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

test('the no-project menu offers "New project from an idea" and hands the typed idea to plan idea', async ($, on) => {
  const spawns: string[][] = []
  on('process.run', async () => ({ value: { exitCode: 3, stdout: 'No project found. Create one from a plan file: autopilot plan <file>', stderr: '' } }))
  on('process.spawn', async function* (_$, e) {
    spawns.push([...e.argv])
    yield { stream: 'stdout' as const, text: 'Plan file written: ./tiny-counter-plan.md\n' }
    return { value: { code: 0, signal: null } }
  })
  const answers = ['New project from an idea', 'Build a tiny counter']
  on('tool.call', { tool: 'AskUserQuestion' }, async (_$, e) => {
    const questions = (e as unknown as { questions: { question: string }[] }).questions
    return { result: { questions, answers: { [questions[0].question]: answers.shift() ?? '' } } }
  })

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
        stdout: e.argv[1] === 'status' ? short : e.argv[1] === 'summary' ? '5 done, 1 blocked, tests 114 -> 131, 4.20 USD' : 'ok',
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
