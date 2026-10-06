-- QQT_Warpigz_v3 (rc.2, Q6): Rosie closes the panels its own service opened.
-- Live (after the Q5 retry): the overlay read "Rosie | menu_open — Waiting for
-- chat or inventory to close." and the user: "it cannot close the window".
-- Root cause: no Rosie task ever closed a panel. sell/salvage/repair/talisman
-- call interact_vendor(npc), stash.lua and stash_pull.lua open the chest, and
-- nothing after that (step end, trip end, failure, stop) pressed Escape. A trip
-- served in town without a return portal (WarPigs' trigger_tasks in Temis, a
-- manual Run town service, Rosie's own automatic trip in town) ends with the
-- player standing at the stash, its panel open: is_inventory_open() stays true,
-- so Rosie's own pickup (pickup/main.lua: is_chat_open() or
-- is_inventory_open() -> menu_open) and every activity waiting on it stay parked.
-- Fix (core/vendor.lua + core/lifecycle.lua + controller.lua): Rosie records
-- the panels it opens (vendor.interact) and closes them with Escape (0x1B) at
-- each step end, at trip end (success, failure, latch, cancel, disable): only
-- while the panel reads open, at most 3 presses 0.5 s apart, re-checked before
-- each press. A panel the player opens by hand is never closed.
-- joint_host.lua: Escape closes h.vendor_screen / h.inventory_open and counts
-- h.game_menu_opens when nothing is open; opts.vendor_inv makes every vendor
-- panel show the inventory; h.escape_ignored models a panel Escape cannot close.
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
    if passed then print('PASS panel-q6: ' .. name)
    else failures[#failures + 1] = name; print('FAIL panel-q6: ' .. name .. ': ' .. tostring(err):sub(1, 2500)) end
end
local CONSUMER = {name = 'Consumer', dir = ROOT .. '/audit/tests/', loaded = {}}
local ESC = 0x1B

local function new(opts)
    opts = opts or {}
    opts.rosie, opts.dirs = true, opts.dirs or {}
    local h = J.new(opts)
    h.assert_clean('load')
    eq(h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end), true, 'RosiePlugin.enable()')
    h.frame()
    return h
end
local function tracker(h) return h.mod('Rosie', 'rosie.private.town.core.tracker') end
local function escapes(h, since)
    local n = 0
    for _, k in ipairs(h.keys) do if k.key == ESC and (not since or k.t >= since) then n = n + 1 end end
    return n
end
local function inv_open(h) return h.as(CONSUMER, function() return h.G.is_inventory_open() end) end
local function pickup_reason(h)
    return h.as(CONSUMER, function() return h.G.LooteerPlugin.status().reason end)
end
local function stash_open(h) return h.vendor_screen == true and h.vendor_actor == h.temis_stash end
local function mythics(h, n)
    h.inventory = {}
    for i = 1, n or 2 do h.inventory[i] = h.gear({rarity = 8, ancestral = true}) end
end
local function trip(h, teleport, limit)
    local done
    eq(h.as(CONSUMER, function()
        local api = h.G.AlfredTheButlerPlugin
        local fn = teleport and api.trigger_tasks_with_teleport or api.trigger_tasks
        return fn('WarPigs', function(r, d) done = {r, d, t = h.now} end)
    end), true, 'trip accepted')
    ok(h.run_until(function() return done ~= nil end, limit or 200), 'the trip finished\n' .. h.tail())
    return done
end
local function reason(done) return tostring(done and done[2] and done[2].reason) end
-- Spacing between consecutive Escape presses.
local function min_gap(h)
    local gap, last = math.huge, nil
    for _, k in ipairs(h.keys) do
        if k.key == ESC then
            if last then gap = math.min(gap, k.t - last) end
            last = k.t
        end
    end
    return gap
end

