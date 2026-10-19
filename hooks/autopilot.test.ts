import { expect, test } from 'claude-code/testing'

// process.run is answered by the test: nothing real is started.
const withoutStatusLine = (calls: string[][]) => calls.filter(a => a[1] !== 'status')

test('/autopilot calls the bundled menu.sh with unchanged arguments', async ($, on) => {
  const calls: string[][] = []
  on('process.run', async (_$, e) => {
    calls.push([...e.argv])
    return { value: { exitCode: 0, stdout: 'Started: at most 5 runs', stderr: '' } }
  })

  const { text } = await $.command.run({ command: 'autopilot', args: 'start 5 sonnet 3 opus' })

  const [call] = withoutStatusLine(calls)
  expect(call[0]).toMatch(/\/menu\.sh$/)
  expect(call.slice(1)).toEqual(['start', '5', 'sonnet', '3', 'opus'])
  expect(text).toBe('Started: at most 5 runs')
})

test('/autopilot plan passes the file path as one argument, even with spaces', async ($, on) => {
  const calls: string[][] = []
  on('process.run', async (_$, e) => {
    calls.push([...e.argv])
    return { value: { exitCode: 0, stdout: 'Draft ready', stderr: '' } }
  })

  const { text } = await $.command.run({ command: 'autopilot', args: 'plan ~/My Project/README.md' })

  expect(withoutStatusLine(calls).map(a => a.slice(1))).toEqual([['plan', '~/My Project/README.md']])
  expect(text).toBe('Draft ready')
})
