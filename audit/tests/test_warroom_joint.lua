-- QQT_Warpigz_v3 (3.3.0): WarRoom end to end in the joint host. The REAL
-- plugins (all ten, Rosie included) and the REAL WarRoom plugin load
-- together; the suite runs a whole day slice and the test decodes the
-- dashboard/suite_data.js WarRoom wrote and checks it against what happened:
--   W1 War Plan: a Whisper claim in Temis -> WarPug plan -> the Pit (boss
--      killed, Rosie picks up a mythic / unique / legendary) -> Undercity ->
--      War Plan Infernal Horde -> Reaper lair (Andariel) -> a Helltide slice
--      that closes its hour (helltide_done) -> turn-in; then a Rosie town
--      trip (salvage), a death. Gold / XP read from the player. Every
--      Overview counter, the activity table, the items panel, the drops, the
--      timeline and the plugin cards match the event log and the host's own
--      record; the file is `window.SUITE_DATA = <JSON>;` within 512 KB.
--      WARROOM_DUMP=<dir> also writes the file (for the headless render).
--   W2 WarRoom is invisible to the bot: the same Pit run with WarRoom
--      switched off writes nothing, and with WarRoom broken (every status
--      and poll raises) no error reaches another plugin.
--   W3 HelltideRevamped: with WarRoom loaded hr_data.js is written into
--      WarRoom/dashboard/; without WarRoom (standalone) into its own folder,
--      and no bus exists (every emit is a no-op).
-- Runs under Lua 5.4 and LuaJIT.
local ROOT = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local J = dofile(ROOT .. '/audit/tests/joint_host.lua')
local checks, failures = 0, {}
local function ok(value, message)
    if not value then error(message or 'expected a true value', 2) end
    checks = checks + 1
