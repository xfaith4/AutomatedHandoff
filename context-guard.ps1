#Requires -Version 7
<#
.SYNOPSIS
  Claude Code hook: watches context usage, forces a handoff at the token limit,
  and signals the outer loop to relaunch a fresh session.

  Wire as BOTH a PostToolUse hook (-Event PostToolUse) and a Stop hook (-Event Stop).

  PostToolUse: reads the transcript, computes current context tokens from the last
               assistant message's usage block. At >= SoftLimit it writes rotate.flag
               and tells Claude to finish the current step, write the handoff, and stop.
               It warns once, then again on every tool call past HardLimit.
               B3: inside a loop run, once the handoff was rewritten this session and context is at or above
               BoundaryLimit (below SoftLimit), it writes rotate.flag ("boundary") once and tells Claude to stop,
               so the next roadmap item starts in a fresh session instead of on top of the last one's context.
               B4: rotate.flag is JSON {reason, sessionId, tokens, ts}, reason soft-limit | hard-limit | boundary.
  Stop:        blocks the stop once if current-handoff.md wasn't written this session, and once more
               if the written top entry fails Test-HandoffEntry (B2). Only inside a loop run (AGENT_LOOP_RUN_ID set by Start-AgentLoop.ps1): the hook is
               registered at user level, so it also fires in interactive sessions, which it must not block.
#>
param(
    [ValidateSet('PostToolUse', 'Stop')][string]$Event = 'PostToolUse',
    # 170k/190k: sessions start at ~50k of fixed context and ~60-120k by their first edit, so 160k left
    # too little room to work. Auto-compaction is near 200k; the wrap-up needs 10-20k of that gap.
    [int]$SoftLimit = 170000,
    [int]$HardLimit = 190000,
    # B3: rotate at the item boundary (handoff written this session) once context reaches this. 0 = off.
    [int]$BoundaryLimit = 100000,
    [string]$HandoffFile = ''   # blank = resolve from .claude/agent-loop.json, then auto-discover
)

# Start-AgentLoop.ps1 passes its -SoftLimit/-HardLimit this way: the hook is registered once, at user level
$envSoft = 0; $envHard = 0
if ([int]::TryParse("$env:AGENT_LOOP_SOFT_TOKENS", [ref]$envSoft) -and $envSoft -gt 0) { $SoftLimit = $envSoft }
if ([int]::TryParse("$env:AGENT_LOOP_HARD_TOKENS", [ref]$envHard) -and $envHard -gt 0) { $HardLimit = $envHard }
$envBoundary = 0   # 0 is a valid value here: -BoundaryLimit 0 turns boundary rotation off
if ([int]::TryParse("$env:AGENT_LOOP_BOUNDARY_TOKENS", [ref]$envBoundary) -and $envBoundary -ge 0) { $BoundaryLimit = $envBoundary }

. (Join-Path $PSScriptRoot Resolve-HandoffFile.ps1)

