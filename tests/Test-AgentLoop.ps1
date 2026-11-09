#Requires -Version 7
# Runs Start-AgentLoop.ps1 against the stand-in CLI (Fake-Claude.ps1) for each scenario and checks the
# loop-end stop reason and session count. Each scenario gets a throwaway git repo with a seeded handoff.
# Needs ~/.claude/scripts/Add-RunHandoffEntry.ps1 (the stand-in writes real handoff entries with it).
# Usage: pwsh -NoProfile -File tests\Test-AgentLoop.ps1 [-Only <name>] [-Show]   (exit code = failures)
param([string]$Only = '', [switch]$Show, [string]$WorkDir = (Join-Path ([IO.Path]::GetTempPath()) 'agent-loop-tests'))
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$loop = Join-Path (Split-Path $here -Parent) 'Start-AgentLoop.ps1'
$fake = Join-Path $here 'Fake-Claude.ps1'
$work = $WorkDir

$scenarios = [ordered]@{
    'default-finished'  = @{ args = @{}; steps = @(@{ label = 'A1'; commit = $true }); stop = 'finished'; sessions = 1 }
    'default-rotate'    = @{ args = @{}; steps = @(@{ label = 'A1'; rotate = $true }, @{ label = 'DONE'; next = 'DONE: all items closed' }); stop = 'done'; sessions = 2 }
    'untildone-happy'   = @{ args = @{ UntilDone = $true }; steps = @(@{ label = 'A1'; commit = $true }, @{ label = 'A2'; commit = $true }, @{ label = 'DONE'; next = 'DONE: roadmap complete' }); stop = 'done'; sessions = 3 }
    'untildone-stall'   = @{ args = @{ UntilDone = $true }; steps = @(@{ label = 'A1' }, @{ label = 'A1' }, @{ label = 'A1' }, @{ label = 'A1' }); stop = 'stalled'; sessions = 3 }
    'untildone-commit-same-label' = @{ args = @{ UntilDone = $true; StallSessions = 2 }; steps = @(@{ label = 'A1'; commit = $true }, @{ label = 'A1'; commit = $true }, @{ label = 'A1'; commit = $true }, @{ label = 'DONE'; next = 'DONE' }); stop = 'done'; sessions = 4 }
    'untildone-noentry' = @{ args = @{ UntilDone = $true }; steps = @(@{ noEntry = $true }, @{ noEntry = $true }, @{ noEntry = $true }); stop = 'stalled'; sessions = 2 }
    'untildone-blocked' = @{ args = @{ UntilDone = $true }; steps = @(@{ label = 'A1'; safe = 'no; waiting on five owner decisions'; owner = 'Decide the fuse value' }); stop = 'blocked'; sessions = 1 }
    'untildone-owner-parked' = @{ args = @{ UntilDone = $true }; steps = @(@{ label = 'A1'; owner = 'Decide the fuse value'; commit = $true }, @{ label = 'DONE'; next = 'DONE' }); stop = 'done'; sessions = 2 }
    'untildone-owner-stop' = @{ args = @{ UntilDone = $true; StopOnOwnerItems = $true }; steps = @(@{ label = 'A1'; owner = 'Decide the fuse value'; commit = $true }, @{ label = 'DONE' }); stop = 'blocked'; sessions = 1 }
    'untildone-costcap' = @{ args = @{ UntilDone = $true; MaxCostUsd = 5 }; steps = @(@{ label = 'A1'; cost = 3; commit = $true }, @{ label = 'A2'; cost = 3; commit = $true }, @{ label = 'A3'; commit = $true }); stop = 'cost-cap'; sessions = 2 }
    'untildone-tokencap' = @{ args = @{ UntilDone = $true; MaxTokens = 100000 }; steps = @(@{ label = 'A1'; tokens = 60000; commit = $true }, @{ label = 'A2'; tokens = 60000; commit = $true }, @{ label = 'A3'; commit = $true }); stop = 'token-cap'; sessions = 2 }
    'untildone-failures' = @{ args = @{ UntilDone = $true }; steps = @(@{ exit = 1 }, @{ exit = 1 }, @{ label = 'DONE' }); stop = 'failed'; sessions = 2 }
    'untildone-fail-then-ok' = @{ args = @{ UntilDone = $true }; steps = @(@{ exit = 1 }, @{ label = 'DONE'; next = 'DONE' }); stop = 'done'; sessions = 2 }
    'ratelimit-stop'    = @{ args = @{ UntilDone = $true }; steps = @(@{ error = 'rate' }, @{ label = 'DONE' }); stop = 'rate-limited'; sessions = 1 }
    'ratelimit-wait'    = @{ args = @{ UntilDone = $true; RateLimitWaitMinutes = 0.02 }; steps = @(@{ error = 'rate' }, @{ label = 'DONE'; next = 'DONE' }); stop = 'done'; sessions = 2 }
    'untildone-maxsessions' = @{ args = @{ UntilDone = $true; MaxSessions = 2 }; steps = @(@{ label = 'A1'; commit = $true }, @{ label = 'A2'; commit = $true }, @{ label = 'A3' }); stop = 'max-sessions'; sessions = 2 }
    # Startup defaults: no MCP servers, guard and hygiene budgets, hygiene hook on the repo handoff, metrics logged, env restored
    'startup-defaults'  = @{ args = @{}; steps = @(@{ label = 'A1'; startup = $true }); stop = 'finished'; sessions = 1
        check = {
            param($lines, $dir)
            $call = Get-Content (Join-Path $dir '.claude/state/fake-call-1.json') -Raw | ConvertFrom-Json
            $a = @($call.args)
            $st = ($lines | Where-Object type -eq 'session' | Select-Object -First 1).startup
            $map = Get-Content (Join-Path $dir '.claude/state/hygiene-map.json') -Raw | ConvertFrom-Json
            $mapTarget = @($map.PSObject.Properties)[0]
            @(
                if ($a -notcontains '--strict-mcp-config') { 'no --strict-mcp-config' }
                $mi = [array]::IndexOf($a, '--mcp-config')
                if ($mi -lt 0 -or -not (Test-Path $a[$mi + 1])) { 'no --mcp-config file' }
                elseif (@((Get-Content $a[$mi + 1] -Raw | ConvertFrom-Json).mcpServers.PSObject.Properties).Count -ne 0) { 'mcp config not empty' }
                if ($call.env.AGENT_LOOP_SOFT_TOKENS -ne '170000' -or $call.env.AGENT_LOOP_HARD_TOKENS -ne '190000') { "guard env $($call.env.AGENT_LOOP_SOFT_TOKENS)/$($call.env.AGENT_LOOP_HARD_TOKENS)" }
                if ($call.env.CLAUDE_HYGIENE_HANDOFF_MAX_AGE_DAYS -ne '0') { 'hygiene injection not disabled' }
                if ($call.env.CLAUDE_HYGIENE_HARD_TOKENS -ne '190000') { "hygiene hard $($call.env.CLAUDE_HYGIENE_HARD_TOKENS)" }
                if ($mapTarget.Value -ne (Join-Path $dir 'current-handoff.md')) { "hygiene map -> $($mapTarget.Value)" }
                if ($st.firstCallCtx -ne 30000) { "firstCallCtx $($st.firstCallCtx)" }
                if ($st.firstEditCall -ne 4 -or $st.ctxAtFirstEdit -ne 36000) { "first edit $($st.firstEditCall) @ $($st.ctxAtFirstEdit)" }
                if ($st.toolCalls -ne 4) { "toolCalls $($st.toolCalls) (subagent call counted?)" }
                if ($st.repeatedReads -ne 1) { "repeatedReads $($st.repeatedReads)" }
                if ($st.resultCharsBeforeEdit -ne 1503) { "resultCharsBeforeEdit $($st.resultCharsBeforeEdit)" }
                if ($st.mcpServers -ne 1 -or $st.tools -ne 4) { "init counts $($st.mcpServers)/$($st.tools)" }
                foreach ($k in 'AGENT_LOOP_SOFT_TOKENS', 'CLAUDE_HYGIENE_MAP', 'CLAUDE_HYGIENE_HANDOFF_MAX_AGE_DAYS', 'AGENT_LOOP_RUN_ID', 'TK_DISABLE') {
                    if ([Environment]::GetEnvironmentVariable($k)) { "$k leaked into the caller's shell" }
                }
            )
        }
    }
    # Opt-outs and custom limits: usual MCP servers, normal hygiene hook, limits passed through
    'startup-optout'    = @{ args = @{ KeepMcp = $true; KeepHygieneInjection = $true; SoftLimit = 150000; HardLimit = 175000 }; steps = @(@{ label = 'A1' }); stop = 'finished'; sessions = 1
        check = {
            param($lines, $dir)
            $call = Get-Content (Join-Path $dir '.claude/state/fake-call-1.json') -Raw | ConvertFrom-Json
            @(
                if (@($call.args) -contains '--strict-mcp-config') { '--strict-mcp-config passed with -KeepMcp' }
                if ($call.env.CLAUDE_HYGIENE_HANDOFF_MAX_AGE_DAYS -or $call.env.CLAUDE_HYGIENE_MAP) { 'hygiene env set with -KeepHygieneInjection' }
                if ($call.env.AGENT_LOOP_SOFT_TOKENS -ne '150000' -or $call.env.AGENT_LOOP_HARD_TOKENS -ne '175000') { "guard env $($call.env.AGENT_LOOP_SOFT_TOKENS)/$($call.env.AGENT_LOOP_HARD_TOKENS)" }
                $st = ($lines | Where-Object type -eq 'session' | Select-Object -First 1).startup
                if ($null -ne $st.firstCallCtx) { 'startup metrics invented for a log without usage' }
            )
        }
    }
    # -McpConfig: only that file's servers
    'startup-mcpconfig' = @{ args = @{ McpConfig = '<dir>/mcp.json' }; steps = @(@{ label = 'A1' }); stop = 'finished'; sessions = 1
        check = {
            param($lines, $dir)
            $a = @((Get-Content (Join-Path $dir '.claude/state/fake-call-1.json') -Raw | ConvertFrom-Json).args)
            $mi = [array]::IndexOf($a, '--mcp-config')
            @(if ($a -notcontains '--strict-mcp-config' -or $mi -lt 0 -or $a[$mi + 1] -ne (Join-Path $dir 'mcp.json')) { "mcp args: $($a -join ' ')" })
        }
    }
}

