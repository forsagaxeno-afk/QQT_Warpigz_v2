-- Round 5, W5-4 (auditor NOT_DONE, round-3/4 critic regression 1): a user
-- pause is not a self-disable. An owned activity plugin that reports
-- enabled == false while its C2 in_run is true (HordeDev in the Horde, Arkham
-- in the Pit, ...) was paused by its hotkey: WarPigs arms no teleport, does
-- not re-enable it (which silently overrode the pause), shows
-- '<Plugin> paused by its hotkey — WarPigs waiting' and logs it once, and
-- resumes managing it when it reports enabled again. A real self-disable
-- (in_run false or no C2 in_run) keeps the old handling.
-- Part A: the real orchestrator with QQT-shaped host mocks. Part B: the joint
-- host with all nine real plugins (critic probe_horde_hotkey_joint for
-- HordeDev, the same pause for ArkhamAsylum).
local ROOT = assert(SUITE_ROOT)
local root = ROOT .. '/WarPigs-1.0.0/'
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

case('W5-4 an owned plugin paused by its hotkey (enabled false, C2 in_run true): no teleport, no re-enable, visible', function()
    for _, tp in ipairs({false, true}) do
        local label = tp and 'teleport on' or 'teleport off'
        local f = fixture({teleport = tp})
        local ark = f.plugin('ArkhamAsylumPlugin', {in_run = true})
        f.quests = {PIT}
        truthy(f.until_true(function() return ark.enables == 1 end, 5), label .. ': Arkham started in the Pit\n' .. f.dump())
        f.run(5)
        ark.enabled = false -- the user presses Arkham's hotkey inside the Pit
        f.run(30)
        eq(f.logged('detected self-disable'), 0, label .. ': not a self-disable')
        eq(ark.enables, 1, label .. ': not re-enabled (9e01f67: re-enabled after the 5 s gap)')
        eq(ark.disables, 0, label)
        eq(f.waypoints, 0, label .. ': no via-Temis teleport'); eq(f.teleports, 0, label .. ': no warplan teleport')
        eq(f.logged('teleport queued'), 0, label .. ': no teleport armed')
        eq(f.logged('ArkhamAsylumPlugin ' .. PAUSED), 1, label .. ': one log line')
        local line = f.o.get_status_line()
        truthy(line:find('ArkhamAsylumPlugin ' .. PAUSED, 1, true), label .. ': status line: ' .. line)
        truthy(line:find('managing ArkhamAsylumPlugin', 1, true), label .. ': still owned: ' .. line)
        -- The user resumes it: WarPigs manages it again, without an enable().
        ark.enabled = true
        f.run(2)
        eq(f.logged('ArkhamAsylumPlugin reports enabled again'), 1, label .. ': resume logged')
        eq(ark.enables, 1, label .. ': no enable() on resume')
        line = f.o.get_status_line()
        truthy(not line:find(PAUSED, 1, true) and line:find('managing ArkhamAsylumPlugin', 1, true), label .. ': ' .. line)
        -- A second pause is logged again (one line per pause).
        ark.enabled = false; f.run(3)
        eq(f.logged('ArkhamAsylumPlugin ' .. PAUSED), 2, label .. ': one line per pause')
        eq(ark.enables, 1, label)
    end
end)

