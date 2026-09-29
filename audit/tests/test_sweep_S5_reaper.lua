-- QQT_Warpigz_v3 sweep S5: Reaper boss lairs, the owner's rare setup.
-- Reaper (manual rotation, Andariel, Greater Lair Keys) + Batmobile + the
-- REAL Rosie (town trips, pickup) + the Universal Rotation stand-in, under
-- seeded chaos (deaths, drops, Limbo, reloads, full bags, lazy stash, elite
-- packs, walls) with every invariant monitor on (TELEPORT / LEFT_DROP /
-- STALL / SPAM / LOOP; audit/tests/joint_host.lua).
--
-- The lair script (joint_host's h.setup_lair, extended here for repeated
-- runs): each boss-dungeon arrival is a fresh lair (altar near (-12,-11),
-- three trash packs on the entrance road, 60+ m from the altar); a click on
-- the interactable altar spends one key (the bag's Greater Lair Key stack) and summons Andariel,
-- who walks to the player (the host's enemies do not move; here every enemy
-- within 15 m aggroes and walks to melee range, the boss always) and resets to
-- full health when the player dies (as a boss fight does). Her death drops
-- three ancestral legendaries and the reward chest; the altar re-arms 5.5 s
-- after the chest is opened, as in the game. A Rosie town portal back keeps the
-- lair as it was.
-- The owner around it: when Reaper stops (keys ran out in Temis, a failed
-- start inside the lair, see F5) he restocks 0-6 keys after 15-40 s and enables
-- Reaper again wherever the player is (0 keys:
-- Reaper must refuse and stop cleanly: "materials running out").
--
-- Default (the suite runs this file under Lua 5.4 and LuaJIT): seeds 1-2,
-- 600 emulated s each, asserting no plugin error, forward progress, and no
-- invariant violation outside the documented known issues.
-- Heavy sweep (by hand):
--   QQT_SWEEP_SEEDS=1-24 QQT_SWEEP_SECS=7200 \
--     python3 audit/tests/run_tests.py --luajit require test_sweep_S5_reaper.lua
--   or, one runtime: luajit -e "SUITE_ROOT='$PWD'" audit/tests/test_sweep_S5_reaper.lua
--   QQT_SWEEP_SEEDS  "1-24" or "3,7,11"          QQT_SWEEP_SECS  emulated s per seed
--   QQT_SWEEP_RATE   chaos injections per minute (default 1)
--   QQT_SWEEP_ONLY   "3,7" keep only those chaos injections (bisecting)
--   QQT_SWEEP_OUT    append one TSV line per hit/error (seed, kind, t, detail)
--   QQT_SWEEP_LOG    write the whole console log there (%d = the seed)
--   QQT_SWEEP_VERBOSE=1 print each seed's report, chaos log and log tail
--   QQT_SWEEP_STRICT=0 report only (the heavy loop's default); 1 asserts
local ROOT = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local J = dofile(ROOT .. '/audit/tests/joint_host.lua')
local checks, failures = 0, {}
local function ok(value, message)
    if not value then error(message or 'expected a true value', 2) end
    checks = checks + 1
end
local function case(name, fn)
    local started = os.clock()
    local passed, err = xpcall(fn, debug.traceback)
    if passed then print(string.format('PASS sweep-S5: %s (%.1fs)', name, os.clock() - started))
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL sweep-S5: ' .. name .. ': ' .. tostring(err)) end
end

local RP = 'Reaper'
local GREATER_KEY = 2558255

local function parse_list(text)
    if not text or text == '' then return nil end
    local out = {}
    for part in text:gmatch('[^,%s]+') do
        local a, b = part:match('^(%d+)%-(%d+)$')
        if a then for n = tonumber(a), tonumber(b) do out[#out + 1] = n end
        else out[#out + 1] = tonumber(part) end
    end
    return out
end

-- One S5 session. Returns the host and the run counters.
local function session(seed, secs, o)
    o = o or {}
    local chaos = {seed = seed, rate = o.rate or 1}
    if o.only then chaos.only = o.only end
    if o.schedule then chaos.schedule = o.schedule end
    if o.chaos == false then chaos = nil end
    local h = J.new({rosie = true, dirs = {'Batmobile', RP}, place = 'temis', ordered_pairs = true,
        virtual_os_time = true, virtual_os_clock = true, persist_widgets = true, target_range = true,
        invariants = o.invariants == nil and true or o.invariants,
        rotation = {seed = seed}, chaos = chaos})
    h.assert_clean('load')
    local rng = J.rng(seed + 4242) -- the scenario's own draws (restocks)
    local S = {summons = 0, kills = 0, chests = 0, keys = o.keys or 4, enables = 1, refused = 0,
        boss_resets = 0, lairs = 0, restocks = {}}
    h.s5 = S
    h.keys_items = {{get_sno_id = function() return GREATER_KEY end, get_stack_count = function() return S.keys end,
        get_acd = function() return 7701 end, get_name = function() return 'Greater Lair Key' end,
        get_display_name = function() return 'Greater Lair Key' end}}
    local L = h.P.lair
    local boss
    local function new_lair()
        S.lairs = S.lairs + 1
        for i = #L.actors, 1, -1 do if not L.actors[i].chaos then table.remove(L.actors, i) end end
        L.items = {}
        boss = nil
        local altar = h.actor(L, 'Boss_WT4_Andariel', -12, -11)
        h.altar = altar
        altar.on_interact = function()
            if altar.summoned or S.keys <= 0 then return end
            altar.summoned, altar.interactable = true, false
            S.keys = S.keys - 1
            S.summons = S.summons + 1
            h.at(1.0, function()
                boss = h.actor(L, 'Boss_WT4_Andariel_Boss', -12, -13,
                    {enemy = true, boss = true, health = 1500, max_health = 1500, chase = true})
                h.boss = boss
                boss.on_death = function()
                    S.kills = S.kills + 1
                    for i = 1, 3 do
                        h.drop(L, boss.pos:x() - 2 + i, boss.pos:y() - 1,
                            {name = 'Helm_Legendary_Boss', rarity = 5, ancestral = true, ga = 1})
                    end
                    local chest = h.actor(L, 'EGB_Chest_Andariel', -13, -16)
                    chest.on_interact = function()
                        if chest.opening then return end
                        chest.opening = true
                        h.at(1.5, function() h.remove_actor(chest); S.chests = S.chests + 1 end)
                        h.at(5.5, function() altar.summoned, altar.interactable = false, true end)
                    end
                    boss = nil
                end
            end)
        end
        for i = 1, 3 do h.actor(L, 'Lair_Trash_' .. i, 44 - i * 8, 94 - i * 16, {enemy = true, health = 200}) end
    end
    L.on_arrive = function(_, trip) if trip.why == 'boss_dungeon' then new_lair() end end
    h.mod('Rosie', 'rosie.private.pickup.gui').elements.general.distance_slider:set(o.pickup_distance or 8)
    ok(h.as('Rosie', function() return h.G.RosiePlugin.enable() end), 'Rosie enabled')
    local e = h.mod(RP, 'gui').elements
    e.boss_enabled.andariel:set(true)
    e.use_batmobile:set(true)
    e.main_toggle:set(true)
    local was_dead, off_since = false, nil
    local function each(hh)
        -- the boss walks to the player; a death resets the fight
        if hh.dead and not was_dead and boss and (boss.health or 0) > 0 then
            boss.health = boss.max_health; S.boss_resets = S.boss_resets + 1
        end
        was_dead = hh.dead
        -- enemies aggro within 15 m (the boss always) and walk to melee range
        if not hh.dead and hh.place == L and not hh.travel then
            for _, a in ipairs(L.actors) do
                if a.enemy and (a.health or 0) > 0 then
                    local d = a.pos:dist_to_ignore_z(hh.pos)
                    if a.chase or d <= 15 then a.chase = true end
                    if a.chase and d > 3 then a.pos = a.pos:get_extended(hh.pos, math.min(0.4, d - 3)) end
                end
            end
        end
        -- the owner restocks keys and enables Reaper again
        local el = hh.mod(RP, 'gui') and hh.mod(RP, 'gui').elements
        if not el then return end
        if o.restock == false or el.main_toggle:get() then off_since = nil; return end
        if hh.travel or hh.place == hh.P.limbo or hh.dead then off_since = nil; return end
        off_since = off_since or hh.now
        if not S.wait then S.wait = rng.range(15, 40) end
        if hh.now - off_since < S.wait then return end
        local add = rng.chance(0.15) and 0 or rng.int(1, 6)
        if add == 0 and S.keys == 0 then S.refused = S.refused + 1 end
        S.keys = S.keys + add
        S.restocks[#S.restocks + 1] = {t = hh.now, add = add}
        S.enables, S.wait, off_since = S.enables + 1, nil, nil
        hh.log[#hh.log + 1] = string.format('%.1f [S5] owner restocks %d key(s) (%d in the bag) and enables Reaper',
            hh.now, add, S.keys)
        el.main_toggle:set(true)
    end
    if o.hook then
        h.run(secs, function(hh) each(hh); o.hook(hh, S) end)
    else
        h.run(secs, each)
    end
    return h, S
end

-- Classifies a hit: 'known' (a documented known issue or benign line),
-- 'F1'..'F4' (this sweep's findings, see the cases below), or nil (new:
-- fails the default run). QQT_SWEEP_OUT writes the class in column 5.
local function classify(hit, h)
    local d = hit.detail
    if hit.kind == 'TELEPORT' then
        -- Rosie's outbound Town Portal re-cast (KNOWN: every 3 s while channelling).
        if not d:find('by Reaper', 1, true) and d:find('town_portal->temis by Rosie', 1, true) then return 'known' end
        -- F2: boss-dungeon teleports out of a loading screen inside the lair.
        if d:find('boss_dungeon->', 1, true) then return 'F2' end
        return nil
    end
    if hit.kind == 'LEFT_DROP' then
        -- KNOWN family: a drop that lands inside a travel channel.
        if d:find('[dropped during the', 1, true) then return 'known' end
        -- KNOWN (sweep harness report, "Rosie abandons drops already on the
        -- ground when a trip is requested"): Rosie's own Town Portal. In a lair
        -- the portal returns to the exact spot and every such drop was
        -- picked up later.
        if d:find('town_portal by Rosie', 1, true) then return 'known' end
        -- F1: Reaper leaves the lair while a drop Rosie wanted lies beyond reach.
        if d:find('town_portal by Reaper', 1, true) then return 'F1' end
        return nil
    end
    if hit.kind == 'SPAM' then
        -- Rosie's per-item stash lines (benign, as in test_rosie_stash_q5).
        if d:find('[Rosie:stash] Deposit', 1, true) then return 'known' end
        -- F4 (LOW): Rosie re-logs the same rejected drop at every range crossing.
        if d:find('[Rosie pickup] Skipped', 1, true) then return 'F4' end
        return nil
    end
    if hit.kind == 'STALL' then
        local since = tonumber(d:match('%(since t=([%d%.]+)%)')) or hit.t
        -- F3: Reaper holds for a Rosie service that idles outside town
        -- (ends in Rosie's 240 s timeout).
        if d:find('Reaper task=alfred_running', 1, true) then return 'F3' end
        if h then
            for _, line in ipairs(h.log) do
                local t = tonumber(line:match('^([%d%.]+) %[Rosie%] failed: Town service or return timed out'))
                if t and t >= since and t <= since + 260 then return 'F3' end
            end
            -- F2 aftermath: idle in a fresh instance after a loading-screen teleport.
            for _, r in ipairs(h.boss_tps) do
                if r.from == 'limbo' and r.t >= since - 240 and r.t <= hit.t then return 'F2' end
            end
        end
        return nil
    end
    return nil
end

local function summarize(seed, h, S)
    local report, hits = h.invariant_report()
    local line = string.format('seed=%d t=%.0f summons=%d kills=%d chests=%d keys_left=%d enables=%d lairs=%d '
        .. 'revive_calls=%d boss_resets=%d rot_casts=%d dashes=%d interrupts=%d chaos=%d errors=%d hits=%d',
        seed, h.now - 1000, S.summons, S.kills, S.chests, S.keys, S.enables, S.lairs,
        h.revives, S.boss_resets, h.rotation.casts, h.rotation.dashes, h.rotation.interrupts,
        h.chaos and #h.chaos.log or 0, #h.errors, #(hits or {}))
    return line, report, hits or {}
end

local seeds = parse_list(os.getenv('QQT_SWEEP_SEEDS'))
local heavy = seeds ~= nil
seeds = seeds or {1, 2}
local secs = tonumber(os.getenv('QQT_SWEEP_SECS') or '') or 600
local strict_env = os.getenv('QQT_SWEEP_STRICT')
local strict = strict_env == '1' or (strict_env == nil and not heavy)
local verbose = os.getenv('QQT_SWEEP_VERBOSE') == '1'
local out_path = os.getenv('QQT_SWEEP_OUT')
local only = parse_list(os.getenv('QQT_SWEEP_ONLY'))
local runtime = jit and 'LuaJIT' or _VERSION

for _, seed in ipairs(seeds) do
    case(string.format('S5 Reaper lairs, seed %d, %d s (rotation + chaos + invariants)', seed, secs), function()
        local h, S = session(seed, secs, {rate = tonumber(os.getenv('QQT_SWEEP_RATE') or ''), only = only})
        local line, report, hits = summarize(seed, h, S)
        print('  ' .. line)
        if verbose then
            print(report); print(h.chaos.summary()); print(h.tail(80))
        end
        local log_path = os.getenv('QQT_SWEEP_LOG')
        if log_path then
            local f = io.open((log_path:gsub('%%d', tostring(seed))), 'w')
            if f then f:write(table.concat(h.log, '\n'), '\n'); f:close() end
        end
        if out_path then
            local f = io.open(out_path, 'a')
            if f then
                for _, er in ipairs(h.errors) do
                    f:write(string.format('%d\t%s\tERROR\t%.1f\t%s\t%s\n', seed, runtime, er.t or 0,
                        tostring(er.plugin), (tostring(er.err):gsub('[\r\n\t]+', ' | '))))
                end
                for _, hit in ipairs(hits) do
                    f:write(string.format('%d\t%s\t%s\t%.1f\t%s\t%s\n', seed, runtime, hit.kind, hit.t or 0,
                        classify(hit, h) or 'new', (tostring(hit.detail):gsub('[\r\n\t]+', ' | '))))
                end
                f:write(string.format('%d\t%s\tSUMMARY\t%.1f\t-\t%s\n', seed, runtime, h.now, line))
                f:close()
            end
        end
        if not strict then return end
        h.assert_clean('seed ' .. seed)
        ok(S.kills >= 3, 'seed ' .. seed .. ': at least three bosses killed\n' .. h.tail(40))
        ok(S.chests >= 2, 'seed ' .. seed .. ': chests opened')
        local accept = function(hit) return classify(hit, h) ~= nil end
        h.assert_invariants('seed ' .. seed, {TELEPORT = accept, LEFT_DROP = accept, STALL = accept, SPAM = accept, LOOP = accept})
    end)
end

-- Finding F1 (minimised from seed 1, chaos injection #2): a wanted drop
-- lying within Rosie's pickup distance when Andariel dies is left in the lair.
-- Rosie holds it through the fight (is_actively_looting() = true), then
-- Reaper's Open Chest (tasks/open_chest.lua MAIN) walks to the reward chest
-- at once, without the looter guard the lair exit has (utils.loot_ready);
-- once the drop is beyond the pickup distance Rosie no longer wants it,
-- loot_pending() (which asks evaluate_item(item, false)) reads idle, and the
-- finishing teleport leaves it. This case pins the current behaviour; with
-- QQT_SWEEP_FINDINGS=1 it asserts the fixed one (the drop is picked up).
if not heavy or os.getenv('QQT_SWEEP_FINDINGS') then
    case('F1 a drop Rosie holds through the boss fight is left when Reaper walks to the chest (seed 1, injection #2)', function()
        -- Seed 1, chaos injection #2 alone (scheduled): a Mythic lands 5.2 m from
        -- the player at t=1135.3 while Andariel (the 4th of 4 keys) is at
        -- 72 hp; Rosie reports is_actively_looting() = true, the boss dies at
        -- ~1136.3, Open Chest walks to (-13,-16) and the drop ends 13.9 m away.
        local h, S = session(1, 160, {keys = 4, restock = false, schedule = {{t = tonumber(os.getenv('F1_T') or '') or 1110, kind = 'drop', n = 2}}})
        local mythic
        for _, it in ipairs(h.P.lair.items or {}) do if it.rarity == 6 then mythic = it end end
        local left = 0
        for _, hit in ipairs(h.invariants.hits) do
            if hit.kind == 'LEFT_DROP' and hit.detail:find('MYTHIC', 1, true) then left = left + 1 end
        end
        ok(S.chests == 4 and h.place == h.P.temis, 'four runs, back in Temis\n' .. h.tail(30))
        if os.getenv('QQT_SWEEP_FINDINGS') == '1' then
            ok(mythic == nil and left == 0, 'F1 fixed: the Mythic was picked up before the lair exit\n'
                .. (h.invariant_report()))
        else
            ok(mythic ~= nil and not mythic.picked and left == 1,
                'F1 still reproduces (flip this case when Reaper is fixed)\n' .. (h.invariant_report()) .. '\n' .. h.chaos.summary() .. '\n' .. h.tail(25))
        end
    end)
end

-- Finding F2 (minimised from seed 2, chaos injection #10/#13 and seed 5
-- #11/#15/#25/#29): a loading screen (Limbo) read in the middle of the boss
-- fight. Reaper has no Limbo guard (ArkhamAsylum and HordeDev have one):
-- navigate_to_boss sees "not in the target zone" with altar_activated set,
-- starts map_nav and casts teleport_to_boss_dungeon. The new instance has a
-- fresh altar and no boss, but altar_activated survives, so Kill Monsters
-- idles until NO_FIGHT_BOUND (75 s) or forever while any enemy is within
-- 40 m; the spent key is lost (4 keys -> 3 kills). Scheduled here: one
-- 5 s Limbo 6 s after the first summon.
if not heavy or os.getenv('QQT_SWEEP_FINDINGS') then
    case('F2 a loading screen mid-fight re-teleports into a fresh lair and loses the summoned boss and its key', function()
        local h, S = session(2, 240, {keys = 2, restock = false,
            schedule = {{t = 1026, kind = 'limbo', seconds = 5}}})
        local tps = h.count(h.boss_tps, function(r) return r.from == 'limbo' end)
        if os.getenv('QQT_SWEEP_FINDINGS') == '1' then
            ok(tps == 0 and S.kills == 2, 'F2 fixed: no boss teleport out of a loading screen, both keys killed a boss ('
                .. tps .. ' teleports, ' .. S.kills .. ' kills)\n' .. h.tail(40))
        else
            ok(tps == 1 and S.summons == 2 and S.kills == 1 and S.lairs == 2,
                string.format('F2 still reproduces (flip when Reaper is fixed): %d boss teleports from Limbo, '
                    .. '%d summons, %d kills, %d lairs\n%s', tps, S.summons, S.kills, S.lairs, h.tail(40)))
        end
    end)
end

-- Finding F3 (seed 18 #16, also seeds 7, 10, 12 after a Rosie reload
-- mid-trip): the bag fills in Temis just as Reaper starts its run. Rosie
-- begins an automatic service in town, Reaper's boss teleport (same second)
-- takes the player to the lair, and the service then does nothing there
-- (no Town Portal) until Rosie's 240 s service timeout; Reaper holds
-- ("Holding for Alfred", alfred_running) the whole time and the failure
-- latches Rosie's automatic trips for 600 s.
if not heavy or os.getenv('QQT_SWEEP_FINDINGS') then
    case('F3 a bag that fills in town as Reaper starts: Rosie idles 240 s in the lair, Reaper holds', function()
        local T = tonumber(os.getenv('F3_T') or '') or 1000.6
        local h = session(3, 300, {keys = 2, restock = false, schedule = {{t = T, kind = 'bag_full'}}})
        local timed_out = h.logged('[Rosie] failed: Town service or return timed out')
        if os.getenv('QQT_SWEEP_FINDINGS') == '1' then
            ok(timed_out == 0, 'F3 fixed: no 240 s service timeout\n' .. h.tail(40))
        else
            ok(timed_out == 1 and h.logged('Holding for Alfred') >= 1,
                'F3 still reproduces (flip when fixed): timeouts=' .. timed_out .. '\n' .. h.tail(40))
        end
    end)
end

-- Finding F5 (seed 24 #4, seed 8 #? after F2): Reaper reloaded (or enabled)
-- in the middle of a boss fight whose summon spent the last key. With its
-- menu restored (QQT keeps widget values), the new instance starts a run,
-- on_enable scans the bag (0 keys) and refuses: "No keys / husks available"
-- -> stop, inside the lair, with the boss alive and its chest unopened. The
-- 1.10.4 "join a fight already in progress" path (interact_altar
-- live_fight) is never reached, and nothing returns the player to town.
if not heavy or os.getenv('QQT_SWEEP_FINDINGS') then
    case('F5 a Reaper reload mid-fight on the last key stops in the lair and abandons the boss', function()
        local reloaded
        local h, S = session(5, 120, {keys = 1, restock = false, chaos = false, hook = function(hh)
            if not reloaded and hh.boss and (hh.boss.health or 0) > 0 and hh.boss.health < 1200 then
                reloaded = hh.now
                hh.reload(RP)
            end
        end})
        ok(reloaded, 'reloaded mid-fight\n' .. h.tail(30))
        if os.getenv('QQT_SWEEP_FINDINGS') == '1' then
            ok(S.kills == 1 and S.chests == 1 and h.place == h.P.temis,
                'F5 fixed: the reloaded Reaper finishes the fight, opens the chest and goes home\n' .. h.tail(30))
        else
            ok(h.logged('No keys / husks available') == 1 and S.chests == 0 and h.place == h.P.lair,
                'F5 still reproduces (flip when fixed)\n' .. h.tail(30))
        end
    end)
end

print(string.format('sweep-S5: %d checks, %d failure(s)', checks, #failures))
if #failures > 0 then error(table.concat(failures, '\n')) end
