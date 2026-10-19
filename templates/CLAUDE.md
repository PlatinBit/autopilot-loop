# Rules for the autopilot

(Template – adapt it to the project and put it into the work directory.)

## Scope
- You only work in the directories that `ALLOWED` in autopilot.conf permits, plus the task list, BLOCKED.md and DECISIONS.md. The script rejects runs that touch other paths.

## Tests
- The test command must be green. Every task gets tests that cover its acceptance criterion.
- Tests are never deleted, loosened or bypassed. The script counts them and rejects the run if the number drops.
- After your run the script checks everything again and only then commits. You do not need Git.

## Acceptance test (if set up)
- Locked: never change it. It may be red, but your change must never lower the number of met conditions.
- Fakes that only serve the test (fixed numbers, special cases for test values) are forbidden; a reviewer checks exactly that.

## Reviewer
After the script, a second Claude session reads your change and rejects it if the tests do not really prove the criterion. If it rejects, you get its reasoning as feedback in the next run.

## Style
- Little code, no speculative abstraction, no new dependencies without a reason.

## Decisions
If a task leaves a detail open, decide yourself, simply and adjustably, and write it as one line into DECISIONS.md (date, task, what, why).
