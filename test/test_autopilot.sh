#!/bin/bash
# Self-test for autopilot-loop with a fake `claude` (test/fake-claude): costs nothing, starts nothing real,
# touches no real settings (own XDG_CONFIG_HOME). Output "ok" = everything passed.
set -u
TOOL_DIR=$(readlink -f "$(dirname "$0")/..")
T=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
fail() { echo "FAILED: $1"; for v in "$T"/.autopilot/log/history.log "$T"/p2/.autopilot/log/history.log; do [ -f "$v" ] && { echo "--- $v"; cat "$v"; }; done; exit 1; }
mkdir -p "$T/bin" "$T/config"
ln -s "$TOOL_DIR/test/fake-claude" "$T/bin/claude"
unset PLANNER_MODEL WORKER_MODEL REVIEWER_MODEL MAX_BLOCKED STALL_WARN_AFTER  # e.g. inherited from a running autopilot
export PATH="$T/bin:$PATH" XDG_CONFIG_HOME="$T/config" FAKE_DIR="$T/fake" AUTOPILOT_LIMIT_WAIT=0 AUTOPILOT_POLL=1 MAX=30 MAX_REJECTIONS=10
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
printf -- '- [ ] 1. [core] one\n- [ ] 2. [core] two\n- [ ] 3. [edge] three\n- [ ] 4. [edge] four\n- [ ] 5. [edge] five\n' >TASKS.md
echo "User file" >secret.txt
git add -A && git commit -qm start && git checkout -qb autopilot
cat >"$T/autopilot.conf" <<'EOF'
NAME=selftest
WORKDIR=project
TEST_CMD='bash check.sh'
ACCEPT_CMD='bash accept.sh'
ACCEPT_FILES=(accept.sh)
PLAN_FILE=project/plan.md
LOCKED=(plan.md)
ALLOWED='^(checks\.txt|code\.txt|red|plan\.md|TASKS\.md|BLOCKED\.md|DECISIONS\.md)$'
FORBIDDEN_CONTENT='FORBIDDEN'
LICENCE_MIN_RUNS=2
STALL_WARN_AFTER=1
EOF
s=$FAKE_DIR/steps
echo "echo check >>checks.txt; $tick"                            >"$s/1.sh"   # accepted (stall: acceptance stays 0)
echo "echo check >>checks.txt; echo 'rtk gradlew build' >\"\$FAKE_DIR/denied\"" >"$s/2.sh"   # not ticked off, build refused
echo "$tick"                                                     >"$s/3.sh"   # without a new test
echo "echo check >>checks.txt; echo x >>accept.sh; $tick"        >"$s/4.sh"   # acceptance file: outside ALLOWED
echo "echo check >>checks.txt; echo x >>plan.md; $tick"          >"$s/5.sh"   # plan file: allowed, but locked
echo "echo check >>checks.txt; echo FORBIDDEN >code.txt; $tick"  >"$s/6.sh"   # forbidden content
echo "echo check >>checks.txt; echo \"echo 'TESTS: 99'\" >code.txt; $tick" >"$s/7.sh"  # fakes the count line
echo "echo check >>checks.txt; mv secret.txt code.txt; $tick"    >"$s/8.sh"   # rename: foreign file gone
echo "echo check >>checks.txt; $tick"                            >"$s/9.sh"   # reviewer rejects
echo "echo check >>checks.txt; $tick"                            >"$s/10.sh"  # … twice: blocked
echo "sed -i 1d checks.txt; $tick"                               >"$s/11.sh"  # tests dropped
echo "echo check >>checks.txt; touch red; $tick"                 >"$s/12.sh"  # tests red
echo "printf 'check goal\ngoal\n' >>checks.txt; $tick"           >"$s/13.sh"  # acceptance 2 of 2
echo "echo check >>checks.txt; $tick"                            >"$s/14.sh"
echo "echo check >>checks.txt; $tick"                            >"$s/15.sh"
echo "echo check >>checks.txt; exit 124"                         >"$s/16.sh"  # time limit …
echo "echo check >>checks.txt; exit 124"                         >"$s/17.sh"  # … twice on the same task: blocked
echo "echo check >>checks.txt; $tick"                            >"$s/18.sh"  # next task goes on
echo "printf '[core]\n\tfsmonitor = touch $T/evil\n' >>.git/config; echo check >>checks.txt; $tick" >"$s/19.sh"  # .git tampering
printf 'VERDICT: ACCEPT\nVERDICT: REJECT: too thin\nVERDICT: REJECT: too thin\nVERDICT: ACCEPT\nVERDICT: ACCEPT\nVERDICT: ACCEPT\nVERDICT: ACCEPT\nVERDICT: ACCEPT\n' >"$FAKE_DIR/verdicts"
export AUTOPILOT_CONF="$T/autopilot.conf"

"$TOOL_DIR/menu.sh" status >/dev/null 2>&1; [ $? = 4 ] || fail "unconfirmed configuration was loaded"
"$TOOL_DIR/menu.sh" trust "$T/autopilot.conf" >/dev/null || fail "trust failed"
"$TOOL_DIR/autopilot.sh" >/dev/null 2>&1 && fail "start without approval not refused"
grep -q "NOT approved" "$T/.autopilot/log/history.log" || fail "no message about the missing approval"
[ -f "$FAKE_DIR/step-nr" ] && fail "Claude was started despite missing approval"
"$TOOL_DIR/menu.sh" start 5 gpt >/dev/null && fail "invalid model accepted"
"$TOOL_DIR/menu.sh" approve >/dev/null || fail "approve failed"
"$TOOL_DIR/autopilot.sh" >"$T/output.txt" 2>&1 || fail "run ended with an error: $(tail -3 "$T/output.txt")"

