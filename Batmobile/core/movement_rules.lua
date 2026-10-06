-- Movement revamp data model: skill catalog, condition type registry,
-- operators / combinators / cast position modes, and small helpers.
local rules = {}
local movement_cast = require 'core.movement_cast'

-- Bounds on slot pre-allocation. Increasing requires bumping widget counts
-- in gui.lua; keep these in sync.
rules.MAX_RULES                 = 8
rules.MAX_CONDITIONS_PER_RULE   = 5

-- Movement-capable skill catalog. We intersect this against
-- get_equipped_spell_ids() at render time so the picker only shows skills
-- the character actually has on the bar. `needs_raycast` mirrors the LOS
-- requirement Batmobile's existing chain uses for that skill. `range` lets
-- us override the global spell_dist for skills with a known fixed reach
-- (e.g. Warlock movement is hardcoded to 15 in the legacy path).
rules.skill_catalog = {
    -- universal
    { id = 337031,  name = 'Evade',              needs_raycast = false, range = nil },
    -- sorcerer
    { id = 288106,  name = 'Teleport',           needs_raycast = false, range = nil },
    { id = 959728,  name = 'Teleport Enchanted', needs_raycast = false, range = nil },
    -- spiritborn
    { id = 1871821, name = 'Soar',               needs_raycast = false, range = nil },
    { id = 1871761, name = 'Rushing Claw',       needs_raycast = false, range = nil },
    { id = 1663206, name = 'Hunter',             needs_raycast = false, range = nil },
    -- rogue
    { id = 358761,  name = 'Dash',               needs_raycast = false, range = nil },
    -- barbarian
    { id = 196545,  name = 'Leap',               needs_raycast = false, range = nil },
    { id = 204662,  name = 'Charge',             needs_raycast = true,  range = nil },
    -- paladin
    { id = 2329865, name = 'Advance',            needs_raycast = true,  range = nil },
    { id = 2106904, name = 'Falling Star',       needs_raycast = true,  range = nil },
    { id = 2297125, name = 'Arbiter of Justice', needs_raycast = true,  range = nil },
    -- warlock
    { id = 2218211, name = 'Wraith Step',        needs_raycast = false, range = 15 },
    { id = 2221282, name = 'Demonic Slash',      needs_raycast = false, range = 15 },
}

rules.skill_by_id = {}
for _, s in ipairs(rules.skill_catalog) do rules.skill_by_id[s.id] = s end

