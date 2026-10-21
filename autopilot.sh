#!/usr/bin/env bash
# autopilot-loop: a feedback loop of worker, script checks, reviewer and a locked goal (plan/acceptance test).
# Claude Code works through the task list, one task per run, with a fresh context and without Git.
# This script then checks the result itself, lets a second Claude judge it and commits only what passes
# everything; otherwise it resets and feeds the reason into the next attempt. Plus: grades and licence per
# task kind, cost per run, stall warning, planner for new tasks, optional smoke test with image review.
#
# Important: the checks protect quality, they are not a security boundary. The test command runs code that
# Claude wrote. Run plans or projects from others only inside a container or a VM.
#
# Normally started from the menu (`autopilot`, in Claude Code `/autopilot-loop`).
# Environment: MAX (runs, 30), MAX_REJECTIONS (rejections in a row, 3), MAX_BLOCKED (blocked tasks, 3),
#              PLANNER_MODEL (opus), WORKER_MODEL (opus), REVIEWER_MODEL (sonnet), AUTOPILOT_CONF (configuration)
# If the worker is a different model than the planner, the planner writes a brief for every task first.
set -u -o pipefail
# shellcheck source=common.sh
. "$(dirname "$(readlink -f "$0")")/common.sh"
need_claude && need_jq || exit 1
MAX=${MAX:-30}
MAX_REJECTIONS=${MAX_REJECTIONS:-3}
MAX_BLOCKED=${MAX_BLOCKED:-3}
PLANNER_MODEL=${PLANNER_MODEL:-opus}
WORKER_MODEL=${WORKER_MODEL:-opus}
REVIEWER_MODEL=${REVIEWER_MODEL:-sonnet}
export PYTHONDONTWRITEBYTECODE=1           # no __pycache__ from tests or the worker in the diff
LIMIT_WAIT=${AUTOPILOT_LIMIT_WAIT:-1800}  # seconds to pause at the usage limit
POLL=${AUTOPILOT_POLL:-20}                # seconds between two checks for `autopilot continue`
WORKER_TIMEOUT=45m                        # time budget of one worker run (named in its prompt)
LOGS=$STATE/log
FEEDBACK=$STATE/feedback.txt
CSV=$LOGS/progress.csv
HEADER="time;run;result;open_tasks;tests;accept;seconds;cost_usd;kind;worker;reviewer;planner"
# What must never change, whatever ALLOWED says: Git, Claude, CI and autopilot management
ALWAYS_LOCKED='^(\.git|\.claude/|\.github/|\.autopilot/|autopilot\.conf$|CLAUDE\.md$)'
[ -d "$WORKDIR" ] || { echo "WORKDIR $WORKDIR from $CONF does not exist. Fix WORKDIR there (then: autopilot trust $CONF)." >&2; exit 1; }
cd "$WORKDIR" || exit 1
ROOT=$(pwd -P)

