-- Scratch repro (Auditor, not shipped): Worldstone drives Navigator, NO Scavenger.
-- Rosie's pickup is the only looter. A fake Navigator walks the player along a
-- route with pathfinder.request_move every pulse; a wanted drop lies off the
-- route. Measures: drop picked? Rosie yields? reversals? Navigator delay.
local ROOT = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local J = dofile(ROOT .. '/audit/tests/joint_host.lua')
local CONSUMER = {name = 'Consumer', dir = ROOT .. '/audit/tests/', loaded = {}}
local NAVCTX = {name = 'Navigator', dir = ROOT .. '/audit/tests/', loaded = {}}

local function new(slider)
    local h = J.new({rosie = true, dirs = {}, place = 'pit'})
    h.assert_clean('load')
    h.pos = h.v(0, 0)
    assert(h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end) == true)
    h.frame()
    if slider then h.mod('Rosie', 'rosie.private.pickup.gui').elements.general.distance_slider:set(slider) end
    return h
end

-- Fake Navigator: route along +x from x0 to goal_x (y=0). mode:
--   'far'  : request_move(final goal) every `every` s (dest far away)
--   'look' : request_move(point `look` m ahead on the route line) every `every` s
-- Honors pause conditions keyed by name (as the seen API suggests).
local function navigator(h, o)
    local nav = {conditions = {}, moves = 0, paused_time = 0, max_pause_run = 0, run = 0, last = -math.huge,
        goal_x = o.goal_x or 120, mode = o.mode or 'far', every = o.every or 0.1, look = o.look or 2, arrived_at = nil}
    local function paused()
        for _, fn in pairs(nav.conditions) do
            local ok, on = pcall(fn)
            if ok and on then return true end
        end
        return false
    end
    nav.paused = paused
    h.G.Navigator = {
        set_pause_condition = function(name, fn) nav.conditions[name] = fn end,
        get_status = function() return {is_busy = nav.arrived_at == nil, is_paused = paused(), owner = 'Worldstone'} end,
        stop = function() end, navigate = function() return 1 end,
    }
    function nav.step(hh)
        if nav.arrived_at then return end
        if hh.pos:x() >= nav.goal_x - 1 then nav.arrived_at = hh.now; return end
        if paused() then
            nav.paused_time = nav.paused_time + 0.1; nav.run = nav.run + 0.1
            if nav.run > nav.max_pause_run then nav.max_pause_run = nav.run end
            return
        end
        nav.run = 0
        if hh.now - nav.last < nav.every - 1e-9 then return end
        nav.last = hh.now
        local tx
        if nav.mode == 'far' then tx = nav.goal_x else tx = math.min(nav.goal_x, hh.pos:x() + nav.look) end
        nav.moves = nav.moves + 1
        hh.as(NAVCTX, function() return hh.G.pathfinder.request_move(hh.v(tx, 0)) end)
    end
    return nav
end

