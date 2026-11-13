# AutomatedHandoff — Product & Engineering Roadmap

> Project status: Active
>
> Product direction: Unattended Claude Code runs that cost less to restart each session, leave handoffs the next session can trust, and log every loop decision so Ben can see why it happened.

<!--
AUTHORING RULES (not rendered as a section; parsers and agents should still read this comment)

1. SINGLE SOURCE OF TRUTH FOR "ACTIVE": the active release is whichever release
   section below carries `> Status: active`. Do not restate which release is
   active up here in the header — a second field here would just be a second
   place for that fact to go stale. Exactly one release should be `active` at
   any time (see Section 8 guardrail).

2. STATUS VOCABULARY IS LOWERCASE AND FIXED: planned | active | blocked |
   validation | done | archived. Parsers normalize case and common aliases
   (e.g. "in progress" -> active, "shipped" -> done), but always author in
   lowercase to avoid relying on that normalization.

3. MILESTONE IDS (recommended, not required for L3/L4 scoring): prefix a
   checklist item with a short stable tag so it can be referenced from
   roadmap-events.jsonl and from other milestones without relying on the
   wording staying the same:
     - [ ] [[M3]] Implement retry backoff in Poll-Provider.ps1
           `check: pwsh ./tests/Poll-Provider.Tests.ps1`
   Reference a dependency inline when order matters and isn't top-to-bottom:
     - [ ] [[M4]] Wire backoff into dispatcher (depends: M3)
           `check: pwsh ./tests/Dispatcher.Tests.ps1`
   Once assigned, an ID is permanent — never reassign it to a different item.

   Exact form, because these are now parsed rather than decorative:
     - The ID is `[[` + one or more of `A-Z a-z 0-9 . _ -` + `]]`, and it comes
       IMMEDIATELY after the checkbox, before the item text.
     - Case is significant: `[[M4]]` and `(depends: m4)` do not match.
     - The dependency tag is `(depends: ...)` and may appear anywhere in the
       item's first line. Several IDs are COMMA-separated:
         - [ ] [[M5]] Ship the thing (depends: M3, M4)
               `check: pwsh ./tests/Ship.Tests.ps1`
     - Dependencies resolve within this file only. Referencing an ID no item
       declares raises ROADMAP-013; a cycle raises ROADMAP-014.
     - Both markers are stripped from the item's display text, exactly as
       ordinary `[tags]` are, so the console shows the wording and not the
       notation.

4. TOKEN / COST DATA LIVES IN THE LEDGER, NOT HERE: do not hand-maintain a
   running token or dollar total inline in this file. That number decays the
   moment it's not updated. roadmap-events.jsonl is the append-only, always-
   current source; ROADMAP_BUDGET_MODEL.md explains how it's valued. The
   optional Phase plan table below is a point-in-time *estimate* for planning,
   not a running actual.

5. "Recently Completed" (Section 6) is NOT a mirror of the `[x]` items already
   sitting inside active/planned release sections above — leave those where
   they are. Section 6 only holds completed work whose original release
   section has since been archived or removed from Section 5, so that
   history survives even after the section that produced it is gone.
   Alternatively, that surviving history may live in a separate archive file
   instead of Section 6 — a supported layout, not a deviation. See the
   "External archive option" under Section 6 for the required pointer
   convention that makes the split self-describing.

6. "Dispatch readiness" in the Release Index (Section 4) is a computed field
   (derived from `normalizedStatus` + open audit findings), not something to
   hand-author differently from what the tooling would compute. If you're
   filling this out by hand because no tooling exists yet, treat it as a
   best-effort mirror of release status + known blockers, not a separate
   judgment call.

7. THIS FILE OPENS AND CLOSES EVERY AGENT RUN. An agent reads this file before
   it builds anything (a `[ ]` means "not finished", not "nothing exists"), and
   it updates this file as one of the LAST files it writes before the run ends:
   the item the work belongs to is checked `[x]` or its status advanced, in the
   same change set as the code. The only reason the record may lag the code is
   a CI validation that has not yet finished — record the item as built and
   awaiting that check, never "to be recorded later." A run that merges code
   and leaves this file unmoved teaches the next agent to rebuild what exists.
-->

## 1. Product Intent

AutomatedHandoff is the context-rotation loop (`Start-Agent`, `Start-AgentLoop.ps1`) plus the `context-guard.ps1` hook. Together they run `claude -p /handoff` headless against any of Ben's repositories. When context passes a limit, the session writes a handoff and stops, and a fresh session picks up from it. The aim is many unattended sessions in a row, each one cheap to start, each one leaving a handoff that is accurate, with the log and report showing why every rotation, stop and retry happened.

