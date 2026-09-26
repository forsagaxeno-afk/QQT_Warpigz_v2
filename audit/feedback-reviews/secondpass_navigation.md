# Independent second-pass navigation audit

Scope: every Lua file under Batmobile-1.0.12 and Reaper-main in the current feedback worktree. These modules were reviewed independently of their initial implementation agent. Runtime edits were authorized by the root agent after the first concrete findings.

## Findings and fixes

1. **Autonomous Batmobile updates undid external pause.** Main called unpause on every long-route/freeroam update. The automatic driver now yields while paused; explicit external `move()` still works, because combat callers use pause to stop exploration while pursuing their own target. A new manual freeroam toggle explicitly resumes. Tested actual main/external/navigator/long_path interaction.
2. **Reaper handoff recognized only old Alfred trigger flags.** A status with `running`, `teleport` or `pending` could be overwritten; cleanup could erase Alfred's Batmobile route. Handoff and navigation release now honor these flags and unreadable status. Tests cover each shape and normal cleanup.
3. **Unavailable actor stream could imply reward completion.** `open_chest` returned nil for both absence and invalid actor data. Sustained invalid samples could consume a run after the loot wait. The scan now reports readability and unknown samples cannot complete, including invalidating a partly elapsed absence interval. The altar task likewise cannot infer activation from a missing actor stream. Valid observable transitions retain their existing behavior.
4. **Traversal debug overlay treated an actor as a vector.** `last_trav:x()`/`:y()` were invalid on the documented actor shape. Drawing now reads `get_position()` and ignores a stale handle. Both cases are covered.

5. **Reaper could resume an unowned Alfred pause or wait forever after a lost callback.** Followup peer review confirmed these remaining lifecycle defects. Reaper now never pauses/resumes Alfred, waits on paused/pending/unknown status, accepts legacy nil without declaring success, and reconciles missing callbacks after an 8-second pickup allowance followed by 2 seconds of freshly observed readable idle. Retiring a request invalidates callbacks and applies a 5-second retry delay; it does not declare maintenance successful. A trigger exception may follow an enqueue, so that reservation is preserved until reconciliation. Callback validation also checks plugin identity and current waiting state. Missing status methods/schema preserve foreign navigation; terminal teleport done/failed latches do not count as an active trip.

No broad pathfinding or route-coordinate rewrite was made. The earlier user report that movement improved is respected.

## Coverage method

All 63 Lua files were enumerated and read: 38 contain executable logic and 25 are static recorded route tables. The inventory below distinguishes these categories. Function sites include named functions and anonymous callbacks; the listing is a source-review index, not a claim that every branch ran in a game. Pure coordinate rows were inspected as data, including finite numbers, interaction markers, point counts and consecutive-point gaps.

### Executable files

