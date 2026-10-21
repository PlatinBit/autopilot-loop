#!/usr/bin/env bash
# Sets up the `autopilot` command (symlink in ~/.local/bin) and checks that everything needed is present.
# Not needed for /autopilot-loop in Claude Code – the plugin installation is enough there.
set -u
HERE=$(cd "$(dirname "$0")" && pwd -P)
missing=0
if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
    echo "missing: Bash 4.4 or newer (found: $BASH_VERSION)"; missing=1
fi
for b in claude git tmux jq; do
    command -v "$b" >/dev/null || { echo "missing: $b"; missing=1; }
done
command -v timeout >/dev/null || command -v gtimeout >/dev/null || echo "Note: without timeout/gtimeout, runs have no time limit."
if [ "$missing" != 0 ]; then
    case "$(uname -s)" in
        Darwin) echo "macOS: brew install bash git tmux jq coreutils  (Claude Code: https://claude.com/claude-code)" ;;
        *) echo "Linux: e.g. sudo apt install git tmux jq  (Claude Code: https://claude.com/claude-code)" ;;
    esac
fi
mkdir -p "$HOME/.local/bin"
ln -sf "$HERE/menu.sh" "$HOME/.local/bin/autopilot"
echo "Command set up: $HOME/.local/bin/autopilot"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "Note: add $HOME/.local/bin to your PATH." ;; esac
cat <<EOF

Next steps:
  1. Project from a plan file:  autopilot plan ~/my-project/README.md   (read the draft, then: autopilot plan accept)
  2. In the project folder:     autopilot start, later autopilot status and autopilot handover
  3. All commands:              autopilot help   (in Claude Code: /autopilot-loop after installing the plugin)
EOF
