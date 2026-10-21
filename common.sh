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
TEST_EMPTY_RC=''          # exit code of TEST_CMD that means "0 tests", not red (pytest: 5)
TEST_TIMEOUT=30m          # time limit for TEST_CMD, ACCEPT_CMD and SMOKE_TEST_CMD (each call)
SANDBOX=off               # on (Linux, needs bubblewrap): those commands run without network and devices, read-only outside WORKDIR
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
DEMO_CMD=''               # demo at the end: uses the result like the owner would, exit 0 = it works (empty: SMOKE_TEST_CMD)
TRY_IT=''                 # short text for the handover: how the owner tries the result
IMAGE_REVIEW_FILE=''      # optional: image produced by SMOKE_TEST_CMD; the reviewer judges it
IMAGE_REVIEW_QUESTION='Does the result in the image look coherent and free of errors?'
REPORT_MODEL=haiku
PLAN_FILE=''              # optional: plan/description being implemented (locked, passed to every run)
notify() { # LEVEL TEXT; LEVEL is ok|info|warn|crit. Default: desktop notification when notify-send
    # exists, silent otherwise; a notify() in autopilot.conf (sourced below) replaces this one.
    command -v notify-send >/dev/null || return 0
    local u=low; case "$1" in crit) u=critical ;; warn) u=normal ;; esac
    notify-send -u "$u" "Autopilot $NAME" "$2" 2>/dev/null || true  # no DBUS: stay silent, never fail the loop
}

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
# Same NAME in two folders: two sessions. Only [A-Za-z0-9_-]: tmux silently renames "." and ":".
SESSION="autopilot-$(printf '%s' "$NAME" | tr -c 'A-Za-z0-9_-' '_')-$(printf '%s' "$CONF_DIR" | hash_only | cut -c1-8)"
mkdir -p "$STATE/log" "$STATE/licence"
[ -f "$STATE/.gitignore" ] || echo '*' >"$STATE/.gitignore"  # logs contain complete prompts: never in Git
# If the configuration lives in the work directory, state and configuration must never end up in Git.
if exclude=$(git -C "$WORKDIR" rev-parse --git-path info/exclude 2>/dev/null); then
    case "$exclude" in /*) ;; *) exclude=$WORKDIR/$exclude ;; esac
    mkdir -p "$(dirname "$exclude")"
    for pattern in /.autopilot/ /autopilot.conf __pycache__/ '*.pyc'; do
        grep -qxF "$pattern" "$exclude" 2>/dev/null || echo "$pattern" >>"$exclude"
    done
fi

# Running: the tmux session exists, or the lock of an autopilot.sh started by hand is held by a live process
lock_alive() { local pid=''; [ -r "$STATE/lock/pid" ] && read -r pid <"$STATE/lock/pid"; [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; }
is_running() { tmux has-session -t "=$SESSION" 2>/dev/null || lock_alive; }

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

# The project's CLAUDE.md as a section for prompts (--safe-mode does not load it by itself)
project_rules() {
    [ -s "$WORKDIR/CLAUDE.md" ] || return 0
    printf '\n\n## Project rules (CLAUDE.md)\n%s\n' "$(cat "$WORKDIR/CLAUDE.md")"
}

# --- Planner: proposes new tasks, adopts them only after your OK ---------------------------------
run_planner() {
    local prompt cost
    prompt="$(cat "$PLANNER_FILE")$(plan_section)$(project_rules)

## Task list ($TASKS_FILE)
$(cat "$WORKDIR/$TASKS_FILE")

## Blocked
$(cat "$WORKDIR/BLOCKED.md" 2>/dev/null || echo –)

## Latest acceptance test
$(tail -40 "$(ls -t "$STATE"/log/accept-*.txt 2>/dev/null | head -1)" 2>/dev/null || echo 'no acceptance test')

## Demo at the end (DEMO_CMD), last lines
$(tail -40 "$STATE/demo.txt" 2>/dev/null || echo 'no demo ran')

## Your previous suggestion (do not repeat it, it did not reach the goal)
$(cat "$STATE/log/suggestion-prev.md" 2>/dev/null || echo –)"
    cost=$(cd "$WORKDIR" && claude_run "$STATE/log/planner.txt" --model "${PLANNER_MODEL:-opus}" --allowedTools Read Grep Glob <<<"$prompt")
    echo "$(date '+%F %T');planner;$cost" >>"$STATE/log/costs-extra.csv"
    # "NOT REACHABLE: <reason>": the goal needs the owner, not more tasks (exit 2, the reason as the text)
    if grep -m1 '^NOT REACHABLE:' "$STATE/log/planner.txt" | cut_chars 1 200 | grep .; then rm -f "$STATE/suggestion.md"; return 2; fi
    grep -E '^- \[ \] .*Done when' "$STATE/log/planner.txt" >"$STATE/suggestion.md"
    cp "$STATE/suggestion.md" "$STATE/log/suggestion-prev.md"
    if [ -s "$STATE/suggestion.md" ]; then echo "$(wc -l <"$STATE/suggestion.md") tasks proposed (autopilot suggestion)."
    else echo "The planner did not deliver usable tasks, see $STATE/log/planner.txt"; return 1; fi
}
