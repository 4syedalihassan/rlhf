# =============================================================================
# setup.ps1 — One-time install of rlhf on Windows
# Run once in PowerShell (as normal user, not admin).
# =============================================================================

$ErrorActionPreference = 'Stop'

$ScriptDir  = Split-Path $MyInvocation.MyCommand.Path -Parent
$ScriptsDir = Join-Path $ScriptDir "scripts"
$HooksDir   = Join-Path $ScriptDir "hooks"

Write-Host ""
Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║            rlhf — Windows Setup              ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# --- 1. Execution Policy check -----------------------------------------------
$policy = Get-ExecutionPolicy -Scope CurrentUser
if ($policy -eq 'Restricted' -or $policy -eq 'AllSigned') {
    Write-Host "Setting PowerShell execution policy to RemoteSigned for current user..." -ForegroundColor Yellow
    Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
    Write-Host "OK Execution policy set to RemoteSigned." -ForegroundColor Green
} else {
    Write-Host "OK Execution policy OK ($policy)." -ForegroundColor Green
}

# --- 2. Unblock scripts (Windows may block downloaded .ps1 files) -----------
Get-ChildItem "$ScriptsDir\*.ps1" | Unblock-File
Write-Host "OK Scripts unblocked." -ForegroundColor Green

# --- 3. Add wrapper functions to PowerShell profile --------------------------
$profileDir = Split-Path $PROFILE -Parent
if (-not (Test-Path $profileDir)) {
    New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
}
if (-not (Test-Path $PROFILE)) {
    New-Item -ItemType File -Force -Path $PROFILE | Out-Null
}

$profileContent = Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue

$markerStart = "# ============================================================"
$markerId    = "# rlhf - AI agent wrapper"

if ($profileContent -match [regex]::Escape($markerId)) {
    Write-Host ""
    Write-Host "  rlhf functions already present in PowerShell profile." -ForegroundColor Yellow
    $overwrite = Read-Host "  Overwrite? (y/N)"
    if ($overwrite -ne 'y' -and $overwrite -ne 'Y') {
        Write-Host "  Skipped profile update."
    } else {
        # Remove old block between markers and re-add
        $profileContent = $profileContent -replace "(?s)$markerStart`n$markerId.*?# END rlhf`n", ""
        Set-Content $PROFILE $profileContent -Encoding UTF8
        Add-RlhfProfile $ScriptsDir
    }
} else {
    Add-RlhfProfile $ScriptsDir
}

function Add-RlhfProfile($sd) {
    $block = @"

$markerStart
$markerId
# Installed: $(Get-Date -Format 'yyyy-MM-dd HH:mm')
# ============================================================
`$env:RLHF_SCRIPTS_DIR = "$sd"

function claude    { & "$sd\rlhf-run.ps1"  claude    @args }
function codex     { & "$sd\rlhf-run.ps1"  codex     @args }
function gemini    { & "$sd\rlhf-run.ps1"  gemini    @args }
function opencode  { & "$sd\rlhf-run.ps1"  opencode  @args }
function copilot   { & "$sd\rlhf-run.ps1"  copilot   @args }

function rlhf-init   { & "$sd\rlhf-init.ps1"   @args }
function rlhf-status { & "$sd\rlhf-status.ps1" @args }

# Escape hatches — bypass wrapper
function claude-raw   { & (Get-Command claude   -CommandType Application | Select-Object -First 1).Source @args }
function codex-raw    { & (Get-Command codex    -CommandType Application | Select-Object -First 1).Source @args }
function gemini-raw   { & (Get-Command gemini   -CommandType Application | Select-Object -First 1).Source @args }
# END rlhf
"@
    Add-Content $PROFILE $block -Encoding UTF8
    Write-Host "OK Wrapper functions added to: $PROFILE" -ForegroundColor Green
}

Add-RlhfProfile $ScriptsDir

# --- 4. Git hook template dir ------------------------------------------------
$templateDir = git config --global init.templateDir 2>&1
if ($LASTEXITCODE -ne 0 -or -not $templateDir) {
    $templateDir = Join-Path $env:USERPROFILE ".git-templates"
    New-Item -ItemType Directory -Force -Path "$templateDir\hooks" | Out-Null
    git config --global init.templateDir $templateDir
    Write-Host "OK Git template dir set: $templateDir" -ForegroundColor Green
} else {
    New-Item -ItemType Directory -Force -Path "$templateDir\hooks" | Out-Null
    Write-Host "OK Git template dir exists: $templateDir" -ForegroundColor Green
}

Copy-Item "$HooksDir\pre-commit" "$templateDir\hooks\pre-commit" -Force
Write-Host "OK Pre-commit hook installed to git template dir." -ForegroundColor Green
Write-Host "   New repos (git init) will auto-get the hook."

# --- 5. Install hook in current repo -----------------------------------------
$null = git rev-parse --git-dir 2>&1
if ($LASTEXITCODE -eq 0) {
    $gitDir  = git rev-parse --git-dir
    $hookDir = Join-Path $gitDir "hooks"
    New-Item -ItemType Directory -Force -Path $hookDir | Out-Null
    Copy-Item "$HooksDir\pre-commit" "$hookDir\pre-commit" -Force
    Write-Host "OK Pre-commit hook installed in current repo." -ForegroundColor Green
}

# --- 6. Summary --------------------------------------------------------------
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Setup complete!                                             ║" -ForegroundColor Cyan
Write-Host "║                                                              ║" -ForegroundColor Cyan
Write-Host "║  Reload your profile:                                        ║" -ForegroundColor Cyan
Write-Host "║    . `$PROFILE                                                ║" -ForegroundColor Cyan
Write-Host "║                                                              ║" -ForegroundColor Cyan
Write-Host "║  Workflow:                                                   ║" -ForegroundColor Cyan
Write-Host "║    1. rlhf-init          <- start of every task             ║" -ForegroundColor Cyan
Write-Host "║    2. claude / codex /   <- wrapped automatically           ║" -ForegroundColor Cyan
Write-Host "║       gemini / opencode / copilot                           ║" -ForegroundColor Cyan
Write-Host "║    3. rlhf-status        <- check state anytime             ║" -ForegroundColor Cyan
Write-Host "║                                                              ║" -ForegroundColor Cyan
Write-Host "║  Watchdog interval: 5min (set `$env:AGENT_WATCHDOG_INTERVAL) ║" -ForegroundColor Cyan
Write-Host "║  Escape: claude-raw / codex-raw (no enforcer)               ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
