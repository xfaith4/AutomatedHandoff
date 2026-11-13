# AutomatedHandoff

A context-rotation loop for long, unattended Claude Code runs.

It runs `claude -p /handoff` headless against a target repository. When a session's context passes a token limit, a hook tells the agent to finish its current step, write a handoff, and stop. The outer loop then starts a fresh session, which picks up from that handoff. The work continues across as many sessions as it needs, and no session runs into auto-compaction.

## How it works

```text
Start-Agent <repo>
  └─ Start-AgentLoop.ps1 ──► claude -p /handoff  (session 1)
                               │  PostToolUse hook: context-guard.ps1
                               │    context ≥ 170k tokens → write rotate.flag,
                               │    tell the agent to write the handoff and stop
                               ▼
                             session ends
     rotate.flag present and handoff not DONE? ──► claude -p /handoff  (session 2) ...
     otherwise ──► stop, print a session table, build the HTML report
```

The loop stops when any of these happens:

- A session finishes without hitting the limit (no `rotate.flag`). With `-UntilDone` this continues instead; see [Until-done mode](#until-done-mode).
- The handoff's top entry says DONE: a `Status: DONE` or `Status: COMPLETE` line, a `(DONE next)` label, or a Next line that starts with `DONE`.
- A session exits non-zero or emits no `result` event.
- The result is a usage-limit error. With `-RateLimitWait` the loop sleeps and starts a new session instead.
- `-Max` sessions have run.

After every session the loop prints a brief: the outcome, the decision it made and why, the top handoff entry's Did / Next / Safe / Owner lines, whether a commit landed, and the running budget.

## Requirements

- PowerShell 7. The scripts use `??` and `[IO.Path]::GetRelativePath`.
- The Claude Code CLI. The loop looks for it via `-ClaudePath`, then `$env:CLAUDE_EXE`, then `PATH`, then the usual Windows install locations.
- A `/handoff` slash command in `~/.claude/commands/handoff.md`. Each session runs it to read the handoff and continue from its next action.
- Optional: `~/.claude/scripts/Add-RunHandoffEntry.ps1`, which writes the `handoff-log.json` entries that the report shows under each session.

## Install

The files in this folder are the source. The installer copies the runtime files to `~/.claude/agent-loop/`, registers the hooks, and adds a `Start-Agent` alias to your PowerShell profile:

```powershell
pwsh -NoProfile -File .\Install-AgentLoop.ps1
. $PROFILE
```

You run this once. The alias points at the installed `Start-Agent.ps1`, and the installer records this folder in `~/.claude/agent-loop/install.json`. Each `Start-Agent` call first copies any changed runtime files from this folder (`Install-AgentLoop.ps1 -FilesOnly`), so edits here take effect on the next run without a reinstall. If a source script fails to parse, nothing is copied and the installed copy runs, with a warning. `Start-Agent -NoUpdate` skips the sync, and `Start-Agent -UpdateOnly` syncs without starting a run. The sync copies the working tree as it is, uncommitted edits and the checked-out branch included.

| Parameter | Default | Purpose |
| --- | --- | --- |
| `-ToolsDir` | `~/.claude/agent-loop` | Where the runtime files go. |
| `-ProfilePath` | `$PROFILE` | Profile that gets `Start-Agent`. The VS Code terminal loads `Microsoft.VSCode_profile.ps1`, so pass that path if you run from VS Code. |
| `-SkipHooks` | off | Don't touch `~/.claude/settings.json`. Use it on reinstalls. |
| `-FilesOnly` | off | Copy only the runtime files that differ, and output their names. No hooks, profile or `install.json`. `Start-Agent` calls it this way. |

The installer:

- backs up `~/.claude/settings.json` before merging `PostToolUse` and `Stop` hooks that call `context-guard.ps1`, and skips the merge if those hooks already exist;
- writes `Start-Agent` between `# >>> agent-loop >>>` and `# <<< agent-loop <<<` markers, so re-running it replaces the block instead of adding a second one.

Edits to the source files have no effect until you reinstall.

## Usage

```powershell
Start-Agent F:\Development\MyRepo -Max 8
Start-Agent                                   # current folder
Start-Agent . -HandoffFile docs\CURRENT-HANDOFF.md
```

| Parameter | Default | Purpose |
| --- | --- | --- |
| `-Repo` (positional) | current folder | Target repository. Moves up to the git root. |
| `-Max` | `10` | Maximum number of sessions. |
| `-UntilDone` | off | Keep starting sessions after each finished item until the handoff says DONE, is blocked, or stalls. |
| `-MaxCost` | `0` (none) | Stop once the summed estimated cost of the run reaches this many USD. |
| `-MaxTokens` | `0` (none) | Stop once the summed input, cache and output tokens reach this count. |
| `-RateLimitWait` | `0` (stop) | Minutes to sleep after a usage-limit result before starting a new session. Up to three waits per run. |
| `-Mode` | `auto` | Permission mode: `auto`, `acceptEdits`, `manual`, `dontAsk`, `plan`, or `bypassPermissions`. |
| `-Prompt` | `/handoff` | Prompt each session starts with. |
| `-HandoffFile` | auto-discovered | Handoff path, relative to the repo. Saved to `.claude/agent-loop.json` for later runs. |
| `-Tools` | `Bash(pwsh:*)`, `Edit`, `Write`, `Read`, `Glob`, `Grep` | Passed as `--allowedTools`. |
| `-ExtraArgs` | none | Extra CLI arguments, for example `'--model','opus'`. |
| `-SoftLimit` | `170000` | Context tokens at which the guard forces a rotation. |
| `-HardLimit` | `190000` | Past this, the guard repeats its warning on every tool call. Must be above `-SoftLimit`. |
| `-McpConfig` | none | Load only the MCP servers in this file. Without it, sessions load none. |
| `-KeepMcp` | off | Load the usual MCP servers. Every session pays their fixed context cost. |
| `-KeepHygieneInjection` | off | Let the session-hygiene hook inject its own handoff and enforce its own budget too. |

`Start-Agent` also adds `.claude/state/` to the repo's `.gitignore` and warns if no handoff file exists yet.

Headless runs have no one to approve a permission prompt, so any denied tool call is printed after each session. In `acceptEdits` mode with the narrow default `-Tools` list, `git`, `npx`, and compound shell commands get denied; `auto` mode avoids most of that.

### Where the handoff is found

`Resolve-HandoffFile.ps1` checks these in order and returns the first hit:

1. An explicit `-HandoffFile` value.
2. `handoffFile` in `<repo>/.claude/agent-loop.json`.
3. The first case-insensitive match for `current-handoff.md`, `docs/current-handoff.md`, or `.claude/current-handoff.md`.
4. A default of `current-handoff.md`.

## Until-done mode

By default one `/handoff` session does one Next item and the loop stops when that session ends cleanly. `-UntilDone` turns the loop into a roadmap driver: each session still does one item, and the loop keeps starting sessions until there is nothing left to do.

```powershell
Start-Agent F:\Development\MyRepo -UntilDone -Max 20 -MaxCost 60 -RateLimitWait 30
```

The prompt gets a steer appended (`-UntilDoneSteer` on the loop script, blank to send `/handoff` unchanged): do exactly one roadmap item, park owner questions in the handoff's Owner line and take the next unblocked item, write `Safe to proceed: no` when nothing is unblocked, and write the entry with `-NextLabel DONE` when the roadmap is complete.

The loop reads the handoff's top entry after every session and decides:

| Outcome | What it means | Loop does |
| --- | --- | --- |
| `finished` | Item done under the limit, handoff updated | Starts the next session |
| `rotated` | Context guard forced a rotation mid-item | Starts the next session |
| `done` | Top entry says DONE | Stops |
| `blocked` | Top entry says `Safe to proceed: no` (or Owner is not "nothing", with `-StopOnOwnerItems`) | Stops for the owner |
| `stalled` | `-StallSessions` (2) finished sessions in a row with no progress | Stops |
| `failed` | Non-zero exit or no result | Retries, stops after `-MaxConsecutiveFailures` (2) in a row |
| `rate-limited` | Usage-limit or overload result | Sleeps `-RateLimitWaitMinutes` then retries, or stops |

Progress means the top entry changed and either its `(label next)` moved or a new commit landed. An agent that keeps re-auditing the same item without committing trips the stall guard. The `-MaxCostUsd` and `-MaxTokens` caps are checked before every new session; on a subscription they are budget proxies, since the CLI's cost figure is an estimate at API prices and the subscription meters the same tokens.

Owner questions do not stop the run unless you pass `-StopOnOwnerItems`. They accumulate in the handoff entries and show in each session's brief in yellow.

## Startup overhead

Each fresh session pays a fixed context cost before it does any work. That is the system prompt, the tool definitions, the MCP servers, and whatever the hooks inject. The loop sets up each session to keep that cost low:

- **No MCP servers by default.** Sessions run with `--strict-mcp-config` and an empty server list, written to `.claude/state/mcp-none.json`. In 16 MyFinancialLedger sessions measured before this change, 36 servers and 89 tools came to about 50k tokens at the first call. Pass `-McpConfig <file>` for the servers a repo really needs, or `-KeepMcp` for the usual set.
- **One handoff, not two.** The loop sets these for its sessions:
  - `CLAUDE_HYGIENE_MAP` points the session-hygiene hook at the repo handoff.
  - `CLAUDE_HYGIENE_HANDOFF_MAX_AGE_DAYS=0` turns off that hook's SessionStart injection, which had put a stale home-folder handoff into every session.
  - `CLAUDE_HYGIENE_SOFT_TOKENS` and `CLAUDE_HYGIENE_HARD_TOKENS` are set to the loop's limits.

  `-KeepHygieneInjection` restores the hook's own behavior.
- **More room to work.** The guard rotates at 170k (was 160k). Before this change, sessions reached their first edit at 60k–120k of context, so 160k left too little room for the edits themselves. Auto-compaction is near 200k, and the gap above 190k is kept for the wrap-up.
- **A pointed rotation message.** It asks the agent to name the exact files and roadmap section the next step needs, so the next session reads only those.

The loop restores every env var it sets, and the console encoding, when it ends. That includes Ctrl+C. `Start-Agent` runs the loop in your shell, and before this fix `AGENT_LOOP_RUN_ID` leaked into later interactive sessions.

Each session's startup is measured from its raw stream log. Only the main chain counts; subagent traffic is skipped.

| Field | Meaning |
| --- | --- |
| `firstCallCtx` | Context tokens at the first assistant turn: the fixed overhead. |
| `firstEditCall`, `ctxAtFirstEdit` | Which tool call made the first `Edit`, `Write`, `MultiEdit` or `NotebookEdit`, and the context at that point. |
| `resultCharsBeforeEdit` | Characters of tool output the agent read before that edit. |
| `toolCalls`, `repeatedReads` | Main-chain tool calls, and reads of the same file with the same offset and limit. |
| `tools`, `mcpServers` | Counts from the init event. |

The brief after each session prints these on a `Startup` line, and the `session` log line carries them as `startup`. The report shows the median in a "Startup context" tile and the per-session values in the detail panel. Compare runs with these numbers before you claim a change helped.

## Context guard

`context-guard.ps1` runs as a hook in every session:

- **PostToolUse:** reads the transcript tail and adds up the last assistant turn's token usage. At 170k tokens (`-SoftLimit`) it writes `rotate.flag` and blocks with a "finish the step, write the handoff, stop" message. Past 190k tokens (`-HardLimit`) it repeats the warning on every tool call. A loop run overrides both limits through `AGENT_LOOP_SOFT_TOKENS` and `AGENT_LOOP_HARD_TOKENS`, because the hook is registered once, at user level.
- **Stop:** blocks the stop once if the handoff hasn't been written since the session started.

The guard always exits 0 and reports its own errors on stderr, so a fault in the guard never breaks the agent.

## Logs and report

Everything is written under `<repo>/.claude/state/`:

| Path | Contents |
| --- | --- |
| `agent-loop.log.jsonl` | One JSON object per line: `loop-start`, `message`, `session`, and `loop-end` events. |
| `runs/<stamp>-s<n>.jsonl` | Raw stream-json output of each session, next to a snapshot of its handoff. |
| `agent-loop-report.html` | Standalone report built at the end of every loop. |
| `<session_id>.json`, `rotate.flag` | Guard state. |
| `mcp-none.json`, `hygiene-map.json` | The empty MCP config and the hygiene-hook handoff map that the loop passes to each session. |

The report shows per-session outcome (`rotated`, `finished`, `done`, `failed`), turns, cost, duration, startup cost, permission denials, and the handoff entries each session wrote. An interrupted run shows as incomplete.

To rebuild a report by hand:

```powershell
pwsh -File ~/.claude/agent-loop/New-AgentLoopReport.ps1 -LogPath .\.claude\state\agent-loop.log.jsonl
```

`AgentLoopReport.html` also works on its own: open it in a browser and drop in an `agent-loop.log.jsonl` or `handoff-log.json` file.

## Files

| File | Role |
| --- | --- |
| `Install-AgentLoop.ps1` | Installs the runtime files, the hooks, and the `Start-Agent` alias. |
| `Start-Agent.ps1` | What `Start-Agent` runs: syncs from source, then starts `Start-AgentLoop.ps1` against the repo. |
| `Start-AgentLoop.ps1` | The outer loop. |
| `context-guard.ps1` | `PostToolUse` and `Stop` hook. |
| `Resolve-HandoffFile.ps1` | Handoff path resolution, shared by the loop and the guard. |
| `New-AgentLoopReport.ps1` | Embeds the run log and handoff entries into the report template. |
| `AgentLoopReport.html` | Report template and standalone viewer. |
| `Settings.hooks` | Reference per-project hook config. The installer doesn't use it. |
| `tests/Test-AgentLoop.ps1` | Runs the loop's stop and continue decisions through a stand-in CLI, `tests/Fake-Claude.ps1`. |

## Known limitations

- The `Stop` guard is registered at user level, so it also fires in interactive sessions outside loop runs. Gating it on `AGENT_LOOP_RUN_ID`, which the loop sets, is the planned fix.
- The checks are a zero-error parse of every `.ps1` file, the stand-in scenarios in `tests/`, and a live run; see [CLAUDE.md](CLAUDE.md). The until-done decisions have been exercised only against the stand-in CLI, not a live roadmap run.
- A usage-limit wait counts as a session against `-Max`. The reset time in the CLI's message is not parsed; the wait is the fixed `-RateLimitWait`.
