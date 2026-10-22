# Sourced by test_autopilot.sh (same shell: $T, $TOOL_DIR, $FAKE_DIR, fail, new_round, sample_project,
# $tick, b_project from part_b.sh): fixes from the 0.9 review – milestones with an acceptance test, start checks,
# fresh checkout at the start, secrets regex, test-control files, gatekeeper prompts, plan from an idea, colours.
# PART_J_ONLY='j1 …' runs only the named blocks.

# J1: ACCEPT_CMD and three milestones: the acceptance goal is only required at the last one; the final review of an
# intermediate milestone sees only that milestone's change (from the commit in .autopilot/milestone)
pj_j1() {
    b_project "$T/pj1" <<EOF
TEST_CMD='bash check.sh'
ACCEPT_CMD='bash accept.sh'
PLAN_FILE=$T/pj1/plan.md
LOCKED=(plan.md accept.sh)
DEMO_CMD='bash check.sh'
FRESH_CHECK=off
EOF
    printf '# Plan\n\n## Milestone 1: a\n\n## Milestone 2: b\n\n```\n## Milestone 7: only an example\n```\n\n## Milestone 3: c\n' >plan.md && git add plan.md && git commit -qm plan || fail "J1: setup failed"
    for n in 1 2 3; do echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/$n.sh"; done
    echo "printf 'check goal\ngoal\n' >>checks.txt; $tick" >"$FAKE_DIR/steps/4.sh"   # Accept 2 of 2 only in Milestone 3
    for n in 1 2 3 4; do echo "VERDICT: ACCEPT" >>"$FAKE_DIR/verdicts"; done
    echo '- [ ] 3. next. Done when a test passes.' >"$FAKE_DIR/planner.txt"
    local s=$T/pj1-conf/.autopilot
    MAX_RUNS=6 "$TOOL_DIR/autopilot.sh" >"$T/pj1.txt" 2>&1 || fail "J1: run failed: $(tail -3 "$T/pj1.txt"; cat "$s/log/history.log")"
    [ "$(cut -f1 "$s/outcome")" = delivered ] || fail "J1: milestones with ACCEPT_CMD not delivered: $(cat "$s/outcome"; cat "$s/log/history.log")"
    grep -q "Milestone 3: 1 tasks added" "$s/log/history.log" && ! grep -q "Milestone 7" "$s/log/history.log" ||
        fail "J1: milestone 3 not reached, or a heading in a code block counted: $(cat "$s/log/history.log")"
    local m2; m2=$(git rev-parse ":/Autopilot: tasks of Milestone 2")
    grep -q "^## Change: git diff $m2..HEAD" "$FAKE_DIR/final-prompt-2" && grep -q "this milestone's only" "$FAKE_DIR/final-prompt-2" ||
        fail "J1: final review of Milestone 2 not limited to its own change: $(grep '^## Change' "$FAKE_DIR/final-prompt-2")"
    grep -q "^## Change: git diff main...HEAD" "$FAKE_DIR/final-prompt-1" && grep -q "^## Change: git diff main...HEAD" "$FAKE_DIR/final-prompt-3" ||
        fail "J1: first or last final review not over the whole change"
}

# J2: plan accept starts afresh: milestone, final-review rounds and no-progress count of an earlier plan are removed
pj_j2() {
    new_round; sample_project "$T/pj2"; git add -A && git commit -qm start || fail "J2: setup failed"
    printf "===CONFIG===\nTEST_CMD='bash check.sh'\nDEMO_CMD='bash check.sh'\n===TASKS===\n- [ ] 1. one. Done when a test passes.\n" >"$FAKE_DIR/setup.txt"
    "$TOOL_DIR/menu.sh" plan "$T/pj2/plan.md" >/dev/null 2>&1 || fail "J2: plan failed"
    for f in milestone final-rounds no-progress; do echo 2 >"$T/pj2/.autopilot/$f"; done
    "$TOOL_DIR/menu.sh" plan accept >"$T/pj2.txt" 2>&1 || fail "J2: accept failed: $(cat "$T/pj2.txt")"
    for f in milestone final-rounds no-progress; do [ ! -e "$T/pj2/.autopilot/$f" ] || fail "J2: .autopilot/$f kept by plan accept"; done
}

