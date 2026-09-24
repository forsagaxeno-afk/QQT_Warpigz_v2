# QQT_Warpigz_v2

![Diablo 4 QQT Season 15 — Warplan Orchestrator](assets/branding/warplan-orchestrator-v2.0.0.png)

**All credits for the original foundation go to @ZEWX — LONG LIVE LEGEND.**

Community maintenance update: we're updating the suite, fixing obvious bugs, and working to improve performance and reliability. The original foundation belongs to @ZEWX. Existing contributors retain their credits.

**First release: v2.0.0.** Project release numbering starts here. Plugin folder names and upstream history remain separate from the bundle version.

[English changelog](CHANGELOG.md) · [Audit and validation](AUDIT.md) · [Credits](CREDITS.md) · [Version rules](CONTRIBUTING.md)

## What it does

WarPug creates a War Plan in Temis. WarPigs watches the plan quests, starts the matching activity, waits for its cleanup, coordinates town services, and hands control to the next activity. This release adds direct SilentRaven integration for completed Whisper rewards during settled visits to **Temis (`Skov_Temis`) only**. Loot Steward is not required.

| Folder | Role | Component version |
| --- | --- | --- |
| `WarPigs-1.0.0` | Master orchestrator and town handoffs | 1.0.10 |
| `WarPug-1.0.0` | War Plan selection and creation | 1.0.11 |
| `Batmobile-1.0.12` | Shared navigation | 2.0.10 |
| `ArkhamAsylum-1.0.6` | The Pit | 2.0.10 |
| `HelltideRevamped-0.4` | Helltides | 2.0.10 |
| `HordeDev-1.3.9` | Infernal Hordes | 2.0.10 |
| `Reaper-main` | Boss lairs | 1.9.1 |
| `WonderCity-main` | Kurast Undercity | 2.0.10 |
| `SilentRaven-0.1.3` | Whisper reward checks in Temis | 0.1.4 |

Nightmare Dungeons are not supported. WarPug excludes those nodes.

## Installation

1. Stop the controllers and close QQT before replacing source files. Back up your plugin folders, settings, custom paths, and WarPug `positions.txt` outside the scripts directory.
2. Install the nine folders above in the QQT scripts directory. Keep one loaded copy of each plugin. Folder names remain unchanged even when a component version increases.
3. Replace the SilentRaven folder completely: its modules now live under `silent_raven.*`. Restore your saved configuration as needed. Do not load old SilentRaven alongside this build.
4. Keep your separately installed **Alfred**, **Looter**, and **combat/Orbwalker** plugins. They are not bundled or replaced. Configure town, loot rules, combat, and activity settings before enabling automation.
5. Fully reload QQT. This matters for the captured module imports that fix Reaper's externally triggered `reset_run` crash.
6. Enable SilentRaven in its own menu and **Whispers in Temis (SilentRaven)** in WarPigs. WarPigs does not override SilentRaven's enable checkbox.
7. Enable WarPug for automatic plan creation, then WarPigs for orchestration. Set **Use teleport** for the existing via-Temis service cycle. Avoid independently starting overlapping activity controllers.

`audit`, `docs`, and `assets` are not plugins. The preserved [upstream documentation](docs/UPSTREAM_README.md) explains original menus and activity setup; its dated history describes earlier builds.

## Whisper behavior

On each stable Temis visit, WarPigs waits for outgoing activity cleanup and observable Alfred/Looter work before requesting a reward check. An active WarPug transaction keeps priority. Requests have time limits, cancellation and late-callback guards. Managed Whisper requests never teleport or change Looter settings.

SilentRaven verifies the selected reward and observes cache receipt before reporting success. Unreadable state or an unconfirmed claim is not reported as completed. See its [integration contract](SilentRaven-0.1.3/README.md).

## Validation

Run with Python 3 and the Lua 5.4 shared library:

```sh
python3 audit/check_release.py
python3 audit/tests/run_tests.py
```

These checks compile runtime Lua and exercise actual modules with host-shaped test doubles. They do not run Diablo IV or QQT's native loader. Current packed Alfred/Looter internals, real NPC behavior, native navigation, and the reported LooteerV3 `approach_stall` still need live verification. Performance work removes identified unnecessary operations; no measured live FPS or throughput improvement is claimed.
