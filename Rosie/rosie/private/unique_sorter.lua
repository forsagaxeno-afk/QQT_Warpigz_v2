-- QQT_Warpigz_v2 local patch (Rosie 1.0.8, 2.3.0-rc.11): "Pick up every
-- Unique (sort in the bag)".
-- A fresh ground drop exposes no affixes until it was picked up once (QQT
-- docs), so on the ground a plain Unique and its S15 Mythic form (same SNO,
-- rarity 6) look the same. With the option on, pickup takes every Unique and
-- every definite Mythic; the bag copy then shows what it is.
--  * Mode "Handle in town" (0): nothing is dropped; the town rules decide.
--  * Mode "Drop on the ground" (1): the bag sorter drops a plain Unique the
--    town rules would salvage or sell, one item per DROP_GAP s, records it in
--    the blacklist first (pickup never takes it again), confirms within
--    CONFIRM s that it left the bag and retries at most RETRIES times; then it
--    leaves the item to the town trip. Mythics (rc.10 town logic plus the
--    pickup catalog), locked items and every item a keep rule protects stay.
--    A hold (town trip, any town, pause) keeps the try count; a given-up
--    item stays given up until it leaves the bag (or GIVEN_UP_TTL s).
-- The sorter never holds the Looter adapter busy, never requests a town trip
-- and never runs during one. While it may act, the census leaves the items
-- it is about to drop out of "bag full" (pending_drop_count).
local Blacklist = require('rosie.private.blacklist')
local MythicForm = require('rosie.private.mythic_form')
local Catalog = require('rosie.data.items')
local CustomItems = require('rosie.private.pickup.data.custom_items')
local M = {}
M.MODE_TOWN, M.MODE_DROP = 0, 1
M.DROP_GAP = 0.6
M.CONFIRM = 2
M.RETRIES = 2
M.PICKUP_REASON = 'accepted: every Unique is taken (sorted in the bag)'
M.GIVEN_UP_TTL = 60 * 60
M.MEMORY_CAP = 512

local toggle, mode_widget = nil, nil
local deps = nil
local pending = nil
local next_drop = 0
-- fp -> time. done: dropped (TTL Blacklist.TTL); given_up: left to town
-- (kept across world changes and town trips; forgotten when the item is no
-- longer in the bag or after GIVEN_UP_TTL s). Both capped at MEMORY_CAP.
local done, given_up, logged = {}, {}, {}
local done_count, given_up_count, logged_count = 0, 0, 0
local allowed_last = false
M.stats = {drops = 0, attempts = 0, failures = 0, given_up = 0, kept = 0}

local function widget_get(w)
    if w == nil then return nil end
    local ok, v = pcall(function() return w:get() end)
    if ok then return v end
    return nil
