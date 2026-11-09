# AutomatedHandoff — Current Handoff

> Active operational context only. Newest entry first.

## 2026-11-08 — Startup-overhead docs and report check (live-startup-check next)

- **Did:** README.md: Startup overhead section, new Start-Agent params, 170k/190k guard, state files. CLAUDE.md: startup-overhead notes, 19 scenarios, 170k/190k. Project memory saved with the repo goal.
- **Verified:** Report from the startup-defaults stand-in run served on 127.0.0.1: Startup context KPI (30k, first edit at 36k call 4) and the detail row render, no console errors. Scripts unchanged since the 19/19 run. Not verified: a live run, and whether strict MCP drops claude.ai connectors.
- **Progress:** skipped (-SkipProgress)
- **Safe to proceed:** yes; all work is uncommitted on main (only the initial commit exists)
- **Next:** Ben reinstalls and runs Start-Agent MyFinancialLedger -Max 1, then compares the Startup line with the baseline. After that, the review.md snapshot work (Add-RunHandoffEntry snapshot plus atomic write plus prev, /handoff drift injection), or commit-and-pr
- **Owner:** Reinstall and live check; approve the review.md snapshot work and the ledger handoff trim; decide whether to commit this work

## 2026-11-08 — Startup-overhead changes built: no MCP by default, 170k/190k budget, hygiene on repo handoff, startup metrics (startup-overhead-docs next)

- **Did:** Start-AgentLoop.ps1: new -SoftLimit 170000 -HardLimit 190000 (exported as AGENT_LOOP_SOFT/HARD_TOKENS), --strict-mcp-config with empty .claude/state/mcp-none.json by default (-McpConfig file, -KeepMcp opt-outs), hygiene hook pointed at the repo handoff via .claude/state/hygiene-map.json with CLAUDE_HYGIENE_HANDOFF_MAX_AGE_DAYS=0 (no SessionStart injection) and hygiene soft/hard = loop limits (-KeepHygieneInjection opt-out), Get-StartupMetrics -> session.startup (firstCallCtx, firstEditCall, ctxAtFirstEdit, resultCharsBeforeEdit, toolCalls, repeatedReads, mcpServers, tools; main chain only) printed in the session brief, body wrapped in try/finally restoring all env vars and OutputEncoding (AGENT_LOOP_RUN_ID used to leak into the shell). context-guard.ps1: defaults 170k/190k, env override, rotation message asks for exact files and roadmap section. Install-AgentLoop.ps1: Start-Agent passes -SoftLimit -HardLimit -McpConfig -KeepMcp -KeepHygieneInjection. AgentLoopReport.html: Startup context KPI (medians) and Startup row in session detail. tests: Fake-Claude records args/env per call and has a startup step; Test-AgentLoop has per-scenario checks and 3 new scenarios.
- **Verified:** Parse of all *.ps1 and tests\*.ps1: 0 errors. tests\Test-AgentLoop.ps1: 19 scenarios, 0 failed (18 in full run, startup-defaults after fixing a test-only Count bug). Not verified: live run; whether --strict-mcp-config also drops claude.ai connectors and plugin MCP servers (check mcpServers in the session brief); report HTML not opened in a browser; README.md and CLAUDE.md not yet updated.
- **Progress:** skipped (-SkipProgress)
- **Safe to proceed:** yes; changes are in source only, installed copy unchanged until Ben reinstalls
- **Next:** Update README.md and CLAUDE.md (new params, startup metrics, hygiene env, 170k/190k, env restore); serve the folder on 127.0.0.1 and check the report renders the Startup KPI against a log with a startup field; then the review.md snapshot work (Add-RunHandoffEntry replace-snapshot, /handoff injection and drift report).
- **Owner:** Reinstall (pwsh -NoProfile -File <abs>\Install-AgentLoop.ps1 -SkipHooks -ProfilePath <VS Code profile>, and the plain profile), then run Start-Agent F:\Development\20_Staging\Financial\MyFinancialLedger -Max 1 and compare the Startup line (baseline ~50k at first call, ~75k at first edit, 36 MCP servers).

## 2026-11-08 — Measured where loop startup context goes; token-limit recommendation (startup-overhead next)

