-- Per-instance Pony target obligations. Deferral is never a death receipt.
local host = require("tristram.host")
local M = {}
local function number(n) return type(n) == "number" and n == n and n >= 0 and n < math.huge end
function M.ready(options)
    if host.standalone_rotation() then return true end
    local ids = host.try(get_equipped_spell_ids)
    if type(ids) ~= "table" then return false end
    local slot = options.pony_attack_slot or 0
    if slot > 0 then return number(ids[slot]) and ids[slot] > 0 end
    for _, id in ipairs(ids) do if number(id) and id > 0 then return true end end
    return false
end
function M.new(options)
    local p = { rows = {}, active = nil, elapsed = 0, last = nil, deferred = 0, unresolved = 0,
        exhausted = 0, reason = "", progress_age = 0 }
    function p.pause() p.last = nil end
    function p.defer(reason)
        local row = p.active
        if not row then return end
        row.failures = row.failures + 1
        row.until_time = p.elapsed + math.min(60, 10 * row.failures)
        row.exhausted = row.failures >= 3
        row.work, row.reason = 0, reason
        p.reason, p.active = reason, nil
    end
    function p.select(sample, range, now)
        local dt = p.last and now - p.last or 0
        if dt < 0 or dt > 1 then dt = 0 end
        p.last, p.elapsed = now, p.elapsed + dt
        for _, row in pairs(p.rows) do row.visible = false end
        local actors = host.actors()
        if not actors then return nil end
        for _, actor in ipairs(actors) do
            local id, skin = host.method(actor, "get_id"), host.method(actor, "get_skin_name")
            local pos = host.method(actor, "get_position")
            if number(id) and id > 0 and type(skin) == "string" and host.method(actor, "is_enemy") == true
                and host.distance(sample.position, pos) <= range then
                local key = tostring(id) .. ":" .. skin
                local row = p.rows[key]
                if not row then
                    row = { id = id, skin = skin, failures = 0, work = 0, position = pos }
                    p.rows[key] = row
                end
                if row.until_time and not row.exhausted and host.distance(row.position, pos) > 3 then row.until_time = nil end
                row.actor, row.position, row.visible = actor, pos, true
            end
        end
        if p.active then
            local row = p.active
            local hp = host.method(row.actor, "get_current_health")
            local distance = host.distance(sample.position, row.position)
            if number(hp) and number(row.health) and hp < row.health
                or row.distance and distance < row.distance - 1 then
                row.work, row.failures = 0, 0
                row.distance = distance
            else row.work = row.work + dt end
            row.health = hp
            if row.work >= (options.pony_stall_seconds or 12) then p.defer("No observed damage or approach progress") end
        end
        local best, score
        p.deferred, p.unresolved, p.exhausted = 0, 0, 0
        for _, row in pairs(p.rows) do
            local same = host.method(row.actor, "get_id") == row.id and host.method(row.actor, "get_skin_name") == row.skin
            local dead = same and host.method(row.actor, "is_dead") == true
            if not dead then
                p.unresolved = p.unresolved + 1
                if row.exhausted then p.exhausted = p.exhausted + 1 end
                if row.exhausted or row.until_time and row.until_time > p.elapsed then p.deferred = p.deferred + 1
                elseif same and row.visible and host.method(row.actor, "is_dead") == false
                    and host.method(row.actor, "is_immune") ~= true and host.method(row.actor, "is_untargetable") ~= true then
                    local value = host.distance(sample.position, row.position)
                    if options.pony_priority == 1 then
                        if host.method(row.actor, "is_elite") == true or host.method(row.actor, "is_champion") == true then value = value - range end
                    end
                    if not best or value < score or value == score and row.id < best.id then best, score = row, value end
                end
            end
        end
        if best ~= p.active then
            if best then best.work, best.distance, best.health = 0, host.distance(sample.position, best.position), host.method(best.actor, "get_current_health") end
            p.active = best
        end
        p.progress_age = best and best.work or 0
        return best and best.actor or nil
    end
    function p.spells(ids)
        local result = {}
        if type(ids) ~= "table" or #ids == 0 then return result end
        local slot = options.pony_attack_slot or 0
        if slot > 0 then if ids[slot] then result[1] = ids[slot] end; return result end
        -- Try other equipped skills if accepted commands produce no progress.
        local offset = math.floor(p.progress_age / 2) % #ids
        for i = 1, #ids do result[i] = ids[(i + offset - 1) % #ids + 1] end
        return result
    end
    return p
end
return M
