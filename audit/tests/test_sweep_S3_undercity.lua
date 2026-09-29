-- QQT_Warpigz_v3 scenario sweep S3: the owner's Undercity setup, standalone
-- WonderCity + Batmobile + Rosie (automatic town trips and pickup) + the
-- Universal Rotation stand-in, long seeded runs with chaos and the invariant
-- monitors on (audit/tests/joint_host.lua: TELEPORT / LEFT_DROP / STALL /
-- SPAM / LOOP).
--
-- The Kurast entry and the Undercity are scripted here (the joint host has
-- one flat 'undercity' place and an inert Kurast):
--   * Kurast is laid out along WonderCity's recorded walk (data/path.lua):
--     the waypoint arrival at its first point, a market stall across the
--     straight line to the Spirit Brazier (Aubrie_Test_Undercity_Crafter)
--     near its end, and actors stream in only within 40 m (the brazier is not
--     in the actor list at the waypoint, so walk_kurast walks the recorded
--     path and enter_undercity takes over when the brazier appears);
--   * the brazier opens the tribute screen within 3 m; a right-click on a
--     tribute's inventory slot consumes it; the ACCEPT click (WonderCity logs
--     'left-click ACCEPT') closes the screen and opens a NEW Undercity (new
--     world ids) behind Portal_Dungeon_Undercity next to the brazier;
--   * 2-4 floors per run (distinct world ids and zones): walled boxes with
--     trash, sometimes a treasure goblin, 0-2 Spirit Hearths (enticements:
--     lit on interaction, a few monsters come), the floor exit at the far
--     end (X1_Undercity_WarpPad + X1_Undercity_PortalSwitch next to it); on
--     beacon floors the switch opens only after the Grand Spirit Beacon
--     (X1_Undercity_Enticements_SpiritBeaconSwitch) is lit and its wave is
--     killed (or 12 s later);
--   * the last floor holds the district boss (X1_Undercity_Lacuni_Boss) past
--     a Healing_Well_Basic; its death drops loot and the reward chest
--     (X1_Undercity_Chest_Attunement), which opens on interaction (loot
--     burst, obols) and stays, non-interactable;
--   * obols are ground items the game collects when walked over
--     (loot_manager.is_obols; Rosie never targets them);
--   * reset_all_dungeons inside an Undercity ejects to the brazier; exit mode
--     Teleport is the Kurast waypoint (back along the whole walk);
--   * entering a portal (the Undercity portal, a floor switch, the reset
--     ejection) is a loading transition: one frame, the rotation cannot break
--     it and no waypoint cast replaces it;
--   * the host's target_selector.get_near_target_list ignores its range
--     argument (every enemy of the place); here it honours it, otherwise
--     WonderCity's kill_monster (which checks no distance for bosses) chases
--     the district boss from the floor entry.
-- Scenario invariants added to the host's monitors (h.invariants.hit):
--   UC_SLOW     an Undercity run still open 480 s after its first floor;
--   UC_ABANDON  a new Undercity opened while the last one's reward chest was
--               never opened;
--   REWARD_LEFT the run is left for good (reset / exit teleport) while boss or
--               reward-chest loot Rosie wants still lies on the boss floor;
--   BOSS_TRIP   a teleport cast within 30 m of the live district boss;
--   KURAST_SLOW more than 150 s from an arrival in Kurast to the Undercity
--               portal (the walk, brazier, tribute and portal);
--   FLOOR_SLOW  more than 240 s on one floor;
--   REWARD_FORGOTTEN WonderCity waits for the reward chest to unlock on a
--               boss floor whose chest it already opened (its reward state
--               was reset, e.g. by a trip it did not record as resumable).
-- A move command during a waypoint / Town Portal channel breaks it (the
-- game's rule; the joint host lets the channel finish), so Rosie's looter
-- walking to a drop cancels WonderCity's exit teleport.
-- Every hit is classified by RULES below: 'known' (being fixed by a plugin
-- session), 'finding' (reported by this sweep), 'expected' (by design /
-- emulator). An unclassified hit fails.
--
-- Default (the suite runs every file under Lua 5.4 and LuaJIT): a reload
-- check of the harness, D1 (scripted chaos) and D2 (seeded chaos) must run
-- clean (no Lua error, no caller-context violation, no monitor error, no
-- unclassified hit) and complete Undercity runs.
--
-- Heavy sweep (developer, not the suite):
--   QQT_SWEEP_SEEDS=1-20 QQT_SWEEP_SECONDS=7200 \
--     luajit -e 'SUITE_ROOT="<repo>"' audit/tests/test_sweep_S3_undercity.lua
-- QQT_SWEEP_SEEDS takes "a-b" or "a,b,c"; QQT_SWEEP_VERBOSE=1 prints every
-- hit; QQT_SWEEP_ONLY=<kind> only that kind; QQT_SWEEP_TAIL=N the last N
-- log lines; QQT_SWEEP_GREP=<text> the matching log lines;
-- QQT_SWEEP_WINDOW=t0-t1 the log (and the teleport casts) in a window;
-- QQT_SWEEP_PROBE=t1,t2 the player / task state at those times;
-- QQT_SWEEP_PROGRESS=1 a CPU-time line every 600 emulated s;
-- QQT_SWEEP_LIST=1 only lists each seed's configuration.
-- A seed's configuration (exit mode, tribute, pickup distance, chaos rate,
-- plugins) is drawn from the seed; to minimise a repro override it with
-- QQT_SWEEP_EXIT=reset|teleport, _DISTANCE=m, _RATE=per_min,
-- _PLUGINS=all|min, _TRIBUTE=skip|use|none, _FLOORS=n, and the chaos with
-- _NOCHAOS=1, _KINDS=drop,death, _CHAOS_ONLY=3,7 (injection numbers) or
-- _SCHEDULE=1330:reload:WonderCity,1400:drop:mythic (absolute times, the
-- host starts at t=1000); _INTERRUPT=dash|cast|off.
-- QQT_SWEEP_FINDINGS=1 runs the minimal repro of each finding
-- (QQT_SWEEP_FINDING=F3 just one); with QQT_SWEEP_STRICT=1 a reproduced
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

local WC = 'WonderCity'
local CONSUMER = {name = 'SweepS3', dir = ROOT .. '/audit/tests/', loaded = {}}
-- WonderCity/data/path.lua (the recorded Kurast walk to the brazier).
local PATH = {
    {1035.100586, 151.795898}, {1034.520630, 155.840164}, {1033.762939, 159.827789}, {1033.301025, 163.818405},
    {1032.986084, 167.852737}, {1033.159424, 171.876282}, {1033.665039, 175.966660}, {1034.030273, 180.076645},
    {1035.572754, 183.773087}, {1038.615601, 186.510468}, {1040.110474, 190.306274}, {1039.954834, 194.412949},
    {1039.915894, 198.490021}, {1039.622314, 202.517303}, {1040.062012, 206.520798}, {1040.016724, 210.599960},
    {1039.196533, 214.621170}, {1039.105957, 218.732727}, {1039.138184, 222.773819}, {1039.277832, 226.895966},
    {1036.578857, 229.849915}, {1032.545044, 229.522003}, {1030.829346, 225.795898}, {1034.179687, 223.530273},
}
local BRAZIER = {1027.0, 221.5}
local TRIBUTES = {2125049, 2485152, 2485144, 2090358} -- gui.tributes_data sno ids 1..4

-- Place keys carry no digits: the LOOP monitor masks numbers in state
-- names, so 'uc2' and 'uc3' would read as one place.
local function letters(n)
    local s = ''
    repeat
        s = string.char(65 + (n - 1) % 26) .. s
        n = math.floor((n - 1) / 26)
    until n <= 0
    return s
end

