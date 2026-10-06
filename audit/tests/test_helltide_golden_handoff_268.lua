-- QQT_Warpigz_v3 2.6.8 (Auditor, 3.3.24 review; repro_hr_golden_handoff_267):
-- the golden-tear handoff only released the focus. The central
-- SMP_Chargeable kept its stand record (approach clock, engaged time), so
-- coming back to it skipped it at once ("no progress for 15s" / "engaged
-- 150s") and marked it spent. A: a golden tear opens while walking to the
-- central one; B: 25 s inside it, then six golden tears. C (LOW): a forced
-- step latched on a sprinting golden tear is dropped beyond NEAR_IN (no
-- force_move_raw at 30 m). Pure module test; runs under Lua 5.4 and LuaJIT.
local here = assert(SUITE_ROOT, 'SUITE_ROOT is required')
package.path = here .. '/HelltideRevamped/?.lua;' .. package.path
local settings = { mode = 1, hunt_rift = true, tear_use_charge_ring = true, rupture_open_chests = false }
package.loaded['core.settings'] = settings
local function position(x)
    return { x = function() return x end, y = function() return 0 end, z = function() return 0 end,
        dist_to = function(_, other) return math.abs(x - other:x()) end }
end
local player = position(0)
package.loaded['core.utils'] = { distance_to = function(target)
    return player:dist_to(target.get_position and target:get_position() or target) end }
package.loaded['data.enums'] = {}
local tracker = {}
package.loaded['core.tracker'] = tracker
package.loaded['core.hr_cinder_run'] = {}
local LOG = {}
console = { print = function(s) LOG[#LOG + 1] = s end }
attributes = { GIZMO_HAS_BEEN_OPERATED = 'operated', CHARGEABLE_GIZMO_PROGRESS = 'progress' }
local time, actors, moved = 0, {}, nil
get_time_since_inject = function() return time end
get_player_position = function() return player end
local event = require 'core.hr_tear_event'
local states = { RIFT_CLOSE_TEARS = 'RIFT_CLOSE_TEARS', RIFT_STAY_ACTIVE = 'RIFT_STAY_ACTIVE',
    EXPLORE_HELLTIDE = 'EXPLORE_HELLTIDE', KILL_MONSTERS = 'KILL_MONSTERS' }
for state in pairs(event.RIFT_STATES) do states[state] = state end
local task = {}
FORCED = {}
event.bind({ force_step = function(pos) FORCED[#FORCED+1] = pos:x(); return true end, get_actors = function() return actors end,
    move_to = function(target) moved = target end, clear_movement = function() moved = nil end })
local function actor(id, skin, x, hp)
    return { id = id, skin = skin, pos = position(x), hp = hp, progress = 0,
        get_id = function(self) return self.id end, get_skin_name = function(self) return self.skin end,
        get_position = function(self) return self.pos end, get_current_health = function(self) return self.hp end,
        get_attribute = function(self, key) return self[key] end }
end
local function golden(id, x) return actor(id, 'S14_Rupture_Major_ZE_MicroRupture', x, 24286798) end
local function chargeable(id, x) local t = actor(id, 'S14_Rupture_SMP_Chargeable', x, 0.05); t.progress = 0.5; return t end
local function reset(list)
    event.on_reset(); LOG = {}
    actors, time, moved = list, 0, nil
    task.current_state = states.RIFT_CLOSE_TEARS
    event.session().anchor = position(0)
    event.session().rupture_type = 'Normal'
end
local function tick() time = time + 0.25; event.execute(task, states) end
local function dump() for _, l in ipairs(LOG) do print('  ' .. l) end end

-- C: mobile golden tear, forced step once, then it sprints away
do
    player = position(0)
    local g = golden(5, 3); g.skin = 'S14_Rupture_Major_ZE_MicroRupture_Mobile_Sprint'
    reset({ g })
    for _ = 1, 8 do tick() end
    print('C forced after stall: ' .. #FORCED)
    g.pos = position(30)
    FORCED = {}; moved = nil
    for _ = 1, 4 do tick() end
    print('C tear 30 m away: force_step calls=' .. #FORCED .. ' last=' .. tostring(FORCED[#FORCED]) .. ' batmobile move_to=' .. tostring(moved ~= nil))
    C_FORCED, C_MOVED = #FORCED, moved ~= nil
end
-- A: approaching the central chargeable, a golden circle opens; after the
-- golden closes the chargeable is re-focused with its stale approach clock.
do
    player = position(0)
    local ch, g = chargeable(1, 10), golden(2, -5)
    reset({ ch })
    tick() -- focus chargeable at d=10
    assert(event.session().focus_tear == ch)
    actors = { ch, g }
    tick() -- handoff
    assert(event.session().focus_tear == g, 'handoff')
    player = position(-5)
    for _ = 1, 80 do tick() end -- 20 s in the golden circle
    g.hp = 0
    tick(); tick(); tick()
    local skipped = false
    for _, l in ipairs(LOG) do if l:find('Skipping tear S14_Rupture_SMP_Chargeable', 1, true) then skipped = true end end
    print('A focus=' .. tostring(event.session().focus_tear and event.session().focus_tear.skin)
        .. ' unreached=' .. tostring(event.session().tear_unreached) .. ' chargeable_skipped=' .. tostring(skipped))
    dump()
    A_SKIPPED = skipped
end
-- D (QQT_Warpigz_v3 2.6.9, review of 2.6.8): the focus flickers to a golden
-- tear for one tick every 2 s while the central one cannot be reached (the
-- player never gets closer): a sub-second time away is not a refocus, so the
-- 15 s approach window still runs out and the tear is skipped.
do
    player = position(0)
    local ch = chargeable(1, 10)
    reset({ ch })
    for i = 1, 240 do -- 60 s
        if i % 8 == 0 then actors = { ch, golden(100 + i, -30) } else actors = { ch } end
        tick()
    end
    D_SKIPPED = false
    for _, l in ipairs(LOG) do if l:find('Skipping tear S14_Rupture_SMP_Chargeable', 1, true) then D_SKIPPED = true end end
    print('D flicker: chargeable skipped=' .. tostring(D_SKIPPED))
end
-- B
do
    player = position(0)
    local ch = chargeable(1, 0)
    reset({ ch })
    for _ = 1, 100 do tick() end -- 25 s inside the chargeable
    local gs = {}
    for i = 1, 6 do
        local g = golden(10 + i, -5); actors = { ch, g }; player = position(-5)
        for _ = 1, 88 do tick() end -- 22 s per golden
        g.hp = 0; tick(); actors = { ch }
    end
    player = position(0)
    for _ = 1, 4 do tick() end
    local skipped
    for _, l in ipairs(LOG) do if l:find('Skipping tear S14_Rupture_SMP_Chargeable', 1, true) then skipped = l end end
    print('B time=' .. time .. ' closed=' .. tostring(event.session().tears_closed) .. ' skip=' .. tostring(skipped))
    assert(not A_SKIPPED, 'A: chargeable skipped at once after the golden handoff (stale approach clock)')
    assert(not skipped, 'B: chargeable skipped: ' .. tostring(skipped))
    assert(C_FORCED == 0 and C_MOVED, 'C: a sprinting golden tear 30 m away got ' .. tostring(C_FORCED)
        .. ' force_move_raw steps (the walk is a Batmobile move_to beyond NEAR_IN)')
    assert(D_SKIPPED, 'D: focus flicker kept resetting the approach window (an unreachable tear never skipped in 60 s)')
end
print('PASS: test_helltide_golden_handoff_268 (A, B, C, D)')
