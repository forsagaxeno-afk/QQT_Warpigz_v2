# WarPigs + WarPug: session notes (WarPigs 1.1.9, WarPug 1.0.17)

WarPigs is the orchestrator: it runs a War Plan (Pit, Helltide, Undercity, Hordes, bosses, Whispers) by driving the activity plugins through their APIs, and it calls Rosie for town trips. WarPug is the War Plan creator (planner).

- `WarPigs/core/orchestrator.lua`: step machine; `core/external.lua`: the API, plus `WarPigsPlugin.peek()` (side-effect free; written for WarRoom, archived since 3.3.6).
- Event bus: step_start / step_done are edges (`emitted_matches`), so they are not repeated per tick.
- Joint tests: `audit/tests/test_joint_suite.lua`, `test_integration_warpug.lua`, `test_warpug.lua`, `test_activity_lease_joint.lua`.
- Hang/loop regressions: `audit/tests/test_warpigs_hang_review.lua` (H1–H8), `test_warpug_alfred_bounds.lua` (P1–P4); teleport casts: `test_warpigs_teleport_casts.lua` (C1–C3).

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
