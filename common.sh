# Shared part of autopilot.sh and menu.sh: finds and loads the project configuration.
# Order: $AUTOPILOT_CONF, ./autopilot.conf, ~/.config/autopilot-loop/standard.conf
# (`autopilot plan <file>` points standard.conf at the new project so that `autopilot` means it everywhere).
# A configuration is only loaded when its checksum has been confirmed (autopilot trust <file>).
TOOL_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
CONF_BASE=${XDG_CONFIG_HOME:-$HOME/.config}/autopilot-loop
# shellcheck source=lib.sh
. "$TOOL_DIR/lib.sh"

find_conf() {
    local k
    for k in "${AUTOPILOT_CONF:-}" "$PWD/autopilot.conf" "$CONF_BASE/standard.conf"; do
        [ -n "$k" ] && [ -f "$k" ] && { readlink -f "$k"; return 0; }
    done
    return 1
}

CONF=$(find_conf) || {
    echo "No project found. Create one from a plan file: autopilot plan <file>  (or in the project directory: autopilot setup)" >&2
    exit 3
}
is_trusted "$CONF" || {
    echo "The configuration $CONF is not (or no longer) confirmed as trusted – it is executed as Bash code." >&2
    echo "Read it, and if everything is right: autopilot trust $CONF" >&2
    exit 4
}
CONF_DIR=$(dirname "$CONF")

# Defaults; autopilot.conf overrides them (meaning: see templates/autopilot.conf)
NAME=$(basename "$CONF_DIR")
WORKDIR=.
BASE_BRANCH=main
TASKS_FILE=TASKS.md
DECISIONS_FILE=DECISIONS.md
TEST_CMD=''
TEST_COUNT_REGEX='^TESTS: ([0-9]+)'
TEST_COUNT_CMD=''         # instead of TEST_COUNT_REGEX: command that gets the output of TEST_CMD on stdin and prints the number
ACCEPT_CMD=''
ACCEPT_REGEX='^ACCEPT: ([0-9]+) of ([0-9]+)'
ACCEPT_FILES=()
ACCEPT_LIST_CMD=''
ALLOWED=''                # required: paths the worker may change (empty = start refused)
LOCKED=()                 # paths that must never change (plan file; acceptance files always count too)
FORBIDDEN_CONTENT=''
WORKER_TOOLS=(Read Edit Write Glob Grep)
PROMPT_FILE=''
REVIEWER_FILE=''
PLANNER_FILE=''
BRIEF_FILE=''
PLANNER=on                # empty list, acceptance open: propose new tasks (adopted only with your OK)
SUPERVISED=off            # on: task kinds without a licence wait for `autopilot continue` after every task
LICENCE_MIN_RUNS=20       # this many grades per kind …
LICENCE_MIN_RATE=95       # … with at least this success rate (%) earn the licence
LICENCE_REVOKE_BELOW=90   # below this it is revoked
STALL_WARN_AFTER=10       # warn after this many accepted runs without acceptance progress (0 = off)
SMOKE_TEST_CMD=''         # optional: command for a real test (e.g. start a server, check its log)
SMOKE_TEST_EVERY=0        # every n accepted runs; 0 = only when the goal is reached
IMAGE_REVIEW_FILE=''      # optional: image produced by SMOKE_TEST_CMD; the reviewer judges it
IMAGE_REVIEW_QUESTION='Does the result in the image look coherent and free of errors?'
REPORT_MODEL=haiku
PLAN_FILE=''              # optional: plan/description being implemented (locked, passed to every run)
notify() { :; }           # LEVEL TEXT; LEVEL is ok|info|warn|crit

# shellcheck disable=SC1090
. "$CONF"

