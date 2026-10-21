# Sourced by test_autopilot.sh (same shell: $T, $TOOL_DIR, $FAKE_DIR, fail, new_round, sample_project,
# $tick, b_project from part_b.sh): N5, N6, N7, N8, N9, N10, N11 from the 0.4.0 bug report.
# PART_E_ONLY='n7 …' runs only the named blocks (used to prove each test fails without its fix).

pe_bwrap_ok() { command -v bwrap >/dev/null && bwrap --ro-bind / / --unshare-all true 2>/dev/null; }

# N7: files written by the test command are never staged or committed; ignored files stay allowed
pe_n7() {
    b_project "$T/n7" <<'EOF'
TEST_CMD='test -e trigger && echo leak >leaked.txt; mkdir -p __pycache__ && touch __pycache__/t.pyc; bash check.sh'
ALLOWED='^(checks\.txt|trigger|TASKS\.md)$'
EOF
    echo "echo check >>checks.txt; touch trigger; $tick" >"$FAKE_DIR/steps/1.sh"
    echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/2.sh"
    printf 'VERDICT: ACCEPT\nVERDICT: ACCEPT\n' >"$FAKE_DIR/verdicts"
    MAX=2 "$TOOL_DIR/autopilot.sh" >"$T/n7.txt" 2>&1 || fail "N7: run ended with an error: $(tail -3 "$T/n7.txt")"
    local h=$T/n7-conf/.autopilot/log/history.log
    grep -q "Run 1 rejected: test command changed files: .*leaked\.txt" "$h" || fail "N7: file written by the test command not rejected: $(cat "$h")"
    grep -q "Run 2 accepted" "$h" || fail "N7: run with only ignored test artefacts rejected: $(cat "$h")"
    git ls-tree -r --name-only HEAD | grep -q leaked && fail "N7: leaked.txt was committed"
    [ ! -e leaked.txt ] && [ ! -e trigger ] || fail "N7: files from the rejected run still lying around"
    git show --name-only --format= HEAD | grep -vxE 'checks\.txt|TASKS\.md' | grep -q . &&
        fail "N7: commit contains more than the checked index: $(git show --name-only --format= HEAD | tr '\n' ' ')"
    [ -z "$(git status --porcelain)" ] || fail "N7: work directory not clean: $(git status --porcelain)"
}

# N5 (without sandbox): a test command that changes .git stops the loop before the next Git call
# could run a planted filter outside any sandbox
pe_n5() {
    rm -f "$T/N5-ESCAPED"
    b_project "$T/n5" <<'EOF'
TEST_CMD='test -e trigger && bash n5-plant.sh 2>/dev/null; bash check.sh'
ALLOWED='^(checks\.txt|trigger|TASKS\.md)$'
EOF
    cat >n5-plant.sh <<'PLANT'
printf '[filter "x"]\n\tclean = touch @OUT@; cat\n' >>.git/config
printf '* filter=x\n' >.git/info/attributes
touch checks.txt
PLANT
    sed -i "s|@OUT@|$T/N5-ESCAPED|" n5-plant.sh
    git add n5-plant.sh && git commit -qm plant || fail "N5: plant setup failed"
    echo "echo check >>checks.txt; touch trigger; $tick" >"$FAKE_DIR/steps/1.sh"
    echo "VERDICT: ACCEPT" >"$FAKE_DIR/verdicts"
    MAX=1 "$TOOL_DIR/autopilot.sh" >"$T/n5.txt" 2>&1 && fail "N5: test command changed .git and the run exits 0"
    grep -q "changed .git" "$T/n5-conf/.autopilot/log/history.log" || fail "N5: .git change by the test command not announced: $(cat "$T/n5-conf/.autopilot/log/history.log")"
    [ ! -e "$T/N5-ESCAPED" ] || fail "N5: the planted git filter ran"
    [ "$(git log --oneline | wc -l)" = 2 ] || fail "N5: a commit was made although the test command changed .git"
}

# N5 (SANDBOX=on): .git is read-only inside the sandbox, so the test command cannot plant anything
pe_n5s() {
    pe_bwrap_ok || { echo "(bwrap missing or unusable: N5 sandbox assertion skipped)"; return 0; }
    b_project "$T/n5s" <<'EOF'
TEST_CMD='echo "# n5s-marker" >>.git/config 2>/dev/null; bash check.sh'
SANDBOX=on
ALLOWED='^(checks\.txt|TASKS\.md)$'
EOF
    echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/1.sh"
    echo "VERDICT: ACCEPT" >"$FAKE_DIR/verdicts"
    MAX=1 "$TOOL_DIR/autopilot.sh" >"$T/n5s.txt" 2>&1 || fail "N5: sandboxed run failed: $(tail -3 "$T/n5s.txt")"
    grep -q "Run 1 accepted" "$T/n5s-conf/.autopilot/log/history.log" || fail "N5: sandboxed run not accepted: $(cat "$T/n5s-conf/.autopilot/log/history.log")"
    grep -q "n5s-marker" .git/config && fail "N5: .git/config is writable inside the sandbox"
}

