# QQT_Warpigz_v2 v2.1.0 — audit

v2.1.0 is an integration release. The question was whether all plugins and the orchestrator work **together**, not only one by one. It was answered by a team of ten domain reviewers, one auditor and one critic, followed by four fix rounds driven by the audit, the critic, and real QQT client logs that the user supplied during the work.

## How the review ran

| Round | Team | Result |
| --- | --- | --- |
| 1 — review | 10 domain reviewers (WarPigs dispatch, WarPigs town, WarPug, SilentRaven, Batmobile, Arkham, WonderCity, HordeDev, Helltide, Reaper) → 1 auditor → 1 critic | 94 findings: 52 confirmed (2 critical, 7 high, 15 medium, 28 low), 25 duplicates, 9 refuted, 8 need a live check; the critic added 6 gaps and 5 disputes |
| 2 — fix | 10 plugin owners with disjoint files and one shared contract → auditor → critic | 130 fixes verified, 1 regression, 2 incomplete, 1 not done |
| 3 — residuals | 7 owners + joint-suite builder → auditor → critic | the residuals closed; a new joint test with all nine plugins in one host found and fixed 3 interaction defects |
| 4 — feature | HordeDev, WarPigs and WonderCity owners + joint extension → auditor → critic | War Plan Horde entry via the War Plan teleport (user request), no compass |
| 5 — hardening | 3 owners + joint extension → auditor → critic | reload mid-horde, Alfred's own trip mid-horde, hotkey pauses, advisory policy; the critic's 2 release blockers fixed afterwards |

Each finding carries file:line evidence, a cross-plugin call chain and a failure scenario. The auditor defaulted to "refuted" when the evidence did not hold, and the critic challenged both. Every fix has an offline regression that fails on the commit before it. The full table of findings and resolutions is in [audit/reviews-2.1.0/FINDINGS.md](audit/reviews-2.1.0/FINDINGS.md).

## The decisive finding: the host runs LuaJIT

The v2.0.0 validation ran only on Lua 5.4. The live client log (`planner.lua:217: attempt to call field 'unpack' (a nil value)`) proved that QQT uses LuaJIT with Lua 5.1 rules, which the original author's "Lua 5.1 limit = 60" comment in the orchestrator had already implied. Under LuaJIT, WarPug could not plan and v2.0.0's `orchestrator.lua` did not compile at all (61 upvalues). Both are fixed, and the offline suite now runs every test under both runtimes, compiles every runtime file with LuaJIT, rejects Lua 5.2+ library use, and warns about functions near the upvalue and local limits.

## Cross-plugin contract introduced

- **C1:** one Alfred status reading in every plugin. A latched `teleport` from a finished or failed trip is not live work. A pause without a hard need is idle for non-owners. The sticky advisory grace survives task switches. An unreadable status holds for at most about 10 s.
- **C2:** additive status fields so that WarPigs can decide safely:
  - HordeDev: `in_run`, `fault`, `exit_pending`, `entry_mode`, `alfred_trip`, `hold`
  - Reaper: `in_run`, `external_run`, `last_result`, `last_error`
  - Arkham and WonderCity: `alfred_trip`, `in_run`, `committed_entry`
- **C3:** `BatmobilePlugin.release(caller)`, an owner-scoped hand-off (target, long path, traversal state, explorer priority).
- **C4:** orbwalker clear/block states are restored on every exit path.
- **C5:** time spent yielding to the Looter or Alfred never counts as "stuck".
- **C6:** every hold is bounded, logged with its reason and shown in the status line.
- **Whisper yield:** the WarPigs bridge's guard may answer `yield:<reason>`. SilentRaven then pauses the request instead of cancelling it.
- **Advisory policy:** while WarPigs is enabled, activity plugins leave advisory restock and stash flags to WarPigs. The one exception is HordeDev's compass restock at the gate, which is a blocking need.
- **War Plan Horde:** `InfernalHordesPlugin.enable({entry='warplan'})`; WarPigs options `horde_warplan_entry` (default on) and `horde_compass_fallback` (default off).

## Reproducible verification

```sh
python3 audit/check_release.py --base <previous release tag>
python3 audit/tests/run_tests.py --luajit require
```

Final result for this release: 41 test files × (Lua 5.4 + LuaJIT) = 82 runs, 0 failures. All 202 runtime files compile under LuaJIT, and the largest function captures 48 upvalues. `test_joint_suite.lua` loads all nine real plugins into one emulated QQT host, with per-plugin module caches, one shared `_G` and caller-context `require` detection. It runs 34 scenarios and 2784 checks per runtime, among them: load and exports, Temis idle, the Whisper → WarPug → Pit chain, an API sweep from every plugin context, the Pit → Undercity → Helltide → Horde → turn-in hand-offs, a master stop, death, War Plan hordes with and without *Use teleport*, missed landings, a reload mid-horde, Alfred's own trips, hotkey pauses and a sticky advisory flag over a full plan. See [audit/VALIDATION.txt](audit/VALIDATION.txt).

## Remaining live checks

Offline tests do not run Diablo IV. [audit/LIVE_CHECKLIST.md](audit/LIVE_CHECKLIST.md) lists the exact log lines to confirm. The open host facts are:

- where `warplan.teleport_to_activity()` lands for a Horde step (logged on every delivery);
- SilentRaven's `select()` and `selected_index()` conventions (dumped once automatically if a claim cannot be verified);
- native `request_move` behaviour while the Looter is active (Whisper walk, LooteerV3 `approach_stall`);
- chest actor states after opening (WonderCity logs one diagnostic line per ambiguous chest);
- whether closed-source Alfred or Looter drive `BatmobilePlugin` under their own caller names.

LooteerV3 and Alfred are closed source. Their settings are never mutated. The earlier audits ([v2.0.0 baseline](audit/baseline-2026-09-23/AUDIT.md), `audit/reviews`, `audit/feedback-reviews`) are kept as history.
