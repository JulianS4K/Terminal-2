# bin/permafix-move.ps1
#
# One-shot script to move the canonical repo from
#   C:\Users\julia\Code\Terminal-2     (current code-agent path)
# to
#   C:\VibeCode\terminal-2             (canonical path per AGENTS.md RULE 4 +
#                                       what copilot's sandbox already mounts)
#
# After this runs:
#   - Both code agent and copilot work from C:\VibeCode\terminal-2
#   - Both see the SAME file tree (no more sub-tree-mount split)
#   - Filesystem-driven drift goes away
#
# RUN FROM A FRESH PowerShell PROMPT, AFTER CLOSING CLAUDE CODE.
# Do NOT run this from inside Claude Code (would yank the rug).
#
# Usage:
#   1. Close all Claude Code sessions, all terminals in the repo, all editors.
#   2. Open PowerShell.
#   3. PowerShell -ExecutionPolicy Bypass -File C:\Users\julia\Code\Terminal-2\bin\permafix-move.ps1
#   4. Update Railway dashboard if it pulls from a local path (most likely it
#      pulls from GitHub, in which case no Railway change is needed).
#   5. Reopen Claude Code at C:\VibeCode\terminal-2

$ErrorActionPreference = "Stop"

$source = "C:\Users\julia\Code\Terminal-2"
$target = "C:\VibeCode\terminal-2"

Write-Host "=== permafix-move ===" -ForegroundColor Cyan
Write-Host "  source: $source"
Write-Host "  target: $target"
Write-Host ""

# Sanity: source must exist
if (-not (Test-Path $source)) {
    Write-Error "Source path does not exist: $source"
    exit 1
}

# Sanity: source git tree must be clean
Push-Location $source
$gitStatus = git status --porcelain
Pop-Location
if ($gitStatus) {
    Write-Warning "Source has uncommitted changes:"
    $gitStatus | ForEach-Object { Write-Host "  $_" }
    $continue = Read-Host "Continue anyway? Uncommitted changes will move with the repo. (y/N)"
    if ($continue -ne "y") { exit 1 }
}

# Make sure C:\VibeCode parent exists
New-Item -ItemType Directory -Force -Path "C:\VibeCode" | Out-Null

# If target already exists (copilot's sandbox mount), back it up first
if (Test-Path $target) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmm"
    $backup = "C:\VibeCode\terminal-2-pre-move-backup-$stamp"
    Write-Host "Target $target already exists - backing up to $backup" -ForegroundColor Yellow
    Move-Item -LiteralPath $target -Destination $backup
    Write-Host "  backup created. The mockup + copilot's docs from this backup were already pulled into git in commit e3f1138, so nothing should be lost." -ForegroundColor Green
}

# THE MOVE
Write-Host "Moving $source -> $target ..." -ForegroundColor Cyan
Move-Item -LiteralPath $source -Destination $target

# Verify git still works at the new location
Push-Location $target
$head = git rev-parse --short HEAD
$branch = git branch --show-current
Pop-Location
Write-Host "  [OK] moved." -ForegroundColor Green
Write-Host "  git HEAD at new location: $head on $branch"
Write-Host ""

# Quick post-move smoke checks
Write-Host "=== post-move smoke checks ===" -ForegroundColor Cyan
Push-Location $target
Write-Host "  app.py present:                $((Test-Path 'app.py'))"
Write-Host "  static/index.html present:     $((Test-Path 'static/index.html'))"
Write-Host "  static/_proposals/ present:    $((Test-Path 'static/_proposals'))"
Write-Host "  supabase/migrations/ count:    $((Get-ChildItem 'supabase/migrations' -File).Count)"
Write-Host "  AGENTS.md present:             $((Test-Path 'AGENTS.md'))"
Pop-Location

Write-Host ""
Write-Host "=== NEXT STEPS (manual) ===" -ForegroundColor Cyan
Write-Host "  1. Railway: most likely pulls from GitHub, no change needed (push"
Write-Host "     already went out as commit e3f1138). If Railway points at a"
Write-Host "     local path, update dashboard service Settings to:"
Write-Host "       C:\VibeCode\terminal-2"
Write-Host ""
Write-Host "  2. Reopen Claude Code at C:\VibeCode\terminal-2"
Write-Host ""
Write-Host "  3. Tell copilot the move is complete. Their sandbox at that path"
Write-Host "     now sees the FULL repo (including app.py, static/index.html,"
Write-Host "     Procfile - the files they could not see before)."
Write-Host ""
Write-Host "Done." -ForegroundColor Green
