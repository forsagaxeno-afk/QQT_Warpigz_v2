-- WarPigs 1.1.9 (QQT_Warpigz_v3): the Undercity "~5 teleports" causes owned by
-- WarPigs (audit/reviews/undercity_teleports_2026-09-28.md). Each case fails
-- on WarPigs 1.1.8 (release 3.3.6).
--   C1  TELEPORTING re-fired warplan.teleport_to_activity() every 6 s while
--       its own 186139 channel was still casting (a 7 s channel gave 6 War
--       Plan calls) and never recognised a same-zone (Temis) landing.
--   C2  TO_TEMIS helltide-lingering fast retry re-fired the Temis waypoint
--       every 6 s into its own channel, without a cap.
--   C3  a Rosie hop back to Temis between two 6 s samples read as "world/zone
--       unchanged" and fired the War Plan teleport again.
-- Host model: a teleport call starts a 186139 channel (a new call restarts
-- it); when the channel ends the player lands at its destination (world,
-- zone, world_id, position), unless the cast was cut (`cut` seconds).
local root = assert(SUITE_ROOT) .. '/WarPigs/'
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
    if not ok then failures[#failures + 1] = name .. ': ' .. tostring(err) end
end

local PLACES = {
    temis   = {world = 'Sanctuary', zone = 'Skov_Temis', town = true, x = 0},
    kurast  = {world = 'Sanctuary', zone = 'Kehj_Kurast', town = true, x = 900},
    helltide = {world = 'Sanctuary', zone = 'Hawe_Verge', town = false, x = 5000},
}

local function fixture(opts)
    opts = opts or {}
    local start = PLACES[opts.at or 'temis']
    local f = {now = 100, world = start.world, zone = start.zone, town = start.town, x = start.x,
        world_id = 1, quests = {}, logs = {}, warplan_calls = 0, waypoints = 0, buffs = {}}
    local e = setmetatable({}, {__index = _G}); e._G = e
    e.console = {print = function(m) f.logs[#f.logs + 1] = string.format('%.1f %s', f.now, tostring(m)) end}
    e.attributes = {PLAYER_IN_TOWN_LEVEL_AREA = 'town'}
    e.get_time_since_inject = function() return f.now end
    local function pos(x) return {x = x, dist_to = function(self, other) return math.abs(self.x - other.x) end} end
    e.get_local_player = function() return {
        is_dead = function() return false end,
        get_attribute = function() return f.town and 1 or 0 end,
        get_buffs = function() return f.buffs end,
        get_position = function() return pos(f.x) end,
        get_active_spell_id = function() return f.cast and 186139 or -1 end,
    } end
    e.get_current_world = function()
        local w = {get_name = function() return f.world end,
            get_current_zone_name = function() return f.zone end}
        if not opts.no_world_id then w.get_world_id = function() return f.world_id end end
        return w
    end
    e.get_quests = function()
        local out = {}
        for _, name in ipairs(f.quests) do out[#out + 1] = {get_name = function() return name end} end
        return out
    end
    e.actors_manager = {get_all_actors = function() return {} end}
    e.get_player_position = function() return pos(f.x) end
    local function cast(dest, channel, cut)
        f.cast = {dest = dest, ends_at = f.now + (cut or channel), cut = cut ~= nil}
    end
    e.teleport_to_waypoint = function()
        f.waypoints = f.waypoints + 1
        cast('temis', f.wp_channel or 5, f.wp_cut)
    end
    e.warplan = {teleport_to_activity = function()
        f.warplan_calls = f.warplan_calls + 1
        cast(f.warplan_dest or 'kurast', f.warplan_channel or 5)
    end}
    e.get_aether_count = function() return 0 end
    e.revive_at_checkpoint = function() end
    e.pathfinder = {request_move = function() end}
    f.settings = {enabled = true, manage_whispers = false, use_teleport_transition = true,
        manage_orbwalker = false, run_pit_after_turnin = false}
    local modules = {['core.settings'] = f.settings,
        ['core.tasks.turn_in_rewards'] = {tick = function() end, get_state = function() return 'IDLE' end}}
    e.require = function(name)
        if modules[name] ~= nil then return modules[name] end
        local value = assert(loadfile(root .. name:gsub('%.', '/') .. '.lua', 't', e))()
        modules[name] = value
        return value
    end
    f.o = e.require('core.orchestrator')
    function f.plugin(name)
        local p = {enabled = false, enables = 0}
        p.enable = function() p.enabled = true; p.enables = p.enables + 1 end
        p.disable = function() p.enabled = false end
        p.status = function() return {enabled = p.enabled} end
        e[name] = p
        return p
    end
    function f.go(place, new_instance)
        local P = PLACES[place]
        f.world, f.zone, f.town, f.x = P.world, P.zone, P.town, P.x
        if new_instance then f.world_id = f.world_id + 1 end
        if P.x == f.x and f.same_zone_jump then f.x = f.x + f.same_zone_jump end
    end
    function f.tick()
        f.now = f.now + 0.5
        local c = f.cast
        if c and f.now >= c.ends_at then
            f.cast = nil
            if not c.cut then
                if c.dest == 'temis' and f.warplan_temis_jump and c.warplan then f.x = f.x + f.warplan_temis_jump end
                f.go(c.dest, not f.keep_world_id)
                if f.buffs_clear_on_land then f.buffs = {} end
            end
        end
        if f.each then f.each() end
        f.o.tick()
    end
    function f.run(seconds) for _ = 1, math.floor(seconds / 0.5 + 0.5) do f.tick() end end
    function f.logged(text)
        local n = 0
        for _, m in ipairs(f.logs) do if m:find(text, 1, true) then n = n + 1 end end
        return n
    end
    return f
end

-- ── C1 ──────────────────────────────────────────────────────────────────────
case('C1 a 7 s War Plan channel is not re-fired: one call, landing confirmed', function()
    local f = fixture()
    local wc = f.plugin('WonderCityPlugin')
    f.warplan_channel = 7
    f.quests = {'WarPlans_QST_Undercity'}
    f.run(60)
    eq(f.warplan_calls, 1, 'one War Plan call for a 7 s channel')
    eq(wc.enables, 1, 'WonderCity enabled after the landing')
    eq(f.logged('teleport retry'), 1, 'the hold is logged once, no retry')
end)

case('C1 a same-zone (Temis) War Plan landing is recognised (new world_id)', function()
    local f = fixture()
    local wc = f.plugin('WonderCityPlugin')
    f.warplan_dest = 'temis'
    f.quests = {'WarPlans_QST_Undercity'}
    f.run(60)
    eq(f.warplan_calls, 1, 'one War Plan call for a Temis landing')
    eq(wc.enables, 1, 'WonderCity enabled')
    truthy(f.logged('teleport confirmed (world id') == 1, 'confirmed by the world_id change')
end)

case('C1 a same-zone landing without world_id: a finished cast with a position jump', function()
    local f = fixture({no_world_id = true})
    local wc = f.plugin('WonderCityPlugin')
    f.warplan_dest = 'temis'
    f.same_zone_jump = 120
    f.quests = {'WarPlans_QST_Undercity'}
    f.run(60)
    eq(f.warplan_calls, 1, 'one War Plan call')
    eq(wc.enables, 1, 'WonderCity enabled')
    truthy(f.logged('position jump after the cast') == 1, 'confirmed by the position jump')
end)

case('C1 a War Plan call that never casts is still retried and bounded (WPT-6)', function()
    local g = fixture()
    local wc = g.plugin('WonderCityPlugin')
    g.warplan_channel = 0   -- a silent no-op: no channel observed, no landing
    g.warplan_dest = 'temis'; g.keep_world_id = true
    g.quests = {'WarPlans_QST_Undercity'}
    g.run(120)
    eq(g.warplan_calls, 6, '1 + WARPLAN_MAX_RETRIES calls, then released')
    eq(wc.enables, 1, 'released to WonderCity')
end)

-- ── C2 ──────────────────────────────────────────────────────────────────────
case('C2 helltide-lingering fast retry never re-fires into its own Temis channel', function()
    local f = fixture({at = 'helltide'})
    f.plugin('WonderCityPlugin'); f.plugin('HelltideRevampedPlugin')
    f.buffs = {{name_hash = 1066539}}; f.buffs_clear_on_land = true
    f.wp_channel = 7
    f.quests = {'WarPlans_QST_Undercity'}
    f.run(30)
    eq(f.waypoints, 1, 'one Temis cast for a 7 s channel')
    truthy(f.logged('arrived in Temis') >= 1, 'arrived in Temis')
    eq(f.warplan_calls, 1, 'then one War Plan call')
end)

case('C2 helltide-lingering fast retries are capped, then the 30 s cadence', function()
    local f = fixture({at = 'helltide'})
    f.plugin('WonderCityPlugin'); f.plugin('HelltideRevampedPlugin')
    f.buffs = {{name_hash = 1066539}}
    f.wp_channel, f.wp_cut = 5, 2     -- every cast is cut by a hit after 2 s
    f.quests = {'WarPlans_QST_Undercity'}
    f.run(120)
    truthy(f.waypoints <= 12, 'Temis casts bounded in 120 s (got ' .. f.waypoints .. ')')
    eq(f.logged('fast retry 8/8'), 1, 'the cap is logged with the count')
    eq(f.logged('fast retry 9/'), 0)
end)

-- ── C3 ──────────────────────────────────────────────────────────────────────
case('C3 a Rosie hop back to Temis between samples is not a missed landing', function()
    local f = fixture()
    local wc = f.plugin('WonderCityPlugin')
    f.warplan_channel = 2
    local fired_at
    f.each = function()
        if f.warplan_calls == 1 and not fired_at then fired_at = f.now end
        if fired_at and f.now - fired_at >= 4 and f.zone == 'Kehj_Kurast' then f.go('temis') end -- Rosie hop
    end
    f.quests = {'WarPlans_QST_Undercity'}
    f.run(60)
    eq(f.warplan_calls, 1, 'no second War Plan call after the Rosie hop')
    eq(wc.enables, 1, 'WonderCity enabled')
end)

if #failures > 0 then
    error('WarPigs teleport cast failures:\n  ' .. table.concat(failures, '\n  '))
end
print('PASS WarPigs teleport casts: ' .. checks .. ' checks (C1 War Plan channel / same-zone landing, C2 Temis fast retry, C3 Rosie hop)')
