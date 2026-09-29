-- QQT_Warpigz_v3 scenario sweep S4: the owner's War Plan setup. WarPigs +
-- WarPug + every activity plugin (ArkhamAsylum, HelltideRevamped, HordeDev,
-- Reaper, WonderCity) + SilentRaven + Batmobile + Rosie (town trips and
-- pickup) + the Universal Rotation stand-in, long seeded runs with chaos and
-- the invariant monitors on (audit/tests/joint_host.lua: TELEPORT /
-- LEFT_DROP / STALL / SPAM / LOOP).
--
-- The War Plan day is scripted here (the joint host has one flat place per
-- activity and a static board):
--   * the War Plan table in Temis: every plan gets a new seeded board (2-4
--     layers of Pit / Undercity / Helltide / Infernal Hordes / Andariel,
--     sometimes a Nightmare Dungeon node WarPug must skip); WarPug's confirm
--     turns the selected path into the plan's quest chain, one War Plan quest
--     at a time, then WarPlans_QST_TurnIn_Rewards (Tyrael);
--   * Pit: the obelisk in Temis opens a NEW pit (new world id) with trash
--     and the Pit Guardian; its death completes the Pit step and leaves the
--     Awakened Glyphstone (3 upgrade chances) and loot; a dungeon reset
--     ejects to Temis next to the obelisk;
--   * Undercity: the Kurast brazier's tribute dialog (ACCEPT) opens a portal
--     to a NEW two-floor Undercity (a warp pad / PortalSwitch on floor 1, the
--     Lacuni boss and the attunement chest on floor 2); the chest's loot
--     burst completes the step; a reset ejects to Kurast;
--   * Helltide: the Helltide zone (buff); monsters spawn near the player;
--     the step completes after a seeded time with enough kills;
--   * Infernal Hordes: the host's scripted horde (waves, door, Council,
--     chest room); the Council's death completes the step;
--   * Andariel (Reaper): the host's lair script (altar stays); the boss's
--     death completes the step;
--   * Turn-in at Tyrael; afterwards the Tree of Whispers has a reward ready
--     on some plans (SilentRaven's Whisper claim, managed by WarPigs).
-- Scenario invariants added to the host's monitors (h.invariants.hit):
--   PLAN_SLOW   one War Plan step open for longer than its bound (quest up
--               with no completion: Pit 600 s, Undercity 720 s, Helltide
--               600 s, Hordes 720 s, boss 480 s, turn-in 300 s);
--   IDLE_TEMIS  no War Plan quest and no plan session for 300 s while the
--               player stands in Temis (WarPug never plans again);
--   MISROUTE    a teleport cast that leaves the current step's activity
--               world while its quest is still up and nobody asked for a
--               town trip (Rosie's own trips and requests are allowed).
-- Every hit is classified by RULES below: 'known' (being fixed by a plugin
-- session), 'sweep' (reported by the harness author), 'board' (an open BOARD
-- item), 'finding' (reported by this sweep), 'expected' (by design /
-- emulator). An unclassified hit fails the file.
--
-- Findings of this sweep (rules below, minimal repros in FINDINGS):
--   F1 WarPigs + Rosie: town-only Rosie request sent during WarPigs' own
--      Horde War Plan teleport; the player stands in the Horde ~240 s.
--   F2 Rosie: a drop that falls during another plugin's travel channel.
--   F3 Rosie: a town service started in town idles 240 s after a foreign
--      teleport takes the player out of town, then latches a failure.
--   F4 HordeDev: frozen at the arena centre after the last wave (forever).
--   F5 WonderCity: a Rosie trip during the exit delay restarts the finished
--      Undercity as a new run (~600 s).
--   F6 WarPug: a one-tick world blip during planning halts it for the session.
--
-- Default (the suite runs every file under Lua 5.4 and LuaJIT): D1 (seed
-- 404, seeded chaos incl. plugin reloads, 1200 s) must run clean (no Lua
-- error, no caller-context violation, no monitor error, no unclassified hit)
-- and complete at least one War Plan.
--
-- Heavy sweep (developer, not the suite):
--   QQT_SWEEP_SEEDS=1-20 QQT_SWEEP_SECONDS=7200 \
--     luajit -e 'SUITE_ROOT="<repo>"' audit/tests/test_sweep_S4_warplan.lua
-- QQT_SWEEP_SEEDS takes "a-b" or "a,b,c"; QQT_SWEEP_VERBOSE=1 prints every
-- hit; QQT_SWEEP_ONLY=<kind> only that kind; QQT_SWEEP_TAIL=N the last N
-- log lines; QQT_SWEEP_GREP=<text> the matching log lines;
-- QQT_SWEEP_WINDOW=t0-t1 the log in a window; QQT_SWEEP_PROBE=t1,t2 the
-- player / step / task state at those times; QQT_SWEEP_PROGRESS=1 a
-- CPU-time line every 600 emulated s; QQT_SWEEP_LIST=1 lists each seed's
-- configuration. To minimise a repro override the seed's draw with
-- QQT_SWEEP_TELEPORT=0|1 (WarPigs 'Use teleport'), _DISTANCE=m (Rosie pickup),
-- _AUTO=0|1 (Rosie automatic trips), _RATE=per_min, _WHISPER=0..1, and the
-- chaos with _NOCHAOS=1, _KINDS=drop,death, _CHAOS_ONLY=3,7 or
-- _SCHEDULE=1330:reload:WarPigs,1400:drop:mythic (absolute times, t starts
-- at 1000); _PLANS=pit,horde (a fixed node list for every plan).
-- QQT_SWEEP_FINDINGS=1 runs the minimal repro of each finding (F1..,
-- QQT_SWEEP_FINDING=F2 just one); with QQT_SWEEP_STRICT=1 a reproduced
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

local WP, PUG, SR, ARK, WC, HR, HD, RP = 'WarPigs', 'WarPug', 'SilentRaven', 'ArkhamAsylum', 'WonderCity',
    'HelltideRevamped', 'HordeDev', 'Reaper'
local CONSUMER = {name = 'SweepS4', dir = ROOT .. '/audit/tests/', loaded = {}}
local function el(h, dir) return assert(h.mod(dir, dir == SR and 'silent_raven.gui' or 'gui'), dir).elements end

-- War Plan nodes: board name, the quest it becomes, the activity world key.
local NODES = {
    pit = {name = 'Warplans_ThePit', quest = 'WarPlans_QST_ThePit', label = 'Pit'},
    uc = {name = 'Warplans_Undercity', quest = 'WarPlans_QST_Undercity', label = 'Undercity'},
    ht = {name = 'Warplans_Helltide', quest = 'WarPlans_QST_Helltide_TorturedGifts', label = 'Helltide'},
    horde = {name = 'Warplans_InfernalHordes', quest = 'WarPlans_QST_InfernalHordes_BSK', label = 'Hordes'},
    boss = {name = 'Warplans_BossLair_Andariel', quest = 'WarPlans_QST_BossLair_Andariel', label = 'Andariel'},
    nmd = {name = 'Warplans_NightmareDungeons', quest = nil, label = 'Nightmare Dungeon'},
}
local NODE_KEYS = {'pit', 'uc', 'ht', 'horde', 'boss'}
local TURNIN_Q = 'WarPlans_QST_TurnIn_Rewards'
local STEP_BOUND = {pit = 600, uc = 720, ht = 600, horde = 720, boss = 480, turnin = 300}

-- ── the scripted War Plan world ───────────────────────────────────────────
local function letters(n)
    local s = ''
    repeat
        s = string.char(65 + (n - 1) % 26) .. s
        n = math.floor((n - 1) / 26)
    until n <= 0
    return s
end

local function build_world(h, seed, o)
    local rng = J.rng(seed * 7919 + 41)
    local v, P = h.v, h.P
    local W = {plans = {}, plan = nil, steps_done = 0, plans_done = 0, turnins = 0, whispers_ready = 0,
        pit_runs = 0, uc_runs = 0, kills = 0, deaths = 0, events = {}, death_times = {}, step = nil,
        next_id = 7000, bag_fills = 0, glyph_ui = false, chances = 0, upgrades = 0, resets = 0}
    h.world = W
    local function note(kind, detail)
        W.events[#W.events + 1] = {t = h.now, kind = kind, detail = detail}
        h.log[#h.log + 1] = string.format('%.1f [warplan] %s: %s', h.now, kind, tostring(detail))
    end
    W.note = note
    local function new_id() W.next_id = W.next_id + 1; return W.next_id end
    local function new_place(key, fields)
        local place = {id = new_id(), town = false, spawn = v(0, 0), actors = {}, items = {}, key = key,
            created_at = h.now}
        for k, val in pairs(fields) do place[k] = val end
        P[key] = place -- h.remove_actor only searches the host's place table
        return place
    end
    local function drop_fields(roll, mythic_share)
        if roll < (mythic_share or 0) then
            return {name = 'Helm_Unique_Generic_005', sno = 2647147, rarity = 6, ancestral = true, ga = 1,
                affixes = {{affix_name_hash = 2662414, get_name = function() return 'Helm_Unique_Generic_005' end},
                    {affix_name_hash = 2628989, get_name = function() return 'S14_Mythic_UniquePotency' end}}}
        elseif roll < 0.55 then
            return {name = 'Helm_Legendary_Chaos', rarity = 5, ancestral = true, ga = rng.int(0, 3)}
        end
        return {name = 'Helm_Rare_Joint', rarity = 3, ga = 0}
    end
    local function trash(place, n, x0, x1, y0, y1, drop_chance, prefix)
        for i = 1, n do
            local x, y = rng.range(x0, x1), rng.range(y0, y1)
            local m = h.actor(place, (prefix or 'Trash_') .. i, x, y, {enemy = true, health = rng.int(80, 240)})
            m.on_death = function()
                h.remove_actor(m)
                W.kills = W.kills + 1
                if rng.chance(drop_chance or 0.15) and h.drop then
                    h.drop(place, m.pos:x() + rng.range(-1.5, 1.5), m.pos:y() + rng.range(-1.5, 1.5),
                        drop_fields(rng.range(0.1, 1)))
                end
            end
        end
    end
    local function loot_pile(place, x, y, n, mythic_share)
        if not h.drop then return end
        for _ = 1, n do
            local ang, d = rng.range(0, 2 * math.pi), rng.range(1, 4.5)
            h.drop(place, x + math.cos(ang) * d, y + math.sin(ang) * d, drop_fields(rng.next(), mythic_share))
        end
    end

    -- A portal entry is a loading transition, not a cast: the rotation stub
    -- cannot break it and a waypoint cast in the same moment does not replace
    -- it (the host models every travel as a channel). One frame.
    W.PORTAL_ENTRY = 0.05
    local PORTALS = {pit_portal = true, uc_portal = true, uc_floor_portal = true, horde_portal = true,
        town_portal = true}
    function W.portal_entry(tr) return tr ~= nil and tr.phase == 'channel' and PORTALS[tr.why] == true end
    local function enter(place, why, pos)
        if h.travel then return false end -- a second click during the transition does nothing
        h.travel_to(place, W.PORTAL_ENTRY, why)
        if pos then h.travel.pos = pos end
        return true
    end

    -- ── the current War Plan step ────────────────────────────────────────
    -- W.step = {key, quest, t (quest up), done_at}; W.plan = {nodes, i}.
    local function set_quest(q)
        if q then h.set_quests({q}) else h.set_quests({}) end
    end
    local on_step = {}
    function W.start_step(key)
        local quest = key == 'turnin' and TURNIN_Q or NODES[key].quest
        W.step = {key = key, quest = quest, t = h.now}
        set_quest(quest)
        note('step', string.format('plan %d step %s (%s)', W.plan and W.plan.n or 0, key, quest))
        if on_step[key] then on_step[key]() end
        -- "Full bag / stash between steps": a seeded share of the steps start
        -- with a full bag (the hand-off must carry a Rosie trip).
        if o.bag_between and rng.chance(o.bag_between) and h.chaos_inject then
            W.bag_fills = W.bag_fills + 1
            h.chaos_inject('bag_full')
        end
    end
    -- The current step's objective is complete: the next quest follows a
    -- moment later (the game swaps the quest).
    function W.complete(key, why)
        local s = W.step
        if not s or s.key ~= key or s.done_at then return end
        s.done_at = h.now
        W.steps_done = W.steps_done + 1
        note('complete', string.format('%s after %.0f s: %s', key, h.now - s.t, why or ''))
        local plan = W.plan
        set_quest(nil)
        h.at(1.0, function()
            if W.step ~= s then return end
            if key == 'turnin' then
                W.step, W.plan = nil, nil
                W.plans_done = W.plans_done + 1
                plan.done_at = h.now
                note('plan', string.format('plan %d done (%d steps) in %.0f s', plan.n, #plan.nodes, h.now - plan.t))
                if rng.chance(o.whisper or 0.5) then
                    h.bounty_ready = true
                    W.whispers_ready = W.whispers_ready + 1
                    note('whisper', 'the Tree of Whispers has a reward ready')
                end
                return
            end
            plan.i = plan.i + 1
            W.start_step(plan.nodes[plan.i] or 'turnin')
        end)
    end

    -- ── the War Plan board (WarPug) ──────────────────────────────────────
    local function new_board()
        local b = h.board
        local count = o.nodes and #o.nodes or rng.int(2, 4)
        local pool = {}
        for _, k in ipairs(NODE_KEYS) do pool[#pool + 1] = k end
        local layers, names, id = {}, {}, 100 + 10 * #W.plans
        for l = 1, count do
            local layer = {}
            local first = o.nodes and o.nodes[l] or pool[rng.int(1, #pool)]
            if not o.nodes and rng.chance(0.15) then
                id = id + 1; layer[#layer + 1] = id; names[id] = NODES.nmd.name
            end
            id = id + 1; layer[#layer + 1] = id; names[id] = NODES[first].name
            if rng.chance(0.5) then
                local other = pool[rng.int(1, #pool)]
                id = id + 1; layer[#layer + 1] = id; names[id] = NODES[other].name
            end
            layers[l] = layer
        end
        b.layers, b.names, b.required, b.selected = layers, names, count, {}
    end
    W.new_board = new_board
    new_board()
    local by_name = {}
    for key, n in pairs(NODES) do by_name[n.name] = key end
    h.on_confirm = function(path)
        local nodes = {}
        for _, id in ipairs(path) do
            local key = by_name[h.board.names[id]]
            if key and key ~= 'nmd' then nodes[#nodes + 1] = key end
        end
        local plan = {n = #W.plans + 1, nodes = nodes, i = 1, t = h.now}
        W.plans[#W.plans + 1] = plan
        W.plan = plan
        note('plan', string.format('plan %d confirmed: %s', plan.n, table.concat(nodes, ' -> ')))
        new_board() -- the next visit sees a new board
        h.at(1.0, function() if W.plan == plan then W.start_step(nodes[1] or 'turnin') end end)
    end
    -- Where warplan.teleport_to_activity() lands for the current quest.
    local DEST = {pit = 'temis', uc = 'kurast', ht = 'helltide', horde = 'bsk', boss = 'lair', turnin = 'temis'}
    h.warplan_dest = function()
        local s = W.step
        if not s or s.done_at then return nil end
        return DEST[s.key]
    end
    -- Turn-in: Tyrael (the host removes the TurnIn quest 0.5 s later).
    local tyrael_interact = h.tyrael.on_interact
    h.tyrael.on_interact = function(hh, a)
        tyrael_interact(hh, a)
        if W.step and W.step.key == 'turnin' then
            h.at(0.5, function() W.complete('turnin', 'rewards handed in at Tyrael') end)
        end
    end

    -- ── Pit ───────────────────────────────────────────────────────────────
    local G = h.G
    local tower = h.pit_tower
    function W.new_pit()
        W.pit_runs = W.pit_runs + 1
        local n = W.pit_runs
        local len = 120 + rng.int(0, 50)
        local place = new_place('pit_' .. letters(n):lower(), {name = 'PIT_Joint_Floor', zone = 'PIT_Subzone',
            box = {-25, len + 15, -30, 30}, slide = true, walls = {}, pit = true})
        local x = math.floor(len / 2)
        local gap = rng.range(-15, 15)
        place.walls[1] = {x, x + 2, -30, gap - 4}
        place.walls[2] = {x, x + 2, gap + 4, 30}
        trash(place, rng.int(4, 8), 12, len - 10, -22, 22, 0.18, 'Pit_Trash_')
        local boss = h.actor(place, 'Pit_Guardian_Joint', len, rng.range(-12, 12),
            {enemy = true, boss = true, health = rng.int(1200, 2400)})
        boss.max_health = boss.health
        place.boss = boss
        boss.on_death = function()
            h.remove_actor(boss)
            place.boss_dead_at = h.now
            note('pit', 'Pit Guardian of ' .. place.key .. ' killed')
            W.chances = 3
            local gx, gy = boss.pos:x() - 3, boss.pos:y()
            place.glyph = h.actor(place, 'Gizmo_Paragon_Glyph_Upgrade', gx, gy)
            place.glyph.on_interact = function()
                if h.pos:dist_to_ignore_z(place.glyph.pos) <= 5 then W.glyph_ui = true end
            end
            loot_pile(place, boss.pos:x(), boss.pos:y(), rng.int(2, 5), o.boss_mythic or 0.08)
            W.complete('pit', 'Pit Guardian killed')
        end
        return place
    end
    G.utility.open_pit_portal = function()
        h.pit_opens = h.pit_opens + 1
        h.vendor_screen = false
        if h.place ~= P.temis or W.pit_portal then return end
        local place = W.new_pit()
        local portal = h.actor(P.temis, 'EGD_MSWK_World_Portal_01', tower.pos:x() + 4, tower.pos:y() - 6)
        W.pit_portal = portal
        note('pit', 'pit ' .. place.key .. ' opened')
        portal.on_interact = function()
            if enter(place, 'pit_portal') then
                h.remove_actor(portal)
                if W.pit_portal == portal then W.pit_portal = nil end
            end
        end
    end
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
    rawset(G, 'get_glyphs', function()
        local glyph = h.place.glyph
        if not (W.glyph_ui and glyph and h.pos:dist_to_ignore_z(glyph.pos) <= 5) then return {} end
        return glyphs
    end)
    rawset(G, 'upgrade_glyph', function(g)
        if not W.glyph_ui or W.chances <= 0 or type(g) ~= 'table' then return false end
        W.chances, W.upgrades = W.chances - 1, W.upgrades + 1
        if rng.chance(0.85) then g.level = g.level + 1 end
        return true
    end)

    -- ── Undercity ─────────────────────────────────────────────────────────
    local brazier = h.brazier
    function W.new_undercity()
        W.uc_runs = W.uc_runs + 1
        local n = W.uc_runs
        local f1 = new_place('uc_' .. letters(n):lower() .. '_one', {name = 'X1_Undercity_Joint',
            zone = 'X1_Undercity_Ziggurat_01', box = {-60, 80, -40, 40}, slide = true, undercity = true})
        local f2 = new_place('uc_' .. letters(n):lower() .. '_two', {name = 'X1_Undercity_Joint',
            zone = 'X1_Undercity_Ziggurat_02', box = {-60, 90, -50, 50}, slide = true, undercity = true})
        trash(f1, rng.int(3, 6), 10, 70, -30, 30, 0.12, 'X1_Undercity_Trash_')
        trash(f2, rng.int(3, 6), 10, 80, -40, 40, 0.12, 'X1_Undercity_Trash_')
        local px = rng.range(35, 70)
        local py = rng.range(-25, 25)
        h.actor(f1, 'X1_Undercity_WarpPad', px - 1, py)
        local sw = h.actor(f1, 'X1_Undercity_PortalSwitch', px, py)
        sw.on_interact = function() enter(f2, 'uc_floor_portal') end
        local boss = h.actor(f2, 'X1_Undercity_Lacuni_Boss', rng.range(50, 80), rng.range(-30, 30),
            {enemy = true, boss = true, health = rng.int(900, 1800)})
        boss.max_health = boss.health
        boss.on_death = function()
            boss.health, boss.dead_at = 0, h.now
            f2.boss_dead_at = h.now
            note('undercity', 'Lacuni boss of ' .. f2.key .. ' killed')
            h.at(1.5, function()
                h.remove_actor(boss)
                local chest = h.actor(f2, 'X1_Undercity_Chest_Attunement_Joint', boss.pos:x() + 2, boss.pos:y())
                chest.on_interact = function()
                    if chest.opened then return end
                    chest.opened, chest.interactable = true, false
                    loot_pile(f2, chest.pos:x(), chest.pos:y(), rng.int(3, 5), o.boss_mythic or 0.08)
                    note('undercity', 'attunement chest opened')
                    W.complete('uc', 'attunement chest opened')
                    h.at(3, function() h.remove_actor(chest) end)
                end
            end)
        end
        return f1, f2
    end
    brazier.on_interact = function() h.vendor_screen = true end
    local accepts = 0
    h.on_click = function()
        if not h.vendor_screen then return end
        local n = h.logged('left-click ACCEPT')
        if n <= accepts then return end
        accepts = n
        h.vendor_screen = false
        if W.uc_portal then return end
        local f1 = W.new_undercity()
        local portal = h.actor('kurast', 'Portal_Dungeon_Undercity', -1455, -215)
        W.uc_portal = portal
        note('undercity', 'tribute accepted: portal to ' .. f1.key)
        portal.on_interact = function()
            if enter(f1, 'uc_portal') then
                h.remove_actor(portal)
                if W.uc_portal == portal then W.uc_portal = nil end
            end
        end
    end
    -- A dungeon reset ejects to the town the run started from.
    rawset(G, 'reset_all_dungeons', function()
        h.resets = h.resets + 1
        W.resets = W.resets + 1
        local place = h.place
        if h.travel or not (place.pit or place.undercity) then return end
        local town, pos = P.temis, v(tower.pos:x() + 6, tower.pos:y() + 4)
        if place.undercity then town, pos = P.kurast, v(brazier.pos:x() + 6, brazier.pos:y() + 4) end
        h.at(0.5, function()
            if h.place == place and not h.travel then
                note('exit', 'dungeon reset: ' .. place.key .. ' left for ' .. town.key)
                h.travel_to(town, 0.1, 'dungeon_reset')
                h.travel.pos = pos
            end
        end)
    end)

    -- ── Helltide ──────────────────────────────────────────────────────────
    P.helltide.helltide = true
    local ht = {need = 0, kills0 = 0, next_spawn = 0}
    W.ht = ht
    on_step.ht = function()
        ht.need = rng.int(90, 200)
        ht.kills0, ht.stay = W.kills, 0
    end
    local function helltide_tick(dt)
        local s = W.step
        if h.place ~= P.helltide or h.dead then return end
        if s and s.key == 'ht' and not s.done_at then
            ht.stay = (ht.stay or 0) + dt
            if ht.stay >= ht.need and W.kills - ht.kills0 >= 4 then
                W.complete('ht', string.format('%.0f s in the Helltide, %d kills', ht.stay, W.kills - ht.kills0))
            end
        end
        if h.now < ht.next_spawn then return end
        ht.next_spawn = h.now + rng.range(8, 20)
        local alive = 0
        for _, a in ipairs(P.helltide.actors) do if a.enemy and (a.health or 0) > 0 then alive = alive + 1 end end
        if alive >= 8 then return end
        local ang, d = rng.range(0, 2 * math.pi), rng.range(10, 25)
        local x, y = h.pos:x() + math.cos(ang) * d, h.pos:y() + math.sin(ang) * d
        if not h.walkable(v(x, y)) then return end
        for i = 1, rng.int(2, 4) do
            local m = h.actor(P.helltide, 'Helltide_Monster_' .. i, x + rng.range(-2, 2), y + rng.range(-2, 2),
                {enemy = true, health = rng.int(80, 200)})
            m.on_death = function()
                h.remove_actor(m)
                W.kills = W.kills + 1
                if rng.chance(0.15) and h.drop then
                    h.drop(P.helltide, m.pos:x(), m.pos:y(), drop_fields(rng.range(0.1, 1)))
                end
            end
        end
    end

    -- ── Infernal Hordes ───────────────────────────────────────────────────
    local A = h.setup_horde({quest_done = false, waves = o.waves or 6, monsters = 3})
    W.arena = A
    -- Every arrival that starts a new horde is a new instance: the last
    -- horde's ground items are gone too (the host clears only the actors).
    local horde_arrive = P.bsk.on_arrive
    P.bsk.on_arrive = function(hh, trip)
        if not (trip and (trip.why == 'alfred_return' or trip.why == 'town_portal')) then P.bsk.items = {} end
        return horde_arrive(hh, trip)
    end
    local horde_seen_council = nil

    -- ── Andariel (Reaper) ────────────────────────────────────────────────
    on_step.boss = function()
        P.lair.actors, P.lair.items = {}, {}
        h.setup_lair(function()
            loot_pile(P.lair, -13, -16, rng.int(2, 4), o.boss_mythic or 0.08)
            W.complete('boss', 'Andariel killed')
        end, {altar_stays = true})
    end

    -- Equipped gear: a death costs 10 % durability (Rosie repairs <= 10 %).
    h.equipped = {h.gear({name = 'Helm_Rare_Joint', durability = 100}), h.gear({name = 'Chest_Rare_Joint', durability = 100})}
    -- Floor loot the way the game reports it (ground items within the radius).
    G.loot_manager.any_item_around = function(pos, radius)
        pos = pos or h.pos
        for _, item in ipairs(h.place.items or {}) do
            if not item.picked and item.pos and item.pos:dist_to_ignore_z(pos) <= (radius or 30) then return true end
        end
        return false
    end

    -- ── scenario invariants ───────────────────────────────────────────────
    -- A Pit / Undercity instance counts only if it was opened for this step
    -- (a pit -> pit or undercity -> undercity plan leaves the finished one).
    function W.in_step_world(key)
        local place = h.place
        local since = W.step and W.step.t or 0
        if key == 'pit' then return place.pit == true and (place.created_at or 0) >= since end
        if key == 'uc' then return place.undercity == true and (place.created_at or 0) >= since end
        if key == 'ht' then return place == P.helltide end
        if key == 'horde' then return place == P.bsk end
        if key == 'boss' then return place == P.lair end
        return false
    end
    W.was_dead, W.last_tick = false, h.now
    local idle = {since = nil, hit = nil}
    function W.tick()
        local dt = h.now - W.last_tick
        W.last_tick = h.now
        if h.dead and not W.was_dead then
            W.deaths = W.deaths + 1
            W.death_times[#W.death_times + 1] = h.now
            for _, item in ipairs(h.equipped) do item.durability = math.max(0, item.durability - 10) end
        end
        W.was_dead = h.dead
        local glyph = h.place.glyph
        if W.glyph_ui and not (glyph and h.pos:dist_to_ignore_z(glyph.pos) <= 5) then W.glyph_ui = false end
        helltide_tick(dt)
        -- Hordes: the Council's death completes the step.
        local s = W.step
        if s and s.key == 'horde' and not s.done_at and A.council_dead_at and A.council_dead_at >= s.t
            and horde_seen_council ~= A.council_dead_at then
            horde_seen_council = A.council_dead_at
            W.complete('horde', 'Council killed (run ' .. A.runs .. ')')
        end
        local inv = h.invariants
        if not inv then return end
        -- PLAN_SLOW: a step open for longer than its bound.
        if s and not s.done_at and not s.slow and h.now - s.t > STEP_BOUND[s.key] then
            s.slow = true
            inv.hit('PLAN_SLOW', string.format('plan %d step %s (%s) open for %d s (since t=%.1f): player in %s at '
                .. '(%.1f, %.1f); %s', W.plan and W.plan.n or 0, s.key, s.quest, STEP_BOUND[s.key], s.t, h.place.key,
                h.pos:x(), h.pos:y(), inv.status_lines()))
        end
        -- IDLE_TEMIS: no plan at all for 300 s while the player is in Temis.
        if not W.step and h.place == P.temis and not h.dead then
            idle.since = idle.since or h.now
            if h.now - idle.since > 300 and not idle.hit then
                local pug = h.G.WarPugPlugin
                local okp, st = pcall(function() return pug and pug.status and pug.status() end)
                idle.hit = inv.hit('IDLE_TEMIS', string.format('no War Plan quest and no plan for 300 s in Temis (since '
                    .. 't=%.1f); WarPug %s; bounty ready %s; %s', idle.since,
                    okp and type(st) == 'table' and tostring(st.state) .. ' ' .. tostring(st.status_line or st.halt_reason or '') or '?',
                    tostring(h.bounty_ready), inv.status_lines()))
            end
        else
            idle.since, idle.hit = nil, nil
        end
    end
    return W
end

-- ── one seeded run ────────────────────────────────────────────────────────
local function pick(rng, list) return list[rng.int(1, #list)] end
local function env_override(o)
    local function num(name) return tonumber(os.getenv('QQT_SWEEP_' .. name) or '') end
    if o.teleport == nil and num('TELEPORT') then o.teleport = num('TELEPORT') == 1 end
    if o.auto == nil and num('AUTO') then o.auto = num('AUTO') == 1 end
    if o.distance == nil then o.distance = num('DISTANCE') end
    if o.rate == nil then o.rate = num('RATE') end
    if o.whisper == nil then o.whisper = num('WHISPER') end
    if o.bag_between == nil then o.bag_between = num('BAG_BETWEEN') end
    local plans = os.getenv('QQT_SWEEP_PLANS')
    if plans and plans ~= '' and o.nodes == nil then
        o.nodes = {}
        for k in plans:gmatch('[%w_]+') do o.nodes[#o.nodes + 1] = k end
    end
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
    local rng = J.rng(seed * 104729 + 11)
    for _ = 1, seed % 5 do rng.next() end
    local c = {seed = seed}
    local draw = {teleport = rng.chance(0.5), auto = rng.chance(0.75), distance = pick(rng, {2, 8, 15}),
        rate = pick(rng, {0.5, 1.0, 1.5}), whisper = pick(rng, {0.4, 0.7}), ark_exit = rng.chance(0.5) and 1 or 0,
        wc_exit = rng.chance(0.5) and 1 or 0, bag_between = pick(rng, {0, 0.25, 0.5})}
    for k, val in pairs(draw) do
        if o[k] == nil then c[k] = val else c[k] = o[k] end
    end
    c.nodes = o.nodes
    return c
end
local function describe(c)
    return string.format('seed=%d teleport=%s rosie_auto=%s pickup=%dm chaos=%.1f/min whisper=%.1f pit_exit=%s '
        .. 'uc_exit=%s bag_between=%.2f%s', c.seed, c.teleport and 'on' or 'off', c.auto and 'on' or 'off', c.distance,
        c.rate, c.whisper, c.ark_exit == 1 and 'teleport' or 'reset', c.wc_exit == 1 and 'teleport' or 'reset',
        c.bag_between, c.nodes and (' plans=' .. table.concat(c.nodes, ',')) or '')
end

local function start(seed, o)
    o = env_override(o or {})
    local c = config(seed, o)
    local chaos = {seed = seed, rate = c.rate, kinds = o.kinds, only = o.only, schedule = o.schedule}
    if o.chaos == false then chaos = nil end
    local h = J.new({rosie = true, place = o.place or 'temis', seed = seed, ordered_pairs = true,
        virtual_os_clock = true, virtual_os_time = true, fast_globals = true, shipped_defaults = true,
        invariants = o.invariants ~= false,
        rotation = {seed = seed, interrupt = o.interrupt == nil and 'dash' or o.interrupt}, chaos = chaos})
    h.assert_clean('load ' .. describe(c))
    h.instrument_exports()
    -- The QQT menu is closed while the bot runs (tree nodes do not open, so
    -- the menus draw only their headers; QQT_SWEEP_MENU=1 opens them).
    h.menu_open = os.getenv('QQT_SWEEP_MENU') == '1'
    local W = build_world(h, seed, {whisper = c.whisper, bag_between = c.bag_between, nodes = c.nodes,
        boss_mythic = o.boss_mythic, waves = o.waves})
    -- The owner's configuration: WarPigs + WarPug + SilentRaven on (the
    -- activity plugins are left to WarPigs), Rosie on with pickup and (on
    -- most seeds) its automatic town trips.
    el(h, WP).main_toggle:set(true)
    el(h, PUG).main_toggle:set(true)
    el(h, SR).main_toggle:set(true)
    el(h, WP).use_teleport_transition:set(c.teleport)
    el(h, ARK).exit_mode:set(c.ark_exit)
    el(h, WC).exit_mode:set(c.wc_exit)
    if not c.auto then h.mod('Rosie', 'rosie.private.town.gui').elements.use_keybind:set(true) end
    h.mod('Rosie', 'rosie.private.pickup.gui').elements.general.distance_slider:set(c.distance)
    ok(h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end) == true, 'Rosie enabled')
    h.c = c
    -- Portal entries are loading transitions (W.portal_entry): the rotation
    -- cannot break them and no waypoint cast replaces them.
    local rot_tick = h._rot.tick
    h._rot.tick = function(...)
        if W.portal_entry(h.travel) then return end
        return rot_tick(...)
    end
    -- Every teleport cast (waypoint, War Plan, boss dungeon) with the caster
    -- and the War Plan step (tail calls keep the host's caller attribution
    -- for the TELEPORT monitor).
    local tp_log = {}
    h.tp_log = tp_log
    local function note_tp(kind, arg)
        local s = W.step
        local rec = {t = h.now, kind = kind, arg = arg, ctx = h.context_name() or '-', from = h.place.key,
            step = s and (s.key .. (s.done_at and '(done)' or '')) or '-'}
        tp_log[#tp_log + 1] = rec
        -- o.cast_drop = {ctx = plugin, mythic = bool}: a drop falls 0.4 s into
        -- that plugin's next cast out of a non-town place (a finding repro).
        local cd = o.cast_drop
        if cd and not cd.done and rec.ctx == cd.ctx and not h.place.town and h.chaos_inject then
            cd.done = true
            h.at(0.4, function()
                if h.travel and h.travel.phase == 'channel' then
                    h.chaos_inject('drop', {during_channel = true, min = 1.5, max = 3, mythic = cd.mythic})
                end
            end)
        end
        -- Scenario invariant MISROUTE: a plugin other than Rosie casts out of
        -- the current step's activity world while the step is still open.
        if h.invariants and s and not s.done_at and not h.travel and rec.ctx ~= 'Rosie' and W.in_step_world(s.key) then
            h.invariants.hit('MISROUTE', string.format('%s cast %s(%s) out of %s while plan %d step %s (%s) is open '
                .. '(since t=%.1f); %s', rec.ctx, kind, arg and string.format('0x%X', arg) or '', h.place.key,
                W.plan and W.plan.n or 0, s.key, s.quest, s.t, h.invariants.status_lines()))
        end
    end
    local orig_tp = h.G.teleport_to_waypoint
    rawset(h.G, 'teleport_to_waypoint', function(sno)
        if W.portal_entry(h.travel) then
            h.log[#h.log + 1] = string.format('%.1f [warplan] teleport_to_waypoint(0x%X) ignored: entering a portal', h.now, sno)
            return false
        end
        note_tp('waypoint', sno)
        return orig_tp(sno)
    end)
    local orig_boss = h.G.teleport_to_boss_dungeon
    rawset(h.G, 'teleport_to_boss_dungeon', function(id)
        note_tp('boss_dungeon', id)
        return orig_boss(id)
    end)
    local orig_act = h.G.warplan.teleport_to_activity
    h.G.warplan.teleport_to_activity = function()
        note_tp('warplan', nil)
        return orig_act()
    end
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
local RULES = {}
local function rule(id, class, kind, fn, why)
    RULES[#RULES + 1] = {id = id, class = class, kind = kind, fn = fn, why = why}
end
local function has(hit, text) return hit.detail:find(text, 1, true) ~= nil end
local function mean_dwell(hit) return tonumber(hit.detail:match('mean dwell ([%d%.]+) s')) or 0 end
-- hit = {kind, detail}; a LEFT_DROP detail ends with the cast behind the
-- departure: ' {cast by <plugin> <kind> step=<step> at t=<t>}'.
local function classify(hit)
    for _, r in ipairs(RULES) do
        if r.kind == hit.kind and r.fn(hit) then return r end
    end
    return nil
end
local function cast_by(hit, who, kind)
    local by, k = hit.detail:match('{cast by ([%w_%-]+) ([%w_]+) step=')
    return by == who and (kind == nil or k == kind)
end
-- Plugins whose casts appear in a TELEPORT detail ('<kind>-><dest> by <owner> (ctx').
local function tp_owners(hit)
    local out, list = {}, {}
    for kind, owner in hit.detail:gmatch('([%w_]+)%->[%w_ ]+ by ([%w_%-]+) %(ctx') do
        if not out[owner .. ':' .. kind] then out[owner .. ':' .. kind] = true; list[#list + 1] = owner .. ':' .. kind end
    end
    return out, list
end
local function only_owners(hit, allowed)
    local seen, list = tp_owners(hit)
    if #list == 0 then return false end
    for key in pairs(seen) do if not allowed[key] then return false end end
    return true
end

-- KNOWN (harness commit, LOW): HelltideRevamped debug lines without a switch.
rule('HR-debug-log-spam', 'sweep', 'SPAM', function(hit)
    return has(hit, 'by HelltideRevamped') and (has(hit, ': [PATROL]') or has(hit, ': [NAV]')
        or has(hit, ': [CHEST RECALL]') or has(hit, ': [HR SPIKE]') or has(hit, ': [CHECK_EVENTS]'))
end, 'known (harness author): HelltideRevamped debug logging has no switch')
-- KNOWN (harness commit, LOW): Batmobile '[nav] STUCK' while a fight holds the player.
rule('BAT-nav-stuck-spam', 'sweep', 'SPAM', function(hit)
    return has(hit, '[nav] STUCK')
end, 'known (harness author): Batmobile [nav] STUCK log rate')
-- KNOWN (Rosie session): the outbound Town Portal re-cast every ~3 s while
-- the channel is broken (up to 12 casts with refunds).
rule('ROSIE-tp-recast', 'known', 'TELEPORT', function(hit)
    return only_owners(hit, {['Rosie:town_portal'] = true})
end, 'known: Rosie outbound Town Portal re-cast while the channel is broken')
-- KNOWN (Rosie session): a drop that falls during Rosie's own Town Portal cast.
rule('ROSIE-tp-cast-drop', 'known', 'LEFT_DROP', function(hit)
    return cast_by(hit, 'Rosie') and has(hit, '[dropped during the waypoint channel]')
end, 'known: Rosie leaving a drop that falls during the Town Portal cast')
-- SWEEP (harness author): a Rosie trip starts while wanted drops lie on the
-- ground (its own automatic trip or a farm plugin's with-teleport request).
rule('ROSIE-trip-leaves-ground-drops', 'sweep', 'LEFT_DROP', function(hit)
    return has(hit, '[already wanted at the cast: town_portal by Rosie')
end, "known (harness author): Rosie's trip leaves wanted drops already on the ground")
-- CONFIG: the monitor counts a Unique / Mythic anywhere within 15 m, but
-- Rosie only walks to drops within its pickup 'Distance' slider (2 m by
-- default, 8 m on some seeds): a Mythic 2-15 m away is left by that setting
-- (Rosie logs 'outside pickup distance'), whoever casts.
rule('ROSIE-mythic-beyond-slider', 'expected', 'LEFT_DROP', function(hit)
    return has(hit, '(beyond it: Unique/Mythic within the radius)')
end, "configuration: a Unique/Mythic beyond Rosie's pickup Distance slider is not walked to")
-- BOUNDED: WarPigs holds its outgoing teleport while the Looter works a
-- drop, at most 30 s ('Looter busy for 30s — proceeding with the teleport
-- anyway'). In the emulator the drop stays unreachable because enemies do
-- not move: a pack parked 12-15 m away is outside the rotation stand-in's
-- 12 m range (never killed) but inside Rosie's FIGHT hold, so Rosie does not
-- walk to the drop. The drop is picked up on the next visit.
rule('WP-looter-hold-bounded', 'expected', 'LEFT_DROP', function(hit)
    return cast_by(hit, 'WarPigs') and has(hit, '[already wanted at the cast: ')
end, "emulator (static enemies) + WarPigs' bounded 30 s Looter hold before its teleport")
-- EMULATOR: a farm plugin casts while a wanted drop has lain unreached for
-- 10 s or more: Rosie held its pickup the whole time (static enemies 12-15 m
-- away keep its FIGHT hold; the rotation stand-in never kills them), so the
-- cast is not what left it. Drops younger than that stay unclassified.
rule('X-cast-over-held-drop', 'expected', 'LEFT_DROP', function(hit)
    local age = tonumber(hit.detail:match('on the ground ([%d%.]+) s'))
    return has(hit, '[already wanted at the cast: ') and not cast_by(hit, 'Rosie') and age ~= nil and age >= 10
end, 'emulator: a drop Rosie held off for >= 10 s (static enemies in its FIGHT radius) before a farm plugin cast')
-- FINDING F2 (Rosie, cross-plugin): a wanted drop that falls during ANOTHER
-- plugin's travel channel is left: WarPigs' via-Temis waypoint, Reaper's /
-- Arkham's / WonderCity's exit cast, HelltideRevamped's zone search hop,
-- HordeDev's Leave Dungeon. Rosie 1.0.24 (after 3.3.6) watches drops only on
-- its OWN trip's outbound leg (trip_drops); nobody watches the others.
rule('X-foreign-channel-drop', 'finding', 'LEFT_DROP', function(hit)
    if not hit.detail:find('%[dropped during the [%w_]+ channel%]') then return false end
    if cast_by(hit, 'Rosie') then return false end
    return true
end, 'F2: a drop that falls during another plugin\'s teleport / leave channel is left (Rosie guards only its own trip)')
-- FINDING F1 (WarPigs + Rosie + HordeDev): the Horde War Plan entry fires
-- warplan.teleport_to_activity() from Temis over a hard Alfred need that is
-- not live yet (bag full, Rosie's automatic service off), then the Temis
-- kick (alfred_kick_if_needed) sends a town-only trigger_tasks while that
-- channel runs. In the Horde Rosie holds the town-only request ("Servicing
-- WarPigs | Idle") until its 240 s service timeout; HordeDev waits on it
-- (alfred_running, "[alfred] HordeDev held for Ns: Alfred busy") and the
-- player stands still, then farms on with a full bag (Rosie latched stuck).
rule('WP-kick-into-horde-channel', 'finding', 'STALL', function(hit)
    return has(hit, ' in bsk ') and has(hit, 'HordeDev task=alfred_running') and has(hit, 'Servicing WarPigs')
end, 'F1: a town-only Rosie request sent during the Horde War Plan teleport strands the player in the Horde ~240 s')
-- FINDING F3 (Rosie, lifecycle): a town service that STARTED in town (no
-- Town Portal leg) is stranded when another plugin's waypoint channel takes
-- the player out of town (HelltideRevamped's zone search hop, WarPigs' War
-- Plan teleport): lifecycle.lua keeps the trip 'Servicing <caller> | Idle'
-- out of town, every town task idles, the farm plugin waits on Alfred
-- ('holding for Ns: Alfred busy') until the 240 s service timeout, then the
-- latched failure blocks the next trip for 120 s while the full bag skips
-- every drop ('equipment bag full'). F1 is the WarPigs-triggered case.
rule('ROSIE-town-service-stranded', 'finding', 'STALL', function(hit)
    return not has(hit, ' in temis ') and not has(hit, ' in kurast ')
        and (has(hit, 'Servicing automatic | Idle') or has(hit, 'Servicing WarPigs | Idle')
            or has(hit, 'Town service or return timed out (240s)'))
end, 'F3: a Rosie town service started in town idles out of town for 240 s after a foreign teleport')
rule('ROSIE-town-service-stranded-plan', 'finding', 'PLAN_SLOW', function(hit)
    return has(hit, 'Servicing automatic | Idle') or has(hit, 'Servicing WarPigs | Idle')
        or has(hit, 'Town service or return timed out (240s)')
end, 'F3 (same episode): the War Plan step overruns while Rosie idles out of town')
-- FINDING F4 (HordeDev, tasks/horde.lua bomber:move_in_pattern): the wave
-- pattern and the victory lap share move_index / reached_target /
-- target_reach_time. A reached point stores target_reach_time =
-- get_time_since_inject() (line 414) and the '== 3' dwell counter (line 412)
-- is reset to 0 only when the player is > 2 m from the next point (line 410).
-- When the lap starts with reached_target left true by the wave pattern,
-- its index jumps to 2 (the arena centre) while the player already stands
-- there: target_reach_time counts up from a timestamp, never equals 3, and
-- HordeDev stands at the centre (9.2, 8.9) forever after the last wave (no
-- door, no Council, no bound: 1298 s on seed 4 until the run ended).
local function at_arena_centre(hit)
    local x, y = hit.detail:match('at %((%-?[%d%.]+), (%-?[%d%.]+)%)')
    x, y = tonumber(x), tonumber(y)
    return x ~= nil and math.abs(x - 9.2) <= 1 and math.abs(y - 8.9) <= 1
end
rule('HD-victory-lap-freeze', 'finding', 'STALL', function(hit)
    return has(hit, ' in bsk ') and at_arena_centre(hit) and has(hit, 'Current Task: Infernal Horde')
end, 'F4: HordeDev freezes at the arena centre after the last wave (victory lap dwell counter holds a timestamp)')
rule('HD-victory-lap-freeze-plan', 'finding', 'PLAN_SLOW', function(hit)
    return has(hit, 'step horde') and at_arena_centre(hit) and has(hit, 'Current Task: Infernal Horde')
end, 'F4 (same episode): the Horde War Plan step never completes')
-- FINDING F5 (WonderCity, core/tracker.lua observe_world): the reward chest
-- is open and exit_undercity has set tracker.exit_trigger_time (the exit
-- delay runs) when Rosie's automatic trip (bag full) takes the player to
-- town. observe_world() records a resumable Alfred trip only while
-- exit_trigger_time == nil (tracker.lua:177), so this departure counts as
-- the run's exit; Rosie's return portal brings the player back into the
-- same finished Undercity, which is then a NEW run (kind 'run':
-- reset_floor_state, done = false, reward_seen = false). WonderCity explores
-- the emptied floor until reset_timeout (600 s) while WarPigs holds the
-- turn-in ('pending disable: WonderCityPlugin (not back in town yet)').
rule('WC-finished-run-restarted', 'finding', 'PLAN_SLOW', function(hit)
    return has(hit, 'WonderCity task=explore_undercity') and has(hit, 'pending disable: WonderCityPlugin')
end, 'F5: a Rosie trip during the exit delay makes WonderCity restart the finished Undercity (~600 s)')
-- Same mechanism on an Undercity -> Undercity plan (seed 13, t=4006-4700):
-- the next Undercity step waits while WonderCity re-explores the finished
-- instance until reset_timeout. Heuristic (text only): an Undercity step
-- over its bound while WonderCity explores.
rule('WC-finished-run-restarted-uc', 'finding', 'PLAN_SLOW', function(hit)
    return has(hit, 'step uc (') and has(hit, 'WonderCity task=explore_undercity')
end, 'F5 (Undercity -> Undercity plan): the next Undercity step waits ~600 s')
-- DESIGN: an Undercity -> Undercity War Plan: the finished instance is left
-- (exit_undercity) and a new one opened at the Kurast brazier.
rule('WC-uc-uc-next-run', 'expected', 'MISROUTE', function(hit)
    return has(hit, 'WonderCity cast waypoint') and has(hit, 'step uc') and has(hit, 'WonderCity task=exit_undercity')
end, 'design: the finished Undercity is left for the next Undercity step')
-- FINDING F6 (WarPug, core/planner.lua tick/context): a planning session
-- (APPROACH_TABLE .. CONFIRMING) that sees no world key for one tick -- a
-- loading screen, an unreadable world, a dead player -- and no companion is
-- halted for good: halt('Stopped: outside Temis or world unavailable'),
-- 'disable and re-enable WarPug to retry' (planner.lua:481-483). HALTED is
-- terminal (planner.lua:486), so the War Plan day ends: WarPigs keeps
-- 'watching quests' in Temis for the rest of the session. Nothing was
-- selected yet in APPROACH_TABLE, so a pause (as for companion work) or a
-- plain reset would be safe there.
rule('PUG-transient-halt', 'finding', 'IDLE_TEMIS', function(hit)
    return has(hit, 'WarPug HALTED') and has(hit, 'Stopped: outside Temis or world unavailable')
end, 'F6: WarPug halts for the session on a one-tick world/player blip during planning')
-- DESIGN: a Pit -> Pit War Plan: the finished pit is left (exit_pit) for the
-- next one (W.in_step_world now ignores an instance opened before the step;
-- this rule keeps hits files from before that change classified).
rule('ARK-pit-pit-next-run', 'expected', 'MISROUTE', function(hit)
    return has(hit, 'ArkhamAsylum cast waypoint') and has(hit, 'step pit') and has(hit, 'ArkhamAsylum task=exit_pit')
end, 'design: the finished pit is left for the next Pit step')
-- EMULATOR: Reaper's Kill Monsters leaves movement to the orbwalker ('stay
-- put — orbwalker handles casting'); the rotation stand-in never walks to a
-- target, so a boss spawned > 12 m from where the altar click left the
-- player is never engaged. The real Universal Rotation (clear mode) is
-- assumed to walk to it (not verified live).
rule('RP-kill-out-of-stub-range', 'expected', 'STALL', function(hit)
    return has(hit, ' in lair ') and has(hit, 'Reaper task=Kill Monsters')
end, 'emulator: the rotation stand-in does not walk to a boss beyond 12 m (Reaper leaves that to the orbwalker)')
rule('RP-kill-out-of-stub-range-plan', 'expected', 'PLAN_SLOW', function(hit)
    return has(hit, 'step boss') and has(hit, 'Reaper task=Kill Monsters')
end, 'emulator (same episode)')
-- DESIGN (LOW): a boss -> boss War Plan: Reaper's run_once ends with
-- 'Rotation finished — returning to Skov_Temis' although the next quest is
-- the same boss; WarPigs re-enables it in Temis (a ~15 s round trip).
rule('RP-boss-boss-roundtrip', 'expected', 'MISROUTE', function(hit)
    return has(hit, 'Reaper cast waypoint') and has(hit, 'step boss')
end, "design (LOW): Reaper's run_once returns to Temis between two Andariel steps")
-- LOW (F1 and F4 episodes): HordeDev's explorer keeps its stuck check
-- running while the player stands still (waiting for Alfred, or frozen at
-- the arena centre) and prints 'Movement spell on cooldown.' once per
-- configured movement spell (11 lines) every 16 s.
rule('HD-movement-spell-spam', 'finding', 'SPAM', function(hit)
    return has(hit, 'by HordeDev') and has(hit, 'Movement spell on cooldown.')
end, "LOW: HordeDev's explorer stuck check prints 'Movement spell on cooldown.' per spell while HordeDev waits")
-- LOW (HordeDev, tasks/open_chests.lua): a HordeDev reload in the chest room
-- after the aether is spent re-initialises the chest phase (GA / Materials
-- not marked opened) and retries the Materials chest with 0 aether every
-- ~2.7 s until max_attempts (15, ~40 s): open_chest does not check
-- aether_count() before interact_object. Bounded.
rule('HD-chest-retry-zero-aether', 'finding', 'LOOP', function(hit)
    return has(hit, 'HordeDev.state switches') and has(hit, 'OPENING_CHEST') and has(hit, 'WAITING_FOR_VFX')
end, 'LOW: after a reload HordeDev retries a chest with 0 aether up to 15 times (~40 s, bounded)')
-- DESIGN: HelltideRevamped fight / explore alternation (seconds per state).
rule('LOOP-hr-fight-explore', 'expected', 'LOOP', function(hit)
    return has(hit, 'EXPLORE_HELLTIDE') and (has(hit, 'KILL_MONSTERS') or has(hit, 'MOVING_TO_HELLTIDE_CHEST'))
        and mean_dwell(hit) >= 3
end, 'HelltideRevamped fight / explore alternation (mean dwell >= 3 s), not a thrash')

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
local SEEDS = ENV_SEEDS and ENV_SEEDS ~= '' and parse_seeds(ENV_SEEDS) or {404}
local SECONDS = tonumber(os.getenv('QQT_SWEEP_SECONDS') or '') or 1200
local VERBOSE = os.getenv('QQT_SWEEP_VERBOSE') == '1'
local TAIL = tonumber(os.getenv('QQT_SWEEP_TAIL') or '')
local ONLY = os.getenv('QQT_SWEEP_ONLY')
-- QQT_SWEEP_HITS=<file>: every hit appended as a tab-separated line (seed,
-- configuration, t, kind, detail); QQT_SWEEP_RECLASSIFY=<file> classifies
-- such a file with the current RULES instead of running seeds.
local HITS_FILE = os.getenv('QQT_SWEEP_HITS')
if HITS_FILE == '' then HITS_FILE = nil end
local RECLASSIFY = os.getenv('QQT_SWEEP_RECLASSIFY')
if RECLASSIFY == '' then RECLASSIFY = nil end

local S = {seeds = 0, emulated = 0, hits = {}, by_rule = {}, unclassified = {}, crashes = {}, plans = 0, steps = 0}
local function steps_line(W)
    local counts = {}
    for _, e in ipairs(W.events) do
        if e.kind == 'complete' then
            local k = tostring(e.detail):match('^(%w+)')
            counts[k] = (counts[k] or 0) + 1
        end
    end
    local out = {}
    for _, k in ipairs({'pit', 'uc', 'ht', 'horde', 'boss', 'turnin'}) do out[#out + 1] = k .. '=' .. (counts[k] or 0) end
    return table.concat(out, ' ')
end
local function sweep_seed(seed, o, seconds)
    seconds = seconds or SECONDS
    local t0 = os.clock()
    local h, W = start(seed, o)
    local progress, next_report = os.getenv('QQT_SWEEP_PROGRESS') == '1', h.now + 600
    local probes = {}
    for t in (os.getenv('QQT_SWEEP_PROBE') or ''):gmatch('[%d%.]+') do probes[#probes + 1] = tonumber(t) end
    -- HordeDev's pattern-walk state (F4 evidence): the upvalues of
    -- bomber:move_in_pattern in HordeDev/tasks/horde.lua.
    local function horde_pattern_state()
        local okm, task = pcall(h.mod, HD, 'tasks.horde')
        if not okm or type(task) ~= 'table' or type(task.Execute) ~= 'function' then return '' end
        local bomber
        for i = 1, 80 do
            local name, val = debug.getupvalue(task.Execute, i)
            if not name then break end
            if name == 'bomber' then bomber = val end
        end
        if type(bomber) ~= 'table' or type(bomber.move_in_pattern) ~= 'function' then return '' end
        local out = {}
        for i = 1, 80 do
            local name, val = debug.getupvalue(bomber.move_in_pattern, i)
            if not name then break end
            if name == 'move_index' or name == 'reached_target' or name == 'target_reach_time' then
                out[#out + 1] = name .. '=' .. tostring(val)
            end
        end
        return #out > 0 and (' HordeDev pattern{' .. table.concat(out, ' ') .. '}') or ''
    end
    local function probe()
        local s = W.step
        if h.place == h.P.bsk then print('  probe t=' .. string.format('%.1f', h.now) .. horde_pattern_state()) end
        -- Enemies and ground items within 20 m (distance, health / rarity).
        local near = {}
        for _, a in ipairs(h.place.actors or {}) do
            if a.enemy and (a.health or 0) > 0 and a.pos then
                local d = h.pos:dist_to_ignore_z(a.pos)
                if d <= 20 then near[#near + 1] = string.format('%s@%.1fm hp=%d', a.name or '?', d, a.health) end
            end
        end
        for _, it in ipairs(h.place.items or {}) do
            if not it.picked and it.pos then
                local d = h.pos:dist_to_ignore_z(it.pos)
                if d <= 20 then near[#near + 1] = string.format('item %s r%s@%.1fm', tostring(it.name), tostring(it.rarity), d) end
            end
        end
        if #near > 0 then print('  probe near: ' .. table.concat(near, ', ')) end
        if h.place.undercity then
            local okt, tr = pcall(h.mod, WC, 'core.tracker')
            local oku, ut = pcall(h.mod, WC, 'core.utils')
            if okt and type(tr) == 'table' then
                local looting = oku and type(ut) == 'table' and type(ut.is_looting) == 'function'
                    and h.as(h.by_dir[WC], function() return ut.is_looting() end)
                print(string.format('  probe WonderCity tracker: done=%s reward_seen=%s exit_trigger=%s loot_quiet=%s '
                    .. 'world_key=%s resume_key=%s is_looting=%s', tostring(tr.done), tostring(tr.reward_seen),
                    tostring(tr.exit_trigger_time), tostring(tr.loot_quiet_since), tostring(tr.world_key),
                    tostring(tr.resume_key), tostring(looting)))
            end
        end
        print(string.format('  probe t=%.1f place=%s pos=(%.1f,%.1f) step=%s travel=%s dead=%s bag=%d; %s', h.now,
            h.place.key, h.pos:x(), h.pos:y(), s and (s.key .. (s.done_at and ' done' or '')) or '-',
            tostring(h.travel and h.travel.why), tostring(h.dead), #(h.inventory or {}),
            h.invariants and h.invariants.status_lines() or ''))
    end
    local each = function()
        W.tick()
        while probes[1] and h.now >= probes[1] do table.remove(probes, 1); probe() end
        if progress and h.now >= next_report then
            next_report = next_report + 600
            print(string.format('  progress seed %d: t=%.0f cpu=%.1f s, log %d lines, plans %d, steps %d (%s)', seed,
                h.now, os.clock() - t0, #h.log, W.plans_done, W.steps_done, steps_line(W)))
            io.stdout:flush()
        end
    end
    local ok_run, err = xpcall(function() h.run(seconds, each) end, debug.traceback)
    S.seeds, S.emulated = S.seeds + 1, S.emulated + seconds
    S.plans, S.steps = S.plans + W.plans_done, S.steps + W.steps_done
    local label = describe(h.c) .. (o and o.label and (' ' .. o.label) or '')
    print(string.format('S4 %s: %.0f s emulated in %.1f s; plans confirmed %d, done %d; steps %d (%s); whispers ready '
        .. '%d, claimed %d; deaths %d, pit runs %d, undercity runs %d, hordes %d, kills %d, Rosie trips %d, pickups %d, '
        .. 'rotation casts %d dashes %d interrupts %d, chaos %d',
        label, seconds, os.clock() - t0, #W.plans, W.plans_done, W.steps_done, steps_line(W), W.whispers_ready,
        h.reward_accepts or 0, W.deaths, W.pit_runs, W.uc_runs, W.arena.runs, W.kills,
        h.count(h.tp_log, function(r) return r.ctx == 'Rosie' end), h.pickups or 0,
        h.rotation.casts, h.rotation.dashes, h.rotation.interrupts, h.chaos and #h.chaos.log or 0))
    if not ok_run then S.crashes[#S.crashes + 1] = label .. ': host crash: ' .. tostring(err) end
    for _, e in ipairs(h.errors) do
        S.crashes[#S.crashes + 1] = string.format('%s: Lua error in %s %s at t=%.1f: %s', label, e.plugin, e.kind, e.t, e.err)
    end
    for _, vi in ipairs(h.violations) do
        S.crashes[#S.crashes + 1] = string.format('%s: [%s] %s (ctx %s, owner %s) at t=%.1f', label, vi.kind, vi.detail,
            vi.context, vi.owner, vi.t)
    end
    for _, hit in ipairs(h.invariants and h.invariants.hits or {}) do
        local rec = {seed = seed, t = hit.t, kind = hit.kind, detail = hit.detail, label = label}
        local cast = hit.kind == 'LEFT_DROP' and cast_before(h, hit.t) or nil
        if cast then
            rec.detail = rec.detail .. string.format(' {cast by %s %s step=%s at t=%.1f}', cast.ctx, cast.kind, cast.step,
                cast.t)
        end
        local r = hit.kind ~= 'INTERNAL' and classify(rec) or nil
        rec.rule = r
        S.hits[#S.hits + 1] = rec
        if HITS_FILE then
            local f = io.open(HITS_FILE, 'a')
            if f then
                f:write(table.concat({tostring(seed), label, string.format('%.1f', hit.t), hit.kind,
                    (rec.detail:gsub('[\t\r\n]+', ' '))}, '\t'), '\n')
                f:close()
            end
        end
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
        for _, text in ipairs(h.log) do
            local t = tonumber(text:match('^(%-?[%d%.]+)'))
            if t and t >= w0 and t <= w1 and not text:find('[LONG PATH]', 1, true) then print(text:sub(1, 400)) end
        end
    end
    return h, W
end

if os.getenv('QQT_SWEEP_LIST') == '1' then
    for _, seed in ipairs(SEEDS) do print(describe(config(seed, env_override({})))) end
    return
end

if RECLASSIFY then
    local seen_seeds = {}
    for line in io.lines(RECLASSIFY) do
        local seed, label, t, kind, detail = line:match('^(%d+)\t([^\t]*)\t([%d%.]+)\t([%w_]+)\t(.*)$')
        if seed then
            local rec = {seed = tonumber(seed), t = tonumber(t), kind = kind, detail = detail, label = label}
            if not seen_seeds[rec.seed] then seen_seeds[rec.seed] = true; S.seeds = S.seeds + 1 end
            local r = kind ~= 'INTERNAL' and classify(rec) or nil
            rec.rule = r
            S.hits[#S.hits + 1] = rec
            if r then
                local b = S.by_rule[r.id]
                if not b then b = {n = 0, seeds = {}, first = rec, rule = r}; S.by_rule[r.id] = b end
                b.n = b.n + 1
                b.seeds[rec.seed] = true
            else
                S.unclassified[#S.unclassified + 1] = rec
            end
        end
    end
elseif ENV_SEEDS and ENV_SEEDS ~= '' then
    for _, seed in ipairs(SEEDS) do
        local passed, err = xpcall(function() sweep_seed(seed) end, debug.traceback)
        if not passed then S.crashes[#S.crashes + 1] = 'seed ' .. seed .. ': ' .. tostring(err) end
    end
elseif os.getenv('QQT_SWEEP_FINDINGS') ~= '1' then
    local passed, err = xpcall(function()
        local _, W = sweep_seed(404, {label = '(D1 seeded)'}, SECONDS)
        ok(W.plans_done >= 1, 'D1: at least one War Plan completed, got ' .. W.plans_done)
    end, debug.traceback)
    if not passed then S.crashes[#S.crashes + 1] = 'D1: ' .. tostring(err) end
end

-- Minimal repros of this sweep's findings (QQT_SWEEP_FINDINGS=1). Each
-- prints REPRODUCED / not reproduced; QQT_SWEEP_STRICT=1 fails on a
-- reproduced finding, so the fixing session gets a test that fails on the
-- old code and passes on the fix.
local FINDINGS = {
    {id = 'F1', rule = 'WP-kick-into-horde-channel', seed = 11, seconds = 420, title = 'Horde War Plan entry with '
        .. "'Use teleport' off and a full bag in Temis (Rosie's automatic service off): WarPigs' town-only Rosie request "
        .. 'lands 0.6 s into its own War Plan teleport; the player stands in the Horde ~240 s',
        o = {nodes = {'horde'}, teleport = false, auto = false, bag_between = 1, schedule = {}}},
    {id = 'F2', rule = 'X-foreign-channel-drop', seed = 3, seconds = 300, title = "a Mythic that falls 0.4 s into "
        .. "Reaper's exit cast after Andariel stays in the lair (Rosie guards only its own Town Portal cast)",
        o = {nodes = {'boss'}, bag_between = 0, schedule = {}, cast_drop = {ctx = RP, mythic = true}}},
    {id = 'F3', rule = 'ROSIE-town-service-stranded', seed = 3, seconds = 420, title = 'the bag fills in Temis 0.2 s '
        .. "into HelltideRevamped's zone-search waypoint cast: Rosie's automatic service starts in town, the channel "
        .. 'lands in Fractured Peaks, Rosie idles out of town 240 s (HR holds on Alfred), then latches the failure',
        o = {nodes = {'ht'}, bag_between = 0, schedule = {{t = 1012, kind = 'bag_full'}}}},
    {id = 'F4', rule = 'HD-victory-lap-freeze', seed = 4, seconds = 5300, title = 'HordeDev freezes at the arena '
        .. 'centre after the last wave (plan 13, t=6097.9; move_in_pattern dwell counter holds a timestamp)',
        o = {}},
    {id = 'F5', rule = 'WC-finished-run-restarted', seed = 8, seconds = 520, title = "the bag fills 10 s after "
        .. "the attunement chest (WonderCity's exit delay): Rosie's automatic trip returns into the finished "
        .. 'Undercity and WonderCity explores it as a new run; the turn-in waits ~600 s',
        o = {nodes = {'uc'}, bag_between = 0, schedule = {{t = 1159, kind = 'bag_full'}}}},
    {id = 'F6', rule = 'PUG-transient-halt', seed = 16, seconds = 420, title = 'a 2-8 s loading screen in Temis '
        .. '1.5 s after WarPug starts walking to the War Plan table halts WarPug for the session (no plan for the '
        .. 'rest of the run)', o = {nodes = {'pit'}, bag_between = 0, schedule = {{t = 1007, kind = 'limbo'}}}},
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

print(string.format('S4 sweep: %d seed(s), %.1f emulated hours, %d War Plans completed, %d steps, %d invariant hit(s), '
    .. '%d unclassified, %d crash(es)', S.seeds, S.emulated / 3600, S.plans, S.steps, #S.hits, #S.unclassified, #S.crashes))
local ids = {}
for id in pairs(S.by_rule) do ids[#ids + 1] = id end
table.sort(ids)
for _, id in ipairs(ids) do
    local b = S.by_rule[id]
    local seeds = {}
    for s in pairs(b.seeds) do seeds[#seeds + 1] = s end
    table.sort(seeds)
    print(string.format('  %-32s %-8s %3d hit(s), seeds %s; first: seed %d t=%.1f %s', id, b.rule.class, b.n,
        table.concat(seeds, ','), b.first.seed, b.first.t, b.first.detail:sub(1, 400)))
end
for i, rec in ipairs(S.unclassified) do
    if i > 60 then print('  ... ' .. (#S.unclassified - 60) .. ' more'); break end
    print(string.format('  UNCLASSIFIED seed %d t=%.1f [%s] %s', rec.seed, rec.t, rec.kind, rec.detail:sub(1, 700)))
end
for _, c in ipairs(S.crashes) do print('  CRASH ' .. c:sub(1, 2000)) end
if #S.crashes > 0 or #S.unclassified > 0 then
    failures[#failures + 1] = string.format('%d crash(es), %d unclassified invariant hit(s)', #S.crashes, #S.unclassified)
end
if #failures > 0 then error('S4 sweep: ' .. table.concat(failures, '; ')) end
print(string.format('PASS: S4 War Plan sweep, %d checks', checks))
