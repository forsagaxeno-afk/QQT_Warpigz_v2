-- QQT_Warpigz_v3: read-only view of the Helltide run shared by the stats
-- overlay (core/hr_overlay.lua) and the web dashboard (core/hr_dashboard.lua).
--
--   wave()          the chest-reset wave: index, count, next reset minute,
--                   seconds to it and the fraction of the wave elapsed
--   target(pos)     the chest being walked to: name, cost, x/y, distance,
--                   source ('seen' = a chest actor / remembered chest,
--                   'learned' = an atlas prediction) and the road mode
--   goal(c, tgt)    what the cinders are counted against (target cost,
--                   cinder-run threshold, Mystery reserve, a regular chest)
--   opened_wave(n)  chests opened in this reset wave (newest first)
--   to_open()       known chests not opened yet: mystery / regular seen,
--                   learned (unconfirmed) spots
--   activity(state), movement(state, tgt), plan()
-- Nothing here writes state or logs; every host read is protected.
local clock = require "core.hr_clock"
local stats = require "core.hr_stats"
local atlas = require "core.hr_atlas"
local enums = require "data.enums"
local tracker = require "core.tracker"

local M = {
    MYSTERY = 'usz_rewardGizmo_Uber',
    PRIZE = 'Warplan_Helltide_HellsPrize',
    REGIONS = {Frac_ = 'Fractured Peaks', Scos_ = 'Scosglen', Kehj_ = 'Kehjistan', Hawe_ = 'Hawezar',
        Step_ = 'Dry Steppes', Naha_ = 'Nahantu', Skov_ = 'Skovos'},
    CHEST_STATES = {MOVING_TO_HELLTIDE_CHEST = true, MOVING_TO_REMEMBERED_CHEST = true, FARM_CHEST_CINDERS = true},
}

-- state -> activity text (anything else is prettified).
local ACTIVITY = {
    INIT = 'Starting',
    EXPLORE_HELLTIDE = 'Patrolling the Helltide',
    MOVING_TO_TRAVERSAL = 'Taking a traversal',
    MOVING_TO_PYRE = 'Walking to an event', INTERACT_PYRE = 'Starting an event', STAY_NEAR_PYRE = 'Helltide event',
    MOVING_TO_HELLTIDE_CHEST = 'Walking to chest', MOVING_TO_REMEMBERED_CHEST = 'Walking to chest',
    MOVING_TO_SILENT_CHEST = 'Walking to a silent chest', FARM_CHEST_CINDERS = 'Farming cinders for a chest',
    MOVING_TO_ORE = 'Gathering ore', MOVING_TO_HERB = 'Gathering herbs', MOVING_TO_SHRINE = 'Taking a shrine',
    MOVING_TO_CHAOS_RIFT = 'Walking to a chaos rift', INTERACT_CHAOS_RIFT = 'Chaos rift', STAY_NEAR_CHAOS_RIFT = 'Chaos rift',
    CHASE_GOBLIN = 'Chasing a goblin', KILL_MONSTERS = 'Fighting',
    BACK_TO_TOWN = 'Going to town', RETURN_TO_HELLTIDE = 'Returning to the Helltide',
    MOVING_TO_MAIDEN = 'Walking to the Blood Maiden', AT_MAIDEN = 'Blood Maiden',
}

local floor, sqrt = math.floor, math.sqrt

local function num(v)
    v = tonumber(v)
    if not v or v ~= v or v == math.huge or v == -math.huge then return 0 end
    return v
end
M.num = num

function M.short_name(name)
    name = tostring(name or '?')
    if name == M.MYSTERY then return 'Mystery' end
    if name == M.PRIZE then return "Hell's Prize" end
    if name == 'Helltide_RewardChest_Random' then return 'Random chest' end
    name = name:gsub('^usz_rewardGizmo_', '')
    return name
end

