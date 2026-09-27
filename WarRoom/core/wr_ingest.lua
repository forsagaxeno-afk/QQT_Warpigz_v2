-- QQT_Warpigz_v3: WarRoom turns suite bus events (core/qqt_events.lua) into
-- counters (core/wr_stats.lua) and list rows (core/wr_feed.lua).
-- handle(state, ev, now) never raises (the collector wraps it in pcall too).
local stats = require 'core.wr_stats'
local feed = require 'core.wr_feed'

local M = {}
local H = {}
M.H = H

local function num(v)
    v = tonumber(v)
    if v == nil or v ~= v or v == math.huge or v == -math.huge then return nil end
    return v
end

local function str(v, fallback)
    if type(v) == 'string' and v ~= '' then return feed.cut(v) end
    if type(v) == 'number' then return tostring(v) end
    return fallback
end

local function mmss(secs)
    secs = math.floor((num(secs) or 0) + 0.5)
    if secs >= 3600 then
        return string.format('%d:%02d:%02d', math.floor(secs / 3600), math.floor(secs / 60) % 60, secs % 60)
    end
    return string.format('%d:%02d', math.floor(secs / 60), secs % 60)
end
M.mmss = mmss

local function comma(n)
    n = math.floor((num(n) or 0) + 0.5)
    local s = tostring(math.abs(n))
    local out = s:reverse():gsub('(%d%d%d)', '%1,'):reverse():gsub('^,', '')
    if n < 0 then out = '-' .. out end
    return out
end
M.comma = comma

-- The activity a drop belongs to: the current one, else (travelling, idle)
-- the activity that ended in the last SOURCE_WINDOW seconds, else 'other'.
M.SOURCE_WINDOW = 300
function M.source_act(state, now)
    local act = state.act
    if act and act ~= 'travel' and act ~= 'idle' then return act end
    local best, best_t = nil, now - M.SOURCE_WINDOW
    for name, last in pairs(state.last_run) do
        if last.t >= best_t then best, best_t = name, last.t end
    end
    return best or 'other'
end

-- Open a run of `act` (label shown on the dashboard); counted = runs + 1 now.
local function open(state, act, now, label, counted, extra)
    local run = {start = now, label = label, counted = counted}
    if type(extra) == 'table' then for k, v in pairs(extra) do run[k] = v end end
    state.open[act] = run
    if counted then stats.run_start(state, act) end
    return run
end
M.open = open

-- Close the open run of `act` (or count a run that had no start event).
local function finish(state, act, plugin, now, ok, secs, best, text)
    local run = state.open[act]
    if secs == nil then secs = run and (now - run.start) or 0 end
    stats.run_end(state, act, {ok = ok, secs = secs, best = best, counted = run ~= nil and run.counted == true,
        start = run and run.start}, now)
    state.open[act] = nil
    state.dirty_save = true -- a finished run is saved now, not up to SAVE_EVERY s later
    state.last_run[act] = {t = now, ok = ok, label = run and run.label}
    feed.timeline(state.feed, now, ok and 'run_ok' or 'run_fail', plugin, act, text, secs)
    if ok then feed.resolve_prefix(state.feed, 'ev:' .. plugin .. ':', now) end
end
M.finish = finish

local function alert(state, now, plugin, code, level, text)
    local _, new = feed.alert(state.feed, 'ev:' .. plugin .. ':' .. code, now, level, plugin, code, text)
    if new then feed.timeline(state.feed, now, 'alert', plugin, state.act or '', text) end
end

-- Arkham (The Pit) -------------------------------------------------------
-- A pit_start while the last opened pit was never entered (collector sets
-- run.entered) and is younger than this is the same run.
M.PIT_REOPEN = 180
H['arkham.pit_start'] = function(state, ev, now)
    local level = num(ev.level)
    local label = level and ('Pit Tier ' .. math.floor(level)) or 'Pit'
    local run = state.open.pit
    if run and not run.entered and now - run.start < M.PIT_REOPEN then
        -- The portal opened again before the bot got in (a retried
        -- confirmation): still the same run.
        run.label, run.level = label, level or run.level
        return
    end
    open(state, 'pit', now, label, true, {level = level, floor = 1})
    state.pit_level = level or state.pit_level
    feed.timeline(state.feed, now, 'run_start', 'arkham', 'pit', label .. ' started')
