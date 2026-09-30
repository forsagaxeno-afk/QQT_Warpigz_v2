# Alfred the Butler

Alfred handles all town management automatically: selling, salvaging, stashing, repairing, restocking, and teleporting back out. External farming scripts integrate with Alfred via a simple one-call API.

---

## How it works

Alfred scans the player's inventory every 0.5s and updates an internal `need_trigger` flag. This flag becomes true when any of the following conditions are met:

- Main inventory is full (`>= max_inventory` setting)
- Talisman inventory is full
- Socketable/consumable/key bags are full (when set to FULL mode)
- Any equipped item durability is <= 10
- Restock items fall below their minimum threshold

When `need_trigger` is true, Alfred expects an external script to hand it control. Alfred then teleports to town, runs the full task chain, and fires a callback when done.

---

## Integrating Alfred into your script

Add Alfred's task as **first priority** in your task list using `create_task`. The task names below (`run`, `fight`, etc.) are examples from your own script — replace them with whatever tasks your script actually has.

```lua
local alfred = AlfredTheButlerPlugin or PLUGIN_alfred_the_butler

local tasks = {
    alfred.create_task('my_script_name', function()
        -- called when Alfred finishes the town run
        -- reset your script state here
        -- e.g. clear run flags, force teleport back to dungeon, etc.
    end),
    require('tasks.my_run_task'),    -- your script's tasks go here
    require('tasks.my_fight_task'),
    -- ... rest of your tasks
}
```

Then in your update loop, iterate tasks in order — first `shouldExecute()` that returns true runs `Execute()`:

```lua
for _, task in ipairs(tasks) do
    if task.shouldExecute() then
        task.Execute()
        break
    end
end
```

Alfred's task is first in the list, so when `need_trigger` is true it intercepts before any of your tasks run. Your script is effectively paused until Alfred calls your callback.

---

## API reference

All functions are available on the global `AlfredTheButlerPlugin` (or `PLUGIN_alfred_the_butler`).

### `create_task(caller, on_done)` — recommended integration
Returns a task object (with `shouldExecute` and `Execute`) ready to drop into your task list. Handles all polling and state internally.

| Parameter | Type | Description |
|-----------|------|-------------|
| `caller` | string | Your script's label, used for logging |
| `on_done` | function | Called when Alfred completes the town run |

---

### `get_status()` — read Alfred's current state
Returns a table with the following fields:

| Field | Type | Description |
|-------|------|-------------|
| `enabled` | bool | Whether Alfred is enabled in settings |
| `need_trigger` | bool | True when a town run is needed — the main flag to watch |
| `inventory_full` | bool | Main inventory >= max_inventory setting |
| `talisman_inventory_full` | bool | Talisman bag >= max_inventory setting |
| `need_repair` | bool | Any equipped item durability <= 10 |
| `inventory_count` | number | Current main inventory item count |
| `sell_count` | number | Number of items queued to sell |
| `salvage_count` | number | Number of items queued to salvage |
| `stash_count` | number | Number of items queued to stash |
| `restock_count` | number | Number of restock items below minimum |
| `trigger_tasks` | bool | Alfred is currently running the task chain |
| `all_task_done` | bool | All tasks completed this cycle |

---

### `trigger_tasks_with_teleport(caller, callback)` — manual trigger
Tells Alfred to run the full town task chain including teleport. Use this if you need direct control instead of `create_task`.

---

### `pause(caller)` / `resume()` — movement control
Pause or resume Alfred's movement control. Alfred pauses Batmobile automatically during task runs.