| File | Lines at review | Function declaration lines | Review focus |
|---|---:|---:|---|
| `Batmobile-1.0.12/core/drawing.lua` | 255 | 4 | All overlay/caching functions read; fixed traversal actor/vec3 mismatch; stale traversal handle skips drawing. |
| `Batmobile-1.0.12/core/explorer.lua` | 830 | 21 | Frontier spatial buckets, visited/retry bookkeeping, distance/direction selection, backtrack restore, scan/eviction and reset read. Existing scoring/route behavior retained. |
| `Batmobile-1.0.12/core/external.lua` | 278 | 26 | All public exports read; pause intentionally permits explicit caller moves; autonomous driver now honors it. Requires captured at bootstrap. |
| `Batmobile-1.0.12/core/long_path.lua` | 214 | 8 | Launch, partial path, debug/runtime caps, route ownership by driving flag, traversal pending and cancellation read; no independent callback remains after stop. |
| `Batmobile-1.0.12/core/movement_conditions.lua` | 115 | 8 | All condition evaluators and AND/OR fold read; evaluator errors fail conditions. |
| `Batmobile-1.0.12/core/movement_engine.lua` | 127 | 3 | Rule order, throttle, node/density target selection and override results read; existing skill/cast policy retained. |
| `Batmobile-1.0.12/core/movement_helpers.lua` | 251 | 13 | Buff lookup/catalog, casting/enemy caches and density sampler read; no mutation of other plugin pause state. |
| `Batmobile-1.0.12/core/movement_rules.lua` | 121 | 3 | Skill/condition/operator registries and helper functions read; numeric IDs are supplied-source data, not revalidated against live game. |
| `Batmobile-1.0.12/core/navigator.lua` | 2372 | 25 | All target selection, traversal, move spell, path retry, pause/reset, trap detection/escape functions and move branches read. Custom movement while paused is intentional and regression-preserved. |
| `Batmobile-1.0.12/core/pathfinder.lua` | 535 | 17 | Heap operations, A*, wall cache, partial reconstruction, LOS/string-pull, debug and normal budgets read. Live mesh correctness cannot be proven offline. |
| `Batmobile-1.0.12/core/settings.lua` | 150 | 3 | All rule/widget conversion and update functions read; combo indexing and bounded counts checked. |
| `Batmobile-1.0.12/core/tracker.lua` | 140 | 7 | All benchmark and event-report callbacks read; counters do not navigate. |
| `Batmobile-1.0.12/core/utils.lua` | 152 | 19 | All geometry, actor/zone/loading, CC/class and logging helpers read. |
| `Batmobile-1.0.12/gui.lua` | 427 | 8 | All widget construction and render callbacks read; retained registry keys and bounded rule slots. |
| `Batmobile-1.0.12/main.lua` | 148 | 5 | All update/render callbacks read; fixed automatic unpause that bypassed caller pause; manual freeroam rising edge remains explicit resume. |
| `Reaper-main/core/boss_rotation.lua` | 424 | 20 | All selection, pool, external one-shot, consume/skip/reset functions read. Failed external runs do not become successful callbacks. |
| `Reaper-main/core/explorerlite.lua` | 587 | 35 | Heap/A*, target/unstuck, movement and reset functions read, including unused exploration helpers. No asynchronous movement callback is registered here. |
| `Reaper-main/core/input.lua` | 93 | 10 | All relative/pixel keyboard/mouse wrappers read; legacy map helpers are not the active teleport path. |
| `Reaper-main/core/map_nav.lua` | 118 | 11 | All start/update/state and teleport retry functions read; exact boss alias matching and bounded per-phase attempts checked. |
| `Reaper-main/core/materials.lua` | 174 | 22 | All bag read, stack/identity deduplication, stock-selection and dump functions read. Missing inventory is conservative no-stock; SNO/cost data still require live confirmation. |
| `Reaper-main/core/navigation_owner.lua` | 22 | 2 | Both ownership functions read; release now preserves Alfred running/teleport/pending routes and unreadable status, not just trigger flags. |
| `Reaper-main/core/pathwalker.lua` | 299 | 14 | All point normalization, nearest/lookahead, interaction, jitter, stuck skip and completion/reset functions read; interaction points remain explicit barriers. |
| `Reaper-main/core/settings.lua` | 157 | 3 | All settings synchronization and tracked orbwalker ownership functions read. |
| `Reaper-main/core/task_manager.lua` | 78 | 4 | All registration/scheduling/reset functions read; reset uses captured tracker/utils and logs task reset errors. |
| `Reaper-main/core/tracker.lua` | 46 | 3 | All reset/timing helpers and flags read; per-run flags reset independently of session totals. |
| `Reaper-main/core/utils.lua` | 167 | 19 | All actor/zone/quest/movement helpers read; altar scan now returns validity separately. Legacy boss-quest completion helper has no runtime callers in current registered tasks. |
| `Reaper-main/data/enums.lua` | 180 | 3 | All actor/zone/SNO/seed tables and three helper functions read. Alias matching covers documented Varshan/Grigoire names. |
| `Reaper-main/gui.lua` | 227 | 4 | All widget construction/render functions read; preserves existing per-boss, town, Belial and orbwalker controls. |
| `Reaper-main/main.lua` | 362 | 11 | All enable/start/stop/render/public API closures read; captured dependencies and reset-before-callback reentrancy checked. |
| `Reaper-main/tasks/alfred.lua` | 191 | 11 | All discovery/status/generation/trigger/task functions read; modern busy and unknown status now yield without overwriting another cycle. |
| `Reaper-main/tasks/belial_chest.lua` | 401 | 16 | All reference-coordinate, target selection, UI retry and phase functions read; user-calibrated pixel flow retained and requires live layout check. |
| `Reaper-main/tasks/dungeon_reset.lua` | 102 | 4 | All reset predicate and phase logic read; live boss/chest gates and out-of-dungeon reset flow retained. |
| `Reaper-main/tasks/interact_altar.lua` | 206 | 7 | All reset/stuck/visibility/task functions read; unavailable actor scan no longer counts as altar activation. |
| `Reaper-main/tasks/kill_monsters.lua` | 74 | 5 | All anchor/predicate/execute/reset functions read; combat ownership flags have cleanup, reward task precedes persistent combat. |
| `Reaper-main/tasks/navigate_to_boss.lua` | 816 | 16 | All route loader, nearest/endpoint helpers, predicates, state/reset and phase branches read; route modules are preloaded in Reaper context. |
| `Reaper-main/tasks/open_chest.lua` | 254 | 12 | All actor scan, phase, cooldown/stuck/reset/task functions read; unknown actor samples invalidate the completion observation interval. |
| `Reaper-main/tasks/revive.lua` | 109 | 7 | All alive/death/settle state and predicate/reset functions read; no success completion callback from recovery. |
| `Reaper-main/tasks/sigil_complete.lua` | 150 | 6 | Legacy inactive module fully read; enemy-absence heuristic is not registered and external sigil requests are rejected. |

### Static route tables

All 25 files contain only point construction/table data and a return; no callbacks or runtime control flow. They cover all ten configured boss IDs. Their coordinates were preserved. Maximum-gap checks describe the recorded data and do not validate live collision meshes.

