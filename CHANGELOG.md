# Changelog

All entries are in English. QQT_Warpigz_v2 release numbering starts with **2.0.0**. Earlier component versions and the imported Git baseline are not earlier releases of this project.

## [3.3.0] — 2026-09-27

![QQT Warpigz Suite v3](https://raw.githubusercontent.com/forsagaxeno-afk/QQT_Warpigz_v2/claude/qqt-diablo4-plugins-orchestrator-4439v5/assets/branding/qqt-warpigz-suite-v3.png)

**QQT_Warpigz_v3 3.3.0** adds **WarRoom**, an 11th plugin: one live dashboard for the whole suite, viewable on this PC or from your phone / another PC on your home network or VPN. It works under WarPigs and when you run a single farm plugin by hand. The Helltide map moves into it as a tab.

### Upgrade from 3.2.x

- Copy **all 11 folders** now (new: `WarRoom`). Menu settings are kept. Keep `WarRoom/data/` when you update to keep all-time totals.
- HelltideRevamped no longer has its own `dashboard` pages; the Helltide map is WarRoom's **Helltide** tab. With WarRoom loaded, HelltideRevamped feeds it automatically.

### Added

- **WarRoom 1.0.0** (menu *Z | War Room | Dashboard*: Enable on, Write every 15 s, reset Session / Today / All time):
  - **Overview**: what the bot is doing now (activity, step, progress), alerts, activities done / started, gold and XP (per hour), items looted by rarity (Mythics detected properly), deaths, busy time; an activities table with success rate, average and best time; items by rarity, greater affixes and what happened to them (stashed / salvaged / sold / kept); a "what ran when" strip; gold/hr and XP/hr charts; latest events and notable drops.
  - Tabs: **Helltide** (figures + the map), **Pit**, **Undercity**, **Hordes**, **Bosses**, **Whispers**, **Items** (filters), **Timeline** (filters), **Bot** (health card per plugin, alerts).
  - **Session / Today / All time** scopes; live / stale / offline banners; three themes (**Forge**, **Daylight**, **Console**) switched at the top.
  - Open `WarRoom/dashboard/index.html`, or run `WarRoom/server/serve.bat` and open `http://127.0.0.1:8765`. **From your phone or over VPN**: `serve-lan.bat` (read-only, only the dashboard folder, private networks only, access token link; allow the firewall prompt for *Private networks*). Nothing is downloaded from the internet and no account or character names are written.
- **Event bus** in every plugin (`qqt_events.lua`): plugins report runs, kills, chests, pickups, town trips and Whisper claims. Without WarRoom it does nothing.

### Rosie 1.0.18: a clearer Keep menu

- **Keep, storage & town** now reads top to bottom, first match wins: **1. Always keep** (Always keep Mythics; Keep Uniques with Item Power ≥; *Unique items I always keep* — both plain and Mythic form, always active, the old "Use unique/mythic filter" switch is gone) → **2. In-game loot filter** → **3. Junk** → **4. Uniques** (GA keep, Ancestral / Non-Ancestral actions, *Uniques to salvage or sell*) → **5. Legendary, Rare, Magic, Common** → **6. Seals** → **7. Charms** → **8. Storage** → **9. Town trips**. Options that only matter when another is off are shown only then. All saved choices carry over.
- Season 14 re-issued Iconic Mythics have one row per name in *Iconic Mythic items to keep* and match by name.
- Pickup takes an item checked in a keep list whatever the GA sliders, minimum rarity or in-game filter say (a full bag still refuses it).
- Every Unique / Mythic decision is logged once: `[Rosie] Kept … / Will salvage … / Will sell …`.

### Changed

- WarPigs 1.1.6, WarPug 1.0.15, Batmobile 2.2.1, ArkhamAsylum 2.1.2, HelltideRevamped 2.6.0, HordeDev 2.2.4, Reaper 1.10.3, WonderCity 2.2.3, SilentRaven 0.2.5, Rosie 1.0.18: report their events to WarRoom (no behaviour change).

### Needs a live check

- Gold and XP readers (`get_gold`, experience / paragon) are documented but new to this suite: the page shows "n/a" if the host cannot read them.
- `serve.ps1` on Windows PowerShell 5.1 and the Windows Firewall prompt in LAN mode.

### Validation

- `python3 audit/tests/run_tests.py --luajit require`: 93 test files × (Lua 5.4 + LuaJIT), 186 runs, 0 failures. New: `test_qqt_events_bus`, `test_qqt_events_joint`, `test_warroom_collector`, `test_warroom_joint` (full War Plan day with every plugin + WarRoom; counters checked against the event log; WarRoom absent / disabled / broken never changes bot behaviour), `test_warroom_dashboard`, `test_warroom_server`, `test_release_layout`. All dashboard pages rendered in headless Chromium (3 themes × 10 tabs × 2 widths) with no errors.
## [3.2.5] — 2026-09-27

**QQT_Warpigz_v3 3.2.5**: Rosie 1.0.17 hotfix. Replace the `Rosie` folder; settings are kept.

### Fixed

- **Rosie stopped after updating to 3.2.4 without restarting QQT** ("Host error: settings.lua:221: attempt to index field 'unique_ip_keep_slider' (a nil value)"). After a Lua reload Rosie reuses its previous menu widgets, and the new *Keep Uniques with Item Power >=* slider was missing from them. The missing widget is now created on reload, and the setting is read nil-safe.

### Validation

- New case in `test_rosie_keep_checked_324.lua` (reload with a pre-3.2.4 cached menu) fails on 3.2.4 and passes now; Rosie test files pass on Lua 5.4 and LuaJIT.

## [3.2.4] — 2026-09-27

**QQT_Warpigz_v3 3.2.4**: Rosie 1.0.16 can keep Uniques by item power, never salvages a checked Unique in its Mythic form, and does much less work on talismans. Replace the `Rosie` folder; settings are kept.

### Added

- **Keep Uniques by item power** (Rosie → town Keep settings → *Ancestral*, under *Unique Greater Affix*): *Keep Uniques with Item Power >=* for plain Uniques (0 = off, the default; 900 keeps max-power items; Mythics follow the Mythic rules). They win over the GA sliders, Salvage / Sell and *Pick up every Unique → Plain Uniques: Drop*. An item whose item power the game does not report is not affected.

### Fixed

- **A checked Unique could be salvaged in its Mythic form** (*unchecked Mythic Uniques* = Salvage with *Use Mythic Unique filter* on). A Unique checked in *Unique items* or in *Mythic Uniques to keep* is now kept in both forms, in town and by *Plain Uniques: Drop*; a name checked in the lists also matches its Season 14 re-issue.
- **Always keep mythics wins** over *unchecked Mythic Uniques* = Salvage / Sell: while it is on, every Mythic (Mythic Uniques included) is kept. The tooltips say so.
- Rosie logs each item a keep rule keeps once: `[Rosie] Kept <name>: <reason>` (for example `item power 925 >= 900`).
- **Talismans: less work, no repeated log lines** (live: game crashes while Rosie handles charms and seals; `[Rosie] Charm kept: ...` repeated every 15–50 s). The charm and seal counts are recounted only when the talisman bag or a talisman setting changes (or every 30 s), not every second, so an open bag or menu no longer reads every talisman's affixes each second. `Seal kept` / `Charm kept` / `Kept` lines appear once per item and reason per game session, also across a Rosie reload.

### Validation

- New `test_rosie_keep_checked_324.lua` (town sell / salvage decision and the Drop sorter; 7 cases) and a new `test_rosie_seal_q10.lua` case (bag and menu open with 23 talismans: 4.6 item reads per talisman per second on 3.2.3, 0 on 3.2.4; one keep line across a reload) fail on 3.2.3 and pass on 3.2.4. `test_rosie_contract.lua` now pins the new precedence. Rosie tests pass with `python3 audit/tests/run_tests.py --luajit require` on Lua 5.4 and LuaJIT; `python3 audit/check_release.py --base HEAD` passes.

## [3.2.3] — 2026-09-27

**QQT_Warpigz_v3 3.2.3**: HelltideRevamped 2.5.2 makes the in-game stats overlay readable and configurable. Replace the `HelltideRevamped` folder; settings are kept (the overlay position resets to the new default once).

### Added

- **Overlay appearance** (HelltideRevamped → *Live data & stats*): *Anchor* (top left / top right / bottom left / bottom right), *Offset X/Y (%)*, *Font size* (15), *Layout* (Two columns / One column), *Width (px, 0 = auto)*, *Colors* (Bright / Classic / Minimal), *Accent* (Cyan / Gold / Green / Red / Purple / White), *Background opacity (%)* (25), *Show bars*, *Compact layout*, and a toggle per section (Helltide timer, Wave, Cinders, Now, Target, Stats table, Opened this wave).

### Fixed

- **Overlay text was almost invisible.** The host draws text under filled rectangles, so the old dark 80 % panel dimmed every label to about 20 %. The default panel is now light (25 %) and text has a dark shadow / outline; titles are bold; bars and dividers sit on their own rows; values align in columns from the font size; the panel is only as tall as the sections you show. The new two-column default sits top left above the party frames at 1080p and up.

### Validation

- `python3 audit/tests/run_tests.py --luajit require`: 84 test files × (Lua 5.4 + LuaJIT), 168 runs, 0 failures. `test_helltide_overlay` checks anchors, offsets, font sizes 10–28, section toggles, contrast of every preset and no overlap between rows.

## [3.2.2] — 2026-09-27

**QQT_Warpigz_v3 3.2.2**: WonderCity 2.2.2 fixes Undercity runs stuck on the first floor. Replace the `WonderCity` folder; settings are kept.

### Fixed

- **WonderCity no longer gets stuck on Undercity floor 1** (live: "failed to leave floor 1, whole lot of back tracking"). Since 3.1.0 one failed walk to the floor exit (`X1_Undercity_PortalSwitch` / `X1_Undercity_WarpPad`) or to the Grand Spirit Beacon skipped it for the rest of the floor — even when the failure was only Batmobile's 15 s cooldown after a failed pathfind, or a long fight. The bot then explored until the run timed out. Now a failed walk sets the exit or beacon aside for 20 s, then 40 s, then 60 s at most and tries it again (`... exploring for Ns before trying it again (attempt n)`); optional Spirit Hearths are still skipped for the floor.

### Notes

- Rosie: a plain Unique hidden by the in-game loot filter is skipped while *Respect Ingame Loot Filter* is on (default), also with *Pick up every Unique*; only Mythics are exempt. This is by design; turn that option off or let your in-game filter show Uniques.
- WonderCity's Batmobile priority *direction* backtracks less than the default *distance*.

### Validation

- `python3 audit/tests/run_tests.py --luajit require`: 84 test files × (Lua 5.4 + LuaJIT), 168 runs, 0 failures. New joint-host cases B7 in `test_wondercity_bounds` (real Batmobile, closed floor: one-time rejection, long fight, beacon before the switch) fail on 3.2.1 and pass now.

## [3.2.1] — 2026-09-27

**QQT_Warpigz_v3 3.2.1**: HelltideRevamped 2.5.1 — the web dashboard has a new look, in **three themes** you pick from the bar at the top of the page (remembered in your browser). Replace the `HelltideRevamped` folder; settings are kept.

### Changed

- **Web dashboard redesigned** (`HelltideRevamped/dashboard/index.html` opens your last theme):
  - **Forge**: warm dark war-table, a sidebar with a cinders gauge and ring countdowns, the map as the main area, stats in tabs.
  - **Daylight**: light HUD (with its own dark toggle), an hour strip with chest-reset ticks and a "now" needle, an activity timeline, stats as bar charts.
  - **Console**: amber tactical console, a full-width map with HUD panels over its corners, stats and logs in two columns.
  Same data and features in every theme (countdowns, cinders vs goal, chest counts, map with pan / zoom / Fit / Border / Coords / Follow / filter / background image, Now, stats, opened this wave, events, history, performance). The 3.2.0 design is gone.

### Validation

- `test_helltide_dashboard` checks all three theme pages (every data field read exists, no external resources) and the entry page.

## [3.2.0] — 2026-09-27

![QQT Warpigz Suite v3](https://raw.githubusercontent.com/forsagaxeno-afk/QQT_Warpigz_v2/claude/qqt-diablo4-plugins-orchestrator-4439v5/assets/branding/qqt-warpigz-suite-v3.png)

**QQT_Warpigz_v3 3.2.0**: HelltideRevamped 2.5.0 gets a simpler **Smart farm** menu that follows the way you farm a Helltide, a live **web dashboard** with a map, a redesigned **in-game overlay**, and a fix for the bot fighting ordinary monsters next to a chest for minutes. New: a step-by-step English user guide, `docs/GUIDE_EN.md`. Only the `HelltideRevamped` folder changed; replace it (or all ten folders). Settings are kept.

### Changed

- **One "Smart farm" menu in Farm mode**, in the order you play:
  1. **Goal**: *Farm cinders until* (new, **on**, *Cinders* **2000**; a value you saved earlier is kept), then open chests in this order: Hell's Prize (666, when you took that War Plan node) > Mystery (250) > the rest, nearest first. *Spend all in the last (min)* (5) spends what you hold before the Helltide ends. With the goal off, *Keep 250 for a Mystery chest* and *Max carry above reserve* work as before.
  2. **How to farm: tears first**: *Hunt tears*, *Stand on chargeable tears*, *Fight Realmwalker*, *Open tear chests*, *Skip legacy Helltide events*.
  3. **Movement and logic**: *Smart chest order*, *Road routing*, *Learn while farming*, *Stay inside the Helltide*, *Pin the target on the map*, *Forget learned data*.
  4. **Advanced**: every tuning slider (tear search and pass-by distance, ritual stay radius, hold-area tolerance, linger, Realmwalker wait, pause tears at cinders, max carry, event radius, events until minute).
  When WarPigs runs Helltide, the menu says so and shows the Warplan options (*Spend cinders on chests at* keeps its own *Spend all in the last (min)*).
- **In-game overlay** redesigned: Helltide ends, wave, cinders (+/min, /hr, bar to the goal, earned / spent / lost), Now, Target, Stats (this Helltide / session / all time), Opened this wave. Rebuilt at most 4 times a second.
- **Web dashboard** (`HelltideRevamped/dashboard/index.html`, open it from disk after turning on *Web dashboard*): chest-reset and Helltide-end countdowns, cinders vs goal, chest counts, a map (patrol road, learned Helltide border, player trail, target line, chests labelled with id, name, cost and coordinates; pan, zoom, Fit, Border, Coords, Follow, site filter, optional background image calibrated by two clicks), Now panel, stats table, chests opened this wave, history and performance.

### Fixed

- **Farm mode: the bot no longer fights ordinary monsters next to a chest for minutes.** *Farm Cinder Threshold* (farm around an almost affordable chest, with no time limit and no tear search) also ran in Farm mode; it is now Warplan only. And a steady stream of plain monsters could hold the bot in one spot for 4–5 minutes: after 25 s of fighting within 45 m of one spot it now moves on along the patrol road (plain monsters skipped for up to 45 s or 50 m; elites, champions and bosses are still fought), so it keeps finding tears.
- The overlay and dashboard no longer show a finished cinder run's plan or target under WarPigs / Warplan.

### Needs a live check

- Map orientation on the dashboard (world drawn rotated 45°), overlay fit at your resolution, the 25 s / 45 m / 50 m move-on numbers in real monster density, whether 2000 cinders is reachable in a typical hour.

### Validation

- `python3 audit/tests/run_tests.py --luajit require`: 84 test files × (Lua 5.4 + LuaJIT), 168 runs, 0 failures. New: `test_helltide_smart_farm_flow`, `test_helltide_overlay`; extended `test_helltide_dashboard`.

## [3.1.1] — 2026-09-27

**QQT_Warpigz_v3 3.1.1** is a bug-fix release on top of 3.1.0: two minor issues found by the post-release integration audit. Upgrade by replacing the `SilentRaven` and `Rosie` folders (or all ten, as for 3.1.0); settings are kept.

### Fixed

- **SilentRaven 0.2.4: no claim trip while HelltideRevamped walks to a ritual ring.** The claim trip treated HR's `MOVING_TO_RIFT` state as idle (its busy list matched only states starting with `RIFT_`), so a due trip could pull the player to Temis on the way to a rupture. Any HR state naming a rift now counts as busy; the trip waits and runs after the rupture.
- **Rosie 1.0.15: the tear event loot window no longer walks back to drops Rosie already settled.** `LooteerPlugin.evaluate_item(item, true)` (distance ignored, used by HelltideRevamped's post-event loot window) now refuses a drop pickup has settled or exhausted (not one merely resting between rounds) with the reason `pickup settled/exhausted`. Ghost drops the host still lists (for example a Tuning Prism already in Materials) are skipped and the summary counts them as taken (`4 drop(s) walked to, 0 given up` instead of `0 walked to, 4 given up`).

### Validation

- `python3 audit/tests/run_tests.py --luajit require`: 82 test files × (Lua 5.4 + LuaJIT), 164 runs, 0 failures.
- New regression cases, each checked to fail on the 3.1.0 code: `test_silentraven_q8` (S1b, no claim trip in `MOVING_TO_RIFT`) and `test_helltide_tears_joint` (3.1.1, settled drops skipped by the loot window, correct counts).
- `python3 audit/check_release.py --base 9a4e317`: PASS.

## [3.1.0] — 2026-09-27

![QQT Warpigz Suite v3](https://raw.githubusercontent.com/forsagaxeno-afk/QQT_Warpigz_v2/claude/qqt-diablo4-plugins-orchestrator-4439v5/assets/branding/qqt-warpigz-suite-v3.png)

**QQT_Warpigz_v3 3.1.0** is a public release. Every plugin was audited on its own (the activity plugin + Rosie + your combat script, no WarPigs / WarPug) and under WarPigs. This fixes the 49 defects the overnight audit confirmed and the 10 issues reported from live play; each fix has a regression test that fails on the old code. HelltideRevamped gets a **Smart farm** for Farm mode, a **cinder run**, tears the bot really closes, and loot collected after the tear event. All credits for the original foundation go to **@ZEWX — LONG LIVE LEGEND**.

### Upgrade from 3.0.0

- Close QQT. Back up `WarPug/positions.txt` (your Reroll / Confirm positions) first. The package ships it uncalibrated.
- Replace the ten plugin folders (`WarPigs`, `WarPug`, `Batmobile`, `ArkhamAsylum`, `HelltideRevamped`, `HordeDev`, `Reaper`, `WonderCity`, `SilentRaven`, `Rosie`) with the ones in the zip's `scripts/` folder, then put your `positions.txt` back.
- Menu settings are kept. Keep your own combat / Orbwalker script.
- Coming from 2.x: follow the 3.0.0 notes first (delete the old folders with a version in their name, remove Alfred / Looter).

### Highlights

- **HelltideRevamped Smart farm** (Farm mode, no WarPigs needed; every part has its own option):
  - Mystery chests first, nearest along the patrol road.
  - A cinder plan that keeps 250 for a Mystery chest you can still reach.
  - Road routing for far chests.
  - Chest spots and the Helltide border learned while farming.
  - *Stay inside the Helltide*.
- **Live data & stats**:
  - On-screen stats (cinders per minute / hour, earned / spent / lost, chests, deaths).
  - An offline web dashboard.
  - An opt-in live Helltide zone (helltides.com or diablo4.life).
  - The Helltide hour now follows **UTC**.
- **Cinder run** (HelltideRevamped *Settings → Spend cinders on chests at*, default **off**, *Cinders* 3000, range 250–10000; needs *Open Helltide Chest*):
  - Once you hold that many cinders, the bot opens chests in this order: **Hell's Prize** (666; only there when you took the War Plan node *Hell's Prize*), then **Mystery** chests (250), then the rest, nearest first.
  - It uses chests in sight, remembered chests and learned spots, and stops below the cheapest known chest.
  - No new tear is hunted while the run has a chest to go to.
  - The run works in every mode (Farm, Warplan, under WarPigs).
  - **Save phase**: with the option on and HelltideRevamped on its own (Farm, or Warplan without WarPigs), chests below the threshold are remembered, not opened. The last minutes of the Helltide (*Spend everything in the last (min)*, at least 2) spend the savings.
  - Under WarPigs chests open as before, because the War Plan Helltide step ends once its cinders are spent. The run starts there only when you already hold the amount.
- **Tears** (Farm mode):
  - The bot stands inside each golden tear until it closes, then goes to the next one.
  - Time limits: at most 90 s inside one tear, 150 s per tear in all, 300 s per rupture.
  - No chest or pickup detour while it stands there. The tear chests are opened once the tear is closed.
- **Loot after the tear event** (Farm mode):
  - Rosie's pickup waits from the arrival at the rupture until the Realmwalker dies, or 10 s after the rupture completes with no Realmwalker.
  - Then the bot walks to each drop Rosie wants in the event area (at most 10 s per drop, 45 s in all) before moving on.
  - The walk to the rupture and back after a death are not paused.
  - WarPigs always runs Helltide in Warplan mode, which does no tears.
- **Rosie**:
  - The stash no longer stops on one item.
  - Rosie closes the stash / vendor panels she opened.
  - A *Splinter of the Prime Evils* you already carry is neither picked up nor sent to the stash.
  - The seal affix filter now decides seals.
  - Drops the host keeps listing after they were taken ("ghost" pickups, such as the Tuning Prism) no longer hold the farm.
- **SilentRaven claims Whisper rewards under WarPigs and standalone**:
  - Rosie's town trips hand a ready reward over on the return leg in both modes.
  - During a WarPigs activity, SilentRaven claims on that activity's Temis stops.
  - New *Claim trip after (minutes, 0 = off)* (default 5): a reward that waits that long with no Temis visit asks Rosie for a town trip from the open world (Helltide).
  - Enable SilentRaven in its own menu (it starts off).

### Changed defaults

- Rosie **Stash socketables** is now **When full** (was *Never*), so a full gems / runes bag goes to the stash. This applies to new installs and to a choice you never saved; a saved choice is kept.
- HelltideRevamped **Skip legacy Helltide events** (3.0.0's *Prefer tears over legacy Helltide events*, renamed; Farm mode, while *Hunt tears* is on, no pyres or flame pillars) is **on** by default again and uses its original setting, so your 3.0.0 choice is kept. The rc.1 test build had turned it off under a new setting.
- Rosie seals: while the seal **Use affix filter** is on with at least one affix checked, it decides seals **instead of the in-game loot filter**. A seal without your affix takes the *Seal default action*, even when the game filter shows it. Charms keep the old order: the in-game filter decides first.
- Rosie seals: a seal whose affixes cannot be read, or that lists none, is kept (it used to be salvaged when the list was empty). The console says why once.
- Rosie seals: unique (Annihilus) and mythic seals are still kept unless *Use unique/mythic seal filter* is on.
- SilentRaven **Claim trip after** is new and **5 minutes** by default; set 0 to turn it off.
- SilentRaven under WarPigs: while WarPigs' *Whispers in Temis* is on (default), a claim on a Temis stop during an activity does not need SilentRaven's own *Auto-fire in town*; WarPigs' option is the consent. SilentRaven itself must be enabled.
- HelltideRevamped **Spend cinders on chests at** is new and **off**; with it off nothing changes.

### Fixed

#### Rosie

- **Stash**: a rune / gem stack whose deposit the host did not confirm used to stop the whole service ("Transfer confirmation timed out … item kept unresolved"), and Rosie then waited for *Run town service*.
  - An item that leaves the bag now counts as deposited.
  - An item that still cannot be confirmed (8 s, or 3 attempts) is skipped for this trip, logged once, and the stash goes on with the next item.
  - A trip that still leaves the bag full is retried after 120 s instead of latching.
  - An unreadable item no longer becomes a host error that switches the town service off.
- **Panels**: the stash / vendor panel Rosie opened is closed at the end of each step and of each trip, including a failed or stopped one.
  - Rosie presses Escape only while the panel reads open, at most 3 times, never while chat is open.
  - A panel you opened yourself is never closed.
  - Pickup no longer stays parked on "menu_open".
- **Ghost drops**: a drop the host keeps listing after it was taken (Protector's Tuning Prism), or one Rosie cannot reach, is handled once with one line (`Took …` / `Leaving …`). It used to get 3 rounds (about 18 s) every time it came back into view.
  - Drops that fall during a fight keep their rounds and are collected after the fight.
  - Tuning Prisms count as Materials, so they are taken with a full consumable bag.
- **Splinters of the Prime Evils** (Terror, Destruction, Hatred: one of each per character) are skipped on the ground while you carry that kind (one line per zone) and never sent to the stash, which refuses them.
- **Seals**: with *Seal default action = Salvage* and the affix filter on (for example *+1 Charm Slot*), a seal without the affix is salvaged and a seal with it is kept, whatever the in-game loot filter shows.
  - A seal the host lists in the equipment bag follows the seal rules.
  - A seal kept against Salvage / Sell is logged once with the reason.
- **Crash with the menu open** on the 312-row seal affix list while hovering a seal: the per-frame work on that path is cut (menu preview at most every 0.5 s, list rows built once, bag slots cached for 0.5 s).
- Pickup pauses taken by other plugins expire after 60 s.
- A drop Rosie cannot take holds activities for at most 20 s.
- A failed town step no longer ends the trip at once.
- A trip requested from Kurast or Caldeum is served in Temis.
- Town selection tables are rebuilt at most once a second.

#### HelltideRevamped

- **Waypoint loop after a trap recovery** (live):
  - The other towns are scanned once per trap. If the abandoned zone is the only Helltide, the bot returns; a second trap in the same hour returns without another scan.
  - A return from inside the Helltide's zone really teleports; it used to log `Returning to known helltide zone` every few seconds without moving.
  - A new UTC hour forgets last hour's zone.
  - If the only Helltide cannot be reached by waypoint, the bot waits for the next hour instead of scanning.
  - After 3 empty scans in an hour, scans slow down to every 4 minutes.
- **Tears**: the bot left every tear after 12–18 s.
  - A 0–100 charge read as closed at 1 %.
  - A chest or a Rosie pickup pulled the player out of the circle.
  - A tear 25–30 m away bounced between two states without being approached.
- The Hell's Prize chest (666 cinders) is known; it used to log "no known cost, ignored".
- A Rosie refusal or a failed trip no longer freezes standalone farming.
- A waypoint refused 3 times is skipped for the hour.
- The Looter hold inside a Helltide is bounded (15 s without progress).
- Pyre / flame pillar events walk to the event they chose (the walk is bounded).
- A chest paid for by the bot's own click counts as opened.
- An interrupted teleport channel no longer counts toward the waypoint skip.

#### SilentRaven

- **No reward in a whole night under WarPigs** (live). WarPigs claimed only between activities, and Rosie's hand-off skipped a WarPigs-managed SilentRaven. Both are fixed; see *Highlights*.
- A complete objective counter (`10/10`, any language) or a progress of 1 now counts as ready.
- One console line per decision says why a ready reward was not taken yet (`reward ready but skipped because …`, `claim trip waits because …`, `[Rosie] no SilentRaven hand-off: …`).
- The console prints the real version (it showed v0.2.1).
- Readiness no longer depends on English quest text.
- Pit, Reaper, Undercity and Helltide wait for a running claim in Temis instead of teleporting away.
- *Debug logging* works.

#### WarPigs / WarPug

- WarPigs lets SilentRaven claim during its activities. Its status gains `whisper_handoff` and `activity_on`, both additive.
- The 55–59 off-window follows the UTC minute.
- WarPigs no longer adopts a Reaper left enabled from an earlier session.
- Repeated lines are logged once, and a missing plugin shows in the status line.
- With WarPigs off, a running activity pauses a WarPug session instead of halting it.

#### HordeDev, Reaper, ArkhamAsylum, WonderCity, Batmobile

- **HordeDev**:
  - A run left outside the Horde is reset instead of idling at the Caldeum gate.
  - The pylon pause of Rosie pickup is always released.
  - It prints about 13 times fewer console lines.
  - A stuck Rosie no longer stops chest opening.
- **Reaper**:
  - A stuck or refusing Rosie no longer traps it.
  - Altar clicks and chest retries are bounded.
  - After a death it walks back to the fight.
  - Less console spam.
- **ArkhamAsylum**:
  - In-Pit town trips work again.
  - Exploration waits for Rosie pickup for at most 15 s.
  - With Rosie, town trips go to Temis even with *Home town* = Cerrigar.
- **WonderCity**:
  - A boss sighting no longer stops exploration.
  - Walks to enticements, portals, warp pads and bosses are bounded.
  - The reward phase survives a script reload.
- **Batmobile**:
  - No false "trapped / giving up".
  - A progressing long route is not hijacked.
  - Evade in *unstuck* follows *Use evade*.
  - The Warlock's **Rampage** is offered in Movement Rules.
- **Standalone farming**: only one activity plugin runs at a time without WarPigs. A second enabled one waits and says why on its overlay.

### Needs a live check

- **Rosie**:
  - The `[interactable=…]` value on `Took` / `Leaving` lines for ghost drops.
  - No `Leaving X` line while enemies are close.
  - Whether a carried Splinter shows in the consumable bag with the same SNO.
  - Whether a second Splinter of another kind is still picked up.
  - Whether Liquid Rainbow follows the same one-per-character rule (inferred).
  - Which `Deposited … (stash list +0 | unreadable)` form the host gives.
  - That one Escape closes the stash, and that the game menu never opens after a trip.
  - No crash with the seal affix list open.
  - The reason on any `[Rosie] Seal kept` line.
- **Tears**:
  - The real circle size: the bot stops within 1 m and walks back beyond 2 m.
  - The charge scale (`Tear charge reads 0-100` appears once if it is 0–100).
  - Whether the Realmwalker spawns within 10 s.
  - That the loot pass leaves no drops behind.
- **Cinder run**:
  - The Hell's Prize actor name, and that opening it takes exactly 666 cinders.
  - The War Plan node read (`unknown` on non-English clients).
  - Very long first trips to a far remembered Hell's Prize.
- **Helltide search**:
  - A `4 returns to X without the Helltide buff` line would mean the waypoint town lies outside the Helltide area.
  - The 12 m "did not move" threshold of a same-zone return.
- **SilentRaven**:
  - The Season 15 Whisper quest name. `no Whisper quest (Bounty_Meta_*) in the quest list` means it is named differently.
  - Whether Helltide farming earns Grim Favor.
  - The `claim trip waits because …` reasons.
- From rc.1:
  - Whether unspent cinders vanish when the Helltide ends.
  - The chest reset minutes.
  - The Rampage cast.
  - `os.rename`, and helltides.com / diablo4.life reachability from QQT.

### Validation

- `python3 audit/tests/run_tests.py --luajit require`: 82 test files × (Lua 5.4 + LuaJIT), 164 runs, 0 failures.
- New regression files in this release (each case checked to fail on the pre-fix code):
  - `test_rosie_ghost_pickup`, `test_rosie_pickup_fight_q1`, `test_rosie_splinters_q9`, `test_rosie_stash_q5`, `test_rosie_panel_q6`, `test_rosie_seal_q10`
  - `test_silentraven_q8`, `test_silentraven_q8_bounds`
  - `test_helltide_search_cycle`, `test_helltide_tears_stand`, `test_helltide_tears_event`, `test_helltide_tears_joint`, `test_helltide_cinder_run`, `test_helltide_cinder_run_joint`
  - plus the rc.1 files listed under [3.1.0-rc.1] in `CHANGELOG.md`.
- Mutation runs on the new code (one fix reverted at a time): these tests catch every mutant except a few that do not change behaviour.
- `python3 audit/check_release.py --base c6433d8`: PASS.

## [3.1.0-rc.1] — 2026-09-27

Test build, released as a private draft (not published). Includes everything from 3.0.0. An overnight audit of every plugin, each checked **standalone for plain farming** (the activity plugin + Rosie + your own combat script, no WarPigs / WarPug) as well as under WarPigs, plus the HelltideRevamped *Smart farm*. Components: WarPigs 1.1.4, WarPug 1.0.14, Batmobile 2.2.0, ArkhamAsylum 2.1.1, HelltideRevamped 2.3.0, HordeDev 2.2.3, Reaper 1.10.2, WonderCity 2.2.1, SilentRaven 0.2.2, Rosie 1.0.13.

### Fixed

#### Rosie

- Pickup pauses taken by other plugins (HordeDev's pylon pause) expire after 60 s; a Rosie reload restores only its own pause, and turning pickup / Rosie back on clears the others. A pause left by a toggled-off or reloaded plugin no longer stops pickup for the rest of the session.
- A drop Rosie cannot take no longer holds everyone: each busy episode gets 20 s in which a drop must leave the ground, then the remaining drops rest 24 s (logged once). This bounds the live 12–39 s Helltide waits; why the item could not be taken is still open (the `[Rosie pickup] Gave up on <name>` line names it).
- A failed town step (for example `sell_failed`) no longer ends the trip at once: the remaining steps and the return portal still run, then the trip ends as failed. A request made in another town (Kurast, Caldeum) is served in Temis without a return leg; a trip whose services all finished and only the return portal was missing ends completed (one `[Rosie] return portal missing` line, no fail streak).
- On the return leg Rosie hands over once to SilentRaven when a Whisper reward is ready (auto-fire on, capped at 100 s, not counted in the 240 s service time).
- Town selection tables are rebuilt at most once a second (48 widget reads per call instead of 2,286).

#### HelltideRevamped

- A Rosie refusal or a failed / cancelled trip no longer freezes standalone Helltide farming in an Alfred retry loop: town service is latched off (`Town service unavailable (...) — farming on`) until Rosie reports it is no longer stuck; a stuck Rosie is never a hard need and the bag-count fallback is off while stuck.
- The trap-recovery "skip this zone" lasts one scan cycle; with no other Helltide active it returns to the known one (`no other Helltide found — returning to <zone>`) instead of never going back.
- A waypoint that is refused or silently ignored 3 times is skipped for the hour (`waypoint <zone> unreachable — skipping this hour`) instead of 99 teleport attempts.
- The Looter hold inside a Helltide is bounded: after 15 s of busy without the bag count rising, farming goes on (`Looter busy 15s without progress — farming on`); a productive multi-item pickup is never cut off.
- HelltideRevamped: **the Helltide hour follows UTC**. The plugin read the local minute, so in half-hour time zones (UTC+5:30, +9:30, -3:30) it idled in town for 5 minutes in the middle of every Helltide, searched during the real minute 55-59 break and stopped events at the wrong minute (`core/hr_clock.lua`).
- HelltideRevamped: a pyre / flame pillar event now walks to the event it chose, not merely the closest pyre or pillar of either kind (a spent one nearby could park the bot next to it for the rest of the Helltide). The walk is given up after 45 s and the whole event after 240 s; an event given up on is skipped for 180 s.
- HelltideRevamped: a remembered chest paid for by the bot's own interaction counts as opened even when the next tick sees the balance below its price (it used to read as "Cinders dropped below ..., aborting").
- HelltideRevamped: a teleport channel that was interrupted (the teleport buff was seen, the player is still in the zone it was fired from) no longer counts toward the 3 tries after which the search skips a waypoint for the rest of the hour (at most 5 interruptions per destination, logged `teleport to <town> interrupted`): a hit while channelling can no longer make the search skip the only active Helltide.
- HelltideRevamped smart farm (night review): the cinder plan counts the expected income only until the last minutes and, with 250 in hand and a reachable Mystery, lets no regular chest take the balance below 250 (a whole hour could pass without a Mystery); a buff flicker no longer cancels and blacklists a chest trip (the exit counts after 3 s without the buff) and a chest whose trip really left the Helltide twice is skipped for the rest of that Helltide; bad chest cells decay by the hour in any zone and across restarts; a Mystery opened before a chest reset and seen closed again after it is routed to again; a new Helltide's chest that spends the balance to exactly 0 is "spent", not "lost"; the first-session cinder rate starts from a plain average (one early pile no longer reads as 100+/min); Farm events run with the default menu (*Skip legacy Helltide events*, formerly *Prefer tears over legacy Helltide events*, now off by default); a diablo4.life answer without Helltide data falls back to helltides.com for the hour.

#### HordeDev

- A compass run left outside the Horde (failed Rosie return, relog, *Use alfred* off) is reset instead of idling at the Caldeum gate forever.
- With *Use alfred* off, HordeDev still yields to live town work and does not teleport to the Library during it.
- The pylon pause of Rosie pickup is released on toggle off, disable and reload, and bounded whichever task runs.
- Console: one horde prints about 217 lines instead of 2,877 (peak 11 lines a second instead of 60).
- A Rosie town trip during the reset, sigil activation or portal entry holds the transaction instead of faulting; *Pick Pylon delay* now applies to every regular pylon.
- A stuck Rosie is no hard need: chests keep being opened (`Rosie stuck: <reason>; farming on without town trips`).

#### Reaper

- A stuck or refusing Rosie no longer traps Reaper in an Alfred loop (`Alfred stuck (<reason>)` in the status; a refusal is retried after 30 s).
- Altar clicks that never summon are bounded (5 clicks / 30 s, then resync once or skip the boss); at most one "retrying open" cycle per chest; Belial is skipped while *Belial Chest* automation is off.
- A death after the summon walks back to the arena once and continues the fight (no restart from the entrance, no skip); no phantom summon from an old click; Kill Monsters gives up after 75 s without boss, enemy or chest.
- The tether anchor is never the world origin; Andariel and Harbinger anchors match the recorded arena endpoints. Less console spam (`Clearing path and target.` only when something was set).

#### ArkhamAsylum

- A plain in-Pit town trip teleports to town again (it was blocked by its own accepted request).
- Pit exploration yields to Rosie pickup for at most 15 s (not next to a live boss, never over the forced exit).
- With Rosie loaded, town trips go to Temis (the town Rosie serves) even with *Home town* = Cerrigar; Cerrigar still drives Pit entry and exit.

#### WonderCity

- A boss sighting no longer idles the explorers for the rest of the floor; after a revive the bot walks back to the boss.
- Walks to enticements, portals, warp pads and bosses are bounded (Batmobile rejects the target or 12 s without progress); an unreachable enticement does not use up *max enticement*.
- Exploration yields to Rosie pickup for at most 12 s per episode; the vendor-closed ACCEPT loop in town restarts at the brazier; the reward phase survives a script reload in the same Undercity.

#### SilentRaven

- Readiness no longer depends on English quest text (objective counters n/m, meta-quest inference; a wrong guess costs at most one probe per Temis visit).
- Activity plugins (Pit, Reaper, Undercity, Helltide) wait for a running SilentRaven claim in Temis instead of teleporting away and cancelling it.
- The *Debug logging* checkbox now logs state changes and hold reasons.

#### Batmobile

- False traversal ping-pong traps and the terminal *giving up* are fixed: escapes keep retrying every 15 s; the escape's own crossing is not counted as a reversal.
- A progressing long partial route is no longer hijacked by the stall escape; traversal routing uses the same height / direction filters as normal target selection; the post-traversal escape is bounded (3 s / 2 failed pathfinds).
- Evade in *unstuck* follows *Use evade*; movement rules skip skills that cannot be cast; hot-path console lines follow the logging level (Info: on change or once per 5 s).
- The free-roam debug explorer yields to Rosie pickup (bounded).

#### WarPigs / WarPug

- WarPigs' Helltide off-window (minutes 55–59) follows the UTC minute like HelltideRevamped; half-hour time zones were 30 minutes off.
- WarPigs no longer adopts a manual Reaper left enabled from an earlier session; the plan boss is started with `run_once` instead.
- *plugin not loaded*, preemption and same-activity opt-out lines are logged once per episode; a missing plugin shows in the status line.
- WarPug with WarPigs off: a running activity plugin pauses a WarPug session instead of halting it (`<name> running`).

#### Standalone farming (all activity plugins)

- **One activity at a time without WarPigs**: ArkhamAsylum, HelltideRevamped, HordeDev, Reaper and WonderCity share a lease (`_G.QQT_Warpigz_activity_lease`). The first enabled one runs; another enabled activity holds with a message on its overlay instead of both teleporting back and forth. HordeDev's *Run pit* hand-off still works; with WarPigs enabled the lease is not used.

### Added

- HelltideRevamped **Smart farm (Farm mode)**, every part behind an option, standalone (no WarPigs needed); WarPigs / Warplan keep the plain behaviour:
  - *Smart chest order*: Mystery chests first, seen chests before learned spots, nearest by patrol road, no ping-pong (hysteresis, at most 3 target changes a minute), an allowed chest right next to you taken on the way; after each chest reset (UTC :00/:15/:20/:30/:40/:45) fresh Mystery chests first again.
  - *Cinder plan*: 250 kept for a Mystery chest you can still reach, counting the expected income until the last minutes; regular chests when the reserve stays, when income refills it, above *Max carry* or in the last minutes.
  - *Road routing*: far chests (over 100 m) along the patrol loop the shorter way round; stuck off the road: back to the road and up to 3 other ways, the working one remembered. A failed smart trip is not picked again for 60 s; a chest the bot got stuck on 3 times in a Helltide is left alone until the next Helltide has passed.
  - *Learn while farming*: chest spots per zone (`learned/<zone>.txt`), predicted after two sightings; the Helltide boundary from the buff; chests trips got stuck on.
  - *Stay inside the Helltide*, *Event radius* (40 m, Warplan 12 m), *Events until minute*, *Pin the target on the map*, *Forget learned data (this zone)*.
- HelltideRevamped **Live data & stats**: an on-screen stats overlay (timers, cinders per minute / hour, earned / spent / lost, chests, deaths per Helltide, session and all time); an offline web dashboard (`HelltideRevamped/dashboard/index.html`, data rewritten every 10 s when on); an opt-in live Helltide zone (helltides.com or diablo4.life: the search teleports straight to this hour's region; off by default, one request at a time, a few per hour, back-off, nothing personal sent); *Reset all-time stats*. `HelltideRevampedPlugin.status().stats` (additive).
- Batmobile: the Movement Rules skill picker offers the Warlock's **Rampage**, found by its spell name among the equipped spells (revamp engine only; needs a live check).

### Notes

- **Not possible, and not faked:**
  - *Live chest locations from the internet*: no public source serves Helltide chest positions in world coordinates (helltides.com's chest maps are image pixels and site content), and the game API does not expose unseen chests. Chest spots are learned in game (seen chests, then predicted spots after two sightings); the live data used is only this hour's Helltide zone.
  - *A web dashboard served by the plugin*: QQT cannot run an HTTP server. The dashboard is a local page (`HelltideRevamped/dashboard/index.html`) that reads a data file the plugin rewrites.
  - *Pathing that learns the map*: the bot learns chest spots, the Helltide boundary and spots where trips got stuck, and reuses a working approach; it does not build its own navigation mesh (Batmobile still does the pathing).
- Needs a live check: whether unspent cinders vanish exactly when the Helltide ends (this decides the *lost* count); chest reset minutes and whether a Mystery chest respawns within the hour; Season 15 event skins; the Rampage spell name and cast; whether `os.rename` exists in QQT (without it saves write directly); whether helltides.com and diablo4.life are reachable from QQT's curl.
- Reaper: an altar that stays non-interactable for 30 s now skips the boss (raise `NOT_READY_BOUND` in `tasks/interact_altar.lua` if the live altar re-arms more slowly).
- Generated files (`HelltideRevamped/learned/*.txt`, `dashboard/hr_data.js`) are not part of the release package.
- Saves are bounded and careful: `<file>.tmp` first, replaced only when complete (the `.tmp` copy stays and is read back if the file itself cannot be written); an existing file that cannot be read (locked, over 1 MB) is never overwritten that session (*Forget learned data* / *Reset all-time stats* still replace it); three failed writes switch saving that file off for the session.

### Validation

- `python3 audit/tests/run_tests.py --luajit require`: 68 test files × (Lua 5.4 + LuaJIT), 136 runs, 0 failures; the largest function captures 48 upvalues (limit 60).
- New regression files, each case checked to fail on the pre-fix code: `test_rosie_night_v3`, `test_horde_standalone_farm`, `test_reaper_bounds`, `test_wondercity_bounds`, `test_silentraven_standalone`, `test_batmobile_nav_recovery`, `test_activity_lease_joint`; new cases in `test_integration_arkham`, `test_integration_helltide`, `test_joint_rosie` (R9, R10), `test_integration_horde`, `test_integration_silentraven`, `test_integration_warpigs_dispatch` (R1b–R3b, WPD-8b UTC minute) and `test_integration_warpug`.
- New offline tests: `test_helltide_clock`, `test_helltide_stats`, `test_helltide_cinder_plan`, `test_helltide_chest_order` (incl. the task-level event walk bound and skip, failed trips and bad chest cells, 3D distances), `test_helltide_roads`, `test_helltide_atlas_fence` (incl. unreadable zone files), `test_helltide_live`, `test_helltide_dashboard`, `test_helltide_standalone_smart` (joint host: HelltideRevamped + Rosie + Batmobile, a Farm Helltide), and a Rampage case in `test_batmobile.lua`. The scripted clocks of `joint_host.lua`, `test_integration_helltide.lua` and `test_helltide_modes.lua` answer the UTC minute (`os.date('!%M')`) too; the joint host reads back files written in the same run.
- `python3 audit/check_release.py --base HEAD`: PASS.

## [3.0.0] — 2026-09-27

![QQT Warpigz Suite v3](https://raw.githubusercontent.com/forsagaxeno-afk/QQT_Warpigz_v2/claude/qqt-diablo4-plugins-orchestrator-4439v5/assets/branding/qqt-warpigz-suite-v3.png)

**QQT_Warpigz_v3**: the public release of the 2.3.0 test builds, the first one since 2.1.3. All credits for the original foundation go to **@ZEWX — LONG LIVE LEGEND**. The Rosie author stays anonymous.

### Upgrade from 2.x (important)

- **Plugin folders no longer carry version numbers**: `WarPigs`, `WarPug`, `Batmobile`, `ArkhamAsylum`, `HelltideRevamped`, `HordeDev`, `Reaper`, `WonderCity`, `SilentRaven`, `Rosie`. Delete the old `WarPigs-1.0.0`, `WarPug-1.0.0`, `Batmobile-1.0.12`, `ArkhamAsylum-1.0.6`, `HelltideRevamped-0.4`, `HordeDev-1.3.9`, `Reaper-main`, `WonderCity-main` and `SilentRaven-0.1.3` folders first, or QQT loads two copies. From now on an update simply replaces the same folders.
- **Rosie replaces Alfred and Looter**: remove your old Alfred / SteroidAlfred / AlfredTheButler-WarPigz / LooteerV3 folders (Rosie stays off while another one is loaded). Rosie starts off: set your pickup and town rules, then enable it.
- Menu settings are kept (they are stored by the plugins' own keys, not by folder name).

### Highlights

- **Rosie**: one plugin for pickup and town service (sell, salvage, repair, Occultist, stash), used by WarPigs and every activity out of the box. LooteerV3-style pickup (rounds per drop, host Auto Loot switched off, walks around walls), Alfred-style stash handling (several open signals, confirmed deposits), bounded retries.
- **Mythic sorting**: a fresh drop shows no affixes until it is picked up once, so on the ground a Mythic Unique looks like its plain Unique. *Pick up every Unique (sort in the bag)* (default on) takes every Unique and Mythic and sorts them in the bag: Mythics (the Mythic upgrade affix, the 14 Season 14 iconic re-issues, rarity 8) are always kept; *Plain Uniques* go to town rules (*In town*) or are dropped on the spot and never picked up again (*Drop*). Favourites, the Unique filter, the GA override and *Always keep mythics* always win. *Use Mythic Unique filter* chooses which Mythic Uniques to keep.
- **HelltideRevamped**: *Warplan* / *Farm* modes; Farm hunts **tears** (kills the cultists, closes the tears, opens the chests, fights the Realmwalker). WarPigs always runs Warplan.
- **HordeDev**: takes the War Plan altar (The Black Pact) between waves; the Looter pause at a pylon is bounded.
- **WonderCity**: optional *Take the boss portal as soon as it opens*.

### Changed since 2.3.0-rc.14

- **TristramLoop is removed from the bundle** (it was only in the private test builds). If you installed it from a test build, delete its folder.

- Rosie 1.0.12: the *Item Types* list no longer shows categories that do not exist in Season 15 (Special / Basic / Advanced Elixirs, Cinders, Heavenly Sigil; they are never picked up). New-install defaults match the recommended setup: quest items, crafting materials, boss trophies, lair keys, charms, seals, soul splinters, reward caches, other consumables, scrolls, horde compasses, tributes, runes and event bags on; gemstones, fish and Nightmare Dungeon sigils off. Saved choices are kept.
- HelltideRevamped 2.2.2: after the trap recovery ("Batmobile gave up after 60s trapped") had reached town, returning to the same Helltide (the only active one) teleported out again every 15 s in an endless town ↔ Helltide loop (live). The recovery now ends in town and the next Helltide visit starts fresh.

### Validation

- `python3 audit/tests/run_tests.py`: all test files × (Lua 5.4 + LuaJIT) pass; new case in `test_integration_helltide.lua` for the town ↔ Helltide loop (fails before the fix).

## [2.3.0-rc.14] — 2026-09-27

Test build, released as a private draft (not published). Includes everything from 2.3.0-rc.13.

### Changed

- HelltideRevamped 2.2.1: the Farm-mode section is now **Tears (Farm mode)** (the Season 15 name): *Hunt tears*, *Prefer tears over legacy Helltide events*, *Fight Realmwalker*, *Open tear chests*. The Season 14 only options are removed from the menu (live report): *Prioritize Surging ruptures*, *Hunt Normal / Surging / Colossal ruptures*, *Enter Deathtoll Chamber* and *Log rupture scan hits*. Every tear found is hunted, the chamber is never entered and the scan log is off; the code paths stay for tests.

### Added

- Rosie 1.0.11: a pickup round that fails is logged with the drop's name: `[Rosie pickup] Retrying <name>: round n/3 failed (...)` and `[Rosie pickup] Gave up on <name> ...` (live rc.13: Helltide waited 12 s and 38.9 s for a drop Rosie could not take; the next log names it).

## [2.3.0-rc.13] — 2026-09-26

Test build, released as a private draft (not published). Includes everything from 2.3.0-rc.12.

### Fixed

- Rosie 1.0.10: **the game crashed** ("Diablo Tool Runtime Error, Crash detected") about 5-6 s after hovering an item with the bag open. The live console showed hundreds of `[Rosie mythic-probe] bag keep|salvage|sell ...` lines: every bag census re-logged every Unique (the line key included the salvage/sell pass, so it never repeated) and read extra native quality attributes for each. These diagnostic probes (ground and bag) now run only for 5 minutes after *Log item and service decisions*, and log one bag line per item reading. Mythic sorting itself does not depend on them.

### Validation

- New case in `test_rosie_unique_sorter.lua`: twelve Uniques in the bag for 20 s produce no probe line while playing (fails on rc.12), and with diagnostics on at most one bag line per item.

## [2.3.0-rc.12] — 2026-09-26

Test build, released as a private draft (not published). Includes everything from 2.3.0-rc.11.

### Fixed

- Rosie 1.0.9: the *Plain Uniques* choice overlapped its label in the menu (live screenshot). The options are now short: *In town* (default) and *Drop*; the tooltip explains both. Saved choices are unchanged (same widget, same order).

## [2.3.0-rc.11] — 2026-09-26

Test build, released as a private draft (not published). Includes everything from 2.3.0-rc.10.

### Added

- Rosie 1.0.8: **Pick up every Unique (sort in the bag)**, a new option right under *Enable Rosie* (default on), with **Plain Uniques**: *Handle in town (salvage/sell by your rules)* (default) or *Drop on the ground (no town trip)*. See "How Rosie sorts Mythics" below.
- Rosie 1.0.8: a list of the plain Uniques Rosie dropped on purpose, so pickup never takes them again (`dropped by Rosie (plain Unique)`, also returned by `LooteerPlugin.evaluate_item`).

### How Rosie sorts Mythics

**Why the ground cannot tell.** A Unique that has just dropped shows no affixes until somebody picks it up once (QQT documents this). A Season 15 Mythic Unique is the same item as the plain Unique (same name, same item ID, same rarity) plus one extra upgrade affix. So on the ground, before the first pickup, a fresh Leoric's Crown and a fresh Mythic Leoric's Crown read exactly the same. Once an item has been picked up, its bag copy lists every affix, and so does a copy dropped back on the ground (live dumps of Leoric's Crown and Condemnation).

**What the option does.** With *Pick up every Unique (sort in the bag)* on, Rosie picks up every Unique and every Mythic, whatever your Greater Affix sliders or slot overrides say, and sorts them in the bag, where it can see what they are. The log shows `accepted: every Unique is taken (sorted in the bag)`. Your bag space is still checked. A Mythic is picked up even if the in-game loot filter hides it; a plain Unique still follows *Respect in-game loot filter* (turn that off, or let your in-game filter show Uniques, to get every Unique). With the option off, pickup works as in rc.10 (the GA sliders decide on the ground; a Unique that might be a Mythic is still taken).

**How Rosie decides in the bag.** An item is a **Mythic** when any of these is true: it has the Mythic upgrade affix (`S14_Mythic_UniquePotency`, hash 2628989, or any affix whose name contains `Mythic`); it is one of the iconic Mythics, including the 14 re-issued in Season 14 (Harlequin Crest, Doombringer, Andariel's Visage, The Cow King's Crown and the others), which report rarity 6; or it reports rarity 8 or more. Any other rarity-6 item is a **plain Unique**. A Unique whose affixes are not readable yet is neither: it is kept and never dropped.

**What happens to plain Uniques.**
- *Handle in town* (default): nothing is dropped. Plain Uniques stay in the bag and the next town trip sells, salvages or keeps them by your town rules, exactly as before; Mythics are kept.
- *Drop on the ground*: outside town (any town the game marks as one, not only Rosie's home town), when no town trip is requested or running, a plain Unique that your town rules would sell or salvage is dropped where you stand, at most one item every 0.6 s. While the sorter can act, the plain Uniques it is about to drop do not count toward your bag limit, so a pile of them does not start a town trip. Before dropping it, Rosie writes it on a list: its item ID plus every affix and roll (the "fingerprint"). Pickup never takes a listed item again. The list keeps an item for 30 minutes and holds at most 200 items. It survives a town trip and the loading screen (a Pit, Undercity or lair you return to keeps it) and is cleared when you enter a different world (a new dungeon). If an item does not leave the bag within 2 s, Rosie tries twice more (a town trip or pause in between does not reset the count) and then leaves it for the town trip; it does not try that item again, even in the next dungeon. The sorter waits while chat or a vendor screen is open, while pickup is off or paused by another addon (activity loot holds), in any town, and during a town trip; it never makes Rosie report "looting" and never asks for a town trip. Mythics are never dropped and never listed; a ground item that reads as a Mythic is never refused because of the list.

**How it combines with your keep rules.** Rosie drops only what your town rules would sell or salvage anyway, so every keep rule still wins: *Always keep mythics* (and even with it off, the sorter never drops a Mythic: your Mythic rules decide in town); favourites (locked items are never dropped); *Use Mythic Unique filter* (Mythics only, decided in town); *Use unique/mythic filter* (a checked Unique is kept); the Unique Greater Affix override (an Ancestral Unique with at least that many GA is kept; the default 1 keeps every Ancestral Unique with a Greater Affix). Plain Uniques your rules keep are stashed on the next trip as before.

**Known limit.** Live dumps say a dropped copy lists its affixes, so the fingerprint is what normally recognises it. For a host where the dropped copy lists no affixes, there is a fallback: when Rosie drops an item it notes every item of the same kind already lying within 4 m, and the first NEW item of that kind that appears within 4 m in the next 5 s is taken to be the dropped copy. Only that one item is then refused, for up to 15 minutes. Items that were already on the ground and fresh drops that land later, including a fresh Mythic form of the same Unique, are picked up as usual. As soon as one dropped copy has been recognised by its fingerprint, the fallback is switched off for the session. A fresh drop of the same Unique landing within 4 m in those same 5 seconds could still be mistaken for the copy.

**Log lines to look at** (all start with `[Rosie sort]`): `Dropped plain Unique <name> sno=... fp=...` once per dropped item; `Kept Mythic <name> (mark=...) sno=...` once per Mythic in the bag while mode Drop is on (the mark names the affix, or says `S14 iconic`, `iconic Mythic`, `catalog Mythic` or `uber`; items with rarity 8 or more are never candidates, so they get no line); `Ground copy of <name> found by fingerprint|position: identifier bag=... ground=... matched=true|false` once per dropped item, naming the dropped copy itself (`position` means the fallback above bound it; whether the host keeps the item identifier across a drop is not known yet); `Drop of <name> refused by the host: ...` and `Could not drop <name> after 3 attempts; it is left to the town trip.` when dropping fails. *Log item and service decisions* adds a summary line: `every Unique= mode= state= blacklist= dropped= attempts= failed= left_to_town= kept_mythics=`. Pickup lines for a listed item end with `dropped by Rosie (plain Unique)`. With the option on, every Unique taken from the ground also logs `[Rosie mythic-probe] taken sno=...` (its ground reading).

### Changed

- Rosie 1.0.8: README ("Mythic sorting"), docs/INSTALL_RU.txt and README.md: version 1.0.8 and the new option; audit/LIVE_CHECKLIST.md: lines to collect for the drop and the identifier match.

### Validation

- `audit/tests/joint_host.lua`: `loot_manager.drop_item` (the item leaves the bag and a NEW ground actor with the same SNO, affixes and rolls and a new identifier appears at the player's position; opt-ins for a copy that lists no affixes and for a drop that errors, returns false or does nothing), combo boxes restore persisted values by hash like checkboxes, and `h.menu_labels` records rendered widget labels in order. The rc.10 scenarios predate the option: the joint host loads it saved OFF unless a test asks for the shipped defaults (`opts.shipped_defaults`); with the option ON, 11 rc.10 cases in `test_rosie_mythic_rc10.lua`, `test_rosie_contract.lua` and `test_rosie_pickup_rounds.lua` fail, as intended: 9 assert that the GA sliders skip plain Uniques on the ground, and 2 expect a `[Rosie mythic-probe] skipped` line for such a drop, which is now taken and logs `[Rosie mythic-probe] taken` instead.
- New `test_rosie_unique_sorter.lua` (10 cases, shipped defaults): the menu order and persisted values; option on with Unique GA 2 takes fresh, plain loaded and Mythic Uniques (loot filter kept for plain Uniques only; off restores rc.10); mode Drop keeps the Mythic, drops the plain Unique once and never takes it again (fingerprint, then the position fallback with a copy that lists no affixes, the 15/30-minute limits); the list cap, world change and Mythic refusal; locked, name-filtered and GA-override Uniques and a Mythic the rules would salvage are never dropped; the sorter is idle with chat, a vendor screen, a pickup pause, a town pause, pickup off, in town and during a town trip; a failing drop costs exactly 3 attempts and is left to town; dropped Uniques cause no town trip while mode Town fills the bag and triggers one; mode Town sells the plain Unique in town and keeps the Mythic. All 10 fail on 2.3.0-rc.10.
- Review fixes in the same file (7 more cases, each failing on the first rc.11 draft): R1 a boss pile of fresh drops (the ground copies list no affixes): the Mythic form lying next to the dropped plain copy is picked up and the identifier line names the real copy, both with a copy that lists its affixes and one that does not; R1b a fresh same-SNO drop 2 m from the spot 5 minutes later is taken, and an item already on the ground before the drop is never refused; R2 a town trip out of a Pit and back keeps the list and the dropped copy is not picked up again; R3 a given-up item is not retried in the next world, a town hold between attempts keeps the try count, and switching to mode Town with a drop pending forgets its entry; P3 a pile of 4 plain Uniques 1 m apart near the bag limit causes no town trip in mode Drop (mode Town still triggers one); P7 a Unique taken with the option on logs its ground probe; P4 mode Drop adds at most one bag read per 0.5 s scan. The idle case also covers Caldeum, Kurast and Cerrigar (only Temis counted as a town before), and the world-change case checks that a town and Limbo keep the list while a different world clears it.
- `python3 audit/tests/run_tests.py --luajit require`: all test files × (Lua 5.4 + LuaJIT) pass; `python3 audit/check_release.py --base HEAD` passes.

## [2.3.0-rc.10] — 2026-09-26

Test build, released as a private draft (not published). Includes everything from 2.3.0-rc.9.

### Fixed

- Rosie 1.0.7: **Mythic Uniques from Uber bosses could still be skipped or destroyed.** QQT documents that a ground item's affix list stays empty until the item has been picked up once, so a fresh Mythic drop reads like a plain Unique (live rc.8: `Skipped Helm | rarity=6 ancestral=true GA=0 ... threshold=unique_general:2` for Leoric's Crown, Stone of Jordan, Henri's Perquisition, Locran's Talisman, Endurant Faith and others). rc.9 treated a Unique as "loaded" once any affix named after the item was listed; that is not a loading signal, and Locran's Talisman and Endurant Faith never carry one. Now a Unique below its Unique Greater Affix minimum whose reading cannot rule out a Mythic (affixes unreadable, no affixes listed, or Ancestral reading 0 Greater Affixes) is picked up as `accepted: may be a Mythic Unique (...); decided in town`. A drop that lists no affixes, or whose affixes are unreadable, reads GA 0 whatever it carries, so no GA rule can judge it: it is taken whichever slider (Unique, slot override or Mythic GA) is stricter, and a known mythic in that state (an S14 iconic, rarity 8) is taken as `accepted: Mythic, Greater Affixes not readable yet`. An Ancestral Unique that lists affixes but reads 0 GA is taken only when the Unique rule is the stricter one. A known plain Unique (affixes listed, GA read, no Mythic mark) follows the Unique rule again.
- Rosie 1.0.7: *Respect in-game loot filter* could skip a mythic on the ground (rarity 8, an S14 iconic, a marked Unique); the town rules already exempted mythics. Pickup now never refuses a mythic for the loot filter.
- Rosie 1.0.7: the town could sell or salvage a picked-up Mythic whose bag copy read no affixes. A rarity-6 bag item that is not a mythic and whose affixes are unreadable or empty is now never sold or salvaged (it is stashed and checked again on the next trip).
- Rosie 1.0.7: the 14 iconic Mythics re-issued in Season 14 (Harlequin Crest, Doombringer, Andariel's Visage, The Cow King's Crown and the others; d4data: Unique magic type with the Mythic quality modifier forced) report rarity 6 and catalog quality "unique", so Rosie skipped them under the Unique GA minimum and could salvage them. They are now mythics for pickup (Mythic GA rule) and town (*Always keep mythics*).
- Rosie 1.0.7: the Mythic mark is the affix hash 2628989 (`S14_Mythic_UniquePotency`) or any affix whose name contains `Mythic` (keep direction only); the log names the matching affix. The live dump from this session (a tempered Leoric's Crown dropped from the bag: GA 1, affixes including `S14_Mythic_UniquePotency#2628989`, then `Wanted Leoric's Crown ... threshold=mythic_general:0`) is a regression case.
- Rosie 1.0.7: **the stash still might not open** (live rc.8: `Open stash: attempt=1..4 distance=1.9 host=true`, then `Stash window did not open after 4 interactions`, while the Blacksmith repair worked). The live log cannot tell which signal stayed silent, and rc.9's check (vendor-screen flag or a stable non-empty stash count, vetoed while any other vendor read as current) still failed with an empty stash, a silent flag, a `get_current_vendor()` that keeps naming the Blacksmith, or a stash list the host caches while the chest is closed. The stash chest is now observed as open when the inventory panel is open, the stash list reads the same twice, or the vendor-screen flag is up while no other NPC reads as the current vendor; these signals count only after this trip has interacted with the chest, and a signal that was already up just before the first interaction (a stash list the host caches while the chest is closed, an inventory panel the player left open, a flag raised by another panel) is ignored. A deposit that moves nothing stops trusting the signals until a fresh interaction. Rosie walks to within 2 m of the chest before interacting (as Alfred and the NPC tasks do; within 3 m it interacts after 1.5 s without getting closer), re-interacts every 0.3 s for 2 s after each attempt (as Alfred does), prefers a Stash actor the host reports interactable, and, when no signal shows, sends one deposit per attempt as a probe that counts only when the bag and stash change; no probe is sent while an NPC panel that was open before the interaction still reads open, and `vendor.is_open('STASH')` is false while another NPC panel reads open. Still at most 4 attempts, 3 transfer attempts per item and 45 s without progress.
- Rosie 1.0.7: **queued stash pulls failed** (`stash_pull_failed` on the rc.9 stash model; not changed in rc.9): the pull required `get_current_vendor()` to name the stash and sent `move_item_from_stash` through the NPC vendor gate. It now uses the stash rule above, goes ahead 2.5 s after the interaction whatever the signals say (as Alfred does), calls `move_item_from_stash` directly (at most 3 calls per item per interaction), interacts again when nothing arrives within 2.5 s (at most 3 times), and re-reads a stash list that lags the panel for 3 s before calling a queued SNO missing. Sell, salvage, repair and talisman salvage keep the live-proven NPC identity check.
- Rosie 1.0.7: **a queued stash pull could destroy a stashed Mythic.** The queue salvages or sells every copy of a queued SNO, and an S15 Mythic form shares its Unique's SNO (the S14 iconics can be queued by SNO too). The pull now leaves in the stash every copy the town rules keep as a mythic while *Always keep mythics* is on (rarity 8+, the mythic list, the S14 SNOs, the Mythic mark, a mythic seal), every Unique whose affixes cannot rule out a Mythic form and every unreadable item; it logs `Kept in the stash: sno=...`, names them in the failure reason when nothing else was queued, and checks the bag copy again before the sell or salvage call.
- Rosie 1.0.7: **pickup gave up on drops too early.** A drop got 5 interactions or 12 s of selection (counted even while a fight kept the player busy) and was then skipped until it left the ground. Pickup now works in rounds like LooteerV3: walk to the drop, interact every 0.15 s within 2 m; a round ends after 30 interactions or 6 s without getting closer, the drop rests 8 s while other wanted drops go first (with none waiting, its next round starts at once, so the busy flag stays up and activity loot holds such as Reaper's, HordeDev's, WonderCity's and Arkham's keep waiting for it), and after 3 rounds it is skipped.

### Changed

- Rosie 1.0.7: pickup switches the host's Auto Loot off on every pulse while it runs (LooteerV3 does the same), so the host never walks to drops Rosie refuses. The host has no getter, so the previous value cannot be restored.
- Rosie 1.0.7: when the host ray cast (`utility.is_ray_cast_walkeable`) reports the straight line to a drop blocked, pickup plans waypoints around the obstacle with a bounded A* search (at most 1500 nodes; the host is asked about each cell once per plan; a diagonal step never cuts a wall corner) and walks them with `request_move`, passing a planned waypoint within 0.6 m. "No path" is cached per drop, so such a drop is planned once. A found path is reused only near the spot it was planned from; from elsewhere (after a pause, a round or a movement recovery) the drop is planned again, at most 4 times, and after that the cached path resumes at the nearest waypoint the ray cast can reach. The cache is dropped when the world changes. Town movement never plans; no engine path and no map pin are used.
- Rosie 1.0.7: diagnostics. Pickup lines for Uniques show `mythic_mark=<affix|false> undecided=<reason|no> affixes=<n|unreadable>` (replaces `details=`). `[Rosie mythic-probe] skipped|taken` lines record how a Unique reads on the ground (name, display, ancestral, sacred, `qbits` = `Item_Quality_Modifier_Bits`, quality level, GA attribute, item power, affixes, mark; at most 3 per drop, one per second), and `[Rosie mythic-probe] bag keep|sell|salvage` lines record every Unique in the bag with Rosie's decision (once per reading, table capped at 256). `Item_Quality_Modifier_Bits` is logged only and never decides anything. The `Open stash` line now also shows the chosen actor, `interactable=` and every stash signal (`sdk= inv= vendor= stash_n=`); a `Stash reads open: signal=inv|count|sdk|receipt attempt=N ...` line names the signal that decided, probe deposits are tagged `probe=true`, and the `did not open after 4 interactions` and `No transfer observed` failures carry the signals.
- Rosie README, docs/INSTALL_RU.txt and README.md: version 1.0.7, pickup rounds, Auto Loot off, the may-be-a-Mythic rule and the stash behaviour.

### Corrected

- rc.9 said "once loaded, every Unique carries its own Unique power affix". That is false: in the game data many Unique equipment definitions carry a Unique power that is not named after the item (among the Uber drops: Locran's Talisman, power affix `S05_BSK_Generic_009`, and Endurant Faith, `S05_BSK_Generic_001`), so rc.9 always took those two as "details not loaded" and printed `details=hidden` for loaded copies.

### Validation

- `audit/tests/joint_host.lua`: opt-in stash variants (sticky current vendor, inventory flag, cached stash list, a chest that never opens or opens late, short reach), a working `move_item_from_stash`, walls for the straight-line mover and the ray cast, an Auto Loot mock, and item `display`/`attrs` fields.
- New `test_rosie_stash_rc10.lua` (21 cases), `test_rosie_mythic_rc10.lua` (the decision matrix S1–S10, undecided reasons, the mark, the live Leoric's Crown dump, Locran's Talisman, the town guard, probe bounds) and `test_rosie_pickup_rounds.lua` (busy player, 15 s fight, bounded skips, wall detour, walled-in drop planned once, ray cast error, Auto Loot off, details loading mid-approach); `test_rosie_contract.lua` gains the rewritten S15 Mythic case and a new S14/probe case. Every assert aimed at a defect was run against 2.3.0-rc.9 and fails there (stash C, D, E, F2, I, P and the diagnostic line; mythic matrix S1 town, S2, S4, S7, S9, S10 town; the town guard; the S14 SNOs; the `Mythic`-word mark; the describe and probe lines; pickup E1, E2, E6, E7, E8); the rest are guards that pass on both.
- Review of the merged rc.10 build: regressions R-F2, R-F4, R-F5/F7, R-F6, R-F8, R-F9 (`test_rosie_stash_rc10.lua`: same-SNO Mythic form in a pull, cached stash list with a late chest, a player-opened inventory panel, reach 1.8 m from the spawn, a D4-like inventory flag beside an open Blacksmith panel, the deciding-signal line, late chest and lagging list for pulls), fresh drops under Mythic GA 1–3 and slot overrides plus the loot-filter exemption (`test_rosie_mythic_rc10.lua`), and R-E10–R-E13 (`test_rosie_pickup_rounds.lua`: continuous busy flag with Reaper's `loot_ready` during a 10 s and a 15 s fight, the wall detour over 5 speeds × 3 starts with every planned leg walkable, re-planning after a pause and a body-block, at most 2500 host walkability checks per frame for a walled-in drop). Each fails on the pre-review rc.10 build; the `test_rosie_contract.lua` case that asserted a fresh drop is skipped under Mythic GA 3 now asserts a listed-affix reading instead.
- `python3 audit/tests/run_tests.py --luajit require`: all test files × (Lua 5.4 + LuaJIT) pass; `python3 audit/check_release.py --base HEAD` passes.

## [2.3.0-rc.9] — 2026-09-26

Test build, released as a private draft (not published). Includes everything from 2.3.0-rc.8.

### Fixed

- Rosie 1.0.6: **the stash did not open** (live rc.8: `Open stash: attempt=1..4 distance=1.9 host=true`, then `Stash window did not open after 4 interactions`, while repair at the Blacksmith worked). The stash is not a vendor: Rosie required `get_current_vendor()` to report it, which the live host does not do, and sent the deposit through `vendor_action`, which needs the vendor-screen flag. Rosie now uses Alfred's check (the host's vendor-screen flag, or stash contents that read the same twice), refuses only while another vendor (for example the Blacksmith) is still the current one, and issues `move_item_to_stash` directly as Alfred does.
- Rosie 1.0.6: **Mythic Uniques from Uber bosses were skipped** (live Uber Mephisto: Leoric's Crown, Stone of Jordan, Henri's Perquisition, Locran's Talisman and others logged as `Skipped Helm | ... GA=0 ... threshold=unique_general:2`). The client had not loaded those drops yet: generic name ("Helm"), no Greater Affixes and no Mythic mark, so they were judged as plain Uniques below the Unique GA minimum. Once loaded, every Unique carries its own Unique power affix *(corrected in 2.3.0-rc.10: false for e.g. Locran's Talisman and Endurant Faith)* (the dump of the same Leoric's Crown shows it plus `S14_Mythic_UniquePotency`, and Rosie then wants it with `threshold=mythic_general:0`). A Unique whose details are not loaded is now picked up and decided in town, where the bag copy is fully known (*Always keep mythics* included). Pickup log lines for Uniques show `details=loaded|hidden mythic_mark=true|false`.
- Rosie 1.0.6: when the host skipped Rosie's move because the player was still walking another plugin's path, Rosie reported "walking" while the player followed that path away from the drop (review of rc.8). Rosie now clears the foreign path and resends its own, at most twice per destination.
- Rosie 1.0.6: a town trip that starts at the Tree of Whispers Raven (after SilentRaven) leaves through the Raven's intermediate point, like SilentRaven and WarPigs, instead of walking into the wall on the direct line.

### Corrected

- rc.8 described treating a `false` from `request_move` as the fix for the Helltide back-and-forth. That was not shown: with the old movement Rosie never reached `request_move` at all. It is a precaution for the new movement path; the Helltide back-and-forth still needs live confirmation on rc.9.

### Validation

- The joint host now models the live stash (not reported by `get_current_vendor()`, contents readable only while its panel is open, optionally no vendor-screen flag), vendor panels that close when the player walks away, and `request_move` skipped while the player is moving. New cases: stash deposits with and without the vendor-screen flag (both fail before the fix with the live message), a hidden-details Mythic Unique is picked up while the same loaded plain Unique is not, a drop is picked up while another plugin's long move is running (fails before the fix); the patrol case now starts with the activity already walking.
- `python3 audit/tests/run_tests.py`: all test files × (Lua 5.4 + LuaJIT) pass.

## [2.3.0-rc.8] — 2026-09-26

Test build, released as a private draft (not published). Includes everything from 2.3.0-rc.7.

### Fixed

- Rosie 1.0.5: **stood still in Temis** on the way to the Blacksmith (repair/salvage) and to the stash (live rc.6: "Moving to stash", `[Rosie:repair] is_done() -> false`, then only `world_traveler::create_path function exit point` every ~2.5 s), and in the Helltide it **looted oddly and ran back and forth** while the host printed ~30 `GENERATING helltide EXCEPTION - 222` lines in 10 s. Rosie moved only after the host's `create_path_game_engine` returned a complete route to the target. On the live host that call is asynchronous and routes to the map pin; Rosie sets none, so no route ever came back and Rosie never walked, while pickup re-requested it every 0.35 s inside the host's 500 ms flood window. Rosie now walks with the native `request_move` (as WarPigs' Temis route and SilentRaven do), never calls the engine path and never sets a map pin. The existing bound still applies: 3 s without progress, two re-requests, then *Stopped: no movement progress*.
- Rosie 1.0.5: `request_move` reporting `false` (the host skips a command that repeats the current one) is no longer treated as a refusal. It used to drop pickup's busy flag every step, so the activity (HelltideRevamped, which yields while the Looter is busy) and Rosie pulled the player back and forth.

### Changed

- Rosie README: movement, retry and mythic sections match the current behaviour; version 1.0.5.

### Validation

- `audit/tests/joint_host.lua` now models the live `create_path_game_engine` whenever the real Rosie is loaded (asynchronous, 500 ms flood dummy, routes only to a map pin) and, on request, a `request_move` that reports `false` for a repeated command. With the old movement code every Rosie town trip and pickup test fails on this model, as in the live log.
- New cases in `test_rosie_contract.lua`: a town trip walks and never calls the engine or sets a pin; six drops are picked up next to a patrolling activity with at most two busy flips (no back and forth); the same with the repeated-command `false` (8 flips before the second fix); a static guard. All fail before the fix.
- `python3 audit/tests/run_tests.py`: all test files × (Lua 5.4 + LuaJIT) pass.

## [2.3.0-rc.7] — 2026-09-26

Test build, released as a private draft (not published). Includes everything from 2.3.0-rc.6. The Rosie town/Helltide movement stall reported live on rc.6 is still being fixed and is not in this build.

### Fixed

- HordeDev 2.2.2: the Looter pause for a pylon or the War Plan altar was meant to last at most 20 s, but when it ran out it was released and immediately taken again on the next tick, so an unreachable pylon could keep Rosie's pickup paused indefinitely (C6). The pause is now taken once per pylon episode; after 20 s it is released for good (logged) and HordeDev walks to the pylon. A new pylon episode may pause again.

### Changed

- `УСТАНОВКА_RU.txt` (docs/INSTALL_RU.txt): 11 folders including Rosie and TristramLoop; remove old Alfred/Looter folders (Rosie replaces them); Rosie starts off; Auto Loot off; TristramLoop needs a Friend.

### Validation

- `python3 audit/tests/run_tests.py`: all test files × (Lua 5.4 + LuaJIT) pass; new case in `test_horde_audit.lua` (fails before the fix: the pause was re-acquired).

## [2.3.0-rc.6] — 2026-09-26

Test build, released as a private draft (not published). Includes everything from 2.3.0-rc.5.

### Fixed

- Rosie 1.0.4: Season 15 **Mythic forms of ordinary Uniques** were treated as plain Uniques (live: "Condemnation", Ancestral Mythic Unique Dagger, skipped on the ground by the Unique Greater Affix minimum and salvaged in town by the default ancestral Unique rule). Such an item keeps the Unique's SNO and rarity 6; the live dump showed the only difference is the Mythic upgrade affix `S14_Mythic_UniquePotency` (hash 2628989). Pickup and town now recognise any Unique carrying it as a mythic: it uses the Mythic GA rule on the ground and *Always keep mythics* protects it from selling and salvage. Unreadable affixes never promote an item. The Greater Affix count is unchanged: built-in `*_Greater` affixes on some Uniques are not Greater Affixes.

### Added

- Rosie town, *Ancestral*: **Use Mythic Unique filter** with a searchable list of every Unique. Checked Mythic Uniques are always kept; unchecked ones take the *unchecked Mythic Uniques* action (default Salvage) unless the Mythic Greater Affix override keeps them. Iconic mythics and plain Uniques are unaffected; locked (favourite) items are never touched. Off (default): Mythic Uniques count as mythics.

### Validation

- `python3 audit/tests/run_tests.py`: all test files × (Lua 5.4 + LuaJIT) pass; new case in `test_rosie_contract.lua` (pickup, town keep, filter, unreadable affixes).

## [2.3.0-rc.5] — 2026-09-26

Test build, released as a private draft (not published). Includes everything from 2.3.0-rc.4.

### Fixed

- Rosie 1.0.3: `utils.lua:923: attempt to compare nil with number` on every item census (live log): the host's `get_item_count()` returned nil, so the bag counts, the town-trip need and the menu preview failed (this also caused the menu flicker). The count now falls back to the inventory list and a missing limit to 25.

### Added

- Rosie diagnostics: *Log item and service decisions* now also dumps every Unique/Mythic within 20 m on the ground and in the inventory — all probed host fields (quality, rarity, flags, names with colour codes), the host method list and the affixes. Live finding: a Season 15 **Mythic form of an ordinary Unique** ("Condemnation", Ancestral Mythic Unique Dagger) reports the same SNO and **rarity 6** as the Unique, so neither rarity 8 nor an SNO list can recognise it; the dump is to find the host's real Mythic marker.

### Validation

- `python3 audit/tests/run_tests.py`: all test files × (Lua 5.4 + LuaJIT) pass; new case in `test_rosie_contract.lua` (fails before the fix).

## [2.3.0-rc.4] — 2026-09-26

Test build, released as a private draft (not published). Includes everything from 2.3.0-rc.3.

### Fixed

- Rosie 1.0.2: "the Rosie menu jumps / flickers up and down". When the host reported the player as not alive or the world as not loaded for a single frame, the menu swapped its two count lines (Equipment / Talismans) for one "Item preview unavailable" line and back, so everything below moved by one line. The error line now appears only after 2 s of continuous failure; until then the last counts stay on screen.

### Validation

- `python3 audit/tests/run_tests.py`: all test files × (Lua 5.4 + LuaJIT) pass; new case in `test_rosie_contract.lua` (fails before the fix: 23 vs 22 menu lines on alternate frames).

## [2.3.0-rc.3] — 2026-09-26

Test build, released as a private draft (not published). Includes everything from 2.3.0-rc.2.

### Fixed

- HordeDev 2.2.1: "after a couple of rounds the character gets stuck at a pylon while also trying to go loot" (live, on 2.1.3 with LooteerV3; the HUD showed *waiting for Looter (439s)*). LooteerV3 reports busy while any wanted item is nearby, even an unreachable one, so the Looter and HordeDev steered the player every tick and neither reached its target. During pylon/altar selection HordeDev now pauses a Looter that supports `acquire_pause` (Rosie) for at most 20 s, released as soon as the pylon is taken; with a Looter without a pause API (LooteerV3) it yields movement for at most 8 s per pylon, then walks to the pylon anyway (logged once). The per-tick `settings.party_mode:false` log line is gone.

### Validation

- `python3 audit/tests/run_tests.py`: all test files × (Lua 5.4 + LuaJIT) pass; two new cases in `test_horde_audit.lua`.

## [2.3.0-rc.2] — 2026-09-25

Test build, released as a private draft (not published). Includes everything from 2.3.0-rc.1.

### Added

- HordeDev 2.2.0: **Take War Plan altar (The Black Pact)** (default on). The War Plan node's altar between waves (`Warplans_BSK_ReplicatorGizmo_<Offer>`, same offer names as pylons) was ignored because HordeDev only looked for `BSK_Pyl*`. It is now accepted like a pylon, by the same priority list (offers missing from the list are still taken), once per offering window (the other offers are ignored for 60 s), and logged.
- WonderCity 2.2.0: **Take the boss portal as soon as it opens** (default off). For the War Plan node that opens a portal straight to the boss at max attunement: the floor portal (`X1_Undercity_PortalSwitch`) is taken from anywhere in view (150 m) instead of only within the check distance; logged once per run. The existing one-time actor scan in the Undercity log lists the real names if the portal turns out to be a different object.

### Changed

- Releases v2.2.0 and v2.2.1 (AlfredTheButler-WarPigz, based on SteroidAlfredV2) are withdrawn from public distribution: the release workflow deletes every release listed in `audit/withdrawn_releases.txt`. The latest public release is v2.1.3 until 2.3.0 is published.

### Validation

- `python3 audit/tests/run_tests.py`: all test files × (Lua 5.4 + LuaJIT) pass; new cases in `test_horde_audit.lua` and `test_wondercity.lua`.

## [2.3.0-rc.1] — 2026-09-25

Test build, released as a private draft (not published) until live testing is done.

### Changed

- **Rosie 1.0.1 replaces Alfred and Looter** (one plugin for town services and pickup; author anonymous). `AlfredTheButler-WarPigz` is removed from the bundle. Rosie publishes the `AlfredTheButlerPlugin`, `PLUGIN_alfred_the_butler` and `LooteerPlugin` APIs every bundle plugin uses; remove old Alfred/Looter folders. Mythics are rarity 8 (any Season 15 Mythic form of a Unique, Mythic charms and seals) and are always kept by default (*Always keep mythics*, also over the in-game loot filter).
- Integration fixes inside Rosie (marked `QQT_Warpigz_v2`): C1 pause fields (`paused`, `paused_by`, `owner`, `pending`); a failed town trip no longer loops (bounded retry, then waits for *Run town service*; `stuck`, `stuck_retry_in`, `fail_streak` in status); callbacks report `nil` / `'failed'` / `'cancelled'` like Alfred; modules bound at load (no caller-context `require`); Batmobile is paused during trips and resumed after; per-item classification is pcall-guarded (unreadable items are kept); reload mid-trip hands off cleanly; pause ownership is respected by the manual keybind; per-frame counting is throttled.
- WarPigs 1.1.3: reads Rosie's failed-trip result, waits at most 150 s on a stuck Rosie (logged with the reason). WonderCity 2.1.3: treats a failed town trip as failed. TristramLoop 1.0.1: Alfred bridge notes for Rosie.
- Release workflow: a pre-release version (`X.Y.Z-rc.N`) is created as a private draft release.

### Validation

- `python3 audit/tests/run_tests.py`: all test files × (Lua 5.4 + LuaJIT) pass; new `test_rosie_contract.lua` and `test_joint_rosie.lua` (real Rosie inside the joint host with WarPigs, Arkham, Helltide, WonderCity, Reaper; reloads). Still needs live testing.

## [2.2.1] — 2026-09-25

### Fixed

- Alfred 1.0.1: since Season 15 **any Unique can become Mythic** (Horadric Cube upgrade) and any Unique Charm can drop as Mythic, so a fixed mythic list can never be complete. Mythics are recognised by their runtime rarity (8) — that already covered every such item — and now, with *Always keep mythics* turned off, a Unique on the unique keep list is kept in its Mythic form too (before, only the iconic mythics of the mythic list were). Tooltip, README and database wording updated ("iconic mythics").

### Validation

- `python3 audit/tests/run_tests.py`: all test files × (Lua 5.4 + LuaJIT) pass; new case in `test_alfred_items.lua`.

## [2.2.0] — 2026-09-25

### Added

- **AlfredTheButler-WarPigz 1.0.0** — Alfred is now part of the bundle (based on SteroidAlfredV2, same `AlfredTheButlerPlugin` API and settings label; remove your old Alfred folder).
  - **Mythic Uniques are recognised**: a mythic is runtime rarity 8 or a database mythic. Before, only a fixed list of 12-13 old mythics counted, so new mythic uniques fell into the legendary rules and could be salvaged or sold. Mythics (equipment, charms, seals) are now always kept unless a mythic filter is explicitly enabled.
  - **Charms and seals are filtered**: detected by the item database and by internal skin name (`Talisman_Charm*`, `Talisman_Seal*`); per type an action per rarity tier (magic … mythic), a minimum greater-affix count and keep lists by name. Mythic charms, which were salvaged by default, are kept.
  - **Item database from the game files**: `data/item_db.lua` is generated by `audit/tools/gen_alfred_item_db.py` from DiabloTools/d4data (38 iconic mythics, 389 charms, 13 seals as of 2026-09-16). Items newer than the database are learned in game (`data/seen_items.lua`) and appear in the lists after a reload.
  - *Dump inventory item info* button: prints SNO, rarity, skin, type and the decision for every item.
  - Fixes over the upstream forks: 0-byte data files no longer crash loading, an unreadable rarity keeps the item, a full stash ends the town cycle as failed instead of halting every plugin, Batmobile is resumed when a request is dropped.
- **HelltideRevamped 2.2.0 — Mode: Warplan / Farm.** Warplan: kill monsters on the way, open chests as soon as cinders allow, move on (no ruptures, maiden or chaos rift). Farm: hunts **Pandemonium Ruptures** (Season 14 "tears": normal, surging, colossal; tears, rift chests, Realmwalker; Deathtoll Chamber optional, off by default), then chests, else monsters, until the Helltide ends. Ported from the author's HelltideRevamped 2.5.0. Whenever WarPigs drives HR (enable or adoption after a reload) the mode is always Warplan (`HelltideRevampedPlugin.set_external`).
- **TristramLoop 1.0.0** — standalone Uber Tristram / Whimsyshire loop (not integrated into WarPigs). Loot wait 15-120 min, default 60 (the game's loot lockout is one hour; the old 17-30 min wait made empty runs); the party friend is a setting with no personal default; `status()` exposes the stop reason. See `TristramLoop/README.md`.

### Changed

- WarPigs 1.1.2: marks an adopted HelltideRevamped as externally driven (Warplan mode).

### Validation

- `python3 audit/tests/run_tests.py`: all test files × (Lua 5.4 + LuaJIT) pass; new `test_helltide_modes.lua`, `test_helltide_modes_warpigs.lua`, `test_alfred_items.lua`, `test_alfred_contract.lua`, `test_tristram_loop.lua`. Rupture actor names and Alfred's rarity values still need a live check (see the plugin READMEs).

## [2.1.3] — 2026-09-25

Fixes from live reports on v2.1.2 (the Whisper-wall turn-in fix from 2.1.2 is confirmed working).

### Fixed

- Reaper (Grigoire and any lair whose altar vanishes or stops being clickable when the boss spawns): "pathing to the boss worked, but he opened the chest and then looped kill boss → chest". Three defects together: (1) after our altar click, the altar disappearing as the boss spawned let `navigate_to_boss` (higher priority) walk the recorded path again before `interact_altar` could register the summon; (2) an altar that stays listed but is no longer interactable was never counted as a summon; (3) with the summon unregistered, the altar was clicked again 6 s after the reward chest while the Looter still held the run-complete step, so the run was never counted ("Total runs completed this session: 0") and WarPigs had to cancel it. Now the summon belongs to `interact_altar` from our first click, a non-interactable altar after our click is success, and opening the reward chest confirms the summon so the altar can never be re-clicked before the run is counted.
- SilentRaven: `selection_failed; select(2) -> false` on a reward panel whose first two slots were empty (`sno=0 valid=false`) and only the third held a cache. The host counts only real cards for `select()`. Selection now tries the slot index, then the index among real cards, then the enumerate key, and before accept verifies that the reported selection cannot mean a different real card. The convention that worked is logged once.
- WonderCity: "stands still right after the start, *finish_undercity (waiting for reward chest)*" (seen twice, floor 1). Any boss/miniboss corpse started the reward wait, which then held the run until its timeout if no reward chest existed on that floor. Without a reward chest 30 s after the death, the reward wait is now dropped (logged with the boss name) and the run continues; the same corpse never re-arms it; a real reward chest always keeps it. The start of the wait now logs the boss name and zone.

### Validation

- `python3 audit/tests/run_tests.py`: 44 test files × (Lua 5.4 + LuaJIT) = 88 runs pass. New regressions (`test_live_reaper_grigoire.lua`, the empty-slot SilentRaven case, the floor-1 corpse WonderCity case) fail on 2.1.2 and pass now.

## [2.1.2] — 2026-09-25

### Fixed

- WarPigs turn-in / WarPug: "right after the Whisper cache he wants to hand in the finished War Plan and gets stuck on the wall between the Whisper tree and the War Plan table" (reported 3 times). Both walked straight at Tyrael / the table with `pathfinder.request_move`. From the Whisper side they now walk out the way SilentRaven walks in (Raven → intermediate → teleport arrival → target); any direct walk with no progress for 3 s takes that detour, at most 3 times, logged.

### Added

- Every new bundle version is published automatically as a GitHub release with an installable package (`.github/workflows/release.yml`, `audit/build_release.py`): CI runs the release checks and the offline suite under Lua 5.4 and LuaJIT, builds `QQT_Warpigz_v2-vX.Y.Z.zip` (nine plugin folders under `scripts/` + docs) and creates release `vX.Y.Z`.

### Validation

- `python3 audit/tests/run_tests.py`: 43 test files × (Lua 5.4 + LuaJIT) = 86 runs pass; `test_live_temis_wall.lua` reproduces the wall on 2.1.1 and passes now.

## [2.1.1] — 2026-09-25

Fixes from the first live reports on v2.1.0.

### Fixed

- HelltideRevamped: "works for a few minutes, then searches for a Helltide in the middle of a Helltide". When the Helltide buff dropped for a moment (walking over the zone edge, a cellar, a buff refresh), the very next tick went to the search task, which reset HR and teleported away before HR could notice it had left the zone and walk back. HR now keeps the tick for 15 s after the buff was last seen while the Helltide hour is active, walks back into the zone, and gives up walking back after 90 s (logged) before searching.
- WonderCity: "teleports to the entrance 5 times in a row, then starts the run". The Kurast teleport retried after 3 s, which is shorter than the channel plus loading screen, and the walk watchdog re-teleported to the same waypoint every 15 s while the player stood still after arrival. The teleport now waits 8 s and never retries during a loading screen; the watchdog ignores the teleport cast, waits 12 s, and re-teleports at most twice per stall (logged), then walks on.

### Validation

- `python3 audit/tests/run_tests.py`: 42 test files × (Lua 5.4 + LuaJIT) = 84 runs pass. New regressions reproduce both live reports on 2.1.0 and pass now.

## [2.1.0] — 2026-09-25

Integration release. A team of ten domain reviewers, one auditor and one critic checked every plugin for joint operation; five review/fix rounds followed, driven by the audit, the critic and real QQT client logs. All credits for the original foundation go to **@ZEWX — LONG LIVE LEGEND**.

### Added

- **Infernal Hordes War Plan steps enter through the War Plan teleport, never a compass.** WarPigs option *Hordes: enter via War Plan teleport (no compass)* (default on) presses `warplan.teleport_to_activity()` itself, also with *Use teleport* off, logs each landing, and starts HordeDev with `enable({entry='warplan'})` only inside the Horde. HordeDev's War Plan mode never uses a compass or the Library walk, finishes a 6-wave horde even without a chest room, leaves with Leave Dungeon and reports `completed`. Three missed landings back off 60 s with a visible reason; *Allow compass entry if the War Plan teleport fails* (default off) is the only compass path. Reloads mid-horde, Alfred's own trips out of the horde and hotkey pauses are handled.
- Shared cross-plugin contract: one Alfred status reading everywhere; additive status fields (`HordeDev in_run/fault/exit_pending/entry_mode`, `Reaper in_run/external_run/last_result`, `Arkham/WonderCity alfred_trip/in_run/committed_entry`, `hold` texts); `BatmobilePlugin.release(caller)` and `get_owner()`; Reaper `run_once` reports `success`/`failed`/`cancelled` exactly once.
- `audit/tests/joint_host.lua` + `test_joint_suite.lua`: all nine real plugins in one emulated QQT host (per-plugin module caches, one shared `_G`, caller-context `require` detection) — 34 scenarios over the whole War Plan loop.
- `run_tests.py` runs every test under Lua 5.4 **and LuaJIT**, compiles all runtime files with LuaJIT, rejects Lua 5.2+ library use and reports functions near the LuaJIT limits. `audit/LIVE_CHECKLIST.md` lists the log lines to confirm in the client.

### Fixed

- **The suite did not work on QQT's LuaJIT runtime.** WarPug's planner called `table.unpack` (nil in LuaJIT): every War Plan path search halted (`attempt to call field 'unpack'`), so no plan was created at the table. WarPigs' `orchestrator.tick()` captured 61 upvalues and did not compile at all (limit 60). HelltideRevamped's `reset()` was at 59.
- WarPigs: no teleport away from a running Alfred cycle in any town; activities resume in place after a WarPigs off/on; Pit/Undercity are not released on their own Alfred trip or during entry; failing Reaper bosses back off instead of looping; the WarPug ↔ Whisper circular wait is gone; Alfred's latched `teleport` flag no longer livelocks town handoffs; a sticky restock flag triggers at most one Alfred trip per Temis visit; the turn-in after a Horde waits about 3 s instead of 20 s; unmapped War Plan quests, refused runs, unconfirmed enables and every long hold are logged and shown; all holds are bounded.
- WarPug: companion work pauses a plan session instead of halting WarPug; Alfred admission follows the shared reading; capture keybinds register every press.
- SilentRaven: reward cards are no longer rejected when the host does not send `valid=true` (live `failed (no_valid_reward)` with a normal 4-card panel); selection verification tolerates host conventions and dumps the reward fields once when it cannot verify; ESC only while the panel is open; the Temis walk detects stalls; a Looter burst pauses instead of cancelling a managed claim.
- Batmobile: a released plugin's target, long path, traversal state and explorer priority no longer steer the next plugin (live: stale Temis target after the Pit); paused holds no longer trip false trap/giving-up; inert traversals are abandoned; explorer state follows world changes and is restored when the same pit is re-entered.
- ArkhamAsylum / WonderCity / Reaper / HordeDev / HelltideRevamped: the sticky Alfred grace survives task switches (no endless Alfred loops); unreadable Alfred status is bounded; orbwalker clear/block states are restored on every exit; time spent yielding to Looter/Alfred no longer counts as "stuck" (live: Helltide blacklisted reachable chests while waiting for the Looter).
- WonderCity: no endless wait at the brazier with default tribute settings, nor at an already opened reward chest (live).
- HordeDev: chest/exit/entry faults are reported and exit instead of freezing WarPigs; teleports are not re-fired into their own channel; a persisted-on HordeDev waits for WarPigs before acting; out of compasses at the gate it still asks Alfred to restock them.
- Reaper: waits for the Looter before leaving the lair; Belial one-shots are refused when the chest sequence is off; the periodic dungeon reset also runs under WarPigs.

### Changed

- WarPug `positions.txt` ships **uncalibrated**; the calibration shipped by earlier releases is ignored. Capture Reroll/Confirm positions after installing or updating (or restore your own file).
- While WarPigs is enabled, activity plugins leave advisory Alfred flags (restock/stash without a full bag or repair) to WarPigs, which services them once per Temis visit. Hard needs and standalone use are unchanged.
- The README now says to copy only the nine plugin folders into `scripts`.

### Validation and limits

- `python3 audit/tests/run_tests.py`: 41 test files × (Lua 5.4 + LuaJIT) = 82 runs pass; all 202 runtime files compile under LuaJIT. See `audit/VALIDATION.txt` and `AUDIT.md`.
- No live Diablo IV/QQT run is claimed by these tests. Still to confirm in the client: where the War Plan teleport lands for a Horde, SilentRaven's reward-selection conventions, native `request_move` behaviour during Looter activity, chest actor states after opening, and whether closed-source Alfred/Looter drive Batmobile under their own caller names.

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
