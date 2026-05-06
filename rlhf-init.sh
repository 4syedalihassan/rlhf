#!/bin/bash
# =============================================================================
# session-init.sh — Initialize or reset agent session state
# Run at the START of every new work task
# =============================================================================

SESSION_FILE=".agent-session.md"
WATCHDOG_LOG=".agent-watchdog.log"

echo ""
echo "=== Agent Session Init ==="
echo ""

# Prompt for task info
read -rp "Current Task (what are you building/fixing?): " TASK
read -rp "Starting from scratch or continuing? (new/continue): " MODE
read -rp "Working branch (leave blank to use current): " BRANCH

# Get or create branch
if [ -n "$BRANCH" ]; then
  git checkout -b "$BRANCH" 2>/dev/null || git checkout "$BRANCH"
  ACTIVE_BRANCH="$BRANCH"
else
  ACTIVE_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "no-git")
fi

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
LAST_COMMIT=$(git log --oneline -1 2>/dev/null || echo "No commits yet")

if [ "$MODE" = "new" ]; then
  LAST_STEP="N/A — fresh session"
  NEXT_STEP="Begin: $TASK"
else
  # Show last known state if exists
  if [ -f "$SESSION_FILE" ]; then
    echo ""
    echo "--- Last known session state ---"
    cat "$SESSION_FILE"
    echo "--------------------------------"
    echo ""
  fi
  read -rp "Last Completed Step (brief): " LAST_STEP
  read -rp "Next Step to resume: " NEXT_STEP
fi

# Write session file
cat > "$SESSION_FILE" << EOF
# Agent Session State
> Last updated: $TIMESTAMP

**Current Task:** $TASK
**Branch:** $ACTIVE_BRANCH
**Mode:** $MODE
**Last Completed Step:** $LAST_STEP
**Next Step:** $NEXT_STEP
**Blockers:** None
**Files Modified:** (agent will update)
**Session Started:** $TIMESTAMP
**Last Commit:** $LAST_COMMIT

---
## Session Log
- [$TIMESTAMP] Session initialized ($MODE)
EOF

# Commit the session init
if git rev-parse --git-dir > /dev/null 2>&1; then
  git add "$SESSION_FILE"
  git commit -m "🚀 session-init: $TASK" --no-verify 2>/dev/null \
    && echo "" \
    && echo "[rlhf-init] Committed session state." \
    || echo "[rlhf-init] Note: nothing to commit or commit failed."
fi

# Reset watchdog log
echo "=== Watchdog Log — Session: $TIMESTAMP ===" > "$WATCHDOG_LOG"

echo ""
echo "✓ Session initialized."
echo "  Task:   $TASK"
echo "  Branch: $ACTIVE_BRANCH"
echo "  File:   $SESSION_FILE"
echo ""
echo "Now run your agent via wrapper:"
echo "  claude   → use alias or: rlhf-run.sh claude"
echo "  codex    → rlhf-run.sh codex"
echo "  gemini   → rlhf-run.sh gemini"
echo ""
