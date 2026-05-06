#!/bin/bash
# =============================================================================
# setup.sh — One-time install of rlhf-run enforcer
# Run once. Sets up aliases, installs hook template, sets permissions.
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$SCRIPT_DIR/scripts"
HOOKS_DIR="$SCRIPT_DIR/hooks"

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║        rlhf — Setup                ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# 1. Make scripts executable
chmod +x "$SCRIPTS_DIR/rlhf-run.sh"
chmod +x "$SCRIPTS_DIR/rlhf-init.sh"
chmod +x "$SCRIPTS_DIR/rlhf-status.sh"
chmod +x "$HOOKS_DIR/pre-commit"
echo "✓ Permissions set."

# 2. Detect shell config file
if [ -n "${ZSH_VERSION:-}" ] || [ "$(basename "${SHELL:-}")" = "zsh" ]; then
  SHELL_RC="$HOME/.zshrc"
elif [ -n "${BASH_VERSION:-}" ] || [ "$(basename "${SHELL:-}")" = "bash" ]; then
  SHELL_RC="$HOME/.bashrc"
else
  SHELL_RC="$HOME/.profile"
fi

echo "  Shell config: $SHELL_RC"

# 3. Write aliases block
ALIAS_BLOCK="
# ============================================================
# rlhf — AI agent wrapper aliases
# Installed by: $SCRIPT_DIR/setup.sh
# ============================================================
export AGENT_SCRIPTS_DIR=\"$SCRIPTS_DIR\"

alias claude='\"$SCRIPTS_DIR/rlhf-run.sh\" claude'
alias codex='\"$SCRIPTS_DIR/rlhf-run.sh\" codex'
alias gemini='\"$SCRIPTS_DIR/rlhf-run.sh\" gemini'
alias opencode='\"$SCRIPTS_DIR/rlhf-run.sh\" opencode'
alias copilot='\"$SCRIPTS_DIR/rlhf-run.sh\" copilot'

# Session helpers
alias rlhf-init='\"$SCRIPTS_DIR/rlhf-init.sh\"'
alias rlhf-status='\"$SCRIPTS_DIR/rlhf-status.sh\"'

# Escape hatch — run agent raw (no enforcer)
alias claude-raw='command claude'
alias codex-raw='command codex'
alias gemini-raw='command gemini'
# ============================================================
"

# Check if already installed
if grep -q "rlhf" "$SHELL_RC" 2>/dev/null; then
  echo ""
  echo "  ⚠  Aliases already present in $SHELL_RC."
  read -rp "  Overwrite? (y/N): " OVERWRITE
  if [ "$OVERWRITE" != "y" ] && [ "$OVERWRITE" != "Y" ]; then
    echo "  Skipped alias install."
  else
    # Remove old block and re-add
    # Simple approach: append new block (user can clean up manually)
    printf '%s\n' "$ALIAS_BLOCK" >> "$SHELL_RC"
    echo "✓ Aliases updated in $SHELL_RC"
  fi
else
  printf '%s\n' "$ALIAS_BLOCK" >> "$SHELL_RC"
  echo "✓ Aliases added to $SHELL_RC"
fi

# 4. Install git hook template (for new repos)
# Git supports a hooks template dir — any new repo initialized will get the hook
GIT_TEMPLATE_DIR=$(git config --global init.templateDir 2>/dev/null || echo "")

if [ -z "$GIT_TEMPLATE_DIR" ]; then
  TEMPLATE_DIR="$HOME/.git-templates"
  mkdir -p "$TEMPLATE_DIR/hooks"
  git config --global init.templateDir "$TEMPLATE_DIR"
  echo "✓ Git template dir set: $TEMPLATE_DIR"
else
  TEMPLATE_DIR="$GIT_TEMPLATE_DIR"
  mkdir -p "$TEMPLATE_DIR/hooks"
  echo "✓ Git template dir exists: $TEMPLATE_DIR"
fi

cp "$HOOKS_DIR/pre-commit" "$TEMPLATE_DIR/hooks/pre-commit"
chmod +x "$TEMPLATE_DIR/hooks/pre-commit"
echo "✓ Pre-commit hook installed to git template dir."
echo "  New repos (git init) will auto-get the hook."

# 5. Install hook in current repo if inside one
if git rev-parse --git-dir > /dev/null 2>&1; then
  GIT_HOOK_DIR=$(git rev-parse --git-dir)/hooks
  cp "$HOOKS_DIR/pre-commit" "$GIT_HOOK_DIR/pre-commit"
  chmod +x "$GIT_HOOK_DIR/pre-commit"
  echo "✓ Pre-commit hook installed in current repo."
fi

# 6. Summary
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Setup complete. Reload your shell:                          ║"
echo "║    source $SHELL_RC"
echo "║                                                              ║"
echo "║  Workflow:                                                   ║"
echo "║    1. rlhf-init          ← start of every task             ║"
echo "║    2. claude / codex /    ← wrapped automatically           ║"
echo "║       gemini / opencode /                                    ║"
echo "║       copilot                                                ║"
echo "║    3. rlhf-status        ← check state anytime             ║"
echo "║                                                              ║"
echo "║  Watchdog interval: 5 min (override: AGENT_WATCHDOG_INTERVAL)║"
echo "║  Escape hatch: claude-raw / codex-raw (no enforcer)         ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
