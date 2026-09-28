-- QQT_Warpigz_v3: WarRoom's counters. Three scopes share one shape:
--   session  since this plugin load (or the Reset session button),
--   today    since local midnight on this PC (rolls over by itself),
--   alltime  since the first run (or the Reset all-time button).
-- Every add goes to all three. hourly rows are clock hours (max 48) for
-- session / today and local days (max 30) for alltime.
local clock = require 'core.wr_clock'

local M = {
    ACTIVITIES = {'pit', 'helltide', 'undercity', 'hordes', 'bosses', 'whispers'},
    BEST_LABEL = {pit = 'Tier', helltide = 'Cinders', undercity = 'Floor', hordes = '', bosses = '', whispers = ''},
    TOTALS = {'gold', 'gold_spent', 'xp', 'levels', 'paragon', 'deaths', 'obols', 'materials', 'glyph_xp'},
    -- QQT_Warpigz_v3 3.3.3 (WarRoom 1.0.3): 'set' (QQT rarity 7, set charms)
    -- was counted as unique.
    RARITIES = {'mythic', 'unique', 'set', 'legendary', 'rare', 'magic', 'common'},
    FATES = {'salvaged', 'sold', 'stashed'},
    HOURLY_MAX = 48,
    DAILY_MAX = 30,
    EXTRA_MAX = 16,
    SCOPES = {'session', 'today', 'alltime'},
}

local function new_activity(name)
    return {runs = 0, ok = 0, failed = 0, time = 0, best = 0, best_label = M.BEST_LABEL[name] or '', extra = {}}
end

function M.new_scope(kind, now)
    local s = {kind = kind, since = now, tracked = 0, totals = {}, activities = {},
        items = {looted = 0, by_rarity = {}, greater_affix = {ga1 = 0, ga2 = 0, ga3 = 0}},
        hourly = {}}
    for _, k in ipairs(M.TOTALS) do s.totals[k] = 0 end
    for _, a in ipairs(M.ACTIVITIES) do s.activities[a] = new_activity(a) end
    for _, r in ipairs(M.RARITIES) do s.items.by_rarity[r] = 0 end
    for _, f in ipairs(M.FATES) do s.items[f] = 0 end
    if kind == 'today' then s.day = clock.day_key(now) end
    return s
end

local function n(v)
    if type(v) ~= 'number' or v ~= v or v == math.huge or v == -math.huge then return 0 end
    return v
end

-- Copy the numbers of a loaded (untrusted) scope onto a fresh one.
local function copy_numbers(dst, src, depth)
    if type(src) ~= 'table' or depth > 4 then return end
    for k, v in pairs(src) do
        if type(k) == 'string' then
            if type(v) == 'number' then dst[k] = n(v)
            elseif type(v) == 'string' and #v <= 64 then dst[k] = v
            elseif type(v) == 'table' then
                if type(dst[k]) ~= 'table' then dst[k] = {} end
                copy_numbers(dst[k], v, depth + 1)
            end
        end
    end
end

