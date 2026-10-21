You are turning a rough idea into a plan file for an autopilot. Below is the idea, one to three sentences. Write a short plan document that a later `autopilot plan` run reads to draft a task list, a test command, a demo command and allowed paths. You may look at the current directory (read only, change nothing); mostly the plan comes from the idea itself.

The document, in Markdown:
- Title and goal: what should be built, in two or three sentences.
- Deliverable (required): what the owner holds in their hands at the end (the files, commands or behaviour they can see and try), how they try it out by hand in one or two sentences, and the one command that proves it works: it starts or uses the finished result the way the owner would and exits 0 only if it works (e.g. `python app.py --help`, `./bin/tool example.md`, `npm start -- --check`). Write it as `Demo: <command>`. This command later becomes DEMO_CMD, and the run counts as delivered only when it passes.
- Constraints: language and tools (pick common, boring ones if the idea does not say), what is out of scope.
- Milestones: 5 to 15, numbered, small and building on each other, each with a verifiable criterion ("works when ...") that an automated test can prove. The last milestone is always end to end: the demo command exits 0 and prints the expected output.

Keep it to about one page, concrete and measurable, no feelings. Output only the document, nothing before or after it.
