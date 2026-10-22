# Sourced by test_autopilot.sh (same shell: $T, $TOOL_DIR, $FAKE_DIR, fail, new_round, sample_project,
# $tick, b_project from part_b.sh): 0.10 – task dependencies, size check, specification, pull request mode.
# PART_L_ONLY='l1 …' runs only the named blocks.
tick_n() { echo "echo check >>checks.txt; sed -i 's/^- \\[ \\] $1\\./- [x] $1./' TASKS.md"; }   # step: tick off task N
block_n() { echo "sed -i 's/^- \\[ \\] $1\\./- [~] $1./' TASKS.md; echo 'too big' >>BLOCKED.md"; }  # step: block task N

# L1: "(after N, M)" right after the number: the next task is the first open one whose dependencies are all [x];
# the prompt names it, ticking off that line (not the first open one) is accepted, status names it
pl_l1() {
    b_project "$T/pl1" <<'EOF'
TEST_CMD='bash check.sh'
EOF
    printf -- '- [ ] 1. (after 2) one\n- [ ] 2. two\n- [ ] 3. (after 1, 2) three\n' >TASKS.md && git commit -qam deps || fail "L1: setup failed"
    local n=0 t h=$T/pl1-conf/.autopilot/log/history.log
    for t in 2 1 3; do n=$((n + 1)); tick_n "$t" >"$FAKE_DIR/steps/$n.sh"; echo "VERDICT: ACCEPT" >>"$FAKE_DIR/verdicts"; done
    MAX_RUNS=1 "$TOOL_DIR/autopilot.sh" >"$T/pl1.txt" 2>&1 || fail "L1: run failed: $(tail -3 "$T/pl1.txt")"
    grep -q "Run 1: 2\. two$" "$h" && grep -q "Run 1 accepted: \[x\] 2\. two" "$h" || fail "L1: task 2 not first: $(cat "$h")"
    grep -qx 'Your task (the script picked it, line 2 of TASKS.md): - \[ \] 2\. two' "$FAKE_DIR/last-prompt" || fail "L1: prompt does not name the task: $(grep -A4 '## This run' "$FAKE_DIR/last-prompt")"
    "$TOOL_DIR/menu.sh" status | grep -qx 'Next task:   1\. (after 2) one' || fail "L1: status next task wrong: $("$TOOL_DIR/menu.sh" status | grep Next)"
    MAX_RUNS=5 "$TOOL_DIR/autopilot.sh" >"$T/pl1.txt" 2>&1
    [ "$(grep -o 'accepted: \[x\] [0-9]' "$h" | tr -d '\n')" = 'accepted: [x] 2accepted: [x] 1accepted: [x] 3' ] || fail "L1: order wrong: $(cat "$h")"
}

# L2: the worker ticks off another line than the one the script picked: rejected, the attempt counts
pl_l2() {
    b_project "$T/pl2" <<'EOF'
TEST_CMD='bash check.sh'
EOF
    printf -- '- [ ] 1. (after 2) one\n- [ ] 2. two\n' >TASKS.md && git commit -qam deps || fail "L2: setup failed"
    tick_n 1 >"$FAKE_DIR/steps/1.sh"; tick_n 2 >"$FAKE_DIR/steps/2.sh"; echo "VERDICT: ACCEPT" >"$FAKE_DIR/verdicts"
    MAX_RUNS=2 "$TOOL_DIR/autopilot.sh" >"$T/pl2.txt" 2>&1 || fail "L2: run failed: $(tail -3 "$T/pl2.txt")"
    local h=$T/pl2-conf/.autopilot/log/history.log
    grep -q "Run 1 rejected: task list changed beyond ticking off or blocking the task picked for this run (only \[ \] -> \[x\] or \[~\] of line 2 is allowed)" "$h" &&
        grep -q "Run 2 accepted: \[x\] 2\. two" "$h" && grep -q '^- \[ \] 1\. (after 2) one$' TASKS.md || fail "L2: wrong line not rejected: $(cat "$h")"
}