note() { echo "$(date '+%F %T') $1" | tee -a "$LOGS/history.log"; }
announce() { note "$2"; notify "$1" "$2" >/dev/null 2>&1 || true; }
# One run per project: a lock directory with the PID (mkdir is atomic); a lock whose PID is dead is taken over
lock=$STATE/lock
if ! mkdir "$lock" 2>/dev/null; then
    pid=''; read -r pid <"$lock/pid" 2>/dev/null
    if [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
        echo "Autopilot is already running for this project (PID $pid). Wait for it to finish, or: autopilot continue / autopilot stop / autopilot abort." >&2; exit 1
    fi
    rm -rf "$lock"
    mkdir "$lock" 2>/dev/null || { echo "Autopilot is already running for this project (lock $lock taken just now). Wait for it to finish, or: autopilot stop / autopilot abort." >&2; exit 1; }
fi
echo $$ >"$lock/pid"; trap 'rm -rf "$lock"' EXIT  # replaced by finish() below once it is defined
# Move older progress files with different columns aside
[ -s "$CSV" ] && [ "$(head -1 "$CSV")" != "$HEADER" ] && mv "$CSV" "$LOGS/progress-$(date +%F-%H%M%S).csv"
# Per-run logs of the previous start go to log/archive/<time>/, otherwise run-1.txt etc. would be overwritten
shopt -s nullglob; old_logs=("$LOGS"/{run,brief,review,tests,accept,smoke,image-review,rejected}-* "$LOGS"/start.txt*); shopt -u nullglob
if [ ${#old_logs[@]} -gt 0 ]; then
    archive=$LOGS/archive/$(date +%F-%H%M%S)-$$; mkdir -p "$archive" && mv "${old_logs[@]}" "$archive/"
fi
record() { # RESULT
    [ -s "$CSV" ] || echo "$HEADER" >"$CSV"
    echo "$(date '+%F %T');$i;$1;$(grep -c '^- \[ \]' "$TASKS_FILE");$count;$acc;$(( $(date +%s) - start ));$cost;$kind;$WORKER_MODEL;$REVIEWER_MODEL;$PLANNER_MODEL" >>"$CSV"
}
add() { case "$1${2:-}" in *\?*) echo '?' ;; *) echo "$1 ${2:-0}" | awk '{printf "%.4f", $1 + $2}' ;; esac; }  # ? = unknown stays unknown
add_extra_cost() { # add the cost of reviewer and image review to the run
    [ -s "$STATE/cost-extra" ] || return 0
    cost=$(add "$cost" "$(awk '{s += $1} END {print s + 0}' "$STATE/cost-extra")"); rm -f "$STATE/cost-extra"
}
is_number() { [[ ${1:-} =~ ^[0-9]+$ ]]; }

# Fingerprint of the Git management (config, info, hooks): if a run changes it, the loop stops,
# because the next Git call could run code through it.
git_fingerprint() {
    local d
    for d in "$(g rev-parse --git-common-dir)" "$(g rev-parse --git-dir)"; do
        find "$d/config" "$d/info" "$d/hooks" -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do checksum "$f"; done
    done | hash_only
}

# Grade for the task kind; grants or revokes the licence
grade() { # GRADE (1 accepted, 0 rejected)
    local n s q
    echo "$(date '+%F %T');$kind;$1" >>"$STATE/grades.csv"
    read -r n s < <(rate "$kind"); q=$(( 100 * s / n ))
    if ! has_licence "$kind" && [ "$n" -ge "$LICENCE_MIN_RUNS" ] && [ "$q" -ge "$LICENCE_MIN_RATE" ]; then
        touch "$STATE/licence/$kind"; announce ok "Licence granted for task kind \"$kind\": $q % over $n runs"
    elif has_licence "$kind" && [ "$q" -lt "$LICENCE_REVOKE_BELOW" ]; then
        rm -f "$STATE/licence/$kind"; announce warn "Licence for \"$kind\" revoked: only $q % – supervised again"
    fi
}

# Test, acceptance and smoke command: time limit TEST_TIMEOUT (exit code 124), lower priority, and with
# SANDBOX=on through sandbox-run (bubblewrap): no network, a minimal /dev, read-only outside the work
# directory and a read-only .git. Runs in the background so a signal interrupts `wait` at once (a
# foreground child would delay the trap until the command ends). Afterwards .git must be unchanged:
# a test command that plants e.g. a Git filter would run it outside the sandbox on the next Git call.
run_cmd() { # COMMAND
    local rc
    if [ "$SANDBOX" = on ]; then
        with_timeout "$TEST_TIMEOUT" nice -n 10 "$TOOL_DIR/sandbox-run" bash -c "$1" & cmd=$!
    else with_timeout "$TEST_TIMEOUT" nice -n 10 bash -c "$1" & cmd=$!; fi
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

# Ends a process tree, children first (POSIX ps only, for macOS)
kill_tree() { local c; for c in $(ps -A -o pid= -o ppid= | awk -v p="$1" '$2 == p {print $1}'); do kill_tree "$c"; done; kill "$1" 2>/dev/null; }

interrupted() { # EXITCODE: Ctrl+C / kill during a run
    trap '' INT TERM HUP
    [ -n "${worker:-}" ] && kill_tree "$worker"
    [ -n "${cmd:-}" ] && kill_tree "$cmd"  # a running test/acceptance/smoke command
    wait 2>/dev/null
    restore HEAD  # not "$before": a commit made in this run (e.g. block_task) must survive
    note "Run $i interrupted (signal): work directory reset to the last commit. Resume with: autopilot start"
    [ -n "${loop_started:-}" ] && [ ! -s "$STATE/outcome" ] && handover stopped "aborted during run $i (signal)"
    exit "$1"
}

reject() { # BEFORE REASON [LOGFILE]
    local patch=$LOGS/rejected-$i.patch
    g diff --cached --no-ext-diff --no-color >"$patch"; [ -s "$patch" ] || rm -f "$patch"  # the attempt, before it is reset
    restore "$1"
    note "Run $i rejected: $2"
    { echo "The last attempt at this task was rejected. Reason: $2"
      [ -f "$patch" ] && echo "Diff of your last attempt (read it with the Read tool, do not start from zero): $patch"
      [ -n "${3:-}" ] && { echo; echo "Last lines of $(basename "$3"):"; tail -40 "$3"; }; } >"$FEEDBACK"
    failures=$((failures + 1)); rejected_n=$((rejected_n + 1)); record rejected; grade 0
}

first_open_as() { # MARK <task list: the list with the first open task marked [MARK]
    awk -v m="$1" '!d && /^- \[ \]/ { sub(/^- \[ \]/, "- [" m "]"); d = 1 } 1'
}

block_task() { # REASON: mark the first open task as [~] so the loop can move on
    local open_before; open_before=$(grep -c '^- \[ \]' "$TASKS_FILE")
    echo "- $(date +%F), $(grep -m1 '^- \[ \]' "$TASKS_FILE" | cut_chars 7 60): $1" >>BLOCKED.md
    block_first_open "$TASKS_FILE"
    [ "$(grep -c '^- \[ \]' "$TASKS_FILE")" -lt "$open_before" ] || { announce crit "Task could not be marked as blocked, stopped"; exit 1; }
    g add -A && g commit -q -m "Autopilot: blocked – $1"
    note "Task blocked: $1"
    rm -f "$FEEDBACK"; attempts=0; failures=0; rejections=0; timeouts=0
}

# Per-task brakes that survive a restart: hash of the first open task line, attempts, rejections in a row,
# reviewer rejections, time limits. A different task than saved resets them (and the feedback).
task_hash() { grep -m1 '^- \[ \]' "$TASKS_FILE" | hash_only | cut -c1-16; }
save_attempts() { echo "$(task_hash) $attempts $failures $rejections $timeouts" >"$STATE/attempts"; }

# Last VERDICT line without Markdown decoration (**, _, `, >) and trailing dot: "**VERDICT: ACCEPT**" → "VERDICT: ACCEPT"
verdict_line() { # FILE
    grep -E '^[[:space:]>*_`]*VERDICT[*_`]*:' "$1" | tail -1 |
        sed -E 's/^[[:space:]>*_`]+//; s/^VERDICT[*_`]*:[[:space:]*_`]*/VERDICT: /; s/[[:space:]*_`.]+$//'
}
# Second Claude with a fresh context and read-only access; prints the VERDICT line.
verdict_of() { # PROMPT-FILE LOG-NAME
    local attempt k rc retried=''
    for attempt in $(seq 1 20); do
        k=$(claude_run "$LOGS/$2" --model "$REVIEWER_MODEL" --allowedTools Read Grep Glob <"$1"); rc=$?
        echo "$k" >>"$STATE/cost-extra"  # runs in a subshell: return the cost through a file
        verdict_line "$LOGS/$2" | grep . && return
        if [ "$rc" = 124 ]; then  # the time limit is no judgement: once more, only then reject
            [ -z "$retried" ] && { retried=1; note "Reviewer: time limit (${CLAUDE_TIMEOUT:-20m}), trying once more" >&2; continue; }
            echo "VERDICT: REJECT: reviewer hit the time limit (${CLAUDE_TIMEOUT:-20m}) twice, see log/$2"; return
        fi
        usage_limit "$LOGS/$2" || return
        note "Reviewer: usage limit, waiting $((LIMIT_WAIT / 60)) min" >&2; sleep "$LIMIT_WAIT"
    done
}
review() {
    { cat "$REVIEWER_FILE"; plan_section; project_rules; echo; echo "## Task"; echo "$open_task"; echo; echo "## Diff"
      g diff --cached --no-ext-diff --no-textconv
      echo; echo "## Test output ($TEST_CMD), last lines"; tail -40 "$LOGS/tests-$i.txt"
      [ -n "$ACCEPT_CMD" ] && { echo; echo "## Acceptance test output ($ACCEPT_CMD), last lines"; tail -40 "$LOGS/accept-$i.txt"; }
    } >"$LOGS/review-prompt.txt"
    verdict_of "$LOGS/review-prompt.txt" "review-$i.txt"
}

# Optional real test; with IMAGE_REVIEW_FILE the reviewer also judges the image it produced.
smoke_test() { # → 0 passed, otherwise the reason in $reason
    [ -n "$SMOKE_TEST_CMD" ] || return 0
    run_cmd "$SMOKE_TEST_CMD" >"$LOGS/smoke-$i.txt" 2>&1
    case $? in 0) ;; 124) reason="smoke test hit the time limit (TEST_TIMEOUT=$TEST_TIMEOUT)"; return 1 ;; *) reason="smoke test red"; return 1 ;; esac
    [ -n "$IMAGE_REVIEW_FILE" ] || return 0
    [ -f "$IMAGE_REVIEW_FILE" ] || { reason="smoke test produced no image ($IMAGE_REVIEW_FILE)"; return 1; }
    printf '%s\n\nRead the image %s with the Read tool. Question: %s\nThe last line must be: VERDICT: ACCEPT or VERDICT: REJECT: <reason>\n' \
        "You are the reviewer and are looking at a result image." "$(readlink -f "$IMAGE_REVIEW_FILE")" "$IMAGE_REVIEW_QUESTION" >"$LOGS/image-review-prompt.txt"
    local u; u=$(verdict_of "$LOGS/image-review-prompt.txt" "image-review-$i.txt")
    [ "$u" = "VERDICT: ACCEPT" ] || { reason="Image review: ${u#VERDICT: REJECT: }"; return 1; }
}

