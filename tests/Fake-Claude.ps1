#Requires -Version 7
# Stand-in for claude.exe. Ignores its arguments. Reads $env:FAKE_SCENARIO (a JSON array of per-session
# steps) and a counter in .claude/state/fake-counter under the current directory. Each step may set:
#   label, next, owner, safe, did, verified -> written as a real handoff entry via Add-RunHandoffEntry.ps1
#   guardBlocked: true             -> write the guard's per-session state with lintBlocked (B2)
#   noEntry: true                  -> write nothing (simulates an agent that forgot the handoff)
#   commit: true                   -> git commit a touched file
#   rotate: true | 'boundary' | 'hard-limit' | 'legacy-boundary' | 'legacy'
#                                  -> write .claude/state/rotate.flag as the guard's B4 JSON (true = soft-limit,
#                                     tokens 180000), or a pre-B4 plain-text flag for the legacy values
#   exit: <int>                    -> process exit code
#   error: 'rate' | 'generic'      -> emit an error result instead of success
#   cost, tokens                   -> numbers in the result event
#   extraResult: @{turns; tokens; cost} -> X2: emit an earlier result event first (a session re-woken by a
#                                     background task); its cost is cumulative-so-far, tokens go in cache_read
#   startup: true                  -> emit init with tools/mcp_servers and a main-chain Read, Read (same file),
#                                     Grep, Edit sequence with usage, plus one subagent tool call to be ignored
#   repair: 'entry' | 'bad'        -> B5: what a `--resume` call (the loop's handoff repair) does for this step's
#                                     session: write a passing entry (label repairLabel, default R1), write one that
#                                     still fails the lint, or (absent) write nothing. repairCost (default 0.1),
#                                     repairExit (default 0). Its result has 5000 tokens. repairRotate: true makes
#                                     the repair write a boundary rotate.flag.
# Every call records its arguments and the loop's env vars in .claude/state/fake-call-<n>.json; a --resume call
# records them in fake-repair-<n>.json instead and does not advance the step counter.
$ErrorActionPreference = 'Stop'
$steps = @(Get-Content $env:FAKE_SCENARIO -Raw | ConvertFrom-Json)
$stateDir = Join-Path (Get-Location) '.claude/state'
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
$counterFile = Join-Path $stateDir 'fake-counter'
$i = if (Test-Path $counterFile) { [int](Get-Content $counterFile) } else { 0 }
function P($o) { $o | ConvertTo-Json -Compress -Depth 8 }

$ri = [array]::IndexOf(@($args), '--resume')
if ($ri -ge 0) {
    # Handoff repair of the session that just ran (step $i - 1)
    $s = $steps[[math]::Min($i, $steps.Count) - 1]
    @{ args = @($args) } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $stateDir "fake-repair-$i.json")
    $rid = "$(@($args)[$ri + 1])"
    P @{ type = 'system'; subtype = 'init'; session_id = $rid; permissionMode = 'auto' }
    P @{ type = 'assistant'; message = @{ content = @(@{ type = 'text'; text = "fake repair of $rid" }) } }
    if ($s.repair) {
        $good = $s.repair -eq 'entry'
        $lbl = $s.repairLabel ?? 'R1'
        & "$HOME/.claude/scripts/Add-RunHandoffEntry.ps1" -HandoffPath $env:FAKE_HANDOFF -SkipProgress -Summary "repair of step $i" `
            -Did "repaired step $i" -Verified ($good ? 'pwsh -NoProfile -File tests/x.ps1: ok' : 'nothing') -SafeToProceed 'yes' `
            -Next ($good ? "${lbl}: the next item" : 'keep going') -NextLabel $lbl -Owner 'nothing' | Out-Null
    }
    if ($s.repairRotate) {   # the guard firing again inside the repair; the loop must keep the main session's flag state
        Set-Content (Join-Path $stateDir 'rotate.flag') (P ([ordered]@{ reason = 'boundary'; sessionId = $rid; tokens = 120000; ts = '2026-11-13T00:00:00Z' }))
    }
    P @{ type = 'result'; subtype = 'success'; is_error = $false; result = 'ok'; num_turns = 2; total_cost_usd = [double]($s.repairCost ?? 0.1)
        session_id = $rid; usage = @{ input_tokens = 100; cache_creation_input_tokens = 0; cache_read_input_tokens = 4800; output_tokens = 100 } }
    exit ([int]($s.repairExit ?? 0))
}

Set-Content $counterFile ($i + 1)
$s = if ($i -lt $steps.Count) { $steps[$i] } else { $steps[-1] }

$envSeen = [ordered]@{}
foreach ($k in 'AGENT_LOOP_SOFT_TOKENS', 'AGENT_LOOP_HARD_TOKENS', 'AGENT_LOOP_BOUNDARY_TOKENS', 'CLAUDE_HYGIENE_MAP', 'CLAUDE_HYGIENE_HANDOFF_MAX_AGE_DAYS',
    'CLAUDE_HYGIENE_SOFT_TOKENS', 'CLAUDE_HYGIENE_HARD_TOKENS', 'TK_DISABLE', 'AGENT_LOOP_RUN_ID') {
    $envSeen[$k] = [Environment]::GetEnvironmentVariable($k)
}
@{ args = @($args); env = $envSeen } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $stateDir "fake-call-$($i + 1).json")

