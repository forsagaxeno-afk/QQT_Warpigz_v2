# Rosie vs Worldstone/Navigator: drops abandoned, 2-3 m stalls, first stash deposit lost (Coordinator investigation, 2026-09-28)

Owner live logs (3.3.5, Rosie 1.0.23 acting as Scavenger for Worldstone). Investigated on 8bb81bd with repros; an adversarial judge kept these causes.

## Rosie gives up a drop while her own 'Rosie Looting' hold is on, before she has resent a single move

**Owner:** Rosie (claude/qqt-rosie): Rosie/rosie/private/pickup/src/pickup.lua and Rosie/rosie/movement.lua. Auditor (claude/qqt-audit): the one-line hook in Rosie/rosie/private/scavenger_mimic.lua, which it owns per Rosie/NOTES.md:8  
**Confidence:** confirmed  
**Code:** Rosie/rosie/private/pickup/src/pickup.lua: :21 (MOVE_GAP 0.35), :340 (YIELD confirm 0.3, rest 4), :395-411 (foreign_move: working gate :396, far :399, sent :406, confirm and moved :410), :412-427 (stand_down), :450 (foreign check) runs before :501-513 (resend), :189-191 and :207-221 (a yielded drop is blocked and never woken). Rosie/rosie/movement.lua: :150-169 (request_move is skipped while the player moves; clear plus resend at most twice, and the resend happens only on the next call). Rosie/rosie/private/pickup/main.lua:77-80. Rosie/rosie/private/scavenger_mimic.lua: :97 (DEBOUNCE 1 s), :113-118 (note_work), :133-137 (is_busy / condition), :234 (a yielded drop leaves get_wanted_items)

**Mechanism:**
1. Step 1 on a new drop cannot yield, because e.working is nil (pickup.lua:396). It sends the move and returns true, so note_work makes Scavenger.is_busy() and 'Rosie Looting' true on that same pulse (main.lua:80, scavenger_mimic.lua:113-117, 133-137).
2. From the next pulse, foreign_move checks the player's move destination. It counts as foreign when it is more than 2.5 m from the player and from the drop, and more than 1.5 m from Rosie's last sent point. After 0.3 s of a foreign destination with at least 0.5 m moved, Rosie stands down (pickup.lua:399-410). It never asks whether Rosie is holding Navigator right now.
3. foreign_move runs every pulse (:450), but the resend waits for e.next = now + 0.35 (:501-503). The 0.3 s yield therefore fires before Rosie's second request. The first request is skipped by the host while the player is walking (movement.lua:150-168). Its clear-and-resend (:154-161) only sets state.next=0, and pickup does not call again before the yield. So an in-flight or late-read Navigator move always wins.
4. stand_down gives a 4 s rest. The drop is then blocked for walks and not woken (:189-191, :218), and it drops out of get_wanted_items (scavenger_mimic.lua:234).
5. Once every drop has yielded, note_work stops and is_busy goes false 1 s later (:97). That releases both 'Rosie Looting' and a live-read 'Worldstone Looting', and Worldstone reaches the portal inside the rest. Live: 5948.33 + 4 = 5952.33, portal at 5952.47.

**Evidence:**
Code: see code_path. The shipped tests cannot show this:
- the fake Navigator pauses instantly (audit/tests/test_rosie_scavenger_mimic.lua:68-95);
- the joint host accepts every request_move, and its clear_stored_path cancels the move (audit/tests/joint_host.lua:946-963).

I re-ran the repro myself on a git-archive export of 8bb81bd, with the repro file copied in: scratchpad/judge_nav/audit/tests/test_zz_repro_rosie_nav_yield.lua (from .claude/worktrees/wf_15eda586-f3f-4). It passes under Lua 5.4 and LuaJIT. Every yield line shows busy=true. Results:
- 'n=1 pre-walk inflight look=false': picked 0/1, yield at 13.90 with busy=true nav_paused=true;
- 'n=2 add lag=1.0': 0/2;
- 'n=4 add inflight look=false': 0/4 with 4 yields;
- ideal Navigator: 4/4, 0 yields.

