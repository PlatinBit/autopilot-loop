#!/usr/bin/env bash
# autopilot-loop – menu and commands. Runs in a normal terminal, without a Claude session.
#
#   autopilot                          menu (whiptail)
#   autopilot plan <file>              draft a new project from a plan file (then: plan accept)
#   autopilot plan idea "<sentences>"  write a plan file from a bare idea (review it, then: autopilot plan <file>)
#   autopilot plan show | plan accept  show the last draft / set it up
#   autopilot trust [file]             approve a hand-written or changed autopilot.conf
#   autopilot start <runs> [reviewer: sonnet|opus|haiku] [max-rejections] [worker: opus|sonnet|haiku] [planner: opus|sonnet]
#   autopilot status [--short] | summary [--short] | stop | abort | continue | approve | conditions
#   autopilot grades | costs | chart | notes | result | propose | suggestion [accept|discard]
#   autopilot report [--if-new]        summary of the last 24 hours (for cron)
#   autopilot doctor                   check everything needed: tools, versions, install commands, project
#   autopilot setup                    create autopilot.conf by hand in the current directory
#   autopilot help                     this help
set -u
HERE=$(dirname "$(readlink -f "$0")")
CONF_BASE=${XDG_CONFIG_HOME:-$HOME/.config}/autopilot-loop
# shellcheck source=lib.sh
. "$HERE/lib.sh"

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
doc_project() { # with a trusted configuration: sandbox state and a one-shot probe of TEST_CMD
    local k='' c
    for c in "${AUTOPILOT_CONF:-}" "$PWD/autopilot.conf" "$CONF_BASE/standard.conf"; do
        [ -n "$c" ] && [ -f "$c" ] && { k=$c; break; }
    done
    [ -n "$k" ] || { echo "Project: none set up yet (autopilot plan <file>) – only the tools above were checked."; return 0; }
    is_trusted "$k" || { echo "Project: $k is not confirmed as trusted – test command not probed (autopilot trust)."; return 0; }
    echo "Project: $k"
    (set +u; SANDBOX=off; . "$k" </dev/null >/dev/null 2>&1
     if [ "$SANDBOX" != on ]; then echo "  SANDBOX=off (test commands run unsandboxed)"
     elif "$HERE/sandbox-run" true >/dev/null 2>&1; then echo "  SANDBOX=on and bwrap works"
     else echo "  SANDBOX=on but bwrap cannot start a sandbox here – $(install_hint bubblewrap), or set SANDBOX=off"; fi)
    probe_test_cmd "$k" | sed 's/^/  /'
}
doctor() {
    local miss=0 t id
    echo "autopilot-loop doctor"
    printf ' ✔ %-9s %-8s %s\n' bash "${BASH_VERSION%%(*}" "runs all scripts (4.4 or newer)"
    doc_row claude "writes, plans and reviews the code" "https://claude.com/claude-code – then log in once: claude" || miss=1
    doc_row git "work branch, checks and commit of every run" || miss=1
    doc_row jq "reads Claude's JSON answers" || miss=1
    doc_row tmux "keeps the loop running in the background (start/stop/abort/status)" || miss=1
    doc_row whiptail "terminal menu (optional: every command also works directly)"
    doc_row python3 "progress chart (optional: everything else works without it)"
    t=timeout; command -v timeout >/dev/null || t=gtimeout
    doc_row "$t" "time limits for runs and commands (optional, coreutils)" "$(install_hint coreutils)"
    doc_row bwrap "sandbox for test commands (optional, Linux, used with SANDBOX=on)"
    if id=$(git var GIT_COMMITTER_IDENT 2>/dev/null); then echo " ✔ git identity: $(sed 's/ [0-9].*//' <<<"$id")"
    else echo " ✘ git identity not set – git config --global user.email you@example.org; git config --global user.name \"Your Name\""; miss=1; fi
    doc_project
    if [ "$miss" = 0 ]; then echo "Everything required is present."
    else echo "Required pieces are missing (✘ above) – install them, then check again: autopilot doctor"; return 1; fi
}

case "${1:-}" in
    plan) shift; exec "$HERE/plan.sh" "$@" ;;
    doctor) doctor; exit $? ;;
    setup)
        [ -e autopilot.conf ] && { echo "autopilot.conf already exists here."; exit 1; }
        cp "$HERE/templates/autopilot.conf" autopilot.conf || exit 1
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
    help|-h|--help) sed -n '2,15p' "$0" | cut -c3-; exit 0 ;;
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
[ -n "${1:-}" ] || need whiptail "The interactive menu is drawn with it (every command also works directly, see: autopilot help)." || exit 1
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