| File | Points | Interaction markers | Maximum consecutive 3D gap |
|---|---:|---:|---:|
| `Reaper-main/paths/andariel_a.lua` | 130 | 0 | 1.18 |
| `Reaper-main/paths/andariel_b.lua` | 264 | 0 | 0.77 |
| `Reaper-main/paths/andariel_c.lua` | 249 | 0 | 0.98 |
| `Reaper-main/paths/beast_a.lua` | 96 | 0 | 1.35 |
| `Reaper-main/paths/beast_b.lua` | 106 | 0 | 1.27 |
| `Reaper-main/paths/beast_c.lua` | 179 | 0 | 0.86 |
| `Reaper-main/paths/belial_a.lua` | 113 | 0 | 1.06 |
| `Reaper-main/paths/butcher_a.lua` | 79 | 0 | 1.10 |
| `Reaper-main/paths/butcher_b.lua` | 88 | 0 | 1.45 |
| `Reaper-main/paths/duriel_a.lua` | 131 | 1 | 3.36 |
| `Reaper-main/paths/duriel_b.lua` | 121 | 0 | 1.11 |
| `Reaper-main/paths/duriel_c.lua` | 234 | 2 | 3.27 |
| `Reaper-main/paths/grigoire_a.lua` | 97 | 0 | 1.35 |
| `Reaper-main/paths/grigoire_b.lua` | 95 | 0 | 1.33 |
| `Reaper-main/paths/grigoire_c.lua` | 126 | 0 | 1.29 |
| `Reaper-main/paths/harbinger_a.lua` | 181 | 0 | 1.27 |
| `Reaper-main/paths/harbinger_b.lua` | 157 | 0 | 1.18 |
| `Reaper-main/paths/urivar_a.lua` | 111 | 0 | 1.09 |
| `Reaper-main/paths/urivar_b.lua` | 101 | 0 | 1.08 |
| `Reaper-main/paths/varshan_a.lua` | 103 | 0 | 1.18 |
| `Reaper-main/paths/varshan_b.lua` | 116 | 0 | 1.15 |
| `Reaper-main/paths/varshan_c.lua` | 168 | 0 | 0.70 |
| `Reaper-main/paths/varshan_d.lua` | 155 | 0 | 0.80 |
| `Reaper-main/paths/zir_a.lua` | 164 | 0 | 1.22 |
| `Reaper-main/paths/zir_b.lua` | 137 | 0 | 1.24 |

Total recorded points read: 3501.

## Cross-module review

- Batmobile public calls capture navigator/explorer/tracker/long_path/pathfinder at bootstrap. Paused explicit movement is intentional; autonomous movement must respect it.
- Reaper task_manager captures tracker/utils at bootstrap. Route variants preload before an external orchestrator can change the active import context. No late generic require remains on the external enable/reset/navigation paths.
- Reaper external run_once/run_boss rejects an already-enabled plugin. A successful completion resets/stops before calling the saved callback, permitting a reentrant new request. Manual stop discards the callback. Failed external rotations do not invoke success.
- Batmobile long route remains active through temporary nil targets during traversal and stop resets traversal escape fields. Reaper navigation and altar reset release only their tracked route; a visibly active/unknown Alfred is preserved.
- Reaper reward tasks precede persistent combat. Missing actor data is now distinct from a confirmed actor disappearance.

## Validation

Command: `python3 audit/tests/run_tests.py test_secondpass_navigation.lua test_batmobile.lua test_reaper.lua test_batmobile_integration.lua`.

Result: 84 new independent checks passed, plus existing Batmobile (84 assertions), Reaper (66 assertions), and shared traversal regression. The runner compiled all 201 runtime Lua files present at followup execution. No live game-client session was performed.

## Remaining limits and explicit classifications

- Alfred forks without a visible queue/pause owner cannot provide a formal ownership lease. The pickup/idle recovery is a bounded compatibility heuristic, not proof that an invisible indefinitely deferred request can never appear later. Observed busy or unknown status always preserves the wait.
- The current navigation API has no enforced caller-token lease. Reaper's local claim and companion status checks mitigate known handoff conflicts; they cannot prove ownership if unrelated code silently replaces a route without exposing state.
- Recorded route interaction points still use the supplied fixed post-interaction wait. Live traversal confirmation depends on the game/API; no speculative new transition signal was invented. Three interaction markers exist in the Duriel routes.
- Batmobile's custom target/mesh behavior, wall sampling and movement skill IDs retain the supplied implementation. The final grid-neighbor goal special case and optional smoothing require live geometry validation, especially near multiple floors.
- Reaper's legacy `is_boss_quest_complete` helper can interpret unreadable quest data as absent, but there are no runtime callers in the registered current flow; actual run completion is chest-driven. The unregistered sigil task is likewise inactive and explicit sigil launch is rejected.
- Belial reward selection is an existing user-calibrated pixel flow. Source review and coordinate scaling checks cannot verify a changed game dialog layout.
- UI constructors and render callbacks were reviewed for the current source shapes; a mock runner does not certify native widget safety or host performance.

## Function/callback source index

### Batmobile-1.0.12/core/drawing.lua

- Line 21: `local function refresh_nav_viz(player_pos, valid_z)`
- Line 41: `local get_max_length = function(messages)`
- Line 50: `drawing.draw_nodes = function (local_player)`
- Line 158: `local ok, pos = pcall(function() return navigator.last_trav:get_position() end)`

