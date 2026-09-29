# Activities: ArkhamAsylum (Pit 2.1.5), Reaper (bosses 1.10.7), HordeDev (Hordes 2.2.8), WonderCity (Undercity 2.2.7)

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
- 2.2.6 (Undercity teleport storm, audit/reviews/undercity_teleports_2026-09-28.md + review_round_1630 + rereview_1820): walk_kurast follows a monotonic walk index (no goal flip on octile ties) with a progress watchdog (index, or 2 m closer to the destination; 20 s); drives only its goal (no refused-node skip; refused time is stall credit ≤30 s); ≤2 re-teleports per 300 s, then the walk hands off to Batmobile's long path (retries back off to 15 s after 3 failures); the cap expires 300 s after it engaged; the stall key keeps the furthest point; a walk ends (fresh budget) on a real arrival (valid position at the destination, brazier/portal ≤25 m), a 'run', an arrival from another zone (teleport_kurast bumps utils.kurast_arrivals) or release_control (on_release); no Batmobile during a 186139 channel or 1.5 s after a recovery. teleport_kurast logs each cast, backs off 60 s after 4 undelivered, debounce from the channel end, on_release clears the count. exit_undercity goes to Temis when a Rosie need is pending (honours the 30 s post-cycle grace). Tests: test_live_wondercity_teleports, test_wondercity_teleport_kurast_v3, test_wondercity_exit_rosie_v3, test_wondercity_walk_review_v3 (F1, E1, J1-J6 joint with real Batmobile, C1-C8). Live: count casts before entry; a stall near the bridge should show at most 2 '(n/2)' re-teleports then the long-path line; under Lua 5.4 the offline A* needs the long path to get round the investigation's partial wall (J6).
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

## Scenario sweep 2026-09-28 (audit/reviews/sweep_2026-09-28.md)
- HordeDev 2.2.8: D1 victory lap dwell counter reset (`test_horde_victory_lap.lua`); D2 zero-aether chest not retried (`test_horde_audit.lua`); D3 movement spell log is one summary line / 30 s (`test_hordedev_movement_spell_spam.lua`).
- Reaper 1.10.7: P1 chest walk waits for the Looter (75 s); P2 reload mid-fight on the last key joins the fight (one committed run); P3 no task in Limbo/Loading/`[sno none]`; C-boss `status().boss_fight` (fresh evidence ≤5 s). Tests `test_reaper_chest_walk_loot`, `_reload_last_key`, `_limbo_guard`, `_boss_fight_status`.
- Arkham 2.1.5: A1 glyph UI lost → re-interact (≤3 re-arms, `test_arkham_glyph_reopen`); A2 portal transition window 5 → 15 s, back-portal memory per floor in `ArkhamAsylum/back_portals.txt` (runtime file, 1800 s TTL, no global), chain guard after going back up, first-load heuristic: a portal 2.5–7.5 m away on the first pit floor seen since load is the back portal (`test_arkham_back_portal_slow_load`, `_reload`); A3 exit sweeps the boss pile ≤20 s for drops Rosie wants but not from her radius (`test_arkham_boss_pile_v3`); A4 hold log clock restarts after a gap/cancel (`test_arkham_hold_log`); C-boss `status().boss_fight` (live boss ≤30 m for ≤90 s, glyph pending ≤120 s; `test_arkham_boss_fight_status`).
  - Risk: a load on floor 1 standing 2.5–7.5 m from its descend portal blacklists it until the 600 s reset. Live check.

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
