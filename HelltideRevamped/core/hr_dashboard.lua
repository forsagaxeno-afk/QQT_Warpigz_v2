-- QQT_Warpigz_v3: data file for the offline web dashboard.
--
-- The host cannot serve HTTP (no sockets), so the dashboard is a static page
-- (dashboard/index.html, opened from disk; it opens the last chosen theme
-- page: forge.html, daylight.html or console.html) that re-loads the script
-- dashboard/hr_data.js every 5 s. This module rewrites that file every
-- 'Dashboard update (s)' seconds (5-60, default 10) while 'Web dashboard' is
-- on and the plugin is enabled:  window.HR_DATA = {...};
-- The payload is bounded to 256 KB (the map layers are cut first).
-- QQT_Warpigz_v3: + the zone's patrol road (a downsampled polyline built
-- once per zone and cached), the reset wave, the target card, the cinder
-- goal, chests opened this wave, chests still to open, rupture anchors seen
-- this hour, the Maiden altar and named atlas spots (core/hr_view.lua).
local json = require "core.hr_json"
local store = require "core.hr_store"
local stats = require "core.hr_stats"
local clock = require "core.hr_clock"
local atlas = require "core.hr_atlas"
local fence = require "core.hr_fence"
local roads = require "core.hr_roads"
local settings = require "core.settings"
local tracker = require "core.tracker"
local perf = require "core.perf"
local view = require "core.hr_view" -- QQT_Warpigz_v3
local enums = require "data.enums"   -- QQT_Warpigz_v3

local M = {
    FILE = 'dashboard/hr_data.js',
    MAX_BYTES = 256 * 1024,
    TRAIL_MAX = 300,
    TRAIL_EVERY = 5,
    ROUTE_MAX = 40,
    FENCE_MAX = 4000,
    ATLAS_MAX = 200,
    HISTORY_MAX = 50,
    ROAD_MAX = 400,         -- QQT_Warpigz_v3: patrol road points exported (every Nth waypoint)
    TEARS_MAX = 20,         -- QQT_Warpigz_v3: rupture anchors kept for this hour
    OPENED_MAX = 20,        -- QQT_Warpigz_v3: chests opened this wave in the file
}

-- road = {zone, pts (flat x, y list)}: built once per zone (M.road_builds counts it).
local st = {write_at = nil, trail = {}, trail_at = nil, writes = 0, road = nil, tears = {}}
M.road_builds = 0

local function period()
    local s = tonumber(settings.dashboard_sec) or 10
    if s ~= s or s < 5 then return 5 end
    if s > 60 then return 60 end
    return s
end

local function round(v) return math.floor((tonumber(v) or 0) + 0.5) end

local function scope(t)
    t = t or {}
    return {earned = round(t.earned), spent = round(t.spent), lost = round(t.lost), chests = round(t.chests),
        mystery = round(t.mystery), deaths = round(t.deaths), tears = round(t.tears), secs = round(t.secs),
        helltides = round(t.helltides)}
end