if ($s.startup) {
    P @{ type = 'system'; subtype = 'init'; session_id = "fake-$($i + 1)"; permissionMode = 'auto'
        tools = @('Read', 'Edit', 'Grep', 'Bash'); mcp_servers = @(@{ name = 'postgresql'; status = 'connected' }) }
    function Use($ctx, $id, $name, $tool, $created = 0) {
        P @{ type = 'assistant'; parent_tool_use_id = $null; message = @{ usage = @{ input_tokens = 10; cache_creation_input_tokens = $created; cache_read_input_tokens = $ctx - 10 - $created; output_tokens = 50 }
                content = @(@{ type = 'tool_use'; id = $id; name = $name; input = $tool }) } }
    }
    function Res($id, $text) { P @{ type = 'user'; parent_tool_use_id = $null; message = @{ content = @(@{ type = 'tool_result'; tool_use_id = $id; content = $text }) } } }
    Use 30000 't1' 'Read' @{ file_path = 'C:\repo\src\a.ts' } 6000; Res 't1' ('x' * 1000)
    # Subagent traffic: must not count as a main-chain call, read or context
    P @{ type = 'assistant'; parent_tool_use_id = 'task1'; message = @{ usage = @{ input_tokens = 999999 }
            content = @(@{ type = 'tool_use'; id = 'sub1'; name = 'Edit'; input = @{ file_path = 'x' } }) } }
    Use 32000 't2' 'Read' @{ file_path = 'c:/repo/src/a.ts' }; Res 't2' @(@{ type = 'text'; text = ('y' * 500) })
    Use 34000 't3' 'Grep' @{ pattern = 'foo' }; Res 't3' 'hit'
    Use 36000 't4' 'Edit' @{ file_path = 'C:\repo\src\a.ts' }; Res 't4' 'ok'
}
else {
    P @{ type = 'system'; subtype = 'init'; session_id = "fake-$($i + 1)"; permissionMode = 'auto' }
}
P @{ type = 'assistant'; message = @{ content = @(@{ type = 'text'; text = "fake session $($i + 1): $($s.did ?? 'working')" }) } }

if ($s.error) {
    $msg = if ($s.error -eq 'rate') { "You've hit your usage limit. Resets at 3pm." } else { 'Something broke' }
    P @{ type = 'result'; subtype = 'error_during_execution'; is_error = $true; result = $msg; num_turns = 1
        total_cost_usd = 0; usage = @{ input_tokens = 100; output_tokens = 10 }; session_id = "fake-$($i + 1)" }
    exit ([int]($s.exit ?? 0))
}

if (-not $s.noEntry) {
    $entryArgs = @{
        HandoffPath = $env:FAKE_HANDOFF; SkipProgress = $true
        Summary = "fake step $($i + 1)"; Did = ($s.did ?? "did step $($i + 1)"); Verified = ($s.verified ?? 'nothing')
        SafeToProceed = ($s.safe ?? 'yes'); Next = ($s.next ?? "item $($s.label)"); NextLabel = ($s.label ?? ''); Owner = ($s.owner ?? 'nothing')
    }
    & "$HOME/.claude/scripts/Add-RunHandoffEntry.ps1" @entryArgs | Out-Null
}
if ($s.commit) {
    Add-Content (Join-Path (Get-Location) 'work.txt') "step $($i + 1)"
    git add -A 2>$null | Out-Null; git -c user.name=t -c user.email=t@t commit -q -m "step $($i + 1)" 2>$null | Out-Null
}
if ($s.rotate) {
    $flagText = switch ("$($s.rotate)") {
        'legacy-boundary' { "boundary fake-$($i + 1)" }   # pre-B4 guard
        'legacy' { 'x' }                                  # unparseable -> soft-limit
        default {
            $reason = $s.rotate -is [bool] ? 'soft-limit' : "$($s.rotate)"
            P ([ordered]@{ reason = $reason; sessionId = "fake-$($i + 1)"; tokens = 180000; ts = '2026-11-13T00:00:00Z' })
        }
    }
    Set-Content (Join-Path $stateDir 'rotate.flag') $flagText
}
if ($s.guardBlocked) {   # what context-guard.ps1 leaves in its per-session state after a lint block
    @{ startedTicks = 0; warned = $false; lastTokens = 0; lintBlocked = $true } | ConvertTo-Json -Compress |
        Set-Content (Join-Path $stateDir "fake-$($i + 1).json")
}

if ($s.extraResult) {
    $x = $s.extraResult
    P @{ type = 'result'; subtype = 'success'; is_error = $false; result = 'first'; num_turns = [int]$x.turns
        total_cost_usd = [double]$x.cost; session_id = "fake-$($i + 1)"
        usage = @{ input_tokens = 0; cache_creation_input_tokens = 0; cache_read_input_tokens = [long]$x.tokens; output_tokens = 0 }
        permission_denials = @() }
}
P @{ type = 'result'; subtype = 'success'; is_error = $false; result = 'ok'; num_turns = 5
    total_cost_usd = [double]($s.cost ?? 1.0); session_id = "fake-$($i + 1)"
    usage = @{ input_tokens = 1000; cache_creation_input_tokens = 2000; cache_read_input_tokens = [long]($s.tokens ?? 50000); output_tokens = 500 }
    permission_denials = @() }
exit ([int]($s.exit ?? 0))
