local ROOT = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local J = dofile(ROOT .. '/audit/tests/joint_host.lua')
local CONSUMER = {name = 'Consumer', dir = ROOT .. '/audit/tests/', loaded = {}}
local h = J.new({rosie = true, dirs = {}, place = 'temis'})
h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end); h.frame()
h.inventory = {}; for i = 1, 25 do h.inventory[i] = h.gear() end
-- the last automatic trip failed (e.g. teleport_failed under Navigator): 120 s retry cooldown
local tracker = h.mod('Rosie', 'rosie.private.town.data.tracker') or h.mod('Rosie','rosie.private.town.core.tracker')
assert(tracker, 'tracker module')
tracker.outcome = 'failed'; tracker.failure_reason = 'teleport_failed'; tracker.fail_streak = 1
tracker.failed_at = h.now
h.G.TRISTRAM_LOOP_STATE = {status = function() return {running = true, owns_activity = true, phase = 'travel'} end}
h.run(110)
print('starting-it-now lines in 110 s:', h.logged('[Rosie] Bag needs a town trip for'))
print(h.tail(4))