-- ── the scripted Kurast entry and Undercity ────────────────────────────────
local function build_world(h, seed, o)
    local rng = J.rng(seed * 7919 + 29)
    local v = h.v
    local G = h.G
    local W = {runs = {}, run = nil, opens = 0, completed = 0, floors_entered = 0, kills = 0, deaths = 0,
        resets = 0, exits = {}, tributes_used = 0, hearths = 0, beacons = 0, chests = 0, obols_picked = 0,
        goblins = 0, events = {}, death_times = {}, kurast_arrival = nil, entries = 0}
    h.world = W
    W.floor_stats = {beacon = {n = 0, sum = 0}, open = {n = 0, sum = 0}}
    local function note(kind, detail)
        W.events[#W.events + 1] = {t = h.now, kind = kind, detail = detail}
        h.log[#h.log + 1] = string.format('%.1f [uc] %s: %s', h.now, kind, tostring(detail))
    end
    W.note = note
    local function hit(kind, detail)
        if h.invariants then h.invariants.hit(kind, detail) end
    end

    -- Kurast along the recorded walk: the waypoint arrival at path[1], the
    -- brazier near the end, a market stall across the straight line.
    local K = h.P.kurast
    K.box = {990, 1085, 125, 260}
    K.spawn = v(PATH[1][1], PATH[1][2])
    K.slide = true
    K.vis = 40
    K.walls = {{1021, 1036.5, 194, 205}}
    h.brazier.pos = v(BRAZIER[1], BRAZIER[2])
    local next_id = 7000

    -- Actors stream in only within place.vis m (Kurast, Undercity floors).
    local am = G.actors_manager
    local function visible(list)
        local vis = h.place.vis
        if not vis then return list end
        local out = {}
        for _, a in ipairs(list) do
            if a.pos and a.pos:dist_to_ignore_z(h.pos) <= vis then out[#out + 1] = a end
        end
        return out
    end
    for _, name in ipairs({'get_all_actors', 'get_ally_actors', 'get_enemy_actors', 'get_enemy_npcs'}) do
        local orig = am[name]
        am[name] = function(...) return visible(orig(...)) end
    end
    -- target_selector.get_near_target_list honours its range (see header).
    local ts = G.target_selector
    local near = ts.get_near_target_list
    ts.get_near_target_list = function(pos, range)
        local list = near(pos, range)
        pos = pos or h.pos
        local r = math.min(tonumber(range) or 1e9, h.place.vis or 1e9)
        local out = {}
        for _, a in ipairs(list) do
            if a.pos and a.pos:dist_to_ignore_z(pos) <= r then out[#out + 1] = a end
        end
        return out
    end
    -- Obols: ground items the game collects when walked over.
    G.loot_manager.is_obols = function(item) return type(item) == 'table' and item.obols == true end
    G.loot_manager.any_item_around = function(pos, radius)
        pos = pos or h.pos
        for _, item in ipairs(h.place.items or {}) do
            if not item.picked and item.pos and item.pos:dist_to_ignore_z(pos) <= (radius or 30) then return true end
        end
        return false
    end
    h.obols = 0
    local function drop_obols(place, x, y, n)
        for _ = 1, n do
            local it = h.drop(place, x + rng.range(-2, 2), y + rng.range(-2, 2),
                {name = 'X1_Undercity_Obols', rarity = 0, obols = true, amount = rng.int(5, 25)})
            it.obols = true
        end
    end
    local function loot(place, x, y, n, mythic_share, tag)
        for _ = 1, n do
            local ang, d = rng.range(0, 2 * math.pi), rng.range(0.8, 4)
            local roll = rng.next()
            local fields
            if roll < (mythic_share or 0) then
                fields = {name = 'Helm_Unique_Generic_005', sno = 2647147, rarity = 6, ancestral = true, ga = 1,
                    affixes = {{affix_name_hash = 2662414, get_name = function() return 'Helm_Unique_Generic_005' end},
                        {affix_name_hash = 2628989, get_name = function() return 'S14_Mythic_UniquePotency' end}}}
            elseif roll < 0.5 then
                fields = {name = 'Helm_Legendary_Chaos', rarity = 5, ancestral = true, ga = rng.int(0, 3)}
            else
                fields = {name = 'Helm_Rare_Joint', rarity = 3, ga = 0}
            end
            local px, py = x + math.cos(ang) * d, y + math.sin(ang) * d
            if not h.walkable(v(px, py)) then px, py = x, y end
            local item = h.drop(place, px, py, fields)
            item.reward_of = tag
        end
    end
    -- Rosie's pickup decision for an item (the one the LEFT_DROP monitor uses),
    -- its console output muted and host counters kept.
    local function rosie_wants(item)
        local rec = h.by_dir.Rosie
        local im = rec and rec.loaded['rosie.private.pickup.src.item_manager']
        if type(im) ~= 'table' or type(im.check_want_item) ~= 'function' then return false end
        local reads, rays = h.item_count_reads, h.ray_casts
        h._mute_log = true
        local okw, wanted, why = pcall(h.as, 'Rosie', function() return im.check_want_item(item, true) end)
        h._mute_log = nil
        h.item_count_reads, h.ray_casts = reads, rays
        return okw and wanted == true, why
    end
    W.rosie_wants = rosie_wants

    -- Tributes (dungeon keys) and the inventory slot the right-click hits.
    h.keys_items = {}
    local function tribute(sno)
        local it = {sno = sno, tribute = true}
        function it:get_sno_id() return self.sno end
        function it:get_name() return 'Tribute_' .. tostring(self.sno) end
        function it:get_skin_name() return self:get_name() end
        function it:is_valid() return true end
        return it
    end
    for i = 1, o.tributes or 0 do h.keys_items[#h.keys_items + 1] = tribute(TRIBUTES[(i - 1) % #TRIBUTES + 1]) end
    local player = G.get_local_player()
    player.get_item_slot_index = function(_, item)
        for i, it in ipairs(h.keys_items) do if it == item then return i - 1 end end
        return -1
    end
    local utility = G.utility
    local right_click = utility.send_mouse_right_click
    utility.send_mouse_right_click = function(x, y)
        right_click(x, y)
        if not (h.vendor_screen and h.vendor_actor == h.brazier) then return end
        local ok_s, s = pcall(function() return h.mod(WC, 'core.settings') end)
        if not ok_s or not s then return end
        for i, it in ipairs(h.keys_items) do
            local slot = i - 1
            local sx = s.inventory_slot_0_x + (slot % 11) * s.inventory_cell_size_x
            local sy = s.inventory_slot_0_y + math.floor(slot / 11) * s.inventory_cell_size_y
            if math.abs(sx - x) < 1 and math.abs(sy - y) < 1 then
                table.remove(h.keys_items, i)
                W.tributes_used = W.tributes_used + 1
                W.pending_tribute = it.sno
                note('tribute', 'used tribute sno ' .. tostring(it.sno))
                return
            end
        end
    end

    -- ── floors ──
    local function new_floor(run, f, last)
        next_id = next_id + 1
        local len = last and (85 + rng.int(0, 30)) or (120 + rng.int(0, 40))
        local zone = last and 'X1_Undercity_Boss_Lacuni' or ('X1_Undercity_SnakeTemple_0' .. f)
        local place = {name = 'X1_Undercity_Joint', zone = zone, id = next_id, town = false,
            spawn = v(0, 0), box = {-25, len + 20, -35, 35}, key = 'uc_' .. letters(run.n) .. '_' .. letters(f):lower(),
            actors = {}, items = {}, slide = true, walls = {}, floor = f, run = run, vis = 60}
        h.P[place.key] = place -- h.remove_actor only searches the host's place table
        for i = 1, rng.int(1, 2) do
            local x = math.floor(len * i / 3)
            local gap = rng.range(-20, 20)
            place.walls[#place.walls + 1] = {x, x + 2, -35, gap - 4}
            place.walls[#place.walls + 1] = {x, x + 2, gap + 4, 35}
        end
        local function free(x, y)
            for _, w in ipairs(place.walls) do
                if x >= w[1] - 1.5 and x <= w[2] + 1.5 and y >= w[3] - 1.5 and y <= w[4] + 1.5 then return false end
            end
            return true
        end
        local function spot(x0, x1, y0, y1)
            for _ = 1, 20 do
                local x, y = rng.range(x0, x1), rng.range(y0, y1)
                if free(x, y) then return x, y end
            end
            return x0, 0
        end
        local function monster(skin, x, y, fields)
            local m = h.actor(place, skin, x, y, fields)
            m.enemy = true
            m.health = m.health or rng.int(80, 240)
            m.max_health = m.health
            local on_death = m.on_death
            m.on_death = function()
                h.remove_actor(m)
                W.kills = W.kills + 1
                if on_death then on_death(m) end
                if rng.chance(o.trash_drop or 0.18) then loot(place, m.pos:x(), m.pos:y(), 1, 0.02) end
                if rng.chance(0.25) then drop_obols(place, m.pos:x(), m.pos:y(), 1) end
            end
            return m
        end
        place.monster = monster
        for i = 1, rng.int(6, 10) do
            local x, y = spot(12, len, -28, 28)
            monster('X1_Undercity_Trash_' .. i, x, y)
        end
        if rng.chance(0.2) then
            local x, y = spot(30, len, -25, 25)
            monster('X1_Undercity_Treasure_Goblin', x, y, {health = 200, on_death = function(m)
                W.goblins = W.goblins + 1
                loot(place, m.pos:x(), m.pos:y(), rng.int(2, 4), 0.05)
            end})
        end
        -- Spirit Hearths (enticements): lit on interaction, 2-3 monsters come.
        for _ = 1, rng.int(0, 2) do
            local x, y = spot(15, len - 10, -25, 25)
            local s = h.actor(place, 'X1_Undercity_SpiritHearth_Switch', x, y)
            s.on_interact = function()
                if s.interactable == false or h.pos:dist_to_ignore_z(s.pos) > 3.5 then return end
                s.interactable = false
                W.hearths = W.hearths + 1
                note('hearth', 'Spirit Hearth lit on ' .. place.key)
                for k = 1, rng.int(2, 3) do
                    monster('X1_Undercity_Hearth_Spawn_' .. k, x + rng.range(-5, 5), y + rng.range(-5, 5))
                end
            end
        end
        if not last then
            local py = rng.range(-20, 20)
            place.pad = h.actor(place, 'X1_Undercity_WarpPad', len + 7, py)
            local sw = h.actor(place, 'X1_Undercity_PortalSwitch', len + 8, py)
            place.switch = sw
            local beacon_floor = rng.chance(o.beacon_share or 0.5)
            if beacon_floor then
                sw.interactable = false
                local bx, by = spot(20, len - 15, -25, 25)
                local b = h.actor(place, 'X1_Undercity_Enticements_SpiritBeaconSwitch', bx, by)
                place.beacon = b
                b.on_interact = function()
                    if b.interactable == false or h.pos:dist_to_ignore_z(b.pos) > 3.5 then return end
                    b.interactable = false
                    W.beacons = W.beacons + 1
                    note('beacon', 'Grand Beacon lit on ' .. place.key)
                    -- o.obols_at_beacon: the lit beacon spills obols 1.5-2 m
                    -- around it (a repro trigger; no draw from the world rng).
                    if o.obols_at_beacon then
                        for k, off in ipairs({{1.5, 0}, {-1.2, 1.2}, {0, -2}}) do
                            if k <= o.obols_at_beacon then
                                local it = h.drop(place, bx + off[1], by + off[2],
                                    {name = 'X1_Undercity_Obols', rarity = 0, obols = true, amount = 10})
                                it.obols = true
                            end
                        end
                    end
                    local wave = {}
                    for k = 1, rng.int(3, 5) do
                        wave[k] = monster('X1_Undercity_Beacon_Wave_' .. k, bx + rng.range(-6, 6), by + rng.range(-6, 6))
                    end
                    local opened = false
                    local function open()
                        if opened then return end
                        opened = true
                        sw.interactable = true
                        place.exit_opened_t = h.now
                        note('switch', 'floor exit opened on ' .. place.key)
                    end
                    place.wave = wave
                    place.open_switch = open
                    h.at(12, open)
                end
            end
            sw.on_interact = function()
                if h.travel or sw.interactable == false or h.pos:dist_to_ignore_z(sw.pos) > 3.5 then return end
                local nxt = run.floors[f + 1]
                note('descend', place.key .. ' -> ' .. nxt.key)
                local kind = place.beacon and 'beacon' or 'open'
                place.left_t = h.now
                local st = W.floor_stats[kind]
                st.n, st.sum = st.n + 1, st.sum + (h.now - (place.first_t or h.now))
                if place.exit_opened_t then
                    st.after_open = (st.after_open or 0) + (h.now - place.exit_opened_t)
                end
                h.travel_to(nxt, W.PORTAL_ENTRY, 'uc_floor_portal')
                h.travel.started = h.now
            end
        else
            local by = rng.range(-15, 15)
            place.well = h.actor(place, 'Healing_Well_Basic', len - 25, by + 8)
            local boss = monster('X1_Undercity_Lacuni_Boss', len, by,
                {boss = true, health = o.boss_health or rng.int(1500, 3000)})
            run.boss = boss
            boss.on_death = function()
                run.boss_dead_at = h.now
                note('boss', string.format('district boss of run %d killed', run.n))
                loot(place, boss.pos:x(), boss.pos:y(), rng.int(1, 3), o.boss_mythic or 0.05, 'boss')
                local chest = h.actor(place, 'X1_Undercity_Chest_Attunement', boss.pos:x() - 3, boss.pos:y())
                run.chest = chest
                -- o.death_after_boss: the player dies 0.3 s after the boss,
                -- before the chest is opened (a repro trigger).
                if o.death_after_boss then
                    h.at(0.3, function()
                        if h.place == place and not h.dead and not h.travel then
                            h.dead, h.goal, h.native = true, nil, nil
                            note('death', 'the player dies next to the dead district boss')
                        end
                    end)
                end
                chest.on_interact = function()
                    if chest.interactable == false or chest.opening or h.pos:dist_to_ignore_z(chest.pos) > 3.5 then return end
                    chest.opening = true
                    h.at(1.0, function()
                        chest.interactable = false
                        run.chest_opened_at = h.now
                        W.chests = W.chests + 1
                        note('chest', string.format('reward chest of run %d opened', run.n))
                        loot(place, chest.pos:x(), chest.pos:y(), rng.int(3, 6), o.chest_mythic or 0.08, 'chest')
                        drop_obols(place, chest.pos:x(), chest.pos:y(), o.chest_obols or rng.int(2, 4))
                        -- o.death_after_chest: the player dies 0.2 s after the
                        -- chest opens (a repro trigger).
                        -- o.bag_after_chest=s: the bag fills s seconds after
                        -- the chest opens (a repro trigger: Rosie's automatic
                        -- trip inside WonderCity's exit delay).
                        if o.bag_after_chest then
                            h.at(o.bag_after_chest, function()
                                h.inventory = h.inventory or {}
                                while #h.inventory < 33 do
                                    h.inventory[#h.inventory + 1] = h.gear({name = 'Helm_Rare_Joint', rarity = 3})
                                end
                                note('bag', 'bag filled to 33 items after the reward chest opened')
                            end)
                        end
                        if o.death_after_chest then
                            h.at(0.2, function()
                                if h.place == place and not h.dead and not h.travel then
                                    h.dead, h.goal, h.native = true, nil, nil
                                    note('death', 'the player dies next to the opened reward chest')
                                end
                            end)
                        end
                    end)
                end
            end
        end
        place.on_arrive = function(_, trip)
            place.first_t = place.first_t or h.now
            place.arrived_t = h.now
            run.last_floor = place
            run.first_floor_t = run.first_floor_t or h.now
            if f == 1 and run.portal then
                h.remove_actor(run.portal)
                run.portal = nil
            end
            if trip and trip.why ~= 'town_portal' then W.floors_entered = W.floors_entered + 1 end
        end
        return place
    end
    function W.new_run()
        local run = {n = #W.runs + 1, floors = {}, opened_at = h.now, tribute = W.pending_tribute}
        W.pending_tribute = nil
        local count = o.floors or rng.int(2, 4)
        for f = 1, count do run.floors[f] = new_floor(run, f, f == count) end
        -- Scenario invariant UC_ABANDON: a new Undercity while the last one's
        -- reward chest was never opened.
        local last = W.run
        if last and last.first_floor_t and not last.chest_opened_at then
            hit('UC_ABANDON', string.format('Undercity run %d (entered t=%.1f, reached %s, boss %s, exit %s) was '
                .. 'left without its reward chest and run %d is opened', last.n, last.first_floor_t,
                last.last_floor and last.last_floor.key or '-', last.boss_dead_at and 'dead' or 'alive',
                last.exit_how or 'none', run.n))
        end
        W.runs[#W.runs + 1] = run
        W.run = run
        W.opens = W.opens + 1
        note('open', string.format('Undercity run %d opened: %d floors%s', run.n, count,
            run.tribute and (', tribute ' .. run.tribute) or ''))
        return run
    end
    function W.in_uc() return h.place and h.place.run ~= nil end
    -- Entering a portal is a loading transition, not a cast.
    W.PORTAL_ENTRY = 0.05
    function W.portal_entry(tr)
        return tr and (tr.why == 'undercity_portal' or tr.why == 'uc_floor_portal' or tr.why == 'dungeon_reset')
    end

    -- The brazier: the tribute screen within 3 m.
    h.brazier.on_interact = function()
        if h.pos:dist_to_ignore_z(h.brazier.pos) > 3 then return end
        h.vendor_screen, h.vendor_actor = true, h.brazier
        -- o.bag_at_brazier: the bag fills when the tribute screen opens for
        -- the o.bag_at_brazier-th time (a repro trigger: a Rosie trip
        -- between runs, in the middle of the entry).
        W.brazier_opens = (W.brazier_opens or 0) + 1
        if o.bag_at_brazier and W.brazier_opens == o.bag_at_brazier then
            h.inventory = h.inventory or {}
            while #h.inventory < 33 do h.inventory[#h.inventory + 1] = h.gear({name = 'Helm_Rare_Joint', rarity = 3}) end
            note('bag', 'bag filled to 33 items as the tribute screen opens')
        end
    end
    local accepts = 0
    h.on_click = function()
        if not (h.vendor_screen and h.vendor_actor == h.brazier) then return end
        local n = h.logged('left-click ACCEPT')
        if n <= accepts then return end
        accepts = n
        h.vendor_screen, h.vendor_actor = false, nil
        if W.portal then return end
        local run = W.new_run()
        local portal = h.actor('kurast', 'Portal_Dungeon_Undercity', BRAZIER[1] + 4, BRAZIER[2] - 5)
        W.portal, run.portal = portal, portal
        portal.on_interact = function()
            if h.travel or h.pos:dist_to_ignore_z(portal.pos) > 3 then return end
            W.entries = W.entries + 1
            if W.kurast_arrival then
                local took = h.now - W.kurast_arrival
                W.kurast_times[#W.kurast_times + 1] = took
                -- Scenario invariant KURAST_SLOW.
                if took > 150 then
                    hit('KURAST_SLOW', string.format('%.0f s from the Kurast arrival at t=%.1f (%s) to the Undercity '
                        .. 'portal; %s', took, W.kurast_arrival, W.kurast_why or '-', h.invariants.status_lines()))
                end
                W.kurast_arrival = nil
            end
            W.portal = nil
            h.travel_to(run.floors[1], W.PORTAL_ENTRY, 'undercity_portal')
            h.travel.started = h.now
        end
    end
    W.kurast_times = {}

    -- reset_all_dungeons inside an Undercity ejects to the brazier.
    rawset(G, 'reset_all_dungeons', function()
        h.resets = h.resets + 1
        W.resets = W.resets + 1
        local floor = h.place
        local run = floor.run
        if not run or h.travel then return end
        h.at(0.5, function()
            if h.place == floor and not h.travel then
                run.exit_how, run.exit_t = 'reset', h.now
                W.exits[#W.exits + 1] = {t = h.now, run = run.n, how = 'reset'}
                note('exit', 'dungeon reset: run ' .. run.n .. ' left for Kurast')
                h.travel_to('kurast', W.PORTAL_ENTRY, 'dungeon_reset')
                h.travel.pos = v(BRAZIER[1] + 5, BRAZIER[2] - 7)
            end
        end)
    end)

    -- Kurast: a crowd / cart / another player's pet across the walk for a
    -- while, placed on o.kurast_block of the arrivals 1-6 s after them.
    local function kurast_block()
        if h.place ~= K or h.travel then return end
        local dx, dy
        if h.goal then dx, dy = h.goal:x() - h.pos:x(), h.goal:y() - h.pos:y() end
        if not dx or dx * dx + dy * dy < 1 then dx, dy = 0, 1 end
        local len = math.sqrt(dx * dx + dy * dy)
        dx, dy = dx / len, dy / len
        local cx, cy = h.pos:x() + dx * 3, h.pos:y() + dy * 3
        local half = rng.range(3, 7)
        local wall
        if math.abs(dx) >= math.abs(dy) then wall = {cx - 0.5, cx + 0.5, cy - half, cy + half}
        else wall = {cx - half, cx + half, cy - 0.5, cy + 0.5} end
        K.walls[#K.walls + 1] = wall
        local secs = rng.range(5, 25)
        W.kurast_blocks = (W.kurast_blocks or 0) + 1
        note('kurast block', string.format('x=[%.1f,%.1f] y=[%.1f,%.1f] for %.1f s', wall[1], wall[2], wall[3], wall[4], secs))
        h.at(secs, function()
            for i = #K.walls, 1, -1 do if K.walls[i] == wall then table.remove(K.walls, i) end end
        end)
    end
    -- Monsters within AGGRO m walk at the player (they stood still in the
    -- host, so a pack 12-14 m away never came into the rotation's 12 m and
    -- kept Rosie's fight hold on); goblins do not.
    W.AGGRO, W.MONSTER_SPEED, W.OBOL_RADIUS = 14, 3.5, 2.5
    local function monsters_approach(place)
        if not place.run or h.dead or h.travel then return end
        for _, a in ipairs(place.actors) do
            if a.enemy and (a.health or 0) > 0 and a.pos and not a.skin:find('Goblin', 1, true) then
                local d = a.pos:dist_to_ignore_z(h.pos)
                if d <= W.AGGRO and d > 1.5 then
                    local step = math.min(W.MONSTER_SPEED * 0.1, d - 1.5)
                    local nx = a.pos:x() + (h.pos:x() - a.pos:x()) / d * step
                    local ny = a.pos:y() + (h.pos:y() - a.pos:y()) / d * step
                    if h.walkable(v(nx, ny)) then a.pos = v(nx, ny) end
                end
            end
        end
    end
    -- Scenario invariant REWARD_LEFT: the run is left for good (reset or the
    -- exit teleport to Kurast) while boss / reward-chest loot Rosie wants
    -- still lies anywhere on the boss floor.
    local function reward_left(floor, why)
        local run = floor.run
        local left, within = {}, 0
        local sm = h.by_dir.Rosie and h.by_dir.Rosie.loaded['rosie.private.pickup.src.settings']
        local oks, ps = pcall(function() return sm.get() end)
        local reach = oks and type(ps) == 'table' and tonumber(ps.distance) or 0
        for _, it in ipairs(floor.items or {}) do
            if it.reward_of and not it.picked and not it.obols then
                local wanted, reason = rosie_wants(it)
                if wanted then
                    local d = it.pos:dist_to_ignore_z(W.depart_pos or h.pos)
                    if d <= reach then within = within + 1 end
                    left[#left + 1] = string.format('%s %s rarity=%s%s %.1f m from the exit spot (on the ground %.0f s; %s)',
                        it.reward_of, tostring(it.name), tostring(it.rarity), it.rarity == 6 and ' MYTHIC' or '',
                        d, h.now - (it.dropped_at or h.now), tostring(reason))
                end
            end
        end
        if #left == 0 then return end
        left[#left + 1] = string.format('pickup distance %s, %d item(s) within it', tostring(reach), within)
        local deaths = 0
        for _, t in ipairs(W.death_times) do if t >= (run.boss_dead_at or h.now) then deaths = deaths + 1 end end
        hit('REWARD_LEFT', string.format('run %d left (%s) with %d wanted reward item(s) on %s: %s; %d death(s) since the '
            .. 'boss died, chest %s', run.n, why, #left, floor.key, table.concat(left, '; '), deaths,
            run.chest_opened_at and string.format('opened t=%.1f', run.chest_opened_at) or 'unopened'))
    end
    -- The chaos injected in [t0, t1] (not skipped), for the slow-run hits.
    local function chaos_between(t0, t1)
        local counts, order = {}, {}
        for _, rec in ipairs(h.chaos and h.chaos.log or {}) do
            if not rec.skipped and rec.t >= t0 and rec.t <= t1 then
                local k = rec.kind
                if k == 'reload' then k = 'reload ' .. (tostring(rec.detail):match('reloaded (%w+)/') or '?') end
                if not counts[k] then order[#order + 1] = k end
                counts[k] = (counts[k] or 0) + 1
            end
        end
        local out = {}
        for _, k in ipairs(order) do out[#out + 1] = k .. ' x' .. counts[k] end
        return #out > 0 and table.concat(out, ', ') or 'none'
    end
    W.chaos_between = chaos_between
    -- The scene when a monitor hit is created (kept in hit.scene: the LOOP
    -- monitor rewrites hit.detail as the count grows).
    function W.scene()
        local place = h.place
        local parts = {string.format('scene t=%.1f %s pos=(%.1f,%.1f)', h.now, tostring(place.key), h.pos:x(), h.pos:y())}
        if place.run then
            parts[#parts + 1] = string.format('floor %d/%d', place.floor, #place.run.floors)
            if place.switch then
                parts[#parts + 1] = string.format('exit %s %.1f m (pad %.1f m)',
                    place.switch.interactable == false and 'closed' or 'open', place.switch.pos:dist_to_ignore_z(h.pos),
                    place.pad.pos:dist_to_ignore_z(h.pos))
            end
            if place.beacon then
                parts[#parts + 1] = string.format('beacon %s %.1f m', place.beacon.interactable == false and 'lit' or 'unlit',
                    place.beacon.pos:dist_to_ignore_z(h.pos))
            end
        end
        return table.concat(parts, ', ')
    end
    W.was_dead = false
    function W.tick()
        if h.dead and not W.was_dead then
            W.deaths = W.deaths + 1
            W.death_times[#W.death_times + 1] = h.now
        end
        W.was_dead = h.dead
        monsters_approach(h.place)
        -- o.bag_at_boss: the bag fills (33 items) when the live district boss
        -- first comes within 12 m (a repro trigger).
        local run_now = h.place.run
        if o.bag_at_boss and not W.bag_at_boss_done and run_now and run_now.boss and h.place == run_now.floors[#run_now.floors]
            and (run_now.boss.health or 0) > 0 and run_now.boss.pos:dist_to_ignore_z(h.pos) <= 12 then
            W.bag_at_boss_done = true
            h.inventory = h.inventory or {}
            while #h.inventory < 33 do h.inventory[#h.inventory + 1] = h.gear({name = 'Helm_Rare_Joint', rarity = 3}) end
            note('bag', 'bag filled to 33 items next to the live district boss')
        end
        -- Scenario invariant REWARD_FORGOTTEN: WonderCity waits for the reward
        -- chest to unlock ('not interactable before our click', logged only
        -- while tracker.done is false) on a boss floor whose chest was already
        -- opened: it forgot the run's reward state and waits for a chest that
        -- can never be opened again.
        W.log_i = W.log_i or 1
        while W.log_i <= #h.log do
            local line = h.log[W.log_i]
            W.log_i = W.log_i + 1
            if type(line) == 'string' and line:find('[WonderCity:chest] reward chest ', 1, true) and line:find('is not interactable before our click', 1, true) then
                local run_here = h.place.run
                if run_here and run_here.chest_opened_at and h.place == run_here.floors[#run_here.floors] then
                    W.forgotten = W.forgotten or {}
                    W.forgotten[h.place.key] = W.forgotten[h.place.key] or h.now
                    hit('REWARD_FORGOTTEN', string.format('run %d: WonderCity waits for the reward chest to unlock in %s '
                        .. '%.0f s after it was opened (t=%.1f): %s', run_here.n, h.place.key, h.now - run_here.chest_opened_at,
                        run_here.chest_opened_at, line:match('%); (.*)$') or '?'))
                end
            end
        end
        -- leaving a boss floor for Kurast (not a Rosie trip): REWARD_LEFT
        if h.place == h.P.limbo and W.tick_place and W.tick_place.run and h.travel and h.travel.to == K then
            local floor = W.tick_place
            if floor == floor.run.floors[#floor.run.floors] then reward_left(floor, tostring(h.travel.why)) end
        end
        if h.place ~= h.P.limbo then W.depart_pos = h.pos end
        W.tick_place = h.place
        -- obols: collected when walked over
        local items = h.place.items
        if items then
            for i = #items, 1, -1 do
                local it = items[i]
                if it.obols and not it.picked and it.pos:dist_to_ignore_z(h.pos) <= W.OBOL_RADIUS then
                    it.picked = true
                    table.remove(items, i)
                    h.obols = h.obols + (it.amount or 10)
                    W.obols_picked = W.obols_picked + 1
                end
            end
        end
        -- beacon wave killed: the floor exit opens
        local place = h.place
        if place.wave and place.open_switch then
            local alive = false
            for _, m in ipairs(place.wave) do if (m.health or 0) > 0 then alive = true end end
            if not alive then place.open_switch() end
        end
        -- Kurast arrival bookkeeping (KURAST_SLOW)
        if h.place == K and not h.travel and W.last_place ~= K then
            local a = h.arrivals[#h.arrivals]
            W.kurast_arrival, W.kurast_why = h.now, a and a.place == 'kurast' and a.why or 'start'
            if rng.chance(o.kurast_block or 0.35) then h.at(rng.range(1, 6), kurast_block) end
        end
        if h.place ~= h.P.limbo then W.last_place = h.place end
        local run = W.run
        if run and run.first_floor_t and not run.done then
            -- a run is over when the player is back in Kurast (not a Rosie trip)
            if h.place == K and not h.travel then
                run.done = true
                if run.chest_opened_at then W.completed = W.completed + 1 end
            elseif not run.slow and h.now - run.first_floor_t > 480 then
                run.slow = true
                local floors = {}
                for _, fl in ipairs(run.floors) do
                    if fl.first_t then
                        floors[#floors + 1] = string.format('%s %.0f s (%s)', fl.key, (fl.left_t or h.now) - fl.first_t,
                            fl.beacon and 'beacon' or (fl.switch and 'open' or 'boss'))
                    end
                end
                hit('UC_SLOW', string.format('Undercity run %d open for 480 s (first floor t=%.1f): now in %s, last floor '
                    .. '%s, boss %s, chest %s; floors: %s; chaos since: %s; %s', run.n, run.first_floor_t, h.place.key,
                    run.last_floor and run.last_floor.key or '-', run.boss_dead_at and 'dead' or 'alive',
                    run.chest_opened_at and 'opened' or (run.chest and 'closed' or 'none'), table.concat(floors, ', '),
                    chaos_between(run.first_floor_t, h.now), h.invariants.status_lines()))
            end
        end
        -- FLOOR_SLOW: one floor for more than 240 s (a Rosie trip's time excluded)
        if place.run and not h.travel then
            if place ~= W.floor_now then W.floor_now, W.floor_since, W.floor_slow = place, h.now, false end
            if not W.floor_slow and h.now - W.floor_since > 240 then
                W.floor_slow = true
                local exit = 'boss floor'
                if place.switch then
                    if place.switch.interactable == false then exit = 'closed (Grand Beacon '
                        .. (place.beacon.interactable == false and 'lit' or 'unlit') .. ')'
                    elseif place.exit_opened_t then exit = string.format('opened by the beacon at t=%.1f', place.exit_opened_t)
                    else exit = 'open from the start' end
                end
                hit('FLOOR_SLOW', string.format('240 s on %s (floor %d of %d, since t=%.1f); exit %s; chaos since: %s; %s',
                    place.key, place.floor, #place.run.floors, W.floor_since, exit, chaos_between(W.floor_since, h.now),
                    h.invariants.status_lines()))
            end
        elseif place == K or place.town then
            W.floor_now = nil
        end
    end
    return W
end

-- ── one seeded run ────────────────────────────────────────────────────────
local function pick(rng, list) return list[rng.int(1, #list)] end
-- Per-seed configuration (all from the seed): exit mode, tribute handling,
-- pickup distance, chaos rate, start town; all plugins loaded (as installed)
-- on some. QQT_SWEEP_* override the seed's draw (to minimise a repro).
local function env_override(o)
    local exit = os.getenv('QQT_SWEEP_EXIT')
    if exit and exit ~= '' and o.exit_mode == nil then o.exit_mode = exit == 'teleport' and 1 or 0 end
    if o.distance == nil then o.distance = tonumber(os.getenv('QQT_SWEEP_DISTANCE') or '') end
    if o.rate == nil then o.rate = tonumber(os.getenv('QQT_SWEEP_RATE') or '') end
    if o.floors == nil then o.floors = tonumber(os.getenv('QQT_SWEEP_FLOORS') or '') end
    local plugins = os.getenv('QQT_SWEEP_PLUGINS')
    if plugins and plugins ~= '' and o.all_plugins == nil then o.all_plugins = plugins == 'all' end
    local tribute = os.getenv('QQT_SWEEP_TRIBUTE')
    if tribute and tribute ~= '' and o.tribute == nil then o.tribute = tribute end
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
    local irq = os.getenv('QQT_SWEEP_INTERRUPT')
    if o.interrupt == nil and irq and irq ~= '' then
        if irq == 'off' then o.interrupt = false else o.interrupt = irq end
    end
    if o.beacon_share == nil then o.beacon_share = tonumber(os.getenv('QQT_SWEEP_BEACON') or '') end
    local start_at = os.getenv('QQT_SWEEP_START')
    if start_at and start_at ~= '' and o.start == nil then o.start = start_at end
    return o
end
local function config(seed, o)
    local rng = J.rng(seed * 104729 + 5)
    for _ = 1, seed % 7 do rng.next() end
    local c = {seed = seed}
    local draw = {exit_mode = rng.chance(0.5) and 1 or 0, tribute = pick(rng, {'skip', 'use', 'none'}),
        distance = pick(rng, {2, 8, 15}), rate = pick(rng, {0.6, 1.0, 1.5}), all_plugins = rng.chance(0.3),
        start = rng.chance(0.5) and 'temis' or 'kurast'}
    c.exit_mode = o.exit_mode or draw.exit_mode
    c.tribute = o.tribute or draw.tribute
    c.distance = o.distance or draw.distance
    c.rate = o.rate or draw.rate
    c.start = o.start or draw.start
    c.all_plugins = o.all_plugins
    if c.all_plugins == nil then c.all_plugins = draw.all_plugins end
    c.floors = o.floors
    c.interrupt = o.interrupt
    return c
end
local function describe(c)
    return string.format('seed=%d exit=%s tribute=%s pickup=%dm chaos=%.1f/min start=%s plugins=%s', c.seed,
        c.exit_mode == 1 and 'teleport' or 'reset', c.tribute, c.distance, c.rate, c.start,
        c.all_plugins and 'all' or 'WonderCity,Batmobile,Rosie')
end

-- QQT keeps a menu value the user set in this session under its hash; a
-- script reload recreates the widget with it. The joint host's h.reload loads
-- the defaults, so a chaos 'reload' switched WonderCity off for the rest of
-- the seed. Here every value this scenario sets (h.setw) is recorded, and a
-- widget created again during a reload gets it back.
local function keep_session_widgets(h)
    local session, reloading = {}, false
    local G = h.G
    for _, ctor in ipairs({'checkbox', 'combo_box', 'slider_int', 'slider_float'}) do
        local tbl = G[ctor]
        local orig = tbl.new
        tbl.new = function(...)
            local w = orig(...)
            local n = select('#', ...)
            local key = n > 0 and select(n, ...) or nil
            if reloading and type(key) == 'string' and session[key] ~= nil then w:set(session[key]) end
            return w
        end
    end
    local reload = h.reload
    h.reload = function(dir, o)
        reloading = true
        local okr, err = pcall(reload, dir, o)
        reloading = false
        if not okr then error(err, 0) end
    end
    -- h.setw(elements, name, hash key, value)
    function h.setw(el, name, key, value)
        el[name]:set(value)
        session[key] = value
    end
end

local function start(seed, o)
    o = env_override(o or {})
    local c = config(seed, o)
    local dirs = {'Batmobile', WC}
    if c.all_plugins then dirs = nil end -- every folder of the package (J.DIRS), all but WonderCity off
    local chaos = {seed = seed, rate = c.rate, kinds = o.kinds, only = o.only, schedule = o.schedule}
    if o.chaos == false then chaos = nil end
    local h = J.new({rosie = true, dirs = dirs, place = c.start, seed = seed, ordered_pairs = true,
        virtual_os_clock = true, shipped_defaults = true, invariants = o.invariants ~= false,
        rotation = {seed = seed, interrupt = c.interrupt == nil and 'dash' or c.interrupt}, chaos = chaos})
    h.assert_clean('load ' .. describe(c))
    -- Speed only (a fifth of the CPU went to the shared table's __index):
    -- the Lua base names are stored raw in the shared table, same values
    -- (the ordered pairs included). Only an assignment to one of these
    -- names would no longer be recorded in h.global_writes.
    for _, name in ipairs({'assert', 'error', 'ipairs', 'next', 'pairs', 'pcall', 'xpcall', 'rawequal', 'rawget',
        'rawset', 'select', 'setmetatable', 'getmetatable', 'tonumber', 'tostring', 'type', 'unpack', 'bit', 'jit',
        'debug', 'coroutine', 'string', 'table', 'math', 'print', 'os', 'io'}) do
        local val = h.G[name]
        if val ~= nil then rawset(h.G, name, val) end
    end
    keep_session_widgets(h)
    local W = build_world(h, seed, {floors = c.floors, boss_health = o.boss_health,
        tributes = (c.tribute == 'use') and 3 or 0, beacon_share = o.beacon_share,
        boss_mythic = o.boss_mythic, chest_mythic = o.chest_mythic, bag_at_boss = o.bag_at_boss or os.getenv('QQT_SWEEP_BAG_AT_BOSS') == '1',
        kurast_block = o.kurast_block or tonumber(os.getenv('QQT_SWEEP_KURAST_BLOCK') or ''),
        death_after_chest = o.death_after_chest or os.getenv('QQT_SWEEP_DEATH_AFTER_CHEST') == '1',
        bag_after_chest = o.bag_after_chest or tonumber(os.getenv('QQT_SWEEP_BAG_AFTER_CHEST') or ''),
        death_after_boss = o.death_after_boss or os.getenv('QQT_SWEEP_DEATH_AFTER_BOSS') == '1',
        bag_at_brazier = o.bag_at_brazier or tonumber(os.getenv('QQT_SWEEP_BAG_AT_BRAZIER') or ''),
        obols_at_beacon = o.obols_at_beacon or tonumber(os.getenv('QQT_SWEEP_OBOLS_AT_BEACON') or ''),
        chest_obols = o.chest_obols or tonumber(os.getenv('QQT_SWEEP_CHEST_OBOLS') or '')})
    if h.place == h.P.kurast then h.pos = h.P.kurast.spawn end
    local gui = h.mod(WC, 'gui').elements
    local L = 'wonder_city_'
    h.setw(gui, 'main_toggle', L .. 'main_toggle', true)
    h.setw(gui, 'exit_mode', L .. 'exit_mode', c.exit_mode)
    h.setw(gui, 'skip_tribute', L .. 'skip_tribute', c.tribute == 'skip')
    if c.tribute == 'use' then h.setw(gui, 'tribute_priority_1', L .. 'tribute_priority_1', 1) end
    h.setw(h.mod('Rosie', 'rosie.private.pickup.gui').elements.general, 'distance_slider',
        'rosie_distance_slider', c.distance)
    ok(h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end) == true, 'Rosie enabled')
    h.c = c
    -- Who cast each teleport and which WonderCity task ran (a tail call keeps
    -- the host's caller attribution for the TELEPORT monitor).
    local tp_log, orig_tp = {}, h.G.teleport_to_waypoint
    h.tp_log = tp_log
    local function wc_task()
        local tm = h.mod(WC, 'core.task_manager')
        local got, task = pcall(function() return tm and tm.get_current_task() end)
        return got and type(task) == 'table' and tostring(task.name) or '-'
    end
    h.wc_task = wc_task
    -- A move command during a waypoint / Town Portal channel interrupts it,
    -- as in the game (the host froze the player and let the cast finish;
    -- test_rosie_foreign_mover models the same by hand). A portal entry is a
    -- loading transition and is not affected.
    W.move_breaks = 0
    local pf = h.G.pathfinder
    for _, name in ipairs({'request_move', 'force_move_raw', 'force_move', 'move_to_cpathfinder'}) do
        local orig = pf[name]
        if type(orig) == 'function' then
            pf[name] = function(p, ...)
                local tr = h.travel
                if tr and tr.phase == 'channel' and not W.portal_entry(tr) and type(p) == 'table' and p.x
                    and h.pos:dist_to_ignore_z(p) > 1 then
                    h.travel, h.casting = nil, false
                    W.move_breaks = W.move_breaks + 1
                    W.breaks = W.breaks or {}
                    W.breaks[#W.breaks + 1] = {t = h.now, ctx = tostring(h.context_name()), why = tostring(tr.why)}
                    h.log[#h.log + 1] = string.format('%.1f [uc] channel: %s by %s broke the %s channel', h.now, name,
                        tostring(h.context_name()), tostring(tr.why))
                end
                return orig(p, ...)
            end
        end
    end
    local inv_hit = h.invariants and h.invariants.hit
    if inv_hit then
        h.invariants.hit = function(kind, detail, data)
            local rec = inv_hit(kind, detail, data)
            local okc, scene = pcall(W.scene)
            if type(rec) == 'table' then rec.scene = okc and scene or ('scene error: ' .. tostring(scene)) end
            return rec
        end
    end
    local rot_tick = h._rot.tick
    h._rot.tick = function(...)
        if W.portal_entry(h.travel) then return end
        return rot_tick(...)
    end
    rawset(h.G, 'teleport_to_waypoint', function(sno)
        if W.portal_entry(h.travel) then
            h.log[#h.log + 1] = string.format('%.1f [uc] teleport_to_waypoint(0x%X) ignored: entering a portal', h.now, sno)
            return false
        end
        tp_log[#tp_log + 1] = {t = h.now, sno = sno, ctx = h.context_name() or '-', from = h.place.key, task = wc_task()}
        -- Scenario invariant BOSS_TRIP: a teleport cast next to a live
        -- district boss (WonderCity defers its own trips while it fights one).
        local run = W.run
        local boss = run and run.boss
        if h.invariants and boss and (boss.health or 0) > 0 and h.place == run.floors[#run.floors] and not h.travel
            and h.pos:dist_to_ignore_z(boss.pos) <= 30 then
            h.invariants.hit('BOSS_TRIP', string.format('teleport_to_waypoint(0x%X) cast by %s (WonderCity task %s) %.1f m '
                .. 'from the live district boss (hp %.0f/%.0f) in %s; bag %d items', sno, tp_log[#tp_log].ctx,
                tp_log[#tp_log].task, h.pos:dist_to_ignore_z(boss.pos), boss.health, boss.max_health, h.place.key,
                #(h.inventory or {})))
        end
        return orig_tp(sno)
    end)
    return h, W
end
-- The teleport cast behind a travel that ended at `t` (within `window` s).
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
local function classify(hit, ctx)
    for _, r in ipairs(RULES) do
        if r.kind == hit.kind and r.fn(hit, ctx) then return r end
    end
    return nil
end
local function cast_by(ctx, who, task)
    return ctx.cast ~= nil and ctx.cast.ctx == who and (task == nil or ctx.cast.task == task)
end
local function chaos_count(hit, kind)
    local list = hit.detail:match('chaos since: ([^;]*)') or ''
    return tonumber(list:match(kind .. ' x(%d+)')) or 0
end
-- The TELEPORT hit's casts: every one by `owner` (and `dest` if given).
local function casts_only(hit, owner, kind)
    local list = hit.detail:match('%(max %d+%): (.*)$') or ''
    list = list:gsub(' {scene.*$', '')
    local n, other = 0, false
    for item in list:gmatch('[^;]+') do
        if not item:find('...', 1, true) then
            n = n + 1
            if not item:find(kind .. ' by ' .. owner, 1, true) then other = true end
        end
    end
    return n > 0 and not other
end

-- KNOWN (Rosie session): the outbound Town Portal re-cast (every ~3 s, up to
-- 12 casts with refunds) when the channel breaks (the rotation's evade).
rule('ROSIE-tp-recast', 'known', 'TELEPORT', function(hit)
    return casts_only(hit, 'Rosie', 'town_portal->temis')
end, 'known: Rosie outbound Town Portal re-cast while the channel is broken')
-- KNOWN (Activities): walk_kurast recovery re-teleports / teleport_kurast
-- retries (WonderCity casts only, to the Kurast waypoint).
-- The WonderCity tasks behind a TELEPORT hit's casts (from the scenario's
-- teleport log).
local function cast_tasks(hit, ctx)
    local tasks = {}
    local list = (hit.detail:match('%(max %d+%): (.*)$') or ''):gsub(' {scene.*$', '')
    for t in list:gmatch('t=([%d%.]+)') do
        t = tonumber(t)
        for _, c in ipairs(ctx.h.tp_log) do
            if math.abs(c.t - t) < 0.06 then tasks[c.task] = (tasks[c.task] or 0) + 1 end
        end
    end
    return tasks
end
rule('WC-kurast-teleports', 'known', 'TELEPORT', function(hit, ctx)
    if not casts_only(hit, 'WonderCity', 'waypoint->kurast') then return false end
    for task in pairs(cast_tasks(hit, ctx)) do
        if task ~= 'walk_kurast' and task ~= 'teleport_kurast' then return false end
    end
    return true
end, 'known: walk_kurast recovery / teleport_kurast uncapped re-teleports')
-- By design (a trade-off): a wanted drop that falls during WonderCity's exit
-- teleport channel makes Rosie's looter walk to it; the move breaks the
-- channel and exit_undercity re-casts after its 5 s debounce. One extra cast
-- per broken channel; the drop is picked up instead of left behind.
rule('WC-exit-recast-after-pickup-break', 'expected', 'TELEPORT', function(hit, ctx)
    -- WonderCity's exit casts, optionally followed by Rosie's own (separate)
    -- Town Portal trip when the bag fills during the exit.
    local times = {}
    local list = (hit.detail:match('%(max %d+%): (.*)$') or ''):gsub(' {scene.*$', '')
    for item in list:gmatch('[^;]+') do
        local t = tonumber(item:match('t=([%d%.]+)'))
        if item:find('waypoint->kurast by WonderCity', 1, true) and t then
            for _, c in ipairs(ctx.h.tp_log) do
                if math.abs(c.t - t) < 0.06 and c.task ~= 'exit_undercity' then return false end
            end
            times[#times + 1] = t
        elseif item:find('town_portal->temis by Rosie', 1, true) then
            if #times == 0 then return false end
        elseif not item:find('...', 1, true) then
            return false
        end
    end
    for i = 1, #times - 1 do
        local broken = false
        for _, b in ipairs(ctx.W.breaks or {}) do
            if b.ctx == 'Rosie' and b.t >= times[i] and b.t <= times[i + 1] then broken = true end
        end
        if not broken then return false end
    end
    return #times > 0
end, "Rosie's pickup of a drop that fell in WonderCity's exit channel broke it; one re-cast per break")
-- FINDING: WonderCity casts its exit teleport with enemies in range (the
-- reward phase does not wait for a fight to end); the rotation's evade breaks
-- the channel and exit_undercity re-casts every 5 s (exit_with_debounce,
-- no cap and no enemy check) until one channel survives.
rule('WC-exit-recast-rotation', 'finding', 'TELEPORT', function(hit, ctx)
    local times = {}
    local list = (hit.detail:match('%(max %d+%): (.*)$') or ''):gsub(' {scene.*$', '')
    for item in list:gmatch('[^;]+') do
        local t = tonumber(item:match('t=([%d%.]+)'))
        if item:find('waypoint->kurast by WonderCity', 1, true) and t then
            for _, c in ipairs(ctx.h.tp_log) do
                if math.abs(c.t - t) < 0.06 and c.task ~= 'exit_undercity' then return false end
            end
            times[#times + 1] = t
        elseif not (item:find('town_portal->temis by Rosie', 1, true) and #times > 0) and not item:find('...', 1, true) then
            return false
        end
    end
    local rotation = 0
    for i = 1, #times - 1 do
        local broken = false
        for _, e in ipairs(ctx.h.rotation and ctx.h.rotation.events or {}) do
            if e.kind == 'interrupt' and e.t >= times[i] and e.t <= times[i + 1] then broken, rotation = true, rotation + 1 end
        end
        for _, b in ipairs(ctx.W.breaks or {}) do
            if b.t >= times[i] and b.t <= times[i + 1] then broken = true end
        end
        if not broken then return false end
    end
    return rotation > 0
end, "the rotation's evade breaks WonderCity's exit channel in a fight; uncapped 5 s re-casts")
-- KNOWN (Rosie session): a drop that falls during Rosie's own Town Portal cast.
rule('ROSIE-tp-cast-drop', 'known', 'LEFT_DROP', function(hit, ctx)
    return has(hit, '(waypoint)') and has(hit, '[dropped during the waypoint channel]') and cast_by(ctx, 'Rosie')
end, 'known: Rosie leaving a drop that falls during the Town Portal cast')
-- New variant of the same: WonderCity's exit teleport (exit mode Teleport).
rule('WC-exit-cast-drop', 'finding', 'LEFT_DROP', function(hit, ctx)
    return has(hit, '(waypoint)') and has(hit, '[dropped during the waypoint channel]') and cast_by(ctx, WC, 'exit_undercity')
end, 'new variant: a drop falling during WonderCity\'s exit teleport channel is left for good')
-- SWEEP (harness author's finding, S3 variant): wanted drops on the ground
-- when a Rosie trip starts (Rosie's own automatic trip, or WonderCity's
-- trigger_tasks_with_teleport) are left; the Town Portal returns to the spot
-- and they are picked up after it.
rule('ROSIE-trip-leaves-ground-drops', 'sweep', 'LEFT_DROP', function(hit)
    return has(hit, '[already wanted at the cast: town_portal by Rosie')
end, "sweep finding: a Rosie trip leaves wanted drops already on the ground (picked up after the return)")
-- SWEEP (harness author's finding): the warp pad keeps the portal task alive
-- while the PortalSwitch next to it is set aside.
rule('WC-pad-thrash-aside', 'sweep', 'LOOP', function(hit)
    return has(hit, 'WonderCity.task switches') and has(hit, 'portal') and has(hit, 'explore_undercity')
        and has(hit, ', exit open ')
end, 'sweep finding: warp pad thrash while the PortalSwitch is set aside (portal.lua:123-127)')
-- FINDING (new trigger of the same code): on a Grand Beacon floor the exit
-- is closed until the beacon is lit; the pad alone keeps the portal task
-- pulling the player back while the beacon lies beyond check_distance.
rule('WC-pad-thrash-beacon', 'finding', 'LOOP', function(hit)
    return has(hit, 'WonderCity.task switches') and has(hit, 'portal')
        and (has(hit, 'explore_undercity') or has(hit, 'kill_monster'))
        and has(hit, ', exit closed ') and has(hit, 'beacon unlit')
end, 'new variant: pad thrash on a beacon floor whose exit is still closed (beacon unlit)')
-- FINDING (LOW): loot_obols' "obols in the beacon" exclusion depends on the
-- beacon being the closest enticement within 20 m of the PLAYER.
rule('WC-obols-beacon-thrash', 'finding', 'LOOP', function(hit)
    return has(hit, 'WonderCity.task switches') and has(hit, 'loot_obols') and has(hit, 'beacon lit')
end, 'loot_obols flips an obol next to a lit beacon in and out of reach (player-relative exclusion)')
-- FINDING (LOW, same family as F1 / F6): interact_enticement picks an
-- enticement only within check_distance (20 m) of the PLAYER; when the path
-- to it detours away (a wall) the player leaves the 20 m ring, a lower task
-- (loot_obols / the explorer) walks back in, and the two flip every 0.5 s.
rule('WC-enticement-edge-thrash', 'finding', 'LOOP', function(hit)
    return has(hit, 'WonderCity.task switches') and has(hit, 'interact_enticement')
        and (has(hit, 'loot_obols') or has(hit, 'explore_undercity')) and mean_dwell(hit) < 3
end, 'interact_enticement flips at the 20 m check_distance ring (player-relative selection)')
rule('LOOP-fight-explore', 'expected', 'LOOP', function(hit)
    return has(hit, 'WonderCity.task switches') and (has(hit, 'kill_monster') or has(hit, 'loot_hold'))
        and mean_dwell(hit) >= 3
end, 'fight / pickup hold alternation (mean dwell >= 3 s), not a thrash')
-- Slow floors / runs: chaos-driven (a Batmobile or WonderCity reload loses
-- the explorer map, two or more deaths walk back from the checkpoint).
local function chaos_slow(hit)
    return chaos_count(hit, 'reload Batmobile') + chaos_count(hit, 'reload WonderCity') > 0
        or chaos_count(hit, 'death') >= 2
end
rule('SLOW-chaos', 'expected', 'FLOOR_SLOW', chaos_slow, 'chaos: explorer reload or repeated deaths on the floor')
rule('SLOW-chaos-run', 'expected', 'UC_SLOW', chaos_slow, 'chaos: explorer reload or repeated deaths in the run')
-- FINDING (S3 instance of the S2 sweep's F3): Rosie's automatic trip starts
-- 0.5 s after the bag fills, in melee with the live district boss;
-- WonderCity 2.2.4 defers only its own request (tasks/alfred.lua
-- boss_fight_defer) and yields to Rosie's live work.
rule('ROSIE-auto-trip-in-boss-fight', 'finding', 'BOSS_TRIP', function(hit)
    return has(hit, 'cast by Rosie')
end, "Rosie's automatic Town Portal during a live district boss fight")
rule('WC-boss-defer-cap', 'expected', 'BOSS_TRIP', function(hit)
    return has(hit, 'cast by WonderCity')
end, "WonderCity's own trip after its 90 s boss-fight defer cap")
-- FINDING (config-dependent, S3 form of the S2 sweep's F4): WonderCity's
-- reward phase ends at the chest (goto_chest stops within 2 m, then obols and
-- the exit); nothing walks the loot burst 1-4 m around it, so with Rosie's
-- shipped 2 m pickup distance part of the chest / boss loot stays behind.
rule('WC-exit-leaves-reward-loot', 'finding', 'REWARD_LEFT', function(hit)
    return has(hit, ' 0 item(s) within it') and (tonumber(hit.detail:match('(%d+) death%(s%) since')) or 0) == 0
end, 'the run exits with reward loot beyond Rosie\'s pickup distance around the chest / boss')
-- FINDING: a death after the boss: the revive at the floor's checkpoint
-- leaves the reward loot beyond Rosie's reach; WonderCity's reward phase
-- does not walk back to it (only obols can pull it back) and exits.
rule('WC-exit-after-death-leaves-reward', 'finding', 'REWARD_LEFT', function(hit)
    return (tonumber(hit.detail:match('(%d+) death%(s%) since')) or 0) > 0
end, 'after a death near the chest, the run exits without going back to the reward loot')
rule('SLOW-run-beacon-floor', 'finding', 'UC_SLOW', function(hit)
    for secs in hit.detail:gmatch('uc_%a+_%a+ (%d+) s %(beacon%)') do
        if tonumber(secs) >= 150 then return true end
    end
    return false
end, 'consequence of the beacon-floor findings: a beacon floor took 150 s+ of the run')
-- The S2 sweep's F4 form: a Unique / Mythic beyond Rosie's pickup distance
-- (but within 15 m) left when WonderCity exits after the reward.
rule('WC-exit-unique-beyond-distance', 'finding', 'LEFT_DROP', function(hit, ctx)
    return has(hit, '(beyond it: Unique/Mythic within the radius)')
        and (cast_by(ctx, WC, 'exit_undercity') or has(hit, '(dungeon_reset)'))
end, 'a Unique/Mythic beyond the pickup distance left when WonderCity exits after the reward')
rule('SLOW-beacon-floor', 'finding', 'FLOOR_SLOW', function(hit)
    return has(hit, 'exit opened by the beacon') or has(hit, 'exit closed (Grand Beacon')
end, 'consequence of WC-pad-thrash-beacon: a beacon floor takes 240 s+')
-- FINDING: a Rosie trip that starts after WonderCity's exit phase began
-- (exit_trigger_time set: the 10 s exit delay or the exit channel) is not
-- recorded as a resumable Alfred trip (core/tracker.lua observe_world: the
-- resume key needs exit_trigger_time == nil); the return into the same
-- Undercity counts as a NEW run (reset_floor_state, new start time), the
-- opened chest is not interactable, and the player stands still in
-- finish_undercity until the 600 s run timeout.
rule('WC-reward-forgotten-after-trip', 'finding', 'REWARD_FORGOTTEN', function(hit)
    return has(hit, 'no opened evidence')
end, 'a Rosie trip during the exit delay: the return is a new run (reward state gone), 60-600 s lost')
-- LOW: a Rosie trip between WonderCity's chest click and its confirmation:
-- the run resumes (reward evidence kept: tracker.chest_interacted) but the
-- 'resume' transition resets goto_chest (last_interact_call), so it re-checks
-- the opened chest as 'not interactable before our click' and waits
-- LOCKED_WAIT (10 s) before accepting it.
rule('WC-chest-recheck-after-trip', 'expected', 'REWARD_FORGOTTEN', function(hit)
    return has(hit, 'opened evidence:') or (has(hit, 'waiting up to') and not has(hit, 'no opened evidence'))
end, 'LOW: after a resumed trip goto_chest re-checks the opened chest (10 s LOCKED_WAIT)')
local function forgotten_here(hit, ctx)
    local key = hit.detail:match('{scene t=[%d%.]+ (%S+) ') or hit.detail:match('now in (uc_%a+_%a+)')
    local t = key and ctx.W.forgotten and ctx.W.forgotten[key]
    return t ~= nil and t <= hit.t
end
rule('WC-reward-forgotten-stall', 'finding', 'STALL', function(hit, ctx)
    return has(hit, 'finish_undercity (waiting for reward chest)') and forgotten_here(hit, ctx)
end, 'consequence of WC-reward-forgotten-after-trip: standing still until the run timeout')
rule('WC-reward-forgotten-floor', 'finding', 'FLOOR_SLOW', function(hit, ctx)
    return has(hit, 'finish_undercity (waiting for reward chest)') and forgotten_here(hit, ctx)
end, 'consequence of WC-reward-forgotten-after-trip')
rule('WC-reward-forgotten-run', 'finding', 'UC_SLOW', function(hit, ctx)
    return forgotten_here(hit, ctx)
end, 'consequence of WC-reward-forgotten-after-trip')
-- By design: WonderCity's run timeout (settings reset_timeout, 600 s) ends
-- a run that chaos slowed down (it already hit UC_SLOW).
rule('UC-timeout-exit', 'expected', 'UC_ABANDON', function(hit, ctx)
    local n, entered = hit.detail:match('Undercity run (%d+) %(entered t=([%d%.]+)')
    local run = n and ctx.W.runs[tonumber(n)]
    return run ~= nil and run.slow == true and (run.exit_t or hit.t) - tonumber(entered) >= 595
end, "WonderCity's 600 s run timeout after a slow (chaos) run")
-- Chaos: Rosie reloaded during a town trip out of the Undercity ('cancelled:
-- Rosie reloaded during service'); the return portal leg is gone, WonderCity
-- teleports to Kurast and opens a new Undercity.
rule('UC-rosie-reload-mid-trip', 'expected', 'UC_ABANDON', function(hit, ctx)
    local entered = tonumber(hit.detail:match('%(entered t=([%d%.]+)'))
    if not entered then return false end
    for _, line in ipairs(ctx.h.log) do
        local t = type(line) == 'string' and tonumber(line:match('^([%d%.]+) '))
        if t and t >= entered and t <= hit.t and line:find('Rosie reloaded during service', 1, true) then return true end
    end
    return false
end, 'chaos: a Rosie reload during a trip out of the Undercity loses the return leg')

-- FINDING (LOW): Batmobile navigator log rate (navigator.lua:2084 PARTIAL
-- PATH REJECTED, :1885 STUCK) while a target stays unreachable; same family
-- as the harness author's LOW [nav] STUCK finding.
rule('BAT-nav-log-rate', 'finding', 'SPAM', function(hit)
    return has(hit, '(by Batmobile') and has(hit, '[nav] ')
end, 'Batmobile [nav] log lines 20+ times a minute while a target is unreachable')

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
local SEEDS = ENV_SEEDS and ENV_SEEDS ~= '' and parse_seeds(ENV_SEEDS) or {301}
local SECONDS = tonumber(os.getenv('QQT_SWEEP_SECONDS') or '') or 900
local VERBOSE = os.getenv('QQT_SWEEP_VERBOSE') == '1'
local TAIL = tonumber(os.getenv('QQT_SWEEP_TAIL') or '')
local ONLY = os.getenv('QQT_SWEEP_ONLY')

local S = {seeds = 0, emulated = 0, hits = {}, by_rule = {}, unclassified = {}, crashes = {}, runs = 0, opened = 0}
local function sweep_seed(seed, o, seconds)
    seconds = seconds or SECONDS
    local t0 = os.clock()
    local h, W = start(seed, o)
    local progress, next_report = os.getenv('QQT_SWEEP_PROGRESS') == '1', h.now + 600
    local probes = {}
    for t in (os.getenv('QQT_SWEEP_PROBE') or ''):gmatch('[%d%.]+') do probes[#probes + 1] = tonumber(t) end
    local function probe()
        local near, nd = nil, nil
        for _, a in ipairs(h.place.actors or {}) do
            if a.enemy and (a.health or 100) > 0 then
                local d = a.pos:dist_to_ignore_z(h.pos)
                if not nd or d < nd then near, nd = a, d end
            end
        end
        local ground = {}
        for _, it in ipairs(h.place.items or {}) do
            if not it.picked and #ground < 8 then
                ground[#ground + 1] = string.format('%s(%.0f,%.0f)%.0fm', it.obols and 'obol' or tostring(it.rarity),
                    it.pos:x(), it.pos:y(), it.pos:dist_to_ignore_z(h.pos))
            end
        end
        local objectives = {}
        for _, a in ipairs(h.place.actors or {}) do
            if not a.enemy and a.skin:match('^X1_Undercity') then
                objectives[#objectives + 1] = string.format('%s%s(%.0f,%.0f)%.0fm', a.skin:gsub('X1_Undercity_', ''),
                    a.interactable == false and '[off]' or '', a.pos:x(), a.pos:y(), a.pos:dist_to_ignore_z(h.pos))
            end
        end
        print(string.format('  probe t=%.1f place=%s pos=(%.1f,%.1f) goal=%s nearest enemy %s travel=%s dead=%s '
            .. 'rotation casts=%d interrupts=%d bag=%d; ground: %s; objectives: %s; %s', h.now, h.place.key, h.pos:x(),
            h.pos:y(), h.goal and string.format('(%.1f,%.1f)', h.goal:x(), h.goal:y()) or '-',
            near and string.format('%s %.1f m', near.skin, nd) or '-', tostring(h.travel and h.travel.why),
            tostring(h.dead), h.rotation.casts, h.rotation.interrupts, #(h.inventory or {}), table.concat(ground, ' '),
            table.concat(objectives, ' '), h.invariants and h.invariants.status_lines() or ''))
    end
    local each = function()
        W.tick()
        while probes[1] and h.now >= probes[1] do table.remove(probes, 1); probe() end
        if progress and h.now >= next_report then
            next_report = next_report + 600
            print(string.format('  progress seed %d: t=%.0f cpu=%.1f s, log %d lines, runs %d/%d', seed, h.now,
                os.clock() - t0, #h.log, W.completed, W.opens))
            io.stdout:flush()
        end
    end
    local ok_run, err = xpcall(function() h.run(seconds, each) end, debug.traceback)
    S.seeds, S.emulated = S.seeds + 1, S.emulated + seconds
    S.runs, S.opened = S.runs + W.completed, S.opened + W.opens
    local label = describe(h.c) .. (o and o.label and (' ' .. o.label) or '')
    local kt = 0
    for _, t in ipairs(W.kurast_times) do kt = kt + t end
    print(string.format('S3 %s: %.0f s emulated in %.1f s; runs opened %d, completed %d, floors %d, kills %d, '
        .. 'hearths %d, beacons %d, chests %d, tributes %d, goblins %d, obols %d, deaths %d, resets %d, exits %d, '
        .. 'Rosie trips %d, pickups %d, mean Kurast->portal %.0f s, rotation casts %d dashes %d interrupts %d, chaos %d',
        label, seconds, os.clock() - t0, W.opens, W.completed, W.floors_entered, W.kills, W.hearths, W.beacons,
        W.chests, W.tributes_used, W.goblins, W.obols_picked, W.deaths, W.resets, #W.exits,
        h.count(h.tp_log, function(r) return r.ctx == 'Rosie' end), h.pickups or 0,
        #W.kurast_times > 0 and kt / #W.kurast_times or 0,
        h.rotation.casts, h.rotation.dashes, h.rotation.interrupts, h.chaos and #h.chaos.log or 0))
    -- Teleport casts per transition: the casts since the previous arrival,
    -- grouped by origin, destination and caster ('uc' = any Undercity floor).
    local per, prev_t, ci = {}, -math.huge, 1
    for _, a in ipairs(h.arrivals) do
        local casts, who, from = 0, nil, nil
        while h.tp_log[ci] and h.tp_log[ci].t <= a.t do
            local c = h.tp_log[ci]
            if c.t > prev_t then
                casts = casts + 1
                who = who and (who:find(c.ctx, 1, true) and who or (who .. '+' .. c.ctx)) or c.ctx
                from = from or (c.from:match('^uc_') and 'uc' or c.from)
            end
            ci = ci + 1
        end
        if casts > 0 then
            local key = string.format('%s->%s by %s', from, a.place:match('^uc_') and 'uc' or a.place, who)
            per[key] = per[key] or {}
            per[key][casts] = (per[key][casts] or 0) + 1
            S.per_transition = S.per_transition or {}
            S.per_transition[key] = S.per_transition[key] or {}
            S.per_transition[key][casts] = (S.per_transition[key][casts] or 0) + 1
        end
        prev_t = a.t
    end
    local keys = {}
    for k in pairs(per) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        local hist = {}
        for n = 1, 20 do if per[k][n] then hist[#hist + 1] = string.format('%dx%d', n, per[k][n]) end end
        parts[#parts + 1] = k .. ' [' .. table.concat(hist, ' ') .. ']'
    end
    print('   casts per transition (casts x transitions): ' .. table.concat(parts, '; '))
    local fb, fo = W.floor_stats.beacon, W.floor_stats.open
    print(string.format('   floors left: %d open-exit floors, mean %.0f s; %d beacon floors, mean %.0f s (%.0f s of it '
        .. 'after the exit opened)', fo.n, fo.n > 0 and fo.sum / fo.n or 0, fb.n, fb.n > 0 and fb.sum / fb.n or 0,
        fb.n > 0 and (fb.after_open or 0) / fb.n or 0))
    for _, k in ipairs({'beacon', 'open'}) do
        S.floor_stats = S.floor_stats or {beacon = {n = 0, sum = 0, after_open = 0}, open = {n = 0, sum = 0, after_open = 0}}
        local a, b = S.floor_stats[k], W.floor_stats[k]
        a.n, a.sum, a.after_open = a.n + b.n, a.sum + b.sum, a.after_open + (b.after_open or 0)
    end
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
        local rec = {seed = seed, t = hit.t, kind = hit.kind, label = label,
            detail = hit.detail .. (hit.scene and (' {' .. hit.scene .. '}') or '')}
        if ctx.cast then
            rec.detail = rec.detail .. string.format(' {cast by %s task=%s at t=%.1f}', ctx.cast.ctx, ctx.cast.task, ctx.cast.t)
        end
        local r = hit.kind ~= 'INTERNAL' and classify(rec, ctx) or nil
        rec.rule = r
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
                print(string.format('%.1f {teleport_to_waypoint 0x%X from %s: ctx %s, WonderCity task %s}', c.t, c.sno,
                    c.from, c.ctx, c.task))
            end
        end
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

local function trips_from_uc(h)
    local n = 0
    for _, c in ipairs(h.tp_log) do if c.ctx == 'Rosie' and c.from:match('^uc_') then n = n + 1 end end
    return n
end
if ENV_SEEDS and ENV_SEEDS ~= '' then
    for _, seed in ipairs(SEEDS) do
        local passed, err = xpcall(function() sweep_seed(seed) end, debug.traceback)
        if not passed then S.crashes[#S.crashes + 1] = 'seed ' .. seed .. ': ' .. tostring(err) end
    end
elseif os.getenv('QQT_SWEEP_FINDINGS') ~= '1' then
    -- Harness check: a chaos 'reload' keeps the menu values set in the
    -- session (keep_session_widgets), and the scripted world works: the
    -- brazier is out of the actor list at the Kurast waypoint (walk_kurast
    -- walks the recorded path), the Undercity opens and is entered.
    local passed, err = xpcall(function()
        local h, W = start(7, {chaos = true, rate = 1e-9, exit_mode = 1, distance = 15, tribute = 'use',
            all_plugins = false, start = 'kurast'})
        local seen = {}
        h.run(1, function() seen[h.wc_task()] = true end)
        ok(h.pos:dist_to_ignore_z(h.brazier.pos) > 40, 'the brazier is out of range at the Kurast waypoint')
        h.chaos_inject('reload', {dir = WC})
        h.chaos_inject('reload', {dir = 'Rosie'})
        local gui = h.mod(WC, 'gui').elements
        ok(gui.main_toggle:get() == true, 'reloaded WonderCity keeps its main toggle')
        ok(gui.exit_mode:get() == 1 and gui.tribute_priority_1:get() == 1, 'reloaded WonderCity keeps exit mode and tribute')
        ok(h.mod('Rosie', 'rosie.private.pickup.gui').elements.general.distance_slider:get() == 15,
            'reloaded Rosie keeps the pickup distance')
        h.run(60, function() W.tick(); seen[h.wc_task()] = true end)
        ok(seen.walk_kurast and seen.enter_undercity, 'walk_kurast then enter_undercity ran')
        ok(W.tributes_used == 1, 'the selected tribute was used at the brazier')
        ok(W.entries == 1 and W.run and W.run.first_floor_t, 'the Undercity was entered\n' .. h.tail(20))
        h.assert_clean('harness check')
        local plain = J.new({dirs = {WC}, place = 'kurast'})
        plain.mod(WC, 'gui').elements.main_toggle:set(true)
        plain.reload(WC)
        ok(plain.mod(WC, 'gui').elements.main_toggle:get() == false,
            'the host h.reload alone still loads the defaults (older tests)')
        print('PASS S3 harness check: Kurast walk, brazier, tribute, entry; a chaos reload keeps the session menu values')
    end, debug.traceback)
    if not passed then S.crashes[#S.crashes + 1] = 'harness check: ' .. tostring(err) end
    -- D1 scripted chaos (fixed times): an elite pack, a full bag inside the
    -- Undercity (Rosie trip, the run resumes), a death, reloads of WonderCity,
    -- Rosie and Batmobile, a Mythic, a loading screen, a wall; exit mode
    -- Reset, tributes used, pickup 15 m.
    passed, err = xpcall(function()
        local h, W = sweep_seed(301, {label = '(D1 scripted)', exit_mode = 0, distance = 15, tribute = 'use',
            all_plugins = false, start = 'kurast', schedule = {
                {t = 1060, kind = 'elite'}, {t = 1100, kind = 'bag_full'}, {t = 1200, kind = 'death'},
                {t = 1260, kind = 'reload', dir = WC}, {t = 1330, kind = 'drop', mythic = true},
                {t = 1400, kind = 'reload', dir = 'Rosie'}, {t = 1450, kind = 'limbo', seconds = 4},
                {t = 1500, kind = 'obstacle'}, {t = 1600, kind = 'bag_full'}, {t = 1700, kind = 'reload', dir = 'Batmobile'}}},
            900)
        ok(W.completed >= 1 and W.opens >= 2, string.format('D1: a run completed and the next opened, got %d/%d',
            W.completed, W.opens))
        ok(trips_from_uc(h) >= 1, 'D1: a Rosie trip out of the Undercity, got ' .. trips_from_uc(h))
        ok(h.logged('resuming the run') >= 1, 'D1: the trip returns into the same Undercity run')
        ok(W.deaths >= 1 and not h.dead, 'D1: the death was revived')
        ok(W.resets >= 1, 'D1: the exit by dungeon reset')
        print(string.format('  D1: %d Rosie trip(s) out of the Undercity, %d resumed run(s), %d tribute(s)',
            trips_from_uc(h), h.logged('resuming the run'), W.tributes_used))
    end, debug.traceback)
    if not passed then S.crashes[#S.crashes + 1] = 'D1: ' .. tostring(err) end
    -- D2 seeded random chaos, exit mode Teleport (the whole Kurast walk after
    -- every run), no tribute selected (the 2 s fallback), pickup 8 m.
    passed, err = xpcall(function()
        local _, W = sweep_seed(302, {label = '(D2 seeded)', exit_mode = 1, distance = 8, tribute = 'none',
            all_plugins = false, rate = 1.5}, 600)
        ok(W.completed >= 1, 'D2: at least 1 Undercity run completed, got ' .. W.completed)
    end, debug.traceback)
    if not passed then S.crashes[#S.crashes + 1] = 'D2: ' .. tostring(err) end
end

-- Minimal repros of this sweep's findings (QQT_SWEEP_FINDINGS=1). Each
-- prints REPRODUCED / not reproduced; QQT_SWEEP_STRICT=1 fails on a
-- reproduced finding, so the fixing session gets a test that fails on the
-- old code and passes on the fix. All run without chaos unless noted.
local FINDINGS = {
    {id = 'F1', rule = 'WC-pad-thrash-beacon', seed = 3, seconds = 300, title = 'Grand Beacon floor, exit closed: '
        .. 'the warp pad alone drives the portal task (portal.lua:123-127); it walks to the pad, the explorer walks '
        .. 'away, 38 switches in 15 s until the 12 s no-progress set-aside',
        o = {chaos = false, beacon_share = 1, floors = 2}},
    {id = 'F2', rule = 'SLOW-beacon-floor', seed = 3, seconds = 300, title = 'after the Grand Beacon is lit the floor '
        .. 'exit (found and walked to before) is forgotten: nothing goes back to it, the explorer wanders until it '
        .. 'passes within check_distance again (exit open at t=1100, floor left after t=1266)',
        o = {chaos = false, beacon_share = 1, floors = 2}},
    {id = 'F3', rule = 'ROSIE-auto-trip-in-boss-fight', seed = 5, seconds = 200, title = "Rosie's automatic Town "
        .. 'Portal 2.3 s after the bag fills, 1.5 m from the live district boss (WonderCity only defers its own request)',
        o = {chaos = false, bag_at_boss = true}},
    {id = 'F4', rule = 'WC-exit-leaves-reward-loot', seed = 2, seconds = 300, title = "with Rosie's shipped 2 m pickup "
        .. 'distance the reward chest / boss loot 2.5-5 m around the chest stays behind at the exit',
        o = {chaos = false, distance = 2}},
    {id = 'F5', rule = 'WC-exit-after-death-leaves-reward', seed = 2, seconds = 260, title = 'a death next to the '
        .. 'opened reward chest: WonderCity confirms the chest from the checkpoint and exits, the chest loot stays '
        .. '104-107 m away', o = {chaos = false, distance = 15, death_after_chest = true, chest_obols = 0}},
    {id = 'F6', rule = 'WC-obols-beacon-thrash', seed = 12, seconds = 480, title = 'an obol 2.2 m from a lit Grand '
        .. 'Beacon: loot_obols excludes it only while the beacon is the closest enticement within 20 m of the PLAYER, '
        .. 'so it flips at the 20 m boundary (53 switches in 96 s) and is never taken (seeded chaos, default config)',
        o = {}},
    {id = 'F7', rule = 'WC-exit-cast-drop', seed = 2, seconds = 1800, title = "a Mythic dropped 0.3 s before the end "
        .. "of WonderCity's exit teleport channel, 2.8 m away (beyond the shipped 2 m pickup distance), is left for "
        .. 'good: nothing re-checks the ground after the exit cast (seeded chaos, default config of seed 2)',
        o = {}},
    {id = 'F8', rule = 'WC-reward-forgotten-after-trip', seed = 2, seconds = 300, title = 'the bag fills 9 s after the '
        .. "reward chest opens (inside WonderCity's 10 s exit delay): Rosie's trip is not a resumable Alfred trip, the "
        .. 'return is a new run, and WonderCity stands in finish_undercity until the 600 s run timeout',
        o = {chaos = false, distance = 15, bag_after_chest = 9}},
    {id = 'F9', rule = 'WC-exit-recast-rotation', seed = 9, seconds = 2560, title = 'WonderCity casts the exit '
        .. 'teleport with an elite pack 8 m away; the rotation\'s evade breaks the channel and exit_undercity re-casts '
        .. 'every 5 s (3 casts at t=3540-3550; seeded chaos, default config of seed 9)', o = {}},
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

print(string.format('S3 sweep: %d seed(s), %.1f emulated hours, %d/%d Undercity runs completed, %d invariant hit(s), '
    .. '%d unclassified, %d crash(es)', S.seeds, S.emulated / 3600, S.runs, S.opened, #S.hits, #S.unclassified, #S.crashes))
if S.per_transition then
    local keys = {}
    for k in pairs(S.per_transition) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local hist = {}
        for n = 1, 20 do if S.per_transition[k][n] then hist[#hist + 1] = string.format('%dx%d', n, S.per_transition[k][n]) end end
        print('  casts per transition ' .. k .. ': ' .. table.concat(hist, ' '))
    end
end
if S.floor_stats then
    local fb, fo = S.floor_stats.beacon, S.floor_stats.open
    print(string.format('  floors left: %d open-exit floors, mean %.0f s; %d beacon floors, mean %.0f s (%.0f s of it after '
        .. 'the exit opened)', fo.n, fo.n > 0 and fo.sum / fo.n or 0, fb.n, fb.n > 0 and fb.sum / fb.n or 0,
        fb.n > 0 and fb.after_open / fb.n or 0))
end
local ids = {}
for id in pairs(S.by_rule) do ids[#ids + 1] = id end
table.sort(ids)
for _, id in ipairs(ids) do
    local b = S.by_rule[id]
    local seeds = {}
    for s in pairs(b.seeds) do seeds[#seeds + 1] = s end
    table.sort(seeds)
    print(string.format('  %-30s %-8s %3d hit(s), seeds %s; first: seed %d t=%.1f %s', id, b.rule.class, b.n,
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
if #failures > 0 then error('S3 sweep: ' .. table.concat(failures, '; ')) end
print(string.format('PASS: S3 Undercity sweep, %d checks', checks))

