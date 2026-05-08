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

# Pre-flight 1: cwd must NOT be inside source or target (or any descendant).
# The shell holds an exclusive handle on its cwd; Move-Item will fail with
# "in use" if we try to move a directory that's a parent of the cwd.
$cwd = (Get-Location).Path
function Is-Inside($child, $parent) {
    $c = (Resolve-Path -LiteralPath $child -ErrorAction SilentlyContinue).Path
    $p = (Resolve-Path -LiteralPath $parent -ErrorAction SilentlyContinue).Path
    if (-not $c -or -not $p) { return $false }
    return ($c -eq $p) -or $c.StartsWith("$p\", [StringComparison]::OrdinalIgnoreCase)
}
if ((Is-Inside $cwd $source) -or (Is-Inside $cwd $target)) {
    Write-Error @"
Cannot move while you are sitting inside the source or target path.

  current cwd: $cwd
  source:      $source
  target:      $target

Fix: cd out of both directories first (e.g. `cd C:\` or `cd $env:USERPROFILE`)
then re-run this script.
"@
    exit 1
}
Write-Host "  cwd OK: $cwd"

# Pre-flight 2: source must exist.
if (-not (Test-Path $source)) {
    Write-Error "Source path does not exist: $source"
    exit 1
}

# Pre-flight 3: source git tree must be clean.
Push-Location $source
$gitStatus = git status --porcelain
Pop-Location
if ($gitStatus) {
    Write-Warning "Source has uncommitted changes:"
    $gitStatus | ForEach-Object { Write-Host "  $_" }
    $continue = Read-Host "Continue anyway? Uncommitted changes will move with the repo. (y/N)"
    if ($continue -ne "y") { exit 1 }
}

# Make sure C:\VibeCode parent exists.
New-Item -ItemType Directory -Force -Path "C:\VibeCode" | Out-Null

# Pre-flight 4: if target exists, test it's actually moveable BEFORE we
# attempt the real move. Catches the "in use by copilot's sandbox" case
# with a clear error instead of a generic Move-Item failure.
if (Test-Path $target) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmm"
    $backup = "C:\VibeCode\terminal-2-pre-move-backup-$stamp"

    Write-Host "Target $target already exists - testing if it's moveable..." -ForegroundColor Yellow
    try {
        # The actual move attempt is the test.
        Move-Item -LiteralPath $target -Destination $backup -ErrorAction Stop
        Write-Host "  backup created at $backup" -ForegroundColor Green
        Write-Host "  (the mockup + copilot's docs from this backup were already pulled into git in e3f1138, so nothing should be lost.)" -ForegroundColor Green
    } catch {
        Write-Error @"
Could not move existing $target out of the way:

  $($_.Exception.Message)

This usually means another process has a file handle inside that directory.
Most likely culprits:
  - copilot's sandbox / cowork session is still active and mounted at this path
  - another PowerShell window has cd'd into it
  - VS Code / editor has a file open from there
  - antivirus is scanning files in there

Fix:
  1. Close all Claude Code sessions (yours AND copilot's if running)
  2. Close any editor/terminal with files in C:\VibeCode\terminal-2 open
  3. Optionally: reboot if you cannot identify the locker
  4. Re-run this script

If you are 100% sure nothing is using it, you can also try:
  - Open Resource Monitor -> CPU tab -> 'Associated Handles' search box -> paste 'C:\VibeCode\terminal-2'
    and end any process holding handles.
"@
        exit 1
    }
}

# THE MOVE
# Use robocopy /MOVE with /XD exclusions on .claude and .scratch to skip
# Claude Code session lock files in .claude/worktrees/ that would otherwise
# block Move-Item. .claude/ and .scratch/ are gitignored runtime cruft - the
# new location will create a fresh .claude/ when you reopen Claude Code at it.
#
# robocopy exit codes 0-7 = success, 8+ = failure. (1 = files copied,
# 2 = extra files skipped, 4 = mismatched, etc.)
Write-Host "Moving $source -> $target via robocopy /MOVE (skipping .claude/ + .scratch/) ..." -ForegroundColor Cyan
$rcArgs = @(
    "$source", "$target",
    "/E",                       # all subdirs incl empty
    "/MOVE",                    # copy then delete source
    "/XD", ".claude", ".scratch",  # skip these directories
    "/R:1", "/W:1",             # retry once, wait 1 second (don't hang)
    "/NFL", "/NDL", "/NP",      # less verbose output
    "/NJH", "/NJS"              # no header, no summary
)
& robocopy @rcArgs | Out-Null
$rcExit = $LASTEXITCODE
if ($rcExit -ge 8) {
    Write-Error "robocopy failed with exit code $rcExit. Source may be partially moved."
    exit 1
}
Write-Host "  [OK] robocopy completed (exit $rcExit; codes < 8 are success)" -ForegroundColor Green

# Source folder may still exist with .claude/ leftover (Claude Code's own
# session lock files). Tell the user how to clean it up later, but don't try
# to delete now (this very script may be running from a Claude Code process
# that holds the lock).
if (Test-Path $source) {
    $leftovers = Get-ChildItem -LiteralPath $source -Force | Select-Object -ExpandProperty Name
    Write-Host ""
    Write-Host "  NOTE: $source still exists with leftover items: $($leftovers -join ', ')" -ForegroundColor Yellow
    Write-Host "        These are Claude Code session locks (.claude/) and/or .scratch/ working files."
    Write-Host "        After you close ALL Claude Code sessions, you can delete the leftover with:"
    Write-Host "          Remove-Item -Recurse -Force '$source'"
}

# Verify git still works at the new location
Push-Location $target
$head = git rev-parse --short HEAD
$branch = git branch --show-current
Pop-Location
Write-Host ""
Write-Host "  git HEAD at new location: $head on $branch" -ForegroundColor Green
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