waiting() { # WAITING only counts while the run that wrote it is alive (a leftover after a crash/reboot does not)
    local pid; [ -r "$STATE/WAITING" ] && read -r pid <"$STATE/WAITING" || return 1
    [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null
}

status() {
    if [ "${1:-}" = --short ]; then  # one line for the Claude Code status line; empty when nothing runs
        is_running || return 0
        if waiting; then echo "Autopilot $NAME: waiting for your OK (supervised)"
        else echo "Autopilot $NAME: $(run_progress)$( [ -n "$ACCEPT_CMD" ] && echo " · $(accept_progress)")"; fi
        return 0
    fi
    echo "Status:      $(is_running && echo 'running' || echo 'off')$( [ -e "$STATE/STOP" ] && echo ' (stops after this run)')$( waiting && echo ' – WAITING for your OK (autopilot continue)')"
    [ ${#ACCEPT_FILES[@]} -gt 0 ] && echo "Acceptance:  $(is_approved && echo 'approved' || echo 'NOT approved')   $(accept_progress)"
    [ -n "$PLAN_FILE" ] && echo "Plan:        $PLAN_FILE"
    if [ -f "$WORKDIR/$TASKS_FILE" ]; then
        echo "Tasks:       $(grep -c '^- \[x\]' "$WORKDIR/$TASKS_FILE") done, $(grep -c '^- \[ \]' "$WORKDIR/$TASKS_FILE") open, $(grep -c '^- \[~\]' "$WORKDIR/$TASKS_FILE") blocked"
        echo "Next:        $(grep -m1 '^- \[ \]' "$WORKDIR/$TASKS_FILE" | cut_chars 7 70)"
    else echo "Tasks:       task list not found: $WORKDIR/$TASKS_FILE (check TASKS_FILE in autopilot.conf)"; fi
    [ -s "$STATE/suggestion.md" ] && echo "Suggestion:  $(wc -l <"$STATE/suggestion.md") new tasks from the planner are waiting (autopilot suggestion)"
    echo
    echo "Latest events:"
    tail -8 "$STATE/log/history.log" 2>/dev/null | cut_chars 12 110
}

conditions() {
    if [ -n "$ACCEPT_LIST_CMD" ]; then (cd "$WORKDIR" && bash -c "$ACCEPT_LIST_CMD")
    elif [ ${#ACCEPT_FILES[@]} -gt 0 ]; then (cd "$WORKDIR" && find "${ACCEPT_FILES[@]/#-/./-}" -type f | sort)
    else echo "No acceptance test set up (ACCEPT_FILES is empty)."; fi
}
notes() {
    echo "DECISIONS made by the autopilot ($DECISIONS_FILE):"; cat "$WORKDIR/$DECISIONS_FILE" 2>/dev/null || echo "–"
    echo; echo "BLOCKED:"; cat "$WORKDIR/BLOCKED.md" 2>/dev/null || echo "nothing"
}
result() {
    local b; b=$(g -C "$WORKDIR" branch --show-current)
    echo "New since $BASE_BRANCH (branch $b):"
    g -C "$WORKDIR" log --oneline "$BASE_BRANCH..HEAD" | cut_chars 1 105
    echo
    if [ "$b" = "$BASE_BRANCH" ]; then echo "The work is directly on $b: nothing to merge."
    else echo "To adopt, on $BASE_BRANCH in the project:  git merge $b"; fi
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
chart() {
    need python3 "The chart needs it (everything else works without it)." || return 1
    python3 "$TOOL_DIR/chart.py" "$STATE" "$NAME" "$(number_from "$STATE/log/accept-start.txt" "$ACCEPT_REGEX" 2 2>/dev/null)"; }
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

summary() { # [--short]: end summary of the last start, from the logs alone (no Claude call)
    local h=$STATE/log/history.log csv=$STATE/log/progress.csv
    local ln events st t0 runs cost secs t1 n_done n_open n_blocked acc ended next
    ln=$(grep -n ' Start: ' "$h" 2>/dev/null | tail -1 | cut -d: -f1)
    [ -n "$ln" ] || { echo "Nothing has run yet. Start it: autopilot start 5 (or the menu)."; return 0; }
    events=$(tail -n +"$ln" "$h")
    st=$(head -1 <<<"$events" | cut_chars 1 19)
    t0=$(sed -n 's/.* Start: \([0-9][0-9]*\) tests green.*/\1/p' <<<"$events" | head -1)
    read -r runs cost secs t1 < <(awk -F';' -v s="$st" '
        NR > 1 && substr($1, 1, 19) >= s { n++; c += $8; sec += $7; t = $5 }
        END { printf "%d %.2f %d %s\n", n, c, sec, (t == "" ? "?" : t) }' "$csv" 2>/dev/null)
    [ "${t1:-?}" = "?" ] && t1=${t0:-?}
    n_done=$(grep -c '^- \[x\]' "$WORKDIR/$TASKS_FILE" 2>/dev/null)
    n_open=$(grep -c '^- \[ \]' "$WORKDIR/$TASKS_FILE" 2>/dev/null)
    n_blocked=$(grep -c '^- \[~\]' "$WORKDIR/$TASKS_FILE" 2>/dev/null)
    if [ "${1:-}" = --short ]; then
        echo "${n_done:-?} done, ${n_blocked:-?} blocked, tests ${t0:-?} -> $t1, ${cost:-0} USD"
        return 0
    fi
    if is_running; then ended='still running'
    elif grep -q 'Goal reached' <<<"$events"; then ended='goal reached'
    elif grep -q 'Limit of .* runs reached' <<<"$events"; then ended='run limit reached (more runs: autopilot start)'
    elif grep -q 'Stopped via STOP' <<<"$events"; then ended='stopped by you'
    elif grep -q 'rejections in a row, stopped' <<<"$events"; then ended='stopped after repeated rejections'
    elif grep -qi 'interrupted' <<<"$events"; then ended='aborted'
    else ended="ended early: $(tail -1 <<<"$events" | cut_chars 21 90)"; fi
    if [ "${n_open:-0}" -gt 0 ] 2>/dev/null; then next="$n_open open tasks left - continue: autopilot start $n_open"
    elif [ "${n_blocked:-0}" -gt 0 ] 2>/dev/null; then next="read BLOCKED.md ($n_blocked blocked), then view and merge: autopilot result"
    else next='view and merge the result: autopilot result'; fi
    acc=$(grep -o 'Accept [0-9]* -> [0-9]* of [0-9?]*\|Accept [0-9]* of [0-9?]*' <<<"$events" | tail -1 |
        sed 's/Accept \([0-9]*\) -> \([0-9]*\)/Accept \2/')
    echo "Last start:  $st - ${runs:-0} runs, $(( ${secs:-0} / 60 ))m $(( ${secs:-0} % 60 ))s run time, ${cost:-0} USD"
    echo "Tasks:       ${n_done:-?} done, ${n_open:-?} open, ${n_blocked:-?} blocked"
    echo "Tests:       ${t0:-?} -> $t1"
    [ -n "$acc" ] && echo "Acceptance:  ${acc#Accept }"
    echo "Ended:       $ended"
    echo "Next:        $next"
    return 0
}

report() { # [--if-new]
    local since recent text k
    since=$(date -d '1 day ago' '+%F %T' 2>/dev/null || date -v-1d '+%F %T')
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

start_now() { # RUNS [REVIEWER] [REJECTIONS] [WORKER] [PLANNER]
    local n=${1:-} reviewer=${2:-sonnet} rejections=${3:-3} worker=${4:-opus} planner=${5:-opus}
    [[ "$n" =~ ^[0-9]+$ && "$rejections" =~ ^[0-9]+$ && "$reviewer" =~ ^(sonnet|opus|haiku)$ && "$worker" =~ ^(sonnet|opus|haiku)$ &&
       "$planner" =~ ^(sonnet|opus)$ ]] ||
        { echo "Usage: autopilot start <runs> [reviewer: sonnet|opus|haiku] [max-rejections] [worker: opus|sonnet|haiku] [planner: opus|sonnet]"; return 2; }
    need tmux "autopilot start runs the loop inside it in the background." || return 1
    is_running && { echo "The autopilot is already running."; return 1; }
    is_approved || { echo "The acceptance test is NOT approved yet (autopilot approve)."; return 1; }
    [ -n "$(g -C "$WORKDIR" status --porcelain)" ] && { clean_up; echo "Leftovers of an aborted run discarded (git reset --hard, git clean -fd in $WORKDIR)."; }
    rm -f "$STATE/STOP"
    # PATH from here (a running tmux server would otherwise pass on its own, maybe without claude);
    # the output also goes to console.txt, so that an immediate failure is not lost with the session.
    local console=$STATE/log/console.txt; : >"$console"
    tmux new -d -s "$SESSION" -e "PATH=$PATH" -e "AUTOPILOT_CONF=$CONF" -e "MAX=$n" -e "WORKER_MODEL=$worker" -e "PLANNER_MODEL=$planner" \
        -e "REVIEWER_MODEL=$reviewer" -e "MAX_REJECTIONS=$rejections" \
        bash -c '{ "$1" 2>&1; echo "autopilot.sh ended with exit code $?"; } | tee -a "$2"' autopilot "$HERE/autopilot.sh" "$console" ||
        { echo "Could not start the tmux session $SESSION."; return 1; }
    for _ in 1 2 3 4 5 6; do sleep 0.5; is_running || break; done
    if ! is_running && ! grep -q 'exit code 0$' "$console"; then
        echo "The autopilot ended right after the start ($console):"; tail -5 "$console"; return 1
    fi
    echo "Started: at most $n runs, planner $planner, worker $worker, reviewer $reviewer, stop after $rejections rejections in a row."
    [ "$planner" = "$worker" ] || echo "The planner writes a brief for every task, the worker implements it."
}

case "${1:-}" in
    status) status "${2:-}"; exit 0 ;;
    summary) summary "${2:-}"; exit 0 ;;
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
        s=$(accept_checksum) || { echo "Approval refused: fix ACCEPT_FILES in $CONF."; exit 1; }
        echo "$s" >"$STATE/APPROVAL"; echo "Acceptance test approved."; exit 0 ;;
    continue)
        waiting || { echo "Nothing is waiting for your OK right now."; exit 0; }
        touch "$STATE/CONTINUE"; echo "OK given, continuing."; exit 0 ;;
    stop)
        is_running || { echo "The autopilot is not running."; exit 0; }
        touch "$STATE/STOP"; echo "Stops after the current run."; exit 0 ;;
    abort)
        is_running || { echo "The autopilot is not running."; exit 0; }
        # Stop autopilot.sh itself first: it ends the worker and resets (killing the session alone leaves the worker running)
        pid=''; read -r pid <"$STATE/lock/pid" 2>/dev/null
        if [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
            kill -TERM "$pid"
            for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
        fi
        tmux kill-session -t "=$SESSION" 2>/dev/null; clean_up; rm -f "$STATE/STOP" "$STATE/WAITING"
        echo "Aborted, the unfinished run was discarded (git reset --hard, git clean -fd in $WORKDIR)."; exit 0 ;;
    start) shift; start_now "$@"; exit $? ;;
    "") ;;
    *) sed -n '2,15p' "$0" | cut -c3-; exit 2 ;;
esac

# --- Menu ---------------------------------------------------------------------------------------
show() { whiptail --title "$TITLE" --scrolltext --msgbox "$1" 26 110; }
choose() { whiptail --title "$TITLE" --menu "$1" 14 72 4 "${@:2}" 3>&1 1>&2 2>&3; }

start_menu() {
    local n planner worker reviewer rejections
    n=$(choose "How many runs at most? (one task per run)" 5 Recommended 10 "" 20 "" 30 "") || return
    planner=$(choose "Which model plans? (task briefs, new tasks)" opus "Recommended, strongest model" sonnet "cheaper") || return
    worker=$(choose "Which model builds (writes the code)?" opus "strongest, most expensive" sonnet "cheaper; gets a brief from the planner" haiku "cheapest; gets a brief, for simple tasks") || return
    reviewer=$(choose "Which model reviews every task?" sonnet "balanced" opus "most thorough, recommended with a cheaper builder" haiku "cheap, less strict") || return
    rejections=$(choose "Stop after how many rejections in a row?" 3 Recommended 2 "" 5 "") || return
    show "$(start_now "$n" "$reviewer" "$rejections" "$worker" "$planner")\n\nIt keeps running even if you close the terminal."
}

while true; do
    choice=$(whiptail --title "$TITLE" --menu "$(status)" 34 110 14 \
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
        13 "Create report now" \
        14 "Doctor: check requirements" 3>&1 1>&2 2>&3) || exit 0
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
        14) show "$("$0" doctor 2>&1)" ;;
    esac
done
