-- Run from HelltideRevamped: lua tests/tear_priority.lua
package.path = './?.lua;' .. package.path

local settings = { mode = 1, hunt_rift = true, tear_use_charge_ring = true, rupture_open_chests = false }
package.loaded['core.settings'] = settings
local function position(x)
    return { x = function() return x end, y = function() return 0 end,
        dist_to = function(_, other) return math.abs(x - other:x()) end }
end
local player = position(0)
package.loaded['core.utils'] = {
    distance_to = function(target)
        return player:dist_to(target.get_position and target:get_position() or target)
    end,
}
package.loaded['data.enums'] = {}
local tracker = {}
package.loaded['core.tracker'] = tracker
local mode = require 'core.hr_mode'
package.loaded['core.hr_cinder_run'] = {}
console = { print = function() end }
attributes = { GIZMO_HAS_BEEN_OPERATED = 'operated', CHARGEABLE_GIZMO_PROGRESS = 'progress' }
local time, actors, moved = 0, {}, nil
get_time_since_inject = function() return time end
get_player_position = function() return player end
local event = require 'core.hr_tear_event'
local states = { RIFT_CLOSE_TEARS = 'RIFT_CLOSE_TEARS', RIFT_STAY_ACTIVE = 'RIFT_STAY_ACTIVE',
    EXPLORE_HELLTIDE = 'EXPLORE_HELLTIDE', KILL_MONSTERS = 'KILL_MONSTERS' }
for state in pairs(event.RIFT_STATES) do states[state] = state end
local task = {}
event.bind({
    get_actors = function() return actors end,
    move_to = function(target) moved = target end,
    clear_movement = function() moved = nil end,
})
local function actor(id, skin, x, hp)
    return { id = id, skin = skin, pos = position(x), hp = hp, progress = 0,
        get_id = function(self) return self.id end,
        get_skin_name = function(self) return self.skin end,
        get_position = function(self) return self.pos end,
        get_current_health = function(self) return self.hp end,
        get_attribute = function(self, key) return self[key] end,
    }
end
local function golden(id, x)
    -- Live snapshot: golden circles are untargetable micro-ruptures with
    -- large health pools and a constant zero charge attribute.
    local tear = actor(id, 'S14_Rupture_Major_ZE_MicroRupture', x, 24286798)
    tear.is_untargetable = function() return true end
    return tear
end
local function chargeable(id, x)
    local tear = actor(id, 'S14_Rupture_SMP_Chargeable', x, 0.050000000745058)
    tear.progress = 0.88192313909531
    return tear
end
local function initial()
    return chargeable(1, 0)
end
local function reset(list)
    event.on_reset()
    settings.mode, settings.hunt_rift, settings.rupture_max_cinders = 1, true, 0
    tracker.hr_external, tracker.hr_cinder_run = nil, nil
    actors, time, moved = list, 0, nil
    task.current_state = states.RIFT_CLOSE_TEARS
    event.session().anchor = position(0)
    event.session().rupture_type = 'Colossal'
end
local function tick()
    time = time + 0.25
    event.execute(task, states)
end
local function focused(target, message)
    assert(event.session().focus_tear == target, message)
end

local tests = {}
function tests.TestV1_GoldenBeforeCentralChargeable()
    local old, gold = initial(), golden(2, 15)
    reset({ old, gold })
    tick()
    focused(gold, 'golden micro-rupture must outrank the central chargeable gizmo')
    assert(moved == gold, 'must walk toward the golden tear')
end
function tests.TestV1_GoldenPreemptsInitialFocus()
    local old, gold = initial(), golden(2, 15)
    reset({ old })
    tick()
    focused(old, 'initial tear remains usable before golden tears appear')
    actors = { old, gold }
    tick()
    focused(gold, 'new golden tear must release the initial focus immediately')
    assert(moved == gold, 'must leave the initial tear for the golden tear')
    assert((event.session().tears_closed or 0) == 0, 'switching targets is not a tear closure')
