# Helper functions for all autopilot-loop scripts (usable without a configuration).
# Principle: the work directory, the plan and everything Claude writes are treated as untrusted.

if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
    echo "autopilot-loop needs Bash 4.4 or newer (macOS: brew install bash)." >&2
    exit 1
fi
CONF_BASE=${XDG_CONFIG_HOME:-$HOME/.config}/autopilot-loop

# SHA-256 (Linux: sha256sum, macOS: shasum); hash_only prints just the hash, reading stdin without an argument.
checksum() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
hash_only() { checksum "$@" | cut -c1-64; }

# On macOS timeout only exists as gtimeout (coreutils); without either the command runs without a time limit.
with_timeout() { # DURATION COMMAND …
    if command -v timeout >/dev/null; then timeout "$@"
    elif command -v gtimeout >/dev/null; then gtimeout "$@"
    else shift; "$@"; fi
}

# The project configuration: $AUTOPILOT_CONF, otherwise autopilot.conf in this folder or one above it (up to the Git root).
find_conf() {
    local d=$PWD
    [ -n "${AUTOPILOT_CONF:-}" ] && { [ -f "$AUTOPILOT_CONF" ] && readlink -f "$AUTOPILOT_CONF"; return; }
    while :; do
        [ -f "$d/autopilot.conf" ] && { readlink -f "$d/autopilot.conf"; return 0; }
        [ -e "$d/.git" ] || [ "$d" = / ] && return 1
        d=$(dirname "$d")
    done
}

# A loop is running when the PID in STATE/lock/pid is alive (a leftover lock after a crash does not count).
lock_alive() { # STATE
    local pid=''; [ -r "$1/lock/pid" ] && read -r pid <"$1/lock/pid"; [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null
}

# Ends a process tree, children first (POSIX ps only, for macOS)
kill_tree() { local c; for c in $(ps -A -o pid= -o ppid= | awk -v p="$1" '$2 == p {print $1}'); do kill_tree "$c"; done; kill "$1" 2>/dev/null; }

# Without the claude CLI nothing can work: say so before anything is created.
need_claude() { command -v claude >/dev/null ||
    { echo "claude (Claude Code CLI) not found on PATH. Install it: https://claude.com/claude-code – then log in once by running: claude" >&2; return 1; }; }

# Install hints for this system: the first package manager found wins.
pkg_manager() { local m; for m in apt-get dnf pacman zypper apk brew; do command -v "$m" >/dev/null && { echo "$m"; return; }; done; }
# Some packages are not named after their command.
pkg_of() { case "$1" in bwrap) echo bubblewrap ;; *) echo "$1" ;; esac; }
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

# Every Claude run: --safe-mode keeps foreign hooks, plugins, MCP servers and the automatic CLAUDE.md out
# (a hook once rewrote the test command; the project's CLAUDE.md is passed in the prompt instead) and
# still uses the normal login. --bare would do the same but ignores the OAuth login (API key only).
# --setting-sources user: never .claude/ from the work directory, whose permission rules would widen the
# tools. And never writing to Git, Claude or autopilot management files.
CLAUDE_SAFE=(--safe-mode --setting-sources user --disallowedTools
    "Edit(.git)" "Write(.git)" "Edit(.git/**)" "Write(.git/**)" "Edit(.claude/**)" "Write(.claude/**)"
    "Edit(.autopilot/**)" "Write(.autopilot/**)" "Edit(autopilot.conf)" "Write(autopilot.conf)")

