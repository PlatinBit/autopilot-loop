#!/bin/bash
# Self-test for autopilot-loop with a fake `claude` (test/fake-claude): costs nothing, starts nothing real,
# touches no real settings (own XDG_CONFIG_HOME). Output "ok" = everything passed.
set -u
export LC_ALL=C.UTF-8  # English git messages (the checks read them); umlauts stay valid
TOOL_DIR=$(readlink -f "$(dirname "$0")/..")
T=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
fail() { echo "FAILED: $1"; for v in "$T"/pa/.autopilot/log/history.log "$T"/p2/.autopilot/log/history.log; do [ -f "$v" ] && { echo "--- $v"; cat "$v"; }; done; exit 1; }
mkdir -p "$T/bin" "$T/config"
ln -s "$TOOL_DIR/test/fake-claude" "$T/bin/claude"
# notify-send stub: the default notify() must never pop real desktop notifications during the test;
# it appends its arguments to $NOTIFY_LOG (part_g reads that).
printf '#!/bin/bash\necho "$*" >>"${NOTIFY_LOG:-/dev/null}"\n' >"$T/bin/notify-send" && chmod +x "$T/bin/notify-send"
unset AUTOPILOT_CONF MAX_RUNS MAX_COST_USD ATTEMPTS MAX_BLOCKED NO_PROGRESS MAX_COST_PER_CALL_USD COOLDOWN EFFORT_WORKER EFFORT_REVIEWER EFFORT_PLANNER EFFORT_LESSONS PARALLEL  # e.g. inherited from a running autopilot
# SANDBOX=off unless a test asks for the sandbox (SANDBOX= in its conf): the results must not depend on bwrap
export PATH="$T/bin:$PATH" XDG_CONFIG_HOME="$T/config" FAKE_DIR="$T/fake" AUTOPILOT_LIMIT_WAIT=0 SANDBOX=off
new_round() { rm -rf "$FAKE_DIR"; mkdir -p "$FAKE_DIR/steps"; }
tick='sed -i "0,/^- \[ \]/s//- [x]/" TASKS.md'
sample_project() { # DIR: Git project with test and acceptance script
    mkdir -p "$1" && cd "$1" || exit 1
    git init -q -b main . && git config user.email test@example.org && git config user.name Test
    echo check >checks.txt
    echo 'test -e red && exit 1; echo "TESTS: $(grep -c check checks.txt) passed"' >check.sh
    echo 'echo "ACCEPT: $(grep -c goal checks.txt) of 2"' >accept.sh
    echo "Plan: count numbers." >plan.md
}

# ================================ Part A: the loop ================================
new_round
sample_project "$T/project"
printf -- '- [ ] 1. one\n- [ ] 2. two\n- [ ] 3. three\n- [ ] 4. four\n- [ ] 5. five\n' >TASKS.md
echo "User file" >secret.txt
git add -A && git commit -qm start && git checkout -qb autopilot
mkdir -p "$T/pa"
cat >"$T/pa/autopilot.conf" <<'EOF'
NAME=selftest
WORKDIR=../project
TEST_CMD='bash check.sh'
ACCEPT_CMD='bash accept.sh'
PLAN_FILE=../project/plan.md
LOCKED=(plan.md accept.sh)
ALLOWED='^(checks\.txt|code\.txt|red|plan\.md)$'
FORBIDDEN_CONTENT='FORBIDDEN'
MODELS=max
EOF
s=$FAKE_DIR/steps
echo "echo check >>checks.txt; $tick"                            >"$s/1.sh"   # accepted
echo "echo check >>checks.txt; echo 'rtk gradlew build' >\"\$FAKE_DIR/denied\"" >"$s/2.sh"   # not ticked off, build refused
echo "$tick"                                                     >"$s/3.sh"   # without a new test
echo "echo check >>checks.txt; echo x >>accept.sh; $tick"        >"$s/4.sh"   # acceptance file: outside ALLOWED
echo "echo check >>checks.txt; echo x >>plan.md; $tick"          >"$s/5.sh"   # plan file: allowed, but locked
echo "echo check >>checks.txt; echo FORBIDDEN >code.txt; $tick"  >"$s/6.sh"   # forbidden content
echo "echo check >>checks.txt; echo \"echo 'TESTS: 99'\" >code.txt; $tick" >"$s/7.sh"  # fakes the count line
echo "echo check >>checks.txt; mv secret.txt code.txt; $tick"    >"$s/8.sh"   # rename: foreign file gone
echo "echo check >>checks.txt; $tick"                            >"$s/9.sh"   # reviewer rejects
echo "echo check >>checks.txt; $tick"                            >"$s/10.sh"  # … again: ATTEMPTS=9 reached, blocked
echo "sed -i 1d checks.txt; $tick"                               >"$s/11.sh"  # tests dropped
echo "echo check >>checks.txt; touch red; $tick"                 >"$s/12.sh"  # tests red
echo "printf 'check goal\ngoal\n' >>checks.txt; $tick"           >"$s/13.sh"  # acceptance 2 of 2
echo "echo check >>checks.txt; $tick"                            >"$s/14.sh"
echo "echo check >>checks.txt; $tick"                            >"$s/15.sh"
echo "echo check >>checks.txt; exit 124"                         >"$s/16.sh"  # time limit …
echo "echo check >>checks.txt; exit 124"                         >"$s/17.sh"  # … twice with ATTEMPTS=2: blocked
echo "echo check >>checks.txt; $tick"                            >"$s/18.sh"  # next task goes on
echo "printf '[core]\n\tfsmonitor = touch $T/evil\n' >>.git/config; echo check >>checks.txt; $tick" >"$s/19.sh"  # .git tampering
printf 'VERDICT: ACCEPT\nVERDICT: REJECT: too thin\nVERDICT: REJECT: too thin\nVERDICT: ACCEPT\nVERDICT: ACCEPT\nVERDICT: ACCEPT\nVERDICT: ACCEPT\nVERDICT: ACCEPT\n' >"$FAKE_DIR/verdicts"
export AUTOPILOT_CONF="$T/pa/autopilot.conf"

"$TOOL_DIR/autopilot.sh" >/dev/null 2>&1; [ $? = 4 ] || fail "unconfirmed configuration was loaded"
[ -f "$FAKE_DIR/step-nr" ] && fail "Claude was started with an unconfirmed configuration"
"$TOOL_DIR/menu.sh" trust "$AUTOPILOT_CONF" >/dev/null || fail "trust failed"
"$TOOL_DIR/menu.sh" start 5 opus >"$T/start-args.txt" 2>&1; [ $? = 2 ] && grep -q "MAX_RUNS, MAX_COST_USD, MODELS" "$T/start-args.txt" ||
    fail "start with the old arguments not refused with a hint: $(cat "$T/start-args.txt")"
ATTEMPTS=9 "$TOOL_DIR/autopilot.sh" >"$T/output.txt" 2>&1 || fail "run ended with an error: $(tail -3 "$T/output.txt")"

v=$T/pa/.autopilot/log/history.log
for expected in "Only blocked tasks left: 1" "no task ticked off" "without a new test" "outside allowed paths: accept.sh" \
                "locked file changed: plan.md" "forbidden content" "Reviewer: too thin" "Task blocked: 9 failed attempts, last: Reviewer: too thin" \
                "dropped from 2 to 1" "tests red" "count line of the test command" "outside allowed paths: secret.txt" \
                'tool calls denied: Bash `rtk gradlew build` (not covered by WORKER_TOOLS)' \
                'denied tool calls: Bash `rtk gradlew build`'; do
    grep -qF "$expected" "$v" || fail "missing in history: $expected"
