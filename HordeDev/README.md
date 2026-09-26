# Infernal Horde

**`As a community script any user is welcome to join the development of this script, if you are not a dev (don't worry, I'm not a dev either the majority of this script is thanks to Neer) I HIGHLY recommend loading this repo into Greptile and using Claude to understand and help write the code, its not a magic wand though you still need to learn to comprehend the logic and the structure and the best practices. You will spend lots of time prompting, testing, deleting everything and trying again. The goal is to learn from it and eventually come up with an improvement. When you do post it in the community thread. `**

**`REQUIRES ORBWALKER CLEAR TOGGLED ON AND BLOCK ORBWALKER MOVEMENT ENABLED`**


## Overview

Infernal Horde is a Lua-based script designed to automate the infernal hordes. This guide provides a high-level overview of the directory structure, core components, and the task manager's role. It also lists the `shouldExecute` functions for each task in the `/tasks` directory to help new developers understand and contribute to the project.

Current Features
- **`When in Horde, horde task runs and navigates to spires / masses, make sure orbwalker clear is on to kill monsters using your rotation`**
- **`Interacts with pylons to select boon/banes based on priority table`**
- **`Picks up Aether`**
- **`Interacts with boss door to check if its locked`**
- **`Enters boss room`**
- **`When bosses are dead switches task to Open Chests`**
- **`Opens Chests based on settings in GUI: Always open GA Chest / Open material, gear, or gold`**


## To-Do

Below is a quick list of things that need to be added, if you would like to tackle these please post in the dev thread and let others know, build in public, and get words of encouragement from other members of the community. 

- **`Clean up repo and remove piteer enums, data etc.`**
- **`Edit Repair task to tp from horde to vendor and back to horde`**

## Known issues

- Does not work if you have auto door opener scripts as it may get stuck at the boss door
- Sell and Repair does not work yet

## Directory Structure

```
infernal_bored/
├── core/
│   ├── affix_filter.lua
│   ├── navigation.lua
│   ├── settings.lua
│   ├── task_manager.lua
│   ├── tracker.lua
│   └── utils.lua
├── data/
│   ├── enums.lua
│   ├── pylons.lua
├── filters/
│   ├── barbarian.lua
│   ├── default.lua
│   ├── druid.lua
│   ├── necromancer.lua
│   ├── rogue.lua
│   ├── sorceror.lua
│   └── spiritbborn.lua
├── tasks/
│   ├── explore.lua
│   ├── horde.lua
│   ├── kill_monsters.lua
│   ├── open_chests.lua
│   ├── town_repair.lua
│   ├── town_sell.lua
│   ├── town_salvage.lua
├── gui.lua
└── main.lua
```

## Core Components

### `main.lua`
- Sets up the main script that runs in the background.
- Imports necessary modules.
- Defines functions for updating settings, executing tasks, and rendering the current task.

### `gui.lua`
- Defines the graphical user interface.
- Provides options for enabling/disabling the bot, adjusting settings, and selecting the type of chest to open.

### `core/`
- **`navigation.lua`**: Functions for moving the player character to a target position using direct movement or pathfinding.
- **`settings.lua`**: Contains a table of program settings and a function to update them based on the GUI.
- **`task_manager.lua`**: Manages a list of tasks and executes them based on priority.
- **`tracker.lua`**: Keeps track of various times during the game.
- **`utils.lua`**: Contains various utility functions, including distance calculation, aura and quest checking, actor retrieval, and pathfinding.

### `data/`
- **`enums.lua`**: Defines a table of constants used throughout the game, including quests, portal names, miscellaneous items, positions, and chest types.
- **`pylons.lua`**: Defines priority list for pylons in descending order.

### `data/filters`
- **`<class>.lua`**: Defines the affix filtering for affix salvage. This filter style is based on Pinguu's Affix Filter

### `tasks/`
- **`explore.lua`**: Defines the task for exploring.
- **`horde.lua`**: Defines the task for managing the horde.
- **`kill_monsters.lua`**: Defines the task for killing monsters.
- **`open_chests.lua`**: Defines the task for opening chests.
- **`town_repair.lua`**: Defines the task for repairing items in town.
- **`town_sell.lua`**: Defines the task for selling items in town.
- **`town_salvage.lua`**: Defines the task for salvaging items in town.

