local plugin_label = 'alfred_the_butler'

local utils = require 'core.utils'
local settings = require 'core.settings'
local tracker = require 'core.tracker'
local explorerlite = require 'core.explorerlite'
local base_task = require 'tasks.base'

local task = base_task.new_task()
local status_enum = {
    IDLE = 'Idle',
    EXECUTE = 'Keeping item in stash',
    MOVING = 'Moving to stash',
    INTERACTING = 'Interacting with stash',
    RESETTING = 'Re-trying stash',
    FAILED = 'Failed to stash'
}

local debounce_time = nil
local debounce_timeout = 1
local stash_item_count = -1
local failed_interaction_count = -1
local last_interaction_item_count = -1

-- ===== debug logging =====
local function dbg(msg)
    if settings.debug then console.print('[alfred:stash] ' .. tostring(msg)) end
end
local last_should_block_reason = nil
local last_is_done_signature = nil
local last_vendor_screen_state = nil
local last_logged_inv_count = -1
-- ==========================


local function should_stash_item(item)
    if not item then return false end
    if settings.skip_favorite and item:is_locked() then return false end
    local is_sell    = utils.is_salvage_or_sell(item, utils.item_enum['SELL'])
    local is_salvage = utils.is_salvage_or_sell(item, utils.item_enum['SALVAGE'])
    local is_cache   = utils.get_item_type(item) == 'cache'
    local skip_cache_now = settings.skip_cache and is_cache
    return not is_sell and not is_salvage and not skip_cache_now
end

local function update_last_interaction_time()
    local local_player = get_local_player()
    local item_count = #local_player:get_inventory_items() +
        #local_player:get_consumable_items() +
        #local_player:get_dungeon_key_items() +
        #local_player:get_socketable_items()

    if item_count == last_interaction_item_count then
        failed_interaction_count = failed_interaction_count + 1
    else
        failed_interaction_count = -1
    end
    if failed_interaction_count < 10 then
        task.last_interaction = get_time_since_inject()
    end
    last_interaction_item_count = item_count
end

local last_npc_log = nil
local extension = {}
function extension.get_npc()
    -- Multiple stash objects exist in town; pick the closest one to the player.
    local skin = utils.npc_enum['STASH']
    local player_pos = get_player_position()
    local best, best_dist = nil, math.huge
    local function check(list)
        for _, actor in pairs(list) do
            if actor:get_skin_name() == skin then
                local d = player_pos and player_pos:dist_to(actor:get_position()) or math.huge
                if d < best_dist then best, best_dist = actor, d end
            end
        end
    end
    check(actors_manager:get_all_actors())
    check(get_actors_list())
    local state
    if best then
        local pos = best:get_position()
        state = string.format('found pos=(%.1f,%.1f,%.1f) dist=%.2f', pos:x(), pos:y(), pos:z(), best_dist)
    else
        state = 'nil'
    end
    if state ~= last_npc_log then
        dbg('get_npc() -> ' .. state)
        last_npc_log = state
    end
    return best
end
function extension.move()
    local npc_location = utils.compute_move_target(utils.get_npc_location('STASH'))
    dbg(string.format('move() -> target=(%.1f,%.1f,%.1f) batmobile=%s',
        npc_location:x(), npc_location:y(), npc_location:z(),
        tostring(BatmobilePlugin ~= nil)))
    if BatmobilePlugin then
        BatmobilePlugin.set_target(plugin_label, npc_location)
        BatmobilePlugin.move(plugin_label)
    else
        explorerlite:set_custom_target(npc_location)
        explorerlite:move_to_target()
    end
end
function extension.interact()
    local npc = extension.get_npc()
    if npc then
        dbg(string.format('interact() npc=%s dist=%.2f', tostring(npc:get_skin_name()), utils.distance_to(npc)))
        interact_vendor(npc)
    else
        dbg('interact() no NPC found in actors_manager')
    end