function M.restore_scope(kind, data, now)
    local s = M.new_scope(kind, now)
    if type(data) ~= 'table' then return s end
    s.since = type(data.since) == 'number' and data.since or now
    s.tracked = n(data.tracked)
    if type(data.day) == 'string' then s.day = data.day end
    copy_numbers(s.totals, data.totals, 1)
    copy_numbers(s.items, data.items, 1)
    if type(data.activities) == 'table' then
        for _, a in ipairs(M.ACTIVITIES) do
            copy_numbers(s.activities[a], data.activities[a], 1)
            -- The label is this version's, never a string from the file.
            s.activities[a].best_label = M.BEST_LABEL[a] or ''
        end
    end
    if type(data.hourly) == 'table' then
        local max = kind == 'alltime' and M.DAILY_MAX or M.HOURLY_MAX
        for i = 1, #data.hourly do
            local row = data.hourly[i]
            if type(row) == 'table' and type(row.t) == 'number' then
                local r = {t = row.t, gold = n(row.gold), xp = n(row.xp), items = n(row.items), act = {}}
                copy_numbers(r.act, row.act, 3)
                s.hourly[#s.hourly + 1] = r
            end
        end
        while #s.hourly > max do table.remove(s.hourly, 1) end
    end
    return s
end

-- The hourly / daily row of `now` in scope s (created on demand).
local function bucket(s, now)
    local t, max
    if s.kind == 'alltime' then
        t, max = clock.day_start(now), M.DAILY_MAX
    else
        -- Local clock hours (a half-hour time zone gets its own boundaries).
        local ds = clock.day_start(now)
        t, max = ds + math.floor((now - ds) / 3600) * 3600, M.HOURLY_MAX
    end
    local last = s.hourly[#s.hourly]
    if last and last.t == t then return last end
    if last and last.t > t then return last end -- clock went back: keep adding to the newest row
    local row = {t = t, gold = 0, xp = 0, items = 0, act = {}}
    s.hourly[#s.hourly + 1] = row
    while #s.hourly > max do table.remove(s.hourly, 1) end
    return row
end
M.bucket = bucket

-- The state holds scopes = {session=, today=, alltime=}.
local function each(state, fn, a, b, c, d)
    for _, name in ipairs(M.SCOPES) do
        local s = state.scopes[name]
        if s then fn(s, a, b, c, d) end
    end
end
M.each = each

local function add_total(s, key, amount, now)
    s.totals[key] = n(s.totals[key]) + amount
    if key == 'gold' or key == 'xp' then
        local row = bucket(s, now)
        row[key] = row[key] + amount
    end
end

function M.add_total(state, key, amount, now)
    amount = n(amount)
    if amount == 0 then return end
    each(state, add_total, key, amount, now)
end

-- 'common'..'mythic' from a pickup event (string or QQT rarity number).
function M.rarity(value, mythic)
    if mythic == true then return 'mythic' end
    if type(value) == 'number' then
        if value >= 8 then return 'mythic' end
        if value == 7 then return 'set' end
        if value >= 6 then return 'unique' end
        if value >= 5 then return 'legendary' end
        if value >= 3 then return 'rare' end
        if value >= 1 then return 'magic' end
        return 'common'
    end
    if type(value) == 'string' then
        local v = value:lower()
        for _, r in ipairs(M.RARITIES) do
            if v:find(r, 1, true) then return r end
        end
        if v:find('normal', 1, true) then return 'common' end
    end
    return 'common'
end

local function add_item(s, rarity, ga, now)
    local items = s.items
    items.looted = n(items.looted) + 1
    items.by_rarity[rarity] = n(items.by_rarity[rarity]) + 1
    if ga >= 1 then
        local key = 'ga' .. (ga >= 3 and 3 or ga)
        items.greater_affix[key] = n(items.greater_affix[key]) + 1
    end
    local row = bucket(s, now)
    row.items = row.items + 1
end

function M.add_item(state, rarity, ga, now)
    ga = math.floor(n(ga))
    each(state, add_item, rarity, ga, now)
end

local function add_fate(s, field, amount)
    s.items[field] = n(s.items[field]) + amount
end

function M.add_fate(state, field, amount)
    amount = n(amount)
    if amount <= 0 then return end
    each(state, add_fate, field, amount)
end

local function run_start(s, act)
    local a = s.activities[act]
    a.runs = a.runs + 1
end

function M.run_start(state, act)
    if not state.scopes.session.activities[act] then return end
    each(state, run_start, act)
end

-- info.counted: run_start counted the run (at info.start). A scope that
-- began after that (today at local midnight, a reset mid-run) never saw
-- the start, so the run is counted in that scope now.
local function run_end(s, act, info, now)
    local a = s.activities[act]
    if not info.counted or (type(info.start) == 'number' and info.start < n(s.since)) then a.runs = a.runs + 1 end
    if info.ok then a.ok = a.ok + 1 else a.failed = a.failed + 1 end
    a.time = a.time + n(info.secs)
    if info.ok and type(info.best) == 'number' and info.best > n(a.best) then a.best = info.best end
    local row = bucket(s, now)
    row.act[act] = n(row.act[act]) + 1
end

-- info = {ok, secs, best, counted, start}
function M.run_end(state, act, info, now)
    if not state.scopes.session.activities[act] then return end
    each(state, run_end, act, info, now)
end

local function extra_add(s, act, key, amount, sub)
    local extra = s.activities[act].extra
    if sub then
        local t = extra[key]
        if type(t) ~= 'table' then t = {}; extra[key] = t end
        if t[sub] == nil then
            local count = 0
            for _ in pairs(t) do count = count + 1 end
            if count >= M.EXTRA_MAX then return end
        end
        t[sub] = n(t[sub]) + amount
    else
        extra[key] = n(extra[key]) + amount
    end
end

-- extra.key += amount, or extra.key[sub] += amount (by_boss).
function M.extra_add(state, act, key, amount, sub)
    if not state.scopes.session.activities[act] then return end
    each(state, extra_add, act, key, n(amount), sub)
end

local function extra_max(s, act, key, value)
    local extra = s.activities[act].extra
    if value > n(extra[key]) then extra[key] = value end
end

function M.extra_max(state, act, key, value)
    if not state.scopes.session.activities[act] then return end
    each(state, extra_max, act, key, n(value))
end

local function best(s, act, value)
    local a = s.activities[act]
    if value > n(a.best) then a.best = value end
end

-- The best figure of an activity without a run (HelltideRevamped's hour record).
function M.best(state, act, value)
    if not state.scopes.session.activities[act] then return end
    value = n(value)
    if value > 0 then each(state, best, act, value) end
end

local function track(s, secs) s.tracked = n(s.tracked) + secs end
function M.track(state, secs)
    if secs > 0 and secs < 30 then each(state, track, secs) end
end

-- Payload view of a scope (the contract's block; kept = looted - fates).
function M.view(s, flags, json)
    local out = {totals = {}, rates = {}, activities = {}, items = {}, hourly = json.array({})}
    for _, k in ipairs(M.TOTALS) do out.totals[k] = n(s.totals[k]) end
    local hours = n(s.tracked) / 3600
    local rate = function(v) if hours < 1 / 60 then return 0 end return math.floor(v / hours + 0.5) end
    out.rates.gold_hr = rate(out.totals.gold)
    out.rates.xp_hr = rate(out.totals.xp)
    if flags.no_xp and out.totals.xp == 0 then out.totals.xp = json.raw('null'); out.rates.xp_hr = json.raw('null') end
    if flags.no_gold and out.totals.gold == 0 then
        out.totals.gold = json.raw('null'); out.rates.gold_hr = json.raw('null')
    end
    for _, name in ipairs(M.ACTIVITIES) do
        local a = s.activities[name]
        local done = a.ok + a.failed
        out.activities[name] = {runs = a.runs, ok = a.ok, failed = a.failed, time = math.floor(a.time + 0.5),
            avg_time = done > 0 and math.floor(a.time / done + 0.5) or 0, best = a.best,
            best_label = a.best_label ~= '' and a.best_label or (M.BEST_LABEL[name] or ''), extra = a.extra}
    end
    local items = s.items
    out.items.looted = n(items.looted)
    out.items.by_rarity = {}
    for _, r in ipairs(M.RARITIES) do out.items.by_rarity[r] = n(items.by_rarity[r]) end
    out.items.greater_affix = {ga1 = n(items.greater_affix.ga1), ga2 = n(items.greater_affix.ga2),
        ga3 = n(items.greater_affix.ga3)}
    local gone = 0
    for _, f in ipairs(M.FATES) do
        out.items[f] = n(items[f])
        gone = gone + out.items[f]
    end
    out.items.kept = math.max(0, out.items.looted - gone)
    for i = 1, #s.hourly do
        local row = s.hourly[i]
        out.hourly[#out.hourly + 1] = {t = row.t, gold = row.gold, xp = row.xp, items = row.items, act = row.act}
    end
    if s.kind == 'alltime' then out.since = s.since end
    return out
end

return M
