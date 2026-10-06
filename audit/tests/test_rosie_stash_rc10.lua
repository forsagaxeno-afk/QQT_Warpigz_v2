-- Rosie 1.0.7 (2.3.0-rc.10): the stash chest opens like Alfred's.
-- Live rc.8: "Open stash: attempt=1..4 distance=1.9 host=true" then "Stash
-- window did not open after 4 interactions", while the Blacksmith repair
-- (vendor.is_open('BLACKSMITH') identity gate) worked. The live log cannot say
-- which host signal stayed silent, so every plausible host variant is covered
-- (joint_host.lua opt-in stash options): the rc.9 model (A), a silent
-- vendor-screen flag (B, C), the inventory flag (D), a get_current_vendor()
-- that keeps naming the Blacksmith (E, I), a cached stash list (F, F2), a
-- short reach (H), a first interaction that does nothing (K), a chest that
-- never opens (G, G2: bounded failure) and the stash pull (P).
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
    if passed then print('PASS stash: ' .. name)
    else failures[#failures + 1] = name; print('FAIL stash: ' .. name .. ': ' .. tostring(err):sub(1, 1500)) end
end
local CONSUMER = {name = 'Consumer', dir = ROOT .. '/audit/tests/', loaded = {}}
local function new(opts)
    opts = opts or {}
    opts.rosie, opts.dirs = true, {}
    local h = J.new(opts)
    h.assert_clean('load')
    return h
end
local function as_consumer(h, fn) return h.as(CONSUMER, fn) end
local function alfred(h) return h.G.AlfredTheButlerPlugin end
local function enable(h)
    eq(as_consumer(h, function() return h.G.RosiePlugin.enable() end), true, 'RosiePlugin.enable()')
    h.frame()
end
local function stash_trip(opts, seed, worn)
    local h = new(opts)
    enable(h)
    h.stash = {}
    for i = 1, seed do h.stash[i] = h.gear({rarity = 8, ancestral = true}) end
    if worn then h.equipped = {h.gear({durability = 40})} end
    h.inventory = {}
    for i = 1, 3 do h.inventory[i] = h.gear() end                              -- salvaged
    for i = 4, 5 do h.inventory[i] = h.gear({rarity = 8, ancestral = true}) end -- mythics: kept, stashed
    local done
    eq(as_consumer(h, function() return alfred(h).trigger_tasks('WarPigs', function(r, d) done = {r, d} end) end), true)
    ok(h.run_until(function() return done ~= nil end, 150), 'the trip finished\n' .. h.tail())
    return h, done
end
local function expect_ok(h, done, label)
    eq(done[1], nil, label .. ' serviced: ' .. tostring(done[2] and done[2].reason) .. '\n' .. h.tail(14))
    eq(#h.stashed, 2, label .. ' both mythics deposited')
    eq(h.logged('did not open'), 0, label)
end

case('A rc.9 model: flag raised, current vendor nil, stash has items', function()
    local h, done = stash_trip({}, 1); expect_ok(h, done, 'A')
    -- The bounded A* (rosie/private/route.lua) answers for pickup only.
    local okr, route = pcall(function() return h.mod('Rosie', 'rosie.private.route') end)
    if okr and type(route) == 'table' then eq(route.stats.plans, 0, 'town movement never plans') end
end)
case('B flag silent, stash has items', function()
    local h, done = stash_trip({stash_screen_flag = false}, 1); expect_ok(h, done, 'B')
end)
case('C flag silent, EMPTY stash', function()
    local h, done = stash_trip({stash_screen_flag = false}, 0); expect_ok(h, done, 'C')
end)
case('D flag silent, EMPTY stash, is_inventory_open() true while the stash panel is open', function()
    local h, done = stash_trip({stash_screen_flag = false, stash_inv = true}, 0); expect_ok(h, done, 'D')
end)
case('E get_current_vendor() keeps naming the Blacksmith (repair first)', function()
    local h, done = stash_trip({vendor_sticky = true}, 1, true)
    ok(h.repairs > 0, 'repaired first')
    expect_ok(h, done, 'E')
end)
case('F stash list readable (cached) while the panel is closed, flag silent', function()
    local h, done = stash_trip({stash_screen_flag = false, stash_stale = true}, 1); expect_ok(h, done, 'F')
end)
case('G chest never opens: bounded failure, few host moves', function()
    local h, done = stash_trip({stash_broken = true}, 1)
    ok(done[1] ~= nil, 'failure reported')
    eq(#h.stashed, 0, 'nothing deposited')
    ok((h.stash_moves or 0) <= 8, 'bounded deposit calls: ' .. tostring(h.stash_moves))
end)
case('H interaction reach 1.8 m (Alfred approaches to < 2 m)', function()
    local h, done = stash_trip({stash_reach = 1.8}, 1); expect_ok(h, done, 'H')
end)

case('F2 cached stash list, flag silent, nothing to salvage (no Blacksmith visit first)', function()
    local h = new({stash_screen_flag = false, stash_stale = true})
    enable(h)
    h.stash = {h.gear({rarity = 8, ancestral = true})}
    h.inventory = {h.gear({rarity = 8, ancestral = true}), h.gear({rarity = 8, ancestral = true})}
    local done
    eq(as_consumer(h, function() return alfred(h).trigger_tasks('WarPigs', function(r, d) done = {r, d} end) end), true)
    ok(h.run_until(function() return done ~= nil end, 150), 'finished')
    eq(done[1], nil, 'F2 serviced: ' .. tostring(done[2] and done[2].reason) .. '\n' .. h.tail(14))
    eq(#h.stashed, 2, 'F2 deposited')
end)
case('I sticky Blacksmith identity, flag raised, EMPTY stash, no inventory flag', function()
    local h, done = stash_trip({vendor_sticky = true}, 0, true); expect_ok(h, done, 'I')
end)
case('K first interaction does not open; stash already holds the same SNO; flag silent', function()
    local h = new({stash_screen_flag = false, stash_fail_first = 1})
    enable(h)
    local same = 424242
    h.stash = {h.gear({rarity = 8, ancestral = true, sno = same})}
    h.inventory = {h.gear({rarity = 8, ancestral = true, sno = same})}
    local done
    eq(as_consumer(h, function() return alfred(h).trigger_tasks('WarPigs', function(r, d) done = {r, d} end) end), true)
    ok(h.run_until(function() return done ~= nil end, 150), 'finished')
    eq(done[1], nil, 'K serviced: ' .. tostring(done[2] and done[2].reason) .. '\n' .. h.tail(16))
    eq(#h.stashed, 1, 'K deposited')
end)
case('G2 chest never opens: failure names the stash window, interact calls bounded', function()
    local h, done = stash_trip({stash_broken = true}, 0)
    ok(done[1] ~= nil, 'failure reported')
    local reason = tostring(done[2] and done[2].reason)
    print('   G2 reason: ' .. reason .. ' stash_moves=' .. tostring(h.stash_moves) .. ' vendor_calls=' .. tostring(#h.vendors))
    ok(reason:find('did not open', 1, true) ~= nil, reason)
    ok(#h.vendors <= 60, 'bounded interact calls: ' .. #h.vendors)
end)

case('P stash pull: a queued stash item is pulled and salvaged (rc.9 model: flag raised, vendor nil)', function()
    local h = new({})
    enable(h)
    local queued = h.gear({name = 'Queued_Helm', sno = 424242})
    h.stash = {h.gear({rarity = 8, ancestral = true}), queued}
    h.inventory = {h.gear(), h.gear()}
    eq(as_consumer(h, function() return alfred(h).queue_stash_pull(424242, 'salvage') end), true, 'queued')
    local done
    eq(as_consumer(h, function() return alfred(h).trigger_tasks('WarPigs', function(r, d) done = {r, d} end) end), true)
    ok(h.run_until(function() return done ~= nil end, 150), 'finished')
    eq(done[1], nil, 'P serviced: ' .. tostring(done[2] and done[2].reason) .. '\n' .. h.tail(16))
    local salvaged = false
    for _, item in ipairs(h.salvaged) do if item == queued then salvaged = true end end
    ok(salvaged, 'the pulled item was salvaged')
end)

case('diagnostic: the Open stash line records the actor and every signal', function()
    local h, done = stash_trip({stash_screen_flag = false}, 1)
    expect_ok(h, done, 'diag')
    local line
    for _, l in ipairs(h.log) do if tostring(l):find('Open stash: attempt=1', 1, true) then line = tostring(l); break end end
    ok(line ~= nil, 'an Open stash line\n' .. h.tail())
    for _, field in ipairs({'actor=(', 'interactable=', 'sdk=', 'inv=', 'vendor=', 'stash_n='}) do
        ok(line:find(field, 1, true) ~= nil, field .. ' in ' .. line)
    end
end)

case('guard: NPC vendors keep the identity gate (a Blacksmith panel is not the Gambler)', function()
    local h = new({})
    enable(h)
    local vendor = h.mod('Rosie', 'rosie.private.town.core.vendor')
    local smith
    for _, a in ipairs(h.G.actors_manager:get_all_actors()) do
        if a.skin == h.mod('Rosie', 'rosie.private.town.core.utils').npc_enum.BLACKSMITH then smith = a end
    end
    h.vendor_screen, h.vendor_actor = true, smith
    eq(h.as('Rosie', function() return vendor.is_open('BLACKSMITH') end), true, 'the Blacksmith panel reads open')
    eq(h.as('Rosie', function() return vendor.is_open('GAMBLER') end), false, 'another NPC key stays closed')
    eq(h.as('Rosie', function() return vendor.is_open('STASH') end), false, 'the stash is not a Blacksmith panel')
end)

-- ── Review rc.10 regressions ────────────────────────────────────────────
local function run_trip(h, limit, each)
    local done
    eq(as_consumer(h, function() return alfred(h).trigger_tasks('WarPigs', function(r, d) done = {r, d} end) end), true)
    ok(h.run_until(function() return done ~= nil end, limit or 150, each), 'the trip finished\n' .. h.tail())
    return done
end
local function mythic_deposit(opts, seed)
    local h = new(opts)
    enable(h)
    h.stash = {}
    for i = 1, seed or 1 do h.stash[i] = h.gear({rarity = 8, ancestral = true}) end
    h.inventory = {h.gear({rarity = 8, ancestral = true}), h.gear({rarity = 8, ancestral = true})}
    return h
end
-- The chest ignores every interaction until `delay` s after the first one.
local function late_chest(h, delay)
    local orig, first = h.G.interact_vendor, nil
    h.G.interact_vendor = function(a)
        if a == h.temis_stash then
            first = first or h.now
            if h.now - first < delay then return true end
        end
        return orig(a)
    end
end
local function pull_trip(opts, setup)
    local h = new(opts)
    enable(h)
    local queued = h.gear({name = 'Queued_Helm', sno = 424242})
    h.stash = {h.gear({rarity = 8, ancestral = true}), queued}
    h.inventory = {h.gear(), h.gear()}
    local lm, orig = h.G.loot_manager, h.G.loot_manager.move_item_from_stash
    h.from_calls = 0
    lm.move_item_from_stash = function(item) h.from_calls = h.from_calls + 1; return orig(item) end
    if setup then setup(h) end
    eq(as_consumer(h, function() return alfred(h).queue_stash_pull(424242, 'salvage') end), true, 'queued')
    local done = run_trip(h)
    local salvaged = false
    for _, item in ipairs(h.salvaged) do if item == queued then salvaged = true end end
    return h, done, salvaged
end

-- Review (major): a cached stash list read "the same twice" and stopped the
-- interaction; a failed deposit never re-interacted ("No transfer observed").
case('R-F4 cached stash list + a chest that opens late: deposits re-interact and succeed', function()
    for _, v in ipairs({
        {'late x1, flag silent', {stash_screen_flag = false, stash_stale = true, stash_fail_first = 1}},
        {'late x2, flag silent', {stash_screen_flag = false, stash_stale = true, stash_fail_first = 2}},
        {'late x3, flag raised', {stash_stale = true, stash_fail_first = 3}},
    }) do
        local h = mythic_deposit(v[2], 1)
        local done = run_trip(h)
        eq(done[1], nil, v[1] .. ': ' .. tostring(done[2] and done[2].reason) .. '\n' .. h.tail(14))
        eq(#h.stashed, 2, v[1] .. ' deposited')
    end
    for _, delay in ipairs({0.5, 1.0, 2.5}) do
        local h = mythic_deposit({stash_screen_flag = false, stash_stale = true}, 1)
        late_chest(h, delay)
        local done = run_trip(h)
        eq(done[1], nil, 'chest late ' .. delay .. ' s: ' .. tostring(done[2] and done[2].reason) .. '\n' .. h.tail(14))
        eq(#h.stashed, 2, 'chest late ' .. delay .. ' s deposited')
    end
    -- The player's inventory panel was open before the interaction.
    local h = mythic_deposit({stash_screen_flag = false, stash_fail_first = 1}, 0)
    h.G.is_inventory_open = function() return h.place == h.P.temis end
    local done = run_trip(h)
    eq(done[1], nil, 'inventory open + late chest: ' .. tostring(done[2] and done[2].reason) .. '\n' .. h.tail(14))
    eq(#h.stashed, 2, 'inventory open + late chest deposited')
    -- A chest that never opens is reported as such, not as a failed transfer.
    h = mythic_deposit({stash_broken = true, stash_stale = true}, 1)
    done = run_trip(h)
    local reason = tostring(done[2] and done[2].reason)
    ok(reason:find('did not open after 4 interactions', 1, true), reason)
    ok(reason:find('sdk=', 1, true) and reason:find('stash_n=', 1, true), 'the failure carries the signals: ' .. reason)
    ok((h.stash_moves or 0) <= 8, 'bounded deposit calls: ' .. tostring(h.stash_moves))
end)

-- Review (major): interaction at up to 3 m, never closer.
case('R-F6 interaction reach 1.8 m straight from the spawn (nothing to salvage)', function()
    local h = mythic_deposit({stash_reach = 1.8}, 1)
    local distances = {}
    local orig = h.G.interact_vendor
    h.G.interact_vendor = function(a)
        if a == h.temis_stash then distances[#distances + 1] = h.pos:dist_to_ignore_z(a.pos) end
        return orig(a)
    end
    local done = run_trip(h)
    eq(done[1], nil, 'reach 1.8: ' .. tostring(done[2] and done[2].reason) .. '\n' .. h.tail(14))
    eq(#h.stashed, 2, 'reach 1.8 deposited')
    ok(#distances >= 1 and distances[1] < 2, 'first interaction below 2 m: ' .. tostring(distances[1]))
end)

-- Review (minor): an NPC panel (D4: the inventory opens beside it) is not the stash.
case('R-F8 an open Blacksmith panel never takes a deposit or a probe', function()
    local h = new({})
    enable(h)
    h.G.is_inventory_open = function() return h.vendor_screen == true end
    local vendor = h.mod('Rosie', 'rosie.private.town.core.vendor')
    h.vendor_screen, h.vendor_actor = true, h.blacksmith
    eq(h.as('Rosie', function() return vendor.is_open('BLACKSMITH') end), true, 'the Blacksmith panel reads open')
    eq(h.as('Rosie', function() return vendor.is_open('STASH') end), false, 'D4-like inventory flag: not the stash')
    for _, v in ipairs({{'D4 inventory flag', true, false}, {'stash-only inventory flag', false, false}, {'cached list', false, true}}) do
        h = new({stash_broken = true, stash_stale = v[3]})
        enable(h)
        if v[2] then h.G.is_inventory_open = function() return h.vendor_screen == true end end
        local same = 777001
        h.stash = {h.gear({rarity = 8, ancestral = true, sno = same})}
        h.equipped = {h.gear({durability = 40})}
        h.inventory = {h.gear({rarity = 8, ancestral = true, sno = same}), h.gear({rarity = 8, ancestral = true, sno = same})}
        local smith_open, lm = false, h.G.loot_manager
        local orig_repair, orig_move = lm.repair_all_items, lm.move_item_to_stash
        lm.repair_all_items = function() smith_open = true; return orig_repair() end
        h.at_smith = 0
        lm.move_item_to_stash = function(item)
            if h.vendor_screen and h.vendor_actor == h.blacksmith then h.at_smith = h.at_smith + 1 end
            return orig_move(item)
        end
        local done = run_trip(h, 200, function(hh) if smith_open then hh.vendor_screen, hh.vendor_actor = true, hh.blacksmith end end)
        eq(h.at_smith, 0, v[1] .. ': move_item_to_stash while the Blacksmith panel is open')
        ok(tostring(done[2] and done[2].reason):find('did not open', 1, true), v[1] .. ': ' .. tostring(done[2] and done[2].reason))
    end
end)

-- Review (minor): the diagnostic must name the signal that opened the stash.
case('R-F9 diagnostics: deciding signal, probe tag', function()
    local h = mythic_deposit({stash_screen_flag = false, stash_inv = true}, 0)
    local orig = h.G.interact_vendor
    h.G.interact_vendor = function(a)
        if a == h.temis_stash then h.at(0.5, function() orig(a) end); return true end
        return orig(a)
    end
    local done = run_trip(h)
    eq(done[1], nil, 'async open: ' .. tostring(done[2] and done[2].reason))
    eq(h.logged('Stash reads open: signal=inv attempt=1'), 1, 'the inventory signal is named\n' .. h.tail(10))
    h = mythic_deposit({stash_screen_flag = false, stash_fail_first = 2}, 0)
    done = run_trip(h)
    eq(done[1], nil, 'probe trip: ' .. tostring(done[2] and done[2].reason))
    ok(h.logged('probe=true') >= 1, 'probe deposits are tagged\n' .. h.tail(10))
end)

-- Review (major): the pull re-interacts when nothing arrives; (minor) the
-- stash list may lag the panel.
case('R-F5/F7 stash pull: late chest with a cached list, and a lagging list', function()
    for _, delay in ipairs({1.0, 2.5}) do
        local h, done, salvaged = pull_trip({stash_stale = true}, function(hh) late_chest(hh, delay) end)
        eq(done[1], nil, 'pull, chest late ' .. delay .. ' s: ' .. tostring(done[2] and done[2].reason))
        ok(salvaged, 'pull, chest late ' .. delay .. ' s: salvaged')
        ok(h.from_calls <= 12, 'bounded pull calls: ' .. h.from_calls)
    end
    local h, done, salvaged = pull_trip({stash_stale = true, stash_broken = true})
    ok(done[1] ~= nil and not salvaged, 'a chest that never opens fails the pull')
    ok(h.from_calls <= 12, 'bounded pull calls on a closed chest: ' .. h.from_calls)
    for _, v in ipairs({{'flag raised', {}}, {'flag silent + inv', {stash_screen_flag = false, stash_inv = true}}}) do
        h, done, salvaged = pull_trip(v[2], function(hh)
            local player = hh.G.get_local_player()
            local orig_items, was_open, opened_at = player.get_stash_items, false, nil
            player.get_stash_items = function(self)
                local open = hh.vendor_screen and hh.vendor_actor == hh.temis_stash
                if open and not was_open then opened_at = hh.now end
                was_open = open
                if open and opened_at and hh.now - opened_at < 0.5 then return {} end
                return orig_items(self)
            end
        end)
        eq(done[1], nil, v[1] .. ' list lag 0.5 s: ' .. tostring(h.mod('Rosie', 'rosie.private.town.core.tracker').failure_reason))
        ok(salvaged, v[1] .. ' list lag 0.5 s: salvaged')
    end
end)

-- Review (major): a queued SNO never takes a stashed Mythic form of it.
case('R-F2 stash pull keeps a same-SNO Mythic form ("Always keep mythics")', function()
    local function affix(hash, name) return {affix_name_hash = hash, get_name = function() return name end} end
    local h = new({})
    enable(h)
    local plain = h.gear({name = 'Helm_Unique_Generic_005', sno = 2647147, rarity = 6, ancestral = true, ga = 0,
        affixes = {affix(2662414, 'Helm_Unique_Generic_005'), affix(1829592, 'S04_Life')}})
    local form = h.gear({name = 'Helm_Unique_Generic_005', sno = 2647147, rarity = 6, ancestral = true, ga = 1,
        affixes = {affix(2662414, 'Helm_Unique_Generic_005'), affix(2628989, 'S14_Mythic_UniquePotency')}})
    h.stash = {plain, form}
    h.inventory = {h.gear()}
    eq(as_consumer(h, function() return alfred(h).queue_stash_pull(2647147, 'salvage') end), true, 'queued')
    local done = run_trip(h)
    local plain_salvaged, form_salvaged, form_stashed = false, false, false
    for _, item in ipairs(h.salvaged) do
        if item == plain then plain_salvaged = true end
        if item == form then form_salvaged = true end
    end
    for _, item in ipairs(h.stash) do if item == form then form_stashed = true end end
    eq(done[1], nil, 'serviced: ' .. tostring(done[2] and done[2].reason))
    ok(plain_salvaged, 'the plain Unique is salvaged')
    eq(form_salvaged, false, 'the Mythic form is never salvaged')
    ok(form_stashed, 'the Mythic form stays in the stash')
    eq(h.logged('Kept in the stash: sno=2647147'), 1, 'the kept Mythic is logged')
    -- Only a Mythic (S14 iconic) and an undecided Unique are stashed: nothing is taken.
    h = new({})
    enable(h)
    local harlequin = h.gear({name = 'S14_Helm_Unique_Generic_002', sno = 2646291, rarity = 6, ancestral = true, ga = 0,
        affixes = {affix(2646292, 'S14_Helm_Unique_Generic_002')}})
    local blank = h.gear({name = 'Helm_Unique_Generic_005', sno = 2647147, rarity = 6, ancestral = true, ga = 0, affixes = {}})
    h.stash = {harlequin, blank}
    h.inventory = {h.gear()}
    eq(as_consumer(h, function() return alfred(h).queue_stash_pull(2646291, 'salvage') end), true, 'queued S14')
    eq(as_consumer(h, function() return alfred(h).queue_stash_pull(2647147, 'sell') end), true, 'queued Leoric')
    run_trip(h)
    for _, list in ipairs({h.salvaged, h.sold}) do
        for _, item in ipairs(list) do ok(item ~= harlequin and item ~= blank, 'a kept stash item was sold or salvaged') end
    end
    eq(#h.stash, 2, 'both stay in the stash')
    local reason = tostring(h.mod('Rosie', 'rosie.private.town.core.tracker').failure_reason)
    ok(reason:find('kept in the stash', 1, true) and reason:find('2646291', 1, true) and reason:find('2647147', 1, true), reason)
end)

print('Rosie stash rc.10: ' .. checks .. ' checks')
if #failures > 0 then error(#failures .. ' failure(s):\n' .. table.concat(failures, '\n')) end
