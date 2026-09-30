local Settings   = require("core.settings")
local LootEngine = require("core.loot_engine")
local Renderer   = require("core.renderer")
local GUI        = require("gui")
local Utils      = require("utils.utils")
local Pathfinder = require("core.pathfinder")
local ItemFilter = require("core.item_filter")
local Updater    = require("core.updater")

local RARITY_NAMES = {
    [0]="Normal",[1]="Normal",[2]="Magic",[3]="Magic",
    [4]="Rare",[5]="Legendary",[6]="Unique",[7]="Set",[8]="Uber",
}

local function handle_loot(item)
    if not item then return end
    if Utils.distance_to(item) > 2 then
        Pathfinder:set_custom_target(item:get_position())
        Pathfinder:move_to_target()
    else
        -- Report loot to D4Remote for statistics tracking
        if D4Remote and D4Remote.record_loot then
            pcall(function()
                local info   = item:get_item_info()
                local cat    = ItemFilter.classify(item) or "misc"
                local rarity = RARITY_NAMES[info:get_rarity()] or "Normal"
                D4Remote.record_loot(cat, rarity)
            end)
        end
        interact_object(item)
    end
end

local _initialized = false

local function main_pulse()
    if not get_local_player() then return end

    if not _initialized then
        _initialized = true
        Updater.init()
    end

    Updater.tick()
    Settings.update()

    if not Settings.get().enabled then return end
    if not Settings.should_execute() then return end

    orbwalker.set_auto_loot_toggle(false)

    local priority = GUI.elements.general.loot_priority_combo:get()

    if priority == 0 then
        local item = LootEngine.get_nearby_item()
        Settings.get().looting = item ~= nil
        handle_loot(item)
    else
        local best = LootEngine.get_best_item()
        Settings.get().looting = best ~= nil
        handle_loot(best and best.Item)
    end
end

-- Global API for other plugins
LooteerPlugin = {
    getSettings = function(setting)
        local val = Settings.get()[setting]
        return val ~= nil and val or nil
    end,
    setSettings = function(setting, value)
        if Settings.get()[setting] ~= nil then
            Settings.get()[setting] = value
            return true
        end
        return false
    end,
    is_idle = function()
        return not Settings.get().looting
    end,
    has_wanted_nearby = function()
        return LootEngine.get_nearby_item() ~= nil
    end,
    -- Live "would Looter pick something up right now?" check for external
    -- orchestrators (e.g. Reaper waits on this before advancing past a chest).
    --
    -- Does a fresh scan rather than reading the cached `looting` flag, so the
    -- answer is correct even when main_pulse is gated (toggle off, behavior
    -- restricted to clear-mode, etc.). Respects the same enable + behavior
    -- gates main_pulse uses, so a "true" result really means Looter is about
    -- to grab something on its next tick.
    is_actively_looting = function()
        if not GUI.elements.main_toggle:get() then return false end
        if not Settings.should_execute()      then return false end
        local priority = GUI.elements.general.loot_priority_combo:get()
        local item
        if priority == 0 then
            item = LootEngine.get_nearby_item()
        else
            local best = LootEngine.get_best_item()
            item = best and best.Item
        end
        return item ~= nil
    end,
    enable = function()
        GUI.elements.main_toggle:set(true)
    end,
    disable = function()
        GUI.elements.main_toggle:set(false)
    end,
    get_enabled = function()
        return GUI.elements.main_toggle:get()
    end,
}

on_update(main_pulse)
on_render_menu(GUI.render)
on_render(Renderer.draw_stuff)