# L3: a task that depends on a blocked one is skipped (so is one that depends on it); when only such tasks are
# left the loop ends, and the handover names them "waiting on blocked task N"
pl_l3() {
    b_project "$T/pl3" <<'EOF'
TEST_CMD='bash check.sh'
EOF
    printf -- '- [ ] 1. one\n- [ ] 2. (after 1) two\n- [ ] 3. three\n- [ ] 4. (after 2) four\n' >TASKS.md && git commit -qam deps || fail "L3: setup failed"
    block_n 1 >"$FAKE_DIR/steps/1.sh"; tick_n 3 >"$FAKE_DIR/steps/2.sh"; echo "VERDICT: ACCEPT" >"$FAKE_DIR/verdicts"
    MAX_RUNS=5 "$TOOL_DIR/autopilot.sh" >"$T/pl3.txt" 2>&1
    local s=$T/pl3-conf/.autopilot
    grep -q "Run 2 accepted: \[x\] 3\. three" "$s/log/history.log" && [ "$(cat "$FAKE_DIR/step-nr")" = 2 ] || fail "L3: task 3 not run, or more runs: $(cat "$s/log/history.log")"
    [ "$(cat "$s/outcome")" = "$(printf 'not-delivered\t2 open tasks wait on blocked tasks')" ] || fail "L3: outcome wrong: $(cat "$s/outcome")"
    grep -qx -- '- \[ \] 2\. (after 1) two – waiting on blocked task 1' "$s/HANDOVER.md" && grep -qx -- '- \[ \] 4\. (after 2) four – waiting on task 2' "$s/HANDOVER.md" ||
        fail "L3: handover does not name the waiting tasks: $(cat "$s/HANDOVER.md")"
    "$TOOL_DIR/menu.sh" status | grep -qx 'Next task:   none – the open tasks wait on blocked tasks' || fail "L3: status next task wrong: $("$TOOL_DIR/menu.sh" status | grep Next)"
}

# L4: size check before the first attempt: a task that does not fit is replaced by its parts (N.1, N.2 with the
# task's dependencies, each part after the one before, own commit, journal entry, no run used, effort low); every
# task is checked once, the parts never; parts that drop the task's check command are not used
pl_l4() {
    b_project "$T/pl4" <<'EOF'
TEST_CMD='bash check.sh'
EOF
    printf -- '- [ ] 1. one\n- [ ] 2. (after 1) big. Done when `bash check.sh` exits 0.\n- [ ] 3. three. Done when `bash check.sh` exits 0.\n' >TASKS.md && git commit -qam size || fail "L4: setup failed"
    printf -- '- [ ] 7. part a. Done when a test passes.\n- [ ] (after 9) part b. Done when `bash check.sh` exits 0.\n' >"$FAKE_DIR/size-2.txt"
    printf -- '- [ ] x. Done when a test passes.\n- [ ] y. Done when a test passes.\n' >"$FAKE_DIR/size-3.txt"
    local n s=$T/pl4-conf/.autopilot
    for n in 1 2 3 4; do echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/$n.sh"; echo "VERDICT: ACCEPT" >>"$FAKE_DIR/verdicts"; done
    MAX_RUNS=4 "$TOOL_DIR/autopilot.sh" >"$T/pl4.txt" 2>&1 || fail "L4: run failed: $(tail -3 "$T/pl4.txt")"
    [ "$(cat TASKS.md)" = "$(printf -- '- [x] 1. one\n- [x] 2.1. (after 1) part a. Done when a test passes.\n- [x] 2.2. (after 1, 2.1) part b. Done when `bash check.sh` exits 0.\n- [x] 3. three. Done when `bash check.sh` exits 0.')" ] ||
        fail "L4: task list wrong: $(cat TASKS.md)"
    git log --format=%s | grep -qx 'Autopilot: split task 2' || fail "L4: no split commit: $(git log --format=%s)"
    grep -q "Run 2: 2\.1\. (after 1) part a" "$s/log/history.log" && grep -q "Size check: task 2 split into 2 parts" "$s/log/history.log" &&
        grep -q "Size check: task 3 does not fit one run, but the parts drop its check command – it stays" "$s/log/history.log" || fail "L4: history wrong: $(cat "$s/log/history.log")"
    grep -q '^### J[0-9]* .* script 2\. (after 1) big\..* split into 2 parts$' "$s/JOURNAL.md" || fail "L4: no journal entry: $(cat "$s/JOURNAL.md")"
    [ "$(cat "$FAKE_DIR/size-nr")" = 3 ] && [ "$(wc -l <"$s/sized")" = 5 ] || fail "L4: size checks not once per task: $(cat "$FAKE_DIR/size-nr") calls, $(wc -l <"$s/sized") sized"
    grep -q ';size;opus;0.01;100;1000;10;low$' "$s/costs.csv" && grep -q '^size .*--json-schema {.*"fits"' "$FAKE_DIR/args" || fail "L4: size call not booked or without schema"
    grep -q "^You are sizing a task" "$FAKE_DIR/size-prompt" && grep -qF -- '- [ ] 3. three.' "$FAKE_DIR/size-prompt" || fail "L4: size prompt wrong"
    MAX_RUNS=1 "$TOOL_DIR/autopilot.sh" >/dev/null 2>&1; [ "$(cat "$FAKE_DIR/size-nr")" = 3 ] || fail "L4: sized again after a restart"
}

