# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A context-rotation loop for unattended Claude Code runs. It runs `claude -p /handoff` headless against a target repo. When a session's context passes a token limit, a hook makes the agent write its handoff and stop, and the outer loop starts a fresh session that picks up from that handoff.

This folder is not a git repository and has no tests, roadmap, or build. All scripts require PowerShell 7 (`??`, `[IO.Path]::GetRelativePath`).

## Source vs. installed copies

The files here are the source. What actually runs is the copy in `~/.claude/agent-loop/`, plus a `Start-Agent` function written into the PowerShell profile. An edit here does nothing until it is reinstalled:

```powershell
# -SkipHooks: hooks are already in ~/.claude/settings.json. The VS Code terminal loads Microsoft.VSCode_profile.ps1, not plain $PROFILE.
pwsh -NoProfile -File .\Install-AgentLoop.ps1 -SkipHooks -ProfilePath "$HOME\OneDrive\Documents\PowerShell\Microsoft.VSCode_profile.ps1"
. $PROFILE
Start-Agent F:\Development\20_Staging\Financial\MyFinancialLedger -Max 1   # live check
```

Both `Microsoft.VSCode_profile.ps1` and `Microsoft.PowerShell_profile.ps1` under `~/OneDrive/Documents/PowerShell` carry a `Start-Agent` block. Install into whichever one the terminal loads (`$PROFILE`), or both, or a stale copy shadows the new one after `. $PROFILE`. Run the installer with its absolute path; a relative `.\Install-AgentLoop.ps1` from a target repo fails.

Ben has to run the install and the live checks himself. This session's auto-mode classifier blocks starting a nested headless `claude -p` and writing to the profile.

## Verification

With no test suite, the check is a parse with zero errors, plus a live run when behavior changes:

```powershell
Get-ChildItem *.ps1 | ForEach-Object {
    $e = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$e)
    '{0}: {1} errors' -f $_.Name, @($e).Count
}
```

A live run's init event shows the `permissionMode` it actually used. Check it, so you know the run used the reinstalled copy and not a stale one. Per-session logs go to `<target>/.claude/state/runs/<stamp>-s<n>.jsonl`, next to a snapshot of the handoff.

To test loop behavior without a nested `claude -p`, pass `-ClaudePath` a stand-in `.ps1` that prints stream-json lines (`system/init`, `assistant`, `result`) and exits with the code you want. Have it write `.claude/state/rotate.flag` to simulate the guard forcing a rotation. For until-done behavior, have it also write a real handoff entry with `Add-RunHandoffEntry.ps1` (vary `-NextLabel`, `-SafeToProceed`, `-Owner`; `DONE` as the label ends the run), optionally commit, and for the usage-limit path emit a `result` with `is_error: true` and text containing "usage limit". Run it in a throwaway git repo so the commit-based progress check is exercised.

## Run log and report

- `Start-AgentLoop.ps1` appends to `<target>/.claude/state/agent-loop.log.jsonl` (override with `-LogPath`). Every line has `ts`, `type` and `runId`. The types are `loop-start`, `message` (each assistant text shown in the terminal, with `session` and `sessionId`), `session` (outcome `rotated|finished|done|failed`, success, turns, `costUsd`, `durationSec`, denials, raw log path) and `loop-end` (stop reason and totals). An interrupted run has no `session` or `loop-end` lines; the viewer shows it as incomplete.
- At loop end it runs `Invoke-LoopSummary.ps1` (skip with `-NoSummary`; model `-SummaryModel`, default `sonnet`). That script writes `runs/<runId>-summary-digest.md`, which holds the run's messages with the old code-page-437 mojibake repaired, the tool errors pulled from the raw stream logs, the handoff entries, and git facts. It then makes one `claude -p --json-schema loop-summary.schema.json` call. The call reads `LoopSummaryPrompt.md` from stdin, has only Read, Grep and Glob, runs with `disableAllHooks` (so the Stop guard can't demand a handoff) and `--strict-mcp-config`, and saves no session. It appends a `summary` line (`summary` object, or `error`) to the loop log, and the report renders that as the run's summary panel plus an "Open issues" KPI. Use `-DigestOnly` to build the digest without a model call. Test it with a stand-in `-ClaudePath` that prints `{"type":"result",...,"structured_output":{...}}`.
- The loop sets `[Console]::OutputEncoding` to UTF-8 while it runs claude. Before that, PowerShell decoded claude's UTF-8 output as code page 437, so the logs show `ΓÇô` for an en dash.
- Then it prints a session table and runs `New-AgentLoopReport.ps1`. That script embeds the log in `AgentLoopReport.html` and writes `agent-loop-report.html` next to the log. It escapes `</` as `<\/` so logged text can't close the data tag.
- `New-AgentLoopReport.ps1 -HandoffLogPath` also embeds the entries of `handoff-log.json` (written by `~/.claude/scripts/Add-RunHandoffEntry.ps1` next to the handoff file), flattened to one JSON line each. The loop passes that path. Each handoff entry has `type: "handoff"`. Inside a loop run, the script also records `runId` and `session`, read from `AGENT_LOOP_RUN_ID` and `AGENT_LOOP_SESSION`, which `Start-AgentLoop.ps1` sets. The report shows such an entry under its session as well as in the "Handoff entries" list.
- `AgentLoopReport.html` is a standalone page with no dependencies. With nothing embedded, it opens a log through the file picker or drag-and-drop. It first tries the input as a single JSON document (a `handoff-log.json` with an `entries` array, or a plain array), then falls back to JSONL. Entries without a `type` that have a `recordedAt` are treated as handoff entries. Before this change, a pretty-printed `handoff-log.json` came out as every line "unreadable". The browser tool won't open `file://` URLs, so serve the folder on `127.0.0.1` to check it there.

