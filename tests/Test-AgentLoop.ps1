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
    'default-rotate'    = @{ args = @{}; steps = @(@{ label = 'A1'; rotate = $true }, @{ label = 'DONE'; next = 'DONE: all items closed' }); stop = 'done'; sessions = 2
        check = {
            param($lines, $dir)
            $s = @($lines | Where-Object type -eq 'session')
            @(
                if ($s[0].rotateReason -ne 'soft-limit') { "s1 rotateReason '$($s[0].rotateReason)', expected soft-limit" }
                if ($s[0].rotateTokens -ne 180000) { "s1 rotateTokens '$($s[0].rotateTokens)', expected 180000" }
                if ($s[0].decision -notmatch 'soft limit') { "s1 decision does not name the soft limit: $($s[0].decision)" }
                if ($null -ne $s[1].rotateReason) { "s2 rotateReason '$($s[1].rotateReason)' on a session that did not rotate" }
            )
        }
    }
    # B3: the guard's "boundary" flag reason reaches the session line and the decision; -BoundaryLimit reaches the env
    'boundary-rotate'   = @{ args = @{ BoundaryLimit = 90000 }; steps = @(@{ label = 'A1'; rotate = 'boundary'; commit = $true }, @{ label = 'DONE'; next = 'DONE: all items closed' }); stop = 'done'; sessions = 2
        check = {
            param($lines, $dir)
            $s1 = @($lines | Where-Object type -eq 'session')[0]
            $start = $lines | Where-Object type -eq 'loop-start' | Select-Object -First 1
            $call = Get-Content (Join-Path $dir '.claude/state/fake-call-1.json') -Raw | ConvertFrom-Json
            @(
                if ($s1.rotateReason -ne 'boundary') { "s1 rotateReason '$($s1.rotateReason)', expected boundary" }
                if ($s1.decision -notmatch 'boundary') { "s1 decision does not mention the boundary: $($s1.decision)" }
                if ($start.boundaryLimit -ne 90000) { "loop-start boundaryLimit $($start.boundaryLimit)" }
                if ($call.env.AGENT_LOOP_BOUNDARY_TOKENS -ne '90000') { "guard env AGENT_LOOP_BOUNDARY_TOKENS '$($call.env.AGENT_LOOP_BOUNDARY_TOKENS)'" }
                if ($env:AGENT_LOOP_BOUNDARY_TOKENS) { 'AGENT_LOOP_BOUNDARY_TOKENS leaked into the shell' }
            )
        }
    }
    # B4: the hard-limit reason reaches the session line; a pre-B4 plain-text flag still parses
    'hardlimit-rotate'  = @{ args = @{}; steps = @(@{ label = 'A1'; rotate = 'hard-limit' }, @{ label = 'DONE'; next = 'DONE: all items closed' }); stop = 'done'; sessions = 2
        check = {
            param($lines, $dir)
            $s1 = @($lines | Where-Object type -eq 'session')[0]
            @(
                if ($s1.rotateReason -ne 'hard-limit') { "s1 rotateReason '$($s1.rotateReason)', expected hard-limit" }
                if ($s1.decision -notmatch 'hard limit') { "s1 decision does not name the hard limit: $($s1.decision)" }
            )
        }
    }
    'legacy-flag'       = @{ args = @{}; steps = @(@{ label = 'A1'; rotate = 'legacy-boundary' }, @{ label = 'A2'; rotate = 'legacy' }, @{ label = 'DONE'; next = 'DONE' }); stop = 'done'; sessions = 3
        check = {
            param($lines, $dir)
            $s = @($lines | Where-Object type -eq 'session')
            @(
                if ($s[0].rotateReason -ne 'boundary') { "s1 rotateReason '$($s[0].rotateReason)', expected boundary from 'boundary <id>'" }
                if ($s[1].rotateReason -ne 'soft-limit') { "s2 rotateReason '$($s[1].rotateReason)', expected soft-limit from an unparseable flag" }
                if ($null -ne $s[1].rotateTokens) { "s2 rotateTokens '$($s[1].rotateTokens)', expected null" }
            )
        }
    }
    'untildone-happy'   = @{ args = @{ UntilDone = $true }; steps = @(@{ label = 'A1'; commit = $true }, @{ label = 'A2'; commit = $true }, @{ label = 'DONE'; next = 'DONE: roadmap complete' }); stop = 'done'; sessions = 3 }
    'untildone-stall'   = @{ args = @{ UntilDone = $true }; steps = @(@{ label = 'A1' }, @{ label = 'A1' }, @{ label = 'A1' }, @{ label = 'A1' }); stop = 'stalled'; sessions = 3 }
    # B3: a boundary rotation ends an item, so until-done applies the same stall and blocked checks to it
    'boundary-stall'    = @{ args = @{ UntilDone = $true }; steps = @(@{ label = 'A1'; rotate = 'boundary' }, @{ label = 'A1'; rotate = 'boundary' }, @{ label = 'A1'; rotate = 'boundary' }, @{ label = 'A1'; rotate = 'boundary' }); stop = 'stalled'; sessions = 3 }
    'boundary-blocked'  = @{ args = @{ UntilDone = $true }; steps = @(@{ label = 'A1'; rotate = 'boundary'; safe = 'no; needs the owner' }, @{ label = 'DONE'; next = 'DONE' }); stop = 'blocked'; sessions = 1 }
    'untildone-commit-same-label' = @{ args = @{ UntilDone = $true; StallSessions = 2 }; steps = @(@{ label = 'A1'; commit = $true }, @{ label = 'A1'; commit = $true }, @{ label = 'A1'; commit = $true }, @{ label = 'DONE'; next = 'DONE' }); stop = 'done'; sessions = 4 }
    'untildone-noentry' = @{ args = @{ UntilDone = $true }; steps = @(@{ noEntry = $true }, @{ noEntry = $true }, @{ noEntry = $true }); stop = 'stalled'; sessions = 2 }
    'untildone-blocked' = @{ args = @{ UntilDone = $true }; steps = @(@{ label = 'A1'; safe = 'no; waiting on five owner decisions'; owner = 'Decide the fuse value' }); stop = 'blocked'; sessions = 1 }
    'untildone-owner-parked' = @{ args = @{ UntilDone = $true }; steps = @(@{ label = 'A1'; owner = 'Decide the fuse value'; commit = $true }, @{ label = 'DONE'; next = 'DONE' }); stop = 'done'; sessions = 2 }
    'untildone-owner-stop' = @{ args = @{ UntilDone = $true; StopOnOwnerItems = $true }; steps = @(@{ label = 'A1'; owner = 'Decide the fuse value'; commit = $true }, @{ label = 'DONE' }); stop = 'blocked'; sessions = 1 }
    'untildone-costcap' = @{ args = @{ UntilDone = $true; MaxCostUsd = 5 }; steps = @(@{ label = 'A1'; cost = 3; commit = $true }, @{ label = 'A2'; cost = 3; commit = $true }, @{ label = 'A3'; commit = $true }); stop = 'cost-cap'; sessions = 2 }
    'untildone-tokencap' = @{ args = @{ UntilDone = $true; MaxTokens = 100000 }; steps = @(@{ label = 'A1'; tokens = 60000; commit = $true }, @{ label = 'A2'; tokens = 60000; commit = $true }, @{ label = 'A3'; commit = $true }); stop = 'token-cap'; sessions = 2 }
    # X2: two result events in one session; turns and tokens are summed (37+5, 400000+53500), cost is the last
    # (cumulative) one, and the summed tokens trip -MaxTokens that the last segment alone would not
    'multi-result'      = @{ args = @{ UntilDone = $true; MaxTokens = 300000 }
        steps = @(@{ label = 'A1'; commit = $true; cost = 1.78; extraResult = @{ turns = 37; tokens = 400000; cost = 0.9 }; verified = 'pwsh -NoProfile -File tests/x.ps1: ok' },
            @{ label = 'A2'; commit = $true; verified = 'pwsh -NoProfile -File tests/x.ps1: ok' })
        stop = 'token-cap'; sessions = 1
        check = {
            param($lines, $dir)
            $s = @($lines | Where-Object type -eq 'session')[0]
            $end = @($lines | Where-Object type -eq 'loop-end')[0]
            @(
                if ($s.turns -ne 42) { "turns $($s.turns), expected 42 (37 + 5)" }
                if ($s.tokens -ne 453500) { "tokens $($s.tokens), expected 453500 (400000 + 53500)" }
                if ($s.costUsd -ne 1.78) { "costUsd $($s.costUsd), expected 1.78 (last, cumulative)" }
                if ($s.resultEvents -ne 2) { "resultEvents $($s.resultEvents), expected 2" }
                if ($null -ne $s.repair) { 'a repair ran on a passing entry' }
                if ($end.totalCostUsd -ne 1.78) { "loop-end totalCostUsd $($end.totalCostUsd), expected 1.78" }
                if ($end.totalTurns -ne 42) { "loop-end totalTurns $($end.totalTurns), expected 42" }
            )
        }
    }
    'untildone-failures' = @{ args = @{ UntilDone = $true }; steps = @(@{ exit = 1 }, @{ exit = 1 }, @{ label = 'DONE' }); stop = 'failed'; sessions = 2 }
    'untildone-fail-then-ok' = @{ args = @{ UntilDone = $true }; steps = @(@{ exit = 1 }, @{ label = 'DONE'; next = 'DONE' }); stop = 'done'; sessions = 2 }
    'ratelimit-stop'    = @{ args = @{ UntilDone = $true }; steps = @(@{ error = 'rate'; repair = 'entry' }, @{ label = 'DONE' }); stop = 'rate-limited'; sessions = 1
        check = { param($lines, $dir) @(if (@($lines | Where-Object type -eq 'repair').Count) { 'repair attempted after a usage limit (B5)' }) }
    }
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
                $c1 = Get-Content (Join-Path $dir '.claude/state/fake-call-1.json') -Raw | ConvertFrom-Json
                if ($c1.env.AGENT_LOOP_BOUNDARY_TOKENS -ne '100000') { "default AGENT_LOOP_BOUNDARY_TOKENS '$($c1.env.AGENT_LOOP_BOUNDARY_TOKENS)', expected 100000" }
                foreach ($k in 'AGENT_LOOP_SOFT_TOKENS', 'AGENT_LOOP_BOUNDARY_TOKENS', 'CLAUDE_HYGIENE_MAP', 'CLAUDE_HYGIENE_HANDOFF_MAX_AGE_DAYS', 'AGENT_LOOP_RUN_ID', 'TK_DISABLE') {
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
    # B2: every session line carries handoffLint { pass, problems, guardBlocked } for the handoff it left
    'lint-logged'       = @{ args = @{}
        steps = @(@{ label = 'A1'; rotate = $true; verified = 'pwsh -NoProfile -File tests/x.ps1: ok' },
            @{ label = 'DONE'; next = 'keep going'; guardBlocked = $true }); stop = 'done'; sessions = 2
        check = {
            param($lines, $dir)
            $sl = @($lines | Where-Object type -eq 'session')
            $l1 = $sl[0].handoffLint; $l2 = $sl[1].handoffLint
            $want2 = 'Next names no file, command or item ID|Verified names no command'
            @(
                if (-not $l1) { 's1: no handoffLint' }
                elseif (-not $l1.pass -or @($l1.problems).Count -or $l1.guardBlocked) { "s1: expected a clean pass, got $($l1 | ConvertTo-Json -Compress)" }
                if (-not $l2) { 's2: no handoffLint' }
                elseif ($l2.pass -or (@($l2.problems) -join '|') -cne $want2 -or -not $l2.guardBlocked) { "s2: expected 2 problems and guardBlocked, got $($l2 | ConvertTo-Json -Compress)" }
            )
        }
    }
    # B5: a session with no new entry is resumed once (same session id, --max-turns 5, the session's own brief and MCP
    # args); the repaired entry counts for the session, its cost and tokens reach the totals, and a flag the repair
    # writes does not turn a finished session into a rotation. The DONE session is not repaired.
    'repair-noentry'    = @{ args = @{ UntilDone = $true }
        steps = @(@{ noEntry = $true; repair = 'entry'; repairLabel = 'A2'; repairCost = 0.25; repairRotate = $true }, @{ label = 'DONE'; next = 'DONE: all items closed' })
        stop = 'done'; sessions = 2
        check = {
            param($lines, $dir)
            $rl = @($lines | Where-Object type -eq 'repair')
            $s = @($lines | Where-Object type -eq 'session')
            $end = $lines | Where-Object type -eq 'loop-end' | Select-Object -Last 1
            $ra = @((Get-Content (Join-Path $dir '.claude/state/fake-repair-1.json') -Raw | ConvertFrom-Json).args)
            $ca = @((Get-Content (Join-Path $dir '.claude/state/fake-call-1.json') -Raw | ConvertFrom-Json).args)
            $at = { param($a, $k) $i = [array]::IndexOf($a, $k); if ($i -ge 0 -and $i + 1 -lt $a.Count) { $a[$i + 1] } }
            @(
                if ($rl.Count -ne 1) { "expected 1 repair line, got $($rl.Count)" }
                else {
                    $r = $rl[0]
                    if ($r.session -ne 1 -or $r.sessionId -ne 'fake-1' -or $r.repairSessionId -ne 'fake-1') { "repair ids: session $($r.session), $($r.sessionId) -> $($r.repairSessionId)" }
                    if ($r.trigger -ne 'no-entry') { "trigger '$($r.trigger)', expected no-entry" }
                    if (-not $r.success -or -not $r.entryWritten -or -not $r.lintPass) { "repair result: $($r | ConvertTo-Json -Compress)" }
                    if ($r.costUsd -ne 0.25 -or $r.tokens -ne 5000 -or $r.turns -ne 2) { "repair cost/tokens/turns $($r.costUsd)/$($r.tokens)/$($r.turns)" }
                    if (-not (Test-Path -LiteralPath $r.rawLog) -or $r.rawLog -notmatch '-s1-repair\.jsonl$') { "repair rawLog $($r.rawLog)" }
                }
                if ((& $at $ra '--resume') -ne 'fake-1') { "--resume $(& $at $ra '--resume')" }
                if ((& $at $ra '--max-turns') -ne '5') { "--max-turns $(& $at $ra '--max-turns')" }
                if ((& $at $ra '-p') -notmatch '^HANDOFF REPAIR: .*no entry written.*Add-RunHandoffEntry\.ps1 -HandoffPath current-handoff\.md') { "repair prompt: $(& $at $ra '-p')" }
                if ((& $at $ra '-p') -match '"') { 'repair prompt has a double quote' }
                foreach ($k in '--append-system-prompt-file', '--mcp-config', '--permission-mode') {
                    if ((& $at $ra $k) -ne (& $at $ca $k)) { "repair $k '$(& $at $ra $k)' differs from the session's '$(& $at $ca $k)'" }
                }
                if ($s[0].outcome -ne 'finished' -or $null -ne $s[0].rotateReason) { "s1 outcome $($s[0].outcome)/$($s[0].rotateReason); the repair's flag leaked" }
                if (-not $s[0].handoffLint.pass) { "s1 handoffLint after repair: $($s[0].handoffLint | ConvertTo-Json -Compress)" }
                if ($s[0].handoffEntry -notmatch 'repair of step 1') { "s1 handoffEntry '$($s[0].handoffEntry)'" }
                if (-not $s[0].repair -or -not $s[0].repair.success -or $s[0].repair.trigger -ne 'no-entry') { "s1 session.repair $($s[0].repair | ConvertTo-Json -Compress)" }
                if ($null -ne $s[1].repair) { 's2 (DONE) has a repair' }
                if ([math]::Round($end.totalCostUsd, 2) -ne 2.25) { "totalCostUsd $($end.totalCostUsd), expected 2.25 (two sessions + repair)" }
                if ($end.totalTokens -ne 112000) { "totalTokens $($end.totalTokens), expected 112000" }
            )
        }
    }
    # B5: a new entry that fails the lint triggers a 'lint' repair; a failed repair call (exit 1) that leaves it failing is logged as such,
    # the rotation keeps its own reason, and a session whose entry passes is not repaired.
    'repair-lint'       = @{ args = @{}
        steps = @(@{ label = 'A1'; rotate = $true; repair = 'bad'; repairExit = 1 }, @{ label = 'A2'; verified = 'pwsh -NoProfile -File tests/x.ps1: ok' })
        stop = 'finished'; sessions = 2
        check = {
            param($lines, $dir)
            $rl = @($lines | Where-Object type -eq 'repair')
            $s = @($lines | Where-Object type -eq 'session')
            @(
                if ($rl.Count -ne 1) { "expected 1 repair line, got $($rl.Count)" }
                else {
                    $r = $rl[0]
                    if ($r.trigger -ne 'lint') { "trigger '$($r.trigger)', expected lint" }
                    if (@($r.problemsBefore) -notcontains 'Verified names no command') { "problemsBefore $(@($r.problemsBefore) -join '; ')" }
                    if (-not $r.entryWritten -or $r.lintPass -or @($r.problemsAfter).Count -eq 0) { "repair result: $($r | ConvertTo-Json -Compress)" }
                    if ($r.success -or $r.exitCode -ne 1) { "failed repair call logged as success $($r.success), exit $($r.exitCode)" }
                }
                $ra = @((Get-Content (Join-Path $dir '.claude/state/fake-repair-1.json') -Raw | ConvertFrom-Json).args)
                if (($ra -join ' ') -notmatch 'Verified names no command') { 'repair prompt does not list the lint problems' }
                if ($s[0].outcome -ne 'rotated' -or $s[0].rotateReason -ne 'soft-limit') { "s1 $($s[0].outcome)/$($s[0].rotateReason)" }
                if ($s[0].handoffLint.pass) { 's1 handoffLint passes after a bad repair' }
                if ($null -ne $s[1].repair -or (Test-Path (Join-Path $dir '.claude/state/fake-repair-2.json'))) { 's2 passed the lint but was repaired' }
            )
        }
    }
    'repair-optout'     = @{ args = @{ NoRepair = $true }; steps = @(@{ noEntry = $true; repair = 'entry' }); stop = 'finished'; sessions = 1
        check = {
            param($lines, $dir)
            @(
                if (@($lines | Where-Object type -eq 'repair').Count) { 'repair line with -NoRepair' }
                if (Test-Path (Join-Path $dir '.claude/state/fake-repair-1.json')) { 'claude --resume called with -NoRepair' }
                if (($lines | Where-Object type -eq 'loop-start').repair -ne $false) { 'loop-start.repair is not false' }
                if ($null -ne ($lines | Where-Object type -eq 'session').repair) { 'session.repair set with -NoRepair' }
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
# Direct guard checks (no loop): the Stop branch blocks a stale handoff only inside a loop run (A3), and
# blocks once on a fresh handoff that fails Test-HandoffEntry (B2). A case with `handoff` text writes that file
# after a guard state whose startedTicks = 0, so the handoff counts as written this session (`stale` puts
# startedTicks after the write instead). PostToolUse cases (B3) pass `tokens`, written as a one-line transcript,
# and check rotate.flag (`flag` = the reason its B4 JSON must carry, with sessionId guard-test and the tokens;
# no `flag` = no file) and the state's boundaryWarned. `warned` seeds the state's soft-limit warning.
$guard = Join-Path (Split-Path $here -Parent) 'context-guard.ps1'
$hGood = "# T`n`n## 2026-01-02 — good (B2 next)`n`n- **Verified:** pwsh -File tests/x.ps1: ok`n- **Safe to proceed:** yes`n- **Next:** B2 in context-guard.ps1`n"
$hBad = "# T`n`n## 2026-01-02 — bad (B2 next)`n`n- **Verified:** looked fine`n- **Safe to proceed:** probably`n- **Next:** carry on`n"
$guardCases = [ordered]@{
    'guard-stop-outside-loop'   = @{ runId = $null; expectBlock = $false }
    'guard-stop-in-loop'        = @{ runId = 'test-run'; expectBlock = $true; reason = '^Rule: update' }
    'guard-lint-pass'           = @{ runId = 'test-run'; handoff = $hGood; expectBlock = $false }
    'guard-lint-fail'           = @{ runId = 'test-run'; handoff = $hBad; expectBlock = $true; expectLintBlocked = $true
        reason = '^HANDOFF CHECK: .*Next names no file, command or item ID; Verified names no command; Safe to proceed does not start with yes or no' }
    'guard-lint-after-stale'    = @{ runId = 'test-run'; handoff = $hBad; stopActive = $true; expectBlock = $true; expectLintBlocked = $true; reason = '^HANDOFF CHECK' }
    'guard-lint-once'           = @{ runId = 'test-run'; handoff = $hBad; lintBlocked = $true; expectBlock = $false; expectLintBlocked = $true }
    'guard-lint-hygiene-shape'  = @{ runId = 'test-run'; handoff = "# Handoff: x`n`n## Status`n`ndone`n"; expectBlock = $false }
    'guard-lint-outside-loop'   = @{ runId = $null; handoff = $hBad; expectBlock = $false }
    'guard-boundary-fires'      = @{ event = 'PostToolUse'; runId = 'test-run'; handoff = $hGood; tokens = 120000; expectBlock = $true
        reason = '^ITEM BOUNDARY: .*~120k tokens \(boundary 100k\)'; flag = 'boundary'; expectBoundaryWarned = $true }
    'guard-boundary-under'      = @{ event = 'PostToolUse'; runId = 'test-run'; handoff = $hGood; tokens = 90000; expectBlock = $false }
    'guard-boundary-stale'      = @{ event = 'PostToolUse'; runId = 'test-run'; handoff = $hGood; stale = $true; tokens = 120000; expectBlock = $false }
    'guard-boundary-once'       = @{ event = 'PostToolUse'; runId = 'test-run'; handoff = $hGood; boundaryWarned = $true; tokens = 130000; expectBlock = $false; expectBoundaryWarned = $true }
    'guard-boundary-outside'    = @{ event = 'PostToolUse'; runId = $null; handoff = $hGood; tokens = 120000; expectBlock = $false }
    'guard-boundary-off'        = @{ event = 'PostToolUse'; runId = 'test-run'; handoff = $hGood; boundaryEnv = '0'; tokens = 120000; expectBlock = $false }
    'guard-boundary-env'        = @{ event = 'PostToolUse'; runId = 'test-run'; handoff = $hGood; boundaryEnv = '50000'; tokens = 60000; expectBlock = $true
        reason = '\(boundary 50k\)'; flag = 'boundary'; expectBoundaryWarned = $true }
    'guard-boundary-soft-wins'  = @{ event = 'PostToolUse'; runId = 'test-run'; handoff = $hGood; tokens = 175000; expectBlock = $true
        reason = '^CONTEXT ROTATION'; flag = 'soft-limit' }
    # B4: soft limit warns once but rewrites the flag on every call; past the hard limit it warns every call, reason hard-limit
    'guard-soft-limit'          = @{ event = 'PostToolUse'; runId = 'test-run'; tokens = 175000; expectBlock = $true; reason = '^CONTEXT ROTATION: ~175k'; flag = 'soft-limit' }
    'guard-soft-warned'         = @{ event = 'PostToolUse'; runId = 'test-run'; handoff = $hGood; warned = $true; tokens = 180000; expectBlock = $false; flag = 'soft-limit' }
    'guard-hard-limit'          = @{ event = 'PostToolUse'; runId = 'test-run'; handoff = $hGood; warned = $true; tokens = 195000; expectBlock = $true; reason = '^CONTEXT ROTATION: ~195k'; flag = 'hard-limit' }
    'guard-hard-outside-loop'   = @{ event = 'PostToolUse'; runId = $null; tokens = 195000; expectBlock = $true; reason = '^CONTEXT ROTATION'; flag = 'hard-limit' }
}
$results = @($results) + @(foreach ($name in $guardCases.Keys) {
    if ($Only -and $name -ne $Only) { continue }
    $gc = $guardCases[$name]
    $dir = Join-Path $work $name
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null   # without `handoff`, no handoff file, so it is never fresh
    $stateFile = Join-Path $dir '.claude/state/guard-test.json'
    if ($null -ne $gc.handoff) {
        New-Item -ItemType Directory -Force -Path (Split-Path $stateFile) | Out-Null
        [IO.File]::WriteAllText((Join-Path $dir 'current-handoff.md'), $gc.handoff)
        $started = if ($gc.stale) { [DateTime]::UtcNow.AddMinutes(5).Ticks } else { 0 }
        @{ startedTicks = $started; warned = [bool]$gc.warned; lastTokens = 0; lintBlocked = [bool]$gc.lintBlocked; boundaryWarned = [bool]$gc.boundaryWarned } |
            ConvertTo-Json -Compress | Set-Content $stateFile
    }
    $transcript = Join-Path $dir 'transcript.jsonl'
    if ($gc.tokens) {
        @{ type = 'assistant'; message = @{ usage = @{ input_tokens = 10; cache_creation_input_tokens = 0; cache_read_input_tokens = $gc.tokens - 60; output_tokens = 50 } } } |
            ConvertTo-Json -Compress -Depth 4 | Set-Content $transcript
    }
    $event = $gc.event ?? 'Stop'
    $payload = @{ session_id = 'guard-test'; cwd = $dir; stop_hook_active = [bool]$gc.stopActive; transcript_path = $transcript } | ConvertTo-Json -Compress
    $saved = @{ AGENT_LOOP_RUN_ID = $env:AGENT_LOOP_RUN_ID; CLAUDE_PROJECT_DIR = $env:CLAUDE_PROJECT_DIR; AGENT_LOOP_BOUNDARY_TOKENS = $env:AGENT_LOOP_BOUNDARY_TOKENS }
    try {
        $env:AGENT_LOOP_RUN_ID = $gc.runId; $env:CLAUDE_PROJECT_DIR = $dir; $env:AGENT_LOOP_BOUNDARY_TOKENS = $gc.boundaryEnv
        $out = ($payload | pwsh -NoProfile -File $guard -Event $event 2>&1 | Out-String).Trim()
    }
    finally { foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }
    $blocked = $out -match '"decision"\s*:\s*"block"'
    $reason = if ($blocked) { try { ($out | ConvertFrom-Json).reason } catch { "unparsable: $out" } }
    $gstate = if (Test-Path $stateFile) { Get-Content $stateFile -Raw | ConvertFrom-Json }
    $lintBlocked = [bool]$gstate.lintBlocked
    $boundaryWarned = [bool]$gstate.boundaryWarned
    $flagPath = Join-Path $dir '.claude/state/rotate.flag'
    $flagText = if (Test-Path $flagPath) { (Get-Content $flagPath -Raw).Trim() }
    $flagObj = $null
    if ($flagText) { try { $flagObj = $flagText | ConvertFrom-Json -ErrorAction Stop } catch { } }
    $problems = @(
        if ($blocked -ne $gc.expectBlock) { "blocked=$blocked, output: $out" }
        elseif (-not $gc.expectBlock -and $out) { "unexpected output: $out" }
        elseif ($gc.reason -and $reason -notmatch $gc.reason) { "reason did not match /$($gc.reason)/: $reason" }
        if ($lintBlocked -ne [bool]$gc.expectLintBlocked) { "state lintBlocked=$lintBlocked, expected $([bool]$gc.expectLintBlocked)" }
        if ($boundaryWarned -ne [bool]$gc.expectBoundaryWarned) { "state boundaryWarned=$boundaryWarned, expected $([bool]$gc.expectBoundaryWarned)" }
        if ($gc.flag -and ($flagObj.reason -ne $gc.flag -or $flagObj.sessionId -ne 'guard-test' -or $flagObj.tokens -ne $gc.tokens -or -not $flagObj.ts)) {
            "rotate.flag '$flagText' is not JSON with reason $($gc.flag), sessionId guard-test, tokens $($gc.tokens) and ts"
        }
        elseif (-not $gc.flag -and $null -ne $flagText) { "unexpected rotate.flag '$flagText'" }
    )
    [pscustomobject]@{
        scenario = $name; expectStop = $(if ($gc.expectBlock) { 'block' } else { 'allow' }); stop = $(if ($blocked) { 'block' } else { 'allow' })
        expectSessions = 0; sessions = 0; pass = ($problems.Count -eq 0); problems = $problems -join '; '
    }
})
# B3: -BoundaryLimit at or above -SoftLimit is rejected before any session starts
if (-not $Only -or $Only -eq 'boundary-invalid') {
    $msg = try { & $loop -ProjectDir $work -ClaudePath $fake -NoSummary -BoundaryLimit 170000 *>&1 | Out-Null; 'no error' } catch { $_.Exception.Message }
    $ok = $msg -match 'must be below -SoftLimit'
    $results = @($results) + [pscustomobject]@{
        scenario = 'boundary-invalid'; expectStop = 'throw'; stop = $(if ($ok) { 'throw' } else { 'none' })
        expectSessions = 0; sessions = 0; pass = $ok; problems = $(if ($ok) { '' } else { $msg })
    }
}
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
# X3: auto-update. Install a copy of the source into a temp tools dir, then check that the installed Start-Agent.ps1
# syncs changed files, refuses a source with parse errors, and runs its own new copy (with -NoUpdate) when replaced.
$repoDir = Split-Path $here -Parent
$auSrc = Join-Path $work 'autoupdate-src'
$auTools = Join-Path $work 'autoupdate-tools'
$auProfile = Join-Path $work 'autoupdate-profile.ps1'
$auFiles = 'Start-Agent.ps1', 'context-guard.ps1', 'Start-AgentLoop.ps1', 'Resolve-HandoffFile.ps1', 'New-AgentLoopReport.ps1',
'AgentLoopReport.html', 'Invoke-LoopSummary.ps1', 'LoopSummaryPrompt.md', 'loop-summary.schema.json'
function Get-StaleFiles { @($auFiles | Where-Object { (Get-FileHash (Join-Path $auSrc $_)).Hash -ne (Get-FileHash (Join-Path $auTools $_)).Hash }) }
$auCases = [ordered]@{
    'autoupdate-install'     = {
        $auSrc, $auTools, $auProfile | Where-Object { Test-Path $_ } | Remove-Item -Recurse -Force
        New-Item -ItemType Directory -Force -Path $auSrc | Out-Null
        foreach ($f in $auFiles + 'Install-AgentLoop.ps1') { Copy-Item (Join-Path $repoDir $f) $auSrc }
        & (Join-Path $auSrc 'Install-AgentLoop.ps1') -ToolsDir $auTools -ProfilePath $auProfile -SkipHooks *>&1 | Out-Null
        $cfg = Get-Content (Join-Path $auTools 'install.json') -Raw | ConvertFrom-Json
        if ($cfg.sourceDir -ne (Resolve-Path $auSrc).Path) { "install.json sourceDir = $($cfg.sourceDir)" }
        $alias = "Set-Alias Start-Agent '$(Join-Path $auTools 'Start-Agent.ps1')'"
        if (-not (Get-Content $auProfile -Raw).Contains($alias)) { "profile has no line: $alias" }
        $stale = Get-StaleFiles; if ($stale) { "not installed: $($stale -join ', ')" }
    }
    'autoupdate-noop'        = {
        $got = @(& (Join-Path $auSrc 'Install-AgentLoop.ps1') -ToolsDir $auTools -FilesOnly)
        if ($got.Count) { "FilesOnly with no change copied: $($got -join ', ')" }
    }
    'autoupdate-sync'        = {
        Add-Content (Join-Path $auSrc 'Start-AgentLoop.ps1') '# changed'
        Add-Content (Join-Path $auSrc 'AgentLoopReport.html') '<!-- changed -->'
        $out = & (Join-Path $auTools 'Start-Agent.ps1') -UpdateOnly 6>&1 3>&1 | Out-String
        $stale = Get-StaleFiles; if ($stale) { "still stale: $($stale -join ', ')" }
        if ($out -notmatch 'updated from .*Start-AgentLoop\.ps1, AgentLoopReport\.html') { "no update message: $out" }
    }
    'autoupdate-parse-error' = {
        $before = (Get-FileHash (Join-Path $auTools 'context-guard.ps1')).Hash
        Add-Content (Join-Path $auSrc 'context-guard.ps1') 'function {'
        Add-Content (Join-Path $auSrc 'Start-AgentLoop.ps1') '# changed again'
        $out = & (Join-Path $auTools 'Start-Agent.ps1') -UpdateOnly 3>&1 | Out-String
        if ((Get-FileHash (Join-Path $auTools 'context-guard.ps1')).Hash -ne $before) { 'broken context-guard.ps1 was installed' }
        if ((Get-StaleFiles) -notcontains 'Start-AgentLoop.ps1') { 'Start-AgentLoop.ps1 copied despite a broken source' }
        if ($out -notmatch 'parse errors.*context-guard\.ps1') { "no parse-error warning: $out" }
        Copy-Item (Join-Path $repoDir 'context-guard.ps1') $auSrc -Force
    }
    'autoupdate-self'        = {
        # The new source copy returns early on -NoUpdate and leaves a marker; the installed copy has no such line,
        # so the marker proves the replaced script re-ran itself as the new copy, once.
        $marker = Join-Path $work 'autoupdate-marker.txt'
        Remove-Item $marker -ErrorAction Ignore
        $sa = Join-Path $auSrc 'Start-Agent.ps1'
        $text = (Get-Content $sa -Raw) -replace "(?m)^\`$ErrorActionPreference = 'Stop'\r?$",
            "`$0`nif (`$NoUpdate) { Add-Content '$marker' 'reinvoked'; return }"
        Set-Content $sa $text
        # A repo path that does not exist: the old copy throws before starting a loop, the new one returns first.
        & (Join-Path $auTools 'Start-Agent.ps1') (Join-Path $work 'no-such-repo') *>&1 | Out-Null
        if (-not (Test-Path $marker)) { 'new Start-Agent.ps1 was not re-run' }
        elseif (@(Get-Content $marker).Count -ne 1) { "re-ran $(@(Get-Content $marker).Count) times" }
        $stale = Get-StaleFiles; if ($stale) { "still stale: $($stale -join ', ')" }
    }
}
$results = @($results) + @(foreach ($name in $auCases.Keys) {
    if ($Only -and $name -ne $Only -and $name -ne 'autoupdate-install') { continue }
    if ($Only -and $Only -notlike 'autoupdate-*') { continue }
    $problems = @(try { & $auCases[$name] } catch { "threw: $($_.Exception.Message)" })
    [pscustomobject]@{
        scenario = $name; expectStop = 'ok'; stop = $(if ($problems.Count) { 'problems' } else { 'ok' })
        expectSessions = 0; sessions = 0; pass = ($problems.Count -eq 0); problems = $problems -join '; '
    }
})
$results | Format-Table -AutoSize | Out-String | Write-Host
$failed = @($results | Where-Object { -not $_.pass }).Count
Write-Host ("{0} scenarios, {1} failed" -f @($results).Count, $failed) -ForegroundColor ($failed ? 'Red' : 'Green')
exit $failed
