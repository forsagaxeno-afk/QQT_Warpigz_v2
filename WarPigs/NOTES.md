# WarPigs + WarPug: session notes (WarPigs 1.1.13, WarPug 1.0.19)

WarPigs is the orchestrator: it runs a War Plan (Pit, Helltide, Undercity, Hordes, bosses, Whispers) by driving the activity plugins through their APIs, and it calls Rosie for town trips. WarPug is the War Plan creator (planner).

- `WarPigs/core/orchestrator.lua`: step machine; `core/external.lua`: the API, plus `WarPigsPlugin.peek()` (side-effect free; written for WarRoom, archived since 3.3.6).
- Event bus: step_start / step_done are edges (`emitted_matches`), so they are not repeated per tick.
- Joint tests: `audit/tests/test_joint_suite.lua`, `test_integration_warpug.lua`, `test_warpug.lua`, `test_activity_lease_joint.lua`.
- Hang/loop regressions: `audit/tests/test_warpigs_hang_review.lua` (H1–H8), `test_warpug_alfred_bounds.lua` (P1–P4); teleport casts: `test_warpigs_teleport_casts.lua` (C1–C3); Tyrael turn-in: `test_warpigs_turnin_tyrael.lua` (Y1–Y6).

## WarPug 1.0.19: stale "Existing selection preserved" (2026-09-30, owner live report on 1.0.17)
WarPug halted with "Existing selection preserved; clear it manually before retrying" without any manual selection; toggling WarPug fixed it at once (so the board read was stale, not a user path). 1.0.18 is taken by the owner's private branch (claude/qqt-owner-betteralfred), hence 1.0.19.
- FIND_PATH: a board path equal to this session's `owned_path` is ours: fewer than the required picks → continue picking; complete → confirm; full length but not yet reported complete → re-read. A shorter path (a user edit while paused, WPG-4) or anything else is foreign.
- A foreign read is logged with node ids/names and our path (`Board holds a selection that is not ours (read n/3): [...]`), then the table is re-opened after 3 s (RECHECK_WAIT → APPROACH_TABLE), up to 3 reads; only then the halt. A real user selection is never cleared or confirmed.
- A foreign-selection halt retries itself after 60 s, at most 3 times per enable (logged).
- Tests: `test_warpug_selection.lua` S1–S3 (fail on 1.0.17).
Live check: the next "Existing selection preserved" comes with 3 `not ours (read n/3)` lines that name the nodes on the board.

## 1.1.13 Rosie's Butler stand-in (2026-09-29)
Rosie publishes `_G.Butler` with `_rosie=true` while Worldstone runs and no real Butler is loaded; its is_busy mirrors Rosie's own trip. The SilentRaven bridge (`wp_silent_raven.lua` companions_clear) read `Butler.is_busy()` without the `_rosie` skip, so a Rosie trip held/cancelled the Whisper request as `butler_busy`. Now skipped, like the Scavenger stand-in (1.1.8). Already skipping: `dispatch.third_party_busy` (orchestrator companion_hold) and WarPug `third_party_busy`; confirmed by tests (H9, P5).

## 1.1.12 pre-Torment Horde map (2026-09-29, owner live log 3.3.9..3.3.14)
The War Plan Horde teleport lands in world=S10_BSK_Pretorment zone=S10_BSK_Pretorment. `dispatch.inside_horde()` (the one place every Horde decision uses: landing, arrived_when, in-place/adoption, W5-2/W5-3, run_finished) knew only S05_BSK_Prototype02, so it logged "landed in a BSK zone HordeDev does not know", re-teleported 3x from inside and never started HordeDev.
- `dispatch.is_horde_zone(zone)`: `InfernalHordesPlugin.is_horde_zone(zone)` when HordeDev publishes it (boolean answer, pcall), else `dispatch.HORDE_ZONES` = {S05_BSK_Prototype02, S10_BSK_Pretorment}. WarPug has no zone constant.
- Tests: `test_warplan_horde_warpigs.lua` P1–P3 (fail on 1.1.11).
Live check: War Plan Horde → `landed world=S10_BSK_Pretorment zone=S10_BSK_Pretorment, inside the Horde`, HordeDev enabled in War Plan mode, no re-teleport.

## 1.1.11 post-release review of 1.1.10 (2026-09-29)
- Y3 [MED] TurnIn as the only WarPlans quest: WarPug cannot plan, so during the 600 s suspension the pit filler runs (when `run_pit_after_turnin` is on; WarPug on or off). Status line: `turn-in suspended (Tyrael not found), retry in Ns`; `peek().turn_in_suspended_s`. With the filler off nothing runs meanwhile (logged).
- Y4 the one-shot re-teleport is no longer cut: no not-found walk within TELEPORT_DEBOUNCE_S of our Temis cast or while 186139 channels (≤15 s).
- Y5 `hunt.TYRAEL` (2574,-484) is **UNVERIFIED live** (joint_host; test_live_temis_wall has 2570,-500). The turn-in logs `Tyrael at (x, y), player at (x, y)` once when he is found: take the real value from the owner's next log.
- Y6 the 60 s / 180 s bounds count only ticks actually hunting (gaps > 2 s: Alfred/Looter/SilentRaven holds, our cast).

