import { expect, test } from 'claude-code/testing'

// process.run and process.spawn are answered by the test: nothing real is started.
const withoutStatusLine = (calls: string[][]) => calls.filter(a => a[1] !== 'status')

test('/autopilot-loop is the registered command name (/autopilot is one Claude Code ships)', async ($, on) => {
  on('process.run', async () => ({ value: { exitCode: 0, stdout: 'ok', stderr: '' } }))
  expect((await $.command.run({ command: 'autopilot-loop', args: 'grades' })).text).toBe('ok')
})

test('/autopilot-loop calls the bundled menu.sh with unchanged arguments', async ($, on) => {
  const calls: string[][] = []
  on('process.run', async (_$, e) => {
    calls.push([...e.argv])
    return { value: { exitCode: 0, stdout: 'Started: at most 5 runs', stderr: '' } }
  })

  const { text } = await $.command.run({ command: 'autopilot-loop', args: 'start 5 sonnet 3 opus' })

  const [call] = withoutStatusLine(calls)
  expect(call[0]).toMatch(/\/menu\.sh$/)
  expect(call.slice(1)).toEqual(['start', '5', 'sonnet', '3', 'opus'])
  expect(text).toBe('Started: at most 5 runs')
})

test('/autopilot-loop plan passes the file path as one argument, even with spaces (no ten-minute limit)', async ($, on) => {
  const calls: string[][] = []
  on('process.spawn', async function* (_$, e) {
    calls.push([...e.argv])
    yield { stream: 'stdout' as const, text: 'Draft ready\n' }
    return { value: { code: 0, signal: null } }
  })

  const { text } = await $.command.run({ command: 'autopilot-loop', args: 'plan ~/My Project/README.md' })

  expect(calls.map(a => a.slice(1))).toEqual([['plan', '~/My Project/README.md']])
  expect(text).toBe('Draft ready')
})

test('a real error is shown, not "menu closed"', async ($, on) => {
  on('process.run', async () => ({ deny: 'menu.sh timed out' }))
  const { text } = await $.command.run({ command: 'autopilot-loop', args: 'grades' })
  expect(text).toMatch(/^Autopilot error: .*menu\.sh timed out/)
})

test('a dismissed question closes the menu quietly', async ($, on) => {
  on('process.run', async () => ({ value: { exitCode: 0, stdout: 'Status:      off\nTasks:       1 open', stderr: '' } }))
  on('tool.call', { tool: 'AskUserQuestion' }, async () => ({ deny: 'dismissed' }))
  const { text } = await $.command.run({ command: 'autopilot-loop', args: '' })
  expect(text).toBe('Autopilot menu closed.')
})

test('/autopilot-loop plan idea passes the idea as one argument, quotes stripped', async ($, on) => {
  const calls: string[][] = []
  on('process.spawn', async function* (_$, e) {
    calls.push([...e.argv])
    yield { stream: 'stdout' as const, text: 'Plan file written\n' }
    return { value: { code: 0, signal: null } }
  })

  const { text } = await $.command.run({ command: 'autopilot-loop', args: 'plan idea "Build a counter"' })

  expect(calls.map(a => a.slice(1))).toEqual([['plan', 'idea', 'Build a counter']])
  expect(text).toBe('Plan file written')
})

// Answers the selection questions in order; `seen` collects the question texts.
const answerWith = (on: Parameters<Parameters<typeof test>[1]>[1], answers: string[], seen: string[] = []) =>
  on('tool.call', { tool: 'AskUserQuestion' }, async (_$, e) => {
    const questions = (e as unknown as { questions: { question: string }[] }).questions
    seen.push(questions[0].question)
    return { result: { questions, answers: { [questions[0].question]: answers.shift() ?? '' } } }
  })

test('the no-project menu offers "New project from an idea" and hands the typed idea to plan idea', async ($, on) => {
  const spawns: string[][] = []
  on('process.run', async () => ({ value: { exitCode: 3, stdout: 'No project found. Create one from a plan file: autopilot plan <file>', stderr: '' } }))
  on('process.spawn', async function* (_$, e) {
    spawns.push([...e.argv])
    yield { stream: 'stdout' as const, text: 'Plan file written: ./tiny-counter-plan.md\n' }
    return { value: { code: 0, signal: null } }
  })
  answerWith(on, ['New project from an idea', 'Build a tiny counter'])

  const { text } = await $.command.run({ command: 'autopilot-loop', args: '' })

  expect(spawns.map(a => a.slice(1))).toEqual([['plan', 'idea', 'Build a tiny counter']])
  expect(text).toBe('Plan file written: ./tiny-counter-plan.md')
})