### Batmobile-1.0.12/core/explorer.lua

- Line 55: `local function direction_penalty(node, from_pos)`
- Line 97: `local function chunk_key(x, y)`
- Line 101: `local add_frontier = function (node_str, node)`
- Line 116: `local remove_frontier = function (node_str)`
- Line 136: `local add_visited = function (node_str)`
- Line 147: `explorer.clear_frontiers_in_box = function(min_x, max_x, min_y, max_y)`
- Line 177: `local remove_visited = function (node_str)`
- Line 183: `local add_retry = function (node_str)`
- Line 189: `local remove_retry = function (node_str)`
- Line 198: `local has_unscanned_neighbor = function (node_x, node_y, step)`
- Line 208: `local check_perimeter_node = function (perimeter, cx, cy, node_x, node_y, z)`
- Line 221: `local get_perimeter = function (node)`
- Line 252: `local pick_closest_frontier = function ()`
- Line 281: `local restore_backtrack = function ()`
- Line 334: `local select_node_distance = function ()`
- Line 462: `local select_node_direction = function (failed)`
- Line 609: `explorer.reset = function ()`
- Line 633: `explorer.set_priority = function (priority)`
- Line 642: `explorer.set_current_pos = function (local_player)`
- Line 660: `explorer.update = function (local_player)`
- Line 800: `explorer.select_node = function (local_player, failed)`

### Batmobile-1.0.12/core/external.lua

- Line 13: `external.is_done = function ()`
- Line 16: `external.is_paused = function ()`
- Line 19: `external.pause = function (caller)`
- Line 28: `external.resume = function (caller)`
- Line 37: `external.reset = function (caller)`
- Line 49: `external.reset_movement = function (caller)`
- Line 59: `external.move = function (caller)`
- Line 73: `external.update = function (caller)`
- Line 86: `external.set_target = function(caller, target, disable_spell)`
- Line 95: `external.clear_target = function (caller)`
- Line 104: `external.get_backtrack = function(caller)`
- Line 113: `external.set_priority = function(caller, priority)`
- Line 126: `external.find_long_path = function(caller, target)`
- Line 141: `external.navigate_long_path = function(caller, target)`
- Line 157: `external.is_long_path_navigating = function()`
- Line 170: `external.get_closeby_node = function(caller, target, max_dist)`
- Line 185: `external.try_traversal_route = function(caller)`
- Line 199: `external.is_traversal_routing = function()`
- Line 204: `external.stop_long_path = function(caller)`
- Line 215: `external.get_target = function()`
- Line 220: `external.get_path = function()`
- Line 229: `external.get_last_pathfind = function()`
- Line 236: `external.clear_traversal_blacklist = function(caller)`
- Line 254: `external.is_giving_up = function()`
- Line 261: `external.is_trapped = function()`
- Line 268: `external.clear_giving_up = function(caller)`

### Batmobile-1.0.12/core/long_path.lua

- Line 23: `function long_path.set_target()`
- Line 36: `function long_path.set_target_cursor()`
- Line 49: `local function start_navigation(path, goal)`
- Line 88: `function long_path.is_traversal_pending()`
- Line 92: `function long_path.stop_navigation()`
- Line 105: `function long_path.test_path()`
- Line 159: `function long_path.find_long_path(start, goal)`
- Line 177: `function long_path.navigate_to(goal)`

### Batmobile-1.0.12/core/movement_conditions.lua

- Line 18: `local function _eval_buff_active(cs, ctx)`
- Line 25: `local function _eval_buff_not_active(cs, ctx)`
- Line 32: `local function _eval_buff_stacks(cs, ctx)`
- Line 41: `local function _eval_skill_ready(cs, ctx)`
- Line 52: `local function _eval_distance(cs, ctx)`
- Line 64: `local function _eval_path_pack_density(cs, ctx)`
- Line 81: `conditions.eval_one = function (cs, ctx)`
- Line 93: `conditions.eval_list = function (list, ctx)`

### Batmobile-1.0.12/core/movement_engine.lua

- Line 22: `local function _pick_next_node_pos(path, player_pos, range, min_req, blacklist)`
- Line 41: `local function _pick_pack_pos(path, density_radius, range, player_pos, min_req)`
- Line 57: `engine.pick = function (rule_state_list, ctx)`

### Batmobile-1.0.12/core/movement_helpers.lua

- Line 12: `helpers.can_cast = function (skill_id)`
- Line 30: `helpers.get_player_buffs = function (local_player)`
- Line 35: `local function _buff_hash(b)`
- Line 46: `local function _buff_name(b)`
- Line 64: `helpers.find_buff = function (buffs, name_hash)`
- Line 72: `helpers.buff_stacks = function (buff)`
- Line 90: `local function _looks_like_bad_name(s)`
- Line 99: `helpers.observe_buffs = function (local_player)`
- Line 139: `helpers.buff_combo_items = function ()`
- Line 155: `helpers.seed_buff_hash = function (hash)`
- Line 168: `helpers.buff_hash_for_combo_index = function (idx)`
- Line 181: `helpers.get_enemies = function ()`
- Line 210: `helpers.largest_pack_on_path = function (path, radius)`

