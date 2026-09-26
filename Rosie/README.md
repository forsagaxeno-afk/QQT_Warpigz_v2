# Rosie

One local addon for pickup, item rules, repairs and storage. Version 1.0.8
(QQT_Warpigz_v2 build; local patches are marked `QQT_Warpigz_v2` in the code).
The bundled Item catalog targets Diablo 4 Season 15, build 3.2.1.73552.

## Install and first run

1. Unload the separate Looteer and Alfred addons. Put the single `Rosie` folder
   directly in QQT's scripts directory, then reload Lua. No companion looter,
   butler, movement addon, server or account is required.
2. Open **Rosie**. It starts off. Review **Pickup rules**, then **Keep, storage &
   town**, including your salvage/sell defaults and bag/stash limits. Existing
   saved pickup and item-policy IDs are retained when the host retains them.
3. Rosie switches the host's **Auto Loot** off on every pickup pulse (as
   LooteerV3 does), so the host never walks to drops Rosie refuses. The host
   offers no way to read the previous value: after unloading Rosie, turn Auto
   Loot back on by hand if you want it. Enable **Rosie**. Fresh pickup/town controls default on; existing saved choices
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
charms and seals, the 14 iconic Mythics re-issued in Season 14 (Harlequin Crest,
Doombringer and the others; rarity 6 on the host), and Season 15 Mythic forms of
ordinary Uniques. A Mythic form is recognised by its Mythic upgrade affix
(`S14_Mythic_UniquePotency`, hash 2628989) or any affix whose name contains
`Mythic`; the log names the affix that matched. *Use Mythic Unique filter*
(Ancestral, default off) replaces that rule for Mythic Uniques: checked ones are
always kept, unchecked ones take the chosen action (default Salvage) unless the
Mythic Greater Affix override keeps them.

A fresh ground drop shows no affixes until it has been picked up once, so a
Mythic Unique and a plain Unique can read the same on the ground. **May be a
Mythic:** a Unique below its Unique Greater Affix minimum whose reading cannot
rule out a Mythic (affixes unreadable, no affixes listed, or Ancestral reading
0 Greater Affixes) is picked up and decided in town (`accepted: may be a Mythic
Unique (...); decided in town`). A drop that lists no affixes (or cannot be read)
reads 0 Greater Affixes whatever it carries, so it is taken whichever slider is
stricter; an Ancestral Unique that lists affixes but reads 0 GA is taken only when
the Unique minimum is the stricter rule. *Respect in-game loot filter* never skips
a mythic. This takes more plain Ancestral Uniques; the town rules sell or salvage
them once the bag copy is known. In town, a Unique whose affixes are unreadable
or empty is never sold or salvaged (it is stashed and checked again on the next
trip). `[Rosie mythic-probe]` lines record how skipped or undecided Uniques read
on the ground (at most 3 per drop, one per second) and how every Unique in the
bag reads with Rosie's keep/sell/salvage decision (once per reading).
`Item_Quality_Modifier_Bits` is logged there (`qbits=`) and never used to decide.
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
if those copies should remain in storage. Copies the town rules keep as mythics
(while *Always keep mythics* is on), Uniques whose affixes cannot rule out a
Mythic form and unreadable items are never taken: they stay in the stash and the
log names them (`Kept in the stash: sno=...`).
Favorites remain protected. Rosie verifies transfer into the proper
bag before processing it; missing or ambiguous items cannot count as success.
Clear queue removes pending intent without moving anything. Pending entries
survive Lua refresh; a running trip is cancelled and must be retried.

**Movement** offers Smooth and responsive or Fast request pacing. Both walk with
the host's native move request (`pathfinder.request_move`) straight to the
target (pickup only: when the host ray cast reports the straight line to a drop
blocked, Rosie plans waypoints around it with a bounded A* search of at most
1500 nodes that never cuts a wall corner, re-plans from where the player stands
at most 4 times per drop, plans a drop with no path only once, and walks
straight when no path is found), keep nearly equal targets, account for height, and allow only bounded
recovery from stalls (3 s without progress: re-request, twice, then *Stopped: no
movement progress*). Rosie never uses the map-pin engine path
(`create_path_game_engine`) and never sets a map pin. Chat, death and loading
release owned movement and suspend work. No random wandering or arbitrary delay
is added.

**Display and diagnostics** controls Rosie's status and read-only decision log.
Bag highlights and their alignment live under town Display settings; ground item
highlights live under Pickup rules. Hidden controls cannot run actions. A failed
settings menu blocks new service and queue actions; a Stop button already shown
still cancels the trip.

**Pickup rounds** (as LooteerV3): Rosie walks to an accepted drop and, within 2 m,
interacts with it every 0.15 s. A round ends after 30 interactions or 6 s without
getting closer; the drop then rests 8 s while other wanted drops go first (with
none waiting its next round starts at once, and Rosie stays busy, so activities
that wait for looting keep waiting) and after 3 rounds it is skipped until it
leaves the ground. A fight that
keeps the player busy therefore costs a round, not the drop. Disabling pickup and
enabling it again resets that budget.

