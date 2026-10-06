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
-- Every case except N11, N15, N17, N18 and the ones named "control" or
-- "guard" fails on Rosie 1.0.24 (N16 too: 1.0.24 yields and the ramp drop is
-- not taken; 1.0.24 never stops Navigator, so it passes N17 and N18).
-- N11 and N13-N16 fail on the first 1.0.25 build (fd70b6d, review: its
-- stop() fired on get_status alone, its grace applied beside an idle
-- Worldstone and sent interactions every frame); 1.0.24 had no grace, no
-- stop and no force, so it passes N11, N14 and N15.
-- Review round 3 (the second 1.0.25 build, de12a7d, fails each): N13 at the
-- live pulse cadence (0.05 / 0.016 s frames: the watchdog read the cached
-- pre-stop reading and disarmed), N4 at 0.05 / 0.016 s frames (the grace
-- outlasted the drop's Distance range and nothing was logged), N17/N18 (a Navigator that
-- honours the hold but never reports is_paused was stopped for another
-- mover's or a rotation's new points), N19 (no stop without Navigator's own
-- progress). The Navigator double reports remaining_distance from the
-- player's position every read, paused or not (the worst case for N17/N18).
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
-- Scavenger.is_busy() is false ('idle', the default) or 'never'; o.nav_last:
-- Navigator issues its command after Rosie in each frame (its command always
-- wins); o.paused_flag='never': get_status never reports is_paused;
-- o.no_force: the host has no force_move_raw; o.rd='none': get_status
-- reports no remaining_distance; o.fdt: the frame step (default 0.1 s; live
-- QQT pulses every game frame); o.setup(h, nav): after the stand-in is up.
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
    if o.no_force then h.G.pathfinder.force_move_raw = nil end
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
    if not o.no_stop then function nav.api.stop() nav.active = false; nav.stops = nav.stops + 1; nav.stopped_at = h.now end end
    -- QQT_Warpigz_v3 1.0.29: o.linger: get_status keeps reporting busy that many s after stop()
    local function busy() return nav.active or (o.linger ~= nil and nav.stopped_at ~= nil and h.now - nav.stopped_at < o.linger) end
    if o.status ~= 'missing' then
        function nav.api.get_status()
            nav.status_calls = nav.status_calls + 1
            if o.status == 'raises' then error('Navigator.get_status exploded') end
            return {state = busy() and 'travelling' or 'idle', owner = 'Worldstone', is_busy = busy(),
                is_paused = o.paused_flag ~= 'never' and nav.last_paused == true, priority = 0, mode = 'travel',
                remaining_distance = o.rd ~= 'none' and (busy() and nav.target and h.pos:dist_to_ignore_z(nav.target) or 0) or nil}
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
    if o.setup then o.setup(h, nav) end
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
        if o.nav_last then h.frame(o.fdt); nav.step(h) else nav.step(h); h.frame(o.fdt) end
        if ws.phase == 'idle' and h.now - t0 >= walk_at then ws.phase = 'walk'; r.walk_t = h.now - t0; walk() end
        local sc = rawget(h.G, 'Scavenger')
        local busy = type(sc) == 'table' and sc._rosie == true and sc.is_busy() == true
        -- Worldstone navigates again after a stop (o.renav)
        if ws.phase == 'walk' and not nav.active and nav.stops > stops then
            if o.renav ~= 'never' and (o.renav == 'at_once' or not busy) then stops = nav.stops; walk() end
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
            -- review round 3: a drop that left the wanted list under the grace
            if h.log[i]:find('is no longer wanted (', 1, true) then r.lost = r.lost or {}; r.lost[#r.lost + 1] = h.log[i] end
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
        eq(r.picked, #DROPS, 'all picked\n' .. rosie_tail(r.h))
        eq(#r.yields, 0, 'no yield (1.0.24: 1 yield with look=6; the far target: 0-1 of 4)')
        ok(r.forced <= 13 * #DROPS, 'force_move_raw <= 13 per drop: ' .. r.forced)
        ok(r.portal_t ~= nil, 'the portal is still reached')
    end
end)

case('N4 Navigator that ignores every condition and has no stop(): one yield per drop, the first 2.5-3.0 s after busy, no freeze', function()
    -- one drop behind the player's route: the grace runs out once. Review
    -- round 3: at 0.05 / 0.016 s frames the player is dragged out of the
    -- Distance range inside the grace; the drop then gets the "no longer
    -- wanted" line with the same diagnostics (second 1.0.25 build: no line)
    for _, fdt in ipairs({0.1, 0.05, 0.016}) do
        local r = run({label = 'N4 ignore, no stop(), 1 drop behind, frame ' .. fdt, model = 'ignore', look = 6, no_stop = true, nav_last = true,
            walk_at = 13.0, drops = {DROPS[2]}, fdt = fdt})
        local lost = r.lost or {}
        eq(#r.yields + #lost, 1, 'frame ' .. fdt .. ': one line for the drop after the grace (second 1.0.25 build at 0.05 / 0.016 s: none)\n'
            .. rosie_tail(r.h))
        local line = #lost == 1 and lost[1] or r.yields[1].line
        if #r.yields == 1 then
            local dt = r.yields[1].t - (r.busy_first or 0)
            ok(dt >= 2.4, string.format('the grace ran first (1.0.24: 0.3-0.4 s): %.2f s', dt))
            ok(dt <= 2.5 + 0.3 + 0.2 + 0.05, string.format('first yield %.2f s after busy', dt))
            ok(line:find('Rosie Looting=true', 1, true), 'the yield came while Rosie Looting held: ' .. line)
        else
            ok(line:find('Emerald is no longer wanted (outside pickup distance', 1, true), line)
        end
        ok(r.portal_t ~= nil, 'the player kept advancing: the portal is reached')
        ok(line:find('paused=false', 1, true), 'the line carries Navigator\'s state: ' .. line)
        ok(line:find('[Rosie Looting=', 1, true) and line:find('grace=', 1, true), 'and the Rosie Looting reading: ' .. line)
    end
    -- four drops: the grace runs once per drop; a later yield of the same
    -- drop (after its 4 s rest) is the 1.0.21 one, with no second grace
    -- (its line still shows the first grace's age)
    local r4 = run({label = 'N4 ignore, no stop(), 4 drops', model = 'ignore', look = 6, no_stop = true, nav_last = true, walk_at = 13.0})
    local per = {}
    for _, y in ipairs(r4.yields) do
        local name = y.line:match('player off (.-);')
        per[name] = (per[name] or 0) + 1
        if per[name] >= 2 then
            local g = tonumber(y.line:match('grace=([%d%.]+)s'))
            ok(g and g >= 4, 'no second grace for ' .. tostring(name) .. ': ' .. y.line)
        end
    end
    for name, n in pairs(per) do ok(n <= 2, 'yields for ' .. tostring(name) .. ': ' .. n) end
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

case('N10 Worldstone pausing pickup through Scavenger: one line per pause episode, at most one per 60 s per caller (1.0.24: silent)', function()
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
    eq(h.logged(line), 1, 'a new pause episode within 60 s: no new line (a caller cycling pause/resume)')
    sc.resume('Worldstone')
    h.run(60)
    sc.pause('Worldstone')
    h.run(1)
    eq(h.logged(line), 2, 'a new pause episode 60 s later, a new line')
    h.assert_clean('N10')
end)

-- Review of the first 1.0.25 build: its stop() fired 0.5 s into the grace on
-- get_status alone (busy, not paused), which cannot tell a Navigator that
-- ignores "Rosie Looting" from one that honours it with a command still in
-- flight or read late but never reports is_paused. If Worldstone did not
-- navigate again after the stop, the run froze.
case('N11 in-flight command, is_paused never reported, no force_move_raw, Worldstone never navigates again: no stop(), no freeze', function()
    local r = run({label = 'N11 inflight, paused never, no force, renav never', model = 'inflight', walk_at = 13.0,
        paused_flag = 'never', no_force = true, renav = 'never', limit = 40})
    eq(r.nav.stops, 0, 'a command in flight is not stopped (first 1.0.25 build: stopped)\n' .. rosie_tail(r.h))
    ok(r.portal_t ~= nil, 'the portal is reached (first 1.0.25 build: never)')
end)
case('N12 guard: Navigator reading its conditions 0.9 s late, is_paused never reported, no force_move_raw, no renavigate: no stop(), no freeze', function()
    local r = run({label = 'N12 lag 1.0, paused never, no force, renav never', model = 'lag', lag = 1.0, look = 6, walk_at = 13.4, nav_last = true,
        paused_flag = 'never', no_force = true, renav = 'never', limit = 40})
    eq(r.nav.stops, 0, 'a read up to 1 s late is not stopped (first 1.0.25 build: stopped)\n' .. rosie_tail(r.h))
    ok(r.portal_t ~= nil, 'the portal is reached (first 1.0.25 build: never)')
end)
case('N13 a Navigator that ignores the hold is stopped once; when nothing navigates again the watchdog says so and Rosie stops no more (0.1, 0.05 and 0.016 s frames)', function()
    -- review round 3: at the live pulse cadence the watchdog read the cached
    -- pre-stop reading and disarmed (second 1.0.25 build: no line at 0.05 / 0.016 s)
    for _, fdt in ipairs({0.1, 0.05, 0.016}) do
        local r = run({label = 'N13 ignore + stop, renav never, frame ' .. fdt, model = 'ignore', look = 6, nav_last = true, renav = 'never',
            limit = 30, fdt = fdt})
        eq(r.nav.stops, 1, 'frame ' .. fdt .. ': one stop() (the evidence: new commands and Navigator\'s own progress while held)\n' .. rosie_tail(r.h))
        eq(r.h.logged('[Rosie pickup] Navigator has stayed idle 5s since Rosie stopped its request'), 1,
            'frame ' .. fdt .. ': the watchdog line (first 1.0.25 build: none; second: none at 0.05 / 0.016 s)\n' .. rosie_tail(r.h))
        -- a new episode: Worldstone navigates again, still ignoring the hold; Rosie no longer stops it
        local h, nav = r.h, r.nav
        nav.api.navigate({owner = 'Worldstone', position = h.v(PORTAL[1], PORTAL[2]), arrive_distance = 2})
        h.drop('pit', h.pos:x() - 3, h.pos:y() + 2, {name = 'Item_Gemstone_Royal_Topaz', sno = 265752, bag = 'socketables', rarity = 0})
        local y0, l0, t1 = #r.yields, #(r.lost or {}), h.now
        while h.now - t1 < 6 - 1e-9 do r.frame() end
        -- after its grace the drop yields, or (dragged out of the Distance range first) is logged "no longer wanted"
        local yielded = #r.yields > y0 and r.yields[#r.yields].line:find('Topaz', 1, true)
        local lost = #(r.lost or {}) > l0 and r.lost[#r.lost]:find('Topaz is no longer wanted', 1, true)
        ok(yielded or lost, 'frame ' .. fdt .. ': the new drop ran its grace, then yielded or was logged out of range\n' .. rosie_tail(h))
        eq(nav.stops, 1, 'frame ' .. fdt .. ': no further stop() this session')
    end
end)
case('N14 WS idle control: Worldstone installed but Navigator idle, a farm mover takes the path: the 1.0.24 yield (0.3 s), no grace, no force', function()
    local h = J.new({rosie = true, dirs = {}, place = 'pit', request_move_redundant = 'any'})
    h.pos = h.v(0, 0)
    h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end)
    h.frame()
    pgui(h).general.distance_slider:set(30)
    h.G.pathfinder.clear_stored_path = function() h.native = nil end
    h.G.Navigator = {set_pause_condition = function() end, stop = function() error('never stopped') end,
        get_status = function() return {state = 'idle', owner = 'Worldstone', is_busy = false, is_paused = false} end}
    h.G.Worldstone = {get_status = function() return {} end}
    h.run(4)
    ok(h.G.Scavenger and h.G.Scavenger._rosie == true, 'stand-in published')
    local it = h.drop('pit', 8, 0, {rarity = 5, ga = 3, name = 'Helm_Legendary_Generic_009', refuse = function() return true end})
    local t0 = h.now
    h.run(1.0) -- Rosie walks to the drop
    local t1 = h.now
    local first
    h.run(3, function(hh)
        hh.goal = hh.v(-12, 0) -- the farm plugin's move command (in flight)
        if not first and hh.logged('Another move took the player off', t0) > 0 then first = hh.now - t1 end
    end)
    ok(first and first <= 0.8, 'yielded within 0.8 s (first 1.0.25 build: 2.5 s grace): ' .. tostring(first) .. '\n' .. rosie_tail(h))
    eq(h.count(h.moves, function(m) return m.kind == 'force_move_raw' and m.owner == 'Rosie' end), 0, 'no force_move_raw')
    ok(it.picked ~= true)
end)

case('N15 the grace does not speed up interactions: a refused drop in reach or in the 2-3 m band keeps its cadence (first 1.0.25 build: every frame)', function()
    -- an in-flight far command the player is not executing (speed 0) and a
    -- clear_stored_path that does not cancel it: the grace re-asserts every pulse
    local function tries(worldstone, x, dt)
        local h = J.new({rosie = true, dirs = {}, place = 'pit'})
        h.pos = h.v(0, 0)
        h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end)
        h.frame()
        pgui(h).general.distance_slider:set(15)
        if worldstone then
            h.G.Navigator = {set_pause_condition = function() end, stop = function() end,
                get_status = function() return {state = 'travelling', owner = 'Worldstone', is_busy = true, is_paused = true} end}
            h.G.Worldstone = {get_status = function() return {} end}
        end
        h.run(4)
        h.G.pathfinder.clear_stored_path = function() h.native = nil end
        h.speed = 0
        local it = h.drop('pit', x, 0, {rarity = 5, ga = 3, name = 'Helm_Legendary_Generic_061', refuse = function() return true end})
        local n, take = 0, it.on_interact
        it.on_interact = function(hh, a) n = n + 1; if take then take(hh, a) end end
        h.goal = h.v(30, 0)
        h.run(3, function(hh) hh.goal = hh.v(30, 0) end, dt)
        return n
    end
    for _, x in ipairs({0.9, 2.5}) do
        for _, dt in ipairs({0.1, 0.016}) do
            local with, without = tries(true, x, dt), tries(false, x, dt)
            ok(with <= 2 * without + 1, string.format('drop at %.1f m, frame %.3f s: %d interactions in 3 s under the grace, %d without (first 1.0.25 build: 28-42 in reach, 13 in the band)',
                x, dt, with, without))
        end
    end
end)

case('N16 a drop on a ramp (z 3 m): Rosie\'s own in-flight walk is not forced again every resend (the force check is 2D)', function()
    local h = J.new({rosie = true, dirs = {}, place = 'pit', request_move_redundant = 'any'})
    h.pos = h.v(0, 0)
    h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end)
    h.frame()
    pgui(h).general.distance_slider:set(15)
    h.G.pathfinder.clear_stored_path = function() h.native = nil end
    h.G.Navigator = {set_pause_condition = function() end, stop = function() end,
        get_status = function() return {state = 'travelling', owner = 'Worldstone', is_busy = true, is_paused = true} end}
    h.G.Worldstone = {get_status = function() return {} end}
    h.run(4)
    local it = h.drop('pit', 6, 4, {rarity = 5, ga = 3, name = 'Helm_Legendary_Generic_066'})
    it.pos = h.v(6, 4, 3)
    h.goal = h.v(-30, 0) -- Navigator's command in flight
    h.run(4)
    ok(it.picked == true, 'taken\n' .. rosie_tail(h))
    local forced = h.count(h.moves, function(m) return m.kind == 'force_move_raw' and m.owner == 'Rosie' end)
    eq(forced, 1, 'one force_move_raw (first 1.0.25 build: the 3D check forced Rosie\'s own walk again)')
end)

-- ── Review round 3 (second 1.0.25 build, de12a7d) ───────────────────────────
case('N17 a Navigator that honours the hold but never reports is_paused, another mover stepping the player 4.5 m every 0.5-1.3 s: no stop(), the portal is reached', function()
    for _, every in ipairs({0.5, 0.8, 1.3}) do
        local r = run({label = 'N17 ideal, paused never, dodge every ' .. every, model = 'ideal', look = 6, walk_at = 13.0,
            paused_flag = 'never', renav = 'never', limit = 45,
            drops = {{x = -9, y = 3, name = 'Item_Gemstone_Royal_Emerald', sno = 265751, bag = 'socketables'}},
            setup = function(h)
                local k = 0
                local function dodge()
                    k = k + 1
                    local sc = rawget(h.G, 'Scavenger')
                    if type(sc) == 'table' and sc._rosie == true and sc.is_busy() == true then
                        h.goal = h.v(h.pos:x() + 4.5 * math.cos(k * 2.1), h.pos:y() + 4.5 * math.sin(k * 2.1))
                    end
                    h.at(every, dodge)
                end
                h.at(every, dodge)
            end})
        eq(r.nav.stops, 0, 'every ' .. every .. ' s: a Navigator honouring the hold is not stopped (second 1.0.25 build: stopped at 0.5 / 0.8 s)\n'
            .. rosie_tail(r.h))
        ok(r.portal_t ~= nil, 'every ' .. every .. ' s: the portal is reached')
    end
end)
case('N18 a rotation stepping the player to a new evade point every 0.3 s (in a fight or not) beside a Navigator that honours the hold: no stop()', function()
    local function go(o)
        local h = J.new({rosie = true, dirs = {}, place = 'pit'})
        h.pos = h.v(0, 0)
        h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end)
        h.frame()
        pgui(h).general.distance_slider:set(15)
        local nav, target = {active = true, stops = 0, conds = {}}, h.v(40, 0)
        h.G.Navigator = {
            set_pause_condition = function(name, fn) nav.conds[name] = fn end,
            stop = function() nav.active = false; nav.stops = nav.stops + 1 end,
            get_status = function() return {state = nav.active and 'travelling' or 'idle', owner = 'Worldstone', is_busy = nav.active,
                is_paused = false, remaining_distance = nav.active and h.pos:dist_to_ignore_z(target) or 0} end,
        }
        h.G.Worldstone = {get_status = function() return {} end}
        h.run(4)
        ok(h.G.Scavenger and h.G.Scavenger._rosie == true, 'stand-in published')
        if o.enemy then h.actor('pit', 'Joint_Monster', o.enemy, 0, {enemy = true, health = 1e9, reach = 0}) end
        local it = h.drop('pit', o.dx, 0.3, {rarity = 5, ga = 3, name = 'Helm_Legendary_Generic_031', refuse = o.refuse and function() return true end or nil})
        local k, t0 = 0, h.now
        h.run(12, function(hh)
            local held = false
            for _, fn in pairs(nav.conds) do local okc, v = pcall(fn); if okc and v == true then held = true end end
            if hh.now - t0 < 8 then -- the rotation: a new evade point every 0.3 s
                local slot = math.floor((hh.now - t0) / 0.3)
                if slot ~= k then k = slot; hh.goal = hh.v(3 * math.cos(slot), 3 * math.sin(slot)) end
            end
            if nav.active and not held then hh.goal = target end -- Navigator honours the hold
        end, o.fdt)
        return nav, it, h
    end
    for _, o in ipairs({{enemy = 2.5, dx = -2.8, refuse = true}, {dx = -4, refuse = true}, {enemy = 2.5, dx = -2.8}, {dx = -4}}) do
        for _, fdt in ipairs({0.1, 0.05}) do
            o.fdt = fdt
            local nav, it, h = go(o)
            eq(nav.stops, 0, string.format('enemy %s, drop %.1f m%s, frame %.2f: no stop() (second 1.0.25 build: one for a refused drop)\n%s',
                tostring(o.enemy), -o.dx, o.refuse and ' refused' or '', fdt, rosie_tail(h)))
            eq(h.logged('Navigator kept moving while'), 0, 'no stop line')
            if not o.refuse then ok(it.picked == true, 'a takeable drop is taken\n' .. rosie_tail(h)) end
        end
    end
end)
case('N19 guard: a Navigator that ignores the hold but reports no remaining_distance is not stopped (no evidence tied to it); the grace and one yield bound the drop', function()
    local r = run({label = 'N19 ignore + stop, no remaining_distance', model = 'ignore', look = 6, nav_last = true, walk_at = 13.0,
        drops = {DROPS[2]}, rd = 'none', renav = 'never', limit = 30})
    eq(r.nav.stops, 0, 'no stop()\n' .. rosie_tail(r.h))
    -- one yield after the grace, or (dragged out of the Distance range first, finer frames) the "no longer wanted" line
    eq(#r.yields + #(r.lost or {}), 1, 'one line after the grace\n' .. rosie_tail(r.h))
    ok(r.portal_t ~= nil, 'the portal is reached')
end)

-- QQT_Warpigz_v3 1.0.29 (post-release review of 1.0.26): the watchdog
-- disarmed on any busy reading 0.5 s or more after Navigator.stop(); a real
-- Navigator that keeps reporting busy for a while after stop() never let it
-- fire. Only an idle -> busy transition disarms it now.
case('N20 a Navigator that keeps reporting busy after stop() (3 s, or for good): the watchdog still fires once and Rosie stops no more', function()
    for _, linger in ipairs({3, 1e9}) do
        local r = run({label = 'N20 ignore + stop, renav never, busy lingers ' .. linger, model = 'ignore', look = 6, nav_last = true,
            renav = 'never', limit = 30, linger = linger})
        eq(r.nav.stops, 1, 'linger ' .. linger .. ': one stop()\n' .. rosie_tail(r.h))
        eq(r.h.logged('[Rosie pickup] Navigator has stayed idle 5s since Rosie stopped its request'), 1,
            'linger ' .. linger .. ': the watchdog line (1.0.28: none, a lingering busy reading disarmed it)\n' .. rosie_tail(r.h))
    end
end)
-- Coordinator review of the first 1.0.29 build (c63b8b3): Worldstone
-- navigating again within the 0.5 s settle was never read idle, so every busy
-- reading counted as lingering and the watchdog switched the stops off while
-- the player travelled (the N6 model, renav at_once). A busy reading with the
-- player walking to a foreign destination disarms it now.
case('N21 guard: Worldstone navigating again after the stop (idle then busy, or at once) disarms the watchdog', function()
    for _, renav in ipairs({'idle', 'at_once'}) do
        for _, fdt in ipairs({0.1, 0.05}) do
            local r = run({label = 'N21 ignore + stop, renav ' .. renav .. ', frame ' .. fdt, model = 'ignore', look = 6, nav_last = true,
                renav = renav, limit = 40, fdt = fdt})
            eq(r.h.logged('[Rosie pickup] Navigator has stayed idle'), 0, 'renav ' .. renav .. ', frame ' .. fdt
                .. ': no watchdog line while Worldstone navigates again (first 1.0.29 build: at_once printed it)\n' .. rosie_tail(r.h))
            ok(r.portal_t ~= nil, 'the portal is reached')
        end
    end
end)

-- QQT_Warpigz_v3 1.0.30 (Auditor review of 1.0.29, LOW): the watchdog read a
-- busy Navigator that another pause condition held (is_paused=true) as idle
-- and switched the stops off.
case('Z2 Worldstone navigates again at once after the stop, but another pause condition holds Navigator 8 s (busy, is_paused=true, player standing): no watchdog off', function()
    for _, fdt in ipairs({0.1, 0.05}) do
        local r = run({label = 'Z2 renav at_once, other pause 8 s, frame ' .. fdt, model = 'ignore', look = 6, nav_last = true,
            renav = 'at_once', limit = 40, fdt = fdt, setup = function(h, nav)
                local base = nav.paused
                nav.paused = function(hh)
                    if nav.stopped_at and hh.now - nav.stopped_at > 0.1 and hh.now - nav.stopped_at < 8.1 then return true end
                    return base(hh)
                end
            end})
        eq(r.h.logged('[Rosie pickup] Navigator has stayed idle'), 0, 'frame ' .. fdt
            .. ': Navigator navigated again (paused by another condition), no watchdog off (1.0.29: switched off)\n' .. rosie_tail(r.h))
    end
end)
-- QQT_Warpigz_v3 1.0.30 (Auditor review, LOW): nav_moving compared
-- remaining_distance with the reading at the stop; a pickup walk toward
-- Navigator's target kept it below that reading for good and disarmed the
-- watchdog. A rolling reference now.
case('N22 after the stop Rosie walks 6 m toward Navigator\'s target for a drop, Navigator stays busy without moving: the watchdog still fires once', function()
    local r = run({label = 'N22 ignore + stop, renav never, busy lingers, drop toward the target', model = 'ignore', look = 6, nav_last = true,
        renav = 'never', limit = 30, linger = 1e9,
        setup = function(h, nav)
            local real = nav.api.stop
            nav.api.stop = function()
                real()
                -- a second drop between the player and Navigator's target
                h.at(0.6, function() h.drop('pit', h.pos:x() + 6, h.pos:y(), {name = 'Item_Gemstone_Royal_Ruby', sno = 265750, bag = 'socketables', rarity = 0}) end)
            end
        end})
    eq(r.nav.stops, 1, 'one stop()\n' .. rosie_tail(r.h))
    eq(r.h.logged('[Rosie pickup] Navigator has stayed idle 5s since Rosie stopped its request'), 1,
        'the watchdog line (1.0.29: the walk toward the target disarmed it)\n' .. rosie_tail(r.h))
end)

print(string.format('rosie nav hold 1.0.25: %d checks, %d failures', checks, #failures))
if #failures > 0 then error(#failures .. ' nav-hold case(s) failed: ' .. table.concat(failures, ' | ')) end
