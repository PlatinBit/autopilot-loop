# Helper functions for all autopilot-loop scripts (usable without a configuration).
# Principle: the work directory, the plan and everything Claude writes are treated as untrusted.

if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
    echo "autopilot-loop needs Bash 4.4 or newer (macOS: brew install bash)." >&2
    exit 1
fi

# SHA-256 (Linux: sha256sum, macOS: shasum); hash_only prints just the hash, reading stdin without an argument.
checksum() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
hash_only() { checksum "$@" | cut -c1-64; }

# On macOS timeout only exists as gtimeout (coreutils); without either the command runs without a time limit.
with_timeout() { # DURATION COMMAND …
    if command -v timeout >/dev/null; then timeout "$@"
    elif command -v gtimeout >/dev/null; then gtimeout "$@"
    else shift; "$@"; fi
}

# Without the claude CLI nothing can work: say so before anything is created.
need_claude() { command -v claude >/dev/null ||
    { echo "claude (Claude Code CLI) not found on PATH. Install it: https://claude.com/claude-code – then log in once by running: claude" >&2; return 1; }; }

# Install hints for this system: the first package manager found wins.
pkg_manager() { local m; for m in apt-get dnf pacman zypper apk brew; do command -v "$m" >/dev/null && { echo "$m"; return; }; done; }
# Some packages are not named after their command.
pkg_of() { case "$1" in bwrap) echo bubblewrap ;; whiptail) [ "$(pkg_manager)" = apt-get ] && echo whiptail || echo newt ;; *) echo "$1" ;; esac; }
install_hint() { # PACKAGE → the install command for this system, ready to copy
    case "$(pkg_manager)" in
        apt-get) echo "sudo apt install $1" ;;
        dnf)     echo "sudo dnf install $1" ;;
        pacman)  echo "sudo pacman -S $1" ;;
        zypper)  echo "sudo zypper install $1" ;;
        apk)     echo "sudo apk add $1" ;;
        brew)    echo "brew install $1" ;;
        *)       echo "install $1 with your system's package manager" ;;
    esac
}
# A required command is missing: say what is missing, why it is needed and how to install it here.
need() { # COMMAND PURPOSE
    command -v "$1" >/dev/null ||
        { echo "$1 not found on PATH. $2 Install it: $(install_hint "$(pkg_of "$1")") – then run again." >&2; return 1; }
}

# Claude's answers are JSON: without jq every run would fail, so say so before anything is created.
need_jq() { need jq "autopilot-loop needs it to read Claude's answers."; }

# Best-effort install suggestion for a project command (TEST_CMD …) that cannot run. Heuristic:
# a missing Python module, pytest, or the command's first word. Prints "Try: …" or nothing.
suggest_install() { # COMMAND EXITCODE LOGFILE
    local cmd=$1 m w
    case "$cmd" in *sandbox-run\ *) cmd=${cmd##*sandbox-run } ;; esac  # plan accept may wrap the command
    m=$(grep -m1 -oE "No module named '?[A-Za-z0-9_]+" "$3" 2>/dev/null | sed "s/.*[ ']//")
    [ -n "$m" ] && { echo "Try: $(install_hint "python3-$m") (or: pip install $m)"; return 0; }
    case "$cmd" in pytest*|python*-m\ pytest*) echo "Try: $(install_hint python3-pytest) (or: pip install pytest)"; return 0 ;; esac
    [ "$2" = 127 ] || return 0
    w=${cmd%% *}; w=${w##*/}
    case "$w" in npm|npx|node) w=nodejs ;; mvn) w=maven ;; go) w=golang ;; *) w=$(pkg_of "$w") ;; esac
    echo "Try: $(install_hint "$w")"
}

# Git without hooks, fsmonitor, external diff programs and pager: a prepared work directory must not be able
# to run code through them while the script checks or commits.
g() { git -c core.hooksPath=/dev/null -c core.fsmonitor= -c diff.external= -c core.pager=cat "$@"; }

# Every Claude run: only the user's own settings (never .claude/ from the work directory, whose hooks would
# otherwise run), and never writing to Git, Claude or autopilot management files.
CLAUDE_SAFE=(--setting-sources user --disallowedTools
    "Edit(.git)" "Write(.git)" "Edit(.git/**)" "Write(.git/**)" "Edit(.claude/**)" "Write(.claude/**)"
    "Edit(.autopilot/**)" "Write(.autopilot/**)" "Edit(autopilot.conf)" "Write(autopilot.conf)")

# claude -p with JSON output; the prompt comes via stdin (no length limit for arguments).
# Answer text goes to TEXTFILE, cost in USD to stdout (0 if unknown). Returns the exit code of claude.
# Time limit via CLAUDE_TIMEOUT (default 20m).
claude_run() { # TEXTFILE [claude arguments …] <prompt
    local text=$1 raw=$1.json rc; shift
    with_timeout "${CLAUDE_TIMEOUT:-20m}" claude -p --output-format json "$@" "${CLAUDE_SAFE[@]}" >"$raw" 2>&1; rc=$?
    if jq -e . "$raw" >/dev/null 2>&1; then
        jq -r '.result // ""' "$raw" >"$text"
        jq -r '.total_cost_usd // 0' "$raw"
    else
        cp "$raw" "$text"; echo 0
    fi
    return $rc
}

