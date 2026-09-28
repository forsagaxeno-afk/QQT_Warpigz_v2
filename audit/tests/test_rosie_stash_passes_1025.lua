-- QQT_Warpigz_v3 1.0.24 (stash port from SteroidAlfred): pass-based deposit.
-- Live 3.3.6 (owner, the same every trip):
--   Open stash: attempt=1 distance=1.6 host=true ... sdk=false inv=false vendor=nil stash_n=0
--   Stash reads open: signal=inv attempt=1 sdk=false inv=true vendor=nil stash_n=16
--   Deposit requested: 2HMace_Unique_Generic_001 (sno=223465, attempt=1, host=false)
--   Skipped 2HMace_Unique_Generic_001 (sno=223465) for this trip: transfer not
--     confirmed after 8s (bag 3 -> 3, stash 0 -> 1)
--   Stash reads open: ... stash_n=293
-- Root cause (3.3.6 tasks/stash.lua): the inventory flag alone read the stash
-- open while its list was still loading; the one move sent then was dropped
-- by the game; the stash list finished loading (0 -> 1 Furnace already in the
-- stash), the receipt read ambiguous, Rosie waited ITEM_WAIT 8 s and skipped
-- the bag:SNO key for the whole trip: both Mythic Furnaces stayed in the bag.
-- The port (SteroidAlfred): the stash reads open on the vendor-screen flag, a
-- stash count > 0 stable 0.5 s, or the inventory panel held 1.5 s with no
-- usable count; then one pass per second sends EVERY stashable item; the bag
-- decides what moved; the rest is simply sent again.
-- The live stash is modelled here only (live_stash below); joint_host.lua is
-- unchanged. On 3.3.6 SP1-SP8, SP10 and SP11 fail (SP1: both Furnaces stay
-- in the bag, the owner's log lines reproduced); SP9 and SP12 pass on both
-- (they guard the port). SP11 (a flapping bag read) and SP12 (cached list +
-- inventory panel) pin two rules the port adds to the spec prototype.
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
    if passed then print('PASS stash-passes: ' .. name)
    else failures[#failures + 1] = name; print('FAIL stash-passes: ' .. name .. ': ' .. tostring(err):sub(1, 2500)) end
end
local CONSUMER = {name = 'Consumer', dir = ROOT .. '/audit/tests/', loaded = {}}
local FURNACE, ANNIHILUS = 223465, 2684354
local function affix(hash, name) return {affix_name_hash = hash, get_name = function() return name end} end
local function new(opts)
    opts = opts or {}
    opts.rosie, opts.dirs = true, {}
    local h = J.new(opts)
    h.assert_clean('load')
    eq(h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end), true, 'RosiePlugin.enable()')
    h.frame()
    return h
end
local function tracker(h) return h.mod('Rosie', 'rosie.private.town.core.tracker') end
local function st(h) return h.as(CONSUMER, function() return h.G.AlfredTheButlerPlugin.get_status() end) end
local function reason(done) return tostring(done and done[2] and done[2].reason) end
local function trip(h, limit)
    local done
    eq(h.as(CONSUMER, function()
        return h.G.AlfredTheButlerPlugin.trigger_tasks('WarPigs', function(r, d) done = {r, d} end)
    end), true, 'trip accepted')
    ok(h.run_until(function() return done ~= nil end, limit or 200), 'the trip finished\n' .. h.tail())
    return done
end
local function stashed(h, item) for _, x in ipairs(h.stashed) do if x == item then return true end end return false end
local function furnace(h)
    return h.gear({name = '2HMace_Unique_Generic_001', sno = FURNACE, rarity = 6, ancestral = true, ga = 1,
        affixes = {affix(1111111, '2HMace_Unique_Generic_001'), affix(2628989, 'S14_Mythic_UniquePotency')}})
end
-- The owner's live stash (3.3.6 log): the panel opens a moment after the
-- interaction, shows the inventory (is_inventory_open) and never raises the
-- vendor-screen flag; its item list reads `partial` items for `load` s, then
-- the whole stash. The game ignores a move sent before the stash loaded (the
-- host returns true, nothing moves). `cap`: the game refuses every move once
-- the stash holds `cap` items. `refuse(item)`: the game never takes that item.
local function live_stash(h, o)
    o = o or {}
    local player, lm = h.G.get_local_player(), h.G.loot_manager
    local orig_move, orig_interact = lm.move_item_to_stash, h.G.interact_vendor
    local opened_at
    h.dropped, h.cmds, h.refused = 0, {}, 0
    local function open() return h.vendor_screen == true and h.vendor_actor == h.temis_stash end
    local function loaded() return opened_at ~= nil and h.now - opened_at >= (o.load or 0) end
    h.G.interact_vendor = function(a)
        if a == h.temis_stash and not open() then
            h.at(0.2, function()
                local was = open(); orig_interact(a)
                if open() and not was then opened_at = h.now; h.opened_at = h.opened_at or h.now end
            end)
            return true
        end
        return orig_interact(a)
    end
    player.get_stash_items = function(self)
        if not open() then opened_at = nil; return {} end
        if loaded() then return h.stash end
        local out = {}
        for i = 1, math.min(o.partial or 0, #h.stash) do out[i] = h.stash[i] end
        return out
    end
    lm.move_item_to_stash = function(item)
        h.cmds[#h.cmds + 1] = {t = h.now, item = item}
        h.stash_moves = (h.stash_moves or 0) + 1
        if not open() then return false end
        if not loaded() then h.dropped = h.dropped + 1; return true end
        if (o.cap and #h.stash >= o.cap) or (o.refuse and o.refuse(item)) then h.refused = h.refused + 1; return true end
        for i = #(h.talismans or {}), 1, -1 do
            if h.talismans[i] == item then
                table.remove(h.talismans, i)
                h.stash[#h.stash + 1] = item; h.stashed[#h.stashed + 1] = item
                return true
            end
        end
        h.stash_moves = h.stash_moves - 1 -- counted again by the joint host
        return orig_move(item)
    end
end
local LIVE = {stash_screen_flag = false, stash_inv = true}
local function seed_stash(h, n, extra)
    h.stash = {}
    for i = 1, n do h.stash[i] = h.gear({rarity = 3, locked = true}) end
    if extra then h.stash[#h.stash + 1] = extra end
end

case('SP1 live: the stash list loads for a while and the game ignores early moves; every item, the Mythics first, is stashed in the same visit', function()
    for _, load in ipairs({2.5, 8}) do
        local h = new(LIVE)
        seed_stash(h, 292)
        table.insert(h.stash, 200, furnace(h)) -- the owner's stash already holds a Furnace (live: "stash 0 -> 1")
        local f1, f2, m = furnace(h), furnace(h), h.gear({name = 'Mythic_Joint', rarity = 8, ancestral = true})
        local l1, l2 = h.gear({name = 'Kept_1', locked = true}), h.gear({name = 'Kept_2', locked = true})
        local seal = h.gear({name = 'Talisman_Seal_Unique_Annihilus', sno = ANNIHILUS, rarity = 6})
        h.inventory, h.talismans = {f1, f2, m, l1, l2}, {seal}
        live_stash(h, {load = load, partial = 16})
        local done = trip(h)
        local label = 'load ' .. load .. ' s'
        eq(done[1], nil, label .. ' serviced: ' .. reason(done) .. '\n' .. h.tail(20))
        for _, it in ipairs({f1, f2, m, l1, l2, seal}) do ok(stashed(h, it), label .. ': ' .. it.name .. ' stashed\n' .. h.tail(24)) end
        eq(h.logged('Skipped'), 0, label .. ': nothing skipped (3.3.6: Skipped 2HMace_Unique_Generic_001)')
        eq(tracker(h).stash_done, true, label .. ': the stash step completed')
        eq(h.logged('Deposited 2HMace_Unique_Generic_001 (sno=223465); 2 of 2 unit(s) left the bag (stash list +2).'), 1,
            label .. ': one receipt for both Furnaces\n' .. h.tail(24))
        ok(h.dropped > 0, label .. ': the early passes were ignored by the game (model check)')
        ok(h.cmds[1].t >= h.opened_at + 0.5 - 1e-6, string.format('%s: first move %.2fs after the panel opened',
            label, h.cmds[1].t - h.opened_at))
        eq(h.cmds[1].item, f1, label .. ': the pass starts with a Mythic')
        ok(#h.cmds <= 6 * (load + 3), label .. ': bounded moves ' .. #h.cmds)
        eq(h.logged('The stash took the first item on pass'), 1, label .. ': the load delay is logged once')
    end
end)

case('SP2 no deposit while the stash list still grows (inventory panel up, count changing every tick)', function()
    local h = new(LIVE)
    seed_stash(h, 200)
    h.inventory = {h.gear({rarity = 8, ancestral = true}), h.gear({rarity = 8, ancestral = true})}
    live_stash(h, {load = 0})
    local player = h.G.get_local_player()
    local full = player.get_stash_items
    local grow_until
    player.get_stash_items = function(self)
        local list = full(self)
        if #list == 0 or not h.opened_at then return list end
        grow_until = grow_until or h.opened_at + 3
        if h.now >= grow_until then return list end
        local n = math.floor((h.now - h.opened_at) * 60) + 1
        local out = {}
        for i = 1, math.min(n, #list) do out[i] = list[i] end
        return out
    end
    local done = trip(h)
    eq(done[1], nil, 'serviced: ' .. reason(done))
    ok(h.cmds[1].t >= grow_until + 0.5 - 1e-6, string.format('first move %.2fs after the list stopped growing', h.cmds[1].t - grow_until))
    eq(#h.stashed, 2, 'both stashed')
end)

case('SP3 empty stash: the inventory panel held 1.5 s opens it; a late-loading empty list still gets every item', function()
    for _, load in ipairs({0, 4}) do
        local h = new(LIVE)
        h.stash = {}
        local items = {h.gear({rarity = 8, ancestral = true}), h.gear({rarity = 8, ancestral = true}), h.gear({locked = true})}
        h.inventory = {items[1], items[2], items[3]}
        live_stash(h, {load = load})
        local done = trip(h)
        eq(done[1], nil, 'load ' .. load .. ' serviced: ' .. reason(done) .. '\n' .. h.tail(16))
        for _, it in ipairs(items) do ok(stashed(h, it), 'load ' .. load .. ' stashed') end
        eq(h.logged('Stash reads open: signal=inv attempt=1'), 1, 'the inventory signal decided\n' .. h.tail(16))
        ok(h.cmds[1].t >= h.opened_at + 1.5 - 1e-6, string.format('first move %.2fs after the panel opened', h.cmds[1].t - h.opened_at))
    end
end)

case('SP4 a really full stash: nothing moves; stash_full latch naming every item left, bounded, panel closed', function()
    local h = new(LIVE)
    seed_stash(h, 300)
    local names = {}
    h.inventory = {}
    for i = 1, 25 do h.inventory[i] = h.gear({name = 'Kept_' .. i, locked = true}); names[i] = 'Kept_' .. i end
    live_stash(h, {load = 1, partial = 16, cap = 300})
    local t0 = h.now
    local done = trip(h)
    print(string.format('   SP4 result: %s moves=%d seconds=%.0f', reason(done), #h.cmds, h.now - t0))
    ok(done[1] ~= nil, 'the trip failed')
    eq(tracker(h).stash_full, true, 'stash_full')
    eq(st(h).stuck, true, 'Rosie reports stuck (latched)')
    ok(reason(done):find('The stash is full', 1, true), reason(done))
    for i = 1, 10 do ok(reason(done):find(names[i] .. ',', 1, true), 'the reason names ' .. names[i]) end
    ok(reason(done):find('(+15 more)', 1, true), 'the rest is counted: ' .. reason(done))
    eq(tracker(h).fail_permanent, true, 'a permanent latch')
    ok(#h.cmds <= 25 * 17, 'bounded moves: ' .. #h.cmds)
    eq(h.logged('No stash progress'), 0, 'not the 45 s bound')
    eq(h.logged('did not open'), 0, 'not "did not open"')
    h.run(3)
    eq(h.vendor_screen == true and h.vendor_actor == h.temis_stash, false, 'the stash panel is closed')
end)

case('SP5 three free slots: the Mythics take them first; the rest is named in the stash-full latch', function()
    local h = new(LIVE)
    seed_stash(h, 297)
    local l1, l2, l3 = h.gear({name = 'Kept_1', locked = true}), h.gear({name = 'Kept_2', locked = true}), h.gear({name = 'Kept_3', locked = true})
    local f, m = furnace(h), h.gear({name = 'Mythic_Joint', rarity = 8, ancestral = true})
    h.inventory = {l1, l2, l3, f, m}
    live_stash(h, {load = 1, partial = 16, cap = 300})
    local done = trip(h)
    print('   SP5 result: ' .. reason(done))
    ok(stashed(h, f) and stashed(h, m), 'both Mythics stashed')
    ok(stashed(h, l1), 'the first kept item in bag order took the last slot')
    ok(not stashed(h, l2) and not stashed(h, l3), 'no room for the rest')
    eq(tracker(h).stash_full, true, 'stash_full')
    ok(reason(done):find('Kept_2', 1, true) and reason(done):find('Kept_3', 1, true), reason(done))
    ok(not reason(done):find('Kept_1', 1, true), 'only what is left is named')
end)

case('SP6 one item the game refuses never holds up the rest: every other item goes in on the first pass after the load', function()
    local h = new(LIVE)
    seed_stash(h, 100)
    local bad = furnace(h)
    local rest = {h.gear({rarity = 8, ancestral = true}), h.gear({locked = true}), h.gear({locked = true})}
    h.inventory = {bad, rest[1], rest[2], rest[3]}
    live_stash(h, {load = 0, refuse = function(item) return item == bad end})
    local done = trip(h)
    print('   SP6 result: ' .. reason(done))
    local first_pass_t = h.cmds[1].t
    for _, it in ipairs(rest) do ok(stashed(h, it), 'stashed') end
    local ok_first = true
    for _, it in ipairs(rest) do
        local sent = false
        for _, mv in ipairs(h.cmds) do if mv.item == it and mv.t == first_pass_t then sent = true end end
        ok_first = ok_first and sent
    end
    ok(ok_first, 'every other item was sent in the same pass as the refused one')
    eq(h.logged('transfer not confirmed'), 0, 'no per-item wait')
    ok(reason(done):find('2HMace_Unique_Generic_001', 1, true), 'the refused item is named: ' .. reason(done))
    eq(tracker(h).stash_full, true, 'gear the stash stops taking reads as a full stash')
    eq(st(h).stuck, false, 'one leftover item is no bag need: Rosie is not stuck')
end)

case('SP7 socketable and material stacks (loading stash): each stack stashed once it loads, one request line per stack', function()
    local h = new(LIVE)
    h.mod('Rosie', 'rosie.private.town.gui').elements.stash_socketables:set(2) -- ALWAYS
    h.mod('Rosie', 'rosie.private.town.gui').elements.stash_consumables:set(2) -- ALWAYS
    seed_stash(h, 50)
    local rune = h.gear({name = 'Rune_Condition_Summons', sno = 2045533, rarity = 0, socket = true, stack = 5})
    function rune:get_stack_count() return self.stack end
    local gem = h.gear({name = 'Gem_Ruby_04', sno = 2700004, rarity = 0, socket = true, stack = 3})
    function gem:get_stack_count() return self.stack end
    local mat = h.gear({name = 'Item_BossMaterial_Joint', sno = 1502569, rarity = 1, stack = 7})
    function mat:get_stack_count() return self.stack end
    h.socketables, h.consumables = {rune, gem}, {mat}
    h.inventory = {h.gear({rarity = 8, ancestral = true})}
    live_stash(h, {load = 3, partial = 10})
    local done = trip(h)
    eq(done[1], nil, 'serviced: ' .. reason(done) .. '\n' .. h.tail(16))
    ok(stashed(h, rune) and stashed(h, gem) and stashed(h, mat), 'every stack stashed')
    eq(h.logged('Deposited Rune_Condition_Summons (sno=2045533); 5 of 5 unit(s) left the bag'), 1, 'rune receipt\n' .. h.tail(16))
    eq(h.logged('Deposit requested: Rune_Condition_Summons'), 1, 'one request line per stack')
end)

case('SP8 a partial stack merge: 2 of 5 fill the stash stack, the 3 left go on the next pass', function()
    local h = new(LIVE)
    h.mod('Rosie', 'rosie.private.town.gui').elements.stash_socketables:set(2) -- ALWAYS
    seed_stash(h, 20)
    local srune = h.gear({name = 'Rune_Condition_Summons', sno = 2045533, rarity = 0, socket = true, stack = 48})
    function srune:get_stack_count() return self.stack end
    table.insert(h.stash, 1, srune)
    local rune = h.gear({name = 'Rune_Condition_Summons', sno = 2045533, rarity = 0, socket = true, stack = 5})
    function rune:get_stack_count() return self.stack end
    h.socketables = {rune}
    h.inventory = {}
    live_stash(h, {load = 1, partial = 5})
    local lm = h.G.loot_manager
    local move = lm.move_item_to_stash
    h.rune_cmds = 0
    lm.move_item_to_stash = function(item)
        if item ~= rune then return move(item) end
        h.rune_cmds = h.rune_cmds + 1
        local before = h.dropped
        local r = move({get_sno_id = function() return -1 end}) -- run the model's open/loaded gates only
        if h.dropped > before or not (h.vendor_screen and h.vendor_actor == h.temis_stash) then return r end
        if srune.stack < 50 then
            local moved = math.min(rune.stack, 50 - srune.stack)
            srune.stack = srune.stack + moved; rune.stack = rune.stack - moved
        else
            local copy = h.gear({name = rune.name, sno = rune.sno, rarity = 0, socket = true, stack = rune.stack})
            function copy:get_stack_count() return self.stack end
            h.stash[#h.stash + 1] = copy; rune.stack = 0
        end
        if rune.stack <= 0 then h.socketables = {}; h.stashed[#h.stashed + 1] = rune end
        return true
    end
    local done = trip(h)
    eq(done[1], nil, 'serviced: ' .. reason(done) .. '\n' .. h.tail(16))
    eq(#h.socketables, 0, 'the whole rune stack is stashed')
    eq(h.logged('Deposited Rune_Condition_Summons (sno=2045533); 2 of 5 unit(s)'), 1, 'first receipt\n' .. h.tail(16))
    eq(h.logged('Deposited Rune_Condition_Summons (sno=2045533); 3 of 3 unit(s)'), 1, 'second receipt\n' .. h.tail(16))
    eq(h.logged('Skipped'), 0, 'nothing skipped')
end)

case('SP9 guards: no deposit command while the player is dead or the trip caller pauses', function()
    local h = new(LIVE)
    seed_stash(h, 100)
    h.inventory = {}
    for i = 1, 6 do h.inventory[i] = h.gear({locked = true}) end
    live_stash(h, {load = 6, partial = 16})
    local done
    eq(h.as(CONSUMER, function() return h.G.AlfredTheButlerPlugin.trigger_tasks('WarPigs', function(r, d) done = {r, d} end) end), true)
    ok(h.run_until(function() return #h.cmds > 0 end, 100), 'passes started\n' .. h.tail())
    h.dead = true
    local n = #h.cmds
    h.run(3)
    eq(#h.cmds, n, 'no command while dead')
    h.dead = false
    eq(h.as(CONSUMER, function() return h.G.AlfredTheButlerPlugin.pause('WarPigs') end) ~= false, true, 'paused')
    n = #h.cmds
    h.run(3)
    eq(#h.cmds, n, 'no command while paused')
    h.as(CONSUMER, function() return h.G.AlfredTheButlerPlugin.resume('WarPigs') end)
    ok(h.run_until(function() return done ~= nil end, 120), 'finished\n' .. h.tail())
    eq(done[1], nil, 'serviced: ' .. reason(done))
    eq(#h.inventory, 0, 'everything stashed')
end)

case('SP10 the game maximum: a stash of 350 latches stash_full before any deposit', function()
    local h = new(LIVE)
    seed_stash(h, 350)
    h.inventory = {h.gear({locked = true})}
    live_stash(h, {load = 0})
    local done = trip(h)
    ok(done[1] ~= nil, 'failed')
    eq(tracker(h).stash_full, true, 'stash_full')
    ok(reason(done):find('The stash is full (350/350 items)', 1, true), reason(done))
    eq(#h.cmds, 0, 'no deposit sent')
end)

case('SP11 a bag read that flaps never keeps the step alive: one false receipt at most, then the stall bound ends it', function()
    -- Two copies of one SNO the game refuses; one copy's stack count reads
    -- nil every other 0.6 s, so the bag quantity of that SNO reads 2, 1, 2,
    -- 1 ... A receipt that adopted the higher reading again would reset the
    -- idle passes and the 45 s bound on every flap (a trip stuck in town).
    local h = new(LIVE)
    seed_stash(h, 100)
    local SNO = 990123
    local a = h.gear({name = 'Refused_Pair', sno = SNO, locked = true})
    local b = h.gear({name = 'Refused_Pair', sno = SNO, locked = true})
    function b:get_stack_count()
        if math.floor(h.now / 0.6) % 2 == 1 then return nil end
        return 1
    end
    h.inventory = {a, b}
    live_stash(h, {load = 0, refuse = function(item) return item == a or item == b end})
    local t0 = h.now
    local done = trip(h, 150)
    print(string.format('   SP11 result: %s seconds=%.0f', reason(done), h.now - t0))
    ok(done[1] ~= nil, 'the step ends (the stash never took the pair)')
    ok(h.logged('Deposited Refused_Pair') <= 1, 'at most one false receipt\n' .. h.tail(20))
    eq(h.logged('No stash progress'), 0, 'ended by the stall bound, not by the 45 s guard')
    ok(reason(done):find('Refused_Pair', 1, true), 'the pair is named: ' .. reason(done))
end)

case('SP12 cached stash list + inventory panel, flag silent: the inventory held 1.5 s opens it (no deadlock while "opening")', function()
    local h = new({stash_screen_flag = false, stash_inv = true, stash_stale = true})
    h.stash = {h.gear({rarity = 8, ancestral = true})}
    local items = {h.gear({rarity = 8, ancestral = true}), h.gear({locked = true})}
    h.inventory = {items[1], items[2]}
    local done = trip(h)
    eq(done[1], nil, 'serviced: ' .. reason(done) .. '\n' .. h.tail(16))
    for _, it in ipairs(items) do ok(stashed(h, it), 'stashed\n' .. h.tail(16)) end
    eq(h.logged('No stash progress'), 0, 'no 45 s wait on a panel that reads "opening"')
end)

print('Rosie stash passes: ' .. checks .. ' checks')
if #failures > 0 then error(#failures .. ' failure(s):\n' .. table.concat(failures, '\n')) end
