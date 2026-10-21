import type { Engine, Register } from 'claude-code'

// The last state the status poll saw (declared in types/index.d.ts), held by the host for this
// session: it survives hot reloads of this module, and a fresh session starts empty - so a reload
// can never fake a "finished" toast, at worst miss one.
const finishRef = { plugin: 'autopilot', key: 'finish' } as const

// All the work is done by menu.sh, which ships with the plugin (the repo is the plugin); this plugin asks questions
// in Claude Code's selection list and shows running projects in the status line. Which project is meant is found
// by menu.sh itself: ./autopilot.conf in the session directory, otherwise the most recently set up project.
async function autopilot($: Engine, args: readonly string[]): Promise<string> {
  const argv = [`${$.plugin.root}/menu.sh`, ...args]
  if (!['plan', 'propose', 'report'].includes(args[0])) {
    const r = await $.process.run(argv, { timeoutMs: 60_000 })
    return (r.stdout + r.stderr).trim()
  }
  // These may call claude (CLAUDE_TIMEOUT, default 20 min), but process.run allows ten minutes at most:
  // spawn has no limit of its own, menu.sh ends after CLAUDE_TIMEOUT by itself.
  let out = ''
  for await (const { text } of $.process.spawn({ argv })) out += text
  return out.trim()
}

const number = (answer: string) => answer.match(/\d+/)?.[0]
const firstWord = (answer: string) => answer.split(' ')[0].toLowerCase()
// $.ui.ask rejects when the person dismisses the question: that is a cancel, not an error.
const cancelled = new Error('cancelled')
const ask = ($: Engine, text: string, header: string, options: string[]) =>
  $.ui.ask(text, { header, options }).catch(() => { throw cancelled })

async function start($: Engine, status: string): Promise<string> {
  // `menu.sh status` prints "Demo: none" when neither DEMO_CMD nor SMOKE_TEST_CMD is set
  const noDemo = /^Demo:\s+none/m.test(status) ? '\n\nNo demo configured (DEMO_CMD or SMOKE_TEST_CMD): the result can never be reported as delivered.' : ''
  const n = number(await ask($, 'How many runs at most (one task per run)?', 'Runs', ['5 (Recommended)', '10', '20', '30']))
  if (!n) return 'Cancelled: no number chosen.'
  const planner = firstWord(await ask($, 'Which model should plan (a brief for every task, new tasks)?', 'Planner',
    ['opus (Recommended, strongest model)', 'sonnet (cheaper)']))
  const worker = firstWord(await ask($, 'Which model should build (write the code)?', 'Builder',
    ['opus (strongest, most expensive)', 'sonnet (cheaper, gets a brief from the planner)', 'haiku (cheapest, for simple tasks)']))
  const reviewer = firstWord(await ask($, 'Which model should review every task?', 'Reviewer',
    ['sonnet (Recommended, balanced)', 'opus (more thorough, more expensive)', 'haiku (cheap, less strict)']))
  const rejections = number(await ask($, 'Stop after how many rejections in a row?', 'Brake', ['3 (Recommended)', '2', '5']))
  if (!rejections) return 'Cancelled: no number chosen.'
  const ok = await ask($, `Start with ${n} runs, planner ${planner}, builder ${worker}, reviewer ${reviewer}, stop after ${rejections} rejections in a row?${noDemo}`,
    'Confirm', ['Start', 'Cancel'])
  return ok === 'Start' ? autopilot($, ['start', n, reviewer, rejections, worker, planner]) : 'Not started.'
}

// New project from a bare idea: free text under "Other"; `plan idea` writes ./<slug>-plan.md for review.
async function newIdea($: Engine): Promise<string> {
  const idea = await ask($, 'What should be built? One to three sentences (type them under "Other").', 'Idea',
    ['Enter the idea under "Other"', 'Cancel'])
  if (idea === 'Cancel') return 'Cancelled.'
  if (idea.startsWith('Enter the idea')) return 'Please type the idea under "Other": run /autopilot-loop again.'
  return autopilot($, ['plan', 'idea', idea])
}