---

## 2. Product Principles

- **Measure, never claim** — every efficiency change has to move a number in the `session.startup` metrics or the loop log, compared against a recorded baseline.
- **Deterministic before model** — anything PowerShell can compute (git facts, handoff parsing, test results, lint) is computed by the loop, never left for the agent to discover with tool calls.
- **Every decision is visible** — each rotation, stop, retry and injected brief writes a log field and shows in `agent-loop-report.html`; no decision exists only in a terminal line.
- **A guard never breaks the agent** — hooks always exit 0 and report failures on stderr.
- **Interactive sessions are not loop runs** — loop-only behavior must not fire outside `Start-AgentLoop.ps1`.

---

## 3. Current State Summary

The loop, the guard, until-done mode, the run log, the HTML report and the model-written summary all exist, and 24 stand-in scenarios pass in `tests/Test-AgentLoop.ps1`. Release 0.1 is done (2026-11-11): no MCP servers by default (0 in live runs), a split first-call cache metric, a loop-built session brief passed with `--append-system-prompt-file`, and a Stop guard that only blocks inside loop runs. Remaining gaps: the Stop guard only checks that a handoff was written, not whether it is any good; rotation happens only at a token limit, not when an item finishes; the loop never checks whether a "Verified:" line is still true; and a session with several `result` events is logged from the last one only (X2).

---

## 4. Release Index

| Release | Status  | Purpose                                                            | Dispatch readiness                |
| ------- | ------- | ------------------------------------------------------------------ | --------------------------------- |
| 0.1     | done    | Baseline, cache visibility, loop-built brief, loop-only Stop guard | done 2026-11-11 (Section 6)       |
| 0.2     | active  | Handoff quality checks and rotation when an item finishes          | in progress (B1-B2 done, B3 next) |
| 0.3     | planned | Tests run between sessions; cheaper model for repair sessions      | planned                           |
| 0.4     | planned | Handoff snapshot (review.md) and a commit per item                 | planned (D1, D2 approved)         |

_Exactly one row above should show `active`. If a second release needs to become active, close out or explicitly re-status the first one in the same edit._

---

## 5. Release Roadmap

## Release 0.2 — Handoffs worth trusting and clean rotation

> Status: active

**Goal:** Sessions end on item boundaries, and a handoff that fails a deterministic quality check is fixed before the next session starts, with the result logged.

#### Product outcomes

- Fewer sessions start mid-item, and none starts from a handoff missing a concrete Next.

#### Engineering milestones

- [x] [[B1]] New `Test-HandoffEntry` in `Resolve-HandoffFile.ps1` (shared by the loop and the guard): the top entry needs a Next naming a file, command or item ID, a Verified line containing at least one command, and a Safe-to-proceed starting with yes or no; returns a list of problems. *(completed: 2026-11-11)*
      `check: pwsh -NoProfile -File tests/Test-AgentLoop.ps1`
- [x] [[B2]] The `Stop` branch of `context-guard.ps1` blocks once with the `Test-HandoffEntry` problems as the reason; the loop logs them as `session.handoffLint`. (depends: B1, A3) *(completed: 2026-11-11)*
      `check: pwsh -NoProfile -File tests/Test-AgentLoop.ps1`
- [x] [[B3]] Rotate at the item boundary: on `PostToolUse`, if the handoff was rewritten this session and context is above `AGENT_LOOP_BOUNDARY_TOKENS` (new `-BoundaryLimit`, default 100000), write `rotate.flag` with reason `boundary` and tell the agent to stop. *(completed: 2026-11-11)*
      `check: pwsh -NoProfile -File tests/Test-AgentLoop.ps1`
- [x] [[B4]] `rotate.flag` holds a JSON reason (`soft-limit`, `hard-limit`, `boundary`); the `session` line logs `rotateReason` and the report shows it in the session table. (depends: B3) *(completed: 2026-11-13)*
      `check: pwsh -NoProfile -File tests/Test-AgentLoop.ps1`
- [x] [[B5]] Handoff repair on a warm cache: when a session ends with no valid handoff, run `claude -p --resume <sessionId>` with a fixed "write the handoff entry" prompt, `--max-turns 5`, logged as a `repair` line; at most one repair per session. (depends: B1) *(completed: 2026-11-13)*
      `check: pwsh -NoProfile -File tests/Test-AgentLoop.ps1`

#### Acceptance criteria

- Stand-in scenarios cover lint pass, lint fail plus block, boundary rotation, the hard-limit reason and a successful and failed repair, and all pass.
- The report shows the rotation reason and lint result for every session.