abs_path() { case "$1" in /*) echo "$1" ;; *) echo "$CONF_DIR/$1" ;; esac; }
WORKDIR=$(abs_path "$WORKDIR")
PROMPT_FILE=$(abs_path "${PROMPT_FILE:-$TOOL_DIR/templates/PROMPT.md}")
REVIEWER_FILE=$(abs_path "${REVIEWER_FILE:-$TOOL_DIR/templates/REVIEWER.md}")
PLANNER_FILE=$(abs_path "${PLANNER_FILE:-$TOOL_DIR/templates/PLANNER.md}")
BRIEF_FILE=$(abs_path "${BRIEF_FILE:-$TOOL_DIR/templates/BRIEF.md}")
[ -n "$PLAN_FILE" ] && PLAN_FILE=$(abs_path "$PLAN_FILE")
STATE=$CONF_DIR/.autopilot  # logs, APPROVAL, STOP, feedback, grades, suggestions
SESSION="autopilot-$NAME-$(printf '%s' "$CONF_DIR" | hash_only | cut -c1-8)"  # same NAME in two folders: two sessions
mkdir -p "$STATE/log" "$STATE/licence"
[ -f "$STATE/.gitignore" ] || echo '*' >"$STATE/.gitignore"  # logs contain complete prompts: never in Git
# If the configuration lives in the work directory, state and configuration must never end up in Git.
if exclude=$(git -C "$WORKDIR" rev-parse --git-path info/exclude 2>/dev/null); then
    case "$exclude" in /*) ;; *) exclude=$WORKDIR/$exclude ;; esac
    mkdir -p "$(dirname "$exclude")"
    for pattern in .autopilot/ autopilot.conf; do
        grep -qxF "$pattern" "$exclude" 2>/dev/null || echo "$pattern" >>"$exclude"
    done
fi

is_running() { tmux has-session -t "=$SESSION" 2>/dev/null; }

# Checksum of the locked acceptance files (empty if there is no acceptance test)
accept_checksum() {
    [ ${#ACCEPT_FILES[@]} -gt 0 ] || return 0
    local list; list=$(cd "$WORKDIR" && find "${ACCEPT_FILES[@]/#-/./-}" -type f 2>/dev/null | LC_ALL=C sort)  # ./-x: a name, not an option
    [ -n "$list" ] || { echo "Acceptance files not found: ${ACCEPT_FILES[*]}" >&2; return 1; }
    (cd "$WORKDIR" && while IFS= read -r d; do checksum "$d"; done <<<"$list" | hash_only)
}
is_approved() {
    [ ${#ACCEPT_FILES[@]} -eq 0 ] && return 0
    local s; s=$(accept_checksum) && [ -n "$s" ] && [ "$(cat "$STATE/APPROVAL" 2>/dev/null)" = "$s" ]
}

# Last line of an output that matches the pattern → group 1 (or 2)
number_from() { # FILE PATTERN [GROUP]
    local line hit=''
    while IFS= read -r line; do
        [[ $line =~ $2 ]] && hit=${BASH_REMATCH[${3:-1}]}
    done <"$1"
    echo "$hit"
}

# --- Grades and licence (per task kind, kind = first [tag] after the number) ----------------------
kind_of() { # TASK LINE, e.g. "- [ ] 8. [logic] …" → logic
    if [[ $1 =~ ^-\ \[.\]\ ([0-9a-z]+\.\ )?\[([a-z0-9_-]+)\] ]]; then echo "${BASH_REMATCH[2]}"; else echo general; fi
}
rate() { # KIND → "count successes" of the last LICENCE_MIN_RUNS grades
    grep ";$1;" "$STATE/grades.csv" 2>/dev/null | tail -"$LICENCE_MIN_RUNS" | awk -F';' '{n++; s+=$3} END {print n+0, s+0}'
}
has_licence() { [ -e "$STATE/licence/$1" ]; }
grade_table() {
    local kind n s
    [ -s "$STATE/grades.csv" ] || { echo "No grades yet."; return; }
    printf '%-14s %8s %8s  %s\n' Kind Grades Rate Licence
    for kind in $(cut -d';' -f2 "$STATE/grades.csv" | sort -u); do
        read -r n s < <(rate "$kind")
        printf '%-14s %8s %7s%%  %s\n' "$kind" "$n/$LICENCE_MIN_RUNS" "$(( n ? 100 * s / n : 0 ))" \
            "$(has_licence "$kind" && echo yes || echo "no (supervised ${SUPERVISED})")"
    done
}

# The plan as a section for prompts (empty if there is none)
plan_section() {
    [ -n "$PLAN_FILE" ] || return 0
    printf '\n\n## Plan being implemented (%s – read only, never change)\n%s\n' "$(basename "$PLAN_FILE")" "$(cat "$PLAN_FILE")"
}

# --- Planner: proposes new tasks, adopts them only after your OK ---------------------------------
run_planner() {
    local prompt cost
    prompt="$(cat "$PLANNER_FILE")$(plan_section)

## Task list ($TASKS_FILE)
$(cat "$WORKDIR/$TASKS_FILE")

## Blocked
$(cat "$WORKDIR/BLOCKED.md" 2>/dev/null || echo –)

## Latest acceptance test
$(tail -40 "$(ls -t "$STATE"/log/accept-*.txt 2>/dev/null | head -1)" 2>/dev/null || echo 'no acceptance test')"
    cost=$(cd "$WORKDIR" && claude_run "$STATE/log/planner.txt" --model "${PLANNER_MODEL:-opus}" --allowedTools Read Grep Glob <<<"$prompt")
    grep -E '^- \[ \] .*Done when' "$STATE/log/planner.txt" >"$STATE/suggestion.md"
    echo "$(date '+%F %T');planner;$cost" >>"$STATE/log/costs-extra.csv"
    if [ -s "$STATE/suggestion.md" ]; then echo "$(wc -l <"$STATE/suggestion.md") tasks proposed (autopilot suggestion)."
    else echo "The planner did not deliver usable tasks, see $STATE/log/planner.txt"; return 1; fi
}
