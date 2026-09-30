-- QQT_Warpigz_v3 1.0.25 (stash passes): pass-based deposit (SteroidAlfred).
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
-- unchanged. On 3.3.6 SP1-SP8, SP10, SP14 and SP15 fail (SP1: both Furnaces
-- stay in the bag, the owner's log lines reproduced); SP9 and SP11-SP13 pass
-- on 3.3.6 too (they guard the port). SP11 (a flapping bag read) and SP12
-- (cached list + inventory panel) pin two rules the port adds to the spec
-- prototype.
-- Review of the port (1.0.25): the first build (9ab6060) latched a permanent
-- "The stash is full" whenever gear stayed in the bag at a stall with a
-- readable count (one refused item, a stale bag entry, a list still loading):
-- Rosie reported stuck and refused the next trips for 600 s. The stash now
-- reads full only at settings.max_stash_items (SteroidAlfred, 3.3.6). SP4-SP6
-- and SP11 were changed to that rule; SP6 (the next bag need starts a trip),
-- SP13 (empty stash + one refused item; a stale bag entry), SP14 (a list that
-- stays partial past the first window; a re-interaction that restarts the
-- load) and SP15 (a panel only a receipt proved open closes) were added.
-- SP4-SP6, SP11 and SP13-SP15 fail on 9ab6060.
-- Review 2 (1.0.25, after 9457f9c): SP16 (a material that lands while the
-- stash list loads no longer starts the short window: the gear waits for the
-- list), SP17 (a last deposit that fills the stash to 350 completes the
-- trip), SP18 (a count-ready panel closed with its list cached reads closed
-- by the inventory panel), SP19 (one refused item that is the only candidate
-- is left for the trip, not a failure every trip), SP20 (the first stall on
-- an inventory-only panel waits as it is) and SP4's thinned passes (at most 2
-- items per pass after 3 quiet passes) fail on 9457f9c. On 3.3.6, SP9, SP11-
-- SP13 and SP17 pass; every other case fails.
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
-- `reload`: an interaction with the open stash restarts its load (untested
-- live). `stale(item)`: that item lands in the stash, the bag list keeps it.
local function live_stash(h, o)
    o = o or {}
    local player, lm = h.G.get_local_player(), h.G.loot_manager
    local orig_move, orig_interact = lm.move_item_to_stash, h.G.interact_vendor
    local opened_at
    h.dropped, h.cmds, h.refused, h.reloads = 0, {}, 0, 0
    local function open() return h.vendor_screen == true and h.vendor_actor == h.temis_stash end
    local function loaded() return opened_at ~= nil and h.now - opened_at >= (o.load or 0) end
    h.G.interact_vendor = function(a)
        if a == h.temis_stash and open() and o.reload then
            opened_at = h.now; h.reloads = h.reloads + 1
            return true
        end
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
        if o.stale and o.stale(item) then
            if not item.gone then item.gone = true; h.stash[#h.stash + 1] = item; h.stashed[#h.stashed + 1] = item end
            return true
        end
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
        eq(h.logged('Deposited 2HMace_Unique_Generic_001 (sno=223465); 2 of 2 unit(s) left the bag (stash list +2); last sent on pass '), 1,
            label .. ': one receipt for both Furnaces\n' .. h.tail(24))
        eq(h.logged('host=true.'), h.logged('Deposited '), label .. ': each receipt names the host value of the move that worked')
        eq(h.logged('Open stash: attempt=2'), 0, label .. ': the open stash is never interacted with again')
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

-- Review (1.0.25): a stash that takes nothing below the game maximum is not
-- latched as full on one trip: each trip fails retryably, naming what is
-- left, and MAX_FAIL_STREAK (3) latches it; then nothing is sent until the
-- latch retry (no loop).
case('SP4 a stash that takes nothing below the maximum: retryable, named, bounded; three trips latch, no loop', function()
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
    ok(reason(done):find('The stash took nothing in', 1, true), reason(done))
    ok(reason(done):find('its list read up to 300 item(s)', 1, true), 'the count read is quoted: ' .. reason(done))
    for i = 1, 10 do ok(reason(done):find(names[i] .. ',', 1, true), 'the reason names ' .. names[i]) end
    ok(reason(done):find('(+15 more)', 1, true), 'the rest is counted: ' .. reason(done))
    eq(tracker(h).stash_full, false, 'not the stash_full latch below the game maximum')
    eq(tracker(h).fail_permanent, false, 'not a permanent latch after one trip')
    local s = st(h)
    eq(s.stuck, true, 'the retry cooldown applies')
    ok(type(s.stuck_retry_in) == 'number', 'a retry is scheduled: ' .. tostring(s.stuck_retry_in))
    eq(h.logged('the stash still reads open (signal=count, stash_n=300)'), 1, 'the loaded stash waits as it is\n' .. h.tail(20))
    eq(h.logged('Open stash: attempt=2'), 0, 'the open stash is not interacted with again')
    -- Review 2: 18 passes (the count changed on pass 2); passes 1-4 send all
    -- 25, then 2 per pass in turn (9457f9c: 450 moves in 24 s).
    ok(#h.cmds <= 25 * 4 + 2 * 14, 'bounded moves: ' .. #h.cmds)
    local per, stamps = {}, {}
    for _, mv in ipairs(h.cmds) do
        if not per[mv.t] then per[mv.t] = 0; stamps[#stamps + 1] = mv.t end
        per[mv.t] = per[mv.t] + 1
    end
    for i = 5, #stamps do ok(per[stamps[i]] <= 2, 'pass ' .. i .. ' sends at most 2 items: ' .. per[stamps[i]]) end
    eq(h.logged('No stash progress'), 0, 'not the 45 s bound')
    eq(h.logged('did not open'), 0, 'not "did not open"')
    h.run(3)
    eq(h.vendor_screen == true and h.vendor_actor == h.temis_stash, false, 'the stash panel is closed')
    -- Two more trips after the cooldown: the fail streak latches (no loop).
    local lc = h.mod('Rosie', 'rosie.private.town.core.lifecycle')
    for n = 2, 3 do
        h.run(lc.RETRY_COOLDOWN + 1)
        local d
        local acc = h.as(CONSUMER, function()
            return h.G.AlfredTheButlerPlugin.trigger_tasks('WarPigs', function(r, x) d = {r, x} end)
        end)
        if acc == true then ok(h.run_until(function() return d ~= nil end, 200), 'trip ' .. n .. ' finished\n' .. h.tail())
        else ok(h.run_until(function() return (tracker(h).fail_streak or 0) >= n end, 200), 'automatic trip ' .. n .. '\n' .. h.tail()) end
    end
    eq(tracker(h).fail_streak, 3, 'three failed trips')
    s = st(h)
    eq(s.stuck, true, 'latched')
    eq(s.stuck_retry_in, nil, 'waits for Run town service or the latch retry')
    local moves = #h.cmds
    ok(moves <= 3 * (25 * 4 + 2 * 14), 'bounded over three trips: ' .. moves)
    h.run(120)
    eq(#h.cmds, moves, 'latched: no more deposits')
end)

case('SP5 three free slots: the Mythics take them first; the rest is left for this trip, named, no latch', function()
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
    eq(done[1], nil, 'two items left are no bag need: the trip completes: ' .. reason(done))
    eq(tracker(h).stash_full, false, 'no stash_full latch below the game maximum')
    eq(tracker(h).stash_done, true, 'the stash step ended')
    eq(h.logged('Skipped Kept_2 (sno='), 1, 'Kept_2 named\n' .. h.tail(12))
    eq(h.logged('Skipped Kept_3 (sno='), 1, 'Kept_3 named')
    eq(h.logged('Skipped Kept_1'), 0, 'only what is left is named')
    eq(h.logged('its list read up to 300 item(s)'), 2, 'the count read is quoted')
    eq(h.logged('Skipped for this trip: Kept_2, Kept_3.'), 1, 'the step end names both')
end)

case('SP6 one item the game refuses never holds up the rest; it is left for this trip and the next bag need starts a trip', function()
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
    eq(done[1], nil, 'the trip completes: ' .. reason(done))
    eq(h.logged('Skipped 2HMace_Unique_Generic_001 (sno=223465) for this trip: the stash did not take it'), 1,
        'the refused item is named\n' .. h.tail(12))
    eq(tracker(h).stash_full, false, 'one refused item is not a full stash')
    eq(tracker(h).fail_permanent, false, 'no latch')
    eq(st(h).stuck, false, 'Rosie is not stuck')
    -- The bag fills again: the next trip is accepted (the first port build
    -- latched "The stash is full" here: stuck, trips refused for 600 s).
    for i = 1, 31 do h.inventory[#h.inventory + 1] = h.gear({name = 'Fill_' .. i, locked = true}) end
    -- Rosie's own automatic service or WarPigs' request: either starts it.
    local started = h.run_until(function() return st(h).running == true end, 5)
    local done2
    if not started then
        eq(h.as(CONSUMER, function()
            return h.G.AlfredTheButlerPlugin.trigger_tasks('WarPigs', function(r, d) done2 = {r, d} end)
        end), true, 'the next trip is accepted (stuck: ' .. tostring(st(h).stuck_reason) .. ')')
    end
    ok(h.run_until(function() return st(h).running ~= true end, 200), 'the next trip ended\n' .. h.tail())
    eq(tracker(h).outcome, 'completed', 'the next trip is serviced: ' .. tostring(tracker(h).failure_reason) .. '\n' .. h.tail(12))
    eq(#h.inventory, 1, 'only the refused Furnace stays')
    eq(tracker(h).stash_full, false, 'still no stash_full')
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
    eq(tracker(h).stash_done, true, 'the step ends (the stash never took the pair)\n' .. h.tail(20))
    ok(h.logged('Deposited Refused_Pair') <= 1, 'at most one false receipt\n' .. h.tail(20))
    eq(h.logged('No stash progress'), 0, 'ended by the stall bound, not by the 45 s guard')
    eq(h.logged('Skipped Refused_Pair (sno=990123) for this trip'), 1, 'the pair is named\n' .. h.tail(12))
    eq(tracker(h).stash_full, false, 'no stash_full latch')
    eq(done[1], nil, 'two items left are no bag need: ' .. reason(done))
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

case('SP13 an empty stash with one refused item, and a stale bag entry: the rest is stashed, the leftover named, no stash_full', function()
    for _, v in ipairs({'refused', 'stale'}) do
        local h = new(LIVE)
        h.stash = {}
        if v == 'stale' then seed_stash(h, 100) end
        local odd = h.gear({name = 'Odd_One', locked = true})
        local k1, k2 = h.gear({name = 'Kept_1', locked = true}), h.gear({name = 'Kept_2', locked = true})
        h.inventory = {odd, k1, k2}
        local o = {load = 0}
        if v == 'refused' then o.refuse = function(item) return item == odd end
        else o.stale = function(item) return item == odd end end
        live_stash(h, o)
        local done = trip(h)
        print('   SP13 ' .. v .. ' result: ' .. reason(done))
        eq(done[1], nil, v .. ': serviced: ' .. reason(done) .. '\n' .. h.tail(16))
        ok(stashed(h, k1) and stashed(h, k2), v .. ': the rest stashed')
        eq(h.logged('Skipped Odd_One'), 1, v .. ': the leftover is named\n' .. h.tail(12))
        eq(tracker(h).stash_full, false, v .. ': no stash_full')
        eq(tracker(h).fail_permanent, false, v .. ': no latch')
        eq(st(h).stuck, false, v .. ': not stuck')
    end
end)

case('SP14 a stash list partial past the first window: the open stash is never interacted with again; a load that never ends is retryable, never "full"', function()
    for _, load in ipairs({14, 30}) do
        local h = new(LIVE)
        seed_stash(h, 292)
        table.insert(h.stash, 200, furnace(h))
        local f1, f2 = furnace(h), furnace(h)
        local k1, k2 = h.gear({name = 'Kept_1', locked = true}), h.gear({name = 'Kept_2', locked = true})
        h.inventory = {f1, f2, k1, k2}
        -- reload: interacting with the open stash restarts its load (not
        -- verified live; the first port build re-interacted at its first stall).
        live_stash(h, {load = load, partial = 16, reload = true})
        local done = trip(h, 250)
        local label = 'load ' .. load .. ' s'
        print(string.format('   SP14 %s result: %s moves=%d reloads=%d', label, reason(done), #h.cmds, h.reloads))
        eq(h.reloads, 0, label .. ': no interaction with the open stash\n' .. h.tail(16))
        eq(h.logged('the stash still reads open (signal=count, stash_n=16)'), 1, label .. ': the first stall waits\n' .. h.tail(16))
        eq(tracker(h).stash_full, false, label .. ': never stash_full')
        eq(tracker(h).fail_permanent, false, label .. ': never a permanent latch')
        ok(h.logged('nothing has left the bag in') >= 3, label .. ': the waiting passes are logged')
        if load == 14 then
            eq(done[1], nil, label .. ': serviced: ' .. reason(done) .. '\n' .. h.tail(16))
            for _, it in ipairs({f1, f2, k1, k2}) do ok(stashed(h, it), label .. ': ' .. it.name .. ' stashed') end
        else
            ok(done[1] ~= nil, label .. ': the trip failed')
            ok(reason(done):find('The stash took nothing in 17 passes', 1, true), label .. ': ' .. reason(done))
            ok(reason(done):find('its list read up to 16 item(s)', 1, true), label .. ': the count as read: ' .. reason(done))
            ok(reason(done):find('2HMace_Unique_Generic_001 x2', 1, true), label .. ': the Furnaces are named')
            eq(tracker(h).fail_streak, 1, label .. ': one retryable failure')
            ok(#h.cmds <= 4 * 17, label .. ': bounded moves ' .. #h.cmds)
        end
    end
end)

case('SP15 a panel only a receipt proved open (no signal at all) closes mid-way: Rosie opens it again, nothing is left behind', function()
    local h = new({stash_screen_flag = false})
    h.stash = {}
    local items = {}
    for i = 1, 4 do items[i] = h.gear({name = 'Kept_' .. i, locked = true}) end
    h.inventory = {items[1], items[2], items[3], items[4]}
    local lm = h.G.loot_manager
    local move = lm.move_item_to_stash
    local closed = false
    lm.move_item_to_stash = function(item)
        local r = move(item)
        if not closed and #h.stashed >= 2 then closed = true; h.vendor_screen, h.vendor_actor = false, nil end -- another addon's Escape
        return r
    end
    local done = trip(h)
    eq(done[1], nil, 'serviced: ' .. reason(done) .. '\n' .. h.tail(16))
    for _, it in ipairs(items) do ok(stashed(h, it), it.name .. ' stashed\n' .. h.tail(16)) end
    eq(h.logged('Stash reads open: signal=receipt'), 1, 'the probe receipt opened it\n' .. h.tail(16))
    eq(h.logged('on a panel only a receipt proved open'), 1, 'the idle panel reads closed\n' .. h.tail(16))
    eq(h.logged('Skipped'), 0, 'nothing left behind')
end)

-- QQT_Warpigz_v3 1.0.25 (review 2): SP16-SP20 fail on 9457f9c.
-- SP16 (major): a gem goes to the materials storage at once while the stash
-- list still loads; the short after-deposit window then skipped every gear
-- item for the trip (the owner's bug again).
case('SP16 a material lands while the stash list loads: the gear waits for the list and nothing is left behind', function()
    for _, load in ipairs({8, 14}) do
        local h = new(LIVE)
        h.mod('Rosie', 'rosie.private.town.gui').elements.stash_socketables:set(2) -- ALWAYS
        seed_stash(h, 292)
        table.insert(h.stash, 200, furnace(h))
        local gem = h.gear({name = 'Gem_Ruby_04', sno = 2700004, rarity = 0, socket = true, stack = 3})
        function gem:get_stack_count() return self.stack end
        h.socketables = {gem}
        local f1, f2, k1 = furnace(h), furnace(h), h.gear({name = 'Kept_1', locked = true})
        h.inventory = {f1, f2, k1}
        live_stash(h, {load = load, partial = 16})
        local lm = h.G.loot_manager
        local live_move = lm.move_item_to_stash
        lm.move_item_to_stash = function(item)
            -- The materials storage is not the stash list: the gem lands at once.
            if item == gem and h.vendor_screen and h.vendor_actor == h.temis_stash and #h.socketables > 0 then
                h.cmds[#h.cmds + 1] = {t = h.now, item = item}
                h.socketables = {}; h.stashed[#h.stashed + 1] = gem
                return true
            end
            return live_move(item)
        end
        local done = trip(h, 250)
        local label = 'load ' .. load .. ' s'
        print(string.format('   SP16 %s result: %s moves=%d', label, reason(done), #h.cmds))
        eq(done[1], nil, label .. ': serviced: ' .. reason(done) .. '\n' .. h.tail(16))
        for _, it in ipairs({f1, f2, k1, gem}) do ok(stashed(h, it), label .. ': ' .. it.name .. ' stashed\n' .. h.tail(16)) end
        eq(h.logged('Skipped'), 0, label .. ': nothing skipped\n' .. h.tail(16))
        eq(h.logged('Deposited Gem_Ruby_04 (sno=2700004); 3 of 3 unit(s)'), 1, label .. ': the gem went on pass 1')
        eq(h.logged('Open stash: attempt=2'), 0, label .. ': the loading stash is never interacted with again')
    end
end)

-- SP17: the last deposit brings the stash to exactly the game maximum; the
-- bag is empty, so the trip completes (9457f9c: "The stash is full (350/350
-- items)" on the tick after the receipt, stash_full and a permanent latch).
case('SP17 the last deposit fills the stash to the maximum: the trip completes, no stash_full', function()
    for _, n in ipairs({349, 348}) do
        local h = new(LIVE)
        seed_stash(h, n)
        h.inventory = {}
        for i = 1, 350 - n do h.inventory[i] = h.gear({name = 'Last_' .. i, locked = true}) end
        live_stash(h, {load = 0})
        local done = trip(h)
        local label = n .. ' + ' .. (350 - n)
        eq(done[1], nil, label .. ': serviced: ' .. reason(done) .. '\n' .. h.tail(12))
        eq(#h.inventory, 0, label .. ': the bag is empty')
        eq(#h.stash, 350, label .. ': the stash is at the maximum')
        eq(tracker(h).stash_done, true, label .. ': the stash step completed')
        eq(tracker(h).stash_full, false, label .. ': no stash_full latch for a finished step')
        eq(tracker(h).fail_permanent, false, label .. ': no latch')
        eq(h.logged('The stash is full'), 0, label .. ': not reported full')
    end
end)

-- SP18: the stash read open by its count while the inventory panel was up;
-- another addon closes the panel after 2 items, the list stays readable
-- (cached). 9457f9c kept passing into the closed panel and skipped the rest.
case('SP18 the panel closes mid-step while its list stays readable: it reads closed by the inventory panel and is opened again', function()
    local h = new(LIVE)
    seed_stash(h, 200)
    local items = {}
    for i = 1, 5 do items[i] = h.gear({name = 'Kept_' .. i, locked = true}) end
    h.inventory = {items[1], items[2], items[3], items[4], items[5]}
    live_stash(h, {load = 0})
    local player, lm = h.G.get_local_player(), h.G.loot_manager
    local get = player.get_stash_items
    local ever = false
    player.get_stash_items = function(self)
        local l = get(self)
        if #l > 0 then ever = true end
        if ever and not (h.vendor_screen and h.vendor_actor == h.temis_stash) then return h.stash end -- cached after the close
        return l
    end
    local move = lm.move_item_to_stash
    local closed = false
    lm.move_item_to_stash = function(item)
        if not closed and #h.stashed >= 2 then closed = true; h.vendor_screen, h.vendor_actor = false, nil end -- another addon's Escape
        return move(item)
    end
    local done = trip(h)
    eq(done[1], nil, 'serviced: ' .. reason(done) .. '\n' .. h.tail(16))
    for _, it in ipairs(items) do ok(stashed(h, it), it.name .. ' stashed\n' .. h.tail(16)) end
    eq(h.logged('Stash reads open: signal=count'), 2, 'the count opened it both times\n' .. h.tail(16))
    eq(h.logged('Stash panel reads closed'), 1, 'the closed panel is seen\n' .. h.tail(16))
    eq(h.logged('Skipped'), 0, 'nothing left behind')
end)

-- SP19: the only stash candidate of every trip is one item the game refuses
-- (the rest of the bag is sold). 3.3.6 skipped it for the trip; 9457f9c
-- failed every trip ("took nothing"): the fail streak grew and latched.
case('SP19 the only candidate is one refused item: every trip completes, no fail streak, not stuck', function()
    local h = new(LIVE)
    seed_stash(h, 100)
    local bad = furnace(h)
    live_stash(h, {load = 0, refuse = function(item) return item == bad end})
    h.inventory = {bad}
    for cycle = 1, 3 do
        for _ = 1, 26 do h.inventory[#h.inventory + 1] = h.gear({rarity = 1, junk = true}) end
        local done = trip(h)
        local label = 'trip ' .. cycle
        eq(done[1], nil, label .. ': serviced: ' .. reason(done) .. '\n' .. h.tail(12))
        eq(#h.inventory, 1, label .. ': only the refused Furnace stays')
        eq(tracker(h).fail_streak or 0, 0, label .. ': no fail streak')
        eq(tracker(h).stash_full, false, label .. ': no stash_full')
        eq(st(h).stuck, false, label .. ': not stuck')
        h.run(2)
    end
    eq(h.logged('Skipped 2HMace_Unique_Generic_001 (sno=223465) for this trip: the stash did not take it in 17 passes'), 3,
        'named once per trip\n' .. h.tail(12))
    eq(h.logged('The stash took nothing'), 0, 'never the "took nothing" failure')
end)

-- SP20: the stash list reads 0 while it loads (the inventory panel decides);
-- if interacting with the open stash restarted the load (not verified live),
-- 9457f9c's re-interaction at the first stall made a 15 s load fail.
case('SP20 a list that reads 0 while it loads: the first stall waits as it is, no second interaction', function()
    local h = new(LIVE)
    seed_stash(h, 301)
    local f1, f2, k1 = furnace(h), furnace(h), h.gear({name = 'Kept_1', locked = true})
    h.inventory = {f1, f2, k1}
    live_stash(h, {load = 15, partial = 0, reload = true})
    local done = trip(h, 250)
    print(string.format('   SP20 result: %s moves=%d reloads=%d', reason(done), #h.cmds, h.reloads))
    eq(done[1], nil, 'serviced: ' .. reason(done) .. '\n' .. h.tail(16))
    for _, it in ipairs({f1, f2, k1}) do ok(stashed(h, it), it.name .. ' stashed\n' .. h.tail(16)) end
    eq(h.reloads, 0, 'no interaction with the open stash')
    eq(h.logged('Open stash: attempt=2'), 0, 'one interaction')
    eq(h.logged('the stash still reads open (signal=inv, stash_n=0)'), 1, 'the first stall waits\n' .. h.tail(16))
    eq(h.logged('Skipped'), 0, 'nothing skipped')
end)

print('Rosie stash passes: ' .. checks .. ' checks')
if #failures > 0 then error(#failures .. ' failure(s):\n' .. table.concat(failures, '\n')) end
