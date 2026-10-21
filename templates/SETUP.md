You are setting up an autopilot for this project. Below is a plan file describing what should be built. Another Claude will then implement it task by task, each time with a fresh context; after every task a script checks automatically whether the test command is green and whether the number of passed tests has risen. At the end the script runs the demo command: only if it exits 0 is the result reported as delivered.

To do this, read the plan and look at the project (language, build system, existing tests). Change nothing.

Only these settings are adopted, each at most once: TEST_CMD, TEST_COUNT_REGEX or TEST_COUNT_CMD, TEST_EMPTY_RC, WORKER_TOOLS, DEMO_CMD, TRY_IT and optionally ALLOWED (only if the plan limits where the worker may work; without it everything except the files that control the test command is allowed) and FORBIDDEN_CONTENT='<regular expression for content new code must never contain>'. An acceptance test (ACCEPT_CMD, ACCEPT_FILES, ACCEPT_REGEX): name one only if the project already contains a suitable test of the overall goal that prints a count like "ACCEPT: 3 of 10"; it is adopted only if its files exist, and they are locked for the worker, so never name files that do not exist yet. Every other line is discarded.

Answer in exactly this format and with nothing else after the first marker:

===CONFIG===
TEST_CMD='<one command that builds in the project directory and runs all tests, e.g. npm test, pytest -q, ./gradlew test, cargo test>'
TEST_COUNT_REGEX='<regular expression (Bash, extended) whose first group reads the number of passed tests from the output, e.g. ([0-9]+) passed>'
TEST_EMPTY_RC=<only if the test tool has an exit code that means "no tests yet", e.g. 5 for pytest – omit the line otherwise>
ALLOWED='<optional, only if the plan limits it: regular expression on file paths relative to the project that the worker may change, e.g. ^(src/|tests/) – omit the line otherwise>'
WORKER_TOOLS=(Read Edit Write Glob Grep 'Bash(<test command without arguments>:*)')
DEMO_CMD='<one command that starts or uses the finished result the way the owner would, from the plan's "Deliverable" (or "What exists at the end") section; exit 0 = it works, e.g. python app.py --help, ./bin/tool examples/a.md, npm start -- --check. No interactive command, no server that never exits>'
TRY_IT='<one or two sentences on how the owner tries the result by hand, with paths relative to the project folder (the handover names that folder), e.g. In the project folder run python app.py, open http://localhost:8000 and upload a file>'

(Instead of TEST_COUNT_REGEX you may write TEST_COUNT_CMD='<command>': it gets the output of the test command on stdin and prints only the number – for tools without a summary line. Proven values:
 pytest: TEST_CMD='pytest -q', TEST_COUNT_REGEX='([0-9]+) passed', TEST_EMPTY_RC=5 (pytest exits with 5 while there are no tests yet) · Jest/Vitest: TEST_COUNT_REGEX='Tests:? +([0-9]+) passed' ·
 Go: TEST_CMD='go test -v ./...', TEST_COUNT_CMD='grep -c -- "--- PASS"' ·
 Rust: TEST_CMD='cargo test', TEST_COUNT_CMD='grep -o "[0-9]* passed" | awk "{s+=\$1} END {print s}"' ·
 Maven: TEST_COUNT_REGEX='Tests run: ([0-9]+)' · .NET: TEST_COUNT_REGEX='Passed: +([0-9]+)' · PHPUnit: TEST_COUNT_REGEX='OK \(([0-9]+) tests?' ·
 RSpec: TEST_COUNT_REGEX='([0-9]+) examples?, 0 failures' ·
 Gradle/JUnit: TEST_CMD='./gradlew test', TEST_COUNT_CMD='cat build/test-results/test/*.xml | grep -c "<testcase"')
===TASKS===
# Tasks: <title of the project>

<two to five sentences with the most important rules for the worker: language, style, what must not be touched>

- [ ] 1. <small task>. Done when <automatically checkable criterion that a test can prove>.
- [ ] 2. …
- [ ] <last>. End to end: <wire the pieces together so that the deliverable works as a whole>. Done when `<DEMO_CMD>` exits 0 and prints <expected output>.

Rules for the tasks:
- One task per sensible, checkable step: every task can be implemented in at most 30 minutes and proven by new automated tests. As a guide, 1 to 3 tasks per milestone of the plan.
- The order builds up step by step; if needed, the first tasks create the test scaffolding so that the test command delivers a number at all.
- Every task ends with "Done when …" and names measurable conditions (inputs, expected results, limits), no feelings.
- The last task is always the end-to-end one above: the demo command, run like the owner would, exits 0 with the expected output. Wiring the parts together (entry point, start-up, integration) is checkable and belongs in the list: a list of unit-tested parts that nobody ever starts as a whole is not finished.
- Only look, feel and usability, which no program can check, stay out of the list; mention them in one sentence under the rules as "Checked by a human".
- The plan file itself is never changed (it is locked).
- If there are no tests and no test command yet, choose the usual test tool of the language and let task 1 set it up; TEST_CMD must already run before task 1 (it may report 0 tests then).
