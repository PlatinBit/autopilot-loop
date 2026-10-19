import type { Engine, Register } from 'claude-code'

// Alle Arbeit macht menu.sh, das mit dem Plugin ausgeliefert wird (das Repo ist das Plugin); dieses Plugin fragt in
// der Auswahlliste von Claude Code ab und zeigt laufende Vorhaben in der Statuszeile. Welches Vorhaben gemeint ist,
// findet menu.sh selbst: ./autopilot.conf im Ordner der Sitzung, sonst das zuletzt angelegte Vorhaben.
async function autopilot($: Engine, args: readonly string[], timeoutMs = 60_000): Promise<string> {
  const r = await $.process.run([`${$.plugin.root}/menu.sh`, ...args], { timeoutMs })
  return (r.stdout + r.stderr).trim()
}

const zahl = (antwort: string) => antwort.match(/\d+/)?.[0]
const erstesWort = (antwort: string) => antwort.split(' ')[0].toLowerCase()
const frage = ($: Engine, text: string, header: string, options: string[]) => $.ui.ask(text, { header, options })

async function starten($: Engine): Promise<string> {
  const n = zahl(await frage($, 'Wie viele Durchläufe höchstens (eine Aufgabe je Durchlauf)?', 'Durchläufe', ['5 (Empfohlen)', '10', '20', '30']))
  if (!n) return 'Abgebrochen: keine Zahl gewählt.'
  const umsetzer = erstesWort(await frage($, 'Welches Modell soll die Aufgaben umsetzen (den Code schreiben)?', 'Umsetzer',
    ['opus (Empfohlen, stärkstes Modell)', 'sonnet (günstiger, schneller)']))
  const gutachter = erstesWort(await frage($, 'Welches Modell soll als Gutachter jede Aufgabe prüfen?', 'Gutachter',
    ['sonnet (Empfohlen, ausgewogen)', 'opus (gründlicher, teurer)', 'haiku (günstig, weniger streng)']))
  const fehler = zahl(await frage($, 'Nach wie vielen Ablehnungen in Folge soll er anhalten?', 'Notbremse', ['3 (Empfohlen)', '2', '5']))
  if (!fehler) return 'Abgebrochen: keine Zahl gewählt.'
  const ok = await frage($, `Starten mit ${n} Durchläufen, Umsetzer ${umsetzer}, Gutachter ${gutachter}, Halt nach ${fehler} Ablehnungen in Folge?`,
    'Bestätigen', ['Starten', 'Abbrechen'])
  return ok === 'Starten' ? autopilot($, ['start', n, gutachter, fehler, umsetzer]) : 'Nicht gestartet.'
}

// Neues Vorhaben: Plan-Datei wählen (Vorschläge aus dem Ordner der Sitzung oder eigener Pfad unter „Other“).
async function neuesVorhaben($: Engine): Promise<string> {
  const r = await $.process.run(['bash', '-c', 'ls -1 *.md 2>/dev/null | head -3'])
  const dateien = r.stdout.split('\n').map(z => z.trim()).filter(Boolean)
  const optionen = dateien.length >= 2 ? dateien : [...dateien, 'Pfad selbst eingeben (unter „Other“)']
  const datei = await frage($, 'Welche Datei beschreibt, was umgesetzt werden soll? (eigener Pfad: „Other“)', 'Plan-Datei', optionen)
  if (datei.startsWith('Pfad selbst')) return 'Bitte den Pfad unter „Other“ eintippen: /autopilot erneut aufrufen.'
  const entwurf = await autopilot($, ['plan', datei], 600_000)
  if (!entwurf.includes('Einrichten: autopilot plan annehmen')) return entwurf
  const ja = await frage($, `${entwurf}\n\nSo einrichten?`, 'Entwurf', ['Einrichten', 'Verwerfen'])
  return ja === 'Einrichten' ? autopilot($, ['plan', 'annehmen']) : 'Entwurf nicht übernommen (ansehen: autopilot plan zeigen).'
}

async function planer($: Engine): Promise<string> {
  const vorschlag = await autopilot($, ['vorschlag'])
  const hat = vorschlag.startsWith('Vorschlag des Planers')
  const wahl = await frage($, hat ? `${vorschlag}\n\nWas tun?` : 'Kein Vorschlag vorhanden. Was tun?', 'Planer',
    hat ? ['Vorschlag übernehmen', 'Vorschlag verwerfen', 'Neues Vorhaben aus Datei']
      : ['Neue Aufgaben planen lassen', 'Neues Vorhaben aus Datei', 'Zurück'])
  switch (wahl) {
    case 'Vorschlag übernehmen': return autopilot($, ['vorschlag', 'annehmen'])
    case 'Vorschlag verwerfen': return autopilot($, ['vorschlag', 'verwerfen'])
    case 'Neue Aufgaben planen lassen': return autopilot($, ['planen'], 600_000)
    case 'Neues Vorhaben aus Datei': return neuesVorhaben($)
    default: return 'Zurück.'
  }
}

