# Reaper v1.9.1 — audited lifecycle fixes

Farms a user-selected set of bosses using **Lair Keys** / **Greater Lair Keys** (separate pools by tier) and **Betrayer's Husks** (Belial). Each confirmed chest open accounts for one key, or the configured Belial husk cost, in the appropriate pool. When every selected boss is out of resources the script returns to town and disables itself.

## Requirements

- An active combat / orbwalker script — Reaper handles navigation and interaction only.
- Optionally **BatmobilePlugin** for autonomous A\* navigation (auto-engages as a fallback when path files fail).
- Optionally **Alfred** for inventory management between runs.

## Setup

1. Drop the `Reaper` folder into your scripts directory.
2. Open the in-game menu → **Reaper**.
3. Under **Bosses to Farm**, pick a **Rotation Mode**:
   - **Manual** — farm one specific boss (pick from the dropdown).
   - **Round Robin** — cycle through ticked bosses, one run each.
   - **Random** — pick a random ticked boss for every run.
4. Under **Settings**, pick your home town and toggle Alfred / Batmobile as desired.
5. Make sure your combat script is running.
6. Click **Enable**.

On enable, Reaper dumps every dungeon-key and consumable item in the console (with SNO IDs and stack counts) so you can verify the constants in `core/materials.lua` if a future patch reshuffles the SNOs.

## Item / Inventory Model

Each boss requires a specific key tier — pools are tracked separately, not pooled:

| Item | SNO | Used by |
|---|---|---|
| **Lair Key** | `2556388` / `2558178` | Varshan, Grigoire, Lord Zir, Beast in Ice, Urivar |
| **Greater Lair Key** | `2558255` | Duriel, Andariel, Bloody Butcher, Harbinger of Hatred |
| **Betrayer's Husk** | `2194099` | Belial — `HUSK_COST_BELIAL` (default 2) per run |

The shipped configuration counts the two listed Lair Key SNOs in the same pool. These mappings are retained from the original source; they have not been verified against a running Season 15 client.

Each boss's required key is set by its `key_tier` field in `data/enums.lua`. Edit that file to change which tier a boss expects. A boss is removed from the rotation when its required tier hits zero, regardless of whether other tiers still have stock.

## Navigation

Reaper teleports directly to each boss dungeon via the runtime API call `teleport_to_boss_dungeon(sno)` — no map clicks, no `command.txt`, no external assistant required. From the dungeon entrance:

1. **Path-file walk (default).** A pre-recorded waypoint file under `paths/<boss>_<variant>.lua` drives the player to the altar. Multiple variants are supported; Reaper picks the closest one to the player on entry.
2. **Batmobile fallback (automatic).** If no path file exists, or a path-file walk completes without the altar in sight, Reaper auto-engages **BatmobilePlugin**'s `navigate_long_path` (uncapped A\*) the rest of the way. No toggle needed — it just works when Batmobile is loaded.
3. **Use Batmobile Navigation toggle (optional).** Tick this in **Settings** to make Batmobile the primary nav everywhere, skipping path files. Useful when Blizzard reshuffles dungeon layouts and the recorded paths drift.

## Belial Chest Automation

After Belial dies a "Ritual of Lies – Choose Reward" chest UI appears. This section automates clicking through it.

| Setting | Description |
|---|---|
| **Enable** | Turn on automated chest clicking |
| **Mode** | Manual / Round Robin / Random |
| **Target Boss** *(Manual)* | Fixed boss to always select |
| **Boss Pool** *(RR / Random)* | Which bosses to include in the pool |
| **Party Delay** | Extra ms before clicking Open (helps sync with party members) |

### Chest Dialog Alignment

The "Choose Reward" dialog can't be inspected through any plugin API — Reaper interacts with it by injecting mouse clicks at known positions. Coordinates are stored as **pixels at a 1920x1080 reference resolution** and converted at click time using **center-aware scaling** (`screen_w/2 + (ref_x − 960) × screen_h/1080`), so 21:9 / 32:9 ultrawide displays don't drift. Tune the positions under **Belial Chest Automation → Chest Dialog Alignment**:

1. Tick **Show crosshairs on screen**. Coloured `+` marks appear at every stored position even when the farmer is disabled.
2. Kill Belial (or trigger the dialog any way you like) so the Ritual of Lies UI is on screen.
3. Adjust the `Slot Y1`–`Slot Y7` sliders so the white crosshairs land on each boss row in the list.
4. Adjust **Slot X (column)** so the crosshairs sit on the boss button, not next to it.
5. Adjust **Modify Reward**, **Scroll**, and **Open** X/Y so each coloured crosshair sits on the matching button.
6. Untick **Show crosshairs** when done.

