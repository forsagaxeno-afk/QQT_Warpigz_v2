local plugin_label = 'alfred_the_butler'

local utils        = require 'core.utils'
local tracker      = require 'core.tracker'
local explorerlite = require 'core.explorerlite'

local function dbg(msg)
    if utils.settings.debug then console.print('[alfred:stash_pull] ' .. tostring(msg)) end
end

-- -----------------------------------------------------------------------
-- State
-- -----------------------------------------------------------------------
local phase  = 'PULL'    -- PULL | SALVAGE | SELL | DONE
local sub    = 'IDLE'    -- IDLE | MOVING | INTERACTING | EXECUTE
local last_int   = 0
local int_tout   = 2.5
local retry      = 0
local max_retry  = 3
local last_pos   = nil
local debounce   = nil
local deb_tout   = 0.8

-- Built from pending_pulls once per run; {[sno_id] = true}
local to_salvage_snos  = {}
local to_sell_snos     = {}
local pull_initialized = false
local stash_seen_count = -1   -- for stash-screen fallback detection

local function any_in(t)  return next(t) ~= nil  end

local function reset_state()
    phase = 'PULL'
    sub   = 'IDLE'
    last_int   = 0
    retry      = 0
    last_pos   = nil
    debounce   = nil
    to_salvage_snos  = {}
    to_sell_snos     = {}
    pull_initialized = false
    stash_seen_count = -1
end

local function build_sno_tables()
    to_salvage_snos = {}
    to_sell_snos    = {}
    for _, entry in ipairs(tracker.pending_pulls) do
        if entry.action == 'salvage' then
            to_salvage_snos[entry.sno_id] = true
        elseif entry.action == 'sell' then
            to_sell_snos[entry.sno_id] = true
        end
    end
    local ns, nv = 0, 0
    for _ in pairs(to_salvage_snos) do ns = ns + 1 end
    for _ in pairs(to_sell_snos)    do nv = nv + 1 end
    dbg(string.format('build_sno_tables: salvage_snos=%d sell_snos=%d', ns, nv))
end

-- -----------------------------------------------------------------------
-- NPC helpers
-- -----------------------------------------------------------------------
local function npc_key_for_phase()
    if phase == 'SALVAGE' then return 'BLACKSMITH' end
    if phase == 'SELL'    then return 'GAMBLER' end
    return 'STASH'
end

local function get_npc(key)
    return utils.get_npc(utils.npc_enum[key])
end

local function move_to(key)
    local loc = utils.compute_move_target(utils.get_npc_location(key))
    if BatmobilePlugin then
        BatmobilePlugin.set_target(plugin_label, loc)
        BatmobilePlugin.move(plugin_label)
    else
        explorerlite:set_custom_target(loc)
        explorerlite:move_to_target()
    end
end

local function clear_bat()
    if BatmobilePlugin then BatmobilePlugin.clear_target(plugin_label) end
end

-- -----------------------------------------------------------------------
-- Vendor-screen detection
-- -----------------------------------------------------------------------
local function sdk_vendor_open()
    if loot_manager and loot_manager.is_in_vendor_screen then
        local ok, val = pcall(function() return loot_manager:is_in_vendor_screen() end)
        return ok and val == true
    end
    return false
end

local function is_stash_open(player)
    if sdk_vendor_open() then return true end
    local cnt = player and #player:get_stash_items() or 0
    local open = cnt > 0 and stash_seen_count == cnt
    stash_seen_count = cnt
    return open
end

-- -----------------------------------------------------------------------
-- Task
-- -----------------------------------------------------------------------
local task = {}
task.name   = 'stash_pull'
task.status = 'Idle'

task.shouldExecute = function()
    if not tracker.trigger_tasks   then return false end
    if not utils.is_in_town()      then return false end
    if tracker.stash_pull_done     then return false end
    if tracker.stash_pull_failed   then return false end
    if not (tracker.stash_done or tracker.stash_failed) then return false end
    if #tracker.pending_pulls == 0 then return false end
    return true
end