async function mehr($: Engine): Promise<string> {
  const wahl = await frage($, 'Was möchtest du sehen?', 'Mehr', ['Kosten und Kurve', 'Entscheidungen lesen', 'Ergebnis ansehen', 'Bericht jetzt'])
  switch (wahl) {
    case 'Kosten und Kurve': return `${await autopilot($, ['kosten'])}\n\nKurve: ${await autopilot($, ['kurve'])}`
    case 'Entscheidungen lesen': return autopilot($, ['notizen'])
    case 'Ergebnis ansehen': return autopilot($, ['ergebnis'])
    case 'Bericht jetzt': return autopilot($, ['bericht'], 300_000)
    default: return `Unbekannte Auswahl: ${wahl}`
  }
}

async function menue($: Engine): Promise<string> {
  const stand = await autopilot($, ['status'])
  if (!stand.startsWith('Zustand:')) {  // noch kein Vorhaben
    const ja = await frage($, `${stand}\n\nNeues Vorhaben aus einer Plan-Datei anlegen?`, 'Autopilot', ['Neues Vorhaben aus Datei', 'Abbrechen'])
    return ja === 'Neues Vorhaben aus Datei' ? neuesVorhaben($) : 'Abgebrochen.'
  }
  const laeuft = /^Zustand:\s+läuft/m.test(stand)
  const wartet = stand.includes('WARTET auf dein OK')
  const frei = !stand.includes('NICHT freigegeben')
  const kopf = stand.split('\n').filter(z => /^(Zustand|Abnahmetest|Plan|Aufgaben|Nächste|Vorschlag):/.test(z)).join('\n')
  const optionen = wartet ? ['Weiter (Fahrstunde OK)', 'Stand und Noten', 'Sanft anhalten', 'Mehr …']
    : laeuft ? ['Stand und Noten', 'Sanft anhalten', 'Sofort abbrechen', 'Mehr …']
      : frei ? ['Starten', 'Stand und Noten', 'Planer und neue Vorhaben', 'Mehr …']
        : ['Abnahmetest freigeben', 'Stand und Noten', 'Planer und neue Vorhaben', 'Mehr …']
  const wahl = await frage($, `${kopf}\n\nWas möchtest du tun?`, 'Autopilot', optionen)

  switch (wahl) {
    case 'Starten': return starten($)
    case 'Weiter (Fahrstunde OK)': return autopilot($, ['weiter'])
    case 'Stand und Noten': return `${stand}\n\nNotentafel:\n${await autopilot($, ['noten'])}`
    case 'Sanft anhalten': return autopilot($, ['stop'])
    case 'Sofort abbrechen': {
      const sicher = await frage($, 'Wirklich sofort abbrechen? Der laufende Durchlauf wird verworfen, Angenommenes bleibt.', 'Abbrechen', ['Ja, abbrechen', 'Nein'])
      return sicher === 'Ja, abbrechen' ? autopilot($, ['abbrechen']) : 'Läuft weiter.'
    }
    case 'Abnahmetest freigeben': {
      const bedingungen = await autopilot($, ['bedingungen'])
      const ja = await frage($, `Ziel des Vorhabens:\n${bedingungen}\n\nSo freigeben? Danach darf der Autopilot den Test nicht mehr ändern.`, 'Freigabe', ['Ja, freigeben', 'Nein'])
      return ja === 'Ja, freigeben' ? autopilot($, ['freigeben']) : 'Nicht freigegeben.'
    }
    case 'Planer und neue Vorhaben': return planer($)
    case 'Mehr …': return mehr($)
    default: return `Unbekannte Auswahl: ${wahl}`
  }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'autopilot',
      description: 'Autopilot-Menü: Vorhaben aus Plan-Datei, starten, anhalten, Stand, Planer, Kosten',
      argumentHint: '[status|stop|weiter|plan <datei>|start <n> [gutachter] [ablehnungen] [umsetzer]]',
    })
    // Statuszeile: läuft ein Vorhaben, steht sein Stand unter der Eingabe (jede Minute aktualisiert).
    const zeigeStand = async () => {
      const zeile = await autopilot($, ['status', '--kurz']).catch(() => '')
      $.ui.status(zeile.startsWith('Autopilot ') ? zeile : undefined)
    }
    void zeigeStand()
    $.clock.every(60_000, () => void zeigeStand())
    return next(e)
  })

  // Ohne Argument: Auswahlmenü; mit Argument direkt an den Befehl `autopilot` (z. B. „/autopilot status“).
  on('command.run', { command: 'autopilot' }, async ($, e) => {
    try {
      const args = e.args.trim()
      if (args.startsWith('plan ')) return { text: await autopilot($, ['plan', args.slice(5).trim()], 600_000) }
      return { text: args ? await autopilot($, args.split(/\s+/)) : await menue($) }
    } catch {
      return { text: 'Autopilot-Menü geschlossen.' }
    }
  })
}
