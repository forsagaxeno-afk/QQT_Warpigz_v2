# Interaction matrix (Auditor, 2026-09-28, release 3e9d0ed)

This matrix lists, for each pair of plugins, the contract between them, the tests that cover it, and the gaps. It was built from the full module review; the findings themselves are in `audit/BOARD.md` under "Full module review". Contract names (C1…C6, lease, Whisper yield) are defined in `AUDIT.md`, and the third-party APIs in `docs/THIRD_PARTY_APIS.md`.
Gaps marked **(F)** have a finding on the BOARD.

## Rosie ↔ farm plugins

| Pair | Contract | Tests | Gaps |
|---|---|---|---|
| Rosie ↔ HelltideRevamped | C1: Alfred status, `trigger_tasks_with_teleport`, stuck/refusal latch; Looter busy via `loot_guard` (15 s in the Helltide, 20 s in search); Q2: a tear pauses pickup | test_integration_helltide, test_joint_rosie, test_helltide_tears_joint, test_rosie_back_forth_332 | refusal without `stuck` loops forever (F); busy during the fight hold (F); stale `helltide_seen_at` after a trip (F); death with a pending need (F) |
| Rosie ↔ ArkhamAsylum | C1/C2 (`alfred_trip`, `in_run`), `looter_hold` 15 s, exit waits for `is_looting` | test_integration_arkham(_batmobile), test_joint_rosie, test_rosie_back_forth_332, test_secondpass_dungeons | trip during a live boss (F); exit wait bounded only by the 600 s timer (F); busy during the fight hold (F) |
| Rosie ↔ WonderCity | C1/C2, loot hold 12 s, reward-phase exit | test_integration_wondercity, test_wondercity_bounds, test_r5_advisory_joint | trip during a live boss (F); exit wait with no own bound (F) |
| Rosie ↔ Reaper | C1 (Alfred hold), RPR-6 loot guard (3 s of quiet, cap 30 s; 75 s in 1.10.4) | test_integration_reaper, test_reaper_bounds, test_activities_fight_hold_332 (unmerged) | the finishing teleport skips the Alfred hold (F); Rosie's yield rest reads as idle (F) |
| Rosie ↔ HordeDev | C1, loot guard, `acquire_pause`/`release_pause` for pylons (25 s bound) | test_horde_audit, test_horde_feedback, test_integration_horde | yield rest reads as idle (F); `bound_pause` skipped after an Execute error (F) |
| Rosie ↔ Batmobile | `hold_peers`: pause/stop_long_path during a trip; `peer_drives_movement` = unpaused and `get_owner()` | test_joint_rosie R4, test_joint_suite | a mid-trip resume is never re-paused, and a foreign pause is resumed at trip end (F); stale `get_owner()` (F) |
| Rosie ↔ SilentRaven | `raven_handoff` on the return leg; Raven's claim trip via `trigger_tasks_with_teleport` | test_silentraven_q8, test_silentraven_q8_bounds, test_silentraven_standalone | Rosie cancel after RAVEN_WAIT = no event or latch (F); the claim trip ignores TristramLoop, Butler and Navigator (F) |
| Rosie ↔ WarPigs/WarPug | C1 gate, via-Temis preamble, turn-in | test_integration_warpigs_town, test_secondpass_town, test_r5_advisory_joint | preamble loop after a cancelled or failed trip (F); WarPug ignores `stuck` (F) |

## Batmobile ↔ consumers

| Pair | Contract | Tests | Gaps |
|---|---|---|---|
| Batmobile ↔ HelltideRevamped | C3 `release`, pause/set_target/move under `helltide_revamped`, reset per session, `is_giving_up` trap recovery | test_integration_helltide (C3, HLT-3/5/9), test_helltide_search_cycle | stale search state after the helltide task takes over (F); respawn wipe after a native walk (F) |
| Batmobile ↔ ArkhamAsylum | C3, `set_target`, traversal routing, kill_boss moves | test_integration_arkham_batmobile, test_batmobile_nav_recovery | STUCK/evade spam at a boss (F); traversal limbo 3-5 u (F); cross_traversal over kill_boss (F) |
| Batmobile ↔ HordeDev | C3 via `core/movement.lua`, set-once waypoint | test_horde_audit, test_joint_suite | respawn wipe after the stage-3 re-teleport (F) |
| Batmobile ↔ Reaper | `navigation_owner`, C3 | test_integration_reaper, test_integration_batmobile | none found |
| Batmobile ↔ WonderCity | long paths in Kurast and the Undercity | test_integration_wondercity, test_live_wondercity_teleports | `walk_kurast` long paths during a Raven claim (F) |
| Batmobile ↔ Looter (freeroam) | yields to `is_actively_looting` 10 s, then drives 5 s | test_integration_batmobile | none found |
| Batmobile ↔ any caller | pause is one shared flag; `stop_long_path`/`clear_target`/`reset` are not owner-scoped | test_integration_batmobile (release, R11) | per-caller pause missing (F) |

