-- QQT_Warpigz_v3: routes along the patrol loop ("roads").
--
-- A far chest is reached through the patrol loop (tracker.waypoints, cyclic,
-- about 4 m between points): follow the loop the shorter way round to the
-- loop point nearest the chest (or the exit learned by an earlier trip),
-- then leave the road for the last stretch (the existing recall navigation
-- in tasks/helltide.lua). Off the road, a stuck chest trip walks back to the
-- road point it left from and tries another exit at least 30 m further
-- along the loop (at most 3 exits, then the usual 60 s blacklist). The exit
-- of a successful trip is stored on the chest's atlas spot.
--
-- A chest whose trips failed (stuck, unreachable) is remembered as a "bad"
-- 4 m cell (bad|cx|cy|n|hour in the zone file); a target in a cell that
-- failed 3 times is skipped. Bad cells lose one count per Helltide they are
-- not hit again.
-- QQT_Warpigz_v3: the decay is counted from the cell's last hit hour (every
-- elapsed hour after the next one takes one count), whatever zone the player
-- is in at the hour change and across reloads: applied when a cell is read
-- (is_bad), hit again, loaded from the zone file and written to it. A cell
-- hit 3 times is left alone for that Helltide and the next one.
local atlas = require "core.hr_atlas"
local clock = require "core.hr_clock"
local settings = require "core.settings"
local tracker = require "core.tracker"

local M = {
    ROAD_MAX = 40,          -- player must be this close to the loop
    OFFROAD_MAX = 80,       -- loop point to target
    LOOKAHEAD = 5,          -- loop points ahead of the player (about 20 m)
    ARRIVE = 8,
    HANDOFF = 30,
    EXIT_SPACING = 30,      -- metres along the loop between tried exits
    MAX_EXITS = 3,
    GRID = 20,
    NO_PROGRESS_S = 20,
    PROGRESS_M = 4,
    BAD_CELL = 4,
    BAD_MAX = 500,
    BAD_MIN = 3,
    BAD_CAP = 999,
}

local floor, sqrt = math.floor, math.sqrt
local loop_cache = nil      -- {wps, n, cum, total, grid}
local bad = {}              -- zone key -> {cells = {k -> {n, hour}}, count, dirty}

