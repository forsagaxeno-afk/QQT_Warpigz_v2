local host = require("tristram.host")
local data = require("tristram.data")
local M = {}
function M.new()
    local e = { seen = {}, killed = {}, credited = {}, current = {}, seen_count = 0, unresolved = 0,
        bosses = 0, alive = 0, target = nil, empty_at = nil, known = false, progress = "Waiting for boss observations." }
    function e.scan(sample, arena, range, now)
        local actors = host.actors()
        e.known = actors ~= nil
        e.target, e.alive = nil, 0
        if not actors then e.empty_at = nil; e.progress = "Actor list unreadable; waiting for a fresh scan."; return end
        if not e.world then e.world = { id = sample.id, name = sample.name, zone = sample.zone } end
        if sample.id ~= e.world.id or sample.name ~= e.world.name or sample.zone ~= e.world.zone then
            e.known, e.empty_at = false, nil
            e.progress = "Encounter belongs to another instance."
            return
        end
        for _, observed in pairs(e.seen) do observed.visible = false end
        local center = vec3:new(arena.x, arena.y, arena.z)
        local best = math.huge
        local unreadable = nil
        for _, actor in ipairs(actors) do
            local position = host.method(actor, "get_position")
            local id = host.method(actor, "get_id")
            local skin = host.method(actor, "get_skin_name")
            local observed = id and e.seen[id]
            if observed and observed.skin == skin then observed.actor, observed.visible = actor, true end
            local arena_distance = host.distance(center, position)
            local enemy = host.method(actor, "is_enemy")
            if arena_distance == math.huge and enemy ~= false then
                e.known, unreadable = false, "actor position unreadable (id=" .. tostring(id) .. ")"
            elseif arena_distance <= range and type(enemy) ~= "boolean" then
                e.known, unreadable = false, "enemy classification unreadable (id=" .. tostring(id) .. ")"
            end
            if arena_distance <= range and enemy == true then
                local dead = host.method(actor, "is_dead")
                if type(dead) ~= "boolean" then e.known = false; unreadable = "enemy life state unreadable (id=" .. tostring(id) .. ")" end
                if dead == false then
                    e.alive = e.alive + 1
                    if host.method(actor, "is_boss") == true and data.BOSS_SLOTS[skin] ~= nil
                        and type(id) == "number" and id == id and not observed then
                        local slot = data.BOSS_SLOTS[skin]
                        if e.current[slot] == nil then e.seen_count = e.seen_count + 1 end
                        e.seen[id] = { actor = actor, skin = skin, slot = slot, visible = true }
                        e.current[slot] = id
                        console.print("[TristramLoop] Boss observed alive: " .. tostring(skin) .. " actor_id=" .. id)
                    end
                    local distance = host.distance(sample.position, position)
                    if distance < best and host.method(actor, "is_untargetable") ~= true
                        and host.method(actor, "is_immune") ~= true then e.target = actor; best = distance end
                end
            end
        end
        -- Corpses can leave the enemy list or lose their enemy flag before the next
        -- scan. Retain the observed handle, but require explicit death and matching
        -- identity; a disappeared/expired/reused handle is never a death.
        for id, observed in pairs(e.seen) do
            local same = host.method(observed.actor, "get_id") == id
                and host.method(observed.actor, "get_skin_name") == observed.skin
            local dead = same and host.method(observed.actor, "is_dead")
            if dead == true then
                observed.state = "dead"
                if not e.killed[id] then
                    e.killed[id] = true
                    if not e.credited[observed.slot] then
                        e.credited[observed.slot] = true
                        e.bosses = e.bosses + 1
                        console.print(string.format("[TristramLoop] Boss deaths observed: %d/3 (%s actor_id=%s).",
                            e.bosses, tostring(observed.skin), tostring(id)))
                    end
                end
            elseif not same then observed.state = "identity unavailable"
            elseif dead ~= false then observed.state = "life state unreadable"
            elseif not observed.visible then observed.state = "missing from scan; death unconfirmed"
            elseif host.method(observed.actor, "is_immune") == true then observed.state = "alive, immune"
            elseif host.method(observed.actor, "is_untargetable") == true then observed.state = "alive, untargetable"
            else observed.state = "alive" end
        end
        local unresolved = {}
        for _, id in pairs(e.current) do
            if not e.killed[id] then
                local observed = e.seen[id]
                unresolved[#unresolved + 1] = tostring(observed.skin) .. " actor=" .. id .. " " .. observed.state
            end
        end
        table.sort(unresolved)
        e.unresolved = #unresolved
        e.progress = string.format("Boss deaths %d/3; alive enemies %d; observed bosses %d. %s",
            e.bosses, e.alive, e.seen_count, table.concat(unresolved, "; "))
        if unreadable then e.progress = e.progress .. " Scan incomplete: " .. unreadable .. "." end
        if not e.known or e.alive > 0 then e.empty_at = nil
        elseif not e.empty_at then e.empty_at = now end
    end
    function e.complete(now)
        return e.known and e.bosses >= 3 and e.unresolved == 0 and e.alive == 0 and e.empty_at ~= nil and now - e.empty_at >= 5
    end
    return e
end
return M
