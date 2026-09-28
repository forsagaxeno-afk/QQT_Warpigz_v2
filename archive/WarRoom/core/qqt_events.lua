-- QQT_Warpigz_v3: suite event bus (3.3.0). This file is byte-identical in
-- every QQT_Warpigz plugin (core/qqt_events.lua; Rosie:
-- rosie/private/qqt_events.lua) and audit/tests/test_qqt_events_bus.lua
-- checks that the copies match.
--
-- _G.QQT_Warpigz_events = {seq = <last seq>, ring = {[seq] = event}, max = 512,
--     on_emit = optional function(event)}
-- The collector (WarRoom) creates the bus at load with M.bus(true) and drains
-- the ring with its own seq cursor. Without a bus emit() returns at once: no
-- table, no global, no cost. An event is
-- {seq, t = get_time_since_inject(), epoch = os.time(), source, kind, ...}
-- plus the caller's scalar fields (string / finite number / boolean; strings
-- are cut at 200 bytes; tables, functions and userdata are dropped). emit()
-- never raises: everything runs under pcall.
local M = {}

local KEY, MAX, TEXT = 'QQT_Warpigz_events', 512, 200
local RESERVED = {seq = true, t = true, epoch = true, source = true, kind = true}
M.KEY, M.MAX = KEY, MAX

-- The bus table or nil. create = true makes it (collector side only).
function M.bus(create)
    local g = _G
    if type(g) ~= 'table' then return nil end
    local bus = rawget(g, KEY)
    if type(bus) == 'table' then return bus end
    if not create then return nil end
    bus = {seq = 0, ring = {}, max = MAX}
    rawset(g, KEY, bus)
    return bus
end

local function scalar(v)
    local tv = type(v)
    if tv == 'boolean' then return v end
    if tv == 'number' then
        if v ~= v or v == math.huge or v == -math.huge then return nil end
        return v
    end
    if tv == 'string' then
        if #v > TEXT then return v:sub(1, TEXT) end
        return v
    end
    return nil
end

local function push(source, kind, fields)
    local bus = M.bus(false)
    if not bus then return nil end
    if type(bus.ring) ~= 'table' then bus.ring = {} end
    local seq = (tonumber(bus.seq) or 0) + 1
    local event = {seq = seq, source = tostring(source), kind = tostring(kind)}
    local clock = rawget(_G, 'get_time_since_inject')
    if type(clock) == 'function' then
        local ok, t = pcall(clock)
        if ok and type(t) == 'number' then event.t = t end
    end
    local ok_os, epoch = pcall(function() return os.time() end)
    if ok_os and type(epoch) == 'number' then event.epoch = epoch end
    if type(fields) == 'table' then
        for k, v in pairs(fields) do
            if type(k) == 'string' and not RESERVED[k] then event[k] = scalar(v) end
        end
    end
    bus.ring[seq] = event
    bus.seq = seq
    local max = tonumber(bus.max) or MAX
    if max < 1 then max = MAX end
    bus.ring[seq - max] = nil
    if type(bus.on_emit) == 'function' then pcall(bus.on_emit, event) end
    return event
end

-- emit('arkham', 'pit_start', {level = 42}) -> the stored event, or nil.
function M.emit(source, kind, fields)
    local ok, event = pcall(push, source, kind, fields)
    if ok then return event end
    return nil
end

return M
