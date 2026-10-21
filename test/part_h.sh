# Sourced by test_autopilot.sh (same shell: $T, $TOOL_DIR, $FAKE_DIR, fail, new_round, sample_project,
# $tick, b_project from part_b.sh, $NOTIFY_LOG stub): 0.8.0 – demo and handover, brakes that survive a
# restart, time-limit feedback, closed check chain.
# PART_H_ONLY='h1 …' runs only the named blocks (used to prove each test fails without its fix).

ph_tasks='^(checks\.txt|code\.txt|TASKS\.md|BLOCKED\.md|DECISIONS\.md)$'

# H1: counters and feedback of the first open task survive a restart; a different task resets them
ph_h1() {
    b_project "$T/ph1" <<EOF
TEST_CMD='bash check.sh'
ALLOWED='$ph_tasks'
EOF
    echo "$tick" >"$FAKE_DIR/steps/1.sh"                          # no new test: rejected
    echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/2.sh"  # restart: same task, second attempt
    echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/3.sh"  # restart with a different task
    printf 'VERDICT: ACCEPT\nVERDICT: ACCEPT\n' >"$FAKE_DIR/verdicts"
    MAX=1 "$TOOL_DIR/autopilot.sh" >"$T/ph1.txt" 2>&1 || fail "H1: first start ended with an error: $(tail -3 "$T/ph1.txt")"
    local a=$T/ph1-conf/.autopilot/attempts
    [ -s "$a" ] && [ "$(cut -d' ' -f2- "$a")" = "1 1 0 0" ] || fail "H1: attempts not saved (attempts, rejections, reviewer, time limits): $(cat "$a" 2>/dev/null)"
    grep -q "Attempt 1 of this task, previous rejections: 0" "$FAKE_DIR/last-prompt" || fail "H1: attempt number missing in the first prompt"
    MAX=1 "$TOOL_DIR/autopilot.sh" >"$T/ph1.txt" 2>&1 || fail "H1: second start ended with an error: $(tail -3 "$T/ph1.txt")"
    grep -q "Same task as last time: 1 attempts, 1 rejections" "$T/ph1-conf/.autopilot/log/history.log" || fail "H1: restart did not keep the counters: $(cat "$T/ph1-conf/.autopilot/log/history.log")"
    grep -qx 2 "$FAKE_DIR/with-feedback" || fail "H1: feedback of the first start not passed on after the restart"
    grep -q "Attempt 2 of this task, previous rejections: 1" "$FAKE_DIR/last-prompt" || fail "H1: attempt number wrong after the restart: $(grep 'Attempt' "$FAKE_DIR/last-prompt")"
    grep -q "Time budget: 45m" "$FAKE_DIR/last-prompt" || fail "H1: time budget missing in the prompt"
    grep -q "Run 1 accepted" "$T/ph1-conf/.autopilot/log/history.log" || fail "H1: second attempt not accepted"
    # the next task is a different one: no feedback, attempt 1 again
    MAX=1 "$TOOL_DIR/autopilot.sh" >"$T/ph1.txt" 2>&1 || fail "H1: third start ended with an error: $(tail -3 "$T/ph1.txt")"
    ! grep -qx 3 "$FAKE_DIR/with-feedback" || fail "H1: feedback carried over to a different task"
    grep -q "Attempt 1 of this task, previous rejections: 0" "$FAKE_DIR/last-prompt" || fail "H1: counters not reset for a different task"
}

