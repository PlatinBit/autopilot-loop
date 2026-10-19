# Gemeinsamer Teil von autopilot.sh und menu.sh: findet und lädt die Projekt-Konfiguration.
# Reihenfolge: $AUTOPILOT_CONF, ./autopilot.conf, ~/.config/autopilot-loop/standard.conf
# (`autopilot plan <datei>` setzt standard.conf auf das neue Vorhaben, damit `autopilot` überall dieses meint).
# Geladen wird eine Konfiguration nur, wenn ihre Prüfsumme bestätigt ist (autopilot vertrauen <datei>).
WERKZEUG=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
KONF_BASIS=${XDG_CONFIG_HOME:-$HOME/.config}/autopilot-loop
# shellcheck source=helfer.sh
. "$WERKZEUG/helfer.sh"

konf_finden() {
    local k
    for k in "${AUTOPILOT_CONF:-}" "$PWD/autopilot.conf" "$KONF_BASIS/standard.conf"; do
        [ -n "$k" ] && [ -f "$k" ] && { readlink -f "$k"; return 0; }
    done
    return 1
}

KONF=$(konf_finden) || {
    echo "Kein Vorhaben gefunden. Neues aus einer Plan-Datei: autopilot plan <datei>  (oder im Projektordner: autopilot einrichten)" >&2
    exit 3
}
vertraut "$KONF" || {
    echo "Die Konfiguration $KONF ist nicht (mehr) als vertrauenswürdig bestätigt – sie wird als Bash-Code ausgeführt." >&2
    echo "Lies sie, und wenn alles stimmt: autopilot vertrauen $KONF" >&2
    exit 4
}
KONF_ORDNER=$(dirname "$KONF")

# Standardwerte; autopilot.conf überschreibt sie (Bedeutung siehe vorlagen/autopilot.conf)
NAME=$(basename "$KONF_ORDNER")
ARBEITSORDNER=.
BASIS_ZWEIG=main
AUFGABEN=TASKS.md
PRUEFEN=''
PRUEF_ZAHL='^PRUEFUNGEN: ([0-9]+)'
PRUEF_ZAEHLER=''          # statt PRUEF_ZAHL: Befehl, der die Ausgabe von PRUEFEN auf stdin bekommt und die Zahl ausgibt
ABNAHME=''
ABNAHME_ZAHL='^ABNAHME: ([0-9]+) von ([0-9]+)'
ABNAHME_DATEIEN=()
BEDINGUNGEN=''
ERLAUBT=''                # Pflicht: Pfade, die der Umsetzer ändern darf (leer = Start verweigert)
GESPERRT=()               # Pfade, die nie geändert werden dürfen (Plan-Datei; Abnahme-Dateien zählen immer dazu)
VERBOTEN_INHALT=''
UMSETZER_WERKZEUGE=(Read Edit Write Glob Grep)
PROMPT_DATEI=''
GUTACHTER_DATEI=''
PLANER_DATEI=''
PLANER=an                 # leere Liste, Abnahme offen: neue Aufgaben vorschlagen (übernehmen nur mit deinem OK)
FAHRSCHULE=aus            # an: Aufgabenarten ohne Führerschein warten nach jeder Aufgabe auf `autopilot weiter`
FUEHRERSCHEIN_AB=20       # so viele Noten je Art …
FUEHRERSCHEIN_QUOTE=95    # … mit mindestens dieser Erfolgsquote (%) geben den Führerschein
ENTZUG_UNTER=90           # darunter wird er entzogen
STILLSTAND=10             # Warnung nach so vielen angenommenen Durchläufen ohne Abnahme-Fortschritt (0 = aus)
SPIELTEST=''              # optional: Befehl für einen echten Test (z. B. Server starten, Log prüfen)
SPIELTEST_ALLE=0          # alle n angenommenen Durchläufe; 0 = nur wenn das Ziel erreicht ist
BILDKRITIK=''             # optional: Bild, das SPIELTEST erzeugt; der Gutachter bewertet es
BILDKRITIK_FRAGE='Wirkt das Ergebnis auf dem Bild stimmig und fehlerfrei?'
BERICHT_MODELL=haiku
PLAN_DATEI=''             # optional: Plan/Beschreibung, die umgesetzt wird (gesperrt, jedem Durchlauf mitgegeben)
benachrichtigen() { :; }  # STUFE TEXT; STUFE ist ok|info|warn|crit

# shellcheck disable=SC1090
. "$KONF"

