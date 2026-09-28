-- QQT_Warpigz_v3: builds window.SUITE_DATA (the dashboard contract, schema
-- v1) from the collector state. encode() keeps the file under max_bytes by
-- halving the lists (timeline, drops, strip, hourly rows) until it fits.
local json = require 'core.wr_json'
local stats = require 'core.wr_stats'
local feed = require 'core.wr_feed'
local plugins = require 'core.wr_plugins'
local ingest = require 'core.wr_ingest'

-- QQT_Warpigz_v3 3.3.4 (WarRoom 1.0.4): shows suite version 3.3.4.
local M = {SCHEMA = 1, SUITE = '3.3.4', PREFIX = 'window.SUITE_DATA = ', NULL = json.raw('null')}

local comma = ingest.comma

local function head(list, max)
    local out = json.array({})
    for i = 1, math.min(#list, max) do out[i] = list[i] end
    return out
end

local function tail(list, max)
    local out = json.array({})
    local first = math.max(1, #list - max + 1)
    for i = first, #list do out[#out + 1] = list[i] end
    return out
end

local function scope_view(state, name, lim)
    local v = stats.view(state.scopes[name], state.flags, json)
    v.hourly = tail(v.hourly, lim.hourly)
    return v
end

-- session.now: what the bot does right now.
local function now_block(state, now)
    local act = state.act or 'idle'
    local run = state.open[act]
    local key = plugins.BY_ACT[act]
    if not key then
        -- Travelling / idle: the activity plugin that is switched on, if any.
        key = ''
        for _, p in ipairs(plugins.LIST) do
            local rr = state.reads[p.key]
            if p.act and p.act ~= 'town' and rr and rr.enabled then key = p.key; break end
        end
    end
    local r = state.reads[key]
    local title = (run and run.label) or (state.zone_label ~= '' and state.zone_label) or
        ({travel = 'Travelling', town = 'Town'})[act] or act
    if act == 'idle' then title = '' end
    local step = (r and r.task) or M.NULL
    if act == 'pit' and run and run.floor then step = 'Floor ' .. run.floor end
    if act == 'town' and state.trip then step = 'Town trip' .. (state.trip.caller and (' for ' .. state.trip.caller) or '') end
    local since = run and run.start
    if not since then
        local block = state.feed.strip[#state.feed.strip]
        since = block and block.s or now
    end
    local a = state.scopes.session.activities[act]
    local eta, progress = M.NULL, M.NULL
    if run and a and a.ok + a.failed > 0 then
        local avg = a.time / (a.ok + a.failed)
        if avg > 0 then
            local elapsed = now - run.start
            eta = math.max(0, math.floor(avg - elapsed + 0.5))
            progress = math.min(0.99, math.floor(elapsed / avg * 100 + 0.5) / 100)
        end
    end
    return {plugin = key, activity = act, title = feed.cut(title), step = type(step) == 'string' and feed.cut(step) or step,
        progress = progress, since = since, eta = eta, zone = state.zone_label or ''}
end

local function helltide_next(now)
    local minute = math.floor(now / 60) % 60
    if minute < 55 then return 0 end
    return 3600 - (now % 3600)
end

local function status_of(state)
    local any = false
    for _, p in ipairs(plugins.LIST) do
        local r = state.reads[p.key]
        if p.key ~= 'batmobile' and r and r.enabled then any = true end
    end
    for _, a in ipairs(state.feed.alerts) do
        if not a.resolved and a.level == 'error' then return 'error' end
    end
    if not any then return 'stopped' end
    if state.act == 'idle' then return 'idle' end
    return 'running'
end

local function extra(s, act, key)
    local e = s.activities[act].extra
    return comma(type(e[key]) == 'number' and e[key] or 0)
end

-- The plan length is WarPug's board path; WarPigs counts a step per quest
-- it works (the turn-in and re-picked quests too). Past the path length
-- the total is unknown (nil), never "step 6 of 3".
local function plan_steps(plan)
    if not plan or type(plan.steps) ~= 'number' then return nil end
    if (plan.step or 0) > plan.steps then return nil end
    return plan.steps
end
M.plan_steps = plan_steps

-- key/value rows per plugin card (max 8), from the session scope.
local KV = {}
KV.warpigs = function(state, s, r)
    local plan = state.warplan
    return {{'Lease holder', state.counters.lease or '-'}, {'Switches', comma(state.counters.switches or 0)},
        {'Plan step', plan and (tostring(plan.step or 0) .. (plan_steps(plan) and (' / ' .. plan_steps(plan)) or '')) or '-'}}
end
KV.warpug = function(state, s, r)
    local plan = state.warplan
    return {{'State', r.task or '-'}, {'Plan', plan and plan.name or '-'},
        {'Step', plan and (tostring(plan.step or 0) .. ' / ' .. tostring(plan_steps(plan) or '?')) or '-'}}
end
KV.rosie = function(state, s, r)
    return {{'Town trips', comma(state.counters.trips or 0)}, {'Salvaged', comma(s.items.salvaged)},
        {'Sold', comma(s.items.sold)}, {'Stashed', comma(s.items.stashed)}, {'Looted', comma(s.items.looted)}}
end
KV.batmobile = function(state, s, r)
    return {{'Owner', type(r.owner) == 'string' and r.owner or 'none'}, {'Trapped', r.trapped and 'yes' or 'no'}}
end
KV.helltide = function(state, s, r)
    return {{'Chests', extra(s, 'helltide', 'chests')}, {'Mystery', extra(s, 'helltide', 'mystery')},
        {'Cinders', extra(s, 'helltide', 'cinders')}}
end
KV.hordedev = function(state, s, r)
    return {{'Runs', comma(s.activities.hordes.runs)}, {'Council', extra(s, 'hordes', 'council')},
        {'Chests', extra(s, 'hordes', 'chests')}}
end
KV.reaper = function(state, s, r)
    local rows, by = {}, s.activities.bosses.extra.by_boss
    if type(by) == 'table' then
        for name, count in pairs(by) do rows[#rows + 1] = {name, count} end
        table.sort(rows, function(a, b) if a[2] ~= b[2] then return a[2] > b[2] end return a[1] < b[1] end)
    end
    local out = {}
    for i = 1, math.min(#rows, 8) do out[i] = {rows[i][1], comma(rows[i][2])} end
    if #out == 0 then out[1] = {'Kills', '0'} end
    return out
end
KV.wonder = function(state, s, r)
    local a = s.activities.undercity
    return {{'Runs', comma(a.runs)}, {'Best floor', comma(a.best)}, {'Bosses', extra(s, 'undercity', 'bosses')}}
end
KV.arkham = function(state, s, r)
    local a = s.activities.pit
    return {{'Runs', comma(a.runs)}, {'Glyphs up', extra(s, 'pit', 'glyphs_up')},
        {'Tier now', state.pit_level and comma(state.pit_level) or '-'}, {'Best', comma(a.best)}}
end
KV.raven = function(state, s, r)
    return {{'Caches', extra(s, 'whispers', 'caches')}, {'Status', r.task or '-'}}
end
M.KV = KV

local function plugin_cards(state)
    local out, s = {}, state.scopes.session
    for _, p in ipairs(plugins.LIST) do
        local r = state.reads[p.key] or {present = false}
        local st
        -- States the page styles: running | idle | paused | waiting | error |
        -- stopped (not loaded) | disabled (loaded, switched off).
        local held = r.st and (r.st.paused == true or r.st.hold or r.st.hold_reason)
        if not r.present then st = 'stopped'
        elseif feed.worst(state.feed, p.key) == 'error' then st = 'error'
        elseif not r.enabled then st = 'disabled'
        elseif r.st and r.st.paused == true then st = 'paused'
        elseif held and held ~= '' then st = 'waiting'
        elseif r.busy or (p.act and p.act == state.act) then st = 'running'
        else st = 'idle' end
        local ok, kv = pcall(KV[p.key], state, s, r)
        local rows = json.array({})
        if not r.present then rows[1] = {'Loaded', 'no'} end
        if ok and type(kv) == 'table' then
            for i = 1, math.min(#kv, 8 - #rows) do rows[#rows + 1] = {feed.cut(kv[i][1]), feed.cut(kv[i][2])} end
        end
        out[p.key] = {name = p.name, role = p.role, state = st, ver = r.ver or '', kv = rows}
    end
    return out
end

function M.build(state, now, lim)
    lim = lim or {timeline = feed.TIMELINE_MAX, drops = feed.DROPS_MAX, strip = feed.STRIP_MAX, hourly = stats.HOURLY_MAX}
    local ht_next = helltide_next(now)
    local next_list = json.array({})
    if ht_next > 0 then
        next_list[1] = {plugin = 'helltide', activity = 'helltide',
            label = 'Helltide (starts in ' .. math.ceil(ht_next / 60) .. ' m)', at = now + ht_next}
    end
    local plan = state.warplan
    local strip = tail(state.feed.strip, lim.strip)
    local drops = head(state.feed.drops, lim.drops)
    return {
        v = M.SCHEMA, t = now, write_every = state.write_every or 15, suite = M.SUITE,
        session = {
            start = state.started, uptime = math.max(0, now - state.started), active = math.floor(state.active + 0.5),
            status = status_of(state), now = now_block(state, now), next = next_list,
            warplan = plan and {name = plan.name, step = plan.step or 0, steps = plan_steps(plan) or M.NULL} or M.NULL,
        },
        scopes = {session = scope_view(state, 'session', lim), today = scope_view(state, 'today', lim),
            alltime = scope_view(state, 'alltime', lim)},
        drops = drops,
        timeline = head(state.feed.timeline, lim.timeline),
        strip = strip,
        alerts = json.array(feed.alerts_view(state.feed)),
        plugins = plugin_cards(state),
        helltide = {file = 'hr_data.js', active = state.act == 'helltide' or (state.snap and state.snap.in_helltide == true),
            next_in = math.floor(ht_next + 0.5), zone = state.helltide_zone or '',
            -- null: unreadable (the page shows n/a, not 0)
            cinders = (state.snap and type(state.snap.cinders) == 'number') and state.snap.cinders or M.NULL},
    }
end

-- 'window.SUITE_DATA = {...};\n' no larger than max_bytes, or nil, reason.
function M.encode(state, now, max_bytes)
    local lim = {timeline = feed.TIMELINE_MAX, drops = feed.DROPS_MAX, strip = feed.STRIP_MAX, hourly = stats.HOURLY_MAX}
    for _ = 1, 10 do
        local ok, data = pcall(M.build, state, now, lim)
        if not ok then return nil, tostring(data) end
        local text = M.PREFIX .. json.encode(data) .. ';\n'
        if #text <= max_bytes then return text end
        lim.timeline = math.floor(lim.timeline / 2)
        lim.drops = math.floor(lim.drops / 2)
        lim.strip = math.floor(lim.strip / 2)
        lim.hourly = math.floor(lim.hourly / 2)
    end
    return nil, 'too big'
end

return M