#### Out of scope

- Model-graded handoff quality; the checks are regexes only.

#### Validation plan

- Run `pwsh -NoProfile -File tests/Test-AgentLoop.ps1` and confirm exit code 0, with the new lint, boundary and repair scenarios listed as passed.
- Run the parse check from `CLAUDE.md` and confirm 0 errors in every `*.ps1`.
- Manual smoke test: serve `.claude/state` on `127.0.0.1` and confirm the report shows the rotation reason and lint result per session, with no console errors.

#### Risks and blockers

- Too low a boundary limit could rotate before useful work; the 100k default is a guess to tune against live numbers.

#### Dependencies

- A3 (done): the `Stop` guard already returns early outside loop runs, so B2's block only fires under `AGENT_LOOP_RUN_ID`.
- `~/.claude/scripts/Add-RunHandoffEntry.ps1` entry shape (Did, Verified, Safe to proceed, Next, Owner), which `Test-HandoffEntry` checks.

#### Known issues

- X2: a session with more than one `result` event is logged from the last one only, so B5's repair accounting would undercount until X2 is fixed.

## Release 0.3 — Verified progress between sessions

> Status: planned

**Goal:** The loop itself checks the repository between sessions and hands the result to the next session, so "Verified:" claims are checked rather than taken on trust.

#### Product outcomes

- A next session learns about a broken test from its brief, not from a later failure.

#### Engineering milestones

- [ ] [[C1]] New `-TestCommand` (also read from `testCommand` in `.claude/agent-loop.json`): run after each session with a `-TestTimeoutSec` limit, log `session.tests` (exit code, duration, the first 40 failure lines) and show it in the report.
      `check: pwsh -NoProfile -File tests/Test-AgentLoop.ps1`
- [ ] [[C2]] `New-SessionBrief` adds the last test result, and the until-done stop logic treats `-StopOnTestFailures <n>` failures in a row as `blocked`. (depends: A4, C1)
      `check: pwsh -NoProfile -File tests/Test-AgentLoop.ps1`
- [ ] [[C3]] `-RepairModel` (default `sonnet`) for B5 repair sessions, logged on the `repair` line. (depends: B5)
      `check: pwsh -NoProfile -File tests/Test-AgentLoop.ps1`

#### Acceptance criteria

- Scenarios with a passing and a failing `-TestCommand` pass, and the failure text shows up in the next session's recorded brief.

#### Out of scope

- Running tests inside the agent's session; this is loop-side only.

#### Validation plan

- Run `pwsh -NoProfile -File tests/Test-AgentLoop.ps1` and confirm exit code 0.

## Release 0.4 — Handoff snapshot and a commit per item

> Status: planned

**Goal:** The active handoff is a 50–100 line snapshot kept apart from history, and until-done runs commit each item on a run branch, then open a PR at the end.

#### Product outcomes

- Startup reads a short snapshot instead of a growing history file.

#### Engineering milestones

- [ ] [[D1]] review.md snapshot work: `Add-RunHandoffEntry.ps1` writes a replaceable active snapshot with an atomic write that keeps the previous one, and history stays in `handoff-log.json`. Approved 2026-11-11.
      `check: pwsh -NoProfile -File tests/Test-AgentLoop.ps1`
- [ ] [[D2]] Trim the MyFinancialLedger handoff to the snapshot format once D1 lands. Approved 2026-11-11. (depends: D1)
      `check: Start-Agent F:\Development\20_Staging\Financial\MyFinancialLedger -Max 1`
- [ ] [[D3]] commit-and-pr (approved 2026-11-06): a commit per item on a run branch, a final PR session and one repair session.
      `check: pwsh -NoProfile -File tests/Test-AgentLoop.ps1`

#### Acceptance criteria

- The active snapshot stays at 100 lines or fewer across a multi-session stand-in run, and a stand-in until-done run ends with one commit per item and a PR session.

#### Out of scope

- Pushing or opening PRs without Ben's go-ahead on the target repository.

#### Validation plan

- Run `pwsh -NoProfile -File tests/Test-AgentLoop.ps1` and confirm exit code 0.

---

## 6. Recently Completed

The work built before this roadmap (the loop, the guard, until-done, the report, the summary, the startup-overhead changes) is recorded in `current-handoff.md` and the git history.

### Archived: zero-cost startup and a visible baseline (milestones A1-A7) *(completed: 2026-11-11)*

Goal: every session starts with a brief built by the loop, pays no fixed overhead it does not need, and the log shows what each session received and what its first call cost.