// New project: choose a plan file (suggestions from the session directory or your own path under "Other").
async function newProject($: Engine): Promise<string> {
  const r = await $.process.run(['bash', '-c', 'ls -1 *.md 2>/dev/null | head -3'])
  const files = r.stdout.split('\n').map(z => z.trim()).filter(Boolean)
  const options = files.length >= 2 ? files : [...files, 'Enter a path yourself (under "Other")']
  const file = await ask($, 'Which file describes what should be built? (own path: "Other")', 'Plan file', options)
  if (file.startsWith('Enter a path')) return 'Please type the path under "Other": run /autopilot-loop again.'
  const draft = await autopilot($, ['plan', file])
  if (!draft.includes('Set up: autopilot plan accept')) return draft
  // Without a demo command `plan accept` refuses; the owner may still set up without one (never "delivered").
  // A proposed acceptance test is dropped unless the owner adopts it.
  const noDemo = draft.includes('No demo command (DEMO_CMD)')
  const setUp = noDemo ? 'Set up without demo (never reported as delivered)' : 'Set up'
  const yes = await ask($, `${draft}\n\nSet it up like this?`, 'Draft', [setUp, 'Discard'])
  if (yes !== setUp) return 'Draft not adopted (view it: autopilot plan show).'
  const flags = noDemo ? ['--no-demo'] : []
  if (draft.includes('proposes an acceptance test')) {
    const adopt = await ask($, 'Adopt the proposed acceptance test too? Its files are locked for the worker; approve them before the first start.', 'Acceptance test', ['Adopt', 'Drop'])
    if (adopt === 'Adopt') flags.push('--with-accept')
  }
  return autopilot($, ['plan', 'accept', ...flags])
}

async function planner($: Engine): Promise<string> {
  const suggestion = await autopilot($, ['suggestion'])
  const has = suggestion.startsWith('Planner suggestion')
  const choice = await ask($, has ? `${suggestion}\n\nWhat now?` : 'No suggestion available. What now?', 'Planner',
    has ? ['Adopt suggestion', 'Discard suggestion', 'New project from file', 'New project from an idea']
      : ['Let the planner propose tasks', 'New project from file', 'New project from an idea'])
  switch (choice) {
    case 'Adopt suggestion': return autopilot($, ['suggestion', 'accept'])
    case 'Discard suggestion': return autopilot($, ['suggestion', 'discard'])
    case 'Let the planner propose tasks': return autopilot($, ['propose'])
    case 'New project from file': return newProject($)
    case 'New project from an idea': return newIdea($)
    default: return 'Back.'
  }
}

// $.ui.ask takes at most four options, so the rest is two pages.
async function more($: Engine): Promise<string> {
  const choice = await ask($, 'What would you like to see?', 'More', ['Handover: result and how to try it', 'View result', 'Costs and chart', 'More …'])
  switch (choice) {
    case 'Handover: result and how to try it': return autopilot($, ['handover'])
    case 'View result': return autopilot($, ['result'])
    case 'Costs and chart': return `${await autopilot($, ['costs'])}\n\nChart: ${await autopilot($, ['chart'])}`
    case 'More …': return evenMore($)
    default: return `Unknown choice: ${choice}`
  }
}

async function evenMore($: Engine): Promise<string> {
  const choice = await ask($, 'What would you like to see?', 'More', ['Read decisions', 'Report now', 'Doctor: check requirements'])
  switch (choice) {
    case 'Read decisions': return autopilot($, ['notes'])
    case 'Report now': return autopilot($, ['report'])
    case 'Doctor: check requirements': return autopilot($, ['doctor'])
    default: return `Unknown choice: ${choice}`
  }
}

async function menu($: Engine): Promise<string> {
  const r = await $.process.run([`${$.plugin.root}/menu.sh`, 'status'], { timeoutMs: 60_000 })
  const status = (r.stdout + r.stderr).trim()
  if (r.exitCode === 4 || status.includes('autopilot trust')) return status  // conf not confirmed yet: show the trust message
  if (r.exitCode === 3 || !status.startsWith('Status:')) {  // no project yet
    const yes = await ask($, `${status}\n\nCreate a new project?`, 'Autopilot',
      ['New project from file', 'New project from an idea', 'Cancel'])
    if (yes === 'New project from file') return newProject($)
    if (yes === 'New project from an idea') return newIdea($)
    return 'Cancelled.'
  }
  const running = /^Status:\s+running/m.test(status)
  const waiting = status.includes('WAITING for your OK')
  const approved = !status.includes('NOT approved')
  const head = status.split('\n').filter(z => /^(Status|Acceptance|Demo|Plan|Tasks|Next|Suggestion):/.test(z)).join('\n')
  const options = waiting ? ['Continue (supervised OK)', 'Status and grades', 'Stop gently', 'More …']
    : running ? ['Status and grades', 'Stop gently', 'Abort now', 'More …']
      : approved ? ['Start', 'Status and grades', 'Planner and new projects', 'More …']
        : ['Approve acceptance test', 'Status and grades', 'Planner and new projects', 'More …']
  const choice = await ask($, `${head}\n\nWhat would you like to do?`, 'Autopilot', options)

  switch (choice) {
    case 'Start': return start($, status)
    case 'Continue (supervised OK)': return autopilot($, ['continue'])
    case 'Status and grades': return `${status}\n\nGrades:\n${await autopilot($, ['grades'])}`
    case 'Stop gently': return autopilot($, ['stop'])
    case 'Abort now': {
      const sure = await ask($, 'Really abort now? The current run is discarded, accepted work stays.', 'Abort', ['Yes, abort', 'No'])
      return sure === 'Yes, abort' ? autopilot($, ['abort']) : 'Keeps running.'
    }
    case 'Approve acceptance test': {
      const conditions = await autopilot($, ['conditions'])
      const yes = await ask($, `Goal of the project:\n${conditions}\n\nApprove like this? Afterwards the autopilot may no longer change the test.`, 'Approval', ['Yes, approve', 'No'])
      return yes === 'Yes, approve' ? autopilot($, ['approve']) : 'Not approved.'
    }
    case 'Planner and new projects': return planner($)
    case 'More …': return more($)
    default: return `Unknown choice: ${choice}`
  }
}

