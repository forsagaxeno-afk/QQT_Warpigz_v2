-- QQT_Warpigz_v3 sweep S1: the owner's main setup, a Farm-mode Helltide.
-- REAL HelltideRevamped (Farm mode, defaults) + Batmobile + Rosie (pickup
-- and town, shipped defaults), the Universal Rotation stand-in and seeded
-- chaos, in the joint host with every invariant monitor on (TELEPORT,
-- LEFT_DROP, STALL, SPAM, LOOP; audit/tests/joint_host.lua).
--
-- The world (seeded, one stream per seed, independent of chaos):
--   * the UTC clock runs with the simulated time: the Helltide ends at :55
--     and the next hour's Helltide opens at :00 in the other zone (Dry
--     Steppes / jirandai loop, Kehjistan / ironwolfs loop, alternating);
--     every zone is the walkable box round its patrol loop;
--   * each hour: Helltide chests along the loop (75-150, Mystery 250, now
--     and then a Hell's Prize 666), ore / herb / shrine / goblin, and 3-5
--     Pandemonium ruptures that appear during the hour (cultists guard the
--     ring; their death opens 2-3 golden tears the player closes by standing
--     in them; the event pays cinders and leaves a free PandemoniumChest; a
--     Surging one also brings a Realmwalker);
--   * monster packs keep spawning round the player inside the Helltide; a
--     kill pays cinders and sometimes drops an item (Rare / Legendary /
--     Unique / Mythic) that Rosie picks up, so the bag fills and Rosie goes
--     to town with a Town Portal and comes back through it;
--   * deaths also happen inside rupture events (seeded), besides chaos.
-- Chaos (all kinds): death + ClickRevive stand-in, drops (also inside a
-- travel channel), Limbo, plugin reloads (widget values kept, as QQT keeps
-- them by hash), full bag, a full lazy stash, elite packs, walls.
--
-- Cinders held at :55 are lost (each hour's record: chests opened, cinders
-- lost, the cheapest chest left closed). The menu is closed while farming.
--
-- Default (the suite, both runtimes): seeds 7 and 11 from minute 54 across
-- the hour change, a forced Rosie trip 2.5 min into the new hour; every
-- invariant hit is classified (KNOWN / DESIGN / OPEN, the CLASSES table) and
-- an unclassified one fails. The sweep (one seed = world + chaos + rotation;
-- the same seed replays exactly):
--   QQT_SWEEP_SEEDS=1-20 QQT_SWEEP_HOURS=2 luajit -e "SUITE_ROOT='$PWD'" \
--       audit/tests/test_sweep_S1_helltide_farm.lua
-- (QQT_SWEEP_START_MIN pins the start minute; QQT_SWEEP_LOG=<prefix> writes
-- each seed's full log to <prefix>.<seed>.log; QQT_INVARIANTS_LOG=<file>
-- appends every hit, tab separated.)
-- Minimised findings (assert the correct behaviour, fail on 3.3.6):
--   QQT_SWEEP_REPRO=chest_pair|hour_end_tear|road_cost|all luajit ...
-- Runs under Lua 5.4 and LuaJIT.
SUITE_ROOT = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local J = dofile(SUITE_ROOT .. '/audit/tests/joint_host.lua')
local HR = 'HelltideRevamped'

local function env(name)
    local v = os.getenv(name)
    if v == nil or v == '' then return nil end
    return v
end
local function parse_seeds(s)
    local out = {}
    for part in tostring(s):gmatch('[^,%s]+') do
        local a, b = part:match('^(%d+)%-(%d+)$')
        if a then for i = tonumber(a), tonumber(b) do out[#out + 1] = i end
        elseif tonumber(part) then out[#out + 1] = tonumber(part) end
    end
    return out
end
local HEAVY = env('QQT_SWEEP_SEEDS') ~= nil
local SEEDS = HEAVY and parse_seeds(env('QQT_SWEEP_SEEDS')) or {7, 11}
local HOURS = tonumber(env('QQT_SWEEP_HOURS') or '') or (HEAVY and 2 or 0.18)
local START_MIN = tonumber(env('QQT_SWEEP_START_MIN') or '')
local LOG_FILE = env('QQT_SWEEP_LOG')

local checks, failures = 0, {}
local function ok(value, message)
    if not value then error(message or 'expected a true value', 2) end
    checks = checks + 1
end
local function case(name, fn)
    local started = os.clock()
    local passed, err = xpcall(fn, debug.traceback)
    if passed then print(string.format('PASS sweep-S1: %s (%.1fs)', name, os.clock() - started))
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL sweep-S1: ' .. name .. ': ' .. tostring(err)) end
end

-- ── patrol loops ──────────────────────────────────────────────────────────
local LOOPS = {}
local function loop_points(file)
    if LOOPS[file] then return LOOPS[file] end
    local f = assert(io.open(SUITE_ROOT .. '/HelltideRevamped/waypoints/' .. file .. '.lua', 'r'))
    local text = f:read('*a'); f:close()
    local pts = {}
    for x, y in text:gmatch('vec3:new%(%s*([%-%d%.]+)%s*,%s*([%-%d%.]+)%s*,%s*[%-%d%.]+%s*%)') do
        pts[#pts + 1] = {tonumber(x), tonumber(y)}
    end
    LOOPS[file] = pts
    return pts
end
-- The two Helltide zones used, alternating by UTC hour (place keys of the
-- joint host; their waypoints are HelltideRevamped's helltide_tps).
local ZONES = {
    {key = 'step', file = 'jirandai', name = 'Step_South'},
    {key = 'kehj', file = 'ironwolfs', name = 'Kehj_Oasis'},
}
local EPOCH0 = 1790481600 -- a UTC hour boundary

-- ── item templates ────────────────────────────────────────────────────────
local function affix(hash, name) return {affix_name_hash = hash, get_name = function() return name end} end
local function item_fields(r)
    local x = r.next()
    if x < 0.02 then
        return {name = 'Helm_Unique_Generic_005', sno = 2647147, rarity = 6, ancestral = true, ga = 1,
            affixes = {affix(2662414, 'Helm_Unique_Generic_005'), affix(J.MYTHIC_MARK, 'S14_Mythic_UniquePotency')}}, 'Mythic'
    elseif x < 0.10 then
        return {name = 'Helm_Unique_Generic_005', sno = 2647147, rarity = 6, ancestral = true, ga = 0,
            affixes = {affix(2662414, 'Helm_Unique_Generic_005')}}, 'Unique'
    elseif x < 0.40 then
        return {name = 'Helm_Legendary_Chaos', rarity = 5, ancestral = r.chance(0.6), ga = r.int(0, 3)}, 'Legendary'
    end
    return {name = 'Helm_Rare_Joint', rarity = 3, ga = 0}, 'Rare'
end

-- ── the world ─────────────────────────────────────────────────────────────
local function build(seed, o)
    o = o or {}
    local h = J.new({rosie = true, shipped_defaults = true, dirs = {'Batmobile', HR}, place = 'temis',
        ordered_pairs = true, invariants = true, reload_keeps_widgets = true, fast_globals = true,
        rotation = {seed = seed},
        chaos = o.chaos == false and nil or {seed = seed, rate = o.rate or 1.0,
            -- a drop inside a travel channel only where something is killed
            -- or opened: the active Helltide (not the zones a scan passes)
            channel_drop_if = function(hh) return hh.place.helltide == true end}})
    local r = J.rng(seed * 7919 + 17)
    -- The menu is closed while farming (tree nodes collapsed): the plugins'
    -- menu callbacks still run every frame but draw no widget lists.
    h.menu_open = false
    local W = {h = h, r = r, seed = seed, stats = {kills = 0, drops = 0, chests = 0, ruptures = 0, tears = 0,
        rw = 0, event_deaths = 0, hours = 0, cinders_paid = 0, hells_prize = 0, mystery = 0}, hour = nil,
        zone = nil, rupts = {}, packs = 0, next_pack = 0}
    h.world = W
    -- Zones: the walkable box round each patrol loop, the spawn (revive
    -- checkpoint, waypoint landing) on the loop's first point.
    for _, z in ipairs(ZONES) do
        local pts = loop_points(z.file)
        local x1, x2, y1, y2 = math.huge, -math.huge, math.huge, -math.huge
        for _, p in ipairs(pts) do
            x1, x2 = math.min(x1, p[1]), math.max(x2, p[1])
            y1, y2 = math.min(y1, p[2]), math.max(y2, p[2])
        end
        local place = h.P[z.key]
        place.box = {x1 - 45, x2 + 45, y1 - 45, y2 + 45}
        place.spawn = h.v(pts[1][1], pts[1][2])
        place.helltide = false
        z.pts, z.place = pts, place
    end
    -- Every other Helltide zone of the host is quiet this session (the
    -- joint host's 'helltide' place carries the buff by default).
    for _, key in ipairs({'helltide', 'frac', 'scos'}) do h.P[key].helltide = false end
    -- Clock: UTC follows the simulated time (HR's hr_clock, os.date('!%M'),
    -- os.time()); a reloaded HR gets the same hook again.
    local start_min = o.start_min or START_MIN or r.int(3, 58)
    W.t0 = h.now
    W.epoch0 = EPOCH0 + start_min * 60 + r.int(0, 59)
    function W.epoch(t) return W.epoch0 + ((t or h.now) - W.t0) end
    W.clock = function() return math.floor(W.epoch()) end
    h.G.os.time = function(t)
        if t ~= nil then return os.time(t) end
        return math.floor(W.epoch())
    end
    local function sync_clock(t)
        h.minute = math.floor(W.epoch(t) / 60) % 60
        local clk = h.mod(HR, 'core.hr_clock')
        if clk and clk._now ~= W.clock then clk._now = W.clock end
    end
    sync_clock()

    local function in_zone() return W.zone and h.place == W.zone.place end
    local function drop_at(x, y, why, r2)
        local fields, label = item_fields(r2 or r)
        if not h.walkable(h.v(x, y)) then x, y = h.pos:x(), h.pos:y() end
        local item = h.drop(h.place, x, y, fields)
        item.world = why
        W.stats.drops = W.stats.drops + 1
        return item, label
    end
    local function burst(x, y, n, why)
        for _ = 1, n do
            local a, d = r.range(0, 2 * math.pi), r.range(0.5, 3)
            drop_at(x + math.cos(a) * d, y + math.sin(a) * d, why)
        end
    end
    local function pay(n) h.cinders = h.cinders + n; W.stats.cinders_paid = W.stats.cinders_paid + n end
    local function loop_pt(z, i) local p = z.pts[((i - 1) % #z.pts) + 1]; return p[1], p[2] end
    local function near_loop(z, i, side)
        local x, y = loop_pt(z, i)
        local nx, ny = loop_pt(z, i + 3)
        local dx, dy = nx - x, ny - y
        local len = math.max(0.01, math.sqrt(dx * dx + dy * dy))
        return x - dy / len * side, y + dx / len * side
    end
    local function actor_xy(skin, x, y, fields)
        local a = h.actor(W.zone.place, skin, x, y, fields)
        -- chests are routed to as points (navigate_to treats tables as points)
        function a:x() return self.pos:x() end
        function a:y() return self.pos:y() end
        function a:z() return self.pos:z() end
        function a:dist_to(p) return self.pos:dist_to(p) end
        a.hour = W.hour
        return a
    end

    -- Helltide chests of the hour.
    local costs = h.mod(HR, 'data.enums').chest_types
    local regular = {'usz_rewardGizmo_1H', 'usz_rewardGizmo_2H', 'usz_rewardGizmo_ChestArmor', 'usz_rewardGizmo_Rings',
        'usz_rewardGizmo_Amulet', 'usz_rewardGizmo_Gloves', 'usz_rewardGizmo_Legs', 'usz_rewardGizmo_Boots',
        'usz_rewardGizmo_Helm', 'Helltide_RewardChest_Random'}
    local function chest(skin, z, i, side)
        local x, y = near_loop(z, i, side)
        local c = actor_xy(skin, x, y)
        c.cost = costs[skin]
        c.on_interact = function()
            if c.interactable == false or h.cinders < c.cost then return end
            h.cinders = h.cinders - c.cost
            c.interactable = false
            W.stats.chests = W.stats.chests + 1
            if skin == 'usz_rewardGizmo_Uber' then W.stats.mystery = W.stats.mystery + 1 end
            if skin == 'Warplan_Helltide_HellsPrize' then W.stats.hells_prize = W.stats.hells_prize + 1 end
            h.at(0.8, function() burst(c.pos:x(), c.pos:y(), skin == 'Warplan_Helltide_HellsPrize' and 5 or 3, 'chest') end)
        end
        return c
    end

    -- A Pandemonium rupture: cultists guard the ring; their death opens the
    -- golden tears; standing in a tear (1.3 m) for `close` s closes it; the
    -- last one completes the event (cinders, a free chest, maybe a Realmwalker).
    local function rupture(z, i)
        local cx, cy = near_loop(z, i, r.range(-12, 12))
        local R = {cx = cx, cy = cy, phase = 'guards', tears = {}, cultists = {}, actors = {}, surging = r.chance(0.35),
            hour = W.hour, born = h.now}
        local function add(a) R.actors[#R.actors + 1] = a; return a end
        add(actor_xy('S14_Rupture_SMP_SwitchGizmo', cx, cy))
        add(actor_xy('S14_PandemoniumCrack_gizmo_holdArea', cx, cy))
        local alive = r.int(2, 4)
        local function open()
            R.phase = 'open'
            h.log[#h.log + 1] = string.format('%.1f [world] rupture #%d at (%.1f, %.1f) opens', h.now, R.n, cx, cy)
            R.marker = add(actor_xy('S14_Rupture_SMP_ActiveUIMarker', cx, cy))
            for k = 1, r.int(2, 3) do
                local a, d = r.range(0, 2 * math.pi), r.range(3, 8)
                local t = add(actor_xy('S14_Rupture_SMP_Chargeable', cx + math.cos(a) * d, cy + math.sin(a) * d))
                t.need, t.charge = r.range(4, 9), 0
                R.tears[#R.tears + 1] = t
            end
            -- a wave of monsters round the ring
            for k = 1, r.int(3, 5) do
                local a = r.range(0, 2 * math.pi)
                local m = add(actor_xy('S14_Rupture_Wave_Monster', cx + math.cos(a) * 7, cy + math.sin(a) * 7,
                    {enemy = true, health = 120, max_health = 120}))
                m.on_death = function() h.remove_actor(m); W.stats.kills = W.stats.kills + 1; pay(r.int(3, 8)) end
            end
            -- a death inside the event (seeded)
            if r.chance(o.event_death or 0.5) then
                R.death_at = h.now + r.range(3, 25)
            end
        end
        for k = 1, alive do
            local a = 2 * math.pi * k / alive
            local c = add(actor_xy('S14_cultist_Spearman', cx + math.cos(a) * 5, cy + math.sin(a) * 5,
                {enemy = true, health = 150, max_health = 150}))
            c.on_death = function()
                h.remove_actor(c)
                alive = alive - 1
                W.stats.kills = W.stats.kills + 1
                pay(r.int(5, 10))
                if alive <= 0 and R.phase == 'guards' then open() end
            end
            R.cultists[#R.cultists + 1] = c
        end
        function R.tick(dt)
            if R.phase == 'open' then
                if R.death_at and h.now >= R.death_at then
                    R.death_at = nil
                    if not h.dead and h.place == z.place and h.pos:dist_to_ignore_z(h.v(cx, cy)) <= 30 then
                        W.stats.event_deaths = W.stats.event_deaths + 1
                        h.chaos_inject('death')
                    end
                end
                local left = 0
                for _, t in ipairs(R.tears) do
                    if not t.closed then
                        if h.place == z.place and not h.dead and h.pos:dist_to_ignore_z(t.pos) <= 1.3 then
                            t.charge = t.charge + dt
                        end
                        if t.charge >= t.need then
                            t.closed = true
                            h.remove_actor(t)
                            W.stats.tears = W.stats.tears + 1
                            pay(r.int(15, 30))
                        else
                            left = left + 1
                        end
                    end
                end
                if left == 0 then
                    R.phase = 'done'
                    h.log[#h.log + 1] = string.format('%.1f [world] rupture #%d at (%.1f, %.1f) complete%s', h.now, R.n,
                        cx, cy, R.surging and ' (Surging: a Realmwalker follows)' or '')
                    W.stats.ruptures = W.stats.ruptures + 1
                    if R.marker then h.remove_actor(R.marker) end
                    pay(r.int(100, 220))
                    local ch = add(actor_xy('S14_Rupture_SMP_PandemoniumChest', cx + 1, cy + 1))
                    ch.on_interact = function()
                        if ch.interactable == false then return end
                        ch.interactable = false
                        h.at(0.8, function() burst(ch.pos:x(), ch.pos:y(), 3, 'rupture chest') end)
                    end
                    if R.surging then
                        h.at(r.range(3, 12), function()
                            if W.zone ~= z then return end
                            local rw = add(actor_xy('S14_Golem_Stone_Realmwalker', cx + 10, cy,
                                {enemy = true, boss = true, health = 700, max_health = 700}))
                            rw.on_death = function()
                                h.remove_actor(rw)
                                W.stats.rw = W.stats.rw + 1
                                pay(r.int(120, 200))
                                burst(rw.pos:x(), rw.pos:y(), 3, 'realmwalker')
                            end
                        end)
                    end
                end
            end
        end
        W.rupts[#W.rupts + 1] = R
        R.n = #W.rupts
        h.log[#h.log + 1] = string.format('%.1f [world] rupture #%d appears at (%.1f, %.1f), %d cultists', h.now, R.n,
            cx, cy, alive)
        return R
    end

    -- Monster packs round the player inside the active Helltide.
    local function pack()
        local n = r.int(3, 6)
        local a0, d0 = r.range(0, 2 * math.pi), r.range(8, 22)
        local cx, cy = h.pos:x() + math.cos(a0) * d0, h.pos:y() + math.sin(a0) * d0
        for k = 1, n do
            local a = 2 * math.pi * k / n
            local x, y = cx + math.cos(a) * 2, cy + math.sin(a) * 2
            if h.walkable(h.v(x, y)) then
                local hp = r.range(60, 160)
                local m = actor_xy(r.chance(0.1) and 'Helltide_Elite_Monster' or 'Helltide_Trash_Monster', x, y,
                    {enemy = true, health = hp, max_health = hp, elite = false, pack = true})
                m.on_death = function()
                    h.remove_actor(m)
                    W.stats.kills = W.stats.kills + 1
                    pay(r.int(2, 7))
                    if r.chance(0.18) then drop_at(m.pos:x(), m.pos:y(), 'kill') end
                end
            end
        end
        W.packs = W.packs + 1
    end
    local function prune_monsters()
        local place = W.zone.place
        for i = #place.actors, 1, -1 do
            local a = place.actors[i]
            if a.pack and a.pos:dist_to_ignore_z(h.pos) > 90 then table.remove(place.actors, i) end
        end
    end

    function W.open_hour(hour)
        local z = ZONES[(math.floor(hour / 3600) % #ZONES) + 1]
        W.hour, W.zone = hour, z
        W.stats.hours = W.stats.hours + 1
        z.place.helltide = true
        z.place.actors = {}
        W.rupts = {}
        local n = #z.pts
        local base = r.int(1, n)
        for k = 1, r.int(5, 8) do chest(regular[r.int(1, #regular)], z, base + r.int(0, n), r.range(-25, 25)) end
        for k = 1, r.int(1, 2) do chest('usz_rewardGizmo_Uber', z, base + r.int(0, n), r.range(-20, 20)) end
        if r.chance(0.5) then chest('Warplan_Helltide_HellsPrize', z, base + r.int(0, n), r.range(-15, 15)) end
        for _, skin in ipairs({'HarvestNode_Ore_Joint', 'HarvestNode_Herb_Joint', 'Shrine_Joint_Artillery'}) do
            for k = 1, r.int(1, 3) do
                local x, y = near_loop(z, base + r.int(0, n), r.range(-6, 6))
                local a = actor_xy(skin, x, y)
                a.on_interact = function() a.interactable = false end
            end
        end
        -- ruptures appear during the hour (the first soon after the start)
        local count = r.int(3, 5)
        W.rupt_plan = {}
        for k = 1, count do
            W.rupt_plan[#W.rupt_plan + 1] = {min = (k == 1) and 1 or r.int(2, 48), i = base + r.int(0, n)}
        end
        h.log[#h.log + 1] = string.format('%.1f [world] Helltide hour opens in %s (%d chests, %d ruptures planned)',
            h.now, z.name, #z.place.actors, count)
    end
    function W.close_hour()
        local z = W.zone
        if not z then return end
        z.place.helltide = false
        -- The cinders held at the end are lost (the game resets them); the
        -- hour record keeps them with the cheapest chest still closed.
        local cheapest, opened = nil, 0
        for _, a in ipairs(z.place.actors) do
            if a.cost and a.hour == W.hour then
                if a.interactable == false then opened = opened + 1
                elseif not cheapest or a.cost < cheapest then cheapest = a.cost end
            end
        end
        W.hours = W.hours or {}
        W.hours[#W.hours + 1] = {zone = z.name, lost = h.cinders, opened = opened, cheapest = cheapest,
            place = h.place.key}
        h.log[#h.log + 1] = string.format('%.1f [world] Helltide hour ends in %s: %d chest(s) opened, %d cinders lost'
            .. ' (cheapest closed chest %s), player in %s', h.now, z.name, opened, h.cinders, tostring(cheapest), h.place.key)
        h.cinders = 0
        -- the Helltide's chests, ruptures and monsters go with it
        local keep = {}
        for _, a in ipairs(z.place.actors) do if not a.hour then keep[#keep + 1] = a end end
        z.place.actors = keep
        W.rupts, W.rupt_plan = {}, {}
        W.zone = nil
    end

    function W.tick(dt)
        local e = W.epoch()
        local minute = math.floor(e / 60) % 60
        local hour = math.floor(e / 3600) * 3600
        if W.zone and (minute >= 55 or hour ~= W.hour) then W.close_hour() end
        if not W.zone and minute < 55 and W.opened_hour ~= hour then
            W.opened_hour = hour
            W.open_hour(hour)
        end
        if not W.zone then return end
        for _, p in ipairs(W.rupt_plan or {}) do
            if not p.done and minute >= p.min then p.done = true; rupture(W.zone, p.i) end
        end
        for _, R in ipairs(W.rupts) do R.tick(dt) end
        if in_zone() and not h.dead and h.now >= W.next_pack then
            W.next_pack = h.now + r.range(12, 30)
            prune_monsters()
            pack()
        end
        if in_zone() and r.chance(0.0004) then
            local a0 = r.range(0, 2 * math.pi)
            local g = actor_xy('treasure_goblin', h.pos:x() + math.cos(a0) * 15, h.pos:y() + math.sin(a0) * 15,
                {enemy = true, health = 250, max_health = 250})
            g.on_death = function() h.remove_actor(g); burst(g.pos:x(), g.pos:y(), 3, 'goblin') end
        end
    end

    -- o.bag_at: the bag is filled (30 rares) this many seconds after the
    -- start, wherever the player is (the default run's Rosie trip).
    if o.bag_at then
        h.at(o.bag_at, function()
            h.inventory = h.inventory or {}
            while #h.inventory < 30 do h.inventory[#h.inventory + 1] = h.gear({name = 'Helm_Rare_Joint', rarity = 3}) end
            h.log[#h.log + 1] = string.format('%.1f [world] bag filled to %d items', h.now, #h.inventory)
        end)
    end

    local base_frame = h.frame
    h.frame = function(dt)
        sync_clock(h.now + (dt or 0.1))
        base_frame(dt)
        W.tick(dt or 0.1)
    end
    return h, W
end

-- ── one seeded run ────────────────────────────────────────────────────────
local function setup(seed, o)
    local h, W = build(seed, o)
    h.assert_clean('load')
    local rp = h.mod('Rosie', 'rosie.private.pickup.gui').elements
    rp.general.distance_slider:set(12)
    ok(h.as('Rosie', function() return h.G.RosiePlugin.enable() end) == true, 'Rosie enabled')
    local e = h.mod(HR, 'gui').elements
    e.mode:set(1)
    e.main_toggle:set(true)
    return h, W
end

local function hour_lines(W)
    local out = {}
    for i, r in ipairs(W.hours or {}) do
        out[#out + 1] = string.format('\n  hour %d %s: %d chest(s) opened, %d cinders lost at :55 (cheapest closed chest %s)%s',
            i, r.zone, r.opened, r.lost, tostring(r.cheapest),
            (r.cheapest and r.lost >= r.cheapest) and ' <- an affordable chest was left' or '')
    end
    return table.concat(out)
end

local function summary(h, W)
    local s = W.stats
    return string.format('seed=%d start=%s hours=%d kills=%d drops=%d pickups=%d chests=%d (mystery %d, prize %d) ruptures=%d tears=%d rw=%d'
        .. ' event_deaths=%d cinders=%d paid=%d trips=%d salvaged=%d stashed=%d rot(casts=%d dashes=%d interrupts=%d) chaos=%d errors=%d',
        W.seed, os.date('!%M:%S', W.epoch0), s.hours, s.kills, s.drops, h.pickups or 0, s.chests, s.mystery, s.hells_prize,
        s.ruptures, s.tears, s.rw, s.event_deaths, h.cinders, s.cinders_paid, h.logged('[Rosie] completed'), #h.salvaged,
        #h.stashed, h.rotation.casts, h.rotation.dashes, h.rotation.interrupts, #h.chaos.log, #h.errors)
        .. hour_lines(W)
end

local function run_seed(seed, hours, o)
    local h, W = setup(seed, o)
    local t_end = h.now + hours * 3600
    local started = os.clock()
    -- (h.now accumulates 0.1 s steps: stop within half a frame of the end,
    -- a remainder below h.run's 1e-9 slack would never advance)
    while h.now < t_end - 0.05 do h.run(math.min(60, t_end - h.now)) end
    local report = h.invariant_report()
    if LOG_FILE then
        local f = io.open(LOG_FILE .. '.' .. seed .. '.log', 'w')
        if f then f:write(table.concat(h.log, '\n'), '\n'); f:close() end
    end
    return h, W, report, os.clock() - started
end

-- ── classification of invariant hits ──────────────────────────────────────
-- KNOWN: reported before this sweep (the harness commit's table, the known
-- issues being fixed); DESIGN: the monitor's threshold, not a defect;
-- OPEN: found by this sweep and on the BOARD (the minimised repro below);
-- anything else is NEW and fails the default run.
local CLASSES = {
    {'KNOWN', 'HR debug logging without a switch (LOW)', function(hit)
        return hit.kind == 'SPAM' and hit.detail:find('by HelltideRevamped', 1, true) ~= nil
            and (hit.detail:find(': [PATROL]', 1, true) or hit.detail:find(': [NAV]', 1, true)
                or hit.detail:find(': [CHEST RECALL]', 1, true) or hit.detail:find(': [HR SPIKE]', 1, true)
                or hit.detail:find(': [CHECK_EVENTS]', 1, true)) ~= nil
    end},
    {'KNOWN', 'Batmobile [nav] STUCK log rate (LOW)', function(hit)
        return hit.kind == 'SPAM' and hit.detail:find('[nav] STUCK', 1, true) ~= nil
    end},
    {'KNOWN', 'Rosie Town Portal re-cast (known re-cast / refund-cap family)', function(hit)
        if hit.kind ~= 'TELEPORT' then return false end
        for owner in hit.detail:gmatch('%->[%w_]+ by ([%w_%-]+) %(ctx') do
            if owner ~= 'Rosie' then return false end
        end
        return hit.detail:find('town_portal->temis by Rosie', 1, true) ~= nil
    end},
    {'KNOWN', 'Rosie Town Portal cast while a drop falls (known: Mythic during the cast)', function(hit)
        return hit.kind == 'LEFT_DROP' and hit.detail:find('cast by Rosie', 1, true) ~= nil
            and hit.detail:find('[dropped during the', 1, true) ~= nil
    end},
    {'KNOWN', 'Rosie trip starts with a wanted drop on the ground (harness commit finding)', function(hit)
        return hit.kind == 'LEFT_DROP' and hit.detail:find('already wanted at the cast: town_portal by Rosie', 1, true) ~= nil
    end},
    {'OPEN', 'F1 HR rupture chest pair: spot / "opened" loop (repro chest_pair)', function(hit)
        return (hit.kind == 'LOOP' and hit.detail:find('RIFT_OPEN_CHEST', 1, true) ~= nil)
            or (hit.kind == 'SPAM' and hit.detail:find('by HelltideRevamped', 1, true) ~= nil
                and (hit.detail:find('Pandemonium chest spotted', 1, true) or hit.detail:find('Rupture_SMP_PandemoniumChest', 1, true)) ~= nil)
            or (hit.kind == 'STALL' and hit.detail:find('RIFT_OPEN_CHEST', 1, true) ~= nil)
    end},
    {'OPEN', 'F2 HR :55 teleport right after its own tear-event pickup pause (repro hour_end_tear)', function(hit)
        return hit.kind == 'LEFT_DROP' and hit.detail:find('cast by HelltideRevamped', 1, true) ~= nil
            and hit.detail:find('[dropped during the', 1, true) == nil
    end},
    {'DESIGN', 'fight / patrol alternation (mean dwell >= 3 s)', function(hit)
        local dwell = tonumber(hit.detail:match('mean dwell ([%d%.]+) s'))
        return hit.kind == 'LOOP' and dwell ~= nil and dwell >= 3 and hit.detail:find('KILL_MONSTERS', 1, true) ~= nil
            and hit.detail:find('EXPLORE_HELLTIDE', 1, true) ~= nil
    end},
}
local function classify(hit)
    for _, c in ipairs(CLASSES) do
        if c[3](hit) then return c[1], c[2] end
    end
    return 'NEW', hit.kind
end

-- ── minimised repros of this sweep's findings ─────────────────────────────
-- QQT_SWEEP_REPRO=<name>[,<name>...] | all runs them instead of the seeds.
-- Each asserts the CORRECT behaviour, so it fails on the code the finding
-- was made on and passes once the owning session has fixed it. They are
-- not part of the default run (the fixes belong to other sessions).
local REPRO, REPRO_ORDER = {}, {}
local function repro(name, fn) REPRO[name] = fn; REPRO_ORDER[#REPRO_ORDER + 1] = name end

-- A standalone Farm-mode HR + Rosie at a Pandemonium rupture on the Hawezar
-- loop (the host's 'helltide' place), as in test_helltide_tears_joint.
local function rupture_host(o)
    o = o or {}
    local h = J.new({rosie = true, dirs = {'Batmobile', HR}, place = 'helltide', ordered_pairs = true,
        invariants = true, minute = o.minute or 10})
    h.mod(HR, 'core.hr_clock')._now = function() return EPOCH0 + h.minute * 60 + math.floor(h.now) % 60 end
    h.assert_clean('load')
    h.mod('Rosie', 'rosie.private.pickup.gui').elements.general.distance_slider:set(o.distance or 12)
    ok(h.as('Rosie', function() return h.G.RosiePlugin.enable() end) == true, 'Rosie enabled')
    local e = h.mod(HR, 'gui').elements
    e.mode:set(1)
    e.main_toggle:set(true)
    h.pos = h.v(-600, 300)
    local ring = h.v(-585, 300)
    h.actor('helltide', 'S14_Rupture_SMP_SwitchGizmo', ring:x(), ring:y())
    h.actor('helltide', 'S14_PandemoniumCrack_gizmo_holdArea', ring:x(), ring:y())
    local tear = h.actor('helltide', 'S14_Rupture_SMP_Chargeable', ring:x() + 2, ring:y() + 1)
    return h, ring, tear, h.mod(HR, 'tasks.helltide')
end
local function chest_actor(h, skin, x, y)
    local c = h.actor('helltide', skin, x, y)
    c.on_interact = function()
        if c.interactable == false then return end
        c.interactable = false
        c.opened_at = h.now
    end
    return c
end

-- F1 (HelltideRevamped, core/hr_tear_event.lua RIFT_OPEN_CHEST): two
-- Pandemonium chests within 10 m of each other. The first is opened; the
-- second is spotted, but find_rift_chest_actor(name, pos) resolves the
-- target as the same-skin actor NEAREST THE PLAYER within 10 m of the
-- spotted position: the opened one the player stands at. It reads "opened",
-- and the second chest is spotted again 2.9 s later, for as long as the
-- rupture state lasts (sweep seed 3: 82 s, until the Helltide hour ended).
repro('chest_pair', function()
    local h, ring, tear, task = rupture_host()
    ok(h.run_until(function()
        return task.current_state == 'RIFT_CLOSE_TEARS' and h.pos:dist_to(tear.pos) <= 1.05
    end, 30), 'HR stands in the tear\n' .. h.tail(30))
    h.run(3)
    h.remove_actor(tear) -- the tear closes: the event pays out two chests
    local a = chest_actor(h, 'S14_Rupture_SMP_PandemoniumChest', ring:x() + 1, ring:y() + 1)
    local b = chest_actor(h, 'S14_Rupture_SMP_PandemoniumChest', ring:x() + 9, ring:y() + 3)
    h.run(60)
    h.assert_clean('chest pair')
    print(string.format('  chest A opened=%s, chest B opened=%s, "Pandemonium chest spotted" x%d, "opened" x%d',
        tostring(a.opened_at ~= nil), tostring(b.opened_at ~= nil), h.logged('Pandemonium chest spotted'),
        h.logged('PandemoniumChest opened')))
    ok(a.opened_at ~= nil, 'the first chest is opened\n' .. h.tail(30))
    ok(b.opened_at ~= nil, 'the second chest 8 m away is opened too (spotted '
        .. h.logged('Pandemonium chest spotted') .. ' times)\n' .. h.tail(12))
    ok(h.logged('Pandemonium chest spotted') <= 4, 'no spot/"opened" loop: '
        .. h.logged('Pandemonium chest spotted') .. ' spots in 60 s')
end)

-- F2 (HelltideRevamped: tear-event pickup pause x search_helltide idle
-- teleport at :55): a wanted drop lands while HR holds Rosie's pickup for
-- the tear event. At minute 55 the Helltide ends: HR releases its own pause
-- ("Looter pickup resumed (stopped)") and search_helltide teleports to town
-- in the same tick; loot_hold() (HLT-8) sees a Looter that is not busy yet
-- (it was paused a moment ago) and does not wait. The drop HR's own pause
-- held back is left in the Helltide (sweep seed 3, t=1544: a Legendary GA3
-- 5.8 m away, on the ground 24.5 s). has_pending_loot() does not cover it
-- either (a fight wait only).
repro('hour_end_tear', function()
    local h, ring, tear, task = rupture_host({minute = 54})
    ok(h.run_until(function()
        return task.current_state == 'RIFT_CLOSE_TEARS' and h.pos:dist_to(tear.pos) <= 1.05
    end, 30), 'HR stands in the tear\n' .. h.tail(30))
    local drop = h.drop('helltide', h.pos:x() + 4, h.pos:y() + 3,
        {name = 'Helm_Legendary_Chaos', rarity = 5, ancestral = true, ga = 3})
    h.run(5)
    ok(not drop.picked, 'held back by the tear-event pause')
    h.minute = 55
    h.P.helltide.helltide = false -- the Helltide hour ends
    local left_at
    h.run(40, function() if not left_at and h.place ~= h.P.helltide then left_at = h.now end end)
    h.assert_clean('hour end in a tear')
    print(string.format('  drop picked=%s; left the Helltide %.1f s after :55', tostring(drop.picked == true),
        (left_at or h.now) - (h.now - 40)))
    ok(drop.picked == true, 'the drop the tear pause held back is picked up before the :55 teleport\n' .. h.tail(20))
end)

-- F3 (HelltideRevamped core/hr_roads.lua M.plan / M.cost, used by
-- core/hr_chest_order.lua and the chest trips): the road route starts at the
-- ONE loop point nearest the player and ends at the ONE nearest the chest.
-- The recorded patrol loops pass the same places several times, so those
-- points are often on different laps and the arc between them runs a long
-- way round the 6.4-7.4 km loop. Sampled over all five loops (chest trips
-- of 100 m or more, alternatives on the same level within 15 m of the
-- player and 40 m of the chest): 22-48 % of the trips cost more than 1.5x
-- the shortest road route (p90 2.2x-7.1x). A few metres of movement also
-- move the start to another lap, so the cost jumps by hundreds of metres
-- and the chest order's hysteresis (half the cost, 3 switches a minute)
-- flips between two chests and pins the third pick. Sweep seed 1
-- (t=2336-2400, the last-minutes dump of hour 1): Boots (-523,-609) road
-- 383 m -> Boots (-740,-594) 622 m -> back -> 773 m, pinned 56 s; the hour
-- ended with 1156 cinders unspent and 75-cinder chests closed. Seed 3:
-- "Hell's Prize at 369m (road 3454m)", opened 523 s later.
-- Here: the real jirandai loop, the player spots and chests of seed 1.
repro('road_cost', function()
    local h = J.new({rosie = true, dirs = {'Batmobile', HR}, place = 'step', ordered_pairs = true, minute = 51})
    h.mod(HR, 'core.hr_clock')._now = function() return EPOCH0 + h.minute * 60 + math.floor(h.now) % 60 end
    local pts = loop_points('jirandai')
    h.P.step.box = {-1300, -150, -900, -150}
    h.P.step.spawn = h.v(pts[1][1], pts[1][2])
    h.P.step.helltide = true
    h.pos = h.v(-310.6, -601.5)
    h.assert_clean('load')
    h.mod(HR, 'gui').elements.main_toggle:set(true)
    local tracker = h.mod(HR, 'core.tracker')
    ok(h.run_until(function() return type(tracker.waypoints) == 'table' and #tracker.waypoints > 1000 end, 20),
        'the jirandai loop is loaded\n' .. h.tail(10))
    local roads = h.mod(HR, 'core.hr_roads')
    local A, B = h.v(-523.0, -609.3), h.v(-740.3, -594.0)
    local P = {h.v(-310.6, -601.5), h.v(-304.5, -615.2), h.v(-298.7, -602.0), h.v(-304.1, -615.3)}
    -- The shortest road route over every loop point near the player (the
    -- road's 40 m) and near the chest (its 80 m off-road), for comparison.
    local L = h.as(HR, function() return roads.loop() end)
    local function best_road(target, p)
        local near_p, near_t = {}, {}
        for i = 1, L.n do
            local dp = math.sqrt((L.xs[i] - p:x()) ^ 2 + (L.ys[i] - p:y()) ^ 2)
            local dt = math.sqrt((L.xs[i] - target:x()) ^ 2 + (L.ys[i] - target:y()) ^ 2)
            if dp <= roads.ROAD_MAX then near_p[#near_p + 1] = {i, dp} end
            if dt <= roads.OFFROAD_MAX then near_t[#near_t + 1] = {i, dt} end
        end
        local best = math.huge
        for _, a in ipairs(near_p) do
            for _, b in ipairs(near_t) do
                local f = roads.arc(a[1], b[1], 1)
                best = math.min(best, a[2] + math.min(f, L.total - f) + b[2])
            end
        end
        return best
    end
    local rows, worst, ratio = {}, 0, 0
    local prev
    for i, p in ipairs(P) do
        local ca = h.as(HR, function() return roads.cost(A, p) end)
        local cb = h.as(HR, function() return roads.cost(B, p) end)
        local ba, bb = best_road(A, p), best_road(B, p)
        rows[#rows + 1] = string.format('P%d (%.1f, %.1f): A %.0f m (shortest road %.0f m, straight %.0f m), B %.0f m (%.0f m, %.0f m)',
            i, p:x(), p:y(), ca, ba, p:dist_to_ignore_z(A), cb, bb, p:dist_to_ignore_z(B))
        ratio = math.max(ratio, ca / ba, cb / bb)
        if prev then
            local moved = p:dist_to_ignore_z(P[i - 1])
            worst = math.max(worst, math.abs(ca - prev.a) - moved, math.abs(cb - prev.b) - moved)
        end
        prev = {a = ca, b = cb}
    end
    print(string.format('  jirandai loop %.0f m, %d points; road cost to chest A (-523,-609) and B (-740,-594) from four'
        .. ' player spots 13-15 m apart:\n    %s', L.total, L.n, table.concat(rows, '\n    ')))
    ok(ratio <= 1.5, string.format('the road cost is up to %.1fx the shortest road route between the same places', ratio))
    ok(worst <= 60, string.format('a 15 m step changes a road cost by %.0f m more than the step itself', worst))
end)

-- QQT_SWEEP_LIB=1: return the builders (scratch drivers, minimisation).
if env('QQT_SWEEP_LIB') then
    return {J = J, build = build, setup = setup, run_seed = run_seed, summary = summary, classify = classify,
        rupture_host = rupture_host, chest_actor = chest_actor, REPRO = REPRO}
end

if env('QQT_SWEEP_REPRO') then
    local want = env('QQT_SWEEP_REPRO')
    for _, name in ipairs(REPRO_ORDER) do
        if want == 'all' or (',' .. want .. ','):find(',' .. name .. ',', 1, true) then
            case('repro ' .. name, REPRO[name])
        end
    end
    print(string.format('sweep S1 repros: %d checks, %d failure(s)', checks, #failures))
    if #failures > 0 then error(table.concat(failures, '\n')) end
    return
end

for _, seed in ipairs(SEEDS) do
    case(string.format('seed %d, %.2f h', seed, HOURS), function()
        -- Default: start at minute 54 (the hour ends a minute later, the next
        -- Helltide opens in the other zone) and fill the bag 2.5 min into the
        -- new hour, so a Rosie trip from the Helltide and back is covered.
        local o = HEAVY and {} or {start_min = 54, bag_at = 510}
        local h, W, report, secs = run_seed(seed, HOURS, o)
        print(string.format('wall=%.0fs ', secs) .. summary(h, W))
        print('replay: seed ' .. seed .. ', ' .. h.chaos.replay())
        local counts, new = {}, {}
        for _, hit in ipairs(h.invariants.hits) do
            local class, label = classify(hit)
            counts[class .. ': ' .. label] = (counts[class .. ': ' .. label] or 0) + 1
            if class ~= 'KNOWN' and class ~= 'DESIGN' then
                new[#new + 1] = string.format('  [%s] %s t=%.1f %s', class, hit.kind, hit.t, hit.detail)
            end
        end
        local keys = {}
        for k in pairs(counts) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do print(string.format('  %3d x %s', counts[k], k)) end
        if #new > 0 then print(table.concat(new, '\n')) end
        for i, e in ipairs(h.errors) do
            if i > 3 then break end
            print(string.format('ERROR %s %s at %.1f: %s', e.plugin, e.kind, e.t, e.err))
        end
        if HEAVY then return end
        h.assert_clean('seed ' .. seed)
        -- the scenario really ran: the hour changed, the new zone was farmed,
        -- a Rosie trip left the Helltide and came back through the portal
        ok(W.stats.hours >= 2, 'the next Helltide hour opened')
        local back
        for _, a in ipairs(h.arrivals) do
            if a.why == 'town_portal' and h.P[a.place] and h.P[a.place].helltide then back = a end
        end
        ok(back ~= nil, 'a Rosie trip came back into the Helltide\n' .. h.tail(30))
        ok(W.stats.kills > 0 and (h.pickups or 0) > 0, 'farmed and picked up')
        ok(#new == 0, #new .. ' unclassified invariant hit(s):\n' .. table.concat(new, '\n'))
    end)
end

print(string.format('sweep S1: %d seed(s), %d checks, %d failure(s)', #SEEDS, checks, #failures))
if #failures > 0 then error(table.concat(failures, '\n')) end
