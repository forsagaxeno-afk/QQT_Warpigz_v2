# Reaper review

Scope: all Reaper Lua modules, task order, GUI/settings, README, and recorded-path interfaces. Runtime declarations checked against the supplied QQT API; no live game session was available. Season 15 actor IDs, key costs, teleport SNOs, recorded paths, and Belial UI coordinates are retained, not claimed as verified.

## Fixed findings

| Severity | Evidence in original source | Result |
|---|---|---|
| Critical | `core/task_manager.lua` scheduled `kill_monsters` before `open_chest`; combat's predicate stayed true for the entire activated run. | Reward handling now has priority over persistent combat, allowing genuine completion. |
| Critical | `tasks/interact_altar.lua` counted external success after 25 seconds without checking a kill or chest. | Removed fabricated success; fights remain active until chest completion. |
| Critical | `main.lua` invoked success on a 30-second town timeout, outside town, and skipped normal cleanup. | Confirm town, retry failed teleports, clean up before callback; callback can safely queue another run. Manual stop and failed runs never call success. |
| High | `run_boss`/`run_once` could replace an active rotation/callback; successful disable retained external state. | Busy requests return false, stop resets immediately, and one-shot completion is independent of pool drift and idempotent. |
| High | `set_external(..., 'sigil')` silently converted a sigil request into material farming. The sigil task was not registered and there is no sigil activation path. | Explicit unsupported sigil requests fail without altering rotation or spending material. Other aliases and tier overrides remain available. Dormant legacy module gets safe nil/reset guards; it remains unscheduled. |
| High | Most tasks had no reset; normal completion skipped reset entirely; combat reset failed to unblock movement. | Full per-run cleanup, reset hooks, stale callback invalidation, orb movement release, and loading-screen guards. Shared startup timer is no longer shadowed. |
| High | `core/pathwalker.lua` cleared completion evidence in `stop_walking`; navigation restarted the path before checking completion. Nearby interaction points were skipped. | Persistent completion flag, check before restart, mixed waypoint normalization, required interaction preservation, bounded navigation failure/skip behavior. |
| High | Belial retry math subtracted `pp.x` / `cp.x`, but QQT `vec3` exposes methods. DONE was never scheduled, preventing subsequent reward selections. | Use coordinate methods, service DONE, and reset state between sessions. |
| High | Alfred could claim unlabelled busy work, overwrite synchronous completion with WAITING, and apply stale callbacks. Cleanup could cancel a foreign Batmobile path. | Yield to any busy cycle, set WAITING before dispatch, use callback generation tokens, avoid pausing foreign work, release only tracked Reaper navigation before Alfred starts, and defer new maintenance during fights/chest sequences. |
| Medium | Inventory scanned two bags without deduplication; zero-count stacks became one; manual-mode stock check required checkboxes. | Deduplicate QQT `game.item_data` by documented `get_acd()` with compatibility fallback, preserve zero stacks, honor manual target. |
| Medium | Narrow Grigoire/Varshan zone checks disagreed with shipped altar aliases; absent world caused errors. | Central literal zone matching for existing aliases and safe no-world handling. No guessed IDs added. |
| Medium | Periodic dungeon reset was forbidden inside any boss zone; consecutive same-boss runs therefore never reset. | Exit to configured town between completed runs before resetting, with bounded teleport retry intervals. |
| Medium | Chest actor disappearance in one update could count success despite reappearance during the loot pause. | Recheck throughout completion wait and resume the chest phase if it reappears. |
| Medium | Exhausted navigation reset its own retry counter indefinitely; external chest failures could restart the same one-shot forever. | Skip failed boss for current rotation without decrementing shared materials or reporting a kill. |

## Verification

`python3 audit/tests/run_tests.py test_reaper.lua` passes with Lua 5.4. The behavioral regression file exercises actual modules and QQT-shaped mocks: duplicated inventory wrappers sharing an ACD, separate/shared tier rotations, external idempotency, busy rejection, scheduler chest priority, temporary actor disappearance, timer rejection, town retry, reentrant callbacks, failed-run callback suppression, Belial retries and repeated cycles, Alfred synchronous/stale callbacks, foreign movement ownership, path completion/interactions, known zone aliases, and periodic resets. It also compiles every suite Lua file through the shared runner.

## Remaining live-validation limits

- The S15 official patch notes do not specify QQT SNO/actor IDs. This patch preserves supplied IDs and removes the source's unsupported claim that a specific historical patch removed a seasonal chest.
- No offline test certifies key costs, current boss teleport destinations, route geometry, Belial dialog layout, party loot ownership, or loading behavior. Pixel coordinates remain user-calibratable.
- Material completion relies on the shipped reward actor patterns becoming absent/non-interactable after interaction, with a confirmation pause. It is not a server-side transaction receipt.
- A fight with neither a matching reward chest nor an explicit game-side failure can remain active. This is deliberately not converted into a successful run after a timer.
- Sigil farming requires a verified activation and completion contract before it can be supported; the old implementation did not contain one.
