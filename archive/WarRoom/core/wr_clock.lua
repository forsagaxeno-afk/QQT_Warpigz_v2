-- QQT_Warpigz_v3: WarRoom's wall clock. epoch() is os.time() (UTC seconds);
-- day_key() / day_start() use the LOCAL calendar of the bot PC, so "today"
-- rolls over at local midnight. Test hook: M._now = function() return t end.
local M = {_now = nil}

function M.epoch()
    if M._now then
        local ok, t = pcall(M._now)
        if ok and type(t) == 'number' then return t end
    end
    local ok, t = pcall(os.time)
    if ok and type(t) == 'number' then return t end
    return 0
end

-- 'YYYY-MM-DD' of the local day containing epoch t.
function M.day_key(t)
    local ok, key = pcall(os.date, '%Y-%m-%d', math.floor(t or M.epoch()))
    if ok and type(key) == 'string' then return key end
    return tostring(math.floor((t or 0) / 86400))
end

-- Epoch of the local midnight that starts the day containing t.
function M.day_start(t)
    t = math.floor(t or M.epoch())
    local ok, start = pcall(function()
        local d = os.date('*t', t)
        return os.time({year = d.year, month = d.month, day = d.day, hour = 0, min = 0, sec = 0, isdst = d.isdst})
    end)
    if ok and type(start) == 'number' and start <= t and t - start < 90000 then return start end
    return math.floor(t / 86400) * 86400
end

return M