end
function extension.execute()
    local local_player = get_local_player()
    if not local_player then dbg('execute() no local_player'); return end

    if debounce_time ~= nil and debounce_time + debounce_timeout > get_time_since_inject() then return end
    debounce_time = get_time_since_inject()
    tracker.last_task = task.name

    local moved = 0
    local skipped_sell = 0
    local skipped_salvage = 0
    local skipped_cache = 0
    local items = local_player:get_inventory_items()
    local total_inv = #items
    if total_inv ~= last_logged_inv_count then
        dbg(string.format('execute() entered — inv=%d stash_count=%d flags{boss=%s keys=%s sigils=%s socket=%s} skip_cache=%s',
            total_inv, tracker.stash_count,
            tostring(tracker.stash_boss_materials), tostring(tracker.stash_keys),
            tostring(tracker.stash_sigils), tostring(tracker.stash_socketables),
            tostring(settings.skip_cache)))
        last_logged_inv_count = total_inv
    end

    for _,item in pairs(items) do
        if item then
            local is_sell = utils.is_salvage_or_sell(item,utils.item_enum['SELL'])
            local is_salvage = utils.is_salvage_or_sell(item,utils.item_enum['SALVAGE'])
            local is_cache = utils.get_item_type(item) == 'cache'
            local skip_cache_now = settings.skip_cache and is_cache
            if not is_sell and not is_salvage and not skip_cache_now then
                local name = (item.get_name and item:get_name()) or '?'
                local locked = (item.is_locked and item:is_locked()) or false
                local real_vendor_open = false
                if loot_manager and loot_manager.is_in_vendor_screen then
                    local ok, val = pcall(function() return loot_manager:is_in_vendor_screen() end)
                    real_vendor_open = ok and val or false
                end
                local move_ret = loot_manager.move_item_to_stash(item)
                dbg(string.format('move_item_to_stash: sno=%s name=%s locked=%s real_vendor_open=%s ret=%s',
                    tostring(item:get_sno_id()), tostring(name), tostring(locked),
                    tostring(real_vendor_open), tostring(move_ret)))
                update_last_interaction_time()
                moved = moved + 1
            else
                if is_sell then skipped_sell = skipped_sell + 1
                elseif is_salvage then skipped_salvage = skipped_salvage + 1
                elseif skip_cache_now then skipped_cache = skipped_cache + 1 end
            end
        end
        debounce_time = get_time_since_inject()
    end
    if total_inv > 0 then
        dbg(string.format('inventory pass: moved=%d skip_sell=%d skip_salvage=%d skip_cache=%d', moved, skipped_sell, skipped_salvage, skipped_cache))
    end

    if tracker.stash_boss_materials then
        local consumeable_items = local_player:get_consumable_items()
        local boss_moved = 0
        for _,item in pairs(consumeable_items) do
            loot_manager.move_item_to_stash(item)
            update_last_interaction_time()
            boss_moved = boss_moved + 1
            debounce_time = get_time_since_inject()
        end
        if boss_moved > 0 then dbg(string.format('boss-mats pass: moved=%d', boss_moved)) end
    end
    if tracker.stash_keys then
        local key_items = local_player:get_dungeon_key_items()
        local key_moved = 0
        for _,item in pairs(key_items) do
            if not string.lower(item:get_name() or ''):match('dungeonsigil') then
                loot_manager.move_item_to_stash(item)
                update_last_interaction_time()
                key_moved = key_moved + 1
                debounce_time = get_time_since_inject()
            end
        end
        if key_moved > 0 then dbg(string.format('keys pass: moved=%d', key_moved)) end
        if tracker.stash_sigils then
            local items = local_player:get_dungeon_key_items()
            local sig_moved = 0
            for _, item in pairs(items) do
                local name = item:get_name()
                if item:is_locked() and string.lower(name):match('dungeonsigil') then
                    dbg(string.format('moving sigil: name=%s', tostring(name)))
                    loot_manager.move_item_to_stash(item)
                    update_last_interaction_time()
                    sig_moved = sig_moved + 1
                end
            end
            if sig_moved > 0 then dbg(string.format('sigils pass: moved=%d', sig_moved)) end
        end
    end
    if tracker.stash_socketables then
        local socket_items = local_player:get_socketable_items()
        local sock_moved = 0
        for _,item in pairs(socket_items) do
            loot_manager.move_item_to_stash(item)
            update_last_interaction_time()
            sock_moved = sock_moved + 1
        end
        if sock_moved > 0 then dbg(string.format('socketables pass: moved=%d', sock_moved)) end
        debounce_time = get_time_since_inject()
    end
    if tracker.stash_talisman_seal or tracker.stash_talisman_charm then
        local talisman_items = utils.list_of(local_player, 'get_talisman_items')
        local tal_moved = 0
        for _,item in pairs(talisman_items) do
            if not utils.should_salvage_talisman(item) and not utils.should_sell_talisman(item) then
                loot_manager.move_item_to_stash(item)
                update_last_interaction_time()
                tal_moved = tal_moved + 1
            end
        end
        if tal_moved > 0 then dbg(string.format('talisman pass: moved=%d', tal_moved)) end
        debounce_time = get_time_since_inject()
    end