## Task Manager

The task manager is a crucial component that manages and executes tasks based on their priority. It ensures that tasks are executed in the correct order, which is essential for the smooth operation of the bot. The task manager's role includes:

- Maintaining a list of tasks.
- Checking if tasks should be executed.
- Executing tasks based on their priority.

## `shouldExecute` Functions

Each task module in the `/tasks` directory includes a `shouldExecute` function that determines whether the task should be executed. Below is a list of these functions for each task:

### `explore.lua`
```lua
shouldExecute = function()
    return not utils.get_closest_enemy()
end
```

### `horde.lua`
```lua
shouldExecute = function()
    return utils.player_in_zone("S05_BSK_Prototype02") 
end
```

### `kill_monsters.lua`
```lua
shouldExecute = function()
    local close_enemy = utils.get_closest_enemy()
    return close_enemy ~= nil
end
```

### `open_chests.lua`
```lua
shouldExecute = function()
    return utils.player_in_zone("S05_BSK_Prototype02") and utils.player_on_quest(2023962)
end
```

### `town_repair.lua`
```lua
shouldExecute = function()
    return utils.player_in_zone("Scos_Cerrigar") 
        and auto_play.get_objective() == objective.repair
end
```

### `town_sell.lua`
```lua
shouldExecute = function()
    return utils.player_in_zone("Scos_Cerrigar") 
        and get_local_player():get_item_count() >= 25
        and settings.loot_modes == gui.loot_modes_enum.SELL
end
```

### `town_salvage.lua`
```lua
shouldExecute = function()
    return utils.player_in_zone("Scos_Cerrigar") 
        and get_local_player():get_item_count() >= 25
        and settings.loot_modes == gui.loot_modes_enum.SALVAGE
end
```

## Getting Started

To get started with contributing to the project, follow these steps:

1. Clone the repository.
2. Familiarize yourself with the directory structure and core components.
3. Review the `shouldExecute` functions for each task to understand the logic behind task execution.
4. Start by making small changes or improvements to the existing codebase.
5. Test your changes thoroughly before submitting a pull request.

We welcome contributions from developers of all skill levels. If you have any questions or need further assistance, feel free to open an issue or reach out to the maintainers.

Happy coding!


## Audited chest and lifecycle behavior

The existing native **Consume Sigil confirmation**, portal-entry settling and
**Leave Dungeon → outside verification → Reset** flows are retained. Their
pending transactions keep scheduler priority across world changes. A pending
transaction is never treated as a completed exit for an external orchestrator.

Chest selection preserves the configured Talisman/Greater Affix priorities,
then the selected Materials or Gold chest. Boss aether is collected before
chest spending. Payment or the attempted chest becoming non-interactable
confirms an opening; unrelated global coin/light effects do not. Materials
continue while aether remains, with the existing Gold chest used for the
remainder when Materials cannot be opened. No new chest costs are assumed.
A rejected Gold chest leaves an explicit `Chests:` error; the chest phase then
ends as a fault (reported in `status().fault`) and HordeDev leaves the Horde
through its normal exit with the unspendable aether instead of waiting in the
chest room. Temporarily unavailable aether readings cannot prove completion.

Chest discovery checks both documented actor and loot/chest sources. State,
attempt counts and delays reset between runs. Missing chest actors no longer
crash completion or skip all remaining chest types. Dead bosses and spent
pylons no longer take priority over living wave targets.

Alfred completion updates only this plugin's local state. Existing companion
cycles retain ownership, and disabling HordeDev invalidates old callbacks and
stops movement issued by HordeDev. A confirmed Teleport-mode arrival retains
completion evidence after the next town task starts, allowing WarPigs to finish
the handoff regardless of update order.

