-- Rosie as the suite's Alfred / Looter provider. The REAL Rosie/main.lua is
-- loaded alone into the emulated QQT host (joint_host.lua, opts.rosie with no
-- other plugin folder): per-plugin require, one shared _G, caller-context
-- require detection. Consumer calls run in a foreign plugin context, as QQT
-- runs them, so a lazy require() inside a Rosie export is reported.
-- Checks the contract the bundle relies on (AUDIT.md C1/C5 and the inventory
-- below): documented globals, every function/field the bundle reads, idle
-- status, a with-teleport town trip and its callback, pause/resume ownership,
-- a failed trip that must not loop, and Looter busy/idle.
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
    if passed then print('PASS rosie: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL rosie: ' .. name .. ': ' .. tostring(err)) end
end

-- What the bundle calls / reads (inventory of WarPigs, WarPug, SilentRaven,
-- HordeDev, HelltideRevamped, Reaper, Arkham, WonderCity, TristramLoop).
local ALFRED_FUNCTIONS = {'get_status', 'trigger_tasks', 'trigger_tasks_with_teleport', 'pause', 'resume'}
-- C1 booleans every reader tests with == true / ~= true.
local ALFRED_BOOLEANS = {'enabled', 'trigger_tasks', 'external_trigger', 'pending', 'running', 'teleport',
    'teleport_done', 'teleport_failed', 'inventory_full', 'need_repair', 'need_trigger', 'paused',
    'all_task_done', 'allow_external', 'external_pause', 'talisman_inventory_full', 'stash_full', 'stuck'}
local LOOTER_FUNCTIONS = {'get_enabled', 'is_actively_looting', 'is_idle', 'getSettings', 'status',
    'evaluate_item', 'observe_items'}
local ROSIE_FUNCTIONS = {'status', 'enable', 'disable', 'service', 'stop', 'shutdown'}

-- A foreign plugin context (code owner != Rosie) for consumer calls.
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
local function looter(h) return h.G.LooteerPlugin end
local function st(h) return as_consumer(h, function() return alfred(h).get_status() end) end
-- AUDIT.md C1 canonical reading (copied verbatim across the suite).
local function live(s)
    return s.trigger_tasks == true or s.external_trigger == true or s.pending == true or s.running == true
        or (s.teleport == true and s.teleport_done ~= true and s.teleport_failed ~= true)
end
-- Rosie applies its switches on its next update: one frame after enable().
local function enable(h)
    eq(as_consumer(h, function() return h.G.RosiePlugin.enable() end), true, 'RosiePlugin.enable()')
    h.frame()
end
local function fill_bag(h, n)
    h.inventory = {}
    for i = 1, n or 25 do h.inventory[i] = h.gear() end
end

