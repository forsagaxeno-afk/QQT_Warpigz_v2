-- QQT_Warpigz_v3: Helltide statistics (overlay, dashboard, status()).
--
-- The cinder balance is read four times a second while HelltideRevamped is
-- enabled (main.lua). A rise is "earned". A fall is "spent" (chests), except
-- a fall to 0 once the Helltide is over (minute 55, or within 10 minutes
-- after its end was seen while the balance carried over from that Helltide
-- is still held): that whole balance is "lost". A 0 reading that does not
-- last a second (loading, a host read glitch) is ignored.
-- QQT_Warpigz_v3: the end-of-Helltide grace ends as soon as the balance was
-- 0 inside a running Helltide (nothing carried over): a new Helltide's
-- chest that spends the balance to exactly 0 is "spent", not "lost".
--
-- Counters exist per Helltide (the current UTC hour), per session (since the
-- plugin loaded) and all time (learned/stats.txt). A Helltide record closes
-- when the hour changes or at minute 55 and goes into a history ring (50).
-- The earn rate is an EWMA over about five minutes of time spent inside a
-- Helltide (outside it the rate is frozen, so the next Helltide starts from
-- the farm's real pace); before any data it starts from the all-time rate.
-- QQT_Warpigz_v3: without an all-time seed, the first SEED_SECS of Helltide
-- time show the plain average (earned / time, never over less than
-- SEED_MIN seconds), so one early cinder pile does not read as 100+/min.
-- Files are written only while the plugin is enabled: every 5 minutes, at a
-- Helltide's close and when the plugin is switched off.
local clock = require "core.hr_clock"
local store = require "core.hr_store"

local M = {
    FILE = 'learned/stats.txt',
    SAVE_EVERY = 300,
    TICK_EVERY = 0.25,
    EWMA_WINDOW = 300,
    RATE_BUCKET = 15,
    HISTORY_MAX = 50,
    NOTES_MAX = 30,
    LOST_GRACE = 600,
    ZERO_CONFIRM = 1.0,
    SEED_SECS = 300,        -- QQT_Warpigz_v3: plain average before the EWMA
    SEED_MIN = 180,         -- QQT_Warpigz_v3: never averaged over less time
    MYSTERY = 'usz_rewardGizmo_Uber',
    OPENED_MAX = 40,        -- QQT_Warpigz_v3: opened-chest ring (overlay / dashboard)
}

local COUNTERS = {'earned', 'spent', 'lost', 'chests', 'mystery', 'silent', 'deaths', 'tears', 'secs', 'helltides'}
M.COUNTERS = COUNTERS

local function counters()
    local t = {}
    for _, k in ipairs(COUNTERS) do t[k] = 0 end
    return t
end

M.session = counters()
M.alltime = counters()
M.helltide = nil
M.history = {}
M.notes = {}
-- QQT_Warpigz_v3: the last OPENED_MAX chests opened this session, oldest
-- first: {name, cost, t (UTC epoch), slot (clock.slot_id), hour, x, y}.
M.opened = {}

local st = {}
local function fresh_state()
    st = {prev = nil, last_tick = nil, loaded = false, dirty = false, save_at = nil,
        end_seen_at = nil, rate = 0, rate_seeded = false, bucket = 0, bucket_t = nil,
        last_closed = nil, last_closed_at = nil, zero_since = nil, now = 0,
        seed_earned = 0, seed_secs = 0}
end
fresh_state()
M._state = function() return st end

local function clamp_count(v)
    if type(v) ~= 'number' or v ~= v or v < 0 then return 0 end
    if v > 1e12 then return 1e12 end
    return v
end

-- A console line that the dashboard lists too (last NOTES_MAX).
function M.note(msg)
    msg = tostring(msg)
    pcall(function() console.print(msg) end)
    local notes = M.notes
    notes[#notes + 1] = {t = clock.epoch(), msg = msg:sub(1, 200)}
    while #notes > M.NOTES_MAX do table.remove(notes, 1) end
end

local function add(key, v)
    if v == 0 then return end
    M.session[key] = M.session[key] + v
    M.alltime[key] = clamp_count(M.alltime[key] + v)
    if M.helltide then M.helltide[key] = M.helltide[key] + v end
    st.dirty = true
end

local function add_lost(amount)
    M.session.lost = M.session.lost + amount
    M.alltime.lost = clamp_count(M.alltime.lost + amount)
    local rec = M.helltide
    if not rec and st.last_closed and st.last_closed_at and st.now - st.last_closed_at <= M.LOST_GRACE then
        rec = st.last_closed
    end
    if rec then rec.lost = rec.lost + amount end
    st.dirty = true
end

-- ── persistence ──────────────────────────────────────────────────────────
local function record_line(h)
    return string.format('h|%d|%s|%d|%d|%d|%d|%d|%d|%d\n', h.hour_id or 0, tostring(h.zone or '?'),
        math.floor(h.earned), math.floor(h.spent), math.floor(h.lost), h.chests, h.mystery, h.deaths,
        math.floor(h.secs))
end

function M.load()
    st.loaded = true
    local lines, why = store.read_lines(M.FILE, 400)
    if not lines then
        -- Existing but unreadable (locked, too large): never overwritten.
        if why == 'unreadable' then st.read_failed = true end
        return false
    end
    local history = {}
    for _, line in ipairs(lines) do
        local key, value = line:match('^([%a_]+)=(%d+%.?%d*)$')
        if key and M.alltime[key] ~= nil then
            M.alltime[key] = clamp_count(tonumber(value))
        else
            local hour, zone, e, s, l, c, m, d, secs = line:match(
                '^h|(%d+)|([%w_%?]+)|(%d+)|(%d+)|(%d+)|(%d+)|(%d+)|(%d+)|(%d+)$')
            if hour then
                local h = counters()
                h.hour_id, h.zone = tonumber(hour), zone
                h.earned, h.spent, h.lost = tonumber(e), tonumber(s), tonumber(l)
                h.chests, h.mystery, h.deaths, h.secs = tonumber(c), tonumber(m), tonumber(d), tonumber(secs)
                history[#history + 1] = h
            end
        end
    end
    while #history > M.HISTORY_MAX do table.remove(history, 1) end
    M.history = history
    if not st.rate_seeded and M.alltime.secs >= 600 and M.alltime.earned > 0 then
        st.rate = M.alltime.earned / (M.alltime.secs / 60)
        st.rate_seeded = true
    end
    return true
end

function M.save(now)
    st.save_at = (now or st.now or 0) + M.SAVE_EVERY
    if st.read_failed then return false end
    local lines = {'v1\n'}
    for _, key in ipairs(COUNTERS) do
        lines[#lines + 1] = string.format('%s=%d\n', key, math.floor(M.alltime[key] + 0.5))
    end
    for _, h in ipairs(M.history) do lines[#lines + 1] = record_line(h) end
    local ok = store.write(M.FILE, lines)
    if ok then st.dirty = false end
    return ok
end

-- Switched off: save pending numbers and re-baseline the balance later
-- (cinders earned while HelltideRevamped is off are not counted).
function M.flush(now)
    if st.dirty and st.loaded then M.save(now) end
    M.suspend()
end

function M.suspend()
    st.prev, st.last_tick, st.zero_since, st.bucket_t, st.bucket = nil, nil, nil, nil, 0
end

-- ── Helltide records ─────────────────────────────────────────────────────
local function open_helltide(hour, zone)
    local h = counters()
    h.hour_id, h.zone = hour, zone or '?'
    M.helltide = h
end

function M.close_helltide(now)
    local h = M.helltide
    M.helltide = nil
    if not h then return nil end
    if h.secs < 30 and h.earned == 0 and h.chests == 0 then return nil end
    h.helltides = 1
    M.session.helltides = M.session.helltides + 1
    M.alltime.helltides = clamp_count(M.alltime.helltides + 1)
    M.history[#M.history + 1] = h
    while #M.history > M.HISTORY_MAX do table.remove(M.history, 1) end
    st.last_closed, st.last_closed_at = h, now
    st.dirty = true
    M.save(now)
    return h
end

-- ── rate ─────────────────────────────────────────────────────────────────
local function update_rate(now, in_helltide)
    if not in_helltide then
        st.bucket, st.bucket_t = 0, nil
        return
    end
    if not st.bucket_t then
        st.bucket_t = now
        return
    end
    local elapsed = now - st.bucket_t
    if elapsed < M.RATE_BUCKET then return end
    local inst = st.bucket / elapsed * 60
    if not st.rate_seeded then
        -- QQT_Warpigz_v3: the plain average until SEED_SECS of data exist.
        st.seed_earned = st.seed_earned + st.bucket
        st.seed_secs = st.seed_secs + elapsed
        st.rate = st.seed_earned / math.max(st.seed_secs, M.SEED_MIN) * 60
        if st.seed_secs >= M.SEED_SECS then st.rate_seeded = true end
    else
        local alpha = 1 - math.exp(-elapsed / M.EWMA_WINDOW)
        st.rate = st.rate + alpha * (inst - st.rate)
    end
    st.bucket, st.bucket_t = 0, now
end

function M.rate_min() return st.rate end
function M.rate_hr() return st.rate * 60 end

-- ── tick ─────────────────────────────────────────────────────────────────
-- now: get_time_since_inject(); cinders: current balance (nil: unreadable);
-- in_helltide: the Helltide buff; zone: learned-data zone key.
function M.tick(now, cinders, in_helltide, zone)
    st.now = now
    if not st.loaded then M.load() end
    if st.save_at == nil then st.save_at = now + M.SAVE_EVERY end
    local dt = 0
    if st.last_tick then
        dt = now - st.last_tick
        if dt < M.TICK_EVERY then return end
        if dt > 2 then dt = 2 elseif dt < 0 then dt = 0 end
    end
    st.last_tick = now

    local hour, active = clock.hour_id(), clock.active()
    if not active then
        st.end_seen_at = now
    elseif st.end_seen_at and st.prev == 0 and not st.zero_since then
        st.end_seen_at = nil -- QQT_Warpigz_v3: nothing carried over into this Helltide
    end
    if M.helltide and (M.helltide.hour_id ~= hour or not active) then M.close_helltide(now) end
    if not M.helltide and active and in_helltide then open_helltide(hour, zone) end
    if M.helltide and in_helltide and zone then M.helltide.zone = zone end
    if in_helltide and dt > 0 then add('secs', dt) end

    if type(cinders) == 'number' and cinders == cinders and cinders >= 0 then
        local prev = st.prev
        if prev == nil then
            st.prev = cinders
        elseif cinders == 0 and prev > 0 then
            -- a drop to 0 counts only when it lasts ZERO_CONFIRM seconds
            st.zero_since = st.zero_since or now
            if now - st.zero_since >= M.ZERO_CONFIRM then
                local over = not active or (st.end_seen_at ~= nil and now - st.end_seen_at <= M.LOST_GRACE)
                if over then
                    add_lost(prev)
                    if active then st.end_seen_at = nil end -- QQT_Warpigz_v3: the carried balance is gone
                else
                    add('spent', prev)
                end
                st.prev, st.zero_since = 0, nil
            end
        else
            st.zero_since = nil
            local d = cinders - prev
            if d > 0 then
                add('earned', d)
                if in_helltide then st.bucket = st.bucket + d end
            elseif d < 0 then
                add('spent', -d)
            end
            st.prev = cinders
        end
    end

    update_rate(now, in_helltide)
    if st.dirty and now >= st.save_at then M.save(now) end
end

-- ── events ───────────────────────────────────────────────────────────────
-- QQT_Warpigz_v3: `pos` (optional) records the chest in M.opened.
function M.on_chest_opened(name, cost, pos)
    if name == 'silent' then add('silent', 1) return end
    if type(cost) == 'number' and cost > 0 then add('chests', 1) end
    if name == M.MYSTERY then add('mystery', 1) end
    if type(cost) ~= 'number' or cost <= 0 then return end
    local x, y
    if pos ~= nil then
        local ok, px, py = pcall(function() return pos:x(), pos:y() end)
        if ok and type(px) == 'number' and type(py) == 'number' and px == px and py == py then x, y = px, py end
    end
    local list = M.opened
    list[#list + 1] = {name = tostring(name), cost = cost, t = clock.epoch(), slot = clock.slot_id(),
        hour = clock.hour_id(), x = x, y = y}
    while #list > M.OPENED_MAX do table.remove(list, 1) end
end

function M.on_death() add('deaths', 1) end
function M.on_tear_done() add('tears', 1) end

function M.reset_alltime()
    M.alltime = counters()
    M.history = {}
    st.last_closed, st.last_closed_at = nil, nil
    st.dirty = true
    st.read_failed = nil -- an explicit reset replaces even an unreadable file
    M.note('[HelltideRevamped] All-time Helltide stats reset')
    M.save(st.now)
end

-- Additive status() field (contract C2-style, read-only numbers).
function M.summary()
    return {
        cinders_per_min = math.floor(st.rate * 10 + 0.5) / 10,
        earned = math.floor(M.session.earned),
        spent = math.floor(M.session.spent),
        lost = math.floor(M.session.lost),
    }
end

-- Tests: forget everything (a fresh plugin load).
function M._reset()
    M.session, M.alltime, M.helltide, M.history, M.notes = counters(), counters(), nil, {}, {}
    M.opened = {} -- QQT_Warpigz_v3
    fresh_state()
end

return M
