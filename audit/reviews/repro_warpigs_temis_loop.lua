local ROOT = assert(SUITE_ROOT)
local root = ROOT .. '/WarPigs/'
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
    local ok, err = xpcall(run, debug.traceback)
    if not ok then failures[#failures + 1] = name .. ': ' .. tostring(err) end
end
local PAUSED = 'paused by its hotkey — WarPigs waiting'

-- ── part A: real orchestrator, host mocks ───────────────────────────────────
local function fixture(opts)
    opts = opts or {}
    local f = {now = 100, world = opts.world or 'PIT_Joint_Floor', zone = opts.zone or 'PIT_Subzone',
        town = opts.town == true, quests = {}, logs = {}, waypoints = 0, teleports = 0}
    local e = setmetatable({}, {__index = _G}); e._G = e
    e.console = {print = function(m) f.logs[#f.logs + 1] = string.format('%.1f %s', f.now, tostring(m)) end}
    e.attributes = {PLAYER_IN_TOWN_LEVEL_AREA = 'town'}
    e.get_time_since_inject = function() return f.now end
    e.get_local_player = function() return {
        is_dead = function() return false end,
        get_attribute = function() return f.town and 1 or 0 end,
        get_buffs = function() return {} end,
        get_position = function() return {} end,
        get_active_spell_id = function() return -1 end,
    } end
    e.get_current_world = function() return {
        get_name = function() return f.world end,
        get_current_zone_name = function() return f.zone end,
    } end
    e.get_quests = function()
        local out = {}
        for _, name in ipairs(f.quests) do out[#out + 1] = {get_name = function() return name end} end
        return out
    end
    e.actors_manager = {get_all_actors = function() return {} end}
    e.teleport_to_waypoint = function() f.waypoints = f.waypoints + 1 end
    e.warplan = {teleport_to_activity = function() f.teleports = f.teleports + 1 end}
    e.get_aether_count = function() return 0 end
    e.revive_at_checkpoint = function() end
    e.pathfinder = {request_move = function() end}
    e.orbwalker = {set_clear_toggle = function() end, set_block_movement = function() end}
    f.settings = {enabled = true, manage_whispers = false, use_teleport_transition = opts.teleport == true,
        manage_orbwalker = false, horde_warplan_entry = true, horde_compass_fallback = false}
    local modules = {['core.settings'] = f.settings,
        ['core.tasks.turn_in_rewards'] = {tick = function() end, get_state = function() return 'IDLE' end}}
    e.require = function(name)
        if modules[name] ~= nil then return modules[name] end
        local value = assert(loadfile(root .. name:gsub('%.', '/') .. '.lua', 't', e))()
        modules[name] = value
        return value
    end
    f.e = e
    f.o = e.require('core.orchestrator')
    function f.plugin(name, fields)
        local p = {enabled = false, enables = 0, disables = 0, st = fields or {}}
        p.enable = function() p.enabled = true; p.enables = p.enables + 1 end
        p.disable = function() p.enabled = false; p.disables = p.disables + 1 end
        p.get_status = function()
            local s = {enabled = p.enabled}
            for k, v in pairs(p.st) do s[k] = v end
            return s
        end
        e[name] = p
        return p
    end
    function f.tick() f.now = f.now + 0.5; f.o.tick() end
    function f.run(seconds) for _ = 1, math.floor(seconds / 0.5 + 0.5) do f.tick() end end
    function f.until_true(predicate, seconds)
        for _ = 1, math.floor(seconds / 0.5 + 0.5) do
            f.tick()
            if predicate() then return true end
        end
        return false
    end
    function f.logged(text)
        local n = 0
        for _, m in ipairs(f.logs) do if m:find(text, 1, true) then n = n + 1 end end
        return n
    end
    function f.dump() return table.concat(f.logs, '\n') end
    return f
end

local PIT = 'WarPlans_QST_ThePit'

for _, v in ipairs({'cancel', 'fail'}) do VARIANT = v
case(v .. ': Rosie trip cancelled during the via-Temis preamble: TEMIS_ALFRED <-> settle forever, never re-triggered', function()
    local f = fixture({teleport = true, world = 'Sanctuary', zone = 'Kehj_Caldeum', town = true})
    f.e.teleport_to_waypoint = function() f.waypoints = f.waypoints + 1; f.zone = 'Skov_Temis' end
    local A = {triggers = 0, st = {enabled = true, inventory_full = true, need_trigger = true,
        trigger_tasks = false, external_trigger = false, running = false, pending = false,
        paused = false, stuck = false, teleport = false}}
    A.get_status = function() local s = {}; for k, v in pairs(A.st) do s[k] = v end; return s end
    A.trigger_tasks = function(caller, cb)
        A.triggers = A.triggers + 1
        A.st.external_trigger, A.st.running = true, true
        A.started = f.now
        return true
    end
    f.e.AlfredTheButlerPlugin = A
    f.plugin('ArkhamAsylumPlugin', {})
    f.quests = {PIT}
    for _ = 1, 3600 do   -- 30 minutes
        f.tick()
        if A.failed_at then A.st.stuck = f.now - A.failed_at < 120; A.st.stuck_retry_in = A.st.stuck and (120 - (f.now - A.failed_at)) or nil; A.st.stuck_reason = 'vendor failed' end
        -- The user presses Rosie's Stop 10 s into the trip (outcome 'cancelled':
        -- not stuck, Rosie's own automatic service is blocked after a cancel).
        if A.started and A.st.running and f.now - A.started >= 10 then
            A.st.external_trigger, A.st.running = false, false
            if A.triggers == 1 and VARIANT == 'fail' then A.st.outcome = 'failed'; A.failed_at = f.now
            elseif A.triggers == 1 then A.st.outcome = 'cancelled'      -- first trip: user Stop
            else A.st.inventory_full, A.st.need_trigger, A.st.outcome = false, false, 'completed' end
        end
    end
    print(string.format('30 min: Alfred triggers=%d warplan teleports=%d waypoints=%d', A.triggers, f.teleports, f.waypoints))
    print('max-wait lines: ' .. f.logged('Alfred max wait') .. ', re-armed lines: ' .. f.logged('re-armed during settle')
        .. ', status: ' .. f.o.get_status_line())
    truthy(A.triggers > 1 or f.teleports > 0, 'the preamble must either re-trigger Alfred or proceed (bounded)')
end)
end

if #failures > 0 then error(table.concat(failures, '\n\n')) end
print('PASS zz_wp repro')
