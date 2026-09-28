# Activities: ArkhamAsylum (Pit 2.1.3), Reaper (bosses 1.10.4), HordeDev (Hordes 2.2.5), WonderCity (Undercity 2.2.3)

One session owns all four. Notes for each are below.

## ArkhamAsylum (Pit)
- In-pit pickup wait 15 s (`core/task_manager.lua:94,118`). `kill_monster.lua:123` ignores the Looter; the pickup wait is skipped when the boss is within 8 m.
- Town trips from inside the Pit go to Temis; the exit waits for the Looter.
- 2.1.3: past `reset_timeout`, a live Alfred holds the forced exit at most 120 s (`FORCED_ALFRED_HOLD_MAX`, as WonderCity). Test: `test_activities_bounds_v3.lua` L3.

## Reaper (bosses)
- Altar clicks and chest retries are bounded; after a death it returns to the fight; `loot_ready` waits for the Looter.
- 1.10.4: `loot_ready` bound 30 → 75 s (Rosie 3.3.2 fight hold is busy-without-moving up to 45 s, then a pickup); a quiet gap < 3 s no longer re-arms the bound. Tests: `test_activities_fight_hold_332.lua` A1, `test_activities_bounds_v3.lua` L2.

## HordeDev (Infernal Hordes)
- Pylon pause always released; the foreign Alfred pause hold is bounded (`tasks/alfred.lua`, `alfred_pause_expired`).
- 2.2.5: `loot_guard.ready` — a quiet gap < 3 s no longer re-arms the 120 s bound (a flapping Looter held the chest/exit forever). Test: `test_activities_bounds_v3.lua` L1.

## WonderCity (Undercity)
- 3.2.2: a failed exit / beacon walk is set aside for 20/40/60 s and then retried (it was stuck on floor 1). Tests: `test_wondercity_bounds.lua` B1–B7.
- Town trips from Kurast hop to Temis; the caller's own travel returns.

## Rosie 3.3.2 fight hold (checked)
- Rosie reports busy without moving while a drop waits out a fight, max 45 s, then picks up. `test_activities_fight_hold_332.lua` (real Rosie):
  exit_pit (A3), Reaper `loot_ready` (A1, was 30 s → fixed), Hordes `loot_guard.ready` (A4, 120 s), Undercity `can_exit` (A5, `reset_timeout` fallback) all wait for the drop and then go.
- The in-pit pickup yield (15 s) / Undercity loot hold (12 s) still stand during a fight hold; in the joint host the native path to the enemy carries on (A2), so no fix. Live check: does the player stand still next to an elite while a drop waits?

## Open (self-review candidates, not yet confirmed/fixed)
- WonderCity `enter_undercity.lua` ~436-522: ACCEPT re-clicked forever while the vendor screen stays open (town, no `reset_timeout`); bargain loop has no attempt cap.
- HordeDev built-in Cerrigar salvage (compass mode, no Alfred): portal not found → move/interact loop, no retry cap (`town_salvage.lua` ~371-412); blacksmith approach uncapped.
- HordeDev `horde.lua`: council pylon clicked every 3 s forever; an unreachable target wins over the locked-door code; no stuck detection.
- HordeDev `tasks/alfred.lua` ~157: `returning_since = now` every tick while work is live (RETURN_WINDOW never starts); all four plugins hold on live Alfred work with only Rosie's own bounds.
- Reaper `interact_altar.lua` ~304: approach before the first click is unbounded (altar on unwalkable ground).
- WonderCity `walk_kurast.lua`: after MAX_RECOVERIES it never escalates; last-waypoint >30 m idles forever. `enter_undercity` waits forever for a missing spirit brazier.
- HordeDev `open_chests.lua` MOVING_TO_AETHER / `move_to_center`: no attempt cap; nil aether count waits forever.
