# =============================================================================
# rlhf-daemon.ps1 — Filesystem watcher + rule enforcement engine (Windows)
#
# Started by rlhf-run.ps1. Do not run directly.
#
# Args:
#   -WatchDir     : project root to watch
#   -WrapperPid   : PID of rlhf-run.ps1 (unused on Windows — file IPC only)
#   -RulesFile    : path to .rlhf-rules
# =============================================================================

param(
    [string]$WatchDir   = ".",
    [int]   $WrapperPid = 0,
    [string]$RulesFile  = ".rlhf-rules"
)

$ErrorActionPreference = 'SilentlyContinue'

# ── Defaults (overridden by .rlhf-rules) ──────────────────────────────────────
$SessionMaxAgeMin   = 15
$RequireSession     = "yes"
$RequireTask        = "yes"
$EnforceBranch      = "yes"
$BlockMainBranch    = "yes"
$MainBranchNames    = "main,master,develop"
$CheckTodo          = "yes"
$TodoFiles          = "TODO.md TASKS.md .rlhf-tasks.md"
$RevertOnViolation  = "yes"
$BlockCooldownSec   = 30
$WatchExclude       = @('\.git','\.rlhf','\.agent-watchdog','node_modules','__pycache__')

# ── Load rules ────────────────────────────────────────────────────────────────
$rulesPath = Join-Path $WatchDir $RulesFile
if (Test-Path $rulesPath) {
    Get-Content $rulesPath | Where-Object { $_ -match '^[A-Z_]+=.+' -and $_ -notmatch '^#' } | ForEach-Object {
        $parts = $_ -split '=', 2
        Set-Variable -Name $parts[0] -Value $parts[1]
    }
}

$SessionFile    = Join-Path $WatchDir ".agent-session.md"
$ViolationsLog  = Join-Path $WatchDir ".rlhf-violations.log"
$BlockedFile    = Join-Path $WatchDir ".rlhf-blocked"
$LastBlockFile  = Join-Path $WatchDir ".rlhf-lastblock"

Set-Location $WatchDir

function DLog($msg) {
    $ts = Get-Date -Format 'HH:mm:ss'
    Add-Content $ViolationsLog "[$ts] [daemon] $msg"
}

# ── Rule Engine ───────────────────────────────────────────────────────────────

function Test-GitRepo {
    $null = git rev-parse --git-dir 2>&1
    return $LASTEXITCODE -eq 0
}

function Invoke-RuleCheck($filePath) {
    $name = Split-Path $filePath -Leaf

    # Skip rlhf/session/git files
    if ($name -match '^\.(rlhf|agent-)' -or $name -eq '.agent-session.md' -or
        $filePath -match '\\\.git\\' -or $filePath -match '/\.git/') { return }

    foreach ($pattern in $WatchExclude) {
        if ($filePath -match $pattern) { return }
    }

    # Rule 1: Session file must exist
    if ($RequireSession -eq "yes" -and -not (Test-Path $SessionFile)) {
        Invoke-Violation $filePath "session_missing" ".agent-session.md missing. Run: rlhf-init"
        return
    }

    # Rule 2: Current Task must be set
    if ($RequireTask -eq "yes" -and (Test-Path $SessionFile)) {
        $taskLine = Get-Content $SessionFile | Where-Object { $_ -match '^\*\*Current Task:\*\*' } | Select-Object -First 1
        $task = ($taskLine -replace '\*\*Current Task:\*\*\s*', '').Trim()
        if (-not $task) {
            Invoke-Violation $filePath "task_not_set" "Current Task empty in .agent-session.md. Fill it before editing."
            return
        }
    }

    # Rule 3: Session freshness
    if (Test-Path $SessionFile) {
        $maxAgeSec  = [int]$SessionMaxAgeMin * 60
        $lastWrite  = (Get-Item $SessionFile).LastWriteTime
        $ageSec     = ([DateTime]::Now - $lastWrite).TotalSeconds
        if ($ageSec -gt $maxAgeSec) {
            Invoke-Violation $filePath "session_stale" ".agent-session.md not updated in $SessionMaxAgeMin+ min. Update it."
            return
        }
    }

    # Rule 4: Branch check
    if ($EnforceBranch -eq "yes" -and (Test-GitRepo)) {
        $sessionBranch = $null
        if (Test-Path $SessionFile) {
            $branchLine    = Get-Content $SessionFile | Where-Object { $_ -match '^\*\*Branch:\*\*' } | Select-Object -First 1
            $sessionBranch = ($branchLine -replace '\*\*Branch:\*\*\s*', '').Trim()
        }
        $currentBranch = (git rev-parse --abbrev-ref HEAD 2>&1) | Select-Object -First 1
        if ($sessionBranch -and $currentBranch -and $sessionBranch -ne $currentBranch) {
            Invoke-Violation $filePath "wrong_branch" "On '$currentBranch', session expects '$sessionBranch'. Checkout correct branch."
            return
        }
    }

    # Rule 5: Block main/master
    if ($BlockMainBranch -eq "yes" -and (Test-GitRepo)) {
        $currentBranch = (git rev-parse --abbrev-ref HEAD 2>&1) | Select-Object -First 1
        $protected = $MainBranchNames -split ','
        if ($protected -contains $currentBranch) {
            Invoke-Violation $filePath "protected_branch" "Direct edits on '$currentBranch' blocked. Create a feature branch."
            return
        }
    }
}