# J3: the start runs TEST_CMD once in a fresh checkout: red (needs an ignored file) or no checkout possible stops
# at once with the reason and FRESH_CHECK=off; FRESH_CHECK=off starts
pj_j3() {
    b_project "$T/pj3" <<'EOF'
TEST_CMD='test -e local.txt && bash check.sh'
EOF
    echo local.txt >.gitignore && echo here >local.txt && git add .gitignore && git commit -qm ignore || fail "J3: setup failed"
    echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/1.sh"; echo "VERDICT: ACCEPT" >"$FAKE_DIR/verdicts"
    local h=$T/pj3-conf/.autopilot/log/history.log
    MAX_RUNS=1 "$TOOL_DIR/autopilot.sh" >"$T/pj3.txt" 2>&1 && fail "J3: red TEST_CMD in a fresh checkout started"
    grep -q "TEST_CMD is red in a fresh checkout of HEAD.*FRESH_CHECK=off" "$h" && [ ! -e "$FAKE_DIR/step-nr" ] || fail "J3: no clear stop before the first run: $(cat "$h")"
    [ "$(git worktree list | wc -l)" = 1 ] || fail "J3: fresh checkout not removed: $(git worktree list)"
    git rm -q --cached .gitignore && rm .gitignore && git commit -qm unignore && git add local.txt && git commit -qm local || fail "J3: setup failed"
    TMPDIR=$T/no-such-dir MAX_RUNS=1 "$TOOL_DIR/autopilot.sh" >"$T/pj3.txt" 2>&1 && fail "J3: start without a fresh checkout went on"
    grep -q "No fresh checkout of HEAD could be made for the start check" "$h" && ! grep -q "works only in the work directory" "$h" ||
        fail "J3: a failed checkout not named as such: $(tail -3 "$h")"
    echo "FRESH_CHECK=off" >>"$AUTOPILOT_CONF"; "$TOOL_DIR/menu.sh" trust "$AUTOPILOT_CONF" >/dev/null
    TMPDIR=$T/no-such-dir MAX_RUNS=1 "$TOOL_DIR/autopilot.sh" >"$T/pj3.txt" 2>&1 || fail "J3: FRESH_CHECK=off did not start: $(tail -3 "$T/pj3.txt")"
    grep -q "Run 1 accepted" "$h" || fail "J3: FRESH_CHECK=off run not accepted: $(cat "$h")"
}

# J4: secrets regex – harmless names with password/token/secret/api key inside do not hit, real ones do (the
# values are built at runtime); SECRETS_CHECK=off switches the check off
pj_j4() {
    local l v; v=$(printf '%s' Zx9Qp4 Lm7Rt2 Wv8Ky3 Hn6Bc1)
    for l in 'tokenizer_name = "bert-base-uncased-finetuned"' 'PASSWORD_HASHERS = "django.contrib.auth.hashers"' \
             'passwordResetTitle: "auth.password.reset.title"' 'secret_env = "MY_APP_SECRET_KEY_ENV_NAME"' \
             'apiKeyHeader = "X-Api-Key-Header-Name-Long"'; do
        ( . "$TOOL_DIR/lib.sh"; grep -qE -- "$SECRETS" <<<"$l" ) && fail "J4: harmless line taken for a secret: $l"
    done
    for l in "DB_PASSWORD = \"$v\"" "dbPassword: '$v'" "aws = AKIA$(printf '%s' ABCDEFGH IJKLMNOP)"; do
        ( . "$TOOL_DIR/lib.sh"; grep -qE -- "$SECRETS" <<<"$l" ) || fail "J4: secret not found: $l"
    done
    b_project "$T/pj4" <<'EOF'
TEST_CMD='bash check.sh'
SECRETS_CHECK=off
EOF
    echo "echo check >>checks.txt; echo 'DB_PASSWORD = \"$v\"' >code.txt; $tick" >"$FAKE_DIR/steps/1.sh"; echo "VERDICT: ACCEPT" >"$FAKE_DIR/verdicts"
    MAX_RUNS=1 "$TOOL_DIR/autopilot.sh" >"$T/pj4.txt" 2>&1 || fail "J4: run failed: $(tail -3 "$T/pj4.txt")"
    grep -q "Run 1 accepted" "$T/pj4-conf/.autopilot/log/history.log" || fail "J4: SECRETS_CHECK=off still rejects: $(cat "$T/pj4-conf/.autopilot/log/history.log")"
}

