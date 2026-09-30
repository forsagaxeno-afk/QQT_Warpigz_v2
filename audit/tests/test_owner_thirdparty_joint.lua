-- QQT_Warpigz_v3 owner-build: the REAL third-party town service and looter of
-- the owner build (SteroidAlfredV2 "BetterAlfred" and LooteerV3, vendored
-- read-only under audit/fixtures/third_party/, never shipped) loaded in the
-- joint host together with ArkhamAsylum + Batmobile + WarPigs (WarPigs off:
-- standalone Pit farming).
--   T1 a full bag in the Pit: Arkham asks SteroidAlfred for the trip, Steroid
--      takes the player to Temis, services the bag, returns through the town
--      portal into the same Pit and calls the callback (no arguments); Arkham
--      resumes the run. No Lua error in any plugin, no caller-context
--      violation.
--   T2 LooteerV3 picks up a wanted drop in the Pit (is_actively_looting while
--      it walks to it), still without errors.
-- The host is a behaviour model (joint_host.lua opts.no_mocks + town_surface:
-- Temis vendors/stash, gear, ground drops, a no-op curl); it is not a live
-- check of either closed-source plugin's internals.
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
    if passed then print('PASS owner-thirdparty: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL owner-thirdparty: ' .. name .. ': ' .. tostring(err)) end
end

local TP = 'audit/fixtures/third_party/'
local ST, LT, ARK = TP .. 'SteroidAlfredV2', TP .. 'LooteerV3', 'ArkhamAsylum'
local CONSUMER = {name = 'Consumer', dir = ROOT .. '/audit/tests/', loaded = {}}

local function vendored(dir)
    local f = io.open(ROOT .. '/' .. dir .. '/main.lua', 'r')
    if f then f:close() end
    return f ~= nil
end

