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
(none open)

## Released
- 3.3.2: Rosie 1.0.20 (no back and forth: fight hold, yield to other movers, obols); HelltideRevamped 2.6.1 (no idle at a dead Pandemonium rupture); WarRoom 1.0.2.
- 3.3.1: Rosie 1.0.19 (a full bag never waits forever; wait reasons logged).
