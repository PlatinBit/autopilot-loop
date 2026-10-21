# Sourced by test_autopilot.sh (same shell: $T, $TOOL_DIR, $FAKE_DIR, fail, new_round, sample_project,
# $tick, b_project from part_b.sh, $NOTIFY_LOG stub): demo and handover, brakes that survive a restart,
# time-limit feedback, closed check chain, the caps, status without the conf.
# PART_H_ONLY='h1 …' runs only the named blocks (used to prove each test fails without its fix).

ph_tasks='^(checks\.txt|code\.txt)$'

# H1: the attempt counter and feedback of the first open task survive a restart; a different task resets them
ph_h1() {
    b_project "$T/ph1" <<EOF
TEST_CMD='bash check.sh'
ALLOWED='$ph_tasks'
EOF
    echo "$tick" >"$FAKE_DIR/steps/1.sh"                          # no new test: rejected
    echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/2.sh"  # restart: same task, second attempt
    echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/3.sh"  # restart with a different task
    printf 'VERDICT: ACCEPT\nVERDICT: ACCEPT\n' >"$FAKE_DIR/verdicts"
    MAX_RUNS=1 "$TOOL_DIR/autopilot.sh" >"$T/ph1.txt" 2>&1 || fail "H1: first start ended with an error: $(tail -3 "$T/ph1.txt")"
    local a=$T/ph1-conf/.autopilot/attempts
    [ -s "$a" ] && [ "$(cut -d' ' -f2- "$a")" = 1 ] || fail "H1: failed attempts not saved: $(cat "$a" 2>/dev/null)"
    grep -q "Attempt 1 of at most 3 for this task" "$FAKE_DIR/last-prompt" || fail "H1: attempt number missing in the first prompt"
    MAX_RUNS=1 "$TOOL_DIR/autopilot.sh" >"$T/ph1.txt" 2>&1 || fail "H1: second start ended with an error: $(tail -3 "$T/ph1.txt")"
    grep -q "Same task as last time: 1 failed attempts so far" "$T/ph1-conf/.autopilot/log/history.log" || fail "H1: restart did not keep the counter: $(cat "$T/ph1-conf/.autopilot/log/history.log")"
    grep -qx 2 "$FAKE_DIR/with-feedback" || fail "H1: feedback of the first start not passed on after the restart"
    grep -q "Attempt 2 of at most 3 for this task" "$FAKE_DIR/last-prompt" || fail "H1: attempt number wrong after the restart: $(grep 'Attempt' "$FAKE_DIR/last-prompt")"
    grep -q "Time budget: 45m" "$FAKE_DIR/last-prompt" || fail "H1: time budget missing in the prompt"
    grep -q "Run 1 accepted" "$T/ph1-conf/.autopilot/log/history.log" || fail "H1: second attempt not accepted"
    # the next task is a different one: no feedback, attempt 1 again
    MAX_RUNS=1 "$TOOL_DIR/autopilot.sh" >"$T/ph1.txt" 2>&1 || fail "H1: third start ended with an error: $(tail -3 "$T/ph1.txt")"
    ! grep -qx 3 "$FAKE_DIR/with-feedback" || fail "H1: feedback carried over to a different task"
    grep -q "Attempt 1 of at most 3 for this task" "$FAKE_DIR/last-prompt" || fail "H1: counter not reset for a different task"
}

