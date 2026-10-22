# Shared part of autopilot.sh and `autopilot start`: finds and loads the project configuration
# ($AUTOPILOT_CONF, otherwise autopilot.conf in the current folder or one above it, up to the Git root).
# A configuration is only loaded when its checksum has been confirmed (autopilot trust <file>).
TOOL_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
# shellcheck source=lib.sh
. "$TOOL_DIR/lib.sh"

CONF=$(find_conf) || {
    echo "No project found here (autopilot.conf in this folder or above, or AUTOPILOT_CONF). Create one: autopilot plan <file>" >&2
    exit 3
}
is_trusted "$CONF" || {
    echo "The configuration $CONF is not (or no longer) confirmed as trusted – it is executed as Bash code." >&2
    echo "Read it, and if everything is right: autopilot trust $CONF" >&2
    exit 4
}
CONF_DIR=$(dirname "$CONF")

# Defaults; autopilot.conf overrides them (meaning: see templates/autopilot.conf). The caps may also come from the environment.
NAME=$(basename "$CONF_DIR")
WORKDIR=.
BASE_BRANCH=''            # empty: the branch checked out in the project's main worktree
TASKS_FILE=TASKS.md
DECISIONS_FILE=DECISIONS.md
TEST_CMD=''
TEST_COUNT_REGEX='^TESTS: ([0-9]+)'
TEST_COUNT_CMD=''
TEST_EMPTY_RC=''
TEST_TIMEOUT=30m
DEMO_CMD=''
TRY_IT=''
ACCEPT_CMD=''
ACCEPT_REGEX='^ACCEPT: ([0-9]+) of ([0-9]+)'
ALLOWED=''
LOCKED=()
FORBIDDEN_CONTENT=''
WORKER_TOOLS=(Read Edit Write Glob Grep)
SANDBOX=${SANDBOX:-}
MODELS=balanced
MAX_RUNS=${MAX_RUNS:-50}
MAX_COST_USD=${MAX_COST_USD:-20}
ATTEMPTS=${ATTEMPTS:-3}
MAX_BLOCKED=${MAX_BLOCKED:-3}
NO_PROGRESS=${NO_PROGRESS:-10}
MAX_COST_PER_CALL_USD=${MAX_COST_PER_CALL_USD:-2}
COOLDOWN=${COOLDOWN:-10m}
EFFORT_WORKER=${EFFORT_WORKER:-}; EFFORT_REVIEWER=${EFFORT_REVIEWER:-}; EFFORT_PLANNER=${EFFORT_PLANNER:-}; EFFORT_LESSONS=${EFFORT_LESSONS:-}
MILESTONE_GATE=auto
PLANNER=on
MERGE=ff
PR_WAIT=off
SIZE_CHECK=''           # empty: on, off with MODELS=cheap
FRESH_CHECK=on
SECRETS_CHECK=on
PLAN_FILE=''
SPEC_FILE=''
PROMPT_FILE=''
REVIEWER_FILE=''
PLANNER_FILE=''
BRIEF_FILE=''
notify() { # LEVEL TEXT; LEVEL is ok|info|warn|crit. Default: desktop notification when notify-send
    # exists, silent otherwise; a notify() in autopilot.conf (sourced below) replaces this one.
    command -v notify-send >/dev/null || return 0
    local u=low; case "$1" in crit) u=critical ;; warn) u=normal ;; esac
    notify-send -u "$u" "Autopilot $NAME" "$2" 2>/dev/null || true  # no DBUS: stay silent, never fail the loop
}

# shellcheck disable=SC1090
. "$CONF"

case $MODELS in  # models, then effort: worker reviewer planner lessons (the planner's also for final, brief, draft, plan)
    balanced) WORKER_MODEL=sonnet; REVIEWER_MODEL=sonnet; PLANNER_MODEL=opus;   e=(medium high high low) ;;
    max)      WORKER_MODEL=opus;   REVIEWER_MODEL=opus;   PLANNER_MODEL=opus;   e=(high xhigh xhigh xhigh) ;;
    cheap)    WORKER_MODEL=haiku;  REVIEWER_MODEL=sonnet; PLANNER_MODEL=sonnet; e=(medium medium medium low) ;;
    *) echo "MODELS=$MODELS in $CONF: use balanced, max or cheap." >&2; exit 1 ;;
esac
EFFORT_WORKER=${EFFORT_WORKER:-${e[0]}}; EFFORT_REVIEWER=${EFFORT_REVIEWER:-${e[1]}}
EFFORT_PLANNER=${EFFORT_PLANNER:-${e[2]}}; EFFORT_LESSONS=${EFFORT_LESSONS:-${e[3]}}
[ -n "$SIZE_CHECK" ] || { [ "$MODELS" = cheap ] && SIZE_CHECK=off || SIZE_CHECK=on; }
case $MERGE in ff|off|pr) ;; *) echo "MERGE=$MERGE in $CONF: use ff, off or pr." >&2; exit 1 ;; esac
abs_path() { case "$1" in /*) echo "$1" ;; *) echo "$CONF_DIR/$1" ;; esac; }
WORKDIR=$(abs_path "$WORKDIR")
PROMPT_FILE=$(abs_path "${PROMPT_FILE:-$TOOL_DIR/templates/PROMPT.md}")
REVIEWER_FILE=$(abs_path "${REVIEWER_FILE:-$TOOL_DIR/templates/REVIEWER.md}")
PLANNER_FILE=$(abs_path "${PLANNER_FILE:-$TOOL_DIR/templates/PLANNER.md}")
BRIEF_FILE=$(abs_path "${BRIEF_FILE:-$TOOL_DIR/templates/BRIEF.md}")
[ -n "$PLAN_FILE" ] && PLAN_FILE=$(abs_path "$PLAN_FILE")
[ -n "$SPEC_FILE" ] && SPEC_FILE=$(abs_path "$SPEC_FILE")
if [ -z "$BASE_BRANCH" ]; then  # the main worktree's branch; if that is the work branch itself: main, else master
    BASE_BRANCH=$(g -C "$WORKDIR" worktree list --porcelain 2>/dev/null | sed -n 's|^branch refs/heads/||p' | head -1)
    [ "$BASE_BRANCH" = "$(g -C "$WORKDIR" branch --show-current 2>/dev/null)" ] &&
        { g -C "$WORKDIR" rev-parse -q --verify main >/dev/null && BASE_BRANCH=main || BASE_BRANCH=master; }
fi
STATE=$CONF_DIR/.autopilot  # logs, costs, STOP, feedback, brakes, suggestion, outcome, handover
# Same NAME in two folders: two sessions. Only [A-Za-z0-9_-]: tmux silently renames "." and ":".
SESSION="autopilot-$(printf '%s' "$NAME" | tr -c 'A-Za-z0-9_-' '_')-$(printf '%s' "$CONF_DIR" | hash_only | cut -c1-8)"
mkdir -p "$STATE/log"
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
is_running() { tmux has-session -t "=$SESSION" 2>/dev/null || lock_alive "$STATE"; }