Built-in salvage refreshes its class filter after character changes and resets
its per-cycle counts and timers. It conservatively keeps all Unique-or-higher
items (host rarity 6 and above), unreadable rarity, locked items and known
Mythics. Affix mode also keeps items whose filter is missing or empty. These
items remain for configured Alfred or manual processing. Existing identifiers
and filter data are unchanged; lower-rarity items with configured rejection
rules can still be salvaged, including explicit junk. No new class or Mythic
identifier is needed for these protections.

Library teleports are debounced while the origin remains loaded. Loading
screens block normal movement; the native pending transaction handlers retain
their own loading/death guards. Existing settings, control hashes, sigil names,
waypoints, boss names and spell identifiers are preserved. No Season 15
identifier or cost has been guessed.

Offline checks from the suite directory:

```sh
python3 audit/tests/run_tests.py test_horde_reset_exit.lua test_horde_sigil_entry.lua test_horde_audit.lua test_integration_horde.lua
```

These retain all 350 prior reset/entry assertions and add 22 behavior checks.
They do not replace an in-game check of routes, live actor names, battle
rotation, seasonal availability or actual teleport/interaction timing.

### Integration review fixes

- A chest phase that cannot finish no longer freezes HordeDev or WarPigs: the fault is published and the configured exit (Leave Dungeon/Reset or Teleport) runs. A latched Leave/Reset, sigil or entry fault is also published, and turning HordeDev off and on (menu toggle, keybind, or a WarPigs disable/enable) clears it. A healthy pending transaction still survives a pause.
- Dying while a Leave/Reset, sigil or entry transaction is pending revives at the checkpoint, and the dead time does not count toward that transaction's timeout.
- `InfernalHordesPlugin.status()` additionally reports `in_run` (committed to a horde: entry, run, chests, exit/Reset or HordeDev's own Alfred trip), `fault`, `alfred_trip` and `hold`; `enabled` now includes the keybind gate.
- Alfred: "Use alfred" off means HordeDev never waits on Alfred. An unreadable Alfred status holds at most 10 s. A finished trip's teleport flag is not treated as live work, a sticky `need_trigger` cannot re-trigger within 30 s of HordeDev's own completed cycle, and a salvage pause nobody can service resumes the chests. When Alfred's callback arrives while the player is still outside the Horde, HordeDev waits up to 20 s for the return portal before other tasks may leave; the built-in Cerrigar salvage does not run after a delegated Alfred trip.
- Waypoint teleports are not re-fired into their own channel: 6 s for the Teleport exit, 8 s for the built-in salvage trip, and not while the teleport spell is still casting (for up to 15 s).
- "Run pit when finish compasses" starts ArkhamAsylum, and is skipped while WarPigs manages the handoffs.
- Time spent yielding to Alfred or another task no longer counts toward the walking watchdog or the Bartuc pylon timeout. A Looter that never reports idle holds the chest/exit handoff for at most 120 s. Holds are shown on screen and logged when they last longer than 60 s.
- `status().exit_pending` is `true` while HordeDev's own exit is actively in progress: the Leave Dungeon/Reset transaction, a Teleport exit that has not left the Horde yet, or an exit that is due but waiting for the Looter. A latched exit fault or a stopped HordeDev reports `false`. WarPigs uses it so it does not cut the exit short after a chest fault.
- "Use keybind" ticked with no key bound no longer blocks an external `enable()` (WarPigs): HordeDev then runs under external control until `disable()` or the menu toggle is switched off, and logs the misconfiguration once. A key you did bind still pauses HordeDev. Starting HordeDev yourself with the menu toggle still needs the key.
- `enable()` while HordeDev is already switched on and inside a healthy run (entry, wave, chests, exit/Reset or its own Alfred trip) keeps that run instead of resetting it; a latched fault is still cleared, and `disable()` followed by `enable()` is a full restart.
- A paused Alfred holds HordeDev's own pending Alfred request, or a salvage stop, for at most 60 s (logged once). After that the request is dropped, the chests continue without the salvage trip until Alfred's pause ends, and the built-in Cerrigar salvage is not used while Alfred is enabled.

Offline regression coverage is in `audit/tests/test_horde_*.lua` and `audit/tests/test_integration_horde.lua`.
