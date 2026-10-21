#!/usr/bin/env bash
# autopilot-loop: a feedback loop of worker, script checks, reviewer and a locked goal (plan, acceptance test, demo).
# Claude Code works through the task list, one task per run, with a fresh context and without Git.
# This script then checks the result itself, lets a second Claude judge it and commits only what passes
# everything; otherwise it resets and feeds the reason into the next attempt. When the list is done it runs
# the demo and writes the handover. Brakes: ATTEMPTS per task, MAX_BLOCKED, NO_PROGRESS, MAX_RUNS, MAX_COST_USD.
#
# Important: the checks protect quality, they are not a security boundary. The test command runs code that
# Claude wrote. Run plans or projects from others only inside a container or a VM.
#
# Normally started with `autopilot start` (in Claude Code `/autopilot-loop start`), which runs it in tmux.
# If the worker is a different model than the planner (MODELS), the planner writes a brief for every task first.
set -u -o pipefail
# shellcheck source=common.sh
. "$(dirname "$(readlink -f "$0")")/common.sh"
need_claude && need_jq || exit 1
export PYTHONDONTWRITEBYTECODE=1           # no __pycache__ from tests or the worker in the diff
LIMIT_WAIT=${AUTOPILOT_LIMIT_WAIT:-1800}  # seconds to pause at the usage limit
WORKER_TIMEOUT=45m                        # time budget of one worker run (named in its prompt)
LOGS=$STATE/log
FEEDBACK=$STATE/feedback.txt
COSTS=$STATE/costs.csv                    # claude_run appends every Claude call here
# What must never change, whatever ALLOWED says: Git, Claude, CI and autopilot management
ALWAYS_LOCKED='^(\.git|\.claude/|\.github/|\.autopilot/|autopilot\.conf$|CLAUDE\.md$)'
# Without ALLOWED the worker may change everything else except these: they decide what the test command runs
TEST_CONTROL='(^|/)(package\.json|pyproject\.toml|pytest\.ini|setup\.cfg|tox\.ini|build\.gradle[^/]*|settings\.gradle[^/]*|gradle\.properties|Cargo\.toml|go\.mod|Makefile|[^/]*\.csproj|pom\.xml)$'
[ -d "$WORKDIR" ] || { echo "WORKDIR $WORKDIR from $CONF does not exist. Fix WORKDIR there (then: autopilot trust $CONF)." >&2; exit 1; }
cd "$WORKDIR" || exit 1
ROOT=$(pwd -P)

note() { echo "$(date '+%F %T') $1" | tee -a "$LOGS/history.log"; }
announce() { note "$2"; notify "$1" "$2" >/dev/null 2>&1 || true; }
# One run per project: a lock directory with the PID (mkdir is atomic); a lock whose PID is dead is taken over
lock=$STATE/lock
if ! mkdir "$lock" 2>/dev/null; then
    if lock_alive "$STATE"; then
        echo "Autopilot is already running for this project (PID $(cat "$lock/pid")). Wait for it to finish, or: autopilot stop [--now]" >&2; exit 1
    fi
    rm -rf "$lock"
    mkdir "$lock" 2>/dev/null || { echo "Autopilot is already running for this project (lock $lock taken just now). Wait for it to finish, or: autopilot stop [--now]" >&2; exit 1; }
fi
echo $$ >"$lock/pid"; trap 'rm -rf "$lock"' EXIT  # replaced by finish() below once it is defined
t_start=$(date '+%F %T')
rm -f "$STATE/outcome" "$STATE/HANDOVER.md" "$STATE/demo.txt"
# What `status`, `status --short` and `handover` read: they never load autopilot.conf, which may change during a run.
{ for k in NAME WORKDIR TASKS_FILE PLAN_FILE TEST_CMD DEMO_CMD ACCEPT_CMD MAX_RUNS MAX_COST_USD; do
      v=${!k}; printf '%s=%s\n' "$k" "${v//$'\n'/ }"; done
  echo "STARTED=$t_start"
  # where this start's lines begin in history.log and costs.csv (two starts may share a second)
  echo "HISTORY_FROM=$(( $(cat "$LOGS/history.log" 2>/dev/null | wc -l) + 1 ))"
  echo "COSTS_FROM=$(( $(cat "$COSTS" 2>/dev/null | wc -l) + 1 ))"; } >"$STATE/info"
