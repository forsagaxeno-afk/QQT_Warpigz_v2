# TristramLoop

A standalone QQT plugin that farms one of two Season 15 maps over and over:

- **Tristram bosses**: the secret Uber Tristram arena (`S15_Secret_UberTristram`) with its three council bosses.
- **Pony / Whimsyshire** (`S15_Playhouse`): explores the map, fights enemies, and opens clouds, chests and breakable containers.

It is **not** part of WarPigs. WarPigs does not start or stop it. Run it on its own, with the other activity plugins turned off.

## How it works

The game gives you a fresh copy of these maps when you enter a new party instance. TristramLoop uses that to reset the map with a "party trick":

1. **Clear.** Tristram: walk a recorded path to the arena, fight until all three council bosses are seen dying. Whimsyshire: explore the reachable map, fight, and open objects.
2. **Loot.** Pick up the drops. It uses the host pickup rules (and Looteer's filter if Looteer is loaded and enabled).
3. **Wait.** Tristram only: wait for the **Loot wait** (default 60 minutes; see below). Whimsyshire uses its own short "Pony reset wait".
4. **Join a friend.** Open Social, type your friend's name in the search box, right-click the first result, click **Join Party**, then **Transfer Now**. This moves you into your friend's instance of the map.
5. **Leave the party.** Open Social, click **Leave Party**, then **Accept**. You stay in a new, fresh instance of the map.
6. Go back to step 1.

On the very first start outside the map, it joins your friend, closes Social with Escape and walks into the party-member portal (`PartyMemberPortal_Index0`).

### About the clicks

The party steps are real mouse clicks and key presses at fixed screen spots. The spots were measured on a 1920x1108 game client and are scaled to your window size. If the game's UI size is different from the default, use **Party UI size (%)** and **Preview party click targets** in Setup to check that the labels sit on the right buttons **before** you start.

Every click is sent only once. If a step does not finish (no loading screen, wrong window, a menu in the way), the loop **stops and tells you why**. It never clicks the same step again blindly.

### Why the loot wait is 60 minutes

The game locks the council bosses' loot for about **one hour** per character after a kill. Resetting earlier gives you a boss fight with no loot. So the loot wait defaults to 60 minutes. You can set it from 15 to 120 minutes. The wait counts from the last observed boss death (or the start of the fight); that time is saved in `tristram/local-state.txt` next to the plugin, so a reload does not forget it.

If you choose **Purpose: XP**, the loot wait is skipped.

**First start after install or reload:** if no boss-kill time is saved yet (first use, or `local-state.txt` cannot be written; the console then says *Local saves unavailable*), the loop counts the full loot wait from the moment the plugin loaded. With the default that is about an hour of *Next instance in ...* before the first reset. This is expected, not a hang. To avoid it, choose **Purpose: XP** or set a shorter loot wait for the first run.

## Before you start

1. Have a friend whose party you can join and who is in the chosen map (their party must be joinable).
2. Open the plugin menu: **Tristram / Pony Loop > Setup > Friend** and type your friend's account or character name. It must match exactly one friend in the Social search. **There is no default friend; the loop will not start until you set one.**
3. Set **Game Social key** to your in-game Social key (default `O`).
4. Optional: set a **Stop key** and a **Confirm party step key** (spare keys, not letters that appear in your friend's name).
5. Close Social, stand in the map (or anywhere, for a first entry through your friend), then switch **Run farming loop** on.

To start again after a stop, switch **Run farming loop** off and on.

## Settings

Main menu

| Setting | Default | What it does |
|---|---|---|
| Farm map | Tristram bosses | Tristram bosses or Pony / Whimsyshire. Takes effect on the next start. |
| Run farming loop | off | Master switch. Always off after a reload. |
| Purpose | Loot / gear | Loot waits the loot wait before each reset. XP does not wait. |
| Use optional Alfred town service | off | When bags fill or gear needs repair, ask Alfred to go to town and come back. Alfred's own settings decide what is sold, salvaged or stored. |
| Automatically revive | on | After death, revive at the checkpoint, wait 45 seconds, then go back and continue. |
| Confirm current party step | button | Use it when automatic transitions are off, after the game finished the current party step. |
| I have cleared all three bosses | button | Tristram only. Finish the fight by hand; refused while enemies are alive. |

Setup

| Setting | Default | What it does |
|---|---|---|
| Automatic party inputs | on | Send the party clicks automatically. Off: you do the party steps yourself and press Confirm. |
| Party UI size (%) | 100 | Match your game's UI size if the click targets are off. |
| Preview party click targets | off | While stopped, draw where each click would land. |
| Friend | empty | **Required.** Your friend's account or character name for the Social search. |
| Game Social key | O | The key that opens Social in the game. |
| Confirm party step key | none | Hotkey for "Confirm current party step". |
| Stop key | none | Hotkey that stops the loop at once. |
| Log world, bosses and portals | button | Print a short diagnostic to the console. |

Timing and combat

| Setting | Default | What it does |
|---|---|---|
| Loot wait (minutes) | 60 (15-120) | Tristram: time after a kill before the next reset. |
| Pony reset wait (seconds) | 5 | Whimsyshire: time after pickup before the next reset. |
| Pony sweep limit (minutes) | 20 | Whimsyshire: give up an unfinished sweep after this (max 30). |
| Automatic safe storage without Alfred | on | Whimsyshire: store carried gear in the Temis stash and repair, without selling or salvaging. |
| Combat progress timeout (seconds) | 12 | Whimsyshire: re-target when a fight makes no progress. |
| Consecutive incomplete run limit | 3 | Whimsyshire: stop after this many unfinished runs in a row. |
| Deaths per session limit | 3 | Whimsyshire: stop after this many deaths. |
| Fallback attack / Enemy priority | rotate / nearest | Whimsyshire: combat without a rotation plugin. |
| Use potion below 35% health | on | Whimsyshire: drink a potion when no rotation plugin is running. |
| Advance party steps on a world transition | on | Move to the next party step when a loading screen is seen. Off: you press Confirm. |
| Finish after three observed boss deaths | on | Tristram: finish the fight on its own when all three bosses died. |
| Seconds between party inputs | 1.5 | Pause between clicks. Increase for a slow UI. |
| Wait after Join Party (seconds) | 5 | Time for the Transfer prompt to appear. |
| Wait after loading (seconds) | 5 | Time for menus to close after a loading screen. |
| Party / teleport timeout (seconds) | 60 | Stop if a party step takes longer. |
| Fight timeout (seconds) | 300 | Tristram: drop an unfinished attempt and reset (not counted as a clear). |
| Alfred town / return timeout (seconds) | 300 | Stop if Alfred's town trip takes longer. |
| Encounter scan range | 60 | How far to look for enemies. |
| Approach distance | 12 | How close to walk before attacking. |
| Pick up host-approved loot | on | Pick up drops. |

## When it stops

The loop stops (and keeps the reason on screen, in the menu, and in the status) when something is not as expected: no friend set, a party step timed out, a menu interrupted a party step, you left the map, the Alfred trip failed, and so on. Fix the cause, then switch **Run farming loop** off and on.

## For other plugins

`TristramLoopPlugin` (also `TRISTRAM_LOOP_STATE`) is a global table:

- `enable()`, `disable()`, `status()`, `getState()`, `confirm_party_step()`, `finish_clear()`, `shutdown()`.
- Status fields copied onto the table every frame, including `running`, `held`, `phase`, `detail`, `cycles`, `wait_seconds`, `loot_wait_minutes`, `friend_set` and **`stop_reason`** (why it last stopped or refused to start; `nil` while running). Fields that are no longer reported are removed, so readers never see old values.

While it runs it takes the activity lease `TRISTRAM_LOOP_ACTIVITY_OWNER` and uses the shared rotation hand-off globals (`EXTERNAL_ROTATION_TARGET`, `EXTERNAL_ROTATION_TRAVEL_MODE`, ...). It refuses to start while host Auto-play is on or another script holds the rotation hand-off.
