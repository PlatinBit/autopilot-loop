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
echo "echo check >>checks.txt"                                   >"$s/2.sh"   # not ticked off
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
echo "printf '[core]\n\tfsmonitor = touch $T/evil\n' >>.git/config; echo check >>checks.txt; $tick" >"$s/16.sh"  # .git tampering
printf 'VERDICT: ACCEPT\nVERDICT: REJECT: too thin\nVERDICT: REJECT: too thin\nVERDICT: ACCEPT\nVERDICT: ACCEPT\nVERDICT: ACCEPT\n' >"$FAKE_DIR/verdicts"
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
                "count line of the test command" "outside allowed paths: secret.txt"; do
    grep -q "$expected" "$v" || fail "missing in history: $expected"
done
[ "$(grep -c '^- \[x\]' TASKS.md)" = 4 ] && grep -q '^- \[~\] 2\.' TASKS.md || fail "task list wrong: $(tr '\n' ' ' <TASKS.md)"
[ "$(git log --oneline | wc -l)" = 6 ] || fail "expected 6 commits: $(git log --oneline | tr '\n' '|')"
git diff --quiet main -- accept.sh plan.md || fail "locked file was changed"
[ -z "$(git status --porcelain)" ] || fail "work directory not clean: $(git status --porcelain)"
[ ! -e code.txt ] && [ ! -e red ] || fail "rejected changes are still lying around"
grep -qx 3 "$FAKE_DIR/with-feedback" && ! grep -qx 1 "$FAKE_DIR/with-feedback" || fail "feedback not passed on (only) after a rejection"
grep -qx 1 "$FAKE_DIR/with-plan" || fail "plan was not passed to the worker"
grep -qx 1 "$FAKE_DIR/with-decisions" || fail "{DECISIONS_FILE} was not filled into the prompt"
grep -q ";accepted;.*;0.0200;" "$T/.autopilot/log/progress.csv" || fail "cost (worker + reviewer) missing in the CSV"
"$TOOL_DIR/menu.sh" grades | grep -q "^core" || fail "grade table without kind \"core\""
"$TOOL_DIR/menu.sh" costs | grep -q "Runs total: 0.21 USD" || fail "cost overview wrong: $("$TOOL_DIR/menu.sh" costs | head -1)"
"$TOOL_DIR/menu.sh" status | grep -q "4 done, 0 open, 1 blocked" || fail "status wrong"
"$TOOL_DIR/menu.sh" result | grep -q "Autopilot: \[x\] 5. \[edge\] five" || fail "result wrong"
k=$("$TOOL_DIR/menu.sh" chart) && grep -q "<svg" "$k" || fail "chart not created"
grep -qx "User file" secret.txt || fail "foreign file lost through a rename"
# Tampering with .git/config (fsmonitor would run code on the next git status): stop immediately
printf -- '- [ ] 6. [edge] six\n' >>TASKS.md && git add -A && git commit -qm "new task"
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
"$TOOL_DIR/autopilot.sh" >"$T/output2.txt" 2>&1 &
for _ in $(seq 1 40); do [ -e "$T/p2/.autopilot/WAITING" ] && break; sleep 0.5; done
[ -e "$T/p2/.autopilot/WAITING" ] || fail "supervised mode does not wait for the OK"
"$TOOL_DIR/menu.sh" status | grep -q "WAITING for your OK" || fail "status does not show the waiting"
"$TOOL_DIR/menu.sh" continue | grep -q "OK given" || fail "continue failed"
wait $! || fail "run ended with an error after the supervised step: $(tail -3 "$T/output2.txt")"
grep -q "Goal reached" "$T/p2/.autopilot/log/history.log" || fail "project not completed"

printf -- '- [ ] 2. [new] two. Done when two more tests pass.\nNot a valid sentence\n- [ ] 3. without criterion\n' >"$FAKE_DIR/planner.txt"
"$TOOL_DIR/menu.sh" propose | grep -q "1 tasks proposed" || fail "planner suggestion not filtered"
"$TOOL_DIR/menu.sh" suggestion accept | grep -q "adopted" || fail "suggestion not adopted"
grep -q '^- \[ \] 2\. \[new\] two' "$T/p2-autopilot/AUTOPILOT-TASKS.md" || fail "suggestion missing in the task list"
echo "Short report: all good." >"$FAKE_DIR/report.txt"
"$TOOL_DIR/menu.sh" report | grep -q "Short report: all good" || fail "report wrong"
[ -z "$("$TOOL_DIR/menu.sh" status --short)" ] || fail "status line shows something although nothing runs"
[ -z "$(find "$T" -name triggered)" ] || fail "command from the file name was executed later while loading"
echo ok
