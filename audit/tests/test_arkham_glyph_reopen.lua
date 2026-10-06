-- QQT_Warpigz_v3 Arkham 2.1.5 (sweep 2026-09-28 A1 / S2 F6, F6b): the glyph UI
-- closes when the player is pulled off the Awakened Glyphstone (death,
-- evade, loading screen). upgrade_glyph kept the first interaction time, read
-- an empty list back at the stone and set glyph_done with chances unused.
--   R1 one upgrade, the player is moved 20 m away (UI closes), walks back:
--      the stone is interacted again and all 3 chances are used (failed pre-fix:
--      1 upgrade, glyph_done with 2 chances left).
--   R2 the UI is lost again and again: at most 3 re-interactions, then the
--      task still finishes (bounded).
--   R3 control: no UI loss, one interaction, 3 upgrades.
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
    if passed then print('PASS arkham-glyph-reopen: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL arkham-glyph-reopen: ' .. name .. ': ' .. tostring(err)) end
end

local function vec(x, y)
    local v = {}
    v.x = function() return x end; v.y = function() return y end; v.z = function() return 0 end
    return v
end
local function pos_of(a) if a.get_position then return a:get_position() end return a end
local function dist(a, b)
    a, b = pos_of(a), pos_of(b)
    return math.sqrt((a:x() - b:x()) ^ 2 + (a:y() - b:y()) ^ 2)
end

local function fixture()
    local f = {now = 100, pos = vec(1, 0), ui_open = false, interacts = 0, upgrades = 0, chances = 3,
        logs = {}, speed = 2, target = nil}
    local gizmo = {get_skin_name = function() return 'Gizmo_Paragon_Glyph_Upgrade' end,
        get_position = function() return vec(0, 0) end}
    f.gizmo = gizmo
    local glyph = {glyph_name_hash = 777, level = 20}
    function glyph:get_level() return self.level end
    function glyph:get_upgrade_chance() return 1 end
    function glyph:get_max_level() return 100 end
    function glyph:can_upgrade() return f.chances > 0 end
    local tracker = {glyph_done = false, glyph_trigger_time = nil}
    f.tracker = tracker
    local modules = {
        ['core.utils'] = {
            player_in_pit = function() return true end,
            get_glyph_upgrade_gizmo = function() return gizmo end,
            looter_hold = function() return false end,
            distance = dist,
            stop_movement = function() f.target = nil end,
        },
        ['core.settings'] = {upgrade_toggle = true, upgrade_threshold = 0, minimum_glyph_level = 1,
            maximum_glyph_level = 100, upgrade_legendary_toggle = false, upgrade_mode = 0,
            disable_orbwalker_at_glyphstone = false, orb_set_clear = function() end},
        ['core.tracker'] = tracker,
        ['gui'] = {upgrade_modes_enum = {HIGHEST = 0, LOWEST = 1}},
        ['tasks.consume_chorons_soul'] = {shouldExecute = function() return false end},
        ['core.qqt_events'] = {emit = function() end},
    }
    local env = {
        require = function(n) return assert(modules[n], n) end,
        get_time_since_inject = function() return f.now end,
        get_local_player = function() return {get_position = function() return f.pos end} end,
        -- The game's glyph list is readable only while its UI is open.
        get_glyphs = function()
            if f.ui_open and dist(f.pos, gizmo) <= 5 then return {glyph} end
            return {}
        end,
        upgrade_glyph = function(g)
            if not f.ui_open or f.chances <= 0 then return end
            g.level = g.level + 1
            f.chances = f.chances - 1
            f.upgrades = f.upgrades + 1
        end,
        interact_object = function(a)
            f.interacts = f.interacts + 1
            if a == gizmo and dist(f.pos, gizmo) <= 5 then f.ui_open = true end
        end,
        console = {print = function(l) f.logs[#f.logs + 1] = tostring(l) end},
        BatmobilePlugin = setmetatable({
            set_target = function(_, t) f.target = pos_of(t) end,
            move = function() end,
        }, {__index = function() return function() return true end end}),
    }
    setmetatable(env, {__index = _G})
    f.task = assert(loadfile(ROOT .. '/ArkhamAsylum/tasks/upgrade_glyph.lua', 't', env))()
    function f.pulse(dt)
        dt = dt or 0.1
        if f.task.shouldExecute() then f.task.Execute() end
        if f.target then
            local d = dist(f.pos, f.target)
            local step = f.speed * dt
            if d <= step then f.pos = f.target
            else
                local k = step / d
                f.pos = vec(f.pos:x() + (f.target:x() - f.pos:x()) * k, f.pos:y() + (f.target:y() - f.pos:y()) * k)
            end
        end
        f.now = f.now + dt
    end
    function f.run_until(pred, seconds)
        local stop = f.now + seconds
        while f.now < stop do
            f.pulse()
            if pred() then return true end
        end
        return false
    end
    -- An evade / death / loading screen: the UI closes, the player is 20 m off.
    function f.pull_away()
        f.ui_open = false
        f.pos = vec(20, 0)
    end
    return f
end

case('R1 UI lost after 1 upgrade: back at the stone it is re-opened and all 3 chances are used', function()
    local f = fixture()
    ok(f.run_until(function() return f.upgrades >= 1 end, 10), 'first upgrade')
    f.pull_away()
    f.run_until(function() return f.tracker.glyph_done end, 60)
    ok(f.tracker.glyph_done, 'glyph_done after the chances are used')
    eq(f.upgrades, 3, string.format('upgrades before glyph_done (%d chance(s) left unused, %d interaction(s))',
        f.chances, f.interacts))
    ok(f.interacts >= 2, 'the glyphstone is interacted again after the UI was lost')
    eq(f.chances, 0, 'chances left')
end)

case('R2 UI lost again and again: at most 3 re-interactions, the task still finishes', function()
    local f = fixture()
    ok(f.run_until(function() return f.upgrades >= 1 end, 10), 'first upgrade')
    local first = f.interacts
    for _ = 1, 6 do
        -- Lose the UI as soon as the player is back at the stone.
        f.pull_away()
        f.run_until(function() return f.tracker.glyph_done or f.ui_open end, 30)
        if f.tracker.glyph_done then break end
        f.ui_open = false
    end
    ok(f.run_until(function() return f.tracker.glyph_done end, 60), 'glyph_done (bounded)')
    local reopen = 0
    for _, l in ipairs(f.logs) do if l:find('glyph UI lost', 1, true) then reopen = reopen + 1 end end
    ok(reopen <= 3, 'at most 3 re-interactions, got ' .. reopen)
    ok(f.interacts - first >= 3, 're-interacted after each loss')
end)

case('R3 control: no UI loss, one interaction, 3 upgrades', function()
    local f = fixture()
    ok(f.run_until(function() return f.tracker.glyph_done end, 30), 'glyph_done')
    eq(f.upgrades, 3, 'upgrades')
    eq(f.interacts, 1, 'interactions')
end)

if #failures > 0 then error(#failures .. ' arkham glyph reopen case(s) failed:\n' .. table.concat(failures, '\n')) end
print(string.format('PASS: arkham glyph reopen, %d checks', checks))
