# WonderCity dedicated review

Scope: every runtime module, tribute selection and legacy reorder task, entry/confirmation/bargain state machine, town routing, beacons/enticements, floor portals, bosses, chests, obols, both explorers, task priority, settings/UI, and Alfred/Batmobile/Looteer contracts. This was a separate plugin-specific pass after the Arkham review. Verification is offline; game-client behavior was not exercised.

## Corrected findings

| Severity | Finding | Correction |
| --- | --- | --- |
| High | Tribute selection fell back to the first dungeon key even when every configured tribute was unavailable or priority zero. | Consume only a configured positive-priority match. Wait visibly when none is available; preserve the explicit Skip tribute option. |
| High | Missing/out-of-range slot indices produced arbitrary screen positions. An inventory reorder between hover and click could consume a different item. | Validate the declared 11-by-3 inventory bounds and integer slot; resolve the selected SNO and slot again before right-clicking. |
| High | Entry guarded actor queries only inside its own Execute, while higher-priority Alfred/walk predicates could already query actors during the documented unsafe post-click windows. | Expose the entry guard to the task manager and check it before any predicate. Preserve the guard deadline across cancellation. |
| High | The confirmation dialog could close the vendor screen, causing the brazier to reopen before ACCEPT. Numeric step comparison also classified TRIBUTE_HOVER as ACCEPT_WAIT. | Drive explicit confirmation steps while the vendor is closed, and test the exact ACCEPT_WAIT state. |
| High | Failed bargain retries reset the index on reopening, so the first choice repeated indefinitely. Temis retreat used a distant Kurast waypoint. | Preserve retry progress across reopening, use a local retreat for the alternate town, and bound the retreat wait. |
| High | Floor-local timers/actor state and custom-explorer boss-room state survived transitions. The run timer was reset on repeated portal interaction, before successful entry. | Observe stable world/name/zone transitions before priority selection. Reset floor tasks and Batmobile once after confirmed arrival. Preserve the run deadline and overall enticement count across floors, with floor-qualified objective keys. |
| High | Dead bosses and goblins were selected before their health was checked, blocking reward chest processing. | Reject dead actors before special-target selection. Boss delay applies to runtime boss classification instead of relying only on a fixed skin-name list. |
| High | An interactable chest that refused every click was marked successful after eight seconds. A successfully clicked chest that despawned never completed. | Distinguish a failed chest from success; retain the configured run deadline as recovery. A close-range clicked chest that becomes non-interactable or disappears completes the task. |
| High | Explorer exhaustion could trigger early exit; the reset deadline could be blocked by loot/objective tasks. | Normal exit requires the completed chest task. The configured deadline preempts normal content/loot work, while observable enabled Alfred service retains ownership. |
| High | Pause alone did not stop Batmobile's independent long-path driver. Old movement could interrupt UI interactions, chest handling or exit. | Stop owned movement on handoff/stationary interactions; release synchronously on external disable, without cancelling Alfred's trip. |
| High | Alfred load/completion mutated the companion, busy unnamed/paused cycles could be overwritten, synchronous callbacks lost their status, and stale callbacks survived cancellation. | Local-only completion, busy-cycle preservation, WAITING before trigger, generation checks, both global aliases, and cancellation of all pending local sessions. Remove competing teleport calls after Alfred's teleport-owning trigger. |
| Medium | Enticement timers followed the nearest actor, so switching objectives inherited an expired timer. | Bind interaction timers to the exact floor-qualified objective key. |
| Medium | A visible portal switch required a separately visible warp pad to activate its task. An already-reached empty warp pad could monopolize priority. | Accept a visible switch directly; yield an arrived pad while waiting for its portal. Debounce portal clicks. |
| Medium | The custom explorer recorded unreachable objectives but immediately selected them again; stale boss-room state blocked its reset. | Honor unreachable cells for objectives/frontiers and reset floor state before predicate gating. Guard absent actor names. |
| Medium | Obol detection depended on English display text, checked the cap only for equality, and could chase an unreachable pickup forever. | Prefer documented `loot_manager.is_obols`, retain a guarded fallback, compare the existing cap with >=, scope to Undercity, and bound failed navigation. |
| Medium | Disabled Looteer exposed stale busy state; missing worlds crashed utilities; stale task labels and missing GUI tree pop remained. | Gate looting on enabled status, guard loading worlds, clear expired task display, and balance the party settings tree. |
| Medium | Town routing continued despite a visible brazier/portal; teleport could be retried during its own active cast. | Yield fixed routing to the live entrance task, preserve active teleport casts, reset watchdogs by world, and debounce revive requests. |

## Verification

`python3 audit/tests/run_tests.py test_wondercity.lua` passes 22 focused Lua 5.4 regressions. Coverage includes missing worlds, disabled Looteer, unavailable tribute selections, invalid/reordered inventory slots, vendor-close confirmation, the global actor guard, bargain retry order, town-route yield, run/floor state, deadline/foreign-service ownership, dead enemies, incomplete exploration, failed/despawned chests, per-objective timers, standalone portals, arrived warp pads, custom-explorer floor reset/unreachable handling, obol identity/cap/stall behavior, and the inactive legacy sort task.

The independent suite contract tests pass all WonderCity Alfred load/busy/synchronous/cancellation checks, stale-task status and disabled-Looteer behavior. The shared runner also compiles every runtime Lua source before testing.

## Preserved settings and live-validation limits

- Existing GUI keys, priorities, SNO IDs, town coordinates, recorded Kurast path, item lists, objective actor names and default options are preserved. No Season 15 numeric ID was guessed.
- Current entry selects a tribute directly from its configured inventory slot. `sort_tribute.lua` is a legacy, unregistered task with no current reorder setting; it remains inactive and now handles empty/missing data safely. The older README's three-tribute stash-reordering description was obsolete.
- Mouse click points and the inventory grid still require the user's calibrated UI layout. The host API does not expose the actual confirmation dialog, selected tribute or selected bargain; the guarded state machine cannot prove those UI selections succeeded. Verify a full entry cycle in game.
- The source's obol cap (2500), healing-well boss-room heuristic, boss-delay behavior, channel timings and interaction radii remain game-dependent. No new Season 15 claim is made for those constants.
- A timed-out chest is reported as a failure; it waits for the configured run reset rather than claiming rewards were collected. Party/Magoogle integration remains explicitly unfinished upstream functionality.
- World identity cannot distinguish an unobserved new instance if name, zone and world ID are all reused. Older Alfred APIs also do not expose every queued foreign request. These are API observability limits, not validated live-game guarantees.
