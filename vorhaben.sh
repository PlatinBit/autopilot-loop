#!/usr/bin/env bash
# Neues Vorhaben aus einer Plan-Datei (z. B. README.md): Claude liest Plan und Projekt und entwirft
# Aufgabenliste, Prüfbefehl und erlaubte Pfade. Eingerichtet wird erst nach deinem OK.
#
#   autopilot plan <datei>      Entwurf erstellen und anzeigen (nur lesend, ändert nichts am Projekt)
#   autopilot plan zeigen       letzten Entwurf anzeigen
#   autopilot plan annehmen     letzten Entwurf einrichten: Arbeitszweig „autopilot“ als Worktree neben dem
#                               Projekt, autopilot.conf, Aufgabenliste; danach meint `autopilot` dieses Vorhaben
set -u
WERKZEUG=$(dirname "$(readlink -f "$0")")
# shellcheck source=helfer.sh
. "$WERKZEUG/helfer.sh"
KONF_BASIS=${XDG_CONFIG_HOME:-$HOME/.config}/autopilot-loop
LETZTER=$KONF_BASIS/letzter-entwurf
AUFGABEN=AUTOPILOT-AUFGABEN.md   # eigener Name, damit keine vorhandene TASKS.md überschrieben wird
mkdir -p "$KONF_BASIS"

