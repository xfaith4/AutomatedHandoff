#Requires -Version 7
<#
.SYNOPSIS
  Builds a self-contained HTML report from an agent-loop JSONL log by embedding the log
  in AgentLoopReport.html. The template also opens a log on its own (file picker or drop).
  With -HandoffLogPath, the entries of handoff-log.json (Add-RunHandoffEntry.ps1) are embedded
  too, one JSON line each.

.EXAMPLE
  ./New-AgentLoopReport.ps1 -LogPath F:\Development\MyRepo\.claude\state\agent-loop.log.jsonl -HandoffLogPath F:\Development\MyRepo\docs\handoff-log.json
#>
param(
    [Parameter(Mandatory)][string]$LogPath,
    [string]$OutPath = (Join-Path (Split-Path $LogPath -Parent) 'agent-loop-report.html'),
    [string]$Template = (Join-Path $PSScriptRoot 'AgentLoopReport.html'),
    [string]$HandoffLogPath = ''        # optional; skipped when the file is missing
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$slot = '<script id="log-data" type="application/x-ndjson"></script>'
$html = Get-Content -LiteralPath $Template -Raw
if (-not $html.Contains($slot)) { throw "Template has no log-data slot: $Template" }

# '</' only occurs inside JSON strings, where '<\/' is an equivalent escape; stops a logged
# '</script>' from closing the data tag
$data = (Get-Content -LiteralPath $LogPath -Raw).TrimEnd()
if ($HandoffLogPath -and (Test-Path -LiteralPath $HandoffLogPath)) {
    # The embedded data is read as JSONL, so the pretty-printed document becomes one line per entry
    try {
        $lines = @((Get-Content -LiteralPath $HandoffLogPath -Raw | ConvertFrom-Json).entries | Where-Object { $_ } | ForEach-Object {
                if (-not $_.PSObject.Properties['type']) { $_ | Add-Member -NotePropertyName type -NotePropertyValue 'handoff' }
                $_ | ConvertTo-Json -Compress -Depth 6
            })
        if ($lines.Count) { $data += "`n" + ($lines -join "`n") }
    }
    catch { Write-Warning "Handoff entries not embedded from ${HandoffLogPath}: $($_.Exception.Message)" }
}
$data = $data.Replace('</', '<\/')
$html.Replace($slot, $slot.Replace('></script>', ">`n$data</script>")) |
    Set-Content -LiteralPath $OutPath -Encoding utf8NoBOM
Get-Item -LiteralPath $OutPath
