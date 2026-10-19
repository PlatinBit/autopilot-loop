#!/usr/bin/env bash
# autopilot-loop – Menü und Befehle. Läuft im normalen Terminal, ohne Claude-Sitzung.
#
#   autopilot                          Menü (whiptail)
#   autopilot plan <datei>             neues Vorhaben aus einer Plan-Datei entwerfen (dann: plan annehmen)
#   autopilot vertrauen [datei]        eine selbst geschriebene oder geänderte autopilot.conf freigeben
#   autopilot start <durchläufe> [gutachter: sonnet|opus|haiku] [max-ablehnungen] [umsetzer: opus|sonnet]
#   autopilot status [--kurz] | stop | abbrechen | weiter | freigeben | bedingungen
#   autopilot noten | kosten | kurve | notizen | ergebnis | planen | vorschlag [annehmen|verwerfen]
#   autopilot bericht [--wenn-neu]     Zusammenfassung der letzten 24 Stunden (für cron)
#   autopilot einrichten               autopilot.conf von Hand im aktuellen Ordner anlegen
set -u
HIER=$(dirname "$(readlink -f "$0")")
KONF_BASIS=${XDG_CONFIG_HOME:-$HOME/.config}/autopilot-loop
# shellcheck source=helfer.sh
. "$HIER/helfer.sh"

case "${1:-}" in
    plan) shift; exec "$HIER/vorhaben.sh" "$@" ;;
    einrichten)
        [ -e autopilot.conf ] && { echo "autopilot.conf gibt es hier schon."; exit 1; }
        cp "$HIER/vorlagen/autopilot.conf" autopilot.conf
        echo "autopilot.conf angelegt: PRUEFEN, ERLAUBT und ARBEITSORDNER eintragen, dann: autopilot vertrauen"
        echo "Einfacher: autopilot plan <plan-datei>"
        exit 0 ;;
    vertrauen)
        k=${2:-}
        [ -n "$k" ] || for k in "${AUTOPILOT_CONF:-}" "$PWD/autopilot.conf" "$KONF_BASIS/standard.conf"; do [ -f "$k" ] && break; done
        [ -f "$k" ] || { echo "Keine autopilot.conf gefunden."; exit 1; }
        echo "Diese Datei wird bei jedem Aufruf als Bash-Code ausgeführt: $(readlink -f "$k")"
        vertrauen "$k" && echo "Als vertrauenswürdig eingetragen (gilt, bis sie sich ändert)."
        exit $? ;;
    hilfe|-h|--help) sed -n '2,12p' "$0" | cut -c3-; exit 0 ;;
esac

hat_vorhaben() { [ -f "${AUTOPILOT_CONF:-/nix}" ] || [ -f "$PWD/autopilot.conf" ] || [ -f "$KONF_BASIS/standard.conf" ]; }

