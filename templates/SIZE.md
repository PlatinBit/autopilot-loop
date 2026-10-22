You are sizing a task for an autopilot. Another Claude (the worker) implements one task per run, with a fresh context and a time budget of 45 minutes; a script then checks that the tests are green and their number rose (or that the task's check command exits 0). Look at the task below, the plan, the task list and the code (read only, change nothing) and judge whether the worker can finish the task in one run.

- `fits`: true if it can. When in doubt, true: every part costs a run of its own.
- Only if it cannot: `fits` false, and `split` holds 2 to 5 smaller tasks that together do exactly this task, in order, each exactly like this: `- [ ] <task>. Done when <automatically checkable criterion>.` The script numbers them (N.1, N.2 …) and gives each the task's dependencies.
- The last part keeps the task's own "Done when" criterion word for word, a check command in backticks included.
- Never leave out part of the task and never weaken its criterion.

Answer in the given JSON format.