# L5: SIZE_CHECK off by default with MODELS=cheap, off by hand, and a wrong value is refused
pl_l5() {
    local c
    for c in MODELS=cheap SIZE_CHECK=off; do
        b_project "$T/pl5" <<EOF
TEST_CMD='bash check.sh'
$c
EOF
        echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/1.sh"; echo "VERDICT: ACCEPT" >"$FAKE_DIR/verdicts"
        MAX_RUNS=1 "$TOOL_DIR/autopilot.sh" >"$T/pl5.txt" 2>&1 || fail "L5: $c: run failed: $(tail -3 "$T/pl5.txt")"
        grep -q '^size ' "$FAKE_DIR/args" && fail "L5: $c: size check ran"
        rm -rf "$T/pl5" "$T/pl5-conf"
    done
    b_project "$T/pl5" <<'EOF'
TEST_CMD='bash check.sh'
SIZE_CHECK=yes
EOF
    "$TOOL_DIR/autopilot.sh" >"$T/pl5.txt" 2>&1 && fail "L5: SIZE_CHECK=yes accepted"
    grep -q "SIZE_CHECK='yes'" "$T/pl5-conf/.autopilot/log/history.log" || fail "L5: SIZE_CHECK=yes not named"
}

# L6: plan --spec writes SPEC.md and stops; plan SPEC.md writes the plan from it and drafts; plan accept commits
# and locks SPEC.md and names it in autopilot.conf; worker, final review see it
pl_l6() {
    new_round; sample_project "$T/pl6"; git add -A && git commit -qm start || fail "L6: setup failed"
    printf '# Word counter\nCounts words.\n\n## Requirements\n1. Counts words.\n   - Example: `wc-tool a.md` → 3, exit code 0.\n\n## Non-goals\n- no GUI\n' >"$FAKE_DIR/spec.txt"
    "$TOOL_DIR/menu.sh" plan --spec "A word counter" >"$T/pl6.txt" 2>&1 || fail "L6: plan --spec failed: $(cat "$T/pl6.txt")"
    cmp -s SPEC.md "$FAKE_DIR/spec.txt" && grep -q 'Example: `wc-tool a.md`' "$T/pl6.txt" && grep -qF "autopilot plan $T/pl6/SPEC.md" "$T/pl6.txt" || fail "L6: SPEC.md not written or shown: $(cat "$T/pl6.txt")"
    grep -q "^You are writing a specification" "$FAKE_DIR/spec-prompt" && grep -q "A word counter" "$FAKE_DIR/spec-prompt" && [ ! -e "$FAKE_DIR/idea-prompt" ] && [ ! -e "$T/pl6/.autopilot/draft" ] ||
        fail "L6: --spec did more than the spec"
    "$TOOL_DIR/menu.sh" plan --spec "A word counter" >"$T/pl6.txt" 2>&1 && fail "L6: an existing SPEC.md was overwritten"
    printf '# Plan: word counter\n' >"$FAKE_DIR/idea.txt"
    printf "===CONFIG===\nTEST_CMD='bash check.sh'\nDEMO_CMD='bash check.sh'\n===TASKS===\n- [ ] 1. one. Done when a test passes.\n" >"$FAKE_DIR/setup.txt"
    "$TOOL_DIR/menu.sh" plan SPEC.md >"$T/pl6.txt" 2>&1 || fail "L6: plan SPEC.md failed: $(cat "$T/pl6.txt")"
    [ -f "$T/pl6/word-counter-plan.md" ] && grep -q "^## Specification (SPEC.md" "$FAKE_DIR/idea-prompt" && grep -q 'Example: `wc-tool a.md`' "$FAKE_DIR/idea-prompt" ||
        fail "L6: plan not written from the spec: $(ls "$T/pl6"; cat "$T/pl6.txt")"
    "$TOOL_DIR/menu.sh" plan accept >"$T/pl6.txt" 2>&1 || fail "L6: accept failed: $(cat "$T/pl6.txt")"
    [ "$(git -C "$T/pl6" show --name-only --format= HEAD | sort | tr '\n' ' ')" = "SPEC.md word-counter-plan.md " ] && [ -z "$(git -C "$T/pl6" status --porcelain)" ] ||
        fail "L6: spec and plan not committed: $(git -C "$T/pl6" show --stat HEAD)"
    grep -qx "SPEC_FILE=$T/pl6/SPEC.md" "$T/pl6/autopilot.conf" && grep -qx 'LOCKED=(word-counter-plan.md SPEC.md)' "$T/pl6/autopilot.conf" || fail "L6: conf wrong: $(cat "$T/pl6/autopilot.conf")"
    grep -q ';spec;opus;0.01;' "$T/pl6/.autopilot/costs.csv" || fail "L6: cost of the spec not booked: $(cat "$T/pl6/.autopilot/costs.csv")"
    export AUTOPILOT_CONF=$T/pl6/autopilot.conf
    echo "echo check >>checks.txt; sed -i 's/^- \\[ \\]/- [x]/' AUTOPILOT-TASKS.md" >"$FAKE_DIR/steps/1.sh"; echo "VERDICT: ACCEPT" >"$FAKE_DIR/verdicts"
    MAX_RUNS=1 SANDBOX=off "$TOOL_DIR/autopilot.sh" >"$T/pl6.txt" 2>&1 || fail "L6: run failed: $(tail -3 "$T/pl6.txt")"
    [ "$(cut -f1 "$T/pl6/.autopilot/outcome")" = delivered ] || fail "L6: not delivered: $(cat "$T/pl6/.autopilot/outcome")"
    grep -q "^## Specification (SPEC.md" "$FAKE_DIR/last-prompt" && grep -q "^## Specification (SPEC.md" "$FAKE_DIR/final-prompt" &&
        grep -q 'acceptance example' "$FAKE_DIR/final-prompt" || fail "L6: spec not in the worker or final prompt"
}