# N6: TERM during the test phase stops autopilot.sh and the running test command at once,
# not only after TEST_TIMEOUT (the trap must interrupt a `wait`, not wait for a foreground child)
pe_n6() {
    b_project "$T/n6" <<'EOF'
TEST_CMD='touch "$FAKE_DIR/n6-testing"; sleep 60.123; bash check.sh'
TEST_TIMEOUT=30s
ALLOWED='^(checks\.txt|TASKS\.md)$'
EOF
    local n6pid
    MAX=1 "$TOOL_DIR/autopilot.sh" >"$T/n6.txt" 2>&1 & n6pid=$!
    for _ in $(seq 1 50); do [ -e "$FAKE_DIR/n6-testing" ] && break; sleep 0.2; done
    [ -e "$FAKE_DIR/n6-testing" ] || { kill -KILL "$n6pid" 2>/dev/null; fail "N6: test phase never started: $(cat "$T/n6.txt")"; }
    sleep 0.3
    kill -TERM "$n6pid"; SECONDS=0
    while kill -0 "$n6pid" 2>/dev/null && [ "$SECONDS" -lt 5 ]; do sleep 0.2; done
    if kill -0 "$n6pid" 2>/dev/null; then
        kill -KILL "$n6pid" 2>/dev/null; pkill -f 'sleep 60\.123' 2>/dev/null
        fail "N6: abort during the test phase did not stop autopilot.sh"
    fi
    wait "$n6pid" 2>/dev/null
    pgrep -f 'sleep 60\.123' >/dev/null && { pkill -f 'sleep 60\.123'; fail "N6: the test command kept running after the abort"; }
    grep -qi interrupted "$T/n6-conf/.autopilot/log/history.log" || fail "N6: no interrupted note: $(cat "$T/n6-conf/.autopilot/log/history.log")"
}

# N8: TEST_EMPTY_RC is named in SETUP.md's adopted-settings list and in the answer format
pe_n8() {
    grep -m1 'Only these settings are adopted' "$TOOL_DIR/templates/SETUP.md" | grep -q TEST_EMPTY_RC ||
        fail "N8: TEST_EMPTY_RC missing in the adopted-settings list of SETUP.md"
    sed -n '/^===CONFIG===/,/^===TASKS===/p' "$TOOL_DIR/templates/SETUP.md" | grep -q '^TEST_EMPTY_RC=' ||
        fail "N8: TEST_EMPTY_RC missing in the answer format of SETUP.md"
}

# N9: the sandbox-run wrapper ships with the plugin, is documented, refuses without bwrap, keeps
# .git read-only, and `plan accept` routes the worker's test command through it (with SANDBOX=on)
pe_n9() {
    [ -x "$TOOL_DIR/sandbox-run" ] || fail "N9: sandbox-run missing or not executable"
    PATH="$T/nocl" "$TOOL_DIR/sandbox-run" true >"$T/n9.txt" 2>&1 && fail "N9: sandbox-run without bwrap exits 0"
    grep -q bwrap "$T/n9.txt" || fail "N9: sandbox-run without bwrap does not mention bwrap: $(cat "$T/n9.txt")"
    AUTOPILOT_SANDBOXED=1 PATH="$T/nocl" "$TOOL_DIR/sandbox-run" bash -c true || fail "N9: nested sandbox-run call failed"
    grep -q "sandbox-run" "$TOOL_DIR/templates/autopilot.conf" || fail "N9: templates/autopilot.conf does not document sandbox-run"
    grep -q "sandbox-run" "$TOOL_DIR/README.md" || fail "N9: README does not document sandbox-run"
    pe_bwrap_ok || { echo "(bwrap missing or unusable: N9 sandbox assertions skipped)"; return 0; }
    new_round; sample_project "$T/n9p"
    git add -A && git commit -qm start || fail "N9: setup failed"
    "$TOOL_DIR/sandbox-run" bash -c 'echo pwn >>.git/config' 2>/dev/null && fail "N9: sandbox-run allows writing .git"
    grep -q pwn .git/config && fail "N9: .git/config was changed through sandbox-run"
    "$TOOL_DIR/sandbox-run" bash -c 'touch n9-inside.txt' && [ -f n9-inside.txt ] || fail "N9: sandbox-run cannot write in the work directory"
    rm -f n9-inside.txt
    printf "===CONFIG===\nTEST_CMD='bash check.sh'\nDEMO_CMD='bash check.sh'\nWORKER_TOOLS=(Read Edit 'Bash(bash check.sh:*)')\n===TASKS===\n- [ ] 1. [x] one. Done when a test passes.\n" >"$FAKE_DIR/setup.txt"
    "$TOOL_DIR/menu.sh" plan "$T/n9p/plan.md" >"$T/n9.txt" 2>&1 || fail "N9: plan failed: $(tail -3 "$T/n9.txt")"
    "$TOOL_DIR/menu.sh" plan accept >"$T/n9.txt" 2>&1 || fail "N9: plan accept failed: $(tail -3 "$T/n9.txt")"
    local conf=$T/n9p/autopilot.conf
    grep -q '^SANDBOX=on' "$conf" || fail "N9: plan accept did not set SANDBOX=on although bwrap works: $(cat "$conf")"
    grep -qF "TEST_CMD='$TOOL_DIR/sandbox-run bash check.sh'" "$conf" || fail "N9: TEST_CMD not routed through sandbox-run: $(grep TEST_CMD "$conf")"
    grep -qF "'Bash($TOOL_DIR/sandbox-run bash check.sh:*)'" "$conf" || fail "N9: worker Bash right not routed through sandbox-run: $(grep WORKER_TOOLS "$conf")"
    grep -q "Test command checked: green, 1 passed tests" "$T/n9.txt" || fail "N11: plan accept does not report the green probe: $(cat "$T/n9.txt")"
}