v=$T/.autopilot/log/history.log
for expected in "Goal reached" "no task ticked off" "without a new test" "outside allowed paths: accept.sh" \
                "locked file changed: plan.md" "forbidden content" "Reviewer: too thin" "Task blocked" \
                "dropped from 2 to 1" "tests red" "Stall" "Licence granted for task kind \"edge\"" \
                "count line of the test command" "outside allowed paths: secret.txt" \
                "tool calls denied (allow them in WORKER_TOOLS, or a hook rewrote them): rtk gradlew build" \
                "denied tool calls: rtk gradlew build"; do
    grep -q "$expected" "$v" || fail "missing in history: $expected"
done
[ "$(grep -c '^- \[x\]' TASKS.md)" = 4 ] && grep -q '^- \[~\] 2\.' TASKS.md || fail "task list wrong: $(tr '\n' ' ' <TASKS.md)"
[ "$(git log --oneline | wc -l)" = 6 ] || fail "expected 6 commits: $(git log --oneline | tr '\n' '|')"
git diff --quiet main -- accept.sh plan.md || fail "locked file was changed"
[ -z "$(git status --porcelain)" ] || fail "work directory not clean: $(git status --porcelain)"
[ ! -e code.txt ] && [ ! -e red ] || fail "rejected changes are still lying around"
grep -qx 3 "$FAKE_DIR/with-feedback" && ! grep -qx 1 "$FAKE_DIR/with-feedback" || fail "feedback not passed on (only) after a rejection"
grep -qx 1 "$FAKE_DIR/with-plan" || fail "plan was not passed to the worker"
[ ! -e "$FAKE_DIR/brief-nr" ] || fail "brief written although planner and worker are the same model"
[ "$(grep -c "tool calls denied" "$v")" = 1 ] || fail "refused tool calls reported although there were none"
grep -qx 1 "$FAKE_DIR/with-decisions" || fail "{DECISIONS_FILE} was not filled into the prompt"
grep -q ";accepted;.*;0.0200;" "$T/.autopilot/log/progress.csv" || fail "cost (worker + reviewer) missing in the CSV"
"$TOOL_DIR/menu.sh" grades | grep -q "^core" || fail "grade table without kind \"core\""
"$TOOL_DIR/menu.sh" costs | grep -q "Runs total: 0.21 USD" || fail "cost overview wrong: $("$TOOL_DIR/menu.sh" costs | head -1)"
"$TOOL_DIR/menu.sh" status | grep -q "4 done, 0 open, 1 blocked" || fail "status wrong"
"$TOOL_DIR/menu.sh" result | grep -q "Autopilot: \[x\] 5. \[edge\] five" || fail "result wrong"
k=$("$TOOL_DIR/menu.sh" chart) && grep -q "<svg" "$k" || fail "chart not created"
grep -qx "User file" secret.txt || fail "foreign file lost through a rename"
# A task that hits the time limit twice is blocked, and the loop moves on to the next one
printf -- '- [ ] 6. [edge] six\n- [ ] 7. [edge] seven\n' >>TASKS.md && git add -A && git commit -qm "new tasks"
"$TOOL_DIR/autopilot.sh" >/dev/null 2>&1 || fail "run with time limits ended with an error"
grep -q "time limit reached twice" "$v" && grep -q '^- \[~\] 6\.' TASKS.md && grep -q '^- \[x\] 7\.' TASKS.md ||
    fail "task with two time limits not blocked: $(tr '\n' ' ' <TASKS.md)"
# Tampering with .git/config (fsmonitor would run code on the next git status): stop immediately
printf -- '- [ ] 8. [edge] eight\n' >>TASKS.md && git add -A && git commit -qm "new task"
"$TOOL_DIR/autopilot.sh" >/dev/null 2>&1 && fail "change to .git/config not noticed"
grep -q "changed .git (config, info or hooks)" "$v" || fail "no message about the .git change"
[ ! -e "$T/evil" ] || fail "code from .git/config was executed"
unset AUTOPILOT_CONF

# ======== Part B: project from a plan file, security filter, supervised mode, planner, report ========
new_round
sample_project "$T/p2"
plan="$T/p2/Plan 'x' \$(touch triggered).md"   # file name with an injected command
printf '# Counter\nIt should count.\n' >"$plan"
git add -A && git commit -qm start
cat >"$FAKE_DIR/setup.txt" <<'EOF'
I have looked at the project.
===CONFIG===
TEST_CMD='bash check.sh'
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

