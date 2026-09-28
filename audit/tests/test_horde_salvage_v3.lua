-- QQT_Warpigz_v3 HordeDev 2.2.5 (Coordinator review): town_salvage.lua used
-- `goto continue` (CLAUDE.md forbids goto). The loops now use
-- `repeat ... until true` + `break`. This loads the real file and runs both
-- salvage modes over mixed inventories: every "keep" path must skip to the
-- NEXT item (not end the loop), and only the rejected items are salvaged.
--   G1 no goto / label token in the file (fails on the old code)
--   G2 general GA mode: locked / Unique / GA-keep skip, the rest salvaged
--   G3 filter mode: locked / no-filter / affix-keep skip, the rest salvaged
local ROOT = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local PATH = ROOT .. '/HordeDev/tasks/town_salvage.lua'
local checks, failures = 0, {}
local function ok(value, message)
    if not value then error(message or 'expected a true value', 2) end
    checks = checks + 1
end
local function case(name, fn)
    local passed, err = pcall(fn)
    if passed then print('PASS horde-salvage: ' .. name)
    else failures[#failures + 1] = name .. ': ' .. tostring(err); print('FAIL horde-salvage: ' .. name .. ': ' .. tostring(err)) end
end

local function item(t)
    return {
        is_locked = function() return t.locked == true end,
        get_rarity = function() return t.rarity or 5 end,
        get_name = function() return t.skin or 'Helm' end,
        get_display_name = function() return t.name end,
        is_junk = function() return false end,
        get_sno_id = function() return t.sno or 1 end,
        get_affixes = function() return t.affixes or {} end,
        name = t.name, ga = t.ga,
    }
end
local function affix(hash)
    return {affix_name_hash = hash, get_roll = function() return 1 end, get_roll_max = function() return 2 end}
end

local function run(filtered, inventory)
    local now = 100
    local settings = {greater_affix_count = 2, affix_salvage_count = 2, use_salvage_filter_toggle = filtered}
    local tracker = {keep_items = 0}
    local ga = {}
    for _, it in ipairs(inventory) do ga[it.name] = it.ga or 0 end
    local salvaged = {}
    local modules = {
        ['core.utils'] = {get_greater_affix_count = function(name) return ga[name] or 0 end},
        ['data.enums'] = {},
        ['core.explorer'] = {},
        ['core.settings'] = settings,
        ['core.tracker'] = tracker,
        ['core.affix_filter'] = {
            is_uber_item = function() return false end,
            get_filter = function(_, skin) if skin == 'NoFilter' then return nil end return {{sno_id = 11}, {sno_id = 12}} end,
        },
        gui = {},
        ['core.movement'] = {},
    }
    local env = setmetatable({
        get_time_since_inject = function() return now end,
        get_local_player = function()
            return {get_inventory_items = function() return inventory end, get_item_count = function() return #inventory end}
        end,
        console = {print = function() end},
        loot_manager = {salvage_specific_item = function(it) salvaged[#salvaged + 1] = it.name end},
    }, {__index = _G})
    env._G = env
    env.require = function(name) return assert(modules[name], 'unexpected require ' .. name) end
    local task = assert(loadfile(PATH, 't', env))()
    task:salvage_items()
    table.sort(salvaged)
    return table.concat(salvaged, ','), tracker.keep_items
end

case('G1 town_salvage.lua has no goto or label', function()
    local f = assert(io.open(PATH, 'r')); local src = f:read('*a'); f:close()
    ok(not src:find('%f[%w_]goto%f[^%w_]'), 'town_salvage.lua contains goto')
    ok(not src:find('::[%w_]+::'), 'town_salvage.lua contains a label')
end)

case('G2 general GA mode: each keep path skips to the next item; the rest are salvaged', function()
    local inv = {
        item{name = 'a_locked', locked = true},
        item{name = 'b_salvage'},
        item{name = 'c_unique', rarity = 6},
        item{name = 'd_salvage'},
        item{name = 'e_ga_keep', ga = 3},
        item{name = 'f_salvage'},
    }
    local salvaged, kept = run(false, inv)
    ok(salvaged == 'b_salvage,d_salvage,f_salvage', 'salvaged: ' .. salvaged)
    ok(kept == 3, 'kept ' .. kept)
end)

case('G3 filter mode: each keep path skips to the next item; the rest are salvaged', function()
    local inv = {
        item{name = 'a_locked', locked = true},
        item{name = 'b_salvage', ga = 3, affixes = {affix(1), affix(2), affix(3)}},
        item{name = 'c_nofilter', skin = 'NoFilter'},
        item{name = 'd_salvage', ga = 0, affixes = {affix(11), affix(12), affix(13)}},
        item{name = 'e_affix_keep', ga = 3, affixes = {affix(11), affix(12), affix(13)}},
        item{name = 'f_salvage', ga = 3, affixes = {affix(11), affix(2), affix(3)}},
    }
    local salvaged, kept = run(true, inv)
    ok(salvaged == 'b_salvage,d_salvage,f_salvage', 'salvaged: ' .. salvaged)
    ok(kept == 3, 'kept ' .. kept)
end)

print(string.format('horde salvage v3: %d checks, %d failures', checks, #failures))
if #failures > 0 then error(#failures .. ' horde salvage regression(s) failed') end