end
H['arkham.pit_floor'] = function(state, ev, now)
    local run = state.open.pit
    if run then run.floor = (run.floor or 1) + 1 end
end
H['arkham.pit_boss_killed'] = function(state, ev, now)
    local run = state.open.pit
    if run then run.boss = true end
end
H['arkham.glyph_upgraded'] = function(state, ev, now)
    stats.extra_add(state, 'pit', 'glyphs_up', 1)
    local run = state.open.pit or state.last_run.pit
    if run then run.glyph = true end
end
H['arkham.glyph_upgrade_failed'] = function(state, ev, now)
    stats.extra_add(state, 'pit', 'glyph_fails', 1)
end
H['arkham.pit_end'] = function(state, ev, now)
    local run = state.open.pit
    local level = num(ev.level) or (run and run.level)
    local label = (run and run.label) or (level and ('Pit Tier ' .. math.floor(level))) or 'Pit'
    local ok = ev.boss == true and ev.timeout ~= true
    local secs = num(ev.secs)
    local text
    if ok then
        text = label .. ' done in ' .. mmss(secs or (run and now - run.start) or 0)
        if ev.glyph == true or (run and run.glyph) then text = text .. ' · glyph upgraded' end
    elseif ev.timeout == true then
        text = label .. ' failed: timer ran out' .. ((run and run.floor) and (' on floor ' .. run.floor) or '')
        alert(state, now, 'arkham', 'pit_timeout', 'warn', label .. ' failed: timer ran out')
    else
        text = label .. ' ended before the boss'
    end
    state.pit_level = level or state.pit_level
    finish(state, 'pit', 'arkham', now, ok, secs, level, text)
end

-- WonderCity (Undercity) -------------------------------------------------
H['wondercity.undercity_start'] = function(state, ev, now)
    open(state, 'undercity', now, 'Undercity', true)
    feed.timeline(state.feed, now, 'run_start', 'wonder', 'undercity', 'Undercity started')
end
H['wondercity.boss_killed'] = function(state, ev, now)
    stats.extra_add(state, 'undercity', 'bosses', 1)
end
H['wondercity.undercity_reward'] = function(state, ev, now)
    local run = state.open.undercity
    if run then run.reward = str(ev.reason, 'reward') end
end
H['wondercity.undercity_end'] = function(state, ev, now)
    local ok = ev.success == true
    local floors = num(ev.floors)
    local text
    if ok then
        text = floors and ('Undercity floor ' .. math.floor(floors) .. ' cleared') or 'Undercity cleared'
    else
        local why = str(ev.reason, 'unknown')
        text = 'Undercity failed: ' .. why
        alert(state, now, 'wonder', 'undercity_failed', 'warn', text)
    end
    finish(state, 'undercity', 'wonder', now, ok, num(ev.secs), floors, text)
end

-- HordeDev (Infernal Hordes) ---------------------------------------------
H['hordedev.horde_start'] = function(state, ev, now)
    open(state, 'hordes', now, 'Infernal Hordes', true, {mode = str(ev.mode)})
    feed.timeline(state.feed, now, 'run_start', 'hordedev', 'hordes', 'Infernal Hordes started')
end
H['hordedev.horde_pylon'] = function(state, ev, now) stats.extra_add(state, 'hordes', 'pylons', 1) end
H['hordedev.horde_council'] = function(state, ev, now) stats.extra_add(state, 'hordes', 'council', 1) end
H['hordedev.horde_chest'] = function(state, ev, now)
    stats.extra_add(state, 'hordes', 'chests', 1)
end
H['hordedev.horde_chest_fault'] = function(state, ev, now)
    alert(state, now, 'hordedev', 'chest_fault', 'warn', 'Horde chest: ' .. str(ev.msg, 'fault'))
end
H['hordedev.horde_done'] = function(state, ev, now)
    local exit = str(ev.exit)
    finish(state, 'hordes', 'hordedev', now, true, nil, nil, 'Infernal Hordes done' .. (exit and (' · ' .. exit) or ''))
