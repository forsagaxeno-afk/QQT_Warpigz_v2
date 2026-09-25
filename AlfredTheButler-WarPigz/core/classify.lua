-- WarPigz item classification for Alfred.
--
-- Every QQT call on an item is pcall-guarded: a missing method or a thrown
-- error reads as "unknown" instead of crashing the inventory scan.
--
-- Rarity (QQT runtime get_rarity()): 0-1 common, 2-3 magic, 4 rare,
-- 5 legendary, 6 unique, 7 set, 8 mythic. The Mythic Uniques introduced with
-- the talisman season report rarity 8 and are not in any fixed SNO list, so a
-- mythic is "rarity 8 OR a SNO the item database lists as mythic/uber".
--
-- Charms and seals are detected by the item database group (by SNO), then by
-- skin-name pattern (Talisman_Seal, Generic_Charm_, talisman+seal/charm),
-- then (items from the talisman bag only) by display name.
local classify = {}

local loaded, db = pcall(require, 'data.item_db')
if not loaded or type(db) ~= 'table' then db = {} end
if type(db.mythic) ~= 'table' then db.mythic = {} end
if type(db.talisman) ~= 'table' then db.talisman = {} end
if type(db.patterns) ~= 'table' then db.patterns = {} end
classify.db = db
classify.db_loaded = loaded and next(db.talisman) ~= nil

-- Self-learning catalog: unique/set/mythic charms and seals and mythic
-- equipment seen in game but missing from the database (items added by a
-- patch newer than the database) are remembered in data/seen_items.lua in
-- this plugin's folder and merged into the database on the next load, so
-- they appear in the GUI lists. Only fixed-rarity items are learned: a
-- rolled-rarity charm must not be pinned to the rarity of one drop.
classify.learned, classify.learned_dirty = {}, false
local function seen_path()
    local path = type(package) == 'table' and type(package.path) == 'string' and package.path or ''
    local root = (path:match('^([^;]*)') or ''):gsub('%?.*$', '')
    local sep = (root:find('/', 1, true) and not root:find('\\', 1, true)) and '/' or '\\'
    return root .. 'data' .. sep .. 'seen_items.lua'
end
classify.seen_path = seen_path
local function merge_learned(sno, entry)
    if type(sno) ~= 'number' or type(entry) ~= 'table' or type(entry.n) ~= 'string' then return end
    if entry.g == 'charm' or entry.g == 'seal' then
        if not db.talisman[sno] then db.talisman[sno] = {n = entry.n, g = entry.g, r = entry.r} end
    end
    if entry.r == 8 and not db.mythic[sno] then db.mythic[sno] = {n = entry.n, g = entry.g or 'unique'} end
    classify.learned[sno] = entry
end
do
    local ok, chunk = pcall(loadfile, seen_path())
    if ok and type(chunk) == 'function' then
        local run_ok, seen = pcall(chunk)
        if run_ok and type(seen) == 'table' then
            for sno, entry in pairs(seen) do merge_learned(sno, entry) end
        end
    end
end

local function clean_name(display)
    if type(display) ~= 'string' then return nil end
    local name = display:gsub('%b{}', ''):gsub('%b<>', ''):gsub('%s+', ' '):match('^%s*(.-)%s*$')
    if name == '' or #name > 80 then return nil end
    return name
end

-- Remember a fixed-rarity talisman or mythic the database does not know.
function classify.learn(info)
    local sno = info and info.sno
    if type(sno) ~= 'number' or info.rarity_source ~= 'runtime' or classify.learned[sno] then return end
    local talisman = (info.kind == 'charm' or info.kind == 'seal') and info.rarity >= 6
    local mythic = info.rarity == 8
    if not talisman and not mythic then return end
    if (talisman and db.talisman[sno]) or (not talisman and db.mythic[sno]) then return end
    local name = clean_name(info.display)
    if not name then return end
    merge_learned(sno, {n = name, g = info.kind or 'unique', r = info.rarity})
    classify.learned_dirty = true
end

