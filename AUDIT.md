# QQT_Warpigz_v2 v2.0.0 — audit

This release combines component source review, independent review of changes, and executable offline regressions. Six reviewers split runtime modules, public APIs, callbacks, town coordination, and cross-plugin handoffs. Follow-up findings were returned to the responsible owner and checked again.

Source coverage does not prove every runtime branch or possible game state. Static route tables are inspected as data, not counted as executed navigation tests.

## Review records

| Scope | Report |
| --- | --- |
| WarPigs, WarPug and dispatch | [Dispatcher review](audit/feedback-reviews/secondpass_warpigs.md) |
| WonderCity and Arkham | [Dungeon review](audit/feedback-reviews/secondpass_dungeons.md) |
| Batmobile, Reaper and routes | [Navigation review](audit/feedback-reviews/secondpass_navigation.md) |
| Horde and Helltide | [Farming review](audit/feedback-reviews/secondpass_farming.md) |
| SilentRaven and actual bridge | [Contract review](audit/feedback-reviews/secondpass_contracts.md) |
| Alfred/Looter APIs and town callers | [Town review](audit/feedback-reviews/secondpass_town.md) |

Reports name reviewed files, tested behavior, findings, and remaining limits. Earlier snapshots can contain counts from before a follow-up fix. Final [validation output](audit/VALIDATION.txt) and [source inventory](audit/SOURCE_INVENTORY.json) describe the packaged source.

## Reproducible verification

```sh
python3 audit/check_release.py
python3 audit/tests/run_tests.py
```

The runner compiles every runtime Lua source and gives each test file an isolated Lua 5.4 state. Tests load real task, planner, bridge and API modules with QQT-shaped mocks. They cover conflicting module caches, callback order, rejected/unknown companion calls, loading, death, reward evidence, navigation ownership, and master stop. Original Alfred/LooteerV2 probes run only when the separately supplied source is available; otherwise they explicitly report a skip.

## Remaining live checks

- Launch Reaper from WarPigs after a full QQT reload.
- Run a Chaos Rift portal wave and check actual actor names and targetability; the reported wave's actors were not captured.
- Finish an Undercity boss, collect its reward, and observe the handoff.
- Revisit Temis with and without completed Whispers, including full inventory, active Alfred, Looter activity, loading, and master stop.
- Confirm native path cancellation and companion status exports in the installed builds.

The current proprietary LooteerV3 source is unavailable. Its screenshot establishes repeated `approach_stall` messages, but not their internal cause. This release fixes observable outer coordination defects; it does not claim to repair that proprietary algorithm or certify packed item sorting rules.

The [previous audit](audit/baseline-2026-09-23/AUDIT.md) and saved manifests are historical baseline evidence, not a separate release of QQT_Warpigz_v2.