# H2: a worker time limit gets its own feedback with the diff of the attempt, and the cost is "?"
ph_h2() {
    b_project "$T/ph2" <<EOF
TEST_CMD='bash check.sh'
ALLOWED='$ph_tasks'
EOF
    echo "echo 'rtk gradlew test' >\"\$FAKE_DIR/denied\"; echo check >>checks.txt" >"$FAKE_DIR/steps/1.sh"  # denied, no tick
    echo "echo check >>checks.txt; echo half >code.txt; exit 124" >"$FAKE_DIR/steps/2.sh"                # time limit
    MAX_RUNS=2 "$TOOL_DIR/autopilot.sh" >"$T/ph2.txt" 2>&1 || fail "H2: run ended with an error: $(tail -3 "$T/ph2.txt")"
    local s=$T/ph2-conf/.autopilot
    grep -qF 'Run 2 rejected: aborted after 45m (time limit): work smaller, or block early with [~]; denied tool calls from the last readable run: Bash `rtk gradlew test` (not covered by WORKER_TOOLS)' "$s/log/history.log" ||
        fail "H2: time limit feedback missing or without the denied commands: $(cat "$s/log/history.log")"
    grep -q "aborted after 45m" "$s/feedback.txt" && grep -q "rejected-2.patch" "$s/feedback.txt" || fail "H2: feedback.txt lacks the reason or the patch path: $(cat "$s/feedback.txt")"
    grep -q '^+half' "$s/log/rejected-2.patch" && grep -q '^+check' "$s/log/rejected-1.patch" || fail "H2: diff of the rejected attempts not saved: $(ls "$s/log")"
    grep -q ';worker;sonnet;?;;;$' "$s/costs.csv" || fail "H2: time-limit cost not recorded as ?: $(cat "$s/costs.csv")"
    "$TOOL_DIR/menu.sh" status | grep -q "worker .*(+1 calls cut off at the time limit, cost unknown)" || fail "H2: status does not name the unknown cost: $("$TOOL_DIR/menu.sh" status)"
    [ "$(cat "$s/outcome")" = "$(printf 'limit\trun cap MAX_RUNS=2 reached, 2 tasks still open')" ] || fail "H2: run cap outcome wrong: $(cat "$s/outcome")"
    [ -z "$(git status --porcelain)" ] || fail "H2: work directory not clean"
}

# H3: an acceptance test without a readable "k of n" line and a test command the worker cannot run
# stop the start before Claude runs
ph_h3() {
    b_project "$T/ph3" <<EOF
TEST_CMD='bash check.sh'
ACCEPT_CMD='echo nothing to read'
LOCKED=(accept.sh)
ALLOWED='$ph_tasks'
EOF
    echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/1.sh"
    MAX_RUNS=1 "$TOOL_DIR/autopilot.sh" >"$T/ph3.txt" 2>&1 && fail "H3: start with an unreadable acceptance test exits 0"
    grep -q 'Acceptance test without a readable "k of n" line' "$T/ph3-conf/.autopilot/log/history.log" || fail "H3: unreadable acceptance test not named: $(cat "$T/ph3-conf/.autopilot/log/history.log")"
    [ ! -f "$FAKE_DIR/step-nr" ] || fail "H3: Claude ran although the acceptance test is unreadable"
    b_project "$T/ph3b" <<EOF
TEST_CMD='bash check.sh'
WORKER_TOOLS=(Read Edit 'Bash(./gradlew:*)')
ALLOWED='$ph_tasks'
EOF
    MAX_RUNS=1 "$TOOL_DIR/autopilot.sh" >"$T/ph3b.txt" 2>&1 && fail "H3: start with WORKER_TOOLS that cannot run TEST_CMD exits 0"
    grep -q 'No Bash entry in WORKER_TOOLS covers the test command "bash' "$T/ph3b-conf/.autopilot/log/history.log" || fail "H3: uncovered test command not named: $(cat "$T/ph3b-conf/.autopilot/log/history.log")"
    [ ! -f "$FAKE_DIR/step-nr" ] || fail "H3: Claude ran although the worker cannot run TEST_CMD"
    # a covering entry (first word) passes, as does no Bash entry at all (the default)
    b_project "$T/ph3c" <<EOF
TEST_CMD='bash check.sh'
WORKER_TOOLS=(Read Edit 'Bash(bash check.sh:*)')
ALLOWED='$ph_tasks'
EOF
    echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/1.sh"; echo "VERDICT: ACCEPT" >"$FAKE_DIR/verdicts"
    MAX_RUNS=1 "$TOOL_DIR/autopilot.sh" >"$T/ph3c.txt" 2>&1 || fail "H3: start with a covering Bash entry refused: $(tail -3 "$T/ph3c.txt")"
    grep -q "Run 1 accepted" "$T/ph3c-conf/.autopilot/log/history.log" || fail "H3: run with a covering Bash entry not accepted"
}

