# Batmobile 1.0.12 — dedicated critic review

Reviewed the complete 16-file plugin: navigator, heap A*, smoothing, exploration/backtracking, long-path driver and external API, movement rules/conditions/helpers, GUI/settings, drawing, instrumentation, and lifecycle. Changes retain public `BatmobilePlugin` signatures, caller labels, path result shape, exploration history on `reset_movement`, custom movement while paused, traversal routing, and the existing pathfinding budgets. No spell/class IDs or season-specific values were changed.

## Fixed findings

| Severity | Source | Finding and correction |
|---|---|---|
| High | `core/navigator.lua`, chain crossing | The chain branch added a timeout to undefined global `now`, crashing when another same-direction traversal was found. It now uses the branch's existing local timestamp. Corrected `trap_escape_pos` to the real `trav_escape_pos` field. |
| High | `core/navigator.lua`, traversal handling | The same traversal buff was processed on successive ticks: history was appended again and a newly chained traversal could be mistaken for a second completed crossing. A rising-edge latch handles each continuous buff once; movement/spells wait for the animation buff to finish. This also avoids interacting again while already traversing. |
| High | `core/navigator.lua`, `set_target` / unstuck | `disable_spell` was compared but never assigned, contradicting the README's documented API. Accepted targets now retain it, including deferred traversal destinations; unstuck evade also honors it. Crossing does not silently discard the flag. `reset_movement` clears it. |
| High | `main.lua` | Freeroam dereferenced a missing player. Dead players could receive movement immediately after asynchronous revival, and every tick sent another revive request. Missing/loading/dead actor states now gate movement; revival retries at most once per second. Existing loading unstuck grace remains. |
| High | `main.lua`, `core/external.lua`, `core/long_path.lua` | Long-path completion/query could treat a traversal's temporary nil target or intermediate escape/approach target as completion. Both now recognize pending traversal state. Explicit API resets and the reset hotkey cancel autonomous long-path work before resetting navigation. `stop_long_path` also clears its pending traversal route. |
| Medium | `core/long_path.lua` | A new successful route inherited old partial/stall state, pathfinding cooldowns, escape destination, spell prohibition and stuck position. These fields now start fresh. `unpause()` also synchronizes the tracker. The drawable full route is copied instead of aliasing a path that unstuck can mutate. |
| Medium | `core/utils.lua` | Crowd-control hashes were string keys while QQT declares numeric `name_hash`. Numeric and serialized hashes are recognized, restoring the existing unstuck suppression. |
| Medium | `core/navigator.lua`, closeby/traversal routing | Approach search validated the snapped point but returned the original point at the player's height. It now returns the validated point. Fractional radii no longer fail `%d` formatting. Routing without a current target no longer crashes in the diagnostic string. |
| Medium | `core/pathfinder.lua` | Path reconstruction repeatedly inserted at array index 1, shifting the entire accumulated route. Append and one reverse retain exact waypoint order with linear work. Removed an open-set map that was written but never read. |
| Medium | `core/explorer.lua` | Backtrack restoration walked all historical frontier indices, including deleted holes. Its existence query now checks active frontier entries; the backtrack stack logic is unchanged. Reset also resets the eviction counter. |
| Medium | `core/movement_helpers.lua` | Pack scoring fetched each enemy position once for every sampled path node. It now snapshots positions once per density evaluation and retains the existing counts, sampling and earliest-maximum tie rule. |
| Medium | Movement engine/conditions and navigator spell diagnostics | Rule/cast diagnostics unconditionally formatted and wrote multiple console lines during normal operation. They now respect the existing DEBUG level; diagnostic `string.format` happens only when enabled. Other navigation/trap/performance logs remain available. |
| Low | Target setters / main driver | Nil target inputs return failure; both freeroam and long-path no longer drive update/move in the same tick. Navigator movement reset invalidates the short actor/buff caches. |

## Evidence and regression results

Run from the suite root:

```text
python3 audit/tests/run_tests.py test_batmobile.lua
```

Result: **12 tests, 84 assertions passed** under the system Lua 5.4 library. The shared runner also compiled all 182 current runtime Lua files. Tests exercise actual plugin modules with deterministic QQT doubles; they are not live client tests.

