-- QQT_Warpigz_v3: Helltide statistics (core/hr_stats.lua): earned / spent /
-- lost accounting, deaths, Helltide records, EWMA rates, persistence through
-- the bounded store (core/hr_store.lua) and its write-failure latch, and the
-- main.lua wiring (files only while the plugin is enabled, flush on disable).
-- Runs under Lua 5.4 and LuaJIT.
local H = dofile(assert(SUITE_ROOT, 'SUITE_ROOT is required') .. '/audit/tests/hr_smart_harness.lua')
local R = H.runner('Helltide stats')
local ok, eq, near = R.ok, R.eq, R.near

local function stats_session(opts)
    local s = H.new(opts)
    local stats = s.require('core.hr_stats')
    function s.tick(cinders, in_helltide, dt)
        s.advance(dt or 0.3)
        if cinders ~= nil then s.cinders = cinders end
        stats.tick(s.now, s.cinders, in_helltide ~= false, 'Step_South')
    end
    return s, stats
end

R.case('cinder sequences: earned, spent (chests) and lost at minute 55', function()
    local s, stats = stats_session()
    s.at_minute(10)
    s.tick(100)                      -- baseline: cinders held at start are not "earned"
    eq(stats.session.earned, 0)
    s.tick(150); eq(stats.session.earned, 50, 'kills')
    s.tick(75); eq(stats.session.spent, 75, 'a chest')
    eq(stats.helltide.earned, 50); eq(stats.helltide.spent, 75)
    s.at_minute(55)
    s.tick(0)                        -- the Helltide ended: the balance is gone
    eq(stats.session.lost, 0, 'a 0 must last a second first')
    s.tick(0, false, 1.2)
    eq(stats.session.lost, 75, 'the whole balance is lost')
    eq(stats.session.spent, 75, 'not counted as spent')
    eq(stats.helltide, nil, 'record closed at :55')
    eq(#stats.history, 1)
    eq(stats.history[1].lost, 75, 'lost goes to the Helltide that just ended')
    eq(stats.history[1].earned, 50)
end)

R.case('a Mystery that spends everything while the Helltide runs is spent, not lost', function()
    local s, stats = stats_session()
    s.at_minute(20)
    s.tick(0); s.tick(250)
    s.tick(0); s.tick(0, true, 1.2)
    eq(stats.session.spent, 250); eq(stats.session.lost, 0)
end)

R.case('a 0 reading shorter than a second (loading, host glitch) is ignored', function()
    local s, stats = stats_session()
    s.at_minute(20)
    s.tick(300); s.tick(0, true, 0.3); s.tick(300, true, 0.3)
    eq(stats.session.spent, 0); eq(stats.session.lost, 0); eq(stats.session.earned, 0)
    s.cinder_error = true
    s.tick(nil) -- unreadable: nothing happens
    eq(stats.session.earned, 0)
end)

R.case('death edge is counted once per death (core/recovery.lua)', function()
    local s, stats = stats_session()
    s.tracker.hr_stats = stats
    local recovery = s.require('core.recovery')
    s.dead = true
    for _ = 1, 5 do recovery.revive_if_dead(s.player); s.advance(0.5) end
    eq(stats.session.deaths, 1, 'one death over several dead ticks')
    s.dead = false; recovery.revive_if_dead(s.player)
    s.dead = true; recovery.revive_if_dead(s.player)
    eq(stats.session.deaths, 2)
    eq(stats.alltime.deaths, 2)
end)

R.case('Helltide rollover when the hour changes', function()
    local s, stats = stats_session()
    s.at_minute(50)
    s.tick(10); s.tick(60)
    for _ = 1, 150 do s.tick(nil) end -- 45 s inside
    local first = stats.helltide.hour_id
    eq(first, H.HOUR)
    s.epoch = H.HOUR + 3600 + 30         -- 00:00:30 of the next hour
    s.tick(60)
    eq(#stats.history, 1, 'the previous Helltide is in the history')
    eq(stats.history[1].hour_id, H.HOUR)
    eq(stats.history[1].zone, 'Step_South')
    eq(stats.helltide.hour_id, H.HOUR + 3600, 'a new record')
    eq(stats.session.helltides, 1)
end)

R.case('EWMA rate: converges on the farm pace, frozen outside, decays on a dry spell', function()
    local s, stats = stats_session()
    s.at_minute(0)
    local c = 0
    s.tick(c)
    for _ = 1, 600 do c = c + 1; s.tick(c, true, 1.0) end        -- 60/min for 10 minutes
    near(stats.rate_min(), 60, 3, 'about 60/min')
    near(stats.rate_hr(), 3600, 180)
    local before = stats.rate_min()
    for _ = 1, 300 do s.tick(c, false, 1.0) end                  -- town: no change
    near(stats.rate_min(), before, 1e-9, 'frozen outside the Helltide')
    for _ = 1, 300 do s.tick(c, true, 1.0) end                   -- 5 dry minutes inside
    ok(stats.rate_min() > 15 and stats.rate_min() < 30, 'decayed to about e^-1: ' .. stats.rate_min())
end)

R.case('all-time totals and history survive a reload (learned/stats.txt)', function()
    local s, stats = stats_session()
    s.at_minute(30)
    s.tick(0); s.tick(400); s.tick(150)
    stats.on_chest_opened('usz_rewardGizmo_Uber', 250)
    stats.on_chest_opened('usz_rewardGizmo_Gloves', 75)
    stats.on_chest_opened('silent', 0)
    stats.on_death(); stats.on_tear_done()
    s.at_minute(55); s.tick(nil)          -- close: the record is saved
    ok(s.file('learned/stats.txt') ~= nil, 'written')
    local s2 = H.new({files = s.files})
    local stats2 = s2.require('core.hr_stats')
    stats2.load()
    eq(stats2.alltime.earned, 400); eq(stats2.alltime.spent, 250)
    eq(stats2.alltime.chests, 2); eq(stats2.alltime.mystery, 1); eq(stats2.alltime.silent, 1)
    eq(stats2.alltime.deaths, 1); eq(stats2.alltime.tears, 1); eq(stats2.alltime.helltides, 1)
    eq(#stats2.history, 1); eq(stats2.history[1].earned, 400); eq(stats2.history[1].chests, 2)
    eq(stats2.session.earned, 0, 'a new session starts at 0')
    ok(stats2.rate_min() == 0, 'no seed from less than 10 minutes of data')
end)

R.case('corrupt, unknown and oversized lines are skipped', function()
    local files = {[H.MEM_ROOT .. 'learned/stats.txt'] = table.concat({
        'v1', 'earned=1200', 'spent=abc', 'garbage line', 'lost=-5', 'deaths=3', 'unknown_key=9',
        'h|bad|x', 'h|1790481600|Step_South|10|5|0|1|0|0|300', 'h|1790485200|Step_South|20|5|0|1|0|0|300|extra',
        'secs=1800', string.rep('x', 600), 'chests=4'}, '\n')}
    local s = H.new({files = files})
    local stats = s.require('core.hr_stats')
    stats.load()
    eq(stats.alltime.earned, 1200); eq(stats.alltime.spent, 0); eq(stats.alltime.lost, 0)
    eq(stats.alltime.deaths, 3); eq(stats.alltime.chests, 4)
    eq(#stats.history, 1, 'one valid history line')
    near(stats.rate_min(), 1200 / 30, 1e-9, 'seeded from the all-time pace (30 minutes)')
end)

R.case('a stats file that exists but cannot be read is never overwritten; Reset all-time can', function()
    local path = H.MEM_ROOT .. 'learned/stats.txt'
    local old = 'v1\nearned=5000\nsecs=7200\n'
    local s, stats = stats_session({files = {[path] = old}})
    s.fail_read = function(p) return p == path end   -- locked by another program
    s.at_minute(10); s.tick(0); s.tick(50)
    for _ = 1, 150 do s.tick(nil) end
    s.at_minute(55); s.tick(nil)                      -- the record closes: a save is due
    eq(stats.save(s.now), false)
    stats.flush(s.now)
    eq(#s.writes, 0, 'never written')
    eq(s.files[path], old, 'the all-time numbers are kept')
    s.fail_read = nil
    stats.reset_alltime()
    eq(#s.writes, 1, 'the explicit reset writes')
    ok(s.files[path]:find('earned=0', 1, true) ~= nil)
    -- Over the 1 MB read limit: the same.
    local big = string.rep('h|1790481600|Step_South|10|5|0|1|0|0|300\n', 26000)
    local t, stats2 = stats_session({files = {[path] = big}})
    t.tick(0); t.tick(50)
    eq(t.logged('larger than 1024 KB'), 1)
    eq(stats2.save(t.now), false)
    eq(t.files[path], big)
end)

R.case('a file that cannot be written is given up after 3 failures (one log line)', function()
    local s, stats = stats_session()
    s.fail_write = function() return true end
    s.at_minute(10); s.tick(0); s.tick(50)
    for _ = 1, 5 do stats.save(s.now) end
    eq(#s.writes, 3, 'three attempts, then no more')
    eq(s.store.failed['learned/stats.txt'], true)
    eq(s.logged('cannot write learned/stats.txt'), 1)
    local big = {}
    for i = 1, 40000 do big[i] = '0123456789abcdef\n' end
    local s2 = H.new()
    eq(s2.store.write('learned/big.txt', big), false, 'over 512 KB is refused')
    eq(#s2.writes, 0)
    eq(s2.logged('not written'), 1)
end)

R.case('store: the root is this plugin\'s absolute folder from package.path, else nothing is written', function()
    local s = H.new()
    local store = s.store
    local function pkg(path)
        s.env.package = {path = path, searchpath = function(name, p)
            for template in p:gmatch('[^;]+') do
                local candidate = template:gsub('%?', name)
                if s.files[candidate] then return candidate end
            end
            return nil
        end}
    end
    s.files['C:\\QQT\\scripts\\HelltideRevamped\\gui.lua'] = '-- gui'
    s.files['C:\\QQT\\scripts\\HelltideRevamped\\core\\hr_store.lua'] = '-- store'
    pkg('C:\\QQT\\scripts\\HelltideRevamped\\?.lua;C:\\QQT\\scripts\\HelltideRevamped\\?\\init.lua')
    store.unresolve()
    eq(store.root(), 'C:\\QQT\\scripts\\HelltideRevamped\\')
    eq(store.path('learned/stats.txt'), 'C:\\QQT\\scripts\\HelltideRevamped\\learned\\stats.txt', 'Windows separators')
    ok(store.write('learned/stats.txt', {'v1\n'}), 'written under the plugin folder')
    ok(s.files['C:\\QQT\\scripts\\HelltideRevamped\\learned\\stats.txt'] == 'v1\n')
    -- Another plugin's folder (no core/hr_store.lua there) is refused.
    s.files['/q/Other/gui.lua'] = '-- gui'
    pkg('/q/Other/?.lua')
    store.unresolve()
    eq(store.root(), nil, 'not this plugin')
    local writes = #s.writes
    eq(store.write('learned/stats.txt', {'x\n'}), false)
    eq(#s.writes, writes, 'nothing written without a root')
    -- A relative path would follow the working directory: refused too.
    s.files['./gui.lua'] = '-- gui'; s.files['./core/hr_store.lua'] = '-- store'
    pkg('./?.lua')
    store.unresolve()
    eq(store.root(), nil, 'relative root refused')
    -- os.rename present: temp file, then rename (and the Windows replace path).
    s.files['/p/HelltideRevamped/gui.lua'] = '-- gui'; s.files['/p/HelltideRevamped/core/hr_store.lua'] = '-- store'
    pkg('/p/HelltideRevamped/?.lua')
    store.unresolve()
    local renames = 0
    rawset(s.env.os, 'rename', function(a, b)
        renames = renames + 1
        if s.files[b] then return nil, 'exists' end -- Windows: no replace
        s.files[b], s.files[a] = s.files[a], nil
        return true
    end)
    rawset(s.env.os, 'remove', function(a) s.files[a] = nil; return true end)
    ok(store.write('learned/x.txt', {'one\n'}))
    eq(s.files['/p/HelltideRevamped/learned/x.txt'], 'one\n'); eq(s.files['/p/HelltideRevamped/learned/x.txt.tmp'], nil)
    ok(store.write('learned/x.txt', {'two\n'}))
    eq(s.files['/p/HelltideRevamped/learned/x.txt'], 'two\n', 'replaced through remove + rename')
    eq(renames, 3)
    local lines = store.read_lines('learned/x.txt')
    eq(#lines, 1); eq(lines[1], 'two')
    s.files['/p/HelltideRevamped/learned/y.txt.tmp'] = 'left\nover\n'
    eq(#store.read_lines('learned/y.txt'), 2, 'an interrupted save is read from the temp file')
    -- The rename fails and so does the direct write: the temp copy is the
    -- only complete one and stays (read back by the next load).
    local main = '/p/HelltideRevamped/learned/x.txt'
    rawset(s.env.os, 'rename', function() return nil, 'locked' end)
    s.fail_write = function(p) return p == main end
    eq(store.write('learned/x.txt', {'three\n'}), false)
    eq(s.files[main], nil, 'the old file was removed for the replace')
    eq(s.files[main .. '.tmp'], 'three\n', 'the temp copy is kept')
    eq(store.read_lines('learned/x.txt')[1], 'three', 'and read back')
    -- The direct write works: the temp copy goes once the file is complete.
    s.fail_write = nil
    ok(store.write('learned/x.txt', {'four\n'}))
    eq(s.files[main], 'four\n'); eq(s.files[main .. '.tmp'], nil)
end)

R.case('main.lua: stats tick only while enabled, saved every 5 minutes and on switch-off', function()
    local s = H.new({cinders = 10})
    s.zone = 'Scos_Coast'
    assert(loadfile(SUITE_ROOT .. '/HelltideRevamped/main.lua', 't', s.env))()
    local stats = s.require('core.hr_stats')
    local function run(seconds) for _ = 1, math.floor(seconds / 0.1 + 0.5) do s.advance(0.1); s.update() end end
    s.at_minute(10)
    run(20)
    eq(stats.session.earned, 0); eq(#s.writes, 0, 'disabled: nothing written')
    s.gui.elements.main_toggle:set(true)
    run(1); s.cinders = 60; run(1)
    eq(stats.session.earned, 50, 'enabled: counted')
    eq(s.env.HelltideRevampedPlugin.status().stats.earned, 50, 'status().stats')
    run(310)
    ok(s.file('learned/stats.txt') ~= nil, 'saved within 5 minutes')
    local writes = #s.writes
    s.cinders = 80; run(1)
    s.env.HelltideRevampedPlugin.disable()
    run(1)
    ok(#s.writes > writes, 'switched off: pending numbers saved')
    ok(s.file('learned/stats.txt'):find('earned=70', 1, true) ~= nil, 'with the last earnings')
end)

-- QQT_Warpigz_v3 (night review): end_seen_at was refreshed through :55-:59 and
-- never cleared, so for ~10 minutes of the next Helltide a chest that spent
-- the balance to exactly 0 was booked as "lost".
R.case('a new Helltide chest that spends the balance to exactly 0 is spent, not lost', function()
    local s, stats = stats_session()
    s.at_minute(50)
    s.tick(40)                                        -- baseline
    s.at_minute(55); s.tick(0, false); s.tick(0, false, 1.2)
    eq(stats.session.lost, 40, 'the balance held at the end is lost')
    s.at_minute(57); s.tick(0, false)                 -- the break, bot still running
    s.epoch = H.HOUR + 3600 + 60                      -- 00:01 of the next hour
    s.tick(0); s.tick(75)
    s.epoch = H.HOUR + 3600 + 4 * 60                  -- 00:04: a 75-cinder chest
    s.tick(0); s.tick(0, true, 1.2)
    eq(stats.session.spent, 75, 'spent'); eq(stats.session.lost, 40, 'nothing more lost')
    eq(stats.helltide.spent, 75); eq(stats.helltide.lost, 0)
    -- A balance still carried over from the ended Helltide keeps the grace.
    local s2, stats2 = stats_session()
    s2.at_minute(50); s2.tick(120)
    s2.at_minute(58); s2.tick(120, false)
    s2.epoch = H.HOUR + 3600 + 30
    s2.tick(120); s2.tick(0); s2.tick(0, true, 1.2)
    eq(stats2.session.lost, 120, 'carried balance zeroed after the hour: lost')
    eq(stats2.session.spent, 0)
end)

-- QQT_Warpigz_v3 (night review): without an all-time seed the first 15 s
-- bucket seeded the EWMA at full weight (one pile read as 100+/min for 10+ min).
R.case('first session: one early cinder pile does not inflate the rate', function()
    local s, stats = stats_session()
    s.at_minute(5)
    local c = 0
    s.tick(c)
    c = 30; s.tick(c, true, 1.0)                        -- a pile in the first seconds
    for _ = 1, 20 do s.tick(c, true, 1.0) end
    ok(stats.rate_min() <= 12, 'after ~20 s: ' .. stats.rate_min())
    for _ = 1, 280 do                                   -- a steady 10/min to minute 5
        s.tick(c, true, 1.0)
        if _ % 6 == 0 then c = c + 1 end
    end
    for _ = 1, 300 do s.tick(c, true, 1.0); if _ % 6 == 0 then c = c + 1 end end
    ok(stats.rate_min() < 16, 'after ~10 minutes at 10/min: ' .. stats.rate_min())
    ok(stats.rate_min() > 8, 'still tracks the pace: ' .. stats.rate_min())
end)

R.finish()