# H2: a worker time limit gets its own feedback with the diff of the attempt, and the cost is "?"
ph_h2() {
    b_project "$T/ph2" <<EOF
TEST_CMD='bash check.sh'
ALLOWED='$ph_tasks'
EOF
    echo "echo 'rtk gradlew test' >\"\$FAKE_DIR/denied\"; echo check >>checks.txt" >"$FAKE_DIR/steps/1.sh"  # denied, no tick
    echo "echo check >>checks.txt; echo half >code.txt; exit 124" >"$FAKE_DIR/steps/2.sh"                # time limit
    MAX=2 "$TOOL_DIR/autopilot.sh" >"$T/ph2.txt" 2>&1 || fail "H2: run ended with an error: $(tail -3 "$T/ph2.txt")"
    local s=$T/ph2-conf/.autopilot
    grep -q "Run 2 rejected: aborted after 45m (time limit): work smaller, or block early with \[~\]; denied commands from the last readable run: rtk gradlew test" "$s/log/history.log" ||
        fail "H2: time limit feedback missing or without the denied commands: $(cat "$s/log/history.log")"
    grep -q "aborted after 45m" "$s/feedback.txt" && grep -q "rejected-2.patch" "$s/feedback.txt" || fail "H2: feedback.txt lacks the reason or the patch path: $(cat "$s/feedback.txt")"
    grep -q '^+half' "$s/log/rejected-2.patch" && grep -q '^+check' "$s/log/rejected-1.patch" || fail "H2: diff of the rejected attempts not saved: $(ls "$s/log")"
    grep -q ";2;rejected;.*;?;" "$s/log/progress.csv" || fail "H2: time-limit cost not recorded as ?: $(cat "$s/log/progress.csv")"
    "$TOOL_DIR/menu.sh" costs | grep -q "plus 1 runs with unknown cost" || fail "H2: costs does not name the unknown cost: $("$TOOL_DIR/menu.sh" costs)"
    [ -z "$(git status --porcelain)" ] || fail "H2: work directory not clean"
}

# H3: an acceptance test without a readable "k of n" line and a test command the worker cannot run
# stop the start before Claude runs
ph_h3() {
    b_project "$T/ph3" <<EOF
TEST_CMD='bash check.sh'
ACCEPT_CMD='echo nothing to read'
ACCEPT_FILES=(accept.sh)
ALLOWED='$ph_tasks'
EOF
    "$TOOL_DIR/menu.sh" approve >/dev/null || fail "H3: approve failed"
    echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/1.sh"
    MAX=1 "$TOOL_DIR/autopilot.sh" >"$T/ph3.txt" 2>&1 && fail "H3: start with an unreadable acceptance test exits 0"
    grep -q 'Acceptance test without a readable "k of n" line' "$T/ph3-conf/.autopilot/log/history.log" || fail "H3: unreadable acceptance test not named: $(cat "$T/ph3-conf/.autopilot/log/history.log")"
    [ ! -f "$FAKE_DIR/step-nr" ] || fail "H3: Claude ran although the acceptance test is unreadable"
    b_project "$T/ph3b" <<EOF
TEST_CMD='bash check.sh'
WORKER_TOOLS=(Read Edit 'Bash(./gradlew:*)')
ALLOWED='$ph_tasks'
EOF
    MAX=1 "$TOOL_DIR/autopilot.sh" >"$T/ph3b.txt" 2>&1 && fail "H3: start with WORKER_TOOLS that cannot run TEST_CMD exits 0"
    grep -q 'No Bash entry in WORKER_TOOLS covers the test command "bash' "$T/ph3b-conf/.autopilot/log/history.log" || fail "H3: uncovered test command not named: $(cat "$T/ph3b-conf/.autopilot/log/history.log")"
    [ ! -f "$FAKE_DIR/step-nr" ] || fail "H3: Claude ran although the worker cannot run TEST_CMD"
    # a covering entry (first word) passes, as does no Bash entry at all (the default)
    b_project "$T/ph3c" <<EOF
TEST_CMD='bash check.sh'
WORKER_TOOLS=(Read Edit 'Bash(bash check.sh:*)')
ALLOWED='$ph_tasks'
EOF
    echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/1.sh"; echo "VERDICT: ACCEPT" >"$FAKE_DIR/verdicts"
    MAX=1 "$TOOL_DIR/autopilot.sh" >"$T/ph3c.txt" 2>&1 || fail "H3: start with a covering Bash entry refused: $(tail -3 "$T/ph3c.txt")"
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
    MAX=3 "$TOOL_DIR/autopilot.sh" >"$T/ph4.txt" 2>&1 || fail "H4: run ended with an error: $(tail -3 "$T/ph4.txt")"
    local h=$T/ph4-conf/.autopilot/log/history.log
    grep -q "Run 1 rejected: code changed while blocking the task: revert your code changes before blocking (code.txt)" "$h" || fail "H4: blocking with a code change not rejected: $(cat "$h")"
    grep -q "Run 2 accepted: \[~\] 1\." "$h" && grep -q "Run 3 accepted: \[x\] 2\." "$h" || fail "H4: clean blocking run or the next task not accepted: $(cat "$h")"
    [ ! -e code.txt ] && grep -q '^- \[~\] 1\.' TASKS.md || fail "H4: code change committed or task not blocked"
}

