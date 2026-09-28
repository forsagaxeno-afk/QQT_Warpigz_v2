# Undercity: ~5 teleports before entry (Coordinator investigation, 2026-09-28)

Discord report: "again, about 5 teleports before entering the Undercity". Investigated on d425cf5 (3.3.5) with joint-host repros; an adversarial judge kept these causes.

## walk_kurast stuck watchdog: the 2.1.1 cap MAX_RECOVERIES=2 is reset by its own recovery landing and by the walk back, so re-teleports to the Kurast waypoint have no bound

**Owner:** Activities (WonderCity)  
**Confidence:** confirmed  
**Code:** WonderCity/tasks/walk_kurast.lua:30-39 (STUCK_THRESHOLD_M 1.5, STUCK_WINDOW_S 12, RECOVERY_COOLDOWN_S 15, MAX_RECOVERIES 2); :56-63, and :60 `if task.last_pos ~= nil and not casting then task.recoveries = 0 end`; :67-75 cap; :81-86 stop/clear/reset Batmobile + teleport_to_waypoint(settings.town_waypoint) + reset_progress(); :166 `if watchdog(player_pos) then return end`; :199-204 task.reset also zeroes recoveries and recovery_cap_logged. WonderCity/core/task_manager.lua:155-162 calls task.reset on every tracker key change (tracker.lua:157 key = name:world_id:zone, :169 'outside'). Unchanged since 76ce0d7 (2.1.1), apart from the 2.2.4 SilentRaven hold at :126-137, which only suppresses the watchdog. The test that hides it: audit/tests/test_live_wondercity_teleports.lua:37 (teleport_to_waypoint never moves the player) and :69-76 (a one-tick 30 m jump counts as 'real progress', which is exactly what a landing looks like).

**Mechanism:**
On the recovery tick reset_progress() sets last_pos=nil. During the channel the ticks see casting=true, so last_pos is set to the stall point without a reset. The task manager skips Limbo. On the first loaded tick after the landing the player stands at the waypoint (path[1], about 38 m from a bridge stall), not casting, more than 1.5 m from last_pos, so :60 sets recoveries=0. The walk then goes back to the same spot, stalls, and 12 s later re-teleports with recoveries=1 again. The cap only engages when the stall is within 1.5 m of the landing spot, which was the 2.1.0 case the test models. If a same-zone waypoint teleport also changes world_id, task.reset zeroes it too. recovery_cap_logged is never printed in this loop.

**Teleports:**
Unbounded: 1 re-teleport per (walk time + 12 s + cast/load), about 20-23 s apart, at least 15 s apart (RECOVERY_COOLDOWN_S). It stops only when a walk gets past the stall (the brazier or portal actor appears, so shouldExecute goes false) or the world key changes. Reproduced: joint host (real WonderCity 2.2.4 + real Batmobile 2.2.2, bridge blocked for 4 walks) gave exactly 5 WonderCity casts (1 teleport_kurast + 4 walk_kurast), then entry. A permanent block gave 16 (LuaJIT) or 20 (Lua 5.4) casts in 400 s with 0 cap lines. My own unit re-run on the real d425cf5 file (3 s cast, 2 s Limbo, landing at path[1], stall at x=40): 8 re-teleports in 180 s, 0 cap lines. A stall at the landing gives 2 plus the cap line.

**Evidence:**
Code read at d425cf5 as cited. The judge re-ran the unit check (scratchpad/judge/wk.lua): stall_x=40 gives 8 teleports and 0 cap lines; stall at the landing gives 2 and 1 cap line. Repro logs uc5/run_b.log: 'J1 joint: bridge blocked for 4 walks: ... 5 waypoint casts (WonderCity 5), cap line 0'; 'J2 ... 20 waypoint casts ... cap line 0, [nav] give-ups 20'. The live 2.1.0 wording ('TPs to the entrance 5 times in a row') is the same symptom. The source comment at walk_kurast.lua:26-29 records live stalls on geometry during the Kurast path follow. Live unknown: how far the brazier actor streams in (get_spirit_brazier at core/utils.lua:97-106 has no range filter). The stall has to happen before the brazier is listed.