- [ ] 1. [new] one. Done when one more test passes.
EOF
"$TOOL_DIR/menu.sh" plan "$plan" >"$T/draft.txt" 2>&1 || fail "draft failed: $(tail -3 "$T/draft.txt")"
grep -q "rm -rf" "$T/draft.txt" && grep -q "Not adopted for security reasons" "$T/draft.txt" || fail "dangerous lines not reported as discarded"
[ ! -e "$T/p2-autopilot" ] || fail "draft already set things up"
"$TOOL_DIR/menu.sh" plan accept >/dev/null || fail "accept failed"
conf=$T/p2/autopilot.conf
grep -q "rm -rf\|TEST_CMD2\|injected\|(Read Bash)\|Bash(\*)\|(\.\*) passed" "$conf" && fail "dangerous line adopted into the configuration: $(cat "$conf")"
( . "$conf"; [ "$PLAN_FILE" = "$plan" ] && [ "${LOCKED[0]}" = "${plan#"$T/p2/"}" ] ) || fail "plan not entered correctly"
[ -z "$(find "$T" -name triggered)" ] || fail "command from the file name was executed"
grep -q "^TEST_COUNT_CMD=" "$conf" || fail "TEST_COUNT_CMD not adopted"
[ "$(readlink -f "$T/config/autopilot-loop/standard.conf")" = "$conf" ] || fail "standard.conf does not point to the new project"
[ -f "$T/p2-autopilot/AUTOPILOT-TASKS.md" ] || fail "task list not in the work branch"
git -C "$T/p2" status --porcelain | grep -q . && fail "project polluted by state files: $(git -C "$T/p2" status --porcelain)"
echo "SUPERVISED=on" >>"$conf"
"$TOOL_DIR/menu.sh" status >/dev/null 2>&1; [ $? = 4 ] || fail "changed configuration loaded without a new confirmation"
"$TOOL_DIR/menu.sh" trust "$conf" >/dev/null || fail "trusting again failed"

mkdir -p "$T/elsewhere" && cd "$T/elsewhere" || exit 1   # from now on without a path: standard.conf
echo "echo check >>checks.txt; sed -i '0,/^- \[ \]/s//- [x]/' AUTOPILOT-TASKS.md" >"$FAKE_DIR/steps/1.sh"
echo "VERDICT: ACCEPT" >"$FAKE_DIR/verdicts"
WORKER_MODEL=sonnet PLANNER_MODEL=opus "$TOOL_DIR/autopilot.sh" >"$T/output2.txt" 2>&1 &
for _ in $(seq 1 40); do [ -e "$T/p2/.autopilot/WAITING" ] && break; sleep 0.5; done
[ -e "$T/p2/.autopilot/WAITING" ] || fail "supervised mode does not wait for the OK"
"$TOOL_DIR/menu.sh" status | grep -q "WAITING for your OK" || fail "status does not show the waiting"
"$TOOL_DIR/menu.sh" continue | grep -q "OK given" || fail "continue failed"
wait $! || fail "run ended with an error after the supervised step: $(tail -3 "$T/output2.txt")"
grep -q "Goal reached" "$T/p2/.autopilot/log/history.log" || fail "project not completed"
# Cheaper worker than planner: the planner writes a brief, and it reaches the worker's prompt
grep -q "## Brief from the planner" "$FAKE_DIR/last-prompt" && grep -q "BRIEF: reuse check.sh" "$FAKE_DIR/last-prompt" ||
    fail "brief from the planner missing in the worker prompt"
grep -q "planner opus, worker sonnet" "$T/p2/.autopilot/log/history.log" || fail "planner model not shown at the start"
grep -q ";sonnet;sonnet;opus$" "$T/p2/.autopilot/log/progress.csv" || fail "planner column missing in the CSV"
"$TOOL_DIR/menu.sh" start 5 sonnet 3 sonnet gpt >/dev/null && fail "invalid planner model accepted"

