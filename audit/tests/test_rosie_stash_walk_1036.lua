-- Rosie 1.0.36 (owner live 3.3.25, Temis, after a Reaper run): with 1.0.35
-- the stall recovery ran (stalls 1-4, detours), but the player moved about
-- 1 m in 22 s: the move requests did not move the player at all. Modelled
-- here: after the salvage, request_move / force_move_raw are accepted and do
-- nothing (another mover's command kept); the game walks to an interacted
-- chest (interact_vendor beyond reach sets the player's goal).
--  W1 the chest is reached by the interact walk and the trip is serviced
--     (fails on 1.0.35: "No stash progress for 45 active seconds");
--  W2 the walk line is printed after the request (request=, dest=);
--  W3 a chest farther than 10 m is never interacted with from afar.
-- Base (1.0.35 header follows).
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
    if passed then print('PASS stash walk 1036: ' .. name)
    else failures[#failures + 1] = name; print('FAIL stash walk 1036: ' .. name .. ': ' .. tostring(err):sub(1, 2500)) end
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

local function dead_mover(h)
    local P = h.G.pathfinder
    for _, k in ipairs({'request_move', 'force_move_raw'}) do
        P[k] = function() h.ignored = (h.ignored or 0) + 1; return true end
    end
    local iv = h.G.interact_vendor
    rawset(h.G, 'interact_vendor', function(a)
        if a == h.temis_stash and h.pos:dist_to_ignore_z(a.pos) > 4 then
            h.far_interacts = (h.far_interacts or 0) + 1
            h.goal = h.Vec:new(a.pos:x(), a.pos:y(), 0) -- the game walks to it
        end
        return iv(a)
    end)
end

case('W1 the move requests do nothing: the interact walk reaches the chest', function()
    local h, done = trip(dead_mover)
    serviced(h, done, 'W1')
    ok((h.ignored or 0) > 0, 'W1 the dead mover was used')
    ok((h.far_interacts or 0) >= 1, 'W1 interacted from afar')
    ok(h.logged('interacting with the chest at') >= 1, 'W1 the interact walk is logged\n' .. h.tail(20))
end)

case('W2 the walk line is printed after the request', function()
    local h, done = trip(dead_mover)
    serviced(h, done, 'W2')
    ok(h.logged('request=') >= 1 and h.logged('dest=') >= 1, 'W2 request and dest logged\n' .. h.tail(20))
    eq(h.logged('Walking to the stash: target=(2574.0,-486.'), 1, 'W2 one start line')
end)

case('W3 a chest farther than 10 m is not interacted with from afar', function()
    local h, done = trip(function(h)
        eq(h.mod('Rosie', 'rosie.private.town.tasks.stash').WALK.INTERACT_RANGE, 10, 'W3 range')
        dead_mover(h)
        h.pos = h.Vec:new(2574.0, -472.0, 0) -- 14 m north of the chest
    end)
    eq(h.far_interacts or 0, 0, 'W3 no interact beyond 10 m')
    ok(done[1] ~= nil, 'W3 the stuck walk still fails bounded')
end)

if #failures > 0 then error(#failures .. ' stash walk 1036 case(s) failed: ' .. table.concat(failures, ', ')) end
print('test_rosie_stash_walk_1036: ' .. checks .. ' checks passed')
