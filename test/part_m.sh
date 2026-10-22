# Sourced by test_autopilot.sh (same shell: $T, $TOOL_DIR, $FAKE_DIR, fail, new_round, sample_project,
# b_project from part_b.sh): 0.10 – parallel workers (PARALLEL > 1). The steps are per task (steps/t<N>.sh), since
# the workers of a wave run in any order. PART_M_ONLY='m1 …' runs only the named blocks.
m_tick() { echo "sed -i 's/^- \\[ \\] $1\\./- [x] $1./' TASKS.md"; }  # step: tick off task N
m_tasks() { local n; for n in "$@"; do printf -- '- [ ] %s. Done when `bash check.sh` exits 0.\n' "$n"; done >TASKS.md; git commit -qam tasks || fail "M: setup failed"; }
m_steps() { local n; for n in "$@"; do echo "echo $n >f$n.txt; $(m_tick "$n")" >"$FAKE_DIR/steps/t$n.sh"; done; }  # task N writes fN.txt, ticks off

# M1: two independent tasks run at the same time (time stamps overlap), each in its own worktree; the script merges
# both (the decisions both workers appended are kept), two commits, the list right, status shows the wave, no worktree left
pm_m1() {
    b_project "$T/pm1" <<'EOF'
TEST_CMD='bash check.sh'
PARALLEL=2
EOF
    m_tasks "1. one" "2. two"
    local n s=$T/pm1-conf/.autopilot
    for n in 1 2; do
        echo "date +%s.%N >\"\$FAKE_DIR/t$n.start\"; sleep 1; echo $n >f$n.txt; echo 'decision $n' >>DECISIONS.md; $(m_tick $n); pwd >\"\$FAKE_DIR/t$n.cwd\"; date +%s.%N >\"\$FAKE_DIR/t$n.end\"" >"$FAKE_DIR/steps/t$n.sh"
        echo "VERDICT: ACCEPT" >>"$FAKE_DIR/verdicts"
    done
    echo "\"$TOOL_DIR/menu.sh\" status >\"\$FAKE_DIR/status-during\"" >>"$FAKE_DIR/steps/t1.sh"
    MAX_RUNS=2 "$TOOL_DIR/autopilot.sh" >"$T/pm1.txt" 2>&1 || fail "M1: run failed: $(tail -3 "$T/pm1.txt")"
    grep -q "Run 1: 1\. one\..* (wave of 2)$" "$s/log/history.log" && grep -q "Run 2: 2\. two\..* (wave of 2)$" "$s/log/history.log" &&
        grep -q "Run 1 accepted: \[x\] 1\. one" "$s/log/history.log" && grep -q "Run 2 accepted: \[x\] 2\. two" "$s/log/history.log" || fail "M1: history wrong: $(cat "$s/log/history.log")"
    awk -v a="$(cat "$FAKE_DIR/t1.start")" -v b="$(cat "$FAKE_DIR/t1.end")" -v c="$(cat "$FAKE_DIR/t2.start")" -v d="$(cat "$FAKE_DIR/t2.end")" 'BEGIN { exit !(a < d && c < b) }' ||
        fail "M1: the workers did not overlap: $(cat "$FAKE_DIR"/t?.start "$FAKE_DIR"/t?.end)"
    [ "$(cat "$FAKE_DIR/t1.cwd")" != "$(cat "$FAKE_DIR/t2.cwd")" ] && [ "$(cat "$FAKE_DIR/t1.cwd")" != "$T/pm1" ] || fail "M1: the workers did not run in worktrees of their own"
    [ "$(git log --format=%s | grep -c '^Autopilot: \[x\]')" = 2 ] && [ "$(git ls-files f1.txt f2.txt | wc -l)" = 2 ] || fail "M1: not two commits: $(git log --stat | head -30)"
    [ "$(cat TASKS.md)" = "$(printf -- '- [x] 1. one. Done when `bash check.sh` exits 0.\n- [x] 2. two. Done when `bash check.sh` exits 0.')" ] || fail "M1: task list wrong: $(cat TASKS.md)"
    grep -qx 'decision 1' DECISIONS.md && grep -qx 'decision 2' DECISIONS.md || fail "M1: decisions of both workers not kept: $(cat DECISIONS.md)"
    grep -q 'f2.txt' "$s/log/review-prompt.txt" && ! grep -q 'f1.txt' "$s/log/review-prompt.txt" || fail "M1: the reviewer of task 2 did not get only its own diff"
    grep -q "^Wave:        2 workers at the same time" "$FAKE_DIR/status-during" && grep -q "Run 1: 1\. one" "$FAKE_DIR/status-during" &&
        grep -q "Run 2: 2\. two" "$FAKE_DIR/status-during" || fail "M1: status during the wave does not show it: $(cat "$FAKE_DIR/status-during")"
    [ "$(git worktree list | wc -l)" = 1 ] && [ ! -e "$s/wave" ] && [ -z "$(git status --porcelain)" ] || fail "M1: worktrees or the wave file left: $(git worktree list)"
    [ "$(grep -c ';worker;' "$s/costs.csv")" = 2 ] && [ "$(grep -c '^time;' "$s/costs.csv")" = 1 ] || fail "M1: costs.csv wrong: $(cat "$s/costs.csv")"
}