end
function tests.TestV1_KeepGoldenUntilClosed()
    local gold, next_gold = golden(2, 15), golden(3, 5)
    reset({ gold })
    tick()
    actors = { initial(), next_gold, gold }
    tick()
    focused(gold, 'nearer golden tear must not interrupt a charging golden tear')
    gold.operated = 1
    tick()
    focused(next_gold, 'closed golden tear must release focus to the next golden tear')
    assert(event.session().tears_closed == 1, 'count the actual closure once')
end
function tests.TestV1_IgnoreClosedAndOutOfRangeGolden()
    local old, closed, distant = initial(), golden(2, 5), golden(3, 100)
    closed.operated = 1
    reset({ old, closed, distant })
    tick()
    tick()
    focused(old, 'closed or out-of-event golden tears must not steal focus')
end

function tests.TestV2_CompletedChargeableCannotStayAliveThroughHealth()
    local old = chargeable(2, 5)
    old.hp = 100
    reset({ old })
    tick()
    old.progress = 99
    tick()
    focused(nil, 'full charge must override residual chargeable-gizmo health')
    assert(event.live_evidence(position(0), true, true) == nil,
        'completed chargeable tear must not keep the event alive')
    old.progress = 0 -- residual gizmo attributes can reset after completion
    assert(event.live_evidence(position(0), true, true) == nil,
        'a confirmed closed tear must remain spent for this event')
end
function tests.TestV2_MissingFocusDoesNotProveLiveTears()
    reset({ golden(2, 5) })
    tick()
    actors = {}
    tick()
    focused(nil, 'a missing tear must release focus')
    assert(event.session().quiet_since == time,
        'a stale focus key must not postpone the event quiet timer')
end
function tests.TestV2_LeftoverRingAndClosedTearReturnToPatrol()
    local old = golden(2, 5)
    local ring = actor(4, 'S14_PandemoniumCrack_gizmo_holdArea', 0, 1)
    reset({ old, ring })
    tick()
    old.hp = 0
    for _ = 1, 60 do
        tick()
        if task.current_state == states.EXPLORE_HELLTIDE then break end
    end
    assert(task.current_state == states.EXPLORE_HELLTIDE,
        'leftover ring and completed tear must not trap the event in closing/staying states')
end
function tests.TestV2_PartialChargeIsStillActive()
    local gold = chargeable(2, 5)
    gold.progress = 0.5
    reset({ gold })
    tick()
    focused(gold, 'partial charge is still an active central chargeable')
    gold.progress = 1
    tick()
    focused(gold, 'normalized full charge must wait for its confirmation interval')
    gold.progress = 0.5
    tick()
    time = time + 2
    gold.progress = 1
    tick()
    focused(gold, 'a charge drop must reset the full-charge confirmation interval')
    for _ = 1, 4 do tick() end
    focused(nil, 'sustained normalized full charge must close the tear')
end

function tests.TestV3_CombatDiscoversGoldenWithoutSeparateMarker()
    local gold = golden(2, 25)
    reset({ gold })
    task.current_state = states.KILL_MONSTERS
    assert(event.poll(task, states), 'visible open golden tear must preempt KILL_MONSTERS without a ring marker')
    assert(task.current_state == states.RIFT_CLOSE_TEARS)
    tick()
    focused(gold, 'combat discovery must engage the golden tear')
    assert(moved == gold)
end
function tests.TestV3_PatrolDiscoversGoldenWithoutSeparateMarker()
    local gold = golden(2, 25)
    reset({ gold })
    task.current_state = states.EXPLORE_HELLTIDE
    assert(event.check_events(task, states), 'patrol must engage a visible golden tear without a second marker')
    tick()
    focused(gold, 'patrol discovery must engage the golden tear')
end
function tests.TestV3_HealthyMicroIgnoresUnrelatedChargeAttribute()
    local micro = golden(2, 5)
    micro.progress = 100
    reset({ micro })
    assert(event.live_evidence(position(0), true, true) == 'tear',
        'golden micro-rupture health must not be overridden by a chargeable-gizmo attribute')
end
function tests.TestV3_ColdFullReadingDoesNotBlacklistReopenedChargeable()
    local gold = chargeable(2, 25)
    gold.progress = 99
    reset({ gold })
    assert(event.live_evidence(position(0), true, true) == nil)
    gold.progress = 0
    assert(event.live_evidence(position(0), true, true) == 'tear',
        'discovery-only closed observation must not suppress a subsequently open tear for 15 minutes')