task.Execute = function()
    local now    = get_time_since_inject()
    local player = get_local_player()
    if not player then return end

    -- ----------------------------------------------------------------
    -- DONE
    -- ----------------------------------------------------------------
    if phase == 'DONE' then
        dbg('complete — stash_pull_done=true, clearing pending_pulls')
        clear_bat()
        tracker.stash_pull_done = true
        tracker.pending_pulls   = {}
        reset_state()
        return
    end

    local key = npc_key_for_phase()
    local npc = get_npc(key)
    local pos = get_player_position()

    -- ----------------------------------------------------------------
    -- IDLE → MOVING
    -- ----------------------------------------------------------------
    if sub == 'IDLE' then
        task.status = phase .. ': moving to ' .. key
        sub      = 'MOVING'
        last_int = now
        last_pos = pos
        move_to(key)
        return
    end

    -- ----------------------------------------------------------------
    -- MOVING
    -- ----------------------------------------------------------------
    if sub == 'MOVING' then
        if npc and utils.distance_to(npc) < 2 then
            sub      = 'INTERACTING'
            task.status = phase .. ': interacting'
            last_int = now
            interact_vendor(npc)
            return
        end
        if last_pos and utils.is_same_position(last_pos, pos) and now - last_int > int_tout then
            retry = retry + 1
            dbg(string.format('MOVING stuck retry=%d/%d', retry, max_retry))
            if retry >= max_retry then
                dbg('MOVING max retries — failing')
                clear_bat()
                tracker.stash_pull_failed = true
                reset_state()
                return
            end
            last_int = now
        end
        last_pos = pos
        move_to(key)
        return
    end

    -- ----------------------------------------------------------------
    -- INTERACTING
    -- ----------------------------------------------------------------
    if sub == 'INTERACTING' then
        local open = (phase == 'PULL') and is_stash_open(player) or sdk_vendor_open()
        if open then
            sub      = 'EXECUTE'
            task.status = phase .. ': executing'
            last_int = now
            debounce = nil
            return
        end
        if now - last_int > int_tout then
            retry = retry + 1
            dbg(string.format('INTERACTING timeout retry=%d/%d', retry, max_retry))
            if retry >= max_retry then
                dbg('INTERACTING max retries — failing')
                clear_bat()
                tracker.stash_pull_failed = true
                reset_state()
                return
            end
            if npc then interact_vendor(npc) end
            last_int = now
        end
        return
    end

    if sub ~= 'EXECUTE' then return end

    -- ----------------------------------------------------------------
    -- EXECUTE (debounced)
    -- ----------------------------------------------------------------
    if debounce and now - debounce < deb_tout then return end
    debounce = now

    -- ---- PULL phase ----
    if phase == 'PULL' then
        if not pull_initialized then
            build_sno_tables()
            pull_initialized = true
        end

        local stash_items  = player:get_stash_items()
        local any_remaining = false

        for _, item in ipairs(stash_items) do
            local sno = item:get_sno_id()
            if to_salvage_snos[sno] or to_sell_snos[sno] then
                any_remaining = true
                local ok = loot_manager.move_item_from_stash(item)
                dbg(string.format('move_item_from_stash sno=%d -> %s', sno, tostring(ok)))
            end
        end

        if not any_remaining then
            dbg('PULL complete — nothing left in stash from queue')
            if any_in(to_salvage_snos) then
                phase = 'SALVAGE'
            elseif any_in(to_sell_snos) then
                phase = 'SELL'
            else
                phase = 'DONE'
            end
            sub   = 'IDLE'
            retry = 0
        end
        return
    end

    -- ---- SALVAGE phase ----
    if phase == 'SALVAGE' then
        local items     = player:get_inventory_items()
        local any_found = false

        for _, item in ipairs(items) do
            if to_salvage_snos[item:get_sno_id()] then
                local ok = loot_manager.salvage_specific_item(item)
                dbg(string.format('salvage sno=%d -> %s', item:get_sno_id(), tostring(ok)))
                any_found = true
            end
        end

        if not any_found then
            dbg('SALVAGE complete')
            phase = any_in(to_sell_snos) and 'SELL' or 'DONE'
            sub   = 'IDLE'
            retry = 0
        end
        return
    end

    -- ---- SELL phase ----
    if phase == 'SELL' then
        local items     = player:get_inventory_items()
        local any_found = false

        for _, item in ipairs(items) do
            if to_sell_snos[item:get_sno_id()] then
                local ok = loot_manager.sell_specific_item(item)
                dbg(string.format('sell sno=%d -> %s', item:get_sno_id(), tostring(ok)))
                any_found = true
            end
        end

        if not any_found then
            dbg('SELL complete')
            phase = 'DONE'
            sub   = 'IDLE'
        end
        return
    end
end

return task
