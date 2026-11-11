# AutomatedHandoff — Current Handoff

> Active operational context only. Newest entry first.

## 2026-11-11 — A7 recorded from live -NoBrief run 20261111-064504; X2 multi-result logging bug found (B1 next)

- **Did:** ROADMAP.md: A7 stamped [x] with numbers; strict-MCP known issue marked answered (mcpServers 0); new X2 [non-blocker]. A7 no-brief (item C.6a): firstCallCtx 47900, firstEditCall 30, ctxAtFirstEdit 94176. A1 with brief (item C.5): 47976 / 20 / 84905. Counting sed -i edits: call 15 vs 25. The brief added no measurable first-call context and came with the earlier first edit; n=1 on different items. X2: the A7 session had two result events (background task re-woke it); the loop keeps only the last, so it logged 4 turns and 446k tokens instead of 46 turns and about 3.8M; cost is cumulative and right.
- **Verified:** Session line read from the MyFinancialLedger log (brief null, no brief file written, so -NoBrief honored); raw stream parsed for both runs (result events, usage per result, edit-like tool calls); Invoke-RoadmapValidation -FailOnError exit 0, score 100, warnings R011 x2 (pre-existing) and R012 (0.1 all items done but still active). Not verified: report browser smoke test from the 0.1 validation plan.
- **Progress:** Roadmap progress appended: 7/23 items done, phases 0/0, 16 open-items left -> docs/ROADMAP-PROGRESS.md
- **Safe to proceed:** yes; all work uncommitted, no failing checks
- **Next:** Close Release 0.1: serve MyFinancialLedger .claude/state on 127.0.0.1 and confirm agent-loop-report.html shows the cache ratio and the brief link with no console errors, then mark 0.1 done and activate 0.2 (B1). X2 fix can go first; it affects -MaxTokens.
- **Owner:** Approve closing 0.1 and activating 0.2; decide on .gitignore and untracking .claude/state; approve D1/D2; commit decision

## 2026-11-11 — A1 recorded from live run 20261111-062509; Start-Agent -NoBrief passthrough (A7 next)

- **Did:** ROADMAP.md: A1 stamped [x] with numbers; A7 note says A1 already carried the brief, so A7 is the -NoBrief counterpart (check line updated). Install-AgentLoop.ps1: Start-Agent gains -NoBrief and -BriefMaxChars passthrough. CLAUDE.md Start-Agent bullet updated. A1 numbers (MyFinancialLedger run 20261111-062509, finished, 50 turns, $2.17, brief 1767 chars): firstCallCtx 47976, firstCallCacheRead 16444 (34%), firstEditCall 20, ctxAtFirstEdit 84905, mcpServers 0; old baseline ~50k / call 21 / ~75k / 36; 11-08 runs had firstEditCall 30 and 68, ctxAtFirstEdit 120k and 161k.
- **Verified:** Logged session.startup and session.brief read from the MyFinancialLedger log; sandboxed install (-ToolsDir/-ProfilePath in scratch, stub loop) shows Start-Agent passes NoBrief=False/4000 by default and True/900 when set; profile and Install-AgentLoop.ps1 parse 0 errors; tests/Test-AgentLoop.ps1 24 scenarios 0 failed; Invoke-RoadmapValidation -FailOnError exit 0. Not verified: the real profile reinstall. Noted: Get-StartupMetrics returns all nulls silently on a file still open for writing (harmless in the loop, which reads after the session ends).
- **Progress:** Roadmap progress appended: 6/22 items done, phases 0/0, 16 open-items left -> docs/ROADMAP-PROGRESS.md
- **Safe to proceed:** yes; all work uncommitted, no failing checks
- **Next:** A7: Ben reinstalls both profiles, then runs Start-Agent F:\Development\20_Staging\Financial\MyFinancialLedger -Max 1 -NoBrief; compare firstEditCall/ctxAtFirstEdit with A1 and record the item each run worked on. Release 0.2 (B1) is planned, not active.
- **Owner:** Reinstall both profiles and run A7 -NoBrief; decide on .gitignore and untracking .claude/state; approve D1/D2; commit decision

