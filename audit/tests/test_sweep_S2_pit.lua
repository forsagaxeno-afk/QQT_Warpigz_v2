-- QQT_Warpigz_v3 scenario sweep S2: the owner's Pit setup, standalone
-- ArkhamAsylum + Batmobile + Rosie (automatic town trips and pickup) + the
-- Universal Rotation stand-in, long seeded runs with chaos and the invariant
-- monitors on (audit/tests/joint_host.lua: TELEPORT / LEFT_DROP / STALL /
-- SPAM / LOOP).
--
-- The Pit is scripted here (the joint host has one flat 'pit' place):
--   * the obelisk in the home town (Temis, or Cerrigar on some seeds): the
--     Iron Wolves crafter opens a vendor dialog, utility.open_pit_portal puts
--     a pit portal next to it for a NEW pit (new world ids per run);
--   * 2-4 floors per run; each floor is a walled box with trash, sometimes a
--     shrine, the descend portal at the far end and (floor 2+) the portal
--     back up next to the arrival point (Prefab_Portal_Dungeon_Generic is
--     both, as in the game);
--   * the last floor has the Pit Guardian (boss); its death leaves drops
--     around it, the Awakened Glyphstone (Gizmo_Paragon_Glyph_Upgrade), on
--     some runs Choron's Burden Receptacle (one extra upgrade chance);
--   * glyphs (get_glyphs / upgrade_glyph) readable while the glyphstone UI is
--     open, 3 upgrade chances per kill (+1 from the Receptacle);
--   * reset_all_dungeons inside a pit ejects to the obelisk town;
--   * loot_manager.any_item_around reads the ground items (the joint host
--     returns h.floor_loot, a scenario flag);
--   * a death costs 10 % durability on the equipped gear (Rosie's repair
--     need at <= 10 %).
-- Scenario invariants added to the host's monitors (h.invariants.hit):
--   PIT_BACK    Arkham took the portal back up (never wanted);
--   PIT_SLOW    a pit run still open 480 s after it was opened;
--   PIT_ABANDON a new pit opened while the last one's Guardian lived;
--   BOSS_TRIP   a teleport cast within 30 m of the live Pit Guardian;
--   HOLD_LOG    Arkham's '[alfred] holding for Ns' claims more than its
--               alfred task has run.
-- Every hit is classified by RULES below: 'known' (being fixed by a plugin
-- session), 'board' (an open BOARD item), 'finding' (reported by this
-- sweep), 'expected' (by design / emulator). An unclassified hit fails.
--
-- Default (the suite runs every file under Lua 5.4 and LuaJIT): a reload
-- check of the harness, D1 (scripted chaos, 800 s) and D2 (seeded chaos,
-- 600 s) must run clean (no Lua error, no caller-context violation, no
-- monitor error, no unclassified hit) and make progress.
--
-- Heavy sweep (developer, not the suite):
--   QQT_SWEEP_SEEDS=1-20 QQT_SWEEP_SECONDS=7200 \
--     luajit -e 'SUITE_ROOT="<repo>"' audit/tests/test_sweep_S2_pit.lua
-- QQT_SWEEP_SEEDS takes "a-b" or "a,b,c"; QQT_SWEEP_VERBOSE=1 prints every
-- hit; QQT_SWEEP_ONLY=<kind> only that kind; QQT_SWEEP_TAIL=N the last N
-- log lines; QQT_SWEEP_GREP=<text> the matching log lines;
-- QQT_SWEEP_WINDOW=t0-t1 the log (and the waypoint casts) in a window;
-- QQT_SWEEP_PROBE=t1,t2 the player / Guardian / task state at those times;
-- QQT_SWEEP_PROGRESS=1 a CPU-time line every 300 emulated s;
-- QQT_SWEEP_LIST=1 only lists each seed's configuration.
-- A seed's configuration (home town, exit mode, pickup distance, chaos rate,
-- plugins) is drawn from the seed; to minimise a repro override it with
-- QQT_SWEEP_TOWN=temis|cerrigar, _EXIT=reset|teleport, _DISTANCE=m,
-- _RATE=per_min, _PLUGINS=all|min, and the chaos with _NOCHAOS=1,
-- _KINDS=drop,death, _CHAOS_ONLY=3,7 (injection numbers) or
-- _SCHEDULE=1330:reload:ArkhamAsylum,1400:drop:mythic (absolute times, the
-- host starts at t=1000); _FLOOR_LOAD=s (floor loading screen, default 2)
-- and _BOSS_MYTHIC=0..1 (share of Mythic boss drops) change the world.
-- QQT_SWEEP_FINDINGS=1 runs the minimal repro of each finding (F1..F5,
-- QQT_SWEEP_FINDING=F3 just one); with QQT_SWEEP_STRICT=1 a reproduced
-- finding fails (a regression test for the session that fixes it).
-- The exit code is non-zero only for crashes / unclassified hits.
local ROOT = assert(SUITE_ROOT, 'SUITE_ROOT is required')
-- QQT_SWEEP_HOST: a snapshot of joint_host.lua for a long background sweep.
local HOST_FILE = os.getenv('QQT_SWEEP_HOST')
local J = dofile(HOST_FILE and HOST_FILE ~= '' and HOST_FILE or (ROOT .. '/audit/tests/joint_host.lua'))

local checks, failures = 0, {}
local function ok(value, message)
    if not value then error(message or 'expected a true value', 2) end
    checks = checks + 1
end

local ARK = 'ArkhamAsylum'
local CONSUMER = {name = 'SweepS2', dir = ROOT .. '/audit/tests/', loaded = {}}

