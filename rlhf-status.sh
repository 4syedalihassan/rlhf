#!/bin/bash
# =============================================================================
# session-status.sh — Quick view of current agent session state
# =============================================================================

SESSION_FILE=".agent-session.md"
WATCHDOG_LOG=".agent-watchdog.log"

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║           AGENT SESSION STATUS               ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# Session state
echo "── SESSION STATE ──────────────────────────────"
if [ -f "$SESSION_FILE" ]; then
  cat "$SESSION_FILE"
else
  echo "  ⚠  No .agent-session.md found. Run rlhf-init"
fi

echo ""
echo "── GIT STATUS ─────────────────────────────────"
if git rev-parse --git-dir > /dev/null 2>&1; then
  echo "Branch : $(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  echo "Status :"
  git status --short
  echo ""
  echo "Last 10 commits:"
  git log --oneline -10
else
  echo "  Not a git repo."
fi

echo ""
echo "── WATCHDOG LOG (last 20 lines) ───────────────"
if [ -f "$WATCHDOG_LOG" ]; then
  tail -20 "$WATCHDOG_LOG"
else
  echo "  No watchdog log yet."
fi
echo ""
