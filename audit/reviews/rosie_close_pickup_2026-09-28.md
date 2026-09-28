# Rosie close-range pickup: chest loot ignored until the player steps 2-3 m away (Coordinator investigation, 2026-09-28)

Player report (Discord): loot from a chest is not picked up, no log; stepping 2-3 m away makes Rosie loot it; "older versions worked". Investigated on 8bb81bd (Rosie 1.0.23, Batmobile 2.2.3) with repros vs v3.3.1; an adversarial judge kept these causes.

## FIGHT hold (3.3.2 regression): chest drops farther than 3 m wait silently for up to 45 s whenever any listed non-dead actor is within 10 m, including 1-HP, untargetable, other-floor or passive ones

**Owner:** Rosie (claude/qqt-rosie)  
**Confidence:** confirmed  
**Code:** Rosie/rosie/private/pickup/src/pickup.lua:339 (FIGHT feet=REACH+1=3, margin=4, calm=1, max=45), :356-379 fight_hold (:368 Utils.enemy_near; :374-377 is the only line, printed at the 45 s cap), :386-390 fight_deferred, :449; Rosie/rosie/private/pickup/utils/utils.lua:133-145 enemy_near (checks only is_dead~=true: no HP>1, is_untargetable or dz filter, unlike WarPigs/core/orchestrator.lua:896-903, HelltideRevamped/core/hr_watch.lua:145, ArkhamAsylum/tasks/kill_monster.lua:7-9,61-67); Rosie/rosie/private/pickup/src/item_manager.lua:418-419 (deferred -> not wanted), :430 (deferred drops are never reported), :357-385 (diagnose() lists held drops as 'Wanted'); Rosie/rosie/private/pickup/main.lua:87-88 (fight_wait_busy sets looting=true while nothing moves), :133-134 (status says 'Picking up accepted items.', so the 'a drop waits for the fight' detail is unreachable)

**Mechanism:**
A chest spills drops about 0-5 m around the player. For each wanted drop farther than 3 m (2D), choose() asks fight_deferred. If target_selector.get_near_target_list lists any actor within 10 m whose is_dead is not true, the hold turns on and the drop is marked not wanted without any report. That includes an actor the rotation never fights: a passive monster, a 1-HP apparition or totem, an untargetable actor, or an enemy on another floor (z is ignored). The hold ends only when nothing is listed within 14 m for 1 s, or at the 45 s cap, which prints the first and only line. Meanwhile drops within 3 m are still taken, so part of the pile stays behind. is_actively_looting()=true and the status reads 'Picking up accepted items.' while nothing moves. It fits every part of the report: silent, 'older versions worked' (<=3.3.1), a 2-3 m step toward the pile brings the held drops inside 3 m and Rosie walks to them at once, 'works sometimes' (it depends on an actor happening to be within 10 m), and 'alt-tabbed back in and it worked' (the 45 s cap passed).

**Evidence:**
CONFIRMED offline on an exported copy of 8bb81bd (joint host, real Rosie; the repo was not touched). Seed test K1 (1-HP actor 8 m away; drops at 0.8/1.6/3.6/4.4 m) and K2 (the same actor untargetable, HP 100): 2 of 4 drops taken in 6 s, 0 console lines, on both LuaJIT and Lua 5.4. The same file on v3.3.1's Rosie: 4 of 4, PASS. Repro gates: G3a/G3b gave 4 of 6 standing, busy=true, 'Picking up accepted items.', 0 lines. In G3d the far drops were taken at 47-48 s, right after 'A fight kept pickup waiting 45s'. In G3e a 2.5 m step toward them gave 4 of 4 at once. G3c (actor at 13 m) gave 6 of 6. pickup.lua is byte-identical in v3.3.4, v3.3.5 and v3.3.6 (Rosie 1.0.23). The live precondition, some listed actor within 10 m of the chest, is not yet verified for this player.