-- ── the scripted Pit ──────────────────────────────────────────────────────
local function build_world(h, seed, o)
    local rng = J.rng(seed * 7919 + 17)
    local v = h.v
    local W = {runs = {}, run = nil, opens = 0, portal = nil, kills = 0, glyph_ui = false, chances = 0,
        upgrades = 0, resets = 0, floors_entered = 0, deaths = 0, completed = 0, exits = {}, back_taken = 0,
        shrines_used = 0, altars_used = 0, events = {}, death_times = {}}
    h.world = W
    local function note(kind, detail)
        W.events[#W.events + 1] = {t = h.now, kind = kind, detail = detail}
        h.log[#h.log + 1] = string.format('%.1f [pit] %s: %s', h.now, kind, tostring(detail))
    end
    W.note = note
    -- Cerrigar obelisk (Arkham's town option 1): inside the host's Cerrigar box.
    h.cerrigar_tower = h.actor('cerrigar', 'TWN_Kehj_IronWolves_PitKey_Crafter', -1330, 70)
    h.cerrigar_tower.on_interact = function() h.vendor_screen = true end
    local function tower_of(place)
        if place == h.P.temis then return h.pit_tower end
        if place == h.P.cerrigar then return h.cerrigar_tower end
        return nil
    end
    W.tower_of = tower_of

    local next_id = 5000
    -- Place keys carry no digits: the LOOP monitor masks numbers in state
    -- names, so 'pit2.1' and 'pit2.2' would read as one place.
    local function letters(n)
        local s = ''
        repeat
            s = string.char(65 + (n - 1) % 26) .. s
            n = math.floor((n - 1) / 26)
        until n <= 0
        return s
    end
    local function new_floor(run, f, last)
        next_id = next_id + 1
        local len = 130 + rng.int(0, 40)
        local place = {name = 'PIT_Joint_Floor', zone = 'PIT_Subzone', id = next_id, town = false,
            spawn = v(0, 0), box = {-25, len + 15, -30, 30}, key = 'pit_' .. letters(run.n) .. '_' .. letters(f):lower(),
            actors = {}, items = {}, slide = true, walls = {}, floor = f, run = run}
        h.P[place.key] = place -- h.remove_actor only searches the host's place table
        -- one or two interior walls with a gap (the mover slides along them)
        for i = 1, rng.int(1, 2) do
            local x = math.floor(len * i / 3)
            local gap = rng.range(-18, 18)
            place.walls[#place.walls + 1] = {x, x + 2, -30, gap - 4}
            place.walls[#place.walls + 1] = {x, x + 2, gap + 4, 30}
        end
        -- trash
        for i = 1, rng.int(5, 9) do
            local x, y = rng.range(12, len), rng.range(-24, 24)
            local walled = false
            for _, w in ipairs(place.walls) do
                if x >= w[1] - 1 and x <= w[2] + 1 and y >= w[3] - 1 and y <= w[4] + 1 then walled = true end
            end
            if not walled then
                local m = h.actor(place, 'Pit_Trash_' .. i, x, y, {enemy = true, health = rng.int(80, 240)})
                m.on_death = function()
                    h.remove_actor(m)
                    W.kills = W.kills + 1
                    if rng.chance(o.trash_drop or 0.18) and h.drop then
                        local rare = rng.chance(0.6)
                        h.drop(place, m.pos:x() + rng.range(-1.5, 1.5), m.pos:y() + rng.range(-1.5, 1.5),
                            rare and {name = 'Helm_Rare_Joint', rarity = 3, ga = 0}
                                or {name = 'Helm_Legendary_Chaos', rarity = 5, ancestral = true, ga = rng.int(0, 3)})
                    end
                end
            end
        end
        if rng.chance(o.shrine_chance or 0.5) then
            local s = h.actor(place, 'Shrine_DRLG_Artillery', rng.range(20, len - 10), rng.range(-20, 20))
            s.on_interact = function()
                if s.used then return end
                s.used, s.interactable = true, false
                W.shrines_used = W.shrines_used + 1
                note('shrine', 'used on ' .. place.key)
            end
        end
        if not last then
            local py = rng.range(-20, 20)
            local portal = h.actor(place, 'Prefab_Portal_Dungeon_Generic', len + 8, py)
            place.down = portal
            portal.on_interact = function()
                if h.travel then return end -- a second click during the transition does nothing
                local nxt = run.floors[f + 1]
                note('descend', place.key .. ' -> ' .. nxt.key)
                h.travel_to(nxt, 0.3, 'pit_floor_portal')
                h.travel.started = h.now
            end
        else
            local bx, by = len, rng.range(-15, 15)
            local boss = h.actor(place, 'Pit_Guardian_Joint', bx, by,
                {enemy = true, boss = true, health = o.boss_health or rng.int(1500, 3000)})
            boss.max_health = boss.health
            run.boss = boss
            boss.on_death = function()
                h.remove_actor(boss)
                run.boss_dead_at = h.now
                W.chances = 3
                note('boss', string.format('Pit Guardian of run %d killed', run.n))
                -- o.bag_near_full: the bag is one item short of full when the
                -- Guardian dies, so its loot pile fills it.
                if o.bag_near_full then
                    h.inventory = h.inventory or {}
                    while #h.inventory < 24 do h.inventory[#h.inventory + 1] = h.gear({name = 'Helm_Rare_Joint'}) end
                end
                local gx, gy = boss.pos:x() - 3, boss.pos:y()
                run.glyph = h.actor(place, 'Gizmo_Paragon_Glyph_Upgrade', gx, gy)
                run.glyph.on_interact = function()
                    if h.pos:dist_to_ignore_z(run.glyph.pos) <= 5 then W.glyph_ui = true end
                end
                if rng.chance(o.altar_chance or 0.4) then
                    local altar = h.actor(place, 'Warplans_Pit_ChoronsBurden_Receptacle', gx - 6, gy + 5)
                    altar.on_interact = function()
                        h.remove_actor(altar)
                        W.chances = W.chances + 1
                        W.altars_used = W.altars_used + 1
                        note('altar', 'Choron\'s Burden Receptacle used (+1 chance)')
                    end
                end
                if h.drop then
                    for i = 1, rng.int(2, 5) do
                        local ang = rng.range(0, 2 * math.pi)
                        local d = rng.range(1, 5)
                        local roll = rng.next()
                        local fields
                        if roll < (o.boss_mythic or 0.08) then
                            fields = {name = 'Helm_Unique_Generic_005', sno = 2647147, rarity = 6, ancestral = true, ga = 1,
                                affixes = {{affix_name_hash = 2662414, get_name = function() return 'Helm_Unique_Generic_005' end},
                                    {affix_name_hash = 2628989, get_name = function() return 'S14_Mythic_UniquePotency' end}}}
                        elseif roll < 0.55 then
                            fields = {name = 'Helm_Legendary_Chaos', rarity = 5, ancestral = true, ga = rng.int(0, 3)}
                        else
                            fields = {name = 'Helm_Rare_Joint', rarity = 3, ga = 0}
                        end
                        h.drop(place, boss.pos:x() + math.cos(ang) * d, boss.pos:y() + math.sin(ang) * d, fields)
                    end
                end
            end
        end
        if f > 1 then
            -- the portal back up, 5-6 m from the arrival point
            local back = h.actor(place, 'Prefab_Portal_Dungeon_Generic', -5, 2)
            place.up = back
            back.on_interact = function()
                if h.travel then return end
                local prev = run.floors[f - 1]
                W.back_taken = W.back_taken + 1
                run.back_taken = (run.back_taken or 0) + 1
                note('back portal', place.key .. ' -> ' .. prev.key .. ' (the portal back up)')
                -- Scenario invariant PIT_BACK: Arkham never has a reason to
                -- go back up. The detail says what preceded it on this floor.
                if h.invariants then
                    local why = {}
                    local arrived = place.portal_arrival
                    if arrived then
                        why[#why + 1] = string.format('arrived through %s at t=%.1f after a %.1f s transition',
                            arrived.why == 'pit_back_portal' and 'the portal back up from the floor below'
                                or 'a descend portal', arrived.t, arrived.transition)
                    else
                        why[#why + 1] = 'no portal arrival on this floor'
                    end
                    for _, rec in ipairs(h.chaos and h.chaos.log or {}) do
                        if rec.kind == 'reload' and not rec.skipped and tostring(rec.detail):find('ArkhamAsylum', 1, true)
                            and rec.t >= (arrived and arrived.t or place.first_t or 0) then
                            why[#why + 1] = string.format('ArkhamAsylum reloaded at t=%.1f', rec.t)
                        end
                    end
                    h.invariants.hit('PIT_BACK', string.format('Arkham took the portal back up %s -> %s at (%.1f, %.1f), '
                        .. 'player %.1f m away; %s', place.key, prev.key, back.pos:x(), back.pos:y(),
                        h.pos:dist_to_ignore_z(back.pos), table.concat(why, '; ')))
                end
                h.travel_to(prev, 0.3, 'pit_back_portal')
                h.travel.pos = v(prev.down.pos:x() - 6, prev.down.pos:y())
                h.travel.started = h.now
            end
        end
        place.on_arrive = function(_, trip)
            place.first_t = place.first_t or h.now
            run.last_floor = place
            if trip and trip.why ~= 'town_portal' then W.floors_entered = W.floors_entered + 1 end
            if trip and (trip.why == 'pit_floor_portal' or trip.why == 'pit_back_portal' or trip.why == 'pit_portal') then
                place.portal_arrival = {t = h.now, transition = h.now - (trip.started or h.now), why = trip.why}
            end
        end
        return place
    end
    function W.new_run(town)
        local run = {n = #W.runs + 1, town = town, floors = {}, opened_at = h.now}
        local count = o.floors or rng.int(2, 4)
        for f = 1, count do run.floors[f] = new_floor(run, f, f == count) end
        W.runs[#W.runs + 1] = run
        W.run = run
        note('open', string.format('pit run %d opened in %s: %d floors', run.n, town.key, count))
        return run
    end
    function W.in_pit() return h.place and h.place.run ~= nil end

    local G = h.G
    -- The obelisk dialog: a portal next to the obelisk for a new pit.
    G.utility.open_pit_portal = function(address)
        h.pit_opens = h.pit_opens + 1
        W.opens = W.opens + 1
        h.vendor_screen = false
        local tower = tower_of(h.place)
        if not tower or W.portal then return end
        -- Scenario invariant PIT_ABANDON: a new pit while the last one was
        -- left before its Guardian died.
        local last = W.run
        if last and not last.completed_at and h.invariants then
            local where = last.last_floor and last.last_floor.key or 'no floor'
            h.invariants.hit('PIT_ABANDON', string.format('pit run %d opened at t=%.1f was abandoned (reached %s, '
                .. 'Guardian %s, back portals taken %d, %d dungeon reset(s) so far) and a new pit is opened in %s',
                last.n, last.opened_at, where, last.boss_dead_at and 'dead' or 'alive', last.back_taken or 0,
                W.resets, h.place.key))
        end
        local run = W.new_run(h.place)
        local town = h.place
        local portal = h.actor(town, 'EGD_MSWK_World_Portal_01', tower.pos:x() + 4, tower.pos:y() - 6)
        W.portal = portal
        portal.on_interact = function()
            h.remove_actor(portal)
            W.portal = nil
            h.travel_to(run.floors[1], 0.5, 'pit_portal')
            h.travel.started = h.now
        end
    end
    -- Reset inside a pit ejects the player to the obelisk town.
    -- Scenario invariant GLYPH_TRIP: leaving the Guardian's floor while the
    -- Awakened Glyphstone still has upgrade chances (Arkham ARK-4: a trip from
    -- there loses the upgrade; Arkham defers its own trips until the upgrade
    -- is done, at most 120 s).
    function W.glyph_check(how)
        local run = W.run
        if not (h.invariants and run and run.glyph and h.place == run.floors[#run.floors] and W.chances > 0) then
            return
        end
        local since = run.boss_dead_at or h.now
        local deaths = 0
        for _, t in ipairs(W.death_times) do if t >= since then deaths = deaths + 1 end end
        local au = h.mod(ARK, 'core.utils')
        local okf, forced = pcall(function() return au and au.exit_pit_forced() end)
        h.invariants.hit('GLYPH_TRIP', string.format('%s from %s with the glyphstone unused (%d upgrade chance(s) '
            .. 'left, %d upgrade(s) done, Guardian died at t=%.1f, %d death(s) since%s); bag %d items', how, h.place.key,
            W.chances, run.upgrades or 0, since, deaths, okf and forced and ', reset timer expired' or '',
            #(h.inventory or {})))
    end
    rawset(G, 'reset_all_dungeons', function()
        h.resets = h.resets + 1
        W.resets = W.resets + 1
        local run = h.place.run
        if not run or h.travel then return end
        W.glyph_check('reset_all_dungeons() by ' .. tostring(h.context_name()))
        local town = run.town
        h.at(0.5, function()
            if h.place.run == run and not h.travel then
                W.exits[#W.exits + 1] = {t = h.now, run = run.n, how = 'reset'}
                note('exit', 'dungeon reset: run ' .. run.n .. ' left for ' .. town.key)
                h.travel_to(town, 0.1, 'dungeon_reset')
                h.travel.pos = v(tower_of(town).pos:x() + 6, tower_of(town).pos:y() + 4)
            end
        end)
    end)
    -- Glyphs, readable while the glyphstone UI is open (within 5 m).
    local glyphs = {}
    for i, lvl in ipairs({12, 30, 44}) do
        local g = {glyph_name_hash = 900000 + i, level = lvl}
        function g:get_level() return self.level end
        function g:get_upgrade_chance() return 0.9 end
        function g:can_upgrade() return W.chances > 0 and self.level < 100 end
        function g:get_max_level() return 100 end
        glyphs[i] = g
    end
    W.glyphs = glyphs
    rawset(G, 'get_glyphs', function()
        local run = h.place.run
        if not (W.glyph_ui and run and run.glyph and h.pos:dist_to_ignore_z(run.glyph.pos) <= 5) then return {} end
        return glyphs
    end)
    rawset(G, 'upgrade_glyph', function(g)
        if not W.glyph_ui or W.chances <= 0 or type(g) ~= 'table' then return false end
        W.chances = W.chances - 1
        W.upgrades = W.upgrades + 1
        if W.run then W.run.upgrades = (W.run.upgrades or 0) + 1 end
        if rng.chance(0.85) then g.level = g.level + 1 end
        return true
    end)
    -- Floor loot the way the game reports it (ground items within the radius).
    G.loot_manager.any_item_around = function(pos, radius)
        pos = pos or h.pos
        for _, item in ipairs(h.place.items or {}) do
            if not item.picked and item.pos and item.pos:dist_to_ignore_z(pos) <= (radius or 30) then return true end
        end
        return false
    end
    -- Equipped gear: a death costs 10 % durability.
    h.equipped = {h.gear({name = 'Helm_Rare_Joint', durability = 100}), h.gear({name = 'Chest_Rare_Joint', durability = 100})}
    W.was_dead = false
    -- o.floor_loading: seconds of loading screen for a floor portal (the
    -- host's Limbo is 2 s); a slow PC loads a floor for longer.
    local floor_loading = o.floor_loading or 2
    -- Scenario invariant HOLD_LOG: Arkham's '[alfred] holding for Ns' line
    -- must not claim a longer hold than its alfred task has been running.
    local hold = {i = #h.log, since = nil}
    local function check_hold_log()
        local tm = h.mod(ARK, 'core.task_manager')
        local got, task = pcall(function() return tm and tm.get_current_task() end)
        local name = got and type(task) == 'table' and task.name or nil
        if name == 'alfred_running' then hold.since = hold.since or h.now else hold.since = nil end
        for i = hold.i + 1, #h.log do
            local secs, reason = h.log[i]:match('%[alfred%] holding for (%d+)s: (.*)$')
            secs = tonumber(secs)
            if secs and h.invariants then
                local real = hold.since and (h.now - hold.since) or 0
                if secs > real + 5 then
                    h.invariants.hit('HOLD_LOG', string.format("Arkham logged '[alfred] holding for %ds: %s' but its "
                        .. 'alfred task has run for %.0f s (since t=%s)', secs, reason, real,
                        hold.since and string.format('%.1f', hold.since) or '-'))
                end
            end
        end
        hold.i = #h.log
    end
    function W.tick()
        check_hold_log()
        local tr = h.travel
        if tr and tr.phase == 'loading' and not tr.extended and floor_loading ~= 2
            and (tr.why == 'pit_floor_portal' or tr.why == 'pit_back_portal') then
            tr.extended, tr.at = true, tr.at + (floor_loading - 2)
        end
        if h.dead and not W.was_dead then
            W.deaths = W.deaths + 1
            W.death_times[#W.death_times + 1] = h.now
            for _, item in ipairs(h.equipped) do item.durability = math.max(0, item.durability - 10) end
        end
        W.was_dead = h.dead
        if W.glyph_ui and not (h.place.run and h.place.run.glyph
            and h.pos:dist_to_ignore_z(h.place.run.glyph.pos) <= 5) then W.glyph_ui = false end
        -- a run counts as completed when its pit is left after the guardian died
        local run = W.run
        -- Scenario invariant PIT_SLOW: a run still open 480 s after it was
        -- opened (runs here take 150-250 s; Arkham's reset timer is 600 s).
        if run and not run.completed_at and not run.slow and h.now - run.opened_at > 480 and h.invariants then
            run.slow = true
            h.invariants.hit('PIT_SLOW', string.format('pit run %d open for 480 s (opened t=%.1f): now in %s, '
                .. 'last floor %s, Guardian %s, back portals taken %d; %s', run.n, run.opened_at, h.place.key,
                run.last_floor and run.last_floor.key or '-', run.boss_dead_at and 'dead' or 'alive', run.back_taken or 0,
                h.invariants.status_lines()))
        end
        if run and run.boss_dead_at and not run.completed_at and not h.place.run and h.place ~= h.P.limbo
            and not h.travel then
            run.completed_at = h.now
            W.completed = W.completed + 1
        end
    end
    return W
end

-- ── one seeded run ────────────────────────────────────────────────────────
local function pick(rng, list) return list[rng.int(1, #list)] end
-- Per-seed configuration (all from the seed): home town, exit mode, pickup
-- distance, floors, chaos rate; all plugins loaded (as installed) on some.
-- QQT_SWEEP_TOWN / _EXIT (reset|teleport) / _DISTANCE / _RATE / _PLUGINS
-- (all|min) override the seed's draw (to minimise a repro).
local function env_override(o)
    local town, exit = os.getenv('QQT_SWEEP_TOWN'), os.getenv('QQT_SWEEP_EXIT')
    if town and town ~= '' and o.town == nil then o.town = town end
    if exit and exit ~= '' and o.exit_mode == nil then o.exit_mode = exit == 'teleport' and 1 or 0 end
    if o.distance == nil then o.distance = tonumber(os.getenv('QQT_SWEEP_DISTANCE') or '') end
    if o.rate == nil then o.rate = tonumber(os.getenv('QQT_SWEEP_RATE') or '') end
    local plugins = os.getenv('QQT_SWEEP_PLUGINS')
    if plugins and plugins ~= '' and o.all_plugins == nil then o.all_plugins = plugins == 'all' end
    -- QQT_SWEEP_CHAOS_ONLY=3,7 keeps only those chaos injections (same times
    -- and draws); QQT_SWEEP_KINDS=drop,death limits the kinds; QQT_SWEEP_NOCHAOS=1.
    local only = os.getenv('QQT_SWEEP_CHAOS_ONLY')
    if only and only ~= '' and o.only == nil then
        o.only = {}
        for n in only:gmatch('%d+') do o.only[#o.only + 1] = tonumber(n) end
    end
    local kinds = os.getenv('QQT_SWEEP_KINDS')
    if kinds and kinds ~= '' and o.kinds == nil then
        o.kinds = {}
        for k in kinds:gmatch('[%w_]+') do o.kinds[#o.kinds + 1] = k end
    end
    if os.getenv('QQT_SWEEP_NOCHAOS') == '1' and o.chaos == nil then o.chaos = false end
    -- QQT_SWEEP_SCHEDULE=1330:reload:ArkhamAsylum,1400:drop:mythic runs only
    -- these injections at those absolute times (t starts at 1000).
    local sched = os.getenv('QQT_SWEEP_SCHEDULE')
    if sched and sched ~= '' and o.schedule == nil then
        o.schedule, o.chaos = {}, true
        for entry in sched:gmatch('[^,]+') do
            local t, kind, arg = entry:match('^([%d%.]+):([%w_]+):?([%w_]*)$')
            local e = {t = tonumber(t), kind = kind}
            if kind == 'reload' and arg ~= '' then e.dir = arg end
            if kind == 'drop' and arg == 'mythic' then e.mythic = true end
            o.schedule[#o.schedule + 1] = e
        end
    end
    return o
end
local function config(seed, o)
    local rng = J.rng(seed * 104729 + 3)
    for _ = 1, seed % 7 do rng.next() end
    local c = {seed = seed}
    local draw = {town = rng.chance(0.25) and 'cerrigar' or 'temis', exit_mode = rng.chance(0.5) and 1 or 0,
        distance = pick(rng, {2, 8, 15}), rate = pick(rng, {0.6, 1.0, 1.5}), all_plugins = rng.chance(0.3)}
    c.town = o.town or draw.town
    c.exit_mode = o.exit_mode or draw.exit_mode
    c.distance = o.distance or draw.distance
    c.rate = o.rate or draw.rate
    c.all_plugins = o.all_plugins
    if c.all_plugins == nil then c.all_plugins = draw.all_plugins end
    c.floors = o.floors
    c.interrupt = o.interrupt
    -- QQT_SWEEP_INTERRUPT=dash|cast|off: which rotation action breaks a
    -- channel (the stand-in's default: a dash/evade).
    local irq = os.getenv('QQT_SWEEP_INTERRUPT')
    if c.interrupt == nil and irq and irq ~= '' then
        if irq == 'off' then c.interrupt = false else c.interrupt = irq end
    end
    return c
end

local function describe(c)
    return string.format('seed=%d town=%s exit=%s pickup=%dm chaos=%.1f/min plugins=%s', c.seed, c.town,
        c.exit_mode == 1 and 'teleport' or 'reset', c.distance, c.rate, c.all_plugins and 'all' or 'ArkhamAsylum,Batmobile,Rosie')
end

local function start(seed, o)
    o = env_override(o or {})
    local c = config(seed, o)
    local dirs = {'ArkhamAsylum', 'Batmobile'}
    if c.all_plugins then dirs = nil end -- every folder of the package (J.DIRS), all but Arkham off
    local chaos = {seed = seed, rate = c.rate, kinds = o.kinds, only = o.only, schedule = o.schedule}
    if o.chaos == false then chaos = nil end
    local h = J.new({rosie = true, dirs = dirs, place = c.town, seed = seed, ordered_pairs = true,
        virtual_os_clock = true, shipped_defaults = true, invariants = o.invariants ~= false,
        rotation = {seed = seed, interrupt = c.interrupt == nil and 'dash' or c.interrupt}, chaos = chaos})
    h.assert_clean('load ' .. describe(c))
    local W = build_world(h, seed, {floors = c.floors, boss_health = o.boss_health,
        boss_mythic = o.boss_mythic or tonumber(os.getenv('QQT_SWEEP_BOSS_MYTHIC') or ''),
        floor_loading = o.floor_loading or tonumber(os.getenv('QQT_SWEEP_FLOOR_LOAD') or ''),
        bag_near_full = o.bag_near_full or os.getenv('QQT_SWEEP_BAG_NEAR_FULL') == '1'})
    -- o.start_on_floor = N: the player already stands on floor N of an open
    -- pit (played by hand, or QQT restarted mid-pit) when the bot starts, at
    -- (x, y) = o.start_pos (default: 30 m into the floor).
    if o.start_on_floor then
        local run = W.new_run(h.P[c.town])
        local floor = run.floors[math.min(o.start_on_floor, #run.floors)]
        h.place, h.pos = floor, h.v((o.start_pos or {30, 0})[1], (o.start_pos or {30, 0})[2])
        floor.first_t, run.last_floor = h.now, floor
    end
    -- The owner's configuration: Arkham on (standalone), Rosie on with
    -- automatic trips, pickup distance per seed.
    local gui = h.mod(ARK, 'gui').elements
    gui.main_toggle:set(true)
    gui.town:set(c.town == 'cerrigar' and 1 or 0)
    gui.exit_mode:set(c.exit_mode)
    h.mod('Rosie', 'rosie.private.pickup.gui').elements.general.distance_slider:set(c.distance)
    ok(h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end) == true, 'Rosie enabled')
    h.c = c
    -- Who cast each waypoint teleport and which Arkham task ran (a tail
    -- call keeps the host's caller attribution for the TELEPORT monitor).
    local tp_log, orig_tp = {}, h.G.teleport_to_waypoint
    h.tp_log = tp_log
    rawset(h.G, 'teleport_to_waypoint', function(sno)
        local tm = h.mod(ARK, 'core.task_manager')
        local got, task = pcall(function() return tm and tm.get_current_task() end)
        tp_log[#tp_log + 1] = {t = h.now, sno = sno, ctx = h.context_name() or '-', from = h.place.key,
            task = got and type(task) == 'table' and tostring(task.name) or '-'}
        -- Scenario invariant GLYPH_TRIP: a teleport cast out of the Guardian's
        -- floor while the Awakened Glyphstone still has upgrade chances
        -- (Arkham ARK-4: a trip from there loses the upgrade; Arkham defers
        -- its own trips until the upgrade is done, at most 120 s).
        local run = W.run
        if not h.travel then
            W.glyph_check(string.format('teleport_to_waypoint(0x%X) cast by %s (Arkham task %s)', sno,
                tp_log[#tp_log].ctx, tp_log[#tp_log].task))
        end
        -- Scenario invariant BOSS_TRIP: a teleport cast next to a live Pit
        -- Guardian (Arkham defers its own trips while one is within 30 m).
        local boss = W.run and W.run.boss
        if h.invariants and boss and boss.health > 0 and h.place == W.run.floors[#W.run.floors] and not h.travel
            and h.pos:dist_to_ignore_z(boss.pos) <= 30 then
            h.invariants.hit('BOSS_TRIP', string.format('teleport_to_waypoint(0x%X) cast by %s (Arkham task %s) %.1f m from '
                .. 'the live Pit Guardian (hp %.0f/%.0f) in %s; bag %d items, durability %s', sno, tp_log[#tp_log].ctx,
                tp_log[#tp_log].task, h.pos:dist_to_ignore_z(boss.pos), boss.health, boss.max_health, h.place.key,
                #(h.inventory or {}), tostring(h.equipped[1] and h.equipped[1].durability)))
        end
        return orig_tp(sno)
    end)
    return h, W
end
-- The waypoint cast behind a travel that ended at `t` (within `window` s).
local function cast_before(h, t, window)
    for i = #h.tp_log, 1, -1 do
        local c = h.tp_log[i]
        if c.t <= t + 1e-6 then
            if t - c.t <= (window or 3.5) then return c end
            return nil
        end
    end
    return nil
end

-- ── classification of invariant hits ──────────────────────────────────────
-- Each rule: id, class ('known' = already being fixed by a plugin session,
-- 'finding' = new, reported by this sweep, 'expected' = by design / emulator
-- artifact), and a predicate over the hit.
local RULES = {}
local function rule(id, class, kind, fn, why)
    RULES[#RULES + 1] = {id = id, class = class, kind = kind, fn = fn, why = why}
end
local function has(hit, text) return hit.detail:find(text, 1, true) ~= nil end
local function mean_dwell(hit) return tonumber(hit.detail:match('mean dwell ([%d%.]+) s')) or 0 end
-- ctx: {h = host, cast = the waypoint cast behind a LEFT_DROP departure}
local function classify(hit, ctx)
    for _, r in ipairs(RULES) do
        if r.kind == hit.kind and r.fn(hit, ctx) then return r end
    end
    return nil
end
local function cast_by(ctx, who, task)
    return ctx.cast ~= nil and ctx.cast.ctx == who and (task == nil or ctx.cast.task == task)
end

-- BOARD (Activities, open LOW): Arkham's '[portal] candidate' actor dump
-- every 2 s for the whole pit (tasks/portal.lua:300-347).
rule('ARK-portal-dump-spam', 'board', 'SPAM', function(hit)
    return has(hit, 'by ArkhamAsylum') and has(hit, '[portal] ')
end, 'known BOARD LOW: Arkham [portal] candidate dump every 2 s')
-- A drop that falls inside the 0.3 s floor-portal transition: nobody can
-- react (the game loads the next floor at once). Chaos puts one there.
rule('floor-portal-transition-drop', 'expected', 'LEFT_DROP', function(hit)
    return (has(hit, '(pit_floor_portal)') or has(hit, '(pit_back_portal)') or has(hit, '(dungeon_reset)'))
        and (has(hit, '[dropped during the pit_floor_portal channel]')
            or has(hit, '[dropped during the pit_back_portal channel]')
            or has(hit, '[dropped during the dungeon_reset channel]'))
end, 'emulator: a drop injected inside the 0.3 s floor-portal / 0.1 s dungeon-reset transition')
-- KNOWN (Rosie session): the outbound Town Portal re-cast (every ~3 s, up to
-- 12 casts with refunds) when the channel breaks (the rotation's cast/evade).
rule('ROSIE-tp-recast', 'known', 'TELEPORT', function(hit)
    local list = hit.detail:match('%(max %d+%): (.*)$') or ''
    local other = false
    for item in list:gmatch('[^;]+') do
        if not item:find('town_portal->temis by Rosie', 1, true) and not item:find('...', 1, true) then other = true end
    end
    return list ~= '' and not other
end, 'known: Rosie outbound Town Portal re-cast while the channel is broken')
-- KNOWN (Rosie session): a drop that falls during Rosie's own Town Portal cast.
rule('ROSIE-tp-cast-drop', 'known', 'LEFT_DROP', function(hit, ctx)
    return has(hit, '(waypoint)') and has(hit, '[dropped during the waypoint channel]') and cast_by(ctx, 'Rosie')
end, 'known: Rosie leaving a drop that falls during the Town Portal cast')
-- New variant: the same, for Arkham's own casts (the exit teleport, exit
-- mode Teleport; its Alfred town hop).
rule('ARK-cast-drop', 'finding', 'LEFT_DROP', function(hit, ctx)
    if has(hit, '(waypoint)') and has(hit, '[dropped during the waypoint channel]') and cast_by(ctx, ARK) then
        return true
    end
    -- exit mode Reset: the drop fell after reset_all_dungeons (0.6 s before
    -- the ejection here), Guardian loot is older and is ARK-exit-unique-*
    local age = tonumber(hit.detail:match('on the ground ([%d%.]+) s'))
    return has(hit, '(dungeon_reset)') and age ~= nil and age <= 0.7
        and not has(hit, '(beyond it: Unique/Mythic within the radius)')
end, 'new variant: a drop falling during an Arkham teleport channel (exit / town hop) is left')
-- SWEEP (the harness author's finding, S2 variant): wanted drops on the
-- ground when Rosie's own automatic Town Portal starts are left; in the Pit
-- the portal back returns to the spot and they are picked up after it.
rule('ROSIE-trip-leaves-ground-drops', 'sweep', 'LEFT_DROP', function(hit)
    return has(hit, '[already wanted at the cast: town_portal by Rosie')
end, "sweep finding: Rosie's trip leaves wanted drops already on the ground (picked up after the return)")
-- Config-dependent: a Unique/Mythic beyond Rosie's pickup distance (default
-- 2 m) near the glyphstone when Arkham leaves: Arkham never walks the boss
-- loot area, Rosie never walks beyond its distance.
rule('ARK-exit-unique-beyond-distance', 'finding', 'LEFT_DROP', function(hit, ctx)
    return has(hit, '(beyond it: Unique/Mythic within the radius)')
        and (cast_by(ctx, ARK, 'exit_pit') or has(hit, '(dungeon_reset)'))
end, 'boss Unique/Mythic beyond the pickup distance left at the pit exit')
-- FINDING (Arkham tasks/portal.lua): the portal back up is excluded only by
-- an in-memory blacklist set when the world changes within 5 s of Arkham's
-- own portal click. A reload of ArkhamAsylum on floor 2+ loses it...
rule('ARK-back-portal-after-reload', 'finding', 'PIT_BACK', function(hit)
    return has(hit, 'ArkhamAsylum reloaded at')
end, 'Arkham takes the portal back up after a reload on floor 2+')
-- ...a floor that loads for longer than ~4.6 s never gets it...
rule('ARK-back-portal-slow-load', 'finding', 'PIT_BACK', function(hit)
    local tr = tonumber(hit.detail:match('after a ([%d%.]+) s transition'))
    return tr ~= nil and tr >= 4.9 and not has(hit, 'the portal back up from the floor below')
end, 'Arkham takes the portal back up when the floor transition took >= 5 s')
-- ...and once it went up, the floor above blacklists its own descend
-- portal (the arrival point is next to it) and takes its portal back up too.
rule('ARK-back-portal-chain', 'finding', 'PIT_BACK', function(hit)
    return has(hit, 'the portal back up from the floor below')
end, 'after going up once, the next floor up blacklists its descend portal and goes up again')
-- ...and the bot started on floor 2+ (QQT restarted mid-pit, a pit played
-- by hand first) never saw a portal arrival at all.
rule('ARK-back-portal-no-arrival', 'finding', 'PIT_BACK', function(hit)
    return has(hit, 'no portal arrival on this floor')
end, 'Arkham started on floor 2+ takes the portal back up')
rule('ARK-back-portal-stuck', 'finding', 'PIT_SLOW', function(hit)
    local n = tonumber(hit.detail:match('back portals taken (%d+)'))
    return n ~= nil and n >= 1
end, 'the run is stuck on an upper floor (descend portal blacklisted) until the 600 s reset timer')
rule('ARK-back-portal-abandon', 'finding', 'PIT_ABANDON', function(hit)
    local n = tonumber(hit.detail:match('back portals taken (%d+)'))
    return n ~= nil and n >= 1
end, 'the stuck run ends at the reset timer without its Guardian')
rule('ARK-floor-ping-pong', 'finding', 'LOOP', function(hit)
    return has(hit, 'world.place switches pit_') and has(hit, '<-> pit_')
end, 'floor ping-pong: each slow floor transition takes the portal back (no blacklist)')
-- FINDING (Rosie town main.lua automatic trip): Arkham 2.1.3 defers its
-- own trips while a live boss is within 30 m, but Rosie's automatic trip
-- starts 0.4 s after the bag fills, mid-Guardian fight; Arkham yields to it.
rule('ROSIE-auto-trip-in-boss-fight', 'finding', 'BOSS_TRIP', function(hit)
    return has(hit, 'cast by Rosie')
end, "Rosie's automatic Town Portal during a live Pit Guardian fight")
-- FINDING (same root): the Guardian's loot pile fills the bag and Rosie's
-- automatic trip leaves before the glyph upgrade (Arkham's own trips wait
-- for it, ARK-4 glyph_pending, at most 120 s).
rule('ROSIE-auto-trip-before-glyph', 'finding', 'GLYPH_TRIP', function(hit)
    return has(hit, 'cast by Rosie')
end, "Rosie's automatic Town Portal before the glyph upgrade")
-- By design: the 600 s reset timer overrides the glyph upgrade.
rule('ARK-glyph-reset-timer', 'expected', 'GLYPH_TRIP', function(hit)
    return has(hit, 'reset timer expired')
end, 'the reset timer (600 s) forces the exit over the glyph upgrade')
-- FINDING (Arkham tasks/upgrade_glyph.lua): once the glyphstone UI was
-- opened, an interruption (a death and the walk back from the checkpoint, an
-- evade/knock-back out of the UI's 5 m, a loading screen) closes it; back at
-- the stone the glyph list reads empty, 8 s have passed since the FIRST
-- interaction (EMPTY_LIST_TIMEOUT), so glyph_done is set without opening the
-- UI again and exit_pit leaves with chances unused.
rule('ARK-glyph-done-after-interruption', 'finding', 'GLYPH_TRIP', function(hit)
    return has(hit, 'by ArkhamAsylum') or has(hit, '(Arkham task exit_pit)')
end, 'Arkham exits with glyph upgrade chances left after an interruption at the glyphstone')
-- FINDING (LOW, Arkham tasks/alfred.lua note_hold): the hold clock
-- (trip.hold/hold_since) survives the task being preempted, so the next
-- hold with the same reason logs the time since the first one.
rule('ARK-stale-hold-log', 'finding', 'HOLD_LOG', function(hit)
    return has(hit, '[alfred] holding for')
end, "Arkham's '[alfred] holding for Ns' counts from an earlier, finished hold")
rule('LOOP-fight-explore', 'expected', 'LOOP', function(hit)
    return has(hit, 'ArkhamAsylum.task') and (has(hit, 'kill_monster <-> explore_pit') or has(hit, 'explore_pit <-> kill_monster'))
        and mean_dwell(hit) >= 3
end, 'fight / explore alternation (mean dwell >= 3 s), not a thrash')
-- Arkham's pickup yield ('Idle') against a task, several seconds each: Rosie's
-- fight hold stays on while a static chaos elite pack stands 12-14 m away
-- (inside Rosie's 14 m hysteresis, outside the rotation's 12 m; the host's
-- enemies never walk in), so the yield comes back every 15 s episode.
rule('LOOP-yield-alternation', 'expected', 'LOOP', function(hit)
    local idle = has(hit, 'ArkhamAsylum.task switches Idle <-> ')
        or (has(hit, 'ArkhamAsylum.task switches') and has(hit, ' <-> Idle '))
    return idle and mean_dwell(hit) >= 3
end, 'emulator: static enemies at 12-14 m keep the pickup yield coming back (mean dwell >= 3 s)')

-- ── the sweep ─────────────────────────────────────────────────────────────
local function parse_seeds(text)
    local out = {}
    for part in tostring(text):gmatch('[^,]+') do
        local a, b = part:match('^%s*(%d+)%s*%-%s*(%d+)%s*$')
        if a then for s = tonumber(a), tonumber(b) do out[#out + 1] = s end
        else out[#out + 1] = tonumber(part) end
    end
    return out
end

local ENV_SEEDS = os.getenv('QQT_SWEEP_SEEDS')
local SEEDS = ENV_SEEDS and ENV_SEEDS ~= '' and parse_seeds(ENV_SEEDS) or {101, 202}
local SECONDS = tonumber(os.getenv('QQT_SWEEP_SECONDS') or '') or 900
local VERBOSE = os.getenv('QQT_SWEEP_VERBOSE') == '1'
local TAIL = tonumber(os.getenv('QQT_SWEEP_TAIL') or '')
local ONLY = os.getenv('QQT_SWEEP_ONLY')

local function boss_place(W)
    local run = W.run
    return run and run.floors[#run.floors] or nil
end
local function boss_kills(W)
    local n = 0
    for _, r in ipairs(W.runs) do if r.boss_dead_at then n = n + 1 end end
    return n
end
local S = {seeds = 0, emulated = 0, hits = {}, by_rule = {}, unclassified = {}, crashes = {}, runs = 0}
local function sweep_seed(seed, o, seconds)
    seconds = seconds or SECONDS
    local t0 = os.clock()
    local h, W = start(seed, o)
    local progress, next_report = os.getenv('QQT_SWEEP_PROGRESS') == '1', h.now + 300
    -- QQT_SWEEP_PROBE=1139,1140.5 prints the state at those times.
    local probes = {}
    for t in (os.getenv('QQT_SWEEP_PROBE') or ''):gmatch('[%d%.]+') do probes[#probes + 1] = tonumber(t) end
    local function probe()
        local boss = W.run and W.run.boss
        local bd = boss and boss.health > 0 and h.place == boss_place(W) and h.pos:dist_to_ignore_z(boss.pos) or nil
        local near, nd = nil, nil
        for _, a in ipairs(h.place.actors or {}) do
            if a.enemy and (a.health or 100) > 0 then
                local d = a.pos:dist_to_ignore_z(h.pos)
                if not nd or d < nd then near, nd = a, d end
            end
        end
        print(string.format('  probe t=%.1f place=%s pos=(%.1f,%.1f) boss %s nearest enemy %s travel=%s dead=%s '
            .. 'rotation casts=%d interrupts=%d; %s', h.now, h.place.key,
            h.pos:x(), h.pos:y(), bd and string.format('alive %.1f m (hp %.0f)', bd, boss.health) or 'n/a',
            near and string.format('%s %.1f m', near.skin, nd) or '-', tostring(h.travel and h.travel.why),
            tostring(h.dead), h.rotation.casts, h.rotation.interrupts,
            h.invariants and h.invariants.status_lines() or ''))
    end
    local each = function()
        W.tick()
        while probes[1] and h.now >= probes[1] do table.remove(probes, 1); probe() end
        if progress and h.now >= next_report then
            next_report = next_report + 300
            print(string.format('  progress seed %d: t=%.0f cpu=%.1f s, log %d lines, runs %d', seed, h.now,
                os.clock() - t0, #h.log, W.completed))
            io.stdout:flush()
        end
    end
    local ok_run, err = xpcall(function() h.run(seconds, each) end, debug.traceback)
    S.seeds, S.emulated = S.seeds + 1, S.emulated + seconds
    S.runs = S.runs + W.completed
    local label = describe(h.c) .. (o and o.label and (' ' .. o.label) or '')
    local line = string.format('S2 %s: %.0f s emulated in %.1f s; pit runs opened %d, completed %d, floors %d, '
        .. 'boss kills %d, upgrades %d, shrines %d, altars %d, deaths %d, back portal taken %d, trips %d, pickups %d, '
        .. 'rotation casts %d dashes %d interrupts %d, chaos %d',
        label, seconds, os.clock() - t0, W.opens, W.completed, W.floors_entered, boss_kills(W),
        W.upgrades, W.shrines_used, W.altars_used, W.deaths, W.back_taken,
        h.count(h.waypoints, function(r) return r.context == 'Rosie' end), h.pickups or 0,
        h.rotation.casts, h.rotation.dashes, h.rotation.interrupts, h.chaos and #h.chaos.log or 0)
    print(line)
    if not ok_run then S.crashes[#S.crashes + 1] = label .. ': host crash: ' .. tostring(err) end
    for _, e in ipairs(h.errors) do
        S.crashes[#S.crashes + 1] = string.format('%s: Lua error in %s %s at t=%.1f: %s', label, e.plugin, e.kind, e.t, e.err)
    end
    for _, vi in ipairs(h.violations) do
        S.crashes[#S.crashes + 1] = string.format('%s: [%s] %s (ctx %s, owner %s) at t=%.1f', label, vi.kind, vi.detail,
            vi.context, vi.owner, vi.t)
    end
    for _, hit in ipairs(h.invariants.hits) do
        local ctx = {h = h, W = W}
        if hit.kind == 'LEFT_DROP' then ctx.cast = cast_before(h, hit.t) end
        local r = hit.kind ~= 'INTERNAL' and classify(hit, ctx) or nil
        local rec = {seed = seed, t = hit.t, kind = hit.kind, detail = hit.detail, rule = r, label = label}
        if ctx.cast then
            rec.detail = rec.detail .. string.format(' {cast by %s task=%s at t=%.1f}', ctx.cast.ctx, ctx.cast.task, ctx.cast.t)
        end
        S.hits[#S.hits + 1] = rec
        if r then
            local b = S.by_rule[r.id]
            if not b then b = {n = 0, seeds = {}, first = rec, rule = r}; S.by_rule[r.id] = b end
            b.n = b.n + 1
            b.seeds[seed] = true
        else
            S.unclassified[#S.unclassified + 1] = rec
        end
        if VERBOSE and (not ONLY or ONLY == hit.kind) then
            print(string.format('  [%s] t=%.1f %s%s', hit.kind, hit.t, r and ('(' .. r.id .. ') ') or '(UNCLASSIFIED) ',
                rec.detail))
        end
    end
    if TAIL then print(h.tail(TAIL)) end
    -- QQT_SWEEP_WINDOW=t0-t1 prints the log lines in that window (the
    -- chatty Arkham portal dump and long-path lines left out).
    -- QQT_SWEEP_GREP=<plain text> prints the matching log lines.
    local grep = os.getenv('QQT_SWEEP_GREP')
    if grep and grep ~= '' then
        for _, text in ipairs(h.log) do
            if text:find(grep, 1, true) then print('  | ' .. text:sub(1, 400)) end
        end
    end
    local window = os.getenv('QQT_SWEEP_WINDOW')
    local w0, w1
    if window then w0, w1 = window:match('^([%d%.]+)%-([%d%.]+)$') end
    if w0 then
        w0, w1 = tonumber(w0), tonumber(w1)
        for _, c in ipairs(h.tp_log) do
            if c.t >= w0 and c.t <= w1 then
                print(string.format('%.1f {teleport_to_waypoint 0x%X from %s: ctx %s, Arkham task %s}', c.t, c.sno, c.from,
                    c.ctx, c.task))
            end
        end
        for _, text in ipairs(h.log) do
            local t = tonumber(text:match('^(%-?[%d%.]+)'))
            if t and t >= w0 and t <= w1 and not text:find('[portal] candidate', 1, true)
                and not text:find('[LONG PATH]', 1, true) then print(text:sub(1, 400)) end
        end
    end
    return h, W
end

if os.getenv('QQT_SWEEP_LIST') == '1' then
    for _, seed in ipairs(SEEDS) do print(describe(config(seed, env_override({})))) end
    return
end

-- Harness check (joint_host.lua, changed with this sweep): the chaos
-- 'reload' keeps the menu values set in the session, as QQT does (the
-- widgets are recreated under the same hash). Before, a reloaded Arkham came
-- back switched off and a reloaded Rosie with a 2 m pickup distance, so the
-- rest of a seed measured an idle bot.
do
    local h = start(7, {chaos = true, rate = 1e-9, town = 'cerrigar', exit_mode = 1, distance = 15})
    h.run(1)
    h.chaos_inject('reload', {dir = ARK})
    h.chaos_inject('reload', {dir = 'Rosie'})
    local gui = h.mod(ARK, 'gui').elements
    ok(gui.main_toggle:get() == true, 'reloaded Arkham keeps its main toggle')
    ok(gui.town:get() == 1 and gui.exit_mode:get() == 1, 'reloaded Arkham keeps town and exit mode')
    ok(h.mod('Rosie', 'rosie.private.pickup.gui').elements.general.distance_slider:get() == 15,
        'reloaded Rosie keeps the pickup distance')
    h.run(20, function() h.world.tick() end)
    ok(h.world.opens >= 1, 'the reloaded Arkham opens a pit at the Cerrigar obelisk\n' .. h.tail(20))
    h.assert_clean('reload check')
    local plain = J.new({dirs = {'ArkhamAsylum'}, place = 'temis'})
    plain.mod(ARK, 'gui').elements.main_toggle:set(true)
    plain.reload(ARK)
    ok(plain.mod(ARK, 'gui').elements.main_toggle:get() == false,
        'h.reload without keep_widgets still loads the defaults (older tests)')
    print('PASS S2 harness check: a chaos reload keeps the session menu values')
end
local function trips_from_pit(h)
    local n = 0
    for _, c in ipairs(h.tp_log) do if c.ctx == 'Rosie' and c.from:match('^pit') then n = n + 1 end end
    return n
end
if ENV_SEEDS and ENV_SEEDS ~= '' then
    for _, seed in ipairs(SEEDS) do
        local passed, err = xpcall(function() sweep_seed(seed) end, debug.traceback)
        if not passed then S.crashes[#S.crashes + 1] = 'seed ' .. seed .. ': ' .. tostring(err) end
    end
elseif os.getenv('QQT_SWEEP_FINDINGS') ~= '1' then
    -- D1 scripted chaos (fixed times): a full bag twice mid-pit, a death,
    -- reloads of Arkham (on a first floor: see F1 for floor 2+) and Rosie,
    -- an elite pack, a Mythic, a loading screen and a wall; Temis home,
    -- exit mode Reset, pickup 15 m.
    local passed, err = xpcall(function()
        local h, W = sweep_seed(101, {label = '(D1 scripted)', town = 'temis', exit_mode = 0, distance = 15,
            all_plugins = false, schedule = {
                {t = 1120, kind = 'elite'}, {t = 1200, kind = 'reload', dir = ARK}, {t = 1230, kind = 'bag_full'},
                {t = 1265, kind = 'death'}, {t = 1400, kind = 'drop', mythic = true},
                {t = 1450, kind = 'reload', dir = 'Rosie'}, {t = 1500, kind = 'limbo', seconds = 4},
                {t = 1560, kind = 'obstacle'}, {t = 1620, kind = 'bag_full'}}}, 800)
        ok(W.completed >= 3, 'D1: at least 3 pit runs completed, got ' .. W.completed)
        ok(W.upgrades >= 6, 'D1: glyph upgrades after the Guardian, got ' .. W.upgrades)
        ok(trips_from_pit(h) >= 1, 'D1: Rosie trips out of the pit, got ' .. trips_from_pit(h))
        ok(h.logged('resuming the run') >= 1, 'D1: a trip returns into the same pit run')
        print(string.format('  D1: %d Rosie trip(s) out of the pit, %d resumed run(s)', trips_from_pit(h),
            h.logged('resuming the run')))
        ok(W.deaths >= 1 and not h.dead, 'D1: the death was revived')
        ok(W.resets >= 3, 'D1: exits by dungeon reset')
    end, debug.traceback)
    if not passed then S.crashes[#S.crashes + 1] = 'D1: ' .. tostring(err) end
    -- D2 seeded random chaos, Cerrigar home (the Rosie trips hop to Temis),
    -- exit mode Teleport, pickup 8 m.
    passed, err = xpcall(function()
        local _, W = sweep_seed(202, {label = '(D2 seeded)', town = 'cerrigar', exit_mode = 1, distance = 8,
            rate = 1.5}, 600)
        ok(W.completed >= 2, 'D2: at least 2 pit runs completed, got ' .. W.completed)
    end, debug.traceback)
    if not passed then S.crashes[#S.crashes + 1] = 'D2: ' .. tostring(err) end
end

-- Minimal repros of this sweep's findings (QQT_SWEEP_FINDINGS=1). Each
-- prints REPRODUCED / not reproduced; QQT_SWEEP_STRICT=1 fails on a
-- reproduced finding, so the fixing session gets a test that fails on the
-- old code and passes on the fix.
local FINDINGS = {
    {id = 'F1', rule = 'ARK-back-portal-after-reload', seed = 101, seconds = 800, title = 'Arkham reloaded on floor 3 '
        .. 'takes the portal back up, the floor above blacklists its own descend portal, the run sits until the 600 s reset',
        o = {town = 'temis', exit_mode = 0, distance = 15, all_plugins = false,
            schedule = {{t = 1330, kind = 'reload', dir = ARK}}}},
    {id = 'F1b', rule = 'ARK-back-portal-no-arrival', seed = 101, seconds = 120, title = 'the bot started on floor 2 of '
        .. 'an open pit (no portal arrival seen) takes the portal back up',
        o = {town = 'temis', exit_mode = 0, distance = 15, all_plugins = false, chaos = false, floors = 3,
            start_on_floor = 2}},
    {id = 'F2', rule = 'ARK-back-portal-slow-load', seed = 5, seconds = 300, title = 'a floor transition of 5 s or more '
        .. '(loading screen 4.7 s here) is "not via portal": no back-portal blacklist, floor ping-pong',
        o = {chaos = false, floor_loading = 4.7}},
    {id = 'F3', rule = 'ROSIE-auto-trip-in-boss-fight', seed = 101, seconds = 200, title = "Rosie's automatic Town "
        .. 'Portal 0.4 s after the bag fills, in melee with the live Pit Guardian (Arkham only defers its own trips)',
        o = {town = 'temis', exit_mode = 0, distance = 15, all_plugins = false, schedule = {{t = 1140, kind = 'bag_full'}}}},
    {id = 'F3b', rule = 'ROSIE-auto-trip-before-glyph', seed = 101, seconds = 200, title = "the Guardian's loot pile "
        .. "fills the bag; Rosie's automatic Town Portal 3.6 s after the kill, the glyphstone unused",
        o = {town = 'temis', exit_mode = 0, distance = 15, all_plugins = false, chaos = false, bag_near_full = true}},
    {id = 'F6', rule = 'ARK-glyph-done-after-interruption', seed = 101, seconds = 200, title = 'a death after the first '
        .. 'glyph upgrade: back at the stone the list reads empty 8 s after the first interaction, glyph marked done, '
        .. 'the pit is reset with 2 chances unused',
        o = {town = 'temis', exit_mode = 0, distance = 15, all_plugins = false, schedule = {{t = 1159, kind = 'death'}}}},
    {id = 'F6b', rule = 'ARK-glyph-done-after-interruption', seed = 60, seconds = 740, title = 'an elite pack right '
        .. "after the Guardian: the rotation's evade takes the player out of the glyph UI after 2 upgrades, 1 chance "
        .. 'unused at the exit (seeded chaos, no death)', o = {}},
    {id = 'F4', rule = 'ARK-exit-unique-beyond-distance', seed = 4, seconds = 300, title = 'with the shipped 2 m pickup '
        .. 'distance a boss Mythic 2.4 m from the glyphstone stays behind at the pit exit',
        o = {chaos = false, distance = 2, boss_mythic = 1}},
    {id = 'F5', rule = 'ARK-stale-hold-log', seed = 1, seconds = 900, title = "the second Rosie trip logs "
        .. "'[alfred] holding for Ns: Alfred busy with another caller' with N counted from the first trip",
        o = {kinds = {'bag_full'}, rate = 0.4}},
}
local function run_finding(f, strict)
    local passed, err = xpcall(function()
        local o = {label = '(' .. f.id .. ')'}
        for k, val in pairs(f.o) do o[k] = val end
        local before = S.by_rule[f.rule] and S.by_rule[f.rule].n or 0
        sweep_seed(f.seed, o, f.seconds)
        local after = S.by_rule[f.rule] and S.by_rule[f.rule].n or 0
        local got = after > before
        print(string.format('%s %s [%s]: %s', f.id, got and 'REPRODUCED' or 'not reproduced', f.rule, f.title))
        if strict and got then error(f.id .. ' reproduced (' .. f.rule .. ')') end
    end, debug.traceback)
    if not passed then S.crashes[#S.crashes + 1] = f.id .. ': ' .. tostring(err) end
end
if os.getenv('QQT_SWEEP_FINDINGS') == '1' then
    local strict = os.getenv('QQT_SWEEP_STRICT') == '1'
    local pick_one = os.getenv('QQT_SWEEP_FINDING')
    for _, f in ipairs(FINDINGS) do
        if not pick_one or pick_one == '' or pick_one == f.id then run_finding(f, strict) end
    end
end

print(string.format('S2 sweep: %d seed(s), %.1f emulated hours, %d pit runs completed, %d invariant hit(s), %d unclassified, %d crash(es)',
    S.seeds, S.emulated / 3600, S.runs, #S.hits, #S.unclassified, #S.crashes))
local ids = {}
for id in pairs(S.by_rule) do ids[#ids + 1] = id end
table.sort(ids)
for _, id in ipairs(ids) do
    local b = S.by_rule[id]
    local seeds = {}
    for s in pairs(b.seeds) do seeds[#seeds + 1] = s end
    table.sort(seeds)
    print(string.format('  %-28s %-8s %3d hit(s), seeds %s; first: seed %d t=%.1f %s', id, b.rule.class, b.n,
        table.concat(seeds, ','), b.first.seed, b.first.t, b.first.detail:sub(1, 400)))
end
for i, rec in ipairs(S.unclassified) do
    if i > 40 then print('  ... ' .. (#S.unclassified - 40) .. ' more'); break end
    print(string.format('  UNCLASSIFIED seed %d t=%.1f [%s] %s', rec.seed, rec.t, rec.kind, rec.detail:sub(1, 600)))
end
for _, c in ipairs(S.crashes) do print('  CRASH ' .. c:sub(1, 2000)) end
if #S.crashes > 0 or #S.unclassified > 0 then
    failures[#failures + 1] = string.format('%d crash(es), %d unclassified invariant hit(s)', #S.crashes, #S.unclassified)
end
if #failures > 0 then error('S2 sweep: ' .. table.concat(failures, '; ')) end
print(string.format('PASS: S2 pit sweep, %d checks', checks))
