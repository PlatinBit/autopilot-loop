# Part of test/test_autopilot.sh (sourced, same shell): start/abort via tmux, time limits, empty test suites,
# session names, log archive, usage limit pattern, sandbox.
b_project() { # DIR <conf lines: Git project with two tasks in DIR, configuration DIR-conf/autopilot.conf, trusted
    new_round; sample_project "$1"
    printf -- '- [ ] 1. [x] one\n- [ ] 2. [x] two\n' >TASKS.md
    git add -A && git commit -qm start && git checkout -qb autopilot || fail "setup of $1 failed"
    mkdir -p "$1-conf"; { printf 'WORKDIR=%q\n' "$1"; cat; } >"$1-conf/autopilot.conf"
    export AUTOPILOT_CONF="$1-conf/autopilot.conf"
    "$TOOL_DIR/menu.sh" trust "$AUTOPILOT_CONF" >/dev/null || fail "trust for $1 failed"
}

# N4: only a real usage limit means waiting; "context limit" and the like are errors
for c in '0|{"is_error":true,"result":"Claude AI usage limit reached|1760000000"}' \
         "0|{\"is_error\":true,\"result\":\"You've hit your limit · resets 5pm\"}" \
         '0|API Error: 429 {"type":"error","error":{"type":"rate_limit_error"}}' \
         '1|{"is_error":true,"result":"Prompt is too long: context limit exceeded"}' \
         '1|{"is_error":false,"result":"usage limit reached"}' \
         '1|Error: output token limit exceeded'; do
    printf '%s' "${c#*|}" >"$T/n4.json"
    ( . "$TOOL_DIR/lib.sh"; usage_limit "$T/n4" ); [ $? = "${c%%|*}" ] || fail "usage_limit wrong for: ${c#*|}"
done

# B2: TEST_EMPTY_RC – exit code 5 (pytest without tests) counts as 0 tests, so a new project can start
b_project "$T/b2" <<'EOF'
TEST_CMD='test -e t.txt || exit 5; echo "TESTS: $(wc -l <t.txt)"'
TEST_EMPTY_RC=5
ALLOWED='^(t\.txt|TASKS\.md)$'
EOF
echo "echo a >t.txt; $tick" >"$FAKE_DIR/steps/1.sh"; echo "VERDICT: ACCEPT" >"$FAKE_DIR/verdicts"
MAX=1 "$TOOL_DIR/autopilot.sh" >"$T/b2.txt" 2>&1 || fail "TEST_EMPTY_RC: run ended with an error: $(tail -3 "$T/b2.txt")"
grep -q "Start: 0 tests green" "$T/b2-conf/.autopilot/log/history.log" && grep -q "Run 1 accepted" "$T/b2-conf/.autopilot/log/history.log" ||
    fail "TEST_EMPTY_RC=5: no start with 0 tests: $(cat "$T/b2-conf/.autopilot/log/history.log")"
printf "===CONFIG===\nTEST_CMD='pytest -q'\nDEMO_CMD='bash check.sh'\nTEST_EMPTY_RC=5\nTEST_EMPTY_RC=5; touch x\n===TASKS===\n- [ ] 1. [x] one. Done when a test passes.\n" >"$FAKE_DIR/setup.txt"
"$TOOL_DIR/menu.sh" plan "$T/b2/plan.md" >"$T/b2-plan.txt" 2>&1 || fail "TEST_EMPTY_RC: draft failed: $(tail -3 "$T/b2-plan.txt")"
grep -qx 'TEST_EMPTY_RC=5' "$T/b2/.autopilot/draft/autopilot.part" || fail "TEST_EMPTY_RC=5 not adopted from the draft"
grep -qF 'discarded: TEST_EMPTY_RC=5; touch x' "$T/b2/.autopilot/draft/discarded.txt" || fail "TEST_EMPTY_RC with a command adopted"
grep -q 'TEST_EMPTY_RC=5' "$TOOL_DIR/templates/SETUP.md" || fail "SETUP.md does not mention TEST_EMPTY_RC for pytest"

