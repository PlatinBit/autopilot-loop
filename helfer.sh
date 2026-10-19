# Hilfsfunktionen für alle Skripte von autopilot-loop (ohne Konfiguration nutzbar).
# Grundsatz: Arbeitsordner, Plan und alles, was Claude schreibt, gelten als nicht vertrauenswürdig.

if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
    echo "autopilot-loop braucht Bash 4.4 oder neuer (macOS: brew install bash)." >&2
    exit 1
fi

# SHA-256 (Linux: sha256sum, macOS: shasum); nur_summe gibt nur den Hash aus, ohne Argument von stdin.
pruefsumme() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
nur_summe() { pruefsumme "$@" | cut -c1-64; }

# timeout gibt es auf macOS nur als gtimeout (coreutils); ohne beides läuft der Befehl ohne Zeitlimit.
zeitlimit() { # DAUER BEFEHL …
    if command -v timeout >/dev/null; then timeout "$@"
    elif command -v gtimeout >/dev/null; then gtimeout "$@"
    else shift; "$@"; fi
}

# Git ohne Hooks, fsmonitor, externe Diff-Programme und Pager: Ein präparierter Arbeitsordner darf darüber
# keinen Code ausführen, wenn das Skript prüft oder committet.
g() { git -c core.hooksPath=/dev/null -c core.fsmonitor= -c diff.external= -c core.pager=cat "$@"; }

# Jeder Claude-Lauf: nur die eigenen Benutzer-Einstellungen (nie .claude/ aus dem Arbeitsordner, dessen Hooks
# sonst ausgeführt würden), und nie Schreiben in Git-, Claude- oder Autopilot-Verwaltungsdateien.
CLAUDE_SICHER=(--setting-sources user --disallowedTools
    "Edit(.git)" "Write(.git)" "Edit(.git/**)" "Write(.git/**)" "Edit(.claude/**)" "Write(.claude/**)"
    "Edit(.autopilot/**)" "Write(.autopilot/**)" "Edit(autopilot.conf)" "Write(autopilot.conf)")

# claude -p mit JSON-Ausgabe; der Auftrag kommt über stdin (kein Längenlimit für Argumente).
# Antworttext nach TEXTDATEI, Kosten in USD auf stdout (0 wenn unbekannt). Rückgabe: Exit-Code von claude.
# Zeitlimit über CLAUDE_ZEIT (Standard 20m).
claude_lauf() { # TEXTDATEI [claude-Argumente …] <auftrag
    local text=$1 roh=$1.json rc; shift
    zeitlimit "${CLAUDE_ZEIT:-20m}" claude -p --output-format json "$@" "${CLAUDE_SICHER[@]}" >"$roh" 2>&1; rc=$?
    if jq -e . "$roh" >/dev/null 2>&1; then
        jq -r '.result // ""' "$roh" >"$text"
        jq -r '.total_cost_usd // 0' "$roh"
    else
        cp "$roh" "$text"; echo 0
    fi
    return $rc
}

# Meldet die Antwort ein Nutzungslimit? Geprüft wird das Fehlerfeld bzw. die Fehlermeldung der CLI selbst,
# nicht der Text des Modells (sonst könnte ein Plan per Text endloses Warten auslösen).
nutzungslimit() { # TEXTDATEI (von claude_lauf)
    local roh=$1.json
    if jq -e . "$roh" >/dev/null 2>&1; then
        jq -e '(.is_error == true) and ((.result // "") | test("limit"; "i"))' "$roh" >/dev/null
    else
        grep -qi 'limit' "$roh"
    fi
}

# Vertrauen in Konfigurationsdateien: Eine autopilot.conf wird mit `source` geladen, also nur, wenn ihre
# Prüfsumme bestätigt ist (nach `autopilot plan annehmen` automatisch, sonst mit `autopilot vertrauen`).
VERTRAUT=${XDG_CONFIG_HOME:-$HOME/.config}/autopilot-loop/vertraut
vertraut() { [ -f "$1" ] && grep -qxF "$(nur_summe <"$1") $(readlink -f "$1")" "$VERTRAUT" 2>/dev/null; }
vertrauen() { # DATEI
    local pfad; pfad=$(readlink -f "$1") && [ -f "$pfad" ] || { echo "Datei nicht gefunden: $1" >&2; return 1; }
    mkdir -p "$(dirname "$VERTRAUT")"
    { awk -v p="$pfad" 'substr($0, 66) != p' "$VERTRAUT" 2>/dev/null; echo "$(nur_summe <"$pfad") $pfad"; } >"$VERTRAUT.neu" &&
        mv "$VERTRAUT.neu" "$VERTRAUT"
}

# Erste offene Aufgabe als blockiert markieren (portabel, ohne GNU-sed)
erste_offene_blockieren() { # DATEI
    awk '!d && /^- \[ \]/ { sub(/^- \[ \]/, "- [~]"); d = 1 } 1' "$1" >"$1.neu" && mv "$1.neu" "$1"
}