# claude -p with JSON output; the prompt comes via stdin (no length limit for arguments).
# Answer text goes to TEXTFILE, cost in USD to stdout (0 if unknown, "?" after the time limit: the
# tokens were spent but never reported). Every call is appended to $COSTS (if set) with its kind,
# model, cost, tokens and effort. Returns the exit code of claude. Time limit via CLAUDE_TIMEOUT (default 20m).
# Effort per kind: EFFORT_WORKER, EFFORT_REVIEWER, EFFORT_LESSONS, and EFFORT_PLANNER for every other kind
# (default high); CLAUDE_CODE_EFFORT_LEVEL from the environment would beat --effort, so the call runs without it.
# Every call stops at MAX_COST_PER_CALL_USD (default 2), see over_budget.
COSTS_HEADER='time;kind;model;usd;input_tokens;cache_read_tokens;output_tokens;effort'
claude_run() { # TEXTFILE KIND [claude arguments …] <prompt
    local text=$1 kind=$2 raw=$1.json rc cost tokens='0;0;0' model=? a prev='' effort; shift 2
    for a in "$@"; do [ "$prev" = --model ] && model=$a; prev=$a; done
    case $kind in worker|reviewer|lessons) effort=EFFORT_${kind^^} ;; *) effort=EFFORT_PLANNER ;; esac; effort=${!effort:-high}
    with_timeout "${CLAUDE_TIMEOUT:-20m}" env -u CLAUDE_CODE_EFFORT_LEVEL claude -p --output-format json --effort "$effort" \
        --max-budget-usd "${MAX_COST_PER_CALL_USD:-2}" "$@" "${CLAUDE_SAFE[@]}" >"$raw" 2>&1; rc=$?
    if jq -e . "$raw" >/dev/null 2>&1; then
        jq -r '.result // (.errors // [] | join("; "))' "$raw" >"$text"
        cost=$(jq -r '.total_cost_usd // 0' "$raw")
        tokens=$(jq -r '[.usage.input_tokens, .usage.cache_read_input_tokens, .usage.output_tokens] | map(. // 0 | tostring) | join(";")' "$raw")
    else
        cp "$raw" "$text"; cost=0
    fi
    [ "$rc" = 124 ] && { cost='?'; tokens=';;'; }
    if [ -n "${COSTS:-}" ]; then  # a costs.csv from before 0.10 gets the new header (its rows have no effort)
        [ -s "$COSTS" ] || echo "$COSTS_HEADER" >"$COSTS"
        [ "$(head -1 "$COSTS")" = "$COSTS_HEADER" ] || { { echo "$COSTS_HEADER"; tail -n +2 "$COSTS"; } >"$COSTS.new" && mv "$COSTS.new" "$COSTS"; }
        echo "$(date '+%F %T');$kind;$model;$cost;$tokens;$effort" >>"$COSTS"
    fi
    echo "$cost"
    return $rc
}
# The flags of the claude CLI the loop relies on that this claude lacks (empty: all there)
missing_flags() {
    local h f m=''; h=$(claude --help 2>/dev/null)
    for f in --safe-mode --effort --max-budget-usd --json-schema; do grep -q -- "$f" <<<"$h" || m+=" $f"; done
    echo "${m# }"
}
# The call stopped at MAX_COST_PER_CALL_USD (--max-budget-usd)
over_budget() { jq -e '.subtype == "error_max_budget_usd"' "$1.json" >/dev/null 2>&1; }  # TEXTFILE (from claude_run)
# Fixed answer formats (--json-schema) of reviewer, final review and planner; the CLI puts the answer into
# .structured_output. The note goes to the journal (journal_add).
NOTE_SCHEMA='{"type":"object","additionalProperties":false,"required":["did","problem","hint"],"description":"your note for the shared journal of the next agents: one line each, about 300 characters in total, no secrets","properties":{"did":{"type":"string","description":"what you did"},"problem":{"type":"string","description":"what went wrong or cost time, or none"},"hint":{"type":"string","description":"one tip for the next agent, or none"}}}'
TASKS_SCHEMA='{"type":"array","maxItems":10,"items":{"type":"string","description":"- [ ] <number>. <task>. Done when <automatically checkable criterion>. Dependencies right after the number: - [ ] <number>. (after <numbers>) <task>. …"}}'
REVIEWER_SCHEMA='{"type":"object","additionalProperties":false,"required":["verdict","reasons","note"],"properties":{"verdict":{"enum":["accept","reject"]},"reasons":{"type":"array","items":{"type":"string"},"description":"for reject: what exactly is missing or wrong, one or two sentences"},"note":'$NOTE_SCHEMA'}}'
FINAL_SCHEMA='{"type":"object","additionalProperties":false,"required":["ok","tasks","note"],"properties":{"ok":{"type":"boolean","description":"true only if there is no real defect"},"tasks":'$TASKS_SCHEMA',"note":'$NOTE_SCHEMA'}}'
PLANNER_SCHEMA='{"type":"object","additionalProperties":false,"required":["tasks","note"],"properties":{"tasks":'$TASKS_SCHEMA',"not_reachable":{"type":"string","description":"only when the goal needs the owner, not tasks: what the owner has to do or decide"},"note":'$NOTE_SCHEMA'}}'
SIZE_SCHEMA='{"type":"object","additionalProperties":false,"required":["fits","split"],"properties":{"fits":{"type":"boolean","description":"true if the worker can finish the task in one run"},"split":{"type":"array","maxItems":5,"items":{"type":"string","description":"- [ ] <task>. Done when <automatically checkable criterion>."},"description":"only when fits is false: 2 to 5 smaller tasks that together do exactly this task"}}}'
# Values of the structured answer, one per line: newlines and other control characters inside a value become spaces
answer_lines() { jq -r ".structured_output | $2 | tostring | gsub(\"[[:cntrl:]]\"; \" \")" "$1.json" 2>/dev/null; }  # TEXTFILE JQ-PATH

