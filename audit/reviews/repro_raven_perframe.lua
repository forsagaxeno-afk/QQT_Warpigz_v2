local ROOT = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local J = dofile(ROOT .. '/audit/tests/joint_host.lua')
local SR = 'SilentRaven'
local h = J.new({rosie = true, dirs = {'WarPigs', 'Batmobile', SR}, place = 'helltide'})
h.mod(SR, 'silent_raven.gui').elements.main_toggle:set(true)
assert(h.as('Rosie', function() return h.G.RosiePlugin.enable() end))
h.run(2)
h.instrument_exports()
local n0 = #h.api_calls
h.run(10)
local wp, alf = 0, 0
for i = n0 + 1, #h.api_calls do
    local c = h.api_calls[i]
    if c.context == SR and c.export == 'WarPigsPlugin' and c.name == 'status' then wp = wp + 1 end
    if c.context == SR and c.name == 'get_status' and c.export ~= 'SilentRavenPlugin' then alf = alf + 1 end
end
print(string.format('SR in the open world (WarPigs loaded, off): WarPigsPlugin.status() calls from SR in 10 s = %d (frames = %d); other get_status = %d', wp, 100, alf))
