-- QQT_Warpigz_v3 Arkham 2.1.5 (sweep 2026-09-28 A3 / S2 F4): the Pit exit only
-- waited for drops inside Rosie's pickup distance (2 m shipped default); a
-- boss Mythic 2.4-5 m from the glyphstone stayed behind at the exit.
-- Real Rosie (pickup 2 m) + ArkhamAsylum + Batmobile in the joint host.
--   P1 a Mythic 4 m and a Legendary 3.6 m from the glyphstone: both are
--      picked before the exit cast (pre-fix: the exit was cast at once).
--   P2 unreachable wanted drops: the exit is still cast within 20 s.
--   P3 the forced (reset timer) exit never walks the pile.
-- QQT_Warpigz_v3 owner-build: no Rosie in this build. P1/P2 exercised Rosie's
-- pickup (evaluate_item, pickup distance) and are dropped; P3 runs with the
-- joint host's Alfred/Looter mocks (LooteerV3 publishes no evaluate_item).
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

-- The Guardian is dead and the glyph used: exit_pit is next. Glyphstone at
-- (gx, gy), the player next to it.
local function setup(gx, gy)
    local h = J.new({rosie = false, dirs = {'ArkhamAsylum', 'Batmobile'}, place = 'pit'})
    h.assert_clean('load')
    h.pos = h.v(gx, gy + 1)
    h.frame()
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

case('P3 the forced (reset timer) exit never walks the pile', function()
    local h = setup(20, 0)
    h.tracker.pit_start_time = h.now - 10000
    local at = run_to_exit(h, 10)
    ok(at ~= nil and at <= 2, 'forced exit cast at once, got ' .. tostring(at))
end)

if #failures > 0 then error(#failures .. ' arkham boss-pile case(s) failed:\n' .. table.concat(failures, '\n')) end
print(string.format('PASS: arkham boss pile, %d checks', checks))
