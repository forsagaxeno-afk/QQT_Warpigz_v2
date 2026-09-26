-- QQT_Warpigz_v2: Season 15 Mythic forms of ordinary Uniques report the same
-- SNO and rarity 6 as the Unique. The only host-visible difference (live dump,
-- "Condemnation", Ancestral Mythic Unique Dagger) is the upgrade affix
-- S14_Mythic_UniquePotency (hash 2628989). Unreadable affixes never promote.
local M = {}

local MARK_HASHES = { [2628989] = true }
local MARK_PATTERN = 'Mythic_UniquePotency'

local function affix_is_mark(affix)
    local ok, hash = pcall(function() return affix.affix_name_hash end)
    if ok and MARK_HASHES[hash] then return true end
    local named, name = pcall(function()
        if type(affix.get_name) == 'function' then return affix:get_name() end
        return affix.name
    end)
    return named and type(name) == 'string' and name:find(MARK_PATTERN, 1, true) ~= nil
end

-- obj: an item_info (ground) or an inventory item; both expose get_affixes.
function M.has_mark(obj)
    if obj == nil then return false end
    local ok, affixes = pcall(function() return obj:get_affixes() end)
    if not ok or type(affixes) ~= 'table' then return false end
    for _, affix in pairs(affixes) do
        if affix ~= nil and affix_is_mark(affix) then return true end
    end
    return false
end

-- Mythic form of an ordinary Unique: rarity 6 plus the upgrade mark.
function M.is_mythic_form(obj, rarity)
    return rarity == 6 and M.has_mark(obj)
end

return M