local function watcher(h, item)
    local w = {rev_x = 0, rev_y = 0, lx = h.pos:x(), ly = h.pos:y(), dx = 0, dy = 0, closest = math.huge,
        moves = #h.moves, who = nil, alt = 0, rosie_moves = 0, first_rosie = nil}
    function w.each(hh)
        local x, y = hh.pos:x(), hh.pos:y()
        local ddx, ddy = x - w.lx, y - w.ly
        if math.abs(ddx) > 0.05 then local d = ddx > 0 and 1 or -1; if w.dx ~= 0 and d ~= w.dx then w.rev_x = w.rev_x + 1 end; w.dx = d end
        if math.abs(ddy) > 0.05 then local d = ddy > 0 and 1 or -1; if w.dy ~= 0 and d ~= w.dy then w.rev_y = w.rev_y + 1 end; w.dy = d end
        w.lx, w.ly = x, y
        if item and not item.picked then w.closest = math.min(w.closest, hh.pos:dist_to_ignore_z(item.pos)) end
        for i = w.moves + 1, #hh.moves do
            local who = hh.moves[i].context == 'Navigator' and 'nav' or 'rosie'
            if who == 'rosie' then w.rosie_moves = w.rosie_moves + 1; w.first_rosie = w.first_rosie or hh.now end
            if w.who and who ~= w.who then w.alt = w.alt + 1 end
            w.who = who
        end
        w.moves = #hh.moves
    end
    return w
end

local function scenario(label, o)
    local h = new(o.slider or 30)
    local item = o.drop ~= false and h.drop('pit', o.dx or 20, o.dy or 6, {rarity = 5, ga = 3, name = 'Helm_Legendary_Generic_031',
        refuse = o.refuse and function() return true end or nil}) or nil
    if o.enemy then h.actor('pit', 'Joint_Monster', o.enemy[1], o.enemy[2], {enemy = true, health = 1e9, reach = 0}) end
    local nav = navigator(h, o)
    if o.condition then nav.conditions['Rosie Looting'] = o.condition(h) end
    local w = watcher(h, item)
    local t0 = h.now
    local picked_at
    local busy_frames = 0
    h.run(o.secs or 60, function(hh)
        nav.step(hh); w.each(hh)
        if item and item.picked and not picked_at then picked_at = hh.now - t0 end
        if hh.as(CONSUMER, function() return hh.G.LooteerPlugin.is_actively_looting() end) then busy_frames = busy_frames + 1 end
    end)
    local yields = h.logged('Another move took the player off')
    local rounds = h.logged('round ')
    local gave = h.logged('Gave up on')
    print(string.format('%-58s picked=%-5s at=%-6s yields=%d rounds_failed=%d gaveup=%d rev_x=%d rev_y=%d alt=%d rosie_moves=%d nav_moves=%d closest=%.1f arrived=%s nav_paused=%.1fs max_pause=%.1fs busy=%.1fs',
        label, tostring(item and item.picked == true), picked_at and string.format('%.1f', picked_at) or '-', yields, rounds, gave,
        w.rev_x, w.rev_y, w.alt, w.rosie_moves, nav.moves, w.closest,
        nav.arrived_at and string.format('%.1f', nav.arrived_at - t0) or 'no', nav.paused_time, nav.max_pause_run, busy_frames * 0.1))
    if os.getenv('SCAV_TAIL') == label then print(h.tail(40)) end
    h.assert_clean(label)
    return h, item, nav, w
end

print('ROSIE VERSION: ' .. tostring((function()
    local h = new(); return h.as(CONSUMER, function() return h.G.AlfredTheButlerPlugin.get_status().version end)
end)()))
-- Baselines
scenario('S0 no drop, far-goal Navigator (route time baseline)', {drop = false, secs = 30})
scenario('S1 far goal every 0.1s, drop 6m off route ahead', {secs = 40})
scenario('S1b far goal every 0.5s, drop 6m off route ahead', {every = 0.5, secs = 40})
scenario('S1c far goal every 1.0s, drop 6m off route ahead', {every = 1.0, secs = 40})
scenario('S2 lookahead 2m every 0.1s, drop 6m off route ahead', {mode = 'look', look = 2, secs = 60})
scenario('S2b lookahead 2m every 0.3s, drop 6m off', {mode = 'look', look = 2, every = 0.3, secs = 60})
scenario('S3 lookahead 5m every 0.1s, drop 6m off route ahead', {mode = 'look', look = 5, secs = 40})
scenario('S4 far goal, drop 6m off BEHIND start (-4,6)', {dx = -4, dy = 6, secs = 40})
scenario('S5 far goal, drop ON route (20,1)', {dx = 20, dy = 1, secs = 30})
scenario('S5b far goal, drop 2.5m off route (20,2.5)', {dx = 20, dy = 2.5, secs = 30})
scenario('S6 far goal, default slider 2, drop 6m off', {slider = 2, secs = 30})
scenario('S6b far goal, default slider 2, drop ON route (20,1)', {slider = 2, dx = 20, dy = 1, secs = 30})
-- Fix prototypes: a Navigator pause condition registered as if by Rosie.
local function cond_looting(h)
    return function() return h.as(CONSUMER, function() return h.G.LooteerPlugin.is_actively_looting() end) == true end
end
local function cond_moving(h)
    -- true only while Rosie's pickup owns the shared route or interacted within 0.5 s
    local mv = h.mod('Rosie', 'rosie.movement')
    return function()
        if mv.status().owner == 'pickup' then return true end
        local last = h.interactions[#h.interactions]
        return last ~= nil and last.context == 'Rosie' and h.now - last.t < 0.5
    end
end
scenario('P1 cond=is_actively_looting, far goal, drop 6m off', {condition = cond_looting, secs = 40})
scenario('P1 cond=is_actively_looting, lookahead 2m, drop 6m off', {condition = cond_looting, mode = 'look', secs = 40})
scenario('P1 cond=is_actively_looting, refused drop (ghost)', {condition = cond_looting, refuse = true, secs = 90})
scenario('P1 cond=is_actively_looting, enemy 8m off route never dies', {condition = cond_looting, enemy = {22, -7}, secs = 90})
scenario('P2 cond=pickup-moving/interacting, far goal, drop 6m off', {condition = cond_moving, secs = 40})
scenario('P2 cond=pickup-moving, refused drop (ghost)', {condition = cond_moving, refuse = true, secs = 90})
scenario('P2 cond=pickup-moving, enemy 8m off route never dies', {condition = cond_moving, enemy = {22, -7}, secs = 90})

-- ── part 2 ──────────────────────────────────────────────────────────────
scenario('S7 far goal, drop next to player (2,5) (loot of a kill)', {dx = 2, dy = 5, secs = 30})
scenario('S7b lookahead 2m, drop next to player (2,5)', {mode = 'look', dx = 2, dy = 5, secs = 30})
-- fight: an enemy that never dies 6.4 m from the start, drop 8.5 m off
scenario('F0 no fix, enemy (5,-4) never dies, drop (6,6)', {dx = 6, dy = 6, enemy = {5, -4}, secs = 70})
scenario('F1 P1 looting-cond, enemy (5,-4) never dies, drop (6,6)', {condition = cond_looting, dx = 6, dy = 6, enemy = {5, -4}, secs = 70})
scenario('F2 P2 moving-cond, enemy (5,-4) never dies, drop (6,6)', {condition = cond_moving, dx = 6, dy = 6, enemy = {5, -4}, secs = 70})
-- fix C prototype: a yielded drop is still interacted with when the other
-- mover brings the player within REACH (no movement request, no tug of war)
local function patch_c(h)
    local P = h.mod('Rosie', 'rosie.private.pickup.src.pickup')
    local U = h.mod('Rosie', 'rosie.private.pickup.utils.utils')
    local blocked = P.blocked
    P.blocked = function(item)
        local b, why = blocked(item)
        if b and why == 'pickup yielded to another move' and U.distance_to(item) <= 2 then return false end
        return b, why
    end
end
local function scenario_c(label, o)
    local orig = new
    new = function(slider) local h = orig(slider); patch_c(h); return h end
    local ok, err = pcall(scenario, label, o)
    new = orig
    if not ok then print('ERR ' .. tostring(err)) end
end
scenario_c('C1 fixC, far goal, drop ON route (20,1)', {dx = 20, dy = 1, secs = 30})
scenario_c('C2 fixC, far goal, drop 2.5m off (20,2.5)', {dx = 20, dy = 2.5, secs = 30})
scenario_c('C3 fixC, far goal, drop 6m off (20,6)', {secs = 30})
-- many drops along the route (alternating 5 m left / right)
local function multi(label, o)
    local h = new(30)
    local items = {}
    for i = 1, 8 do items[i] = h.drop('pit', 10 * i, (i % 2 == 0) and 5 or -5, {rarity = 5, ga = 3, name = 'Helm_Legendary_Generic_0' .. (40 + i)}) end
    local nav = navigator(h, o)
    if o.condition then nav.conditions['Rosie Looting'] = o.condition(h) end
    local t0 = h.now
    h.run(o.secs or 120, function(hh) nav.step(hh) end)
    local n = 0
    for _, it in ipairs(items) do if it.picked then n = n + 1 end end
    print(string.format('%-58s picked=%d/8 yields=%d arrived=%s nav_paused=%.1fs max_pause=%.1fs', label, n,
        h.logged('Another move took the player off'), nav.arrived_at and string.format('%.1f', nav.arrived_at - t0) or 'no',
        nav.paused_time, nav.max_pause_run))
    h.assert_clean(label)
end
multi('M0 no fix, 8 drops 5 m off, far goal', {})
multi('M0b no fix, 8 drops 5 m off, lookahead 2m', {mode = 'look'})
multi('M1 P2 moving-cond, 8 drops 5 m off, far goal', {condition = cond_moving})
-- a Rosie whose on_update stops (unload / dead callback) while walking to a drop:
-- a pause condition over frozen state freezes Navigator for good.
local function frozen(label, make)
    local h = new(30)
    local item = h.drop('pit', 20, 6, {rarity = 5, ga = 3, name = 'Helm_Legendary_Generic_031'})
    local nav = navigator(h, {})
    nav.conditions['Rosie Looting'] = make(h)
    h.run(1.0, function(hh) nav.step(hh) end)
    h.by_dir['Rosie'].update = {} -- Rosie's pulse no longer runs
    local t0 = h.now
    h.run(60, function(hh) nav.step(hh) end)
    print(string.format('%-58s arrived=%s nav_paused=%.1fs max_pause=%.1fs', label,
        nav.arrived_at and string.format('%.1f', nav.arrived_at - t0) or 'no', nav.paused_time, nav.max_pause_run))
end
frozen('R1 P1 looting-cond, Rosie pulse stops mid-walk', cond_looting)
frozen('R2 P2 moving-cond, Rosie pulse stops mid-walk', cond_moving)
frozen('R3 P2 + heartbeat (pulse within 0.5 s), pulse stops', function(h)
    local inner = cond_moving(h)
    local P = h.mod('Rosie', 'rosie.private.pickup.src.pickup')
    local last = h.now
    local step = P.step
    P.step = function(...) last = h.now; return step(...) end
    return function() return h.now - last < 0.5 and inner() end
end)
-- Navigator that clears the stored path every frame while paused
local base_navigator = navigator
local function navigator_clearing(h, o)
    local nav = base_navigator(h, o)
    local step = nav.step
    nav.step = function(hh)
        if nav.paused() then hh.as(NAVCTX, function() return hh.G.pathfinder.clear_stored_path() end) end
        step(hh)
    end
    return nav
end
do
    local orig = navigator
    navigator = navigator_clearing
    scenario('N1 P2 moving-cond, Navigator clears path while paused', {condition = cond_moving, secs = 40})
    navigator = orig
end
print('done')
