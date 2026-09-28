# QQT review board

Shared by all QQT sessions (see CLAUDE.md). Newest entries go at the top of each section.
Format: `- [date] [session] text (branch@sha, files, tests)`.

## Requests between sessions
- [2026-09-28] [Coordinator → Rosie] Rosie cannot cast Town Portal while the third-party **Navigator** (driven by Worldstone) keeps moving the player. The Navigator interrupts the cast, the trip ends `teleport_failed`, and Rosie cannot pause it. Waiting for the owner's `[ApiProbe]` log of what **Butler** (a Navigator-aware Rosie-like addon) sends to Navigator. Then implement the same in Rosie's `lifecycle.hold_peers` / `release_peers`, with a joint-host regression test using a fake Navigator.

## Ready for review
- [2026-09-28] [Activities] Rosie 3.3.2 fight-hold check + unbounded waits: Reaper 1.10.4 (`loot_ready` 30 → 75 s, outlasts the 45 s fight hold; flapping busy no longer re-arms the bound), HordeDev 2.2.5 (`loot_guard.ready` same flap fix), ArkhamAsylum 2.1.3 (forced exit: Alfred hold capped at 120 s). `test_integration_reaper.lua` RPR-6 bound updated 30 → 75. (claude/qqt-activities, Reaper/core/utils.lua, HordeDev/core/loot_guard.lua, ArkhamAsylum/core/task_manager.lua, versions.json; tests: test_activities_fight_hold_332.lua A1-A5, test_activities_bounds_v3.lua L1-L3, A1/L1-L3 fail on the old code). Coordinator: README rows (Arkham 2.1.3, HordeDev 2.2.5, Reaper 1.10.4), CHANGELOG, VERSION.

## Auditor / critic findings
(none open)

## Released
- 3.3.2: Rosie 1.0.20 (no back and forth: fight hold, yield to other movers, obols); HelltideRevamped 2.6.1 (no idle at a dead Pandemonium rupture); WarRoom 1.0.2.
- 3.3.1: Rosie 1.0.19 (a full bag never waits forever; wait reasons logged).
