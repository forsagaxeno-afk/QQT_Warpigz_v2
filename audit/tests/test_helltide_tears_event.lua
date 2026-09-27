-- QQT_Warpigz_v3 (rc.2, Q3): "when farming tears, running after the loot is
-- dumb - loot once the whole event is over (the Realmwalker killed, or no
-- Realmwalker within 10 seconds after the rift completes)".
-- These cases drive the real HelltideRevamped main.lua / tasks/helltide.lua /
-- core/hr_tear_event.lua / hr_tear_stand.lua / hr_tear_loot.lua (Farm mode,
-- standalone: HR + a Rosie-shaped Looter + Batmobile, no WarPigs) through a
-- Surging or Normal rupture with two golden tears, drops from the fight and
-- a Realmwalker. The Looter walks the player to any accepted drop within its
-- pickup distance unless someone paused it (as Rosie does).
-- Runs under Lua 5.4 and LuaJIT.
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
local last_session
local function case(name, fn)
    cases = cases + 1
    last_session = nil
    local passed, err = pcall(fn)
    if passed then
        print('PASS Helltide tear event: ' .. name)
    else
        failures[#failures + 1] = name .. ': ' .. tostring(err)
        print('FAIL Helltide tear event: ' .. name .. ': ' .. tostring(err))
        local logs = last_session and last_session.logs or {}
        for i = math.max(1, #logs - 30), #logs do print('    | ' .. logs[i]) end
    end
end

local Vec = {}; Vec.__index = Vec
function Vec:new(x, y, z) return setmetatable({xx = x or 0, yy = y or 0, zz = z or 0}, self) end
function Vec:x() return self.xx end
function Vec:y() return self.yy end
function Vec:z() return self.zz end
function Vec:dist_to(o) return math.sqrt((self.xx - o:x())^2 + (self.yy - o:y())^2 + (self.zz - o:z())^2) end
function Vec:dist_to_ignore_z(o) return math.sqrt((self.xx - o:x())^2 + (self.yy - o:y())^2) end
local function v(x, y, z) return Vec:new(x, y, z) end

local PROGRESS = 2
local next_id = 9000
local function actor(skin, x, y, opts)
    opts = opts or {}
    next_id = next_id + 1
    local a = {skin = skin, pos = v(x, y, 0), interactable = opts.interactable ~= false, hp = opts.hp,
        id = next_id, progress = opts.progress}
    function a:get_skin_name() return self.skin end
    function a:get_position() return self.pos end
    function a:is_interactable() return self.interactable end
    function a:get_id() return self.id end
    if opts.hp then function a:get_current_health() return self.hp end end
    function a:get_attribute(k) if k == PROGRESS then return self.progress or 0 end return 0 end
    return a
end
local function item(x, y)
    next_id = next_id + 1
    local it = {pos = v(x, y, 0), id = next_id}
    function it:get_position() return self.pos end
    function it:get_id() return self.id end
    return it
end

local SKIN = {
    surging = 'S14_Rupture_LE_SwitchGizmo',
    normal = 'S14_Rupture_SMP_SwitchGizmo',
    hold = 'S14_PandemoniumCrack_gizmo_holdArea',
    glint = 'S14_Rupture_SMP_Chargeable',
    realmwalker = 'S14_Golem_Stone_Realmwalker',
}
local HELLTIDE_BUFF = 1066539
local SPEED, CIRCLE = 7, 2.5

-- opts.range: the Looter's pickup distance (default 12 m).
-- opts.rw: 'spawn' (3 s after completion, dies after 8 s within 15 m),
--          'late' (spawns 14 s after completion), 'immortal', nil (never).
local function session(opts)
    opts = opts or {}
    local s = {now = 100, minute = 10, pos = v(0, 0, 0), zone = 'Test_Zone', in_helltide = true,
        helltide_active = true, cinders = 311, actors = {}, logs = {}, interactions = {}, states = {},
        dead = false, pauses = {}, tears = {}, drops = {}, picked = 0, picked_early = 0, steer_early = 0,
        closed = 0, range = opts.range or 12, acquires = 0, refuse = {}, unwanted = {}}
    local bm = {target = nil}
    local player = {
        get_position = function() return s.pos end, get_current_speed = function() return 0 end,
        is_dead = function() return s.dead end, get_item_count = function() return s.picked end,
        get_consumable_items = function() return {} end, get_attribute = function() return 0 end,
        get_buffs = function() return s.in_helltide and {{name_hash = HELLTIDE_BUFF}} or {} end,
    }
    local world = {get_name = function() return s.world_name or 'Sanctuary_Eastern_Continent' end,
        get_current_zone_name = function() return s.zone end, get_world_id = function() return 1 end}
    local env = setmetatable({}, {__index = _G})
    env._G = env
    env.vec3 = Vec
    env.get_time_since_inject = function() return s.now end
    env.get_helltide_coin_cinders = function() return s.cinders end
    env.get_player_position = function() return s.pos end
    env.get_local_player = function() return player end
    env.get_current_world = function() return world end
    env.on_render = function() end
    env.on_render_menu = function() end
    env.on_update = function(fn) s.update = fn end
    env.console = {print = function(line) s.logs[#s.logs + 1] = string.format('%.1f %s', s.now, tostring(line)) end}
    env.target_selector = {get_near_target_list = function() return {} end}
    env.actors_manager = {get_all_actors = function() return s.actors end, get_enemy_actors = function() return {} end,
        get_all_items = function() return s.drops end}
    env.loot_manager = {get_all_items_chest_sort_by_distance = function() return {} end,
        any_item_around = function() return false end}
    env.utility = {set_height_of_valid_position = function(p) return p end, is_point_walkeable = function() return true end}
    env.pathfinder = {request_move = function() end, clear_stored_path = function() end}
    env.teleport_to_waypoint = function() end
    env.interact_object = function(a) s.interactions[#s.interactions + 1] = a end
    env.revive_at_checkpoint = function() end
    env.attributes = {PLAYER_IN_TOWN_LEVEL_AREA = 1, CHARGEABLE_GIZMO_PROGRESS = PROGRESS, GIZMO_HAS_BEEN_OPERATED = 3}
    env.orbwalker = {set_clear_toggle = function() end, set_block_movement = function() end}
    env.os = setmetatable({date = function(fmt, ...)
        if fmt == '%M' or fmt == '!%M' then return string.format('%02d', s.minute) end
        if fmt == '!%S' then return '00' end
        return os.date(fmt, ...)
    end}, {__index = os})
    env.BatmobilePlugin = {
        pause = function() end, resume = function() end,
        set_target = function(_, t) bm.target = t; return true end,
        clear_target = function() bm.target = nil end, stop_long_path = function() end,
        update = function() end, move = function() end, is_paused = function() return false end,
        is_done = function() return false end, reset = function() bm.target = nil end,
        reset_movement = function() bm.target = nil end,
        get_target = function() local t = bm.target; return t and (t.get_position and t:get_position() or t) end,
        clear_giving_up = function() end, is_giving_up = function() return false end,
        navigate_long_path = function() return true end, is_long_path_navigating = function() return false end,
        get_closeby_node = function(_, p) return p end, clear_traversal_blacklist = function() end,
        release = function() bm.target = nil end,
    }
    -- Rosie-shaped Looter: the nearest accepted drop within its distance,
    -- unless paused (a refused drop is accepted by evaluate_item but never taken).
    local function wanted()
        if next(s.pauses) ~= nil or s.looter_off then return nil end
        local best, bd = nil, math.huge
        for _, d in ipairs(s.drops) do
            local dd = s.pos:dist_to(d.pos)
            if dd <= s.range and dd < bd and not s.refuse[d] and not s.unwanted[d] then best, bd = d, dd end
        end
        return best
    end
    env.LooteerPlugin = {get_enabled = function() return not s.looter_off end,
        is_actively_looting = function() return wanted() ~= nil end,
        evaluate_item = function(it) return not s.unwanted[it] end,
        acquire_pause = function(c) s.pauses[c] = s.now; s.acquires = s.acquires + 1; return true end,
        release_pause = function(c) s.pauses[c] = nil; return true end}
    local function control(value)
        return {value = value, get = function(self) return self.value end, set = function(self, n) self.value = n end}
    end
    local controls = setmetatable({}, {__index = function(t, k) local c = control(false); rawset(t, k, c); return c end})
    local defaults = {main_toggle = true, town = 0, helltide_chest_toggle = true,
        kill_monsters_toggle = false, kill_monsters_rarity = 0, farm_cinder_threshold = 0,
        maiden_disable_cinders = 0, mode = 1, hunt_rift_toggle = true,
        rupture_hunt_normal = true, rupture_hunt_surging = true, rupture_hunt_colossal = true,
        rupture_open_chests = true, tear_use_charge_ring = true, rupture_max_cinders = 0,
        tear_search_dist = 110, tear_passby_dist = 50, tear_event_radius = 12, tear_circle_radius = 2,
        rupture_linger_sec = 5, rupture_do_realmwalker = true, rupture_rw_wait_sec = 25}
    for k, value in pairs(defaults) do controls[k] = control(value) end
    s.controls = controls
    local noop = setmetatable({}, {__index = function() return function() end end})
    local modules = {
        gui = {elements = controls, render = function() end, mode = {'Warplan', 'Farm'},
            town_data = {[0] = {zone_name = 'Skov_Temis', waypoint_sno = 0x1CE51E}}},
        ['core.perf'] = noop, ['core.helltide_explorer'] = noop,
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
    s.utils = env.require('core.utils')
    s.utils.helltide_active = function() return s.helltide_active end
    s.tear = env.require('core.hr_tear_event')
    s.helltide = env.require('tasks.helltide')
    assert(loadfile(root .. 'main.lua', 't', env))()
    s.plugin = env.HelltideRevampedPlugin
    last_session = s

    local function step_to(target, dt)
        local d = s.pos:dist_to(target)
        if d <= 0.3 then return end
        local k = math.min(d, SPEED * dt) / d
        s.pos = v(s.pos:x() + (target:x() - s.pos:x()) * k, s.pos:y() + (target:y() - s.pos:y()) * k, 0)
    end
    local OX = opts.ox or 0 -- QQT_Warpigz_v3 (rc.2 review): the ring further out
    s.ring = v(30 + OX, 0, 0)
    s.actors = {actor(opts.starter or SKIN.surging, 30 + OX, 0), actor(SKIN.hold, 30 + OX, 0)}
    for _, p in ipairs({{36, 0}, {30, 9}}) do
        local t = actor(SKIN.glint, p[1] + OX, p[2], {progress = 0})
        t.close_s = opts.close_s or 10
        s.tears[#s.tears + 1] = t
        s.actors[#s.actors + 1] = t
    end
    local function drop(x, y) s.drops[#s.drops + 1] = item(x, y) end
    s.drop = drop
    -- The event is over for the Looter model when the Realmwalker dies, or
    -- s.over_after seconds after the rupture completed.
    function s.tick(seconds, dt)
        dt = dt or 0.1
        for _ = 1, math.floor(seconds / dt + 0.5) do
            s.now = s.now + dt
            -- the fight drops loot: every 6 s inside a tear circle 6.4 m from
            -- that tear, once at the ring after the last tear, every 3 s of
            -- the Realmwalker fight by the Realmwalker
            if s.now - (s.last_mob_drop or 0) >= 6 then
                for _, t in ipairs(s.tears) do
                    if s.pos:dist_to(t.pos) <= CIRCLE then
                        s.last_mob_drop = s.now
                        drop(t.pos:x() + 5, t.pos:y() + 4)
                        break
                    end
                end
            end
            if #s.tears == 0 and not s.ring_drop then s.ring_drop = true; drop(24 + OX, -6) end
            if s.rw and s.rw.hp > 0 and s.pos:dist_to(s.rw.pos) <= 15 and s.now - (s.last_rw_drop or 0) >= 3 then
                s.last_rw_drop = s.now
                drop(s.rw.pos:x() - 4, s.rw.pos:y() + 3)
            end
            local it = wanted()
            if it then
                if not s.event_over then s.steer_early = s.steer_early + dt end
                if s.pos:dist_to(it.pos) > 0.5 then step_to(it.pos, dt) else
                    for i, d in ipairs(s.drops) do if d == it then table.remove(s.drops, i) break end end
                    s.picked = s.picked + 1
                    if not s.event_over then s.picked_early = s.picked_early + 1 end
                end
            elseif bm.target and not s.frozen then
                step_to(bm.target.get_position and bm.target:get_position() or bm.target, dt)
            end
            for i = #s.tears, 1, -1 do
                local t = s.tears[i]
                if s.pos:dist_to(t.pos) <= CIRCLE and t.close_s then
                    t.progress = (t.progress or 0) + dt / t.close_s
                    if t.progress >= 1 then
                        s.closed = s.closed + 1
                        table.remove(s.tears, i)
                        for j, a in ipairs(s.actors) do if a == t then table.remove(s.actors, j) break end end
                        drop(t.pos:x() + 4, t.pos:y() - 3) -- the tear's reward
                    end
                end
            end
            if not s.completed_at then
                for _, line in ipairs(s.logs) do
                    if line:find('rupture complete', 1, true) then s.completed_at = s.now break end
                end
            end
            local spawn_after = opts.rw == 'late' and 14 or 3
            if opts.rw and s.completed_at and not s.rw and s.now - s.completed_at >= spawn_after then
                s.rw = actor(SKIN.realmwalker, 44, 6, {hp = 100})
                s.actors[#s.actors + 1] = s.rw
            end
            if s.rw and s.rw.hp > 0 and opts.rw ~= 'immortal' and s.pos:dist_to(s.rw.pos) <= 15 then
                s.rw.hp = s.rw.hp - 100 / (opts.rw_kill_s or 8) * dt
                if s.rw.hp <= 1 then -- QQT_Warpigz_v3: HR reads hp <= 1 as dead
                    s.rw.hp = 0
                    for j, a in ipairs(s.actors) do if a == s.rw then table.remove(s.actors, j) break end end
                    drop(s.rw.pos:x() + 2, s.rw.pos:y() + 2)
                    drop(s.rw.pos:x() - 3, s.rw.pos:y() + 1)
                    s.event_over, s.event_over_at = true, s.now
                end
            end
            if s.over_after and s.completed_at and not s.event_over and s.now - s.completed_at >= s.over_after then
                s.event_over, s.event_over_at = true, s.now
            end
            if s.before_tick then s.before_tick() end
            s.update()
            local st = s.helltide.current_state
            s.states[st] = true
            if s.pauses.HelltideRevamped and not s.first_pause then
                s.first_pause, s.first_pause_d = s.now, s.pos:dist_to(s.ring)
            end
            if s.event_over and not s.left_at and not s.tear.is_rift_state(st) then
                s.left_at, s.left_drops = s.now, #s.drops
            end
        end
    end
    function s.logged(pattern)
        local n = 0
        for _, line in ipairs(s.logs) do if line:find(pattern, 1, true) then n = n + 1 end end
        return n
    end
    function s.run_until(pred, max_s)
        local t0 = s.now
        while s.now - t0 < max_s do
            s.tick(0.1)
            if pred() then return true end
        end
        return false
    end
    return s
end

-- ── the pause lasts until the whole event is over ─────────────────────────
case('Q3 Surging + Realmwalker: no looting until it dies, then every drop is collected before HR moves on', function()
    local s = session({rw = 'spawn'})
    local released_at
    s.before_tick = function()
        if s.completed_at and not released_at and s.pauses.HelltideRevamped == nil then released_at = s.now end
    end
    s.tick(150)
    eq(s.closed, 2, 'both tears closed')
    eq(s.logged('[RIFT] Realmwalker defeated'), 1, 'Realmwalker fought and killed')
    -- QQT_Warpigz_v3 (rc.2 review): on arrival at the ring (r + 10), not
    -- from where its open tears were first seen (30 m out here).
    ok(s.first_pause and s.first_pause - 100 < 3, 'pickup paused on arrival at the rupture')
    ok(s.first_pause_d <= 12 + 10 + 0.5, string.format('not before the ring was reached (%.1f m)', s.first_pause_d))
    eq(s.picked_early, 0, 'no drop taken before the Realmwalker died')
    ok(s.steer_early < 0.05, string.format('the Looter never moved the player during the event (%.1fs)', s.steer_early))
    ok(released_at and released_at >= s.event_over_at, 'released only once the Realmwalker died')
    eq(s.logged('Looter pickup resumed (tear event over: Realmwalker defeated)'), 1, 'one resume line with the reason')
    eq(s.logged('Pausing Looter pickup until the tear event is over'), 1, 'one pause line for the whole event')
    ok(s.picked >= 10, 'the event drops were taken after it: ' .. s.picked)
    eq(s.left_drops, 0, 'no drop left behind when HR resumed patrol')
    eq(s.logged('Tear event over (Realmwalker defeated) — collecting its loot'), 1, 'loot window logged once')
    eq(s.logged('Tear event loot:'), 1, 'loot window summary logged once')
    ok(s.acquires <= 12, 'pause refreshed about every 5 s, not every tick: ' .. s.acquires)
end)

case('Q3 Surging, no Realmwalker: the pause ends 10 s after the rupture completed, then the loot is collected', function()
    local s = session({rw = nil})
    s.over_after = 10
    local released_at
    s.before_tick = function()
        if s.completed_at and not released_at and s.pauses.HelltideRevamped == nil then released_at = s.now end
    end
    s.tick(150)
    eq(s.closed, 2, 'both tears closed')
    ok(s.completed_at, 'rupture completed')
    ok(released_at, 'released')
    local after = released_at - s.completed_at
    ok(after >= 9.9 and after <= 11, string.format('released %.1fs after completion (10 s expected)', after))
    eq(s.picked_early, 0, 'no drop taken during the event')
    eq(s.logged('Looter pickup resumed (tear event over: no Realmwalker within 10s)'), 1, 'resume reason logged')
    eq(s.left_drops, 0, 'every drop collected before HR left')
    ok(s.logged('Realmwalker wait timed out') == 1, 'the Realmwalker wait itself is unchanged (slider)')
end)

case('Q3 Normal rupture (no Realmwalker chain): paused until it completes, then collected', function()
    local s = session({starter = SKIN.normal})
    s.over_after = 0
    s.tick(100)
    eq(s.closed, 2, 'both tears closed')
    eq(s.picked_early, 0, 'no drop taken before the rupture completed')
    eq(s.logged('Looter pickup resumed (tear event over: rupture complete)'), 1, 'resume reason logged')
    eq(s.left_drops, 0, 'every drop collected before HR left')
    eq(s.logged('Normal rupture complete — resuming patrol'), 1, 'completed once (no second linger after the loot walk)')
end)

case('Q3 a small pickup distance: HR walks to each drop the Looter wants before it leaves', function()
    local s = session({rw = 'spawn', range = 3})
    s.tick(150)
    eq(s.picked_early, 0, 'no drop taken during the event')
    ok(s.picked >= 10, 'drops taken after the event: ' .. s.picked)
    eq(s.left_drops, 0, 'no drop left behind (tears, ring and Realmwalker drops are metres apart)')
end)

case('Q3 a Realmwalker that shows up after the 10 s gates its fight again', function()
    local s = session({rw = 'late'})
    local paused_in_fight, looted_in_fight = false, false
    s.before_tick = function()
        if s.rw and s.rw.hp > 0 and s.helltide.current_state == 'RIFT_KILL_REALMWALKER' then
            if s.pauses.HelltideRevamped then paused_in_fight = true end
        end
    end
    s.tick(160)
    ok(s.logged('Tear event over (no Realmwalker within 10s)') == 1, 'first window after 10 s without it')
    eq(s.logged('[RIFT] Realmwalker defeated'), 1, 'the late Realmwalker was fought')
    ok(paused_in_fight, 'pickup paused again during its fight')
    eq(s.logged('Tear event over (Realmwalker defeated)'), 1, 'a second window after it died')
    eq(#s.drops, 0, 'its drops collected too')
end)

-- ── C6: bounded and released on every exit ─────────────────────────────────
case('Q3/C6 the pause is released on disable, death, Warplan, reset, zone change, Helltide end and WarPigs enable', function()
    local function mid_event(opts)
        local s = session(opts or {rw = 'immortal'})
        ok(s.run_until(function() return s.helltide.current_state == 'RIFT_WAIT_REALMWALKER' end, 60), 'waiting for the Realmwalker')
        ok(s.pauses.HelltideRevamped ~= nil, 'paused between the tears and the Realmwalker')
        return s
    end
    local s = mid_event()
    s.controls.main_toggle:set(false)
    s.tick(0.5)
    eq(s.pauses.HelltideRevamped, nil, 'disable (menu) releases')
    s = mid_event()
    s.plugin.disable()
    s.tick(0.2)
    eq(s.pauses.HelltideRevamped, nil, 'disable() (WarPigs switching activity) releases')
    s = mid_event()
    s.dead = true
    s.tick(0.5)
    eq(s.pauses.HelltideRevamped, nil, 'death releases')
    s = mid_event()
    s.controls.mode:set(0)
    s.tick(0.5)
    eq(s.pauses.HelltideRevamped, nil, 'Warplan releases')
    s = mid_event()
    s.plugin.enable() -- WarPigs takes an HR that is farming a rupture: Warplan
    s.tick(0.5)
    eq(s.pauses.HelltideRevamped, nil, 'WarPigs enable (Warplan) releases')
    -- (Rosie takes the drops in range first: HR's Looter hold yields to her)
    ok(s.run_until(function() return not s.tear.is_rift_state(s.helltide.current_state) end, 20),
        'and leaves the rupture: ' .. tostring(s.helltide.current_state))
    s = mid_event()
    s.helltide:reset()
    eq(s.pauses.HelltideRevamped, nil, 'reset releases')
    s = mid_event()
    s.in_helltide = false -- walked/teleported out of the zone, hour still on
    s.tick(0.5)
    eq(s.pauses.HelltideRevamped, nil, 'leaving the zone releases')
    s = mid_event()
    s.in_helltide, s.helltide_active = false, false -- the Helltide ended
    s.tick(20)
    eq(s.pauses.HelltideRevamped, nil, 'Helltide end releases')
end)

case('Q3/C6 a reloaded HR drops the pause its previous load held', function()
    local s = session({rw = 'immortal'})
    ok(s.run_until(function() return s.pauses.HelltideRevamped ~= nil end, 10), 'paused')
    -- A script reload runs every module again: the new hr_tear_stand holds nothing.
    assert(loadfile(root .. 'core/hr_tear_stand.lua', 't', s.env))()
    eq(s.pauses.HelltideRevamped, nil, 'the stale pause is released at load')
end)

case('Q3/C6 an endless event is capped: the pause never outlasts 300 s', function()
    local s = session({rw = 'immortal'})
    local longest, since = 0, nil
    s.before_tick = function()
        if s.pauses.HelltideRevamped then
            since = since or s.now
            if s.now - since > longest then longest = s.now - since end
        else
            since = nil
        end
    end
    -- QQT_Warpigz_v3 (rc.2 review): the Realmwalker chain has its own bound
    -- (180 s); the abandoned area is engaged again once its blacklist expires.
    ok(s.run_until(function() return s.logged('took longer than') > 0 end, 420), 'the rupture was capped')
    eq(s.logged('Realmwalker chain took longer than 180s'), 1, 'the immortal Realmwalker ended by the chain cap')
    eq(s.logged('Realmwalker chain still running after 180s — Looter pickup resumes (pause cap)'), 1, 'pause cap logged once')
    s.tick(0.5)
    ok(longest <= 300.5, string.format('pause held at most 300 s (%.1fs)', longest))
    eq(s.pauses.HelltideRevamped, nil, 'released')
end)

case('Q3/C6 the gate itself expires after 300 s of wall time (yields included)', function()
    local s = session()
    local loot = s.env.require('core.hr_tear_loot')
    local sess = {}
    eq(loot.gate_wants(sess, 'MOVING_TO_RIFT', 10), false, 'not while walking to the rupture')
    eq(loot.gate_wants(sess, 'RIFT_CLOSE_TEARS', 11), true, 'opened at the rupture')
    loot.credit(sess, 500) -- a yield is credited to the timers, never to the cap
    eq(loot.gate_wants(sess, 'RIFT_STAY_ACTIVE', 310), true, 'still on at 299 s')
    eq(loot.gate_wants(sess, 'RIFT_STAY_ACTIVE', 311), false, 'expired at 300 s')
    eq(loot.gate_wants(sess, 'RIFT_KILL_REALMWALKER', 312), false, 'stays expired')
    eq(s.logged('pause cap'), 1, 'cap logged once')
    eq(loot.gate_wants({}, 'CHAMBER_CLOSE_TEARS', 5), false, 'the Deathtoll Chamber is not gated')
end)

case('Q3/C6 the loot window is bounded: a drop the Looter refuses or cannot reach is left', function()
    local s = session({starter = SKIN.normal})
    s.over_after = 0
    ok(s.run_until(function() return s.completed_at ~= nil end, 80), 'rupture completed')
    local refused = item(s.pos:x() + 14, s.pos:y())
    s.refuse[refused] = true
    s.drops[#s.drops + 1] = refused
    local w0 = s.now
    ok(s.run_until(function() return s.logged('Tear event loot:') > 0 end, 50), 'window finished')
    ok(s.logged(', 1 given up,') == 1, 'the refused drop was given up once it was reached')
    ok(s.now - w0 <= 20, string.format('without waiting for the window cap (%.1fs)', s.now - w0))
    ok(s.run_until(function() return not s.tear.is_rift_state(s.helltide.current_state) end, 5), 'HR moved on')
    eq(#s.drops, 1, 'only the refused drop is left')
    local t = session({starter = SKIN.normal})
    t.over_after = 0
    ok(t.run_until(function() return t.completed_at ~= nil end, 80), 'rupture completed')
    t.drops[#t.drops + 1] = item(t.pos:x() + 20, t.pos:y() + 5)
    t.frozen = true -- Batmobile cannot get there
    local t0 = t.now
    ok(t.run_until(function() return t.logged('Tear event loot:') > 0 end, 60), 'window finished')
    ok(t.logged('no progress towards it for 5s') >= 1, 'unreachable drop given up')
    ok(t.now - t0 <= 46, string.format('window bounded (%.1fs)', t.now - t0))
end)

case('Q3 no Rosie-shaped Looter pickup (off): no pause is held and no loot walk runs', function()
    local s = session({rw = 'spawn'})
    s.looter_off = true
    s.env.LooteerPlugin.acquire_pause = function() return false end
    s.tick(150)
    eq(s.logged('collecting its loot'), 0, 'no loot window')
    eq(s.logged('[RIFT] Realmwalker defeated'), 1, 'the event itself runs as before')
end)

-- ── QQT_Warpigz_v3 (rc.2 review): the pause holds only at the event ────────
case('review: a rupture whose tears are open is engaged from far away: the walk there is not paused, its drops are taken', function()
    -- The ring is 100 m out and its tears are already open: HR engages it
    -- (RIFT_CLOSE_TEARS) at once. Monsters killed on the walk drop loot
    -- 44 m and 59 m before the ring (outside the post-event loot area).
    local s = session({starter = SKIN.normal, ox = 70})
    s.over_after = 0
    local walk_drops, paused_far = {}, false
    s.before_tick = function()
        if s.pauses.HelltideRevamped and s.pos:dist_to(s.ring) > 12 + 10 + 0.5 then paused_far = true end
        for _, x in ipairs({40, 55}) do
            if not walk_drops[x] and s.pos:x() >= x then
                walk_drops[x] = item(x + 1, 2)
                s.drops[#s.drops + 1] = walk_drops[x]
            end
        end
    end
    s.tick(160)
    eq(s.closed, 2, 'both tears closed')
    ok(s.logged('Found ritual ring at dist=100.0') == 1, 'engaged from 100 m')
    eq(paused_far, false, string.format('never paused on the walk (first pause %.1f m from the ring)', s.first_pause_d or -1))
    for _, x in ipairs({40, 55}) do
        for _, d in ipairs(s.drops) do ok(d ~= walk_drops[x], 'the drop passed at x=' .. x .. ' was taken on the way') end
    end
    eq(s.left_drops, 0, 'no drop left when HR resumed patrol')
    eq(s.logged('Pausing Looter pickup until the tear event is over'), 1, 'one pause line')
end)

case('review: a finished loot window resumes patrol where it ends (no walk back to the ring)', function()
    local s = session({starter = SKIN.normal})
    s.over_after = 0
    local far
    s.before_tick = function()
        -- a kill 38 m from the ring during the event (Rosie paused, 12 m range)
        if not far and s.closed >= 1 then far = item(-8, 3); s.drops[#s.drops + 1] = far end
    end
    ok(s.run_until(function() return s.logged('Tear event loot:') > 0 end, 120), 'loot window finished')
    for _, d in ipairs(s.drops) do ok(d ~= far, 'the far drop was walked to') end
    s.tick(4)
    eq(s.logged('Outside rupture bubble'), 0, 'no walk back to the ring after the window')
    eq(s.logged('Normal rupture complete — resuming patrol'), 1, 'resumed patrol right away')
    ok(s.pos:dist_to(s.ring) > 30, string.format('still where the window ended (%.1f m from the ring)', s.pos:dist_to(s.ring)))
end)

case('review: a revive walk-back is not paused; a drop passed on the way back is taken', function()
    local s = session({starter = SKIN.normal})
    s.over_after = 0
    ok(s.run_until(function()
        local f = s.tear.session().focus_tear
        return f and s.pos:dist_to(f.pos) <= 1.05
    end, 20), 'standing in the first tear')
    s.tick(2)
    ok(s.pauses.HelltideRevamped ~= nil, 'paused in the tear')
    s.dead = true
    s.tick(1.5)
    eq(s.pauses.HelltideRevamped, nil, 'death releases')
    s.dead = false
    s.pos = v(-60, 0, 0) -- the checkpoint, 90 m from the ring
    local back = item(-25, 2) -- a kill on the way back, 55 m from the ring
    s.drops[#s.drops + 1] = back
    local paused_far = false
    s.before_tick = function()
        if s.pauses.HelltideRevamped and s.pos:dist_to(s.ring) > 12 + 32 + 4 + 0.5 then paused_far = true end
    end
    s.tick(100)
    eq(paused_far, false, 'not paused while walking back from the checkpoint')
    for _, d in ipairs(s.drops) do ok(d ~= back, 'the drop passed on the way back was taken') end
    eq(s.closed, 2, 'both tears closed after the revive')
    eq(s.logged('Pausing Looter pickup until the tear event is over'), 2, 'paused again once back at the rupture')
end)

case('review: after a teleport out mid-event the town tick never takes the pause again', function()
    local s = session({rw = 'immortal'})
    ok(s.run_until(function() return s.helltide.current_state == 'RIFT_WAIT_REALMWALKER' end, 60), 'waiting for the Realmwalker')
    ok(s.pauses.HelltideRevamped ~= nil, 'paused')
    -- the teleport: a loading screen (the task is suspended, the pause given
    -- back), then the town: no Helltide buff, the rupture state still set
    -- (town coordinates can fall anywhere: here on the ring's own)
    s.world_name, s.in_helltide, s.zone, s.pos = 'Limbo', false, 'Skov_Temis', v(30, 4, 0)
    s.tick(1)
    eq(s.pauses.HelltideRevamped, nil, 'released on the loading screen')
    local lines = s.logged('Pausing Looter pickup')
    s.world_name = nil
    s.tick(1)
    eq(s.logged('Pausing Looter pickup'), lines, 'no pause line in town')
    eq(s.pauses.HelltideRevamped, nil, 'not paused in town')
end)

case('review: suspend without reset (loading screen) releases the pause', function()
    local s = session({rw = 'immortal'})
    ok(s.run_until(function() return s.helltide.current_state == 'RIFT_WAIT_REALMWALKER' end, 60), 'waiting for the Realmwalker')
    ok(s.pauses.HelltideRevamped ~= nil, 'paused between the tears and the Realmwalker')
    s.world_name = 'Limbo' -- main_pulse suspends the task every tick, no reset
    s.tick(5)
    eq(s.pauses.HelltideRevamped, nil, 'loading screen (suspend) releases')
end)

-- ── QQT_Warpigz_v3 (rc.2 review): the Realmwalker chain has its own bound ──
case('review: long tears (85 s each) leave the Realmwalker fight its own bound; the loot is collected after it', function()
    local s = session({rw = 'spawn', close_s = 85, rw_kill_s = 130})
    ok(s.run_until(function() return s.left_at ~= nil end, 420), 'HR left the rupture')
    eq(s.closed, 2, 'both tears closed after 85 s each')
    eq(s.logged('took longer than'), 0, 'not cut off by a cap')
    eq(s.logged('[RIFT] Realmwalker defeated'), 1, 'the Realmwalker was killed')
    ok(s.event_over_at - 100 > 300, string.format('the whole event ran past the old 300 s cap (%.0fs)', s.event_over_at - 100))
    eq(s.logged('Tear event over (Realmwalker defeated)'), 1, 'loot pass after the kill')
    eq(s.picked_early, 0, 'no drop taken during the event')
    eq(s.left_drops, 0, 'every event drop collected')
    eq(s.logged('pause cap'), 0, 'the pause was not capped mid-fight')
end)

case('review: the Realmwalker chain bound and the gate phases (unit)', function()
    local s = session()
    local loot = s.env.require('core.hr_tear_loot')
    local g = {}
    eq(loot.gate_wants(g, 'RIFT_CLOSE_TEARS', 0), true, 'opened')
    eq(loot.gate_wants(g, 'RIFT_STAY_ACTIVE', 290), true, 'tears: 290 s')
    loot.rw_chain(g, 295)
    eq(loot.gate_wants(g, 'RIFT_KILL_REALMWALKER', 400), true, 'the chain restarts the clock (105 s into it)')
    eq(loot.gate_wants(g, 'RIFT_KILL_REALMWALKER', 474), true, '179 s into the chain')
    eq(loot.gate_wants(g, 'RIFT_KILL_REALMWALKER', 475), false, 'capped at RW_CHAIN_MAX_S')
    eq(s.logged('Realmwalker chain still running after 180s'), 1, 'chain cap logged once')
    eq(s.tear.C.RW_CHAIN_MAX_S, loot.C.RW_CHAIN_MAX_S, 'one bound for the chain and its pause')
    -- at the event: opens within r + 10 of the ring, holds within r + 32 (left beyond r + 36)
    local a = {anchor = v(100, 0, 0)}
    s.pos = v(60, 0, 0)
    eq(loot.gate_wants(a, 'RIFT_CLOSE_TEARS', 1, 12, false), false, '40 m out: not opened')
    eq(a.loot_gate, nil, 'no gate yet')
    eq(loot.gate_wants(a, 'RIFT_CLOSE_TEARS', 1, 12, true), true, 'standing at an engaged tear opens it')
    s.pos = v(50, 0, 0)
    eq(loot.gate_wants(a, 'RIFT_CLOSE_TEARS', 2, 12, false), false, '50 m out, not at the tear: away')
    eq(loot.away(a), true, 'away is reported')
    s.pos = v(54, 0, 0)
    eq(loot.gate_wants(a, 'RIFT_CLOSE_TEARS', 3, 12, false), false, '46 m: still away (hysteresis)')
    s.pos = v(57, 0, 0)
    eq(loot.gate_wants(a, 'RIFT_CLOSE_TEARS', 4, 12, false), true, '43 m: back')
    s.pos = v(53, 0, 0)
    eq(loot.gate_wants(a, 'RIFT_CLOSE_TEARS', 5, 12, false), true, '47 m: kept (hysteresis)')
    a.rw_anchor = v(0, 0, 0)
    s.pos = v(10, 0, 0)
    eq(loot.gate_wants(a, 'RIFT_KILL_REALMWALKER', 6, 12, false), true, 'next to the Realmwalker far from the ring')
    eq(loot.gate_wants(a, 'RIFT_STAY_ACTIVE', 7, 12, false), false, 'but not in a tear state')
end)

-- ── QQT_Warpigz_v3 (rc.2 review): reroute and window caps ─────────────────
case('review: a reroute to a second rupture gets its own pause and loot pass', function()
    local s = session({starter = SKIN.normal})
    s.controls.rupture_do_realmwalker:set(false)
    s.settings:update_settings()
    s.actors[#s.actors + 1] = actor(SKIN.surging, 80, 0)
    s.actors[#s.actors + 1] = actor(SKIN.hold, 80, 0)
    for _, p in ipairs({{86, 0}, {80, 9}}) do
        local t = actor(SKIN.glint, p[1], p[2], {progress = 0})
        t.close_s = 10
        s.tears[#s.tears + 1] = t
        s.actors[#s.actors + 1] = t
    end
    local a_starter = s.actors[1] -- A's switch gizmo is consumed once A's ritual runs
    s.before_tick = function()
        if a_starter and s.now >= 105 then
            for j, a in ipairs(s.actors) do if a == a_starter then table.remove(s.actors, j) break end end
            a_starter = nil
        end
    end
    s.tick(80)
    local function before(pattern, t_max)
        local n = 0
        for _, line in ipairs(s.logs) do
            if line:find(pattern, 1, true) and tonumber(line:match('^(%S+)')) < t_max then n = n + 1 end
        end
        return n
    end
    eq(before('New Surging rupture elsewhere — rerouting', 180), 1, 'rerouted from A to B')
    eq(s.closed, 4, 'all four tears closed')
    eq(before('Pausing Looter pickup until the tear event is over', 180), 2, 'B gets its own event pause')
    eq(before('collecting its loot', 180), 2, 'B gets its own loot pass')
end)

case('review: the loot window ends at its caps while drops keep landing', function()
    local s = session({starter = SKIN.normal, range = 3})
    s.over_after = 0
    local over_at, last_drop
    s.before_tick = function()
        if not over_at and s.logged('collecting its loot') > 0 then over_at = s.now end
        if over_at and s.now - over_at < 150 and s.now - (last_drop or 0) >= 1.0 then
            last_drop = s.now
            s.drop((s.pos:x() < 30) and 38 or 22, (math.floor(s.now) % 2 == 0) and 3 or -3)
        end
    end
    ok(s.run_until(function() return s.logged('Tear event loot:') > 0 end, 260), 'window finished')
    local took = s.now - over_at
    ok(took <= 90.5, string.format('window bounded by its caps (45 s handler, 90 s wall): %.1fs', took))
    eq(s.logged('(time cap) — moving on'), 1, 'ended by the time cap')
end)

case('review: a tear still engaged when the gate cap fires loses the pause too', function()
    local s = session({rw = 'immortal', close_s = 60})
    ok(s.run_until(function()
        local f = s.tear.session().focus_tear
        return f and s.pos:dist_to(f.pos) <= 1.05
    end, 20), 'standing in the first tear')
    s.tick(1)
    s.tear.session().loot_gate.opened_at = s.now - 301 -- the event ran 300 s (wall)
    s.tick(0.5)
    ok(s.tear.session().tear_focus_key ~= nil, 'the tear is still engaged')
    eq(s.pauses.HelltideRevamped, nil, 'the per-tear pause ended with the cap')
    eq(s.logged('Looter pickup resumed (pause cap)'), 1, 'released once, with the reason')
end)

-- ── QQT_Warpigz_v3 (rc.2 review): loot window bounds (unit, real module) ───
local function window(opts)
    local s = session()
    local loot = s.env.require('core.hr_tear_loot')
    local w = {s = s, loot = loot, sess = {loot_gate = {held = opts.held ~= false}}, moves = 0, clears = 0}
    s.drops = {}
    s.pos = opts.pos or v(30, 0, 0)
    w.ctx = {anchor = v(30, 0, 0), radius = 52,
        move_to = function(pos) w.moves = w.moves + 1; w.target = pos end,
        clear = function() w.clears = w.clears + 1 end}
    function w.step(t) return loot.collect(w.sess, t, 'test', w.ctx) end
    return w
end

case('review: loot window bounds: per drop, dwell, refused, outside the area, nothing held, clear, credit', function()
    -- a drop approached slowly (1.1 m/s: progress, never reached) is left after ITEM_MAX_S
    local w = window({})
    local far = item(50, 0)
    w.s.drops = {far}
    local t, left_at, cleared_at_end = 0, nil, false
    while t < 20 and not left_at do
        local c0 = w.clears
        if not w.step(t) then left_at, cleared_at_end = t, w.clears > c0 end
        if t >= 1.5 then w.s.pos = v(w.s.pos:x() + 0.11, 0, 0) end
        t = t + 0.1
    end
    eq(w.s.logged('not taken within 10s'), 1, 'given up after ITEM_MAX_S')
    ok(left_at and left_at <= 12.5, 'window ended: ' .. tostring(left_at))
    ok(cleared_at_end, 'the last walk is cleared when the window ends (no stale target)')
    -- standing on a drop the Looter does not take: left after ITEM_DWELL_S
    w = window({})
    w.s.drops = {item(30.5, 0)}
    t, left_at = 0, nil
    while t < 12 and not left_at do
        if not w.step(t) then left_at = t end
        t = t + 0.1
    end
    ok(left_at and left_at <= 3.5, string.format('dwell bound (1.5 s on it), not ITEM_MAX_S: %s', tostring(left_at)))
    ok(w.s.logged(', 1 given up,') == 1, 'given up once')
    ok(w.clears >= 1, 'movement cleared at the end')
    -- refused by evaluate_item, and a wanted drop outside the event area: never walked to
    w = window({})
    local refused, outside, inside = item(40, 0), item(95, 0), item(45, 0)
    w.s.unwanted[refused] = true
    w.s.drops = {refused, outside, inside}
    local targets = {}
    t, left_at = 0, nil
    while t < 20 and not left_at do
        if not w.step(t) then left_at = t end
        if w.target then targets[string.format('%d', w.target:x())] = true; w.s.pos = w.target; w.target = nil end
        if w.s.pos:dist_to(inside.pos) < 1 then w.s.drops = {refused, outside} end -- Rosie took it
        t = t + 0.1
    end
    ok(targets['45'], 'the wanted drop in the area was walked to')
    eq(targets['40'], nil, 'a drop the Looter refuses is not walked to')
    eq(targets['95'], nil, 'a drop outside the event area is not walked to')
    ok(left_at, 'window ended')
    -- no pause was held: no window at all
    w = window({held = false})
    w.s.drops = {item(40, 0)}
    eq(w.step(0), false, 'nothing held back: no window')
    eq(w.s.logged('collecting its loot'), 0, 'no window line')
    -- a yield is credited to the window's handler-time bounds
    w = window({})
    w.s.drops = {item(80, 0)}
    eq(w.step(0), true, 'window started')
    eq(w.step(2), true, 'walking to the drop')
    w.loot.credit(w.sess, 60)
    w.s.pos = v(35, 0, 0)
    eq(w.step(62), true, 'still collecting after a 60 s yield')
    eq(w.s.logged('(time cap)'), 0, 'the yield did not count toward WINDOW_MAX_S')
    -- ... but the wall-time bound (WINDOW_WALL_MAX_S) still ends it
    w.s.pos = v(38, 0, 0)
    eq(w.step(80), true, 'still collecting at 80 s wall')
    local c0 = w.clears
    eq(w.step(91), false, 'ended at 90 s wall time')
    eq(w.s.logged('(time cap)'), 1, 'by the time cap')
    ok(w.clears > c0, 'movement cleared at the cap')
end)

case('review: a Looter/Alfred yield during the loot window is credited to it', function()
    local s = session({starter = SKIN.normal, range = 3})
    s.over_after = 0
    local far
    ok(s.run_until(function() return s.logged('collecting its loot') > 0 end, 120), 'window started')
    far = item(-5, 20) -- in the event area, 40 m from the ring
    s.drops[#s.drops + 1] = far
    s.tick(2)
    s.now = s.now + 60 -- the task yielded 60 s (its handlers did not run)
    ok(s.run_until(function() return s.logged('Tear event loot:') > 0 end, 60), 'window finished')
    eq(s.logged('(time cap)'), 0, 'not ended by the time cap after the yield')
    for _, d in ipairs(s.drops) do ok(d ~= far, 'the far drop was still walked to') end
end)

case('review: the loot window is not cut by the rupture cap', function()
    local s = session({starter = SKIN.normal, range = 3})
    s.over_after = 0
    ok(s.run_until(function() return s.logged('collecting its loot') > 0 end, 120), 'window started')
    s.tear.session().started_at = s.now - 299 -- the rupture used up its 300 s
    ok(s.run_until(function() return s.left_at ~= nil end, 60), 'HR left the rupture')
    eq(s.logged('took longer than'), 0, 'the window ran on its own bounds')
    eq(s.left_drops, 0, 'every drop collected')
end)

case('review: a Realmwalker that walks away is followed: its fight stays paused and its drops are collected', function()
    local s = session({rw = 'spawn', rw_kill_s = 20})
    s.before_tick = function()
        local rw = s.rw
        if rw and rw.hp > 1 and rw.pos:x() < 95 then rw.pos = v(math.min(95, rw.pos:x() + 0.6), 6, 0) end
    end
    ok(s.run_until(function() return s.left_at ~= nil end, 200), 'HR left the rupture')
    eq(s.logged('[RIFT] Realmwalker defeated'), 1, 'killed')
    eq(s.picked_early, 0, 'no drop taken during the fight, 65 m from the ring')
    eq(s.left_drops, 0, 'its drops by where it died were collected')
end)

case('review: a Looter that refuses the pause (enabled) gets no loot window', function()
    local s = session({rw = 'spawn'})
    s.env.LooteerPlugin.acquire_pause = function() return false end
    s.tick(150)
    eq(s.logged('collecting its loot'), 0, 'no loot window')
    eq(s.logged('Pausing Looter pickup'), 0, 'no pause line')
    eq(s.logged('[RIFT] Realmwalker defeated'), 1, 'the event itself runs as before')
end)

print(string.format('Helltide tear event: %d cases, %d checks, %d failures', cases, checks, #failures))
if #failures > 0 then error('Helltide tear event failures:\n' .. table.concat(failures, '\n')) end
print('PASS: test_helltide_tears_event (' .. cases .. ' cases)')