# H5: demo red at the end: not delivered, HANDOVER.md says so, exit 1 (PLANNER=off)
ph_h5() {
    b_project "$T/ph5" <<EOF
TEST_CMD='bash check.sh'
DEMO_CMD='echo starting; echo DEMO-BROKEN; exit 3'
PLANNER=off
ALLOWED='$ph_tasks'
EOF
    for n in 1 2; do echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/$n.sh"; done
    printf 'VERDICT: ACCEPT\nVERDICT: ACCEPT\n' >"$FAKE_DIR/verdicts"
    MAX=3 "$TOOL_DIR/autopilot.sh" >"$T/ph5.txt" 2>&1 && fail "H5: red demo exits 0"
    local s=$T/ph5-conf/.autopilot
    [ "$(cat "$s/outcome")" = "$(printf 'not-delivered\tdemo failed: demo red (DEMO_CMD exit code 3)')" ] || fail "H5: outcome wrong: $(cat "$s/outcome")"
    grep -q "DEMO-BROKEN" "$s/demo.txt" || fail "H5: demo output not saved"
    head -1 "$s/HANDOVER.md" | grep -q "^# Not delivered: demo failed" || fail "H5: HANDOVER.md headline wrong: $(head -1 "$s/HANDOVER.md")"
    grep -q "DEMO-BROKEN" "$s/HANDOVER.md" && grep -q "^Tests: 1 -> 3" "$s/HANDOVER.md" || fail "H5: HANDOVER.md without proof: $(cat "$s/HANDOVER.md")"
    "$TOOL_DIR/menu.sh" summary --short | grep -q "^not delivered (demo failed: demo red (DEMO_CMD exit code 3)) - 2 done" || fail "H5: summary --short wrong: $("$TOOL_DIR/menu.sh" summary --short)"
    "$TOOL_DIR/menu.sh" status | grep -q "^Demo:        echo starting" || fail "H5: status does not show the demo command: $("$TOOL_DIR/menu.sh" status)"
}

# H6: demo green: delivered, HANDOVER.md with TRY_IT, proof and merge hint; handover command and
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
    NOTIFY_LOG=$log MAX=3 "$TOOL_DIR/autopilot.sh" >"$T/ph6.txt" 2>&1 || fail "H6: delivered run exits non-zero: $(tail -3 "$T/ph6.txt")"
    local s=$T/ph6-conf/.autopilot
    [ "$(cut -f1 "$s/outcome")" = delivered ] || fail "H6: outcome not delivered: $(cat "$s/outcome")"
    head -1 "$s/HANDOVER.md" | grep -qx "# Delivered" || fail "H6: HANDOVER.md headline wrong: $(head -1 "$s/HANDOVER.md")"
    grep -q "Run bash check.sh and read the count." "$s/HANDOVER.md" && grep -q "DEMO-OK" "$s/HANDOVER.md" &&
        grep -q "git merge autopilot" "$s/HANDOVER.md" && grep -q "Autopilot: \[x\] 2\." "$s/HANDOVER.md" ||
        fail "H6: HANDOVER.md incomplete: $(cat "$s/HANDOVER.md")"
    "$TOOL_DIR/menu.sh" handover | grep -qx "# Delivered" || fail "H6: autopilot handover does not show HANDOVER.md"
    "$TOOL_DIR/menu.sh" summary --short | grep -q "^delivered - 2 done, 0 blocked" || fail "H6: summary --short wrong: $("$TOOL_DIR/menu.sh" summary --short)"
    tail -1 "$log" | grep -q "^-u low Autopilot ph6-conf Delivered: all tasks done" || fail "H6: notification does not lead with the result: $(tail -1 "$log")"
    grep -q "## Project rules (CLAUDE.md)" "$FAKE_DIR/last-prompt" && grep -q "keep it short" "$FAKE_DIR/last-prompt" || fail "H6: CLAUDE.md missing in the worker prompt"
    grep -q "## Project rules (CLAUDE.md)" "$s/log/review-prompt.txt" && grep -q "## Test output" "$s/log/review-prompt.txt" || fail "H6: CLAUDE.md or test output missing in the review prompt"
    # an older claude without --safe-mode is refused before anything runs (hooks could rewrite commands again)
    rm -f "$FAKE_DIR/step-nr"
    FAKE_OLD_CLAUDE=1 MAX=1 "$TOOL_DIR/autopilot.sh" >"$T/ph6-old.txt" 2>&1 && fail "H6: a claude without --safe-mode is not refused"
    grep -q "claude is too old for --safe-mode" "$T/ph6-old.txt" || fail "H6: old claude not named: $(cat "$T/ph6-old.txt")"
    [ ! -f "$FAKE_DIR/step-nr" ] || fail "H6: Claude ran although it lacks --safe-mode"
    FAKE_OLD_CLAUDE=1 "$TOOL_DIR/menu.sh" doctor >"$T/ph6-doc.txt" 2>&1 && fail "H6: doctor with an old claude exits 0"
    grep -q "too old for --safe-mode" "$T/ph6-doc.txt" || fail "H6: doctor does not report the missing --safe-mode: $(cat "$T/ph6-doc.txt")"
}

