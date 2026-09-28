# HelltideRevamped: session notes (current 2.6.1)

## Map
- `tasks/helltide.lua`: the main state machine, about 186 file-level locals. **Add no new file-level locals.**
- `core/hr_mode.lua`: Warplan vs Farm mode. `core/hr_tear_event.lua`: Pandemonium ruptures ("tears"). `core/hr_cinder_plan.lua`: the cinder budget and the cinder run.
- `core/hr_chest_order.lua`, `hr_roads.lua`, `hr_atlas.lua`, `hr_fence.lua`: chest order, road routing, learned chests and the Helltide border.
- `core/hr_stats.lua`, `hr_overlay.lua`, `hr_dashboard.lua` (writes `hr_data.js`, into WarRoom's folder when WarRoom is on), `hr_view.lua` (the activity label).
- `tasks/alfred.lua`: town trips through Rosie, with a bounded foreign-pause hold.

## History
- 3.1.0: smart farm (Mystery chests first, cinder plan, road routing, learning); tears: stand in each until it closes, loot after the event (Realmwalker dead or 10 s); cinder run (Hell's Prize 666 > Mystery 250 > the rest); UTC timing; zone-cycling fix; "Skip legacy Helltide events" defaults ON.
- 3.2.0: menu in play order (Goal "Farm cinders until" 2000 → tears → movement → Advanced); Farm Cinder Threshold is Warplan-only; move on after 25 s near a chest.
- 3.2.3: overlay appearance settings.
- 3.3.2: no idle at a dead rupture. Only an open tear, a living cultist or a living Realmwalker counts as live; a dead site is left in about 6 s; spent sites are remembered for 900 s; the label is honest.

## Open / live checks
- The move-on numbers (25 s / 45 m / 50 m); whether 2000 cinders is reachable in a typical Helltide hour; the map orientation and overlay fit.
- A Surging rupture made only of waves (no tears or cultists) is kept alive by the marker skins only and completes after 30 s of quiet. Verify live.