Live: 2 to 4 yields about 0.42 s apart, right before 'Prefab_Portal_Dungeon_Generic ... interacted'. Rosie/NOTES.md:36 lists 'no Another move took the player off beside Worldstone's route' as the 1.0.23 live check that failed.

**Fix:**
Rosie 1.0.24. The Rosie-side flaw exists under every Navigator model. This fix alone is enough only if Navigator honours the hold with an in-flight or late move.
(a) scavenger_mimic.lua after :137: `Pickup.nav_held=function() return M.is_busy() end`. It is false out of effect, so without Worldstone the behaviour stays 1.0.21.
(b) pickup.lua foreign_move after :406: while pcall(M.nav_held) is true and not e.held_spent, keep e.held_since. While now-e.held_since < YIELD.held (2.5 s): `e.foreign=nil; e.reassert=true; return false`. Reset held_since after a gap of more than 1 s.
(c) M.step before :501: `if e.reassert then e.reassert=nil; e.next=0 end`, so the resend is not held back by MOVE_GAP. After an accepted request, call G.movement.force_for('pickup',0.5). movement.lua then sends `pcall(native.force_move_raw, vector(route point))` when request_move returned false and get_move_destination is more than 1.5 m from the route point. This happens at most once per pace (0.2 s), only inside that window. force_move_raw is a live API: ArkhamAsylum/tasks/portal.lua:482, HelltideRevamped/core/explorerlite.lua:482.
(d) stand_down sets e.held_spent when held_since is set: one grace per drop.
(e) Mark it `-- QQT_Warpigz_v3 1.0.24`.
Bounds: at most 2.5 s per drop. The mimic's CAP 20 s and CEILING 60 s still apply, and walk_hold follows (pickup.lua:386-394).

**Test:**
New file audit/tests/test_rosie_nav_hold_1024.lua (Rosie session), built on joint_host with the repro's Navigator doubles:
- request_move_redundant='any';
- a clear_stored_path that keeps the in-game move (h.native=nil only);
- a Worldstone double that registers 'Worldstone Looting' = Scavenger.is_busy.
Cases:
(1) In-flight far-target command, 1 drop: 1/1 picked, 0 'Another move took the player off'. On 8bb81bd: 0/1, 1 yield (fails).
(2) Lag 1 s, 2 drops: 2/2 picked. On 8bb81bd: 0/2 (fails).
(3) Navigator that ignores every condition: at most 1 yield per drop, the first no later than 2.5+0.3+0.2 s after busy, and the player keeps advancing (no freeze).
(4) No _G.Worldstone: the first yield still comes 0.3 s after the foreign move (1.0.21 unchanged).
(5) force_move_raw calls are at most 13 per drop.
Prove that (1) and (2) fail by stashing the fix. Also re-run test_rosie_scavenger_mimic, yield_reach_1022, back_forth_332, foreign_mover, pickup_1022, pickup_fight_q1 and suite_rosie_scavenger_skip.

## Navigator 0.1.0 keeps moving the player while 'Rosie Looting' is true. Why cannot be decided offline: it ignores the condition, runs a command already in flight, reads the condition late, or the condition is not registered

**Owner:** Third party (Navigator/Worldstone .pak, not fixable). Workaround: Auditor, mimic diagnostics (scavenger_mimic.lua); Rosie, bounded stop fallback (pickup.lua / foreign.lua)  
**Confidence:** likely  
**Code:** Rosie/rosie/private/scavenger_mimic.lua:137 (condition), :245-254 (shim, register once per Navigator table, log line :252); Rosie/rosie/private/foreign.lua:43-46 (navigator_status), :59 (trip condition 'Rosie'), :84-99 (quiet_navigator stop pattern); Rosie/rosie/private/pickup/src/pickup.lua:419-421 (the yield line logs no Navigator state); tools/ApiProbe/main.lua:7,121-124; docs/THIRD_PARTY_APIS.md:20,33,38,40

**Mechanism:**
Each 'Another move took the player off' line proves that the player walked at least 0.5 m toward a non-Rosie point more than 2.5 m away for 0.3 s (pickup.lua:399-410). On the pulse before, Pickup.step returned true, so 'Rosie Looting' was true (main.lua:80; scavenger_mimic.lua:113-117, 137), provided it was registered (the :252 log line).

