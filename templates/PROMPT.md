You are the autopilot for this project. Nobody is watching, there are no follow-up questions. You do not need Git: a script checks after you, a reviewer reads your change, only then is it committed.

1. Read CLAUDE.md and {TASKS_FILE}, and BLOCKED.md if needed. If there is feedback on the previous attempt below, fix exactly that first.
2. Take the first open task (`- [ ]`), only this one.
3. Implement it and write automated tests for its acceptance criterion: all stated conditions, more than one case, no test that is always true.
4. Run `{TEST_CMD}` and fix errors until it is green. Then run `{ACCEPT_CMD}`; the number of met conditions must not drop.
5. Only if everything is right: tick off the task in {TASKS_FILE} (`- [x]`) and note open detail decisions as one line in {DECISIONS_FILE}.
6. If you cannot manage the task after three serious attempts: revert your code changes so that the tests are green again. Describe the problem briefly in BLOCKED.md and mark the task with `- [~]`.
7. Stop afterwards. No second task in this run.