**Fix:**
Rosie/ only; mark the changes '-- QQT_Warpigz_v3 1.0.24'. Minimal fix: (1) In Utils.enemy_near, count an actor only if get_current_health()>1, is_untargetable()~=true and |dz|<=5, mirroring orchestrator.lua:896-903 and kill_monster.lua:61-67. (2) Make the hold visible. Print one '[Rosie pickup] N drop(s) wait for the fight (<skin> at X m)' line per hold episode. In status(), when looting is true only because of fight_wait_busy, say 'Waiting for the fight to end (N drops)'. In diagnose(), print 'held by the fight hold'. (3) To cover a passive but valid monster: start the hold only when engaged, meaning a valid enemy within 6 m or a spell cast by the player in the last 3 s. Once on, the existing 14 m / 1 s exit and the 45 s cap still apply. The elites at 5-6 m in the existing tests keep holding.

**Test:**
Seed file: /tmp/claude-0/-home-user-QQT-Warpigz-v2/f0661e64-4c16-5466-a632-f06a0350959a/scratchpad/judge_close/test_rosie_chest_close_1024.lua (proposed as audit/tests/test_rosie_chest_close_1024.lua; run with SUITE_ROOT and ONLY=K1 to pick a case). K1, K2 and K3 all fail on 8bb81bd under both runtimes. K3 checks that a real elite at 6 m still holds a drop 7 m away, with 0 Rosie moves, exactly one fight line, and a status that does not say 'Picking up'. These must stay green: test_rosie_pickup_1022 F1-F3, test_rosie_back_forth_332 B1/B2/B6, test_rosie_loot_waiting_1022, test_activities_fight_hold_332 and test_rosie_scavenger_mimic.

## Standing dead band within 2 m: Rosie only interacts from where the player stands and never steps closer, so a drop the game will not take at 1.2-2.0 m is spammed until a round fails

**Owner:** Rosie (claude/qqt-rosie)  
**Confidence:** likely  
**Code:** Rosie/rosie/private/pickup/src/pickup.lua:19 (REACH=2), :20-22 (INTERACT_GAP 0.15, MOVE_GAP 0.35, ROUND_INTERACTS 30), :500-503 (walk; the MOVE_GAP early return at :501 lets a walked approach overshoot onto the drop), :514-529 (in reach: M.release_movement at :516, interact_object at :528, never a move); Rosie/rosie/private/pickup/utils/utils.lua:13-19 (2D dist_to_ignore_z); Rosie/rosie/movement.lua:117 (1.5 m 3D arrival, which would swallow a short step-in); Rosie/rosie/private/pickup/main.lua:67-70 (host Auto Loot forced off every pulse since 1.0.7); the game fact is hinted at in WonderCity/tasks/enter_undercity.lua:27-34

**Mechanism:**
A chest spill lands 0.5-2 m from a player who is standing still, so no approach walk happens. Within 2 m, step() calls interact_object every 0.15 s from the player's spot and releases its own move. If the game takes a ground item only from closer than that distance (unmeasured live), nothing happens for 30 interactions (about 4.5-6 s). Then comes 'Retrying X: round 1/3 failed (interactions did not pick it up, distance 1.x)', and after 3 rounds the drop is exhausted. Stepping more than 2 m away makes Rosie walk to the drop. The native move keeps running for up to 0.35 s after the last request, which carries the player to about 0-0.5 m of the drop, so the first interaction takes it. This matches 'walk 2-3 m away, then Rosie goes and loots it'. Not a 3.3.x regression: the interact_object, REACH and request_move lines are unchanged from v3.0.0 to 8bb81bd, and pre-1.0.7 used the same 2 m switch. 'Older versions worked' fits only if the older setup relied on the host's Auto Loot, or on LooteerV3, which Rosie replaces and which also forces Auto Loot off.