Discriminator from the log: 'Leaving Pragmatic Tuning Prism ... no progress' at 6146.69 is a first-round settle. It needs at least 6 s of steps returning true (pickup.lua:486-495, :501, :530). So the hold was continuously true from about 6140.7 to 6146.69, with no yield. Four yields followed at 6148.72. Dust at 6344.98 is followed by yields at 6348.58, the same pattern. Two readings:
- If the gems were wanted right after the settle, the hold never dropped (DEBOUNCE 1 s, scavenger_mimic.lua:97). Navigator then moved the player after about 8 s of a true condition. That rules out the in-flight and ≤5 s lag models and points to Navigator ignoring or not seeing 'Rosie Looting', for example a single-slot overwrite by the 'Rosie' trip condition at foreign.lua:59.
- If the gems were outside the Distance slider until Navigator carried the player to them, the hold was off for at least 1 s. The in-flight and lag models then fit, and cause 1's fix is sufficient.

The docs' 'Worldstone polls every 5 s' is ApiProbe's 5 s dedup of identical lines (main.lua:121-124), not a measured rate.

**Evidence:**
Live log plus the code above. The repro separates the models but cannot pick one: the ignore model gives 0/4 with 4 yields (busy=true nav_paused=false); a single-slot overwrite after a trip gives 1/4; a Worldstone-only condition polled every 5 s gives 0/4; the ideal model gives 4/4. The investigation's grace prototype (proto_1024.patch) still loses in the ignore and slot models (1/4, 2/4), per the repro report.

**Fix:**
(a) Diagnostics, pcall-guarded, only while the mimic is in effect:
- the mimic counts reads of condition() and of shim.is_busy, and records the time of the last read;
- the yield line, and a once-per-episode line when the grace from cause 1 expires, append: busy, the age and rate of 'Rosie Looting' reads, and pcall(Navigator.get_status) state / owner / is_paused / is_busy / remaining_distance, plus Movement.status().detail.
(b) A runtime-gated fallback in pickup.lua. It fires when the grace has run 0.5 s, get_status().is_busy==true, is_paused~=true, and owner is not 'Rosie' or 'Butler'. It then calls foreign-style `Navigator.stop()` at most once per drop and at most 5 times per busy episode, with the STOP_GAP 1 s pattern from foreign.lua:84-99, logged once. Worldstone re-issues navigate() by itself.
Ship (a) for sure. Ship (b) behind the gate: its effect on Worldstone's flow is a live check.

**Test:**
In test_rosie_nav_hold_1024.lua:
(6) Navigator that ignores conditions, with a Worldstone double that re-navigates only when Scavenger.is_busy() is false: 4/4 picked, ≤4 stop() calls. On 8bb81bd: 0/4 (fails).
(7) Worldstone that re-navigates at once after a stop: stop() calls ≤5 per episode, the portal is still reached, and there is no hold longer than CAP 20 s.
(8) The diagnostic line appears once per episode and contains 'paused=false' and a read age ≤0.2 s. It is absent without _G.Worldstone, and it still prints when get_status raises or is missing.

## Calm tail of the fight hold: Scavenger.is_busy() stays false for about 1-1.25 s after the last kill, so Worldstone can start walking before Rosie's first step

**Owner:** Rosie (pickup.lua, main.lua) + Auditor (scavenger_mimic.lua:234)  
**Confidence:** possible  
**Code:** Rosie/rosie/private/pickup/src/pickup.lua:339 (FIGHT calm 1.0, margin 4), :356-379 (fight_hold), :386-394 (fight_deferred), :449; Rosie/rosie/private/pickup/src/item_manager.lua:418-419; Rosie/rosie/private/pickup/main.lua:80,87-88; Rosie/rosie/private/scavenger_mimic.lua:25-28,234

