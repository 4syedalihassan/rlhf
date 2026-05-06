#!/bin/bash
# =============================================================================
# rlhf-run.sh — Universal AI Agent Wrapper
# Enforces: session continuity, git checkpoints, context injection
#
# Usage:
#   rlhf-run.sh claude  [args...]
#   rlhf-run.sh codex   [args...]
#   rlhf-run.sh gemini  [args...]
#   rlhf-run.sh opencode [args...]
#   rlhf-run.sh copilot [args...]
# =============================================================================

set -euo pipefail

# --- Config ------------------------------------------------------------------

AGENT_CMD="${1:-}"
shift || true
ARGS=("$@")

SESSION_FILE=".agent-session.md"
WATCHDOG_LOG=".agent-watchdog.log"
WATCHDOG_INTERVAL="${AGENT_WATCHDOG_INTERVAL:-300}"   # default 5 min, override via env
WATCHDOG_PID=""

# Per-agent instruction file mapping
case "$AGENT_CMD" in
  claude)    INSTR_FILE="CLAUDE.md" ;;
  codex)     INSTR_FILE="AGENTS.md" ;;
  gemini)    INSTR_FILE="GEMINI.md" ;;
  opencode)  INSTR_FILE="OPENCODE.md" ;;
  copilot)   INSTR_FILE=".github/copilot-instructions.md" ;;
  *)
    echo "[rlhf-run] ERROR: Unknown agent '$AGENT_CMD'"
    echo "  Supported: claude | codex | gemini | opencode | copilot"
    exit 1
    ;;
esac

INSTR_BACKUP="${INSTR_FILE}.agent-bak"

# --- Helpers -----------------------------------------------------------------

log()  { echo "[rlhf-run] $*"; }
warn() { echo "[rlhf-run] WARN: $*" >&2; }

in_git_repo() {
  git rev-parse --git-dir > /dev/null 2>&1
}

# --- Session Context Injection -----------------------------------------------
# Prepends live session state + git history into the agent's instruction file.
# Agent reads its own instruction file at startup — this is how context survives.

