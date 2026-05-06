#!/bin/bash
# =============================================================================
# rlhf-daemon.sh — Filesystem watcher + rule enforcement engine
#
# Started by rlhf-run.sh. Do not run directly.
#
# Args:
#   $1 = WATCH_DIR       — project root to watch
#   $2 = WRAPPER_PID     — PID of rlhf-run.sh (receives SIGUSR1 on violation)
#   $3 = RULES_FILE      — path to .rlhf-rules (optional)
#
# IPC:
#   Writes .rlhf-blocked when a violation is detected.
#   rlhf-run.sh monitor loop reads this file.
# =============================================================================

WATCH_DIR="${1:-.}"
WRAPPER_PID="${2:-0}"
RULES_FILE="${3:-.rlhf-rules}"

SESSION_FILE="$WATCH_DIR/.agent-session.md"
VIOLATIONS_LOG="$WATCH_DIR/.rlhf-violations.log"
BLOCKED_FILE="$WATCH_DIR/.rlhf-blocked"
LASTBLOCK_FILE="$WATCH_DIR/.rlhf-lastblock"
LASTCHECK_FILE="$WATCH_DIR/.rlhf-lastcheck"

# ── Defaults (overridden by .rlhf-rules) ──────────────────────────────────────
SESSION_MAX_AGE_MIN=15
REQUIRE_SESSION=yes
REQUIRE_TASK=yes
ENFORCE_BRANCH=yes
BLOCK_MAIN_BRANCH=yes
MAIN_BRANCH_NAMES="main,master,develop"
CHECK_TODO=yes
TODO_FILES="TODO.md TASKS.md .rlhf-tasks.md"
REVERT_ON_VIOLATION=yes
BLOCK_COOLDOWN_SEC=30
WATCH_EXCLUDE='\.git|\.rlhf|\.agent-watchdog|node_modules|__pycache__|\.pyc$|\.rlhf-blocked$'
WATCHDOG_INTERVAL=300

# ── Load rules ────────────────────────────────────────────────────────────────
if [ -f "$WATCH_DIR/$RULES_FILE" ]; then
    # shellcheck disable=SC1090
    source "$WATCH_DIR/$RULES_FILE"
elif [ -f "$RULES_FILE" ]; then
    source "$RULES_FILE"
fi

cd "$WATCH_DIR" || exit 1

dlog() { echo "[rlhf-daemon] $*" >> "$VIOLATIONS_LOG"; }

# ── OS detection ──────────────────────────────────────────────────────────────
get_file_mtime() {
    local file="$1"
    if stat --version > /dev/null 2>&1; then
        # GNU stat (Linux)
        stat -c %Y "$file" 2>/dev/null || echo 0
    else
        # BSD stat (macOS)
        stat -f %m "$file" 2>/dev/null || echo 0
    fi
}

# ── Rule Engine ───────────────────────────────────────────────────────────────

check_rules() {
    local filepath="$1"

    # Skip rlhf control files and the session file itself
    local basename
    basename=$(basename "$filepath")
    case "$basename" in
        .rlhf-*|.agent-session.md|.agent-watchdog.log) return 0 ;;
    esac

    # Rule 1: Session file must exist
    if [ "$REQUIRE_SESSION" = "yes" ] && [ ! -f "$SESSION_FILE" ]; then
        trigger_violation "$filepath" "session_missing" \
            ".agent-session.md does not exist. Run: rlhf-init"
        return
    fi

    # Rule 2: Current Task must be set
    if [ "$REQUIRE_TASK" = "yes" ] && [ -f "$SESSION_FILE" ]; then
        local task
        task=$(grep "^\*\*Current Task:\*\*" "$SESSION_FILE" 2>/dev/null \
               | sed 's/\*\*Current Task:\*\* *//' | xargs)
        if [ -z "$task" ]; then
            trigger_violation "$filepath" "task_not_set" \
                "Current Task is empty in .agent-session.md. Fill it in before editing files."
            return
        fi
    fi

    # Rule 3: Session freshness
    if [ -f "$SESSION_FILE" ]; then
        local max_age_sec=$(( SESSION_MAX_AGE_MIN * 60 ))
        local now; now=$(date +%s)
        local mtime; mtime=$(get_file_mtime "$SESSION_FILE")
        local age=$(( now - mtime ))
        if [ "$age" -gt "$max_age_sec" ]; then
            trigger_violation "$filepath" "session_stale" \
                ".agent-session.md last updated ${SESSION_MAX_AGE_MIN}+ min ago. Update it before editing files."
            return
        fi
    fi

    # Rule 4: Branch check
    if [ "$ENFORCE_BRANCH" = "yes" ] && git rev-parse --git-dir > /dev/null 2>&1; then
        local session_branch current_branch
        session_branch=$(grep "^\*\*Branch:\*\*" "$SESSION_FILE" 2>/dev/null \
                        | sed 's/\*\*Branch:\*\* *//' | xargs)
        current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)

        if [ -n "$session_branch" ] && [ -n "$current_branch" ] \
           && [ "$session_branch" != "$current_branch" ]; then
            trigger_violation "$filepath" "wrong_branch" \
                "On branch '$current_branch' but session expects '$session_branch'. Checkout correct branch first."
            return
        fi
    fi

    # Rule 5: Block direct commits to main/master
    if [ "$BLOCK_MAIN_BRANCH" = "yes" ] && git rev-parse --git-dir > /dev/null 2>&1; then
        local current_branch
        current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
        local IFS=','
        for protected in $MAIN_BRANCH_NAMES; do
            if [ "$current_branch" = "$protected" ]; then
                trigger_violation "$filepath" "protected_branch" \
                    "Direct edits on '$current_branch' are blocked. Create a feature branch first."
                return
            fi
        done
    fi

    # Rule 6: TODO compliance (warn only — task format too varied to hard block)
    if [ "$CHECK_TODO" = "yes" ] && [ -f "$SESSION_FILE" ]; then
        local task
        task=$(grep "^\*\*Current Task:\*\*" "$SESSION_FILE" 2>/dev/null \
               | sed 's/\*\*Current Task:\*\* *//' | xargs)
        local todo_found=false
        for todo_file in $TODO_FILES; do
            if [ -f "$WATCH_DIR/$todo_file" ]; then
                if grep -qF "$task" "$WATCH_DIR/$todo_file" 2>/dev/null; then
                    todo_found=true
                fi
                break
            fi
        done
        if [ "$todo_found" = "false" ]; then
            local ts; ts=$(date '+%H:%M:%S')
            echo "[$ts] WARN | todo_mismatch | Task '$task' not in TODO | $filepath" >> "$VIOLATIONS_LOG"
            # Warn only — not a hard block
        fi
    fi
}

