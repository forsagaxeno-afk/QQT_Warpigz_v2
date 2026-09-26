-- QQT_Warpigz_v2 local patch (Rosie 1.0.7, live 2.3.0-rc.8/rc.9): Season
-- 14/15 Mythic Uniques report rarity 6 like Uniques.
-- Game data: a Mythic is a Unique (eMagicType 2) with the item quality
-- modifier "Mythic" (5); an S15 Mythic form keeps the Unique's SNO. The only
-- host-visible marker seen live (dump of "Condemnation", Ancestral Mythic
-- Unique Dagger) is the upgrade affix S14_Mythic_UniquePotency (hash 2628989).
-- Every marker here only ever promotes an item to mythic (keep / pick up);
-- none of them can make Rosie skip, sell or salvage an item.
local M = {}

local MARK_HASHES = { [2628989] = true }
-- Any affix whose internal name contains "Mythic" (case-sensitive). No affix
-- referenced by an item definition carries that word, but affixes added by
-- the quality modifier are not referenced there either (the potency affix
-- itself is not), so this is a keep-direction guess: the probe line names the
-- affix that matched. "Potency" alone is NOT a marker (ordinary affixes such
-- as UNIQUE_Double_Damage_Tag_Generic_Potency carry it).
local MARK_WORD = 'Mythic'

-- S14 re-issues of the iconic Mythics: Unique magic type with the Mythic
-- modifier forced by definition (eForcedItemQualityModifier 5). The catalog
-- lists them as quality "unique"; they are iconic mythics, not forms.
M.MYTHIC_SNOS = {
    [2629581] = 'Ring of Starless Skies', [2646271] = 'Doombringer',
    [2646273] = "El'Druin, Sword of Justice", [2646275] = 'Shattered Vow',
    [2646277] = 'Ahavarion, Spear of Lycander', [2646279] = 'The Grandfather',
    [2646281] = 'Melted Heart of Selig', [2646283] = 'Shroud of False Death',
    [2646285] = "Tyrael's Might", [2646287] = 'Nesekem, the Herald',
    [2646289] = "Andariel's Visage", [2646291] = 'Harlequin Crest',
    [2646293] = 'Heir of Perdition', [2646295] = "The Cow King's Crown",
}
function M.is_mythic_sno(sno) return sno ~= nil and M.MYTHIC_SNOS[sno] ~= nil end

local function affix_name(affix)
    local ok, name = pcall(function()
        if type(affix.get_name) == 'function' then return affix:get_name() end
        return affix.name
    end)
    return ok and type(name) == 'string' and name or nil
end
local function affix_hash(affix)
    local ok, hash = pcall(function() return affix.affix_name_hash end)
    return ok and type(hash) == 'number' and hash or nil
end
local function affix_is_mark(affix)
    if MARK_HASHES[affix_hash(affix) or -1] then return true end
    local name = affix_name(affix)
    return name ~= nil and name:find(MARK_WORD, 1, true) ~= nil
end

-- The affix list, or nil when the host cannot read it.
local function affixes_of(obj)
    if obj == nil then return nil end
    local ok, affixes = pcall(function() return obj:get_affixes() end)
    if not ok or type(affixes) ~= 'table' then return nil end
    return affixes
end

-- The marking affix (name or hash as text), or nil.
function M.mark_of(obj)
    local affixes = affixes_of(obj)
    if not affixes then return nil end
    for _, affix in pairs(affixes) do
        if affix ~= nil and affix_is_mark(affix) then
            return affix_name(affix) or tostring(affix_hash(affix))
        end
    end
    return nil
end
function M.has_mark(obj) return M.mark_of(obj) ~= nil end

-- Mythic form of an ordinary Unique: rarity 6 plus the upgrade mark.
function M.is_mythic_form(obj, rarity)
    return rarity == 6 and M.has_mark(obj)
end

-- Live (Uber Mephisto, rc.8): "Skipped Helm | sno=2647147 rarity=6
-- ancestral=true GA=0 ... threshold=unique_general:2". Such a reading cannot
-- tell a plain Unique from a Mythic. Returns the reason, or nil when the item
-- can be judged: affixes unreadable, none listed, or an Ancestral item that
-- reads no Greater Affix (ga_count 0; pass nil to skip that test).
function M.undecided(obj, ga_count)
    local affixes = affixes_of(obj)
    if not affixes then return 'affixes unreadable' end
    if next(affixes) == nil then return 'no affixes listed' end
    if ga_count == 0 then
        local ok, ancestral = pcall(function() return obj:is_ancestral() end)
        if ok and ancestral == true then return 'Ancestral, 0 Greater Affixes read' end
    end
    return nil
end

-- The number of listed affixes, or nil when the host cannot read them
-- (describe() prints it).
function M.affix_count(obj)
    local affixes = affixes_of(obj)
    if not affixes then return nil end
    local n = 0
    for _ in pairs(affixes) do n = n + 1 end
    return n
end

-- QQT_Warpigz_v2 local patch: diagnostics only. Item_Quality_Modifier_Bits
-- (qbits) is LOG ONLY: never a decision input until one live log shows its
-- layout on a known Mythic and a plain Unique.
local function attr(obj, name)
    local ok, v = pcall(function() return obj:get_attribute(name) end)
    if ok and type(v) == 'number' and v == v then return v end
    return nil
end
function M.probe(obj)
    local function call(name)
        local ok, v = pcall(function() return obj[name](obj) end)
        if ok then return v end
        return nil
    end
    local display = call('get_display_name')
    local parts = {
        'name=' .. tostring(call('get_name')),
        'display=' .. (type(display) == 'string' and string.format('%q', display:sub(1, 160)) or tostring(display)),
        'ancestral=' .. tostring(call('is_ancestral')),
        'sacred=' .. tostring(call('is_sacred')),
        'qbits=' .. tostring(attr(obj, 'Item_Quality_Modifier_Bits')),
        'qlevel=' .. tostring(attr(obj, 'Item_Quality_Level')),
        'gaattr=' .. tostring(attr(obj, 'Item_Greater_Affix_Count')),
        'ip=' .. tostring(attr(obj, 'Item_Power_Total')),
    }
    local affixes = affixes_of(obj)
    if not affixes then
        parts[#parts + 1] = 'affixes=unreadable'
    else
        local list, n = {}, 0
        for _, affix in pairs(affixes) do
            if affix ~= nil then
                n = n + 1
                if n <= 12 then list[#list + 1] = tostring(affix_name(affix)) .. '#' .. tostring(affix_hash(affix)) end
            end
        end
        parts[#parts + 1] = 'affixes=' .. n .. ' [' .. table.concat(list, ', ') .. ']'
        parts[#parts + 1] = 'mark=' .. tostring(M.mark_of(obj))
    end
    return (table.concat(parts, ' '):gsub('[\r\n]', ' '))
end

return M