**Fix:**
walk_kurast.lua: (1) Stop resetting recoveries on displacement. Delete :60, or reset only when the walk really passed the stall: store task.stall_key (the closest path index at the recovery, or the distance to target for the Temis long path) and reset only when the closest index exceeds stall_key+2 (Temis: 10 m closer). Make the cap survive task.reset for the same Kurast visit, e.g. at most 2 recoveries per rolling 300 s, logged once. (2) This also covers the next cause: STUCK_WINDOW_S above Batmobile's 15 s failed-target cooldown. Regression, in test_live_wondercity_teleports.lua: teleport_to_waypoint sets spell 186139 for 3 s; skip 2 s of Limbo; set pos to the landing (10,10); walk 0.7 m/tick to x=40 and stick. Over 180 s assert teleports <= 2 and cap line == 1 (d425cf5: 8 and 0). Add a variant with a stall at the landing and landing jitter of 2 m (<= 2). Joint: J1 from audit/tests/test_zz_repro_uc_walk_kurast.lua (in the repro worktree), assert WonderCity waypoint casts <= 1+2. Prove it by stashing the fix.

## walk_kurast re-teleports on a single Batmobile give-up: 12 s watchdog window < Batmobile failed-target cooldown 15 s, and set_target()==false is ignored

**Owner:** Activities (WonderCity); Batmobile only for reference  
**Confidence:** confirmed  
**Code:** WonderCity/tasks/walk_kurast.lua:31 (12 s), :176-184 (set_target return ignored; it re-requests path[k+2], 4 m from the failed node), :190 move. Batmobile/core/navigator.lua:34-35 (failed_target_cooldown=15, radius=15), :1137-1143 (set_target returns false inside the failed radius during the cooldown), :1815-1822 (a paused navigator with no target returns without moving), :2303-2319 ('[nav] clearing unreachable custom target … cooldown=15s radius=15|50') and :2161-2183 (partial path with no progress for 2.5 s, radius 25).

**Mechanism:**
After 3 A* failures, or a partial path with no progress, Batmobile clears the goal and blacklists a 15-25 m radius for 15 s. walk_kurast has paused Batmobile and keeps asking for path[k+2], which lies inside the radius, so it is rejected. The player stands still, and the watchdog fires at 12 s, about 3 s before Batmobile would accept the goal again. The player is sent back to path[1] and replays the route to the same node. Combined with the first cause, this repeats on every walk.

**Teleports:**
+1 re-teleport per Batmobile give-up, where 0 is needed. Unbounded when combined with the first cause.

**Evidence:**
Code as cited (re-read). Repro J4: '[nav] clearing unreachable custom target 1040,198.5, cooldown=15s radius=15' at 1006.7, obstacle gone at 1007.7, '[wonder_city walk_kurast] stuck 12.0s … re-teleporting' at 1017.6 (10.9 s later), 1 extra cast. In the Lua 5.4 J2 run, each of the 20 re-teleports followed a '[nav] give-up' line.

**Fix:**
walk_kurast.lua: raise STUCK_WINDOW_S to about 20 s (above failed_target_cooldown 15 + margin). When set_target returns false, target the next path node outside the failed radius (k+3..k+6) instead of re-requesting the rejected one, and do not count that time toward the stall. Regression, unit: a BatmobilePlugin double whose set_target returns false for 15 s after a give-up and then true, player still meanwhile. Assert 0 teleports (d425cf5: 1). Joint: J4 (obstacle removed 1 s after the give-up), assert 0 walk_kurast re-teleports.

## Rosie's outbound Town Portal re-casts every 3 s, even while channelling (the 2.1.1 '5 teleports' fix, ported to Arkham in 3.3.3, was never ported to Rosie); it is hit whenever a trip starts in Kurast before the entry

