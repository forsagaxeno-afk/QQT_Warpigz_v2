-- QQT_Warpigz_v3: UTC clock for the Helltide hour.
--
-- Helltides run from minute 0 to minute 55 of every UTC hour. The old code
-- read the LOCAL minute (os.date("%M")), which is off by 30 minutes in a
-- half-hour time zone (UTC+5:30, +9:30, -3:30). Everything here reads UTC.
--
-- Chest resets: regular Helltide chests rotate at the UTC minutes in
-- RESET_MINUTES (helltides.com rotation timing; needs live confirmation).
-- A "slot" is the span between two reset minutes; slot_id() is unique per
-- hour and slot.
--
-- Test hook: M._now = function() return <UTC epoch seconds> end drives every
-- function below (minute, second and hour id from one clock).
local M = {
    RESET_MINUTES = {0, 15, 20, 30, 40, 45},
    END_MINUTE = 55,
    _now = nil,
}

local floor = math.floor

local function epoch()
    if M._now then
        local ok, t = pcall(M._now)
        if ok and type(t) == 'number' then return t end
    end
    local ok, t = pcall(os.time)
    if ok and type(t) == 'number' then return t end
    return 0
end
M.epoch = epoch

-- UTC minute (0-59) and second (0-59.x). os.date("!%M") is the primary
-- source; os.time() (seconds since the epoch, UTC on every platform) is the
-- fallback when os.date is unavailable.
local function min_sec()
    if M._now then
        local t = epoch()
        return floor(t / 60) % 60, t % 60
    end
    local okm, m = pcall(os.date, '!%M')
    local minute = okm and tonumber(m)
    if minute then
        local oks, s = pcall(os.date, '!%S')
        return minute, (oks and tonumber(s)) or 0
    end
    local t = epoch()
    return floor(t / 60) % 60, t % 60
end
M.min_sec = min_sec

function M.minute()
    local m = min_sec()
    return m
end

-- os.date("!*t") (UTC calendar table), or nil.
function M.utc()
    local ok, t = pcall(os.date, '!*t', M._now and epoch() or nil)
    if ok and type(t) == 'table' then return t end
    return nil
end

-- Start of the current UTC hour (epoch seconds): helltides.com's hour id.
function M.hour_id()
    return floor(epoch() / 3600) * 3600
end

-- Minutes (fractional) until the Helltide ends at minute 55; 0 after it.
function M.minutes_left()
    local m, s = min_sec()
    local left = M.END_MINUTE - (m + s / 60)
    if left < 0 then return 0 end
    return left
end

-- A Helltide is running (UTC minute below 55).
function M.active()
    local m = min_sec()
    return m < M.END_MINUTE
end

-- Legacy events are done before this UTC minute (default 45).
function M.events_ok(limit)
    local m = min_sec()
    return m < (tonumber(limit) or 45)
end

-- Index into RESET_MINUTES of the last reset boundary at or before now.
function M.reset_slot(minute)
    local m = minute or M.minute()
    local slot = 1
    for i, boundary in ipairs(M.RESET_MINUTES) do
        if m >= boundary then slot = i end
    end
    return slot
end

-- Unique per hour and slot (hour_id * 100 + slot).
function M.slot_id()
    return M.hour_id() * 100 + M.reset_slot()
end

-- True (and the new slot id) when a reset boundary was crossed since the
-- slot id `prev` was taken. nil `prev` is never a crossing.
function M.crossed_reset(prev)
    local now_id = M.slot_id()
    if prev == nil then return false, now_id end
    return now_id ~= prev, now_id
end

-- Seconds until the next reset boundary (the next hour's :00 after :45).
function M.next_reset_in()
    local m, s = min_sec()
    local at = m + s / 60
    for _, boundary in ipairs(M.RESET_MINUTES) do
        if boundary > at then return (boundary - at) * 60 end
    end
    return (60 - at) * 60
end

-- Seconds until the next Helltide starts (0 while one is running).
function M.starts_in()
    local m, s = min_sec()
    if m < M.END_MINUTE then return 0 end
    return (60 - (m + s / 60)) * 60
end

-- "12:34" for a number of seconds.
function M.mmss(seconds)
    seconds = tonumber(seconds) or 0
    if seconds ~= seconds or seconds < 0 then seconds = 0 end
    seconds = floor(seconds + 0.5)
    return string.format('%d:%02d', floor(seconds / 60), seconds % 60)
end

return M
