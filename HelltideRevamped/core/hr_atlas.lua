-- QQT_Warpigz_v3: learned chest atlas (world coordinates, own sightings).
--
-- No public API gives Helltide chest positions in world coordinates, so the
-- plugin learns them: every Helltide chest actor it sees becomes a spot of
-- its zone (a 3 m cell per chest type; sightings within 4 m merge). After a
-- few sessions the chest order can route to likely chests (predicted()) the
-- player has not seen yet this time, instead of exploring blindly.
--
--   seen   distinct reset slots the chest was seen in (capped at 999)
--   miss   visits of a predicted spot without a chest (capped at 999)
--   exit   the patrol-loop index the last successful trip left the road at
--
-- One file per zone, learned/<zone>.txt, loaded when the zone is entered and
-- saved (only when changed) on a zone change, at the Helltide's end and every
-- 5 minutes. Other modules add their own lines to the same file through
-- register_section() (hr_fence: in/out cells, hr_roads: bad cells). Lines are
-- parsed with patterns (never loadstring); malformed ones are skipped.
local clock = require "core.hr_clock"
local store = require "core.hr_store"
local enums = require "data.enums"
local settings = require "core.settings"
local chest_targets = require "core.chest_targets"
local tracker = require "core.tracker"

local M = {
    MAX_SPOTS = 200,
    MERGE_M = 4,
    CELL = 3,
    CAP = 999,
    MIN_SEEN = 2,
    MIN_CONF = 0.34,
    SCAN_EVERY = 2,
    ZONE_EVERY = 2,
    SAVE_EVERY = 300,
    REOPEN_GRACE = 30,
    MYSTERY = 'usz_rewardGizmo_Uber',
}

local zones = {}        -- key -> {spots = {}, dirty = false, loaded = false}
local sections = {}     -- prefix -> {parse = fn(zone, parts), lines = fn(zone, out), clear = fn(zone)}
local section_list = {}
local current = nil     -- current zone key
local st = {zone_at = nil, scan_at = nil, save_at = nil, hour = nil}
M.reset_seen_at = nil   -- a spot we opened this slot was seen closed again (a chest reset)

local floor, sqrt = math.floor, math.sqrt

local function learn_on() return settings.learn ~= false end

