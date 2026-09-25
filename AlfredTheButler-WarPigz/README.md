# Alfred the Butler (WarPigz 1.0.0)

Town management for QQT: sell, salvage (equipment and talismans), stash, repair
and teleport back out, driven by your own rules or by an external farming
script. This is the WarPigz maintenance build of the **SteroidAlfredV2** fork of
**Alfred the Butler** (original author: Leoric). All credit for the original
plugin goes to its authors; this build fixes item classification and a list of
runtime problems and keeps the public API unchanged.

## Install

1. Copy `AlfredTheButler-WarPigz` into your QQT `scripts` folder.
2. **Disable or remove your old Alfred folder** (AlfredTheButler, SteroidAlfredV2
   or any other fork). Every Alfred publishes the same globals
   (`AlfredTheButlerPlugin`, `PLUGIN_alfred_the_butler`). If another Alfred
   already holds those globals when this one loads, or replaces them later,
   this build prints a console warning, shows it at the top of its menu and
   stays idle (it never runs a second set of town cycles); remove the other
   folder and reload.
3. Your settings carry over: the plugin label is still `alfred_the_butler`.
   New options (per-rarity charm/seal actions, mythic protection) start at the
   safe defaults below.

## What changed in WarPigz 1.0.0

### Mythics are always kept (default)

* A mythic is an item with runtime rarity **8** (the new *Mythic Uniques*,
  mythic charms, mythic seals) **or** an SNO the item database lists as an
  uber/mythic. The old fork only knew a fixed list of 13 uber SNO ids, so every
  new Mythic Unique fell through to the legendary/unique rules and could be
  salvaged or sold, and mythic charms defaulted to salvage.
* **Mythic protection → Always keep mythics** (on by default) keeps every
  mythic whatever the other rules say, in-game loot filter included. Turn it
  off only if you want the mythic action / keep list (Ancestral tree) and the
  *Mythic* tier of the charm and seal settings to apply.
* The mythic keep list in the GUI is built from the item database, not a
  hardcoded list.

### Charms and seals

* Detection: item database group by SNO, then skin name (`Talisman_Seal`,
  `Generic_Charm_`, `Talisman…Charm/Seal`), then (talisman bag only) display
  name. A charm whose skin contains "Ring" or "Sword" is no longer taken for a
  ring or a weapon.
* Per type (charm, seal): an action (Keep / Salvage / Sell) for each rarity
  tier — Magic, Rare, Legendary, Unique, Set, Mythic. Defaults: Magic and Rare
  are salvaged, Legendary and above are kept.
* *Min greater affixes to keep* per type (0 = off), the existing affix filter,
  and keep lists: unique/mythic charms, set charms (searchable), mythic and
  legendary seals. Checked items are always kept; unchecked ones follow the
  tier action.
* The talisman bag triggers a town run when it reaches *Max talisman items*
  (0 = same as *Max inventory items*), never above 33: the bag holds 33
  (LooteerV3 treats 33 as full; check yours with *Dump inventory item info*,
  which lists every bag item). The Occultist is only visited when a talisman
  is actually marked for salvage.
* An item whose rarity cannot be read and whose SNO the database does not
  know is **kept** (reason `rarity unknown` in the dump) instead of being
  treated as magic (salvaged) or as a non-unique.

### Debug

* **Debug → Dump inventory item info** (button, or the keybind next to it)
  prints, for every inventory and talisman-bag item: sno, rarity (and whether
  it came from the game or the database), tier, mythic flag and its source,
  skin name, display name, detected type/group and how it was detected, and
  the decision with its reason. Use it to check live that a Mythic Unique
  reports rarity 8.
* **Debug logging** turns the task logs on; they are off by default (the old
  fork printed several console lines every frame while stashing or salvaging
  talismans).

### Fixes

* LuaJIT/runtime: data files that are missing, 0 bytes, BOM-only or malformed
  no longer crash the load (`json.decode` on nil / non-table); every QQT item
  call is pcall-guarded; the settings update no longer indexes the gamble
  category lists (it threw when a saved index was out of range); search boxes
  accept `(`, `%` and other pattern characters; a caller name with pattern
  characters no longer breaks the status overlay.
* Tasks: a town task no longer fails on the first external trigger when the
  player already stands at the NPC (the status prefix `(caller) ` made the
  state check miss and the task fell through to *Failed*); sell/salvage use
  the loot filter consistently (the equipment loot filter used to mark items
  as both sell and salvage, so they were sold).
* External API: every caller waiting on a cycle gets its callback exactly once
  (a second trigger used to replace the first callback; a trigger without a
  callback kept a stale one); a trigger is refused (`false`) while Alfred is
  disabled; disabling Alfred mid-request drops the request so re-enabling does
  not run a stale cycle; `resume` no longer clears the caller of a running
  cycle; `create_task` stops waiting when Alfred is disabled.
