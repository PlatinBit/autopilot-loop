#!/usr/bin/env bash
# autopilot-loop: Regelkreis aus Umsetzer, Skript-Prüfer, Gutachter und gesperrtem Ziel (Plan/Abnahmetest).
# Claude Code arbeitet die Aufgabenliste ab, eine Aufgabe je Durchlauf, mit frischem Kontext und ohne Git.
# Dieses Skript prüft danach selbst, lässt einen zweiten Claude urteilen und committet nur, was alles besteht;
# sonst Rücksetzen mit Rückmeldung an den nächsten Versuch. Dazu: Noten und Führerschein je Aufgabenart,
# Kosten je Durchlauf, Stillstand-Warnung, Planer für neue Aufgaben, optionaler Spieltest mit Bildkritik.
#
# Wichtig: Die Prüfungen sichern die Qualität, sie sind keine Sicherheitsgrenze. Der Prüfbefehl führt Code aus,
# den Claude geschrieben hat. Fremde Pläne oder Projekte nur in einem Container oder einer VM bearbeiten lassen.
#
# Normalerweise über das Menü gestartet (`autopilot`, in Claude Code `/autopilot`).
# Umgebung: MAX (Durchläufe, 30), MAX_FEHLER (Ablehnungen in Folge, 3), MAX_BLOCKIERT (blockierte Aufgaben, 3),
#           UMSETZER_MODELL (opus), GUTACHTER_MODELL (sonnet), AUTOPILOT_CONF (Konfiguration)
set -u -o pipefail
# shellcheck source=gemeinsam.sh
. "$(dirname "$(readlink -f "$0")")/gemeinsam.sh"
MAX=${MAX:-30}
MAX_FEHLER=${MAX_FEHLER:-3}
MAX_BLOCKIERT=${MAX_BLOCKIERT:-3}
UMSETZER_MODELL=${UMSETZER_MODELL:-opus}
GUTACHTER_MODELL=${GUTACHTER_MODELL:-sonnet}
WARTEN=${AUTOPILOT_WARTEN:-1800}      # Sekunden Pause beim Nutzungslimit
NACHFRAGE=${AUTOPILOT_NACHFRAGE:-20}  # Sekunden zwischen zwei Blicken auf `autopilot weiter`
LOGS=$ZUSTAND/log
RUECK=$ZUSTAND/rueckmeldung.txt
CSV=$LOGS/fortschritt.csv
KOPF="zeit;durchlauf;ergebnis;offene_aufgaben;pruefungen;abnahme;sekunden;kosten_usd;art;umsetzer;gutachter"
# Was nie geändert werden darf, egal was ERLAUBT sagt: Git-, Claude-, CI- und Autopilot-Verwaltung
IMMER_GESPERRT='^(\.git|\.claude/|\.github/|\.autopilot/|autopilot\.conf$|CLAUDE\.md$)'
cd "$ARBEITSORDNER" || exit 1

notiz() { echo "$(date '+%F %T') $1" | tee -a "$LOGS/verlauf.txt"; }
melde() { notiz "$2"; benachrichtigen "$1" "$2" >/dev/null 2>&1 || true; }
# Ältere Fortschrittsdateien mit anderen Spalten beiseitelegen
[ -s "$CSV" ] && [ "$(head -1 "$CSV")" != "$KOPF" ] && mv "$CSV" "$LOGS/fortschritt-$(date +%F-%H%M%S).csv"
protokoll() { # ERGEBNIS
    [ -s "$CSV" ] || echo "$KOPF" >"$CSV"
    echo "$(date '+%F %T');$i;$1;$(grep -c '^- \[ \]' "$AUFGABEN");$zahl;$abn;$(( $(date +%s) - start ));$kosten;$art;$UMSETZER_MODELL;$GUTACHTER_MODELL" >>"$CSV"
}
plus() { echo "$1 ${2:-0}" | awk '{printf "%.4f", $1 + $2}'; }
zusatzkosten() { # Kosten von Gutachter und Bildkritik zum Durchlauf addieren
    [ -s "$ZUSTAND/kosten-zusatz" ] || return 0
    kosten=$(plus "$kosten" "$(awk '{s += $1} END {print s + 0}' "$ZUSTAND/kosten-zusatz")"); rm -f "$ZUSTAND/kosten-zusatz"
}
ist_zahl() { [[ ${1:-} =~ ^[0-9]+$ ]]; }