local function history()
    local out = {}
    local list = stats.history or {}
    for i = math.max(1, #list - M.HISTORY_MAX + 1), #list do
        local h = list[i]
        out[#out + 1] = {hour = h.hour_id or 0, zone = tostring(h.zone or '?'), earned = round(h.earned),
            spent = round(h.spent), lost = round(h.lost), chests = round(h.chests), mystery = round(h.mystery),
            deaths = round(h.deaths), secs = round(h.secs)}
    end
    return out
end

local function spot_status(spot, slot)
    if spot.opened_slot == slot then return 'opened' end
    if spot.used_slot == slot then return 'spent' end
    if spot.miss_slot == slot then return 'missed' end
    if spot.live_slot == slot then return 'seen' end
    return 'predicted'
end

local function atlas_list(limit)
    local out = {}
    local slot = clock.slot_id()
    for i, s in ipairs(atlas.spots()) do
        if #out >= limit then break end
        out[#out + 1] = {id = i, type = s.type, x = round(s.x), y = round(s.y), seen = s.seen, miss = s.miss,
            status = spot_status(s, slot), name = view.short_name(s.name), cost = round(s.cost)} -- QQT_Warpigz_v3: + id, name, cost
    end
    return out
end

-- QQT_Warpigz_v3: the zone's patrol loop as a flat [x, y, ...] list, every
-- Nth waypoint (at most ROAD_MAX points). Built once per zone.
local function road_for(zone)
    if st.road and st.road.zone == zone then return st.road.pts end
    local pts = {}
    local file
    for _, tp in ipairs(enums.helltide_tps) do
        if tp.name == zone then file = tp.file end
    end
    local wps
    if type(tracker.waypoints) == 'table' and tracker.waypoints_zone == zone and #tracker.waypoints > 0 then
        wps = tracker.waypoints
    elseif file then
        local ok, list = pcall(require, 'waypoints.' .. file)
        if ok and type(list) == 'table' then wps = list end
    end
    if wps and #wps > 1 then
        local step = math.max(1, math.ceil(#wps / M.ROAD_MAX))
        for i = 1, #wps, step do
            local x, y = atlas.xyz(wps[i])
            if x then pts[#pts + 1] = round(x); pts[#pts + 1] = round(y) end
        end
    end
    M.road_builds = M.road_builds + 1
    st.road = {zone = zone, pts = pts}
    return pts
end

-- QQT_Warpigz_v3: rupture anchors seen this hour (the tear event's session).
local function tears_now()
    local hour = clock.hour_id()
    local keep = {}
    for _, t in ipairs(st.tears) do
        if t.hour == hour then t.active = false; keep[#keep + 1] = t end
    end
    st.tears = keep
    local tear = tracker.tear_event
    local ok, sess = pcall(function() return tear and tear.session and tear.session() end)
    if ok and type(sess) == 'table' then
        local x, y = atlas.xyz(sess.anchor or sess.chamber_anchor)
        if x then
            local found = nil
            for _, t in ipairs(keep) do
                local dx, dy = t.x - x, t.y - y
                if dx * dx + dy * dy <= 625 then found = t end
            end
            if not found then
                found = {x = round(x), y = round(y), hour = hour, type = tostring(sess.rupture_type or 'Rupture')}
                keep[#keep + 1] = found
                while #keep > M.TEARS_MAX do table.remove(keep, 1) end
            end
            found.active = true
        end
    end
    local out = {}
    for i, t in ipairs(keep) do out[i] = {x = t.x, y = t.y, type = t.type, active = t.active} end
    return out
end

local function opened_list()
    local out = {}
    for _, o in ipairs(view.opened_wave(M.OPENED_MAX)) do
        local e = {name = view.short_name(o.name), cost = round(o.cost), t = o.t}
        if o.x then e.x, e.y = round(o.x), round(o.y) end
        out[#out + 1] = e
    end
    return out
end

local function opened_hour()
    local out = {}
    local hour = clock.hour_id()
    for _, o in ipairs(stats.opened or {}) do
        if o.hour == hour and o.x then
            out[#out + 1] = {name = view.short_name(o.name), cost = round(o.cost), x = round(o.x), y = round(o.y),
                t = o.t, wave = o.slot == clock.slot_id()}
        end
    end
    return out
end

-- QQT_Warpigz_v3: wave, target, goal, now, opened, still to open.
local function live_view(data, player_pos, cinders)
    local w = view.wave()
    data.wave = {i = w.i, n = w.n, start = w.start, next_min = w.next_min, next_in = round(w.next_in)}
    local resets = {}
    for i, m in ipairs(clock.RESET_MINUTES) do resets[i] = m end
    data.reset_minutes = json.array(resets)
    data.end_minute = clock.END_MINUTE
    data.starts_in = round(clock.starts_in())
    data.in_helltide = tracker.hr_in_ht == true
    local tgt = view.target(player_pos)
    if tgt then
        data.target = {name = tgt.short, raw = tgt.name, cost = tgt.cost, source = tgt.source, mystery = tgt.mystery,
            road = tgt.road, x = tgt.x and round(tgt.x) or nil, y = tgt.y and round(tgt.y) or nil,
            dist = tgt.dist and round(tgt.dist) or nil}
    end
    local g, rs = view.goal(cinders, tgt)
    data.goal = {cost = round(g.cost), label = g.label, ready = g.ready}
    if rs then data.run = {on = rs.on == true, active = rs.active == true, saving = rs.saving == true,
        threshold = round(rs.threshold)} end
    local state = tracker.hr_task_state
    data.now = {activity = view.activity(state), movement = view.movement(state, tgt), plan = view.plan()}
    data.opened = json.array(opened_list())
    data.opened_hour = json.array(opened_hour())
    data.to_open = view.to_open()
    data.region = view.region(data.zone) or ''
    local maiden = enums.maiden_positions and enums.maiden_positions[data.zone]
    local mx, my = atlas.xyz(maiden)
    if mx then data.maiden = {round(mx), round(my)} end
end

local function top_perf()
    local rows = {}
    if type(perf.data) ~= 'table' then return rows end
    for name, d in pairs(perf.data) do
        if type(d) == 'table' and type(d.max) == 'number' then
            rows[#rows + 1] = {name = tostring(name), max_ms = d.max * 1000,
                avg_ms = (d.count or 0) > 0 and (d.total or 0) / d.count * 1000 or 0, count = d.count or 0}
        end
    end
    table.sort(rows, function(a, b) return a.max_ms > b.max_ms end)
    local out = {}
    for i = 1, math.min(10, #rows) do out[i] = rows[i] end
    return out
end

local function notes()
    local out = {}
    for _, n in ipairs(stats.notes or {}) do out[#out + 1] = {t = n.t, msg = n.msg} end
    return out
end

local function flat_pairs(list)
    local parts = {}
    for i = 1, #list do parts[i] = tostring(list[i]) end
    return '[' .. table.concat(parts, ',') .. ']'
end

-- Build the payload text (window.HR_DATA=...;). `layers` = 1 full, 2 no
-- fence cells, 3 no fence / atlas / trail.
function M.build(now, player_pos, layers)
    layers = layers or 1
    local task = tracker.hr_task_state
    local live = tracker.hr_live
    local order = tracker.hr_chest_order
    local target = order and order.last_plan
    local cinders = 0
    local okc, c = pcall(get_helltide_coin_cinders)
    if okc and type(c) == 'number' then cinders = c end
    local data = {
        v = 1,
        t = clock.epoch(),
        zone = atlas.current_zone() or '',
        live_zone = live and live.zone_name and live.zone_name() or '',
        state = tostring(task or ''),
        mode = tracker.hr_mode and tracker.hr_mode.effective() or '',
        cinders = cinders,
        minutes_left = clock.minutes_left(),
        next_reset = clock.next_reset_in(),
        active = clock.active(),
        rates = {per_min = stats.rate_min(), per_hr = stats.rate_hr()},
        helltide = scope(stats.helltide),
        session = scope(stats.session),
        alltime = scope(stats.alltime),
        history = json.array(history()),
        plan = target and {reserve = target.reserve or 0, target = target.target_name or '',
            mystery_known = target.mystery_known or 0} or nil,
        perf = json.array(top_perf()),
        events = json.array(notes()),
    }
    local px, py = atlas.xyz(player_pos)
    if px then data.player = {round(px), round(py)} end
    local chests, route = {}, nil
    local remembered, target_key
    if type(tracker.hr_get_remembered) == 'function' then
        local okr, r, k = pcall(tracker.hr_get_remembered)
        if okr then remembered, target_key = r, k end
    end
    if type(remembered) == 'table' then
        for key, e in pairs(remembered) do
            local x, y = atlas.xyz(e.position)
            if x and #chests < 60 then
                chests[#chests + 1] = {type = e.name == 'usz_rewardGizmo_Uber' and 'mystery' or 'regular',
                    x = round(x), y = round(y), status = key == target_key and 'target'
                        or (e.predicted and 'predicted' or 'remembered'),
                    name = view.short_name(e.name), cost = round(e.cost)} -- QQT_Warpigz_v3: + name, cost
            end
            if key == target_key then route = e.route end
        end
    end
    data.chests = json.array(chests)
    live_view(data, player_pos, cinders) -- QQT_Warpigz_v3
    if layers < 3 then
        data.tears = json.array(tears_now()) -- QQT_Warpigz_v3
        data.road = {zone = data.zone, pts = json.raw(flat_pairs(road_for(data.zone)))} -- QQT_Warpigz_v3
        data.atlas = json.array(atlas_list(M.ATLAS_MAX))
        local trail = {}
        for i, p in ipairs(st.trail) do trail[i] = p end
        data.trail = json.array(trail)
    end
    data.route = json.array(type(route) == 'table' and roads.points(route, M.ROUTE_MAX) or {})
    local text = json.encode(data)
    if layers == 1 then
        -- Fence cells as one flat [cx, cy, ...] list (20 m cells).
        text = text:sub(1, -2) .. ',"fence_cell":' .. fence.CELL .. ',"fence_in":'
            .. flat_pairs(fence.cells(nil, M.FENCE_MAX)) .. '}'
    end
    return 'window.HR_DATA=' .. text .. ';\n'
end

function M.tick(now, player_pos, in_helltide)
    if settings.dashboard ~= true then return false end
    if in_helltide and player_pos and (not st.trail_at or now - st.trail_at >= M.TRAIL_EVERY or now < st.trail_at) then
        st.trail_at = now
        local x, y = atlas.xyz(player_pos)
        if x then
            st.trail[#st.trail + 1] = {round(x), round(y)}
            while #st.trail > M.TRAIL_MAX do table.remove(st.trail, 1) end
        end
    end
    if st.write_at and now - st.write_at < period() and now >= st.write_at then return false end
    st.write_at = now
    local text
    for layers = 1, 3 do
        local ok, built = pcall(M.build, now, player_pos, layers)
        if not ok then
            stats.note('[HelltideRevamped] dashboard data failed: ' .. tostring(built))
            return false
        end
        text = built
        if #text <= M.MAX_BYTES then break end
        text = nil
    end
    if not text then return false end
    local ok = store.write(M.FILE, {text})
    if ok then st.writes = st.writes + 1 end
    return ok
end

function M.writes() return st.writes end
function M._reset() st = {write_at = nil, trail = {}, trail_at = nil, writes = 0, road = nil, tears = {}}; M.road_builds = 0 end

return M
