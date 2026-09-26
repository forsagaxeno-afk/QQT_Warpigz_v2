-- Standalone, non-destructive town service. Native calls require observed receipts.
-- Temis identities/waypoint are shared corpus evidence from the installed town catalog.
local host = require("tristram.host")
local movement = require("tristram.bridge_movement")
local party = require("tristram.party")
local pony_data = require("tristram.pony_data")
local data = require("tristram.data")
local M = { ZONE = "Skov_Temis", WAYPOINT = 0x1CE51E, STASH = "Stash",
    REPAIR = "TWN_Skov_Temis_Crafter_Blacksmith", PORTAL = "TownPortal" }
local function finite(n) return type(n) == "number" and n == n and n >= 0 and n < math.huge end
local function bag(player, method)
    local list = host.method(player, method)
    if type(list) ~= "table" then return nil end
    return list
end
local function quantity(player, method, sno)
    local list, total = bag(player, method), 0
    if not list then return nil end
    for _, item in pairs(list) do
        local id, count = host.method(item, "get_sno_id"), host.method(item, "get_stack_count")
        if not finite(id) or not finite(count) then return nil end
        if id == sno then total = total + math.max(1, count) end
    end
    return total
end
function M.needs_repair(player, threshold)
    local list = bag(player, "get_equipped_items")
    if not list then return nil end
    for _, item in pairs(list) do
        local value = host.method(item, "get_durability")
        if not finite(value) then return nil end
        if value <= (threshold or 10) then return true end
    end
    return false
end
function M.available()
    return type(teleport_to_waypoint) == "function" and type(interact_object) == "function"
        and type(interact_vendor) == "function" and type(loot_manager.move_item_to_stash) == "function"
        and type(loot_manager.repair_all_items) == "function" and type(loot_manager.get_current_vendor) == "function"
