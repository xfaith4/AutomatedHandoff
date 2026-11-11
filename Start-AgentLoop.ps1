#Requires -Version 7
<#
.SYNOPSIS
  Runs Claude Code headless in a loop. Each iteration is a fresh context window
  that starts with /handoff. By default it relaunches only when context-guard.ps1
  set rotate.flag. With -UntilDone it also relaunches after a session that finished
  its item, and keeps going until the handoff says DONE, is blocked, stalls, or a cap is hit.

.EXAMPLE
  ./Start-AgentLoop.ps1 -ProjectDir F:\Development\MyRepo -MaxSessions 8
.EXAMPLE
  ./Start-AgentLoop.ps1 F:\Development\MyRepo -UntilDone -MaxSessions 20 -MaxCostUsd 60
#>
param(
    [string]$ProjectDir = (Get-Location).Path,
    [int]$MaxSessions = 10,
    [string]$Prompt = '/handoff',
    # auto: the classifier approves routine git/npx/reads that an allowlist can't anticipate; -p has no human to ask
    [ValidateSet('auto', 'acceptEdits', 'manual', 'dontAsk', 'plan', 'bypassPermissions')]
    [string]$PermissionMode = 'auto',
    [string]$HandoffFile = '',          # blank = .claude/agent-loop.json, then auto-discover
    [string]$LogPath = '',              # blank = .claude/state/agent-loop.log.jsonl (one JSON object per line)
    [string[]]$ExtraArgs = @(),         # e.g. '--allowedTools','Bash(pwsh:*)','--model','opus'
    [string]$ClaudePath = $env:CLAUDE_EXE,  # optional explicit path to claude.exe / claude.cmd
    [switch]$NoSummary,                 # skip the end-of-run summary call (Invoke-LoopSummary.ps1)
    [string]$SummaryModel = 'sonnet',

    # Until-done mode: one roadmap item per session, keep going until the handoff says DONE
    [switch]$UntilDone,
    # Appended to a default '/handoff' prompt in until-done mode. Blank = send the prompt unchanged.
    [string]$UntilDoneSteer = 'engineering only. Do exactly one roadmap item this session. ' +
    'If the Next item needs an owner decision, record the question in the handoff Owner line and take the next unblocked roadmap item instead. ' +
    'If no unblocked item is left, write "Safe to proceed: no" and say why. ' +
    'When the roadmap has no open items left, write the handoff entry with -NextLabel DONE and -Next "DONE: <why>".',
    [double]$MaxCostUsd = 0,            # 0 = no cap. Cumulative estimated cost (the CLI's total_cost_usd per session)
    [long]$MaxTokens = 0,               # 0 = no cap. Cumulative input + cache + output tokens from the result events
    [int]$MaxConsecutiveFailures = 2,   # until-done: a failed session is retried until this many fail in a row
    [int]$StallSessions = 2,            # until-done: stop after this many finished sessions in a row with no progress
    [switch]$StopOnOwnerItems,          # until-done: also stop when the top entry's Owner line is not "nothing"
    [double]$RateLimitWaitMinutes = 0,  # 0 = stop on a usage-limit result. Otherwise sleep this long and start a new session
    [int]$MaxRateLimitWaits = 3,

    # Context budget per session. context-guard.ps1 reads it from AGENT_LOOP_SOFT_TOKENS / AGENT_LOOP_HARD_TOKENS.
    # Auto-compaction is near 200k and the wrap-up (finish the step, write the handoff) needs 10-20k, so 190k is the ceiling.
    [ValidateRange(50000, 195000)][int]$SoftLimit = 170000,
    [ValidateRange(50000, 199000)][int]$HardLimit = 190000,
    # B3: once a session has rewritten the handoff (an item closed) and context is at or above this, the guard
    # rotates so the next item starts fresh. Read from AGENT_LOOP_BOUNDARY_TOKENS. 0 = off. Must be below -SoftLimit.
    [ValidateRange(0, 195000)][int]$BoundaryLimit = 100000,
    # MCP servers are fixed context in every session. Default: --strict-mcp-config with no servers.
    # -McpConfig loads only the servers in that file; -KeepMcp loads the usual user/project/plugin set.
    [string]$McpConfig = '',
    [switch]$KeepMcp,
    # Default: the session-hygiene hook uses the repo handoff as its handoff (one source of truth, no second Stop block)
    # and skips its SessionStart injection, because /handoff reads the repo handoff itself. This restores the normal hook.
    [switch]$KeepHygieneInjection,
    # Pre-session brief: git facts, the handoff's top entry and its roadmap item, written to runs/<stamp>-s<n>-brief.md
    # and passed with --append-system-prompt-file (a file, so newlines and quotes survive Windows argument passing).
    [ValidateRange(500, 20000)][int]$BriefMaxChars = 4000,
    [string]$RoadmapFile = 'ROADMAP.md',
    [switch]$NoBrief
)
if ($SoftLimit -ge $HardLimit) { throw "-SoftLimit ($SoftLimit) must be below -HardLimit ($HardLimit)." }
if ($BoundaryLimit -ge $SoftLimit) { throw "-BoundaryLimit ($BoundaryLimit) must be below -SoftLimit ($SoftLimit); 0 turns it off." }
if ($McpConfig -and -not (Test-Path -LiteralPath $McpConfig -PathType Leaf)) { throw "-McpConfig file not found: $McpConfig" }
if ($McpConfig) { $McpConfig = (Resolve-Path -LiteralPath $McpConfig).Path }