local function d2(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return sqrt(dx * dx + dy * dy)
end

local function pos_xy(p)
    local x, y = atlas.xyz(p)
    return x, y
end

local function gkey(gx, gy) return (gx + 32768) * 65536 + (gy + 32768) end

-- ── loop model ───────────────────────────────────────────────────────────
function M.loop()
    local wps = tracker.waypoints
    if type(wps) ~= 'table' or #wps < 10 then return nil end
    if tracker.waypoints_zone and atlas.current_zone() and tracker.waypoints_zone ~= atlas.current_zone() then
        return nil
    end
    if loop_cache and loop_cache.wps == wps then return loop_cache end
    local n = #wps
    local xs, ys, cum, grid = {}, {}, {0}, {}
    for i = 1, n do
        local x, y = pos_xy(wps[i])
        if not x then return nil end
        xs[i], ys[i] = x, y
        if i > 1 then cum[i] = cum[i - 1] + d2(xs[i - 1], ys[i - 1], x, y) end
        local k = gkey(floor(x / M.GRID), floor(y / M.GRID))
        local cell = grid[k]
        if not cell then cell = {}; grid[k] = cell end
        cell[#cell + 1] = i
    end
    local total = cum[n] + d2(xs[n], ys[n], xs[1], ys[1])
    loop_cache = {wps = wps, n = n, xs = xs, ys = ys, cum = cum, total = total, grid = grid}
    return loop_cache
end

-- Nearest loop index to (x, y) within max_d, or nil.
local function nearest(L, x, y, max_d, skip)
    local r = math.ceil(max_d / M.GRID)
    local gx, gy = floor(x / M.GRID), floor(y / M.GRID)
    local best, best_d = nil, max_d
    for dx = -r, r do
        for dy = -r, r do
            local cell = L.grid[gkey(gx + dx, gy + dy)]
            if cell then
                for _, i in ipairs(cell) do
                    if not (skip and skip(i)) then
                        local d = d2(L.xs[i], L.ys[i], x, y)
                        if d < best_d then best, best_d = i, d end
                    end
                end
            end
        end
    end
    return best, best_d
end
-- QQT_Warpigz_v3 2.6.4 (sweep H1): the recorded loops pass the same place
-- several times. One candidate per pass ("lap"): the loop points within
-- max_d, grouped into runs of consecutive indices (a gap of more than
-- LAP_GAP points starts another lap), the nearest point of each run that
-- `skip` does not reject. List of {i, d}, nearest first, at most LAP_MAX.
M.LAP_GAP, M.LAP_MAX, M.LAP_EXTRA = 6, 8, 30
local function lap_points(L, x, y, max_d, skip, extra)
    local r = math.ceil(max_d / M.GRID)
    local gx, gy = floor(x / M.GRID), floor(y / M.GRID)
    local near = {}
    for dx = -r, r do
        for dy = -r, r do
            local cell = L.grid[gkey(gx + dx, gy + dy)]
            if cell then
                for _, i in ipairs(cell) do
                    local d = d2(L.xs[i], L.ys[i], x, y)
                    if d <= max_d then near[#near + 1] = {i = i, d = d} end
                end
            end
        end
    end
    if #near == 0 then return {} end
    table.sort(near, function(a, b) return a.i < b.i end)
    -- runs of consecutive indices; the last run joins the first across the wrap
    local runs, cur = {}, {near[1]}
    for k = 2, #near do
        if near[k].i - near[k - 1].i > M.LAP_GAP then
            runs[#runs + 1] = cur
            cur = {}
        end
        cur[#cur + 1] = near[k]
    end
    runs[#runs + 1] = cur
    if #runs > 1 and near[1].i + L.n - near[#near].i <= M.LAP_GAP then
        for _, e in ipairs(runs[#runs]) do runs[1][#runs[1] + 1] = e end
        runs[#runs] = nil
    end
    -- Per lap: its nearest point and both ends of the run (walking a little
    -- further along the lap can save more road than it costs).
    local out = {}
    for _, run in ipairs(runs) do
        local keep = {run[1], run[#run]}
        table.sort(run, function(a, b) return a.d < b.d end)
        table.insert(keep, 1, run[1])
        local seen = {}
        for _, e in ipairs(keep) do
            if not seen[e.i] then
                seen[e.i] = true
                if not (skip and skip(e.i)) then
                    out[#out + 1] = {i = e.i, d = e.d}
                elseif e == keep[1] then
                    -- the nearest point crosses out: the nearest one that does not
                    for _, alt in ipairs(run) do
                        if not seen[alt.i] and not skip(alt.i) then
                            seen[alt.i] = true
                            out[#out + 1] = {i = alt.i, d = alt.d}
                            break
                        end
                    end
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.d < b.d end)
    -- Another lap only when it is about as close as the nearest one: a much
    -- longer straight leg may cross what the loop goes round (a hairpin).
    local reach = out[1] and out[1].d + (extra or max_d) or 0
    while #out > 0 and (#out > M.LAP_MAX * 3 or out[#out].d > reach) do out[#out] = nil end
    return out
end

M.nearest_index = function(pos, max_d)
    local L = M.loop()
    local x, y = pos_xy(pos)
    if not L or not x then return nil end
    return nearest(L, x, y, max_d or M.ROAD_MAX)
end

-- Arc length from index a to index b going in direction dir (+1 / -1).
local function arc(L, a, b, dir)
    local forward = L.cum[b] - L.cum[a]
    if forward < 0 then forward = forward + L.total end
    if dir == 1 then return forward end
    local back = L.total - forward
    if back >= L.total then back = back - L.total end
    return back
end
M.arc = function(a, b, dir) local L = M.loop(); return L and arc(L, a, b, dir) end

local function shorter(L, a, b)
    local f, bk = arc(L, a, b, 1), arc(L, a, b, -1)
    if f <= bk then return 1, f end
    return -1, bk
end

local function wrap(L, i)
    return ((i - 1) % L.n) + 1
end

local function valid_exit(L, idx, tx, ty)
    return type(idx) == 'number' and idx >= 1 and idx <= L.n and idx == floor(idx)
        and d2(L.xs[idx], L.ys[idx], tx, ty) <= M.OFFROAD_MAX
end

-- ── planning ─────────────────────────────────────────────────────────────
-- Road cost (metres) from the player to the target, or the straight
-- distance when the loop cannot be used. Second value: the route plan.
local start_cache = {x = nil, y = nil, L = nil, starts = nil}

local function crosses_out(L, i, target)
    local fence = tracker.hr_fence
    if not fence then return false end
    local ok, fine = pcall(fence.segment_ok, L.wps[i], target)
    return ok and fine == false
end

function M.plan(target, player, exit_idx)
    if settings.road_routing == false then return nil end
    local L = M.loop()
    local tx, ty = pos_xy(target)
    local px, py = pos_xy(player)
    if not L or not tx or not px then return nil end
    -- The player's loop points are shared by every candidate of one pick.
    -- QQT_Warpigz_v3 2.6.4 (sweep H1): one start per lap near the player and
    -- one exit per lap near the chest, the cheapest pair (the single nearest
    -- points were often on different laps: 2,179 m of road for a 270 m trip,
    -- and the cost jumped when a step moved the start to another lap).
    local c = start_cache
    if c.L ~= L or c.x == nil or math.abs(c.x - px) > 0.5 or math.abs(c.y - py) > 0.5 then
        c.L, c.x, c.y = L, px, py
        c.starts = lap_points(L, px, py, M.ROAD_MAX)
    end
    local starts = c.starts
    if #starts == 0 then return nil end
    local exits
    if valid_exit(L, exit_idx, tx, ty) then
        exits = {{i = exit_idx, d = d2(L.xs[exit_idx], L.ys[exit_idx], tx, ty)}}
    else
        exits = lap_points(L, tx, ty, M.OFFROAD_MAX, function(i) return crosses_out(L, i, target) end, M.LAP_EXTRA)
    end
    local best
    for _, s in ipairs(starts) do
        for _, e in ipairs(exits) do
            local dir, road = shorter(L, s.i, e.i)
            local cost = s.d + road + e.d
            if not best or cost < best.cost then
                best = {i0 = s.i, i1 = e.i, dir = dir, road = road, offroad = e.d, cost = cost}
            end
        end
    end
    if not best or best.offroad > M.OFFROAD_MAX then return nil end
    return {i0 = best.i0, i1 = best.i1, dir = best.dir, offroad = best.offroad, road = best.road,
        cost = best.cost, mode = 'road', cursor = best.i0, tried = {best.i1}, target = target, tx = tx, ty = ty}
end

function M.cost(target, player, exit_idx)
    local route = M.plan(target, player, exit_idx)
    if route then return route.cost, route end
    local tx, ty = pos_xy(target)
    local px, py = pos_xy(player)
    if not tx or not px then return math.huge, nil end
    return d2(px, py, tx, ty), nil
end

-- Remaining arc from the cursor to the exit along the route direction.
local function remaining(L, route)
    return arc(L, route.cursor, route.i1, route.dir)
end

local function progress(route, value, now)
    if not route.best or value < route.best - M.PROGRESS_M then
        route.best, route.best_t = value, now
        return true
    end
    return false
end

-- Next point to walk to, or nil once the road part is done (hand-off: the
-- caller walks to the target) or the route failed (route.failed).
function M.next_goal(route, player, now)
    if type(route) ~= 'table' or route.failed then return nil end
    if route.mode == 'offroad' then return nil end
    local L = M.loop()
    if not L then
        -- The loop went away (zone change, task reset): not a hand-off.
        route.failed = 'patrol loop unavailable'
        return nil
    end
    if route.i1 > L.n or route.cursor > L.n then route.failed = 'loop changed'; return nil end
    local px, py = pos_xy(player)
    if not px then return nil end
    now = now or 0
    if route.best_t and now - route.best_t > M.NO_PROGRESS_S then
        route.failed = 'no progress on the road'
        return nil
    end
    if route.mode == 'backtrack' then
        local bi = route.back_idx
        local d = d2(L.xs[bi], L.ys[bi], px, py)
        progress(route, d, now)
        if d > M.ARRIVE then return L.wps[bi] end
        -- Back on the road: continue along the loop to the next exit.
        route.i0, route.cursor, route.i1 = bi, bi, route.next_exit
        route.dir = shorter(L, bi, route.i1)
        route.mode, route.best, route.best_t = 'road', nil, nil
    end
    -- Advance the cursor to the loop point nearest the player a little ahead.
    local best_i, best_d = route.cursor, d2(L.xs[route.cursor], L.ys[route.cursor], px, py)
    local rem = remaining(L, route)
    for step = 1, 25 do
        local i = wrap(L, route.cursor + route.dir * step)
        if arc(L, route.cursor, i, route.dir) > rem then break end
        local d = d2(L.xs[i], L.ys[i], px, py)
        if d < best_d then best_i, best_d = i, d end
    end
    route.cursor = best_i
    rem = remaining(L, route)
    progress(route, rem, now)
    local exit_d = d2(L.xs[route.i1], L.ys[route.i1], px, py)
    if rem <= M.HANDOFF or (exit_d <= M.HANDOFF and rem <= M.HANDOFF * 2 + 20) then
        route.mode = 'offroad'
        return nil
    end
    local goal = route.cursor
    for _ = 1, M.LOOKAHEAD do
        local nxt = wrap(L, goal + route.dir)
        if arc(L, route.cursor, nxt, route.dir) > rem then break end
        goal = nxt
    end
    return L.wps[goal]
end

-- The chest trip got stuck off the road. When another exit exists, walks
-- back to the road first (true), else false (the caller blacklists the chest
-- as before and marks the chest's cell bad).
function M.stuck_offroad(route, player)
    local L = M.loop()
    if not L or type(route) ~= 'table' or route.mode ~= 'offroad' then return false end
    route.tried = route.tried or {route.i1}
    if #route.tried >= M.MAX_EXITS then return false end
    local tx, ty = route.tx, route.ty
    if not tx then return false end
    local alt = nearest(L, tx, ty, M.OFFROAD_MAX, function(i)
        for _, used in ipairs(route.tried) do
            if math.min(arc(L, used, i, 1), arc(L, used, i, -1)) < M.EXIT_SPACING then return true end
        end
        local fence = tracker.hr_fence
        if fence then
            local ok, fine = pcall(fence.segment_ok, L.wps[i], route.target)
            if ok and fine == false then return true end
        end
        return false
    end)
    if not alt then return false end
    route.tried[#route.tried + 1] = alt
    route.back_idx, route.next_exit = route.i1, alt
    route.mode, route.best, route.best_t = 'backtrack', nil, nil
    return true
end

-- The chest was opened after an off-road leg: remember the exit.
function M.on_success(route, pos, name)
    if type(route) ~= 'table' or route.mode ~= 'offroad' or not route.i1 then return nil end
    return atlas.set_exit(pos, route.i1, name)
end

-- C5: seconds of a companion yield never count toward the no-progress window.
function M.credit(route, gap)
    if type(route) == 'table' and route.best_t and type(gap) == 'number' and gap > 0 then
        route.best_t = route.best_t + gap
    end
end

-- Route points for the dashboard (at most `limit`).
function M.points(route, limit)
    local L = M.loop()
    local out = {}
    if not L or type(route) ~= 'table' or not route.cursor or route.mode == 'offroad' then return out end
    limit = limit or 40
    local rem = remaining(L, route)
    local step = math.max(1, floor((rem / 4) / limit))
    local i = route.cursor
    for _ = 1, limit do
        out[#out + 1] = {floor(L.xs[i]), floor(L.ys[i])}
        local nxt = wrap(L, i + route.dir * step)
        if arc(L, route.cursor, nxt, route.dir) > rem then break end
        i = nxt
    end
    out[#out + 1] = {floor(L.xs[route.i1]), floor(L.ys[route.i1])}
    return out
end

-- ── bad cells ────────────────────────────────────────────────────────────
local function bad_zone(key)
    if not key then return nil end
    local z = bad[key]
    if not z then
        z = {cells = {}, count = 0, dirty = false}
        bad[key] = z
    end
    return z
end

local function bad_key(x, y)
    return gkey(floor(x / M.BAD_CELL), floor(y / M.BAD_CELL))
end

-- QQT_Warpigz_v3: lazy decay from the last hit hour. A cell hit in hour H
-- keeps its count through H and H+1 and loses one per hour after that. The
-- anchor moves to the previous hour so later decay keeps counting. Returns
-- the cell, or nil once it decayed away (removed from the zone).
local function settle(z, k, cell, hour)
    if not cell then return nil end
    hour = hour or clock.hour_id()
    if type(hour) ~= 'number' or type(cell.hour) ~= 'number' then return cell end
    local steps = floor((hour - cell.hour) / 3600) - 1
    if steps <= 0 then return cell end
    cell.n = cell.n - steps
    cell.hour = hour - 3600
    z.dirty = true
    if cell.n <= 0 then
        z.cells[k] = nil
        z.count = z.count - 1
        return nil
    end
    return cell
end

function M.record_bad(pos)
    if settings.learn == false then return false end
    local z = bad_zone(atlas.current_zone())
    local x, y = pos_xy(pos)
    if not z or not x then return false end
    local k = bad_key(x, y)
    local cell = settle(z, k, z.cells[k]) -- QQT_Warpigz_v3
    if not cell then
        if z.count >= M.BAD_MAX then return false end
        cell = {n = 0, hour = 0}
        z.cells[k] = cell
        z.count = z.count + 1
    end
    cell.n = math.min(M.BAD_CAP, cell.n + 1)
    cell.hour = clock.hour_id()
    z.dirty = true
    return true
end

function M.is_bad(pos, key)
    local z = bad[key or atlas.current_zone() or '']
    local x, y = pos_xy(pos)
    if not z or not x then return false end
    local k = bad_key(x, y)
    local cell = settle(z, k, z.cells[k]) -- QQT_Warpigz_v3
    return cell ~= nil and cell.n >= M.BAD_MIN
end

-- Decay every bad cell of every zone to the current hour.
function M.decay(key, hour)
    hour = hour or clock.hour_id()
    for zk, z in pairs(bad) do
        if key == nil or zk == key then
            for k, cell in pairs(z.cells) do settle(z, k, cell, hour) end
        end
    end
end

local st = {hour = nil, at = nil}
function M.tick(now)
    if now and st.at and now - st.at < 1 and now >= st.at then return end
    st.at = now
    local hour = clock.hour_id()
    if st.hour and st.hour ~= hour then M.decay(nil, hour) end
    st.hour = hour
end

local function parse(key, parts)
    -- bad|cx|cy|n|last_hour
    if #parts ~= 5 then return end
    local cx, cy, n, hour = tonumber(parts[2]), tonumber(parts[3]), tonumber(parts[4]), tonumber(parts[5])
    if not (cx and cy and n and hour) or cx ~= floor(cx) or cy ~= floor(cy) or n < 1 then return end
    if math.abs(cx) > 30000 or math.abs(cy) > 30000 then return end
    local z = bad_zone(key)
    local k = gkey(cx, cy)
    if not z.cells[k] then
        if z.count >= M.BAD_MAX then return end
        z.count = z.count + 1
    end
    z.cells[k] = {n = math.min(M.BAD_CAP, floor(n)), hour = floor(hour)}
    settle(z, k, z.cells[k]) -- QQT_Warpigz_v3: a cell from an old session decays on load
end

local function lines(key, out)
    local z = bad[key]
    if not z then return end
    M.decay(key) -- QQT_Warpigz_v3: never write a count that has decayed
    for k, cell in pairs(z.cells) do
        local gx = floor(k / 65536)
        local cx, cy = gx - 32768, (k - gx * 65536) - 32768
        out[#out + 1] = string.format('bad|%d|%d|%d|%d\n', cx, cy, cell.n, cell.hour)
    end
end

atlas.register_section({'bad'}, {
    parse = parse,
    lines = lines,
    dirty = function(key) local z = bad[key]; return z ~= nil and z.dirty end,
    saved = function(key) local z = bad[key]; if z then z.dirty = false end end,
    clear = function(key) bad[key] = {cells = {}, count = 0, dirty = true} end,
    reset_all = function() bad, loop_cache, st = {}, nil, {} end,
})

return M