// Status line and finish toast: poll `menu.sh status --short` (every minute, and right after each
// /autopilot-loop command). A running project shows as the status line; when the last poll saw it
// running and this one does not, the run just finished: one toast with `menu.sh summary --short`
// (outcome first: "delivered - …" or "not delivered (reason) - …"), and a "finished" line that stays
// until the next session or the next start.
async function pollStatus($: Engine): Promise<void> {
  const r = await $.process.run([`${$.plugin.root}/menu.sh`, 'status', '--short'], { timeoutMs: 60_000 }).catch(() => null)
  // Could not ask, or status failed (exit 4 = conf not trusted, e.g. just edited; any other error): keep the last state, decide nothing.
  if (r === null || r.exitCode !== 0) return
  const line = (r.stdout + r.stderr).trim()
  const held = (await $.state.get(finishRef)).value ?? { running: '', done: '' }
  if (line.startsWith('Autopilot ')) {
    if (held.running !== line || held.done) await $.state.set(finishRef, { running: line, done: '' })
    $.ui.status(line)
  } else if (held.running) {  // ran at the last poll, not any more: it finished
    const name = held.running.match(/^Autopilot (.*?):/)?.[1] ?? ''
    const result = (await autopilot($, ['summary', '--short']).catch(() => '')) || 'see the summary'
    const done = `Autopilot ${name}: ${result[0].toUpperCase()}${result.slice(1)} - /autopilot-loop handover`
    await $.state.set(finishRef, { running: '', done })
    $.ui.toast(done)
    $.ui.status(done)
  } else {
    $.ui.status(held.done || undefined)  // keep "finished ..." until the next session or start
  }
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
      description: 'Autopilot menu: project from a plan file, start, stop, status, handover, planner, costs',
      argumentHint: '[status|summary|handover|doctor|stop|continue|trust <file>|plan <file>|plan idea "<idea>"|plan accept [--no-demo] [--with-accept]|start <runs> [reviewer] [max-rejections] [worker] [planner]]',
    }).catch(err => $.ui.log(`autopilot-loop: /autopilot-loop not registered: ${err instanceof Error ? err.message : err}`))
    return next(e)
  })

  // Without an argument: selection menu; with an argument straight to the `autopilot` command (e.g. "/autopilot-loop status").
  on('command.run', { command: 'autopilot-loop' }, async ($, e) => {
    try {
      const args = e.args.trim()
      let text: string
      if (args.startsWith('plan idea ')) {
        let idea = args.slice(10).trim()
        if (/^(".*"|'.*')$/.test(idea)) idea = idea.slice(1, -1)
        text = await autopilot($, ['plan', 'idea', idea])
      } else if (args.startsWith('plan ')) {
        text = await autopilot($, ['plan', args.slice(5).trim()])
      } else {
        text = args ? await autopilot($, args.split(/\s+/)) : await menu($)
      }
      await pollStatus($).catch(() => {})  // refresh the status line right away (start, stop, abort …)
      return { text }
    } catch (err) {
      return { text: err === cancelled ? 'Autopilot menu closed.' : `Autopilot error: ${err instanceof Error ? err.message : err}` }
    }
  }).catch(() => ({ text: 'Autopilot error: the command did not finish in time.' }))
}