# J5: settings with a fixed form are checked at the start (crit, exit 1, no Claude call); 0.8 settings that would
# silently drop a check are refused, harmless ones only warned about
pj_j5() {
    local c
    for c in 'MAX_RUNS=ten' 'ATTEMPTS=-1' 'MAX_BLOCKED=2.5' 'NO_PROGRESS=' 'MAX_COST_USD=lots' 'FRESH_CHECK=yes' 'SECRETS_CHECK=0' 'SANDBOX=maybe' \
             'SUPERVISED=on' "SMOKE_TEST_CMD='true'" 'LICENCE_FILE=x' 'REPORT_MODEL=opus'; do
        b_project "$T/pj5" <<EOF
TEST_CMD='bash check.sh'
$c
EOF
        "$TOOL_DIR/autopilot.sh" >"$T/pj5.txt" 2>&1 && fail "J5: $c accepted"
        grep -q "${c%%=*}" "$T/pj5-conf/.autopilot/log/history.log" && [ ! -e "$FAKE_DIR/step-nr" ] || fail "J5: $c not named, or Claude started: $(cat "$T/pj5.txt")"
        rm -rf "$T/pj5" "$T/pj5-conf"
    done
    b_project "$T/pj5" <<'EOF'
TEST_CMD='bash check.sh'
STALL_WARN_AFTER=4
ACCEPT_LIST_CMD='true'
MAX_COST_USD=7.5
EOF
    echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/1.sh"; echo "VERDICT: ACCEPT" >"$FAKE_DIR/verdicts"
    MAX_RUNS=1 "$TOOL_DIR/autopilot.sh" >"$T/pj5.txt" 2>&1 || fail "J5: run with warnings failed: $(tail -3 "$T/pj5.txt")"
    grep -q "STALL_WARN_AFTER .* ignored .*NO_PROGRESS" "$T/pj5-conf/.autopilot/log/history.log" && grep -q "ACCEPT_LIST_CMD .* ignored" "$T/pj5-conf/.autopilot/log/history.log" ||
        fail "J5: no warning for STALL_WARN_AFTER or ACCEPT_LIST_CMD: $(cat "$T/pj5-conf/.autopilot/log/history.log")"
}

# J6: without ALLOWED the files behind TEST_CMD are locked too: its own script (first word), conftest.py, gradlew
pj_j6() {
    b_project "$T/pj6" <<'EOF'
TEST_CMD='./check.sh'
ATTEMPTS=5
EOF
    chmod +x check.sh && git add -A && git commit -qm exec || fail "J6: setup failed"
    echo "echo check >>checks.txt; echo '# x' >>check.sh; $tick" >"$FAKE_DIR/steps/1.sh"
    echo "echo check >>checks.txt; mkdir -p tests; echo x >tests/conftest.py; $tick" >"$FAKE_DIR/steps/2.sh"
    echo "echo check >>checks.txt; echo x >gradlew; $tick" >"$FAKE_DIR/steps/3.sh"
    echo "echo check >>checks.txt; mkdir -p gradle/wrapper; echo x >gradle/wrapper/gradle-wrapper.properties; $tick" >"$FAKE_DIR/steps/4.sh"
    echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/5.sh"; echo "VERDICT: ACCEPT" >"$FAKE_DIR/verdicts"
    MAX_RUNS=5 "$TOOL_DIR/autopilot.sh" >"$T/pj6.txt" 2>&1 || fail "J6: run failed: $(tail -3 "$T/pj6.txt")"
    local h=$T/pj6-conf/.autopilot/log/history.log f n=1
    for f in check.sh tests/conftest.py gradlew gradle/wrapper/gradle-wrapper.properties; do
        grep -q "Run $n rejected: change to a file that controls the test command: $f" "$h" || fail "J6: $f not locked without ALLOWED: $(cat "$h")"
        n=$((n + 1))
    done
    grep -q "Run 5 accepted" "$h" || fail "J6: ordinary change refused: $(cat "$h")"
}

