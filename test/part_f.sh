# Sourced by test_autopilot.sh (same shell: $T, $TOOL_DIR, $FAKE_DIR, fail, new_round, sample_project,
# $tick, b_project from part_b.sh): missing-tool messages with purpose and install command, install_hint,
# install suggestions for a test command that cannot run, and `autopilot doctor`.
# PART_F_ONLY='f1 …' runs only the named blocks (used to prove each test fails without its fix).

# Stub package managers, so install_hint picks one deterministically
mkdir -p "$T/pf-apt" "$T/pf-brew"
printf '#!/bin/bash\nexit 0\n' >"$T/pf-apt/apt-get" && chmod +x "$T/pf-apt/apt-get"
printf '#!/bin/bash\nexit 0\n' >"$T/pf-brew/brew" && chmod +x "$T/pf-brew/brew"

# F1: install_hint picks the first available package manager, maps package names, falls back cleanly
pf_f1() {
    local h
    h=$(PATH="$T/pf-apt:$T/pf-brew:$T/nocl" bash -c ". '$TOOL_DIR/lib.sh'; install_hint jq") || fail "F1: install_hint failed"
    [ "$h" = "sudo apt install jq" ] || fail "F1: apt-get not picked first: $h"
    h=$(PATH="$T/pf-brew:$T/nocl" bash -c ". '$TOOL_DIR/lib.sh'; install_hint jq")
    [ "$h" = "brew install jq" ] || fail "F1: brew not picked: $h"
    h=$(PATH="$T/nocl" bash -c ". '$TOOL_DIR/lib.sh'; install_hint jq")
    [ "$h" = "install jq with your system's package manager" ] || fail "F1: no clean fallback: $h"
    h=$(PATH="$T/pf-apt:$T/nocl" bash -c ". '$TOOL_DIR/lib.sh'; install_hint \"\$(pkg_of bwrap)\"")
    [ "$h" = "sudo apt install bubblewrap" ] || fail "F1: bwrap not mapped to bubblewrap: $h"
}

# F2: missing jq – the message names the purpose and THIS system's install command (not a fixed list)
pf_f2() {
    b_project "$T/pf2" <<'EOF'
TEST_CMD='bash check.sh'
ALLOWED='^(checks\.txt|TASKS\.md)$'
EOF
    MAX_RUNS=1 PATH="$T/pf-apt:$T/nojq" "$TOOL_DIR/autopilot.sh" >"$T/pf2.txt" 2>&1 && fail "F2: autopilot.sh without jq exits 0"
    grep -q "jq not found" "$T/pf2.txt" && grep -q "Claude's answers" "$T/pf2.txt" &&
        grep -qF "sudo apt install jq" "$T/pf2.txt" || fail "F2: jq message lacks purpose or install command: $(cat "$T/pf2.txt")"
    MAX_RUNS=1 PATH="$T/pf-brew:$T/nojq" "$TOOL_DIR/autopilot.sh" >"$T/pf2b.txt" 2>&1 && fail "F2: autopilot.sh without jq exits 0 (brew)"
    grep -qF "brew install jq" "$T/pf2b.txt" && ! grep -q "apt install" "$T/pf2b.txt" ||
        fail "F2: jq message not specific to the detected package manager: $(cat "$T/pf2b.txt")"
}

# F3: missing tmux at `start` – purpose and this system's install command
pf_f3() {
    b_project "$T/pf3" <<'EOF'
TEST_CMD='bash check.sh'
ALLOWED='^(checks\.txt|TASKS\.md)$'
EOF
    PATH="$T/pf-apt:$T/nocl" "$TOOL_DIR/menu.sh" start >"$T/pf3.txt" 2>&1 && fail "F3: start without tmux exits 0"
    grep -q "tmux not found" "$T/pf3.txt" && grep -q "background" "$T/pf3.txt" &&
        grep -qF "sudo apt install tmux" "$T/pf3.txt" && ! grep -q "brew install" "$T/pf3.txt" ||
        fail "F3: tmux message lacks purpose or system-specific install command: $(cat "$T/pf3.txt")"
}

# F4: test command cannot run at the start – the message suggests an install command
pf_f4() {
    # exit 127: the first word of TEST_CMD becomes the suggestion
    b_project "$T/pf4" <<'EOF'
TEST_CMD='pf4-missing-tool-xyz -q'
ALLOWED='^(checks\.txt|TASKS\.md)$'
EOF
    MAX_RUNS=1 PATH="$T/pf-apt:$PATH" "$TOOL_DIR/autopilot.sh" >"$T/pf4.txt" 2>&1 && fail "F4: start with a missing test tool exits 0"
    grep -q "Test command cannot run (missing tool?)" "$T/pf4-conf/.autopilot/log/history.log" &&
        grep -qF "Try: sudo apt install pf4-missing-tool-xyz" "$T/pf4-conf/.autopilot/log/history.log" ||
        fail "F4: rc-127 start message without install suggestion: $(cat "$T/pf4-conf/.autopilot/log/history.log")"
    # "No module named X": python3-X plus a pip hint
    b_project "$T/pf4m" <<'EOF'
TEST_CMD='echo "No module named numpy"; exit 1'
ALLOWED='^(checks\.txt|TASKS\.md)$'
EOF
    MAX_RUNS=1 PATH="$T/pf-apt:$PATH" "$TOOL_DIR/autopilot.sh" >"$T/pf4m.txt" 2>&1 && fail "F4: start with a missing module exits 0"
    grep -qF "Try: sudo apt install python3-numpy (or: pip install numpy)" "$T/pf4m-conf/.autopilot/log/history.log" ||
        fail "F4: missing-module start message without install suggestion: $(cat "$T/pf4m-conf/.autopilot/log/history.log")"
}

