#!/usr/bin/env bash
# autopilot-loop – menu and commands. Runs in a normal terminal, without a Claude session.
#
#   autopilot                          menu (whiptail)
#   autopilot plan <file>              draft a new project from a plan file (then: plan accept)
#   autopilot plan show | plan accept  show the last draft / set it up
#   autopilot trust [file]             approve a hand-written or changed autopilot.conf
#   autopilot start <runs> [reviewer: sonnet|opus|haiku] [max-rejections] [worker: opus|sonnet]
#   autopilot status [--short] | stop | abort | continue | approve | conditions
#   autopilot grades | costs | chart | notes | result | propose | suggestion [accept|discard]
#   autopilot report [--if-new]        summary of the last 24 hours (for cron)
#   autopilot setup                    create autopilot.conf by hand in the current directory
#   autopilot help                     this help
set -u
HERE=$(dirname "$(readlink -f "$0")")
CONF_BASE=${XDG_CONFIG_HOME:-$HOME/.config}/autopilot-loop
# shellcheck source=lib.sh
. "$HERE/lib.sh"

case "${1:-}" in
    plan) shift; exec "$HERE/plan.sh" "$@" ;;
    setup)
        [ -e autopilot.conf ] && { echo "autopilot.conf already exists here."; exit 1; }
        cp "$HERE/templates/autopilot.conf" autopilot.conf
        echo "autopilot.conf created: fill in TEST_CMD, ALLOWED and WORKDIR, then: autopilot trust"
        echo "Easier: autopilot plan <plan-file>"
        exit 0 ;;
    trust)
        k=${2:-}
        [ -n "$k" ] || for k in "${AUTOPILOT_CONF:-}" "$PWD/autopilot.conf" "$CONF_BASE/standard.conf"; do [ -f "$k" ] && break; done
        [ -f "$k" ] || { echo "No autopilot.conf found."; exit 1; }
        echo "This file is executed as Bash code on every call: $(readlink -f "$k")"
        trust "$k" && echo "Marked as trusted (valid until it changes)."
        exit $? ;;
    help|-h|--help) sed -n '2,13p' "$0" | cut -c3-; exit 0 ;;
esac

has_project() { [ -f "${AUTOPILOT_CONF:-/nonexistent}" ] || [ -f "$PWD/autopilot.conf" ] || [ -f "$CONF_BASE/standard.conf" ]; }

