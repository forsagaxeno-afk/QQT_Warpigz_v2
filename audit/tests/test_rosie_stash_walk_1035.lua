-- Rosie 1.0.35 (owner live 3.3.24, Temis): "After ROSIE finishes salvaging
-- items in TEMIS, it tries to go to the stash but gets stuck at the
-- Blacksmith and cannot reach the stash." Log: "Closed the blacksmith panel
-- ... (salvage done)", no "Open stash" line, then 45 s later "No stash
-- progress for 45 active seconds". The stash walk had no stuck recovery:
-- rosie/movement.lua blocks a goal after ~9 s without progress and the stash
-- task never released it.
--  S1 the player cannot move for 12 s after the salvage (body-blocked at the
--     counter); then the way is free: the walk goes on and the stash opens.
--  S2 a wall between the Blacksmith and the chest: the walk detours (the
--     portal point) and the stash opens.
--  S3 the walk line names the target, its source, the distance and the
--     movement status (the next live log has the Temis chest data).
--  S4 control: no obstacle, no stall line, the trip is serviced.
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
    if passed then print('PASS stash walk: ' .. name)
    else failures[#failures + 1] = name; print('FAIL stash walk: ' .. name .. ': ' .. tostring(err):sub(1, 2500)) end
end
local CONSUMER = {name = 'Consumer', dir = ROOT .. '/audit/tests/', loaded = {}}
local function trip(setup)
    local h = J.new({rosie = true, dirs = {}})
    h.assert_clean('load')
    eq(h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end), true, 'enable')
    h.frame()
    h.stash = {h.gear({rarity = 8, ancestral = true})}
    h.inventory = {}
    for i = 1, 3 do h.inventory[i] = h.gear() end                              -- salvaged
    for i = 4, 5 do h.inventory[i] = h.gear({rarity = 8, ancestral = true}) end -- kept, stashed
    local tracker = h.mod('Rosie', 'rosie.private.town.core.tracker')
    local done
    eq(h.as(CONSUMER, function()
        return h.G.AlfredTheButlerPlugin.trigger_tasks('WarPigs', function(r, d) done = {r, d} end)
    end), true, 'trigger')
    ok(h.run_until(function() return tracker.salvage_done == true end, 120), 'salvage done\n' .. h.tail(20))
    eq(h.place, h.P.temis, 'in Temis')
    ok(h.pos:dist_to_ignore_z(h.blacksmith.pos) < 3, 'at the Blacksmith')
    if setup then setup(h) end
    ok(h.run_until(function() return done ~= nil end, 150), 'the trip finished\n' .. h.tail(20))
    return h, done
end
local function serviced(h, done, label)
    eq(done[1], nil, label .. ' serviced: ' .. tostring(done[2] and done[2].reason) .. '\n' .. h.tail(20))
    eq(#h.stashed, 2, label .. ' both items deposited')
    eq(h.logged('No stash progress'), 0, label .. ' no 45 s failure')
end

case('S1 body-blocked for 12 s at the Blacksmith, then free', function()
    local h, done = trip(function(h)
        local speed, t0 = h.speed, h.now
        h.speed = 0
        local frame = h.frame
        h.frame = function(...)
            if h.speed == 0 and h.now - t0 >= 12 then h.speed = speed end
            return frame(...)
        end
    end)
    serviced(h, done, 'S1')
    ok(h.logged('No walking progress') >= 1, 'S1 the stall is logged\n' .. h.tail(20))
end)

case('S2 a wall between the Blacksmith and the chest', function()
    local h, done = trip(function(h)
        h.place.walls = {{2571.5, 2576.0, -483.5, -481.6}}
    end)
    h.place.walls = nil
    serviced(h, done, 'S2')
    ok(h.logged('via=(2578.1,-482.') >= 1, 'S2 detour through the portal point\n' .. h.tail(20))
end)

case('S3 the walk line names the target and its source', function()
    local h, done = trip()
    serviced(h, done, 'S3')
    ok(h.logged('Walking to the stash: target=(2574.0,-486.') >= 1, 'S3 target logged\n' .. h.tail(20))
    ok(h.logged('from=chest actor') >= 1, 'S3 source logged')
    ok(h.logged('move=') >= 1, 'S3 movement status logged')
end)

case('S4 control: a free walk logs no stall', function()
    local h, done = trip()
    serviced(h, done, 'S4')
    eq(h.logged('No walking progress'), 0, 'S4 no stall line')
end)

if #failures > 0 then error(#failures .. ' stash walk case(s) failed: ' .. table.concat(failures, ', ')) end
print('test_rosie_stash_walk_1035: ' .. checks .. ' checks passed')
