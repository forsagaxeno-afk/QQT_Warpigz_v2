-- ApiProbe (QQT_Warpigz_v3 diagnostics, not part of the release package).
-- Read-only helper: it never moves the character or changes a setting.
--  1. Lists the API tables other addons publish in _G (Navigator, Worldstone,
--     Butler, Scavenger, TristramLoop, ...): every function name and value.
--  2. Logs every call into the Navigator / Worldstone / Butler / Scavenger
--     APIs: which file called it, the arguments and what it returned.
--     A call repeated with the same arguments is logged once per 5 s.
--  3. Every 5 s reads Worldstone.get_status() (read-only) and logs all its
--     fields when they change: is there a running/enabled flag while
--     Worldstone is switched off in its menu? (QQT_Warpigz_v3 1.0.22: the
--     Rosie Scavenger mimic reads only the Worldstone global so far.)
-- Everything goes to the console and to ApiProbe\probe_log.txt.
-- Remove the folder when done.
local WATCH = {'navig', 'worldstone', 'butler', 'scavenger', 'tristram', 'loop'}
local WRAP = {'navig', 'worldstone', 'butler', 'scavenger'}
local SKIP = {ApiProbePlugin = true}
local seen, wrapped, last_line = {}, {}, {}
local probe = {busy = false, next_at = 0, last = nil} -- item 3
local file_path, lines_written = nil, 0

do
    local ok, dir = pcall(function()
        local found = package.searchpath and package.searchpath('main', package.path)
        return found and found:match('^(.*[/\\])')
    end)
    if ok and type(dir) == 'string' and dir:sub(1, 1) ~= '.' then file_path = dir .. 'probe_log.txt' end
end

local function out(text)
    console.print('[ApiProbe] ' .. text)
    if file_path and lines_written < 20000 then
        local f = io.open(file_path, 'a')
        if f then
            f:write(string.format('%.2f %s\n', get_time_since_inject(), text))
            f:close()
            lines_written = lines_written + 1
        end
    end
end

local function matches(name, list)
    local low = string.lower(name)
    for _, p in ipairs(list) do if low:find(p, 1, true) then return true end end
    return false
end

local function show(v, depth)
    local t = type(v)
    if t == 'string' then return string.format('%q', #v > 80 and v:sub(1, 80) .. '...' or v) end
    if t == 'number' or t == 'boolean' or t == 'nil' then return tostring(v) end
    if t == 'table' then
        local ok_x, x = pcall(function() return v.x and v:x() end)
        if ok_x and type(x) == 'number' then
            local ok_y, y = pcall(function() return v:y() end)
            return string.format('vec(%.1f,%.1f)', x, ok_y and y or 0)
        end
        if (depth or 0) >= 2 then return '{...}' end
        local parts, n = {}, 0
        for k, val in pairs(v) do
            n = n + 1
            if n > 12 then parts[#parts + 1] = '...'; break end
            parts[#parts + 1] = tostring(k) .. '=' .. show(val, (depth or 0) + 1)
        end
        return '{' .. table.concat(parts, ', ') .. '}'
    end
    if t == 'userdata' then
        local ok_x, x = pcall(function() return v:x() end)
        if ok_x and type(x) == 'number' then
            local ok_y, y = pcall(function() return v:y() end)
            return string.format('vec(%.1f,%.1f)', x, ok_y and y or 0)
        end
        local ok_n, n = pcall(function() return v:get_skin_name() end)
        if ok_n and n then return 'actor(' .. tostring(n) .. ')' end
    end
    return t
end

local function caller()
    local info = debug and debug.getinfo and debug.getinfo(3, 'Sl')
    if not info then return '?' end
    local src = tostring(info.short_src or info.source or '?')
    return (src:match('scripts[/\\](.*)$') or src) .. ':' .. tostring(info.currentline or '?')
end

local function list_api(name, tbl)
    local funcs, fields = {}, {}
    for k, v in pairs(tbl) do
        if type(v) == 'function' then funcs[#funcs + 1] = tostring(k)
        else fields[#fields + 1] = tostring(k) .. '=' .. show(v, 1) end
    end
    table.sort(funcs); table.sort(fields)
    out(string.format('API %s: %d functions: %s', name, #funcs, table.concat(funcs, ', ')))
    if #fields > 0 then out(string.format('API %s fields: %s', name, table.concat(fields, '; '))) end
    local mt = getmetatable(tbl)
    if type(mt) == 'table' and type(mt.__index) == 'table' then
        local more = {}
        for k, v in pairs(mt.__index) do if type(v) == 'function' then more[#more + 1] = tostring(k) end end
        table.sort(more)
        if #more > 0 then out(string.format('API %s (metatable): %s', name, table.concat(more, ', '))) end
    end
end

local function wrap(name, tbl)
    local count = 0
    local keys = {}
    for k, v in pairs(tbl) do if type(v) == 'function' then keys[#keys + 1] = k end end
    for _, k in ipairs(keys) do
        local fn = tbl[k]
        local label = name .. '.' .. tostring(k)
        local ok = pcall(function()
            tbl[k] = function(...)
                local args = {...}
                local shown = {}
                for i = 1, select('#', ...) do shown[i] = show(args[i], 0) end
                local results = {pcall(fn, ...)}
                local line = string.format('call %s(%s) from %s', label, table.concat(shown, ', '), caller())
                local ret = {}
                for i = 2, #results do ret[#ret + 1] = show(results[i], 0) end
                if not results[1] then ret = {'ERROR ' .. tostring(results[2])} end
                local key = line .. ' -> ' .. table.concat(ret, ', ')
                local now = get_time_since_inject()
                if not probe.busy and (not last_line[key] or now - last_line[key] >= 5) then
                    last_line[key] = now
                    out(key)
                end
                if not results[1] then error(results[2], 0) end
                return (table.unpack or unpack)(results, 2, #results)
            end
        end)
        if ok then count = count + 1 end
    end
    out(string.format('watching %d functions of %s', count, name))
end

-- Item 3: every field of Worldstone.get_status(), logged when it changes.
local function probe_worldstone(now)
    if now < probe.next_at then return end
    probe.next_at = now + 5
    local ws = rawget(_G, 'Worldstone')
    if type(ws) ~= 'table' or type(ws.get_status) ~= 'function' then return end
    probe.busy = true
    local ok, st = pcall(ws.get_status)
    probe.busy = false
    local line
    if not ok then line = 'ERROR ' .. tostring(st)
    elseif type(st) ~= 'table' then line = show(st, 0)
    else
        local parts = {}
        for k, v in pairs(st) do parts[#parts + 1] = tostring(k) .. '=' .. show(v, 1) end
        table.sort(parts)
        line = '{' .. table.concat(parts, ', ') .. '}'
    end
    if line ~= probe.last then probe.last = line; out('Worldstone.get_status() -> ' .. line) end
end

local next_scan = 0
on_update(function()
    local now = get_time_since_inject()
    probe_worldstone(now)
    if now < next_scan then return end
    next_scan = now + 1
    for name, v in pairs(_G) do
        if type(name) == 'string' and not SKIP[name] and type(v) == 'table' and not seen[v] and matches(name, WATCH) then
            seen[v] = true
            list_api(name, v)
            if matches(name, WRAP) and not wrapped[v] then wrapped[v] = true; wrap(name, v) end
        end
    end
end)
ApiProbePlugin = {version = '1.0'}
out('loaded; log file: ' .. tostring(file_path))
