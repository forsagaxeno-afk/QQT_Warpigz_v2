# QQT review board

Shared by all QQT sessions (see CLAUDE.md). Newest entries go at the top of each section.
Format: `- [date] [session] text (branch@sha, files, tests)`.

## Requests between sessions
- [2026-09-28] [Coordinator → Rosie] **Butler trip captured, full API lists in `docs/THIRD_PARTY_APIS.md`.** Butler does not pause Navigator: Worldstone stands still on its own while `Butler.is_busy()` is true. For Rosie, Worldstone reads only `AlfredTheButlerPlugin.get_status()`, and in the owner's log it never showed a trip (`trigger_tasks=false`). Implement: (1) during the whole trip, including the Town Portal cast, Rosie's Alfred status reports a trip in progress like the original Alfred (`trigger_tasks=true`, `returned` only at the end); (2) `Navigator.set_pause_condition("Rosie", fn)` with fn = trip in progress, plus `Navigator.stop()` before the cast when the owner is not Rosie; (3) `Scavenger.pause("Rosie")` / `resume("Rosie")`; (4) any in-town Navigator walk uses `owner="Rosie", priority=10`; (5) do not start a trip while `Butler.is_busy()`. All guarded + pcall. Joint-host test with fake Navigator/Scavenger/Worldstone poller. Supersedes the two older Rosie entries below.
- [2026-09-28] [Owner via Coordinator → Auditor+Critic] Once the Rosie Navigator/Scavenger fix is merged: run a **full review of every module and of their interactions**, using the session system. For each plugin, post the findings under "Auditor / critic findings" tagged to the owning session. Each session fixes its own findings, with a test, and marks them Ready for review. Cross-plugin findings go to both sessions. Finish with an interaction matrix (Rosie ↔ each farm plugin, Batmobile ↔ each, WarPigs ↔ each, SilentRaven, WarRoom, third-party Navigator / Scavenger / Worldstone). The Coordinator releases once the board is clear.
- [2026-09-28] [Coordinator → Rosie] ApiProbe results are in `docs/THIRD_PARTY_APIS.md`. Navigator: `navigate(opts)`, `stop()`, `get_status()` (it has `is_paused` and `priority`), `get_known_scenes()`. Scavenger (Navigator's looter): `is_busy()`, `pause(caller)`. Worldstone polls `AlfredTheButlerPlugin.get_status()` every 5 s. Implement: during a town trip, hold Navigator (`stop()`, plus pause if available) and pause Scavenger; resume only what Rosie paused. In pickup, yield while `Scavenger.is_busy()`. Still missing: the `API Navigator/Scavenger/Worldstone/Butler: …` function-list lines and one Butler town trip. Asked the owner for them.
- [2026-09-28] [Coordinator → Helltide, Activities, Batmobile] Where a plugin waits for `LooteerPlugin.is_actively_looting()`, also wait for a busy `Scavenger.is_busy()` (guarded, pcall), because the owner may run Navigator's Scavenger instead of Rosie's pickup. See `docs/THIRD_PARTY_APIS.md`. Low priority after your current task.
- [2026-09-28] [Coordinator → Rosie] Rosie cannot cast Town Portal while the third-party **Navigator** (driven by Worldstone) keeps moving the player. The Navigator interrupts the cast, the trip ends `teleport_failed`, and Rosie cannot pause it. Waiting for the owner's `[ApiProbe]` log of what **Butler** (a Navigator-aware Rosie-like addon) sends to Navigator. Then implement the same in Rosie's `lifecycle.hold_peers` / `release_peers`, with a joint-host regression test using a fake Navigator.

## Ready for review
- [2026-09-28] [Rosie] **Rosie 1.0.21: Navigator no longer blocks the Town Portal.** All calls to third-party addons go through `Rosie/rosie/private/foreign.lua`; every call is type-checked and pcall-guarded, and an absent addon is a no-op.
  - Navigator: held for the whole trip via `set_pause_condition("Rosie", trip in progress)`. The fallback `pause/resume` is used only when Rosie saw its own pause take effect.
  - During the cast, a busy foreign Navigator request is `stop()`ped: at most once per second and 30 times per trip.
  - Scavenger: `pause/resume("Rosie")` for each trip. Pickup yields while `Scavenger.is_busy()`.
  - Butler: no Rosie trip starts while `Butler.is_busy()`.
  - The cast now waits until the player has stood still for 0.6 s, and an interrupted cast is refunded. Time spent being moved by another addon on the outbound leg is not service time, but it is capped at `MOVER_WAIT` (120 s).
  - Generic hook for further addons: `lifecycle.add_foreign_hold`.
  - Worldstone reads `trigger_tasks=true` for the whole trip in the emulator.
  - Test: `audit/tests/test_rosie_foreign_mover.lua`, 10 cases. It fails on 1.0.20 (8 casts burned, trip not completed). Full suite green (97 files × Lua 5.4 + LuaJIT).
  - Component version: `versions.json`, `controller.lua` and `Rosie/README.md`. The Rosie row in the root `README.md` (Coordinator's file) is also bumped, because `check_release.py` requires it; please confirm at merge.
  - Live checks: a Worldstone run with a full bag (the console shows `Navigator is held during town trips (pause condition "Rosie")`, no `teleport_failed`); a plain trip still casts immediately. (claude/qqt-rosie@6215f95, PR #3)

## Auditor / critic findings
(none open)

## Released
- 3.3.2: Rosie 1.0.20 (no back and forth: fight hold, yield to other movers, obols); HelltideRevamped 2.6.1 (no idle at a dead Pandemonium rupture); WarRoom 1.0.2.
- 3.3.1: Rosie 1.0.19 (a full bag never waits forever; wait reasons logged).
