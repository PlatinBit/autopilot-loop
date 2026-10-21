#!/usr/bin/env bash
# New project from a plan file (e.g. README.md) or from a few sentences: Claude reads plan and project and
# drafts the task list, test command and demo command. Nothing is set up before your OK.
#
#   autopilot plan <file>      create and show a draft (read only, changes nothing in the project)
#   autopilot plan "<idea>"    write ./<slug>-plan.md from one to three sentences, then draft from it
#   autopilot plan             show the draft, or the planner's suggestion for the project here
#   autopilot plan accept      set up the draft (work branch "autopilot" as a worktree next to the project,
#                              autopilot.conf, task list), or add the planner's suggestion to the task list
#   autopilot plan discard     throw the draft or the suggestion away
# Draft and suggestion both waiting: the newer one is meant.
set -u
TOOL_DIR=$(dirname "$(readlink -f "$0")")
# shellcheck source=lib.sh
. "$TOOL_DIR/lib.sh"
LAST=$CONF_BASE/last-draft
TASKS_FILE=AUTOPILOT-TASKS.md   # own name, so that no existing TASKS.md is overwritten
conf_dir_writable "$CONF_BASE" || exit 1

fail() { echo "$1" >&2; exit 1; }
exclude_state() { # REPO: state directory and configuration never in Git
    local a; a=$(g -C "$1" rev-parse --git-common-dir)/info/exclude
    case "$a" in /*) ;; *) a=$1/$a ;; esac
    mkdir -p "$(dirname "$a")"
    for m in /.autopilot/ /autopilot.conf __pycache__/ '*.pyc'; do grep -qxF "$m" "$a" 2>/dev/null || echo "$m" >>"$a"; done
}
# Claude gave no answer: say why – the usage limit with its reset time, or the answer file to read
claude_failed() { # ANSWERFILE
    local t
    usage_limit "$1" && { t=$(limit_reset "$1"); fail "Claude's usage limit is reached${t:+ (resets $t)} – nothing was set up; run the same command again then."; }
    fail "Claude exited with an error, see $1"
}

# Only these settings may be taken from the draft, in exactly this form.
# The draft comes from Claude (and indirectly from plan and project); everything else is discarded.
# Tools: only Read, Edit, Write, Glob, Grep and Bash for a single command without wildcards or special characters.
# Each setting at most once (two ALLOWED lines would become one broken pattern). An acceptance test (ACCEPT_CMD
# with ACCEPT_FILES of plain paths) is adopted at `plan accept` only if its files exist; they are then locked.
safe_conf() { # FILE → valid lines on stdout, discarded ones on stderr
    local z seen=' ' tool='(Read|Edit|Write|Glob|Grep|'"'"'Bash\((\./)?[A-Za-z0-9_][A-Za-z0-9_./ -]*:\*\)'"'"')'
    local path='[A-Za-z0-9_][A-Za-z0-9_.-]*(/[A-Za-z0-9_][A-Za-z0-9_.-]*)*'  # no ".." segments, no leading "/"
    while IFS= read -r z; do
        if [[ $z =~ ^(TEST_CMD|TEST_COUNT_CMD|ALLOWED|FORBIDDEN_CONTENT|DEMO_CMD|TRY_IT|ACCEPT_CMD)=\'[^\']*\'$ ]] ||
           [[ $z =~ ^(TEST_COUNT_REGEX|ACCEPT_REGEX)=\'[^\']*\(\[0-9\]\+\)[^\']*\'$ ]] ||
           [[ $z =~ ^TEST_EMPTY_RC=[0-9]{1,3}$ ]] ||
           [[ $z =~ ^ACCEPT_FILES=\($path(\ $path)*\)$ ]] ||
           [[ $z =~ ^WORKER_TOOLS=\(\ ?$tool(\ $tool)*\ ?\)$ ]]; then
            [[ $seen == *" ${z%%=*} "* ]] && { echo "discarded (duplicate): $z" >&2; continue; }
            seen+="${z%%=*} "; echo "$z"
        elif [ -n "$z" ]; then echo "discarded: $z" >&2; fi
    done <"$1"
}

show_draft() { # DRAFT DIRECTORY
    local e=$1
    echo "Draft for: $(cat "$e/plan")"
    echo
    echo "Settings (TEST_CMD, TEST_COUNT_CMD, DEMO_CMD and ACCEPT_CMD are run as shell commands – please read carefully):"
    sed 's/^/  /' "$e/autopilot.part"
    echo
    echo "Tasks ($(grep -c '^- \[ \]' "$e/tasks.md")):"; grep '^- \[ \]' "$e/tasks.md" | cut_chars 1 140 | sed 's/^/  /'
    [ -s "$e/discarded.txt" ] && { echo; echo "Not adopted for security reasons:"; sed 's/^/  /' "$e/discarded.txt"; }
    echo
    grep -q "^DEMO_CMD='[^']" "$e/autopilot.part" ||
        echo "No demo command (DEMO_CMD) in the draft: the run can never end as delivered. Add one to autopilot.conf after setting up (then: autopilot trust)."
    echo "Read in full: $e/tasks.md   Set up: autopilot plan accept   Throw away: autopilot plan discard"
}

# A plan file outside any Git project gets its own project folder next to it (<name>-autopilot/) with its own
# Git repository and a copy of the plan. Nothing else on the system is changed – no `git init` in your folders.
new_workspace() { # PLANFILE → path of the project folder on stdout
    local file=$1 name dir
    name=$(basename "$file"); name=${name%.*}; name=$(printf %s "$name" | tr -c 'A-Za-z0-9._-' '-')
    dir=$(dirname "$file")/${name:-plan}-autopilot
    if [ -d "$dir/.git" ]; then echo "$dir"; return; fi
    [ -e "$dir" ] && { echo "$dir exists and is not a Git project – please move it or use another plan file." >&2; return 1; }
    mkdir -p "$dir" && cp "$file" "$dir/" || return 1
    g -C "$dir" init -q -b main || return 1
    # No Git identity on this machine? Set one for this folder only (your global settings stay untouched).
    [ -n "$(g -C "$dir" config user.email)" ] || { g -C "$dir" config user.name autopilot-loop; g -C "$dir" config user.email autopilot-loop@localhost; }
    g -C "$dir" add -A && g -C "$dir" commit -q --no-verify -m "Plan" || return 1
    mkdir -p "$dir/.autopilot" && touch "$dir/.autopilot/own-workspace"
    echo "Note: $file is not inside a Git project, so a separate project folder was created: $dir" >&2
    echo "$dir"
}

idea() { # IDEA TEXT: write ./<slug>-plan.md, then draft from it
    local text=$1 slug out a
    slug=$(printf %s "$text" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-')
    slug=${slug:0:40}; slug=${slug#-}; slug=${slug%-}
    out=$PWD/${slug:-idea}-plan.md
    [ -e "$out" ] && fail "$out already exists – draft from it (autopilot plan $out), move it aside or word the idea differently."
    a=$CONF_BASE/idea-answer.txt; rm -f "$CONF_BASE/idea-costs.csv"
    echo "Claude turns the idea into a plan file (takes a few minutes) …"
    COSTS=$CONF_BASE/idea-costs.csv claude_run "$a" plan --model opus --allowedTools Read Grep Glob \
        <<<"$(cat "$TOOL_DIR/templates/IDEA.md")"$'\n\n## Idea\n'"$text" >/dev/null || claude_failed "$a"
    jq -e . "$a.json" >/dev/null 2>&1 && [ -s "$a" ] ||
        fail "Claude gave no usable answer (invalid JSON or empty output), see $a – run autopilot plan \"<idea>\" again."
    cp "$a" "$out" || fail "Could not write $out"
    echo "Plan file written: $out"
    echo; head -25 "$out" | sed 's/^/  /'; [ "$(wc -l <"$out")" -gt 25 ] && echo "  …"
    echo
    draft "$out"
}

draft() { # PLANFILE
    local file repo rel e prompt cost c
    file=$(readlink -f "${1/#\~/$HOME}") && [ -f "$file" ] || fail "File not found: $1"  # ~ also without a shell (plugin)
    if ! repo=$(g -C "$(dirname "$file")" rev-parse --show-toplevel 2>/dev/null); then
        repo=$(new_workspace "$file") || fail "Could not create a project folder for $file."
        file=$repo/$(basename "$file")
    fi
    g -C "$repo" rev-parse -q --verify HEAD >/dev/null || fail "The Git project has no commit yet (git add -A && git commit -m Start)."
    rel=${file#"$repo"/}
    e=$repo/.autopilot/draft
    exclude_state "$repo"
    rm -rf "$e"; mkdir -p "$e"
    # An idea's plan file was written before the project was known: its cost belongs to this project now
    c=$repo/.autopilot/costs.csv
    [ -s "$CONF_BASE/idea-costs.csv" ] && { { [ -s "$c" ] && tail -n +2 "$CONF_BASE/idea-costs.csv" || cat "$CONF_BASE/idea-costs.csv"; } >>"$c"; rm -f "$CONF_BASE/idea-costs.csv"; }
    echo "$file" >"$e/plan"
    echo "Claude reads $rel and the project and drafts the tasks (takes a few minutes) …"
    prompt="$(cat "$TOOL_DIR/templates/SETUP.md")"
    # A plan with "## Milestone N" sections: only the first milestone now, the loop drafts the others itself
    grep -qE '^##[[:space:]]+Milestone[[:space:]]+[0-9]+' "$file" && prompt+="

## Milestones
The plan is split into \"## Milestone N\" sections. Draft the tasks of the first milestone only; the autopilot drafts the next milestone itself when one is done. Its last task proves that milestone's criterion; the error-case and the end-to-end task belong to the last milestone only, unless the plan has just one."
    prompt+="

## Plan file: $rel
$(cat "$file")

## Files in the project (excerpt)
$(g -C "$repo" ls-files | head -300)"
    cost=$(cd "$repo" && COSTS=$c claude_run "$e/answer.txt" draft --model opus --allowedTools Read Grep Glob <<<"$prompt") ||
        claude_failed "$e/answer.txt"
    jq -e . "$e/answer.txt.json" >/dev/null 2>&1 && [ -s "$e/answer.txt" ] ||
        fail "Claude gave no usable answer (invalid JSON or empty output), see $e/answer.txt – run autopilot plan <file> again."
    sed -n '/^===CONFIG===/,/^===TASKS===/p' "$e/answer.txt" | sed '1d;$d' >"$e/config.raw"
    sed -n '/^===TASKS===/,$p' "$e/answer.txt" | sed '1d' >"$e/tasks.md"
    safe_conf "$e/config.raw" >"$e/autopilot.part" 2>"$e/discarded.txt"
    grep -q '^TEST_CMD=' "$e/autopilot.part" || fail "The draft contains no valid test command, see $e/answer.txt"
    grep -q '^- \[ \] ' "$e/tasks.md" || fail "The draft contains no tasks, see $e/answer.txt"
    echo "$repo" >"$LAST"
    echo "Draft ready (cost approx. $cost USD)."; echo
    show_draft "$e"
}

accept_draft() { # DRAFT DIRECTORY
    local e=$1 repo file rel base wt err sr wrap='' z re f locked note=''
    repo=${e%/.autopilot/draft}
    file=$(cat "$e/plan"); rel=${file#"$repo"/}
    err=$(ALLOWED=$(sed -n "s/^ALLOWED='\(.*\)'$/\1/p" "$e/autopilot.part") FORBIDDEN_CONTENT=$(sed -n "s/^FORBIDDEN_CONTENT='\(.*\)'$/\1/p" "$e/autopilot.part") bad_patterns)
    [ -z "$err" ] || fail "The draft's $(echo $err) is not a valid regular expression (grep -E). Draft again: autopilot plan <file>"
    base=$(g -C "$repo" branch --show-current); base=${base:-$(g -C "$repo" rev-parse HEAD)}  # detached HEAD: the commit
    wt=$repo-autopilot
    [ -f "$repo/.autopilot/own-workspace" ] && wt=$repo  # own project folder (plan outside Git): work in it on branch autopilot
    under_claude_dir "$wt" && fail "The work directory $wt would lie below ~/.claude/, where Claude Code refuses every write. Move the project (or the plan file) elsewhere, then: autopilot plan <file>"
    # The acceptance test of the draft is adopted when its files exist (they are locked, so the worker could never create them).
    locked=$(printf '%q' "$rel")
    if grep -q '^ACCEPT_CMD=' "$e/autopilot.part"; then
        for f in $(sed -n 's/^ACCEPT_FILES=(\(.*\))$/\1/p' "$e/autopilot.part"); do
            [ -e "$repo/$f" ] || { note="The draft's acceptance test was dropped: $f does not exist."; break; }
            locked+=" $(printf '%q' "$f")"
        done
        grep -q '^ACCEPT_FILES=' "$e/autopilot.part" || note="The draft's acceptance test was dropped: it names no ACCEPT_FILES to lock."
    fi
    if [ "$wt" = "$repo" ]; then
        base=main  # new_workspace created main with the plan
        g -C "$repo" checkout -q autopilot 2>/dev/null || g -C "$repo" checkout -q -b autopilot || fail "Could not create the work branch autopilot in $repo."
    elif [ ! -d "$wt" ]; then
        if g -C "$repo" rev-parse -q --verify autopilot >/dev/null; then err=$(g -C "$repo" worktree add -q "$wt" autopilot 2>&1 >/dev/null)
        else err=$(g -C "$repo" worktree add -q "$wt" -b autopilot 2>&1 >/dev/null); fi ||
            fail "Could not create the work branch in $wt: $(printf '%s\n' "$err" | tail -1)
Move or remove what is at $wt (or delete a stale worktree with: git -C \"$repo\" worktree prune), then run again: autopilot plan accept (the draft is kept)."
    fi
    [ -z "$(g -C "$wt" status --porcelain)" ] || fail "The work directory $wt has uncommitted changes."
    cp "$e/tasks.md" "$wt/$TASKS_FILE"
    # Second run with the same task list: nothing to commit, that is fine.
    g -C "$wt" add "$TASKS_FILE" && { g -C "$wt" diff --cached --quiet -- "$TASKS_FILE" ||
        g -C "$wt" commit -q --no-verify -m "Autopilot: tasks from $rel"; } ||
        fail "Commit failed – is a Git identity set? (git config --global user.name / user.email)"
    # When the sandbox works here, a metachar-free test command (and the worker's Bash rights) is routed
    # through sandbox-run, so the worker's own test calls are sandboxed too, not only the ones the loop runs.
    sr=$TOOL_DIR/sandbox-run; re='^[A-Za-z0-9_./:= -]+$'
    (cd "$wt" && sandbox_works) && [[ $(sed -n "s/^TEST_CMD='\(.*\)'\$/\1/p" "$e/autopilot.part") =~ $re ]] && wrap=1
    # Paths and names come from the file system and Git (branch names may contain ' $ ( ): always quote with %q,
    # because the file is later loaded with `source`.
    {
        printf '# Project from %s, set up %s with autopilot plan\n' "$(printf %q "$rel")" "$(date '+%F %T')"
        printf 'WORKDIR=%q\nBASE_BRANCH=%q\nTASKS_FILE=%q\nPLAN_FILE=%q\nLOCKED=(%s)\n' "$wt" "$base" "$TASKS_FILE" "$file" "$locked"
        while IFS= read -r z; do
            [ -n "$note" ] && [[ $z == ACCEPT_* ]] && continue
            [[ $z == ACCEPT_FILES=* ]] && continue  # locked above
            if [ -n "$wrap" ]; then case $z in
                TEST_CMD=*) z="TEST_CMD='$sr ${z#"TEST_CMD='"}" ;;
                WORKER_TOOLS=*) z=${z//"'Bash("/"'Bash($sr "} ;;
            esac; fi
            echo "$z"
        done <"$e/autopilot.part"
        grep -q "^DEMO_CMD='[^']" "$e/autopilot.part" || printf "# no demo: the run can never end as delivered – add one\nDEMO_CMD=''\n"
    } >"$repo/autopilot.conf"
    trust "$repo/autopilot.conf"  # you have just accepted the draft
    rm -rf "$e"; rm -f "$LAST"
    echo "Set up: $repo/autopilot.conf, work branch \"autopilot\" in $wt"
    [ -n "$note" ] && echo "$note"
    probe_test_cmd "$repo/autopilot.conf"
    grep -q "^DEMO_CMD=''" "$repo/autopilot.conf" && echo "Warning: no demo command – add DEMO_CMD to $repo/autopilot.conf (then: autopilot trust)."
    echo "Start: cd $(printf %q "$repo") && autopilot start"
}

accept_suggestion() { # adds the planner's suggestion to the task list of the project here (needs its trusted conf)
    (
        # shellcheck source=common.sh
        . "$TOOL_DIR/common.sh"
        n=$(wc -l <"$STATE/suggestion.md")
        is_running && { echo "Stop it first: the autopilot is running."; exit 1; }
        [ -z "$(g -C "$WORKDIR" status --porcelain)" ] || { echo "Work directory not clean."; exit 1; }
        cat "$STATE/suggestion.md" >>"$WORKDIR/$TASKS_FILE"
        g -C "$WORKDIR" add "$TASKS_FILE" && g -C "$WORKDIR" commit -q -m "Planner: $n new tasks" || exit 1
        rm -f "$STATE/suggestion.md" "$STATE/no-progress"  # adopted = new state: the no-progress brake starts afresh
        echo "$n tasks adopted. Start: autopilot start"
    )
}

# What `plan`, `plan accept` and `plan discard` mean: "draft DIR" or "suggestion FILE", the newer one
pending() {
    local d s=''
    d=$(cat "$LAST" 2>/dev/null) && d=$d/.autopilot/draft && [ -s "$d/tasks.md" ] || d=''
    s=$(find_conf) && s=$(dirname "$s")/.autopilot/suggestion.md && [ -s "$s" ] || s=''
    if [ -n "$d" ] && { [ -z "$s" ] || [ "$d/tasks.md" -nt "$s" ]; }; then echo "draft $d"
    elif [ -n "$s" ]; then echo "suggestion $s"; fi
}

case "${1:-}" in
    ""|accept|discard)
        read -r kind path < <(pending)
        case "${1:-}:${kind:-}" in
            :) echo "Nothing to show: no draft and no planner suggestion."; sed -n '5,6p' "$0" | cut -c3-; exit 0 ;;
            accept:|discard:) fail "Nothing to $1: no draft and no planner suggestion here. Draft one: autopilot plan <file>" ;;
            :draft) show_draft "$path" ;;
            :suggestion) echo "Planner suggestion ($path):"; cat "$path"; echo; echo "Adopt: autopilot plan accept   Throw away: autopilot plan discard" ;;
            accept:draft) accept_draft "$path" ;;
            accept:suggestion) accept_suggestion ;;
            discard:draft) rm -rf "$path"; rm -f "$LAST"; echo "Draft thrown away." ;;
            discard:suggestion) rm -f "$path"; echo "Planner suggestion thrown away." ;;
        esac ;;
    -h|--help|help) sed -n '2,11p' "$0" | cut -c3- ;;
    *) need_claude && need_jq || exit 1
       if [ -f "${1/#\~/$HOME}" ]; then draft "$1"
       elif [[ $* == *' '* && $* != *.md && $* != *.txt ]]; then idea "$*"
       else fail "File not found: $1 (an idea needs a few words in quotes: autopilot plan \"<idea>\")"; fi ;;
esac
