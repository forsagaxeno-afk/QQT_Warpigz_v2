-- QQT_Warpigz_v3 night audit (area rosie): regressions for the confirmed
-- Rosie defects, each run with the REAL Rosie in the joint host, standalone
-- (no WarPigs: Rosie + the one farming plugin, as a user farms).
--   N1 a named pickup pause (acquire_pause) of another plugin never outlives
--      its owner: TTL, Rosie reload, Rosie/pickup enable edge;
--   N2 a stuck Rosie (stash full) no longer freezes HordeDev's chests;
--      HR's hard need ignores a stuck Rosie;
--   N3 one failed service step no longer ends the trip before repair, stash
--      and the return portal;
--   N4 a request from another town (Caldeum) completes in Temis (no
--      teleport_failed, no fail_streak);
--   N5 untakeable drops: Rosie's per-episode pickup budget, HR's loot hold
--      survives one-frame busy gaps;
--   N6 the Batmobile debug explorer yields to Rosie pickup (bounded);
--   N7 the town settings selection tables are not rebuilt on every pulse.
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
    if passed then print('PASS rosie-night: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL rosie-night: ' .. name .. ': ' .. tostring(err)) end
end
local CONSUMER = {name = 'Consumer', dir = ROOT .. '/audit/tests/', loaded = {}}
local function new(opts)
    opts.rosie = true
    opts.dirs = opts.dirs or {}
    local h = J.new(opts)
    h.assert_clean('load')
    eq(h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end), true, 'RosiePlugin.enable()')
    return h
end
local function looter(h, name, arg)
    return h.as(CONSUMER, function() return h.G.LooteerPlugin[name](arg) end)
end
local function alfred_status(h) return h.as(CONSUMER, function() return h.G.AlfredTheButlerPlugin.get_status() end) end

case('N1 a pause of another plugin expires, and a Rosie reload or enable edge never keeps it', function()
    local h = new({place = 'pit'})
    h.mod('Rosie', 'rosie.private.pickup.gui').elements.general.distance_slider:set(30)
    h.run(1)
    eq(looter(h, 'acquire_pause', 'HordeDev'), true, 'pause taken')
    h.run(2)
    eq(looter(h, 'status').paused, true, 'paused while fresh')
    -- The owner stopped without a release (HordeDev off mid-pylon).
    h.drop('pit', h.pos:x() + 1, h.pos:y(), {rarity = 5, ga = 3, name = 'Helm_Legendary_Generic_001'})
    h.run(70)
    local s = looter(h, 'status')
    eq(s.paused, false, 'stale HordeDev pause expired (' .. tostring(s.detail) .. ')')
    ok(h.logged('pickup pause by HordeDev expired') == 1, 'expiry logged once\n' .. h.tail())
    ok((h.pickups or 0) >= 1, 'pickup resumed and took the drop')
    -- A live owner re-acquiring refreshes its time (not expired meanwhile).
    for _ = 1, 4 do looter(h, 'acquire_pause', 'Owner'); h.run(20) end
    eq(looter(h, 'status').paused, true, 'a refreshed pause stays')
    looter(h, 'release_pause', 'Owner')
    -- The Rosie enable edge clears other plugins' pauses.
    looter(h, 'acquire_pause', 'Other')
    h.as(CONSUMER, function() return h.G.RosiePlugin.disable() end); h.run(1)
    h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end); h.run(1)
    eq(looter(h, 'status').paused, false, 'Rosie off/on clears a foreign pause')
    -- A Rosie reload never restores another plugin's pause.
    looter(h, 'acquire_pause', 'Other')
    eq(looter(h, 'status').paused, true)
    h.reload('Rosie'); h.run(1)
    h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end); h.run(1)
    eq(looter(h, 'status').paused, false, 'reload does not restore it')
    -- Rosie's own town pause is exempt from the TTL (a trip may last 240 s).
    local ps = h.mod('Rosie', 'rosie.private.pickup.src.settings')
    h.as('Rosie', function() ps.acquire_pause('Rosie') end)
    h.run(90)
    eq(h.as('Rosie', function() return ps.is_paused() end), true, "Rosie's own pause is not expired")
    h.as('Rosie', function() ps.release_pause('Rosie') end)
    eq(#h.errors, 0, 'host errors')
end)

