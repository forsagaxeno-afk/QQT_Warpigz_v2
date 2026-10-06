-- QQT_Warpigz_v3: WarRoom reads the other plugins' published status tables
-- (every call protected, nothing is ever called that changes a plugin:
-- WarPigs is read through its side-effect-free peek(), never status(),
-- which runs WarPigs' alfred_idle() hold clocks; LooteerPlugin.status()
-- is never called).
-- read_all() returns key -> {present, enabled, busy, ver, task, st} and
-- conditions() the alert conditions they report right now.
local M = {}

-- key, display name, role, global, status function, activity it runs.
M.LIST = {
    {key = 'warpigs', name = 'WarPigs', role = 'Orchestrator', g = 'WarPigsPlugin', fn = 'peek'},
    {key = 'warpug', name = 'WarPug', role = 'War plans', g = 'WarPugPlugin', fn = 'status'},
    {key = 'rosie', name = 'Rosie', role = 'Town & pickup', g = 'AlfredTheButlerPlugin', fn = 'get_status', act = 'town'},
    {key = 'batmobile', name = 'Batmobile', role = 'Navigation', g = 'BatmobilePlugin'},
    {key = 'helltide', name = 'HelltideRevamped', role = 'Helltide', g = 'HelltideRevampedPlugin', fn = 'status', act = 'helltide'},
    {key = 'hordedev', name = 'HordeDev', role = 'Infernal Hordes', g = 'InfernalHordesPlugin', fn = 'status', act = 'hordes'},
    {key = 'reaper', name = 'Reaper', role = 'Bosses', g = 'ReaperPlugin', fn = 'status', act = 'bosses'},
    {key = 'wonder', name = 'WonderCity', role = 'Undercity', g = 'WonderCityPlugin', fn = 'get_status', act = 'undercity'},
    {key = 'arkham', name = 'ArkhamAsylum', role = 'The Pit', g = 'ArkhamAsylumPlugin', fn = 'get_status', act = 'pit'},
    {key = 'raven', name = 'SilentRaven', role = 'Whisper rewards', g = 'SilentRavenPlugin', fn = 'get_status', act = 'whispers'},
}
M.BY_ACT = {}
M.BY_KEY = {}
for _, p in ipairs(M.LIST) do
    M.BY_KEY[p.key] = p
    if p.act then M.BY_ACT[p.act] = p.key end
end
-- Event source -> plugin key.
M.SOURCE = {arkham = 'arkham', wondercity = 'wonder', hordedev = 'hordedev', reaper = 'reaper',
    helltide = 'helltide', rosie = 'rosie', silentraven = 'raven', warpug = 'warpug', warpigs = 'warpigs',
    batmobile = 'batmobile'}

local function call(obj, fn)
    if type(obj) ~= 'table' then return nil end
    local f = obj[fn]
    if type(f) ~= 'function' then return nil end
    local ok, v = pcall(f)
    if ok then return v end
    return nil
end

local function text(v)
    if type(v) == 'string' then return v end
    if type(v) == 'table' and type(v.name) == 'string' then
        local s = v.name
        if type(v.status) == 'string' and v.status ~= '' then s = s .. ' (' .. v.status .. ')' end
        return s
    end
    return nil
end

local function read_one(p)
    local g = rawget(_G, p.g)
    local r = {present = type(g) == 'table'}
    if not r.present then return r end
    if p.key == 'batmobile' then
        r.enabled = true
        r.owner = call(g, 'get_owner')
        r.busy = r.owner ~= nil
        r.trapped = call(g, 'is_trapped') == true
        r.giving_up = call(g, 'is_giving_up') == true
        return r
    end
    local st = call(g, p.fn)
    if type(st) ~= 'table' then r.unreadable = true; return r end
    r.st = st
    r.enabled = st.enabled == true
    r.busy = st.in_run == true or st.busy == true or st.running == true or st.trigger_tasks == true
    if type(st.version) == 'string' then r.ver = st.version:gsub('^v', '') end
    local task = text(st.task) or (type(st.state) == 'string' and st.state) or (type(st.status) == 'string' and st.status)
    if task then r.task = (task:gsub('^Current Task: ', '')) end
    -- QQT_Warpigz_v3 3.3.3 (WarRoom 1.0.3): LooteerPlugin.status() is not read:
    -- it runs Rosie's pickup Settings.update() and expires other plugins'
    -- pickup pauses, and nothing here used its result.
    return r
end

function M.read_all()
    local out = {}
    for _, p in ipairs(M.LIST) do
        local ok, r = pcall(read_one, p)
        out[p.key] = ok and r or {present = false}
    end
    return out
end

local function reason(v, fallback)
    if type(v) == 'string' and v ~= '' then return v end
    return fallback
end

-- {key=, level=, plugin=, code=, text=} for what the statuses report now.
function M.conditions(reads)
    local out = {}
    local function add(plugin, code, level, msg) out[#out + 1] = {key = plugin .. ':' .. code, plugin = plugin,
        code = code, level = level, text = msg} end
    local r = reads.rosie
    if r and r.st then
        if r.st.stuck then add('rosie', 'town_stuck', 'warn', 'Town trip stuck: ' .. reason(r.st.stuck_reason, 'unknown reason')) end
        if (tonumber(r.st.fail_streak) or 0) >= 3 then
            add('rosie', 'town_failures', 'warn', 'Town trips failed ' .. tostring(r.st.fail_streak) .. ' times in a row')
        end
    end
    r = reads.hordedev
    if r and r.st and r.enabled and r.st.fault then add('hordedev', 'fault', 'error', 'Horde fault: ' .. reason(r.st.fault, 'unknown')) end
    r = reads.reaper
    if r and r.st and r.enabled and r.st.failed then
        add('reaper', 'failure', 'warn', 'Boss rotation failed: ' .. reason(r.st.failure_reason, reason(r.st.last_error, 'unknown')))
    end
    r = reads.wonder
    if r and r.st and r.enabled and r.st.reward_failed then add('wonder', 'reward_failed', 'warn', 'Undercity reward chest failed') end
    r = reads.batmobile
    if r and r.present then
        if r.trapped then add('batmobile', 'stuck', 'warn', 'Navigation trapped (stuck)') end
        if r.giving_up then add('batmobile', 'give_up', 'warn', 'Navigation is giving up on its target') end
    end
    for _, p in ipairs(M.LIST) do
        local rr = reads[p.key]
        if rr and rr.present and rr.unreadable then add(p.key, 'status', 'info', p.name .. ' status is unreadable') end
    end
    return out
end

return M
