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

# Start clean: when this suite runs inside a loop session, the parent loop's env vars are inherited and the
# leak and opt-out checks would report them. This process is separate, so clearing them here touches nothing else.
Get-ChildItem env: | Where-Object Name -match '^(AGENT_LOOP_|CLAUDE_HYGIENE_)|^TK_DISABLE$' |
    ForEach-Object { [Environment]::SetEnvironmentVariable($_.Name, $null) }

# Checks one session's brief: the --append-system-prompt-file argument recorded by Fake-Claude and the `brief`
# field of the matching `session` log line (path = that file, sha/chars = its bytes). Returns the brief text in
# .text and problem strings in .problems.
function Test-SessionBrief($lines, [string]$dir, [int]$n, [int]$maxChars = 4000) {
    $a = @((Get-Content (Join-Path $dir ".claude/state/fake-call-$n.json") -Raw | ConvertFrom-Json).args)
    $bi = [array]::IndexOf($a, '--append-system-prompt-file')
    $lb = (@($lines | Where-Object type -eq 'session')[$n - 1]).brief
    $text = $null
    $problems = @(
        if ($a -contains '--append-system-prompt') { "s${n}: inline --append-system-prompt passed" }
        if ($bi -lt 0 -or $bi + 1 -ge $a.Count) { "s${n}: no --append-system-prompt-file argument" }
        elseif (-not (Test-Path -LiteralPath $a[$bi + 1])) { "s${n}: brief file $($a[$bi + 1]) missing" }
        elseif ($a[$bi + 1] -notmatch "-s$n-brief\.md$") { "s${n}: brief file name $($a[$bi + 1])" }
        if (-not $lb) { "s${n}: session line has no brief field" }
        else {
            if ($bi -ge 0 -and $lb.path -ne $a[$bi + 1]) { "s${n}: brief.path $($lb.path) is not the file passed to claude" }
            if ($lb.path -and (Test-Path -LiteralPath $lb.path)) {
                $bytes = [IO.File]::ReadAllBytes($lb.path)
                $text = [Text.Encoding]::UTF8.GetString($bytes)
                $sha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
                if ($lb.sha -ne $sha) { "s${n}: brief.sha $($lb.sha) does not match the file ($sha)" }
                if ($lb.chars -ne $text.Length) { "s${n}: brief.chars $($lb.chars) does not match the file ($($text.Length))" }
                if ($text.Length -gt $maxChars) { "s${n}: brief is $($text.Length) chars, over the $maxChars cap" }
            }
        }
    )
    [pscustomobject]@{ text = $text; sha = $lb.sha; problems = $problems }
}

# Roadmap seeded by the brief scenarios: the seed handoff's label (S0) and the label session 1 writes (A1).
$briefRoadmap = @'
# Test — Roadmap

## Release 0.1 — Seed release

- [ ] [[S0]] Seed item S0 for the brief test.
      `check: seed-check-S0`
- [ ] [[A1]] Item A1 for the brief test.
      `check: seed-check-A1`
