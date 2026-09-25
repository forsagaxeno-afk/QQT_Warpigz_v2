# Changelog

All entries are in English. QQT_Warpigz_v2 release numbering starts with **2.0.0**. Earlier component versions and the imported Git baseline are not earlier releases of this project.

## [2.1.1] — 2026-09-25

Fixes from the first live reports on v2.1.0.

### Fixed

- HelltideRevamped: "works for a few minutes, then searches for a Helltide in the middle of a Helltide". When the Helltide buff dropped for a moment (walking over the zone edge, a cellar, a buff refresh), the very next tick went to the search task, which reset HR and teleported away before HR could notice it had left the zone and walk back. HR now keeps the tick for 15 s after the buff was last seen while the Helltide hour is active, walks back into the zone, and gives up walking back after 90 s (logged) before searching.
- WonderCity: "teleports to the entrance 5 times in a row, then starts the run". The Kurast teleport retried after 3 s, which is shorter than the channel plus loading screen, and the walk watchdog re-teleported to the same waypoint every 15 s while the player stood still after arrival. The teleport now waits 8 s and never retries during a loading screen; the watchdog ignores the teleport cast, waits 12 s, and re-teleports at most twice per stall (logged), then walks on.

### Validation

- `python3 audit/tests/run_tests.py`: 42 test files × (Lua 5.4 + LuaJIT) = 84 runs pass. New regressions reproduce both live reports on 2.1.0 and pass now.

## [2.1.0] — 2026-09-25

Integration release. A team of ten domain reviewers, one auditor and one critic checked every plugin for joint operation; five review/fix rounds followed, driven by the audit, the critic and real QQT client logs. All credits for the original foundation go to **@ZEWX — LONG LIVE LEGEND**.

### Added

- **Infernal Hordes War Plan steps enter through the War Plan teleport, never a compass.** WarPigs option *Hordes: enter via War Plan teleport (no compass)* (default on) presses `warplan.teleport_to_activity()` itself, also with *Use teleport* off, logs each landing, and starts HordeDev with `enable({entry='warplan'})` only inside the Horde. HordeDev's War Plan mode never uses a compass or the Library walk, finishes a 6-wave horde even without a chest room, leaves with Leave Dungeon and reports `completed`. Three missed landings back off 60 s with a visible reason; *Allow compass entry if the War Plan teleport fails* (default off) is the only compass path. Reloads mid-horde, Alfred's own trips out of the horde and hotkey pauses are handled.
- Shared cross-plugin contract: one Alfred status reading everywhere; additive status fields (`HordeDev in_run/fault/exit_pending/entry_mode`, `Reaper in_run/external_run/last_result`, `Arkham/WonderCity alfred_trip/in_run/committed_entry`, `hold` texts); `BatmobilePlugin.release(caller)` and `get_owner()`; Reaper `run_once` reports `success`/`failed`/`cancelled` exactly once.
- `audit/tests/joint_host.lua` + `test_joint_suite.lua`: all nine real plugins in one emulated QQT host (per-plugin module caches, one shared `_G`, caller-context `require` detection) — 34 scenarios over the whole War Plan loop.
- `run_tests.py` runs every test under Lua 5.4 **and LuaJIT**, compiles all runtime files with LuaJIT, rejects Lua 5.2+ library use and reports functions near the LuaJIT limits. `audit/LIVE_CHECKLIST.md` lists the log lines to confirm in the client.

### Fixed

- **The suite did not work on QQT's LuaJIT runtime.** WarPug's planner called `table.unpack` (nil in LuaJIT): every War Plan path search halted (`attempt to call field 'unpack'`), so no plan was created at the table. WarPigs' `orchestrator.tick()` captured 61 upvalues and did not compile at all (limit 60). HelltideRevamped's `reset()` was at 59.
- WarPigs: no teleport away from a running Alfred cycle in any town; activities resume in place after a WarPigs off/on; Pit/Undercity are not released on their own Alfred trip or during entry; failing Reaper bosses back off instead of looping; the WarPug ↔ Whisper circular wait is gone; Alfred's latched `teleport` flag no longer livelocks town handoffs; a sticky restock flag triggers at most one Alfred trip per Temis visit; the turn-in after a Horde waits about 3 s instead of 20 s; unmapped War Plan quests, refused runs, unconfirmed enables and every long hold are logged and shown; all holds are bounded.
- WarPug: companion work pauses a plan session instead of halting WarPug; Alfred admission follows the shared reading; capture keybinds register every press.
- SilentRaven: reward cards are no longer rejected when the host does not send `valid=true` (live `failed (no_valid_reward)` with a normal 4-card panel); selection verification tolerates host conventions and dumps the reward fields once when it cannot verify; ESC only while the panel is open; the Temis walk detects stalls; a Looter burst pauses instead of cancelling a managed claim.
- Batmobile: a released plugin's target, long path, traversal state and explorer priority no longer steer the next plugin (live: stale Temis target after the Pit); paused holds no longer trip false trap/giving-up; inert traversals are abandoned; explorer state follows world changes and is restored when the same pit is re-entered.
- ArkhamAsylum / WonderCity / Reaper / HordeDev / HelltideRevamped: the sticky Alfred grace survives task switches (no endless Alfred loops); unreadable Alfred status is bounded; orbwalker clear/block states are restored on every exit; time spent yielding to Looter/Alfred no longer counts as "stuck" (live: Helltide blacklisted reachable chests while waiting for the Looter).
- WonderCity: no endless wait at the brazier with default tribute settings, nor at an already opened reward chest (live).
- HordeDev: chest/exit/entry faults are reported and exit instead of freezing WarPigs; teleports are not re-fired into their own channel; a persisted-on HordeDev waits for WarPigs before acting; out of compasses at the gate it still asks Alfred to restock them.
- Reaper: waits for the Looter before leaving the lair; Belial one-shots are refused when the chest sequence is off; the periodic dungeon reset also runs under WarPigs.