# J7: MERGE=ff does not fast-forward when that would overwrite a file that is ignored in the main worktree
pj_j7() {
    new_round; sample_project "$T/pj7"
    printf -- '- [ ] 1. one\n' >TASKS.md && git add -A && git commit -qm start && git worktree add -q "$T/pj7-wt" -b autopilot || fail "J7: setup failed"
    mkdir -p "$T/pj7/local" && echo '*' >"$T/pj7/local/.gitignore" && echo mine >"$T/pj7/local/conf.txt"   # ignored, so the main worktree looks clean
    mkdir -p "$T/pj7-conf"; printf "WORKDIR=%q\nTEST_CMD='bash check.sh'\nDEMO_CMD='bash check.sh'\nFRESH_CHECK=off\n" "$T/pj7-wt" >"$T/pj7-conf/autopilot.conf"
    export AUTOPILOT_CONF=$T/pj7-conf/autopilot.conf; "$TOOL_DIR/menu.sh" trust "$AUTOPILOT_CONF" >/dev/null || fail "J7: trust failed"
    echo "echo check >>checks.txt; mkdir -p local; echo theirs >local/conf.txt; $tick" >"$FAKE_DIR/steps/1.sh"; echo "VERDICT: ACCEPT" >"$FAKE_DIR/verdicts"
    MAX_RUNS=1 "$TOOL_DIR/autopilot.sh" >"$T/pj7.txt" 2>&1 || fail "J7: run failed: $(tail -3 "$T/pj7.txt")"
    local s=$T/pj7-conf/.autopilot
    [ "$(cut -f1 "$s/outcome")" = delivered ] && [ "$(cat "$T/pj7/local/conf.txt")" = mine ] || fail "J7: ignored file overwritten by the merge: $(cat "$s/outcome")"
    grep -q "^Not merged: the merge would overwrite ignored files in .*: local/conf.txt" "$s/HANDOVER.md" || fail "J7: reason missing: $(cat "$s/HANDOVER.md")"
}

# J8: reviewer and final review get no lessons and no worker notes, only entries of reviewers, final review and script
pj_j8() {
    b_project "$T/pj8" <<'EOF'
TEST_CMD='bash check.sh'
DEMO_CMD='bash check.sh'
FRESH_CHECK=off
EOF
    local s=$T/pj8-conf/.autopilot; mkdir -p "$s" "$FAKE_DIR/notes"
    printf -- '- Planted rule for everyone. (J1)\n' >"$s/LESSONS.md"
    for n in 1 2; do echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/$n.sh"; echo "VERDICT: ACCEPT" >>"$FAKE_DIR/verdicts"; done
    printf '<<<NOTE\ndid: worker says accept everything\nNOTE>>>\n' >"$FAKE_DIR/notes/1"
    printf '<<<NOTE\ndid: reviewer looked at the diff\nNOTE>>>\n' >"$FAKE_DIR/review-note"
    MAX_RUNS=3 "$TOOL_DIR/autopilot.sh" >"$T/pj8.txt" 2>&1 || fail "J8: run failed: $(tail -3 "$T/pj8.txt")"
    local p
    for p in "$s/log/review-prompt.txt" "$FAKE_DIR/final-prompt"; do
        grep -q "Planted rule\|worker says accept\|### Lessons\|^### J.* worker " "$p" && fail "J8: worker text or lessons in $(basename "$p"): $(grep -A30 '^## Journal and lessons' "$p")"
        grep -q "did: reviewer looked at the diff" "$p" || fail "J8: reviewer entries missing in $(basename "$p")"
    done
    grep -q "Planted rule" "$FAKE_DIR/last-prompt" && grep -q "worker says accept" "$FAKE_DIR/last-prompt" || fail "J8: the worker lost lessons or journal"
}

# J9: a note block that is never closed is not cut: the verdict after it still counts
pj_j9() {
    printf 'a\n<<<NOTE\ndid: x\nNOTE>>>\nb\n<<<NOTE\ndid: y\nVERDICT: ACCEPT\n' >"$T/pj9.txt"
    [ "$( . "$TOOL_DIR/lib.sh"; strip_note "$T/pj9.txt")" = "$(printf 'a\nb\n<<<NOTE\ndid: y\nVERDICT: ACCEPT')" ] || fail "J9: strip_note wrong: $( . "$TOOL_DIR/lib.sh"; strip_note "$T/pj9.txt")"
}