# Locate the Claude Code CLI: explicit -> PATH -> common Windows install locations
if (-not $ClaudePath) {
    $ClaudePath = (Get-Command claude -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1).Source
}
if (-not $ClaudePath) {
    $ClaudePath = @(
        "$HOME\.local\bin\claude.exe"            # native installer (irm https://claude.ai/install.ps1 | iex)
        "$env:APPDATA\npm\claude.cmd"            # npm i -g @anthropic-ai/claude-code
        "$env:LOCALAPPDATA\Programs\claude\claude.exe"
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
}
if (-not $ClaudePath) {
    throw "Claude Code CLI not found. Install it (irm https://claude.ai/install.ps1 | iex), " +
    "add it to PATH, or pass -ClaudePath / set `$env:CLAUDE_EXE."
}
Write-Host "Claude CLI: $ClaudePath" -ForegroundColor DarkGray

Set-Location $ProjectDir
$stateDir = Join-Path $ProjectDir '.claude/state'
$flag = Join-Path $stateDir 'rotate.flag'
$runDir = Join-Path $stateDir 'runs'
. (Join-Path $PSScriptRoot 'Resolve-HandoffFile.ps1')
$HandoffFile = Resolve-HandoffFile $ProjectDir $HandoffFile
$handoff = Join-Path $ProjectDir $HandoffFile
Write-Host "Handoff file: $HandoffFile" -ForegroundColor DarkGray
New-Item -ItemType Directory -Force -Path $runDir | Out-Null

if ($UntilDone -and $Prompt -eq '/handoff' -and $UntilDoneSteer) { $Prompt = "/handoff $UntilDoneSteer" }
if ($UntilDone) {
    $caps = @(
        "sessions $MaxSessions"
        if ($MaxCostUsd -gt 0) { 'cost ${0:N2}' -f $MaxCostUsd }
        if ($MaxTokens -gt 0) { "tokens $MaxTokens" }
        "stall after $StallSessions idle sessions"
        "failures $MaxConsecutiveFailures in a row"
        if ($RateLimitWaitMinutes -gt 0) { "usage-limit wait $RateLimitWaitMinutes min x$MaxRateLimitWaits" } else { 'stop on usage limit' }
    ) -join ' | '
    Write-Host "Until-done mode: continue after each finished item until the handoff says DONE." -ForegroundColor Cyan
    Write-Host "Caps: $caps" -ForegroundColor DarkGray
    Write-Host "Prompt: $Prompt" -ForegroundColor DarkGray
}

# Start-Agent runs this script in the caller's shell, so every env var set below is put back in the
# finally block at the end of the file. Before, AGENT_LOOP_RUN_ID outlived the run and tagged later
# interactive handoff entries with a stale runId.
$envNames = @('TK_DISABLE', 'AGENT_LOOP_RUN_ID', 'AGENT_LOOP_SESSION', 'AGENT_LOOP_SOFT_TOKENS', 'AGENT_LOOP_HARD_TOKENS', 'AGENT_LOOP_BOUNDARY_TOKENS',
    'CLAUDE_HYGIENE_MAP', 'CLAUDE_HYGIENE_HANDOFF_MAX_AGE_DAYS', 'CLAUDE_HYGIENE_SOFT_TOKENS', 'CLAUDE_HYGIENE_HARD_TOKENS')
$envBackup = @{}
foreach ($k in $envNames) { $envBackup[$k] = [Environment]::GetEnvironmentVariable($k) }
$prevOutputEncoding = [Console]::OutputEncoding
# The body below is not re-indented under this try; the finally at the end of the file restores the shell.
try {

# tk wraps git/cat/etc. in { ... } so allow-listed commands need a human to approve them; -p has none
$env:TK_DISABLE = '1'
# claude writes UTF-8. Decoding it with the console code page (437) logged an en dash as 'ΓÇô'.
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
# The session-hygiene handoff lives outside the repo; let unattended sessions write it
$hygieneDir = (Join-Path $HOME '.claude/handoffs') -replace '\\', '/'

# Context budget for context-guard.ps1 (a user-level hook, so it reads the run's limits from the environment)
$env:AGENT_LOOP_SOFT_TOKENS = "$SoftLimit"
$env:AGENT_LOOP_HARD_TOKENS = "$HardLimit"
$env:AGENT_LOOP_BOUNDARY_TOKENS = "$BoundaryLimit"

# MCP servers: none by default. The ledger runs loaded 36 (Slack, Gmail, Snowflake, ...) and started every session
# at ~50k tokens before reading a file.
$mcpArgs = @()
$mcpMode = 'default (user, project and plugin servers)'
if ($McpConfig) {
    $mcpArgs = @('--strict-mcp-config', '--mcp-config', $McpConfig)
    $mcpMode = "only $McpConfig"
}
elseif (-not $KeepMcp) {
    $noMcp = Join-Path $stateDir 'mcp-none.json'
    Set-Content -LiteralPath $noMcp -Value '{ "mcpServers": {} }' -Encoding utf8
    $mcpArgs = @('--strict-mcp-config', '--mcp-config', $noMcp)
    $mcpMode = 'none (--strict-mcp-config)'
}
Write-Host "MCP servers: $mcpMode" -ForegroundColor DarkGray

# Session-hygiene hook: point it at the repo handoff, match its budget to the guard's, and turn off its
# SessionStart injection (max age 0 days). Otherwise every session got a second, possibly staler handoff
# injected, and the hygiene Stop hook asked for a second handoff file at 160k.
$hygieneMode = 'normal'
if (-not $KeepHygieneInjection) {
    $hygieneMap = Join-Path $stateDir 'hygiene-map.json'
    @{ $ProjectDir = (Join-Path $ProjectDir $HandoffFile) } | ConvertTo-Json | Set-Content -LiteralPath $hygieneMap -Encoding utf8
    $env:CLAUDE_HYGIENE_MAP = $hygieneMap
    $env:CLAUDE_HYGIENE_HANDOFF_MAX_AGE_DAYS = '0'
    $env:CLAUDE_HYGIENE_SOFT_TOKENS = "$SoftLimit"
    $env:CLAUDE_HYGIENE_HARD_TOKENS = "$HardLimit"
    $hygieneMode = 'repo handoff, no injection'
}
Write-Host ("Context budget: soft {0}k, hard {1}k, item boundary {2} | hygiene hook: {3}" -f ($SoftLimit / 1000), ($HardLimit / 1000),
    ($BoundaryLimit -gt 0 ? "$($BoundaryLimit / 1000)k" : 'off'), $hygieneMode) -ForegroundColor DarkGray

# Run log: everything shown in the terminal, as JSONL. AgentLoopReport.html renders it.
if (-not $LogPath) { $LogPath = Join-Path $stateDir 'agent-loop.log.jsonl' }
$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
# Add-RunHandoffEntry.ps1 records these so the report can show each handoff under its session
$env:AGENT_LOOP_RUN_ID = $runId
function Write-LoopLog([string]$Type, [System.Collections.IDictionary]$Fields) {
    $entry = [ordered]@{ ts = (Get-Date).ToString('o'); type = $Type; runId = $runId }
    foreach ($k in $Fields.Keys) { $entry[$k] = $Fields[$k] }
    Add-Content -LiteralPath $LogPath -Value ($entry | ConvertTo-Json -Compress -Depth 6)
}

# --- helpers -----------------------------------------------------------------

function Get-GitHead {
    # Short HEAD sha, or $null outside a repo / without git. Never throws.
    try {
        $h = git -C $ProjectDir rev-parse --short HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $h) { return "$h".Trim() }
    }
    catch {}
    return $null
}

function Get-HandoffBrief([string]$Path) {
    # The top entry of a newest-first handoff (Add-RunHandoffEntry.ps1 shape), or the sections of a
    # session-hygiene style handoff. Everything is best-effort text; missing fields stay ''.
    $b = [ordered]@{ exists = $false; heading = ''; label = ''; did = ''; next = ''; owner = ''; safe = ''; status = '' }
    if (-not (Test-Path $Path)) { return $b }
    $b.exists = $true
    $lines = @([IO.File]::ReadAllLines($Path))
    $starts = @(for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^##\s') { $i } })
    # Head region = file header + top entry: a Status: DONE line further down belongs to an older entry
    $endIdx = if ($starts.Count -ge 2) { $starts[1] - 1 } else { $lines.Count - 1 }
    $head = if ($lines.Count) { $lines[0..$endIdx] } else { @() }
    foreach ($l in $head) {
        if ($l -match '^\s*Status:\s*(DONE|COMPLETE)\b') { $b.status = $Matches[1].ToUpper(); break }
    }
    $entryRx = '^##\s+(?<date>\d{4}-\d{2}-\d{2})\s+\S+\s+(?<summary>.*?)(?:\s+\((?<label>[^()]+?)\s+next\))?\s*$'
    if ($starts.Count -and $lines[$starts[0]] -match $entryRx) {
        $b.heading = $lines[$starts[0]].Substring(3).Trim()
        $b.label = "$($Matches['label'])".Trim()
        foreach ($l in $head) {
            if ($l -match '^\s*-\s+\*\*(?<k>[^*]+?):\*\*\s*(?<v>.*)$') {
                switch ($Matches['k'].Trim().ToLower()) {
                    'did' { $b.did = $Matches['v'].Trim() }
                    'next' { $b.next = $Matches['v'].Trim() }
                    'owner' { $b.owner = $Matches['v'].Trim() }
                    'safe to proceed' { $b.safe = $Matches['v'].Trim() }
                }
            }
        }
        return $b
    }
    # Session-hygiene template: "# Handoff: ..." with ## Status / ## Next action / ## Waiting on the user
    $title = $lines | Where-Object { $_ -match '^#\s' } | Select-Object -First 1
    if ($title) { $b.heading = $title.Substring(1).Trim() }
    $section = ''
    $buf = @{}
    foreach ($l in $lines) {
        if ($l -match '^##\s+(.+?)\s*$') { $section = $Matches[1].ToLower(); continue }
        if ($section -and $l.Trim()) { $buf[$section] = (@($buf[$section], $l.Trim()) -join ' ').Trim() }
    }
    $b.did = "$($buf['status'])"
    $b.next = "$($buf['next action'])"
    $b.owner = "$($buf['waiting on the user'])"
    return $b
}

function Test-HandoffDone($Brief) {
    if ($Brief.status) { return $true }
    # Case-sensitive: a Next line that starts with "Done-when" must not end the run
    if ($Brief.label -cmatch '^(DONE|COMPLETE)$') { return $true }
    return [bool]($Brief.next -cmatch '^(DONE|COMPLETE)\b')
}

function Test-OwnerNothing([string]$Owner) {
    return [bool]($Owner -match '^\s*(nothing|none|n/?a|-|—)?\s*\.?\s*$')
}

function Get-ResultTokens($Result) {
    $u = $Result.usage
    if (-not $u) { return [long]0 }
    [long]$t = 0
    foreach ($k in 'input_tokens', 'cache_creation_input_tokens', 'cache_read_input_tokens', 'output_tokens') {
        $p = $u.PSObject.Properties[$k]
        if ($p -and $null -ne $p.Value) { $t += [long]$p.Value }
    }
    return $t
}

function Format-Tokens([long]$T) {
    if ($T -ge 1000000) { return '{0:N1}M' -f ($T / 1000000) }
    if ($T -ge 1000) { return '{0:N0}k' -f ($T / 1000) }
    return "$T"
}

function Get-StartupMetrics([string]$Path) {
    # What a session spent getting up to speed, from its raw stream log. Main chain only: subagent
    # traffic (parent_tool_use_id set) is not in the main context. Best-effort; never throws.
    # firstEditCall is the 1-based tool call index of the first Edit/Write (Bash edits such as sed -i don't count).
    $m = [ordered]@{
        tools = $null; mcpServers = $null; firstCallCtx = $null; firstCallCacheRead = $null; firstCallCacheCreation = $null
        firstEditCall = $null; ctxAtFirstEdit = $null
        resultCharsBeforeEdit = [long]0; toolCalls = 0; repeatedReads = 0
    }
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $m }
    $editTools = 'Edit', 'Write', 'MultiEdit', 'NotebookEdit'
    $ctx = $null
    $beforeEdit = @{}
    $reads = @{}
    try {
        foreach ($line in [IO.File]::ReadLines($Path)) {
            try { $e = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
            if ($e.type -eq 'system' -and $e.subtype -eq 'init') {
                $m.tools = @($e.tools).Count; $m.mcpServers = @($e.mcp_servers).Count; continue
            }
            if ($e.PSObject.Properties['parent_tool_use_id'] -and $e.parent_tool_use_id) { continue }
            if ($e.type -eq 'assistant') {
                $u = $e.message.usage
                if ($u) {
                    $ctx = [long]$u.input_tokens + [long]$u.cache_creation_input_tokens + [long]$u.cache_read_input_tokens
                    if ($null -eq $m.firstCallCtx) {
                        # Kept apart: a cold first call (all cache creation) costs far more than a warm one (all cache read).
                        $m.firstCallCtx = $ctx
                        $m.firstCallCacheRead = [long]$u.cache_read_input_tokens
                        $m.firstCallCacheCreation = [long]$u.cache_creation_input_tokens
                    }
                }
                foreach ($c in @($e.message.content)) {
                    if ($c.type -ne 'tool_use') { continue }
                    $m.toolCalls++
                    if ($c.name -eq 'Read' -and $c.input.file_path) {
                        $key = ('{0}|{1}|{2}' -f ("$($c.input.file_path)" -replace '\\', '/').ToLower(), $c.input.offset, $c.input.limit)
                        if ($reads.ContainsKey($key)) { $m.repeatedReads++ } else { $reads[$key] = $true }
                    }
                    if ($null -eq $m.firstEditCall) {
                        if ($c.name -in $editTools) { $m.firstEditCall = $m.toolCalls; $m.ctxAtFirstEdit = $ctx }
                        else { $beforeEdit[$c.id] = $true }
                    }
                }
            }
            elseif ($e.type -eq 'user') {
                foreach ($c in @($e.message.content)) {
                    if ($c.type -ne 'tool_result' -or -not $beforeEdit.ContainsKey("$($c.tool_use_id)")) { continue }
                    $m.resultCharsBeforeEdit += if ($c.content -is [string]) { $c.content.Length }
                    else { [long](@($c.content) | ForEach-Object { "$($_.text)".Length } | Measure-Object -Sum).Sum }
                }
            }
        }
    }
    catch { Write-Verbose "startup metrics: $($_.Exception.Message)" }
    return $m
}

function Format-Startup($S) {
    if ($null -eq $S.firstCallCtx) { return 'no usage recorded' }
    $edit = if ($S.firstEditCall) { "first edit at call $($S.firstEditCall), $(Format-Tokens $S.ctxAtFirstEdit)" } else { 'no Edit/Write' }
    $hit = if ($S.firstCallCtx -gt 0 -and $null -ne $S.firstCallCacheRead) { ', {0:P0} cache hit' -f ($S.firstCallCacheRead / $S.firstCallCtx) } else { '' }
    return '{0} at first call{5} | {1} | {2} MCP servers, {3} tools | {4} repeated reads' -f (Format-Tokens $S.firstCallCtx), $edit, $S.mcpServers, $S.tools, $S.repeatedReads, $hit
}

function Limit-Text([string]$S, [int]$Max = 150) {
    $S = "$S" -replace '\s+', ' '
    if ($S.Length -le $Max) { return $S }
    return $S.Substring(0, $Max - 1) + '…'
}

function Invoke-GitLines([string[]]$GitArgs) {
    # git output as lines, @() on failure or outside a repo. Never throws.
    try {
        $out = @(git -C $ProjectDir @GitArgs 2>$null)
        if ($LASTEXITCODE -eq 0) { return @($out | Where-Object { $_ -ne $null }) }
    }
    catch {}
    return @()
}

function Get-RoadmapItem([string]$Path, [string]$Label) {
    # The roadmap lines for a handoff label: the "[[A4]]" checklist item with its indented continuation lines,
    # under its release heading; else a heading that names the label, up to the next heading of the same level.
    if (-not $Label -or $Label -cmatch '^(DONE|COMPLETE)$' -or -not (Test-Path -LiteralPath $Path)) { return @() }
    $lines = @([IO.File]::ReadAllLines($Path))
    $esc = [regex]::Escape($Label)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch "\[\[$esc\]\]") { continue }
        $out = [System.Collections.Generic.List[string]]::new()
        for ($h = $i - 1; $h -ge 0; $h--) { if ($lines[$h] -match '^##\s') { $out.Add($lines[$h]); break } }
        $out.Add($lines[$i])
        for ($j = $i + 1; $j -lt $lines.Count -and $lines[$j] -match '^\s+\S'; $j++) { $out.Add($lines[$j]) }
        return @($out)
    }
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch "^(?<hashes>#{2,4})\s.*\b$esc\b") { continue }
        $level = $Matches['hashes'].Length
        $out = @($lines[$i])
        for ($j = $i + 1; $j -lt $lines.Count; $j++) {
            if ($lines[$j] -match '^(#+)\s' -and $Matches[1].Length -le $level) { break }
            $out += $lines[$j]
        }
        return $out
    }
    return @()
}