case('W5-4 a real self-disable (in_run false, or no C2 in_run) keeps the old handling', function()
    for _, fields in ipairs({{in_run = false}, {}}) do
        local label = fields.in_run == false and 'in_run false' or 'no C2 in_run'
        local f = fixture()
        local ark = f.plugin('ArkhamAsylumPlugin', fields)
        f.quests = {PIT}
        truthy(f.until_true(function() return ark.enables == 1 end, 5), label .. ': started')
        ark.enabled = false
        f.tick()
        eq(f.logged('detected self-disable of ArkhamAsylumPlugin'), 1, label .. ': self-disable')
        eq(f.logged(PAUSED), 0, label)
        truthy(f.until_true(function() return ark.enables == 2 end, 8), label .. ': re-enabled after the gap')
    end
    -- 'Use teleport' on: the self-disable still arms the transition.
    local g = fixture({teleport = true})
    local ark = g.plugin('ArkhamAsylumPlugin', {in_run = false})
    g.quests = {PIT}
    truthy(g.until_true(function() return ark.enables == 1 end, 5), 'started in place')
    ark.enabled = false
    g.run(10)
    eq(g.logged('detected self-disable of ArkhamAsylumPlugin'), 1)
    -- teleport_pending was armed; the same Pit plan cancels it (continuation).
    eq(g.logged('ArkhamAsylumPlugin: same-activity continuation pattern='), 1, 'the handoff transition was armed\n' .. g.dump())
    eq(ark.enables, 2, 're-enabled in place after the gap')
end)