end
H['hordedev.horde_fail'] = function(state, ev, now)
    local text = 'Infernal Hordes failed: ' .. str(ev.msg, 'unknown')
    alert(state, now, 'hordedev', 'horde_failed', 'warn', text)
    -- An entry / activation fault before the Horde started is not a run
    -- (HordeDev reports it once per fault; the alert says it).
    if state.open.hordes then finish(state, 'hordes', 'hordedev', now, false, nil, nil, text) end
end

-- Reaper (bosses) ----------------------------------------------------------
H['reaper.boss_summoned'] = function(state, ev, now)
    local label = str(ev.label, str(ev.boss, 'Boss'))
    open(state, 'bosses', now, label, true)
end
H['reaper.chest_opened'] = function(state, ev, now) stats.extra_add(state, 'bosses', 'chests', 1) end
H['reaper.boss_killed'] = function(state, ev, now)
    local label = str(ev.label, str(ev.boss, 'Boss'))
    stats.extra_add(state, 'bosses', 'by_boss', 1, label)
    local tier = str(ev.tier)
    finish(state, 'bosses', 'reaper', now, true, num(ev.secs), nil,
        label .. (tier and (' (' .. tier .. ')') or '') .. ' killed')
end
H['reaper.boss_skipped'] = function(state, ev, now)
    feed.timeline(state.feed, now, 'alert', 'reaper', 'bosses',
        str(ev.label, 'Boss') .. ' skipped: ' .. str(ev.reason, 'unknown'))
end
-- result: 'success' | 'failed' | 'cancelled' (Reaper/main.lua end_run; the
-- run kind is in `mode`). A summoned boss still open when the run ends was
-- not killed: a failed run (a cancel raises no alert).
H['reaper.run_end'] = function(state, ev, now)
    local result = str(ev.result, '')
    local good = result == '' or result == 'completed' or result == 'ok' or result == 'success'
    local open_run = state.open.bosses
    if good then
        if open_run then state.open.bosses = nil end
        return
    end
    local text = 'Boss run ' .. result .. ': ' .. str(ev.reason, 'unknown')
    if result ~= 'cancelled' then alert(state, now, 'reaper', 'run_failed', 'warn', text) end
    if open_run then finish(state, 'bosses', 'reaper', now, false, nil, nil, text) end
end

-- HelltideRevamped -------------------------------------------------------
-- A Helltide run is a VISIT: the collector opens it when the bot is in the
-- Helltide (buff) and ends it (end_visit) HELLTIDE_AWAY s after it left, or
-- when HelltideRevamped closes its hour record inside. helltide_done is that
-- hour record: HR closes it at the hour change while it runs, so under a War
-- Plan (HR switched off after its quest) it can arrive much later; its
-- chests / cinders go to the extras then and never count a second run.
M.HELLTIDE_MIN, M.HELLTIDE_AWAY = 60, 120
function M.end_visit(state, now, force, text)
    local run = state.open.helltide
    if not run then return false end
    local secs = (run.away or now) - run.start
    if secs < M.HELLTIDE_MIN and not force then
        state.open.helltide = nil -- passing through
        return false
    end
    finish(state, 'helltide', 'helltide', now, true, secs, nil,
        text or ('Helltide' .. (state.helltide_zone and state.helltide_zone ~= '' and (' · ' .. state.helltide_zone) or '')
            .. ' done in ' .. mmss(secs)))
    return true
end
H['helltide.helltide_done'] = function(state, ev, now)
    local earned, chests = num(ev.earned) or 0, num(ev.chests) or 0
    stats.extra_add(state, 'helltide', 'chests', chests)
    stats.extra_add(state, 'helltide', 'mystery', num(ev.mystery) or 0)
    stats.extra_add(state, 'helltide', 'cinders', earned)
    stats.extra_add(state, 'helltide', 'tears', num(ev.tears) or 0)
    stats.best(state, 'helltide', earned)
    local zone = str(ev.zone)
    if zone then state.helltide_zone = zone end
    local text = 'Helltide hour closed · ' .. comma(chests) .. ' chests · ' .. comma(earned) .. ' cinders'
    local run = state.open.helltide
    if run and not run.away and M.end_visit(state, now, true, text) then return end
    -- The visit is (or will be) its own run row: the hour record is not a
    -- second run on the Runs lists (kind 'helltide_hour', not run_*).
    feed.timeline(state.feed, now, 'helltide_hour', 'helltide', 'helltide', text, num(ev.secs))
    state.dirty_save = true