done
[ "$(grep -c '^- \[x\]' TASKS.md)" = 4 ] && grep -q '^- \[~\] 2\.' TASKS.md || fail "task list wrong: $(tr '\n' ' ' <TASKS.md)"
[ "$(git log --oneline | wc -l)" = 6 ] || fail "expected 6 commits: $(git log --oneline | tr '\n' '|')"
git diff --quiet main -- accept.sh plan.md || fail "locked file was changed"
[ -z "$(git status --porcelain)" ] || fail "work directory not clean: $(git status --porcelain)"
[ ! -e code.txt ] && [ ! -e red ] || fail "rejected changes are still lying around"
grep -qx 3 "$FAKE_DIR/with-feedback" && ! grep -qx 1 "$FAKE_DIR/with-feedback" || fail "feedback not passed on (only) after a rejection"
grep -qx 1 "$FAKE_DIR/with-plan" || fail "plan was not passed to the worker without a brief"
[ ! -e "$FAKE_DIR/brief-nr" ] || fail "brief written although planner and worker are the same model (MODELS=max)"
[ "$(grep -c "tool calls denied" "$v")" = 1 ] || fail "refused tool calls reported although there were none"
grep -qx 1 "$FAKE_DIR/with-decisions" || fail "{DECISIONS_FILE} was not filled into the prompt"
c=$T/pa/.autopilot/costs.csv
[ "$(head -1 "$c")" = "time;kind;model;usd;input_tokens;cache_read_tokens;output_tokens;effort;cache_creation_tokens" ] || fail "costs.csv header wrong: $(head -1 "$c")"
[ "$(grep -c ';worker;opus;0.01;100;1000;10;high;0$' "$c")" = 15 ] && [ "$(grep -c ';reviewer;opus;0.01;' "$c")" = 6 ] ||
    fail "costs.csv: worker and reviewer calls with tokens not recorded: $(cat "$c")"
"$TOOL_DIR/menu.sh" status >"$T/st.txt" || fail "status failed"
grep -q "4 done, 0 open, 1 blocked" "$T/st.txt" || fail "status wrong: $(cat "$T/st.txt")"
grep -qE '^  worker +0\.15 USD +tokens: 1500 in, 15k cache read, 150 out$' "$T/st.txt" && grep -qE '^  lessons +0\.01 USD' "$T/st.txt" &&
    ! grep -qE '^  size ' "$T/st.txt" && grep -qE '^  total +0\.22 USD$' "$T/st.txt" ||  # no size check: SIZE_CHECK is off by default
    fail "status: cost and tokens per kind wrong: $(cat "$T/st.txt")"
grep -q "Autopilot: \[x\] 5. five" "$T/pa/.autopilot/HANDOVER.md" || fail "handover does not list the commits"
grep -qx "User file" secret.txt || fail "foreign file lost through a rename"
# A task that hits the time limit twice (ATTEMPTS=2) is blocked, and the loop moves on to the next one
printf -- '- [ ] 6. six\n- [ ] 7. seven\n' >>TASKS.md && git add -A && git commit -qm "new tasks"
ATTEMPTS=2 "$TOOL_DIR/autopilot.sh" >/dev/null 2>&1 || fail "run with time limits ended with an error"
grep -q "Task blocked: 2 failed attempts, last: aborted after 45m (time limit)" "$v" && grep -q '^- \[~\] 6\.' TASKS.md && grep -q '^- \[x\] 7\.' TASKS.md ||
    fail "task with two time limits not blocked: $(tr '\n' ' ' <TASKS.md)"
# Tampering with .git/config (fsmonitor would run code on the next git status): stop immediately
printf -- '- [ ] 8. eight\n' >>TASKS.md && git add -A && git commit -qm "new task"
"$TOOL_DIR/autopilot.sh" >/dev/null 2>&1 && fail "change to .git/config not noticed"
grep -q "changed .git (config, info or hooks)" "$v" || fail "no message about the .git change"
[ ! -e "$T/evil" ] || fail "code from .git/config was executed"
unset AUTOPILOT_CONF

# ======== Part B: project from a plan file, security filter, brief, second instance, planner suggestion ========
new_round
sample_project "$T/p2"
plan="$T/p2/Plan 'x' \$(touch triggered).md"   # file name with an injected command
printf '# Counter\nIt should count.\n' >"$plan"
git add -A && git commit -qm start
cat >"$FAKE_DIR/setup.txt" <<'EOF'
I have looked at the project.
===CONFIG===
TEST_CMD='bash check.sh'
DEMO_CMD='bash check.sh'
TEST_COUNT_CMD='grep -o "TESTS: [0-9]*" | grep -o "[0-9]*"'
ALLOWED='^checks\.txt$'
WORKER_TOOLS=(Read Edit 'Bash(bash check.sh:*)')
WORKER_TOOLS=(Read Bash)
WORKER_TOOLS=(Read 'Bash(*)')
TEST_COUNT_REGEX='(.*) passed'
rm -rf "$HOME"
TEST_CMD2=$(touch /tmp/injected)
ALLOWED='.'; touch /tmp/injected
===TASKS===
# Tasks: counter
Only change checks.txt.

- [ ] 1. one. Done when one more test passes.
EOF
"$TOOL_DIR/menu.sh" plan "$plan" >"$T/draft.txt" 2>&1 || fail "draft failed: $(tail -3 "$T/draft.txt")"
grep -q "rm -rf" "$T/draft.txt" && grep -q "Not adopted for security reasons" "$T/draft.txt" || fail "dangerous lines not reported as discarded"
[ ! -e "$T/p2-autopilot" ] || fail "draft already set things up"
cd "$T/p2" || exit 1
"$TOOL_DIR/menu.sh" plan | grep -qF "Draft for: $plan" || fail "plan without arguments does not show the draft"
"$TOOL_DIR/menu.sh" plan accept >"$T/accept.txt" || fail "accept failed: $(cat "$T/accept.txt")"
grep -qF "Start: cd $T/p2 && autopilot start" "$T/accept.txt" || fail "accept does not say where to start: $(cat "$T/accept.txt")"
conf=$T/p2/autopilot.conf
grep -q "rm -rf\|TEST_CMD2\|injected\|(Read Bash)\|Bash(\*)\|(\.\*) passed" "$conf" && fail "dangerous line adopted into the configuration: $(cat "$conf")"
( . "$conf"; [ "$PLAN_FILE" = "$plan" ] && [ "${LOCKED[0]}" = "${plan#"$T/p2/"}" ] && [ -z "${NAME:-}" ] ) || fail "plan not entered correctly"
[ -z "$(find "$T" -name triggered)" ] || fail "command from the file name was executed"
grep -q "^TEST_COUNT_CMD=" "$conf" || fail "TEST_COUNT_CMD not adopted"
[ ! -e "$T/config/autopilot-loop/standard.conf" ] || fail "a standard.conf was still written"
[ -f "$T/p2-autopilot/AUTOPILOT-TASKS.md" ] || fail "task list not in the work branch"
git -C "$T/p2" status --porcelain | grep -q . && fail "project polluted by state files: $(git -C "$T/p2" status --porcelain)"
grep -q ';draft;opus;0.01;100;1000;10;high;0$' "$T/p2/.autopilot/costs.csv" || fail "the draft's Claude call is missing in costs.csv"
echo "# changed" >>"$conf"
"$TOOL_DIR/autopilot.sh" >/dev/null 2>&1; [ $? = 4 ] || fail "changed configuration loaded without a new confirmation"
"$TOOL_DIR/menu.sh" trust >/dev/null || fail "trusting again (conf found in the current folder) failed"

