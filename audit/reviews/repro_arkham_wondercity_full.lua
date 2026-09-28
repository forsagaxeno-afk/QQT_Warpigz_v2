-- Scratch repros (auditor act1). Not part of the suite.
local ROOT = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local failures, checks = {}, 0
local function check(label, fn)
    checks = checks + 1
    local ok, err = pcall(fn)
    if not ok then failures[#failures + 1] = label .. ': ' .. tostring(err) end
end
local function vec(x, y, z)
    local v = {}
    v.x = function() return x end; v.y = function() return y end; v.z = function() return z or 0 end
    return v
end
local function dist(a, b)
    if a.get_position then a = a:get_position() end
    if b.get_position then b = b:get_position() end
    return math.max(math.abs(a:x() - b:x()), math.abs(a:y() - b:y()))
end

-- R1: Arkham interact_shrine walks forever to a shrine it can never reach.
check('R1 arkham interact_shrine: unreachable shrine is never given up', function()
    local f = {now = 100, pos = vec(0, 0), targets = 0, logs = {}}
    local shrine = {
        get_skin_name = function() return 'Shrine_DRLG_Test' end,
        is_interactable = function() return true end,
        get_position = function() return vec(8, 0, 12) end, -- ledge above, 8 m away
    }
    local modules = {
        ['core.utils'] = {distance = dist, player_in_pit = function() return true end,
            stop_movement = function() end},
        ['core.settings'] = {interact_shrine = true, speed_mode = false, check_distance = 12,
            orb_set_clear = function() end},
        ['core.tracker'] = {},
    }
    local env = setmetatable({
        require = function(n) return assert(modules[n], n) end,
        get_time_since_inject = function() return f.now end,
        get_local_player = function() return {get_position = function() return f.pos end} end,
        actors_manager = {get_ally_actors = function() return {shrine} end},
        console = {print = function(l) f.logs[#f.logs + 1] = l end},
        interact_object = function() end,
        BatmobilePlugin = setmetatable({set_target = function() f.targets = f.targets + 1; return false end},
            {__index = function() return function() return true end end}),
    }, {__index = _G})
    local task = assert(loadfile(ROOT .. '/ArkhamAsylum/tasks/interact_shrine.lua', 't', env))()
    for _ = 1, 600 * 20 do -- 600 s (the whole default pit timer), player never moves
        f.now = f.now + 0.05
        assert(task.shouldExecute(), 'shrine task released priority')
        task.Execute()
    end
    error(string.format('still walking to the shrine after 600 s (%d set_target calls, all rejected); logs=%d',
        f.targets, #f.logs))
end)

-- R2: WonderCity walk_kurast (town = Temis) walks during a SilentRaven claim.
check('R2 wondercity walk_kurast: ignores a running SilentRaven claim in Temis', function()
    local f = {now = 100, pos = vec(2400, -500), navs = 0}
    local settings = {town_zone = 'Skov_Temis', town_waypoint = 1, town_long_path_target = vec(2557, -506)}
    local utils = {
        player_in_zone = function(z) return z == 'Skov_Temis' end,
        distance = dist, stop_movement = function() end,
        get_spirit_brazier = function() return nil end, get_entrance_portal = function() return nil end,
        raven_claim_active = function() return true end,
    }
    local modules = {['core.utils'] = utils, ['core.settings'] = settings, ['data.path'] = {vec(0, 0), vec(1, 1)}}
    local env = setmetatable({
        require = function(n) return assert(modules[n], n) end,
        get_time_since_inject = function() return f.now end,
        get_local_player = function()
            return {get_position = function() return f.pos end, get_active_spell_id = function() return 0 end}
        end,
        teleport_to_waypoint = function() end,
        console = {print = function() end},
        BatmobilePlugin = setmetatable({
            is_long_path_navigating = function() return false end,
            navigate_long_path = function() f.navs = f.navs + 1; return true end,
        }, {__index = function() return function() return true end end}),
    }, {__index = _G})
    local task = assert(loadfile(ROOT .. '/WonderCity/tasks/walk_kurast.lua', 't', env))()
    for _ = 1, 100 do
        f.now = f.now + 0.05
        if task.shouldExecute() then task.Execute() end
    end
    assert(f.navs == 0, string.format('walk_kurast started %d long paths while SilentRaven claims', f.navs))
end)

-- R3: Arkham teleport_cerrigar re-casts 3 s after the first cast, in the gap
-- between the end of the channel and the loading screen (fixed to 8 s in
-- WonderCity's teleport_kurast after the "5 teleports in a row" live report).
local function tp_fixture(path)
    local f = {now = 100, teleports = 0, spell = 0, zone = 'Hawe_Zarbinzet'}
    local modules = {
        ['core.utils'] = {player_in_zone = function(z) return f.zone == z end,
            player_in_pit = function() return false end, player_in_undercity = function() return false end,
            stop_movement = function() end, raven_claim_active = function() return false end},
        ['core.settings'] = {town_zone = 'Scos_Cerrigar', town_waypoint = 1},
    }
    local env = setmetatable({
        require = function(n) return assert(modules[n], n) end,
        get_time_since_inject = function() return f.now end,
        get_local_player = function() return {get_active_spell_id = function() return f.spell end} end,
        get_current_world = function() return {get_name = function() return 'Sanctuary_Eastern_Continent' end} end,
        teleport_to_waypoint = function() f.teleports = f.teleports + 1 end,
        console = {print = function() end},
        BatmobilePlugin = setmetatable({}, {__index = function() return function() return true end end}),
    }, {__index = _G})
    f.task = assert(loadfile(ROOT .. path, 't', env))()
    return f
end
local function tp_scenario(f)
    f.task.Execute()                                               -- cast
    f.spell = 186139
    for _ = 1, 30 do f.now = f.now + 0.1; f.task.Execute() end     -- 3 s channel
    f.spell = 0
    for _ = 1, 10 do f.now = f.now + 0.1; f.task.Execute() end     -- 1 s before the loading screen
    return f.teleports
end
check('R3 arkham teleport_cerrigar: no re-cast before the loading screen', function()
    local n = tp_scenario(tp_fixture('/ArkhamAsylum/tasks/teleport_cerrigar.lua'))
    assert(n == 1, 'teleport_cerrigar cast ' .. n .. ' times (WonderCity teleport_kurast: '
        .. tp_scenario(tp_fixture('/WonderCity/tasks/teleport_kurast.lua')) .. ')')
end)


-- R4: a full bag starts an Alfred/Rosie town trip in the middle of a live boss
-- fight (alfred ranks above kill_boss; nothing checks for a live boss).
local function alfred_fixture(path, in_run)
    local f = {now = 100, calls = {}}
    local status = {enabled = true, need_trigger = true, inventory_full = true}
    _G.AlfredTheButlerPlugin = {
        get_status = function() return status end,
        trigger_tasks = function(c) f.calls[#f.calls + 1] = 'plain'; return true end,
        trigger_tasks_with_teleport = function(c) f.calls[#f.calls + 1] = 'teleport'; return true end,
    }
    local utils = {player_in_pit = in_run, player_in_undercity = in_run, player_in_zone = function() return false end,
        looter_hold = function() return false end, get_glyph_upgrade_gizmo = function() return nil end}
    local modules = {['core.utils'] = utils, ['core.settings'] = {town_zone = 'Skov_Temis', town_waypoint = 1,
        upgrade_toggle = true, return_for_loot = false}, ['core.tracker'] = {glyph_done = false}}
    local env = setmetatable({
        require = function(n) return assert(modules[n], n) end,
        get_time_since_inject = function() return f.now end,
        get_player_position = function() return vec(0, 0) end,
        loot_manager = {any_item_around = function() return false end},
        get_current_world = function() return {get_current_zone_name = function() return 'PIT_Subzone' end,
            get_name = function() return 'PIT_X' end} end,
        teleport_to_waypoint = function() end,
        console = {print = function() end},
        BatmobilePlugin = setmetatable({}, {__index = function() return function() return true end end}),
    }, {__index = _G})
    f.task = assert(loadfile(ROOT .. path, 't', env))()
    return f
end
check('R4 arkham alfred: no town trip while the Pit guardian is alive next to us', function()
    local f = alfred_fixture('/ArkhamAsylum/tasks/alfred.lua', function() return true end)
    if f.task.shouldExecute() then f.task.Execute() end
    _G.AlfredTheButlerPlugin = nil
    assert(#f.calls == 0, 'Arkham started a ' .. tostring(f.calls[1]) .. ' Alfred trip (boss fight not considered)')
end)
check('R4b wondercity alfred: no town trip while the Undercity boss is alive', function()
    local f = alfred_fixture('/WonderCity/tasks/alfred.lua', function() return true end)
    if f.task.shouldExecute() then f.task.Execute() end
    _G.AlfredTheButlerPlugin = nil
    assert(#f.calls == 0, 'WonderCity started a ' .. tostring(f.calls[1]) .. ' Alfred trip (boss fight not considered)')
end)

if #failures > 0 then error('act1 repros failed:\n' .. table.concat(failures, '\n')) end
print(string.format('PASS: act1 repros (%d checks)', checks))
