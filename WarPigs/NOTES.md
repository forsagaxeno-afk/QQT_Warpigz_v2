# WarPigs + WarPug: session notes (WarPigs 1.1.6, WarPug 1.0.15)

WarPigs is the orchestrator: it runs a War Plan (Pit, Helltide, Undercity, Hordes, bosses, Whispers) by driving the activity plugins through their APIs, and it calls Rosie for town trips. WarPug is the War Plan creator (planner).

- `WarPigs/core/orchestrator.lua`: step machine; `core/external.lua`: the API, plus `WarPigsPlugin.peek()` (side-effect free, used by WarRoom).
- Event bus: step_start / step_done are edges (`emitted_matches`), so they are not repeated per tick.
- Joint tests: `audit/tests/test_joint_suite.lua`, `test_integration_warpug.lua`, `test_warpug.lua`, `test_activity_lease_joint.lua`.

## Open
- Nothing open from live reports right now.
