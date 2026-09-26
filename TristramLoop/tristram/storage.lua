-- Data only: never execute a saved file. All writes stay beside this addon.
local M = {}
local function finite(n) return type(n) == "number" and n == n and math.abs(n) < 1e12 end
local function hex(s) return (s:gsub(".", function(c) return string.format("%02x", string.byte(c)) end)) end
local function unhex(s)
    if #s % 2 ~= 0 or s:find("[^0-9a-f]") then return nil end
    return (s:gsub("..", function(c) return string.char(tonumber(c, 16)) end))
end
function M.new(path)
    local store = { points = {}, arena = nil, last_clear = nil, path = path, message = "" }
    local function can_store()
        return type(path) == "string" and type(io) == "table" and type(io.open) == "function"
    end
    local opened, file = false, nil
    if can_store() then opened, file = pcall(io.open, path, "r")
    else store.message = "Local saves unavailable; the loot wait will restart on reload." end
    if opened and file then
        local body = file:read(8193) or ""
        file:close()
        if #body <= 8192 and body:sub(1, 3) == "v1\n" then
            for line in body:gmatch("[^\r\n]+") do
                local key, x, y, w, h = line:match("^point (%a+) ([%d.]+) ([%d.]+) (%d+) (%d+)$")
                x, y, w, h = tonumber(x), tonumber(y), tonumber(w), tonumber(h)
                if key and finite(x) and finite(y) and w and h and w > 0 and h > 0
                    and x >= 0 and x < w and y >= 0 and y < h then
                    store.points[key] = { x = x, y = y, w = w, h = h }
                end
                local name, zone, ax, ay, az = line:match("^arena (%x+) (%x+) ([%d.e+-]+) ([%d.e+-]+) ([%d.e+-]+)$")
                ax, ay, az = tonumber(ax), tonumber(ay), tonumber(az)
                if name and finite(ax) and finite(ay) and finite(az) then
                    name, zone = unhex(name), unhex(zone)
                    if name and zone then store.arena = { name = name, zone = zone, x = ax, y = ay, z = az } end
                end
                local stamp = tonumber(line:match("^clear (%d+)$"))
                if finite(stamp) and stamp > 0 then store.last_clear = stamp end
            end
        else store.message = "Saved data unreadable; using the bundled arena and conservative loot wait." end
    end
    function store.save()
        if not can_store() then
            store.message = "Local saves unavailable; the loot wait will restart on reload."
            return false
        end
        local rows = { "v1" }
        local keys = {}
        for key in pairs(store.points) do keys[#keys + 1] = key end
        table.sort(keys)
        for _, key in ipairs(keys) do
            local p = store.points[key]
            rows[#rows + 1] = string.format("point %s %.3f %.3f %d %d", key, p.x, p.y, p.w, p.h)
        end
        local a = store.arena
        if a then rows[#rows + 1] = string.format("arena %s %s %.9g %.9g %.9g", hex(a.name), hex(a.zone), a.x, a.y, a.z) end
        if store.last_clear then rows[#rows + 1] = string.format("clear %.0f", store.last_clear) end
        local ok, result = pcall(function()
            local out = io.open(path, "w")
            if not out then return false end
            local wrote = out:write(table.concat(rows, "\n") .. "\n")
            local closed = out:close()
            return wrote ~= nil and closed ~= nil
        end)
        store.message = ok and result and "Saved locally." or "Could not save; the loot wait will restart on reload."
        return ok and result == true
    end
    return store
end
return M