inject_context() {
  mkdir -p "$(dirname "$INSTR_FILE")"
  touch "$INSTR_FILE"

  # Backup original (clean, no injected block)
  cp "$INSTR_FILE" "$INSTR_BACKUP"

  SESSION_CONTENT=$(cat "$SESSION_FILE" 2>/dev/null || echo "_No prior session. Fresh start._")

  if in_git_repo; then
    GIT_LOG=$(git log --oneline -10 2>/dev/null || echo "No commits yet.")
    GIT_STATUS=$(git status --short 2>/dev/null || echo "Clean.")
    GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
  else
    GIT_LOG="Not a git repo."
    GIT_STATUS="N/A"
    GIT_BRANCH="N/A"
  fi

  TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

  INJECT_BLOCK="<!-- ============================================================ -->
<!-- AGENT-RUN: AUTO-INJECTED CONTEXT BLOCK — DO NOT EDIT        -->
<!-- Injected: $TIMESTAMP                              -->
<!-- ============================================================ -->

## 🔄 ACTIVE SESSION STATE

$SESSION_CONTENT

## 📜 RECENT GIT HISTORY (branch: $GIT_BRANCH)
\`\`\`
$GIT_LOG
\`\`\`

## 📂 CURRENT WORKING CHANGES
\`\`\`
$GIT_STATUS
\`\`\`

## ⚠️  MANDATORY RULES — NON-NEGOTIABLE — FOLLOW EVERY STEP

### BEFORE touching any file:
1. Read \`.agent-session.md\` — understand current task state
2. Confirm you are on the correct git branch
3. Run \`git status\` — never work on dirty state blindly

### AFTER every logical unit of work (NOT end of session — DURING):
\`\`\`bash
# Update session file FIRST
# Then commit BOTH your work AND the session file together
git add -A && git commit -m \"checkpoint: [describe what was just completed]\"
\`\`\`

### .agent-session.md MUST contain before every commit:
- **Current Task:** what the overall goal is
- **Last Completed Step:** exactly what was just done
- **Next Step:** what comes next
- **Blockers:** anything stuck or unclear
- **Files Modified:** key files changed this session

### NEVER:
- Work more than 15 minutes without a commit
- Skip updating \`.agent-session.md\`
- Assume context from a previous session survives — it does NOT
- Leave work uncommitted when session ends or pauses

### ON SESSION START — always run these first:
\`\`\`bash
cat .agent-session.md
git log --oneline -10
git status
\`\`\`

<!-- END AGENT-RUN INJECTED BLOCK -->
<!-- ============================================================ -->

"

  # Prepend inject block to instruction file
  printf '%s\n' "$INJECT_BLOCK" | cat - "$INSTR_BACKUP" > "$INSTR_FILE"
  log "Context injected → $INSTR_FILE"
}

restore_instr_file() {
  if [ -f "$INSTR_BACKUP" ]; then
    mv "$INSTR_BACKUP" "$INSTR_FILE"
    log "Restored $INSTR_FILE"
  fi
}

# --- Watchdog ----------------------------------------------------------------
# Background process. Commits every N seconds if there are uncommitted changes.
# Independent of the agent — runs even if agent freezes or loses context.

start_watchdog() {
  (
    WPID=$$
    echo "[rlhf-watchdog:$WPID] Started at $(date '+%Y-%m-%d %H:%M:%S') interval=${WATCHDOG_INTERVAL}s" >> "$WATCHDOG_LOG"

    while true; do
      sleep "$WATCHDOG_INTERVAL"

      if ! in_git_repo; then
        continue
      fi

      CHANGES=$(git status --porcelain 2>/dev/null)
      if [ -n "$CHANGES" ]; then
        TSTAMP=$(date '+%H:%M:%S')
        git add -A

        # Auto-update session file if agent forgot
        if ! git diff --cached --name-only | grep -q ".agent-session.md"; then
          echo "" >> "$SESSION_FILE"
          echo "_[rlhf-watchdog auto-checkpoint at $TSTAMP]_" >> "$SESSION_FILE"
          git add "$SESSION_FILE"
        fi

        git commit -m "⏱ watchdog-checkpoint [$TSTAMP]" --no-verify \
          >> "$WATCHDOG_LOG" 2>&1 \
          && echo "[rlhf-watchdog:$WPID] Committed at $TSTAMP" >> "$WATCHDOG_LOG" \
          || echo "[rlhf-watchdog:$WPID] Commit failed at $TSTAMP" >> "$WATCHDOG_LOG"
      else
        echo "[rlhf-watchdog:$WPID] No changes at $(date '+%H:%M:%S')" >> "$WATCHDOG_LOG"
      fi
    done
  ) &
  echo $!
}

stop_watchdog() {
  if [ -n "$WATCHDOG_PID" ]; then
    kill "$WATCHDOG_PID" 2>/dev/null || true
    log "Watchdog stopped (PID=$WATCHDOG_PID)"
  fi
}

# --- Session End Commit -------------------------------------------------------

commit_session_end() {
  if ! in_git_repo; then return; fi

  CHANGES=$(git status --porcelain 2>/dev/null)
  if [ -n "$CHANGES" ]; then
    git add -A
    git commit -m "🏁 session-end [$(date '+%Y-%m-%d %H:%M')]" --no-verify \
      && log "Session-end commit done." \
      || warn "Session-end commit failed — check git status manually."
  else
    log "No uncommitted changes at session end."
  fi
}

# --- Cleanup on exit ---------------------------------------------------------

cleanup() {
  restore_instr_file
  stop_watchdog
  commit_session_end
  log "Cleanup complete."
}

trap cleanup EXIT INT TERM HUP

# --- Pre-flight checks -------------------------------------------------------

if ! command -v "$AGENT_CMD" > /dev/null 2>&1; then
  warn "'$AGENT_CMD' not found in PATH. Continuing anyway..."
fi

if ! in_git_repo; then
  warn "Not inside a git repo. Watchdog and commits disabled."
  WATCHDOG_INTERVAL=0
fi

if [ ! -f "$SESSION_FILE" ]; then
  log "No .agent-session.md found. Run rlhf-init first, or one will be created."
  cat > "$SESSION_FILE" << 'EOF'
# Agent Session State
_Auto-created. Fill this in before starting work._

**Current Task:** 
**Last Completed Step:** N/A — session just started
**Next Step:** 
**Blockers:** None
**Files Modified:** None yet
**Started:** $(date '+%Y-%m-%d %H:%M')
EOF
fi

# --- Main --------------------------------------------------------------------

inject_context

if in_git_repo && [ "$WATCHDOG_INTERVAL" -gt 0 ]; then
  WATCHDOG_PID=$(start_watchdog)
  log "Watchdog started (PID=$WATCHDOG_PID, interval=${WATCHDOG_INTERVAL}s)"
fi

log "Launching: $AGENT_CMD ${ARGS[*]:-}"
echo "---"

"$AGENT_CMD" "${ARGS[@]}"
EXIT_CODE=$?

log "Agent exited (code=$EXIT_CODE)"
exit $EXIT_CODE
