-- QQT_Warpigz_v2 local patch (Rosie 1.0.8, 2.3.0-rc.11): plain Uniques Rosie
-- dropped on purpose ("Pick up every Unique", mode "Drop on the ground").
-- Pickup must never take them again, or Rosie would carry the same item back
-- and forth.
--  * Fingerprint: the SNO plus the sorted "hash:roll" list of the bag copy's
--    affixes (rolls to 3 decimals). Live dumps (Leoric's Crown, Condemnation):
--    once an item was picked up, its re-dropped ground copy lists its affixes.
--  * Position fallback, only for a dropped copy that lists no affixes: when
--    Rosie records an item it notes every same-SNO ground item already near
--    the spot; within BIND_WINDOW s it binds the entry to the first NEW
--    same-SNO ground item within FALLBACK_RADIUS m that lists no affixes (the
--    nearest to the spot) and from then on refuses only that one actor, for
--    at most FALLBACK_WINDOW s. A fresh drop that lands later, or that was
--    already on the ground, is never refused. Once any dropped copy was seen
--    listing its affixes (fingerprint match), the host is known to list them
--    and the fallback is off for the session.
--  * The host item identifier is recorded for diagnostics only (whether it
--    survives a drop is unknown); the fingerprint match or the bound copy
--    logs once per entry whether it matched.
--  * Entries expire after TTL s and at most CAP are kept (oldest first out).
--    Each entry belongs to the world it was recorded in. The list is cleared
--    when a different world is entered; town, Limbo and the loading screen do
--    not count, so a town trip out of a Pit and back keeps it.
--  * A Mythic is never recorded, and a ground reading that is a definite
--    Mythic (rarity 8+, S14 iconic SNO, the Mythic upgrade affix) is never
--    refused.
local MythicForm = require('rosie.private.mythic_form')
local M = {}
M.TTL = 30 * 60
M.CAP = 200
M.FALLBACK_RADIUS = 4
M.FALLBACK_WINDOW = 15 * 60
M.BIND_WINDOW = 5
M.REASON = 'dropped by Rosie (plain Unique)'

local entries = {}      -- oldest first
local by_sno = {}       -- sno -> count of live entries
local field_world = nil -- the last non-town, non-loading world key
local cleared = 0
local affixes_on_drop = false -- a dropped copy was seen listing its affixes

local function call(obj, name, ...)
    if obj == nil then return nil end
    local ok, fn = pcall(function() return obj[name] end)
    if not ok or type(fn) ~= 'function' then return nil end
    local ok2, v = pcall(fn, obj, ...)
    if ok2 then return v end
    return nil
end
local function now() return get_time_since_inject() end
local function number(v) return type(v) == 'number' and v == v and v > -math.huge and v < math.huge end

-- The world key (id|name) and whether it is transient: loading, Limbo or a
-- town (the game's in-town attribute).
local function world_state()
    local ok, key, transient = pcall(function()
        local w = get_current_world()
        if not w then return nil end
        local name = w:get_name()
        local zone = call(w, 'get_current_zone_name')
        local k = tostring(w:get_world_id()) .. '|' .. tostring(name)
        if zone == nil or zone == '[sno none]' or name == 'Limbo' then return k, true end
        local attrs = rawget(_G, 'attributes')
        local player = get_local_player()
        if type(attrs) == 'table' and attrs.PLAYER_IN_TOWN_LEVEL_AREA ~= nil and player
            and call(player, 'get_attribute', attrs.PLAYER_IN_TOWN_LEVEL_AREA) == 1 then return k, true end
        return k, false
    end)
    if not ok then return nil, true end
    return key, transient
end
local function rebuild_index()
    by_sno = {}
    for _, e in ipairs(entries) do by_sno[e.sno] = (by_sno[e.sno] or 0) + 1 end
end
function M.clear()
    entries, by_sno = {}, {}
    cleared = cleared + 1
end
-- Changes every time the list is cleared (a world change).
function M.generation() return cleared end
-- Clears every entry when a different world is entered. Unreadable worlds,
-- loading screens, Limbo and towns never count as a change.
function M.sync_world()
    local key, transient = world_state()
    if key == nil or transient then return end
    if field_world ~= nil and key ~= field_world and #entries > 0 then M.clear() end
    field_world = key
end
-- Rebuilds the list only when an entry actually expired.
local function prune(t)
    local expired = false
    for _, e in ipairs(entries) do
        if t - e.at >= M.TTL or t < e.at then expired = true; break end
    end
    if not expired then return end
    local kept = {}
    for _, e in ipairs(entries) do
        if t - e.at < M.TTL and t >= e.at then kept[#kept + 1] = e end
    end
    entries = kept; rebuild_index()
end

local function affix_roll(affix)
    local ok, roll = pcall(function()
        if type(affix.get_roll) == 'function' then return affix:get_roll() end
        return affix.roll
    end)
    return ok and number(roll) and roll or nil
end
local function affix_key(affix)
    local ok, hash = pcall(function() return affix.affix_name_hash end)
    local id = ok and number(hash) and (hash == math.floor(hash) and string.format('%.0f', hash) or tostring(hash)) or nil
    if not id then
        local okn, name = pcall(function()
            if type(affix.get_name) == 'function' then return affix:get_name() end
            return affix.name
        end)
        id = okn and type(name) == 'string' and name or '?'
    end
    local roll = affix_roll(affix)
    return id .. ':' .. (roll and string.format('%.3f', roll) or '-')
end
-- sno, fingerprint text, affix count. The fingerprint is nil when the affix
-- list cannot be read or lists nothing (count nil = unreadable).
function M.fingerprint(obj)
    local sno = call(obj, 'get_sno_id')
    if not number(sno) then return nil, nil, nil end
    local affixes = call(obj, 'get_affixes')
    if type(affixes) ~= 'table' then return sno, nil, nil end
    local keys = {}
    for _, affix in pairs(affixes) do
        if affix ~= nil then keys[#keys + 1] = affix_key(affix) end
    end
    if #keys == 0 then return sno, nil, 0 end
    table.sort(keys)
    return sno, tostring(sno) .. '#' .. table.concat(keys, ','), #keys
end

-- A definite Mythic reading (keep direction only).
function M.is_definite_mythic(obj)
    local rarity = call(obj, 'get_rarity')
    local sno = call(obj, 'get_sno_id')
    if number(rarity) and rarity >= 8 then return true end
    if MythicForm.is_mythic_sno(sno) then return true end
    local ok, marked = pcall(MythicForm.has_mark, obj)
    return ok and marked == true
end

local function identifier(obj)
    local lm = rawget(_G, 'loot_manager')
    if type(lm) ~= 'table' or type(lm.get_item_identifier) ~= 'function' then return nil end
    local ok, id = pcall(lm.get_item_identifier, obj)
    if ok and (type(id) == 'number' or type(id) == 'string') then return id end
    return nil
end
local function xyz(pos)
    if pos == nil then return nil end
    local x, y, z = call(pos, 'x'), call(pos, 'y'), call(pos, 'z')
    if not number(x) or not number(y) then return nil end
    return {x = x, y = y, z = number(z) and z or 0}
end
-- A ground actor's key, as pickup keys it (Pickup.key): the host identifier,
-- else SNO plus position.
local function ground_key(g, info)
    local id = identifier(g)
    if type(id) == 'number' and id > 0 then return tostring(id) end
    local sno = call(info, 'get_sno_id')
    local p = xyz(call(g, 'get_position'))
    if not number(sno) or not p then return nil end
    return tostring(sno) .. ':' .. string.format('%.1f:%.1f:%.1f', p.x, p.y, p.z)
end
local function near(p, e)
    if not p or not e.pos then return false, nil end
    local dx, dy = p.x - e.pos.x, p.y - e.pos.y
    local d2 = dx * dx + dy * dy
    return d2 <= M.FALLBACK_RADIUS * M.FALLBACK_RADIUS, d2
end
local function ground_items()
    local am = rawget(_G, 'actors_manager')
    if type(am) ~= 'table' or type(am.get_all_items) ~= 'function' then return nil end
    local ok, items = pcall(am.get_all_items)
    return ok and type(items) == 'table' and items or nil
end
-- The same-SNO ground items already near the spot (never bound later).
local function snapshot(sno, e)
    local snap = {}
    for _, g in pairs(ground_items() or {}) do
        local info = call(g, 'get_item_info') or g
        if call(info, 'get_sno_id') == sno and near(xyz(call(g, 'get_position')), e) then
            local k = ground_key(g, info)
            if k then snap[k] = true end
        end
    end
    return snap
end

-- Records a bag item before Rosie drops it. `pos` is where it will land
-- (the player's position). Returns the entry, or nil (Mythic, unreadable
-- item, or no affixes listed: such an item is never dropped).
function M.record(item, pos, name)
    M.sync_world()
    if M.is_definite_mythic(item) then return nil end
    local sno, fp = M.fingerprint(item)
    if not sno or not fp then return nil end
    local t = now()
    prune(t)
    for _, e in ipairs(entries) do
        -- A retry: the bind window restarts, the first snapshot is kept.
        if e.fp == fp then
            e.at = t; e.pos = xyz(pos) or e.pos; e.id = identifier(item) or e.id
            if not e.bound and not e.fp_seen then e.armed = true end
            return e
        end
    end
    local e = {sno = sno, fp = fp, at = t, pos = xyz(pos), id = identifier(item), name = name, id_logged = false,
        world = (world_state()), armed = true}
    e.snap = snapshot(sno, e)
    entries[#entries + 1] = e
    by_sno[sno] = (by_sno[sno] or 0) + 1
    while #entries > M.CAP do
        local old = table.remove(entries, 1)
        by_sno[old.sno] = (by_sno[old.sno] or 1) - 1
        if by_sno[old.sno] <= 0 then by_sno[old.sno] = nil end
    end
    return e
end
-- An entry whose item never left the bag: forget it (no false refusals).
function M.forget(fp)
    local kept = {}
    for _, e in ipairs(entries) do if e.fp ~= fp then kept[#kept + 1] = e end end
    if #kept ~= #entries then entries = kept; rebuild_index() end
end
function M.count() return #entries end
function M.entries()
    local out = {}
    for i, e in ipairs(entries) do
        out[i] = {sno = e.sno, fp = e.fp, at = e.at, id = e.id, name = e.name, world = e.world,
            bound = e.bound, fp_seen = e.fp_seen == true, armed = e.armed == true}
    end
    return out
end
-- True once a dropped copy was seen listing its affixes (fallback off).
function M.fallback_off() return affixes_on_drop end

local function log_identifier(e, ground, how)
    if e.id_logged then return end
    e.id_logged = true
    local gid = identifier(ground)
    console.print(string.format('[Rosie sort] Ground copy of %s found by %s: identifier bag=%s ground=%s matched=%s',
        tostring(e.name or e.sno), how, tostring(e.id), tostring(gid), tostring(e.id ~= nil and gid ~= nil and e.id == gid)))
end
local function seen_by_fingerprint(e, ground)
    e.fp_seen, e.armed = true, false
    affixes_on_drop = true
    log_identifier(e, ground, 'fingerprint')
end
-- Within the bind window: find this entry's dropped copy among the NEW
-- same-SNO ground items near the spot. A copy listing the fingerprint
-- disarms the fallback; else the nearest new copy listing no affixes is bound.
local function bind(e, t)
    if not e.armed then return end
    if affixes_on_drop or e.bound or e.fp_seen or t - e.at > M.BIND_WINDOW or t < e.at then e.armed = false; return end
    -- One ground scan per entry and frame (pickup evaluates every drop).
    if e.scan_at == t then return end
    e.scan_at = t
    local best, best_d, best_key
    for _, g in pairs(ground_items() or {}) do
        local info = call(g, 'get_item_info') or g
        if call(info, 'get_sno_id') == e.sno then
            local inside, d2 = near(xyz(call(g, 'get_position')), e)
            local k = inside and ground_key(g, info) or nil
            if k and not (e.snap and e.snap[k]) then
                local _, fp = M.fingerprint(info)
                if fp == e.fp then seen_by_fingerprint(e, g); return end
                if fp == nil and not M.is_definite_mythic(info) and (not best or d2 < best_d) then
                    best, best_d, best_key = g, d2, k
                end
            end
        end
    end
    if best then
        e.bound, e.armed = best_key, false
        log_identifier(e, best, 'position')
    end
end
-- Binds pending entries (the sorter calls it every step while one is armed).
function M.observe()
    if #entries == 0 then return end
    local t = nil
    for _, e in ipairs(entries) do
        if e.armed then t = t or now(); bind(e, t) end
    end
end
-- A ground item (or its info) Rosie dropped: true plus the reason.
function M.match(ground, info)
    if #entries == 0 then return false end
    info = info or ground
    local sno = call(info, 'get_sno_id')
    if not number(sno) or by_sno[sno] == nil then return false end
    M.sync_world()
    local t = now()
    prune(t)
    if by_sno[sno] == nil then return false end
    if M.is_definite_mythic(info) then return false end
    local world = world_state()
    local _, fp = M.fingerprint(info)
    if fp then
        for _, e in ipairs(entries) do
            if e.fp == fp and (world == nil or e.world == nil or e.world == world) then
                if not e.fp_seen then seen_by_fingerprint(e, ground) end
                return true, M.REASON
            end
        end
        return false
    end
    local k = nil
    for _, e in ipairs(entries) do
        if e.sno == sno and (world == nil or e.world == nil or e.world == world) then
            if e.armed then bind(e, t) end
            if e.bound and t - e.at <= M.FALLBACK_WINDOW then
                k = k or ground_key(ground, info)
                if k == e.bound then return true, M.REASON end
            end
        end
    end
    return false
end
return M