costs_from=$(sed -n 's/^COSTS_FROM=//p' "$STATE/info")
# The Claude Code status line shows every project listed here (the entry stays after the end for the outcome)
mkdir -p "$CONF_BASE/running" 2>/dev/null && echo "$CONF" >"$CONF_BASE/running/$SESSION"
# Per-run logs of the previous start go to log/archive/<time>/, otherwise run-1.txt etc. would be overwritten
shopt -s nullglob; old_logs=("$LOGS"/{run,brief,review,tests,accept,rejected}-* "$LOGS"/start.txt*); shopt -u nullglob
if [ ${#old_logs[@]} -gt 0 ]; then
    archive=$LOGS/archive/$(date +%F-%H%M%S)-$$; mkdir -p "$archive" && mv "${old_logs[@]}" "$archive/"
fi
is_number() { [[ ${1:-} =~ ^[0-9]+$ ]]; }
pause() { sleep "$1" & wait $!; }  # in the background, so a signal is handled at once
open_tasks() { grep -c '^- \[ \]' "$TASKS_FILE"; }

# Last line of an output that matches the pattern → group 1 (or 2)
number_from() { # FILE PATTERN [GROUP]
    local line hit=''
    while IFS= read -r line; do [[ $line =~ $2 ]] && hit=${BASH_REMATCH[${3:-1}]}; done <"$1"
    echo "$hit"
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

# Fingerprint of the Git management (config, info, hooks): if a run changes it, the loop stops,
# because the next Git call could run code through it.
git_fingerprint() {
    local d
    for d in "$(g rev-parse --git-common-dir)" "$(g rev-parse --git-dir)"; do
        find "$d/config" "$d/info" "$d/hooks" -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do checksum "$f"; done
    done | hash_only
}

# Test, acceptance and demo command: time limit TEST_TIMEOUT (exit code 124), lower priority, and when the
# sandbox works through sandbox-run (bubblewrap): no network, a minimal /dev, read-only outside the work
# directory and a read-only .git. Runs in the background so a signal interrupts `wait` at once (a
# foreground child would delay the trap until the command ends). Afterwards .git must be unchanged:
# a test command that plants e.g. a Git filter would run it outside the sandbox on the next Git call.
run_cmd() { # COMMAND [stop]: with "stop" a STOP file ends the command (the demo)
    local rc w=()
    [ -n "$sandbox" ] && w=("$TOOL_DIR/sandbox-run")
    with_timeout "$TEST_TIMEOUT" nice -n 10 ${w[@]+"${w[@]}"} bash -c "$1" & cmd=$!
    [ -n "${2:-}" ] && while kill -0 "$cmd" 2>/dev/null; do [ -e "$STATE/STOP" ] && kill_tree "$cmd"; pause 0.5; done
    wait "$cmd"; rc=$?; cmd=''
    [ "$(git_fingerprint)" = "$fingerprint" ] ||
        { announce crit "The test command changed .git (config, info or hooks) – stopped. Please inspect before starting again."; exit 1; }
    return "$rc"
}
# Number of passed tests in $tests_n (empty if the result is red or no number can be read), the exit
# code of TEST_CMD in $tests_rc; returns 124 at the time limit.
run_tests() {
    local n
    tests_n=''
    run_cmd "$TEST_CMD" >"$1" 2>&1; tests_rc=$?
    [ "$tests_rc" = 124 ] && { echo "(time limit TEST_TIMEOUT=$TEST_TIMEOUT reached)" >>"$1"; return 124; }
    if [ "$tests_rc" -ne 0 ]; then [ "$tests_rc" = "${TEST_EMPTY_RC:--}" ] && tests_n=0; return 0; fi  # e.g. pytest: 5 = no tests
    if [ -n "$TEST_COUNT_CMD" ]; then n=$(bash -c "$TEST_COUNT_CMD" <"$1" | tail -1)
    else n=$(number_from "$1" "$TEST_COUNT_REGEX"); fi
    is_number "$n" && tests_n=$n; return 0
}
# Met acceptance conditions in $accept_n (the test may be red); empty if no number can be read.
run_accept() {
    local k
    accept_n=''
    [ -n "$ACCEPT_CMD" ] || { accept_n=0; return 0; }
    run_cmd "$ACCEPT_CMD" >"$1" 2>&1
    [ $? = 124 ] && echo "(time limit TEST_TIMEOUT=$TEST_TIMEOUT reached)" >>"$1"
    k=$(number_from "$1" "$ACCEPT_REGEX"); is_number "$k" && accept_n=$k
    return 0
}

# Work directory and submodules back to COMMIT (reset does not touch the inside of submodules)
restore() { # COMMIT
    g reset -q --hard "$1" && g clean -qfd &&
        g submodule --quiet update --force --recursive && g submodule --quiet foreach --recursive 'git clean -qffd'
}

interrupted() { # EXITCODE: Ctrl+C, kill or `autopilot stop --now` during a run
    local where="before the first run"
    trap '' INT TERM HUP
    [ -n "${worker:-}" ] && kill_tree "$worker"
    [ -n "${cmd:-}" ] && kill_tree "$cmd"  # a running test, acceptance or demo command
    wait 2>/dev/null
    restore HEAD  # not "$before": a commit made in this run (e.g. block_task) must survive
    [ "$i" -gt 0 ] && where="during run $i"
    note "Interrupted $where: work directory reset to the last commit. Resume with: autopilot start"
    [ -n "${loop_started:-}" ] && [ ! -s "$STATE/outcome" ] && handover stopped "stopped $where (stop --now or a signal)"
    exit "$1"
}

# Per-task brake that survives a restart: hash of the first open task line and its failed attempts.
task_hash() { grep -m1 '^- \[ \]' "$TASKS_FILE" | hash_only | cut -c1-16; }
save_attempts() { echo "$(task_hash) $fails" >"$STATE/attempts"; }
last_reason() { sed -n '1s/^The last attempt at this task was rejected. Reason: //p' "$FEEDBACK" 2>/dev/null; }

reject() { # BEFORE REASON [LOGFILE]: every rejection counts as a failed attempt of the task
    local patch=$LOGS/rejected-$i.patch
    g diff --cached --no-ext-diff --no-color >"$patch"; [ -s "$patch" ] || rm -f "$patch"  # the attempt, before it is reset
    restore "$1"
    note "Run $i rejected: $2"
    { echo "The last attempt at this task was rejected. Reason: $2"
      [ -f "$patch" ] && echo "Diff of your last attempt (read it with the Read tool, do not start from zero): $patch"
      [ -n "${3:-}" ] && { echo; echo "Last lines of $(basename "$3"):"; tail -40 "$3"; }; } >"$FEEDBACK"
    fails=$((fails + 1)); rejected_n=$((rejected_n + 1)); save_attempts
}

first_open_as() { # MARK <task list: the list with the first open task marked [MARK]
    awk -v m="$1" '!d && /^- \[ \]/ { sub(/^- \[ \]/, "- [" m "]"); d = 1 } 1'
}

block_task() { # REASON: mark the first open task as [~] so the loop can move on
    local open_before line; open_before=$(open_tasks); line=$(grep -m1 '^- \[ \]' "$TASKS_FILE")
    echo "- $(date +%F), $(shorten 60 <<<"${line:6}"): $1" >>BLOCKED.md
    block_first_open "$TASKS_FILE"
    [ "$(open_tasks)" -lt "$open_before" ] || { announce crit "Task could not be marked as blocked, stopped"; exit 1; }
    g add -A && g commit -q -m "Autopilot: blocked – $(shorten 100 <<<"$1")"
    note "Task blocked: $1"
    rm -f "$FEEDBACK"; fails=0
}

# Last VERDICT line without Markdown decoration (**, _, `, >) and trailing dot: "**VERDICT: ACCEPT**" → "VERDICT: ACCEPT"
verdict_line() { # FILE
    grep -E '^[[:space:]>*_`]*VERDICT[*_`]*:' "$1" | tail -1 |
        sed -E 's/^[[:space:]>*_`]+//; s/^VERDICT[*_`]*:[[:space:]*_`]*/VERDICT: /; s/[[:space:]*_`.]+$//'
}
# Second Claude with a fresh context and read-only access; prints the VERDICT line.
verdict_of() { # PROMPT-FILE LOG-NAME
    local attempt rc retried=''
    for attempt in $(seq 1 20); do
        claude_run "$LOGS/$2" reviewer --model "$REVIEWER_MODEL" --allowedTools Read Grep Glob <"$1" >/dev/null; rc=$?
        verdict_line "$LOGS/$2" | grep . && return
        if [ "$rc" = 124 ]; then  # the time limit is no judgement: once more, only then reject
            [ -z "$retried" ] && { retried=1; note "Reviewer: time limit (${CLAUDE_TIMEOUT:-20m}), trying once more" >&2; continue; }
            echo "VERDICT: REJECT: reviewer hit the time limit (${CLAUDE_TIMEOUT:-20m}) twice, see log/$2"; return
        fi
        usage_limit "$LOGS/$2" || return
        note "Reviewer: usage limit, waiting $((LIMIT_WAIT / 60)) min" >&2; pause "$LIMIT_WAIT"
    done
}
review() {
    { cat "$REVIEWER_FILE"; project_rules; echo; echo "## Task"; echo "$open_task"; echo; echo "## Diff"
      g diff --cached --no-ext-diff --no-textconv
      echo; echo "## Test output ($TEST_CMD), last lines"; tail -40 "$LOGS/tests-$i.txt"
      [ -n "$ACCEPT_CMD" ] && { echo; echo "## Acceptance test output ($ACCEPT_CMD), last lines"; tail -40 "$LOGS/accept-$i.txt"; }
    } >"$LOGS/review-prompt.txt"
    verdict_of "$LOGS/review-prompt.txt" "review-$i.txt"
}

# Demo at the end: DEMO_CMD uses the result like the owner would. Output in $STATE/demo.txt, exit code in
# $demo_rc. → 0 it works, 1 red (reason in $reason), 2 no DEMO_CMD, 3 ended by `autopilot stop`.
demo() {
    rm -f "$STATE/demo.txt"; demo_rc=''
    [ -n "$DEMO_CMD" ] || { reason="no demo: DEMO_CMD is empty, so nothing shows that the result works"; return 2; }
    run_cmd "$DEMO_CMD" stop >"$STATE/demo.txt" 2>&1; demo_rc=$?
    [ "$demo_rc" = 0 ] && return 0
    [ -e "$STATE/STOP" ] && return 3
    if [ "$demo_rc" = 124 ]; then reason="demo hit the time limit (TEST_TIMEOUT=$TEST_TIMEOUT)"; else reason="demo red (DEMO_CMD exit code $demo_rc)"; fi
    return 1
}
# Command, exit code and last lines of an output, "(no output, exit N)" when it printed nothing
proof() { # COMMAND EXITCODE FILE LINES
    echo "\`$1\` – exit code $2"
    if [ -s "$3" ]; then echo "Last lines:"; tail -"$4" "$3"; else echo "(no output, exit $2)"; fi
}

# Every end of the loop: $STATE/outcome (one line: outcome, tab, reason) and $STATE/HANDOVER.md, written by
# the shell alone (no Claude call), and the result first in the notification.
handover() { # OUTCOME REASON; OUTCOME is delivered|not-delivered|stopped|limit|error
    local b built merged='' next
    printf '%s\t%s\n' "$1" "$2" >"$STATE/outcome"
    b=$(g branch --show-current); [ -n "$b" ] || b=$(g rev-parse --short HEAD)
    { [ "$b" = "$BASE_BRANCH" ] || g merge-base --is-ancestor HEAD "$BASE_BRANCH" 2>/dev/null; } && merged=1
    built=$(g log --oneline "$BASE_BRANCH..HEAD" 2>/dev/null | cut_chars 1 100); [ -n "$built" ] || built=$(grep '^- \[x\]' "$TASKS_FILE")
    case $1 in
        delivered) if [ -n "$merged" ]; then next="try it (see above): the work is already on $BASE_BRANCH"
                   else next="try it (see above), then adopt it: in the project, on $BASE_BRANCH: git merge $b"; fi ;;
        stopped|limit) next="continue: autopilot start" ;;
        *) if grep -q '^- \[~\]' "$TASKS_FILE"; then next="read BLOCKED.md, split or solve the blocked tasks, then: autopilot start"
           elif [ -s "$STATE/suggestion.md" ]; then next="read the planner's suggestion: autopilot plan – adopt it: autopilot plan accept"
           else next="fix the cause (logs: $LOGS), then: autopilot start"; fi ;;
    esac
    {   if [ "$1" = delivered ]; then echo "# Delivered"; else echo "# Not delivered: $2"; fi
        echo "Project $NAME, $t_start to $(date '+%F %T'), $i runs, $(cost_sum "$COSTS" "$costs_from") USD this start"
        echo; echo "## What was built"; echo "${built:-nothing new}"
        echo; echo "## How to try it"; echo "${TRY_IT:-(TRY_IT is not set in autopilot.conf)}"
        if [ -n "$merged" ]; then echo "In: $ROOT"
        else echo "In the work directory $ROOT (branch $b, not merged into $BASE_BRANCH yet)"; fi
        echo; echo "## Proof"
        if [ -n "$demo_rc" ]; then echo -n "Demo: "; proof "$DEMO_CMD" "$demo_rc" "$STATE/demo.txt" 20
        elif [ -n "$DEMO_CMD" ]; then echo "Demo: not run (\`$DEMO_CMD\`)"
        else echo "Demo: none (DEMO_CMD is not set in autopilot.conf)"; fi
        echo -n "Tests: $count0 -> $count passed, "; proof "$TEST_CMD" "$last_tests_rc" "$last_tests" 5
        [ -n "$ACCEPT_CMD" ] && echo "Acceptance: $acc0 -> $acc of ${target:-?}"
        echo; echo "## Open"
        grep '^- \[~\]' "$TASKS_FILE" || echo "no blocked tasks"
        [ -s BLOCKED.md ] && { echo "Reasons (BLOCKED.md):"; tail -10 BLOCKED.md; }
        echo "Rejected runs this start: $rejected_n$( [ "$rejected_n" -gt 0 ] && echo " (diffs: $LOGS/rejected-*.patch)")"
        echo; echo "## Cost (all Claude calls of this project)"; cost_table "$COSTS"
        echo; echo "## Next step for you"; echo "$next"
    } >"$STATE/HANDOVER.md"
    if [ "$1" = delivered ]; then notify ok "Delivered: $2" >/dev/null 2>&1 || true
    else notify warn "Not delivered: $2" >/dev/null 2>&1 || true; fi
}
finish() { # EXIT trap: an end that wrote no outcome itself (crit stop) is an error with the last history line
    if [ -n "${loop_started:-}" ]; then
        [ -s "$STATE/outcome" ] || handover error "$(tail -1 "$LOGS/history.log" | cut -c21- | shorten 160)"
        save_attempts
    fi
    rm -f "$STATE/STOP"; rm -rf "$lock"
}
trap 'finish' EXIT  # handover for an end not handled explicitly, attempts saved, STOP and lock removed

