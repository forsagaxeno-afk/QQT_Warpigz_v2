-- QQT_Warpigz_v3: opt-in live Helltide zone ('Live Helltide zone', default
-- off). Only the current Helltide REGION is read; there is no public source
-- of chest positions in world coordinates (see core/hr_atlas.lua).
--
-- Sources (both unofficial, no published API or rate limit):
--   0 helltides.com  Firebase node .../helltide.json
--                    {"endTime":..,"id":<hour epoch>,"startTime":..,"zone":"dry_steppes"}
--   1 diablo4.life   /api/trackers/list, "helltide" object (shape unverified;
--                    {} means no data). QQT_Warpigz_v3 (night review): live
--                    checks on 2026-09-27 got {} while a Helltide ran, so a
--                    "no data" answer switches to helltides.com for the hour.
-- Polite by construction: at most one request in flight, a User-Agent, no
-- personal data, every 60 s only in the first minutes of an hour while this
-- hour's zone is unknown, otherwise every 'Live poll (min)' minutes and only
-- while it is still unknown; errors back off 60/120/240 ... 900 s; nothing
-- in minutes 55-59. With the option off, without the host's curl API, or
-- when the source fails, search works exactly as before.
local clock = require "core.hr_clock"
local enums = require "data.enums"
local settings = require "core.settings"

local M = {
    URLS = {
        [0] = 'https://helltides-7e530-default-rtdb.firebaseio.com/helltide.json',
        [1] = 'https://diablo4.life/api/trackers/list',
    },
    HEADERS = {Accept = 'application/json', ['User-Agent'] = 'QQT-HelltideRevamped/3.0'},
    TIMEOUT = 8,
    FAST_POLL = 60,
    EARLY_MINUTES = 5,
    BACKOFF_MIN = 60,
    BACKOFF_MAX = 900,
    MAX_BODY = 8192,
    ZONES = {
        fractured_peaks = true, scosglen = true, dry_steppes = true, hawezar = true,
        kehjistan = true, nahantu = true, skovos = true,
    },
}

local st
local function fresh()
    st = {in_flight = false, sent_at = nil, next_at = nil, backoff = 0, record = nil, refuted = {},
        requests = 0, last_error = nil, logged = {}, gen = 0}
end
fresh()

local function note(msg)
    pcall(function() console.print('[HelltideRevamped] ' .. msg) end)
end

local function log_once(key, msg)
    if st.logged[key] then return end
    st.logged[key] = true
    note(msg)
end

-- The host's curl API (async http_get), or nil.
function M.api()
    local c = curl
    if type(c) == 'table' and type(c.http_get) == 'function' then return c end
    return nil
end

function M.available() return M.api() ~= nil end

local function tp_for(zone_id)
    for _, tp in ipairs(enums.helltide_tps) do
        if tp.live_id == zone_id then return tp end
    end
    return nil
end

-- Maps a free-form diablo4.life zone string to a helltides.com zone id.
local function zone_id_from_text(text)
    text = tostring(text or ''):lower()
    if M.ZONES[text] then return text end
    if text:find('steppe', 1, true) then return 'dry_steppes' end
    if text:find('peak', 1, true) then return 'fractured_peaks' end
    if text:find('scosglen', 1, true) then return 'scosglen' end
    if text:find('kehj', 1, true) then return 'kehjistan' end
    if text:find('hawezar', 1, true) then return 'hawezar' end
    if text:find('nahantu', 1, true) then return 'nahantu' end
    if text:find('skovos', 1, true) then return 'skovos' end
    return nil
end