### Batmobile-1.0.12/core/movement_rules.lua

- Line 87: `rules.apply_op = function (op, a, b)`
- Line 98: `rules.equipped_movement_skills = function ()`
- Line 114: `rules.skill_combo_items = function (equipped_only)`

### Batmobile-1.0.12/core/navigator.lua

- Line 125: `local function is_trav_blacklisted(trav_str, now)`
- Line 143: `local function compute_escape_target(trav_pos, player_pos)`
- Line 180: `local get_nearby_travs = function (local_player)`
- Line 200: `local has_traversal_buff = function (local_player)`
- Line 218: `local get_closeby_node = function (trav_node, max_dist)`
- Line 241: `table.sort(nodes, function(a, b)`
- Line 277: `local function try_traversal_route(local_player, player_pos)`
- Line 327: `local get_movement_spell_id = function(local_player)`
- Line 432: `select_target = function (prev_target)`
- Line 531: `local function shuffle_table(tbl)`
- Line 541: `local get_unstuck_node = function ()`
- Line 580: `local unstuck = function (local_player)`
- Line 640: `navigator.is_done = function ()`
- Line 643: `navigator.pause = function ()`
- Line 647: `navigator.unpause = function ()`
- Line 651: `navigator.update = function ()`
- Line 691: `navigator.reset_movement = function ()`
- Line 734: `navigator.record_failed_direction = function (player_pos, target_pos)`
- Line 780: `navigator.reset = function ()`
- Line 800: `navigator.set_target = function (target, disable_spell)`
- Line 861: `navigator.clear_target = function ()`
- Line 868: `navigator.move = function ()`
- Line 1910: `navigator.update_trap_state = function(local_player)`
- Line 2025: `navigator.attempt_escape = function(local_player)`
- Line 2359: `navigator.clear_trap_state = function()`

### Batmobile-1.0.12/core/pathfinder.lua

- Line 29: `local function new_heap()`
- Line 32: `function Heap:push(f, node_str, node)`
- Line 45: `function Heap:pop()`
- Line 69: `function Heap:empty() return self.size == 0 end`
- Line 70: `local heuristic = function (a, b)`
- Line 75: `local reconstruct_path = function (closed_set, prev_nodes, cur_node)`
- Line 108: `local function wp_key(node_str, z)`
- Line 111: `pathfinder.clear_wall_penalty_cache = function()`
- Line 115: `local get_valid_neighbor = function (cur_node, goal, x, y, evaluated, ignore_walls, directions)`
- Line 169: `local get_neighbors = function (node, goal, evaluated, ignore_walls, directions)`
- Line 195: `local function has_los(a, b, step)`
- Line 218: `local function string_pull(path, step)`
- Line 244: `local function pull_bench(path, step)`
- Line 253: `local function pf_bucket(counter)`
- Line 260: `pathfinder.find_path = function (start, goal, is_custom_target, shared_evaluated, time_cap_override)`
- Line 352: `local function pf_return(path, is_partial, status)`
- Line 446: `pathfinder.find_path_debug = function(start, goal, opts)`

### Batmobile-1.0.12/core/settings.lua

- Line 43: `local function _read_rule(slot)`
- Line 103: `local function _read_all_rules()`
- Line 115: `settings.update_settings = function ()`

### Batmobile-1.0.12/core/tracker.lua

- Line 31: `tracker.bench_start = function(name)`
- Line 41: `tracker.bench_stop = function(name, meta)`
- Line 67: `tracker.bench_count = function(name)`
- Line 75: `tracker.bench_set_meta = function(name, meta)`
- Line 80: `tracker.bench_report = function()`
- Line 99: `table.sort(entries, function(a, b) return a.data.total > b.data.total end)`
- Line 126: `table.sort(cnt_entries, function(a, b) return a.name < b.name end)`

### Batmobile-1.0.12/core/utils.lua

- Line 7: `utils.distance_to = function (target)`
- Line 19: `utils.is_same_position = function (pos1, pos2)`
- Line 22: `utils.is_mounted = function ()`
- Line 26: `utils.player_in_zone = function (zname)`
- Line 31: `utils.player_loading = function ()`
- Line 36: `utils.player_in_town = function()`
- Line 43: `utils.in_combat = function (local_player)`
- Line 47: `utils.is_cced = function (local_player)`
- Line 61: `utils.normalize_value = function (val)`
- Line 65: `utils.normalize_node = function (node)`
- Line 70: `utils.vec_to_string = function (node)`
- Line 74: `utils.string_to_vec = function (str)`
- Line 81: `utils.distance = function (a, b)`
- Line 92: `utils.distance_z = function (a, b)`
- Line 95: `utils.get_set_count = function (set)`
- Line 102: `utils.get_character_class = function (local_player)`
- Line 125: `utils.log = function (level, msg)`
- Line 131: `utils.debug_log = function (format, ...)`
- Line 136: `utils.get_valid_node = function (node, alt_z)`

### Batmobile-1.0.12/gui.lua

