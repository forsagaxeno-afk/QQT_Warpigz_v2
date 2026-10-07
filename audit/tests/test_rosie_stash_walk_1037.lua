-- Rosie 1.0.37 (Coordinator review of 1.0.36, fast track).
--  G1 [HIGH] a counter pins the straight-line mover (the detours too); the
--     game's interact walk routes around it to an interaction point 1.2 m
--     off the chest centre. 1.0.36 overrode that walk on the next tick
--     (request_move / clear_stored_path / force) and failed with "No stash
--     progress for 45 active seconds"; Rosie must leave the game's walk alone.
--  A1 [MED] a second Stash-skin actor nearer the Blacksmith (owner live 3.3.25:
--     actor 8388681 at (2570.1,-475.5)) that opens nothing: Rosie takes the
--     one nearest the town table's chest and logs both actors once.
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
    if passed then print('PASS stash walk 1037: ' .. name)
    else failures[#failures + 1] = name; print('FAIL stash walk 1037: ' .. name .. ': ' .. tostring(err):sub(1, 2500)) end
end
local CONSUMER = {name = 'Consumer', dir = ROOT .. '/audit/tests/', loaded = {}}
local function trip(setup, pre)
    local h = J.new({rosie = true, dirs = {}})
    h.assert_clean('load')
    if pre then pre(h) end
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

-- The game's interact walk: waypoints around the counter, then the
-- interaction point. Any other mover that replaces the goal cancels it.
local function counter_and_game_walk(h)
    h.place.walls = {{2568.0, 2580.0, -483.5, -481.6}} -- the counter: portal point and both sides inside
    local iv = h.G.interact_vendor
    rawset(h.G, 'interact_vendor', function(a)
        if a == h.temis_stash and h.pos:dist_to_ignore_z(a.pos) > 4 and not h.game_route then
            h.far_interacts = (h.far_interacts or 0) + 1
            h.game_route = {h.Vec:new(2582, -480.5, 0), h.Vec:new(2582, -485, 0), h.Vec:new(2575.2, -486.3, 0)}
            h.route_i = 1
            h.goal = h.game_route[1]; h.route_goal = h.goal
        end
        return iv(a)
    end)
    local frame = h.frame
    h.frame = function(...)
        local r = frame(...)
        if h.game_route then
            local wp = h.game_route[h.route_i]
            if h.goal == h.route_goal then -- still walking it
            elseif h.goal == nil and h.pos:dist_to_ignore_z(wp) < 0.3 then
                h.route_i = h.route_i + 1
                if h.game_route[h.route_i] then h.goal = h.game_route[h.route_i]; h.route_goal = h.goal
                else h.game_route = nil end
            else
                h.overridden = (h.overridden or 0) + 1; h.game_route = nil -- another command replaced it
            end
        end
        return r
    end
end

case('G1 the game walk around the counter is not overridden', function()
    local h, done = trip(counter_and_game_walk)
    h.place.walls = nil
    serviced(h, done, 'G1')
    ok((h.far_interacts or 0) >= 1, 'G1 an interact walk ran')
    eq(h.overridden or 0, 0, 'G1 Rosie never replaced the game walk')
end)

case('A1 the chest nearest the town table wins over a nearer decoy', function()
    local decoy
    local h, done = trip(nil, function(h)
        decoy = h.actor('temis', 'Stash', 2570.1, -475.5, {})
    end)
    h.remove_actor(decoy)
    serviced(h, done, 'A1')
    eq(h.logged('Stash actor '), 2, 'A1 both actors logged once\n' .. h.tail(20))
    ok(h.logged('from=chest actor ' .. tostring(h.temis_stash.id)) >= 1, 'A1 the town-table chest is the target')
end)

if #failures > 0 then error(#failures .. ' stash walk 1037 case(s) failed: ' .. table.concat(failures, ', ')) end
print('test_rosie_stash_walk_1037: ' .. checks .. ' checks passed')