# H4: a blocking run ([~]) that also changes code is rejected; one that changes only the notes passes
ph_h4() {
    b_project "$T/ph4" <<EOF
TEST_CMD='bash check.sh'
ALLOWED='$ph_tasks'
EOF
    local block='sed -i "0,/^- \[ \]/s//- [~]/" TASKS.md; echo "- 1: too hard" >>BLOCKED.md'
    echo "echo half >code.txt; $block" >"$FAKE_DIR/steps/1.sh"
    echo "$block" >"$FAKE_DIR/steps/2.sh"
    echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/3.sh"; echo "VERDICT: ACCEPT" >"$FAKE_DIR/verdicts"
    MAX_RUNS=3 "$TOOL_DIR/autopilot.sh" >"$T/ph4.txt" 2>&1 || fail "H4: run ended with an error: $(tail -3 "$T/ph4.txt")"
    local h=$T/ph4-conf/.autopilot/log/history.log
    grep -q "Run 1 rejected: code changed while blocking the task: revert your code changes before blocking (code.txt)" "$h" || fail "H4: blocking with a code change not rejected: $(cat "$h")"
    grep -q "Run 2 accepted: \[~\] 1\." "$h" && grep -q "Run 3 accepted: \[x\] 2\." "$h" || fail "H4: clean blocking run or the next task not accepted: $(cat "$h")"
    [ ! -e code.txt ] && grep -q '^- \[~\] 1\.' TASKS.md || fail "H4: code change committed or task not blocked"
}

# H5: demo red at the end: not delivered, HANDOVER.md with command, exit code and output, no merge advice, exit 1 (PLANNER=off)
ph_h5() {
    b_project "$T/ph5" <<EOF
TEST_CMD='bash check.sh'
DEMO_CMD='echo starting; echo DEMO-BROKEN; exit 3'
PLANNER=off
ALLOWED='$ph_tasks'
EOF
    for n in 1 2; do echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/$n.sh"; done
    printf 'VERDICT: ACCEPT\nVERDICT: ACCEPT\n' >"$FAKE_DIR/verdicts"
    MAX_RUNS=3 "$TOOL_DIR/autopilot.sh" >"$T/ph5.txt" 2>&1 && fail "H5: red demo exits 0"
    local s=$T/ph5-conf/.autopilot
    [ "$(cat "$s/outcome")" = "$(printf 'not-delivered\tdemo failed: demo red (DEMO_CMD exit code 3)')" ] || fail "H5: outcome wrong: $(cat "$s/outcome")"
    grep -q "DEMO-BROKEN" "$s/demo.txt" || fail "H5: demo output not saved"
    head -1 "$s/HANDOVER.md" | grep -q "^# Not delivered: demo failed" || fail "H5: HANDOVER.md headline wrong: $(head -1 "$s/HANDOVER.md")"
    grep -qF 'Demo: `echo starting; echo DEMO-BROKEN; exit 3` – exit code 3' "$s/HANDOVER.md" && grep -q "^DEMO-BROKEN" "$s/HANDOVER.md" ||
        fail "H5: HANDOVER.md without the demo's command, exit code or output: $(cat "$s/HANDOVER.md")"
    grep -qF 'Tests: 1 -> 3 passed, `bash check.sh` – exit code 0' "$s/HANDOVER.md" && grep -q "^TESTS: 3 passed" "$s/HANDOVER.md" ||
        fail "H5: HANDOVER.md without the test proof: $(cat "$s/HANDOVER.md")"
    [ "$(grep -c "demo red (DEMO_CMD exit code 3)" "$s/HANDOVER.md")" = 1 ] || fail "H5: the reason appears more than once in the handover"
    grep -q "git merge" "$s/HANDOVER.md" && fail "H5: a not delivered result gets merge advice"
    grep -qF "In the work directory $(cd "$T/ph5" && pwd -P) (branch autopilot, not merged into main yet)" "$s/HANDOVER.md" ||
        fail "H5: handover does not name the work directory to try it in: $(cat "$s/HANDOVER.md")"
    "$TOOL_DIR/menu.sh" status --short | grep -q "^Autopilot ph5-conf ended: not delivered (demo failed: demo red (DEMO_CMD exit code 3)) - 2 done" ||
        fail "H5: status --short wrong: $("$TOOL_DIR/menu.sh" status --short)"
    "$TOOL_DIR/menu.sh" status | grep -q "^Demo:        echo starting" || fail "H5: status does not show the demo command: $("$TOOL_DIR/menu.sh" status)"
}