- [x] [[A1]] Live baseline: Ben reinstalls into both profiles, reloads the profile and runs one session on MyFinancialLedger; record `firstCallCtx`, `firstCallCacheRead`, `ctxAtFirstEdit`, `firstEditCall` and `mcpServers` in `current-handoff.md` against the old baseline (~50k / ~75k / call 21 / 36 servers). *(completed: 2026-11-11)*
      Owner run; this session cannot launch a nested `claude -p`. In a PowerShell 7 terminal, run in order:
      1. `pwsh -NoProfile -File "F:\Development\20_Staging\AI Projects\AutomatedHandoff\Install-AgentLoop.ps1" -SkipHooks -ProfilePath "$HOME\OneDrive\Documents\PowerShell\Microsoft.VSCode_profile.ps1"`
      2. `pwsh -NoProfile -File "F:\Development\20_Staging\AI Projects\AutomatedHandoff\Install-AgentLoop.ps1" -SkipHooks -ProfilePath "$HOME\OneDrive\Documents\PowerShell\Microsoft.PowerShell_profile.ps1"`
      3. `. $PROFILE`
      4. `Start-Agent F:\Development\20_Staging\Financial\MyFinancialLedger -Max 1`
      Use the profile function `Start-Agent`, not `Start-AgentLoop`: the script is not on PATH, and `-Max` is ambiguous against its `-MaxSessions`, `-MaxCostUsd` and `-MaxTokens`. A Startup line that shows a cache-hit percentage confirms the run used the reinstalled copy.
      Done 2026-11-11, run 20261111-062509 (finished, 50 turns, $2.17): firstCallCtx 47,976, firstCallCacheRead 16,444 (34%), firstEditCall 20, ctxAtFirstEdit 84,905, mcpServers 0 (was ~50k / call 21 / ~75k / 36). The reinstalled copy already includes A4, so this run carried a 1,767-char brief; it is the with-brief run, not a no-brief baseline.
      `check: Start-Agent F:\Development\20_Staging\Financial\MyFinancialLedger -Max 1`
- [x] [[A2]] `Get-StartupMetrics` in `Start-AgentLoop.ps1` records `firstCallCacheRead` and `firstCallCacheCreation` separately (today it adds them together at line 274); `AgentLoopReport.html` shows a cache-hit ratio in the Startup tile and the detail row. *(completed: 2026-11-11)*
      `check: pwsh -NoProfile -File tests/Test-AgentLoop.ps1`
- [x] [[A3]] Gate the `Stop` branch of `context-guard.ps1` on `AGENT_LOOP_RUN_ID` so it only blocks inside loop runs; add a scenario where the guard is called without the variable and must not block. *(completed: 2026-11-11)*
      `check: pwsh -NoProfile -File tests/Test-AgentLoop.ps1`
- [x] [[A4]] New `New-SessionBrief` in `Start-AgentLoop.ps1`: from `Get-HandoffBrief`, `git rev-parse`, `git status --porcelain`, the commits since the last session and the roadmap section named by the top entry's label, build a brief capped by a new `-BriefMaxChars` (default 4000) and pass it with `--append-system-prompt`; `-NoBrief` opts out. *(completed: 2026-11-11)*
      Built with `--append-system-prompt-file runs/<stamp>-s<n>-brief.md` instead of the inline flag, so newlines and quotes survive Windows argument passing; the file is also A5's raw brief path.
      `check: pwsh -NoProfile -File tests/Test-AgentLoop.ps1`
- [x] [[A5]] Log the brief: the `session` line carries `brief.chars`, `brief.sha` and the raw brief path `runs/<stamp>-s<n>-brief.md`; the report's session detail links it. (depends: A4) *(completed: 2026-11-11)*
      `brief.sha` is the SHA-256 of the file's bytes and `brief.path` is absolute, like `rawLog`; `brief` is null with `-NoBrief` or when building it failed. The report links it as a `file:///` URL.
      `check: pwsh -NoProfile -File tests/Test-AgentLoop.ps1`