try {
    $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json
    $root = $env:CLAUDE_PROJECT_DIR ?? $payload.cwd
    $stateDir = Join-Path $root '.claude/state'
    New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

    $stateFile = Join-Path $stateDir "$($payload.session_id).json"
    $flag = Join-Path $stateDir 'rotate.flag'
    $HandoffFile = Resolve-HandoffFile $root $HandoffFile
    $handoff = Join-Path $root $HandoffFile

    # Per-session state (ticks avoid DateTime Kind/JSON parsing pitfalls)
    $state = if (Test-Path $stateFile) { Get-Content $stateFile -Raw | ConvertFrom-Json }
    else { [pscustomobject]@{ startedTicks = [DateTime]::UtcNow.Ticks; warned = $false; lastTokens = 0 } }

    function Get-ContextTokens([string]$Path) {
        if (-not $Path -or -not (Test-Path $Path)) { return 0 }
        $lines = @(Get-Content -LiteralPath $Path -Tail 200)   # @() so a 1-line file isn't indexed as chars
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            try { $e = $lines[$i] | ConvertFrom-Json -ErrorAction Stop } catch { continue }
            $u = $e.message.usage
            if ($e.type -eq 'assistant' -and $u -and -not $e.isSidechain) {
                # Context = everything sent in + what was generated on the last turn
                return [int]($u.input_tokens + $u.cache_creation_input_tokens +
                    $u.cache_read_input_tokens + $u.output_tokens)
            }
        }
        return 0
    }

    # B4: rotate.flag is one JSON object; reason is soft-limit, hard-limit or boundary. The loop reads it.
    function Write-RotateFlag([string]$Reason, [int]$Tokens) {
        [ordered]@{ reason = $Reason; sessionId = $payload.session_id; tokens = $Tokens; ts = [DateTime]::UtcNow.ToString('o') } |
            ConvertTo-Json -Compress | Set-Content -LiteralPath $flag
    }

    $handoffFresh = (Test-Path $handoff) -and
    ((Get-Item $handoff).LastWriteTimeUtc.Ticks -gt [long]$state.startedTicks)
    $out = $null

    switch ($Event) {
        'PostToolUse' {
            $tokens = Get-ContextTokens $payload.transcript_path
            $state.lastTokens = $tokens
            if ($tokens -ge $SoftLimit) {
                # Tells the outer loop to relaunch. Rewritten on every call past the soft limit, so a session that
                # crosses the hard limit ends with reason hard-limit.
                Write-RotateFlag ($tokens -ge $HardLimit ? 'hard-limit' : 'soft-limit') $tokens
                if (-not $state.warned -or $tokens -ge $HardLimit) {
                    $state.warned = $true
                    $k = [math]::Round($tokens / 1000)
                    $out = @{
                        decision = 'block'
                        reason   = "CONTEXT ROTATION: ~${k}k tokens in context (limit $([math]::Round($SoftLimit/1000))k). " +
                        "Finish ONLY the current atomic step. Then update $HandoffFile with: goal, what's done, " +
                        "files touched, decisions + why, open issues, and exact next steps. Name the exact files and the " +
                        "roadmap section the next step needs, so the next session reads only those. Then stop. " +
                        "Do not start new work - a fresh session will resume via /handoff." +
                        " If the overall task is finished, put 'Status: DONE' on its own line in the handoff."
                    }
                }
            }
            elseif ($env:AGENT_LOOP_RUN_ID -and $BoundaryLimit -gt 0 -and $tokens -ge $BoundaryLimit -and $handoffFresh -and
                -not $state.boundaryWarned) {
                # B3: the handoff was rewritten this session, so an item just closed. Starting the next one on top of
                # this context costs more per call than a fresh session that reads the handoff. Once per session.
                Write-RotateFlag 'boundary' $tokens
                $state | Add-Member -NotePropertyName boundaryWarned -NotePropertyValue $true -Force
                $k = [math]::Round($tokens / 1000)
                $out = @{
                    decision = 'block'
                    reason   = "ITEM BOUNDARY: you rewrote $HandoffFile this session and context is ~${k}k tokens " +
                    "(boundary $([math]::Round($BoundaryLimit/1000))k). Do not start the next item. If this item's work " +
                    "is not committed yet, commit it; make sure the top entry of $HandoffFile names the next step. " +
                    "Then stop. A fresh session will pick up the next item via /handoff."
                }
            }
        }
        'Stop' {
            if (-not $env:AGENT_LOOP_RUN_ID) { break }
            if (-not $handoffFresh) {
                if (-not $payload.stop_hook_active) {
                    $out = @{ decision = 'block'; reason = "Rule: update $HandoffFile before ending this session." }
                }
                break
            }
            # B2: a fresh handoff must pass the lint. Blocks at most once per session (state.lintBlocked),
            # so it also catches an entry written after the stale-handoff block (stop_hook_active is then true).
            # A handoff with no dated entry (session-hygiene shape) has nothing to lint and is left alone.
            $problems = @(Test-HandoffEntry $handoff)
            $unlintable = $problems.Count -eq 1 -and $problems[0] -like 'no top entry*'
            if ($problems.Count -and -not $unlintable -and -not $state.lintBlocked) {
                $state | Add-Member -NotePropertyName lintBlocked -NotePropertyValue $true -Force
                $state | Add-Member -NotePropertyName lintProblems -NotePropertyValue $problems -Force
                $out = @{
                    decision = 'block'
                    reason   = "HANDOFF CHECK: the top entry of $HandoffFile is not specific enough for the next session: " +
                    ($problems -join '; ') + '. Fix those fields in that entry (Next: a file, command or item ID; ' +
                    'Verified: the commands you ran and their results; Safe to proceed: starts with yes or no), then stop.'
                }
            }
        }
    }

    $state | ConvertTo-Json -Compress | Set-Content $stateFile
    if ($out) { $out | ConvertTo-Json -Compress }
    exit 0
}
catch {
    # Never break the agent because the guard failed
    [Console]::Error.WriteLine("context-guard: $($_.Exception.Message)")
    exit 0
}