# H7: MAX_REJECTIONS blocks the task instead of ending the loop; the next task goes on
ph_h7() {
    b_project "$T/ph7" <<EOF
TEST_CMD='bash check.sh'
ALLOWED='$ph_tasks'
EOF
    for n in 1 2; do echo "$tick" >"$FAKE_DIR/steps/$n.sh"; done          # no new test: rejected twice
    echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/3.sh"; echo "VERDICT: ACCEPT" >"$FAKE_DIR/verdicts"
    MAX=4 MAX_REJECTIONS=2 "$TOOL_DIR/autopilot.sh" >"$T/ph7.txt" 2>&1 || fail "H7: run ended with an error: $(tail -3 "$T/ph7.txt")"
    local h=$T/ph7-conf/.autopilot/log/history.log
    grep -q "Task blocked: 2 rejections in a row, last: The last attempt at this task was rejected. Reason: task ticked off without a new test" "$h" || fail "H7: task not blocked after MAX_REJECTIONS: $(cat "$h")"
    grep -q "Run 3 accepted: \[x\] 2\." "$h" || fail "H7: loop did not go on with the next task: $(cat "$h")"
    grep -q '^- \[~\] 1\.' TASKS.md && grep -q '^- \[x\] 2\.' TASKS.md || fail "H7: task list wrong: $(tr '\n' ' ' <TASKS.md)"
    [ "$(cut -f1 "$T/ph7-conf/.autopilot/outcome")" = not-delivered ] || fail "H7: blocked task counted as delivered: $(cat "$T/ph7-conf/.autopilot/outcome")"
}

# H8: a stall (STALL_WARN_AFTER accepted runs without acceptance progress) ends the loop: not delivered
ph_h8() {
    b_project "$T/ph8" <<EOF
TEST_CMD='bash check.sh'
ACCEPT_CMD='bash accept.sh'
ACCEPT_FILES=(accept.sh)
STALL_WARN_AFTER=1
ALLOWED='$ph_tasks'
EOF
    "$TOOL_DIR/menu.sh" approve >/dev/null || fail "H8: approve failed"
    for n in 1 2; do echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/$n.sh"; done
    printf 'VERDICT: ACCEPT\nVERDICT: ACCEPT\n' >"$FAKE_DIR/verdicts"
    MAX=2 "$TOOL_DIR/autopilot.sh" >"$T/ph8.txt" 2>&1 && fail "H8: stalled run exits 0"
    local s=$T/ph8-conf/.autopilot
    grep -q "Run 1 accepted" "$s/log/history.log" && ! grep -q "Run 2:" "$s/log/history.log" || fail "H8: loop did not stop at the stall: $(cat "$s/log/history.log")"
    [ "$(cat "$s/outcome")" = "$(printf 'not-delivered\tstalled: Accept 0 of 2 unchanged for 1 accepted runs')" ] || fail "H8: outcome wrong: $(cat "$s/outcome")"
}

