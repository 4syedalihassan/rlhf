# =============================================================================
# rlhf-init.ps1 — Initialize or reset agent session state (Windows)
# Run at the START of every new work task
# =============================================================================

$ErrorActionPreference = 'Stop'

$SessionFile  = ".agent-session.md"
$WatchdogLog  = ".agent-watchdog.log"

Write-Host ""
Write-Host "=== rlhf Session Init ===" -ForegroundColor Cyan
Write-Host ""

# Prompt
$Task   = Read-Host "Current Task (what are you building/fixing?)"
$Mode   = Read-Host "Starting from scratch or continuing? (new/continue)"
$Branch = Read-Host "Working branch (leave blank to use current)"

# Git branch
$isGit = $false
$null = git rev-parse --git-dir 2>&1
if ($LASTEXITCODE -eq 0) { $isGit = $true }

if ($Branch) {
    git checkout -b $Branch 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { git checkout $Branch 2>&1 | Out-Null }
    $ActiveBranch = $Branch
} elseif ($isGit) {
    $ActiveBranch = (git rev-parse --abbrev-ref HEAD 2>&1) | Select-Object -First 1
} else {
    $ActiveBranch = "no-git"
}

$Timestamp  = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$LastCommit = if ($isGit) { (git log --oneline -1 2>&1) | Select-Object -First 1 } else { "No git repo" }
if (-not $LastCommit) { $LastCommit = "No commits yet" }

if ($Mode -eq "new") {
    $LastStep = "N/A - fresh session"
    $NextStep = "Begin: $Task"
} else {
    if (Test-Path $SessionFile) {
        Write-Host ""
        Write-Host "--- Last known session state ---" -ForegroundColor Yellow
        Get-Content $SessionFile
        Write-Host "--------------------------------"
        Write-Host ""
    }
    $LastStep = Read-Host "Last Completed Step (brief)"
    $NextStep = Read-Host "Next Step to resume"
}

# Write session file
$sessionContent = @"
# Agent Session State
> Last updated: $Timestamp

**Current Task:** $Task
**Branch:** $ActiveBranch
**Mode:** $Mode
**Last Completed Step:** $LastStep
**Next Step:** $NextStep
**Blockers:** None
**Files Modified:** (agent will update)
**Session Started:** $Timestamp
**Last Commit:** $LastCommit

---
## Session Log
- [$Timestamp] Session initialized ($Mode)
"@

Set-Content $SessionFile $sessionContent -Encoding UTF8

# Commit session init
if ($isGit) {
    git add $SessionFile 2>&1 | Out-Null
    git commit -m "session-init: $Task" --no-verify 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host ""
        Write-Host "[rlhf-init] Committed session state." -ForegroundColor Green
    }
}

# Reset watchdog log
Set-Content $WatchdogLog "=== Watchdog Log - Session: $Timestamp ===" -Encoding UTF8

Write-Host ""
Write-Host "OK Session initialized." -ForegroundColor Green
Write-Host "  Task:   $Task"
Write-Host "  Branch: $ActiveBranch"
Write-Host "  File:   $SessionFile"
Write-Host ""
Write-Host "Now run your agent:"
Write-Host "  claude / codex / gemini / opencode / copilot"
Write-Host ""
