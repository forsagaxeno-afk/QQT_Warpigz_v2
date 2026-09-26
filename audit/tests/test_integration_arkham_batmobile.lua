-- Joint ArkhamAsylum + Batmobile regressions (round 3: R10 / ARK-3).
-- Loads the REAL Batmobile plugin (main.lua, gui, settings, navigator,
-- explorer, pathfinder, long_path, external ...) and the REAL ArkhamAsylum
-- plugin (main.lua, gui, settings, task_manager and every task), each with
-- its own module cache (QQT resolves require() per plugin) and one shared
-- global table (plugins share _G: BatmobilePlugin / ArkhamAsylumPlugin).
-- Only the QQT host (world, player movement, actors) and the closed-source
-- AlfredTheButler / Looteer are behaviour-level mocks.
-- Runs under Lua 5.4 and LuaJIT.
local ROOT = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local ARK_DIR, BAT_DIR = ROOT .. '/ArkhamAsylum-1.0.6/', ROOT .. '/Batmobile-1.0.12/'
local checks, failures = 0, {}
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        checks = checks + 1
        print('PASS arkham+batmobile: ' .. name)
    else
        failures[#failures + 1] = name .. ': ' .. tostring(err)
        print('FAIL arkham+batmobile: ' .. name .. ': ' .. tostring(err))
    end
end

local Vec = {}; Vec.__index = Vec
function Vec.new(_, x, y, z) return setmetatable({_x = x or 0, _y = y or 0, _z = z or 0}, Vec) end
function Vec:x() return self._x end
function Vec:y() return self._y end
function Vec:z() return self._z end
function Vec:dist_to(o)
    local dx, dy, dz = self._x - o:x(), self._y - o:y(), self._z - o:z()
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end
local function v(x, y) return Vec:new(x, y, 0) end

-- Walkable boxes {min_x, max_x, min_y, max_y} per world zone.
local PIT = {name = 'PIT_Joint_Floor', zone = 'PIT_Subzone', id = 41, box = {-20, 220, -24, 24}}
local TEMIS = {name = 'Sanctuary_Eastern_Continent', zone = 'Skov_Temis', id = 1,
    box = {2480, 2660, -580, -400}, entry = v(2540, -470), portal = v(2520, -480)}
local KYOVASHAD = {name = 'Sanctuary_Eastern_Continent', zone = 'Frac_Kyovashad', id = 1,
    box = {-1620, -1380, 680, 920}, entry = v(-1500, 800), portal = v(-1520, 790)}
local LIMBO = {name = 'Limbo', zone = '[sno none]', id = 0}
-- Pit floor portal ('Prefab_Portal_Dungeon_Generic' is both the descend
-- portal and the portal back up next to the arrival point).
local function portal_actor(x, y, to, spawn)
    local a = {pos = v(x, y), to = to, spawn = spawn}
    function a:get_skin_name() return 'Prefab_Portal_Dungeon_Generic' end
    function a:get_position() return self.pos end
    function a:is_interactable() return true end
    function a:is_dead() return false end
    function a:get_current_health() return 1 end
    function a:is_boss() return false end
    function a:is_elite() return false end
    function a:is_champion() return false end
    return a
end
local ENTRY = {name = 'PIT_Joint_Entry', zone = 'PIT_Subzone', id = 40, box = {-30, 30, -20, 20}}
local DEEP = {name = 'PIT_Joint_Deep', zone = 'PIT_Subzone', id = 42, box = {-20, 220, -24, 24}}
ENTRY.actors = {portal_actor(8, 0, DEEP, v(0, 0))}
DEEP.actors = {portal_actor(-5, 0, ENTRY, v(6, 3))}
local SPEED = 7 -- units per second the host moves the player toward the last move request

local function copy_keys(t)
    local out, n = {}, 0
    for k in pairs(t) do out[k] = true; n = n + 1 end
    return out, n
end
local function kept(before, now_set)
    local n, total = 0, 0
    for k in pairs(before) do
        total = total + 1
        if now_set[k] ~= nil then n = n + 1 end
    end
    return n, total
end

-- opts.batmobile_first: order of the plugins' on_update callbacks (the host
-- order is not a contract, so both orders must work); opts.start: first pit
-- floor; opts.town / opts.callback_first: Alfred's service town and whether
-- its callback fires in town before the return portal.
local function world(opts)
    opts = opts or {}
    local h = {now = 1000, log = {}, place = opts.start or PIT, pos = v(0, 0), goal = nil, actors = {}, floor_loot = false,
        vendor = false, waypoints = {}, interactions = {}, pit_opens = 0, orb = {}, updates = {},
        requests = {}, alfred_moves = 0}
    local G = setmetatable({}, {__index = _G})
    G._G = G
    local function widget(default, key)
        local w = {v = default, key = key, state = 0}
        function w:get() return self.v end
        function w:set(val) self.v = val; self.state = (val == true or val == 1) and 1 or 0 end
        function w:get_state() return self.state end
        function w:get_key() return self.key end
        function w:render() end
        function w:push() return false end
        function w:pop() end
        return w
    end
    G.checkbox = {new = function(_, d) return widget(d) end}
    G.combo_box = {new = function(_, d) return widget(d) end}
    G.slider_int = {new = function(_, _, _, d) return widget(d) end}
    G.slider_float = {new = function(_, _, _, d) return widget(d) end}
    G.tree_node = {new = function() return widget(nil) end}
    G.keybind = {new = function(_, key) return widget(false, key) end}
    G.get_hash = function(x) return x end
    G.render_menu_header = function() end
    G.console = {print = function(m) h.log[#h.log + 1] = string.format('%.1f %s', h.now, tostring(m)) end}
    G.get_time_since_inject = function() return h.now end
    local player = {}
    function player:get_position() return h.pos end
    function player:get_buffs() return {} end
    function player:get_attribute() return 0 end
    function player:get_character_class_id() return 0 end
    function player:is_dead() return false end
    function player:get_active_spell_id() return -1 end
    function player:get_current_health() return 100 end
    function player:get_skin_name() return 'Player' end
    G.get_local_player = function() return player end
    G.get_player_position = function() return h.pos end
    local w = {}
    function w:get_name() return h.place.name end
    function w:get_current_zone_name() return h.place.zone end
    function w:get_world_id() return h.place.id end
    G.get_current_world = function() return w end
    G.vec3 = Vec
    G.vec2 = {new = function() return {} end}
    G.attributes = {PLAYER_IN_TOWN_LEVEL_AREA = 1, CURRENT_MOUNT = 2}
    local function actors() return h.place.actors or h.actors end
    G.actors_manager = {get_ally_actors = actors, get_all_actors = actors, get_enemy_npcs = function() return {} end}
    G.target_selector = {get_near_target_list = function() return {} end}
    G.loot_manager = {any_item_around = function() return h.floor_loot end,
        is_in_vendor_screen = function() return h.vendor end}
    G.interact_object = function(a)
        h.interactions[#h.interactions + 1] = {actor = a, t = h.now, place = h.place}
        -- a pit portal: short delay, loading screen, then the other floor
        if a.to and not h.travel then h.travel = {at = h.now + 0.5, to = a.to, pos = a.spawn} end
    end
    G.reset_all_dungeons = function() end
    G.revive_at_checkpoint = function() end
    G.get_glyphs = function() return {} end
    G.upgrade_glyph = function() end
    G.get_screen_width = function() return 1920 end
    G.graphics = {text_2d = function() end, circle_3d = function() end, line = function() end}
    G.color_white = function() return 0 end
    G.orbwalker = {set_clear_toggle = function(val) h.orb.clear = val end,
        set_block_movement = function(val) h.orb.block = val end, get_orb_mode = function() return 0 end}
    G.cast_spell = {position = function() return false end}
    local function walkable(p)
        local b = h.place.box
        return b ~= nil and p:x() >= b[1] and p:x() <= b[2] and p:y() >= b[3] and p:y() <= b[4]
    end
    G.utility = {open_pit_portal = function() h.pit_opens = h.pit_opens + 1 end,
        set_height_of_valid_position = function(p) return p end,
        is_point_walkeable = walkable, can_cast_spell = function() return false end,
        is_ray_cast_walkeable = function() return true end}
    local function request(p, kind)
        h.goal = Vec:new(p:x(), p:y(), 0)
        h.requests[#h.requests + 1] = {t = h.now, kind = kind, place = h.place, alfred = h.alfred_driving}
    end
    G.pathfinder = {request_move = function(p) request(p, 'request_move') end,
        force_move_raw = function(p) request(p, 'force_move_raw') end, clear_stored_path = function() end}
    -- A waypoint teleport: short channel, loading screen, then the town. It
    -- interrupts whatever Alfred was doing (its return portal included).
    G.teleport_to_waypoint = function(sno)
        h.waypoints[#h.waypoints + 1] = {t = h.now, sno = sno, place = h.place}
        if h.trip and h.trip.phase ~= 'done' then h.trip.phase = 'interrupted' end
        h.travel = {at = h.now + 1, to = TEMIS, pos = TEMIS.entry}
    end
    G.on_update = function(fn) h.updates[#h.updates + 1] = fn end
    G.on_render = function() end
    G.on_render_menu = function() end

    -- AlfredTheButler: source-shaped status; the with-teleport trip is a host
    -- script (town portal out, services, town portal back to the exit point).
    local al = {enabled = true, need_trigger = false, inventory_full = false, need_repair = false,
        trigger_tasks = false, teleport = false, teleport_done = false, teleport_failed = false,
        restock_count = 0, paused = false, triggers = {}}
    h.alfred = al
    G.AlfredTheButlerPlugin = {
        get_status = function()
            return {enabled = al.enabled, need_trigger = al.need_trigger, inventory_full = al.inventory_full,
                need_repair = al.need_repair, trigger_tasks = al.trigger_tasks, teleport = al.teleport,
                teleport_done = al.teleport_done, teleport_failed = al.teleport_failed,
                restock_count = al.restock_count, paused = al.paused}
        end,
        trigger_tasks = function(caller, cb)
            al.triggers[#al.triggers + 1] = {t = h.now, caller = caller, teleport = false}; al.cb = cb
            al.trigger_tasks = true
        end,
        trigger_tasks_with_teleport = function(caller, cb)
            al.triggers[#al.triggers + 1] = {t = h.now, caller = caller, teleport = true}; al.cb = cb
            al.trigger_tasks, al.teleport, al.teleport_done = true, true, false
            h.trip = {phase = 'channel', t = h.now, exit = h.pos, exit_place = h.place,
                town = opts.town or TEMIS, callback_first = opts.callback_first}
        end,
    }
    G.LooteerPlugin = {get_enabled = function() return true end, is_actively_looting = function() return false end}

    -- One module cache per plugin; globals they write land in the shared table.
    local function plugin(dir)
        local modules = {}
        local env = setmetatable({}, {__index = G, __newindex = G})
        rawset(env, 'require', function(name)
            if modules[name] ~= nil then return modules[name] end
            local chunk = assert(loadfile(dir .. name:gsub('%.', '/') .. '.lua', 't', env))
            local r = chunk(); if r == nil then r = true end
            modules[name] = r
            return r
        end)
        assert(loadfile(dir .. 'main.lua', 't', env))()
        return modules
    end
    local bat_mod
    if opts.batmobile_first then bat_mod = plugin(BAT_DIR) end
    local ark_mod = plugin(ARK_DIR)
    if not opts.batmobile_first then bat_mod = plugin(BAT_DIR) end
    h.G, h.api, h.bm = G, G.ArkhamAsylumPlugin, G.BatmobilePlugin
    h.tracker, h.tm, h.ark_gui = ark_mod['core.tracker'], ark_mod['core.task_manager'], ark_mod['gui']
    h.nav, h.explorer = bat_mod['core.navigator'], bat_mod['core.explorer']
    -- Instrument (not replace) the shared Batmobile API.
    h.bm_calls = {}
    for _, name in ipairs({'reset', 'set_target', 'navigate_long_path', 'move', 'resume'}) do
        local real = h.bm[name]
        h.bm[name] = function(caller, ...)
            h.bm_calls[#h.bm_calls + 1] = {name = name, caller = caller, t = h.now, place = h.place}
            return real(caller, ...)
        end
    end

    local function go(place, pos) h.place, h.pos, h.goal = place, pos, nil end
    -- Host side of Alfred's with-teleport trip.
    local function alfred_tick()
        local trip = h.trip
        if not trip or trip.phase == 'done' or trip.phase == 'interrupted' then return end
        local age = h.now - trip.t
        local function next_phase(phase) trip.phase, trip.t = phase, h.now end
        if trip.phase == 'channel' and age >= 1 then
            go(LIMBO, v(0, 0)); next_phase('loading_out')
        elseif trip.phase == 'loading_out' and age >= 2 then
            go(trip.town, trip.town.entry); next_phase('services')
        elseif trip.phase == 'services' then
            -- vendors: walk around the town square
            h.alfred_driving = true
            G.pathfinder.request_move(v(trip.town.entry:x() + 20, trip.town.entry:y() + 10))
            h.alfred_driving = false
            h.alfred_moves = h.alfred_moves + 1
            if age >= 8 then
                al.inventory_full, al.need_trigger = false, false
                h.floor_loot = false
                if trip.callback_first then
                    al.trigger_tasks, al.teleport_done = false, true
                    local cb = al.cb; al.cb = nil
                    trip.callback_at = h.now
                    if cb then cb() end
                end
                next_phase('to_portal')
            end
        elseif trip.phase == 'to_portal' then
            local portal = trip.town.portal
            if h.pos:dist_to(portal) <= 1.5 then
                next_phase('loading_back'); go(LIMBO, v(0, 0))
            elseif age > 20 then
                al.teleport_failed = true; next_phase('interrupted')
            else
                h.alfred_driving = true
                G.pathfinder.request_move(portal)
                h.alfred_driving = false
            end
        elseif trip.phase == 'loading_back' and age >= 2 then
            -- the town portal returns to where the pit was left
            go(trip.exit_place, Vec:new(trip.exit:x() + 0.5, trip.exit:y(), 0))
            next_phase('done')
            if not trip.callback_first then
                al.trigger_tasks, al.teleport_done = false, true
                local cb = al.cb; al.cb = nil
                if cb then cb() end
            end
        end
    end
    function h.frame(dt)
        dt = dt or 0.1
        h.now = h.now + dt
        if h.travel and h.now >= h.travel.at then
            if h.place ~= LIMBO then go(LIMBO, v(0, 0)); h.travel.at = h.now + 2
            else go(h.travel.to, h.travel.pos); h.travel = nil end
        end
        alfred_tick()
        for _, fn in ipairs(h.updates) do fn() end
        -- the host walks the player toward the last movement request
        if h.goal and h.place ~= LIMBO then
            local dx, dy = h.goal:x() - h.pos:x(), h.goal:y() - h.pos:y()
            local d = math.sqrt(dx * dx + dy * dy)
            local step = SPEED * dt
            if d <= step then h.pos = Vec:new(h.goal:x(), h.goal:y(), 0)
            else
                local nxt = Vec:new(h.pos:x() + dx / d * step, h.pos:y() + dy / d * step, 0)
                if walkable(nxt) then h.pos = nxt end
            end
        end
    end
    function h.run_for(seconds, each)
        local stop = h.now + seconds
        while h.now < stop do
            h.frame()
            if each then each() end
        end
    end
    function h.task() return h.tm.get_current_task().name end
    function h.logged(text)
        local n = 0
        for _, l in ipairs(h.log) do if l:find(text, 1, true) then n = n + 1 end end
        return n
    end
    function h.count(name, caller, pred)
        local n = 0
        for _, c in ipairs(h.bm_calls) do
            if c.name == name and (caller == nil or c.caller == caller) and (pred == nil or pred(c)) then n = n + 1 end
        end
        return n
    end
    function h.dump(n)
        local out = {}
        for i = math.max(1, #h.log - (n or 25)), #h.log do out[#out + 1] = h.log[i] end
        return table.concat(out, '\n')
    end
    return h
end

-- Explore part of the pit floor with Arkham driving the real Batmobile, then
-- fill the inventory with loot on the floor: Arkham's with-teleport trip.
-- Frames until Alfred's trip script ends (back in the pit, or aborted).
local function run_trip(h, each)
    local stop = h.now + 60
    while h.now < stop and h.trip.phase ~= 'done' and h.trip.phase ~= 'interrupted' do
        h.frame()
        if each then each() end
    end
end

local function explore_then_trip(h, seconds)
    h.api.enable()
    h.run_for(seconds or 20)
    local ex = h.explorer
    assert(h.task() == 'explore_pit', 'Arkham explores the pit: ' .. h.task())
    assert(ex.visited_count > 200 and ex.frontier_count > 0,
        string.format('pit explored before the trip (visited=%d frontiers=%d)', ex.visited_count, ex.frontier_count))
    assert(seconds ~= nil or h.pos:dist_to(v(0, 0)) > 25, 'the player moved through the pit: x=' .. h.pos:x())
    -- boss already seen on this floor (run state that must survive the trip)
    h.tracker.boss_seen, h.tracker.boss_position = true, v(210, 0)
    local before = {pit_start = h.tracker.pit_start_time, visited_count = ex.visited_count}
    before.visited = copy_keys(ex.visited)
    before.frontier = {}
    for key, node in pairs(ex.frontier_node) do before.frontier[key] = node end
    h.floor_loot = true
    h.alfred.need_trigger, h.alfred.inventory_full = true, true
    local guard = 0
    while #h.alfred.triggers == 0 and guard < 40 do h.frame(); guard = guard + 1 end
    assert(#h.alfred.triggers == 1 and h.alfred.triggers[1].teleport, 'with-teleport Alfred trip from the pit')
    before.trip_at = h.now
    return before
end

-- Back in the same pit world: the run and Batmobile's map both resume.
local function assert_resumed(h, before)
    local ex = h.explorer
    assert(h.place == PIT, 'back in the pit: ' .. tostring(h.place.name) .. '\n' .. h.dump())
    assert(h.logged('resuming the run') == 1, 'Arkham resumes the same run\n' .. h.dump())
    assert(h.tracker.pit_start_time == before.pit_start, string.format('deadline restarted (%.1f -> %.1f)',
        before.pit_start, h.tracker.pit_start_time))
    assert(h.tracker.boss_seen == true and h.tracker.boss_position ~= nil
        and h.tracker.boss_position:x() == 210, 'boss state wiped')
    assert(h.count('reset', 'arkham_asylum', function(c) return c.t >= before.trip_at end) == 0,
        'Arkham reset Batmobile during/after the trip')
    assert(h.logged('explorer map restored') == 1, 'Batmobile restores the pit map\n' .. h.dump())
    local vk, vt = kept(before.visited, ex.visited)
    assert(vk == vt, string.format('visited cells restored (%d of %d)', vk, vt))
    -- Live frontiers away from the return point (outside this frame's scan
    -- and eviction box; stale ones already visited are dropped lazily by
    -- the selector) are exactly the ones mapped before the trip.
    local far, far_kept = 0, 0
    for key, node in pairs(before.frontier) do
        if before.visited[key] == nil
            and math.max(math.abs(node:x() - h.pos:x()), math.abs(node:y() - h.pos:y())) > 30
        then
            far = far + 1
            if ex.frontier[key] ~= nil then far_kept = far_kept + 1 end
        end
    end
    assert(far > 0 and far_kept == far, string.format('pit frontiers restored (%d of %d)', far_kept, far))
    -- exploring continues from the restored map (never from an empty one)
    local low = ex.visited_count
    h.run_for(10, function() if ex.visited_count < low then low = ex.visited_count end end)
    assert(low >= before.visited_count, string.format('explorer map wiped after the resume (%d < %d)',
        low, before.visited_count))
    assert(h.task() == 'explore_pit', 'Arkham explores again: ' .. h.task())
    assert(h.logged('world changed') == 2, 'exactly the two world transitions reset per-visit state')
end

-------------------------------------------------------------------------------
-- R10: pit floor explored -> Alfred with-teleport trip -> same pit world.
for _, order in ipairs({'arkham_first', 'batmobile_first'}) do
    test('R10 same pit after an Alfred with-teleport trip: run resumes and Batmobile map restored (' .. order .. ')',
        function()
            local h = world({batmobile_first = order == 'batmobile_first'})
            local before = explore_then_trip(h)
            run_trip(h)
            assert(h.trip.phase == 'done', 'Alfred trip finished: ' .. tostring(h.trip.phase))
            assert_resumed(h, before)
            assert(#h.waypoints == 0, 'Arkham teleported during the trip')
        end)
end

-- Arkham-side gap: Alfred's callback lands in town before its return portal
-- (the order is not verified live, HRD-5). Until the return, Arkham must not
-- walk to the obelisk (Temis), teleport to its town (elsewhere) or reset
-- Batmobile, which cancels the return and drops the cached pit map.
for _, town in ipairs({TEMIS, KYOVASHAD}) do
    test('R10 callback before the return portal (' .. town.zone .. '): Arkham holds, Alfred returns, run and map resume',
        function()
            local h = world({town = town, callback_first = true})
            h.actors = {} -- obelisk / pit portal come from settings.town_pit_tower_pos in Temis
            local before = explore_then_trip(h)
            local statuses = {}
            run_trip(h, function()
                if h.trip.callback_at and h.place == town then statuses[#statuses + 1] = h.api.get_status() end
            end)
            local cb_at = h.trip.callback_at
            assert(cb_at ~= nil, 'callback fired in town')
            local function in_town(c) return c.place == town end
            local town_calls = h.count('set_target', 'arkham_asylum', in_town)
                + h.count('navigate_long_path', 'arkham_asylum', in_town) + h.count('move', 'arkham_asylum', in_town)
            assert(town_calls == 0, 'Arkham drove Batmobile in town during Alfred\'s return: ' .. town_calls)
            assert(h.count('reset', 'arkham_asylum', in_town) == 0,
                'Arkham reset Batmobile in town (drops the pit map kept for the return)')
            for _, r in ipairs(h.requests) do
                assert(r.alfred or r.place ~= town or r.t < cb_at, 'Arkham moved the player in town after the callback')
            end
            assert(#h.waypoints == 0, 'Arkham teleported away from Alfred\'s return portal')
            assert(h.pit_opens == 0, 'Arkham opened a new pit during the return')
            assert(#statuses > 0 and statuses[1].alfred_trip == true and statuses[1].in_run == true,
                'C2: the own trip is reported until back in the pit')
            local shown = false
            for _, st in ipairs(statuses) do
                if st.task:find('return to the pit', 1, true) then shown = true end
            end
            assert(shown, 'the hold is visible in the status')
            assert(h.logged('holding up to') == 1, 'the hold is logged once')
            assert(h.trip.phase == 'done', 'Alfred returned to the pit: ' .. tostring(h.trip.phase) .. '\n' .. h.dump())
            assert_resumed(h, before)
            assert(h.api.get_status().alfred_trip == false, 'trip ends back in the pit')
        end)
end

-- C6 bound: an Alfred that never takes its return portal holds Arkham only
-- for the return window, then Arkham continues in town (logged).
test('R10 callback in town without a return: bounded hold, then Arkham continues in town', function()
    local h = world({town = KYOVASHAD, callback_first = true})
    explore_then_trip(h, 8)
    local guard = h.now + 30
    while h.trip.callback_at == nil and h.now < guard do h.frame() end
    local cb_at = assert(h.trip.callback_at, 'callback fired in town')
    h.trip.phase = 'stalled' -- Alfred never takes its return portal
    local held_until = nil
    h.run_for(40, function()
        if held_until == nil and h.task() ~= 'alfred_running' then held_until = h.now end
    end)
    assert(held_until ~= nil, 'hold never ended')
    assert(held_until - cb_at >= 25, string.format('no hold for the return (Arkham took over %.1fs after the callback)',
        held_until - cb_at))
    assert(held_until - cb_at <= 31, string.format('hold not bounded (%.1fs)', held_until - cb_at))
    assert(h.logged('did not return to the pit within') == 1, 'the expiry is logged once\n' .. h.dump())
    assert(#h.waypoints >= 1 and h.waypoints[1].t >= held_until, 'Arkham heads back to its town after the bound')
    assert(h.api.get_status().alfred_trip == false, 'trip no longer reported')
end)

test('R10 a failed Alfred return ends the hold at once', function()
    local h = world({town = KYOVASHAD, callback_first = true})
    explore_then_trip(h, 8)
    local guard = h.now + 30
    while h.trip.callback_at == nil and h.now < guard do h.frame() end
    h.run_for(1)
    assert(h.place == KYOVASHAD and h.task() == 'alfred_running' and #h.waypoints == 0, 'holding for the return')
    h.trip.phase = 'stalled'
    h.alfred.teleport_failed = true
    h.run_for(1)
    assert(h.logged('return to the pit failed') == 1, 'failed return is logged')
    assert(h.task() ~= 'alfred_running', 'a failed return must not hold Arkham')
end)

-- Arkham-side gap: the back-portal blacklist of a floor reached through a
-- portal was dropped by the trip, so the resumed floor walked back up
-- through the portal it arrived by (real Batmobile drives the approach).
test('R10 resumed floor reached through a portal keeps its back portal blacklisted', function()
    local h = world({start = ENTRY})
    h.api.enable()
    local guard = h.now + 20
    while h.place ~= DEEP and h.now < guard do h.frame() end
    assert(h.place == DEEP, 'descended through the entry floor portal\n' .. h.dump())
    h.run_for(2)
    assert(h.logged('back-portal blacklisted') == 1, 'arrival back portal blacklisted\n' .. h.dump())
    local back = DEEP.actors[1]
    h.floor_loot = true
    h.alfred.need_trigger, h.alfred.inventory_full = true, true
    local before = {pit_start = h.tracker.pit_start_time}
    guard = h.now + 4
    while #h.alfred.triggers == 0 and h.now < guard do h.frame() end
    assert(#h.alfred.triggers == 1 and h.alfred.triggers[1].teleport, 'with-teleport trip soon after arriving')
    assert(h.pos:dist_to(back.pos) < 22, 'trip starts within the portal detection radius of the back portal')
    h.interactions = {}
    run_trip(h)
    assert(h.trip.phase == 'done' and h.place == DEEP, 'Alfred returned to the deep floor')
    assert(h.logged('resuming the run') == 1 and h.tracker.pit_start_time == before.pit_start, 'run resumed')
    assert(h.logged('explorer map restored') == 1, 'Batmobile restores the floor map')
    h.run_for(12)
    local used_back = 0
    for _, i in ipairs(h.interactions) do if i.actor == back then used_back = used_back + 1 end end
    assert(used_back == 0 and h.place == DEEP,
        'resumed floor walked back up through its arrival portal (now on ' .. tostring(h.place.name) .. ')')
    assert(h.logged('back-portal blacklist near') == 1, 'kept blacklist is logged')
    assert(h.task() == 'explore_pit', 'Arkham explores the resumed floor: ' .. h.task())
end)

if #failures > 0 then
    error(#failures .. ' Arkham+Batmobile joint regression(s) failed:\n' .. table.concat(failures, '\n'))
end
print('PASS: Arkham+Batmobile joint: ' .. checks .. ' regressions passed')
