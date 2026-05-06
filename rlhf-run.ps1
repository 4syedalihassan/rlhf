# =============================================================================
# rlhf-run.ps1 — Universal AI Agent Wrapper (Windows / PowerShell)
# Enforces: session continuity, git checkpoints, context injection
#
# Usage:
#   .\rlhf-run.ps1 claude  [args...]
#   .\rlhf-run.ps1 codex   [args...]
#   .\rlhf-run.ps1 gemini  [args...]
#   .\rlhf-run.ps1 opencode [args...]
#   .\rlhf-run.ps1 copilot [args...]
# =============================================================================

param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$AgentCmd,

    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$AgentArgs
)

$ErrorActionPreference = 'Stop'

# --- Config ------------------------------------------------------------------

$SessionFile    = ".agent-session.md"
$WatchdogLog    = ".agent-watchdog.log"
$WatchdogIntervalSec = if ($env:AGENT_WATCHDOG_INTERVAL) { [int]$env:AGENT_WATCHDOG_INTERVAL } else { 300 }
$WatchdogJob    = $null

$InstrFileMap = @{
    'claude'    = 'CLAUDE.md'
    'codex'     = 'AGENTS.md'
    'gemini'    = 'GEMINI.md'
    'opencode'  = 'OPENCODE.md'
    'copilot'   = '.github\copilot-instructions.md'
}

if (-not $InstrFileMap.ContainsKey($AgentCmd)) {
    Write-Host "[rlhf] ERROR: Unknown agent '$AgentCmd'" -ForegroundColor Red
    Write-Host "  Supported: claude | codex | gemini | opencode | copilot"
    exit 1
}

$InstrFile   = $InstrFileMap[$AgentCmd]
$InstrBackup = "$InstrFile.agent-bak"
$WorkDir     = (Get-Location).Path

# --- Helpers -----------------------------------------------------------------

function Log($msg)  { Write-Host "[rlhf] $msg" -ForegroundColor Cyan }
function Warn($msg) { Write-Host "[rlhf] WARN: $msg" -ForegroundColor Yellow }

function Test-GitRepo {
    $null = git rev-parse --git-dir 2>&1
    return $LASTEXITCODE -eq 0
}

function Get-GitInfo {
    if (Test-GitRepo) {
        $log    = (git log --oneline -10 2>&1) -join "`n"
        $status = (git status --short 2>&1) -join "`n"
        $branch = (git rev-parse --abbrev-ref HEAD 2>&1) | Select-Object -First 1
        if (-not $log)    { $log    = "No commits yet." }
        if (-not $status) { $status = "Clean." }
        if (-not $branch) { $branch = "unknown" }
    } else {
        $log = "Not a git repo."; $status = "N/A"; $branch = "N/A"
    }
    return @{ Log = $log; Status = $status; Branch = $branch }
}

# --- Context Injection -------------------------------------------------------

function Inject-Context {
    # Ensure parent dir exists (e.g. .github/)
    $dir = Split-Path $InstrFile -Parent
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    # Create instruction file if missing
    if (-not (Test-Path $InstrFile)) {
        New-Item -ItemType File -Force -Path $InstrFile | Out-Null
    }

    # Backup original
    Copy-Item $InstrFile $InstrBackup -Force

    $sessionContent = if (Test-Path $SessionFile) {
        Get-Content $SessionFile -Raw -Encoding UTF8
    } else {
        "_No prior session. Fresh start._"
    }

    $git       = Get-GitInfo
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    $injectBlock = @"
<!-- ============================================================ -->
<!-- RLHF: AUTO-INJECTED CONTEXT BLOCK — DO NOT EDIT             -->
<!-- Injected: $timestamp                                         -->
<!-- ============================================================ -->

## ACTIVE SESSION STATE

$sessionContent

## RECENT GIT HISTORY (branch: $($git.Branch))
``````
$($git.Log)
``````

## CURRENT WORKING CHANGES
``````
$($git.Status)
``````

## MANDATORY RULES — NON-NEGOTIABLE — FOLLOW EVERY STEP

### BEFORE touching any file:
1. Read `.agent-session.md` — understand current task state
2. Confirm you are on the correct git branch
3. Run `git status` — never work on dirty state blindly

### AFTER every logical unit of work (NOT end of session — DURING):
``````bash
git add -A && git commit -m "checkpoint: [describe what was just completed]"
``````

### .agent-session.md MUST contain before every commit:
- **Current Task:** what the overall goal is
- **Last Completed Step:** exactly what was just done
- **Next Step:** what comes next
- **Blockers:** anything stuck or unclear
- **Files Modified:** key files changed this session

### NEVER:
- Work more than 15 minutes without a commit
- Skip updating `.agent-session.md`
- Assume context from a previous session survives — it does NOT
- Leave work uncommitted when session ends or pauses

<!-- END RLHF INJECTED BLOCK -->
<!-- ============================================================ -->

"@

    $originalContent = Get-Content $InstrBackup -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    $newContent = $injectBlock + "`n" + $originalContent
    Set-Content $InstrFile $newContent -Encoding UTF8 -NoNewline

    Log "Context injected -> $InstrFile"
}