# F5: the probe at `plan accept` also suggests an install command for a missing tool
pf_f5() {
    new_round; sample_project "$T/pf5p"
    git add -A && git commit -qm start || fail "F5: setup failed"
    printf "===CONFIG===\nTEST_CMD='pf5-missing-tool-xyz -q'\nDEMO_CMD='bash check.sh'\n===TASKS===\n- [ ] 1. [x] one. Done when a test passes.\n" >"$FAKE_DIR/setup.txt"
    "$TOOL_DIR/menu.sh" plan "$T/pf5p/plan.md" >/dev/null 2>&1 || fail "F5: plan failed"
    PATH="$T/pf-apt:$PATH" "$TOOL_DIR/menu.sh" plan accept >"$T/pf5.txt" 2>&1 || fail "F5: plan accept failed: $(tail -3 "$T/pf5.txt")"
    grep -qi "cannot run" "$T/pf5.txt" && grep -qF "Try: sudo apt install pf5-missing-tool-xyz" "$T/pf5.txt" ||
        fail "F5: probe warning without install suggestion: $(cat "$T/pf5.txt")"
}

# F6: `autopilot doctor` – required tools listed, exit 0 on a complete system, 1 with a hidden tool,
# install command for the missing one, git identity shown, trusted conf probed
pf_f6() {
    local c p
    mkdir -p "$T/pf-full"
    for c in "$T/nocl"/*; do ln -sf "$(readlink -f "$c")" "$T/pf-full/$(basename "$c")"; done
    printf '#!/bin/bash\n[ "$1" = --help ] && { printf "  --safe-mode\n  --effort\n  --max-budget-usd\n  --json-schema\n"; exit 0; }\necho "2.1.0 (stub)"\n' >"$T/pf-full/claude" && chmod +x "$T/pf-full/claude"
    printf '#!/bin/bash\necho "tmux 3.4"\n' >"$T/pf-full/tmux" && chmod +x "$T/pf-full/tmux"
    # Doctor runs outside a repo here: stub the git identity (CI runners have no global one)
    env -u AUTOPILOT_CONF GIT_COMMITTER_NAME=CI GIT_COMMITTER_EMAIL=ci@test XDG_CONFIG_HOME="$T/pf6-cfg" PATH="$T/pf-apt:$T/pf-full" \
        "$TOOL_DIR/menu.sh" doctor >"$T/pf6.txt" 2>&1 || fail "F6: doctor on a complete system exits non-zero: $(cat "$T/pf6.txt")"
    for c in claude git jq tmux; do grep -q " $c" "$T/pf6.txt" || fail "F6: doctor does not list $c: $(cat "$T/pf6.txt")"; done
    grep -qi "identity" "$T/pf6.txt" || fail "F6: doctor does not show the git identity: $(cat "$T/pf6.txt")"
    rm "$T/pf-full/jq"
    env -u AUTOPILOT_CONF GIT_COMMITTER_NAME=CI GIT_COMMITTER_EMAIL=ci@test XDG_CONFIG_HOME="$T/pf6-cfg" PATH="$T/pf-apt:$T/pf-full" \
        "$TOOL_DIR/menu.sh" doctor >"$T/pf6h.txt" 2>&1 && fail "F6: doctor with a hidden jq exits 0: $(cat "$T/pf6h.txt")"
    grep "jq" "$T/pf6h.txt" | grep -qF "sudo apt install jq" || fail "F6: doctor without jq lacks the install command: $(cat "$T/pf6h.txt")"
    ln -sf "$(readlink -f "$T/nocl/jq")" "$T/pf-full/jq"
    # with a trusted configuration: sandbox state and the test command probe
    b_project "$T/pf6p" <<'EOF'
TEST_CMD='bash check.sh'
ALLOWED='^(checks\.txt|TASKS\.md)$'
EOF
    PATH="$T/pf-apt:$T/pf-full" "$TOOL_DIR/menu.sh" doctor >"$T/pf6p.txt" 2>&1 || fail "F6: doctor with a trusted conf exits non-zero: $(cat "$T/pf6p.txt")"
    grep -q "no sandbox: bwrap is missing" "$T/pf6p.txt" && grep -q "green, 1 passed tests" "$T/pf6p.txt" ||
        fail "F6: doctor does not probe the trusted project's test command: $(cat "$T/pf6p.txt")"
}

# F7: doctor warns when the work directory lies below ~/.claude/ (Claude Code refuses every write there)
pf_f7() {
    mkdir -p "$T/pf7home/.claude/jobs"
    b_project "$T/pf7home/.claude/jobs/p" <<'EOF'
TEST_CMD='bash check.sh'
EOF
    HOME=$T/pf7home "$TOOL_DIR/menu.sh" doctor >"$T/pf7.txt" 2>&1
    grep -q "✘ WORKDIR .* lies below ~/.claude/: Claude Code refuses every write there" "$T/pf7.txt" || fail "F7: doctor does not warn about ~/.claude: $(cat "$T/pf7.txt")"
}

for pf in ${PART_F_ONLY:-f1 f2 f3 f4 f5 f6 f7}; do
    "pf_$pf"
    unset AUTOPILOT_CONF; cd "$T" || exit 1
done
unset pf
