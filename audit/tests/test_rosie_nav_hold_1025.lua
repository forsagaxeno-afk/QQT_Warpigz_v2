-- QQT_Warpigz_v3 Rosie 1.0.25 (live 3.3.5, owner: Worldstone + Navigator +
-- Rosie acting as Scavenger): a boss dies, drops fall around the player,
-- Worldstone navigates to the portal and Rosie logs "Another move took the
-- player off X; leaving it for 4s (yield 1)" for 2-4 drops 0.4 s apart; the
-- player enters the portal with the drops on the ground
-- (audit/reviews/rosie_navigator_pickup_2026-09-28.md). Rosie yielded while
-- her own "Rosie Looting" condition held Navigator: Navigator's command was
-- still in flight (the host skips request_move while the player walks it) or
-- read late, and the 0.3 s yield came before Rosie's first resend.
-- 1.0.25: while "Rosie Looting" is true, a foreign destination gets a 2.5 s
-- grace per drop (no yield; the walk is re-asserted at once, a skipped
-- request is sent again with force_move_raw inside a short window); a
-- Navigator that keeps walking 0.5 s into the grace (busy, not paused) gets
-- one stop() per drop (at most 5 per pickup episode); the yield line carries
-- Navigator's state; the fight hold's calm tail keeps the stand-in busy.
-- Doubles from the investigation's repro (test_zz_repro_rosie_nav_yield.lua):
--   ideal   : Navigator reads every condition every frame
--   lag     : reads its conditions every `lag` s
--   inflight: request_move is skipped while the player moves and
--             clear_stored_path does not stop the in-game move
--   ignore  : honours no condition
-- Every case except the ones named "control" fails on Rosie 1.0.24.
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
local only = os.getenv('ONLY')
local function case(name, fn)
    if only and not name:find(only, 1, true) then return end
    local passed, err = xpcall(fn, debug.traceback)
    if passed then print('PASS nav hold 1.0.25: ' .. name)
    else failures[#failures + 1] = name; print('FAIL nav hold 1.0.25: ' .. name .. ': ' .. tostring(err):gsub('\nstack traceback:.*', '')) end
end
local CONSUMER = {name = 'Consumer', dir = ROOT .. '/audit/tests/', loaded = {}}
local function pgui(h) return h.mod('Rosie', 'rosie.private.pickup.gui').elements end

local PORTAL = {40, 0}
local DROPS = {
    {x = 3, y = 3, name = 'Item_Gemstone_Royal_Ruby', sno = 265750, bag = 'socketables'},
    {x = -3, y = 2.5, name = 'Item_Gemstone_Royal_Emerald', sno = 265751, bag = 'socketables'},
    {x = 2.5, y = -3.5, name = 'CraftingMaterial_Pure_Primordial_Dust', sno = 2533710},
    {x = -2.5, y = -3, name = 'Talisman_Seal_Horadric_Joint', bag = 'talismans'},
}

-- o.model: ideal | lag | inflight | ignore; o.look: Navigator walks `look` m
-- ahead (path following) instead of to the far target; o.n: drops;
-- o.walk_at / o.drop_at: s after the altar; o.add: an add next to the
-- player dies at that time (the fight hold); o.no_worldstone; o.no_stop:
-- Navigator without stop(); o.status: 'raises' | 'missing';
-- o.renav: after a stop Worldstone navigates again 'at_once' or only when
-- Scavenger.is_busy() is false ('idle', the default); o.nav_last: Navigator
-- issues its command after Rosie in each frame (its command always wins).
local function run(o)
    o = o or {}
    local h = J.new({rosie = true, dirs = {}, place = 'pit', speed = o.speed or 4,
        request_move_redundant = o.model == 'inflight' and 'any' or nil})
    h.assert_clean('load')
    h.pos = h.v(0, 0)
    h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end)
    h.frame()
    pgui(h).general.distance_slider:set(12)
    pgui(h).item_types.gemstone_items_toggle:set(true)
    if o.model == 'inflight' then
        -- clear_stored_path clears the plugin's stored path, not the move the game executes
        h.G.pathfinder.clear_stored_path = function() h.native = nil end
    end
    local nav = {conditions = {}, names = {}, active = false, paused_frames = 0, walk_frames = 0,
        next_read = -math.huge, cached = false, api = {}, cmds = 0, stops = 0, status_calls = 0}
    local function read_all()
        local p = false
        for _, name in ipairs(nav.names) do
            local okc, on = pcall(nav.conditions[name])
            if okc and on == true then p = true end
        end
        return p
    end
    function nav.paused(hh)
        if o.model == 'ignore' then return false end
        if o.model == 'lag' then
            if hh.now >= nav.next_read then nav.cached = read_all(); nav.next_read = hh.now + (o.lag or 0.5) end
            return nav.cached
        end
        return read_all()
    end
    function nav.api.set_pause_condition(name, fn)
        if not nav.conditions[name] then nav.names[#nav.names + 1] = name end
        nav.conditions[name] = fn
    end
    function nav.api.navigate(opts)
        nav.target, nav.on_arrive, nav.active = opts.position, opts.on_arrive, true
        nav.arrive = opts.arrive_distance or 2
        return 1
    end
    if not o.no_stop then function nav.api.stop() nav.active = false; nav.stops = nav.stops + 1 end end
    if o.status ~= 'missing' then
        function nav.api.get_status()
            nav.status_calls = nav.status_calls + 1
            if o.status == 'raises' then error('Navigator.get_status exploded') end
            return {state = nav.active and 'travelling' or 'idle', owner = 'Worldstone', is_busy = nav.active,
                is_paused = nav.last_paused == true, priority = 0, mode = 'travel'}
        end
    end
    function nav.step(hh)
        if not nav.active or hh.place ~= hh.P.pit then return end
        local d = hh.pos:dist_to_ignore_z(nav.target)
        if d <= nav.arrive then
            nav.active = false
            if nav.on_arrive then nav.on_arrive(hh) end
            return
        end
        local p = nav.paused(hh)
        nav.last_paused = p
        if p then nav.paused_frames = nav.paused_frames + 1; return end
        nav.walk_frames = nav.walk_frames + 1
        local goal = nav.target
        if o.look and d > o.look then
            goal = hh.v(hh.pos:x() + (nav.target:x() - hh.pos:x()) / d * o.look, hh.pos:y() + (nav.target:y() - hh.pos:y()) / d * o.look)
        end
        nav.cmds = nav.cmds + 1
        hh.goal = goal -- the game's move command (the mover the host is executing)
    end
    h.G.Navigator = nav.api
    local ws = {phase = 'idle', navs = 0}
    if not o.no_worldstone then
        nav.api.set_pause_condition('Worldstone Looting', function()
            local sc = rawget(h.G, 'Scavenger')
            if type(sc) ~= 'table' or type(sc.is_busy) ~= 'function' then return false end
            return sc.is_busy() == true
        end)
        h.G.Worldstone = {get_status = function() return {} end}
    end
    h.run(4) -- Worldstone seen for more than GRACE s: the stand-in is published
    if not o.no_worldstone then ok(h.G.Scavenger and h.G.Scavenger._rosie == true, 'stand-in published') end
    local r = {h = h, nav = nav, ws = ws, yields = {}, busy_first = nil, items = {}, busy_since = nil, busy_max = 0}
    local t0 = h.now -- the altar
    r.t0 = t0
    local function walk()
        ws.navs = ws.navs + 1
        nav.api.navigate({owner = 'Worldstone', position = h.v(PORTAL[1], PORTAL[2]), arrive_distance = 2,
            on_arrive = function(hh) ws.phase = 'gone'; r.portal_t = hh.now - t0 end})
    end
    if o.add then
        r.enemy = h.actor('pit', 'Joint_Monster', 1, 0, {enemy = true, health = 1e9, reach = 0})
        h.at(o.add, function() r.enemy.health, r.enemy.interactable = 0, false; r.kill_t = h.now - t0 end)
    end
    h.at(o.drop_at or 13.5, function()
        for i, d in ipairs(o.drops or DROPS) do
            if i > (o.n or #DROPS) then break end
            r.items[#r.items + 1] = h.drop('pit', d.x, d.y, {name = d.name, sno = d.sno, bag = d.bag, rarity = 0})
        end
    end)
    local walk_at = o.walk_at or 15
    local stops = 0
    local function frame()
        local n = #h.log
        if o.nav_last then h.frame(); nav.step(h) else nav.step(h); h.frame() end
        if ws.phase == 'idle' and h.now - t0 >= walk_at then ws.phase = 'walk'; r.walk_t = h.now - t0; walk() end
        local sc = rawget(h.G, 'Scavenger')
        local busy = type(sc) == 'table' and sc._rosie == true and sc.is_busy() == true
        -- Worldstone navigates again after a stop (o.renav)
        if ws.phase == 'walk' and not nav.active and nav.stops > stops then
            if o.renav == 'at_once' or not busy then stops = nav.stops; walk() end
        end
        if busy and not r.busy_first and #r.items > 0 then r.busy_first = h.now - t0 end
        if busy then
            r.busy_since = r.busy_since or h.now
            r.busy_max = math.max(r.busy_max, h.now - r.busy_since)
            if r.enemy and (r.enemy.health or 0) > 0 then r.busy_in_fight = true end
        else r.busy_since = nil end
        for i = n + 1, #h.log do
            if h.log[i]:find('Another move took the player off', 1, true) then
                r.yields[#r.yields + 1] = {t = h.now - t0, busy = busy, line = h.log[i]}
            end
        end
    end
    r.frame = frame
    while ws.phase ~= 'gone' and h.now - t0 < (o.limit or 60) do frame() end
    r.picked, r.left = 0, 0
    for _, it in ipairs(r.items) do if it.picked then r.picked = r.picked + 1 else r.left = r.left + 1 end end
    r.forced = h.count(h.moves, function(m) return m.kind == 'force_move_raw' and m.owner == 'Rosie' end)
    print(string.format('  %-44s picked=%d/%d yields=%d first_busy=%s walk=%.1f portal=%s stops=%d forced=%d',
        o.label or '?', r.picked, #r.items, #r.yields, r.busy_first and string.format('%.2f', r.busy_first) or '-',
        r.walk_t or -1, r.portal_t and string.format('%.1f', r.portal_t) or 'never', nav.stops, r.forced))
    h.assert_clean(o.label)
    return r
end
local function rosie_tail(h, n)
    local out = {}
    for _, line in ipairs(h.log) do if line:find('[Rosie', 1, true) then out[#out + 1] = line end end
    local keep = {}
    for i = math.max(1, #out - (n or 12) + 1), #out do keep[#keep + 1] = out[i] end
    return table.concat(keep, '\n')
end

case('N1 in-flight far-target command, Navigator walking before the drop: 1/1 picked, no yield', function()
    local r = run({label = 'N1 inflight far, walk first, 1 drop', model = 'inflight', n = 1, walk_at = 13.0})
    eq(r.picked, 1, 'picked (1.0.24: 0/1, yield at +0.4 s with busy=true)\n' .. rosie_tail(r.h))
    eq(#r.yields, 0, 'no "Another move took the player off"')
    ok(r.portal_t ~= nil, 'Worldstone still reaches the portal')
    ok(r.forced <= 13, 'force_move_raw calls per drop <= 13: ' .. r.forced)
end)

case('N2 Navigator reading its conditions every 1 s, an add dies 0.7 s after the drops: 2/2 picked', function()
    local r = run({label = 'N2 lag 1.0, add, 2 drops', model = 'lag', lag = 1.0, n = 2, add = 14.2, look = 6})
    eq(r.picked, 2, 'picked (1.0.24: 0/2)\n' .. rosie_tail(r.h))
    eq(#r.yields, 0, 'no yield')
    ok(r.portal_t ~= nil, 'Worldstone still reaches the portal')
end)

case('N3 in-flight command with four drops (path following and far target): every drop taken, force_move_raw bounded', function()
    for _, look in ipairs({6, false}) do
        local r = run({label = 'N3 inflight look=' .. tostring(look), model = 'inflight', look = look or nil, walk_at = 13.0})
        eq(r.picked, #DROPS, 'all picked (1.0.24: 0-1 of 4)\n' .. rosie_tail(r.h))
        eq(#r.yields, 0, 'no yield')
        ok(r.forced <= 13 * #DROPS, 'force_move_raw <= 13 per drop: ' .. r.forced)
        ok(r.portal_t ~= nil, 'the portal is still reached')
    end
end)

case('N4 Navigator that ignores every condition and has no stop(): one yield per drop, the first 2.5-3.0 s after busy, no freeze', function()
    -- one drop behind the player's route: the grace runs out once
    local r = run({label = 'N4 ignore, no stop(), 1 drop behind', model = 'ignore', look = 6, no_stop = true, nav_last = true,
        walk_at = 13.0, drops = {DROPS[2]}})
    eq(#r.yields, 1, 'one yield after the grace\n' .. rosie_tail(r.h))
    local dt = r.yields[1].t - (r.busy_first or 0)
    ok(dt >= 2.4, string.format('the grace ran first (1.0.24: 0.3-0.4 s): %.2f s', dt))
    ok(dt <= 2.5 + 0.3 + 0.2 + 0.05, string.format('first yield %.2f s after busy', dt))
    ok(r.portal_t ~= nil, 'the player kept advancing: the portal is reached')
    ok(r.yields[1].line:find('paused=false', 1, true), 'the yield line carries Navigator\'s state: ' .. r.yields[1].line)
    ok(r.yields[1].line:find('Rosie Looting=true', 1, true), 'and the Rosie Looting reading')
    -- four drops: never a second yield for the same drop
    local r4 = run({label = 'N4 ignore, no stop(), 4 drops', model = 'ignore', look = 6, no_stop = true, nav_last = true, walk_at = 13.0})
    local per = {}
    for _, y in ipairs(r4.yields) do
        local name = y.line:match('player off (.-);')
        per[name] = (per[name] or 0) + 1
    end
    for name, n in pairs(per) do eq(n, 1, 'yields for ' .. tostring(name)) end
    ok(r4.portal_t ~= nil, 'four drops: the portal is reached')
end)

case('N5 Navigator that ignores every condition, Worldstone navigates again once Scavenger is idle: 4/4 picked, <= 4 stop() calls, one stop line', function()
    local r = run({label = 'N5 ignore + stop, renav idle', model = 'ignore', look = 6, nav_last = true})
    eq(r.picked, #DROPS, 'all picked (1.0.24: 0/4)\n' .. rosie_tail(r.h))
    ok(r.nav.stops >= 1 and r.nav.stops <= #DROPS, 'stop() calls: ' .. r.nav.stops)
    eq(r.h.logged('[Rosie pickup] Navigator kept moving while "Rosie Looting" held it'), 1, 'logged once per episode\n' .. rosie_tail(r.h))
    ok(r.portal_t ~= nil, 'Worldstone still reaches the portal')
end)

case('N6 Worldstone navigates again at once after each stop(): stops bounded, the portal is reached, no busy stretch past the 20 s cap', function()
    local r = run({label = 'N6 ignore + stop, renav at once', model = 'ignore', look = 6, renav = 'at_once', nav_last = true})
    ok(r.nav.stops >= 1 and r.nav.stops <= 5, 'stop() calls per episode <= 5: ' .. r.nav.stops)
    ok(r.portal_t ~= nil, 'the portal is reached\n' .. rosie_tail(r.h))
    ok(r.busy_max <= 20.5, string.format('longest busy stretch %.1f s', r.busy_max))
    ok(r.picked >= 1, 'the grace still wins some drops: ' .. r.picked)
end)

case('N7 the yield line still prints when Navigator.get_status raises or is missing', function()
    for _, st in ipairs({'raises', 'missing'}) do
        local r = run({label = 'N7 ignore, get_status ' .. st, model = 'ignore', look = 6, no_stop = true, status = st, nav_last = true,
            walk_at = 13.0, drops = {DROPS[2]}})
        ok(#r.yields >= 1, st .. ': yielded\n' .. rosie_tail(r.h))
        local want = st == 'raises' and 'get_status raised' or 'without get_status'
        ok(r.yields[1].line:find(want, 1, true), st .. ': ' .. r.yields[1].line)
    end
end)

case('N8 control: without Worldstone the first yield still comes about 0.3 s after the foreign move (1.0.21), no diagnostics, no force', function()
    local r = run({label = 'N8 no Worldstone, ideal, 1 drop', model = 'ideal', n = 1, look = 6, no_worldstone = true, walk_at = 13.8, limit = 20})
    ok(#r.yields >= 1, 'yielded\n' .. rosie_tail(r.h))
    local dt = r.yields[1].t - r.walk_t
    ok(dt <= 0.8, string.format('first yield %.2f s after the foreign move', dt))
    ok(not r.yields[1].line:find('[Rosie Looting=', 1, true), 'no Navigator diagnostics without the stand-in: ' .. r.yields[1].line)
    eq(r.forced, 0, 'no force_move_raw')
    eq(r.nav.stops, 0, 'Navigator never stopped')
end)

case('N9 calm tail: Scavenger reads busy within 0.3 s of the kill, never while an enemy is near; with an in-flight Navigator every drop is taken', function()
    local r = run({label = 'N9 add dies, drops 4 m, ideal', model = 'ideal', look = 6, add = 14.2, n = 2, walk_at = 15.4})
    ok(r.kill_t, 'the add died')
    ok(not r.busy_in_fight, 'never busy while the add lived')
    ok(r.busy_first and r.busy_first - r.kill_t <= 0.3, string.format('busy %.2f s after the kill (1.0.24: about 1.1 s)',
        (r.busy_first or 99) - r.kill_t))
    local r2 = run({label = 'N9 add dies, in-flight Navigator', model = 'inflight', look = 6, add = 14.2, n = 2, walk_at = 14.3})
    eq(r2.picked, 2, 'in-flight: 2/2 (1.0.24: 1/2, 2 yields)\n' .. rosie_tail(r2.h))
    eq(#r2.yields, 0, 'no yield')
end)

case('N10 Worldstone pausing pickup through Scavenger: one line per pause episode (1.0.24: silent)', function()
    local h = J.new({rosie = true, dirs = {}, place = 'pit'})
    h.assert_clean('load')
    h.pos = h.v(0, 0)
    h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end)
    h.frame()
    h.G.Navigator = {set_pause_condition = function() end, get_status = function() return {} end}
    h.G.Worldstone = {get_status = function() return {} end}
    h.run(4)
    local sc = h.G.Scavenger
    ok(sc and sc._rosie == true, 'stand-in published')
    local line = '[Rosie pickup] Paused by Worldstone (through Scavenger)'
    eq(sc.pause('Worldstone'), true, 'paused')
    h.run(1)
    eq(h.logged(line), 1, 'the pause start is logged\n' .. rosie_tail(h))
    eq(sc.pause('Worldstone'), true, 'a repeated pause is held')
    h.run(1)
    eq(h.logged(line), 1, 'a repeated pause adds no line')
    eq(h.as(CONSUMER, function() return h.G.LooteerPlugin.status().detail end), 'Paused by Worldstone.', 'status names Worldstone')
    sc.resume('Worldstone')
    h.run(1)
    sc.pause('Worldstone')
    h.run(1)
    eq(h.logged(line), 2, 'a new pause episode, a new line')
    h.assert_clean('N10')
end)

print(string.format('rosie nav hold 1.0.25: %d checks, %d failures', checks, #failures))
if #failures > 0 then error(#failures .. ' nav-hold case(s) failed: ' .. table.concat(failures, ' | ')) end
