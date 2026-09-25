-- AlfredTheButler-WarPigz public API contract: the globals, functions and
-- get_status() fields that WarPigs, HordeDev, HelltideRevamped, Reaper,
-- WonderCity, ArkhamAsylum, SilentRaven, WarPug and audit/tests/joint_host.lua
-- read, with the semantics those callers assume (C1 live-work predicate,
-- trigger acceptance, pause/resume, one callback per waiting caller, no stale
-- request after a disable). Loads the real plugin with the harness of
-- test_alfred_items.lua.
local harness_env = setmetatable({ALFRED_TEST_HARNESS_ONLY = true}, {__index = _G})
local harness = assert(loadfile(SUITE_ROOT .. '/audit/tests/test_alfred_items.lua', 't', harness_env))()
local item = harness.item
local failures, checks = {}, 0
local function check(label, fn)
    checks = checks + 1
    local ok, err = pcall(fn)
    if not ok then failures[#failures + 1] = label .. ': ' .. tostring(err) end
end
local function eq(a, b, m) assert(a == b, (m or 'mismatch') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end

local L = 'alfred_the_butler_'
local ENABLED = {[L .. 'main_toggle'] = true}

-- C1 canonical live-work predicate, copied verbatim across the suite.
local function live(s)
    return s.trigger_tasks == true or s.external_trigger == true or s.pending == true or s.running == true
        or (s.teleport == true and s.teleport_done ~= true and s.teleport_failed ~= true)
end

local function new(widgets)
    local h = harness.new({widgets = widgets or ENABLED})
    h.pulse(2)
    return h
end

-- Runs pulses until fn() is true (or n pulses).
local function run_until(h, fn, n)
    for _ = 1, n or 200 do
        if fn() then return true end
        h.pulse(1, 0.3)
    end
    return fn()
end

check('plugin loads with an empty inventory and publishes both globals', function()
    local h = new()
    eq(h.env.AlfredTheButlerPlugin ~= nil, true, 'AlfredTheButlerPlugin')
    eq(h.env.PLUGIN_alfred_the_butler, h.env.AlfredTheButlerPlugin, 'same table under both names')
    for _, fn in ipairs({'get_status', 'create_task', 'pause', 'resume', 'trigger_tasks', 'trigger_tasks_with_teleport',
        'enable', 'disable', 'queue_stash_pull', 'get_pending_pulls', 'clear_pending_pulls',
        'get_item_decision', 'dump_items'}) do
        eq(type(h.api[fn]), 'function', fn)
    end
    h.render_menu()
    eq(#h.errors(), 0, 'no errors: ' .. table.concat(h.errors(), ' | '))
end)

check('get_status carries every field the suite reads, with the right types', function()
    local h = new()
    local s = h.api.get_status()
    local booleans = {'enabled', 'need_trigger', 'inventory_full', 'need_repair', 'trigger_tasks', 'external_trigger',
        'pending', 'running', 'teleport', 'teleport_done', 'teleport_failed', 'paused', 'all_task_done',
        'talisman_inventory_full', 'salvage_failed', 'salvage_done', 'sell_failed', 'sell_done'}
    for _, k in ipairs(booleans) do eq(type(s[k]), 'boolean', k) end
    for _, k in ipairs({'restock_count', 'inventory_count', 'salvage_count', 'sell_count', 'stash_count', 'last_reset'}) do
        eq(type(s[k]), 'number', k)
    end
    eq(s.name, 'alfred_the_butler', 'plugin label kept (user settings survive)')
    eq(s.version, 'WarPigz 1.0.1', 'version')
    eq(s.enabled, true, 'enabled')
    eq(s.restock_count, 0, 'restock_count')
    eq(live(s), false, 'idle Alfred is not live work')
    eq(s.paused_by, nil, 'paused_by')
    eq(s.external_caller, nil, 'external_caller')
end)

check('disabled Alfred reports enabled=false and refuses triggers (no stored callback)', function()
    local h = new({})
    eq(h.api.get_status().enabled, false, 'disabled')
    local called = false
    eq(h.api.trigger_tasks('WarPigs', function() called = true end), false, 'refused')
    eq(h.api.get_status().external_trigger, false, 'no request')
    h.set(L .. 'main_toggle', true)
    h.pulse(20)
    eq(called, false, 'callback never ran')
end)

check('trigger -> live work -> full town cycle -> callback once, then idle', function()
    local h = new()
    local calls = 0
    eq(h.api.trigger_tasks('WarPigs', function() calls = calls + 1 end), true, 'accepted')
    local s = h.api.get_status()
    eq(s.external_trigger, true, 'external_trigger')
    eq(s.pending, true, 'pending before the chain starts')
    eq(s.external_caller, 'WarPigs', 'external_caller')
    eq(live(s), true, 'live')
    h.pulse(1)
    eq(h.api.get_status().running, true, 'running once the chain started')
    assert(run_until(h, function() return calls > 0 end), 'cycle completes')
    h.pulse(5)
    eq(calls, 1, 'callback exactly once')
    s = h.api.get_status()
    eq(live(s), false, 'not live after completion')
    eq(s.all_task_done, true, 'all_task_done')
    eq(s.external_caller, nil, 'caller cleared')
    eq(#h.errors(), 0, 'no errors')
end)

check('two callers waiting on one cycle are both called once', function()
    local h = new()
    local a, b = 0, 0
    h.api.trigger_tasks('HordeDev', function() a = a + 1 end)
    h.api.trigger_tasks_with_teleport('WarPigs', function() b = b + 1 end)
    assert(run_until(h, function() return a > 0 and b > 0 end), 'both called')
    h.pulse(5)
    eq(a, 1, 'first'); eq(b, 1, 'second')
end)

check('pause / resume: paused, paused_by, return values, requests survive a pause', function()
    local h = new()
    eq(h.api.pause('WarPug'), true, 'pause returns true')
    local s = h.api.get_status()
    eq(s.paused, true, 'paused'); eq(s.paused_by, 'WarPug', 'paused_by')
    local called = false
    h.api.trigger_tasks('WarPigs', function() called = true end)
    h.pulse(20)
    eq(called, false, 'no cycle while paused')
    eq(h.api.get_status().external_caller, 'WarPigs', 'trigger caller kept while paused')
    eq(h.api.resume('WarPug'), true, 'resume returns true')
    s = h.api.get_status()
    eq(s.paused, false, 'resumed'); eq(s.paused_by, nil, 'paused_by cleared')
    assert(run_until(h, function() return called end), 'cycle runs after resume')
end)

check('disabling mid-request drops it: no stale cycle or callback after re-enable', function()
    local h = new()
    local called = false
    h.api.pause('X')   -- keep the request pending
    h.api.trigger_tasks('WarPigs', function() called = true end)
    h.set(L .. 'main_toggle', false)
    h.pulse(2)
    local s = h.api.get_status()
    eq(s.enabled, false, 'disabled'); eq(s.external_trigger, false, 'request dropped')
    h.api.resume('X')
    h.set(L .. 'main_toggle', true)
    h.pulse(30)
    eq(called, false, 'stale callback never ran')
    eq(live(h.api.get_status()), false, 'idle')
end)

check('create_task hands control to Alfred on need_trigger and calls on_done', function()
    local h = new({[L .. 'main_toggle'] = true, [L .. 'max_inventory'] = 20})
    for i = 1, 20 do h.inventory[i] = item({sno = 2799600 + i, rarity = 8, skin = 'Sword_Unique_' .. i}) end
    h.pulse(3)
    eq(h.api.get_status().need_trigger, true, 'need_trigger (bag of mythics)')
    local done = 0
    local task = h.api.create_task('Reaper', function() done = done + 1 end)
    eq(task.shouldExecute(), true, 'should execute')
    task.Execute()
    eq(task.status, 'waiting', 'waiting')
    eq(h.api.get_status().external_caller, 'Reaper', 'caller')
    assert(run_until(h, function() return done > 0 end), 'on_done called')
    eq(task.status, 'idle', 'idle again')
    -- the mythics were stashed, never sold or salvaged
    eq(#h.sold + #h.salvaged, 0, 'no mythic sold/salvaged')
    eq(#h.stashed, 20, 'mythics stashed')
end)

check('create_task stops waiting when Alfred is disabled', function()
    local h = new()
    local task = h.api.create_task('Helltide', function() end)
    h.api.pause('hold')
    task.status = 'idle'
    h.inventory = {}
    task.Execute()
    eq(task.status, 'waiting', 'waiting')
    h.set(L .. 'main_toggle', false)
    eq(task.shouldExecute(), false, 'not executing for a disabled Alfred')
    eq(task.status, 'idle', 'back to idle')
end)

check('teleport waits for a busy Looter read-only and at most 8 s', function()
    local h = new()
    h.zone = 'Kehj_Somewhere'
    local writes = 0
    h.env.LooteerPlugin = {is_actively_looting = function() return true end,
        getSettings = function() return true end, setSettings = function() writes = writes + 1; return true end}
    eq(h.api.trigger_tasks_with_teleport('Helltide', function() end), true, 'accepted')
    h.pulse(10, 0.3)
    eq(h.teleported, nil, 'still waiting for Looter')
    h.pulse(30, 0.3)
    eq(h.teleported ~= nil, true, 'teleported after the bound')
    eq(writes, 0, 'Looter settings never written')
    eq(live(h.api.get_status()), true, 'trip in flight is live work')
end)

check('queue_stash_pull validates arguments', function()
    local h = new()
    eq(h.api.queue_stash_pull(123, 'salvage'), true, 'ok')
    eq(h.api.queue_stash_pull('x', 'salvage'), false, 'bad sno')
    eq(h.api.queue_stash_pull(1, 'burn'), false, 'bad action')
    eq(#h.api.get_pending_pulls(), 1, 'queued')
    h.api.clear_pending_pulls()
    eq(#h.api.get_pending_pulls(), 0, 'cleared')
end)

-- One pause flag, like Batmobile-1.0.12 core/external.lua.
local function batmobile()
    local bm = {paused = false, by = nil, resumes = 0}
    bm.api = {
        is_paused = function() return bm.paused end,
        pause = function(caller) bm.paused, bm.by = true, caller end,
        resume = function(caller) bm.paused, bm.by = false, nil; bm.resumes = bm.resumes + 1 end,
        set_target = function() end, move = function() end, reset = function() end, clear_target = function() end,
    }
    return bm
end

check('disabling mid-cycle resumes the Batmobile Alfred paused; re-enable leaves it running', function()
    local h = new()
    local bm = batmobile()
    h.env.BatmobilePlugin = bm.api
    h.zone = 'Kehj_Somewhere'
    eq(h.api.trigger_tasks_with_teleport('Helltide', function() end), true, 'accepted')
    h.pulse(3)
    eq(bm.paused, true, 'paused during the cycle'); eq(bm.by, 'alfred_the_butler', 'by Alfred')
    h.set(L .. 'main_toggle', false)
    h.pulse(2)
    eq(bm.paused, false, 'resumed on disable')
    eq(live(h.api.get_status()), false, 'no live work after disable')
    h.set(L .. 'main_toggle', true)
    h.pulse(10)
    eq(bm.paused, false, 'still running after re-enable')
    eq(bm.resumes, 1, 'resumed exactly once')
    eq(h.mod('core.tracker').batmobile_resume, nil, 'note cleared')
end)

check('a Batmobile paused by someone else stays paused through a disable and a full cycle', function()
    local h = new()
    local bm = batmobile()
    bm.paused, bm.by = true, 'WarPug'
    h.env.BatmobilePlugin = bm.api
    h.api.trigger_tasks('WarPigs', function() end)
    h.pulse(3)
    h.set(L .. 'main_toggle', false)
    h.pulse(2)
    eq(bm.resumes, 0, 'not resumed on disable')
    h.set(L .. 'main_toggle', true)
    local done = false
    h.api.trigger_tasks('WarPigs', function() done = true end)
    assert(run_until(h, function() return done end), 'cycle completes')
    eq(bm.resumes, 0, 'not resumed after the cycle')
end)

check('a full cycle resumes the Batmobile it paused, once', function()
    local h = new()
    local bm = batmobile()
    h.env.BatmobilePlugin = bm.api
    local done = false
    h.api.trigger_tasks('WarPigs', function() done = true end)
    h.pulse(2)
    eq(bm.paused, true, 'paused')
    assert(run_until(h, function() return done end), 'cycle completes')
    h.pulse(3)
    eq(bm.paused, false, 'resumed'); eq(bm.resumes, 1, 'once')
end)

check('stash full ends the cycle as failed: callbacks once with failed, stuck published, not live, triggers refused', function()
    local h = new({[L .. 'main_toggle'] = true, [L .. 'max_inventory'] = 20, [L .. 'max_stash_items'] = 1})
    local bm = batmobile()
    h.env.BatmobilePlugin = bm.api
    h.stash = {item({sno = 1, rarity = 5, skin = 'Helm_Legendary_1'})}
    h.env.loot_manager.move_item_to_stash = function() return false end   -- the game's stash is full
    for i = 1, 20 do h.inventory[i] = item({sno = 2799600 + i, rarity = 8, skin = 'Sword_Unique_' .. i}) end
    h.pulse(3)
    local a, b, results = 0, 0, {}
    h.api.trigger_tasks('HordeDev', function(r) a = a + 1; results[#results + 1] = r end)
    h.api.trigger_tasks('WarPigs', function(r) b = b + 1; results[#results + 1] = r end)
    assert(run_until(h, function() return a > 0 and b > 0 end), 'callbacks fired')
    h.pulse(10)
    eq(a, 1, 'first once'); eq(b, 1, 'second once')
    eq(results[1], 'failed', 'result failed'); eq(results[2], 'failed', 'result failed (2)')
    local s = h.api.get_status()
    eq(s.stuck, true, 'stuck'); eq(s.stuck_reason, 'stash full', 'reason'); eq(s.stash_full, true, 'stash_full')
    eq(live(s), false, 'not live work (callers do not wait forever)')
    eq(s.need_trigger, false, 'need_trigger hidden while stuck')
    eq(s.inventory_full, true, 'inventory_full still true')
    eq(bm.paused, false, 'Batmobile resumed')
    eq(h.api.trigger_tasks('Reaper', function() error('must not run') end), false, 'trigger refused while stuck')
    local task = h.api.create_task('Reaper', function() end)
    eq(task.shouldExecute(), false, 'create_task does not hand off to a stuck Alfred')
    eq(h.mod('tasks.status').status, 'Alfred is stuck, your stash is probably full!!', 'status text')
    -- the keybind keeps pulsing: no new cycle starts while stuck
    h.set(L .. 'keybind_toggle', true)
    h.pulse(20)
    eq(h.api.get_status().running, false, 'no self-started cycle while stuck')
    -- the user empties the bag: stuck clears, triggers work again
    h.set(L .. 'keybind_toggle', false)
    h.inventory = {}
    h.pulse(2)
    s = h.api.get_status()
    eq(s.stuck, false, 'stuck cleared'); eq(s.stuck_reason, nil, 'reason cleared')
    eq(h.api.trigger_tasks('Reaper', function() end), true, 'accepted again')
    eq(#h.errors(), 0, 'no errors: ' .. table.concat(h.errors(), ' | '))
end)

check('stuck clears on a manual trigger and on disable', function()
    local h = new()
    local tracker = h.mod('core.tracker')
    tracker.stuck, tracker.stuck_reason = true, 'stash full'
    h.inventory = {}
    for i = 1, 25 do h.inventory[i] = item({sno = 2799700 + i, rarity = 8, skin = 'Sword_Unique_' .. i}) end
    h.pulse(2)
    eq(h.api.get_status().stuck, true, 'still stuck with a full bag')
    h.set(L .. 'manual_keybind', true)
    h.pulse(1)
    eq(h.api.get_status().stuck, false, 'manual trigger clears')
    tracker.stuck = true
    h.set(L .. 'main_toggle', false)
    h.pulse(1)
    eq(tracker.stuck, false, 'disable clears')
end)

check('another Alfred already loaded: this one keeps its hands off the globals and stays idle', function()
    local old = {get_status = function() return {enabled = true} end}
    local h = harness.new({widgets = ENABLED, globals = {AlfredTheButlerPlugin = old}})
    eq(h.env.AlfredTheButlerPlugin, old, 'old Alfred keeps its global')
    eq(h.env.PLUGIN_alfred_the_butler, nil, 'second global not taken either')
    local warned = false
    for _, line in ipairs(h.logs) do if line:find('WARNING', 1, true) and line:find('another Alfred', 1, true) then warned = true end end
    eq(warned, true, 'loud console warning')
    h.inventory = {}
    for i = 1, 25 do h.inventory[i] = item({sno = 2799800 + i, rarity = 5, skin = 'Helm_Legendary_' .. i}) end
    h.set(L .. 'keybind_toggle', true)
    h.vendor = true
    h.pulse(40, 0.5)
    eq(#h.sold + #h.salvaged + #h.stashed, 0, 'no town work by the idle copy')
    h.render_menu()
end)

check('an earlier load of this same build (script reload) is replaced', function()
    local prev = {edition = 'WarPigz'}
    local h = harness.new({widgets = ENABLED, globals = {AlfredTheButlerPlugin = prev, PLUGIN_alfred_the_butler = prev}})
    eq(h.env.AlfredTheButlerPlugin ~= prev, true, 'replaced')
    eq(h.env.AlfredTheButlerPlugin, h.env.PLUGIN_alfred_the_butler, 'both globals ours')
    eq(h.api.trigger_tasks('X', function() end), true, 'works')
end)

check('an Alfred loaded after this one takes over: this one steps aside and drops its request', function()
    local h = new()
    local bm = batmobile()
    h.env.BatmobilePlugin = bm.api
    h.api.trigger_tasks('WarPigs', function() end)
    h.pulse(2)
    eq(bm.paused, true, 'paused by the running cycle')
    local ours = h.api
    h.env.PLUGIN_alfred_the_butler = {get_status = function() return {enabled = true} end}
    h.pulse(2)
    eq(bm.paused, false, 'Batmobile released')
    eq(ours.get_status().running, false, 'our cycle stopped')
    local warned = false
    for _, line in ipairs(h.logs) do if line:find('replaced', 1, true) and line:find('WARNING', 1, true) then warned = true end end
    eq(warned, true, 'warning')
end)

check('the joint host mock and this Alfred expose the same status field names', function()
    local src = assert(io.open(SUITE_ROOT .. '/audit/tests/joint_host.lua')):read('*a')
    local list = assert(src:match("local ALFRED_FIELDS = (%b{})"), 'ALFRED_FIELDS in joint_host')
    local h = new()
    h.api.pause('WarPigs')
    local s = h.api.get_status()
    for field in list:gmatch("'([%w_]+)'") do
        assert(s[field] ~= nil or field == 'external_caller', 'missing status field ' .. field)
    end
end)

if #failures > 0 then error('Alfred API contract failed:\n' .. table.concat(failures, '\n')) end
print(string.format('PASS: Alfred API contract (%d checks)', checks))
