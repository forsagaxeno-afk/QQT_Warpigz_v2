local ROOT = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local J = dofile(ROOT .. '/audit/tests/joint_host.lua')
local CONSUMER = {name = 'Consumer', dir = ROOT .. '/audit/tests/', loaded = {}}
local fails = 0
local function new(dirs)
    local h = J.new({rosie = true, dirs = dirs or {}, place = 'pit'})
    h.pos = h.v(0, 0)
    h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end)
    h.frame()
    h.mod('Rosie', 'rosie.private.pickup.gui').elements.general.distance_slider:set(30)
    return h
end
local function scenario(label, dirs, readyfn, mover_s)
    local h = new(dirs)
    local item = h.drop('pit', 10, 0, {rarity = 5, ga = 3, name = 'Helm_Legendary_Generic_031'})
    h.run(0.5)
    -- the activity walks to its chest (another mover) for mover_s seconds, then stops (chest opened)
    local stop_at = h.now + mover_s
    local early
    local t0 = h.now
    h.run_until(function() return item.picked == true end, 60, function(hh)
        local m = (hh.now < stop_at) or (hh.now >= stop_at + 5 and hh.now < stop_at + 6.5)
        if m then
            hh.as(CONSUMER, function() return hh.G.pathfinder.request_move(hh.v(-12, 0)) end)
        elseif hh.now >= stop_at + 6.5 and not item.picked and not early and readyfn(hh) then early = hh.now - t0 end
        local b = hh.as(CONSUMER, function() return hh.G.LooteerPlugin.is_actively_looting() end)
        if b ~= hh._lastb then print(string.format('  t=%.1f busy=%s', hh.now - t0, tostring(b))); hh._lastb = b end
    end)
    print(string.format('%s: exit allowed with the drop on the ground at %s s; picked=%s at %.1f; yields=%d',
        label, tostring(early), tostring(item.picked), h.now - t0,
        h.logged('[Rosie pickup] Another move took the player off')))
    if early then fails = fails + 1 end
end
scenario('HordeDev loot_guard.ready', {'HordeDev'}, function(hh)
    local g = hh.mod('HordeDev', 'core.loot_guard')
    return hh.as('HordeDev', function() return g.ready() end)
end, 1.5)
scenario('Reaper utils.loot_ready', {'Reaper'}, function(hh)
    local u = hh.mod('Reaper', 'core.utils')
    return hh.as('Reaper', function() return u.loot_ready() end)
end, 1.5)
if fails > 0 then error(fails .. ' exits before the pickup') end
