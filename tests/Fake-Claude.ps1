#Requires -Version 7
# Stand-in for claude.exe. Ignores its arguments. Reads $env:FAKE_SCENARIO (a JSON array of per-session
# steps) and a counter in .claude/state/fake-counter under the current directory. Each step may set:
#   label, next, owner, safe, did  -> written as a real handoff entry via Add-RunHandoffEntry.ps1
#   noEntry: true                  -> write nothing (simulates an agent that forgot the handoff)
#   commit: true                   -> git commit a touched file
#   rotate: true                   -> write .claude/state/rotate.flag (guard forced a rotation)
#   exit: <int>                    -> process exit code
#   error: 'rate' | 'generic'      -> emit an error result instead of success
#   cost, tokens                   -> numbers in the result event
$ErrorActionPreference = 'Stop'
$steps = @(Get-Content $env:FAKE_SCENARIO -Raw | ConvertFrom-Json)
$stateDir = Join-Path (Get-Location) '.claude/state'
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
$counterFile = Join-Path $stateDir 'fake-counter'
$i = if (Test-Path $counterFile) { [int](Get-Content $counterFile) } else { 0 }
Set-Content $counterFile ($i + 1)
$s = if ($i -lt $steps.Count) { $steps[$i] } else { $steps[-1] }
function P($o) { $o | ConvertTo-Json -Compress -Depth 6 }

P @{ type = 'system'; subtype = 'init'; session_id = "fake-$($i + 1)"; permissionMode = 'auto' }
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
        Summary = "fake step $($i + 1)"; Did = ($s.did ?? "did step $($i + 1)"); Verified = 'nothing'
        SafeToProceed = ($s.safe ?? 'yes'); Next = ($s.next ?? "item $($s.label)"); NextLabel = ($s.label ?? ''); Owner = ($s.owner ?? 'nothing')
    }
    & "$HOME/.claude/scripts/Add-RunHandoffEntry.ps1" @entryArgs | Out-Null
}
if ($s.commit) {
    Add-Content (Join-Path (Get-Location) 'work.txt') "step $($i + 1)"
    git add -A 2>$null | Out-Null; git -c user.name=t -c user.email=t@t commit -q -m "step $($i + 1)" 2>$null | Out-Null
}
if ($s.rotate) { Set-Content (Join-Path $stateDir 'rotate.flag') 'x' }

P @{ type = 'result'; subtype = 'success'; is_error = $false; result = 'ok'; num_turns = 5
    total_cost_usd = [double]($s.cost ?? 1.0); session_id = "fake-$($i + 1)"
    usage = @{ input_tokens = 1000; cache_creation_input_tokens = 2000; cache_read_input_tokens = [long]($s.tokens ?? 50000); output_tokens = 500 }
    permission_denials = @() }
exit ([int]($s.exit ?? 0))