end
function M.begin(origin, need_room, need_repair)
    if not M.available() then return nil, "Native town APIs are unavailable; enable configured Alfred service." end
    local t = { native = true, active = true, stage = "outbound", detail = "Teleporting to Temis for safe storage/repair.",
        next_action = 0, attempts = 0, pending = nil, need_room = need_room, need_repair = need_repair,
        origin = { id = origin.id, name = origin.name, zone = origin.zone }, visited = false,
        return_required = origin.name == pony_data.WORLD and origin.zone == pony_data.ZONE }
    local function same(s) return s and s.id == t.origin.id and s.name == t.origin.name and s.zone == t.origin.zone end
    local function stage(value) t.stage, t.attempts, t.goal, t.progress_at = value, 0, nil, nil end
    local function actor(skin, sample)
        local result, distance, count = nil, math.huge, 0
        for _, a in ipairs(host.actors() or {}) do
            if host.method(a, "get_skin_name") == skin and host.method(a, "is_interactable") == true then
                count = count + 1
                local d = host.distance(sample.position, host.method(a, "get_position"))
                if d < distance then result, distance = a, d end
            end
        end
        if skin == M.PORTAL and count ~= 1 then return nil, math.huge end
        return result, distance
    end
    local function approach(a, distance, now)
        if distance <= 3 then return movement.release() end
        local id = host.method(a, "get_id")
        if t.goal ~= id or not t.best or not t.progress_at or distance < t.best - 1 then
            t.goal, t.best, t.progress_at = id, distance, now
        end
        if now - t.progress_at > 15 then return nil, "Native town movement made no progress." end
        if movement.go_to(host.method(a, "get_position")) == false then return nil, "Native town movement was refused." end
        return false
    end
    function t.set_recovering(on)
        local now = get_time_since_inject()
        if on and not t.paused then t.paused_at = now end
        if not on and t.paused then
            local duration = math.max(0, now - t.paused_at)
            if t.pending then t.pending.at = t.pending.at + duration end
            t.next_action = t.next_action + duration
        end
        t.paused, t.progress_at = on, nil
        return movement.release()
    end
    function t.cancel() t.active = false; return movement.release() end
    function t.poll()
        local sample, now = host.sample(), get_time_since_inject()
        if not t.active then return false, "Native town request was cancelled." end
        if t.paused or not sample or sample.dead or is_chat_open() then return false end
        if t.stage == "complete" and not t.return_required and sample.zone == M.ZONE then
            return true, nil, { inventory_full = false, need_repair = M.needs_repair(sample.player) }
        end
        if t.return_required and t.visited and same(sample) then
            if t.stage ~= "return" then return false, "Town return arrived before service was verified." end
            return true, nil, { inventory_full = false, need_repair = M.needs_repair(sample.player) }
        end
        if sample.zone == M.ZONE then
            t.visited = true
            if t.stage == "outbound" then stage(t.need_room and "stash" or "repair") end
        elseif t.stage ~= "outbound" and t.stage ~= "return" or not same(sample) and not t.visited then
            return false, "Native town service reached an unexpected destination."
        end
        if now < t.next_action then return false end
        t.next_action = now + 1
        if t.stage == "outbound" then
            if t.attempts >= 3 then return false, "Town teleport did not produce observed arrival." end
            t.attempts = t.attempts + 1; t.next_action = now + 10
            host.try(teleport_to_waypoint, M.WAYPOINT)
            return false
        end
        if sample.zone ~= M.ZONE then return false, "Return portal reached a different farming instance." end
        if t.stage == "close" then
            t.detail = "Closing the town vendor before returning."
            if host.try(loot_manager.is_in_vendor_screen) == true or is_inventory_open() then
                if t.attempts >= 3 then return false, "Town vendor did not close." end
                t.attempts = t.attempts + 1; party.close_vendor(); return false
            end
            local next_stage = t.after_close or (t.return_required and "return" or "complete")
            t.after_close = nil; stage(next_stage); return false
        end
        local skin = t.stage == "stash" and M.STASH or t.stage == "repair" and M.REPAIR or M.PORTAL
        local a, distance = actor(skin, sample)
        t.detail = "Native town: " .. t.stage .. "; waiting for observed completion."
        if not a then return false end -- outer service timeout bounds absent/ambiguous actors
        local arrived, why = approach(a, distance, now)
        if why then return false, why end
        if not arrived then return false end
        if t.stage == "return" then
            if t.attempts >= 3 then return false, "Return portal did not produce same-instance arrival." end
            t.attempts = t.attempts + 1; t.next_action = now + 5
            host.try(interact_object, a); return false
        end
        local vendor = host.try(loot_manager.get_current_vendor)
        if host.try(loot_manager.is_in_vendor_screen) ~= true or host.method(vendor, "get_id") ~= host.method(a, "get_id")
            or host.method(vendor, "get_skin_name") ~= skin then
            if t.attempts >= 3 then return false, "Expected town vendor did not open." end
            t.attempts = t.attempts + 1
            host.try(t.stage == "stash" and interact_object or interact_vendor, a); return false
        end
        if t.stage == "repair" then
            local need = M.needs_repair(sample.player, 94)
            if need == nil then return false, "Equipped durability is unreadable." end
            if not need then stage("close"); return false end
            if t.attempts >= 6 then return false, "Repair did not improve observed equipment durability." end
            t.attempts = t.attempts + 1; host.try(loot_manager.repair_all_items); return false
        end
        if t.pending then
            local from = quantity(sample.player, "get_inventory_items", t.pending.sno)
            local to = quantity(sample.player, "get_stash_items", t.pending.sno)
            if from and to and from < t.pending.from and to > t.pending.to then t.pending = nil; t.attempts = 0
            elseif now - t.pending.at > 8 then return false, "Stash transfer unconfirmed or stash full; carried items preserved."
            else return false end
        end
        local items = bag(sample.player, "get_inventory_items")
        if not items then return false, "Inventory is unreadable." end
        local item
        for _, value in pairs(items) do
            -- Keep favorites/locked items with the character. No salvage or sell.
            if host.method(value, "is_locked") == false then item = value; break end
        end
        if not item then
            local count = host.method(sample.player, "get_item_count")
            if not finite(count) or count >= data.INVENTORY_CAPACITY then return false, "No movable gear left; inventory still full." end
            t.after_close = t.need_repair and "repair" or nil
            stage("close"); return false
        end
        local sno = host.method(item, "get_sno_id")
        local from, to = quantity(sample.player, "get_inventory_items", sno), quantity(sample.player, "get_stash_items", sno)
        if not finite(sno) or not from or not to then return false, "Stash quantities are unreadable." end
        t.pending = { sno = sno, from = from, to = to, at = now }
        host.try(loot_manager.move_item_to_stash, item)
        return false
    end
    return t
end
return M
