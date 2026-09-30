local Settings   = require("core.settings")
local Utils      = require("utils.utils")
local ItemFilter = require("core.item_filter")

local LootEngine = {}

local function ga_setting_for_slot(slot, rarity, s)
    local prefix = (rarity == 6 or rarity == 7) and "unique_" or "legendary_"
    return s[prefix .. slot .. "_ga_count"]
end

function LootEngine.check_want_item(item, ignore_distance)
    -- Catalog is mandatory. Without it we have no name patterns, no group
    -- mapping, no special tables — refuse to loot rather than half-classify.
    if not ItemFilter._catalog_loaded then return false end

    local info, id, skin, rarity = ItemFilter.get_info(item)
    if not info then return false end

    local s = Settings.get()

    if not ignore_distance and Utils.distance_to(item) >= s.distance then return false end
    if loot_manager.is_gold(item) or loot_manager.is_potion(item) then return false end

    local cat = ItemFilter.classify(item)
    if not cat then return false end

    -- ── Always-loot categories (now opt-out via toggle) ────────────
    if cat == "uber"          then return s.uber          ~= false end
    if cat == "keys"          then return s.keys_loot     ~= false end
    if cat == "misc_trinkets" then return s.misc_trinkets ~= false and not Utils.is_inventory_full() end
    if cat == "xp_powerup"    then return s.xp_powerup    ~= false end
    if cat == "class_powerup" then return s.class_powerup == true   end
    if cat == "glyph_drop"    then return s.glyph_drop    ~= false end
    if cat == "boss_drops" then
        if s.boss_drops == false then return false end
        if rarity < (s.boss_drops_rarity or 0) then return false end
        return not Utils.is_inventory_full()
    end

    -- ── Toggled / conditional ──────────────────────────────────────
    if cat == "boss_material" then return s.boss_items end

    if cat == "event" then
        if not s.event_items then return false end
        return not Utils.is_inventory_full()
    end

    if cat == "goblin_cache" then return s.goblin_cache and not Utils.is_inventory_full() end
    if cat == "obol_bag" then
        if s.skip_obols then return false end
        local player = get_local_player()
        if player and player:get_obols() >= 2500 then return false end
        return s.obols
    end
    if cat == "cinders"      then return s.cinders end

    if cat == "quest" then return s.quest_items end

    if cat == "crafting" then
        if not s.crafting_items then return false end
        if rarity < (s.crafting_rarity or 0) then return false end
        local skip_key = Utils.MAT_SKIP_KEY[id]
        if skip_key and s[skip_key] then return false end
        if Utils.is_crafting_mat_capped(id) then return false end
        return true
    end

    if cat == "cache" then
        if s.cache == false then return false end
        if rarity < (s.cache_rarity or 0) then return false end
        if not Utils.is_inventory_full() then return true end
        return false
    end

    if cat == "scroll" then
        if not s.scroll then return false end
        if rarity < (s.scroll_rarity or 0) then return false end
        if not Utils.is_consumable_inventory_full() or
            Utils.is_lowest_stack_below(get_local_player():get_consumable_items(), id, 20, info:get_stack_count()) then
            return true
        end
        return false
    end

    if cat == "heavenly_sigil" then
        return s.heavenly_sigil and not Utils.is_consumable_inventory_full()
    end

    if cat == "sigil" then
        if not s.sigils then return false end
        if rarity < (s.sigil_rarity or 0) then return false end
        return not Utils.is_sigil_inventory_full()
    end

    if cat == "tribute" or cat == "compass" then
        local flag       = (cat == "tribute") and s.tribute or s.compass
        local min_rarity = (cat == "tribute") and (s.tribute_rarity or 0)
                                              or  (s.compass_rarity or 0)
        if not flag then return false end
        if rarity < min_rarity then return false end
        if not Utils.is_sigil_inventory_full() or
            Utils.is_lowest_stack_below(get_local_player():get_dungeon_key_items(), id, 99, info:get_stack_count()) then
            return true
        end
        return false
    end

    if cat == "rune" then
        if not s.rune then return false end
        if rarity < (s.rune_rarity or 0) then return false end
        if not Utils.is_socketable_inventory_full() or
            Utils.is_lowest_stack_below(get_local_player():get_socketable_items(), id, 100, info:get_stack_count()) then
            return true
        end
        return false
    end

    if cat == "gemstone" then
        if not s.gemstone then return false end
        if rarity < (s.gemstone_rarity or 0) then return false end
        if not Utils.is_socketable_inventory_full() or
            Utils.is_lowest_stack_below(get_local_player():get_socketable_items(), id, 99, info:get_stack_count()) then
            return true
        end
        return false
    end

    if cat == "consumable" then
        if not s.consumable then return false end
        if rarity < (s.consumable_rarity or 0) then return false end
        if not Utils.is_consumable_inventory_full() or
            Utils.is_lowest_stack_below(get_local_player():get_consumable_items(), id, 99, info:get_stack_count()) then
            return true
        end
        return false
    end

    if cat == "recipe" then
        if not s.recipe then return false end
        if rarity < (s.recipe_rarity or 0) then return false end
        return not Utils.is_inventory_full()
    end

    if cat == "charm" then
        if not s.charm or rarity < s.charm_rarity then return false end
        if s.ingame_filter_charm and info:is_filtered_by_loot_filter() then return false end
        if s.charm_ga_count > 0 then
            local ga = Utils.get_ga_count(info)
            if ga < s.charm_ga_count then return false end
        end
        return not Utils.is_talisman_inventory_full()
    end

    -- Trophies are cosmetics (back trophies, mount trophies, banners).
    -- Default off; user can opt in via the Trophy toggle.
    if cat == "trophy" then
        if not s.trophy then return false end
        return not Utils.is_inventory_full()
    end

    if cat == "cube" then
        if not s.cube or rarity < s.cube_rarity then return false end
        return not Utils.is_consumable_inventory_full()
    end

    if cat == "seal" then
        if not s.seal or rarity < s.seal_rarity then return false end
        return not Utils.is_talisman_inventory_full()
    end

    if cat == "fish" then
        if not s.fish then return false end
        -- GoFish integration: skip fish we've already registered in its local
        -- catalog. Predicate is gated by GoFish's own toggle and returns false
        -- when the integration is off, so Looter falls through to default
        -- behavior when GoFish isn't loaded or the toggle is disabled.
        if _G.gofish and _G.gofish.is_fish_learned and _G.gofish.is_fish_learned(id) then
            return false
        end
        if rarity >= 6 then return true end  -- unique/mythic always loot when fish is enabled
        if rarity < (s.fish_rarity or 0) then return false end
        return not Utils.is_inventory_full()
    end

    if cat == "misc" then return false end

    -- ── Equipment ─────────────────────────────────────────────────
    if Utils.is_inventory_full() then return false end
    if s.use_ingame_loot_filter and info:is_filtered_by_loot_filter() then return false end

    local is_anc = (s.ancestral_only or s.pick_ancestral_normals) and info:is_ancestral()

    -- Ancestral-only: reject non-ancestral gear unless it's a unique and the
    -- non_ancestral_uniques exception is enabled.
    if s.ancestral_only and not is_anc then
        if not (s.non_ancestral_uniques and rarity >= 6) then return false end
    end

    if rarity < s.rarity then
        if not (s.pick_ancestral_normals and is_anc and rarity == 0) then return false end
    end

    if rarity >= 5 then
        local ga   = Utils.get_ga_count(info)
        local need = nil

        if s.custom_toggle then
            local slot = ItemFilter.get_slot(item)
            if slot then need = ga_setting_for_slot(slot, rarity, s) end
        end

        if need == nil then
            if     rarity == 5 then need = s.ga_count
            elseif rarity == 6 then need = s.unique_ga_count
            elseif rarity == 7 then need = 0
            elseif rarity == 8 then need = ItemFilter.is_uber(id) and s.uber_unique_ga_count or s.unique_ga_count
            else                     need = 4
            end
        end

        if ga < need then return false end
    elseif rarity >= 3 then
        if s.rare_ga_count > 0 then
            local ga = Utils.get_ga_count(info)
            if ga < s.rare_ga_count then return false end
        end
    elseif rarity >= 1 then
        if s.magic_ga_count > 0 then
            local ga = Utils.get_ga_count(info)
            if ga < s.magic_ga_count then return false end
        end
    end

    return true
