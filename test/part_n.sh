# Sourced by test_autopilot.sh (same shell: $T, $TOOL_DIR, $FAKE_DIR, fail, new_round, sample_project, $tick,
# b_project from part_b.sh, tick_n/block_n from part_l.sh): 0.10 – findings of the live test.
# PART_N_ONLY='n1 …' runs only the named blocks.

# N1: MAX_COST_USD is checked before every Claude call, not only before a worker run: used up by the last task, the
# final review (demo green) or the planner (demo red) is never called, the outcome is limit
pn_n1() {
    local d s
    for d in 'bash check.sh' false; do
        b_project "$T/pn1" <<EOF
TEST_CMD='bash check.sh'
DEMO_CMD='$d'
FRESH_CHECK=off
EOF
        s=$T/pn1-conf/.autopilot
        for n in 1 2; do tick_n "$n" >"$FAKE_DIR/steps/$n.sh"; echo "VERDICT: ACCEPT" >>"$FAKE_DIR/verdicts"; done
        echo 'FINAL: OK' >"$FAKE_DIR/final-1.txt"; printf -- '- [ ] 3. more. Done when a test passes.\n' >"$FAKE_DIR/planner.txt"
        MAX_COST_USD=0.04 "$TOOL_DIR/autopilot.sh" >"$T/pn1.txt" 2>&1 || fail "N1 ($d): run failed: $(tail -3 "$T/pn1.txt")"
        [ "$(cat "$s/outcome")" = "$(printf 'limit\tcost cap MAX_COST_USD=0.04 reached (0.04 USD), 0 tasks still open')" ] ||
            fail "N1 ($d): outcome wrong: $(cat "$s/outcome"; cat "$s/log/history.log")"
        grep -qE '^(final|planner) ' "$FAKE_DIR/args" && fail "N1 ($d): a Claude call after the cost cap: $(cut -c1-60 "$FAKE_DIR/args")"
        rm -rf "$T/pn1" "$T/pn1-conf"
    done
}

# N2: only blocked tasks left: no demo, no final review, no planner; not delivered "N tasks blocked, nothing left to build"
pn_n2() {
    b_project "$T/pn2" <<'EOF'
TEST_CMD='bash check.sh'
DEMO_CMD='bash check.sh'
EOF
    local s=$T/pn2-conf/.autopilot
    block_n 1 >"$FAKE_DIR/steps/1.sh"; block_n 2 >"$FAKE_DIR/steps/2.sh"; echo 'nothing' >"$FAKE_DIR/planner.txt"
    "$TOOL_DIR/autopilot.sh" >"$T/pn2.txt" 2>&1 || fail "N2: run failed: $(tail -3 "$T/pn2.txt")"
    [ "$(cat "$s/outcome")" = "$(printf 'not-delivered\t2 tasks blocked, nothing left to build')" ] || fail "N2: outcome wrong: $(cat "$s/outcome")"
    grep -q "Only blocked tasks left: 2 (see BLOCKED.md)" "$s/log/history.log" && ! grep -q "All tasks done" "$s/log/history.log" || fail "N2: history wrong: $(cat "$s/log/history.log")"
    [ ! -e "$s/demo.txt" ] && ! grep -qE '^(final|planner) ' "$FAKE_DIR/args" || fail "N2: demo, final review or planner ran: $(cut -c1-60 "$FAKE_DIR/args")"
}

# N3: demo red and the planner proposes nothing usable: not delivered "Demo red, the planner proposed nothing", no suggestion
pn_n3() {
    b_project "$T/pn3" <<'EOF'
TEST_CMD='bash check.sh'
DEMO_CMD='false'
EOF
    local s=$T/pn3-conf/.autopilot
    for n in 1 2; do tick_n "$n" >"$FAKE_DIR/steps/$n.sh"; echo "VERDICT: ACCEPT" >>"$FAKE_DIR/verdicts"; done
    echo 'I have no idea.' >"$FAKE_DIR/planner.txt"
    "$TOOL_DIR/autopilot.sh" >"$T/pn3.txt" 2>&1 && fail "N3: exit 0 although nothing was delivered"
    [ "$(cat "$s/outcome")" = "$(printf 'not-delivered\tDemo red, the planner proposed nothing')" ] || fail "N3: outcome wrong: $(cat "$s/outcome")"
    [ ! -e "$s/suggestion.md" ] && ! grep -q "planner's suggestion" "$s/HANDOVER.md" && ! grep -q "proposed new tasks" "$s/log/history.log" ||
        fail "N3: an empty suggestion reported: $(tail -3 "$s/HANDOVER.md"; cat "$s/log/history.log")"
}

