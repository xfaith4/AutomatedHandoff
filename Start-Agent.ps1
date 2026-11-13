#Requires -Version 7
<#
.SYNOPSIS  Run the context-rotating Claude Code loop against a repo.
.DESCRIPTION
  The profile's Start-Agent alias points at the installed copy of this script in ~/.claude/agent-loop.
  Each call first syncs the installed runtime files from the source folder recorded in install.json
  (Install-AgentLoop.ps1 -FilesOnly). A source with parse errors is refused, and the installed copy
  is kept. When this script itself changed, the new copy is run in its place. -NoUpdate skips the sync.
.EXAMPLE   Start-Agent F:\Development\MyRepo -Max 8
.EXAMPLE   Start-Agent            # current folder (snaps to git root)
.EXAMPLE   Start-Agent F:\Development\MyRepo -UntilDone -Max 20 -MaxCost 60   # work the roadmap until DONE
.EXAMPLE   Start-Agent -UpdateOnly   # sync the installed copy from source, start nothing
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Repo = (Get-Location).Path,
    [int]$Max = 10,
    [switch]$UntilDone,          # continue after each finished item until the handoff says DONE, is blocked, or stalls
    [double]$MaxCost = 0,        # cumulative estimated cost cap in USD (0 = none)
    [long]$MaxTokens = 0,        # cumulative token cap (0 = none)
    [double]$RateLimitWait = 0,  # minutes to sleep on a usage-limit result before a new session (0 = stop)
    [ValidateSet('auto', 'acceptEdits', 'manual', 'dontAsk', 'plan', 'bypassPermissions')]
    [string]$Mode = 'auto',
    [string]$Prompt = '/handoff',
    [string]$HandoffFile,    # e.g. docs\CURRENT-HANDOFF.md - saved to .claude\agent-loop.json for this repo
    [string[]]$Tools = @('Bash(pwsh:*)', 'Edit', 'Write', 'Read', 'Glob', 'Grep'),
    [string[]]$ExtraArgs = @(),
    [int]$SoftLimit = 170000,    # context-guard rotation point per session
    [int]$HardLimit = 190000,
    [int]$BoundaryLimit = 100000, # rotate once an item closes (handoff rewritten) above this; 0 = off
    [string]$McpConfig,          # load only the MCP servers in this file (default: none)
    [switch]$KeepMcp,            # load the usual MCP servers (costs fixed context in every session)
    [switch]$KeepHygieneInjection, # let the session-hygiene hook inject its own handoff too
    [switch]$NoBrief,            # skip the pre-session brief (for a no-brief comparison run)
    [int]$BriefMaxChars = 4000,  # cap on the pre-session brief
    [switch]$NoRepair,           # B5: no claude -p --resume call when a session leaves no valid handoff
    [switch]$NoUpdate,           # skip the sync from the source folder
    [switch]$UpdateOnly          # sync from the source folder, then stop
)
# No Set-StrictMode here: it would carry into Start-AgentLoop.ps1, which is not written for it.
$ErrorActionPreference = 'Stop'

# 1. Sync the installed copy from source. A failed sync only warns: the installed copy still runs.
$installCfg = Join-Path $PSScriptRoot 'install.json'
if (-not $NoUpdate -and (Test-Path $installCfg)) {
    $changed = @()
    try {
        $src = (Get-Content $installCfg -Raw | ConvertFrom-Json).sourceDir
        $installer = Join-Path $src 'Install-AgentLoop.ps1'
        if (-not (Test-Path $installer)) { throw "installer not found: $installer" }
        $changed = @(& $installer -SourceDir $src -ToolsDir $PSScriptRoot -FilesOnly)
        if ($changed.Count) { Write-Host "Agent loop updated from ${src}: $($changed -join ', ')" -ForegroundColor Green }
    }
    catch { Write-Warning "Agent loop not updated, running the installed copy: $($_.Exception.Message)" }
    if ($UpdateOnly) { return }
    if ($changed -contains 'Start-Agent.ps1') {
        # This file was replaced on disk; run the new copy with the same arguments, without a second sync.
        $null = $PSBoundParameters.Remove('NoUpdate')
        & $PSCommandPath @PSBoundParameters -NoUpdate
        return
    }
}
elseif ($UpdateOnly) {
    Write-Warning "Nothing to update: $(if ($NoUpdate) { '-NoUpdate was given' } else { "no install.json next to $PSCommandPath" })."
    return
}

# 2. Run the loop
$path = (Resolve-Path $Repo -ErrorAction Stop).Path
# Snap to repo root so CLAUDE_PROJECT_DIR, the handoff and .claude/state all line up
$root = git -C $path rev-parse --show-toplevel 2>$null
if ($LASTEXITCODE -eq 0 -and $root) { $path = (Resolve-Path $root).Path }

if ($HandoffFile) {
    $cfgDir = Join-Path $path '.claude'
    New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
    @{ handoffFile = ($HandoffFile -replace '\\', '/') } | ConvertTo-Json |
        Set-Content (Join-Path $cfgDir 'agent-loop.json')
    Write-Host "Saved handoff location for this repo: $HandoffFile"
}
. (Join-Path $PSScriptRoot 'Resolve-HandoffFile.ps1')
$hf = Resolve-HandoffFile $path ''
if (-not (Test-Path (Join-Path $path $hf))) {
    Write-Warning "No $hf in $path - the first session starts without one."
}
$gi = Join-Path $path '.gitignore'
if (-not (Test-Path $gi)) {
    Set-Content $gi '.claude/state/'; Write-Host 'Created .gitignore with .claude/state/'
}
elseif (-not (Select-String -Path $gi -Pattern '^\.claude/state/?' -Quiet)) {
    Add-Content $gi "`n.claude/state/"; Write-Host 'Added .claude/state/ to .gitignore'
}

$args2 = @('--allowedTools') + $Tools + $ExtraArgs
$loopArgs = @{
    ProjectDir = $path; MaxSessions = $Max; PermissionMode = $Mode; Prompt = $Prompt; ExtraArgs = $args2
    UntilDone = $UntilDone; MaxCostUsd = $MaxCost; MaxTokens = $MaxTokens; RateLimitWaitMinutes = $RateLimitWait
    SoftLimit = $SoftLimit; HardLimit = $HardLimit; BoundaryLimit = $BoundaryLimit; KeepMcp = $KeepMcp; KeepHygieneInjection = $KeepHygieneInjection
    NoBrief = $NoBrief; BriefMaxChars = $BriefMaxChars; NoRepair = $NoRepair
}
if ($McpConfig) { $loopArgs.McpConfig = (Resolve-Path $McpConfig -ErrorAction Stop).Path }
& (Join-Path $PSScriptRoot 'Start-AgentLoop.ps1') @loopArgs