function New-SessionBrief($Handoff, [int]$Session, [string]$SinceHead, [string]$RoadmapPath, [int]$MaxChars) {
    # Facts the agent would otherwise spend its first tool calls collecting. Appended to the system prompt,
    # so it sits after the cached prefix; capped at $MaxChars, the roadmap part is cut first.
    $nl = "`n"
    $sb = [Text.StringBuilder]::new()
    [void]$sb.Append("# Loop brief (session $Session)$nl$nl")
    [void]$sb.Append("Start-AgentLoop.ps1 collected these facts just before this session started. Use them instead of " +
        "re-running git status/log or re-reading the handoff's top entry; open files only for detail you need. " +
        "If a file disagrees with this brief, the file wins.$nl$nl")

    [void]$sb.Append("## Git$nl$nl")
    $branch = (Invoke-GitLines @('rev-parse', '--abbrev-ref', 'HEAD') | Select-Object -First 1)
    $head = Get-GitHead
    if (-not $head) { [void]$sb.Append("- Not a git repository.$nl") }
    else {
        [void]$sb.Append("- Branch $branch, HEAD $head$nl")
        $commits = if ($SinceHead -and $SinceHead -ne $head) { Invoke-GitLines @('log', '--oneline', '-n', '20', "$SinceHead..HEAD") } else { @() }
        if ($SinceHead) {
            $what = if ($commits.Count) { ($commits | ForEach-Object { "  - $_" }) -join $nl } else { '  - none' }
            [void]$sb.Append("- Commits since the previous session started ($SinceHead):$nl$what$nl")
        }
        else {
            $recent = Invoke-GitLines @('log', '--oneline', '-n', '3')
            [void]$sb.Append("- Recent commits:$nl$(($recent | ForEach-Object { "  - $_" }) -join $nl)$nl")
        }
        $status = Invoke-GitLines @('status', '--porcelain')
        if (-not $status.Count) { [void]$sb.Append("- Working tree clean.$nl") }
        else {
            $shown = ($status | Select-Object -First 15 | ForEach-Object { "  - ``$($_.TrimEnd())``" }) -join $nl
            $more = if ($status.Count -gt 15) { "$nl  - ... and $($status.Count - 15) more" } else { '' }
            [void]$sb.Append("- Working tree: $($status.Count) changed or untracked:$nl$shown$more$nl")
        }
    }

    [void]$sb.Append("$nl## Handoff top entry ($HandoffFile)$nl$nl")
    if (-not $Handoff.exists) { [void]$sb.Append("- No handoff file found.$nl") }
    else {
        foreach ($f in @(@('Entry', $Handoff.heading, 300), @('Next', $Handoff.next, 600), @('Safe to proceed', $Handoff.safe, 300),
                @('Owner', $Handoff.owner, 400), @('Did', $Handoff.did, 800))) {
            if ($f[1]) { [void]$sb.Append("- **$($f[0]):** $(Limit-Text $f[1] $f[2])$nl") }
        }
    }

    $item = Get-RoadmapItem $RoadmapPath $Handoff.label
    if ($item.Count) {
        [void]$sb.Append("$nl## Roadmap item $($Handoff.label) ($RoadmapFile)$nl$nl")
        [void]$sb.Append(($item -join $nl) + $nl)
    }

    $text = $sb.ToString()
    if ($text.Length -gt $MaxChars) {
        $marker = "$nl[brief truncated to $MaxChars chars]$nl"
        $text = $text.Substring(0, $MaxChars - $marker.Length) + $marker
    }
    return $text
}

