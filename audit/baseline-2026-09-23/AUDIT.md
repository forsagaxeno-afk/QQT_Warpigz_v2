# War Pig — audited build, 2026-09-23

This update fixes confirmed runtime and integration defects in the supplied project. It includes separate reviews for every plugin, an independent common audit and reproducible offline Lua regressions. The previously working Horde reset/entry behavior remains part of the baseline.

## Installation

1. Stop WarPigs and all activity controllers, then close QQT before replacing loaded Lua files.
2. Back up your existing eight plugin folders and their settings. Preserve custom paths and WarPug's `positions.txt`; do not delete your configured folders just to install this update.
3. Copy the eight plugin folders from this archive into `scripts`, replacing matching source files. Keep only one loaded copy of each plugin; put backups outside `scripts`. `audit/` and this document are not plugins.
4. Reload QQT. Keep your configured Alfred, Looteer and combat plugin. They are external dependencies and are not included in this archive.
5. Enable your normal orchestration setup. Do not also enable an unrelated activity controller that competes for the same navigation.

Existing plugin directory names and persisted setting keys are retained. The archive is an audited patch, not an upstream version-number claim.

## Main corrections

- **Helltide:** eligible chests are filtered before nearest-target ranking. Opened or blacklisted chests no longer hide usable same-type chests. Discovery includes the host's chest list, selected targets are reacquired by location, stale route/session state is cleared, and rejected interactions have bounded retries. Optional diagnostics describe unknown skins without inventing their costs.
- **Batmobile:** corrected traversal crashes and repeated buff handling, spell-prohibition requests, crowd-control hash types, approach height and autonomous route cleanup. Loading/death gates prevent invalid movement. Path reconstruction, backtrack lookup, density sampling and debug logging do less work.
- **Orchestration and town services:** cleanup is serialized before the next activity. Unfinished runs are not marked complete by a timer. Existing Alfred cycles retain their callback; synchronous and obsolete callbacks are handled correctly. Disabling an owner releases its own movement.
- **Reaper:** reward processing can run after combat, paths retain completion evidence, consecutive runs reset task state, inventory counts deduplicate item identities, and Belial retry/navigation failures no longer report false success.
- **Arkham:** reward and floor state resets at confirmed transitions, glyph retries count actual attempts, temporary boss disappearance is not death, and exploration exhaustion is not treated as Pit completion.
- **WonderCity:** configured tribute choices and inventory slots are validated, entry transition guards precede actor scans, dead bosses release the reward task, chest failure is distinguished from completion, and objective memory belongs to the current floor.
- **WarPug:** selection ownership is preserved, invalid quest/death/loading states cannot start a plan, submission is not repeatedly confirmed after a timeout, rerolls and delayed clicks are bounded, and calibration/test hotkeys trigger once per press. Its real WarPigs readiness contract is tested across cleanup, turn-in, filler and teleport modes.
- **HordeDev:** chest success requires payment or spent-chest evidence, optional chest disappearance cannot end the whole sequence, remaining aether continues through Materials/Gold, and missing readings never prove completion. Confirmed TELEPORT exit remains visible across task changes. Built-in salvage protects unrecognized high-rarity items and does not reject items against an empty class filter.

Detailed findings, severity, tests and remaining limits are recorded under `audit/reviews/`. The common reviewer independently checks shared contracts in addition to individual plugin regressions.

| Plugin | Dedicated report |
|---|---|
| HelltideRevamped | [Helltide review](../reviews/helltide.md) |
| Batmobile | [Navigation review](../reviews/batmobile.md) |
| ArkhamAsylum | [Pit review](../reviews/arkham.md) |
| HordeDev | [Horde review](../reviews/horde.md) |
| Reaper | [Boss-run review](../reviews/reaper.md) |
| WarPigs | [Orchestrator review](../reviews/warpigs.md) |
| WarPug | [Plan-creator review](../reviews/warpug.md) |
| WonderCity | [Undercity review](../reviews/wondercity.md) |