Defaults match the values that were hard-coded in earlier versions; you only need to recalibrate if a game patch reshuffles the dialog layout, or if you run an unusual aspect ratio where the `screen_h/1080` scaling alone is insufficient.

## Dungeon Reset

Resets all dungeons after every N completed runs (configurable). Useful for keeping dungeon layouts fresh. The run count is kept for the whole session, also across WarPigs one-shot runs; a reset that comes due during a one-shot run is done in town before the run reports back.

## Combat Behaviour

During boss fights Reaper keeps the player within **15 units of the altar/anchor position**. If the player drifts further away (e.g. chasing a stray enemy), it walks back before re-engaging. Suppressor orbs are always chased regardless of distance.

## Settings Reference

| Setting | Default | Description |
|---|---|---|
| Home town | Temis | Town to return to between runs (matches Alfred / Arkham). |
| Use Alfred | On | Hand off inventory/repair/restock to Alfred between runs. |
| Use Batmobile Navigation | Off | Force Batmobile as the primary navigation. When off, path files run first and Batmobile auto-engages on failure. |
| Bosses to Farm | All off | Per-boss checkboxes (Round Robin / Random) or single boss dropdown (Manual). |
| Rotation Mode | Round Robin | Manual / Round Robin / Random — how the script cycles through ticked bosses. |
| Dungeon Reset | Off | Reset dungeons every N runs. |
| Dungeon Reset Interval | 10 | Runs between dungeon resets. |

## Notes

- Inventory is scanned once at enable time. Re-enable to refresh.
- If the EGB / boss chest fails to despawn after several interact attempts, Reaper re-scans inventory: if stock remains the run retries; otherwise the boss is skipped.
- Boss-dungeon teleports have bounded inner and outer retries. Exhausted navigation skips that boss for the current session without counting a successful run.
- Paths from your zone entrance to the altar are stored in `paths/<boss>_<variant>.lua`. Multiple variants are supported and the closest one is picked at runtime.

## External control and completion

`ReaperPlugin.run_once(boss_id, run_type, on_complete)` accepts one run when Reaper is idle. `run_boss` uses the same one-run rotation without a callback. A refused request returns `false` plus a reason (`"busy"`, `"unknown boss"`, `"unsupported run type"`, `"sigil runs are not supported"`, `"belial_chest_disabled"`) and preserves the active run. `nil`, `"material"`, and `"lair_key"` infer the boss's configured tier; `"lair"`, `"greater"`, and `"husk"` select it explicitly. A Belial one-shot is refused while the Belial Chest sequence is off, because nothing would confirm the Ritual of Lies reward dialog.

Explicit `"sigil"` requests return `false`: this version has no verified sigil activation path. They are never converted into a material run. The legacy `sigil_complete.lua` heuristic is intentionally not scheduled.

A successful run requires reward-chest consumption and confirmed arrival in the selected town. `on_complete(result)` is called exactly once per run, after cleanup (Reaper is already off), so it may safely request the next run: `"success"`, `"failed"` (failed navigation or chest attempts) or `"cancelled"` (`disable()`, toggle off). A long fight or delayed teleport is not success; town teleports retry until arrival. `disable()` clears task state immediately.

`ReaperPlugin.status()` adds `in_run` (an orchestrator run from acceptance until it reports; a manual run only at the altar, in the fight, at the chest, during its own Alfred trip or the return to town), `external_run` (started by `run_once`), `last_result` / `last_error` (kept after the stop) and `hold_reason` (why Reaper is waiting on Alfred or the Looter).

Companions: Reaper yields while Alfred has live work (including another caller's trip), treats a pause it does not own as idle, and waits at most about 10 s on an unreadable Alfred status. Restock or stash-only requests wait out a 30 s grace after any finished Alfred cycle and never pull the player out of a boss lair; a full inventory or repair still does. Before leaving a lair after the chest, Reaper waits for the Looter to finish plus 3 s of quiet (at most 30 s). Stopping or yielding releases Reaper's own Batmobile route, and Reaper never leaves the orbwalker clear toggle forced OFF.

Reaper captures its tracker, task helpers, inventory definitions and recorded
paths during plugin load. External calls from WarPigs then reuse those references
instead of resolving generic `core.*` / `tasks.*` modules in the caller's context.
This fixes the reported `reset_run` nil error during external startup while
keeping the existing navigation and waypoint-selection behavior.

Offline regressions exercise the scheduler, rotation, chest state, town callbacks, recorded paths, inventory counting, Alfred ownership, and known zone aliases. They do not certify live game identifiers, item costs, recorded routes, or Belial pixel coordinates. Existing settings keys and IDs are preserved. Validate these details in the running client before unattended use.
