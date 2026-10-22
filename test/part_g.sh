# Sourced by test_autopilot.sh (same shell: $T, $TOOL_DIR, $FAKE_DIR, fail, new_round, sample_project,
# $tick, b_project from part_b.sh): `autopilot status` after the end, the default desktop notification,
# `autopilot plan "<idea>"` and the usage limit at `plan`. $T/bin/notify-send appends to $NOTIFY_LOG.
# PART_G_ONLY='g1 …' runs only the named blocks (used to prove each test fails without its fix).

# G1: status after a finished run – outcome, counts, tests, cost and tokens, next step; --short one-liner
pg_g1() {
    b_project "$T/pg1" <<'EOF'
TEST_CMD='bash check.sh'
MODELS=cheap
EOF
    for n in 1 2; do echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/$n.sh"; done
    printf 'VERDICT: ACCEPT\nVERDICT: ACCEPT\n' >"$FAKE_DIR/verdicts"
    MAX_RUNS=5 "$TOOL_DIR/autopilot.sh" >"$T/pg1.txt" 2>&1 || fail "G1: run failed: $(tail -3 "$T/pg1.txt")"
    grep -q "DEMO_CMD is not set in .*: the loop can never end as delivered" "$T/pg1-conf/.autopilot/log/history.log" || fail "G1: no warning about the missing demo"
    "$TOOL_DIR/menu.sh" status >"$T/pg1-sum.txt" 2>&1 || fail "G1: status exits non-zero: $(cat "$T/pg1-sum.txt")"
    grep -q "^Outcome:     not delivered (no demo: DEMO_CMD is empty" "$T/pg1-sum.txt" || fail "G1: outcome missing: $(cat "$T/pg1-sum.txt")"
    grep -q "2 done, 0 open, 0 blocked" "$T/pg1-sum.txt" || fail "G1: task counts wrong: $(cat "$T/pg1-sum.txt")"
    grep -q "^Tests:       1 -> 3" "$T/pg1-sum.txt" || fail "G1: test counts wrong: $(cat "$T/pg1-sum.txt")"
    grep -q "^This start: .*, 2 runs, 0.06 USD" "$T/pg1-sum.txt" || fail "G1: runs or cost wrong: $(cat "$T/pg1-sum.txt")"
    grep -qE '^  brief +0\.02 USD +tokens: 200 in, 2000 cache read, 20 out$' "$T/pg1-sum.txt" || fail "G1: tokens per kind missing: $(cat "$T/pg1-sum.txt")"
    grep -q "^Next step:   read the handover: autopilot handover" "$T/pg1-sum.txt" || fail "G1: next-step hint missing: $(cat "$T/pg1-sum.txt")"
    "$TOOL_DIR/menu.sh" status --short | grep -qx "Autopilot pg1-conf ended: not delivered (no demo: DEMO_CMD is empty, so nothing shows that the result works) - 2 done, 0 blocked, tests 1 -> 3, 0.06 USD" ||
        fail "G1: --short one-liner wrong: $("$TOOL_DIR/menu.sh" status --short)"
    PATH="$T/nocl" "$TOOL_DIR/menu.sh" status >/dev/null 2>&1 || fail "G1: status does not work without claude on PATH"
    grep -q "^## Cost" "$T/pg1-conf/.autopilot/HANDOVER.md" && grep -qE '^  worker +0\.02 USD' "$T/pg1-conf/.autopilot/HANDOVER.md" || fail "G1: handover without the cost per kind"
}

# G2: status before anything ran – clear message, exit 0, no Claude call
pg_g2() {
    b_project "$T/pg2" <<'EOF'
TEST_CMD='bash check.sh'
EOF
    "$TOOL_DIR/menu.sh" status >"$T/pg2.txt" 2>&1 || fail "G2: status without runs exits non-zero: $(cat "$T/pg2.txt")"
    grep -q "not started yet" "$T/pg2.txt" || fail "G2: no clear message without runs: $(cat "$T/pg2.txt")"
    "$TOOL_DIR/menu.sh" handover | grep -q "No handover yet" || fail "G2: handover before the first end"
    [ ! -f "$FAKE_DIR/step-nr" ] || fail "G2: status started Claude"
}

