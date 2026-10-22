<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.svg">
    <img src="assets/logo-light.svg" width="100%" alt="autopilot-loop: plan, build, verify, commit - until done">
  </picture>
</p>

<p align="center">
  <a href="https://github.com/PlatinBit/autopilot-loop/actions/workflows/test.yml"><img src="https://github.com/PlatinBit/autopilot-loop/actions/workflows/test.yml/badge.svg" alt="Self-test"></a>
  <img src="https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fraw.githubusercontent.com%2FPlatinBit%2Fautopilot-loop%2Fmain%2F.claude-plugin%2Fplugin.json&query=%24.version&label=version" alt="Version">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/Claude%20Code-plugin-8b5cf6" alt="Claude Code plugin">
</p>

# autopilot-loop

**Give [Claude Code](https://claude.com/claude-code) a plan or an idea and it builds it task by task on its own – and only calls it "delivered" when your demo, a final review and a fresh checkout all pass.**

<p align="center"><img src="assets/demo.gif" alt="autopilot-loop in Claude Code: plan, accept, start, delivered, handover" width="100%"></p>

- **A shell script checks, not the model:** tests green, test count never drops, only allowed paths touched, locked files untouched. Only the script commits. [Safeguards](docs/REFERENCE.md#safeguards)
- **A read-only reviewer with a veto:** a second Claude reads diff and test output; a rejection resets the run and its reason goes into the next attempt. [How it works](docs/REFERENCE.md#how-it-works)
- **"Delivered" is earned:** `DEMO_CMD` exits 0, the final review finds nothing, tests and demo pass in a fresh checkout, then `main` is fast-forwarded and `HANDOVER.md` explains how to try it. [The end](docs/REFERENCE.md#the-end-final-review-fresh-checkout-merge)
- **Journal and lessons:** every agent leaves a note; the planner condenses them into at most 15 lessons for later prompts. [Journal and lessons](docs/REFERENCE.md#journal-and-lessons)
- **Cost under control:** caps per start and per call, model presets, effort per role, every call in `costs.csv`. [Configuration](docs/REFERENCE.md#configuration)

## What a run looks like

A real run in Claude Code, `history.log` shortened:

```text
2026-10-22 21:46:35 Start: 0 tests green, at most 50 runs or 1.89 USD, models cheap (planner sonnet, worker haiku, reviewer sonnet), sandbox on
2026-10-22 21:47:04 Run 1 accepted: [x] 1. Test scaffolding and counting function. Create `tests/__init__.py`,… | Tests 0 -> 4 | worker 0.0044 USD
2026-10-22 21:47:53 Run 2 accepted: [x] 2. (after 1) CLI for one file. `mdcount.py` gets `main(argv: list[str] | None =… | Tests 4 -> 7 | worker 0.0077 USD
2026-10-22 21:48:46 Run 3 rejected: no task ticked off or blocked (rc 0)
2026-10-22 21:49:28 Run 4 accepted: [x] 3. (after 2) Several files and the total line. With 2 or more paths, a final line… | Tests 7 -> 9 | worker 0.0052 USD
2026-10-22 21:51:48 Final review (round 1): OK
2026-10-22 21:51:48 Milestone 1 done: the planner drafts the tasks of Milestone 2 …
[…]
2026-10-22 21:54:33 Run 11 accepted: [x] 10. (after 9) End to end. Done when `bash demo.sh` exits 0 and prints the counts… | Tests 19 -> 19 | worker 0.0041 USD
2026-10-22 21:54:48 Final review (round 1): OK
2026-10-22 21:54:48 Fresh checkout: tests and demo green
2026-10-22 21:54:48 Merged into main (fast-forward).
```

Run 3 was rejected and redone. The final review checked each milestone; after a fresh-checkout run the result was merged into `main`. The 10-task project cost 2.0 USD with `MODELS=cheap`, planning included.

## Quick start

1. **Install** – in a Claude Code session:
   ```
   /plugin marketplace add PlatinBit/autopilot-loop
   /plugin install autopilot@autopilot-loop
   ```
2. **Plan** – Claude drafts tasks, test and demo command; read the draft, then accept it:
   ```
   /autopilot-loop plan A CLI that counts words in Markdown files
   /autopilot-loop plan accept
   ```
3. **Start** – runs in the background until delivered, not delivered or a cap is hit:
   ```
   /autopilot-loop start
   ```

Needs Linux or WSL, Bash 4.4+, `git`, `tmux`, `jq` and Claude Code 2.1+; `autopilot doctor` checks it. The terminal command `autopilot` works without Claude Code: [Installation](docs/REFERENCE.md#installation).

## How it works

```mermaid
flowchart LR
  P([Plan or idea]) --> W[Worker<br/>one task]
  W --> S{Script<br/>checks}
  S -- fail --> W
  S --> R{Reviewer<br/>read-only}
  R -- reject --> W
  R --> C[Commit]
  C -- next task --> W
  C --> E{Demo, final review,<br/>fresh checkout}
  E -- issues --> W
  E --> D([Delivered:<br/>merge + handover])
```

- **The worker** (Claude) does one small task per run, with a fresh context and no Git access.
- **A shell script** checks the result with hard rules; anything that fails is reset, and the reason goes into the next attempt.
- **The reviewer** (a second Claude, read-only tools) rejects weak tests and fakes; only then the script commits.
- **At the end** the script runs the demo, a final review of the whole change and tests and demo in a fresh checkout, then merges and writes a handover. Otherwise the outcome is "not delivered".
- **Large plans** go milestone by milestone; the planner drafts the next one's tasks itself.
- **Test and demo commands** run in a bubblewrap sandbox; the worker's own Bash calls only through the bundled `sandbox-run`. It is not a security boundary: [Security](docs/REFERENCE.md#security).

Full flowchart and details: [How it works](docs/REFERENCE.md#how-it-works).

## Commands

In Claude Code as `/autopilot-loop <command>`, in the terminal as `autopilot <command>`:

| No. | Command | Effect |
|---|---|---|
| 1 | `plan <file>` / `plan "<idea>"` | Claude drafts tasks, test and demo command |
| 2 | `plan accept` | adopts the draft and sets up the work branch |
| 3 | `start` | runs the loop in the background |
| 4 | `status` | progress, outcome, tests, cost |
| 5 | `stop [--now]` | stop after the current run, or now |
| 6 | `handover` | what was built, how to try it, the proof |

All commands and settings: [Commands](docs/REFERENCE.md#commands), [Configuration](docs/REFERENCE.md#configuration). Full reference: [docs/REFERENCE.md](docs/REFERENCE.md).

## Status

A hobby project. Tested on Linux (the self-test runs in CI on Ubuntu); macOS is untested. `PARALLEL` > 1 and `MERGE=pr` are experimental. [Issues](https://github.com/PlatinBit/autopilot-loop/issues) and reports from real runs are welcome.

License: [MIT](LICENSE).
