-- Run from Rosie with Lua 5.3+: lua tests/tuning_prisms.lua
package.path = './?.lua;' .. package.path

local settings = {crafting_items=true, other_consumables=false, distance=60}
package.loaded['rosie.private.pickup.src.settings'] = {get=function() return settings end}
package.loaded['rosie.private.pickup.src.pickup'] = {}
package.loaded['rosie.private.mythic_form'] = {}
package.loaded['rosie.private.blacklist'] = {}
package.loaded['rosie.private.unique_sorter'] = {}

local distance, lootable, bag_reads = 2, true, 0
local full_bag = {}
for i=1,33 do full_bag[i] = {} end
local player = {
    is_dead=function() return false end,
    get_position=function() return {dist_to_ignore_z=function() return distance end} end,
    get_consumable_items=function() bag_reads=bag_reads+1; return full_bag end,
}
get_local_player=function() return player end
loot_manager = {
    is_gold=function() return false end,
    is_potion=function() return false end,
    is_obols=function() return false end,
    is_lootable_item=function() return lootable end,
}

local Catalog = require('rosie.data.items')
local Logic = require('rosie.private.pickup.src.item_logic')
local Manager = require('rosie.private.pickup.src.item_manager')
local checks=0
local function equal(actual, expected, label)
    assert(actual==expected, label..': expected '..tostring(expected)..', got '..tostring(actual))
    checks=checks+1
end
local function drop(sno)
    local info = {get_sno_id=function() return sno end, is_valid=function() return true end}
    return {get_item_info=function() return info end, get_position=function() return {} end},info
end

-- V1: every prism obeys crafting_items, regardless of other_consumables or bag space.
local function TestV1_TuningPrismPickup()
    for _,sno in ipairs({2533710,2533715,2533718,2533720,2533724,2533727,2533731,2533733}) do
        local item,info=drop(sno)
        for _,crafting in ipairs({false,true}) do
            for _,consumables in ipairs({false,true}) do
                settings.crafting_items,settings.other_consumables=crafting,consumables
                equal(Manager.check_want_item(item,false),crafting,'prism '..sno..' toggle policy')
            end
        end
        local kind,slot,stack,bag=Logic.classify(info)
        equal(kind,'crafting','prism category')
        equal(slot,nil,'prism has no equipment slot')
        equal(stack,Catalog.by_id[sno].stack,'catalog stack preserved')
        equal(bag,'materials','material destination')
        local destination_kind,destination_bag=Manager.destination(item)
        equal(destination_kind,'crafting','pickup receipt category')
        equal(destination_bag,nil,'no consumable bag receipt')
        settings.crafting_items=true
        lootable=false
        equal(Manager.check_want_item(item,false),false,'host refusal preserved')
        lootable=nil
        local wanted,_,decision=Manager.check_want_item(item,false)
        equal(wanted,false,'host unavailable deferred')
        equal(decision,'deferred','host unavailable decision')
        lootable=true
        distance=61
        equal(Manager.check_want_item(item,false),false,'distance limit preserved')
        distance=2
    end
    equal(bag_reads,0,'prisms do not consult a full consumable bag')
end
TestV1_TuningPrismPickup()

-- Every unrelated catalog entry retains its category and metadata.
-- Trace of Echoes has an explicit Lair Keys pickup override.
for sno,known in pairs(Catalog.by_id) do
    if not Logic.MATERIALS[sno] then
        local _,info=drop(sno)
        local kind,slot,stack,bag=Logic.classify(info)
        equal(kind,sno==2409389 and 'lair_key' or known.kind,'pickup category '..sno)
        equal(slot,known.slot,'unchanged slot '..sno)
        equal(stack,known.stack,'unchanged stack '..sno)
        equal(bag,known.bag,'unchanged bag '..sno)
    end
end
print('PASS: tuning prism pickup and catalog regression ('..checks..' checks)')