**Mechanism:**
By design the mimic is never busy during the fight hold (scavenger_mimic.lua:25-28; main.lua:88 sets only looting). get_wanted_items also leaves out fight-deferred drops (:234). The hold ends only after 1 s with no enemy within 14 m, plus a 0.25 s cache. Until then, drops farther than 3 m are deferred and the Scavenger reads idle and empty. A Worldstone that gates navigate() on is_busy() or on wanted items leaves in this window, and cause 1 then turns Navigator's head start into yields. This is only a trigger: with a Navigator that honours the hold it loses nothing.

**Evidence:**
Code as cited. In the repro, first busy comes 1.1 s after the kill (+15.30 vs a walk at +15.0). It loses drops only together with cause 1 or 2 (M7 table: every-frame model 4/4, in-flight far 0/4). Worldstone's actual leave logic is closed, so the trigger is inferred.

**Fix:**
pickup.lua: `function M.calm_tail() return FIGHT.on and not FIGHT.capped and not Utils.enemy_near(G.fight_radius+FIGHT.margin) end`. main.lua after :87: `if fight_busy and Pickup.calm_tail() then Mimic.note_work(get_time_since_inject()) end`. note_work is a no-op out of effect. In scavenger_mimic wanted_now (:234), keep a fight-deferred drop while Pickup.calm_tail() is true. It is never busy while an enemy is within 14 m, which keeps the BOARD:152 lesson (a fight wait froze Navigator for 46.6 s).

**Test:**
Kill case in test_rosie_nav_hold_1024.lua: the enemy dies at (37,0), and the wanted drops are 7-9 m away. Expected:
- Scavenger.is_busy() true within 0.3 s of the kill (8bb81bd: about 1.1 s, fails);
- never true while any enemy is within 14 m;
- with a Worldstone that navigates on the first frame is_busy is false, together with cause 1: 2/2 picked, 0 yields (8bb81bd: 1/2, 2 yields).

## Dead band from 2 to 3 m: pickup interacts only within REACH=2 m and has no fallback when the player cannot get closer. Each stall keeps the stand-in busy and holds Navigator for 6-20 s

**Owner:** Rosie (claude/qqt-rosie): Rosie/rosie/private/pickup/src/pickup.lua  
**Confidence:** likely  
**Code:** Rosie/rosie/private/pickup/src/pickup.lua:19 (REACH 2), :23-24 (ROUND_STALL 6, PROGRESS 0.5), :325-337 (fighting(): a cast, an enemy within 10 m, or 'host kept'), :339 (FIGHT.feet 3), :481-498 (stall: a clear window settles a non-gear drop as 'Leaving ... cannot reach it'; otherwise fail_round), :502-513 (walks while d>2), :514-529 (interacts only when d≤2); Rosie/rosie/private/pickup/utils/utils.lua:13-19 (2D distance); Rosie/rosie/movement.lua:117 (arrival 1.5 m in 3D, never before 2 m in 2D), :163-168; Rosie/rosie/private/route.lua:20,139,175

**Mechanism:**
The drop lies where the game will not let the player stand within 2 m of it: an altar step, rocks, or a prop. request_move brings the player to the nearest standable point, 2.1-2.8 m away. Pickup keeps walking every 0.35 s and never calls interact_object. After 6 s without 0.5 m of progress it settles a non-gear drop with exactly the live line (Tuning Prism 2.7, Primordial Dust 2.4, Conduit Globe 2.8, all [interactable=true]).

If the window held a fight sample, it runs 3 rounds of 6 s instead. That is the Power Globe pattern: round 1/3 at distance 2.1, then round 2/3 6.1 s later. A fight sample can also be 'host kept' from a skipped request_move with no enemy present (movement.lua:167, pickup.lua:330-334), so 'Retrying' does not prove an enemy was near.

The whole time, step returns true (:501, :530), so the stand-in is busy and 'Rosie Looting' holds Navigator and Worldstone.

A 'Leaving' settle needs a window with no 'host kept' sample. So the host accepted Rosie's moves and no foreign destination was seen, which argues against Navigator pinning the player. This assumes request_move returns false when it skips (movement.lua:163-166 says 'assumed').

