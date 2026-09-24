# Farming second-pass review

Scope: every Lua source file in `HordeDev-1.3.9` and `HelltideRevamped-0.4`, including inactive legacy modules, callbacks, configuration, class filters, and all route data. Review conducted against the shared feedback worktree; package branding/version changes are owned by the release coordinator. No game client or live QQT account was available.

The runtime review covered function bodies, captured/late imports, task registration and priority, reset/cancel callbacks, actor targeting, movement ownership, completion evidence, retries, death/loading, external Alfred and Looteer handoffs. The inventory below enumerates each file and its named functions; anonymous callbacks were also inspected. Coordinate arrays were checked in full by loading every row into a minimal vector environment, rather than claiming live navigability from source coordinates.

## Corrected findings

### Infernal Hordes

- Chest completion previously depended on a fixed loot delay and could hand off while Looteer was still working. A read-only Looteer guard now requires three continuous idle seconds after the configured chest delay. New chest evidence resets that timer; late pickups retain the chest lane and block the first exit request. Once a native exit channel/reset has actually been committed, the exit retains its transaction instead of a late Looteer flag preempting it.
- The compatibility guard recognizes the supplied legacy getter's successful `nil` for false, verified modern `get_enabled`, `is_actively_looting`, and `is_idle` functions, and failed/malformed reads. Unknown modern ownership cannot become idle through a legacy nil fallback. The guard never changes Looteer settings or calls Looteer movement methods.
- The autonomous explorer invoked an unused 21×21×21 diagnostic volume scan (9,261 walkability/height checks) every aggressive update. Its drawing bodies were commented out and its result fed no movement selection. Removed its callback invocation; functional path scoring, navigation targets, movement spells, and A* selection were preserved.
- Movement release now preserves the shared native path when Looteer or Alfred already has busy/unknown ownership. It discards Horde's old ownership flag while releasing only its internal explorer and scoped Batmobile label. A callback-order test proves a companion replacement path survives paid-chest cleanup.
- Main now owns revival, at most once per second while dead; the explorer no longer issues a second independent revive. Main and explorer reject missing/loading world snapshots and missing positions. HUD rendering also handles a missing player position.
- Outer Alfred reads in `open_chests`, `start_dungeon`, and `utils.is_inventory_full` now protect missing/throwing/malformed status exports. Unknown state defers chest interaction, salvage signals and missing-compass Pit handoff; a later valid request proceeds normally. The separately reviewed `tasks/alfred.lua` request/callback changes belong to the town reviewer.

### Helltide

- Traversal recovery wrote a global `trav_blacklist` because its local declaration appeared after the function. The declaration now precedes both recovery and selection. A regression first blacklists an actual selected traversal through its timeout, confirms it is skipped, invokes the existing recovery closure, and confirms it becomes selectable without creating a global.
- Maiden retry was 1.5 seconds although the declared heart insertion charge was three seconds. Retry now permits the full three-second channel and another 1.5 seconds for confirmation. Heart-count decrease remains the confirmation signal.
- Experimental grid selection no longer selects a score -1 unreachable/cooling node when every candidate is excluded. Vertically separated nodes with the same XY no longer divide by zero and produce NaN movement coordinates.
- Farming and search tasks share one revival timer, preventing per-frame and task-switch duplicate requests. A successful live snapshot rearms the timer for a later death.
- Every native-pathfinder fallback records its movement ownership. Yield/suspend clears that recorded path once only if neither Looteer nor Alfred has current busy/unknown ownership. Otherwise it preserves the shared path and discards its old ownership flag. Callback-order regressions verify replacement paths survive the first cleanup as well as repeated cleanup. Batmobile movement ownership remains separate.
- Farming now reads actual modern Looteer ownership as well as legacy getters, protects failures, and yields on unknown reads. Disabled Looteer does not hold farming through stale busy state.
- Main skips missing/loading world snapshots, suspending the previous owner, and HUD drawing handles missing positions.
- The outer Alfred availability/inventory readers protect failed exports; farming holds unknown companion ownership instead of assuming permission to salvage or continuing movement. The dedicated Alfred task was independently updated by the town reviewer.
- Search's `FOUND_HELLTIDE` state previously only logged. If its buff was later lost, the task could be selected forever without starting a new search. It now re-enters the search state and resumes the established routing logic.

