# SilentRaven 0.2.6: "manual now" and receipt_unconfirmed (Coordinator investigation, 2026-09-28)

Source: Discord report + screenshot (manual run, `API_CLAIMING -> run finished: unconfirmed (receipt_unconfirmed)`, then `no Whisper quest (Bounty_Meta_*) in the quest list`). Investigated on d425cf5 (3.3.5) with repro scripts vs 0.2.5 (v3.3.2); an adversarial judge kept these causes. Owner session: Raven (SilentRaven).

## RC1 (3.3.3 regression): the TristramLoop 'activity_owner' hold has no time limit and applies to auto-fire only. The keybind is exempt, so standing in Temis never auto-claims.

**Confidence:** confirmed  
**Code:** d425cf5 SilentRaven/silent_raven/coordination.lua:246-254 (activity_owner reads TRISTRAM_LOOP_STATE.status() fresh on every call; true when running and owns_activity) -> coordination.lua:304-307 (modes 'auto' and 'delegated' only; 'manual' skips it) -> SilentRaven/main.lua:147-149 (note_hold, then return). Claim trip: claims.lua:96-97 (blocker 'activity'). The keybind path main.lua:163-164 never reaches it. Before 3.3.3, v3.3.2 coordination.lua:248-256 had no such check. Rosie bounds the same signal: Rosie/rosie/private/town/main.lua:28 (DEFER_TOWN=60, DEFER_ANY=600) and :99-115.

**Mechanism:**
While a loop plugin publishes TRISTRAM_LOOP_STATE with running and owns_activity:
- Every auto-fire sample in Temis returns 'activity_owner:TristramLoop, <phase>' and does not fire.
- Nothing expires the hold. elapsed() and HARD_NEED_LIMIT apply only to Alfred.
- The claim trip is blocked for the whole session.
- Only Rosie's return-leg hand-off can still claim (teleport.lua:162-218), and Rosie defers its own trips for the same signal.
- The keybind ignores the gate and claims at once.
This is exactly the screenshot: 'manual trigger fired' passed companions('manual'), yet auto never fired while the player stood in Temis (START->WALK_NPC means in Temis, fsm.lua:408).

**Evidence:**
Code as cited, and the diff v3.3.2..d425cf5 of coordination.lua adds only this gate and RC2's.

Re-run by the judge: test_zz_repro_raven_autofire.lua A8 (TRISTRAM_LOOP_STATE running+owns_activity, phase 'town').
- 0.2.6: auto_run_at=never, hold 'activity_owner:TristramLoop, town' for 60 s, then manual_after=fired.
- The same script on the 0.2.5 tree (scratchpad/wf4/old): auto_run_at=+0.1s, success.

Other evidence:
- q8_bounds case T (audit/tests/test_silentraven_q8_bounds.lua:313-328) fails on 0.2.5 at :322.
- Worldstone loop plus TristramLoop: 0 runs in 4 Temis stops.
- CHANGELOG.md:80-84 (Rosie 1.0.19): the owner's Worldstone loop kept 'another activity owns the run' on for hours.

Not verified live: whether the reporter's setup publishes TRISTRAM_LOOP_STATE, and whether owns_activity stays true while idle in Temis.

