-- QQT_Warpigz_v3 3.3.6 (Auditor, urgent): Rosie 1.0.23 publishes its own
-- `_G.Scavenger` stand-in (`_rosie = true`, Rosie/rosie/private/scavenger_mimic.lua)
-- while Worldstone runs. It answers is_busy() for Rosie's own pickup, which
-- every plugin already reads through LooteerPlugin. Our plugins must treat it
-- as absent; a real third-party Scavenger still holds as in 3.3.3.
--   R1 WarPigs Whisper bridge: a Rosie pickup burst cancelled the managed
--      Whisper request ('scavenger_busy' is no pause reason before accept).
--   R2 WarPigs outgoing teleport held for 'Scavenger collecting loot'.
--   R3 WarPug planning held ('Scavenger busy').
--   R4 SilentRaven third_party_reason() = 'scavenger_busy'.
--   R5 ArkhamAsylum / Reaper / HordeDev / WonderCity scavenger_busy() true.
--   R6 Batmobile freeroam yielded to it.
-- Each R case fails on the 3.3.5 tree; each also checks that a real
-- `{is_busy = ...}` Scavenger still holds.
local ROOT = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local checks, failures = 0, {}
local function eq(actual, expected, message)
    if actual ~= expected then
        error((message or 'mismatch') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
    end
    checks = checks + 1
end
local function case(name, fn)
    local passed, err = xpcall(fn, debug.traceback)
    if passed then print('PASS rosie-scavenger-skip: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL rosie-scavenger-skip: ' .. name .. ': ' .. tostring(err)) end
end

-- Rosie's stand-in (same marker fields as scavenger_mimic.lua's shim) and a
-- real third-party Scavenger, both busy.
local function rosie_scavenger()
    return {_rosie = true, mimic = true, name = 'Rosie', is_busy = function() return true end,
        pause = function() end, resume = function() end}
end
local function real_scavenger()
    return {is_busy = function() return true end, pause = function() end, resume = function() end}
end

-- Any-shaped stub for dependencies a module only captures at load.
local function stub()
    return setmetatable({}, {__index = function(t, k) local v = stub(); rawset(t, k, v); return v end,
        __call = function() return nil end})