# P3: test and acceptance command end at TEST_TIMEOUT, with a clear reason (each rejects the run)
b_project "$T/p3" <<'EOF'
TEST_CMD='test -e slow && sleep 30; bash check.sh'
ACCEPT_CMD='test -e slow2 && sleep 30; bash accept.sh'
ACCEPT_FILES=(accept.sh)
TEST_TIMEOUT=2s
ALLOWED='^(checks\.txt|slow|slow2|TASKS\.md)$'
EOF
"$TOOL_DIR/menu.sh" approve >/dev/null || fail "P3: approve failed"
echo "echo check >>checks.txt; touch slow; $tick" >"$FAKE_DIR/steps/1.sh"
echo "echo check >>checks.txt; touch slow2; $tick" >"$FAKE_DIR/steps/2.sh"; echo "VERDICT: ACCEPT" >"$FAKE_DIR/verdicts"
SECONDS=0; MAX=2 "$TOOL_DIR/autopilot.sh" >"$T/p3.txt" 2>&1
[ "$SECONDS" -lt 25 ] || fail "TEST_TIMEOUT ignored: took ${SECONDS}s"
grep -qF "Run 1 rejected: tests hit the time limit (TEST_TIMEOUT=2s)" "$T/p3-conf/.autopilot/log/history.log" || fail "no time limit reason: $(cat "$T/p3-conf/.autopilot/log/history.log")"
grep -qF "Run 2 rejected: acceptance test without a readable number" "$T/p3-conf/.autopilot/log/history.log" || fail "acceptance time limit not rejected: $(cat "$T/p3-conf/.autopilot/log/history.log")"
grep -q "time limit" "$T/p3-conf/.autopilot/log/accept-2.txt" || fail "acceptance test without time limit note"
[ ! -e slow ] && [ ! -e slow2 ] && [ -z "$(git status --porcelain)" ] || fail "time limit: work directory not reset"