# H6: demo green: delivered, HANDOVER.md with TRY_IT, where to try it, proof and merge hint; handover command and
# notification; CLAUDE.md of the project reaches worker and reviewer (--safe-mode loads it no more)
ph_h6() {
    b_project "$T/ph6" <<EOF
TEST_CMD='bash check.sh'
DEMO_CMD='echo DEMO-OK; bash check.sh'
TRY_IT='Run bash check.sh and read the count.'
ALLOWED='$ph_tasks'
EOF
    echo "Project rule: keep it short." >CLAUDE.md; git add CLAUDE.md && git commit -qm rules || fail "H6: setup failed"
    for n in 1 2; do echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/$n.sh"; done
    printf 'VERDICT: ACCEPT\nVERDICT: ACCEPT\n' >"$FAKE_DIR/verdicts"
    local log=$T/ph6-notify.log; : >"$log"
    NOTIFY_LOG=$log MAX_RUNS=3 "$TOOL_DIR/autopilot.sh" >"$T/ph6.txt" 2>&1 || fail "H6: delivered run exits non-zero: $(tail -3 "$T/ph6.txt")"
    local s=$T/ph6-conf/.autopilot
    [ "$(cut -f1 "$s/outcome")" = delivered ] || fail "H6: outcome not delivered: $(cat "$s/outcome")"
    head -1 "$s/HANDOVER.md" | grep -qx "# Delivered" || fail "H6: HANDOVER.md headline wrong: $(head -1 "$s/HANDOVER.md")"
    grep -q "Run bash check.sh and read the count." "$s/HANDOVER.md" && grep -q "DEMO-OK" "$s/HANDOVER.md" &&
        grep -q "git merge autopilot" "$s/HANDOVER.md" && grep -q "Autopilot: \[x\] 2\." "$s/HANDOVER.md" ||
        fail "H6: HANDOVER.md incomplete: $(cat "$s/HANDOVER.md")"
    grep -qF "In the work directory $(cd "$T/ph6" && pwd -P) (branch autopilot" "$s/HANDOVER.md" || fail "H6: where to try it missing"
    "$TOOL_DIR/menu.sh" handover | grep -qx "# Delivered" || fail "H6: autopilot handover does not show HANDOVER.md"
    "$TOOL_DIR/menu.sh" status --short | grep -q "^Autopilot ph6-conf ended: delivered - 2 done, 0 blocked" || fail "H6: status --short wrong: $("$TOOL_DIR/menu.sh" status --short)"
    tail -1 "$log" | grep -q "^-u low Autopilot ph6-conf Delivered: all tasks done" || fail "H6: notification does not lead with the result: $(tail -1 "$log")"
    grep -q "## Project rules (CLAUDE.md)" "$FAKE_DIR/last-prompt" && grep -q "keep it short" "$FAKE_DIR/last-prompt" || fail "H6: CLAUDE.md missing in the worker prompt"
    grep -q "## Project rules (CLAUDE.md)" "$s/log/review-prompt.txt" && grep -q "## Test output" "$s/log/review-prompt.txt" || fail "H6: CLAUDE.md or test output missing in the review prompt"
    [ ! -e "$s/STOP" ] || fail "H6: STOP left behind"
    # an older claude without --safe-mode is refused before anything runs (hooks could rewrite commands again)
    rm -f "$FAKE_DIR/step-nr"
    FAKE_OLD_CLAUDE=1 MAX_RUNS=1 "$TOOL_DIR/autopilot.sh" >"$T/ph6-old.txt" 2>&1 && fail "H6: a claude without --safe-mode is not refused"
    grep -q "claude is too old for --safe-mode" "$T/ph6-old.txt" || fail "H6: old claude not named: $(cat "$T/ph6-old.txt")"
    [ ! -f "$FAKE_DIR/step-nr" ] || fail "H6: Claude ran although it lacks --safe-mode"
    FAKE_OLD_CLAUDE=1 "$TOOL_DIR/menu.sh" doctor >"$T/ph6-doc.txt" 2>&1 && fail "H6: doctor with an old claude exits 0"
    grep -q "too old for --safe-mode" "$T/ph6-doc.txt" || fail "H6: doctor does not report the missing --safe-mode: $(cat "$T/ph6-doc.txt")"
}