function Restore-InstrFile {
    if (Test-Path $InstrBackup) {
        Move-Item $InstrBackup $InstrFile -Force
        Log "Restored $InstrFile"
    }
}

# --- Watchdog ----------------------------------------------------------------
# Runs as a background PowerShell job.
# Commits every N seconds if uncommitted changes exist.

$WatchdogScriptBlock = {
    param($WorkDir, $IntervalSec, $SessionFile, $WatchdogLog)

    Set-Location $WorkDir
    $pid_self = $PID
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content $WatchdogLog "[rlhf-watchdog:$pid_self] Started at $timestamp interval=${IntervalSec}s"

    while ($true) {
        Start-Sleep -Seconds $IntervalSec

        $isGit = $null
        $null = git rev-parse --git-dir 2>&1
        if ($LASTEXITCODE -ne 0) { continue }

        $changes = git status --porcelain 2>&1
        if ($changes) {
            $ts = Get-Date -Format 'HH:mm:ss'
            git add -A 2>&1 | Out-Null

            # Check if session file is staged; if not, append note and stage it
            $staged = git diff --cached --name-only 2>&1
            if ($staged -notcontains ".agent-session.md" -and (Test-Path $SessionFile)) {
                Add-Content $SessionFile "`n_[rlhf-watchdog auto-checkpoint at $ts]_"
                git add $SessionFile 2>&1 | Out-Null
            }

            $result = git commit -m "watchdog-checkpoint [$ts]" --no-verify 2>&1
            if ($LASTEXITCODE -eq 0) {
                Add-Content $WatchdogLog "[rlhf-watchdog:$pid_self] Committed at $ts"
            } else {
                Add-Content $WatchdogLog "[rlhf-watchdog:$pid_self] Commit failed at $ts - $result"
            }
        } else {
            $ts = Get-Date -Format 'HH:mm:ss'
            Add-Content $WatchdogLog "[rlhf-watchdog:$pid_self] No changes at $ts"
        }
    }
}

function Start-Watchdog {
    $job = Start-Job `
        -ScriptBlock $WatchdogScriptBlock `
        -ArgumentList $WorkDir, $WatchdogIntervalSec, $SessionFile, $WatchdogLog
    return $job
}

function Stop-WatchdogJob {
    if ($WatchdogJob) {
        Stop-Job  -Job $WatchdogJob -ErrorAction SilentlyContinue
        Remove-Job -Job $WatchdogJob -Force -ErrorAction SilentlyContinue
        Log "Watchdog stopped (Job ID=$($WatchdogJob.Id))"
    }
}

# --- Session End Commit -------------------------------------------------------

function Commit-SessionEnd {
    if (-not (Test-GitRepo)) { return }
    $changes = git status --porcelain 2>&1
    if ($changes) {
        git add -A
        $ts = Get-Date -Format 'yyyy-MM-dd HH:mm'
        git commit -m "session-end [$ts]" --no-verify 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Log "Session-end commit done."
        } else {
            Warn "Session-end commit failed — check git status manually."
        }
    } else {
        Log "No uncommitted changes at session end."
    }
}

# --- Cleanup -----------------------------------------------------------------

function Invoke-Cleanup {
    Restore-InstrFile
    Stop-WatchdogJob
    Commit-SessionEnd
    Log "Cleanup complete."
}

# --- Pre-flight --------------------------------------------------------------

if (-not (Get-Command $AgentCmd -ErrorAction SilentlyContinue)) {
    Warn "'$AgentCmd' not found in PATH. Continuing anyway..."
}

$inGit = Test-GitRepo
if (-not $inGit) {
    Warn "Not inside a git repo. Watchdog and commits disabled."
    $WatchdogIntervalSec = 0
}

if (-not (Test-Path $SessionFile)) {
    Log "No .agent-session.md found. Run rlhf-init first, or one will be created."
    $autoSession = @"
# Agent Session State
_Auto-created. Fill this in before starting work._

**Current Task:** 
**Last Completed Step:** N/A - session just started
**Next Step:** 
**Blockers:** None
**Files Modified:** None yet
**Started:** $(Get-Date -Format 'yyyy-MM-dd HH:mm')
"@
    Set-Content $SessionFile $autoSession -Encoding UTF8
}

# --- Main --------------------------------------------------------------------

try {
    Inject-Context

    if ($inGit -and $WatchdogIntervalSec -gt 0) {
        $WatchdogJob = Start-Watchdog
        Log "Watchdog started (Job ID=$($WatchdogJob.Id), interval=${WatchdogIntervalSec}s)"
    }

    Log "Launching: $AgentCmd $($AgentArgs -join ' ')"
    Write-Host "---"

    if ($AgentArgs -and $AgentArgs.Count -gt 0) {
        & $AgentCmd @AgentArgs
    } else {
        & $AgentCmd
    }
    $exitCode = $LASTEXITCODE

    Log "Agent exited (code=$exitCode)"

} finally {
    Invoke-Cleanup
}

exit $exitCode
