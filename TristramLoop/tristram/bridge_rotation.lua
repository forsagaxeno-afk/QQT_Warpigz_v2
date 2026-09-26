-- Combat handoff and native equipped-spell casting for this activity.
-- An optional external rotation may read the handoff slots. The activity can
-- still fight through cast_spell.target when no external rotation is running.
local settings = require("tristram.settings")
local lease = require("tristram.activity_lease")
local bridge = {}
local target = nil
local travel = false
local movement_lock = false
local last_error = nil

function bridge.has_foreign_target()
    local current = rawget(_G, "EXTERNAL_ROTATION_TARGET")
    local barbarian = rawget(_G, "BARBARIAN_FORCE_GOBLIN_TARGET")
    return current ~= nil and current ~= target or barbarian ~= nil and barbarian ~= target
end

function bridge.available()
    return not bridge.has_foreign_target()
        and rawget(_G, "EXTERNAL_ROTATION_TRAVEL_MODE") ~= true
        and rawget(_G, "EXTERNAL_ROTATION_LOCK_MOVEMENT") ~= true
        and rawget(_G, "EXTERNAL_ROTATION_EVENT_LEASH") == nil
end

function bridge.refresh()
    if not lease.can_write() or bridge.has_foreign_target() then return end
    -- A peer may clear a shared slot between frames. Reassert only this
    -- activity's live claim; release() never erases a foreign actor.
    if target ~= nil then
        _G.EXTERNAL_ROTATION_TARGET = target
        _G.BARBARIAN_FORCE_GOBLIN_TARGET = target
        _G.EXTERNAL_ROTATION_TRAVEL_MODE = nil
        _G.EXTERNAL_ROTATION_LOCK_MOVEMENT = true
        movement_lock = true
    elseif travel then
        _G.EXTERNAL_ROTATION_TRAVEL_MODE = true
    end
end

function bridge.orb_mode_owned_elsewhere()
    return false
end

function bridge.is_degraded()
    return true
end

function bridge.last_error()
    return last_error
end

function bridge.set_travel_mode(value)
    if not lease.can_write() then return false end
    travel = value == true
    if target == nil then _G.EXTERNAL_ROTATION_TRAVEL_MODE = travel or nil end
    last_error = nil
    return true
end

function bridge.set_external_target(actor)
    if not lease.can_write() then return false end
    if actor == nil then return bridge.clear_external_target() end
    if target ~= nil and target ~= actor then
        if not bridge.clear_external_target() then return false end
    end
    target = actor
    _G.EXTERNAL_ROTATION_TARGET = actor
    _G.BARBARIAN_FORCE_GOBLIN_TARGET = actor
    _G.EXTERNAL_ROTATION_TRAVEL_MODE = nil
    _G.EXTERNAL_ROTATION_LOCK_MOVEMENT = true
    movement_lock = true
    last_error = nil
    return true
end

function bridge.clear_external_target()
    if not lease.can_write() then return false end
    if target ~= nil then
        if _G.EXTERNAL_ROTATION_TARGET == target then _G.EXTERNAL_ROTATION_TARGET = nil end
        if _G.BARBARIAN_FORCE_GOBLIN_TARGET == target then _G.BARBARIAN_FORCE_GOBLIN_TARGET = nil end
        target = nil
    end
    if movement_lock then
        if _G.EXTERNAL_ROTATION_LOCK_MOVEMENT == true then _G.EXTERNAL_ROTATION_LOCK_MOVEMENT = nil end
        movement_lock = false
    end
    _G.EXTERNAL_ROTATION_TRAVEL_MODE = travel or nil
    last_error = nil
    return true
end

function bridge.release()
    if not lease.can_write() then return false end
    if bridge.has_foreign_target() then
        -- A later writer owns the shared flags and movement. Retire only our
        -- remaining actor hint; boolean slots cannot identify that writer.
        if _G.EXTERNAL_ROTATION_TARGET == target then _G.EXTERNAL_ROTATION_TARGET = nil end
        if _G.BARBARIAN_FORCE_GOBLIN_TARGET == target then _G.BARBARIAN_FORCE_GOBLIN_TARGET = nil end
        target, travel, movement_lock, last_error = nil, false, false, nil
        return true
    end
    if not bridge.clear_external_target() then return false end
    travel = false
    _G.EXTERNAL_ROTATION_TRAVEL_MODE = nil
    last_error = nil
    return true
end

function bridge.fallback_attack(actor, spell_id, animation_time)
    if not lease.can_write() or actor == nil or type(spell_id) ~= "number" then
        last_error = "fallback lacks activity ownership, target or equipped spell"
        return false
    end
    local readable, dead = pcall(function() return actor:is_dead() end)
    local ready, castable = pcall(utility.can_cast_spell, spell_id)
    if not readable or dead ~= false or not ready or castable ~= true then
        last_error = "target life or equipped spell readiness is unavailable"
        return false
    end
    local ok, cast = pcall(cast_spell.target, actor, spell_id,
        animation_time or settings.FALLBACK_ANIMATION_TIME, false)
    if not ok then last_error = tostring(cast); return false end
    last_error = nil
    if cast ~= true then last_error = "host refused the equipped spell; check its target and range" end
    return cast == true
end

return bridge