# Journal (.autopilot/JOURNAL.md, written only by the script): one entry per agent run,
# "### J<n> <time> <role> <task> <result>" plus the agent's note: only did:/problem:/hint: lines of the LAST
# <<<NOTE … NOTE>>> block, or of the note field of a structured answer (one line per field), at most 3 lines /
# 600 bytes, control characters removed. Without a note (or answer file) the entry holds only the header.
# Numbers run on over restarts; the file is never shortened.
journal_add() { # ANSWER_FILE JOURNAL ROLE TASK RESULT
  local _ans=$1 _jf=$2 _role=$3 _res=$5 _task _n _note
  _task=$(printf '%s' "$4" | tr -d '\000-\037\177')
  _n=$(grep -c '^### J' "$_jf" 2>/dev/null)
  _n=$(( ${_n:-0} + 1 ))
  _note=$( { answer_lines "$_ans" '.note // {} | to_entries[] | select(.key | test("^(did|problem|hint)$")) | "\(.key): \(.value)"'
             awk '/^<<<NOTE[[:space:]]*$/ { b = ""; on = 1; next }
               /^NOTE>>>[[:space:]]*$/ { if (on) last = b; on = 0; next }
               on { b = b $0 "\n" }
               END { printf "%s", last }' "$_ans" 2>/dev/null; } \
    | tr -d '\000-\011\013-\037\177' \
    | grep -E '^(did|problem|hint):' | head -n 3 | head -c 600 \
    | { iconv -f UTF-8 -t UTF-8 -c 2>/dev/null || cat; })
  {
    printf '### J%s %s %s %s %s\n' "$_n" "$(date '+%Y-%m-%d %H:%M')" "$_role" "$_task" "$_res"
    [ -n "$_note" ] && printf '%s\n' "$_note"
    printf '\n'
  } >> "$_jf"
}
# The last N entries (default 25) for the next prompt.
journal_tail() { # JOURNAL [N]
  awk -v k="${2:-25}" '/^### J/ { n++ } { l[NR] = $0; e[NR] = n }
       END { for (i = 1; i <= NR; i++) if (e[i] > n - k) print l[i] }' "$1" 2>/dev/null
}
# An answer without its closed note blocks, before VERDICT:/FINAL:/task lines are read from it.
# A block that is never closed stays in (otherwise an answer with a stray "<<<NOTE" would lose its verdict).
strip_note() {
    awk '/^<<<NOTE[[:space:]]*$/ && !on { on = 1; b = "" }
         on { b = b $0 "\n"; if (/^NOTE>>>[[:space:]]*$/) on = 0; next }
         { print }
         END { if (on) printf "%s", b }' "$1" 2>/dev/null
}
# Output of a project command without ANSI escape sequences (colours, cursor moves), for handover and prompts
no_ansi() { sed "s/$(printf '\033')\[[0-9;?]*[A-Za-z]//g" | tr -d '\033'; }
# "## Milestone N" headings of a plan (outside fenced code blocks): the numbers, sorted, each once
milestones() { # PLANFILE
    awk '/^[[:space:]]*(```|~~~)/ { code = !code; next }
         !code && /^##[[:space:]]+Milestone[[:space:]]+[0-9]+/ { s = $0; sub(/^##[[:space:]]+Milestone[[:space:]]+/, "", s); sub(/[^0-9].*/, "", s); print s }' "$1" 2>/dev/null | sort -nu
}
# Lines that look like a secret: AWS key, private key block, a long literal assigned to a name that is or ends in
# password/secret/token/api_key (DB_PASSWORD, dbPassword); longer names like tokenizer_name or PASSWORD_HASHERS do not count
SECRETS='AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|((^|[^A-Za-z0-9])([Pp]assword|PASSWORD|[Ss]ecret|SECRET|[Tt]oken|TOKEN|[Aa]pi_?[Kk]ey|API_?KEY)|[a-z0-9](Password|Secret|Token|Api_?[Kk]ey))["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"'][A-Za-z0-9+/=_.-]{20,}["'"'"']'

# Sum of the cost in USD from line FROM on (a start notes where its calls begin; empty = all), unknown costs ("?") left out
cost_sum() { # CSV [FROM]
    awk -F';' -v f="${2:-2}" 'NR > 1 && NR >= f && $4 != "?" { c += $4 } END { printf "%.2f\n", c }' "$1" 2>/dev/null || echo 0.00
}
# Cost and tokens per kind of Claude call (plan, spec, draft, size, brief, worker, reviewer, planner, lessons, final) and the total
cost_table() { # CSV
    [ -s "$1" ] || { echo "  no Claude calls recorded yet"; return 0; }
    awk -F';' '
        function h(n) { return n >= 1e6 ? sprintf("%.1fM", n / 1e6) : n >= 1e4 ? sprintf("%.0fk", n / 1e3) : n + 0 }
        NR > 1 { k = $2; seen[k] = 1; if ($4 == "?") u[k]++; else { c[k] += $4; t += $4 }
                                         i[k] += $5; r[k] += $6; o[k] += $7 }
        END { n = split("plan spec draft size brief worker reviewer planner lessons final", order, " ")
              for (k in seen) { known = 0; for (j = 1; j <= n; j++) if (order[j] == k) known = 1; if (!known) order[++n] = k }
              for (j = 1; j <= n; j++) { k = order[j]; if (!(k in seen)) continue
                  printf "  %-9s %8.2f USD   tokens: %s in, %s cache read, %s out%s\n", k, c[k], h(i[k]), h(r[k]), h(o[k]),
                         u[k] ? sprintf(" (+%d calls cut off at the time limit, cost unknown)", u[k]) : "" }
              printf "  %-9s %8.2f USD\n", "total", t }' "$1"
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
# Did the call end with an API or network error (overloaded, 5xx, connection reset, API timeout)? The CLI then
# prints no JSON at all, or an error answer naming it. The usage limit is not one of them (usage_limit).
API_ERROR_PATTERN='overloaded|ECONNRESET|ECONNREFUSED|ETIMEDOUT|EAI_AGAIN|socket hang up|fetch failed|network|connection error|timed? ?out|internal server error|bad gateway|service unavailable|(^|[^0-9])5[0-9][0-9]([^0-9]|$)'
api_error() { # TEXTFILE (from claude_run)
    usage_limit "$1" && return 1
    jq -e . "$1.json" >/dev/null 2>&1 || return 0
    jq -e --arg p "$API_ERROR_PATTERN" '(.is_error == true) and (((.api_error_status // 0) >= 500) or ((.result // "") | test($p; "i")))' "$1.json" >/dev/null
}
# When the usage limit resets, as far as the message says ("resets 5pm", or "…|<unix time>")
limit_reset() { # TEXTFILE (from claude_run)
    local r; r=$(jq -r '.result // ""' "$1.json" 2>/dev/null || cat "$1.json" 2>/dev/null)
    if [[ $r =~ \|([0-9]{10}) ]]; then date -d "@${BASH_REMATCH[1]}" '+%F %H:%M' 2>/dev/null || date -r "${BASH_REMATCH[1]}" '+%F %H:%M'
    elif [[ $r =~ resets\ ([^|\"]+) ]]; then echo "${BASH_REMATCH[1]% }"; fi
}

# Trust in configuration files: an autopilot.conf is loaded with `source`, so only when its checksum
# has been confirmed (automatically after `autopilot plan accept`, otherwise with `autopilot trust`).
TRUSTED_FILE=$CONF_BASE/trusted
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
# Shortens each line to at most N characters at a word boundary, with "…" when something was cut
shorten() { # N <lines
    local l w; while IFS= read -r l || [ -n "$l" ]; do
        if [ "${#l}" -le "$1" ]; then printf '%s\n' "$l"
        else l=${l:0:$1-1}; w=${l% *}; [ "${#w}" -ge $(($1 * 2 / 3)) ] && l=$w; printf '%s…\n' "$l"; fi
    done
}

# Dependencies: "- [ ] 4. (after 2, 3) …" right after the number waits until tasks 2 and 3 are ticked off [x];
# "after 3" also covers the parts 3.1, 3.2 … of a split task 3, a number that no task has counts as done.
# next: line number of the next task, the first open one whose dependencies are all [x] (empty: none can start).
# waiting: every open task that cannot start, with the blocked [~] (or else open) task it waits on.
tasks_awk() { # next|waiting FILE
    awk -v mode="$1" '
        function state(d,   j, s) { s = "x"; for (j = 1; j <= NR; j++) if (num[j] == d || index(num[j], d ".") == 1) { if (st[j] == "~") return "~"; if (st[j] != "x") s = " " }; return s }
        { line[NR] = $0 }
        /^- \[[ x~]\]/ { st[NR] = substr($0, 4, 1) }
        match($0, /^- \[.\] [0-9]+(\.[0-9]+)*\./) { num[NR] = substr($0, 7, RLENGTH - 7) }
        match($0, /^- \[.\] [0-9]+(\.[0-9]+)*\. \(after [0-9][0-9., ]*\)/) { dep[NR] = substr($0, 1, RLENGTH - 1); sub(/.*\(after /, "", dep[NR]) }
        END { for (i = 1; i <= NR; i++) { if (st[i] != " ") continue
                  n = split(dep[i], a, /[ ,]+/); why = ""
                  for (k = 1; k <= n; k++) { d = a[k]; sub(/\.$/, "", d); if (d == "") continue; s = state(d)
                      if (s == "~") { why = "blocked task " d; break }; if (s == " " && why == "") why = "task " d }
                  if (mode == "next" && why == "") { print i; exit }
                  if (mode == "waiting" && why != "") print line[i] " – waiting on " why } }' "$2"
}
next_task() { tasks_awk next "$1"; }  # FILE
# The task list with the open task in line LINE marked [MARK] (portable, without GNU sed)
mark_line() { awk -v l="$1" -v m="$2" 'NR == l { sub(/^- \[ \]/, "- [" m "]") } 1'; }  # LINE MARK <task list

# Does the bubblewrap sandbox work here? (bwrap may be installed but unable to create namespaces: AppArmor, container)
LIB_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
sandbox_works() { command -v bwrap >/dev/null && "$LIB_DIR/sandbox-run" true >/dev/null 2>&1; }

# Claude Code refuses every write below ~/.claude/: a work directory there could never get a single change.
under_claude_dir() { # PATH
    local p c; p=$(readlink -f "$1" 2>/dev/null || echo "$1"); c=$(readlink -f "$HOME/.claude" 2>/dev/null || echo "$HOME/.claude")
    case "$p/" in "$c"/*) return 0 ;; esac; return 1
}

# Run TEST_CMD from a trusted configuration once (used by `plan accept` and `autopilot doctor`):
# a missing tool like pytest should show up now, not as a bare "tests red" at the first start.
# A failure only warns, with an install suggestion where one can be guessed.
probe_test_cmd() { # CONF (written and trusted)
    local conf=$1 dir out
    dir=$(dirname "$conf"); out=$dir/.autopilot/log/plan-probe.txt
    mkdir -p "$dir/.autopilot/log"
    (
        set +u; cd "$dir" || exit 0; . "$conf" </dev/null >/dev/null 2>&1
        [ -n "$TEST_CMD" ] || { echo "WARNING: test command not checked: TEST_CMD is not set in $conf"; exit 0; }
        cd "$WORKDIR" 2>/dev/null || { echo "WARNING: test command not checked: work directory $WORKDIR missing"; exit 0; }
        w=(); [ "${SANDBOX:-}" != off ] && sandbox_works && w=("$LIB_DIR/sandbox-run")
        NO_COLOR=1 PY_COLORS=0 FORCE_COLOR=0 TERM=dumb with_timeout "${TEST_TIMEOUT:-30m}" ${w[@]+"${w[@]}"} bash -c "$TEST_CMD" >"$out" 2>&1; rc=$?
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
