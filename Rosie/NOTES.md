# Rosie: session notes (current 1.0.21)

Rosie is the pickup + town-service addon. It replaces the old Alfred (town) and Looteer (pickup) and publishes their APIs: `AlfredTheButlerPlugin`, `LooteerPlugin`, `RosiePlugin`.

## Map
- `rosie/controller.lua`: the master switch, the per-frame update order (town, then pickup, then the unique sorter) and the `RosiePlugin` API.
- `rosie/private/town/`: the town service. `core/lifecycle.lua` handles request / finish / latches / `hold_peers` / auto_blocked. `main.lua` runs automatic trips (deferral, wait log). `core/utils.lua` has the item census (`update_tracker_count`) and the keep decision. The tasks are sell, salvage, repair, stash, stash_pull, salvage_talisman, teleport and status.
- `rosie/private/pickup/`: pickup. `src/item_manager.lua` chooses a drop; `src/pickup.lua` steps toward it, retries in rounds, holds during a fight and yields to other movers; `main.lua` publishes the Looter API.
- `rosie/private/unique_sorter.lua`: "Pick up every Unique", the Drop mode.
- `rosie/movement.lua`: owner-based movement (pickup / town) and `yield` versus `release`.

## History (important fixes)
- 3.1.0: ghost pickups, Splinters carried once, the seal filter crash, stash receipts plus a one-item skip, Escape closes the panels, stand still while a tear is live.
- 3.2.4 / 3.2.5: "Keep Uniques with Item Power ≥" (plain Uniques only); checked lists keep both forms; Always keep Mythics wins. The reload crash came from cached GUI widgets: `town/gui.lua` now recreates any missing widget keys.
- 3.3.0: the Keep menu is ordered top-down and the first match wins (Always keep → loot filter → junk → Uniques → Legendary … → Seals → Charms → Storage → Town trips).
- 3.3.1: a full bag never waits forever (an activity owner or a foreign pause waits at most 60 s in town / 600 s anywhere; a latch is retried every 600 s); wait reasons are logged.
- 3.3.2: fight hold (no walk to a drop more than 3 m away while an enemy is within 10 m, 14 m hysteresis, 45 s cap, pickup stays busy without moving); yield to another mover (rest 4 → 30 s); obols are never targeted.
- 1.0.21 (unreleased): third-party peers (`rosie/private/foreign.lua`, API from `docs/THIRD_PARTY_APIS.md`, all guarded + pcall): Navigator is held for the whole trip via `set_pause_condition("Rosie", trip in progress)` (fallback `pause/resume("Rosie")` only when Rosie saw its own pause take effect); during the outbound cast a busy, unpaused, foreign Navigator request is `stop()`ped (1 s gap, 30 per trip); Scavenger `pause/resume("Rosie")` per trip; pickup yields while `Scavenger.is_busy()`; no trip starts while `Butler.is_busy()`. The cast waits until the player stood still 0.6 s, a cast the player was moved out of is refunded, outbound time being moved is not service time but capped by `MOVER_WAIT` 120 s. Generic hook: `lifecycle.add_foreign_hold{name, global, hold, release}`. Test: `test_rosie_foreign_mover.lua` (fails on 1.0.20).

## Open
- **Navigator blocks the Town Portal cast.** Live log 2026-09-28: `Player_TownPortal` buff at 115 s, Navigator "stuck" moves from 136 to 182 s, `[Rosie] failed: teleport_failed` at 175 s. Fixed in 1.0.21 (offline). Live checks left: a Worldstone run with a full bag (the log should show `Navigator is held during town trips (pause condition "Rosie")`, no `teleport_failed`); Navigator's `pause`/`resume` argument form is still unconfirmed (only used when `set_pause_condition` is missing).
- Live checks: the fight hold feel in the Pit / Helltide; the `Another move took the player off` frequency.
