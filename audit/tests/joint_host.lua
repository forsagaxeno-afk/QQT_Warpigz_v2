-- Joint QQT host emulation for audit/tests/test_joint_suite.lua (loaded with
-- dofile). It loads ALL NINE plugins together the way QQT does:
--   * each plugin folder's main.lua runs with a require() that resolves
--     modules from THAT folder and caches them per plugin (package.loaded per
--     plugin context);
--   * every plugin shares ONE global table, so BatmobilePlugin, WarPigsPlugin
--     ... are visible to everyone;
--   * require() resolves in the context of the plugin whose callback the host
--     is currently running. A require() executed by code of plugin B while
--     plugin A's callback runs would resolve A's module in QQT; the host
--     records it as a caller-context violation (with the stack) and the joint
--     test fails on it. The same applies to package.* reads.
-- Callbacks run in alphabetical folder order: on_update, then on_render, then
-- on_render_menu. A callback error is logged like QQT does and the plugin
-- keeps running; the test asserts that no error happened.
-- The world, the player, AlfredTheButler, LooteerV3, the native warplan /
-- quest_reward / pathfinder / orbwalker APIs are behaviour-level mocks.
-- opts.rosie loads the REAL Rosie folder (Rosie publishes RosiePlugin plus the
-- AlfredTheButlerPlugin / PLUGIN_alfred_the_butler / LooteerPlugin adapters)
-- instead of the Alfred and Looter mocks; opts.dirs loads only those folders.
-- Rosie mode adds the host surface Rosie needs: Temis vendors, vendor screens,
-- salvage/sell/repair/stash commands, inventory gear (h.gear), ground items
-- (h.drop), chat/inventory probes and the town portal a waypoint teleport
-- out of a non-town place leaves in Temis (back to the exact spot).
-- Round 4: widgets load persisted values (opts.persisted, by widget hash);
-- use_item / confirm_sigil_notification model the Infernal Compass at the
-- Caldeum gate (h.items, h.sigil_confirms, the Horde portal); every arrival
-- is recorded (h.arrivals) and may run the place's on_arrive; h.setup_horde
-- scripts an Infernal Horde (waves, locked door, Council, chest room).
-- Sweep tooling (QQT_Warpigz_v3 after 3.3.6; details at J.install_invariants,
-- J.install_rotation and J.install_chaos at the end of this file), all opt-in:
--   opts.invariants = true | {KIND = false | {thresholds}}  read-only monitors
--     TELEPORT / LEFT_DROP / STALL / SPAM / LOOP; h.invariant_report(),
--     h.assert_invariants(label, overrides). QQT_INVARIANTS=1 turns them on
--     for every host (QQT_INVARIANTS_LOG=<file> appends each hit, tab
--     separated, with the test file and its lines on the stack).
--   opts.rotation = true | {...}  a Universal Rotation stand-in (casts at
--     enemies within 12 m, seeded 3-6 m dashes/evades that can break a channel).
--   opts.chaos = {seed = N, rate = per_minute, kinds = {...}, only = {n...}}
--     seeded death / drop (Mythic, also inside a travel channel) / Limbo /
--     plugin reload / full bag / lazy stash / elite pack / path obstacle.
--   opts.virtual_os_clock (default with chaos): deterministic os.clock().
--   opts.persist_widgets: a reloaded plugin's keyed widgets keep their values
--     (QQT's menu store), instead of loading their defaults again.
--   opts.target_range: target_selector.get_near_target_list(pos, range)
--     returns only the enemies within `range` of `pos`.
local ROOT = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local J = {}

J.DIRS = {'ArkhamAsylum', 'Batmobile', 'HelltideRevamped', 'HordeDev',
    'Reaper', 'SilentRaven', 'WarPigs', 'WarPug', 'WonderCity'}
-- Documented cross-plugin exports (plugin READMEs / main.lua).
J.EXPORTS = {
    ArkhamAsylumPlugin = 'ArkhamAsylum', BatmobilePlugin = 'Batmobile',
    HelltideRevampedPlugin = 'HelltideRevamped', InfernalHordesPlugin = 'HordeDev',
    ReaperPlugin = 'Reaper', SilentRavenPlugin = 'SilentRaven',
    PLUGIN_silent_raven = 'SilentRaven', WarPigsPlugin = 'WarPigs',
    WarPugPlugin = 'WarPug', WonderCityPlugin = 'WonderCity',
}
-- Pre-existing upstream globals (luacheck W111 since the original archive):
-- class filters and explorer state written lazily. Reported, not failures.
J.UPSTREAM_GLOBALS = {get_color = true, filter_items = true, exploration_mode = true,
    current_circle_target = true}
J.TEMIS_WP, J.KURAST_WP = 0x1CE51E, 0x1EAACC
-- Waypoint SNO -> place: Temis, Kurast, HordeDev's Library (Caldeum) and
-- Cerrigar, and HelltideRevamped's helltide zones (data/enums.lua).
J.WAYPOINTS = {[J.TEMIS_WP] = 'temis', [J.KURAST_WP] = 'kurast', [0x10D63D] = 'caldeum', [0x76D58] = 'cerrigar',
    [0xACE9B] = 'frac', [0x27E01] = 'scos', [0xDEAFC] = 'kehj', [0x9346B] = 'helltide', [0x462E2] = 'step'}
J.HELLTIDE_BUFF = 1066539
J.TREE = {2596.38, -495.79}
J.ROSIE_EXPORTS = {RosiePlugin = 'Rosie', AlfredTheButlerPlugin = 'Rosie', PLUGIN_alfred_the_butler = 'Rosie',
    LooteerPlugin = 'Rosie'}

local function copy(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end
J.copy = copy

function J.new(opts)
    opts = opts or {}
    local h = {now = 1000, log = {}, errors = {}, violations = {}, missing = {}, global_writes = {},
        file_writes = {}, plugins = {}, by_dir = {}, frames = 0,
        waypoints = {}, warplans = {}, moves = {}, clears = {}, orb_log = {}, interactions = {},
        vendors = {}, clicks = {}, keys = {}, revives = 0, resets = 0, leaves = 0, boss_tps = {},
        pit_opens = 0, quests = {}, minute = opts.minute or 30, aether = 0, cinders = 0, arrivals = {},
        floor_loot = false, dead = false, buffs = {}, events = {}, speed = opts.speed or 7}
    math.randomseed(opts.seed or 7)
    local rosie = opts.rosie == true
    h.rosie = rosie
    local dirs = {}
    for _, dir in ipairs(opts.dirs or J.DIRS) do dirs[#dirs + 1] = dir end
    if rosie then
        local present = false
        for _, dir in ipairs(dirs) do if dir == 'Rosie' then present = true end end
        if not present then dirs[#dirs + 1] = 'Rosie' end
        table.sort(dirs)
    end
    h.dirs = dirs
    h.exports = {}
    for export, dir in pairs(J.EXPORTS) do
        for _, d in ipairs(dirs) do if d == dir then h.exports[export] = dir end end
    end
    if rosie then for export, dir in pairs(J.ROSIE_EXPORTS) do h.exports[export] = dir end end
    local context = nil   -- plugin record whose callback is running
    local loading = nil   -- plugin record whose main.lua is running

    -- ── vectors ─────────────────────────────────────────────────────────────
    local Vec = {}; Vec.__index = Vec
    function Vec.new(_, x, y, z) return setmetatable({_x = x or 0, _y = y or 0, _z = z or 0}, Vec) end
    function Vec:x() return self._x end
    function Vec:y() return self._y end
    function Vec:z() return self._z end
    function Vec:dist_to(o)
        local dx, dy, dz = self._x - o:x(), self._y - o:y(), self._z - o:z()
        return math.sqrt(dx * dx + dy * dy + dz * dz)
    end
    function Vec:dist_to_ignore_z(o)
        local dx, dy = self._x - o:x(), self._y - o:y()
        return math.sqrt(dx * dx + dy * dy)
    end
    function Vec:squared_dist_to_ignore_z(o)
        local dx, dy = self._x - o:x(), self._y - o:y()
        return dx * dx + dy * dy
    end
    function Vec:is_zero() return self._x == 0 and self._y == 0 and self._z == 0 end
    function Vec:get_extended(to, d)
        local dx, dy, dz = to:x() - self._x, to:y() - self._y, to:z() - self._z
        local len = math.sqrt(dx * dx + dy * dy + dz * dz)
        if len == 0 then return Vec:new(self._x, self._y, self._z) end
        return Vec:new(self._x + dx / len * d, self._y + dy / len * d, self._z + dz / len * d)
    end
    local function v(x, y, z) return Vec:new(x, y, z or 0) end
    h.v, h.Vec = v, Vec
    local Vec2 = {}; Vec2.__index = Vec2
    function Vec2.new(_, x, y) return setmetatable({_x = x or 0, _y = y or 0}, Vec2) end
    function Vec2:x() return self._x end
    function Vec2:y() return self._y end

    -- ── places ──────────────────────────────────────────────────────────────
    local P = {
        temis = {name = 'Sanctuary_Eastern_Continent', zone = 'Skov_Temis', id = 1, town = true,
            spawn = v(2552, -466), box = {2440, 2700, -620, -360}},
        kurast = {name = 'Sanctuary_Eastern_Continent', zone = 'Naha_Kurast', id = 1, town = true,
            spawn = v(-1480, -240), box = {-1700, -1260, -460, -20}},
        caldeum = {name = 'Sanctuary_Eastern_Continent', zone = 'Kehj_Caldeum', id = 1, town = true,
            spawn = v(-1720, -580), box = {-1900, -1540, -760, -400}},
        cerrigar = {name = 'Sanctuary_Eastern_Continent', zone = 'Scos_Cerrigar', id = 1, town = true,
            spawn = v(-1340, 60), box = {-1500, -1180, -100, 220}},
        pit = {name = 'PIT_Joint_Floor', zone = 'PIT_Subzone', id = 41, town = false,
            spawn = v(0, 0), box = {-30, 230, -30, 30}},
        undercity = {name = 'X1_Undercity_Joint', zone = 'X1_Undercity_SnakeTemple_02', id = 77, town = false,
            spawn = v(0, 0), box = {-60, 260, -60, 60}},
        bsk = {name = 'S05_BSK_Prototype02', zone = 'S05_BSK_Prototype02', id = 5, town = false,
            spawn = v(0, 0), box = {-80, 80, -80, 80}},
        helltide = {name = 'Sanctuary_Eastern_Continent', zone = 'Hawe_Verge', id = 1, town = false,
            spawn = v(-600, 300), box = {-900, -300, 0, 600}, helltide = true},
        limbo = {name = 'Limbo', zone = '[sno none]', id = 0, town = false, spawn = v(0, 0)},
        -- Andariel's lair: Reaper's recorded paths run from (42,86)/(86,40)
        -- to the altar near (-10,-9).
        lair = {name = 'Boss_WT4_Andariel', zone = 'Boss_WT4_Andariel', id = 90, town = false,
            spawn = v(42, 85.8), box = {-30, 100, -30, 100}},
    }
    -- HelltideRevamped's helltide zones (data/enums.lua); a scenario marks
    -- the active one with `helltide = true` (the player then has the buff).
    for key, zone in pairs({frac = 'Frac_Tundra_S', scos = 'Scos_Coast', kehj = 'Kehj_Oasis', step = 'Step_South'}) do
        P[key] = {name = 'Sanctuary_Eastern_Continent', zone = zone, id = 1, town = false,
            spawn = v(300, 300), box = {0, 600, 0, 600}}
    end
    for key, place in pairs(P) do place.key, place.actors = key, {} end
    h.P = P
    h.place, h.pos = P[opts.place or 'temis'], nil
    h.pos = opts.pos or h.place.spawn
    h.waypoint_places = copy(J.WAYPOINTS)

    -- ── actors ──────────────────────────────────────────────────────────────
    local Actor = {}; Actor.__index = Actor
    local next_id = 100
    function Actor:get_skin_name() return self.skin end
    function Actor:get_position() return self.pos end
    function Actor:is_interactable() return self.interactable ~= false end
    function Actor:get_current_health() return self.health or 100 end
    function Actor:get_max_health() return self.max_health or 100 end
    function Actor:is_dead() return (self.health or 100) <= 0 end
    function Actor:is_enemy() return self.enemy == true end
    function Actor:is_boss() return self.boss == true end
    function Actor:is_elite() return self.elite == true end
    function Actor:is_champion() return false end
    function Actor:is_untargetable() return false end
    function Actor:is_immune() return false end
    function Actor:has_affix() return false end
    function Actor:get_affixes() return {} end
    function Actor:get_buffs() return {} end
    function Actor:get_id() return self.id end
    function Actor:get_sno_id() return self.sno or 0 end
    function Actor:get_display_name() return self.display or self.skin end
    function h.actor(place, skin, x, y, fields)
        next_id = next_id + 1
        local a = setmetatable({skin = skin, pos = v(x, y), id = next_id}, Actor)
        for k, val in pairs(fields or {}) do a[k] = val end
        local list = (type(place) == 'table' and place or P[place]).actors
        list[#list + 1] = a
        return a
    end
    function h.remove_actor(a)
        for _, place in pairs(P) do
            for i = #place.actors, 1, -1 do if place.actors[i] == a then table.remove(place.actors, i) end end
        end
    end
    local function actors_here() return h.place.actors end

    -- Temis landmarks (positions from the plugins' own data / live logs).
    h.table_actor = h.actor('temis', 'Warplans_Vendor', 2566, -452)
    h.tyrael = h.actor('temis', 'NPC_QST_X2_Tyrael_NonCombat', 2574, -484)
    h.raven = h.actor('temis', 'temis_bounty_meta_raven_npc', J.TREE[1], J.TREE[2])
    h.pit_tower = h.actor('temis', 'TWN_Kehj_IronWolves_PitKey_Crafter', 2530, -440)
    h.pit_tower.on_interact = function() h.vendor_screen = true end
    h.brazier = h.actor('kurast', 'Aubrie_Test_Undercity_Crafter', -1460, -220)
    h.horde_gate = h.actor('caldeum', 'QST_Caldeum_GatesToHell_Seal', -1712, -590)
    -- Turning the plan in at Tyrael completes the turn-in quest.
    h.tyrael.on_interact = function()
        h.at(0.5, function()
            local keep = {}
            for _, q in ipairs(h.quests) do
                if (type(q) == 'table' and q.name or q) ~= 'WarPlans_QST_TurnIn_Rewards' then keep[#keep + 1] = q end
            end
            h.quests = keep
        end)
    end

    -- Boss lair script: the altar summons the boss; its death drops the chest;
    -- opening the chest empties it. `on_kill` runs when the boss dies.
    -- Round 5: o.altar_stays keeps the altar (no longer interactable) after
    -- the summon and spawns the boss next to it, as in the game; Reaper then
    -- fights at the altar and finishes its run (with opts.virtual_os_time for
    -- its os.time chest phases). Default: the round-2 script (altar removed).
    function h.setup_lair(on_kill, o)
        o = o or {}
        local lair = P.lair
        h.altar = h.actor(lair, 'Boss_WT4_Andariel', -12, -11)
        h.altar.on_interact = function()
            if o.altar_stays then
                if h.altar.summoned then return end
                h.altar.summoned, h.altar.interactable = true, false
            end
            h.at(1.0, function()
                if not o.altar_stays then h.remove_actor(h.altar) end
                local bx, by = -15, -14
                if o.altar_stays then bx, by = -12, -13 end
                h.boss = h.actor(lair, 'Boss_WT4_Andariel_Boss', bx, by, {enemy = true, boss = true, health = 300})
                h.boss.on_death = function()
                    h.boss_killed_at = h.now
                    h.boss_chest = h.actor(lair, 'EGB_Chest_Andariel', -13, -16)
                    h.boss_chest.on_interact = function()
                        h.at(1.5, function() h.remove_actor(h.boss_chest); h.chest_opened_at = h.now end)
                    end
                    if on_kill then on_kill(h) end
                end
            end)
        end
    end

    -- Round 5: the Undercity entry at the Kurast brazier (WonderCity's
    -- tasks/enter_undercity.lua): interacting opens the tribute vendor; the
    -- ACCEPT click (WonderCity logs 'left-click ACCEPT') closes it and spawns
    -- Portal_Dungeon_Undercity next to the brazier; the portal enters the
    -- Undercity. Opt-in (older scenarios keep the inert brazier).
    function h.setup_undercity()
        h.brazier.on_interact = function() h.vendor_screen = true end
        local accepts = 0
        h.on_click = function()
            if not h.vendor_screen then return end
            local n = h.logged('left-click ACCEPT')
            if n <= accepts then return end
            accepts = n
            h.vendor_screen = false
            local portal = h.actor('kurast', 'Portal_Dungeon_Undercity', -1455, -215)
            portal.on_interact = function()
                h.remove_actor(portal)
                h.travel_to('undercity', 0.5, 'undercity_portal')
            end
        end
    end

    -- Infernal Horde script (HordeDev's actor names, data/enums.lua,
    -- data/pylons.lua, tasks/horde.lua): every arrival in the BSK world is a
    -- new horde. Each wave starts with an offering pylon; interacting spawns
    -- its monsters; the last kill of a wave grants `aether_per_wave`. After
    -- `waves` waves (War Plan hordes: 6) the locked boss door appears; opening
    -- it shows the Council pylon; the Council boss's death ends the War Plan
    -- objective (InfernalHordes quest -> TurnIn quest unless `quest_done` is
    -- false) and, unless `chest_room` is false, reveals the chest room
    -- (stash, greater-affix / materials chests at 10 aether, gold chest takes
    -- the rest). `stash` defaults to `chest_room`. Aether starts at 0 in
    -- every new horde; Alfred's return portal re-enters the same horde.
    -- `next_quest` (round 5) is the War Plan step that replaces the Horde
    -- quest at the Council's death (default: the TurnIn quest).
    function h.setup_horde(o)
        o = o or {}
        local bsk = P.bsk
        local A = {waves = o.waves or 6, per_wave = o.aether_per_wave or 5, monsters = o.monsters or 3,
            chest_room = o.chest_room ~= false, runs = 0, wave = 0, events = {}, opened = {}}
        if o.stash == nil then A.stash = A.chest_room else A.stash = o.stash end
        h.arena = A
        local function event(what)
            A.events[#A.events + 1] = {t = h.now, what = what, run = A.runs}
        end
        A.event = event
        -- Scheduled steps of a horde the player already left do nothing.
        local function later(delay, fn)
            local run = A.runs
            h.at(delay, function() if A.runs == run then fn() end end)
        end
        local spawn_pylon, spawn_wave, spawn_door, spawn_council, boss_dead
        spawn_pylon = function()
            local p = h.actor(bsk, 'BSK_Pyl_ChaoticOffering', 14, 10)
            p.on_interact = function()
                if p.used then return end
                p.used, p.interactable = true, false
                event('pylon ' .. (A.wave + 1))
                later(0.5, function() h.remove_actor(p); spawn_wave() end)
            end
        end
        spawn_wave = function()
            A.wave = A.wave + 1
            event('wave ' .. A.wave)
            local alive = A.monsters
            for i = 1, A.monsters do
                local ang = (i / A.monsters) * 2 * math.pi
                local m = h.actor(bsk, 'BSK_Wave_Monster', 9 + 6 * math.cos(ang), 9 + 6 * math.sin(ang),
                    {enemy = true, health = 100})
                m.on_death = function()
                    h.remove_actor(m)
                    alive = alive - 1
                    if alive > 0 then return end
                    h.aether = h.aether + A.per_wave
                    event('wave ' .. A.wave .. ' cleared')
                    if A.wave < A.waves then later(1.0, spawn_pylon) else later(1.0, spawn_door) end
                end
            end
        end
        spawn_door = function()
            event('locked door')
            local icon = h.actor(bsk, 'BSK_MapIcon_LockedDoor', -18, -18)
            local door = h.actor(bsk, 'Hell_Fort_BSK_Door_A_01_Dyn', -20, -20)
            door.on_interact = function()
                if door.opened then return end
                door.opened = true
                event('door opened')
                h.remove_actor(icon); h.remove_actor(door)
                later(0.5, spawn_council)
            end
        end
        spawn_council = function()
            local p = h.actor(bsk, 'BSK_PylChoiceGizmo_SelectCouncil', -30, -30)
            p.on_interact = function()
                if p.used then return end
                p.used, p.interactable = true, false
                event('council pylon')
                later(1.0, function()
                    h.remove_actor(p)
                    local boss = h.actor(bsk, 'BSK_Council_Boss', -34, -34,
                        {enemy = true, boss = true, health = o.boss_health or 300})
                    boss.on_death = function() h.remove_actor(boss); boss_dead() end
                end)
            end
        end
        boss_dead = function()
            event('council dead')
            A.council_dead_at = h.now
            if o.quest_done ~= false then
                local keep = {}
                for _, q in ipairs(h.quests) do
                    local name = type(q) == 'table' and q.name or q
                    if not tostring(name):find('WarPlans_QST_InfernalHordes', 1, true) then keep[#keep + 1] = q end
                end
                keep[#keep + 1] = o.next_quest or 'WarPlans_QST_TurnIn_Rewards'
                h.quests = keep
            end
            if A.stash then h.actor(bsk, 'Stash', -40, -38) end
            if not A.chest_room then return end
            local function chest(skin, x, y, cost, once)
                local c = h.actor(bsk, skin, x, y)
                c.on_interact = function()
                    local price = cost or h.aether
                    if price <= 0 or h.aether < price then return end
                    h.aether = h.aether - price
                    A.opened[#A.opened + 1] = skin
                    event('opened ' .. skin)
                    if once then c.interactable = false end
                end
            end
            chest('BSK_UniqueOpChest_GreaterAffix', -38, -42, 10, true)
            chest('BSK_UniqueOpChest_Materials', -34, -42, 10, false)
            chest('BSK_UniqueOpChest_Gold', -36, -45, nil, false)
        end
        -- Round 5: `resume_at` puts the FIRST horde mid-way, as after a QQT
        -- reload inside it: a wave number N (N waves cleared, their aether
        -- earned, the next offering or the door follows), 'door' (all waves
        -- cleared, the locked door is up) or 'council_dead' (the Council has
        -- just died: quest swap, stash and chest room as above).
        local resume = o.resume_at
        bsk.on_arrive = function(_, trip)
            -- Alfred's return portal goes back into the same horde.
            if trip and (trip.why == 'alfred_return' or trip.why == 'town_portal') then return end
            bsk.actors = {}
            A.runs, A.wave, A.council_dead_at = A.runs + 1, 0, nil
            event('arrived in the Horde')
            h.aether = 0 -- aether is a per-horde currency
            local r = resume
            resume = nil
            if r == nil then later(1.0, spawn_pylon); return end
            A.wave = type(r) == 'number' and math.min(r, A.waves) or A.waves
            h.aether = A.wave * A.per_wave
            event('resumed at ' .. tostring(r))
            if r == 'council_dead' then boss_dead()
            elseif r == 'door' or A.wave >= A.waves then spawn_door()
            else later(1.0, spawn_pylon) end
        end
        if h.place == bsk then bsk.on_arrive(h) end
        return A
    end

    -- ── plugin records / code ownership ─────────────────────────────────────
    local prefixes = {}
    for _, dir in ipairs(dirs) do
        local rec = {name = dir, dir = ROOT .. '/' .. dir .. '/', loaded = {}, update = {}, render = {}, menu = {}}
        h.plugins[#h.plugins + 1] = rec
        h.by_dir[dir] = rec
        prefixes[#prefixes + 1] = {'@' .. rec.dir, rec}
    end
    -- Closed-source companions run in their own (folder-less) contexts.
    h.alfred_ctx = {name = 'AlfredTheButler', pseudo = true, loaded = {}}
    h.looter_ctx = {name = 'LooteerV3', pseudo = true, loaded = {}}
    local function plugin_of_source(src)
        if type(src) ~= 'string' then return nil end
        for _, entry in ipairs(prefixes) do
            if src:sub(1, #entry[1]) == entry[1] then return entry[2] end
        end
        return nil
    end
    -- First Lua frame at or above `level` (C frames such as pcall skipped).
    local function code_owner(level)
        level = level + 1
        while true do
            local info = debug.getinfo(level, 'S')
            if not info then return nil end
            if info.what ~= 'C' then return plugin_of_source(info.source), info.source end
            level = level + 1
        end
    end
    h.code_owner = code_owner
    h.plugin_of_source = plugin_of_source -- sweep: SPAM/LOOP attribute console lines
    local function violation(kind, detail, owner)
        h.violations[#h.violations + 1] = {kind = kind, detail = detail, t = h.now,
            context = context and context.name or (loading and loading.name) or '-',
            owner = owner and owner.name or '-', trace = debug.traceback('', 3)}
    end

    -- ── shared global table ─────────────────────────────────────────────────
    local BASE = {}
    for _, name in ipairs({'assert', 'error', 'ipairs', 'next', 'pairs', 'pcall', 'xpcall', 'rawequal', 'rawget',
        'rawset', 'select', 'setmetatable', 'getmetatable', 'tonumber', 'tostring', 'type', 'load',
        'loadstring', 'collectgarbage', '_VERSION', 'unpack', 'bit', 'jit', 'setfenv', 'getfenv', 'debug',
        'coroutine'}) do
        BASE[name] = rawget(_G, name)
    end
    -- QQT_Warpigz_v3 (3.3.0): opts.ordered_pairs makes the plugins' pairs()
    -- walk string / number / boolean keys in sorted order. Native pairs order
    -- is not reproducible: LuaJIT 2.1 and Lua 5.4 seed the string hash per
    -- process, and in Lua 5.4 whether a removed key's node is reused depends
    -- on when the GC ran (so on every allocation anywhere in the process).
    -- Batmobile's explorer takes the first of equally good frontiers in pairs
    -- order, so the same script walks a different Pit from run to run with no
    -- other change. Traversal semantics are kept: keys removed during the loop
    -- are skipped, __pairs and tables with object keys use the native pairs.
    if opts.ordered_pairs then
        local native_pairs, rawget_, getmt = pairs, rawget, getmetatable
        local RANK = {boolean = 1, number = 2, string = 3}
        local function before(a, b)
            local ta, tb = type(a), type(b)
            if ta ~= tb then return RANK[ta] < RANK[tb] end
            if ta == 'boolean' then return (not a) and b end
            return a < b
        end
        BASE.pairs = function(t)
            local mt = getmt(t)
            if type(t) ~= 'table' or (mt and mt.__pairs) then return native_pairs(t) end
            local keys = {}
            for k in native_pairs(t) do
                if not RANK[type(k)] then return native_pairs(t) end
                keys[#keys + 1] = k
            end
            table.sort(keys, before)
            local i = 0
            return function()
                while true do
                    i = i + 1
                    local k = keys[i]
                    if k == nil then return nil end
                    local v = rawget_(t, k)
                    if v ~= nil then return k, v end
                end
            end, t, nil
        end
    end
    BASE.string, BASE.table, BASE.math = copy(string), copy(table), copy(math)
    h.stdlib = {string = BASE.string, table = BASE.table, math = BASE.math}
    h.stdlib_keys = {string = copy(BASE.string), table = copy(BASE.table), math = copy(BASE.math)}
    BASE.print = function(...)
        if h._mute_log then return end -- sweep: an invariant probe's own output
        local parts = {}
        for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
        local msg = table.concat(parts, ' ')
        h.log[#h.log + 1] = string.format('%.1f [print] %s', h.now, msg)
        if h._inv then h._inv.line(msg) end
    end
    -- Round 5: opts.virtual_os_time makes os.time() (no arguments) follow the
    -- simulated clock, so wall-clock phases (Reaper's chest WAIT_GONE /
    -- WAIT_COMPLETE, os.time based) finish in simulated time. Off by default:
    -- every older scenario keeps the real clock.
    local os_time = os.time
    if opts.virtual_os_time then
        local epoch = os.time()
        os_time = function(t)
            if t ~= nil then return os.time(t) end
            return epoch + math.floor(h.now)
        end
    end
    -- Sweep: opts.virtual_os_clock (a step in s, or true = 2e-6; on by
    -- default with opts.chaos) makes the plugins' os.clock() advance by that
    -- step per call instead of real CPU time. Batmobile's pathfinder stops on
    -- a CPU-time budget as well as an iteration cap, so with the real clock
    -- the same script can walk differently from run to run (and a chaos run
    -- would not replay exactly). Off by default: older scenarios keep it.
    local os_clock = os.clock
    local vclock = opts.virtual_os_clock
    if vclock == nil and opts.chaos then vclock = true end
    if vclock then
        local step, ticks = type(vclock) == 'number' and vclock or 2e-6, 0
        os_clock = function() ticks = ticks + 1; return ticks * step end
    end
    BASE.os = setmetatable({date = function(fmt, ...)
        -- QQT_Warpigz_v3: HelltideRevamped reads the UTC minute ('!%M',
        -- core/hr_clock.lua) and so does WarPigs (with a '%M' fallback). Both follow h.minute.
        if fmt == '%M' or fmt == '!%M' then return string.format('%02d', h.minute) end
        if fmt == '!%S' then return '00' end
        return os.date(fmt, ...)
    end, time = os_time, clock = os_clock, getenv = function() return nil end}, {__index = function(_, k)
        h.missing['os.' .. tostring(k)] = (h.missing['os.' .. tostring(k)] or 0) + 1
    end})
    -- Plugins may read their own data files; writes stay in memory.
    -- QQT_Warpigz_v3: a later read of a written path returns the last
    -- written text (h.mem_files[path]; tests may seed it), so persistence
    -- round-trips; every other read goes to the real file.
    local mem_files = {}
    h.mem_files = mem_files
    local function mem_reader(text)
        local pos, f = 1, {}
        local function next_line()
            if pos > #text then return nil end
            local e = text:find('\n', pos, true)
            local line
            if e then line, pos = text:sub(pos, e - 1), e + 1 else line, pos = text:sub(pos), #text + 1 end
            return line
        end
        function f:lines() return next_line end
        function f:read(fmt)
            if fmt == '*a' or fmt == '*all' or fmt == 'a' then
                local rest = text:sub(pos); pos = #text + 1; return rest
            end
            return next_line()
        end
        function f:seek(whence, offset)
            if whence == 'end' then pos = #text + 1; return #text end
            if whence == 'set' then pos = (offset or 0) + 1 end
            return pos - 1
        end
        function f:close() return true end
        return f
    end
    BASE.io = {open = function(path, mode)
        mode = mode or 'r'
        if mode:find('[wa+]') then
            local owner = code_owner(2)
            local rec = {path = path, mode = mode, owner = owner and owner.name, t = h.now, data = {}}
            h.file_writes[#h.file_writes + 1] = rec
            if h.fail_writes and h.fail_writes(path) then return nil, 'write refused by the test' end
            local f = {}
            function f:write(...)
                for i = 1, select('#', ...) do rec.data[#rec.data + 1] = tostring((select(i, ...))) end
                mem_files[path] = table.concat(rec.data)
                return self
            end
            function f:close() mem_files[path] = table.concat(rec.data); return true end
            function f:flush() return true end
            function f:setvbuf() return true end
            mem_files[path] = ''
            return f
        end
        if mem_files[path] ~= nil then return mem_reader(mem_files[path]) end
        return io.open(path, mode)
    end, lines = io.lines, write = function() end, read = function() return nil end}

    local G = {}
    h.G = G
    -- Optional globals the plugins probe for (not provided by this host).
    local EXPECTED_ABSENT = {PERSISTENT_MODE = true, D4Remote = true, PitPlugin = true,
        PLUGIN_alfred_the_butler = true}
    setmetatable(G, {
        __index = function(_, k)
            local val = BASE[k]
            if val == nil and type(k) == 'string' and not EXPECTED_ABSENT[k] then
                h.missing[k] = (h.missing[k] or 0) + 1
            end
            return val
        end,
        __newindex = function(t, k, val)
            local owner = code_owner(2)
            h.global_writes[#h.global_writes + 1] = {name = k, owner = owner and owner.name or '-',
                context = context and context.name or (loading and loading.name) or '-', t = h.now,
                at_load = loading ~= nil}
            rawset(t, k, val)
        end,
    })
    local function host(name, val) rawset(G, name, val) end
    host('_G', G)

    local function resolve(ctx, name)
        local rel = name:gsub('%.', '/')
        for _, candidate in ipairs({ctx.dir .. rel .. '.lua', ctx.dir .. rel .. '/init.lua'}) do
            local f = io.open(candidate, 'r')
            if f then f:close(); return candidate end
        end
        return nil
    end
    host('require', function(name)
        local ctx = context or loading
        local owner = code_owner(2)
        if not ctx then
            violation('require outside a plugin context', tostring(name), owner)
            error("module '" .. tostring(name) .. "' not found (no plugin context)", 2)
        end
        if owner ~= ctx then
            violation('caller-context require', string.format("require('%s') by %s code while %s runs (QQT resolves it in %s)",
                tostring(name), owner and owner.name or 'host', ctx.name, ctx.name), owner)
        end
        local cached = ctx.loaded[name]
        if cached ~= nil then return cached end
        local path = ctx.dir and resolve(ctx, name)
        if not path then error("module '" .. tostring(name) .. "' not found in " .. ctx.name, 2) end
        local chunk = assert(loadfile(path, 't', G))
        local result = chunk(name)
        if result == nil then result = true end
        if ctx.loaded[name] == nil then ctx.loaded[name] = result end
        return ctx.loaded[name]
    end)
    local package_proxy = setmetatable({}, {
        __index = function(_, k)
            local ctx = context or loading
            local owner = code_owner(2)
            if owner ~= ctx then
                violation('caller-context package.' .. tostring(k), 'package.' .. tostring(k) .. ' read by '
                    .. (owner and owner.name or 'host') .. ' code while ' .. (ctx and ctx.name or '-') .. ' runs', owner)
            end
            if k == 'loaded' then return ctx and ctx.loaded end
            if k == 'path' then return ctx and ctx.dir and (ctx.dir .. '?.lua;' .. ctx.dir .. '?/init.lua') or '' end
            if k == 'searchpath' then return package.searchpath end
            if k == 'config' then return package.config end
            return nil
        end,
        __newindex = function(_, k) violation('package write', 'package.' .. tostring(k) .. ' assigned', code_owner(2)) end,
    })
    host('package', package_proxy)

    local function register(kind)
        return function(fn)
            local ctx = loading or context
            if not loading then violation('callback registered outside load', kind, code_owner(2)) end
            if ctx and ctx[kind] then ctx[kind][#ctx[kind] + 1] = fn end
        end
    end
    host('on_update', register('update'))
    host('on_render', register('render'))
    host('on_render_menu', register('menu'))

    -- Run `fn` in `ctx`'s callback context, capturing errors like the host.
    h.calls = {}
    local function invoke(ctx, kind, fn)
        local key = ctx.name .. ':' .. kind
        h.calls[key] = (h.calls[key] or 0) + 1
        local prev = context
        context = ctx
        local ok, err = xpcall(fn, debug.traceback)
        context = prev
        if not ok then
            h.errors[#h.errors + 1] = {plugin = ctx.name, kind = kind, t = h.now, err = tostring(err)}
            h.log[#h.log + 1] = string.format('%.1f [host] %s %s error: %s', h.now, ctx.name, kind, tostring(err))
        end
        return ok, err
    end
    h.invoke = invoke
    -- Scenario code calling plugin exports runs in a plugin context.
    function h.as(dir_or_ctx, fn)
        local ctx = type(dir_or_ctx) == 'table' and dir_or_ctx or assert(h.by_dir[dir_or_ctx], dir_or_ctx)
        local prev = context
        context = ctx
        local packed
        local ok, err = xpcall(function()
            packed = (function(...) return {n = select('#', ...), ...} end)(fn())
        end, debug.traceback)
        context = prev
        if not ok then error(err, 2) end
        return (table.unpack or unpack)(packed, 1, packed.n)
    end
    function h.context_name() return context and context.name end

    -- ── menu widgets ────────────────────────────────────────────────────────
    local function widget(value, key)
        local w = {v = value, key = key, state = (value == true) and 1 or 0}
        function w:get() return self.v end
        function w:set(val)
            self.v = val
            if type(val) == 'boolean' then self.state = val and 1 or 0 elseif type(val) == 'number' then self.state = val end
        end
        function w:get_state() return self.state end
        function w:get_key() return self.key end
        function w:set_key(k) self.key = k end
        function w:render(label, ...)
            h.widgets_rendered = (h.widgets_rendered or 0) + 1
            -- 2.3.0-rc.11: h.menu_labels (a list the test sets) records the
            -- label of every widget rendered, in order.
            if h.menu_labels and type(label) == 'string' then h.menu_labels[#h.menu_labels + 1] = label end
        end
        function w:push() return h.menu_open ~= false end
        function w:pop() end
        return w
    end
    -- QQT restores a widget's stored value at load: opts.persisted maps the
    -- widget hash (get_hash returns its string) to the value it loads with.
    local persisted = copy(opts.persisted or {})
    -- 2.3.0-rc.11 (Rosie 1.0.8): the rc.10 scenarios predate "Pick up every
    -- Unique" (shipped ON); they load with it saved OFF, which is rc.10
    -- behaviour. opts.shipped_defaults loads the shipped defaults instead.
    if opts.rosie and not opts.shipped_defaults and persisted.Rosie_pickup_all_uniques == nil then
        persisted.Rosie_pickup_all_uniques = false
    end
    -- Sweep: opts.persist_widgets = true models QQT's menu store across a
    -- script reload (h.reload, chaos 'reload'): a keyed widget created again
    -- loads the value its predecessor holds now, not its default (sliders
    -- too). Default off: the older reload scenarios keep their behaviour.
    local live = opts.persist_widgets and {} or nil
    h.live_widgets = live
    local function stored(key, default)
        if live and key ~= nil and live[key] then return live[key].v end
        if key == nil or persisted[key] == nil then return default end
        return persisted[key]
    end
    local function keep(key, w)
        if live and key ~= nil then live[key] = w end
        return w
    end
    -- Sweep: every checkbox is registered by its hash key (h.checkboxes[key]
    -- = {w, owner}) and each plugin's '*main_toggle' by folder (h.toggles),
    -- so the invariant monitors can tell which farm plugin is switched on
    -- without calling a plugin getter (several are not read-only).
    h.checkboxes, h.toggles = {}, {}
    host('checkbox', {new = function(_, d, key)
        local w = keep(key, widget(stored(key, d == true)))
        local owner = loading or context
        if type(key) == 'string' then
            h.checkboxes[key] = {w = w, owner = owner and owner.name or '-'}
            if owner and not owner.pseudo and key:sub(-11) == 'main_toggle' then h.toggles[owner.name] = w end
        end
        return w
    end})
    host('combo_box', {new = function(_, d, key) return keep(key, widget(stored(key, d or 0))) end})
    host('slider_int', {new = function(_, _, _, d, key)
        if live then return keep(key, widget(stored(key, d))) end
        return widget(d)
    end})
    host('slider_float', {new = function(_, _, _, d, key)
        if live then return keep(key, widget(stored(key, d))) end
        return widget(d)
    end})
    host('tree_node', {new = function() return widget(false) end})
    host('button', {new = function() local w = widget(false); function w:render() return false end; return w end})
    host('input_text', {new = function(_, d) return widget(d or '') end})
    host('keybind', {new = function(_, key, toggle, hash)
        local w = widget(false, stored(hash, key))
        w.state = 0
        return w
    end})
    host('colorpicker', {new = function(_, d) return widget(d) end})
    host('get_hash', function(x) return x end)
    host('render_menu_header', function() end)
    local graphics_used = {}
    h.graphics_used = graphics_used
    host('graphics', setmetatable({}, {__index = function(_, k)
        if k == 'text_2d' or k == 'text_3d' then
            -- Sweep: with the monitors on, the drawn status text is kept per
            -- plugin (the STALL report quotes it, LOOP reads WarPigs/WarPug).
            return function(text)
                graphics_used[k] = (graphics_used[k] or 0) + 1
                if h._inv then h._inv.overlay(context, text) end
            end
        end
        return function() graphics_used[k] = (graphics_used[k] or 0) + 1 end
    end}))
    for _, c in ipairs({'white', 'red', 'green', 'yellow', 'orange', 'blue', 'purple', 'cyan', 'pink', 'gray',
        'grey', 'black', 'light_blue', 'dark_green', 'turquoise', 'orange_red'}) do
        host('color_' .. c, function(a) return {c, a} end)
    end
    host('color', {new = function(r, g, b, a)
        if type(r) == 'table' then return {g, b, a} end -- color:new(...)
        return {r, g, b, a}
    end})
    host('get_screen_width', function() return 1920 end)
    host('get_screen_height', function() return 1080 end)
    host('get_cursor_position', function() return Vec2:new(960, 540) end)
    host('vec3', Vec)
    host('vec2', Vec2)

    -- ── time, world, player ─────────────────────────────────────────────────
    host('console', {print = function(...)
        if h._mute_log then return end -- sweep: an invariant probe's own output
        local parts = {}
        for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
        local msg = table.concat(parts, ' ')
        h.log[#h.log + 1] = string.format('%.1f %s', h.now, msg)
        if h._inv then h._inv.line(msg) end
    end})
    host('get_time_since_inject', function() return h.now end)
    host('get_gametime', function() return h.now end)
    local world = {}
    function world:get_name() return h.place.name end
    function world:get_current_zone_name() return h.place.zone end
    function world:get_world_id() return h.place.id end
    host('get_current_world', function() return world end)
    host('attributes', {PLAYER_IN_TOWN_LEVEL_AREA = 1, CURRENT_MOUNT = 2})
    -- QQT buff objects: name_hash/stacks fields, name()/get_name_hash() methods.
    function h.buff(name, hash, stacks)
        return {name_hash = hash, stacks = stacks or 1, name = function() return name end,
            get_name = function() return name end, get_name_hash = function() return hash end}
    end
    local player = {}
    function player:get_position() return h.pos end
    function player:is_dead() return h.dead end
    function player:get_buffs()
        local out = {}
        if h.place.helltide then out[#out + 1] = h.buff('Helltide_Zone', J.HELLTIDE_BUFF) end
        for _, b in ipairs(h.buffs) do out[#out + 1] = b end
        return out
    end
    function player:get_attribute(attr)
        if attr == 1 then return h.place.town and 1 or 0 end
        return 0
    end
    function player:get_character_class_id() return 0 end
    function player:get_active_spell_id() return h.casting and 186139 or -1 end
    function player:get_current_health() return h.dead and 0 or 100 end
    function player:get_max_health() return 100 end
    function player:get_skin_name() return 'Player' end
    function player:get_item_count()
        h.item_count_reads = (h.item_count_reads or 0) + 1
        if rosie and h.item_count == nil then return #(h.inventory or {}) end
        return h.item_count or 0
    end
    function player:get_inventory_items() return h.inventory or {} end
    -- QQT_Warpigz_v3 (Q9): h.consumables / h.socketables model those bags;
    -- h.consumables_error makes the consumable read raise.
    function player:get_consumable_items()
        if h.consumables_error then error('host: consumable bag unavailable') end
        return h.consumables or {}
    end
    function player:get_dungeon_key_items() return h.keys_items or {} end
    -- Stash contents read only while the stash panel is open (Alfred's
    -- stash-count check relies on that).
    function player:get_stash_items()
        if h.vendor_screen and h.vendor_actor ~= nil and h.vendor_actor == h.temis_stash then
            -- Sweep (chaos 'stash_lazy', or a scenario setting h.stash_lazy =
            -- {small = N, window = s}): for `window` s after the panel opens
            -- the host lists only the first `small` stash items (live: 32,
            -- then the full 300 a moment later).
            local lazy = h.stash_lazy
            if lazy and h.now - (h.stash_opened_at or -math.huge) < (lazy.window or 1) then
                local out = {}
                for i = 1, math.min(lazy.small or 32, #(h.stash or {})) do out[i] = h.stash[i] end
                return out
            end
            return h.stash or {}
        end
        if opts.stash_stale and h.place == P.temis then return h.stash or {} end -- opts.stash_stale: a cached list while the panel is closed
        return {}
    end
    function player:get_equipped_items() return h.equipped or {} end
    function player:get_talisman_items() return h.talismans or {} end
    function player:get_socketable_items() return h.socketables or {} end -- QQT_Warpigz_v3 (Q9)
    function player:is_spell_ready() return false end
    function player:get_move_destination() return h.goal or h.pos end
    function player:is_moving() return h.goal ~= nil end
    function player:get_current_speed() return h.goal and h.speed or 0 end
    function player:get_id() return 1 end
    function player:get_obols() return h.obols or 0 end
    function player:is_enemy() return false end
    host('get_local_player', function() return player end)
    host('get_player_position', function() return h.pos end)
    local function walkable(p)
        local b = h.place.box
        if not (b ~= nil and p:x() >= b[1] and p:x() <= b[2] and p:y() >= b[3] and p:y() <= b[4]) then return false end
        -- Obstacles (h.place.walls = {{x1, x2, y1, y2}, ...}): the straight-line
        -- mover stops in front of them, as the live request_move does.
        for _, w in ipairs(h.place.walls or {}) do
            if p:x() >= w[1] and p:x() <= w[2] and p:y() >= w[3] and p:y() <= w[4] then return false end
        end
        return true
    end
    h.walkable = walkable

    -- ── travel (waypoints, warplan, portals) ────────────────────────────────
    -- `channel` s of casting, then 2 s of Limbo loading, then `place`.
    function h.travel_to(place, channel, why)
        place = type(place) == 'string' and P[place] or place
        h.travel = {at = h.now + (channel or 1), to = place, phase = 'channel', why = why}
        h.casting = true
        if h._inv then h._inv.on_travel(h.travel) end
        if h._chaos then h._chaos.on_travel(h.travel, channel or 1) end
    end
    local function note_call(list, rec)
        local owner = code_owner(3)
        rec.t, rec.context, rec.owner = h.now, context and context.name or '-', owner and owner.name or '-'
        rec.from = h.place.key
        list[#list + 1] = rec
        return rec
    end
    host('teleport_to_waypoint', function(sno)
        local rec = note_call(h.waypoints, {sno = sno})
        local key = h.waypoint_places[sno] or 'cerrigar'
        -- Sweep (TELEPORT): in this host Rosie's Town Portal cast is the
        -- waypoint teleport to Temis out of a non-town place (spell 186139).
        if h._inv then
            h._inv.teleport(rosie and key == 'temis' and not h.place.town and h.place ~= P.limbo
                and 'town_portal' or 'waypoint', rec, key)
        end
        -- Rosie mode: teleporting to Temis out of a non-town place leaves a
        -- town portal in Temis that leads back to the exact spot.
        if rosie and key == 'temis' and not h.place.town and h.place ~= P.limbo then
            h.open_town_portal(h.place, h.pos)
        end
        h.travel_to(key, 1.0, 'waypoint')
        return true
    end)
    host('teleport_to_boss_dungeon', function(id)
        local rec = note_call(h.boss_tps, {id = id})
        if h._inv then h._inv.teleport('boss_dungeon', rec, tostring(id)) end
        h.travel_to(h.boss_lair or 'lair', 1.0, 'boss_dungeon')
    end)
    -- Reviving is asynchronous: the player stands up at the checkpoint of the
    -- same world a moment later.
    host('revive_at_checkpoint', function()
        h.revives = h.revives + 1
        if h.dead and not h.reviving then
            h.reviving = true
            h.at(2.0, function()
                h.dead, h.reviving = false, false
                h.pos, h.goal = h.place.spawn, nil
            end)
        end
    end)
    host('reset_all_dungeons', function() h.resets = h.resets + 1 end)
    host('leave_dungeon', function()
        h.leaves = h.leaves + 1
        h.travel_to(h.leave_to or 'caldeum', 0.5, 'leave')
    end)
    -- Infernal Compasses (HordeDev's dungeon sigils). use_item at the
    -- Caldeum gate consumes the compass and opens the Consume Sigil dialog;
    -- confirming it opens the Horde portal next to the gate.
    h.items, h.sigil_confirms = {}, {}
    function h.sigil(name)
        name = name or 'S05_DungeonSigil_BSK_Wave6'
        return {get_name = function() return name end, get_skin_name = function() return name end,
            get_sno_id = function() return 0 end}
    end
    function h.give_compasses(n, name)
        h.keys_items = h.keys_items or {}
        for _ = 1, n or 1 do h.keys_items[#h.keys_items + 1] = h.sigil(name) end
    end
    host('use_item', function(item)
        note_call(h.items, {item = item, name = item and type(item.get_name) == 'function' and item:get_name() or nil})
        for i = #(h.keys_items or {}), 1, -1 do
            if h.keys_items[i] == item then table.remove(h.keys_items, i) end
        end
        if h.place == P.caldeum and h.pos:dist_to_ignore_z(h.horde_gate.pos) <= 20 then h.sigil_dialog = true end
        return true
    end)
    function h.open_horde_portal()
        if h.horde_portal then return h.horde_portal end
        local portal = h.actor('caldeum', 'Portal_Dungeon_Generic', -1706, -596)
        portal.on_interact = function()
            h.remove_actor(portal); h.horde_portal = nil
            h.travel_to('bsk', 0.5, 'horde_portal')
        end
        h.horde_portal = portal
        return portal
    end
    host('get_aether_count', function() return h.aether end)
    host('get_helltide_coin_cinders', function() return h.cinders end)
    host('get_glyphs', function() return {} end)
    host('upgrade_glyph', function() end)
    -- QQT_Warpigz_v3: h.spells / h.spell_names model the equipped bar.
    host('get_equipped_spell_ids', function() return h.spells or {} end)
    host('get_name_for_spell', function(id) return (h.spell_names or {})[id] or '' end)
    host('interact_object', function(a)
        note_call(h.interactions, {actor = a, skin = a and a.skin})
        if a and a.on_interact then a.on_interact(h, a) end
        return true
    end)
    host('interact_vendor', function(a)
        note_call(h.vendors, {actor = a, skin = a and a.skin})
        if rosie and a and a.vendor and h.pos:dist_to_ignore_z(a.pos) <= (a == h.temis_stash and (opts.stash_reach or 4) or 4)
            and not (opts.stash_broken and a == h.temis_stash)
            and not (a == h.temis_stash and (opts.stash_fail_first or 0) > (h.stash_fails or 0) and (function() h.stash_fails = (h.stash_fails or 0) + 1; return true end)()) then
            h.vendor_screen, h.vendor_actor = true, a
            if a ~= h.temis_stash then h.last_npc_vendor = a end
            if a == h.temis_stash then h.stash_opens = (h.stash_opens or 0) + 1; h.stash_opened_at = h.now end
        end
        if a == h.table_actor and h.pos:dist_to_ignore_z(a.pos) <= 4 then h.board.ready = true end
        if a and a.on_interact then a.on_interact(h, a) end
        return true
    end)

    -- ── native pathfinder / movement ────────────────────────────────────────
    local function move_request(kind)
        return function(p)
            if not p then return end
            -- opts.request_move_redundant (assumed return value): QQT documents
            -- that request_move "only sends a command if the player isn't
            -- already moving"; a skipped repeat is modelled as returning false.
            -- request_move_redundant='any' follows the docs literally: every
            -- request_move is skipped while the player is still moving.
            if kind == 'request_move' and opts.request_move_redundant and h.goal
                and (opts.request_move_redundant == 'any'
                    or math.abs(h.goal:x() - p:x()) + math.abs(h.goal:y() - p:y()) <= 0.5) then
                h.redundant_moves = (h.redundant_moves or 0) + 1
                return false
            end
            local rec = note_call(h.moves, {kind = kind, x = p:x(), y = p:y()})
            h.goal = Vec:new(p:x(), p:y(), 0)
            h.native = {x = p:x(), y = p:y(), by = rec.owner, context = rec.context, t = h.now}
            return true
        end
    end
    local pathfinder_api = {request_move = move_request('request_move'), force_move_raw = move_request('force_move_raw'),
        force_move = move_request('force_move'), move_to_cpathfinder = move_request('move_to_cpathfinder'),
        clear_stored_path = function()
            note_call(h.clears, {})
            h.goal, h.native = nil, nil
            if h.engine then h.engine.stored = nil end -- a pending mark request is NOT cancelled (live log)
        end}
    -- Live QQT create_path_game_engine (2.3.0-rc.6 logs), modelled whenever the
    -- real Rosie is loaded (opts.engine_path=false turns it off): asynchronous
    -- ("forward_mark_request ... forwarded", then a result only on a later call),
    -- a dummy {} within 500 ms of the previous call (flood prevention), and it
    -- routes to the MAP PIN: without a pin the request never completes
    -- ("create_path function exit point" forever, as in Temis).
    h.pins = {}
    if rosie and opts.engine_path ~= false then
        local engine = {calls = 0, forwards = 0, dummies = 0, finals = 0, last = -math.huge, log = {}}
        h.engine = engine
        pathfinder_api.create_path_game_engine = function(p)
            note_call(engine.log, {x = p and p:x(), y = p and p:y()})
            engine.calls = engine.calls + 1
            if h.now - engine.last < 0.5 then
                engine.dummies = engine.dummies + 1; engine.last = h.now
                return {}
            end
            engine.last = h.now
            local pending = engine.pending
            if pending and pending.mark and h.now >= pending.at + 0.6 then
                local route, from, mark = {}, pending.from, pending.mark
                local d = math.max(from:dist_to_ignore_z(mark), 0.01)
                for i = 1, math.ceil(d / 2) do
                    local f = math.min(1, i * 2 / d)
                    route[#route + 1] = Vec:new(from:x() + (mark:x() - from:x()) * f, from:y() + (mark:y() - from:y()) * f, 0)
                end
                engine.finals, engine.pending, engine.stored = engine.finals + 1, nil, route
                return route
            end
            if not pending then
                engine.forwards = engine.forwards + 1
                engine.pending = {at = h.now, from = Vec:new(h.pos:x(), h.pos:y(), 0), mark = h.pin}
            end
            return engine.stored or {}
        end
    end
    host('pathfinder', pathfinder_api)
    host('utility', {
        set_map_pin = function(p) h.pin = p; h.pins[#h.pins + 1] = p end,
        is_point_walkeable = walkable,
        set_height_of_valid_position = function(p) return p end,
        -- A straight line through h.place.walls is blocked (no walls: true,
        -- as before). h.ray_casts counts the calls.
        is_ray_cast_walkeable = function(from, to)
            h.ray_casts = (h.ray_casts or 0) + 1
            local walls = h.place.walls
            if not walls or from == nil or to == nil then return true end
            local d = math.max(from:dist_to_ignore_z(to), 0.01)
            for i = 0, math.ceil(d / 0.2) do
                local f = math.min(1, i * 0.2 / d)
                local x, y = from:x() + (to:x() - from:x()) * f, from:y() + (to:y() - from:y()) * f
                for _, w in ipairs(walls) do
                    if x >= w[1] and x <= w[2] and y >= w[3] and y <= w[4] then return false end
                end
            end
            return true
        end,
        can_cast_spell = function() return false end,
        -- The Temis obelisk dialog opens a pit: a portal to the pit floor appears.
        open_pit_portal = function()
            h.pit_opens = h.pit_opens + 1
            h.vendor_screen = false
            if h.place == P.temis and not h.pit_portal then
                h.pit_portal = h.actor('temis', 'EGD_MSWK_World_Portal_01', 2534, -446)
                h.pit_portal.on_interact = function()
                    h.remove_actor(h.pit_portal); h.pit_portal = nil
                    h.travel_to('pit', 0.5, 'pit_portal')
                end
            end
        end,
        send_key_press = function(key) h.keys[#h.keys + 1] = {key = key, t = h.now}
            -- QQT_Warpigz_v3 (Q6): Escape also closes an open vendor/stash
            -- panel and a hand-opened inventory (h.inventory_open); with
            -- nothing open it opens the game menu (h.game_menu_opens).
            -- h.escape_ignored: the key reaches no panel (a stuck panel).
            if key == 0x1B and h.escape_ignored then return end
            if key == 0x1B and not (h.panel or h.vendor_screen or h.inventory_open) then
                h.game_menu_opens = (h.game_menu_opens or 0) + 1
            end
            if key == 0x1B then h.panel = false end
            if key == 0x1B and h.rosie then h.vendor_screen, h.vendor_actor, h.inventory_open = false, nil, false end end,
        send_mouse_click = function(x, y)
            h.clicks[#h.clicks + 1] = {x = x, y = y, t = h.now}
            if h.on_click then h.on_click(x, y) end
        end,
        send_mouse_right_click = function(x, y) h.clicks[#h.clicks + 1] = {x = x, y = y, t = h.now, right = true} end,
        send_mouse_move = function() end,
        send_mouse_wheel = function() end,
        get_cursor_screen_position = function() return Vec2:new(960, 540) end,
        confirm_sigil_notification = function()
            note_call(h.sigil_confirms, {})
            if h.sigil_dialog and h.place == P.caldeum then
                h.sigil_dialog = false
                h.open_horde_portal()
            end
            return true
        end,
    })
    host('cast_spell', {position = function() return false end, target = function() return false end,
        self = function() return false end})
    host('evade', {register_circular_spell = function() end, is_dangerous_position = function() return false end})
    host('danger_level', {low = 1, medium = 2, high = 3})
    host('target_selector', {
        -- Sweep: opts.target_range = true honours (pos, range) as the game
        -- does; by default every living enemy of the place is returned (the
        -- older scenarios rely on it). Without it a pack 100 m away counts as
        -- "an enemy near the player" for every plugin that asks.
        get_near_target_list = function(pos, range)
            local out = {}
            local ranged = opts.target_range and type(range) == 'number' and type(pos) == 'table' and pos.x
            for _, a in ipairs(actors_here()) do
                if a.enemy and (a.health or 100) > 0
                    and (not ranged or (a.pos and a.pos:dist_to_ignore_z(pos) <= range)) then
                    out[#out + 1] = a
                end
            end
            return out
        end,
        is_valid_enemy = function(a) return a.enemy == true and (a.health or 100) > 1 end,
    })
    host('actors_manager', {
        get_all_actors = function() return actors_here() end,
        get_ally_actors = function()
            local out = {}
            for _, a in ipairs(actors_here()) do if not a.enemy then out[#out + 1] = a end end
            return out
        end,
        get_enemy_actors = function()
            local out = {}
            for _, a in ipairs(actors_here()) do if a.enemy then out[#out + 1] = a end end
            return out
        end,
        get_enemy_npcs = function()
            local out = {}
            for _, a in ipairs(actors_here()) do if a.enemy then out[#out + 1] = a end end
            return out
        end,
        get_all_items = function() return rosie and (h.place.items or {}) or {} end,
    })
    host('loot_manager', {
        any_item_around = function() return h.floor_loot end,
        -- opts.stash_screen_flag=false: the stash panel does not raise the
        -- vendor-screen flag (the case Alfred's stash-count fallback covers).
        is_in_vendor_screen = function()
            if h.vendor_screen and h.vendor_actor ~= nil and h.vendor_actor == h.temis_stash
                and opts.stash_screen_flag == false then return false end
            return h.vendor_screen == true
        end,
        get_all_items_chest_sort_by_distance = function() return {} end,
        interact_with_object = function(a)
            note_call(h.interactions, {actor = a, skin = a and a.skin, loot = true})
            if a and a.on_interact then a.on_interact(h, a) end
        end,
        is_obols = function() return false end,
    })
    if rosie then
        -- Rosie's town commands act on the vendor screen that is open.
        local lm = G.loot_manager
        local function take(item, list)
            for i = #(list or {}), 1, -1 do if list[i] == item then table.remove(list, i); return true end end
            return false
        end
        h.salvaged, h.sold, h.stashed, h.repairs = {}, {}, {}, 0
        -- rc.10 opt-in stash variants (defaults keep the rc.9 model):
        -- opts.vendor_sticky (get_current_vendor keeps naming the last NPC),
        -- opts.stash_inv (is_inventory_open while the stash panel is open),
        -- opts.stash_stale (stash list readable in Temis while closed),
        -- opts.stash_broken (the chest never opens), opts.stash_fail_first=N
        -- (the first N stash interactions do nothing), opts.stash_reach
        -- (interaction reach, default 4). h.stash_moves counts deposit calls.
        -- Live (2.3.0-rc.8): the stash is not a vendor; get_current_vendor()
        -- does not report it while its panel is open (opts.stash_is_vendor
        -- restores the old model).
        lm.get_current_vendor = function()
            if opts.vendor_sticky then return h.last_npc_vendor end -- opts.vendor_sticky: the last NPC vendor stays current
            if not h.vendor_screen then return nil end
            if h.vendor_actor == h.temis_stash and not opts.stash_is_vendor then return nil end
            return h.vendor_actor
        end
        lm.get_item_identifier = function(item) return item and item.uid end
        -- 2.3.0-rc.11: loot_manager.drop_item(item). The item leaves the bag
        -- and a NEW ground actor appears at the player's position: same SNO,
        -- rarity, affixes and rolls, a new identifier (uid). h.dropped lists
        -- {bag = item, ground = actor}. Opt-ins: h.drop_hides_affixes (the
        -- ground copy lists no affixes), h.drop_fails ('error' raises,
        -- 'false' returns false, 'stay' returns true but nothing happens).
        lm.drop_item = function(item)
            h.drop_calls = (h.drop_calls or 0) + 1
            if h.drop_fails == 'error' then error('host: drop_item failed') end
            if h.drop_fails == 'false' then return false end
            if h.drop_fails == 'stay' then return true end
            if not take(item, h.inventory) then return false end
            local fields = {}
            for k, val in pairs(item) do
                if type(val) ~= 'function' and k ~= 'uid' and k ~= 'pos' and k ~= 'picked' and k ~= 'on_interact' then fields[k] = val end
            end
            if item.affixes then
                fields.affixes = {}
                if not h.drop_hides_affixes then for i, a in ipairs(item.affixes) do fields.affixes[i] = a end end
            elseif h.drop_hides_affixes then fields.affixes = {} end
            local ground = h.drop(h.place, h.pos:x(), h.pos:y(), fields)
            h.dropped = h.dropped or {}
            h.dropped[#h.dropped + 1] = {bag = item, ground = ground, t = h.now}
            return true
        end
        lm.is_gold = function() return false end
        lm.is_potion = function() return false end
        lm.is_lootable_item = function() return true end
        lm.salvage_specific_item = function(item)
            if take(item, h.inventory) or take(item, h.talismans) then h.salvaged[#h.salvaged + 1] = item end
            return true
        end
        lm.sell_specific_item = function(item)
            if take(item, h.inventory) or take(item, h.talismans) then h.sold[#h.sold + 1] = item end
            return true
        end
        lm.repair_all_items = function()
            h.repairs = h.repairs + 1
            for _, item in ipairs(h.equipped or {}) do item.durability = 100 end
            return true
        end
        -- The stash panel must be open (Rosie's own check is not the host's).
        lm.move_item_to_stash = function(item)
            h.stash_moves = (h.stash_moves or 0) + 1
            if not (h.vendor_screen and h.vendor_actor == h.temis_stash) then return false end
            -- QQT_Warpigz_v3 (Q9): a must-keep item (field must_keep) is refused
            -- by the game (host returns true, nothing moves).
            if item.must_keep then return true end
            if take(item, h.inventory) or take(item, h.consumables or {}) or take(item, h.socketables or {}) then
                h.stashed[#h.stashed + 1] = item
                h.stash = h.stash or {}; h.stash[#h.stash + 1] = item
            end
            return true
        end
        lm.move_item_from_stash = function(item) -- works only while the stash panel is open
            if not (h.vendor_screen and h.vendor_actor == h.temis_stash) then return false end
            if take(item, h.stash) then h.inventory[#h.inventory + 1] = item end
            return true
        end
        host('is_chat_open', function() return h.chat_open == true end)
        host('is_inventory_open', function()
            -- QQT_Warpigz_v3 (Q6): h.inventory_open (opened by hand) and
            -- opts.vendor_inv (every vendor panel shows the inventory).
            if h.inventory_open == true or (opts.vendor_inv == true and h.vendor_screen == true) then return true end
            return opts.stash_inv == true and h.vendor_screen == true and h.vendor_actor == h.temis_stash
        end)
        host('get_actors_list', function() return actors_here() end)
        host('orb_mode', {none = 0, pvp = 1, clear = 2, flee = 3})
        -- Temis vendors Rosie services (skins and positions: rosie/private/town/core/town.lua).
        h.blacksmith = h.actor('temis', 'TWN_Skov_Temis_Crafter_Blacksmith', 2574.25, -479.20, {vendor = true})
        h.gambler = h.actor('temis', 'TWN_Skov_Temis_Vendor_Gambler', 2566.22, -478.74, {vendor = true})
        h.temis_stash = h.actor('temis', 'Stash', 2574.04, -486.25, {vendor = true})
        -- A waypoint teleport to Temis from a non-town place leaves a town
        -- portal there that returns to the exact spot (one at a time).
        function h.open_town_portal(place, pos)
            if h.town_portal then h.remove_actor(h.town_portal) end
            local portal = h.actor('temis', 'TownPortal', 2578.11, -482.26)
            portal.on_interact = function()
                h.remove_actor(portal); h.town_portal = nil
                h.travel_to(place, 0.5, 'town_portal')
                h.travel.pos = pos
            end
            h.town_portal = portal
            return portal
        end
        -- Inventory gear Rosie can classify (legacy skin prefix, not in the catalog).
        local uid = 5000
        function h.gear(fields)
            uid = uid + 1
            local item = {uid = uid, name = 'Helm_Rare_Joint', rarity = 3, ancestral = false, junk = false,
                locked = false, ga = 0, durability = 100, sno = 990000000 + uid}
            for k, val in pairs(fields or {}) do item[k] = val end
            function item:is_valid() return true end
            function item:is_locked() return self.locked end
            function item:get_sno_id() return self.sno end
            function item:get_name() return self.name end
            function item:get_skin_name() return self.name end
            -- `display` models a host label that differs from the SNO name
            -- (live rc.8: a fresh Leoric's Crown read "Helm").
            function item:get_display_name() return self.display or self.name end
            function item:get_rarity() return self.rarity end
            function item:is_ancestral() return self.ancestral end
            function item:is_junk() return self.junk end
            -- `attrs` holds named host attributes (Item_Quality_Modifier_Bits ...);
            -- anything else keeps the old behaviour (the Greater Affix count).
            function item:get_attribute(name)
                if self.attrs and self.attrs[name] ~= nil then return self.attrs[name] end
                if name == 'Item_Quality_Modifier_Bits' or name == 'Item_Quality_Level'
                    or name == 'Item_Power_Total' then return nil end
                return self.ga
            end
            function item:get_affixes() return self.affixes or {} end
            function item:get_durability() return self.durability end
            function item:is_filtered_by_loot_filter() return self.filtered == true end
            function item:get_stack_count() return 1 end
            function item:get_item_info() return self end
            return item
        end
        -- A ground drop at (x, y) of `place`; interacting picks it up.
        function h.drop(place, x, y, fields)
            place = type(place) == 'string' and P[place] or place
            local item = h.gear(fields)
            item.pos = v(x, y)
            item.dropped_at = h.now -- sweep: LEFT_DROP reports the age of a drop left behind
            function item:get_position() return self.pos end
            item.on_interact = function()
                if item.picked then return end
                -- QQT_Warpigz_v3 (Q9): fields.refuse(h, item) true = the game
                -- refuses the pickup (the drop stays); fields.bag names the bag
                -- list ('consumables', 'socketables') a picked drop goes to.
                if item.refuse and item.refuse(h, item) then h.refusals = (h.refusals or 0) + 1; return end
                item.picked = true
                for i = #(place.items or {}), 1, -1 do if place.items[i] == item then table.remove(place.items, i) end end
                local bag = item.bag or 'inventory'
                h[bag] = h[bag] or {}
                h[bag][#h[bag] + 1] = item
                h.pickups = (h.pickups or 0) + 1
            end
            place.items = place.items or {}
            place.items[#place.items + 1] = item
            return item
        end
    end

    -- ── orbwalker ───────────────────────────────────────────────────────────
    h.orb = {clear = true, block = false, mode = 0, auto_loot = opts.auto_loot == true}
    host('orbwalker', {
        set_clear_toggle = function(val) h.orb.clear = val; note_call(h.orb_log, {what = 'clear', value = val}) end,
        set_auto_loot_toggle = function(val) h.orb.auto_loot = val end,
        set_block_movement = function(val) h.orb.block = val; note_call(h.orb_log, {what = 'block', value = val}) end,
        get_orb_mode = function() return h.orb.mode end,
    })

    -- ── quests ──────────────────────────────────────────────────────────────
    local function quest_obj(q)
        if type(q) == 'string' then q = {name = q} end
        return {get_name = function() return q.name end, get_id = function() return q.id or #q.name end,
            get_objectives = function() return q.objectives or {} end}
    end
    host('get_quests', function()
        if h.quests_unreadable then error('quest snapshot unavailable') end
        local out = {}
        for i, q in ipairs(h.quests) do out[i] = quest_obj(q) end
        if h.bounty_ready then
            out[#out + 1] = quest_obj({name = 'Bounty_Meta_Quest', objectives = {{text = 'Return to the Tree of Whispers'}}})
        end
        return out
    end)
    function h.set_quests(list) h.quests = list or {} end

    -- ── native war plan board (WarPug) and warplan teleport (WarPigs) ───────
    h.board = {ready = false, required = 3, selected = {}, confirmed = 0,
        layers = {{11, 12}, {21, 22}, {31}},
        names = {[11] = 'Warplans_ThePit', [12] = 'Warplans_Undercity', [21] = 'Warplans_Helltide',
            [22] = 'Warplans_InfernalHordes', [31] = 'Warplans_TurnIn'}}
    local board = h.board
    local function legal_now()
        return copy(board.layers[#board.selected + 1] or {})
    end
    host('warplan', {
        is_ready = function() return board.ready end,
        selected_path = function() return copy(board.selected) end,
        selected_count = function() return #board.selected end,
        get_selectable_now = legal_now,
        node_name = function(id) return board.names[id] end,
        select_node = function(id)
            for _, legal in ipairs(legal_now()) do
                if legal == id then board.selected[#board.selected + 1] = id; return true end
            end
            return false
        end,
        deselect_last = function()
            if #board.selected == 0 then return false end
            table.remove(board.selected)
            return true
        end,
        is_complete = function() return #board.selected == board.required end,
        required_picks = function() return board.required end,
        confirm = function()
            note_call(h.warplans, {kind = 'confirm', path = copy(board.selected)})
            board.confirmed = board.confirmed + 1
            local path = copy(board.selected)
            board.selected, board.ready = {}, false
            if h.on_confirm then h.on_confirm(path) end
        end,
        teleport_to_activity = function()
            local rec = note_call(h.warplans, {kind = 'teleport'})
            local dest = h.warplan_dest
            if type(dest) == 'function' then dest = dest(h) end
            if h._inv then
                h._inv.teleport('warplan', rec, type(dest) == 'table' and dest.key or dest and tostring(dest) or 'no destination')
            end
            if dest then h.travel_to(dest, 1.5, 'warplan') end
        end,
    })

    -- ── Tree of Whispers reward panel (SilentRaven) ─────────────────────────
    h.panel = false
    h.reward_entries = {[1] = {sno = 1087411, valid = true, internal_name = 'BountyMeta_Cache_Helms'}}
    h.raven.on_interact = function() if h.bounty_ready then h.panel = true end end
    -- The claimed cache lands in the inventory (SilentRaven verifies receipt).
    function h.deliver_reward(index)
        local base = h.reward_entries[0] ~= nil and 0 or 1
        local entry = h.reward_entries[(index or 0) + base]
        local sno = entry and tonumber(entry.sno)
        h.inventory = h.inventory or {}
        h.inventory[#h.inventory + 1] = {get_sno_id = function() return sno end, get_acd = function() return 4321 end,
            get_stack_count = function() return 1 end, get_skin_name = function() return 'cache' end,
            get_name = function() return 'BountyMeta_Cache' end, is_valid = function() return true end,
            is_locked = function() return false end, get_rarity = function() return 0 end}
        h.panel, h.bounty_ready = false, false
    end
    host('quest_reward', {
        is_open = function() return h.panel end,
        enumerate = function() return h.panel and h.reward_entries or {} end,
        select = function(i) h.reward_selected = i; return true end,
        selected_index = function() return h.reward_selected or -1 end,
        accept = function()
            h.reward_accepts = (h.reward_accepts or 0) + 1
            h.deliver_reward(h.reward_selected)
            return true
        end,
        pick_and_accept = function(i)
            h.reward_selected = i
            h.reward_accepts = (h.reward_accepts or 0) + 1
            h.deliver_reward(i)
            return true
        end,
    })

    -- ── AlfredTheButler (closed source): C1-shaped status ───────────────────
    local al = {enabled = true, need_trigger = false, inventory_full = false, need_repair = false,
        restock_count = 0, trigger_tasks = false, external_trigger = false, pending = false,
        running = false, teleport = false, teleport_done = false, teleport_failed = false,
        paused = false, all_task_done = true, triggers = {}, work = opts.alfred_work or 6}
    h.alfred = al
    local ALFRED_FIELDS = {'enabled', 'need_trigger', 'inventory_full', 'need_repair', 'restock_count',
        'trigger_tasks', 'external_trigger', 'pending', 'running', 'teleport', 'teleport_done',
        'teleport_failed', 'paused', 'paused_by', 'external_caller', 'all_task_done'}
    local function queue_alfred(caller, cb, teleport)
        local owner = code_owner(3)
        al.triggers[#al.triggers + 1] = {t = h.now, caller = caller, teleport = teleport,
            context = context and context.name or '-', owner = owner and owner.name or '-', place = h.place.key}
        al.external_trigger, al.external_caller, al.cb, al.all_task_done = true, caller, cb, false
        al.job = {t = h.now, phase = 'queued', teleport = teleport, exit = h.place, exit_pos = h.pos}
        if teleport then al.teleport, al.teleport_done, al.teleport_failed = true, false, false end
        return true
    end
    if not rosie then host('AlfredTheButlerPlugin', {
        get_status = function()
            if al.unreadable then error('Alfred status unavailable') end
            local s = {}
            for _, k in ipairs(ALFRED_FIELDS) do s[k] = al[k] end
            return s
        end,
        trigger_tasks = function(caller, cb) return queue_alfred(caller, cb, false) end,
        trigger_tasks_with_teleport = function(caller, cb) return queue_alfred(caller, cb, true) end,
        pause = function(caller) al.paused, al.paused_by = true, caller; return true end,
        resume = function(caller) al.paused, al.paused_by = false, nil; return true end,
    }) end
    local function alfred_done()
        local job = al.job
        al.job = nil
        al.trigger_tasks, al.external_trigger, al.running, al.all_task_done = false, false, false, true
        al.inventory_full, al.need_repair = false, false
        if not al.sticky_need then al.need_trigger = false end
        if job and job.teleport then al.teleport_done = true end
        local cb = al.cb
        al.cb = nil
        if cb then cb() end
    end
    local function alfred_tick()
        local job = al.job
        if not job or al.paused or not al.enabled then return end
        local age = h.now - job.t
        local function phase(name) job.phase, job.t = name, h.now end
        if job.phase == 'queued' and age >= 0.3 then
            al.external_trigger, al.trigger_tasks, al.running = false, true, true
            if job.teleport and not h.place.town then
                h.travel_to('temis', 1.0, 'alfred'); phase('to_town')
            else
                phase('work')
            end
        elseif job.phase == 'to_town' and not h.travel and h.place.town then
            phase('work')
        elseif job.phase == 'work' then
            if age >= al.work then
                if job.teleport and job.exit and not job.exit.town then
                    h.travel_to(job.exit, 1.0, 'alfred_return'); phase('return')
                else
                    alfred_done()
                end
            elseif h.place.town and math.floor(age * 2) ~= math.floor((age - 0.1) * 2) then
                G.pathfinder.request_move(v(h.pos:x() + 3, h.pos:y() + 2))
            end
        elseif job.phase == 'return' and not h.travel and h.place == job.exit then
            h.pos = job.exit_pos
            alfred_done()
        end
    end

    -- ── LooteerV3 (closed source): read only ────────────────────────────────
    local lt = {enabled = true, busy = false}
    h.looter = lt
    if not rosie then host('LooteerPlugin', {
        get_enabled = function() return lt.enabled end,
        is_actively_looting = function() return lt.busy end,
    }) end
    local function looter_tick()
        if lt.busy and lt.enabled and math.floor(h.now * 2) ~= math.floor((h.now - 0.1) * 2) then
            G.pathfinder.request_move(v(h.pos:x() + 2, h.pos:y() - 1))
        end
    end

    -- ── load every plugin ───────────────────────────────────────────────────
    local sorted = copy(dirs)
    table.sort(sorted)
    for i, dir in ipairs(sorted) do assert(dirs[i] == dir, 'plugin folders must load in alphabetical order') end
    h.base_keys = {}
    for k in pairs(G) do h.base_keys[k] = true end
    for _, rec in ipairs(h.plugins) do
        loading = rec
        local chunk, err = loadfile(rec.dir .. 'main.lua', 't', G)
        if not chunk then
            h.errors[#h.errors + 1] = {plugin = rec.name, kind = 'load', t = h.now, err = err}
        else
            local ok, lerr = xpcall(chunk, debug.traceback)
            if not ok then h.errors[#h.errors + 1] = {plugin = rec.name, kind = 'load', t = h.now, err = tostring(lerr)} end
        end
        loading = nil
    end

    -- QQT script reload of one plugin folder: its callbacks are dropped and
    -- main.lua runs again. opts.keep_loaded keeps the folder's package.loaded
    -- (a host that does not clear it); default is a fresh module cache.
    function h.reload(dir, o)
        o = o or {}
        local rec = assert(h.by_dir[dir], dir)
        if not o.keep_loaded then rec.loaded = {} end
        rec.update, rec.render, rec.menu = {}, {}, {}
        loading = rec
        local chunk, err = loadfile(rec.dir .. 'main.lua', 't', G)
        if not chunk then
            h.errors[#h.errors + 1] = {plugin = rec.name, kind = 'reload', t = h.now, err = err}
        else
            local ok, lerr = xpcall(chunk, debug.traceback)
            if not ok then h.errors[#h.errors + 1] = {plugin = rec.name, kind = 'reload', t = h.now, err = tostring(lerr)} end
        end
        loading = nil
    end

    -- ── frame loop ──────────────────────────────────────────────────────────
    local function travel_tick()
        local t = h.travel
        if not t or h.now < t.at then return end
        if t.phase == 'channel' then
            -- Sweep (LEFT_DROP): judged while the player still stands in the
            -- place it leaves (Rosie's decision reads the zone and position).
            if h._inv then h._inv.departing(t) end
            h.casting = false
            h.place, h.pos, h.goal, h.native = P.limbo, P.limbo.spawn, nil, nil
            h.vendor_screen = false
            t.phase, t.at = 'loading', h.now + 2
        else
            h.travel = nil
            h.place, h.pos, h.goal = t.to, t.pos or t.to.spawn, nil
            h.arrivals[#h.arrivals + 1] = {t = h.now, place = t.to.key, why = t.why}
            if t.to.on_arrive then t.to.on_arrive(h, t) end
        end
    end
    local function run_events()
        local keep = {}
        for _, e in ipairs(h.events) do
            if h.now >= e.at then e.fn(h) else keep[#keep + 1] = e end
        end
        h.events = keep
    end
    function h.at(delay, fn) h.events[#h.events + 1] = {at = h.now + delay, fn = fn} end
    function h.frame(dt)
        dt = dt or 0.1
        h.now = h.now + dt
        h.frames = h.frames + 1
        travel_tick()
        run_events()
        if h._chaos then h._chaos.tick() end -- sweep: seeded chaos (J.new({chaos = ...}))
        if not rosie then
            invoke(h.alfred_ctx, 'update', alfred_tick)
            invoke(h.looter_ctx, 'update', looter_tick)
        end
        for _, rec in ipairs(h.plugins) do
            for _, fn in ipairs(rec.update) do invoke(rec, 'on_update', fn) end
        end
        -- Sweep: the third-party Universal Rotation (J.new({rotation = ...}))
        -- runs as its own folder-less plugin after the suite's plugins.
        if h._rot then invoke(h.rotation_ctx, 'update', h._rot.tick) end
        if h.vendor_screen and h.vendor_actor and h.vendor_actor.pos
            and h.pos:dist_to_ignore_z(h.vendor_actor.pos) > 5 then
            h.vendor_screen, h.vendor_actor = false, nil -- walking away closes the panel
        end
        if h.goal and h.place ~= P.limbo and not h.travel then
            local dx, dy = h.goal:x() - h.pos:x(), h.goal:y() - h.pos:y()
            local d = math.sqrt(dx * dx + dy * dy)
            local step = h.speed * dt
            if d <= step then
                if walkable(h.goal) then h.pos = Vec:new(h.goal:x(), h.goal:y(), 0) end
                h.goal = nil
            else
                local nxt = Vec:new(h.pos:x() + dx / d * step, h.pos:y() + dy / d * step, 0)
                if walkable(nxt) then h.pos = nxt
                elseif h.place.slide then
                    -- QQT_Warpigz_v3: opt-in (place.slide) — like the game's
                    -- mover, a step that clips a wall corner slides along it.
                    local sx = Vec:new(h.pos:x() + dx / d * step, h.pos:y(), 0)
                    local sy = Vec:new(h.pos:x(), h.pos:y() + dy / d * step, 0)
                    if math.abs(dx) >= math.abs(dy) and walkable(sx) then h.pos = sx
                    elseif walkable(sy) then h.pos = sy
                    elseif walkable(sx) then h.pos = sx end
                end
            end
        end
        -- The combat rotation (not a plugin of the suite) kills enemies in reach.
        for _, a in ipairs(h.place.actors) do
            if a.enemy and (a.health or 100) > 0 and a.pos:dist_to_ignore_z(h.pos) <= (a.reach or 4) then
                a.health = (a.health or 100) - (h.dps or 40) * dt
                if a.health <= 0 then
                    a.health, a.interactable = 0, false
                    if a.on_death then a.on_death(h, a) end
                end
            end
        end
        if h.render ~= false then
            for _, rec in ipairs(h.plugins) do
                for _, fn in ipairs(rec.render) do invoke(rec, 'on_render', fn) end
            end
            for _, rec in ipairs(h.plugins) do
                for _, fn in ipairs(rec.menu) do invoke(rec, 'on_render_menu', fn) end
            end
        end
        if h._inv then h._inv.tick() end -- sweep: invariant monitors (read-only)
    end
    function h.run(seconds, each, dt)
        local stop = h.now + seconds - 1e-9
        while h.now < stop do
            h.frame(dt)
            if each then each(h) end
        end
    end
    function h.run_until(pred, seconds, each, dt)
        local stop = h.now + seconds - 1e-9
        while h.now < stop do
            h.frame(dt)
            if each then each(h) end
            if pred(h) then return true end
        end
        return false
    end

    -- ── inspection helpers ──────────────────────────────────────────────────
    -- Record (not replace) every call of a documented export: export, name,
    -- caller argument, calling plugin context and place. h.bm_calls keeps the
    -- BatmobilePlugin subset.
    h.bm_calls, h.api_calls = {}, {}
    local wrapped = {}
    function h.instrument_exports()
        for export in pairs(h.exports) do
            local api = G[export]
            if type(api) == 'table' and not wrapped[api] then
                wrapped[api] = true
                local label = api == G.PLUGIN_silent_raven and 'SilentRavenPlugin' or export
                for name, fn in pairs(api) do
                    if type(fn) == 'function' then
                        api[name] = function(...)
                            local caller = (...)
                            local rec = {export = label, name = name, caller = type(caller) == 'string' and caller or nil,
                                context = context and context.name or '-', t = h.now, place = h.place.key,
                                -- an options table's `entry` (HordeDev enable({entry = 'warplan'}))
                                entry = type(caller) == 'table' and caller.entry or nil,
                                with_args = select('#', ...) > 0}
                            h.api_calls[#h.api_calls + 1] = rec
                            if label == 'BatmobilePlugin' then h.bm_calls[#h.bm_calls + 1] = rec end
                            return fn(...)
                        end
                    end
                end
            end
        end
    end
    function h.mod(dir, name) return h.by_dir[dir].loaded[name] end
    function h.logged(text, since)
        local n = 0
        for _, line in ipairs(h.log) do
            if line:find(text, 1, true) then
                if not since or (tonumber(line:match('^(%-?[%d%.]+)')) or 0) >= since then n = n + 1 end
            end
        end
        return n
    end
    function h.tail(n)
        local out = {}
        for i = math.max(1, #h.log - (n or 40)), #h.log do out[#out + 1] = h.log[i] end
        return table.concat(out, '\n')
    end
    function h.count(list, pred)
        local n = 0
        for _, rec in ipairs(list) do if not pred or pred(rec) then n = n + 1 end end
        return n
    end
    function h.new_globals()
        local out = {}
        for k in pairs(G) do if not h.base_keys[k] then out[#out + 1] = k end end
        table.sort(out)
        return out
    end
    function h.stdlib_additions()
        local out = {}
        for lib, now_tbl in pairs(h.stdlib) do
            for k in pairs(now_tbl) do
                if h.stdlib_keys[lib][k] == nil then out[#out + 1] = lib .. '.' .. k end
            end
        end
        table.sort(out)
        return out
    end
    -- Fail with the first recorded Lua error or caller-context violation.
    function h.assert_clean(label)
        if #h.errors > 0 then
            local e = h.errors[1]
            error(string.format('%s: %d Lua error(s); first in %s %s at %.1f:\n%s', label or 'joint', #h.errors,
                e.plugin, e.kind, e.t, e.err), 2)
        end
        if #h.violations > 0 then
            local vi = h.violations[1]
            error(string.format('%s: %d caller-context violation(s); first: [%s] %s (context=%s owner=%s at %.1f)%s',
                label or 'joint', #h.violations, vi.kind, vi.detail, vi.context, vi.owner, vi.t, vi.trace), 2)
        end
    end

    -- ── sweep: invariant monitors, Universal Rotation stub, seeded chaos ──
    -- All opt-in (see J.install_invariants / J.install_rotation /
    -- J.install_chaos below). QQT_INVARIANTS=1 in the environment turns the
    -- monitors on for every J.new that does not pass invariants=false.
    local inv_opts = opts.invariants
    if inv_opts == nil and os.getenv('QQT_INVARIANTS') == '1' then inv_opts = true end
    local sweep_host = {P = P, rosie = rosie, seed = opts.seed or 7}
    if inv_opts then J.install_invariants(h, inv_opts, sweep_host) end
    function h.invariant_report()
        if not h._inv then return 'invariants off (J.new({invariants = true}) or QQT_INVARIANTS=1)', {} end
        return h._inv.report()
    end
    function h.assert_invariants(label, overrides)
        if not h._inv then error((label or 'joint') .. ': invariants are off; pass J.new({invariants = true})', 2) end
        local remaining = h._inv.filter(overrides)
        if #remaining > 0 then
            error(string.format('%s: %d invariant violation(s):\n%s', label or 'joint', #remaining,
                h._inv.format(remaining)), 2)
        end
    end
    if opts.rotation then
        h.rotation_ctx = {name = 'UniversalRotation', pseudo = true, loaded = {}}
        J.install_rotation(h, opts.rotation, sweep_host)
    end
    if opts.chaos then
        h.chaos_ctx = {name = 'ClickRevive', pseudo = true, loaded = {}}
        J.install_chaos(h, opts.chaos, sweep_host)
    end
    return h
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Sweep tooling (QQT_Warpigz_v3 after 3.3.6): invariant monitors, a Universal
-- Rotation stub and seeded chaos. Test infrastructure only; nothing here is
-- reachable unless a scenario asks for it (or QQT_INVARIANTS=1, monitors only).
--
--   local h = J.new({rosie = true, place = 'pit', invariants = true,
--       rotation = true, chaos = {seed = 42, rate = 2}})
--   h.run(600)
--   print((h.invariant_report()))
--   h.assert_invariants('S2 pit', {SPAM = false, TELEPORT = 1,
--       LOOP = function(hit) return hit.detail:find('world.place', 1, true) end})
--   print(h.chaos.replay())  -- the exact J.new chaos table to replay the run
--
-- None of the three draws from math.random (plugins that do see the same
-- numbers as without them): each has its own Park-Miller stream (J.rng).
-- ═══════════════════════════════════════════════════════════════════════════

-- Park-Miller "minimal standard" generator. Every product stays below 2^53,
-- so Lua 5.4 (integers) and LuaJIT (doubles) produce the same sequence.
function J.rng(seed)
    local s = math.floor(tonumber(seed) or 1) % 2147483647
    if s <= 0 then s = s + 2147483646 end
    -- Two warm-up steps: the first output of a small seed is tiny (42 ->
    -- 0.0003), which would bias the first draw of every stream.
    s = (s * 16807) % 2147483647
    s = (s * 16807) % 2147483647
    local r = {}
    function r.next() s = (s * 16807) % 2147483647; return s / 2147483647 end
    function r.range(a, b) return a + (b - a) * r.next() end
    function r.int(a, b) return math.min(b, a + math.floor(r.next() * (b - a + 1))) end
    function r.chance(p) return r.next() < (p or 0) end
    function r.pick(list) return list[r.int(1, #list)] end
    return r
end

local function mask_numbers(s) return (tostring(s):gsub('%d+', '#')) end
J.mask_numbers = mask_numbers
local function merged(defaults, user)
    local out = {}
    for k, val in pairs(defaults) do out[k] = val end
    if type(user) == 'table' then for k, val in pairs(user) do out[k] = val end end
    return out
end
local function one_line(s) return (tostring(s):gsub('[\t\r\n]+', ' ')) end

-- ── invariant monitors ─────────────────────────────────────────────────────
-- TELEPORT   more than `max` teleport casts (teleport_to_waypoint, Rosie's
--            Town Portal = the Temis waypoint out of a non-town place,
--            warplan.teleport_to_activity, teleport_to_boss_dungeon) between
--            two arrivals in a new place.
-- LEFT_DROP  a travel channel completes (the player leaves the place) while a
--            ground item Rosie wants (ItemManager.check_want_item, the
--            decision behind LooteerPlugin.evaluate_item without its
--            rejection log) lies within `radius` m of where it stood and
--            within Rosie's pickup distance (a Unique/Mythic counts anywhere
--            within `radius`). Judged before the Limbo switch, so Rosie reads
--            the old zone. Tags: dropped during the channel, already wanted
--            when the cast started; a drop picked up after a return to the
--            spot is annotated "picked up later" (the hit stays). Rosie mode
--            only (ground items exist only there).
-- STALL      the player stays within `move` m for more than `seconds` s while
--            alive, not loading, a farm plugin's main toggle is on, and (in
--            a town) some plugin still sent a command in the last
--            `town_quiet` s (a quiet town is idle, not stalled).
-- SPAM       one console line (numbers masked) printed more than `max` times
--            within `window` s.
-- LOOP       one state source switching between the same two states more
--            than `max` times within `window` s. Sources: each task
--            manager's current task (Arkham, HelltideRevamped + its task
--            state, HordeDev, Reaper, WonderCity, Rosie town), SilentRaven's
--            tracker.state, the drawn WarPigs / WarPug status line, the
--            player's place, and "state A -> B" console lines.
J.INVARIANT_KINDS = {'TELEPORT', 'LEFT_DROP', 'STALL', 'SPAM', 'LOOP'}
J.INVARIANT_DEFAULTS = {
    TELEPORT = {max = 2},
    LEFT_DROP = {radius = 15},
    STALL = {seconds = 90, move = 1, town_quiet = 10, poll = 0.5,
        farm = {'ArkhamAsylum', 'HelltideRevamped', 'HordeDev', 'Reaper', 'WonderCity', 'WarPigs'}},
    SPAM = {max = 20, window = 60},
    LOOP = {max = 10, window = 120, poll = 0.25},
}
-- Task managers read by LOOP / STALL (get_current_task() only returns a local).
J.TASK_MODULES = {ArkhamAsylum = 'core.task_manager', HelltideRevamped = 'core.task_manager',
    HordeDev = 'core.task_manager', Reaper = 'core.task_manager', WonderCity = 'core.task_manager',
    Rosie = 'rosie.private.town.core.task_manager'}
J.MYTHIC_MARK = 2628989 -- S14_Mythic_UniquePotency

-- The test file that built the host and its lines on the stack, innermost
-- first ('45<790': J.new in a helper at line 45, called by a case at 790).
local function test_site()
    local file, lines = nil, {}
    for level = 2, 60 do
        local info = debug.getinfo(level, 'Sl')
        if not info then break end
        local name = type(info.source) == 'string' and info.source:match('(test_[%w_]+%.lua)$')
        if name and (file == nil or name == file) and #lines < 4 then
            file = name
            lines[#lines + 1] = tostring(info.currentline)
        end
    end
    return file or '?', #lines > 0 and table.concat(lines, '<') or '0'
end

function J.install_invariants(h, user, host)
    local P = host.P
    local cfg = {}
    for _, kind in ipairs(J.INVARIANT_KINDS) do
        local u = type(user) == 'table' and user[kind] or nil
        if u == false then cfg[kind] = false else cfg[kind] = merged(J.INVARIANT_DEFAULTS[kind], u) end
    end
    local M = {hits = {}, config = cfg, pending_left = {}}
    h._inv, h.invariants = M, M
    M.test, M.site = test_site()
    M.runtime = rawget(_G, 'jit') and 'luajit' or tostring(_VERSION)
    M.env_log = os.getenv('QQT_INVARIANTS_LOG')
    M.env_log = M.env_log ~= '' and M.env_log or nil

    -- Every hit is appended to $QQT_INVARIANTS_LOG (tab separated: test,
    -- J.new line, runtime, kind, time, new|final, detail) when it is set.
    local function write_env(hit, final)
        if not M.env_log then return end
        local f = io.open(M.env_log, 'a')
        if not f then return end
        f:write(table.concat({M.test, tostring(M.site), M.runtime, hit.kind, string.format('%.1f', hit.t),
            final and 'final' or 'new', one_line(hit.detail)}, '\t'), '\n')
        f:close()
        hit.dirty = false
    end
    function M.hit(kind, detail, data)
        local hit = {kind = kind, t = h.now, detail = detail, data = data}
        M.hits[#M.hits + 1] = hit
        write_env(hit)
        return hit
    end
    local function revise(hit, detail)
        if hit.detail ~= detail then hit.detail, hit.dirty = detail, true end
    end
    local internal_seen = {}
    function M.internal(msg)
        msg = one_line(msg):sub(1, 300)
        if internal_seen[msg] then return end
        internal_seen[msg] = true
        M.hit('INTERNAL', 'monitor error (the monitor, not a plugin): ' .. msg)
    end

    -- Drawn status text per plugin, from the latest frame it drew in.
    local ov = {lines = {}, frame = {}}
    M.ov = ov
    function M.overlay(ctx, text)
        if not ctx or type(text) ~= 'string' then return end
        local name = ctx.name
        local lines = ov.lines[name]
        if ov.frame[name] ~= h.frames or not lines then
            lines = {}
            ov.lines[name], ov.frame[name] = lines, h.frames
        end
        if #lines < 4 then lines[#lines + 1] = text end
    end
    function M.current_tasks()
        local out = {}
        for _, rec in ipairs(h.plugins) do
            local modname = J.TASK_MODULES[rec.name]
            local tm = modname and rec.loaded[modname]
            if type(tm) == 'table' and type(tm.get_current_task) == 'function' then
                local ok, task = pcall(tm.get_current_task)
                if ok and type(task) == 'table' then
                    out[#out + 1] = {dir = rec.name, name = task.name, state = task.current_state, status = task.status}
                end
            end
        end
        local sr = h.by_dir.SilentRaven
        local tracker = sr and sr.loaded['silent_raven.tracker']
        if type(tracker) == 'table' and tracker.state ~= nil then
            out[#out + 1] = {dir = 'SilentRaven', state = tracker.state}
        end
        return out
    end
    function M.status_lines()
        local parts = {}
        for _, t in ipairs(M.current_tasks()) do
            local s = t.dir .. ' task=' .. tostring(t.name or '-')
            if t.state ~= nil then s = s .. ' state=' .. tostring(t.state) end
            if type(t.status) == 'string' and t.status ~= '' then s = s .. ' (' .. t.status .. ')' end
            parts[#parts + 1] = s
        end
        local names = {}
        for name in pairs(ov.lines) do names[#names + 1] = name end
        table.sort(names)
        for _, name in ipairs(names) do
            if h.frames - (ov.frame[name] or -1e9) <= 5 then
                parts[#parts + 1] = name .. ' drew "' .. table.concat(ov.lines[name], ' | '):sub(1, 160) .. '"'
            end
        end
        return table.concat(parts, '; ')
    end

    -- TELEPORT ---------------------------------------------------------------
    local tp = {calls = {}, origin = h.place, origin_t = h.now}
    M.tp = tp
    local function describe_calls()
        local out, first = {}, math.max(1, #tp.calls - 5)
        for i = first, #tp.calls do
            local c = tp.calls[i]
            out[#out + 1] = string.format('%s->%s by %s (ctx %s) t=%.1f', c.kind, tostring(c.dest), c.owner, c.context, c.t)
        end
        return string.format('%d teleport casts since arriving in %s at t=%.1f (max %d): %s%s', #tp.calls,
            tostring(tp.origin and tp.origin.key), tp.origin_t, cfg.TELEPORT.max, first > 1 and '... ' or '',
            table.concat(out, '; '))
    end
    local teleport
    -- Called from the host's teleport functions inside a plugin's callback:
    -- a monitor error must never reach the plugin.
    function M.teleport(kind, rec, dest)
        local ok, err = pcall(teleport, kind, rec, dest)
        if not ok then M.internal('teleport: ' .. tostring(err)) end
    end
    teleport = function(kind, rec, dest)
        local call = {kind = kind, t = h.now, owner = rec and rec.owner or '-', context = rec and rec.context or '-',
            dest = dest, from = h.place.key}
        tp.calls[#tp.calls + 1] = call
        if cfg.TELEPORT and #tp.calls > cfg.TELEPORT.max then
            if tp.hit then revise(tp.hit, describe_calls())
            else tp.hit = M.hit('TELEPORT', describe_calls(), {calls = tp.calls}) end
        end
        -- LEFT_DROP: a cast out of a place marks the drops Rosie still wants
        -- (checked at the end of the frame; reported only if left behind).
        if cfg.LEFT_DROP and h.place ~= P.limbo then
            M.pending_left[#M.pending_left + 1] = {place = h.place, pos = h.pos, why = kind .. ' by ' .. call.owner}
        end
    end
    local function arrive(place)
        if place == tp.origin then return end
        if tp.hit and tp.hit.dirty then write_env(tp.hit, true) end
        tp.calls, tp.hit, tp.origin, tp.origin_t = {}, nil, place, h.now
    end
    function M.on_travel(travel) M.travel_started = h.now; M.travel_why = travel and travel.why end

    -- LEFT_DROP --------------------------------------------------------------
    local left_seen = setmetatable({}, {__mode = 'k'})
    local marked = setmetatable({}, {__mode = 'k'}) -- item -> cast that found it wanted
    local function marked_mythic(item)
        for _, a in ipairs(type(item.affixes) == 'table' and item.affixes or {}) do
            if type(a) == 'table' and a.affix_name_hash == J.MYTHIC_MARK then return true end
        end
        return (tonumber(item.rarity) or 0) >= 8
    end
    local function evaluate(im, item)
        -- Host counters a test may assert on are restored; Rosie's own
        -- console output during the probe is muted.
        local reads, rays = h.item_count_reads, h.ray_casts
        h._mute_log = true
        local ok, wanted, reason = pcall(h.as, 'Rosie', function() return im.check_want_item(item, true) end)
        h._mute_log = nil
        h.item_count_reads, h.ray_casts = reads, rays
        if not ok then M.internal('LEFT_DROP check_want_item: ' .. tostring(wanted)); return false end
        return wanted == true, reason
    end
    local function rosie_pickup()
        local rec = h.by_dir.Rosie
        if not host.rosie or not rec then return nil end
        local master = h.checkboxes and h.checkboxes.Rosie_enabled
        if master and master.w:get() ~= true then return nil end
        local im, sm = rec.loaded['rosie.private.pickup.src.item_manager'], rec.loaded['rosie.private.pickup.src.settings']
        if type(im) ~= 'table' or type(im.check_want_item) ~= 'function' or type(sm) ~= 'table' then return nil end
        local ok, s = pcall(sm.get)
        if not ok or type(s) ~= 'table' or s.enabled ~= true then return nil end
        return im, s
    end
    M.left_open = {} -- LEFT_DROP hits whose drop may still be picked up on a return
    -- The host calls this when a travel channel completes, while the player
    -- still stands in the place it leaves.
    function M.departing(travel)
        local ok, err = pcall(M.check_left, h.place, h.pos,
            'leaving ' .. tostring(h.place.key) .. ' (' .. tostring(travel and travel.why) .. ')', 'leave')
        if not ok then M.internal('departing: ' .. tostring(err)) end
    end
    -- mode 'mark': a cast out of the place; 'leave': the place is left.
    function M.check_left(place, pos, why, mode)
        local c = cfg.LEFT_DROP
        if not c or not place or place == P.limbo or not pos or not place.items or #place.items == 0 then return end
        local im, s = rosie_pickup()
        if not im then return end
        local reach = math.min(c.radius, tonumber(s.distance) or c.radius)
        for _, item in ipairs(place.items) do
            if not item.picked and not left_seen[item] and not item.refuse and item.pos then
                local d = pos:dist_to_ignore_z(item.pos)
                local rarity = tonumber(item.rarity) or 0
                if d <= c.radius and (d <= reach or rarity >= 6) then
                    local wanted, reason = evaluate(im, item)
                    if wanted and mode == 'mark' then
                        marked[item] = marked[item] or string.format('%s at t=%.1f', why, h.now)
                    elseif wanted then
                        left_seen[item] = true
                        local age = item.dropped_at and (h.now - item.dropped_at) or nil
                        local during = item.dropped_at and M.travel_started and item.dropped_at >= M.travel_started
                        M.left_open[#M.left_open + 1] = M.hit('LEFT_DROP', string.format(
                            '%s left %s (sno=%s rarity=%s%s) %.1f m away in %s%s; Rosie: %s; pickup distance %s%s%s',
                            why, tostring(item.name), tostring(item.sno), tostring(item.rarity),
                            marked_mythic(item) and ' MYTHIC' or '', d, place.key,
                            age and string.format(', on the ground %.1f s', age) or '', tostring(reason),
                            tostring(s.distance), d > reach and ' (beyond it: Unique/Mythic within the radius)' or '',
                            (during and ' [dropped during the ' .. tostring(M.travel_why) .. ' channel]' or '')
                                .. (marked[item] and ' [already wanted at the cast: ' .. marked[item] .. ']' or '')),
                            {item = item, place = place.key, mythic = marked_mythic(item), during_channel = during})
                    end
                end
            end
        end
    end

    -- STALL ------------------------------------------------------------------
    local st = {next_poll = -math.huge, cmds = -1, cmd_t = -math.huge}
    M.st = st
    local function command_count()
        return #h.moves + #h.interactions + #h.vendors + #h.waypoints + #h.clicks + #h.keys + #h.warplans
            + #h.boss_tps + #h.items + #h.sigil_confirms + (h.engine and h.engine.calls or 0)
    end
    local function farm_on()
        local on = {}
        for _, dir in ipairs(cfg.STALL.farm) do
            local w = h.toggles[dir]
            if w and h.by_dir[dir] and w:get() == true then on[#on + 1] = dir end
        end
        return #on > 0 and on or nil
    end
    local function stall_end()
        local a = st.anchor
        if a and a.hit and a.hit.dirty then write_env(a.hit, true) end
        st.anchor = nil
    end
    local function stall_tick()
        local c = cfg.STALL
        if not c or h.now < st.next_poll then return end
        st.next_poll = h.now + c.poll
        local cmds = command_count()
        if cmds ~= st.cmds then st.cmds, st.cmd_t = cmds, h.now end
        local farm = farm_on()
        if h.dead or h.place == P.limbo or h.travel or not farm then return stall_end() end
        local a = st.anchor
        if not a or a.place ~= h.place or h.pos:dist_to_ignore_z(a.pos) >= c.move then
            stall_end()
            st.anchor = {pos = h.pos, t = h.now, place = h.place}
            return
        end
        if h.place.town and h.now - st.cmd_t > c.town_quiet then a.t = h.now; return end -- idle in town
        if h.now - a.t > c.seconds then
            local detail = string.format('player stood still at (%.1f, %.1f) in %s for %.0f s (since t=%.1f); farm on: %s; %s',
                a.pos:x(), a.pos:y(), h.place.key, h.now - a.t, a.t, table.concat(farm, ','), M.status_lines())
            if a.hit then revise(a.hit, detail) else a.hit = M.hit('STALL', detail) end
        end
    end

    -- SPAM and "state A -> B" lines -----------------------------------------
    local sp = {q = {}, hit = {}}
    M.sp = sp
    -- The plugin whose code printed the line: the first plugin frame above
    -- the host's console.print (plugins often print through a log wrapper).
    local function line_owner()
        for level = 3, 14 do
            local info = debug.getinfo(level, 'S')
            if not info then return nil end
            local rec = h.plugin_of_source(info.source)
            if rec then return rec end
        end
        return nil
    end
    function M.transition(src, from, to)
        local c = cfg.LOOP
        if not c or from == nil or to == nil or from == to then return end
        local cutoff = h.now - c.window
        local kept, count, first = {}, 1, h.now
        for _, e in ipairs(M.lp.trans[src] or {}) do
            if e.t >= cutoff then
                kept[#kept + 1] = e
                if (e.a == from and e.b == to) or (e.a == to and e.b == from) then
                    count = count + 1
                    if e.t < first then first = e.t end
                end
            end
        end
        kept[#kept + 1] = {t = h.now, a = from, b = to}
        M.lp.trans[src] = kept
        if count > c.max then
            local key = src .. '|' .. (from < to and (from .. '|' .. to) or (to .. '|' .. from))
            -- The mean dwell tells a thrash (a fraction of a second per state)
            -- from a plugin that alternates for a reason (fight, explore, ...).
            local detail = string.format('%s switches %s <-> %s %d times within %.0f s (t=%.1f..%.1f, mean dwell %.1f s)',
                src, from, to, count, c.window, first, h.now, (h.now - first) / math.max(1, count - 1))
            local hit = M.lp.hit[key]
            if not hit then hit = M.hit('LOOP', detail); hit.count = count; M.lp.hit[key] = hit
            elseif count > hit.count then hit.count = count; revise(hit, detail) end
        end
    end
    function M.line(msg)
        if type(msg) ~= 'string' then return end
        local ok, err = pcall(function()
            local c = cfg.SPAM
            if c then
                local key = mask_numbers(msg)
                local q = sp.q[key]
                if not q then q = {n = 0, head = 1}; sp.q[key] = q end
                q.n = q.n + 1
                q[q.n] = h.now
                local cutoff = h.now - c.window
                while q[q.head] < cutoff do q[q.head] = nil; q.head = q.head + 1 end
                local count = q.n - q.head + 1
                if count > c.max then
                    local hit = sp.hit[key]
                    if not hit then
                        local owner = line_owner()
                        hit = M.hit('SPAM', string.format('%d times within %.0f s (by %s, ctx %s): %s', count, c.window,
                            owner and owner.name or '-', h.context_name() or '-', key:sub(1, 200)))
                        hit.count, hit.key, hit.owner = count, key, owner and owner.name or '-'
                        sp.hit[key] = hit
                    elseif count > hit.count then
                        hit.count = count
                        revise(hit, string.format('%d times within %.0f s (by %s): %s', count, c.window, hit.owner,
                            key:sub(1, 200)))
                    end
                end
            end
            if cfg.LOOP and msg:find('->', 1, true) then
                local from, to = msg:match('[Ss]tate%s+([%w_%.:]+)%s*%->%s*([%w_%.:]+)')
                if from then
                    local owner = line_owner()
                    M.transition((owner and owner.name or '-') .. '.log', mask_numbers(from), mask_numbers(to))
                end
            end
        end)
        if not ok then M.internal('line: ' .. tostring(err)) end
    end

    -- LOOP polling -----------------------------------------------------------
    M.lp = {cur = {}, trans = {}, hit = {}, next_poll = -math.huge}
    function M.state(src, state)
        if state == nil then return end
        state = mask_numbers(state)
        local prev = M.lp.cur[src]
        if prev == state then return end
        M.lp.cur[src] = state
        if prev ~= nil then M.transition(src, prev, state) end
    end
    local function loop_tick()
        local c = cfg.LOOP
        if not c or h.now < M.lp.next_poll then return end
        M.lp.next_poll = h.now + c.poll
        for _, t in ipairs(M.current_tasks()) do
            if t.name ~= nil then M.state(t.dir .. '.task', tostring(t.name)) end
            if t.state ~= nil then M.state(t.dir .. '.state', tostring(t.state)) end
        end
        for _, dir in ipairs({'WarPigs', 'WarPug'}) do
            local lines = ov.lines[dir]
            if lines and lines[1] and h.frames - (ov.frame[dir] or -1e9) <= 1 then M.state(dir .. '.status', lines[1]) end
        end
        if h.place ~= P.limbo then M.state('world.place', h.place.key) end
    end

    -- frame end --------------------------------------------------------------
    M.last_place, M.last_pos = h.place, h.pos
    function M.tick()
        local ok, err = pcall(function()
            if #M.pending_left > 0 then
                local list = M.pending_left
                M.pending_left = {}
                for _, p in ipairs(list) do M.check_left(p.place, p.pos, p.why, 'mark') end
            end
            for i = #M.left_open, 1, -1 do
                local hit = M.left_open[i]
                local item = hit.data.item
                if item.picked then
                    table.remove(M.left_open, i)
                    revise(hit, hit.detail .. string.format(' [picked up later, back in %s by t=%.1f]', hit.data.place, h.now))
                    write_env(hit, true)
                elseif h.now - hit.t > 900 then
                    table.remove(M.left_open, i)
                end
            end
            if h.place ~= M.last_place then
                if h.place ~= P.limbo then arrive(h.place) end
                M.last_place = h.place
                if st.anchor then stall_end() end
            end
            M.last_pos = h.pos
            loop_tick()
            stall_tick()
        end)
        if not ok then M.internal('tick: ' .. tostring(err)) end
    end

    -- report -----------------------------------------------------------------
    function M.format(hits)
        local out = {}
        for i, hit in ipairs(hits) do
            out[#out + 1] = string.format('  %d. [%s] t=%.1f %s', i, hit.kind, hit.t, hit.detail)
        end
        return table.concat(out, '\n')
    end
    function M.report()
        if #M.hits == 0 then return 'invariants: no violation', M.hits end
        local counts, order = {}, {}
        for _, hit in ipairs(M.hits) do
            if not counts[hit.kind] then order[#order + 1] = hit.kind end
            counts[hit.kind] = (counts[hit.kind] or 0) + 1
        end
        local head = {}
        for _, kind in ipairs(order) do head[#head + 1] = kind .. '=' .. counts[kind] end
        return string.format('invariants: %d violation(s) (%s)\n%s', #M.hits, table.concat(head, ' '), M.format(M.hits)), M.hits
    end
    -- overrides[KIND] = false (ignore the kind) | N (allow up to N hits) |
    -- function(hit) -> true to ignore that hit. INTERNAL is never ignored.
    function M.filter(overrides)
        overrides = overrides or {}
        local left, allowed = {}, {}
        for _, hit in ipairs(M.hits) do
            local o = nil
            if hit.kind ~= 'INTERNAL' then o = overrides[hit.kind] end
            local skip = false
            if o == false then skip = true
            elseif type(o) == 'number' then
                allowed[hit.kind] = (allowed[hit.kind] or 0) + 1
                skip = allowed[hit.kind] <= o
            elseif type(o) == 'function' then skip = o(hit) and true or false end
            if not skip then left[#left + 1] = hit end
        end
        return left
    end
    return M
end

-- ── Universal Rotation stub (third-party combat plugin, no sources) ──────
-- While an enemy is within `range` m it casts every `cast_every` s at the
-- nearest one (dps * cast_every damage; the host's own reach-4 kill stays),
-- and on a cast with probability `move_chance` it dashes or evades 3-6 m
-- (toward or away from the target, stopping at walls / the place's edge).
-- `interrupt`: 'dash' (default) a dash breaks a Town Portal / waypoint
-- channel as in the game, 'cast' every cast does, false the rotation holds
-- still while the player channels. h.rotation = {casts, dashes, interrupts,
-- events = {{t, kind, detail}}}.
J.ROTATION_DEFAULTS = {range = 12, cast_every = 0.6, dps = 60, move_chance = 0.2, dash_min = 3, dash_max = 6,
    interrupt = 'dash'}
function J.install_rotation(h, user, host)
    local P = host.P
    local c = merged(J.ROTATION_DEFAULTS, user)
    local rng = J.rng(c.seed or host.seed)
    local R = {cfg = c, casts = 0, dashes = 0, interrupts = 0, events = {}, next_cast = -math.huge}
    h.rotation, h._rot = R, R
    local function note(kind, detail)
        if #R.events < 5000 then R.events[#R.events + 1] = {t = h.now, kind = kind, detail = detail} end
    end
    local function interrupt(why)
        local t = h.travel
        if t and t.phase == 'channel' then
            h.travel, h.casting = nil, false
            R.interrupts = R.interrupts + 1
            note('interrupt', why .. ' broke the ' .. tostring(t.why) .. ' channel')
        end
    end
    local atan2 = math.atan2 or math.atan
    function R.tick()
        if h.dead or h.place == P.limbo or (h.travel and h.travel.phase ~= 'channel') then return end
        if c.interrupt == false and h.casting then return end
        if h.now < R.next_cast then return end
        local best, bd
        for _, a in ipairs(h.place.actors) do
            if a.enemy and (a.health or 100) > 0 and a.pos then
                local d = a.pos:dist_to_ignore_z(h.pos)
                if d <= c.range and (not bd or d < bd) then best, bd = a, d end
            end
        end
        if not best then return end
        R.next_cast = h.now + c.cast_every
        R.casts = R.casts + 1
        note('cast', string.format('%s at %.1f m', tostring(best.skin), bd))
        if c.interrupt == 'cast' then interrupt('a skill cast') end
        if c.dps > 0 then
            best.health = (best.health or 100) - c.dps * c.cast_every
            if best.health <= 0 then
                best.health, best.interactable = 0, false
                if best.on_death then best.on_death(h, best) end
            end
        end
        if not rng.chance(c.move_chance) then return end
        local base = atan2(h.pos:y() - best.pos:y(), h.pos:x() - best.pos:x())
        local toward = rng.chance(0.5)
        if toward then base = base + math.pi end
        local ang, dist = base + rng.range(-0.8, 0.8), rng.range(c.dash_min, c.dash_max)
        local x0, y0 = h.pos:x(), h.pos:y()
        local ex, ey = x0, y0
        for i = 1, math.ceil(dist / 0.5) do
            local f = math.min(dist, i * 0.5)
            local nx, ny = x0 + math.cos(ang) * f, y0 + math.sin(ang) * f
            if not h.walkable(h.v(nx, ny)) then break end
            ex, ey = nx, ny
        end
        if ex == x0 and ey == y0 then return end
        h.pos = h.v(ex, ey)
        R.dashes = R.dashes + 1
        note('dash', string.format('%s %.1f m to (%.1f, %.1f)', toward and 'dash' or 'evade',
            math.sqrt((ex - x0) ^ 2 + (ey - y0) ^ 2), ex, ey))
        if c.interrupt then interrupt('an evade') end
    end
    return R
end

-- ── seeded chaos ──────────────────────────────────────────────────────────
-- J.new({chaos = {seed = N, rate = per_minute, kinds = {...}, only = {n...},
-- schedule = {{t = abs_time, kind = ..., <params>}...}, ...}}). Injections
-- arrive as a Poisson stream (`rate` per simulated minute, first one after
-- `start` s); the kind comes from the seed, every injection's details from
-- its own stream (seed, n), so `only = {3, 7}` keeps just injections 3 and 7
-- at the same times with the same draws (to bisect a failure; positions
-- that depend on where the player is follow the run). The same seed and
-- scenario replay the whole run exactly: chaos turns on the virtual
-- os.clock, and opts.ordered_pairs = true removes the other source of
-- run-to-run drift (pairs order). Channel drops: each travel channel (Town Portal,
-- waypoint, portal, War Plan) gets a drop inside it with probability
-- `channel_drop` (Rosie mode). Every injection (and every skip) is logged
-- as '<t> [chaos] seed=N #n kind: detail' in h.log and h.chaos.log;
-- h.chaos.replay() returns the J.new chaos table that replays the run.
-- Kinds: death (+ ClickRevive stand-in revive at the checkpoint after
-- `revive_after` s unless a plugin revived), drop (Mythic with probability
-- `mythic`), limbo (2-8 s), reload (one plugin's main.lua via h.reload),
-- bag_full, stash_lazy (stash full, first reads small), elite (a pack
-- 8-14 m away), obstacle (a wall across the path for 5-20 s).
J.CHAOS_KINDS = {'death', 'drop', 'limbo', 'reload', 'bag_full', 'stash_lazy', 'elite', 'obstacle'}
J.CHAOS_DEFAULTS = {rate = 1.0, start = 5, channel_drop = 0.35, mythic = 0.35, revive_after = 8,
    limbo_min = 2, limbo_max = 8, obstacle_min = 5, obstacle_max = 20, elite_min = 3, elite_max = 5,
    elite_health = 400, stash_small = 32, stash_full = 300, stash_window = 1.0, bag_size = 33}
local function chaos_affix(hash, name) return {affix_name_hash = hash, get_name = function() return name end} end
function J.install_chaos(h, user, host)
    local P = host.P
    local c = merged(J.CHAOS_DEFAULTS, type(user) == 'table' and user or {})
    local seed = math.floor(tonumber(c.seed) or 1)
    local master, chan = J.rng(seed), J.rng(seed + 7777)
    -- Injection n draws its details from its own stream, seeded with the
    -- n-th value of a seed stream: independent of whether injections before
    -- it ran (`only`), and not correlated between neighbours.
    local seed_stream, seeds = J.rng(seed + 31337), {}
    local function detail_seed(n)
        while #seeds < n do seeds[#seeds + 1] = math.floor(seed_stream.next() * 2147483646) + 1 end
        return seeds[n]
    end
    local kinds = c.kinds or J.CHAOS_KINDS
    local only
    if type(c.only) == 'table' then only = {}; for _, n in ipairs(c.only) do only[n] = true end end
    local C = {seed = seed, cfg = c, log = {}, n = 0}
    h.chaos, h._chaos = C, C
    local function line(n, kind, detail, skipped)
        local rec = {n = n, t = h.now, kind = kind, detail = detail, skipped = skipped or nil}
        C.log[#C.log + 1] = rec
        h.log[#h.log + 1] = string.format('%.1f [chaos] seed=%d #%d %s%s: %s', h.now, seed, n, kind,
            skipped and ' skipped' or '', tostring(detail))
        return rec
    end
    local I = {}
    function I.death(r, p, n)
        if h.dead then return nil, 'already dead' end
        if h.place == P.limbo or (h.travel and h.travel.phase == 'loading') then return nil, 'loading screen' end
        if h.place.town and not p.force then return nil, 'in town' end
        if h.travel and h.travel.phase == 'channel' then h.travel, h.casting = nil, false end
        h.dead, h.goal, h.native = true, nil, nil
        local after = p.revive_after or c.revive_after
        h.at(after, function()
            if h.dead and not h.reviving then
                h.invoke(h.chaos_ctx, 'update', function() h.G.revive_at_checkpoint() end)
                line(n, 'death', 'no plugin revived: ClickRevive stand-in revives at the checkpoint')
            end
        end)
        return string.format('player died at (%.1f, %.1f) in %s', h.pos:x(), h.pos:y(), h.place.key)
    end
    function I.drop(r, p)
        if not host.rosie or not h.drop then return nil, 'needs rosie = true (ground items)' end
        if h.place == P.limbo or (h.place.town and not p.force) then return nil, 'town or loading screen' end
        local mythic = p.mythic
        if mythic == nil then mythic = r.chance(c.mythic) end
        local ang, dist = r.range(0, 2 * math.pi), r.range(p.min or 2, p.max or 6)
        local x, y = h.pos:x() + math.cos(ang) * dist, h.pos:y() + math.sin(ang) * dist
        if not h.walkable(h.v(x, y)) then x, y, dist = h.pos:x(), h.pos:y(), 0 end
        local fields, label
        if mythic then
            fields = {name = 'Helm_Unique_Generic_005', sno = 2647147, rarity = 6, ancestral = true, ga = 1,
                affixes = {chaos_affix(2662414, 'Helm_Unique_Generic_005'), chaos_affix(J.MYTHIC_MARK, 'S14_Mythic_UniquePotency')}}
            label = 'Mythic (Leoric, S14_Mythic_UniquePotency)'
        elseif r.chance(0.5) then
            fields, label = {name = 'Helm_Legendary_Chaos', rarity = 5, ancestral = true, ga = 3}, 'Legendary GA3'
        else
            fields, label = {name = 'Helm_Rare_Joint', rarity = 3, ga = 0}, 'Rare'
        end
        local item = h.drop(h.place, x, y, fields)
        item.chaos = true
        return string.format('%s dropped %.1f m away at (%.1f, %.1f) in %s%s', label, dist, x, y, h.place.key,
            p.during_channel and h.travel and (' during the ' .. tostring(h.travel.why) .. ' channel') or '')
    end
    function I.limbo(r, p)
        if h.place == P.limbo or h.travel then return nil, 'already travelling' end
        local secs = p.seconds or r.range(c.limbo_min, c.limbo_max)
        local place, pos = h.place, h.pos
        h.place, h.pos, h.goal, h.native, h.vendor_screen = P.limbo, P.limbo.spawn, nil, nil, false
        h.at(secs, function()
            if h.place == P.limbo and not h.travel then h.place, h.pos = place, pos end
        end)
        return string.format('loading screen (Limbo) for %.1f s out of %s', secs, place.key)
    end
    function I.reload(r, p)
        if type(h.reload) ~= 'function' then return nil, 'host has no reload' end
        local dirs = p.dir and {p.dir} or c.reload_dirs or h.dirs
        local dir = dirs[r.int(1, #dirs)]
        if not h.by_dir[dir] then return nil, 'not loaded: ' .. tostring(dir) end
        h.reload(dir)
        return 'reloaded ' .. dir .. '/main.lua'
    end
    function I.bag_full(r, p)
        if host.rosie then
            if h.item_count ~= nil then h.item_count = c.bag_size; return 'bag count pinned at ' .. c.bag_size end
            h.inventory = h.inventory or {}
            local added = 0
            while #h.inventory < c.bag_size do
                h.inventory[#h.inventory + 1] = h.gear({name = 'Helm_Rare_Joint', rarity = 3}); added = added + 1
            end
            return string.format('bag filled to %d items (+%d rares)', #h.inventory, added)
        end
        h.alfred.inventory_full, h.alfred.need_trigger = true, true
        return 'Alfred stand-in reports inventory_full + need_trigger'
    end
    function I.stash_lazy(r, p)
        if not host.rosie then return nil, 'needs rosie = true (stash)' end
        h.stash = h.stash or {}
        local added = 0
        while #h.stash < (p.full or c.stash_full) do
            h.stash[#h.stash + 1] = h.gear({name = 'Helm_Rare_Joint', rarity = 3}); added = added + 1
        end
        h.stash_lazy = {small = p.small or c.stash_small, window = p.window or c.stash_window}
        return string.format('stash holds %d items (+%d); the first %.1f s after opening list only %d',
            #h.stash, added, h.stash_lazy.window, h.stash_lazy.small)
    end
    function I.elite(r, p)
        if h.place.town or h.place == P.limbo or not h.place.box then return nil, 'town or loading screen' end
        local count = p.count or r.int(c.elite_min, c.elite_max)
        local ang0, dist = r.range(0, 2 * math.pi), r.range(8, 14)
        local cx, cy = h.pos:x() + math.cos(ang0) * dist, h.pos:y() + math.sin(ang0) * dist
        local placed = 0
        for i = 1, count do
            local a = 2 * math.pi * i / count
            local x, y = cx + 1.5 * math.cos(a), cy + 1.5 * math.sin(a)
            if not h.walkable(h.v(x, y)) then x, y = h.pos:x() + math.cos(a) * 6, h.pos:y() + math.sin(a) * 6 end
            local e = h.actor(h.place, 'Chaos_Elite_Pack', x, y,
                {enemy = true, elite = true, health = c.elite_health, max_health = c.elite_health, chaos = true})
            e.on_death = function() h.remove_actor(e) end
            placed = placed + 1
        end
        return string.format('%d elites %.1f m away around (%.1f, %.1f) in %s', placed, dist, cx, cy, h.place.key)
    end
    function I.obstacle(r, p)
        if h.place == P.limbo or not h.place.box then return nil, 'loading screen' end
        local dx, dy
        if h.goal then dx, dy = h.goal:x() - h.pos:x(), h.goal:y() - h.pos:y() end
        if not dx or dx * dx + dy * dy < 1 then
            local ang = r.range(0, 2 * math.pi)
            dx, dy = math.cos(ang), math.sin(ang)
        end
        local len = math.sqrt(dx * dx + dy * dy)
        dx, dy = dx / len, dy / len
        local ahead, half = p.ahead or 3, (p.width or 10) / 2
        local cx, cy = h.pos:x() + dx * ahead, h.pos:y() + dy * ahead
        local wall
        if math.abs(dx) >= math.abs(dy) then wall = {cx - 0.5, cx + 0.5, cy - half, cy + half}
        else wall = {cx - half, cx + half, cy - 0.5, cy + 0.5} end
        local place = h.place
        local had = place.walls ~= nil
        place.walls = place.walls or {}
        place.walls[#place.walls + 1] = wall
        local secs = p.seconds or r.range(c.obstacle_min, c.obstacle_max)
        h.at(secs, function()
            for i = #(place.walls or {}), 1, -1 do if place.walls[i] == wall then table.remove(place.walls, i) end end
            if not had and place.walls and #place.walls == 0 then place.walls = nil end
        end)
        return string.format('wall x=[%.1f,%.1f] y=[%.1f,%.1f] across the path in %s for %.1f s',
            wall[1], wall[2], wall[3], wall[4], place.key, secs)
    end
    C.injectors = I
    function C.inject(kind, n, p)
        p = p or {}
        local fn = I[kind]
        if not fn then return line(n, kind, 'unknown kind', true) end
        local r = J.rng(detail_seed(n))
        local ok, detail, why = pcall(fn, r, p, n)
        if not ok then return line(n, kind, 'injector error: ' .. tostring(detail), true) end
        if detail == nil then return line(n, kind, why or 'not applicable now', true) end
        return line(n, kind, detail)
    end
    -- A scenario may inject by hand (same logging, next injection number).
    function h.chaos_inject(kind, p)
        C.n = C.n + 1
        return C.inject(kind, C.n, p)
    end
    local function gap() return -math.log(1 - master.next()) * 60 / math.max(c.rate, 1e-6) end
    local sched
    if type(c.schedule) == 'table' then
        sched = {}
        for i, e in ipairs(c.schedule) do sched[i] = e end
        table.sort(sched, function(a, b) return a.t < b.t end)
        C.sched_i = 1
    end
    function C.tick()
        if sched then
            while sched[C.sched_i] and h.now >= sched[C.sched_i].t do
                local e = sched[C.sched_i]
                C.sched_i = C.sched_i + 1
                C.n = math.max(C.n, e.n or C.n + 1)
                C.inject(e.kind, e.n or C.n, e)
            end
            return
        end
        if C.next_t == nil then C.next_t = h.now + c.start + gap() end
        while h.now >= C.next_t do
            local kind = master.pick(kinds)
            C.n = C.n + 1
            local n = C.n
            C.next_t = C.next_t + gap()
            if not only or only[n] then C.inject(kind, n) end
        end
    end
    function C.on_travel(travel, channel)
        if sched or not host.rosie or (c.channel_drop or 0) <= 0 then return end
        local allowed = false
        for _, k in ipairs(kinds) do if k == 'drop' then allowed = true end end
        if not allowed or h.place == P.limbo or h.place.town then return end
        if not chan.chance(c.channel_drop) then return end
        C.n = C.n + 1
        local n = C.n
        local delay = chan.range(0.1, 0.8) * channel
        if only and not only[n] then return end
        h.at(delay, function()
            if h.travel == travel and travel.phase == 'channel' then
                C.inject('drop', n, {during_channel = true, min = 1, max = 4})
            else
                line(n, 'drop', 'the channel ended before the drop', true)
            end
        end)
    end
    function C.replay()
        local ks = {}
        for _, k in ipairs(kinds) do ks[#ks + 1] = string.format('%q', k) end
        local parts = {string.format('seed = %d', seed), string.format('rate = %s', tostring(c.rate)),
            'kinds = {' .. table.concat(ks, ', ') .. '}'}
        for _, key in ipairs({'start', 'channel_drop', 'mythic', 'revive_after'}) do
            if c[key] ~= J.CHAOS_DEFAULTS[key] then parts[#parts + 1] = key .. ' = ' .. tostring(c[key]) end
        end
        return 'chaos = {' .. table.concat(parts, ', ') .. '}'
    end
    function C.summary()
        local out = {}
        for _, rec in ipairs(C.log) do
            out[#out + 1] = string.format('#%d t=%.1f %s%s: %s', rec.n, rec.t, rec.kind, rec.skipped and ' (skipped)' or '', rec.detail)
        end
        return table.concat(out, '\n')
    end
    return C
end

return J
