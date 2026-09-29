-- QQT_Warpigz_v3 Rosie 1.0.31 (owner: Worldstone v0.1.9 shows "Required
-- plugins: Butler"): Rosie stands in for Butler (rosie/private/butler_mimic.lua)
-- the way she stands in for Scavenger: _G.Butler (_rosie=true) only while
-- _G.Worldstone exists, the option is on and no real Butler is loaded; a real
-- Butler is never overwritten and wins when it loads later. is_busy covers a
-- whole Rosie trip; needs_visit is true only while Rosie's automatic service
-- will run the trip; any other name is a logged no-op; Rosie never yields to
-- her own stand-in.
local ROOT = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local J = dofile(ROOT .. '/audit/tests/joint_host.lua')
local checks, failures = 0, {}
local function ok(value, message) if not value then error(message or 'expected a true value', 2) end checks = checks + 1 end
local function eq(a, e, m) if a ~= e then error((m or 'mismatch') .. ': expected ' .. tostring(e) .. ', got ' .. tostring(a), 2) end checks = checks + 1 end
local function case(name, fn)
    local passed, err = xpcall(fn, debug.traceback)
    if passed then print('PASS butler 1.0.31: ' .. name)
    else failures[#failures + 1] = name; print('FAIL butler 1.0.31: ' .. name .. ': ' .. tostring(err):gsub('\nstack traceback:.*', '')) end
end
local CONSUMER = {name = 'Consumer', dir = ROOT .. '/audit/tests/', loaded = {}}
local function new(place)
    local h = J.new({rosie = true, dirs = {}, place = place or 'pit'})
    h.assert_clean('load')
    eq(h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end), true, 'RosiePlugin.enable()')
    h.frame()
    return h
end
local function butler(h) return rawget(h.G, 'Butler') end
local function own(h) local b = butler(h); return type(b) == 'table' and rawget(b, '_rosie') == true end
local function st(h) return h.as(CONSUMER, function() return h.G.AlfredTheButlerPlugin.get_status() end) end
local function fill(h) h.inventory = {}; for i = 1, 25 do h.inventory[i] = h.gear() end end
local function worldstone(h) h.G.Worldstone = {get_status = function() return {} end} end

case('B1 published only while Worldstone runs (no Butler installed); removed when Worldstone goes', function()
    local h = new()
    h.run(2)
    eq(butler(h), nil, 'no Butler without Worldstone')
    worldstone(h)
    h.run(0.5)
    ok(own(h), 'Rosie stands in for Butler')
    eq(h.logged('Standing in for Butler for Worldstone'), 1, 'logged once')
    h.G.Worldstone = nil
    h.run(0.5)
    eq(butler(h), nil, 'removed with Worldstone')
    h.assert_clean('B1')
end)

case('B2 a real Butler is never overwritten, and wins when it loads after Rosie published', function()
    local h = new()
    local real = {is_busy = function() return false end, needs_visit = function() return false, {} end}
    h.G.Butler = real
    worldstone(h)
    h.run(2)
    eq(butler(h), real, 'a Butler loaded first is kept')
    h.G.Butler = nil
    h.run(0.5)
    ok(own(h), 'published once the real one is gone')
    h.G.Butler = real -- loads ~2 s after the others
    h.run(0.5)
    eq(butler(h), real, 'the real Butler stays')
    eq(h.logged('A Butler addon is loaded: Rosie stops standing in for Butler'), 1, 'logged')
    h.assert_clean('B2')
end)

case('B3 the option off: never published', function()
    local h = new()
    h.mod('Rosie', 'rosie.private.pickup.gui').elements.act_as_butler:set(false)
    worldstone(h)
    h.run(2)
    eq(butler(h), nil, 'not published')
end)

case('B4 is_busy is true through a whole Rosie trip and false around it; Rosie never waits for her own stand-in', function()
    local h = new()
    worldstone(h)
    h.run(0.5)
    ok(own(h), 'published')
    eq(h.as(CONSUMER, function() return butler(h).is_busy() end), false, 'idle')
    fill(h)
    local seen_busy, mismatch = false, 0
    ok(h.run_until(function()
        local running = st(h).running == true
        local b = h.as(CONSUMER, function() return butler(h).is_busy() end)
        if running then seen_busy = seen_busy or b; if not b then mismatch = mismatch + 1 end end
        return seen_busy and not running
    end, 240), 'a trip ran and ended\n' .. h.tail(8))
    eq(mismatch, 0, 'is_busy true on every frame of the trip')
    eq(st(h).outcome, 'completed', 'the trip completed (not blocked by the stand-in)')
    eq(h.logged('Butler is running a town trip'), 0, 'Rosie never waits for her own stand-in')
    eq(h.as(CONSUMER, function() return butler(h).is_busy() end), false, 'idle after')
    h.assert_clean('B4')
end)

case('B5 needs_visit is true only while Rosie\'s automatic service will run the trip', function()
    local h = new('temis')
    worldstone(h)
    h.run(0.5)
    local function need() return h.as(CONSUMER, function() return butler(h).needs_visit() end) end
    eq(need(), false, 'no need')
    -- automatic service off (keybind gate): a need Rosie will not serve is never reported
    local tg = h.mod('Rosie', 'rosie.private.town.gui').elements
    tg.use_keybind:set(true); tg.keybind_toggle:set(false)
    fill(h)
    h.run(1.5)
    eq(st(h).need_trigger, true, 'the bag needs town')
    eq(need(), false, 'automatic service off: no need reported')
    -- automatic service on, held by another activity (bounded): the trip will run
    h.G.TRISTRAM_LOOP_STATE = {status = function() return {running = true, owns_activity = true, phase = 'travel'} end}
    tg.use_keybind:set(false)
    h.run(1.5)
    eq(st(h).running, false, 'held')
    local n, list = need()
    eq(n, true, 'a need Rosie will serve is reported')
    ok(type(list) == 'table' and #list >= 1, 'needs listed')
    local s = h.as(CONSUMER, function() return butler(h).get_status() end)
    eq(s.needs_visit, true, 'status needs_visit'); eq(s.owner, 'Butler', 'owner'); eq(s.is_in_town, true, 'in town')
    ok(type(s.counts) == 'table' and type(s.counts.inventory) == 'number', 'counts')
    h.assert_clean('B5')
end)

case('B6 an unknown name is a no-op that never throws, logged once', function()
    local h = new()
    worldstone(h)
    h.run(0.5)
    local okc, r = h.as(CONSUMER, function() return pcall(function() return butler(h).start_trip('Worldstone') end) end)
    eq(okc, true, 'no throw'); eq(r, nil, 'nil result')
    h.as(CONSUMER, function() return butler(h).start_trip() end)
    eq(h.logged('Worldstone called Butler.start_trip - not mimicked yet'), 1, 'logged once')
    local s = h.as(CONSUMER, function() return butler(h).get_status() end)
    eq(type(s), 'table', 'get_status works')
    h.assert_clean('B6')
end)

print(string.format('rosie butler 1.0.31: %d checks, %d failures', checks, #failures))
if #failures > 0 then error(#failures .. ' case(s) failed: ' .. table.concat(failures, ' | ')) end
