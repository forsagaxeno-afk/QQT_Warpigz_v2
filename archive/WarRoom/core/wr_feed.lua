-- QQT_Warpigz_v3: WarRoom's lists: timeline (newest first, max 300), notable
-- drops (newest first, max 200), the session strip (contiguous activity
-- blocks, max 200) and alerts (max 50; a resolved one is kept 1 h).
local M = {TIMELINE_MAX = 300, DROPS_MAX = 200, STRIP_MAX = 200, ALERTS_MAX = 50,
    ALERT_KEEP = 3600, ALERT_STALE = 12 * 3600, TEXT_MAX = 160, NAMES_MAX = 200}

local function cut(text)
    text = tostring(text or '')
    if #text > M.TEXT_MAX then return text:sub(1, M.TEXT_MAX) end
    return text
end
M.cut = cut

function M.new()
    return {timeline = {}, drops = {}, strip = {}, alerts = {}, names = {}, name_order = {}}
end

local function push_front(list, item, max)
    table.insert(list, 1, item)
    while #list > max do list[#list] = nil end
end

function M.timeline(feed, t, kind, plugin, act, text, dur)
    local row = {t = t, kind = kind, plugin = plugin, act = act, text = cut(text)}
    if type(dur) == 'number' and dur == dur and dur >= 0 and dur < 1e7 then row.dur = math.floor(dur + 0.5) end
    push_front(feed.timeline, row, M.TIMELINE_MAX)
    return row
end

-- Remember the rarity of a picked up item (for a later 'stashed'), by name
-- and, when known, by SNO ('#<sno>': Rosie's stash reports the internal name).
local function remember_key(feed, key, entry)
    if feed.names[key] == nil then
        feed.name_order[#feed.name_order + 1] = key
        if #feed.name_order > M.NAMES_MAX then
            feed.names[table.remove(feed.name_order, 1)] = nil
        end
    end
    feed.names[key] = entry
end
function M.remember(feed, name, rarity, ga, sno)
    local entry = {rarity = rarity, ga = ga, name = name}
    remember_key(feed, name, entry)
    if type(sno) == 'number' then remember_key(feed, '#' .. sno, entry) end
end

function M.drop(feed, d)
    d.name = cut(d.name)
    push_front(feed.drops, d, M.DROPS_MAX)
    return d
end

-- A drop's fate until Rosie reports it: 'picked up'. Rosie's town trip
-- reports only counts of salvaged / sold items, so a drop is never called
-- 'kept' (it may have been salvaged or sold since); only 'stashed' is per item.
M.PICKED = 'picked up'
-- The fate of a loaded drop (files before 3.3.0 said 'kept').
function M.fate_name(v)
    if type(v) ~= 'string' or v == '' or v == 'kept' then return M.PICKED end
    return (v:sub(1, 16))
end

-- The newest drop called `name` still 'picked up' becomes `fate`.
function M.fate(feed, name, fate)
    for i = 1, #feed.drops do
        local d = feed.drops[i]
        if d.name == name and d.fate == M.PICKED then
            d.fate = fate
            return d
        end
    end
    return nil
end

-- The newest 'picked up' drop with this SNO becomes `fate`.
function M.fate_sno(feed, sno, fate)
    for i = 1, #feed.drops do
        local d = feed.drops[i]
        if d.sno == sno and d.fate == M.PICKED then
            d.fate = fate
            return d
        end
    end
    return nil
end

-- The strip's current block is `act` up to now. gap: nothing was recorded
-- since the last poll (WarRoom off, PC asleep): the last block keeps its end
-- and a new block starts now, so the gap stays empty on the page.
function M.strip(feed, act, now, gap)
    local last = feed.strip[#feed.strip]
    if last and last.a == act and not gap then
        if now > last.e then last.e = now end
        return last
    end
    if last and now > last.e and not gap then last.e = now end
    local block = {a = act, s = (last and not gap) and last.e or now, e = now}
    feed.strip[#feed.strip + 1] = block
    while #feed.strip > M.STRIP_MAX do table.remove(feed.strip, 1) end
    return block
end

-- Raise (or refresh) the alert `key`. Returns the alert and true when new.
function M.alert(feed, key, now, level, plugin, code, text)
    for _, a in ipairs(feed.alerts) do
        if a.key == key and not a.resolved then
            a.text, a.level = cut(text), level
            return a, false
        end
    end
    local a = {key = key, t = now, level = level, plugin = plugin, code = code, text = cut(text), resolved = false}
    push_front(feed.alerts, a, M.ALERTS_MAX)
    return a, true
end

function M.resolve(feed, key, now)
    for _, a in ipairs(feed.alerts) do
        if a.key == key and not a.resolved then a.resolved, a.rt = true, now end
    end
end

-- Resolve every open alert whose key starts with prefix.
function M.resolve_prefix(feed, prefix, now)
    for _, a in ipairs(feed.alerts) do
        if not a.resolved and a.key:sub(1, #prefix) == prefix then a.resolved, a.rt = true, now end
    end
end

-- Open alerts whose key starts with prefix (a set of keys).
function M.open_keys(feed, prefix)
    local out = {}
    for _, a in ipairs(feed.alerts) do
        if not a.resolved and a.key:sub(1, #prefix) == prefix then out[a.key] = true end
    end
    return out
end

function M.prune(feed, now)
    local keep = {}
    for _, a in ipairs(feed.alerts) do
        local drop = (a.resolved and now - (a.rt or a.t) > M.ALERT_KEEP)
            or (not a.resolved and now - a.t > M.ALERT_STALE)
        if not drop then keep[#keep + 1] = a end
    end
    feed.alerts = keep
end

-- Payload copies (internal keys removed).
function M.alerts_view(feed)
    local out = {}
    for _, a in ipairs(feed.alerts) do
        out[#out + 1] = {t = a.t, level = a.level, plugin = a.plugin, code = a.code, text = a.text,
            resolved = a.resolved == true}
    end
    return out
end

-- The worst open alert level of a plugin ('error' | 'warn' | 'info' | nil).
function M.worst(feed, plugin)
    local rank, worst = {info = 1, warn = 2, error = 3}, nil
    for _, a in ipairs(feed.alerts) do
        if not a.resolved and a.plugin == plugin and (worst == nil or rank[a.level] > rank[worst]) then
            worst = a.level
        end
    end
    return worst
end

return M
