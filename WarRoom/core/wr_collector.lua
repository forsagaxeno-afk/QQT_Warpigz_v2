-- QQT_Warpigz_v3: WarRoom's collector. tick() is called from on_update but
-- does real work at most once per POLL_EVERY seconds: drain the suite event
-- bus, poll the player / world (core/wr_host.lua), read the plugin statuses
-- (every STATUS_EVERY s), then write dashboard/suite_data.js every
-- `write_every` s and data/alltime.txt + data/today.txt every SAVE_EVERY s.
local events = require 'core.qqt_events'
local clock = require 'core.wr_clock'
local stats = require 'core.wr_stats'
local feed = require 'core.wr_feed'
local host = require 'core.wr_host'
local plugins = require 'core.wr_plugins'
local ingest = require 'core.wr_ingest'
local payload = require 'core.wr_payload'
local store = require 'core.wr_store'
local persist = require 'core.wr_persist'

local M = {POLL_EVERY = 1, STATUS_EVERY = 2, SAVE_EVERY = 60, MAX_EVENTS = 600,
    FILE = 'dashboard/suite_data.js', ALLTIME = 'data/alltime.txt', TODAY = 'data/today.txt',
    GOLD_JUMP = 1e11, GAP = 30}

local state

local function log(msg)
    pcall(function() console.print('[WarRoom] ' .. msg) end)
end

local function fresh_state(now)
    return {
        started = now, scopes = {session = stats.new_scope('session', now), today = stats.new_scope('today', now),
            alltime = stats.new_scope('alltime', now)},
        feed = feed.new(), open = {}, last_run = {}, counters = {}, reads = {}, flags = {no_xp = true, no_gold = true},
        cursor = 0, lost = 0, active = 0, act = 'idle', no_save = {}, snap = {},
    }
end