- **Did:** No files changed. Ledger loop logs: about 50k tokens of fixed overhead at the first call in every session (89 tools, 36 MCP servers incl. Slack/Gmail/Snowflake, skills list, CLAUDE.md, rules); tool results before the first edit only 71-145k chars (about 18-36k tokens). Model claude-opus-5-5, standard window. Recommended: loop runs with --strict-mcp-config and a minimal MCP config; raise guard to soft 170k / hard 190k and set CLAUDE_HYGIENE_HARD_TOKENS to match in loop runs; log firstCallCtx and ctxAtFirstEdit per session.
- **Verified:** Parsed 16 runs/*-s*.jsonl init and usage events. Overhead split (MCP vs skills vs system prompt) not measured; needs a one-session A/B run by Ben.
- **Progress:** skipped (-SkipProgress)
- **Safe to proceed:** yes; nothing changed
- **Next:** If Ben approves: add -StrictMcp (default on) and -McpConfig to Start-AgentLoop.ps1, raise context-guard limits, export CLAUDE_HYGIENE_HARD_TOKENS, add startup metrics to the session log line; extend tests\Test-AgentLoop.ps1.
- **Owner:** Approve the startup-overhead changes; then run one Start-Agent session on the ledger to measure firstCallCtx with strict MCP.

## 2026-11-08 — Mapped review.md onto the handoff script, /handoff command and agent loop (review-handoff-plan next)

- **Did:** No files changed. Analysis only: review.md items 1-7 mapped to Add-RunHandoffEntry.ps1 (replace snapshot, auto-captured git fields, atomic writes), commands/handoff.md (inject snapshot and drift report via !, single authority, progressive reads, no inherited approvals), and Start-AgentLoop.ps1 (startup-cost metrics). Baseline from 16 MyFinancialLedger loop logs: 10-26 tool calls and 60k-120k context before first Edit/Write; ledger CURRENT-HANDOFF.md is 1084 lines, 98 entries.
- **Verified:** Baseline computed by parsing runs/*-s*.jsonl tool_use events. No code written or tested.
- **Progress:** skipped (-SkipProgress)
- **Safe to proceed:** yes; nothing changed
- **Next:** Waiting on Ben to pick the order: step 1 (startup-cost metrics in the loop session log and report) or the approved commit-and-pr item first.
- **Owner:** Choose order: handoff optimization vs commit-and-pr. Approve any later trim of the ledger CURRENT-HANDOFF.md after archive check.

## 2026-11-07 — Answered: until-done command for the LED repo (commit-and-pr next)

- **Did:** No files changed. Gave Ben the until-done command for F:\Development\20_Staging\300PixelLED_2812B: Start-Agent <repo> -UntilDone -Max 20 -MaxCost 60 -RateLimitWait 30. Noted the plain PowerShell profile still has the stale Start-Agent without -UntilDone (VS Code profile is current).
- **Verified:** Installed Start-AgentLoop.ps1 and the VS Code profile contain UntilDone; Microsoft.PowerShell_profile.ps1 does not. LED repo has docs/CURRENT-HANDOFF.md and ROADMAP.md, clean tree, no agent-loop.json. Nothing run.
- **Progress:** skipped (-SkipProgress)
- **Safe to proceed:** yes; no changes made
- **Next:** Build the commit-and-pr item (top entry below): run branch at loop start, Max-2 reservation, PR session, failure scan, repair session, starting in Start-AgentLoop.ps1.
- **Owner:** Reinstall Start-Agent into Microsoft.PowerShell_profile.ps1 if running outside VS Code; run the until-done command on the LED repo.

## 2026-11-06 — Owner approved commit-per-item, final PR session, and one repair session (commit-and-pr next)

- **Did:** No code changed; context limit reached. Decision recorded for the next session to build.
- **Verified:** nothing to verify
- **Progress:** skipped (-SkipProgress)
- **Safe to proceed:** yes; design approved, no uncommitted work here
- **Next:** Build -CommitEachItem / -PullRequest in Start-AgentLoop.ps1 and Start-Agent. Spec: (1) at loop start, if enabled, create and switch to branch agent-loop/<runId> from HEAD (refuse if tree dirty unless -AllowDirty); (2) steer appends "commit each completed item on the current branch with a conventional message; never touch main"; (3) reserve 2 sessions of -Max (and the same share of -MaxCost/-MaxTokens): item sessions run to Max-2, then a PR session with prompt "push the branch and open a PR to main with gh pr create; body = summary of all handoff entries this run plus git log base..HEAD; this PR is the final summary and change request"; (4) after the PR session, scan the run: failed sessions, tool errors from the raw stream logs (reuse the extraction in Invoke-LoopSummary.ps1), push/gh failures, and handoff entries with Safe to proceed: no. If any, run exactly one repair session with those findings in the prompt: fix, commit, push, gh pr edit the body. (5) Log pr URL, branch, repair findings on loop-end; show in brief, table and report. (6) Add stand-in scenarios: pr-created, repair-triggered, repair-skipped, dirty-tree-refused (Fake-Claude must fake gh or the loop takes -GhPath). Also: a usage-limit wait no longer counts against -Max (owner silent, keep current behavior until asked).
- **Owner:** nothing

## 2026-11-06 — Until-done live check passed on 300PixelLED_2812B (commit-per-item steer (optional) next)

- **Did:** No loop code changed. Live run 20261106-224004: 3 sessions, E0 items 2-4 done, each session continued after its brief, stopped at max-sessions, $13.72 of $15 cap, 6.2M tokens. CLAUDE.md: note on the two profile files and absolute installer path (the first attempt failed on a stale Start-Agent in Microsoft.PowerShell_profile.ps1).
- **Verified:** Live run output read end to end: briefs printed per session, decision lines correct, budget line correct, summary and report produced. Not verified: stall and rate-limit paths against the real CLI; commit-based progress never fired because /handoff treats committing as an owner task.
- **Progress:** skipped (-SkipProgress)
- **Safe to proceed:** yes; nothing uncommitted here (not a git repo)
- **Next:** Optional: add a -CommitEachItem steer (or document the -Prompt variant) so unattended runs commit per item and the commit-based progress check can fire. Otherwise no engineering next; the mode is live.
- **Owner:** Decide whether unattended runs may commit per item. Whether a usage-limit wait should count against -Max.

## 2026-11-06 — Until-done mode: drive a roadmap to completion with guards and per-session briefs (until-done live check next)

- **Did:** Start-AgentLoop.ps1: -UntilDone (continue after finished sessions), -UntilDoneSteer appended to /handoff, outcomes done/blocked/stalled/failed/rate-limited/cost-cap/token-cap, Get-HandoffBrief parses the top entry, per-session brief and budget printed, session log rows carry tokens/decision/head sha/handoff fields. AgentLoopReport.html: new outcome tones and detail fields. Install-AgentLoop.ps1: Start-Agent gained -UntilDone -MaxCost -MaxTokens -RateLimitWait. tests/Test-AgentLoop.ps1 + tests/Fake-Claude.ps1: 16 stand-in scenarios. README.md and CLAUDE.md updated.
- **Verified:** Parse: 8 scripts, 0 errors. tests\Test-AgentLoop.ps1: 16 scenarios, 0 failed. Installer rendered Start-Agent into a scratch profile: 0 parse errors, new params pass through. node --check on the report inline script: ok. README markdownlint clean. Not verified: a live until-done run against a real roadmap, and whether a real usage-limit result matches the rate-limit regex.
- **Progress:** skipped (-SkipProgress)
- **Safe to proceed:** yes; source edited only, installed copy in ~/.claude/agent-loop is stale until Ben reinstalls
- **Next:** Ben: reinstall (pwsh -NoProfile -File .\Install-AgentLoop.ps1 -SkipHooks -ProfilePath "$HOME\OneDrive\Documents\PowerShell\Microsoft.VSCode_profile.ps1"; . $PROFILE), then a live run: Start-Agent <repo> -UntilDone -Max 3 -MaxCost 15. Check the per-session briefs and that a finished session continues.
- **Owner:** Reinstall and run the live check. Decide whether a usage-limit wait should count against -Max (it does now).

## 2026-11-06 — Answered why a -Max 3 run stopped after one session (loop-until-done (optional) next)

- **Did:** No files changed. Explained that -MaxSessions is a cap, not a target: Start-AgentLoop.ps1 line 121 marks a session finished when rotate.flag is absent and breaks the loop; the 300PixelLED_2812B run ended at 17 turns under the 160k soft limit, so no rotation happened.
- **Verified:** Read Start-AgentLoop.ps1 lines 118-124 to confirm the outcome logic. Nothing run.
- **Progress:** skipped (-SkipProgress)
- **Safe to proceed:** yes; no changes, nothing uncommitted
- **Next:** If Ben wants the loop to continue until the handoff says DONE, change the finished outcome at Start-AgentLoop.ps1:121 to rotate unless Status: DONE, add an owner-gate check, then reinstall and live-check.
- **Owner:** Decide whether finished sessions should rotate until the handoff is DONE, or keep current behaviour.

## 2026-11-04 — Fix summarizer CLI lookup under StrictMode (loop-summary-live-check next)

- **Did:** Invoke-LoopSummary.ps1: test the Get-Command result before reading .Source; added the LOCALAPPDATA fallback; copied to ~/.claude/agent-loop
- **Verified:** Parse 0 errors; the lookup with no claude on PATH under StrictMode resolves ~/.local/bin/claude.exe. Real summarizer call still unverified.
- **Progress:** skipped (-SkipProgress)
- **Safe to proceed:** yes
- **Next:** Ben reruns Invoke-LoopSummary.ps1 on UnifiedAIToolbox, then New-AgentLoopReport.ps1
- **Owner:** Rerun the live summarizer call

## 2026-11-04 — End-of-run AI summary for agent-loop runs (loop-summary-live-check next)

- **Did:** New Invoke-LoopSummary.ps1, LoopSummaryPrompt.md, loop-summary.schema.json. Start-AgentLoop.ps1: calls the summarizer at loop end (-NoSummary, -SummaryModel), sets Console OutputEncoding to UTF-8 (fixes the cp437 mojibake in logs). AgentLoopReport.html: renders type:summary as a run summary panel plus an Open issues KPI. Install-AgentLoop.ps1 copies the 3 new files. CLAUDE.md updated.
- **Verified:** Parse: 0 errors in all 6 scripts. Digest-only on the UnifiedAIToolbox run 20261104-073919: 20 KB, 2 tool errors found, 0 mojibake left. Native-arg round-trip of the schema and settings JSON via python: ok. Stand-in claude success and failure paths both append a summary line. Sample summary validated with jsonschema. Both reports rendered in Chrome on 127.0.0.1 with no console errors. NOT verified: a real claude -p --json-schema call (nested headless is blocked here), so structured_output parsing against the real CLI and disableAllHooks are unconfirmed.
- **Progress:** skipped (-SkipProgress)
- **Safe to proceed:** yes; installed copy not yet updated
- **Next:** Reinstall with -SkipHooks, then run Invoke-LoopSummary.ps1 -ProjectDir UnifiedAIToolbox against run 20261104-073919 and open its agent-loop-report.html
- **Owner:** Run the reinstall and the live summarizer call

## 2026-11-02 — Create README.md for AutomatedHandoff (agent-loop-live-check next)

- **Did:** Added README.md: purpose, loop diagram, stop conditions, requirements, install and Start-Agent parameters, handoff resolution, context guard, logs/report, file map, known limitations.
- **Verified:** Docs only; no scripts changed. Parameters and defaults checked against the param blocks in Install-AgentLoop.ps1 (Start-Agent), Start-AgentLoop.ps1, context-guard.ps1 and New-AgentLoopReport.ps1. markdownlint not run.
- **Progress:** skipped (-SkipProgress)
- **Safe to proceed:** yes; documentation only, installed copies still stale until reinstall
- **Next:** Ben reinstalls (Install-AgentLoop.ps1 -SkipHooks -ProfilePath <VSCode profile>) and runs Start-Agent MyFinancialLedger -Max 1; confirm the report shows that run's handoff entry under session 1.
- **Owner:** Same as before: approve auto mode for unattended runs; scope the Stop guard to loop runs.

## 2026-11-01 — Report reads handoff-log.json (no more unreadable lines) (agent-loop-live-check next)

- **Did:** AgentLoopReport.html: parses whole-JSON docs before JSONL, renders a Handoff entries section and per-session handoffs. Add-RunHandoffEntry.ps1 (+Tests): type=handoff on every entry (backfills old ones), runId/session from AGENT_LOOP_RUN_ID/AGENT_LOOP_SESSION. Start-AgentLoop.ps1 sets those env vars and passes -HandoffLogPath; New-AgentLoopReport.ps1 embeds handoff entries as JSONL. handoff-log.json backfilled. CLAUDE.md updated.
- **Verified:** All .ps1 parse 0 errors. Pester Add-RunHandoffEntry.Tests.ps1: 10 passed 0 failed. Chrome via 127.0.0.1: handoff-log.json loads as 2 entries 0 skipped; untyped legacy doc 2 entries; JSONL with a bad line still reports 1 skipped; embedded report shows the handoff under its session and </script> survives. Not verified: live claude run.
- **Progress:** skipped (-SkipProgress)
- **Safe to proceed:** yes; installed copies in ~/.claude/agent-loop are stale until reinstall
- **Next:** Ben reinstalls (Install-AgentLoop.ps1 -SkipHooks -ProfilePath <VSCode profile>) and runs Start-Agent MyFinancialLedger -Max 1; confirm the report shows that run's handoff entry under session 1.
- **Owner:** Same as before: approve auto mode for unattended runs; scope the Stop guard to loop runs (AGENT_LOOP_RUN_ID now exists to gate on).

## 2026-11-01 — Agent-loop JSONL run log and HTML report (agent-loop-live-check next)

- **Did:** Start-AgentLoop.ps1: logs loop-start/message/session/loop-end JSONL to .claude/state/agent-loop.log.jsonl (-LogPath), prints a session table at loop end, builds the report; fixed a bug where a non-JSON stream line re-processed the previous event. New: New-AgentLoopReport.ps1, AgentLoopReport.html. Install-AgentLoop.ps1 copies both. CLAUDE.md updated.
- **Verified:** All .ps1 parse with 0 errors. Fake-claude runs (rotate->finish, fail) produced the expected log entries, outcomes, denials and terminal table. Embedded report rendered in Chrome via 127.0.0.1: KPIs, run groups, incomplete run, skipped bad line, expanded details OK. Not verified: a live claude run, and the empty template opened directly from file://.
- **Progress:** skipped (-SkipProgress)
- **Safe to proceed:** yes; installed copies are stale until Ben reinstalls
- **Next:** Ben reinstalls (Install-AgentLoop.ps1 -SkipHooks -ProfilePath <VSCode profile>) and runs Start-Agent MyFinancialLedger -Max 1; confirm denials are gone and agent-loop-report.html opens.
- **Owner:** Same as before: approve auto mode for unattended runs; scope the Stop guard to loop runs.

## 2026-11-01 — Create CLAUDE.md for AutomatedHandoff (agent-loop-live-check next)

- **Did:** Added CLAUDE.md: source-vs-installed copies, reinstall and parse-check commands, loop/guard/resolver architecture, known issues.
- **Verified:** Docs only; no scripts changed. Commands in CLAUDE.md taken from existing handoff and script params; not re-run.
- **Progress:** skipped (-SkipProgress)
- **Safe to proceed:** yes; documentation only
- **Next:** Ben reinstalls (Install-AgentLoop.ps1 -SkipHooks -ProfilePath <VSCode profile>) and runs Start-Agent MyFinancialLedger -Max 1 to confirm auto mode clears the denials.
- **Owner:** Same as previous entry: approve auto mode for unattended runs; scope the Stop guard to loop runs.

## 2026-11-01 — Live check failed; switch the loop to auto permission mode (reinstall + live-check next)

- **Did:** The live `Start-Agent ... MyFinancialLedger -Max 1` run (Ben ran it) ended with 4 denials: a compound `cd; cat ~/.claude/hooks/...; head`, `git diff; node prettier --check`, `npx prettier --check`, and `git add && git commit`. Cause: the loop forced `--permission-mode acceptEdits` with an allowlist of only `Bash(pwsh:*)` and file tools, and `-p` has no one to approve anything else. The user default is already `defaultMode: auto`. `Start-AgentLoop.ps1` and `Install-AgentLoop.ps1` now default to `auto`; the ValidateSets match the CLI choices (`auto, acceptEdits, manual, dontAsk, plan, bypassPermissions`; `default` was dropped). The installer has a new `-ProfilePath` parameter, because the VS Code terminal loads `Microsoft.VSCode_profile.ps1`, not `$PROFILE` from a plain pwsh.
- **Verified:** Both scripts parse with 0 errors. A second live run at 15:14 had 5 denials, but its init event shows `permissionMode: acceptEdits`, and the installed copy and the profile still default to `acceptEdits`, so it ran before the reinstall and doesn't test the fix. Not verified: the reinstall and a live run. The session's auto classifier refused both launching a nested headless `claude -p` ("Create Unsafe Agents") and writing the profile ("Unauthorized Persistence").
- **Progress:** skipped; not a git repository, no roadmap.
- **Safe to proceed:** yes once Ben reinstalls; until then the installed copies still default to `acceptEdits`.
- **Next:** Ben runs `pwsh -NoProfile -File .\Install-AgentLoop.ps1 -SkipHooks -ProfilePath "$HOME\OneDrive\Documents\PowerShell\Microsoft.VSCode_profile.ps1"`, then `. $PROFILE`, then `Start-Agent F:\Development\20_Staging\Financial\MyFinancialLedger -Max 1`. If denials remain, check whether the `rtk hook claude` rewrite (`git` becomes `rtk git`) is involved; `Bash(rtk git *)` is already allowed.
- **Owner:** approve auto mode for unattended runs (the classifier still blocks risky actions; `acceptEdits` plus a wider `-Tools` list is the alternative). Still open: the Advisor placement for MyFinancialLedger U.4, and committing U.3 there.

## 2026-11-01 — Unblock unattended agent-loop permissions (agent-loop-live-check next)

- **Did:** `BensClaudeTokenKillerv2/hooks/tk-rewrite.ps1` (also copied to `~/.tk/hooks`): `TK_DISABLE=1` makes the hook a pass-through, with a Pester case for it. `Start-AgentLoop.ps1` (also copied to `~/.claude/agent-loop`): sets `TK_DISABLE=1`, passes `--add-dir ~/.claude/handoffs`, and prints `result.permission_denials`. `~/.claude/commands/handoff.md`: call `Add-RunHandoffEntry.ps1` on one line with `pwsh -NoProfile -File`, never `-Command` or `& { }`.
- **Verified:** `Invoke-Pester tests/Hook.Tests.ps1` passed 26, failed 0. Hook smoke test: with `TK_DISABLE=1` it emits nothing; unset, it still wraps. `Start-AgentLoop.ps1` parses with 0 errors. The denial printer was tested on a sample result JSON. `claude --help` lists `--add-dir`. Not verified: a live `Start-Agent` run.
- **Progress:** skipped (`-SkipProgress`); not a git repository, no roadmap.
- **Safe to proceed:** yes. The tk repo changes are uncommitted; that repo already had CRLF-only diffs in the same files.
- **Next:** run `Start-Agent F:\Development\20_Staging\Financial\MyFinancialLedger -Max 1`. Confirm that git commits land and that no "Permission denials" line prints. Then commit the U.3 work and revert `next-env.d.ts` if it changed.
- **Owner:** decide whether MyFinancialLedger keeps two handoffs (`docs/CURRENT-HANDOFF.md` and `~/.claude/handoffs/...`) or maps one in `handoff-paths.json`. Also decide whether the context-guard Stop hook should fire outside agent-loop runs; see the note below.

## Note: context-guard fires in every session

`Install-AgentLoop.ps1` registers `context-guard.ps1` as a user-level Stop hook, so it blocks the first stop of every interactive session in a folder with no fresh `current-handoff.md`, not only loop runs. A guard on `$env:TK_DISABLE` (or a dedicated `AGENT_LOOP` variable set by `Start-AgentLoop.ps1`) would scope it to unattended runs.
