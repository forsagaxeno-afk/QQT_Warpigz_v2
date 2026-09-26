-- Joint suite: ALL NINE plugins loaded together in one emulated QQT host
-- (audit/tests/joint_host.lua): per-plugin require caches, one shared _G,
-- callbacks in alphabetical folder order, caller-context require detection.
-- Scenarios:
--   1 load: exports, exact global set, consumer-referenced API, detector
--     self-test
--   2 Temis: 60 s idle, persisted activity toggles, Whisper -> plan ->
--     dispatch, Looter bursts around the claim (L7), Alfred hard/unreadable
--   3 cross-plugin API sweep from WarPigs' context (every consumer-referenced
--     export member), status reads from every plugin context
--   4 handoffs: Pit -> Undercity, Undercity -> Helltide, Horde -> turn-in ->
--     next plan, Arkham's own Alfred trip, Reaper dispatch, via-Temis Alfred
--     preamble, sticky restock flag
--   5 master stop (toggle and API), re-enable in place, adoption, death
--   6 Infernal Hordes War Plan entry (round 4): J1/J2 War Plan teleport ->
--     HordeDev in War Plan mode -> 6 scripted waves -> Council -> chests (or
--     none) -> exit -> turn-in, with 'Use teleport' off/on; J3 missed
--     teleports, backoff, compass fallback; J4 persisted HordeDev toggle;
--     J5 hotkey pause mid-horde; J6 Horde -> turn-in -> Pit in one Temis
--     visit; J7 standalone compass farming
-- Regressions for the defects this suite found are marked "Found by this
-- suite". Runs under Lua 5.4 and LuaJIT (run_tests.py runs both).
local ROOT = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local J = dofile(ROOT .. '/audit/tests/joint_host.lua')
local checks, failures, cases = 0, {}, 0
local report = {}
local function ok(value, message)
    if not value then error(message or 'expected a true value', 2) end
    checks = checks + 1