# M2: both tasks change the same line: the first is merged, the second gets the conflict as feedback (no attempt
# counted) and is done afterwards alone on the new base
pm_m2() {
    b_project "$T/pm2" <<'EOF'
TEST_CMD='bash check.sh'
PARALLEL=2
EOF
    echo base >shared.txt; git add shared.txt; m_tasks "1. one" "2. two"
    local s=$T/pm2-conf/.autopilot
    echo "echo one >shared.txt; $(m_tick 1)" >"$FAKE_DIR/steps/t1.sh"; echo "echo two >shared.txt; $(m_tick 2)" >"$FAKE_DIR/steps/t2.sh"
    printf 'VERDICT: ACCEPT\nVERDICT: ACCEPT\n' >"$FAKE_DIR/verdicts"
    MAX_RUNS=3 "$TOOL_DIR/autopilot.sh" >"$T/pm2.txt" 2>&1 || fail "M2: run failed: $(tail -3 "$T/pm2.txt")"
    grep -q "Run 1 accepted: \[x\] 1\. one" "$s/log/history.log" &&
        grep -q "Run 2: conflict with parallel task 1 – no attempt counted, retry on the new base (conflict 1 of 2)" "$s/log/history.log" &&
        grep -q "Run 3: 2\. two\. Done when .*exits 0\.$" "$s/log/history.log" && grep -q "Run 3 accepted: \[x\] 2\. two" "$s/log/history.log" || fail "M2: history wrong: $(cat "$s/log/history.log")"
    grep -q "conflict with parallel task 1, retry on the new base" "$FAKE_DIR/prompt-t2" && grep -q "Attempt 1 of at most 3" "$FAKE_DIR/prompt-t2" ||
        fail "M2: the retry did not get the conflict, or it counted as an attempt: $(grep -A3 'Feedback' "$FAKE_DIR/prompt-t2")"
    [ "$(cat shared.txt)" = two ] && grep -q '^- \[x\] 2\.' TASKS.md && grep -q 'worker 2\. two.* conflict with parallel task 1$' "$s/JOURNAL.md" || fail "M2: result wrong: $(cat shared.txt TASKS.md)"
    [ -z "$(ls -A "$s/pending" 2>/dev/null)" ] || fail "M2: pending state left: $(ls "$s/pending")"
}

# M3: the reviewer rejects one of the two: only that change is reset, the other one stays committed; the rejected
# task counts the attempt and goes on alone with the feedback (also after a restart)
pm_m3() {
    b_project "$T/pm3" <<'EOF'
TEST_CMD='bash check.sh'
PARALLEL=2
EOF
    m_tasks "1. one" "2. two"; m_steps 1 2
    local s=$T/pm3-conf/.autopilot
    printf 'VERDICT: ACCEPT\nVERDICT: REJECT: too thin\nVERDICT: ACCEPT\n' >"$FAKE_DIR/verdicts"
    MAX_RUNS=2 "$TOOL_DIR/autopilot.sh" >"$T/pm3.txt" 2>&1 || fail "M3: run failed: $(tail -3 "$T/pm3.txt")"
    grep -q "Run 1 accepted: \[x\] 1\. one" "$s/log/history.log" && grep -q "Run 2 rejected: Reviewer: too thin" "$s/log/history.log" || fail "M3: history wrong: $(cat "$s/log/history.log")"
    [ "$(git ls-files f1.txt)" = f1.txt ] && [ ! -e f2.txt ] && grep -q '^- \[x\] 1\.' TASKS.md && grep -q '^- \[ \] 2\.' TASKS.md && [ -z "$(git status --porcelain)" ] ||
        fail "M3: not only the rejected change reset: $(ls; cat TASKS.md)"
    # the next task is task 2: its failed attempt and feedback went from pending/ to the serial brake
    [ "$(cut -d' ' -f2 "$s/attempts")" = 1 ] && grep -q "Reviewer: too thin" "$s/feedback.txt" && [ -z "$(ls -A "$s/pending")" ] ||
        fail "M3: the rejection is not kept for the task: $(cat "$s/attempts" "$s/feedback.txt" 2>&1)"
    MAX_RUNS=1 "$TOOL_DIR/autopilot.sh" >"$T/pm3.txt" 2>&1 || fail "M3: second start failed: $(tail -3 "$T/pm3.txt")"
    grep -q "Attempt 2 of at most 3" "$FAKE_DIR/prompt-t2" && grep -q "Reviewer: too thin" "$FAKE_DIR/prompt-t2" || fail "M3: the retry lacks the attempt or the feedback"
    grep -q "Run 1 accepted: \[x\] 2\. two" "$s/log/history.log" && [ -z "$(ls -A "$s/pending")" ] || fail "M3: retry not accepted: $(tail -5 "$s/log/history.log")"
}