end

-- Rosie (town + pickup) --------------------------------------------------
H['rosie.trip_start'] = function(state, ev, now)
    state.trip = {start = now, caller = str(ev.caller), stashed = 0}
end
H['rosie.trip_end'] = function(state, ev, now)
    local trip = state.trip or {start = now, stashed = 0}
    local sold, salvaged = num(ev.sold) or 0, num(ev.salvaged) or 0
    stats.add_fate(state, 'sold', sold)
    stats.add_fate(state, 'salvaged', salvaged)
    state.counters.trips = (state.counters.trips or 0) + 1
    local outcome = str(ev.outcome, 'done')
    local text = 'Town trip: salvaged ' .. comma(salvaged) .. ', sold ' .. comma(sold) .. ', stashed ' .. comma(trip.stashed)
    local ok = outcome == 'done' or outcome == 'success' or outcome == 'completed' or outcome == 'ok'
    if not ok then
        text = 'Town trip ' .. outcome .. ': ' .. str(ev.reason, 'unknown')
        if outcome ~= 'cancelled' then alert(state, now, 'rosie', 'town_trip', 'warn', text) end
    else
        feed.resolve_prefix(state.feed, 'ev:rosie:', now)
    end
    feed.timeline(state.feed, now, 'town', 'rosie', 'town', text, num(ev.secs) or (now - trip.start))
    state.trip = nil
end
-- Rosie's stash names an item by its internal name (item:get_name()) while
-- the pickup carries the display name: the SNO ties the two together.
H['rosie.stashed'] = function(state, ev, now)
    stats.add_fate(state, 'stashed', 1)
    state.dirty_save = true
    if state.trip then state.trip.stashed = state.trip.stashed + 1 end
    local sno = num(ev.sno)
    if sno and feed.fate_sno(state.feed, sno, 'stashed') then return end
    local known = sno and state.feed.names['#' .. sno]
    local name = (known and known.name) or str(ev.name)
    if not name then return end
    if feed.fate(state.feed, name, 'stashed') then return end
    known = known or state.feed.names[name]
    feed.drop(state.feed, {t = now, rarity = known and known.rarity or '', name = name, ga = known and known.ga or 0,
        src = 'town', act = 'Stash', fate = 'stashed'})
end
local NOTABLE = {mythic = true, unique = true, legendary = true}
local TITLE = {mythic = 'Mythic', unique = 'Unique', legendary = 'Legendary'}
H['rosie.pickup'] = function(state, ev, now)
    local rarity = stats.rarity(ev.rarity, ev.mythic == true)
    local ga = math.floor(num(ev.ga) or 0)
    if ga < 0 then ga = 0 end
    stats.add_item(state, rarity, ga, now)
    local name = str(ev.name)
    if not name then return end
    local sno = num(ev.sno)
    feed.remember(state.feed, name, rarity, ga, sno)
    -- The drops list: mythic, unique, legendary with a greater affix.
    if not NOTABLE[rarity] or (rarity == 'legendary' and ga < 1) then return end
    local act = M.source_act(state, now)
    local run = state.open[act]
    local d = {t = now, rarity = rarity, name = name, ga = ga, src = act,
        act = (run and run.label) or state.zone_label or '', fate = feed.PICKED, sno = sno}
    local power = num(ev.power)
    if power then d.power = power end
    if ev.ancestral == true then d.ancestral = true end
    feed.drop(state.feed, d)
    state.dirty_save = true -- a notable drop is saved now
    if rarity ~= 'legendary' or ga >= 2 then
        feed.timeline(state.feed, now, 'drop', 'rosie', act, TITLE[rarity] .. ' · ' .. name
            .. (ga > 0 and (' (' .. ga .. ' GA)') or ''))
    end
