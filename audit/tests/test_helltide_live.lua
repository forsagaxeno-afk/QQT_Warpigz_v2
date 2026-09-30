-- QQT_Warpigz_v3: opt-in live Helltide zone (core/hr_live.lua) with a curl
-- stub that answers on the next update: Firebase body, stale hour, unknown
-- zone, backoff, one request in flight, no curl, option off (zero requests),
-- the diablo4.life fallback shape, and the search integration in the joint
-- host (straight to the live zone; no buff on arrival refutes it and the
-- normal town cycle runs). Runs under Lua 5.4 and LuaJIT.
local H = dofile(assert(SUITE_ROOT, 'SUITE_ROOT is required') .. '/audit/tests/hr_smart_harness.lua')
local J = dofile(SUITE_ROOT .. '/audit/tests/joint_host.lua')
local R = H.runner('Helltide live zone')
local ok, eq = R.ok, R.eq

local function body(hour, zone)
    return string.format('{"endTime":"2026-09-27T04:55:00.000Z","id":%d,"startTime":"2026-09-27T04:00:00.000Z","zone":"%s"}',
        hour, zone)
end

local function session(opts)
    local s = H.new(opts)
    s.live = s.require('core.hr_live')
    s.set('live_api', true)
    s.at_minute(2)
    return s
end

