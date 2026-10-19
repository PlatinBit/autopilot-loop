import { expect, test } from 'claude-code/testing'

// process.run wird vom Test beantwortet: nichts Echtes wird gestartet.
const ohneStatuszeile = (aufrufe: string[][]) => aufrufe.filter(a => a[1] !== 'status')

test('/autopilot ruft das mitgelieferte menu.sh mit unveränderten Argumenten auf', async ($, on) => {
  const aufrufe: string[][] = []
  on('process.run', async (_$, e) => {
    aufrufe.push([...e.argv])
    return { value: { exitCode: 0, stdout: 'Gestartet: höchstens 5 Durchläufe', stderr: '' } }
  })

  const { text } = await $.command.run({ command: 'autopilot', args: 'start 5 sonnet 3 opus' })

  const [aufruf] = ohneStatuszeile(aufrufe)
  expect(aufruf[0]).toMatch(/\/menu\.sh$/)
  expect(aufruf.slice(1)).toEqual(['start', '5', 'sonnet', '3', 'opus'])
  expect(text).toBe('Gestartet: höchstens 5 Durchläufe')
})

test('/autopilot plan übergibt den Dateipfad als ein Argument, auch mit Leerzeichen', async ($, on) => {
  const aufrufe: string[][] = []
  on('process.run', async (_$, e) => {
    aufrufe.push([...e.argv])
    return { value: { exitCode: 0, stdout: 'Entwurf fertig', stderr: '' } }
  })

  const { text } = await $.command.run({ command: 'autopilot', args: 'plan ~/Mein Projekt/README.md' })

  expect(ohneStatuszeile(aufrufe).map(a => a.slice(1))).toEqual([['plan', '~/Mein Projekt/README.md']])
  expect(text).toBe('Entwurf fertig')
})
