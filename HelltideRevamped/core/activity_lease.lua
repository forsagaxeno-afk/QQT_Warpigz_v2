-- QQT_Warpigz_v3: standalone activity lease. Identical copy in ArkhamAsylum,
-- WonderCity, HordeDev, HelltideRevamped and Reaper (core/activity_lease.lua).
--
-- Every activity main_toggle is a persisted checkbox, so a leftover toggle
-- is easy to miss. With WarPigs off, two enabled activity plugins used to
-- teleport back and forth between their home towns forever. The first
-- enabled activity to pulse takes the shared lease _G[KEY] = {owner =
-- '<Export>'} and keeps it while it reports enabled; every other enabled
-- activity holds (no teleport, no movement) and says why, once per episode.
-- The lease is free as soon as its owner reports enabled == false, so a
-- hand-off such as HordeDev's 'Run pit' (InfernalHordesPlugin.disable(),
-- then ArkhamAsylumPlugin.enable()) is not held. With WarPigs on, WarPigs
-- owns activity hand-offs and the lease is not consulted.
local KEY = 'QQT_Warpigz_activity_lease'
local LABELS = {
    ArkhamAsylumPlugin = 'ArkhamAsylum', WonderCityPlugin = 'WonderCity',
    HelltideRevampedPlugin = 'HelltideRevamped', InfernalHordesPlugin = 'HordeDev',
    ReaperPlugin = 'Reaper',
}

local lease = {reason = nil, logged = nil}

-- Plain reads/writes when a sandbox has no rawget/rawset.
local function get(name)
    if rawget then return rawget(_G, name) end
    return _G[name]
end
local function put(value)
    if rawset then rawset(_G, KEY, value) else _G[KEY] = value end
end

local function status_of(p)
    if type(p) ~= 'table' then return nil end
    local fn = (type(p.status) == 'function' and p.status)
        or (type(p.get_status) == 'function' and p.get_status) or nil
    if not fn then return nil end
    local ok, s = pcall(fn)
    if ok and type(s) == 'table' then return s end
    return nil
end

local function orchestrated()
    local st = status_of(get('WarPigsPlugin'))
    return st ~= nil and st.enabled == true
end

-- Called on every pulse of the enabled plugin `export`. Returns nil when it
-- may run, or the hold reason. `log` (optional) prints the reason once per
-- episode.
function lease.check(export, log)
    if orchestrated() then
        lease.reason, lease.logged = nil, nil
        return nil
    end
    local current = get(KEY)
    local owner = type(current) == 'table' and current.owner or nil
    if owner and owner ~= export then
        local st = status_of(get(owner))
        if st and st.enabled == true then
            local reason = 'another activity plugin (' .. (LABELS[owner] or tostring(owner))
                .. ') is enabled — turn one off'
            lease.reason = reason
            if lease.logged ~= owner then
                lease.logged = owner
                if log then log(reason) end
            end
            return reason
        end
    end
    if owner ~= export then put({owner = export}) end
    if lease.logged and log then log('the other activity plugin is off — resuming') end
    lease.reason, lease.logged = nil, nil
    return nil
end

-- Called when `export` is disabled: frees the lease it holds.
function lease.release(export)
    local current = get(KEY)
    if type(current) == 'table' and current.owner == export then put(nil) end
    lease.reason, lease.logged = nil, nil
end

return lease