**Evidence:**
The code facts were re-read and hold. Game-fact dependent emulation (repro chest file on 8bb81bd): with a take radius of 1.2 or 1.5 m, 2 of 5 drops were taken standing with 0 Rosie moves, and 4-5 of 5 after a 3 m step. With 1.8 m, 5 of 5. With 1.2 m where interact_object walks the player like a click (M5), 5 of 5, so there is no dead band in that model. Batch of 20 chests with gear, take 1.2 m: 65% standing, 93% after the step. Seed case K4 (helm at 1.7 m, refused beyond 1.2 m) fails on 8bb81bd under both runtimes: never taken, 0 moves. Against it for this report: every standing batch run that left drops also logged a 'Retrying … interactions did not pick it up' line within about 6 s, while the player says nothing was logged. It fits only if he stepped away before then.

**Fix:**
Add a bounded step-in. After 4 CLEAR in-reach interactions with no take, and while the player has moved less than 0.2 m, send one move onto the drop with z snapped by utility.set_height_of_valid_position. It needs a small arrival radius, about 0.3 m, through a new option in rosie.movement, because movement.lua:117's 1.5 m 3D arrival would drop a 1.7 -> 0.3 m step. Log once per drop '[Rosie pickup] X at 1.7 m: interactions not taking it; stepping closer'. Keep ROUND_INTERACTS, the rounds and the 20 s episode budget (C6).

**Test:**
Seed K4: fails on 8bb81bd, passes when the drop is taken within 4 s with at least 1 Rosie move and no 'Retrying' line. Add a control: a drop at 0.8 m is still taken with 0 moves. test_rosie_pickup_rounds, test_rosie_ghost_pickup, test_rosie_yield_reach_1022 and test_rosie_back_forth_332 B7 must stay green.

## No-bag drops (materials, crafting, quest, cinders) are falsely logged 'Took' after 3.5 s of failed standing interactions and then ignored; the one retry needs going more than 4 m away and back within 2 m, and a failed retry is silent

**Owner:** Rosie (claude/qqt-rosie)  
**Confidence:** possible  
**Code:** Rosie/rosie/private/pickup/src/pickup.lua:84-85 (nonbag_interacts=3, nonbag_clear=3.5, away=REACH+2), :470-473 (settle 'taken' with retry=true), :161-171 (retry: :167 marks away beyond 4 m, :168 unsettles at d<=2), :256-274 (settle; :261 before=G.retried, :270 'if before==why then return end' = silent), :286-303 (Q9 carry-over to a re-listed actor, silent); introduced in v3.1.0 (Rosie 1.0.14)

**Mechanism:**
Any cause that makes standing interactions fail for 3.5 s of CLEAR time, such as the dead band above, turns a still-listed no-bag drop into '[Rosie pickup] Took X (it goes to no bag; the host still lists it on the ground, ignoring it)'. That reads like a pickup, and the drop is then ignored for up to 180 s after it was last listed. A 2-3 m step does nothing. Only going more than 4 m away and coming back within 2 m unsettles it, once. The retry interacts from wherever the player stops, and if it fails it re-settles with no line.

**Evidence:**
Code re-read; the version boundary was checked: the 'goes to no bag' line is absent in v3.0.0 and present from v3.1.0. Seed K5 (Pragmatic Tuning Prism at 1.7 m, refused beyond 1.2 m) fails on 8bb81bd with a false 'Took' line and the prism not picked. In repro M1x (take 1.2 m, mixed kinds), 3 of 5 were left after stepping away and back, with 'Took Veiled Crystal' and 'Took Conduit Globe' while both stayed on the ground. It depends on the dead band's game fact, so it is not an independent cause of this report.

**Fix:**
At pickup.lua:470, settle a no-bag drop as 'taken' only after interactions from 1.0 m or less (after the step-in above), or when item:is_interactable()==false. Otherwise let the round end as 'interactions did not pick it up'. Reword a settle without a receipt to 'Leaving X: still listed after N interactions (no bag to confirm it was taken)'. When the retried settle repeats the same verdict (:270), log it instead of returning silently.