-- The learned-data key of a host zone name: the helltide_tps entry of its
-- region (one patrol loop, one file), else the sanitised zone name.
function M.zone_key(zone_name)
    if type(zone_name) ~= 'string' or zone_name == '' then return nil end
    for _, tp in ipairs(enums.helltide_tps) do
        if zone_name:sub(1, #tp.region) == tp.region then return tp.name end
    end
    local key = zone_name:gsub('[^%w_]', '_'):sub(1, 48)
    if key == '' or key == 'stats' then key = 'zone_' .. key end
    return key
end

function M.current_zone() return current end

function M.register_section(prefixes, handlers)
    for _, prefix in ipairs(prefixes) do sections[prefix] = handlers end
    section_list[#section_list + 1] = handlers
end

local function zone_data(key)
    local z = zones[key]
    if not z then
        z = {spots = {}, dirty = false, loaded = false, key = key}
        zones[key] = z
    end
    return z
end

local function spot_type(name)
    return name == M.MYSTERY and 'mystery' or 'regular'
end

local function d2(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return sqrt(dx * dx + dy * dy)
end

local function find_spot(z, kind, x, y)
    local best, best_d = nil, M.MERGE_M
    for _, spot in ipairs(z.spots) do
        if spot.type == kind then
            local d = d2(spot.x, spot.y, x, y)
            if d <= best_d then best, best_d = spot, d end
        end
    end
    return best
end

local function evict(z)
    local worst_i, worst
    for i, spot in ipairs(z.spots) do
        if not worst or (spot.seen - spot.miss) < (worst.seen - worst.miss)
            or ((spot.seen - spot.miss) == (worst.seen - worst.miss) and (spot.last_hour or 0) < (worst.last_hour or 0)) then
            worst_i, worst = i, spot
        end
    end
    if worst_i then table.remove(z.spots, worst_i) end
end

local function new_spot(z, kind, name, cost, x, y, zz)
    if #z.spots >= M.MAX_SPOTS then evict(z) end
    local spot = {type = kind, name = name, cost = cost, x = x, y = y, z = zz, seen = 0, miss = 0,
        last_hour = 0, exit_idx = nil}
    z.spots[#z.spots + 1] = spot
    return spot
end

local function xyz(pos)
    local ok, x, y, z = pcall(function() return pos:x(), pos:y(), pos:z() end)
    if not ok or type(x) ~= 'number' or type(y) ~= 'number' or x ~= x or y ~= y then return nil end
    return x, y, (type(z) == 'number' and z == z) and z or 0
end
M.xyz = xyz

-- ── load / save ──────────────────────────────────────────────────────────
local function file_of(key) return 'learned/' .. key .. '.txt' end

local function parse_spot(z, parts)
    -- v1|spot|type|name|cost|x|y|z|seen|miss|last_hour|exit_idx
    if #parts ~= 12 then return end
    local kind, name = parts[3], parts[4]
    if kind ~= 'mystery' and kind ~= 'regular' then return end
    local cost = enums.chest_types[name]
    if not cost or spot_type(name) ~= kind then return end
    local x, y, zz = tonumber(parts[6]), tonumber(parts[7]), tonumber(parts[8])
    local seen, miss, hour, exit = tonumber(parts[9]), tonumber(parts[10]), tonumber(parts[11]), tonumber(parts[12])
    if not (x and y and zz and seen and miss and hour and exit) then return end
    if x ~= x or y ~= y or zz ~= zz or math.abs(x) > 1e5 or math.abs(y) > 1e5 or math.abs(zz) > 1e5 then return end
    if #z.spots >= M.MAX_SPOTS or find_spot(z, kind, x, y) then return end
    local spot = new_spot(z, kind, name, cost, x, y, zz)
    spot.seen = math.max(0, math.min(M.CAP, floor(seen)))
    spot.miss = math.max(0, math.min(M.CAP, floor(miss)))
    spot.last_hour = math.max(0, floor(hour))
    if exit > 0 then spot.exit_idx = floor(exit) end
end

local function split(line)
    local parts = {}
    for part in (line .. '|'):gmatch('([^|]*)|') do parts[#parts + 1] = part end
    return parts
end

function M.load_zone(key)
    local z = zone_data(key)
    if z.loaded then return z end
    z.loaded = true
    local lines, why = store.read_lines(file_of(key), 12000)
    if not lines then
        -- A file that exists but cannot be read now (locked, too large) is
        -- never overwritten with this session's data alone.
        if why == 'unreadable' then
            z.read_failed = true
            pcall(function() console.print('[HelltideRevamped] ' .. file_of(key) .. ' cannot be read — not saved this session') end)
        end
        return z
    end
    for _, line in ipairs(lines) do
        local parts = split(line)
        if parts[1] == 'v1' and parts[2] == 'spot' then
            parse_spot(z, parts)
        else
            local handler = sections[parts[1]]
            if handler and handler.parse then pcall(handler.parse, key, parts) end
        end
    end
    return z
end

function M.save_zone(key)
    key = key or current
    if not key then return false end
    local z = zones[key]
    if not z or not z.loaded then return false end
    local any_dirty = z.dirty
    for _, handler in ipairs(section_list) do
        if handler.dirty and handler.dirty(key) then any_dirty = true end
    end
    if not any_dirty then return false end
    -- Storage off (no plugin folder) or given up for this file: keep the
    -- changes (dirty) without building the text.
    if not store.root() or store.failed[file_of(key)] or z.read_failed then return false end
    local out = {'v1|zone|' .. key .. '\n'}
    for _, s in ipairs(z.spots) do
        out[#out + 1] = string.format('v1|spot|%s|%s|%d|%.1f|%.1f|%.1f|%d|%d|%d|%d\n', s.type, s.name, s.cost,
            s.x, s.y, s.z, s.seen, s.miss, s.last_hour or 0, s.exit_idx or 0)
    end
    for _, handler in ipairs(section_list) do
        if handler.lines then pcall(handler.lines, key, out) end
    end
    local ok = store.write(file_of(key), out)
    if ok then -- a failed write keeps the changes for the next save
        z.dirty = false
        for _, handler in ipairs(section_list) do
            if handler.saved then pcall(handler.saved, key) end
        end
    end
    return ok
end

-- ── learning ─────────────────────────────────────────────────────────────
function M.observe(name, cost, pos, interactable)
    if not learn_on() or not current then return nil end
    local x, y, zz = xyz(pos)
    if not x or not enums.chest_types[name] then return nil end
    local z = M.load_zone(current)
    local kind = spot_type(name)
    local spot = find_spot(z, kind, x, y) or new_spot(z, kind, name, cost, x, y, zz)
    spot.name, spot.cost = name, cost
    local slot = clock.slot_id()
    if spot.seen_slot ~= slot then
        spot.seen_slot = slot
        spot.seen = math.min(M.CAP, spot.seen + 1)
        spot.last_hour = clock.hour_id()
        z.dirty = true
    end
    if interactable then
        spot.live_slot = slot
        -- QQT_Warpigz_v3 (night review): resets happen at the slot
        -- boundaries, so a chest opened at :10 and seen closed again at :16
        -- was never counted (only a same-slot re-close was). Opened in an
        -- earlier slot of this hour and closed again now: a respawn (the slot
        -- crossing already reported the reset; no reset_seen_at here).
        if spot.opened_slot and spot.opened_slot ~= slot and spot.opened_at then
            local now = tonumber(get_time_since_inject()) or 0
            if now - spot.opened_at >= M.REOPEN_GRACE or now < spot.opened_at then
                if spot.opened_hour == clock.hour_id() then spot.respawns = (spot.respawns or 0) + 1 end
                spot.opened_slot, spot.opened_at, spot.opened_hour = nil, nil, nil
                if spot.used_slot ~= slot then spot.used_slot = nil end
            end
        end
        if spot.used_slot == slot then
            local now = tonumber(get_time_since_inject()) or 0
            if spot.opened_slot == slot and spot.opened_at then
                -- A chest we opened this slot is closed again: the chests
                -- were reset (seen after a grace; is_interactable can lag).
                if now - spot.opened_at >= M.REOPEN_GRACE then
                    spot.opened_slot, spot.opened_at, spot.used_slot = nil, nil, nil
                    spot.respawns = (spot.respawns or 0) + 1
                    M.reset_seen_at = now
                end
            else
                spot.used_slot = nil
            end
        end
    else
        spot.used_slot = slot -- opened (by us earlier, or already spent)
    end
    return spot
end

local function spot_at(pos, name)
    if not current then return nil end
    local x, y = xyz(pos)
    if not x then return nil end
    local z = M.load_zone(current)
    if name then return find_spot(z, spot_type(name), x, y) end
    return find_spot(z, 'mystery', x, y) or find_spot(z, 'regular', x, y)
end
M.spot_at = spot_at

function M.mark_opened(pos, name)
    if not current then return nil end
    local spot = spot_at(pos, name)
    if not spot and name and enums.chest_types[name] and learn_on() then
        spot = M.observe(name, enums.chest_types[name], pos, false)
    end
    if not spot then return nil end
    spot.opened_slot = clock.slot_id()
    spot.opened_hour = clock.hour_id()
    spot.opened_at = get_time_since_inject()
    spot.used_slot = spot.opened_slot
    return spot
end

-- A predicted spot visited without a chest.
function M.mark_miss(spot_or_pos)
    local spot = spot_or_pos
    if type(spot) ~= 'table' or spot.type == nil then spot = spot_at(spot_or_pos) end
    if not spot then return nil end
    local slot = clock.slot_id()
    spot.miss_slot = slot
    if learn_on() and spot.counted_miss_slot ~= slot then
        spot.counted_miss_slot = slot
        spot.miss = math.min(M.CAP, spot.miss + 1)
        local z = current and zones[current]
        if z then z.dirty = true end
    end
    return spot
end

function M.set_exit(pos, exit_idx, name)
    if not learn_on() or type(exit_idx) ~= 'number' then return nil end
    local spot = spot_at(pos, name)
    if not spot then return nil end
    if spot.exit_idx ~= exit_idx then
        spot.exit_idx = exit_idx
        local z = current and zones[current]
        if z then z.dirty = true end
    end
    return spot
end

function M.confidence(spot)
    local total = spot.seen + spot.miss
    if total <= 0 then return 0 end
    return spot.seen / total
end

-- Likely chests of the current zone that are not known spent this slot.
-- filter(spot) -> false drops a spot (fence, bad cells).
function M.predicted(filter)
    local out = {}
    if not current then return out end
    local z = M.load_zone(current)
    local slot, hour = clock.slot_id(), clock.hour_id()
    for _, spot in ipairs(z.spots) do
        -- A Mystery chest we opened this hour counts as gone for the hour
        -- until that spot was once seen closed again (respawn unconfirmed).
        local gone_for_hour = spot.type == 'mystery' and spot.opened_hour == hour and (spot.respawns or 0) == 0
        if spot.seen >= M.MIN_SEEN and M.confidence(spot) >= M.MIN_CONF and not gone_for_hour
            and spot.opened_slot ~= slot and spot.used_slot ~= slot and spot.miss_slot ~= slot
            and spot.live_slot ~= slot -- seen this slot: the actor list has it (visible/remembered)
            and (not filter or filter(spot) ~= false) then
            out[#out + 1] = spot
        end
    end
    return out
end

function M.spots(key)
    local z = zones[key or current or '']
    return z and z.spots or {}
end

function M.forget(key)
    key = key or current
    if not key then return false end
    local z = zone_data(key)
    -- An explicit Forget replaces even a file that could not be read.
    z.spots, z.loaded, z.dirty, z.read_failed = {}, true, true, nil
    for _, handler in ipairs(section_list) do
        if handler.clear then pcall(handler.clear, key) end
    end
    M.save_zone(key)
    return true
end

-- ── tick (main.lua, while enabled) ───────────────────────────────────────
local function read_zone()
    local ok, name = pcall(function()
        local world = get_current_world()
        return world and world:get_current_zone_name()
    end)
    if ok then return name end
    return nil
end

function M.set_zone(key)
    if key == current then return end
    if current then M.save_zone(current) end
    current = key
    if key then M.load_zone(key) end
end

-- The Helltide chests of an actor snapshot: {actor, skin, position,
-- interactable, name, cost} (chest_targets.read + classify). Cached for the
-- snapshot table (tasks/helltide.lua refreshes it once a second), so the
-- atlas and the chest order read and classify every actor once. Read-only.
local snap_src, snap_list = nil, {}
function M.classified(actors)
    if type(actors) ~= 'table' then return {} end
    if actors == snap_src then return snap_list end
    local list = {}
    for _, actor in pairs(actors) do
        local entry = chest_targets.read(actor)
        if entry then
            local name, cost = chest_targets.classify(entry.skin, enums.chest_types)
            if name then
                entry.name, entry.cost = name, cost
                list[#list + 1] = entry
            end
        end
    end
    snap_src, snap_list = actors, list
    return list
end

-- Every chest actor in reach feeds the atlas (spent ones too).
function M.scan(actors)
    if not learn_on() or not current or type(actors) ~= 'table' then return 0 end
    local n = 0
    for _, entry in ipairs(M.classified(actors)) do
        M.observe(entry.name, entry.cost, entry.position, entry.interactable)
        n = n + 1
    end
    return n
end

function M.tick(now, in_helltide)
    if not st.zone_at or now - st.zone_at >= M.ZONE_EVERY or now < st.zone_at then
        st.zone_at = now
        local name = read_zone()
        -- Loading screens report no zone: keep the last one.
        if type(name) == 'string' and name ~= '' and not name:find('%[sno') then
            M.set_zone(M.zone_key(name))
        end
        local hour, active = clock.hour_id(), clock.active()
        -- Saved when the Helltide ends (minute 55) and when the hour changes.
        if current and ((st.hour and st.hour ~= hour) or (st.active and not active)) then M.save_zone(current) end
        st.hour, st.active = hour, active
    end
    if in_helltide and learn_on() and (not st.scan_at or now - st.scan_at >= M.SCAN_EVERY or now < st.scan_at) then
        st.scan_at = now
        local get_actors = tracker.hr_get_actors
        if type(get_actors) == 'function' then
            local ok, actors = pcall(get_actors)
            if ok then M.scan(actors) end
        end
    end
    if not st.save_at then st.save_at = now + M.SAVE_EVERY end
    if now >= st.save_at then
        st.save_at = now + M.SAVE_EVERY
        if current then M.save_zone(current) end
    end
end

function M.flush()
    if current then M.save_zone(current) end
end

function M._reset()
    zones, current, st = {}, nil, {}
    M.reset_seen_at = nil
    for _, handler in ipairs(section_list) do
        if handler.reset_all then pcall(handler.reset_all) end
    end
end

return M