## 1.1.10 turn-in: Tyrael not in the actor list (2026-09-28, live 3.3.5)
Live: `[WarPigs:turn_in] NPC not found … Looking for: NPC_QST_X2_Tyrael_NonCombat` every 4 s for 800+ s, the bot stood in Temis. APPROACH_NPC returned without moving.
- The turn-in walks toward Tyrael's known position (`hunt.TYRAEL` 2574,-484, via the Temis wall route) so he streams in; after 60 s without him it re-teleports to Temis once; after 180 s it gives the turn-in up for 600 s (`M.suspended`). The orchestrator treats a suspended task quest as not matched (`dispatch.task_suspended`), so the next War Plan step runs; the suspension is not a completed turn-in (no pit-filler arm, no R6 re-arm). Retried after 600 s.
- 'NPC not found' logged once per episode; the candidate dump at most every 30 s (was 4 s).
Live check: a turn-in where Tyrael is out of range walks toward the War Plan table and interacts; if he never appears, one re-teleport, then `giving the turn-in up for 600s; WarPigs continues`.

## 1.1.9 Undercity teleport storm (2026-09-28, audit/reviews/undercity_teleports_2026-09-28.md)
Fixed (each with a test that fails on 1.1.8):
- C1 TELEPORTING: no War Plan retry while our own 186139 cast channels (`dispatch.own_cast_hold`, bounded by HORDE_CAST_CAP 15 s, logged once per call). Landing = world/zone change, world_id change, or a finished cast with a position jump ≥ `LANDING_JUMP` 30 (`dispatch.landing_snapshot` / `landing_seen`). A same-zone Temis landing is covered by world_id / position jump (no WonderCity-town lookup needed).
- C2 TO_TEMIS: no waypoint re-fire while our cast channels (15 s); helltide-lingering fast retries capped at `LINGER_FAST_MAX` 8 per TO_TEMIS (logged `fast retry n/8`), then the 30 s timeout cadence.
- C3 TELEPORTING observes the place every tick, so a Rosie hop back between the 6 s samples is seen as the landing.
Live check: Undercity War Plan with Use teleport on → one `warplan.teleport_to_activity() called`, `teleport confirmed (…)`, no `teleport retry` lines.

## 1.1.7 hang/loop self-review (2026-09-28)
Fixed (each with a test that fails on 1.1.6):
- H1/H2 Temis preamble: one Alfred budget per Temis visit (`alfred_gate.VISIT_BUDGET` = 180 s of busy time: consecutive busy readings with something incoming; idle time is not counted (H5, Auditor); reset on leaving Temis / release_all). Before: a hard need a cycle cannot clear (stash full, provider without `stuck`) held the IDLE gate forever and re-triggered Alfred every ~10 s; a latched live flag bounced TEMIS_ALFRED <-> POST_ALFRED_SETTLE with a fresh 180 s each time. After the budget the kick stops, the Alfred step is skipped and the settle does not bounce; the companion gate (another 180 s max for live work) still applies.
- H3 turn-in task: its own Alfred live-work yield is bounded (`LIVE_WORK_HOLD` 180 s per episode).
- H4 SilentRaven bridge: an unreadable SilentRaven status during an owned request ends the request after `LIMIT.run` (60 s), best-effort cancel, no second submit in the visit. Before: tick() returned early on every pulse forever.

Auditor review of 1.1.7 (fixed, same PR):
- H5 budget counts busy time only (was wall time since the first busy reading).
- H6 third-party `Scavenger.is_busy()` / `Butler.is_busy()` (guarded, pcall): hold every WarPigs outgoing teleport via `companion_hold` (Scavenger 30 s, Butler 180 s, `dispatch.THIRD_PARTY`) and the Whisper bridge admission (`scavenger_busy` / `butler_busy`, bounded by `wait_live`). The turn-in's teleports use the same `ctx.hold`.
- H7 an owned plugin whose `_G` export changes (QQT reload) gets `mark_adopted` again (HR War Plan mode), `dispatch.watch_export`.
- H8 `WarPigsPlugin.status()` runs `alfred_idle()` only while WarPigs is on (`alfred_idle` = nil when off).
- WarPug 1.0.16: `alfred_hold` honours `stuck` (no retry window: not waited on; with `stuck_retry_in`: ≤150 s) and bounds hard work without live work (≤180 s); a busy Scavenger / Butler holds a new session (≤180 s per episode).
- Not done: Helltide entry `disable_when` debounce (LOW, uncertain): the tick already returns on an unreadable quest list and in Limbo/loading; no repro of a readable empty snapshot yet.

Reviewed, no change:
- A plugin whose `disable_when` never becomes true keeps the handoff (loot-safe by design; disabling WarPigs is the stop path). Pit/Undercity town releases and Reaper holds are already bounded.
- Rosie trip mid-step: every gate reads C1 live work through bounded holds (companion_hold 180 s, stuck 150 s, paused 180 s).
- TO_TEMIS retries the waypoint every 30 s without a cap (a retry, not a stall; companion/chest holds pause it).
- War Plan rotation: turn-in edge re-arms the teleport (R6); a pending teleport without incoming keeps the Whisper slot/WarPug open (WPT-2).
- Reload mid-step: state is rebuilt; a running wanted plugin is adopted, an unwanted one goes through disable_when; a SilentRaven request of the old instance is waited for via `traffic_hold` (bounded by SilentRaven) and admission (`wait_live`).

## Open
- Live checks for 1.1.7 / WarPug 1.0.16: (1) a Temis visit with a full stash (Rosie cannot empty the bag) leaves for the next activity after ~3 min busy, logs `Alfred budget of this Temis visit spent` once; (2) with Butler/Scavenger installed, an activity end waits for their busy flag before the waypoint; (3) WarPug plans with Rosie latched `stuck` (stash full).