## How the pieces fit

- **`Install-AgentLoop.ps1`** copies the runtime files (loop, guard, resolver, report script, HTML template, and the summarizer's script, prompt and schema) to `~/.claude/agent-loop`. It merges `PostToolUse` (matcher `*`) and `Stop` hooks that call `context-guard.ps1` into user-level `~/.claude/settings.json`: it backs the file up first and skips the merge if a `context-guard.ps1` hook is already there. It writes `Start-Agent` into the profile between the `# >>> agent-loop >>>` and `# <<< agent-loop <<<` markers, so re-running replaces the block.
  - `Start-Agent` is a double-quoted here-string. `` `$ `` stays literal in the profile, and `$(...)` (the installed script paths) expands at install time. Keep that escaping intact when editing it.
  - `Start-Agent` moves to the git root, can save `-HandoffFile` to `<repo>/.claude/agent-loop.json`, adds `.claude/state/` to `.gitignore`, and passes `--allowedTools` to the loop.
- **`Start-AgentLoop.ps1`** finds the CLI (`-ClaudePath`, then `$env:CLAUDE_EXE`, then PATH, then the usual Windows install paths). Each iteration it deletes `rotate.flag` and runs `claude -p <Prompt> --permission-mode <mode> --output-format stream-json --verbose --add-dir ~/.claude/handoffs`, then prints assistant text, the result summary, and `permission_denials`.
  - The loop stops on a non-zero exit or a missing `result` event, when `rotate.flag` is absent (the task finished under the limit), or when the handoff's top entry says DONE (`Status: DONE|COMPLETE` in the header or top entry, a `(DONE next)` label, or a Next line starting with `DONE`, case-sensitive). Otherwise it rotates.
  - `-UntilDone` makes a `finished` session continue instead. It then stops on `done`, `blocked` (top entry `Safe to proceed: no`, or Owner not "nothing" with `-StopOnOwnerItems`), `stalled` (`-StallSessions` finished sessions in a row where the top entry didn't change, or its label stayed the same with no new commit), `failed` after `-MaxConsecutiveFailures` in a row, `rate-limited` (result text matches a usage-limit pattern; `-RateLimitWaitMinutes` > 0 sleeps and retries up to `-MaxRateLimitWaits`), `cost-cap` or `token-cap`. With the default `/handoff` prompt it appends `-UntilDoneSteer` (one item per session, park owner questions, write `-NextLabel DONE` when the roadmap is finished).
  - `Get-HandoffBrief` parses the top entry of an `Add-RunHandoffEntry.ps1` style handoff (heading label, Did, Next, Owner, Safe to proceed) or the sections of a session-hygiene style one. After every session the loop prints a brief from it plus the decision, the commit delta and the running budget, and the `session` log line carries `tokens`, `decision`, `headBefore`/`headAfter` and the `handoff*` fields; the report shows them in the session detail panel.
  - Startup overhead, as of 2026-11-08:
    - **MCP:** by default the loop passes `--strict-mcp-config --mcp-config .claude/state/mcp-none.json`, an empty server list. `-McpConfig <file>` loads only that file, and `-KeepMcp` passes nothing extra.
    - **Hygiene hook:** unless `-KeepHygieneInjection` is set, the loop sets these:
      - `CLAUDE_HYGIENE_MAP`, pointing at `.claude/state/hygiene-map.json`, which maps the repo to its handoff;
      - `CLAUDE_HYGIENE_HANDOFF_MAX_AGE_DAYS=0`, so there is no SessionStart injection;
      - `CLAUDE_HYGIENE_SOFT_TOKENS` and `CLAUDE_HYGIENE_HARD_TOKENS`, set to the loop's limits.
    - **Guard limits:** it sets `AGENT_LOOP_SOFT_TOKENS` and `AGENT_LOOP_HARD_TOKENS` from `-SoftLimit` and `-HardLimit` (170k/190k), and the guard reads them.
    - **Env restore:** a `try/finally` puts back every env var it set and `[Console]::OutputEncoding`. `Start-Agent` runs in the caller's shell, so they leaked before.
    - **Metrics:** `Get-StartupMetrics` parses each raw stream log, main chain only (it skips `parent_tool_use_id`), into the `session` line's `startup` field. That field holds `firstCallCtx`, `firstEditCall`, `ctxAtFirstEdit`, `resultCharsBeforeEdit`, `toolCalls`, `repeatedReads`, `tools` and `mcpServers`. The report shows it as a KPI tile and a detail row.
    - **Baseline**, from 16 MyFinancialLedger sessions before the change: ~50k at the first call, ~75k at the first edit (around call 21), and 36 MCP servers.
    - **Unverified:** whether strict MCP also drops claude.ai connectors and plugin servers. The first live run's `mcpServers` count answers it.
  - `tests/Test-AgentLoop.ps1` runs 19 stand-in scenarios through `tests/Fake-Claude.ps1`:
    - default stop, rotation, until-done happy path, stall, blocked, owner parked vs stop, cost and token caps, failure retry, usage-limit stop and wait, and session cap;
    - `startup-defaults`, `startup-optout` and `startup-mcpconfig`, which check the CLI args, the env vars, the metrics, and that no env var leaks.

    Fake-Claude writes each call's args and env to `.claude/state/fake-call-<n>.json`. A step with `startup: true` emits a usage-bearing tool sequence. A scenario can carry a `check` scriptblock `param($lines, $dir)` that returns problem strings. Each scenario is a throwaway git repo under `%TEMP%\agent-loop-tests` with a seeded handoff. Run it after any change to the loop's decisions: `pwsh -NoProfile -File tests\Test-AgentLoop.ps1`, exit code is the failure count.
  - It sets `TK_DISABLE=1`, because the tk rewrite hook wraps commands in `{ ... }`, so allowlist rules stop matching them and `-p` has no human to approve them.
- **`context-guard.ps1`** is the hook. It keeps per-session state in `<root>/.claude/state/<session_id>.json`, with the start time stored as `DateTime` ticks on purpose.
  - On `PostToolUse` it reads the tail of the transcript and adds up the last main-chain assistant `usage` (input, cache creation, cache read, and output tokens). At `SoftLimit` (170k) it writes `rotate.flag` and blocks with a "finish the step, write the handoff, stop" message. It warns once, and again on every tool call past `HardLimit` (190k). `AGENT_LOOP_SOFT_TOKENS` and `AGENT_LOOP_HARD_TOKENS` override both limits.
  - On `Stop` it blocks once (respecting `stop_hook_active`) if the handoff wasn't written after the session started.
  - It always exits 0, even when it fails, and reports errors on stderr. A guard failure must never break the agent.
- **`Resolve-HandoffFile.ps1`** is shared by the loop and the guard. It resolves the handoff in this order: an explicit value, then `handoffFile` in `.claude/agent-loop.json`, then the first case-insensitive match for `current-handoff.md`, `docs/current-handoff.md`, or `.claude/current-handoff.md`, then a default of `current-handoff.md`. The result is relative to the repo root.
- **`Settings.hooks`** is a reference per-project hook config. It points at `$CLAUDE_PROJECT_DIR/.claude/hooks/context-guard.ps1` and adds a `SessionStart` (`clear`) hook that prints `current-handoff.md`. The installer doesn't use it; it writes user-level hooks that point at the installed copy instead.

## Known issues and decisions

- The default permission mode is `auto` in both the loop and `Start-Agent`, and their `ValidateSet`s match the CLI's choices. `acceptEdits` with the narrow default `-Tools` allowlist caused denials on `git`, `npx`, and compound commands in headless runs. If denials remain, check whether the `rtk` hook's `git` → `rtk git` rewrite is involved.
- The `Stop` guard is registered at user level, so it also fires in interactive sessions outside loop runs. The proposed fix, not yet made, is to gate it on an env var set by `Start-AgentLoop.ps1`.

## Handoff for this repo

`current-handoff.md` here is this repo's own run handoff, newest entry first. Read its top entry before you pick up work. Write new entries with `Add-RunHandoffEntry.ps1 -HandoffPath .\current-handoff.md -SkipProgress` (no git, no roadmap).
