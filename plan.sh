#!/usr/bin/env bash
# New project from a plan file (e.g. README.md): Claude reads plan and project and drafts the
# task list, test command and allowed paths. Nothing is set up before your OK.
#
#   autopilot plan <file>      create and show a draft (read only, changes nothing in the project)
#   autopilot plan show        show the last draft
#   autopilot plan accept      set up the last draft: work branch "autopilot" as a worktree next to the
#                              project, autopilot.conf, task list; afterwards `autopilot` means this project
set -u
TOOL_DIR=$(dirname "$(readlink -f "$0")")
# shellcheck source=lib.sh
. "$TOOL_DIR/lib.sh"
CONF_BASE=${XDG_CONFIG_HOME:-$HOME/.config}/autopilot-loop
LAST=$CONF_BASE/last-draft
TASKS_FILE=AUTOPILOT-TASKS.md   # own name, so that no existing TASKS.md is overwritten
conf_dir_writable "$CONF_BASE" || exit 1

fail() { echo "$1" >&2; exit 1; }
exclude_state() { # REPO: state directory and configuration never in Git
    local a; a=$(g -C "$1" rev-parse --git-common-dir)/info/exclude
    case "$a" in /*) ;; *) a=$1/$a ;; esac
    mkdir -p "$(dirname "$a")"
    for m in .autopilot/ autopilot.conf; do grep -qxF "$m" "$a" 2>/dev/null || echo "$m" >>"$a"; done
}

# Only these settings may be taken from the draft, in exactly this form.
# The draft comes from Claude (and indirectly from plan and project); everything else is discarded.
# Tools: only Read, Edit, Write, Glob, Grep and Bash for a single command without wildcards or special characters.
# Each setting at most once (two ALLOWED lines would become one broken pattern). No ACCEPT_CMD: an acceptance
# test needs locked ACCEPT_FILES, which you set up by hand.
safe_conf() { # FILE → valid lines on stdout, discarded ones on stderr
    local z seen=' ' tool='(Read|Edit|Write|Glob|Grep|'"'"'Bash\((\./)?[A-Za-z0-9_][A-Za-z0-9_./ -]*:\*\)'"'"')'
    while IFS= read -r z; do
        if [[ $z =~ ^(TEST_CMD|TEST_COUNT_CMD|ALLOWED|FORBIDDEN_CONTENT)=\'[^\']*\'$ ]] ||
           [[ $z =~ ^(TEST_COUNT_REGEX|ACCEPT_REGEX)=\'[^\']*\(\[0-9\]\+\)[^\']*\'$ ]] ||
           [[ $z =~ ^TEST_EMPTY_RC=[0-9]{1,3}$ ]] ||
           [[ $z =~ ^WORKER_TOOLS=\(\ ?$tool(\ $tool)*\ ?\)$ ]]; then
            [[ $seen == *" ${z%%=*} "* ]] && { echo "discarded (duplicate): $z" >&2; continue; }
            seen+="${z%%=*} "; echo "$z"
        elif [ -n "$z" ]; then echo "discarded: $z" >&2; fi
    done <"$1"
}

show() { # DRAFT DIRECTORY
    local e=$1
    echo "Draft for: $(cat "$e/plan")"
    echo
    echo "Settings (TEST_CMD and TEST_COUNT_CMD are run as shell commands – please read carefully):"
    sed 's/^/  /' "$e/autopilot.part"
    echo
    echo "Tasks ($(grep -c '^- \[ \]' "$e/tasks.md")):"; grep '^- \[ \]' "$e/tasks.md" | cut -c1-140 | sed 's/^/  /'
    [ -s "$e/discarded.txt" ] && { echo; echo "Not adopted for security reasons:"; sed 's/^/  /' "$e/discarded.txt"; }
    echo
    echo "Read in full: $e/tasks.md   Set up: autopilot plan accept   Draft again: autopilot plan <file>"
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

draft() { # PLANFILE
    local file repo rel e prompt cost
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
    echo "$file" >"$e/plan"
    echo "Claude reads $rel and the project and drafts the tasks (takes a few minutes) …"
    prompt="$(cat "$TOOL_DIR/templates/SETUP.md")

## Plan file: $rel
$(cat "$file")

## Files in the project (excerpt)
$(g -C "$repo" ls-files | head -300)"
    cost=$(cd "$repo" && claude_run "$e/answer.txt" --model "${PLANNER_MODEL:-opus}" --allowedTools Read Grep Glob <<<"$prompt") ||
        fail "Claude exited with an error, see $e/answer.txt"
    jq -e . "$e/answer.txt.json" >/dev/null 2>&1 && [ -s "$e/answer.txt" ] ||
        fail "Claude gave no usable answer (invalid JSON or empty output), see $e/answer.txt – run autopilot plan <file> again."
    sed -n '/^===CONFIG===/,/^===TASKS===/p' "$e/answer.txt" | sed '1d;$d' >"$e/config.raw"
    sed -n '/^===TASKS===/,$p' "$e/answer.txt" | sed '1d' >"$e/tasks.md"
    safe_conf "$e/config.raw" >"$e/autopilot.part" 2>"$e/discarded.txt"
    grep -q '^TEST_CMD=' "$e/autopilot.part" || fail "The draft contains no valid test command, see $e/answer.txt"
    grep -q '^- \[ \] ' "$e/tasks.md" || fail "The draft contains no tasks, see $e/answer.txt"
    echo "$repo" >"$LAST"
    echo "Draft ready (cost approx. $cost USD)."; echo
    show "$e"
}

accept() {
    local repo e file rel name base wt allowed err
    repo=$(cat "$LAST" 2>/dev/null) && [ -d "$repo/.autopilot/draft" ] || fail "No draft available (autopilot plan <file>)."
    e=$repo/.autopilot/draft
    file=$(cat "$e/plan"); rel=${file#"$repo"/}
    allowed=$(sed -n "s/^ALLOWED='\(.*\)'$/\1/p" "$e/autopilot.part")
    allowed="(${allowed:-^$})|^(${TASKS_FILE//./\\.}|BLOCKED\\.md|DECISIONS\\.md)\$"
    err=$(ALLOWED=$allowed FORBIDDEN_CONTENT=$(sed -n "s/^FORBIDDEN_CONTENT='\(.*\)'$/\1/p" "$e/autopilot.part") bad_patterns)
    [ -z "$err" ] || fail "The draft's $(echo $err) is not a valid regular expression (grep -E). Draft again: autopilot plan <file>"
    name=$(basename "$repo" | tr -c 'A-Za-z0-9._-' '-'); name=${name%-}  # also the name of the tmux session
    base=$(g -C "$repo" branch --show-current); base=${base:-$(g -C "$repo" rev-parse HEAD)}  # detached HEAD: the commit
    wt=$repo-autopilot
    # Own project folder (created for a plan outside Git): work directly in it, no second folder needed.
    [ -f "$repo/.autopilot/own-workspace" ] && { wt=$repo; base=$(g -C "$repo" rev-list --max-parents=0 HEAD | tail -1); }
    if [ ! -d "$wt" ]; then
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
    # Paths and names come from the file system and Git (branch names may contain ' $ ( ): always quote with %q,
    # because the file is later loaded with `source`.
    {
        printf '# Project from %s, set up %s with autopilot plan\n' "$(printf %q "$rel")" "$(date '+%F %T')"
        printf 'NAME=%q\nWORKDIR=%q\nBASE_BRANCH=%q\nTASKS_FILE=%q\nPLAN_FILE=%q\nLOCKED=(%q)\n' \
            "$name" "$wt" "$base" "$TASKS_FILE" "$file" "$rel"
        grep -v '^ALLOWED=' "$e/autopilot.part"
        echo "ALLOWED='$allowed'"
    } >"$repo/autopilot.conf"
    trust "$repo/autopilot.conf"  # you have just accepted the draft
    ln -sf "$repo/autopilot.conf" "$CONF_BASE/standard.conf"
    rm -rf "$e"; rm -f "$LAST"
    echo "Set up: $repo/autopilot.conf, work branch \"autopilot\" in $wt"
    echo "Start: autopilot (menu) or autopilot start 5"
}

case "${1:-}" in
    "") sed -n '2,8p' "$0" | cut -c3-; exit 2 ;;
    show) repo=$(cat "$LAST" 2>/dev/null) && [ -d "$repo/.autopilot/draft" ] || fail "No draft available."
          show "$repo/.autopilot/draft" ;;
    accept) accept ;;
    *) need_claude || exit 1; draft "$1" ;;
esac
