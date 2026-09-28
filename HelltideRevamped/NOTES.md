# HelltideRevamped: session notes (current 2.6.3)

## Map
- `tasks/helltide.lua`: the main state machine, about 186 file-level locals. **Add no new file-level locals.**
- `core/hr_mode.lua`: Warplan vs Farm mode. `core/hr_tear_event.lua`: Pandemonium ruptures ("tears"). `core/hr_cinder_plan.lua`: the cinder budget and the cinder run.
- `core/hr_chest_order.lua`, `hr_roads.lua`, `hr_atlas.lua`, `hr_fence.lua`: chest order, road routing, learned chests and the Helltide border.
- `core/hr_stats.lua`, `hr_overlay.lua`, `hr_dashboard.lua` (writes `hr_data.js`; into WarRoom's folder when `_G.QQT_WarRoom` is present, which it no longer is since 3.3.6: WarRoom is archived, the optional path is kept), `hr_view.lua` (the activity label).
- `tasks/alfred.lua`: town trips through Rosie, with a bounded foreign-pause hold.
- `core/hr_watch.lua` (2.6.2, via `tracker.hr_watch`): bounds for the ore/herb/shrine/goblin/silent chest/chaos rift walks (12 s without progress, or a per-state cap; a given-up target is skipped 120 s), the KILL_MONSTERS "no damage, no progress for 15 s: ignore 60 s" rule, and the pyre/pillar "no monster within 25 m for 20 s: event over" exit.

## History
- 3.1.0: smart farm (Mystery chests first, cinder plan, road routing, learning); tears: stand in each until it closes, loot after the event (Realmwalker dead or 10 s); cinder run (Hell's Prize 666 > Mystery 250 > the rest); UTC timing; zone-cycling fix; "Skip legacy Helltide events" defaults ON.
- 3.2.0: menu in play order (Goal "Farm cinders until" 2000 → tears → movement → Advanced); Farm Cinder Threshold is Warplan-only; move on after 25 s near a chest.
- 3.2.3: overlay appearance settings.
- 3.3.2: no idle at a dead rupture. Only an open tear, a living cultist or a living Realmwalker counts as live; a dead site is left in about 6 s; spent sites are remembered for 900 s; the label is honest.

- 2.6.2 (stall audit): no wait or walk without a bound. Chest 2-6 m band: interact from there after 3 s without getting closer (6 attempts, then blacklist). Spent pyre/pillar left after 20 s with no monster. Unreachable ore/herb/shrine/goblin given up. Warplan kill ignores a target that takes no damage. Zone-override entry park bounded to 45 s. Rupture: cultists not hurt or reached for 20 s → leave (300 s blacklist); a rupture not reachable, or whose only tears were out of reach, is blacklisted 300 s and not counted as completed. Search: a refused/failed teleport to this hour's own Helltide is retried every 120 s (it waited for the next hour).

- 2.6.2 (auditor findings on 2.6.1): rupture grace/quiet timers run only within LIVE_SCAN_M of the site (a death/revive no longer finishes or abandons a live rupture); the quiet cap returns from `M.execute` (no old-state handler overwrites it on the same tick); an interactable starter switch is weak evidence (no 6 s exit, 30 s quiet cap, then left uncounted, 300 s); a Realmwalker counts only when this rupture would fight it and never re-arms a spent site; `listed()` compares ids. `tasks/alfred.lua`: any refusal blocks 30 s whatever `stuck` says (no 5 s request loop), no retry-delay hold after it, and the alfred task gives up the tick while dead (revive runs); a trip that left from the Helltide stamps `helltide_seen_at` on completion (no search reset when the buff lags). Search restarts from SEARCHING when the helltide task farmed since its last tick (no stale scan teleport at :55). `km_nav_map` entries older than 10 s are pruned.

- 2.6.3 (Coordinator, suite 3.3.6): WarRoom archived by the owner. The "Web dashboard" tooltip no longer points to WarRoom (no viewer page ships now); `hr_dashboard.warroom_path()` / `warroom_on()` stay as an optional, harmless integration (nil without `_G.QQT_WarRoom`). No behaviour change.

## Open / live checks
- The move-on numbers (25 s / 45 m / 50 m); whether 2000 cinders is reachable in a typical Helltide hour; the map orientation and overlay fit.
- A Surging rupture made only of waves (no tears or cultists) is kept alive by the marker skins only and completes after 30 s of quiet. Verify live.
- 2.6.2: before the player starts a rupture, is its SwitchGizmo interactable (weak evidence relies on it)? Does Rosie's trip callback fire before the buff is back (the stamp covers it either way)?
- 2.6.2: does `interact_object` open a chest from 3-6 m (the band fix relies on it; else the 6 attempts blacklist it after ~27 s)? Does a real pyre/pillar event always have a monster within 25 m while it runs (else the 20 s quiet exit leaves early)? Grep live logs for "Giving up on the", "No damage and no progress", "Cultists not killed", "Event over (no monster", "retrying in 120s".
- Not fixed (on the BOARD as findings): the 25 s idle Realmwalker wait after every Surging/Colossal completion; road route dropped after 20 s of fighting then "too far" abandon; Nahantu/Skovos hours idle (no patrol loop); Farm "save phase" / tears paused below the goal; FARM_CHEST_CINDERS (Warplan, off by default) has no time cap.
