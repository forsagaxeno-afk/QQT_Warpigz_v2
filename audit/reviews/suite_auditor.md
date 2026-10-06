# Independent suite integration audit

This review covers shared contracts across the eight bundled plugins. It is separate from the individual plugin reviews and does not claim an in-game Season 15 certification. The common auditor changed this report and its independent test files only; runtime fixes are owned by the individual plugin critics and root reviewer.

## Evidence and scope

- Reviewed activity enable/disable/status surfaces; task scheduling; Batmobile long-path handoffs; Alfred callback ownership; Looteer activity reporting; native host API declarations; and plugin module-loading assumptions.
- Read the supplied QQT companion implementations in `AlfredTheButler-main/core/external.lua`, `AlfredTheButler-main/tasks/status.lua`, and `LooteerV2-main/main.lua`. These companions are outside this bundle and were not changed.
- The supplied source archive matched the checked upstream `e7fd3b1e078470d6993ab4220d34a9990c5a909e` except the seven previously confirmed Horde files. That comparison and current Season 15 primary-source verification are recorded by the root review.
- No new actor IDs, quest names, key IDs, chest prices, or seasonal object mappings were inferred from public patch notes.

## Cross-plugin defects found

| Priority | Defect and observed consequence | Resolution responsibility |
|---|---|---|
| High | Alfred task modules could pause a foreign service cycle while merely loading. Completion callbacks also called `pause()`. The actual supplied Alfred implementation has no `create_task` capability and prioritizes `external_pause`, so the existing fork heuristic incorrectly treated it as safe to pause. Services could remain parked. | Activity critics: remove load/completion mutations of the companion; update local task state only. |
| High | An active Alfred cycle with no published `external_caller` was treated as available. Triggering again replaced the original caller and callback. The actual supplied companion does not publish that field. | Activity critics: yield any observed live or queued service cycle. |
| High | Alfred completion could run synchronously inside the trigger function; the task then overwrote the callback's completed state with `WAITING`, leaving the activity stuck. | Activity critics: establish wait state before calling the companion. |
| High | Late Alfred callbacks could affect a later activity session because tasks had no cancellation generation. | Activity critics: invalidate obsolete callbacks on explicit cancellation/disable, while preserving valid callback ownership across the service's own town/return trip. |
| High | Disabling an activity usually changed GUI flags only. An earlier Batmobile long path kept driving independently in `Batmobile/main.lua` and unpaused movement each tick, so an outgoing activity could interrupt teleport, loot, or the next activity. | Activity critics stop their own navigation at handoffs; Batmobile critic cancels autonomous long paths on explicit reset. |
| Medium | Most task managers retained the previous `current_task` when nothing matched. This was behavioral in Horde because `chests_done()` used a supposedly current `Exit Horde` task as evidence. | Activity critics clear expired task status while preserving explicit multi-world transactions. |
| Medium | Supplied Looteer v2 never clears `looting` when returning early because it is disabled. Arkham, WonderCity, and Helltide accepted that stale flag and could wait forever. | Consumer critics require the companion to be enabled before trusting `looting`. |
| Medium | Batmobile movement-rule selection formatted and printed multiple messages per rule on every movement tick, independent of debug settings. | Batmobile critic removes normal-path log spam and verifies the affected movement path. |
| High | Independent review caught a regression in the new Batmobile traversal latch: the first buff tick consumed its rising edge even when the current actor scan was empty, so a remembered crossing was never processed after actors returned. | Root applied a minimal branch guard accepting a remembered traversal or a new traversal edge; common auditor reproduced the failure and verified the correction. |
| High | WarPug's new busy check initially had no real producer in WarPigs. A naive producer then created a circular wait with optional filler Pit runs, and a bare pending-teleport intent could wait forever for the quest that WarPug was supposed to create. | Root publishes the actual busy state, gives enabled plan creation priority over optional filler, and distinguishes active transition/cleanup from idle intent awaiting a new plan. The WarPug critic tests the real two-plugin contract. |
| High | Clearing Horde's stale current task exposed a TELEPORT exit ordering bug: after Library arrival, a town task could replace `Exit Horde` before WarPigs observed it, erasing the completion signal and blocking the handoff. | Common auditor reproduced the exact task-order failure. The Horde critic added persistent completion evidence only after an issued exit reaches a valid, alive, non-loading Library snapshot; reset/enable clears it. |