-- Load data/alltime.txt and data/today.txt (a file that exists but cannot
-- be read is never overwritten this session).
local function load(now)
    local lines, why = store.read_lines(M.ALLTIME, 20000)
    local data = lines and persist.decode(lines)
    if data then
        state.scopes.alltime = stats.restore_scope('alltime', data.scope, now)
        if type(data.drops) == 'table' then
            for i = math.min(#data.drops, feed.DROPS_MAX), 1, -1 do
                local d = data.drops[i]
                if type(d) == 'table' and type(d.t) == 'number' and type(d.name) == 'string' then
                    feed.drop(state.feed, {t = d.t, rarity = tostring(d.rarity or ''), name = d.name,
                        ga = tonumber(d.ga) or 0, power = tonumber(d.power), src = tostring(d.src or ''),
                        act = tostring(d.act or ''), fate = feed.fate_name(d.fate), sno = tonumber(d.sno),
                        ancestral = d.ancestral == true or nil})
                end
            end
        end
    elseif why == 'unreadable' or (lines and not data) then
        state.no_save[M.ALLTIME] = true
        log('data/alltime.txt could not be read: it is kept and not overwritten this session')
    end
    lines, why = store.read_lines(M.TODAY, 5000)
    data = lines and persist.decode(lines)
    if data and type(data.scope) == 'table' and data.scope.day == clock.day_key(now) then
        state.scopes.today = stats.restore_scope('today', data.scope, now)
    elseif why == 'unreadable' then
        state.no_save[M.TODAY] = true
    end
end

function M.init(opts)
    opts = opts or {}
    local now = clock.epoch()
    state = fresh_state(now)
    local bus = events.bus(true)
    state.cursor = bus and tonumber(bus.seq) or 0
    if opts.load ~= false then pcall(load, now) end
    return state
end

function M.state() return state end

function M.save(now)
    if state.no_save[M.ALLTIME] ~= true then
        local drops = {}
        for i = 1, #state.feed.drops do drops[i] = state.feed.drops[i] end
        store.write(M.ALLTIME, persist.encode({v = 1, scope = state.scopes.alltime, drops = drops}))
    end
    if state.no_save[M.TODAY] ~= true then
        store.write(M.TODAY, persist.encode({v = 1, scope = state.scopes.today}))
    end
    state.saved_at = now
end

-- Scope reset (menu buttons): 'session' | 'today' | 'alltime'.
function M.reset(which, now)
    now = now or clock.epoch()
    if which == 'session' then
        state.scopes.session = stats.new_scope('session', now)
        state.started, state.active = now, 0
        state.feed.timeline, state.feed.strip = {}, {}
    elseif which == 'today' then
        state.scopes.today = stats.new_scope('today', now)
    elseif which == 'alltime' then
        state.scopes.alltime = stats.new_scope('alltime', now)
        state.feed.drops = {}
    end
    state.dirty_save = true
end

local function drain(now)
    local bus = events.bus(true)
    if not bus or type(bus.ring) ~= 'table' then return 0 end
    local seq = tonumber(bus.seq) or 0
    if seq < state.cursor then state.cursor = 0 end -- the bus was replaced
    local first = state.cursor + 1
    local oldest = seq - (tonumber(bus.max) or events.MAX) + 1
    if first < oldest then
        state.lost = state.lost + (oldest - first)
        first = oldest
    end
    if seq - first + 1 > M.MAX_EVENTS then first = seq - M.MAX_EVENTS + 1 end
    local n = 0
    for i = first, seq do
        local ev = bus.ring[i]
        if ev then
            -- Counted at the collector's clock (an event is at most one poll old).
            local ok, err = pcall(ingest.handle, state, ev, now)
            if not ok and not state.ingest_logged then
                state.ingest_logged = true
                log('an event could not be counted: ' .. tostring(err))
            end
            n = n + 1
        end
    end
    state.cursor = seq
    return n
end
M.drain = drain

-- Gold, XP (level / paragon rollover), obols, deaths.
local function money_xp(snap, now)
    local prev = state.snap
    if snap.gold then
        state.flags.no_gold = false
        if prev.gold then
            local d = snap.gold - prev.gold
            if d > 0 and d < M.GOLD_JUMP then stats.add_total(state, 'gold', d, now)
            elseif d < 0 and -d < M.GOLD_JUMP then stats.add_total(state, 'gold_spent', -d, now) end
        end
    end
    if snap.obols and prev.obols and snap.obols > prev.obols then
        stats.add_total(state, 'obols', snap.obols - prev.obols, now)
    end
    if snap.xp then
        state.flags.no_xp = false
        M.xp_step(prev, snap, now)
    end
    if snap.dead and not prev.dead and snap.player then
        stats.add_total(state, 'deaths', 1, now)
        local run = state.open[state.act]
        local where = (run and run.label) or state.zone_label
        feed.timeline(state.feed, now, 'death', plugins.BY_ACT[state.act] or '', state.act,
            'Died' .. ((where and where ~= '') and (' in ' .. where) or ''))
    end
end

-- XP gained between two polls. A level or paragon step (or the bar going
-- back without one: an unread paragon level-up) counts the rest of the old
-- bar plus the new progress; a level going DOWN is another character.
function M.xp_step(prev, snap, now)
    if not prev.xp then return end
    local lvl, plvl = snap.level or 0, prev.level or 0
    local par, ppar = snap.paragon, prev.paragon
    if lvl < plvl or (par and ppar and par < ppar) then return end
    local gained
    local level_up = lvl > plvl
    local paragon_up = par ~= nil and ppar ~= nil and par > ppar
    if level_up or paragon_up or snap.xp < prev.xp then
        local rest = (prev.xp_need or 0) - prev.xp
        if rest < 0 then rest = 0 end
        gained = rest + math.max(snap.xp, 0)
        if level_up then
            stats.add_total(state, 'levels', lvl - plvl, now)
            feed.timeline(state.feed, now, 'level', '', state.act, 'Reached level ' .. math.floor(lvl))
        end
        if paragon_up then
            stats.add_total(state, 'paragon', par - ppar, now)
            feed.timeline(state.feed, now, 'level', '', state.act, 'Paragon ' .. math.floor(par))
        end
    else
        gained = snap.xp - prev.xp
    end
    -- A jump of many bars at once is a character switch or a bad read.
    local cap = math.max((prev.xp_need or 0) * 5, 1e12)
    if gained > 0 and gained < cap then stats.add_total(state, 'xp', gained, now) end
end

-- A Helltide visit (core/wr_ingest.lua end_visit): open while in the
-- Helltide, ended HELLTIDE_AWAY s after the bot left (a Rosie town trip in
-- between keeps it open however long it takes).
function M.helltide_visit(act, now)
    local run = state.open.helltide
    if act == 'helltide' then
        if not run then ingest.open(state, 'helltide', now, 'Helltide', false)
        else run.away = nil end
        return
    end
    if not run then return end
    if state.trip then run.away = now; return end -- a Rosie trip (up to 240 s) returns to the Helltide
    run.away = run.away or now
    if now - run.away >= ingest.HELLTIDE_AWAY then ingest.end_visit(state, now) end
end

-- A trip_start whose trip_end never came (Rosie reloaded / switched off
-- mid-trip) stops holding the 'town' activity after this long (Rosie's own
-- service limit is 240 s plus the travel).
M.TRIP_STALE = 900

local ACT_PLUGIN_ACTS = {pit = true, undercity = true, hordes = true, bosses = true, helltide = true}

-- The activity the bot is in now (strip + session.now).
local function infer(snap, now)
    local reads = state.reads
    if state.trip and now - (state.trip.start or now) > M.TRIP_STALE then state.trip = nil end
    if state.trip then return 'town' end
    local raven = reads.raven
    if raven and raven.enabled and raven.st and raven.st.running == true then return 'whispers' end
    local place = host.place_activity(snap)
    if place then return place end
    for _, p in ipairs(plugins.LIST) do
        local r = reads[p.key]
        if p.act and ACT_PLUGIN_ACTS[p.act] and r and r.enabled then return 'travel' end
    end
    if reads.warpigs and reads.warpigs.enabled then return 'travel' end
    return 'idle'
end

local function statuses(now)
    state.reads = plugins.read_all()
    local active = {}
    for _, c in ipairs(plugins.conditions(state.reads)) do
        active[c.key] = true
        local _, new = feed.alert(state.feed, c.key, now, c.level, c.plugin, c.code, c.text)
        if new and c.level ~= 'info' then feed.timeline(state.feed, now, 'alert', c.plugin, state.act, c.text) end
    end
    for _, a in ipairs(state.feed.alerts) do
        if not a.resolved and a.key:sub(1, 3) ~= 'ev:' and not active[a.key] then feed.resolve(state.feed, a.key, now) end
    end
    feed.prune(state.feed, now)
end

-- One poll: everything except the file writes.
function M.poll(now, t)
    local dt = state.last_epoch and (now - state.last_epoch) or 0
    -- A gap: the first poll after WarRoom was off, or polls 30 s+ apart (PC
    -- asleep, on_update stalled). The strip never paints it as an activity.
    local gap = state.last_epoch == nil or dt >= M.GAP
    state.last_epoch = now
    if dt > 0 and dt < 30 then stats.track(state, dt) end
    local today = state.scopes.today
    if today.day ~= clock.day_key(now) then
        state.scopes.today = stats.new_scope('today', now)
        state.dirty_save = true
    end
    drain(now)
    if not state.status_t or (t or now) - state.status_t >= M.STATUS_EVERY then
        state.status_t = t or now
        statuses(now)
    end
    local ok, snap = pcall(host.poll)
    if not ok or type(snap) ~= 'table' then snap = {} end
    money_xp(snap, now)
    state.snap = snap
    local act = infer(snap, now)
    M.helltide_visit(act, now)
    if act == 'pit' and state.open.pit then state.open.pit.entered = true end
    state.act = act
    state.zone_label = host.zone_label(snap, act)
    if act == 'helltide' and snap.zone then state.helltide_zone = state.zone_label:gsub('^Helltide · ', '') end
    feed.strip(state.feed, act, now, gap)
    if dt > 0 and dt < 30 and act ~= 'idle' and act ~= 'travel' then state.active = state.active + dt end
end

-- The file text (bounded to store.MAX_BYTES by trimming the lists).
function M.render(now)
    return payload.encode(state, now, store.MAX_BYTES)
end

-- QQT_Warpigz_v3 3.3.3 (WarRoom 1.0.3): a payload that cannot be built is
-- logged once per session (it was silent: the page just stopped updating).
function M.write(now)
    local text, err = M.render(now)
    if not text then
        if not state.render_logged then
            state.render_logged = true
            log('dashboard/suite_data.js could not be built: ' .. tostring(err))
        end
        return false, err
    end
    return store.write(M.FILE, {text})
end

-- opts: {enabled, write_every, reset = 'session'|'today'|'alltime'|nil}
function M.tick(t, opts)
    if not state then M.init() end
    opts = opts or {}
    local now = clock.epoch()
    -- A reset button (main.lua passes it for one frame only) is applied on the
    -- frame it comes, before the Enable and poll gates, and saved at once.
    if opts.reset then
        M.reset(opts.reset, now)
        state.write_t = nil
        if opts.enabled == false then
            state.dirty_save = false
            M.save(now)
        end
    end
    if opts.enabled == false then
        if state.enabled_before then
            state.enabled_before = false
            M.save(now)
        end
        local bus = events.bus(true)
        state.cursor = bus and tonumber(bus.seq) or state.cursor
        -- Nothing earned while off is counted: the next poll is a new baseline.
        state.last_epoch, state.snap = nil, {}
        return false
    end
    if not opts.reset and state.last_t and t - state.last_t < M.POLL_EVERY and t >= state.last_t then return false end
    state.last_t = t
    state.enabled_before = true
    M.poll(now, t)
    local every = tonumber(opts.write_every) or 15
    if every < 5 then every = 5 elseif every > 60 then every = 60 end
    state.write_every = every
    if not state.write_t or t - state.write_t >= every or t < state.write_t then
        state.write_t = t
        M.write(now)
    end
    if state.dirty_save or not state.save_t or t - state.save_t >= M.SAVE_EVERY or t < state.save_t then
        state.save_t, state.dirty_save = t, false
        M.save(now)
    end
    return true
end

return M
