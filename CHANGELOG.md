# Changelog

All entries are in English. QQT_Warpigz_v2 release numbering starts with **2.0.0**. Earlier component versions and the imported Git baseline are not earlier releases of this project.

## [2.0.0] — 2026-09-24

First maintenance release of **QQT_Warpigz_v2**. All credits for the original foundation go to **@ZEWX — LONG LIVE LEGEND**.

### Added

- Direct SilentRaven integration with WarPigs for completed Whisper reward checks during stable visits to Temis only. Loot Steward is not required.
- Explicit request ownership, visible pending state, cancellation, bounded retries, and generation-safe managed Whisper callbacks.
- Reward-selection validation and observed cache receipt before SilentRaven reports a successful claim.
- Component and cross-plugin regressions, review records, source inventory, and release-version checks.
- Project branding, preserved credits, English notes, and separate bundle/component version tracking.

### Fixed

- Reaper's externally triggered `reset_run` crash caused by generic modules resolving in another plugin's context. Captured imports retain the correct tracker and helpers.
- Infernal Hordes Chaos Rift combat portals being ignored while the controller returned to the center. Recognized live hostile portals receive appropriate combat priority.
- Undercity completion around the boss and final chest. Missing actors alone no longer prove completion; rewards take priority over exploration.
- WarPigs treating unreadable/sparse quest snapshots as activity completion, accepting unknown town state, and allowing obsolete Alfred callbacks to affect later cycles.
- WarPug starting through active town companions, disagreeing with confirmed Alfred service completion, and trusting stale Temis data during loading.
- Alfred callers overwriting observed work, resuming pauses they did not acquire, and waiting indefinitely after rejected, thrown, or lost-callback requests.
- Batmobile autonomous updates undoing external pauses; Reaper treating unreadable companion/actor state as safe completion.
- Repeated altar, heart and shrine interactions, false traversal completion during approach, and dungeon cleanup clearing Alfred's newly acquired route.
- SilentRaven/WarPigs callback-order races, repeated teleport requests during a cast, and progression with a missing/dead player or loading world.
- Completed-Alfred advisory grace expiring during an already accepted Whisper request; live work and unreadable status still revoke the request.
- Horde reward/exit progression competing with observable looting, and outer Alfred checks failing on unavailable status.
- Helltide traversal blacklist scope, premature Maiden charging retries, invalid fallback target selection, and native movement cleanup when yielding.

### Performance and coordination

- Removed an unused large walkability scan from Horde updates.
- Bounded repeated movement, interaction, teleport and revival requests in reviewed paths.
- Preferred read-only modern Looter activity exports with legacy false-as-nil compatibility. No unsupported Looter pause/settings mutation is introduced.
- Namespaced SilentRaven modules to avoid generic module-cache collisions.

### Validation and limits

- `audit/VALIDATION.txt` records the final offline run; `AUDIT.md` documents review coverage and live checks.
- No live Diablo IV/QQT run or measured FPS improvement is claimed. Current packed Alfred/Looter internals were not recovered or certified.
- The reported LooteerV3 `approach_stall` needs exact source/runtime evidence. Outer town coordination fixes are included.
