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
        $a = @{ ProjectDir = $dir; ClaudePath = $fake; NoSummary = $true; MaxSessions = 6 }
        foreach ($k in $sc.args.Keys) { $a[$k] = $sc.args[$k] }
        $out = & $loop @a *>&1 | Out-String
        if ($Show) { Write-Host "`n===== $name =====" -ForegroundColor White; Write-Host $out }
        $logPath = Join-Path $dir '.claude/state/agent-loop.log.jsonl'
        $lines = Get-Content $logPath | ForEach-Object { $_ | ConvertFrom-Json }
        $end = $lines | Where-Object type -eq 'loop-end' | Select-Object -Last 1
        $count = @($lines | Where-Object type -eq 'session').Count
        [pscustomobject]@{
            scenario = $name; expectStop = $sc.stop; stop = $end.stopReason; expectSessions = $sc.sessions; sessions = $count
            pass = ($end.stopReason -eq $sc.stop -and $count -eq $sc.sessions)
        }
    }
    finally { Pop-Location }
}
$results | Format-Table -AutoSize | Out-String | Write-Host
$failed = @($results | Where-Object { -not $_.pass }).Count
Write-Host ("{0} scenarios, {1} failed" -f @($results).Count, $failed) -ForegroundColor ($failed ? 'Red' : 'Green')
exit $failed
