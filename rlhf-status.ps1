# =============================================================================
# rlhf-status.ps1 — Quick view of current agent session state (Windows)
# =============================================================================

$SessionFile = ".agent-session.md"
$WatchdogLog = ".agent-watchdog.log"

Write-Host ""
Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║           RLHF SESSION STATUS                ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

Write-Host "-- SESSION STATE --" -ForegroundColor Yellow
if (Test-Path $SessionFile) {
    Get-Content $SessionFile
} else {
    Write-Host "  WARNING: No .agent-session.md found. Run rlhf-init first." -ForegroundColor Red
}

Write-Host ""
Write-Host "-- GIT STATUS --" -ForegroundColor Yellow
$null = git rev-parse --git-dir 2>&1
if ($LASTEXITCODE -eq 0) {
    $branch = (git rev-parse --abbrev-ref HEAD 2>&1) | Select-Object -First 1
    Write-Host "Branch : $branch"
    Write-Host "Status :"
    git status --short
    Write-Host ""
    Write-Host "Last 10 commits:"
    git log --oneline -10
} else {
    Write-Host "  Not a git repo."
}

Write-Host ""
Write-Host "-- WATCHDOG LOG (last 20 lines) --" -ForegroundColor Yellow
if (Test-Path $WatchdogLog) {
    Get-Content $WatchdogLog -Tail 20
} else {
    Write-Host "  No watchdog log yet."
}
Write-Host ""