# H7: ATTEMPTS failed attempts block the task instead of ending the loop; the next task goes on
ph_h7() {
    b_project "$T/ph7" <<EOF
TEST_CMD='bash check.sh'
ALLOWED='$ph_tasks'
EOF
    for n in 1 2; do echo "$tick" >"$FAKE_DIR/steps/$n.sh"; done          # no new test: rejected twice
    echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/3.sh"; echo "VERDICT: ACCEPT" >"$FAKE_DIR/verdicts"
    MAX_RUNS=4 ATTEMPTS=2 "$TOOL_DIR/autopilot.sh" >"$T/ph7.txt" 2>&1 || fail "H7: run ended with an error: $(tail -3 "$T/ph7.txt")"
    local h=$T/ph7-conf/.autopilot/log/history.log
    grep -q "Task blocked: 2 failed attempts, last: task ticked off without a new test" "$h" || fail "H7: task not blocked after ATTEMPTS: $(cat "$h")"
    grep -q "Run 3 accepted: \[x\] 2\." "$h" || fail "H7: loop did not go on with the next task: $(cat "$h")"
    grep -q '^- \[~\] 1\.' TASKS.md && grep -q '^- \[x\] 2\.' TASKS.md || fail "H7: task list wrong: $(tr '\n' ' ' <TASKS.md)"
    [ "$(cut -f1 "$T/ph7-conf/.autopilot/outcome")" = not-delivered ] || fail "H7: blocked task counted as delivered: $(cat "$T/ph7-conf/.autopilot/outcome")"
}

# H8: NO_PROGRESS accepted runs without acceptance progress end the loop: not delivered
ph_h8() {
    b_project "$T/ph8" <<EOF
TEST_CMD='bash check.sh'
ACCEPT_CMD='bash accept.sh'
LOCKED=(accept.sh)
NO_PROGRESS=1
ALLOWED='$ph_tasks'
EOF
    for n in 1 2; do echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/$n.sh"; done
    printf 'VERDICT: ACCEPT\nVERDICT: ACCEPT\n' >"$FAKE_DIR/verdicts"
    MAX_RUNS=2 "$TOOL_DIR/autopilot.sh" >"$T/ph8.txt" 2>&1 && fail "H8: run without progress exits 0"
    local s=$T/ph8-conf/.autopilot
    grep -q "Run 1 accepted" "$s/log/history.log" && ! grep -q "Run 2:" "$s/log/history.log" || fail "H8: loop did not stop without progress: $(cat "$s/log/history.log")"
    [ "$(cat "$s/outcome")" = "$(printf 'not-delivered\tno progress: Accept 0 of 2 unchanged for 1 accepted runs')" ] || fail "H8: outcome wrong: $(cat "$s/outcome")"
}

