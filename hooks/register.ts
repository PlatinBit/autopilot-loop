import type { Engine, Register } from 'claude-code'

// The last state the status poll saw (declared in types/index.d.ts), held by the host for this
// session: it survives hot reloads of this module, and a fresh session starts empty - so a reload
// can never fake a "finished" toast, at worst miss one.
const finishRef = { plugin: 'autopilot', key: 'finish' } as const

// All the work is done by menu.sh, which ships with the plugin (the repo is the plugin); this plugin asks questions
// in Claude Code's selection list and shows running projects in the status line. Which project is meant is found
// by menu.sh itself: autopilot.conf in the session directory or a folder above it.
async function autopilot($: Engine, args: readonly string[]): Promise<string> {
  const argv = [`${$.plugin.root}/menu.sh`, ...args]
  if (args[0] !== 'plan') {
    const r = await $.process.run(argv, { timeoutMs: 60_000 })
    return (r.stdout + r.stderr).trim()
  }
  // `plan` may call claude (CLAUDE_TIMEOUT, default 20 min), but process.run allows ten minutes at most:
  // spawn has no limit of its own, menu.sh ends after CLAUDE_TIMEOUT by itself.
  let out = ''
  for await (const { text } of $.process.spawn({ argv })) out += text
  return out.trim()
}

// $.ui.ask rejects when the person dismisses the question: that is a cancel, not an error.
const cancelled = new Error('cancelled')
const ask = ($: Engine, text: string, header: string, options: string[]) =>
  $.ui.ask(text, { header, options }).catch(() => { throw cancelled })

async function start($: Engine): Promise<string> {
  const ok = await ask($, 'Start the autopilot in the background? It stops by itself when the work is done or a cap in autopilot.conf is reached (MAX_RUNS, MAX_COST_USD).',
    'Start', ['Start', 'Cancel'])
  return ok === 'Start' ? autopilot($, ['start']) : 'Not started.'
}

// A draft (from a file or an idea) is set up, thrown away or kept for later.
async function decide($: Engine, draft: string): Promise<string> {
  if (!draft.includes('autopilot plan accept')) return draft
  const choice = await ask($, `${draft}\n\nSet it up like this?`, 'Draft', ['Set up', 'Throw away', 'Decide later'])
  if (choice === 'Set up') return autopilot($, ['plan', 'accept'])
  if (choice === 'Throw away') return autopilot($, ['plan', 'discard'])
  return 'Draft kept (view it: /autopilot-loop plan).'
}

// New project from a bare idea: free text under "Other"; `plan "<idea>"` writes ./<slug>-plan.md and drafts from it.
async function newIdea($: Engine): Promise<string> {
  const idea = await ask($, 'What should be built? One to three sentences (type them under "Other").', 'Idea',
    ['Enter the idea under "Other"', 'Cancel'])
  if (idea === 'Cancel') return 'Cancelled.'
  if (idea.startsWith('Enter the idea')) return 'Please type the idea under "Other": run /autopilot-loop again.'
  return decide($, await autopilot($, ['plan', idea]))
}

// New project: choose a plan file (suggestions from the session directory or your own path under "Other").
async function newProject($: Engine): Promise<string> {
  const r = await $.process.run(['bash', '-c', 'ls -1 *.md 2>/dev/null | head -3'])
  const files = r.stdout.split('\n').map(z => z.trim()).filter(Boolean)
  const options = files.length >= 2 ? files : [...files, 'Enter a path yourself (under "Other")']
  const file = await ask($, 'Which file describes what should be built? (own path: "Other")', 'Plan file', options)
  if (file.startsWith('Enter a path')) return 'Please type the path under "Other": run /autopilot-loop again.'
  return decide($, await autopilot($, ['plan', file]))
}

async function planner($: Engine): Promise<string> {
  const pending = await autopilot($, ['plan'])
  const has = pending.includes('autopilot plan accept')
  const choice = await ask($, has ? `${pending}\n\nWhat now?` : 'No draft and no planner suggestion. What now?', 'Planner',
    has ? ['Adopt it', 'Throw it away', 'New project from file', 'New project from an idea']
      : ['New project from file', 'New project from an idea'])
  switch (choice) {
    case 'Adopt it': return autopilot($, ['plan', 'accept'])
    case 'Throw it away': return autopilot($, ['plan', 'discard'])
    case 'New project from file': return newProject($)
    case 'New project from an idea': return newIdea($)
    default: return 'Back.'
  }
}