**Evidence:**
I re-ran scratchpad/judge_nav/audit/tests/test_zz_repro_rosie_nav_band.lua on the 8bb81bd export (5.4 and LuaJIT pass):
- B1: a wall stops the player at 2.4 m; 0 interactions; '+7.5 Leaving Pragmatic Tuning Prism: cannot reach it (no progress, distance 2.4)'; the helm gets '(not walkable, distance 2.4)'.
- B2: an enemy near gives 'Retrying … round 1/3' at +6.1 and 2/3 at +12.2, 'Gave up' at +18.3.
- B3: with no enemy but a skipped request_move, the same three rounds.
- B5: the stand-in keeps Navigator paused for 8.3 s (20 s with host kept).
- B4: real Batmobile loaded, 0 Batmobile moves.
Geometry is inferred: the live distances cluster just above REACH. The Distance slider value is still needed to rule out a pinned player.

**Fix:**
pickup.lua, Rosie 1.0.24: add `local BAND={far=REACH+1,stall=1.0,gap=0.4}` (far equals FIGHT.feet at :339). In M.step after the stall checks: `local band=d>REACH and d<=BAND.far and now-e.best_at>=BAND.stall`. Walk only when `d>REACH and not band`. Otherwise take the interact branch with `e.next=now+(band and BAND.gap or INTERACT_GAP)`. That branch already releases movement, so no move is sent in the band. Band interactions count in e.interacts but not in e.reach or e.clear (`if not fight and not band`), so a refused drop is never settled as 'taken'. The 6 s stall, the rounds and the 20 s episode still bound it. Log 'Interacting with X from 2.x m (the player gets no closer)' once per drop. Optional: Power/Conduit Globes may be proximity-only pickups like obols (item_manager.lua:89-92). Exclude them if the owner confirms that interact never takes them.

**Test:**
New file audit/tests/test_rosie_standoff_band.lua: the drop at (8,0), walls {{6,10,-2,2}}, and on_interact takes it only within 3.0 m. Cases:
- S1 prism: picked, busy ≤2.5 s, no 'Leaving' line (8bb81bd: 0 interactions, 'Leaving … distance 2.4' after 7.5 s; fails).
- S2 helm: picked (8bb81bd: '(not walkable…)'; fails).
- S3 the game takes it only within 2.0 m: exactly one 'Leaving' line, busy ≤8 s, interactions ≤15.
- S4 open ground: every interaction at ≤2.0 m.
- S5 Worldstone stand-in: Navigator paused ≤2.5 s (8bb81bd: 8.3 s; fails).
- S6 an enemy that never dies at 6 m: picked, no 'Retrying' (8bb81bd: rounds 1-3; fails).

## The first stash deposit of a visit goes out on the 'inv' signal while the stash list is still loading (stash_n=16 of 293), and the game drops it

**Owner:** Rosie (claude/qqt-rosie): Rosie/rosie/private/town/tasks/stash.lua (vendor.lua unchanged)  
**Confidence:** likely  
**Code:** Rosie/rosie/private/town/core/vendor.lua:50-54 (baseline), :65-79 (inv signal :75, no list check); Rosie/rosie/private/town/tasks/stash.lua:191-201 (stash_open log :198), :353-354 (0.3 s tick), :371 then :417-463 (deposit on the same tick; move_item_to_stash :459), :373-375 (Alfred waits 2 s after interacting), :423-424 (the partial count also feeds the capacity check and cache)

**Mechanism:**
The baseline is taken just before the interaction: inv=false, stash_n=0. On the next 0.3 s tick the inventory panel reads open, and stash_signals returns why='inv' without looking at the list (vendor.lua:75). Execute sends move_item_to_stash on that same tick, while get_stash_items lists 16 of 293 entries (32 of 300 in the earlier log). The bag stays at 3 for 8 s, so the command moved nothing. Every deposit after the list filled was confirmed in about 0.3 s.

**Evidence:**
Live: 'Stash reads open: signal=inv attempt=1 … stash_n=16', then 'Deposit requested' at the same timestamp 6699.24, then 'stash_n=293' at 6707.33. I re-ran scratchpad/judge_nav/audit/tests/test_zz_repro_rosie_nav_stash.lua on the 8bb81bd export. It reproduces the exact sequence: 'Open stash attempt=1 … stash_n=0' → 'Stash reads open: signal=inv attempt=1 … stash_n=16' plus 'Deposit requested' on the same tick → '(bag 3 -> 3, stash 0 -> 1)' → '… attempt=0 … stash_n=293'. The model assumes the game drops moves sent while the list loads. The other explanation, 'the game refuses Mythics', cannot be excluded: both live first deposits were Mythics.

