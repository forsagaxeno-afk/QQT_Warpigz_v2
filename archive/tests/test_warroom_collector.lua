-- QQT_Warpigz_v3: WarRoom collector (WarRoom/main.lua, WarRoom/core/wr_*.lua)
-- against a fake QQT host: suite bus events + player / world polls ->
-- session / today / all-time aggregates, local-midnight rollover, XP across
-- level and paragon steps, plugin-status alerts, persistence, and a
-- dashboard/suite_data.js that is `window.SUITE_DATA = <valid JSON>;`,
-- bounded in size. Runs under Lua 5.4 and LuaJIT.
local ROOT = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local WR = ROOT .. '/WarRoom/'

local passed, failed = 0, {}
local function ok(cond, name)
    if cond then passed = passed + 1 else failed[#failed + 1] = name end
end
local function eq(a, b, name)
    if a == b then passed = passed + 1
    else failed[#failed + 1] = name .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a) end
end

-- Strict JSON validator (RFC 8259 grammar; no decoding).
local function json_check(text)
    local pos = 1
    local function ws() pos = text:find('[^ \t\r\n]', pos) or (#text + 1) end
    local function peek() return text:sub(pos, pos) end
    local function str()
        pos = pos + 1
        while true do
            local c = peek()
            if c == '' then error('unterminated string') end
            if c == '"' then pos = pos + 1; return end
            if c == '\\' then
                local e = text:sub(pos + 1, pos + 1)
                if e == 'u' then
                    assert(text:sub(pos + 2, pos + 5):match('^%x%x%x%x$'), 'bad \\u escape at ' .. pos)
                    pos = pos + 6
                else
                    assert(e:match('^["\\/bfnrt]$'), 'bad escape at ' .. pos)
                    pos = pos + 2
                end
            else
                assert(c:byte() >= 32, 'control character in a string at ' .. pos)
                pos = pos + 1
            end
        end
    end
    local value
    local function list(close, item)
        pos = pos + 1; ws()
        if peek() == close then pos = pos + 1; return end
        while true do
            item(); ws()
            local d = peek(); pos = pos + 1
            if d == close then return end
            assert(d == ',', 'expected , or ' .. close .. ' at ' .. (pos - 1))
            ws()
        end
    end
    value = function()
        ws()
        local c = peek()
        if c == '{' then
            list('}', function()
                assert(peek() == '"', 'object key expected at ' .. pos); str(); ws()
                assert(peek() == ':', ': expected at ' .. pos); pos = pos + 1
                value()
            end)
        elseif c == '[' then
            list(']', value)
        elseif c == '"' then
            str()
        else
            local lit = text:match('^%-?%d+%.?%d*[eE]?[%+%-]?%d*', pos) or text:match('^true', pos)
                or text:match('^false', pos) or text:match('^null', pos)
            assert(lit and #lit > 0 and not lit:match('%.$'), 'bad value at ' .. pos .. ': ' .. text:sub(pos, pos + 10))
            pos = pos + #lit
        end
    end
    value(); ws()
    assert(pos > #text, 'trailing data at ' .. pos)
    return true
end

-- Fake host ---------------------------------------------------------------
local T = 100
local noon = os.time({year = 2026, month = 9, day = 27, hour = 12, min = 0, sec = 0})
local EPOCH = noon
local logs = {}
console = {print = function(msg) logs[#logs + 1] = tostring(msg) end}
get_time_since_inject = function() return T end
attributes = {PARAGON_LEVEL = 'PARAGON', PLAYER_IN_TOWN_LEVEL_AREA = 'TOWN'}
local P = {gold = 1000000, level = 50, xp = 900, need = 1000, paragon = 10, obols = 100, dead = false,
    town = 0, buffs = {}}
local player = {}
function player:get_gold() return P.gold end
function player:get_level() return P.level end
function player:get_current_experience() return P.xp end
function player:get_experience_total_next_level() return P.need end
function player:get_obols() return P.obols end
function player:is_dead() return P.dead end
function player:get_buffs() return P.buffs end
function player:get_attribute(id)
    if id == 'PARAGON' then return P.paragon end
    if id == 'TOWN' then return P.town end
    return 0
end
get_local_player = function() return player end
local W = {name = 'Sanctuary_Eastern_Continent', zone = 'Kehj_Caldeum'}
local world = {}
function world:get_name() return W.name end
function world:get_current_zone_name() return W.zone end
get_current_world = function() return world end
get_helltide_coin_cinders = function() return 321 end

-- Plugin globals (status tables the collector reads).
local ST = {rosie = {enabled = true, stuck = false, version = '1.0.15'}, arkham = {enabled = true, task = 'Current Task: Explore (floor)', in_run = true, version = '2.1.1'}}
AlfredTheButlerPlugin = {get_status = function() return ST.rosie end}
ArkhamAsylumPlugin = {get_status = function() return ST.arkham end}
WarPigsPlugin = {status = function() error('WarRoom must not call WarPigs status()') end,
    peek = function() return {enabled = true, version = '1.1.5'} end}
ReaperPlugin = {status = function() error('boom') end}
BatmobilePlugin = {get_owner = function() return 'arkham' end, is_trapped = function() return false end,
    is_giving_up = function() return false end}

-- Menu / callback stubs for loading main.lua.
local function widget(default)
    local w = {v = default}
    function w:get() return self.v end
    function w:set(v) self.v = v end
    function w:render() end
    function w:push() return true end
    function w:pop() end
    return w
end
checkbox = {new = function(_, v) return widget(v) end}
slider_int = {new = function(_, lo, hi, v) return widget(v) end}
button = {new = function() return widget(false) end}
tree_node = {new = function() return widget(nil) end}
get_hash = function(s) return s end
local callbacks = {}
on_update = function(fn) callbacks.update = fn end
on_render_menu = function(fn) callbacks.menu = fn end

package.path = WR .. '?.lua;' .. package.path

-- 1. main.lua loads like a plugin and publishes QQT_WarRoom -----------------
dofile(WR .. 'main.lua')
ok(type(QQT_WarRoom) == 'table', 'QQT_WarRoom published')
eq(QQT_WarRoom.dashboard_dir, WR .. 'dashboard/', 'dashboard_dir is the absolute WarRoom/dashboard/')
eq(QQT_WarRoom.version, '1.0.6', 'version published')
ok(type(callbacks.update) == 'function' and type(callbacks.menu) == 'function', 'callbacks registered')
local gui = require 'gui'
eq(gui.version, 'v1.0.6', 'gui version string')
eq(gui.elements.main_toggle:get(), true, 'Enable defaults to ON')
eq(gui.elements.write_every:get(), 15, 'Write every defaults to 15 s')
callbacks.menu()

-- Redirect every file to a temp folder before any tick runs.
local tmp = os.tmpname()
os.remove(tmp)
os.execute('mkdir -p "' .. tmp .. '/dashboard" "' .. tmp .. '/data"')
local store = require 'core.wr_store'
store.set_root(tmp .. '/')
local clock = require 'core.wr_clock'
clock._now = function() return EPOCH end
local collector = require 'core.wr_collector'
local events = require 'core.qqt_events'
local payload = require 'core.wr_payload'
local state = collector.init({load = false})
ok(type(rawget(_G, 'QQT_Warpigz_events')) == 'table', 'the collector creates the event bus')

local function step(dt, opts)
    T, EPOCH = T + dt, EPOCH + dt
    return collector.tick(T, opts or {enabled = true, write_every = 15})
end
local function read(rel)
    local f = io.open(tmp .. '/' .. rel, 'r')
    if not f then return nil end
    local text = f:read('*a')
    f:close()
    return text
end
local function emit(src, kind, fields) return events.emit(src, kind, fields or {}) end

callbacks.update() -- the real on_update callback
step(1)
local S = function() return collector.state().scopes.session end
eq(S().totals.gold, 0, 'first poll is the baseline')
local text = read('dashboard/suite_data.js')
ok(text ~= nil, 'suite_data.js written on the first tick')

-- 2. Polls: gold, obols, XP with level + paragon steps, deaths -------------
P.gold = P.gold + 5000; step(1)
P.gold = P.gold - 2000; step(1)
eq(S().totals.gold, 5000, 'gold earned')
eq(S().totals.gold_spent, 2000, 'gold spent')
P.obols = 160; step(1)
eq(S().totals.obols, 60, 'obols gained')
P.xp = 950; step(1)
eq(S().totals.xp, 50, 'xp within a level')
P.level, P.xp, P.need = 51, 30, 1200; step(1)
eq(S().totals.xp, 50 + 50 + 30, 'xp across a level-up: rest of the old bar + new progress')
eq(S().totals.levels, 1, 'level counted')
local before = S().totals.xp
P.level, P.xp, P.need = 60, 0, 800; step(1)
eq(S().totals.xp - before, 1200 - 30, 'xp across a multi-level jump: rest of the old bar')
eq(S().totals.levels, 10, 'levels 50 -> 60')
before = S().totals.xp
P.xp = 500; step(1)
P.paragon, P.xp = 11, 100; step(1)
eq(S().totals.xp - before, 500 + 300 + 100, 'xp across a paragon step')
eq(S().totals.paragon, 1, 'paragon step counted')
P.dead = true; step(1); step(1)
P.dead = false; step(1)
eq(S().totals.deaths, 1, 'one death per is_dead edge')
local tl = collector.state().feed.timeline
ok(tl[1].kind == 'death', 'death on the timeline')

-- 3. Events: pit, bosses, helltide, undercity, hordes, whispers, rosie -----
W.name, W.zone = 'PIT_Subzone_01', 'PIT_Subzone_01'
emit('arkham', 'pit_start', {level = 98})
step(1)
eq(collector.state().act, 'pit', 'pit world -> activity pit')
emit('arkham', 'pit_floor', {gen = 2}); emit('arkham', 'glyph_upgraded', {hash = 1, from = 10, to = 11})
step(1)
local data = payload.build(collector.state(), EPOCH)
eq(data.session.now.activity, 'pit', 'session.now activity')
eq(data.session.now.plugin, 'arkham', 'session.now plugin')
eq(data.session.now.title, 'Pit Tier 98', 'session.now title')
eq(data.session.now.step, 'Floor 2', 'session.now step')
eq(data.plugins.arkham.state, 'running', 'arkham card running')
eq(data.plugins.arkham.ver, '2.1.1', 'plugin version from status')
eq(data.plugins.reaper.state, 'disabled', 'an erroring status reads as disabled (unreadable)')
eq(data.plugins.wonder.state, 'stopped', 'an absent plugin is stopped'); eq(data.plugins.wonder.kv[1][2], 'no', 'absent plugin: Loaded no')
step(300)
emit('arkham', 'pit_end', {secs = 330, boss = true, glyph = true, level = 98, timeout = false})
step(1)
local pit = S().activities.pit
eq(pit.runs, 1, 'pit runs'); eq(pit.ok, 1, 'pit ok'); eq(pit.best, 98, 'pit best tier')
eq(pit.time, 330, 'pit time'); eq(pit.extra.glyphs_up, 1, 'pit glyphs_up')
emit('arkham', 'pit_start', {level = 101}); step(1)
emit('arkham', 'pit_end', {secs = 900, boss = false, timeout = true, level = 101}); step(1)
eq(pit.failed, 1, 'timed out pit is failed')
eq(pit.best, 98, 'a failed tier is not a best')
local alerts = collector.state().feed.alerts
ok(alerts[1].code == 'pit_timeout' and alerts[1].resolved == false, 'pit timeout alert raised')
emit('arkham', 'pit_start', {level = 98}); step(1)
emit('arkham', 'pit_end', {secs = 300, boss = true, level = 98}); step(1)
ok(alerts[1].resolved == true, 'a later successful pit resolves the alert')

W.name, W.zone = 'Sanctuary_Eastern_Continent', 'Boss_WT4_Duriel'
for _ = 1, 2 do
    emit('reaper', 'boss_summoned', {boss = 'duriel', label = 'Duriel'}); step(1)
    emit('reaper', 'boss_killed', {boss = 'duriel', label = 'Duriel', tier = 'T4', secs = 60}); step(1)
end
local bosses = S().activities.bosses
eq(bosses.runs, 2, 'boss runs'); eq(bosses.ok, 2, 'boss kills')
eq(bosses.extra.by_boss.Duriel, 2, 'by_boss counts')

W.zone = 'Kehj_Gea_Kul'
P.buffs = {{name_hash = 1066539}}
step(1)
eq(collector.state().act, 'helltide', 'helltide buff -> activity helltide')
emit('helltide', 'helltide_done', {hour = 1, zone = 'kehj', earned = 1120, spent = 900, lost = 0, chests = 12,
    mystery = 2, deaths = 0, tears = 1, secs = 3300})
step(1)
local ht = S().activities.helltide
eq(ht.runs, 1, 'helltide runs'); eq(ht.best, 1120, 'helltide best cinders')
eq(ht.extra.chests, 12, 'helltide chests'); eq(ht.extra.cinders, 1120, 'helltide cinders')
P.buffs = {}

emit('wondercity', 'undercity_start'); step(1)
emit('wondercity', 'boss_killed', {name = 'X'}); step(1)
emit('wondercity', 'undercity_end', {success = true, reason = 'done', floors = 4, secs = 540}); step(1)
local uc = S().activities.undercity
eq(uc.ok, 1, 'undercity ok'); eq(uc.best, 4, 'undercity best floor'); eq(uc.extra.bosses, 1, 'undercity bosses')

emit('hordedev', 'horde_start', {mode = 'compass'}); step(1)
emit('hordedev', 'horde_council', {bartuc = true}); emit('hordedev', 'horde_chest', {type = 'gold'})
emit('hordedev', 'horde_done', {mode = 'compass', exit = 'teleport'}); step(1)
local hd = S().activities.hordes
eq(hd.runs, 1, 'hordes runs'); eq(hd.ok, 1, 'hordes ok'); eq(hd.extra.council, 1, 'hordes council')

emit('silentraven', 'whisper_claim', {result = 'claimed', name = 'Cache', slot = 1}); step(1)
eq(S().activities.whispers.ok, 1, 'whisper claimed'); eq(S().activities.whispers.extra.caches, 1, 'caches')

emit('warpug', 'plan_created', {path = 'pit>helltide>town', rerolls = 0})
emit('warpigs', 'step_start', {quest = 'The Pit'}); step(1)
data = payload.build(collector.state(), EPOCH)
eq(data.session.warplan.step, 1, 'warplan step'); eq(data.session.warplan.steps, 3, 'warplan steps from path')

emit('rosie', 'pickup', {name = 'Harlequin Crest', rarity = 6, mythic = true, ga = 1})
emit('rosie', 'pickup', {name = "Tyrael's Might", rarity = 6, ga = 2})
emit('rosie', 'pickup', {name = 'Gloves', rarity = 'legendary', ga = 3})
emit('rosie', 'pickup', {name = 'Blue ring', rarity = 3})
emit('rosie', 'pickup', {name = 'Junk', rarity = 1})
step(1)
local items = S().items
eq(items.looted, 5, 'looted')
eq(items.by_rarity.mythic, 1, 'mythic from the pickup flag')
eq(items.by_rarity.unique, 1, 'unique')
eq(items.by_rarity.legendary, 1, 'legendary')
eq(items.by_rarity.rare, 1, 'rare'); eq(items.by_rarity.magic, 1, 'magic')
eq(items.greater_affix.ga1, 1, 'ga1'); eq(items.greater_affix.ga2, 1, 'ga2'); eq(items.greater_affix.ga3, 1, 'ga3')
local drops = collector.state().feed.drops
eq(#drops, 3, 'legendary+ are notable drops')
eq(drops[1].name, 'Gloves', 'drops newest first')
P.town = 1
emit('rosie', 'trip_start', {caller = 'arkham', sell = true, salvage = true, stash = true, inv = 30}); step(1)
eq(collector.state().act, 'town', 'town trip -> activity town')
emit('rosie', 'stashed', {name = 'Harlequin Crest', sno = 1, bag = 'stash'})
emit('rosie', 'trip_end', {caller = 'arkham', outcome = 'success', secs = 90, sold = 1, salvaged = 2}); step(1)
eq(items.sold, 1, 'sold'); eq(items.salvaged, 2, 'salvaged'); eq(items.stashed, 1, 'stashed')
eq(drops[3].fate, 'stashed', 'stashed event updates the drop fate')
data = payload.build(collector.state(), EPOCH)
eq(data.scopes.session.items.kept, 1, 'kept = looted - salvaged - sold - stashed')
ok(collector.state().feed.timeline[1].kind == 'town', 'town trip on the timeline')
P.town = 0

-- 3b. End-to-end review regressions (3.3.0) --------------------------------
do
    local ingest = require 'core.wr_ingest'
    local A = S().activities
    local tl_has = function(text)
        for _, r in ipairs(collector.state().feed.timeline) do if r.text:find(text, 1, true) then return true end end
        return false
    end
    -- A War Plan Helltide slice: HR is switched off after its quest, so its
    -- hour record (helltide_done) comes long after the bot left. The visit
    -- itself is the run; the late record adds chests / cinders, no 2nd run.
    local runs0, ok0 = A.helltide.runs, A.helltide.ok
    W.name, W.zone = 'Sanctuary_Eastern_Continent', 'Kehj_Gea_Kul'
    P.buffs = {{name_hash = 1066539}}; step(1)
    for _ = 1, 20 do step(10) end
    P.buffs = {}; step(1)
    eq(A.helltide.runs, runs0, 'a visit is not counted while the bot may come back')
    P.town = 1; step(60); P.town = 0 -- a town trip in the middle
    P.buffs = {{name_hash = 1066539}}; step(1)
    for _ = 1, 6 do step(10) end
    P.buffs = {}; step(1)
    for _ = 1, 13 do step(10) end
    eq(A.helltide.runs, runs0 + 1, 'the Helltide visit (with a town trip inside) is one run')
    eq(A.helltide.ok, ok0 + 1, 'the visit is done')
    local chests0 = A.helltide.extra.chests
    emit('helltide', 'helltide_done', {hour = 2, zone = 'kehj', earned = 1500, spent = 0, lost = 0, chests = 9,
        mystery = 0, deaths = 0, tears = 0, secs = 400}); step(1)
    eq(A.helltide.runs, runs0 + 1, 'a late hour record counts no second run')
    eq(A.helltide.extra.chests, chests0 + 9, 'the late record adds its chests'); eq(A.helltide.best, 1500, 'and its best')
    ok(tl_has('Helltide hour closed'), 'the hour record is on the timeline')
    -- A long Rosie trip (over the away grace) from inside a Helltide keeps the visit.
    runs0 = A.helltide.runs
    P.buffs = {{name_hash = 1066539}}; step(1)
    for _ = 1, 10 do step(10) end
    P.buffs = {}; P.town = 1
    emit('rosie', 'trip_start', {caller = 'automatic', sell = 3, salvage = 9, stash = 0, inv = 30}); step(1)
    for _ = 1, 20 do step(10) end
    emit('rosie', 'trip_end', {caller = 'automatic', outcome = 'completed', secs = 200, sold = 3, salvaged = 9})
    step(1); P.town = 0
    P.buffs = {{name_hash = 1066539}}; step(1)
    for _ = 1, 10 do step(10) end
    P.buffs = {}; step(1)
    for _ = 1, 13 do step(10) end
    eq(A.helltide.runs, runs0 + 1, 'a Helltide with a 200 s town trip inside is one run')
    runs0 = runs0 + 1
    -- Passing through a Helltide zone (under a minute) is not a run.
    P.buffs = {{name_hash = 1066539}}; step(1); step(20)
    P.buffs = {}; step(1)
    for _ = 1, 13 do step(10) end
    eq(A.helltide.runs, runs0, 'a short pass through is not a Helltide run')

    -- SilentRaven: WarPigs looks for Whispers after every turn-in; nothing
    -- to claim / a cancel is not a run, a failed claim is.
    local w0, wf0 = A.whispers.runs, A.whispers.failed
    emit('silentraven', 'whisper_claim', {result = 'skipped_not_ready', reason = 'no_completed_whispers'})
    emit('silentraven', 'whisper_claim', {result = 'skipped_busy'})
    emit('silentraven', 'whisper_claim', {result = 'cancelled', reason = 'left_temis'}); step(1)
    eq(A.whispers.runs, w0, 'skipped / cancelled Whisper visits are not runs')
    emit('silentraven', 'whisper_claim', {result = 'unconfirmed', reason = 'receipt_unconfirmed'}); step(1)
    eq(A.whispers.failed, wf0 + 1, 'an unconfirmed claim is a failed run')

    -- Reaper: a summoned boss whose run is cancelled is a failed run (no alert).
    local b0, bf0 = A.bosses.runs, A.bosses.failed
    emit('reaper', 'boss_summoned', {boss = 'duriel', label = 'Duriel'}); step(1)
    emit('reaper', 'run_end', {result = 'cancelled', reason = 'stopped', mode = 'run_once'}); step(1)
    eq(A.bosses.runs, b0 + 1, 'the summon counted the run'); eq(A.bosses.failed, bf0 + 1, 'cancelled after summon: failed')
    eq(collector.state().open.bosses, nil, 'no boss run left open')
    for _, a in ipairs(collector.state().feed.alerts) do ok(a.code ~= 'run_failed', 'a cancel raises no alert') end
    emit('reaper', 'run_end', {result = 'failed', reason = 'altar', mode = 'run_boss'}); step(1)
    eq(A.bosses.runs, b0 + 1, 'a failed run with no boss open counts nothing more')

    -- HordeDev: an entry fault before horde_start is an alert, not a run.
    local h0 = A.hordes.runs
    emit('hordedev', 'horde_fail', {msg = 'no Infernal Compass'}); step(1)
    eq(A.hordes.runs, h0, 'entry fault: no run')
    local fault
    for _, a in ipairs(collector.state().feed.alerts) do if a.code == 'horde_failed' then fault = a end end
    ok(fault and not fault.resolved, 'entry fault: alert raised')
    emit('hordedev', 'horde_start', {mode = 'warplan'}); step(1)
    emit('hordedev', 'horde_fail', {msg = 'reset failed'}); step(1)
    eq(A.hordes.runs, h0 + 1, 'a started Horde that fails is one run'); ok(A.hordes.failed >= 1, 'and failed')

    -- Arkham: the pit portal confirmed again before the bot got in is one run.
    local p0 = A.pit.runs
    emit('arkham', 'pit_start', {level = 60}); step(1)
    emit('arkham', 'pit_start', {level = 60}); step(1)
    eq(A.pit.runs, p0 + 1, 'a re-opened (not entered) pit is the same run')
    W.name, W.zone = 'PIT_Subzone_01', 'PIT_Subzone_01'; step(1)
    emit('arkham', 'pit_end', {secs = 200, boss = true, level = 60}); step(1)
    W.name, W.zone = 'Sanctuary_Eastern_Continent', 'Kehj_Gea_Kul'
    emit('arkham', 'pit_start', {level = 60}); step(1)
    eq(A.pit.runs, p0 + 2, 'the next pit is a new run')
    W.name, W.zone = 'PIT_Subzone_01', 'PIT_Subzone_01'; step(1)
    emit('arkham', 'pit_start', {level = 60}); step(1)
    eq(A.pit.runs, p0 + 3, 'a pit_start after the bot was inside is a new run')
    emit('arkham', 'pit_end', {secs = 100, boss = true, level = 60}); step(1)
    W.name, W.zone = 'Sanctuary_Eastern_Continent', 'Kehj_Gea_Kul'

    -- Rosie: a legendary without a greater affix is not a notable drop.
    local d0 = #collector.state().feed.drops
    emit('rosie', 'pickup', {name = 'Plain legendary', rarity = 5, ga = 0}); step(1)
    eq(#collector.state().feed.drops, d0, 'a 0-GA legendary is counted, not listed')
    -- Rosie's stash reports the internal name; the SNO finds the drop.
    emit('rosie', 'pickup', {name = 'Shroud of False Death', sno = 4242, rarity = 6, ga = 1}); step(1)
    emit('rosie', 'stashed', {name = 'Chest_Unique_Generic_042', sno = 4242, bag = 'equipment'}); step(1)
    local shroud = collector.state().feed.drops[1]
    eq(shroud.name, 'Shroud of False Death', 'the picked drop is listed'); eq(shroud.fate, 'stashed', 'stashed by SNO')
    eq(#collector.state().feed.drops, d0 + 1, 'no second (internal name) row for the stashed drop')
    table.remove(collector.state().feed.drops, 1) -- keep the later persistence counts
    -- WarPigs: a plugin that finished its run gives the lease back.
    emit('warpigs', 'plugin_enabled', {plugin = 'ReaperPlugin', reason = 'boss'}); step(1)
    eq(collector.state().counters.lease, 'ReaperPlugin', 'lease holder')
    emit('warpigs', 'plugin_finished', {plugin = 'ReaperPlugin'}); step(1)
    eq(collector.state().counters.lease, nil, 'finished: no lease holder')
    -- A trip_start whose trip_end never comes stops holding 'town'.
    emit('rosie', 'trip_start', {caller = 'automatic', sell = 0, salvage = 0, stash = 0, inv = 3}); step(1)
    eq(collector.state().act, 'town', 'trip -> town')
    for _ = 1, math.ceil(collector.TRIP_STALE / 20) + 1 do step(20) end
    ok(collector.state().act ~= 'town', 'a trip without its end is dropped after TRIP_STALE: ' .. collector.state().act)
    eq(ingest.HELLTIDE_AWAY, 120, 'Helltide away grace')
end

-- 4. Plugin status alerts (raise + resolve) --------------------------------
ST.rosie.stuck, ST.rosie.stuck_reason = true, 'vendor unreachable'
step(3)
local found
for _, a in ipairs(collector.state().feed.alerts) do if a.code == 'town_stuck' then found = a end end
ok(found and not found.resolved, 'rosie stuck -> alert')
ST.rosie.stuck = false
step(3)
ok(found and found.resolved == true, 'stuck cleared -> resolved')

-- 5. Throttle: at most one poll per second ----------------------------------
local polls = 0
local real_poll = collector.poll
collector.poll = function(...) polls = polls + 1; return real_poll(...) end
for _ = 1, 10 do T = T + 0.05; collector.tick(T, {enabled = true, write_every = 15}) end
collector.poll = real_poll
ok(polls <= 1, 'no more than one poll in half a second (got ' .. polls .. ')')

-- 6. The written file: prefix, valid JSON, schema coverage, node ----------
step(20)
text = read('dashboard/suite_data.js')
ok(text and text:sub(1, #'window.SUITE_DATA = ') == 'window.SUITE_DATA = ', 'file prefix')
local body = text and text:match('^window%.SUITE_DATA = (.*);\n$')
ok(body ~= nil, 'one assignment ending with ;')
local okj, err = pcall(json_check, body or '')
ok(okj, 'suite_data.js body is valid JSON: ' .. tostring(err))
ok(#text <= 512 * 1024, 'file within 512 KB')
for _, key in ipairs({'"v":1', '"t":', '"write_every":15', '"suite":', '"session":', '"scopes":', '"drops":[',
    '"timeline":[', '"strip":[', '"alerts":[', '"plugins":', '"helltide":', '"hourly":[', '"by_rarity":',
    '"greater_affix":', '"rates":', '"gold_hr":', '"avg_time":', '"best_label":', '"since":', '"warplan":',
    '"next":[', '"uptime":', '"active":', '"kv":[', '"next_in":', '"file":"hr_data.js"'}) do
    ok(body and body:find(key, 1, true), 'payload has ' .. key)
end
ok(not (body or ''):find(tmp, 1, true), 'no file path in the payload')
local node = io.popen('command -v node 2>/dev/null')
local node_path = node and node:read('*l')
if node then node:close() end
if node_path and node_path ~= '' then
    local script = "const fs=require('fs'),vm=require('vm');const c={window:{}};" ..
        "vm.runInNewContext(fs.readFileSync(process.argv[1],'utf8'),c);const d=c.window.SUITE_DATA;" ..
        "if(!d||d.v!==1||!d.scopes.alltime||!Array.isArray(d.timeline))process.exit(3);console.log('ok')"
    local p = io.popen('node -e "' .. script .. '" "' .. tmp .. '/dashboard/suite_data.js" 2>&1')
    local out = p:read('*a'); p:close()
    ok(out:find('ok', 1, true) == 1, 'node evaluates suite_data.js: ' .. out)
end

-- 7. Local midnight rollover of "today" -------------------------------------
local today_gold = collector.state().scopes.today.totals.gold
ok(today_gold > 0, 'today counted gold')
local day_before = collector.state().scopes.today.day
local midnight = clock.day_start(EPOCH) + 86400
EPOCH = midnight - 2; T = T + 1; collector.tick(T, {enabled = true, write_every = 15})
eq(collector.state().scopes.today.day, day_before, 'still the same day before midnight')
T, EPOCH = T + 3, midnight + 1
P.gold = P.gold + 700
collector.tick(T, {enabled = true, write_every = 15})
eq(collector.state().scopes.today.totals.gold, 700, 'today restarted at local midnight')
ok(collector.state().scopes.today.day ~= day_before, 'today has the new day key')
ok(S().totals.gold > 700, 'session kept across midnight')
ok(collector.state().scopes.alltime.totals.gold > 700, 'all-time kept across midnight')

-- 8. Persistence: all-time + today survive a reload -------------------------
collector.save(EPOCH)
local at_gold = collector.state().scopes.alltime.totals.gold
local at_duriel = collector.state().scopes.alltime.activities.bosses.extra.by_boss.Duriel
ok(read('data/alltime.txt') ~= nil and read('data/today.txt') ~= nil, 'data files written')
collector.init()
eq(collector.state().scopes.alltime.totals.gold, at_gold, 'all-time gold restored')
eq(collector.state().scopes.alltime.activities.bosses.extra.by_boss.Duriel, at_duriel, 'by_boss restored')
eq(collector.state().scopes.today.totals.gold, 700, 'today restored on the same day')
eq(collector.state().scopes.session.totals.gold, 0, 'session starts fresh')
eq(#collector.state().feed.drops, 3, 'drops restored')
eq(collector.state().feed.drops[1].name, 'Gloves', 'drops keep their order')
-- A stale today file (yesterday) is dropped.
EPOCH = EPOCH + 86400
collector.init()
eq(collector.state().scopes.today.totals.gold, 0, "yesterday's today file is not restored")

-- 9. Resets ---------------------------------------------------------------
step(1); P.gold = P.gold + 10; step(1)
collector.tick(T + 1, {enabled = true, write_every = 15, reset = 'alltime'}); T = T + 1
eq(collector.state().scopes.alltime.totals.gold, 0, 'reset all-time')
eq(#collector.state().feed.drops, 0, 'reset all-time clears drops')

-- 10. Size cap: the lists shrink until the file fits ------------------------
local st = collector.state()
for i = 1, 300 do
    require('core.wr_feed').timeline(st.feed, EPOCH - i, 'drop', 'rosie', 'pit', string.rep('x', 150) .. i)
end
for i = 1, 200 do
    require('core.wr_feed').drop(st.feed, {t = EPOCH - i, rarity = 'legendary', name = string.rep('n', 150), ga = 1,
        src = 'pit', act = 'Pit', fate = 'kept'})
end
local full = assert(payload.encode(st, EPOCH, 512 * 1024))
ok(#full > 60000, 'a full payload is large (' .. #full .. ' bytes)')
local small = payload.encode(st, EPOCH, 40000)
ok(small ~= nil and #small <= 40000, 'payload trimmed under a 40 KB cap')
ok(pcall(json_check, small:match('^window%.SUITE_DATA = (.*);\n$')), 'trimmed payload is valid JSON')
local saved_max = store.MAX_BYTES
store.MAX_BYTES = 30000
step(20)
store.MAX_BYTES = saved_max
text = read('dashboard/suite_data.js')
ok(text and #text <= 30000, 'written file obeys the store limit')

-- 11. Disabled: nothing is polled or written; the bus backlog is skipped --
local writes = store.writes
emit('arkham', 'pit_start', {level = 5})
step(20, {enabled = false, write_every = 15})
eq(store.writes, writes + 2, 'switching off saves once (alltime + today)')
step(20, {enabled = false, write_every = 15})
eq(store.writes, writes + 2, 'nothing written while off')
local runs, gold_before = S().activities.pit.runs, S().totals.gold
P.gold = P.gold + 99999
step(1)
eq(S().activities.pit.runs, runs, 'events emitted while off are not counted')
eq(S().totals.gold, gold_before, 'gold gained while off is not counted')

-- 12. Bus overflow is survived -------------------------------------------
for i = 1, 700 do emit('rosie', 'pickup', {name = 'x' .. i, rarity = 1}) end
step(1)
ok(collector.state().lost > 0, 'lost events are counted, not fatal')

-- 13. Review regressions (3.3.0 review board D1-D8, A3, A5) ----------------
do
    local feedm = require 'core.wr_feed'
    local statsm = require 'core.wr_stats'
    local st13 = function() return collector.state() end
    local function town() W.name, W.zone = 'Sanctuary_Eastern_Continent', 'Kehj_Gea_Kul'; P.town, P.buffs = 1, {} end
    local function pit() W.name, W.zone = 'PIT_Subzone_01', 'PIT_Subzone_01'; P.town = 0 end
    town(); step(1); step(1)

    -- D2: a gap (WarRoom off 2 h, or the PC asleep 3 h) is never painted as
    -- the activity before it; the last block keeps its end.
    pit(); step(1); step(30); step(30)
    local strip = st13().feed.strip
    local pit_block = strip[#strip]
    eq(pit_block.a, 'pit', 'D2: in the pit')
    local pit_end = pit_block.e
    step(7200, {enabled = false, write_every = 15})
    town(); step(1)
    strip = st13().feed.strip
    eq(pit_block.e, pit_end, 'D2: WarRoom off 2 h: the pit block is not stretched over the gap')
    ok(strip[#strip].a ~= 'pit', 'D2: back on: a new block for what runs now')
    eq(strip[#strip].s, EPOCH, 'D2: the new block starts now, not where the pit ended')
    pit(); step(1); step(10)
    pit_block = strip[#strip]; pit_end = pit_block.e
    step(3 * 3600) -- on_update stalled (PC asleep) inside the pit
    strip = st13().feed.strip
    eq(pit_block.e, pit_end, 'D2: a 3 h sleep does not extend the pit block')
    ok(strip[#strip].a == 'pit' and strip[#strip].s == EPOCH, 'D2: a new pit block starts after the sleep')
    town(); step(1)

    -- D3: a run across local midnight (or a reset mid-run) is counted in the
    -- scope that replaced the one it started in.
    local midnight = clock.day_start(EPOCH) + 86400
    T, EPOCH = T + 1, midnight - 180; collector.tick(T, {enabled = true, write_every = 15})
    local s_runs, s_ok = S().activities.pit.runs, S().activities.pit.ok
    local a_runs = st13().scopes.alltime.activities.pit.runs
    emit('arkham', 'pit_start', {level = 70}); step(1)
    pit(); step(1)
    T, EPOCH = T + 1, midnight + 240; collector.tick(T, {enabled = true, write_every = 15})
    emit('arkham', 'pit_end', {secs = 420, boss = true, level = 70}); step(1)
    local tp = st13().scopes.today.activities.pit
    eq(tp.runs, 1, 'D3: the new day counts the run that started before midnight')
    eq(tp.ok, 1, 'D3: and its success')
    eq(S().activities.pit.runs, s_runs + 1, 'D3: session counts it once')
    eq(S().activities.pit.ok, s_ok + 1, 'D3: session success once')
    eq(st13().scopes.alltime.activities.pit.runs, a_runs + 1, 'D3: all-time counts it once')
    town(); step(1)
    emit('arkham', 'pit_start', {level = 70}); step(1)
    pit(); step(1)
    T = T + 1; collector.tick(T, {enabled = true, write_every = 15, reset = 'today'})
    emit('arkham', 'pit_end', {secs = 300, boss = true, level = 70}); step(1)
    tp = st13().scopes.today.activities.pit
    ok(tp.runs == 1 and tp.ok == 1, 'D3: reset today mid-run: 1 run, 1 ok (got ' .. tp.runs .. '/' .. tp.ok .. ')')
    town(); step(1)

    -- D4: a finished run and a notable pickup are saved on that poll, not up
    -- to SAVE_EVERY s later.
    step(1)
    local saved = st13().save_t
    emit('arkham', 'pit_start', {level = 71}); step(1)
    emit('arkham', 'pit_end', {secs = 200, boss = true, level = 71}); step(1)
    eq(st13().save_t, T, 'D4: saved on the poll that finished the run')
    ok(saved ~= T, 'D4: (not a periodic save)')
    ok((read('data/alltime.txt') or ''):find('activities.pit.best=n71', 1, true), 'D4: the finished run is in alltime.txt')
    step(1)
    emit('rosie', 'pickup', {name = 'Saved Mythic', rarity = 8, mythic = true, ga = 1}); step(1)
    eq(st13().save_t, T, 'D4: saved on the poll of a notable pickup')
    ok((read('data/alltime.txt') or ''):find('Saved Mythic', 1, true), 'D4: the drop is in alltime.txt')

    -- D5: an hour record after the visit ended is not a second run row.
    local A = S().activities
    local hr0 = A.helltide.runs
    local function run_rows()
        local n = 0
        for _, r in ipairs(st13().feed.timeline) do if r.act == 'helltide' and r.kind:match('^run_') then n = n + 1 end end
        return n
    end
    local rows0 = run_rows()
    W.zone = 'Kehj_Gea_Kul'; P.town = 0; P.buffs = {{name_hash = 1066539}}; step(1)
    for _ = 1, 10 do step(10) end
    P.buffs = {}; step(1) -- the buff ends before HR's hour record
    emit('helltide', 'helltide_done', {hour = 3, zone = 'kehj', earned = 1200, spent = 0, lost = 0, chests = 7,
        mystery = 0, deaths = 0, tears = 0, secs = 3000}); step(2)
    for _ = 1, 13 do step(10) end
    eq(A.helltide.runs, hr0 + 1, 'D5: one Helltide visit = one run')
    eq(run_rows() - rows0, 1, 'D5: one run row on the timeline for it')
    eq(st13().feed.timeline[2].kind == 'helltide_hour' or st13().feed.timeline[1].kind == 'helltide_hour'
        or (function() for _, r in ipairs(st13().feed.timeline) do if r.kind == 'helltide_hour' then return true end end end)(),
        true, 'D5: the hour record has its own kind')

    -- D7: a drop is 'picked up' until Rosie reports its fate (a salvage count
    -- is not per item): never 'kept'.
    emit('rosie', 'pickup', {name = 'Fate Unique', rarity = 6, ga = 1}); step(1)
    emit('rosie', 'trip_start', {caller = 'x', inv = 30}); step(1)
    emit('rosie', 'trip_end', {caller = 'x', outcome = 'completed', secs = 60, sold = 0, salvaged = 1}); step(1)
    local fd
    for _, d in ipairs(st13().feed.drops) do if d.name == 'Fate Unique' then fd = d end end
    eq(fd and fd.fate, 'picked up', 'D7: the drop is picked up, not kept')
    eq(feedm.fate_name('kept'), 'picked up', 'D7: an old file\'s kept loads as picked up')
    eq(feedm.fate_name('stashed'), 'stashed', 'D7: stashed stays')

    -- D8: unreadable cinders are null (n/a), not 0.
    local cinders_fn = get_helltide_coin_cinders
    get_helltide_coin_cinders = function() return nil end
    step(1)
    eq(payload.build(st13(), EPOCH).helltide.cinders, payload.NULL, 'D8: unreadable cinders -> null')
    get_helltide_coin_cinders = cinders_fn
    step(1)
    eq(payload.build(st13(), EPOCH).helltide.cinders, 321, 'D8: readable cinders')

    -- A3: a persisted best_label is not restored (always this version's label).
    local rs = statsm.restore_scope('alltime', {since = 1, activities = {pit = {runs = 1,
        best_label = '<img src=x onerror=alert(1)>'}}}, 100)
    eq(rs.activities.pit.best_label, 'Tier', 'A3: best_label from the file is dropped')
    eq(rs.activities.pit.runs, 1, 'A3: the numbers are restored')

    -- D1: the reset buttons, clicked through the real menu + on_update
    -- callbacks for one frame, on a frame that is not a poll frame.
    local function frames(n) for _ = 1, n do T, EPOCH = T + 1 / 60, EPOCH + 1 / 60; callbacks.update() end end
    local function click(btn)
        gui.elements[btn].v = true; callbacks.menu(); gui.elements[btn].v = false
        T, EPOCH = T + 1 / 60, EPOCH + 1 / 60; callbacks.update()
    end
    gui.elements.main_toggle.v = true
    frames(90)
    P.gold = P.gold + 5000; frames(90)
    ok(S().totals.gold >= 5000, 'D1: session gold before the reset')
    T = st13().last_t + 0.2 -- the next frame is 0.2 s after a poll: no poll due
    local w0 = store.writes
    click('reset_session')
    eq(S().totals.gold, 0, 'D1: Reset session works on a non-poll frame')
    ok(store.writes >= w0 + 3, 'D1: suite_data.js + the data files written at once (' .. (store.writes - w0) .. ')')
    P.gold = P.gold + 700; frames(90)
    ok(st13().scopes.alltime.totals.gold > 0, 'D1: all-time has gold')
    gui.elements.main_toggle.v = false; frames(60)
    w0 = store.writes
    click('reset_alltime')
    eq(st13().scopes.alltime.totals.gold, 0, 'D1: Reset all-time works with Enable off')
    eq(store.writes, w0 + 2, 'D1: saved at once while off (alltime + today)')
    ok((read('data/alltime.txt') or ''):find('totals.gold=n0', 1, true), 'D1: the saved all-time file is reset')
    frames(60)
    gui.elements.main_toggle.v = true; frames(120)
    eq(st13().scopes.alltime.totals.gold, 0, 'D1: nothing earned while off came back')

    -- A5: QQT_WarRoom.enabled is the Enable toggle from load (HelltideRevamped
    -- builds hr_data.js for WarRoom only while it is true).
    local saved_gui, saved_new, saved_cb = package.loaded.gui, checkbox.new, {callbacks.update, callbacks.menu}
    checkbox.new = function() return widget(false) end -- the saved Enable toggle is OFF
    package.loaded.gui = nil
    QQT_WarRoom = nil
    dofile(WR .. 'main.lua')
    eq(QQT_WarRoom.enabled, false, 'A5: enabled is false before the first pulse when the toggle is off')
    checkbox.new, package.loaded.gui = saved_new, saved_gui
    callbacks.update, callbacks.menu = saved_cb[1], saved_cb[2]
end

-- E. QQT_Warpigz_v3 3.3.3 (WarRoom 1.0.3) -------------------------------------
do
    -- E1: a set charm (QQT rarity 7, Rosie utils) is its own rarity, never a
    -- unique: it is not in the unique count nor on the drops list.
    local ingest, stats = require 'core.wr_ingest', require 'core.wr_stats'
    local st = collector.state()
    local items = st.scopes.session.items
    local unique, set, looted, ndrops = items.by_rarity.unique, items.by_rarity.set or 0, items.looted, #st.feed.drops
    ingest.handle(st, {source = 'rosie', kind = 'pickup', name = 'Set Charm', rarity = 7, ga = 0}, EPOCH)
    eq(items.looted, looted + 1, 'E1: the set charm is looted')
    eq(items.by_rarity.unique, unique, 'E1: a set charm is not a unique')
    eq(items.by_rarity.set, set + 1, 'E1: counted as set')
    eq(#st.feed.drops, ndrops, 'E1: a set charm is not a notable drop')
    local v = stats.view(st.scopes.session, st.flags, require 'core.wr_json')
    eq(v.items.by_rarity.set, set + 1, 'E1: set in the payload view')
    eq(stats.rarity('Set'), 'set', 'E1: string rarity Set')
    eq(stats.rarity(6), 'unique', 'E1: rarity 6 stays unique'); eq(stats.rarity(8), 'mythic', 'E1: rarity 8 mythic')

    -- E2: WarRoom never calls LooteerPlugin.status(): Rosie's pickup status
    -- runs Settings.update() and expires other plugins' pauses, and WarRoom
    -- never used what it returned.
    local plugins = require 'core.wr_plugins'
    local calls = 0
    local saved = LooteerPlugin
    LooteerPlugin = {status = function() calls = calls + 1; return {enabled = true} end}
    plugins.read_all()
    eq(calls, 0, 'E2: LooteerPlugin.status is never called')
    LooteerPlugin = saved

    -- E3: a claim ended by SilentRaven's Enable toggle is no run.
    local wh = st.scopes.session.activities.whispers
    local runs, failed_runs = wh.runs, wh.failed
    ingest.handle(st, {source = 'silentraven', kind = 'whisper_claim', result = 'disabled'}, EPOCH)
    eq(wh.runs, runs, 'E3: disabled is not a run'); eq(wh.failed, failed_runs, 'E3: nor a failure')

    -- E4: a loaded scope with a string counter or a number in place of a
    -- table restores only what fits, and the payload still builds.
    local bad = {since = 1, totals = {gold = 'lots'}, items = {by_rarity = 5, looted = 'x'},
        activities = {pit = {runs = 'many', ok = 2, extra = 7}}}
    local sc = stats.restore_scope('alltime', bad, EPOCH)
    eq(sc.totals.gold, 0, 'E4: string total ignored'); eq(type(sc.items.by_rarity), 'table', 'E4: by_rarity stays a table')
    eq(sc.activities.pit.runs, 0, 'E4: string runs ignored'); eq(sc.activities.pit.ok, 2, 'E4: numbers restored')
    eq(type(sc.activities.pit.extra), 'table', 'E4: extra stays a table')
    local saved_scope = st.scopes.alltime
    st.scopes.alltime = sc
    ok(collector.render(EPOCH) ~= nil, 'E4: the payload builds with a restored bad scope')
    stats.add_item(st, 'rare', 0, EPOCH)
    st.scopes.alltime = saved_scope

    -- E5: a payload that cannot be built is logged once.
    local saved_build = payload.build
    payload.build = function() error('probe') end
    local n0 = #logs
    collector.write(EPOCH); collector.write(EPOCH)
    local lines = 0
    for i = n0 + 1, #logs do if logs[i]:find('could not be built', 1, true) then lines = lines + 1 end end
    eq(lines, 1, 'E5: one log line for a payload that cannot be built')
    payload.build = saved_build
end

-- E6: a collector error switches WarRoom off, and QQT_WarRoom.enabled with it
-- (HelltideRevamped writes hr_data.js only while it is true).
do
    local saved_tick = collector.tick
    collector.tick = function() error('probe') end
    QQT_WarRoom.enabled = true
    gui.elements.main_toggle.v = true
    callbacks.update()
    eq(QQT_WarRoom.enabled, false, 'E6: enabled is false once the collector is off')
    collector.tick = saved_tick
end

os.execute('rm -rf "' .. tmp .. '"')
if #failed > 0 then error('WarRoom collector: ' .. #failed .. ' failed:\n  ' .. table.concat(failed, '\n  ')) end
print('WarRoom collector: ' .. passed .. ' checks passed')
