local town = {}

town.list = {
    temis = {
        id = 'temis',
        display_name = 'Temis',
        zone_name = 'Skov_Temis',
        waypoint_sno = 0x1CE51E,
        npc_enum = {
            BLACKSMITH = 'TWN_Skov_Temis_Crafter_Blacksmith',
            JEWELER = 'TWN_Skov_Temis_Crafter_Jeweler',
            OCCULTIST = 'TWN_Skov_Temis_Crafter_Occultist',
            SILVERSMITH = 'TWN_Skov_Vendor_Silversmith',
            WEAPON = 'TWN_Skov_Temis_Vendor_Weapons',
            STASH = 'Stash',
            GAMBLER = 'TWN_Skov_Temis_Vendor_Gambler',
            ALCHEMIST = 'TWN_Skov_Temis_Crafter_Alchemist',
            HEALER = 'TWN_Skov_Temis_Service_Healer',
            PIT_TOWER = 'TWN_Kehj_IronWolves_PitKey_Crafter',
            PORTAL = 'TownPortal',
        },
        npc_loc_enum = {
            BLACKSMITH = vec3:new(2574.2500, -479.1963, 31.5029),
            JEWELER = vec3:new(2599.4873046875, -481.2578125, 30.5166015625),
            OCCULTIST = vec3:new(2583.6436, -478.2217, 31.5029),
            SILVERSMITH = vec3:new(2634.7548828125, -477.6875, 28.919921875),
            WEAPON = vec3:new(2621.7822265625, -456.6396484375, 29.5615234375),
            STASH = vec3:new(2570.6807,-474.2803,30.5166),
            GAMBLER = vec3:new(2566.2158203125, -478.7431640625, 30.927734375),
            ALCHEMIST = vec3:new(2599.4521484375, -483.7548828125, 30.5166015625),
            HEALER = vec3:new(2590.2822265625, -466.7939453125, 30.927734375),
            PIT_TOWER = vec3:new(2572.708984375, -498.4921875, 30.5166015625),
            PORTAL = vec3:new(2578.1103515625, -482.2646484375, 31.5029296875),
        },
        npc_via_loc_enum = {
            GAMBLER = vec3:new(2568.7685546875, -471.8046875, 30.5166015625),
            JEWELER = vec3:new(2621.5869140625, -500.4306640625, 28.919921875),            
        },
        walls = {
            {
                inside_anchor = vec3:new(2566.2158203125, -478.7431640625, 30.927734375),
                via = vec3:new(2568.7685546875, -471.8046875, 30.5166015625),
                radius = 5,
            },
        },
        reset_positions = {
            default     = vec3:new(2578.1103515625, -482.2646484375, 31.5029296875),
            stash       = vec3:new(2570.6807,-474.2803,30.5166),
            salvage     = vec3:new(2574.2500, -479.1963, 31.5029),
            sell_gamble = vec3:new(2566.2158203125, -478.7431640625, 30.927734375),
        },
    },
}

town.default = 'temis'

town.options = { 'Temis' }
town.option_to_id = { [0] = 'temis' }
town.id_to_option = { temis = 0 }

function town.get(choice)
    return town.list[choice] or town.list[town.default]
end

return town
