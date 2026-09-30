# HelltideRevamped dedicated review

## Scope and evidence

Reviewed `main.lua`, GUI/settings, task scheduling, utilities and tracker,
Alfred integration, the complete Helltide and search task state machines,
experimental exploration, route loading and data tables. The task actively
uses Batmobile and direct pathfinder fallback; the older `core/explorer.lua`
and `core/explorerlite.lua` are not required by this task graph.

API evidence: supplied QQT `#api/actors_manager.lua` documents `get_all_actors`;
`#api/loot_manager.lua` documents `get_all_items_chest_sort_by_distance`;
`#api/classes.lua` documents actor skin, position and interactability. The
supplied Alfred and Looteer source was also examined, with integration findings
cross-checked by the common auditor and Batmobile critic.

## Confirmed defects repaired

| Severity | Location | Defect and resulting repair |
| --- | --- | --- |
| High | `tasks/helltide.lua`, `core/chest_targets.lua` | Choosing the nearest actor before testing interactability or blacklist hid other same-type chests. All eligibility filters now precede nearest selection. |
| High | Same | Discovery queried only the actor list, although the host provides a dedicated loot/chest list. Both sources are merged and duplicate actor references removed; invalid handles are skipped. This proves the missing source path, not that any particular live chest is missing from the first source. |
| High | Same | A chest could be selected beyond 50 units then immediately abandoned by approach logic. Direct range is now consistent; affordable distant sightings enter remembered recall, whose existing maximum is 150 units. |
| High | Same | Reacquisition by closest matching name could bind to another chest. It now requires a matching actor within four units of the selected position. Cache keys also distinguish height. |
| High | Same | Interaction could retry forever at a reachable chest if no combat was present and no successful opening occurred. Six rejected attempts now produce a 60-second blacklist. |
| High | Same | Cinders lost en route could leave an unaffordable chest targeted. Affordability is rechecked and its position retained for later recall. Cinder-payment completion also works when the actor has unloaded. |
| High | `tasks/search_helltide.lua` | Every search iteration reset the cycle counter and cooldown; the cycle boundary also excluded the fifth destination. Session reset is separated from scan progression, every destination is tried and cooldown survives. |
| High | Same | Teleport requests were repeated every pulse before the teleport buff appeared. Each destination now uses the existing six-second debounce. |
| High | Same | An override zone unconditionally suppressed search after the farming task stopped owning it. Search now defers only while the Helltide task actually owns the override. |
| High | `tasks/alfred.lua`, task manager | Module loading/cleanup could pause Alfred, unnamed active cycles could be replaced, and synchronous completion was overwritten by WAITING. Loading and completion no longer mutate Alfred ownership; busy/queued cycles always hold the queue, WAITING precedes trigger and generation tokens invalidate canceled callbacks. |
| High | Main/task manager/Helltide | Disable or task handoff could leave autonomous Batmobile long-path movement running. Owned movement is suspended before handoff; explicit stop invalidates local sessions without resetting another movement owner. |
| Medium | `tasks/helltide.lua` | Disabled Looteer could leave `looting=true` and stall Helltide forever. Yield now requires Looteer enabled as well. |
| Medium | Reset/route loading | Actor-derived caches, blacklists, interaction snapshots, Maiden state and old waypoints survived reset. Full reset clears these; unmatched region loading clears the old route. |
| Medium | Main/settings | False settings were unreadable/unsettable; GUI synchronization overwrote external changes. False values remain supported and external writes update the existing GUI controls. |
| Medium | Main/utils | Main task execution could run with no world or in Limbo; region checks dereferenced missing world state. Loading guards and nil-safe region checks added; matching uses a literal region prefix. |
| Medium | Helltide/Alfred | Full inventory with salvage disabled or no available Alfred repeatedly entered a no-op town branch. Service handoff now requires enabled salvage and an available enabled Alfred. Idle search delegates service requests to the same ownership-aware task. |
| Low | Task manager | Status retained the last task after no predicate matched. It now reports Idle. |

## Diagnostics and preserved behavior

The existing `Draw chest status` setting also enables scan diagnostics, at most
once per five seconds. Unknown Helltide/reward-gizmo skins log once per session
and remain unselected. This makes changed skins distinguishable from cinder,
range or blacklist filtering without guessing seasonal names or costs.

Existing persistent control hashes, five regional routes and waypoint IDs,
source-provided buffs/costs, explicit zone overrides/exclusions, Maiden priority,
orbwalker opt-in and other activity options are preserved. The five routes are
selected by their existing literal region prefixes. No new seasonal ID or
waypoint coordinate was added.

## Validation and practical limits

`python3 audit/tests/run_tests.py test_helltide.lua` passes 16 behavior
regressions and the suite-wide Lua 5.4 compile pass. Tests execute the real
Helltide/search/main modules with host stubs, as well as the candidate-selection
module. The shared contract tests independently cover Helltide's Alfred
lifecycle and task handoff behavior.

No game session was available. These results establish source-level behavior;
they do not prove Season 15 live actor names, costs, event timing, route
walkability, waypoint availability, combat rotation effectiveness or traversal
success. The cinder table is unchanged. The S10 Chaos Rift skin and Helltide
buff hash are retained source data, not newly certified seasonal features.
Existing exclusions (`Hawe_ZakFort`, `Skov_Skartara` in the specified world)
remain deliberate configuration and can still prevent farming in those zones.
Maiden intentionally precedes chests when enabled; the cinder cutoff releases
that priority. Enabled Looteer behavior modes with a stale busy flag still lack
an explicit companion-side activity/status signal; disabling Looteer is now
handled, while changing its internal behavior would be a companion change.
