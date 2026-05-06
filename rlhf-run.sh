#!/bin/bash
# =============================================================================
# rlhf-run.sh — Universal AI Agent Wrapper
# Enforces: session continuity, git checkpoints, context injection,
#           filesystem rule enforcement via rlhf-daemon
#
# Usage:
#   rlhf-run.sh claude  [args...]
#   rlhf-run.sh codex   [args...]
# =============================================================================

set -uo pipefail

AGENT_CMD="${1:-}"
shift || true
ARGS=("$@")

SESSION_FILE=".agent-session.md"
WATCHDOG_LOG=".agent-watchdog.log"
BLOCKED_FILE=".rlhf-blocked"
RULES_FILE=".rlhf-rules"

WATCHDOG_INTERVAL="${AGENT_WATCHDOG_INTERVAL:-300}"
WATCHDOG_PID=""
DAEMON_PID=""
MONITOR_PID=""
AGENT_PID=""

case "$AGENT_CMD" in
  claude)    INSTR_FILE="CLAUDE.md" ;;
  codex)     INSTR_FILE="AGENTS.md" ;;
  gemini)    INSTR_FILE="GEMINI.md" ;;
  opencode)  INSTR_FILE="OPENCODE.md" ;;
  copilot)   INSTR_FILE=".github/copilot-instructions.md" ;;
  *)
    echo "[rlhf] ERROR: Unknown agent '$AGENT_CMD'"
    echo "  Supported: claude | codex | gemini | opencode | copilot"
    exit 1 ;;
esac

INSTR_BACKUP="${INSTR_FILE}.agent-bak"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { echo "[rlhf] $*"; }
warn() { echo "[rlhf] WARN: $*" >&2; }
in_git_repo() { git rev-parse --git-dir > /dev/null 2>&1; }

# ── Context Injection ─────────────────────────────────────────────────────────