# --- Without a project: only offer "New project" ---------------------------------------------------
new_project() { # in the menu: ask for the path, draft, show, accept
    local file t
    file=$(whiptail --title "Autopilot" --inputbox "Path to the plan file (e.g. ~/project/README.md):" 10 78 3>&1 1>&2 2>&3) || return
    file=${file/#\~/$HOME}
    t=$(mktemp) || return
    clear; "$HERE/plan.sh" "$file" | tee "$t" || { read -rp "Press Enter to continue …" _; rm -f "$t"; return; }
    whiptail --title "Autopilot" --scrolltext --yesno "$(cat "$t")\n\nSet it up like this?" 30 110 &&
        whiptail --title "Autopilot" --msgbox "$("$HERE/plan.sh" accept 2>&1)" 12 90
    rm -f "$t"
}
if [ -z "${1:-}" ] && ! has_project; then
    whiptail --title "Autopilot" --yesno "No project set up yet.\n\nCreate a new project from a plan file?" 10 70 && new_project
    exit 0
fi

# shellcheck source=common.sh
. "$HERE/common.sh"
TITLE="Autopilot – $NAME"

run_progress() { # "Run 14/15" of the current run
    local max nr
    max=$(grep 'Start: ' "$STATE/log/history.log" 2>/dev/null | tail -1 | grep -o 'at most [0-9]*' | grep -o '[0-9]*')
    nr=$(sed -n 's/^.* Run \([0-9]*\): .*/\1/p' "$STATE/log/history.log" 2>/dev/null | tail -1)
    echo "Run ${nr:-0}/${max:-?}"
}
accept_progress() {
    grep -o 'Accept [0-9]* -> [0-9]* of [0-9?]*\|Accept [0-9]* of [0-9?]*' "$STATE/log/history.log" 2>/dev/null | tail -1 |
        sed 's/Accept \([0-9]*\) -> \([0-9]*\)/Accept \2/'
}

status() {
    if [ "${1:-}" = --short ]; then  # one line for the Claude Code status line; empty when nothing runs
        is_running || return 0
        if [ -e "$STATE/WAITING" ]; then echo "Autopilot $NAME: waiting for your OK (supervised)"
        else echo "Autopilot $NAME: $(run_progress)$( [ -n "$ACCEPT_CMD" ] && echo " · $(accept_progress)")"; fi
        return 0
    fi
    echo "Status:      $(is_running && echo 'running' || echo 'off')$( [ -e "$STATE/STOP" ] && echo ' (stops after this run)')$( [ -e "$STATE/WAITING" ] && echo ' – WAITING for your OK (autopilot continue)')"
    [ ${#ACCEPT_FILES[@]} -gt 0 ] && echo "Acceptance:  $(is_approved && echo 'approved' || echo 'NOT approved')   $(accept_progress)"
    [ -n "$PLAN_FILE" ] && echo "Plan:        $PLAN_FILE"
    if [ -f "$WORKDIR/$TASKS_FILE" ]; then
        echo "Tasks:       $(grep -c '^- \[x\]' "$WORKDIR/$TASKS_FILE") done, $(grep -c '^- \[ \]' "$WORKDIR/$TASKS_FILE") open, $(grep -c '^- \[~\]' "$WORKDIR/$TASKS_FILE") blocked"
        echo "Next:        $(grep -m1 '^- \[ \]' "$WORKDIR/$TASKS_FILE" | cut -c7-70)"
    else echo "Tasks:       task list not found: $WORKDIR/$TASKS_FILE (check TASKS_FILE in autopilot.conf)"; fi
    [ -s "$STATE/suggestion.md" ] && echo "Suggestion:  $(wc -l <"$STATE/suggestion.md") new tasks from the planner are waiting (autopilot suggestion)"
    echo
    echo "Latest events:"
    tail -8 "$STATE/log/history.log" 2>/dev/null | cut -c12-110
}

conditions() {
    if [ -n "$ACCEPT_LIST_CMD" ]; then (cd "$WORKDIR" && bash -c "$ACCEPT_LIST_CMD")
    elif [ ${#ACCEPT_FILES[@]} -gt 0 ]; then (cd "$WORKDIR" && find "${ACCEPT_FILES[@]}" -type f | sort)
    else echo "No acceptance test set up (ACCEPT_FILES is empty)."; fi
}
notes() {
    echo "DECISIONS made by the autopilot ($DECISIONS_FILE):"; cat "$WORKDIR/$DECISIONS_FILE" 2>/dev/null || echo "–"
    echo; echo "BLOCKED:"; cat "$WORKDIR/BLOCKED.md" 2>/dev/null || echo "nothing"
}
result() {
    echo "New since $BASE_BRANCH (branch $(g -C "$WORKDIR" branch --show-current)):"
    g -C "$WORKDIR" log --oneline "$BASE_BRANCH..HEAD" | cut -c1-105
    echo; echo "To adopt, in the project:  git merge $(g -C "$WORKDIR" branch --show-current)"
}
costs() {
    local csv=$STATE/log/progress.csv
    [ -s "$csv" ] || { echo "No costs recorded yet."; return; }
    awk -F';' 'NR > 1 { s += $8; t[substr($1, 1, 10)] += $8; m[$10] += $8; n[$10]++ }
        END { printf "Runs total: %.2f USD\n\nPer day:\n", s; for (d in t) printf "  %s  %8.2f USD\n", d, t[d]
              printf "\nPer worker model:\n"; for (k in m) printf "  %-8s %8.2f USD in %d runs\n", k, m[k], n[k] }' "$csv"
    [ -s "$STATE/log/costs-extra.csv" ] &&
        awk -F';' '{ s[$2] += $3 } END { printf "\nOther:\n"; for (k in s) printf "  %-8s %8.2f USD\n", k, s[k] }' "$STATE/log/costs-extra.csv"
    echo; echo "(With a subscription these are notional values; billing goes through the usage limit.)"
}
chart() { python3 "$TOOL_DIR/chart.py" "$STATE" "$NAME" "$(number_from "$STATE/log/accept-start.txt" "$ACCEPT_REGEX" 2 2>/dev/null)"; }
clean_up() { g -C "$WORKDIR" reset -q --hard && g -C "$WORKDIR" clean -qfd; }

suggestion() {
    case "${1:-}" in
        accept)
            [ -s "$STATE/suggestion.md" ] || { echo "No suggestion available."; return 1; }
            is_running && { echo "Stop it first: the autopilot is running."; return 1; }
            [ -z "$(g -C "$WORKDIR" status --porcelain)" ] || { echo "Work directory not clean."; return 1; }
            cat "$STATE/suggestion.md" >>"$WORKDIR/$TASKS_FILE"
            g -C "$WORKDIR" add "$TASKS_FILE" && g -C "$WORKDIR" commit -q -m "Planner: $(wc -l <"$STATE/suggestion.md") new tasks" &&
                { echo "$(wc -l <"$STATE/suggestion.md") tasks adopted. Start: autopilot start 5"; rm -f "$STATE/suggestion.md"; } ;;
        discard) rm -f "$STATE/suggestion.md"; echo "Suggestion discarded." ;;
        *) if [ -s "$STATE/suggestion.md" ]; then echo "Planner suggestion:"; cat "$STATE/suggestion.md"
               echo; echo "Adopt: autopilot suggestion accept   Discard: autopilot suggestion discard"
           else echo "No suggestion available. Create one: autopilot propose"; fi ;;
    esac
}

report() { # [--if-new]
    local since recent text k
    since=$(python3 -c 'import datetime as d; print((d.datetime.now() - d.timedelta(days=1)).strftime("%Y-%m-%d %H:%M:%S"))')
    recent=$(awk -v s="$since" 'substr($0, 1, 19) >= s' "$STATE/log/history.log" 2>/dev/null)
    [ "${1:-}" = --if-new ] && [ -z "$recent" ] && return 0
    text="Autopilot project: $NAME$( [ -n "$PLAN_FILE" ] && echo " (plan: $(basename "$PLAN_FILE"))")
## Status
$(status)
## Events of the last 24 hours
${recent:-none}
## Grades
$(grade_table)
## Costs
$(costs)
## Decisions and blocked tasks
$(notes | tail -30)"
    k=$(printf '%s\n\nSummarise this for the project owner in at most 10 short lines: what was done, what is stuck, what they should decide or look at. No introduction.\n' "$text" |
        claude_run "$STATE/log/report.txt" --model "$REPORT_MODEL") && [ -s "$STATE/log/report.txt" ] ||
        { printf '%s\n' "$text" >"$STATE/log/report.txt"; k=0; }
    echo "$(date '+%F %T');report;${k:-0}" >>"$STATE/log/costs-extra.csv"
    notify info "Report: $(cat "$STATE/log/report.txt")" >/dev/null 2>&1 || true
    cat "$STATE/log/report.txt"
}

start_now() { # RUNS [REVIEWER] [REJECTIONS] [WORKER]
    local n=${1:-} reviewer=${2:-sonnet} rejections=${3:-3} worker=${4:-opus}
    [[ "$n" =~ ^[0-9]+$ && "$rejections" =~ ^[0-9]+$ && "$reviewer" =~ ^(sonnet|opus|haiku)$ && "$worker" =~ ^(sonnet|opus)$ ]] ||
        { echo "Usage: autopilot start <runs> [reviewer: sonnet|opus|haiku] [max-rejections] [worker: opus|sonnet]"; return 2; }
    is_running && { echo "The autopilot is already running."; return 1; }
    is_approved || { echo "The acceptance test is NOT approved yet (autopilot approve)."; return 1; }
    [ -n "$(g -C "$WORKDIR" status --porcelain)" ] && { clean_up; echo "Leftovers of an aborted run discarded."; }
    rm -f "$STATE/STOP"
    tmux new -d -s "$SESSION" -e "AUTOPILOT_CONF=$CONF" -e "MAX=$n" -e "WORKER_MODEL=$worker" \
        -e "REVIEWER_MODEL=$reviewer" -e "MAX_REJECTIONS=$rejections" "$HERE/autopilot.sh"
    echo "Started: at most $n runs, worker $worker, reviewer $reviewer, stop after $rejections rejections in a row."
}

case "${1:-}" in
    status) status "${2:-}"; exit 0 ;;
    conditions) conditions; exit 0 ;;
    notes) notes; exit 0 ;;
    result) result; exit 0 ;;
    grades) grade_table; exit 0 ;;
    costs) costs; exit 0 ;;
    chart) chart; exit $? ;;
    propose) (cd "$WORKDIR" && run_planner); exit $? ;;
    suggestion) suggestion "${2:-}"; exit $? ;;
    report) report "${2:-}"; exit 0 ;;
    approve)
        [ ${#ACCEPT_FILES[@]} -gt 0 ] || { echo "No acceptance test set up."; exit 0; }
        accept_checksum >"$STATE/APPROVAL"; echo "Acceptance test approved."; exit 0 ;;
    continue)
        [ -e "$STATE/WAITING" ] || { echo "Nothing is waiting for your OK right now."; exit 0; }
        touch "$STATE/CONTINUE"; echo "OK given, continuing."; exit 0 ;;
    stop)
        is_running || { echo "The autopilot is not running."; exit 0; }
        touch "$STATE/STOP"; echo "Stops after the current run."; exit 0 ;;
    abort)
        is_running || { echo "The autopilot is not running."; exit 0; }
        tmux kill-session -t "=$SESSION"; sleep 1; clean_up; rm -f "$STATE/STOP" "$STATE/WAITING"
        echo "Aborted, the unfinished run was discarded."; exit 0 ;;
    start) shift; start_now "$@"; exit $? ;;
    "") ;;
    *) sed -n '2,13p' "$0" | cut -c3-; exit 2 ;;