## 2026-11-11 — A6 brief stand-in scenarios (A7 next)

- **Did:** tests/Test-AgentLoop.ps1: new Test-SessionBrief helper (checks --append-system-prompt-file arg, file name, brief.path/sha/chars against the file bytes, cap); scenarios brief-injected (2 sessions, seeded ROADMAP.md; s2 brief carries s1 entry, commit and roadmap item A1, not S0), brief-capped (-BriefMaxChars 600: exact length, truncation marker, roadmap cut), brief-optout (-NoBrief: no arg, no brief files, brief key null, strict MCP still on); optional per-scenario setup scriptblock; startup-defaults reuses the helper. ROADMAP.md A6 stamped [x]; CLAUDE.md test section updated (22 scenarios).
- **Verified:** pwsh -NoProfile -File tests/Test-AgentLoop.ps1: 24 scenarios, 0 failed (brief-injected failed once on a wrong clean-tree expectation in the test, fixed). Parse of Test-AgentLoop.ps1: 0 errors. Invoke-RoadmapValidation -FailOnError: exit 0 (INFO only). Not verified: live run with the brief (A7, needs reinstall).
- **Progress:** Roadmap progress appended: 5/22 items done, phases 0/0, 17 open-items left -> docs/ROADMAP-PROGRESS.md
- **Safe to proceed:** yes; all work uncommitted, no failing checks
- **Next:** A7: live -Max 1 run on MyFinancialLedger with the brief, after Ben reinstalls; record firstEditCall and ctxAtFirstEdit next to A1. A1 numbers also need Bens live run. Candidate non-blocker: Start-Agent should create .gitignore when missing.
- **Owner:** Reinstall both profiles; run A1 then A7 live on MyFinancialLedger; decide on .gitignore and untracking .claude/state; approve D1/D2; commit decision

## 2026-11-11 — Review of live run 20261111-055243 report (A6 next)

- **Did:** No code changes. Reviewed .claude/state/agent-loop-report.html in a browser (127.0.0.1, no console errors) and the log. Findings: installed copy (00:39) predates A4, so the run sent no brief; mcpServers 0 answers the strict-MCP question; first call 46k with 36% cache hit; repo has no .gitignore so .claude/state is tracked (Start-Agent only appends to an existing .gitignore); session Tokens 1.72M is cumulative billed tokens, not context.
- **Verified:** Browser render of the report and session detail; grep of installed Start-AgentLoop.ps1 (no New-SessionBrief); git ls-files .claude shows tracked state files. Not verified: brief in a live run.
- **Progress:** Roadmap progress refreshed (no change): 4/22 items done, phases 0/0, 18 open-items left -> docs/ROADMAP-PROGRESS.md
- **Safe to proceed:** yes; all work uncommitted
- **Next:** A6: brief-injected and brief-optout stand-in scenarios. Owner first: reinstall so live runs carry the brief. Candidate non-blocker: Start-Agent should create .gitignore when missing.
- **Owner:** Reinstall both profiles; run A1 on MyFinancialLedger; decide on .gitignore and untracking .claude/state; approve D1/D2; commit decision

## 2026-11-11 — A5 brief logged on the session line and linked in the report (A6 next)

