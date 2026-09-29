-- QQT_Warpigz_v3 HordeDev 2.2.9: the Infernal Horde maps. The War Plan
-- teleport lands in the pre-Torment map S10_BSK_Pretorment (owner live log);
-- the compass Horde is S05_BSK_Prototype02. Published as
-- InfernalHordesPlugin.horde_zones / is_horde_zone(zone).
local M = {ZONES = {S05_BSK_Prototype02 = true, S10_BSK_Pretorment = true}}

function M.is(zone)
    return type(zone) == 'string' and M.ZONES[zone] == true
end

-- Inside a Horde map, through utils.player_in_zone (one check per map).
function M.player_inside(utils)
    for zone in pairs(M.ZONES) do
        if utils.player_in_zone(zone) then return true end
    end
    return false
end

return M
