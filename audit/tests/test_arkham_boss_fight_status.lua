-- QQT_Warpigz_v3 Arkham 2.1.5 (contract C-boss, sweep 2026-09-28 #6 / S2 F3,
-- F3b): ArkhamAsylumPlugin.get_status() publishes boss_fight so Rosie's
-- automatic trip can wait (Arkham's own boss/glyph defers only gated its own
-- Alfred request). Real ArkhamAsylum + Batmobile in the joint host.
--   C1 a live boss 1.5 m away: boss_fight = true; false once it is dead.
--   C2 a pending glyph upgrade: boss_fight = true until glyph_done.
--   C3 bounded by Arkham's own clocks: boss 90 s, glyph 120 s; a read gap
--      starts the clock over.
--   C4 Arkham disabled, or outside the pit: false.
-- The field did not exist pre-fix (boss_fight == nil).
local ROOT = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local J = dofile(ROOT .. '/audit/tests/joint_host.lua')
local checks, failures = 0, {}
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
local function case(name, fn)
    local passed, err = xpcall(fn, debug.traceback)
    if passed then print('PASS arkham-boss-fight-status: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL arkham-boss-fight-status: ' .. name .. ': ' .. tostring(err)) end
end
local CONSUMER = {name = 'Consumer', dir = ROOT .. '/audit/tests/', loaded = {}}
local function new(enabled)
    local h = J.new({dirs = {'ArkhamAsylum', 'Batmobile'}, place = 'pit'})
    h.assert_clean('load')
    h.pos = h.v(0, 0)
    if enabled then h.mod('ArkhamAsylum', 'gui').elements.main_toggle:set(true) end
    h.run(1)
    return h
end
local function status(h)
    return h.as(CONSUMER, function() return h.G.ArkhamAsylumPlugin.get_status() end)
end

case('C1 live boss 1.5 m away: boss_fight while it lives, false once dead', function()
    local h = new(true)
    eq(status(h).boss_fight, false, 'no boss: boss_fight')
    local boss = h.actor('pit', 'Joint_Pit_Guardian', 1.5, 0, {enemy = true, boss = true, health = 1e9})
    h.run(0.5)
    eq(status(h).boss_fight, true, 'live boss 1.5 m away: boss_fight')
    h.run(10, function(hh) ok(status(hh).boss_fight == true, 'boss_fight dropped during the fight') end)
    boss.health = 0
    h.run(0.5)
    eq(status(h).boss_fight, false, 'dead boss: boss_fight')
end)

case('C2 glyph upgrade pending: boss_fight until glyph_done', function()
    local h = new(true)
    local tracker = h.mod('ArkhamAsylum', 'core.tracker')
    h.actor('pit', 'Gizmo_Paragon_Glyph_Upgrade', 1, 0, {})
    h.run(0.5)
    eq(status(h).boss_fight, true, 'glyphstone up, upgrade pending: boss_fight')
    -- The emulated glyph list is empty: upgrade_glyph ends by its own 8 s window.
    ok(h.run_until(function() return tracker.glyph_done == true end, 30), 'glyph_done')
    eq(status(h).boss_fight, false, 'after glyph_done: boss_fight')
end)

case('C3 bounded by its own clocks (boss 90 s, glyph 120 s), a read gap restarts them', function()
    local h = new(false)
    local alfred = h.mod('ArkhamAsylum', 'tasks.alfred')
    local settings = h.mod('ArkhamAsylum', 'core.settings')
    local read = function() return h.as('ArkhamAsylum', function() return alfred.boss_fight() end) end
    h.actor('pit', 'Joint_Pit_Guardian', 1.5, 0, {enemy = true, boss = true, health = 1e9})
    local t0 = h.now
    local last_true
    h.run(100, function(hh) if read() then last_true = hh.now - t0 end end)
    ok(last_true and last_true >= 89 and last_true <= 90.5, 'boss hold ends at ~90 s, last true at ' .. tostring(last_true))
    eq(read(), false, 'boss hold over')
    h.run(5) -- not read for 5 s: a new episode
    eq(read(), true, 'a read gap starts the boss clock over')
    for _, a in ipairs(h.P.pit.actors) do if a.boss then a.health = 0 end end
    settings.upgrade_toggle = true
    h.actor('pit', 'Gizmo_Paragon_Glyph_Upgrade', 1, 0, {})
    t0, last_true = h.now, nil
    h.run(130, function(hh)
        settings.upgrade_toggle = true
        if read() then last_true = hh.now - t0 end
    end)
    ok(last_true and last_true >= 119 and last_true <= 120.5, 'glyph hold ends at ~120 s, last true at ' .. tostring(last_true))
end)

case('C4 Arkham disabled or outside the pit: false', function()
    local h = new(false)
    h.actor('pit', 'Joint_Pit_Guardian', 1.5, 0, {enemy = true, boss = true, health = 1e9})
    h.run(0.5)
    eq(status(h).boss_fight, false, 'Arkham disabled: boss_fight')
    local g = new(true)
    g.actor('temis', 'Joint_Boss', g.P.temis.spawn:x() + 1, g.P.temis.spawn:y(), {enemy = true, boss = true, health = 1e9})
    g.travel_to('temis', 0.5, 'test')
    g.run(3)
    eq(status(g).boss_fight, false, 'outside the pit: boss_fight')
end)

if #failures > 0 then error(#failures .. ' arkham boss-fight status case(s) failed:\n' .. table.concat(failures, '\n')) end
print(string.format('PASS: arkham boss-fight status, %d checks', checks))
