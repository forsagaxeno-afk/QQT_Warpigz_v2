-- QQT_Warpigz_v3 3.3.3 (live: "just standing around waiting", "slow"):
-- every wait, stand and walk-to-a-target in a live Helltide ends on its
-- own. Each case below stood still (or looped) on the 3.3.2 code:
--   * a chest the bot cannot get within 2 m of (Batmobile refuses the cell);
--   * a spent pyre / pillar that stays listed after its event is over;
--   * ore, herb, shrine or goblin the bot cannot reach;
--   * a monster that never loses health (Warplan kill);
--   * a rupture cultist that cannot be killed or reached;
--   * a rupture / tear the bot cannot reach, re-engaged every 120 s.
-- Drives the real HelltideRevamped main.lua / tasks/helltide.lua with the
-- test_helltide_rupture_idle_332 harness. Runs under Lua 5.4 and LuaJIT.
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
        print('PASS Helltide stalls: ' .. name)
    else
        failures[#failures + 1] = name .. ': ' .. tostring(err)
        print('FAIL Helltide stalls: ' .. name .. ': ' .. tostring(err))
        local logs = last_session and last_session.logs or {}
        for i = math.max(1, #logs - 25), #logs do print('    | ' .. logs[i]) end
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
local next_id = 7000
-- opts.readable=false: the charge attribute cannot be read (nil);
-- opts.no_id: no get_id (position key fallback).
local function actor(skin, x, y, opts)
    opts = opts or {}
    next_id = next_id + 1
    local a = {skin = skin, pos = v(x, y, 0), interactable = opts.interactable ~= false, hp = opts.hp,
        id = next_id, progress = opts.progress}
    function a:get_skin_name() return self.skin end
    function a:get_position() return self.pos end
    function a:is_interactable() return self.interactable end
    if not opts.no_id then function a:get_id() return self.id end end
    if opts.hp then function a:get_current_health() return self.hp end end
    if opts.readable ~= false then
        function a:get_attribute(k) if k == PROGRESS then return (self.progress or 0) * (self.scale or 1) end return 0 end
    end
    return a
end

local SKIN = {
    normal_starter = 'S14_Rupture_SMP_SwitchGizmo',
    surging_starter = 'S14_Rupture_LE_SwitchGizmo',
    boundary = 'PandemoniumRift_gizmo_Boundry',
    hold = 'S14_PandemoniumCrack_gizmo_holdArea',
    glint = 'S14_Rupture_SMP_Chargeable',
    chest = 'S14_Rupture_SMP_PandemoniumChest',
}
local HELLTIDE_BUFF = 1066539
local SPEED, CIRCLE = 7, 2.5 -- m/s; the golden circle a tear charges in

local function session(opts)
    opts = opts or {}
    local s = {now = 100, minute = 10, pos = v(0, 0, 0), zone = 'Test_Zone', in_helltide = true,
        cinders = 311, actors = {}, loot = {}, logs = {}, interactions = {}, states = {}, dead = false,
        orb = {clear = true, block = false}, pauses = {}, acquires = 0, releases = 0, tears = {}, closed = 0,
        inside = 0, left_circle = 0, frozen = false}
    local bm = {target = nil}
    s.bm = bm
    local player = {
        get_position = function() return s.pos end, get_current_speed = function() return 0 end,
        is_dead = function() return s.dead end, get_item_count = function() return s.items or 0 end,
        get_consumable_items = function() return {} end, get_attribute = function() return 0 end,
        get_buffs = function() return s.in_helltide and {{name_hash = HELLTIDE_BUFF}} or {} end,
    }
    local world = {get_name = function() return 'Sanctuary_Eastern_Continent' end,
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
    env.target_selector = {get_near_target_list = function() return s.enemies or {} end}
    env.actors_manager = {get_all_actors = function() return s.actors end, get_enemy_actors = function() return {} end}
    env.loot_manager = {get_all_items_chest_sort_by_distance = function() return s.loot end,
        any_item_around = function() return false end}
    env.utility = {set_height_of_valid_position = function(p) return p end, is_point_walkeable = function() return true end}
    env.pathfinder = {request_move = function() end, clear_stored_path = function() end}
    env.teleport_to_waypoint = function() end
    env.interact_object = function(a) s.interactions[#s.interactions + 1] = a end
    env.revive_at_checkpoint = function() s.revives = (s.revives or 0) + 1 end
    env.attributes = {PLAYER_IN_TOWN_LEVEL_AREA = 1, CHARGEABLE_GIZMO_PROGRESS = PROGRESS, GIZMO_HAS_BEEN_OPERATED = 3}
    env.orbwalker = {set_clear_toggle = function(on) s.orb.clear = on end,
        set_block_movement = function(on) s.orb.block = on end}
    env.os = setmetatable({date = function(fmt, ...)
        if fmt == '%M' or fmt == '!%M' then return string.format('%02d', s.minute) end
        if fmt == '!%S' then return '00' end
        return os.date(fmt, ...)
    end}, {__index = os})
    env.BatmobilePlugin = {
        pause = function() end, resume = function() end,
        set_target = function(_, t)
            s.moves = (s.moves or 0) + 1
            if s.refuse then bm.target = nil; return false end
            bm.target = t; return true
        end,
        clear_target = function() bm.target = nil end, stop_long_path = function() end,
        update = function() end, move = function() end, is_paused = function() return false end,
        is_done = function() return false end, reset = function() bm.target = nil end,
        reset_movement = function() bm.target = nil end, get_target = function() return bm.target end,
        clear_giving_up = function() end, is_giving_up = function() return false end,
        navigate_long_path = function() return true end, is_long_path_navigating = function() return false end,
        get_closeby_node = function(_, p) return p end, clear_traversal_blacklist = function() end,
        release = function() bm.target = nil end,
    }
    -- Rosie-shaped Looter (acquire_pause/release_pause by caller): busy while
    -- its item lies on the ground and no one paused it; it steers the player.
    env.LooteerPlugin = {get_enabled = function() return true end,
        is_actively_looting = function() return s.loot_item ~= nil and next(s.pauses) == nil end,
        acquire_pause = function(c) s.pauses[c] = s.now; s.acquires = s.acquires + 1; return true end,
        release_pause = function(c) s.pauses[c] = nil; s.releases = s.releases + 1; return true end}
    local function control(value)
        return {value = value, get = function(self) return self.value end, set = function(self, n) self.value = n end}
    end
    local controls = setmetatable({}, {__index = function(t, k) local c = control(false); rawset(t, k, c); return c end})
    local defaults = {main_toggle = true, town = 0, helltide_chest_toggle = true,
        kill_monsters_toggle = opts.kill == true, kill_monsters_rarity = 0, farm_cinder_threshold = 0,
        maiden_disable_cinders = 0, mode = opts.mode or 1, hunt_rift_toggle = true,
        rupture_hunt_normal = true, rupture_hunt_surging = true, rupture_hunt_colossal = true,
        rupture_open_chests = true, tear_use_charge_ring = true, rupture_max_cinders = 0,
        tear_search_dist = 110, tear_passby_dist = 50, tear_event_radius = 12, tear_circle_radius = 2,
        rupture_linger_sec = 5, rupture_do_realmwalker = opts.rw == true, rupture_rw_wait_sec = 25,
        event_toggle = opts.event == true, ore_toggle = opts.ore == true, herb_toggle = opts.herb == true,
        shrine_toggle = opts.shrine == true, goblin_toggle = opts.goblin == true}
    for k, value in pairs(opts.controls or {}) do defaults[k] = value end
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
    s.tracker = env.require('core.tracker')
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
    -- One simulated host frame: Batmobile walks to its goal, a busy Looter
    -- steers the player to its item, tears in whose circle the player stands
    -- charge (1 / close_s per second) and close at 100 %.
    function s.tick(seconds, dt)
        dt = dt or 0.1
        for _ = 1, math.floor(seconds / dt + 0.5) do
            s.now = s.now + dt
            if bm.target and not s.frozen then
                step_to(bm.target.get_position and bm.target:get_position() or bm.target, dt)
            end
            if s.loot_item and next(s.pauses) == nil then
                if s.pos:dist_to(s.loot_item) > 0.5 then step_to(s.loot_item, dt) else s.loot_item = nil end
            end
            if s.push then s.pos = s.push; s.push = nil end
            local in_any, in_tear = false, nil
            for i = #s.tears, 1, -1 do
                local t = s.tears[i]
                if s.pos:dist_to(t.pos) <= CIRCLE then
                    in_any, in_tear = true, t
                    if t.close_s then
                        t.progress = (t.progress or 0) + dt / t.close_s
                        if t.progress >= 1 then
                            s.closed = s.closed + 1
                            table.remove(s.tears, i)
                            if t.stay_listed then
                                t.progress, t.close_s = 1, nil -- closed, the gizmo stays listed at 100 %
                            else
                                for j, a in ipairs(s.actors) do if a == t then table.remove(s.actors, j) break end end
                            end
                        end
                    end
                end
            end
            if in_any then s.inside = s.inside + dt end
            -- left the circle of a tear that is still open
            if s.was_in and s.was_in ~= in_tear then
                for _, t in ipairs(s.tears) do
                    if t == s.was_in then s.left_circle = s.left_circle + 1 end
                end
            end
            s.was_in = in_tear
            if s.before_tick then s.before_tick() end
            s.update()
            s.states[s.helltide.current_state] = true
        end
    end
    function s.logged(pattern)
        local n = 0
        for _, line in ipairs(s.logs) do if line:find(pattern, 1, true) then n = n + 1 end end
        return n
    end
    return s
end


local GLOVES = 'usz_rewardGizmo_Gloves'
local function enemy(x, y, hp, opts)
    opts = opts or {}
    local e = actor(opts.skin or 'Monster_Test', x, y, {hp = hp})
    function e:is_boss() return opts.boss == true end
    function e:is_elite() return opts.elite == true end
    function e:is_champion() return false end
    return e
end
local function state(s) return s.helltide.current_state end
-- Seconds spent in `name` states and how often one was entered.
local function watch_states(s, names)
    s.in_s, s.entered = 0, 0
    local was = false
    s.before_tick = function()
        local now_in = names[state(s)] == true
        if now_in then s.in_s = s.in_s + 0.1 end
        if now_in and not was then s.entered = s.entered + 1 end
        was = now_in
    end
end

case('a chest the bot cannot get within 2 m of is tried from where it stands, then skipped', function()
    local s = session({mode = 0})
    s.actors = {actor(GLOVES, 3.5, 0)}
    s.refuse = true -- Batmobile refuses the chest cell: the player never gets closer than 3.5 m
    watch_states(s, {MOVING_TO_HELLTIDE_CHEST = true})
    s.tick(90)
    ok(#s.interactions >= 1, 'the chest was tried from 3.5 m (' .. #s.interactions .. ' interactions)')
    -- 3 s band + 6 attempts x 4 s, then the 60 s blacklist
    ok(s.in_s <= 40, string.format('%.1fs at the chest in 90 s', s.in_s))
    eq(s.logged('did not open after'), 1, 'the give-up is logged')
end)

case('a chest that opens from 3.5 m is opened, not stood at', function()
    local s = session({mode = 0})
    local chest = actor(GLOVES, 3.5, 0)
    s.actors = {chest}
    s.refuse = true
    s.before_tick = function()
        if #s.interactions > 0 and chest.interactable then chest.interactable = false; s.cinders = s.cinders - 75 end
    end
    s.tick(30)
    eq(s.cinders, 311 - 75, 'opened once')
    ok(state(s) ~= 'MOVING_TO_HELLTIDE_CHEST', 'moved on')
end)

case('a spent pillar that stays listed after its event is left once the fight is over', function()
    local s = session({mode = 0, event = true})
    local pillar = actor('S04_Helltide_FlamePillar_Switch_Dyn', 5, 0)
    s.actors = {pillar}
    watch_states(s, {MOVING_TO_PYRE = true, INTERACT_PYRE = true, STAY_NEAR_PYRE = true})
    local wb = s.before_tick
    s.before_tick = function()
        wb()
        if #s.interactions > 0 then pillar.interactable = false end -- event started, then over: no monsters
    end
    s.tick(120)
    ok(#s.interactions >= 1, 'the pillar was used')
    ok(s.in_s <= 45, string.format('%.1fs at a pillar with no fight (240 s cap before)', s.in_s))
    eq(s.entered, 1, 'not engaged again')
end)

case('a running event with monsters around is still stood by', function()
    local s = session({mode = 0, event = true})
    local pillar = actor('S04_Helltide_FlamePillar_Switch_Dyn', 5, 0)
    s.actors = {pillar}
    s.before_tick = function()
        if #s.interactions > 0 then pillar.interactable = false end
        -- a wave every few seconds near the pillar (Warplan, kill off: the orbwalker fights)
        s.enemies = (math.floor(s.now) % 6 < 5) and {enemy(9, 0, 100)} or {}
    end
    s.tick(60)
    eq(state(s), 'STAY_NEAR_PYRE', 'still at the event while it spawns monsters')
end)

for _, kind in ipairs({'ore', 'herb', 'shrine'}) do
    case(kind .. ' the bot cannot reach is given up and not re-picked at once', function()
        local s = session({mode = 0, [kind] = true})
        local skin = ({ore = 'HarvestNode_Ore', herb = 'HarvestNode_Herb', shrine = 'Shrine_Test'})[kind]
        s.actors = {actor(skin, 5, 0)}
        s.refuse = true
        local st = ({ore = 'MOVING_TO_ORE', herb = 'MOVING_TO_HERB', shrine = 'MOVING_TO_SHRINE'})[kind]
        watch_states(s, {[st] = true})
        s.tick(120)
        ok(s.in_s <= 30, string.format('%.1fs walking to an unreachable %s in 120 s', s.in_s, kind))
        eq(s.entered, 1, 'skipped after the give-up')
    end)
end

case('a goblin the bot cannot reach is given up', function()
    local s = session({mode = 0, goblin = true})
    s.actors = {actor('treasure_goblin_Test', 20, 0, {hp = 100})}
    s.refuse = true
    watch_states(s, {CHASE_GOBLIN = true})
    s.tick(120)
    ok(s.in_s <= 40, string.format('%.1fs chasing an unreachable goblin in 120 s', s.in_s))
end)

case('Warplan kill: a monster that never loses health is not fought forever', function()
    local s = session({mode = 0, kill = true})
    s.enemies = {enemy(1.5, 0, 100, {elite = true})}
    watch_states(s, {KILL_MONSTERS = true})
    s.tick(120)
    ok(s.in_s <= 40, string.format('%.1fs on an unkillable monster in 120 s', s.in_s))
end)

case('Warplan kill: a monster that takes damage is fought to the end', function()
    local s = session({mode = 0, kill = true})
    local e = enemy(1.5, 0, 1000, {elite = true})
    s.enemies = {e}
    s.before_tick = function() e.hp = e.hp - 1 end -- 10 hp/s: 100 s
    s.tick(60)
    eq(state(s), 'KILL_MONSTERS', 'still fighting a monster that is losing health')
end)

case('a zone-override entry where the buff never comes is not parked on until the hour ends', function()
    local s = session({mode = 0})
    s.zone, s.in_helltide = 'Skov_Celestia', false
    s.pos = v(-728, 731, 0)
    s.tick(120)
    ok(not s.helltide.shouldExecute(), 'the helltide task releases the zone to search after the park bound')
    ok(s.logged('no Helltide buff') >= 1, 'logged')
end)

local function rift(s) return s.tear.is_rift_state(state(s)) end
local function watch_rift(s)
    s.rift_s, s.engages = 0, 0
    local was = false
    s.before_tick = function()
        local now_rift = rift(s)
        if now_rift then s.rift_s = s.rift_s + 0.1 end
        if now_rift and not was then s.engages = s.engages + 1 end
        was = now_rift
    end
end

case('rupture: a cultist that cannot be targeted does not park the bot for 300 s, nor re-arm the site', function()
    local s = session()
    s.actors = {actor(SKIN.normal_starter, 30, 2), actor(SKIN.hold, 30, 0), actor('S14_cultist_Melee', 36, 0, {hp = 100})}
    watch_rift(s)
    s.tick(290)
    -- the 30 s walk-to-the-ring bound, then 20 s without progress on the cultist
    ok(s.rift_s <= 60, string.format('%.0fs in rupture states in 290 s (300 s, then again every 120 s before)', s.rift_s))
    eq(s.engages, 1, 'the site is not re-armed by the same untouchable cultist')
    ok(s.logged('Cultists not killed') >= 1, 'the give-up names the cultists')
end)

case('rupture: cultists that die are fought, not given up', function()
    local s = session()
    local c1 = enemy(36, 0, 400, {skin = 'S14_cultist_Melee'})
    s.actors = {actor(SKIN.normal_starter, 30, 2), actor(SKIN.hold, 30, 0), c1}
    s.enemies = {c1}
    s.before_tick = function()
        if s.pos:dist_to(c1.pos) < 10 and c1.hp > 0 then c1.hp = c1.hp - 1 end -- 10 hp/s: 40 s fight
    end
    s.tick(45)
    eq(s.logged('Cultists not killed'), 0, 'a cultist losing health is not given up')
end)

case('rupture: a site the bot cannot walk to is not re-engaged every 120 s', function()
    local s = session()
    s.actors = {actor(SKIN.normal_starter, 80, 2), actor(SKIN.hold, 80, 0), actor('S14_cultist_Melee', 82, 0, {hp = 100})}
    watch_rift(s)
    local wb = s.before_tick
    s.before_tick = function() wb(); s.frozen = s.pos:x() > 40 end
    s.tick(290)
    eq(s.engages, 1, 'one attempt in 290 s')
end)

case('rupture: a tear the bot cannot reach is not re-engaged, nor counted as a completed rupture', function()
    local s = session({rw = true})
    s.actors = {actor(SKIN.surging_starter, 30, 2), actor(SKIN.hold, 30, 0)}
    local t = actor(SKIN.glint, 30, 15, {progress = 0})
    t.close_s = 5
    s.tears = {t}
    s.actors[#s.actors + 1] = t
    watch_rift(s)
    local wb = s.before_tick
    s.before_tick = function() wb(); s.frozen = s.pos:dist_to(t.pos) < 8 end
    s.tick(600)
    ok(s.engages <= 2, 'engaged ' .. s.engages .. ' times in 600 s')
    eq(s.logged('rupture complete'), 0, 'a rupture whose only tear was out of reach is not completed')
end)

print(string.format('Helltide stalls: %d cases, %d checks, %d failures', cases, checks, #failures))
if #failures > 0 then error('Helltide stalls failures:\n' .. table.concat(failures, '\n')) end
print('PASS: test_helltide_stalls_333 (' .. cases .. ' cases)')