# --- Ohne Vorhaben: nur „Neues Vorhaben“ anbieten ---------------------------------------------------
neues_vorhaben() { # im Menü: Pfad erfragen, entwerfen, zeigen, annehmen
    local datei t
    datei=$(whiptail --title "Autopilot" --inputbox "Pfad zur Plan-Datei (z. B. ~/projekt/README.md):" 10 78 3>&1 1>&2 2>&3) || return
    datei=${datei/#\~/$HOME}
    t=$(mktemp) || return
    clear; "$HIER/vorhaben.sh" "$datei" | tee "$t" || { read -rp "Weiter mit Enter …" _; rm -f "$t"; return; }
    whiptail --title "Autopilot" --scrolltext --yesno "$(cat "$t")\n\nSo einrichten?" 30 110 &&
        whiptail --title "Autopilot" --msgbox "$("$HIER/vorhaben.sh" annehmen 2>&1)" 12 90
    rm -f "$t"
}
if [ -z "${1:-}" ] && ! hat_vorhaben; then
    whiptail --title "Autopilot" --yesno "Noch kein Vorhaben eingerichtet.\n\nNeues Vorhaben aus einer Plan-Datei anlegen?" 10 70 && neues_vorhaben
    exit 0
fi

# shellcheck source=gemeinsam.sh
. "$HIER/gemeinsam.sh"
TITEL="Autopilot – $NAME"

durchlauf_stand() { # „Durchlauf 14/15“ des laufenden Laufs
    local max nr
    max=$(grep 'Start: ' "$ZUSTAND/log/verlauf.txt" 2>/dev/null | tail -1 | grep -o 'höchstens [0-9]*' | grep -o '[0-9]*')
    nr=$(sed -n 's/^.* Durchlauf \([0-9]*\): .*/\1/p' "$ZUSTAND/log/verlauf.txt" 2>/dev/null | tail -1)
    echo "Durchlauf ${nr:-0}/${max:-?}"
}
abnahme_stand() {
    grep -o 'Abnahme [0-9]* -> [0-9]* von [0-9?]*\|Abnahme [0-9]* von [0-9?]*' "$ZUSTAND/log/verlauf.txt" 2>/dev/null | tail -1 |
        sed 's/Abnahme \([0-9]*\) -> \([0-9]*\)/Abnahme \2/'
}

status() {
    if [ "${1:-}" = --kurz ]; then  # eine Zeile für die Statuszeile in Claude Code; leer, wenn nichts läuft
        laeuft || return 0
        if [ -e "$ZUSTAND/WARTET" ]; then echo "Autopilot $NAME: wartet auf dein OK (Fahrstunde)"
        else echo "Autopilot $NAME: $(durchlauf_stand)$( [ -n "$ABNAHME" ] && echo " · $(abnahme_stand)")"; fi
        return 0
    fi
    echo "Zustand:     $(laeuft && echo 'läuft' || echo 'aus')$( [ -e "$ZUSTAND/STOP" ] && echo ' (hält nach diesem Durchlauf an)')$( [ -e "$ZUSTAND/WARTET" ] && echo ' – WARTET auf dein OK (autopilot weiter)')"
    [ ${#ABNAHME_DATEIEN[@]} -gt 0 ] && echo "Abnahmetest: $(freigegeben && echo 'freigegeben' || echo 'NICHT freigegeben')   $(abnahme_stand)"
    [ -n "$PLAN_DATEI" ] && echo "Plan:        $PLAN_DATEI"
    echo "Aufgaben:    $(grep -c '^- \[x\]' "$ARBEITSORDNER/$AUFGABEN") erledigt, $(grep -c '^- \[ \]' "$ARBEITSORDNER/$AUFGABEN") offen, $(grep -c '^- \[~\]' "$ARBEITSORDNER/$AUFGABEN") blockiert"
    echo "Nächste:     $(grep -m1 '^- \[ \]' "$ARBEITSORDNER/$AUFGABEN" | cut -c7-70)"
    [ -s "$ZUSTAND/vorschlag.md" ] && echo "Vorschlag:   $(wc -l <"$ZUSTAND/vorschlag.md") neue Aufgaben vom Planer warten (autopilot vorschlag)"
    echo
    echo "Letzte Ereignisse:"
    tail -8 "$ZUSTAND/log/verlauf.txt" 2>/dev/null | cut -c12-110
}

bedingungen() {
    if [ -n "$BEDINGUNGEN" ]; then (cd "$ARBEITSORDNER" && bash -c "$BEDINGUNGEN")
    elif [ ${#ABNAHME_DATEIEN[@]} -gt 0 ]; then (cd "$ARBEITSORDNER" && find "${ABNAHME_DATEIEN[@]}" -type f | sort)
    else echo "Kein Abnahmetest eingerichtet (ABNAHME_DATEIEN ist leer)."; fi
}
notizen() {
    echo "ENTSCHEIDUNGEN des Autopiloten:"; cat "$ARBEITSORDNER/ENTSCHEIDUNGEN.md" 2>/dev/null || echo "–"
    echo; echo "BLOCKIERT:"; cat "$ARBEITSORDNER/BLOCKED.md" 2>/dev/null || echo "nichts"
}
ergebnis() {
    echo "Neu seit $BASIS_ZWEIG (Zweig $(g -C "$ARBEITSORDNER" branch --show-current)):"
    g -C "$ARBEITSORDNER" log --oneline "$BASIS_ZWEIG..HEAD" | cut -c1-105
    echo; echo "Übernehmen: im Projekt  git merge $(g -C "$ARBEITSORDNER" branch --show-current)"
}
kosten() {
    local csv=$ZUSTAND/log/fortschritt.csv
    [ -s "$csv" ] || { echo "Noch keine Kosten aufgezeichnet."; return; }
    awk -F';' 'NR > 1 { s += $8; t[substr($1, 1, 10)] += $8; m[$10] += $8; n[$10]++ }
        END { printf "Durchläufe gesamt: %.2f USD\n\nJe Tag:\n", s; for (d in t) printf "  %s  %8.2f USD\n", d, t[d]
              printf "\nJe Umsetzer-Modell:\n"; for (k in m) printf "  %-8s %8.2f USD in %d Durchläufen\n", k, m[k], n[k] }' "$csv"
    [ -s "$ZUSTAND/log/kosten-extra.csv" ] &&
        awk -F';' '{ s[$2] += $3 } END { printf "\nSonstiges:\n"; for (k in s) printf "  %-8s %8.2f USD\n", k, s[k] }' "$ZUSTAND/log/kosten-extra.csv"
    echo; echo "(Mit Abo sind das rechnerische Werte, abgerechnet wird über das Nutzungslimit.)"
}
kurve() { python3 "$WERKZEUG/kurve.py" "$ZUSTAND" "$NAME" "$(zahl_aus "$ZUSTAND/log/abnahme-start.txt" "$ABNAHME_ZAHL" 2 2>/dev/null)"; }
aufraeumen() { g -C "$ARBEITSORDNER" reset -q --hard && g -C "$ARBEITSORDNER" clean -qfd; }

vorschlag() {
    case "${1:-}" in
        annehmen)
            [ -s "$ZUSTAND/vorschlag.md" ] || { echo "Kein Vorschlag vorhanden."; return 1; }
            laeuft && { echo "Erst anhalten: Der Autopilot läuft gerade."; return 1; }
            [ -z "$(g -C "$ARBEITSORDNER" status --porcelain)" ] || { echo "Arbeitsordner nicht sauber."; return 1; }
            cat "$ZUSTAND/vorschlag.md" >>"$ARBEITSORDNER/$AUFGABEN"
            g -C "$ARBEITSORDNER" add "$AUFGABEN" && g -C "$ARBEITSORDNER" commit -q -m "Planer: $(wc -l <"$ZUSTAND/vorschlag.md") neue Aufgaben" &&
                { echo "$(wc -l <"$ZUSTAND/vorschlag.md") Aufgaben übernommen. Starten: autopilot start 5"; rm -f "$ZUSTAND/vorschlag.md"; } ;;
        verwerfen) rm -f "$ZUSTAND/vorschlag.md"; echo "Vorschlag verworfen." ;;
        *) if [ -s "$ZUSTAND/vorschlag.md" ]; then echo "Vorschlag des Planers:"; cat "$ZUSTAND/vorschlag.md"
               echo; echo "Übernehmen: autopilot vorschlag annehmen   Verwerfen: autopilot vorschlag verwerfen"
           else echo "Kein Vorschlag vorhanden. Neuen erstellen: autopilot planen"; fi ;;
    esac
}

bericht() { # [--wenn-neu]
    local seit neues text k
    seit=$(python3 -c 'import datetime as d; print((d.datetime.now() - d.timedelta(days=1)).strftime("%Y-%m-%d %H:%M:%S"))')
    neues=$(awk -v s="$seit" 'substr($0, 1, 19) >= s' "$ZUSTAND/log/verlauf.txt" 2>/dev/null)
    [ "${1:-}" = --wenn-neu ] && [ -z "$neues" ] && return 0
    text="Autopilot-Projekt: $NAME$( [ -n "$PLAN_DATEI" ] && echo " (Plan: $(basename "$PLAN_DATEI"))")
## Stand
$(status)
## Ereignisse der letzten 24 Stunden
${neues:-keine}
## Notentafel
$(notentafel)
## Kosten
$(kosten)
## Entscheidungen und Blockiertes
$(notizen | tail -30)"
    k=$(printf '%s\n\nFasse das für den Projektinhaber in höchstens 10 kurzen Zeilen auf Deutsch zusammen: was erledigt wurde, was hakt, was er entscheiden oder ansehen sollte. Keine Einleitung.\n' "$text" |
        claude_lauf "$ZUSTAND/log/bericht.txt" --model "$BERICHT_MODELL") && [ -s "$ZUSTAND/log/bericht.txt" ] ||
        { printf '%s\n' "$text" >"$ZUSTAND/log/bericht.txt"; k=0; }
    echo "$(date '+%F %T');bericht;${k:-0}" >>"$ZUSTAND/log/kosten-extra.csv"
    benachrichtigen info "Bericht: $(cat "$ZUSTAND/log/bericht.txt")" >/dev/null 2>&1 || true
    cat "$ZUSTAND/log/bericht.txt"
}

start_direkt() { # DURCHLÄUFE [GUTACHTER] [ABLEHNUNGEN] [UMSETZER]
    local n=${1:-} gutachter=${2:-sonnet} fehler=${3:-3} umsetzer=${4:-opus}
    [[ "$n" =~ ^[0-9]+$ && "$fehler" =~ ^[0-9]+$ && "$gutachter" =~ ^(sonnet|opus|haiku)$ && "$umsetzer" =~ ^(sonnet|opus)$ ]] ||
        { echo "Aufruf: autopilot start <durchläufe> [gutachter: sonnet|opus|haiku] [max-ablehnungen] [umsetzer: opus|sonnet]"; return 2; }
    laeuft && { echo "Der Autopilot läuft schon."; return 1; }
    freigegeben || { echo "Der Abnahmetest ist noch nicht freigegeben (autopilot freigeben)."; return 1; }
    [ -n "$(g -C "$ARBEITSORDNER" status --porcelain)" ] && { aufraeumen; echo "Reste eines abgebrochenen Durchlaufs verworfen."; }
    rm -f "$ZUSTAND/STOP"
    tmux new -d -s "$SITZUNG" -e "AUTOPILOT_CONF=$KONF" -e "MAX=$n" -e "UMSETZER_MODELL=$umsetzer" \
        -e "GUTACHTER_MODELL=$gutachter" -e "MAX_FEHLER=$fehler" "$HIER/autopilot.sh"
    echo "Gestartet: höchstens $n Durchläufe, Umsetzer $umsetzer, Gutachter $gutachter, Halt nach $fehler Ablehnungen in Folge."
}

case "${1:-}" in
    status) status "${2:-}"; exit 0 ;;
    bedingungen) bedingungen; exit 0 ;;
    notizen) notizen; exit 0 ;;
    ergebnis) ergebnis; exit 0 ;;
    noten) notentafel; exit 0 ;;
    kosten) kosten; exit 0 ;;
    kurve) kurve; exit $? ;;
    planen) (cd "$ARBEITSORDNER" && planen); exit $? ;;
    vorschlag) vorschlag "${2:-}"; exit $? ;;
    bericht) bericht "${2:-}"; exit 0 ;;
    freigeben)
        [ ${#ABNAHME_DATEIEN[@]} -gt 0 ] || { echo "Kein Abnahmetest eingerichtet."; exit 0; }
        abnahme_summe >"$ZUSTAND/FREIGABE"; echo "Abnahmetest freigegeben."; exit 0 ;;
    weiter)
        [ -e "$ZUSTAND/WARTET" ] || { echo "Es wartet gerade nichts auf dein OK."; exit 0; }
        touch "$ZUSTAND/WEITER"; echo "OK gegeben, es geht weiter."; exit 0 ;;
    stop)
        laeuft || { echo "Der Autopilot läuft gerade nicht."; exit 0; }
        touch "$ZUSTAND/STOP"; echo "Hält nach dem laufenden Durchlauf an."; exit 0 ;;
    abbrechen)
        laeuft || { echo "Der Autopilot läuft gerade nicht."; exit 0; }
        tmux kill-session -t "=$SITZUNG"; sleep 1; aufraeumen; rm -f "$ZUSTAND/STOP" "$ZUSTAND/WARTET"
        echo "Abgebrochen, angefangener Durchlauf verworfen."; exit 0 ;;
    start) shift; start_direkt "$@"; exit $? ;;
    "") ;;
    *) sed -n '2,11p' "$0" | cut -c3-; exit 2 ;;