# --- Planner: proposes new tasks, adopted only with `autopilot plan accept` -----------------------
# No progress: accepted runs without a higher acceptance count, persisted per acceptance level ("<acc> <count>").
np_count() { local a='' c=''; read -r a c <"$STATE/no-progress" 2>/dev/null; if [ "$a" = "$acc" ] && is_number "$c"; then echo "$c"; else echo 0; fi; }
np_add() { echo "$acc $(( $(np_count) + $1 ))" >"$STATE/no-progress"; }
run_planner() {
    local prompt
    prompt="$(cat "$PLANNER_FILE")$(plan_section)$(project_rules)

## Task list ($TASKS_FILE)
$(cat "$TASKS_FILE")

## Blocked
$(cat BLOCKED.md 2>/dev/null || echo –)

## Latest acceptance test
$(tail -40 "$(ls -t "$LOGS"/accept-*.txt 2>/dev/null | head -1)" 2>/dev/null || echo 'no acceptance test')

## Demo at the end (DEMO_CMD)
$(if [ -n "$demo_rc" ]; then proof "$DEMO_CMD" "$demo_rc" "$STATE/demo.txt" 40; else echo 'no demo ran'; fi)

## Your previous suggestion (do not repeat it, it did not reach the goal)
$(cat "$LOGS/suggestion-prev.md" 2>/dev/null || echo –)"
    claude_run "$LOGS/planner.txt" planner --model "$PLANNER_MODEL" --allowedTools Read Grep Glob <<<"$prompt" >/dev/null
    # "NOT REACHABLE: <reason>": the goal needs the owner, not more tasks (exit 2, the reason as the text)
    if grep -m1 '^NOT REACHABLE:' "$LOGS/planner.txt" | shorten 200 | grep .; then rm -f "$STATE/suggestion.md"; return 2; fi
    grep -E '^- \[ \] .*Done when' "$LOGS/planner.txt" >"$STATE/suggestion.md"
    cp "$STATE/suggestion.md" "$LOGS/suggestion-prev.md"
    if [ -s "$STATE/suggestion.md" ]; then echo "$(wc -l <"$STATE/suggestion.md") tasks proposed."
    else echo "The planner did not deliver usable tasks, see $LOGS/planner.txt"; return 1; fi
}
# A planner round counts as half of NO_PROGRESS: two rounds without progress end the loop.
plan_more() { # WHY (the loop ends here)
    local answer rc
    if [ "$(np_count)" -ge "$NO_PROGRESS" ]; then
        note "No progress${ACCEPT_CMD:+ (Accept $acc of ${target:-?})} after the planner's rounds – check the acceptance test or the demo"
        handover not-delivered "no progress${ACCEPT_CMD:+ (Accept $acc of ${target:-?})} after two planner rounds"; exit 1
    fi
    np_add $(( (NO_PROGRESS + 1) / 2 ))
    note "$1: planner drafts new tasks …"
    answer=$(run_planner); rc=$?
    if [ "$rc" = 2 ]; then note "Planner: $answer"; handover not-delivered "$answer"; exit 1; fi  # NOT REACHABLE: needs the owner
    note "Planner: $answer Read: autopilot plan – adopt: autopilot plan accept"
    handover not-delivered "$1, the planner proposed new tasks (autopilot plan)"; exit 0
}