## Independent regressions

`audit/tests/test_suite_contracts.lua` loads real activity modules inside separate Lua environments with controlled companion state. It verifies:

1. Loading each of the five activity Alfred tasks does not mutate a foreign cycle.
2. An unnamed active Alfred cycle, or a paused but still queued/live foreign cycle, is yielded without being retriggered.
3. A synchronous completion is retained and does not pause the companion.
4. A callback from a cancelled task session cannot pause another owner or alter new local state.
5. Each activity task manager clears a task that no longer runs.
6. Arkham and WonderCity ignore disabled Looteer's stale busy flag but continue yielding to enabled, active looting.
7. Horde's confirmed TELEPORT exit remains visible after another task takes the queue, and a new run cannot inherit that completion.

`audit/tests/test_batmobile_integration.lua` independently exercises a remembered traversal whose first buff tick has an empty actor enumeration. It checks immediate crossing handling, exactly one history entry for a continuous buff, and no movement during the animation. The test failed before the root correction and passes afterwards; Batmobile's original 12 tests / 84 assertions also pass unchanged.

The runner compiles all runtime Lua files and creates a fresh Lua state for each test file. The common tests use mocks to isolate real state-transition defects; they do not simulate the game's host scheduler, rendering, path geometry, inventory, or network/server timing. Initial runs reproduced the reported failures before the individual fixes landed. After the activity fixes, the independent common run compiled 184 runtime files and passed **all 33 shared-contract checks**. The auditor also independently reran the WarPigs 17-scenario suite, Reaper 66-assertion suite, and Batmobile 12-test / 84-assertion suite successfully. The final `test_warpug.lua` independently passed with real WarPug and WarPigs modules, including the two circular-wait reproductions, owned cleanup, actual turn-in, post-disable cooldown and teleport modes.

The final independent Horde run passed its **22 new behavior checks** and the unchanged **120 reset/exit + 230 sigil/entry assertions**. The final built-in salvage helper was also read independently: both processing modes preserve Unique-or-higher and unreadable rarity, affix mode preserves missing/empty criteria, and tests confirm that configured lower-rarity rejection still works. These checks do not establish that the retained class/affix tables cover all current-season items.

## Remaining integration limits

- **Module cache isolation is a host precondition.** All eight plugins use generic module names such as `gui`, `core.settings`, and `core.tracker`. A conventional shared `package.loaded` would alias these modules across folders. The supplied host API declarations do not specify the loader's isolation rules, and the suite is intended to run in a host that isolates each plugin's imports. There is no evidence here that the live host violates that assumption, so a disruptive module rename was not applied.
- **Batmobile has no enforceable ownership lease.** Caller strings are diagnostic labels and can be overwritten by subsequent API calls. Correctness depends on the orchestrator enabling one activity at a time and the outgoing activity releasing its own navigation. `pause()` is not synonymous with cancelling a long path. Changing that public meaning globally would break existing consumers that pause exploration before supplying a custom target. If Alfred starts independently before an activity yields, an Alfred-busy flag alone cannot distinguish that activity's old path from Alfred's replacement target; local ownership tracking improves cleanup but cannot resolve that unobservable race.
- **Enabled-but-inactive Looteer remains ambiguous.** The supplied Looteer also leaves its busy flag stale when its own behavior mode makes it return early, while remaining enabled. Its public interface does not expose that eligibility state. No arbitrary timeout was added that could interrupt genuine loot movement. A companion-side fix would be needed to make that state observable.
- **Alfred versions vary.** Missing queued/caller/paused fields cannot reveal a request before Alfred begins reporting `trigger_tasks`. The orchestrator's dwell and local callback ownership reduce that gap but do not add a missing companion API. The no-pause completion behavior is grounded in the supplied implementation; unprovided commercial or packed forks still require live validation.
- **Unsatisfiable Alfred restock can hold plan creation.** WarPug conservatively respects `need_trigger`; the supplied companion can retain that flag when a configured restock item is unavailable. If the companion provides no reliable completion evidence for a bypass, correct its restock configuration or resolve the pending service rather than expect automatic plan creation to override it.
- **Runtime Season 15 validation remains necessary.** Offline tests cannot confirm current chest actors, cinder costs, boss rewards, world identifiers, UI positions, client responsiveness, or frame-time improvements on the user's game build. Existing data was preserved unless source evidence and a specific regression supported a change.