# H9: planner rounds: two rounds without acceptance progress end the loop; NOT REACHABLE ends it at once;
# a red demo reaches the planner with its command, exit code and output
ph_h9() {
    b_project "$T/ph9" <<EOF
TEST_CMD='bash check.sh'
ACCEPT_CMD='bash accept.sh'
LOCKED=(accept.sh)
ALLOWED='$ph_tasks'
EOF
    for n in 1 2; do echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/$n.sh"; done
    printf 'VERDICT: ACCEPT\nVERDICT: ACCEPT\n' >"$FAKE_DIR/verdicts"
    printf -- '- [ ] 3. three. Done when the goal is met.\n' >"$FAKE_DIR/planner.txt"
    local s=$T/ph9-conf/.autopilot
    for round in 1 2; do
        MAX_RUNS=3 "$TOOL_DIR/autopilot.sh" >"$T/ph9.txt" 2>&1 || fail "H9: planner round $round exits non-zero: $(tail -3 "$T/ph9.txt")"
        grep -q "Planner: 1 tasks proposed" "$s/log/history.log" || fail "H9: round $round without a suggestion: $(cat "$s/log/history.log")"
        "$TOOL_DIR/menu.sh" plan discard | grep -q "Planner suggestion thrown away" || fail "H9: plan discard of the suggestion failed"
    done
    [ -s "$s/log/suggestion-prev.md" ] || fail "H9: previous suggestion not kept for the planner"
    grep -q ';planner;opus;0.01;' "$s/costs.csv" || fail "H9: planner calls missing in costs.csv"
    MAX_RUNS=3 "$TOOL_DIR/autopilot.sh" >"$T/ph9.txt" 2>&1 && fail "H9: third planner round exits 0"
    [ "$(cat "$s/outcome")" = "$(printf 'not-delivered\tno progress (Accept 0 of 2) after two planner rounds')" ] || fail "H9: outcome wrong: $(cat "$s/outcome")"
    [ "$(cat "$s/no-progress")" = "0 12" ] || fail "H9: two accepted runs and two planner rounds (half of NO_PROGRESS each) not counted: $(cat "$s/no-progress")"
    # adopting a suggestion resets the brake (new state)
    printf -- '- [ ] 9. nine. Done when the goal is met.\n' >"$s/suggestion.md"
    "$TOOL_DIR/menu.sh" plan accept >/dev/null || fail "H9: plan accept of the suggestion failed"
    [ ! -e "$s/no-progress" ] || fail "H9: no-progress not reset by adopting a suggestion"
    git -C "$T/ph9" reset -q --hard HEAD~1
    # NOT REACHABLE from the planner: the reason becomes the outcome
    echo "NOT REACHABLE: the owner must provide the API key" >"$FAKE_DIR/planner.txt"
    MAX_RUNS=3 "$TOOL_DIR/autopilot.sh" >"$T/ph9.txt" 2>&1 && fail "H9: NOT REACHABLE exits 0"
    [ "$(cat "$s/outcome")" = "$(printf 'not-delivered\tNOT REACHABLE: the owner must provide the API key')" ] || fail "H9: NOT REACHABLE not in the outcome: $(cat "$s/outcome")"
    [ ! -s "$s/suggestion.md" ] || fail "H9: NOT REACHABLE left a suggestion behind"
    # demo red with the planner on: it sees DEMO_CMD, exit code and output
    b_project "$T/ph9d" <<EOF
TEST_CMD='bash check.sh'
DEMO_CMD='echo DEMO-SAYS-NO; exit 4'
ALLOWED='$ph_tasks'
EOF
    for n in 1 2; do echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/$n.sh"; done
    printf 'VERDICT: ACCEPT\nVERDICT: ACCEPT\n' >"$FAKE_DIR/verdicts"; printf -- '- [ ] 3. three. Done when the demo works.\n' >"$FAKE_DIR/planner.txt"
    MAX_RUNS=3 "$TOOL_DIR/autopilot.sh" >"$T/ph9d.txt" 2>&1 || fail "H9: red demo with the planner exits non-zero: $(tail -3 "$T/ph9d.txt")"
    grep -qF '`echo DEMO-SAYS-NO; exit 4` – exit code 4' "$FAKE_DIR/planner-prompt" && grep -q "^DEMO-SAYS-NO" "$FAKE_DIR/planner-prompt" ||
        fail "H9: the planner does not see the demo's command, exit code and output: $(cat "$FAKE_DIR/planner-prompt")"
}