Coverage includes custom targets/paused movement, sub-2-unit target drift path reuse, no-spell requests during both normal and unstuck movement, explicit reset history preservation, traversal approach Z, a two-tick continuous traversal buff, chain state/timestamp, full and partial A* routes, a wall detour, result snapshot call IDs, long-path startup/reset/stop/query contracts, null player, loading/death/revival, and concurrent freeroam/long-path toggles.

| Reproducible operation-count fixture | Original work | Patched work |
|---|---:|---:|
| Reconstruct a straight 201-node path | 20,100 shifted array entries from front insertion | 0 shifted entries; 200 appends and 100 swaps |
| Score 24 path nodes against 10 enemies | 240 host `get_position` calls | 10 host calls |
| Restore backtrack with frontier index 100,000 and no live frontier | 100,001 historical index reads per secondary node | 0 historical reads |
| Successful movement rule plus `skill_ready`, normal log level | Diagnostic formatting and console output unconditionally | 0 diagnostic `string.format` calls and 0 console calls |

These count fixtures demonstrate reduced work, not an FPS or route-time promise. Some diagnostic arguments such as `vec_to_string` are still evaluated before the debug logger; the zero-format result specifically counts `string.format`. No A* caps, retry delays, traversal cooldowns, movement rate, smoothing limits, or exploration radii were lowered for a speed claim.

API grounding: supplied QQT `classes.lua` declares `name_hash` as numeric and `buff:name()` as callable; `actors_manager.lua` declares the no-self enemy enumeration function. The root audit separately checked current QQT declarations. Existing `utility.set_height_of_valid_position` usage was retained; this change does not introduce the separately documented native `world:calculate_path` API.

## Consumer contracts and remaining risks

- `pause(caller)` remains an **exploration pause**. Explicit `set_target` + `move` continues to work, as required by existing WonderCity, Arkham, Helltide and other callers. An autonomous long path remains active until stopped/reset/completed. Callers yielding ownership must stop their own long path, clear their target, then pause. There is no reliable owner identity API; `tracker.external_caller` records the latest call, not ownership. This was communicated to the Helltide, Arkham and common reviewers.
- Full reset remains the boundary for explorer/world caches. Explorer visited/scanned keys and A* evaluated keys are planar; stacked floors or geometry changing without reset remain a live validation concern. A global cache/key redesign would change exploration and partial-path behavior, so it was not attempted here.
- The movement-rule engine's next-node selector has no legacy-style interpolation when smoothing leaves the next waypoint beyond spell range. Its per-rule throttle starts at selection, even if a later raycast/cast fails. These are concrete remaining rule-engine limitations; they were not concealed by changing skill IDs, readiness checks or cast type.
- The navigator's distance-to-next-waypoint replan heuristic can regard a long smoothed segment as a deviation after the existing cooldown. Changing it requires reliable segment/progress tracking and representative obstacle traces. The current patch reduces work without replacing route-following semantics.
- Chain traversal selection still infers direction from gizmo names and inspects actors near the position when the buff first appears. The latch fixes duplicate handling; it does not prove that all live chain destinations are selected on the correct floor. Verify climb/ladder/jump routes in client.
- `get_closeby_node` retains the existing eight candidate / 40 ms per candidate feasibility budget; runtime long paths retain 10,000 iterations / 300 ms, and the explicitly invoked debug path button retains its 100,000 / 15-second safety ceiling. Synchronous worst-case work can still be visible. No async scheduler or speculative native-router replacement was introduced.

## Independent integration follow-up

The common auditor reproduced one additional streaming case after the initial review: a temporarily empty actor scan on the first traversal-buff tick consumed the buff edge without processing the remembered crossing. The root reviewer expanded the crossing gate to include the remembered traversal or a fresh buff edge. The independent `test_batmobile_integration.lua` failed before that change and passes afterward, including first-tick processing and movement suppression during the continuous animation. The original 12 tests / 84 assertions still pass.

Recommended live checks: one normal exploration route; a paused consumer's custom target with spells prohibited; a long route crossing a ladder and jump; disable/yield during a long route; death/loading recovery; a dense combat path with movement rules. Capture existing performance counters and compare route success as well as timing.
