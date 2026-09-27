-- QQT_Warpigz_v3: WarRoom, the suite dashboard collector. It reads the other
-- plugins (event bus + published status tables) and the game, and writes
-- dashboard/suite_data.js for the web dashboard. It never moves the player
-- and never changes another plugin.
local gui = require 'gui'
local store = require 'core.wr_store'
local collector = require 'core.wr_collector'

-- The plugin folder is read from this plugin's own package.path, once, here.
local root = store.resolve_root()
local function dashboard_dir()
    if not root then return nil end
    local sep = root:find('\\', 1, true) and '\\' or '/'
    return root .. 'dashboard' .. sep
end

-- HelltideRevamped writes its hr_data.js into dashboard_dir when present.
-- enabled is the Enable toggle from the start (not true until the first
-- pulse): HelltideRevamped builds hr_data.js for WarRoom only while it is true.
QQT_WarRoom = {dashboard_dir = dashboard_dir(), version = (gui.version:gsub('^v', '')),
    enabled = gui.elements.main_toggle:get() == true}

collector.init()

local off = false
local function main_pulse()
    if off then return end
    local e = gui.elements
    local enabled = e.main_toggle:get() == true
    QQT_WarRoom.enabled = enabled
    local reset = gui.request_reset
    gui.request_reset = nil
    local ok, err = pcall(collector.tick, get_time_since_inject(),
        {enabled = enabled, write_every = e.write_every:get(), reset = reset})
    if not ok then
        off = true
        console.print('[WarRoom] collector is off for this session: ' .. tostring(err))
    end
end

on_update(main_pulse)
on_render_menu(gui.render)

console.print('Lua Plugin - WarRoom - ' .. gui.version)
