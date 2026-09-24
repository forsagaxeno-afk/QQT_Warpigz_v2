# HelltideRevamped

Helltide farming with chest collection, regional patrols, optional Maiden runs,
Alfred service trips, and Batmobile navigation. Existing setting keys, routes,
chest names and cinder costs are preserved.

## Chest detection

Discovery combines the host actor list with the documented loot-and-chest list.
Only names already listed in `data/enums.lua` receive a cinder cost. The nearest
eligible chest is chosen after checking interactability, affordability, range
and its temporary blacklist. Opened chests no longer hide another chest of the
same type. Once selected, a chest is tracked by name and position.

Chests within 50 units use direct approach; remembered chests within 150 units
use the existing recall navigation. An affordable chest seen beyond the direct
range is remembered for recall. A chest that rejects six interaction attempts
is skipped for 60 seconds so the patrol can continue.

If a chest is still missed, enable **Debug settings → Draw chest status** and
capture the console output near that chest:

- `[CHEST SCAN]` reports the chest toggle, cinders, recognized actors,
  interactable actors, affordable actors, actors within 50 units and blacklisted
  actors. These counts are independent, not a sequential filtering funnel.
- `[CHEST UNKNOWN]` records an unrecognized Helltide/reward-gizmo skin, its
  interactability and distance. Each skin is logged once per session.
- `[CHEST RETRY LIMIT]` identifies a recognized chest whose interaction was
  repeatedly rejected.

Scan diagnostics run at most once every five seconds. Unknown actors are never
assigned a guessed cost or opened merely because their name mentions Helltide.
If `known=0`, attach the unknown-skin lines and a screenshot showing the chest's
actual cost. If the host exposes the actor in neither documented list, this
plugin cannot discover it from those lists.

## Navigation and companion plugins

Patrol routes cover the existing `Frac_`, `Scos_`, `Kehj_`, `Hawe_` and `Step_`
regions. Unsupported regions use Batmobile free exploration. Existing explicit
zone overrides and exclusions remain in `data/zone_overrides.lua`; these are
source-provided coordinates, not newly validated seasonal data. Batmobile is
needed for the unsupported-region exploration fallback and traversal-aware
long-distance navigation.

Alfred handles salvage when enabled. Helltide yields to an existing Alfred
cycle, including hosts that do not expose its caller. Completion callbacks
update Helltide state without pausing Alfred. Disabling Helltide invalidates
outstanding callbacks and pending chest/search state, and stops movement it
issued. A disabled Looteer with a stale `looting` flag no longer blocks Helltide.

Only a hard Alfred need (`inventory_full` or `need_repair`, or the local item
count when Alfred publishes no inventory view) sends Helltide to town, and it
still does so at once. An advisory flag alone (`need_trigger` next to
`inventory_full`/`need_repair` that are both off, or the legacy fork's
`restock_count`) never starts an Alfred trip from inside a helltide: restock
waits for the next inventory-full or repair trip, or for WarPigs' Temis visit,
so standalone Helltide does not restock for those flags while it farms. A
provider that publishes only `need_trigger` keeps it as its town signal, at
most once per 30-second grace after any finished cycle. A teleport flag left
over from a finished or failed trip is not treated as work. An unreadable Alfred status
holds for at most about 10 seconds; a pause set by another plugin holds a
pending town request for at most 60 seconds.

Time spent yielding to Looteer or Alfred does not count toward the chest,
chest-recall, traversal or patrol stuck timers, so a reachable chest is no
longer blacklisted right after a long Looteer pickup. After a Batmobile
give-up the town teleport is retried every 6 seconds while the Helltide buff
is still present, and no Alfred round trip starts from inside the trap. During
minutes 55-59 Helltide teleports to the idle town first and asks Alfred for
salvage only after arriving. Search teleports wait up to 20 seconds for an
active Looteer pickup. After an external enable (WarPigs) without the buff,
search waits up to 15 seconds for the buff before teleporting away. Every HR
session starts with a Batmobile exploration reset, and disabling Helltide
releases Batmobile and turns orbwalker clear back on and movement unblocked
when **Manage orbwalker** is on, or when Helltide itself forced them (the
cinder gate's clear OFF) before the option was switched off. `HelltideRevampedPlugin.status().hold` names any Looteer/Alfred hold, and
holds longer than a minute are logged once a minute.

**Do Maiden** takes priority over chest selection while its conditions hold.
Use **Disable Maiden at Cinders** to release Maiden farming for chest spending.
The existing Chaos Rift option still uses its source-provided seasonal name;
its presence in the menu is not proof that the activity exists this season.

## Compatibility and tests

No Season 15 actor IDs, chest costs, buffs, waypoints or seasonal interactions
have been invented. The supplied QQT API confirms the actor and loot discovery
methods; actual current-season actors, chest prices, routes and combat behavior
still require an in-game check.

From the suite directory, run:

```sh
python3 audit/tests/run_tests.py test_helltide.lua
```

The offline regressions cover chest discovery and selection, completed and
rejected interactions, cinder loss, recall, cache invalidation, cancellation,
diagnostics, zone search, teleport debounce, movement handoff and settings.
