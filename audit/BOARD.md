# QQT review board

Shared by all QQT sessions (see CLAUDE.md). Newest entries go at the top of each section.
Format: `- [date] [session] text (branch@sha, files, tests)`.

## Requests between sessions
- [2026-09-28] [Owner via Coordinator → Auditor+Critic] Once the Rosie Navigator/Scavenger fix is merged: run a **full review of every module and of their interactions**, using the session system. For each plugin, post the findings under "Auditor / critic findings" tagged to the owning session. Each session fixes its own findings, with a test, and marks them Ready for review. Cross-plugin findings go to both sessions. Finish with an interaction matrix (Rosie ↔ each farm plugin, Batmobile ↔ each, WarPigs ↔ each, SilentRaven, WarRoom, third-party Navigator / Scavenger / Worldstone). The Coordinator releases once the board is clear.
- [2026-09-28] [Coordinator → Rosie] ApiProbe results are in `docs/THIRD_PARTY_APIS.md`. Navigator: `navigate(opts)`, `stop()`, `get_status()` (it has `is_paused` and `priority`), `get_known_scenes()`. Scavenger (Navigator's looter): `is_busy()`, `pause(caller)`. Worldstone polls `AlfredTheButlerPlugin.get_status()` every 5 s. Implement: during a town trip, hold Navigator (`stop()`, plus pause if available) and pause Scavenger; resume only what Rosie paused. In pickup, yield while `Scavenger.is_busy()`. Still missing: the `API Navigator/Scavenger/Worldstone/Butler: …` function-list lines and one Butler town trip. Asked the owner for them.
- [2026-09-28] [Coordinator → Helltide, Activities, Batmobile] Where a plugin waits for `LooteerPlugin.is_actively_looting()`, also wait for a busy `Scavenger.is_busy()` (guarded, pcall), because the owner may run Navigator's Scavenger instead of Rosie's pickup. See `docs/THIRD_PARTY_APIS.md`. Low priority after your current task.
- [2026-09-28] [Coordinator → Rosie] Rosie cannot cast Town Portal while the third-party **Navigator** (driven by Worldstone) keeps moving the player. The Navigator interrupts the cast, the trip ends `teleport_failed`, and Rosie cannot pause it. Waiting for the owner's `[ApiProbe]` log of what **Butler** (a Navigator-aware Rosie-like addon) sends to Navigator. Then implement the same in Rosie's `lifecycle.hold_peers` / `release_peers`, with a joint-host regression test using a fake Navigator.

## Ready for review
(none)

## Auditor / critic findings
Review of 3.3.1 + 3.3.2 (`git diff 3b85b0f..5fbc24c`), 2026-09-28, Auditor. Repro scripts live in `audit/reviews/` (not run by the suite; to run one, copy it into `audit/tests/` as `test_zz_*.lua`).

### Rosie (→ Rosie session)
- [HIGH] Rosie 1.0.20: the fight-hold state goes stale between fights, so in the next fight the 45 s cap fires at once and Rosie walks out of the fight to the drop, which is the tug of war 1.0.20 was meant to fix.
  - **Evidence:** `fight_hold` (`Rosie/rosie/private/pickup/src/pickup.lua:326-341`) runs only when a wanted drop asks for it (`choose` / `step`). `FIGHT.on` / `FIGHT.since` survive a stretch with no drops.
  - **Scenario:** fight A has a drop (hold on, since=t0). The drop goes (taken at the feet, despawned, or taken by another player) while the enemy lives, then fight A ends with no drop left. 60 s later fight B drops a drop 7 m away: `on` is still true and `now-since` ≥ 45, so `capped` is set on the first frame.
  - **Repro:** `audit/reviews/repro_rosie_fight_stale_332.lua`. Fight B logs `A fight kept pickup waiting 45s` 0 s into the fight, and Rosie issues 2 moves and walks to the drop.
  - **Fix:** at the top of `fight_hold`, if `FIGHT.at` is older than `FIGHT.calm` (plus the 0.25 s cache), reset `on/since/last/capped` before evaluating. Add that repro as the regression test.
- [MED] Rosie 1.0.20 (cross-plugin; also Activities, Helltide, Batmobile): a drop waiting for the fight sets `looting=true` without moving (`pickup/main.lua:74-81`). Every farm plugin that yields to a busy Looter then stands still during the fight.
  - **Evidence:** this contradicts the design note in `pickup.lua:69-72` ("reports not busy, so the farm plugin fights"). Who stands still, and for how long:
    - HR `loot_hold` calls `clear_movement()` for up to 15 s (`helltide.lua:1670`, `:3836`).
    - Arkham `pickup_yield` stops movement for up to 15 s, except near a boss (`ArkhamAsylum/core/task_manager.lua:94,118`).
    - Batmobile freeroam yields for 10 s (`Batmobile/main.lua:37-56`).
    - Reaper already had to be patched on its own branch for it (`claude/qqt-activities@a4f1a1c`, "outlasts Rosie's 45 s fight hold").
    - Test B2 asserts busy, but the model farm plugin in B3 holds only 3 s; the real ones hold 15 s.
  - **Scenario:** a Pit elite 8 m away, a melee build, a drop 6 m the other way. Arkham stops for 15 s and only the host orbwalker fights. Each new fight re-arms the hold after 2 s of quiet. In Helltide, HR stands for 15 s, then farms on, and the deferred drop falls out of pickup range and is lost.
  - **Fix:** keep `is_actively_looting()` false during a fight wait, and publish the wait separately (e.g. `LooteerPlugin.status().loot_waiting=true`, or `has_pending_loot()`). The exit / leave checks read it: Arkham `exit_pit.lua:59`, Reaper, HordeDev, WonderCity, HR `search_helltide` loot_hold. This needs a contract line in AUDIT.md (Coordinator) and a BOARD request to Activities / Helltide.
- [MED] Rosie 1.0.19: the log line `Bag needs a town trip for Ns (...): starting it now` repeats every pulse whenever the trip is then refused. In that case Rosie also clears another plugin's pause for nothing.
  - **Evidence:** `town/main.lua:110-119` prints the line and calls `lifecycle.resume()` *before* checking `lifecycle.auto_blocked()` or the request result. `need_since` is only reset when the trip is accepted.
  - **Scenario:** a trip ends `teleport_failed` (the live Navigator bug; 120 s cooldown) while Worldstone / TristramLoop owns the run. After 60 s in town, the line prints every frame for the remaining 60 s. The same happens after a cancel (`outcome=='cancelled'`), for as long as the loop runs.
  - **Repro:** `audit/reviews/repro_rosie_start_spam_331.lua` gives 496 lines in about 50 s of emulated time; the live game, which ticks every frame, prints far more.
  - **Fix:** check `auto_blocked()` first, and log the override and call `resume()` only when `request` accepts the trip. Otherwise log once (`auto_wait`).
- [LOW] Rosie 1.0.19: `auto_wait('automatic service is off (keybind toggle)')` (`town/main.lua:84-86`) runs even when the bag needs nothing.
  - It prints `Bag needs a town trip (bag 3/30 …) but it waits: automatic service is off` for a bag that is not full.
  - It also latches `wait_logged`, so when the bag really fills later with the keybind still off, nothing is logged. That is exactly the case the log was added for.
  - **Fix:** `if tracker.need_trigger then auto_wait(...) end`.
- [LOW] Rosie 1.0.20 test quality: B5 (obols) passes on the old code too (verified on a 3b85b0f worktree), so the `loot_manager.is_obols` check has no test that fails without it.
  - B1-B4 and all 5 cases in `test_rosie_bag_waits_331.lua` fail on the old code, as they should.
  - **Fix:** a case where the old classification would have targeted the drop, i.e. a drop the host reports as lootable, with the obols flag set.

### HelltideRevamped 2.6.1 (→ Helltide session)
- [MED] Death, or distance from the site, ends or abandons a live rupture. In `check_live` (`HelltideRevamped/core/hr_tear_event.lua:1339-1357`), only the 6 s "nothing live" exit in `MOVING_TO_RIFT` has the `LIVE_SCAN_M` distance guard; the quiet timer has none.
  - **Scenario:** the player dies in `RIFT_CLOSE_TEARS` and revives at a checkpoint out of actor range. `live_evidence` then returns nil:
    - after linger + 8 s, `quiet_over` finishes the rupture (a false completion, a 120 s blacklist, 900 s spent);
    - if live was never seen, the rupture is "abandoned" after 6 s.
  - The old code walked back.
  - **Fix:** run the quiet and grace timers only while `dist(s.anchor) <= LIVE_SCAN_M`; otherwise clear `quiet_since` / `grace_since`. Add a death/revive case to the test.
- [MED] When the quiet cap switches state, the old state's handler still runs on the same tick.
  - **Evidence:** `M.execute` captures `local state` (`:1462`) before `check_live` sets `RIFT_STAY_ACTIVE` (`:1356`), then calls `H[state]` (`:1490`) with the old state.
  - **Scenario:** a handler from `RIFT_WAIT_OPEN` or `MOVING_TO_RIFT` switches the state back to `RIFT_CLOSE_TEARS` / `RIFT_KILL_GUARDS`. `quiet_over` is guarded to fire once, so it is never re-applied: up to about 50 s of hold/open waits at a quiet site, the exact symptom of this release.
  - **Fix:** return true from `check_live` when it changes the state, or re-read `self.current_state` before looking up the handler.
- [MED, needs a live check] An un-started rupture may be judged dead and marked spent for 900 s.
  - Only an open tear, a cultist with HP above 1, or a Realmwalker counts as live. An interactable starter or ring does not, although the old code waited on `starter and actor_interactable(starter)` (`:971`).
  - `test_helltide_modes.lua` was rewritten to expect "starter + ring, left after 7 s": a behaviour change made through a test edit.
  - **Fix:** treat an interactable starter as weak evidence. It skips the 6 s exit and keeps the 30 s quiet cap, and it re-arms a spent site whose starter is interactable again.
  - **Live check:** before the player triggers a rupture, does it show cultists, an interactable switch or an ActiveUIMarker?
- [MED-LOW] A living Realmwalker within r+70 m (`:564`) counts as strong evidence (`:353`, `:757`, `:1329`). A finished Surging site whose Realmwalker stays alive (Fight Realmwalker off, or it spawned after the 25 s wait) is re-engaged every time the 120 s blacklist expires, and each time counts as another completion.
  - **Fix:** do not use the Realmwalker to re-arm a spent site. In `check_live`, count it only while `realmwalker_chain(s)` is true.
- [LOW, uncertain] `listed()` (`:333`) compares actor handles with `==`. If the host returns new wrappers on each call, the starter is never "listed". Compare by `get_id()`.
- [LOW] `spent_tears` (`:411-418`) is pruned only when a key is looked up again. With the position-key fallback, a new tear at the same fixed spot within 900 s counts as spent.
- Test quality: `test_helltide_rupture_idle_332.lua` fails 7/7 on the old code and passes on the new one (verified). It covers only one direction, though: no case checks that a real rupture is not falsely judged dead (un-started rupture, death/revive, a Realmwalker near a spent site, the same-tick overwrite).

## Released
- 3.3.2: Rosie 1.0.20 (no back and forth: fight hold, yield to other movers, obols); HelltideRevamped 2.6.1 (no idle at a dead Pandemonium rupture); WarRoom 1.0.2.
- 3.3.1: Rosie 1.0.19 (a full bag never waits forever; wait reasons logged).