**Fix:**
Bound it the way Rosie does.
- Track when the reward became ready: tracker.ready_since, set in main.refresh_ready (or read claims.state.ready_since).
- In companions('auto'/'delegated'), skip activity_owner once the player is in Temis and now - ready_since >= 60 s (ACTIVITY_DEFER_S, like Rosie's DEFER_TOWN). A Temis stop between runs then claims.
- Once the run starts, the Navigator pause condition holds Navigator-driven loops (this needs RC2's fix).
- Keep the claim-trip 'activity' blocker, or bound it at 600 s like DEFER_ANY.
- Log it once at info: 'auto-fire waited 60s for <owner>; claiming at this Temis stop'.
- Mark the change '-- QQT_Warpigz_v3 X.Y.Z: …'.

**Test:**
Rewrite q8_bounds case T:
1. J.new({dirs={'Batmobile',SR}, place='temis'}), SilentRaven enabled, TRISTRAM_LOOP_STATE={status=function() return {running=true,owns_activity=true,phase='town'} end} for the whole case, h.bounty_ready=true.
2. Assert no 'claiming the Whisper reward' before 59 s.
3. Assert exactly one 'claiming the Whisper reward (auto)' by 70 s, and the run finishes.

It fails on d425cf5: no claim at 70 s, the current :322 behaviour. Prove it by stashing the fix.

## RC2 (3.3.3 regression): the Navigator/Butler/Scavenger holds apply in every mode with no time limit. The Navigator hold is circular: only SilentRaven's own pause condition could clear it, and that condition only switches on after admission.

**Confidence:** confirmed  
**Code:** d425cf5 SilentRaven/silent_raven/coordination.lua:
- :271-279, third_party_reason: Butler.is_busy -> 'butler_busy'; Scavenger.is_busy -> 'scavenger_busy'; Navigator.get_status with is_busy, not is_paused and owner ~= 'SilentRaven' -> 'navigator_busy:<owner>'. No elapsed() bound, unlike the UNKNOWN_LIMIT and HARD_NEED_LIMIT checks at :21, :39-46 and :152-160.
- :283-291, the pause condition: returns `tracker.running == true and tracker.yield_since == nil` (:288-290).
- :310, applied in every mode.

Where it bites:
- Auto-fire: SilentRaven/main.lua:147-149.
- Keybind: main.lua:163-167, 'manual trigger deferred: <reason>'.
- Claim trip: claims.lua:100-101.

For comparison, the peers bound the same signals: WarPigs dispatch.THIRD_PARTY at 30 s / 180 s (WarPigs/core/orchestrator.lua:585-586) and WarPug third_party.HOLD=180 (WarPug/core/planner.lua:230-244).

**Mechanism:**
How Worldstone blocks every stop:
- Worldstone returns to Temis and walks to the dungeon portal through Navigator: owner 'Worldstone', priority 0, unpaused (docs/THIRD_PARTY_APIS.md:14, 36-38).
- If that request is already busy when SilentRaven first samples in Temis, every sample is 'navigator_busy:Worldstone'.
- SilentRaven's pause condition, which would hold Navigator, only turns true once tracker.running is set. That never happens, so every Temis stop passes with no claim.

Butler and Scavenger: is_busy is trusted forever.

The outcome is a race. If SilentRaven samples before Worldstone's navigate, it fires, pauses Navigator and claims.

**Evidence:**
Re-run by the judge, autofire repro (0.2.6), 60 s each:
- A6 (Navigator busy for Worldstone): auto never fired; keybind 'deferred(navigator_busy:Worldstone)'.
- A9 (Butler busy): auto never fired; keybind 'deferred(butler_busy)'.
- A10 (idle-but-busy Navigator): auto never fired.
- The same cases on the 0.2.5 tree: auto_run_at=+0.1s, success.
- With no third-party addon, A0-A5, A7, A11 and A12 all auto-fire at +0.1 s on 0.2.6.

Other evidence:
- q8_bounds case N (:334-353) fails on 0.2.5 at :349.
- Worldstone loop: 0 runs when the request is pending on the first Temis frame; a success when it arrives 0-1 s later. So it is timing-dependent live.

This cannot explain the screenshot moment. The keybind checks the same gate and it fired, and auto-fire would have fired within 0.5 s of the gate clearing. It explains 'manual' for Worldstone/Butler users in general.

**Fix:**
(a) In third_party_reason, a Navigator request with priority < 10 (an activity walk: Worldstone sends none, so 0) no longer holds. Once the claim runs, SilentRaven's pause condition holds it; Rosie's trip does the same. Keep holding for priority >= 10 (Butler's town walk, :49).

(b) Bound butler_busy, scavenger_busy and a priority >= 10 navigator_busy to 180 s per ready episode, like WarPug HOLD, with one info line. Use a clock that survives the 1 s / 2 s sampling-gap resets.

The `_rosie` stand-in skip is already in ca32b17 (0.2.7).

**Test:**
New case in test_silentraven_q8_bounds.lua (or test_silentraven_navigator.lua):
1. place='temis', dirs {'Batmobile',SR}.
2. A Navigator mock with set_pause_condition storing conditions, is_paused = any condition true, and a permanent Worldstone request {is_busy=true, owner='Worldstone', priority=0}.
3. bounty_ready=true.
4. Expect 'claiming the Whisper reward (auto)' within 2 s, cond.SilentRaven()==true while running, and 'run finished: success'.

It fails on d425cf5 (A6: never). Keep N green (Butler priority 10).

Add a Butler.is_busy-stuck-true case: expect a claim after the 180 s bound, with one log line.

## RC3 (3.3.3 regression): mid-run yield loop. Any yield releases SilentRaven's Navigator pause, and the busy Navigator then keeps the run yielding until it is cancelled at 120 s (or leaves Temis).

**Confidence:** confirmed  
**Code:** d425cf5 SilentRaven/silent_raven/coordination.lua:288-290 (the condition is false while yield_since is set), :274-277 and :310 (navigator_busy also in mode 'run'); fsm.lua:246-257 (yielding() calls companions('run') every tick), :87-107 (hold sets yield_since; YIELD_LIMIT_S=120 at :26; finish('cancelled', true, keep_visit) at :105), :419-425 (left_temis while paused), :407 (companion_yield for auto/manual/delegated). v3.3.2 'run' mode checked only Alfred live work and the Looter (coordination.lua:253).

**Mechanism:**
1. An own run yields: a 1 s Looter or Rosie pickup blip, Alfred live work, or the stand-in tail.
2. yield_since is set, so the 'SilentRaven' condition turns false.
3. Navigator resumes Worldstone's request and reports busy and unpaused.
4. The reason becomes navigator_busy:Worldstone, so the yield never clears.
5. Result: 'cancelled (yield_timeout:navigator_busy:Worldstone)' at +120 s. Live, Worldstone more likely walks the player into the portal first, giving 'left_temis'.
6. The visit is not latched, and the next admission is held again by RC2.

If Navigator's is_paused does not reflect pause conditions (unverified, THIRD_PARTY_APIS.md:21-24), the run yields on its first tick.

**Evidence:**
Re-run by the judge, test_zz_repro_raven_yield.lua (0.2.6):
- Y1 (no blip): success in 7.9 s.
- Y2 (1 s Looter blip): hold sequence [+1.0 looter_busy, +2.0 navigator_busy:Worldstone]; then 'waiting 60s for navigator_busy:Worldstone…' and 'run finished: cancelled (yield_timeout:navigator_busy:Worldstone) — not claimed' at +121.1 s, accepts=nil.
- Y3 (is_paused ignores conditions): cancelled at +120.6 s.
- Y4 (Rosie stand-in tail): cancelled at +121.2 s.
- On 0.2.5 all Y cases succeed; 0.2.5 never pauses Navigator, and the mock never moves the player.

**Fix:**
Keep the pause condition on during a yield unless the yield is for a town service that walks through Navigator:
`tracker.running == true and not (tracker.yield_since ~= nil and (tracker.yield_reason == 'butler_busy' or tostring(tracker.yield_reason):find('^navigator_busy:')))`.

With RC2(a), a priority-0 Navigator request is never a 'run' hold reason, so a Worldstone request cannot hold the yield. The stand-in skip is already in ca32b17.

**Test:**
Joint host, place='temis':
1. Manual keybind run.
2. A Navigator mock that honours conditions, with a Worldstone request (priority 0) 0.5 s after the press.
3. LooteerPlugin.is_actively_looting true from +1 s to +2 s.
4. Expect 'run finished: success' within 12 s and no 'yield_timeout'. Assert cond.SilentRaven()==true during the Looter blip.

It fails on d425cf5 (Y2: cancelled at +121 s).

## RC4 (older code, the screenshot's 'unconfirmed'): the receipt counts only a rise in the bag. A claim that happened (the quest left the list) is reported 'unconfirmed — not claimed' and counted as a failure.

**Confidence:** confirmed  
**Code:** d425cf5 SilentRaven/silent_raven/fsm.lua:452-465:
- :457 needs `count > tracker.claim_before and snapshot and closed`; snapshot is only nil-checked, never present/ready.
- :461-463 sets receipt_unconfirmed after 8 s.

Other pieces:
- whispers.lua:174-197, cache_count: reads only get_inventory_items and get_consumable_items (:181); returns nil if any SNO is unreadable (:186); counts an unreadable stack as 1 (:191-192).
- whispers.lua:6-11 itself says 'quest disappears from log = successfully turned in'.
- finish, fsm.lua:54-73: latch at :56, stats.bump_failure at :61-62, ' — not claimed' at :65-68, whisper_claim result=unconfirmed at :70-71.
- Pinned by audit/tests/test_silentraven.lua:95-103 ('quest_empty' -> unconfirmed).
- Identical in v3.3.2 fsm.lua:443-455; whispers.lua is unchanged v3.3.2..d425cf5.

**Mechanism:**
Accept is sent (SELECT_VERIFY->API_CLAIMING). The quest turns in and the panel closes.

The panel reads were clean booleans in this run: == false at START (fsm.lua:478), == true at INTERACT_NPC (:498). So the failing conjunct is almost certainly the bag count. Possible reasons:
- the card SNO differs from the item SNO;
- the cache lands in an unread list (dungeon key, socketable or talisman items);
- it stacks with an unreadable count;
- the new item's SNO is unreadable;
- the bag is full, or the reward is not a bag item.

After 8 s the run ends 'unconfirmed'. Effects:
- stats failure;
- D4Remote shows 'failed';
- WarRoom shows 'Whisper claim failed' (WarRoom/core/wr_ingest.lua:330-339);
- the log says '— not claimed'.

Users read this as SilentRaven not working.

**Evidence:**
The screenshot sequence equals test_zz_repro_raven_receipt.lua R-A line for line (re-run by the judge): the accept removes the quest and closes the panel, no bag item, then '… run finished: unconfirmed (receipt_unconfirmed) — not claimed' at +8.0 s, followed by 'no Whisper quest (Bounty_Meta_*) in the quest list'.

That last line is the first quest read after the run: refresh_ready is skipped while running (main.lua:371-376; claims.lua:162-175). So the quest really was gone.

R-C/D/D2/E/F/G/H (other SNO, other list, unreadable stack or SNO, panel not false) also end unconfirmed. R-B/B2 (card SNO in inventory or consumables) end in success.

A live 'run finished: success' has never been seen (SilentRaven/NOTES.md:9, audit/LIVE_CHECKLIST.md:25).

Not a 3.3.3 regression; it does not stop auto-fire by itself.

**Fix:**
In API_CLAIMING, also accept a turned-in quest as receipt:
- the quest was ready at START (store tracker.claim_quest_ready);
- a readable snapshot (non-nil) shows it no longer ready (absent, or a new collecting round);
- reward_panel_open() == false;
- all held for 1 s.
Then finish('success') with last_reason 'quest_turned_in' and log 'claimed <name> (quest turned in; cache not seen in the bags)'. A nil snapshot never counts.

On a real timeout, log pick SNO, claim_before, cache_count, is_open() and the quest state, plus a one-time diff of SNOs across all 5 bag lists (get_inventory_items, get_consumable_items, get_dungeon_key_items, get_socketable_items, get_talisman_items; cf. Rosie/rosie/private/pickup/utils/utils.lua:65-66).

Update README.md:19-21.

**Test:**
Edit test_silentraven.lua:95-103:
- 'quest_empty' (quest gone, panel closed, no bag item) now expects result 'success' and last_reason 'quest_turned_in'. It fails on d425cf5 ('unconfirmed').
- 'quest_error' (nil snapshot) stays 'unconfirmed'.
- New: quest still ready + panel closed + no bag item -> 'unconfirmed', and the new diagnostic line is logged.
- accept_throws with the quest still ready -> unconfirmed; with the quest gone -> success.

Accepts stay 1 in every case.

## RC5 (older code): after an 'unconfirmed' claim-trip hand-off, the trip-limit counter carries into the next ready episode. Every second reward gets no automatic claim trip on a client where readiness is inferred.

**Confidence:** confirmed  
**Code:** d425cf5 SilentRaven/silent_raven/claims.lua:
- :180 watch_trip runs first;
- :149 keeps waiting while Rosie is still live;
- :183-185 resets unclaimed when the quest leaves;
- :155 then adds 1 when Rosie's callback arrives later with a non-success result;
- :187-189 a new episode does not reset unclaimed;
- :211-215 the limit is 1 when readiness is inferred.
Same in v3.3.2.

**Mechanism:**
1. Claim trip -> Rosie hand-off -> RC4 'unconfirmed'.
2. The quest disappears, which resets unclaimed=0.
3. Rosie finishes its return leg and the callback fires. The result is not 'success', so unclaimed becomes 1 with no episode left to reset it.
4. The next ready episode logs 'reward ready: no more claim trips after 1 without a claim; waiting for a Temis visit'.

On the Russian client readiness is always inferred (NOTES.md:8), so every second reward waits for a manual or Temis claim.

**Evidence:**
test_zz_repro_raven_trip_carry.lua (ru):
- '1079.9 run finished: unconfirmed'
- '1080.0 no Whisper quest'
- '1085.4 claim trip ended without a claim (…SilentRaven: unconfirmed, receipt_unconfirmed)'
- '1089.0 reward ready: no more claim trips after 1 without a claim'

On en, episode 2 gets 1 trip instead of 2. The result is identical on 0.2.5.

**Fix:**
At the start of a new ready episode (claims.lua:188) also set s.unclaimed = 0. Alternatively, count a trip only while the episode that requested it is still on (s.ready_since and s.ready_since <= trip.t). RC4's fix removes the common trigger.

**Test:**
Joint host, rosie=true, dirs {'Batmobile','Rosie',SR}, place helltide:
1. claim_trip 1 min, Russian objective text.
2. The accept removes the quest with no bag item (RC4 unfixed), or a Rosie callback 'failed' after the quest is gone.
3. Make the reward ready again.
4. Expect a second 'claim trip requested' and no 'no more claim trips after 1'.

It fails on d425cf5.

## RC6: a blocked or skipped auto-fire leaves no trace in the log, so users see 'reward ready' and then nothing, and conclude that SilentRaven became manual.

**Confidence:** confirmed  
**Code:** d425cf5 SilentRaven/main.lua:
- Silent returns: :125, 127, 131, 132-133, 134, 135, 143.
- note_hold, :106-117: a debug line only when the reason changes (:111); an info line only after one continuous HOLD_LOG_S=60 s hold (:67, :113-116); the episode resets after a sampling gap over 1 s (:107).
- tracker.hold_reason is cleared only when auto-fire starts (:150).

Other places:
- claims.lua:193-203: in Temis it logs only 'latched' / 'managed_temis', never a hold.
- claims.lua:216-219: 'claimed on the next Temis visit' even when every visit is held.
- The hold appears only in get_status().hold_reason (external.lua:34) and D4Remote 'Waiting:' (main.lua:214-221).
- The menu has no status line (gui.lua:74+).

**Mechanism:**
Every Temis stop shorter than 60 s (a Worldstone stop is about 40 s) prints nothing at normal verbosity, whatever RC1 or RC2 hold applies. With Debug on, 'auto-fire held: X' prints once per session per distinct reason, so it is easily far above the excerpt a user sends.

**Evidence:**
test_zz_repro_raven_visibility.lua:
- V3/V4 (TristramLoop or Navigator hold, three 50 s Temis stops, Debug off): 4 SilentRaven lines in total, none naming the hold.
- V1 (one 150 s stop): a single line 'auto-fire waiting 61s: activity_owner:TristramLoop, town'.
- The Worldstone-loop repro: 5 lines, none with a hold reason.

**Fix:**
At the first held auto-fire of each Temis visit, log at info once per reason and ready episode, for example via claims' say('hold:'..reason): 'reward ready in Temis but auto-fire waits: <reason>'. Outside Temis, stop promising 'claimed on the next Temis visit' while the last visit was held.

**Test:**
Joint host, place temis, Debug off, TRISTRAM_LOOP_STATE owns_activity (or a Worldstone Navigator request once RC2 is fixed only for Butler), 30 s in Temis. Expect exactly one '[SilentRaven] reward ready in Temis but auto-fire waits: activity_owner:TristramLoop' line. It fails on d425cf5 (0 lines).

## RC7 (possible, older code): the automatic paths need snapshot.ready, but the keybind's START accepts 'present and not collecting'. A Whisper quest whose objective text cannot be read never auto-claims, yet the keybind works.

**Confidence:** possible  
**Code:** d425cf5:
- SilentRaven/main.lua:131: auto-fire needs tracker.ready.
- Rosie/rosie/private/town/tasks/teleport.lua:166: the hand-off needs s.ready.
- claims.lua:183-186: the claim trip needs snapshot.ready.
- fsm.lua:474-476: START only rejects 'not present' or 'collecting and not ready'.
- whispers.lua:120-163: ready needs an English hint or a read meta objective. Objectives with empty text are skipped at :135-136, so the has_progress/progress_ratio fallback in counter_state (:93-95) is never reached without text.
- The manual path never checks tracker.ready (main.lua:154-175).

**Mechanism:**
If the client returns a Bounty_Meta quest with no objective text (or text that is empty or unreadable), meta_read stays false, so ready and collecting are both false. Auto-fire, the hand-off and the claim trip never start, and Rosie's hand-off refuses silently (teleport.lua:166 returns nil with no reason). The keybind claims. This gives the same auto-no, manual-yes pattern as RC1, with no third-party addon.

**Evidence:**
test_zz_repro_raven_ready.lua Q1-Q3 (empty objectives, text '', no text with progress_ratio=1): ready=false; 'Whisper quest present, no objective text -> not ready'; no 'reward ready'; auto never fires in 60 s; the keybind claims.

Unchanged since 3.1.0, so it explains the report only if the S15 client stopped returning objective text. The reporter's log decides it.

**Fix:**
In quest_snapshot, evaluate counter_state(text or '', objective) for meta objectives even when the text is empty: has_progress with ratio >= 1 is complete. Treat a present meta quest with a readable objective list and no incomplete evidence as ready (inferred), which reuses the one-probe-per-visit bound in fsm.lua:501-508.

**Test:**
test_silentraven.lua harness: get_objectives returns {{text='', has_progress=true, progress_ratio=1}}. Expect c.api.get_status().ready == true and an auto-fire run in Temis (auto_fire_toggle on). It fails on d425cf5 (ready=false).

## Refuted

- Rosie's `_rosie` Scavenger stand-in as a cause of 'manual now'. Its is_busy is true only within 1 s of a Rosie pickup step (Rosie/rosie/private/scavenger_mimic.lua:46, 97-106). In autofire A7/A12, with the stand-in published, auto-fire happens at +0.1 s on 0.2.6. It only adds short blips (feeding RC3 under Worldstone), and before an accept it cancels a WarPigs-bridged request (wp_silent_raven.lua:179). Both are already fixed on the release branch in ca32b17 (SilentRaven 0.2.7 coordination.lua:273-277, WarPigs 1.1.8 wp_silent_raven.lua:179-184), not yet released: ship them in 3.3.6.
- RUN_TIMEOUT 100 -> 90 s (fsm.lua:14; v3.3.2 fsm.lua:12) is not the screenshot's cause. That run ended at the API_CLAIMING 8 s receipt timeout (receipt_unconfirmed, fsm.lua:461-463), not at run_timeout (fsm.lua:427-428), and reaching run_timeout needs an accept at 82 s or later. Minor side note: README.md:23 still says 100 s.
- finish_external latching the visit after an accept (fsm.lua:77-80) applies only after an accept, and the latch clears on the next zone change (tracker.lua:124-130). It does not stop auto-fire across visits.
- An 'unconfirmed' result disabling later auto-fire: the latch is per visit (fsm.lua:56; tracker.lua:124-130), and the quest is gone anyway. The keybind ignores the latch (main.lua:154-175).
- The 2 Hz auto-fire throttle (main.lua:131-133): the first sample passes (nil -> -math.huge), and 0.5 s is shorter than the 1 s / 2 s hold windows (main.lua:107, coordination.lua:35). in_whisper_town is exactly zone=='Skov_Temis' (whispers.lua:68), so the reordered checks behave the same.
- WarPigs loaded but off, or a stuck managed_by / reserved_by_war_pigs: WarPigs status then gives enabled / manages_whispers false (WarPigs/core/external.lua:16, 22-23), and a managed SilentRaven would log 'manual trigger ignored' (main.lua:159-160), not 'manual trigger fired'. can_start runs on the keybind too (main.lua:163).
- WarPug busy, Alfred live work, a busy Looter, or Butler/Scavenger/Navigator busy as the thing blocking auto-fire at the screenshot moment: the keybind runs the same checks (coordination.lua:308-310) and fired. Only auto-only gates (activity_owner, war_pigs_busy, Alfred hard need <= 60 s), a latched visit, auto_fire off or ready=false fit that moment.
- 'Idle-but-busy Navigator / stuck Butler forever' as a separate cause: the missing bound is real, but the trigger is unverified (field meanings are not documented, docs/THIRD_PARTY_APIS.md:21-24). It is folded into RC2's bound.
- The other 3.3.3+ diffs: get_status().yielding (external.lua:37) is additive; WarPigs 1.1.7 alfred_idle=nil while off is never read by SilentRaven; the claim-trip counting change (claims.lua:143-159) allows more trips, not fewer; Rosie 1.0.21/22 teleport.lua changes touch only the outbound cast, not raven_plugin/raven_handoff (teleport.lua:162-218).
- The '[WarPug] Reroll captured' line mid-run is WarPug's own capture keybind (WarPug/gui.lua:185-188) and is unrelated to the claim.

## Ask the reporter

Попросить у репортёра (Debug у него уже включён):
1) Какие аддоны загружены: Worldstone, Navigator, Butler, Scavenger, TristramLoop, WarPigs (включён ли, «Manage Whispers»), какой фарм-плагин. Хватит строк загрузки из начала лога.
2) Весь лог SilentRaven до нажатия клавиши. Эти строки печатаются один раз на смену причины и могут быть сильно выше скриншота:
   - '[SilentRaven] auto-fire held: …' и 'auto-fire waiting …s: …';
   - 'Whisper quest … -> ready / ready (inferred…) / not ready' и 'reward ready…';
   - 'reward ready but skipped because this Temis visit is already handled…' и 'reward ready: claim trip waits because …';
   - предыдущие 'run finished: …' в том же визите в Темис;
   - строки Rosie '[Rosie] waiting for SilentRaven…' и '[Rosie] no SilentRaven hand-off: …'.
3) Настройки SilentRaven: включён ли Auto-fire, сколько стоит в Claim trip (min). Статус SilentRaven в D4Remote, если есть ('Waiting: …').
4) После выбора награды: появился ли кэш в сумке и в какой вкладке (снаряжение / расходники / ключи / камни). Какой слот выбран, была ли сумка полной.
5) Если стоит Worldstone/TristramLoop: сколько секунд персонаж стоит в Темисе между забегами. Остаётся ли включённым TristramLoop, когда цикл остановлен.

Живые проверки после фикса: 'run finished: success (…quest_turned_in…)' вместо 'unconfirmed'; авто-клейм в Темисе при работающем Worldstone и TristramLoop; при пропущенном авто-клейме видна одна строка с причиной.
