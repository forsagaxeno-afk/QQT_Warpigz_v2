local Settings   = require("core.settings")
local LootEngine = require("core.loot_engine")
local ItemFilter = require("core.item_filter")
local Utils      = require("utils.utils")

local Renderer = {}

function Renderer.draw_stuff()
    if not get_local_player() or not Settings.get().enabled then return end

    local ppos = get_player_position()

    if Utils.is_inventory_full() then
        graphics.text_3d("Inventory Full", ppos, 20, color_red(255))
    end
    if Utils.is_consumable_inventory_full() then
        graphics.text_3d("Consumable Full", vec3:new(ppos:x(), ppos:y(), ppos:z()+1), 20, color_red(255))
    end
    if Utils.is_socketable_inventory_full() then
        graphics.text_3d("Socketable Full", vec3:new(ppos:x(), ppos:y(), ppos:z()+2), 20, color_red(255))
    end
    if Utils.is_sigil_inventory_full() then
        graphics.text_3d("Sigil Full",      vec3:new(ppos:x(), ppos:y(), ppos:z()+3), 20, color_red(255))
    end
    if Utils.is_talisman_inventory_full() then
        graphics.text_3d("Talisman Full",   vec3:new(ppos:x(), ppos:y(), ppos:z()+4), 20, color_red(255))
    end

    local s = Settings.get()

    if s.scan_items then
        for _, item in pairs(actors_manager:get_all_items()) do
            local info = item:get_item_info()
            if info then
                local skin = info:get_skin_name() or ""
                local cat  = ItemFilter.classify(item) or ""
                local want = LootEngine.check_want_item(item, true)
                local txt  = string.format("%s | r=%d | id=%d | cat=%s | want=%s",
                    skin, info:get_rarity(), info:get_sno_id(), cat, tostring(want))
                local highlight = skin:find("Charm") or skin:find("Flippy") or skin:find("Seal")
                    or skin:find("Horadric") or skin:find("[Kk]ey") or skin:find("Boss")
                    or skin:find("Treasure") or skin:find("Sigil") or cat == "uber"
                local col = highlight and color_yellow(255) or color_white(200)
                graphics.text_3d(txt, item:get_position(), 14, col)
                if highlight then console.print("[LooteerV3 Scan] " .. txt) end
            end
        end
    end

    if s.draw_wanted_items then
        for _, item in pairs(actors_manager:get_all_items()) do
            if LootEngine.check_want_item(item, true) then
                graphics.circle_3d(item:get_position(), 0.5, color_pink(255), 3)
            end
        end
    end
end

return Renderer
