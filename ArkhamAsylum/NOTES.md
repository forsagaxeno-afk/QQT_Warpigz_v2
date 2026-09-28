# Activities: ArkhamAsylum (Pit 2.1.3), Reaper (bosses 1.10.4), HordeDev (Hordes 2.2.5), WonderCity (Undercity 2.2.4)

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

## Audit 2026-09-28 (all HIGH/MED in these folders fixed)
- Arkham 2.1.3: shrine walk bounded (30 s no progress / 3 set_target refusals / Z>5 m / used Betrayer's Eye skipped); no new trip with a live boss within 30 m (≤90 s); `teleport_cerrigar` 8 s debounce + loading guard; no `goto`. Test `test_arkham_audit_v3.lua`.
  - Not changed: `alfred.lua` manual hop debounce stays 3 s; `test_secondpass_town.lua:132` (not ours) expects a retry at 3 s. Needs the test owner first.
- Reaper 1.10.4: altar approach bounded (60 s no progress, Alfred yields don't reset it); a live boss fight on enable/reload is joined; the finishing teleport waits for live Alfred work (≤180 s). Test `test_reaper_audit_v3.lua`.
- WonderCity 2.2.4: no new trip during a live boss fight (≤90 s); `walk_kurast` holds during a SilentRaven claim. Test `test_wondercity_audit_v3.lua`.
- HordeDev `town_salvage.lua`: no `goto` (test `test_horde_salvage_v3.lua`). `loot_pending()` also requires `LooteerPlugin.status().ready` (P1).
- Reaper/HordeDev exits wait for a drop Rosie yielded/rests (`evaluate_item(item,false) and evaluate_item(item,true)`), inside the 75/120 s bound. All four loot waits also hold on a busy `Scavenger.is_busy()`. Test `test_activities_loot_waits_v3.lua`.
- Open LOWs (not done): 30 s bound on Pit/Undercity normal exit loot wait; `resume_key` never cleared after a trip that never returns; HordeDev tasks without pcall; log spam; actor-scan perf; custom explorer beacon_aside; `cross_traversal` vs `kill_boss`.

## Rosie 3.3.2 fight hold (checked)
- Rosie reports busy without moving while a drop waits out a fight, max 45 s, then picks up. `test_activities_fight_hold_332.lua` (real Rosie):
  exit_pit (A3), Reaper `loot_ready` (A1, was 30 s → fixed), Hordes `loot_guard.ready` (A4, 120 s), Undercity `can_exit` (A5, `reset_timeout` fallback) all wait for the drop and then go.
- The in-pit pickup yield (15 s) / Undercity loot hold (12 s) still stand during a fight hold; in the joint host the native path to the enemy carries on (A2), so no fix. Live check: does the player stand still next to an elite while a drop waits?

## Open (self-review candidates, not yet confirmed/fixed)
- WonderCity `enter_undercity.lua` ~436-522: ACCEPT re-clicked forever while the vendor screen stays open (town, no `reset_timeout`); bargain loop has no attempt cap.
- HordeDev built-in Cerrigar salvage (compass mode, no Alfred): portal not found → move/interact loop, no retry cap (`town_salvage.lua` ~371-412); blacksmith approach uncapped.
- HordeDev `horde.lua`: council pylon clicked every 3 s forever; an unreachable target wins over the locked-door code; no stuck detection.
- HordeDev `tasks/alfred.lua` ~157: `returning_since = now` every tick while work is live (RETURN_WINDOW never starts); all four plugins hold on live Alfred work with only Rosie's own bounds.
- WonderCity `walk_kurast.lua`: after MAX_RECOVERIES it never escalates; last-waypoint >30 m idles forever. `enter_undercity` waits forever for a missing spirit brazier.
- HordeDev `open_chests.lua` MOVING_TO_AETHER / `move_to_center`: no attempt cap; nil aether count waits forever.