esac

# --- Menu ---------------------------------------------------------------------------------------
show() { whiptail --title "$TITLE" --scrolltext --msgbox "$1" 26 110; }
choose() { whiptail --title "$TITLE" --menu "$1" 14 72 4 "${@:2}" 3>&1 1>&2 2>&3; }

start_menu() {
    local n worker reviewer rejections
    n=$(choose "How many runs at most? (one task per run)" 5 Recommended 10 "" 20 "" 30 "") || return
    worker=$(choose "Which model implements the tasks?" opus "Recommended, strongest model" sonnet "cheaper, faster") || return
    reviewer=$(choose "Which model reviews as the reviewer?" sonnet "Recommended, balanced" opus "more thorough, more expensive" haiku "cheap, less strict") || return
    rejections=$(choose "Stop after how many rejections in a row?" 3 Recommended 2 "" 5 "") || return
    show "$(start_now "$n" "$reviewer" "$rejections" "$worker")\n\nIt keeps running even if you close the terminal."
}

while true; do
    choice=$(whiptail --title "$TITLE" --menu "$(status)" 34 110 13 \
        1 "Refresh status" \
        2 "Start" \
        3 "Continue (approve the supervised step)" \
        4 "Stop gently (after the current run)" \
        5 "Abort now" \
        6 "Watch live (back with Ctrl+b, then d)" \
        7 "New project from a plan file" \
        8 "Planner: view, adopt or create a suggestion" \
        9 "Approve acceptance test" \
        10 "Grades, costs and chart" \
        11 "Read decisions and blocked tasks" \
        12 "View result" \
        13 "Create report now" 3>&1 1>&2 2>&3) || exit 0
    case $choice in
        2) start_menu ;;
        3) show "$("$0" continue)" ;;
        4) show "$("$0" stop)" ;;
        5) whiptail --title "$TITLE" --defaultno --yesno "Abort now? The current run is discarded." 9 70 && show "$("$0" abort)" ;;
        6) if is_running; then tmux attach -t "=$SESSION"; else show "The autopilot is not running."; fi ;;
        7) new_project; exec "$0" ;;
        8) if [ -s "$STATE/suggestion.md" ]; then
               whiptail --title "$TITLE" --scrolltext --yesno "$(suggestion)\n\nAdopt?" 26 110 && show "$(suggestion accept)"
           elif whiptail --title "$TITLE" --yesno "No suggestion available. Let the planner propose new tasks now? (takes a few minutes)" 9 70; then
               clear; echo "The planner is working …"; show "$("$0" propose 2>&1)"; fi ;;
        9) if is_approved; then show "Already approved.\n\n$(conditions)"
           elif whiptail --title "$TITLE" --scrolltext --yesno "Goal – the project must meet these conditions:\n\n$(conditions)\n\nApprove like this? Afterwards the autopilot may no longer change the test." 26 110; then
               show "$("$0" approve)"; fi ;;
        10) show "GRADES\n$(grade_table)\n\nCOSTS\n$(costs)\n\nCHART: $(chart)" ;;
        11) show "$(notes)" ;;
        12) show "$(result)" ;;
        13) clear; echo "Creating report …"; show "$(report)" ;;
    esac
done