* Disabling Alfred mid-cycle resumes the Batmobile it paused (it used to stay
  paused for every plugin until a later cycle completed).
* Stash full (or *Skip stashing cache* with a bag full of caches): the old
  fork held the cycle forever (`trigger_tasks`/`external_trigger` stayed true,
  no callback), so every farming plugin waited on "Alfred busy". Now the cycle
  ends as failed: each waiting callback is called once with `'failed'`,
  `get_status()` reports `stuck = true`, `stuck_reason`, `need_trigger =
  false`, and triggers are refused (`false`) until you free stash space and
  use the manual trigger, disable/enable Alfred, or the bag no longer needs a
  town run.
* Batmobile is resumed only if Alfred paused a running Batmobile. Alfred no
  longer writes Looter settings (`setSettings('looting', ...)`): before the
  teleport it waits, read-only, while Looter is busy (`is_actively_looting`),
  at most 8 s (the old fork could wait forever).
* The inventory item export (`data/export/items-*.json`) is written only when
  keybinds are used and the export keybind is on (it used to write a file on
  every town run).
* The lite explorer no longer writes the global `exploration_mode`, calls the
  undefined `find_target()`/global `world`, or draws debug text at every path
  point every frame.
* The unregistered gamble/restock/stocktake tasks were removed.

## Integrating Alfred into your script

```lua
local alfred = AlfredTheButlerPlugin or PLUGIN_alfred_the_butler
local tasks = {
    alfred.create_task('my_script_name', function()
        -- called once when Alfred finished the town run
    end),
    require('tasks.my_run_task'),
}
```

### API

| Function | Notes |
|---|---|
| `get_status()` | table, see below |
| `create_task(caller, on_done)` | task object (`shouldExecute`, `Execute`) for your task list |
| `trigger_tasks(caller, cb)` / `trigger_tasks_with_teleport(caller, cb)` | returns `true` when accepted, `false` while Alfred is disabled or stuck; `cb` is called once when the cycle finished (`cb()`), or with `'failed'` when Alfred gave the cycle up (stash full) |
| `pause(caller)` / `resume(caller)` | return `true` |
| `enable()` / `disable()` | main toggle |
| `queue_stash_pull(sno, 'salvage'\|'sell')`, `get_pending_pulls()`, `clear_pending_pulls()` | stash pull queue |
| `get_item_decision(item, in_talisman_bag)` | `'keep'\|'salvage'\|'sell'`, reason, info |
| `dump_items()` | the *Dump inventory item info* output |

`get_status()` fields: `name`, `version`, `enabled`, `paused`, `paused_by`,
`external_caller`, `owner`, `external_trigger`, `pending` (requested, chain not
started), `running` (chain running), `trigger_tasks`, `teleport`,
`teleport_done`, `teleport_failed`, `need_trigger`, `inventory_full`,
`talisman_inventory_full`, `need_repair`, `inventory_count`, `talisman_count`,
`salvage_count`, `salvage_talisman_count`, `sell_count`, `stash_count`,
`restock_count` (always 0: this fork does not restock), `last_reset`,
`salvage_done`, `salvage_failed`, `sell_done`, `sell_failed`, `stash_full`,
`all_task_done`, `stuck`, `stuck_reason`, `item_db_version`.

## Item database and self-learning catalog

Classification does not depend on any database: a mythic is recognised by its
runtime rarity (8) — since Season 15 any Unique can be Mythic (Horadric Cube
upgrade) and any Unique Charm can drop Mythic, so no fixed list can be complete;
a Unique on the unique keep list is also kept in its Mythic form — charms and seals by their internal skin name
(`Talisman_Charm*`, `Talisman_Seal*`). The database only fills the GUI lists
(keep lists by name) before an item has ever dropped.

`data/item_db.lua` is generated by `audit/tools/gen_alfred_item_db.py` from
**DiabloTools/d4data** (https://github.com/DiabloTools/d4data), the JSON dump of
Diablo IV's game files: every iconic Mythic Unique (equipment, charms, seals) and every
charm and Horadric seal with its English name and, when fixed, its rarity. The
file header records the d4data commit it was built from. Regenerate after a game
patch (the script's docstring shows the sparse checkout, about 150 MB):

```
python3 audit/tools/gen_alfred_item_db.py <d4data checkout>
```

Items newer than the database are learned in game: a unique, set or mythic
charm or seal, or a mythic item, whose SNO is not in the database is written to
`data/seen_items.lua` in this folder (at most every 30 s) and merged into the
lists on the next load. Delete that file to forget them.

The affix, aspect and unique lists in `data/affix/` come unchanged from
SteroidAlfredV2. `core/json.lua` is rxi's json.lua (MIT, notice in the file).