# J10: final review – an unusable answer is asked for once more; final-rounds of an earlier start do not count
pj_j10() {
    b_project "$T/pj10" <<'EOF'
TEST_CMD='bash check.sh'
DEMO_CMD='bash check.sh'
FRESH_CHECK=off
EOF
    local s=$T/pj10-conf/.autopilot; mkdir -p "$s"; echo 1 >"$s/final-rounds"   # left over from an earlier start
    for n in 1 2 3; do echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/$n.sh"; echo "VERDICT: ACCEPT" >>"$FAKE_DIR/verdicts"; done
    echo 'I could not decide.' >"$FAKE_DIR/final-1.txt"
    echo '- [ ] 3. Fix it. Done when a test passes.' >"$FAKE_DIR/final-2.txt"
    MAX_RUNS=5 "$TOOL_DIR/autopilot.sh" >"$T/pj10.txt" 2>&1 || fail "J10: run failed: $(tail -3 "$T/pj10.txt"; cat "$s/log/history.log")"
    [ "$(cut -f1 "$s/outcome")" = delivered ] && grep -q '^- \[x\] 3\. Fix it' TASKS.md || fail "J10: not delivered: $(cat "$s/outcome")"
    grep -q "Final review (round 1): no usable answer, asking once more" "$s/log/history.log" && [ "$(cat "$FAKE_DIR/final-nr")" = 3 ] ||
        fail "J10: final review not asked again: $(cat "$s/log/history.log")"
}

# J11: plan "<idea>" in a Git project: plan accept commits the plan in the base branch (the work branch has it, the
# main worktree stays clean), warns about other changes; WORKER_TOOLS also cover demo and check commands;
# doctor names a dirty main worktree under MERGE=ff
pj_j11() {
    new_round; sample_project "$T/pj11"; git add -A && git commit -qm start || fail "J11: setup failed"
    printf '# Tiny counter\n\n## Deliverable\nDemo: bash check.sh --demo\n' >"$FAKE_DIR/idea.txt"
    printf "===CONFIG===\nTEST_CMD='bash check.sh'\nDEMO_CMD='bash check.sh --demo'\nWORKER_TOOLS=(Read Edit Write Glob Grep 'Bash(bash check.sh:*)')\n===TASKS===\n- [ ] 1. one. Done when \`test -e out.txt\` exits 0.\n" >"$FAKE_DIR/setup.txt"
    "$TOOL_DIR/menu.sh" plan "a tiny counter tool" >"$T/pj11.txt" 2>&1 || fail "J11: plan from an idea failed: $(tail -3 "$T/pj11.txt")"
    echo other >"$T/pj11/other.txt"
    "$TOOL_DIR/menu.sh" plan accept >"$T/pj11.txt" 2>&1 || fail "J11: accept failed: $(cat "$T/pj11.txt")"
    grep -q "Warning: .* has other uncommitted changes" "$T/pj11.txt" || fail "J11: no warning about the dirty main worktree: $(cat "$T/pj11.txt")"
    [ "$(git log -1 --format=%s)" = "Plan: Tiny counter" ] && git log -1 --format=%B | grep -q "^Co-Authored-By: Claude" &&
        [ "$(git show --name-only --format= HEAD)" = a-tiny-counter-tool-plan.md ] || fail "J11: plan not committed alone: $(git log -1 --stat)"
    [ -f "$T/pj11-autopilot/a-tiny-counter-tool-plan.md" ] || fail "J11: plan missing in the work branch"
    [ "$(git status --porcelain)" = "?? other.txt" ] || fail "J11: main worktree not clean apart from other.txt: $(git status --porcelain)"
    local w; w=$(sed -n 's/^WORKER_TOOLS=//p' "$T/pj11/autopilot.conf")
    grep -qF "bash check.sh --demo:*)'" <<<"$w" && grep -qF "test -e out.txt:*)'" <<<"$w" && [ "$(grep -o 'bash check.sh:\*' <<<"$w" | wc -l)" = 1 ] ||
        fail "J11: WORKER_TOOLS without demo or check command, or twice the test command: $w"
    "$TOOL_DIR/menu.sh" doctor >"$T/pj11.txt" 2>&1
    grep -q "MERGE=ff: .* has uncommitted or untracked files" "$T/pj11.txt" || fail "J11: doctor does not name the dirty main worktree: $(cat "$T/pj11.txt")"
    # before the first start: autopilot.conf and .autopilot/ untracked and not yet excluded are no leftovers
    rm other.txt; : >"$(git rev-parse --git-common-dir)/info/exclude"; [ -n "$(git status --porcelain)" ] || fail "J11: setup of the clean case failed"
    "$TOOL_DIR/menu.sh" doctor >"$T/pj11.txt" 2>&1
    grep -q "MERGE=ff" "$T/pj11.txt" && fail "J11: doctor names autopilot.conf or .autopilot/ as leftovers: $(git status --porcelain)"
}

