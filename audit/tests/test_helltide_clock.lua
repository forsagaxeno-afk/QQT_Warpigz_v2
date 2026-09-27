-- QQT_Warpigz_v3: HelltideRevamped UTC clock (core/hr_clock.lua) and the
-- time-zone fix of utils.helltide_active()/do_events(): the Helltide hour and
-- the chest reset slots follow the UTC minute, never the local one.
-- Runs under Lua 5.4 and LuaJIT.
local H = dofile(assert(SUITE_ROOT, 'SUITE_ROOT is required') .. '/audit/tests/hr_smart_harness.lua')
local R = H.runner('Helltide clock')
local ok, eq, near = R.ok, R.eq, R.near

R.case('half-hour time zone: helltide_active and do_events follow the UTC minute, not the local one', function()
    local s = H.new()
    local utils = s.require('core.utils')
    s.clock._now = nil          -- read through os.date like the host
    s.tz_minutes = 30           -- UTC+5:30: the local minute is 30 ahead
    s.at_minute(57)             -- UTC :57 (no Helltide), local :27
    eq(s.env.os.date('%M'), '27', 'local minute differs')
    eq(utils.helltide_active(), false, 'no Helltide at UTC :57')
    s.at_minute(27)             -- UTC :27, local :57
    eq(s.env.os.date('%M'), '57')
    eq(utils.helltide_active(), true, 'Helltide at UTC :27 although the local minute is 57')
    s.at_minute(44); eq(utils.do_events(), true, 'events before :45 (Warplan / legacy)')
    s.at_minute(46); s.tz_minutes = -30
    eq(utils.do_events(), false, 'no events from UTC :45 on')
end)

R.case('Farm mode uses "Events until minute"; Warplan keeps minute 45', function()
    local s = H.new()
    local utils = s.require('core.utils')
    s.set('mode', 1); s.set('event_until_min', 50)
    s.at_minute(47); eq(utils.do_events(), true, 'Farm: until :50')
    s.at_minute(50); eq(utils.do_events(), false)
    s.set('mode', 0)
    s.at_minute(47); eq(utils.do_events(), false, 'Warplan: :45 as before')
    s.set('mode', 1); s.set('event_until_min', 99)
    s.at_minute(54); eq(utils.do_events(), true, 'clamped to 55')
end)

R.case('minutes_left, active and starts_in', function()
    local s = H.new()
    local c = s.clock
    s.at_minute(10, 30); near(c.minutes_left(), 44.5, 1e-9, 'at 10:30')
    eq(c.active(), true)
    s.at_minute(54, 59); near(c.minutes_left(), 1 / 60, 1e-9, 'one second left')
    s.at_minute(55, 0); eq(c.minutes_left(), 0); eq(c.active(), false)
    near(c.starts_in(), 300, 1e-9, 'next Helltide in 5 minutes')
    s.at_minute(0, 0); eq(c.active(), true); eq(c.starts_in(), 0)
    eq(c.mmss(754), '12:34'); eq(c.mmss(-5), '0:00'); eq(c.mmss(0 / 0), '0:00')
end)

R.case('reset slots, the next reset and crossing a boundary (also across the hour)', function()
    local s = H.new()
    local c = s.clock
    local expect = {[0] = 1, [14] = 1, [15] = 2, [19] = 2, [20] = 3, [29] = 3, [30] = 4, [39] = 4, [40] = 5,
        [44] = 5, [45] = 6, [54] = 6, [59] = 6}
    for minute, slot in pairs(expect) do eq(c.reset_slot(minute), slot, 'slot at :' .. minute) end
    s.at_minute(10, 0); near(c.next_reset_in(), 300, 1e-9, 'next reset at :15')
    s.at_minute(46, 0); near(c.next_reset_in(), 14 * 60, 1e-9, 'after :45 the next is :00')
    s.at_minute(14, 59)
    local crossed, id = c.crossed_reset(nil)
    eq(crossed, false, 'no previous slot: not a crossing')
    crossed = c.crossed_reset(id); eq(crossed, false, 'same slot')
    s.advance(1)
    local id2
    crossed, id2 = c.crossed_reset(id); eq(crossed, true, 'crossed :15')
    ok(id2 ~= id)
    s.at_minute(59, 59)
    local _, late = c.crossed_reset(nil)
    s.advance(1)                       -- 00:00 of the next hour
    crossed = c.crossed_reset(late)
    eq(crossed, true, 'the next hour is a new slot')
    eq(c.hour_id(), H.HOUR + 3600)
end)

R.case('without os.date the epoch clock (UTC) is used', function()
    local s = H.new()
    s.clock._now = nil
    s.env.os.date = function() error('os.date unavailable') end
    s.at_minute(56)
    eq(s.clock.active(), false, 'epoch minute 56')
    s.at_minute(3)
    eq(s.clock.minute(), 3)
    eq(s.clock.hour_id(), H.HOUR)
end)

R.finish()
