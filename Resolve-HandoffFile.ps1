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

# Deterministic quality check of the handoff's top entry (Add-RunHandoffEntry.ps1 shape:
# "## YYYY-MM-DD — summary (label next)" followed by "- **Key:** value" lines).
# Returns problem strings; an empty array means the entry passes. Regexes only, never a model.
#   Next             names a file, a command or an item ID (or says DONE / COMPLETE)
#   Verified         contains at least one command
#   Safe to proceed  starts with yes or no
function Test-HandoffEntry([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return @("handoff file not found: $Path") }
    $lines = @([IO.File]::ReadAllLines($Path))
    $top = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^##\s') { $top = $i; break } }
    if ($top -lt 0 -or $lines[$top] -notmatch '^##\s+\d{4}-\d{2}-\d{2}\b') {
        return @('no top entry in the "## YYYY-MM-DD — summary (label next)" shape')
    }
    $f = @{}
    for ($i = $top + 1; $i -lt $lines.Count -and $lines[$i] -notmatch '^##\s'; $i++) {
        if ($lines[$i] -match '^\s*-\s+\*\*(?<k>[^*]+?):\*\*\s*(?<v>.*)$') { $f[$Matches['k'].Trim().ToLower()] = $Matches['v'].Trim() }
    }
    $file = '(?:[\w.-]+[\\/])+[\w.-]+|\b[\w-]+\.(?:ps1|psm1|psd1|md|json|jsonl|ya?ml|ts|tsx|js|mjs|py|cs|html|css|sql|toml|txt)\b'
    $cmd = '`[^`]+`|\b(?:pwsh|powershell|npm|npx|pnpm|yarn|git|node|python3?|pytest|dotnet|cargo|go|make|Start-Agent|Invoke-\w+|Test-\w+)\b'
    $item = '\b[A-Z]{1,3}\.?\d+[a-z]?\b'
    $problems = [Collections.Generic.List[string]]::new()
    $next = "$($f['next'])"
    if (-not $next) { $problems.Add('Next is missing or empty') }
    elseif ($next -cnotmatch '^(DONE|COMPLETE)\b' -and $next -notmatch $file -and $next -notmatch $cmd -and $next -cnotmatch $item) {
        $problems.Add('Next names no file, command or item ID')
    }
    $verified = "$($f['verified'])"
    if (-not $verified) { $problems.Add('Verified is missing or empty') }
    elseif ($verified -notmatch $cmd -and $verified -notmatch '\b[\w.-]+\.(?:ps1|py|sh|js|ts)\b') { $problems.Add('Verified names no command') }
    $safe = "$($f['safe to proceed'])"
    if (-not $safe) { $problems.Add('Safe to proceed is missing or empty') }
    elseif ($safe -notmatch '^(yes|no)\b') { $problems.Add('Safe to proceed does not start with yes or no') }
    return @($problems)
}