# A usage-limit or overload result. The CLI puts the message in result/errors with subtype != success.
$rateLimitRx = '(?i)usage limit|rate.?limit|hit your limit|limit reached|out of (extra )?usage|resets? (at|in)\b|overloaded|\b429\b'

# --- loop --------------------------------------------------------------------

Write-LoopLog 'loop-start' ([ordered]@{
        project = $ProjectDir; prompt = $Prompt; permissionMode = $PermissionMode
        maxSessions = $MaxSessions; handoffFile = $HandoffFile
        untilDone = [bool]$UntilDone; maxCostUsd = $MaxCostUsd; maxTokens = $MaxTokens
        stallSessions = $StallSessions; maxConsecutiveFailures = $MaxConsecutiveFailures
        rateLimitWaitMinutes = $RateLimitWaitMinutes
        softLimit = $SoftLimit; hardLimit = $HardLimit; boundaryLimit = $BoundaryLimit; mcp = $mcpMode; hygieneHook = $hygieneMode
    })
$sessions = [System.Collections.Generic.List[object]]::new()
$stopReason = 'max-sessions'
$totalCost = 0.0
$totalTokens = [long]0
$consecutiveFailures = 0
$stallCount = 0
$rateWaits = 0
$prevBrief = Get-HandoffBrief $handoff
$roadmapPath = if ([IO.Path]::IsPathRooted($RoadmapFile)) { $RoadmapFile } else { Join-Path $ProjectDir $RoadmapFile }
$prevSessionHead = $null

