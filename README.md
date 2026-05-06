# rlhf

> Reinforcement Learning from Human Frustration

![rlhf logo](rlhf-logo.png)

AI coding agents drift. They forget instructions mid-session, stop committing to git, and when a terminal dies — so does your progress. `rlhf` wraps every agent call with mechanical enforcement: context injection at launch, a background watchdog that auto-commits every N minutes no matter what the agent is doing, and a pre-commit hook that blocks commits missing session state.

No more "the agent forgot to use git." No more lost work after a crashed session.

---

## How It Works

```
You → rlhf-run.sh → agent (claude / codex / gemini / opencode / copilot)
           │
           ├── Injects .agent-session.md + git history into instruction file at launch
           ├── Starts background watchdog (auto-commits every 5 min if changes exist)
           └── On exit: restores instruction file, commits any remaining work
```

Three enforcement layers that run **outside** the model — agent drift cannot stop them:

| Layer | What it does |
|---|---|
| **Context injection** | Prepends live session state + git log into the agent's instruction file before launch |
| **Watchdog** | Background process commits every N minutes regardless of agent behavior |
| **Pre-commit hook** | Blocks any commit where `.agent-session.md` wasn't updated alongside code |

---

## Supported Agents

| Agent | Command | Instruction File |
|---|---|---|
| Claude Code | `claude` | `CLAUDE.md` |
| OpenAI Codex CLI | `codex` | `AGENTS.md` |
| Gemini CLI | `gemini` | `GEMINI.md` |
| OpenCode | `opencode` | `OPENCODE.md` |
| GitHub Copilot CLI | `copilot` | `.github/copilot-instructions.md` |

---

## Install

**Requirements:** bash, git, any of the supported agents in `$PATH`.

```bash
git clone https://github.com/yourname/rlhf.git ~/rlhf
cd ~/rlhf
chmod +x setup.sh && ./setup.sh
source ~/.zshrc   # or ~/.bashrc
```

`setup.sh` does four things:
1. Sets execute permissions on all scripts
2. Adds aliases to your shell config (`claude`, `codex`, `gemini`, `opencode`, `copilot` → all wrapped)
3. Installs the pre-commit hook to your git template dir (all future `git init` repos get it automatically)
4. Installs the hook into your current repo if you're inside one

After setup, calling `claude` runs the wrapper. Use `claude-raw` to bypass entirely.

---

## Usage

### Every new task — run this first:

```bash
cd your-project
rlhf-init
```

`rlhf-init` prompts for task description and branch, writes `.agent-session.md`, and makes an initial commit. The session file is the source of truth the agent reads at launch and updates throughout.

### Then run your agent normally:

```bash
claude          # Claude Code — wrapped
codex           # Codex CLI — wrapped
gemini          # Gemini CLI — wrapped
opencode        # OpenCode — wrapped
copilot         # GitHub Copilot CLI — wrapped
```

The wrapper handles everything. You don't change how you use the agent.

### Check state mid-session:

```bash
rlhf-status
```

Shows current session file, git status, last 10 commits, and recent watchdog activity.

---

## Session File

`.agent-session.md` lives in your repo root. The agent reads it at launch (injected into its instruction file) and must update it before every commit.

```markdown
# Agent Session State

**Current Task:** Refactor auth module to use JWT
**Branch:** feature/jwt-auth
**Last Completed Step:** Replaced session middleware with JWT verify fn
**Next Step:** Update tests to mock JWT instead of session cookies
**Blockers:** None
**Files Modified:** src/middleware/auth.js, src/routes/login.js
**Session Started:** 2025-01-15 14:30:00
**Last Commit:** abc1234 checkpoint: JWT middleware complete

---
## Session Log
- [14:30] Session initialized
- [14:55] checkpoint: base JWT implementation done
- [15:20] rlhf-watchdog-checkpoint [auto]
```

Commit the session file alongside your code. The pre-commit hook enforces this.

---

## Configuration

| Variable | Default | Description |
|---|---|---|
| `AGENT_WATCHDOG_INTERVAL` | `300` | Seconds between watchdog auto-commits |

```bash
# Example: commit every 2 minutes
export AGENT_WATCHDOG_INTERVAL=120
```

Add to `.zshrc` / `.bashrc` to persist.

---

## File Structure

```
rlhf/
├── setup.sh                          # one-time install
├── rlhf-logo.png                     # project logo
├── README.md
├── scripts/
│   ├── rlhf-run.sh                   # main wrapper — wraps all agents
│   ├── rlhf-init.sh                  # initialize session before each task
│   └── rlhf-status.sh                # view current session state
├── hooks/
│   └── pre-commit                    # git hook — blocks commits missing session update
└── .agent-session.template.md        # blank session file template
```

---

## Pre-Commit Hook

The hook runs on every `git commit` (except `--no-verify`, which the watchdog uses intentionally).

Blocks if:
- `.agent-session.md` doesn't exist
- Code files are staged but `.agent-session.md` is not
- `Current Task` field is empty

```
╔══════════════════════════════════════════════════════════╗
║  PRE-COMMIT BLOCKED: .agent-session.md not staged        ║
╚══════════════════════════════════════════════════════════╝

  You are committing code without updating session state.
  Update .agent-session.md with:
    - Last Completed Step
    - Next Step
  Then: git add .agent-session.md
```

To install the hook in an existing repo manually:

```bash
cp ~/rlhf/hooks/pre-commit .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
```

---

## Escape Hatches

```bash
claude-raw      # run claude with no wrapper
codex-raw       # run codex with no wrapper
gemini-raw      # run gemini with no wrapper

git commit --no-verify   # skip pre-commit hook (watchdog uses this)
```

---

## Adding a New Repo

```bash
cd new-project
git init                # pre-commit hook auto-installed via git template dir
rlhf-init               # create session file, set task, initial commit
claude                  # start working
```

---

## Why Not Just Use Instruction Files?

Instruction files (CLAUDE.md, AGENTS.md, etc.) are read at session start but:

- Context window fills → instructions get diluted → agent drifts
- Nothing forces the agent to actually commit
- Session crash = all state lost

`rlhf` enforces behavior *outside* the model. The watchdog doesn't care if the agent forgot — it commits anyway. The hook doesn't care if the agent skipped the update — it blocks the commit.

The name is the reason. You've been there.

---

## Contributing

PRs welcome. Key areas:
- Support for additional agents
- Cross-platform support (currently bash / Linux / macOS)
- Windows (WSL) testing

---

## License

MIT