async function menu($: Engine): Promise<string> {
  const r = await $.process.run([`${$.plugin.root}/menu.sh`, 'status'], { timeoutMs: 60_000 })
  const status = (r.stdout + r.stderr).trim()
  if (r.exitCode === 3 || !status.startsWith('Status:')) {  // no project here
    const yes = await ask($, `${status}\n\nCreate a new project?`, 'Autopilot',
      ['New project from file', 'New project from an idea', 'Cancel'])
    if (yes === 'New project from file') return newProject($)
    if (yes === 'New project from an idea') return newIdea($)
    return 'Cancelled.'
  }
  const running = /^Status:\s+running/m.test(status)
  const head = status.split('\n\nLatest events:')[0]
  const options = running ? ['Stop after this run', 'Stop now', 'Full status']
    : ['Start', 'Handover: result and how to try it', 'Drafts, suggestions, new projects', 'Doctor: check requirements']
  const choice = await ask($, `${head}\n\nWhat would you like to do?`, 'Autopilot', options)
  switch (choice) {
    case 'Start': return start($)
    case 'Stop after this run': return autopilot($, ['stop'])
    case 'Stop now': {
      const sure = await ask($, 'Really stop now? The current run is discarded, accepted work stays.', 'Stop now', ['Yes, stop now', 'No'])
      return sure === 'Yes, stop now' ? autopilot($, ['stop', '--now']) : 'Keeps running.'
    }
    case 'Full status': return status
    case 'Handover: result and how to try it': return autopilot($, ['handover'])
    case 'Drafts, suggestions, new projects': return planner($)
    case 'Doctor: check requirements': return autopilot($, ['doctor'])
    default: return `Unknown choice: ${choice}`
  }
}

// Status line and finish toast: poll `menu.sh status --short` (every minute, and right after each
// /autopilot-loop command). It prints one line per project that ran: "Autopilot <name>: run …" while it
// runs, "Autopilot <name> ended: <outcome> - …" afterwards. Running lines show as the status line; a
// project the last poll saw running and this one sees ended gets one toast with its outcome, and a
// "finished" line that stays until the next session or its next start.
const nameOf = (line: string) => line.match(/^Autopilot (\S+?)( ended)?:/)?.[1] ?? ''
async function pollStatus($: Engine): Promise<void> {
  const r = await $.process.run([`${$.plugin.root}/menu.sh`, 'status', '--short'], { timeoutMs: 60_000 }).catch(() => null)
  if (r === null || r.exitCode !== 0) return  // could not ask: keep the last state, decide nothing
  const lines = r.stdout.split('\n').map(z => z.trim()).filter(z => z.startsWith('Autopilot '))
  const running = lines.filter(z => !/^Autopilot \S+ ended: /.test(z))
  const held = (await $.state.get(finishRef)).value ?? { running: '', done: '' }
  let done = held.done ? held.done.split('\n') : []
  for (const before of held.running ? held.running.split('\n') : []) {
    const name = nameOf(before)
    if (running.some(z => nameOf(z) === name)) continue
    const ended = lines.find(z => z.startsWith(`Autopilot ${name} ended: `))?.slice(`Autopilot ${name} ended: `.length) || 'finished - see the status'
    const text = `Autopilot ${name}: ${ended[0].toUpperCase()}${ended.slice(1)} - /autopilot-loop handover`
    done = [...done.filter(z => nameOf(z) !== name), text]
    $.ui.toast(text)
  }
  done = done.filter(z => !running.some(y => nameOf(y) === nameOf(z)))  // running again: its finished line goes
  await $.state.set(finishRef, { running: running.join('\n'), done: done.join('\n') })
  $.ui.status([...running, ...done].join(' | ') || undefined)
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    // Status line: while a project runs, its progress shows below the input (refreshed every minute).
    // Set up first, so a refused command registration below cannot take it down.
    const showStatus = () => void pollStatus($).catch(() => {})
    showStatus()
    $.clock.every(60_000, showStatus)
    await $.command.register({
      name: 'autopilot-loop',
      description: 'Autopilot: plan a project from a file or an idea, start, status, stop, handover, doctor',
      argumentHint: '[plan <file>|plan "<idea>"|plan --spec "<idea>"|plan [accept|discard]|start|status [--short|--watch]|stop [--now]|handover [--export-lessons]|doctor|trust [file]|help]',
    }).catch(err => $.ui.log(`autopilot-loop: /autopilot-loop not registered: ${err instanceof Error ? err.message : err}`))
    return next(e)
  })

  // Without an argument: selection menu; with an argument straight to the `autopilot` command (e.g. "/autopilot-loop status").
  on('command.run', { command: 'autopilot-loop' }, async ($, e) => {
    try {
      const args = e.args.trim()
      const unquote = (s: string) => /^(".*"|'.*')$/.test(s) ? s.slice(1, -1) : s
      let text: string
      if (args.startsWith('plan --spec ')) {  // the idea stays one argument after --spec
        text = await autopilot($, ['plan', '--spec', unquote(args.slice(12).trim())])
      } else if (args.startsWith('plan ')) {  // a path or an idea, spaces included, stays one argument
        text = await autopilot($, ['plan', unquote(args.slice(5).trim())])
      } else {
        const argv = args.split(/\s+/)
        // --watch repeats until Ctrl+C, which a slash command cannot send: one round
        if (argv[0] === 'status' && argv[1] === '--watch') argv.splice(2, argv.length, '--once')
        text = args ? await autopilot($, argv) : await menu($)
      }
      await pollStatus($).catch(() => {})  // refresh the status line right away (start, stop …)
      return { text }
    } catch (err) {
      return { text: err === cancelled ? 'Autopilot menu closed.' : `Autopilot error: ${err instanceof Error ? err.message : err}` }
    }
  }).catch(() => ({ text: 'Autopilot error: the command did not finish in time.' }))
}