# Fingerabdruck der Git-Verwaltung (config, info, hooks): ändert ihn ein Durchlauf, wird angehalten,
# denn darüber ließe sich beim nächsten Git-Aufruf Code ausführen.
git_abdruck() {
    local d
    for d in "$(g rev-parse --git-common-dir)" "$(g rev-parse --git-dir)"; do
        find "$d/config" "$d/info" "$d/hooks" -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do pruefsumme "$f"; done
    done | nur_summe
}

# Note für die Aufgabenart; vergibt oder entzieht den Führerschein
benoten() { # NOTE (1 angenommen, 0 verworfen)
    local n s q
    echo "$(date '+%F %T');$art;$1" >>"$ZUSTAND/noten.csv"
    read -r n s < <(quote "$art"); q=$(( 100 * s / n ))
    if ! hat_fuehrerschein "$art" && [ "$n" -ge "$FUEHRERSCHEIN_AB" ] && [ "$q" -ge "$FUEHRERSCHEIN_QUOTE" ]; then
        touch "$ZUSTAND/fuehrerschein/$art"; melde ok "Führerschein für Aufgabenart „$art“: $q % aus $n Durchläufen"
    elif hat_fuehrerschein "$art" && [ "$q" -lt "$ENTZUG_UNTER" ]; then
        rm -f "$ZUSTAND/fuehrerschein/$art"; melde warn "Führerschein für „$art“ entzogen: nur noch $q % – wieder Fahrschule"
    fi
}

# Zahl bestandener Prüfungen, leer bei rotem Ergebnis oder wenn keine Zahl gelesen werden kann.
pruefen() {
    local n
    nice -n 10 bash -c "$PRUEFEN" >"$1" 2>&1 || return 0
    if [ -n "$PRUEF_ZAEHLER" ]; then n=$(bash -c "$PRUEF_ZAEHLER" <"$1" | tail -1)
    else n=$(zahl_aus "$1" "$PRUEF_ZAHL"); fi
    ist_zahl "$n" && echo "$n"
}
# Erfüllte Abnahmebedingungen, 0 wenn der Test nicht läuft (darf rot sein).
abnahme() {
    [ -n "$ABNAHME" ] || { echo 0; return; }
    nice -n 10 bash -c "$ABNAHME" >"$1" 2>&1
    local k; k=$(zahl_aus "$1" "$ABNAHME_ZAHL"); ist_zahl "$k" && echo "$k" || echo 0
}

verwerfen() { # VORHER GRUND [LOGDATEI]
    g reset -q --hard "$1" && g clean -qfd
    notiz "Durchlauf $i verworfen: $2"
    { echo "Der letzte Versuch an dieser Aufgabe wurde verworfen. Grund: $2"
      [ -n "${3:-}" ] && { echo; echo "Letzte Zeilen aus $(basename "$3"):"; tail -40 "$3"; }; } >"$RUECK"
    fehler=$((fehler + 1)); protokoll verworfen; benoten 0
}

blockieren() { # GRUND: erste offene Aufgabe als [~] markieren, damit die Schleife weiterkommt
    local vorher_offen; vorher_offen=$(grep -c '^- \[ \]' "$AUFGABEN")
    echo "- $(date +%F), $(grep -m1 '^- \[ \]' "$AUFGABEN" | cut -c7-60): $1" >>BLOCKED.md
    erste_offene_blockieren "$AUFGABEN"
    [ "$(grep -c '^- \[ \]' "$AUFGABEN")" -lt "$vorher_offen" ] || { melde crit "Aufgabe ließ sich nicht als blockiert markieren, angehalten"; exit 1; }
    g add -A && g commit -q -m "Autopilot: blockiert – $1"
    notiz "Aufgabe blockiert: $1"
    rm -f "$RUECK"; fehler=0; ablehnungen=0
}

