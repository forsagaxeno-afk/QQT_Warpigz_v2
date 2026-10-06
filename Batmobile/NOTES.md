# Batmobile: session notes (current 2.2.7)

The shared movement / navigation core: explorer, pathfinding, long paths, the movement-skill catalog (evade, Warlock Rampage) and freeroam. Most activity plugins move through `BatmobilePlugin` (`set_target` / `move` / `pause` / `resume` / `stop_long_path` / `is_paused` / `get_owner`).

- Rosie pauses Batmobile during a town trip (`lifecycle.hold_peers`).
- Freeroam holds its movement 10 s for a busy Looter (`main.lua:37`).
- Known test caveat: the explorer's `pairs` order depends on the hash seed; the joint host has an `ordered_pairs` option (the old W2 flake).
- The third-party **Navigator** (with Worldstone) is a different navigator and not ours.

## History
- 2.2.7 (Auditor review of 3.3.24, LOW; `test_batmobile_enigma_starvation.lua` E1-E4, E1-E3 fail on 2.2.6): Enigma Teleport no longer starves the class movement spells.
  - `movement_cast.position` arms the Enigma throttle on every attempt that reaches the projection, so a refused click (node off-screen, w2s nil/NaN) no longer leaves `enigma_ready()` true on every tick (was 48 Enigma picks to 2 class picks in 200 ticks).
  - The legacy selector alternates: after an Enigma pick the next one goes to a castable class spell (`navigator.last_pick_enigma`); Enigma alone keeps every pick. The class chain is now `class_movement_spell()`.
  - Revamp: `engine.pick` skips input-action rules (Enigma) when `ctx.no_input_action` (town) before stamping `last_fire`.
  - `movement_rules` catalog note: order is append-only (fixed ids 1-14, Rampage 15, Enigma 16); new skills go after Enigma.
- 2.2.6 (community Enigma Teleport, `core/movement_cast.lua`; merged by the Coordinator).
- 2.2.5 (Auditor LOWs on 2.2.4): the `[unstuck] … replanning, target kept` and `[unstuck] EXHAUSTED` lines go through `nav_log` too; B10 now also covers both `PARTIAL PATH SKIPPED` lines and the two `[unstuck]` lines; the 2.2.4 lines carry their version marker. `test_integration_batmobile.lua` BAT-4 reads the replan line at Debug.
- 2.2.4 (scenario sweep 2026-09-28, §2.5 B1; test B10): the per-attempt `[nav] STUCK`, `PARTIAL PATH REJECTED` and both `PARTIAL PATH SKIPPED` lines go through `nav_log` (Disabled: none, Info: one per 5 s with `(+N similar)`, Debug: every line). A wedged paused caller printed 236 STUCK lines in 60 s. `test_batmobile_nav_recovery.lua` N5 now reads STUCK at Info.
- 2.2.3 (Coordinator, 3.3.x): freeroam does not double-wait for Rosie's pickup (see CHANGELOG).
- 2.2.2 (self-review "the bot goes back and forth", `test_batmobile_oscillation.lua`):
  - **Path look-ahead jitter.** A node closer than `movement_step` (4 u) was skipped but stayed `path[1]`. Walking on to the next node took the player back beyond 4 u of it, so the next tick walked back: an endless back and forth on the 4 u ring that never read as STUCK (position kept changing). Hit a node left behind by a Looter/fight detour, the unstuck side-step node, and hairpin corners. Now skipped nodes are dropped once a later node is walked to; the look-ahead skips only when that node is in straight reach (`in_straight_reach`, first 6 u sampled like the string-pull), else the path is followed node by node; the unstuck side-step (`side_step_node`) is walked to until reached. Offline sim: an open room with a pillar now finishes exploring (before: stuck at an unstuck node forever).
  - **Auditor round (audit/reviews/repro_batmobile_full.lua R1–R6; tests B4–B9):**
    - R6 traversal limbo: displaced 3–5 u after a non-Jump interact, nothing drove the player back and every `set_target` was deferred. Now it walks back to the interact spot (1 u nearer the gizmo), at most `TRAV_REAPPROACH_MAX` = 3 times, then `abandon_traversal`. A buff-missed crossing also counts when the player stands >3 u away on another floor (|dz| ≥ 1.5), so a real climb is never walked back.
    - R1 respawn detector: a caller goal set after the last explorer scan (`target_set_at > explorer_updated_at`) survives the >50 u jump check (HordeDev same-zone re-teleport). Not "only if the last update was recent": a real death also stops updates, and the detector must still fire then.
    - R2 `get_owner()` is nil once no goal is held (`clear_target`, `stop_long_path`, a goal the navigator dropped); traversal routing still counts as held.
    - R3 the move-gap compensation never pushes `last_update` past now: after a load, STUCK is back after main.lua's 5 s grace (+1 s), not load time + 6 s. The 5 s grace itself is kept.
    - R5 a paused/custom caller within `CALLER_GOAL_REACH` = 3 u of its goal (boss hitbox) gets no STUCK/unstuck/Evade.
    - Freeroam also yields to a busy `Scavenger.is_busy()` (Navigator's looter; Coordinator request).
  - **Unbounded STUCK suppression next to a traversal.** A player held 3–5 u from a gizmo (a blocker the walk grid does not know) had STUCK suppressed forever and trap escape kept routing to the same gizmo. Now at most `TRAV_APPROACH_MAX` = 5 s per gizmo, then it is dropped like an inert one (`abandon_traversal`: 60 s blacklist, the caller's goal given back). The "STUCK suppressed" line goes through `nav_log`.

## Reviewed, no change (2.2.2)
- Explorer `direction` fallback picks the first zero-penalty in-range frontier in `pairs` order (arbitrary). A nearest-frontier rule was measured in the offline sim: better on a comb map, worse on a room grid. No evidence it causes back and forth; left as is.
- `pause` / `resume`: any caller's `resume` lifts any pause (owner not enforced). Needed for activity hand-offs (a new activity resumes a pause a previous one left). Rosie's `release_peers` resumes only a Batmobile still paused, and a paused Batmobile never drives on its own (freeroam off, long route stopped by `hold_peers`).
- Post-traversal escape, inert gizmo interacts, exploration resets and trap `giving_up` are bounded.

## Open
- Auditor LOW (uncertain), not done: the walkability grace after a load is a fixed 3 s; `wall_penalty_cache` can fill during streaming and grows without bound.
- **Autonomous long route vs a busy Looter.** `main.lua` drives a long route that its caller did not keep paused (Reaper `LONG_PATHING`) without yielding to `LooteerPlugin.is_actively_looting()`. Rosie's 3.3.2 YIELD resolves the tug of war on her side (she leaves the drop 4 → 30 s). Freeroam's 10 s yield cannot simply be copied: Rosie reports busy also during a fight hold without moving, so the route would stall in every fight. Needs a Looter signal "walking to a drop" vs "waiting" (question for the Rosie session).
- A dynamic blocker straight on the route (not in the walk grid): unstuck side-steps, walks on, bumps again; `unstuck_count` resets on every move, so it never reaches EXHAUSTED. Bounded only by trap detection (frontiers cleared, `giving_up` at 60 s). Watch live logs for repeated `unstuck by` lines at one spot.
- Live checks for 2.2.2: fewer "dancing in place" moments after loot pickups and at tight corners in the Pit; `[nav] traversal … not reachable for interact` should be rare.
- The "[nav] world changed … resetting explorer" and "back in … explorer map restored (0 frontiers)" lines are normal.