- Line 8: `local get_character_class = function (local_player)`
- Line 34: `local function create_checkbox(value, key)`
- Line 98: `local function _mvr_hash(suffix)`
- Line 140: `local function _build_skill_labels()`
- Line 164: `function gui.render_movement_revamp()`
- Line 183: `local seed_ok, seed_err = pcall(function ()`
- Line 243: `local ok, err = pcall(function ()`
- Line 299: `function gui.render()`

### Batmobile-1.0.12/main.lua

- Line 25: `local function update_locals()`
- Line 32: `local function main_pulse()`
- Line 133: `local function render_pulse()`
- Line 139: `on_update(function()`
- Line 144: `on_render_menu(function ()`

### Reaper-main/core/boss_rotation.lua

- Line 53: `local function pool_runs_for(boss)`
- Line 62: `local function refresh_runs_remaining()`
- Line 68: `local function any_runs_available()`
- Line 82: `local function advance_roundrobin(start_after)`
- Line 97: `local function advance_random()`
- Line 112: `local function advance_manual()`
- Line 119: `local function advance_to_runnable(start_after)`
- Line 128: `local function load_pools_from_inventory()`
- Line 138: `function rotation.build(settings)`
- Line 164: `local function add_entry(bd)`
- Line 235: `function rotation.current()`
- Line 241: `function rotation.is_done()`
- Line 247: `function rotation.pool_summary()`
- Line 257: `function rotation.runs_for_tier(tier)`
- Line 267: `function rotation.consume_run()`
- Line 321: `function rotation.advance(reason)`
- Line 346: `function rotation.resync_pools()`
- Line 355: `function rotation.set_external(boss_id, run_type)`
- Line 407: `function rotation.clear_external()`
- Line 415: `function rotation.reset()`

### Reaper-main/core/explorerlite.lua

- Line 4: `function MinHeap.new(compare)`
- Line 5: `return setmetatable({heap = {}, compare = compare or function(a, b) return a < b end}, MinHeap)`
- Line 8: `function MinHeap:push(value)`
- Line 13: `function MinHeap:pop()`
- Line 21: `function MinHeap:peek()`
- Line 25: `function MinHeap:empty()`
- Line 29: `function MinHeap:siftUp(index)`
- Line 38: `function MinHeap:siftDown(index)`
- Line 52: `function MinHeap:contains(value)`
- Line 101: `function explorerlite:clear_path_and_target()`
- Line 108: `local function calculate_distance(point1, point2)`
- Line 117: `local function set_height_of_valid_position(point)`
- Line 121: `local function get_grid_key(point)`
- Line 136: `local function update_explored_area_bounds(point, radius)`
- Line 145: `local function is_point_in_explored_area(point)`
- Line 154: `local function find_unstuck_target()`
- Line 182: `local function handle_stuck_player()`
- Line 221: `function explorerlite:reset_exploration()`
- Line 240: `local function is_near_wall(point)`
- Line 260: `local function find_random_explored_target()`
- Line 285: `function vec3.__add(v1, v2)`
- Line 289: `local function is_in_last_targets(point)`
- Line 298: `local function add_to_last_targets(point)`
- Line 310: `local function heuristic(a, b)`
- Line 315: `local function get_neighbors(point)`
- Line 353: `local function reconstruct_path(came_from, current)`
- Line 385: `local function a_star(start, goal)`
- Line 392: `local open_set = MinHeap.new(function(a, b)`
- Line 446: `local function check_if_stuck()`
- Line 464: `function explorerlite:set_custom_target(target)`
- Line 468: `function explorerlite:movement_spell_to_target(target)`
- Line 499: `local function move_to_target()`
- Line 554: `local function move_to_target_aggressive()`
- Line 563: `function explorerlite:move_to_target()`
- Line 582: `on_render(function()`

### Reaper-main/core/input.lua

- Line 17: `local function rel(rx, ry)`
- Line 37: `function input.key_press(vk_code)`
- Line 45: `function input.click_rel(rx, ry)`
- Line 50: `function input.right_click_rel(rx, ry)`
- Line 55: `function input.move_rel(rx, ry)`
- Line 62: `function input.scroll_rel(rx, ry, delta)`
- Line 71: `function input.click_px(x, y)`
- Line 75: `function input.scroll_px(x, y, delta)`
- Line 84: `function input.open_map()`
- Line 89: `function input.close_map()`

### Reaper-main/core/map_nav.lua

- Line 48: `local function now() return get_time_since_inject() end`
- Line 50: `local function in_boss_zone()`
- Line 56: `local function set_state(st)`
- Line 61: `local function elapsed() return now() - s.t end`
- Line 63: `local function do_teleport()`
- Line 78: `function map_nav.start(boss_id, zone_prefix)`
- Line 88: `function map_nav.is_done()   return s.state == STATE.DONE end`
- Line 89: `function map_nav.is_active() return s.state ~= STATE.IDLE and s.state ~= STATE.DONE end`
- Line 90: `function map_nav.reset()     s.state = STATE.IDLE; s.boss_id = nil end`
- Line 91: `function map_nav.get_state() return s.state end`
- Line 93: `function map_nav.update()`

### Reaper-main/core/materials.lua