for ($n = 1; $n -le $MaxSessions; $n++) {
    Remove-Item $flag -ErrorAction SilentlyContinue
    $env:AGENT_LOOP_SESSION = "$n"
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $log = Join-Path $runDir "$stamp-s$n.jsonl"
    $headBefore = Get-GitHead
    Write-Host "`n[$n/$MaxSessions] Fresh session -> $(Limit-Text $Prompt 90)" -ForegroundColor Cyan
    if ($prevBrief.exists -and $prevBrief.next) { Write-Host "  picking up: $(Limit-Text $prevBrief.next 110)" -ForegroundColor DarkGray }

    $briefArgs = @()
    $briefInfo = $null
    if (-not $NoBrief) {
        try {
            $briefText = New-SessionBrief $prevBrief $n $prevSessionHead $roadmapPath $BriefMaxChars
            $briefPath = Join-Path $runDir "$stamp-s$n-brief.md"
            $briefBytes = [Text.UTF8Encoding]::new($false).GetBytes($briefText)
            [IO.File]::WriteAllBytes($briefPath, $briefBytes)
            $briefArgs = @('--append-system-prompt-file', $briefPath)
            # sha of the exact bytes on disk, so two sessions' briefs can be compared without opening them
            $briefInfo = [ordered]@{
                chars = $briefText.Length
                sha   = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($briefBytes)).ToLowerInvariant()
                path  = $briefPath
            }
            Write-Host "  brief: $($briefText.Length) chars -> $briefPath" -ForegroundColor DarkGray
        }
        catch { Write-Warning "Session brief skipped: $($_.Exception.Message)" }
    }
    $prevSessionHead = $headBefore

    $global:LASTEXITCODE = 0
    $started = Get-Date
    $sessionId = $null
    $result = $null
    $denials = @()
    & $ClaudePath -p $Prompt --permission-mode $PermissionMode --output-format stream-json --verbose @mcpArgs --add-dir $hygieneDir @briefArgs @ExtraArgs |
        Tee-Object -FilePath $log |
        ForEach-Object {
            # A non-JSON line throws even under SilentlyContinue and would leave the previous $e in place
            try { $e = $_ | ConvertFrom-Json -ErrorAction Stop } catch { return }
            if ($e.type -eq 'system' -and $e.subtype -eq 'init') { $sessionId = $e.session_id }
            elseif ($e.type -eq 'assistant') {
                $e.message.content | Where-Object type -eq 'text' |
                    ForEach-Object {
                        Write-Host $_.text -ForegroundColor Gray
                        Write-LoopLog 'message' ([ordered]@{ session = $n; sessionId = $sessionId; text = $_.text })
                    }
                }
                elseif ($e.type -eq 'result') {
                    $result = $e
                    Write-Host ("Session end: {0} | turns {1} | `${2:N2} | {3} tokens" -f $e.subtype, $e.num_turns, $e.total_cost_usd, (Format-Tokens (Get-ResultTokens $e))) -ForegroundColor Yellow
                    $denied = @($e.permission_denials | Where-Object { $_ })
                    if ($denied.Count) {
                        Write-Host "Permission denials: $($denied.Count)" -ForegroundColor Red
                        $denials = @($denied | ForEach-Object {
                                $what = if ($_.tool_input.command) { $_.tool_input.command } else { $_.tool_input.file_path }
                                Write-Host ("  {0}: {1}" -f $_.tool_name, $what) -ForegroundColor Red
                                [ordered]@{ tool = $_.tool_name; input = $what }
                            })
                    }
                }
            }
    $exit = $LASTEXITCODE
    $ended = Get-Date

    if (Test-Path $handoff) { Copy-Item $handoff (Join-Path $runDir "$stamp-s$n-handoff.md") }
    $headAfter = Get-GitHead
    $brief = Get-HandoffBrief $handoff
    $tokens = Get-ResultTokens $result
    $startup = Get-StartupMetrics $log
    # B2: lint the handoff as this session left it; guardBlocked = the Stop guard blocked once on the lint
    $lintProblems = @(Test-HandoffEntry $handoff)
    $guardState = Join-Path $stateDir "$($sessionId ?? $result.session_id).json"
    $guardBlocked = $false
    if (Test-Path -LiteralPath $guardState) {
        try { $guardBlocked = [bool](Get-Content -LiteralPath $guardState -Raw | ConvertFrom-Json).lintBlocked }
        catch { Write-Verbose "guard state unreadable: $($_.Exception.Message)" }
    }
    $handoffLint = [ordered]@{ pass = $lintProblems.Count -eq 0; problems = $lintProblems; guardBlocked = $guardBlocked }
    $errText = if ($result) { "$($result.result) $(@($result.errors) -join ' ')" } else { '' }
    $rateLimited = $result -and ($result.is_error -or $result.subtype -ne 'success') -and $errText -match $rateLimitRx

    $outcome = if ($rateLimited) { 'rate-limited' }
    elseif ($exit -ne 0 -or -not $result) { 'failed' }
    elseif (Test-HandoffDone $brief) { 'done' }
    elseif (Test-Path $flag) { 'rotated' }
    else { 'finished' }
    # B3: the guard writes "<reason> <sessionId>" to rotate.flag; boundary = item closed above -BoundaryLimit
    $rotateReason = $null
    if ($outcome -eq 'rotated') {
        $flagText = ''
        try { $flagText = "$(Get-Content -LiteralPath $flag -Raw)".Trim() }
        catch { Write-Warning "rotate.flag unreadable, reason taken as context: $($_.Exception.Message)" }
        $rotateReason = if ($flagText -match '^boundary\b') { 'boundary' } else { 'context' }
    }

    $totalCost += [double]($result.total_cost_usd ?? 0)
    $totalTokens += $tokens

    # Progress = a new top entry that moved the roadmap pointer or landed a commit
    $newEntry = $brief.exists -and ($brief.heading -ne $prevBrief.heading -or $brief.did -ne $prevBrief.did)
    $sameLabel = $brief.label -and ($brief.label -eq $prevBrief.label)
    $committed = $headBefore -and $headAfter -and ($headBefore -ne $headAfter)
    $progressed = $newEntry -and (-not $sameLabel -or $committed)
    # A boundary rotation (B3) ends an item just like a finished session, so it gets the same stall and blocked
    # checks; otherwise a session that rewrites the handoff above the boundary without progress never stalls.
    $itemEnded = $outcome -eq 'finished' -or $rotateReason -eq 'boundary'
    if ($itemEnded) { if ($progressed) { $stallCount = 0 } else { $stallCount++ } }
    elseif ($outcome -in 'done', 'rotated') { $stallCount = 0 }
    $prevBrief = $brief

    $blocked = $UntilDone -and $itemEnded -and (
        ($brief.safe -match '^\s*no\b') -or ($StopOnOwnerItems -and -not (Test-OwnerNothing $brief.owner)))

    # Decide: keep going or stop, and say why in one line
    $go = $false
    $wait = 0.0
    switch ($outcome) {
        'rate-limited' {
            if ($RateLimitWaitMinutes -gt 0 -and $rateWaits -lt $MaxRateLimitWaits) {
                $rateWaits++; $go = $true; $wait = $RateLimitWaitMinutes
                $decision = "usage limit hit - waiting $RateLimitWaitMinutes min ($rateWaits/$MaxRateLimitWaits), then a new session"
            }
            else { $decision = 'usage limit hit - stopping' }
        }
        'failed' {
            $consecutiveFailures++
            if ($UntilDone -and $consecutiveFailures -lt $MaxConsecutiveFailures) {
                $go = $true; $decision = "session failed ($consecutiveFailures/$MaxConsecutiveFailures) - retrying with a fresh session"
            }
            else { $decision = "session failed (exit $exit, result event: $([bool]$result)) - stopping" }
        }
        'done' { $decision = 'handoff says DONE - stopping' }
        'rotated' {
            $consecutiveFailures = 0
            if ($rotateReason -ne 'boundary') { $go = $true; $decision = 'context limit hit - rotating to a fresh session' }
            elseif ($blocked) { $outcome = 'blocked'; $decision = 'item closed at the boundary, but the handoff says it cannot proceed - stopping for the owner' }
            elseif ($UntilDone -and $stallCount -ge $StallSessions) { $outcome = 'stalled'; $decision = "item boundary with no progress in $stallCount sessions - stopping" }
            else { $go = $true; $decision = 'item closed above the boundary limit - rotating to a fresh session' }
        }
        'finished' {
            $consecutiveFailures = 0
            if (-not $UntilDone) { $decision = 'session ended under the limit - task finished' }
            elseif ($blocked) { $outcome = 'blocked'; $decision = 'handoff says it cannot proceed - stopping for the owner' }
            elseif ($stallCount -ge $StallSessions) { $outcome = 'stalled'; $decision = "no progress in $stallCount sessions (same next item, no new commit) - stopping" }
            else { $go = $true; $decision = 'item finished under the limit - continuing (until-done)' }
        }
    }
    if ($go -and $MaxCostUsd -gt 0 -and $totalCost -ge $MaxCostUsd) { $go = $false; $stopReason = 'cost-cap'; $decision = ('cost cap reached (${0:N2} of ${1:N2}) - stopping' -f $totalCost, $MaxCostUsd) }
    elseif ($go -and $MaxTokens -gt 0 -and $totalTokens -ge $MaxTokens) { $go = $false; $stopReason = 'token-cap'; $decision = "token cap reached ($(Format-Tokens $totalTokens) of $(Format-Tokens $MaxTokens)) - stopping" }
    elseif ($go -and $n -ge $MaxSessions) { $decision += " - but session cap $MaxSessions reached" }
    elseif (-not $go) { $stopReason = $outcome }

    $row = [ordered]@{
        session      = $n
        sessionId    = $sessionId ?? $result.session_id
        start        = $started.ToString('o')
        end          = $ended.ToString('o')
        durationSec  = [math]::Round(($ended - $started).TotalSeconds, 1)
        outcome      = $outcome
        rotateReason = $rotateReason
        success      = $outcome -notin 'failed', 'rate-limited' -and $result.subtype -eq 'success' -and -not $result.is_error
        subtype      = $result.subtype
        exitCode     = $exit
        turns        = $result.num_turns
        costUsd      = $result.total_cost_usd
        tokens       = $tokens
        denials      = $denials
        rawLog       = $log
        decision     = $decision
        headBefore   = $headBefore
        headAfter    = $headAfter
        handoffEntry = $brief.heading
        handoffNext  = $brief.next
        handoffOwner = $brief.owner
        handoffSafe  = $brief.safe
        handoffLint  = $handoffLint
        startup      = $startup
        brief        = $briefInfo
    }
    Write-LoopLog 'session' $row
    $sessions.Add([pscustomobject]$row)

    # Per-session brief: what the session left behind and what the loop decided
    $tone = switch ($outcome) { 'done' { 'Green' } 'finished' { 'Green' } 'rotated' { 'Magenta' } 'failed' { 'Red' } 'rate-limited' { 'Yellow' } default { 'Yellow' } }
    Write-Host ''
    Write-Host ("-- Session $n brief ").PadRight(72, '-') -ForegroundColor Cyan
    Write-Host ("  {0,-9} {1}" -f 'Outcome', $outcome) -ForegroundColor $tone
    Write-Host ("  {0,-9} {1}" -f 'Decision', $decision) -ForegroundColor $tone
    if ($brief.exists) {
        Write-Host ("  {0,-9} {1}" -f 'Handoff', (Limit-Text $brief.heading 110))
        if ($brief.did) { Write-Host ("  {0,-9} {1}" -f 'Did', (Limit-Text $brief.did)) }
        if ($brief.next) { Write-Host ("  {0,-9} {1}" -f 'Next', (Limit-Text $brief.next)) }
        if ($brief.safe) { Write-Host ("  {0,-9} {1}" -f 'Safe', (Limit-Text $brief.safe 110)) }
        $ownerTone = if (Test-OwnerNothing $brief.owner) { 'DarkGray' } else { 'Yellow' }
        Write-Host ("  {0,-9} {1}" -f 'Owner', (Limit-Text ($brief.owner ? $brief.owner : 'nothing'))) -ForegroundColor $ownerTone
        if (-not $newEntry) { Write-Host '  (handoff entry unchanged by this session)' -ForegroundColor Yellow }
        $lintText = if ($handoffLint.pass) { 'pass' } else { Limit-Text ($lintProblems -join '; ') 110 }
        if ($guardBlocked) { $lintText += ' (guard blocked once)' }
        Write-Host ("  {0,-9} {1}" -f 'Lint', $lintText) -ForegroundColor ($handoffLint.pass ? 'DarkGray' : 'Yellow')
    }
    else { Write-Host '  Handoff   (none found)' -ForegroundColor Yellow }
    $commitNote = if ($committed) { "$headBefore -> $headAfter (new commit)" } elseif ($headAfter) { "$headAfter (unchanged)" } else { 'not a git repo' }
    Write-Host ("  {0,-9} {1}" -f 'Commit', $commitNote)
    Write-Host ("  {0,-9} {1}" -f 'Startup', (Format-Startup $startup)) -ForegroundColor DarkGray
    $budget = 'sessions {0}/{1} | cost ${2:N2}{3} | tokens {4}{5}' -f $n, $MaxSessions, $totalCost,
    ($MaxCostUsd -gt 0 ? ('/${0:N2}' -f $MaxCostUsd) : ''), (Format-Tokens $totalTokens),
    ($MaxTokens -gt 0 ? "/$(Format-Tokens $MaxTokens)" : '')
    if ($UntilDone) { $budget += " | idle $stallCount/$StallSessions" }
    Write-Host ("  {0,-9} {1}" -f 'Budget', $budget) -ForegroundColor DarkGray
    Write-Host ('-' * 72) -ForegroundColor Cyan

    if (-not $go) { break }
    if ($wait -gt 0) {
        $until = (Get-Date).AddMinutes($wait)
        Write-Host ("Sleeping until {0:HH:mm:ss} ..." -f $until) -ForegroundColor Yellow
        Start-Sleep -Seconds ([math]::Ceiling($wait * 60))
    }
}

