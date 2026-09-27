-- QQT_Warpigz_v3: learned chest atlas (core/hr_atlas.lua) and learned
-- Helltide fence (core/hr_fence.lua): observation, merging, per-slot seen /
-- miss accounting, predictions, eviction, zone isolation, the zone file
-- round trip, malformed lines, and fence in/out learning and allowed().
-- Runs under Lua 5.4 and LuaJIT.
local H = dofile(assert(SUITE_ROOT, 'SUITE_ROOT is required') .. '/audit/tests/hr_smart_harness.lua')
local R = H.runner('Helltide atlas/fence')
local ok, eq = R.ok, R.eq
local v = H.v

local MYSTERY, GLOVES = 'usz_rewardGizmo_Uber', 'usz_rewardGizmo_Gloves'

local function session(opts)
    local s = H.new(opts)
    local atlas = s.require('core.hr_atlas')
    local fence = s.require('core.hr_fence')
    local roads = s.require('core.hr_roads')
    s.tracker.hr_fence = fence
    atlas.set_zone('Step_South')
    return s, atlas, fence, roads
end

R.case('observe: one spot per chest, merged within 4 m, per chest type', function()
    local s, atlas = session()
    local a = atlas.observe(GLOVES, 75, v(100, 100), true)
    local b = atlas.observe(GLOVES, 75, v(102.5, 101), true)
    eq(a, b, 'within 4 m: the same spot')
    local c = atlas.observe(GLOVES, 75, v(106, 100), true)
    ok(c ~= a, '6 m away: another spot')
    local m = atlas.observe(MYSTERY, 250, v(100, 100), true)
    ok(m ~= a and m.type == 'mystery', 'a Mystery at the same place is its own spot')
    eq(#atlas.spots(), 3)
    eq(atlas.observe('Helltide_Unknown', 75, v(0, 0), true), nil, 'unknown chests are not learned')
end)

R.case('seen counts distinct reset slots; misses once per slot; confidence and predictions', function()
    local s, atlas = session()
    s.at_minute(1)
    local spot = atlas.observe(GLOVES, 75, v(50, 50), true)
    atlas.observe(GLOVES, 75, v(50, 50), true)
    eq(spot.seen, 1, 'the same slot counts once')
    eq(#atlas.predicted(), 0, 'seen once: not predicted yet')
    s.at_minute(16)                                   -- next slot (:15)
    atlas.observe(GLOVES, 75, v(50, 50), true)
    eq(spot.seen, 2)
    eq(#atlas.predicted(), 0, 'seen live this slot: the chest order has the actor')
    s.at_minute(21)                                   -- next slot (:20)
    eq(#atlas.predicted(), 1, 'seen in 2 slots: predicted')
    atlas.mark_miss(spot); atlas.mark_miss(spot)
    eq(spot.miss, 1, 'one miss per slot')
    eq(#atlas.predicted(), 0, 'missed this slot: not predicted again this slot')
    s.at_minute(31)
    eq(#atlas.predicted(), 1, 'conf 2/3')
    atlas.mark_miss(spot); s.at_minute(41); atlas.mark_miss(spot); s.at_minute(46); atlas.mark_miss(spot)
    ok(atlas.confidence(spot) < atlas.MIN_CONF, 'conf 2/6')
    s.at_minute(50)
    eq(#atlas.predicted(), 0, 'low confidence: not predicted')
end)

R.case('opened / spent this slot are not predicted; seen closed again = a reset', function()
    local s, atlas = session()
    local spot = atlas.observe(MYSTERY, 250, v(10, 10), true)
    s.at_minute(16); atlas.observe(MYSTERY, 250, v(10, 10), true)
    s.at_minute(21)
    eq(#atlas.predicted(), 1)
    atlas.mark_opened(v(10, 10), MYSTERY)
    eq(#atlas.predicted(), 0, 'opened this slot')
    s.advance(40)
    atlas.observe(MYSTERY, 250, v(10, 10), true)     -- closed again 40 s later
    ok(atlas.reset_seen_at ~= nil, 'reset detected')
    eq(spot.opened_slot, nil)
    s.at_minute(31)
    atlas.observe(MYSTERY, 250, v(10, 10), false)    -- seen spent
    s.at_minute(31, 30)
    eq(#atlas.predicted(), 0, 'spent this slot')
    s.at_minute(41)
    eq(#atlas.predicted(), 1, 'a new slot: predicted again')
end)

-- QQT_Warpigz_v3 (night review): a Mystery opened at :10 and seen closed
-- again at :16 (after the :15 reset) was never counted as a respawn, so the
-- spot stayed hidden for the rest of the hour.
R.case('a Mystery opened before a reset and seen closed again after it is predicted again', function()
    local s, atlas = session()
    s.set('mode', 1)
    local pos = v(100, 0)
    s.at_minute(1); atlas.observe(MYSTERY, 250, pos, true)
    s.at_minute(16); atlas.observe(MYSTERY, 250, pos, true)
    s.epoch = s.epoch + 3600; s.at_minute(10)
    atlas.observe(MYSTERY, 250, pos, true)
    atlas.mark_opened(pos, MYSTERY)
    s.advance(5); atlas.observe(MYSTERY, 250, pos, false)   -- spent right after the open
    s.at_minute(16); s.advance(40)
    local spot = atlas.observe(MYSTERY, 250, pos, true)     -- closed again after the :15 reset
    eq(spot.respawns, 1, 'respawn learned across the slot boundary')
    s.at_minute(21)
    eq(#atlas.predicted(), 1, 'the spot is a candidate again')
    local order, targets = s.require('core.hr_chest_order'), s.require('core.chest_targets')
    s.pos = v(0, 0)
    local pick = order.pick({actors = {}, remembered = {}, key_of = targets.key, player = s.pos, cinders = 300, now = s.now})
    eq(pick and pick.name, MYSTERY, 'routed to after the reset')
    -- A chest still reported interactable right after the open (lag) is no respawn.
    s.epoch = s.epoch + 3600; s.at_minute(14, 50)
    atlas.observe(MYSTERY, 250, pos, true)
    atlas.mark_opened(pos, MYSTERY)
    s.at_minute(15, 5); s.advance(5)
    atlas.observe(MYSTERY, 250, pos, true)
    eq(spot.respawns, 1, 'no respawn inside the 30 s grace')
end)

R.case('the zone file round trip, with fence and bad cells, and zone isolation', function()
    local s, atlas, fence, roads = session()
    s.at_minute(1); atlas.observe(GLOVES, 75, v(10.26, 20.44, 3), true)
    s.at_minute(16); atlas.observe(GLOVES, 75, v(10, 20), true)
    atlas.observe(MYSTERY, 250, v(-300, 400), true)
    atlas.set_exit(v(10, 20), 42, GLOVES)
    for _ = 1, 3 do fence.tick(s.now, true, v(0, 0)); s.advance(2.1) end
    fence.on_left(v(200, 0)); fence.on_left(v(205, 5))
    roads.record_bad(v(7, 7))
    ok(atlas.save_zone('Step_South'), 'saved')
    local text = s.file('learned/Step_South.txt')
    ok(text and text:find('v1|spot|regular|usz_rewardGizmo_Gloves|75|10.3|20.4|3.0|2|0|', 1, true), text)
    ok(text:find('\nin|0|0|3\n', 1, true) and text:find('\nout|10|0|2\n', 1, true), 'fence lines')
    ok(text:find('\nbad|1|1|1|', 1, true), 'bad cell line')
    -- A fresh plugin load reads it back.
    local s2 = H.new({files = s.files})
    local atlas2 = s2.require('core.hr_atlas')
    local fence2 = s2.require('core.hr_fence')
    s2.tracker.hr_fence = fence2
    atlas2.set_zone('Step_South')
    eq(#atlas2.spots(), 2)
    local g = atlas2.spot_at(v(10, 20), GLOVES)
    eq(g.seen, 2); eq(g.exit_idx, 42); eq(g.cost, 75)
    eq(fence2.allowed(v(205, 0)), false, 'learned out cell')
    eq(fence2.allowed(v(5, 5)), true, 'learned in cell')
    -- Another zone knows nothing of it.
    atlas2.set_zone('Scos_Coast')
    eq(#atlas2.spots(), 0)
    eq(fence2.allowed(v(205, 0)), true, 'no fence data in this zone')
    eq(atlas.zone_key('Step_South_Sub'), 'Step_South', 'region prefix -> patrol zone')
    eq(atlas.zone_key('Naha_Kurast'), 'Naha_Kurast')
    eq(atlas.zone_key('stats'), 'zone_stats', 'never the stats file')
end)

R.case('unparsable, oversized and out-of-range lines are ignored', function()
    local path = H.MEM_ROOT .. 'learned/Step_South.txt'
    local files = {[path] = table.concat({
        'v1|zone|Step_South',
        'v1|spot|regular|usz_rewardGizmo_Gloves|75|10|20|0|3|1|1790481600|0',     -- valid
        'v1|spot|regular|usz_rewardGizmo_Gloves|75|nan|20|0|3|1|1790481600|0',    -- NaN
        'v1|spot|mystery|usz_rewardGizmo_Gloves|75|30|20|0|3|1|1790481600|0',     -- type/name mismatch
        'v1|spot|regular|NotAChest|75|40|20|0|3|1|1790481600|0',                  -- unknown chest
        'v1|spot|regular|usz_rewardGizmo_Gloves|75|999999|20|0|3|1|1|0',          -- out of range
        'v1|spot|regular|usz_rewardGizmo_Gloves|75|50|20',                         -- short
        'in|1.5|2|3', 'in|1|2', 'out|a|b|c', 'bad|1|2|x|3',
        string.rep('in|1|1|1', 80),                                                -- 640 bytes
        'in|3|4|5', 'garbage', ''}, '\n')}
    local s = H.new({files = files})
    local atlas = s.require('core.hr_atlas')
    local fence = s.require('core.hr_fence')
    s.require('core.hr_roads')
    atlas.set_zone('Step_South')
    eq(#atlas.spots(), 1, 'one valid spot')
    local st = fence.stats('Step_South')
    eq(st.inn, 1, 'one valid in cell'); eq(st.out, 0)
end)

R.case('at most 200 spots per zone: the weakest (seen - miss), then the oldest, go first', function()
    local s, atlas = session()
    local first = atlas.observe(GLOVES, 75, v(0, 0), true)
    first.miss = 5                                        -- weakest
    for i = 1, 200 do atlas.observe(GLOVES, 75, v(i * 10, 0), true) end
    eq(#atlas.spots(), 200, 'bounded')
    eq(atlas.spot_at(v(0, 0), GLOVES), nil, 'the weakest spot was evicted')
    ok(atlas.spot_at(v(2000, 0), GLOVES) ~= nil, 'the newest is kept')
end)

R.case('fence: in / out learning and allowed()', function()
    local s, atlas, fence = session()
    eq(fence.allowed(v(1000, 1000)), true, 'no data: everything allowed')
    for i = 0, 5 do fence.tick(s.now, true, v(i * 20, 0)); s.advance(2.1) end
    eq(fence.allowed(v(50, 30)), true, 'near the learned inside')
    eq(fence.allowed(v(50, 150)), false, 'more than 60 m from every inside cell')
    fence.on_left(v(130, 0))
    eq(fence.allowed(v(130, 0)), true, 'one drop is not enough')
    fence.on_left(v(135, 5))
    eq(fence.allowed(v(130, 0)), false, 'left the Helltide there twice')
    eq(fence.segment_ok(v(0, 0), v(200, 0)), false, 'a straight line through the out cell')
    eq(fence.segment_ok(v(0, 0), v(0, 40)), true)
    -- A cell sampled inside more often than it was left stays allowed.
    for _ = 1, 3 do fence.tick(s.now, true, v(125, 5)); s.advance(2.1) end
    eq(fence.allowed(v(130, 0)), true, 'mostly inside')
    s.set('fence', false)
    eq(fence.allowed(v(50, 150)), true, 'option off')
    s.set('fence', true)
    s.set('learn', false)
    fence.on_left(v(0, 0)); fence.on_left(v(0, 0)); fence.on_left(v(0, 0))
    eq(fence.allowed(v(0, 0)), true, 'learning off: nothing learned')
    -- Seeded from the patrol loop of this zone.
    s.set('learn', true)
    s.tracker.waypoints = {v(500, 500), v(504, 500), v(508, 500)}
    s.tracker.waypoints_zone = 'Step_South'
    fence.tick(s.now, false, nil)
    eq(fence.allowed(v(510, 520)), true, 'near the loop')
end)

R.case('a failed save keeps the changes; the next save writes them', function()
    local s, atlas, fence = session()
    atlas.observe(GLOVES, 75, v(10, 10), true)
    fence.on_left(v(0, 0))
    s.fail_write = function() return true end
    eq(atlas.save_zone('Step_South'), false)
    s.fail_write = nil
    eq(atlas.save_zone('Step_South'), true, 'still dirty: saved now')
    local text = s.file('learned/Step_South.txt')
    ok(text:find('usz_rewardGizmo_Gloves', 1, true) and text:find('\nout|0|0|1\n', 1, true), text)
    eq(atlas.save_zone('Step_South'), false, 'clean: nothing to write')
end)

R.case('a zone file that exists but cannot be read is never overwritten; Forget still clears it', function()
    local path = H.MEM_ROOT .. 'learned/Step_South.txt'
    local old = 'v1|zone|Step_South\nv1|spot|regular|usz_rewardGizmo_Gloves|75|10|20|0|3|1|1790481600|0\n'
    local s = H.new({files = {[path] = old}})
    s.fail_read = function(p) return p == path end   -- locked by another program
    local atlas = s.require('core.hr_atlas')
    s.tracker.hr_fence = s.require('core.hr_fence')
    s.require('core.hr_roads')
    atlas.set_zone('Step_South')
    eq(#atlas.spots(), 0, 'nothing read')
    eq(s.logged('learned/Step_South.txt cannot be read'), 1)
    atlas.observe(GLOVES, 75, v(50, 50), true)
    s.tracker.hr_fence.on_left(v(0, 0))
    eq(atlas.save_zone('Step_South'), false, 'not saved')
    atlas.set_zone('Scos_Coast')                      -- leaving the zone saves it: refused too
    eq(#s.writes, 0, 'the file is never written')
    eq(s.files[path], old, 'the learned data is kept')
    atlas.set_zone('Step_South')
    ok(atlas.forget(), 'Forget this zone')
    eq(s.files[path], 'v1|zone|Step_South\n', 'an explicit Forget replaces it')
    -- A file over the 1 MB read limit is kept the same way.
    local big = string.rep('v1|spot|regular|usz_rewardGizmo_Gloves|75|10|20|0|3|1|1790481600|0\n', 16000)
    local t = H.new({files = {[path] = big}})
    local atlas2 = t.require('core.hr_atlas')
    t.require('core.hr_fence'); t.require('core.hr_roads')
    atlas2.set_zone('Step_South')
    eq(t.logged('larger than 1024 KB'), 1)
    atlas2.observe(GLOVES, 75, v(50, 50), true)
    eq(atlas2.save_zone('Step_South'), false)
    eq(t.files[path], big, 'the large file is untouched')
end)

R.case('forget(zone) clears spots, fence and bad cells of that zone only', function()
    local s, atlas, fence, roads = session()
    atlas.observe(GLOVES, 75, v(10, 10), true)
    fence.on_left(v(0, 0)); fence.on_left(v(0, 0))
    for _ = 1, 3 do roads.record_bad(v(1, 1)) end
    eq(roads.is_bad(v(1, 1)), true)
    atlas.set_zone('Scos_Coast'); atlas.observe(GLOVES, 75, v(10, 10), true)
    atlas.set_zone('Step_South')
    ok(atlas.forget(), 'forgotten')
    eq(#atlas.spots(), 0)
    eq(fence.allowed(v(0, 0)), true)
    eq(roads.is_bad(v(1, 1)), false)
    eq(#atlas.spots('Scos_Coast'), 1, 'the other zone keeps its spots')
    local text = s.file('learned/Step_South.txt')
    eq(text, 'v1|zone|Step_South\n', 'the zone file is emptied')
end)

R.finish()