end
function extension.reset()
    local local_player = get_local_player()
    if not local_player then return end
    local new_position = vec3:new(2570.6807, -474.2803, 30.5166)
    if task.reset_state == status_enum['MOVING'] then
        new_position = vec3:new(2578.1103515625, -482.2646484375, 31.5029296875)
    end
    if BatmobilePlugin then
        BatmobilePlugin.set_target(plugin_label, new_position)
        BatmobilePlugin.move(plugin_label)
    else
        explorerlite:set_custom_target(new_position)
        explorerlite:move_to_target()
    end
end
function extension.is_done()
    if task.check_status(status_enum['EXECUTE']) then
        local stash_items = get_local_player():get_stash_items()
        local stash_count = #stash_items
        tracker.stash_item_count_cached = stash_count
        if stash_count >= settings.max_stash_items then
            dbg('is_done() -> stash full (' .. stash_count .. '/' .. settings.max_stash_items .. '), halting alfred')
            tracker.stash_full = true
            return true
        end
    end
    local socketable_stashed = true
    if tracker.stash_socketables then
        socketable_stashed = #get_local_player():get_socketable_items() == 0
    end
    local sigils_stashed = true
    if tracker.stash_sigils then
        local items = get_local_player():get_dungeon_key_items()
        for _, item in pairs(items) do
            local name = item:get_name()
            if item:is_locked() and string.lower(name):match('dungeonsigil') then
                sigils_stashed = false
            end
        end
    end
    local boss_stashed = true
    if tracker.stash_boss_materials then
        boss_stashed = #get_local_player():get_consumable_items() == 0
    end
    local keys_stashed = true
    if tracker.stash_keys then
        local key_items = get_local_player():get_dungeon_key_items()
        local remaining = 0
        for _, item in pairs(key_items) do
            if not string.lower(item:get_name() or ''):match('dungeonsigil') then
                remaining = remaining + 1
            end
        end
        keys_stashed = remaining == 0
    end
    local talisman_stashed = not (tracker.stash_talisman_seal or tracker.stash_talisman_charm) or (function()
        for _, item in pairs(utils.list_of(get_local_player(), 'get_talisman_items')) do
            if not utils.should_salvage_talisman(item) and not utils.should_sell_talisman(item) then return false end
        end
        return true
    end)()
    local result = (tracker.stash_count == 0) and
        (not tracker.stash_socketables or socketable_stashed) and
        (not tracker.stash_boss_materials or boss_stashed) and
        (not tracker.stash_keys or keys_stashed) and
        (not tracker.stash_sigils or sigils_stashed) and
        talisman_stashed
    local sig = string.format('done=%s sc=%d sock=%s boss=%s keys=%s sig=%s tal=%s flags{sock=%s boss=%s keys=%s sig=%s seal=%s charm=%s}',
        tostring(result), tracker.stash_count,
        tostring(socketable_stashed), tostring(boss_stashed), tostring(keys_stashed),
        tostring(sigils_stashed), tostring(talisman_stashed),
        tostring(tracker.stash_socketables), tostring(tracker.stash_boss_materials),
        tostring(tracker.stash_keys), tostring(tracker.stash_sigils),
        tostring(tracker.stash_talisman_seal), tostring(tracker.stash_talisman_charm))
    if sig ~= last_is_done_signature then
        dbg('is_done() ' .. sig)
        last_is_done_signature = sig
    end
    return result