-- Parses a response body: zone id, hour id (or nil when the source has none).
function M.parse(body, source)
    if type(body) ~= 'string' or #body == 0 or #body > M.MAX_BODY then return nil, nil, 'empty or too large' end
    if (source or 0) == 1 then
        local obj = body:match('"helltide"%s*:%s*(%b{})')
        if not obj or obj:match('^{%s*}$') then return nil, nil, 'no data' end
        local text = obj:match('"zone"%s*:%s*"([^"]*)"') or obj:match('"location"%s*:%s*"([^"]*)"')
            or obj:match('"name"%s*:%s*"([^"]*)"')
        local zone = zone_id_from_text(text)
        if not zone then return nil, nil, 'unknown zone ' .. tostring(text) end
        return zone, nil
    end
    local zone = body:match('"zone"%s*:%s*"([%w_]+)"')
    local id = tonumber(body:match('"id"%s*:%s*(%d+)'))
    if not zone or not id then return nil, nil, 'unexpected body' end
    if not M.ZONES[zone] then return nil, nil, 'unknown zone ' .. zone end
    return zone, id
end

-- After an answer (with or without this hour's zone).
local function schedule_next(now)
    st.backoff = 0
    local minute = clock.minute()
    if st.record and st.record.hour_id == clock.hour_id() and not st.record.tentative then
        -- The region does not change within the hour: look again next hour.
        st.next_at = now + (60 - minute) * 60 + 5
    elseif minute < M.EARLY_MINUTES then
        st.next_at = now + M.FAST_POLL
    else
        local poll = tonumber(settings.live_poll_min) or 5
        if poll ~= poll then poll = 5 end
        st.next_at = now + math.max(2, math.min(15, poll)) * 60
    end
end

local function schedule_after_error(now, why)
    st.last_error = tostring(why)
    if st.backoff <= 0 then st.backoff = M.BACKOFF_MIN else st.backoff = math.min(M.BACKOFF_MAX, st.backoff * 2) end
    st.next_at = now + st.backoff
end

local function on_response(gen, source, now_fn, body, status, err)
    if gen ~= st.gen then return end -- a reset or a newer request made this one stale
    st.in_flight = false
    local now = now_fn()
    if (err ~= nil and err ~= '') or status ~= 200 then
        schedule_after_error(now, (err ~= nil and err ~= '') and err or ('HTTP ' .. tostring(status)))
        log_once('err:' .. tostring(status), string.format('live Helltide zone: request failed (%s) — retrying later',
            tostring(st.last_error)))
        return
    end
    local zone, id, why = M.parse(body, source)
    local hour = clock.hour_id()
    if not zone then
        if why == 'no data' then
            schedule_next(now) -- an empty tracker is an answer, not an error
            if source == 1 then
                -- QQT_Warpigz_v3: diablo4.life has no Helltide zone: ask
                -- helltides.com at once, for the rest of this hour.
                st.fallback_hour, st.next_at = clock.hour_id(), nil
                log_once('d4l-empty:' .. clock.hour_id(),
                    'live Helltide zone: diablo4.life has no Helltide data — asking helltides.com this hour')
            end
        else
            schedule_after_error(now, why)
            log_once('parse:' .. tostring(why), 'live Helltide zone: ' .. tostring(why))
        end
        return
    end
    if id ~= nil and id ~= hour then
        -- Stale (the source has not switched to this hour yet) or a clock
        -- mismatch: never acted on; asked again on the usual schedule.
        st.record = nil
        schedule_next(now)
        return
    end
    local tp = tp_for(zone)
    -- A source without an hour id (diablo4.life) may still show last hour's
    -- region in the first minutes: tentative, asked again until minute 5.
    st.record = {hour_id = hour, zone = zone, tp = tp, at = now,
        tentative = id == nil and clock.minute() < M.EARLY_MINUTES}
    if not tp then
        log_once('noloop:' .. zone .. ':' .. hour, string.format(
            'live Helltide zone: %s has no patrol loop here — searching the usual way', zone))
    else
        log_once('zone:' .. hour, string.format('live Helltide zone: %s (%s)', zone, tp.name))
    end
    schedule_next(now)
end

-- main.lua, every tick while the plugin is enabled.
function M.tick(now)
    if settings.live_api ~= true then return false end
    if st.in_flight then
        if st.sent_at and now - st.sent_at > M.TIMEOUT + 10 then
            -- The callback never came: count it as an error, drop the request.
            st.in_flight, st.gen = false, st.gen + 1
            schedule_after_error(now, 'no answer')
        end
        return false
    end
    if not clock.active() then return false end
    local hour = clock.hour_id()
    local rec = st.record
    if rec and rec.hour_id == hour and not (rec.tentative and clock.minute() < M.EARLY_MINUTES) then return false end
    if st.hour ~= hour then
        -- A new hour: ask at once (the schedule of the last hour is void;
        -- a running error backoff keeps its length for the next failure).
        st.hour, st.next_at = hour, nil
    end
    if st.next_at and now < st.next_at then return false end
    local api = M.api()
    if not api then
        log_once('nocurl', 'live Helltide zone: this QQT build has no curl API — option ignored')
        return false
    end
    local source = tonumber(settings.live_source) or 0
    if source ~= 1 or st.fallback_hour == hour then source = 0 end -- QQT_Warpigz_v3
    st.gen = st.gen + 1
    local gen = st.gen
    local now_fn = function()
        local ok, t = pcall(get_time_since_inject)
        return ok and type(t) == 'number' and t or now
    end
    local ok, queued = pcall(api.http_get, M.URLS[source], function(body, status, err)
        local okc, cerr = pcall(on_response, gen, source, now_fn, body, status, err)
        if not okc then
            st.in_flight = false
            schedule_after_error(now_fn(), cerr)
        end
    end, M.HEADERS, M.TIMEOUT)
    st.requests = st.requests + 1
    if not ok or queued == false then
        schedule_after_error(now, ok and 'not queued' or queued)
        return false
    end
    st.in_flight, st.sent_at = true, now
    return true
end

-- The helltide_tps entry of this hour's live zone, or nil when unknown,
-- stale, without a patrol loop, refuted or the option is off.
function M.zone_tp()
    if settings.live_api ~= true then return nil end
    local rec = st.record
    local hour = clock.hour_id()
    if not rec or rec.hour_id ~= hour or not clock.active() then return nil end
    local refuted = st.refuted[hour]
    if refuted and refuted[rec.zone] then return nil end
    return rec.tp
end

-- True while this hour's first answer is on its way (at most WAIT_S): the
-- search holds its town cycle that long instead of teleporting a moment early.
M.WAIT_S = 5
function M.waiting(now)
    if settings.live_api ~= true or not st.in_flight or not st.sent_at then return false end
    if st.record and st.record.hour_id == clock.hour_id() then return false end
    now = now or st.sent_at
    return now - st.sent_at < M.WAIT_S and now >= st.sent_at
end

function M.zone_name()
    local rec = st.record
    if not rec or rec.hour_id ~= clock.hour_id() then return nil end
    return rec.zone
end

-- True when the live record names the zone key the player is in.
function M.matches_zone(zone_key)
    local tp = M.zone_tp()
    return tp ~= nil and zone_key ~= nil and tp.name == zone_key
end

-- The arrival showed no Helltide buff: that zone is ignored for this hour
-- (another answer this hour, e.g. a corrected tentative one, still counts).
function M.refute(hour_id, zone)
    hour_id = hour_id or clock.hour_id()
    zone = zone or (st.record and st.record.zone) or '?'
    local refuted = st.refuted[hour_id] or {}
    st.refuted[hour_id] = refuted
    if refuted[zone] then return end
    refuted[zone] = true
    note(string.format('live Helltide zone %s not confirmed on arrival — searching the usual way this hour', tostring(zone)))
    -- A tentative source may correct itself: ask again soon.
    if st.record and st.record.tentative then st.next_at = nil end
end

function M.state() return st end
function M._reset() fresh() end

return M
