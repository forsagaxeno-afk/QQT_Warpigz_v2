-- QQT_Warpigz_v3 Rosie 1.0.29 (post-release review of 3.3.9-3.3.11, audit/BOARD.md), Z1 1.0.30:
--  F  [LOW-MED] the 1.0.26 Navigator grace re-asserted Rosie's walk with
--     force_move_raw in a fight (an enemy within fight_radius the fight hold
--     does not count as engaged, or a drop within FIGHT.feet during a cast),
--     while NAVSTOP already skipped fights: next to Worldstone Rosie walked to
--     a farther drop against the rotation. The grace now has the same fight
--     guard: in a fight a foreign move gets the 1.0.24 handling (a real
--     foreign move yields), never the force re-assert.
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
local only = os.getenv('ONLY')
local function case(name, fn)
    if only and not name:find(only, 1, true) then return end
    local passed, err = xpcall(fn, debug.traceback)
    if passed then print('PASS nav fight 1.0.29: ' .. name)
    else failures[#failures + 1] = name; print('FAIL nav fight 1.0.29: ' .. name .. ': ' .. tostring(err):gsub('\nstack traceback:.*', '')) end
end
local CONSUMER = {name = 'Consumer', dir = ROOT .. '/audit/tests/', loaded = {}}
local function pgui(h) return h.mod('Rosie', 'rosie.private.pickup.gui').elements end
local function rosie_tail(h, n)
    local out = {}
    for _, line in ipairs(h.log) do if line:find('[Rosie', 1, true) then out[#out + 1] = line end end
    local keep = {}
    for i = math.max(1, #out - (n or 12) + 1), #out do keep[#keep + 1] = out[i] end
    return table.concat(keep, '\n')
end
local function forced(h, since)
    return h.count(h.moves, function(m) return m.kind == 'force_move_raw' and m.owner == 'Rosie' and (not since or (m.t or m.at or since) >= since) end)
end

-- Worldstone + a Navigator with a live request that honours "Rosie Looting";
-- the host reported a rotation cast once, long ago (live: G.cast_seen).
local function worldstone(h, o)
    o = o or {}
    local nav = {active = true, stops = 0, conds = {}, target = h.v(40, 0)}
    h.G.Navigator = {
        set_pause_condition = function(name, fn) nav.conds[name] = fn end,
        stop = function() nav.active = false; nav.stops = nav.stops + 1 end,
        get_status = function()
            if o.status then return o.status(nav) end
            return {state = nav.active and 'travelling' or 'idle', owner = 'Worldstone', is_busy = nav.active,
                is_paused = false, remaining_distance = nav.active and h.pos:dist_to_ignore_z(nav.target) or 0}
        end,
    }
    h.G.Worldstone = {get_status = function() return {} end}
    local player = h.G.get_local_player()
    player.get_active_spell_id = function() if h.casting then return 186139 end return h.spell or -1 end
    h.spell = 111
    h.mod('Rosie', 'rosie.private.pickup.src.pickup').sample_cast(h.now - 10)
    h.spell = nil
    h.run(4)
    ok(h.G.Scavenger and h.G.Scavenger._rosie == true, 'stand-in published')
    function nav.held()
        for _, fn in pairs(nav.conds) do local okc, v = pcall(fn); if okc and v == true then return true end end
        return false
    end
    return nav
end
local function host(o)
    local h = J.new({rosie = true, dirs = {}, place = 'pit', request_move_redundant = 'any'})
    h.assert_clean('load')
    h.pos = h.v(0, 0)
    h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end)
    h.frame()
    pgui(h).general.distance_slider:set(15)
    h.G.pathfinder.clear_stored_path = function() h.native = nil end
    return h
end

case('F1 a fight the hold does not count as engaged (enemy 8 m, no cast): no force_move_raw against the rotation', function()
    for _, fdt in ipairs({0.1, 0.05}) do
        local h = host()
        local nav = worldstone(h)
        local enemy = h.actor('pit', 'Joint_Monster', 0, 8, {enemy = true, health = 1e9, reach = 0})
        local it = h.drop('pit', -5, 0, {rarity = 5, ga = 3, name = 'Helm_Legendary_Generic_031'})
        local t0, k, f0 = h.now, -1, forced(h)
        local held_seen = false
        h.run(4, function(hh)
            if nav.held() then held_seen = true end
            -- the rotation: a new evade point every 0.4 s, away from the drop
            local slot = math.floor((hh.now - t0) / 0.4)
            if slot ~= k then k = slot; hh.goal = hh.v(2 + math.cos(slot), -2 + math.sin(slot)) end
        end, fdt)
        ok(held_seen, 'frame ' .. fdt .. ': the drop is wanted and not deferred (Rosie Looting held): the case reaches the grace\n' .. rosie_tail(h))
        eq(forced(h) - f0, 0, 'frame ' .. fdt .. ': no force_move_raw in the fight (1.0.28: the grace forced the walk)\n' .. rosie_tail(h))
        eq(nav.stops, 0, 'no stop()')
        -- the fight ends: the drop is taken
        enemy.health, enemy.interactable = 0, false
        h.run(12, nil, fdt)
        ok(it.picked == true, 'frame ' .. fdt .. ': taken after the fight\n' .. rosie_tail(h))
    end
end)

case('F2 a cast (engaged) with a drop inside FIGHT.feet but out of reach: no force_move_raw while casting', function()
    local h = host()
    local nav = worldstone(h)
    h.actor('pit', 'Joint_Monster', 0, 9, {enemy = true, health = 1e9, reach = 0})
    local it = h.drop('pit', -2.6, 0, {rarity = 5, ga = 3, name = 'Helm_Legendary_Generic_031', refuse = function() return true end})
    local t0, k, f0 = h.now, -1, forced(h)
    h.run(3, function(hh)
        hh.spell = 222 -- the rotation casts
        local slot = math.floor((hh.now - t0) / 0.4)
        if slot ~= k then k = slot; hh.goal = hh.v(2 + math.cos(slot), -2 + math.sin(slot)) end
    end)
    eq(forced(h) - f0, 0, 'no force_move_raw while the player casts (1.0.28: forced)\n' .. rosie_tail(h))
    eq(nav.stops, 0, 'no stop()')
    ok(it.picked ~= true)
end)

case('F3 control: no fight, a foreign command in flight under the hold still gets the grace (force, no yield)', function()
    local h = host()
    local nav = worldstone(h)
    local it = h.drop('pit', -5, 0, {rarity = 5, ga = 3, name = 'Helm_Legendary_Generic_031'})
    local t0, f0 = h.now, forced(h)
    h.goal = h.v(30, 0) -- Navigator's command in flight
    h.run(4)
    ok(it.picked == true, 'taken\n' .. rosie_tail(h))
    ok(forced(h) - f0 >= 1, 'the grace forced the walk')
    eq(h.logged('Another move took the player off', t0), 0, 'no yield')
    eq(nav.stops, 0, 'no stop()')
end)

-- QQT_Warpigz_v3 1.0.30 (Auditor review of 1.0.29, HIGH, shipped in 3.3.17):
-- the grace's guard counted the trailing FIGHT.cast = 3 s window after any
-- cast, so for about 2 s after a kill (the fight hold ends after 1 s) Rosie
-- had no grace, Worldstone's portal command dragged the player off and the
-- post-kill drop was skipped. Only a cast right now or an enemy near counts.
for _, cast_ago in ipairs({0.3, 1.0, 2.0, 2.9}) do
    case('Z1 the boss just died (last rotation cast ' .. cast_ago .. ' s before the drop), no enemy, a Navigator command in flight: the grace takes the drop (like F3)', function()
        local h = host()
        worldstone(h)
        h.spell = 333
        h.run(1) -- the rotation casts on the boss
        h.spell = nil
        h.run(cast_ago) -- the boss dies; the drops fall now
        local it = h.drop('pit', -5, 0, {rarity = 5, ga = 3, name = 'Helm_Legendary_Generic_031'})
        local t0 = h.now
        h.goal = h.v(30, 0) -- Worldstone heads for the portal
        h.run(6)
        eq(h.logged('Another move took the player off', t0), 0, 'no yield (1.0.29: yielded, the drop skipped)\n' .. rosie_tail(h))
        ok(it.picked == true, 'taken\n' .. rosie_tail(h))
    end)
end

print(string.format('nav fight 1.0.29: %d checks, %d failures', checks, #failures))
if #failures > 0 then error(#failures .. ' case(s) failed: ' .. table.concat(failures, ' | ')) end
