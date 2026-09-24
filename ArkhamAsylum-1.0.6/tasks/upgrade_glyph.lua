local plugin_label = 'arkham_asylum'
local utils = require 'core.utils'
local settings = require 'core.settings'
local tracker = require 'core.tracker'
local gui = require 'gui'
local soul_task = require 'tasks.consume_chorons_soul'

local task = {
    name = 'upgrade_glyph',
    status = 'idle',
    last_interaction_time = -math.huge,
    blacklist = {},
    failed_count = 0,
    pending_attempt = nil,
}
local ATTEMPT_DELAY = 2
local EMPTY_LIST_TIMEOUT = 8
-- ARK-4/C6: yield to an active Looter (boss drops), but not forever.
local LOOTER_HOLD_MAX = 45
local looter_yield_since = nil

-- QQT declares a Lua table; retain support for older vector wrappers.
local function glyph_list()
    local glyphs = get_glyphs()
    if not glyphs then return {} end
    if type(glyphs.size) == 'function' and type(glyphs.get) == 'function' then
        local list = {}
        for i = 1, glyphs:size() do list[#list + 1] = glyphs:get(i) end
        return list
    end
    return glyphs
end

local function should_upgrade(glyph)
    local level = glyph:get_level()
    local chance = math.floor((glyph:get_upgrade_chance() + 0.005) * 100)
    return chance >= settings.upgrade_threshold
        and not task.blacklist[glyph.glyph_name_hash]
        and level >= settings.minimum_glyph_level
        and level <= settings.maximum_glyph_level
        and (not glyph.get_max_level or level < glyph:get_max_level())
        and (level ~= 45 or settings.upgrade_legendary_toggle)
        and (glyph:can_upgrade() or (settings.upgrade_legendary_toggle and level == 45))
end

-- Count completed API attempts, never scheduler predicate evaluations. Keep
-- numeric snapshots: a live glyph handle can change level after upgrading.
local function resolve_attempt(glyphs)
    local pending = task.pending_attempt
    if not pending then return end
    for _, glyph in pairs(glyphs) do
        if glyph.glyph_name_hash == pending.hash then
            if glyph:get_level() <= pending.level then
                task.failed_count = task.failed_count + 1
                if pending.level == 45 or task.failed_count >= 5 then
                    task.blacklist[pending.hash] = true
                    task.failed_count = 0
                end
            else
                task.failed_count = 0
            end
            task.pending_attempt = nil
            return
        end
    end
end

task.reset = function ()
    task.last_interaction_time = -math.huge
    task.blacklist = {}
    task.failed_count = 0
    task.pending_attempt = nil
    task.last_attempt_hash = nil
    task.status = 'idle'
    looter_yield_since = nil
end

-- C5: time spent yielding to Looter/Alfred is not time the glyph UI stayed
-- empty (EMPTY_LIST_TIMEOUT would otherwise mark the glyph done unused).
task.on_yield = function (seconds)
    if tracker.glyph_trigger_time then
        tracker.glyph_trigger_time = tracker.glyph_trigger_time + seconds
    end
end

task.shouldExecute = function ()
    if not utils.player_in_pit() or not settings.upgrade_toggle
        or tracker.glyph_done
    then return false end
    -- Finished/blacklisted souls yield; a still-rendering actor alone must
    -- not prevent glyph upgrades forever after the soul task has given up.
    if soul_task.shouldExecute() then return false end
    if utils.get_glyph_upgrade_gizmo() == nil then return false end
    local now = get_time_since_inject()
    if utils.looter_hold(LOOTER_HOLD_MAX, 'glyph upgrade') then
        looter_yield_since = looter_yield_since or now
        return false
    end
    if looter_yield_since then
        task.on_yield(now - looter_yield_since)
        looter_yield_since = nil
    end
    return true
end

task.Execute = function ()
    local player = get_local_player()
    local gizmo = utils.get_glyph_upgrade_gizmo()
    if not player or not gizmo then return end
    BatmobilePlugin.pause(plugin_label)
    local distance = utils.distance(player, gizmo)
    if settings.disable_orbwalker_at_glyphstone and distance <= 5 then
        settings.orb_set_clear(false)
    end
    if distance > 2 then
        BatmobilePlugin.set_target(plugin_label, gizmo, distance <= 4)
        BatmobilePlugin.move(plugin_label)
        task.status = 'walking to Awakened Glyphstone'
        return
    end
    utils.stop_movement()
    local now = get_time_since_inject()
    if tracker.glyph_trigger_time == nil then
        task.reset()
        tracker.glyph_trigger_time = now
        task.last_interaction_time = now
        interact_object(gizmo)
        task.status = 'interacting with Awakened Glyphstone'
        return
    end
    if now - task.last_interaction_time < ATTEMPT_DELAY then return end
    local glyphs = glyph_list()
    if next(glyphs) == nil then
        if now - tracker.glyph_trigger_time >= EMPTY_LIST_TIMEOUT then
            tracker.glyph_done = true
            task.status = 'no glyphs available'
        else
            task.last_interaction_time = now
            interact_object(gizmo)
        end
        return
    end
    resolve_attempt(glyphs)
    local selected = nil
    for _, glyph in pairs(glyphs) do
        if should_upgrade(glyph) and (selected == nil
            or (settings.upgrade_mode == gui.upgrade_modes_enum.HIGHEST
                and glyph:get_level() > selected:get_level())
            or (settings.upgrade_mode == gui.upgrade_modes_enum.LOWEST
                and glyph:get_level() < selected:get_level()))
        then selected = glyph end
    end
    if not selected then
        tracker.glyph_done = true
        task.status = 'idle'
        return
    end
    if task.last_attempt_hash ~= selected.glyph_name_hash then task.failed_count = 0 end
    task.last_attempt_hash = selected.glyph_name_hash
    task.pending_attempt = { hash = selected.glyph_name_hash, level = selected:get_level() }
    console.print('Upgrading ' .. tostring(selected.glyph_name_hash))
    upgrade_glyph(selected)
    task.last_interaction_time = now
    task.status = 'upgrading glyphs'
end

return task