# Demo at the end: DEMO_CMD uses the result like the owner would; without it the smoke test (with its image
# review) stands in. Output in $STATE/demo.txt. → 0 it works, 1 red (reason in $reason), 2 nothing to show.
demo() {
    local r
    rm -f "$STATE/demo.txt"
    if [ -n "$DEMO_CMD" ]; then
        run_cmd "$DEMO_CMD" >"$STATE/demo.txt" 2>&1; r=$?
        case $r in 0) return 0 ;; 124) reason="demo hit the time limit (TEST_TIMEOUT=$TEST_TIMEOUT)" ;; *) reason="demo red (DEMO_CMD exit code $r)" ;; esac
        return 1
    fi
    [ -n "$SMOKE_TEST_CMD" ] || { reason="no demo: DEMO_CMD and SMOKE_TEST_CMD are empty, so nothing shows that the result works"; return 2; }
    local keep=$i; i=end; smoke_test; r=$?; i=$keep; add_extra_cost  # smoke-end.txt: the last run's log stays
    cp "$LOGS/smoke-end.txt" "$STATE/demo.txt" 2>/dev/null
    return "$r"
}

# Every end of the loop: $STATE/outcome (one line: outcome, tab, reason) and $STATE/HANDOVER.md, written by
# the shell alone (no Claude call), and the result first in the notification.
handover() { # OUTCOME REASON; OUTCOME is delivered|not-delivered|stopped|limit|error
    local b built spent unknown next merge
    printf '%s\t%s\n' "$1" "$2" >"$STATE/outcome"
    b=$(g branch --show-current); [ -n "$b" ] || b=$(g rev-parse --short HEAD)
    [ "$b" = "$BASE_BRANCH" ] && merge="the work is directly on $b, nothing to merge" || merge="in the project, on $BASE_BRANCH: git merge $b"
    built=$(g log --oneline "$BASE_BRANCH..HEAD" 2>/dev/null | cut_chars 1 100); [ -n "$built" ] || built=$(grep '^- \[x\]' "$TASKS_FILE")
    read -r spent unknown < <(awk -F';' -v s="$t_start" 'NR > 1 && substr($1, 1, 19) >= s { if ($8 == "?") u++; else c += $8 }
        END { printf "%.2f %d\n", c, u }' "$CSV" 2>/dev/null)
    [ "${unknown:-0}" -gt 0 ] && unknown=" (+ $unknown runs with unknown cost, time limit)" || unknown=''
    case $1 in
        delivered) next="adopt it: $merge" ;;
        stopped|limit) next="continue: autopilot start" ;;
        *) if grep -q '^- \[~\]' "$TASKS_FILE"; then next="read BLOCKED.md, split or solve the blocked tasks, then: autopilot start"
           else next="fix the cause ($2; see $LOGS), then: autopilot start"; fi ;;
    esac
    {   if [ "$1" = delivered ]; then echo "# Delivered"; else echo "# Not delivered: $2"; fi
        echo "Project $NAME, $t_start to $(date '+%F %T'), $i runs, ${spent:-0} USD$unknown"
        echo; echo "## What was built"; echo "${built:-nothing new}"
        echo; echo "## How to try it"; echo "${TRY_IT:-(TRY_IT is not set in autopilot.conf)}"
        echo "Branch $b in $WORKDIR – $merge"
        echo; echo "## Proof"
        if [ -f "$STATE/demo.txt" ]; then echo "Demo (${DEMO_CMD:-$SMOKE_TEST_CMD}): ${reason:-green}, last lines:"; tail -40 "$STATE/demo.txt"
        else echo "Demo: not run${DEMO_CMD:+ (DEMO_CMD=$DEMO_CMD)}"; fi
        echo "Tests: $count0 -> $count"
        [ -n "$ACCEPT_CMD" ] && echo "Acceptance: $acc0 -> $acc of ${target:-?}"
        echo; echo "## Open"
        grep '^- \[~\]' "$TASKS_FILE" || echo "no blocked tasks"
        [ -s BLOCKED.md ] && { echo "Reasons (BLOCKED.md):"; tail -10 BLOCKED.md; }
        echo "Rejected runs this start: $rejected_n$( [ "$rejected_n" -gt 0 ] && echo " (diffs: $LOGS/rejected-*.patch)")"
        echo; echo "## Next step for you"; echo "$next"
    } >"$STATE/HANDOVER.md"
    if [ "$1" = delivered ]; then notify ok "Delivered: $2" >/dev/null 2>&1 || true
    else notify warn "Not delivered: $2" >/dev/null 2>&1 || true; fi
}
finish() { # EXIT trap: an end that wrote no outcome itself (crit stop, abort) is an error with the last history line
    if [ -n "${loop_started:-}" ]; then
        [ -s "$STATE/outcome" ] || handover error "$(tail -1 "$LOGS/history.log" | cut_chars 21 160)"
        save_attempts
    fi
    rm -rf "$lock"
}
trap 'finish' EXIT  # handover for an end not handled explicitly, attempts saved, lock released

