-- Per-addon module namespace prevents core.settings collisions in shared Lua states.
local root = nil
if type(debug) == "table" and type(debug.getinfo) == "function" then
    local ok, info = pcall(function() return debug.getinfo(1, "S") end)
    if ok and type(info) == "table" and type(info.source) == "string" and info.source:sub(1, 1) == "@" then
        root = info.source:sub(2):gsub("\\", "/"):match("^(.*)/main%.lua$")
    end
end
-- The live host supplies its own require. Debug/package/io are optional libraries.
if not root and type(package) == "table" and type(package.searchpath) == "function" and type(package.path) == "string" then
    local ok, found = pcall(package.searchpath, "tristram.settings", package.path)
    if ok and type(found) == "string" then root = found:gsub("\\", "/"):match("^(.*)/tristram/settings%.lua$") end
end
local previous = rawget(_G, "TristramLoopPlugin")
if type(previous) == "table" and type(previous.shutdown) == "function" then
    if previous.shutdown() == false then
        console.print("[TristramLoop] Reload stopped: previous instance still owns cleanup.")
        return
    end
end
if type(package) == "table" and type(package.loaded) == "table" then
    for name in pairs(package.loaded) do
        if type(name) == "string" and name:match("^tristram%.") then package.loaded[name] = nil end
    end
end
local old_path = type(package) == "table" and package.path
if root and type(old_path) == "string" then package.path = root .. "/?.lua;" .. old_path end
local settings = require("tristram.settings")
local store = require("tristram.storage").new(root and (root .. "/tristram/local-state.txt"))
local controller = require("tristram.controller").new(store)
local host = require("tristram.host")
if type(old_path) == "string" then package.path = old_path end
local api = { _settings = settings } -- private widget reload anchor
api.enable, api.status = controller.enable, controller.status
api.disable = function() return controller.disable("Stopped by external addon/API control.") end
api.confirm_party_step, api.finish_clear = controller.confirm, controller.finish
api.shutdown = controller.shutdown
function api.getState() return controller.status().state end
-- Status fields are copied onto the API table. Keys that vanished from the
-- latest status (a cleared stop reason, fallback spell, ...) are removed so
-- readers never see stale values; API functions are never touched.
local published = {}
local function publish()
    local status = controller.status()
    for key in pairs(published) do
        if status[key] == nil then api[key] = nil; published[key] = nil end
    end
    for key, value in pairs(status) do api[key] = value; published[key] = true end
end
publish()
_G.TristramLoopPlugin = api
_G.TRISTRAM_LOOP_STATE = api
local function command(name)
    if name == "confirm" then controller.confirm()
    elseif name == "finish" then controller.finish()
    elseif name == "diagnose" then host.diagnose() end
end
-- Registration works before a character exists; every action checks the live sample.
on_update(function()
    if not controller.active then return end
    local ok, why = pcall(controller.tick)
    if not ok then controller.stop("Host error: " .. tostring(why)) end
    publish()
end)
on_render_menu(function()
    if controller.active then settings.render(controller.status(), store, command) end
end)
on_key_press(function(key)
    if not controller.active then return end
    local e = settings.elements
    if key > 0 and key == e.stop_key:get_key() then controller.disable("Stopped by configured stop key (VK=" .. tostring(key) .. ").")
    elseif key > 0 and key == e.continue_key:get_key() then controller.confirm() end
end)
on_render(function()
    if controller.active then settings.render_preview(controller.running) end
    if controller.active and (controller.running or controller.held and settings.elements.enabled:get()) then
        graphics.text_2d("Tristram Loop: " .. controller.status().detail, vec2:new(20, 80), 16, color_white(255))
    end
end)
local viewport_width, viewport_height = require("tristram.party").dimensions()
console.print("[TristramLoop] Loaded v" .. api.version .. " | window="
    .. (viewport_width and tostring(viewport_width) .. "x" .. tostring(viewport_height) or "unavailable")
    .. " | automatic party inputs | stopped")
return api