# L7: MERGE=pr – delivered pushes the work branch to origin and opens a pull request (title from the plan, body =
# the handover), BASE_BRANCH stays; PR_WAIT=on: red checks are not delivered (output to handover and planner),
# a later green round reuses the open pull request
pl_l7() {
    b_project "$T/pl7" <<EOF
TEST_CMD='bash check.sh'
DEMO_CMD='bash $T/pl7/check.sh'
PLAN_FILE=$T/pl7/plan.md
FRESH_CHECK=off
MERGE=pr
PR_WAIT=on
EOF
    git init -q --bare "$T/pl7-origin.git" && git remote add origin "$T/pl7-origin.git" && ln -sf "$TOOL_DIR/test/fake-gh" "$T/bin/gh" || fail "L7: setup failed"
    printf '# Word counter\n' >plan.md && printf -- '- [ ] 1. one #12 for @octocat\n- [ ] 2. two\n' >TASKS.md && git commit -qam plan || fail "L7: setup failed"
    local s=$T/pl7-conf/.autopilot main u=https://github.com/example/project/pull/7 n; main=$(git rev-parse main)
    for n in 1 2; do echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/$n.sh"; echo "VERDICT: ACCEPT" >>"$FAKE_DIR/verdicts"; done
    echo "build: lint failed" >"$FAKE_DIR/gh-checks.txt"; echo 1 >"$FAKE_DIR/gh-checks-rc"; echo 2 >"$FAKE_DIR/gh-nochecks"  # CI starts late
    HOME=$T AUTOPILOT_PR_POLL=0 MAX_RUNS=3 "$TOOL_DIR/autopilot.sh" >"$T/pl7.txt" 2>&1
    [ "$(git -C "$T/pl7-origin.git" rev-parse autopilot)" = "$(git rev-parse HEAD)" ] && [ "$(git rev-parse main)" = "$main" ] || fail "L7: branch not pushed, or main moved"
    grep -qx "pr create --base main --head autopilot --title Word counter --body-file $s/pr-body.md" "$FAKE_DIR/gh-args" &&
        [ "$(grep -cx "pr checks $u --watch" "$FAKE_DIR/gh-args")" = 3 ] || fail "L7: gh not called right, or \"no checks reported\" not asked again: $(cat "$FAKE_DIR/gh-args")"
    # the text: what was built, demo/tests lines; no path, log or output; ~ for the home folder; no issue link, no mention
    head -1 "$FAKE_DIR/gh-body" | grep -qx '## What was built' && grep -q '^Demo: `bash ~/pl7/check.sh` – exit code 0$' "$FAKE_DIR/gh-body" &&
        grep -q '^Tests: 1 -> 3 passed' "$FAKE_DIR/gh-body" && grep -qF 'one `#12` for `@octocat`' "$FAKE_DIR/gh-body" || fail "L7: PR text wrong: $(cat "$FAKE_DIR/gh-body")"
    ! grep -qF -e "$T" -e "$HOME" -e 'Journal' -e 'Lessons' -e 'TESTS:' "$FAKE_DIR/gh-body" || fail "L7: PR text with a path, log or output: $(cat "$FAKE_DIR/gh-body")"
    grep -q "^not-delivered	CI red: $u" "$s/outcome" && grep -q "build: lint failed" "$s/HANDOVER.md" && grep -q "build: lint failed" "$FAKE_DIR/planner-prompt" ||
        fail "L7: red checks not handled: $(cat "$s/outcome"; cat "$s/log/history.log")"
    echo 0 >"$FAKE_DIR/gh-checks-rc"
    HOME=$T MAX_RUNS=3 "$TOOL_DIR/autopilot.sh" >"$T/pl7.txt" 2>&1 || fail "L7: green round failed: $(tail -3 "$T/pl7.txt")"
    [ "$(cat "$s/outcome")" = "$(printf 'delivered\tPR opened: %s' "$u")" ] && [ "$(grep -c '^pr create' "$FAKE_DIR/gh-args")" = 1 ] || fail "L7: green round wrong: $(cat "$s/outcome"; cat "$FAKE_DIR/gh-args")"
    head -1 "$s/HANDOVER.md" | grep -qx "# Delivered, PR opened: $u" && grep -q "gh pr merge $u" "$s/HANDOVER.md" || fail "L7: handover wrong: $(head -3 "$s/HANDOVER.md")"
    "$TOOL_DIR/menu.sh" status --short | grep -q "^Autopilot pl7-conf ended: delivered, PR opened: $u" || fail "L7: status --short wrong: $("$TOOL_DIR/menu.sh" status --short)"
    "$TOOL_DIR/menu.sh" doctor | grep -q "MERGE=pr: pushes to $T/pl7-origin.git" || fail "L7: doctor does not show MERGE=pr: $("$TOOL_DIR/menu.sh" doctor)"
    rm -f "$T/bin/gh"
}