fehler() { echo "$1" >&2; exit 1; }
ausschliessen() { # REPO: Statusordner und Konfiguration nie in Git
    local a; a=$(g -C "$1" rev-parse --git-common-dir)/info/exclude
    case "$a" in /*) ;; *) a=$1/$a ;; esac
    mkdir -p "$(dirname "$a")"
    for m in .autopilot/ autopilot.conf; do grep -qxF "$m" "$a" 2>/dev/null || echo "$m" >>"$a"; done
}

# Nur diese Einstellungen dürfen aus dem Entwurf übernommen werden, in genau dieser Form.
# Der Entwurf stammt von Claude (und indirekt aus Plan und Projekt); alles andere wird verworfen.
# Werkzeuge: nur Read, Edit, Write, Glob, Grep und Bash für einen einzelnen Befehl ohne Platzhalter oder Sonderzeichen.
sichere_konf() { # DATEI → gültige Zeilen auf stdout, Verworfenes auf stderr
    local z werkzeug='(Read|Edit|Write|Glob|Grep|'"'"'Bash\((\./)?[A-Za-z0-9_][A-Za-z0-9_./ -]*:\*\)'"'"')'
    while IFS= read -r z; do
        if [[ $z =~ ^(PRUEFEN|PRUEF_ZAEHLER|ERLAUBT|VERBOTEN_INHALT|ABNAHME)=\'[^\']*\'$ ]] ||
           [[ $z =~ ^(PRUEF_ZAHL|ABNAHME_ZAHL)=\'[^\']*\(\[0-9\]\+\)[^\']*\'$ ]] ||
           [[ $z =~ ^UMSETZER_WERKZEUGE=\(\ ?$werkzeug(\ $werkzeug)*\ ?\)$ ]]; then echo "$z"
        elif [ -n "$z" ]; then echo "verworfen: $z" >&2; fi
    done <"$1"
}

zeigen() { # ENTWURFSORDNER
    local e=$1
    echo "Entwurf für: $(cat "$e/plan")"
    echo
    echo "Einstellungen (PRUEFEN, PRUEF_ZAEHLER und ABNAHME werden als Shell-Befehle ausgeführt – bitte genau lesen):"
    sed 's/^/  /' "$e/autopilot.teil"
    echo
    echo "Aufgaben ($(grep -c '^- \[ \]' "$e/aufgaben.md")):"; grep '^- \[ \]' "$e/aufgaben.md" | cut -c1-140 | sed 's/^/  /'
    [ -s "$e/verworfen.txt" ] && { echo; echo "Aus Sicherheitsgründen nicht übernommen:"; sed 's/^/  /' "$e/verworfen.txt"; }
    echo
    echo "Ganz lesen: $e/aufgaben.md   Einrichten: autopilot plan annehmen   Neu entwerfen: autopilot plan <datei>"
}

entwerfen() { # PLANDATEI
    local datei repo rel e auftrag kosten
    datei=$(readlink -f "${1/#\~/$HOME}") && [ -f "$datei" ] || fehler "Datei nicht gefunden: $1"  # ~ auch ohne Shell (Plugin)
    repo=$(g -C "$(dirname "$datei")" rev-parse --show-toplevel 2>/dev/null) ||
        fehler "$datei liegt in keinem Git-Projekt. Zuerst: cd $(dirname "$datei") && git init && git add -A && git commit -m Start"
    g -C "$repo" rev-parse -q --verify HEAD >/dev/null || fehler "Das Git-Projekt hat noch keinen Commit (git add -A && git commit -m Start)."
    rel=${datei#"$repo"/}
    e=$repo/.autopilot/entwurf
    ausschliessen "$repo"
    rm -rf "$e"; mkdir -p "$e"
    echo "$datei" >"$e/plan"
    echo "Claude liest $rel und das Projekt und entwirft die Aufgaben (dauert ein paar Minuten) …"
    auftrag="$(cat "$WERKZEUG/vorlagen/EINRICHTEN.md")

## Plan-Datei: $rel
$(cat "$datei")

## Dateien im Projekt (Auszug)
$(g -C "$repo" ls-files | head -300)"
    kosten=$(cd "$repo" && claude_lauf "$e/antwort.txt" --model "${UMSETZER_MODELL:-opus}" --allowedTools Read Grep Glob <<<"$auftrag") ||
        fehler "Claude ist mit einem Fehler beendet, siehe $e/antwort.txt"
    sed -n '/^===KONF===/,/^===AUFGABEN===/p' "$e/antwort.txt" | sed '1d;$d' >"$e/konf.roh"
    sed -n '/^===AUFGABEN===/,$p' "$e/antwort.txt" | sed '1d' >"$e/aufgaben.md"
    sichere_konf "$e/konf.roh" >"$e/autopilot.teil" 2>"$e/verworfen.txt"
    grep -q '^PRUEFEN=' "$e/autopilot.teil" || fehler "Der Entwurf enthält keinen gültigen Prüfbefehl, siehe $e/antwort.txt"
    grep -q '^- \[ \] ' "$e/aufgaben.md" || fehler "Der Entwurf enthält keine Aufgaben, siehe $e/antwort.txt"
    echo "$repo" >"$LETZTER"
    echo "Entwurf fertig (Kosten ca. $kosten USD)."; echo
    zeigen "$e"
}

annehmen() {
    local repo e datei rel name basis wt erlaubt
    repo=$(cat "$LETZTER" 2>/dev/null) && [ -d "$repo/.autopilot/entwurf" ] || fehler "Kein Entwurf vorhanden (autopilot plan <datei>)."
    e=$repo/.autopilot/entwurf
    datei=$(cat "$e/plan"); rel=${datei#"$repo"/}
    name=$(basename "$repo" | tr -c 'A-Za-z0-9._-' '-'); name=${name%-}  # auch Name der tmux-Sitzung
    basis=$(g -C "$repo" branch --show-current); basis=${basis:-main}
    wt=$repo-autopilot
    if [ ! -d "$wt" ]; then
        if g -C "$repo" rev-parse -q --verify autopilot >/dev/null; then g -C "$repo" worktree add -q "$wt" autopilot
        else g -C "$repo" worktree add -q "$wt" -b autopilot; fi || fehler "Arbeitszweig konnte nicht angelegt werden."
    fi
    [ -z "$(g -C "$wt" status --porcelain)" ] || fehler "Der Arbeitsordner $wt hat nicht committete Änderungen."
    cp "$e/aufgaben.md" "$wt/$AUFGABEN"
    g -C "$wt" add "$AUFGABEN" && g -C "$wt" commit -q --no-verify -m "Autopilot: Aufgaben aus $rel" ||
        fehler "Commit fehlgeschlagen – ist eine Git-Identität gesetzt? (git config --global user.name / user.email)"
    erlaubt=$(sed -n "s/^ERLAUBT='\(.*\)'$/\1/p" "$e/autopilot.teil")
    # Pfade und Namen stammen aus Dateisystem und Git (Branch-Namen dürfen ' $ ( enthalten): immer mit %q quotieren,
    # denn die Datei wird später mit `source` geladen.
    {
        printf '# Vorhaben aus %s, eingerichtet %s mit autopilot plan\n' "$(printf %q "$rel")" "$(date '+%F %T')"
        printf 'NAME=%q\nARBEITSORDNER=%q\nBASIS_ZWEIG=%q\nAUFGABEN=%q\nPLAN_DATEI=%q\nGESPERRT=(%q)\n' \
            "$name" "$wt" "$basis" "$AUFGABEN" "$datei" "$rel"
        grep -v '^ERLAUBT=' "$e/autopilot.teil"
        echo "ERLAUBT='(${erlaubt:-^$})|^(${AUFGABEN//./\\.}|BLOCKED\\.md|ENTSCHEIDUNGEN\\.md)\$'"
    } >"$repo/autopilot.conf"
    vertrauen "$repo/autopilot.conf"  # du hast den Entwurf gerade angenommen
    ln -sf "$repo/autopilot.conf" "$KONF_BASIS/standard.conf"
    rm -rf "$e"; rm -f "$LETZTER"
    echo "Eingerichtet: $repo/autopilot.conf, Arbeitszweig „autopilot“ in $wt"
    echo "Starten: autopilot (Menü) oder autopilot start 5"
}

case "${1:-}" in
    "") sed -n '2,10p' "$0" | cut -c3-; exit 2 ;;
    zeigen) repo=$(cat "$LETZTER" 2>/dev/null) && [ -d "$repo/.autopilot/entwurf" ] || fehler "Kein Entwurf vorhanden."
            zeigen "$repo/.autopilot/entwurf" ;;
    annehmen) annehmen ;;
    *) entwerfen "$1" ;;
esac
