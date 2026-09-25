-- Whimsyshire objectives. The caller owns combat, pickup, recovery and movement.
local host = require("tristram.host")
local data = require("tristram.pony_data")
local exploration = require("tristram.pony_explorer")
local M = {}
local INTERACT_REACH, UNAVAILABLE_SECONDS = 2.5, 15
local function valid_id(id) return type(id) == "number" and id == id and id > 0 and id < math.huge end
function M.new(sample, time, options)
    local p = { world = sample.id, objects = {}, opened = 0, failed = 0, encountered = 0,
        last_loot = time, needs_loot = false, active = nil, paused = nil, checked_items = {},
        explorer = exploration.new(sample.position, time), detail = "Exploring Whimsyshire.", unknown_objects = {}, unknown_count = 0 }
    local approach, approach_goal, approach_reach = nil, nil, nil
    local return_path = nil
    function p.pause(now)
        if not p.paused then p.paused = now; p.explorer.suspend(now) end
        if p.active then p.active.inactive_at = nil end
        if approach then approach.suspend(now) end
        if return_path then return_path.suspend(now) end
    end
    function p.resume(now)
        if p.paused then
            local delta = now - p.paused
            for _, row in pairs(p.objects) do
                if row.next_try then row.next_try = row.next_try + delta end
                if row.missing_at then row.missing_at = row.missing_at + delta end
            end
            p.paused = nil
        end
        p.explorer.resume(now)
        -- Combat, town and checkpoint movement invalidate a cached detour path.
        approach, approach_goal, approach_reach = nil, nil, nil
        return_path = nil
    end
    function p.looted(now, origin)
        p.checked_items = {}
        for _, item in pairs(host.try(actors_manager.get_all_items) or {}) do
            local id = host.method(item, "get_id")
            if valid_id(id) and host.distance(origin, host.method(item, "get_position")) <= options.range then
                p.checked_items[id] = true -- this completed pickup pass rejected it; periodic passes reevaluate policy
            end
        end
        p.last_loot, p.needs_loot = now, false
        p.resume(now)
    end
    function p.combat(now)
        if p.paused then p.resume(now) end
        if p.active then p.active.inactive_at = nil end
        p.needs_loot = true
        p.explorer.suspend(now)
    end
    function p.approach(position, goal, now, reach)
        if not approach or host.distance(approach_goal, goal) > 1 or approach_reach ~= reach then
            -- Anchored pickup can leave two in-scope drops farther apart than
            -- one loaded local route. Reconnect through observed terrain first.
            if host.distance(position, goal) > exploration.MAX_APPROACH_DISTANCE then
                approach, p.detail = p.explorer.return_to(position, goal, now, reach, { horizontal_reach = true })
            else
                approach, p.detail = exploration.approach(position, goal, now, reach, { horizontal_reach = true })
            end
            approach_goal, approach_reach = goal, reach
        end
        if not approach then return "blocked", p.detail end
        return approach.step(position, now)
    end
    function p.return_step(position, goal, now)
        if not return_path then
            return_path, p.detail = p.explorer.return_to(position, goal, now)
        end
        if not return_path then return "blocked", p.detail end
        return return_path.step(position, now)
    end
    local function settled(row, why)
        row.done = true
        if row.attempts > 0 then
            p.opened = p.opened + 1
            p.needs_loot = true
            console.print("[TristramLoop] Pony object settled: " .. row.skin .. " actor=" .. row.id .. " (" .. why .. ").")
        end
        if p.active == row then p.active = nil; approach = nil end
    end
    local function failed(row, why)
        row.failed, p.failed = true, p.failed + 1
        p.active, approach = nil, nil
        console.print("[TristramLoop] Pony object unresolved: " .. row.skin .. " actor=" .. row.id .. ": " .. why)
    end
    function p.tick(current, now)
        if current.id ~= p.world or current.name ~= data.WORLD or current.zone ~= data.ZONE then
            return "blocked", "Pony instance changed; previous exploration is invalid."
        end
        local actors = host.actors()
        if not actors then p.pause(now); return "waiting", "Waiting for readable pony objects." end
        if p.paused then p.resume(now) end
        for _, row in pairs(p.objects) do row.visible = false end
        local unknown, presence_known = false, true
        local present_ids = {}
        -- The host may return sparse or identity-keyed actor tables.
        for _, actor in pairs(actors) do
            local skin = host.method(actor, "get_skin_name")
            local position, id = host.method(actor, "get_position"), host.method(actor, "get_id")
            local distance = host.distance(current.position, position)
            if valid_id(id) then present_ids[id] = true end
            if type(skin) ~= "string" or skin == "" or not valid_id(id) or distance == math.huge then
                presence_known, unknown = false, true
            end
            local spec = data.OBJECTS[skin]
            if not spec and type(skin) == "string" and valid_id(id) and distance <= options.range
                and host.method(actor, "is_interactable") == true and host.method(actor, "is_enemy") == false then
                local key = tostring(id) .. ":" .. skin
                if not p.unknown_objects[key] then
                    p.unknown_objects[key] = true; p.unknown_count = p.unknown_count + 1
                    console.print("[TristramLoop] Unclassified interactable (not auto-opened): " .. skin .. " actor=" .. id
                        .. " x=" .. tostring(position:x()) .. " y=" .. tostring(position:y()))
                end
            end
            if spec then
                if distance == math.huge then unknown = true
                elseif distance <= options.range then
                    if not valid_id(id) then unknown = true
                    else
                        local key = tostring(id) .. ":" .. skin
                        local row = p.objects[key]
                        local discovered = row == nil
                        if not row then
                            row = { id = id, skin = skin, kind = spec.kind, attempts = 0 }
                            p.objects[key], p.encountered = row, p.encountered + 1
                        end
                        row.actor, row.position, row.visible, row.missing_at = actor, position, true, nil
                        local usable, dead = host.method(actor, "is_interactable"), host.method(actor, "is_dead")
                        -- Schema-backed attribute string also works without an optional enum table.
                        local operated = host.method(actor, "get_attribute", "Gizmo_Has_Been_Operated")
                        row.usable = usable == true and dead == false
                        row.approachable = dead == false and type(usable) == "boolean"
                        if discovered then
                            console.print(string.format("[TristramLoop] Pony object observed: %s actor=%s distance=%.1f interactable=%s dead=%s operated=%s",
                                skin, tostring(id), distance, tostring(usable), tostring(dead), tostring(operated)))
                        end
                        if usable == true then row.inactive_at, row.inactive_elapsed = nil, 0 end
                        if not row.done and not row.failed then
                            if operated == 1 or operated == true or dead == true then settled(row, "observed operated/dead state")
                            elseif row.attempts > 0 and usable == false and distance <= INTERACT_REACH then
                                settled(row, "became noninteractable nearby after interaction")
                            elseif type(usable) ~= "boolean" or dead ~= false then unknown = true end
                        end
                    end
                end
            end
        end
        for _, row in pairs(p.objects) do
            if not presence_known then row.missing_at = nil end
            if presence_known and not present_ids[row.id] and not row.done and not row.failed and not row.visible and row.attempts > 0
                and host.distance(current.position, row.position) <= 8 then
                row.missing_at = row.missing_at or now
                if now - row.missing_at >= 1 then settled(row, "disappeared after interaction on nearby readable scans")
                else return "waiting", "Confirming nearby object disappearance before continuing." end
            end
        end
        local new_items = false
        if options.loot then
            local items = host.try(actors_manager.get_all_items)
            if type(items) ~= "table" then new_items = true
            else
                for _, item in pairs(items) do
                    local id = host.method(item, "get_id")
                    local distance = host.distance(current.position, host.method(item, "get_position"))
                    if distance == math.huge or distance <= options.range and (not valid_id(id) or not p.checked_items[id]) then new_items = true; break end
                end
            end
        end
        if not p.defer_loot and (p.needs_loot or new_items or options.loot and now - p.last_loot >= 10) then
            p.pause(now)
            return "loot", "Collecting pony drops before continuing exploration."
        end
        local row = p.active
        if row and (not row.visible or row.done or row.failed) then p.active, approach, row = nil, nil, nil end
        if not row then
            local best = math.huge
            for _, candidate in pairs(p.objects) do
                local distance = host.distance(current.position, candidate.position)
                if candidate.visible and candidate.approachable and not candidate.done and not candidate.failed
                    and distance < best then row, best = candidate, distance end
            end
            p.active = row
        end
        if row then
            -- Exploration leg timers stop while handling a detour; object timing continues.
            p.explorer.suspend(now)
            if not row.approachable then
                row.inactive_at = nil
                return "waiting", "Waiting for readable pony object life and interactability."
            end
            if row.next_try and now < row.next_try then return "waiting", "Waiting for " .. row.skin .. " to change state." end
            if row.attempts >= (row.kind == "container" and 8 or 3) then
                failed(row, "bounded attempts exhausted without an observed state change")
                return "waiting", "Continuing exploration after an unresolved object."
            end
            if host.distance(current.position, row.position) > INTERACT_REACH then
                local action, value = p.approach(current.position, row.position, now, INTERACT_REACH)
                if action == "blocked" then failed(row, tostring(value)); return "waiting", value end
                return action == "done" and "waiting" or action, value
            end
            approach = nil
            -- Initial noninteractability is not proof that an object was opened.
            -- Approach exact, living objects first, then wait for usable state.
            if not row.usable then
                local delta = row.inactive_at and math.max(0, now - row.inactive_at) or 0
                if delta <= 1 then row.inactive_elapsed = (row.inactive_elapsed or 0) + delta end
                row.inactive_at = now
                if (row.inactive_elapsed or 0) >= UNAVAILABLE_SECONDS then
                    failed(row, "remained noninteractable nearby without operated/dead evidence")
                    return "waiting", "Continuing after an unavailable pony object; it was not counted as opened."
                end
                return "waiting", "Waiting for " .. row.skin .. " to become interactable nearby."
            end
            -- Refresh identity and state immediately before issuing this exact-object action.
            if host.method(row.actor, "get_id") ~= row.id or host.method(row.actor, "get_skin_name") ~= row.skin
                or host.method(row.actor, "is_interactable") ~= true or host.method(row.actor, "is_dead") ~= false then
                return "waiting", "Waiting for a fresh pony object observation."
            end
            row.attempts, row.next_try = row.attempts + 1, now + 2
            return row.kind == "container" and row.attempts > 2 and "attack" or "interact", row.actor
        end
        if unknown then p.explorer.suspend(now); return "waiting", "Pony object data is unreadable; completion is unconfirmed." end
        p.explorer.resume(now)
        local action, value = p.explorer.step(current.position, now)
        if action == "done" then
            for _, pending in pairs(p.objects) do
                if not pending.done and not pending.failed then
                    failed(pending, "object left the readable area before its state was confirmed")
                end
            end
            if p.failed > 0 then return "incomplete", "Exploration ended with " .. p.failed .. " unresolved pony objects." end
        end
        return action, value
    end
    function p.status()
        local status = p.explorer.status()
        status.objects, status.opened, status.unresolved = p.encountered, p.opened, p.failed
        status.unknown_objects = p.unknown_count
        return status
    end
    return p
end
return M