end
local function eq(actual, expected, message)
    if actual ~= expected then
        error((message or 'mismatch') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
    end
    checks = checks + 1
end
-- JOINT_ONLY=<text> (developer convenience) runs only the scenarios whose
-- name contains <text>; run_tests.py never sets it.
local ONLY = os.getenv('JOINT_ONLY')
local function case(name, fn)
    if ONLY and ONLY ~= '' and not name:find(ONLY, 1, true) then return end
    cases = cases + 1
    local started = os.clock()
    local passed, err = xpcall(fn, debug.traceback)
    if passed then
        print(string.format('PASS joint: %s (%.1fs)', name, os.clock() - started))
    else
        failures[#failures + 1] = name .. ': ' .. tostring(err)
        print('FAIL joint: ' .. name .. ': ' .. tostring(err))
    end
end
local function note(line)
    for _, seen in ipairs(report) do if seen == line then return end end
    report[#report + 1] = line
end

local WP, PUG, SR, BAT = 'WarPigs-1.0.0', 'WarPug-1.0.0', 'SilentRaven-0.1.3', 'Batmobile-1.0.12'
local ARK, WC, HR, HD, RP = 'ArkhamAsylum-1.0.6', 'WonderCity-main', 'HelltideRevamped-0.4', 'HordeDev-1.3.9', 'Reaper-main'
local ACTIVITY_EXPORTS = {ArkhamAsylumPlugin = ARK, WonderCityPlugin = WC, HelltideRevampedPlugin = HR,
    InfernalHordesPlugin = HD, ReaperPlugin = RP}

local function el(h, dir)
    local mod = dir == SR and 'silent_raven.gui' or 'gui'
    return assert(h.mod(dir, mod), 'gui of ' .. dir).elements
end
-- The configuration the README asks for: SilentRaven and WarPug on, WarPigs
-- on with Whispers in Temis (default), activity plugins left to WarPigs.
local function setup(opts)
    opts = opts or {}
    local h = J.new(opts)
    h.assert_clean('load')
    h.instrument_exports()
    el(h, WP).main_toggle:set(opts.warpigs ~= false)
    el(h, PUG).main_toggle:set(opts.warpug ~= false)
    el(h, SR).main_toggle:set(opts.raven ~= false)
    if opts.teleport then el(h, WP).use_teleport_transition:set(true) end
    if opts.orb then
        for _, dir in ipairs({WP, ARK, WC, HR, RP}) do el(h, dir).manage_orbwalker:set(true) end
    end
    if opts.quests then h.set_quests(opts.quests) end
    return h
end
local function status(h, export)
    local api = h.G[export]
    local fn = api.status or api.get_status
    return h.as(WP, function() return fn() end)
end
local function enabled(h, export) return status(h, export).enabled == true end
local function bm(h) return h.G.BatmobilePlugin end
-- Batmobile navigator state that must not survive a hand-off (C3).
local function bm_state(h)
    local nav, lp = h.mod(BAT, 'core.navigator'), h.mod(BAT, 'core.long_path')
    local ex = h.mod(BAT, 'core.explorer')
    return {owner = h.as(WP, function() return bm(h).get_owner() end), target = nav.target,
        custom = nav.is_custom_target, long = lp.navigating, route_owner = lp.owner,
        priority = ex.priority, default_priority = ex.default_priority or 'direction',
        trav = nav.last_trav, trav_final = nav.trav_final_target, escape = nav.trav_escape_pos,
        paused = nav.paused, path = #(nav.path or {})}
end
local function assert_released(h, label, owner)
    local s = bm_state(h)
    ok(s.owner ~= owner, label .. ': Batmobile still owned by ' .. tostring(s.owner))
    eq(s.target, nil, label .. ': stale Batmobile target')
    ok(s.custom ~= true, label .. ': stale custom target flag')
    eq(s.long, false, label .. ': stale long path')
    eq(s.priority, s.default_priority, label .. ': explorer priority not restored')
    eq(s.trav_final, nil, label .. ': stale traversal routing')
    eq(s.escape, nil, label .. ': stale traversal escape')
end
local function first(list, pred)
    for _, rec in ipairs(list) do if pred(rec) then return rec end end
    return nil
end
local function last(list, pred)
    for i = #list, 1, -1 do if pred(list[i]) then return list[i] end end
    return nil
end
local function log_time(h, text)
    for _, line in ipairs(h.log) do
        if line:find(text, 1, true) then return tonumber(line:match('^(%-?[%d%.]+)')) end
    end
    return nil
end
local function check_globals(h, label)
    for _, name in ipairs(h.new_globals()) do
        if J.UPSTREAM_GLOBALS[name] then
            note('pre-existing upstream global written: ' .. name)
        else
            ok(J.EXPORTS[name] ~= nil, label .. ': unexpected new global ' .. name)
        end
    end
    for name in pairs(h.missing) do note('undefined global read (' .. label .. '): ' .. name) end
    for _, key in ipairs(h.stdlib_additions()) do
        ok(key == 'table.contains', label .. ': unexpected standard-library mutation ' .. key)
        note('shared standard library mutated: ' .. key .. ' (HordeDev core/utils.lua, pre-existing)')
    end
end
local function context_calls(h, dir, place)
    local n = 0
    for _, c in ipairs(h.bm_calls) do
        if c.context == dir and (place == nil or c.place == place) then n = n + 1 end
    end
    for _, m in ipairs(h.moves) do
        if m.context == dir and (place == nil or m.from == place) then n = n + 1 end
    end
    return n
end

-- ═══ 1. Load ═════════════════════════════════════════════════════════════════
local EXPORT_API = {
    BatmobilePlugin = {'pause', 'resume', 'reset', 'reset_movement', 'move', 'update', 'set_target',
        'clear_target', 'set_priority', 'find_long_path', 'navigate_long_path', 'is_long_path_navigating',
        'stop_long_path', 'get_target', 'get_path', 'get_last_pathfind', 'clear_traversal_blacklist',
        'is_giving_up', 'is_trapped', 'clear_giving_up', 'release', 'get_owner', 'is_done', 'is_paused',
        'get_closeby_node', 'try_traversal_route', 'is_traversal_routing', 'get_backtrack'},
    ArkhamAsylumPlugin = {'get_status', 'enable', 'disable'},
    WonderCityPlugin = {'get_status', 'enable', 'disable'},
    HelltideRevampedPlugin = {'enable', 'disable', 'status', 'getSettings', 'setSettings', 'getState'},
    InfernalHordesPlugin = {'enable', 'disable', 'status', 'getState', 'chests_done', 'getSettings', 'setSettings'},
    ReaperPlugin = {'enable', 'disable', 'run_boss', 'run_once', 'clear_external', 'status'},
    SilentRavenPlugin = {'get_status', 'is_available', 'set_managed', 'pause', 'resume', 'trigger_tasks',
        'trigger_tasks_with_teleport', 'cancel', 'check_version'},
    WarPigsPlugin = {'enable', 'disable', 'status'},
    WarPugPlugin = {'status'},
}

-- Every `Export.member` / `Export:member` a runtime file references.
local function referenced_members()
    local refs = {}
    local list = io.popen and io.popen('find "' .. ROOT .. '" -name "*.lua" -not -path "*/audit/*"')
    local files = {}
    if list then
        for path in list:lines() do files[#files + 1] = path end
        list:close()
    end
    for _, path in ipairs(files) do
        local f = io.open(path, 'r')
        if f then
            for line in f:lines() do
                local code = line:gsub('%-%-.*$', '')
                for export, member in code:gmatch('([%w_]+Plugin)[%.:]([%a_][%w_]*)') do
                    if J.EXPORTS[export] and not path:find('/' .. J.EXPORTS[export] .. '/', 1, true) then
                        refs[export .. '.' .. member] = path:sub(#ROOT + 2)
                    end
                end
                for member in code:gmatch('PLUGIN_silent_raven[%.:]([%a_][%w_]*)') do
                    refs['SilentRavenPlugin.' .. member] = path:sub(#ROOT + 2)
                end
            end
            f:close()
        end
    end
    return refs, #files
end

case('1 load: all nine plugins load together, documented exports, exact global set', function()
    local h = J.new()
    h.assert_clean('load')
    eq(#h.plugins, 9, 'plugin folders')
    for _, rec in ipairs(h.plugins) do
        ok(#rec.update >= 1, rec.name .. ' registered no on_update')
        ok(#rec.menu >= 1, rec.name .. ' registered no on_render_menu')
    end
    ok(h.global_writes[1] ~= nil, 'global writes recorded')
    for export, dir in pairs(J.EXPORTS) do
        ok(type(h.G[export]) == 'table', 'export ' .. export .. ' missing')
        local writer = first(h.global_writes, function(w) return w.name == export end)
        eq(writer and writer.owner, dir, export .. ' written by its own plugin')
        ok(writer.at_load, export .. ' exported at load time')
    end
    eq(h.G.PLUGIN_silent_raven, h.G.SilentRavenPlugin, 'SilentRaven legacy alias')
    for export, api in pairs(EXPORT_API) do
        for _, fn in ipairs(api) do
            eq(type(h.G[export][fn]), 'function', export .. '.' .. fn)
        end
    end
    -- The set of new _G keys equals the documented export set.
    local new, expected = h.new_globals(), {}
    for export in pairs(J.EXPORTS) do expected[#expected + 1] = export end
    table.sort(expected)
    eq(table.concat(new, ','), table.concat(expected, ','), 'new globals after load')
    check_globals(h, 'load')
    eq(#h.file_writes, 0, 'no plugin writes a file while loading')
    -- Every cross-plugin member referenced in source exists on the export.
    local refs, nfiles = referenced_members()
    if nfiles == 0 then
        note('source scan for consumer-referenced exports skipped: io.popen unavailable')
    else
        local n = 0
        for ref, where in pairs(refs) do
            local export, member = ref:match('^([%w_]+)%.([%w_]+)$')
            ok(h.G[export][member] ~= nil, ref .. ' referenced by ' .. where .. ' is not exported')
            n = n + 1
        end
        ok(n >= 20, 'consumer references found: ' .. n)
    end
    -- QQT would print these as undefined reads; only optional companions are expected.
    for name in pairs(h.missing) do note('undefined global read at load: ' .. name) end
end)

case('1 load: the caller-context detector records a foreign require (self-test)', function()
    local h = J.new()
    h.assert_clean('load')
    -- A function owned by Batmobile's folder that requires lazily.
    local probe = assert(load("return function() return require('core.settings'), package.loaded end",
        '@' .. ROOT .. '/' .. BAT .. '/core/joint_probe.lua', 't', h.G))()
    local own_settings = h.as(BAT, probe)
    eq(#h.violations, 0, 'own-context require is clean')
    eq(own_settings, h.mod(BAT, 'core.settings'), 'own context resolves its own module')
    local foreign = h.as(WP, probe)
    ok(#h.violations >= 2, 'foreign require and package read recorded')
    local v = h.violations[1]
    eq(v.kind, 'caller-context require')
    eq(v.context, WP); eq(v.owner, BAT)
    ok(v.trace:find('joint_probe', 1, true) ~= nil, 'stack recorded')
    -- The QQT hazard itself: WarPigs' settings module comes back.
    eq(foreign, h.mod(WP, 'core.settings'), 'QQT resolves the module of the running plugin')
    local passed = pcall(h.assert_clean, 'probe')
    eq(passed, false, 'assert_clean fails on a violation')
    -- Real plugin code: SilentRaven's catalog timestamp reloads its data
    -- module lazily. Only SilentRaven calls it (clean); from WarPigs' callback
    -- the same call would resolve WarPigs' module in QQT.
    local g = J.new()
    local rewards = g.mod(SR, 'silent_raven.rewards')
    g.as(SR, function() return pcall(rewards.last_sync_epoch) end)
    eq(#g.violations, 0, 'own-context lazy require is clean')
    g.now = g.now + 3600 -- past its read cache
    g.as(WP, function() return pcall(rewards.last_sync_epoch) end)
    local lazy = first(g.violations, function(x) return x.kind == 'caller-context require' end)
    ok(lazy ~= nil and lazy.owner == SR and lazy.context == WP
        and lazy.detail:find('silent_raven.data.last_sync', 1, true) ~= nil, 'real lazy require detected')
end)

-- ═══ 2. Temis ════════════════════════════════════════════════════════════════
case('2 Temis idle 60 s: managers on, activity plugins off, no plan table in stream', function()
    local h = setup({})
    h.remove_actor(h.table_actor)
    h.run(60)
    h.assert_clean('idle')
    check_globals(h, 'idle')
    eq(#h.waypoints, 0, 'teleports while idle')
    eq(#h.warplans, 0, 'warplan calls while idle')
    eq(h.logged('visit 1: skipped_not_ready'), 1, 'one Whisper check per Temis visit')
    eq(h.logged('visit 2'), 0, 'no repeated Whisper visit')
    eq(h.G.WarPugPlugin.status().state, 'APPROACH_TABLE', 'WarPug waits for the plan table')
    ok(h.logged('Waiting for war plan table actor') >= 5, 'WarPug diagnostics')
    eq(bm_state(h).owner, nil, 'nobody owns Batmobile')
    eq(#h.orb_log, 0, 'orbwalker untouched')
    for export in pairs(ACTIVITY_EXPORTS) do eq(enabled(h, export), false, export .. ' stays off') end
    -- render and menu callbacks of every plugin ran every frame
    for _, rec in ipairs(h.plugins) do
        eq(h.calls[rec.name .. ':on_update'], h.frames * #rec.update, rec.name .. ' on_update calls')
        eq(h.calls[rec.name .. ':on_render_menu'], h.frames * #rec.menu, rec.name .. ' menu calls')
        if #rec.render > 0 then eq(h.calls[rec.name .. ':on_render'], h.frames * #rec.render, rec.name .. ' render') end
    end
    ok((h.widgets_rendered or 0) > h.frames * 20, 'menu widgets rendered')
    ok((h.graphics_used.text_2d or 0) > 0, 'status overlays drawn')
    local line = h.as(WP, function() return h.G.WarPigsPlugin.status() end)
    eq(line.enabled, true); eq(line.busy, false, 'WarPigs idle'); eq(line.manages_whispers, true)
end)

case('2 Temis start with activity toggles persisted on: WarPigs turns them off on its first tick', function()
    local h = setup({})
    h.remove_actor(h.table_actor)
    for export, dir in pairs(ACTIVITY_EXPORTS) do el(h, dir).main_toggle:set(true) end
    h.run(1)
    for export in pairs(ACTIVITY_EXPORTS) do eq(enabled(h, export), false, export .. ' disabled by WarPigs') end
    local early = #h.waypoints
    for _, w in ipairs(h.waypoints) do
        note(string.format('persisted toggle: %s fired teleport_to_waypoint(0x%X) in its first frame, before '
            .. "WarPigs' first tick (README: avoid starting activity controllers yourself)", w.owner, w.sno))
    end
    ok(early <= 2, 'first-frame teleports bounded: ' .. early)
    -- F-H2 (round 4): HordeDev waits for WarPigs' first decision (J4).
    eq(h.count(h.waypoints, function(w) return w.context == HD end), 0, 'no HordeDev first-frame Library teleport')
    h.run(30)
    eq(#h.waypoints, early, 'no teleport after WarPigs took over')
    h.assert_clean('persisted')
end)

case('2 Temis session: Whisper claim -> WarPug plan -> WarPigs enables the Pit', function()
    local h = setup({})
    h.bounty_ready = true
    h.on_confirm = function(path)
        h.at(1.0, function() h.set_quests({'WarPlans_QST_ThePit'}) end)
    end
    local enabled_at = nil
    ok(h.run_until(function()
        if not enabled_at and h.logged('enabled ArkhamAsylumPlugin') > 0 then enabled_at = h.now end
        return enabled_at ~= nil and h.now - enabled_at > 12
    end, 90), 'Pit dispatched within 90 s\n' .. h.tail())
    h.assert_clean('session')
    eq(h.reward_accepts, 1, 'one Whisper reward claimed')
    eq(h.logged('visit 1: success'), 1, 'WarPigs bridge reports the claim')
    eq(h.board.confirmed, 1, 'one war plan submitted')
    local claimed_at, planned_at = log_time(h, 'visit 1: success'), log_time(h, '[WarPug] state IDLE -> ')
    ok(claimed_at and planned_at and planned_at >= claimed_at, 'WarPug waited for the Whisper claim')
    ok(h.logged('HALTED') == 0, 'WarPug never halted')
    eq(h.G.WarPugPlugin.status().state, 'IDLE', 'WarPug idle once the plan quest is active')
    eq(#h.waypoints, 0, 'no teleports (Use teleport off, Pit tower in Temis)')
    ok(h.place == h.P.pit, 'Arkham entered the pit: ' .. h.place.zone)
    ok(first(h.bm_calls, function(c) return c.context == ARK end) ~= nil, 'Arkham drives Batmobile')
    eq(first(h.bm_calls, function(c) return c.context == ARK and c.t < enabled_at end), nil,
        'no Arkham movement before WarPigs enabled it')
    check_globals(h, 'session')
end)

-- L7 in the joint host: LooteerV3 approach_stall bursts (~1 s every 5-7 s,
-- live log) around the managed Whisper claim, plus one burst right after
-- accept. Found by this suite: the bridge cancelled the request once accept
-- was sent, so a reward that was claimed reported 'cancelled', was
-- re-requested twice in the visit and WarPug started ~11 s late.
case('2 Temis Whisper claim during Looter bursts: paused before accept, success after accept, no re-requests', function()
    local h = setup({})
    h.bounty_ready = true
    local t0, bursts, accept_burst = h.now, {{2, 3}, {8, 9}, {21, 22}, {27, 28}}, nil
    local sr_moves_busy = 0
    ok(h.run_until(function()
        local rel, busy = h.now - t0, false
        for _, w in ipairs(bursts) do if rel >= w[1] and rel < w[2] then busy = true end end
        local st = h.G.SilentRavenPlugin.get_status()
        if st.state == 'API_CLAIMING' and not accept_burst then accept_burst = h.now end
        if accept_burst and h.now - accept_burst < 1.2 then busy = true end
        h.looter.busy = busy
        return h.logged('[WarPug] state IDLE -> APPROACH_TABLE') > 0
    end, 90, function()
        if h.looter.busy then
            sr_moves_busy = sr_moves_busy + h.count(h.moves, function(m) return m.context == SR and m.t == h.now end)
        end
    end), 'WarPug started planning\n' .. h.tail())
    h.assert_clean('looter bursts')
    ok(accept_burst ~= nil, 'the claim reached accept')
    eq(h.reward_accepts, 1, 'one reward accepted')
    eq(h.logged('pausing the Whisper request'), 1, 'the walk paused for a burst before accept')
    eq(h.logged('checking completed Whispers in Temis'), 1, 'one managed request in the visit')
    eq(h.logged('retrying when companions are clear'), 0, 'no re-request of a claimed reward')
    eq(h.logged('run finished: success'), 1, 'SilentRaven verified the claim')
    eq(h.logged('visit 1: success'), 1, 'WarPigs reports the claim')
    eq(sr_moves_busy, 0, 'SilentRaven never moved while the Looter was busy')
    local done, planned = log_time(h, 'visit 1: success'), log_time(h, '[WarPug] state IDLE -> APPROACH_TABLE')
    ok(planned - done <= 3, string.format('WarPug starts %.1fs after the claim', planned - done))
end)

-- C1 across the town readers (WarPigs, its Whisper bridge, WarPug, Arkham):
-- a hard need is serviced once by WarPigs and waited for; an unreadable
-- Alfred holds every reader at most 10 s, then the chain continues.
for _, mode in ipairs({'hard', 'unreadable'}) do
    case('2 Temis session with Alfred ' .. mode .. ': bounded holds, one chain, pit entered', function()
        local h = setup({})
        h.bounty_ready = true
        if mode == 'hard' then h.alfred.inventory_full, h.alfred.need_trigger = true, true end
        if mode == 'unreadable' then h.alfred.unreadable = true end
        h.on_confirm = function() h.at(1.0, function() h.set_quests({'WarPlans_QST_ThePit'}) end) end
        ok(h.run_until(function() return h.place == h.P.pit end, 90), 'pit entered\n' .. h.tail())
        h.assert_clean(mode)
        eq(h.reward_accepts, 1, 'Whisper claimed'); eq(h.board.confirmed, 1, 'plan submitted')
        eq(#h.waypoints, 0, 'no teleports')
        local claimed = log_time(h, 'visit 1: success')
        if mode == 'hard' then
            eq(h.count(h.alfred.triggers), 1, 'one Alfred cycle (WarPigs kick in Temis)')
            eq(h.alfred.triggers[1].context, WP)
            ok(claimed >= h.alfred.triggers[1].t + h.alfred.work, 'Whisper walk after the Alfred cycle')
        else
            eq(h.count(h.alfred.triggers), 0, 'unreadable Alfred is never triggered')
            ok(h.logged('Alfred unavailable — status unreadable for 10s') == 1, 'WarPigs gives up after 10 s')
            ok(claimed - 1000 <= 25, string.format('Whisper claimed %.0fs after the start (10 s bound)', claimed - 1000))
            ok(h.logged('[alfred] Alfred status unreadable for 10s') <= 1, 'Arkham logs its bound once')
        end
    end)
end

-- ═══ 3. API sweep ════════════════════════════════════════════════════════════
-- `strict`: the host already ticked, so SilentRaven accepts a request.
local function sweep_calls(h, strict)
    local G = h.G
    local target = h.v(2560, -470)
    local calls = {}
    local function add(name, fn) calls[#calls + 1] = {name, fn} end
    -- Batmobile, as the five consumers call it (their own caller labels).
    for _, label in ipairs({'arkham_asylum', 'wonder_city', 'helltide_revamped', 'infernal_horde', 'Reaper'}) do
        local B = G.BatmobilePlugin
        add(label .. ' pause/resume', function() B.pause(label); B.resume(label) end)
        add(label .. ' set_target/update/move', function() B.set_target(label, target); B.update(label); B.move(label) end)
        add(label .. ' getters', function() return B.get_target(), B.get_path(), B.get_owner(), B.is_done(),
            B.is_paused(), B.is_giving_up(), B.is_trapped(), B.is_traversal_routing(), B.get_last_pathfind() end)
        add(label .. ' long path', function()
            B.find_long_path(label, target); B.navigate_long_path(label, target)
            B.is_long_path_navigating(); B.stop_long_path(label)
        end)
        add(label .. ' nodes/backtrack', function() B.get_closeby_node(label, target, 5); B.get_backtrack(label) end)
        add(label .. ' traversal/giving up', function()
            B.try_traversal_route(label); B.clear_traversal_blacklist(label); B.clear_giving_up(label)
        end)
        add(label .. ' priority/clear/reset', function()
            B.set_priority(label, 'direction'); B.clear_target(label); B.reset_movement(label); B.reset(label)
        end)
        add(label .. ' release', function() B.release(label) end)
    end
    -- Activity plugins, as WarPigs / HordeDev / SilentRaven / WarPug use them.
    add('Arkham get_status/enable/disable', function()
        G.ArkhamAsylumPlugin.get_status(); G.ArkhamAsylumPlugin.enable(); G.ArkhamAsylumPlugin.get_status()
        G.ArkhamAsylumPlugin.disable()
    end)
    add('WonderCity get_status/enable/disable', function()
        G.WonderCityPlugin.get_status(); G.WonderCityPlugin.enable(); G.WonderCityPlugin.get_status()
        G.WonderCityPlugin.disable()
    end)
    add('Helltide status/getState/getSettings/enable/disable', function()
        local H = G.HelltideRevampedPlugin
        H.status(); H.getState(); H.getSettings('enabled'); H.enable(); H.status(); H.disable()
    end)
    add('HordeDev status/getState/chests_done/getSettings/enable/disable', function()
        local D = G.InfernalHordesPlugin
        D.status(); D.getState(); D.chests_done(); D.getSettings('enabled'); D.enable(); D.status(); D.disable()
    end)
    add('Reaper run_once/status/clear_external/disable', function()
        local R, result = G.ReaperPlugin, nil
        assert(R.run_once('andariel', nil, function(r) result = r end) == true, 'run_once accepted')
        R.status(); R.clear_external(); R.disable()
        assert(result == 'cancelled', 'run_once callback reports cancelled: ' .. tostring(result))
    end)
    add('Reaper run_boss/refusal/disable', function()
        local R = G.ReaperPlugin
        R.run_boss('zir'); R.status(); R.disable()
        local accepted, why = R.run_once('belial')
        assert(accepted == false and why == 'belial_chest_disabled', 'Belial one-shot refused: ' .. tostring(why))
        R.enable(); R.disable()
    end)
    add('SilentRaven managed request lifecycle', function()
        local S = G.SilentRavenPlugin
        S.get_status(); S.is_available(); S.check_version('0.1.0')
        assert(S.set_managed('WarPigs', true) == true, 'set_managed')
        local queued, why = S.trigger_tasks('WarPigs', function() end, function() return true end)
        assert(queued == true or (not strict and queued == false and type(why) == 'string'),
            'trigger_tasks: ' .. tostring(queued) .. ' ' .. tostring(why))
        S.get_status()
        if queued then assert(S.cancel('WarPigs') == true, 'cancel') end
        S.set_managed('WarPigs', false); S.pause('WarPigs'); S.resume('WarPigs')
        S.trigger_tasks_with_teleport('Probe', function() end); S.cancel('Probe')
    end)
    add('WarPug status', function() return G.WarPugPlugin.status() end)
    add('WarPigs status/enable/disable', function()
        G.WarPigsPlugin.status(); G.WarPigsPlugin.enable(); G.WarPigsPlugin.status(); G.WarPigsPlugin.disable()
    end)
    return calls
end
local STATUS_READERS = {
    {'WarPigsPlugin', 'status'}, {'WarPugPlugin', 'status'}, {'SilentRavenPlugin', 'get_status'},
    {'PLUGIN_silent_raven', 'get_status'}, {'ArkhamAsylumPlugin', 'get_status'}, {'WonderCityPlugin', 'get_status'},
    {'HelltideRevampedPlugin', 'status'}, {'InfernalHordesPlugin', 'status'}, {'ReaperPlugin', 'status'},
    {'BatmobilePlugin', 'get_owner'}, {'BatmobilePlugin', 'is_long_path_navigating'},
    {'InfernalHordesPlugin', 'chests_done'}, {'InfernalHordesPlugin', 'getState'},
}

case('3 API sweep from WarPigs context on a freshly loaded host', function()
    local h = setup({warpigs = false, warpug = false})
    local failed = {}
    for _, call in ipairs(sweep_calls(h)) do
        local passed, err = pcall(h.as, WP, call[2])
        if not passed then failed[#failed + 1] = call[1] .. ': ' .. tostring(err) end
    end
    eq(#failed, 0, 'API calls failed:\n' .. table.concat(failed, '\n'))
    h.assert_clean('sweep')
    -- Every export member another plugin's source references was swept.
    local swept = {}
    for _, c in ipairs(h.api_calls) do
        if c.context == WP then swept[c.export .. '.' .. c.name] = true end
    end
    local refs, nfiles = referenced_members()
    -- Calls made through _G[name] / call(p, 'name') / aliases, which the
    -- source scan cannot see: WarPigs' dispatcher and bridge, WarPug's and
    -- SilentRaven's companion reads, HordeDev's and Arkham's WarPigs reads.
    for _, ref in ipairs({'SilentRavenPlugin.get_status', 'SilentRavenPlugin.set_managed',
        'SilentRavenPlugin.trigger_tasks', 'SilentRavenPlugin.cancel', 'WarPugPlugin.status', 'WarPigsPlugin.status',
        'ArkhamAsylumPlugin.enable', 'ArkhamAsylumPlugin.disable', 'ArkhamAsylumPlugin.get_status',
        'WonderCityPlugin.enable', 'WonderCityPlugin.disable', 'WonderCityPlugin.get_status',
        'HelltideRevampedPlugin.enable', 'HelltideRevampedPlugin.disable', 'HelltideRevampedPlugin.status',
        'InfernalHordesPlugin.enable', 'InfernalHordesPlugin.disable', 'InfernalHordesPlugin.status',
        'InfernalHordesPlugin.chests_done', 'InfernalHordesPlugin.getState', 'ReaperPlugin.run_boss',
        'ReaperPlugin.disable', 'ReaperPlugin.clear_external'}) do
        refs[ref] = refs[ref] or 'dynamic call'
    end
    local missing = {}
    for ref, where in pairs(refs) do
        if not swept[ref] then missing[#missing + 1] = ref .. ' (' .. where .. ')' end
    end
    table.sort(missing)
    if nfiles == 0 then note('static source scan unavailable (io.popen); dynamic cross-plugin calls still checked') end
    eq(#missing, 0, 'consumer-referenced API not swept: ' .. table.concat(missing, ', '))
    -- Status readers from every plugin context (WarPug, SilentRaven and
    -- HordeDev read WarPigs; SilentRaven reads WarPug; WarPigs reads all).
    for _, rec in ipairs(h.plugins) do
        for _, reader in ipairs(STATUS_READERS) do
            local passed, err = pcall(h.as, rec, function() return h.G[reader[1]][reader[2]]() end)
            ok(passed, rec.name .. ' -> ' .. reader[1] .. '.' .. reader[2] .. ': ' .. tostring(err))
        end
    end
    h.assert_clean('status readers')
    -- The sweep leaves a consistent suite: nothing runs, nothing breaks.
    el(h, WP).main_toggle:set(true)
    h.run(10)
    h.assert_clean('after sweep')
    for export in pairs(ACTIVITY_EXPORTS) do eq(enabled(h, export), false, export .. ' off after the sweep') end
    check_globals(h, 'sweep')
end)

case('3 API sweep repeated in Temis with every plugin ticking (WarPigs off, SilentRaven unmanaged)', function()
    local h = setup({warpigs = false})
    h.remove_actor(h.table_actor)
    h.run(6)
    local failed = {}
    for _, call in ipairs(sweep_calls(h, true)) do
        local passed, err = pcall(h.as, WP, call[2])
        if not passed then failed[#failed + 1] = call[1] .. ': ' .. tostring(err) end
    end
    eq(#failed, 0, 'API calls failed:\n' .. table.concat(failed, '\n'))
    h.run(10)
    h.assert_clean('ticking sweep')
    for export in pairs(ACTIVITY_EXPORTS) do eq(enabled(h, export), false, export .. ' off after the sweep') end
end)

case('3 status reads from every plugin context mid-run (Arkham in the pit)', function()
    local h = setup({place = 'pit', quests = {'WarPlans_QST_ThePit'}})
    h.run(8)
    ok(enabled(h, 'ArkhamAsylumPlugin'), 'Arkham running')
    for _, rec in ipairs(h.plugins) do
        for _, reader in ipairs(STATUS_READERS) do
            local passed, err = pcall(h.as, rec, function() return h.G[reader[1]][reader[2]]() end)
            ok(passed, rec.name .. ' -> ' .. reader[1] .. '.' .. reader[2] .. ': ' .. tostring(err))
        end
    end
    local S = h.G.SilentRavenPlugin
    h.as(WP, function() S.get_status(); S.is_available() end)
    h.run(4)
    h.assert_clean('mid-run sweep')
end)

-- ═══ 4. Handoffs ═════════════════════════════════════════════════════════════
case('4 Pit -> Undercity: Arkham released in town, Batmobile and orbwalker clean, WonderCity after the gap', function()
    local h = setup({place = 'pit', quests = {'WarPlans_QST_ThePit'}, orb = true})
    for i = 1, 4 do h.actor('pit', 'Pit_Monster_' .. i, 20 + i * 15, (i % 2) * 6, {enemy = true}) end
    local arkham_owned = false
    h.run(12, function()
        if bm_state(h).owner == 'arkham_asylum' then arkham_owned = true end
    end)
    ok(enabled(h, 'ArkhamAsylumPlugin'), 'Arkham enabled in the pit')
    ok(arkham_owned or first(h.bm_calls, function(c) return c.context == ARK end) ~= nil, 'Arkham drives Batmobile')
    ok(first(h.orb_log, function(o) return o.context == ARK and o.what == 'block' and o.value == true end) ~= nil,
        'Arkham blocked movement for combat')
    -- The next WarPlan quest appears while the player is still in the pit.
    h.set_quests({'WarPlans_QST_Undercity'})
    h.run(4)
    ok(enabled(h, 'ArkhamAsylumPlugin'), 'Arkham kept until back in town')
    eq(enabled(h, 'WonderCityPlugin'), false, 'WonderCity waits for the Pit hand-off')
    ok(h.logged('deferring disable of ArkhamAsylumPlugin — not back in town yet') == 1, 'deferral logged')
    -- Arkham's exit: back in Temis.
    h.travel_to('temis', 1.0, 'pit_exit')
    local arrived
    ok(h.run_until(function()
        if not arrived and h.place == h.P.temis then arrived = h.now end
        return not enabled(h, 'ArkhamAsylumPlugin')
    end, 10), 'Arkham released in town')
    local released_at = h.now
    ok(released_at - arrived <= 1.0, string.format('release %.1fs after arrival', released_at - arrived))
    assert_released(h, 'after Arkham', 'arkham_asylum')
    eq(h.orb.block, false, 'movement block restored'); eq(h.orb.clear, true, 'clear restored')
    local in_town = context_calls(h, ARK, 'temis')
    if in_town > 0 then note(string.format('Pit -> Undercity: Arkham issued %d movement call(s) in Temis before its '
        .. 'release (WarPigs ticks at 2 Hz)', in_town)) end
    local ark_calls = #h.bm_calls
    ok(h.run_until(function() return enabled(h, 'WonderCityPlugin') end, 10), 'WonderCity enabled')
    local gap = h.now - released_at
    ok(gap >= 5 - 1e-6 and gap <= 6.1, string.format('post-disable gap %.1fs', gap))
    h.run(10)
    eq(first(h.bm_calls, function(c) return c.context == ARK and c.t > released_at end), nil,
        'no Arkham Batmobile call after its release')
    eq(first(h.moves, function(m) return m.context == ARK and m.t > released_at end), nil,
        'no Arkham native movement after its release')
    ok(#h.bm_calls > ark_calls, 'WonderCity drives Batmobile')
    ok(first(h.waypoints, function(w) return w.context == WC end) ~= nil, 'WonderCity heads to Kurast')
    eq(first(h.waypoints, function(w) return w.context ~= WC end), nil, 'only WonderCity teleported')
    h.assert_clean('pit->undercity')
    check_globals(h, 'pit->undercity')
end)

case('4 Undercity -> Helltide: WonderCity released on return to Kurast, Helltide after the gap', function()
    local h = setup({place = 'undercity', quests = {'WarPlans_QST_Undercity'}, orb = true})
    for i = 1, 3 do h.actor('undercity', 'Undercity_Monster_' .. i, 25 + i * 20, 0, {enemy = true}) end
    h.run(15)
    ok(enabled(h, 'WonderCityPlugin'), 'WonderCity enabled inside the Undercity')
    ok(first(h.bm_calls, function(c) return c.context == WC end) ~= nil, 'WonderCity drives Batmobile')
    h.set_quests({'WarPlans_QST_Helltide_TorturedGifts'})
    h.run(3)
    ok(enabled(h, 'WonderCityPlugin'), 'WonderCity kept inside the Undercity')
    eq(enabled(h, 'HelltideRevampedPlugin'), false, 'Helltide waits')
    h.travel_to('kurast', 1.0, 'undercity_exit')
    ok(h.run_until(function() return not enabled(h, 'WonderCityPlugin') end, 10), 'WonderCity released in Kurast')
    local released_at = h.now
    assert_released(h, 'after WonderCity', 'wonder_city')
    eq(h.orb.block, false, 'movement block restored'); eq(h.orb.clear, true, 'clear restored')
    ok(h.run_until(function() return enabled(h, 'HelltideRevampedPlugin') end, 10), 'Helltide enabled')
    local gap = h.now - released_at
    ok(gap >= 5 - 1e-6 and gap <= 6.1, string.format('post-disable gap %.1fs', gap))
    -- Helltide finds the active helltide zone (Hawe_Verge) by its own search.
    h.P.helltide.helltide = true
    ok(h.run_until(function() return h.place == h.P.helltide end, 90), 'Helltide reached the active zone\n' .. h.tail())
    h.run(15)
    local hr_tps = h.count(h.waypoints, function(w) return w.context == HR end)
    ok(hr_tps >= 1 and hr_tps <= 6, 'bounded Helltide zone search: ' .. hr_tps)
    local prev
    for _, w in ipairs(h.waypoints) do
        if w.context == HR then
            if prev then ok(w.t - prev >= 5.9, string.format('HR waypoint spam: %.1fs apart', w.t - prev)) end
            prev = w.t
        end
    end
    eq(first(h.bm_calls, function(c) return c.context == WC and c.t > released_at end), nil,
        'no WonderCity Batmobile call after its release')
    eq(first(h.waypoints, function(w) return w.context == WC and w.t > released_at end), nil,
        'no WonderCity teleport after its release')
    ok(first(h.bm_calls, function(c) return c.context == HR and c.place == 'helltide' end) ~= nil,
        'Helltide drives Batmobile in the helltide')
    h.assert_clean('undercity->helltide')
end)

case('4 Horde -> turn-in: HordeDev released after its exit, turn-in teleports after the short settle (L4)', function()
    local h = setup({place = 'bsk', quests = {'WarPlans_QST_InfernalHordes_BSK'}})
    h.run(15)
    ok(enabled(h, 'InfernalHordesPlugin'), 'HordeDev enabled in BSK (cold start in place)')
    h.set_quests({'WarPlans_QST_TurnIn_Rewards'})
    h.run(5)
    ok(enabled(h, 'InfernalHordesPlugin'), 'HordeDev kept while it reports in_run inside BSK')
    eq(#h.waypoints, 0, 'no teleport out of BSK over HordeDev')
    -- HordeDev's exit lands outside the Horde (Caldeum, at the gate).
    h.travel_to('caldeum', 0.5, 'leave')
    h.pos = nil
    ok(h.run_until(function() return not enabled(h, 'InfernalHordesPlugin') end, 10), 'HordeDev released')
    local released_at = h.now
    assert_released(h, 'after HordeDev', 'infernal_horde')
    ok(h.run_until(function() return first(h.waypoints, function(w) return w.context == WP end) ~= nil end, 25),
        'turn-in teleports to Temis')
    local tp = first(h.waypoints, function(w) return w.context == WP end)
    eq(tp.sno, J.TEMIS_WP, 'Temis waypoint')
    local wait = tp.t - released_at
    ok(wait <= 9.5, string.format('turn-in teleport %.1fs after the release (gap 5 s + settle 3 s; was 20 s)', wait))
    eq(h.count(h.waypoints, function(w) return w.context == HD end), 0, 'no HordeDev teleport after the run')
    ok(h.run_until(function() return #h.quests == 0 end, 40), 'turn-in completed at Tyrael\n' .. h.tail())
    h.run(3)
    eq(h.mod(WP, 'core.tasks.turn_in_rewards').get_state(), 'IDLE', 'turn-in task idle')
    ok(h.logged('turn-in cycle completed') == 1, 'turn-in completion logged')
    eq(first(h.bm_calls, function(c) return c.context == HD and c.t > released_at end), nil,
        'no HordeDev Batmobile call after its release')
    -- The loop closes in Temis: Whisper check, then WarPug submits the next plan.
    ok(h.run_until(function() return h.board.confirmed == 1 end, 60), 'WarPug submits the next plan\n' .. h.tail())
    ok(h.logged('visit 1: skipped_not_ready') == 1, 'Whisper check ran first')
    h.assert_clean('horde->turn-in')
end)

case('4 Pit hand-off waits over Arkham\'s own Alfred trip (town leg is not the end of the run)', function()
    local h = setup({place = 'pit', quests = {'WarPlans_QST_ThePit'}})
    h.run(10)
    h.set_quests({'WarPlans_QST_Undercity'})
    h.run(1)
    -- Bags full with loot on the floor: Arkham's with-teleport Alfred trip.
    h.floor_loot = true
    h.alfred.inventory_full, h.alfred.need_trigger = true, true
    local in_town, statuses = false, {}
    ok(h.run_until(function()
        if h.place == h.P.temis then
            in_town = true
            statuses[#statuses + 1] = status(h, 'ArkhamAsylumPlugin')
        end
        return in_town and h.place == h.P.pit
    end, 40), 'Alfred trip went to town and back\n' .. h.tail())
    local trip = first(h.alfred.triggers, function(t) return t.context == ARK end)
    ok(trip and trip.teleport, 'Arkham started the with-teleport trip')
    ok(#statuses > 10, 'town leg observed')
    for _, st in ipairs(statuses) do
        eq(st.enabled, true, 'Arkham kept during its town leg')
        eq(st.alfred_trip, true, 'C2 alfred_trip published during the town leg')
    end
    eq(enabled(h, 'WonderCityPlugin'), false, 'WonderCity not started over the trip')
    ok(h.logged('deferring disable of ArkhamAsylumPlugin — ArkhamAsylumPlugin Alfred round trip in progress') == 1,
        'hold reason logged')
    h.floor_loot = false
    h.run(8)
    ok(h.logged('resuming the run') == 1, 'Arkham resumes the same pit run')
    eq(#h.waypoints, 0, 'nobody teleported during the trip')
    -- The run ends: back in town, released, WonderCity next.
    h.travel_to('temis', 1.0, 'pit_exit')
    ok(h.run_until(function() return enabled(h, 'WonderCityPlugin') end, 20), 'WonderCity after the real exit')
    h.assert_clean('arkham trip')
end)

case('4 Reaper boss dispatch from Temis; WarPigs stop cancels the run with one callback', function()
    local h = setup({quests = {'WarPlans_QST_BossLair_Andariel'}})
    h.setup_lair()
    ok(h.run_until(function() return h.place == h.P.lair end, 15), 'Reaper travelled to the lair')
    h.run(6)
    local st = status(h, 'ReaperPlugin')
    eq(st.enabled, true); eq(st.in_run, true, 'C2 in_run'); eq(st.external_run, true, 'C2 external_run')
    eq(h.count(h.boss_tps, function(t) return t.context == RP end), 1, 'one boss-dungeon teleport by Reaper')
    ok(first(h.bm_calls, function(c) return c.context == RP end) ~= nil, 'Reaper drives Batmobile')
    local stop_at = h.now
    el(h, WP).main_toggle:set(false)
    h.run(1)
    st = status(h, 'ReaperPlugin')
    eq(st.enabled, false, 'Reaper stopped by the master stop')
    eq(st.last_result, 'cancelled', 'C2 last_result')
    eq(h.logged('[Reaper] Run cancelled'), 1, 'one cancellation')
    assert_released(h, 'after Reaper', 'reaper')
    eq(first(h.waypoints, function(w) return w.t >= stop_at end), nil, 'no teleport on stop')
    h.run(5)
    eq(first(h.bm_calls, function(c) return c.context == RP and c.t > stop_at + 1 end), nil, 'Reaper idle')
    h.assert_clean('reaper')
end)

case('4 Pit -> Undercity with Use teleport: via-Temis Alfred preamble, warplan teleport, WonderCity in Kurast', function()
    local h = setup({place = 'pit', quests = {'WarPlans_QST_ThePit'}, teleport = true})
    h.run(10)
    ok(h.logged('cold start: already inside the ArkhamAsylumPlugin activity') == 1, 'cold start in place')
    eq(#h.warplans, 0, 'no warplan teleport out of the running pit')
    ok(enabled(h, 'ArkhamAsylumPlugin'), 'Arkham enabled')
    h.set_quests({'WarPlans_QST_Undercity'})
    h.warplan_dest = 'kurast'
    h.run(2)
    h.travel_to('temis', 1.0, 'pit_exit')
    ok(h.run_until(function() return not enabled(h, 'ArkhamAsylumPlugin') end, 10), 'Arkham released in Temis')
    assert_released(h, 'after Arkham', 'arkham_asylum')
    -- The pit loot filled the bags: Alfred has hard work in Temis.
    h.alfred.inventory_full, h.alfred.need_trigger = true, true
    ok(h.run_until(function() return enabled(h, 'WonderCityPlugin') end, 60), 'WonderCity enabled\n' .. h.tail())
    h.assert_clean('preamble')
    local trigger = first(h.alfred.triggers, function(t) return t.context == WP end)
    ok(trigger ~= nil and trigger.place == 'temis', 'WarPigs triggered Alfred in Temis')
    -- Found by this suite: the Temis kick serviced the bags on arrival and the
    -- preamble then started a second full Alfred cycle; it now joins the one
    -- that just finished in this visit.
    eq(h.count(h.alfred.triggers), 1, 'one Alfred cycle per hand-off (kick, then the preamble joins it)')
    ok(h.logged('Alfred picked up trigger, no work pending') + h.logged('Alfred finished its work') >= 1,
        'the preamble still dwells and settles')
    eq(h.alfred.inventory_full, false, 'Alfred emptied the bags')
    eq(h.count(h.warplans, function(w) return w.kind == 'teleport' end), 1, 'one warplan teleport')
    local tp = first(h.warplans, function(w) return w.kind == 'teleport' end)
    local last_trigger = last(h.alfred.triggers, function() return true end)
    ok(tp.t > last_trigger.t + h.alfred.work, 'warplan teleport after the last Alfred cycle')
    eq(h.place, h.P.kurast, 'landed in Kurast')
    eq(h.count(h.waypoints, function(w) return w.context == WP end), 0, 'no extra Temis hop (already in Temis)')
    h.run(10)
    h.assert_clean('preamble run')
end)

-- A restock need Alfred can never fill (Steroid's sticky need_trigger) with
-- Use teleport on. Found by this suite: the Temis kick, the via-Temis
-- preamble and then Arkham each started an Alfred cycle for the same
-- advisory flag within ~16 s, before the pit even opened.
case('4 sticky restock flag with Use teleport: one Alfred cycle per Temis visit, the Pit starts without another', function()
    local h = setup({quests = {'WarPlans_QST_ThePit'}, teleport = true})
    h.alfred.need_trigger, h.alfred.sticky_need, h.alfred.restock_count = true, true, 2
    ok(h.run_until(function() return enabled(h, 'ArkhamAsylumPlugin') end, 40), 'Arkham enabled\n' .. h.tail())
    local enabled_at = h.now
    ok(h.run_until(function() return h.place == h.P.pit end, 30), 'Arkham entered the pit\n' .. h.tail())
    h.assert_clean('sticky restock')
    eq(h.count(h.alfred.triggers, function(t) return t.context == WP end), 1, 'one WarPigs Alfred cycle in Temis')
    eq(h.count(h.alfred.triggers, function(t) return t.context == ARK end), 0, 'no Arkham advisory trip in Temis')
    eq(h.count(h.alfred.triggers), 1, 'one Alfred cycle in total')
    ok(h.now - enabled_at <= 15, string.format('pit opened %.1fs after the enable', h.now - enabled_at))
    ok(h.logged('teleport skipped — quest actor present') == 1, 'Pit tower already in Temis: no warplan teleport')
    -- Standalone rule unchanged: without WarPigs Arkham still services the
    -- advisory flag in town after its own grace (checked via its status).
    eq(h.G.WarPigsPlugin.status().alfred_idle, true, 'WarPigs reports the advisory flag handled for this visit')
end)

-- ═══ 5. Master stop ══════════════════════════════════════════════════════════
local function arkham_pit(opts)
    opts = opts or {}
    local h = setup({place = 'pit', quests = {'WarPlans_QST_ThePit'}, orb = true, teleport = opts.teleport})
    for i = 1, 4 do h.actor('pit', 'Pit_Monster_' .. i, 20 + i * 15, (i % 2) * 6, {enemy = true}) end
    h.run(8)
    ok(enabled(h, 'ArkhamAsylumPlugin'), 'Arkham running in the pit')
    return h
end
local function assert_master_stopped(h, label, stop_at)
    eq(enabled(h, 'ArkhamAsylumPlugin'), false, label .. ': Arkham disabled')
    assert_released(h, label, 'arkham_asylum')
    eq(h.orb.block, false, label .. ': movement block released'); eq(h.orb.clear, true, label .. ': clear restored')
    local raven = h.as(WP, function() return h.G.SilentRavenPlugin.get_status() end)
    eq(raven.managed_by, nil, label .. ': SilentRaven released')
    eq(h.mod(WP, 'core.tasks.turn_in_rewards').get_state(), 'IDLE', label .. ': turn-in idle')
    eq(first(h.waypoints, function(w) return w.t >= stop_at end), nil, label .. ': no teleport on stop')
    eq(first(h.warplans, function(w) return w.t >= stop_at end), nil, label .. ': no warplan call on stop')
end

case('5 master stop: WarPigs off mid-pit releases everything; re-enable resumes in place', function()
    for _, tp in ipairs({false, true}) do
        local label = tp and 'teleport on' or 'teleport off'
        local h = arkham_pit({teleport = tp})
        local stop_at = h.now
        el(h, WP).main_toggle:set(false)
        h.run(1)
        assert_master_stopped(h, label, stop_at)
        local stopped_at = h.now
        h.run(10)
        eq(first(h.bm_calls, function(c) return c.context == ARK and c.t > stopped_at end), nil,
            label .. ': Arkham idle while WarPigs is off')
        eq(enabled(h, 'ArkhamAsylumPlugin'), false, label .. ': nobody restarts Arkham')
        -- Re-enable: the pit quest is still active and the player still inside.
        local pit_world = h.place
        el(h, WP).main_toggle:set(true)
        ok(h.run_until(function() return enabled(h, 'ArkhamAsylumPlugin') end, 3), label .. ': Arkham re-enabled')
        if tp then ok(h.logged('cold start: already inside the ArkhamAsylumPlugin activity') == 2,
            label .. ': in-place cold start') end
        local resumed_at = h.now
        h.run(8)
        eq(h.place, pit_world, label .. ': still in the same pit')
        eq(first(h.waypoints, function(w) return w.t >= stop_at end), nil, label .. ': no teleport on resume')
        eq(first(h.warplans, function(w) return w.t >= stop_at end), nil, label .. ': no warplan call on resume')
        ok(first(h.bm_calls, function(c) return c.context == ARK and c.t > resumed_at end) ~= nil,
            label .. ': Arkham drives Batmobile again')
        h.assert_clean(label)
    end
end)

case('5 master stop via WarPigsPlugin.disable(); manual Arkham is adopted on re-enable', function()
    local h = arkham_pit()
    local stop_at = h.now
    local released = h.as(PUG, function() return h.G.WarPigsPlugin.disable() end)
    eq(released, true, 'disable() reports a complete release')
    h.run(1)
    assert_master_stopped(h, 'api stop', stop_at)
    -- The user restarts the pit by hand while WarPigs is off.
    el(h, ARK).main_toggle:set(true)
    h.run(5)
    ok(enabled(h, 'ArkhamAsylumPlugin'), 'manual Arkham runs')
    local enables_before = h.logged('enabled ArkhamAsylumPlugin')
    local adopt_at = h.now
    h.as(PUG, function() h.G.WarPigsPlugin.enable() end)
    h.run(3)
    eq(h.logged('adopted active ArkhamAsylumPlugin'), 1, 'WarPigs adopts the running pit')
    eq(h.logged('enabled ArkhamAsylumPlugin'), enables_before, 'adopted without a re-enable')
    ok(enabled(h, 'ArkhamAsylumPlugin'), 'Arkham keeps running')
    eq(first(h.waypoints, function(w) return w.t >= adopt_at end), nil, 'no teleport on adoption')
    local line = h.as(WP, function() return h.G.WarPigsPlugin.status() end)
    eq(line.busy, true, 'WarPigs reports the adopted activity')
    h.assert_clean('adoption')
end)

case('5 death in the pit under WarPigs: revive, no hand-off, Arkham continues', function()
    for _, tp in ipairs({false, true}) do
        local h = arkham_pit({teleport = tp})
        local died_at = h.now
        h.dead = true
        ok(h.run_until(function() return not h.dead end, 10), 'revived')
        h.run(6)
        ok(h.revives >= 1, 'revive requested')
        eq(h.logged('player died'), 1, 'WarPigs logs the death once')
        eq(h.logged('player revived'), 1, 'WarPigs logs the revive once')
        ok(enabled(h, 'ArkhamAsylumPlugin'), 'Arkham kept (quest still active)')
        eq(h.place, h.P.pit, 'still in the pit')
        eq(first(h.waypoints, function(w) return w.t >= died_at end), nil, 'no teleport after the death')
        eq(first(h.warplans, function(w) return w.t >= died_at end), nil, 'no warplan call after the death')
        ok(first(h.bm_calls, function(c) return c.context == ARK and c.t > died_at + 3 end) ~= nil,
            'Arkham drives again after the revive')
        h.assert_clean('death')
    end
end)

-- ═══ 6. Infernal Hordes War Plan entry (round 4) ═════════════════════════════
-- The user feature: a Horde War Plan is entered through the War Plan
-- teleport (no Infernal Compass, no Library walk); HordeDev runs in War Plan
-- entry mode only inside the Horde. The host scripts the horde itself
-- (joint_host.lua h.setup_horde: 6 waves, locked door, Council, chest room).
-- Every scenario fails on d275b9d except J7 (standalone guard).
local HORDE_Q, LIBRARY_WP = 'WarPlans_QST_InfernalHordes_BSK', 0x10D63D
local LANDED_BSK = 'landed world=S05_BSK_Prototype02 zone=S05_BSK_Prototype02, inside the Horde'
local function hd_calls(h, name)
    local out = {}
    for _, c in ipairs(h.api_calls) do
        if c.export == 'InfernalHordesPlugin' and c.name == name and c.context == WP then out[#out + 1] = c end
    end
    return out
end
local function warplan_tps(h, since)
    return h.count(h.warplans, function(w) return w.kind == 'teleport' and w.t >= (since or 0) end)
end
local function arena_event(A, what, run)
    return first(A.events, function(e) return e.what == what and (run == nil or e.run == run) end)
end
-- Nothing of the compass chain ran: no use_item, no sigil confirmation, no
-- Library waypoint, no HordeDev teleport, no compass countdown.
local function no_compass(h, label)
    eq(#h.items, 0, label .. ': use_item (Infernal Compass) calls')
    eq(#h.sigil_confirms, 0, label .. ': sigil confirmations')
    eq(h.count(h.waypoints, function(w) return w.sno == LIBRARY_WP end), 0, label .. ': Library teleports')
    eq(h.count(h.waypoints, function(w) return w.context == HD end), 0, label .. ': HordeDev teleports')
    eq(h.logged('Waiting five seconds before selecting a compass'), 0, label .. ': compass countdown')
end
-- Samples HordeDev's C2 status every frame.
local function horde_watch(h)
    local w = {tasks = {}, outside = {}, stall = 0, max_stall = 0}
    function w.each()
        local st = status(h, 'InfernalHordesPlugin')
        local name = st.task and st.task.name or '?'
        w.tasks[name] = (w.tasks[name] or 0) + 1
        if st.enabled == true and h.place ~= h.P.bsk and h.place ~= h.P.limbo then
            w.outside[tostring(st.entry_mode) .. ':' .. name] = true
        end
        -- The round-3 critic's silent stall: on, 'Idle', in_run, no hold.
        if st.enabled == true and name == 'Idle' and st.in_run == true and st.hold == nil and not h.travel then
            w.stall = w.stall + 0.1
            if w.stall > w.max_stall then w.max_stall = w.stall end
        else
            w.stall = 0
        end
        if st.last_result == 'completed' and not w.completed then
            w.completed = {t = h.now, in_run = st.in_run, enabled = st.enabled, place = h.place.key, task = name,
                chests_done = h.as(WP, function() return h.G.InfernalHordesPlugin.chests_done() end)}
        end
        if st.hold == 'waiting for War Plan teleport' and not w.waiting then
            w.waiting = {t = h.now, task = name, in_run = st.in_run, place = h.place.key}
        end
    end
    return w
end
local function outside_only(w, allowed, label)
    for key in pairs(w.outside) do ok(allowed[key], label .. ': HordeDev on outside the Horde as ' .. key) end
end

-- J1/J2: a Pit, then the Horde War Plan. WarPigs releases Arkham in Temis,
-- fires the War Plan teleport itself, starts HordeDev in War Plan mode inside
-- the Horde, and after the exit the turn-in follows.
local function warplan_horde_chain(opts)
    local h = setup({place = 'pit', quests = {'WarPlans_QST_ThePit'}, teleport = opts.teleport})
    local A = h.setup_horde(opts.arena)
    h.run(10)
    ok(enabled(h, 'ArkhamAsylumPlugin'), 'Arkham running in the pit')
    h.set_quests({HORDE_Q})
    h.warplan_dest = 'bsk'
    h.run(2)
    h.travel_to('temis', 1.0, 'pit_exit')
    ok(h.run_until(function() return not enabled(h, 'ArkhamAsylumPlugin') end, 10), 'Arkham released in Temis')
    local w = horde_watch(h)
    w.arkham_released = h.now
    ok(h.run_until(function() return #h.quests == 0 end, 420, w.each), 'the turn-in completes\n' .. h.tail())
    h.run(2, w.each)
    h.assert_clean('war plan horde')
    return h, A, w
end
-- The horde itself, the exit, the release and the turn-in (J1 and J2).
local function assert_warplan_run(h, A, w, label, chest_room)
    no_compass(h, label)
    eq(h.logged('enabling it to navigate itself'), 0, label .. ': no WPD-3 enable outside the Horde')
    local arrived = first(h.arrivals, function(a) return a.place == 'bsk' end)
    ok(arrived and arrived.why == 'warplan', label .. ': the War Plan teleport put the player in the Horde')
    local enables = hd_calls(h, 'enable')
    eq(#enables, 1, label .. ': one HordeDev enable')
    eq(enables[1].place, 'bsk', label .. ': enabled inside the Horde')
    eq(enables[1].entry, 'warplan', label .. ': enable({entry = "warplan"})')
    ok(enables[1].t >= arrived.t, label .. ': enabled only after the arrival')
    eq(h.logged(LANDED_BSK), 1, label .. ': landing logged once')
    -- 6 host-scripted waves, the Council, then the chest room (or none).
    eq(A.runs, 1, label .. ': one horde')
    eq(A.wave, 6, label .. ': six waves')
    eq(h.count(A.events, function(e) return e.what:find('^pylon') ~= nil end), 6, label .. ': six offerings')
    ok(arena_event(A, 'door opened') and arena_event(A, 'council dead'), label .. ': door and Council')
    if chest_room then
        eq(table.concat(A.opened, ','), 'BSK_UniqueOpChest_GreaterAffix,BSK_UniqueOpChest_Materials,'
            .. 'BSK_UniqueOpChest_Materials', label .. ': chests opened with the aether')
        eq(h.aether, 0, label .. ': aether spent')
        eq(h.logged('Chest sequence finished'), 1, label .. ': chest phase finished')
    else
        eq(#A.opened, 0, label .. ': no chest room')
        eq(h.logged('no chest room; leaving without chests'), 1, label .. ': bounded completion without chests')
        local left = first(h.arrivals, function(a) return a.why == 'leave' end)
        ok(left.t - A.council_dead_at <= 45, string.format('%s: left %.1fs after the Council (bounded)', label,
            left.t - A.council_dead_at))
    end
    -- Found by this suite: the aether hold was logged every pulse from the
    -- first wave on (~600 lines per horde).
    ok(h.logged('holding — player still has') <= 1, label .. ': aether hold not logged every pulse ('
        .. h.logged('holding — player still has') .. ')')
    -- Exit, a visible completed result, released, turn-in.
    eq(h.leaves, 1, label .. ': Leave Dungeon'); eq(h.resets, 1, label .. ': reset')
    ok(w.completed ~= nil, label .. ': last_result completed')
    eq(w.completed.in_run, false, label .. ': in_run false after the exit')
    eq(w.completed.chests_done, true, label .. ': chests_done() after the exit')
    ok(w.completed.place ~= 'bsk', label .. ': completed outside the Horde')
    eq(h.logged('War Plan horde complete; no new cycle'), 1, label .. ': completion logged')
    local released = first(hd_calls(h, 'disable'), function(c) return c.t >= w.completed.t end)
    ok(released and released.t - w.completed.t <= 1.0, label .. ': released right after the exit')
    eq(status(h, 'InfernalHordesPlugin').entry_mode, 'compass', label .. ': disable() reset the entry mode')
    eq(w.tasks['Start Dungeon'], nil, label .. ': no compass cycle after the exit')
    eq(w.tasks['Walking to Horde'], nil, label .. ': no Library walk')
    eq(w.tasks['Enter Horde'], nil, label .. ': no portal walk')
    outside_only(w, {['warplan:Exit Horde'] = true, ['warplan:War Plan horde complete'] = true}, label)
    ok(w.max_stall <= 3, label .. ': no idle stall')
    eq(h.logged('turn-in cycle completed'), 1, label .. ': turn-in')
    eq(h.count(h.warplans, function(w2) return w2.kind == 'teleport' end), 1, label .. ': one War Plan teleport')
end

case('J1 War Plan Horde, Use teleport off: WarPigs teleports, HordeDev in War Plan mode, 6 waves, exit, turn-in', function()
    for _, variant in ipairs({'chest room', 'no chest room (unspendable aether)', 'no chest room, no aether'}) do
        local chest_room = variant == 'chest room'
        local h, A, w = warplan_horde_chain({arena = {chest_room = chest_room,
            aether_per_wave = variant == 'no chest room, no aether' and 0 or 5}})
        local label = 'J1 ' .. variant
        assert_warplan_run(h, A, w, label, chest_room)
        -- The War Plan teleport comes from WarPigs itself, after Arkham's
        -- release and the post-disable gap; no waypoint before the exit.
        local tp = first(h.warplans, function(x) return x.kind == 'teleport' end)
        eq(tp.context, WP, label .. ': War Plan teleport by WarPigs')
        ok(tp.t - w.arkham_released >= 5 - 1e-6, string.format('%s: War Plan teleport %.1fs after the release (gap 5 s)',
            label, tp.t - w.arkham_released))
        eq(first(h.waypoints, function(x) return x.t < w.completed.t end), nil, label .. ': no waypoint teleport before the exit')
        eq(h.count(h.alfred.triggers), 0, label .. ': no Alfred cycle (no need, Use teleport off)')
        if not chest_room then eq(h.aether, variant == 'no chest room, no aether' and 0 or 30, label .. ': aether left') end
    end
end)

case('J2 War Plan Horde, Use teleport on: via-Temis preamble (one Alfred cycle), then the War Plan teleport', function()
    local h, A, w = warplan_horde_chain({teleport = true, arena = {}})
    local label = 'J2'
    assert_warplan_run(h, A, w, label, true)
    local arrived = first(h.arrivals, function(a) return a.place == 'bsk' end)
    local visit = h.count(h.alfred.triggers, function(t) return t.t < arrived.t end)
    eq(visit, 1, 'J2: one Alfred cycle in the Temis visit before the Horde')
    local trigger = h.alfred.triggers[1]
    eq(trigger.context, WP, 'J2: WarPigs triggered it'); eq(trigger.place, 'temis', 'J2: in Temis')
    eq(h.logged('via-Temis preamble: already in Temis — Alfred triggered'), 1, 'J2: preamble Alfred step')
    local tp = first(h.warplans, function(x) return x.kind == 'teleport' end)
    ok(tp.t >= trigger.t + h.alfred.work, 'J2: War Plan teleport after the Alfred cycle')
    eq(h.logged('the via-Temis warplan teleport arrived — ' .. LANDED_BSK), 1, 'J2: landing logged once')
    eq(h.count(h.alfred.triggers, function(t) return t.context == HD end), 0, 'J2: no HordeDev Alfred trip')
end)

case('J3 War Plan teleport misses the Horde 3 times: no compass, visible reason, 60 s backoff; compass fallback once', function()
    -- Fallback off (default): three misses, then the backoff; never a compass.
    local h = setup({quests = {HORDE_Q}})
    h.give_compasses(2)
    h.warplan_dest = 'caldeum'   -- the War Plan teleport lands at the Caldeum gate
    local lines = {}
    h.run(150, function()
        local line = h.as(WP, function() return h.mod(WP, 'core.orchestrator').get_status_line() end)
        if h.now >= 1025 and h.now < 1075 then lines[#lines + 1] = line end
    end)
    h.assert_clean('J3')
    no_compass(h, 'J3')
    eq(#hd_calls(h, 'enable'), 0, 'J3: HordeDev never enabled outside the Horde')
    eq(enabled(h, 'InfernalHordesPlugin'), false)
    local tps = {}
    for _, x in ipairs(h.warplans) do if x.kind == 'teleport' then tps[#tps + 1] = x end end
    eq(#tps, 6, 'J3: 3 War Plan teleports per round, 2 rounds in 150 s')
    for i = 2, 3 do ok(tps[i].t - tps[i - 1].t >= 6 - 1e-6, 'J3: channel debounce between tries') end
    ok(tps[4].t - tps[3].t >= 60, string.format('J3: 60 s backoff before round 2 (%.1fs)', tps[4].t - tps[3].t))
    eq(h.logged('not using a compass (compass fallback off)'), 2, 'J3: one reason line per round')
    eq(h.logged('retrying the War Plan teleport (round 2)'), 1, 'J3: round 2 logged')
    ok(h.logged('War Plan Horde entry:') <= 18, 'J3: War Plan entry log rate-limited: ' .. h.logged('War Plan Horde entry:'))
    ok(#lines > 50, 'J3: status sampled during the backoff')
    for _, line in ipairs(lines) do
        ok(line:find('did not reach the Horde', 1, true) and line:find('compass fallback off', 1, true),
            'J3: backoff reason visible in the status line: ' .. line)
    end
    eq(h.logged('enabling it to navigate itself'), 0, 'J3: WPD-3 bypass off in War Plan mode')

    -- Fallback on: compass mode exactly once after the three misses.
    local f = setup({quests = {HORDE_Q}})
    el(f, WP).horde_compass_fallback:set(true)
    f.give_compasses(2)
    local A = f.setup_horde({})
    f.warplan_dest = 'caldeum'
    local w = horde_watch(f)
    ok(f.run_until(function() return #f.quests == 0 end, 420, w.each), 'J3 fallback: the compass horde and the turn-in\n'
        .. f.tail())
    f.assert_clean('J3 fallback')
    local enables = hd_calls(f, 'enable')
    eq(#enables, 1, 'J3 fallback: one HordeDev enable')
    eq(enables[1].with_args, false, 'J3 fallback: enable() without arguments (compass mode)')
    eq(enables[1].place, 'caldeum', 'J3 fallback: at the gate')
    local third = log_time(f, 'compass fallback is on: starting HordeDev in compass mode')
    ok(third and enables[1].t >= third, 'J3 fallback: only after the third miss')
    eq(f.logged('starting HordeDev in compass mode (compass fallback'), 1, 'J3 fallback: logged once')
    eq(warplan_tps(f), 3, 'J3 fallback: no War Plan teleport after the fallback')
    eq(#f.items, 1, 'J3 fallback: one compass for the one horde')
    eq(f.items[1].context, HD, 'J3 fallback: HordeDev used it')
    local entered = first(f.arrivals, function(a) return a.place == 'bsk' end)
    eq(entered.why, 'horde_portal', 'J3 fallback: entered through the compass portal')
    eq(A.wave, 6, 'J3 fallback: the horde ran')
    ok(w.outside['compass:Start Dungeon'], 'J3 fallback: compass mode at the gate')
end)

case('J4 HordeDev toggle persisted on at load with WarPigs on: nothing before WarPigs decides', function()
    local PERSISTED = {infernal_horde_main_toggle = true, war_pigs_main_toggle = true, war_pug_main_toggle = true,
        silent_raven_main_toggle = true}
    local variants = {
        {'Temis, no Horde plan', 'temis', nil, true},
        {'Temis, Horde plan', 'temis', HORDE_Q, true},
        {'at the gate with compasses, Horde plan', 'caldeum', HORDE_Q, true},
        {'at the gate, Horde plan, War Plan entry off', 'caldeum', HORDE_Q, false},
    }
    for _, v in ipairs(variants) do
        local label, warplan_on = 'J4 ' .. v[1], v[4]
        local persisted = J.copy(PERSISTED)
        persisted.war_pigs_horde_warplan_entry = warplan_on
        local h = J.new({place = v[2], persisted = persisted})
        h.assert_clean('load')
        h.instrument_exports()
        eq(el(h, HD).main_toggle:get(), true, label .. ': HordeDev toggle persisted on')
        if v[2] == 'caldeum' then h.pos = h.v(-1714, -586) end
        h.give_compasses(2)
        local A = h.setup_horde({})
        h.warplan_dest = 'bsk'
        if v[3] then h.set_quests({v[3]}) end
        h.run(60)
        h.assert_clean(label)
        -- WarPigs' first decision about HordeDev (stop it, or adopt it).
        local decided = log_time(h, '[WarPigs] disabled InfernalHordesPlugin')
            or log_time(h, 'adopted active InfernalHordesPlugin')
        ok(decided and decided <= 1000.1 + 1e-6, label .. ': WarPigs decided on its first tick')
        -- HordeDev runs before WarPigs within a frame: nothing at or before it.
        local function before(list) return first(list, function(c) return c.context == HD and c.t <= decided + 1e-6 end) end
        eq(before(h.waypoints), nil, label .. ': no HordeDev teleport before WarPigs decided')
        eq(before(h.items), nil, label .. ': no compass before WarPigs decided')
        eq(before(h.moves), nil, label .. ': no HordeDev movement before WarPigs decided')
        eq(h.logged('waiting up to 5s for WarPigs before acting'), 1, label .. ': visible wait logged')
        if warplan_on then
            no_compass(h, label)
            if v[3] then
                ok(h.logged('was not started by WarPigs — stopping it') == 1, label .. ': persisted HordeDev not adopted')
                local enables = hd_calls(h, 'enable')
                eq(#enables, 1, label .. ': started once'); eq(enables[1].entry, 'warplan')
                eq(enables[1].place, 'bsk', label .. ': inside the Horde')
                ok(A.wave >= 1, label .. ': waves run')
            else
                eq(enabled(h, 'InfernalHordesPlugin'), false, label .. ': stays off')
            end
        else
            -- d275b9d behaviour with the option off: adopted, compass after
            -- HordeDev's bounded 5 s wait.
            eq(h.logged('No enable/disable from WarPigs within 5s'), 1, label .. ': bounded wait ended')
            ok(h.items[1] and h.items[1].t >= decided + 5, label .. ': compass only after the bounded wait')
        end
    end
end)

-- Round 5 (W5-4): a hotkey pause with C2 in_run is a user pause, not a
-- self-disable. d275b9d/9e01f67 treated it as a self-disable: with 'Use
-- teleport' on WarPigs left the horde via Temis, with it off it re-enabled
-- HordeDev after the 5 s gap (the round-4 J5 asserted exactly that, as a
-- recorded pre-existing behaviour). Now WarPigs waits, visibly, and the same
-- horde continues when the user resumes; still no silent Idle+in_run stall.
local PAUSED = 'paused by its hotkey — WarPigs waiting'
local function status_line(h)
    return h.as(WP, function() return h.mod(WP, 'core.orchestrator').get_status_line() end)
end
local function count_since(list, t)
    local n = 0
    for _, rec in ipairs(list) do if rec.t >= t then n = n + 1 end end
    return n
end
case('J5 HordeDev hotkey pressed mid-horde under WarPigs: a user pause (W5-4), WarPigs waits visibly, horde resumes',
    function()
    local function paused_horde(opts)
        local h = setup({quests = {HORDE_Q}, teleport = opts.teleport})
        el(h, WP).horde_warplan_entry:set(opts.warplan)
        el(h, HD).use_keybind:set(true); el(h, HD).keybind_toggle:set_key(0x70)
        h.give_compasses(3)
        local A = h.setup_horde({})
        h.warplan_dest = opts.warplan and 'bsk' or 'caldeum'
        local w = horde_watch(h)
        ok(h.run_until(function() return A.wave >= 3 end, 240, w.each), 'horde reached wave 3\n' .. h.tail())
        el(h, HD).keybind_toggle.state = 0 -- the user presses HordeDev's bound hotkey
        w.paused_at = h.now
        return h, A, w
    end
    for _, v in ipairs({{'compass mode, Use teleport on', false, true}, {'War Plan, Use teleport on', true, true},
        {'War Plan, Use teleport off', true, false}}) do
        local label = 'J5 ' .. v[1]
        local h, A, w = paused_horde({warplan = v[2], teleport = v[3]})
        local items, shown = #h.items, 0
        h.run(20, function()
            w.each()
            if status_line(h):find('InfernalHordesPlugin ' .. PAUSED, 1, true) then shown = shown + 1 end
        end)
        eq(enabled(h, 'InfernalHordesPlugin'), false,
            label .. ': still paused after 20 s (9e01f67: re-enabled or left)')
        eq(status(h, 'InfernalHordesPlugin').in_run, true, label .. ': C2 in_run while paused in the Horde')
        eq(h.logged('detected self-disable of InfernalHordesPlugin'), 0, label .. ': not a self-disable')
        local function calls_since(name)
            return h.count(hd_calls(h, name), function(c) return c.t >= w.paused_at end)
        end
        eq(calls_since('enable'), 0, label .. ': no re-enable over the pause')
        eq(calls_since('disable'), 0, label .. ': no disable')
        eq(count_since(h.waypoints, w.paused_at), 0, label .. ': no teleport_to_waypoint (9e01f67 teleport on: Temis)')
        eq(count_since(h.warplans, w.paused_at), 0, label .. ': no War Plan call')
        eq(h.place, h.P.bsk, label .. ': the player stays in the Horde')
        eq(h.logged('[WarPigs] InfernalHordesPlugin ' .. PAUSED .. ' (it reports a run in progress'), 1,
            label .. ': the wait logged once')
        ok(shown >= 190, label .. ': the wait is visible in the status line (' .. shown .. ' of 200 frames)')
        el(h, HD).keybind_toggle.state = 1 -- the user resumes HordeDev
        ok(h.run_until(function() w.each(); return #h.quests == 0 end, 300), label .. ': the horde and the turn-in\n'
            .. h.tail())
        h.run(2, w.each)
        h.assert_clean(label)
        eq(h.logged('InfernalHordesPlugin reports enabled again'), 1, label .. ': resume logged')
        eq(calls_since('enable'), 0, label .. ': resumed without an enable()')
        eq(A.runs, 1, label .. ': the same horde'); eq(A.wave, 6, label)
        ok(A.council_dead_at ~= nil, label .. ': Council dead')
        eq(#h.items, items, label .. ': no compass after the pause')
        if v[2] then
            no_compass(h, label)
            eq(h.logged('War Plan horde complete; no new cycle'), 1, label .. ': completed')
        else
            eq(#h.items, 1, label .. ': one compass for the one horde')
            eq(h.count(h.waypoints, function(x) return x.sno == LIBRARY_WP and x.t >= w.paused_at end), 0,
                label .. ': no Library teleport (new compass cycle) after the pause')
        end
        ok(w.max_stall <= 3, string.format('%s: no silent idle stall (%.1fs)', label, w.max_stall))
        eq(h.logged('turn-in cycle completed'), 1, label .. ': turn-in')
    end
end)

case('J6 Horde -> turn-in -> next Pit plan in one Temis visit (Use teleport on): one WarPigs Alfred cycle', function()
    for _, sticky in ipairs({false, true}) do
        local label = sticky and 'J6 sticky restock flag' or 'J6'
        local h = setup({quests = {HORDE_Q}, teleport = true})
        if sticky then h.alfred.need_trigger, h.alfred.sticky_need, h.alfred.restock_count = true, true, 2 end
        local A = h.setup_horde({})
        h.warplan_dest = 'bsk'
        local released
        ok(h.run_until(function()
            if not released and A.council_dead_at and not enabled(h, 'InfernalHordesPlugin') then
                released = h.now
                h.bounty_ready = true
                h.on_confirm = function() h.at(1.0, function() h.set_quests({'WarPlans_QST_ThePit'}) end) end
            end
            return enabled(h, 'ArkhamAsylumPlugin')
        end, 480), label .. ': Arkham enabled for the next plan\n' .. h.tail())
        h.assert_clean(label)
        no_compass(h, label)
        eq(A.runs, 1, label .. ': one War Plan horde'); eq(A.wave, 6)
        eq(h.logged('War Plan horde complete; no new cycle'), 1, label .. ': completed')
        eq(h.logged('turn-in cycle completed'), 1, label .. ': turned in')
        eq(h.board.confirmed, 1, label .. ': next plan submitted')
        eq(h.reward_accepts, 1, label .. ': Whisper claimed in the visit')
        eq(h.logged('run finished: success'), 1, label .. ': SilentRaven verified the claim')
        eq(h.count(h.alfred.triggers, function(t) return t.t >= released and t.context == WP end), 1,
            label .. ': one WarPigs Alfred cycle in the Temis visit')
        eq(h.count(h.alfred.triggers, function(t) return t.t >= released end), 1, label .. ': one Alfred cycle in total')
        eq(h.logged('Alfred already serviced this visit'), 1, label .. ': the next preamble joins it')
        ok(h.now - released <= 42, string.format('%s: Arkham enabled %.1fs after the Horde release', label, h.now - released))
        eq(h.place, h.P.temis, label .. ': Pit tower in Temis')
        if sticky and h.count(h.alfred.triggers, function(t) return t.context == HD end) > 0 then
            note('J6: a sticky advisory restock flag still sends HordeDev on its own Alfred trip from the chest room '
                .. '(open C1 item: advisory flags after the grace)')
        end
    end
end)

case('J7 standalone HordeDev (WarPigs off): compass farming unchanged', function()
    local h = setup({warpigs = false, warpug = false})
    h.remove_actor(h.table_actor)
    h.give_compasses(2)
    local A = h.setup_horde({quest_done = false})
    el(h, HD).main_toggle:set(true)
    local w = horde_watch(h)
    ok(h.run_until(function() w.each(); return A.runs >= 2 and h.resets >= 2 end, 480), 'J7: two hordes\n' .. h.tail())
    h.run(20, w.each)
    h.assert_clean('J7')
    eq(h.count(h.waypoints, function(x) return x.context == HD and x.sno == LIBRARY_WP end), 1, 'J7: Library teleport once')
    eq(#h.items, 2, 'J7: one compass per horde')
    for _, item in ipairs(h.items) do
        eq(item.context, HD); eq(item.from, 'caldeum', 'J7: compass used at the gate')
        eq(item.name, 'S05_DungeonSigil_BSK_Wave6')
    end
    eq(#h.sigil_confirms, 2, 'J7: sigil confirmed per horde')
    eq(h.count(h.arrivals, function(a) return a.place == 'bsk' and a.why == 'horde_portal' end), 2, 'J7: portal entries')
    eq(h.leaves, 2, 'J7: Leave Dungeon per horde'); eq(h.resets, 2, 'J7: reset per horde')
    eq(#h.warplans, 0, 'J7: no War Plan call')
    eq(h.logged('waiting up to 5s for WarPigs'), 0, 'J7: no WarPigs wait standalone')
    eq(h.logged('Entry mode: warplan'), 0, 'J7: compass mode')
    -- Guard: identical on d275b9d, which has no entry_mode / last_result.
    local st = status(h, 'InfernalHordesPlugin')
    ok(st.entry_mode == nil or st.entry_mode == 'compass', 'J7: compass mode')
    eq(st.last_result, nil, 'J7: no War Plan result in compass mode')
    ok(w.tasks['Start Dungeon'] and w.tasks['Enter Horde'] and w.tasks['Open Chests'], 'J7: the full compass cycle')
    ok(h.logged('Dungeon Sigil not found in inventory') >= 1, 'J7: out of compasses on the third cycle')
    eq(enabled(h, 'InfernalHordesPlugin'), true, 'J7: still farming')
end)

-- ═══ 7. Round 5: the round-4 critic/auditor probes as joint regressions ═════
-- K1 reload mid War Plan horde (critic probe_reload_midhorde), K2 Alfred's own
-- teleport trip mid-horde (probe_alfred_selfstart_trace), K3 BSK lobby
-- landings (probe_landing_variants), K4 a Stash visible from arrival
-- (probe_static_stash_loop / auditor probe_completion_edges), K5 user hotkey
-- pauses (probe_horde_hotkey_joint), K6 a sticky advisory restock flag across
-- a whole plan (round-5 policy). Each fails on 9e01f67 in at least one
-- variant; K1 'after the Council' and K2 'after the Council' also failed on
-- the round-5 tree before the joint-suite fixes (Found by this suite).
local PERSISTED_ON = {infernal_horde_main_toggle = true, war_pigs_main_toggle = true, war_pug_main_toggle = true,
    silent_raven_main_toggle = true}
local function wp_calls(h, export, name, t0)
    local out = {}
    for _, c in ipairs(h.api_calls) do
        if c.export == export and c.name == name and c.context == WP and c.t >= (t0 or 0) then out[#out + 1] = c end
    end
    return out
end
local function leave_time(h)
    local a = first(h.arrivals, function(x) return x.why == 'leave' end)
    return a and a.t
end

-- Found by this suite (K1 after the Council): the Horde quest is already gone
-- then, so nobody adopted the persisted HordeDev; it ran in compass mode and,
-- with no chest room, never exited (its fresh tracker never sees the door or
-- the Council): 'cleanup still pending', the turn-in never ran (also on
-- 9e01f67, and on 9e01f67 at wave 3 / at the door too).
case('K1 QQT reload mid War Plan horde (persisted toggles, place=bsk): War Plan mode, the run completes, exit, turn-in',
    function()
    local ARENAS = {{'chest room', true, true}, {'no chest room, stash', false, true},
        {'no chest room, no stash', false, false}}
    local variants = {}
    for _, at in ipairs({3, 'door', 'council_dead'}) do
        for _, arena in ipairs(ARENAS) do variants[#variants + 1] = {at = at, arena = arena, teleport = false} end
    end
    variants[#variants + 1] = {at = 3, arena = ARENAS[3], teleport = true}
    variants[#variants + 1] = {at = 'council_dead', arena = ARENAS[1], teleport = true}
    variants[#variants + 1] = {at = 'council_dead', arena = ARENAS[2], teleport = true}
    for _, v in ipairs(variants) do
        local label = string.format('K1 reload %s, %s, Use teleport %s', v.at == 3 and 'at wave 3'
            or v.at == 'door' and 'at the locked door' or 'after the Council', v.arena[1], v.teleport and 'on' or 'off')
        local persisted = J.copy(PERSISTED_ON)
        persisted.war_pigs_use_teleport_transition = v.teleport
        local h = J.new({place = 'bsk', persisted = persisted})
        h.assert_clean('load')
        h.instrument_exports()
        eq(el(h, HD).main_toggle:get(), true, label .. ': HordeDev toggle persisted on')
        h.give_compasses(3)
        h.set_quests({HORDE_Q})
        local A = h.setup_horde({chest_room = v.arena[2], stash = v.arena[3], resume_at = v.at})
        if v.at == 'council_dead' then
            eq(h.quests[1], 'WarPlans_QST_TurnIn_Rewards', label .. ': objective already done')
        end
        h.warplan_dest = 'bsk'
        local w = horde_watch(h)
        local mode_at
        ok(h.run_until(function()
            w.each()
            if not mode_at and status(h, 'InfernalHordesPlugin').entry_mode == 'warplan' then mode_at = h.now end
            return #h.quests == 0
        end, 300), label .. ': the horde and the turn-in complete (9e01f67 without a chest room: stuck in BSK)\n'
            .. h.tail())
        h.run(3, w.each)
        h.assert_clean(label)
        ok(mode_at and mode_at <= 1001 + 1e-6, label .. ': War Plan entry mode within 1 s: ' .. tostring(mode_at))
        eq(h.logged('switching it to War Plan entry mode'), 1, label .. ': the retag logged once')
        local enables = hd_calls(h, 'enable')
        eq(#enables, 1, label .. ': one enable')
        eq(enables[1].entry, 'warplan', label .. ': enable({entry = "warplan"})'); eq(enables[1].place, 'bsk', label)
        eq(h.logged('No enable/disable from WarPigs within 5s'), 0, label .. ': the F-H2 wait ended at once')
        eq(A.runs, 1, label .. ': the same horde'); eq(A.wave, 6, label)
        ok(A.council_dead_at ~= nil, label .. ': Council dead')
        if v.arena[2] then
            eq(#A.opened, 3, label .. ': the chest room was opened')
            eq(h.logged('Chest sequence finished'), 1, label .. ': chest phase finished')
        else
            eq(#A.opened, 0, label)
            eq(h.logged('no chest room; leaving without chests'), 1, label .. ': bounded completion without chests')
            if v.at == 'council_dead' then
                eq(h.logged('War Plan objective already complete for 20s and no chest room'), 1,
                    label .. ': evidence of a run started after the Council')
            end
        end
        local left = leave_time(h)
        ok(left and left - A.council_dead_at <= 75, string.format('%s: left %.1fs after the Council (bounded)', label,
            (left or math.huge) - A.council_dead_at))
        eq(h.leaves, 1, label .. ': Leave Dungeon'); eq(h.resets, 1, label .. ': reset')
        ok(w.completed and w.completed.chests_done, label .. ': last_result completed, chests_done()')
        eq(h.logged('War Plan horde complete; no new cycle'), 1, label .. ': completed')
        local released = first(hd_calls(h, 'disable'), function(c) return c.t >= w.completed.t end)
        ok(released and released.t - w.completed.t <= 4, label .. ': released right after the exit')
        eq(h.logged('cleanup still pending'), 0, label .. ': no endless handoff hold')
        no_compass(h, label)
        eq(warplan_tps(h), 0, label .. ': no War Plan teleport (already inside)')
        eq(h.count(h.waypoints, function(x) return x.from == 'bsk' end), 0, label .. ': nothing teleported out of BSK')
        outside_only(w, {['warplan:Exit Horde'] = true, ['warplan:War Plan horde complete'] = true}, label)
        ok(w.max_stall <= 3, label .. ': no silent idle stall')
        eq(h.logged('turn-in cycle completed'), 1, label .. ': turn-in')
    end
    -- Guard for the fix: a HordeDev left on in a compass horde while the War
    -- Plan is at another step (not a reload after the Council) is retagged
    -- too, but the 'objective already complete' evidence needs a quiet arena
    -- and a run that has not seen the door or the Council itself: it still
    -- plays every wave, the Council and the chests before leaving.
    for _, at in ipairs({0, 3}) do
        local label = 'K1 guard: compass horde left on while the plan is at the Pit, from wave ' .. at
        local h = J.new({place = 'bsk', persisted = J.copy(PERSISTED_ON)})
        h.assert_clean('load')
        h.instrument_exports()
        h.set_quests({'WarPlans_QST_ThePit'})
        local A = h.setup_horde({waves = 10, resume_at = at > 0 and at or nil})
        ok(h.run_until(function() return h.leaves >= 1 end, 400), label .. ': the horde ends\n' .. h.tail())
        local left = h.now
        ok(h.run_until(function() return enabled(h, 'ArkhamAsylumPlugin') end, 90), label .. ': the Pit next\n' .. h.tail())
        h.assert_clean(label)
        eq(h.logged('switching it to War Plan entry mode'), 1, label .. ': retagged once')
        eq(A.wave, 10, label .. ': every wave played'); ok(A.council_dead_at ~= nil, label .. ': Council killed')
        ok(left > A.council_dead_at, label .. ': left after the Council')
        ok(#A.opened >= 3, label .. ': chests opened: ' .. #A.opened)
        eq(h.logged('leaving without chests'), 0, label .. ': no early exit')
        eq(h.leaves, 1, label .. ': one Leave Dungeon'); eq(#h.items, 0, label .. ': no compass')
        ok(first(hd_calls(h, 'disable'), function(c) return c.t >= left - 1 end), label .. ': HordeDev released after its exit')
    end
end)

-- Found by this suite (K2 after the Council): with the Horde quest already
-- gone, WarPigs' disable_when released the War Plan HordeDev in Temis during
-- Alfred's trip (in_run == false outside the Horde); Alfred's portal then put
-- the player back into BSK and the turn-in teleported out of it: chests and
-- Leave Dungeon lost (also on 9e01f67). At wave 3 with 'Use teleport' on,
-- 9e01f67 released HordeDev and its preamble teleported out of BSK (2 hordes).
case("K2 Alfred's own teleport trip mid War Plan horde, back into the same horde: HordeDev kept, nothing leaves BSK",
    function()
    for _, v in ipairs({
        {'wave 3', 'wave3', true, false}, {'wave 3', 'wave3', true, true},
        {'the locked door', 'door', true, false}, {'the locked door', 'door', true, true},
        {'the chest room (after the Council)', 'council', true, false},
        {'the chest room (after the Council)', 'council', true, true},
        {'the boss room without a chest room (after the Council)', 'council', false, false},
        {'wave 3 with 45 s of Alfred work', 'wave3', true, true, 45},
    }) do
        local label = string.format('K2 at %s, Use teleport %s', v[1], v[4] and 'on' or 'off')
        local h = setup({quests = {HORDE_Q}, teleport = v[4]})
        local A = h.setup_horde({chest_room = v[3]})
        h.warplan_dest = 'bsk'
        local reached = ({
            wave3 = function() return A.wave >= 3 end,
            door = function() local e = A.events[#A.events]; return e ~= nil and e.what == 'locked door' end,
            council = function() return A.council_dead_at ~= nil end,
        })[v[2]]
        ok(h.run_until(reached, 400), label .. ': reached\n' .. h.tail())
        local mark = h.now
        -- Alfred starts its own with-teleport cycle (another caller).
        h.as(h.alfred_ctx, function() h.G.AlfredTheButlerPlugin.trigger_tasks_with_teleport('AlfredTheButler', nil) end)
        h.alfred.work = v[5] or 20
        local w = horde_watch(h)
        local town_frames, dropped = 0, false
        ok(h.run_until(function()
            w.each()
            local job = h.alfred.job -- Alfred's own trip out of the Horde (not a WarPigs cycle)
            if h.place == h.P.temis and job and job.teleport and job.exit == h.P.bsk then
                town_frames = town_frames + 1
                if not enabled(h, 'InfernalHordesPlugin') then dropped = true end
            end
            return #h.quests == 0
        end, 500), label .. ': the horde and the turn-in\n' .. h.tail())
        h.run(3)
        h.assert_clean(label)
        ok(first(h.arrivals, function(a) return a.t >= mark and a.place == 'temis' and a.why == 'alfred' end)
            and first(h.arrivals, function(a) return a.t >= mark and a.place == 'bsk' and a.why == 'alfred_return' end),
            label .. ': Alfred took the player to Temis and back into the same horde')
        ok(town_frames > 50 and not dropped, label .. ': HordeDev kept over the town leg (9e01f67 after the Council: '
            .. 'released in Temis)')
        eq(A.runs, 1, label .. ': one horde (9e01f67 wave 3, teleport on: 2)'); eq(A.wave, 6, label)
        ok(A.council_dead_at ~= nil, label .. ': Council dead')
        if v[3] then
            eq(#A.opened, 3, label .. ': the chests were opened (9e01f67 after the Council: 0)')
        else
            eq(h.logged('no chest room; leaving without chests'), 1, label .. ': bounded completion without chests')
        end
        eq(h.leaves, 1, label .. ': Leave Dungeon (9e01f67 after the Council: the turn-in teleported out of BSK)')
        local completed = log_time(h, 'War Plan horde complete; no new cycle')
        ok(completed, label .. ': completed')
        for _, c in ipairs(hd_calls(h, 'disable')) do
            -- log times carry one decimal
            ok(c.t >= completed - 0.05, string.format('%s: released only after its completion (%.1f < %.1f)', label,
                c.t, completed))
        end
        eq(#hd_calls(h, 'enable'), 1, label .. ': one enable')
        eq(h.count(h.waypoints, function(x) return x.from == 'bsk' end), 0,
            label .. ': no teleport_to_waypoint from BSK')
        eq(h.count(h.warplans, function(x) return x.kind == 'teleport' and x.from == 'bsk' end), 0,
            label .. ': no War Plan teleport from BSK')
        eq(warplan_tps(h), 1, label .. ': one War Plan teleport')
        eq(h.logged('finished its War Plan run'), 0, label .. ': no false "finished" release')
        eq(h.logged('left the Horde without a completed run'), 0, label)
        no_compass(h, label)
        local turned = log_time(h, 'turn-in cycle completed')
        ok(turned and turned > leave_time(h), label .. ': the turn-in after the exit')
        if v[2] == 'council' then
            ok(h.logged('HordeDev War Plan run is out of the Horde during an Alfred trip or a teleport') >= 1,
                label .. ': the hold is logged (C6)')
        end
    end
end)

case('K3 War Plan teleport lands in a BSK lobby zone: no compass, the reason and a report request (fallback on/off)',
    function()
    local function odd_place(h, world, zone)
        local place = {key = 'lobby', name = world, zone = zone, id = 6, town = false, spawn = h.v(0, 0),
            box = {-80, 80, -80, 80}, actors = {}}
        h.P.lobby = place
        return place
    end
    local LOBBY_W, LOBBY_Z = 'S05_BSK_Prototype02', 'S05_BSK_Lobby'
    for _, v in ipairs({
        {'lobby, fallback off, Use teleport off', LOBBY_W, LOBBY_Z, false, false},
        {'lobby, fallback on, Use teleport off', LOBBY_W, LOBBY_Z, true, false},
        {'lobby, fallback off, Use teleport on', LOBBY_W, LOBBY_Z, false, true},
        {'lobby, fallback on, Use teleport on', LOBBY_W, LOBBY_Z, true, true},
        {'the Horde zone in a world without BSK, fallback on', 'WarPlan_Hordes', 'S05_BSK_Prototype02', true, false},
    }) do
        local label = 'K3 ' .. v[1]
        local h = setup({quests = {HORDE_Q}, teleport = v[5]})
        if v[4] then el(h, WP).horde_compass_fallback:set(true) end
        h.give_compasses(2)
        h.warplan_dest = odd_place(h, v[2], v[3])
        local report_text = string.format('landed in a BSK zone HordeDev does not know (zone=%s, world=%s) — '
            .. 'please report; not using a compass', v[3], v[2])
        local shown, hd_on = 0, false
        h.run(150, function()
            if status_line(h):find(report_text .. ' — retrying the War Plan teleport in', 1, true) then
                shown = shown + 1
            end
            if enabled(h, 'InfernalHordesPlugin') then hd_on = true end
        end)
        h.assert_clean(label)
        eq(#hd_calls(h, 'enable'), 0, label .. ': HordeDev never enabled (9e01f67 fallback on: enable() in the lobby)')
        eq(hd_on, false, label .. ': HordeDev stays off')
        no_compass(h, label)
        local tps = {}
        for _, x in ipairs(h.warplans) do if x.kind == 'teleport' then tps[#tps + 1] = x end end
        ok(#tps >= 4 and #tps <= 6, label .. ': three War Plan teleports per round, then round 2: ' .. #tps)
        ok(tps[4].t - tps[3].t >= 60 - 1e-6, string.format('%s: 60 s backoff (%.1fs)', label, tps[4].t - tps[3].t))
        eq(h.logged('War Plan Horde entry: 3 War Plan teleports did not reach the Horde: ' .. report_text
            .. (v[4] and ' (compass fallback not used in a BSK zone)' or '') .. '; retrying in 60s'), 2,
            label .. ': the reason logged once per round')
        eq(h.logged('compass fallback is on'), 0, label .. ': the compass fallback never engages in a BSK zone')
        eq(h.logged('enabling it to navigate itself'), 0, label .. ': no WPD-3 bypass')
        ok(shown >= 300, label .. ': the report request is in the status line during the backoff ('
            .. shown .. ' frames)')
    end
    -- The landing recovers in round 2: the normal War Plan horde follows.
    for _, tp in ipairs({false, true}) do
        local label = 'K3 recovery in round 2, Use teleport ' .. (tp and 'on' or 'off')
        local h = setup({quests = {HORDE_Q}, teleport = tp})
        el(h, WP).horde_compass_fallback:set(true)
        local lobby = odd_place(h, LOBBY_W, LOBBY_Z)
        h.give_compasses(2)
        local A = h.setup_horde({})
        local n = 0
        h.warplan_dest = function() n = n + 1; return n > 3 and 'bsk' or lobby end
        ok(h.run_until(function() return #h.quests == 0 end, 420), label .. ': the horde and the turn-in\n' .. h.tail())
        h.assert_clean(label)
        eq(warplan_tps(h), 4, label .. ': three misses, then the Horde')
        local enables = hd_calls(h, 'enable')
        eq(#enables, 1, label .. ': one enable')
        eq(enables[1].entry, 'warplan', label); eq(enables[1].place, 'bsk', label)
        eq(A.runs, 1, label); eq(A.wave, 6, label); eq(#A.opened, 3, label .. ': chests')
        no_compass(h, label)
        eq(h.logged('turn-in cycle completed'), 1, label .. ': turn-in')
    end
end)

-- The lead's round-4 gate (completion evidence only while the wave task is
-- idle in the boss room) and H5-1 (a stale idle reading while another task
-- holds the queue). 9e01f67 has the gate but not H5-1: with another caller's
-- Alfred work in the boss room the horde was left at the door and a second
-- horde followed.
case('K4 Stash visible from arrival: the Council is killed and the chests opened before the exit', function()
    for _, v in ipairs({
        {'chest room, 75 s Council fight', true, 3000, false, false},
        {'chest room, 75 s Council fight', true, 3000, true, false},
        {'chest room, 10 s Council fight', true, 400, false, false},
        {'no chest room, 75 s Council fight', false, 3000, false, false},
        {"chest room, another caller's Alfred work in the boss room", true, 3000, false, true},
        {"chest room, another caller's Alfred work in the boss room", true, 3000, true, true},
        {"no chest room, another caller's Alfred work in the boss room", false, 3000, false, true},
    }) do
        local label = string.format('K4 %s, Use teleport %s', v[1], v[4] and 'on' or 'off')
        local h = setup({quests = {HORDE_Q}, teleport = v[4]})
        local A = h.setup_horde({boss_health = v[3], chest_room = v[2], stash = false})
        local arrive = h.P.bsk.on_arrive
        h.P.bsk.on_arrive = function(a, trip) -- the Stash is part of the arena
            arrive(a, trip)
            if not (trip and trip.why == 'alfred_return') then h.actor('bsk', 'Stash', -40, -38) end
        end
        h.warplan_dest = 'bsk'
        local tracker = h.mod(HD, 'core.tracker')
        local held, left_at
        ok(h.run_until(function()
            if v[5] and not held and tracker.locked_door_found and tracker.horde_idle_since ~= nil
                and not A.council_dead_at then
                -- Another caller's Alfred cycle (no teleport) while the wave
                -- task was idle in the boss room: the player stays in BSK.
                held = h.now
                h.as(h.alfred_ctx, function() h.G.AlfredTheButlerPlugin.trigger_tasks('AlfredTheButler', nil) end)
                h.alfred.work = 30
            end
            if not left_at and h.leaves >= 1 then left_at = h.now end
            return #h.quests == 0 or A.runs >= 3
        end, 900), label .. ': the turn-in\n' .. h.tail())
        h.run(2)
        h.assert_clean(label)
        eq(A.runs, 1, label .. ': one horde (9e01f67 with the boss-room hold: 2)')
        local door, opened, dead = arena_event(A, 'locked door', 1), arena_event(A, 'door opened', 1),
            arena_event(A, 'council dead', 1)
        ok(door and opened and dead, label .. ': door opened and Council killed\n' .. h.tail())
        ok(opened.t - door.t > 20, string.format(
            '%s: the door approach (%.1fs) outlasts CHEST_WAIT with the Stash in sight', label, opened.t - door.t))
        ok(left_at and left_at > dead.t, label .. ': left only after the Council died')
        if v[5] then
            local pylon = arena_event(A, 'council pylon', 1)
            ok(held and pylon.t - held >= 25, label .. ': the Alfred hold ran in the boss room')
        end
        if v[2] then
            eq(#A.opened, 3, label .. ': the chests were opened')
            eq(h.logged('no chest room'), 0, label .. ': no chest skip')
        else
            local skip = log_time(h, 'stash visible for 20s and no chest room; leaving without chests')
            ok(skip and skip >= dead.t + 20 - 0.5, string.format(
                '%s: the bounded skip only after the boss room is idle (skip %s, Council dead %.1f)', label,
                tostring(skip), dead.t))
        end
        eq(h.leaves, 1, label .. ': one Leave Dungeon')
        eq(h.logged('War Plan horde complete; no new cycle'), 1, label .. ': completed once')
        no_compass(h, label)
        eq(h.logged('turn-in cycle completed'), 1, label .. ': turn-in')
    end
end)

-- W5-4 beyond J5: a pause that holds the handoff (the quest is gone while the
-- plugin is paused) and a pause long enough for the C6 watchdog.
case('K5 user hotkey pause under WarPigs: HordeDev in the chest room, Arkham while the plan moves on; WarPigs waits',
    function()
    for _, v in ipairs({{true, false}, {false, false}, {true, true}, {false, true}}) do
        local chest, tp = v[1], v[2]
        local label = string.format('K5 HordeDev paused after the Council, %s, Use teleport %s',
            chest and 'chest room' or 'no chest room', tp and 'on' or 'off')
        local h = setup({quests = {HORDE_Q}, teleport = tp})
        el(h, HD).use_keybind:set(true); el(h, HD).keybind_toggle:set_key(0x70)
        local A = h.setup_horde({chest_room = chest})
        h.warplan_dest = 'bsk'
        ok(h.run_until(function() return A.council_dead_at ~= nil end, 400), label .. ': Council dead\n' .. h.tail())
        h.run(1)
        el(h, HD).keybind_toggle.state = 0 -- the user presses HordeDev's hotkey in the chest room
        local p = h.now
        local shown = 0
        h.run(60, function()
            if status_line(h):find('InfernalHordesPlugin ' .. PAUSED, 1, true) then shown = shown + 1 end
        end)
        local st = status(h, 'InfernalHordesPlugin')
        eq(st.enabled, false, label .. ': still paused'); eq(st.in_run, true, label .. ': C2 in_run')
        eq(count_since(h.waypoints, p), 0, label .. ': no teleport (the turn-in waits for the paused HordeDev)')
        eq(count_since(h.warplans, p), 0, label)
        eq(h.place, h.P.bsk, label .. ': still in the Horde')
        eq(h.logged('turn-in cycle completed'), 0, label .. ': the turn-in is held')
        eq(#hd_calls(h, 'enable') + #hd_calls(h, 'disable'), 1, label .. ': no WarPigs enable/disable over the pause')
        eq(h.logged('[WarPigs] InfernalHordesPlugin ' .. PAUSED .. ' (it reports a run in progress'), 1,
            label .. ': the wait logged once')
        ok(shown >= 590, label .. ': the wait is visible (' .. shown .. ' of 600 frames)')
        el(h, HD).keybind_toggle.state = 1
        ok(h.run_until(function() return #h.quests == 0 end, 300),
            label .. ': chests/exit and the turn-in\n' .. h.tail())
        h.run(2)
        h.assert_clean(label)
        eq(h.logged('InfernalHordesPlugin reports enabled again'), 1, label .. ': resume logged')
        eq(#hd_calls(h, 'enable'), 1, label .. ': resumed without an enable()')
        eq(A.runs, 1, label .. ': the same horde')
        if chest then eq(#A.opened, 3, label .. ': the chests')
        else eq(h.logged('no chest room; leaving without chests'), 1, label .. ': bounded completion') end
        eq(h.leaves, 1, label .. ': Leave Dungeon'); eq(h.logged('War Plan horde complete; no new cycle'), 1, label)
        local released = first(hd_calls(h, 'disable'), function(c) return c.t >= p end)
        ok(released and released.place ~= 'bsk', label .. ': released outside the Horde, after the exit')
        no_compass(h, label)
        eq(h.logged('turn-in cycle completed'), 1, label .. ': turn-in')
    end
    for _, tp in ipairs({false, true}) do
        local label = 'K5 Arkham paused in the Pit while the plan moves on to an Undercity, Use teleport '
            .. (tp and 'on' or 'off')
        local h = setup({place = 'pit', quests = {'WarPlans_QST_ThePit'}, teleport = tp})
        el(h, ARK).use_keybind:set(true); el(h, ARK).keybind_toggle:set_key(0x70)
        for i = 1, 4 do h.actor('pit', 'Pit_Monster_' .. i, 20 + i * 15, (i % 2) * 6, {enemy = true}) end
        ok(h.run_until(function() return enabled(h, 'ArkhamAsylumPlugin') end, 10), label .. ': Arkham started')
        h.run(5)
        el(h, ARK).keybind_toggle.state = 0 -- the user presses Arkham's hotkey
        local p = h.now
        h.run(3)
        h.set_quests({'WarPlans_QST_Undercity'})
        h.warplan_dest = 'kurast'
        local wc_on = false
        h.run(125, function() if enabled(h, 'WonderCityPlugin') then wc_on = true end end)
        local st = status(h, 'ArkhamAsylumPlugin')
        eq(st.enabled, false, label .. ': still paused'); eq(st.in_run, true, label .. ': C2 in_run in the Pit')
        eq(wc_on, false, label .. ': WonderCity not started over the paused Arkham (handoff held)')
        eq(count_since(h.waypoints, p), 0, label .. ': no teleport'); eq(count_since(h.warplans, p), 0, label)
        eq(h.place, h.P.pit, label .. ': still in the Pit')
        eq(#wp_calls(h, 'ArkhamAsylumPlugin', 'enable', p) + #wp_calls(h, 'ArkhamAsylumPlugin', 'disable', p), 0,
            label .. ': no enable/disable over the pause')
        eq(h.logged('[WarPigs] ArkhamAsylumPlugin ' .. PAUSED .. ' (it reports a run in progress'), 1,
            label .. ': the wait logged once')
        local line = status_line(h)
        ok(line:find('pending disable: ArkhamAsylumPlugin (ArkhamAsylumPlugin ' .. PAUSED .. ')', 1, true),
            label .. ': the held handoff names the pause: ' .. line)
        ok(h.logged('watchdog: handoff gate held for') >= 1, label .. ': the C6 watchdog reports the long hold')
        el(h, ARK).keybind_toggle.state = 1 -- the user resumes Arkham
        local r = h.now
        h.run(6)
        eq(enabled(h, 'ArkhamAsylumPlugin'), true, label .. ': resumed')
        eq(h.logged('ArkhamAsylumPlugin reports enabled again'), 1, label .. ': resume logged')
        eq(#wp_calls(h, 'ArkhamAsylumPlugin', 'enable', p), 0, label .. ': resumed without an enable()')
        ok(first(h.bm_calls, function(c) return c.context == ARK and c.t > r end), label .. ': Arkham drives again')
        eq(h.place, h.P.pit, label .. ': the same Pit run')
        -- Arkham's run ends in town; the Undercity follows.
        h.travel_to('temis', 1.0, 'pit_exit')
        ok(h.run_until(function() return enabled(h, 'WonderCityPlugin') end, 90),
            label .. ': WonderCity next\n' .. h.tail())
        h.assert_clean(label)
        local released = first(wp_calls(h, 'ArkhamAsylumPlugin', 'disable', r), function() return true end)
        ok(released and released.place == 'temis', label .. ': Arkham released in town after the resume')
        local wc = first(wp_calls(h, 'WonderCityPlugin', 'enable', r), function() return true end)
        ok(wc and wc.t >= released.t + 5 - 1e-6, label .. ': WonderCity after the post-disable gap')
    end
end)

-- The round-5 policy across one War Plan: Pit -> Undercity -> Horde -> Reaper
-- -> Helltide -> turn-in with Steroid's sticky restock flag. Advisory Alfred
-- trips come only from WarPigs, in Temis, at most once per Temis visit; a
-- hard need (a full bag in the Pit and in the Undercity) still sends the
-- activity plugin's own trip at once. 9e01f67: WonderCity, HordeDev and Reaper
-- each made advisory trips of their own.
case('K6 sticky advisory restock flag across a full plan: advisory Alfred only from WarPigs in Temis, once per visit',
    function()
    local Q = {pit = 'WarPlans_QST_ThePit', uc = 'WarPlans_QST_Undercity', boss = 'WarPlans_QST_BossLair_Andariel',
        ht = 'WarPlans_QST_Helltide_TorturedGifts', turn = 'WarPlans_QST_TurnIn_Rewards'}
    local DEST = {[Q.uc] = 'kurast', [HORDE_Q] = 'bsk', [Q.boss] = 'lair', [Q.ht] = 'helltide'}
    for _, tp in ipairs({false, true}) do
        local label = 'K6 Use teleport ' .. (tp and 'on' or 'off')
        local h = setup({quests = {Q.pit}, teleport = tp, virtual_os_time = true})
        h.alfred.need_trigger, h.alfred.sticky_need, h.alfred.restock_count = true, true, 2
        h.setup_undercity()
        local A = h.setup_horde({next_quest = Q.boss})
        h.setup_lair(function(hh) hh.at(3, function() hh.set_quests({Q.ht}) end) end, {altar_stays = true})
        for i = 1, 4 do h.actor('pit', 'Pit_Monster_' .. i, 20 + i * 15, (i % 2) * 6, {enemy = true}) end
        for i = 1, 3 do h.actor('undercity', 'Undercity_Monster_' .. i, 25 + i * 20, 0, {enemy = true}) end
        h.warplan_dest = function(hh) return DEST[hh.quests[1]] end
        h.P.helltide.helltide = true
        local phase, since, visit, in_temis = 'pit', nil, 1, true
        local trips, seen, hard = {}, 0, {}
        ok(h.run_until(function()
            local here = h.place == h.P.temis
            if here and not in_temis then visit = visit + 1 end
            in_temis = here
            while seen < #h.alfred.triggers do
                seen = seen + 1
                local t = h.alfred.triggers[seen]
                trips[#trips + 1] = {t = t.t, context = t.context, place = t.place, visit = here and visit or nil}
            end
            if phase == 'pit' and h.place == h.P.pit then
                since = since or h.now
                if not hard.full and h.now - since > 6 then hard.full = h.now; h.alfred.inventory_full = true end
                if h.now - since > 25 and not h.travel then
                    h.set_quests({Q.uc}); h.travel_to('temis', 1.0, 'pit_exit'); phase, since = 'uc', nil
                end
            elseif phase == 'uc' and h.place == h.P.undercity then
                since = since or h.now
                -- WonderCity services only a full bag inside an Undercity
                -- (repairs wait for the end of the run: its unchanged rule).
                if not hard.bag and h.now - since > 6 then hard.bag = h.now; h.alfred.inventory_full = true end
                if h.now - since > 30 and not h.travel and not h.alfred.job then
                    h.set_quests({HORDE_Q}); h.travel_to('kurast', 1.0, 'undercity_exit'); phase, since = 'rest', nil
                end
            elseif phase == 'rest' and h.quests[1] == Q.ht and h.place == h.P.helltide then
                since = since or h.now
                if h.now - since > 30 then h.set_quests({Q.turn}); phase = 'turn' end
            elseif phase == 'turn' and #h.quests == 0 then
                return true
            end
            return false
        end, 1500), label .. ': the whole plan and the turn-in (phase ' .. phase .. ')\n' .. h.tail())
        h.run(2)
        h.assert_clean(label)
        -- every activity ran
        for _, want in ipairs({{'pit', 'pit_portal'}, {'undercity', 'undercity_portal'}, {'bsk', 'warplan'},
            {'helltide'}}) do
            ok(first(h.arrivals, function(a) return a.place == want[1] and (want[2] == nil or a.why == want[2]) end),
                label .. ': reached ' .. want[1])
        end
        eq(A.runs, 1, label .. ': one horde'); eq(A.wave, 6, label); eq(#A.opened, 3, label .. ': Horde chests')
        ok(h.chest_opened_at ~= nil, label .. ': the boss chest')
        eq(status(h, 'ReaperPlugin').last_result, 'success', label .. ': Reaper run_once success')
        no_compass(h, label)
        eq(h.logged('turn-in cycle completed'), 1, label .. ': turn-in')
        -- Alfred: the two hard needs at once, everything else WarPigs in Temis.
        local listing = {}
        for _, t in ipairs(trips) do
            listing[#listing + 1] = string.format('%.1f %s %s v%s', t.t, t.context, t.place, tostring(t.visit))
        end
        listing = table.concat(listing, '; ')
        local per_visit, wp_trips, own = {}, 0, {}
        for _, t in ipairs(trips) do
            if t.context == WP then
                wp_trips = wp_trips + 1
                eq(t.place, 'temis', label .. ': WarPigs services Alfred in Temis [' .. listing .. ']')
                ok(t.visit ~= nil, label .. ': during a Temis visit')
                per_visit[t.visit] = (per_visit[t.visit] or 0) + 1
                ok(per_visit[t.visit] <= 1, label .. ': at most one Alfred cycle per Temis visit [' .. listing .. ']')
            else
                own[#own + 1] = t
            end
        end
        ok(wp_trips >= 1, label .. ': WarPigs serviced the advisory flag [' .. listing .. ']')
        eq(#own, 2, label .. ': only the two hard-need trips by activity plugins '
            .. '(9e01f67: WonderCity, HordeDev, Reaper advisory trips) [' .. listing .. ']')
        eq(own[1].context, ARK, label .. ': full bag in the Pit -> Arkham [' .. listing .. ']')
        eq(own[1].place, 'pit', label)
        ok(own[1].t - hard.full <= 1.0, string.format('%s: at once (%.1fs)', label, own[1].t - hard.full))
        eq(own[2].context, WC, label .. ': full bag in the Undercity -> WonderCity [' .. listing .. ']')
        eq(own[2].place, 'undercity', label)
        ok(own[2].t - hard.bag <= 1.0, string.format('%s: at once (%.1fs)', label, own[2].t - hard.bag))
        ok(h.logged('advisory Alfred restock skipped: WarPigs is enabled and services it in Temis') >= 1,
            label .. ': the activity plugins log the skip')
        eq(h.logged('Advisory Alfred flag left to WarPigs'), 1, label .. ': HordeDev chest-room skip logged once')
    end
end)

for _, line in ipairs(report) do print('NOTE joint: ' .. line) end
if #failures > 0 then
    error(#failures .. ' of ' .. cases .. ' joint scenario(s) failed:\n' .. table.concat(failures, '\n'))
end
print(string.format('PASS: joint suite (all nine plugins in one host): %d scenarios, %d checks', cases, checks))