end
function extension.done()
    dbg('done() called — marking stash_done=true')
    if BatmobilePlugin then
        BatmobilePlugin.clear_target(plugin_label)
    end
    tracker.stash_done = true
    stash_item_count = -1
    failed_interaction_count = -1
    last_interaction_item_count = -1
end
function extension.failed()
    dbg(string.format('failed() called — retry=%d max=%d failed_interactions=%d',
        task.retry or -1, task.max_retries or -1, failed_interaction_count))
    if BatmobilePlugin then
        BatmobilePlugin.clear_target(plugin_label)
    end
    tracker.stash_failed = true
    stash_item_count = -1
    failed_interaction_count = -1
    last_interaction_item_count = -1
end
function extension.is_in_vendor_screen()
    -- Prefer the SDK signal (matches sell/salvage/repair tasks). The legacy
    -- count-based heuristic could never return true on an empty stash, which
    -- is exactly the failure mode the right-click fallback is meant to catch.
    local sdk_open = false
    if loot_manager and loot_manager.is_in_vendor_screen then
        local ok, val = pcall(function() return loot_manager:is_in_vendor_screen() end)
        sdk_open = ok and val == true
    end
    local stash_count = #get_local_player():get_stash_items()
    local count_open  = stash_count > 0 and stash_item_count == stash_count
    local is_open     = sdk_open or count_open
    if is_open ~= last_vendor_screen_state then
        dbg(string.format('is_in_vendor_screen() -> %s (sdk=%s count=%s stash_items=%d prev_seen=%d)',
            tostring(is_open), tostring(sdk_open), tostring(count_open), stash_count, stash_item_count))
        last_vendor_screen_state = is_open
    end
    stash_item_count = stash_count
    return is_open
end

task.name = 'stash'
task.extension = extension
task.status_enum = status_enum

task.shouldExecute = function ()
    if tracker.trigger_tasks == false then
        task.retry = 0
    end
    if utils.is_in_town() and
        tracker.trigger_tasks and
        not tracker.stash_failed and
        not tracker.stash_done and
        (tracker.sell_done or tracker.sell_failed) and
        (tracker.salvage_done or tracker.salvage_failed) and
        (tracker.salvage_talisman_done or tracker.salvage_talisman_failed)
    then
        if last_should_block_reason ~= 'OK' then
            dbg('shouldExecute() -> true (gates passed, running stash task)')
            last_should_block_reason = 'OK'
        end
        if task.check_status(task.status_enum['FAILED']) then
            task.set_status(task.status_enum['IDLE'])
        end
        return true
    end
    -- Determine which gate blocked, log only on change so we don't spam
    local reason
    if not utils.is_in_town() then reason = 'not_in_town'
    elseif not tracker.trigger_tasks then reason = 'trigger_tasks=false'
    elseif tracker.stash_failed then reason = 'stash_failed=true'
    elseif tracker.stash_done then reason = 'stash_done=true'
    elseif not (tracker.sell_done or tracker.sell_failed) then reason = 'sell not done/failed'
    elseif not (tracker.salvage_done or tracker.salvage_failed) then reason = 'salvage not done/failed'
    else reason = 'unknown' end
    if reason ~= last_should_block_reason then
        dbg('shouldExecute() -> false, blocked by: ' .. reason)
        last_should_block_reason = reason
    end
    return false
end

return task