## Task flow and combined ownership

Horde registered order is Alfred → built-in town salvage → Library/walk-in → chests → exit → sigil start → entry → wave/boss. Pending reset/sigil/entry transactions receive the scheduler's exclusive lane before ordinary tasks. Normal reward flow is boss/aether → configured chest sequence → fixed delay plus Looteer quiet → native exit commitment → observed outside/arrival → orchestrator handoff. A missing optional chest can advance the configured sequence; unknown aether or failed required chest evidence cannot fabricate payment/completion.

The Chaos portal patch was reviewed independently of its author: known live attackable variants outrank ordinary trash and aether; a living Council boss retains priority; dead/friendly/immune/untargetable/hazard candidates are rejected; at the portal, the wave task retains the objective rather than retreating to center. Callback-level tests cover both movement modes. No additional portal targeting change was necessary in this pass.

Helltide registered order is Alfred → farming → search. Task changes suspend the previous movement owner. Farming's event selection, remembered chests and cinder-payment confirmation retain their existing priorities and bounded retries. Search keeps its five-destination cycle, native teleport debounce, confirmed-zone return and cycle cooldown. A false/throwing or missing Alfred response does not authorize replacing another caller's callback. Both plugins' new companion imports are captured during bootstrap; this pass introduced no public callback-time module lookup.

## Verification

`python3 audit/tests/run_tests.py test_secondpass_farming.lua test_helltide.lua test_horde_feedback.lua test_horde_audit.lua test_horde_reset_exit.lua test_horde_sigil_entry.lua test_secondpass_town.lua`

The focused suite passed with 18 new farming cases, 16 existing Helltide cases, nine Horde feedback cases, 22 Horde audit cases, 120 reset/exit assertions, 230 sigil/entry assertions, and 322 cross-plugin town checks. The runner compiles all runtime Lua before executing tests. The data test validates 8,703 coordinate rows in all ten Helltide routes plus Horde Library, and 151 affix rows across all seven Horde class filters plus the Helltide filter. These are schema/finite-number checks, not proof of current map geometry or current item SNO meaning.

Independent critic checked the Horde quiet/commit behavior and raised explorer world-name and HUD-position guards; both were corrected. Its Helltide review then identified a successor-path cancellation race: a recorded old native path does not prove ownership after a companion update. Both farming plugins now preserve companion replacement paths, and the regressions assert actual current-target identity, not merely cleanup counters. The final independent review accepted these farming branches and requested support for Alfred's optional `pending` status; both movement adapters now preserve that ownership too, with a parameterized regression.

## Inactive code and live limits

- Helltide `core/explorer.lua` returns an empty module at the top; its legacy Pit/grid bodies are unreachable. `core/explorerlite.lua` is not imported by the registered runtime and its autonomous update is commented out. They were inspected but not enabled or broadly refactored.
- Horde `tasks/explore.lua`, `tasks/kill_monsters.lua`, `tasks/town_repair.lua`, and `tasks/town_sell.lua` are not in the registered task list. `core/navigation.pathfind_to` refers to an undeclared explorer, and unused `utils.navigate_to` refers to an undeclared navigation/path API. These dormant helpers must not be activated without repair. The old bulk town-sell task is not a new active selling path.
- Legacy class filter files export global `get_color`/`filter_items` helpers. The active Horde affix module consumes the returned filter tables, not those helpers. The helpers have identical behavior, but remain unnecessary globals. `max_roll` metadata is not an implemented value-based quality rule. Empty/unknown filters and Unique-or-higher rarity are retained by the tested built-in salvage path; no claim of a complete replacement loot sorter is made.
- Horde's old explorer Pit timeout helpers are dormant under the current tracker (`pit_start_time` remains zero). No active reset behavior was added there.
- Existing Helltide hour/event cutoff policy, route geometry, chest prices/skin mappings, affix SNO meaning, Maiden charge length, per-frame native actor lifetime, and host-specific loading timing still require an in-game run. Legacy ore/herb event handles are not all reacquired like the hardened reward chests. Protected Lua calls cannot guarantee safety against a native host crash on an invalid actor handle.
- Live acceptance should include a Chaos portal wave in both movement modes; a final Horde chest with a long Looteer pickup and a late pickup; reset and teleport exits; Helltide death while switching farming/search; a Maiden channel; vertical traversal recovery; Looteer/Alfred contention; disable while using native-path fallback; and loading immediately before HUD/update callbacks.

