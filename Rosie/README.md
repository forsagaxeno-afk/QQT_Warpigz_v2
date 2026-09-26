# Rosie

One local addon for pickup, item rules, repairs and storage. Version 1.0.6
(QQT_Warpigz_v2 build; local patches are marked `QQT_Warpigz_v2` in the code).
The bundled Item catalog targets Diablo 4 Season 15, build 3.2.1.73552.

## Install and first run

1. Unload the separate Looteer and Alfred addons. Put the single `Rosie` folder
   directly in QQT's scripts directory, then reload Lua. No companion looter,
   butler, movement addon, server or account is required.
2. Open **Rosie**. It starts off. Review **Pickup rules**, then **Keep, storage &
   town**, including your salvage/sell defaults and bag/stash limits. Existing
   saved pickup and item-policy IDs are retained when the host retains them.
3. Turn the host's **Auto Loot** off if Rosie should decide which drops to take.
   Enable **Rosie**. Fresh pickup/town controls default on; existing saved choices
   are respected. Either service can be turned off independently.
4. Use **Run town service** for an immediate trip or a retry after correcting a
   reported problem. **Stop Rosie** cancels an active trip and turns Rosie off.
   The master switch also stops pickup immediately.

Do not run a second addon publishing `LooteerPlugin` or `AlfredTheButlerPlugin`.
Rosie reports a setup conflict and yields if another provider is already present
or loads later. Remove that duplicate and reload Rosie. Keep the old folders
outside the active scripts directory if you want an easy rollback.

## Daily flow

Rosie collects accepted drops, watches bag space and repair need, and services
Temis when needed: sell, salvage and repair at the relevant vendors, process
talismans, deposit kept items, process explicit stash pulls, then observe arrival
back in the original world. Repair shares the Blacksmith visit with salvage.
Temis is the supported town. Rosie does not fight, revive or reset encounters.

The overview explains waits, ownership, failures and cleanup, including a disabled
town worker or its paused automatic-service keybind. Equipment and talisman bag
counts are displayed separately from the latest scan. Settings remain available while off. A failed trip
is retried after 120 s while its need remains; after three failures (or a failure
that a retry cannot fix) it waits for **Run town service**. Protected full bags do
not cause endless town trips.

**Mythics.** *Always keep mythics* (default on) keeps rarity-8 mythics, mythic
charms and seals, and Season 15 Mythic forms of ordinary Uniques (recognised by
their Mythic upgrade affix). *Use Mythic Unique filter* (Ancestral, default off)
replaces that rule for Mythic Uniques: checked ones are always kept, unchecked
ones take the chosen action (default Salvage) unless the Mythic Greater Affix
override keeps them.
Unfinished resource release is retried and prevents new work, including on reload.

**Pickup rules** separates equipment rarity/Greater Affixes from charms, seals,
Soul Splinters, keys, runes, materials and other bags. Ancestral tier is not a GA
count. Common/Magic/Rare crafting bases are not implicitly junk. Select the rarity,
GA and category policy you actually want; catalog presence does not prove that an
item currently drops. Native in-game filtering is optional for supported gear.

**Keep, storage & town** sets disposition and storage policy. Locked gear cannot
be sold or salvaged. The favorite preference also controls whether favorites are
stashed. Missing destructive evidence retains the item. Named-item pickers offer
literal name/type/class/ID search, class-plus-selected, all-class and selected-only
views. Saved choices for other classes remain visible. Item labels never own the
saved choice; the Item ID does.

**Queued stash pulls** is an explicit advanced action. Enter a named equipment,
charm or seal Item ID from the picker, choose Salvage or Sell, add it, then run
town service. An entry selects **every matching unlocked copy of that Item ID**.
Rosie's automatic bag/repair trips leave this queue pending. Run town service,
its manual keybind, or an explicit request through the compatibility API consumes it;
another addon can make that request. Clear the queue before delegating town trips
if those copies should remain in storage.
Favorites remain protected. Rosie verifies transfer into the proper
bag before processing it; missing or ambiguous items cannot count as success.
Clear queue removes pending intent without moving anything. Pending entries
survive Lua refresh; a running trip is cancelled and must be retried.

**Movement** offers Smooth and responsive or Fast request pacing. Both walk with
the host's native move request (`pathfinder.request_move`) straight to the
target, keep nearly equal targets, account for height, and allow only bounded
recovery from stalls (3 s without progress: re-request, twice, then *Stopped: no
movement progress*). Rosie never uses the map-pin engine path
(`create_path_game_engine`) and never sets a map pin. Chat, death and loading
release owned movement and suspend work. No random wandering or arbitrary delay
is added.

**Display and diagnostics** controls Rosie's status and read-only decision log.
Bag highlights and their alignment live under town Display settings; ground item
highlights live under Pickup rules. Hidden controls cannot run actions. A failed
settings menu blocks new service and queue actions; a Stop button already shown
still cancels the trip. Per-item pickup attempts and selected approach time are finite; disabling
pickup and enabling it again explicitly resets that budget.

## Other addons and saved state

Tristram may own pickup movement while using Rosie's policy. Warlock and existing
activity consumers can still use `LooteerPlugin`, `AlfredTheButlerPlugin` and
`PLUGIN_alfred_the_butler`. These are adapters to Rosie's two private workers, not
separate installed runners. The master gates status and incoming requests. Legacy
enable/disable methods change their worker preference; enabling the whole product
requires `RosiePlugin.enable()` or the menu master.

`RosiePlugin` offers `status()`, `enable()`, `disable()`, `service()`, `stop()` and
`shutdown()`. `status()` returns a fresh snapshot containing phase, detail,
enabled, town, pickup and movement. Underscore members support internal reload
handoff and are not consumer contracts. No network calls or user profile files
are bundled. Real client restart persistence remains a host-dependent acceptance
check; Lua refresh preserves the existing widget objects.

Verified against a simulated host. Native appearance, real navigation and settings
persistence across a full client restart still require in-game verification.
