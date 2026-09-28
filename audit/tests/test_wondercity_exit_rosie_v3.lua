-- QQT_Warpigz_v3 WonderCity 2.2.6: Kurast<->Temis ping-pong at run end
-- (audit/reviews/undercity_teleports_2026-09-28.md). Rosie serves Temis
-- only. A need left over from the run (need_repair here; WonderCity's alfred
-- task only acts on inventory_full inside the Undercity) used to cost 3
-- waypoint casts: the exit to Kurast, Rosie's hop to Temis, teleport_kurast
-- back. The exit now goes straight to Temis when a Rosie need is pending:
-- 2 casts. Without a need, or without Rosie, the exit keeps the working town.
-- Joint host, standalone WonderCity + real Batmobile (+ real Rosie).
-- Runs under Lua 5.4 and LuaJIT.
local SUITE = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local checks, failures = 0, {}
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
local function case(name, fn)
    local passed, err = xpcall(fn, debug.traceback)
    if passed then print('PASS WonderCity exit/Rosie: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL WonderCity exit/Rosie: ' .. name .. ': ' .. tostring(err)) end
end

local J = dofile(SUITE .. '/audit/tests/joint_host.lua')

-- A standalone WonderCity run in the Undercity that ends by the forced
-- timeout (30 s, no exit delay), exit mode 1 (teleport). Working town Kurast.
local function run_end(opts)
    local h = J.new({rosie = opts.rosie, dirs = {'Batmobile', 'WonderCity'}, place = 'undercity'})
    h.assert_clean('load')
    local wc = h.mod('WonderCity', 'gui').elements
    wc.skip_tribute:set(true); wc.exit_mode:set(1)
    wc.reset_timeout:set(30); wc.exit_undercity_delay:set(0)
    if opts.rosie then
        h.mod('Rosie', 'rosie.private.town.gui').elements.use_keybind:set(true) -- no automatic trips
        ok(h.as('Rosie', function() return h.G.RosiePlugin.enable() end))
    end
    if opts.setup then opts.setup(h) end
    wc.main_toggle:set(true)
    ok(h.run_until(function() return h.logged('teleport out') > 0 end, 90), 'the run ended\n' .. h.tail(30))
    return h
end
local function casts_since(h, t)
    local list = {}
    for _, w in ipairs(h.waypoints) do
        if w.t >= t then list[#list + 1] = (J.WAYPOINTS[w.sno] or tostring(w.sno)) .. '<-' .. tostring(w.from) end
    end
    return list
end

case('R1 need_repair left at run end: exit to Temis, Rosie serves there without a cast, one cast back (2, was 3)', function()
    local h = run_end({rosie = true, setup = function(h) h.equipped = {h.gear({durability = 5})} end})
    local mark = h.now - 0.2
    ok(h.run_until(function()
        return h.logged('[Rosie] completed') + h.logged('[Rosie] failed') > 0 and h.place.key == 'kurast'
    end, 200), 'the trip ended back in Kurast\n' .. h.tail(40))
    h.run(10) -- nothing re-casts once home
    local casts = casts_since(h, mark)
    eq(#casts, 2, 'waypoint casts from the exit to the return to Kurast (' .. table.concat(casts, ', ') .. ')')
    eq(casts[1], 'temis<-undercity', 'the exit goes to Temis')
    eq(casts[2], 'kurast<-temis', 'teleport_kurast brings the player back')
    eq(h.logged('[Rosie] completed'), 1, 'Rosie completed the service')
    eq(h.equipped[1].durability, 100, 'repaired')
    eq(h.logged('Rosie need pending at run end'), 1, 'decision logged once')
    eq(h.logged('teleport_failed'), 0, 'no teleport_failed')
    eq(#h.errors, 0, 'no host errors')
end)

case('R1b the destination is decided once per exit: a debounced re-cast after a cut channel still goes to Temis', function()
    local h = run_end({rosie = true, setup = function(h) h.equipped = {h.gear({durability = 5})} end})
    local mark = h.now - 0.2
    h.travel, h.casting = nil, false -- the channel is cut: still in the Undercity
    h.equipped[1].durability = 100   -- the need reads clear by now
    ok(h.run_until(function() return #casts_since(h, mark) >= 2 end, 20), 're-cast\n' .. h.tail(20))
    local casts = casts_since(h, mark)
    eq(casts[1], 'temis<-undercity'); eq(casts[2], 'temis<-undercity', 'the re-cast keeps the destination')
    eq(h.logged('Rosie need pending at run end'), 1, 'logged once per exit')
end)

case('R2 no Rosie need at run end: the exit keeps the working town (Kurast), one cast', function()
    local h = run_end({rosie = true})
    local mark = h.now - 0.2
    ok(h.run_until(function() return h.place.key == 'kurast' end, 60), 'back in Kurast\n' .. h.tail(30))
    h.run(10)
    local casts = casts_since(h, mark)
    eq(#casts, 1, 'casts (' .. table.concat(casts, ', ') .. ')')
    eq(casts[1], 'kurast<-undercity')
    eq(h.logged('Rosie need pending at run end'), 0)
    eq(#h.errors, 0, 'no host errors')
end)

case('R3 without Rosie (a C1 Alfred only) a pending need_repair keeps the working town', function()
    local h = run_end({rosie = false, setup = function(h) h.alfred.need_trigger, h.alfred.need_repair = true, true end})
    local mark = h.now - 0.2
    h.run(3)
    local casts = casts_since(h, mark)
    ok(#casts >= 1, 'a cast')
    eq(casts[1], 'kurast<-undercity', 'the exit goes to the working town')
    eq(h.logged('Rosie need pending at run end'), 0)
end)

if #failures > 0 then error(#failures .. ' WonderCity exit/Rosie case(s) failed:\n' .. table.concat(failures, '\n')) end
print('WonderCity exit/Rosie: ' .. checks .. ' checks')