# Zweiter Claude mit frischem Kontext und nur Leserechten; gibt die URTEIL-Zeile aus.
urteil_von() { # AUFTRAG-DATEI LOG-NAME
    local versuch k
    for versuch in $(seq 1 20); do
        k=$(claude_lauf "$LOGS/$2" --model "$GUTACHTER_MODELL" --allowedTools Read Grep Glob <"$1")
        echo "$k" >>"$ZUSTAND/kosten-zusatz"  # läuft in einer Unter-Shell: Kosten über eine Datei zurückgeben
        grep '^URTEIL:' "$LOGS/$2" | tail -1 | grep . && return
        nutzungslimit "$LOGS/$2" || return
        notiz "Gutachter: Nutzungslimit, warte $((WARTEN / 60)) min" >&2; sleep "$WARTEN"
    done
}
gutachten() {
    { cat "$GUTACHTER_DATEI"; plan_abschnitt; echo; echo "## Aufgabe"; echo "$aufgabe_offen"; echo; echo "## Diff"
      g diff --cached --no-ext-diff --no-textconv; } >"$LOGS/gutachten-auftrag.txt"
    urteil_von "$LOGS/gutachten-auftrag.txt" "gutachten-$i.txt"
}

# Optionaler echter Test; mit BILDKRITIK bewertet der Gutachter zusätzlich das erzeugte Bild.
spieltest() { # → 0 bestanden, sonst Grund in $grund
    [ -n "$SPIELTEST" ] || return 0
    nice -n 10 bash -c "$SPIELTEST" >"$LOGS/spieltest-$i.txt" 2>&1 || { grund="Spieltest rot"; return 1; }
    [ -n "$BILDKRITIK" ] || return 0
    [ -f "$BILDKRITIK" ] || { grund="Spieltest lieferte kein Bild ($BILDKRITIK)"; return 1; }
    printf '%s\n\nLies das Bild %s mit dem Read-Werkzeug. Frage: %s\nDie letzte Zeile muss lauten: URTEIL: ANNEHMEN oder URTEIL: ABLEHNEN: <Grund>\n' \
        "Du bist Gutachter und siehst dir ein Ergebnisbild an." "$(readlink -f "$BILDKRITIK")" "$BILDKRITIK_FRAGE" >"$LOGS/bildkritik-auftrag.txt"
    local u; u=$(urteil_von "$LOGS/bildkritik-auftrag.txt" "bildkritik-$i.txt")
    [ "$u" = "URTEIL: ANNEHMEN" ] || { grund="Bildkritik: ${u#URTEIL: ABLEHNEN: }"; return 1; }
}

# Fahrschule: Arten ohne Führerschein warten nach jeder Aufgabe auf `autopilot weiter`.
fahrstunde() {
    [ "$FAHRSCHULE" = an ] && ! hat_fuehrerschein "$art" || return 0
    echo "$aufgabe" >"$ZUSTAND/WARTET"; rm -f "$ZUSTAND/WEITER"
    melde info "Fahrstunde „$art“: $aufgabe – angenommen und committet. Bitte ansehen, dann: autopilot weiter"
    until [ -e "$ZUSTAND/WEITER" ] || [ -e "$ZUSTAND/STOP" ]; do sleep "$NACHFRAGE"; done
    rm -f "$ZUSTAND/WARTET" "$ZUSTAND/WEITER"
}

# Dateinamen der vorgemerkten Änderungen, ohne Umbenennungs-Erkennung (sonst fiele der alte Pfad heraus)
geaendert() { g diff --cached --name-only --no-renames -- "$@"; }