## WarPigs ↔ plugins

| Pair | Contract | Tests | Gaps |
|---|---|---|---|
| WarPigs ↔ activities (Arkham, WonderCity, HordeDev, Reaper, HR) | enable/disable, C2 status fields, C6 holds, user pause, advisory policy, War Plan Horde | test_integration_warpigs_dispatch, test_joint_suite, test_warpigs_user_pause, test_warpigs_joint_r4, test_warplan_horde_*, test_horde_warplan_r5 | a reload while owned (HR Warplan mode lost) (F); one-tick quest flicker disables HR (F, uncertain) |
| WarPigs ↔ WarPug | `busy` handshake, planner hold | test_warpug, test_integration_warpug | WarPug holds with no bound on a stuck Rosie (F); WarPug reload mid-selection |
| WarPigs ↔ SilentRaven | bridge guard `yield:<reason>`, `manages_whispers`, `whisper_handoff`, `activity_on` | test_warpigs_whispers, test_warpigs_raven_yield, test_silentraven_q8 | yield pause not published to farm plugins (F) |
| WarPigs ↔ WarRoom | `peek()` is read-only | test_warroom_joint | `status()` has side effects; every plugin calls it every pulse (F) |
| WarPigs ↔ activity lease | WarPigs on = no lease | test_activity_lease_joint | none found |

## SilentRaven and WarRoom

| Pair | Contract | Tests | Gaps |
|---|---|---|---|
| SilentRaven ↔ Arkham/HR/Reaper/WonderCity | `raven_claim_active()` holds Temis steps (100 s run, 120 s pause) | test_silentraven_standalone S2-S5, test_joint_suite | WonderCity `walk_kurast` has no hold (F); yield-paused request still holds (F) |
| WarRoom ↔ all | owns the bus; `qqt_events.lua` byte-identical copies; `_G.QQT_WarRoom` | test_qqt_events_bus, test_qqt_events_joint, test_warroom_collector, test_warroom_joint | bus test hard-codes 10 copies (F); `enabled` stays true after a collector error (F) |
| WarRoom ↔ HelltideRevamped | HR writes `hr_data.js` into `dashboard_dir` | test_helltide_dashboard | see the `enabled` flag above |

## Third-party (closed `.pak`) ↔ suite

| Pair | Contract (observed) | Tests | Gaps |
|---|---|---|---|
| Navigator/Worldstone ↔ Rosie town | Worldstone waits on `AlfredTheButlerPlugin.get_status()`; Rosie 1.0.21: `set_pause_condition`, `stop()` before the cast, stillness wait | test_rosie_foreign_mover (unmerged 1.0.21) | pause condition inherits every unbounded busy state; `returned` stays true while idle (F) |
| Rosie pickup ↔ Worldstone/Navigator | none in 1.0.21 (Worldstone waits on `Scavenger.is_busy()`, seen). Rosie 1.0.22 (in progress): Scavenger mimic plus the `"Rosie Looting"` pause condition | test_rosie_scavenger_mimic (1.0.22) | Rosie yields drops to Navigator moves, so drops are lost; a yielded drop stays blocked in reach; YIELD blind spot (F) |
| Butler ↔ WarPigs | hold teleports while `Butler.is_busy()` | none | WarPigs does not read it (F, LOW) |
| Scavenger | **not in the owner's setup** (enabled only to observe Worldstone); Rosie 1.0.22 publishes a mimic when no real one exists | test_rosie_scavenger_mimic | a real Scavenger is still yielded to, and the mimic must never be treated as a foreign looter |
| Butler ↔ SilentRaven | none today | none | auto-fire during a Butler trip (F, HIGH) |
| Butler ↔ Rosie | only one town service at a time | none | Rosie does not check `Butler.is_busy()` before a trip |
| TristramLoop ↔ Rosie | `owns_activity` / `controls_loot` / `phase=='revive'` | test_rosie_bag_waits_331, test_rosie_contract | revive phase has no bound (F); start-log spam (F) |
| TristramLoop ↔ SilentRaven | none | none | the claim trip ignores `owns_activity` (F) |

## Coverage gaps across the suite
- No joint test loads a fake Navigator, Butler or Worldstone next to WarPigs, SilentRaven or a farm plugin. Only Rosie 1.0.21 has one.
- No test covers a plugin reload while another plugin owns it (HR under WarPigs), or a reload mid-fight (Reaper).
- No test covers death with a pending town need, or a stuck revive phase.
- There is no pending-loot contract. Every exit guard infers "loot left" from `is_actively_looting`, which is false during Rosie's fight hold (1.0.20 reports busy there instead, and that has its own cost) and during yield rests.
