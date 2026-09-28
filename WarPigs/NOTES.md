# WarPigs + WarPug: session notes (WarPigs 1.1.7, WarPug 1.0.15)

WarPigs is the orchestrator: it runs a War Plan (Pit, Helltide, Undercity, Hordes, bosses, Whispers) by driving the activity plugins through their APIs, and it calls Rosie for town trips. WarPug is the War Plan creator (planner).

- `WarPigs/core/orchestrator.lua`: step machine; `core/external.lua`: the API, plus `WarPigsPlugin.peek()` (side-effect free, used by WarRoom).
- Event bus: step_start / step_done are edges (`emitted_matches`), so they are not repeated per tick.
- Joint tests: `audit/tests/test_joint_suite.lua`, `test_integration_warpug.lua`, `test_warpug.lua`, `test_activity_lease_joint.lua`.
- Hang/loop regressions: `audit/tests/test_warpigs_hang_review.lua` (H1–H4).

## 1.1.7 hang/loop self-review (2026-09-28)
Fixed (each with a test that fails on 1.1.6):
- H1/H2 Temis preamble: one Alfred budget per Temis visit (`alfred_gate.VISIT_BUDGET` = 180 s, from the first busy reading with something incoming; reset on leaving Temis / release_all). Before: a hard need a cycle cannot clear (stash full, provider without `stuck`) held the IDLE gate forever and re-triggered Alfred every ~10 s; a latched live flag bounced TEMIS_ALFRED <-> POST_ALFRED_SETTLE with a fresh 180 s each time. After the budget the kick stops, the Alfred step is skipped and the settle does not bounce; the companion gate (another 180 s max for live work) still applies.
- H3 turn-in task: its own Alfred live-work yield is bounded (`LIVE_WORK_HOLD` 180 s per episode).
- H4 SilentRaven bridge: an unreadable SilentRaven status during an owned request ends the request after `LIMIT.run` (60 s), best-effort cancel, no second submit in the visit. Before: tick() returned early on every pulse forever.

Reviewed, no change:
- A plugin whose `disable_when` never becomes true keeps the handoff (loot-safe by design; disabling WarPigs is the stop path). Pit/Undercity town releases and Reaper holds are already bounded.
- Rosie trip mid-step: every gate reads C1 live work through bounded holds (companion_hold 180 s, stuck 150 s, paused 180 s).
- TO_TEMIS retries the waypoint every 30 s without a cap (a retry, not a stall; companion/chest holds pause it).
- War Plan rotation: turn-in edge re-arms the teleport (R6); a pending teleport without incoming keeps the Whisper slot/WarPug open (WPT-2).
- Reload mid-step: state is rebuilt; a running wanted plugin is adopted, an unwanted one goes through disable_when; a SilentRaven request of the old instance is waited for via `traffic_hold` (bounded by SilentRaven) and admission (`wait_live`).

## Open
- Live checks for 1.1.7: a Temis visit with a full stash (Rosie cannot empty the bag) must leave for the next activity after ~3 min, log `Alfred budget of this Temis visit spent` once.