The [common audit](../reviews/suite_auditor.md) records independent integration findings and their verification. The tool's reviewer-process limit required the Helltide and Arkham reviewers to take separate subsequent passes over Horde and WonderCity; each plugin has its own report and regression file.

## Behavior changes to know

- A cleanup timeout now logs the blocked handoff instead of pretending the activity finished and teleporting away. If a plugin never completes, inspect its status or stop it explicitly.
- Reaper rejects its unfinished explicit `sigil` run type. Default/material runs remain supported; an unsupported request no longer silently becomes a material run.
- When WarPug is enabled, it takes priority over the optional Pit filler between plans. An already running filler finishes its normal cleanup; idle intent to teleport to a future plan does not prevent the creator from creating that plan.
- Batmobile's public pause still pauses exploration. Consumers that yield navigation must stop their own long path and clear their target; this update retains that public contract.
- Horde's built-in salvage retains Unique-or-higher and unreadable-rarity items, including unrecognized item IDs, even if marked junk. Missing/empty affix filters also retain items. Handle these through your deliberately configured Alfred or manually; external Alfred's own rules are unchanged.

WarPug conservatively waits for Alfred's pending work. An impossible restock target that leaves `need_trigger` permanently true can still hold plan creation; correct that companion setting rather than assuming the service finished.

## Verification scope

Final result: **184 runtime Lua files compile; all 12 regression files pass, with no failures.** This includes the unchanged 350 assertions for the previously working Horde reset/entry flow and 33 independent shared-contract checks. The complete output is in [VALIDATION.txt](VALIDATION.txt).

Run from this folder with Python 3 and the system Lua 5.4 shared library:

```text
python3 audit/tests/run_tests.py
```

The runner compiles runtime Lua and executes each regression file in a fresh Lua state. Tests use actual plugin modules with controlled QQT-shaped doubles. They cover state transitions, API argument shapes, handoffs and selected navigation work counts. They do not run Diablo IV, measure FPS or establish live route completion.

For example, one Batmobile fixture reduces enemy-position API calls from 240 to 10, while preserving the selected density result. Another removes 20,100 array shifts during reconstruction of a 201-node route. These are operation counts, not a claim that the character moves a particular percentage faster.

Seasonal review: [SEASON_15.md](../SEASON_15.md). Current actor skins, identifiers, costs, every seasonal modifier and actual background client behavior still need live validation. The supplied host does not expose enough state to prove every companion ownership/visibility condition; those limits are documented rather than guessed.

## First live checks and useful diagnostics

- Helltide: approach two same-type chests with the nearest already opened, then a chest requiring movement, then rotate zones. If detection still fails, enable **Draw chest status** (also enables scan diagnostics), stand near the affected chest, and capture its diagnostic lines and the current cinder count.
- Batmobile: run a normal route and one with a ladder/jump, then test death/revival and disabling the owning activity during a long route. Capture navigation/traversal/performance messages around a failure.
- Horde: complete the chest cycle with RESET selected, confirm departure occurs before reset, and confirm the next sigil entry proceeds.
- WarPigs: verify one full activity → loot → Alfred → next activity handoff. For an unmatched plan, enable its existing **Log ALL quests** option.

Send the plugin status, relevant log excerpt, game/QQT version, companion versions and what happened immediately before a failure. Do not treat a transient loading frame as proof that a boss, chest or portal has completed.

## Source baseline

The supplied archive was compared with GitHub `main` at `e7fd3b1e078470d6993ab4220d34a9990c5a909e`: 186 files matched, and only the seven user-confirmed Horde fix files differed. Those fixes were preserved as the starting point. Public QQT API declarations were checked at `14acd83bd3e94d6da27f0c361c9d1cbc3b06e916`. Baseline details are in `audit/*baseline_comparison.json`.
