-- QQT_Warpigz_v3 (Q7): the Helltide search (tasks/search_helltide.lua) never
-- cycles the waypoints for the rest of the hour.
--
-- Live (v3.0.0) log 9982 -> 11206 (~20 min): after a Batmobile trap recovery
-- in Menestad (Fractured Peaks), the only active Helltide, the search logged
-- "skip_cached_zone set — cycling through TPs to find a different helltide",
-- "Teleporting to: wejinhani / jirandai / marowen / ironwolfs", "skipping
-- abandoned zone menestad" and one 45 s wait per cycle, for 20 minutes.
--
-- Loads the REAL HelltideRevamped task manager, tasks (helltide, search,
-- alfred) and core modules with QQT-shaped host stubs: a teleport is a 2.5 s
-- channel (teleport buff) followed by the landing zone; the Helltide buff is
-- present only in s.active_zone before minute 55; the UTC clock (os.date,
-- os.time) follows s.epoch. Batmobile is the synthetic boundary (its
-- giving_up flag is the trap). Runs under Lua 5.4 and LuaJIT.
local root = assert(SUITE_ROOT, 'SUITE_ROOT is required') .. '/HelltideRevamped/'
local checks, cases, failures = 0, 0, {}
local function ok(cond, message)
    checks = checks + 1
    if not cond then error(message or 'assertion failed', 2) end