# Planner proposes new tasks; after two rounds on the same acceptance level the goal is out of reach for tasks.
plan_more() { # WHY (the loop ends here)
    local rounds; rounds=$(grep -cx -- "$acc" "$STATE/planner-rounds" 2>/dev/null)
    if [ "${rounds:-0}" -ge 2 ]; then
        note "Planner: two planner rounds without progress${ACCEPT_CMD:+ (Accept $acc of ${target:-?})}, stopped – check the acceptance test or demo; allow new rounds: rm $STATE/planner-rounds"
        handover not-delivered "two planner rounds without progress${ACCEPT_CMD:+ (Accept $acc of ${target:-?})}; allow new rounds: rm $STATE/planner-rounds"; exit 1
    fi
    echo "$acc" >>"$STATE/planner-rounds"
    note "$1: planner drafts new tasks …"
    local answer; answer=$(run_planner); rc=$?
    if [ "$rc" = 2 ]; then note "Planner: $answer"; handover not-delivered "$answer"; exit 1; fi  # NOT REACHABLE: needs the owner
    note "$answer Review and adopt: autopilot suggestion"
    handover not-delivered "$1, planner proposed tasks (autopilot suggestion)"; exit 0
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

# Supervised mode: kinds without a licence wait for `autopilot continue` after every task.
supervised_stop() {
    [ "$SUPERVISED" = on ] && ! has_licence "$kind" || return 0
    printf '%s\n%s\n' "$$" "$task" >"$STATE/WAITING"; rm -f "$STATE/CONTINUE"
    announce info "Supervised \"$kind\": $task – accepted and committed. Please review, then: autopilot continue"
    until [ -e "$STATE/CONTINUE" ] || [ -e "$STATE/STOP" ]; do sleep "$POLL"; done
    rm -f "$STATE/WAITING" "$STATE/CONTINUE"
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
[ -n "$ALLOWED" ] || { announce crit "ALLOWED is not set in $CONF – which paths may Claude change?"; exit 1; }
bad=$(bad_patterns); [ -z "$bad" ] || { announce crit "$(echo $bad) in $CONF is not a valid regular expression (grep -E)"; exit 1; }
[ -n "$ACCEPT_CMD" ] && [ ${#ACCEPT_FILES[@]} -eq 0 ] &&
    { announce crit "ACCEPT_CMD is set but ACCEPT_FILES is empty in $CONF: the acceptance test would not be locked"; exit 1; }
claude --help 2>/dev/null | grep -q -- '--safe-mode' || { announce crit "claude is too old for --safe-mode (needs Claude Code >= 2.1): update it"; exit 1; }
tools_cover_test_cmd || { announce crit "No Bash entry in WORKER_TOOLS covers the test command \"${TEST_CMD%% *} …\" in $CONF: the worker could never run it (e.g. 'Bash(${TEST_CMD%% *}:*)')"; exit 1; }
[ -f "$TASKS_FILE" ] || { announce crit "Task list $WORKDIR/$TASKS_FILE is missing"; exit 1; }
if [ "$SANDBOX" = on ]; then
    command -v bwrap >/dev/null ||
        { announce crit "SANDBOX=on in $CONF needs bubblewrap (bwrap, Linux only), not found on PATH: $(install_hint bubblewrap) or set SANDBOX=off"; exit 1; }
    # bwrap may be installed but unable to create namespaces (AppArmor restriction, container)
    "$TOOL_DIR/sandbox-run" true >"$LOGS/sandbox-probe.txt" 2>&1 ||
        { announce crit "SANDBOX=on, but bwrap cannot start a sandbox here: $(tail -1 "$LOGS/sandbox-probe.txt" | cut_chars 1 160) – fix bubblewrap (AppArmor? container?) or set SANDBOX=off in $CONF"; exit 1; }
fi
is_approved || { announce warn "Acceptance test NOT approved: choose \"Approve acceptance test\" in the menu (or: autopilot approve)"; exit 1; }
[ -n "$(g status --porcelain)" ] && { announce crit "Work directory not clean, aborting"; exit 1; }
g var GIT_COMMITTER_IDENT >/dev/null 2>&1 || { announce crit "Git cannot commit in $WORKDIR: no identity. Set one: git config --global user.email you@example.org; git config --global user.name \"Your Name\""; exit 1; }
rm -f "$STATE/WAITING" "$STATE/CONTINUE" "$STATE/cost-extra" "$STATE/STOP" "$STATE/outcome" "$STATE/HANDOVER.md" "$STATE/demo.txt"

i=0; start=$(date +%s); acc=0; cost=0; kind=-; worker=''; cmd=''; reason=''; rejected_n=0; t_start=$(date '+%F %T')
fingerprint=$(git_fingerprint)  # before the first run_cmd: it checks .git after every test command
trap 'interrupted 130' INT; trap 'interrupted 143' TERM; trap 'interrupted 129' HUP  # HUP: tmux session killed
run_tests "$LOGS/start.txt" || { announce crit "Tests hit the time limit (TEST_TIMEOUT=$TEST_TIMEOUT) before the start, see $LOGS/start.txt"; exit 1; }
count=$tests_n
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
announce info "Start: $count tests green${ACCEPT_CMD:+, Accept $acc of ${target:-?}}, at most $MAX runs, planner $PLANNER_MODEL, worker $WORKER_MODEL, reviewer $REVIEWER_MODEL"

# Brakes of the first open task from the last start (same task: counters and feedback kept)
attempts=0; failures=0; rejections=0; timeouts=0; last=''
h=''; [ -r "$STATE/attempts" ] && read -r h a f r t <"$STATE/attempts"
if [ -n "${h:-}" ] && [ "$h" = "$(task_hash)" ] && [ "${a:-0}" -gt 0 ]; then
    attempts=$a; failures=$f; rejections=$r; timeouts=$t; last=$(grep -m1 '^- \[ \]' "$TASKS_FILE")
    note "Same task as last time: $attempts attempts, $failures rejections in a row, $timeouts time limits so far – counters and feedback kept"
else rm -f "$FEEDBACK"; fi
waits=0; accepted=0; no_progress=0; last_denied=''; loop_started=1
while [ "$i" -lt "$MAX" ]; do
    [ -e "$STATE/STOP" ] && { rm -f "$STATE/STOP"; note "Stopped via STOP after $i runs"; handover stopped "stopped by you after $i runs"; exit 0; }
    if ! grep -q '^- \[ \]' "$TASKS_FILE"; then
        if [ -z "$ACCEPT_CMD" ] || [ "$acc" = "${target:-x}" ]; then
            reason=''; demo; r=$?
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
    [ "$failures" -ge "$MAX_REJECTIONS" ] && { note "$failures rejections in a row. Last reason: $(head -1 "$FEEDBACK" 2>/dev/null)"; block_task "$failures rejections in a row, last: $(head -1 "$FEEDBACK" 2>/dev/null | cut_chars 1 120)"; continue; }
    [ "$(grep -c '^- \[~\]' "$TASKS_FILE")" -ge "$MAX_BLOCKED" ] && { announce crit "$MAX_BLOCKED tasks blocked, please check BLOCKED.md"; exit 1; }

    i=$((i + 1)); start=$(date +%s); before=$(g rev-parse HEAD); cost=0
    open_task=$(grep -m1 '^- \[ \]' "$TASKS_FILE"); kind=$(kind_of "$open_task")
    [ "$open_task" != "$last" ] && { last=$open_task; attempts=0; failures=0; rejections=0; timeouts=0; rm -f "$FEEDBACK"; }
    attempts=$((attempts + 1)); save_attempts
    note "Run $i: $(printf '%s\n' "$open_task" | cut_chars 7 80)"
    prompt=$(cat "$PROMPT_FILE")
    # Quoted replacements: taken literally (no & from bash 5.2 patsub_replacement, no backslash handling)
    prompt=${prompt//\{TASKS_FILE\}/"$TASKS_FILE"}
    prompt=${prompt//\{DECISIONS_FILE\}/"$DECISIONS_FILE"}
    prompt=${prompt//\{TEST_CMD\}/"$TEST_CMD"}
    prompt=${prompt//\{ACCEPT_CMD\}/"${ACCEPT_CMD:-(no acceptance test)}"}
    prompt+=$'\n\n## This run\n'"Time budget: $WORKER_TIMEOUT, then the run is aborted and reset. Attempt $attempts of this task, previous rejections: $failures."
    prompt+=$(plan_section)$(project_rules)
    [ -s "$FEEDBACK" ] && prompt+=$'\n\n## Feedback on the previous attempt\n'"$(cat "$FEEDBACK")"
    # Brief: the (stronger) planner plans the task, the (cheaper) worker implements it.
    if [ "$PLANNER_MODEL" != "$WORKER_MODEL" ]; then
        brief=$(cat "$BRIEF_FILE"; plan_section; project_rules; printf '\n\n## Task\n%s\n' "$open_task"
                [ -s "$FEEDBACK" ] && { printf '\n## Feedback on the previous attempt\n'; cat "$FEEDBACK"; })
        k=$(claude_run "$LOGS/brief-$i.txt" --model "$PLANNER_MODEL" --allowedTools Read Grep Glob <<<"$brief")
        if [ $? -eq 0 ] && [ -s "$LOGS/brief-$i.txt" ]; then
            echo "$k" >>"$STATE/cost-extra"
            prompt+=$'\n\n## Brief from the planner\n'"$(cat "$LOGS/brief-$i.txt")"
        else note "Run $i: no brief from the planner ($PLANNER_MODEL), the worker goes without one"; fi
    fi
    # In the background so that a signal interrupts `wait` at once (a foreground child delays the trap)
    # --add-dir: the logs (rejected-N.patch) may lie outside the work directory (worktree case)
    CLAUDE_TIMEOUT=$WORKER_TIMEOUT claude_run "$LOGS/run-$i.txt" --model "$WORKER_MODEL" --permission-mode acceptEdits \
        --add-dir "$LOGS" --allowedTools "${WORKER_TOOLS[@]}" <<<"$prompt" >"$STATE/worker-cost" & worker=$!
    wait "$worker"; rc=$?; worker=''; cost=$(cat "$STATE/worker-cost" 2>/dev/null); cost=${cost:-0}

    # Did the run change the Git management (hooks, config)? Then stop immediately.
    if [ "$(git_fingerprint)" != "$fingerprint" ]; then
        announce crit "Run $i changed .git (config, info or hooks) – stopped. Please inspect before starting again."
        exit 1
    fi

    # Subscription usage limit: wait instead of using up a run (at most 20 times).
    if [ "$rc" -ne 0 ] && usage_limit "$LOGS/run-$i.txt"; then
        restore "$before"
        i=$((i - 1)); attempts=$((attempts - 1)); waits=$((waits + 1))
        [ "$waits" -gt 20 ] && { announce crit "Usage limit persists, stopped"; exit 1; }
        note "Usage limit, waiting $((LIMIT_WAIT / 60)) min"; sleep "$LIMIT_WAIT"; continue
    fi

    # Any other error reported by Claude (login, network …): retrying only burns runs, so stop without counting a rejection.
    if [ "$rc" -ne 0 ] && err=$(jq -er 'select(.is_error == true) | .result // "unknown error"' "$LOGS/run-$i.txt.json" 2>/dev/null); then
        restore "$before"
        announce crit "Run $i: Claude reported an error: $(echo "$err" | head -1 | cut_chars 1 200) – fix it (e.g. claude /login, check the network), then start again"
        exit 1
    fi

    # Tool calls Claude Code refused (not in WORKER_TOOLS, or a hook rewrote the command): name them,
    # otherwise a run without e.g. the build command only ends in a time-out with no visible reason.
    denied=$(jq -r '[.permission_denials[]? | .tool_input.command // .tool_name] | unique | .[:3] | join(" | ")' \
        "$LOGS/run-$i.txt.json" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//' | cut_chars 1 200)
    [ -n "$denied" ] && { last_denied=$denied; note "Run $i: tool calls denied (allow them in WORKER_TOOLS, or a hook rewrote them): $denied"; }

    # Script checks: only green, not weakened work in allowed paths counts.
    g add -A
    task=$(g diff --cached --no-ext-diff -U0 -- "$TASKS_FILE" | grep -m1 '^+- \[[x~]\]' | cut_chars 4 90)
    if [ "$rc" -eq 124 ]; then
        # Time limit: say so, with what was refused (this run has no readable answer, so the last one that had)
        reject "$before" "aborted after $WORKER_TIMEOUT (time limit): work smaller, or block early with [~]${last_denied:+; denied commands from the last readable run: $last_denied}" "$LOGS/run-$i.txt"
        # Twice on the same task: too big for one run – block it instead of burning more runs.
        timeouts=$((timeouts + 1)); [ "$timeouts" -ge 2 ] && block_task "time limit reached twice – task too big for one run, please split it"
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
        reject "$before" "code changed while blocking the task: revert your code changes before blocking ($(echo $extra | cut_chars 1 120))"; continue
    fi
    subs=$(changed_submodules)
    if [ -n "$subs" ]; then reject "$before" "change inside a submodule: $(echo $subs)"; continue; fi
    foreign=$(changed | grep -Ev -- "$ALLOWED")
    [ $? -le 1 ] || { reject "$before" "ALLOWED check failed (invalid pattern?)"; continue; }
    if [ -n "$foreign" ]; then reject "$before" "change outside allowed paths: $(echo $foreign)"; continue; fi
    locked=$( { changed | grep -E "$ALWAYS_LOCKED"
                for p in ${LOCKED[@]+"${LOCKED[@]}"} ${ACCEPT_FILES[@]+"${ACCEPT_FILES[@]}"}; do changed "$p"; done; } | sort -u)
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
    if [ "$ticked" -gt 0 ] && [ "$SMOKE_TEST_EVERY" -gt 0 ] && [ $(( (accepted + 1) % SMOKE_TEST_EVERY )) -eq 0 ]; then
        reason=''; smoke_test; ok=$?; add_extra_cost
        [ "$ok" = 0 ] || { reject "$before" "$reason" "$LOGS/smoke-$i.txt"; continue; }
    fi
    # Files the test, acceptance or smoke command wrote were never checked above, so nothing may be
    # staged after the checks: the commit takes exactly the index staged before those commands ran.
    # Ignored files (caches like __pycache__/) do not show up here and stay allowed.
    drift=$(g -c core.quotePath=false status --porcelain --untracked-files=all | grep -v '^[MADRCT] ')
    if [ -n "$drift" ]; then reject "$before" "test command changed files: $(echo $drift | cut_chars 1 200)"; continue; fi

    # Reviewer: only for completed tasks; two rejections of the same task block it.
    if [ "$ticked" -gt 0 ]; then
        verdict=$(review); add_extra_cost
        if [ "${verdict:-}" != "VERDICT: ACCEPT" ]; then
            reason=${verdict#VERDICT: REJECT: }; [ -n "$reason" ] || reason="no verdict, see log/review-$i.txt"
            rejections=$((rejections + 1))
            reject "$before" "Reviewer: $reason"
            [ "$rejections" -ge 2 ] && block_task "Reviewer rejected twice: $reason"
            continue
        fi
    fi

    g commit -q --no-verify -m "Autopilot: $task" -m "Tests $count -> $new${ACCEPT_CMD:+, Accept $acc -> $acc_new of ${target:-?}}" ||
        { reject "$before" "commit failed"; continue; }
    note "Run $i accepted: $task | Tests $count -> $new${ACCEPT_CMD:+, Accept $acc -> $acc_new of ${target:-?}} | $cost USD"
    if [ -n "$ACCEPT_CMD" ] && [ "$acc_new" -le "$acc" ] && [ "$acc_new" != "${target:-x}" ]; then no_progress=$((no_progress + 1)); else no_progress=0; fi
    count=$new; acc=$acc_new; attempts=0; failures=0; rejections=0; timeouts=0; accepted=$((accepted + 1)); rm -f "$FEEDBACK"
    record accepted; [ "$ticked" -gt 0 ] && grade 1
    # Accepted runs without acceptance progress: the tasks miss the goal, more of them would not help
    [ "$STALL_WARN_AFTER" -gt 0 ] && [ "$no_progress" -ge "$STALL_WARN_AFTER" ] && {
        note "Stall: Accept has not risen for $STALL_WARN_AFTER accepted runs (stays at $acc of ${target:-?}) – stopped, the tasks do not lead to the goal"
        handover not-delivered "stalled: Accept $acc of ${target:-?} unchanged for $STALL_WARN_AFTER accepted runs"; exit 1; }
    [ "$ticked" -gt 0 ] && supervised_stop
done
note "Limit of $MAX runs reached ($count tests${ACCEPT_CMD:+, Accept $acc of ${target:-?}})"
handover limit "run limit of $MAX reached, $(grep -c '^- \[ \]' "$TASKS_FILE") tasks still open"