**Test:**
Seed K5: fails on 8bb81bd; passes with no 'Took' line and the prism taken within 6 s. Add a case that forces the retry to fail and asserts one line for it. test_rosie_ghost_pickup Q1-1..Q1-11 (a real ghost taken at the feet still settles once with one line) and test_rosie_pickup_fight_q1 must stay green.

## Walk-only band of 2.0-3.0 m: Rosie never interacts beyond 2 m even when the player cannot get closer (a drop on or against a chest, prop or ledge); this matches the owner's own 'no progress, distance 2.1/2.7/2.8 [interactable=true]' lines

**Owner:** Rosie (claude/qqt-rosie)  
**Confidence:** likely  
**Code:** Rosie/rosie/private/pickup/src/pickup.lua:486-499 (after a 6 s stall: fail_round 'stall' for gear, settle 'unreachable' for everything else), :502-513 (beyond REACH it only calls request_move to the raw item position); Rosie/rosie/private/pickup/utils/utils.lua:116-130 (walkable_near is only used as proof, never as a walk goal); contrast Rosie/rosie/private/town/tasks/stash.lua:378-384 (the stash is interacted with within 3 m after 1.5 s without reaching 2 m) and HelltideRevamped/NOTES.md:17 (a 2-6 m chest band)

**Mechanism:**
The game move stops at the edge of the obstacle, 2.1-2.8 m from the drop. Rosie keeps sending request_move and never calls interact_object at d>2. After 6 s: 'Retrying X: round n/3 failed (no progress toward it, distance 2.x)' for gear, or 'Leaving X: cannot reach it (no progress/not walkable, distance 2.x) [interactable=true]' for other drops, which is permanent for that drop. Not a regression, and it is logged, so it explains the owner's lines but not the player's 'nothing in the log'.

**Evidence:**
Repro band P1 on 8bb81bd, with drops on a 4x4 m prop and a game that takes drops from up to 3.0 m: 2 of 4 taken, 30 Rosie moves, 0 interactions with the other two, then 'Leaving Power Globe: cannot reach it (not walkable, distance 2.6)' and 'Leaving Conduit Globe: cannot reach it (no progress …)'. Stepping away and back did not help. Seed K6 fails on 8bb81bd under both runtimes. Whether the live game takes a drop from 2.1-2.8 m is a live check.

**Fix:**
Use the stash rule. When REACH < d <= FIGHT.feet (3 m) and the player has not got within REACH for 1.5 s (e.best_at), call interact_object from where the player stands every INTERACT_GAP. These calls count in e.interacts and ROUND_INTERACTS, so the round bound still applies (C6). Before a non-gear drop is settled 'unreachable', give it this band attempt. Optionally walk to the walkable ring point from walkable_near that is nearest the player instead of the raw item position. Log once: 'X: cannot get closer than 2.4 m; interacting from here'.

**Test:**
Seed K6 (walls {{0.5,4.5,-2,2}}, helm at (2.6,0), refused beyond 3.0 m): fails on 8bb81bd; passes when the helm is taken within 10 s with no 'no progress' line. test_rosie_pickup_fight_q1 F7/F8 and test_rosie_pickup_rounds (walled drops beyond 3 m) must stay unchanged.

## Silent setting gate: Behavior = Orbwalk runs pickup only while the orbwalker is in Clear mode, and logs nothing

**Owner:** Rosie (claude/qqt-rosie)  
**Confidence:** possible  
**Code:** Rosie/rosie/private/pickup/main.lua:66 (release and return every pulse); Rosie/rosie/private/pickup/src/settings.lua:328-331 (should_execute); Rosie/rosie/private/pickup/gui.lua:19 (behavior_combo, whose widget hash uses the Looter label, so an old LooteerV3 value carries over)

