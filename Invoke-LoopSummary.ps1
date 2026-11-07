#Requires -Version 7
<#
.SYNOPSIS
  Writes the end-of-run engineering summary for one agent-loop run. It condenses the run into a
  digest (loop log, tool errors in the raw stream logs, handoff entries, git facts) and makes one
  read-only `claude -p --json-schema` call with LoopSummaryPrompt.md. It then appends a
  `summary` line to the loop log, which AgentLoopReport.html renders as the run's summary panel.

.DESCRIPTION
  The call gets only Read, Grep and Glob, runs with all hooks disabled (so context-guard's Stop
  hook can't demand a handoff), loads no MCP servers and saves no session. A failed call still
  appends a `summary` line, with `error` set, so the report shows why the panel is missing.

.EXAMPLE
  ./Invoke-LoopSummary.ps1 -ProjectDir F:\Development\MyRepo                  # latest run in the log
.EXAMPLE
  ./Invoke-LoopSummary.ps1 -ProjectDir F:\Development\MyRepo -RunId 20261104-073919 -DigestOnly
#>
[CmdletBinding()]
param(
    [string]$ProjectDir = (Get-Location).Path,
    [string]$RunId = '',                 # blank = the last loop-start in the log
    [string]$LogPath = '',               # blank = <ProjectDir>/.claude/state/agent-loop.log.jsonl
    [string]$HandoffLogPath = '',        # handoff-log.json; skipped when missing
    [string]$ClaudePath = $env:CLAUDE_EXE,
    [string]$Model = 'sonnet',           # summarizing is a cheap-model task
    [double]$MaxBudgetUsd = 1.0,
    [string]$PromptPath = (Join-Path $PSScriptRoot 'LoopSummaryPrompt.md'),
    [string]$SchemaPath = (Join-Path $PSScriptRoot 'loop-summary.schema.json'),
    [switch]$DigestOnly                  # write the digest and stop; no model call, no log line
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProjectDir = (Resolve-Path -LiteralPath $ProjectDir).Path
if (-not $LogPath) { $LogPath = Join-Path $ProjectDir '.claude/state/agent-loop.log.jsonl' }
if (-not (Test-Path -LiteralPath $LogPath)) { throw "Loop log not found: $LogPath" }

# Older runs decoded claude's UTF-8 stdout as code page 437, so an en dash was logged as 'ΓÇô'.
# Re-encoding as 437 and decoding as UTF-8 recovers the text; keep the original if that fails.
$cp437 = [Text.Encoding]::GetEncoding(437)
$strictUtf8 = [Text.UTF8Encoding]::new($false, $true)
function Repair-Text([string]$Text) {
    if (-not $Text -or $Text -notmatch '[ΓÇÔ][ÇÄÉ]') { return $Text }
    # Only text that is entirely 437-representable can be mojibake; anything else is left alone
    if ($cp437.GetString($cp437.GetBytes($Text)) -cne $Text) { return $Text }
    try { return $strictUtf8.GetString($cp437.GetBytes($Text)) } catch { return $Text }
}
function Limit-Text([string]$Text, [int]$Max) {
    if (-not $Text -or $Text.Length -le $Max) { return $Text }
    $Text.Substring(0, $Max) + " … [$($Text.Length - $Max) more chars]"
}
$prop = { param($o, $n) if ($o -and $o.PSObject.Properties[$n]) { $o.$n } }
# ConvertFrom-Json turns ISO timestamps into DateTime; print them back as ISO, not in the locale format
$iso = { param($v) if ($v -is [datetime]) { $v.ToString('yyyy-MM-dd HH:mm:sszzz') } else { "$v" } }

# --- Load this run's log entries ----------------------------------------------------------------
$entries = @(Get-Content -LiteralPath $LogPath -Encoding utf8 | ForEach-Object {
        if ($_.Trim()) { try { $_ | ConvertFrom-Json -ErrorAction Stop } catch { } }
    })
if (-not $RunId) {
    $RunId = @($entries | Where-Object { $_.type -eq 'loop-start' })[-1].runId
    if (-not $RunId) { throw "No loop-start entry in $LogPath" }
}
$run = @($entries | Where-Object { (& $prop $_ 'runId') -eq $RunId })
$start = $run | Where-Object type -eq 'loop-start' | Select-Object -First 1
$end = $run | Where-Object type -eq 'loop-end' | Select-Object -First 1
$sessionRows = @($run | Where-Object type -eq 'session' | Sort-Object session)
$messages = @($run | Where-Object type -eq 'message')
if (-not $start) { throw "Run $RunId has no loop-start entry in $LogPath" }
$stateDir = Split-Path $LogPath -Parent
$runDir = Join-Path $stateDir 'runs'

# --- Tool errors from the raw stream logs (the loop log keeps assistant text only) ---------------
$toolErrors = [Collections.Generic.List[object]]::new()
foreach ($row in $sessionRows) {
    $raw = & $prop $row 'rawLog'
    if (-not $raw -or -not (Test-Path -LiteralPath $raw)) { continue }
    $calls = @{}
    foreach ($line in [IO.File]::ReadLines($raw)) {
        if ($line -notmatch '"tool_use"|"is_error":true') { continue }   # skip the bulk cheaply
        try { $e = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        # @() because a one-block content array comes back from the scriptblock unrolled to a scalar
        $content = @(& $prop (& $prop $e 'message') 'content')
        foreach ($b in $content) {
            if ($b -is [string]) { continue }
            $bt = & $prop $b 'type'
            if ($bt -eq 'tool_use') { $calls[$b.id] = $b }
            elseif ($bt -eq 'tool_result' -and (& $prop $b 'is_error')) {
                $call = $calls[$b.tool_use_id]
                $in = if ($call) { $call.input } else { $null }
                $what = (& $prop $in 'command') ?? (& $prop $in 'file_path') ?? (& $prop $in 'pattern') ??
                ($(if ($in) { $in | ConvertTo-Json -Compress -Depth 4 }))
                $text = if ($b.content -is [string]) { $b.content } else { ($b.content | ForEach-Object { & $prop $_ 'text' }) -join "`n" }
                $toolErrors.Add([pscustomobject]@{
                        session = $row.session
                        tool    = if ($call) { $call.name } else { '?' }
                        input   = Limit-Text (Repair-Text "$what") 300
                        error   = Limit-Text (Repair-Text "$text") 500
                    })
            }
        }
    }
}

# --- Git facts, collected now that the loop has ended ---------------------------------------------
function Get-Git([string[]]$GitArgs) {
    $out = & git -C $ProjectDir @GitArgs 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    @($out) -join "`n"
}
$isGit = $null -ne (Get-Git @('rev-parse', '--is-inside-work-tree'))
$since = ([datetimeoffset]$start.ts).ToString('o')

# --- Handoff entries recorded during this run -----------------------------------------------------
$handoffs = @()
if ($HandoffLogPath -and (Test-Path -LiteralPath $HandoffLogPath)) {
    try {
        $handoffs = @((Get-Content -LiteralPath $HandoffLogPath -Raw -Encoding utf8 | ConvertFrom-Json).entries |
                Where-Object { $_ -and (& $prop $_ 'runId') -eq $RunId })
    }
    catch { Write-Warning "Handoff log not read: $($_.Exception.Message)" }
}
$lastRaw = & $prop $sessionRows[-1] 'rawLog'
$snapshot = if ($lastRaw) { $lastRaw -replace '\.jsonl$', '-handoff.md' }

# --- Digest ---------------------------------------------------------------------------------------
$rel = { param($p) if ($p) { [IO.Path]::GetRelativePath($ProjectDir, $p) } }
$sb = [Text.StringBuilder]::new()
$w = { param($s = '') [void]$sb.AppendLine($s) }
& $w "# Agent-loop run $RunId"
& $w
& $w "- Repository: $($start.project)"
& $w "- Prompt: $($start.prompt) · permission mode $($start.permissionMode) · max sessions $($start.maxSessions)"
& $w "- Handoff file: $($start.handoffFile)"
& $w "- Started: $(& $iso $start.ts)"
& $w ("- Ended: " + $(if ($end) { "$(& $iso $end.ts) · stop reason **$($end.stopReason)** · $($end.sessions) sessions · $($end.totalTurns) turns · `$$($end.totalCostUsd)" } else { 'no loop-end entry (interrupted or still running)' }))
& $w
& $w '## Sessions'
& $w
& $w '| # | Outcome | Success | Turns | Cost USD | Duration s | Denials |'
& $w '| --- | --- | --- | --- | --- | --- | --- |'
foreach ($r in $sessionRows) {
    & $w "| $($r.session) | $($r.outcome) | $($r.success) | $($r.turns) | $($r.costUsd) | $($r.durationSec) | $(@($r.denials).Count) |"
}
foreach ($r in $sessionRows | Where-Object { @($_.denials).Count }) {
    foreach ($d in $r.denials) { & $w "- Session $($r.session) denied: ``$($d.tool)`` $($d.input)" }
}
& $w
& $w '## Git facts (after the loop ended)'
& $w
if ($isGit) {
    & $w "- Branch: $(Get-Git @('rev-parse', '--abbrev-ref', 'HEAD')) · HEAD $(Get-Git @('rev-parse', '--short', 'HEAD'))"
    $commits = Get-Git @('log', "--since=$since", '--format=%h %s')
    & $w
    & $w '### Commits since the run started'
    & $w
    & $w '```text'; & $w ($commits ? $commits : '(none)'); & $w '```'
    & $w
    & $w '### git status --short'
    & $w
    & $w '```text'; & $w ((Get-Git @('status', '--short')) ?? '(clean)'); & $w '```'
    & $w
    & $w '### git diff --stat HEAD'
    & $w
    & $w '```text'; & $w ((Get-Git @('diff', '--stat', 'HEAD')) ?? '(none)'); & $w '```'
    & $w
    & $w 'Uncommitted changes may predate this run. Credit a file to the run only when its messages describe the change.'
}
else { & $w 'Not a git repository.' }
& $w
& $w "## Tool calls that returned an error ($($toolErrors.Count))"
& $w
foreach ($t in $toolErrors) { & $w "- Session $($t.session) · ``$($t.tool)`` · input: $($t.input -replace '\r?\n', ' ⏎ ')"; & $w "  - error: $($t.error -replace '\r?\n', ' | ')" }
if (-not $toolErrors.Count) { & $w '(none)' }
& $w
& $w "## Handoff entries recorded in this run ($($handoffs.Count))"
& $w
foreach ($h in $handoffs) {
    & $w "### Session $(& $prop $h 'session') · $(& $iso (& $prop $h 'recordedAt')) · $(& $prop $h 'summary')"
    & $w
    foreach ($k in 'did', 'verified', 'safeToProceed', 'next', 'owner') { if (& $prop $h $k) { & $w "- **${k}:** $(& $prop $h $k)" } }
    & $w
}
if ($snapshot -and (Test-Path -LiteralPath $snapshot)) { & $w "Final handoff snapshot (read its top entry): ``$(& $rel $snapshot)``" }
& $w
& $w '## Assistant messages, in order'
foreach ($r in $sessionRows) {
    $sm = @($messages | Where-Object session -eq $r.session)
    & $w
    & $w "### Session $($r.session) ($($r.outcome), $($sm.Count) messages)"
    for ($i = 0; $i -lt $sm.Count; $i++) {
        $last = $i -eq $sm.Count - 1
        $text = Repair-Text $sm[$i].text
        & $w
        if ($last) { & $w "#### Session $($r.session) wrap-up report" ; & $w; & $w $text }
        else { & $w "- [$(([datetimeoffset]$sm[$i].ts).ToString('HH:mm:ss'))] $((Limit-Text $text 1500) -replace '\r?\n', ' ')" }
    }
}

New-Item -ItemType Directory -Force -Path $runDir | Out-Null
$digestPath = Join-Path $runDir "$RunId-summary-digest.md"
[IO.File]::WriteAllText($digestPath, $sb.ToString(), [Text.UTF8Encoding]::new($false))
Write-Host "Summary digest: $digestPath ($([math]::Round($sb.Length / 1KB)) KB, $($toolErrors.Count) tool errors)" -ForegroundColor DarkGray
if ($DigestOnly) { return Get-Item -LiteralPath $digestPath }

# --- The summarizer call --------------------------------------------------------------------------
function Write-SummaryLog([System.Collections.IDictionary]$Fields) {
    $entry = [ordered]@{ ts = (Get-Date).ToString('o'); type = 'summary'; runId = $RunId }
    foreach ($k in $Fields.Keys) { $entry[$k] = $Fields[$k] }
    Add-Content -LiteralPath $LogPath -Value ($entry | ConvertTo-Json -Compress -Depth 10) -Encoding utf8
}

# StrictMode throws on $null.Source, so test the Get-Command result before reading it
if (-not $ClaudePath) {
    $found = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { $ClaudePath = $found.Source }
}
if (-not $ClaudePath) {
    $ClaudePath = @("$HOME\.local\bin\claude.exe", "$env:APPDATA\npm\claude.cmd", "$env:LOCALAPPDATA\Programs\claude\claude.exe") |
        Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $ClaudePath) { throw 'Claude Code CLI not found. Pass -ClaudePath or set $env:CLAUDE_EXE.' }

$schema = (Get-Content -LiteralPath $SchemaPath -Raw | ConvertFrom-Json | ConvertTo-Json -Compress -Depth 20)
# Instructions go over stdin: no quoting limits, and a positional prompt can't be swallowed by a variadic flag
$prompt = (Get-Content -LiteralPath $PromptPath -Raw) +
"`n`n## This run`n`nRun id: $RunId`nDigest file: $(& $rel $digestPath)`n`nRead the digest, check what you need, then return the summary."
$cliArgs = @(
    '-p', '--output-format', 'json', '--json-schema', $schema
    '--model', $Model, '--max-budget-usd', "$MaxBudgetUsd"
    '--tools', 'Read,Grep,Glob', '--allowedTools', 'Read,Grep,Glob'
    '--settings', '{"disableAllHooks":true}', '--strict-mcp-config', '--no-session-persistence'
)

$started = Get-Date
$prevOut = [Console]::OutputEncoding
$prevLoc = Get-Location
try {
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)   # claude writes UTF-8
    Set-Location -LiteralPath $ProjectDir
    $env:TK_DISABLE = '1'
    $global:LASTEXITCODE = 0
    $out = @($prompt | & $ClaudePath @cliArgs 2>&1 | ForEach-Object { "$_" })
    $exit = $LASTEXITCODE
}
finally { [Console]::OutputEncoding = $prevOut; Set-Location $prevLoc }
$duration = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)

$result = $null
foreach ($line in $out) { try { $o = $line | ConvertFrom-Json -ErrorAction Stop; if ((& $prop $o 'type') -eq 'result') { $result = $o } } catch { } }
$summary = & $prop $result 'structured_output'
if (-not $summary -and $result -and (& $prop $result 'result')) {
    # Fallback: the model answered in text; accept it if it is the JSON object
    $txt = ($result.result -replace '(?s)^\s*```(?:json)?\s*|\s*```\s*$', '')
    try { $summary = $txt | ConvertFrom-Json -ErrorAction Stop } catch { }
}
$meta = [ordered]@{
    model       = $Model
    costUsd     = & $prop $result 'total_cost_usd'
    durationSec = $duration
    digest      = $digestPath
}
if ($exit -ne 0 -or -not $summary -or -not (& $prop $summary 'headline')) {
    $why = if (-not $result) { "no result event (exit $exit): $(Limit-Text (($out | Select-Object -Last 5) -join ' | ') 400)" }
    elseif (& $prop $result 'is_error') { "result error ($($result.subtype)): $(Limit-Text "$(& $prop $result 'result')" 400)" }
    else { "no structured output (exit $exit, subtype $($result.subtype))" }
    $meta['error'] = $why
    Write-SummaryLog $meta
    Write-Warning "Run summary not written: $why"
    return
}
$meta['summary'] = $summary
Write-SummaryLog $meta
Write-Host ("Run summary [{0}]: {1}" -f $summary.status, $summary.headline) -ForegroundColor Green
[pscustomobject]$meta
