# QQT review board

Shared by all QQT sessions (see CLAUDE.md). Newest entries go at the top of each section.
Format: `- [date] [session] text (branch@sha, files, tests)`.

## Requests between sessions
- [2026-09-28] [Orchestrator → Helltide] `test_integration_helltide.lua` case 'v3 trap recovery with the only active Helltide' failed once (line 909 `bounded skip: expected 1, got 0`, both runtimes, run in parallel with the other half of the suite) and passed on re-run with and without the WarPigs 1.1.7 change. Looks wall-clock dependent (HR reads `os.time()` / the real minute); please pin the clock in that test.
- [2026-09-28] [Coordinator → Rosie] Rosie cannot cast Town Portal while the third-party **Navigator** (driven by Worldstone) keeps moving the player. The Navigator interrupts the cast, the trip ends `teleport_failed`, and Rosie cannot pause it. Waiting for the owner's `[ApiProbe]` log of what **Butler** (a Navigator-aware Rosie-like addon) sends to Navigator. Then implement the same in Rosie's `lifecycle.hold_peers` / `release_peers`, with a joint-host regression test using a fake Navigator.

## Ready for review
- [2026-09-28] [Orchestrator] WarPigs 1.1.7: hang/loop self-review. Bounded Alfred budget per Temis visit (H1 unclearable hard need looped Alfred trips forever, H2 latched live flag bounced TEMIS_ALFRED/SETTLE forever), bounded turn-in Alfred yield (H3), bounded unreadable SilentRaven status in the Whisper bridge (H4). (claude/qqt-warpigs, WarPigs/core/orchestrator.lua, core/tasks/turn_in_rewards.lua, wp_silent_raven.lua, gui.lua, versions.json, README version cell only (check_release requires it); test_warpigs_hang_review.lua fails on 1.1.6; WarPigs/WarPug/joint suites green)

## Auditor / critic findings
(none open)

## Released
- 3.3.2: Rosie 1.0.20 (no back and forth: fight hold, yield to other movers, obols); HelltideRevamped 2.6.1 (no idle at a dead Pandemonium rupture); WarRoom 1.0.2.
- 3.3.1: Rosie 1.0.19 (a full bag never waits forever; wait reasons logged).