case('N1b HordeDev switched off mid-pylon: Rosie pickup resumes', function()
    local h = new({dirs = {'Batmobile', 'HordeDev'}, place = 'bsk'})
    h.mod('Rosie', 'rosie.private.pickup.gui').elements.general.distance_slider:set(30)
    h.setup_horde({waves = 3})
    h.as(CONSUMER, function() return h.G.InfernalHordesPlugin.enable() end)
    ok(h.run_until(function() return looter(h, 'status').paused end, 30), 'HordeDev paused pickup for the pylon')
    h.as(CONSUMER, function() return h.G.InfernalHordesPlugin.disable() end)
    h.run(2)
    h.drop('bsk', h.pos:x() + 1, h.pos:y(), {rarity = 5, ga = 3, name = 'Helm_Legendary_Generic_001'})
    h.run(70)
    eq(looter(h, 'status').paused, false, 'pickup no longer paused')
    ok((h.pickups or 0) >= 1, 'the drop is picked up')
end)

case('N2 standalone HordeDev with a stuck Rosie (stash full) opens the chests instead of asking forever', function()
    local h = new({dirs = {'Batmobile', 'HordeDev'}, place = 'temis'})
    h.instrument_exports()
    h.mod('Rosie', 'rosie.private.town.gui').elements.max_stash_items:set(10)
    h.stash = {}
    for _ = 1, 10 do h.stash[#h.stash + 1] = h.gear({locked = true}) end
    h.inventory = {}
    for _ = 1, 25 do h.inventory[#h.inventory + 1] = h.gear({locked = true}) end
    ok(h.run_until(function() return h.logged('[Rosie] failed') > 0 end, 120), 'the stash-full trip failed\n' .. h.tail())
    local s = alfred_status(h)
    eq(s.stuck, true, 'Rosie latched')
    eq(s.inventory_full, true, 'still publishes inventory_full (WarPug R3)')
    local A = h.setup_horde({resume_at = 'council_dead'})
    h.travel_to('bsk', 0.5, 'test')
    h.run(4)
    h.aether = 100
    h.as(CONSUMER, function() return h.G.InfernalHordesPlugin.enable() end)
    local mark = h.now
    h.run(400)
    local calls = h.count(h.api_calls, function(c) return c.t > mark and c.name == 'trigger_tasks_with_teleport' end)
    ok(#A.opened > 0, 'chests opened: ' .. #A.opened .. '\n' .. h.tail())
    ok(calls <= 1, 'requests to a stuck Rosie: ' .. calls)
    local hd = h.mod('HordeDev', 'core.utils')
    eq(hd.alfred_hard_need({enabled = true, stuck = true, inventory_full = true}), false, 'HordeDev hard need while stuck')
    eq(hd.alfred_trip_wanted({enabled = true, stuck = true, inventory_full = true, need_trigger = true}), false,
        'HordeDev trip wanted while stuck')
    eq(hd.alfred_hard_need({enabled = true, inventory_full = true}), true, 'a real hard need is unchanged')
end)

case('N2b HelltideRevamped: a stuck Rosie is no hard need, and is_inventory_full is false (not the 33-item fallback)', function()
    local h = new({dirs = {'Batmobile', 'HelltideRevamped'}, place = 'helltide'})
    local u = h.mod('HelltideRevamped', 'core.utils')
    eq(u.alfred_hard_need({enabled = true, stuck = true, inventory_full = true}), false, 'stuck')
    eq(u.alfred_hard_need({enabled = true, inventory_full = true}), true, 'not stuck')
    local orig = h.G.AlfredTheButlerPlugin.get_status
    h.G.AlfredTheButlerPlugin.get_status = function()
        local s = orig(); s.enabled, s.stuck, s.inventory_full = true, true, true; return s
    end
    h.inventory = {}
    for _ = 1, 33 do h.inventory[#h.inventory + 1] = h.gear({locked = true}) end
    eq(h.as('HelltideRevamped', function() return u.is_inventory_full() end), false, 'is_inventory_full while stuck')
    h.G.AlfredTheButlerPlugin.get_status = orig
end)

case('N3 one failed vendor step: salvage, repair, stash and the return portal still run', function()
    local h = new({place = 'pit'})
    h.mod('Rosie', 'rosie.private.town.gui').elements.use_keybind:set(true) -- trips only on request
    h.gambler.vendor = false -- the sell step never reads an open vendor
    h.mod('Rosie', 'rosie.private.town.gui').elements.item_legendary_or_lower:set(2)
    h.inventory = {}
    for _ = 1, 5 do h.inventory[#h.inventory + 1] = h.gear({locked = true}) end
    for _ = 1, 20 do h.inventory[#h.inventory + 1] = h.gear() end
    h.equipped = {h.gear({durability = 5})}
    h.run(1)
    local result
    ok(h.as(CONSUMER, function()
        return h.G.AlfredTheButlerPlugin.trigger_tasks_with_teleport('Consumer', function(a, b) result = {a, b} end)
    end) ~= false, 'request accepted')
    ok(h.run_until(function() return result ~= nil end, 300), 'callback\n' .. h.tail())
    local s = alfred_status(h)
    eq(result[1], 'failed', 'the trip still reports its failure')
    eq(s.failure_reason, 'sell_failed', 'first failure named')
    ok(h.repairs >= 1, 'repaired after the failed sell\n' .. h.tail())
    eq(#h.stashed, 5, 'stashed after the failed sell')
    eq(h.place.key, 'pit', 'back in the field through the return portal')
end)

case('N4 a with-teleport request from Caldeum completes in Temis (no teleport_failed, no fail_streak)', function()
    local h = new({place = 'caldeum'})
    h.mod('Rosie', 'rosie.private.town.gui').elements.use_keybind:set(true) -- no automatic service
    h.inventory = {}
    for _ = 1, 25 do h.inventory[#h.inventory + 1] = h.gear() end
    h.run(1)
    local result
    ok(h.as(CONSUMER, function()
        return h.G.AlfredTheButlerPlugin.trigger_tasks_with_teleport('Consumer', function(a, b) result = {a, b} end)
    end) ~= false, 'request accepted')
    ok(h.run_until(function() return result ~= nil end, 300), 'callback\n' .. h.tail())
    local s = alfred_status(h)
    eq(result[1], nil, 'success (' .. tostring(s.failure_reason) .. ')')
    eq(s.outcome, 'completed')
    eq(s.fail_streak, 0)
    eq(h.logged('teleport_failed'), 0, 'no teleport_failed')
    eq(#h.salvaged, 25, 'serviced')
end)

case('N5 untakeable drops: pickup rests them after a 20 s episode budget', function()
    local h = new({place = 'pit'})
    h.mod('Rosie', 'rosie.private.pickup.gui').elements.general.distance_slider:set(15)
    h.run(1)
    for i = 1, 4 do
        local g = h.drop('pit', h.pos:x() + i * 1.5, h.pos:y() + 1, {rarity = 5, ga = 3, name = 'Helm_Legendary_Generic_00' .. i})
        g.on_interact = function() h.ghost_tries = (h.ghost_tries or 0) + 1 end -- nothing is taken
    end
    local since, longest = nil, 0
    h.run(120, function()
        if looter(h, 'is_actively_looting') then
            since = since or h.now
            if h.now - since > longest then longest = h.now - since end
        else since = nil end
    end)
    ok(longest <= 21, string.format('longest continuous busy %.1fs', longest))
    ok(h.logged('busy 20s without picking anything up') >= 1, 'budget logged\n' .. h.tail())
    -- A drop that is picked up restarts the budget: a real one is still taken.
    h.drop('pit', h.pos:x() - 1, h.pos:y(), {rarity = 5, ga = 3, name = 'Helm_Legendary_Generic_009'})
    local before = h.pickups or 0
    ok(h.run_until(function() return (h.pickups or 0) > before end, 60), 'a takeable drop is picked up')
end)

case('N5b HR loot hold is bounded across one-frame busy gaps between drops', function()
    local h = new({dirs = {'Batmobile', 'HelltideRevamped'}, place = 'helltide'})
    local task = h.mod('HelltideRevamped', 'tasks.helltide')
    ok(type(task) == 'table' and type(task.loot_hold) == 'function', 'loot_hold exists')
    local busy = true
    local real = h.G.LooteerPlugin
    h.G.LooteerPlugin = {get_enabled = function() return true end, is_actively_looting = function() return busy end}
    local held, capped_at, released = 0, nil, 0
    local t0 = h.now
    for i = 1, 400 do -- 40 s: busy, with one quiet frame every 5 s (between drops)
        h.now = t0 + i * 0.1
        busy = i % 50 ~= 0
        local hold = h.as('HelltideRevamped', function() return task:loot_hold(nil) end)
        if hold then held = held + 0.1 end
        if busy and not hold then
            capped_at = capped_at or (h.now - t0)
            if h.now - t0 < 30 then released = released + 0.1 end
        end
    end
    h.G.LooteerPlugin = real
    ok(capped_at and capped_at <= 16, 'first cap after ' .. tostring(capped_at) .. 's of busy with one-frame gaps')
    ok(released >= 9, string.format('then the Looter is ignored for about 10 s (%.1fs)', released))
    ok(held >= 14, string.format('still yields to a working Looter (%.1fs)', held))
    ok(h.logged('Looter busy') >= 1, 'the cap is logged')
end)

case('N6 the Batmobile debug explorer yields to Rosie pickup', function()
    local h = new({dirs = {'Batmobile'}, place = 'frac'})
    h.mod('Rosie', 'rosie.private.pickup.gui').elements.general.distance_slider:set(15)
    h.mod('Batmobile', 'gui').elements.freeroam_keybind_toggle.state = 1
    h.run(5)
    h.drop(h.P.frac, h.pos:x() + 4, h.pos:y() + 4, {rarity = 5, ga = 3, name = 'Helm_Legendary_Generic_001'})
    ok(h.run_until(function() return (h.pickups or 0) > 0 end, 20), 'drop next to the route picked up\n' .. h.tail())
end)

case('N7 town settings: selection tables are rebuilt at most once per second, or at once on demand', function()
    local h = new({place = 'pit'})
    h.run(2)
    local tgui = h.mod('Rosie', 'rosie.private.town.gui')
    local n = 0
    for _, w in pairs(tgui.elements) do
        if type(w) == 'table' and type(w.get) == 'function' then
            local g = w.get
            w.get = function(self, ...) n = n + 1; return g(self, ...) end
        end
    end
    h.render = false
    n = 0
    h.run(2)
    ok(n < 8000, 'widget reads in 2 s of updates: ' .. n)
    -- A changed selection is visible at once with force, else within 1 s.
    local settings = h.mod('Rosie', 'rosie.private.town.core.settings')
    local name
    for key in pairs(tgui.elements) do if key:match('^mythic_%d+$') then name = key; break end end
    ok(name, 'a mythic checkbox exists')
    local sno = tonumber(name:match('%d+'))
    local was = tgui.elements[name]:get()
    tgui.elements[name]:set(not was)
    h.as('Rosie', function() settings:update_settings(true) end)
    eq(settings.ancestral_mythic[sno] == true, not was, 'forced rebuild')
    tgui.elements[name]:set(was)
    h.run(1.2)
    eq(settings.ancestral_mythic[sno] == true, was, 'rebuilt within a second')
end)

if #failures > 0 then error(table.concat(failures, '\n')) end
print('Rosie night checks: ' .. checks)