function Invoke-Violation($filePath, $rule, $message) {
    # Cooldown
    $now = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $lastBlock = 0
    if (Test-Path $LastBlockFile) { $lastBlock = [int](Get-Content $LastBlockFile) }
    if (($now - $lastBlock) -lt [int]$BlockCooldownSec) {
        DLog "COOLDOWN | $rule | $filePath"
        return
    }
    $now | Set-Content $LastBlockFile

    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    DLog "BLOCKED | $rule | $filePath | $message"

    # Revert file
    if ($RevertOnViolation -eq "yes" -and (Test-GitRepo)) {
        $tracked = git ls-files --error-unmatch $filePath 2>&1
        if ($LASTEXITCODE -eq 0) {
            git restore $filePath 2>&1 | Out-Null
            DLog "Reverted: $filePath"
        } else {
            # Untracked — delete it
            Remove-Item $filePath -Force -ErrorAction SilentlyContinue
            DLog "Removed untracked: $filePath"
        }
    }

    # Write blocked file (IPC to rlhf-run.ps1 monitor)
    @"
FILE=$filePath
RULE=$rule
MSG=$message
TIME=$ts
"@ | Set-Content $BlockedFile -Encoding UTF8

    # Prepend notice to instruction files
    foreach ($instr in @('CLAUDE.md','AGENTS.md','GEMINI.md','OPENCODE.md')) {
        $instrPath = Join-Path $WatchDir $instr
        if (Test-Path $instrPath) {
            $notice  = "<!-- RLHF BLOCK [$($ts)] Rule: $rule - $message -->`n"
            $content = Get-Content $instrPath -Raw -Encoding UTF8
            Set-Content $instrPath ($notice + $content) -Encoding UTF8
        }
    }
}

# ── Watcher ───────────────────────────────────────────────────────────────────

DLog "=== Daemon started | PID=$PID | watching: $WatchDir ==="

$watcher = New-Object System.IO.FileSystemWatcher
$watcher.Path                = $WatchDir
$watcher.Filter              = "*.*"
$watcher.IncludeSubdirectories = $true
$watcher.NotifyFilter        = [System.IO.NotifyFilters]::LastWrite -bor
                               [System.IO.NotifyFilters]::FileName

$onChange = {
    param($source, $e)
    Invoke-RuleCheck $e.FullPath
}

$onCreated = {
    param($source, $e)
    Invoke-RuleCheck $e.FullPath
}

$watcher.EnableRaisingEvents = $true
$changedEvent = Register-ObjectEvent $watcher "Changed" -Action $onChange
$createdEvent = Register-ObjectEvent $watcher "Created" -Action $onCreated

DLog "FileSystemWatcher active."

# Keep alive
while ($true) {
    Start-Sleep -Seconds 5
    # Flush any queued events
    $null = Get-Job -State Completed | Remove-Job -Force -ErrorAction SilentlyContinue
}
