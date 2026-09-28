-- QQT_Warpigz_v3 Rosie 1.0.22 (owner request): Rosie acts as Scavenger when
-- the Scavenger addon is not installed. Worldstone (closed .pak) drives the
-- third-party Navigator, polls Scavenger.is_busy() and pauses Navigator
-- through its "Worldstone Looting" condition. With no Scavenger nothing held
-- Navigator while Rosie walked to a drop: Navigator re-issued its move every
-- pulse, Rosie saw another mover, stepped back and the drop was left behind.
-- Rosie now publishes a Scavenger-compatible _G.Scavenger backed by its
-- pickup and registers its own Navigator condition "Rosie Looting". Busy is
-- bounded (20 s without a pickup, 60 s per episode, then 5 s off without a
-- walk to a drop) and never covers the fight hold.
-- QQT_Warpigz_v3 1.0.22 round 2 (owner): all of it only while Worldstone runs
-- (and no real Scavenger owns the global); without Worldstone Rosie behaves
-- exactly like 1.0.21 (cases b2, d4, h4, h5). Scavenger.pause is bounded: a
-- caller re-pausing every 2 s keeps Rosie pickup paused at most 60 s (e2);
-- every pause through the table is released when it is unpublished (e3, g,
-- g2). Review LOWs: "Rosie Looting" is false beside a real Scavenger (f2), a
-- conflict removes the own table (g2), wanted items are only drops Rosie
-- would work now (c, d, i).
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
local function case(name, fn)
    local passed, err = xpcall(fn, debug.traceback)
    if passed then print('PASS scavenger mimic: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL scavenger mimic: ' .. name .. ': ' .. tostring(err)) end
end
local CONSUMER = {name = 'Consumer', dir = ROOT .. '/audit/tests/', loaded = {}}
local function pgui(h) return h.mod('Rosie', 'rosie.private.pickup.gui').elements end
local function mimic(h) return h.mod('Rosie', 'rosie.private.scavenger_mimic') end
local function looter(h) return h.G.LooteerPlugin end
local function looting(h) return h.as(CONSUMER, function() return h.G.LooteerPlugin.is_actively_looting() end) end
local function paused(h) return h.as(CONSUMER, function() return h.G.LooteerPlugin.status().paused end) end
local function new(opts)
    opts = opts or {}
    local h = J.new({rosie = true, dirs = {}, place = 'pit'})
    h.assert_clean('load')
    h.pos = h.v(0, 0)
    eq(h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end), true, 'RosiePlugin.enable()')
    h.frame()
    pgui(h).general.distance_slider:set(opts.distance or 12)
    if opts.option == false then pgui(h).act_as_scavenger:set(false) end
    return h
end
local function legendary(h, x, y, fields)
    fields = fields or {}
    fields.rarity, fields.ga = fields.rarity or 5, fields.ga or 3
    fields.name = fields.name or 'Helm_Legendary_Generic_031'
    return h.drop('pit', x, y, fields)
end
local function listed(sc, item)
    for _, it in ipairs(sc.get_wanted_items()) do if it == item then return true end end
    return false
end

-- A fake Navigator with the seen API. While `active` and no pause condition
-- holds, it re-issues its move toward `goal` every pulse (Worldstone's
-- request). opts.only: the only condition names it honours.
local function fake_navigator(h, goal, opts)
    opts = opts or {}
    local nav = {conditions = {}, paused_frames = 0, walk_frames = 0, goal = goal or h.v(200, 0), active = true, api = {}}
    function nav.paused() -- every condition is read (no pairs-order dependence)
        local p = false
        for name, fn in pairs(nav.conditions) do
            if not opts.only or opts.only[name] then
                local okc, on = pcall(fn)
                if okc and on == true then p = true end
            end
        end
        return p
    end
    function nav.api.set_pause_condition(name, fn) nav.conditions[name] = fn end
    function nav.api.navigate(o) nav.goal = o and o.position or nav.goal; nav.active = true; return 1 end
    function nav.api.stop() nav.active = false end
    function nav.api.get_status()
        return {state = nav.active and 'travelling' or 'idle', owner = 'Worldstone', is_busy = nav.active,
            is_paused = nav.paused(), priority = 0, mode = 'travel'}
    end
    function nav.step(hh)
        if not nav.active or hh.place ~= hh.P.pit then return end
        if nav.paused() then nav.paused_frames = nav.paused_frames + 1; return end
        nav.walk_frames = nav.walk_frames + 1
        hh.goal = nav.goal
    end
    h.G.Navigator = nav.api
    return nav
end
-- Worldstone: its Navigator condition reads Scavenger.is_busy() (looked up
-- on every call; Worldstone loads before Scavenger). opts.reads=false: it
-- runs but registers no condition. nav=nil: Worldstone without Navigator.
local function fake_worldstone(h, nav, opts)
    opts = opts or {}
    local ws = {reads = 0, busy_reads = 0}
    if nav and opts.reads ~= false then
        nav.api.set_pause_condition('Worldstone Looting', function()
            local sc = rawget(h.G, 'Scavenger')
            if type(sc) ~= 'table' or type(sc.is_busy) ~= 'function' then return false end
            ws.reads = ws.reads + 1
            local busy = sc.is_busy() == true
            if busy then ws.busy_reads = ws.busy_reads + 1 end
            return busy
        end)
    end
    h.G.Worldstone = {get_status = function() return {} end}
    ws.api = h.G.Worldstone
    return ws
end
-- Navigator + Worldstone loaded and idle for more than GRACE s: published.
local function worldstone_run(h, opts)
    local nav = fake_navigator(h, nil, opts)
    nav.active = false
    local ws = fake_worldstone(h, nav, opts)
    h.run(4)
    return nav, ws
