-- QQT_Warpigz_v3 Batmobile 2.2.7: Enigma Teleport (opt-in, Mouse 3) must not
-- starve the class movement spells (Auditor review of 3.3.24, LOW).  Loads
-- the real movement_cast, movement_rules, movement_engine, movement_helpers,
-- utils and navigator with QQT-shaped host mocks.  Every case failed on 2.2.6.
--   E1 a refused click (off-screen node, w2s nil/NaN) arms the Enigma
--      throttle; the class Teleport gets its picks
--   E2 with spell_interval >= enigma_interval, Enigma and the class spell
--      take turns instead of Enigma winning every pick
--   E3 revamp in town: the Enigma rule is skipped without stamping its
--      throttle, so it fires at once outside town
--   E4 the picker catalog order stays append-only (saved rule indices)
-- Runs under Lua 5.4 and LuaJIT.
local root = assert(SUITE_ROOT, 'SUITE_ROOT is required') .. '/Batmobile/'
local checks, cases, failures = 0, 0, {}
local function ok(cond, message)
    checks = checks + 1
    if not cond then error(message or 'assertion failed', 2) end
end
local function case(name, fn)
    cases = cases + 1
    local passed, err = pcall(fn)
    if passed then
        print('PASS Batmobile Enigma: ' .. name)
    else
        failures[#failures + 1] = name .. ': ' .. tostring(err)
        print('FAIL Batmobile Enigma: ' .. name .. ': ' .. tostring(err))
    end
end

local Vec = {}; Vec.__index = Vec
function Vec:new(x, y, z) return setmetatable({_x = x, _y = y, _z = z or 0}, self) end
function Vec:x() return self._x end
function Vec:y() return self._y end
function Vec:z() return self._z end
local function v(x, y, z) return Vec:new(x, y, z) end

-- opts.screen(dest) -> {x, y} or nil (the w2s projection)
local function harness(opts)
    opts = opts or {}
    local h = {now = 100, town = false, clicks = 0, casts = {}}
    local player = {pos = v(0, 0)}
    function player:get_position() return self.pos end
    function player:is_dead() return false end
    function player:get_character_class_id() return 0 end          -- sorcerer
    function player:get_attribute() return h.town and 1 or 0 end
    function player:get_buffs() return {} end
    local settings = {step = 0.5, normalizer = 2, log_level = 0, plugin_label = 't',
        use_movement = true, use_enigma = true, use_teleport = true, spell_interval = 0.15,
        min_spell_dist = 3, movement_revamp = false, movement_rules = {}}
    local env = setmetatable({vec3 = Vec,
        get_time_since_inject = function() return h.now end,
        get_local_player = function() return player end,
        is_chat_open = function() return false end,
        is_inventory_open = function() return false end,
        get_screen_width = function() return 1920 end,
        get_screen_height = function() return 1080 end,
        get_equipped_spell_ids = function() return {} end,
        get_name_for_spell = function() return '' end,
        attributes = {PLAYER_IN_TOWN_LEVEL_AREA = 1},
        console = {print = function() end},
        graphics = {w2s = function(dest) return (opts.screen or function() return {x = 650, y = 420} end)(dest) end},
        utility = {send_mouse_middle_click = function() h.clicks = h.clicks + 1 end,
            can_cast_spell = function(id) return id > 0 end,
            set_height_of_valid_position = function(p) return p end,
            is_point_walkeable = function() return true end},
        cast_spell = {position = function(id) h.casts[#h.casts + 1] = id; return true end},
        actors_manager = {get_enemy_npcs = function() return {} end, get_all_actors = function() return {} end},
    }, {__index = _G})
    env._G = env
    local modules = {['core.settings'] = settings,
        ['core.tracker'] = {bench_start = function() end, bench_stop = function() end,
            bench_count = function() end, bench_enabled = false},
        ['core.explorer'] = {}, ['core.pathfinder'] = {}}
    env.require = function(name)
        if modules[name] ~= nil then return modules[name] end
        local chunk = assert(loadfile(root .. name:gsub('%.', '/') .. '.lua', 't', env))
        modules[name] = chunk()
        return modules[name]
    end
    h.settings = settings
    h.player = player
    h.cast = env.require('core.movement_cast')
    h.rules = env.require('core.movement_rules')
    h.engine = env.require('core.movement_engine')
    h.nav = env.require('core.navigator')
    for i = 1, 200 do
        local name, value = debug.getupvalue(h.nav.move, i)
        if not name then break end
        if name == 'get_movement_spell_id' then h.pick_fn = value end
    end
    assert(h.pick_fn, 'navigator selector upvalue missing')
    -- One selector run, then the dispatch navigator.move() would make.
    function h.pick_and_cast(dest)
        local id = h.pick_fn(player)
        if id ~= nil then h.cast.position(id, dest or v(8, 0), 0) end
        return id
    end
    return h
end

-- Counts selector picks over `ticks` 50 ms move ticks.
local function run(h, ticks, dest)
    local enigma, class = 0, 0
    for _ = 1, ticks do
        h.now = h.now + 0.05
        local id = h.pick_and_cast(dest)
        if id == h.cast.ENIGMA then enigma = enigma + 1 elseif id ~= nil then class = class + 1 end
    end
    return enigma, class
end

-- ── E1 ──────────────────────────────────────────────────────────────────
case('E1 a refused Enigma click arms the throttle; the class Teleport still fires', function()
    for _, label in ipairs({'nil', 'nan', 'offscreen'}) do
        local h = harness({screen = function()
            if label == 'nil' then return nil end
            if label == 'nan' then return {x = 0 / 0, y = 100} end
            return {x = 1920, y = 100}
        end})
        local enigma, class = run(h, 200)
        ok(h.clicks == 0, label .. ': no click is sent')
        ok(class >= 25, string.format('%s: class picks %d vs Enigma %d in 200 ticks (2.2.6: 2 vs 48)',
            label, class, enigma))
    end
end)

-- ── E2 ──────────────────────────────────────────────────────────────────
case('E2 spell_interval >= enigma_interval: Enigma and the class spell take turns', function()
    local h = harness()
    h.settings.spell_interval = 0.3
    h.cast.enigma_interval = 0.25
    local enigma, class = run(h, 200)
    ok(enigma >= 10, 'Enigma still clicks (' .. enigma .. ')')
    ok(class >= 10, string.format('class picks %d vs Enigma %d (2.2.6: 0 class picks)', class, enigma))
    -- control: Enigma alone (no class spell enabled) keeps every pick
    local solo = harness()
    solo.settings.spell_interval = 0.3
    solo.settings.use_teleport = false
    local e2, c2 = run(solo, 200)
    ok(c2 == 0 and e2 >= 20, 'Enigma-only setups keep clicking (' .. e2 .. ')')
end)

-- ── E3 ──────────────────────────────────────────────────────────────────
case('E3 revamp in town skips the Enigma rule without stamping its throttle', function()
    local h = harness()
    h.settings.movement_revamp = true
    h.settings.movement_rules = {
        {enabled = true, skill_id = h.cast.ENIGMA, conditions = {}, throttle_ms = 5000},
    }
    h.nav.path = {v(8, 0)}
    h.town = true
    h.now = h.now + 1
    local id = h.pick_fn(h.player)
    ok(id == nil, 'no Enigma in town')
    ok(h.engine.last_fire[1] == nil, 'the Enigma rule throttle is not stamped in town (2.2.6 stamped it)')
    h.town = false
    h.now = h.now + 1; h.nav.spell_time = -1
    ok(h.pick_fn(h.player) == h.cast.ENIGMA, 'Enigma fires right after leaving town (2.2.6: throttled 5 s)')
end)

-- ── E4 ──────────────────────────────────────────────────────────────────
case('E4 the picker catalog stays append-only', function()
    local h = harness()
    local cat = h.rules.skill_catalog
    ok(cat[1].id == 337031, 'Evade first')
    ok(cat[15].match == 'rampage', 'Rampage at 15')
    ok(cat[16].id == h.cast.ENIGMA, 'Enigma at 16')
end)

if #failures > 0 then
    error('Batmobile Enigma: ' .. #failures .. ' of ' .. cases .. ' cases failed:\n  ' .. table.concat(failures, '\n  '))
end
print(string.format('PASS Batmobile Enigma suite: %d cases, %d checks', cases, checks))