**Fix:**
stash.lua, Rosie 1.0.24. Track list_n and list_at in stash_open(), and reset them at each interaction (:393-395). Before the first receipt of an interaction (not state.proven), Execute waits with the status 'Waiting for the stash list to load' until three things hold:
- at least 2 s since the interaction (Alfred's rule, :373-375);
- the count unchanged for 1 s;
- the count no more than 10 below tracker.stash_item_count_cached from the last visit.
After 6 s it goes anyway. Add stash_n to the 'Deposit requested' line. Mark it `-- QQT_Warpigz_v3 1.0.24`.

**Test:**
New file audit/tests/test_rosie_stash_load_1024.lua. The host model lives inside the test, so joint_host is untouched:
- sdk=false, inv=true;
- the list is empty for 0.25 s, then 16 entries until LOAD, then full;
- moves before LOAD return true and move nothing.
Cases:
- L1: 3 Furnaces (sno 223465, Rosie/rosie/data/items.lua:136), one copy already at stash index 40. Expect 0 left and no 'transfer not confirmed'. 8bb81bd gives the exact live line and 3 left (fails).
- L4: a second visit whose list pauses at 16 for 4 s. Expect 0 dropped moves (8bb81bd: 2; fails).
Re-run test_rosie_stash_q5, stash_rc10 and secondpass_town.

## The receipt check will not resend when a same-SNO stash count grows during the load, so after 8 s it skips every copy of that SNO for the trip, and this repeats each visit

**Owner:** Rosie (claude/qqt-rosie): Rosie/rosie/private/town/tasks/stash.lua  
**Confidence:** confirmed  
**Code:** Rosie/rosie/private/town/tasks/stash.lua:287-345 (pending_receipt: bag receipt :308, 3 s :313, ambiguous branch :321-331, 3 attempts :332-336, retry :342-344), :262 (ITEM_WAIT 8), :269-285 (skip: key bag:sno :270, interactions reset :280, which re-logs 'Stash reads open' via :196-199), :92 (all copies filtered), :139-163 (next_item walks the bag in host order, with no priority)

**Mechanism:**
p.destination was read from the 16-entry list: 0. As the list loads, a Furnace stashed earlier appears and the count becomes 1. The bag is unchanged, so neither receipt passes. `destination~=p.destination` routes it into the ambiguous branch, which by design never sends a second command. After ITEM_WAIT it calls skip(). skip() marks the whole SNO, so candidate() drops all 3 copies (:92). Resetting interactions re-logs the second 'Stash reads open … stash_n=293' line; it is not a new interaction.

With no prior copy in the stash, the count stays 0 and the retry path (:342) recovers on attempt 2. The loss therefore needs a first deposit, a partial list and a prior copy, which Mythics usually have.

next_item has no Mythic-first order. The skipped copies simply keep the front bag slots, so the same SNO is the victim on the next visit.

**Evidence:**
Code as cited. Repro S4 on the 8bb81bd export: trip 1 'Skipped 2HMace_Unique_Generic_001 … transfer not confirmed after 8s (bag 3 -> 3, stash 0 -> 1)'; trip 2 the same line again, with 3 Furnaces left. Without a prior copy the item is deposited on attempt 2. Live: the same line, and earlier the same pattern with Nemesis Bracers (stash_n 32 → 300). joint_host returns the full list the moment the panel opens (audit/tests/joint_host.lua:805-809), so no shipped test has a loading list.

**Fix:**
In pending_receipt, save p.list_n (the list size at send). After the 3 s wait, when source==p.source and |#stash - p.list_n| > 1, the per-SNO stash change is not a receipt. Set destination=p.destination and log once: 'Stash list changed from A to B entries while X was pending; its bag count did not change, so nothing moved'. The existing re-interact and resend path, bounded by 3 attempts, then runs instead of the 8 s skip. This keeps Q5-5 (audit/tests/test_rosie_stash_q5.lua:193-201: exactly 1 command when the stash side changes on a complete list) and Q5-4 (:182-191) green. A plain 'retry every transfer-not-confirmed' would break Q5-5 :199. Optionally, re-select a bag-unchanged skip once at the end of the visit, only if the list has grown by more than the receipts since the send.

**Test:**
Same file. L1 with LOAD=4 or 9 s, where the list pauses at 16 long enough to pass cause 5's gate: the Furnace is deposited on attempt 2 or 3, with 0 'Skipped' lines (8bb81bd: skipped; fails). L3: a refused Mythic on a complete list gets ≤3 commands and exactly one 'Skipped' line. A second trip leaves 0 Furnaces. Q5-4, Q5-5, Q5-9, Q5-12 and Q5-14 must still pass under Lua 5.4 and LuaJIT.

## Batmobile involved?

No. Batmobile has no part in the yields, the 2-3 m stalls or the lost first deposit.

- **Pickup never calls Batmobile.** Rosie's pickup walks through the host pathfinder in Rosie/rosie/movement.lua:3,150. From Batmobile it reads only is_paused/get_owner (Rosie/rosie/controller.lua:13-20), and only to decide whether to clear a path (:80).
- **Batmobile does not move by itself in a Worldstone run.** It moves only inside navigator.move (Batmobile/core/navigator.lua:1268-2518). That runs only on a long route, in freeroam, or when a caller calls move() (Batmobile/main.lua:149-186; Batmobile/core/external.lua:184-200). A Worldstone+Navigator run does none of these.
- **The 2.2.2→2.2.3 change is unrelated.** It only makes freeroam ignore Rosie's stand-in (Batmobile/main.lua:46-54). With freeroam on, 2.2.2 would have waited on the stand-in, not moved the player.
- **The 3 u caller-goal rule is unrelated.** CALLER_GOAL_REACH (navigator.lua:169) never stops a move.
- **Offline check:** with the real Batmobile loaded, the joint-host repros show 0 Batmobile moves and identical log lines.
- **Town:** Rosie uses Batmobile there only to walk to the stash (stash.lua:409-410). The lost deposit happens after the panel is already open.

A live confirmation is cheap: no Batmobile or [LONG PATH] lines in the run, and BatmobilePlugin.get_owner() stays nil.

## Refuted

- Batmobile as a cause of any of the three symptoms. Rosie's pickup walks through the native pathfinder in rosie/movement.lua:3,150. Rosie reads Batmobile only through is_paused/get_owner (Rosie/rosie/controller.lua:13-20), and uses it only to skip a path clear (:80). Every Batmobile request_move sits inside navigator.move (Batmobile/core/navigator.lua:1268-2518). That runs only on a long route, freeroam, or a caller's move() (Batmobile/main.lua:149-186, core/external.lua:184-200). The 2.2.2→2.2.3 change only makes freeroam ignore the stand-in (main.lua:46-54). The repro with real Batmobile loaded shows 0 Batmobile moves and identical lines. The stash walk uses Batmobile in town (stash.lua:409-410), but the lost deposit happens after the panel opened.
- The 2–3 m stalls as a Batmobile dead band (CALLER_GOAL_REACH=3, navigator.lua:169): it only suppresses STUCK/unstuck and never stops a move, and Batmobile is not in the loop.
- 'is_busy is false before Rosie's first step', so Navigator gets a head start on every drop: step 1 cannot yield (pickup.lua:396) and sets busy on the same pulse (main.lua:80, scavenger_mimic.lua:113-117). The only head start is the fight-hold calm tail (cause 3) or drops that enter the Distance slider while Navigator walks.
- 'Worldstone polls Scavenger.is_busy() about every 5 s' as evidence of a slow reader: it is ApiProbe's 5 s dedup of identical call+result lines (tools/ApiProbe/main.lua:7,121-124).
- Mythic-first deposit order as a cause: no priority sort exists (stash.lua:139-163, host bag order). A Mythic is first again because the SNO-wide skip (:92, :270) leaves its copies in the front slots. That is a consequence of cause 6.
- 'Clear-and-resend lets Rosie take the path back' (movement.lua:154-161): the clear only sets state.next=0. Pickup's next call waits MOVE_GAP 0.35 s (pickup.lua:503), and the 0.3 s yield comes first.
- 'The item did move and the bag list was stale' (the Q5-5 case) for the Furnace: every later deposit in the same visit was confirmed by a bag change within 0.3 s, and the bag read 3 -> 3 for 8 s. This is unlikely, but the owner's post-trip counts would settle it.
- A paused Navigator pinning the player as the cause of the 'Leaving … no progress' stalls: not supported. A 'Leaving' settle needs a window with no 'host kept' sample (pickup.lua:330-334, 490), and the distances cluster just above REACH. It is not fully excluded: request_move returning false on a skip is assumed (movement.lua:163-166), and the Distance slider value is unknown.
- 'The shipped tests prove the 1.0.23 hold works': the fake Navigator pauses instantly (test_rosie_scavenger_mimic.lua:68-95), and the joint host accepts every request_move and cancels on clear (joint_host.lua:946-963).

## Ask the owner

Ask the owner for these; they decide what cannot be settled offline.

1. **Settings.**
   - The Rosie pickup "Distance" slider value. This decides cause 2: if the gems were already inside the slider range after the prism or dust stall, Navigator ignored a hold that had been true for 8 s. If they were outside it, Navigator was already walking and the in-flight/lag models apply.
   - Whether "Act as Scavenger for Worldstone/Navigator" is on.
   - Loot priority (nearest or best).
   - Whether ApiProbe is still installed.
2. **One raw console log, 20 s either side of one yield series** (for example 6140-6155), unfiltered. Include every [Navigator], [Worldstone], [Rosie], [Rosie pickup] and [Rosie:stash] line. In particular:
   - when Worldstone's position request started;
   - any "Busy as Scavenger for", "busy 20s without picking anything up" or "Pickup pause by Worldstone (through Scavenger)" line.
3. **Once per session:** do these lines appear?
   - `Acting as Scavenger for Worldstone/Navigator`
   - `Navigator waits while Rosie picks up a drop (pause condition "Rosie Looting")`
   - `Navigator.set_pause_condition failed`
   - `Navigator is held during town trips (pause condition "Rosie")`
   Also: do the yields happen in the first Worldstone run after a reload, before Rosie's first town trip? That tests the single-slot overwrite.
4. **If ApiProbe is loaded:** probe_log.txt for one boss-to-portal sequence. It should show Navigator.get_status with is_paused, state and owner, and Worldstone's Scavenger.pause/resume timing.
5. **One "Leaving … cannot reach it" drop.**
   - A screenshot: is it on a ledge, a rock or an altar step?
   - Does a manual click from where the bot stood pick it up? That tests interact_object from 2-3 m.
   - Are Power Globes and Conduit Globes taken just by walking over them?
6. **Stash.**
   - After the trip with "Skipped 2HMace_Unique_Generic_001": how many The Furnace are in the bag, and how many in the stash?
   - The host=… value on that "Deposit requested" line.
   - Has Rosie ever logged "Deposited <a Mythic>"? A Mythic deposited later in a visit, after the list loaded, rules out "the game refuses Mythics".
7. **Rotation movement:** is evade or other movement on in Universal Rotation? It would be another source of foreign moves.

**Live checks after 1.0.24:**
- no "Another move took the player off" line before the portal;
- the new diagnostic line shows paused=true or false;
- "Interacting with X from 2.x m" is followed by the drop leaving the ground;
- the first "Deposit requested" of each visit comes 2-3 s after "Stash reads open", with the full stash_n and no "transfer not confirmed";
- no Mythics piling up in the bag.

**Reproduction used here** (the repo was untouched): a git-archive export of 8bb81bd plus the three repro tests, at /tmp/claude-0/-home-user-QQT-Warpigz-v2/f0661e64-4c16-5466-a632-f06a0350959a/scratchpad/judge_nav/audit/tests/test_zz_repro_rosie_nav_{yield,band,stash}.lua. All three pass under Lua 5.4 and LuaJIT.