# H10: stop, status and handover work although the configuration was edited (untrusted, even broken) during the run:
# they read only .autopilot/
ph_h10() {
    b_project "$T/ph10" <<EOF
TEST_CMD='bash check.sh'
DEMO_CMD='bash check.sh'
ALLOWED='$ph_tasks'
EOF
    echo "touch \"\$FAKE_DIR/started\"; while [ ! -e \"\$FAKE_DIR/go\" ]; do sleep 0.2; done; echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/1.sh"
    echo "VERDICT: ACCEPT" >"$FAKE_DIR/verdicts"
    MAX_RUNS=1 "$TOOL_DIR/autopilot.sh" >"$T/ph10-run.txt" 2>&1 & local run=$!
    for _ in $(seq 1 50); do [ -e "$FAKE_DIR/started" ] && break; sleep 0.2; done
    echo 'this is ( not bash' >>"$AUTOPILOT_CONF"
    "$TOOL_DIR/menu.sh" status >"$T/ph10.txt" 2>&1 || fail "H10: status with a broken conf exits non-zero: $(cat "$T/ph10.txt")"
    grep -q "^Status: *running – run 1 of at most 1" "$T/ph10.txt" || fail "H10: status with a broken conf: $(cat "$T/ph10.txt")"
    "$TOOL_DIR/menu.sh" status --short | grep -q "^Autopilot ph10-conf: run 1/1" || fail "H10: status --short with a broken conf: $("$TOOL_DIR/menu.sh" status --short)"
    "$TOOL_DIR/menu.sh" stop >"$T/ph10.txt" 2>&1 || fail "H10: stop with a broken conf exits non-zero: $(cat "$T/ph10.txt")"
    [ -e "$T/ph10-conf/.autopilot/STOP" ] && grep -q "Stops after the current run" "$T/ph10.txt" || fail "H10: STOP not set: $(cat "$T/ph10.txt")"
    touch "$FAKE_DIR/go"; wait "$run"
    [ "$(cut -f1 "$T/ph10-conf/.autopilot/outcome")" = stopped ] || fail "H10: STOP not honoured: $(cat "$T/ph10-conf/.autopilot/outcome")"
    [ ! -e "$T/ph10-conf/.autopilot/STOP" ] || fail "H10: STOP not removed at the end"
    "$TOOL_DIR/menu.sh" handover | grep -q "^# Not delivered: stopped by you after 1 runs" || fail "H10: handover with a broken conf: $("$TOOL_DIR/menu.sh" handover)"
    "$TOOL_DIR/menu.sh" stop >"$T/ph10.txt" 2>&1; grep -q "not running" "$T/ph10.txt" || fail "H10: stop without a live run: $(cat "$T/ph10.txt")"
}

# H11: STOP during the demo ends the demo: outcome stopped, STOP removed; a demo without output says so
ph_h11() {
    b_project "$T/ph11" <<EOF
TEST_CMD='bash check.sh'
DEMO_CMD='touch "\$FAKE_DIR/demo-started"; sleep 30'
ALLOWED='$ph_tasks'
EOF
    for n in 1 2; do echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/$n.sh"; done
    printf 'VERDICT: ACCEPT\nVERDICT: ACCEPT\n' >"$FAKE_DIR/verdicts"
    SECONDS=0; MAX_RUNS=3 "$TOOL_DIR/autopilot.sh" >"$T/ph11.txt" 2>&1 & local run=$!
    for _ in $(seq 1 100); do [ -e "$FAKE_DIR/demo-started" ] && break; sleep 0.2; done
    [ -e "$FAKE_DIR/demo-started" ] || fail "H11: demo never started: $(cat "$T/ph11.txt")"
    "$TOOL_DIR/menu.sh" stop >/dev/null
    wait "$run" || fail "H11: stop during the demo exits non-zero: $(tail -3 "$T/ph11.txt")"
    [ "$SECONDS" -lt 20 ] || fail "H11: STOP did not end the demo (${SECONDS}s)"
    [ "$(cat "$T/ph11-conf/.autopilot/outcome")" = "$(printf 'stopped\tstopped by you during the demo')" ] || fail "H11: outcome wrong: $(cat "$T/ph11-conf/.autopilot/outcome")"
    [ ! -e "$T/ph11-conf/.autopilot/STOP" ] || fail "H11: STOP not removed at the end"
    # a green demo that prints nothing
    b_project "$T/ph11b" <<EOF
TEST_CMD='bash check.sh'
DEMO_CMD='true'
ALLOWED='$ph_tasks'
EOF
    for n in 1 2; do echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/$n.sh"; done
    printf 'VERDICT: ACCEPT\nVERDICT: ACCEPT\n' >"$FAKE_DIR/verdicts"
    MAX_RUNS=3 "$TOOL_DIR/autopilot.sh" >"$T/ph11b.txt" 2>&1 || fail "H11: silent demo: run failed: $(tail -3 "$T/ph11b.txt")"
    grep -qxF 'Demo: `true` – exit code 0' "$T/ph11b-conf/.autopilot/HANDOVER.md" && grep -qxF "(no output, exit 0)" "$T/ph11b-conf/.autopilot/HANDOVER.md" ||
        fail "H11: silent demo not shown as such: $(cat "$T/ph11b-conf/.autopilot/HANDOVER.md")"
}