# M4: a task that depends on another is never in the same wave: 1 and 3 together, then 2 alone
pm_m4() {
    b_project "$T/pm4" <<'EOF'
TEST_CMD='bash check.sh'
PARALLEL=3
EOF
    m_tasks "1. one" "2. (after 1) two" "3. three"; m_steps 1 2 3
    local h=$T/pm4-conf/.autopilot/log/history.log
    printf 'VERDICT: ACCEPT\nVERDICT: ACCEPT\nVERDICT: ACCEPT\n' >"$FAKE_DIR/verdicts"
    MAX_RUNS=5 "$TOOL_DIR/autopilot.sh" >"$T/pm4.txt" 2>&1 || fail "M4: run failed: $(tail -3 "$T/pm4.txt")"
    grep -q "Run 1: 1\. one.* (wave of 2)$" "$h" && grep -q "Run 2: 3\. three.* (wave of 2)$" "$h" && grep -q "Run 3: 2\. (after 1) two.*exits 0\.$" "$h" &&
        grep -q "Run 3 accepted: \[x\] 2\." "$h" && [ "$(grep -c '^- \[x\]' TASKS.md)" = 3 ] || fail "M4: waves wrong: $(cat "$h")"
}

# M5: a worker that changes a locked file, and one that ticks off another task's line, are both rejected
pm_m5() {
    b_project "$T/pm5" <<'EOF'
TEST_CMD='bash check.sh'
PARALLEL=2
LOCKED=(plan.md)
EOF
    m_tasks "1. one" "2. two"
    local h=$T/pm5-conf/.autopilot/log/history.log head; head=$(git rev-parse HEAD)
    echo "echo x >>plan.md; echo 1 >f1.txt; $(m_tick 1)" >"$FAKE_DIR/steps/t1.sh"; echo "echo 2 >f2.txt; $(m_tick 1)" >"$FAKE_DIR/steps/t2.sh"
    MAX_RUNS=2 "$TOOL_DIR/autopilot.sh" >"$T/pm5.txt" 2>&1 || fail "M5: run failed: $(tail -3 "$T/pm5.txt")"
    grep -q "Run 1 rejected: locked file changed: plan.md" "$h" &&
        grep -q "Run 2 rejected: task list changed beyond ticking off or blocking the task picked for this run (only \[ \] -> \[x\] or \[~\] of line 2 is allowed)" "$h" ||
        fail "M5: not both rejected: $(cat "$h")"
    [ "$(git rev-parse HEAD)" = "$head" ] && [ -z "$(git status --porcelain)" ] && [ ! -e f1.txt ] && [ ! -e f2.txt ] || fail "M5: rejected changes left"
}

# M6: stop --now during a wave ends all workers and removes every temporary worktree
pm_m6() {
    b_project "$T/pm6" <<'EOF'
TEST_CMD='bash check.sh'
PARALLEL=2
EOF
    m_tasks "1. one" "2. two"
    local n s=$T/pm6-conf/.autopilot ap w
    for n in 1 2; do echo "touch \"\$FAKE_DIR/t$n.start\"; sleep 31.5; $(m_tick $n)" >"$FAKE_DIR/steps/t$n.sh"; done
    MAX_RUNS=2 "$TOOL_DIR/autopilot.sh" >"$T/pm6.txt" 2>&1 & ap=$!
    for n in $(seq 1 100); do [ -e "$FAKE_DIR/t1.start" ] && [ -e "$FAKE_DIR/t2.start" ] && break; sleep 0.1; done
    [ -e "$FAKE_DIR/t2.start" ] || fail "M6: the workers did not start: $(cat "$T/pm6.txt")"
    [ "$(git worktree list | wc -l)" = 3 ] || fail "M6: no worktree per worker: $(git worktree list)"
    w=$(git worktree list | sed -n '2s/ .*//p')
    "$TOOL_DIR/menu.sh" status --short | grep -q "wave of 2" || fail "M6: status --short does not show the wave: $("$TOOL_DIR/menu.sh" status --short)"
    "$TOOL_DIR/menu.sh" stop --now >"$T/pm6-stop.txt" 2>&1 || fail "M6: stop --now failed: $(cat "$T/pm6-stop.txt")"
    wait "$ap"
    [ "$(git worktree list | wc -l)" = 1 ] && [ ! -e "$w" ] || fail "M6: worktrees left: $(git worktree list)"
    ! pgrep -f 'sleep 31.5' >/dev/null || fail "M6: worker processes left: $(pgrep -af 'sleep 31.5')"
    [ "$(cut -f1 "$s/outcome")" = stopped ] && grep -q "Wave running at the end (discarded, PARALLEL=2):" "$s/HANDOVER.md" && grep -q "^Run 2: 2\. two" "$s/HANDOVER.md" ||
        fail "M6: outcome or handover wrong: $(cat "$s/outcome"; cat "$s/HANDOVER.md")"
    [ ! -e "$s/wave" ] && [ -z "$(git status --porcelain)" ] && grep -q '^- \[ \] 1\.' TASKS.md || fail "M6: wave file or changes left"
}