mkdir -p "$T/p2/sub/deeper" && cd "$T/p2/sub/deeper" || exit 1   # from here: autopilot.conf two folders up
echo "touch \"\$FAKE_DIR/started\"; while [ ! -e \"\$FAKE_DIR/go\" ]; do sleep 0.2; done; echo check >>checks.txt; sed -i '0,/^- \[ \]/s//- [x]/' AUTOPILOT-TASKS.md" >"$FAKE_DIR/steps/1.sh"
echo "VERDICT: ACCEPT" >"$FAKE_DIR/verdicts"
"$TOOL_DIR/autopilot.sh" >"$T/output2.txt" 2>&1 & first=$!
for _ in $(seq 1 50); do [ -e "$FAKE_DIR/started" ] && break; sleep 0.2; done
[ -e "$FAKE_DIR/started" ] || fail "run from a subfolder did not start: $(cat "$T/output2.txt")"
# A second instance for the same project is refused quickly and leaves the first run's state alone
SECONDS=0; timeout 10 "$TOOL_DIR/autopilot.sh" >"$T/second.txt" 2>&1 && fail "second instance started: $(cat "$T/second.txt")"
[ "$SECONDS" -le 5 ] || fail "second instance needed ${SECONDS}s to be refused: $(cat "$T/second.txt")"
grep -q "already running" "$T/second.txt" || fail "second instance: no 'already running' message: $(cat "$T/second.txt")"
[ -d "$T/p2/.autopilot/lock" ] || fail "second instance removed the lock of the first run"
"$TOOL_DIR/menu.sh" status | grep -q "^Status: *running – run 1 of at most 50" || fail "status does not show the running run: $("$TOOL_DIR/menu.sh" status)"
"$TOOL_DIR/menu.sh" status --short | grep -qx "Autopilot p2: run 1/50 · 0.00 USD" || fail "status --short while running: $("$TOOL_DIR/menu.sh" status --short)"  # nothing booked yet: the worker is still running
touch "$FAKE_DIR/go"
wait "$first" || fail "run ended with an error: $(tail -3 "$T/output2.txt")"
grep -q "Goal reached" "$T/p2/.autopilot/log/history.log" || fail "project not completed"
# MODELS=balanced: no brief (only cheap gets one); the sonnet worker gets the whole plan and reads the code itself
[ ! -e "$FAKE_DIR/brief-nr" ] && grep -q "## Plan being implemented" "$FAKE_DIR/last-prompt" && grep -q "It should count" "$FAKE_DIR/last-prompt" ||
    fail "balanced: a brief ran, or the worker did not get the plan"
grep -q "models balanced (planner opus, worker sonnet, reviewer sonnet)" "$T/p2/.autopilot/log/history.log" || fail "models not shown at the start"
grep -q ';brief;' "$T/p2/.autopilot/costs.csv" && fail "costs.csv: a brief call under MODELS=balanced"
grep -q ';worker;sonnet;' "$T/p2/.autopilot/costs.csv" || fail "costs.csv: worker model wrong"
"$TOOL_DIR/menu.sh" status --short | grep -qx "Autopilot p2 ended: delivered, merged into main - 1 done, 0 blocked, tests 1 -> 2, 0.03 USD" ||
    fail "status --short after the end: $("$TOOL_DIR/menu.sh" status --short)"
# Planner suggestion: shown by `plan`, adopted by `plan accept`, thrown away by `plan discard` (honest when there is none)
printf -- '- [ ] 2. two. Done when two more tests pass.\n' >"$T/p2/.autopilot/suggestion.md"
"$TOOL_DIR/menu.sh" plan | grep -q "^Planner suggestion" || fail "plan does not show the suggestion"
"$TOOL_DIR/menu.sh" plan accept | grep -q "1 tasks adopted" || fail "suggestion not adopted"
grep -q '^- \[ \] 2\. two' "$T/p2-autopilot/AUTOPILOT-TASKS.md" || fail "suggestion missing in the task list"
"$TOOL_DIR/menu.sh" plan discard >"$T/discard.txt" 2>&1 && fail "plan discard without anything exits 0"
grep -q "Nothing to discard" "$T/discard.txt" || fail "plan discard without anything is not honest: $(cat "$T/discard.txt")"
[ -z "$(find "$T" -name triggered)" ] || fail "command from the file name was executed later while loading"

