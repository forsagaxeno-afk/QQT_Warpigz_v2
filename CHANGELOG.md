# Changelog

All entries are in English. QQT_Warpigz_v2 release numbering starts with **2.0.0**. Earlier component versions and the imported Git baseline are not earlier releases of this project.

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