**Stash.** The stash chest is not an NPC vendor. Rosie walks to within 2 m of the
nearest Stash actor (within 3 m it interacts after 1.5 s without getting closer),
preferring one the host reports interactable, interacts with it (again every 0.3 s for
2 s, as Alfred does, up to 4 attempts 3 s apart) and then deposits once the chest
reads open: the inventory panel is open, the stash list reads the same twice, or
the vendor-screen flag is up while no other NPC reads as the current vendor. These
signals count only after this trip has interacted with the chest, and a signal
already up just before the first interaction is ignored. A deposit that moves
nothing makes Rosie interact again. If no signal shows, one deposit per attempt
is sent as a probe and counts only when the bag and stash change (never while an
NPC panel open before the interaction still reads open). Each attempt logs
`Open stash: attempt=N distance= host= actor=(x,y) interactable= sdk= inv=
vendor= stash_n=`, and `Stash reads open: signal=...` names the signal that
decided. Queued stash pulls use the same rule, go ahead 2.5 s after the
interaction as Alfred does, and interact again (at most 3 times) when nothing
arrives in the bag. Sell, salvage, repair and talisman salvage still require the expected
NPC (Gambler, Blacksmith, Occultist) to be the current vendor.

## Mythic sorting

A fresh ground drop shows no affixes until it has been picked up once, and a
Season 15 Mythic form keeps its Unique's name, SNO and rarity. On the ground a
Mythic and a plain Unique therefore look the same; in the bag they do not.

**Pick up every Unique (sort in the bag)** (right under *Enable Rosie*, default
on) makes pickup take every Unique and every Mythic, whatever the Greater Affix
sliders and slot overrides say (`accepted: every Unique is taken (sorted in the
bag)`). Bag space is still checked. A Mythic ignores *Respect in-game loot
filter*; a plain Unique still respects it (turn that filter off, or let it show
Uniques, if you want every Unique). The legacy *Skip gear with visible affixes*
setting still applies. Off: the pickup GA rules decide on the ground as in 1.0.7.

In the bag a Unique is a **Mythic** when it has rarity 8 or more, is one of the
iconic Mythics (including the 14 re-issued in Season 14, such as Harlequin
Crest), or carries the Mythic upgrade affix (`S14_Mythic_UniquePotency`, hash
2628989, or any affix whose name contains `Mythic`). Everything else with
rarity 6 is a **plain Unique**. **Plain Uniques** (shown while the option is on):

- *Handle in town (salvage/sell by your rules)* (default): nothing is dropped.
  Plain Uniques wait in the bag; the town trip sells, salvages or keeps them by
  your rules, and Mythics follow *Always keep mythics* and the Mythic rules.
- *Drop on the ground (no town trip)*: outside town (any town the game flags,
  not only Rosie's home town), when no town trip runs, a plain Unique your town
  rules would sell or salvage is dropped on the spot, one item every 0.6 s.
  While the sorter can act, those items do not count toward the bag limit, so a
  pile of them does not start a town trip. Rosie first remembers it (its SNO
  plus every affix and roll), so pickup never takes it again (`dropped by Rosie
  (plain Unique)`). The list lives 30 min and holds at most 200 items; a town
  trip and the loading screen keep it, entering a different world clears it.
  If the dropped copy lists no affixes, Rosie binds the entry to the first new
  item of that SNO within 4 m of the spot in the next 5 s (items already lying
  there are excluded) and refuses only that item, for up to 15 min; fresh drops
  that land later, including a Mythic form, are picked up as usual. Once one
  dropped copy was recognised by its fingerprint this fallback is off for the
  session. A drop that does not leave the bag within 2 s is retried twice (a
  town trip or pause in between keeps the count); then the item is left for the
  town trip and not tried again. Never dropped: Mythics (even with *Always keep
  mythics* off; in town your Mythic rules decide), locked items, Uniques whose
  affixes are not readable yet, and every Unique a keep rule protects (*Use
  unique/mythic filter* selections, the Unique Greater Affix override, *Use
  Mythic Unique filter*). Nothing is dropped while chat or a vendor screen is
  open, pickup is off or paused by another addon, or a town trip is requested
  or running.

Log lines (turn on *Log item and service decisions* for the summary):
`[Rosie sort] Dropped plain Unique <name> sno=... fp=...`, `[Rosie sort] Kept
Mythic <name> (mark=...)` (mode Drop), `[Rosie sort] Ground copy of <name> found by
fingerprint|position: identifier bag=... ground=... matched=...` (once per
item, for the dropped copy), `[Rosie mythic-probe] taken sno=...` (every Unique
taken from the ground), `[Rosie sort] Drop of <name> refused by the host` and `[Rosie sort]
Could not drop <name> after 3 attempts; it is left to the town trip.`

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
