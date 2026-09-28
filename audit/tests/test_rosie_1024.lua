-- QQT_Warpigz_v3 Rosie 1.0.24 (owner, live 3.3.5 log):
--  S  "Max stash items" is not a setting: the game maximum (350) is a
--     constant. A stale saved slider value of 300 stopped stashing ("Configured
--     stash capacity reached (300/300)") when the host miscounted the stash.
--  V  At load "[Rosie] Item preview failed: ... waiting for a living player"
--     was printed: no player yet is a wait, not an error.
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
    if passed then print('PASS rosie 1.0.24: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL rosie 1.0.24: ' .. name .. ': ' .. tostring(err)) end
end
local CONSUMER = {name = 'Consumer', dir = ROOT .. '/audit/tests/', loaded = {}}
local function new(opts)
    opts = opts or {}
    opts.rosie, opts.dirs = true, opts.dirs or {}
    local h = J.new(opts)
    h.assert_clean('load')
    eq(h.as(CONSUMER, function() return h.G.RosiePlugin.enable() end), true, 'RosiePlugin.enable()')
    h.frame()
    return h
end
local function st(h) return h.as(CONSUMER, function() return h.G.AlfredTheButlerPlugin.get_status() end) end
local function trip(h, teleport)
    local r = {}
    local name = teleport and 'trigger_tasks_with_teleport' or 'trigger_tasks'
    eq(h.as(CONSUMER, function()
        return h.G.AlfredTheButlerPlugin[name]('Consumer', function(err, res) r.err, r.res, r.done = err, res, true end)
    end), true, 'trip accepted')
    return r
end
-- A stash that already holds n items and a bag of `bag` items to stash (locked
-- gear is kept and stashed, never sold or salvaged).
local function stash_setup(h, n, bag)
    h.stash = {}
    for _ = 1, n do h.stash[#h.stash + 1] = h.gear({locked = true}) end
    h.inventory = {}
    for _ = 1, bag do h.inventory[#h.inventory + 1] = h.gear({locked = true}) end
end

case('S1 a stale saved "Max stash items" of 300 is not read: a stash of 300 still takes deposits', function()
    local h = new({place = 'temis'})
    local gui = h.mod('Rosie', 'rosie.private.town.gui')
    local el = gui.elements.max_stash_items
    if el then el:set(300) end -- the saved value from the removed slider (old code reads it)
    stash_setup(h, 300, 25)
    local r = trip(h, false)
    ok(h.run_until(function() return r.done end, 240), 'trip ends\n' .. h.tail())
    eq(h.logged('capacity reached'), 0, 'no configured capacity\n' .. h.tail(8))
    eq(st(h).stash_full, false, 'stash_full stays false')
    ok(#h.stash > 300, 'deposits went in: ' .. #h.stash)
    h.assert_clean('S1')
end)

case('S2 the stash is full at the game maximum 350', function()
    local h = new({place = 'temis'})
    stash_setup(h, 350, 25)
    local r = trip(h, false)
    ok(h.run_until(function() return r.done end, 240), 'trip ends\n' .. h.tail())
    -- The stop message belongs to the Coordinator's stash port: only the state is checked.
    eq(st(h).stash_full, true, 'stash_full')
    h.assert_clean('S2')
end)

case('S3 no "Max stash items" setting: no GUI element, settings.max_stash_items is 350', function()
    local h = new({place = 'temis'})
    eq(h.mod('Rosie', 'rosie.private.town.gui').elements.max_stash_items, nil, 'no slider')
    h.run(1)
    eq(h.mod('Rosie', 'rosie.private.town.core.settings').max_stash_items, 350, 'the game maximum')
end)

case('V1 the item preview does not print an error while no living player exists (loading)', function()
    local h = new({place = 'temis'})
    h.dead = true
    h.run(6)
    h.dead = false
    h.run(1)
    eq(h.logged('Item preview failed'), 0, 'no error line for a wait\n' .. h.tail(8))
    h.assert_clean('V1')
end)

print(string.format('rosie 1.0.24: %d checks, %d failures', checks, #failures))
if #failures > 0 then error(table.concat(failures, '\n')) end