esac

# --- Menü ---------------------------------------------------------------------------------------
zeige() { whiptail --title "$TITEL" --scrolltext --msgbox "$1" 26 110; }
waehle() { whiptail --title "$TITEL" --menu "$1" 14 72 4 "${@:2}" 3>&1 1>&2 2>&3; }

starten() {
    local n umsetzer gutachter fehler
    n=$(waehle "Wie viele Durchläufe höchstens? (eine Aufgabe je Durchlauf)" 5 Empfohlen 10 "" 20 "" 30 "") || return
    umsetzer=$(waehle "Welches Modell setzt die Aufgaben um?" opus "Empfohlen, stärkstes Modell" sonnet "günstiger, schneller") || return
    gutachter=$(waehle "Welches Modell prüft als Gutachter?" sonnet "Empfohlen, ausgewogen" opus "gründlicher, teurer" haiku "günstig, weniger streng") || return
    fehler=$(waehle "Nach wie vielen Ablehnungen in Folge anhalten?" 3 Empfohlen 2 "" 5 "") || return
    zeige "$(start_direkt "$n" "$gutachter" "$fehler" "$umsetzer")\n\nEr läuft weiter, auch wenn du das Terminal schließt."
}

while true; do
    wahl=$(whiptail --title "$TITEL" --menu "$(status)" 34 110 13 \
        1 "Stand aktualisieren" \
        2 "Starten" \
        3 "Weiter (Fahrstunde freigeben)" \
        4 "Sanft anhalten (nach dem laufenden Durchlauf)" \
        5 "Sofort abbrechen" \
        6 "Live zuschauen (zurück mit Strg+b, dann d)" \
        7 "Neues Vorhaben aus einer Plan-Datei" \
        8 "Planer: Vorschlag ansehen, übernehmen oder neu erstellen" \
        9 "Abnahmetest freigeben" \
        10 "Noten, Kosten und Kurve" \
        11 "Entscheidungen und Blockiertes lesen" \
        12 "Ergebnis ansehen" \
        13 "Bericht jetzt erstellen" 3>&1 1>&2 2>&3) || exit 0
    case $wahl in
        2) starten ;;
        3) zeige "$("$0" weiter)" ;;
        4) zeige "$("$0" stop)" ;;
        5) whiptail --title "$TITEL" --defaultno --yesno "Sofort abbrechen? Der laufende Durchlauf wird verworfen." 9 70 && zeige "$("$0" abbrechen)" ;;
        6) if laeuft; then tmux attach -t "=$SITZUNG"; else zeige "Der Autopilot läuft gerade nicht."; fi ;;
        7) neues_vorhaben; exec "$0" ;;
        8) if [ -s "$ZUSTAND/vorschlag.md" ]; then
               whiptail --title "$TITEL" --scrolltext --yesno "$(vorschlag)\n\nÜbernehmen?" 26 110 && zeige "$(vorschlag annehmen)"
           elif whiptail --title "$TITEL" --yesno "Kein Vorschlag vorhanden. Jetzt neue Aufgaben planen lassen? (dauert ein paar Minuten)" 9 70; then
               clear; echo "Der Planer arbeitet …"; zeige "$("$0" planen 2>&1)"; fi ;;
        9) if freigegeben; then zeige "Bereits freigegeben.\n\n$(bedingungen)"
           elif whiptail --title "$TITEL" --scrolltext --yesno "Ziel – diese Bedingungen muss das Projekt erfüllen:\n\n$(bedingungen)\n\nSo freigeben? Danach darf der Autopilot den Test nicht mehr ändern." 26 110; then
               zeige "$("$0" freigeben)"; fi ;;
        10) zeige "NOTENTAFEL\n$(notentafel)\n\nKOSTEN\n$(kosten)\n\nKURVE: $(kurve)" ;;
        11) zeige "$(notizen)" ;;
        12) zeige "$(ergebnis)" ;;
        13) clear; echo "Bericht wird erstellt …"; zeige "$(bericht)" ;;
    esac
done