inject_context() {
    mkdir -p "$(dirname "$INSTR_FILE")"
    touch "$INSTR_FILE"
    cp "$INSTR_FILE" "$INSTR_BACKUP"

    local session_content git_log git_status git_branch timestamp
    session_content=$(cat "$SESSION_FILE" 2>/dev/null || echo "_No prior session. Fresh start._")
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    if in_git_repo; then
        git_log=$(git log --oneline -10 2>/dev/null || echo "No commits yet.")
        git_status=$(git status --short 2>/dev/null || echo "Clean.")
        git_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    else
        git_log="Not a git repo."; git_status="N/A"; git_branch="N/A"
    fi

    local inject_block
    inject_block="<!-- RLHF INJECTED $timestamp -->

## ACTIVE SESSION STATE
$session_content

## GIT HISTORY (branch: $git_branch)
\`\`\`
$git_log
\`\`\`
## WORKING CHANGES
\`\`\`
$git_status
\`\`\`

## MANDATORY RULES
- Update .agent-session.md before every commit
- Run: git add -A && git commit -m 'checkpoint: ...' after each logical unit
- Never work >15 min without a commit
- Never assume previous session context survives

<!-- END RLHF BLOCK -->

"
    printf '%s\n' "$inject_block" | cat - "$INSTR_BACKUP" > "$INSTR_FILE"
    log "Context injected -> $INSTR_FILE"
}

restore_instr_file() {
    [ -f "$INSTR_BACKUP" ] && mv "$INSTR_BACKUP" "$INSTR_FILE" && log "Restored $INSTR_FILE"
}

# ── Watchdog ──────────────────────────────────────────────────────────────────

start_watchdog() {
    (
        echo "[watchdog:$$] started interval=${WATCHDOG_INTERVAL}s" >> "$WATCHDOG_LOG"
        while true; do
            sleep "$WATCHDOG_INTERVAL"
            in_git_repo || continue
            local changes; changes=$(git status --porcelain 2>/dev/null)
            [ -z "$changes" ] && continue
            local ts; ts=$(date '+%H:%M:%S')
            git add -A
            if ! git diff --cached --name-only | grep -q ".agent-session.md"; then
                printf '\n_[watchdog %s]_\n' "$ts" >> "$SESSION_FILE"
                git add "$SESSION_FILE"
            fi
            git commit -m "watchdog-checkpoint [$ts]" --no-verify >> "$WATCHDOG_LOG" 2>&1
        done
    ) &
    echo $!
}

# ── Daemon ────────────────────────────────────────────────────────────────────

start_daemon() {
    local daemon_script="$SCRIPT_DIR/rlhf-daemon.sh"
    if [ ! -f "$daemon_script" ]; then
        warn "rlhf-daemon.sh not found — rule enforcement disabled."
        echo ""
        return
    fi
    bash "$daemon_script" "$(pwd)" "$$" "$RULES_FILE" &
    echo $!
}

# ── Violation Monitor ─────────────────────────────────────────────────────────
# Polls .rlhf-blocked every 300ms.
# On violation: SIGSTOP agent, show message, wait for user, SIGCONT.

start_monitor() {
    (
        local agent_pid="$1"
        while true; do
            sleep 0.3
            [ ! -f "$BLOCKED_FILE" ] && continue
            [ -z "$agent_pid" ] && continue

            # Parse violation
            local v_file v_rule v_msg v_time
            v_file=$(grep '^FILE=' "$BLOCKED_FILE" 2>/dev/null | cut -d= -f2-)
            v_rule=$(grep '^RULE=' "$BLOCKED_FILE" 2>/dev/null | cut -d= -f2-)
            v_msg=$(grep  '^MSG='  "$BLOCKED_FILE" 2>/dev/null | cut -d= -f2-)
            v_time=$(grep '^TIME=' "$BLOCKED_FILE" 2>/dev/null | cut -d= -f2-)
            rm -f "$BLOCKED_FILE"

            # Freeze agent
            kill -STOP "$agent_pid" 2>/dev/null || continue

            # Print to terminal
            {
                printf '\a'
                echo ""
                echo "╔══════════════════════════════════════════════════════════════╗"
                echo "║  ⛔  RLHF BLOCKED — AGENT SUSPENDED                         ║"
                echo "╠══════════════════════════════════════════════════════════════╣"
                printf "║  Rule  : %-51s ║\n" "$v_rule"
                printf "║  File  : %-51s ║\n" "$(basename "$v_file")"
                printf "║  Reason: %-51s ║\n" "$v_msg"
                printf "║  Time  : %-51s ║\n" "$v_time"
                echo "╠══════════════════════════════════════════════════════════════╣"
                echo "║  File has been REVERTED. Agent is FROZEN.                   ║"
                echo "║  [Enter] Resume    [q] Quit                                 ║"
                echo "╚══════════════════════════════════════════════════════════════╝"
                printf "\n> "
            } > /dev/tty

            local choice
            read -r choice < /dev/tty

            case "$choice" in
                q|Q)
                    echo "[rlhf] Aborted." > /dev/tty
                    kill "$agent_pid" 2>/dev/null ;;
                *)
                    echo "[rlhf] Resuming..." > /dev/tty
                    kill -CONT "$agent_pid" 2>/dev/null ;;
            esac
        done
    ) "$AGENT_PID" &
    echo $!
}

# ── Session End Commit ────────────────────────────────────────────────────────

commit_session_end() {
    in_git_repo || return
    local changes; changes=$(git status --porcelain 2>/dev/null)
    [ -z "$changes" ] && log "Clean at session end." && return
    git add -A
    git commit -m "session-end [$(date '+%Y-%m-%d %H:%M')]" --no-verify \
        && log "Session-end commit done." \
        || warn "Session-end commit failed."
}

# ── Cleanup ───────────────────────────────────────────────────────────────────

cleanup() {
    [ -n "$MONITOR_PID"  ] && kill "$MONITOR_PID"  2>/dev/null || true
    [ -n "$DAEMON_PID"   ] && kill "$DAEMON_PID"   2>/dev/null || true
    [ -n "$WATCHDOG_PID" ] && kill "$WATCHDOG_PID" 2>/dev/null || true
    restore_instr_file
    commit_session_end
    rm -f "$BLOCKED_FILE" 2>/dev/null
    log "Cleanup done."
}

trap cleanup EXIT INT TERM HUP

# ── Pre-flight ────────────────────────────────────────────────────────────────

command -v "$AGENT_CMD" > /dev/null 2>&1 || warn "'$AGENT_CMD' not in PATH."
in_git_repo || { warn "Not a git repo. Watchdog/commits disabled."; WATCHDOG_INTERVAL=0; }

if [ ! -f "$SESSION_FILE" ]; then
    log "No session file. Run rlhf-init first."
    printf '# Agent Session State\n**Current Task:**\n**Branch:**\n**Last Completed Step:** N/A\n**Next Step:**\n**Blockers:** None\n' > "$SESSION_FILE"
fi

# ── Launch ────────────────────────────────────────────────────────────────────

inject_context

if in_git_repo && [ "${WATCHDOG_INTERVAL:-0}" -gt 0 ]; then
    WATCHDOG_PID=$(start_watchdog)
    log "Watchdog PID=$WATCHDOG_PID interval=${WATCHDOG_INTERVAL}s"
fi

DAEMON_PID=$(start_daemon)
[ -n "$DAEMON_PID" ] && log "Daemon PID=$DAEMON_PID"

log "Launching: $AGENT_CMD ${ARGS[*]:-}"
echo "---"

"$AGENT_CMD" "${ARGS[@]}" &
AGENT_PID=$!

MONITOR_PID=$(start_monitor)
log "Monitor PID=$MONITOR_PID"

# Wait for agent — this is interruptible by signals
wait "$AGENT_PID" 2>/dev/null || true
EXIT_CODE=$?

log "Agent exited (code=$EXIT_CODE)"
exit $EXIT_CODE
