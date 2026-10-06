-- Rosie 1.0.38 (Coordinator re-review of 1.0.37, follow-ups).
--  D1 [MED] the counter also pins the game's interact walk (straight to the
--     chest); a detour (the portal point) gets around it. 1.0.37 replaced
--     every detour with the next interact walk (the 4 s hold outlasts the
--     3 s gap), so the stash opened only after the 6 interact walks.
--  P1 [LOW] a pending panel close (vendor.closing) blocks the interact walk.
--  R1 [LOW] the actor nearest the town table opens nothing (a stale table):
--     after MAX_INTERACTIONS it is set aside and the next Stash actor opens.
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
    if passed then print('PASS stash walk 1038: ' .. name)
    else failures[#failures + 1] = name; print('FAIL stash walk 1038: ' .. name .. ': ' .. tostring(err):sub(1, 2500)) end
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

local function opened_at(h)
    local frame = h.frame
    h.frame = function(...)
        local r = frame(...)
        if not h.first_open and (h.stash_opens or 0) > 0 then h.first_open = h.now end
        return r
    end
end

case('D1 a detour runs between interact walks when the game walk is pinned', function()
    local t0
    local h, done = trip(function(h)
        t0 = h.now
        h.place.walls = {{2571.5, 2576.0, -483.5, -481.6}}
        local iv = h.G.interact_vendor
        rawset(h.G, 'interact_vendor', function(a)
            if a == h.temis_stash and h.pos:dist_to_ignore_z(a.pos) > 4 then
                h.far_interacts = (h.far_interacts or 0) + 1
                h.goal = h.Vec:new(a.pos:x(), a.pos:y(), 0) -- the game walks straight: the counter pins it
            end
            return iv(a)
        end)
        opened_at(h)
    end)
    h.place.walls = nil
    serviced(h, done, 'D1')
    ok(h.logged('via=(2578.1,-482.') >= 1, 'D1 the portal detour ran\n' .. h.tail(20))
    ok(h.first_open and h.first_open - t0 <= 25, 'D1 the stash opened within 25 s: ' .. tostring(h.first_open and h.first_open - t0))
end)

case('P1 a pending panel close blocks the interact walk', function()
    local h, done = trip(function(h)
        local P = h.G.pathfinder
        for _, k in ipairs({'request_move', 'force_move_raw'}) do P[k] = function() return true end end
        local vendor = h.mod('Rosie', 'rosie.private.town.core.vendor')
        vendor.closing = function() return true end
        local iv = h.G.interact_vendor
        rawset(h.G, 'interact_vendor', function(a)
            if a == h.temis_stash and h.pos:dist_to_ignore_z(a.pos) > 4 then h.far_interacts = (h.far_interacts or 0) + 1 end
            return iv(a)
        end)
    end)
    eq(h.far_interacts or 0, 0, 'P1 no interact walk while a close is pending')
    eq(h.logged('interacting with the chest at'), 0, 'P1 no interact line')
    ok(done[1] ~= nil, 'P1 the stuck walk fails bounded')
end)

case('R1 a chest at the town table that opens nothing is set aside', function()
    local decoy
    local h, done = trip(nil, function(h)
        h.temis_stash.pos = h.Vec:new(2570.1, -475.5, 0) -- the real chest is elsewhere
        decoy = h.actor('temis', 'Stash', 2574.04, -486.25, {}) -- opens nothing
    end)
    h.remove_actor(decoy)
    serviced(h, done, 'R1')
    eq(h.logged('did not open after 4 interactions; trying the next Stash actor'), 1, 'R1 set aside once\n' .. h.tail(20))
end)

if #failures > 0 then error(#failures .. ' stash walk 1038 case(s) failed: ' .. table.concat(failures, ', ')) end
print('test_rosie_stash_walk_1038: ' .. checks .. ' checks passed')
