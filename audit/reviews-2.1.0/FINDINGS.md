# QQT_Warpigz_v2 v2.1.0 — integration review findings

Generated from the structured results of the multi-agent review (10 domain reviewers, 1 auditor, 1 critic per round). Round 1 reviewed, rounds 2–5 fixed and re-audited. Severity is the auditor's final severity; "Round 2 audit" is the fix auditor's verdict on the fix. Later rounds closed the items the round-2 auditor/critic still flagged (tables below).

## Round 1 findings (94) and their resolution

| ID | Severity | Verdict | Title | Resolution |
| --- | --- | --- | --- | --- |
| WPG-1 | critical | CONFIRMED | table.unpack (Lua 5.2+) in WarPug's path search makes every planning attempt HALT on a LuaJIT/5.1 host | Fixed in round 1 hotfix (80e7c03, LuaJIT) |
| WPG-2 | critical | CONFIRMED | WarPigs orchestrator.tick exceeds the host's 60-upvalue limit, so WarPigs fails to load and WarPugPlugin loses its dispatcher | Fixed in round 1 hotfix (80e7c03, LuaJIT) |
| ARK-1 | high | CONFIRMED | Ordinary task switch calls alfred.on_cancel(), erasing the need_trigger stickiness grace -> endless Alfred re-trigger loop (never enters pit | Fixed (round 2, arkham) |
| HLT-1 | high | CONFIRMED | Sticky Alfred need_trigger/restock re-triggers a full Alfred town trip every ~13s; helltide.lua bypasses alfred.lua's STUCK_NEED_TRIGGER_GRA | Fixed (round 2); advisory trips inside a helltide removed in round 3 (R12) |
| HLT-2 | high | DUPLICATE → WPT-1 | Legacy Alfred: is_inventory_full treats a latched status.teleport (teleport_done=true) as 'inventory full', so Alfred is re-triggered foreve | Fixed (round 2, helltide) |
| HRD-1 | high | CONFIRMED | Latched open_chests FAULT (no handler) makes chests_done() permanently false, and WarPigs waits forever: suite-wide halt | Fixed (round 2, warpigs_dispatch) |
| HRD-4 | high | DUPLICATE → HRD-1 | Latched RESET/sigil/entry transactions: no revive while pending, permanent FAULT after timeout, and neither the GUI toggle nor WarPigs can c | Fixed (round 2, horde) |
| SRV-1 | high | DUPLICATE → WPT-2 | WarPug is starved forever: WarPigs.is_busy() blocks the planner until the Whisper check runs, but the check never runs while teleport_pendin | Fixed with WPT-2 |
| WCY-1 | high | DUPLICATE → ARK-1 | Alfred restock-stickiness escape is erased by on_cancel on every task switch, so a sticky need_trigger livelocks WonderCity in town | Fixed (round 2, wondercity) |
| WCY-2 | high | CONFIRMED | Default tribute settings (Skip tribute off, all priorities 0) or exhausted tributes make entry wait at the brazier forever; WarPigs has no w | Fixed (round 2, wondercity) |
| WPG-3 | high | DUPLICATE → WPT-2 | Deadlock: a pending teleport with no incoming quest closes the Whisper slot, while blocks_plan_creator() keeps WarPigs 'busy' for WarPug for | Fixed with WPT-2 |
| WPG-4 | high | DUPLICATE → WPT-3 | WarPigs triggers Alfred in Temis during an active WarPug session, and WarPug turns it into a permanent HALT that stops the whole loop | Fixed (round 2, warpug) |
| WPG-5 | high | DUPLICATE → WPT-1 | WarPug's Alfred busy check differs from every other consumer: it ignores 'pending' and treats a finished 'teleport' cycle as busy forever | Fixed (round 2, warpug) |
| WPT-1 | high | CONFIRMED | WarPigs treats Alfred's leftover `teleport` flag (set after trigger_tasks_with_teleport) as live work, so every town handoff livelocks | Fixed (round 2, warpigs_town) |
| WPT-2 | high | CONFIRMED | Deadlock: the SilentRaven bridge marks WarPigs busy for WarPug, but the Whisper check that would clear it cannot run while a teleport is pen | Fixed (round 2, warpigs_town) |
| WPT-3 | high | CONFIRMED | WarPigs' 20 s Alfred grace is exported as `alfred_idle` and WarPug checks it on every tick; when it expires WarPigs re-triggers Alfred and W | Fixed (round 2, warpigs_town) |
| ARK-2 | medium | DUPLICATE → WPD-4 | WarPigs in_town_disable_when fires during Arkham's own return_for_loot Alfred round trip; Arkham is disabled and Alfred returns the player i | Fixed (round 2, warpigs_dispatch) |
| ARK-3 | medium | CONFIRMED | Re-entering the same pit after an Alfred trip is classified as a new 'run': reset_timeout deadline restarts, boss/glyph floor state and Batm | Fixed (round 2); explorer-map restore completed in round 3 (R10) |
| ARK-4 | medium | CONFIRMED | alfred task (priority 6) preempts the pending glyph upgrade: upgrade_glyph yields while Looteer loots, alfred does not | Fixed (round 2, arkham) |
| ARK-5 | medium | CONFIRMED | Handoff to a busy/unknown Alfred and release_control() skip utils.stop_movement(); Arkham's Batmobile long path stays armed and is re-driven | Fixed (round 2, arkham) |
| BAT-1 | medium | CONFIRMED | Trap detector runs while a paused consumer holds a custom target: false trapped/giving_up makes HR abandon the zone mid-Maiden/pyre/rift, an | Fixed (round 2); its paused-route regression fixed in round 3 (R9) |
| BAT-2 | medium | CONFIRMED | Non-Jump traversal interact loop has no timeout: if no traversal buff arrives, the navigator freezes (target nil, last_trav set) forever and | Fixed (round 2, batmobile) |
| BAT-9 | medium | DUPLICATE → ARK-5 | No owner is ever checked: tracker.external_caller is write-only, and pause/resume/stop act for anyone, so releases are guesswork (Reaper nev | Fixed (round 2, batmobile) |
| HLT-3 | medium | CONFIRMED | Batmobile giving-up recovery fires one teleport and parks in BACK_TO_TOWN; an interrupted channel stalls HR in the trap, and salvage queues  | Fixed (round 2, helltide) |
| HLT-7 | medium | NEEDS_LIVE_CHECK | search_helltide undoes WarPigs' arrival whenever the landing is outside the buff area; Skovos (Skov_*) helltides are unreachable except via  | Fixed (round 2, helltide) |
| HRD-5 | medium | NEEDS_LIVE_CHECK | walking_to_horde (and in Cerrigar, town_salvage) take over in Alfred's town after the HordeDev-triggered salvage callback and teleport away  | Fixed (round 2, horde) |
| RPR-2 | medium | CONFIRMED | WarPigs cannot turn off a Reaper it did not start through run_once: disable_when waits for a callback that never registers, and pending_disa | Fixed (round 2, warpigs_dispatch) |
| RPR-3 | medium | CONFIRMED | Reaper's Alfred yield loops when need_trigger stays stuck: every run_once clears the 30 s grace, and the legacy restock branch has no grace  | Fixed (round 2, reaper) |
| RPR-5 | medium | DUPLICATE → ARK-5 | navigation_owner.release drops Reaper's claim but skips stopping Reaper's own Batmobile long path whenever Alfred looks busy, paused or unkn | Fixed (round 2, reaper) |
| RPR-6 | medium | CONFIRMED | Reaper never coordinates with Looteer: town teleport fires about 3 s after the chest despawns while the looter is still picking up items | Fixed (round 2, reaper) |
| RPR-7 | medium | DUPLICATE → WPD-6 | Failure is never reported to the orchestrator: no callback on failure, status.failed is cleared by stop(), and WarPigs re-enables a failing  | Fixed (round 2, warpigs_dispatch) |
| SRV-2 | medium | CONFIRMED | Whisper is skipped for the whole Temis visit when Alfred or Looter is busy more than 20 s; WarPigs itself kicks Alfred right before the admi | Fixed (round 2, warpigs_town) |
| SRV-3 | medium | NEEDS_LIVE_CHECK | Reward claim hard-gates on quest_reward return conventions that were never verified against the host: select()==true, same-frame selected_in | Fixed (round 2, silentraven) |
| SRV-4 | medium | CONFIRMED | Unmanaged SilentRaven autofire has no WarPug/Alfred/Looter admission check and permanently HALTs an in-progress WarPug session | Fixed (round 2, warpug) |
| WCY-3 | medium | DUPLICATE → WPD-1 | WarPigs releases WonderCity in Kurast while the Alfred cycle WonderCity just started is live, then teleports to Temis mid-cycle | Fixed (round 2, warpigs_dispatch) |
| WCY-4 | medium | DUPLICATE → WPD-2 | When WarPigs starts or resumes mid-Undercity with WonderCity off, the via-Temis preamble teleports the player out before the Undercity arriv | Fixed (round 2, warpigs_dispatch) |
| WCY-5 | medium | DUPLICATE → ARK-5 | Temis long-path navigation keeps driving the player when a foreign Alfred cycle takes over, and survives WonderCity disable | Fixed (round 2, wondercity) |
| WPD-1 | medium | CONFIRMED | Teleport to Temis fires while Alfred (or Looter) is working outside Temis; WarPigs itself starts Alfred, then teleports mid-cycle | Fixed (round 2, warpigs_dispatch) |
| WPD-2 | medium | CONFIRMED | Horde 'has_aether' teleport hold waits for a HordeDev that WarPigs has disabled and will not re-enable: permanent stall after a WarPigs off/ | Fixed (round 2, warpigs_dispatch) |
| WPD-3 | medium | NEEDS_LIVE_CHECK | InfernalHordes enable_gate requires a BSK world, but HordeDev's entry flow starts outside BSK: endless Temis → Alfred → warplan teleport loo | Fixed (round 2, warpigs_dispatch) |
| WPD-4 | medium | CONFIRMED | Pit/Undercity released by in_town_disable_when during an Alfred with-teleport round trip; the run and floor loot are abandoned | Fixed (round 2, warpigs_dispatch) |
| WPD-6 | medium | CONFIRMED | Reaper run_once refusal/failure signals ignored: failed runs re-dispatched indefinitely, 'busy' refusals retried every tick | Fixed (round 2, warpigs_dispatch) |
| WPT-4 | medium | DUPLICATE → WPD-1 | The via-Temis step teleports away from an Alfred cycle running in another town; WarPigs even triggers Alfred there itself and teleports away | Fixed with WPD-1 |
| WPT-7 | medium | DUPLICATE → SRV-4 | When WarPigs does not manage Whispers, SilentRaven auto-fire (on by default) starts in Temis with no check on WarPug, Alfred or WarPigs' act | Fixed (round 2, silentraven) |
| ARK-7 | low | CONFIRMED | enable() cannot yield enabled status when 'Use keybind' is on with no bound key; WarPigs retries forever with Arkham idle (and enable overri | Fixed (round 2, arkham) |
| ARK-8 | low | DUPLICATE → BAT-11 | Arkham's Batmobile explorer priority leaks to later plugins (set_priority is never restored on release) | Fixed (round 2, batmobile) |
| ARK-9 | low | DUPLICATE → WCY-6 | Unreadable/malformed Alfred status pins Arkham in a no-op alfred task, above the reset-timeout 'hard override' | Fixed (round 2, arkham) |
| BAT-10 | low | NEEDS_LIVE_CHECK | External update/move bypass Batmobile's own loading guard, and explorer permanently caches cells as non-walkable, so a scan during load or s | Fixed (round 2, batmobile) |
| BAT-11 | low | CONFIRMED | The explorer priority set by one plugin carries over to the next consumer, and reset() does not restore the default | Fixed (round 2, batmobile) |
| BAT-3 | low | CONFIRMED | The standard release (stop_long_path + clear_target + pause) leaves traversal-routing state: the next task's or plugin's set_target returns  | Fixed (round 2, batmobile) |
| BAT-4 | low | CONFIRMED | Paused-mode unstuck() replaces the caller's custom target with an explorer frontier and writes explorer.visited; consumers that set a waypoi | Fixed (round 2, batmobile) |
| BAT-5 | low | CONFIRMED | navigate_long_path secretly unpauses, and long-path completion is detected only while unpaused: paused callers never see is_long_path_naviga | Fixed (round 2, batmobile) |
| BAT-6 | low | CONFIRMED | clear_traversal_blacklist() does not lift the 60 s global traversal block that any custom target sets, so every consumer's traversal recover | Fixed (round 2, batmobile) |
| BAT-7 | low | CONFIRMED | Explorer and trap state cross world boundaries (reset() only): HR entered by WarPigs inherits a full 4000-frontier table, and trav_history r | Fixed (round 2, batmobile) |
| BAT-8 | low | CONFIRMED | resume()+set_target() (HR patrol_move/navigate_to): Batmobile silently swaps the caller's waypoint for explorer targets and never arms faile | Fixed (round 2, batmobile) |
| HLT-4 | low | CONFIRMED | Minute 55-59 idle: search_helltide fires its own town teleport and requests salvage in the same tick, so Alfred's with-teleport trip starts  | Fixed (round 2, helltide) |
| HLT-5 | low | DUPLICATE → BAT-7 | HR never resets Batmobile exploration when WarPigs drops the player directly into a helltide, so stale state from the previous activity driv | Fixed (round 2, batmobile) |
| HLT-6 | low | DUPLICATE → WPD-7 | When HR is disabled it does not restore the orbwalker clear toggle its cinder gate forced OFF, so the next activity may run with clear disab | Fixed (round 2, warpigs_dispatch) |
| HLT-8 | low | CONFIRMED | search_helltide and the give-up path teleport without checking Looteer ownership (loot_guard is consulted only inside the helltide task) | Fixed (round 2, helltide) |
| HLT-9 | low | CONFIRMED | MOVING_TO_TRAVERSAL relies on Batmobile self-routing but never clears the patrol custom target, so the traversal usually times out and is bl | Fixed (round 2, helltide) |
| HRD-10 | low | NEEDS_LIVE_CHECK | Teleport-mode exit re-fires teleport_to_waypoint(Library) after 5.0s while WarPigs/turn-in assume a ~5s channel and use 6s debounces; the Wa | Fixed (round 2, horde) |
| HRD-2 | low | NEEDS_LIVE_CHECK | get_aether_count is optional everywhere except open_chests completion: without it the chest phase never finishes | No change: the live log shows the host exposes get_aether_count (critic dispute) |
| HRD-6 | low | DUPLICATE → WCY-6 | HordeDev Alfred task blocks the entire queue (waves, chests, exit) when Alfred's status is unreadable, even with use_alfred=false | Fixed (round 2, horde) |
| HRD-7 | low | CONFIRMED | status().enabled reports only main_toggle, not the keybind state that gates execution (Arkham, WonderCity and WarPigs include it) | Fixed (round 2, horde) |
| HRD-8 | low | CONFIRMED | Built-in salvage path re-fires teleport_to_waypoint about 0.1s after the first call, then every 5s (self-cancelling channel per the suite's  | Fixed (round 2, horde) |
| HRD-9 | low | CONFIRMED | run_pit calls PitPlugin, which no plugin in the suite provides (Arkham exports ArkhamAsylumPlugin) | Fixed (round 2, horde) |
| RPR-10 | low | DUPLICATE → WPD-7 | Orbwalker handoff fight: WarPigs forces clear ON just before run_once, and run_once's reset immediately forces it OFF; Reaper also leaves it | Fixed (round 2, warpigs_dispatch) |
| RPR-11 | low | CONFIRMED | Periodic dungeon reset never runs under WarPigs: each run_once resets its baseline, and the finishing path preempts the task | Fixed (round 2, reaper) |
| RPR-4 | low | DUPLICATE → WPD-5 | Paused or unreadable Alfred makes Reaper yield forever (even with 'Use Alfred' off), while WarPigs and other plugins treat the same state as | Fixed (round 2, reaper) |
| RPR-8 | low | CONFIRMED | WarPigs Belial one-shot with the shipped default belial_chest_enabled=false: Ritual of Lies dialog is never confirmed, husks are spent and t | Fixed (round 2, reaper) |
| SRV-5 | low | CONFIRMED | ESC is sent when no reward panel is open (panel-timeout retry, and a clean cancel after accept), which in D4 opens the game menu for every p | Fixed (round 2, silentraven) |
| SRV-6 | low | CONFIRMED | The GUI and D4Remote payload re-require a non-shipped file on every render frame and every second | Fixed (round 2, silentraven) |
| SRV-8 | low | CONFIRMED | D4Remote contract drift: record_loot is documented as sent per claim but never called; register only runs at load | Fixed (round 2, silentraven) |
| WCY-6 | low | CONFIRMED | An unreadable Alfred status freezes WonderCity everywhere, including the forced run-timeout exit | Fixed (round 2, wondercity) |
| WCY-7 | low | CONFIRMED | WarPigs' in-town disable ignores entry already under way (tribute used, portal accepted, portal being entered) | Fixed (round 2, warpigs_dispatch) |
| WCY-8 | low | DUPLICATE → BAT-11 | WonderCity leaves Batmobile's explorer priority set to 'distance' for the plugins that run after it | Fixed (round 2, batmobile) |
| WCY-9 | low | NEEDS_LIVE_CHECK | WonderCity ignores Alfred's completion result, while WarPigs treats failed/cancelled as not completed | Fixed (round 2, wondercity) |
| WPD-5 | low | CONFIRMED | Turn-in task treats any paused Alfred as busy forever, while the orchestrator treats a foreign pause as idle; the turn-in match also clears  | Fixed (round 2, warpigs_town) |
| WPD-7 | low | CONFIRMED | Reaper's release path turns orbwalker clear OFF, the opposite of Arkham/WonderCity release; WarPigs only restores it when its own manage_orb | Fixed (round 2, warpigs_dispatch) |
| WPD-8 | low | CONFIRMED | Helltide off-window hold exists only on the Alfred path; without Alfred, warplan teleports into minutes 55-59 and retries every 6 s | Fixed (round 2, warpigs_dispatch) |
| WPG-6 | low | CONFIRMED | positions.txt ships with the author's calibration and reroll_set/confirm_set=true, so blind native clicks fire on a fresh install | Fixed (round 2, warpug) |
| WPG-7 | low | CONFIRMED | The first activity of every plan WarPug creates starts without the native warplan transition | Fixed in round 3 (R6: native transition after the turn-in) |
| WPG-9 | low | CONFIRMED | Capture/test keybinds use toggle mode but are never reset, so every second press is ignored and a restored toggle state may capture at load | Fixed (round 2, warpug) |
| WPT-5 | low | DUPLICATE → WPD-5 | A paused Alfred is handled inconsistently: the turn-in task blocks on any pause, and the orchestrator's pre-teleport gate blocks on paused-w | Fixed with WPD-5 |
| WPT-6 | low | CONFIRMED | warplan.teleport_to_activity() is called without pcall and the TELEPORTING retry loop has no limit | Fixed (round 2, warpigs_dispatch) |
| ARK-10 | none | REFUTED | Persisted slider key 'upgrade_threshold' is not plugin-prefixed | No change (refuted) |
| ARK-6 | none | REFUTED | Choron's Soul is scheduled before upgrade_glyph and consumes all upgrade chances, contradicting the GUI contract 'consume remaining glyph up | No change (refuted) |
| HRD-3 | none | REFUTED | open_chests requires boolean need_trigger for the legacy PLUGIN_alfred_the_butler status, which utils.is_inventory_full (and Reaper) treat a | No change (refuted) |
| RPR-1 | none | REFUTED | WarPigs one-shot run has no key check and no altar failure path: out of keys means an endless interact loop and a permanent WarPigs hold | No change (refuted) |
| RPR-12 | none | REFUTED | Host APIs used only by Reaper (teleport_to_boss_dungeon, get_gametime) have no availability guard, and a missing function stalls silently in | No change (refuted) |
| RPR-9 | none | REFUTED | Death mid-fight clears altar_activated, the only 'live fight' guard, so Alfred (and dungeon_reset) can pull the player out after the key is  | No change (refuted) |
| SRV-7 | none | REFUTED | The pause lease is silently dropped whenever a run finishes (reset_run clears paused/paused_by), contrary to the documented owner-checked pa | No change (refuted) |
| WCY-10 | none | REFUTED | Dead tribute-sorting code and settings: sort_tribute.lua reads settings that no longer exist; the 'sort_button' click point is configurable  | No change (refuted) |
| WPG-8 | none | REFUTED | WarPigs' master stop (toggle or keybind) does not stop WarPug, which keeps walking, clicking and confirming | No change (refuted) |

## Critic gaps (round 1)

| ID | Severity | Title | Resolution |
| --- | --- | --- | --- |
| CRT-1 | high | WonderCity never confirms a reward chest that is already opened or stays flagged interactable; the exit waits for reset_timeout (600 s, restarted by a | Fixed (round 2, wondercity) |
| CRT-2 | high | WarPigs never releases a HordeDev that is on but not at the end of a horde (toggle persisted across a restart, manual enable, quest gone before entry) | Fixed (round 2, warpigs_dispatch) |
| CRT-3 | high | SilentRaven accepts a reward card only when entry.valid == true (and sno is a number), while its own scoring treats a missing 'valid' as usable; manag | Fixed (round 2, silentraven) |
| CRT-4 | medium | The HelltideRevamped chest 'no progress' timer keeps running while HR yields to Looteer, so reachable Tortured Gift chests are blacklisted the moment  | Fixed (round 2, helltide) |
| CRT-5 | medium | WarPug can confirm plans containing activities WarPigs cannot run (only Nightmare Dungeons are blocked; 9 boss quest names are guesses). An unmapped W | Fixed (round 2, warpigs_dispatch) |
| CRT-6 | low | The turn-in task always waits 20 s outside a town before teleporting, even when WarPigs knows no activity plugin is on or exiting; this adds 20-25 s o | Fixed (round 2, warpigs_dispatch) |

## Round 3–5 items (closing auditor/critic residuals and the War Plan Horde feature)

| Round | ID | Summary | Audit |
| --- | --- | --- | --- |
| 3 | R1 | Every companion hold is now bounded per gate. dispatch.companion_hold(now, gate) keeps a separate episode for each gate: 'idle', 'to_temis', 'settle', 'teleporting' and 'task'. An episode resets only when its own gate ha | VERIFIED |
| 3 | R2 | WPD-3 now counts an enable_gate denial only when a warplan TELEPORTING confirmed or released to IDLE since the last enable attempt (dispatch.delivered). The flag is set on confirm, on the retry-cap release, on the warpla | VERIFIED |
| 3 | R3 | The Reaper disable_when now lets the C2 fields decide. complete, external_run == false or in_run == false: release. in_run == true on a run WarPigs did not start (adopted after a reload, or a manual run of the same boss) | VERIFIED |
| 3 | R4 | A Reaper run_once refused over and over (e.g. 'belial_chest_disabled', or 'busy' while the user runs Reaper by hand) is now visible. dispatch.status_suffix shows 'Reaper refused <boss>: <reason> (retrying every 30s)' rig | VERIFIED |
| 3 | R5 | The IDLE Whisper slot now closes whenever an activity or task quest is incoming, whether or not a teleport is pending. With 'Use teleport' off none ever is. The bridge's admission wait (up to 120 s) therefore no longer r | VERIFIED |
| 3 | R6 | WPG-7: on the TurnIn matched->unmatched edge, with settings.use_teleport_transition on, teleport_pending is armed (logged 'teleport queued — turn-in finished (next plan)'). The first activity of the next plan now gets th | VERIFIED |
| 3 | R7 | When a faulted HordeDev reports status().exit_pending == true (the new C2 field the horde fixer adds), the fault grace is HORDE_EXIT_GRACE = 180 s: its 120 s Looter hold plus the Leave/Reset time. The extension is logged | VERIFIED |
| 3 | R8 | When enable() does not produce an enabled status (e.g. HordeDev with 'Use keybind' on and no key bound), plugin_enable records dispatch.unconfirmed[plugin] and retries only every ENABLE_RETRY (30 s). Nothing runs in betw | VERIFIED |
| 3 | R15 | This is the bridge side of live L7. During a Looter burst before accept, the continuation guard now answers (false, 'yield:looter_busy'). 'Before accept' means the request is queued, or running in any state other than AP | VERIFIED |
| 3 | R9 | Paused trap sampling is no longer keyed on `paused` alone. navigator.move samples and runs attempt_escape when unpaused, or when navigator.paused_trap_active(player) is true. That function first requires the caller's goa | VERIFIED |
| 3 | R10 | When navigator.observe_world resets on a world change or teleport, it first keeps a by-reference snapshot of the explorer map it is leaving: visited, frontier tables, retry, backtrack, scanned and frontier chunks, via th | VERIFIED |
| 3 | R11 | External move and resume from a different caller no longer drop the current owner's goal or route. note_foreign() only logs '[batmobile] <move\|resume> by X: goal of Y kept (replaced only by a new goal claim or its relea | VERIFIED |
| 3 | R12 | HLT-1 completed. In HelltideRevamped-0.4/tasks/alfred.lua, decide() no longer starts an advisory-only with-teleport trip while utils.is_in_helltide(). Advisory-only means need_trigger with inventory_full and need_repair  | VERIFIED |
| 3 | R13 | C4/L12b. HelltideRevamped-0.4/core/settings.lua now keeps a file-local orb_forced = {clear, block}, like WonderCity's orb_forced. orb_set_clear, apply_cinder_orb_gate and force_orb_clear_for record whether HR left clear  | VERIFIED |
| 3 | R14 | goto_chest's locked_wait no longer records a never-clicked, non-interactable reward chest as opened after 10 s just because some boss_kill_time exists, or after 30 s blind. It now completes after 10 s only with positive  | VERIFIED |
| 3 | R7 | HordeDev now publishes the C2 field status().exit_pending. It is true while HordeDev is enabled and its own exit is actively in progress: the Leave Dungeon/RESET transaction; a Teleport exit whose channel has not left th | VERIFIED |
| 3 | R8 | This mirrors Arkham's ARK-7. enable() sets a runtime-only settings.external_control flag (no GUI control, never persisted). With it set, utils.get_keybind_state() passes when 'Use keybind' is on and no key is bound (0x0A | VERIFIED |
| 3 | C1-deviation (HordeDev paused-Alfred holds) | HordeDev's own WAITING request and its needs_salvage hold now share one 60 s bound on a paused Alfred (PAUSED_HOLD_MAX, the same value Arkham, WonderCity and HR use). The window starts only while HordeDev wants Alfred (W | VERIFIED |
| 3 | R15 | SilentRaven side of the continuation-guard pause (live L7). Only an explicit `false` answer whose reason starts with 'yield:' pauses a request. Every other false answer, and any guard error, cancels as before.  While pau | VERIFIED |
| 3 | R10-joint | Added a joint regression that loads the REAL Batmobile plugin (main.lua, gui, settings, navigator, explorer, pathfinder, long_path, external) next to the REAL ArkhamAsylum plugin. Each plugin has its own module cache and | VERIFIED |
| 3 | R10-return-hold | Arkham-side gap found with the joint test. Alfred's with-teleport callback can arrive in town before its return portal (the order is not verified live, HRD-5). In that window alfred.is_busy() was already false, so Arkham | VERIFIED |
| 3 | R10-back-portal | Second Arkham-side gap. portal.reset() cleared the back-portal blacklist on the 'outside' transition, so resuming a floor that was reached through a portal treated it as 'entered not via portal'. When the Alfred return p | VERIFIED |
| 4 | F-H1 | Added War Plan entry mode to HordeDev. InfernalHordesPlugin.enable(opts) selects 'warplan' when opts.entry == 'warplan'; any other call, including enable() with no argument or a colon call, selects 'compass', which is th | VERIFIED |
| 4 | F-H2 | If HordeDev is active, WarPigsPlugin.status().enabled == true and nothing has called InfernalHordesPlugin.enable() this session (a persisted-on or manual toggle), HordeDev now waits up to 5 s for WarPigs to decide before | VERIFIED |
| 4 | F-H3 | keep_run_on_enable(mode) now keeps a run only where the run actually is: transaction_pending(), HordeDev's own Alfred trip, or the player in S05_BSK_Prototype02. It never keeps a finished War Plan run, and never keeps a  | VERIFIED |
| 4 | F-H4 | start_dungeon's activity-start Alfred trip (no compass at the gate) no longer starts for an advisory-only flag when WarPigs is enabled and reports alfred_idle == true. An advisory-only flag is need_trigger/restock withou | VERIFIED |
| 4 | F-W1 | New settings in WarPigs: horde_warplan_entry (default ON, GUI 'Hordes: enter via War Plan teleport (no compass)') and horde_compass_fallback (default OFF, GUI 'Allow compass entry if the War Plan teleport fails', shown o | VERIFIED |
| 4 | F-W2 | alfred_trigger_now joins, and does not re-trigger, any completed WarPigs Alfred cycle triggered in this Temis visit by the same Alfred (last_alfred_completion_at >= visit_trigger_at), whatever its age, unless inventory_f | VERIFIED |
| 4 | F-W3 | Whisper bridge: after accept (post_accept: claim_sent, or API_CLAIMING), any companion reason answers (false, 'yield:<reason>'). A Looter burst keeps 'yield:looter_busy'. tick() no longer cancels in that state, so Silent | VERIFIED |
| 4 | F-W4 | plugin_enable, R8 cooldown branch: when is_plugin_on(plugin) becomes true during the 30 s cooldown, WarPigs adopts it at once without calling enable() again. It sets owned, clears enable_blocked, unconfirmed and gate_den | VERIFIED |
| 4 | F-W5 | The 'deferring enable of X — <gate>' dedup key strips the ' (N.Ns left)' countdown with a string method, which adds no upvalue. The post-disable cooldown line now prints once per episode instead of every tick. | VERIFIED |
| 4 | F-C1 | WonderCity now reads WarPigs the same way ArkhamAsylum does. A new local warpigs_advisory_idle() in WonderCity-main/tasks/alfred.lua is a verbatim copy of Arkham's: it returns true only when WarPigsPlugin.status() is cal | VERIFIED |
| 5 | W5-1 | New dispatch.hwe_retag(), called from hwe_run_finished for a HordeDev that WarPigs owns (so it runs every tick in the disable phase, including the cold-start adoption tick). It fires when War Plan entry is on, the player | VERIFIED |
| 5 | W5-2 | (a) hwe_run_finished, for a War Plan HordeDev that WarPigs owns outside the Horde, now has three cases. With last_result 'completed' and no alfred_trip or exit_pending, it releases after HORDE_DONE_SETTLE (3 s) and logs  | VERIFIED |
| 5 | W5-3 | hwe_missed records the landing world and zone and sets landing_bsk when either name contains 'bsk' (any case). After 3 misses the compass fallback engages only when the last landing is outside the BSK family. A BSK landi | VERIFIED |
| 5 | W5-4 | New dispatch.user_paused(plugin, running, now) runs every tick for each owned plugin before the self-disable reconcile. An owned plugin whose status reports enabled == false while C2 in_run == true (HordeDev in the Horde | VERIFIED |
| 5 | H5-1 | I checked the lead's completion_evidence() gate (all evidence needs tracker.horde_idle_since ~= nil). It handles a Stash visible from arrival, the door approach, the Council pylon, the fight, and the War Plan objective v | VERIFIED |
| 5 | H5-2 | F-H2's 5 s wait now counts only loaded-world time. main.lua waiting_for_warpigs() adds time between two consecutive pulses only when both saw a world WarPigs can decide in: player position set, world name not Limbo or lo | VERIFIED |
| 5 | H5-3 | keep_run_on_enable() also keeps HordeDev's own built-in Cerrigar salvage trip: own_salvage_trip(mode) = mode ~= 'warplan' and builtin_salvage_pending() and the player is in Scos_Cerrigar. builtin_salvage_pending() needs  | VERIFIED |
| 5 | H5-4 | New policy in HordeDev. While WarPigsPlugin is loaded and status().enabled == true, an advisory-only Alfred flag (need_trigger/restock/stash without inventory_full or need_repair) never starts a HordeDev Alfred trip. At  | VERIFIED |
| 5 | A5-1 | New policy in ArkhamAsylum and WonderCity. Each plugin's warpigs_advisory_idle() now returns true whenever WarPigsPlugin.status() is callable, returns a table and reports enabled == true (still read through pcall). It no | VERIFIED |
| 5 | A5-2 | I checked Reaper and HelltideRevamped against the policy at activity start in town, not only inside a lair or helltide. Reaper had a gap: evaluate() blocked advisory-only flags only by its own 30 s sticky grace and the b | VERIFIED |
| 5 | blocker 1 | Out of compasses at the gate: HordeDev asks Alfred to restock them again, also under WarPigs (fixed by the lead after the round-5 critic, b9da34f). | regression added |
| 5 | blocker 2 | War Plan HordeDev kept outside the Horde during Alfred work/teleport is bounded (180 s), logged and shown (b9da34f). | regression added |

## Joint-suite defects found and fixed

- Round 3, medium, fixed: WarPigs Whisper bridge cancelled a managed SilentRaven request after accept on a Looter burst: a claimed reward was reported 'cancelled', re-requested twice, and WarPug started ~11 s late
- Round 3, low, fixed: Via-Temis preamble started a second Alfred cycle right after the Temis kick's WarPigs cycle finished in the same visit
- Round 3, low, fixed: Arkham started its own advisory-only Alfred trip in Temis right after WarPigs had serviced the same sticky restock flag for the visit
- Round 3, low, fixed: test_secondpass_contracts.lua still asserted the pre-R15 cancel on a Looter burst (suite red before this task)
- Round 3, low, open (see limits): Sticky advisory restock flag still costs WonderCity/HordeDev one advisory Alfred trip per activity start in town
- Round 3, low, open (see limits): 'deferring enable of X — post-disable cooldown: … (N.Ns left)' is logged every WarPigs tick during the 5 s gap
- Round 4, low, fixed: HordeDev logs '[exit_horde] holding — player still has N aether' on every pulse from the first wave to the end of the chests (~456 lines per horde in the joint War Plan run), and says 'holding' even though the exit is no
- Round 4, low, open (see limits): Hotkey pause mid-horde with 'Use teleport' on and War Plan entry: WarPigs still treats the pause as a self-disable and leaves the horde via Temis; the War Plan teleport then lands in a new horde and HordeDev's R8/F-H3 ke
- Round 4, low, open (see limits): Sticky advisory restock flag: HordeDev in War Plan mode still makes its own Alfred trip from the chest room
- Round 5, medium, fixed: A QQT reload after the Council in a War Plan horde without a chest room leaves HordeDev stuck in the Horde forever, and the turn-in never runs
- Round 5, medium, fixed: Alfred's own teleport trip right after the Council (quest already swapped) made WarPigs release the War Plan HordeDev in Temis; after Alfred's portal back, the turn-in teleported out of BSK and the chests and Leave Dunge
