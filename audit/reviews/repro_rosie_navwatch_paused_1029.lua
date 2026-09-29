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
        print(rosie_tail(r.h, 8))
        eq(r.h.logged('[Rosie pickup] Navigator has stayed idle'), 0, 'frame ' .. fdt .. ': Navigator navigated again (paused by another condition), the watchdog must not switch the stops off\n')
    end
end)
print(string.format('zz: %d checks, %d failures', checks, #failures))
if #failures > 0 then error(#failures .. ' case(s) failed: ' .. table.concat(failures, ' | ')) end
