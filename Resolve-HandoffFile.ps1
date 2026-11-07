# Shared by context-guard.ps1 and Start-AgentLoop.ps1.
# Order: explicit value -> .claude/agent-loop.json "handoffFile" -> first existing candidate
#        (case-insensitive) -> 'current-handoff.md'. Returns a path relative to the repo root.
function Resolve-HandoffFile([string]$Root, [string]$Explicit) {
    if ($Explicit) { return $Explicit }
    $cfg = Join-Path $Root '.claude/agent-loop.json'
    if (Test-Path $cfg) {
        $h = (Get-Content $cfg -Raw | ConvertFrom-Json).handoffFile
        if ($h) { return $h }
    }
    foreach ($c in 'current-handoff.md', 'docs/current-handoff.md', '.claude/current-handoff.md') {
        $dir = Join-Path $Root (Split-Path $c -Parent)
        $hit = Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
            Where-Object Name -ieq (Split-Path $c -Leaf) | Select-Object -First 1
        if ($hit) { return [IO.Path]::GetRelativePath($Root, $hit.FullName) }
    }
    return 'current-handoff.md'
}
