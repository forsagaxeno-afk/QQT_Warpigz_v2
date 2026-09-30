-- QQT_Warpigz_v3 (rc.2, Q5): one unconfirmed socketable no longer stops the
-- stash, the trip or Rosie.
-- Live (v3.0.0): "[WarPigs] Alfred is stuck (Stash: Transfer confirmation
-- timed out for Rune_Condition_Summons; item kept unresolved.) and waits for
-- an explicit Run town service"; the user: bags full of gems and talismans,
-- plenty of room in the stash, nothing moved.
-- Root cause (stash.lua pending_receipt): a deposit counted only when BOTH
-- the bag lost `amount` units AND the stash list gained `amount` units of the
-- SNO. Any other change ("source~=p.source or destination~=p.destination")
-- waited without a bound of its own until the 45 s no-progress guard failed
-- the whole stash (and three such trips latched Rosie). A rune stack that
-- merges into a stash stack the host lists with a zero/one stack count, a
-- stash list that does not show socketables, or a partial merge into a
-- nearly full stash stack all leave the bag and never pass that receipt.
-- The joint host models those host variants here (only in this file):
--   merge0  the stash merges the stack; stash entries report stack count 0;
--   hidden  get_stash_items() does not list socketables;
--   partial the stash stack holds 50; a 5-stack merges 2 into a 48-stack,
--           3 stay in the bag until the next command opens a new stash stack;
--   refuse  one SNO never moves (host returns true);
--   stale   one SNO lands in the stash but the bag list keeps it (a later
--           move of that stack does nothing: the game already took it).
-- QQT_Warpigz_v3 1.0.25 (stash passes): the stash now works in passes
-- (tasks/stash.lua). Every second one pass sends every stashable item; the
-- bag decides what moved and the rest is sent again. There is no per-item
-- wait (the 3.x ITEM_WAIT 8 s, 3 attempts per item and MAX_SKIPS 3 items in a
-- row are gone): the step ends when nothing is left, or after AFTER_DEPOSIT
-- (3) idle passes once anything moved (the rest is skipped for the trip), or
-- after FIRST_WAIT + SECOND_WAIT (12 + 5) idle passes with nothing moved
-- ("The stash took nothing in 17 passes", retryable). Q5-4, Q5-5, Q5-9,
-- Q5-14 and Q5-16 were adjusted to those bounds.
-- QQT_Warpigz_v3 1.0.25 (review 2): once anything moved, the AFTER_DEPOSIT
-- window starts only from pass FIRST_WAIT (12): a receipt early in a long
-- stash load no longer ends the step while the list still loads. After 3
-- quiet passes a pass sends only THIN (2) items in turn. Q5-4, Q5-5 (12
-- commands for the one leftover rune) and Q5-14 (2 + 23 x 4 + 2 x 8) were
-- adjusted to those bounds.
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
    if passed then print('PASS stash-q5: ' .. name)
    else failures[#failures + 1] = name; print('FAIL stash-q5: ' .. name .. ': ' .. tostring(err):sub(1, 2500)) end
end
local CONSUMER = {name = 'Consumer', dir = ROOT .. '/audit/tests/', loaded = {}}
local RUNE = 2045533 -- a stand-in SNO for Rune_Condition_Summons
local FULL, ALWAYS = 1, 2

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
local function lifecycle(h) return h.mod('Rosie', 'rosie.private.town.core.lifecycle') end

-- A socketable stack (gem, rune) in the socketables bag or the stash.
local function socketable(h, name, sno, stack)
    local item = h.gear({name = name, sno = sno, stack = stack, socket = true, rarity = 0})
    function item:get_stack_count() return self.zero and 0 or self.stack end
    return item
end
-- Socketables bag + a stash that stacks socketables (see the header).
local function socket_host(h, mode)
    mode = mode or {}
    h.socketables = h.socketables or {}
    local player = h.G.get_local_player()
    player.get_socketable_items = function() return h.socketables end
    local stash_items = player.get_stash_items
    player.get_stash_items = function(self)
        local list = stash_items(self)
        if not mode.hidden then return list end
        local out = {}
        for _, item in ipairs(list) do if not item.socket then out[#out + 1] = item end end
        return out
    end
    local lm = h.G.loot_manager
    local move = lm.move_item_to_stash
    h.socket_moves = {}
    lm.move_item_to_stash = function(item)
        if not (item and item.socket) then return move(item) end
        h.stash_moves = (h.stash_moves or 0) + 1
        h.socket_moves[item.sno] = (h.socket_moves[item.sno] or 0) + 1
        if not (h.vendor_screen and h.vendor_actor == h.temis_stash) then return false end
        local at
        for i, x in ipairs(h.socketables) do if x == item then at = i end end
        if not at then return false end
        if h.stale_done and h.stale_done[item] then return true end -- the game: that stack already left the bag
        if mode.refuse == item.sno then return true end
        local into
        for _, s in ipairs(h.stash) do
            if s.socket and s.sno == item.sno and s.stack < (mode.cap or 1000) then into = s end
        end
        local moved = item.stack
        if into then
            moved = math.min(moved, (mode.cap or 1000) - into.stack)
            into.stack = into.stack + moved
        else
            local copy = socketable(h, item.name, item.sno, moved)
            copy.zero = mode.merge0
            h.stash[#h.stash + 1] = copy
        end
        h.stashed[#h.stashed + 1] = item
        if mode.stale == item.sno then h.stale_done = h.stale_done or {}; h.stale_done[item] = true; return true end -- the bag list keeps the moved stack
        item.stack = item.stack - moved
        if item.stack <= 0 then table.remove(h.socketables, at) end
        return true
    end
end
-- A full socketables bag: the rune first, then `gems` gem stacks. The stash
-- already holds a stack of each (the stack the host merges into).
local function fill(h, gems, rune_stack, stash_rune)
    h.socketables, h.stash = {}, {}
    h.socketables[1] = socketable(h, 'Rune_Condition_Summons', RUNE, rune_stack or 3)
    for i = 1, gems do
        h.socketables[#h.socketables + 1] = socketable(h, 'Gem_Ruby_0' .. (i % 5), 2700000 + i, 2)
    end
    local rune = socketable(h, 'Rune_Condition_Summons', RUNE, stash_rune or 10)
    rune.zero = h.merge0
    h.stash[1] = rune
    for i = 1, gems do
        local gem = socketable(h, 'Gem_Ruby_0' .. (i % 5), 2700000 + i, 7)
        gem.zero = h.merge0
        h.stash[#h.stash + 1] = gem
    end
end
local function left(h, sno)
    local n = 0
    for _, item in ipairs(h.socketables) do if not sno or item.sno == sno then n = n + item.stack end end
    return n
end
local function trip(h, limit)
    local done
    eq(h.as(CONSUMER, function()
        return h.G.AlfredTheButlerPlugin.trigger_tasks('WarPigs', function(r, d) done = {r, d} end)
    end), true, 'trip accepted')
    ok(h.run_until(function() return done ~= nil end, limit or 200), 'the trip finished\n' .. h.tail())
    return done
end
local function reason(done) return tostring(done and done[2] and done[2].reason) end
local function live_host(mode, opts)
    opts = opts or {}
    opts.persisted = opts.persisted or {alfred_the_butler_stash_socketables = FULL}
    local h = new(opts)
    h.merge0 = mode.merge0
    socket_host(h, mode)
    fill(h, mode.gems or 24, mode.rune_stack, mode.stash_rune)
    h.inventory = {}
    return h
end
local function expect_serviced(h, done, label)
    eq(done[1], nil, label .. ' serviced: ' .. reason(done) .. '\n' .. h.tail(20))
    eq(h.logged('Transfer confirmation timed out'), 0, label .. ' no confirmation timeout')
    eq(tracker(h).stash_failed, false, label .. ' stash step not failed')
    eq((lifecycle(h).stuck()), false, label .. ' Rosie not stuck')
end

case('Q5-1 live: the rune merges into a stash stack the host lists with stack count 0', function()
    local h = live_host({merge0 = true})
    local done = trip(h)
    print('   Q5-1 result: ' .. reason(done))
    expect_serviced(h, done, 'Q5-1')
    eq(left(h), 0, 'the whole socketables bag is stashed')
    eq(h.socket_moves[RUNE], 1, 'one command for the rune')
end)

case('Q5-2 the stash list does not show socketables at all', function()
    local h = live_host({hidden = true})
    local done = trip(h)
    print('   Q5-2 result: ' .. reason(done))
    expect_serviced(h, done, 'Q5-2')
    eq(left(h), 0, 'the whole socketables bag is stashed')
end)

case('Q5-3 partial merge into a nearly full stash stack (48/50): the rest goes on the next command', function()
    local h = live_host({cap = 50, rune_stack = 5, stash_rune = 48})
    local done = trip(h)
    print('   Q5-3 result: ' .. reason(done))
    expect_serviced(h, done, 'Q5-3')
    eq(left(h, RUNE), 0, 'the rune remainder is stashed too')
    eq(h.socket_moves[RUNE], 2, 'two commands: 2 merged, 3 into a new stash stack')
end)

case('Q5-4 one rune the stash never takes: skipped once for this trip, every other stack stashed', function()
    local h = live_host({refuse = RUNE})
    local done = trip(h)
    print('   Q5-4 result: ' .. reason(done))
    expect_serviced(h, done, 'Q5-4')
    eq(left(h), 3, 'only the refused rune stays in the bag')
    eq(h.logged('Skipped Rune_Condition_Summons'), 1, 'the skip is logged once\n' .. h.tail(30))
    ok(h.socket_moves[RUNE] <= 12, 'bounded commands for the refused rune (one per pass up to pass FIRST_WAIT): ' .. tostring(h.socket_moves[RUNE]))
    eq(h.logged('did not open'), 0, 'no stash-window failure')
end)

case('Q5-5 the stash receives the rune but the bag list keeps it: re-sent only until the stall, skipped once', function()
    local h = live_host({stale = RUNE})
    local done = trip(h)
    print('   Q5-5 result: ' .. reason(done))
    expect_serviced(h, done, 'Q5-5')
    eq(left(h) - left(h, RUNE), 0, 'every gem stashed')
    ok(h.socket_moves[RUNE] <= 12, 'the stale stack is re-sent at most until the stall (pass FIRST_WAIT): ' .. tostring(h.socket_moves[RUNE]))
    eq(h.logged('Skipped Rune_Condition_Summons'), 1, 'the skip is logged once\n' .. h.tail(30))
end)

case('Q5-6 refused items never latch Rosie: a remaining need after skips is a retryable failure', function()
    -- Every socketable is refused: the bag stays full. The stash step is not
    -- a failure per item; the trip ends failed but not permanently latched.
    local h = live_host({refuse = RUNE, gems = 0})
    for i = 1, 24 do h.socketables[#h.socketables + 1] = socketable(h, 'Rune_Condition_Summons', RUNE, 1) end
    local done = trip(h)
    print('   Q5-6 result: ' .. reason(done))
    ok(done[1] ~= nil, 'the need is unresolved')
    eq(h.logged('Transfer confirmation timed out'), 0, 'no confirmation timeout')
    eq(tracker(h).fail_permanent, false, 'not a permanent latch after one trip')
    local stuck, wait = lifecycle(h).stuck()
    eq(stuck, true, 'the normal retry cooldown applies')
    ok(type(wait) == 'number', 'a retry is scheduled (not "waits for Run town service")')
    ok(reason(done):find('Rune_Condition_Summons', 1, true) ~= nil, 'the reason names the skipped item: ' .. reason(done))
end)

case('Q5-7 an item whose checks raise is skipped; the stash goes on with the rest', function()
    -- "Skip favorited items" reads is_locked(); one item raises there.
    local h = live_host({}, {persisted = {alfred_the_butler_stash_socketables = FULL,
        alfred_the_butler_skip_favorite = true}})
    local bad = h.socketables[2]
    function bad:is_locked() error('unreadable item') end
    local done = trip(h)
    print('   Q5-7 result: ' .. reason(done))
    expect_serviced(h, done, 'Q5-7')
    eq(left(h), bad.stack, 'only the unreadable stack stays')
    eq(h.logged('Rosie] Host error'), 0, 'no host error')
    eq(h.logged('its checks raised'), 1, 'the unreadable item is logged once (no per-tick spam)')
end)

case('Q5-9 bounded: every item refused fails the step after 12 + 5 idle passes (full or closed stash), not a latch', function()
    local h = live_host({gems = 0})
    local lm, refused = h.G.loot_manager, 0
    local move = lm.move_item_to_stash
    lm.move_item_to_stash = function(item)
        if item and item.socket then refused = refused + 1; return true end -- nothing ever moves
        return move(item)
    end
    for i = 1, 24 do h.socketables[#h.socketables + 1] = socketable(h, 'Gem_Topaz_0' .. i, 2800000 + i, 1) end
    local done = trip(h)
    print('   Q5-9 result: ' .. reason(done) .. ' commands=' .. refused)
    ok(done[1] ~= nil, 'the step fails')
    -- QQT_Warpigz_v3 1.0.25 (stash passes): the idle-pass bound ends the
    -- step (the vendor screen still reads open after 12 passes: 5 more, no
    -- re-interaction), not the 4-interaction cap; never stash_full.
    ok(reason(done):find('The stash took nothing in 17 passes', 1, true) ~= nil, 'the stall reason: ' .. reason(done))
    eq(h.logged('did not open'), 0, 'not the 4-interaction cap')
    ok(refused <= 25 * 17, 'bounded deposit commands (FIRST_WAIT + SECOND_WAIT passes): ' .. refused)
    eq(tracker(h).stash_full, false, 'not the stash_full latch')
    eq(tracker(h).fail_permanent, false, 'retryable, not latched after one trip')
    eq(h.logged('Transfer confirmation timed out'), 0, 'no confirmation timeout')
end)

case('Q5-10 receipts are logged once per deposit (no per-tick spam)', function()
    local h = live_host({merge0 = true})
    local done = trip(h)
    expect_serviced(h, done, 'Q5-10')
    eq(h.logged('Deposited Rune_Condition_Summons'), 1, 'one receipt line for the rune')
    eq(h.logged('3 of 3 unit(s) left the bag (stash list +0)'), 1, 'the bag-side receipt names the stash delta')
    eq(h.logged('Deposit requested'), 25, 'one command per stack')
end)

case('Q5-8 shipped defaults: a full socketables bag (gems, runes) is stashed by a standalone Rosie', function()
    local h = new({place = 'pit'})
    socket_host(h, {})
    fill(h, 24)
    h.inventory = {}
    ok(h.run_until(function() return tracker(h).outcome == 'completed' or tracker(h).outcome == 'failed' end, 240),
        'an automatic trip ran\n' .. h.tail())
    eq(tracker(h).outcome, 'completed', 'the trip completed: ' .. tostring(tracker(h).failure_reason))
    eq(left(h), 0, 'the full socketables bag is stashed with the shipped defaults')
end)

-- QQT_Warpigz_v3 (Q5 review): the per-item bounds, pinned one by one.
local function gems_left(h)
    local n = 0
    for _, item in ipairs(h.socketables) do if item.sno ~= RUNE and item.name:find('^Gem_Ruby') then n = n + item.stack end end
    return n
end

case('Q5-11 one socketable with an unreadable SNO (0 or raising) never voids the bag count: the rest is stashed', function()
    for _, variant in ipairs({'zero', 'raise'}) do
        local h = live_host({})
        local bad = socketable(h, 'Gem_Unknown', variant == 'zero' and 0 or 2799999, 1)
        if variant == 'raise' then function bad:get_sno_id() error('host: sno unreadable') end end
        table.insert(h.socketables, 1, bad)
        local done = trip(h, 300)
        print('   Q5-11 ' .. variant .. ' result: ' .. reason(done) .. ' left=' .. left(h))
        expect_serviced(h, done, 'Q5-11 ' .. variant)
        eq(left(h), bad.stack, variant .. ': only the unreadable stack stays')
        eq(h.logged('SNO or stack count unreadable'), 1, variant .. ': passed over by the candidate check, logged once')
        eq(h.logged('bag contents unreadable'), 0, variant .. ': the good items are never blamed')
        eq(h.logged('not accepted'), 0, variant .. ': no MAX_SKIPS failure')
    end
end)

case('Q5-12 two refused items listed first: each is skipped with its own interactions, every gem is stashed', function()
    local h = live_host({refuse = RUNE, gems = 23})
    local second = socketable(h, 'Rune_Refused_2', RUNE + 1, 3)
    table.insert(h.socketables, 2, second)
    local move = h.G.loot_manager.move_item_to_stash
    h.G.loot_manager.move_item_to_stash = function(item)
        if item == second then
            h.socket_moves[second.sno] = (h.socket_moves[second.sno] or 0) + 1
            if h.vendor_screen and h.vendor_actor == h.temis_stash then return true end -- refused: nothing moves
            return false
        end
        return move(item)
    end
    local done = trip(h, 300)
    print('   Q5-12 result: ' .. reason(done) .. ' gems_left=' .. gems_left(h))
    expect_serviced(h, done, 'Q5-12')
    eq(gems_left(h), 0, 'all 23 gems stashed')
    eq(h.logged('did not open'), 0, 'not "Stash window did not open after 4 interactions"')
    eq(h.logged('Skipped Rune_Condition_Summons'), 1, 'first refused item skipped once')
    eq(h.logged('Skipped Rune_Refused_2'), 1, 'second refused item skipped once')
end)

case('Q5-13 a socketable whose get_name() raises is still stashed (the name is only a label)', function()
    local h = live_host({})
    local first = h.socketables[1]
    function first:get_name() error('host: name unreadable') end
    local done = trip(h)
    print('   Q5-13 result: ' .. reason(done) .. ' left=' .. left(h))
    expect_serviced(h, done, 'Q5-13')
    eq(left(h), 0, 'the whole bag is stashed, the unnamed rune included')
    eq(h.logged('Item metadata unavailable'), 0, 'no metadata failure')
end)

case('Q5-14 the stash accepts 2 stacks, then refuses everything: the idle passes end the step at pass 12, bounded commands', function()
    local h = live_host({gems = 24})
    local lm, commands, accepted = h.G.loot_manager, 0, 0
    local move = lm.move_item_to_stash
    lm.move_item_to_stash = function(item)
        if not (item and item.socket) then return move(item) end
        commands = commands + 1
        if not (h.vendor_screen and h.vendor_actor == h.temis_stash) then return false end
        if accepted >= 2 then return true end -- the tab is full: nothing moves
        accepted = accepted + 1
        return move(item)
    end
    local t0 = h.now
    local done = trip(h, 300)
    print(string.format('   Q5-14 result: %s commands=%d seconds=%.0f', reason(done), commands, h.now - t0))
    eq(done[1], nil, 'the step ends once the passes move nothing (the bag need is gone): ' .. reason(done))
    eq(tracker(h).stash_done, true, 'stash step done, not failed')
    eq(h.logged('Skipped Gem_Ruby_0'), 5, 'five per-item skip lines, then a summary\n' .. h.tail(12))
    -- Pass 1 sends all 25 (2 move), passes 2-4 send the 23 left, passes 5-12
    -- only THIN=2 each; the step ends at pass 12 (FIRST_WAIT).
    ok(commands <= 2 + 23 * 4 + 2 * 8, 'at most 2 + 23 x 4 + 2 x 8 deposit commands: ' .. commands)
    eq(h.logged('timed out'), 0, 'ended by the idle-pass bound, not by a service timeout')
    eq(tracker(h).fail_permanent, false, 'retryable')
end)

case('Q5-15 the stash stack of the SNO is unreadable when the command is sent: the deposit still goes out', function()
    local h = live_host({})
    h.stash[1].get_stack_count = function() return nil end -- the rune stack in the stash: count unreadable
    local done = trip(h)
    print('   Q5-15 result: ' .. reason(done) .. ' left=' .. left(h))
    expect_serviced(h, done, 'Q5-15')
    eq(left(h), 0, 'everything stashed, the rune included')
    eq(h.socket_moves[RUNE], 1, 'one command for the rune')
    eq(h.logged('stash list unreadable'), 1, 'the bag decides the receipt')
    eq(h.logged('Skipped'), 0, 'nothing skipped')
end)

case('Q5-16 a same-SNO bag entry whose count is unreadable: the readable stack is stashed, the other passed over', function()
    local h = live_host({gems = 23})
    -- A second rune stack whose stack count cannot be read. QQT_Warpigz_v3
    -- 1.0.25 (stash passes): it is left out of the rune's bag
    -- quantity (it no longer voids it), so the readable stack is sent and
    -- confirmed; the unreadable one is passed over, logged once.
    local ghost = socketable(h, 'Rune_Condition_Summons', RUNE, 1)
    function ghost:get_stack_count() return nil end
    table.insert(h.socketables, 2, ghost)
    local done = trip(h, 300)
    print('   Q5-16 result: ' .. reason(done) .. ' gems_left=' .. gems_left(h))
    expect_serviced(h, done, 'Q5-16')
    eq(gems_left(h), 0, 'every gem stashed')
    eq(h.logged('bag contents unreadable'), 0, 'no per-item bag wait')
    eq(h.socket_moves[RUNE], 1, 'the readable rune stack is sent once and stashed')
    eq(left(h, RUNE), 1, 'only the unreadable stack stays')
    eq(h.logged('SNO or stack count unreadable'), 1, 'the unreadable stack is passed over, logged once')
end)

case('Q5-17 an item whose SNO turns unreadable between selection and the command never fails the stash', function()
    local h = live_host({})
    -- The wrapper expires right after its first read in a frame: the candidate
    -- check reads it; the command uses that read (a second read would raise).
    local flaky = h.socketables[1]
    function flaky:get_sno_id()
        if self.read_at == h.now then error('host: wrapper expired') end
        self.read_at = h.now
        return self.sno
    end
    local done = trip(h)
    print('   Q5-17 result: ' .. reason(done) .. ' left=' .. left(h))
    expect_serviced(h, done, 'Q5-17')
    eq(gems_left(h), 0, 'every gem stashed')
    ok(left(h, RUNE) == 0 or h.logged('Skipped Rune_Condition_Summons') == 1, 'the rune is stashed or skipped once')
    eq(h.logged('Item metadata unavailable'), 0, 'no stash failure')
    eq(h.logged('not accepted'), 0, 'no MAX_SKIPS failure')
end)

print('Rosie stash Q5: ' .. checks .. ' checks')
if #failures > 0 then error(#failures .. ' failure(s):\n' .. table.concat(failures, '\n')) end