- Line 43: `local function safe_count(item)`
- Line 44: `local ok, n = pcall(function() return item:get_stack_count() end)`
- Line 49: `local function get_dungeon_keys()`
- Line 52: `local ok, keys = pcall(function() return lp:get_dungeon_key_items() end)`
- Line 57: `local function get_consumables()`
- Line 60: `local ok, items = pcall(function() return lp:get_consumable_items() end)`
- Line 65: `local function is_lair_key_sno(sno)`
- Line 78: `function materials.scan_keys()`
- Line 86: `local function tally(items)`
- Line 89: `local id_ok, id = pcall(function() return item:get_acd() end)`
- Line 91: `id_ok, id = pcall(function() return item:get_id() end)`
- Line 94: `local ok, sno = pcall(function() return item:get_sno_id() end)`
- Line 114: `function materials.lair_runs_available()`
- Line 120: `function materials.belial_runs_available()`
- Line 128: `function materials.has_inventory_stock(settings)`
- Line 147: `local function dump(label, items)`
- Line 150: `local ok_sno, sno   = pcall(function() return item:get_sno_id() end)`
- Line 151: `local ok_name, name = pcall(function() return item:get_name() end)`
- Line 152: `local ok_disp, disp = pcall(function() return item:get_display_name() end)`
- Line 153: `local ok_cnt, cnt   = pcall(function() return item:get_stack_count() end)`
- Line 161: `function materials.print_all_keys()`
- Line 166: `function materials.print_summary()`

### Reaper-main/core/navigation_owner.lua

- Line 4: `function owner.claim() owner.active = true end`
- Line 5: `function owner.release()`

### Reaper-main/core/pathwalker.lua

- Line 35: `local function now() return get_gametime() end`
- Line 40: `function M.point_position(p)`
- Line 47: `local function normalise(points)`
- Line 59: `local function find_target_index(player_pos)`
- Line 90: `local function try_interact(wp_pos)`
- Line 97: `local ok, inter = pcall(function() return actor:is_interactable() end)`
- Line 124: `local function jitter_path(path)`
- Line 152: `function M.start_walking_path_with_points(points, path_name, _force, start_index)`
- Line 179: `function M.stop_walking()`
- Line 191: `function M.is_path_completed()`
- Line 195: `function M.is_at_final_waypoint()`
- Line 202: `function M.get_progress() return M.current_waypoint_index, #M.current_path end`
- Line 203: `function M.get_status()`
- Line 212: `function M.update_path_walking()`

### Reaper-main/core/settings.lua

- Line 61: `function settings:update_settings()`
- Line 143: `settings.orb_set_clear = function(v)`
- Line 150: `settings.orb_set_block = function(v)`

### Reaper-main/core/task_manager.lua

- Line 15: `function task_manager.register_task(task)`
- Line 19: `function task_manager.execute_tasks()`
- Line 44: `function task_manager.get_current_task()`
- Line 48: `function task_manager.reset_all()`

### Reaper-main/core/tracker.lua

- Line 24: `function tracker.reset_run()`
- Line 36: `function tracker.check_time(key, delay)`
- Line 42: `function tracker.clear_key(key)`

### Reaper-main/core/utils.lua

- Line 8: `function utils.distance_to(target)`
- Line 20: `function utils.get_zone()`
- Line 25: `function utils.player_in_zone(zname)`
- Line 29: `function utils.match_player_zone(pattern)`
- Line 33: `function utils.in_boss_zone(boss)`
- Line 37: `function utils.get_altar()`
- Line 38: `local ok, actors = pcall(function() return actors_manager:get_all_actors() end)`
- Line 42: `local valid, name = pcall(function() return actor:get_skin_name() end)`
- Line 53: `function utils.get_dungeon_entrance()`
- Line 68: `function utils.get_suppressor()`
- Line 75: `function utils.get_town_portal()`
- Line 82: `function utils.get_closest_enemy()`
- Line 102: `local function boss_quest_present()`
- Line 106: `local ok_n, name = pcall(function() return quest:get_name() end)`
- Line 116: `function utils.is_boss_quest_complete()`
- Line 133: `function utils.boss_quest_active()`
- Line 137: `local ok_n, name = pcall(function() return quest:get_name() end)`
- Line 147: `function utils.reset_boss_quest_tracking()`
- Line 156: `function utils.try_movement_spell(target_pos)`

### Reaper-main/data/enums.lua

- Line 57: `function enums.zone_matches(boss, zone)`
- Line 66: `function enums.is_boss_zone(zone)`
- Line 114: `function enums.positions.getBossRoomPosition(world_name)`

### Reaper-main/gui.lua

- Line 9: `local function cb(default, key)`
- Line 12: `local function si(min, max, default, key)`
- Line 15: `local function cbo(default_idx, key)`
- Line 120: `function gui.render()`

### Reaper-main/main.lua

- Line 42: `local function on_enable()`
- Line 106: `local function on_disable()`
- Line 119: `local function stop()`
- Line 128: `on_update(function()`
- Line 203: `on_render(function()`
- Line 257: `on_render(function()`
- Line 285: `enable  = function() gui.elements.main_toggle:set(true)  end,`
- Line 294: `run_boss = function(boss_id, run_type)`
- Line 320: `run_once = function(boss_id, run_type, on_complete)`
- Line 336: `clear_external = function()`
- Line 345: `status  = function()`

