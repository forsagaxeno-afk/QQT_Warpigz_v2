-- HordeDev side of the War Plan Horde entry (round 4, F-H1/F-H2):
--   * InfernalHordesPlugin.enable({entry = 'warplan'}) selects War Plan entry,
--     enable() without options keeps the compass/farming mode, disable()
--     resets to 'compass', status() publishes entry_mode / hold / last_result;
--   * War Plan mode never uses a compass (no use_item, no sigil activation or
--     confirmation), never teleports to the Library or walks to the gate or
--     into the portal, never runs the built-in Cerrigar salvage, and idles
--     visibly outside BSK ('waiting for War Plan teleport');
--   * inside BSK the normal wave / pylon / council / chest / exit logic runs
--     (6 waves; nothing counts waves); a horde without a chest room, stash or
--     aether still completes within a bound and leaves; after the exit:
--     in_run == false, last_result == 'completed', chests_done() == true and
--     no second cycle;
--   * a HordeDev whose main toggle was on at load waits (bounded, visible)
--     for WarPigs' first decision while WarPigs is enabled (F-H2), and only
--     loaded-world time counts toward that bound (H5-2);
--   * round 5: the no-chest-room evidence counts only while the wave task is
--     idle in the boss room and actually running: a Stash in sight from
--     arrival, the door approach, the Council fight, the objective vanishing
--     mid-fight or an Alfred hold never end a horde before the Council (H5-1);
--     under WarPigs an advisory-only Alfred flag never pauses the chests for a
--     HordeDev Alfred trip (H5-4).
-- The real HordeDev plugin runs in an isolated environment with QQT-shaped
-- host mocks. Every case fails on d275b9d (no entry modes, first-frame
-- Library teleport) and passes now; the compass cases prove standalone
-- farming is unchanged.
local ROOT = assert(SUITE_ROOT) .. '/HordeDev-1.3.9/'
local checks, failures = 0, {}
local function eq(a, b, message)
    if a ~= b then error((message or 'mismatch') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end
    checks = checks + 1
end
local function truthy(value, message)
    if not value then error(message or 'expected a true value', 2) end
    checks = checks + 1
end
local function case(name, run)
    local ok, err = pcall(run)
    if ok then print('PASS War Plan Horde: ' .. name) else failures[#failures + 1] = name .. ': ' .. tostring(err) end
end

local vec = {}; vec.__index = vec
function vec:new(x, y, z) return setmetatable({_x = x or 0, _y = y or 0, _z = z or 0}, vec) end
function vec:x() return self._x end
function vec:y() return self._y end
function vec:z() return self._z end
function vec:dist_to(p) return math.sqrt((self._x - p:x()) ^ 2 + (self._y - p:y()) ^ 2 + (self._z - p:z()) ^ 2) end
function vec:dist_to_ignore_z(p) return math.sqrt((self._x - p:x()) ^ 2 + (self._y - p:y()) ^ 2) end
function vec:is_zero() return self._x == 0 and self._y == 0 and self._z == 0 end

local function widget(value)
    local w = {v = value, state = 0, key = 0x0A}
    function w:get() return self.v end
    function w:set(v) self.v = v; if type(v) == 'boolean' then self.state = v and 1 or 0 end end
    function w:render() end
    function w:push() return false end
    function w:pop() end
    function w:get_key() return self.key end
    function w:get_state() return self.state end
    return w
end

local function actor(name, x, y, opts)
    opts = opts or {}
    local a = {name = name, pos = vec:new(x or 0, y or 0, 0), interactable = opts.interactable ~= false,
        health = opts.health or 10, enemy = opts.enemy == true}
    function a:get_skin_name() return self.name end
    function a:get_position() return self.pos end
    function a:is_interactable() return self.interactable end
    function a:get_current_health() return self.health end
    function a:is_enemy() return self.enemy end
    function a:is_boss() return false end
    function a:is_elite() return false end
    function a:is_champion() return false end
    function a:get_name() return self.name end
    return a
end

local LIBRARY = 0x10D63D
-- Full HordeDev: real main.lua, gui.lua, core/*, tasks/*; only the host is
-- mocked. Every native that moves, teleports, uses an item or interacts is
-- recorded with its time.
local function horde(opts)
    opts = opts or {}
    local s = {now = 100, aether = opts.aether or 0, world = 'S05_BSK_Prototype02', zone = 'S05_BSK_Prototype02',
        id = 1, pos = vec:new(0, 0, 0), actors = {}, interactions = {}, logs = {}, teleports = {}, updates = {},
        item_count = 0, dead = false, leaves = 0, resets = 0, revives = 0, keys = {}, used = 0, moves = 0,
        spells = 0, quests = {}, alfred_triggers = 0}
    local player = {
        get_position = function() return s.pos end,
        is_dead = function() return s.dead end,
        get_item_count = function() return s.item_count end,
        get_buffs = function() return {} end,
        get_character_class_id = function() return 0 end,
        is_spell_ready = function() return false end,
        get_move_destination = function() return s.pos end,
        is_moving = function() return false end,
        get_dungeon_key_items = function() return s.keys end,
        get_inventory_items = function() return {} end,
        get_active_spell_id = function() return 0 end,
        get_attribute = function() return 0 end,
    }
    local world = {
        get_name = function() return s.world end,
        get_current_zone_name = function() return s.zone end,
        get_world_id = function() return s.id end,
    }
    local function move() s.moves = s.moves + 1; s.last_move = s.now end
    local env = {
        vec3 = vec, vec2 = vec,
        get_hash = function(x) return x end,
        checkbox = {new = function(_, v) return widget(v) end},
        slider_int = {new = function(_, _, _, d) return widget(d) end},
        slider_float = {new = function(_, _, _, d) return widget(d) end},
        combo_box = {new = function(_, d) return widget(d) end},
        keybind = {new = function(_, key) local w = widget(false); w.key = key; return w end},
        tree_node = {new = function() return widget(false) end},
        console = {print = function(m) s.logs[#s.logs + 1] = string.format('%.1f %s', s.now, tostring(m)) end},
        get_time_since_inject = function() return s.now end,
        get_local_player = function() return player end,
        get_player_position = function() return s.pos end,
        get_current_world = function() return world end,
        actors_manager = {get_all_actors = function() return s.actors end},
        loot_manager = {any_item_around = function() return false end},
        interact_object = function(a)
            s.interactions[#s.interactions + 1] = a and a.name
            if a and a.on_interact then a.on_interact(a) end
            return true
        end,
        teleport_to_waypoint = function(id) s.teleports[#s.teleports + 1] = {id = id, t = s.now} end,
        pathfinder = {request_move = move, force_move_raw = move, clear_stored_path = function() end},
        utility = {set_height_of_valid_position = function(p) return p end, is_point_walkeable = function() return true end,
            confirm_sigil_notification = function() s.confirms = (s.confirms or 0) + 1; return true end},
        evade = {register_circular_spell = function() end, is_dangerous_position = function() return false end},
        color = {new = function() return {} end}, danger_level = {high = 3},
        color_white = function() return {} end, color_red = function() return {} end, color_green = function() return {} end,
        color_yellow = function() return {} end, color_orange = function() return {} end,
        graphics = {text_3d = function() end, text_2d = function() end},
        target_selector = {is_valid_enemy = function(a) return a.enemy and a.health > 1 end, get_near_target_list = function() return {} end},
        orbwalker = {get_orb_mode = function() return 0 end, set_clear_toggle = function() end},
        revive_at_checkpoint = function() s.revives = s.revives + 1 end,
        on_update = function(fn) s.updates[#s.updates + 1] = fn end,
        on_render = function() end, on_render_menu = function() end,
        leave_dungeon = function()
            s.leaves = s.leaves + 1
            if s.on_leave then s.on_leave() end
        end,
        reset_all_dungeons = function()
            s.resets = s.resets + 1
            if s.reset_result ~= nil then return s.reset_result end
        end,
        use_item = function() s.used = s.used + 1 end,
        cast_spell = {position = function() s.spells = s.spells + 1; return false end},
        get_quests = function()
            local out = {}
            for _, name in ipairs(s.quests) do out[#out + 1] = {get_name = function() return name end} end
            return out
        end,
        os = os, math = math, string = string, table = table, pairs = pairs, ipairs = ipairs, type = type,
        tostring = tostring, tonumber = tonumber, pcall = pcall, error = error, assert = assert, next = next,
        setmetatable = setmetatable, getmetatable = getmetatable, select = select, rawget = rawget,
        print = function() end,
    }
    env.get_aether_count = function() return s.aether end
    for k, v in pairs(opts.globals or {}) do env[k] = v end
    env._G = env
    local loaded = {}
    env.require = function(name)
        if loaded[name] ~= nil then return loaded[name] end
        local chunk = assert(loadfile(ROOT .. name:gsub('%.', '/') .. '.lua', 't', env))
        local result = chunk()
        if result == nil then result = true end
        loaded[name] = result
        return result
    end
    env.package = {loaded = loaded}
    if opts.persisted_on then
        -- The GUI checkbox reads its persisted value at load.
        local new = env.checkbox.new
        env.checkbox = {new = function(_, v, key)
            if key == 'infernal_horde_main_toggle' then return widget(true) end
            return new(_, v, key)
        end}
    end
    assert(loadfile(ROOT .. 'main.lua', 't', env))()
    s.env, s.loaded, s.P = env, loaded, env.InfernalHordesPlugin
    s.gui, s.tr = loaded.gui, loaded['core.tracker']
    function s:tick(dt)
        self.now = self.now + (dt or 0.2)
        for _, fn in ipairs(self.updates) do fn() end
        if self.step then self.step() end
    end
    function s:run(seconds, dt, each)
        dt = dt or 0.2
        for _ = 1, math.floor(seconds / dt + 0.5) do
            self:tick(dt)
            if each then each() end
        end
    end
    function s:until_true(predicate, seconds)
        for _ = 1, math.floor(seconds / 0.2 + 0.5) do
            self:tick(0.2)
            if predicate() then return true end
        end
        return false
    end
    function s:task_name() return self.P.status().task.name end
    function s:gate() -- Caldeum, at the Hell Gate
        self.world, self.zone, self.id = 'Sanctuary_Eastern_Continent', 'Kehj_Caldeum', self.id + 1
        self.actors = {actor('QST_Caldeum_GatesToHell_Seal', 3, 0)}
    end
    function s:caldeum() -- Caldeum, far from the gate
        self.world, self.zone, self.id = 'Sanctuary_Eastern_Continent', 'Kehj_Caldeum', self.id + 1
        self.actors = {}
    end
    function s:town(zone)
        self.world, self.zone, self.id = 'Sanctuary_Eastern_Continent', zone or 'Skov_Temis', self.id + 1
        self.actors = {}
    end
    function s:bsk()
        self.world, self.zone, self.id = 'S05_BSK_Prototype02', 'S05_BSK_Prototype02', self.id + 1
        self.actors = {}
    end
    function s:logged(text)
        local n = 0
        for _, m in ipairs(self.logs) do if m:find(text, 1, true) then n = n + 1 end end
        return n
    end
    function s:tail(n)
        local out = {}
        for i = math.max(1, #self.logs - (n or 25)), #self.logs do out[#out + 1] = self.logs[i] end
        return table.concat(out, '\n')
    end
    -- Leave Dungeon lands `where` (default: the Caldeum gate) after `delay`.
    function s:leave_to(where, delay)
        self.on_leave = function() self.leave_at = self.now + (delay or 2) end
        local prior = self.step
        self.step = function()
            if prior then prior() end
            if self.leave_at and self.now >= self.leave_at then
                self.leave_at = nil
                if where then where(self) else self:gate() end
            end
        end
    end
    return s
end

local function sigil(name) return {get_name = function() return name end} end
-- Nothing that enters a horde by compass, walks or teleports ran.
local function no_compass_chain(s, label)
    eq(s.used, 0, label .. ': no use_item (compass)')
    eq(s.confirms, nil, label .. ': no sigil confirmation')
    eq(s.tr.sigil_used, false, label .. ': no sigil used')
    eq(s.tr.sigil_activation_pending, false, label .. ': no sigil activation pending')
    eq(s.tr.horde_entry_pending, false, label .. ': no portal entry pending')
    for _, t in ipairs(s.teleports) do
        error(string.format('%s: teleport_to_waypoint(0x%X) at %.1f', label, t.id, t.t), 2)
    end
    checks = checks + 1
end

-- A scripted 6-wave War Plan horde around the (unmoving) player: each wave a
-- pylon, then monsters; after wave 6 the locked door, the council pylon, the
-- council boss, then (unless opts.no_chest_room) the chest room with stash.
-- Round 5 options (all off by default): opts.static_stash (a Stash in sight
-- from arrival to the end), opts.door_time (the locked door opens only this
-- long after it appeared: the door approach), opts.council_delay (the council
-- pylon appears this long after the door opened), opts.boss_time (length of
-- the Council fight, default 4 s), opts.on_door / opts.on_council hooks.
-- a.t records when the door appeared/opened, the council pylon was used and
-- the boss died.
local function war_plan_arena(s, opts)
    opts = opts or {}
    local a = {wave = 0, log = {}, t = {}}
    local stash = opts.static_stash and actor('Stash', 1.5, 0) or nil
    local function set(list)
        if stash then list[#list + 1] = stash end
        s.actors = list
    end
    local function spawn_wave()
        a.wave = a.wave + 1
        local pylon = actor('BSK_Pyl_ChaoticOffering', 1, 0)
        pylon.on_interact = function(p)
            p.interactable = false
            a.log[#a.log + 1] = 'pylon ' .. a.wave
            set({actor('BSK_Wave_Monster', 1, 0, {enemy = true, health = 100})})
            a.kill_at = s.now + (opts.wave_time or 3)
        end
        set({pylon})
    end
    local function council_pylon()
        local pyl = actor('BSK_PylChoiceGizmo_SelectCouncil', 1, 0)
        pyl.on_interact = function(p)
            p.interactable = false
            a.log[#a.log + 1] = 'council'
            a.t.council = s.now
            set({actor('BSK_Council_Boss', 1, 0, {enemy = true, health = 500})})
            a.boss_at = s.now + (opts.boss_time or 4)
            if opts.on_council then opts.on_council(s) end
        end
        set({pyl})
    end
    local function council()
        a.t.door = s.now
        local door = actor('Hell_Fort_BSK_Door_A_01_Dyn', 1, 0)
        set({actor('BSK_MapIcon_LockedDoor', 30, 30), door})
        door.on_interact = function()
            if a.t.door_opened or s.now - a.t.door < (opts.door_time or 0) then return end
            a.t.door_opened = s.now
            if opts.council_delay then
                set({})
                a.council_at = s.now + opts.council_delay
            else
                council_pylon()
            end
        end
        if opts.on_door then opts.on_door(s) end
    end
    local function chest_room()
        a.log[#a.log + 1] = 'boss dead'
        a.t.boss_dead = s.now
        s.actors = {}
        if stash or opts.stash ~= false then s.actors[#s.actors + 1] = stash or actor('Stash', 1.5, 0) end
        if not opts.no_chest_room then
            local materials = actor('BSK_UniqueOpChest_Materials', 0.5, 0)
            materials.on_interact = function()
                if s.aether >= 10 then s.aether = s.aether - 10; a.opened = (a.opened or 0) + 1 end
            end
            s.actors[#s.actors + 1] = materials
            s.actors[#s.actors + 1] = actor('BSK_UniqueOpChest_Gold', 1.0, 0)
        end
        s.aether = opts.aether or 20
        if opts.on_boss then opts.on_boss(s) end
    end
    spawn_wave()
    local prior = s.step
    s.step = function()
        if prior then prior() end
        if a.kill_at and s.now >= a.kill_at then
            a.kill_at = nil
            if a.wave < 6 then spawn_wave() else council() end
        end
        if a.council_at and s.now >= a.council_at then a.council_at = nil; council_pylon() end
        if a.boss_at and s.now >= a.boss_at then a.boss_at = nil; chest_room() end
    end
    return a
end

-- ── Contract ─────────────────────────────────────────────────────────────────
case('enable(opts) selects the entry mode; enable() stays compass; disable() resets it', function()
    local s = horde()
    eq(s.P.status().entry_mode, 'compass', 'default mode')
    s.P.enable({entry = 'warplan'})
    eq(s.P.status().entry_mode, 'warplan', 'War Plan entry')
    eq(s.P.status().enabled, true)
    s.P.disable()
    eq(s.P.status().entry_mode, 'compass', 'disable() resets the mode')
    s.P.enable()
    eq(s.P.status().entry_mode, 'compass', 'enable() without options = compass')
    s.P.enable({entry = 'warplan'}); s.P.enable({})
    eq(s.P.status().entry_mode, 'compass', 'enable({}) = compass')
    s.P.enable({entry = 'warplan'}); s.P.enable(s.P)
    eq(s.P.status().entry_mode, 'compass', 'enable called with a colon = compass')
    eq(s:logged('HORDE ACTIVATING (War Plan entry)'), 3, 'War Plan enables logged')
    eq(s.P.status().last_result, nil, 'no result before a run')
end)

-- ── Outside BSK: a visible idle, never the compass chain ────────────────────
local OUTSIDE = {
    {'Temis', function(s) s:town('Skov_Temis') end},
    {'Caldeum, away from the gate', function(s) s:caldeum() end},
    {'Caldeum at the gate with a compass', function(s) s:gate(); s.keys = {sigil('S05_DungeonSigil_BSK_Wave6')} end},
    {'Caldeum at an open portal, stale run flags', function(s)
        s:gate(); s.keys = {sigil('S05_DungeonSigil_BSK_Wave10')}
        s.actors[#s.actors + 1] = actor('Portal_Dungeon_Generic', 1, 0)
        s.P.enable(); s.tr.horde_opened, s.tr.has_entered, s.tr.sigil_used = true, false, true
    end},
    {'Cerrigar with a full bag', function(s) s:town('Scos_Cerrigar'); s.item_count = 40; s.tr.needs_salvage = true end},
}
for _, place in ipairs(OUTSIDE) do
    case('War Plan mode outside BSK idles visibly: ' .. place[1], function()
        local s = horde()
        place[2](s)
        s.P.enable({entry = 'warplan'})
        s:run(120)
        no_compass_chain(s, place[1])
        eq(s.moves, 0, place[1] .. ': no movement')
        eq(s.spells, 0, place[1] .. ': no movement spell')
        eq(#s.interactions, 0, place[1] .. ': no interaction')
        local st = s.P.status()
        eq(st.enabled, true, 'still enabled')
        eq(st.task.name, 'Waiting for War Plan teleport', place[1] .. ': visible task')
        eq(st.hold, 'waiting for War Plan teleport', place[1] .. ': status hold')
        eq(st.in_run, false, place[1] .. ': not in a run')
        eq(st.entry_mode, 'warplan')
        eq(st.fault, nil, place[1] .. ': no fault')
        eq(s:logged('waiting for the War Plan teleport (no compass'), 1, place[1] .. ': wait logged when it starts')
        eq(s:logged('still waiting for the War Plan teleport'), 1, place[1] .. ': then at most once a minute (120 s)')
    end)
end

-- Control: the same places in compass mode still farm (standalone unchanged).
case('compass mode (enable() without options) keeps the Library and compass chain', function()
    local t = horde(); t:town('Skov_Temis'); t.P.enable(); t:run(3)
    eq(#t.teleports, 1, 'Temis: Library teleport'); eq(t.teleports[1].id, LIBRARY)
    local g = horde(); g:gate(); g.keys = {sigil('S05_DungeonSigil_BSK_Wave6')}; g.P.enable(); g:run(8)
    eq(g:task_name(), 'Start Dungeon', 'gate: Start Dungeon')
    eq(g.used, 1, 'gate: the compass is used')
end)

-- ── Inside BSK: the whole 6-wave War Plan horde, exit, no second cycle ─────
case('War Plan run in BSK: 6 waves, council, chests, Leave Dungeon, completed, no second cycle', function()
    local s = horde()
    s.gui.elements.merry_go_round:set(false)
    s.gui.elements.exit_mode:set(1) -- 'Teleport' exit: War Plan mode still uses Leave Dungeon
    local arena = war_plan_arena(s, {aether = 20})
    s.quests = {'WarPlans_QST_InfernalHordes_BSK'}
    s.P.enable({entry = 'warplan'})
    s:run(1)
    eq(s:task_name(), 'Idle', 'settle gate after enable')
    s:run(3)
    eq(s:task_name(), 'Infernal Horde', 'waves run inside BSK')
    eq(s.P.status().in_run, true)
    s:leave_to(function(x) x:gate(); x.keys = {sigil('S05_DungeonSigil_BSK_Wave6')} end)
    truthy(s:until_true(function() return s.leaves >= 1 end, 240), 'Leave Dungeon reached\n' .. s:tail())
    eq(arena.wave, 6, '6 waves')
    eq(arena.log[#arena.log], 'boss dead')
    eq(arena.opened, 2, 'the aether was spent at the chests')
    truthy(s:logged('Chest sequence finished') == 1, 'chest phase finished')
    local left_at = s.now
    truthy(s:until_true(function() return s.P.status().last_result == 'completed' end, 30), 'run completed\n' .. s:tail())
    eq(s.resets, 1, 'reset after the War Plan run')
    local st = s.P.status()
    eq(st.in_run, false, 'in_run false after the exit')
    eq(s.P.chests_done(), true, 'chests_done() after the exit')
    eq(st.fault, nil)
    eq(s:logged('War Plan horde complete'), 1, 'completion logged once')
    s:run(120)
    no_compass_chain(s, 'after the exit')
    eq(#s.teleports, 0, 'no Library teleport (not even the Teleport exit)')
    eq(s:task_name(), 'War Plan horde complete', 'visible completed result')
    eq(s.P.status().hold, nil, 'a result, not a hold')
    truthy(s.last_move == nil or s.last_move <= left_at, 'no movement after the exit')
    eq(s:logged('Waiting five seconds before selecting a compass'), 0, 'no compass cycle started')
    eq(s:logged('War Plan run: leaving through Leave Dungeon'), 1, 'Teleport exit setting ignored, logged once')
end)

case('back-to-back War Plan hordes: each arrival in BSK gets a fresh run (re-enable or not)', function()
    for _, reenable in ipairs({true, false}) do
        local s = horde()
        s.gui.elements.merry_go_round:set(false)
        local first = war_plan_arena(s, {aether = 10})
        s.P.enable({entry = 'warplan'})
        s:leave_to()
        truthy(s:until_true(function() return s.P.status().last_result == 'completed' end, 240), 'first run\n' .. s:tail())
        eq(first.opened, 1)
        s:run(10)
        -- the next War Plan teleport lands in a new horde
        s.step = nil
        s:bsk()
        local second = war_plan_arena(s, {aether = 20})
        if reenable then s.P.enable({entry = 'warplan'}) end
        eq(s:logged('keeping the current run'), 0, 'a finished War Plan run is never kept')
        s:leave_to()
        truthy(s:until_true(function() return s.leaves >= 2 end, 240), 'second run left\n' .. s:tail())
        eq(second.wave, 6, 'second horde: waves ran')
        eq(second.opened, 2, 'second horde: its chests were opened (no stale finished flag)')
        truthy(s:until_true(function() return s.P.status().last_result == 'completed' end, 30), 'second run completed')
        eq(s.resets, 2)
        no_compass_chain(s, 'back-to-back')
        eq(#s.teleports, 0)
    end
end)

-- ── Bounded completion without a chest room / stash / aether ───────────────
case('War Plan horde with a stash but no chest room: bounded skip, exit, completed (compass holds as before)', function()
    for _, mode in ipairs({'warplan', 'compass'}) do
        local s = horde()
        s.gui.elements.merry_go_round:set(false)
        war_plan_arena(s, {no_chest_room = true, aether = 12})
        s.P.enable(mode == 'warplan' and {entry = 'warplan'} or nil)
        s:leave_to()
        local done = s:until_true(function() return s.leaves >= 1 end, 150)
        if mode == 'warplan' then
            truthy(done, 'left without a chest room\n' .. s:tail())
            eq(s:logged('stash visible for 20s and no chest room'), 1, 'skip logged once')
            eq(s.tr.chest_fault, nil, 'not a fault')
            truthy(s:until_true(function() return s.P.status().last_result == 'completed' end, 30), 'completed')
            eq(s.P.chests_done(), true, 'chests_done() with 12 unspendable aether')
            eq(s.P.status().in_run, false)
            no_compass_chain(s, 'no chest room')
        else
            eq(done, false, 'compass mode: unchanged exit gate (chests required)')
        end
    end
end)

case('no false completion mid-wave: a stash in sight and a blank quest list before the waves end', function()
    local s = horde()
    s.gui.elements.merry_go_round:set(false)
    s.quests = {'WarPlans_QST_InfernalHordes_BSK'}
    local arena = war_plan_arena(s, {aether = 10, wave_time = 8})
    local stash = actor('Stash', 40, 0)
    local prior = s.step
    s.step = function()
        prior()
        if arena.log[#arena.log] ~= 'council' and arena.log[#arena.log] ~= 'boss dead' then
            local seen = false
            for _, a in ipairs(s.actors) do if a == stash then seen = true end end
            if not seen then s.actors[#s.actors + 1] = stash end
        end
        -- the host reports no quests for a while during waves 2 and 3
        s.quests = (arena.wave == 2 or arena.wave == 3) and {} or {'WarPlans_QST_InfernalHordes_BSK'}
    end
    s.P.enable({entry = 'warplan'})
    s:leave_to()
    truthy(s:until_true(function() return s.leaves >= 1 end, 300), 'left after the chests\n' .. s:tail())
    eq(s:logged('no chest room'), 0, 'no chest skip during the waves')
    eq(arena.wave, 6, 'all waves ran before the exit')
    eq(arena.opened, 1, 'the chest was opened')
    truthy(s:logged('Interacting with council pylon') >= 1, 'the council ran')
end)

case('War Plan horde without chest room or stash: the objective vanishing bounds completion', function()
    local s = horde()
    s.gui.elements.merry_go_round:set(false)
    s.quests = {'WarPlans_QST_InfernalHordes_BSK'}
    war_plan_arena(s, {no_chest_room = true, stash = false, aether = 0,
        on_boss = function(x) x.quests = {'WarPlans_QST_TurnIn_Rewards'} end})
    s.P.enable({entry = 'warplan'})
    s:leave_to()
    truthy(s:until_true(function() return s.leaves >= 1 end, 150), 'left\n' .. s:tail())
    eq(s:logged('War Plan objective complete for 20s and no chest room'), 1)
    truthy(s:until_true(function() return s.P.status().last_result == 'completed' end, 30), 'completed')
    no_compass_chain(s, 'no stash')
end)

case('War Plan horde with nothing after the council: the quiet boss room bounds completion', function()
    local s = horde()
    s.gui.elements.merry_go_round:set(false)
    war_plan_arena(s, {no_chest_room = true, stash = false, aether = 0})
    s.P.enable({entry = 'warplan'})
    s:leave_to()
    local boss_dead
    truthy(s:until_true(function()
        if not boss_dead and #s.actors == 0 and s.tr.locked_door_found then boss_dead = s.now end
        return s.leaves >= 1
    end, 240), 'left\n' .. s:tail())
    truthy(boss_dead and s.now - boss_dead <= 75, string.format('bounded: %.1fs after the boss', s.now - (boss_dead or 0)))
    eq(s:logged('boss room quiet for 20s and no chest room'), 1)
    truthy(s:until_true(function() return s.P.status().last_result == 'completed' end, 30), 'completed')
end)

case('War Plan chest room with no aether: the chest phase ends within its bounds and the run completes', function()
    local s = horde()
    s.gui.elements.merry_go_round:set(false)
    local arena = war_plan_arena(s, {aether = 0})
    s.P.enable({entry = 'warplan'})
    s:leave_to()
    local boss_dead
    truthy(s:until_true(function()
        if not boss_dead and arena.log[#arena.log] == 'boss dead' then boss_dead = s.now end
        return s.leaves >= 1
    end, 240), 'left\n' .. s:tail())
    truthy(s.now - boss_dead <= 60, string.format('bounded: %.1fs after the boss', s.now - boss_dead))
    eq(arena.opened, nil, 'nothing to spend')
    truthy(s:until_true(function() return s.P.status().last_result == 'completed' end, 30), 'completed')
    eq(s.P.status().fault, nil)
end)

case('War Plan chest room without a stash: leaves after the bounded stash wait (compass unchanged)', function()
    for _, mode in ipairs({'warplan', 'compass'}) do
        local s = horde()
        s.gui.elements.merry_go_round:set(false)
        war_plan_arena(s, {stash = false, aether = 10})
        s.P.enable(mode == 'warplan' and {entry = 'warplan'} or nil)
        s:leave_to()
        local finished_at
        local done = s:until_true(function()
            if not finished_at and s.tr.finished_chest_looting then finished_at = s.now end
            return s.leaves >= 1
        end, 180)
        truthy(finished_at, mode .. ': chests finished')
        if mode == 'warplan' then
            truthy(done, 'left without a stash')
            truthy(s.now - finished_at >= 10 and s.now - finished_at <= 13,
                string.format('stash wait bounded: %.1fs', s.now - finished_at))
        else
            eq(done, false, 'compass mode: unchanged (stash required)')
        end
    end
end)

-- ── Exit edge cases ─────────────────────────────────────────────────────────
case('War Plan exit: Leave Dungeon landing elsewhere and a refused reset still complete the run', function()
    local s = horde()
    s.gui.elements.merry_go_round:set(false)
    war_plan_arena(s, {aether = 10})
    s.reset_result = false
    s.P.enable({entry = 'warplan'})
    s:leave_to(function(x) x:town('Skov_Temis') end)
    truthy(s:until_true(function() return s.P.status().last_result == 'completed' end, 240), 'completed\n' .. s:tail())
    eq(s.P.status().fault, nil, 'no latched exit fault')
    eq(s.resets, 1)
    eq(s:logged('the War Plan run is complete without it'), 1, 'refused reset logged')
    eq(s.P.chests_done(), true)
    eq(s.P.status().in_run, false)
    s:run(30)
    no_compass_chain(s, 'after a Temis landing')
end)

case('War Plan mode: a full bag with no Alfred never starts the Cerrigar walk-in; chests continue', function()
    for _, mode in ipairs({'warplan', 'compass'}) do
        local s = horde()
        s.gui.elements.merry_go_round:set(false)
        s.item_count = 40
        war_plan_arena(s, {aether = 10})
        s.P.enable(mode == 'warplan' and {entry = 'warplan'} or nil)
        s:leave_to()
        local done = s:until_true(function() return s.leaves >= 1 or #s.teleports > 0 end, 240)
        truthy(done, mode .. ': progressed\n' .. s:tail())
        if mode == 'warplan' then
            eq(#s.teleports, 0, 'no Cerrigar teleport')
            eq(s.leaves, 1, 'left the Horde')
        else
            eq(s.teleports[1].id, 0x76D58, 'compass mode: built-in Cerrigar salvage unchanged')
        end
    end
end)

case('re-enable in War Plan mode at the gate with stale run flags: full reset, idle, never a compass', function()
    local s = horde()
    s:gate(); s.keys = {sigil('S05_DungeonSigil_BSK_Wave6')}
    s.P.enable()
    s.tr.horde_opened, s.tr.has_entered, s.tr.sigil_used = true, true, true
    s:run(2)
    s.P.enable({entry = 'warplan'})
    eq(s:logged('keeping the current run'), 0, 'stale flags outside BSK are not a run')
    eq(s.tr.horde_opened, false, 'full reset')
    s:run(60)
    no_compass_chain(s, 'gate')
    eq(s:task_name(), 'Waiting for War Plan teleport')
    -- then the War Plan teleport lands in BSK: the run starts there
    s:bsk(); s.actors = {actor('BSK_Wave_Monster', 1, 0, {enemy = true, health = 100})}
    s:run(4)
    eq(s:task_name(), 'Infernal Horde', 'runs once inside BSK')
end)

-- ── F-H2: persisted-on HordeDev under WarPigs ───────────────────────────────
local function warpigs(enabled)
    local wp = {on = enabled}
    wp.status = function() return {enabled = wp.on, alfred_idle = true} end
    return wp
end
case('persisted-on HordeDev waits for WarPigs before any Library teleport or compass (bounded, visible)', function()
    -- (a) WarPigs disables it on its first tick: it never acted
    local wp = warpigs(true)
    local a = horde({persisted_on = true, globals = {WarPigsPlugin = wp}})
    a:town('Skov_Temis')
    a:tick(0.05)
    eq(a:task_name(), 'Waiting for WarPigs', 'visible wait on the first frame')
    truthy(a.P.status().hold:find('WarPigs', 1, true), 'status hold')
    a:run(0.5); a.P.disable(); a:run(30)
    eq(#a.teleports, 0, 'no first-frame Library teleport'); eq(a.used, 0)
    eq(a:logged('waiting up to 5s for WarPigs'), 1, 'logged once')
    -- (b) WarPigs enables it: it runs at once (compass mode as asked)
    local b = horde({persisted_on = true, globals = {WarPigsPlugin = warpigs(true)}})
    b:town('Skov_Temis')
    b:run(2)
    eq(#b.teleports, 0, 'nothing before the decision')
    b.P.enable(); b:run(1)
    eq(#b.teleports, 1, 'runs once WarPigs enabled it'); eq(b.teleports[1].id, LIBRARY)
    -- (b2) WarPigs enables it in War Plan mode inside BSK: the run starts there
    local w = horde({persisted_on = true, globals = {WarPigsPlugin = warpigs(true)}})
    w.actors = {actor('BSK_Wave_Monster', 1, 0, {enemy = true, health = 100})}
    w:run(1); w.P.enable({entry = 'warplan'}); w:run(3)
    eq(w:task_name(), 'Infernal Horde')
    -- (c) no decision (WarPigs adopted it): bounded, then it runs as configured
    local c = horde({persisted_on = true, globals = {WarPigsPlugin = warpigs(true)}})
    c:town('Skov_Temis')
    c:run(4.8)
    eq(#c.teleports, 0, 'held for the bound')
    c:run(1)
    eq(#c.teleports, 1, 'runs after 5 s without a decision')
    eq(c:logged('No enable/disable from WarPigs within 5s'), 1)
    -- (d) WarPigs loaded but off, and (e) no WarPigs: standalone unchanged
    for _, globals in ipairs({{WarPigsPlugin = warpigs(false)}, {}}) do
        local d = horde({persisted_on = true, globals = globals})
        d:town('Skov_Temis')
        d:run(0.4)
        eq(#d.teleports, 1, 'standalone: first frames act as before')
        eq(d:logged('waiting up to'), 0)
    end
end)

-- ── Round 5 ────────────────────────────────────────────────────────────────
-- H5-1: the no-chest-room completion evidence (stash visible, War Plan
-- objective gone, quiet boss room) counts only while the wave task is idle in
-- the boss room (tracker.horde_idle_since, the round-4 critic's gate), and
-- only while the wave task is the task that runs: an Alfred hold in the boss
-- room leaves no stale idle reading behind.
local CHEST_WAIT = 20
local function council_run(s, arena, seconds)
    local skipped_at
    local left = s:until_true(function()
        if not skipped_at and s.tr.chests_skipped then skipped_at = s.now end
        return s.leaves >= 1
    end, seconds or 400)
    return left, skipped_at
end
local function saw(arena, what)
    for _, entry in ipairs(arena.log) do if entry == what then return true end end
    return false
end

case('H5-1 stash visible from arrival, door approach and Council fight longer than CHEST_WAIT: the Council is killed first', function()
    for _, chest_room in ipairs({true, false}) do
        local label = chest_room and 'chest room' or 'no chest room'
        local s = horde()
        s.gui.elements.merry_go_round:set(false)
        s.quests = {'WarPlans_QST_InfernalHordes_BSK'}
        local arena = war_plan_arena(s, {static_stash = true, door_time = CHEST_WAIT + 5, boss_time = CHEST_WAIT + 10,
            no_chest_room = not chest_room, aether = 20})
        s.P.enable({entry = 'warplan'})
        s:leave_to()
        local left, skipped_at = council_run(s, arena)
        truthy(left, label .. ': left the Horde\n' .. s:tail())
        truthy(saw(arena, 'council') and saw(arena, 'boss dead'), string.format(
            '%s: the Council was fought and killed before leaving (skip at %s)\n%s', label, tostring(skipped_at), s:tail()))
        -- the scenario really has a stash in sight for longer than CHEST_WAIT
        -- at the door and during the fight
        truthy(arena.t.door_opened - arena.t.door > CHEST_WAIT, label .. ': door approach longer than CHEST_WAIT')
        truthy(arena.t.boss_dead - arena.t.council > CHEST_WAIT, label .. ': Council fight longer than CHEST_WAIT')
        eq(arena.wave, 6, label .. ': 6 waves')
        if chest_room then
            eq(arena.opened, 2, 'chest room: the chests were opened')
            eq(s:logged('no chest room'), 0, 'chest room: no skip')
            eq(s.tr.chests_skipped, nil)
        else
            eq(s:logged('stash visible for 20s and no chest room'), 1, 'no chest room: bounded skip, logged once')
            truthy(skipped_at and skipped_at >= arena.t.boss_dead + CHEST_WAIT - 0.5, string.format(
                'no chest room: skip only after the boss room is idle (skip %.1f, boss dead %.1f)',
                skipped_at or -1, arena.t.boss_dead))
        end
        truthy(s:until_true(function() return s.P.status().last_result == 'completed' end, 30), label .. ': completed')
        no_compass_chain(s, label)
    end
end)

case('H5-1 the War Plan objective gone mid-fight (or a blank quest list at the door) is no evidence before the boss room is idle', function()
    for _, chest_room in ipairs({true, false}) do
        local label = chest_room and 'chest room' or 'no chest room'
        local s = horde()
        s.gui.elements.merry_go_round:set(false)
        s.quests = {'WarPlans_QST_InfernalHordes_BSK'}
        local arena = war_plan_arena(s, {stash = false, door_time = CHEST_WAIT + 5, boss_time = CHEST_WAIT + 10,
            no_chest_room = not chest_room, aether = chest_room and 20 or 0,
            on_door = function(x) x.quests = {} end,                                -- blank list at the door
            on_council = function(x) x.quests = {'WarPlans_QST_TurnIn_Rewards'} end}) -- gone mid-fight
        s.P.enable({entry = 'warplan'})
        s:leave_to()
        local left, skipped_at = council_run(s, arena)
        truthy(left, label .. ': left the Horde\n' .. s:tail())
        truthy(saw(arena, 'council') and saw(arena, 'boss dead'), label .. ': the Council was fought and killed\n' .. s:tail())
        if chest_room then
            eq(arena.opened, 2, 'chest room: the chests were opened')
            eq(s:logged('no chest room'), 0, 'chest room: no skip')
        else
            eq(s:logged('War Plan objective complete for 20s and no chest room'), 1, 'no chest room: bounded skip')
            truthy(skipped_at and skipped_at >= arena.t.boss_dead + CHEST_WAIT - 0.5, string.format(
                'no chest room: skip only after the boss room is idle (skip %.1f, boss dead %.1f)',
                skipped_at or -1, arena.t.boss_dead))
        end
        truthy(s:until_true(function() return s.P.status().last_result == 'completed' end, 30), label .. ': completed')
    end
end)

case('H5-1 an Alfred hold in the boss room is not idle time: no stale evidence while the wave task does not run', function()
    -- Alfred works for another caller for 30 s right after the door opened,
    -- while the player stays in the Horde and the Council pylon appears.
    local st = {enabled = true, need_trigger = false, running = false}
    local triggers = 0
    local s = horde({globals = {AlfredTheButlerPlugin = {get_status = function() return st end,
        trigger_tasks_with_teleport = function() triggers = triggers + 1; return true end}}})
    s.gui.elements.merry_go_round:set(false)
    local arena = war_plan_arena(s, {static_stash = true, council_delay = 4, aether = 20})
    local prior = s.step
    local held = 0
    s.step = function()
        prior()
        local opened = arena.t.door_opened
        st.running = opened ~= nil and s.now >= opened + 1 and s.now < opened + 1 + CHEST_WAIT + 10
        if st.running and s.P.status().hold == 'Alfred busy' then held = held + 1 end
    end
    s.P.enable({entry = 'warplan'})
    s:leave_to()
    local left = council_run(s, arena)
    truthy(left, 'left the Horde\n' .. s:tail())
    truthy(held * 0.2 > CHEST_WAIT, string.format('the Alfred hold lasted longer than CHEST_WAIT (%.1fs)', held * 0.2))
    eq(s:logged('no chest room'), 0, 'no chest skip from a stale idle reading')
    truthy(saw(arena, 'council') and saw(arena, 'boss dead'), 'the Council was fought after the hold\n' .. s:tail())
    eq(arena.opened, 2, 'the chests were opened')
    eq(triggers, 0, 'HordeDev never triggered Alfred')
end)

-- H5-2: F-H2's bound counts loaded-world time only (WarPigs does not tick
-- during a loading screen, so it cannot decide there).
case('H5-2 F-H2 wait: Limbo / loading time does not count; the bound runs in the loaded world only', function()
    -- 6 s of Limbo at load, then Temis: nothing in the first 0.5 s (WarPigs'
    -- first loaded tick), nothing for 4.7 s, then it runs as configured.
    local s = horde({persisted_on = true, globals = {WarPigsPlugin = warpigs(true)}})
    s.world, s.zone = 'Limbo', '[sno none]'
    s:run(6)
    eq(s:task_name(), 'Waiting for WarPigs', 'the wait is visible during the loading screen')
    eq(s:logged('waiting up to 5s for WarPigs'), 1, 'logged once, at the first pulse')
    s:town('Skov_Temis')
    s:run(0.5)
    eq(#s.teleports, 0, 'no HordeDev teleport in the first 0.5 s after the load')
    eq(s:task_name(), 'Waiting for WarPigs')
    s:run(4.2)
    eq(#s.teleports, 0, 'held for 4.7 s of loaded time')
    s:run(1)
    eq(#s.teleports, 1, 'bounded: runs after 5 s of loaded time without a decision'); eq(s.teleports[1].id, LIBRARY)
    eq(s:logged('No enable/disable from WarPigs within 5s'), 1)
    -- WarPigs decides on its first loaded tick: HordeDev never acted
    local d = horde({persisted_on = true, globals = {WarPigsPlugin = warpigs(true)}})
    d.world, d.zone = 'Limbo', '[sno none]'
    d:run(8)
    d:town('Skov_Temis'); d:run(0.4)
    d.P.disable(); d:run(30)
    eq(#d.teleports, 0, 'decided after the load: no teleport'); eq(d.used, 0)
    -- a loading screen in the middle of the wait pauses it; so does an
    -- unloaded zone reading ('[sno none]') in a named world
    local m = horde({persisted_on = true, globals = {WarPigsPlugin = warpigs(true)}})
    m:town('Skov_Temis'); m:run(2)
    m.world, m.zone = 'Limbo', '[sno none]'; m:run(4)
    m.world, m.zone = 'Sanctuary_Eastern_Continent', '[sno none]'; m:run(3)
    m:town('Skov_Temis'); m:run(2.4)
    eq(#m.teleports, 0, 'about 4 s of loaded time so far (the loading screen and the unloaded zone did not count)')
    m:run(1)
    eq(#m.teleports, 1, 'runs once 5 s of loaded time have passed')
end)

-- H5-4 (suite policy): while WarPigs is enabled an advisory-only Alfred flag
-- (restock/stash without inventory_full or need_repair) never pauses the
-- chests for a HordeDev Alfred trip, in War Plan and compass mode alike;
-- WarPigs services advisory flags once per Temis visit. Hard needs and
-- standalone HordeDev are unchanged.
local function chest_room_trip(status, wp, mode)
    local triggers = 0
    local alfred = {get_status = function() return status end,
        trigger_tasks_with_teleport = function() triggers = triggers + 1; return true end}
    local s = horde({globals = {AlfredTheButlerPlugin = alfred, WarPigsPlugin = wp}})
    s.gui.elements.merry_go_round:set(false)
    local arena = war_plan_arena(s, {aether = 20})
    s.P.enable(mode ~= 'compass' and {entry = 'warplan'} or nil)
    s:leave_to()
    local paused = false
    s:until_true(function()
        if s.loaded['tasks.open_chests'].current_state == 'PAUSED_FOR_SALVAGE' then paused = true end
        return s.leaves >= 1 or (arena.t.boss_dead ~= nil and s.now - arena.t.boss_dead > 60)
    end, 300)
    return s, arena, triggers, paused
end
case('H5-4 chest room under WarPigs: an advisory-only flag starts no HordeDev Alfred trip; hard needs and standalone unchanged', function()
    local advisory = function() return {enabled = true, need_trigger = true, restock_count = 2} end
    for _, v in ipairs({
        {'War Plan, WarPigs idle', 'warplan', {enabled = true, alfred_idle = true}},
        {'War Plan, WarPigs not idle', 'warplan', {enabled = true, alfred_idle = false}},
        {'War Plan, WarPigs without alfred_idle', 'warplan', {enabled = true}},
        {'compass, WarPigs enabled', 'compass', {enabled = true, alfred_idle = false}},
    }) do
        local reading = v[3]
        local s, arena, triggers, paused = chest_room_trip(advisory(), {status = function() return reading end}, v[2])
        eq(triggers, 0, v[1] .. ': no HordeDev Alfred trip for an advisory-only flag')
        eq(paused, false, v[1] .. ': the chests never paused for it')
        eq(arena.opened, 2, v[1] .. ': the chests were opened')
        eq(s.leaves, 1, v[1] .. ': left the Horde')
        eq(s:logged('Advisory Alfred flag left to WarPigs'), 1, v[1] .. ': logged once')
        eq(s.loaded['core.tracker'].needs_salvage, false, v[1])
    end
    local idle_wp = {status = function() return {enabled = true, alfred_idle = true} end}
    for _, hard in ipairs({'inventory_full', 'need_repair'}) do
        local status = advisory(); status[hard] = true
        local s, _, triggers, paused = chest_room_trip(status, idle_wp, 'warplan')
        truthy(paused and triggers >= 1, hard .. ' under WarPigs: the chests pause for a HordeDev Alfred trip')
        eq(s:logged('Advisory Alfred flag left to WarPigs'), 0, hard .. ': not an advisory flag')
    end
    for _, v in ipairs({{'WarPigs off', {status = function() return {enabled = false, alfred_idle = true} end}},
        {'no WarPigs', nil}}) do
        local s, _, triggers, paused = chest_room_trip(advisory(), v[2], 'warplan')
        truthy(paused and triggers >= 1, v[1] .. ': standalone rule, the advisory trip starts as before')
        eq(s:logged('Advisory Alfred flag left to WarPigs'), 0, v[1])
    end
end)

for _, failure in ipairs(failures) do print('FAIL ' .. failure) end
print(string.format('War Plan Horde (HordeDev): %d checks, %d failures', checks, #failures))
assert(#failures == 0, 'War Plan Horde (HordeDev) regressions failed')
print(string.format('PASS: War Plan Horde entry, HordeDev side (%d checks)', checks))