### Changed

- WarPug `positions.txt` ships **uncalibrated**; the calibration shipped by earlier releases is ignored. Capture Reroll/Confirm positions after installing or updating (or restore your own file).
- While WarPigs is enabled, activity plugins leave advisory Alfred flags (restock/stash without a full bag or repair) to WarPigs, which services them once per Temis visit. Hard needs and standalone use are unchanged.
- The README now says to copy only the nine plugin folders into `scripts`.

### Validation and limits

- `python3 audit/tests/run_tests.py`: 41 test files × (Lua 5.4 + LuaJIT) = 82 runs pass; all 202 runtime files compile under LuaJIT. See `audit/VALIDATION.txt` and `AUDIT.md`.
- No live Diablo IV/QQT run is claimed by these tests. Still to confirm in the client: where the War Plan teleport lands for a Horde, SilentRaven's reward-selection conventions, native `request_move` behaviour during Looter activity, chest actor states after opening, and whether closed-source Alfred/Looter drive Batmobile under their own caller names.

## [2.0.0] — 2026-09-24

First maintenance release of **QQT_Warpigz_v2**. All credits for the original foundation go to **@ZEWX — LONG LIVE LEGEND**.

### Added

- Direct SilentRaven integration with WarPigs for completed Whisper reward checks during stable visits to Temis only. Loot Steward is not required.
- Explicit request ownership, visible pending state, cancellation, bounded retries, and generation-safe managed Whisper callbacks.
- Reward-selection validation and observed cache receipt before SilentRaven reports a successful claim.
- Component and cross-plugin regressions, review records, source inventory, and release-version checks.
- Project branding, preserved credits, English notes, and separate bundle/component version tracking.

### Fixed

- Reaper's externally triggered `reset_run` crash caused by generic modules resolving in another plugin's context. Captured imports retain the correct tracker and helpers.
- Infernal Hordes Chaos Rift combat portals being ignored while the controller returned to the center. Recognized live hostile portals receive appropriate combat priority.
- Undercity completion around the boss and final chest. Missing actors alone no longer prove completion; rewards take priority over exploration.
- WarPigs treating unreadable/sparse quest snapshots as activity completion, accepting unknown town state, and allowing obsolete Alfred callbacks to affect later cycles.
- WarPug starting through active town companions, disagreeing with confirmed Alfred service completion, and trusting stale Temis data during loading.
- Alfred callers overwriting observed work, resuming pauses they did not acquire, and waiting indefinitely after rejected, thrown, or lost-callback requests.
- Batmobile autonomous updates undoing external pauses; Reaper treating unreadable companion/actor state as safe completion.
- Repeated altar, heart and shrine interactions, false traversal completion during approach, and dungeon cleanup clearing Alfred's newly acquired route.
- SilentRaven/WarPigs callback-order races, repeated teleport requests during a cast, and progression with a missing/dead player or loading world.
- Completed-Alfred advisory grace expiring during an already accepted Whisper request; live work and unreadable status still revoke the request.
- Horde reward/exit progression competing with observable looting, and outer Alfred checks failing on unavailable status.
- Helltide traversal blacklist scope, premature Maiden charging retries, invalid fallback target selection, and native movement cleanup when yielding.

### Performance and coordination

- Removed an unused large walkability scan from Horde updates.
- Bounded repeated movement, interaction, teleport and revival requests in reviewed paths.
- Preferred read-only modern Looter activity exports with legacy false-as-nil compatibility. No unsupported Looter pause/settings mutation is introduced.
- Namespaced SilentRaven modules to avoid generic module-cache collisions.

### Validation and limits

- `audit/VALIDATION.txt` records the final offline run; `AUDIT.md` documents review coverage and live checks.
- No live Diablo IV/QQT run or measured FPS improvement is claimed. Current packed Alfred/Looter internals were not recovered or certified.
- The reported LooteerV3 `approach_stall` needs exact source/runtime evidence. Outer town coordination fixes are included.