end
local function eq(actual, expected, message)
    if actual ~= expected then
        error((message or 'mismatch') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
    end
    checks = checks + 1
end
local ONLY = os.getenv('JOINT_ONLY')
local function case(name, fn)
    if ONLY and ONLY ~= '' and not name:find(ONLY, 1, true) then return end
    local started = os.clock()
    local passed, err = xpcall(fn, debug.traceback)
    if passed then print(string.format('PASS warroom joint: %s (%.1fs)', name, os.clock() - started))
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL warroom joint: ' .. name .. ': ' .. tostring(err)) end
end

-- ── a strict JSON decoder (the file must be plain JSON after the prefix) ──
local function json_decode(text)
    local pos = 1
    local function fail(msg) error('JSON: ' .. msg .. ' at ' .. pos, 0) end
    local function ws() pos = text:find('[^ \t\r\n]', pos) or (#text + 1) end
    local value
    local function str()
        local out = {}
        pos = pos + 1
        while true do
            local c = text:sub(pos, pos)
            if c == '' then fail('unterminated string') end
            if c == '"' then pos = pos + 1; return table.concat(out) end
            if c == '\\' then
                local e = text:sub(pos + 1, pos + 1)
                local map = {['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t'}
                if e == 'u' then
                    local hex = text:sub(pos + 2, pos + 5)
                    if not hex:match('^%x%x%x%x$') then fail('bad \\u') end
                    local cp = tonumber(hex, 16)
                    out[#out + 1] = cp < 128 and string.char(cp) or '?'
                    pos = pos + 6
                elseif map[e] then out[#out + 1] = map[e]; pos = pos + 2
                else fail('bad escape') end
            else
                if c:byte() < 32 then fail('control character') end
                out[#out + 1] = c; pos = pos + 1
            end
        end
    end
    value = function()
        ws()
        local c = text:sub(pos, pos)
        if c == '{' then
            local t = {}
            pos = pos + 1; ws()
            if text:sub(pos, pos) == '}' then pos = pos + 1; return t end
            while true do
                ws()
                if text:sub(pos, pos) ~= '"' then fail('key expected') end
                local k = str(); ws()
                if text:sub(pos, pos) ~= ':' then fail(': expected') end
                pos = pos + 1
                t[k] = value(); ws()
                local d = text:sub(pos, pos); pos = pos + 1
                if d == '}' then return t end
                if d ~= ',' then fail(', or } expected') end
            end
        elseif c == '[' then
            local t = {n = 0}
            pos = pos + 1; ws()
            if text:sub(pos, pos) == ']' then pos = pos + 1; return t end
            while true do
                t.n = t.n + 1
                t[t.n] = value(); ws()
                local d = text:sub(pos, pos); pos = pos + 1
                if d == ']' then return t end
                if d ~= ',' then fail(', or ] expected') end
            end
        elseif c == '"' then return str()
        elseif text:sub(pos, pos + 3) == 'true' then pos = pos + 4; return true
        elseif text:sub(pos, pos + 4) == 'false' then pos = pos + 5; return false
        elseif text:sub(pos, pos + 3) == 'null' then pos = pos + 4; return nil
        else
            local num = text:match('^-?%d+%.?%d*[eE]?[-+]?%d*', pos)
            if not num or num == '' then fail('value expected') end
            pos = pos + #num
            return tonumber(num)
        end
    end
    local v = value(); ws()
    if pos <= #text then fail('trailing text') end
    return v
end

local WP, PUG, SR, ARK, HR, WR = 'WarPigs', 'WarPug', 'SilentRaven', 'ArkhamAsylum', 'HelltideRevamped', 'WarRoom'
local HORDE_Q = 'WarPlans_QST_InfernalHordes_BSK'
local SUITE_FILE = ROOT .. '/WarRoom/dashboard/suite_data.js'
local HR_WR_FILE = ROOT .. '/WarRoom/dashboard/hr_data.js'
local HR_OWN_FILE = ROOT .. '/HelltideRevamped/dashboard/hr_data.js'

local function el(h, dir)
    local mod = dir == SR and 'silent_raven.gui' or 'gui'
    return assert(h.mod(dir, mod), 'gui of ' .. dir).elements
end
local function with_warroom(extra)
    local dirs = {}
    for _, d in ipairs(J.DIRS) do dirs[#dirs + 1] = d end
    for _, d in ipairs(extra or {}) do dirs[#dirs + 1] = d end
    table.sort(dirs)
    return dirs
end
-- The player's gold / XP getters (not in the shared host: no plugin but
-- WarRoom reads them).
local function money(h)
    h.gold, h.level, h.xp, h.xp_need = 5000000, 60, 1000, 100000
    local p = h.G.get_local_player()
    function p:get_gold() return h.gold end
    function p:get_level() return h.level end
    function p:get_current_experience() return h.xp end
    function p:get_experience_total_next_level() return h.xp_need end
end
local function suite(h)
    local text = h.mem_files[SUITE_FILE]
    ok(type(text) == 'string' and #text > 0, 'suite_data.js written')
    local body = text:match('^window%.SUITE_DATA = (.*);\n$')
    ok(body ~= nil, 'suite_data.js is `window.SUITE_DATA = ...;`: ' .. text:sub(1, 60))
    ok(#text <= 512 * 1024, 'within 512 KB')
    return json_decode(body), text
end
local function writes_to(h, path)
    local n = 0
    for _, w in ipairs(h.file_writes) do if w.path == path then n = n + 1 end end
    return n
end
local function count(list, pred)
    local n = 0
    for i = 1, list.n or #list do if pred(list[i]) then n = n + 1 end end
    return n
end

case('W1 a War Plan day with WarRoom loaded: suite_data.js counters match what happened', function()
    local Q = {pit = 'WarPlans_QST_ThePit', uc = 'WarPlans_QST_Undercity', boss = 'WarPlans_QST_BossLair_Andariel',
        ht = 'WarPlans_QST_Helltide_TorturedGifts', turn = 'WarPlans_QST_TurnIn_Rewards'}
    local DEST = {[Q.uc] = 'kurast', [HORDE_Q] = 'bsk', [Q.boss] = 'lair', [Q.ht] = 'helltide'}
    local h = J.new({dirs = with_warroom({WR}), rosie = true, virtual_os_time = true})
    h.assert_clean('load')
    local room = rawget(h.G, 'QQT_WarRoom')
    ok(type(room) == 'table' and room.dashboard_dir == ROOT .. '/WarRoom/dashboard/', 'QQT_WarRoom.dashboard_dir: '
        .. tostring(room and room.dashboard_dir))
    local bus = rawget(h.G, 'QQT_Warpigz_events')
    ok(type(bus) == 'table' and type(bus.ring) == 'table', 'WarRoom created the bus at load')
    -- Ground truth: every event, through the bus hook WarRoom leaves free.
    local log = {}
    bus.on_emit = function(e) log[#log + 1] = e end
    money(h)
    local CONSUMER = {name = 'Consumer', dir = ROOT .. '/audit/tests/', loaded = {}}
    eq(h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end), true, 'RosiePlugin.enable()')
    h.mod('Rosie', 'rosie.private.pickup.gui').elements.general.distance_slider:set(30)
    el(h, WP).main_toggle:set(true)
    el(h, PUG).main_toggle:set(true)
    el(h, SR).main_toggle:set(true)
    el(h, ARK).pit_level:set(37)
    el(h, HR).dashboard:set(true) -- HelltideRevamped 'Web dashboard' (off by default)
    h.setup_undercity()
    local A = h.setup_horde({next_quest = Q.boss})
    h.setup_lair(function(hh) hh.at(3, function() hh.set_quests({Q.ht}) end) end, {altar_stays = true})
    for i = 1, 4 do h.actor('pit', 'Pit_Monster_' .. i, 20 + i * 15, (i % 2) * 6, {enemy = true}) end
    local pit_boss = h.actor('pit', 'Pit_Boss_Joint', 90, 0, {enemy = true, boss = true, health = 200})
    local dropped = {}
    -- The boss leaves the glyph gizmo and its loot: a mythic, a unique and a 3-GA legendary.
    pit_boss.on_death = function()
        local x, y = pit_boss.pos:x(), pit_boss.pos:y()
        h.actor('pit', 'Gizmo_Paragon_Glyph_Upgrade', x + 2, y + 2)
        dropped[#dropped + 1] = h.drop('pit', x + 3, y, {name = 'Mythic_Joint_Helm', display = 'Harlequin Crest',
            rarity = 8, ancestral = true, ga = 1, sno = 990777001})
        dropped[#dropped + 1] = h.drop('pit', x - 3, y, {name = 'Helm_Legendary_Generic_009', display = 'Tyrael\'s Might',
            rarity = 6, ancestral = true, ga = 2, sno = 990777002})
        dropped[#dropped + 1] = h.drop('pit', x, y + 3, {name = 'Helm_Legendary_Generic_010',
            display = 'Gloves of the Illuminator', rarity = 5, ancestral = true, ga = 3, sno = 990777003})
    end
    for i = 1, 3 do h.actor('undercity', 'Undercity_Monster_' .. i, 25 + i * 20, 0, {enemy = true}) end
    h.warplan_dest = function(hh) return DEST[hh.quests[1]] end
    h.P.helltide.helltide = true
    -- The Whisper claim first; the confirmed War Plan starts with the Pit.
    h.bounty_ready = true
    h.on_confirm = function() h.at(1.0, function() h.set_quests({Q.pit}) end) end
    local hr_clock = h.mod(HR, 'core.hr_clock')
    local phase, since = 'pit', nil
    ok(h.run_until(function()
        if phase == 'pit' and h.place == h.P.pit then
            since = since or h.now
            if not dropped.pit then
                dropped.pit = true
                h.gold = h.gold + 250000
            end
            local all = #dropped == 3
            for _, d in ipairs(dropped) do all = all and d.picked == true end
            if h.now - since > 40 and pit_boss.health <= 0 and (all or h.now - since > 150) and not h.travel then
                h.xp = h.xp + 40000
                h.set_quests({Q.uc}); h.travel_to('temis', 1.0, 'pit_exit'); phase, since = 'uc', nil
            end
        elseif phase == 'uc' and h.place == h.P.undercity then
            since = since or h.now
            if h.now - since > 30 and not h.travel and not h.alfred.job then
                h.gold = h.gold + 100000
                h.set_quests({HORDE_Q}); h.travel_to('kurast', 1.0, 'undercity_exit'); phase, since = 'rest', nil
            end
        elseif phase == 'rest' and h.quests[1] == Q.ht and h.place == h.P.helltide then
            since = since or h.now
            if h.now - since > 40 and not dropped.hour then
                -- The Helltide hour ends while the bot is inside: HR closes the record.
                dropped.hour = true
                h.xp = h.xp + 70000 -- crosses the level: 1,000 + 40,000 + 70,000 > 100,000
                h.level = 61
                h.xp = h.xp - 100000
                local base = h.G.os.time() -- the simulated clock HR reads
                hr_clock._now = function() return base + 3600 end
            end
            if h.now - since > 50 then h.set_quests({Q.turn}); phase = 'turn' end
        elseif phase == 'turn' and #h.quests == 0 then
            return true
        end
        return false
    end, 1800), 'the whole plan and the turn-in (phase ' .. phase .. ')\n' .. h.tail())
    h.run(3)
    -- The plan is over: no next plan, the orchestrator off (a manual trip next).
    h.on_confirm = nil
    el(h, PUG).main_toggle:set(false)
    el(h, WP).main_toggle:set(false)
    h.run(3)
    -- A Rosie town trip (salvage) asked by a consumer, and a death.
    h.inventory = {}
    for _ = 1, 6 do h.inventory[#h.inventory + 1] = h.gear() end
    local trip
    local accepted, why = h.as(CONSUMER, function()
        return h.G.AlfredTheButlerPlugin.trigger_tasks_with_teleport('Consumer', function(r) trip = {r} end)
    end)
    eq(accepted, true, 'trip accepted (' .. tostring(why) .. ')')
    ok(h.run_until(function() return trip ~= nil end, 120), 'trip finished\n' .. h.tail())
    h.gold = h.gold - 20000
    h.dead = true; h.run(3); h.dead = false
    h.run(20)
    h.assert_clean('W1')

    -- ── what happened (the event log and the host) ──
    local by = {}
    for _, e in ipairs(log) do
        local k = e.source .. '.' .. e.kind
        by[k] = by[k] or {}
        by[k][#by[k] + 1] = e
    end
    local function n(k) return by[k] and #by[k] or 0 end
    eq(n('arkham.pit_start'), 1, 'one pit opened')
    eq(n('arkham.pit_end'), 1, 'one pit_end'); eq(by['arkham.pit_end'][1].boss, true, 'pit boss killed')
    eq(n('wondercity.undercity_end'), 1, 'one Undercity')
    eq(n('hordedev.horde_done'), 1, 'one Horde')
    eq(n('reaper.boss_killed'), 1, 'one boss')
    eq(n('helltide.helltide_done'), 1, 'the Helltide hour closed: ' .. h.tail(20))
    eq(by['silentraven.whisper_claim'][1].result, 'success', 'the Whisper claim')
    for i = 2, n('silentraven.whisper_claim') do
        -- WarPigs looks again after the turn-in: nothing to claim is not a failed run.
        ok(by['silentraven.whisper_claim'][i].result:sub(1, 8) == 'skipped_', 'later Whisper visits skipped')
    end
    local picked = 0
    for _, d in ipairs(dropped) do if d.picked then picked = picked + 1 end end
    eq(picked, 3, 'Rosie picked up the three drops')
    eq(n('rosie.pickup'), 3, 'three pickup events')
    eq(n('rosie.trip_end'), 1, 'one town trip'); eq(by['rosie.trip_end'][1].outcome, 'completed')

    -- ── what WarRoom wrote ──
    local D, text = suite(h)
    eq(D.v, 1, 'schema'); ok(D.t > 0 and D.write_every == 15, 'header')
    local s = D.scopes.session
    local acts = s.activities
    local uc_ok = by['wondercity.undercity_end'][1].success == true
    eq(acts.pit.runs, 1, 'pit runs'); eq(acts.pit.ok, 1, 'pit ok'); eq(acts.pit.failed, 0, 'pit failed')
    eq(acts.pit.best, 37, 'best pit tier'); eq(acts.pit.best_label, 'Tier')
    ok(acts.pit.time >= 40 and acts.pit.avg_time == acts.pit.time, 'pit time ' .. acts.pit.time)
    eq(acts.undercity.runs, 1, 'undercity runs'); eq(acts.undercity.ok, uc_ok and 1 or 0, 'undercity ok')
    eq(acts.hordes.runs, 1, 'horde runs'); eq(acts.hordes.ok, 1, 'horde ok')
    eq(acts.hordes.extra.council, 1, 'council'); eq(acts.hordes.extra.pylons, 6, 'pylons')
    eq(acts.hordes.extra.chests, #A.opened, 'horde chests')
    eq(acts.bosses.runs, 1, 'boss runs'); eq(acts.bosses.ok, 1, 'boss ok'); eq(acts.bosses.failed, 0, 'boss failed')
    eq(acts.bosses.extra.by_boss.Andariel, 1, 'by_boss Andariel'); eq(acts.bosses.extra.chests, 1, 'boss chest')
    local hd = by['helltide.helltide_done'][1]
    eq(acts.helltide.runs, 1, 'helltide runs'); eq(acts.helltide.ok, 1, 'helltide ok')
    eq(acts.helltide.extra.chests, hd.chests or 0, 'helltide chests')
    eq(acts.whispers.runs, 1, 'whisper runs'); eq(acts.whispers.ok, 1); eq(acts.whispers.extra.caches, 1, 'caches')
    -- Overview "Activities done": ok summed; failed; runs.
    local done, runs, failed = 0, 0, 0
    for _, a in pairs(acts) do done, runs, failed = done + a.ok, runs + a.runs, failed + a.failed end
    eq(done, 5 + (uc_ok and 1 or 0), 'activities done')
    eq(runs, 6, 'activities started'); eq(failed, uc_ok and 0 or 1, 'activities failed')
    -- Gold, XP, deaths.
    eq(s.totals.gold, 350000, 'gold farmed'); eq(s.totals.gold_spent, 20000, 'gold spent')
    eq(s.totals.xp, 110000, 'xp across the level-up'); eq(s.totals.levels, 1, 'one level')
    eq(s.totals.deaths, 1, 'one death')
    ok(s.rates.gold_hr > 0, 'gold rate')
    -- Items.
    eq(s.items.looted, 3, 'items looted'); eq(s.items.by_rarity.mythic, 1); eq(s.items.by_rarity.unique, 1)
    eq(s.items.by_rarity.legendary, 1)
    eq(s.items.greater_affix.ga1, 1); eq(s.items.greater_affix.ga2, 1)
    eq(s.items.salvaged, 6, 'salvaged on the trip'); eq(#h.salvaged, 6)
    eq(D.drops.n, 3, 'notable drops: the mythic, the unique, the 3-GA legendary')
    local drop_by = {}
    for i = 1, D.drops.n do drop_by[D.drops[i].rarity] = D.drops[i] end
    ok(drop_by.mythic and drop_by.unique and drop_by.legendary, 'one drop per rarity')
    eq(drop_by.mythic.name, 'Harlequin Crest', 'the display name'); eq(drop_by.mythic.src, 'pit', 'dropped in the pit')
    eq(drop_by.unique.ga, 2); eq(drop_by.legendary.ga, 3); eq(drop_by.mythic.fate, 'picked up')
    ok(drop_by.mythic.act:find('Pit', 1, true) ~= nil, 'drop act ' .. tostring(drop_by.mythic.act))
    -- Timeline kinds and the plugin cards.
    local kinds = {}
    for i = 1, D.timeline.n do kinds[D.timeline[i].kind] = (kinds[D.timeline[i].kind] or 0) + 1 end
    eq(kinds.run_ok, 5 + (uc_ok and 1 or 0), 'run_ok rows'); eq(kinds.death, 1, 'death row'); eq(kinds.town, 1, 'town row')
    ok((kinds.drop or 0) >= 2 and (kinds.plan or 0) >= 3 and (kinds.level or 0) == 1, 'drop / plan / level rows')
    for i = 1, D.timeline.n do
        local r = D.timeline[i]
        ok(type(r.t) == 'number' and type(r.text) == 'string' and type(r.plugin) == 'string' and type(r.act) == 'string',
            'timeline row types')
    end
    for key, p in pairs(D.plugins) do
        ok(type(p.name) == 'string' and type(p.state) == 'string' and p.kv.n ~= nil, 'plugin card ' .. key)
        ok(p.state ~= 'stopped', key .. ' is loaded: ' .. p.state)
        for i = 1, p.kv.n do ok(p.kv[i].n == 2 and type(p.kv[i][2]) == 'string', key .. ' kv row') end
    end
    local st = h.mod(WR, 'core.wr_collector').state()
    for key, r in pairs(st.reads) do ok(r.present and not r.unreadable, key .. ' status readable') end
    local wp = D.session.warplan
    ok(type(wp) == 'table' and wp.step >= 5, 'war plan steps counted: ' .. tostring(wp and wp.step))
    ok(wp.steps == nil or wp.step <= wp.steps, 'never "step N of M" with N > M')
    for i = 1, D.timeline.n do
        local a, b = D.timeline[i].text:match('step (%d+) of (%d+)')
        ok(a == nil or tonumber(a) <= tonumber(b), 'timeline plan step within the plan: ' .. D.timeline[i].text)
    end
    eq(D.helltide.file, 'hr_data.js')
    ok(D.strip.n >= 5, 'the session strip')
    ok(type(D.session.now) == 'table' and type(D.session.now.activity) == 'string', 'session.now')
    local out = os.getenv('WARROOM_DUMP')
    if out and out ~= '' then
        local f = assert(io.open(out .. '/suite_data.js', 'w')); f:write(text); f:close()
        local hr = h.mem_files[HR_WR_FILE]
        if hr then f = assert(io.open(out .. '/hr_data.js', 'w')); f:write(hr); f:close() end
    end
    -- HelltideRevamped wrote its map data next to the Helltide pages.
    ok(writes_to(h, HR_WR_FILE) > 0, 'hr_data.js written into WarRoom/dashboard')
    eq(writes_to(h, HR_OWN_FILE), 0, 'not into HelltideRevamped/dashboard')
    -- Persistence: alltime.txt / today.txt written and within the bounds.
    ok(writes_to(h, ROOT .. '/WarRoom/data/alltime.txt') > 0, 'alltime saved')
end)


-- One Pit War Plan step, the same script in every configuration: the
-- trace of what the bot did (positions each second, plugin log without
-- timing lines, API calls) must not depend on WarRoom.
local function pit_trace(cfg)
    local dirs = cfg.warroom and with_warroom({WR}) or with_warroom({})
    -- pairs() order is per process (hash seed) and, under Lua 5.4, per GC
    -- history: Batmobile's explorer picks among tied frontiers in that order,
    -- so without this even two runs with no WarRoom at all walk different
    -- paths. Sorted pairs for every configuration (see joint_host.lua).
    local h = J.new({dirs = dirs, virtual_os_time = true, ordered_pairs = true})
    -- CPU-time budgets (Batmobile's explorer throttles on os.clock) would
    -- make any extra plugin change the run: the simulated clock instead.
    h.G.os.clock = function() return h.now end
    -- and one fixed epoch (the runs happen at different wall-clock seconds).
    local real_time = os.time
    h.G.os.time = function(t) if t ~= nil then return real_time(t) end return 1790500000 + math.floor(h.now) end
    h.assert_clean('load ' .. cfg.name)
    if cfg.warroom then
        el(h, WR).main_toggle:set(cfg.enabled ~= false)
        if cfg.break_it then
            -- Every WarRoom internal fails: status reads, the host poll, the writer.
            local plugins = h.mod(WR, 'core.wr_plugins')
            plugins.read_all = function() error('status boom') end
            h.mod(WR, 'core.wr_host').poll = function() error('poll boom') end
            h.mod(WR, 'core.wr_payload').encode = function() error('encode boom') end
        end
    end
    el(h, ARK).pit_level:set(20)
    for i = 1, 3 do h.actor('pit', 'Pit_Monster_' .. i, 20 + i * 15, (i % 2) * 6, {enemy = true}) end
    h.set_quests({'WarPlans_QST_ThePit'})
    el(h, WP).main_toggle:set(true)
    local trace = {}
    local cost, calls, worst = 0, 0, 0
    local rec = h.by_dir[WR]
    if rec then
        for i, fn in ipairs(rec.update) do
            rec.update[i] = function(...)
                local t0 = os.clock()
                fn(...)
                local dt = os.clock() - t0
                cost, calls = cost + dt, calls + 1
                if dt > worst then worst = dt end
            end
        end
    end
    local next_sample = h.now
    h.run(60, function(hh)
        if hh.now >= next_sample then
            next_sample = next_sample + 1
            trace[#trace + 1] = string.format('%s %.1f %.1f', hh.place.key, hh.pos:x(), hh.pos:y())
        end
    end)
    h.travel_to('temis', 1.0, 'pit_exit')
    h.run(10)
    h.assert_clean(cfg.name)
    local log = {}
    for _, line in ipairs(h.log) do
        if not line:find('WarRoom', 1, true) and not line:find('PERF', 1, true) and not line:find('SPIKE', 1, true)
            and not line:find('ms', 1, true) and not line:match('^%S+%s%s') then
            log[#log + 1] = line
        end
    end
    local api = {}
    for _, c in ipairs(h.api_calls) do api[#api + 1] = c.export .. '.' .. c.name end
    return {h = h, trace = table.concat(trace, '\n'), log = table.concat(log, '\n'), api = table.concat(api, ','),
        cost = cost, calls = calls, worst = worst}
end

case('W2 WarRoom never changes what the bot does: absent, enabled, disabled and broken give the same run', function()
    local base = pit_trace({name = 'no WarRoom'})
    ok(base.h.place == base.h.P.temis and #base.trace >= 60, 'the Pit run happened')
    eq(rawget(base.h.G, 'QQT_Warpigz_events'), nil, 'no WarRoom: no bus')
    local on = pit_trace({name = 'enabled', warroom = true})
    local off = pit_trace({name = 'disabled', warroom = true, enabled = false})
    local broken = pit_trace({name = 'broken', warroom = true, break_it = true})
    for _, r in ipairs({on, off, broken}) do
        eq(r.trace, base.trace, 'same positions every second')
        eq(r.log, base.log, 'same plugin log')
        eq(r.api, base.api, 'same cross-plugin API calls')
    end
    -- Enabled: bounded per-frame cost (the collector works once a second).
    ok(on.calls >= 600, 'WarRoom ticked every frame: ' .. on.calls)
    print(string.format('  WarRoom cost: %d frames, avg %.3f ms, worst %.2f ms', on.calls, on.cost / on.calls * 1000,
        on.worst * 1000))
    ok(on.cost / on.calls < 0.002, string.format('average WarRoom frame %.3f ms', on.cost / on.calls * 1000))
    ok(on.worst < 0.05, string.format('worst WarRoom frame %.1f ms', on.worst * 1000))
    ok(writes_to(on.h, SUITE_FILE) >= 4, 'enabled: suite_data.js rewritten every 15 s')
    -- Disabled: nothing written at all, the bus is drained (no backlog).
    local wrote = 0
    for _, w in ipairs(off.h.file_writes) do if w.owner == WR then wrote = wrote + 1 end end
    eq(wrote, 0, 'disabled: WarRoom writes nothing')
    local st = off.h.mod(WR, 'core.wr_collector').state()
    eq(st.cursor, rawget(off.h.G, 'QQT_Warpigz_events').seq, 'disabled: events skipped, not queued')
    eq(st.scopes.session.activities.pit.runs, 0, 'disabled: nothing counted')
    -- Broken: WarRoom switched itself off with one log line; nobody else saw an error.
    eq(broken.h.logged('[WarRoom] collector is off for this session'), 1, 'one log line')
    eq(#broken.h.errors, 0, 'no error reached the host or another plugin')
end)

case('W3 HelltideRevamped standalone (no WarRoom): hr_data.js in its own folder, emits are no-ops', function()
    local h = J.new({dirs = {'Batmobile', HR}, place = 'helltide'})
    h.assert_clean('load')
    h.P.helltide.helltide = true
    el(h, HR).dashboard:set(true)
    el(h, HR).main_toggle:set(true)
    h.run(25)
    h.assert_clean('W3')
    ok(writes_to(h, HR_OWN_FILE) > 0, 'hr_data.js written into HelltideRevamped/dashboard')
    eq(writes_to(h, HR_WR_FILE), 0, 'not into WarRoom/dashboard')
    eq(rawget(h.G, 'QQT_Warpigz_events'), nil, 'no bus: every emit was a no-op')
    eq(rawget(h.G, 'QQT_WarRoom'), nil, 'no WarRoom global')
    local text = h.mem_files[HR_OWN_FILE]
    ok(type(text) == 'string' and text:sub(1, 15) == 'window.HR_DATA=', 'the HR payload')
end)

-- 3.3.0 review B2: WarRoom's status poll is invisible to WarPigs. Reading
-- WarPigs through status() ran its alfred_idle(): it started WarPigs'
-- paused-work hold clock and logged, with no WarPigs tick. WarRoom reads
-- WarPigs through the side-effect-free peek() instead.
case('W4 WarRoom plugin reads never touch WarPigs state (alfred_gate, log)', function()
    local h = J.new({dirs = with_warroom({WR}), rosie = true, virtual_os_time = true})
    el(h, WR).main_toggle:set(true)
    el(h, WP).main_toggle:set(true)
    local orch = h.mod(WP, 'core.orchestrator')
    local gate
    for i = 1, 200 do
        local n, v = debug.getupvalue(orch.alfred_idle, i)
        if not n then break end
        if n == 'alfred_gate' then gate = v end
    end
    ok(gate ~= nil, 'alfred_gate upvalue')
    h.G.AlfredTheButlerPlugin.get_status = function()
        return {enabled = true, paused = true, paused_by = 'SomeOwner', inventory_full = true}
    end
    local logged0 = h.logged('Alfred is paused by')
    local plugins = h.mod(WR, 'core.wr_plugins')
    local reads = h.as(WR, function() return plugins.read_all() end)
    eq(gate.paused_since, nil, 'WarRoom read_all() starts no WarPigs hold clock')
    eq(h.logged('Alfred is paused by'), logged0, 'WarRoom read_all() writes no WarPigs log line')
    ok(reads.warpigs.present and reads.warpigs.enabled == true, 'WarPigs still read (enabled)')
    eq(reads.warpigs.ver, (h.G.WarPigsPlugin.status().version:gsub('^v', '')), 'WarPigs version read')
end)

print(string.format('WarRoom joint: %d checks, %d failures', checks, #failures))
if #failures > 0 then error(table.concat(failures, '\n')) end
