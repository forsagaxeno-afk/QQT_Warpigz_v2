-- scratch repro (auditor): SilentRaven ignores the third-party movers/loop owners.
local ROOT = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local J = dofile(ROOT .. '/audit/tests/joint_host.lua')
local SR = 'SilentRaven'
local function trips(h)
    return h.count(h.api_calls, function(c) return c.name == 'trigger_tasks_with_teleport' and c.context == SR end)
end
local results = {}
-- A: claim trip while TristramLoop owns the activity, Butler busy, Navigator walking.
do
    local h = J.new({rosie = true, dirs = {'Batmobile', SR}, place = 'helltide'})
    h.instrument_exports()
    local g = h.mod(SR, 'silent_raven.gui').elements
    g.main_toggle:set(true); g.claim_trip_slider:set(1)
    assert(h.as('Rosie', function() return h.G.RosiePlugin.enable() end))
    h.P.helltide.helltide = true
    h.G.TRISTRAM_LOOP_STATE = {status = function() return {running = true, owns_activity = true, phase = 'farm'} end}
    h.G.Butler = {is_busy = function() return true end, get_status = function() return {is_busy = true} end}
    h.G.Navigator = {get_status = function() return {is_busy = true, owner = 'Worldstone'} end, is_busy = function() return true end}
    h.run(1)
    h.bounty_ready = true
    h.run(90)
    results[#results + 1] = 'A claim trips requested while TristramLoop owns / Butler / Navigator busy: ' .. trips(h)
end
-- B: auto-fire in Temis while Butler is busy (walking in Temis via Navigator).
do
    local h = J.new({rosie = true, dirs = {SR}, place = 'temis'})
    h.instrument_exports()
    h.mod(SR, 'silent_raven.gui').elements.main_toggle:set(true)
    assert(h.as('Rosie', function() return h.G.RosiePlugin.enable() end))
    h.G.Butler = {is_busy = function() return true end, get_status = function() return {is_busy = true, step = 'stash'} end}
    h.G.Navigator = {get_status = function() return {is_busy = true, owner = 'Butler', priority = 10} end, is_busy = function() return true end}
    h.bounty_ready = true
    local ran = false
    h.run(30, function()
        local s = h.as(SR, function() return h.G.SilentRavenPlugin.get_status() end)
        if s.running then ran = true end
    end)
    results[#results + 1] = 'B SilentRaven auto-fire ran while Butler/Navigator busy: ' .. tostring(ran)
        .. ' accepts=' .. tostring(h.reward_accepts)
end
for _, r in ipairs(results) do print(r) end
