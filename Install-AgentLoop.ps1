#Requires -Version 7
<#
.SYNOPSIS
  One-time installer for the context-rotation agent loop.
  - Copies context-guard.ps1 + Start-AgentLoop.ps1 to ~/.claude/agent-loop
  - Merges the PostToolUse/Stop hooks into ~/.claude/settings.json (user-level, every repo)
    without touching your existing hooks
  - Adds a Start-Agent function to $PROFILE (idempotent; re-running replaces the block)

.EXAMPLE
  ./Install-AgentLoop.ps1            # run from the folder holding the two scripts
  . $PROFILE                          # reload
  Start-Agent F:\Development\MyRepo
#>
param(
    [string]$SourceDir = $PSScriptRoot,
    [string]$ToolsDir = (Join-Path $HOME '.claude/agent-loop'),
    [string]$ProfilePath = $PROFILE,    # the VS Code terminal uses Microsoft.VSCode_profile.ps1
    [switch]$SkipHooks
)
$ErrorActionPreference = 'Stop'

# 1. Copy scripts
New-Item -ItemType Directory -Force -Path $ToolsDir | Out-Null
foreach ($f in 'context-guard.ps1', 'Start-AgentLoop.ps1', 'Resolve-HandoffFile.ps1', 'New-AgentLoopReport.ps1', 'AgentLoopReport.html',
    'Invoke-LoopSummary.ps1', 'LoopSummaryPrompt.md', 'loop-summary.schema.json') {
    Copy-Item (Join-Path $SourceDir $f) $ToolsDir -Force
}
$guard = (Join-Path $ToolsDir 'context-guard.ps1') -replace '\\', '/'
Write-Host "Scripts -> $ToolsDir" -ForegroundColor Green

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

# 3. Profile function (between markers so re-runs replace it cleanly)
$begin = '# >>> agent-loop >>>'
$end = '# <<< agent-loop <<<'
$block = @"
$begin
function Start-Agent {
    <#
    .SYNOPSIS  Run the context-rotating Claude Code loop against a repo.
    .EXAMPLE   Start-Agent F:\Development\MyRepo -Max 8
    .EXAMPLE   Start-Agent            # current folder (snaps to git root)
    .EXAMPLE   Start-Agent F:\Development\MyRepo -UntilDone -Max 20 -MaxCost 60   # work the roadmap until DONE
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string]`$Repo = (Get-Location).Path,
        [int]`$Max = 10,
        [switch]`$UntilDone,          # continue after each finished item until the handoff says DONE, is blocked, or stalls
        [double]`$MaxCost = 0,        # cumulative estimated cost cap in USD (0 = none)
        [long]`$MaxTokens = 0,        # cumulative token cap (0 = none)
        [double]`$RateLimitWait = 0,  # minutes to sleep on a usage-limit result before a new session (0 = stop)
        [ValidateSet('auto','acceptEdits','manual','dontAsk','plan','bypassPermissions')]
        [string]`$Mode = 'auto',
        [string]`$Prompt = '/handoff',
        [string]`$HandoffFile,    # e.g. docs\CURRENT-HANDOFF.md - saved to .claude\agent-loop.json for this repo
        [string[]]`$Tools = @('Bash(pwsh:*)','Edit','Write','Read','Glob','Grep'),
        [string[]]`$ExtraArgs = @(),
        [int]`$SoftLimit = 170000,    # context-guard rotation point per session
        [int]`$HardLimit = 190000,
        [string]`$McpConfig,          # load only the MCP servers in this file (default: none)
        [switch]`$KeepMcp,            # load the usual MCP servers (costs fixed context in every session)
        [switch]`$KeepHygieneInjection, # let the session-hygiene hook inject its own handoff too
        [switch]`$NoBrief,            # skip the pre-session brief (for a no-brief comparison run)
        [int]`$BriefMaxChars = 4000   # cap on the pre-session brief
    )
    `$path = (Resolve-Path `$Repo -ErrorAction Stop).Path
    # Snap to repo root so CLAUDE_PROJECT_DIR, the handoff and .claude/state all line up
    `$root = git -C `$path rev-parse --show-toplevel 2>`$null
    if (`$LASTEXITCODE -eq 0 -and `$root) { `$path = (Resolve-Path `$root).Path }

    if (`$HandoffFile) {
        `$cfgDir = Join-Path `$path '.claude'
        New-Item -ItemType Directory -Force -Path `$cfgDir | Out-Null
        @{ handoffFile = (`$HandoffFile -replace '\\','/') } | ConvertTo-Json |
            Set-Content (Join-Path `$cfgDir 'agent-loop.json')
        Write-Host "Saved handoff location for this repo: `$HandoffFile"
    }
    . '$((Join-Path $ToolsDir 'Resolve-HandoffFile.ps1'))'
    `$hf = Resolve-HandoffFile `$path ''
    if (-not (Test-Path (Join-Path `$path `$hf))) {
        Write-Warning "No `$hf in `$path - the first session starts without one."
    }
    `$gi = Join-Path `$path '.gitignore'
    if (-not (Test-Path `$gi)) {
        Set-Content `$gi '.claude/state/'; Write-Host 'Created .gitignore with .claude/state/'
    }
    elseif (-not (Select-String -Path `$gi -Pattern '^\.claude/state/?' -Quiet)) {
        Add-Content `$gi "`n.claude/state/"; Write-Host 'Added .claude/state/ to .gitignore'
    }

    `$args2 = @('--allowedTools') + `$Tools + `$ExtraArgs
    `$loopArgs = @{
        ProjectDir = `$path; MaxSessions = `$Max; PermissionMode = `$Mode; Prompt = `$Prompt; ExtraArgs = `$args2
        UntilDone = `$UntilDone; MaxCostUsd = `$MaxCost; MaxTokens = `$MaxTokens; RateLimitWaitMinutes = `$RateLimitWait
        SoftLimit = `$SoftLimit; HardLimit = `$HardLimit; KeepMcp = `$KeepMcp; KeepHygieneInjection = `$KeepHygieneInjection
        NoBrief = `$NoBrief; BriefMaxChars = `$BriefMaxChars
    }
    if (`$McpConfig) { `$loopArgs.McpConfig = (Resolve-Path `$McpConfig -ErrorAction Stop).Path }
    & '$((Join-Path $ToolsDir 'Start-AgentLoop.ps1'))' @loopArgs
}
$end
"@

if (-not (Test-Path $ProfilePath)) { New-Item -ItemType File -Force -Path $ProfilePath | Out-Null }
$content = Get-Content $ProfilePath -Raw
$pattern = "(?s)$([regex]::Escape($begin)).*?$([regex]::Escape($end))"
$content = if ($content -match $pattern) { [regex]::Replace($content, $pattern, { $block }) }
else { ($content ?? '').TrimEnd() + "`n`n$block`n" }
Set-Content $ProfilePath $content
Write-Host "Start-Agent added to $ProfilePath  -> run: . `$PROFILE" -ForegroundColor Green