# N10: SANDBOX=on with a bwrap that cannot create namespaces (AppArmor, container) is named
# exactly, instead of "Tests already red"
pe_n10() {
    mkdir -p "$T/bwbad"
    printf '#!/bin/bash\necho "bwrap: setting up uid map: Permission denied" >&2\nexit 1\n' >"$T/bwbad/bwrap"
    chmod +x "$T/bwbad/bwrap"
    b_project "$T/n10" <<'EOF'
TEST_CMD='bash check.sh'
SANDBOX=on
ALLOWED='^(checks\.txt|TASKS\.md)$'
EOF
    MAX=1 PATH="$T/bwbad:$PATH" "$TOOL_DIR/autopilot.sh" >"$T/n10.txt" 2>&1 && fail "N10: start with a broken bwrap exits 0"
    local h=$T/n10-conf/.autopilot/log/history.log
    grep -q "bwrap cannot start a sandbox" "$h" || fail "N10: broken bwrap not named: $(cat "$h")"
    grep -q "Tests already red" "$h" && fail "N10: broken bwrap misreported as red tests"
    [ ! -f "$FAKE_DIR/step-nr" ] || fail "N10: Claude was started despite a broken bwrap"
}

# N11: a drafted test command that cannot run (missing tool) shows up at `plan accept` (without
# aborting the setup) and the start says "cannot run" instead of "tests red"
pe_n11() {
    new_round; sample_project "$T/n11p"
    git add -A && git commit -qm start || fail "N11: setup failed"
    printf "===CONFIG===\nTEST_CMD='n11-missing-tool-xyz13 -q'\nDEMO_CMD='bash check.sh'\n===TASKS===\n- [ ] 1. [x] one. Done when a test passes.\n" >"$FAKE_DIR/setup.txt"
    "$TOOL_DIR/menu.sh" plan "$T/n11p/plan.md" >/dev/null 2>&1 || fail "N11: plan failed"
    "$TOOL_DIR/menu.sh" plan accept >"$T/n11.txt" 2>&1 || fail "N11: plan accept with a missing tool must not abort the setup: $(tail -3 "$T/n11.txt")"
    grep -qi "cannot run" "$T/n11.txt" || fail "N11: plan accept does not report the missing tool: $(cat "$T/n11.txt")"
    grep -q "Start: autopilot" "$T/n11.txt" || fail "N11: setup message missing after the probe warning: $(cat "$T/n11.txt")"
    # start: missing tool (exit 127) is named as such …
    b_project "$T/n11s" <<'EOF'
TEST_CMD='n11-missing-tool-xyz13 -q'
ALLOWED='^(checks\.txt|TASKS\.md)$'
EOF
    MAX=1 "$TOOL_DIR/autopilot.sh" >"$T/n11s.txt" 2>&1 && fail "N11: start with a missing test tool exits 0"
    grep -q "Test command cannot run (missing tool?)" "$T/n11s-conf/.autopilot/log/history.log" ||
        fail "N11: start does not name the missing tool: $(cat "$T/n11s-conf/.autopilot/log/history.log")"
    # … while plain red tests keep their message
    b_project "$T/n11r" <<'EOF'
TEST_CMD='false'
ALLOWED='^(checks\.txt|TASKS\.md)$'
EOF
    MAX=1 "$TOOL_DIR/autopilot.sh" >"$T/n11r.txt" 2>&1 && fail "N11: start with red tests exits 0"
    local h=$T/n11r-conf/.autopilot/log/history.log
    grep -q "Tests already red before the start" "$h" || fail "N11: red tests not reported as red: $(cat "$h")"
    grep -q "cannot run" "$h" && fail "N11: red tests misreported as a missing tool"
}

for pe in ${PART_E_ONLY:-n7 n5 n5s n6 n8 n9 n10 n11}; do
    "pe_$pe"
    unset AUTOPILOT_CONF; cd "$T" || exit 1
done
unset pe
