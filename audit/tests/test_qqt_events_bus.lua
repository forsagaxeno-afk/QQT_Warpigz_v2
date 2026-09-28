-- QQT_Warpigz_v3 (3.3.0): the suite event bus (core/qqt_events.lua in every
-- plugin, Rosie: rosie/private/qqt_events.lua).
--   * every copy is byte-identical: one per shipped plugin, 10 since 3.3.6
--     (WarRoom's copy is parked with it in archive/ and not checked);
--   * no shipped plugin creates the bus: WarRoom was its only creator, so
--     in the 3.3.6 package emit() is a no-op (the tests below create it);
--   * no bus -> emit() is a no-op that creates no global;
--   * bus(true) creates _G.QQT_Warpigz_events = {seq, ring, max = 512};
--   * an event is {seq, t, epoch, source, kind, ...scalar fields}: tables,
--     functions and non-finite numbers are dropped, long strings cut, the
--     reserved keys cannot be overwritten;
--   * the ring keeps the last `max` events; on_emit sees every event;
--   * emit() never raises (broken bus, failing clock, failing on_emit);
--   * every emit call in the runtime code uses a source.kind of the contract.
-- Runs under Lua 5.4 and LuaJIT.
local ROOT = assert(SUITE_ROOT, 'SUITE_ROOT is required')
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
    if passed then print('PASS qqt-events: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL qqt-events: ' .. name .. ': ' .. tostring(err)) end
end

local COPIES = {'ArkhamAsylum/core/qqt_events.lua', 'Batmobile/core/qqt_events.lua',
    'HelltideRevamped/core/qqt_events.lua', 'HordeDev/core/qqt_events.lua', 'Reaper/core/qqt_events.lua',
    'Rosie/rosie/private/qqt_events.lua', 'SilentRaven/silent_raven/qqt_events.lua', 'WarPigs/core/qqt_events.lua',
    'WarPug/core/qqt_events.lua', 'WonderCity/core/qqt_events.lua'}
-- QQT_Warpigz_v3 3.3.6: the shipped plugins (versions.json); each has one copy above.
local SHIPPED = {'ArkhamAsylum', 'Batmobile', 'HelltideRevamped', 'HordeDev', 'Reaper', 'Rosie', 'SilentRaven',
    'WarPigs', 'WarPug', 'WonderCity'}

local function read(rel)
    local f = io.open(ROOT .. '/' .. rel, 'rb')
    if not f then return nil end
    local text = f:read('*a'); f:close()
    return text
end

-- A fresh module in its own global table (the plugin's _G).
local function fresh(env_fields)
    local env = {}
    for _, k in ipairs({'type', 'tostring', 'tonumber', 'pairs', 'ipairs', 'pcall', 'rawget', 'rawset', 'math',
        'string', 'table', 'os', 'error'}) do env[k] = _G[k] end
    local now = 100
    env.get_time_since_inject = function() return now end
    for k, v in pairs(env_fields or {}) do env[k] = v end
    env._G = env
    local text = assert(read(COPIES[1]))
    local chunk
    if setfenv and loadstring then
        chunk = assert(loadstring(text, '=qqt_events'))
        setfenv(chunk, env)
    else
        chunk = assert(load(text, '=qqt_events', 't', env))
    end
    local M = chunk()
    return M, env, function(t) now = t end
end

case('every plugin ships the same file, byte for byte', function()
    local base = assert(read(COPIES[1]), COPIES[1])
    ok(#base > 500, 'the emitter is not empty')
    for _, rel in ipairs(COPIES) do
        local text = read(rel)
        ok(text ~= nil, rel .. ' is missing')
        eq(text, base, rel .. ' differs from ' .. COPIES[1])
    end
    ok(base:find('QQT_Warpigz_v3', 1, true) ~= nil, 'marked')
end)

case('the copies cover exactly the shipped plugins of versions.json', function()
    local manifest = assert(read('versions.json'), 'versions.json')
    local block = assert(manifest:match('"components"%s*:%s*(%b{})'), 'components block')
    local listed, n = {}, 0
    for name in block:gmatch('"([%w_]+)"%s*:') do listed[name] = true; n = n + 1 end
    eq(n, #SHIPPED, 'shipped plugins in versions.json')
    eq(#COPIES, #SHIPPED, 'one copy per shipped plugin')
    for i, dir in ipairs(SHIPPED) do
        ok(listed[dir], dir .. ' is a component of versions.json')
        eq(COPIES[i]:match('^[^/]+'), dir, 'copy ' .. i .. ' belongs to ' .. dir)
    end
    ok(not listed.WarRoom, 'WarRoom is not shipped (archived in 3.3.6)')
end)

case('no bus: emit is a no-op and creates no global', function()
    local M, env = fresh()
    eq(M.KEY, 'QQT_Warpigz_events'); eq(M.MAX, 512)
    eq(M.emit('arkham', 'pit_start', {level = 5}), nil, 'nothing stored')
    eq(rawget(env, 'QQT_Warpigz_events'), nil, 'no global created by an emitter')
    eq(M.bus(), nil, 'bus() without create does not create')
end)

case('bus(true) creates the ring; events carry seq, t, epoch, source, kind and scalar fields', function()
    local M, env, set_now = fresh()
    local bus = M.bus(true)
    eq(rawget(env, 'QQT_Warpigz_events'), bus, 'published at _G.QQT_Warpigz_events')
    eq(bus.seq, 0); eq(bus.max, 512); eq(type(bus.ring), 'table')
    eq(M.bus(true), bus, 'an existing bus is reused')
    set_now(123.5)
    local long = string.rep('x', 300)
    local e = M.emit('reaper', 'boss_killed', {boss = 'andariel', label = 'Andariel', tier = 'greater', secs = 42.5,
        ok = true, list = {1, 2}, fn = print, nan = 0 / 0, inf = math.huge, text = long,
        seq = 99, kind = 'forged', source = 'forged', t = -1, epoch = -1, [1] = 'positional'})
    ok(e ~= nil, 'stored')
    eq(bus.seq, 1); eq(bus.ring[1], e)
    eq(e.seq, 1); eq(e.t, 123.5); eq(type(e.epoch), 'number'); eq(e.source, 'reaper'); eq(e.kind, 'boss_killed')
    eq(e.boss, 'andariel'); eq(e.label, 'Andariel'); eq(e.tier, 'greater'); eq(e.secs, 42.5); eq(e.ok, true)
    eq(e.list, nil, 'tables dropped'); eq(e.fn, nil, 'functions dropped')
    eq(e.nan, nil, 'NaN dropped'); eq(e.inf, nil, 'infinity dropped')
    eq(#e.text, 200, 'long strings cut to 200 bytes')
    eq(e[1], nil, 'positional fields dropped')
    local e2 = M.emit('warpigs', 'turn_in_done')
    eq(e2.seq, 2, 'fields optional'); eq(e2.kind, 'turn_in_done')
    local e3 = M.emit('rosie', 'pickup', 'not a table')
    eq(e3.seq, 3, 'a non-table field argument is ignored')
end)

case('the ring keeps the last max events; on_emit sees every one', function()
    local M = fresh()
    local bus = M.bus(true)
    local seen = {}
    bus.on_emit = function(e) seen[#seen + 1] = e.seq end
    for i = 1, 600 do M.emit('warpug', 'plan_reroll', {n = i}) end
    eq(bus.seq, 600); eq(#seen, 600, 'on_emit per event')
    local n, low = 0, math.huge
    for seq in pairs(bus.ring) do n = n + 1; if seq < low then low = seq end end
    eq(n, 512, 'ring capped at 512'); eq(low, 89, 'the oldest 88 dropped')
    eq(bus.ring[600].n, 600)
    -- A collector draining with a cursor sees contiguous seqs.
    local cursor, got = 500, 0
    while bus.ring[cursor + 1] do cursor = cursor + 1; got = got + 1 end
    eq(got, 100); eq(cursor, bus.seq)
    -- A smaller max set by the collector applies from the next emit.
    bus.max = 10
    M.emit('warpug', 'plan_reroll', {n = 601})
    eq(bus.ring[601 - 10], nil, 'max honoured')
end)

case('emit never raises: broken bus, failing clock, failing on_emit, odd arguments', function()
    local M, env = fresh({get_time_since_inject = function() error('host clock gone') end})
    local bus = M.bus(true)
    bus.on_emit = function() error('collector bug') end
    local e = M.emit('helltide', 'death', {})
    ok(e ~= nil, 'stored despite the clock and on_emit'); eq(e.t, nil, 'no t without a clock')
    bus.ring = 'garbage'; bus.seq = 'x'; bus.max = -3
    e = M.emit('helltide', 'tear_done', {})
    ok(e ~= nil and e.seq == 1, 'a broken ring/seq is repaired'); eq(type(bus.ring), 'table')
    e = M.emit(nil, nil, nil)
    eq(e.source, 'nil'); eq(e.kind, 'nil')
    env.QQT_Warpigz_events = 'not a table'
    eq(M.emit('a', 'b', {}), nil, 'a non-table bus is ignored')
    eq(M.bus(), nil)
    local ok_call = pcall(M.emit, 'a', 'b', setmetatable({}, {__pairs = function() error('boom') end}))
    ok(ok_call, 'no raise from a hostile fields table')
    env.QQT_Warpigz_events = setmetatable({}, {__index = function() error('hostile bus') end,
        __newindex = function() error('hostile bus') end})
    ok(pcall(M.emit, 'a', 'b', {}), 'no raise from a hostile bus')
end)

-- Every emit call site in the runtime code names a source.kind of the
-- contract (scratchpad PLAN; the archived WarRoom collector read these).
local KINDS = {
    arkham = {'pit_start', 'pit_floor', 'pit_boss_killed', 'glyph_upgraded', 'glyph_upgrade_failed', 'pit_end'},
    wondercity = {'undercity_start', 'boss_killed', 'undercity_reward', 'undercity_end'},
    hordedev = {'horde_start', 'horde_pylon', 'horde_council', 'horde_chest', 'horde_chest_fault', 'horde_done', 'horde_fail'},
    reaper = {'boss_summoned', 'chest_opened', 'boss_killed', 'boss_skipped', 'run_end'},
    helltide = {'helltide_done', 'chest_opened', 'death', 'tear_done'},
    rosie = {'trip_start', 'trip_end', 'stashed', 'pickup'},
    silentraven = {'whisper_claim'},
    warpug = {'plan_created', 'plan_reroll', 'plan_halt'},
    warpigs = {'step_start', 'step_done', 'turn_in_done', 'plugin_enabled', 'plugin_disabled', 'plugin_finished'},
}
local HORDE_TRACKER = {horde_fail = true, horde_chest = true, horde_chest_fault = true, horde_pylon = true,
    horde_council = true}

-- 3.3.6: archive/ (parked WarRoom) and ROOT/.claude/ (local worktrees of
-- other sessions: old full checkouts) are not this tree's runtime code; an
-- old copy there could otherwise satisfy "emitted somewhere" for a lost call
-- site. Only ROOT's own .claude is pruned, so a suite run from inside such a
-- worktree still scans its files.
case('every emit call site uses a contract source.kind; every contract kind is emitted somewhere', function()
    local list = io.popen and io.popen('find "' .. ROOT .. '" -path "' .. ROOT .. '/.claude" -prune -o -name "*.lua"'
        .. ' -not -path "*/audit/*" -not -path "*/archive/*" -print')
    if not list then print('NOTE: io.popen unavailable — call-site scan skipped'); return end
    local allowed, used = {}, {}
    for source, kinds in pairs(KINDS) do
        for _, kind in ipairs(kinds) do allowed[source .. '.' .. kind] = true end
    end
    local sites = 0
    for path in list:lines() do
        local f = io.open(path, 'r')
        local text = f and f:read('*a') or ''
        if f then f:close() end
        for source, kind in text:gmatch("events%.emit%(%s*'([%w_]+)'%s*,%s*'([%w_]+)'") do
            sites = sites + 1
            ok(allowed[source .. '.' .. kind], path:sub(#ROOT + 2) .. ': unknown event ' .. source .. '.' .. kind)
            used[source .. '.' .. kind] = true
        end
        if path:find('/HordeDev/', 1, true) then
            for kind in text:gmatch("tracker%.emit%(%s*'([%w_]+)'") do
                sites = sites + 1
                ok(HORDE_TRACKER[kind], path:sub(#ROOT + 2) .. ': unknown HordeDev event ' .. kind)
                used['hordedev.' .. kind] = true
            end
        end
    end
    list:close()
    ok(sites >= 40, 'emit call sites found: ' .. sites)
    -- tracker.emit_start / emit_done (HordeDev) emit horde_start / horde_done.
    used['hordedev.horde_start'], used['hordedev.horde_done'] = true, true
    for key in pairs(allowed) do ok(used[key], 'contract event never emitted: ' .. key) end
end)

-- QQT_Warpigz_v3 3.3.6: WarRoom, the only collector, is archived. No shipped
-- plugin creates the bus or writes the global, so every emit() in the package
-- returns at once (the cases above create the bus themselves).
case('no shipped plugin creates the bus', function()
    local dirs = {}
    for _, dir in ipairs(SHIPPED) do dirs[#dirs + 1] = '"' .. ROOT .. '/' .. dir .. '"' end
    local list = io.popen and io.popen('find ' .. table.concat(dirs, ' ') .. ' -name "*.lua" -type f')
    if not list then print('NOTE: io.popen unavailable — creator scan skipped'); return end
    local files, bad = 0, {}
    for path in list:lines() do
        files = files + 1
        local f = io.open(path, 'r')
        local text = f and f:read('*a') or ''
        if f then f:close() end
        local n, emitter = 0, path:find('/qqt_events%.lua$') ~= nil
        if emitter then eq(text, read(COPIES[1]), path:sub(#ROOT + 2) .. ' is the shared emitter') end
        for line in (text .. '\n'):gmatch('([^\n]*)\n') do
            n = n + 1
            local code = line:gsub('%-%-.*$', '')
            local where = path:sub(#ROOT + 2) .. ':' .. n
            if code:find('bus%(%s*true%s*%)') then bad[#bad + 1] = where .. ': creates the bus: ' .. line end
            -- The emitter itself names the key (KEY) and only reads it without create.
            if not emitter and code:find('QQT_Warpigz_events', 1, true) then
                bad[#bad + 1] = where .. ': touches the bus global: ' .. line
            end
        end
    end
    list:close()
    ok(files > 100, 'runtime files scanned: ' .. files)
    eq(#bad, 0, 'bus creators / global writers in the package:\n' .. table.concat(bad, '\n'))
end)

print(string.format('QQT events bus: %d checks, %d failures', checks, #failures))
if #failures > 0 then error(table.concat(failures, '\n')) end