# H12: without ALLOWED everything but the files that control the test command may change; the cost cap ends a start
ph_h12() {
    b_project "$T/ph12" <<EOF
TEST_CMD='bash check.sh'
EOF
    echo "echo check >>checks.txt; mkdir -p web; echo '{}' >web/package.json; $tick" >"$FAKE_DIR/steps/1.sh"
    echo "echo check >>checks.txt; mkdir -p src; echo x >src/any.txt; $tick" >"$FAKE_DIR/steps/2.sh"
    echo "VERDICT: ACCEPT" >"$FAKE_DIR/verdicts"
    MAX_RUNS=2 "$TOOL_DIR/autopilot.sh" >"$T/ph12.txt" 2>&1 || fail "H12: run failed: $(tail -3 "$T/ph12.txt")"
    local h=$T/ph12-conf/.autopilot/log/history.log
    grep -q "Run 1 rejected: change to a file that controls the test command: web/package.json" "$h" || fail "H12: package.json not refused without ALLOWED: $(cat "$h")"
    grep -q "Run 2 accepted" "$h" || fail "H12: an ordinary file refused without ALLOWED: $(cat "$h")"
    # cost cap: every call costs 0.01, so 0.02 USD is used up after the first run (brief, worker, reviewer)
    echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/3.sh"; printf "VERDICT: ACCEPT\nVERDICT: ACCEPT\n" >"$FAKE_DIR/verdicts"
    printf -- '- [ ] 3. three\n- [ ] 4. four\n' >>TASKS.md && git add -A && git commit -qm more
    MAX_COST_USD=0.02 "$TOOL_DIR/autopilot.sh" >"$T/ph12.txt" 2>&1 || fail "H12: cost cap run failed: $(tail -3 "$T/ph12.txt")"
    [ "$(cat "$T/ph12-conf/.autopilot/outcome")" = "$(printf 'limit\tcost cap MAX_COST_USD=0.02 reached (0.03 USD), 2 tasks still open')" ] ||
        fail "H12: cost cap outcome wrong: $(cat "$T/ph12-conf/.autopilot/outcome")"
}

# H13: plan accept refuses a work directory below ~/.claude/ (Claude Code refuses every write there)
ph_h13() {
    new_round; mkdir -p "$T/ph13home/.claude/jobs"; sample_project "$T/ph13home/.claude/jobs/p"
    git add -A && git commit -qm start || fail "H13: setup failed"
    printf "===CONFIG===\nTEST_CMD='bash check.sh'\nDEMO_CMD='bash check.sh'\n===TASKS===\n- [ ] 1. one. Done when a test passes.\n" >"$FAKE_DIR/setup.txt"
    HOME=$T/ph13home "$TOOL_DIR/menu.sh" plan "$T/ph13home/.claude/jobs/p/plan.md" >"$T/ph13.txt" 2>&1 || fail "H13: draft failed: $(cat "$T/ph13.txt")"
    HOME=$T/ph13home "$TOOL_DIR/menu.sh" plan accept >"$T/ph13.txt" 2>&1 && fail "H13: plan accept below ~/.claude exits 0"
    grep -q "below ~/.claude/, where Claude Code refuses every write" "$T/ph13.txt" || fail "H13: no clear message: $(cat "$T/ph13.txt")"
    [ ! -e "$T/ph13home/.claude/jobs/p-autopilot" ] && [ ! -e "$T/ph13home/.claude/jobs/p/autopilot.conf" ] || fail "H13: something was set up below ~/.claude"
    HOME=$T/ph13home "$TOOL_DIR/menu.sh" plan discard >/dev/null
}

for ph in ${PART_H_ONLY:-h1 h2 h3 h4 h5 h6 h7 h8 h9 h10 h11 h12 h13}; do
    "ph_$ph"
    unset AUTOPILOT_CONF; cd "$T" || exit 1
done
unset ph ph_tasks
