# HordeDev dedicated review

## Scope and preservation

This is a separate HordeDev review pass by the Helltide reviewer. The orchestrator
requested reviewer reuse after the available agent-thread limit prevented a new
process; HordeDev retains its own report and tests.

Reviewed main/settings, scheduler/tracker, native sigil activation and entry,
reset/teleport exit, wave objectives and pylons, post-boss aether/chests,
Library navigation, Alfred and built-in salvage, explorer, navigation helpers,
data tables and non-registered legacy tasks. No Horde-specific CLAUDE.md exists.

The prior accepted reset/entry work remains in place. In particular:

- Native `utility.confirm_sigil_notification` is retained, with delayed retries
  and stable portal/arrival evidence before handing off.
- Native `leave_dungeon` is retained; reset is requested only after the expected
  outside world has stabilized, then settles before releasing the queue.
- `reset_exit_pending`, `sigil_activation_pending`, and `horde_entry_pending`
  retain their scheduler priority across world changes and loading.
- External `chests_done()` remains false during pending transactions.

All 350 existing assertions were copied without changing their checks; only
`ROOT`/`package.path` were adapted to the shared suite runner.

## Confirmed repairs

| Severity | Area | Finding and repair |
| --- | --- | --- |
| High | Alfred | Load/completion could pause a companion, unnamed or paused-but-live cycles could be replaced, synchronous completion was overwritten by WAITING, and obsolete callbacks could affect a later run. Initialization/completion now only update local state; live/queued work wins, WAITING precedes trigger, and generation tokens cancel obsolete callbacks. |
| High | Scheduler | `current_task` stayed at the previous task when no predicate matched, including Exit Horde; this could incorrectly satisfy an orchestrator's completion hold. Normal selection now reports Idle while preserving all three pending transaction branches. |
| High | Chest completion | `wait_for_vfx` dereferenced a missing chest; any global chest coin/light effect could also mark an unrelated chest successful. Completion now uses actual aether payment or spent chest state, handles missing actors, and keeps active completion scheduled after the gold actor unloads. |
| High | Chest order | A missing optional chest chose a next chest and then overwrote the state with FINISHED. Exhausted selection returned the same final index forever. Advancement is finite and preserves the configured optional-chest priority. |
| High | Aether | Selected Materials were marked finished after one opening while exit refused to run with remaining aether. Materials now continue while resources remain, then use the existing Gold chest when Materials reject further openings. Gold failure holds an explicit fault instead of claiming completion. No chest cost is guessed. |
| High | Aether evidence | Missing/unavailable aether readings are never treated as proven zero for completion. Post-boss initialization also enters the existing aether-collection stage before chest spending. |
| High | Destructive salvage | The static Mythic SNO list and empty default class filters could allow newer/unrecognized valuable items to be salvaged. Both built-in branches now preserve host rarity 6 or higher and unknown/unreadable rarity; affix mode preserves missing/empty criteria. Locked and known Mythic protection remains. Configured lower-rarity rejection, including junk, remains available. Rarity 6 meaning Unique is grounded in supplied Alfred `core/utils.lua` and Looteer `src/item_logic.lua`; no new item/class ID is guessed. |
| High | Teleport handoff | Clearing stale task status exposed a race: an actual Library arrival could select the next town task before WarPigs observed Exit Horde. The exit task now retains completion evidence only after its requested teleport reaches the expected reliable outside snapshot; reset/enable clears it. The independent common regression reproduces Horde-before-WarPigs arrival ordering and verifies reset on re-enable. |
| High | Loading | Affix-filter initialization required a local player during module load. Filter loading is now lazy and refreshes if character class changes. Normal movement has missing-world/loading/death gates; pending native transactions retain their existing guards. |
| Medium | Chest timers | Opening/VFX/movement/loot delays and failed movement counters survived transitions or reset, causing rapid retries and stale failures. Attempt and per-chest/run timers now reset at their respective boundaries. Failed openings no longer fabricate opened flags. |
| Medium | Movement lifecycle | Disabling or handing off tasks could leave previously issued movement active. A local ownership helper cancels issued Batmobile/explorer movement once, without resetting another activity's movement before HordeDev issues any. Explicit explorer movement remains usable when background exploration is suppressed. |
| Medium | Library walk | Teleport was reissued every pulse while the origin zone remained loaded; a predicate's second branch bypassed loading guards. Teleports now debounce and both branches honor loading. Final Batmobile waypoint advancement can now pass the last index and finish. |
| Medium | Wave targeting | Dead bosses/elites and spent pylons could outrank living enemies. Special combat targets now require living hostile actors, and pylon candidates must be interactable. Per-run interaction/fallback state clears on cancellation. |
| Medium | Built-in salvage | `last_salvage_time` survived reset and prevented a later cycle from processing inventory. Keep counts accumulated across retries, and protected mythic items were omitted from completion counts. Per-cycle state resets and protected items count as retained. Protection is additionally widened conservatively as described above; protected identifiers and filter data remain unchanged. |
| Medium | Settings | False values could not be read/written through the plugin API, and GUI refresh overwrote external writes. Supported values now remain readable and writes update the existing controls. |
| Medium | Chest source | Only actor enumeration was queried despite a documented loot/chest enumeration API. Exact existing chest names now also use that source, skip invalid handles and choose the nearest match. |
| Low | Tracker | The runtime-timer registry retained all historical entries after clearing. It now clears its registry after processing. |

## Validation

Final focused command:

```sh
python3 audit/tests/run_tests.py test_horde_audit.lua test_horde_reset_exit.lua test_horde_sigil_entry.lua
```

Result: all three files pass, comprising **22 new behavior regressions**, the
unchanged **120 reset/exit assertions** and **230 sigil/entry assertions**. The
suite-wide Lua 5.4 compile pass also passes. New checks cover chest payment and
missing actors, unrelated VFX, sequence advancement, aether spending and missing
readings, post-boss pickup, loading, teleport debounce, final waypoint arrival,
living target selection, movement ownership, both chest discovery sources,
class-filter loading, two successive protected-item salvage cycles, unknown-SNO
Unique/higher-rarity retention, unreadable rarity, missing/empty affix criteria,
continued configured lower-rarity rejection and settings. All 33 shared
lifecycle/scheduler contracts also pass, including the independent confirmed
Teleport completion handoff regression.

## Limits and retained data

No in-game execution was available. Live actor availability, target hostility,
chest interaction timing, route geometry, teleport behavior, combat rotations,
companion returns, and current-season content must be verified in the client.
A fault after unsuccessful Gold spending deliberately retains ownership and
resources until the problem is reviewed or the plugin restarted.

All existing sigil, chest, boss, buff, waypoint and movement-spell identifiers,
coordinates, settings hashes and item-filter data remain unchanged. The UI's
selected chest choices are Materials and Gold; Talisman and Greater Affix are
optional priorities. Retained S05/S12 and WarPlans names are source evidence,
not newly validated Season 15 features. Legacy class/affix/protected-item tables
are not a comprehensive current-season inventory contract. Built-in salvage
therefore keeps Unique-or-higher/unreadable rarity and missing/empty affix
criteria for configured Alfred or manual processing. Unregistered
Explore/Kill Monsters/Town Sell/Town Repair helpers remain outside the active
task schedule, as before; they were not silently activated by this review.