end

-- SilentRaven (whispers) ---------------------------------------------------
-- result (SilentRaven fsm finish): 'success'; 'failed' | 'unconfirmed' (a
-- failed run); 'cancelled' and 'skipped_*' (nothing to claim, panel busy:
-- WarPigs looks again after every turn-in) are not runs.
H['silentraven.whisper_claim'] = function(state, ev, now)
    local result = ev.result
    if result == 'cancelled' or (type(result) == 'string' and result:sub(1, 8) == 'skipped_') then return end
    local ok = result == true or result == 'ok' or result == 'claimed' or result == 'success' or result == 'done'
    if ok then stats.extra_add(state, 'whispers', 'caches', 1) end
    local name = str(ev.name)
    local text = ok and ('Whisper cache turned in' .. (name and (': ' .. name) or ''))
        or ('Whisper claim failed: ' .. str(ev.reason, str(result, 'unknown')))
    finish(state, 'whispers', 'raven', now, ok, 0, nil, text)
end

-- WarPug / WarPigs (plans) -------------------------------------------------
local function count_steps(path)
    if type(path) == 'number' then return math.floor(path) end
    if type(path) ~= 'string' or path == '' then return nil end
    local n = 0
    for _ in path:gmatch('[^,;>|]+') do n = n + 1 end
    return n > 0 and n or nil
end
H['warpug.plan_created'] = function(state, ev, now)
    state.warplan = {name = 'War plan', step = 0, steps = count_steps(ev.path)}
    local steps = state.warplan.steps
    feed.timeline(state.feed, now, 'plan', 'warpug', 'plan', 'War plan created' .. (steps and (' (' .. steps .. ' steps)') or ''))
    feed.resolve_prefix(state.feed, 'ev:warpug:', now)
end
H['warpug.plan_reroll'] = function(state, ev, now)
    feed.timeline(state.feed, now, 'plan', 'warpug', 'plan', 'War plan rerolled' .. (num(ev.n) and (' (' .. ev.n .. ')') or ''))
end
H['warpug.plan_halt'] = function(state, ev, now)
    alert(state, now, 'warpug', 'plan_halt', 'warn', 'War plan halted: ' .. str(ev.reason, 'unknown'))
end
-- 'WarPlans_QST_Helltide_TorturedGifts' -> 'Helltide TorturedGifts'.
local function quest_label(q)
    q = str(q)
    if not q then return nil end
    local label = q:gsub('^[Ww]ar[Pp]lans?_QST_', ''):gsub('_', ' ')
    return label ~= '' and label or q
end
M.quest_label = quest_label
H['warpigs.step_start'] = function(state, ev, now)
    local plan = state.warplan or {name = 'War plan', step = 0}
    state.warplan = plan
    plan.step = (plan.step or 0) + 1
    plan.quest = quest_label(ev.quest)
    local of = (plan.steps and plan.step <= plan.steps) and (' of ' .. plan.steps) or ''
    feed.timeline(state.feed, now, 'plan', 'warpigs', 'plan', 'War plan step ' .. plan.step .. of .. ': ' .. (plan.quest or 'quest'))
end
H['warpigs.turn_in_done'] = function(state, ev, now)
    feed.timeline(state.feed, now, 'plan', 'warpigs', 'plan', 'War plan turned in')
    if state.warplan then state.warplan.done = true end
end
H['warpigs.plugin_enabled'] = function(state, ev, now)
    state.counters.switches = (state.counters.switches or 0) + 1
    state.counters.lease = str(ev.plugin)
end
H['warpigs.plugin_disabled'] = function(state, ev, now)
    if state.counters.lease == str(ev.plugin) then state.counters.lease = nil end
end
-- A plugin that finished its run hands the lease back without a disable.
H['warpigs.plugin_finished'] = H['warpigs.plugin_disabled']

function M.handle(state, ev, now)
    if type(ev) ~= 'table' then return false end
    local fn = H[tostring(ev.source) .. '.' .. tostring(ev.kind)]
    if not fn then return false end
    fn(state, ev, now)
    return true
end

return M
