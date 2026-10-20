# Sourced by test_autopilot.sh (same shell: $T, $TOOL_DIR, $FAKE_DIR, fail, new_round, sample_project, $tick).

# P8: setup copies the commented template (published, documents every default); without it: error, no success message
grep -qx 'autopilot.conf' "$TOOL_DIR/.gitignore" && fail "setup: .gitignore also ignores templates/autopilot.conf"
for k in $(sed -n '/^# Defaults/,/^\. "\$CONF"/s/^\([A-Z_]*\)=.*/\1/p' "$TOOL_DIR/common.sh"); do
    grep -qE "^#?$k=" "$TOOL_DIR/templates/autopilot.conf" || fail "setup: templates/autopilot.conf does not document $k"
done
mkdir -p "$T/su/tool" "$T/su/p" && cd "$T/su/p" || exit 1
"$TOOL_DIR/menu.sh" setup >"$T/su/out.txt" 2>&1 || fail "setup failed: $(cat "$T/su/out.txt")"
cmp -s autopilot.conf "$TOOL_DIR/templates/autopilot.conf" && bash -n autopilot.conf || fail "setup: autopilot.conf is not the template"
rm autopilot.conf && cp "$TOOL_DIR/menu.sh" "$TOOL_DIR/lib.sh" "$T/su/tool/"   # a tool without the template
"$T/su/tool/menu.sh" setup >"$T/su/out.txt" 2>&1 && fail "setup without a template exits 0"
grep -q "created" "$T/su/out.txt" && fail "setup without a template reports success: $(cat "$T/su/out.txt")"

# P4 (bytecode), P5 (count line in docs), P11 (umlaut file name), P15 (blocked tasks at the end), P16 (rules in the prompt)
new_round
sample_project "$T/pc"
printf -- '- [~] 0. [core] blocked before\n- [ ] 1. [core] one\n- [ ] 2. [core] two\n- [ ] 3. [core] three\n' >TASKS.md
echo 'import sys' >conftest.py   # imported by the test command: Python would write __pycache__/ into the project root
git add -A && git commit -qm start
mkdir -p "$T/pcc"
cat >"$T/pcc/autopilot.conf" <<EOF
WORKDIR=$T/pc
TEST_CMD='python3 -c "import conftest" && bash check.sh'
ALLOWED='^(checks\.txt|docs/|tool\.sh|sub/|TASKS\.md|BLOCKED\.md|DECISIONS\.md)'
notify() { echo "\$1 \$2" >>"$T/pcc/notify.log"; }
EOF
s=$FAKE_DIR/steps
echo "mkdir -p docs; echo x >docs/Prüfung.md; echo check >>checks.txt; $tick
[ \"\$PYTHONDONTWRITEBYTECODE\" = 1 ] && touch \"\$FAKE_DIR/nobytecode\""                   >"$s/1.sh"   # umlaut in a path
echo "echo 'pytest style: the test prints TESTS: 25' >docs/guide.md; echo check >>checks.txt; $tick" >"$s/2.sh"   # count line in a doc
echo "echo \"echo 'TESTS: 99'\" >tool.sh; echo check >>checks.txt; $tick"                    >"$s/3.sh"   # count line in code
echo "mkdir -p sub/__pycache__; touch sub/__pycache__/m.pyc sub/m.pyc; echo check >>checks.txt; $tick" >"$s/4.sh"   # bytecode left behind
printf 'VERDICT: ACCEPT\nVERDICT: ACCEPT\nVERDICT: ACCEPT\n' >"$FAKE_DIR/verdicts"
export AUTOPILOT_CONF="$T/pcc/autopilot.conf"
"$TOOL_DIR/menu.sh" trust "$AUTOPILOT_CONF" >/dev/null || fail "part c: trust failed"
"$TOOL_DIR/autopilot.sh" >"$T/pcc/out.txt" 2>&1   # exit code: the checks below name what went wrong
h=$T/pcc/.autopilot/log/history.log
grep -q "outside allowed paths: .*pyc" "$h" && fail "P4: bytecode counted as a change: $(grep -m1 'outside allowed' "$h")"
grep -q "Run 1 accepted" "$h" || fail "P11: file with umlaut not accepted: $(grep 'Run 1 rejected' "$h")"
git -c core.quotePath=false ls-files docs | grep -qx 'docs/Prüfung.md' || fail "P11: file with umlaut not committed"
grep -q "Run 2 accepted" "$h" || fail "P5: count line in a doc rejected: $(grep 'Run 2 rejected' "$h")"
grep -q "Run 3 rejected: new code contains the count line .*: echo 'TESTS: 99'" "$h" || fail "P5: count line in code not rejected with the line"
[ -e "$FAKE_DIR/nobytecode" ] && [ ! -e "$T/pc/__pycache__" ] || fail "P4: PYTHONDONTWRITEBYTECODE not set for tests and worker"
git ls-files | grep -q 'pyc' && fail "P4: bytecode committed: $(git ls-files | grep pyc)"
grep -qxF '__pycache__/' .git/info/exclude && grep -qxF '*.pyc' .git/info/exclude || fail "P4: bytecode not excluded from Git"
grep -q "Goal reached: all tasks done except 1 blocked" "$h" || fail "P15: blocked tasks not named at the end: $(tail -1 "$h")"
tail -1 "$T/pcc/notify.log" | grep -q '^warn Goal reached' || fail "P15: end with blocked tasks not announced as warn: $(tail -1 "$T/pcc/notify.log")"
grep -q "CLAUDE.md and" "$TOOL_DIR/templates/PROMPT.md" && fail "P16: PROMPT.md still points to a CLAUDE.md that is never created"
grep -q "Tests are never deleted, loosened or bypassed" "$FAKE_DIR/last-prompt" || fail "P16: rules missing in the worker prompt"

# P7: result in a work directory on the base branch: nothing to merge; own project folder: branch autopilot, merge it into main
"$TOOL_DIR/menu.sh" result | grep -q "directly on main: nothing to merge" || fail "P7: result on the base branch suggests a merge: $("$TOOL_DIR/menu.sh" result | tail -1)"
[ "$(git -C "$T/home/readme-autopilot" branch --show-current)" = autopilot ] || fail "P7: own project folder has no branch autopilot"
AUTOPILOT_CONF="$T/home/readme-autopilot/autopilot.conf" "$TOOL_DIR/menu.sh" result | grep -q "on main in the project:  git merge autopilot" ||
    fail "P7: result in the own project folder wrong: $(AUTOPILOT_CONF="$T/home/readme-autopilot/autopilot.conf" "$TOOL_DIR/menu.sh" result)"

# P17: shortened text counts characters, an umlaut at the edge stays whole
printf -- '- [ ] %sü tail\n' "$(printf 'a%.0s' $(seq 63))" >>TASKS.md
LC_ALL=C.UTF-8 "$TOOL_DIR/menu.sh" status | LC_ALL=C.UTF-8 grep -q '^Next: *a*ü$' || fail "P17: status cuts an umlaut in half"
grep -nE 'cut -c ?[0-9]+-[0-9]' "$TOOL_DIR/menu.sh" "$TOOL_DIR/plan.sh" && fail "P17: menu.sh/plan.sh still shorten text by bytes"
git checkout -q TASKS.md
unset AUTOPILOT_CONF
cd "$T" || exit 1
