-- QQT_Warpigz_v3: web dashboard data (core/hr_dashboard.lua, core/hr_json.lua):
-- the file is `window.HR_DATA=<valid JSON>;`, bounded to 256 KB (map layers
-- cut first), written at most every 'Dashboard update' seconds, and never
-- while the option is off. The shipped page reads it back. Runs under Lua
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

R.case('option off: zero writes; the page ships and reads the data file', function()
    local s = session()
    for _ = 1, 600 do s.advance(0.1); s.dash.tick(s.now, s.pos, true) end
    eq(#s.writes, 0, 'dashboard off')
    local f = assert(io.open(SUITE_ROOT .. '/HelltideRevamped/dashboard/index.html', 'r'))
    local page = f:read('*a'); f:close()
    ok(page:find("'hr_data.js?ts='", 1, true) ~= nil, 'reloads hr_data.js with a cache buster')
    ok(page:find('setInterval(load, 5000)', 1, true) ~= nil, 'every 5 s')
    ok(page:find('window.HR_DATA', 1, true) ~= nil)
    ok(page:find('http', 1, true) == nil or not page:find('src="http', 1, true), 'no external resources')
    ok(not page:find('<link', 1, true), 'no external stylesheet')
    for _, tab in ipairs({'data-tab="live"', 'data-tab="map"', 'data-tab="history"', 'data-tab="perf"'}) do
        ok(page:find(tab, 1, true) ~= nil, tab)
    end
    local keep = io.open(SUITE_ROOT .. '/HelltideRevamped/dashboard/.keep', 'r')
    ok(keep ~= nil, 'the dashboard folder ships'); keep:close()
    keep = io.open(SUITE_ROOT .. '/HelltideRevamped/learned/.keep', 'r')
    ok(keep ~= nil, 'the learned folder ships'); keep:close()
end)

R.finish()