end
-- A sandbox whose `require` loads the plugin's real file when `real[name]`,
-- else a stub.
local function sandbox(dir, real)
    local c = {now = 100, logs = {}}
    local e = setmetatable({}, {__index = _G}); e._G = e
    e.console = {print = function(m) c.logs[#c.logs + 1] = tostring(m) end}
    e.get_time_since_inject = function() return c.now end
    local modules = {}
    e.require = function(name)
        if modules[name] ~= nil then return modules[name] end
        local value
        if real and real[name] then
            value = assert(loadfile(ROOT .. '/' .. dir .. '/' .. name:gsub('%.', '/') .. '.lua', 't', e))()
        else
            value = stub()
        end
        modules[name] = value
        return value
    end
    c.e = e
    function c.load(path) return assert(loadfile(ROOT .. '/' .. dir .. '/' .. path, 't', e))() end
    return c
end
-- The upvalue `name` reachable from `root` (a function or a module table),
-- searched through nested function upvalues.
local function find_upvalue(root, name)
    local seen = {}
    local function walk(f, depth)
        if type(f) ~= 'function' or seen[f] or depth > 4 then return nil end
        seen[f] = true
        local i = 1
        while true do
            local n, v = debug.getupvalue(f, i)
            if not n then break end
            if n == name then return v end
            if type(v) == 'function' then
                local found = walk(v, depth + 1)
                if found ~= nil then return found end
            end
            i = i + 1
        end
        return nil
    end
    if type(root) == 'function' then return walk(root, 0) end
    for _, v in pairs(root) do
        local found = walk(v, 0)
        if found ~= nil then return found end
    end
    return nil
end

-- ── R1 WarPigs Whisper bridge (actual bridge + actual SilentRaven) ─────────
-- Fixture adapted from test_warpigs_raven_yield.lua.
local function whisper_fixture()
    local c = {now = 100, zone = 'Skov_Temis', world = 'Town', enabled = true,
        moves = 0, clears = 0, escapes = 0, interacts = 0, teleports = 0, panel = false}
    local e = setmetatable({}, {__index = _G}); e._G = e
    local V = {}; V.__index = V
    function V:x() return self[1] end
    function V:y() return self[2] end
    function V:z() return self[3] end
    e.vec3 = {new = function(_, x, y, z) return setmetatable({x, y, z}, V) end}
    c.pos = e.vec3:new(2560, -480, 30)
    c.npc_pos = e.vec3:new(2596, -495, 30)
    c.npc = {get_skin_name = function() return 'temis_bounty_meta_raven_npc' end,
        is_interactable = function() return true end, get_position = function() return c.npc_pos end}
    local player = {is_dead = function() return false end,
        get_active_spell_id = function() return 0 end,
        get_buffs = function() return {} end,
        get_position = function() return c.pos end,
        get_attribute = function() return c.zone == 'Skov_Temis' and 1 or 0 end,
        get_inventory_items = function() return {} end, get_consumable_items = function() return {} end}
    e.get_local_player = function() return player end
    e.get_current_world = function() return {get_current_zone_name = function() return c.zone end,
        get_name = function() return c.world end} end
    e.get_time_since_inject = function() return c.now end
    e.attributes = {PLAYER_IN_TOWN_LEVEL_AREA = 1}
    e.get_quests = function() return {{get_name = function() return 'Bounty_Meta_Quest' end,
        get_objectives = function() return {{text = 'Return to the Tree of Whispers'}} end}} end
    e.actors_manager = {get_ally_actors = function() return {c.npc} end}
    e.console = {print = function() end}
    e.pathfinder = {request_move = function() c.moves = c.moves + 1 end,
        clear_stored_path = function() c.clears = c.clears + 1 end}
    e.utility = {send_key_press = function() c.escapes = c.escapes + 1; c.panel = false end}
    e.interact_object = function() c.interacts = c.interacts + 1; c.panel = true end
    e.teleport_to_waypoint = function() c.teleports = c.teleports + 1 end
    e.quest_reward = {is_open = function() return c.panel end}
    local function widget(value)
        return {get = function() return value end, set = function(_, next_value) value = next_value end,
            get_state = function() return value and 1 or 0 end}
    end
    local gui = {elements = {main_toggle = {get = function() return c.enabled end},
        debug_toggle = widget(false), auto_fire_toggle = widget(false), prefer_legendary_toggle = widget(true),
        legendary_bonus_slider = widget(50), manual_fire_keybind = widget(false), reload_catalog_toggle = widget(false)},
        render = function() end}
    local modules = {gui = {foreign = true}, ['core.tracker'] = {foreign = true},
        ['core.settings'] = {foreign = true}, ['silent_raven.gui'] = gui}
    e.package = {loaded = modules}
    e.require = function(name)
        if modules[name] ~= nil then return modules[name] end
        assert(name:match('^silent_raven%.'), 'unexpected non-namespaced dependency: ' .. name)
        local value = assert(loadfile(ROOT .. '/SilentRaven/' .. name:gsub('%.', '/') .. '.lua', 't', e))()
        modules[name] = value
        return value
    end
    e.on_update = function(fn) c.update = fn end
    e.on_render_menu = function() end
    assert(loadfile(ROOT .. '/SilentRaven/main.lua', 't', e))()
    c.update()
    c.api, c.tracker = e.SilentRavenPlugin, e.require('silent_raven.tracker')
    c.bridge = assert(loadfile(ROOT .. '/WarPigs/wp_silent_raven.lua', 't', e))().new({})
    c.env = e
    function c.walk()
        c.bridge:observe(c.now, true)
        c.now = c.now + 1.1
        c.bridge:observe(c.now, true)
        c.bridge:tick(c.now, true)
        eq(c.api.get_status().pending, true, 'Whisper request queued')
        c.update()
        eq(c.tracker.running, true, 'SilentRaven walks the claim')
    end
    return c
end

case('R1 WarPigs: Rosie\'s Scavenger stand-in does not cancel the Whisper request; a real Scavenger still does', function()
    local c = whisper_fixture(); c.walk()
    c.env.Scavenger = rosie_scavenger()
    local ok, why = c.tracker.continuation_guard()
    eq(ok, true, 'guard with the stand-in busy (3.3.5: false, scavenger_busy); reason ' .. tostring(why))
    for _ = 1, 10 do
        c.now = c.now + 0.5
        c.bridge:observe(c.now, true)
        eq(c.bridge:tick(c.now, false), true, 'the bridge keeps the request')
        c.update()
    end
    local st = c.api.get_status()
    eq(st.running, true, 'request still running')
    eq(st.last_result ~= 'cancelled', true, 'not cancelled (3.3.5: cancelled, scavenger_busy)')

    local d = whisper_fixture(); d.walk()
    d.env.Scavenger = real_scavenger()
    local ok2, why2 = d.tracker.continuation_guard()
    eq(ok2, false, 'a real busy Scavenger still holds the claim')
    eq(type(why2) == 'string' and why2:find('scavenger_busy', 1, true) ~= nil, true, 'reason ' .. tostring(why2))
end)

-- ── R2 WarPigs outgoing teleport hold ───────────────────────────────────────
case('R2 WarPigs: the teleport is not held for Rosie\'s stand-in; a real Scavenger still holds it', function()
    local c = sandbox('WarPigs', {['wp_silent_raven'] = true})
    local o = c.load('core/orchestrator.lua')
    local dispatch = find_upvalue(o, 'dispatch')
    eq(type(dispatch) == 'table' and type(dispatch.third_party_busy) == 'function', true, 'dispatch found')
    c.e.Scavenger = rosie_scavenger()
    eq(dispatch.third_party_busy('Scavenger'), false, 'stand-in is not a third-party Scavenger')
    eq(dispatch.companion_hold(c.now, 'rosie_standin'), nil, 'no teleport hold (3.3.5: Scavenger collecting loot)')
    c.e.Scavenger = real_scavenger()
    eq(dispatch.third_party_busy('Scavenger'), true, 'real Scavenger busy')
    c.now = c.now + 0.5
    eq(dispatch.companion_hold(c.now, 'real_scavenger'), 'Scavenger collecting loot', 'real Scavenger holds')
end)

-- ── R3 WarPug planning hold ─────────────────────────────────────────────────
case('R3 WarPug: planning is not held for Rosie\'s stand-in; a real Scavenger still holds it', function()
    local c = sandbox('WarPug', {})
    local p = c.load('core/planner.lua')
    local busy = find_upvalue(p, 'third_party_busy')
    eq(type(busy), 'function', 'third_party_busy found')
    c.e.Scavenger = rosie_scavenger()
    eq(busy(c.now), nil, 'no hold (3.3.5: Scavenger busy)')
    c.e.Scavenger = real_scavenger()
    eq(busy(c.now), 'Scavenger busy', 'real Scavenger holds')
end)

-- ── R4 SilentRaven ──────────────────────────────────────────────────────────
case('R4 SilentRaven: third_party_reason ignores Rosie\'s stand-in; a real Scavenger still holds', function()
    local c = sandbox('SilentRaven', {})
    local coord = c.load('silent_raven/coordination.lua')
    c.e.Scavenger = rosie_scavenger()
    eq(coord.third_party_reason(), nil, 'no hold (3.3.5: scavenger_busy)')
    c.e.Scavenger = real_scavenger()
    eq(coord.third_party_reason(), 'scavenger_busy', 'real Scavenger holds')
    -- Butler is unchanged.
    c.e.Scavenger = rosie_scavenger()
    c.e.Butler = {is_busy = function() return true end}
    eq(coord.third_party_reason(), 'butler_busy', 'Butler still holds')
end)

-- ── R5 activities ───────────────────────────────────────────────────────────
case('R5 Arkham / Reaper / HordeDev / WonderCity: scavenger_busy() ignores Rosie\'s stand-in', function()
    for _, p in ipairs({{'ArkhamAsylum', 'core/utils.lua'}, {'Reaper', 'core/utils.lua'},
            {'HordeDev', 'core/loot_guard.lua'}, {'WonderCity', 'core/utils.lua'}}) do
        local c = sandbox(p[1], {})
        local m = c.load(p[2])
        local busy = (type(m) == 'table' and type(m.scavenger_busy) == 'function' and m.scavenger_busy)
            or find_upvalue(m, 'scavenger_busy')
        eq(type(busy), 'function', p[1] .. ': scavenger_busy found')
        c.e.Scavenger = rosie_scavenger()
        eq(busy(), false, p[1] .. ': stand-in is not busy (3.3.5: true)')
        c.e.Scavenger = real_scavenger()
        eq(busy(), true, p[1] .. ': real Scavenger busy')
        c.e.Scavenger = nil
        eq(busy(), false, p[1] .. ': no Scavenger')
    end
end)

-- ── R6 Batmobile freeroam ───────────────────────────────────────────────────
case('R6 Batmobile: freeroam does not yield to Rosie\'s stand-in; a real Scavenger still holds it', function()
    local c = sandbox('Batmobile', {})
    local update
    c.e.on_update = function(fn) update = fn end
    c.e.on_render_menu = function() end
    c.e.on_render = function() end
    c.e.checkbox = {new = function() return {get = function() return false end, set = function() end} end}
    c.e.get_hash = function() return 1 end
    c.load('main.lua')
    local yields = find_upvalue(update, 'freeroam_yields_to_looter')
    eq(type(yields), 'function', 'freeroam_yields_to_looter found')
    c.e.Scavenger = rosie_scavenger()
    eq(yields(), false, 'drives on (3.3.5: yields)')
    c.e.Scavenger = real_scavenger()
    eq(yields(), true, 'real Scavenger: yields')
end)

print(string.format('rosie scavenger skip: %d checks, %d failures', checks, #failures))
if #failures > 0 then error(#failures .. ' Rosie Scavenger stand-in regression(s) failed:\n  ' .. table.concat(failures, '\n  ')) end