# H9: planner rounds: two rounds without acceptance progress end the loop; NOT REACHABLE ends it at once
ph_h9() {
    b_project "$T/ph9" <<EOF
TEST_CMD='bash check.sh'
ACCEPT_CMD='bash accept.sh'
ACCEPT_FILES=(accept.sh)
ALLOWED='$ph_tasks'
EOF
    "$TOOL_DIR/menu.sh" approve >/dev/null || fail "H9: approve failed"
    for n in 1 2; do echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/$n.sh"; done
    printf 'VERDICT: ACCEPT\nVERDICT: ACCEPT\n' >"$FAKE_DIR/verdicts"
    printf -- '- [ ] 3. [x] three. Done when the goal is met.\n' >"$FAKE_DIR/planner.txt"
    local s=$T/ph9-conf/.autopilot
    for round in 1 2; do
        MAX=3 "$TOOL_DIR/autopilot.sh" >"$T/ph9.txt" 2>&1 || fail "H9: planner round $round exits non-zero: $(tail -3 "$T/ph9.txt")"
        grep -q "1 tasks proposed" "$s/log/history.log" || fail "H9: round $round without a suggestion: $(cat "$s/log/history.log")"
        "$TOOL_DIR/menu.sh" suggestion discard >/dev/null
    done
    [ -s "$s/log/suggestion-prev.md" ] || fail "H9: previous suggestion not kept for the planner"
    MAX=3 "$TOOL_DIR/autopilot.sh" >"$T/ph9.txt" 2>&1 && fail "H9: third planner round exits 0"
    [ "$(cat "$s/outcome")" = "$(printf 'not-delivered\ttwo planner rounds without progress (Accept 0 of 2); allow new rounds: rm %s/planner-rounds' "$s")" ] || fail "H9: outcome wrong: $(cat "$s/outcome")"
    [ "$(wc -l <"$s/planner-rounds")" = 2 ] || fail "H9: planner rounds not counted: $(cat "$s/planner-rounds")"
    # adopting a suggestion resets the rounds (new state)
    printf -- '- [ ] 9. [x] nine. Done when the goal is met.\n' >"$s/suggestion.md"
    "$TOOL_DIR/menu.sh" suggestion accept >/dev/null || fail "H9: suggestion accept failed"
    [ ! -e "$s/planner-rounds" ] || fail "H9: planner-rounds not reset by suggestion accept"
    git -C "$T/ph9" reset -q --hard HEAD~1
    # NOT REACHABLE from the planner: the reason becomes the outcome
    rm -f "$s/planner-rounds"
    echo "NOT REACHABLE: the owner must provide the API key" >"$FAKE_DIR/planner.txt"
    MAX=3 "$TOOL_DIR/autopilot.sh" >"$T/ph9.txt" 2>&1 && fail "H9: NOT REACHABLE exits 0"
    [ "$(cat "$s/outcome")" = "$(printf 'not-delivered\tNOT REACHABLE: the owner must provide the API key')" ] || fail "H9: NOT REACHABLE not in the outcome: $(cat "$s/outcome")"
    [ ! -s "$s/suggestion.md" ] || fail "H9: NOT REACHABLE left a suggestion behind"
}

# H10: stop works although the configuration was edited (no longer trusted) while the run lives
ph_h10() {
    b_project "$T/ph10" <<EOF
TEST_CMD='bash check.sh'
ALLOWED='$ph_tasks'
EOF
    local slp
    mkdir -p "$T/ph10-conf/.autopilot/lock"; sleep 30 & slp=$!; echo "$slp" >"$T/ph10-conf/.autopilot/lock/pid"
    echo "# edited during the run" >>"$AUTOPILOT_CONF"
    "$TOOL_DIR/menu.sh" stop >"$T/ph10.txt" 2>&1 || fail "H10: stop with an untrusted conf exits non-zero: $(cat "$T/ph10.txt")"
    [ -e "$T/ph10-conf/.autopilot/STOP" ] && grep -q "Stops after the current run" "$T/ph10.txt" || fail "H10: STOP not set: $(cat "$T/ph10.txt")"
    kill "$slp" 2>/dev/null; wait "$slp" 2>/dev/null; rm -rf "$T/ph10-conf/.autopilot/lock"
    "$TOOL_DIR/menu.sh" stop >"$T/ph10.txt" 2>&1; grep -q "not running" "$T/ph10.txt" || fail "H10: stop without a live run: $(cat "$T/ph10.txt")"
}

for ph in ${PART_H_ONLY:-h1 h2 h3 h4 h5 h6 h7 h8 h9 h10}; do
    "ph_$ph"
    unset AUTOPILOT_CONF; cd "$T" || exit 1
done
unset ph ph_tasks
