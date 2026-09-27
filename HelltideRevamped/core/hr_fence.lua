-- QQT_Warpigz_v3: learned Helltide boundary ("fence"), 20 m cells.
--
-- The host has no Helltide boundary API. A cell is learned "in" from the
-- patrol loop (seeded, never saved) and from the Helltide buff while the
-- player stands in it (sampled every 2 s); it is marked "out" where the buff
-- dropped while the hour was still running (tasks/helltide.lua, "Left
-- helltide zone"). allowed(pos) rejects a cell marked out at least twice
-- (and more often than it was seen inside) and a position more than about
-- 60 m from every known inside cell. Cells are saved in the zone file of
-- core/hr_atlas.lua as in|cx|cy|n and out|cx|cy|n, at most 4000 per zone.
local atlas = require "core.hr_atlas"
local settings = require "core.settings"
local tracker = require "core.tracker"

local M = {
    CELL = 20,
    MAX_CELLS = 4000,
    SAMPLE_EVERY = 2,
    CAP = 999,
    NEAR_CELLS = 3,
    OUT_MIN = 2,
    SEGMENT_STEP = 10,
}

local floor = math.floor
local zones = {}
local st = {sample_at = nil}

local function data(key)
    if not key then return nil end
    local z = zones[key]
    if not z then
        z = {inn = {}, out = {}, seed = {}, count = 0, dirty = false, seeded_for = nil, any = false}
        zones[key] = z
    end
    return z
end

local function ckey(cx, cy) return (cx + 32768) * 65536 + (cy + 32768) end
local function cxy(k)
    local cx = floor(k / 65536)
    return cx - 32768, (k - cx * 65536) - 32768
end
M.ckey, M.cxy = ckey, cxy

local function cell_of(x, y) return floor(x / M.CELL), floor(y / M.CELL) end

local function key_of_pos(pos)
    local x, y = atlas.xyz(pos)
    if not x then return nil end
    local cx, cy = cell_of(x, y)
    return ckey(cx, cy), cx, cy
end

local function learn_on() return settings.learn ~= false end

local function bump(z, list, k)
    local n = list[k]
    if n == nil then
        if z.count >= M.MAX_CELLS then return false end
        z.count = z.count + 1
        n = 0
    end
    if n < M.CAP then
        list[k] = n + 1
        z.dirty = true
    end
    z.any = true
    return true
end

function M.is_out_key(z, k)
    local out = z.out[k] or 0
    return out >= M.OUT_MIN and out > (z.inn[k] or 0)
end

-- Seeds "in" cells from the zone's patrol loop (not saved).
function M.seed(key, waypoints)
    local z = data(key)
    if not z or type(waypoints) ~= 'table' or z.seeded_for == waypoints then return false end
    z.seeded_for = waypoints
    z.seed = {}
    for _, wp in ipairs(waypoints) do
        local k = key_of_pos(wp)
        if k then z.seed[k] = true; z.any = true end
    end
    return true
end

-- The Helltide buff dropped at `pos` while the hour was still running.
function M.on_left(pos)
    if not learn_on() then return false end
    local z = data(atlas.current_zone())
    local k = z and key_of_pos(pos)
    if not k then return false end
    return bump(z, z.out, k)
end

function M.allowed(pos, key)
    if settings.fence == false then return true end
    local z = zones[key or atlas.current_zone() or '']
    if not z or not z.any then return true end
    local k, cx, cy = key_of_pos(pos)
    if not k then return true end
    if M.is_out_key(z, k) then return false end
    local r = M.NEAR_CELLS
    for dx = -r, r do
        for dy = -r, r do
            local nk = ckey(cx + dx, cy + dy)
            if z.seed[nk] or (z.inn[nk] or 0) > 0 then return true end
        end
    end
    return false
end

-- False when the straight line a -> b crosses a cell marked out.
function M.segment_ok(a, b, key)
    if settings.fence == false then return true end
    local z = zones[key or atlas.current_zone() or '']
    if not z or not z.any then return true end
    local ax, ay = atlas.xyz(a)
    local bx, by = atlas.xyz(b)
    if not ax or not bx then return true end
    local len = math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
    local steps = math.max(1, math.ceil(len / M.SEGMENT_STEP))
    for i = 0, steps do
        local f = i / steps
        local cx, cy = cell_of(ax + (bx - ax) * f, ay + (by - ay) * f)
        if M.is_out_key(z, ckey(cx, cy)) then return false end
    end
    return true
end

function M.tick(now, in_helltide, pos)
    local key = atlas.current_zone()
    if key and tracker.waypoints_zone == key and type(tracker.waypoints) == 'table' and #tracker.waypoints > 0 then
        M.seed(key, tracker.waypoints)
    end
    if st.sample_at and now - st.sample_at < M.SAMPLE_EVERY and now >= st.sample_at then return end
    st.sample_at = now
    if not in_helltide or not learn_on() or not pos then return end
    local z = data(key)
    local k = z and key_of_pos(pos)
    if k then bump(z, z.inn, k) end
end

function M.stats(key)
    local z = zones[key or atlas.current_zone() or '']
    if not z then return {inn = 0, out = 0} end
    local i, o = 0, 0
    for _ in pairs(z.inn) do i = i + 1 end
    for _ in pairs(z.out) do o = o + 1 end
    return {inn = i, out = o}
end

-- Inside cells (learned and seeded) as a flat {cx, cy, ...} list, bounded.
function M.cells(key, limit)
    local z = zones[key or atlas.current_zone() or '']
    local out = {}
    if not z then return out end
    limit = limit or M.MAX_CELLS
    local seen = {}
    for k, n in pairs(z.inn) do
        if n > 0 and #out < limit * 2 then
            local cx, cy = cxy(k)
            out[#out + 1], out[#out + 2] = cx, cy
            seen[k] = true
        end
    end
    for k in pairs(z.seed) do
        if not seen[k] and #out < limit * 2 then
            local cx, cy = cxy(k)
            out[#out + 1], out[#out + 2] = cx, cy
        end
    end
    return out
end

-- ── zone file section (core/hr_atlas.lua) ────────────────────────────────
local function parse(key, parts)
    local kind = parts[1]
    local cx, cy, n = tonumber(parts[2]), tonumber(parts[3]), tonumber(parts[4])
    if #parts ~= 4 or not (cx and cy and n) then return end
    if cx ~= floor(cx) or cy ~= floor(cy) or math.abs(cx) > 30000 or math.abs(cy) > 30000 or n < 1 then return end
    local z = data(key)
    local list = kind == 'in' and z.inn or z.out
    local k = ckey(cx, cy)
    if list[k] == nil then
        if z.count >= M.MAX_CELLS then return end
        z.count = z.count + 1
    end
    list[k] = math.min(M.CAP, floor(n))
    z.any = true
end

local function lines(key, out)
    local z = zones[key]
    if not z then return end
    local written = 0
    for _, pair in ipairs({{'in', z.inn}, {'out', z.out}}) do
        for k, n in pairs(pair[2]) do
            if written >= M.MAX_CELLS then return end
            local cx, cy = cxy(k)
            out[#out + 1] = string.format('%s|%d|%d|%d\n', pair[1], cx, cy, n)
            written = written + 1
        end
    end
end

atlas.register_section({'in', 'out'}, {
    parse = parse,
    lines = lines,
    dirty = function(key) local z = zones[key]; return z ~= nil and z.dirty end,
    saved = function(key) local z = zones[key]; if z then z.dirty = false end end,
    clear = function(key)
        local z = data(key)
        z.inn, z.out, z.count, z.dirty = {}, {}, 0, true
        z.any = next(z.seed) ~= nil
    end,
    reset_all = function() zones, st = {}, {} end,
})

return M