# The worker must be able to run TEST_CMD: with Bash entries in WORKER_TOOLS one must cover its first word
# (a hook or a wrong pattern once left every run without a test, visible only as a time limit).
tools_cover_test_cmd() {
    local t p w=${TEST_CMD%% *} has=''
    for t in "${WORKER_TOOLS[@]}"; do
        case $t in
            Bash) return 0 ;;
            Bash\(*) has=1; p=${t#Bash(}; p=${p%)}; p=${p%%:*}; [ "${p%% *}" = "$w" ] || [ "$p" = '*' ] && return 0 ;;
        esac
    done
    [ -z "$has" ]
}

# File names of the staged changes, without rename detection (otherwise the old path would drop out)
changed() { g -c core.quotePath=false diff --cached --name-only --no-renames -- "$@"; }
# New or changed symlinks whose target lies outside the work directory (tests and Claude would follow them)
outside_links() {
    local f t
    g -c core.quotePath=false diff --cached --name-only --no-renames --diff-filter=d | while IFS= read -r f; do
        [ -L "$f" ] || continue
        t=$(readlink -f -- "$f") || t=''
        case "$t" in "$ROOT"/*) ;; *) echo "$f" ;; esac
    done
}
# Submodules with a new commit or edited/new files inside (mode 160000 on either side of the diff)
changed_submodules() {
    g -c core.quotePath=false diff HEAD --raw --no-renames --ignore-submodules=none |
        awk -F'\t' '$1 ~ /^:(160000 [0-7]+|[0-7]+ 160000) / {print $2}'
}

[ -n "$TEST_CMD" ] || { announce crit "TEST_CMD is not set in $CONF"; exit 1; }
[ -n "$DEMO_CMD" ] || announce warn "DEMO_CMD is not set in $CONF: the loop can never end as delivered (it ends as \"not delivered: no demo\")"
# 0.8 locked the acceptance test through ACCEPT_FILES; ignoring it silently would leave those files unlocked
[ -n "${ACCEPT_FILES+x}" ] && { announce crit "ACCEPT_FILES in $CONF is gone since 0.9: move its paths into LOCKED=(…), then: autopilot trust"; exit 1; }
bad=$(bad_patterns); [ -z "$bad" ] || { announce crit "$(echo $bad) in $CONF is not a valid regular expression (grep -E)"; exit 1; }
claude --help 2>/dev/null | grep -q -- '--safe-mode' || { announce crit "claude is too old for --safe-mode (needs Claude Code >= 2.1): update it"; exit 1; }
tools_cover_test_cmd || { announce crit "No Bash entry in WORKER_TOOLS covers the test command \"${TEST_CMD%% *} …\" in $CONF: the worker could never run it (e.g. 'Bash(${TEST_CMD%% *}:*)')"; exit 1; }
[ -f "$TASKS_FILE" ] || { announce crit "Task list $WORKDIR/$TASKS_FILE is missing"; exit 1; }
sandbox=''
if [ "$SANDBOX" != off ]; then
    if sandbox_works; then sandbox=1
    else announce warn "No sandbox: bubblewrap is missing or cannot start here – test commands run unsandboxed. $(install_hint bubblewrap), or set SANDBOX=off to silence this"; fi
fi
[ -n "$(g status --porcelain)" ] && { announce crit "Work directory not clean, aborting"; exit 1; }
g var GIT_COMMITTER_IDENT >/dev/null 2>&1 || { announce crit "Git cannot commit in $WORKDIR: no identity. Set one: git config --global user.email you@example.org; git config --global user.name \"Your Name\""; exit 1; }

i=0; acc=0; cost=0; worker=''; cmd=''; reason=''; rejected_n=0; demo_rc=''
fingerprint=$(git_fingerprint)  # before the first run_cmd: it checks .git after every test command
trap 'interrupted 130' INT; trap 'interrupted 143' TERM; trap 'interrupted 129' HUP  # HUP: tmux session killed
run_tests "$LOGS/start.txt" || { announce crit "Tests hit the time limit (TEST_TIMEOUT=$TEST_TIMEOUT) before the start, see $LOGS/start.txt"; exit 1; }
count=$tests_n; last_tests=$LOGS/start.txt; last_tests_rc=$tests_rc
if [ -z "$count" ]; then
    # exit code 127 = command not found; a missing Python module exits 1 but names itself in the output
    hint=$(grep -m1 -iE 'command not found|No module named|No such file or directory' "$LOGS/start.txt" | cut_chars 1 160)
    if [ "$tests_rc" = 127 ] || [ -n "$hint" ]; then
        try=$(suggest_install "$TEST_CMD" "$tests_rc" "$LOGS/start.txt")
        announce crit "Test command cannot run (missing tool?): ${hint:-exit code 127}, see $LOGS/start.txt${try:+ – $try}"
    else
        announce crit "Tests already red before the start or without a readable number, see $LOGS/start.txt"
    fi
    exit 1
fi
run_accept "$LOGS/accept-start.txt"; acc=$accept_n
target=$( [ -n "$ACCEPT_CMD" ] && number_from "$LOGS/accept-start.txt" "$ACCEPT_REGEX" 2 )
is_number "$target" || target=''
[ -n "$ACCEPT_CMD" ] && { [ -n "$acc" ] && [ -n "$target" ] || { announce crit "Acceptance test without a readable \"k of n\" line (ACCEPT_REGEX=$ACCEPT_REGEX), see $LOGS/accept-start.txt – the goal could never be measured"; exit 1; }; }
acc=${acc:-0}; count0=$count; acc0=$acc
announce info "Start: $count tests green${ACCEPT_CMD:+, Accept $acc of ${target:-?}}, at most $MAX_RUNS runs or $MAX_COST_USD USD, models $MODELS (planner $PLANNER_MODEL, worker $WORKER_MODEL, reviewer $REVIEWER_MODEL), sandbox ${sandbox:+on}${sandbox:-off}"

# Brake of the first open task from the last start (same task: counter and feedback kept)
fails=0; last=''
h=''; f=''; [ -r "$STATE/attempts" ] && read -r h f <"$STATE/attempts"
if [ -n "$h" ] && [ "$h" = "$(task_hash)" ] && is_number "$f" && [ "$f" -gt 0 ]; then
    fails=$f; last=$(grep -m1 '^- \[ \]' "$TASKS_FILE")
    note "Same task as last time: $fails failed attempts so far – counter and feedback kept"
else rm -f "$FEEDBACK"; fi
waits=0; last_denied=''; loop_started=1
while :; do
    [ -e "$STATE/STOP" ] && { note "Stopped via STOP after $i runs"; handover stopped "stopped by you after $i runs"; exit 0; }
    if [ "$(open_tasks)" = 0 ]; then
        if [ -z "$ACCEPT_CMD" ] || [ "$acc" = "${target:-x}" ]; then
            reason=''; demo; r=$?
            [ "$r" = 3 ] && { note "Demo stopped via STOP"; handover stopped "stopped by you during the demo"; exit 0; }
            if [ "$r" = 1 ]; then
                note "All tasks done, but $reason (see $STATE/demo.txt)"
                [ "$PLANNER" = on ] && plan_more "Demo red"
                handover not-delivered "demo failed: $reason"; exit 1
            fi
            blocked=$(grep -c '^- \[~\]' "$TASKS_FILE")
            if [ "$blocked" -gt 0 ]; then
                note "Goal reached: all tasks done except $blocked blocked (see BLOCKED.md)${ACCEPT_CMD:+, Accept $acc of $target}."
                handover not-delivered "$blocked tasks blocked"
            elif [ "$r" = 2 ]; then
                note "Goal reached: all tasks done${ACCEPT_CMD:+, Accept $acc of $target}, but $reason"
                handover not-delivered "$reason"
            else
                note "Goal reached: all tasks done${ACCEPT_CMD:+, Accept $acc of $target}, demo green."
                handover delivered "all tasks done${ACCEPT_CMD:+, Accept $acc of $target}, demo green"
            fi
        elif [ "$PLANNER" = on ]; then plan_more "No open tasks, Accept only $acc of ${target:-?}"
        else note "No open tasks left, Accept only $acc of ${target:-?}: new tasks needed"; handover not-delivered "Accept $acc of ${target:-?}, new tasks needed"; fi
        exit 0
    fi
    [ "$fails" -ge "$ATTEMPTS" ] && { block_task "$fails failed attempts, last: $(last_reason | shorten 120)"; continue; }
    [ "$(grep -c '^- \[~\]' "$TASKS_FILE")" -ge "$MAX_BLOCKED" ] &&
        { announce crit "$MAX_BLOCKED tasks blocked, please check BLOCKED.md"; handover not-delivered "$MAX_BLOCKED tasks blocked (MAX_BLOCKED), see BLOCKED.md"; exit 1; }
    [ "$i" -ge "$MAX_RUNS" ] && { note "Run cap reached: $MAX_RUNS runs"; handover limit "run cap MAX_RUNS=$MAX_RUNS reached, $(open_tasks) tasks still open"; exit 0; }
    spent=$(cost_sum "$COSTS" "$costs_from")
    awk -v s="$spent" -v m="$MAX_COST_USD" 'BEGIN { exit !(s >= m) }' &&
        { note "Cost cap reached: $spent USD"; handover limit "cost cap MAX_COST_USD=$MAX_COST_USD reached ($spent USD), $(open_tasks) tasks still open"; exit 0; }

    i=$((i + 1)); before=$(g rev-parse HEAD); cost=0
    open_task=$(grep -m1 '^- \[ \]' "$TASKS_FILE")
    [ "$open_task" != "$last" ] && { last=$open_task; fails=0; rm -f "$FEEDBACK"; }
    save_attempts
    note "Run $i: $(shorten 80 <<<"${open_task:6}")"
    prompt=$(cat "$PROMPT_FILE")
    # Quoted replacements: taken literally (no & from bash 5.2 patsub_replacement, no backslash handling)
    prompt=${prompt//\{TASKS_FILE\}/"$TASKS_FILE"}
    prompt=${prompt//\{DECISIONS_FILE\}/"$DECISIONS_FILE"}
    prompt=${prompt//\{TEST_CMD\}/"$TEST_CMD"}
    prompt=${prompt//\{ACCEPT_CMD\}/"${ACCEPT_CMD:-(no acceptance test)}"}
    prompt+=$'\n\n## This run\n'"Time budget: $WORKER_TIMEOUT, then the run is aborted and reset. Attempt $((fails + 1)) of at most $ATTEMPTS for this task (then it is blocked)."
    prompt+=$(project_rules)
    [ -s "$FEEDBACK" ] && prompt+=$'\n\n## Feedback on the previous attempt\n'"$(cat "$FEEDBACK")"
    # Brief: the (stronger) planner plans the task with the whole plan, the (cheaper) worker implements it.
    # Without a brief the worker gets the plan itself.
    brief_ok=''
    if [ "$PLANNER_MODEL" != "$WORKER_MODEL" ]; then
        brief=$(cat "$BRIEF_FILE"; plan_section; project_rules; printf '\n\n## Task\n%s\n' "$open_task"
                [ -s "$FEEDBACK" ] && { printf '\n## Feedback on the previous attempt\n'; cat "$FEEDBACK"; })
        if claude_run "$LOGS/brief-$i.txt" brief --model "$PLANNER_MODEL" --allowedTools Read Grep Glob <<<"$brief" >/dev/null &&
           [ -s "$LOGS/brief-$i.txt" ]; then
            brief_ok=1; prompt+=$'\n\n## Brief from the planner\n'"$(cat "$LOGS/brief-$i.txt")"
        else note "Run $i: no brief from the planner ($PLANNER_MODEL), the worker gets the plan instead"; fi
    fi
    [ -n "$brief_ok" ] || prompt+=$(plan_section)
    # In the background so that a signal interrupts `wait` at once (a foreground child delays the trap)
    # --add-dir: the logs (rejected-N.patch) may lie outside the work directory (worktree case)
    CLAUDE_TIMEOUT=$WORKER_TIMEOUT claude_run "$LOGS/run-$i.txt" worker --model "$WORKER_MODEL" --permission-mode acceptEdits \
        --add-dir "$LOGS" --allowedTools "${WORKER_TOOLS[@]}" <<<"$prompt" >"$STATE/worker-cost" & worker=$!
    wait "$worker"; rc=$?; worker=''; cost=$(cat "$STATE/worker-cost" 2>/dev/null); cost=${cost:-0}

    # Did the run change the Git management (hooks, config)? Then stop immediately.
    if [ "$(git_fingerprint)" != "$fingerprint" ]; then
        announce crit "Run $i changed .git (config, info or hooks) – stopped. Please inspect before starting again."
        exit 1
    fi

    # Subscription usage limit: wait instead of using up a run or an attempt (at most 20 times).
    if [ "$rc" -ne 0 ] && usage_limit "$LOGS/run-$i.txt"; then
        restore "$before"
        t=$(limit_reset "$LOGS/run-$i.txt"); i=$((i - 1)); waits=$((waits + 1))
        [ "$waits" -gt 20 ] && { announce crit "Usage limit persists, stopped"; exit 1; }
        note "Usage limit${t:+ (resets $t)}, waiting $((LIMIT_WAIT / 60)) min"; pause "$LIMIT_WAIT"; continue
    fi

    # Any other error reported by Claude (login, network …): retrying only burns runs, so stop without counting an attempt.
    if [ "$rc" -ne 0 ] && err=$(jq -er 'select(.is_error == true) | .result // "unknown error"' "$LOGS/run-$i.txt.json" 2>/dev/null); then
        restore "$before"
        announce crit "Run $i: Claude reported an error: $(head -1 <<<"$err" | shorten 200) – fix it (e.g. claude /login, check the network), then start again"
        exit 1
    fi

    # Tool calls Claude Code refused: name them per tool, otherwise a run without e.g. the build command only
    # ends in a time-out with no visible reason.
    denied=$(jq -r '[.permission_denials[]? |
        if .tool_name == "Bash" then "Bash `\(.tool_input.command // "?")` (not covered by WORKER_TOOLS)"
        elif (.tool_name | test("^(Edit|Write|MultiEdit|NotebookEdit)$")) then
            "\(.tool_name) \(.tool_input.file_path // .tool_input.notebook_path // "?") (Claude Code refused the write: outside the work directory, below ~/.claude or a protected path)"
        else "\(.tool_name) (not in WORKER_TOOLS)" end] | unique | .[:3] | join(" | ")' \
        "$LOGS/run-$i.txt.json" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//' | shorten 400)
    [ -n "$denied" ] && { last_denied=$denied; note "Run $i: tool calls denied: $denied"; }

    # Script checks: only green, not weakened work in allowed paths counts.
    g add -A
    task=$(g diff --cached --no-ext-diff -U0 -- "$TASKS_FILE" | grep -m1 '^+- \[[x~]\]' | cut -c4- | shorten 90)
    if [ "$rc" -eq 124 ]; then
        # Time limit: say so, with what was refused (this run has no readable answer, so the last one that had)
        reject "$before" "aborted after $WORKER_TIMEOUT (time limit): work smaller, or block early with [~]${last_denied:+; denied tool calls from the last readable run: $last_denied}" "$LOGS/run-$i.txt"
        continue
    fi
    if [ -z "$task" ]; then
        reject "$before" "no task ticked off or blocked (rc $rc)${denied:+; denied tool calls: $denied}" "$LOGS/run-$i.txt"; continue
    fi
    # The only allowed change to the task list: the first open task ticked off [x] or blocked [~]
    old_tasks=$(g show "$before:$TASKS_FILE"); now_tasks=$(cat "$TASKS_FILE")
    if [ "$now_tasks" != "$(first_open_as x <<<"$old_tasks")" ] && [ "$now_tasks" != "$(first_open_as '~' <<<"$old_tasks")" ]; then
        reject "$before" "task list changed beyond ticking off or blocking the first open task (only [ ] -> [x] or [~] of that line is allowed)"; continue
    fi
    # Blocking means giving up: nothing but the task list, BLOCKED.md and the decisions may change
    if [[ $task == '[~]'* ]] && extra=$(changed | grep -vxF -e "$TASKS_FILE" -e BLOCKED.md -e "$DECISIONS_FILE") && [ -n "$extra" ]; then
        reject "$before" "code changed while blocking the task: revert your code changes before blocking ($(echo $extra | shorten 120))"; continue
    fi
    subs=$(changed_submodules)
    if [ -n "$subs" ]; then reject "$before" "change inside a submodule: $(echo $subs)"; continue; fi
    # Task list, BLOCKED.md and the decisions are always allowed; ALLOWED (if set) is the rest, otherwise
    # everything except the files that control the test command.
    if [ -n "$ALLOWED" ]; then
        foreign=$(changed | grep -vxF -e "$TASKS_FILE" -e BLOCKED.md -e "$DECISIONS_FILE" | grep -Ev -- "$ALLOWED")
        [ $? -le 1 ] || { reject "$before" "ALLOWED check failed (invalid pattern?)"; continue; }
        if [ -n "$foreign" ]; then reject "$before" "change outside allowed paths: $(echo $foreign)"; continue; fi
    else
        foreign=$(changed | grep -E -- "$TEST_CONTROL")
        if [ -n "$foreign" ]; then reject "$before" "change to a file that controls the test command: $(echo $foreign) (allow it through ALLOWED in autopilot.conf)"; continue; fi
    fi
    locked=$( { changed | grep -E "$ALWAYS_LOCKED"
                for p in ${LOCKED[@]+"${LOCKED[@]}"}; do changed "$p"; done; } | sort -u)
    if [ -n "$locked" ]; then reject "$before" "locked file changed: $(echo $locked)"; continue; fi
    links=$(outside_links)
    if [ -n "$links" ]; then reject "$before" "symlink pointing outside the work directory: $(echo $links)"; continue; fi
    added=$(g diff --cached --no-ext-diff --no-renames -U0 -- . ":(exclude)$TASKS_FILE" ":(exclude)BLOCKED.md" ":(exclude)$DECISIONS_FILE" |
        grep '^+' | grep -v '^+++' | sed 's/^+//')
    if [ -n "$FORBIDDEN_CONTENT" ]; then
        grep -qE -- "$FORBIDDEN_CONTENT" <<<"$added"; r=$?  # 1 = no hit; 0 = hit, 2 = check failed: both reject
        [ "$r" = 1 ] || { reject "$before" "forbidden content added or check failed (pattern: $FORBIDDEN_CONTENT)"; continue; }
    fi
    # New code that prints the count line itself could fake the check (pattern without ^/$, because in code
    # the line sits in the middle of a print/echo). Documentation is not run, so it may quote the line.
    fake_t=${TEST_COUNT_REGEX#^}; fake_t=${fake_t%\$}; fake_a=${ACCEPT_REGEX#^}; fake_a=${fake_a%\$}
    code=$(g diff --cached --no-ext-diff --no-renames -U0 -- . ":(exclude)$TASKS_FILE" ":(exclude)BLOCKED.md" ":(exclude)$DECISIONS_FILE" \
        ":(exclude)*.md" ":(exclude)*.rst" | grep '^+' | grep -v '^+++' | sed 's/^+//')
    hit=$( { [ -z "$TEST_COUNT_CMD" ] && grep -m1 -E "$fake_t" <<<"$code"; } || { [ -n "$ACCEPT_CMD" ] && grep -m1 -E "$fake_a" <<<"$code"; } )
    if [ -n "$hit" ]; then
        reject "$before" "new code contains the count line of the test command or acceptance test (could fake the result): $hit"; continue
    fi
    run_tests "$LOGS/tests-$i.txt" || { reject "$before" "tests hit the time limit (TEST_TIMEOUT=$TEST_TIMEOUT)" "$LOGS/tests-$i.txt"; continue; }
    new=$tests_n
    if [ -z "$new" ]; then reject "$before" "tests red or without a readable number" "$LOGS/tests-$i.txt"; continue; fi
    if [ "$new" -lt "$count" ]; then reject "$before" "tests dropped from $count to $new"; continue; fi
    ticked=$(( $(grep -c '^- \[x\]' "$TASKS_FILE") - $(g show "$before:$TASKS_FILE" | grep -c '^- \[x\]') ))
    if [ "$ticked" -gt 0 ] && [ "$new" -le "$count" ]; then reject "$before" "task ticked off without a new test"; continue; fi
    run_accept "$LOGS/accept-$i.txt"; acc_new=$accept_n
    if [ -z "$acc_new" ]; then reject "$before" "acceptance test without a readable number (crashed or time limit?)" "$LOGS/accept-$i.txt"; continue; fi
    if [ "$acc_new" -lt "$acc" ]; then reject "$before" "Accept dropped from $acc to $acc_new" "$LOGS/accept-$i.txt"; continue; fi
    # Files the test or acceptance command wrote were never checked above, so nothing may be staged
    # after the checks: the commit takes exactly the index staged before those commands ran.
    # Ignored files (caches like __pycache__/) do not show up here and stay allowed.
    drift=$(g -c core.quotePath=false status --porcelain --untracked-files=all | grep -v '^[MADRCT] ')
    if [ -n "$drift" ]; then reject "$before" "test command changed files: $(echo $drift | shorten 200)"; continue; fi

    # Reviewer: only for completed tasks
    if [ "$ticked" -gt 0 ]; then
        verdict=$(review)
        if [ "${verdict:-}" != "VERDICT: ACCEPT" ]; then
            reason=${verdict#VERDICT: REJECT: }; [ -n "$reason" ] || reason="no verdict, see log/review-$i.txt"
            reject "$before" "Reviewer: $reason"; continue
        fi
    fi

    g commit -q --no-verify -m "Autopilot: $task" -m "Tests $count -> $new${ACCEPT_CMD:+, Accept $acc -> $acc_new of ${target:-?}}" ||
        { reject "$before" "commit failed"; continue; }
    note "Run $i accepted: $task | Tests $count -> $new${ACCEPT_CMD:+, Accept $acc -> $acc_new of ${target:-?}} | worker $cost USD"
    progress=1; [ -n "$ACCEPT_CMD" ] && [ "$acc_new" -le "$acc" ] && [ "$acc_new" != "${target:-x}" ] && progress=''
    count=$new; acc=$acc_new; last_tests=$LOGS/tests-$i.txt; last_tests_rc=$tests_rc; fails=0; rm -f "$FEEDBACK"
    # Accepted runs without acceptance progress: the tasks miss the goal, more of them would not help
    if [ -z "$progress" ]; then
        np_add 1
        [ "$(np_count)" -ge "$NO_PROGRESS" ] && {
            note "No progress: Accept has not risen for $NO_PROGRESS accepted runs (stays at $acc of ${target:-?}) – stopped, the tasks do not lead to the goal"
            handover not-delivered "no progress: Accept $acc of ${target:-?} unchanged for $NO_PROGRESS accepted runs"; exit 1; }
    fi
done