## Complete file/function inventory

The following list includes inactive files and data-only files. Function names are source declaration labels; anonymous registered callbacks are included in the review scope above.

### HordeDev-1.3.9

34 Lua files; 5,722 source lines at review snapshot.

| File | Named functions / data |
|---|---|
| `Meteor.lua` | `M.initialize` |
| `core/affix_filter.lua` | `refresh_filter`, `affix_filter:get_filter`, `affix_filter:is_uber_item` |
| `core/explorer.lua` | `MinHeap.new`, `MinHeap:push`, `MinHeap:pop`, `MinHeap:peek`, `MinHeap:empty`, `MinHeap:siftUp`, `MinHeap:siftDown`, `MinHeap:contains`, `check_pit_time`, `check_and_reset_dungeons`, `explorer:clear_path_and_target`, `calculate_distance`, `set_height_of_valid_position`, `get_grid_key`, `update_explored_area_bounds`, `is_point_in_explored_area`, `find_unstuck_target`, `handle_stuck_player`, `check_walkable_area`, `reset_exploration`, `is_near_wall`, `find_random_explored_target`, `vec3.__add`, `is_in_last_targets`, `add_to_last_targets`, `find_nearby_unexplored_point`, `heuristic`, `get_neighbors`, `reconstruct_path`, `a_star`, `check_if_stuck`, `explorer:set_custom_target`, `explorer:movement_spell_to_target`, `get_closest_center_position`, `move_to_target`, `move_to_target_aggresive`, `explorer:move_to_target`, `explorer:move_to_target_safely` |
| `core/loot_guard.lua` | `M.busy`, `read`, `M.ready`, `M.reset`, `M.commit_exit`, `M.companion_may_own_movement` |
| `core/movement.lua` | `M.claim`, `M.stop` |
| `core/navigation.lua` | `navigation:move_to`, `navigation:pathfind_to` |
| `core/settings.lua` | `settings.set_setting`, `settings:update_settings` |
| `core/task_manager.lua` | `task_manager.set_finished_time`, `task_manager.get_finished_time`, `task_manager.register_task`, `activate`, `task_manager.execute_tasks`, `task_manager.stop`, `task_manager.get_current_task` |
| `core/tracker.lua` | `tracker.check_time`, `tracker.set_teleported_from_town`, `tracker.clear_runtime_timers`, `tracker.clear_key`, `tracker.fresh_run_reset` |
| `core/utils.lua` | `utils.get_greater_affix_count`, `utils.distance_to`, `utils.player_in_zone`, `utils.get_closest_enemy`, `utils.get_horde_portal`, `utils.get_horde_gate`, `utils.get_bartuc_pylon`, `utils.get_boss_pylon`, `utils.get_town_portal`, `utils.get_obelisk`, `utils.loot_on_floor`, `utils.get_blacksmith`, `utils.get_jeweler`, `table.contains`, `utils.player_has_aura`, `utils.player_on_quest`, `utils.navigate_to`, `move_to_next_position`, `utils.get_material_chest`, `utils.get_chest`, `scan`, `utils.get_stash`, `utils.get_consumable_info`, `safe_get`, `utils.get_aether_actor`, `utils.is_inventory_full`, `utils.get_character_class`, `utils.get_keybind_state` |
| `data/enums.lua` | Data table / no named functions |
| `data/filters/barbarian.lua` | `get_color`, `filter_items` |
| `data/filters/default.lua` | `get_color`, `filter_items` |
| `data/filters/druid.lua` | `get_color`, `filter_items` |
| `data/filters/necromancer.lua` | `get_color`, `filter_items` |
| `data/filters/rogue.lua` | `get_color`, `filter_items` |
| `data/filters/sorcerer.lua` | `get_color`, `filter_items` |
| `data/filters/spiritborn.lua` | `get_color`, `filter_items` |
| `data/library.lua` | Data table / no named functions |
| `data/pylons.lua` | Data table / no named functions |
| `gui.lua` | `create_checkbox`, `gui.render` |
| `main.lua` | `update_locals`, `main_pulse`, `render_pulse`, `enable`, `disable`, `status`, `getState`, `getSettings`, `setSettings` |
| `tasks/alfred.lua` | `get_alfred`, `get_alfred_status`, `live_work`, `clear_request`, `retire_request`, `waiting_for_request`, `complete`, `trigger_alfred`, `task.shouldExecute`, `task.Execute`, `task.reset` |
| `tasks/enter_horde.lua` | `task:reset`, `task:fail`, `task.shouldExecute`, `task:Execute` |
| `tasks/exit_horde.lua` | `snapshot`, `stop_exit_movement`, `reset`, `has_completed_teleport`, `fail_reset`, `run_reset`, `shouldExecute`, `Execute` |
| `tasks/explore.lua` | `shouldExecute`, `Execute` |
| `tasks/horde.lua` | `is_live_chaos_portal`, `bm_pulse`, `bomber:bomb_to`, `get_current_time`, `get_player_pos`, `is_objective`, `bomber:all_waves_cleared`, `bomber:shoot_in_circle`, `bomber:get_target`, `bomber:get_pylons`, `bomber:get_locked_door`, `position_to_string`, `bomber:move_in_pattern`, `position_to_string`, `bomber:main_pulse`, `world_is_bsk`, `shouldExecute`, `cancel_pending`, `Execute` |
| `tasks/kill_monsters.lua` | `shouldExecute`, `Execute` |
| `tasks/open_chests.lua` | `bm_pulse`, `move_to`, `chest_enabled`, `next_enabled_index`, `aether_count`, `clear_chest_timers`, `shouldExecute`, `Execute`, `return_from_salvage`, `waiting_for_salvage`, `init_chest_opening`, `move_to_aether`, `collect_aether`, `move_to_center`, `select_chest`, `move_to_chest`, `open_chest`, `wait_for_vfx`, `fail_chests`, `try_next_chest`, `wait_for_loot`, `finish_chest_opening`, `reset` |
| `tasks/start_dungeon.lua` | `task.read_world`, `task.stop_movement`, `task:release_movement`, `task:reset`, `task:fail`, `task:begin_activation`, `task:activation_update`, `use_dungeon_sigil`, `task.shouldExecute`, `task:Execute` |
| `tasks/town_repair.lua` | `shouldExecute`, `Execute` |
| `tasks/town_salvage.lua` | `preserve_by_rarity`, `salvage_low_greater_affix_items_with_filter`, `salvage_low_greater_affix_items`, `shouldExecute`, `Execute`, `init_salvage`, `teleport_to_town`, `handle_teleporting`, `move_to_blacksmith`, `interact_with_blacksmith`, `salvage_items`, `move_to_portal`, `interact_with_portal`, `finish_salvage`, `reset` |
| `tasks/town_sell.lua` | `shouldExecute`, `Execute` |
| `tasks/walking_to_horde.lua` | `bm_pulse`, `bm_move_to`, `move_to`, `reset_progress_tracker`, `watchdog_tick`, `snap_to_nearest_waypoint`, `near_horde_gate`, `is_loading_or_limbo`, `walking_to_horde_task.shouldExecute`, `walking_to_horde_task.Execute` |