# N3: a second start moves the per-run logs of the first one to log/archive/<time>/ instead of overwriting them
b_project "$T/n3" <<'EOF'
TEST_CMD='bash check.sh'
ALLOWED='^(checks\.txt|TASKS\.md)$'
EOF
for n in 1 2; do echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/$n.sh"; done
printf 'VERDICT: ACCEPT\nVERDICT: ACCEPT\n' >"$FAKE_DIR/verdicts"
MAX=1 "$TOOL_DIR/autopilot.sh" >/dev/null 2>&1 && MAX=1 "$TOOL_DIR/autopilot.sh" >"$T/n3.txt" 2>&1 || fail "log archive: run failed: $(tail -3 "$T/n3.txt")"
l=$T/n3-conf/.autopilot/log
a=$(ls -d "$l"/archive/*/ 2>/dev/null | head -1)
[ -n "$a" ] && grep -q "Step 1 done" "$a/run-1.txt" && [ -f "$a/review-1.txt" ] && [ -f "$a/start.txt" ] || fail "logs of the first start not archived: $(ls -R "$l")"
grep -q "Step 2 done" "$l/run-1.txt" || fail "log of the second start missing"
[ "$(grep -c 'Run 1 accepted' "$l/history.log")" = 2 ] || fail "history.log not kept across starts"
"$TOOL_DIR/menu.sh" costs | grep -q "Runs total: 0.04 USD" || fail "costs wrong after archiving: $("$TOOL_DIR/menu.sh" costs | head -1)"
k=$("$TOOL_DIR/menu.sh" chart) && grep -q "<svg" "$k" || fail "chart not created after archiving"

# S1: SANDBOX=on without bubblewrap refuses to start; with it the test command cannot write outside WORKDIR,
# sees no devices and no network
cp -a "$T/nocl" "$T/nobw" && ln -sf "$TOOL_DIR/test/fake-claude" "$T/nobw/claude"   # nocl: no bwrap either
b_project "$T/s1" <<'EOF'
TEST_CMD='touch "$SB_OUT1" "$SB_OUT2" 2>/dev/null; echo x >/tmp/sb && echo TMP-OK; touch .sb && rm .sb && echo WD-OK
ls /dev | sed "s/^/DEV /"; awk -F: "NF > 1 { gsub(/ /, \"\", \$1); print \"IF \" \$1 }" /proc/net/dev; bash check.sh'
SANDBOX=on
ALLOWED='^(checks\.txt|TASKS\.md)$'
EOF
echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/1.sh"; echo "VERDICT: ACCEPT" >"$FAKE_DIR/verdicts"
MAX=1 PATH="$T/nobw" "$TOOL_DIR/autopilot.sh" >"$T/s1.txt" 2>&1 && fail "SANDBOX=on without bwrap not refused"
grep -q "SANDBOX=on.*bwrap.*not found" "$T/s1.txt" || fail "SANDBOX=on without bwrap: message unclear: $(cat "$T/s1.txt")"
[ -f "$FAKE_DIR/step-nr" ] && fail "SANDBOX=on without bwrap: Claude was started"
if command -v bwrap >/dev/null && bwrap --ro-bind / / --unshare-all true 2>/dev/null; then
    o1=$T/sb-out; o2=$TOOL_DIR/test/.sb-probe-$$
    SB_OUT1=$o1 SB_OUT2=$o2 MAX=1 "$TOOL_DIR/autopilot.sh" >"$T/s1.txt" 2>&1; r=$?
    [ ! -e "$o1" ] && [ ! -e "$o2" ] || { rm -f "$o2"; fail "sandboxed test command wrote outside WORKDIR"; }
    [ "$r" = 0 ] && grep -q "Run 1 accepted" "$T/s1-conf/.autopilot/log/history.log" || fail "sandboxed run failed: $(tail -3 "$T/s1.txt")"
    s=$T/s1-conf/.autopilot/log/start.txt
    grep -q TMP-OK "$s" && grep -q WD-OK "$s" || fail "sandbox: /tmp or WORKDIR not writable: $(cat "$s")"
    grep -qE '^DEV (i2c-|hidraw|kmsg)' "$s" && fail "sandbox: devices visible: $(grep '^DEV' "$s" | tr '\n' ' ')"
    [ "$(grep '^IF ' "$s")" = "IF lo" ] || fail "sandbox: network visible: $(grep '^IF ' "$s" | tr '\n' ' ')"
else echo "(bwrap missing or unusable: only the SANDBOX refusal was tested)"; fi

# With tmux on a private server (never the user's): P1 start, P2 abort, P9 session name
if command -v tmux >/dev/null; then
    export TMUX_TMPDIR=$T/tmx; unset TMUX; mkdir -p "$TMUX_TMPDIR"
    trap 'tmux kill-server 2>/dev/null; kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
    # server started from an environment without claude (e.g. a terminal without nvm)
    PATH="$T/nocl" "$(command -v tmux)" -f /dev/null new -d -s keep "$(command -v sleep)" 120 || fail "private tmux server did not start"
    b_wait_off() { for _ in $(seq 1 60); do "$TOOL_DIR/menu.sh" status | grep -q '^Status: *off' && return; sleep 0.25; done; fail "$1: session still running"; }
    # P1: start passes PATH on and reports an immediate failure with the last lines instead of "Started"
    b_project "$T/p1" <<'EOF'
TEST_CMD='bash check.sh'
ALLOWED='^(checks\.txt|TASKS\.md)$'
EOF
    echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/1.sh"; echo "VERDICT: ACCEPT" >"$FAKE_DIR/verdicts"
    echo junk >junk.txt
    "$TOOL_DIR/menu.sh" start 1 >"$T/p1.txt" 2>&1 || fail "start failed: $(cat "$T/p1.txt")"
    grep -q Started "$T/p1.txt" || fail "start: no Started: $(cat "$T/p1.txt")"
    grep -qF "clean -fd in $T/p1" "$T/p1.txt" || fail "start: cleaning message does not name the work directory: $(cat "$T/p1.txt")"
    b_wait_off "start"
    grep -q "Run 1 accepted" "$T/p1-conf/.autopilot/log/history.log" || fail "start: the run never happened (tmux PATH?): $(cat "$T/p1-conf/.autopilot/log/console.txt")"
    printf 'TASKS_FILE=NOPE.md\n' >>"$AUTOPILOT_CONF"; "$TOOL_DIR/menu.sh" trust "$AUTOPILOT_CONF" >/dev/null
    "$TOOL_DIR/menu.sh" start 1 >"$T/p1.txt" 2>&1 && fail "start exits 0 although autopilot.sh ended at once: $(cat "$T/p1.txt")"
    grep -q "NOPE.md is missing" "$T/p1.txt" && ! grep -q Started "$T/p1.txt" || fail "start: failure not reported: $(cat "$T/p1.txt")"
    # P2: abort stops autopilot.sh and its worker, then cleans up
    b_project "$T/p2a" <<'EOF'
TEST_CMD='bash check.sh'
ALLOWED='^(checks\.txt|new\.txt|TASKS\.md)$'
EOF
    echo "echo new >new.txt; touch \"\$FAKE_DIR/started\"; sleep 5; echo late >\"\$FAKE_DIR/late\"" >"$FAKE_DIR/steps/1.sh"
    "$TOOL_DIR/menu.sh" start 1 >"$T/p2a.txt" 2>&1 || fail "abort: start failed: $(cat "$T/p2a.txt")"
    for _ in $(seq 1 40); do [ -e "$FAKE_DIR/started" ] && break; sleep 0.25; done
    [ -e "$FAKE_DIR/started" ] || fail "abort: worker never started: $(cat "$T/p2a-conf/.autopilot/log/console.txt")"
    "$TOOL_DIR/menu.sh" abort >"$T/p2a.txt" 2>&1
    grep -qF "clean -fd in $T/p2a" "$T/p2a.txt" || fail "abort: message does not name the work directory: $(cat "$T/p2a.txt")"
    sleep 4  # the worker would write "late" 5 s after its start
    [ ! -e "$FAKE_DIR/late" ] || fail "abort: the worker kept running"
    [ ! -e "$T/p2a-conf/.autopilot/lock" ] || fail "abort: lock not released"
    grep -qi interrupted "$T/p2a-conf/.autopilot/log/history.log" || fail "abort: autopilot.sh was not interrupted: $(cat "$T/p2a-conf/.autopilot/log/history.log")"
    [ -z "$(git status --porcelain)" ] || fail "abort: work directory not clean"
    b_wait_off "abort"
    # P9: "." or ":" in NAME (tmux would rename the session): status still finds it
    b_project "$T/p9" <<'EOF'
NAME=v1.2:x
TEST_CMD='bash check.sh'
ALLOWED='^(checks\.txt|TASKS\.md)$'
EOF
    echo "touch \"\$FAKE_DIR/started\"; sleep 5; echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/1.sh"; echo "VERDICT: ACCEPT" >"$FAKE_DIR/verdicts"
    "$TOOL_DIR/menu.sh" start 1 >"$T/p9.txt" 2>&1 || fail "NAME with a dot: start failed: $(cat "$T/p9.txt")"
    for _ in $(seq 1 40); do [ -e "$FAKE_DIR/started" ] && break; sleep 0.25; done
    "$TOOL_DIR/menu.sh" status | grep -q '^Status: *running' || fail "NAME with a dot: status does not find the session: $(tmux ls)"
    "$TOOL_DIR/menu.sh" abort >/dev/null 2>&1; b_wait_off "NAME with a dot"
    tmux kill-server 2>/dev/null; unset TMUX_TMPDIR
    trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
else echo "(tmux missing: start/abort/session name tests skipped)"; fi
unset AUTOPILOT_CONF
cd "$T" || exit 1