# M7: the cost cap makes the wave smaller: 3 workers at the mean worker cost so far (1 USD) do not fit into 2.5 USD;
# a wave of 1 is no wave
pm_m7() {
    b_project "$T/pm7" <<'EOF'
TEST_CMD='bash check.sh'
PARALLEL=3
SIZE_CHECK=off
MAX_COST_USD=2.5
EOF
    m_tasks "1. one" "2. two" "3. three"; m_steps 1 2 3
    local h=$T/pm7-conf/.autopilot/log/history.log; mkdir -p "$T/pm7-conf/.autopilot"
    printf 'time;kind;model;usd;input_tokens;cache_read_tokens;output_tokens;effort\n2026-01-01 10:00:00;worker;sonnet;1.00;1;2;3;medium\n' >"$T/pm7-conf/.autopilot/costs.csv"
    printf 'VERDICT: ACCEPT\nVERDICT: ACCEPT\nVERDICT: ACCEPT\n' >"$FAKE_DIR/verdicts"
    MAX_RUNS=5 "$TOOL_DIR/autopilot.sh" >"$T/pm7.txt" 2>&1 || fail "M7: run failed: $(tail -3 "$T/pm7.txt")"
    grep -q "Cost cap: 3 workers at about 1.0000 USD each would exceed MAX_COST_USD=2.5, wave of 2" "$h" && grep -q "Run 2: 2\. two.* (wave of 2)$" "$h" &&
        grep -q "Run 3: 3\. three.*exits 0\.$" "$h" && [ "$(grep -c '^- \[x\]' TASKS.md)" = 3 ] || fail "M7: wave not made smaller: $(cat "$h")"
    b_project "$T/pm7b" <<'EOF'
TEST_CMD='bash check.sh'
PARALLEL=2
SIZE_CHECK=off
MAX_COST_USD=1.5
EOF
    m_tasks "1. one" "2. two"; m_steps 1 2; mkdir -p "$T/pm7b-conf/.autopilot"; head -2 "$T/pm7-conf/.autopilot/costs.csv" >"$T/pm7b-conf/.autopilot/costs.csv"
    printf 'VERDICT: ACCEPT\nVERDICT: ACCEPT\n' >"$FAKE_DIR/verdicts"
    MAX_RUNS=2 "$TOOL_DIR/autopilot.sh" >"$T/pm7.txt" 2>&1 || fail "M7: second run failed: $(tail -3 "$T/pm7.txt")"
    grep -q "wave of 1$" "$T/pm7b-conf/.autopilot/log/history.log" && grep -q "Run 1: 1\. one\..*exits 0\.$" "$T/pm7b-conf/.autopilot/log/history.log" &&
        ! grep -q "(wave of" "$T/pm7b-conf/.autopilot/log/history.log" ||
        fail "M7: a wave of 1 ran as a wave: $(cat "$T/pm7b-conf/.autopilot/log/history.log")"
}

# M8: PARALLEL outside 1–4 is refused before any Claude call
pm_m8() {
    local v
    for v in 0 5 two; do
        b_project "$T/pm8" <<EOF
TEST_CMD='bash check.sh'
PARALLEL=$v
EOF
        "$TOOL_DIR/autopilot.sh" >"$T/pm8.txt" 2>&1 && fail "M8: PARALLEL=$v accepted"
        grep -q "PARALLEL='$v'.*1, 2, 3 or 4" "$T/pm8-conf/.autopilot/log/history.log" && [ ! -e "$FAKE_DIR/args" ] || fail "M8: PARALLEL=$v not named, or Claude started: $(cat "$T/pm8.txt")"
        rm -rf "$T/pm8" "$T/pm8-conf"
    done
}

for pm in ${PART_M_ONLY:-m1 m2 m3 m4 m5 m6 m7 m8}; do
    "pm_$pm"
    unset AUTOPILOT_CONF; cd "$T" || exit 1
done
unset pm