# ======== Part C: plan file outside any Git project (e.g. ~/readme.md): own project folder, nothing else touched ========
mkdir -p "$T/home" && echo "# Idea" >"$T/home/readme.md" && cd "$T/home" || exit 1
unset GIT_AUTHOR_NAME GIT_COMMITTER_NAME
"$TOOL_DIR/menu.sh" plan "$T/home/readme.md" >"$T/draft3.txt" 2>&1 || fail "draft outside Git failed: $(tail -3 "$T/draft3.txt")"
grep -q "separate project folder was created" "$T/draft3.txt" || fail "no note about the new project folder"
[ -d "$T/home/readme-autopilot/.git" ] && [ ! -e "$T/home/.git" ] || fail "Git was not confined to the new project folder"
[ "$(cat "$T/home/readme.md")" = "# Idea" ] || fail "original plan file was changed"
"$TOOL_DIR/menu.sh" plan accept >/dev/null || fail "accept in the own project folder failed"
( . "$T/home/readme-autopilot/autopilot.conf"; [ "$WORKDIR" = "$T/home/readme-autopilot" ] ) || fail "WORKDIR should be the project folder itself"
[ ! -e "$T/home/readme-autopilot-autopilot" ] || fail "an unnecessary second folder was created"
[ "$(ls -A "$T/home")" = "readme-autopilot
readme.md" ] || fail "something else was created next to the plan: $(ls -A "$T/home" | tr '\n' ' ')"

# ======== Part D: error messages ========
mkdir -p "$T/d1"
for w in "gone dir" "$T/absent/work"; do
    printf 'WORKDIR=%q\n' "$w" >"$T/d1/autopilot.conf"
    case "$w" in /*) p=$w ;; *) p=$T/d1/$w ;; esac
    AUTOPILOT_CONF="$T/d1/autopilot.conf" "$TOOL_DIR/menu.sh" trust "$T/d1/autopilot.conf" >/dev/null || fail "trust for the WORKDIR test failed"
    AUTOPILOT_CONF="$T/d1/autopilot.conf" "$TOOL_DIR/autopilot.sh" >"$T/d1/out.txt" 2>&1 && fail "missing WORKDIR $w not refused"
    grep -qF "$p" "$T/d1/out.txt" || fail "message does not name the missing path $p: $(cat "$T/d1/out.txt")"
    grep -q "WORKDIR" "$T/d1/out.txt" || fail "message does not name WORKDIR: $(cat "$T/d1/out.txt")"
    grep -qE '^cd:|line [0-9]+:' "$T/d1/out.txt" && fail "raw shell error for a missing WORKDIR: $(cat "$T/d1/out.txt")"
done
# status with the task list deleted: name the path, no raw grep error, exit 0
mkdir -p "$T/d2/work" && printf -- '- [ ] 1. one\n' >"$T/d2/work/My Tasks.md"
printf 'WORKDIR=work\nTASKS_FILE=%q\n' "My Tasks.md" >"$T/d2/autopilot.conf"
export AUTOPILOT_CONF="$T/d2/autopilot.conf"
"$TOOL_DIR/menu.sh" status | grep -q "not started yet" || fail "status before the first start wrong: $("$TOOL_DIR/menu.sh" status)"
"$TOOL_DIR/menu.sh" trust "$AUTOPILOT_CONF" >/dev/null || fail "trust for the task list test failed"
"$TOOL_DIR/autopilot.sh" >/dev/null 2>&1   # ends at once (no TEST_CMD), but notes what status reads
grep -q "TEST_CMD is not set" "$T/d2/.autopilot/log/history.log" || fail "start without TEST_CMD not refused"
"$TOOL_DIR/menu.sh" status | grep -q "0 done, 1 open" || fail "status with a task list wrong: $("$TOOL_DIR/menu.sh" status)"
rm "$T/d2/work/My Tasks.md"
"$TOOL_DIR/menu.sh" status >"$T/d2/out.txt" 2>&1 || fail "status without a task list exits non-zero: $(cat "$T/d2/out.txt")"
grep -qF "$T/d2/work/My Tasks.md" "$T/d2/out.txt" || fail "status does not name the missing task list: $(cat "$T/d2/out.txt")"
grep -q '^grep:' "$T/d2/out.txt" && fail "raw grep error in status: $(cat "$T/d2/out.txt")"
# an unknown MODELS value is named
printf 'WORKDIR=work\nMODELS=gpt\n' >"$T/d2/autopilot.conf"; "$TOOL_DIR/menu.sh" trust "$AUTOPILOT_CONF" >/dev/null
"$TOOL_DIR/autopilot.sh" >"$T/d2/out.txt" 2>&1 && fail "MODELS=gpt accepted"
grep -q "MODELS=gpt .*balanced, max or cheap" "$T/d2/out.txt" || fail "MODELS=gpt not named: $(cat "$T/d2/out.txt")"
unset AUTOPILOT_CONF

# ======== Part E: security ========
# LOCKED entries with a leading "-" are file names, not options
new_round
sample_project "$T/e1/work"
mv accept.sh ./-accept.sh && mv plan.md ./-plan.md
printf -- '- [ ] 1. one\n' >TASKS.md && git add -A && git commit -qm start
cat >"$T/e1/autopilot.conf" <<'EOF'
WORKDIR=work
TEST_CMD='bash check.sh'
ACCEPT_CMD='bash ./-accept.sh'
LOCKED=(-plan.md -accept.sh)
ALLOWED='^(checks\.txt|-accept\.sh|-plan\.md)$'
EOF
echo "echo check >>checks.txt; echo x >>./-accept.sh; $tick" >"$FAKE_DIR/steps/1.sh"
echo "echo check >>checks.txt; echo x >>./-plan.md; $tick"   >"$FAKE_DIR/steps/2.sh"
export AUTOPILOT_CONF="$T/e1/autopilot.conf"
"$TOOL_DIR/menu.sh" trust "$AUTOPILOT_CONF" >/dev/null || fail "trust for the dash file test failed"
MAX_RUNS=2 "$TOOL_DIR/autopilot.sh" >"$T/e1/out.txt" 2>&1 || fail "run with a dash acceptance file ended with an error: $(tail -3 "$T/e1/out.txt")"
grep -q "Run 1 rejected: locked file changed: -accept.sh" "$T/e1/.autopilot/log/history.log" || fail "change to -accept.sh not rejected as locked"
grep -q "Run 2 rejected: locked file changed: -plan.md" "$T/e1/.autopilot/log/history.log" || fail "change to LOCKED -plan.md not rejected as locked"
[ "$(git log --oneline | wc -l)" = 1 ] && [ -z "$(git status --porcelain)" ] || fail "dash file change was committed or left behind"
# Symlinks in allowed paths: pointing outside WORKDIR (absolute or ../) rejected, pointing inside allowed
new_round
sample_project "$T/e2/work"
printf -- '- [ ] 1. one\n' >TASKS.md && git add -A && git commit -qm start
start_head=$(git rev-parse HEAD)
printf 'WORKDIR=work\nTEST_CMD=%q\nALLOWED=%q\nATTEMPTS=5\n' 'bash check.sh' '^(checks\.txt|out1|out2|in1)$' >"$T/e2/autopilot.conf"
echo "secret" >"$T/e2/outside.txt"
echo "echo check >>checks.txt; ln -s $T/e2/outside.txt out1; $tick" >"$FAKE_DIR/steps/1.sh"
echo "echo check >>checks.txt; ln -s ../outside.txt out2; $tick"    >"$FAKE_DIR/steps/2.sh"
echo "echo check >>checks.txt; ln -s checks.txt in1; $tick"         >"$FAKE_DIR/steps/3.sh"
echo "VERDICT: ACCEPT" >"$FAKE_DIR/verdicts"
export AUTOPILOT_CONF="$T/e2/autopilot.conf"
"$TOOL_DIR/menu.sh" trust "$AUTOPILOT_CONF" >/dev/null || fail "trust for the symlink test failed"
MAX_RUNS=3 "$TOOL_DIR/autopilot.sh" >"$T/e2/out.txt" 2>&1 || fail "symlink run ended with an error: $(tail -3 "$T/e2/out.txt")"
grep -q "Run 1 rejected: symlink .*out1" "$T/e2/.autopilot/log/history.log" || fail "absolute symlink outside WORKDIR not rejected"
grep -q "Run 2 rejected: symlink .*out2" "$T/e2/.autopilot/log/history.log" || fail "../ symlink outside WORKDIR not rejected"
grep -q "Run 3 accepted" "$T/e2/.autopilot/log/history.log" || fail "symlink inside WORKDIR not accepted"
[ "$(git rev-parse HEAD~1)" = "$start_head" ] || fail "HEAD changed by a rejected symlink run"
git ls-tree -r --name-only HEAD | grep -q '^out[12]$' && fail "outside symlink was committed"
[ ! -L out1 ] && [ ! -L out2 ] || fail "outside symlink still lying around after the rejection"
[ -L in1 ] && [ -z "$(git status --porcelain)" ] || fail "inside symlink missing or work directory not clean"
# Submodules: an edited or a new file inside is rejected and the submodule restored; other changes still pass
new_round
mkdir -p "$T/e3/lib" && git -C "$T/e3/lib" init -q -b main && echo orig >"$T/e3/lib/lib.txt" &&
    git -C "$T/e3/lib" add -A && git -C "$T/e3/lib" -c user.email=t@e.org -c user.name=T commit -qm lib
sample_project "$T/e3/work"
printf -- '- [ ] 1. one\n' >TASKS.md
git -c protocol.file.allow=always submodule add -q "$T/e3/lib" sub && git add -A && git commit -qm start
start_head=$(git rev-parse HEAD)
printf 'WORKDIR=work\nTEST_CMD=%q\nALLOWED=%q\n' 'bash check.sh' '^(checks\.txt|sub|sub/.*)$' >"$T/e3/autopilot.conf"
echo "echo check >>checks.txt; echo changed >sub/lib.txt; $tick" >"$FAKE_DIR/steps/1.sh"
echo "echo check >>checks.txt; echo new >sub/new.txt; $tick"     >"$FAKE_DIR/steps/2.sh"
echo "echo check >>checks.txt; $tick"                            >"$FAKE_DIR/steps/3.sh"
echo "VERDICT: ACCEPT" >"$FAKE_DIR/verdicts"
export AUTOPILOT_CONF="$T/e3/autopilot.conf"
"$TOOL_DIR/menu.sh" trust "$AUTOPILOT_CONF" >/dev/null || fail "trust for the submodule test failed"
MAX_RUNS=2 "$TOOL_DIR/autopilot.sh" >"$T/e3/out.txt" 2>&1 || fail "submodule run ended with an error: $(tail -3 "$T/e3/out.txt")"
grep -q "Run 1 rejected: .*submodule.*sub" "$T/e3/.autopilot/log/history.log" || fail "edited file inside a submodule not rejected"
grep -q "Run 2 rejected: .*submodule.*sub" "$T/e3/.autopilot/log/history.log" || fail "new file inside a submodule not rejected"
[ "$(git rev-parse HEAD)" = "$start_head" ] || fail "HEAD changed by a rejected submodule run"
[ -z "$(git status --porcelain)" ] || fail "work directory not clean after the submodule rejection: $(git status --porcelain)"
[ -z "$(git -C sub status --porcelain)" ] || fail "submodule not restored after the rejection: $(git -C sub status --porcelain)"
[ "$(cat sub/lib.txt)" = orig ] && [ ! -e sub/new.txt ] || fail "submodule files not back to the recorded state"
MAX_RUNS=1 "$TOOL_DIR/autopilot.sh" >"$T/e3/out.txt" 2>&1 || fail "submodule follow-up run ended with an error: $(tail -3 "$T/e3/out.txt")"
grep -q "Run 1 accepted" "$T/e3/.autopilot/log/history.log" || fail "change outside the submodule rejected in a project with a submodule"
# Prompt placeholders are filled in literally, even with & (bash 5.2 patsub_replacement) or a backslash
new_round
sample_project "$T/e4/work"
printf -- '- [ ] 1. one\n' >TASKS.md && git add -A && git commit -qm start
printf 'WORKDIR=work\nTEST_CMD=%q\nACCEPT_CMD=%q\nLOCKED=(accept.sh)\nALLOWED=%q\n' 'bash check.sh && true' 'printf "%s\n" x >/dev/null; bash accept.sh' \
    '^(checks\.txt)$' >"$T/e4/autopilot.conf"
echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/1.sh"
echo "VERDICT: ACCEPT" >"$FAKE_DIR/verdicts"
printf -- '- [ ] 2. more. Done when a test passes.\n' >"$FAKE_DIR/planner.txt"   # the planner proposes a task at the end (an empty answer is "not delivered")
export AUTOPILOT_CONF="$T/e4/autopilot.conf"
"$TOOL_DIR/menu.sh" trust "$AUTOPILOT_CONF" >/dev/null || fail "trust for the placeholder test failed"
MAX_RUNS=1 "$TOOL_DIR/autopilot.sh" >"$T/e4/out.txt" 2>&1 || fail "placeholder run ended with an error: $(tail -3 "$T/e4/out.txt")"
grep -qF 'run `bash check.sh && true` once in full' "$FAKE_DIR/last-prompt" || fail "TEST_CMD with & not filled in literally: $(grep -m1 'in full' "$FAKE_DIR/last-prompt")"
grep -qF 'run `printf "%s\n" x >/dev/null; bash accept.sh`;' "$FAKE_DIR/last-prompt" || fail "ACCEPT_CMD with a backslash not filled in literally"
grep -qF '{TEST_CMD}' "$FAKE_DIR/last-prompt" && fail "placeholder {TEST_CMD} left in the prompt"
# Shortened task text never cuts an umlaut in half (history.log, BLOCKED.md, commit message)
new_round
sample_project "$T/e5/work"
u=$(printf 'ü%.0s' $(seq 1 100))
printf -- '- [ ] 1. %s\n- [ ] 2. a%s\n' "$u" "$u" >TASKS.md && git add -A && git commit -qm start
printf 'WORKDIR=work\nTEST_CMD=%q\n' 'bash check.sh' >"$T/e5/autopilot.conf"
for n in 1 2 3; do echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/$n.sh"; done
printf 'VERDICT: REJECT: no\nVERDICT: REJECT: no\nVERDICT: ACCEPT\n' >"$FAKE_DIR/verdicts"
export AUTOPILOT_CONF="$T/e5/autopilot.conf"
"$TOOL_DIR/menu.sh" trust "$AUTOPILOT_CONF" >/dev/null || fail "trust for the umlaut test failed"
LC_ALL=C.UTF-8 ATTEMPTS=2 MAX_RUNS=3 "$TOOL_DIR/autopilot.sh" >"$T/e5/out.txt" 2>&1 || fail "umlaut run ended with an error: $(tail -3 "$T/e5/out.txt")"
grep -q "Task blocked" "$T/e5/.autopilot/log/history.log" && grep -q "Run 3 accepted" "$T/e5/.autopilot/log/history.log" || fail "umlaut run did not block task 1 and accept task 2"
iconv -f UTF-8 -t UTF-8 "$T/e5/.autopilot/log/history.log" >/dev/null 2>&1 || fail "history.log contains a cut umlaut"
iconv -f UTF-8 -t UTF-8 BLOCKED.md >/dev/null 2>&1 || fail "BLOCKED.md contains a cut umlaut"
git log -1 --format=%B | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 || fail "commit message contains a cut umlaut"
git log -1 --format=%s | grep -q "^Autopilot: \[x\] 2\. aüü*…$" || fail "commit message without the shortened umlaut task: $(git log -1 --format=%s)"
# Without a Git identity the loop stops before Claude is started
new_round
sample_project "$T/e6/work"
printf -- '- [ ] 1. one\n' >TASKS.md && git add -A && git commit -qm start
git config --unset user.email && git config --unset user.name && git config user.useConfigOnly true
printf 'WORKDIR=work\nTEST_CMD=%q\n' 'bash check.sh' >"$T/e6/autopilot.conf"
echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/1.sh"
export AUTOPILOT_CONF="$T/e6/autopilot.conf"
"$TOOL_DIR/menu.sh" trust "$AUTOPILOT_CONF" >/dev/null || fail "trust for the identity test failed"
env -u EMAIL -u GIT_COMMITTER_EMAIL -u GIT_AUTHOR_EMAIL GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 MAX_RUNS=1 \
    "$TOOL_DIR/autopilot.sh" >"$T/e6/out.txt" 2>&1 && fail "run without a Git identity not refused"
grep -q "user.email" "$T/e6/out.txt" || fail "no user.email hint without a Git identity: $(tail -3 "$T/e6/out.txt")"
grep -q "git config" "$T/e6/out.txt" || fail "no git config hint without a Git identity"
[ -f "$FAKE_DIR/step-nr" ] && fail "Claude was started without a Git identity"
git config user.email t@e.org && git config user.name T
GIT_CONFIG_GLOBAL=/dev/null MAX_RUNS=1 "$TOOL_DIR/autopilot.sh" >"$T/e6/out.txt" 2>&1 || fail "run with a local Git identity refused: $(tail -3 "$T/e6/out.txt")"
[ -f "$FAKE_DIR/step-nr" ] || fail "Claude not started with a local Git identity"
# Task text with $(...), backticks, ; and a leading -e is never executed and appears literally
new_round
sample_project "$T/e7/work"
m=$T/e7-marker
printf -- '- [ ] -e $(touch %s); `touch %s`; echo hi\n' "$m" "$m" >TASKS.md && git add -A && git commit -qm start
printf 'WORKDIR=work\nTEST_CMD=%q\n' 'bash check.sh' >"$T/e7/autopilot.conf"
echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/1.sh"
echo "VERDICT: ACCEPT" >"$FAKE_DIR/verdicts"
export AUTOPILOT_CONF="$T/e7/autopilot.conf"
"$TOOL_DIR/menu.sh" trust "$AUTOPILOT_CONF" >/dev/null || fail "trust for the task text test failed"
MAX_RUNS=1 "$TOOL_DIR/autopilot.sh" >"$T/e7/out.txt" 2>&1 || fail "task text run ended with an error: $(tail -3 "$T/e7/out.txt")"
[ ! -e "$m" ] || fail "task text was executed"
grep -F 'Run 1:' "$T/e7/.autopilot/log/history.log" | grep -qF -- '-e $(touch' || fail "history.log line 'Run 1:' without the literal task text"
grep -F 'Run 1 accepted' "$T/e7/.autopilot/log/history.log" | grep -qF '$(touch' || fail "history.log line 'Run 1 accepted' without the literal task text"
git log -1 --format=%s | grep -qF '$(touch' || fail "commit subject without the literal \$(touch"
git log -1 --format=%s | grep -qF -- '-e $(touch' || fail "commit subject lost the leading -e"
git log -1 --format=%s | grep -qF '`touch' || fail "commit subject without the literal backtick"
unset AUTOPILOT_CONF

# ======== Part F: fresh machine ========
# Detached HEAD: plan accept takes the commit as BASE_BRANCH instead of "main"
new_round
sample_project "$T/f1/repo"
git add -A && git commit -qm start && git checkout -q --detach && git branch -qD main || fail "detached HEAD setup failed"
head=$(git rev-parse HEAD)
printf "===CONFIG===\nTEST_CMD='bash check.sh'\nDEMO_CMD='bash check.sh'\n===TASKS===\n- [ ] 1. one. Done when a test passes.\n" >"$FAKE_DIR/setup.txt"
"$TOOL_DIR/menu.sh" plan "$T/f1/repo/plan.md" >"$T/f1/out.txt" 2>&1 || fail "draft with a detached HEAD failed: $(tail -3 "$T/f1/out.txt")"
"$TOOL_DIR/menu.sh" plan accept >"$T/f1/out.txt" 2>&1 || fail "accept with a detached HEAD failed: $(tail -3 "$T/f1/out.txt")"
( . "$T/f1/repo/autopilot.conf"; [ "$BASE_BRANCH" = "$head" ] ) || fail "BASE_BRANCH is not the detached commit: $(grep BASE_BRANCH "$T/f1/repo/autopilot.conf")"
# Nested plan file, branch "trunk", path with space, $ and umlaut; status from a subfolder finds the project
new_round
R="$T/f2/my \$dir ü/repo"
mkdir -p "$R/docs/spec" && cd "$R" || fail "nested plan setup failed"
git init -q -b trunk . && git config user.email t@e.org && git config user.name T
echo 'Plan: nested.' >docs/spec/plan.md
echo 'echo "TESTS: 1 passed"' >check.sh
git add -A && git commit -qm start
git rev-parse -q --verify refs/heads/main >/dev/null && fail "nested plan setup: branch main exists"
printf "===CONFIG===\nTEST_CMD='bash check.sh'\nDEMO_CMD='bash check.sh'\n===TASKS===\n- [ ] 1. one. Done when a test passes.\n" >"$FAKE_DIR/setup.txt"
"$TOOL_DIR/menu.sh" plan "$R/docs/spec/plan.md" >"$T/f2/out.txt" 2>&1 || fail "nested plan draft failed: $(tail -3 "$T/f2/out.txt")"
"$TOOL_DIR/menu.sh" plan accept >"$T/f2/out.txt" 2>&1 || fail "nested plan accept failed: $(tail -3 "$T/f2/out.txt")"
( . "$R/autopilot.conf"; [ "$BASE_BRANCH" = trunk ] && [ "${#LOCKED[@]}" = 1 ] && [ "${LOCKED[0]}" = docs/spec/plan.md ] && [ "$PLAN_FILE" = "$R/docs/spec/plan.md" ] && [ "$WORKDIR" = "$R-autopilot" ] ) || fail "nested plan conf wrong: $(cat "$R/autopilot.conf")"
[ -d "$R-autopilot" ] || fail "nested plan: worktree $R-autopilot missing"
cd "$R/docs/spec" || exit 1
"$TOOL_DIR/menu.sh" status >"$T/f2/status.txt" 2>&1 || fail "status from a subfolder exits non-zero: $(cat "$T/f2/status.txt")"
grep -q "^Status: *off – not started yet" "$T/f2/status.txt" || fail "status from a subfolder does not find the project: $(cat "$T/f2/status.txt")"
# plan + plan accept twice for the same project: worktree and branch reused, one trust line
new_round
sample_project "$T/f3/repo"
git add -A && git commit -qm start || fail "second-run setup failed"
printf "===CONFIG===\nTEST_CMD='bash check.sh'\nDEMO_CMD='bash check.sh'\n===TASKS===\n- [ ] 1. one. Done when a test passes.\n" >"$FAKE_DIR/setup.txt"
for i in 1 2; do
    "$TOOL_DIR/menu.sh" plan "$T/f3/repo/plan.md" >"$T/f3/out.txt" 2>&1 || fail "plan run $i failed: $(tail -3 "$T/f3/out.txt")"
    "$TOOL_DIR/menu.sh" plan accept >"$T/f3/out.txt" 2>&1 || fail "accept run $i failed: $(tail -3 "$T/f3/out.txt")"
done
k=$(readlink -f "$T/f3/repo/autopilot.conf")
grep -qxF "$(sha256sum <"$k" | cut -c1-64) $k" "$T/config/autopilot-loop/trusted" || fail "second run: conf not trusted"
[ "$(grep -cF " $k" "$T/config/autopilot-loop/trusted")" = 1 ] || fail "second run: trusted does not list the conf exactly once"
[ "$(git -C "$T/f3/repo" worktree list | grep -c autopilot)" = 1 ] || fail "second run: worktree not reused"
git -C "$T/f3/repo" rev-parse -q --verify autopilot >/dev/null || fail "second run: branch autopilot missing"
# plan accept cannot create the work branch (a regular file is in the way): path, Git's reason and a hint
new_round
sample_project "$T/f4/repo"
git add -A && git commit -qm start || fail "work branch error setup failed"
printf "===CONFIG===\nTEST_CMD='bash check.sh'\nDEMO_CMD='bash check.sh'\n===TASKS===\n- [ ] 1. one. Done when a test passes.\n" >"$FAKE_DIR/setup.txt"
"$TOOL_DIR/menu.sh" plan "$T/f4/repo/plan.md" >"$T/f4/out.txt" 2>&1 || fail "work branch error: plan failed: $(tail -3 "$T/f4/out.txt")"
echo keep >"$T/f4/repo-autopilot"
"$TOOL_DIR/menu.sh" plan accept >"$T/f4/out.txt" 2>&1 && fail "accept with a file at the worktree path exits 0"
grep -qF "$T/f4/repo-autopilot" "$T/f4/out.txt" || fail "work branch error does not name the path: $(cat "$T/f4/out.txt")"
grep -qiE 'move|remove' "$T/f4/out.txt" || fail "work branch error gives no hint what to do: $(cat "$T/f4/out.txt")"
grep -q "already exists" "$T/f4/out.txt" || fail "work branch error lacks Git's reason: $(cat "$T/f4/out.txt")"
[ "$(cat "$T/f4/repo-autopilot")" = keep ] || fail "work branch error: the file in the way was changed"
"$TOOL_DIR/menu.sh" plan discard | grep -q "Draft thrown away" || fail "plan discard does not throw the draft away"
# config directory without write permission: `plan` and `trust` name the folder and XDG_CONFIG_HOME, no raw mkdir error
if [ "$(id -u)" != 0 ]; then
    new_round
    mkdir -p "$T/ro" && chmod 555 "$T/ro"
    sample_project "$T/ro-p"
    git add -A && git commit -qm start || fail "read-only config setup failed"
    printf "TEST_CMD=true\n" >"$T/ro-p/x.conf"
    XDG_CONFIG_HOME="$T/ro/config" "$TOOL_DIR/menu.sh" plan "$T/ro-p/plan.md" >"$T/ro-out1.txt" 2>&1 && { chmod 755 "$T/ro"; fail "plan with a read-only config dir exits 0"; }
    XDG_CONFIG_HOME="$T/ro/config" "$TOOL_DIR/menu.sh" trust "$T/ro-p/x.conf" >"$T/ro-out2.txt" 2>&1 && { chmod 755 "$T/ro"; fail "trust with a read-only config dir exits 0"; }
    chmod 755 "$T/ro"
    for o in "$T/ro-out1.txt" "$T/ro-out2.txt"; do
        grep -qF "$T/ro/config/autopilot-loop" "$o" || fail "read-only config dir: folder not named: $(cat "$o")"
        grep -qF XDG_CONFIG_HOME "$o" || fail "read-only config dir: no hint about XDG_CONFIG_HOME: $(cat "$o")"
        ! grep -q '^mkdir:' "$o" || fail "read-only config dir: raw mkdir error: $(cat "$o")"
    done
fi
# claude not on PATH: `plan <file>` and autopilot.sh exit early with a clear message and create nothing
mkdir -p "$T/nocl"
for c in bash env dirname readlink basename mkdir rm mv cp cat ls touch grep sed awk cut tr sort head tail wc tee date find git jq sha256sum shasum nice timeout gtimeout mktemp id ps sleep seq; do
    p=$(command -v "$c") && case $p in /*) ln -sf "$p" "$T/nocl/$c" ;; esac; done
new_round
sample_project "$T/nc-p"
git add -A && git commit -qm start || fail "no-claude plan setup failed"
PATH="$T/nocl" "$TOOL_DIR/menu.sh" plan "$T/nc-p/plan.md" >"$T/nc1.txt" 2>&1 && fail "plan without claude exits 0"
grep -q claude "$T/nc1.txt" && grep -q "not found" "$T/nc1.txt" && grep -q "claude.com/claude-code" "$T/nc1.txt" || fail "plan without claude: message incomplete: $(cat "$T/nc1.txt")"
[ ! -e "$T/nc-p/.autopilot/draft" ] || fail "plan without claude created .autopilot/draft"
new_round
sample_project "$T/nc"
printf -- '- [ ] 1. one\n' >TASKS.md
git add -A && git commit -qm start && git checkout -qb autopilot || fail "no-claude run setup failed"
mkdir -p "$T/nc-conf"
cat >"$T/nc-conf/autopilot.conf" <<EOF
WORKDIR=$T/nc
TEST_CMD='bash check.sh'
EOF
AUTOPILOT_CONF="$T/nc-conf/autopilot.conf" "$TOOL_DIR/menu.sh" trust "$T/nc-conf/autopilot.conf" >/dev/null || fail "no-claude run: trust failed"
AUTOPILOT_CONF="$T/nc-conf/autopilot.conf" MAX_RUNS=1 PATH="$T/nocl" "$TOOL_DIR/autopilot.sh" >"$T/nc2.txt" 2>&1 && fail "autopilot.sh without claude exits 0"
grep -q claude "$T/nc2.txt" && grep -q "not found" "$T/nc2.txt" && grep -q "claude.com/claude-code" "$T/nc2.txt" || fail "autopilot.sh without claude: message incomplete: $(cat "$T/nc2.txt")"
! grep -q "Run 1" "$T/nc-conf/.autopilot/log/history.log" 2>/dev/null || fail "autopilot.sh without claude started a run"
# jq not on PATH (claude is): autopilot.sh exits early with an install hint and starts no run
mkdir -p "$T/nojq"
for c in bash env dirname readlink basename mkdir rm mv cp cat ls touch grep sed awk cut tr sort head tail wc tee date find git sha256sum shasum nice timeout gtimeout mktemp id ps sleep seq; do
    p=$(command -v "$c") && case $p in /*) ln -sf "$p" "$T/nojq/$c" ;; esac; done
ln -sf "$TOOL_DIR/test/fake-claude" "$T/nojq/claude"
new_round
sample_project "$T/nj"
printf -- '- [ ] 1. one\n' >TASKS.md
git add -A && git commit -qm start && git checkout -qb autopilot || fail "no-jq run setup failed"
mkdir -p "$T/nj-conf"
cat >"$T/nj-conf/autopilot.conf" <<EOF
WORKDIR=$T/nj
TEST_CMD='bash check.sh'
EOF
AUTOPILOT_CONF="$T/nj-conf/autopilot.conf" "$TOOL_DIR/menu.sh" trust "$T/nj-conf/autopilot.conf" >/dev/null || fail "no-jq run: trust failed"
AUTOPILOT_CONF="$T/nj-conf/autopilot.conf" MAX_RUNS=1 PATH="$T/nojq" "$TOOL_DIR/autopilot.sh" >"$T/nj.txt" 2>&1 && fail "autopilot.sh without jq exits 0"
grep -q "jq not found" "$T/nj.txt" && grep -qi "install jq" "$T/nj.txt" || fail "autopilot.sh without jq: message incomplete: $(cat "$T/nj.txt")"
! grep -q "Run 1" "$T/nj-conf/.autopilot/log/history.log" 2>/dev/null || fail "autopilot.sh without jq started a run"
# Claude reports an error that is no usage limit: stop after one run, count no attempt, touch nothing
new_round
sample_project "$T/er"
printf -- '- [ ] 1. one\n' >TASKS.md
git add -A && git commit -qm start && git checkout -qb autopilot || fail "claude-error run setup failed"
mkdir -p "$T/er-conf"
cat >"$T/er-conf/autopilot.conf" <<EOF
WORKDIR=$T/er
TEST_CMD='bash check.sh'
MODELS=max
EOF
AUTOPILOT_CONF="$T/er-conf/autopilot.conf" "$TOOL_DIR/menu.sh" trust "$T/er-conf/autopilot.conf" >/dev/null || fail "claude-error run: trust failed"
echo "Invalid API key · Please run /login" >"$FAKE_DIR/error.txt"
echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/1.sh"
er_head=$(git rev-parse HEAD)
AUTOPILOT_CONF="$T/er-conf/autopilot.conf" MAX_RUNS=5 "$TOOL_DIR/autopilot.sh" >"$T/er.txt" 2>&1 && fail "claude error: autopilot.sh exits 0"
grep -qF "Invalid API key · Please run /login" "$T/er-conf/.autopilot/log/history.log" || fail "claude error: text missing in history.log: $(cat "$T/er.txt")"
[ "$(grep -o 'Run [0-9]*:' "$T/er-conf/.autopilot/log/history.log" | sort -u | wc -l)" = 1 ] || fail "claude error: more than one run: $(cat "$T/er-conf/.autopilot/log/history.log")"
[ ! -s "$T/er-conf/.autopilot/attempts" ] || [ "$(cut -d' ' -f2 "$T/er-conf/.autopilot/attempts")" = 0 ] || fail "claude error: counted as a failed attempt"
[ -z "$(git status --porcelain)" ] || fail "claude error: work directory not clean"
[ "$(git rev-parse HEAD)" = "$er_head" ] || fail "claude error: HEAD changed"
# Claude answers with raw text or nothing: `plan` names the answer file, no jq/parse errors
new_round; sample_project "$T/gb"; git add -A && git commit -qm start || fail "garbage setup failed"
for g in 'this is { not json' ''; do
    printf '%s' "$g" >"$FAKE_DIR/garbage"
    "$TOOL_DIR/menu.sh" plan "$T/gb/plan.md" >"$T/gb.txt" 2>&1 && fail "garbage '$g': plan exits 0"
    grep -q "Claude gave no usable answer" "$T/gb.txt" && grep -qF "$T/gb/.autopilot/draft/answer.txt" "$T/gb.txt" || fail "garbage '$g': message incomplete: $(cat "$T/gb.txt")"
    ! grep -qE '^(jq:|parse error)' "$T/gb.txt" || fail "garbage '$g': raw jq error shown"
done
# Reviewer hits the time limit: rejected with "time limit", not "no verdict", and no long wait
new_round; sample_project "$T/rt"
printf -- '- [ ] 1. one\n' >TASKS.md
git add -A && git commit -qm start && git checkout -qb autopilot || fail "reviewer timeout setup failed"
mkdir -p "$T/rt-conf"
cat >"$T/rt-conf/autopilot.conf" <<EOF
WORKDIR=$T/rt
TEST_CMD='bash check.sh'
MODELS=max
EOF
AUTOPILOT_CONF="$T/rt-conf/autopilot.conf" "$TOOL_DIR/menu.sh" trust "$T/rt-conf/autopilot.conf" >/dev/null || fail "reviewer timeout: trust failed"
echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/1.sh"
echo 5 >"$FAKE_DIR/review-sleep"
echo "VERDICT: ACCEPT" >"$FAKE_DIR/verdicts"
SECONDS=0; AUTOPILOT_CONF="$T/rt-conf/autopilot.conf" CLAUDE_TIMEOUT=2 MAX_RUNS=1 "$TOOL_DIR/autopilot.sh" >"$T/rt.txt" 2>&1
grep -q "time limit" "$T/rt-conf/.autopilot/log/history.log" || fail "reviewer timeout: 'time limit' missing: $(cat "$T/rt.txt")"
[ "$(grep -c "Reviewer: time limit (2), trying once more" "$T/rt-conf/.autopilot/log/history.log")" = 1 ] && grep -q "time limit (2) twice" "$T/rt-conf/.autopilot/log/history.log" ||
    fail "reviewer timeout: not retried exactly once before rejecting: $(cat "$T/rt-conf/.autopilot/log/history.log")"
! grep -q "no verdict" "$T/rt-conf/.autopilot/log/history.log" || fail "reviewer timeout: reported as no verdict: $(cat "$T/rt.txt")"
[ "$SECONDS" -lt 30 ] || fail "reviewer timeout: waited too long: $(cat "$T/rt.txt")"
! git log --format=%s | grep -q "^Autopilot:" || fail "reviewer timeout: a task was accepted: $(cat "$T/rt.txt")"
grep -q ';reviewer;opus;?;;;;xhigh;$' "$T/rt-conf/.autopilot/costs.csv" || fail "reviewer timeout: cost not recorded as unknown: $(cat "$T/rt-conf/.autopilot/costs.csv")"
# SIGTERM during a worker run: child killed, work directory reset, history line with the hint
new_round; sample_project "$T/si"
printf -- '- [ ] 1. one\n' >TASKS.md
git add -A && git commit -qm start && git checkout -qb autopilot || fail "SIGTERM setup failed"
mkdir -p "$T/si-conf"
cat >"$T/si-conf/autopilot.conf" <<EOF
WORKDIR=$T/si
TEST_CMD='bash check.sh'
EOF
AUTOPILOT_CONF="$T/si-conf/autopilot.conf" "$TOOL_DIR/menu.sh" trust "$T/si-conf/autopilot.conf" >/dev/null || fail "SIGTERM: trust failed"
echo "echo check >>checks.txt; echo new >new.txt; touch \"\$FAKE_DIR/started\"; sleep 30" >"$FAKE_DIR/steps/1.sh"
si_head=$(git rev-parse HEAD)
AUTOPILOT_CONF="$T/si-conf/autopilot.conf" MAX_RUNS=1 "$TOOL_DIR/autopilot.sh" >"$T/si.txt" 2>&1 & pid=$!
for _ in $(seq 1 50); do [ -e "$FAKE_DIR/started" ] && break; sleep 0.2; done
[ -e "$FAKE_DIR/started" ] || { kill "$pid" 2>/dev/null; fail "SIGTERM: worker step never started: $(cat "$T/si.txt")"; }
kill -TERM "$pid"; SECONDS=0
while kill -0 "$pid" 2>/dev/null && [ "$SECONDS" -lt 5 ]; do sleep 0.2; done
if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid"; fail "SIGTERM: still running after 5 s"; fi
[ "$(git rev-parse HEAD)" = "$si_head" ] || fail "SIGTERM: HEAD changed: $(cat "$T/si.txt")"
[ -z "$(git status --porcelain)" ] || fail "SIGTERM: work directory not clean: $(git status --porcelain) $(cat "$T/si.txt")"
grep -q "Interrupted during run 1" "$T/si-conf/.autopilot/log/history.log" || fail "SIGTERM: 'Interrupted during run 1' missing: $(cat "$T/si.txt")"
grep -q "autopilot start" "$T/si-conf/.autopilot/log/history.log" || fail "SIGTERM: hint 'autopilot start' missing: $(cat "$T/si.txt")"
[ "$(cat "$T/si-conf/.autopilot/outcome")" = "$(printf 'stopped\tstopped during run 1 (stop --now or a signal)')" ] || fail "SIGTERM: outcome wrong: $(cat "$T/si-conf/.autopilot/outcome")"
[ ! -e "$T/si-conf/.autopilot/lock" ] || fail "SIGTERM: lock not released"
# A lock whose PID is dead (crash) is taken over, and released at the end
new_round; echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/1.sh"; echo "VERDICT: ACCEPT" >"$FAKE_DIR/verdicts"
sleep 0 & dead=$!; wait $dead
mkdir -p "$T/si-conf/.autopilot/lock"; echo "$dead" >"$T/si-conf/.autopilot/lock/pid"
AUTOPILOT_CONF="$T/si-conf/autopilot.conf" MAX_RUNS=1 "$TOOL_DIR/autopilot.sh" >"$T/sl.txt" 2>&1 || fail "stale lock: autopilot.sh did not start: $(cat "$T/sl.txt")"
git log --format=%s | grep -q '^Autopilot:' || fail "stale lock: the run did not accept the task: $(cat "$T/sl.txt")"
[ ! -e "$T/si-conf/.autopilot/lock" ] || fail "stale lock: lock not released at the end"
# Same NAME in two folders: different tmux session names
mkdir -p "$T/sn-bin" "$T/sn1" "$T/sn2"; printf '#!/bin/bash\necho "$*" >>"%s"\nexit 1\n' "$T/sn-tmux.log" >"$T/sn-bin/tmux"; chmod +x "$T/sn-bin/tmux"
for n in sn1 sn2; do
    printf 'WORKDIR=%q\nNAME=same\n' "$T/si" >"$T/$n/autopilot.conf"
    AUTOPILOT_CONF="$T/$n/autopilot.conf" "$TOOL_DIR/menu.sh" trust "$T/$n/autopilot.conf" >/dev/null || fail "session name: trust $n failed"
    AUTOPILOT_CONF="$T/$n/autopilot.conf" PATH="$T/sn-bin:$PATH" "$TOOL_DIR/menu.sh" start >/dev/null 2>&1
done
[ -s "$T/sn-tmux.log" ] || fail "session name: start never called tmux"
n=$(grep -o -- '-t [^ ]*' "$T/sn-tmux.log" | sort -u | wc -l); [ "$n" -ge 2 ] || fail "same NAME in two folders: one tmux session name: $(cat "$T/sn-tmux.log")"
# start without tmux on PATH: non-zero, message with installation hint, no "Started"; the argument check still comes first (exit 2)
new_round
sample_project "$T/nt"
git add -A && git commit -qm start || fail "start without tmux: setup failed"
mkdir -p "$T/nt-conf"
cat >"$T/nt-conf/autopilot.conf" <<EOF
WORKDIR=$T/nt
TEST_CMD='bash check.sh'
EOF
AUTOPILOT_CONF="$T/nt-conf/autopilot.conf" "$TOOL_DIR/menu.sh" trust "$T/nt-conf/autopilot.conf" >/dev/null || fail "start without tmux: trust failed"
AUTOPILOT_CONF="$T/nt-conf/autopilot.conf" PATH="$T/nocl" "$TOOL_DIR/menu.sh" start >"$T/nt.txt" 2>&1 && fail "start without tmux exits 0"
grep -q "tmux not found" "$T/nt.txt" && grep -q "background" "$T/nt.txt" && grep -qi "install tmux" "$T/nt.txt" || fail "start without tmux: message incomplete: $(cat "$T/nt.txt")"
! grep -q Started "$T/nt.txt" || fail "start without tmux printed Started: $(cat "$T/nt.txt")"
AUTOPILOT_CONF="$T/nt-conf/autopilot.conf" PATH="$T/nocl" "$TOOL_DIR/menu.sh" start 5 >/dev/null 2>&1; [ $? -eq 2 ] || fail "start with an argument no longer exits 2"
# The plugin's signals: no project -> status exit 3 + "autopilot plan"; an untrusted conf no longer stops status
# (it reads only .autopilot/), but start says exit 4 + "autopilot trust"
mkdir -p "$T/sig/none" "$T/sig/cfg" "$T/sig/untr"; cd "$T/sig/none" || exit 1
printf 'NAME=sig\nWORKDIR=%q\n' "$T/sig/untr" >"$T/sig/untr/autopilot.conf"
env -u AUTOPILOT_CONF XDG_CONFIG_HOME="$T/sig/cfg" "$TOOL_DIR/menu.sh" status >"$T/sig/out.txt" 2>&1; rc=$?
[ $rc = 3 ] || fail "status without project: exit code $rc, expected 3: $(cat "$T/sig/out.txt")"
grep -q "autopilot plan" "$T/sig/out.txt" || fail "status without project: no 'autopilot plan' hint: $(cat "$T/sig/out.txt")"
! head -c7 "$T/sig/out.txt" | grep -q '^Status:' || fail "status without project starts with Status: $(cat "$T/sig/out.txt")"
AUTOPILOT_CONF="$T/sig/untr/autopilot.conf" XDG_CONFIG_HOME="$T/sig/cfg" "$TOOL_DIR/menu.sh" status >"$T/sig/out.txt" 2>&1 ||
    fail "status with an untrusted conf exits non-zero: $(cat "$T/sig/out.txt")"
AUTOPILOT_CONF="$T/sig/untr/autopilot.conf" XDG_CONFIG_HOME="$T/sig/cfg" "$TOOL_DIR/menu.sh" start >"$T/sig/out.txt" 2>&1; rc=$?
[ $rc = 4 ] && grep -q "autopilot trust" "$T/sig/out.txt" || fail "start with an untrusted conf: exit $rc, expected 4 with a trust hint: $(cat "$T/sig/out.txt")"
cd "$T" || exit 1
. "$TOOL_DIR/test/part_a.sh"
. "$TOOL_DIR/test/part_b.sh"
. "$TOOL_DIR/test/part_c.sh"
. "$TOOL_DIR/test/part_e.sh"
. "$TOOL_DIR/test/part_f.sh"
. "$TOOL_DIR/test/part_g.sh"
. "$TOOL_DIR/test/part_h.sh"
. "$TOOL_DIR/test/part_i.sh"
. "$TOOL_DIR/test/part_j.sh"
. "$TOOL_DIR/test/part_k.sh"
. "$TOOL_DIR/test/part_l.sh"
. "$TOOL_DIR/test/part_m.sh"
. "$TOOL_DIR/test/part_n.sh"
echo ok
