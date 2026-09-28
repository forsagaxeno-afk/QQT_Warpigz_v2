-- QQT_Warpigz_v3: web dashboard data (core/hr_dashboard.lua, core/hr_json.lua):
-- the file is `window.HR_DATA=<valid JSON>;`, bounded to 256 KB (map layers
-- cut first), written at most every 'Dashboard update' seconds, and never
-- while the option is off. The shipped theme pages read it back. Runs under Lua
-- 5.4 and LuaJIT.
local H = dofile(assert(SUITE_ROOT, 'SUITE_ROOT is required') .. '/audit/tests/hr_smart_harness.lua')
local R = H.runner('Helltide dashboard')
local ok, eq = R.ok, R.eq
local v = H.v

-- Strict JSON validator (RFC 8259 grammar; no decoding).
local function json_check(text)
    local pos = 1
    local function ws() pos = text:find('[^ \t\r\n]', pos) or (#text + 1) end
    local function peek() return text:sub(pos, pos) end
    local function str()
        pos = pos + 1
        while true do
            local c = peek()
            if c == '' then error('unterminated string') end
            if c == '"' then pos = pos + 1; return end
            if c == '\\' then
                local e = text:sub(pos + 1, pos + 1)
                if e == 'u' then
                    assert(text:sub(pos + 2, pos + 5):match('^%x%x%x%x$'), 'bad \\u escape at ' .. pos)
                    pos = pos + 6
                else
                    assert(e:match('^["\\/bfnrt]$'), 'bad escape at ' .. pos)
                    pos = pos + 2
                end
            else
                assert(c:byte() >= 32, 'control character in a string at ' .. pos)
                pos = pos + 1
            end
        end
    end
    local value
    local function list(close, item)
        pos = pos + 1; ws()
        if peek() == close then pos = pos + 1; return end
        while true do
            item(); ws()
            local d = peek(); pos = pos + 1
            if d == close then return end
            assert(d == ',', 'expected , or ' .. close .. ' at ' .. (pos - 1))
            ws()
        end
    end
    value = function()
        ws()
        local c = peek()
        if c == '{' then
            list('}', function()
                assert(peek() == '"', 'object key expected at ' .. pos); str(); ws()
                assert(peek() == ':', ': expected at ' .. pos); pos = pos + 1
                value()
            end)
        elseif c == '[' then
            list(']', value)
        elseif c == '"' then
            str()
        else
            local lit = text:match('^%-?%d+%.?%d*[eE]?[%+%-]?%d*', pos) or text:match('^true', pos)
                or text:match('^false', pos) or text:match('^null', pos)
            assert(lit and #lit > 0 and not lit:match('%.$'), 'bad value at ' .. pos .. ': ' .. text:sub(pos, pos + 10))
            pos = pos + #lit
        end
    end
    value(); ws()
    assert(pos > #text, 'trailing data at ' .. pos)
    return true
end

local function session(opts)
    local s = H.new(opts)
    s.dash = s.require('core.hr_dashboard')
    s.stats = s.require('core.hr_stats')
    s.atlas = s.require('core.hr_atlas')
    s.fence = s.require('core.hr_fence')
    s.roads = s.require('core.hr_roads')
    s.tracker.hr_fence = s.fence
    s.atlas.set_zone('Step_South')
    return s
end

local function payload(text)
    ok(text:sub(1, #'window.HR_DATA=') == 'window.HR_DATA=', 'script prefix')
    ok(text:sub(-2) == ';\n', 'ends with ;')
    return text:sub(#'window.HR_DATA=' + 1, -3)
end

R.case('json encoder: escaping, finite numbers, arrays and objects, depth', function()
    local s = session()
    local json = s.require('core.hr_json')
    eq(json.encode({1, 2, 3}), '[1,2,3]')
    eq(json.encode({b = 1, a = 'x'}), '{"a":"x","b":1}')
    eq(json.encode('q"\\\n\t\1'), '"q\\"\\\\\\n\\t\\u0001"')
    eq(json.encode({0 / 0, math.huge, -math.huge, 1.25, -3}), '[0,0,0,1.25,-3]')
    eq(json.encode({}), '{}')
    eq(json.encode({t = true, f = false, [7] = 'skipped'}), '{"f":false,"t":true}')
    local deep = {}
    local cur = deep
    for _ = 1, 10 do cur.n = {}; cur = cur.n end
    ok(json.encode(deep):find('null', 1, true) ~= nil, 'deeper than 6 levels is null')
    json_check(json.encode(deep))
    eq(json.encode({json.raw('[1,2]')}), '[[1,2]]', 'raw fragments')
end)

R.case('the data file is window.HR_DATA=<valid JSON>; with every section', function()
    local s = session({cinders = 180})
    s.set('dashboard', true)
    s.at_minute(12)
    s.stats.tick(s.now, 100, true, 'Step_South'); s.advance(0.3)
    s.stats.tick(s.now, 180, true, 'Step_South')
    s.stats.note('[CHEST ORDER] a "quoted" note\nwith a line break')
    for i = 1, 30 do s.atlas.observe(i % 5 == 0 and 'usz_rewardGizmo_Uber' or 'usz_rewardGizmo_Gloves', 75, v(i * 9, i * 3), true) end
    for i = 0, 10 do s.fence.tick(s.now, true, v(i * 20, 0)); s.advance(2.1) end
    s.tracker.hr_get_remembered = function()
        return {k1 = {name = 'usz_rewardGizmo_Uber', cost = 250, position = v(40, 40), predicted = true}}, 'k1'
    end
    s.pos = v(5, 5)
    eq(s.dash.tick(s.now, s.pos, true), true, 'written')
    local text = s.file('dashboard/hr_data.js')
    local body = payload(text)
    json_check(body)
    for _, key in ipairs({'"v":1', '"zone":"Step_South"', '"cinders":180', '"helltide":', '"session":', '"alltime":',
        '"history":', '"chests":[', '"atlas":[', '"fence_in":[', '"fence_cell":20', '"trail":[', '"perf":', '"events":[',
        '"rates":', '"status":"target"', 'a \\"quoted\\" note\\nwith a line break'}) do
        ok(body:find(key, 1, true) ~= nil, 'has ' .. key)
    end
end)

R.case('a fresh session: every list is a JSON array even when empty (the page iterates them)', function()
    local s = session()
    s.set('dashboard', true)
    s.dash.tick(s.now, s.pos, true)
    local body = payload(s.file('dashboard/hr_data.js'))
    json_check(body)
    for _, key in ipairs({'"events":[]', '"chests":[]', '"history":[]', '"perf":[]', '"route":[]', '"atlas":[]'}) do
        ok(body:find(key, 1, true) ~= nil, 'empty list as []: ' .. key)
    end
end)

R.case('256 KB bound: map layers are cut first; still too big: nothing is written', function()
    local s = session()
    s.set('dashboard', true)
    for i = 1, 200 do s.atlas.observe('usz_rewardGizmo_Gloves', 75, v(i * 10, 0), true) end
    s.fence.seed('Step_South', (function()
        local wps = {}
        for i = 1, 4000 do wps[i] = v((i % 80) * 20, math.floor(i / 80) * 20) end
        return wps
    end)())
    for i = 1, 50 do s.stats.history[i] = {hour_id = H.HOUR - i * 3600, zone = 'Step_South', earned = 900, spent = 800,
        lost = 0, chests = 9, mystery = 1, deaths = 0, secs = 3300} end
    s.dash.tick(s.now, s.pos, true)
    local full = s.file('dashboard/hr_data.js')
    ok(#full <= s.dash.MAX_BYTES, 'within 256 KB: ' .. #full)
    ok(full:find('"fence_in":[', 1, true) ~= nil, 'everything fits at the real bound')
    s.dash.MAX_BYTES = math.floor(#full * 0.6)
    s.advance(11); s.dash.tick(s.now, s.pos, true)
    local cut = s.file('dashboard/hr_data.js')
    ok(#cut <= s.dash.MAX_BYTES, 'bounded: ' .. #cut)
    ok(cut:find('"fence_in"', 1, true) == nil, 'the fence layer was cut')
    json_check(payload(cut))
    s.dash.MAX_BYTES = 200
    local writes = #s.writes
    s.advance(11)
    eq(s.dash.tick(s.now, s.pos, true), false, 'nothing fits')
    eq(#s.writes, writes, 'no write')
    s.dash.MAX_BYTES = 256 * 1024
end)

R.case('written at most every "Dashboard update" seconds; trail sampled every 5 s', function()
    local s = session()
    s.set('dashboard', true); s.set('dashboard_sec', 10)
    for _ = 1, 250 do s.advance(0.1); s.pos = v(s.now, 0); s.dash.tick(s.now, s.pos, true) end
    eq(#s.writes, 3, 'at 0, 10 and 20 s')
    s.set('dashboard_sec', 1)                        -- clamped to 5
    for _ = 1, 100 do s.advance(0.1); s.dash.tick(s.now, s.pos, true) end
    eq(#s.writes, 5, 'every 5 s at most')
    local body = payload(s.file('dashboard/hr_data.js'))
    local trail = body:match('"trail":(%b[])')
    local points = 0
    for _ in trail:gmatch('%[%-?%d+,%-?%d+%]') do points = points + 1 end
    ok(points >= 6 and points <= 8, 'a trail point every 5 s: ' .. points)
end)

-- QQT_Warpigz_v3: three theme pages share hr_data.js; index.html redirects to
-- the last chosen one (localStorage 'hr_dash_theme', Forge by default).
-- QQT_Warpigz_v3 (3.3.0): the pages moved to WarRoom/dashboard/helltide/
-- (3.3.6: WarRoom is archived with its tests in archive/, not shipped); the
-- page checks below run only when a copy ships in HelltideRevamped/dashboard/.
local THEMES = {'forge.html', 'daylight.html', 'console.html'}
local function read_page(name)
    local f = io.open(SUITE_ROOT .. '/HelltideRevamped/dashboard/' .. name, 'r')
    if not f then return nil end
    local page = f:read('*a'); f:close()
    return page
end
local PAGES_MOVED = read_page('index.html') == nil
if PAGES_MOVED then print('NOTE: no HelltideRevamped/dashboard pages ship (moved to the archived WarRoom) — HR page checks skipped') end

local function no_external(page, name)
    for _, bad in ipairs({'src="http', "src='http", 'href="http', "href='http", '<link', '@import', 'url(', '<img',
        '<iframe', 'fetch(', 'XMLHttpRequest'}) do
        ok(not page:find(bad, 1, true), name .. ': no external resources: ' .. bad)
    end
    for _, word in ipairs({'Senq', 'Licensed', 'lifetime'}) do
        ok(not page:find(word, 1, true), name .. ': no third-party branding: ' .. word)
    end
end

R.case('option off: zero writes; the theme pages ship and read the data file', function()
    local s = session()
    for _ = 1, 600 do s.advance(0.1); s.dash.tick(s.now, s.pos, true) end
    eq(#s.writes, 0, 'dashboard off')
    for _, name in ipairs(PAGES_MOVED and {} or THEMES) do
        local page = read_page(name)
        ok(page:find("'hr_data.js?ts='", 1, true) ~= nil, name .. ': reloads hr_data.js with a cache buster')
        ok(page:find('setInterval(load, 5000)', 1, true) ~= nil, name .. ': every 5 s')
        ok(page:find('window.HR_DATA', 1, true) ~= nil, name .. ': reads window.HR_DATA')
        no_external(page, name)
        -- one page (header, KPI cards, map, now, stats, opened, history, performance).
        for _, id in ipairs({'id="k-reset"', 'id="k-end"', 'id="k-cind"', 'id="k-sess"', 'id="k-all"', 'id="map"',
            'id="filter"', 'id="fit"', 'id="border"', 'id="coords"', 'id="follow"', 'id="bgbtn"', 'id="activity"',
            'id="stats"', 'id="opened"', 'id="events"', 'id="hist"', 'id="perftab"', 'id="refresh"'}) do
            ok(page:find(id, 1, true) ~= nil, name .. ': ' .. id)
        end
        ok(page:find('<title>HelltideRevamped — Live</title>', 1, true) ~= nil, name .. ': title')
        -- the theme switcher: first thing in <body>, links to all three, marks this one, saves the choice.
        local nav = page:match('<body>%s*(<nav class="hrsw".-</nav>)')
        ok(nav ~= nil, name .. ': theme switcher at the top of the page')
        nav = nav or ''
        for _, other in ipairs(THEMES) do
            ok(nav:find('href="' .. other .. '"', 1, true) ~= nil, name .. ': switcher links ' .. other)
        end
        ok(nav:find('href="' .. name .. '" data%-theme%-file="[%a]+" class="cur"') ~= nil, name .. ': current theme highlighted')
        local _, cur = nav:gsub('class="cur"', '')
        eq(cur, 1, name .. ': exactly one current theme')
        ok(nav:find('>Forge<', 1, true) and nav:find('>Daylight<', 1, true) and nav:find('>Console<', 1, true), name .. ': labels')
        ok(page:find("localStorage.setItem('hr_dash_theme'", 1, true) ~= nil, name .. ': saves the choice')
    end
    local keep = io.open(SUITE_ROOT .. '/HelltideRevamped/dashboard/.keep', 'r')
    ok(keep ~= nil, 'the dashboard folder ships'); keep:close()
    keep = io.open(SUITE_ROOT .. '/HelltideRevamped/learned/.keep', 'r')
    ok(keep ~= nil, 'the learned folder ships'); keep:close()
end)

R.case('index.html opens the last chosen theme (Forge by default, localStorage guarded)', function()
    if PAGES_MOVED then return end -- QQT_Warpigz_v3 (3.3.0)
    local page = read_page('index.html')
    ok(page:find('<title>HelltideRevamped — Live</title>', 1, true) ~= nil, 'title')
    ok(page:find("localStorage.getItem('hr_dash_theme')", 1, true) ~= nil, 'reads the saved theme')
    ok(page:find("location.replace(pick + '.html')", 1, true) ~= nil, 'redirects without a history entry')
    ok(page:find("var pick = 'forge'", 1, true) ~= nil, 'Forge by default')
    local try_at = page:find('try {', 1, true)
    local get_at = page:find('localStorage.getItem', 1, true)
    local catch_at = page:find('} catch (e)', 1, true)
    ok(try_at and get_at and catch_at and try_at < get_at and get_at < catch_at, 'localStorage inside try/catch')
    for _, theme in ipairs({'forge', 'daylight', 'console'}) do
        ok(page:find(theme .. ': 1', 1, true) ~= nil, 'known theme ' .. theme)
        ok(page:find('href="' .. theme .. '.html"', 1, true) ~= nil, 'fallback link ' .. theme)
    end
    ok(not page:find('hr_data.js?ts=', 1, true), 'the entry page loads no data itself')
    no_external(page, 'index.html')
end)

-- ── QQT_Warpigz_v3: the live view (wave, target, goal, opened, road) ─────
local function full_session()
    local s = session({cinders = 180, zone = 'Kehj_Oasis'})
    s.atlas.set_zone('Kehj_Oasis')
    s.set('dashboard', true)
    s.tracker.hr_stats = s.stats
    s.tracker.hr_atlas = s.atlas
    s.tracker.hr_in_ht = true
    s.tracker.hr_task_state = 'MOVING_TO_REMEMBERED_CHEST'
    s.tracker.hr_get_remembered = function()
        return {k1 = {name = 'Helltide_RewardChest_Random', cost = 75, position = v(30, 40), route = {}},
            k2 = {name = 'usz_rewardGizmo_Uber', cost = 250, position = v(-100, 0)},
            k3 = {name = 'usz_rewardGizmo_Rings', cost = 75, position = v(0, -90), predicted = true}}, 'k1'
    end
    return s
end

local function decode_keys(body)
    -- Top-level keys of the payload object (depth-1 scan of the JSON text).
    local keys, depth, i = {}, 0, 1
    while i <= #body do
        local c = body:sub(i, i)
        if c == '"' then
            local j = i + 1
            while body:sub(j, j) ~= '"' do if body:sub(j, j) == '\\' then j = j + 1 end; j = j + 1 end
            if depth == 1 and body:sub(j + 1, j + 1) == ':' then keys[body:sub(i + 1, j - 1)] = true end
            i = j
        elseif c == '{' or c == '[' then depth = depth + 1
        elseif c == '}' or c == ']' then depth = depth - 1 end
        i = i + 1
    end
    return keys
end

R.case('live view: reset wave, timers, goal, target card, now, still to open', function()
    local s = full_session()
    s.at_minute(21, 40)
    s.pos = v(0, 0)
    s.dash.tick(s.now, s.pos, true)
    local body = payload(s.file('dashboard/hr_data.js'))
    json_check(body)
    for _, key in ipairs({'"wave":{"i":3,"n":6,"next_in":500,"next_min":30,"start":20}',
        '"reset_minutes":[0,15,20,30,40,45]', '"end_minute":55', '"starts_in":0', '"in_helltide":true',
        '"goal":{"cost":75,"label":"Random chest","ready":true}', '"region":"Kehjistan"',
        '"to_open":{"learned":0,"mystery":1,"regular":1}', '"activity":"Walking to chest"',
        '"movement":"Patrol road, then off-road"', '"maiden":[121,-747]', '"tears":[]', '"opened":[]'}) do
        ok(body:find(key, 1, true) ~= nil, 'has ' .. key)
    end
    local target = body:match('"target":(%b{})')
    ok(target ~= nil, 'target card')
    for _, key in ipairs({'"name":"Random chest"', '"cost":75', '"dist":50', '"source":"seen"', '"x":30', '"y":40',
        '"road":true', '"mystery":false'}) do
        ok(target:find(key, 1, true) ~= nil, 'target ' .. key)
    end
    -- the cinder goal: short of a Mystery target
    s.cinders = 100
    s.tracker.hr_get_remembered = function()
        return {k2 = {name = 'usz_rewardGizmo_Uber', cost = 250, position = v(-100, 0), predicted = true}}, 'k2'
    end
    s.advance(11); s.dash.tick(s.now, s.pos, true)
    body = payload(s.file('dashboard/hr_data.js'))
    ok(body:find('"goal":{"cost":250,"label":"Mystery","ready":false}', 1, true) ~= nil, 'Mystery goal not ready')
    ok(body:match('"target":(%b{})'):find('"source":"learned"', 1, true) ~= nil, 'a predicted chest is a learned target')
    -- after the Helltide: next one starts in 3 minutes; no target, the plain goal
    s.tracker.hr_get_remembered = nil
    s.tracker.hr_task_state = nil
    s.advance(11); s.at_minute(57)
    s.dash.tick(s.now, s.pos, false)
    body = payload(s.file('dashboard/hr_data.js'))
    json_check(body)
    ok(body:find('"starts_in":180', 1, true) ~= nil and body:find('"active":false', 1, true) ~= nil, 'between Helltides')
    ok(body:find('"target":', 1, true) == nil, 'no target')
    ok(body:find('"activity":"Idle"', 1, true) ~= nil, 'idle')
end)

R.case('opened this wave: position, age and wave; a reset boundary starts a new list', function()
    local s = full_session()
    s.at_minute(16)
    s.stats.on_chest_opened('usz_rewardGizmo_Uber', 250, v(377.4, -622.2))
    s.stats.on_chest_opened('usz_rewardGizmo_Gloves', 75, v(310, -659))
    s.stats.on_chest_opened('silent', 0, v(1, 1))            -- not a cinder chest
    eq(#s.stats.opened, 2, 'two chests recorded')
    s.dash.tick(s.now, s.pos, true)
    local body = payload(s.file('dashboard/hr_data.js'))
    local opened = body:match('"opened":(%b[])')
    ok(opened:find('{"cost":75,"name":"Gloves","t":' .. s.epoch .. ',"x":310,"y":-659}', 1, true) ~= nil, opened)
    ok(opened:find('"name":"Gloves"', 1, true) < opened:find('"name":"Mystery"', 1, true), 'newest first')
    ok(body:match('"opened_hour":(%b[])'):find('"wave":true', 1, true) ~= nil)
    s.at_minute(21)                                          -- the :20 reset
    s.advance(11); s.dash.tick(s.now, s.pos, true)
    body = payload(s.file('dashboard/hr_data.js'))
    ok(body:find('"opened":[]', 1, true) ~= nil, 'a new wave starts empty')
    local hour = body:match('"opened_hour":(%b[])')
    ok(hour:find('"wave":false', 1, true) ~= nil and hour:find('"name":"Mystery"', 1, true) ~= nil, 'the hour keeps them')
    for i = 1, 60 do s.stats.on_chest_opened('usz_rewardGizmo_Rings', 75, v(i, i)) end
    eq(#s.stats.opened, s.stats.OPENED_MAX, 'the ring is bounded')
    s.advance(11); s.dash.tick(s.now, s.pos, true)
    local _, n = payload(s.file('dashboard/hr_data.js')):match('"opened":(%b[])'):gsub('"name":', '')
    eq(n, s.dash.OPENED_MAX, 'the file lists at most OPENED_MAX of this wave')
end)

R.case('the patrol road: a downsampled polyline built once per zone, kept in every write', function()
    local s = full_session()
    for _ = 1, 5 do s.advance(11); s.dash.tick(s.now, s.pos, true) end
    eq(s.dash.road_builds, 1, 'built once for Kehj_Oasis')
    local body = payload(s.file('dashboard/hr_data.js'))
    local pts = body:match('"road":{"pts":(%b[]),"zone":"Kehj_Oasis"}')
    ok(pts ~= nil, 'road with its zone')
    local _, commas = pts:gsub(',', '')
    local n = (commas + 1) / 2
    ok(n >= 100 and n <= s.dash.ROAD_MAX, 'downsampled road points: ' .. n)
    ok(pts:find('^%[216,%-601,'), 'starts at the loop start (every Nth point from the first)')
    s.atlas.set_zone('Step_South')
    s.advance(11); s.dash.tick(s.now, s.pos, true)
    s.advance(11); s.dash.tick(s.now, s.pos, true)
    eq(s.dash.road_builds, 2, 'once more for the next zone')
    body = payload(s.file('dashboard/hr_data.js'))
    ok(body:find('"road":{"pts":[', 1, true) and body:find('"zone":"Step_South"}', 1, true), 'Step_South road')
    s.atlas.set_zone('Naha_Somewhere')                        -- no patrol loop
    s.advance(11); s.dash.tick(s.now, s.pos, true)
    ok(payload(s.file('dashboard/hr_data.js')):find('"road":{"pts":[],"zone":"Naha_Somewhere"}', 1, true) ~= nil, 'empty road')
end)

R.case('stats scopes, rupture anchors and a full map stay well under 300 KB', function()
    local s = full_session()
    s.at_minute(10)
    s.stats.tick(s.now, 0, true, 'Kehj_Oasis'); s.advance(0.3)
    s.stats.tick(s.now, 300, true, 'Kehj_Oasis')
    s.stats.on_chest_opened('usz_rewardGizmo_Uber', 250, v(1, 1)); s.stats.on_death()
    local sess = {anchor = v(500, 500), rupture_type = 'Pandemonium'}
    s.tracker.tear_event = {session = function() return sess end}
    for i = 1, 200 do s.atlas.observe(i % 7 == 0 and 'usz_rewardGizmo_Uber' or 'usz_rewardGizmo_Amulet', 125, v(i * 11, -i * 7), true) end
    s.fence.seed('Kehj_Oasis', (function()
        local wps = {}
        for i = 1, 4000 do wps[i] = v((i % 80) * 20, math.floor(i / 80) * 20) end
        return wps
    end)())
    for i = 1, 50 do s.stats.history[i] = {hour_id = H.HOUR - i * 3600, zone = 'Kehj_Oasis', earned = 900, spent = 800,
        lost = 0, chests = 9, mystery = 1, deaths = 0, secs = 3300} end
    for i = 1, 300 do s.pos = v(i, i); s.advance(5.1); s.dash.tick(s.now, s.pos, true) end
    sess = {anchor = v(900, 100), rupture_type = 'Pandemonium'}
    s.advance(11); s.dash.tick(s.now, s.pos, true)
    local text = s.file('dashboard/hr_data.js')
    ok(#text < 300 * 1024, 'full payload size ' .. #text)
    local body = payload(text)
    json_check(body)
    ok(body:find('"fence_in":[', 1, true) ~= nil, 'the full map fits')
    local tears = body:match('"tears":(%b[])')
    ok(tears:find('{"active":false,"type":"Pandemonium","x":500,"y":500}', 1, true) ~= nil, tears)
    ok(tears:find('{"active":true,"type":"Pandemonium","x":900,"y":100}', 1, true) ~= nil, tears)
    local sc = body:match('"session":(%b{})')
    ok(sc:find('"chests":1', 1, true) and sc:find('"mystery":1', 1, true) and sc:find('"deaths":1', 1, true)
        and sc:find('"earned":300', 1, true), sc)
    ok(body:match('"alltime":(%b{})'):find('"chests":1', 1, true) ~= nil)
    ok(body:match('"helltide":(%b{})'):find('"earned":300', 1, true) ~= nil)
end)

R.case('every theme page only reads fields the data file has (static check), and uses the new ones', function()
    local s = full_session()
    s.tracker.hr_chest_order = {last_plan = {reserve = 250, target_name = 'usz_rewardGizmo_Uber', target_pos = v(5, 5),
        target_key = 'k9', class = 0}}
    s.tracker.hr_cinder_run = {status = function() return {on = true, active = false, saving = true, threshold = 3000} end}
    s.tracker.tear_event = {session = function() return {anchor = v(50, 50)} end}
    s.stats.history[1] = {hour_id = H.HOUR - 3600, zone = 'Kehj_Oasis', earned = 1, spent = 1, lost = 0, chests = 1,
        mystery = 0, deaths = 0, secs = 60}
    s.pos = v(0, 0)
    s.dash.tick(s.now, s.pos, true)
    local body = payload(s.file('dashboard/hr_data.js'))
    json_check(body)
    local keys = decode_keys(body)
    ok(body:find('"goal":{"cost":3000,"label":"Cinder run","ready":false}', 1, true) ~= nil, 'saving: the run threshold is the goal')
    ok(body:find('"plan":"Saving cinders for the run at 3000"', 1, true) ~= nil, 'plan text')
    for _, name in ipairs(PAGES_MOVED and {} or THEMES) do
        local page = read_page(name)
        local used = {}
        for field in page:gmatch('[^%w_%.]d%.([%a_][%w_]*)') do used[field] = true end
        for field in page:gmatch('last%.([%a_][%w_]*)') do used[field] = true end
        local n = 0
        for field in pairs(used) do
            n = n + 1
            ok(keys[field], name .. ' reads d.' .. field .. ', which the data file has')
        end
        ok(n >= 20, name .. ': fields found in the page: ' .. n)
        for _, field in ipairs({'reset_minutes', 'end_minute', 'goal', 'target', 'now', 'opened', 'opened_hour', 'to_open',
            'road', 'tears', 'maiden', 'in_helltide', 'region', 'helltide', 'session', 'alltime', 'fence_in', 'fence_cell',
            'atlas', 'chests', 'trail', 'route', 'player', 'history', 'perf', 'events', 'rates', 'cinders'}) do
            ok(used[field], name .. ' uses d.' .. field)
        end
    end
end)

-- QQT_Warpigz_v3 (3.3.0): with WarRoom loaded (_G.QQT_WarRoom.dashboard_dir)
-- hr_data.js is written into WarRoom's dashboard folder, not HR's own.
-- 3.3.6: WarRoom is archived (not shipped); HR keeps this optional path so
-- it works again if WarRoom returns, and the cases below still cover it.
R.case('WarRoom present: hr_data.js goes to its dashboard_dir; absent: HR folder as before', function()
    local s = session({cinders = 180})
    s.set('dashboard', true)
    s.at_minute(12)
    s.pos = v(5, 5)
    eq(s.dash.warroom_path(), nil, 'no WarRoom: no WarRoom path')
    eq(s.dash.tick(s.now, s.pos, true), true, 'written without WarRoom')
    ok(s.file('dashboard/hr_data.js') ~= nil, 'HR folder without WarRoom')
    s.env.QQT_WarRoom = {dashboard_dir = '/mem/WarRoom/dashboard'}
    eq(s.dash.warroom_path(), '/mem/WarRoom/dashboard/hr_data.js', 'separator added')
    s.env.QQT_WarRoom = {dashboard_dir = 'C:\\QQT\\scripts\\WarRoom\\dashboard\\'}
    eq(s.dash.warroom_path(), 'C:\\QQT\\scripts\\WarRoom\\dashboard\\hr_data.js', 'Windows folder kept')
    s.env.QQT_WarRoom = {dashboard_dir = '/mem/WarRoom/dashboard/'}
    s.files['/mem/HelltideRevamped/dashboard/hr_data.js'] = nil
    s.advance(30)
    eq(s.dash.tick(s.now, s.pos, true), true, 'written with WarRoom')
    local text = s.files['/mem/WarRoom/dashboard/hr_data.js']
    ok(text ~= nil, 'hr_data.js in WarRoom/dashboard')
    json_check(payload(text or 'window.HR_DATA={};\n'))
    eq(s.file('dashboard/hr_data.js'), nil, 'HR folder not written while WarRoom is present')
    s.env.QQT_WarRoom = {dashboard_dir = 42}
    eq(s.dash.warroom_path(), nil, 'a bad dashboard_dir is ignored')
end)

-- QQT_Warpigz_v3 (3.3.0, review A5): with the 'Web dashboard' option OFF the
-- file is built only while WarRoom reports its Enable toggle as true (not
-- before WarRoom read it, not while it is switched off).
R.case('option off: hr_data.js only while WarRoom is enabled', function()
    local s = session({cinders = 180})
    s.set('dashboard', false)
    s.at_minute(12)
    s.pos = v(5, 5)
    eq(s.dash.tick(s.now, s.pos, true), false, 'option off, no WarRoom: nothing written')
    s.env.QQT_WarRoom = {dashboard_dir = '/mem/WarRoom/dashboard/'}
    s.advance(30)
    eq(s.dash.tick(s.now, s.pos, true), false, 'WarRoom toggle not read yet (enabled nil): nothing built')
    s.env.QQT_WarRoom.enabled = false
    s.advance(30)
    eq(s.dash.tick(s.now, s.pos, true), false, 'WarRoom switched off: nothing built')
    eq(s.files['/mem/WarRoom/dashboard/hr_data.js'], nil, 'no file while WarRoom is off')
    s.env.QQT_WarRoom.enabled = true
    s.advance(30)
    eq(s.dash.tick(s.now, s.pos, true), true, 'WarRoom enabled: written automatically')
    ok(s.files['/mem/WarRoom/dashboard/hr_data.js'] ~= nil, 'hr_data.js in WarRoom/dashboard')
end)

-- QQT_Warpigz_v3 3.3.6: WarRoom is archived, so the package never publishes
-- _G.QQT_WarRoom. With the 'Web dashboard' option off (the default) nothing
-- is built or written and nothing raises or logs a failure; the menu option's
-- tooltip does not point to WarRoom (it did up to 2.6.2) and the refresh
-- slider shows only with the option on. With the option on the file goes to
-- HelltideRevamped/dashboard/ as before.
R.case('3.3.6 package without WarRoom: nothing written, no error; the menu does not point to WarRoom', function()
    local s = session({cinders = 180})
    eq(rawget(s.env, 'QQT_WarRoom'), nil, 'no WarRoom in the package')
    eq(s.settings.dashboard, false, 'Web dashboard is off by default')
    eq(s.dash.warroom_on(), false, 'warroom_on() without WarRoom')
    eq(s.dash.warroom_path(), nil, 'warroom_path() without WarRoom')
    s.at_minute(12)
    for i = 1, 900 do
        s.advance(0.1)
        s.pos = v(i, 0)
        local passed, res = pcall(s.dash.tick, s.now, s.pos, i % 2 == 0)
        ok(passed, 'tick raised: ' .. tostring(res))
        eq(res, false, 'nothing written at tick ' .. i)
    end
    eq(#s.writes, 0, 'no file opened for writing')
    for path in pairs(s.files) do ok(not path:find('hr_data', 1, true), 'no data file: ' .. path) end
    eq(s.logged('dashboard data failed'), 0, 'no build error logged')
    local e = s.gui.elements
    local tip, slider = nil, 0
    e.dashboard.render = function(_, _, text) tip = text end
    e.dashboard_sec.render = function() slider = slider + 1 end
    s.gui.render()
    ok(type(tip) == 'string' and #tip > 0, 'the Web dashboard option is in the menu')
    ok(not tip:find('WarRoom', 1, true), 'its tooltip does not point to WarRoom: ' .. tostring(tip))
    eq(slider, 0, 'no refresh slider while the option is off')
    s.set('dashboard', true)
    s.gui.render()
    eq(slider, 1, 'the refresh slider with the option on')
    s.advance(30)
    eq(s.dash.tick(s.now, s.pos, true), true, 'option on: written')
    ok(s.file('dashboard/hr_data.js') ~= nil, 'into HelltideRevamped/dashboard/ (no WarRoom)')
    eq(rawget(s.env, 'QQT_WarRoom'), nil, 'HR never creates the WarRoom global')
end)

R.finish()