# ── Violation Handler ─────────────────────────────────────────────────────────

trigger_violation() {
    local filepath="$1"
    local rule="$2"
    local message="$3"

    # Cooldown — prevent spam
    local now; now=$(date +%s)
    local last_block; last_block=$(cat "$LASTBLOCK_FILE" 2>/dev/null || echo 0)
    if [ $(( now - last_block )) -lt "$BLOCK_COOLDOWN_SEC" ]; then
        dlog "COOLDOWN | $rule | $filepath"
        return
    fi
    echo "$now" > "$LASTBLOCK_FILE"

    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    dlog "BLOCKED | $ts | $rule | $filepath | $message"

    # Step 1: Revert the file (if tracked by git)
    if [ "$REVERT_ON_VIOLATION" = "yes" ]; then
        if git rev-parse --git-dir > /dev/null 2>&1; then
            if git ls-files --error-unmatch "$filepath" > /dev/null 2>&1; then
                git restore "$filepath" 2>/dev/null \
                    && dlog "Reverted: $filepath" \
                    || dlog "Revert failed: $filepath"
            else
                # Untracked new file — remove it
                rm -f "$filepath" 2>/dev/null \
                    && dlog "Removed untracked: $filepath"
            fi
        fi
    fi

    # Step 2: Write blocked file → picked up by rlhf-run monitor loop
    cat > "$BLOCKED_FILE" << EOF
FILE=$filepath
RULE=$rule
MSG=$message
TIME=$ts
EOF

    # Step 3: Signal wrapper if PID known
    if [ "$WRAPPER_PID" -gt 0 ] 2>/dev/null; then
        kill -USR1 "$WRAPPER_PID" 2>/dev/null || true
    fi

    # Step 4: Prepend violation notice to all instruction files agent might read
    # so it sees the block on next context refresh
    inject_block_notice_to_instr_files "$rule" "$message"
}

inject_block_notice_to_instr_files() {
    local rule="$1"
    local message="$2"
    local ts; ts=$(date '+%H:%M:%S')

    for instr in CLAUDE.md AGENTS.md GEMINI.md OPENCODE.md; do
        if [ -f "$WATCH_DIR/$instr" ]; then
            local notice
            notice="<!-- ⛔ RLHF BLOCK [$ts] Rule: $rule — $message -->"$'\n'
            { printf '%s\n' "$notice"; cat "$WATCH_DIR/$instr"; } \
                > "$WATCH_DIR/${instr}.tmp" \
                && mv "$WATCH_DIR/${instr}.tmp" "$WATCH_DIR/$instr"
        fi
    done
}

# ── File Watchers ─────────────────────────────────────────────────────────────

watch_inotifywait() {
    dlog "Starting watcher: inotifywait"
    inotifywait -m -r -q \
        -e close_write,create,delete,moved_to \
        --exclude "$WATCH_EXCLUDE" \
        --format '%w%f' \
        "$WATCH_DIR" 2>/dev/null | \
    while read -r filepath; do
        check_rules "$filepath"
    done
}

watch_fswatch() {
    dlog "Starting watcher: fswatch"
    fswatch -r \
        -e '\.git' -e '\.rlhf' -e '\.agent-watchdog' -e 'node_modules' \
        "$WATCH_DIR" 2>/dev/null | \
    while read -r filepath; do
        check_rules "$filepath"
    done
}

watch_polling() {
    dlog "Starting watcher: polling (fallback, 2s interval)"
    touch "$LASTCHECK_FILE"
    while true; do
        sleep 2
        find "$WATCH_DIR" -newer "$LASTCHECK_FILE" -type f \
            2>/dev/null | \
        grep -vE "$WATCH_EXCLUDE" | \
        while read -r filepath; do
            check_rules "$filepath"
        done
        touch "$LASTCHECK_FILE"
    done
}

# ── Main ──────────────────────────────────────────────────────────────────────

ts=$(date '+%Y-%m-%d %H:%M:%S')
dlog "=== Daemon started === $ts | PID=$$ | watching: $WATCH_DIR"

if command -v inotifywait > /dev/null 2>&1; then
    watch_inotifywait
elif command -v fswatch > /dev/null 2>&1; then
    watch_fswatch
else
    dlog "WARNING: inotifywait and fswatch not found. Using polling fallback."
    dlog "Install: apt install inotify-tools  OR  brew install fswatch"
    watch_polling
fi