# J12: colours: project commands run with NO_COLOR/TERM=dumb, and escape sequences never reach the handover
pj_j12() {
    b_project "$T/pj12" <<'EOF'
TEST_CMD='bash check.sh'
DEMO_CMD='printf "\033[1;32mDEMO OK\033[0m NO_COLOR=%s TERM=%s\n" "$NO_COLOR" "$TERM"'
FRESH_CHECK=off
EOF
    for n in 1 2; do echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/$n.sh"; echo "VERDICT: ACCEPT" >>"$FAKE_DIR/verdicts"; done
    MAX_RUNS=3 "$TOOL_DIR/autopilot.sh" >"$T/pj12.txt" 2>&1 || fail "J12: run failed: $(tail -3 "$T/pj12.txt")"
    local hv=$T/pj12-conf/.autopilot/HANDOVER.md
    grep -q "^DEMO OK NO_COLOR=1 TERM=dumb$" "$hv" || fail "J12: demo line missing or still coloured: $(grep DEMO "$hv" | od -c | head -3)"
    grep -q "$(printf '\033')" "$hv" && fail "J12: escape sequence in the handover"
    return 0
}

# J13: merged into main: outcome, handover head, status --short and notification say so, FRESH_CHECK=off is named in the
# proof; the worker is told to run the demo only when a WORKER_TOOLS entry covers it, not the task's check command here
pj_j13() {
    new_round; sample_project "$T/pj13"
    printf -- '- [ ] 1. one. Done when `test -e out.txt` exits 0.\n' >TASKS.md && git add -A && git commit -qm start && git worktree add -q "$T/pj13-wt" -b autopilot || fail "J13: setup failed"
    mkdir -p "$T/pj13-conf"; printf "WORKDIR=%q\nTEST_CMD='bash check.sh'\nDEMO_CMD='bash check.sh --demo'\nWORKER_TOOLS=(Read Edit 'Bash(bash check.sh:*)')\nFRESH_CHECK=off\n" "$T/pj13-wt" >"$T/pj13-conf/autopilot.conf"
    export AUTOPILOT_CONF=$T/pj13-conf/autopilot.conf; "$TOOL_DIR/menu.sh" trust "$AUTOPILOT_CONF" >/dev/null || fail "J13: trust failed"
    mkdir -p "$T/pj13-conf/.autopilot"; echo 'test -e out.txt' >"$T/pj13-conf/.autopilot/approved-checks"  # a hand-written list: approved by hand
    echo "echo x >out.txt; $tick" >"$FAKE_DIR/steps/1.sh"; echo "VERDICT: ACCEPT" >"$FAKE_DIR/verdicts"
    local log=$T/pj13-notify.log s=$T/pj13-conf/.autopilot; : >"$log"
    NOTIFY_LOG=$log MAX_RUNS=1 "$TOOL_DIR/autopilot.sh" >"$T/pj13.txt" 2>&1 || fail "J13: run failed: $(tail -3 "$T/pj13.txt")"
    [ "$(cat "$s/outcome")" = "$(printf 'delivered\tmerged into main')" ] || fail "J13: outcome wrong: $(cat "$s/outcome")"
    head -1 "$s/HANDOVER.md" | grep -qx "# Delivered, merged into main" || fail "J13: handover head wrong: $(head -1 "$s/HANDOVER.md")"
    grep -qx "Fresh checkout: off (FRESH_CHECK=off)" "$s/HANDOVER.md" && grep -q "Fresh checkout: off (FRESH_CHECK=off)$" "$s/log/history.log" ||
        fail "J13: FRESH_CHECK=off not named: $(grep -i fresh "$s/HANDOVER.md" "$s/log/history.log")"
    "$TOOL_DIR/menu.sh" status --short | grep -q "^Autopilot pj13-conf ended: delivered, merged into main - 1 done" || fail "J13: status --short wrong: $("$TOOL_DIR/menu.sh" status --short)"
    tail -1 "$log" | grep -q "Autopilot pj13-conf Delivered, merged into main$" || fail "J13: notification wrong: $(tail -1 "$log")"
    grep -qF "Demo command (it must exit 0 once all tasks are done): run the demo command yourself to try your change: \`bash check.sh --demo\`" "$FAKE_DIR/last-prompt" &&
        grep -qF "Check command of this task (it must exit 0): you cannot run the check command yourself; the script runs it after you: \`test -e out.txt\`" "$FAKE_DIR/last-prompt" ||
        fail "J13: run hints wrong: $(grep -E 'Demo command|Check command' "$FAKE_DIR/last-prompt")"
}