**Owner:** Rosie  
**Confidence:** confirmed  
**Code:** Rosie/rosie/private/town/tasks/teleport.lua:25-26 (debounce_timeout=3); :49-55 (spell 186139 only sets the status and does NOT return); :69-76 (the 0.6 s stand-still gate passes during a still channel); :77 3 s gate; :78 cap outbound_attempts>=8; :79-82 re-cast teleport_to_waypoint(Temis); :33,:59-68 up to 4 refunds when moved; :265-270 outbound leg with a 60 s service bound. Rosie/rosie/private/town/core/lifecycle.lua:330 teleport=true outside Temis, :335 return_required=false from any town (a Kurast trip ends in Temis), :502-503 the tick suspends only on zone '[sno none]' (no Limbo/Loading guard anywhere in Rosie town code). Callers in Kurast: WonderCity/tasks/alfred.lua:299-315 (inside the Undercity only inventory_full triggers, :305, so need_repair and advisory needs from the run are requested in Kurast; standalone any need after the 30 s grace, under WarPigs hard needs) and :221-255; Rosie/rosie/private/town/main.lua:91-131 (automatic trip anywhere). Return: WonderCity/tasks/teleport_kurast.lua:45-49 (+1). The fixed pattern for comparison: teleport_kurast.lua:15-19,24-27 (76ce0d7); ArkhamAsylum teleport_cerrigar (b4c94cd, audit/BOARD.md:193).

**Mechanism:**
Rosie starts the Town Portal (a waypoint cast to Temis) and records debounce_time. The player channels without moving, so the stand-still gate passes. 3 s after the cast start, and without checking 186139, Rosie calls teleport_to_waypoint again. The suite's own sources put the channel at about 5 s and say a second call cancels it (WarPigs/core/orchestrator.lua:357; HordeDev/tasks/town_salvage.lua:154,262-263; docs/UPSTREAM_README.md 'Suite-wide: teleport & interact channel debouncing'). Only the cast after which no re-cast is allowed (attempt 8) can finish. Pre-2.1.1 teleport_kurast did return while casting, and live it still re-cast inside the post-cast gap with a 3 s debounce. Rosie is strictly weaker than that version.