# L8: MERGE=pr start check: gh missing, not logged in, no origin – each refused before any Claude call, doctor names it
pl_l8() {
    b_project "$T/pl8" <<'EOF'
TEST_CMD='bash check.sh'
MERGE=pr
EOF
    local why
    if ! command -v gh >/dev/null; then   # a real gh on PATH: this case cannot be played here
        MAX_RUNS=1 "$TOOL_DIR/autopilot.sh" >"$T/pl8.txt" 2>&1 && fail "L8: start without gh"
        grep -q "MERGE=pr needs the GitHub CLI gh" "$T/pl8-conf/.autopilot/log/history.log" || fail "L8: missing gh not named: $(cat "$T/pl8.txt")"
        "$TOOL_DIR/menu.sh" doctor | grep -q "✘ MERGE=pr: gh (GitHub CLI) not found" || fail "L8: doctor does not name the missing gh"
    fi
    ln -sf "$TOOL_DIR/test/fake-gh" "$T/bin/gh"; touch "$FAKE_DIR/gh-noauth"
    for why in "gh is not logged in" "no remote origin"; do
        MAX_RUNS=1 "$TOOL_DIR/autopilot.sh" >"$T/pl8.txt" 2>&1 && fail "L8: start with $why"
        grep -q "MERGE=pr: .*$why" "$T/pl8-conf/.autopilot/log/history.log" && "$TOOL_DIR/menu.sh" doctor | grep -q "✘ MERGE=pr: .*$why" || fail "L8: $why not named: $(cat "$T/pl8.txt")"
        rm -f "$FAKE_DIR/gh-noauth"
    done
    ! grep -q -- '--effort' "$FAKE_DIR/args" || fail "L8: Claude ran despite the failed start check: $(cat "$FAKE_DIR/args" 2>&1)"
    rm -f "$T/bin/gh"
}