absolut() { case "$1" in /*) echo "$1" ;; *) echo "$KONF_ORDNER/$1" ;; esac; }
ARBEITSORDNER=$(absolut "$ARBEITSORDNER")
PROMPT_DATEI=$(absolut "${PROMPT_DATEI:-$WERKZEUG/vorlagen/PROMPT.md}")
GUTACHTER_DATEI=$(absolut "${GUTACHTER_DATEI:-$WERKZEUG/vorlagen/GUTACHTER.md}")
PLANER_DATEI=$(absolut "${PLANER_DATEI:-$WERKZEUG/vorlagen/PLANER.md}")
[ -n "$PLAN_DATEI" ] && PLAN_DATEI=$(absolut "$PLAN_DATEI")
ZUSTAND=$KONF_ORDNER/.autopilot  # Logs, FREIGABE, STOP, Rückmeldung, Noten, Vorschläge
SITZUNG="autopilot-$NAME"
mkdir -p "$ZUSTAND/log" "$ZUSTAND/fuehrerschein"
[ -f "$ZUSTAND/.gitignore" ] || echo '*' >"$ZUSTAND/.gitignore"  # Logs enthalten vollständige Aufträge: nie in Git
# Liegt die Konfiguration im Arbeitsordner, dürfen Status und Konfiguration nie in Git landen.
if ausschluss=$(git -C "$ARBEITSORDNER" rev-parse --git-path info/exclude 2>/dev/null); then
    case "$ausschluss" in /*) ;; *) ausschluss=$ARBEITSORDNER/$ausschluss ;; esac
    mkdir -p "$(dirname "$ausschluss")"
    for muster in .autopilot/ autopilot.conf; do
        grep -qxF "$muster" "$ausschluss" 2>/dev/null || echo "$muster" >>"$ausschluss"
    done
fi

laeuft() { tmux has-session -t "=$SITZUNG" 2>/dev/null; }

# Prüfsumme der gesperrten Abnahme-Dateien (leer, wenn es keinen Abnahmetest gibt)
abnahme_summe() {
    [ ${#ABNAHME_DATEIEN[@]} -gt 0 ] || return 0
    local liste; liste=$(cd "$ARBEITSORDNER" && find "${ABNAHME_DATEIEN[@]}" -type f | LC_ALL=C sort)
    [ -n "$liste" ] || { echo "Abnahme-Dateien nicht gefunden: ${ABNAHME_DATEIEN[*]}" >&2; return 1; }
    (cd "$ARBEITSORDNER" && while IFS= read -r d; do pruefsumme "$d"; done <<<"$liste" | nur_summe)
}
freigegeben() {
    [ ${#ABNAHME_DATEIEN[@]} -eq 0 ] && return 0
    local s; s=$(abnahme_summe) && [ -n "$s" ] && [ "$(cat "$ZUSTAND/FREIGABE" 2>/dev/null)" = "$s" ]
}

# Letzte Zeile einer Ausgabe, die auf das Muster passt → Gruppe 1 (bzw. 2)
zahl_aus() { # DATEI MUSTER [GRUPPE]
    local zeile treffer=''
    while IFS= read -r zeile; do
        [[ $zeile =~ $2 ]] && treffer=${BASH_REMATCH[${3:-1}]}
    done <"$1"
    echo "$treffer"
}

# --- Noten und Führerschein (je Aufgabenart, Art = erstes [tag] nach der Nummer) ------------------
art_von() { # AUFGABENZEILE, z. B. „- [ ] 8. [logik] …“ → logik
    if [[ $1 =~ ^-\ \[.\]\ ([0-9a-z]+\.\ )?\[([a-z0-9_-]+)\] ]]; then echo "${BASH_REMATCH[2]}"; else echo allgemein; fi
}
quote() { # ART → "anzahl erfolge" der letzten FUEHRERSCHEIN_AB Noten
    grep ";$1;" "$ZUSTAND/noten.csv" 2>/dev/null | tail -"$FUEHRERSCHEIN_AB" | awk -F';' '{n++; s+=$3} END {print n+0, s+0}'
}
hat_fuehrerschein() { [ -e "$ZUSTAND/fuehrerschein/$1" ]; }
notentafel() {
    local art n s
    [ -s "$ZUSTAND/noten.csv" ] || { echo "Noch keine Noten."; return; }
    printf '%-14s %8s %8s  %s\n' Art Noten Quote Führerschein
    for art in $(cut -d';' -f2 "$ZUSTAND/noten.csv" | sort -u); do
        read -r n s < <(quote "$art")
        printf '%-14s %8s %7s%%  %s\n' "$art" "$n/$FUEHRERSCHEIN_AB" "$(( n ? 100 * s / n : 0 ))" \
            "$(hat_fuehrerschein "$art" && echo ja || echo "nein (Fahrschule ${FAHRSCHULE})")"
    done
}

# Der Plan als Abschnitt für Aufträge (leer, wenn es keinen gibt)
plan_abschnitt() {
    [ -n "$PLAN_DATEI" ] || return 0
    printf '\n\n## Plan, der umgesetzt wird (%s – nur lesen, nie ändern)\n%s\n' "$(basename "$PLAN_DATEI")" "$(cat "$PLAN_DATEI")"
}

# --- Planer: schlägt neue Aufgaben vor, übernimmt sie erst nach deinem OK -------------------------
planen() {
    local auftrag kosten
    auftrag="$(cat "$PLANER_DATEI")$(plan_abschnitt)

## Aufgabenliste ($AUFGABEN)
$(cat "$ARBEITSORDNER/$AUFGABEN")

## Blockiert
$(cat "$ARBEITSORDNER/BLOCKED.md" 2>/dev/null || echo –)

## Letzter Abnahmetest
$(tail -40 "$(ls -t "$ZUSTAND"/log/abnahme-*.txt 2>/dev/null | head -1)" 2>/dev/null || echo 'kein Abnahmetest')"
    kosten=$(cd "$ARBEITSORDNER" && claude_lauf "$ZUSTAND/log/planer.txt" --model "${UMSETZER_MODELL:-opus}" --allowedTools Read Grep Glob <<<"$auftrag")
    grep -E '^- \[ \] .*Fertig, wenn' "$ZUSTAND/log/planer.txt" >"$ZUSTAND/vorschlag.md"
    echo "$(date '+%F %T');planer;$kosten" >>"$ZUSTAND/log/kosten-extra.csv"
    if [ -s "$ZUSTAND/vorschlag.md" ]; then echo "$(wc -l <"$ZUSTAND/vorschlag.md") Aufgaben vorgeschlagen (autopilot vorschlag)."
    else echo "Der Planer hat keine brauchbaren Aufgaben geliefert, siehe $ZUSTAND/log/planer.txt"; return 1; fi
}