Write-LoopLog 'loop-end' ([ordered]@{
        sessions     = $sessions.Count
        stopReason   = $stopReason
        totalTurns   = [int]($sessions | Measure-Object turns -Sum).Sum
        totalCostUsd = [math]::Round([double]$totalCost, 4)
        totalTokens  = $totalTokens
    })

Write-Host "`nRun $runId - stopped: $stopReason" -ForegroundColor Cyan
$sessions | Format-Table session, outcome, success, turns,
@{ n = 'cost'; e = { if ($null -ne $_.costUsd) { '${0:N2}' -f $_.costUsd } } },
@{ n = 'tokens'; e = { Format-Tokens $_.tokens } },
durationSec, @{ n = 'denials'; e = { @($_.denials).Count } },
@{ n = 'next'; e = { Limit-Text $_.handoffNext 60 } } -AutoSize | Out-Host
Write-Host ('Totals: {0} sessions | ${1:N2} | {2} tokens' -f $sessions.Count, $totalCost, (Format-Tokens $totalTokens)) -ForegroundColor DarkGray
Write-Host "Log: $LogPath" -ForegroundColor DarkGray
[Console]::OutputEncoding = $prevOutputEncoding
# Add-RunHandoffEntry.ps1 writes handoff-log.json next to the handoff file
$handoffLog = Join-Path (Split-Path $handoff -Parent) 'handoff-log.json'
if (-not $NoSummary -and $sessions.Count) {
    # One read-only call that turns the run into the report's summary panel; a failure never fails the loop
    Write-Host "`nSummarizing run $runId ($SummaryModel)..." -ForegroundColor Cyan
    try {
        & (Join-Path $PSScriptRoot 'Invoke-LoopSummary.ps1') -ProjectDir $ProjectDir -RunId $runId -LogPath $LogPath `
            -HandoffLogPath $handoffLog -ClaudePath $ClaudePath -Model $SummaryModel | Out-Null
    }
    catch { Write-Warning "Run summary not written: $($_.Exception.Message)" }
}
try {
    $report = & (Join-Path $PSScriptRoot 'New-AgentLoopReport.ps1') -LogPath $LogPath -HandoffLogPath $handoffLog
    Write-Host "Report: $($report.FullName)" -ForegroundColor DarkGray
}
catch { Write-Warning "Report not written: $($_.Exception.Message)" }

}
finally {
    # Leave the caller's shell as it was (Start-Agent runs this in-process), also after Ctrl+C
    foreach ($k in $envNames) { [Environment]::SetEnvironmentVariable($k, $envBackup[$k]) }
    [Console]::OutputEncoding = $prevOutputEncoding
}