**Teleports:**
Channel (plus gap) under 3 s: 1 Rosie cast. Over 3 s: 8 Rosie casts, and up to 12 if another addon moved the player (refunds), then +1 WonderCity cast Temis→Kurast = 9 before entry. Bounded per trip by the 8-attempt cap plus 4 refunds, the 60 s outbound service time (teleport.lua:266, then teleport_failed and Rosie's 120 s cooldown) and MOVER_WAIT 120 s. It repeats for every trip that starts in Kurast; Rosie's latches allow about one per Kurast visit. With a jittering live channel near 3 s the count falls between 1 and 8.

**Evidence:**
Code re-read as cited; a grep shows no Limbo/Loading guard in Rosie/rosie/private/town. Repro run_a.log: 'R1 Kurast full bag, channel 1.0/2.5 s: 2 casts (Rosie 1, WonderCity 1)'; 'channel 3.2 s / 5.0 s: 9 casts (Rosie 8, WonderCity 1)'; 'R1b … Rosie automatic trip, channel 5 s: 9 casts'. The same under Lua 5.4 and LuaJIT. The live Rosie 1.0.21 comment (teleport.lua:56-58) says 'the live trip spent 8 casts in 24 s', which is exactly the 3 s cadence up to the cap. That was attributed to Navigator; the 1.0.21/1.0.22 fixes did not touch the 3 s debounce or the casting check. Live unknown: the real channel length and whether a re-call restarts it (the suite assumes both).

**Fix:**
Change teleport_with_debounce in the reviewed source that generates teleport.lua (the header says it is generated by tools/build-rosie.mjs). (a) While get_active_spell_id()==186139 and the cast is younger than 15 s, return with status 'Teleporting' and do not count an attempt. (b) debounce_timeout 3 → 8. (c) While the world name contains Limbo/Loading, refresh debounce_time and return. (d) Log each cast: '[Rosie] Town Portal cast N/8 from <zone>'. Keep the refund logic, measured from the cast start. Regression: a teleport.lua unit fixture (test_rosie_foreign_mover.lua style) with the player still, spell 186139 for 5 s, a 1.5 s non-Limbo gap, 2 s Limbo, then Skov_Temis. Assert exactly 1 teleport_to_waypoint (d425cf5: 2 or more). Joint: R1 with a 5 s channel, assert Rosie casts == 1 (d425cf5: 8).

## Kurast↔Temis ping-pong: any Rosie trip started in Kurast before the entry ends in Temis (no return leg), and WonderCity then teleports back

**Owner:** Activities (WonderCity), with Rosie  
**Confidence:** confirmed  
**Code:** Rosie/rosie/private/town/core/lifecycle.lua:330-336 (a request from Kurast: teleport=true, return_required=false); Rosie/rosie/private/town/tasks/teleport.lua:228-230,260 (no return leg); WonderCity/tasks/alfred.lua:299-315 (:305 inside the Undercity only inventory_full; need_repair and advisory needs wait until Kurast) and :194-210; WonderCity/tasks/exit_undercity.lua:42-44 (the exit lands at settings.town_waypoint = Kurast); WonderCity/tasks/teleport_kurast.lua:45-49.

**Mechanism:**
By design Rosie serves Temis only. After a run the exit teleports to Kurast. A need left over from the run (need_repair, a talisman bag, stash extras; or an automatic Rosie trip) is served from Kurast: Rosie hops to Temis, the trip ends there, and teleport_kurast casts back. It multiplies with the previous cause: 1-8 Rosie casts + 1.

**Teleports:**
+2 per trip with a short channel (Rosie 1 + WonderCity 1), 9 with a channel over 3 s. Bounded by Rosie: a completed trip whose need remains latches 'permanent'; failures have a 120 s cooldown and MAX_FAIL_STREAK 3; WonderCity's 30 s advisory grace applies. Normally at most one per Kurast visit.

**Evidence:**
Repro R2: 'CAST teleport_to_waypoint(temis) by Rosie +2.5 … [Rosie] completed +11.9 … CAST teleport_to_waypoint(kurast) by WonderCity +11.9 … inside +38.3'. The existing joint case B3 in audit/tests/test_wondercity_bounds.lua:468-492 shows the same shape.

**Fix:**
When a Rosie need is pending at run end (AlfredTheButlerPlugin.get_status().need_trigger, a hard need, or advisory when standalone), exit_undercity should teleport to Rosie's town (Temis 0x1CE51E) instead of settings.town_waypoint. The trip then starts in town with no Rosie cast, and teleport_kurast brings the player back: 2 teleports instead of 3. Alternatively, request need_repair while still inside the Undercity at the reward phase, using the return leg. Regression: joint, standalone WonderCity + real Rosie, need_repair set during the run. Count waypoint casts between 'undercity_end' and the next entry: expect 2 (d425cf5: 3 with a 1 s channel).

## WarPigs TELEPORTING retry re-fires warplan.teleport_to_activity() every 6 s with no cast check (the Horde path has one); a War Plan landing in the same zone (Temis) is never recognised

**Owner:** Orchestrator (WarPigs)  
**Confidence:** possible  
**Code:** WarPigs/core/orchestrator.lua:27 (TELEPORT_CHECK_INTERVAL 6.0), :1720 (WARPLAN_MAX_RETRIES 5), :3458 cadence, :3469-3476 Limbo guard (unreachable: tick() already returns on Limbo or '[sno none]' at :2611-2618), :3478-3492 (confirm only on a world-name/zone change or arrived_when; world_id is not compared), :3501-3528 retry via pcall(warplan.teleport_to_activity) with no dispatch.teleport_casting() check, :3529-3535 release after 5. Compare hwe: :1876-1882 teleport_casting(), :1983-1987 'never re-fire into our own channel'. Undercity arrived_when at :1166-1184 (brazier actor 'Aubrie_Test_Undercity_Crafter' or an X1_Undercity_ zone). Only with 'Use teleport' ON (WarPigs/gui.lua:25 default false).

**Mechanism:**
(a) The time from the call to the zone change exceeds 6 s: a late start, a channel longer than the ~5 s the code assumes (:357 leaves 1 s of margin), or a hit or mover restarts the channel. The 6 s sample then still reads Skov_Temis, which equals the snapshot, and it re-calls into its own channel. Each retry lands inside the next channel. (b) If the War Plan Undercity teleport lands in Temis itself (the Temis Undercity entrance, WonderCity/gui.lua:67-71) and the brazier is not listed at the landing, the world name and zone never change and arrived_when stays false, so there are 5 completed Temis→Temis re-teleports. After that WonderCity (default town Kurast) teleports once more.

**Teleports:**
Bounded: 1 + WARPLAN_MAX_RETRIES = 6 War Plan calls per hand-off (about 38 s), then 'releasing the gate', plus 1 teleport_kurast cast if the player is not in WonderCity's town. Repro: channel 5.5 s gives 1, 6.2 s gives 3, 7.0 s gives 6. A same-zone Temis landing gives 6 warplan + 1 WonderCity = 7. The existing test test_integration_warpigs_dispatch.lua:446-467 accepts teleports <= 6.

**Evidence:**
Code re-read. Repro run_a.log: 'W1 War Plan channel 6.2 s: … warplan 3, retries logged 2'; '7.0 s: warplan 6, retries logged 5'; 'W2 War Plan lands in Temis (same zone): 7 casts (warplan 6, waypoint 1)'. It needs a channel over 6 s (against the suite's own ~5 s figure) or a same-zone landing; neither is verified live, and where the Undercity War Plan teleport lands is not documented anywhere in the repo.

**Fix:**
In the retry branch at :3501, when dispatch.teleport_casting() is true and now minus the last call is under dispatch.HORDE_CAST_CAP (15 s), set started_at=now and do not retry or count, mirroring hwe_deliver :1983-1987. Record world:get_world_id() in the snapshot and accept a world_id change, or a 186139 cast seen and then ended with a position jump, as a landing. Also treat a Temis landing as delivered when WonderCity's town is Temis. Regression (Orchestrator test file): joint, Use teleport ON, h.warplan_dest='kurast', War Plan channel 7 s; assert warplan calls == 1 (d425cf5: 6). Same-zone case: h.warplan_dest='temis' with a new world_id and no brazier listed; assert 1 call (d425cf5: 6). Tighten test_integration_warpigs_dispatch.lua:446-467.

## walk_kurast keeps driving Batmobile (pause/set_target/move; in Temis mode resume + navigate_long_path) during its own recovery channel, right after its own Batmobile.reset() cleared the failed target

**Owner:** Activities (WonderCity)  
**Confidence:** likely  
**Code:** WonderCity/tasks/walk_kurast.lua:56-63 (a tick while casting returns false, so Execute continues); :167-190 (pause, set_target(path[k+2]), move on every channel tick); :152-161 (Temis: resume + navigate_long_path); :81-84 (the watchdog's BatmobilePlugin.reset makes the next set_target accepted). Batmobile/core/navigator.lua:2040-2060 request_move with no 186139 guard (the only 186139 reference in Batmobile is utils.lua:45, where in_combat excludes it). Movement cancels a channel: WonderCity/tasks/exit_undercity.lua:60-63, docs/UPSTREAM_README.md ('that movement cancelled the exit teleport channel').

**Mechanism:**
Each recovery cast is followed on the same pulses by a fresh goal and move() to Batmobile. If Batmobile issues request_move, the channel is cancelled: the player sees a cast that never teleports and then walks on. That walk counts as movement and resets recoveries (first cause), so the cap can never engage.

**Teleports:**
Turns each recovery into an aborted cast; bounded only by the 15 s cooldown per cast. Repro J3: 160 WonderCity move/set_target calls inside its own 4 s channels (3 casts). J3b (host variant where a move cancels the channel), LuaJIT: 11 of 12 recovery casts aborted in 300 s and the player never entered. Lua 5.4: 0 of 3 (timing-dependent).

**Evidence:**
Code re-read. Repro J3/J3b logs ('stuck 12.0s … re-teleporting' at 1026.3, then 'waypoint channel interrupted by a move from WonderCity' at 1026.4). The cancellation needs the host variant, because the stock joint_host freezes movement during a channel (joint_host.lua:1545).

**Fix:**
In walk_kurast Execute, after watchdog(), return when get_active_spell_id()==186139 (no pause/set_target/move/resume/navigate_long_path during a channel, bounded by a 15 s cast cap), as exit_undercity does. Regression: joint with h.instrument_exports() and a 4 s waypoint channel. Count WonderCity BatmobilePlugin move/set_target/resume/navigate_long_path calls inside [cast.t, cast.t+4]: expect 0 (d425cf5: 160).

## teleport_kurast re-casts every 8 s with no attempt cap and no log when a channel does not deliver; any world-key change wipes its debounce; its loading guard is dead code

**Owner:** Activities (WonderCity)  
**Confidence:** possible  
**Code:** WonderCity/tasks/teleport_kurast.lua:19 (8 s), :24-27 (returns while casting without refreshing debounce_time, so the 8 s run from the cast start), :31, :33-38 (Limbo/Loading guard unreachable: main.lua:40-43 and core/task_manager.lua:145-148 return first), :39-43 cast with no counter and no console.print, :45-49 shouldExecute, :53 pauses only Batmobile, :60 reset sets debounce_time=-math.huge; core/task_manager.lua:155-162 resets on every tracker key change (tracker.lua:157,169).

**Mechanism:**
It is an amplifier, not a trigger. Clean channels give exactly 1 cast (repro B1-B7). If the channel is cut (a hit, LooteerPlugin/Scavenger pickup, Navigator/Worldstone, SilentRaven's claim walk) or refused, it casts again every 8 s forever and silently. If the host reports an intermediate world/zone key before Naha_Kurast, reset() wipes the debounce and it casts again on the next 50 ms pulse.

**Teleports:**
Unbounded: 1 per 8 s while not in town_zone. Unit T1: 15 casts in 120 s with every channel cut after 1.5 s, 0 log lines. T3: reset('outside') 0.5 s after a cast gives an immediate second cast. In clean joint runs: 1.

**Evidence:**
Code re-read; the pre-2.1.1 diff shows the casting return existed before and 2.1.1 only changed 3→8 s plus the (unreachable) Limbo guard. Repro run_a.log: 'teleport_kurast re-casts — REPRODUCED (3 expectations violated)'. Whether live channels get cut here is unverified.

**Fix:**
Count casts per trip and log each one ('[wonder_city teleport_kurast] cast N to <zone> from <zone>'). After 4 undelivered casts back off 60 s with one log line. Keep debounce_time across 'outside' transitions unless the new zone is town_zone (reset(transition) ignores 'outside'). Remove or relocate the dead Limbo guard. Regression: unit T1 (channels cut after 1.5 s; assert <= 4 casts in 120 s and one log per cast); T3 (reset('outside') within 8 s gives no second cast).

## WarPigs TO_TEMIS helltide-lingering fast retry re-fires the Temis waypoint every 6 s with no cap and no cast check (only when a Helltide step precedes the Undercity)

**Owner:** Orchestrator (WarPigs)  
**Confidence:** possible  
**Code:** WarPigs/core/orchestrator.lua:362 (TEMIS_LINGER_RETRY_INTERVAL=6), :1457-1462 helltide_lingering_post_quest, :3266-3273 first cast, :3315-3324 fast retry (no teleport_casting(), no counter), :3325-3331 30 s timeout retry, also uncapped.

**Mechanism:**
With 'Use teleport' ON and the Helltide buff still active after a Helltide War Plan step with HR off, it re-fires every 6 s whatever the state of the channel. A channel longer than 6 s is always re-cast, and hits add further casts.

**Teleports:**
Unbounded while not in Skov_Temis. Repro W3a: 7 s channel, 19 Temis casts in 120 s, never arrived. W3b (1 s channel, 4 cut by hits): 5 Temis casts + 1 warplan before the Undercity.

**Evidence:**
Code re-read; repro W3a/W3b logs '[WarPigs] via-Temis preamble: helltide-lingering fast retry — re-firing waypoint'. Narrow: needs Use teleport ON and Helltide → Undercity order.

**Fix:**
Skip the fast retry while dispatch.teleport_casting() and the cast is under 15 s old, and cap fast retries (e.g. 8, then the 30 s cadence) with a count in the log. Regression: W3a (7 s channel), assert Temis casts <= 2 within 30 s.

## Races with SilentRaven and WarPigs around a Kurast-origin Rosie trip: SilentRaven's claim walk or claim trip cuts WonderCity's Kurast cast; WarPigs' 6 s landing sample misses a Rosie hop and re-fires the War Plan teleport

**Owner:** SilentRaven (Raven+WarRoom); Orchestrator for the 6 s sample  
**Confidence:** possible  
**Code:** SilentRaven/main.lua:127-160 maybe_autofire and SilentRaven/silent_raven/claims.lua:89-116 blocker(): neither checks an active 186139 cast or an enabled WonderCity (no 186139 or WonderCity reference in SilentRaven code). WonderCity/tasks/teleport_kurast.lua:56 holds only when a claim is already running or pending. WarPigs/core/orchestrator.lua:3458,3478-3496 (samples only every 6 s against a Temis snapshot).

**Mechanism:**
(a) After a Kurast-origin trip completes in Temis, WonderCity casts on its next pulse. SilentRaven's auto-claim starts 0.1-0.5 s later and walks, which cuts the channel, so WonderCity casts again after the claim. (b) Standalone, WonderCity enabled in the open world with a reward ready for 300 s or more: SilentRaven requests a Rosie trip, Rosie's cast replaces WonderCity's, the return portal goes back to the open world, and WonderCity casts again. (c) Under WarPigs, a Rosie hop Kurast→Temis finishing before the 6 s sample reads as 'unchanged', and warplan.teleport_to_activity() fires again.

**Teleports:**
(a) +1 WonderCity cast per Temis visit, bounded by SilentRaven's one claim per visit. (b) WonderCity 1 (cancelled) + Rosie 1-8 + portal + WonderCity 1; TRIP_LIMIT 2. (c) +1 warplan per miss, up to 5.

**Evidence:**
Repro R5: '[SilentRaven] claiming the Whisper reward (auto)' at 1012.0, 'waypoint channel interrupted by a move from SilentRaven', WonderCity recast at +19.9. R6: WonderCity cast +0.1, Rosie +0.8. W5: '1034.9 teleport retry 1/5 — world/zone unchanged (… zone=Skov_Temis)' after '[Rosie] completed'. (a) and (b) need the move-cancels-channel host variant.

**Fix:**
SilentRaven: add a blocker/hold 'the player is channelling a teleport' (active spell 186139, bounded to 15 s) in maybe_autofire and claims.blocker. WarPigs: while TELEPORTING, observe the zone every tick and confirm the landing on any zone change seen between samples. Regression: R5 → WonderCity casts from Temis == 1; W5 → warplan calls == 1.

## Refuted

- Destination mismatch (WarPigs delivers or skips at a Temis brazier, WonderCity's default town is Kurast): J9 gave 1 cast in total, the same as baseline. This is the normal single teleport_kurast, not a loop.
- Self-disable re-arm (WonderCity enabled→false in Kurast makes WarPigs re-run via Temis): W4 took the 'same-activity continuation … cancelling teleport, re-enable in place' path with 0 extra casts. Its only side effect is that WarPigs overrides a user pause.
- Standalone WonderCity re-requests a trip at the brazier after the 30 s advisory grace: it loops only with a stubbed sticky need_trigger. With the real Rosie a leftover need latches 'permanent' (r3real: 2 casts, entered), so it is not reachable as shipped.
- WPD-3 gate denials / MAX_GATE_DENIALS / gate_bypass: WarPlans_QST_Undercity has no enable_gate (WarPigs/core/orchestrator.lua:1166-1184), so that path never runs for WonderCity.
- WarPug or SilentRaven's FSM teleporting before the entry: WarPug has no teleport call. SilentRaven's only teleport (fsm.lua:441-442) is its own claim trip to Temis, covered by the SilentRaven race cause.
- A 3.3.x regression of the 2.1.1 fix: walk_kurast and teleport_kurast are unchanged since 76ce0d7, except the 2.2.4 SilentRaven hold, which suppresses the watchdog. Baseline B1-B7 cast teleport_kurast exactly once with 1 s and 5 s channels. The 'again' is the 2.1.1 cap that never worked for a stall away from the landing, plus the same 3 s bug class in Rosie.
- WonderCity/tasks/alfred.lua:34-38 teleport_with_debounce: dead code, never called.
- enter_undercity / brazier / tribute / portal / interact_enticement: no teleport_to_waypoint, teleport_to_activity or reset_all_dungeons calls (the WonderCity grep lists only teleport_kurast:41, walk_kurast:85, exit_undercity:44/47 and the dead alfred:37).
- The walk_kurast cap restarting on every world transition as a separate cause: confirmed at unit level (+2 per Kurast visit), but it is subsumed by the first cause and handled by its fix (a per-visit or rolling cap).

## Log lines to ask for

Ask for the full console log from the ~5 teleports through the Undercity entry, plus two setup answers: is WarPigs 'Use teleport' on or off, and is WonderCity's town Kurast or Temis? Also ask what the player sees: does the character actually land at the Kurast Bazaar waypoint each time, or does the cast bar restart and go to Temis?

1. walk_kurast loop (the first two causes):
- Repeated '[wonder_city walk_kurast] stuck X.Xs near (x,y) — re-teleporting to town waypoint' about 20 s apart, with the same (x,y).
- NO '[wonder_city walk_kurast] still not moving after 2 re-teleports — no further teleports, walking on'.
- About 11 s before each re-teleport, '[nav] clearing unreachable custom target …, cooldown=15s radius=15' or '[nav] partial-path no progress for 2.5s … abandoning unreachable target'. If these are present it is the Batmobile give-up / 12 s window cause.

2. Rosie outbound re-cast (plus the Kurast ping-pong):
- Rosie logs no line per cast. Look for a trip starting in Kurast before the entry: '[Rosie] Town Portal waits…' or '[Rosie] Town Portal: 4 interrupted casts were not counted', then '[Rosie] completed' or '[Rosie] failed: teleport_failed'.
- Then '[WonderCity:alfred] Alfred completion callback result=…' and a single Kurast teleport.
- On screen: casts toward Temis with Rosie's overlay status 'Teleporting' repeating.

3. WarPigs War Plan retry:
- '[WarPigs] warplan.teleport_to_activity() called — world=… zone=…'.
- Then '[WarPigs] teleport retry N/5 — world/zone unchanged (world=… zone=…)'. zone=Skov_Temis means a channel over 6 s or a same-zone landing.
- Possibly '[WarPigs] teleport: world/zone unchanged after 5 retries … releasing the gate'.

4. TO_TEMIS: '[WarPigs] via-Temis preamble: helltide-lingering fast retry — re-firing waypoint' and '[WarPigs] via-Temis preamble: TO_TEMIS timeout — retrying waypoint'.

5. teleport_kurast: it prints nothing. Casts with none of the lines above between them, and an overlay reading 'teleport_kurast: waiting X.XXs / teleporting', point to it.

6. SilentRaven: '[SilentRaven] claiming the Whisper reward (auto)', or 'claim trip requested', right after a WonderCity cast in Temis.

7. Exit re-casts: count 'teleport out' lines (WonderCity exit_undercity, 5 s debounce, no cast check). This rules out exit re-casts being counted as 'before entering'.

Live facts still needed:
- The real waypoint and War Plan channel lengths.
- Whether a repeated call restarts the channel.
- How far from the Kurast waypoint the 'Aubrie_Test_Undercity_Crafter' actor starts to appear in the actor list.