end
function tests.TestV3_LiveTearBeforeLeftoverRing()
    local gold = golden(2, 80)
    local ring = actor(4, 'S14_PandemoniumCrack_gizmo_holdArea', 0, 1)
    reset({ ring, gold })
    task.current_state = states.KILL_MONSTERS
    assert(event.poll(task, states))
    assert(task.current_state == states.RIFT_CLOSE_TEARS,
        'a leftover nearby ring must not mask a live tear elsewhere in search range')
    tick()
    focused(gold, 'must route to the live tear, not the empty ring')
end
function tests.TestV3_HuntGatesStillApply()
    reset({ golden(2, 25) })
    task.current_state = states.KILL_MONSTERS
    settings.hunt_rift = false
    assert(not event.poll(task, states), 'hunt off must be honored')
    settings.hunt_rift = true
    mode.set_external(true)
    assert(not event.poll(task, states), 'external Warplan must not enter tears')
    mode.set_external(false)
    tracker.hr_cinder_run = { busy = function() return true end }
    assert(not event.poll(task, states), 'active chest run must retain priority')
    tracker.hr_cinder_run = nil
end
function tests.TestV3_CombatRescansAfterEmptyPoll()
    reset({})
    task.current_state = states.KILL_MONSTERS
    assert(not event.poll(task, states))
    local gold = golden(2, 25)
    actors = { gold }
    time = event.C.KILL_SCAN_TTL + 0.1
    assert(event.poll(task, states), 'an earlier empty combat scan must not block a newly visible tear')
    tick()
    focused(gold, 'newly visible tear must take over combat')
end
function tests.TestV3_LiveTearKeepsNearbyRitualAnchor()
    local gold = golden(2, 25)
    local ring = actor(4, 'S14_PandemoniumCrack_gizmo_holdArea', 10, 1)
    reset({ gold, ring })
    task.current_state = states.KILL_MONSTERS
    assert(event.poll(task, states))
    assert(event.session().anchor == ring.pos, 'use the nearby ritual centre for the rest of the event')
    tick()
    focused(gold, 'retaining the ring anchor must not stand on the ring instead of the tear')
    assert(moved == gold)
end
function tests.TestV4_MicroStepsInsideRatherThanStoppingAtFourMetres()
    local gold = golden(311951738, 3.05) -- distance from the live snapshot
    gold.hp = 18215098
    reset({ gold })
    tick()
    assert(moved == gold, 'micro-rupture must be approached inside its circle, not stopped at attack range')
    gold.pos = position(0.5)
    tick()
    assert(moved == nil and event.session().tear_standing,
        'stand still once inside the golden circle')
    gold.pos = position(3)
    tick()
    assert(moved == gold, 'follow the tear when its circle moves away')
end
function tests.TestV4_DeadMicroWithZeroChargeIsClosed()
    local gold, next_gold = golden(2, 3), golden(3, 16.10)
    reset({ gold, next_gold })
    tick()
    focused(gold, 'nearest golden tear first')
    gold.hp = 0
    tick()
    focused(next_gold, 'zero health micro-rupture must close despite its constant zero charge reading')
    assert(event.session().tears_closed == 1)
end
function tests.TestV4_MobileSprintUsesGoldenCircleMovement()
    local gold = golden(130023594, 3)
    gold.skin = 'S14_Rupture_Major_ZE_MicroRupture_Mobile_Sprint'
    reset({ initial(), gold })
    tick()
    focused(gold, 'mobile golden tear must precede the initial chargeable')
    assert(moved == gold, 'mobile golden tear must be approached inside its circle')
end

local failures, count = {}, 0
for name, test in pairs(tests) do
    count = count + 1
    local ok, err = pcall(test)
    print((ok and 'PASS ' or 'FAIL ') .. name .. (ok and '' or ': ' .. tostring(err)))
    if not ok then failures[#failures + 1] = name end
end
assert(#failures == 0, tostring(#failures) .. '/' .. count .. ' tear priority tests failed')
print(tostring(count) .. ' tear priority tests passed')