- **Did:** Start-AgentLoop.ps1: session line gets brief {chars, sha (SHA-256 of the file bytes), path (absolute)}, null with -NoBrief or a failed build, reset each iteration. AgentLoopReport.html: Session brief row in the session detail links the file as file:/// (scheme fixed, never from the log) with chars and short sha. tests/Test-AgentLoop.ps1: startup-defaults checks brief.path equals the passed file and sha/chars match it; startup-optout checks brief is null; the suite now clears inherited AGENT_LOOP_*/CLAUDE_HYGIENE_*/TK_DISABLE so it passes inside a loop session (it failed 2 env checks before). ROADMAP.md A5 checked; CLAUDE.md updated. All uncommitted.
- **Verified:** Parse *.ps1 and tests/*.ps1: 0 errors. tests/Test-AgentLoop.ps1: 21 scenarios, 0 failed. Logged brief field inspected (624 chars, sha, path). New-AgentLoopReport on the test log: brief embedded. node --check on the report script ok; fileHref tested on a Windows path with space and #. Roadmap validation L3: exit 0, score 100, 2 pre-existing R011 warnings. Not verified: report opened in a browser, installed copy, live run.
- **Progress:** Roadmap progress appended: 4/22 items done, phases 0/0, 18 open-items left -> docs/ROADMAP-PROGRESS.md
- **Safe to proceed:** yes; all work uncommitted, inactive until reinstall
- **Next:** A6: stand-in scenarios brief-injected and brief-optout (args recorded by Fake-Claude.ps1 plus the brief log fields); much of it is already asserted in startup-defaults/startup-optout, so A6 can be dedicated scenarios that move those checks. A1 still waits on Ben.
- **Owner:** Reinstall into both profiles and run A1 live; approve D1/D2; decide on committing

## 2026-11-11 — A4 New-SessionBrief pre-session brief (A5 next)

- **Did:** Start-AgentLoop.ps1: New-SessionBrief, Get-RoadmapItem, Invoke-GitLines; params -BriefMaxChars (4000), -RoadmapFile (ROADMAP.md), -NoBrief; each session writes runs/<stamp>-s<n>-brief.md (branch/HEAD, commits since previous session start, git status, handoff top entry, roadmap item for the label) and passes --append-system-prompt-file (file form, not inline, so newlines and quotes survive Windows arg passing). tests/Test-AgentLoop.ps1: startup-defaults asserts the brief arg and sections, startup-optout uses -NoBrief and asserts no brief. ROADMAP.md A4 checked with the file-form note; CLAUDE.md documents it. All uncommitted.
- **Verified:** Parse of *.ps1 and tests/*.ps1: 0 errors. tests/Test-AgentLoop.ps1: 21 scenarios, 0 failed. Inspected a stand-in session-2 brief and recorded args. Ran New-SessionBrief on this repo: A4 roadmap item extracted, 1200-char cap truncates with marker. Roadmap validation L3: exit 0, score 100, 2 pre-existing R011 warnings. Not verified: real claude.exe accepting --append-system-prompt-file in -p mode (listed in --help), installed copy, live run.
- **Progress:** Roadmap progress appended: 3/22 items done, phases 0/0, 19 open-items left -> docs/ROADMAP-PROGRESS.md
- **Safe to proceed:** yes; all work uncommitted, inactive until reinstall
- **Next:** A5: log brief.chars, brief.sha and the brief path on the session line; link it in the report session detail. A1 still waits on Ben.
- **Owner:** Reinstall into both profiles and run A1 live; approve D1/D2; decide on committing

## 2026-11-11 — ROADMAP A1 owner commands corrected (A4 next)

- **Did:** ROADMAP.md A1: replaced the Start-AgentLoop ... -Max 1 command (not on PATH; -Max ambiguous for the script) with the exact sequence: install into the VS Code profile and the PowerShell profile by absolute path, dot-source the profile, then Start-Agent MyFinancialLedger -Max 1. Added firstCallCacheRead to the metrics to record.
- **Verified:** Both profiles define only Start-Agent (grep). Invoke-RoadmapValidation L3 -FailOnError: exit 0, score 100, 0 errors, 2 pre-existing warnings. Commands not run here.
- **Progress:** Roadmap progress refreshed (no change): 2/22 items done, phases 0/0, 20 open-items left -> docs/ROADMAP-PROGRESS.md
- **Safe to proceed:** yes; uncommitted
- **Next:** A4: New-SessionBrief in Start-AgentLoop.ps1. A1 still waits on Ben.
- **Owner:** Run the four A1 commands in ROADMAP.md; approve D1/D2; decide on committing

## 2026-11-11 — A2 split first-call cache metrics and A3 loop-only Stop guard (A4 next)

- **Did:** Start-AgentLoop.ps1 Get-StartupMetrics adds firstCallCacheRead/firstCallCacheCreation, Format-Startup prints cache hit %; AgentLoopReport.html Startup tile and detail row show the first-call cache-hit ratio (older logs without the split still render); context-guard.ps1 Stop branch blocks only when AGENT_LOOP_RUN_ID is set; tests/Fake-Claude.ps1 first call now has 6000 cache creation; tests/Test-AgentLoop.ps1 checks the split and adds guard-stop-outside-loop and guard-stop-in-loop; ROADMAP.md A2 and A3 checked; CLAUDE.md updated. All uncommitted.
- **Verified:** Parse of *.ps1 and tests/*.ps1: 0 errors. tests/Test-AgentLoop.ps1: 21 scenarios, 0 failed. node --check on the report script: ok; startupText run on sample records with and without the split. Invoke-RoadmapValidation L3 -FailOnError: exit 0, score 100, 0 errors, 2 warnings (pre-existing R011). Not verified: installed copy (needs reinstall), live run, that claude -p passes AGENT_LOOP_RUN_ID through to hooks, report opened in a browser.
- **Progress:** Roadmap progress appended: 2/22 items done, phases 0/0, 20 open-items left -> docs/ROADMAP-PROGRESS.md
- **Safe to proceed:** yes; all work uncommitted, A2/A3 inactive until reinstall
- **Next:** A4: New-SessionBrief in Start-AgentLoop.ps1 (brief from Get-HandoffBrief, git state, roadmap section; --append-system-prompt, -BriefMaxChars 4000, -NoBrief). A1 still waits on Ben.
- **Owner:** Reinstall (Install-AgentLoop.ps1 -SkipHooks into both profiles) and run A1 live; approve D1/D2; decide whether to commit ROADMAP.md and this work

## 2026-11-10 — ROADMAP.md created from the improvement proposals (A1 next)

- **Did:** New ROADMAP.md (roadmap-contract template): Release 0.1 active (A1 live baseline, A2 split cache metrics, A3 Stop guard loop-only, A4-A7 loop-built brief and logging), 0.2 handoff lint + boundary rotation + warm-cache repair, 0.3 tests between sessions, 0.4 review.md snapshot + commit-and-pr. CLAUDE.md: roadmap pointer and handoff command without -SkipProgress.
- **Verified:** Invoke-RoadmapValidation.ps1 -MinimumMaturity L3 -FailOnError: exit 0, score 100, L4, 0 errors, 2 warnings (R011 Active release pointer and detail heading; skipped because template rule 1 forbids restating active in the header). Validator does not parse ## Slice headings, so releases use 0.x; template comment examples got sample check lines to clear R020. No code changed, tests not rerun.
- **Progress:** Roadmap progress appended: 0/22 items done, phases 0/0, 22 open-items left -> docs/ROADMAP-PROGRESS.md
- **Safe to proceed:** yes; ROADMAP.md and CLAUDE.md uncommitted
- **Next:** A1: Ben reinstalls and runs Start-Agent MyFinancialLedger -Max 1 for a baseline; meanwhile A2 and A3 can be built with stand-in tests
- **Owner:** Run A1 live; approve D1/D2; decide whether to commit ROADMAP.md

## 2026-11-10 — Improvement review of the rotation loop (proposals only) (live-startup-check next)

- **Did:** No code changes. Proposed: (1) loop-built pre-session brief via --append-system-prompt (git facts, top entry, roadmap section; Get-HandoffBrief already parses it but only prints), (2) rotate at item boundary when handoff written and ctx > ~100k, (3) Stop-hook lint of handoff entry quality, (4) run repo tests between sessions and feed results to next brief, (5) cache-warm --resume repair when handoff missing; minor: split cache_read vs cache_creation in startup metrics, gate Stop guard on env var, cheaper model for repair sessions.
- **Verified:** Read Start-AgentLoop.ps1 and context-guard.ps1 to confirm brief is not injected and cache tokens are summed. Nothing built or tested.
- **Progress:** skipped (-SkipProgress)
- **Safe to proceed:** yes; no files changed besides this entry
- **Next:** Ben live run (Start-Agent MyFinancialLedger -Max 1) for a fresh baseline, then build proposals 1 and 3 with stand-in tests
- **Owner:** Pick which proposals to build; reinstall and live check still pending

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