# J14: MERGE=off: plain "delivered" everywhere; a compound demo is not offered although a prefix entry matches its start
pj_j14() {
    b_project "$T/pj14" <<'EOF'
TEST_CMD='bash check.sh'
DEMO_CMD='bash check.sh && true'
WORKER_TOOLS=(Read Edit 'Bash(bash check.sh:*)')
MERGE=off
FRESH_CHECK=off
EOF
    for n in 1 2; do echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/$n.sh"; echo "VERDICT: ACCEPT" >>"$FAKE_DIR/verdicts"; done
    MAX_RUNS=3 "$TOOL_DIR/autopilot.sh" >"$T/pj14.txt" 2>&1 || fail "J14: run failed: $(tail -3 "$T/pj14.txt")"
    local s=$T/pj14-conf/.autopilot
    [ "$(cat "$s/outcome")" = "$(printf 'delivered\t')" ] && head -1 "$s/HANDOVER.md" | grep -qx "# Delivered" ||
        fail "J14: MERGE=off not plain delivered: $(cat "$s/outcome"; head -1 "$s/HANDOVER.md")"
    "$TOOL_DIR/menu.sh" status --short | grep -q "^Autopilot pj14-conf ended: delivered - 2 done" || fail "J14: status --short wrong: $("$TOOL_DIR/menu.sh" status --short)"
    grep -qF "you cannot run the demo command yourself; the script runs it after you: \`bash check.sh && true\`" "$FAKE_DIR/last-prompt" ||
        fail "J14: compound demo offered to the worker: $(grep 'Demo command' "$FAKE_DIR/last-prompt")"
}

# J15: a multi-step demo as "bash demo.sh": plan accept lets the worker run exactly that command, and without ALLOWED
# demo.sh is locked like the test command's own script
pj_j15() {
    new_round; sample_project "$T/pj15"; echo 'bash check.sh' >demo.sh; git add -A && git commit -qm start || fail "J15: setup failed"
    printf "===CONFIG===\nTEST_CMD='bash check.sh'\nDEMO_CMD='bash demo.sh'\n===TASKS===\n- [ ] 1. one. Done when a test passes.\n" >"$FAKE_DIR/setup.txt"
    "$TOOL_DIR/menu.sh" plan "$T/pj15/plan.md" >/dev/null 2>&1 && "$TOOL_DIR/menu.sh" plan accept >"$T/pj15.txt" 2>&1 || fail "J15: plan failed: $(cat "$T/pj15.txt")"
    grep -qE "'Bash\((.*/sandbox-run )?bash demo.sh:\*\)'" "$T/pj15/autopilot.conf" || fail "J15: WORKER_TOOLS without the demo command: $(grep WORKER_TOOLS "$T/pj15/autopilot.conf")"
    b_project "$T/pj15b" <<'EOF'
TEST_CMD='bash check.sh'
DEMO_CMD='bash demo.sh'
ATTEMPTS=3
EOF
    echo 'bash check.sh' >demo.sh && git add demo.sh && git commit -qm demo || fail "J15: setup failed"
    echo "echo check >>checks.txt; echo true >demo.sh; $tick" >"$FAKE_DIR/steps/1.sh"
    echo "echo check >>checks.txt; $tick" >"$FAKE_DIR/steps/2.sh"; echo "VERDICT: ACCEPT" >"$FAKE_DIR/verdicts"
    MAX_RUNS=2 "$TOOL_DIR/autopilot.sh" >"$T/pj15.txt" 2>&1 || fail "J15: run failed: $(tail -3 "$T/pj15.txt")"
    local h=$T/pj15b-conf/.autopilot/log/history.log
    grep -q "Run 1 rejected: change to a file that controls the test command: demo.sh" "$h" && grep -q "Run 2 accepted" "$h" || fail "J15: demo.sh not locked: $(cat "$h")"
}

for pj in ${PART_J_ONLY:-j1 j2 j3 j4 j5 j6 j7 j8 j9 j10 j11 j12 j13 j14 j15}; do
    "pj_$pj"
    unset AUTOPILOT_CONF; cd "$T" || exit 1
done
unset pj