-- QQT_Warpigz_v3: skills found by their spell NAME (get_name_for_spell)
-- instead of a fixed id, e.g. the Warlock's Rampage (id, name string and
-- cast mode need live confirmation). Each gets a slot after the fixed-id
-- skills with id 0 until an equipped spell's lower-case name contains
-- `match`; skill_by_id then gains that id. Revamp rule engine only: the
-- legacy per-class chain is unchanged.
-- QQT_Warpigz_v3 2.2.7: saved rules store the picker INDEX, so the catalog
-- order is append-only: fixed ids (1-14), Rampage (15), Enigma (16). Do not
-- add entries to name_catalog (that would shift Enigma); append any new
-- skill after Enigma instead.
rules.name_catalog = {
    { match = 'rampage', name = 'Rampage', needs_raycast = false, range = 15 },
}
rules.named_entries = {}
for _, s in ipairs(rules.name_catalog) do
    local entry = { id = 0, name = s.name, needs_raycast = s.needs_raycast, range = s.range, match = s.match }
    rules.named_entries[#rules.named_entries + 1] = entry
    rules.skill_catalog[#rules.skill_catalog + 1] = entry
end
rules.NAMED_TTL = 10
-- Append after name-based skills to preserve every saved picker index.
-- New skills go after this entry (see the name_catalog note above).
local enigma = { id=movement_cast.ENIGMA, name='Enigma Teleport (Mouse 3)',
    needs_raycast=false, input_action=true }
rules.skill_catalog[#rules.skill_catalog+1] = enigma
rules.skill_by_id[enigma.id] = enigma
local static_ids = {}
for id in pairs(rules.skill_by_id) do static_ids[id] = true end
local named_checked_at = nil

-- Resolve the name-matched entries against the equipped spells (protected,
-- at most every NAMED_TTL seconds unless forced).
rules.resolve_named = function (force)
    local okt, now = pcall(get_time_since_inject)
    now = (okt and type(now) == 'number') and now or 0
    if not force and named_checked_at and now - named_checked_at < rules.NAMED_TTL and now >= named_checked_at then
        return
    end
    named_checked_at = now
    if type(get_equipped_spell_ids) ~= 'function' then return end
    local ok, equipped = pcall(get_equipped_spell_ids)
    if not ok or type(equipped) ~= 'table' then return end
    local name_of = nil
    for _, id in pairs(equipped) do
        if type(id) == 'number' and id > 0 and not static_ids[id] then
            if name_of == nil then
                name_of = type(get_name_for_spell) == 'function' and get_name_for_spell or false
            end
            if not name_of then return end
            local okn, name = pcall(name_of, id)
            if okn and type(name) == 'string' and name ~= '' then
                local lower = name:lower()
                for _, entry in ipairs(rules.named_entries) do
                    if entry.id ~= id and lower:find(entry.match, 1, true) then
                        if entry.id ~= 0 and rules.skill_by_id[entry.id] == entry then
                            rules.skill_by_id[entry.id] = nil
                        end
                        entry.id = id
                        rules.skill_by_id[id] = entry
                    end
                end
            end
        end
    end
end

-- Condition types. The combo at index 1 ("none") is the natural default,
-- meaning a condition row is empty / has no effect.
rules.condition_types = {
    { key = 'none',              label = '(none)',                  uses_op = false, uses_buff = false, uses_radius = false },
    { key = 'buff_active',       label = 'Buff is active',          uses_op = false, uses_buff = true,  uses_radius = false },
    { key = 'buff_not_active',   label = 'Buff is NOT active',      uses_op = false, uses_buff = true,  uses_radius = false },
    { key = 'buff_stacks',       label = 'Buff stacks',             uses_op = true,  uses_buff = true,  uses_radius = false },
    { key = 'skill_ready',       label = 'This skill is ready',     uses_op = false, uses_buff = false, uses_radius = false },
    { key = 'distance',          label = 'Distance to cast node',   uses_op = true,  uses_buff = false, uses_radius = false },
    { key = 'path_pack_density', label = 'Pack size on path',       uses_op = true,  uses_buff = false, uses_radius = true  },
}

rules.condition_labels = {}
for i, c in ipairs(rules.condition_types) do rules.condition_labels[i] = c.label end

rules.condition_key_by_index = {}
for i, c in ipairs(rules.condition_types) do rules.condition_key_by_index[i] = c.key end

rules.condition_meta_by_key = {}
for _, c in ipairs(rules.condition_types) do rules.condition_meta_by_key[c.key] = c end

-- Comparison operators. `ops` is the internal key list used by apply_op;
-- `op_labels` is the display string used in the GUI combo (the bare angle
-- brackets render poorly in QQT's font).
rules.ops = { '<', '<=', '=', '>=', '>' }
rules.op_labels = {
    '< (less than)',
    '<= (less or equal)',
    '= (equals)',
    '>= (greater or equal)',
    '> (greater than)',
}

-- Combinators
rules.combinators = { 'AND', 'OR' }

-- Cast position modes
rules.cast_positions = {
    { key = 'next_node',                   label = 'Toward next path node' },
    { key = 'toward_largest_pack_on_path', label = 'Toward largest pack on path' },
}
rules.cast_position_labels = {}
for i, p in ipairs(rules.cast_positions) do rules.cast_position_labels[i] = p.label end

rules.apply_op = function (op, a, b)
    if op == '<'  then return a <  b end
    if op == '<=' then return a <= b end
    if op == '='  then return a == b end
    if op == '>=' then return a >= b end
    if op == '>'  then return a >  b end
    return false
end

-- Equipped + movement-capable skills, in catalog order. Returns table of
-- catalog entries (each: {id, name, needs_raycast, range}).
rules.equipped_movement_skills = function ()
    local out = {}
    if type(get_equipped_spell_ids) ~= 'function' then return out end
    rules.resolve_named() -- QQT_Warpigz_v3: name-matched skills (Rampage)
    local ok, equipped = pcall(get_equipped_spell_ids)
    if not ok or type(equipped) ~= 'table' then return out end
    local equipped_set = {}
    for _, id in pairs(equipped) do
        if type(id) == 'number' then equipped_set[id] = true end
    end
    for _, s in ipairs(rules.skill_catalog) do
        if equipped_set[s.id] then out[#out + 1] = s end
    end
    return out
end

-- Build combo items for the rule's skill picker. Index 1 = "(none)".
rules.skill_combo_items = function (equipped_only)
    local items = { '(none)' }
    local src = equipped_only and rules.equipped_movement_skills() or rules.skill_catalog
    for i, s in ipairs(src) do items[i + 1] = s.name end
    return items, src
end

return rules
