import type { Engine, Register } from 'claude-code'

// All the work is done by menu.sh, which ships with the plugin (the repo is the plugin); this plugin asks questions
// in Claude Code's selection list and shows running projects in the status line. Which project is meant is found
// by menu.sh itself: ./autopilot.conf in the session directory, otherwise the most recently set up project.
async function autopilot($: Engine, args: readonly string[], timeoutMs = 60_000): Promise<string> {
  const r = await $.process.run([`${$.plugin.root}/menu.sh`, ...args], { timeoutMs })
  return (r.stdout + r.stderr).trim()
}

const number = (answer: string) => answer.match(/\d+/)?.[0]
const firstWord = (answer: string) => answer.split(' ')[0].toLowerCase()
const ask = ($: Engine, text: string, header: string, options: string[]) => $.ui.ask(text, { header, options })

async function start($: Engine): Promise<string> {
  const n = number(await ask($, 'How many runs at most (one task per run)?', 'Runs', ['5 (Recommended)', '10', '20', '30']))
  if (!n) return 'Cancelled: no number chosen.'
  const worker = firstWord(await ask($, 'Which model should implement the tasks (write the code)?', 'Worker',
    ['opus (Recommended, strongest model)', 'sonnet (cheaper, faster)']))
  const reviewer = firstWord(await ask($, 'Which model should review every task?', 'Reviewer',
    ['sonnet (Recommended, balanced)', 'opus (more thorough, more expensive)', 'haiku (cheap, less strict)']))
  const rejections = number(await ask($, 'Stop after how many rejections in a row?', 'Brake', ['3 (Recommended)', '2', '5']))
  if (!rejections) return 'Cancelled: no number chosen.'
  const ok = await ask($, `Start with ${n} runs, worker ${worker}, reviewer ${reviewer}, stop after ${rejections} rejections in a row?`,
    'Confirm', ['Start', 'Cancel'])
  return ok === 'Start' ? autopilot($, ['start', n, reviewer, rejections, worker]) : 'Not started.'
}

// New project: choose a plan file (suggestions from the session directory or your own path under "Other").
async function newProject($: Engine): Promise<string> {
  const r = await $.process.run(['bash', '-c', 'ls -1 *.md 2>/dev/null | head -3'])
  const files = r.stdout.split('\n').map(z => z.trim()).filter(Boolean)
  const options = files.length >= 2 ? files : [...files, 'Enter a path yourself (under "Other")']
  const file = await ask($, 'Which file describes what should be built? (own path: "Other")', 'Plan file', options)
  if (file.startsWith('Enter a path')) return 'Please type the path under "Other": run /autopilot again.'
  const draft = await autopilot($, ['plan', file], 600_000)
  if (!draft.includes('Set up: autopilot plan accept')) return draft
  const yes = await ask($, `${draft}\n\nSet it up like this?`, 'Draft', ['Set up', 'Discard'])
  return yes === 'Set up' ? autopilot($, ['plan', 'accept']) : 'Draft not adopted (view it: autopilot plan show).'
}

async function planner($: Engine): Promise<string> {
  const suggestion = await autopilot($, ['suggestion'])
  const has = suggestion.startsWith('Planner suggestion')
  const choice = await ask($, has ? `${suggestion}\n\nWhat now?` : 'No suggestion available. What now?', 'Planner',
    has ? ['Adopt suggestion', 'Discard suggestion', 'New project from file']
      : ['Let the planner propose tasks', 'New project from file', 'Back'])
  switch (choice) {
    case 'Adopt suggestion': return autopilot($, ['suggestion', 'accept'])
    case 'Discard suggestion': return autopilot($, ['suggestion', 'discard'])
    case 'Let the planner propose tasks': return autopilot($, ['propose'], 600_000)
    case 'New project from file': return newProject($)
    default: return 'Back.'
  }
}

async function more($: Engine): Promise<string> {
  const choice = await ask($, 'What would you like to see?', 'More', ['Costs and chart', 'Read decisions', 'View result', 'Report now'])
  switch (choice) {
    case 'Costs and chart': return `${await autopilot($, ['costs'])}\n\nChart: ${await autopilot($, ['chart'])}`
    case 'Read decisions': return autopilot($, ['notes'])
    case 'View result': return autopilot($, ['result'])
    case 'Report now': return autopilot($, ['report'], 300_000)
    default: return `Unknown choice: ${choice}`
  }
}

async function menu($: Engine): Promise<string> {
  const status = await autopilot($, ['status'])
  if (!status.startsWith('Status:')) {  // no project yet
    const yes = await ask($, `${status}\n\nCreate a new project from a plan file?`, 'Autopilot', ['New project from file', 'Cancel'])
    return yes === 'New project from file' ? newProject($) : 'Cancelled.'
  }
  const running = /^Status:\s+running/m.test(status)
  const waiting = status.includes('WAITING for your OK')
  const approved = !status.includes('NOT approved')
  const head = status.split('\n').filter(z => /^(Status|Acceptance|Plan|Tasks|Next|Suggestion):/.test(z)).join('\n')
  const options = waiting ? ['Continue (supervised OK)', 'Status and grades', 'Stop gently', 'More …']
    : running ? ['Status and grades', 'Stop gently', 'Abort now', 'More …']
      : approved ? ['Start', 'Status and grades', 'Planner and new projects', 'More …']
        : ['Approve acceptance test', 'Status and grades', 'Planner and new projects', 'More …']
  const choice = await ask($, `${head}\n\nWhat would you like to do?`, 'Autopilot', options)

  switch (choice) {
    case 'Start': return start($)
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

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'autopilot',
      description: 'Autopilot menu: project from a plan file, start, stop, status, planner, costs',
      argumentHint: '[status|stop|continue|plan <file>|start <runs> [reviewer] [max-rejections] [worker]]',
    })
    // Status line: while a project runs, its progress shows below the input (refreshed every minute).
    const showStatus = async () => {
      const line = await autopilot($, ['status', '--short']).catch(() => '')
      $.ui.status(line.startsWith('Autopilot ') ? line : undefined)
    }
    void showStatus()
    $.clock.every(60_000, () => void showStatus())
    return next(e)
  })

  // Without an argument: selection menu; with an argument straight to the `autopilot` command (e.g. "/autopilot status").
  on('command.run', { command: 'autopilot' }, async ($, e) => {
    try {
      const args = e.args.trim()
      if (args.startsWith('plan ')) return { text: await autopilot($, ['plan', args.slice(5).trim()], 600_000) }
      return { text: args ? await autopilot($, args.split(/\s+/)) : await menu($) }
    } catch {
      return { text: 'Autopilot menu closed.' }
    }
  })
}
