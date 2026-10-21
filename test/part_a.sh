# Part of test_autopilot.sh (sourced, same shell): N1, N2, A1, P6, P14 from the 0.3.0 bug report.
pa_project() { # NAME CONF-LINES: Git project $T/pa-NAME on branch autopilot with four tasks, conf $T/pa-NAME-conf/autopilot.conf
    new_round; sample_project "$T/pa-$1"
    printf -- '- [ ] 1. one\n- [ ] 2. two\n- [ ] 3. three\n- [ ] 4. four\n' >TASKS.md
    git add -A && git commit -qm start && git checkout -qb autopilot || fail "$1: setup failed"
    mkdir -p "$T/pa-$1-conf"; printf 'WORKDIR=%q\nTEST_CMD=%q\n%s\n' "$T/pa-$1" 'bash check.sh' "$2" >"$T/pa-$1-conf/autopilot.conf"
    export AUTOPILOT_CONF="$T/pa-$1-conf/autopilot.conf"
}
pa_plan() { # NAME CONFIG-LINES: project $T/pa-NAME with a draft whose config section is CONFIG-LINES
    new_round; sample_project "$T/pa-$1"; git add -A && git commit -qm start || fail "$1: plan setup failed"
    printf "===CONFIG===\nTEST_CMD='bash check.sh'\nDEMO_CMD='bash check.sh'\n%s\n===TASKS===\n- [ ] 1. one. Done when a test passes.\n" "$2" >"$FAKE_DIR/setup.txt"
    "$TOOL_DIR/menu.sh" plan "$T/pa-$1/plan.md" >"$T/pa-$1.txt" 2>&1 || fail "$1: draft failed: $(tail -3 "$T/pa-$1.txt")"
}

# N1: an invalid ALLOWED / FORBIDDEN_CONTENT pattern must never switch the checks off (grep exit 2 = "nothing found")
pa_project n1 "ALLOWED='^(checks\\.txt|TASKS\\.md\$'
FORBIDDEN_CONTENT='(BOESE'"
"$TOOL_DIR/menu.sh" trust "$AUTOPILOT_CONF" >"$T/pa-n1.txt" 2>&1 && fail "N1: trust accepted an invalid ALLOWED"
grep -q "ALLOWED FORBIDDEN_CONTENT .*not a valid regular expression" "$T/pa-n1.txt" || fail "N1: trust does not name the invalid patterns: $(cat "$T/pa-n1.txt")"
grep -qF "$AUTOPILOT_CONF" "$T/config/autopilot-loop/trusted" 2>/dev/null && fail "N1: invalid configuration was marked as trusted"
# trusted earlier (e.g. by an older version): the start is refused before Claude runs, nothing is committed
echo "$(sha256sum <"$AUTOPILOT_CONF" | cut -c1-64) $(readlink -f "$AUTOPILOT_CONF")" >>"$T/config/autopilot-loop/trusted"
echo "echo BOESE >secret.txt; echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/1.sh"
echo "VERDICT: ACCEPT" >"$FAKE_DIR/verdicts"
n1_head=$(git rev-parse HEAD)
MAX_RUNS=1 "$TOOL_DIR/autopilot.sh" >"$T/pa-n1.txt" 2>&1 && fail "N1: start with an invalid ALLOWED not refused"
grep -q "ALLOWED FORBIDDEN_CONTENT in .* is not a valid regular expression" "$T/pa-n1-conf/.autopilot/log/history.log" || fail "N1: no message about the invalid pattern: $(cat "$T/pa-n1.txt")"
[ ! -f "$FAKE_DIR/step-nr" ] && [ "$(git rev-parse HEAD)" = "$n1_head" ] || fail "N1: Claude ran or a commit was made despite an invalid pattern"
# plan accept with an invalid ALLOWED from the draft: refused before anything is set up
pa_plan n1p "ALLOWED='^(src/'"
"$TOOL_DIR/menu.sh" plan accept >"$T/pa-n1p.txt" 2>&1 && fail "N1: plan accept with an invalid ALLOWED exits 0"
grep -q "ALLOWED is not a valid regular expression" "$T/pa-n1p.txt" || fail "N1: plan accept does not name the invalid ALLOWED: $(cat "$T/pa-n1p.txt")"
[ ! -e "$T/pa-n1p/autopilot.conf" ] && [ ! -e "$T/pa-n1p-autopilot" ] || fail "N1: plan accept set things up despite an invalid ALLOWED"
"$TOOL_DIR/menu.sh" plan discard >/dev/null || fail "N1: plan discard of the refused draft failed"

# N2: two ALLOWED lines in a draft must not merge into one broken (multi-line) pattern
pa_plan n2 "ALLOWED='^src/'
ALLOWED='^tests/'"
grep -q "Not adopted" "$T/pa-n2.txt" && grep -q "duplicate.*ALLOWED='^tests/'" "$T/pa-n2.txt" || fail "N2: second ALLOWED not shown as discarded: $(cat "$T/pa-n2.txt")"
"$TOOL_DIR/menu.sh" plan accept >"$T/pa-n2.txt" 2>&1 || fail "N2: accept failed: $(cat "$T/pa-n2.txt")"
( . "$T/pa-n2/autopilot.conf"; [ "$ALLOWED" = '^src/' ] ) || fail "N2: ALLOWED is not the one first line: $(grep -A1 '^ALLOWED=' "$T/pa-n2/autopilot.conf")"

