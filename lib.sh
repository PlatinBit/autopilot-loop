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
usage_limit() { # TEXTFILE (from claude_run)
    local raw=$1.json
    if jq -e . "$raw" >/dev/null 2>&1; then
        jq -e '(.is_error == true) and ((.result // "") | test("limit"; "i"))' "$raw" >/dev/null
    else
        grep -qi 'limit' "$raw"
    fi
}

# Trust in configuration files: an autopilot.conf is loaded with `source`, so only when its checksum
# has been confirmed (automatically after `autopilot plan accept`, otherwise with `autopilot trust`).
TRUSTED_FILE=${XDG_CONFIG_HOME:-$HOME/.config}/autopilot-loop/trusted
is_trusted() { [ -f "$1" ] && grep -qxF "$(hash_only <"$1") $(readlink -f "$1")" "$TRUSTED_FILE" 2>/dev/null; }
trust() { # FILE
    local path; path=$(readlink -f "$1") && [ -f "$path" ] || { echo "File not found: $1" >&2; return 1; }
    mkdir -p "$(dirname "$TRUSTED_FILE")"
    { awk -v p="$path" 'substr($0, 66) != p' "$TRUSTED_FILE" 2>/dev/null; echo "$(hash_only <"$path") $path"; } >"$TRUSTED_FILE.new" &&
        mv "$TRUSTED_FILE.new" "$TRUSTED_FILE"
}

# Mark the first open task as blocked (portable, without GNU sed)
block_first_open() { # FILE
    awk '!d && /^- \[ \]/ { sub(/^- \[ \]/, "- [~]"); d = 1 } 1' "$1" >"$1.new" && mv "$1.new" "$1"
}