### HelltideRevamped-0.4

29 Lua files; 15,920 source lines at review snapshot.

| File | Named functions / data |
|---|---|
| `core/chest_targets.lua` | `M.read`, `M.collect`, `append`, `M.classify`, `M.key`, `M.select`, `M.at_position` |
| `core/explorer.lua` | `MinHeap.new`, `MinHeap:push`, `MinHeap:pop`, `MinHeap:peek`, `MinHeap:empty`, `MinHeap:siftUp`, `MinHeap:siftDown`, `MinHeap:contains`, `get_grid_size`, `check_pit_time`, `check_and_reset_dungeons`, `explorer:clear_path_and_target`, `calculate_distance`, `explorer:check_start_location_reached`, `explorer:set_start_location_target`, `set_height_of_valid_position`, `get_grid_key`, `mark_area_as_explored`, `is_point_in_explored_area`, `find_nearest_unexplored_point`, `check_walkable_area`, `find_distant_explored_circle`, `find_explored_direction_target`, `explorer.reset_exploration`, `is_near_wall`, `find_central_unexplored_target`, `find_random_explored_target`, `vec3.__add`, `is_in_last_targets`, `add_to_last_targets`, `find_unstuck_target`, `find_target`, `heuristic`, `get_neighbors`, `reconstruct_path`, `a_star`, `move_to_target`, `check_if_stuck`, `explorer:set_custom_target`, `explorer:movement_spell_to_target`, `explorer:move_to_target`, `draw_explored_area_bounds`, `check_and_create_circle`, `calculate_distance`, `check_and_create_circle`, `explorer:update`, `explorer.clear_explored_circles` |
| `core/explorerlite.lua` | `MinHeap.new`, `MinHeap:push`, `MinHeap:pop`, `MinHeap:peek`, `MinHeap:empty`, `MinHeap:siftUp`, `MinHeap:siftDown`, `MinHeap:contains_key`, `explorerlite:clear_path_and_target`, `calculate_distance`, `set_height_of_valid_position`, `get_grid_key`, `is_point_in_explored_area`, `find_unstuck_target`, `handle_stuck_player`, `explorerlite:reset_exploration`, `vec3.__add`, `heuristic`, `get_neighbors`, `reconstruct_path`, `a_star`, `check_if_stuck`, `explorerlite:set_custom_target`, `explorerlite:movement_spell_to_target`, `move_to_target`, `move_to_target_aggresive`, `explorerlite:move_to_target` |
| `core/helltide_explorer.lua` | `build_grid`, `score_node`, `select_next_node`, `helltide_explorer.init`, `helltide_explorer.get_target`, `helltide_explorer.get_stats`, `helltide_explorer.report_intermediate_fail`, `helltide_explorer.get_active_node_pos`, `helltide_explorer.mark_active_unreachable`, `helltide_explorer.mark_chest_opened`, `helltide_explorer.reset` |
| `core/loot_guard.lua` | `M.busy`, `read`, `M.companion_may_own_movement` |
| `core/perf.lua` | `perf.start`, `perf.stop`, `perf.inc`, `perf.set_meta`, `perf.report` |
| `core/recovery.lua` | `M.revive_if_dead` |
| `core/settings.lua` | `settings.set_setting`, `settings:update_settings`, `cinder_gate_active`, `force_active`, `settings.orb_set_clear`, `settings.apply_cinder_orb_gate`, `settings.force_orb_clear_for`, `settings.orb_set_block` |
| `core/task_manager.lua` | `task_manager.set_finished_time`, `task_manager.get_finished_time`, `task_manager.register_task`, `task_manager.execute_tasks`, `task_manager.stop`, `task_manager.get_current_task` |
| `core/tracker.lua` | `tracker.check_time`, `tracker.set_teleported_from_town`, `tracker.clear_key` |
| `core/utils.lua` | `utils.distance_to`, `utils.check_z_distance`, `utils.player_in_zone`, `utils.player_in_region`, `utils.loot_on_floor`, `utils.get_consumable_info`, `safe_get`, `utils.alfred_available`, `utils.is_inventory_full`, `utils.is_in_helltide`, `utils.is_teleporting`, `utils.have_whispering_key`, `utils.check_cinders`, `utils.player_in_town`, `utils.helltide_active`, `utils.do_events` |
| `data/enums.lua` | Data table / no named functions |
| `data/filter.lua` | `get_color`, `filter_items` |
| `data/zone_overrides.lua` | `M.get_current`, `M.is_excluded_zone` |
| `gui.lua` | `create_checkbox`, `gui.render` |
| `main.lua` | `update_locals`, `main_pulse`, `render_pulse`, `enable`, `disable`, `status`, `getSettings`, `setSettings`, `getState` |
| `tasks/alfred.lua` | `get_alfred`, `get_alfred_status`, `live_work`, `clear_request`, `retire_request`, `waiting_for_request`, `reset`, `trigger_alfred`, `task.shouldExecute`, `task.Execute`, `task.reset` |
| `tasks/helltide.lua` | `recall_state_reset`, `chest_stuck_reset`, `build_farm_roam`, `native_move`, `bm_pulse`, `move_to`, `patrol_move`, `navigate_to`, `reset_navigate_state`, `try_traversal_recovery`, `clear_movement`, `mark_chest_opened`, `maiden_reset_cycle`, `get_cached_actors`, `find_maiden_altar`, `get_maiden_pos`, `should_do_maiden`, `invalidate_fct_cache`, `find_closest_target`, `find_closest_waypoint_index`, `load_waypoints`, `check_and_load_waypoints`, `randomize_waypoint`, `chest_key`, `remember_chest`, `scan_and_remember_chests`, `allow_chest_interaction`, `find_affordable_remembered_chest`, `km_is_unreachable`, `km_mark_unreachable`, `get_kill_target`, `log_chest_diagnostics`, `check_events`, `shouldExecute`, `Execute`, `initiate_waypoints`, `return_to_helltide`, `move_to_traversal`, `explore_helltide`, `advance_ni`, `fallback_to_free_explore`, `move_to_pyre`, `interact_pyre`, `stay_near_pyre`, `move_to_maiden`, `at_maiden`, `move_to_silent_chest`, `move_to_helltide_chest`, `move_to_remembered_chest`, `farm_chest_cinders`, `move_to_ore`, `move_to_herb`, `move_to_shrine`, `chase_goblin`, `kill_monsters`, `move_to_chaos_rift`, `interact_chaos_rift`, `stay_near_chaos_rift`, `back_to_town`, `return_from_salvage`, `suspend`, `cancel_pending`, `reset`, `chest_label` |
| `tasks/search_helltide.lua` | `detect_helltide_zone`, `index_of_tp`, `shouldExecute`, `Execute`, `searching_helltide`, `teleporting_to_helltide`, `waiting_for_teleport`, `found_helltide`, `cancel_pending`, `reset` |
| `waypoints/ironwolfs.lua` | Data table / no named functions |
| `waypoints/ironwolfs_to_maiden.lua` | Data table / no named functions |
| `waypoints/jirandai.lua` | Data table / no named functions |
| `waypoints/jirandai_to_maiden.lua` | Data table / no named functions |
| `waypoints/marowen.lua` | Data table / no named functions |
| `waypoints/marowen_to_maiden.lua` | Data table / no named functions |
| `waypoints/menestad.lua` | Data table / no named functions |
| `waypoints/menestad_to_maiden.lua` | Data table / no named functions |
| `waypoints/wejinhani.lua` | Data table / no named functions |
| `waypoints/wejinhani_to_maiden.lua` | Data table / no named functions |