# L9: only check commands the owner approved run: a split whose earlier part brings its own command is not used; a
# final-review task with a command nobody approved is not run (marker files prove it) but needs a new test, and
# history, journal, worker prompt and handover name it
pl_l9() {
    b_project "$T/pl9" <<'EOF'
TEST_CMD='bash check.sh'
DEMO_CMD='bash check.sh'
FRESH_CHECK=off
EOF
    printf -- '- [ ] 1. one. Done when `bash check.sh` exits 0.\n' >TASKS.md && git commit -qam tasks || fail "L9: setup failed"
    printf -- '- [ ] a. Done when `touch %s/pl9-part` exits 0.\n- [ ] b. Done when `bash check.sh` exits 0.\n' "$T" >"$FAKE_DIR/size-1.txt"
    printf -- '- [ ] 2. Fix it. Done when `touch %s/pl9-final` exits 0.\n' "$T" >"$FAKE_DIR/final-1.txt"
    echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/1.sh"
    echo "$tick" >"$FAKE_DIR/steps/2.sh"                            # no new test: rejected (its check is never run)
    echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/3.sh"   # a new test: accepted
    printf 'VERDICT: ACCEPT\nVERDICT: ACCEPT\n' >"$FAKE_DIR/verdicts"
    MAX_RUNS=4 "$TOOL_DIR/autopilot.sh" >"$T/pl9.txt" 2>&1 || fail "L9: run failed: $(tail -3 "$T/pl9.txt")"
    local s=$T/pl9-conf/.autopilot h=$T/pl9-conf/.autopilot/log/history.log
    grep -q "Size check: task 1 does not fit one run, but part 1 brings a check command that is not approved" "$h" && grep -q '^- \[x\] 1\. one' TASKS.md ||
        fail "L9: a split with an earlier part's own check command was used: $(cat "$h"; cat TASKS.md)"
    [ ! -e "$T/pl9-part" ] && [ ! -e "$T/pl9-final" ] || fail "L9: a check command nobody approved ran"
    grep -qF "check command not approved: \`touch $T/pl9-final\`" "$h" && grep -q "Run 2 rejected: task ticked off without a new test" "$h" &&
        grep -q "Run 3 accepted: \[x\] 2\. Fix it" "$h" || fail "L9: unapproved check not handled like no check: $(cat "$h")"
    grep -qF "script 2. Fix it. Done when \`touch" "$s/JOURNAL.md" && grep -q "check command not approved: touch $T/pl9-final" "$s/JOURNAL.md" || fail "L9: journal does not name it: $(cat "$s/JOURNAL.md")"
    grep -qF "\`touch $T/pl9-final\`, but the owner has not approved it" "$FAKE_DIR/last-prompt" && ! grep -q "^Check command of this task" "$FAKE_DIR/last-prompt" ||
        fail "L9: worker prompt wrong: $(grep -i 'check command' "$FAKE_DIR/last-prompt")"
    [ "$(cut -f1 "$s/outcome")" = delivered ] && grep -qx -- "- \`touch $T/pl9-final\`" "$s/HANDOVER.md" || fail "L9: handover does not name it: $(cat "$s/outcome"; cat "$s/HANDOVER.md")"
}