R.case('Firebase body: this hour\'s zone maps to the patrol zone; one polite request', function()
    local s = session()
    eq(s.live.tick(s.now), true, 'request sent')
    local call = s.curl_calls[1]
    ok(call.url:find('helltides%-7e530') ~= nil, call.url)
    eq(call.headers['User-Agent'], 'QQT-HelltideRevamped/3.0'); eq(call.timeout, 8)
    for _ = 1, 10 do s.advance(0.1); s.live.tick(s.now) end
    eq(#s.curl_calls, 1, 'at most one request in flight')
    eq(s.live.waiting(s.now), true, 'the search may hold for the first answer')
    eq(s.pump(body(H.HOUR, 'dry_steppes'), 200, ''), 1)
    local tp = s.live.zone_tp()
    ok(tp ~= nil and tp.name == 'Step_South', 'dry_steppes -> Step_South')
    eq(s.live.matches_zone('Step_South'), true)
    eq(s.live.waiting(s.now), false)
    for _ = 1, 600 do s.advance(1); s.live.tick(s.now) end
    eq(#s.curl_calls, 1, 'the zone is known for the hour: no more requests')
    s.at_minute(55); eq(s.live.zone_tp(), nil, 'no Helltide at :55')
    for _ = 1, 290 do s.advance(1); s.live.tick(s.now) end
    eq(#s.curl_calls, 1, 'nothing asked in minutes 55-59')
    s.epoch = H.HOUR + 3600 + 5
    eq(s.live.zone_tp(), nil, 'last hour\'s record is stale')
    s.live.tick(s.now)
    eq(#s.curl_calls, 2, 'asked again as soon as the new hour starts')
end)

R.case('a stale hour or an unknown zone is never acted on', function()
    local s = session()
    s.live.tick(s.now); s.pump(body(H.HOUR - 3600, 'hawezar'), 200, '')
    eq(s.live.zone_tp(), nil, 'last hour\'s zone rejected')
    s.advance(30); s.live.tick(s.now)
    eq(#s.curl_calls, 1, 'minute 2: asked again after 60 s, not 30')
    s.advance(31); s.live.tick(s.now)
    eq(#s.curl_calls, 2)
    s.pump(body(H.HOUR, 'westmarch'), 200, '')
    eq(s.live.zone_tp(), nil, 'unknown zone rejected')
    eq(s.logged('unknown zone westmarch'), 1)
    s.advance(61); s.live.tick(s.now)
    s.pump(body(H.HOUR, 'nahantu'), 200, '')
    eq(s.live.zone_tp(), nil, 'Nahantu has no patrol loop: the normal search')
    eq(s.live.zone_name(), 'nahantu')
    eq(s.logged('has no patrol loop'), 1)
end)

R.case('errors back off 60, 120, 240 ... 900 s; a lost callback is an error', function()
    local s = session()
    s.at_minute(0)                                   -- 45 minutes of backoff stay inside the hour
    local gaps, last = {}, nil
    for _ = 1, 7 do
        s.live.tick(s.now)
        local n = #s.curl_calls
        if last then gaps[#gaps + 1] = math.floor(s.curl_calls[n].at - last + 0.5) end
        last = s.curl_calls[n].at
        s.pump('', 503, '')
        repeat s.advance(1); s.live.tick(s.now) until #s.curl_calls > n or s.now - last > 2000
    end
    eq(table.concat(gaps, ','), '60,120,240,480,900,900', 'backoff')
    eq(s.logged('request failed (HTTP 503)'), 1, 'logged once')
    local n = #s.curl_calls                          -- the next request is in flight
    eq(s.live.state().in_flight, true)
    s.curl_queue = {}                                -- the host never calls back
    s.advance(19); s.live.tick(s.now)
    eq(s.live.state().in_flight, false, 'given up after the timeout')
    eq(s.live.state().last_error, 'no answer')
    eq(#s.curl_calls, n, 'and backing off')
    s.curl_refuse = true
    s.advance(901); s.live.tick(s.now)
    eq(s.live.state().in_flight, false, 'a refused request is not in flight')
end)

R.case('without the host curl API, or with the option off: no request, no error', function()
    local s = session({curl = false})
    for _ = 1, 20 do s.advance(1); s.live.tick(s.now) end
    eq(s.logged('no curl API'), 1, 'said once')
    eq(s.live.zone_tp(), nil)
    local off = H.new()
    local live = off.require('core.hr_live')
    for _ = 1, 50 do off.advance(10); live.tick(off.now) end
    eq(#off.curl_calls, 0, 'live_api off: zero requests')
    eq(live.zone_tp(), nil)
    off.set('live_api', true)
    eq(live.zone_tp(), nil)
end)

R.case('diablo4.life fallback: {} is no data; a populated object is mapped by name', function()
    local s = session()
    s.set('live_source', 1)
    s.live.tick(s.now)
    ok(s.curl_calls[1].url:find('diablo4.life', 1, true) ~= nil)
    s.pump('{"helltide":{},"worldBoss":{"name":"Avarice","time":1790488800000},"chestRespawn":1790488800000}', 200, '')
    eq(s.live.zone_tp(), nil, 'empty tracker')
    eq(s.live.state().backoff, 0, 'an empty answer is not an error')
    -- QQT_Warpigz_v3 (night review): diablo4.life sends {} even while a
    -- Helltide runs: helltides.com is asked at once for the rest of the hour.
    s.live.tick(s.now)
    eq(#s.curl_calls, 2, 'asked again at once')
    ok(s.curl_calls[2].url:find('firebaseio', 1, true) ~= nil, 'helltides.com for this hour')
    s.pump('{"endTime":"x","id":' .. s.clock.hour_id() .. ',"startTime":"y","zone":"dry_steppes"}', 200, '')
    local tp = s.live.zone_tp()
    ok(tp ~= nil and tp.name == 'Step_South', 'Dry Steppes from helltides.com')
    eq(s.logged('diablo4.life has no Helltide data'), 1)
    eq(select(1, s.live.parse('{"helltide":{"zone":"Dry Steppes","time":1790481600000},"worldBoss":{}}', 1)), 'dry_steppes')
    eq(select(1, s.live.parse('{"helltide":{"location":"Fractured Peaks"}}', 1)), 'fractured_peaks')
    eq(s.live.parse(string.rep('x', 9000), 0), nil, 'oversized body')
end)

R.case('diablo4.life has no hour id: an early answer stays tentative until minute 5', function()
    local s = session()
    s.set('live_source', 1)
    s.at_minute(0, 30)
    s.live.tick(s.now)
    s.pump('{"helltide":{"zone":"Hawezar"}}', 200, '')          -- still last hour's region
    eq(s.live.zone_tp().name, 'Hawe_Verge', 'usable meanwhile')
    s.advance(61); s.epoch = s.epoch + 61; s.live.tick(s.now)
    eq(#s.curl_calls, 2, 'asked again a minute later')
    s.pump('{"helltide":{"zone":"Dry Steppes"}}', 200, '')
    eq(s.live.zone_tp().name, 'Step_South', 'the new hour\'s region replaces it')
    s.at_minute(6)
    for _ = 1, 120 do s.advance(1); s.live.tick(s.now) end
    eq(#s.curl_calls, 2, 'after minute 5 the answer is settled for the hour')
    eq(s.live.zone_tp().name, 'Step_South')
end)

R.case('refute: the refuted zone is ignored for the rest of the hour, a corrected answer is not', function()
    local s = session()
    s.live.tick(s.now); s.pump(body(H.HOUR, 'scosglen'), 200, '')
    ok(s.live.zone_tp() ~= nil)
    s.live.refute(H.HOUR)
    eq(s.live.zone_tp(), nil)
    eq(s.logged('not confirmed on arrival'), 1)
    s.live.refute(H.HOUR); eq(s.logged('not confirmed on arrival'), 1, 'said once')
    -- diablo4.life, early in the hour: last hour's region first, then the right one.
    local d = session()
    d.set('live_source', 1)
    d.at_minute(0, 20)
    d.live.tick(d.now); d.pump('{"helltide":{"zone":"Hawezar"}}', 200, '')
    d.live.refute(H.HOUR)                             -- no buff at Wejinhani
    eq(d.live.zone_tp(), nil)
    d.advance(1); d.live.tick(d.now)
    eq(#d.curl_calls, 2, 'a refuted tentative answer is asked again at once')
    d.pump('{"helltide":{"zone":"Scosglen"}}', 200, '')
    eq(d.live.zone_tp().name, 'Scos_Coast', 'the corrected region is used')
end)

-- ── search integration (joint host: all of HelltideRevamped + Batmobile) ──
local function joint(active)
    local h = J.new({dirs = {'Batmobile', 'HelltideRevamped'}, place = 'temis', minute = 10})
    h.P[active].helltide = true
    local calls = {}
    rawset(h.G, 'curl', {http_get = function(url, cb)
        calls[#calls + 1] = url
        -- The source's hour id, taken when it answers (the plugin checks it then).
        h.at(0.3, function() cb(body(math.floor(os.time() / 3600) * 3600, 'dry_steppes'), 200, '') end)
        return true
    end})
    local g = h.mod('HelltideRevamped', 'gui').elements
    g.live_api:set(true)
    g.main_toggle:set(true)
    return h, calls
end
local function hr_teleports(h)
    local out = {}
    for _, w in ipairs(h.waypoints) do if w.context == 'HelltideRevamped' then out[#out + 1] = w.sno end end
    return out
end

R.case('search: straight to the live zone, no town cycle', function()
    local h, calls = joint('step')
    ok(h.run_until(function() return h.place == h.P.step end, 60), 'reached the Dry Steppes\n' .. h.tail(30))
    h.run(5)
    h.assert_clean('live search')
    local tps = hr_teleports(h)
    eq(tps[1], 0x462E2, 'the first teleport is the live zone (Jirandai)')
    eq(#tps, 1, 'no other town tried')
    eq(#calls, 1, 'one request')
    eq(h.logged('Live Helltide zone: jirandai'), 1)
    for k in pairs(h.missing) do
        -- Absent optional companions (SilentRavenPlugin ...) are fine; host API is not.
        ok(J.EXPORTS[k] ~= nil or J.ROSIE_EXPORTS[k] ~= nil, 'undefined global read: ' .. k)
    end
end)

R.case('search: no buff on arrival refutes the hint; the town cycle finds the real one', function()
    local h = joint('helltide')                       -- the live source says Dry Steppes, it is Hawezar
    ok(h.run_until(function() return h.place == h.P.helltide end, 240), 'found Hawezar\n' .. h.tail(30))
    h.assert_clean('refuted search')
    local tps = hr_teleports(h)
    eq(tps[1], 0x462E2, 'tried the live zone first')
    eq(h.logged('not confirmed on arrival'), 1)
    eq(tps[#tps], 0x9346B, 'then the cycle reached Wejinhani')
end)

R.finish()