# G3: default notify() – notify-send with the urgency mapping; absent or failing notify-send stays
# silent; a notify() from autopilot.conf still wins
pg_g3() {
    b_project "$T/pg3" <<'EOF'
TEST_CMD='bash check.sh'
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

# G4: plan "<idea>" – writes ./<slug>-plan.md from the fake answer, drafts from it in one step (showing both),
# books the idea's cost to the project, refuses to overwrite; the IDEA template and the idea reach Claude
pg_g4() {
    new_round
    mkdir -p "$T/pg4" && cd "$T/pg4" || exit 1
    printf '# Plan: tiny counter\nGoal: count things.\n- 1. Setup. Works when a test passes.\n' >"$FAKE_DIR/idea.txt"
    printf "===CONFIG===\nTEST_CMD='bash check.sh'\nDEMO_CMD='bash check.sh'\n===TASKS===\n- [ ] 1. one. Done when a test passes.\n" >"$FAKE_DIR/setup.txt"
    "$TOOL_DIR/menu.sh" plan "Build a Tiny counter! App" >"$T/pg4.txt" 2>&1 || fail "G4: plan idea failed: $(cat "$T/pg4.txt")"
    local f=$T/pg4/build-a-tiny-counter-app-plan.md w=$T/pg4/build-a-tiny-counter-app-plan-autopilot
    [ -f "$f" ] || fail "G4: plan file missing: $(ls -A "$T/pg4")"
    grep -q "# Plan: tiny counter" "$f" || fail "G4: plan file without the answer: $(cat "$f")"
    [ "$(ls -A "$T/pg4" | wc -l)" = 2 ] && [ -d "$w/.git" ] || fail "G4: more than the plan file and its project folder created: $(ls -A "$T/pg4")"
    grep -qF "Plan file written: $f" "$T/pg4.txt" && grep -q "# Plan: tiny counter" "$T/pg4.txt" || fail "G4: plan file not shown: $(cat "$T/pg4.txt")"
    grep -q "^Draft for: " "$T/pg4.txt" && grep -q "Set up: autopilot plan accept" "$T/pg4.txt" || fail "G4: draft not shown in the same step: $(cat "$T/pg4.txt")"
    grep -q ';plan;opus;0.01;' "$w/.autopilot/costs.csv" && grep -q ';draft;opus;0.01;' "$w/.autopilot/costs.csv" ||
        fail "G4: cost of the idea or the draft not in the project's costs.csv: $(cat "$w/.autopilot/costs.csv" 2>&1)"
    grep -qF "Build a Tiny counter! App" "$FAKE_DIR/idea-prompt" || fail "G4: idea missing in the prompt"
    grep -q "Milestones: if the idea names a number or a list of milestones, use exactly those. Otherwise as few as make sense: 1 for a small tool" "$FAKE_DIR/idea-prompt" && ! grep -q "5 to 15" "$FAKE_DIR/idea-prompt" || fail "G4: IDEA template (milestone rule) missing in the prompt"
    # the plan and the tasks follow the language of the idea, not the user's "language" setting
    for p in idea-prompt setup-prompt; do
        grep -qF "in the language of the idea or plan file, even if other instructions or settings ask for another language" "$FAKE_DIR/$p" || fail "G4: language rule missing in $p"
    done
    grep -qF -- '--settings {"language":""}' "$FAKE_DIR/args" || fail "G4: the user's language setting is not neutralised: $(head -2 "$FAKE_DIR/args")"
    cp "$f" "$f.keep"
    "$TOOL_DIR/menu.sh" plan "Build a Tiny counter! App" >"$T/pg4b.txt" 2>&1 && fail "G4: overwrite not refused"
    grep -q "already exists" "$T/pg4b.txt" || fail "G4: overwrite message missing: $(cat "$T/pg4b.txt")"
    cmp -s "$f" "$f.keep" || fail "G4: existing plan file was changed"
    rm -f "$f.keep"
    "$TOOL_DIR/menu.sh" plan missing.md >"$T/pg4c.txt" 2>&1 && fail "G4: a missing plan file exits 0"
    grep -q "File not found: missing.md" "$T/pg4c.txt" || fail "G4: a missing .md file was taken for an idea: $(cat "$T/pg4c.txt")"
    "$TOOL_DIR/menu.sh" plan discard >/dev/null || fail "G4: plan discard failed"
}

# G5: the usage limit at `plan` (file and idea) is named with its reset time, nothing is set up
pg_g5() {
    new_round; sample_project "$T/pg5"; git add -A && git commit -qm start || fail "G5: setup failed"
    echo "You've hit your limit · resets 5pm" >"$FAKE_DIR/limit.txt"
    "$TOOL_DIR/menu.sh" plan "$T/pg5/plan.md" >"$T/pg5.txt" 2>&1 && fail "G5: plan at the usage limit exits 0"
    grep -q "Claude's usage limit is reached (resets 5pm)" "$T/pg5.txt" || fail "G5: plan does not name the usage limit: $(cat "$T/pg5.txt")"
    "$TOOL_DIR/menu.sh" plan "a counter for words" >"$T/pg5b.txt" 2>&1 && fail "G5: plan idea at the usage limit exits 0"
    grep -q "Claude's usage limit is reached (resets 5pm)" "$T/pg5b.txt" || fail "G5: plan idea does not name the usage limit: $(cat "$T/pg5b.txt")"
    [ ! -e "$T/pg5/a-counter-for-words-plan.md" ] || fail "G5: a plan file was written at the usage limit"
}

for pg in ${PART_G_ONLY:-g1 g2 g3 g4 g5}; do
    "pg_$pg"
    unset AUTOPILOT_CONF; cd "$T" || exit 1
done
unset pg