$results = foreach ($name in $scenarios.Keys) {
    if ($Only -and $name -ne $Only) { continue }
    $sc = $scenarios[$name]
    $dir = Join-Path $work $name
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Push-Location $dir
    try {
        git init -q 2>$null
        Set-Content 'current-handoff.md' "# Test — Current Handoff`n> Active operational context only. Newest entry first.`n`n## 2026-01-01 — seed entry (S0 next)`n`n- **Did:** seeded`n- **Verified:** n/a`n- **Progress:** skipped`n- **Safe to proceed:** yes`n- **Next:** item S0`n- **Owner:** nothing`n"
        git add -A 2>$null | Out-Null; git -c user.name=t -c user.email=t@t commit -q -m seed 2>$null | Out-Null
        $scenarioFile = Join-Path $dir 'scenario.json'
        $sc.steps | ConvertTo-Json -Depth 4 -AsArray | Set-Content $scenarioFile
        $env:FAKE_SCENARIO = $scenarioFile
        $env:FAKE_HANDOFF = Join-Path $dir 'current-handoff.md'
        Set-Content (Join-Path $dir 'mcp.json') '{ "mcpServers": { "postgresql": { "command": "x" } } }'
        $a = @{ ProjectDir = $dir; ClaudePath = $fake; NoSummary = $true; MaxSessions = 6 }
        foreach ($k in $sc.args.Keys) { $a[$k] = $sc.args[$k] -is [string] ? $sc.args[$k].Replace('<dir>', $dir) : $sc.args[$k] }
        $out = & $loop @a *>&1 | Out-String
        if ($Show) { Write-Host "`n===== $name =====" -ForegroundColor White; Write-Host $out }
        $logPath = Join-Path $dir '.claude/state/agent-loop.log.jsonl'
        $lines = Get-Content $logPath | ForEach-Object { $_ | ConvertFrom-Json }
        $end = $lines | Where-Object type -eq 'loop-end' | Select-Object -Last 1
        $count = @($lines | Where-Object type -eq 'session').Count
        $problems = if ($sc.check) { @(& $sc.check $lines $dir) } else { @() }
        [pscustomobject]@{
            scenario = $name; expectStop = $sc.stop; stop = $end.stopReason; expectSessions = $sc.sessions; sessions = $count
            pass = ($end.stopReason -eq $sc.stop -and $count -eq $sc.sessions -and $problems.Count -eq 0)
            problems = $problems -join '; '
        }
    }
    finally { Pop-Location }
}
$results | Format-Table -AutoSize | Out-String | Write-Host
$failed = @($results | Where-Object { -not $_.pass }).Count
Write-Host ("{0} scenarios, {1} failed" -f @($results).Count, $failed) -ForegroundColor ($failed ? 'Red' : 'Green')
exit $failed
