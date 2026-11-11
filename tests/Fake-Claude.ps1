#Requires -Version 7
# Stand-in for claude.exe. Ignores its arguments. Reads $env:FAKE_SCENARIO (a JSON array of per-session
# steps) and a counter in .claude/state/fake-counter under the current directory. Each step may set:
#   label, next, owner, safe, did, verified -> written as a real handoff entry via Add-RunHandoffEntry.ps1
#   guardBlocked: true             -> write the guard's per-session state with lintBlocked (B2)
#   noEntry: true                  -> write nothing (simulates an agent that forgot the handoff)
#   commit: true                   -> git commit a touched file
#   rotate: true | 'boundary'      -> write .claude/state/rotate.flag (guard forced a rotation; 'boundary' = B3 reason)
#   exit: <int>                    -> process exit code
#   error: 'rate' | 'generic'      -> emit an error result instead of success
#   cost, tokens                   -> numbers in the result event
#   startup: true                  -> emit init with tools/mcp_servers and a main-chain Read, Read (same file),
#                                     Grep, Edit sequence with usage, plus one subagent tool call to be ignored
# Every call records its arguments and the loop's env vars in .claude/state/fake-call-<n>.json.
$ErrorActionPreference = 'Stop'
$steps = @(Get-Content $env:FAKE_SCENARIO -Raw | ConvertFrom-Json)
$stateDir = Join-Path (Get-Location) '.claude/state'
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
$counterFile = Join-Path $stateDir 'fake-counter'
$i = if (Test-Path $counterFile) { [int](Get-Content $counterFile) } else { 0 }
Set-Content $counterFile ($i + 1)
$s = if ($i -lt $steps.Count) { $steps[$i] } else { $steps[-1] }
function P($o) { $o | ConvertTo-Json -Compress -Depth 8 }

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
if ($s.rotate) { Set-Content (Join-Path $stateDir 'rotate.flag') ('boundary' -eq $s.rotate ? "boundary fake-$($i + 1)" : 'x') }
if ($s.guardBlocked) {   # what context-guard.ps1 leaves in its per-session state after a lint block
    @{ startedTicks = 0; warned = $false; lastTokens = 0; lintBlocked = $true } | ConvertTo-Json -Compress |
        Set-Content (Join-Path $stateDir "fake-$($i + 1).json")
}

P @{ type = 'result'; subtype = 'success'; is_error = $false; result = 'ok'; num_turns = 5
    total_cost_usd = [double]($s.cost ?? 1.0); session_id = "fake-$($i + 1)"
    usage = @{ input_tokens = 1000; cache_creation_input_tokens = 2000; cache_read_input_tokens = [long]($s.tokens ?? 50000); output_tokens = 500 }
    permission_denials = @() }
exit ([int]($s.exit ?? 0))
