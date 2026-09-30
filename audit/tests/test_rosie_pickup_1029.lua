-- QQT_Warpigz_v3 Rosie 1.0.29 (post-release review of 3.3.9-3.3.11 and the
-- scenario sweep 2026-09-28 §2.3, audit/BOARD.md):
--  R3 a travel channel (the Town Portal / waypoint channel 186139), cast by
--     another plugin (an activity's exit) or Rosie, counted as a fight in
--     pickup fighting(): the step onto a drop in reach was held and the drop
--     left behind when the channel completed. It is no fight now.
--  L  each spell id that counts as a cast (fight evidence) is logged once, so
--     the owner's log shows whether interaction or pickup ids count.
--  R4 a skipped drop whose reason flipped (outside distance <-> bag full while
--     the player walked back and forth) printed a Skipped line on every flip;
--     now once per drop per reason (numbers in a reason normalised).
local ROOT = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local J = dofile(ROOT .. '/audit/tests/joint_host.lua')
local checks, failures = 0, {}
local function ok(value, message) if not value then error(message or 'expected a true value', 2) end checks = checks + 1 end
local function eq(a, e, m) if a ~= e then error((m or 'mismatch') .. ': expected ' .. tostring(e) .. ', got ' .. tostring(a), 2) end checks = checks + 1 end
local function case(name, fn)
    local passed, err = xpcall(fn, debug.traceback)
    if passed then print('PASS pickup 1.0.29: ' .. name)
    else failures[#failures + 1] = name; print('FAIL pickup 1.0.29: ' .. name .. ': ' .. tostring(err):gsub('\nstack traceback:.*', '')) end
end
local CONSUMER = {name = 'Consumer', dir = ROOT .. '/audit/tests/', loaded = {}}
local function new(dist)
    local h = J.new({rosie = true, dirs = {}, place = 'pit'})
    h.assert_clean('load')
    h.pos = h.v(0, 0)
    eq(h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end), true, 'RosiePlugin.enable()')
    h.frame()
    h.mod('Rosie', 'rosie.private.pickup.gui').elements.general.distance_slider:set(dist or 15)
    h.run(0.5)
    return h
end
local function helm(i) return {rarity = 5, ga = 3, name = string.format('Helm_Legendary_Generic_%03d', 60 + i)} end
local function take_within(r) return function(h, it) return h.pos:dist_to_ignore_z(it.pos) > r end end
local function spells(h)
    local player = h.G.get_local_player()
    player.get_active_spell_id = function() if h.casting then return 186139 end return h.spell or -1 end
end

case('R3 a drop in reach the game takes only from closer, during another plugin\'s 8 s waypoint channel: Rosie steps in and takes it before the channel ends', function()
    local h = new()
    spells(h)
    h.spell = 111; h.run(0.2); h.spell = nil; h.frame() -- the host has reported a rotation cast once
    local f = helm(6); f.refuse = take_within(1.2)
    local it = h.drop('pit', 1.7, 0, f)
    h.travel_to('temis', 8, 'waypoint') -- an activity's exit channel
    h.goal = nil
    -- Live a walk breaks the channel (the joint host freezes the player while
    -- h.travel is set): a move command during the channel cancels it.
    local broke = false
    local t0 = h.now
    ok(h.run_until(function()
        if h.travel and h.travel.phase == 'channel' and h.goal then h.travel, h.casting, broke = nil, false, true end
        return it.picked == true
    end, 6), 'taken (1.0.28: the channel counted as a fight, no step-in, the channel completed)\n' .. h.tail(8))
    ok(broke, 'Rosie\'s step broke the channel')
    eq(h.place, h.P.pit, 'still in the Pit')
    ok(h.now - t0 < 8, 'before the channel would have completed')
end)

case('L1 each spell id counted as a cast is logged once (the Town Portal channel never)', function()
    local h = new()
    spells(h)
    h.casting = true; h.run(0.5); h.casting = false
    eq(h.logged('counts as a cast'), 0, 'the travel channel is no cast')
    for _ = 1, 3 do h.spell = 111; h.run(0.3); h.spell = nil; h.run(0.3) end
    eq(h.logged('Active spell id 111 counts as a cast'), 1, 'id 111 once\n' .. h.tail(6))
    h.spell = 222; h.run(0.3); h.spell = nil; h.run(0.3)
    eq(h.logged('Active spell id 222 counts as a cast'), 1, 'id 222 once')
end)

case('R4 a skipped drop whose reason flips (bag full <-> outside the Distance range) 20 times: one Skipped line per reason', function()
    local h = new(8)
    h.mod('Rosie', 'rosie.private.town.gui').elements.main_toggle:set(false) -- no town trip for the full bag
    h.inventory = {}
    for i = 1, 33 do h.inventory[i] = h.gear({locked = true}) end
    h.run(0.5)
    local it = h.drop('pit', 7, 0, helm(1))
    local t0 = h.now
    for i = 1, 20 do
        h.pos = h.v(i % 2 == 0 and -4 or 0, 0) -- 11 m (outside 8) / 7 m (bag full)
        h.run(0.6)
    end
    local n = 0
    for _, l in ipairs(h.log) do if l:find('[Rosie pickup] Skipped Helm_Legendary_Generic_061', 1, true) then n = n + 1 end end
    eq(n, 2, 'one line per reason (1.0.28: one per flip, about 20)\n' .. h.tail(6))
    ok(it.picked ~= true)
end)

print(string.format('rosie pickup 1.0.29: %d checks, %d failures', checks, #failures))
if #failures > 0 then error(#failures .. ' case(s) failed: ' .. table.concat(failures, ' | ')) end