function M.region(zone)
    if type(zone) ~= 'string' or zone == '' then return nil end
    for prefix, label in pairs(M.REGIONS) do
        if zone:sub(1, #prefix) == prefix then return label end
    end
    return zone
end

-- "6m 29s" / "45s" for a number of seconds.
function M.dur(seconds)
    seconds = floor(num(seconds) + 0.5)
    if seconds < 0 then seconds = 0 end
    if seconds >= 3600 then return string.format('%dh %02dm', floor(seconds / 3600), floor(seconds / 60) % 60) end
    if seconds >= 60 then return string.format('%dm %02ds', floor(seconds / 60), seconds % 60) end
    return string.format('%ds', seconds)
end

-- ── timers ───────────────────────────────────────────────────────────────
function M.wave()
    local list = clock.RESET_MINUTES
    local m, s = clock.min_sec()
    local at = m + s / 60
    local i = clock.reset_slot(m)
    local start = list[i]
    local nxt = list[i + 1] or 60
    local span = nxt - start
    local frac = span > 0 and (at - start) / span or 0
    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
    return {i = i, n = #list, start = start, next_min = nxt % 60, next_in = clock.next_reset_in(), frac = frac}
end

-- ── remembered chests (tasks/helltide.lua) ───────────────────────────────
local function remembered()
    local get = tracker.hr_get_remembered
    if type(get) ~= 'function' then return nil end
    local ok, rem, key, fname, fpos = pcall(get)
    if not ok then return nil end
    return type(rem) == 'table' and rem or nil, key, fname, fpos
end
M.remembered = remembered

-- The chest order's last plan, only while the order runs (Farm smart order,
-- or an engaged cinder run). Otherwise it is left over: e.g. under WarPigs
-- after a cinder run ended the order is no longer asked, and its last plan
-- would show "Opening chests, Mystery first" / an old target for the rest
-- of the Helltide.
local function live_plan()
    local order = tracker.hr_chest_order
    if type(order) ~= 'table' or type(order.last_plan) ~= 'table' then return nil end
    if type(order.enabled) == 'function' then
        local ok, on = pcall(order.enabled)
        if not ok or on ~= true then return nil end
    end
    return order.last_plan
end
M.live_plan = live_plan

local function xy(pos)
    if pos == nil then return nil end
    return atlas.xyz(pos)
end

function M.target(player_pos)
    local state = tracker.hr_task_state
    local rem, rkey, fname, fpos = remembered()
    local lp = live_plan()
    local name, pos, key, entry
    if type(lp) == 'table' and lp.target_name and lp.target_pos then
        name, pos, key = lp.target_name, lp.target_pos, lp.target_key
    end
    if not name and rkey and rem and type(rem[rkey]) == 'table' then
        entry = rem[rkey]
        name, pos, key = entry.name, entry.position, rkey
    end
    if not name and fname and fpos and state == 'MOVING_TO_HELLTIDE_CHEST' then
        name, pos = fname, fpos
    end
    if not name then return nil end
    entry = entry or (key and rem and type(rem[key]) == 'table' and rem[key]) or nil
    local source = 'seen'
    if (entry and entry.predicted) or (type(lp) == 'table' and lp.target_key == key and num(lp.class) % 2 == 1) then
        source = 'learned'
    end
    local x, y = xy(pos)
    local t = {name = tostring(name), short = M.short_name(name), cost = enums.chest_types[name] or 0,
        source = source, mystery = name == M.MYSTERY, road = entry and type(entry.route) == 'table' or false}
    if x then
        t.x, t.y = x, y
        local px, py = xy(player_pos)
        if px then
            local dx, dy = x - px, y - py
            t.dist = sqrt(dx * dx + dy * dy)
        end
    end
    return t
end

-- ── cinder goal ──────────────────────────────────────────────────────────
function M.goal(cinders, target)
    cinders = num(cinders)
    local run = tracker.hr_cinder_run
    local rs = nil
    if run and run.status then
        local ok, s = pcall(run.status)
        if ok and type(s) == 'table' then rs = s end
    end
    local g
    if rs and rs.saving and num(rs.threshold) > 0 then
        g = {cost = num(rs.threshold), label = 'Cinder run'}
    elseif target and num(target.cost) > 0 then
        g = {cost = num(target.cost), label = target.short}
    else
        local lp = live_plan()
        if type(lp) == 'table' and num(lp.reserve) > 0 then
            g = {cost = num(lp.reserve), label = 'Mystery reserve'}
        else
            g = {cost = enums.chest_types.usz_rewardGizmo_Gloves or 75, label = 'Chest'}
        end
    end
    g.ready = cinders >= g.cost
    g.frac = g.cost > 0 and math.min(1, cinders / g.cost) or 1
    return g, rs
end

-- ── opened chests ────────────────────────────────────────────────────────
function M.opened_wave(limit)
    local out = {}
    local slot = clock.slot_id()
    local list = stats.opened or {}
    for i = #list, 1, -1 do
        local o = list[i]
        if o.slot ~= slot then break end
        out[#out + 1] = o
        if limit and #out >= limit then break end
    end
    return out
end

function M.opened_hour_count()
    local n, hour = 0, clock.hour_id()
    local list = stats.opened or {}
    for i = #list, 1, -1 do
        if list[i].hour ~= hour then break end
        n = n + 1
    end
    return n
end

function M.to_open()
    local out = {mystery = 0, regular = 0, learned = 0}
    local rem = remembered()
    if rem then
        for _, e in pairs(rem) do
            if type(e) == 'table' and not e.predicted then
                if e.name == M.MYSTERY then out.mystery = out.mystery + 1 else out.regular = out.regular + 1 end
            end
        end
    end
    local ok, list = pcall(atlas.predicted)
    if ok and type(list) == 'table' then out.learned = #list end
    return out
end

-- ── now ──────────────────────────────────────────────────────────────────
function M.activity(state)
    state = state and tostring(state) or nil
    if not state or state == '' then return 'Idle' end
    local text = ACTIVITY[state]
    if text then return text end
    local tear = tracker.tear_event
    if tear and tear.is_rift_state then
        local ok, rift = pcall(tear.is_rift_state, state)
        if ok and rift then return 'Pandemonium rupture' end
    end
    text = state:lower():gsub('_', ' ')
    return (text:gsub('^%l', string.upper))
end

function M.movement(state, target)
    if M.CHEST_STATES[state] and target then
        if target.road then return 'Patrol road, then off-road' end
        return 'Direct path'
    end
    if state == 'EXPLORE_HELLTIDE' then return 'Following the patrol loop' end
    if state == 'BACK_TO_TOWN' or state == 'RETURN_TO_HELLTIDE' then return 'Teleport / travel' end
    if state == nil or state == '' then return 'Standing' end
    return 'Local'
end

function M.plan()
    local run = tracker.hr_cinder_run
    local rs = nil
    if run and run.status then
        local ok, s = pcall(run.status)
        if ok and type(s) == 'table' then rs = s end
    end
    if rs and rs.active then return 'Cinder run: opening chests, best first' end
    if rs and rs.saving then return string.format('Saving cinders for the run at %d', num(rs.threshold)) end
    local lp = live_plan()
    if type(lp) == 'table' then
        if num(lp.reserve) > 0 then return string.format('Reserve %d for a Mystery chest', num(lp.reserve)) end
        return 'Opening chests, Mystery first'
    end
    local mode = tracker.hr_mode
    local ok, eff = pcall(function() return mode and mode.effective() end)
    if ok and eff == 'warplan' then return 'Warplan: chests on the way' end
    return 'Opening regular chests'
end

-- Cinders per minute of Helltide time of a stats scope.
function M.scope_rate(t)
    t = t or {}
    local mins = num(t.secs) / 60
    if mins <= 0 then return 0 end
    return num(t.earned) / mins
end

return M
