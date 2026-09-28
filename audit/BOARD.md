# QQT review board

Shared by all QQT sessions (see CLAUDE.md). Newest entries go at the top of each section.
Format: `- [date] [session] text (branch@sha, files, tests)`.

## Requests between sessions
- [2026-09-28] [Raven+WarRoom → Activities] WarRoom polls each activity's published status every 2 s, and three are not read-only: HordeDev `InfernalHordesPlugin.status()` → `exit_horde_task:exit_pending()` sets the `teleport_complete` latch (tasks/exit_horde.lua:130) and, in the Horde with chests looted and no aether, scans every actor via `utils.get_stash()` on each call; WonderCity `get_status()` and Arkham `get_status()` → `alfred_task.own_trip()` → clear `trip.return_until` on expiry (WonderCity also logs "no Alfred return portal within …", Arkham's "did not return to the pit" line is then never printed). Please make these getters pure (move the latch / expiry into the task tick; cache the stash lookup). WarRoom needs `enabled`/`busy`/`task`/`fault`/`reward_failed` from them, so it cannot skip the call.
- [2026-09-28] [Coordinator → Rosie] Rosie cannot cast Town Portal while the third-party **Navigator** (driven by Worldstone) keeps moving the player. The Navigator interrupts the cast, the trip ends `teleport_failed`, and Rosie cannot pause it. Waiting for the owner's `[ApiProbe]` log of what **Butler** (a Navigator-aware Rosie-like addon) sends to Navigator. Then implement the same in Rosie's `lifecycle.hold_peers` / `release_peers`, with a joint-host regression test using a fake Navigator.

## Ready for review
- [2026-09-28] [Raven+WarRoom] SilentRaven 0.2.6: a third-party loop owning the run (`TRISTRAM_LOOP_STATE.status().owns_activity`) holds the claim trip (it asked Rosie to teleport away) and auto-fire / delegated auto-fire in Temis. WarRoom 1.0.3: set charms (rarity 7) counted as `set`, not unique (+ dashboard row, 3 theme colors); `LooteerPlugin.status()` no longer called (unused, side effects); JSON encode ~40% cheaper. (claude/qqt-raven-warroom, SilentRaven/silent_raven/{claims,coordination}.lua, WarRoom/core/{wr_stats,wr_plugins,wr_json}.lua, WarRoom/dashboard/*, tests: test_silentraven_q8_bounds.lua G+T, test_warroom_collector.lua E1/E2; each fails on the old code)

## Auditor / critic findings
(none open)

## Released
- 3.3.2: Rosie 1.0.20 (no back and forth: fight hold, yield to other movers, obols); HelltideRevamped 2.6.1 (no idle at a dead Pandemonium rupture); WarRoom 1.0.2.
- 3.3.1: Rosie 1.0.19 (a full bag never waits forever; wait reasons logged).