-- own_trips = false: SteroidAlfred's 'Use keybind' on with the keybind off, so
-- it runs only requested trips; otherwise (its default) it also starts its own
-- trip on need_trigger, in the same frame it sees the full bag.
local function host(own_trips)
    local h = J.new({no_mocks = true, town_surface = true, place = 'pit',
        dirs = {ARK, 'Batmobile', 'WarPigs', LT, ST}})
    h.assert_clean('load')
    ok(type(h.G.AlfredTheButlerPlugin) == 'table' and type(h.G.AlfredTheButlerPlugin.get_status) == 'function',
        'SteroidAlfred publishes AlfredTheButlerPlugin')
    ok(h.G.PLUGIN_alfred_the_butler == h.G.AlfredTheButlerPlugin, 'and PLUGIN_alfred_the_butler')
    ok(type(h.G.LooteerPlugin) == 'table' and type(h.G.LooteerPlugin.is_actively_looting) == 'function',
        'LooteerV3 publishes LooteerPlugin')
    -- Record every trip request and the arguments of its callback.
    h.trips = {}
    local api = h.G.AlfredTheButlerPlugin
    for _, name in ipairs({'trigger_tasks', 'trigger_tasks_with_teleport'}) do
        local real = api[name]
        api[name] = function(caller, cb)
            local rec = {name = name, caller = caller, t = h.now, place = h.place.key}
            h.trips[#h.trips + 1] = rec
            local wrapped = cb and function(...)
                rec.done, rec.nargs = h.now, select('#', ...)
                return cb(...)
            end
            return real(caller, wrapped)
        end
    end
    h.as(CONSUMER, function() api.enable() end)
    if own_trips == false then
        local g = h.mod(ST, 'gui').elements
        g.use_keybind:set(true); g.keybind_toggle:set(false)
    end
    for i = 1, 4 do h.actor('pit', 'Pit_Monster_' .. i, 20 + i * 15, (i % 2) * 6, {enemy = true}) end
    h.mod(ARK, 'gui').elements.main_toggle:set(true)
    h.run(3)
    return h
end
local function steroid_status(h) return h.as(CONSUMER, function() return h.G.AlfredTheButlerPlugin.get_status() end) end

if not (vendored(ST) and vendored(LT)) then
    print('SKIP owner-thirdparty: the vendored SteroidAlfredV2 / LooteerV3 copies are missing')
    return
end

case('T1 bag full in the Pit: Arkham -> SteroidAlfred trip to Temis and back into the Pit, callback without arguments', function()
    local h = host(false)
    local st = steroid_status(h)
    eq(st.name, 'alfred_the_butler', 'Steroid status name')
    eq(st.enabled, true, 'Steroid enabled')
    eq(st.paused, nil, 'Steroid publishes no paused field')
    eq(st.trigger_tasks, false, 'idle at start')
    local pit = h.place
    h.inventory = {}
    for i = 1, 26 do h.inventory[i] = h.gear({rarity = 3}) end
    ok(h.run_until(function() return #h.trips > 0 end, 20), 'Arkham asks for the trip\n' .. h.tail(20))
    local trip = h.trips[1]
    eq(trip.caller, 'arkham_asylum', 'the caller')
    eq(trip.place, 'pit', 'asked from the Pit')
    ok(h.run_until(function() return h.place == h.P.temis end, 30), 'Steroid took the player to Temis\n' .. h.tail(20))
    ok(h.run_until(function() return trip.done ~= nil end, 120), 'the callback came\n' .. h.tail(30))
    eq(trip.nargs, 0, 'Steroid calls the callback without arguments')
    ok(h.run_until(function() return h.place == pit end, 30), 'back in the same Pit\n' .. h.tail(20))
    eq(#h.inventory, 0, 'the bag was serviced')
    h.run(10)
    h.assert_clean('T1')
    eq(#h.trips, 1, 'one trip')
    st = steroid_status(h)
    eq(st.trigger_tasks, false, 'Steroid idle again')
    local task = h.mod(ARK, 'tasks.alfred')
    eq(h.as(ARK, function() return task.is_busy() end), false, "Arkham's Alfred task idle")
    ok(h.logged('back in PIT_Joint_Floor:41') >= 1, 'Arkham resumed the run')
    eq(h.logged('town service busy'), 0, 'no stuck-service bound on a normal trip')
end)

case('T1b SteroidAlfred\'s own bag trip (its default): Arkham yields and resumes the Pit run', function()
    local h = host(true)
    local pit = h.place
    h.inventory = {}
    for i = 1, 26 do h.inventory[i] = h.gear({rarity = 3}) end
    ok(h.run_until(function() return h.place == h.P.temis end, 30), 'a trip to Temis\n' .. h.tail(20))
    ok(h.run_until(function() return h.place == pit end, 120), 'back in the same Pit\n' .. h.tail(30))
    eq(#h.inventory, 0, 'the bag was serviced')
    h.run(10)
    h.assert_clean('T1b')
    eq(steroid_status(h).trigger_tasks, false, 'Steroid idle again')
    local task = h.mod(ARK, 'tasks.alfred')
    eq(h.as(ARK, function() return task.is_busy() end), false, "Arkham's Alfred task idle")
    ok(h.logged('back in PIT_Joint_Floor:41') >= 1, 'Arkham resumed the run')
end)

case('T2 LooteerV3 picks up a wanted drop in the Pit', function()
    local h = host()
    local lt = h.G.LooteerPlugin
    h.as(CONSUMER, function() lt.enable() end)
    h.mod(LT, 'gui').elements.general.distance_slider:set(12)
    local item = h.drop('pit', h.pos:x() + 5, h.pos:y(), {rarity = 5, ancestral = true, ga = 2,
        name = 'Helm_Legendary_Generic_031', sno = 207027}) -- 207027: a Helm in LooteerV3's catalog
    local busy = false
    ok(h.run_until(function() return item.picked == true end, 30, function(hh)
        if hh.as(CONSUMER, function() return lt.is_actively_looting() end) then busy = true end
    end), 'LooteerV3 picked the drop up\n' .. h.tail(20))
    ok(busy, 'is_actively_looting while it went for it')
    h.run(3)
    eq(h.as(CONSUMER, function() return lt.is_actively_looting() end), false, 'idle afterwards')
    h.assert_clean('T2')
end)

if #failures > 0 then error(#failures .. ' owner-build third-party case(s) failed:\n' .. table.concat(failures, '\n')) end
print(string.format('PASS: owner-build third-party joint, %d checks', checks))
