local ROOT = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local J = dofile(ROOT .. '/audit/tests/joint_host.lua')
local h = J.new({rosie = true, dirs = {'Batmobile'}, place = 'pit'})
h.instrument_exports()
h.mod('Rosie', 'rosie.private.pickup.gui').elements.general.distance_slider:set(2)
h.as('Rosie', function() return h.G.RosiePlugin.enable() end)
local nav = h.mod('Batmobile', 'core.navigator')
h.run(1)
print('bat paused at start', nav.paused)
h.inventory = h.inventory or {}
for _ = 1, 25 do h.inventory[#h.inventory + 1] = h.gear() end
local function st() return h.as('Batmobile', function() return h.G.AlfredTheButlerPlugin.get_status() end) end
local resumed=false
local ok = h.run_until(function()
  local s = st()
  if not resumed and h.place == h.P.temis then
    resumed=true
    h.as('Batmobile', function() h.G.BatmobilePlugin.resume('someone') end)
    print('resumed Batmobile mid-trip at', h.now)
  end
  return resumed and not s.running
end, 200)
print('trip done', ok, 'place', h.place.name or tostring(h.place))
h.run(0.2)
local pausedlog = {}
for _,c in ipairs(h.bm_calls) do pausedlog[#pausedlog+1]=c.name..':'..tostring(c.caller) end
print('bm calls', table.concat(pausedlog, ' '))
local s = st()
print('after trip: running', s.running, 'returned', s.returned, 'outcome', s.outcome)
h.run(120)
s = st()
print('120s later idle: returned', s.returned)
print(h.tail(12))