printf -- '- [ ] 2. [new] two. Done when two more tests pass.\nNot a valid sentence\n- [ ] 3. without criterion\n' >"$FAKE_DIR/planner.txt"
"$TOOL_DIR/menu.sh" propose | grep -q "1 tasks proposed" || fail "planner suggestion not filtered"
"$TOOL_DIR/menu.sh" suggestion accept | grep -q "adopted" || fail "suggestion not adopted"
grep -q '^- \[ \] 2\. \[new\] two' "$T/p2-autopilot/AUTOPILOT-TASKS.md" || fail "suggestion missing in the task list"
echo "Short report: all good." >"$FAKE_DIR/report.txt"
"$TOOL_DIR/menu.sh" report | grep -q "Short report: all good" || fail "report wrong"
[ -z "$("$TOOL_DIR/menu.sh" status --short)" ] || fail "status line shows something although nothing runs"
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
    printf 'WORKDIR=%q\nALLOWED=x\n' "$w" >"$T/d1/autopilot.conf"
    case "$w" in /*) p=$w ;; *) p=$T/d1/$w ;; esac
    AUTOPILOT_CONF="$T/d1/autopilot.conf" "$TOOL_DIR/menu.sh" trust "$T/d1/autopilot.conf" >/dev/null || fail "trust for the WORKDIR test failed"
    AUTOPILOT_CONF="$T/d1/autopilot.conf" "$TOOL_DIR/autopilot.sh" >"$T/d1/out.txt" 2>&1 && fail "missing WORKDIR $w not refused"
    grep -qF "$p" "$T/d1/out.txt" || fail "message does not name the missing path $p: $(cat "$T/d1/out.txt")"
    grep -q "WORKDIR" "$T/d1/out.txt" || fail "message does not name WORKDIR: $(cat "$T/d1/out.txt")"
    grep -qE '^cd:|line [0-9]+:' "$T/d1/out.txt" && fail "raw shell error for a missing WORKDIR: $(cat "$T/d1/out.txt")"
done
# status with the task list deleted: name the path, no raw grep error, exit 0
mkdir -p "$T/d2/work" && printf -- '- [ ] 1. [x] one\n' >"$T/d2/work/My Tasks.md"
printf 'WORKDIR=work\nTASKS_FILE=%q\nALLOWED=x\n' "My Tasks.md" >"$T/d2/autopilot.conf"
export AUTOPILOT_CONF="$T/d2/autopilot.conf"
"$TOOL_DIR/menu.sh" trust "$AUTOPILOT_CONF" >/dev/null || fail "trust for the task list test failed"
"$TOOL_DIR/menu.sh" status | grep -q "0 done, 1 open" || fail "status with a task list wrong"
rm "$T/d2/work/My Tasks.md"
"$TOOL_DIR/menu.sh" status >"$T/d2/out.txt" 2>&1 || fail "status without a task list exits non-zero: $(cat "$T/d2/out.txt")"
grep -qF "$T/d2/work/My Tasks.md" "$T/d2/out.txt" || fail "status does not name the missing task list: $(cat "$T/d2/out.txt")"
grep -q '^grep:' "$T/d2/out.txt" && fail "raw grep error in status: $(cat "$T/d2/out.txt")"
# approve with the acceptance file gone: refused, APPROVAL untouched (absent stays absent, present stays identical)
mkdir -p "$T/d3/work" && echo "echo ok" >"$T/d3/work/accept.sh"
printf 'WORKDIR=work\nACCEPT_FILES=(accept.sh)\nALLOWED=x\n' >"$T/d3/autopilot.conf"
export AUTOPILOT_CONF="$T/d3/autopilot.conf"
"$TOOL_DIR/menu.sh" trust "$AUTOPILOT_CONF" >/dev/null || fail "trust for the approve test failed"
mv "$T/d3/work/accept.sh" "$T/d3/work/accept.old"
"$TOOL_DIR/menu.sh" approve >"$T/d3/out.txt" 2>&1 && fail "approve without acceptance files exits 0"
grep -q "approved" "$T/d3/out.txt" && fail "approve without acceptance files says approved: $(cat "$T/d3/out.txt")"
[ ! -e "$T/d3/.autopilot/APPROVAL" ] || fail "approve without acceptance files created APPROVAL"
mv "$T/d3/work/accept.old" "$T/d3/work/accept.sh"
"$TOOL_DIR/menu.sh" approve >/dev/null || fail "approve with the acceptance file failed"
before=$(sha256sum <"$T/d3/.autopilot/APPROVAL")
mv "$T/d3/work/accept.sh" "$T/d3/work/accept.old"
"$TOOL_DIR/menu.sh" approve >"$T/d3/out.txt" 2>&1 && fail "approve with a renamed acceptance file exits 0"
grep -q "approved" "$T/d3/out.txt" && fail "approve with a renamed acceptance file says approved: $(cat "$T/d3/out.txt")"
[ "$(sha256sum <"$T/d3/.autopilot/APPROVAL")" = "$before" ] || fail "approve with a renamed acceptance file changed APPROVAL"

# ======== Part E: security ========
# ACCEPT_FILES and LOCKED entries with a leading "-" are file names, not options
new_round
sample_project "$T/e1/work"
mv accept.sh ./-accept.sh && mv plan.md ./-plan.md
printf -- '- [ ] 1. [x] one\n' >TASKS.md && git add -A && git commit -qm start
cat >"$T/e1/autopilot.conf" <<'EOF'
WORKDIR=work
TEST_CMD='bash check.sh'
ACCEPT_CMD='bash ./-accept.sh'
ACCEPT_FILES=(-accept.sh)
LOCKED=(-plan.md)
ALLOWED='^(checks\.txt|-accept\.sh|-plan\.md|TASKS\.md)$'
EOF
echo "echo check >>checks.txt; echo x >>./-accept.sh; $tick" >"$FAKE_DIR/steps/1.sh"
echo "echo check >>checks.txt; echo x >>./-plan.md; $tick"   >"$FAKE_DIR/steps/2.sh"
export AUTOPILOT_CONF="$T/e1/autopilot.conf"
"$TOOL_DIR/menu.sh" trust "$AUTOPILOT_CONF" >/dev/null || fail "trust for the dash file test failed"
"$TOOL_DIR/menu.sh" approve >"$T/e1/out.txt" 2>&1 || fail "approve with ACCEPT_FILES=(-accept.sh) failed: $(cat "$T/e1/out.txt")"
"$TOOL_DIR/menu.sh" conditions | grep -qx -- './-accept.sh' || fail "conditions does not list -accept.sh"
MAX=2 "$TOOL_DIR/autopilot.sh" >"$T/e1/out.txt" 2>&1 || fail "run with a dash acceptance file ended with an error: $(tail -3 "$T/e1/out.txt")"
grep -q "NOT approved" "$T/e1/.autopilot/log/history.log" && fail "dash acceptance file not recognised as approved"
grep -q "Run 1:" "$T/e1/.autopilot/log/history.log" || fail "run with a dash acceptance file did not get past the approval check"
grep -q "Run 1 rejected: locked file changed: -accept.sh" "$T/e1/.autopilot/log/history.log" || fail "change to -accept.sh not rejected as locked"
grep -q "Run 2 rejected: locked file changed: -plan.md" "$T/e1/.autopilot/log/history.log" || fail "change to LOCKED -plan.md not rejected as locked"
[ "$(git log --oneline | wc -l)" = 1 ] && [ -z "$(git status --porcelain)" ] || fail "dash file change was committed or left behind"
# Symlinks in allowed paths: pointing outside WORKDIR (absolute or ../) rejected, pointing inside allowed
new_round
sample_project "$T/e2/work"
printf -- '- [ ] 1. [x] one\n' >TASKS.md && git add -A && git commit -qm start
start_head=$(git rev-parse HEAD)
printf 'WORKDIR=work\nTEST_CMD=%q\nALLOWED=%q\n' 'bash check.sh' '^(checks\.txt|out1|out2|in1|TASKS\.md)$' >"$T/e2/autopilot.conf"
echo "secret" >"$T/e2/outside.txt"
echo "echo check >>checks.txt; ln -s $T/e2/outside.txt out1; $tick" >"$FAKE_DIR/steps/1.sh"
echo "echo check >>checks.txt; ln -s ../outside.txt out2; $tick"    >"$FAKE_DIR/steps/2.sh"
echo "echo check >>checks.txt; ln -s checks.txt in1; $tick"         >"$FAKE_DIR/steps/3.sh"
echo "VERDICT: ACCEPT" >"$FAKE_DIR/verdicts"
export AUTOPILOT_CONF="$T/e2/autopilot.conf"
"$TOOL_DIR/menu.sh" trust "$AUTOPILOT_CONF" >/dev/null || fail "trust for the symlink test failed"
"$TOOL_DIR/menu.sh" approve >/dev/null || fail "approve for the symlink test failed"
MAX=3 "$TOOL_DIR/autopilot.sh" >"$T/e2/out.txt" 2>&1 || fail "symlink run ended with an error: $(tail -3 "$T/e2/out.txt")"
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
printf -- '- [ ] 1. [x] one\n' >TASKS.md
git -c protocol.file.allow=always submodule add -q "$T/e3/lib" sub && git add -A && git commit -qm start
start_head=$(git rev-parse HEAD)
printf 'WORKDIR=work\nTEST_CMD=%q\nALLOWED=%q\n' 'bash check.sh' '^(checks\.txt|sub|sub/.*|TASKS\.md)$' >"$T/e3/autopilot.conf"
echo "echo check >>checks.txt; echo changed >sub/lib.txt; $tick" >"$FAKE_DIR/steps/1.sh"
echo "echo check >>checks.txt; echo new >sub/new.txt; $tick"     >"$FAKE_DIR/steps/2.sh"
echo "echo check >>checks.txt; $tick"                            >"$FAKE_DIR/steps/3.sh"
echo "VERDICT: ACCEPT" >"$FAKE_DIR/verdicts"
export AUTOPILOT_CONF="$T/e3/autopilot.conf"
"$TOOL_DIR/menu.sh" trust "$AUTOPILOT_CONF" >/dev/null || fail "trust for the submodule test failed"
MAX=2 "$TOOL_DIR/autopilot.sh" >"$T/e3/out.txt" 2>&1 || fail "submodule run ended with an error: $(tail -3 "$T/e3/out.txt")"
grep -q "Run 1 rejected: .*submodule.*sub" "$T/e3/.autopilot/log/history.log" || fail "edited file inside a submodule not rejected"
grep -q "Run 2 rejected: .*submodule.*sub" "$T/e3/.autopilot/log/history.log" || fail "new file inside a submodule not rejected"
[ "$(git rev-parse HEAD)" = "$start_head" ] || fail "HEAD changed by a rejected submodule run"
[ -z "$(git status --porcelain)" ] || fail "work directory not clean after the submodule rejection: $(git status --porcelain)"
[ -z "$(git -C sub status --porcelain)" ] || fail "submodule not restored after the rejection: $(git -C sub status --porcelain)"
[ "$(cat sub/lib.txt)" = orig ] && [ ! -e sub/new.txt ] || fail "submodule files not back to the recorded state"
MAX=1 "$TOOL_DIR/autopilot.sh" >"$T/e3/out.txt" 2>&1 || fail "submodule follow-up run ended with an error: $(tail -3 "$T/e3/out.txt")"
grep -q "Run 1 accepted" "$T/e3/.autopilot/log/history.log" || fail "change outside the submodule rejected in a project with a submodule"
# Prompt placeholders are filled in literally, even with & (bash 5.2 patsub_replacement) or a backslash
new_round
sample_project "$T/e4/work"
printf -- '- [ ] 1. [x] one\n' >TASKS.md && git add -A && git commit -qm start
printf 'WORKDIR=work\nTEST_CMD=%q\nACCEPT_CMD=%q\nALLOWED=%q\n' 'bash check.sh && true' 'printf "%s\n" x >/dev/null; bash accept.sh' \
    '^(checks\.txt|TASKS\.md)$' >"$T/e4/autopilot.conf"
echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/1.sh"
echo "VERDICT: ACCEPT" >"$FAKE_DIR/verdicts"
export AUTOPILOT_CONF="$T/e4/autopilot.conf"
"$TOOL_DIR/menu.sh" trust "$AUTOPILOT_CONF" >/dev/null || fail "trust for the placeholder test failed"
"$TOOL_DIR/menu.sh" approve >/dev/null || fail "approve for the placeholder test failed"
MAX=1 "$TOOL_DIR/autopilot.sh" >"$T/e4/out.txt" 2>&1 || fail "placeholder run ended with an error: $(tail -3 "$T/e4/out.txt")"
grep -qF 'Run `bash check.sh && true` and fix' "$FAKE_DIR/last-prompt" || fail "TEST_CMD with & not filled in literally: $(grep -m1 'and fix' "$FAKE_DIR/last-prompt")"
grep -qF 'run `printf "%s\n" x >/dev/null; bash accept.sh`;' "$FAKE_DIR/last-prompt" || fail "ACCEPT_CMD with a backslash not filled in literally"
grep -qF '{TEST_CMD}' "$FAKE_DIR/last-prompt" && fail "placeholder {TEST_CMD} left in the prompt"
# Shortened task text never cuts an umlaut in half (history.log, BLOCKED.md, commit message)
new_round
sample_project "$T/e5/work"
u=$(printf 'ü%.0s' $(seq 1 60))
printf -- '- [ ] 1. [x] %s\n- [ ] 2. [x] a%s\n' "$u" "$u" >TASKS.md && git add -A && git commit -qm start
printf 'WORKDIR=work\nTEST_CMD=%q\nALLOWED=%q\n' 'bash check.sh' '^(checks\.txt|TASKS\.md|BLOCKED\.md)$' >"$T/e5/autopilot.conf"
for n in 1 2 3; do echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/$n.sh"; done
printf 'VERDICT: REJECT: no\nVERDICT: REJECT: no\nVERDICT: ACCEPT\n' >"$FAKE_DIR/verdicts"
export AUTOPILOT_CONF="$T/e5/autopilot.conf"
"$TOOL_DIR/menu.sh" trust "$AUTOPILOT_CONF" >/dev/null || fail "trust for the umlaut test failed"
LC_ALL=C.UTF-8 MAX=3 "$TOOL_DIR/autopilot.sh" >"$T/e5/out.txt" 2>&1 || fail "umlaut run ended with an error: $(tail -3 "$T/e5/out.txt")"
grep -q "Task blocked" "$T/e5/.autopilot/log/history.log" && grep -q "Run 3 accepted" "$T/e5/.autopilot/log/history.log" || fail "umlaut run did not block task 1 and accept task 2"
iconv -f UTF-8 -t UTF-8 "$T/e5/.autopilot/log/history.log" >/dev/null 2>&1 || fail "history.log contains a cut umlaut"
iconv -f UTF-8 -t UTF-8 BLOCKED.md >/dev/null 2>&1 || fail "BLOCKED.md contains a cut umlaut"
git log -1 --format=%B | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 || fail "commit message contains a cut umlaut"
git log -1 --format=%B | grep -q "Autopilot: \[x\] 2\. \[x\] aü" || fail "commit message without the shortened umlaut task"
# Without a Git identity the loop stops before Claude is started
new_round
sample_project "$T/e6/work"
printf -- '- [ ] 1. [x] one\n' >TASKS.md && git add -A && git commit -qm start
git config --unset user.email && git config --unset user.name && git config user.useConfigOnly true
printf 'WORKDIR=work\nTEST_CMD=%q\nALLOWED=%q\n' 'bash check.sh' '^(checks\.txt|TASKS\.md)$' >"$T/e6/autopilot.conf"
echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/1.sh"
export AUTOPILOT_CONF="$T/e6/autopilot.conf"
"$TOOL_DIR/menu.sh" trust "$AUTOPILOT_CONF" >/dev/null || fail "trust for the identity test failed"
env -u EMAIL -u GIT_COMMITTER_EMAIL -u GIT_AUTHOR_EMAIL GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 MAX=1 \
    "$TOOL_DIR/autopilot.sh" >"$T/e6/out.txt" 2>&1 && fail "run without a Git identity not refused"
grep -q "user.email" "$T/e6/out.txt" || fail "no user.email hint without a Git identity: $(tail -3 "$T/e6/out.txt")"
grep -q "git config" "$T/e6/out.txt" || fail "no git config hint without a Git identity"
[ -f "$FAKE_DIR/step-nr" ] && fail "Claude was started without a Git identity"
git config user.email t@e.org && git config user.name T
GIT_CONFIG_GLOBAL=/dev/null MAX=1 "$TOOL_DIR/autopilot.sh" >"$T/e6/out.txt" 2>&1 || fail "run with a local Git identity refused: $(tail -3 "$T/e6/out.txt")"
[ -f "$FAKE_DIR/step-nr" ] || fail "Claude not started with a local Git identity"
unset AUTOPILOT_CONF

# ======== Part F: fresh machine ========
# Detached HEAD: plan accept takes the commit as BASE_BRANCH instead of "main"
new_round
sample_project "$T/f1/repo"
git add -A && git commit -qm start && git checkout -q --detach && git branch -qD main || fail "detached HEAD setup failed"
head=$(git rev-parse HEAD)
printf "===CONFIG===\nTEST_CMD='bash check.sh'\n===TASKS===\n- [ ] 1. [x] one. Done when a test passes.\n" >"$FAKE_DIR/setup.txt"
"$TOOL_DIR/menu.sh" plan "$T/f1/repo/plan.md" >"$T/f1/out.txt" 2>&1 || fail "draft with a detached HEAD failed: $(tail -3 "$T/f1/out.txt")"
"$TOOL_DIR/menu.sh" plan accept >"$T/f1/out.txt" 2>&1 || fail "accept with a detached HEAD failed: $(tail -3 "$T/f1/out.txt")"
( . "$T/f1/repo/autopilot.conf"; [ "$BASE_BRANCH" = "$head" ] ) || fail "BASE_BRANCH is not the detached commit: $(grep BASE_BRANCH "$T/f1/repo/autopilot.conf")"
"$TOOL_DIR/menu.sh" result >"$T/f1/out.txt" 2>&1 || fail "result with a detached-HEAD base exits non-zero: $(cat "$T/f1/out.txt")"
grep -q "fatal:" "$T/f1/out.txt" && fail "result with a detached-HEAD base shows a Git error: $(cat "$T/f1/out.txt")"
grep -q "Autopilot: tasks from plan.md" "$T/f1/out.txt" || fail "result with a detached-HEAD base does not list the new commit"
# Nested plan file, branch "trunk", path with space, $ and umlaut
new_round
R="$T/f2/my \$dir ü/repo"
mkdir -p "$R/docs/spec" && cd "$R" || fail "nested plan setup failed"
git init -q -b trunk . && git config user.email t@e.org && git config user.name T
echo 'Plan: nested.' >docs/spec/plan.md
echo 'echo "TESTS: 1 passed"' >check.sh
git add -A && git commit -qm start
git rev-parse -q --verify refs/heads/main >/dev/null && fail "nested plan setup: branch main exists"
printf "===CONFIG===\nTEST_CMD='bash check.sh'\n===TASKS===\n- [ ] 1. [x] one. Done when a test passes.\n" >"$FAKE_DIR/setup.txt"
"$TOOL_DIR/menu.sh" plan "$R/docs/spec/plan.md" >"$T/f2/out.txt" 2>&1 || fail "nested plan draft failed: $(tail -3 "$T/f2/out.txt")"
"$TOOL_DIR/menu.sh" plan accept >"$T/f2/out.txt" 2>&1 || fail "nested plan accept failed: $(tail -3 "$T/f2/out.txt")"
( . "$R/autopilot.conf"; [ "$BASE_BRANCH" = trunk ] && [ "${#LOCKED[@]}" = 1 ] && [ "${LOCKED[0]}" = docs/spec/plan.md ] && [ "$PLAN_FILE" = "$R/docs/spec/plan.md" ] && [ "$WORKDIR" = "$R-autopilot" ] ) || fail "nested plan conf wrong: $(cat "$R/autopilot.conf")"
[ -d "$R-autopilot" ] || fail "nested plan: worktree $R-autopilot missing"
cd "$T/f2"
"$TOOL_DIR/menu.sh" status >"$T/f2/status.txt" 2>&1 || fail "status exits non-zero: $(cat "$T/f2/status.txt")"
grep -qF "Plan:        $R/docs/spec/plan.md" "$T/f2/status.txt" || fail "status does not show the nested plan path: $(cat "$T/f2/status.txt")"
# plan + plan accept twice for the same project: worktree and branch reused, one trust line
new_round
sample_project "$T/f3/repo"
git add -A && git commit -qm start || fail "second-run setup failed"
printf "===CONFIG===\nTEST_CMD='bash check.sh'\n===TASKS===\n- [ ] 1. [x] one. Done when a test passes.\n" >"$FAKE_DIR/setup.txt"
for i in 1 2; do
    "$TOOL_DIR/menu.sh" plan "$T/f3/repo/plan.md" >"$T/f3/out.txt" 2>&1 || fail "plan run $i failed: $(tail -3 "$T/f3/out.txt")"
    "$TOOL_DIR/menu.sh" plan accept >"$T/f3/out.txt" 2>&1 || fail "accept run $i failed: $(tail -3 "$T/f3/out.txt")"
done
[ "$(readlink -f "$T/config/autopilot-loop/standard.conf")" = "$(readlink -f "$T/f3/repo/autopilot.conf")" ] || fail "second run: standard.conf does not point to the project"
[ "$(grep -cF " $(readlink -f "$T/f3/repo/autopilot.conf")" "$T/config/autopilot-loop/trusted")" = 1 ] || fail "second run: trusted does not list the conf exactly once"
[ "$(git -C "$T/f3/repo" worktree list | grep -c autopilot)" = 1 ] || fail "second run: worktree not reused"
git -C "$T/f3/repo" rev-parse -q --verify autopilot >/dev/null || fail "second run: branch autopilot missing"
cd "$T/f3"
"$TOOL_DIR/menu.sh" status >"$T/f3/out.txt" 2>&1; [ $? != 4 ] || fail "second run: conf not trusted: $(tail -3 "$T/f3/out.txt")"
# plan accept cannot create the work branch (a regular file is in the way): path, Git's reason and a hint
new_round
sample_project "$T/f4/repo"
git add -A && git commit -qm start || fail "work branch error setup failed"
printf "===CONFIG===\nTEST_CMD='bash check.sh'\n===TASKS===\n- [ ] 1. [x] one. Done when a test passes.\n" >"$FAKE_DIR/setup.txt"
"$TOOL_DIR/menu.sh" plan "$T/f4/repo/plan.md" >"$T/f4/out.txt" 2>&1 || fail "work branch error: plan failed: $(tail -3 "$T/f4/out.txt")"
echo keep >"$T/f4/repo-autopilot"
"$TOOL_DIR/menu.sh" plan accept >"$T/f4/out.txt" 2>&1 && fail "accept with a file at the worktree path exits 0"
grep -qF "$T/f4/repo-autopilot" "$T/f4/out.txt" || fail "work branch error does not name the path: $(cat "$T/f4/out.txt")"
grep -qiE 'move|remove' "$T/f4/out.txt" || fail "work branch error gives no hint what to do: $(cat "$T/f4/out.txt")"
grep -q "already exists" "$T/f4/out.txt" || fail "work branch error lacks Git's reason: $(cat "$T/f4/out.txt")"
[ "$(cat "$T/f4/repo-autopilot")" = keep ] || fail "work branch error: the file in the way was changed"
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
for c in bash env dirname readlink basename mkdir rm mv cp cat ls touch grep sed awk cut tr sort head tail wc tee date find git jq sha256sum shasum nice timeout gtimeout mktemp id; do
    p=$(command -v "$c") && case $p in /*) ln -sf "$p" "$T/nocl/$c" ;; esac; done
new_round
sample_project "$T/nc-p"
git add -A && git commit -qm start || fail "no-claude plan setup failed"
PATH="$T/nocl" "$TOOL_DIR/menu.sh" plan "$T/nc-p/plan.md" >"$T/nc1.txt" 2>&1 && fail "plan without claude exits 0"
grep -q claude "$T/nc1.txt" && grep -q "not found" "$T/nc1.txt" && grep -q "claude.com/claude-code" "$T/nc1.txt" || fail "plan without claude: message incomplete: $(cat "$T/nc1.txt")"
[ ! -e "$T/nc-p/.autopilot/draft" ] || fail "plan without claude created .autopilot/draft"
new_round
sample_project "$T/nc"
printf -- '- [ ] 1. [x] one\n' >TASKS.md
git add -A && git commit -qm start && git checkout -qb autopilot || fail "no-claude run setup failed"
mkdir -p "$T/nc-conf"
cat >"$T/nc-conf/autopilot.conf" <<EOF
WORKDIR=$T/nc
TEST_CMD='bash check.sh'
ALLOWED='^checks\.txt\$'
EOF
AUTOPILOT_CONF="$T/nc-conf/autopilot.conf" "$TOOL_DIR/menu.sh" trust "$T/nc-conf/autopilot.conf" >/dev/null || fail "no-claude run: trust failed"
AUTOPILOT_CONF="$T/nc-conf/autopilot.conf" MAX=1 PATH="$T/nocl" "$TOOL_DIR/autopilot.sh" >"$T/nc2.txt" 2>&1 && fail "autopilot.sh without claude exits 0"
grep -q claude "$T/nc2.txt" && grep -q "not found" "$T/nc2.txt" && grep -q "claude.com/claude-code" "$T/nc2.txt" || fail "autopilot.sh without claude: message incomplete: $(cat "$T/nc2.txt")"
! grep -q "Run 1" "$T/nc-conf/.autopilot/log/history.log" 2>/dev/null || fail "autopilot.sh without claude started a run"
# Claude reports an error that is no usage limit: stop after one run, count no rejection, touch nothing
new_round
sample_project "$T/er"
printf -- '- [ ] 1. [x] one\n' >TASKS.md
git add -A && git commit -qm start && git checkout -qb autopilot || fail "claude-error run setup failed"
mkdir -p "$T/er-conf"
cat >"$T/er-conf/autopilot.conf" <<EOF
WORKDIR=$T/er
TEST_CMD='bash check.sh'
ALLOWED='^checks\.txt\$'
EOF
AUTOPILOT_CONF="$T/er-conf/autopilot.conf" "$TOOL_DIR/menu.sh" trust "$T/er-conf/autopilot.conf" >/dev/null || fail "claude-error run: trust failed"
echo "Invalid API key · Please run /login" >"$FAKE_DIR/error.txt"
echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/1.sh"
er_head=$(git rev-parse HEAD)
er_grades=$(cat "$T/er-conf/.autopilot/grades.csv" 2>/dev/null)
AUTOPILOT_CONF="$T/er-conf/autopilot.conf" MAX=5 MAX_REJECTIONS=3 "$TOOL_DIR/autopilot.sh" >"$T/er.txt" 2>&1 && fail "claude error: autopilot.sh exits 0"
grep -qF "Invalid API key · Please run /login" "$T/er-conf/.autopilot/log/history.log" || fail "claude error: text missing in history.log: $(cat "$T/er.txt")"
[ "$(grep -o 'Run [0-9]*:' "$T/er-conf/.autopilot/log/history.log" | sort -u | wc -l)" = 1 ] || fail "claude error: more than one run: $(cat "$T/er-conf/.autopilot/log/history.log")"
[ "$(cat "$T/er-conf/.autopilot/grades.csv" 2>/dev/null)" = "$er_grades" ] || fail "claude error: grades.csv changed"
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
echo ok
