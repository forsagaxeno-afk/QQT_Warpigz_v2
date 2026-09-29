-- QQT_Warpigz_v3 Arkham 2.1.5 (sweep 2026-09-28 A3 / S2 F4): the Pit exit only
-- waited for drops inside Rosie's pickup distance (2 m shipped default); a
-- boss Mythic 2.4-5 m from the glyphstone stayed behind at the exit.
-- Real Rosie (pickup 2 m) + ArkhamAsylum + Batmobile in the joint host.
--   P1 a Mythic 4 m and a Legendary 3.6 m from the glyphstone: both are
--      picked before the exit cast (pre-fix: the exit was cast at once).
--   P2 unreachable wanted drops: the exit is still cast within 20 s.
--   P3 the forced (reset timer) exit never walks the pile.
local ROOT = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local J = dofile(ROOT .. '/audit/tests/joint_host.lua')
local checks, failures = 0, {}
local function ok(value, message)
    if not value then error(message or 'expected a true value', 2) end
    checks = checks + 1
end
local function case(name, fn)
    local passed, err = xpcall(fn, debug.traceback)
    if passed then print('PASS arkham-boss-pile: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL arkham-boss-pile: ' .. name .. ': ' .. tostring(err)) end
end
local CONSUMER = {name = 'Consumer', dir = ROOT .. '/audit/tests/', loaded = {}}
local MYTHIC = {rarity = 6, ancestral = true, ga = 1, name = 'Helm_Unique_Generic_005', sno = 2647147,
    affixes = {{affix_name_hash = 2628989, get_name = function() return 'S14_Mythic_UniquePotency' end}}}
local function legendary_fields() return {rarity = 5, ga = 3, name = 'Helm_Legendary_Generic_031'} end

-- The Guardian is dead and the glyph used: exit_pit is next. Glyphstone at
-- (gx, gy), the player next to it.
local function setup(gx, gy)
    local h = J.new({rosie = true, dirs = {'ArkhamAsylum', 'Batmobile'}, place = 'pit'})
    h.assert_clean('load')
    h.pos = h.v(gx, gy + 1)
    ok(h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end) == true, 'RosiePlugin.enable()')
    h.frame()
    h.mod('Rosie', 'rosie.private.pickup.gui').elements.general.distance_slider:set(2)
    h.mod('ArkhamAsylum', 'gui').elements.main_toggle:set(true)
    -- No exit delay: the time to the exit cast is the pile sweep.
    h.mod('ArkhamAsylum', 'gui').elements.exit_pit_delay:set(0)
    h.run(1)
    local tracker = h.mod('ArkhamAsylum', 'core.tracker')
    local gizmo = h.actor('pit', 'Gizmo_Paragon_Glyph_Upgrade', gx, gy, {})
    tracker.boss_dead, tracker.boss_seen, tracker.glyph_done = true, true, true
    tracker.glyph_anchor_pos = gizmo.pos
    tracker.pit_start_time = h.now
    h.tracker = tracker
    return h
end
local function exit_cast_count(h) return h.resets + #h.waypoints end
local function run_to_exit(h, seconds)
    local n0 = exit_cast_count(h)
    local t0 = h.now
    local at
    h.run_until(function(hh)
        if exit_cast_count(hh) > n0 then at = hh.now - t0; return true end
        return false
    end, seconds)
    return at
end

case('P1 a Mythic 4 m and a Legendary 3.6 m from the glyphstone are picked before the exit cast', function()
    local h = setup(20, 0)
    local mythic = h.drop('pit', 24, 0, MYTHIC)
    local leg = h.drop('pit', 20, -3.6, legendary_fields())
    local picked_at_cast
    local n0 = exit_cast_count(h)
    local at = nil
    local t0 = h.now
    h.run_until(function(hh)
        if exit_cast_count(hh) > n0 then
            at = hh.now - t0
            picked_at_cast = {mythic = mythic.picked == true, leg = leg.picked == true}
            return true
        end
        return false
    end, 60)
    ok(at ~= nil, 'the exit is cast\n' .. h.tail(20))
    ok(picked_at_cast.mythic, string.format('the Mythic 4 m away was left behind at the exit cast (%.1f s)\n%s',
        at, h.tail(20)))
    ok(picked_at_cast.leg, 'the Legendary 3.6 m away was left behind at the exit cast\n' .. h.tail(20))
    ok(at <= 25, string.format('exit cast after %.1f s', at))
    print(string.format('  P1 exit cast %.1f s after the glyph, both drops picked', at))
end)

case('P2 unreachable wanted drops: the exit is still cast within 20 s', function()
    -- Glyphstone at the pit edge; the drops are 5-7 m off the walkable area.
    local h = setup(20, -26)
    h.drop('pit', 20, -33, MYTHIC)
    h.drop('pit', 16, -32, legendary_fields())
    h.drop('pit', 24, -31, legendary_fields())
    local at = run_to_exit(h, 40)
    ok(at ~= nil, 'the exit is cast\n' .. h.tail(20))
    ok(at <= 21, string.format('exit cast after %.1f s (at most 20 s of sweep)', at))
    ok(h.logged('boss pile sweep over') + h.logged('not reached in') >= 1, 'the sweep tried the drops\n' .. h.tail(20))
end)

case('P3 the forced (reset timer) exit never walks the pile', function()
    local h = setup(20, 0)
    local mythic = h.drop('pit', 24, 0, MYTHIC)
    h.tracker.pit_start_time = h.now - 10000
    local at = run_to_exit(h, 10)
    ok(at ~= nil and at <= 2, 'forced exit cast at once, got ' .. tostring(at))
    ok(not mythic.picked, 'no pile walk on the forced exit')
end)

if #failures > 0 then error(#failures .. ' arkham boss-pile case(s) failed:\n' .. table.concat(failures, '\n')) end
print(string.format('PASS: arkham boss pile, %d checks', checks))