end

function LootEngine.get_nearby_item()
    local all, found = actors_manager:get_all_items(), {}
    for _, item in pairs(all) do
        if LootEngine.check_want_item(item, false) then
            table.insert(found, item)
        end
    end
    table.sort(found, function(a, b) return Utils.distance_to(a) < Utils.distance_to(b) end)
    return found[1]
end

function LootEngine.score_item(item)
    local info, id, _, rarity = ItemFilter.get_info(item)
    if not info then return 0 end
    local score = ItemFilter.is_uber(id) and 1000
        or rarity >= 5 and 500
        or rarity >= 3 and 300
        or rarity >= 1 and 100
        or 10
    local ga = Utils.get_ga_count(info)
    return score + (ga == 3 and 100 or ga == 2 and 75 or ga == 1 and 50 or 0)
end

function LootEngine.get_best_item()
    local all, scored = actors_manager:get_all_items(), {}
    for _, item in ipairs(all) do
        if LootEngine.check_want_item(item, false) then
            table.insert(scored, { Item = item, Score = LootEngine.score_item(item) })
        end
    end
    table.sort(scored, function(a, b) return a.Score > b.Score end)
    return scored[1]
end

function LootEngine.get_item_based_on_priority()
    return Settings.get().loot_priority == 0
        and LootEngine.get_nearby_item()
        or  LootEngine.get_best_item()
end

return LootEngine
