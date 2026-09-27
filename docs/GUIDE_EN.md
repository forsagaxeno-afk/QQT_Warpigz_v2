# QQT_Warpigz_v3: the simple guide

This guide is for people who have never used these plugins. It uses short steps and plain words.

You can run the bundle in two ways:

- **Mode A: War Plan automation.** WarPigs and WarPug run your War Plans from start to end.
- **Mode B: one activity by hand.** You pick one activity (for example Helltide) and farm only that.

Read parts 1 to 3 first. Then read the part for the mode you want.

All credits for the original foundation go to **@ZEWX — LONG LIVE LEGEND**.

**Contents**

1. [What is in the bundle](#1-what-is-in-the-bundle)
2. [Install or update](#2-install-or-update)
3. [First-time setup everyone needs](#3-first-time-setup-everyone-needs)
4. [Mode A: "War Plan" automation with WarPigs](#4-mode-a-war-plan-automation-with-warpigs)
5. [Mode B: farm one activity by hand](#5-mode-b-farm-one-activity-by-hand)
6. [Troubleshooting (FAQ)](#6-troubleshooting-faq)

---

## 1. What is in the bundle

There are 10 plugin folders:

| Folder | What it does |
| --- | --- |
| `WarPigs` | The "boss" plugin. It watches your War Plan quests and turns the right activity plugin on and off. |
| `WarPug` | Makes a new War Plan for you in Temis. |
| `Rosie` | Picks up loot, and in town it sells, salvages, repairs and puts items in your stash. It replaces the old Alfred and Looter plugins. |
| `Batmobile` | Walking and pathfinding. The other plugins use it. It does nothing on its own. |
| `HelltideRevamped` | Farms Helltides: tears, cinders, chests. |
| `HordeDev` | Farms Infernal Hordes. |
| `Reaper` | Farms boss lairs (uses Lair Keys, Greater Lair Keys, Betrayer's Husks). |
| `WonderCity` | Farms the Kurast Undercity. |
| `ArkhamAsylum` | Farms the Pit. |
| `SilentRaven` | Claims your Whisper rewards in Temis. |

Not included: **your combat script** (for example Orbwalker and your class rotation). You must install and keep your own. The bot walks and loots. Your combat script does the fighting.

Nightmare Dungeons are not supported.

---

## 2. Install or update

Follow these steps every time you install or update.

1. **Close QQT.**
2. **Back up `WarPug/positions.txt`.** Copy it to a safe place **outside** the QQT `scripts` folder. This file holds your WarPug click positions. The new package ships it empty.
3. Open the release zip. Go into its `scripts` folder.
4. Copy **the 10 plugin folders** from there into your QQT `scripts` folder. Replace the old folders completely.
   - Do **not** copy `audit`, `docs` or `assets` into `scripts`. QQT would try to load them and print `cannot open ...\main.lua`.
5. **Coming from version 2.x?** Delete the old folders that have a version number in their name first. Otherwise QQT loads two copies:
   `WarPigs-1.0.0`, `WarPug-1.0.0`, `Batmobile-1.0.12`, `ArkhamAsylum-1.0.6`, `HelltideRevamped-0.4`, `HordeDev-1.3.9`, `Reaper-main`, `WonderCity-main`, `SilentRaven-0.1.3`.
   (Since 3.0 the folders have no version in their name.)
6. **Remove Alfred and Looter.** Rosie replaces them. Move these folders out of `scripts` (or delete them): `Alfred`, `SteroidAlfred`, `AlfredTheButler-WarPigz`, `LooteerV3`, and any other Alfred or Looter copy. If you keep one, Rosie shows a conflict and does not start.
7. **Keep your combat script / Orbwalker.** It is not part of the bundle.
8. Put your backed-up `positions.txt` back into the `WarPug` folder.
9. Start QQT. In the console you should see one line per plugin, for example `Lua Plugin - WarPigs - v...`. The versions should match the table in `README.md`.

Your menu settings are kept when you update.

---

## 3. First-time setup everyone needs

Do this once, whatever mode you use.

### 3.1 Rosie (loot and town)

**Rosie starts OFF.** Set her up before you turn her on.

1. Open the **Rosie** menu.
2. Open **Pickup rules**. Choose what she picks up:
   - **General Settings → Minimum Equipment Rarity**: the lowest gear rarity to pick up.
   - **Equipment Greater Affixes**: how many Greater Affixes (GA) gear needs to be picked up. `0` = any.
   - **Item Types**: tick the item types you want (Charms, Seals, Runes, Gemstones, Horde Compasses, Lair Keys, Tributes and so on).
   - **Respect Ingame Loot Filter** (default ON): skip items your in-game loot filter hides.
3. Open **Keep, storage & town**. Choose what happens in town:
   - **General settings → Home town**: Temis (the only town Rosie serves).
   - **General settings → Max inventory items** (default 25): when the bag has this many items, Rosie goes to town.
   - **Non-Ancestral** and **Ancestral**: for each item type choose **Keep**, **Salvage** or **Sell**.
   - **Ancestral → Always keep mythics** (default ON): mythics are never sold or salvaged. Leave it on.
4. Go back to the top of the Rosie menu and tick **Enable Rosie**.

**Important Rosie options, in plain words:**

| Option | Where | Default | What it means |
| --- | --- | --- | --- |
| **Enable Rosie** | top of the Rosie menu | OFF | The master switch. Turning it off stops all Rosie work. |
| **Pick up every Unique (sort in the bag)** | right under Enable Rosie | ON | On the ground, a Mythic and a normal Unique look the same. With this on, Rosie picks up **every** Unique and Mythic. Once it is in the bag she can see which one it is. She never throws away a Mythic. |
| **Plain Uniques** | under the option above | In town | **In town**: normal Uniques stay in the bag and your town rules sell, salvage or keep them. **Drop**: outside town, a normal Unique your rules would sell or salvage is dropped on the ground right away and never picked up again. This means fewer town trips. Mythics, locked items and Uniques your rules keep are never dropped. |
| **Stash socketables** | Keep, storage & town → Socketables | When full | When your gems/runes bag is full, Rosie puts them in the stash. Other choices: Never, Always. |
| **Seal default action** | Keep, storage & town → Talisman (Seal) | Salvage | What happens to seals you do not want. |
| **Use affix filter** (seals) | Keep, storage & town → Talisman (Seal) | OFF | Turn it on and tick the seal affixes you want. A seal with enough of your affixes is kept. Every other seal gets the Seal default action. While this filter is on (with at least one affix ticked), **it decides seals, not the in-game loot filter**. |
| **Use unique/mythic seal filter** | Keep, storage & town → Talisman (Seal) | OFF | Unique seals (Annihilus) and mythic seals are always kept unless you turn this on. |
| **Run town service** | top of the Rosie menu (shown when Rosie is on and idle) | – | Sends Rosie to town now. Also use it to retry after a problem. |
| **Stop Rosie** | top of the Rosie menu (shown during a trip) | – | Cancels the trip and turns Rosie off. |

Good to know:

- Locked (favourite) items are never sold or salvaged.
- Rosie turns the game's **Auto Loot** off while she works. After you remove Rosie, turn Auto Loot back on by hand if you want it.
- Charms work like before: the in-game loot filter decides first, then the charm rules (**Talisman (Charm)**).

### 3.2 Your combat script

1. Install your combat script / Orbwalker the normal way.
2. Turn it on and check that it fights.
3. The bundle does not change it. Most activity plugins have a **Manage orbwalker** option. It is OFF by default, so your combat script stays in charge. Leave it off unless you know you need it.
4. For **Infernal Hordes** (HordeDev), Orbwalker **Clear** must be ON and **Block Orbwalker Movement** must be enabled.

### 3.3 Batmobile basics

Batmobile has no "Enable" box. It is always there for the other plugins. Open **Z | Batmobile | Leoric**:

1. **use movement spells**: a key toggle. Bind a key and switch it on if you want the bot to use your movement skills (evade, teleport, dash, leap...).
2. **Movement Spells**: tick the skills to use. You only see the skills of your class. **evade** is ON by default. The anti-stuck help also uses evade only when this box is ticked.
3. **Movement Revamp** (default OFF): replaces the simple list with rules you build yourself (**Movement Rules**). Only for advanced users. Warlocks can pick **Rampage** there.
4. **Reset batmobile**: a key that clears Batmobile's memory if it gets confused.

---

## 4. Mode A: "War Plan" automation with WarPigs

### 4.1 What WarPigs and WarPug do

- **WarPug** stands in Temis. When you have no active War Plan, it picks and confirms a new War Plan path for you. It never picks Nightmare Dungeon steps. If there is no good path, it clicks **Reroll** and **Confirm**. For this it needs your saved click positions.
- **WarPigs** reads your War Plan quests. For each step it turns on the right activity plugin (Helltide, Pit, Hordes, boss lairs, Undercity). When the step is done, it waits for the plugin to finish, turns it off and starts the next one. At the end it hands in the War Plan.

### 4.2 Set up WarPug (click positions)

You only need this once (or after a new install, unless you restored `positions.txt`).

1. Go to Temis and open the War Plan board.
2. Open **Z | War Pug | War Plan Creator**.
3. **Set Reroll Pos**: bind a key. Put your mouse over the **Reroll** button in the game. Press the key. The console says `Reroll captured`.
4. **Set Confirm Pos**: bind a key. Open the reroll dialog. Put your mouse over the **Confirm** button. Press the key.
5. Optional check: bind **Test Click Sequence**. With WarPug **off** and the War Plan board open, press the key. Watch the clicks land on the right buttons. **Show click positions** draws green crosses on the saved spots.
6. Tick **Enable** in WarPug.

### 4.3 Which plugins to turn on

| Turn ON yourself | Leave OFF (WarPigs turns them on and off) |
| --- | --- |
| Rosie (**Enable Rosie**) | HelltideRevamped |
| Your combat script | HordeDev |
| SilentRaven (**Enable**), if you want Whisper rewards | Reaper |
| WarPug (**Enable**) | WonderCity |
| WarPigs (**Enable**) — last | ArkhamAsylum |

Batmobile needs nothing (no Enable box).

Still **open each activity plugin once and set it up** (for example the Pit level in ArkhamAsylum). WarPigs uses those settings. Just do not tick their **Enable**.

Under WarPigs, Helltide always runs in **Warplan** mode. The Smart farm menu is not used there.

### 4.4 Key WarPigs options

Menu: **Z | War Pigs | Orchestrator**.

| Option | Default | What it means |
| --- | --- | --- |
| **Enable** | OFF | Starts and stops WarPigs. |
| **Use keybind** / **Toggle Keybind** | OFF | A hotkey to switch WarPigs on and off. |
| **Use teleport** | OFF | After each activity: go to Temis, let Rosie do town work, then teleport to the next War Plan step. The README recommends turning it on. |
| **Run pit after turn-in** | OFF | After a hand-in, run the Pit while there is no War Plan step to do. |
| **Hordes: enter via War Plan teleport (no compass)** | ON | For a Horde step, WarPigs uses the War Plan teleport. **No Infernal Compass is used.** Keep it on. |
| **Allow compass entry if the War Plan teleport fails** | OFF | Only if 3 War Plan teleports miss the Horde: use a compass instead. Off = never spend a compass; wait 60 s and try the teleport again. |
| **Whispers in Temis (SilentRaven)** | ON | Lets SilentRaven claim Whisper rewards. SilentRaven must also be enabled in its own menu. |
| **Manage orbwalker** | OFF | Leave off; your combat script stays in charge. |

### 4.5 Start, pause, stop

1. Turn on your combat script, Rosie, SilentRaven (optional) and WarPug.
2. Go to Temis.
3. Tick **Enable** in WarPigs (or press its Toggle Keybind).
4. To pause or stop: **turn WarPigs off** (untick Enable or press its key). WarPigs then stops the activity it runs.
   - Do **not** pause with an activity plugin's own hotkey. It works, but WarPigs then just waits for that plugin and nothing moves on.
   - Do not start another activity plugin yourself while WarPigs runs.

### 4.6 What to expect

- A white **status line** at the top of the screen shows what WarPigs is doing.
- In the console you will see lines like:
  - `[WarPigs] enabled InfernalHordesPlugin (...)` / `[WarPigs] disabled ...` when a step starts and ends.
  - `[WarPigs] War Plan Horde entry: ... landed world=... zone=...` when it teleports into a Horde.
  - `[WarPigs] turn-in cycle completed ...` after a hand-in.
  - `[SilentRaven] reward ready` and `claiming the Whisper reward (...)` for Whisper rewards.
- A missing plugin is shown in the WarPigs menu (`... not loaded — ... will not be managed`).

---

## 5. Mode B: farm one activity by hand

### 5.1 The general rule

Turn on **only these**:

1. **One** activity plugin (for example HelltideRevamped).
2. **Rosie**.
3. **Batmobile** (always there, nothing to turn on).
4. **Your combat script**.
5. **SilentRaven** — only if you want Whisper rewards claimed. Keep its **Auto-fire in town** on.

Leave **WarPigs and WarPug off**.

If you turn on two activity plugins (for example ArkhamAsylum and WonderCity), the first one runs. The second one **waits** and shows why on its screen text. They no longer teleport back and forth.

### 5.2 HelltideRevamped (Helltides)

**What it does:** finds the Helltide, farms cinders (tears first), then opens chests.

**How to start:**

1. Open **Z | Helltide Revamped | Letrico**.
2. Set **Mode** to **Farm** (the default).
3. Check **Settings → Open Helltide Chest** is ticked (default ON).
4. Tick **Enable**.

The bot finds the zone with the Helltide by itself. The Helltide hour follows **UTC** time.

**Farm mode: the Smart farm menu.** It is in the order of a Helltide:

**1. Goal: farm cinders, then open chests**

| Option | Default | What it means |
| --- | --- | --- |
| **Farm cinders until** | ON | Below the goal the bot only farms and opens no Helltide chest. It remembers the chests it sees. At the goal it goes on a chest run: Hell's Prize (666) first, then Mystery chests (250), then the rest, nearest first. Then it farms again. |
| **Cinders** | 2000 | The goal. |
| **Spend all in the last (min)** | 5 | In the last minutes of the Helltide it spends everything, so no cinders are lost. |
| **Keep 250 for a Mystery chest** | ON | Shown only when the goal is off. Keeps 250 cinders for a Mystery chest you can still reach. |

Untick **Farm cinders until** to open chests as soon as you can pay (the old way).

**2. How to farm: tears first**

| Option | Default | What it means |
| --- | --- | --- |
| **Hunt tears** | ON | Goes to every tear first. Tears give the most cinders. No tear in sight: it fights monsters along the road until one shows up. |
| **Stand on chargeable tears** | ON | Stands inside each golden tear until it closes (at most 90 s per tear). |
| **Fight Realmwalker** | ON | Waits for the Realmwalker after the tears and kills it. |
| **Open tear chests** | ON | Opens the free chests in the ritual ring once the tear is closed. |
| **Skip legacy Helltide events** | ON | Skips flame pillars and soul pyres. Tears pay more. |

After a tear event, the bot collects the drops Rosie wants in the event area, then moves on.

**3. Movement and logic**

| Option | Default | What it means |
| --- | --- | --- |
| **Smart chest order** | ON | Mystery chests first, nearest first along the road, no running back and forth. |
| **Road routing** | ON | Reaches far chests along the road. |
| **Learn while farming** | ON | Remembers chest spots and the Helltide border (folder `HelltideRevamped\learned`). |
| **Stay inside the Helltide** | ON | Skips chests and events outside the Helltide. |
| **Pin the target on the map** | OFF | Puts the game map pin on the chest the bot walks to. |
| **Forget learned data (this zone)** | button | Deletes what it learned for the zone you are in. |

**Advanced**: tuning sliders (tear search distance, Realmwalker wait and so on). You can leave them alone.

**Warplan mode.** If you set **Mode** to **Warplan**, the bot opens chests as soon as it can pay and keeps moving. No tears, no Maiden, no chaos rifts. Then **Settings** shows **Spend cinders on chests at** (default OFF). With it on you also get **Cinders** and **Spend all in the last (min)**: the bot saves cinders until it has that many, then goes on a chest run in the same order; in the last minutes it spends what it saved.

**Live data & stats** (its own menu section):

| Option | Default | What it means |
| --- | --- | --- |
| **Stats overlay** | ON | A panel on screen: time left, cinders per minute and hour, chests, deaths. Pick **Rows**; change its look under **Overlay appearance** (below). |
| **Web dashboard** | OFF | Turn it on. Then open `HelltideRevamped\dashboard\index.html` in your web browser straight from the disk (double-click it). No internet needed. It shows live stats, a map and history. Pick a theme at the top of the page: **Forge**, **Daylight** or **Console**; next time `index.html` opens the one you picked. |
| **Live Helltide zone (internet)** | OFF | Asks helltides.com (or diablo4.life) where the Helltide is this hour, so the bot goes there directly. Only the zone is read; nothing about you is sent. |
| **Reset all-time stats** | button | Clears the all-time totals. |

**Overlay appearance** (open it under **Stats overlay**):

| Option | Default | What it means |
| --- | --- | --- |
| **Anchor** | Top left | The screen corner the panel starts from. Pick **Top right** or **Bottom right** to move it away from the party frames. |
| **Offset X / Y (%)** | 1 / 3 | How far from that corner, in percent of the screen. |
| **Font size** | 15 | Bigger text makes the whole panel bigger. |
| **Layout** | Two columns | **Two columns** is wide and short; **One column** is narrow and tall. |
| **Width (px, 0 = auto)** | 0 | 0 fits the text. A smaller width cuts long texts. |
| **Colors** | Bright | **Bright**: white text with a dark shadow. **Classic**: the old softer colours. **Minimal**: no panel, white text with a black outline. |
| **Accent** | Cyan | Colour of the section titles and the timer bar. |
| **Background opacity (%)** | 25 | How dark the panel is. The game draws the text under the panel, so a dark panel makes the text dim too: keep it at 40% or lower. |
| **Show bars** | ON | The bars under the timer, the wave and the cinders. |
| **Compact layout** | OFF | Tighter lines and fewer extra rows. |
| **Sections** | all ON | Tick off what you do not need: Helltide timer, Wave, Cinders, Now, Target, Stats table, Opened this wave. The panel gets shorter. |

**Tips:**

- When you update, you can keep the `HelltideRevamped\learned` folder. It holds what the bot learned.
- **Settings → Idle town** (default Temis): the town it waits in between Helltides.
- **Do Maiden (Farm mode only)** is OFF by default. It needs Helltide hearts in your bag.

**Common problems:**

- *"It walks past chests."* That is normal with the goal on. It saves cinders and comes back for the chests at the goal.
- *"It waits in town."* Helltides run minutes 0–54 of each UTC hour. In the break it waits.
- *Chests are missed.* Turn on **Debug settings → Draw chest status** and send the `[CHEST SCAN]` lines.

### 5.3 HordeDev (Infernal Hordes)

**What it does:** uses an Infernal Compass, plays the waves, picks pylons, kills the bosses, opens the chests, leaves and starts again.

**How to start:**

1. Put **Infernal Compasses** in your bag.
2. Set your combat script: Orbwalker **Clear ON** and **Block Orbwalker Movement** enabled.
3. Open **Z | Infernal Horde | Letrico** and tick **Enable**.

**Options that matter** (menu **Settings**):

| Option | Default | What it means |
| --- | --- | --- |
| **Exit mode** | Reset | Reset: Leave Dungeon, then reset. Teleport: travel to the Library. |
| **Always Open GA Chest** | ON | Opens the Greater Affix chest when there is one. |
| **Select Chest Type** | Materials | Materials or Gold. |
| **Always Open WarPlans Talisman Chest** | OFF | Opens the War Plan Talisman chest first. |
| **Do Bartuc** | OFF | Picks Bartuc first. |
| **Run pit when finish compasses** | OFF | Starts ArkhamAsylum when you run out of compasses. |
| **Advanced settings → Use 6 / 8 / 10 wave compasses** | all ON | Which compasses it may use. |

**Tips and problems:**

- Do not use "auto door opener" scripts. HordeDev can get stuck at the boss door.
- `Dungeon Sigil not found in inventory.` means you have no compass.
- If **Use keybind** is ticked, starting from the menu also needs the key.

### 5.4 Reaper (bosses)

**What it does:** teleports to boss lairs, kills the boss, opens the chest. It uses Lair Keys, Greater Lair Keys, or Betrayer's Husks (Belial). When you run out, it goes to town and turns itself off.

**How to start:**

1. Put your keys in your bag.
2. Open **Reaper** → **Bosses to Farm**.
3. Pick **Rotation Mode** (default Round Robin):
   - **Manual**: one boss (pick it in **Target Boss**).
   - **Round Robin**: tick several bosses; one run each in turn.
   - **Random**: a random ticked boss each run.
4. Tick the bosses you want (all are OFF by default).
5. Tick **Enable**.

**Options that matter:**

| Option | Where | Default | What it means |
| --- | --- | --- | --- |
| **Home town** | Settings | Temis | Town between runs. |
| **Use Alfred** | Settings | ON | Town work between runs. Rosie does this now. Leave it on. |
| **Use Batmobile Navigation** | Settings | OFF | Use Batmobile instead of recorded paths. Try it if the bot gets lost in a lair. |
| **Dungeon Reset → Enable** | Dungeon Reset | OFF | Resets dungeons every N runs. |
| **Belial Chest Automation → Enable** | Belial Chest Automation | OFF | Needed for Belial: clicks the reward chest. Check the crosshairs under **Chest Dialog Alignment**. |

**Tip:** your keys are counted when you turn Reaper on. Turn it off and on after adding keys.

### 5.5 WonderCity (Kurast Undercity)

**What it does:** enters the Undercity, uses enticements and beacons, kills the boss, opens the final chest, and starts again.

**How to start:**

1. Open **Z | WonderCity | Leoric** → **Undercity Settings**.
2. Pick **Town** (default Kurast).
3. Set **Tribute Priority** (0 = skip, 1 = first). Or tick **Skip tribute**.
4. Tick **Enable**.

**Options that matter:**

| Option | Default | What it means |
| --- | --- | --- |
| **Reset Time (s)** | 600 | Gives up on a run after this many seconds. |
| **Exit mode** | Reset | How it leaves. |
| **Max Enticement** | 5 | How many enticements to use. |
| **Loot Obols** | ON | Picks up Obols. |
| **Chase goblin** | ON | Chases goblins. |
| **Use custom explorer** | OFF | A faster, objective-first explorer. Try it if runs are slow. |
| **Enable Bargains** | OFF | Picks a bargain at the obelisk. Needs the **Click Points Setup**. |

**Tip:** town work (Rosie) always happens in Temis. WonderCity travels back to its town by itself.

### 5.6 ArkhamAsylum (The Pit)

**What it does:** enters the Pit at your level, explores, kills the boss, upgrades glyphs, leaves and starts again.

**How to start:**

1. Open **Z | Arkham Asylum (pit) | Leoric** → **Pit Settings**.
2. Set **Pit Level**. **The default is 1** — change it to your level.
3. Tick **Enable**.

**Options that matter:**

| Option | Default | What it means |
| --- | --- | --- |
| **Home town** | Temis | Where it starts the run. |
| **Reset Time (s)** | 600 | Gives up on a Pit after this many seconds. |
| **Exit delay (s)** | 10 | Wait before leaving. |
| **Enable Glyph Upgrade** | ON | Upgrades glyphs after the boss. |
| **Upgrade mode** | Lowest to highest | Which glyphs first. |
| **Upgrade to legendary glyph** | ON | Turn off to save gem fragments. |
| **Return for loot** | ON | Comes back for loot after a town trip. |
| **Enable shrine interaction (and belial eye)** | ON | Uses shrines. |

### 5.7 SilentRaven (Whisper rewards)

**What it does:** claims your finished Whisper rewards in Temis.

**How to set it up:**

1. Open **SilentRaven** and tick **Enable**. **It starts OFF.**
2. Keep **Auto-fire in town** ON (default). Then every Rosie town trip hands a ready reward to SilentRaven on the way back.
3. **Claim trip after (minutes, 0 = off)** (default 5): if a reward has been ready for 5 minutes and nobody went to Temis, SilentRaven asks Rosie for a town trip. This only happens in the open world (like a Helltide), not in a Pit, Undercity, Horde or lair. Set 0 to turn it off.
4. **Priority pick**: choose which reward caches you like best.

In the console you see one line per decision, for example `[SilentRaven] reward ready`, `claiming the Whisper reward (...)`, `reward ready but skipped because ...`.

### 5.8 Rosie as a service

Rosie runs next to every activity. You do not start her per activity. She:

- picks up loot by your **Pickup rules**,
- goes to Temis when the bag is full or gear needs repair,
- sells, salvages, repairs and stashes, then brings you back.

Activity plugins wait for her while she works. If you want a trip now, press **Run town service**.

### 5.9 Batmobile

Batmobile moves your character for the other plugins. See [3.3 Batmobile basics](#33-batmobile-basics). Use **Reset batmobile** if the bot keeps walking into the same wall.

---

## 6. Troubleshooting (FAQ)

**Rosie says "Another pickup or town addon loaded. Unload it, then reload Rosie."**
You still have Alfred or Looter in your `scripts` folder. Remove every Alfred / Looter folder (see [step 6 of the install](#2-install-or-update)). Reload QQT.

**Rosie stopped and does nothing.**
1. Check **Enable Rosie** is ticked.
2. Look at the status text at the top of the Rosie menu. It says why.
3. Fix the cause (for example a full stash).
4. Press **Run town service** to try again. A failed trip is retried after 120 s; after three failures Rosie waits for **Run town service**.

**The bot just stands still.**
- Is the activity plugin enabled? Is your combat script running?
- Under WarPigs: read the status line at the top of the screen. It may be waiting for Rosie, for an activity to finish, or for a plugin you paused with its own hotkey.
- Is a second activity plugin on? Only one runs; the other waits.
- Helltide: is it the 55–59 minute break (UTC)?
- Try the Batmobile **Reset batmobile** key.

**Two plugins teleport back and forth.**
You have two activity plugins on, or you started an activity plugin while WarPigs runs. In Mode B keep only one activity plugin on. In Mode A leave all activity plugins off and let WarPigs switch them.

**WarPug does not reroll.**
Capture the **Reroll** and **Confirm** positions again (section 4.2), or restore your `positions.txt`.

**A Horde step spent a compass.**
Check WarPigs: **Hordes: enter via War Plan teleport (no compass)** ON and **Allow compass entry if the War Plan teleport fails** OFF.

**Where are the logs and what do I send?**
- Everything the plugins say goes to the **QQT console**.
- To report a problem, copy the **whole console log** from the start of the session to the problem (not just the last line).
- Say which mode you used (A or B), which plugins were on, and what you expected.
- Useful extras:
  - Rosie: **Display and diagnostics → Log item and service decisions** prints what she decided about nearby items.
  - SilentRaven: **Debug logging**.
  - HelltideRevamped: **Debug settings → Draw chest status**.
  - WarPigs: **Verbose logs**.
- The list of important log lines is in `LIVE_CHECKLIST.md` (in the release zip).
