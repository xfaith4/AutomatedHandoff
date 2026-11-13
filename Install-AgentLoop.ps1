#Requires -Version 7
<#
.SYNOPSIS
  One-time installer for the context-rotation agent loop.
  - Copies context-guard.ps1 + Start-AgentLoop.ps1 to ~/.claude/agent-loop
  - Merges the PostToolUse/Stop hooks into ~/.claude/settings.json (user-level, every repo)
    without touching your existing hooks
  - Adds a Start-Agent alias to $PROFILE (idempotent; re-running replaces the block). It points at the
    installed Start-Agent.ps1, which re-syncs from this source folder (recorded in install.json) on every call.

.EXAMPLE
  ./Install-AgentLoop.ps1            # run from the folder holding the scripts
  . $PROFILE                          # reload
  Start-Agent F:\Development\MyRepo

.EXAMPLE
  ./Install-AgentLoop.ps1 -FilesOnly  # copy changed runtime files only; outputs the names it copied
#>
param(
    [string]$SourceDir = $PSScriptRoot,
    [string]$ToolsDir = (Join-Path $HOME '.claude/agent-loop'),
    [string]$ProfilePath = $PROFILE,    # the VS Code terminal uses Microsoft.VSCode_profile.ps1
    [switch]$SkipHooks,
    [switch]$FilesOnly                  # sync runtime files only: no hooks, profile or install.json
)
$ErrorActionPreference = 'Stop'
$SourceDir = (Resolve-Path $SourceDir).Path

# 1. Copy the runtime files that differ. Refuse the whole copy when any source script fails to parse, so a
#    half-edited working tree never replaces a working installed copy.
$files = 'Start-Agent.ps1', 'context-guard.ps1', 'Start-AgentLoop.ps1', 'Resolve-HandoffFile.ps1', 'New-AgentLoopReport.ps1',
'AgentLoopReport.html', 'Invoke-LoopSummary.ps1', 'LoopSummaryPrompt.md', 'loop-summary.schema.json'
$broken = foreach ($f in $files -like '*.ps1') {
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceDir $f), [ref]$null, [ref]$parseErrors)
    if (@($parseErrors).Count) { "$f (line $($parseErrors[0].Extent.StartLineNumber): $($parseErrors[0].Message))" }
}
if ($broken) { throw "Source has parse errors, installed copy unchanged: $($broken -join '; ')" }
New-Item -ItemType Directory -Force -Path $ToolsDir | Out-Null
$copied = foreach ($f in $files) {
    $from = Join-Path $SourceDir $f
    $to = Join-Path $ToolsDir $f
    if ((Test-Path $to) -and (Get-FileHash $from).Hash -eq (Get-FileHash $to).Hash) { continue }
    Copy-Item $from $to -Force
    $f
}
if ($FilesOnly) { return $copied }
@{ sourceDir = $SourceDir } | ConvertTo-Json | Set-Content (Join-Path $ToolsDir 'install.json')
$guard = (Join-Path $ToolsDir 'context-guard.ps1') -replace '\\', '/'
Write-Host "Scripts -> $ToolsDir ($(@($copied).Count) changed); auto-update source: $SourceDir" -ForegroundColor Green

# 2. Merge hooks into user-level settings.json (backs up first, skips duplicates)
if (-not $SkipHooks) {
    $settingsPath = Join-Path $HOME '.claude/settings.json'
    $settings = if (Test-Path $settingsPath) {
        Copy-Item $settingsPath "$settingsPath.bak-$(Get-Date -Format yyyyMMddHHmmss)"
        Get-Content $settingsPath -Raw | ConvertFrom-Json -AsHashtable
    }
    else { @{} }
    if (-not $settings.hooks) { $settings.hooks = @{} }

    foreach ($evt in 'PostToolUse', 'Stop') {
        $cmd = "pwsh -NoProfile -File `"$guard`" -Event $evt"
        $existing = @($settings.hooks[$evt])
        $already = $existing | Where-Object { $_.hooks.command -match 'context-guard\.ps1' }
        if ($already) { Write-Host "$evt hook already present - skipped"; continue }
        $entry = @{ hooks = @(@{ type = 'command'; command = $cmd }) }
        if ($evt -eq 'PostToolUse') { $entry.matcher = '*' }
        $settings.hooks[$evt] = @($existing | Where-Object { $_ }) + $entry
        Write-Host "$evt hook added" -ForegroundColor Green
    }
    $settings | ConvertTo-Json -Depth 20 | Set-Content $settingsPath
}

# 3. Profile alias (between markers so re-runs replace it cleanly). The logic lives in the installed
#    Start-Agent.ps1, so updating the scripts never needs a profile edit or a `. $PROFILE`.
$begin = '# >>> agent-loop >>>'
$end = '# <<< agent-loop <<<'
$block = @"
$begin
# Start-Agent re-syncs ~/.claude/agent-loop from $SourceDir on each call (-NoUpdate skips it).
if (Test-Path Function:\Start-Agent) { Remove-Item Function:\Start-Agent }   # drop a pre-alias definition
Set-Alias Start-Agent '$((Join-Path $ToolsDir 'Start-Agent.ps1'))'
$end
"@

if (-not (Test-Path $ProfilePath)) { New-Item -ItemType File -Force -Path $ProfilePath | Out-Null }
$content = Get-Content $ProfilePath -Raw
$pattern = "(?s)$([regex]::Escape($begin)).*?$([regex]::Escape($end))"
$content = if ($content -match $pattern) { [regex]::Replace($content, $pattern, { $block }) }
else { ($content ?? '').TrimEnd() + "`n`n$block`n" }
Set-Content $ProfilePath $content
Write-Host "Start-Agent added to $ProfilePath  -> run: . `$PROFILE" -ForegroundColor Green