- [x] [[A6]] Stand-in scenarios `brief-injected` and `brief-optout` check the `--append-system-prompt` argument recorded by `tests/Fake-Claude.ps1` and the `brief` log fields. (depends: A4, A5) *(completed: 2026-11-11)*
      Checks `--append-system-prompt-file` (A4's form); a seeded `ROADMAP.md` checks that session 2's brief carries session 1's entry, commit and roadmap item. A third scenario, `brief-capped`, checks the `-BriefMaxChars` cut and marker.
      `check: pwsh -NoProfile -File tests/Test-AgentLoop.ps1`
- [x] [[A7]] Live comparison: one `-Max 1` run on MyFinancialLedger with the brief, with `firstEditCall` and `ctxAtFirstEdit` recorded next to the A1 numbers in `current-handoff.md`. (depends: A1, A6) *(completed: 2026-11-11)*
      Because A1 already carried the brief, A7 is the counterpart run with `Start-Agent ... -Max 1 -NoBrief` (passthrough added 2026-11-11; needs a reinstall). Compare its numbers with A1's. One pair of single runs on different items is noisy, so record the item each run worked on.
      `check: Start-Agent F:\Development\20_Staging\Financial\MyFinancialLedger -Max 1 -NoBrief`
      Done 2026-11-11, run 20261111-064504 (item C.6a, no brief file, `brief` null): firstCallCtx 47,900, firstEditCall 30, ctxAtFirstEdit 94,176. A1 with the brief (item C.5): 47,976 / 20 / 84,905. Counting `sed -i` edits too: call 15 with the brief against call 25 without. The brief cost no measurable first-call context and came with the earlier first edit, but n=1 on different items.

Acceptance criteria, all met on 2026-11-11:

- All scenarios in `tests/Test-AgentLoop.ps1` pass, the new ones included, and every `*.ps1` parses with zero errors.
- The A7 run shows a lower `firstEditCall` or `ctxAtFirstEdit` than A1, or the handoff records that it didn't and why.
- An interactive session that changes nothing ends without a Stop-guard block.

Validation run: `tests/Test-AgentLoop.ps1` 24 scenarios, 0 failed; parse check 0 errors; report smoke test on 127.0.0.1 (cache-hit tile and brief link render, no console errors).
Live result: A1 with the brief reached its first edit at call 20 with 84,905 context; A7 without it at call 30 with 94,176 (single runs on different items).

---

## 7. Cross-Cutting Engineering Work

- [ ] [[X1]] Update `README.md` and `CLAUDE.md` in the same change as each milestone that adds a parameter or log field. [non-blocker]
      `check: pwsh -NoProfile -File tests/Test-AgentLoop.ps1`
- [x] [[X2]] A session with more than one `result` event is logged from the last one only. `Start-AgentLoop.ps1` keeps `$result = $e`, so turns, tokens and duration come from the final segment. Seen in run 20261111-064504: a background task re-woke the session after its first result (42 turns, $1.78), and the log shows 4 turns and 446k tokens. `total_cost_usd` is cumulative, so cost is right. Sum `num_turns`, the result tokens and `duration_ms` across result events, keep the last cost, and add a Fake-Claude scenario with two results. This also matters for `-MaxTokens`. [non-blocker] *(completed: 2026-11-13; turns and tokens summed, last cost kept, `session.resultEvents` added; `durationSec` was already wall-clock, so `duration_ms` needed no sum)*
      `check: pwsh -NoProfile -File tests/Test-AgentLoop.ps1`
- [x] [[X3]] `Start-Agent` auto-updates: the profile holds only an alias to the installed `Start-Agent.ps1`, which syncs changed runtime files from the source folder in `install.json` (`Install-AgentLoop.ps1 -FilesOnly`, refused on parse errors) and re-runs itself when replaced; `-NoUpdate`, `-UpdateOnly`. *(completed: 2026-11-11)*
      `check: pwsh -NoProfile -File tests/Test-AgentLoop.ps1`

---

## 8. Risks and Design Guardrails

- Only one release may carry `Status: active` at a time; the active-release blockquote in Section 5 is the sole source of truth for this.
- No efficiency milestone counts as done on stand-in results alone if it claims a live improvement; it needs a live `startup` comparison.
- Every new loop decision writes a log field before it gets a report view; nothing is shown that isn't in `agent-loop.log.jsonl`.
- Edits here change nothing until the files are reinstalled into `~/.claude/agent-loop`.

---

## 9. Definition of Done for Release Execution

A release should not be marked `done` unless:

- All checklist items for that release are implemented, moved to a future release, or explicitly blocked.
- Acceptance criteria are verifiably satisfied.
- Validation commands and smoke tests have been run or explicitly documented as unavailable.
- Affected docs (`README.md`, `CLAUDE.md`) are updated where workflow or behavior changed.
- Logging and error handling are sufficient to diagnose failures.
- Later releases were not partially started just to create the illusion of momentum.
- The release and each completed milestone carry absolute completion dates in `YYYY-MM-DD` format.
- Milestone IDs referenced elsewhere still resolve; none were renumbered or removed.
