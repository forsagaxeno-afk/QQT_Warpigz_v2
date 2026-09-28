local ROOT = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local J = dofile(ROOT .. '/audit/tests/joint_host.lua')
local CONSUMER = {name = 'Consumer', dir = ROOT .. '/audit/tests/', loaded = {}}
local h = J.new({rosie = true, dirs = {}, place = 'pit'})
h.pos = h.v(0, 0)
h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end)
h.frame()
h.mod('Rosie', 'rosie.private.pickup.gui').elements.general.distance_slider:set(30)
local P = h.mod('Rosie', 'rosie.private.pickup.src.pickup')
local function fight_state()
  local fh
  for i = 1, 60 do local n, v = debug.getupvalue(P.fight_deferred, i); if n == 'fight_hold' then fh = v end; if not n then break end end
  for i = 1, 60 do local n, v = debug.getupvalue(fh, i); if n == 'FIGHT' then return string.format('on=%s since=%s capped=%s now=%.1f', tostring(v.on), tostring(v.since), tostring(v.capped), h.now) end; if not n then break end end
end
local busy = function() return h.as(CONSUMER, function() return h.G.LooteerPlugin.is_actively_looting() end) end
local e1 = h.actor('pit', 'Dark_Conjurer', 5, 0, {enemy = true, elite = true, health = 1e9})
local d1 = h.drop('pit', -7, 0, {rarity = 5, ga = 3, name = 'Helm_Legendary_Generic_020'})
h.run(3)
print('A', fight_state(), 'busy', busy(), 'pos', h.pos:x())
do local it=h.place.items; for i=#it,1,-1 do if it[i]==d1 then table.remove(it,i) end end end
for i=1,6 do h.run(0.5); print('  A+', fight_state(), 'pos', h.pos:x()) end
e1.health = 0; h.remove_actor(e1)
for i=1,6 do h.run(10); print('  gap', fight_state()) end
print('gap', fight_state())
local rosie_moves = function() return h.count(h.moves, function(m) return m.owner == 'Rosie' end) end
local before = rosie_moves()
local t0 = h.now
local px=h.pos:x()
h.actor('pit', 'Dark_Conjurer', px+5, 0, {enemy = true, elite = true, health = 1e9})
local d2 = h.drop('pit', px-7, 0, {rarity = 5, ga = 3, name = 'Helm_Legendary_Generic_021'})
for i=1,6 do h.run(0.5); print('  B+', fight_state(), 'pos', h.pos:x(), 'busy', busy(), 'picked', tostring(d2.picked)) end
print('B', fight_state(), 'busy', busy(), 'Rosie moves', rosie_moves() - before, 'cap logged', h.logged('A fight kept pickup waiting', t0), 'picked', tostring(d2.picked))
print(h.tail(8))