[ -n "$PRUEFEN" ] || { melde crit "PRUEFEN ist in $KONF nicht gesetzt"; exit 1; }
[ -n "$ERLAUBT" ] || { melde crit "ERLAUBT ist in $KONF nicht gesetzt – welche Pfade darf Claude ändern?"; exit 1; }
[ -f "$AUFGABEN" ] || { melde crit "Aufgabenliste $ARBEITSORDNER/$AUFGABEN fehlt"; exit 1; }
freigegeben || { melde warn "Abnahmetest nicht freigegeben: im Menü „Abnahmetest freigeben“ wählen (oder: autopilot freigeben)"; exit 1; }
[ -n "$(g status --porcelain)" ] && { melde crit "Arbeitsordner nicht sauber, Abbruch"; exit 1; }
rm -f "$ZUSTAND/WARTET" "$ZUSTAND/WEITER" "$ZUSTAND/kosten-zusatz"

i=0; start=$(date +%s); abn=0; kosten=0; art=-
zahl=$(pruefen "$LOGS/start.txt")
[ -n "$zahl" ] || { melde crit "Prüfung schon vor dem Start rot oder ohne lesbare Zahl, siehe $LOGS/start.txt"; exit 1; }
abn=$(abnahme "$LOGS/abnahme-start.txt")
ziel=$( [ -n "$ABNAHME" ] && zahl_aus "$LOGS/abnahme-start.txt" "$ABNAHME_ZAHL" 2 )
ist_zahl "$ziel" || ziel=''
abdruck=$(git_abdruck)
melde info "Start: $zahl Prüfungen grün${ABNAHME:+, Abnahme $abn von ${ziel:-?}}, höchstens $MAX Durchläufe, Umsetzer $UMSETZER_MODELL, Gutachter $GUTACHTER_MODELL"

