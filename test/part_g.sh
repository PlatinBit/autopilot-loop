# Sourced by test_autopilot.sh (same shell: $T, $TOOL_DIR, $FAKE_DIR, fail, new_round, sample_project,
# $tick, b_project from part_b.sh): `autopilot summary` from the logs, the default desktop
# notification, and `autopilot plan idea`. $T/bin/notify-send is a stub that appends to $NOTIFY_LOG.
# PART_G_ONLY='g1 …' runs only the named blocks (used to prove each test fails without its fix).

# G1: summary after a finished run – counts, tests, cost, "goal reached", next step; --short one-liner
pg_g1() {
    b_project "$T/pg1" <<'EOF'
TEST_CMD='bash check.sh'
ALLOWED='^(checks\.txt|TASKS\.md)$'
EOF
    for n in 1 2; do echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/$n.sh"; done
    printf 'VERDICT: ACCEPT\nVERDICT: ACCEPT\n' >"$FAKE_DIR/verdicts"
    MAX=5 "$TOOL_DIR/autopilot.sh" >"$T/pg1.txt" 2>&1 || fail "G1: run failed: $(tail -3 "$T/pg1.txt")"
    "$TOOL_DIR/menu.sh" summary >"$T/pg1-sum.txt" 2>&1 || fail "G1: summary exits non-zero: $(cat "$T/pg1-sum.txt")"
    grep -q "2 done, 0 open, 0 blocked" "$T/pg1-sum.txt" || fail "G1: task counts wrong: $(cat "$T/pg1-sum.txt")"
    grep -q "Tests:       1 -> 3" "$T/pg1-sum.txt" || fail "G1: test counts wrong: $(cat "$T/pg1-sum.txt")"
    grep -q "2 runs" "$T/pg1-sum.txt" && grep -q "0.04 USD" "$T/pg1-sum.txt" || fail "G1: runs or cost wrong: $(cat "$T/pg1-sum.txt")"
    grep -q "Ended:       not delivered (no demo: DEMO_CMD and SMOKE_TEST_CMD are empty" "$T/pg1-sum.txt" || fail "G1: outcome missing: $(cat "$T/pg1-sum.txt")"
    grep -q "Next:.*autopilot handover.*autopilot result" "$T/pg1-sum.txt" || fail "G1: next-step hint missing: $(cat "$T/pg1-sum.txt")"
    [ "$("$TOOL_DIR/menu.sh" summary --short)" = "not delivered (no demo: DEMO_CMD and SMOKE_TEST_CMD are empty, so nothing shows that the result works) - 2 done, 0 blocked, tests 1 -> 3, 0.04 USD" ] ||
        fail "G1: --short one-liner wrong: $("$TOOL_DIR/menu.sh" summary --short)"
    PATH="$T/nocl" "$TOOL_DIR/menu.sh" summary >/dev/null 2>&1 || fail "G1: summary does not work without claude on PATH"
}

# G2: summary before anything ran – clear message, exit 0, no Claude call
pg_g2() {
    b_project "$T/pg2" <<'EOF'
TEST_CMD='bash check.sh'
ALLOWED='^(checks\.txt|TASKS\.md)$'
EOF
    "$TOOL_DIR/menu.sh" summary >"$T/pg2.txt" 2>&1 || fail "G2: summary without runs exits non-zero: $(cat "$T/pg2.txt")"
    grep -q "Nothing has run yet" "$T/pg2.txt" || fail "G2: no clear message without runs: $(cat "$T/pg2.txt")"
    [ ! -f "$FAKE_DIR/step-nr" ] || fail "G2: summary started Claude"
}