end
-- A real (third-party) Scavenger.
local function real_scavenger(h)
    local sc = {busy = false, calls = {}}
    h.G.Scavenger = {
        is_busy = function() return sc.busy end,
        pause = function(who) sc.calls[#sc.calls + 1] = 'pause:' .. tostring(who) end,
        resume = function(who) sc.calls[#sc.calls + 1] = 'resume:' .. tostring(who) end,
        get_status = function() return {} end,
        get_wanted_items = function() return {} end,
    }
    sc.api = h.G.Scavenger
    return sc
end
-- The tug of war over the path, counted directly: a frame in which Rosie
-- issued a pickup move AND Navigator re-issued its own.
local function tug_counter(h, nav)
    local t = {tugs = 0, moves = #h.moves, walked = nav.walk_frames}
    function t.before(hh) t.moves, t.walked = #hh.moves, nav.walk_frames end
    function t.after(hh)
        if #hh.moves > t.moves and nav.walk_frames > t.walked then t.tugs = t.tugs + 1 end
    end
    return t
end
-- Worldstone's route: Navigator walks the player from (0,0) toward (200,0)
-- every pulse; a wanted drop lies 6 m off the route at x=40. opts.nav_first:
-- Navigator acts before Rosie in each frame (plugin order is not fixed).
-- opts.no_worldstone: Navigator runs without Worldstone; opts.reads=false:
-- Worldstone runs without its own condition.
local function route_run(opts)
    opts = opts or {}
    local h = new({option = opts.option})
    local nav = fake_navigator(h, h.v(200, 0), {only = opts.only})
    local ws = not opts.no_worldstone and fake_worldstone(h, nav, {reads = opts.reads}) or nil
    nav.active = false
    h.run(4) -- Worldstone seen for more than GRACE s: the table is published
    local item = legendary(h, 40, 6)
    local t = tug_counter(h, nav)
    local r = {h = h, nav = nav, ws = ws, item = item, t = t, busy_frames = 0, closest = math.huge}
    nav.active = true
    local function observe(hh)
        local sc = rawget(hh.G, 'Scavenger')
        local busy = type(sc) == 'table' and sc.is_busy() == true
        if busy then r.busy_frames = r.busy_frames + 1 end
        r.closest = math.min(r.closest, hh.pos:dist_to_ignore_z(item.pos))
    end
    local stop = h.now + 24 - 1e-9
    while h.now < stop do
        t.before(h)
        if opts.nav_first then nav.step(h); h.frame() else h.frame(); nav.step(h) end
        t.after(h)
        observe(h)
    end
    return r
end
local function rosie_lines(h)
    local out = {}
    for _, line in ipairs(h.log) do if line:find('[Rosie', 1, true) then out[#out + 1] = line end end
    return table.concat(out, '\n')
end

case('a: Worldstone + Navigator, a drop 6 m off the route: Navigator waits, Rosie takes it, no back and forth', function()
    local r = route_run()
    local h = r.h
    ok(h.G.Scavenger and h.G.Scavenger._rosie == true, 'Rosie published its Scavenger table')
    eq(h.logged('Acting as Scavenger for Worldstone/Navigator (no Scavenger installed)'), 1, 'published: logged once')
    eq(r.item.picked, true, 'the drop was picked up\n' .. h.tail(12))
    ok(r.busy_frames > 0, 'Scavenger.is_busy() was true while Rosie looted')
    ok(r.ws.busy_reads > 0, "Worldstone's condition read a busy Scavenger")
    ok(r.nav.paused_frames > 0, 'Navigator was paused while Rosie looted')
    eq(h.logged('Another move took the player off'), 0, 'Rosie never stepped back for Navigator')
    print(string.format('  a: tugs=%d paused_frames=%d busy_frames=%d', r.t.tugs, r.nav.paused_frames, r.busy_frames))
    eq(r.t.tugs, 0, 'Navigator never re-issued its move in a frame Rosie moved')
    ok(h.pos:x() > 150, 'Navigator resumed after the pickup: x=' .. string.format('%.1f', h.pos:x()))
    ok(h.logged('pause condition "Rosie Looting"') == 1, 'own condition registered once')
    h.assert_clean('a')
end)

case('a2: the Scavenger table alone holds a Navigator that honours only Worldstone\'s condition', function()
    local r = route_run({only = {['Worldstone Looting'] = true}})
    eq(r.item.picked, true, 'picked through the Worldstone condition alone\n' .. r.h.tail(12))
    ok(r.ws.busy_reads > 0 and r.nav.paused_frames > 0, 'paused by Worldstone reading Rosie as Scavenger')
    eq(r.t.tugs, 0, 'no tug of war')
    eq(r.h.logged('Another move took the player off'), 0, 'no yield')
    r.h.assert_clean('a2')
end)

case('a3: Rosie\'s own condition "Rosie Looting" holds Navigator when Worldstone runs but does not read Scavenger', function()
    local r = route_run({reads = false})
    eq(r.item.picked, true, 'picked through "Rosie Looting"\n' .. r.h.tail(12))
    ok(r.nav.conditions['Rosie Looting'] ~= nil, 'registered')
    ok(r.nav.conditions['Worldstone Looting'] == nil, 'Worldstone registered nothing here')
    ok(r.nav.conditions['Rosie'] == nil, 'the town-trip condition name is not reused')
    ok(r.nav.paused_frames > 0, 'paused by Rosie Looting')
    eq(r.t.tugs, 0, 'no tug of war')
    eq(r.h.logged('Another move took the player off'), 0, 'no yield')
    r.h.assert_clean('a3')
end)

case('a4: Navigator acting before Rosie in each frame: at most one shared frame, then it waits', function()
    local r = route_run({nav_first = true})
    eq(r.item.picked, true, 'picked\n' .. r.h.tail(12))
    ok(r.t.tugs <= 1, 'tugs: ' .. r.t.tugs)
    ok(r.nav.paused_frames > 0, 'paused')
    eq(r.h.logged('Another move took the player off'), 0, 'no yield')
    r.h.assert_clean('a4')
end)

local old_behaviour -- case b, compared by b2
case('b: option off (old behaviour): nothing holds Navigator, the drop is left behind or fought over', function()
    local r = route_run({option = false})
    local h = r.h
    eq(h.G.Scavenger, nil, 'no Scavenger table with the option off')
    print(string.format('  b: picked=%s tugs=%d closest=%.1f paused_frames=%d', tostring(r.item.picked),
        r.t.tugs, r.closest, r.nav.paused_frames))
    eq(r.nav.paused_frames, 0, 'Navigator was never paused')
    ok(r.item.picked ~= true, 'the old failure shows: the drop is left behind')
    ok(r.t.tugs >= 1, 'the old failure shows: Rosie and Navigator moved in the same frame (a yields at 0): ' .. r.t.tugs)
    ok(h.logged('Another move took the player off') >= 1, 'Rosie stepped back for Navigator (old tug of war)\n' .. h.tail(12))
    old_behaviour = {picked = r.item.picked, tugs = r.t.tugs, closest = r.closest, x = h.pos:x(), log = rosie_lines(h)}
    h.assert_clean('b')
end)

-- QQT_Warpigz_v3 1.0.22 round 2 (owner): Navigator without Worldstone is 1.0.21.
case('b2: Navigator without Worldstone (option on): exactly the 1.0.21 run: no table, no condition, same path and log as b', function()
    local r = route_run({no_worldstone = true})
    local h = r.h
    eq(h.G.Scavenger, nil, 'no Scavenger table without Worldstone')
    eq(r.nav.conditions['Rosie Looting'], nil, 'no "Rosie Looting" without Worldstone')
    eq(r.nav.paused_frames, 0, 'Navigator was never paused')
    eq(h.logged('Scavenger'), 0, 'nothing logged about Scavenger')
    print(string.format('  b2: picked=%s tugs=%d closest=%.1f', tostring(r.item.picked), r.t.tugs, r.closest))
    ok(old_behaviour, 'case b ran')
    eq(r.item.picked, old_behaviour.picked, 'picked as with the option off')
    eq(r.t.tugs, old_behaviour.tugs, 'tugs as with the option off')
    eq(string.format('%.3f/%.3f', r.closest, h.pos:x()), string.format('%.3f/%.3f', old_behaviour.closest, old_behaviour.x),
        'the same path as with the option off')
    eq(rosie_lines(h), old_behaviour.log, 'the same Rosie log as with the option off')
    h.assert_clean('b2')
end)

case('c: the fight hold (enemy near, drop 6 m away) keeps pickup busy but not Scavenger busy, nor a wanted item', function()
    local h = new({distance = 30})
    local nav = worldstone_run(h)
    local sc = h.G.Scavenger
    ok(sc and sc._rosie, 'published')
    local enemy = h.actor('pit', 'Dark_Conjurer', 7, 0, {enemy = true, elite = true, health = 1e9})
    local item = legendary(h, -6, 0, {name = 'Helm_Legendary_Generic_010'})
    local seen = {busy = false, cond = false, looting = false, listed = false}
    h.run(6, function(hh)
        if sc.is_busy() then seen.busy = true end
        if nav.conditions['Rosie Looting']() then seen.cond = true end
        if looting(hh) then seen.looting = true end
        if listed(sc, item) then seen.listed = true end
    end)
    eq(seen.looting, true, 'pickup stays busy while the drop waits for the fight (3.3.2)')
    eq(seen.busy, false, 'Scavenger.is_busy() stays false in the fight hold')
    eq(seen.cond, false, 'Rosie Looting stays false in the fight hold')
    eq(seen.listed, false, 'a drop the fight holds is not a wanted item (review)')
    ok(item.picked ~= true, 'no walk out of the fight')
    enemy.health = 0
    ok(h.run_until(function(hh)
        if sc.is_busy() then seen.busy = true end
        if listed(sc, item) then seen.listed = true end
        return item.picked == true
    end, 15), 'taken after the fight\n' .. h.tail(10))
    eq(seen.busy, true, 'busy while walking to it after the fight')
    eq(seen.listed, true, 'a wanted item once the fight is over')
    h.assert_clean('c')
end)

-- A stream of drops 4 m off the player, each taken on its 3rd interaction
-- (bag 'sink': the bag never fills): Rosie walks and picks up without a break.
local function stream()
    local side, current = 1, nil
    return function(hh)
        if current and not current.picked then return end
        local n = 0
        current = legendary(hh, hh.pos:x() + 4 * side, hh.pos:y(), {bag = 'sink', refuse = function() n = n + 1; return n < 3 end})
        side = -side
    end
end
case('d: steady pickups keep one busy episode up to 60 s; then 5 s off without a walk to a drop; then a new episode', function()
    local h = new({distance = 30})
    local nav = worldstone_run(h)
    local sc, m = h.G.Scavenger, mimic(h)
    eq(m.CAP, 20); eq(m.CEILING, 60); eq(m.COOL, 5)
    local feed = stream()
    feed(h)
    local t0 = h.now
    local first, capped, again, rises, was = nil, nil, nil, 0, false
    local cool_busy, cool_moves, cond_mismatch, cool_pos, cool_moved, near, cool_listed = 0, 0, 0, nil, 0, nil, 0
    local moves = #h.moves
    h.run(72, function(hh)
        feed(hh)
        local busy = sc.is_busy()
        if (nav.conditions['Rosie Looting']() == true) ~= busy then cond_mismatch = cond_mismatch + 1 end
        if busy and not was then rises = rises + 1 end
        was = busy
        if busy and not first then first = hh.now end
        if first and not capped and not busy then
            capped, cool_pos = hh.now, hh.pos
            local n = 0 -- taken on its 6th interaction: in reach for a while in the cool-down
            near = legendary(hh, hh.pos:x(), hh.pos:y() + 1, {name = 'Helm_Legendary_Generic_036', bag = 'sink',
                refuse = function() n = n + 1; return n < 6 end})
        end
        if capped and hh.now > capped + 0.15 and hh.now < capped + m.COOL - 0.15 then
            if busy then cool_busy = cool_busy + 1 end
            cool_moves = cool_moves + (#hh.moves - moves)
            cool_moved = math.max(cool_moved, hh.pos:dist_to_ignore_z(cool_pos))
            cool_listed = cool_listed + #sc.get_wanted_items()
        end
        moves = #hh.moves
        if capped and not again and busy then again = hh.now end
    end)
    ok(first and first - t0 < 1, 'busy at once')
    ok(capped, 'is_busy went false\n' .. h.tail(10))
    print(string.format('  d: busy for %.1f s in %d episode(s), off for %.1f s, pickups=%d, moves in the cool-down=%d, moved %.2f m',
        capped - first, rises, again and again - capped or -1, h.pickups or 0, cool_moves, cool_moved))
    ok(math.abs((capped - first) - m.CEILING) <= 0.3, 'one episode up to the 60 s ceiling: ' .. (capped - first))
    ok(rises >= 2, 'a new episode after the cool-down')
    eq(h.logged('Busy as Scavenger for 60s in one go'), 1, 'the ceiling is logged once per episode')
    eq(h.logged('without a pickup'), 0, 'steady pickups never hit the 20 s stall cap')
    eq(cool_busy, 0, 'false for the whole cool-down')
    eq(cool_moves, 0, 'no pickup move in the cool-down: Navigator has the path')
    ok(cool_moved < 1, 'the player stood still in the cool-down: ' .. cool_moved)
    eq(cool_listed, 0, 'no wanted items in the cool-down, not even the drop in reach (review)')
    eq(near.picked, true, 'a drop in reach is still taken in the cool-down')
    ok(again and math.abs((again - capped) - m.COOL) <= 0.3, 'a new episode after 5 s: ' .. tostring(again and again - capped))
    eq(cond_mismatch, 0, 'Rosie Looting follows is_busy')
    ok(h.pickups and h.pickups >= 40, 'steady pickups: ' .. tostring(h.pickups))
    h.assert_clean('d')
end)

case('d2: a pile that takes longer than 20 s under a walking Navigator: one busy episode, every drop taken, no tug of war', function()
    local h = new()
    local nav = worldstone_run(h)
    local sc, m = h.G.Scavenger, mimic(h)
    -- 24 drops within the 12 m pickup distance, each taken on its 6th interaction.
    local items = {}
    for i = 1, 24 do
        local a, rad, n = i * 2.39996, 3 + (i % 8), 0
        items[i] = legendary(h, rad * math.cos(a), rad * math.sin(a), {name = string.format('Helm_Legendary_Generic_%03d', 100 + i),
            bag = 'sink', refuse = function() n = n + 1; return n < 6 end})
    end
    local function picked()
        local c = 0
        for _, item in ipairs(items) do if item.picked then c = c + 1 end end
        return c
    end
    local t = tug_counter(h, nav)
    nav.active = true
    local rises, was, first, last = 0, false, nil, nil
    local stop = h.now + 60
    while h.now < stop and picked() < #items do
        t.before(h); h.frame(); nav.step(h); t.after(h)
        local busy = sc.is_busy()
        if busy and not was then rises = rises + 1 end
        if busy then first = first or h.now; last = h.now end
        was = busy
    end
    print(string.format('  d2: picked %d/%d in %.1f s, busy episodes=%d, tugs=%d', picked(), #items, (last or 0) - (first or 0), rises, t.tugs))
    eq(picked(), #items, 'every drop taken\n' .. h.tail(12))
    eq(rises, 1, 'one busy episode')
    ok(last - first > m.CAP, 'the episode outlasted the 20 s stall cap: ' .. (last - first))
    eq(h.logged('Busy as Scavenger for'), 0, 'no cap')
    eq(h.logged('Another move took the player off'), 0, 'Rosie never stepped back for Navigator')
    eq(t.tugs, 0, 'no tug of war')
    local x = h.pos:x()
    h.run(3, function(hh) nav.step(hh) end)
    ok(h.pos:x() > x + 10, 'Navigator walks on after the pile')
    h.assert_clean('d2')
end)

case('d3: drops the game refuses (no pickup): busy ends after 20 s and stays off; resting drops are not wanted items', function()
    local h = new({distance = 30})
    local _, ws = worldstone_run(h)
    local sc, m = h.G.Scavenger, mimic(h)
    local pickup = h.mod('Rosie', 'rosie.private.pickup.src.pickup')
    local refused = {}
    for i, p in ipairs({{1, 0}, {0, 1}, {-1, 0}}) do
        refused[i] = legendary(h, p[1], p[2], {name = 'Helm_Legendary_Generic_009', refuse = function() return true end})
    end
    local first, off, off_busy, hold = nil, nil, 0, nil
    h.run(27, function(hh)
        local busy = sc.is_busy()
        if busy and not first then first = hh.now end
        if first and not off and not busy then off = hh.now end
        if off and hh.now < off + m.COOL - 0.15 and busy then off_busy = off_busy + 1 end
        -- QQT_Warpigz_v3 1.0.22 round 2: the walk hold is gated on Worldstone in the same frame.
        if off and not hold and hh.now >= off + 1 then
            hold = {before = pickup.walk_hold(hh.now)}
            hh.G.Worldstone = nil
            hold.gone = pickup.walk_hold(hh.now)
            hh.G.Worldstone = ws.api
        end
    end)
    ok(first and off, 'busy, then not\n' .. h.tail(10))
    ok(math.abs((off - first) - m.CAP) <= 0.3, 'off after 20 s without a pickup: ' .. (off - first))
    eq(off_busy, 0, 'false for the cool-down')
    eq(hold.before, true, 'the cool-down holds walks')
    eq(hold.gone, false, 'no walk hold on the frame Worldstone is gone')
    local ItemManager = h.mod('Rosie', 'rosie.private.pickup.src.item_manager')
    local wanted = {}
    for _, item in ipairs(sc.get_wanted_items()) do wanted[item] = true end
    for i, item in ipairs(refused) do
        eq(ItemManager.check_want_item(item, false), true, 'the filter still wants refused drop ' .. i)
        ok(not wanted[item], 'a resting drop is not a wanted item: ' .. i)
    end
    h.assert_clean('d3')
end)

case('d4: Navigator without Worldstone: nothing is counted: no cap, no log, no walk hold for the same stream', function()
    local h = new({distance = 30})
    local nav = fake_navigator(h); nav.active = false
    local pickup, m, feed, held = h.mod('Rosie', 'rosie.private.pickup.src.pickup'), mimic(h), stream(), 0
    feed(h)
    h.run(66, function(hh)
        feed(hh)
        if pickup.walk_hold(hh.now) then held = held + 1 end
    end)
    eq(h.logged('Busy as Scavenger for'), 0, 'no cap without Worldstone')
    eq(held, 0, 'never a walk hold without Worldstone')
    eq(m.is_busy(), false, 'never busy without Worldstone')
    eq(nav.conditions['Rosie Looting'], nil, 'no condition without Worldstone')
    eq(h.G.Scavenger, nil, 'no table without Worldstone')
    ok(h.pickups and h.pickups >= 70, 'pickups went on without a break: ' .. tostring(h.pickups))
    h.assert_clean('d4')
end)

case('e: pause("Worldstone") stops Rosie pickup, resume("Worldstone") restores it', function()
    local h = new({distance = 30})
    local nav = worldstone_run(h)
    local sc = h.G.Scavenger
    eq(sc.pause('Worldstone'), true, 'pause returns true')
    local item = legendary(h, 6, 0)
    local moves = #h.moves
    h.run(4)
    ok(item.picked ~= true, 'no pickup while Worldstone pauses Scavenger')
    eq(#h.moves, moves, 'no pickup move')
    eq(sc.is_busy(), false)
    local st = sc.get_status()
    eq(st.is_paused, true); eq(st.state, 'paused'); eq(st.mimic, true); eq(st.name, 'Rosie'); eq(st.owner, 'Rosie')
    -- One version source, no literal to bump here.
    local f = assert(io.open(ROOT .. '/versions.json', 'r'))
    local manifest = f:read('*a'); f:close()
    eq(st.version, manifest:match('"Rosie"%s*:%s*"([^"]+)"'), 'the Rosie version of versions.json')
    eq(st.version, h.as(CONSUMER, function() return h.G.AlfredTheButlerPlugin.get_status().version end), 'the Rosie status version')
    local ls = h.as(CONSUMER, function() return looter(h).status() end)
    eq(ls.paused, true, 'the Looter pause')
    ok(ls.detail:find('Worldstone', 1, true), 'paused by Worldstone: ' .. ls.detail)
    eq(sc.resume('Worldstone'), true, 'resume returns true')
    ok(h.run_until(function() return item.picked == true end, 10), 'taken after resume\n' .. h.tail(10))
    eq(sc.get_status().is_paused, false)
    -- The pause gate on its own (review): paused AFTER the drop exists and
    -- while Rosie walks to it -> false on the same frame, for the table and
    -- for "Rosie Looting" as Navigator reads it (not only after the debounce).
    local cond = nav.conditions['Rosie Looting']
    local item2 = legendary(h, h.pos:x() + 10, 0, {name = 'Helm_Legendary_Generic_035'})
    ok(h.run_until(function() return sc.is_busy() and cond() == true end, 3), 'busy walking to the next drop')
    eq(sc.pause('Worldstone'), true)
    eq(sc.is_busy(), false, 'false on the same frame as the pause')
    eq(cond(), false, 'Rosie Looting false on the same frame as the pause')
    h.frame()
    eq(sc.is_busy(), false, 'false while paused')
    eq(cond(), false, 'Rosie Looting false while paused')
    eq(sc.resume('Worldstone'), true)
    ok(h.run_until(function() return item2.picked == true end, 10), 'taken after the second resume\n' .. h.tail(10))
    -- A nil caller is keyed as Scavenger-caller; 'Rosie' never takes Rosie's own trip pause.
    eq(sc.pause(), true)
    ok(looter(h).status().detail:find('Scavenger-caller', 1, true), 'nil caller key')
    eq(sc.resume(), true)
    eq(sc.pause('Rosie'), true)
    ok(looter(h).status().detail:find('Scavenger-caller:Rosie', 1, true), 'a foreign "Rosie" is not the trip pause')
    eq(sc.resume('Rosie'), true)
    eq(looter(h).status().paused, false, 'all released')
    h.assert_clean('e')
end)

-- QQT_Warpigz_v3 1.0.22 round 2 (review R2): a caller that re-pauses
-- periodically never keeps Rosie pickup paused forever.
case('e2: Worldstone re-pausing every 2 s for 150 s: Rosie pickup resumes within 60 s and takes the drop; resume starts a new episode', function()
    local h = new({distance = 30})
    worldstone_run(h)
    local sc = h.G.Scavenger
    local t0 = h.now
    eq(sc.pause('Worldstone'), true)
    local item = legendary(h, 8, 0)
    local next_pause, calls, refused, resumed_at, picked_at, repaused = h.now + 2, 1, 0, nil, nil, 0
    h.run(150, function(hh)
        if hh.now >= next_pause then
            next_pause = next_pause + 2
            calls = calls + 1
            if sc.pause('Worldstone') ~= true then refused = refused + 1 end
        end
        local p = paused(hh)
        if not resumed_at and not p then resumed_at = hh.now end
        if resumed_at and p then repaused = repaused + 1 end
        if item.picked and not picked_at then picked_at = hh.now end
    end)
    print(string.format('  e2: %d pause calls, pickup resumed after %.1f s, drop taken after %.1f s', calls,
        (resumed_at or 0) - t0, (picked_at or 0) - t0))
    ok(resumed_at, 'pickup resumed\n' .. h.tail(10))
    ok(resumed_at - t0 <= 60.2, 'at most 60 s paused (no TTL refresh): ' .. (resumed_at - t0))
    ok(resumed_at - t0 >= 59.5, 'the pause held until its bound: ' .. (resumed_at - t0))
    ok(picked_at and picked_at >= resumed_at, 'the drop was taken after the pause ended')
    eq(repaused, 0, 'never paused again by the ignored calls')
    eq(refused, 0, 'every pause call returns true')
    eq(h.logged('pause by Worldstone (through Scavenger) ended after 60s'), 1, 'logged once per episode')
    -- resume starts a new episode: the next pause holds again
    eq(sc.resume('Worldstone'), true)
    eq(sc.pause('Worldstone'), true)
    eq(paused(h), true, 'a new episode after resume: paused again')
    local item2 = legendary(h, h.pos:x() + 6, 0, {name = 'Helm_Legendary_Generic_037'})
    h.run(3)
    ok(item2.picked ~= true, 'held by the new episode')
    eq(sc.resume('Worldstone'), true)
    ok(h.run_until(function() return item2.picked == true end, 10), 'taken after the resume\n' .. h.tail(10))
    -- The mimic's own bound, without the Looter TTL (a pause kept alive by
    -- another path): released after PAUSE_MAX s all the same.
    local settings = h.mod('Rosie', 'rosie.private.pickup.src.settings')
    local ttl = settings.FOREIGN_PAUSE_TTL
    settings.FOREIGN_PAUSE_TTL = 1e6
    local t1 = h.now
    eq(sc.pause('Worldstone'), true)
    ok(h.run_until(function(hh) return not paused(hh) end, 70), 'released by the mimic bound\n' .. h.tail(10))
    ok(math.abs((h.now - t1) - mimic(h).PAUSE_MAX) <= 0.2, 'after PAUSE_MAX s: ' .. (h.now - t1))
    eq(sc.pause('Worldstone'), true)
    eq(paused(h), false, 'ignored until resume')
    settings.FOREIGN_PAUSE_TTL = ttl
    eq(sc.resume('Worldstone'), true)
    h.assert_clean('e2')
end)

-- QQT_Warpigz_v3 1.0.22 round 2 (review R2): unpublishing releases every
-- pause taken through the table at once.
case('e3: pauses through the table are released when it is unpublished: Worldstone gone, option off, a real Scavenger', function()
    local h = new({distance = 30})
    local _, ws = worldstone_run(h)
    local sc = h.G.Scavenger
    eq(sc.pause('Worldstone'), true); eq(sc.pause(), true)
    eq(paused(h), true)
    local item = legendary(h, 6, 0)
    h.run(1)
    ok(item.picked ~= true, 'paused')
    h.G.Worldstone = nil
    h.frame()
    eq(h.G.Scavenger, nil, 'removed with Worldstone gone')
    eq(paused(h), false, 'released on that update')
    eq(h.logged('Pickup pause by Scavenger-caller, Worldstone (through Scavenger) released'), 1, 'logged')
    ok(h.run_until(function() return item.picked == true end, 5), 'pickup goes on\n' .. h.tail(8))
    eq(sc.pause('Worldstone'), false, 'a kept reference cannot pause while unpublished')
    eq(paused(h), false)
    h.G.Worldstone = ws.api
    h.frame()
    eq(h.G.Scavenger, nil, 'the grace again after Worldstone came back')
    h.run(3.5)
    eq(h.G.Scavenger, sc, 'published again')
    eq(sc.pause('Worldstone'), true)
    pgui(h).act_as_scavenger:set(false)
    h.frame()
    eq(h.G.Scavenger, nil, 'removed with the option off')
    eq(paused(h), false, 'released with the option off')
    pgui(h).act_as_scavenger:set(true)
    h.run(3.5)
    eq(h.G.Scavenger, sc, 'published again')
    eq(sc.pause('Worldstone'), true)
    local real = real_scavenger(h)
    h.frame()
    eq(h.G.Scavenger, real.api, 'the real Scavenger stays')
    eq(paused(h), false, 'released when a real Scavenger takes over')
    h.assert_clean('e3')
end)

case('f: a real Scavenger present: Rosie does not publish, registers no condition and still yields to it', function()
    local h = new({distance = 30})
    local real = real_scavenger(h)
    local nav = worldstone_run(h)
    h.run(2)
    eq(h.G.Scavenger, real.api, 'the real Scavenger is never replaced')
    eq(h.logged('Acting as Scavenger'), 0, 'nothing published')
    eq(nav.conditions['Rosie Looting'], nil, 'no "Rosie Looting" beside a real Scavenger')
    real.busy = true
    local item = legendary(h, 8, 0)
    h.run(5)
    ok(item.picked ~= true, 'yields while the real Scavenger is busy')
    ok(h.pos:dist_to_ignore_z(h.v(0, 0)) < 0.5, 'no walk to the drop')
    real.busy = false
    ok(h.run_until(function() return item.picked == true end, 15), 'taken once it is idle\n' .. h.tail(10))
    h.G.Worldstone = nil
    h.run(1)
    eq(h.G.Scavenger, real.api, 'Worldstone gone: the real Scavenger is never removed')
    h.assert_clean('f')
end)

case('f2: a real Scavenger loading after Rosie published: it wins, "Rosie Looting" goes false, Rosie yields to it', function()
    local h = new({distance = 30})
    local nav = worldstone_run(h)
    ok(h.G.Scavenger and h.G.Scavenger._rosie, 'published first')
    local cond = nav.conditions['Rosie Looting']
    ok(cond, 'registered while published')
    local first = legendary(h, 10, 0, {name = 'Helm_Legendary_Generic_040'})
    ok(h.run_until(function() return cond() == true end, 3), 'Rosie Looting true walking to a drop')
    local real = real_scavenger(h)
    eq(cond(), false, 'Rosie Looting false on the frame a real Scavenger loads')
    ok(h.run_until(function() return first.picked == true end, 10), 'Rosie still takes its drop (the real one is idle)')
    h.run(5)
    eq(h.G.Scavenger, real.api, 'not overwritten back')
    eq(h.logged('A Scavenger addon is loaded: Rosie stops acting as Scavenger'), 1, 'take-over logged once')
    -- Review LOW (a): the kept condition answers false beside a real
    -- Scavenger while Rosie walks to a drop (the real one idle).
    local item0 = legendary(h, 8, 0, {name = 'Helm_Legendary_Generic_038'})
    local walked, cond_true = false, 0
    ok(h.run_until(function(hh)
        if looting(hh) then walked = true end
        if cond() == true then cond_true = cond_true + 1 end
        return item0.picked == true
    end, 10), 'Rosie picks up beside an idle real Scavenger\n' .. h.tail(10))
    eq(walked, true, 'Rosie pickup was busy')
    eq(cond_true, 0, 'Rosie Looting never true beside a real Scavenger')
    real.busy = true
    local item = legendary(h, h.pos:x() + 8, 0)
    local x = h.pos:x()
    h.run(4)
    ok(item.picked ~= true, 'yields to the real one')
    ok(math.abs(h.pos:x() - x) < 0.5, 'no walk to the drop')
    real.busy = false
    ok(h.run_until(function() return item.picked == true end, 15), 'taken once it is idle')
    h.assert_clean('f2')
end)

case('f3: Rosie never yields to its own Scavenger table: a drop is looted in one busy episode', function()
    local h = new({distance = 30})
    worldstone_run(h)
    local sc = h.G.Scavenger
    local foreign = h.mod('Rosie', 'rosie.private.foreign')
    local item = legendary(h, 9, 0)
    local episodes, was, foreign_busy, owned = 0, false, 0, 0
    ok(h.run_until(function(hh)
        local busy = sc.is_busy()
        if busy and not was then episodes = episodes + 1 end
        was = busy
        if foreign.scavenger_busy() then foreign_busy = foreign_busy + 1 end
        if looter(hh).status().activity_owned then owned = owned + 1 end
        return item.picked == true
    end, 10), 'taken\n' .. h.tail(10))
    h.run(2, function() if sc.is_busy() and not was then episodes = episodes + 1 end; was = sc.is_busy() end)
    eq(episodes, 1, 'one busy episode, no oscillation')
    eq(foreign_busy, 0, 'the own table is never a foreign looter')
    eq(owned, 0, 'pickup never reported activity-owned')
    eq(sc.is_busy(), false, 'not busy after the debounce')
    eq(h.logged('Another move took the player off'), 0)
    -- A trip with the own table published: nothing to pause, nothing logged.
    eq(foreign.scavenger_hold(), 'mimic')
    eq(h.logged('Could not hold Scavenger'), 0)
    h.assert_clean('f3')
end)

case('g: reload: the new instance replaces its own table at once; the old closures return false; old pauses released', function()
    local h = new({distance = 30})
    local nav = worldstone_run(h)
    local old, old_cond = h.G.Scavenger, nav.conditions['Rosie Looting']
    ok(old and old._rosie and old_cond, 'published + registered')
    legendary(h, 12, 0)
    ok(h.run_until(function() return old.is_busy() end, 5), 'old instance busy walking to the drop')
    eq(old.pause('Worldstone'), true, 'a pause through the old table')
    h.reload('Rosie')
    ok(h.G.Scavenger ~= old and h.G.Scavenger._rosie == true, 'a fresh table right after the reload')
    eq(h.logged('Pickup pause by Worldstone (through Scavenger) released'), 1, 'the retired instance released its pause')
    eq(h.logged('reload: pickup pause by Worldstone not restored'), 0, 'nothing left for the reload to drop')
    eq(old.is_busy(), false, 'old is_busy false')
    eq(old_cond(), false, 'old condition false')
    eq(old.pause('Worldstone'), false, 'old pause refused')
    eq(old.resume('Worldstone'), false, 'old resume refused')
    eq(old.get_status().state, 'disabled', 'old status')
    eq(#old.get_wanted_items(), 0, 'old wanted list empty')
    h.run(1)
    ok(nav.conditions['Rosie Looting'] ~= old_cond, 'the condition is registered again by the new instance')
    local sc = h.G.Scavenger
    local item = legendary(h, h.pos:x() + 8, 0, {name = 'Helm_Legendary_Generic_032'})
    local seen = false
    ok(h.run_until(function() if sc.is_busy() then seen = true end; return item.picked == true end, 15),
        'the new instance loots\n' .. h.tail(10))
    eq(seen, true, 'the new table reports busy')
    eq(old.is_busy(), false)
    -- A reload while Worldstone is gone: the old table goes, nothing new.
    h.G.Worldstone = nil
    h.reload('Rosie')
    eq(h.G.Scavenger, nil, 'no table after a reload without Worldstone')
    h.run(4)
    eq(h.G.Scavenger, nil, 'still none')
    h.assert_clean('g')
end)

-- QQT_Warpigz_v3 1.0.22 round 2 (review R4 b): a conflict stopped tick()
-- and left a dead own table published.
case('g2: an installation conflict removes the own table and releases its pauses (running, and at a reload)', function()
    local h = new({distance = 30})
    local nav = worldstone_run(h)
    local sc, cond = h.G.Scavenger, nav.conditions['Rosie Looting']
    eq(sc.pause('Worldstone'), true)
    local settings = h.mod('Rosie', 'rosie.private.pickup.src.settings')
    h.G.LooteerPlugin = {name = 'another looter'}
    h.frame()
    eq(h.G.Scavenger, nil, 'the own table is removed on the conflict')
    eq(settings.pause_state().owners.Worldstone, nil, 'its pause is released')
    eq(cond(), false, 'Rosie Looting false')
    eq(sc.is_busy(), false)
    h.assert_clean('g2')
    -- A reload that finds a conflict: the retired instance removes its table.
    local h2 = new({distance = 30})
    worldstone_run(h2)
    ok(h2.G.Scavenger and h2.G.Scavenger._rosie, 'published')
    h2.G.LooteerPlugin = {name = 'another looter'}
    h2.reload('Rosie')
    eq(h2.G.Scavenger, nil, 'no dead Rosie table after a reload with a conflict')
    h2.run(4)
    eq(h2.G.Scavenger, nil, 'still none')
end)

case('h: option off: no global, no condition; on: published; off again: removed. No Navigator/Worldstone: never published', function()
    local h = new({option = false})
    local nav = worldstone_run(h)
    h.run(2)
    eq(h.G.Scavenger, nil, 'no global with the option off')
    eq(nav.conditions['Rosie Looting'], nil, 'no condition with the option off')
    pgui(h).act_as_scavenger:set(true)
    h.run(4)
    ok(h.G.Scavenger and h.G.Scavenger._rosie, 'published once on')
    ok(nav.conditions['Rosie Looting'] ~= nil, 'registered once on')
    -- The option gate on its own (review): turned off while Rosie walks to a
    -- drop -> false on the same frame.
    local cond = nav.conditions['Rosie Looting']
    local item = legendary(h, 8, 0)
    ok(h.run_until(function() return cond() == true end, 3), 'Rosie Looting true walking to a drop')
    pgui(h).act_as_scavenger:set(false)
    eq(cond(), false, 'false on the same frame as the option off')
    eq(h.G.Scavenger.is_busy(), false, 'the table answers false too until it is removed')
    h.frame()
    eq(cond(), false, 'false on the next frame')
    h.run(0.5)
    eq(h.G.Scavenger, nil, 'removed when turned off')
    eq(cond(), false, 'the condition answers false while off')
    ok(h.run_until(function() return item.picked == true end, 10), 'pickup goes on with the option off')
    eq(cond(), false)
    h.assert_clean('h')
    -- GRACE: a real Scavenger loading 1 s after Navigator: Rosie never published its table.
    local h3 = new()
    fake_worldstone(h3, nil)
    local nav3 = fake_navigator(h3); nav3.active = false
    local shim_seen = false
    local function watch(hh)
        local cur = rawget(hh.G, 'Scavenger')
        if type(cur) == 'table' and rawget(cur, '_rosie') then shim_seen = true end
    end
    h3.run(1, watch)
    local real = real_scavenger(h3)
    h3.run(5, watch)
    eq(shim_seen, false, 'never published inside the grace')
    eq(h3.G.Scavenger, real.api, 'the real Scavenger stays')
    eq(h3.logged('Acting as Scavenger'), 0, 'nothing published')
    eq(h3.logged('A Scavenger addon is loaded'), 0, 'nothing to take over')
    h3.assert_clean('h3')
    -- Without Navigator and Worldstone Rosie publishes only its documented globals.
    local h2 = new()
    h2.run(10)
    eq(table.concat(h2.new_globals(), ','), 'AlfredTheButlerPlugin,LooteerPlugin,PLUGIN_alfred_the_butler,RosiePlugin',
        'no Scavenger without Worldstone')
    h2.assert_clean('h2')
end)

-- QQT_Warpigz_v3 1.0.22 round 2 (owner R1): the Worldstone gate over time.
case('h4: Navigator alone: 1.0.21; Worldstone later: published after the grace; Worldstone gone: removed; a real Scavenger untouched', function()
    local h = new({distance = 30})
    local m = mimic(h)
    local nav = fake_navigator(h); nav.active = false
    local item = legendary(h, 10, 0)
    local looted = false
    h.run(10, function(hh) if looting(hh) then looted = true end end)
    ok(looted and item.picked == true, 'Rosie picks up as in 1.0.21\n' .. h.tail(8))
    eq(h.G.Scavenger, nil, 'no Worldstone: no Scavenger table')
    eq(nav.conditions['Rosie Looting'], nil, 'no Worldstone: no condition')
    eq(h.logged('Scavenger'), 0, 'nothing logged about Scavenger')
    eq(table.concat(h.new_globals(), ','), 'AlfredTheButlerPlugin,LooteerPlugin,Navigator,PLUGIN_alfred_the_butler,RosiePlugin',
        'only the documented globals beside Navigator')
    -- Worldstone appears later (read on each pulse): published GRACE s after it was first seen.
    local ws = fake_worldstone(h, nav)
    local t0, pub_at = h.now, nil
    h.run(m.GRACE + 1, function(hh) if not pub_at and rawget(hh.G, 'Scavenger') then pub_at = hh.now end end)
    ok(pub_at, 'published once Worldstone runs')
    ok(pub_at - t0 >= m.GRACE - 0.15 and pub_at - t0 <= m.GRACE + 0.25, 'after the grace from Worldstone: ' .. (pub_at - t0))
    ok(h.G.Scavenger._rosie == true, 'Rosie\'s table')
    local cond = nav.conditions['Rosie Looting']
    ok(cond, 'registered once published')
    -- Worldstone gone while Rosie walks to a drop.
    local item2 = legendary(h, h.pos:x() + 10, 0, {name = 'Helm_Legendary_Generic_039'})
    ok(h.run_until(function() return cond() == true end, 3), 'Rosie Looting true walking to a drop')
    h.G.Worldstone = nil
    eq(cond(), false, 'Rosie Looting false on the frame Worldstone goes')
    eq(h.G.Scavenger.is_busy(), false, 'the table answers false until it is removed')
    h.frame()
    eq(h.G.Scavenger, nil, 'removed on the next update')
    eq(h.logged('Worldstone is not running: Rosie stops acting as Scavenger'), 1, 'logged')
    local cond_true = 0
    ok(h.run_until(function() if cond() == true then cond_true = cond_true + 1 end; return item2.picked == true end, 10),
        'pickup goes on (1.0.21)\n' .. h.tail(8))
    eq(cond_true, 0, 'Rosie Looting stays false without Worldstone')
    -- Worldstone back: published again after the grace.
    h.G.Worldstone = ws.api
    h.run(m.GRACE + 0.5)
    ok(h.G.Scavenger and h.G.Scavenger._rosie, 'published again')
    -- A real Scavenger present and Worldstone gone: the real table stays.
    local real = real_scavenger(h)
    h.run(1)
    h.G.Worldstone = nil
    h.run(1)
    eq(h.G.Scavenger, real.api, 'a real Scavenger is never removed')
    h.assert_clean('h4')
end)

case('h5: the grace counts from Worldstone or Navigator, whichever was seen later; Worldstone without Navigator publishes', function()
    local h = new()
    local m = mimic(h)
    fake_worldstone(h, nil)
    h.run(2)
    eq(h.G.Scavenger, nil, 'inside the grace')
    fake_navigator(h).active = false
    local t0, pub_at = h.now, nil
    h.run(m.GRACE + 1, function(hh) if not pub_at and rawget(hh.G, 'Scavenger') then pub_at = hh.now end end)
    ok(pub_at and pub_at - t0 >= m.GRACE - 0.15, 'the grace restarted with Navigator: ' .. tostring(pub_at and pub_at - t0))
    local h2 = new()
    fake_worldstone(h2, nil)
    h2.run(m.GRACE + 1)
    ok(h2.G.Scavenger and h2.G.Scavenger._rosie, 'Worldstone alone: published after the grace')
    h.assert_clean('h5'); h2.assert_clean('h5b')
end)

case('i: gates, status and wanted items: dead, loading, disabled, paused, town trip, activity loot, Worldstone gone; guarded calls', function()
    local h = new({distance = 30})
    local _, ws = worldstone_run(h)
    local sc = h.G.Scavenger
    local near = legendary(h, 14, 0)
    local far = legendary(h, 0, 29.5, {name = 'Helm_Legendary_Generic_033'})
    local outside = legendary(h, -40, 0, {name = 'Helm_Legendary_Generic_034'})
    local wanted = sc.get_wanted_items()
    local set = {}
    for _, item in ipairs(wanted) do set[item] = true end
    ok(set[near] and set[far], 'wanted drops listed')
    ok(not set[outside], 'a drop outside the pickup distance is not listed')
    wanted[1] = nil
    ok(#sc.get_wanted_items() >= 2, 'the caller gets a copy')
    -- Review LOW (c): only drops Rosie would work now.
    eq(sc.pause('Worldstone'), true)
    eq(#sc.get_wanted_items(), 0, 'none while paused')
    eq(sc.resume('Worldstone'), true)
    h.G.TRISTRAM_LOOP_STATE = {status = function() return {running = true, owns_activity = true, controls_loot = true} end}
    eq(#sc.get_wanted_items(), 0, 'none while an activity owns the loot')
    h.G.TRISTRAM_LOOP_STATE = nil
    h.G.Worldstone = nil
    eq(#sc.get_wanted_items(), 0, 'none while Worldstone is gone')
    h.G.Worldstone = ws.api
    ok(#sc.get_wanted_items() >= 2, 'listed again')
    ok(h.run_until(function() return sc.is_busy() end, 3), 'busy walking to a drop')
    eq(sc.get_status().state, 'looting')
    h.dead = true
    eq(sc.is_busy(), false, 'false while dead'); h.dead = false
    local place = h.place
    h.place = h.P.limbo
    eq(sc.is_busy(), false, 'false in a loading screen'); h.place = place
    ok(sc.is_busy(), 'busy again')
    -- The town-trip gate on its own (a real trip also pauses pickup, which hides it).
    local life = h.mod('Rosie', 'rosie.private.town.core.lifecycle')
    mimic(h).configure({town_busy = function() return true end})
    eq(sc.is_busy(), false, 'false while a town trip runs')
    eq(#sc.get_wanted_items(), 0, 'no wanted items while a town trip runs')
    mimic(h).configure({town_busy = function() return life.busy() and true or false end})
    ok(sc.is_busy(), 'busy again after the trip gate')
    eq(h.as(CONSUMER, function() return h.G.RosiePlugin.disable() end), true)
    eq(sc.is_busy(), false, 'false when Rosie is off')
    local st = sc.get_status()
    eq(st.is_enabled, false); eq(st.state, 'disabled')
    eq(#sc.get_wanted_items(), 0, 'no wanted items while off (after the cache)')
    h.run(0.3)
    eq(#sc.get_wanted_items(), 0, 'no wanted items while off')
    eq(h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end), true)
    h.run(0.5)
    -- A town trip holds Navigator itself: never Scavenger busy during it.
    h.inventory = {}
    for i = 1, 3 do h.inventory[i] = h.gear() end
    local done = false
    eq(h.as(CONSUMER, function()
        return h.G.AlfredTheButlerPlugin.trigger_tasks_with_teleport('Consumer', function() done = true end)
    end), true, 'trip accepted')
    local busy_in_trip = 0
    ok(h.run_until(function()
        if h.as(CONSUMER, function() return h.G.AlfredTheButlerPlugin.get_status().running end) and sc.is_busy() then
            busy_in_trip = busy_in_trip + 1
        end
        return done
    end, 200), 'trip ends\n' .. h.tail(10))
    eq(busy_in_trip, 0, 'never busy during a town trip')
    eq(h.logged('Could not hold Scavenger'), 0, 'the own table is not held for the trip')
    -- Every entry point is guarded (a throwing gate, a throwing host list).
    local am = h.G.actors_manager
    local list = am.get_all_items
    am.get_all_items = function() error('host: item list unavailable') end
    h.run(0.3)
    eq(#sc.get_wanted_items(), 0, 'a throwing item list gives an empty list')
    am.get_all_items = list
    mimic(h).configure({enabled = function() error('boom') end})
    eq(sc.is_busy(), false); eq(sc.pause('X'), true); eq(sc.resume('X'), true)
    eq(type(sc.get_status()), 'table'); eq(type(sc.get_wanted_items()), 'table')
    h.assert_clean('i')
end)

print(string.format('scavenger mimic: %d checks, %d failures', checks, #failures))
if #failures > 0 then error(table.concat(failures, '\n')) end