**Mechanism:**
With Behavior=Orbwalk, every drop, even one at the feet, is ignored unless orbwalker.get_orb_mode()==clear. Only the menu status says 'Waiting for orbwalker Clear mode'. If the player moves by holding the Clear key, pickup runs during that walk, which looks like 'I moved 2-3 m, then Rosie looted'. The player himself wondered whether he had 'an incorrect setting'.

**Evidence:**
Repro G1 on 8bb81bd: 0 of 6 picked, 0 lines, status waiting_for_clear. Seed K8 fails on 8bb81bd (no line). The behaviour is the same in every version, so it does not explain 'older versions worked'.

**Fix:**
Log once per zone, when a wanted drop is in range and orb mode is not clear: '[Rosie pickup] waiting for orbwalker Clear mode (Behavior = Orbwalk)'.

**Test:**
Seed K8 (behavior_combo:set(1), h.orb.mode=0, drop at 1 m): exactly one line. With h.orb.mode set to clear, the drop is taken.

## Silent addon gate: a busy third-party Scavenger (Rosie 1.0.21 / 3.3.3), or Worldstone pausing through Rosie's Scavenger stand-in (1.0.23), stops pickup even at the feet with no log and a misleading status

**Owner:** Rosie (claude/qqt-rosie)  
**Confidence:** possible  
**Code:** Rosie/rosie/private/pickup/main.lua:14-16 (activity_owns_loot true while foreign.scavenger_busy()), :74 (Pickup.reset(false); return; no line), :126 (status 'Tristram controls pickup and movement'); Rosie/rosie/private/foreign.lua:27-37; Rosie/rosie/private/scavenger_mimic.lua:170-180 (pause -> Looter acquire_pause, nothing logged at the start), main.lua:71

**Mechanism:**
If the Scavenger .pak is installed and reports is_busy() (possibly on the same close drop it cannot take either), Rosie resets pickup every pulse and says nothing. With Worldstone and no Scavenger, Worldstone's Scavenger.pause('Worldstone') pauses Rosie's pickup for up to 60 s with no start line.

**Evidence:**
Repro G2: 0 of 6 picked, 0 lines, status 'Tristram controls pickup…'; v3.3.2 took 6 of 6. G4b: 0 of 6, status 'Paused by Worldstone.'. Seed K7 fails on 8bb81bd. It applies only if the player runs these addons, which is unknown.

**Fix:**
Log the hand-over once per episode: '[Rosie pickup] Scavenger (Navigator) is busy; leaving drops to it'. Log the start of a pause taken through Scavenger. Give the status its own reason naming Scavenger or Worldstone. Optionally, after about 5 s of Scavenger busy, still interact with a wanted drop within REACH (no move, so no tug of war).

**Test:**
Seed K7 (h.G.Scavenger.is_busy=true, drop at 1 m): one line naming Scavenger, and status.detail without 'Tristram'. Add a Worldstone case to test_rosie_scavenger_mimic: after pause('Worldstone'), one start line. test_suite_rosie_scavenger_skip and test_rosie_scavenger_mimic stay green.

## Batmobile involved?

No. Rosie's pickup never calls BatmobilePlugin (set_target/move), explorerlite or force_move. It walks only through Rosie/rosie/movement.lua to the native pathfinder.request_move (pickup.lua:12, movement.lua:142-150), and interacts with interact_object. Batmobile 2.2.3's only change is freeroam skipping Rosie's _rosie Scavenger table (Batmobile/main.lua:49-51). In every offline run Batmobile made 0 moves and 0 interactions during pickup. The only indirect link: during a FIGHT hold, fight_wait_busy reports the Looter busy, so a Batmobile freeroam drive yields for up to 10 s (Batmobile/main.lua:37-65). That does not apply to manual chest opening. No Batmobile change is needed; every fix belongs to the Rosie session.

## Refuted

