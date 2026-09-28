-- QQT_Warpigz_v3 Arkham 2.1.3 (auditor findings). Each case failed on the
-- pre-fix tree and passes after the fix:
--   S*  interact_shrine walked forever to an unreachable shrine (no walk
--       bound, set_target refusals ignored, XY-only, BetrayersEyeSwitch
--       without an interactable check).
--   B*  a hard Alfred need started a town trip in the middle of a live boss
--       fight (alfred ranks above kill_boss).
--   T*  teleport_cerrigar re-cast 3 s after the first cast, before the
--       loading screen (WonderCity 2.1.1 fix ported).
--   G   no goto in kill_monster / push_monsters (Lua 5.1 host rule).
local ROOT = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local checks, failures = 0, {}
local function ok(value, message)
    if not value then error(message or 'expected a true value', 2) end
    checks = checks + 1
end
local function eq(a, b, message)
    if a ~= b then error((message or 'values differ') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end
    checks = checks + 1
end
local function case(name, fn)
    local passed, err = xpcall(fn, debug.traceback)
    if passed then print('PASS arkham-audit-v3: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL arkham-audit-v3: ' .. name .. ': ' .. tostring(err)) end
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
local function load_task(path, modules, env)
    env.require = function(n) return assert(modules[n], n) end
    setmetatable(env, {__index = _G})
    return assert(loadfile(ROOT .. path, 't', env))()
end
local function count_logs(logs, needle)
    local n = 0
    for _, l in ipairs(logs) do if l:find(needle, 1, true) then n = n + 1 end end
    return n
end

-- ---------------------------------------------------------------- shrine
local function shrine_actor(name, x, y, z, interactable)
    return {
        get_skin_name = function() return name end,
        is_interactable = function() return interactable ~= false end,
        get_position = function() return vec(x, y, z) end,
    }
end
local function shrine_fixture(actors, set_target_result)
    local f = {now = 100, pos = vec(0, 0, 0), targets = 0, logs = {}, interacts = 0}
    local modules = {
        ['core.utils'] = {distance = dist, player_in_pit = function() return true end,
            stop_movement = function() end},
        ['core.settings'] = {interact_shrine = true, speed_mode = false, check_distance = 12,
            orb_set_clear = function() end},
        ['core.tracker'] = {},
    }
    local env = {
        get_time_since_inject = function() return f.now end,
        get_local_player = function() return {get_position = function() return f.pos end} end,
        actors_manager = {get_ally_actors = function() return actors end},
        console = {print = function(l) f.logs[#f.logs + 1] = l end},
        interact_object = function() f.interacts = f.interacts + 1 end,
        BatmobilePlugin = setmetatable({set_target = function()
            f.targets = f.targets + 1
            return set_target_result
        end}, {__index = function() return function() return true end end}),
    }
    f.task = load_task('/ArkhamAsylum/tasks/interact_shrine.lua', modules, env)
    return f
end
-- Pulses until shouldExecute is false; returns seconds taken (nil = never within limit).
local function shrine_run(f, limit, step)
    local t0 = f.now
    while f.now - t0 < limit do
        if not f.task.shouldExecute() then return f.now - t0 end
        f.task.Execute()
        if step then step(f) end
        f.now = f.now + 0.05
    end
    return nil
end

case('S1 interact_shrine: an unreachable shrine (no progress) is blacklisted after ~30 s', function()
    local f = shrine_fixture({shrine_actor('Shrine_DRLG_Test', 8, 0, 0)}, true)
    local after = shrine_run(f, 600)
    ok(after ~= nil, string.format('still walking to the shrine after 600 s (%d set_target calls)', f.targets))
    ok(after >= 29 and after <= 32, string.format('released after %.1f s', after))
    eq(count_logs(f.logs, 'no progress toward shrine'), 1, 'one log line')
end)

case('S2 interact_shrine: a shrine Batmobile refuses as a target is blacklisted after 3 refusals', function()
    local f = shrine_fixture({shrine_actor('Shrine_DRLG_Test', 8, 0, 0)}, false)
    local after = shrine_run(f, 600)
    ok(after ~= nil, string.format('still walking after 600 s (%d set_target calls, all rejected)', f.targets))
    eq(f.targets, 3, 'set_target calls before the blacklist')
    eq(count_logs(f.logs, 'refused the shrine target'), 1, 'one log line')
end)

case('S3 interact_shrine: a shrine on another floor level (> 5 m in Z) is not a target', function()
    local f = shrine_fixture({shrine_actor('Shrine_DRLG_Test', 8, 0, 12)}, true)
    ok(not f.task.shouldExecute(), 'shrine 12 m above the player selected')
    local g = shrine_fixture({shrine_actor('Shrine_DRLG_Test', 8, 0, 3)}, true)
    ok(g.task.shouldExecute(), 'shrine 3 m above (same level) must stay a target')
end)

case('S4 interact_shrine: a non-interactable BetrayersEyeSwitch is not a target', function()
    local f = shrine_fixture({shrine_actor('BetrayersEyeSwitch_Test', 4, 0, 0, false)}, true)
    ok(not f.task.shouldExecute(), 'used (non-interactable) BetrayersEyeSwitch selected')
    local g = shrine_fixture({shrine_actor('BetrayersEyeSwitch_Test', 4, 0, 0, true)}, true)
    ok(g.task.shouldExecute(), 'interactable BetrayersEyeSwitch must stay a target')
end)

case('S5 interact_shrine: a slow but progressing walk is not blacklisted', function()
    local shrine = shrine_actor('Shrine_DRLG_Test', 11, 0, 0)
    local f = shrine_fixture({shrine}, true)
    -- 0.2 m/s: 10 m in 50 s (longer than the 30 s window, but always progressing).
    for _ = 1, 50 * 20 do
        ok(f.task.shouldExecute(), 'shrine dropped while the player was closing in')
        f.task.Execute()
        f.pos = vec(math.min(9.5, f.pos:x() + 0.01), 0, 0)
        f.now = f.now + 0.05
    end
    eq(count_logs(f.logs, 'blacklisting'), 0, 'no blacklist while progressing')
    ok(f.interacts > 0, 'interacted once in range')
end)

case('S6 interact_shrine: time yielded to Alfred is not no-progress time', function()
    local f = shrine_fixture({shrine_actor('Shrine_DRLG_Test', 8, 0, 0)}, true)
    f.task.Execute()
    f.now = f.now + 20
    f.task.on_yield(20)
    f.task.Execute()
    f.now = f.now + 20
    f.task.on_yield(20)
    ok(f.task.shouldExecute(), 'blacklisted after yielded time only')
    f.task.Execute()
    eq(count_logs(f.logs, 'blacklisting'), 0, 'no blacklist from yielded time')
end)

-- ---------------------------------------------------------------- alfred / boss
local function alfred_fixture(opts)
    opts = opts or {}
    local f = {now = 100, calls = {}, logs = {}, teleports = 0, enemies = {}, zone = 'PIT_Subzone', world = 'PIT_X'}
    f.status = {enabled = true, need_trigger = true, need_repair = true}
    local alfred = {
        get_status = function() return f.status end,
        trigger_tasks = function() f.calls[#f.calls + 1] = 'plain'; f.status.running = true; return true end,
        trigger_tasks_with_teleport = function() f.calls[#f.calls + 1] = 'teleport'; f.status.running = true; return true end,
    }
    f.in_pit = opts.in_pit ~= false
    local utils = {player_in_pit = function() return f.in_pit end, player_in_zone = function() return false end,
        looter_hold = function() return false end, get_glyph_upgrade_gizmo = function() return nil end}
    local modules = {['core.utils'] = utils, ['core.settings'] = {town_zone = 'Scos_Cerrigar', town_waypoint = 1,
        upgrade_toggle = true, return_for_loot = false}, ['core.tracker'] = {glyph_done = false}}
    local env = {
        AlfredTheButlerPlugin = alfred,
        get_time_since_inject = function() return f.now end,
        get_player_position = function() return vec(0, 0, 0) end,
        loot_manager = {any_item_around = function() return false end},
        get_current_world = function() return {get_current_zone_name = function() return f.zone end,
            get_name = function() return f.world end} end,
        teleport_to_waypoint = function() f.teleports = f.teleports + 1 end,
        target_selector = {get_near_target_list = function(pos, range)
            local out = {}
            for _, e in ipairs(f.enemies) do if dist(pos, e) <= range then out[#out + 1] = e end end
            return out
        end},
        console = {print = function(l) f.logs[#f.logs + 1] = l end},
        BatmobilePlugin = setmetatable({}, {__index = function() return function() return true end end}),
    }
    f.task = load_task('/ArkhamAsylum/tasks/alfred.lua', modules, env)
    return f
end
local function boss(x, hp)
    return {get_position = function() return vec(x, 0, 0) end, is_boss = function() return true end,
        get_current_health = function() return hp end}
end
local function pulse(f)
    if f.task.shouldExecute() then f.task.Execute() end
    f.now = f.now + 0.1
end

case('B1 alfred: no new town trip while the Pit guardian is alive within 30 m; starts after ~90 s', function()
    local f = alfred_fixture()
    f.enemies = {boss(10, 5000)}
    local t0 = f.now
    while #f.calls == 0 and f.now - t0 < 200 do pulse(f) end
    ok(#f.calls == 1, 'no trip within 200 s (the defer must be bounded)')
    local after = f.now - t0
    ok(after >= 89, string.format('Arkham started a %s Alfred trip %.1f s into a live boss fight', f.calls[1], after))
    ok(after <= 92, string.format('trip started after %.1f s', after))
    eq(count_logs(f.logs, 'Alfred trip deferred: live boss'), 1, 'one log line')
end)

case('B2 alfred: a dead or distant boss does not defer the trip', function()
    local f = alfred_fixture()
    f.enemies = {boss(10, 0), boss(45, 5000)}
    pulse(f)
    eq(#f.calls, 1, 'trip started at once')
    local g = alfred_fixture({in_pit = false})
    g.enemies = {boss(10, 5000)}
    pulse(g)
    eq(#g.calls, 1, 'outside the pit a boss never defers')
end)

case('B3 alfred: a trip already running is never interrupted by a boss', function()
    local f = alfred_fixture()
    pulse(f)
    eq(#f.calls, 1, 'trip started')
    f.enemies = {boss(5, 5000)}
    for _ = 1, 50 do
        ok(f.task.shouldExecute(), 'own running trip dropped for a boss')
        f.task.Execute()
        f.now = f.now + 0.1
    end
    ok(f.task.own_trip(), 'trip still ours')
    eq(#f.calls, 1, 'no second request')
end)

-- ---------------------------------------------------------------- teleports
local function tp_fixture()
    local f = {now = 100, teleports = 0, spell = 0, world = 'Sanctuary_Eastern_Continent'}
    local modules = {
        ['core.utils'] = {player_in_zone = function() return false end,
            player_in_pit = function() return false end, stop_movement = function() end,
            raven_claim_active = function() return false end},
        ['core.settings'] = {town_zone = 'Scos_Cerrigar', town_waypoint = 1},
    }
    local env = {
        get_time_since_inject = function() return f.now end,
        get_local_player = function() return {get_active_spell_id = function() return f.spell end} end,
        get_current_world = function() return {get_name = function() return f.world end} end,
        teleport_to_waypoint = function() f.teleports = f.teleports + 1 end,
        console = {print = function() end},
        BatmobilePlugin = setmetatable({}, {__index = function() return function() return true end end}),
    }
    f.task = load_task('/ArkhamAsylum/tasks/teleport_cerrigar.lua', modules, env)
    return f
end

case('T1 teleport_cerrigar: no re-cast between the end of the channel and the loading screen', function()
    local f = tp_fixture()
    f.task.Execute()                                               -- cast
    f.spell = 186139
    for _ = 1, 30 do f.now = f.now + 0.1; f.task.Execute() end     -- 3 s channel
    f.spell = 0
    for _ = 1, 30 do f.now = f.now + 0.1; f.task.Execute() end     -- 3 s before the loading screen
    eq(f.teleports, 1, 'teleport_cerrigar casts within 6 s')
    for _ = 1, 30 do f.now = f.now + 0.1; f.task.Execute() end     -- 9 s: nothing happened, retry once
    eq(f.teleports, 2, 'retry after the 8 s debounce')
end)

case('T2 teleport_cerrigar: a loading screen past the debounce is not a failed cast', function()
    local f = tp_fixture()
    f.task.Execute()
    f.world = 'Limbo'
    for _ = 1, 150 do f.now = f.now + 0.1; f.task.Execute() end
    eq(f.teleports, 1, 'casts while loading')
    f.world = 'Sanctuary_Eastern_Continent'
    for _ = 1, 30 do f.now = f.now + 0.1; f.task.Execute() end
    eq(f.teleports, 1, 'no cast right after loading ended (debounce re-armed)')
end)

-- ---------------------------------------------------------------- goto
case('G no goto / labels in kill_monster and push_monsters', function()
    for _, name in ipairs({'kill_monster', 'push_monsters'}) do
        local fh = assert(io.open(ROOT .. '/ArkhamAsylum/tasks/' .. name .. '.lua', 'r'))
        local src = fh:read('*a')
        fh:close()
        ok(not src:find('%f[%w_]goto%f[^%w_]'), name .. '.lua contains goto')
        ok(not src:find('::[%a_][%w_]*::'), name .. '.lua contains a ::label::')
    end
end)

print(string.format('arkham audit v3: %d checks, %d failures', checks, #failures))
if #failures > 0 then error(#failures .. ' arkham audit regression(s) failed') end
