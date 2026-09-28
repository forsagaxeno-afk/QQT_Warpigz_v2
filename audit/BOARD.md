# QQT review board

Shared by all QQT sessions (see CLAUDE.md). Newest entries go at the top of each section.
Format: `- [date] [session] text (branch@sha, files, tests)`.

## Requests between sessions
- [2026-09-28] [Coordinator → Rosie] Rosie cannot cast Town Portal while the third-party **Navigator** (driven by Worldstone) keeps moving the player. The Navigator interrupts the cast, the trip ends `teleport_failed`, and Rosie cannot pause it. Waiting for the owner's `[ApiProbe]` log of what **Butler** (a Navigator-aware Rosie-like addon) sends to Navigator. Then implement the same in Rosie's `lifecycle.hold_peers` / `release_peers`, with a joint-host regression test using a fake Navigator.

## Ready for review
(none)

## Auditor / critic findings
(none open)

## Released
- 3.3.2: Rosie 1.0.20 (no back and forth: fight hold, yield to other movers, obols); HelltideRevamped 2.6.1 (no idle at a dead Pandemonium rupture); WarRoom 1.0.2.
- 3.3.1: Rosie 1.0.19 (a full bag never waits forever; wait reasons logged).