'@

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
                if ($st.firstCallCacheRead -ne 23990 -or $st.firstCallCacheCreation -ne 6000) { "first-call cache split $($st.firstCallCacheRead)/$($st.firstCallCacheCreation)" }
                if ($st.firstEditCall -ne 4 -or $st.ctxAtFirstEdit -ne 36000) { "first edit $($st.firstEditCall) @ $($st.ctxAtFirstEdit)" }
                if ($st.toolCalls -ne 4) { "toolCalls $($st.toolCalls) (subagent call counted?)" }
                if ($st.repeatedReads -ne 1) { "repeatedReads $($st.repeatedReads)" }
                if ($st.resultCharsBeforeEdit -ne 1503) { "resultCharsBeforeEdit $($st.resultCharsBeforeEdit)" }
                if ($st.mcpServers -ne 1 -or $st.tools -ne 4) { "init counts $($st.mcpServers)/$($st.tools)" }
                $b = Test-SessionBrief $lines $dir 1
                $b.problems
                if ($b.text -and $b.text -notmatch '(?s)# Loop brief \(session 1\).*## Git.*## Handoff top entry') { 'brief missing its sections' }
                foreach ($k in 'AGENT_LOOP_SOFT_TOKENS', 'CLAUDE_HYGIENE_MAP', 'CLAUDE_HYGIENE_HANDOFF_MAX_AGE_DAYS', 'AGENT_LOOP_RUN_ID', 'TK_DISABLE') {
                    if ([Environment]::GetEnvironmentVariable($k)) { "$k leaked into the caller's shell" }
                }
            )
        }
    }
    # Opt-outs and custom limits: usual MCP servers, normal hygiene hook, limits passed through
    'startup-optout'    = @{ args = @{ KeepMcp = $true; KeepHygieneInjection = $true; NoBrief = $true; SoftLimit = 150000; HardLimit = 175000 }; steps = @(@{ label = 'A1' }); stop = 'finished'; sessions = 1
        check = {
            param($lines, $dir)
            $call = Get-Content (Join-Path $dir '.claude/state/fake-call-1.json') -Raw | ConvertFrom-Json
            @(
                if (@($call.args) -contains '--append-system-prompt-file') { 'brief passed with -NoBrief' }
                if (@($call.args) -contains '--strict-mcp-config') { '--strict-mcp-config passed with -KeepMcp' }
                if ($call.env.CLAUDE_HYGIENE_HANDOFF_MAX_AGE_DAYS -or $call.env.CLAUDE_HYGIENE_MAP) { 'hygiene env set with -KeepHygieneInjection' }
                if ($call.env.AGENT_LOOP_SOFT_TOKENS -ne '150000' -or $call.env.AGENT_LOOP_HARD_TOKENS -ne '175000') { "guard env $($call.env.AGENT_LOOP_SOFT_TOKENS)/$($call.env.AGENT_LOOP_HARD_TOKENS)" }
                $st = ($lines | Where-Object type -eq 'session' | Select-Object -First 1).startup
                if ($null -ne $st.firstCallCtx -or $null -ne $st.firstCallCacheRead) { 'startup metrics invented for a log without usage' }
                if ($null -ne ($lines | Where-Object type -eq 'session' | Select-Object -First 1).brief) { 'brief logged with -NoBrief' }
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
    # A6: a brief per session, built from the handoff and roadmap as they stand before that session
    'brief-injected'    = @{ args = @{}; setup = { param($dir) Set-Content (Join-Path $dir 'ROADMAP.md') $briefRoadmap }
        steps = @(@{ label = 'A1'; rotate = $true; commit = $true }, @{ label = 'DONE'; next = 'DONE: all items closed' }); stop = 'done'; sessions = 2
        check = {
            param($lines, $dir)
            $b1 = Test-SessionBrief $lines $dir 1
            $b2 = Test-SessionBrief $lines $dir 2
            $t1 = $b1.text ?? ''; $t2 = $b2.text ?? ''
            @(
                $b1.problems; $b2.problems
                if ($b1.text -and $b2.text) {
                    if ($t1 -notmatch '# Loop brief \(session 1\)') { 's1: wrong session header' }
                    if ($t1 -notmatch '(?s)## Git.*Recent commits:.*seed.*Working tree: \d+ changed.*scenario\.json') { 's1: git section lacks recent commits or working tree' }
                    if ($t1 -notmatch '(?s)## Handoff top entry.*\*\*Entry:\*\* .*seed entry \(S0 next\).*\*\*Next:\*\* item S0') { 's1: handoff section is not the seed entry' }
                    if ($t1 -notmatch '(?s)## Roadmap item S0.*## Release 0\.1 — Seed release.*\[\[S0\]\] Seed item S0.*seed-check-S0') { 's1: roadmap item S0 missing' }
                    if ($t1 -match '\[\[A1\]\]') { 's1: brief carries roadmap item A1, which no entry named yet' }
                    if ($t2 -notmatch '# Loop brief \(session 2\)') { 's2: wrong session header' }
                    if ($t2 -notmatch '(?s)Commits since the previous session started.*step 1') { 's2: commit made by session 1 not listed' }
                    if ($t2 -notmatch '(?s)\*\*Entry:\*\* .*fake step 1.*\*\*Next:\*\* item A1') { 's2: handoff section is not the entry session 1 wrote' }
                    if ($t2 -notmatch '(?s)## Roadmap item A1.*\[\[A1\]\] Item A1.*seed-check-A1') { 's2: roadmap item A1 missing' }
                    if ($t2 -match '\[\[S0\]\]') { 's2: brief still carries roadmap item S0' }
                    if ($b1.sha -eq $b2.sha) { 'both sessions logged the same brief sha' }
                }
            )
        }
    }
    # A6: -BriefMaxChars cuts from the end (the roadmap part) and marks the cut
    'brief-capped'      = @{ args = @{ BriefMaxChars = 600 }; setup = { param($dir) Set-Content (Join-Path $dir 'ROADMAP.md') $briefRoadmap }
        steps = @(@{ label = 'A1' }); stop = 'finished'; sessions = 1
        check = {
            param($lines, $dir)
            $b = Test-SessionBrief $lines $dir 1 600
            @(
                $b.problems
                if ($b.text) {
                    if ($b.text.Length -ne 600) { "capped brief is $($b.text.Length) chars, expected 600" }
                    if ($b.text -notmatch '\[brief truncated to 600 chars\]\s*$') { 'no truncation marker at the end' }
                    if ($b.text -notmatch '^# Loop brief \(session 1\)') { 'cap cut the header' }
                    if ($b.text -match 'seed-check-S0') { 'roadmap tail survived a 600-char cap' }
                }
            )
        }
    }
    # A6: -NoBrief passes no brief argument, writes no brief file and logs brief = null; other defaults stay on
    'brief-optout'      = @{ args = @{ NoBrief = $true }; setup = { param($dir) Set-Content (Join-Path $dir 'ROADMAP.md') $briefRoadmap }
        steps = @(@{ label = 'A1'; rotate = $true }, @{ label = 'DONE'; next = 'DONE' }); stop = 'done'; sessions = 2
        check = {
            param($lines, $dir)
            $sessionLines = @($lines | Where-Object type -eq 'session')
            @(
                foreach ($n in 1, 2) {
                    $a = @((Get-Content (Join-Path $dir ".claude/state/fake-call-$n.json") -Raw | ConvertFrom-Json).args)
                    if ($a -match '^--append-system-prompt') { "s${n}: brief argument passed with -NoBrief: $($a -match '^--append-system-prompt')" }
                    if ($a -notcontains '--strict-mcp-config') { "s${n}: -NoBrief also dropped --strict-mcp-config" }
                    $sl = $sessionLines[$n - 1]
                    if ($sl -and -not $sl.PSObject.Properties['brief']) { "s${n}: session line has no brief key" }
                    elseif ($sl -and $null -ne $sl.brief) { "s${n}: brief logged with -NoBrief" }
                }
                $files = @(Get-ChildItem (Join-Path $dir '.claude/state/runs') -Filter '*-brief.md' -ErrorAction Ignore)
                if ($files.Count) { "brief files written with -NoBrief: $($files.Name -join ', ')" }
            )
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
        if ($sc.setup) { & $sc.setup $dir }   # extra seeded files, committed with the seed so the tree starts clean
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
# Direct guard checks (no loop): the Stop branch blocks a stale handoff only inside a loop run.
$guard = Join-Path (Split-Path $here -Parent) 'context-guard.ps1'
$guardCases = [ordered]@{
    'guard-stop-outside-loop' = @{ runId = $null; expectBlock = $false }
    'guard-stop-in-loop'      = @{ runId = 'test-run'; expectBlock = $true }
}
$results = @($results) + @(foreach ($name in $guardCases.Keys) {
    if ($Only -and $name -ne $Only) { continue }
    $gc = $guardCases[$name]
    $dir = Join-Path $work $name
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null   # no handoff file, so it is never fresh
    $payload = @{ session_id = 'guard-test'; cwd = $dir; stop_hook_active = $false } | ConvertTo-Json -Compress
    $saved = @{ AGENT_LOOP_RUN_ID = $env:AGENT_LOOP_RUN_ID; CLAUDE_PROJECT_DIR = $env:CLAUDE_PROJECT_DIR }
    try {
        $env:AGENT_LOOP_RUN_ID = $gc.runId; $env:CLAUDE_PROJECT_DIR = $dir
        $out = ($payload | pwsh -NoProfile -File $guard -Event Stop 2>&1 | Out-String).Trim()
    }
    finally { foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }
    $blocked = $out -match '"decision"\s*:\s*"block"'
    $problems = @(
        if ($blocked -ne $gc.expectBlock) { "blocked=$blocked, output: $out" }
        elseif (-not $gc.expectBlock -and $out) { "unexpected output: $out" }
    )
    [pscustomobject]@{
        scenario = $name; expectStop = $(if ($gc.expectBlock) { 'block' } else { 'allow' }); stop = $(if ($blocked) { 'block' } else { 'allow' })
        expectSessions = 0; sessions = 0; pass = ($problems.Count -eq 0); problems = $problems -join '; '
    }
})
# Direct Test-HandoffEntry checks (B1): exact problem lists for each handoff shape.
. (Join-Path (Split-Path $here -Parent) 'Resolve-HandoffFile.ps1')
$hdr = "# Test — Current Handoff`n> Active operational context only. Newest entry first.`n`n"
function New-Entry([string]$Next, [string]$Verified, [string]$Safe, [string]$Label = 'B1') {
    $l = @("## 2026-01-02 — lint case ($Label next)", '', '- **Did:** something')
    if ($null -ne $Verified) { $l += "- **Verified:** $Verified" }
    if ($null -ne $Safe) { $l += "- **Safe to proceed:** $Safe" }
    if ($null -ne $Next) { $l += "- **Next:** $Next" }
    $l += '- **Owner:** nothing'
    ($l -join "`n") + "`n`n## 2026-01-01 — older entry (A1 next)`n`n- **Verified:** n/a`n- **Safe to proceed:** maybe`n- **Next:** later`n"
}
$lintCases = [ordered]@{
    'lint-pass'        = @{ text = $hdr + (New-Entry 'B2: wire the lint into context-guard.ps1' 'pwsh -NoProfile -File tests/Test-AgentLoop.ps1: 0 failed' 'yes; clean tree'); expect = @() }
    'lint-pass-forms'  = @{ text = $hdr + (New-Entry 'run `npm test` again' 'ran `make check`, ok' 'No; owner gate'); expect = @() }
    'lint-pass-done'   = @{ text = $hdr + (New-Entry 'DONE: roadmap finished' 'Invoke-RoadmapValidation exit 0' 'yes' 'DONE'); expect = @() }
    'lint-vague'       = @{ text = $hdr + (New-Entry 'keep going with the rest' 'looked fine to me' 'probably'); expect = @('Next names no file, command or item ID', 'Verified names no command', 'Safe to proceed does not start with yes or no') }
    'lint-missing'     = @{ text = $hdr + (New-Entry $null $null $null); expect = @('Next is missing or empty', 'Verified is missing or empty', 'Safe to proceed is missing or empty') }
    'lint-empty-next'  = @{ text = $hdr + (New-Entry '' 'git status: clean' 'yes'); expect = @('Next is missing or empty') }
    'lint-not-entry'   = @{ text = "# Handoff: something`n`n## Status`n`ndone`n`n## Next action`n`nB1`n"; expect = @('no top entry in the "## YYYY-MM-DD — summary (label next)" shape') }
    'lint-no-file'     = @{ text = $null; expect = @('handoff file not found: <path>') }
}
$results = @($results) + @(foreach ($name in $lintCases.Keys) {
    if ($Only -and $name -ne $Only) { continue }
    $lc = $lintCases[$name]
    $dir = Join-Path $work $name
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $path = Join-Path $dir 'current-handoff.md'
    if ($null -ne $lc.text) { [IO.File]::WriteAllText($path, $lc.text) }
    $got = @(Test-HandoffEntry $path)
    $want = @($lc.expect | ForEach-Object { $_.Replace('<path>', $path) })
    $problems = @(if (($got -join '|') -cne ($want -join '|')) { "got [$($got -join '; ')], want [$($want -join '; ')]" })
    [pscustomobject]@{
        scenario = $name; expectStop = "$($want.Count) problems"; stop = "$($got.Count) problems"
        expectSessions = 0; sessions = 0; pass = ($problems.Count -eq 0); problems = $problems -join '; '
    }
})
$results | Format-Table -AutoSize | Out-String | Write-Host
$failed = @($results | Where-Object { -not $_.pass }).Count
Write-Host ("{0} scenarios, {1} failed" -f @($results).Count, $failed) -ForegroundColor ($failed ? 'Red' : 'Green')
exit $failed