# N4: the final review over the per-call budget: asked once more, then not delivered with that reason
pn_n4() {
    b_project "$T/pn4" <<'EOF'
TEST_CMD='bash check.sh'
DEMO_CMD='bash check.sh'
FRESH_CHECK=off
EOF
    local s=$T/pn4-conf/.autopilot
    for n in 1 2; do tick_n "$n" >"$FAKE_DIR/steps/$n.sh"; echo "VERDICT: ACCEPT" >>"$FAKE_DIR/verdicts"; done
    echo 2 >"$FAKE_DIR/final-budget"
    "$TOOL_DIR/autopilot.sh" >"$T/pn4.txt" 2>&1 && fail "N4: exit 0 although nothing was delivered"
    grep -q "Final review (round 1): per-call budget (MAX_COST_PER_CALL_USD=5), trying once more" "$s/log/history.log" || fail "N4: not retried: $(cat "$s/log/history.log")"
    [ "$(cut -f2 "$s/outcome")" = "the final review hit the per-call budget (MAX_COST_PER_CALL_USD=5) twice, see $s/log/final.txt" ] &&
        grep -q '^### J[0-9]* .* final - over budget$' "$s/JOURNAL.md" || fail "N4: outcome or journal wrong: $(cat "$s/outcome")"
}

# N5: a budget abort that uses up the last attempt condenses the lessons once (in block_task), not twice; its row in
# costs.csv has the tokens of .modelUsage (the CLI reports 0 in .usage then), with the cache creation tokens
pn_n5() {
    b_project "$T/pn5" <<'EOF'
TEST_CMD='bash check.sh'
ATTEMPTS=1
EOF
    local s=$T/pn5-conf/.autopilot
    mkdir -p "$FAKE_DIR/budget"; touch "$FAKE_DIR/budget/1"; echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/1.sh"
    MAX_RUNS=1 "$TOOL_DIR/autopilot.sh" >"$T/pn5.txt" 2>&1
    grep -q "Task blocked: 1 failed attempts, last: hit the per-call budget" "$s/log/history.log" || fail "N5: not blocked: $(cat "$s/log/history.log")"
    [ "$(cat "$FAKE_DIR/lessons-nr")" = 1 ] || fail "N5: lessons condensed $(cat "$FAKE_DIR/lessons-nr") times"
    grep -q ';worker;sonnet;2.01;3;300;42;medium;55$' "$s/costs.csv" || fail "N5: tokens of the budget abort not read: $(cat "$s/costs.csv")"
}

# N6: a check command is a whole command: a bare path to a file that does not run is none (the test count must rise),
# a program on PATH is one (and is not approved here)
pn_n6() {
    b_project "$T/pn6" <<'EOF'
TEST_CMD='bash check.sh'
EOF
    mkdir -p tests; echo 'assert 1' >tests/test_x.py
    printf -- '- [ ] 1. one. Done when `tests/test_x.py` passes.\n- [ ] 2. two. Done when `true` exits 0.\n' >TASKS.md && git add -A && git commit -qm paths || fail "N6: setup failed"
    local h=$T/pn6-conf/.autopilot/log/history.log
    for n in 1 2; do tick_n "$n" >"$FAKE_DIR/steps/$n.sh"; echo "VERDICT: ACCEPT" >>"$FAKE_DIR/verdicts"; done
    MAX_RUNS=1 "$TOOL_DIR/autopilot.sh" >"$T/pn6.txt" 2>&1 || fail "N6: run failed: $(tail -3 "$T/pn6.txt")"
    grep -q "Run 1 accepted" "$h" && ! grep -q "check command not approved: \`tests/test_x.py\`" "$h" && ! grep -q "check command" "$FAKE_DIR/last-prompt" ||
        fail "N6: a bare path taken for a check command: $(cat "$h")"
    MAX_RUNS=1 "$TOOL_DIR/autopilot.sh" >"$T/pn6.txt" 2>&1 || fail "N6: second run failed: $(tail -3 "$T/pn6.txt")"
    grep -q "check command not approved: \`true\`" "$h" || fail "N6: a program without arguments not taken for a check command: $(cat "$h")"
}

for pn in ${PART_N_ONLY:-n1 n2 n3 n4 n5 n6}; do
    "pn_$pn"
    unset AUTOPILOT_CONF; cd "$T" || exit 1
done
unset pn