case('W5-4 paused when its quest vanishes: kept until the user resumes, then the normal loot-safe release', function()
    local f = fixture()
    local ark = f.plugin('ArkhamAsylumPlugin', {in_run = true})
    f.quests = {PIT}
    truthy(f.until_true(function() return ark.enables == 1 end, 5), 'started')
    ark.enabled = false
    f.run(2)
    -- The Pit plan is gone and the next plan (Undercity) is already visible.
    local wc = f.plugin('WonderCityPlugin', {in_run = false})
    f.quests = {'WarPlans_QST_Undercity'}
    f.run(20)
    eq(ark.disables, 0); eq(ark.enables, 1, 'not re-enabled')
    eq(f.logged('detected self-disable'), 0)
    eq(wc.enables, 0, 'the next activity waits for the paused one (no two activities at once)')
    truthy(f.o.is_busy(), 'WarPigs still owns the paused run (the plan creator waits)')
    truthy(f.o.get_status_line():find('ArkhamAsylumPlugin ' .. PAUSED, 1, true), f.o.get_status_line())
    -- C6: the held handoff reaches the watchdog; the pause is named once.
    f.run(50)
    local line = f.o.get_status_line()
    local _, shown = line:gsub('ArkhamAsylumPlugin paused by its hotkey', '')
    truthy(line:find('held', 1, true) and shown == 1, 'watchdog shows the pause once: ' .. line)
    eq(wc.enables, 0)
    -- Resumed in the Pit: released only once back in town (Arkham's disable_when).
    ark.enabled = true
    f.run(5)
    eq(ark.disables, 0, 'not in town yet')
    eq(wc.enables, 0)
    f.world, f.zone, f.town = 'Sanctuary_Eastern_Continent', 'Skov_Temis', true
    ark.st.in_run = false
    truthy(f.until_true(function() return ark.disables == 1 end, 5), 'released in town\n' .. f.dump())
    truthy(f.until_true(function() return wc.enables == 1 end, 8), 'then the next activity starts\n' .. f.dump())
    -- WarPigs' master stop while a plugin is paused releases it.
    local g = fixture()
    local a2 = g.plugin('ArkhamAsylumPlugin', {in_run = true})
    g.quests = {PIT}
    truthy(g.until_true(function() return a2.enables == 1 end, 5), 'started')
    a2.enabled = false
    g.run(2)
    g.o.release_all()
    eq(a2.disables, 1, 'released by the master stop')
    truthy(not g.o.get_status_line():find(PAUSED, 1, true), 'pause forgotten: ' .. g.o.get_status_line())
end)

-- ── part B: the joint host (all nine real plugins) ──────────────────────────
local J = dofile(ROOT .. '/audit/tests/joint_host.lua')
local WP, PUG, SR, HD, ARK = 'WarPigs-1.0.0', 'WarPug-1.0.0', 'SilentRaven-0.1.3', 'HordeDev-1.3.9', 'ArkhamAsylum-1.0.6'
local HORDE = 'WarPlans_QST_InfernalHordes_BSK'
local function el(h, dir) return assert(h.mod(dir, dir == SR and 'silent_raven.gui' or 'gui'), dir).elements end
local function joint(opts)
    local h = J.new({place = opts.place})
    h.assert_clean('load')
    h.instrument_exports()
    el(h, WP).main_toggle:set(true); el(h, PUG).main_toggle:set(true); el(h, SR).main_toggle:set(true)
    if opts.teleport then el(h, WP).use_teleport_transition:set(true) end
    if opts.warplan == false then el(h, WP).horde_warplan_entry:set(false) end
    return h
end
local function wp_calls(h, export, name, since)
    local n = 0
    for _, c in ipairs(h.api_calls) do
        if c.export == export and c.name == name and c.context == WP and c.t >= since then n = n + 1 end
    end
    return n
end
local function after(list, since)
    local n = 0
    for _, rec in ipairs(list) do if rec.t >= since then n = n + 1 end end
    return n
end
local function status_line(h) return h.as(WP, function() return h.mod(WP, 'core.orchestrator').get_status_line() end) end
local function status(h, export)
    local api = h.G[export]
    local fn = api.status or api.get_status
    return h.as(WP, function() return fn() end)
end

-- Critic probe_horde_hotkey_joint (round 3), in the nine-plugin host: the
-- user presses HordeDev's bound hotkey at wave 3. 9e01f67: 'detected
-- self-disable' — with 'Use teleport' on WarPigs left the Horde via Temis,
-- with it off WarPigs re-enabled HordeDev after the 5 s gap (the pause was
-- silently overridden).
case('W5-4 joint: HordeDev paused by its hotkey mid-horde: WarPigs waits, no teleport, no re-enable; resume finishes it', function()
    for _, v in ipairs({{warplan = true, teleport = false}, {warplan = true, teleport = true},
        {warplan = false, teleport = true}}) do
        local label = 'W5-4 ' .. (v.warplan and 'War Plan' or 'compass') .. (v.teleport and ', teleport on' or ', teleport off')
        local h = joint(v)
        el(h, HD).use_keybind:set(true); el(h, HD).keybind_toggle:set_key(0x70)
        h.give_compasses(3)
        local A = h.setup_horde({})
        h.warplan_dest = v.warplan and 'bsk' or 'caldeum'
        h.set_quests({HORDE})
        truthy(h.run_until(function() return A.wave >= 3 end, 300), label .. ': wave 3\n' .. h.tail())
        eq(status(h, 'InfernalHordesPlugin').enabled, true, label .. ': running')
        local items = #h.items
        el(h, HD).keybind_toggle.state = 0 -- the user presses HordeDev's bound hotkey
        local paused_at = h.now
        local shown
        h.run(20, function()
            if status_line(h):find('InfernalHordesPlugin ' .. PAUSED, 1, true) then shown = true end
        end)
        eq(status(h, 'InfernalHordesPlugin').enabled, false, label .. ': still paused (9e01f67 teleport off: re-enabled)')
        eq(h.logged('detected self-disable of InfernalHordesPlugin'), 0, label .. ': not a self-disable')
        eq(wp_calls(h, 'InfernalHordesPlugin', 'enable', paused_at), 0, label .. ': no re-enable')
        eq(wp_calls(h, 'InfernalHordesPlugin', 'disable', paused_at), 0, label)
        eq(after(h.waypoints, paused_at), 0, label .. ': no teleport_to_waypoint (9e01f67 teleport on: Temis)')
        eq(after(h.warplans, paused_at), 0, label .. ': no War Plan teleport')
        eq(h.place, h.P.bsk, label .. ': the player stays in the Horde')
        eq(h.logged('InfernalHordesPlugin ' .. PAUSED), 1, label .. ': one log line')
        truthy(shown, label .. ': status line shows the pause')
        -- The user resumes HordeDev with its hotkey: the same horde finishes.
        el(h, HD).keybind_toggle.state = 1
        truthy(h.run_until(function() return #h.quests == 0 end, 300), label .. ': horde and turn-in\n' .. h.tail())
        h.run(3)
        h.assert_clean(label)
        eq(h.logged('InfernalHordesPlugin reports enabled again'), 1, label .. ': resume logged')
        eq(A.runs, 1, label .. ': the same horde'); eq(A.wave, 6, label); truthy(A.council_dead_at, label)
        eq(wp_calls(h, 'InfernalHordesPlugin', 'enable', paused_at), 0, label .. ': resumed without an enable()')
        eq(#h.items, items, label .. ': no compass after the pause')
        eq(h.logged('turn-in cycle completed'), 1, label .. ': turn-in')
    end
end)

-- The same pause for ArkhamAsylum in the Pit (C2 in_run: in the Pit).
-- 9e01f67: 'detected self-disable', Arkham re-enabled after the 5 s gap.
case('W5-4 joint: Arkham paused by its hotkey in the Pit: WarPigs waits; resume continues the Pit run', function()
    for _, tp in ipairs({false, true}) do
        local label = 'W5-4 Arkham ' .. (tp and 'teleport on' or 'teleport off')
        local h = joint({place = 'pit', teleport = tp})
        el(h, ARK).use_keybind:set(true); el(h, ARK).keybind_toggle:set_key(0x70)
        for i = 1, 4 do h.actor('pit', 'Pit_Monster_' .. i, 20 + i * 15, (i % 2) * 6, {enemy = true}) end
        h.set_quests({'WarPlans_QST_ThePit'})
        truthy(h.run_until(function() return status(h, 'ArkhamAsylumPlugin').enabled == true end, 10), label .. ': started')
        h.run(5)
        el(h, ARK).keybind_toggle.state = 0 -- the user presses Arkham's bound hotkey
        local paused_at = h.now
        h.run(1)
        local st = status(h, 'ArkhamAsylumPlugin')
        eq(st.enabled, false, label .. ': paused'); eq(st.in_run, true, label .. ': C2 in_run (in the Pit)')
        h.run(20)
        eq(status(h, 'ArkhamAsylumPlugin').enabled, false, label .. ': still paused (9e01f67: re-enabled after 5 s)')
        eq(h.logged('detected self-disable of ArkhamAsylumPlugin'), 0, label)
        eq(wp_calls(h, 'ArkhamAsylumPlugin', 'enable', paused_at), 0, label .. ': no re-enable')
        eq(after(h.waypoints, paused_at), 0, label .. ': no teleport'); eq(after(h.warplans, paused_at), 0, label)
        eq(h.place, h.P.pit, label .. ': still in the Pit')
        eq(h.logged('ArkhamAsylumPlugin ' .. PAUSED), 1, label .. ': one log line')
        truthy(status_line(h):find('ArkhamAsylumPlugin ' .. PAUSED, 1, true), label .. ': ' .. status_line(h))
        el(h, ARK).keybind_toggle.state = 1
        local resumed_at = h.now
        h.run(6)
        h.assert_clean(label)
        eq(status(h, 'ArkhamAsylumPlugin').enabled, true, label .. ': resumed')
        eq(h.logged('ArkhamAsylumPlugin reports enabled again'), 1, label .. ': resume logged')
        eq(wp_calls(h, 'ArkhamAsylumPlugin', 'enable', paused_at), 0, label .. ': no enable() on resume')
        local drove = false
        for _, c in ipairs(h.bm_calls) do if c.context == ARK and c.t > resumed_at then drove = true end end
        truthy(drove, label .. ': Arkham drives again after the resume')
        truthy(status_line(h):find('managing ArkhamAsylumPlugin', 1, true), label .. ': ' .. status_line(h))
    end
end)

if #failures > 0 then error(#failures .. ' WarPigs user-pause regressions failed:\n' .. table.concat(failures, '\n\n')) end
print('PASS WarPigs user pause (W5-4): ' .. checks .. ' checks')