fehler=0; wartezeiten=0; ablehnungen=0; letzte=""; angenommen=0; ohne_fortschritt=0
while [ "$i" -lt "$MAX" ]; do
    [ -e "$ZUSTAND/STOP" ] && { rm -f "$ZUSTAND/STOP"; melde info "Angehalten per STOP nach $i Durchläufen"; exit 0; }
    if ! grep -q '^- \[ \]' "$AUFGABEN"; then
        if [ -z "$ABNAHME" ] || [ "$abn" = "${ziel:-x}" ]; then
            grund=''; i=ende; spieltest || { melde warn "Alle Aufgaben erledigt, aber $grund (siehe log/spieltest-ende.txt)"; exit 1; }
            melde ok "Ziel erreicht: alle Aufgaben erledigt${ABNAHME:+, Abnahme $abn von $ziel}."
        elif [ "$PLANER" = an ]; then
            notiz "Keine offenen Aufgaben, Abnahme erst $abn von ${ziel:-?}: Planer entwirft neue Aufgaben …"
            melde warn "Abnahme erst $abn von ${ziel:-?}. $(planen) Ansehen und übernehmen: autopilot vorschlag"
        else melde warn "Keine offenen Aufgaben mehr, Abnahme erst $abn von ${ziel:-?}: neue Aufgaben nötig"; fi
        exit 0
    fi
    [ "$fehler" -ge "$MAX_FEHLER" ] && { melde crit "$fehler Ablehnungen in Folge, angehalten. Letzter Grund: $(head -1 "$RUECK" 2>/dev/null)"; exit 1; }
    [ "$(grep -c '^- \[~\]' "$AUFGABEN")" -ge "$MAX_BLOCKIERT" ] && { melde crit "$MAX_BLOCKIERT Aufgaben blockiert, bitte BLOCKED.md ansehen"; exit 1; }

    i=$((i + 1)); start=$(date +%s); vorher=$(g rev-parse HEAD); kosten=0
    aufgabe_offen=$(grep -m1 '^- \[ \]' "$AUFGABEN"); art=$(art_von "$aufgabe_offen")
    [ "$aufgabe_offen" != "$letzte" ] && { letzte=$aufgabe_offen; ablehnungen=0; rm -f "$RUECK"; }
    notiz "Durchlauf $i: $(echo "$aufgabe_offen" | cut -c7-80)"
    auftrag=$(cat "$PROMPT_DATEI")
    auftrag=${auftrag//\{AUFGABEN\}/$AUFGABEN}
    auftrag=${auftrag//\{PRUEFEN\}/$PRUEFEN}
    auftrag=${auftrag//\{ABNAHME\}/${ABNAHME:-(kein Abnahmetest)}}
    auftrag+=$(plan_abschnitt)
    [ -s "$RUECK" ] && auftrag+=$'\n\n## Rückmeldung zum letzten Versuch\n'"$(cat "$RUECK")"
    kosten=$(CLAUDE_ZEIT=45m claude_lauf "$LOGS/durchlauf-$i.txt" --model "$UMSETZER_MODELL" --permission-mode acceptEdits \
        --allowedTools "${UMSETZER_WERKZEUGE[@]}" <<<"$auftrag")
    rc=$?; kosten=${kosten:-0}

    # Hat der Durchlauf die Git-Verwaltung verändert (Hooks, config)? Dann sofort anhalten.
    if [ "$(git_abdruck)" != "$abdruck" ]; then
        melde crit "Durchlauf $i hat .git (config, info oder hooks) verändert – angehalten. Bitte prüfen, bevor wieder gestartet wird."
        exit 1
    fi

    # Nutzungslimit des Abos: warten statt Durchlauf verbrauchen (höchstens 20 Mal).
    if [ "$rc" -ne 0 ] && nutzungslimit "$LOGS/durchlauf-$i.txt"; then
        g reset -q --hard "$vorher" && g clean -qfd
        i=$((i - 1)); wartezeiten=$((wartezeiten + 1))
        [ "$wartezeiten" -gt 20 ] && { melde crit "Nutzungslimit hält an, angehalten"; exit 1; }
        notiz "Nutzungslimit, warte $((WARTEN / 60)) min"; sleep "$WARTEN"; continue
    fi

    # Skript-Prüfer: nur grüne, nicht abgeschwächte Arbeit in erlaubten Pfaden zählt.
    g add -A
    aufgabe=$(g diff --cached --no-ext-diff -U0 -- "$AUFGABEN" | grep -m1 '^+- \[[x~]\]' | cut -c4-90)
    if [ -z "$aufgabe" ]; then verwerfen "$vorher" "keine Aufgabe abgehakt oder blockiert (rc $rc)" "$LOGS/durchlauf-$i.txt"; continue; fi
    fremd=$(geaendert | grep -Ev "$ERLAUBT")
    if [ -n "$fremd" ]; then verwerfen "$vorher" "Änderung außerhalb erlaubter Pfade: $(echo $fremd)"; continue; fi
    gesperrt=$( { geaendert | grep -E "$IMMER_GESPERRT"
                  for p in ${GESPERRT[@]+"${GESPERRT[@]}"} ${ABNAHME_DATEIEN[@]+"${ABNAHME_DATEIEN[@]}"}; do geaendert "$p"; done; } | sort -u)
    if [ -n "$gesperrt" ]; then verwerfen "$vorher" "gesperrte Datei geändert: $(echo $gesperrt)"; continue; fi
    hinzu=$(g diff --cached --no-ext-diff --no-renames -U0 -- . ":(exclude)$AUFGABEN" ":(exclude)BLOCKED.md" ":(exclude)ENTSCHEIDUNGEN.md" |
        grep '^+' | grep -v '^+++' | sed 's/^+//')
    if [ -n "$VERBOTEN_INHALT" ] && grep -qE "$VERBOTEN_INHALT" <<<"$hinzu"; then
        verwerfen "$vorher" "verbotener Inhalt hinzugefügt (Muster: $VERBOTEN_INHALT)"; continue
    fi
    # Neuer Code, der die Zählzeile selbst ausgibt, könnte die Prüfung fälschen (Muster ohne ^/$, denn im Code
    # steht die Zeile mitten in einem print/echo)
    imitat_p=${PRUEF_ZAHL#^}; imitat_p=${imitat_p%\$}; imitat_a=${ABNAHME_ZAHL#^}; imitat_a=${imitat_a%\$}
    if { [ -z "$PRUEF_ZAEHLER" ] && grep -qE "$imitat_p" <<<"$hinzu"; } || { [ -n "$ABNAHME" ] && grep -qE "$imitat_a" <<<"$hinzu"; }; then
        verwerfen "$vorher" "neuer Code enthält die Zählzeile des Prüfbefehls oder Abnahmetests (könnte das Ergebnis fälschen)"; continue
    fi
    neu=$(pruefen "$LOGS/pruefung-$i.txt")
    if [ -z "$neu" ]; then verwerfen "$vorher" "Prüfung rot oder ohne lesbare Zahl" "$LOGS/pruefung-$i.txt"; continue; fi
    if [ "$neu" -lt "$zahl" ]; then verwerfen "$vorher" "Prüfungen von $zahl auf $neu gesunken"; continue; fi
    haken=$(( $(grep -c '^- \[x\]' "$AUFGABEN") - $(g show "$vorher:$AUFGABEN" | grep -c '^- \[x\]') ))
    if [ "$haken" -gt 0 ] && [ "$neu" -le "$zahl" ]; then verwerfen "$vorher" "Aufgabe abgehakt ohne neue Prüfung"; continue; fi
    abn_neu=$(abnahme "$LOGS/abnahme-$i.txt")
    if [ "$abn_neu" -lt "$abn" ]; then verwerfen "$vorher" "Abnahme von $abn auf $abn_neu gesunken" "$LOGS/abnahme-$i.txt"; continue; fi
    if [ "$haken" -gt 0 ] && [ "$SPIELTEST_ALLE" -gt 0 ] && [ $(( (angenommen + 1) % SPIELTEST_ALLE )) -eq 0 ]; then
        grund=''; spieltest; ok=$?; zusatzkosten
        [ "$ok" = 0 ] || { verwerfen "$vorher" "$grund" "$LOGS/spieltest-$i.txt"; continue; }
    fi

    # Gutachter: nur für erledigte Aufgaben; zwei Ablehnungen derselben Aufgabe blockieren sie.
    if [ "$haken" -gt 0 ]; then
        g add -A
        urteil=$(gutachten); zusatzkosten
        if [ "${urteil:-}" != "URTEIL: ANNEHMEN" ]; then
            grund=${urteil#URTEIL: ABLEHNEN: }; [ -n "$grund" ] || grund="kein Urteil, siehe log/gutachten-$i.txt"
            ablehnungen=$((ablehnungen + 1))
            verwerfen "$vorher" "Gutachter: $grund"
            [ "$ablehnungen" -ge 2 ] && blockieren "Gutachter lehnte zweimal ab: $grund"
            continue
        fi
    fi

    g add -A && g commit -q --no-verify -m "Autopilot: $aufgabe" -m "Prüfungen $zahl -> $neu${ABNAHME:+, Abnahme $abn -> $abn_neu von ${ziel:-?}}" ||
        { verwerfen "$vorher" "Commit fehlgeschlagen"; continue; }
    notiz "Durchlauf $i angenommen: $aufgabe | Prüfungen $zahl -> $neu${ABNAHME:+, Abnahme $abn -> $abn_neu von ${ziel:-?}} | $kosten USD"
    if [ -n "$ABNAHME" ] && [ "$abn_neu" -le "$abn" ] && [ "$abn_neu" != "${ziel:-x}" ]; then ohne_fortschritt=$((ohne_fortschritt + 1)); else ohne_fortschritt=0; fi
    [ "$STILLSTAND" -gt 0 ] && [ "$ohne_fortschritt" -eq "$STILLSTAND" ] &&
        melde warn "Stillstand: seit $STILLSTAND angenommenen Durchläufen steigt die Abnahme nicht (bleibt bei $abn_neu von ${ziel:-?})"
    zahl=$neu; abn=$abn_neu; fehler=0; angenommen=$((angenommen + 1)); rm -f "$RUECK"
    protokoll angenommen; [ "$haken" -gt 0 ] && benoten 1
    [ "$haken" -gt 0 ] && fahrstunde
done
melde info "Obergrenze von $MAX Durchläufen erreicht ($zahl Prüfungen${ABNAHME:+, Abnahme $abn von ${ziel:-?}})"