end
-- The two menu widgets (Rosie's master menu owns them).
function M.bind(pick_all_widget, mode)
    toggle, mode_widget = pick_all_widget, mode
end
-- Town helpers bound once at load (utils, tracker, lifecycle).
function M.configure(d) deps = d end
function M.pick_all() return widget_get(toggle) == true end
function M.mode()
    local v = widget_get(mode_widget)
    return v == M.MODE_DROP and M.MODE_DROP or M.MODE_TOWN
end
function M.drop_mode() return M.pick_all() and M.mode() == M.MODE_DROP end

local function call(obj, name, ...)
    if obj == nil then return nil end
    local ok, fn = pcall(function() return obj[name] end)
    if not ok or type(fn) ~= 'function' then return nil end
    local ok2, v = pcall(fn, obj, ...)
    if ok2 then return v end
    return nil
end
local function remember(set, key)
    if logged_count >= M.MEMORY_CAP then logged, logged_count = {}, 0 end
    if set[key] then return false end
    set[key] = true
    if set == logged then logged_count = logged_count + 1 end
    return true
end
local function mark_done(fp, t)
    if done_count >= M.MEMORY_CAP then done, done_count = {}, 0 end
    if not done[fp] then done_count = done_count + 1 end
    done[fp] = t
end
local function mark_given_up(fp, t)
    if given_up_count >= M.MEMORY_CAP then given_up, given_up_count = {}, 0 end
    if not given_up[fp] then given_up_count = given_up_count + 1 end
    given_up[fp] = t
end
local function name_of(item)
    local n = call(item, 'get_display_name') or call(item, 'get_name') or call(item, 'get_skin_name')
    return (tostring(n or 'unknown'):gsub('[\r\n]', ' '):gsub('{[^}]*}', ''):gsub('%s+$', ''):sub(1, 80))
end
-- Why an item is a Mythic (the rc.10 town definition plus the pickup
-- catalog / uber list), or nil.
function M.mythic_reason(item)
    local rarity = call(item, 'get_rarity')
    local sno = call(item, 'get_sno_id')
    if type(rarity) == 'number' and rarity >= 8 then return 'rarity ' .. tostring(rarity) end
    local utils = deps and deps.utils
    if utils and type(utils.mythics) == 'table' and utils.mythics[sno] ~= nil then return 'iconic Mythic' end
    if MythicForm.is_mythic_sno(sno) then return 'S14 iconic' end
    local okm, mark = pcall(MythicForm.mark_of, item)
    if okm and mark then return tostring(mark) end
    local meta = sno ~= nil and Catalog.by_id[sno] or nil
    if meta and meta.kind == 'equipment' and meta.quality == 'mythic' then return 'catalog Mythic' end
    if sno ~= nil and CustomItems.ubers and CustomItems.ubers[sno] ~= nil then return 'uber' end
    return nil
end

-- The sorter may act now (the caller already checked Rosie on, pickup on and
-- not paused).
local function in_town_attr()
    local ok, v = pcall(function()
        local attrs = rawget(_G, 'attributes')
        if type(attrs) ~= 'table' or attrs.PLAYER_IN_TOWN_LEVEL_AREA == nil then return false end
        return get_local_player():get_attribute(attrs.PLAYER_IN_TOWN_LEVEL_AREA) == 1
    end)
    return ok and v == true
end
local function town_idle()
    local life, tracker, utils = deps.lifecycle, deps.tracker, deps.utils
    if life.busy() then return false, 'town trip' end
    if tracker.trigger_tasks == true or tracker.external_trigger == true or tracker.manual_trigger == true then return false, 'town trip' end
    if tracker.teleport == true and tracker.teleport_done ~= true and tracker.teleport_failed ~= true then return false, 'teleport' end
    if tracker.external_pause == true then return false, 'town paused' end
    local player = get_local_player()
    if not player or call(player, 'is_dead') ~= false then return false, 'no living player' end
    local world = get_current_world()
    local zone = call(world, 'get_current_zone_name')
    if not zone or zone == '[sno none]' then return false, 'loading' end
    -- Rosie's home town, and any town the game flags (Caldeum, Kurast, ...).
    local okt, in_town = pcall(utils.is_in_town)
    if not okt or in_town ~= false or in_town_attr() then return false, 'in town' end
    local okc, chat = pcall(is_chat_open)
    if not okc or chat ~= false then return false, 'chat open' end
    local okv, vendor = pcall(function() return loot_manager.is_in_vendor_screen() end)
    if okv and vendor == true then return false, 'vendor screen' end
    return true
end

local function bag()
    local player = get_local_player()
    local items = call(player, 'get_inventory_items')
    return type(items) == 'table' and items or nil
end
-- Bag copies of the pending item (only rarity-6 items of its SNO are read).
local function count_fp(items, fp, sno)
    local n = 0
    for _, it in pairs(items) do
        if call(it, 'get_rarity') == 6 and (sno == nil or call(it, 'get_sno_id') == sno) then
            local _, f = Blacklist.fingerprint(it)
            if f == fp then n = n + 1 end
        end
    end
    return n
end
-- A bag item the sorter may drop, plus its fingerprint. `quiet`: no log.
local function candidate(item, quiet)
    local utils = deps.utils
    local rarity = call(item, 'get_rarity')
    if rarity ~= 6 then return nil end
    local item_type = utils.get_item_type(item)
    if item_type == 'talisman_seal' or item_type == 'talisman_charm' or item_type == 'unknown' then return nil end
    if not utils.can_modify_item(item) then return nil end
    local sno, fp, n = Blacklist.fingerprint(item)
    if not fp or not n or n == 0 then return nil end
    local why = M.mythic_reason(item)
    if why then
        if not quiet and remember(logged, 'kept|' .. fp) then
            M.stats.kept = M.stats.kept + 1
            console.print(string.format('[Rosie sort] Kept Mythic %s (mark=%s) sno=%s', name_of(item), why, tostring(sno)))
        end
        return nil
    end
    if given_up[fp] or done[fp] then return nil end
    local enum = utils.item_enum
    if not (utils.is_salvage_or_sell(item, enum.SALVAGE) or utils.is_salvage_or_sell(item, enum.SELL)) then return nil end
    return fp, sno
end

local function attempt(item, fp, sno, items)
    local now = get_time_since_inject()
    next_drop = now + M.DROP_GAP
    local here = call(get_local_player(), 'get_position')
    local name = name_of(item)
    -- Recorded BEFORE the drop: the ground copy may appear this very frame.
    if not Blacklist.record(item, here, name) then
        mark_given_up(fp, now)
        return
    end
    local before = count_fp(items, fp, sno)
    pending = pending and pending.fp == fp and pending or {fp = fp, sno = sno, name = name, tries = 0}
    pending.before = before
    pending.tries = pending.tries + 1
    pending.deadline = now + M.CONFIRM
    M.stats.attempts = M.stats.attempts + 1
    local ok, result = pcall(loot_manager.drop_item, item)
    if not ok or result == false then
        M.stats.failures = M.stats.failures + 1
        pending.deadline = now + M.DROP_GAP
        if not pending.error_logged then
            pending.error_logged = true
            console.print(string.format('[Rosie sort] Drop of %s refused by the host: %s', name, tostring(result)))
        end
    end
end

local function dropped(p)
    mark_done(p.fp, get_time_since_inject())
    M.stats.drops = M.stats.drops + 1
    console.print(string.format('[Rosie sort] Dropped plain Unique %s sno=%s fp=%s', p.name, tostring(p.sno), p.fp))
end
local function settle(items, now)
    local p = pending
    if count_fp(items, p.fp, p.sno) < p.before then
        pending = nil
        dropped(p)
        return true
    end
    if now < p.deadline then return true end
    if p.tries > M.RETRIES then
        pending = nil
        mark_given_up(p.fp, now)
        M.stats.given_up = M.stats.given_up + 1
        Blacklist.forget(p.fp)
        console.print(string.format('[Rosie sort] Could not drop %s after %d attempts; it is left to the town trip.', p.name, p.tries))
        return false
    end
    return false
end
-- A hold (town trip, teleport, town, pause) interrupted the pending drop: its
-- try count is kept. Back in the field, an item still in the bag continues
-- where it stopped; an item that left meanwhile (a trip may have sold it) is
-- not reported as a drop and its list entry stays (the drop may have happened).
local function resume(items, now)
    local p = pending
    local town = p.town_hold
    p.held, p.town_hold = nil, nil
    local n = count_fp(items, p.fp, p.sno)
    if n < p.before then
        pending = nil
        -- Only a trip can sell or salvage it; after any other hold it dropped.
        if not town then dropped(p) end
        return
    end
    p.before, p.deadline = n, math.min(p.deadline, now)
end
local TOWN_HOLDS = {['town trip'] = true, teleport = true, ['in town'] = true, loading = true}
local function hold(why)
    if not pending then return end
    pending.held = true
    if TOWN_HOLDS[why] then pending.town_hold = true end
end
-- Mode switched off with a drop pending: an item still in the bag is
-- forgotten by the list; one that left is reported as dropped.
local function release_pending()
    local p = pending
    pending = nil
    local items = bag()
    if items and count_fp(items, p.fp, p.sno) < p.before and not p.held then dropped(p); return end
    Blacklist.forget(p.fp)
end
-- given_up / done memory: TTLs, and a given-up item no longer in the bag is
-- forgotten.
local function prune_memory(items, now)
    for fp, at in pairs(done) do
        if now - at >= Blacklist.TTL or now < at then done[fp] = nil; done_count = done_count - 1 end
    end
    if given_up_count == 0 then return end
    local present = {}
    for _, it in pairs(items) do
        if call(it, 'get_rarity') == 6 then
            local _, f = Blacklist.fingerprint(it)
            if f then present[f] = true end
        end
    end
    for fp, at in pairs(given_up) do
        if not present[fp] or now - at >= M.GIVEN_UP_TTL or now < at then given_up[fp] = nil; given_up_count = given_up_count - 1 end
    end
end

-- One sorter step (controller update). `allowed`: Rosie on, pickup on, not
-- paused. Returns what it did, for tests and diagnostics.
function M.update(allowed)
    allowed_last = false
    if not deps then return 'unconfigured' end
    Blacklist.sync_world()
    if not M.drop_mode() then
        if pending then release_pending() end
        return 'off'
    end
    if not allowed then
        if pending then
            local okb, busy = pcall(deps.lifecycle.busy)
            hold((not okb or busy) and 'town trip' or 'held')
        end
        return 'held'
    end
    allowed_last = true
    Blacklist.observe()
    local now = get_time_since_inject()
    -- Nothing pending and the next scan is not due: no host reads.
    if not pending and now < next_drop then return 'spacing' end
    local idle, why = town_idle()
    if not idle then
        hold(why)
        return why
    end
    local items = bag()
    if not items then return 'bag unreadable' end
    if pending and pending.held then resume(items, now) end
    if pending then
        if settle(items, now) then return 'waiting' end
        if not pending then return 'gave up' end
    end
    if now < next_drop then return 'spacing' end
    prune_memory(items, now)
    for _, item in pairs(items) do
        local fp, sno = candidate(item)
        if fp and (not pending or pending.fp == fp) then
            attempt(item, fp, sno, items)
            return 'dropping'
        end
    end
    -- The pending item is no longer a candidate (locked meanwhile, rules
    -- changed): it is still in the bag, so its entry is forgotten.
    if pending then Blacklist.forget(pending.fp); pending = nil end
    next_drop = now + 0.5
    return 'idle'
end
-- Bag items the sorter is about to drop (the census keeps them out of the
-- "bag full" count so a pile of plain Uniques does not start a town trip).
-- 0 unless mode Drop is on, the sorter may act and no town trip is live.
function M.pending_drop_count(items)
    if not deps or not allowed_last or not M.drop_mode() or type(items) ~= 'table' then return 0 end
    if not town_idle() then return 0 end
    local n = 0
    for _, item in pairs(items) do
        local ok, fp = pcall(candidate, item, true)
        if ok and fp then n = n + 1 end
    end
    return n
end
-- Clears the per-item memory (pending drop, dropped and given-up items).
function M.reset()
    pending = nil
    done, given_up = {}, {}
    done_count, given_up_count = 0, 0
end
return M