# Does the answer report a usage limit? Checks the error field or the CLI's own error message,
# not the model's text (otherwise a plan could trigger endless waiting through its text).
# Narrow pattern: "context limit" or "output token limit" are errors, not a reason to wait for hours.
LIMIT_PATTERN='usage limit|rate.?limit|limit reached|hit your limit|resets|429'
usage_limit() { # TEXTFILE (from claude_run)
    local raw=$1.json
    if jq -e . "$raw" >/dev/null 2>&1; then
        jq -e --arg p "$LIMIT_PATTERN" '(.is_error == true) and ((.result // "") | test($p; "i"))' "$raw" >/dev/null
    else
        grep -qiE "$LIMIT_PATTERN" "$raw"
    fi
}

# Trust in configuration files: an autopilot.conf is loaded with `source`, so only when its checksum
# has been confirmed (automatically after `autopilot plan accept`, otherwise with `autopilot trust`).
TRUSTED_FILE=${XDG_CONFIG_HOME:-$HOME/.config}/autopilot-loop/trusted
is_trusted() { [ -f "$1" ] && grep -qxF "$(hash_only <"$1") $(readlink -f "$1")" "$TRUSTED_FILE" 2>/dev/null; }
conf_dir_writable() { # DIR: create it; on failure name it and XDG_CONFIG_HOME
    mkdir -p "$1" 2>/dev/null && [ -w "$1" ] ||
        { echo "Cannot write to the config directory $1 – make it writable or set XDG_CONFIG_HOME to a writable folder." >&2; return 1; }
}
# grep exits 2 on an invalid pattern and prints nothing: a path or content check would then let everything through.
valid_ere() { grep -E -- "$1" </dev/null >/dev/null 2>&1; [ $? -le 1 ]; }
bad_patterns() { # names of the set but invalid ALLOWED / FORBIDDEN_CONTENT
    local v; for v in ALLOWED FORBIDDEN_CONTENT; do [ -z "${!v-}" ] || valid_ere "${!v}" || echo "$v"; done
}
trust() { # FILE
    local path bad; path=$(readlink -f "$1") && [ -f "$path" ] || { echo "File not found: $1" >&2; return 1; }
    bad=$(set +u; . "$path" </dev/null >/dev/null 2>&1; bad_patterns)
    [ -z "$bad" ] || { echo "Not trusted: $(echo $bad) in $path is not a valid regular expression (grep -E)." >&2; return 1; }
    conf_dir_writable "$(dirname "$TRUSTED_FILE")" || return 1
    { awk -v p="$path" 'substr($0, 66) != p' "$TRUSTED_FILE" 2>/dev/null; echo "$(hash_only <"$path") $path"; } >"$TRUSTED_FILE.new" &&
        mv "$TRUSTED_FILE.new" "$TRUSTED_FILE"
}

# Like `cut -c FROM-TO`, but counts characters instead of bytes (GNU cut would cut an umlaut in half)
cut_chars() { # FROM TO <lines
    local l; while IFS= read -r l || [ -n "$l" ]; do printf '%s\n' "${l:$1-1:$2-$1+1}"; done
}

# Mark the first open task as blocked (portable, without GNU sed)
block_first_open() { # FILE
    awk '!d && /^- \[ \]/ { sub(/^- \[ \]/, "- [~]"); d = 1 } 1' "$1" >"$1.new" && mv "$1.new" "$1"
}

# Run TEST_CMD from a trusted configuration once (used by `plan accept` and `autopilot doctor`):
# a missing tool like pytest should show up now, not as a bare "tests red" at the first start.
# A failure only warns, with an install suggestion where one can be guessed.
probe_test_cmd() { # CONF (written and trusted)
    local conf=$1 dir out sr
    dir=$(dirname "$conf"); out=$dir/.autopilot/log/plan-probe.txt
    sr=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/sandbox-run
    mkdir -p "$dir/.autopilot/log"
    (
        set +u; cd "$dir" || exit 0; . "$conf" </dev/null >/dev/null 2>&1
        [ -n "$TEST_CMD" ] || { echo "WARNING: test command not checked: TEST_CMD is not set in $conf"; exit 0; }
        cd "$WORKDIR" 2>/dev/null || { echo "WARNING: test command not checked: work directory $WORKDIR missing"; exit 0; }
        w=(); [ "${SANDBOX:-off}" = on ] && w=("$sr")
        with_timeout "${TEST_TIMEOUT:-30m}" ${w[@]+"${w[@]}"} bash -c "$TEST_CMD" >"$out" 2>&1; rc=$?
        if [ "$rc" = 0 ]; then
            if [ -n "${TEST_COUNT_CMD:-}" ]; then n=$(bash -c "$TEST_COUNT_CMD" <"$out" | tail -1)
            else re=${TEST_COUNT_REGEX:-'^TESTS: ([0-9]+)'}; n=''
                 while IFS= read -r l; do [[ $l =~ $re ]] && n=${BASH_REMATCH[1]}; done <"$out"; fi
            if [[ $n =~ ^[0-9]+$ ]]; then echo "Test command checked: green, $n passed tests."
            else echo "WARNING: test command is green, but no readable test count (check TEST_COUNT_REGEX/TEST_COUNT_CMD), see $out"; fi
        elif [ "$rc" = 124 ]; then echo "WARNING: test command hit the time limit (TEST_TIMEOUT=${TEST_TIMEOUT:-30m}), see $out"
        elif [ -n "${TEST_EMPTY_RC:-}" ] && [ "$rc" = "$TEST_EMPTY_RC" ]; then
            echo "Test command checked: no tests yet (exit code $rc = TEST_EMPTY_RC), task 1 adds the first ones."
        else echo "WARNING: test command cannot run (exit code $rc, missing tool?): $(tail -2 "$out" | tr '\n' ' ' | cut_chars 1 160)"
             try=$(suggest_install "$TEST_CMD" "$rc" "$out"); [ -n "$try" ] && echo "$try"
        fi
    )
}