### Reaper-main/tasks/alfred.lua

- Line 23: `local function get_alfred()`
- Line 27: `local function get_alfred_status()`
- Line 50: `local function is_busy(status)`
- Line 56: `local function clear_request()`
- Line 60: `local function retire_request()`
- Line 67: `local function waiting_for_request(status)`
- Line 81: `function task.reset()`
- Line 89: `local function trigger_alfred()`
- Line 100: `local ok, accepted = pcall(a.trigger_tasks_with_teleport, plugin_label, function()`
- Line 119: `function task.shouldExecute()`
- Line 170: `function task.Execute()`

### Reaper-main/tasks/belial_chest.lua

- Line 50: `local function resolve(ref_x, ref_y)`
- Line 60: `local function ref_points(cfg)`
- Line 81: `local function click_at(ref_x, ref_y, label)`
- Line 107: `local function click_target(boss_id)`
- Line 122: `open   = function()`
- Line 126: `modify = function()`
- Line 130: `scroll = function()`
- Line 139: `local function in_belial_zone()`
- Line 143: `local function find_belial_chest()`
- Line 149: `local ok, inter = pcall(function() return a:is_interactable() end)`
- Line 161: `local function pick_target()`
- Line 203: `local function set_state(st)`
- Line 208: `local function elapsed()`
- Line 215: `function task.reset()`
- Line 224: `function task.shouldExecute()`
- Line 236: `function task.Execute()`

### Reaper-main/tasks/dungeon_reset.lua

- Line 28: `local function now() return get_time_since_inject() end`
- Line 32: `function task.reset()`
- Line 38: `function task.shouldExecute()`
- Line 52: `function task.Execute()`

### Reaper-main/tasks/interact_altar.lua

- Line 34: `local function check_if_stuck()`
- Line 56: `local function any_chest_visible()`
- Line 60: `local ok, inter = pcall(function() return a:is_interactable() end)`
- Line 74: `function task.reset()`
- Line 83: `function task.shouldExecute()`
- Line 107: `local ok, inter = pcall(function() return actor:is_interactable() end)`
- Line 131: `function task.Execute()`

### Reaper-main/tasks/kill_monsters.lua

- Line 17: `local function in_target_boss_zone()`
- Line 26: `local function get_anchor_position()`
- Line 43: `function task.reset()`
- Line 48: `function task.shouldExecute()`
- Line 54: `function task.Execute()`

### Reaper-main/tasks/navigate_to_boss.lua

- Line 36: `local function cache_variants(boss_id)`
- Line 55: `local function load_variants(boss_id)`
- Line 59: `local function pick_best_path(variants)`
- Line 77: `local function in_target_zone(boss)`
- Line 82: `local function chest_visible()`
- Line 86: `local ok, inter = pcall(function() return a:is_interactable() end)`
- Line 153: `local function now() return get_time_since_inject() end`
- Line 154: `local function set_state(s) nav.state = s; nav.phase_start = now() end`
- Line 156: `local function reset_nav()`
- Line 179: `local function find_nearest_path_index(pts, player_pos)`
- Line 194: `local function get_altar_approach_target(boss)`
- Line 212: `function task.reset()`
- Line 216: `function task.shouldExecute()`
- Line 280: `function task.Execute()`
- Line 518: `local ok_name, name = pcall(function() return actor:get_skin_name() end)`
- Line 520: `local ok_pos, apos = pcall(function() return actor:get_position() end)`

### Reaper-main/tasks/open_chest.lua

- Line 31: `local function set_phase(p)`
- Line 37: `local function phase_elapsed()`
- Line 41: `local function cooldown_ok()`
- Line 46: `local function find_egb_chest()`
- Line 53: `local valid, name, pos = pcall(function()`
- Line 65: `local position_ok, d = pcall(function() return pp and pp:dist_to(pos) or 0 end)`
- Line 74: `local function in_target_boss_zone()`
- Line 85: `local function check_stuck()`
- Line 99: `local function try_movement_spell(target)`
- Line 112: `function task.reset()`
- Line 122: `function task.shouldExecute()`
- Line 138: `function task.Execute()`

### Reaper-main/tasks/revive.lua

- Line 28: `local function now() return get_time_since_inject() end`
- Line 29: `local function set_state(st) s.state = st; s.t = now() end`
- Line 30: `local function elapsed() return now() - s.t end`
- Line 32: `local function player_is_dead()`
- Line 39: `function task.reset()`
- Line 44: `function task.shouldExecute()`
- Line 49: `function task.Execute()`

### Reaper-main/tasks/sigil_complete.lua

- Line 37: `local function now()         return get_time_since_inject() end`
- Line 38: `local function set_state(st) s.state = st; s.t = now() end`
- Line 40: `local function in_sigil_zone()`
- Line 52: `function task.reset()`
- Line 59: `function task.shouldExecute()`
- Line 77: `function task.Execute()`