# A1: an acceptance test from the draft is adopted (and its files locked) when its files exist, dropped with a note otherwise
pa_plan a1 "ACCEPT_CMD='bash accept.sh'
ACCEPT_FILES=(accept.sh)"
"$TOOL_DIR/menu.sh" plan accept >"$T/pa-a1.txt" 2>&1 || fail "A1: plan accept failed: $(cat "$T/pa-a1.txt")"
( . "$T/pa-a1/autopilot.conf"; [ "$ACCEPT_CMD" = 'bash accept.sh' ] && [ "${LOCKED[*]}" = 'plan.md accept.sh' ] ) ||
    fail "A1: acceptance test with existing files not adopted and locked: $(cat "$T/pa-a1/autopilot.conf")"
pa_plan a1m "ACCEPT_CMD='bash accept.sh'
ACCEPT_FILES=(missing.sh)"
"$TOOL_DIR/menu.sh" plan accept >"$T/pa-a1m.txt" 2>&1 || fail "A1: plan accept with a missing acceptance file failed: $(cat "$T/pa-a1m.txt")"
grep -q "acceptance test was dropped: missing.sh does not exist" "$T/pa-a1m.txt" || fail "A1: dropped acceptance test not named: $(cat "$T/pa-a1m.txt")"
grep -q '^ACCEPT_' "$T/pa-a1m/autopilot.conf" && fail "A1: acceptance test with a missing file adopted: $(cat "$T/pa-a1m/autopilot.conf")"
# a 0.8 configuration with ACCEPT_FILES is refused instead of leaving the acceptance files unlocked
pa_project a1o "ACCEPT_CMD='bash accept.sh'
ACCEPT_FILES=(accept.sh)"
"$TOOL_DIR/menu.sh" trust "$AUTOPILOT_CONF" >/dev/null || fail "A1: trust failed"
MAX_RUNS=1 "$TOOL_DIR/autopilot.sh" >/dev/null 2>&1 && fail "A1: ACCEPT_FILES from 0.8 not refused"
grep -q "ACCEPT_FILES in .* is gone since 0.9: move its paths into LOCKED" "$T/pa-a1o-conf/.autopilot/log/history.log" || fail "A1: no hint to move ACCEPT_FILES into LOCKED"
[ ! -f "$FAKE_DIR/step-nr" ] || fail "A1: Claude ran with an unlocked acceptance test"

# P6: the only allowed change to the task list is the first open task ticked off or blocked
pa_project p6 "ALLOWED='^checks\\.txt\$'"
"$TOOL_DIR/menu.sh" trust "$AUTOPILOT_CONF" >/dev/null || fail "P6: trust failed"
echo "echo check >>checks.txt; $tick; sed -i '/^- \[ \]/d' TASKS.md"           >"$FAKE_DIR/steps/1.sh"  # deletes the other tasks
echo "echo check >>checks.txt; sed -i 's/^- \[ \] 2\./- [x] 2./' TASKS.md"     >"$FAKE_DIR/steps/2.sh"  # ticks off task 2 instead of 1
echo "echo check >>checks.txt; $tick; echo '- [ ] 5. new' >>TASKS.md"          >"$FAKE_DIR/steps/3.sh"  # adds a task
echo "echo check >>checks.txt; $tick"                                         >"$FAKE_DIR/steps/4.sh"  # correct
printf 'VERDICT: ACCEPT\nVERDICT: ACCEPT\nVERDICT: ACCEPT\nVERDICT: ACCEPT\n' >"$FAKE_DIR/verdicts"
p6_head=$(git rev-parse HEAD)
ATTEMPTS=4 MAX_RUNS=4 "$TOOL_DIR/autopilot.sh" >"$T/pa-p6.txt" 2>&1 || fail "P6: run ended with an error: $(tail -3 "$T/pa-p6.txt")"
for r in 1 2 3; do grep -q "Run $r rejected: task list changed" "$T/pa-p6-conf/.autopilot/log/history.log" || fail "P6: task list change in run $r not rejected"; done
grep -q "Run 4 accepted" "$T/pa-p6-conf/.autopilot/log/history.log" || fail "P6: correct tick-off in run 4 not accepted"
[ "$(git rev-parse HEAD~1)" = "$p6_head" ] && grep -q '^- \[ \] 4\.' TASKS.md && ! grep -q '5\.' TASKS.md || fail "P6: a changed task list was committed: $(tr '\n' ' ' <TASKS.md)"

# P14: Markdown variants of the reviewer's verdict count; a REJECT stays a REJECT
pa_project p14 "ALLOWED='^checks\\.txt\$'"
"$TOOL_DIR/menu.sh" trust "$AUTOPILOT_CONF" >/dev/null || fail "P14: trust failed"
for n in 1 2 3 4 5; do echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/$n.sh"; done
printf '**VERDICT: ACCEPT**\nVERDICT: ACCEPT.\n> VERDICT: ACCEPT\n**VERDICT: REJECT: too thin**\n**VERDICT:** ACCEPT\n' >"$FAKE_DIR/verdicts"
MAX_RUNS=5 "$TOOL_DIR/autopilot.sh" >"$T/pa-p14.txt" 2>&1 || fail "P14: run ended with an error: $(tail -3 "$T/pa-p14.txt")"
v=$T/pa-p14-conf/.autopilot/log/history.log
for r in 1 2 3 5; do grep -q "Run $r accepted" "$v" || fail "P14: verdict variant in run $r not accepted"; done
grep -q "Run 4 rejected: Reviewer: too thin$" "$v" || fail "P14: decorated REJECT not rejected with its reason"
unset AUTOPILOT_CONF
cd "$T" || exit 1