case('Q6-1 live: a WarPigs trip served in Temis leaves the stash panel open; pickup parks on menu_open', function()
    local h = new({stash_inv = true})
    mythics(h, 2)
    local done = trip(h)
    eq(done[1], nil, 'serviced: ' .. reason(done))
    eq(#h.stashed, 2, 'both mythics stashed')
    h.run(5)
    print('   Q6-1 result: ' .. reason(done) .. ' escapes=' .. escapes(h) .. ' stash_open=' .. tostring(stash_open(h))
        .. ' inventory_open=' .. tostring(inv_open(h)) .. ' pickup=' .. tostring(pickup_reason(h)))
    eq(stash_open(h), false, 'the stash panel Rosie opened is closed\n' .. h.tail(20))
    eq(inv_open(h), false, 'is_inventory_open() reads false again')
    ok(pickup_reason(h) ~= 'menu_open', 'pickup is not parked on menu_open: ' .. tostring(pickup_reason(h)))
    ok(escapes(h) >= 1 and escapes(h) <= 3, 'bounded Escape presses: ' .. escapes(h))
    eq(h.game_menu_opens or 0, 0, 'Escape never pressed with nothing open (game menu)')
    ok(h.run_until(function() return false end, 20) == false and escapes(h) <= 3, 'no further presses while idle')
end)

case('Q6-2 standalone Run town service in Temis: the stash panel is closed before the trip ends', function()
    local h = new({stash_inv = true})
    mythics(h, 2)
    local ok_start = h.as(CONSUMER, function() return h.G.RosiePlugin.service() end)
    eq(ok_start, true, 'manual service accepted')
    ok(h.run_until(function() return tracker(h).outcome == 'completed' or tracker(h).outcome == 'failed' end, 200),
        'the trip finished\n' .. h.tail())
    eq(tracker(h).outcome, 'completed', 'completed: ' .. tostring(tracker(h).failure_reason))
    -- The stash step's own end closes the panel, before the trip completes.
    eq(stash_open(h), false, 'closed at the stash step end\n' .. h.tail(20))
    h.run(5)
    ok(pickup_reason(h) ~= 'menu_open', 'pickup not parked: ' .. tostring(pickup_reason(h)))
    eq(h.game_menu_opens or 0, 0, 'no stray Escape')
    eq(h.logged('Closed the stash panel'), 1, 'one log line per close\n' .. h.tail(20))
end)

case('Q6-3 NPC panel (the vendor panel shows the inventory): the Blacksmith panel closes at the salvage step end', function()
    local h = new({vendor_inv = true})
    h.inventory = {}
    for i = 1, 3 do h.inventory[i] = h.gear() end -- rares: salvaged
    local done = trip(h)
    print('   Q6-3 result: ' .. reason(done) .. ' escapes=' .. escapes(h))
    eq(done[1], nil, 'serviced: ' .. reason(done))
    eq(#h.salvaged, 3, 'salvaged')
    eq(h.vendor_screen, false, 'the Blacksmith panel is closed when the trip ends\n' .. h.tail(20))
    ok(escapes(h) >= 1 and escapes(h) <= 3, 'bounded presses: ' .. escapes(h))
    ok(h.keys[1] and h.keys[1].t <= done.t, 'closed before the trip reported completion')
    h.run(5)
    ok(pickup_reason(h) ~= 'menu_open', 'pickup not parked: ' .. tostring(pickup_reason(h)))
    eq(h.game_menu_opens or 0, 0, 'no stray Escape')
end)

case('Q6-4 a failed stash step closes the panel (retryable failure, nothing parked)', function()
    local h = new({stash_inv = true})
    mythics(h, 6)
    local lm = h.G.loot_manager
    lm.move_item_to_stash = function() h.stash_moves = (h.stash_moves or 0) + 1; return true end -- nothing ever moves
    local done = trip(h)
    print('   Q6-4 result: ' .. reason(done) .. ' escapes=' .. escapes(h))
    ok(done[1] ~= nil, 'the stash step failed')
    h.run(5)
    eq(stash_open(h), false, 'the panel is closed after the failure\n' .. h.tail(20))
    ok(escapes(h) >= 1 and escapes(h) <= 3, 'bounded presses: ' .. escapes(h))
    ok(pickup_reason(h) ~= 'menu_open', 'pickup not parked: ' .. tostring(pickup_reason(h)))
    eq(h.game_menu_opens or 0, 0, 'no stray Escape')
end)

case('Q6-5 Stop / disable while the stash panel is open: Rosie still closes its own panel', function()
    local h = new({stash_inv = true})
    mythics(h, 8)
    local lm = h.G.loot_manager
    local move = lm.move_item_to_stash
    lm.move_item_to_stash = function(item) h.slow = (h.slow or 0) + 1; if h.slow % 2 == 0 then return move(item) end; return true end
    eq(h.as(CONSUMER, function() return h.G.AlfredTheButlerPlugin.trigger_tasks('WarPigs', function() end) end), true)
    ok(h.run_until(function() return stash_open(h) and #h.stashed >= 1 end, 150), 'the stash panel is open\n' .. h.tail())
    eq(h.as(CONSUMER, function() return h.G.RosiePlugin.stop() end), true, 'stop')
    h.run(4)
    eq(stash_open(h), false, 'closed after Stop\n' .. h.tail(20))
    ok(escapes(h) >= 1 and escapes(h) <= 3, 'bounded presses: ' .. escapes(h))
    eq(tracker(h).outcome, 'cancelled', 'a cancel, never a latch')
    eq(h.game_menu_opens or 0, 0, 'no stray Escape')
end)

case('Q6-6 an inventory the player opens by hand is never closed (idle, and after a trip)', function()
    local h = new({stash_inv = true})
    h.inventory = {}
    h.inventory_open = true
    h.run(20)
    eq(escapes(h), 0, 'idle Rosie never presses Escape')
    eq(h.inventory_open, true, 'the player inventory stays open')
    h.inventory_open = false
    mythics(h, 2)
    local done = trip(h)
    eq(done[1], nil, 'serviced: ' .. reason(done))
    h.run(3)
    local after = escapes(h)
    ok(after >= 1, 'Rosie closed its own stash panel')
    h.inventory_open = true -- the player opens the inventory after the trip
    h.run(20)
    eq(escapes(h), after, 'no press on the hand-opened inventory')
    eq(h.inventory_open, true, 'the player inventory stays open')
end)

case('Q6-7 bounded: a panel Escape cannot close gets at most 3 presses, 0.5 s apart, logged once', function()
    local h = new({stash_inv = true})
    mythics(h, 2)
    h.escape_ignored = true
    local done = trip(h)
    eq(done[1], nil, 'serviced: ' .. reason(done))
    h.run(30)
    eq(escapes(h), 3, 'exactly three presses')
    ok(min_gap(h) >= 0.5 - 1e-6, 'presses spaced >= 0.5 s: ' .. tostring(min_gap(h)))
    eq(h.logged('could not close the stash panel'), 1, 'logged once\n' .. h.tail(20))
    eq(tracker(h).outcome, 'completed', 'the trip itself is not failed by a stuck panel')
end)

case('Q6-8 a trip with the return portal: the panel is closed at the step end, before the portal', function()
    local h = new({place = 'pit', stash_inv = true})
    mythics(h, 2)
    local done = trip(h, true, 240)
    print('   Q6-8 result: ' .. reason(done) .. ' escapes=' .. escapes(h))
    eq(done[1], nil, 'serviced: ' .. reason(done))
    ok(escapes(h) >= 1 and escapes(h) <= 3, 'bounded presses: ' .. escapes(h))
    eq(h.game_menu_opens or 0, 0, 'no stray Escape (no press after the loading screen)')
    h.run(10)
    eq(inv_open(h), false, 'nothing reads open')
end)

case('Q6-9 NPC panel without the inventory flag: the identity-checked vendor screen decides', function()
    local h = new({})
    h.inventory = {}
    for i = 1, 3 do h.inventory[i] = h.gear() end -- rares: salvaged at the Blacksmith
    local done = trip(h)
    eq(done[1], nil, 'serviced: ' .. reason(done))
    eq(h.vendor_screen, false, 'the Blacksmith panel is closed\n' .. h.tail(20))
    ok(escapes(h) >= 1 and escapes(h) <= 3, 'bounded presses: ' .. escapes(h))
    eq(h.logged('Closed the blacksmith panel'), 1, 'logged once\n' .. h.tail(20))
    eq(h.game_menu_opens or 0, 0, 'no stray Escape')
end)

case('Q6-10 never on the bare vendor-screen flag: a stash panel that shows no inventory is not pressed', function()
    -- Default joint model: the stash panel raises only the vendor-screen flag
    -- (no inventory flag, no NPC identity). Nothing parks pickup, and Rosie
    -- cannot prove a panel is open: no Escape (it could open the game menu).
    local h = new({})
    mythics(h, 2)
    local done = trip(h)
    eq(done[1], nil, 'serviced: ' .. reason(done))
    h.run(10)
    eq(escapes(h), 0, 'no press without a panel reading open')
    ok(pickup_reason(h) ~= 'menu_open', 'pickup not parked: ' .. tostring(pickup_reason(h)))
end)

case('Q6-11 chat open around the stash step end: no Escape while the chat is open (it would close the chat), closed after', function()
    local h = new({stash_inv = true})
    mythics(h, 2)
    local seen_chat_press = false
    local done
    eq(h.as(CONSUMER, function()
        return h.G.AlfredTheButlerPlugin.trigger_tasks('WarPigs', function(r, d) done = {r, d} end)
    end), true)
    -- Open the chat as soon as the last deposit lands, close it 2 s later.
    ok(h.run_until(function() return #h.stashed >= 2 end, 150), 'deposited\n' .. h.tail())
    h.chat_open = true
    h.at(2, function() h.chat_open = false end)
    ok(h.run_until(function() return done ~= nil end, 60, function()
        if h.chat_open and escapes(h) > 0 then seen_chat_press = true end
    end), 'the trip finished\n' .. h.tail())
    eq(seen_chat_press, false, 'no Escape while the chat is open')
    h.run(3)
    eq(stash_open(h), false, 'closed once the chat closed\n' .. h.tail(20))
    ok(escapes(h) >= 1 and escapes(h) <= 3, 'bounded presses: ' .. escapes(h))
end)

-- QQT_Warpigz_v3 (Q6 review): the closer's guards and every recording site, pinned.
case('Q6-12 Stop with the chat open while Rosie\'s stash panel is open: no Escape until the chat closes, closed after', function()
    local h = new({stash_inv = true})
    mythics(h, 8)
    local lm = h.G.loot_manager
    local move = lm.move_item_to_stash
    lm.move_item_to_stash = function(item) h.slow = (h.slow or 0) + 1; if h.slow % 2 == 0 then return move(item) end; return true end
    eq(h.as(CONSUMER, function() return h.G.AlfredTheButlerPlugin.trigger_tasks('WarPigs', function() end) end), true)
    ok(h.run_until(function() return stash_open(h) and #h.stashed >= 1 end, 150), 'the stash panel is open\n' .. h.tail())
    h.chat_open = true
    local before = escapes(h)
    eq(h.as(CONSUMER, function() return h.G.RosiePlugin.stop() end), true, 'stop')
    h.run(2)
    eq(escapes(h), before, 'no Escape while the chat is open (it would close the chat)')
    eq(stash_open(h), true, 'the panel waits for the chat')
    h.chat_open = false
    h.run(3)
    eq(stash_open(h), false, 'closed once the chat closed\n' .. h.tail(20))
    ok(escapes(h) - before >= 1 and escapes(h) - before <= 3, 'bounded presses: ' .. (escapes(h) - before))
    eq(tracker(h).outcome, 'cancelled', 'a cancel')
end)

-- The closer on its own (Rosie idle in Temis; the controller ticks it every frame).
local function closer(h) return h.mod('Rosie', 'rosie.private.town.core.vendor') end
local function rosie_opens(h, delay)
    closer(h).interact(h.temis_stash, 'STASH') -- recorded as Rosie's panel (out of reach: the host opens nothing)
    local function open() h.vendor_screen, h.vendor_actor = true, h.temis_stash end
    if delay then h.at(delay, open) else open() end
end
case('Q6-13 a Rosie panel that closed by itself is released: a later hand-opened inventory gets no Escape', function()
    local h = new({stash_inv = true})
    h.inventory = {}
    rosie_opens(h)
    h.run(2) -- settled and reading open
    h.vendor_screen = false -- the panel closes by itself (not Rosie)
    h.run(1)
    h.inventory_open = true -- the player opens the inventory by hand
    closer(h).request_close('test step end')
    h.run(4)
    eq(escapes(h), 0, 'no press on the hand-opened inventory')
    eq(h.inventory_open, true, 'the player inventory stays open')
end)

case('Q6-14 a zone change or a death ends Rosie\'s claim on its panel: no Escape afterwards', function()
    for _, event in ipairs({'zone', 'death'}) do
        local h = new({stash_inv = true})
        h.inventory = {}
        rosie_opens(h)
        h.inventory_open = true -- an inventory that reads open across the event
        h.run(2)
        if event == 'zone' then h.place = h.P.kurast else h.dead = true end
        h.run(1)
        if event == 'death' then h.dead = false end
        closer(h).request_close('trip cancelled')
        h.run(4)
        eq(escapes(h), 0, event .. ': no press after the claim ended')
        eq(h.inventory_open, true, event .. ': the inventory is left alone')
    end
end)

case('Q6-15 a panel that opens late after the interaction: the close waits for it (1.5 s settle) and closes it', function()
    local h = new({stash_inv = true})
    h.inventory = {}
    rosie_opens(h, 1.0)
    closer(h).request_close('stash failed')
    h.run(4)
    eq(stash_open(h), false, 'the late panel is closed\n' .. h.tail(10))
    eq(escapes(h), 1, 'one press')
    eq(h.game_menu_opens or 0, 0, 'no stray Escape')
end)

case('Q6-16 every vendor step records its panel: Gambler (sell), Blacksmith (repair), Occultist (talisman), stash pull', function()
    local occultist
    local function closes(label, h, done, line)
        print('   Q6-16 ' .. label .. ': ' .. reason(done) .. ' escapes=' .. escapes(h))
        eq(done[1], nil, label .. ' serviced: ' .. reason(done) .. '\n' .. h.tail(20))
        h.run(3)
        eq(h.vendor_screen, false, label .. ': the panel is closed\n' .. h.tail(20))
        ok(h.logged(line) >= 1, label .. ': "' .. line .. '"\n' .. h.tail(20))
        eq(h.game_menu_opens or 0, 0, label .. ': no stray Escape')
    end
    local h = new({vendor_inv = true, persisted = {alfred_the_butler_item_legendary_or_lower = 2}}) -- Sell
    h.inventory = {h.gear(), h.gear()}
    closes('sell', h, trip(h), 'Closed the gambler panel')
    eq(#h.sold, 2, 'sold')
    h = new({vendor_inv = true})
    h.inventory, h.equipped = {}, {h.gear({durability = 5})}
    closes('repair', h, trip(h), 'Closed the blacksmith panel')
    eq(h.repairs >= 1, true, 'repaired')
    h = new({vendor_inv = true})
    occultist = h.actor('temis', 'TWN_Skov_Temis_Crafter_Occultist', 2583.64, -478.22, {vendor = true})
    h.inventory = {}
    h.talismans = {h.gear({sno = 2418245, name = 'Talisman_Seal_Legendary', rarity = 5, affixes = {}})}
    closes('talisman', h, trip(h), 'Closed the occultist panel')
    eq(#h.talismans, 0, 'the talisman was salvaged at the Occultist ' .. tostring(occultist.skin))
    h = new({vendor_inv = true, stash_inv = true})
    local queued = h.gear({name = 'Queued_Helm', sno = 424242})
    h.stash = {h.gear({rarity = 8, ancestral = true}), queued}
    h.inventory = {h.gear(), h.gear()}
    eq(h.as(CONSUMER, function() return h.G.AlfredTheButlerPlugin.queue_stash_pull(424242, 'salvage') end), true, 'queued')
    closes('stash pull', h, trip(h), 'Closed the blacksmith panel it opened (stash_pull done)') -- the pulled item's vendor
    local salvaged = false
    for _, item in ipairs(h.salvaged) do if item == queued then salvaged = true end end
    ok(salvaged, 'the pulled item was salvaged')
end)

print('Rosie panel Q6: ' .. checks .. ' checks')
if #failures > 0 then error(#failures .. ' failure(s):\n' .. table.concat(failures, '\n')) end
