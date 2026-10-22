#!/usr/bin/env bash
# autopilot-loop – the `autopilot` command (in Claude Code: /autopilot-loop <command>).
#
#   autopilot plan <file> | plan "<idea>"   draft a project from a plan file, or from a few sentences
#   autopilot plan [accept|discard]          show / set up or adopt / throw away the draft or the planner's suggestion
#   autopilot start                          run the loop in the background (tmux) until done or a cap is hit
#   autopilot status [--short]               where it stands; after the end: outcome, tasks, tests, cost, tokens
#   autopilot stop [--now]                   stop after the current run / now (the unfinished run is discarded)
#   autopilot handover                       the result: what was built, how to try it, the proof, what is open
#   autopilot doctor                         check tools, versions and the project's test command
#   autopilot trust [file]                   confirm a hand-written or changed autopilot.conf (it is Bash code)
#   autopilot help                           this help
# The project is ./autopilot.conf (or one in a folder above, up to the Git root), or $AUTOPILOT_CONF.
set -u
HERE=$(dirname "$(readlink -f "$0")")
# shellcheck source=lib.sh
. "$HERE/lib.sh"
NO_PROJECT="No project found here (autopilot.conf in this folder or above, or AUTOPILOT_CONF). Create one: autopilot plan <file>"

# --- Doctor: checklist of everything autopilot-loop needs (works without a project) ----------------
doc_row() { # COMMAND PURPOSE [INSTALL]: ✔ with version, or ✘ with the install command (returns 1)
    local v
    if command -v "$1" >/dev/null; then
        v=$({ "$1" --version 2>/dev/null || "$1" -V 2>/dev/null; } </dev/null | grep -oE '[0-9]+\.[0-9][0-9A-Za-z.]*' | head -1)
        printf ' ✔ %-9s %-8s %s\n' "$1" "${v:--}" "$2"
    else
        printf ' ✘ %-9s %-8s %s – %s\n' "$1" - "$2" "${3:-$(install_hint "$(pkg_of "$1")")}"
        return 1
    fi
}
doc_project() { # with a trusted configuration: work directory, sandbox state and a one-shot probe of TEST_CMD
    local k
    k=$(find_conf) || { echo "Project: none here (autopilot plan <file>) – only the tools above were checked."; return 0; }
    is_trusted "$k" || { echo "Project: $k is not confirmed as trusted – test command not probed (autopilot trust)."; return 0; }
    echo "Project: $k"
    (set +u; SANDBOX=''; WORKDIR=.; cd "$(dirname "$k")" && . "$k" </dev/null >/dev/null 2>&1
     under_claude_dir "$WORKDIR" && echo "  ✘ WORKDIR $(readlink -f "$WORKDIR") lies below ~/.claude/: Claude Code refuses every write there – move the project"
     if [ "$SANDBOX" = off ]; then echo "  SANDBOX=off (test commands run unsandboxed)"
     elif sandbox_works; then echo "  sandbox on (bwrap works)"
     else echo "  no sandbox: bwrap is missing or cannot start here – $(install_hint bubblewrap), or set SANDBOX=off"; fi
     main=$(g -C "$WORKDIR" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')
     [ "${MERGE:-ff}" = ff ] && [ -n "$main" ] && [ -n "$(g -C "$main" status --porcelain 2>/dev/null)" ] &&
         echo "  ✘ MERGE=ff: $main has uncommitted or untracked files – a delivered result is not merged until they are committed or removed")
    probe_test_cmd "$k" | sed 's/^/  /'
}
doctor() {
    local miss=0 t id
    echo "autopilot-loop doctor"
    printf ' ✔ %-9s %-8s %s\n' bash "${BASH_VERSION%%(*}" "runs all scripts (4.4 or newer)"
    doc_row claude "writes, plans and reviews the code" "https://claude.com/claude-code – then log in once: claude" || miss=1
    if command -v claude >/dev/null; then
        if claude --help 2>/dev/null | grep -q -- '--safe-mode'; then echo " ✔ claude --safe-mode supported (runs without foreign hooks and plugins)"
        else echo " ✘ claude is too old for --safe-mode (needs Claude Code >= 2.1) – update it"; miss=1; fi
    fi
    doc_row git "work branch, checks and commit of every run" || miss=1
    doc_row jq "reads Claude's JSON answers" || miss=1
    doc_row tmux "keeps the loop running in the background (start)" || miss=1
    t=timeout; command -v timeout >/dev/null || t=gtimeout
    doc_row "$t" "time limits for runs and commands (optional, coreutils)" "$(install_hint coreutils)"
    doc_row bwrap "sandbox for test commands (optional, Linux, used when it works)"
    if id=$(git var GIT_COMMITTER_IDENT 2>/dev/null); then echo " ✔ git identity: $(sed 's/ [0-9].*//' <<<"$id")"
    else echo " ✘ git identity not set – git config --global user.email you@example.org; git config --global user.name \"Your Name\""; miss=1; fi
    doc_project
    if [ "$miss" = 0 ]; then echo "Everything required is present."
    else echo "Required pieces are missing (✘ above) – install them, then check again: autopilot doctor"; return 1; fi
}

# --- status, stop, handover: read only .autopilot/ (never autopilot.conf, which may change during a run) ---
state_of() { local c; c=$(find_conf) && echo "$(dirname "$c")/.autopilot"; }
info() { sed -n "s/^$2=//p" "$1/info" 2>/dev/null | head -1; }  # STATE KEY: what autopilot.sh noted at its start
load() { # STATE: facts of the last start
    st=$1; started=$(info "$st" STARTED); name=$(info "$st" NAME | tr -c 'A-Za-z0-9._\n-' '_')
    tasks=$(info "$st" WORKDIR)/$(info "$st" TASKS_FILE)
    ev=$(tail -n +"$(info "$st" HISTORY_FROM)" "$st/log/history.log" 2>/dev/null)
    run=$(sed -n 's/^.\{20\}Run \([0-9]*\): .*/\1/p' <<<"$ev" | tail -1)
    t0=$(sed -n 's/.* Start: \([0-9]*\) tests green.*/\1/p' <<<"$ev" | head -1)
    t1=$(sed -n 's/.* Tests [0-9]* -> \([0-9]*\).*/\1/p' <<<"$ev" | tail -1); t1=${t1:-$t0}
    acc=$(grep -o 'Accept [0-9]* -> [0-9]* of [0-9?]*\|Accept [0-9]* of [0-9?]*' <<<"$ev" | tail -1 | sed 's/Accept [0-9]* -> /Accept /')
    spent=$(cost_sum "$st/costs.csv" "$(info "$st" COSTS_FROM)")
    n_done=$(grep -c '^- \[x\]' "$tasks" 2>/dev/null); n_open=$(grep -c '^- \[ \]' "$tasks" 2>/dev/null)
    n_blocked=$(grep -c '^- \[~\]' "$tasks" 2>/dev/null)
}
outcome_text() { # STATE → "delivered" | "not delivered (reason)" | "stopped (reason)" …; empty while running or before any end
    local o='' why=''
    lock_alive "$1" && return 0
    [ -r "$1/outcome" ] && IFS=$'\t' read -r o why <"$1/outcome" || return 0
    [ "$o" = delivered ] && why=''  # a delivery needs no reason
    echo "${o/not-delivered/not delivered}${why:+ ($(shorten 100 <<<"$why"))}"
}
status_short() { # one line per project in running/ (the Claude Code status line and finish toast read these)
    local f st o
    for f in "$CONF_BASE"/running/*; do
        [ -f "$f" ] || continue
        st=$(dirname "$(head -1 "$f")")/.autopilot
        [ -s "$st/info" ] || { rm -f "$f"; continue; }  # project gone
        load "$st"
        if lock_alive "$st"; then
            echo "Autopilot $name: run ${run:-0}/$(info "$st" MAX_RUNS)${acc:+ · $acc} · $spent USD$( [ -e "$st/STOP" ] && echo ' · stops after this run')"
        else
            o=$(outcome_text "$st")
            echo "Autopilot $name ended: ${o:-no result (see autopilot status)} - ${n_done:-?} done, ${n_blocked:-?} blocked, tests ${t0:-?} -> ${t1:-?}, $spent USD"
        fi
    done
}
status() {
    local st s plan demo o next
    if ! st=$(state_of); then
        echo "$NO_PROJECT"; s=$(status_short); [ -n "$s" ] && printf '\nProjects that ran:\n%s\n' "$s"
        return 3
    fi
    [ -s "$st/info" ] || { echo "Status:      off – not started yet. Start it: autopilot start"; return 0; }
    load "$st"
    if lock_alive "$st"; then
        echo "Status:      running – run ${run:-0} of at most $(info "$st" MAX_RUNS), $spent of at most $(info "$st" MAX_COST_USD) USD$( [ -e "$st/STOP" ] && echo ' (stops after this run)')"
    else
        o=$(outcome_text "$st"); echo "Status:      off"
        echo "Outcome:     ${o:-none (the start ended early, see the events below)}"
    fi
    plan=$(info "$st" PLAN_FILE); [ -n "$plan" ] && echo "Plan:        $plan"
    demo=$(info "$st" DEMO_CMD); echo "Demo:        ${demo:-none}"
    if [ -f "$tasks" ]; then
        echo "Tasks:       $n_done done, $n_open open, $n_blocked blocked"
        [ "$n_open" -gt 0 ] && echo "Next task:   $(grep -m1 '^- \[ \]' "$tasks" | cut_chars 7 70)"
    else echo "Tasks:       task list not found: $tasks (check TASKS_FILE in autopilot.conf)"; fi
    echo "Tests:       ${t0:-?} -> ${t1:-?}"
    [ -n "$acc" ] && echo "Acceptance:  ${acc#Accept }"
    echo "This start:  $started, ${run:-0} runs, $spent USD"
    echo "Cost (all Claude calls of this project):"; cost_table "$st/costs.csv"
    [ -s "$st/suggestion.md" ] && echo "Suggestion:  $(grep -c . "$st/suggestion.md") new tasks from the planner wait: autopilot plan, then autopilot plan accept"
    echo; echo "Latest events:"; tail -8 <<<"$ev" | cut_chars 12 110
    lock_alive "$st" && return 0
    if [ "$(cut -f1 "$st/outcome" 2>/dev/null)" = delivered ]; then next='read the handover and try the result: autopilot handover'
    elif [ "${n_open:-0}" -gt 0 ]; then next="continue: autopilot start ($n_open tasks open)"
    elif [ -s "$st/suggestion.md" ]; then next="read the planner's suggestion: autopilot plan, then autopilot plan accept"
    elif [ "${n_blocked:-0}" -gt 0 ]; then next="read BLOCKED.md ($n_blocked blocked) and the handover: autopilot handover"
    else next='read the handover: autopilot handover'; fi
    echo; echo "Next step:   $next"
}
stop() { # [--now]
    local st pid c
    st=$(state_of) || { echo "$NO_PROJECT" >&2; return 3; }
    lock_alive "$st" || { echo "The autopilot is not running."; return 0; }
    read -r pid <"$st/lock/pid"
    if [ "${1:-}" != --now ]; then touch "$st/STOP"; echo "Stops after the current run (a running demo is ended)."; return 0; fi
    kill -TERM "$pid"  # autopilot.sh ends the worker and resets the work directory itself
    for _ in $(seq 1 10); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
    # Still alive: it waits for a child in the foreground (the reviewer, say); ending the children lets it handle the signal
    if kill -0 "$pid" 2>/dev/null; then for c in $(ps -A -o pid= -o ppid= | awk -v p="$pid" '$2 == p {print $1}'); do kill_tree "$c"; done; fi
    for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
    kill -0 "$pid" 2>/dev/null && { echo "Could not stop the autopilot (PID $pid) – check it: ps -p $pid"; return 1; }
    echo "Stopped now: the unfinished run was discarded (work directory reset to the last commit)."
}
handover() {
    local st; st=$(state_of) || { echo "$NO_PROJECT" >&2; return 3; }
    [ -s "$st/HANDOVER.md" ] || { echo "No handover yet: it is written when a start ends. Start it: autopilot start"; return 0; }
    cat "$st/HANDOVER.md"
}

start_now() {
    # shellcheck source=common.sh
    . "$HERE/common.sh"
    need tmux "autopilot start runs the loop inside it in the background." || return 1
    is_running && { echo "The autopilot is already running."; return 1; }
    [ -n "$(g -C "$WORKDIR" status --porcelain)" ] &&
        { g -C "$WORKDIR" reset -q --hard && g -C "$WORKDIR" clean -qfd; echo "Leftovers of an aborted run discarded (git reset --hard, git clean -fd in $WORKDIR)."; }
    rm -f "$STATE/STOP"
    # PATH from here (a running tmux server would otherwise pass on its own, maybe without claude);
    # the output also goes to console.txt, so that an immediate failure is not lost with the session.
    local console=$STATE/log/console.txt; : >"$console"
    tmux new -d -s "$SESSION" -e "PATH=$PATH" -e "AUTOPILOT_CONF=$CONF" \
        bash -c '{ "$1" 2>&1; echo "autopilot.sh ended with exit code $?"; } | tee -a "$2"' autopilot "$HERE/autopilot.sh" "$console" ||
        { echo "Could not start the tmux session $SESSION."; return 1; }
    for _ in 1 2 3 4 5 6; do sleep 0.5; is_running || break; done
    if ! is_running && ! grep -q 'exit code 0$' "$console"; then
        echo "The autopilot ended right after the start ($console):"; tail -5 "$console"; return 1
    fi
    echo "Started: at most $MAX_RUNS runs or $MAX_COST_USD USD, models $MODELS (planner $PLANNER_MODEL, worker $WORKER_MODEL, reviewer $REVIEWER_MODEL)."
    [ -n "$DEMO_CMD" ] || echo "Warning: DEMO_CMD is not set in $CONF – the run can never end as delivered."
    echo "It keeps running when you close the terminal. Follow it: autopilot status"
}

case "${1:-}" in
    plan) shift; exec "$HERE/plan.sh" "$@" ;;
    start)
        [ $# -eq 1 ] || { echo "autopilot start takes no arguments: runs, cost cap and models are set in autopilot.conf (MAX_RUNS, MAX_COST_USD, MODELS)."; exit 2; }
        start_now ;;
    status) if [ "${2:-}" = --short ]; then status_short; else status; fi ;;
    stop) stop "${2:-}" ;;
    handover) handover ;;
    doctor) doctor ;;
    trust)
        k=${2:-$(find_conf)} && [ -f "$k" ] || { echo "No autopilot.conf found."; exit 1; }
        echo "This file is executed as Bash code on every call: $(readlink -f "$k")"
        trust "$k" && echo "Marked as trusted (valid until it changes)." ;;
    ""|help|-h|--help) sed -n '3,14p' "$0" | cut -c3- ;;
    *) echo "Unknown command: $1"; sed -n '3,14p' "$0" | cut -c3-; exit 2 ;;
esac
