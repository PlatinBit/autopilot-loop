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
