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
  Stop:        blocks the stop once if current-handoff.md wasn't written this session.
#>
param(
    [ValidateSet('PostToolUse', 'Stop')][string]$Event = 'PostToolUse',
    [int]$SoftLimit = 160000,
    [int]$HardLimit = 185000,
    [string]$HandoffFile = ''   # blank = resolve from .claude/agent-loop.json, then auto-discover
)

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

    $handoffFresh = (Test-Path $handoff) -and
    ((Get-Item $handoff).LastWriteTimeUtc.Ticks -gt [long]$state.startedTicks)
    $out = $null

    switch ($Event) {
        'PostToolUse' {
            $tokens = Get-ContextTokens $payload.transcript_path
            $state.lastTokens = $tokens
            if ($tokens -ge $SoftLimit) {
                Set-Content -Path $flag -Value $payload.session_id   # tells the outer loop to relaunch
                if (-not $state.warned -or $tokens -ge $HardLimit) {
                    $state.warned = $true
                    $k = [math]::Round($tokens / 1000)
                    $out = @{
                        decision = 'block'
                        reason   = "CONTEXT ROTATION: ~${k}k tokens in context (limit $([math]::Round($SoftLimit/1000))k). " +
                        "Finish ONLY the current atomic step. Then update $HandoffFile with: goal, what's done, " +
                        "files touched, decisions + why, open issues, and exact next steps. Then stop. " +
                        "Do not start new work - a fresh session will resume via /handoff." +
                        " If the overall task is finished, put 'Status: DONE' on its own line in the handoff."
                    }
                }
            }
        }
        'Stop' {
            if (-not $handoffFresh -and -not $payload.stop_hook_active) {
                $out = @{ decision = 'block'; reason = "Rule: update $HandoffFile before ending this session." }
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