end
local function eq(actual, expected, message)
    checks = checks + 1
    if actual ~= expected then
        error((message or 'values differ') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
    end
end
local function case(name, fn)
    cases = cases + 1
    local passed, err = xpcall(fn, debug.traceback)
    if passed then
        print('PASS Helltide search cycle: ' .. name)
    else
        failures[#failures + 1] = name .. ': ' .. tostring(err)
        print('FAIL Helltide search cycle: ' .. name .. ': ' .. tostring(err))
    end
end

local Vec = {}
Vec.__index = Vec
function Vec:new(x, y, z) return setmetatable({xx = x or 0, yy = y or 0, zz = z or 0}, self) end
function Vec:x() return self.xx end
function Vec:y() return self.yy end
function Vec:z() return self.zz end
function Vec:dist_to(o) return math.sqrt((self.xx - o:x())^2 + (self.yy - o:y())^2 + (self.zz - o:z())^2) end
function Vec:dist_to_ignore_z(o) return math.sqrt((self.xx - o:x())^2 + (self.yy - o:y())^2) end

local HELLTIDE_BUFF, TELEPORT_BUFF = 1066539, 44010
local TOWN_ZONE, TOWN_WP = 'Skov_Temis', 0x1CE51E
local HOUR = 1790481600 -- 2026-09-27 04:00:00 UTC
local MENESTAD, MAROWEN, IRONWOLFS, WEJINHANI, JIRANDAI = 0xACE9B, 0x27E01, 0xDEAFC, 0x9346B, 0x462E2
local ZONE_OF = {[MENESTAD] = 'Frac_Tundra_S', [MAROWEN] = 'Scos_Coast', [IRONWOLFS] = 'Kehj_Oasis',
    [WEJINHANI] = 'Hawe_Verge', [JIRANDAI] = 'Step_South', [TOWN_WP] = TOWN_ZONE}
local CHANNEL_S = 2.5

local function session(opts)
    opts = opts or {}
    local s = {now = 100, epoch = HOUR + (opts.minute or 10) * 60, pos = Vec:new(0, 0, 0),
        world = 'Sanctuary_Eastern_Continent', zone = opts.zone or TOWN_ZONE,
        active_zone = opts.active_zone, refuse = opts.refuse or {}, teleporting = false,
        logs = {}, teleports = {}, fires = {}, task_ticks = {}, channel = nil}
    function s.minute() return math.floor(s.epoch / 60) % 60 end
    -- s.outside: in the zone but outside the Helltide area (a waypoint
    -- teleport lands inside it unless s.waypoint_outside).
    function s.buffed() return s.zone == s.active_zone and s.minute() < 55 and not s.outside end
    local bm = {giving_up = false, paused = false, target = nil}
    s.bm = bm
    local batmobile = {
        pause = function() bm.paused = true end,
        resume = function() bm.paused = false end,
        set_target = function(_, t) bm.target = t; return true end,
        clear_target = function() bm.target = nil end,
        stop_long_path = function() end,
        update = function() end,
        move = function() end,
        is_paused = function() return bm.paused end,
        is_done = function() return false end,
        reset = function() bm.target = nil end,
        reset_movement = function() bm.target = nil end,
        get_target = function() return bm.target end,
        clear_giving_up = function() bm.giving_up = false end,
        is_giving_up = function() return bm.giving_up end,
        navigate_long_path = function() return true end,
        is_long_path_navigating = function() return false end,
        get_closeby_node = function(_, p) return p end,
        clear_traversal_blacklist = function() end,
    }
    local player = {
        get_position = function() return s.pos end,
        get_current_speed = function() return 0 end,
        is_dead = function() return false end,
        get_item_count = function() return 0 end,
        get_consumable_items = function() return {} end,
        get_attribute = function() return 0 end,
        get_buffs = function()
            local buffs = {}
            if s.buffed() then buffs[#buffs + 1] = {name_hash = HELLTIDE_BUFF} end
            if s.teleporting then buffs[#buffs + 1] = {name_hash = TELEPORT_BUFF} end
            return buffs
        end,
    }
    local world = {get_name = function() return s.world end,
        get_current_zone_name = function() return s.zone end,
        get_world_id = function() return 1 end}
    local env = setmetatable({}, {__index = _G})
    env._G = env
    env.vec3 = Vec
    env.get_time_since_inject = function() return s.now end
    env.get_helltide_coin_cinders = function() return 0 end
    env.get_player_position = function() return s.pos end
    env.get_local_player = function() return player end
    env.get_current_world = function() return world end
    env.on_render = function() end
    env.on_render_menu = function() end
    env.on_update = function() end
    env.console = {print = function(line) s.logs[#s.logs + 1] = {t = s.now, line = tostring(line)} end}
    env.target_selector = {get_near_target_list = function() return {} end}
    env.actors_manager = {get_all_actors = function() return {} end, get_enemy_actors = function() return {} end}
    env.loot_manager = {get_all_items_chest_sort_by_distance = function() return {} end,
        any_item_around = function() return false end}
    env.utility = {set_height_of_valid_position = function(p) return p end, is_point_walkeable = function() return true end}
    env.pathfinder = {request_move = function() end, clear_stored_path = function() end}
    -- A teleport: refused (false) for s.refuse[id], else a CHANNEL_S channel
    -- (teleport buff) and then the landing zone of that waypoint.
    env.teleport_to_waypoint = function(id)
        s.teleports[#s.teleports + 1] = {at = s.now, id = id}
        s.fires[id] = (s.fires[id] or 0) + 1
        if s.refuse[id] then return false end
        s.teleporting, s.channel = true, {id = id, until_t = s.now + CHANNEL_S}
        -- Q7 review: s.interrupts[id] channels end early (a cast, a hit):
        -- no landing, same zone, same spot.
        if s.interrupts and (s.interrupts[id] or 0) > 0 then
            s.interrupts[id] = s.interrupts[id] - 1
            s.channel.interrupt, s.channel.until_t = true, s.now + 1.0
        end
        return true
    end
    env.interact_object = function() end
    env.revive_at_checkpoint = function() end
    env.attributes = {PLAYER_IN_TOWN_LEVEL_AREA = 1}
    env.orbwalker = {set_clear_toggle = function() end, set_block_movement = function() end}
    env.os = setmetatable({
        date = function(fmt, t)
            if fmt == '!%M' or fmt == '%M' then return string.format('%02d', s.minute()) end
            if fmt == '!%S' then return string.format('%02d', math.floor(s.epoch) % 60) end
            return os.date(fmt, t or s.epoch)
        end,
        time = function(t) if t then return os.time(t) end return math.floor(s.epoch) end,
    }, {__index = os})
    env.BatmobilePlugin = batmobile
    env.LooteerPlugin = {get_enabled = function() return true end, is_actively_looting = function() return false end}

    local function control(value)
        return {value = value, get = function(self) return self.value end, set = function(self, n) self.value = n end}
    end
    local controls = setmetatable({}, {__index = function(t, k) local c = control(false); rawset(t, k, c); return c end})
    local defaults = {main_toggle = true, town = 0, salvage_toggle = false, helltide_chest_toggle = true,
        kill_monsters_toggle = false, kill_monsters_rarity = 0, farm_cinder_threshold = 0,
        maiden_disable_cinders = 0, manage_orbwalker = false, prioritize_traversals_toggle = false}
    for k, value in pairs(defaults) do controls[k] = control(value) end
    local noop = setmetatable({}, {__index = function() return function() end end})
    local modules = {
        gui = {elements = controls, render = function() end,
            town_data = {[0] = {zone_name = TOWN_ZONE, waypoint_sno = TOWN_WP},
                [1] = {zone_name = 'Scos_Cerrigar', waypoint_sno = 0x76D58}}},
        ['core.perf'] = noop,
        ['core.helltide_explorer'] = noop,
    }
    env.require = function(name)
        if modules[name] == nil then
            modules[name] = assert(loadfile(root .. name:gsub('%.', '/') .. '.lua', 't', env))()
        end
        return modules[name]
    end
    s.env = env
    s.settings = env.require('core.settings')
    s.settings:update_settings()
    s.tracker = env.require('core.tracker')
    s.tm = env.require('core.task_manager')
    s.search = env.require('tasks.search_helltide')

    function s.tick(seconds, dt)
        dt = dt or 0.1
        for _ = 1, math.floor(seconds / dt + 0.5) do
            s.now, s.epoch = s.now + dt, s.epoch + dt
            if s.channel and s.now >= s.channel.until_t then
                if s.channel.interrupt then
                    s.interrupted = (s.interrupted or 0) + 1
                else
                    s.zone = ZONE_OF[s.channel.id] or TOWN_ZONE
                    s.outside = s.waypoint_outside or nil
                    -- Q7 review: a landing puts the player at the waypoint.
                    s.pos = Vec:new(s.pos:x() + 50, s.pos:y(), s.pos:z())
                end
                s.teleporting, s.channel = false, nil
            end
            s.tm.execute_tasks()
            local name = s.tm.get_current_task().name or '?'
            local key = name:match('^Explore Helltide') and 'helltide' or name
            s.task_ticks[key] = (s.task_ticks[key] or 0) + 1
        end
    end
    function s.logged(pattern, since)
        local n = 0
        for _, e in ipairs(s.logs) do
            if (not since or e.t > since) and e.line:find(pattern, 1, true) then n = n + 1 end
        end
        return n
    end
    function s.fires_since(t, id)
        local n = 0
        for _, f in ipairs(s.teleports) do
            if f.at > t and (id == nil or f.id == id) then n = n + 1 end
        end
        return n
    end
    -- Scan teleports (not the home town, not the given zone) since t.
    function s.scan_fires(t, except)
        local n = 0
        for _, f in ipairs(s.teleports) do
            if f.at > t and f.id ~= TOWN_WP and f.id ~= except then n = n + 1 end
        end
        return n
    end
    function s.helltide_share(seconds)
        local before_h, before_all = s.task_ticks.helltide or 0, 0
        for _, n in pairs(s.task_ticks) do before_all = before_all + n end
        s.tick(seconds)
        local after_all = 0
        for _, n in pairs(s.task_ticks) do after_all = after_all + n end
        return ((s.task_ticks.helltide or 0) - before_h) / math.max(1, after_all - before_all)
    end
    -- Q7 review: real time passes without HR ticking (a town trip, a hold,
    -- HR disabled): the UTC clock and the inject clock advance together.
    function s.jump(to_epoch)
        s.now = s.now + (to_epoch - s.epoch)
        s.epoch = to_epoch
    end
    -- Farming in the active zone: the Batmobile trap fires the recovery.
    function s.trap()
        s.bm.giving_up = true
        s.tick(0.2)
        ok(s.tracker.skip_cached_zone, 'the trap recovery set skip_cached_zone')
    end
    return s
end

-- Farming the Menestad Helltide (found by the real search at minute 10).
local function farming_menestad(opts)
    opts = opts or {}
    local s = session({zone = TOWN_ZONE, active_zone = 'Frac_Tundra_S', minute = opts.minute, refuse = opts.refuse})
    s.tick(opts.find_s or 60)
    eq(s.zone, 'Frac_Tundra_S', 'the search found the Menestad Helltide')
    ok(s.buffed(), 'in the Helltide')
    s.tick(5)
    return s
end

case('live 3.0.0 log 9982-11206: Menestad abandoned and the only Helltide - one scan of the other four, back, no second cycle in 20 min', function()
    local s = farming_menestad()
    local t0 = s.now
    s.trap()
    eq(s.fires_since(t0, TOWN_WP), 1, 'the give-up teleport to the home town')
    -- ~20 minutes, as in the live log.
    s.tick(20 * 60)
    eq(s.scan_fires(t0, MENESTAD), 4, 'marowen, ironwolfs, wejinhani and jirandai once each')
    for _, id in ipairs({MAROWEN, IRONWOLFS, WEJINHANI, JIRANDAI}) do
        eq(s.fires_since(t0, id), 1, 'scan destination ' .. string.format('0x%X', id))
    end
    eq(s.logged('no other Helltide found — returning to menestad', t0), 1)
    eq(s.logged('Not in helltide, teleport to next town to check', t0), 0, 'no second (45 s) cycle')
    ok(s.logged('skipping abandoned zone menestad', t0) <= 1, 'abandoned zone skipped once per scan at most')
    eq(s.fires_since(t0, MENESTAD), 1, 'one teleport back to Menestad')
    eq(s.zone, 'Frac_Tundra_S', 'back in the only active Helltide')
    ok(s.buffed())
    eq(s.tracker.skip_cached_zone, false, 'the skip lasted one scan')
    -- Back right after the last scan hop, never after a 45 s end-of-cycle wait.
    local back_at, last_hop
    for _, f in ipairs(s.teleports) do
        if f.at > t0 and f.id == MENESTAD then back_at = f.at end
        if f.at > t0 and f.id == JIRANDAI then last_hop = f.at end
    end
    ok(back_at and last_hop and back_at - last_hop < 15,
        'back after the last hop: ' .. tostring(back_at and last_hop and back_at - last_hop))
    ok(s.helltide_share(60) > 0.9, 'farming the Helltide again')
    -- The scan is logged once (it used to precede every hop).
    eq(s.logged('skip_cached_zone set — cycling through TPs', t0), 1, 'scan-start log once per scan')
end)

case('a second trap in the same hour returns straight to the only Helltide (no second scan)', function()
    local s = farming_menestad()
    local t0 = s.now
    s.trap()
    s.tick(90)
    eq(s.zone, 'Frac_Tundra_S', 'back after the first scan')
    eq(s.scan_fires(t0, MENESTAD), 4)
    s.tick(30)
    local t1 = s.now
    s.trap()
    s.tick(60)
    eq(s.scan_fires(t1, MENESTAD), 0, 'the second trap scanned the other towns again')
    eq(s.logged('menestad is the only Helltide this hour', t1), 1, 'logged once')
    eq(s.fires_since(t1, MENESTAD), 1, 'straight back')
    eq(s.zone, 'Frac_Tundra_S')
    ok(s.buffed())
    eq(s.tracker.skip_cached_zone, false)
    -- Six more traps in the hour: each returns straight back; successful
    -- returns never count toward the fruitless-return bound.
    for _ = 1, 6 do
        s.tick(30)
        s.trap()
        s.tick(40)
        eq(s.zone, 'Frac_Tundra_S', 'back after a repeated trap')
    end
    eq(s.scan_fires(t1, MENESTAD), 0, 'no scan after repeated traps')
    eq(s.logged('without the Helltide buff', t1), 0, 'successful returns counted as fruitless')
    eq(s.logged('waypoint menestad unreachable', t1), 0)
    -- The next hour forgets it (a new zone): a trap there scans again.
    s.epoch = HOUR + 54 * 60 + 50
    s.tick(60)                                   -- minute 55: home town
    eq(s.zone, TOWN_ZONE)
    s.epoch = HOUR + 3600 + 5 * 60
    s.active_zone = 'Scos_Coast'
    s.tick(90)
    eq(s.zone, 'Scos_Coast', 'next hour: found by a normal search')
    local t2 = s.now
    s.trap()
    s.tick(90)
    eq(s.logged('skip_cached_zone set — cycling through TPs', t2), 1, 'a new hour scans again after a trap')
    eq(s.logged('no other Helltide found — returning to marowen', t2), 1)
    eq(s.zone, 'Scos_Coast')
end)

case('the hour ends during the scan: skip_cached_zone is released (C6), the next hour searches normally', function()
    local s = farming_menestad({minute = 53})
    s.epoch = HOUR + 54 * 60 + 50
    local t0 = s.now
    s.trap()
    s.tick(30)                                   -- minute 55 during the scan
    ok(s.minute() >= 55)
    s.tick(2)
    eq(s.tracker.skip_cached_zone, false, 'the trap skip outlived the hour')
    s.tick(60)
    eq(s.zone, TOWN_ZONE, 'idle in the home town until the next Helltide')
    eq(s.logged('Helltide is not active, wait until helltide starts', t0), 1, 'idle log once, not every tick')
    -- Next hour, Hawezar.
    s.epoch = HOUR + 3600 + 30
    s.active_zone = 'Hawe_Verge'
    local t1 = s.now
    s.tick(120)
    eq(s.logged('skip_cached_zone set', t1), 0, 'a stale trap skip in the next hour')
    eq(s.zone, 'Hawe_Verge', 'the next hour found its Helltide')
    ok(s.buffed())
    ok(t0 < t1)
end)

case("a new hour this task never saw end (town trip over minutes 55-59): last hour's zone is dropped, no endless return", function()
    local s = farming_menestad()
    -- The search never ran during minutes 55-59 (a town trip, a hold):
    -- the next hour's Helltide is in Scosglen, the player still in Menestad.
    s.jump(HOUR + 3600 + 60)                     -- Q7 review: both clocks advance
    s.active_zone = 'Scos_Coast'
    local t0 = s.now
    s.tick(5 * 60)
    eq(s.zone, 'Scos_Coast', "stuck returning to last hour's zone")
    ok(s.buffed())
    eq(s.logged('Returning to known helltide zone: menestad', t0), 0, "returned to last hour's zone")
    eq(s.logged("new Helltide hour — forgetting last hour's zone menestad", t0), 1)
end)

-- QQT_Warpigz_v3 3.3.3: the waypoint of this hour's only Helltide is retried
-- every 120 s (it waited for the next hour: one refused or interrupted return
-- idled the bot for up to 55 minutes).
case('the abandoned zone is also unusable by waypoint: one scan, then its waypoint retried every 120 s (no scan cycles)', function()
    -- Menestad reached another way (WarPigs War Plan teleport); its waypoint is refused.
    local s = session({zone = 'Frac_Tundra_S', active_zone = 'Frac_Tundra_S', refuse = {[MENESTAD] = true}})
    s.tick(5)
    ok(s.buffed())
    local t0 = s.now
    s.trap()
    s.tick(20 * 60)
    eq(s.scan_fires(t0, MENESTAD), 4, 'scan cycles after the only Helltide proved unreachable')
    eq(s.logged('skip_cached_zone set — cycling through TPs', t0), 1, 'one scan')
    eq(s.logged('no other Helltide found — returning to menestad', t0), 1)
    eq(s.logged('waypoint menestad unreachable — skipping this hour', t0), 0, 'not given up for the hour')
    local refused = s.logged("waypoint menestad unreachable — this hour's Helltide, retrying in 120s", t0)
    ok(refused >= 8 and refused <= 11, 'retried every 120 s in 20 min: ' .. refused)
    ok(s.fires_since(t0, MENESTAD) <= refused, 'at most one fire per retry: ' .. s.fires_since(t0, MENESTAD))
    ok(s.logged('cannot be reached by waypoint', t0) >= 1, 'the wait is logged')
    eq(s.logged('Not in helltide, teleport to next town to check', t0), 0)
    -- Minute 55: home town; the next hour searches again (menestad retried).
    s.epoch = HOUR + 56 * 60
    s.tick(30)
    eq(s.zone, TOWN_ZONE)
    s.epoch = HOUR + 3600 + 30
    s.active_zone = 'Kehj_Oasis'
    s.tick(120)
    eq(s.zone, 'Kehj_Oasis', 'the next hour found its Helltide')
end)

case('no Helltide in any patrol region (Nahantu/Skovos hour): scans back off after 3, never every 45 s all hour', function()
    local s = session({zone = TOWN_ZONE, active_zone = 'Kehj_Kurast', minute = 1})
    local t0 = s.now
    s.tick(50 * 60)
    ok(s.scan_fires(t0) <= 5 * 15, 'scan teleports in 50 min: ' .. s.scan_fires(t0))
    local scans = s.logged('Not in helltide, teleport to next town to check', t0)
    ok(scans >= 3, 'three scans at the normal pace: ' .. scans)
    ok(scans <= 3 + 12, 'bounded scans in 50 min: ' .. scans)
    eq(s.logged('no Helltide found in 3 scans this hour', t0), 1, 'the back-off is logged once')
    ok(s.scan_fires(t0) <= 5 * 15, 'teleports in 50 min: ' .. s.scan_fires(t0))
    -- The next hour starts at the normal pace again.
    s.epoch = HOUR + 3600 + 30
    s.active_zone = 'Step_South'
    s.tick(150)
    eq(s.zone, 'Step_South', 'the next hour found its Helltide')
end)

case('a WarPigs-style external enable in the abandoned-zone scan: disable/enable never carries the skip or the hour memory', function()
    local s = farming_menestad()
    s.trap()
    s.tick(90)
    eq(s.zone, 'Frac_Tundra_S')
    -- WarPigs disables HR (task_manager.stop -> cancel_pending) and re-enables it.
    s.tracker.skip_cached_zone = true
    s.tm.stop()
    eq(s.tracker.skip_cached_zone, false, 'disable kept skip_cached_zone')
    s.tick(5)
    s.bm.giving_up = true
    local t1 = s.now
    s.tick(90)
    -- After a stop the hour memory is gone too: a trap scans once more (bounded).
    eq(s.scan_fires(t1, MENESTAD), 4, 'one scan of the other four')
    eq(s.logged('no other Helltide found — returning to menestad', t1), 1)
    eq(s.zone, 'Frac_Tundra_S')
end)

case('outside the Helltide area in its own zone (walk back gave up): search teleports to the waypoint, no endless "Returning"', function()
    local s = farming_menestad()
    local t0 = s.now
    s.outside = true                             -- walked out of the Helltide area, same zone name
    s.tick(5 * 60)
    ok(s.fires_since(t0, MENESTAD) >= 1, 'no teleport: "Returning" without leaving the spot')
    ok(s.fires_since(t0, MENESTAD) <= 2, 'bounded teleports: ' .. s.fires_since(t0, MENESTAD))
    ok(s.logged('Returning to known helltide zone: menestad', t0) <= 2,
        '"Returning" repeated: ' .. s.logged('Returning to known helltide zone: menestad', t0))
    eq(s.zone, 'Frac_Tundra_S')
    ok(s.buffed(), 'back in the Helltide at the waypoint')
    ok(s.helltide_share(60) > 0.9, 'farming again')
end)

case('returns that never show the buff are bounded (4 returns, then a 120 s wait, logged)', function()
    local s = farming_menestad()
    local t0 = s.now
    s.outside, s.waypoint_outside = true, true   -- the waypoint itself is outside the Helltide area
    local seen
    for _ = 1, 15 * 60 do
        s.tick(1)
        if s.logged('4 returns to menestad without the Helltide buff', t0) > 0 then seen = s.now break end
    end
    ok(seen, 'the fruitless returns were bounded')
    eq(s.logged('Returning to known helltide zone: menestad', t0), 4, '4 returns before the wait')
    s.tick(15 * 60 - (seen - t0))
    local returns = s.logged('Returning to known helltide zone: menestad', t0)
    ok(returns <= 4 * 8, 'bounded "Returning" in 15 min: ' .. returns)
    ok(s.fires_since(t0, MENESTAD) <= returns, 'returns: ' .. s.fires_since(t0, MENESTAD))
    eq(s.logged('waypoint menestad unreachable — skipping this hour', t0), 0, 'never given up for the hour')
    -- QQT_Warpigz_v3 (Q7 review): farmed this hour, so it is this hour's
    -- only Helltide: wait for the next hour (logged once), never scan the
    -- other four towns (they cannot hold it).
    eq(s.scan_fires(t0, MENESTAD), 0, 'scan teleports after the bound')
    ok(s.logged('the only Helltide this hour (menestad) cannot be reached by waypoint', t0) >= 1)
    eq(s.logged('Not in helltide, teleport to next town to check', t0), 0)
end)

-- QQT_Warpigz_v3 (Q7 review) regressions -----------------------------------

case('Q7 review: a return inside its own zone whose channel is interrupted 4 times is re-fired, never a fruitless return', function()
    local s = farming_menestad()
    local t0 = s.now
    s.interrupts = {[MENESTAD] = 4}              -- casts / hits / a pickup walk during the channel
    s.outside = true                             -- the walk back gave up: same zone, outside the area
    s.tick(5 * 60)
    eq(s.interrupted, 4, 'four interrupted channels')
    eq(s.logged('teleport to menestad interrupted — trying again', t0), 4, 'each interrupt re-fired under TP_MAX_INTERRUPTS')
    eq(s.logged('without the Helltide buff', t0), 0, 'an interrupted channel counted as a fruitless return')
    eq(s.logged('waypoint menestad unreachable', t0), 0, "this hour's only Helltide skipped")
    eq(s.scan_fires(t0, MENESTAD), 0, 'scanned the other towns')
    eq(s.logged('Returning to known helltide zone: menestad', t0), 1, 'one return, re-fired inside it')
    eq(s.fires_since(t0, MENESTAD), 5, 'four interrupted fires and the landing')
    eq(s.zone, 'Frac_Tundra_S')
    ok(s.buffed(), 'back in the Helltide')
    ok(s.helltide_share(60) > 0.9, 'farming again')
end)

-- The search ticked in hour H (idle at minute 55), WarPigs disabled HR; in
-- hour H+1 the War Plan teleport lands in the Menestad Helltide and enables
-- HR: only the helltide task runs until the first trap or walk-out.
local function warpigs_next_hour(opts)
    opts = opts or {}
    local s = session({zone = TOWN_ZONE, active_zone = 'Scos_Coast', minute = 50})
    s.tick(60)
    eq(s.zone, 'Scos_Coast', 'hour H: the search found its Helltide')
    s.jump(HOUR + 55 * 60 + 5)
    s.tick(20)
    eq(s.zone, TOWN_ZONE, 'hour H, minute 55: the search idles in the home town')
    s.tm.stop()                                  -- WarPigs disables HR
    s.jump(HOUR + 3600 + 10 * 60)                -- hour H+1, minute 10
    s.refuse = opts.refuse or {}
    s.zone, s.active_zone, s.outside = 'Frac_Tundra_S', 'Frac_Tundra_S', nil
    s.tick(20)                                   -- HR enabled inside the Helltide
    ok(s.buffed(), 'farming the H+1 Helltide')
    return s
end

case("Q7 review: HR enabled inside this hour's Helltide after a search tick in an earlier hour keeps the zone and the trap skip", function()
    local s = warpigs_next_hour()
    local t1 = s.now
    s.trap()
    s.tick(120)
    eq(s.logged('new Helltide hour', t1), 0, "this hour's zone forgotten mid-hour")
    eq(s.logged('skip_cached_zone set — cycling through TPs', t1), 1, 'the trap skip was dropped')
    eq(s.logged('Not in helltide, teleport to next town to check', t1), 0)
    eq(s.scan_fires(t1, MENESTAD), 4, 'one scan of the other four')
    eq(s.zone, 'Frac_Tundra_S')
    local t2 = s.now
    s.trap()
    s.tick(60)
    eq(s.scan_fires(t2, MENESTAD), 0, 'the second trap in the hour scanned again')
    eq(s.logged('menestad is the only Helltide this hour', t2), 1)
    eq(s.zone, 'Frac_Tundra_S')
    ok(s.buffed())
end)

case("Q7 review: a walk-out after such an enable returns to this hour's zone (1 teleport), no 4-town scan", function()
    local s = warpigs_next_hour()
    local t1 = s.now
    s.outside = true
    s.tick(5 * 60)
    eq(s.logged('new Helltide hour', t1), 0)
    eq(s.logged('Returning to known helltide zone: menestad', t1), 1)
    eq(s.logged('Not in helltide, teleport to next town to check', t1), 0)
    eq(s.scan_fires(t1, MENESTAD), 0, 'scanned the other towns')
    eq(s.fires_since(t1, MENESTAD), 1)
    ok(s.buffed(), 'back in the Helltide')
end)

case("Q7 review: such an enable where this hour's only Helltide refuses its waypoint: one scan, then wait (no scans all hour)", function()
    local s = warpigs_next_hour({refuse = {[MENESTAD] = true}})
    local t1 = s.now
    s.trap()
    s.tick(20 * 60)
    eq(s.logged('new Helltide hour', t1), 0)
    eq(s.logged('skip_cached_zone set — cycling through TPs', t1), 1, 'one scan')
    eq(s.scan_fires(t1, MENESTAD), 4, 'scan teleports in 20 min')
    eq(s.logged('cannot be reached by waypoint', t1), 1, 'the wait is logged once')
    eq(s.logged('Not in helltide, teleport to next town to check', t1), 0)
end)

case("Q7 review: a walk-out return to this hour's zone whose waypoint is refused waits and retries (no 4-town scans all hour)", function()
    local s = warpigs_next_hour({refuse = {[MENESTAD] = true}})
    local t1 = s.now
    s.outside = true
    s.tick(15 * 60)
    local returns = s.logged('Returning to known helltide zone: menestad', t1)
    ok(returns >= 6 and returns <= 8, 'retried every 120 s: ' .. returns)
    eq(s.logged('waypoint menestad unreachable — skipping this hour', t1), 0)
    ok(s.logged('cannot be reached by waypoint', t1) >= 1, 'the wait is logged')
    eq(s.scan_fires(t1, MENESTAD), 0, 'scanned four towns that cannot hold this hour\'s Helltide')
    eq(s.logged('Not in helltide, teleport to next town to check', t1), 0)
end)

case("3.3.3: one refused return to this hour's zone (a fight at the edge) is retried, not a wait until the next hour", function()
    local s = warpigs_next_hour({refuse = {[MENESTAD] = true}})
    local t1 = s.now
    s.outside = true
    for _ = 1, 300 do
        s.tick(1)
        if s.logged("waypoint menestad unreachable", t1) > 0 then break end
    end
    eq(s.logged("waypoint menestad unreachable — this hour's Helltide, retrying in 120s", t1), 1, 'refused once')
    s.refuse = {}                               -- the next channel is not refused
    s.tick(4 * 60)
    ok(s.fires_since(t1, MENESTAD) >= 2, 'the return was fired again')
    eq(s.zone, 'Frac_Tundra_S')
    ok(s.buffed(), 'back in the Helltide within minutes, not next hour')
end)

case("Q7 review: HR started inside a Helltide (no search tick that hour); next hour last hour's zone is dropped on the first tick", function()
    local s = session({zone = 'Frac_Tundra_S', active_zone = 'Frac_Tundra_S', minute = 30})
    s.tick(20)
    ok(s.buffed(), 'farming from the start')
    -- A town trip over the hour change: back in Menestad in hour H+1, whose
    -- Helltide is in Scosglen.
    s.jump(HOUR + 3600 + 60)
    s.active_zone = 'Scos_Coast'
    local t0 = s.now
    s.tick(5 * 60)
    eq(s.logged("new Helltide hour — forgetting last hour's zone menestad", t0), 1)
    eq(s.logged('Returning to known helltide zone: menestad', t0), 0, "returned to last hour's zone")
    eq(s.logged('without the Helltide buff', t0), 0)
    eq(s.logged('waypoint menestad unreachable', t0), 0, 'last hour\'s zone marked unreachable for this hour')
    eq(s.zone, 'Scos_Coast')
    ok(s.buffed())
end)

case("Q7 review: a waypoint unusable last hour is retried in a new hour this task never saw end", function()
    -- Hour H: Menestad's waypoint is refused (marked unreachable), Scosglen found.
    local s = session({zone = TOWN_ZONE, active_zone = 'Scos_Coast', minute = 50, refuse = {[MENESTAD] = true}})
    s.tick(60)
    eq(s.zone, 'Scos_Coast')
    local t0 = s.now
    ok(s.logged('waypoint menestad unreachable', 0) == 1, 'hour H marked menestad unreachable')
    -- No search tick over minutes 55-59; hour H+1: Menestad, waypoint usable.
    s.jump(HOUR + 3600 + 30)
    s.refuse = {}
    s.active_zone = 'Frac_Tundra_S'
    s.tick(4 * 60)
    eq(s.zone, 'Frac_Tundra_S', "last hour's unreachable set carried into the new hour")
    ok(s.buffed())
    ok(s.fires_since(t0, MENESTAD) >= 1)
end)

case('Q7 review: a scan cut off by minute 55 never shortens the next hour\'s first scan; idle logged once per idle window', function()
    local s = session({zone = TOWN_ZONE, active_zone = 'Kehj_Kurast', minute = 54})
    s.epoch = HOUR + 54 * 60 + 38                -- a scan starts at 54:38 (no patrol region this hour)
    local t0 = s.now
    s.tick(90)
    ok(s.minute() >= 55)
    eq(s.zone, TOWN_ZONE, 'idle in the home town')
    ok(s.scan_fires(t0) >= 2 and s.scan_fires(t0) < 5, 'the scan was cut off: ' .. s.scan_fires(t0))
    eq(s.logged('Helltide is not active, wait until helltide starts', t0), 1)
    -- 00:00 of hour H+1: Fractured Peaks.
    s.jump(HOUR + 3600 + 1)
    s.active_zone = 'Frac_Tundra_S'
    local t1 = s.now
    s.tick(30)
    eq(s.zone, 'Frac_Tundra_S', 'found within 30 s of 00:00 (a leftover hop count ended the scan early)')
    eq(s.logged('Not in helltide, teleport to next town to check', t1), 1, 'the first scan of the hour logs its start')
    -- A second idle window logs again (once).
    s.jump(HOUR + 3600 + 55 * 60 + 5)
    s.tick(60)
    eq(s.logged('Helltide is not active, wait until helltide starts', t0), 2, 'idle log once per idle window')
end)

print(string.format('Helltide search cycle: %d cases, %d checks, %d failures', cases, checks, #failures))
if #failures > 0 then error('Helltide search cycle failures:\n' .. table.concat(failures, '\n')) end
print('PASS: test_helltide_search_cycle (' .. cases .. ' cases)')