- Batmobile as the cause (CALLER_GOAL_REACH=3, 1 u arrival, the 2.2.3 change): Rosie's pickup never drives Batmobile. It moves only through rosie.movement to the native pathfinder.request_move (pickup.lua:12, movement.lua:150). The only change in Batmobile 2.2.3 is freeroam's Scavenger check (Batmobile/main.lua:49-51). Batmobile made 0 moves and 0 interactions in every repro run.
- Default Distance slider of 2 (gui.lua:22, settings.lua:15) as this player's cause: he saw Rosie walk to the loot after he stepped away. With Distance <= 2, a drop beyond 2 m is not wanted (item_manager.lua:87) and one within 2 m is never walked to. The setting is still worth asking about.
- Stale unreachable move destination / host skipping request_move while moving (movement.lua:150-168): the in-reach branch sends no move at all (pickup.lua:514-529), and emulation G5 gave 6 of 6.
- YIELD to another mover (pickup.lua:189-191, 395-427): it holds only walks to drops beyond 2 m, in-reach drops are still interacted with (1.0.23), and the first 3 yields are logged. It is not a silent close-range failure.
- Scavenger stand-in walk_hold (pickup.lua:391-393): only with Worldstone loaded, 5 s, and drops within 2 m are still taken.
- Episode budget, round and after-fight-round logic: every exit prints a line, so none of it is silent.
- movement.lua:117's 1.5 m 3D arrival as the cause: pickup walks only when the 2D distance exceeds 2 m, so it never trips. It does matter for the step-in fix.
- Obols (item_manager.lua:92): excluded by design; the game collects them.
- The close-range interact/walk logic as a 3.3.x regression: the interact_object, REACH=2 and request_move lines are identical from v3.0.0 to 8bb81bd. The only new layers are FIGHT (3.3.2), the Scavenger yield (3.3.3) and the mimic (3.3.4).
- Alt-tab as a Rosie mechanism: Rosie never reads window focus. 'Alt-tabbed back and it worked' is explained by the 45 s fight cap elapsing, or else by host/game behaviour (a live check).

## Ask the player

Please send (Cwolly):
1) The full console log from game start through at least one chest where loot stayed on the ground, without cutting it. Say roughly when you opened the chest and when you stepped away. Lines that decide it:
   - '[Rosie pickup] Retrying …: round 1/3 failed (interactions did not pick it up, distance 1.x)' or '[Rosie pickup] Took … (it goes to no bag …)' for an item that is still on the ground: Rosie is standing too far to pick it up.
   - No Rosie line at all, then '[Rosie pickup] A fight kept pickup waiting 45s' after a while: the fight hold.
   - '… no progress toward it, distance 2.x' or 'Leaving …: cannot reach it': an item Rosie cannot walk up to.
2) While the loot is lying there, a screenshot of Rosie's pickup menu status line, and the output of the pickup 'Diagnose' button:
   - 'Picking up accepted items.' while nothing moves: the fight hold.
   - 'Waiting for orbwalker Clear mode': your Behavior setting.
   - 'Tristram controls pickup…': a Scavenger addon.
   - 'Paused by Worldstone.': Worldstone.
3) Your Rosie pickup settings: Behavior (Always or Orbwalk), Distance, Loot priority, and which categories are on (crafting materials, quest items, cinders).
4) Which other addons you run: Navigator, Worldstone, Scavenger, a rotation (which one), and whether you use the orbwalker's Clear key to move.
5) Were you playing manually or with a bot (HelltideRevamped, WarPigs), and what kind of chest was it (Helltide, Silent, dungeon)? Was any monster, totem or ghost-like apparition nearby, even one you were not fighting, on a ledge or on another floor?
6) Were the items that stayed behind right next to you (within about 2 m), or a bit farther (3-5 m)? When you stepped 2-3 m, was it toward the loot or away from it?
7) Which 'older version' worked for you: 3.3.1 or earlier, or the old LooteerV3 / Alfred setup?
8) Was the game window in the background (alt-tabbed) while the loot was not being picked up?