# G3: default notify() – notify-send with the urgency mapping; absent or failing notify-send stays
# silent; a notify() from autopilot.conf still wins
pg_g3() {
    b_project "$T/pg3" <<'EOF'
TEST_CMD='bash check.sh'
ALLOWED='^(checks\.txt|TASKS\.md)$'
EOF
    local log=$T/pg3-notify.log out
    : >"$log"
    out=$(NOTIFY_LOG=$log bash -c ". '$TOOL_DIR/common.sh'; notify crit boom; notify warn warm; notify info told; notify ok fine") ||
        fail "G3: notify via the stub exits non-zero"
    [ -z "$out" ] || fail "G3: notify wrote to stdout: $out"
    grep -qx -- "-u critical Autopilot pg3-conf boom" "$log" || fail "G3: crit not mapped to critical: $(cat "$log")"
    grep -qx -- "-u normal Autopilot pg3-conf warm" "$log" || fail "G3: warn not mapped to normal: $(cat "$log")"
    grep -qx -- "-u low Autopilot pg3-conf told" "$log" && grep -qx -- "-u low Autopilot pg3-conf fine" "$log" ||
        fail "G3: info/ok not mapped to low: $(cat "$log")"
    # notify-send present but failing (no DBUS): no error, exit 0, loop untouched
    mkdir -p "$T/pg3-nsfail"
    printf '#!/bin/bash\nexit 1\n' >"$T/pg3-nsfail/notify-send" && chmod +x "$T/pg3-nsfail/notify-send"
    out=$(PATH="$T/pg3-nsfail:$T/nocl" bash -c ". '$TOOL_DIR/common.sh'; notify crit boom" 2>&1) ||
        fail "G3: failing notify-send makes notify exit non-zero: $out"
    [ -z "$out" ] || fail "G3: failing notify-send produced output: $out"
    # no notify-send at all: silent, exit 0 ($T/nocl has the base tools but no notify-send)
    out=$(PATH="$T/nocl" bash -c ". '$TOOL_DIR/common.sh'; notify crit boom" 2>&1) ||
        fail "G3: notify without notify-send exits non-zero: $out"
    [ -z "$out" ] || fail "G3: notify without notify-send produced output: $out"
    # a notify() in autopilot.conf overrides the default
    printf 'notify() { echo "custom:$1:$2" >>%q; }\n' "$T/pg3-custom.log" >>"$AUTOPILOT_CONF"
    "$TOOL_DIR/menu.sh" trust "$AUTOPILOT_CONF" >/dev/null || fail "G3: trusting the conf with notify() failed"
    : >"$log"
    NOTIFY_LOG=$log bash -c ". '$TOOL_DIR/common.sh'; notify crit boom" || fail "G3: custom notify exits non-zero"
    grep -qx "custom:crit:boom" "$T/pg3-custom.log" || fail "G3: notify() from autopilot.conf not used"
    [ ! -s "$log" ] || fail "G3: default notify ran although autopilot.conf defines notify(): $(cat "$log")"
}

# G4: plan idea – writes ./<slug>-plan.md from the fake answer, refuses to overwrite, prints the
# next step, and the IDEA template plus the idea reach Claude (marker in the prompt)
pg_g4() {
    new_round
    mkdir -p "$T/pg4" && cd "$T/pg4" || exit 1
    printf '# Plan: tiny counter\nGoal: count things.\n- 1. Setup. Works when a test passes.\n' >"$FAKE_DIR/idea.txt"
    "$TOOL_DIR/menu.sh" plan idea "Build a Tiny counter! App" >"$T/pg4.txt" 2>&1 || fail "G4: plan idea failed: $(cat "$T/pg4.txt")"
    local f=$T/pg4/build-a-tiny-counter-app-plan.md
    [ -f "$f" ] || fail "G4: plan file missing: $(ls -A "$T/pg4")"
    grep -q "# Plan: tiny counter" "$f" || fail "G4: plan file without the answer: $(cat "$f")"
    [ "$(ls -A "$T/pg4")" = "$(basename "$f")" ] || fail "G4: more than the plan file created: $(ls -A "$T/pg4")"
    grep -qF "Next: read and edit $f" "$T/pg4.txt" && grep -qF "autopilot plan $f" "$T/pg4.txt" ||
        fail "G4: next-step hint missing: $(cat "$T/pg4.txt")"
    grep -q "# Plan: tiny counter" "$T/pg4.txt" || fail "G4: plan head not shown: $(cat "$T/pg4.txt")"
    grep -qF "Build a Tiny counter! App" "$FAKE_DIR/idea-prompt" || fail "G4: idea missing in the prompt"
    grep -q "Milestones: 5 to 15" "$FAKE_DIR/idea-prompt" || fail "G4: IDEA template missing in the prompt"
    cp "$f" "$f.keep"
    "$TOOL_DIR/menu.sh" plan idea "Build a Tiny counter! App" >"$T/pg4b.txt" 2>&1 && fail "G4: overwrite not refused"
    grep -q "already exists" "$T/pg4b.txt" || fail "G4: overwrite message missing: $(cat "$T/pg4b.txt")"
    cmp -s "$f" "$f.keep" || fail "G4: existing plan file was changed"
    rm -f "$f.keep"
}

for pg in ${PART_G_ONLY:-g1 g2 g3 g4}; do
    "pg_$pg"
    unset AUTOPILOT_CONF; cd "$T" || exit 1
done
unset pg