# L10: autopilot stop --now while PR_WAIT waits for the checks: the outcome is "stopped", not "delivered"
pl_l10() {
    b_project "$T/pl10" <<'EOF'
TEST_CMD='bash check.sh'
DEMO_CMD='bash check.sh'
FRESH_CHECK=off
MERGE=pr
PR_WAIT=on
EOF
    git init -q --bare "$T/pl10-origin.git" && git remote add origin "$T/pl10-origin.git" && ln -sf "$TOOL_DIR/test/fake-gh" "$T/bin/gh" || fail "L10: setup failed"
    local n ap s=$T/pl10-conf/.autopilot
    for n in 1 2; do echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/$n.sh"; echo "VERDICT: ACCEPT" >>"$FAKE_DIR/verdicts"; done
    echo 30 >"$FAKE_DIR/gh-checks-sleep"
    MAX_RUNS=3 "$TOOL_DIR/autopilot.sh" >"$T/pl10.txt" 2>&1 & ap=$!
    for n in $(seq 1 300); do [ -e "$FAKE_DIR/gh-checks-waiting" ] && break; sleep 0.1; done
    [ -e "$FAKE_DIR/gh-checks-waiting" ] || fail "L10: PR_WAIT never started: $(cat "$T/pl10.txt" "$s/log/history.log")"
    [ ! -e "$s/outcome" ] || fail "L10: outcome written before the checks: $(cat "$s/outcome")"
    "$TOOL_DIR/menu.sh" stop --now >"$T/pl10-stop.txt" 2>&1 || fail "L10: stop --now failed: $(cat "$T/pl10-stop.txt")"
    wait "$ap"
    [ "$(cut -f1 "$s/outcome")" = stopped ] && head -1 "$s/HANDOVER.md" | grep -q '^# Not delivered: stopped' || fail "L10: outcome not stopped: $(cat "$s/outcome"; head -3 "$s/HANDOVER.md")"
    rm -f "$T/bin/gh"
}

for pl in ${PART_L_ONLY:-l1 l2 l3 l4 l5 l6 l7 l8 l9 l10}; do
    "pl_$pl"
    unset AUTOPILOT_CONF; cd "$T" || exit 1
done
unset pl