case('loads cleanly and publishes exactly its documented globals', function()
    local h = new()
    local globals = table.concat(h.new_globals(), ',')
    eq(globals, 'AlfredTheButlerPlugin,LooteerPlugin,PLUGIN_alfred_the_butler,RosiePlugin', 'new globals')
    eq(h.G.PLUGIN_alfred_the_butler, h.G.AlfredTheButlerPlugin, 'legacy Alfred alias is the same adapter')
    eq(alfred(h)._rosie, true); eq(looter(h)._rosie, true); eq(h.G.RosiePlugin._rosie, true)
    local rec = h.by_dir.Rosie
    ok(#rec.update == 1 and #rec.menu == 1 and #rec.render == 1, 'one host callback of each kind')
    for _, name in ipairs(ALFRED_FUNCTIONS) do eq(type(alfred(h)[name]), 'function', 'AlfredTheButlerPlugin.' .. name) end
    for _, name in ipairs(LOOTER_FUNCTIONS) do eq(type(looter(h)[name]), 'function', 'LooteerPlugin.' .. name) end
    for _, name in ipairs(ROSIE_FUNCTIONS) do eq(type(h.G.RosiePlugin[name]), 'function', 'RosiePlugin.' .. name) end
    h.run(3)
    h.assert_clean('idle frames')
    eq(#h.file_writes, 0, 'no file writes')
    eq(#h.moves + #h.waypoints, 0, 'Rosie starts off: no movement, no teleport')
end)

case('idle status: C1 fields are booleans, nothing live, master switch gates both adapters', function()
    local h = new()
    h.run(1)
    local s = st(h)
    eq(s.enabled, false, 'Rosie starts off: Alfred adapter disabled')
    eq(as_consumer(h, function() return looter(h).get_enabled() end), false, 'Looter adapter disabled')
    local accepted, why = as_consumer(h, function() return alfred(h).trigger_tasks_with_teleport('Consumer') end)
    eq(accepted, false, 'a request while Rosie is off is refused'); ok(type(why) == 'string', 'with a reason')
    enable(h)
    h.run(2)
    s = st(h)
    for _, key in ipairs(ALFRED_BOOLEANS) do eq(type(s[key]), 'boolean', 'get_status().' .. key) end
    eq(s.enabled, true); eq(live(s), false, 'idle: no live work'); eq(s.paused, false)
    eq(s.inventory_full or s.need_repair, false, 'no hard need'); eq(s.need_trigger, false)
    eq(s.paused_by, nil); eq(s.external_caller, nil); eq(s.owner, nil)
    eq(s.restock_count, 0, 'Rosie does not restock')
    eq(as_consumer(h, function() return looter(h).get_enabled() end), true)
    eq(as_consumer(h, function() return looter(h).is_actively_looting() end), false)
    eq(as_consumer(h, function() return looter(h).is_idle() end), true)
    eq(as_consumer(h, function() return looter(h).getSettings('enabled') end), true, 'legacy getSettings(enabled)')
    eq(as_consumer(h, function() return looter(h).getSettings('looting') end), nil, 'legacy nil = not looting')
    local ls = as_consumer(h, function() return looter(h).status() end)
    eq(ls.enabled, true); eq(ls.running, false); eq(ls.paused, false); eq(ls.activity_owned, false)
    local rs = as_consumer(h, function() return h.G.RosiePlugin.status() end)
    eq(rs.enabled, true); eq(rs.phase, 'ready')
    h.assert_clean('idle')
end)

case('with-teleport trip from the pit: live at once, town service, return portal, one success callback', function()
    local h = new({place = 'pit', pos = nil})
    h.pos = h.v(40, 5)
    enable(h)
    fill_bag(h, 25)
    local results = {}
    -- Requested before Rosie's own 0.5 s scan could start an automatic trip.
    local accepted = as_consumer(h, function()
        return alfred(h).trigger_tasks_with_teleport('Consumer', function(result, detail)
            results[#results + 1] = {first = result, detail = detail}
        end)
    end)
    eq(accepted, true, 'request accepted')
    local s = st(h)
    eq(live(s), true, 'C1: live synchronously after the call')
    eq(s.external_trigger, true); eq(s.running, true); eq(s.teleport, true); eq(s.pending, true)
    eq(s.external_caller, 'Consumer'); eq(s.owner, 'Consumer'); eq(s.inventory_full, true)
    local again = as_consumer(h, function() return alfred(h).trigger_tasks_with_teleport('Other') end)
    eq(again, false, 'a second caller cannot replace the running request')
    eq(as_consumer(h, function() return alfred(h).pause('Other') end), false, 'another caller cannot pause our trip')
    local saw_town, live_in_town = false, true
    ok(h.run_until(function()
        if h.place == h.P.temis then
            saw_town = true
            live_in_town = live_in_town and live(st(h))
        end
        return #results > 0
    end, 90), 'trip finished\n' .. h.tail())
    ok(saw_town, 'serviced in Temis'); ok(live_in_town, 'live during the whole town leg')
    eq(#results, 1, 'one callback')
    -- Old fork contract: nil on success; Rosie's result table as 2nd argument.
    eq(results[1].first, nil, 'legacy first argument nil = success')
    eq(type(results[1].detail), 'table', 'Rosie result table as the second argument')
    eq(results[1].detail.success, true, 'success'); eq(results[1].detail.reason, nil)
    eq(h.place, h.P.pit, 'back in the pit'); eq(h.pos:x(), 40, 'at the same spot'); eq(h.pos:y(), 5)
    eq(#h.inventory, 0, 'bag emptied'); eq(#h.salvaged, 25, 'salvaged at the Blacksmith')
    s = st(h)
    eq(live(s), false, 'C1: the latched teleport of a finished trip is not live work')
    eq(s.teleport_done, true); eq(s.all_task_done, true); eq(s.outcome, 'completed')
    eq(s.inventory_full, false); eq(s.need_trigger, false); eq(s.external_caller, nil)
    eq(h.count(h.waypoints), 1, 'one waypoint teleport (to Temis)')
    h.run(5)
    eq(#results, 1, 'the callback is not repeated')
    eq(live(st(h)), false)
    h.assert_clean('trip')
end)

case('plain trigger_tasks in Temis (WarPigs kick): serviced in place, no teleport', function()
    local h = new()
    enable(h)
    fill_bag(h, 25)
    local done
    eq(as_consumer(h, function() return alfred(h).trigger_tasks('WarPigs', function(r, d) done = {r, d} end) end), true)
    eq(st(h).teleport, false, 'no teleport from town')
    ok(h.run_until(function() return done ~= nil end, 60), 'finished\n' .. h.tail())
    eq(done[1], nil, 'nil = success'); eq(done[2].success, true)
    eq(#h.waypoints, 0, 'nobody teleported'); eq(h.place, h.P.temis)
    eq(st(h).external_trigger, false, 'WarPigs pickup edge: external_trigger clears at completion')
    h.assert_clean('kick')
end)

case('pause/resume: owner-scoped, published as paused/paused_by, holds automatic and requested trips', function()
    local h = new({place = 'pit'})
    enable(h)
    eq(as_consumer(h, function() return alfred(h).pause('TristramLoop') end), true, 'pause while idle')
    local s = st(h)
    eq(s.paused, true); eq(s.paused_by, 'TristramLoop'); eq(s.external_pause, true); eq(s.pause_caller, 'TristramLoop')
    eq(live(s), false, 'C1: a pause alone is not live work')
    fill_bag(h, 25)
    h.run(5)
    eq(#h.waypoints, 0, 'no automatic trip while paused, even with a full bag')
    eq(st(h).inventory_full, true, 'hard need published while paused')
    local accepted = as_consumer(h, function() return alfred(h).trigger_tasks_with_teleport('Consumer') end)
    eq(accepted, false, 'requests wait for the pause owner')
    eq(as_consumer(h, function() return alfred(h).pause('WarPigs') end), false, 'a second pauser is refused')
    eq(as_consumer(h, function() return alfred(h).resume('WarPigs') end), false, 'only the owner resumes')
    eq(st(h).paused_by, 'TristramLoop')
    eq(as_consumer(h, function() return alfred(h).resume('TristramLoop') end), true, 'owner resumes')
    eq(st(h).paused, false)
    -- Rosie's own automatic service then starts (need_trigger with the keybind off).
    ok(h.run_until(function() return h.place == h.P.temis end, 10), 'automatic trip after the resume')
    local s2 = st(h)
    eq(live(s2), true, 'an automatic trip is live work for every reader (running)')
    eq(s2.external_trigger, false, 'automatic: not an external request')
    ok(h.run_until(function() return h.place == h.P.pit and not live(st(h)) end, 60), 'automatic trip returned')
    h.assert_clean('pause')
end)

-- QQT_Warpigz_v2 latch: a transient failure refuses API requests for
-- RETRY_COOLDOWN s (stuck_retry_in published), then allows another attempt;
-- MAX_FAIL_STREAK consecutive failures latch until an explicit Run town service.
case('a failed trip whose need remains is stuck for a bounded cooldown; three failures latch until Run town service', function()
    local h = new()
    enable(h)
    local life = h.mod('Rosie', 'rosie.private.town.core.lifecycle')
    eq(life.RETRY_COOLDOWN, 120); eq(life.MAX_FAIL_STREAK, 3)
    h.remove_actor(h.blacksmith) -- the salvage vendor cannot be reached
    fill_bag(h, 25)
    local results = {}
    eq(as_consumer(h, function()
        return alfred(h).trigger_tasks('Consumer', function(r, d) results[#results + 1] = {first = r, detail = d} end)
    end), true)
    ok(h.run_until(function() return #results > 0 end, 200), 'failure reported\n' .. h.tail())
    eq(results[1].first, 'failed', "legacy 'failed' first argument")
    eq(results[1].detail.success, false, 'failure is reported'); ok(type(results[1].detail.reason) == 'string', 'with a reason')
    h.run(2)
    local s = st(h)
    eq(s.outcome, 'failed'); eq(live(s), false); eq(s.fail_streak, 1)
    eq(s.stuck, true, 'stuck published'); eq(s.stuck_reason, s.failure_reason)
    ok(type(s.stuck_retry_in) == 'number' and s.stuck_retry_in > 100 and s.stuck_retry_in <= 120, 'retry_in ' .. tostring(s.stuck_retry_in))
    eq(s.inventory_full, true, 'the hard need stays visible')
    eq(s.need_trigger, false, 'need_trigger is not advertised for a stuck provider')
    local accepted, why = as_consumer(h, function() return alfred(h).trigger_tasks('WarPigs') end)
    eq(accepted, false, 'no looping API trips'); ok(tostring(why):find('next attempt allowed in', 1, true), tostring(why))
    accepted = as_consumer(h, function() return alfred(h).trigger_tasks_with_teleport('Consumer') end)
    eq(accepted, false)
    local before = #h.vendors
    h.run(60)
    eq(live(st(h)), false, 'no retry inside the cooldown')
    eq(#h.vendors, before, 'no vendor walk inside the cooldown')
    eq(h.logged('[Rosie] failed'), 1)
    -- The cooldown expires: another attempt (Rosie's own automatic service or
    -- an API request, whichever comes first), which fails again.
    ok(h.run_until(function() return h.logged('[Rosie] failed') == 2 end, 400), 'second attempt\n' .. h.tail())
    h.run(1)
    eq(st(h).fail_streak, 2); eq(st(h).stuck, true); ok(st(h).stuck_retry_in ~= nil, 'still a bounded latch')
    ok(h.run_until(function() return h.logged('[Rosie] failed') == 3 end, 400), 'third attempt\n' .. h.tail())
    h.run(1)
    s = st(h)
    eq(s.fail_streak, 3); eq(s.stuck, true); eq(s.stuck_retry_in, nil, 'latched until an explicit retry')
    accepted, why = as_consumer(h, function() return alfred(h).trigger_tasks('WarPigs') end)
    eq(accepted, false); ok(tostring(why):find('Run town service', 1, true), tostring(why))
    before = #h.vendors
    h.run(300)
    eq(h.logged('[Rosie] failed'), 3, 'no fourth attempt'); eq(#h.vendors, before, 'no vendor walk while latched')
    -- The explicit retry (menu button / RosiePlugin.service) is still accepted.
    h.blacksmith = h.actor('temis', 'TWN_Skov_Temis_Crafter_Blacksmith', 2574.25, -479.20, {vendor = true})
    eq(as_consumer(h, function() return h.G.RosiePlugin.service() end), true, 'Run town service retries')
    eq(st(h).stuck, false, 'a running retry is not stuck')
    ok(h.run_until(function() return st(h).outcome == 'completed' end, 60), 'retry completes\n' .. h.tail())
    eq(#h.inventory, 0); eq(st(h).fail_streak, 0, 'a completed trip resets the streak')
    eq(as_consumer(h, function() return alfred(h).trigger_tasks('WarPigs') end), true, 'API accepted again')
    h.assert_clean('stuck')
end)

case('a non-transient failure (needs left after a complete service) latches at once; a user cancel never latches', function()
    local h = new()
    enable(h)
    -- Protected (locked, skip favourites) items keep the bag full after a complete service.
    h.mod('Rosie', 'rosie.private.town.gui').elements.skip_favorite:set(true)
    h.inventory = {}
    for i = 1, 25 do h.inventory[i] = h.gear({locked = true}) end
    local r
    eq(as_consumer(h, function() return alfred(h).trigger_tasks('Consumer', function(a) r = a end) end), true)
    ok(h.run_until(function() return r ~= nil end, 200), 'finished\n' .. h.tail())
    eq(r, 'failed')
    h.run(1)
    local s = st(h)
    eq(s.stuck, true); eq(s.stuck_retry_in, nil, 'permanent at the first failure'); eq(s.fail_streak, 1)
    h.run(200)
    eq(h.logged('[Rosie] failed'), 1, 'no retry of a non-transient failure')
    -- Cancel: a fresh bag, a trip, then the user switches Rosie off mid-trip.
    for _, item in ipairs(h.inventory) do item.locked = false end
    eq(as_consumer(h, function() return h.G.RosiePlugin.service() end), true)
    ok(h.run_until(function() return st(h).outcome == 'completed' end, 90), 'explicit retry completes\n' .. h.tail())
    fill_bag(h, 25)
    local c
    eq(as_consumer(h, function() return alfred(h).trigger_tasks('Consumer', function(a) c = a end) end), true)
    h.run(0.3) -- still walking to the vendors
    eq(live(st(h)), true)
    eq(as_consumer(h, function() return h.G.RosiePlugin.disable() end), true)
    eq(c, 'cancelled', "legacy 'cancelled' first argument")
    -- Rosie's own automatic service gated (keybind) to observe the adapter.
    h.mod('Rosie', 'rosie.private.town.gui').elements.use_keybind:set(true)
    enable(h)
    h.run(1)
    s = st(h)
    eq(s.running, false)
    eq(s.stuck, false, 'a cancel does not latch'); eq(s.need_trigger, true, 'the need is advertised again')
    ok(s.outcome ~= 'failed', 'outcome ' .. tostring(s.outcome))
    eq(as_consumer(h, function() return alfred(h).trigger_tasks('Consumer') end), true, 'accepted right after re-enable')
    h.assert_clean('cancel')
end)

case("a pause inside the owner's running trip is bounded (60 s), then the trip fails", function()
    local h = new({place = 'pit'})
    enable(h)
    fill_bag(h, 25)
    local r, d
    eq(as_consumer(h, function()
        return alfred(h).trigger_tasks_with_teleport('Consumer', function(a, b) r, d = a, b end)
    end), true)
    ok(h.run_until(function() return h.place == h.P.temis end, 20), 'in town')
    eq(as_consumer(h, function() return alfred(h).pause('Consumer') end), true, 'the owner pauses its trip')
    local t0 = h.now
    ok(h.run_until(function() return r ~= nil end, 90), 'the paused trip ended\n' .. h.tail())
    ok(h.now - t0 >= 59 and h.now - t0 <= 62, 'after ~60 s: ' .. tostring(h.now - t0))
    eq(r, 'failed'); ok(tostring(d.reason):find('Paused by Consumer', 1, true), tostring(d.reason))
    local s = st(h)
    eq(live(s), false); eq(s.paused, false, 'the owner pause ends with its trip')
    h.assert_clean('pause bound')
end)

case('mythics: the persisted loot-filter toggles and junk marks never sell or salvage a mythic (H3)', function()
    -- The old WarPigz Alfred's keys: Universal loot-filter mode on.
    local h = new({persisted = {alfred_the_butler_loot_filter_mode = true}})
    enable(h)
    local utils = h.mod('Rosie', 'rosie.private.town.core.utils')
    local settings = h.mod('Rosie', 'rosie.private.town.core.settings')
    local tgui = h.mod('Rosie', 'rosie.private.town.gui')
    h.run(1)
    eq(settings.loot_filter_mode, true, 'persisted Universal loot-filter mode')
    eq(settings.mythic_always_keep, true, 'Always keep mythics defaults on')
    local SALVAGE, SELL = utils.item_enum.SALVAGE, utils.item_enum.SELL
    local function acts(item)
        return h.as('Rosie', function()
            return utils.is_salvage_or_sell(item, SALVAGE) or utils.is_salvage_or_sell(item, SELL)
        end)
    end
    local rare = h.gear({filtered = true})
    local mythic = h.gear({rarity = 8, ancestral = true, filtered = true})
    local junk_mythic = h.gear({rarity = 8, ancestral = true, junk = true})
    eq(acts(rare), true, 'a filtered rare is salvaged (loot-filter mode works)')
    eq(acts(mythic), false, 'a filtered mythic is kept')
    tgui.elements.loot_filter_toggle:set(false); tgui.elements.loot_filter_equipment:set(true)
    tgui.elements.ancestral_item_junk:set(SALVAGE)
    h.run(1)
    eq(acts(mythic), false, 'equipment filter mode: kept')
    eq(acts(junk_mythic), false, 'junk-marked mythic: kept')
    -- Guard off: mythics follow only the mythic rules (default Keep), never
    -- the filter or junk action; an explicit mythic action still applies.
    tgui.elements.mythic_always_keep:set(false)
    h.run(1)
    eq(acts(mythic), false, 'guard off, mythic action Keep: kept despite the filter')
    eq(acts(junk_mythic), false, 'guard off: the junk action is not the mythic rule')
    tgui.elements.ancestral_item_mythic:set(SALVAGE)
    h.run(1)
    eq(acts(mythic), true, 'guard off + mythic action Salvage: the user rule applies')
    tgui.elements.mythic_always_keep:set(true); tgui.elements.ancestral_item_mythic:set(0)
    tgui.elements.loot_filter_toggle:set(true)
    -- Talismans: unique / mythic charms and seals never take the filter action.
    tgui.elements.talisman_charm_action:set(SALVAGE); tgui.elements.talisman_seal_action:set(SALVAGE)
    h.run(1)
    local function t_acts(item)
        return h.as('Rosie', function() return utils.should_salvage_talisman(item) or utils.should_sell_talisman(item) end)
    end
    eq(t_acts(h.gear({name = 'talisman_charm_joint', rarity = 3, filtered = true})), true, 'filtered rare charm salvaged')
    eq(t_acts(h.gear({name = 'talisman_charm_joint', rarity = 6, filtered = true})), false, 'filtered unique charm kept')
    eq(t_acts(h.gear({name = 'talisman_charm_joint', rarity = 8, filtered = true})), false, 'filtered mythic charm kept')
    eq(t_acts(h.gear({name = 'talisman_seal_joint', rarity = 8, filtered = true})), false, 'filtered mythic seal kept')
    -- A trip with the persisted filter on: filtered mythics survive it.
    h.inventory = {}
    for i = 1, 20 do h.inventory[i] = h.gear({filtered = true}) end
    for _ = 1, 5 do h.inventory[#h.inventory + 1] = h.gear({rarity = 8, ancestral = true, filtered = true}) end
    local r
    eq(as_consumer(h, function() return alfred(h).trigger_tasks('Consumer', function(a) r = a or 'ok' end) end), true)
    ok(h.run_until(function() return r ~= nil end, 120), 'trip finished\n' .. h.tail())
    eq(#h.salvaged, 20, 'the filtered rares were salvaged')
    for _, item in ipairs(h.salvaged) do ok(item.rarity < 8, 'no mythic salvaged') end
    for _, item in ipairs(h.sold) do ok(item.rarity < 8, 'no mythic sold') end
    h.assert_clean('mythic')
end)

case('one unreadable item never ends the census, a classification or the pulse (M2)', function()
    local h = new()
    enable(h)
    fill_bag(h, 24)
    local bad = h.gear()
    bad.broken = true
    function bad:get_rarity()
        if self.broken then error('host: item vanished') end
        return self.rarity
    end
    h.inventory[#h.inventory + 1] = bad
    -- Census only (Rosie's automatic service gated by its keybind).
    h.mod('Rosie', 'rosie.private.town.gui').elements.use_keybind:set(true)
    h.run(2)
    local s = st(h)
    eq(s.inventory_count, 25); eq(s.salvage_count, 24, 'the readable items are counted'); eq(s.running, false)
    local utils = h.mod('Rosie', 'rosie.private.town.core.utils')
    eq(h.as('Rosie', function() return utils.is_salvage_or_sell(bad, utils.item_enum.SALVAGE) end), false,
        'an unreadable item is kept, no error')
    eq(h.logged('Host error'), 0, 'no host error in the pulse'); eq(st(h).enabled, true, 'Rosie stays on')
    eq(h.logged('Item skipped this census (unreadable)'), 0, 'classification errors are contained per item')
    -- The item becomes readable: the next census counts it and a trip services all.
    bad.broken = false
    local r
    eq(as_consumer(h, function() return alfred(h).trigger_tasks('Consumer', function(a) r = a or 'ok' end) end), true)
    ok(h.run_until(function() return r ~= nil end, 120), 'trip finished\n' .. h.tail())
    eq(r, 'ok', 'the trip completed'); eq(#h.salvaged, 25)
    h.assert_clean('census')
end)

-- M1: a QQT reload mid-trip, with and without the host clearing the plugin's
-- package.loaded. The old instance cancels its trip (legacy 'cancelled'), the
-- new one owns every global and accepts the next request.
for _, keep in ipairs({false, true}) do
    case('reload mid-trip (package.loaded ' .. (keep and 'kept' or 'cleared') .. '): the new instance takes over', function()
        local h = new({place = 'pit'})
        enable(h)
        fill_bag(h, 25)
        local first, detail
        eq(as_consumer(h, function()
            return alfred(h).trigger_tasks_with_teleport('Consumer', function(a, d) first, detail = a, d end)
        end), true)
        ok(h.run_until(function() return h.place == h.P.temis end, 20), 'in town mid-trip')
        local old_alfred, old_looter, old_rosie = alfred(h), looter(h), h.G.RosiePlugin
        h.reload('Rosie', {keep_loaded = keep})
        h.assert_clean('reload')
        eq(first, 'cancelled', 'the old trip is cancelled by the reload')
        eq(detail.reason, 'Rosie reloaded during service')
        ok(alfred(h) ~= old_alfred and looter(h) ~= old_looter and h.G.RosiePlugin ~= old_rosie, 'fresh adapters')
        eq(h.G.PLUGIN_alfred_the_butler, alfred(h))
        eq(#h.by_dir.Rosie.update, 1, 'one update callback after the reload')
        h.run(2)
        local s = st(h)
        eq(s.enabled, true, 'the new instance is enabled (cached master switch)'); eq(s.stuck, false)
        eq(as_consumer(h, function() return h.G.RosiePlugin.status().enabled end), true)
        local r, d
        local accepted, why = as_consumer(h, function()
            return alfred(h).trigger_tasks('Consumer', function(a, b) r, d = a, b end)
        end)
        -- Rosie's own automatic service may already have taken the full bag.
        if accepted then
            ok(h.run_until(function() return d ~= nil end, 90), 'the next request completes\n' .. h.tail())
            eq(r, nil, 'success')
        else
            ok(not tostring(why):find('reloaded', 1, true), 'not refused as a retired instance: ' .. tostring(why))
            ok(h.run_until(function() return st(h).outcome == 'completed' end, 90), 'the automatic trip completes\n' .. h.tail())
        end
        eq(#h.inventory, 0, 'serviced by the new instance')
        eq(h.logged('This Rosie instance has reloaded'), 0)
        eq(as_consumer(h, function() return old_alfred.trigger_tasks('Consumer') end), false, 'the old adapter refuses')
        h.assert_clean('after reload')
    end)
end

case('Looter adapter: busy while collecting an accepted drop, idle after; paused during a town trip', function()
    local h = new({place = 'pit'})
    h.pos = h.v(0, 0)
    enable(h)
    h.mod('Rosie', 'rosie.private.pickup.gui').elements.general.distance_slider:set(30)
    h.drop('pit', 12, 0)
    local busy_seen, legacy_seen, status_seen = false, false, false
    ok(h.run_until(function()
        local busy = as_consumer(h, function() return looter(h).is_actively_looting() end)
        if busy then
            busy_seen = true
            legacy_seen = legacy_seen or as_consumer(h, function() return looter(h).getSettings('looting') end) == true
            status_seen = status_seen or as_consumer(h, function() return looter(h).status().running end) == true
            eq(as_consumer(h, function() return looter(h).is_idle() end), false, 'is_idle agrees')
        end
        return (h.pickups or 0) > 0
    end, 20), 'the drop was picked up\n' .. h.tail())
    ok(busy_seen, 'is_actively_looting() true while approaching the drop')
    ok(legacy_seen, 'getSettings(looting) true while collecting')
    ok(status_seen, 'status().running true while collecting')
    h.run(1)
    eq(as_consumer(h, function() return looter(h).is_actively_looting() end), false, 'idle after the pickup')
    eq(#h.inventory, 1)
    -- A drop during a town trip is left alone: the trip pauses pickup.
    fill_bag(h, 25)
    eq(as_consumer(h, function() return alfred(h).trigger_tasks_with_teleport('Consumer') end), true)
    h.drop('pit', 3, 0)
    local looting_during_trip = false
    ok(h.run_until(function()
        looting_during_trip = looting_during_trip or as_consumer(h, function() return looter(h).is_actively_looting() end)
        return h.place == h.P.temis
    end, 10), 'trip left for town')
    eq(looting_during_trip, false, 'no pickup while the trip owns the player')
    eq(as_consumer(h, function() return looter(h).status().paused end), true, 'pickup paused by the trip')
    ok(h.run_until(function() return h.place == h.P.pit and not live(st(h)) end, 60), 'trip returned')
    eq(as_consumer(h, function() return looter(h).status().paused end), false, 'pause released after the trip')
    -- Master off: both adapters report disabled at once.
    eq(as_consumer(h, function() return h.G.RosiePlugin.disable() end), true)
    eq(as_consumer(h, function() return looter(h).get_enabled() end), false)
    eq(as_consumer(h, function() return looter(h).is_actively_looting() end), false)
    eq(st(h).enabled, false)
    h.assert_clean('looter')
end)

-- M4 and the TristramLoop contract: when pickup lets go of movement while
-- another mover drives the player (a running Batmobile route or goal, or
-- TristramLoop owning loot), Rosie yields without clearing the native path.
case('pickup release yields without clearing the path when Batmobile or TristramLoop drives (M4)', function()
    local function scenario(peer)
        local h = new({place = 'pit'})
        h.pos = h.v(0, 0)
        enable(h)
        h.mod('Rosie', 'rosie.private.pickup.gui').elements.general.distance_slider:set(30)
        local item = h.drop('pit', 12, 0)
        ok(h.run_until(function() return h.count(h.moves, function(m) return m.owner == 'Rosie' end) > 0 end, 5),
            'pickup walks to the drop')
        if peer == 'batmobile' then
            h.G.BatmobilePlugin = {is_paused = function() return false end, get_owner = function() return 'arkham_asylum' end}
        elseif peer == 'tristram' then
            h.G.TRISTRAM_LOOP_STATE = {status = function()
                return {running = true, owns_activity = true, controls_loot = true}
            end}
        end
        -- The drop disappears (picked by someone else): pickup lets go.
        for i = #h.P.pit.items, 1, -1 do if h.P.pit.items[i] == item then table.remove(h.P.pit.items, i) end end
        local before = h.count(h.clears, function(c) return c.owner == 'Rosie' end)
        h.run(2)
        local cleared = h.count(h.clears, function(c) return c.owner == 'Rosie' end) - before
        eq(as_consumer(h, function() return looter(h).is_actively_looting() end), false, 'pickup idle')
        h.assert_clean('release ' .. tostring(peer))
        return cleared
    end
    ok(scenario(nil) >= 1, 'alone: pickup clears its own path')
    eq(scenario('batmobile'), 0, 'Batmobile driving: no clear')
    eq(scenario('tristram'), 0, 'TristramLoop controls loot: no clear')
end)

-- M3: the item census (every service pulse, every menu frame) runs at most
-- every 0.25 s; the overlay status is cached for 0.25 s.
case('census and overlay are throttled during a trip with the menu open (M3)', function()
    local h = new({place = 'pit'})
    enable(h)
    fill_bag(h, 25)
    eq(as_consumer(h, function() return alfred(h).trigger_tasks_with_teleport('Consumer') end), true)
    h.run(1)
    local reads0 = h.item_count_reads or 0
    local frames, status_calls = 0, 0
    local api = looter(h)
    local loot_status = api.status
    api.status = function(...) status_calls = status_calls + 1; return loot_status(...) end
    h.run(5, function() frames = frames + 1 end, 0.05)
    api.status = loot_status
    local reads = (h.item_count_reads or 0) - reads0
    ok(frames >= 100, 'frames ' .. frames)
    ok(reads <= 5 / 0.25 + 2, 'census runs at most every 0.25 s: ' .. reads .. ' in 5 s over ' .. frames .. ' frames')
    ok(reads >= 5, 'but it still runs during the trip: ' .. reads)
    ok(status_calls <= 5 / 0.25 + 2, 'menu/overlay status recomputed at most every 0.25 s: ' .. status_calls)
    h.assert_clean('throttle')
end)

case('RosiePlugin API from a foreign plugin context resolves no module lazily (QQT per-folder require)', function()
    local h = new()
    enable(h)
    fill_bag(h, 25)
    eq(as_consumer(h, function() return alfred(h).trigger_tasks('Consumer') end), true)
    h.run(4)
    local s = as_consumer(h, function() return h.G.RosiePlugin.status() end)
    eq(s.phase, 'service', 'status() while servicing')
    eq(as_consumer(h, function() return h.G.RosiePlugin.stop() end), true, 'stop() cancels the trip')
    eq(live(st(h)), false)
    eq(as_consumer(h, function() return h.G.RosiePlugin.enable() end), true)
    eq(as_consumer(h, function() return h.G.RosiePlugin.disable() end), true)
    h.assert_clean('foreign-context API')
end)

if #failures > 0 then error(table.concat(failures, '\n')) end
print('Rosie contract: ' .. checks .. ' checks')
