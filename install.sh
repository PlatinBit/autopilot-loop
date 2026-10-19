#!/usr/bin/env bash
# Richtet den Befehl `autopilot` ein (Verknüpfung in ~/.local/bin) und prüft, ob alles Nötige da ist.
# Für /autopilot in Claude Code ist das nicht nötig – dort genügt die Plugin-Installation.
set -u
HIER=$(cd "$(dirname "$0")" && pwd -P)
fehlt=0
if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
    echo "fehlt: Bash 4.4 oder neuer (vorhanden: $BASH_VERSION)"; fehlt=1
fi
for b in claude git tmux jq python3; do
    command -v "$b" >/dev/null || { echo "fehlt: $b"; fehlt=1; }
done
command -v timeout >/dev/null || command -v gtimeout >/dev/null || echo "Hinweis: ohne timeout/gtimeout laufen Durchläufe ohne Zeitlimit."
command -v whiptail >/dev/null || echo "Hinweis: ohne whiptail gibt es kein Terminal-Menü (Befehle und /autopilot funktionieren trotzdem)."
if [ "$fehlt" != 0 ]; then
    case "$(uname -s)" in
        Darwin) echo "macOS: brew install bash git tmux jq python coreutils newt  (Claude Code: https://claude.com/claude-code)" ;;
        *) echo "Linux: z. B. sudo apt install git tmux jq python3 whiptail  (Claude Code: https://claude.com/claude-code)" ;;
    esac
fi
mkdir -p "$HOME/.local/bin"
ln -sf "$HIER/menu.sh" "$HOME/.local/bin/autopilot"
echo "Befehl eingerichtet: $HOME/.local/bin/autopilot"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "Hinweis: $HOME/.local/bin in den PATH aufnehmen." ;; esac
cat <<EOF

Nächste Schritte:
  1. Vorhaben aus einer Plan-Datei:  autopilot plan ~/mein-projekt/README.md   (Entwurf ansehen, dann: autopilot plan annehmen)
  2. Menü:  autopilot   (in Claude Code: /autopilot nach der Plugin-Installation, siehe README)
  3. Optional täglicher Bericht per cron:  30 7 * * *  PATH=$PATH $HOME/.local/bin/autopilot bericht --wenn-neu
EOF