// The running -> not-running transition lives in pollStatus, which runs after every command and on
// the session.start timer. The harness fires neither session.start nor the timer, and a plugin's
// $.ui.toast / $.ui.status are not routed through test hooks here, so the toast text itself is not
// assertable; what is observable is the transition's one `menu.sh summary --short` call - the piece
// that fetches the toast's content - and that it happens exactly once, never without a prior
// "running" poll (so a fresh session or a reload can never produce a false "finished").
test('the finish transition fetches the summary one-liner exactly once', async ($, on) => {
  let short = 'Autopilot demo: Run 1/5'
  const calls: string[][] = []
  on('process.run', async (_$, e) => {
    calls.push([...e.argv])
    return {
      value: {
        exitCode: 0, stderr: '',
        stdout: e.argv[1] === 'status' ? short : e.argv[1] === 'summary' ? 'delivered - 5 done, 1 blocked, tests 114 -> 131, 4.20 USD' : 'ok',
      },
    }
  })
  const summaries = () => calls.filter(a => a[1] === 'summary').map(a => a.slice(1))

  await $.command.run({ command: 'autopilot-loop', args: 'grades' })  // poll sees: running
  expect(summaries()).toEqual([])
  short = ''                                                          // the run ended
  await $.command.run({ command: 'autopilot-loop', args: 'grades' })  // poll sees: not running -> finished
  expect(summaries()).toEqual([['summary', '--short']])
  await $.command.run({ command: 'autopilot-loop', args: 'grades' })  // later polls: no second finish
  expect(summaries()).toEqual([['summary', '--short']])
})

test('never seen running: the finish path is never taken (fresh session or reload stays quiet)', async ($, on) => {
  const calls: string[][] = []
  on('process.run', async (_$, e) => {
    calls.push([...e.argv])
    return { value: { exitCode: 0, stdout: e.argv[1] === 'status' ? '' : 'ok', stderr: '' } }
  })

  await $.command.run({ command: 'autopilot-loop', args: 'grades' })
  await $.command.run({ command: 'autopilot-loop', args: 'grades' })

  expect(calls.filter(a => a[1] === 'summary')).toEqual([])
})

test('a poll answered with exit 4 (conf not trusted) decides nothing: no false finish, no lost finish', async ($, on) => {
  let reply = { exitCode: 0, stdout: 'Autopilot demo: Run 1/5' }
  const calls: string[][] = []
  on('process.run', async (_$, e) => {
    calls.push([...e.argv])
    return { value: { stderr: '', ...(e.argv[1] === 'status' ? reply : { exitCode: 0, stdout: 'ok' }) } }
  })
  const summaries = () => calls.filter(a => a[1] === 'summary').length

  await $.command.run({ command: 'autopilot-loop', args: 'grades' })  // running
  reply = { exitCode: 4, stdout: 'autopilot.conf changed: autopilot trust' }
  await $.command.run({ command: 'autopilot-loop', args: 'grades' })  // unknown: hold the state
  expect(summaries()).toBe(0)
  reply = { exitCode: 3, stdout: 'No project found' }
  await $.command.run({ command: 'autopilot-loop', args: 'grades' })  // any other failure is unknown too
  expect(summaries()).toBe(0)
  reply = { exitCode: 0, stdout: '' }
  await $.command.run({ command: 'autopilot-loop', args: 'grades' })  // now it really ended
  expect(summaries()).toBe(1)
})

test('the menu offers the handover under "More"', async ($, on) => {
  const calls: string[][] = []
  on('process.run', async (_$, e) => {
    calls.push([...e.argv])
    return { value: { exitCode: 0, stderr: '', stdout: e.argv[1] === 'status' ? 'Status:      off\nTasks:       0 open' : 'Result: delivered' } }
  })
  answerWith(on, ['More …', 'Handover: result and how to try it'])
  const { text } = await $.command.run({ command: 'autopilot-loop', args: '' })
  expect(calls.map(a => a[1])).toContain('handover')
  expect(text).toBe('Result: delivered')
})

test('the start dialog warns when the status reports no demo', async ($, on) => {
  on('process.run', async (_$, e) => ({ value: { exitCode: 0, stderr: '',
    stdout: e.argv[1] === 'status' ? 'Status:      off\nDemo:        none\nTasks:       1 open' : 'ok' } }))
  const seen: string[] = []
  answerWith(on, ['Start', '5', 'opus', 'sonnet', 'sonnet', '3', 'Cancel'], seen)
  const { text } = await $.command.run({ command: 'autopilot-loop', args: '' })
  expect(text).toBe('Not started.')
  expect(seen.at(-1)).toMatch(/No demo configured .* never be reported as delivered/)
})

test('a draft without a demo is set up only with --no-demo; a proposed acceptance test needs an explicit yes', async ($, on) => {
  const accepts: string[][] = []
  let draft = 'Draft for: plan.md\nNo demo command (DEMO_CMD) in the draft\nSet up: autopilot plan accept'
  on('process.run', async (_$, e) => ({ value: { exitCode: e.argv[1] === 'status' ? 3 : 0, stderr: '', stdout: e.argv[1] === 'status' ? 'No project found.' : 'ok' } }))
  on('process.spawn', async function* (_$, e) {  // every `plan …` call is spawned, the draft and the accept
    if (e.argv[2] === 'accept') { accepts.push(e.argv.slice(3)); yield { stream: 'stdout' as const, text: 'Set up' } }
    else yield { stream: 'stdout' as const, text: draft }
    return { value: { code: 0, signal: null } }
  })
  answerWith(on, ['New project from file', 'plan.md', 'Set up without demo (never reported as delivered)',
    'New project from file', 'plan.md', 'Set up', 'Adopt'])
  expect((await $.command.run({ command: 'autopilot-loop', args: '' })).text).toBe('Set up')
  expect(accepts).toEqual([['--no-demo']])

  draft = 'Draft for: plan.md\nDEMO_CMD=\'python app.py --help\'\nThe draft proposes an acceptance test\nSet up: autopilot plan accept'
  await $.command.run({ command: 'autopilot-loop', args: '' })
  expect(accepts).toEqual([['--no-demo'], ['--with-accept']])
})
