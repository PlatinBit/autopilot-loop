import { expect, test } from 'claude-code/testing'

// process.run and process.spawn are answered by the test: nothing real is started.
const withoutStatusLine = (calls: string[][]) => calls.filter(a => a[1] !== 'status')

test('/autopilot-loop is the registered command name (/autopilot is one Claude Code ships)', async ($, on) => {
  on('process.run', async () => ({ value: { exitCode: 0, stdout: 'ok', stderr: '' } }))
  expect((await $.command.run({ command: 'autopilot-loop', args: 'handover' })).text).toBe('ok')
})

test('/autopilot-loop calls the bundled menu.sh with unchanged arguments', async ($, on) => {
  const calls: string[][] = []
  on('process.run', async (_$, e) => {
    calls.push([...e.argv])
    return { value: { exitCode: 0, stdout: 'Stops after the current run', stderr: '' } }
  })

  const { text } = await $.command.run({ command: 'autopilot-loop', args: 'stop --now' })

  const [call] = withoutStatusLine(calls)
  expect(call[0]).toMatch(/\/menu\.sh$/)
  expect(call.slice(1)).toEqual(['stop', '--now'])
  expect(text).toBe('Stops after the current run')
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

test('/autopilot-loop plan "<idea>" passes the idea as one argument, quotes stripped', async ($, on) => {
  const calls: string[][] = []
  on('process.spawn', async function* (_$, e) {
    calls.push([...e.argv])
    yield { stream: 'stdout' as const, text: 'Plan file written\n' }
    return { value: { code: 0, signal: null } }
  })

  const { text } = await $.command.run({ command: 'autopilot-loop', args: 'plan "Build a counter"' })

  expect(calls.map(a => a.slice(1))).toEqual([['plan', 'Build a counter']])
  expect(text).toBe('Plan file written')
})

test('a real error is shown, not "menu closed"', async ($, on) => {
  on('process.run', async () => ({ deny: 'menu.sh timed out' }))
  const { text } = await $.command.run({ command: 'autopilot-loop', args: 'handover' })
  expect(text).toMatch(/^Autopilot error: .*menu\.sh timed out/)
})

test('a dismissed question closes the menu quietly', async ($, on) => {
  on('process.run', async () => ({ value: { exitCode: 0, stdout: 'Status:      off\nTasks:       1 open', stderr: '' } }))
  on('tool.call', { tool: 'AskUserQuestion' }, async () => ({ deny: 'dismissed' }))
  const { text } = await $.command.run({ command: 'autopilot-loop', args: '' })
  expect(text).toBe('Autopilot menu closed.')
})

// Answers the selection questions in order; `seen` collects the question texts.
const answerWith = (on: Parameters<Parameters<typeof test>[1]>[1], answers: string[], seen: string[] = []) =>
  on('tool.call', { tool: 'AskUserQuestion' }, async (_$, e) => {
    const questions = (e as unknown as { questions: { question: string }[] }).questions
    seen.push(questions[0].question)
    return { result: { questions, answers: { [questions[0].question]: answers.shift() ?? '' } } }
  })

test('the no-project menu turns a typed idea into a draft and sets it up on "Set up"', async ($, on) => {
  const spawns: string[][] = []
  on('process.run', async () => ({ value: { exitCode: 3, stdout: 'No project found here. Create one: autopilot plan <file>', stderr: '' } }))
  on('process.spawn', async function* (_$, e) {
    spawns.push([...e.argv])
    yield { stream: 'stdout' as const, text: e.argv[2] === 'accept' ? 'Set up' : 'Plan file written\nDraft for: x\nSet up: autopilot plan accept\n' }
    return { value: { code: 0, signal: null } }
  })
  answerWith(on, ['New project from an idea', 'Build a tiny counter', 'Set up'])

  const { text } = await $.command.run({ command: 'autopilot-loop', args: '' })

  expect(spawns.map(a => a.slice(1))).toEqual([['plan', 'Build a tiny counter'], ['plan', 'accept']])
  expect(text).toBe('Set up')
})

test('the start dialog asks only for a confirmation and calls start without arguments', async ($, on) => {
  const calls: string[][] = []
  on('process.run', async (_$, e) => {
    calls.push([...e.argv])
    return { value: { exitCode: 0, stderr: '', stdout: e.argv[1] === 'status' ? 'Status:      off\nTasks:       1 open' : 'Started' } }
  })
  const seen: string[] = []
  answerWith(on, ['Start', 'Start'], seen)
  const { text } = await $.command.run({ command: 'autopilot-loop', args: '' })
  expect(text).toBe('Started')
  expect(seen).toHaveLength(2)
  expect(withoutStatusLine(calls).map(a => a.slice(1))).toEqual([['start']])
})

test('the menu offers the handover', async ($, on) => {
  const calls: string[][] = []
  on('process.run', async (_$, e) => {
    calls.push([...e.argv])
    return { value: { exitCode: 0, stderr: '', stdout: e.argv[1] === 'status' ? 'Status:      off\nTasks:       0 open' : '# Delivered' } }
  })
  answerWith(on, ['Handover: result and how to try it'])
  const { text } = await $.command.run({ command: 'autopilot-loop', args: '' })
  expect(calls.map(a => a[1])).toContain('handover')
  expect(text).toBe('# Delivered')
})

// The running -> ended transition lives in pollStatus, which runs after every command (and on the
// session.start timer, which the harness does not fire). Toast and status line are answered here.
const observe = (on: Parameters<Parameters<typeof test>[1]>[1]) => {
  const seen = { toasts: [] as string[], status: [] as (string | undefined)[] }
  on('ui.toast', async (_$, e) => { seen.toasts.push(e.text); return { value: undefined } })
  on('ui.status', async (_$, e) => { seen.status.push(e.text); return { value: undefined } })
  return seen
}

test('a project the last poll saw running and this one sees ended gets one toast; the others keep running', async ($, on) => {
  let short = 'Autopilot a: run 1/50 · 0.10 USD\nAutopilot b: run 3/50 · 0.40 USD'
  on('process.run', async (_$, e) => ({ value: { exitCode: 0, stderr: '', stdout: e.argv[2] === '--short' ? short : 'ok' } }))
  const seen = observe(on)

  await $.command.run({ command: 'autopilot-loop', args: 'handover' })   // poll: both running
  expect(seen.toasts).toEqual([])
  expect(seen.status.at(-1)).toBe('Autopilot a: run 1/50 · 0.10 USD | Autopilot b: run 3/50 · 0.40 USD')
  short = 'Autopilot a ended: delivered - 2 done, 0 blocked, tests 1 -> 3, 0.20 USD\nAutopilot b: run 4/50 · 0.50 USD'
  await $.command.run({ command: 'autopilot-loop', args: 'handover' })   // a ended
  const done = 'Autopilot a: Delivered - 2 done, 0 blocked, tests 1 -> 3, 0.20 USD - /autopilot-loop handover'
  expect(seen.toasts).toEqual([done])
  expect(seen.status.at(-1)).toBe(`Autopilot b: run 4/50 · 0.50 USD | ${done}`)
  await $.command.run({ command: 'autopilot-loop', args: 'handover' })   // later polls: no second toast, the line stays
  expect(seen.toasts).toEqual([done])
  expect(seen.status.at(-1)).toBe(`Autopilot b: run 4/50 · 0.50 USD | ${done}`)
})

test('never seen running: an ended line of an older start stays quiet (fresh session or reload)', async ($, on) => {
  on('process.run', async (_$, e) => ({ value: { exitCode: 0, stderr: '',
    stdout: e.argv[2] === '--short' ? 'Autopilot a ended: not delivered (no demo) - 1 done, 0 blocked, tests 1 -> 2, 0.10 USD' : 'ok' } }))
  const seen = observe(on)
  await $.command.run({ command: 'autopilot-loop', args: 'handover' })
  await $.command.run({ command: 'autopilot-loop', args: 'handover' })
  expect(seen.toasts).toEqual([])
  expect(seen.status.at(-1)).toBeUndefined()
})

test('a failed poll decides nothing: no false finish, no lost finish', async ($, on) => {
  let reply = { exitCode: 0, stdout: 'Autopilot a: run 1/50 · 0.10 USD' }
  on('process.run', async (_$, e) => ({ value: { stderr: '', ...(e.argv[2] === '--short' ? reply : { exitCode: 0, stdout: 'ok' }) } }))
  const seen = observe(on)
  await $.command.run({ command: 'autopilot-loop', args: 'handover' })   // running
  reply = { exitCode: 1, stdout: '' }
  await $.command.run({ command: 'autopilot-loop', args: 'handover' })   // unknown: hold the state
  expect(seen.toasts).toEqual([])
  reply = { exitCode: 0, stdout: 'Autopilot a ended: delivered - 1 done, 0 blocked, tests 1 -> 2, 0.10 USD' }
  await $.command.run({ command: 'autopilot-loop', args: 'handover' })   // now it really ended
  expect(seen.toasts).toHaveLength(1)
  expect(seen.toasts[0]).toMatch(/^Autopilot a: Delivered - /)
})