-- Lua source of the learned catalog (sorted, deterministic).
function classify.learned_source()
    local ids = {}
    for sno in pairs(classify.learned) do ids[#ids + 1] = sno end
    table.sort(ids)
    local lines = {'-- Items Alfred has seen that its database does not list (written by Alfred).', 'return {'}
    for _, sno in ipairs(ids) do
        local e = classify.learned[sno]
        lines[#lines + 1] = string.format('    [%d] = {n=%q,g=%q,r=%d},', sno, e.n, tostring(e.g), tonumber(e.r) or 0)
    end
    lines[#lines + 1] = '}'
    return table.concat(lines, '\n') .. '\n'
end

classify.KEEP, classify.SALVAGE, classify.SELL = 0, 1, 2
classify.action_names = {[0] = 'keep', [1] = 'salvage', [2] = 'sell'}
classify.TIERS = {'magic', 'rare', 'legendary', 'unique', 'set', 'mythic'}
classify.TIER_DEFAULTS = {magic = 1, rare = 1, legendary = 0, unique = 0, set = 0, mythic = 0}

local function index(object, key) return object[key] end

-- object:method(...) or nil when the method is missing or throws.
local function call(object, method, ...)
    if object == nil then return nil end
    local ok, fn = pcall(index, object, method)
    if not ok or type(fn) ~= 'function' then return nil end
    local ok2, value = pcall(fn, object, ...)
    if ok2 then return value end
    return nil
end
classify.call = call

function classify.get_rarity(item)
    local rarity = call(item, 'get_rarity')
    if type(rarity) ~= 'number' then
        local info = call(item, 'get_item_info')
        if info ~= nil then rarity = call(info, 'get_rarity') end
    end
    if type(rarity) == 'number' then return rarity end
    return nil
end

function classify.greater_affix_count(display)
    local count = 0
    if type(display) == 'string' then
        for _ in display:gmatch('GreaterAffix') do count = count + 1 end
    end
    return count
end

local function lower(text) return type(text) == 'string' and text:lower() or '' end

-- 'charm' | 'seal' | nil, plus how it was detected.
function classify.talisman_kind(sno, skin, display, in_talisman_bag)
    local entry = sno and db.talisman[sno]
    if entry and (entry.g == 'charm' or entry.g == 'seal') then return entry.g, 'db' end
    if type(skin) == 'string' and skin ~= '' then
        for _, pattern in ipairs(db.patterns) do
            if type(pattern.p) == 'string' then
                local ok, found = pcall(string.find, skin, pattern.p)
                if ok and found and (pattern.g == 'charm' or pattern.g == 'seal') then return pattern.g, 'skin' end
            end
        end
        local low = skin:lower()
        if low:find('talisman', 1, true) or low:find('generic_charm', 1, true) then
            if low:find('seal', 1, true) then return 'seal', 'skin' end
            if low:find('charm', 1, true) then return 'charm', 'skin' end
        end
    end
    if in_talisman_bag then
        local low = lower(display)
        if low:find('seal', 1, true) then return 'seal', 'display' end
        if low:find('charm', 1, true) then return 'charm', 'display' end
        return 'charm', 'talisman bag'
    end
    return nil, nil
end

-- Rarity 8, a database mythic/uber, or (keeping is the safe side) a skin or
-- display name that says so ("Mythic", "_Uber_").
function classify.is_mythic(sno, rarity, skin, display)
    if rarity == 8 then return true, 'rarity 8' end
    if sno and db.mythic[sno] then return true, 'item db' end
    local low = lower(skin)
    if low:find('mythic', 1, true) or low:find('_uber', 1, true) then return true, 'skin name' end
    if lower(display):find('mythic', 1, true) then return true, 'display name' end
    return false, nil
end

-- One snapshot of everything Alfred needs from an item.
function classify.read(item, in_talisman_bag)
    local info = {item = item}
    info.sno = call(item, 'get_sno_id')
    info.skin = call(item, 'get_name')
    info.display = call(item, 'get_display_name')
    local rarity = classify.get_rarity(item)
    local entry = info.sno and db.talisman[info.sno]
    info.rarity_source = rarity and 'runtime' or nil
    if rarity == nil then
        if info.sno and db.mythic[info.sno] then rarity = 8
        elseif entry then rarity = entry.r end
        info.rarity_source = rarity and 'item db' or 'unknown'
    end
    info.rarity = rarity or 0
    info.ancestral = call(item, 'is_ancestral') == true
    info.locked = call(item, 'is_locked') == true
    info.junk = call(item, 'is_junk') == true
    info.ga = classify.greater_affix_count(info.display)
    info.kind, info.kind_source = classify.talisman_kind(info.sno, info.skin, info.display, in_talisman_bag)
    info.mythic, info.mythic_source = classify.is_mythic(info.sno, info.rarity, info.skin, info.display)
    info.db_name = (entry and entry.n) or (info.sno and db.mythic[info.sno] and db.mythic[info.sno].n) or nil
    classify.learn(info)
    return info
end

function classify.tier(rarity)
    if rarity >= 8 then return 'mythic' end
    if rarity == 7 then return 'set' end
    if rarity == 6 then return 'unique' end
    if rarity == 5 then return 'legendary' end
    if rarity == 4 then return 'rare' end
    return 'magic'
end

-- nil when the loot filter is unreadable, else true/false.
local function loot_filtered(item)
    local value = call(item, 'is_filtered_by_loot_filter')
    if type(value) == 'boolean' then return value end
    return nil
end

local function matching_affixes(item, selected)
    local matched = 0
    local affixes = call(item, 'get_affixes')
    if type(affixes) ~= 'table' or type(selected) ~= 'table' then return 0 end
    for _, affix in pairs(affixes) do
        local ok, hash = pcall(index, affix, 'affix_name_hash')
        if ok and hash and selected[hash] then matched = matched + 1 end
    end
    return matched
end
classify.matching_affixes = matching_affixes

-- Charm / seal decision. s = settings (s.mythic_always_keep,
-- s.loot_filter_mode, s.talisman[kind] = {tier, min_ga, keep_list_on,
-- keep_list, affix_filter, affix_count, affix, loot_filter}).
function classify.talisman_action(info, s)
    if info.locked then return classify.KEEP, 'favorited' end
    if info.mythic and s.mythic_always_keep ~= false then return classify.KEEP, 'mythic (always kept)' end
    -- rarity unreadable and not in the item database: rarity 0 would be the
    -- magic tier (salvaged by default), so keep instead (the safe side)
    if info.rarity_source == 'unknown' then return classify.KEEP, 'rarity unknown' end
    local cfg = type(s.talisman) == 'table' and s.talisman[info.kind] or nil
    if type(cfg) ~= 'table' then return classify.KEEP, 'no settings' end
    local tier = classify.tier(info.rarity)
    local tiers = type(cfg.tier) == 'table' and cfg.tier or classify.TIER_DEFAULTS
    local action = tiers[tier]
    if action ~= classify.SALVAGE and action ~= classify.SELL then action = classify.KEEP end
    if s.loot_filter_mode or cfg.loot_filter then
        local filtered = loot_filtered(info.item)
        if filtered == false then return classify.KEEP, 'loot filter keeps it' end
        if filtered == true then
            if action == classify.SELL then return classify.SELL, 'loot filter' end
            return classify.SALVAGE, 'loot filter'
        end
    end
    if cfg.keep_list_on and type(cfg.keep_list) == 'table' and info.sno and cfg.keep_list[info.sno] then
        return classify.KEEP, 'keep list'
    end
    if (cfg.min_ga or 0) > 0 and info.ga >= cfg.min_ga then return classify.KEEP, 'greater affixes' end
    if cfg.affix_filter and matching_affixes(info.item, cfg.affix) >= (cfg.affix_count or 1) then
        return classify.KEEP, 'affix filter'
    end
    return action, tier .. ' action'
end

-- Equipment decision (the SteroidAlfredV2 rules, mythics first).
-- item_type: helm/chest/.../weapon_2h, or cache/tempering/unknown (kept).
function classify.equipment_action(info, item_type, s)
    if info.locked then return classify.KEEP, 'favorited' end
    if item_type == 'cache' or item_type == 'tempering' or item_type == 'unknown' then
        return classify.KEEP, 'not equipment'
    end
    if info.mythic and s.mythic_always_keep ~= false then return classify.KEEP, 'mythic (always kept)' end
    -- unreadable rarity: a Unique or Mythic Unique would otherwise fall to
    -- the non-unique / legendary action
    if info.rarity_source == 'unknown' then return classify.KEEP, 'rarity unknown' end
    if s.loot_filter_mode then
        local filtered = loot_filtered(info.item)
        if filtered == true then return classify.SALVAGE, 'loot filter' end
        return classify.KEEP, 'loot filter keeps it'
    end
    if s.loot_filter_equipment then
        local filtered = loot_filtered(info.item)
        if filtered == true then return classify.SALVAGE, 'loot filter' end
        if filtered == false then return classify.KEEP, 'loot filter keeps it' end
    end
    local is_unique = info.rarity == 6 or info.rarity == 7
    local ga = info.ancestral and info.ga or 0
    if not info.ancestral then
        if info.mythic then return s.ancestral_item_mythic or classify.KEEP, 'mythic action' end
        if info.junk then return s.item_junk, 'junk' end
        if is_unique then return s.item_unique, 'unique action' end
        return s.item_legendary_or_lower, 'non-unique action'
    end
    if info.junk and not info.mythic then return s.ancestral_item_junk, 'junk' end
    if info.mythic then
        if (s.ancestral_mythic_ga_count or 0) > 0 and ga >= s.ancestral_mythic_ga_count then
            return classify.KEEP, 'mythic greater affixes'
        end
        if s.ancestral_unique_filter and type(s.ancestral_mythic) == 'table' and s.ancestral_mythic[info.sno] then
            return classify.KEEP, 'mythic keep list'
        end
        return s.ancestral_item_mythic or classify.KEEP, 'mythic action'
    end
    if is_unique then
        if (s.ancestral_unique_ga_count or 0) > 0 and ga >= s.ancestral_unique_ga_count then
            return classify.KEEP, 'unique greater affixes'
        end
        if s.ancestral_unique_filter and type(s.ancestral_unique) == 'table' and s.ancestral_unique[info.sno] then
            return classify.KEEP, 'unique keep list'
        end
        return s.ancestral_item_unique, 'unique action'
    end
    if (s.ancestral_ga_count or 0) > 0 and ga >= s.ancestral_ga_count then
        if s.ancestral_filter and type(s.ancestral_affix) == 'table' then
            local selected = s.ancestral_affix[item_type]
            local matched = matching_affixes(info.item, selected)
            if matched >= (s.ancestral_affix_count or 1) then return classify.KEEP, 'greater affixes + affixes', matched end
        else
            return classify.KEEP, 'greater affixes'
        end
    end
    return s.ancestral_item_legendary, 'legendary action'
end

-- Lists for the GUI, built from the database.
function classify.mythic_list(groups)
    local list = {}
    for sno, entry in pairs(db.mythic) do
        if groups == nil or groups[entry.g] then
            list[#list + 1] = {sno_id = sno, name = entry.n, description = entry.n, class = {'all'},
                item_type = entry.g}
        end
    end
    table.sort(list, function(a, b) return a.name < b.name or (a.name == b.name and a.sno_id < b.sno_id) end)
    return list
end

function classify.talisman_list(kind, rarities)
    local list = {}
    for sno, entry in pairs(db.talisman) do
        if entry.g == kind and (rarities == nil or rarities[entry.r]) then
            list[#list + 1] = {sno_id = sno, name = entry.n, description = entry.n, class = {'all'},
                item_type = kind == 'seal' and 'Seal' or 'Charm', rarity = entry.r}
        end
    end
    table.sort(list, function(a, b) return a.name < b.name or (a.name == b.name and a.sno_id < b.sno_id) end)
    return list
end

return classify
