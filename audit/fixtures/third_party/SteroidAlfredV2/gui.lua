local plugin_label = 'alfred_the_butler'
local plugin_version = '1.0.0'
-- console.print("Lua Plugin - Alfred the Butler - Leoric - v" .. plugin_version)

local utils = require 'core.utils'
local town = require 'core.town'
local gui = {}

gui.town_options = town.options

local affix_types = utils.get_item_affixes()
local item_aspects = utils.get_item_aspects()
local unique_items = utils.get_unique_items()
local mythic_items = utils.get_mythic_items()
local unique_charm_items = utils.get_unique_charm_items()
local mythic_seal_items  = utils.get_mythic_seal_items()
local set_charm_items    = utils.get_set_charm_items()

local function create_checkbox(value, key)
    return checkbox:new(value, get_hash(plugin_label .. '_' .. key))
end

local function add_tree(name)
    local tree_name = tostring(name)
    tree_name = tree_name .. '_tree'
    gui.elements[tree_name] = tree_node:new(2)
end

local function add_checkbox(name, data, default)
    for _,item in pairs(data) do
        local checkbox_name = tostring(name)
        checkbox_name = checkbox_name .. '_' .. tostring(item.sno_id)
        gui.elements[checkbox_name] = create_checkbox(default, checkbox_name)
    end
end

local function add_search(name)
    local search_name = tostring(name)
    search_name = search_name .. '_search'
    gui.elements[search_name] = input_text:new(get_hash(plugin_label .. tostring(name) .. '_search_input'))
end

local function render_checkbox(name,data, show_item_type)
    local search_name = tostring(name)
    search_name = search_name .. '_search'
    for _,item in pairs(data) do
        local item_name = item.name
        if show_item_type then
            item_name = item.name .. ' - ' .. item.item_type
        end
        for _,class in pairs(item.class) do
            if string.lower(class) == 'all' or string.lower(class) == utils.get_character_class() then
                local checkbox_name = tostring(name)
                checkbox_name = checkbox_name .. '_' .. tostring(item.sno_id)
                local search_string = string.lower(gui.elements[search_name]:get())
                if search_string ~= '' and
                    (string.lower(item_name):match(search_string) or
                    string.lower(item.description):match(search_string) or
                    tostring(item.sno_id):match(search_string))
                then
                    gui.elements[checkbox_name]:render(item.description, item_name)
                elseif gui.elements[checkbox_name]:get() then
                    gui.elements[checkbox_name]:render(item.description, item_name)
                end
            end
        end
    end
end

gui.plugin_label = plugin_label
gui.plugin_version = plugin_version

gui.stash_options = {
    'Inventory',
    'Stash'
}

gui.item_options = {
    'Keep',
    'Salvage',
    'Sell'
}

gui.stash_extra_options= {
    'Never',
    'When full',
    'Always',
}

gui.failed_options= {
    'Log',
    'Forced Retry',
}

gui.gamble_language= {
    'English',
    'Chinese',
    'Other'
}

gui.gamble_categories = {
    ['sorcerer'] = {'Cap', 'Whispering Key', 'Tunic', 'Gloves', 'Boots', 'Pants', 'Amulet', 'Ring', 'Sword', 'Mace', 'Dagger', 'Staff', 'Wand', 'Focus'},
    ['barbarian'] = {'Cap', 'Whispering Key', 'Tunic', 'Gloves', 'Boots', 'Pants', 'Amulet', 'Ring', 'Axe', 'Sword', 'Mace', 'Two-Handed Axe', 'Two-Handed Sword', 'Two-Handed Mace', 'Polearm'},
    ['rogue'] = {'Cap', 'Whispering Key', 'Tunic', 'Gloves', 'Boots', 'Pants', 'Amulet', 'Ring', 'Sword', 'Dagger', 'Bow', 'Crossbow'},
    ['druid'] = {'Cap', 'Whispering Key', 'Tunic', 'Gloves', 'Boots', 'Pants', 'Amulet', 'Ring', 'Axe', 'Sword', 'Mace', 'Two-Handed Axe', 'Two-Handed Mace', 'Polearm', 'Dagger', 'Staff', 'Totem'},
    ['necromancer'] = {'Cap', 'Whispering Key', 'Tunic', 'Gloves', 'Boots', 'Pants', 'Amulet', 'Ring', 'Axe', 'Sword', 'Mace', 'Two-Handed Axe', 'Two-Handed Sword', 'Scythe', 'Two-Handed Mace', 'Two-Handed Scythe', 'Dagger', 'Shield', 'Wand', 'Focus'},
    ['spiritborn'] = {'Quarterstaff', 'Cap', 'Whispering Key', 'Tunic', 'Gloves', 'Boots', 'Pants', 'Amulet', 'Ring', 'Polearm', 'Glaive'},
    ['paladin'] = {"Cap", "Whispering Key", "Tunic", "Gloves", "Boots", "Pants", "Amulet", "Ring", "Axe", "Sword", "Mace", "Shield", "Flail", "Two-Handed Axe", "Two-Handed Sword", "Two-Handed Mace"},
    ['default'] = {'CLASS NOT LOADED'}
}

gui.gamble_categories_chinese = {
    ['sorcerer'] = {"è½¯å¸½", "ä½Žè¯­é’¥åŒ™", "çŸ­è¡£", "æ‰‹å¥—", "é´å­", "è£¤å­", "æŠ¤ç¬¦", "æˆ’æŒ‡", "å‰‘", "é’‰é”¤", "åŒ•é¦–", "æ–", "é­”æ–", "èšèƒ½å™¨"},
    ['barbarian'] = {"è½¯å¸½", "ä½Žè¯­é’¥åŒ™", "çŸ­è¡£", "æ‰‹å¥—", "é´å­", "è£¤å­", "æŠ¤ç¬¦", "æˆ’æŒ‡", "æ–§", "å‰‘", "é’‰é”¤", "åŒæ‰‹æ–§", "åŒæ‰‹å‰‘", "åŒæ‰‹é’‰é”¤", "é•¿æŸ„æ­¦å™¨"},
    ['rogue'] = {"è½¯å¸½", "ä½Žè¯­é’¥åŒ™", "çŸ­è¡£", "æ‰‹å¥—", "é´å­", "è£¤å­", "æŠ¤ç¬¦", "æˆ’æŒ‡", "å‰‘", "åŒ•é¦–", "å¼“", "å¼©"},
    ['druid'] = {"è½¯å¸½", "ä½Žè¯­é’¥åŒ™", "çŸ­è¡£", "æ‰‹å¥—", "é´å­", "è£¤å­", "æŠ¤ç¬¦", "æˆ’æŒ‡", "æ–§", "å‰‘", "é’‰é”¤", "åŒæ‰‹æ–§", "åŒæ‰‹é’‰é”¤", "é•¿æŸ„æ­¦å™¨", "åŒ•é¦–", "æ–", "å›¾è…¾"},
    ['necromancer'] = {"è½¯å¸½", "ä½Žè¯­é’¥åŒ™", "çŸ­è¡£", "æ‰‹å¥—", "é´å­", "è£¤å­", "æŠ¤ç¬¦", "æˆ’æŒ‡", "æ–§", "å‰‘", "é’‰é”¤", "åŒæ‰‹æ–§", "åŒæ‰‹å‰‘", "é•°åˆ€", "åŒæ‰‹é’‰é”¤", "åŒæ‰‹é•°åˆ€", "åŒ•é¦–", "ç›¾ç‰Œ", "é­”æ–", "èšèƒ½å™¨"},
    ['spiritborn'] = {"é•¿æ–", "è½¯å¸½", "ä½Žè¯­é’¥åŒ™", "çŸ­è¡£", "æ‰‹å¥—", "é´å­", "è£¤å­", "æŠ¤ç¬¦", "æˆ’æŒ‡", "é•¿æŸ„æ­¦å™¨", "å‰‘åˆƒæˆŸ"},
    ['paladin'] = {"è½¯å¸½", "ä½Žè¯­é’¥åŒ™", "çŸ­è¡£", "æ‰‹å¥—", "é´å­", "è£¤å­", "æŠ¤ç¬¦", "æˆ’æŒ‡", "æ–§", "å‰‘", "é’‰é”¤", "ç›¾", "è¿žæž·", "åŒæ‰‹æ–§", "åŒæ‰‹å‰‘", "åŒæ‰‹é’‰é”¤"},
    ['default'] = {"CLASS NOT LOADED"}
}

gui.elements = {
    main_tree = tree_node:new(0),
    main_toggle = create_checkbox(false, 'main_toggle'),

    use_keybind = create_checkbox(false, 'use_keybind'),
    keybind_toggle = keybind:new(0x0A, true, get_hash(plugin_label .. '_keybind_toggle' )),
    export_keybind_toggle = keybind:new(0x0A, true, get_hash(plugin_label .. '_export_keybind_toggle' )),
    dump_keybind = keybind:new(0x0A, true, get_hash(plugin_label .. '_dump_keybind')),
    manual_keybind = keybind:new(0x0A, true, get_hash(plugin_label .. '_manual_keybind')),

    item_tree = tree_node:new(1),
    item_legendary_or_lower = combo_box:new(1, get_hash(plugin_label .. '_item_legendary_or_lower')),
    item_unique = combo_box:new(2, get_hash(plugin_label .. '_item_unique')),
    item_junk = combo_box:new(1, get_hash(plugin_label .. '_item_junk')),

    ancestral_item_tree = tree_node:new(1),
    ancestral_item_legendary = combo_box:new(1, get_hash(plugin_label .. '_ancestral_item_legendary')),
    ancestral_item_unique = combo_box:new(1, get_hash(plugin_label .. '_ancestral_item_unique')),
    ancestral_item_junk = combo_box:new(1, get_hash(plugin_label .. '_ancestral_item_junk')),
    ancestral_item_mythic = combo_box:new(0, get_hash(plugin_label .. '_ancestral_item_mythic')),
    ancestral_keep_max_aspect_toggle = create_checkbox(true, 'max_aspect'),
    ancestral_aspect_filter_toggle = create_checkbox(false, 'aspect_filter'),
    ancestral_ga_count_slider = slider_int:new(0, 4, 1, get_hash(plugin_label .. '_ga_slider')),
    ancestral_unique_ga_count_slider = slider_int:new(0, 4, 1, get_hash(plugin_label .. '_unique_ga_slider')),
    ancestral_mythic_ga_count_slider = slider_int:new(0, 4, 1, get_hash(plugin_label .. '_mythic_ga_slider')),
    ancestral_filter_toggle = create_checkbox(false, 'use_filter'),
    ancestral_unique_filter_toggle = create_checkbox(false, 'use_unique_filter'),

    ancestral_affix_count_slider = slider_int:new(1, 4, 2, get_hash(plugin_label .. '_affix_slider')),

    affix_export_button = button:new(get_hash(plugin_label .. '_affix_export_button')),
    affix_import_button = button:new(get_hash(plugin_label .. '_affix_import_button')),
    affix_import_name = input_text:new(get_hash(plugin_label .. '_affix_import_button')),

    socketable_tree = tree_node:new(1),
    stash_socketables = combo_box:new(0, get_hash(plugin_label .. '_stash_socketables')),

    consumeable_tree = tree_node:new(1),
    stash_consumables = combo_box:new(0, get_hash(plugin_label .. '_stash_consumables')),

    key_tree = tree_node:new(1),
    stash_keys = combo_box:new(0, get_hash(plugin_label .. '_stash_keys')),
    stash_sigils = create_checkbox(false, 'stash_sigils'),
    salvage_sigils = create_checkbox(false, 'salvage_sigils'),

    gamble_tree = tree_node:new(1),
    gamble_toggle = create_checkbox(false, 'gamble_toggle'),
    gamble_language = combo_box:new(0, get_hash(plugin_label .. '_gamble_language')),
    gamble_non_english = input_text:new(get_hash(plugin_label .. '_gamble_custom_text')),
    gamble_threshold = slider_int:new(10, 2580, 1000, get_hash(plugin_label .. '_gamble_threshold')),
    gamble_category = {
        ['sorcerer'] = combo_box:new(0, get_hash(plugin_label .. '_gamble_sorcerer_category')),
        ['barbarian'] = combo_box:new(0, get_hash(plugin_label .. '_gamble_barbarian_category')),
        ['rogue'] = combo_box:new(0, get_hash(plugin_label .. '_gamble_rogue_category')),
        ['druid'] = combo_box:new(0, get_hash(plugin_label .. '_gamble_druid_category')),
        ['necromancer'] = combo_box:new(0, get_hash(plugin_label .. '_gamble_necromancer_category')),
        ['spiritborn'] = combo_box:new(0, get_hash(plugin_label .. '_gamble_spiritborn_category')),
        ['paladin'] = combo_box:new(0, get_hash(plugin_label .. '_gamble_paladin_category')),
        ['default'] = combo_box:new(0, get_hash(plugin_label .. '_gamble_default_category')),
    },

    loot_filter_tree      = tree_node:new(1),
    loot_filter_toggle    = create_checkbox(false, 'loot_filter_mode'),
    loot_filter_equipment = create_checkbox(false, 'loot_filter_equipment'),
    loot_filter_seal  = create_checkbox(false, 'loot_filter_seal'),
    loot_filter_charm = create_checkbox(false, 'loot_filter_charm'),

    general_tree = tree_node:new(1),
    town_choice = combo_box:new(0, get_hash(plugin_label .. '_town_choice_v2')),
    explorer_path_angle_slider = slider_int:new(0, 360, 10, get_hash(plugin_label .. '_explorer_path_angle_slider')),
    max_inventory = slider_int:new(20,33, 25, get_hash(plugin_label .. '_max_inventory')),
    max_stash_items = slider_int:new(1, 350, 350, get_hash(plugin_label .. '_max_stash_items')),
    failed_action = combo_box:new(0, get_hash(plugin_label .. '_failed_action')),
    skip_cache = create_checkbox(false, 'skip_cache'),
    skip_favorite = create_checkbox(false, 'skip_favorite'),

    drawing_tree = tree_node:new(1),
    draw_status = create_checkbox(true, 'draw_status'),
    draw_status_offset_x = slider_int:new(0, 1200, 0, get_hash(plugin_label .. "draw_status_offset_x")),
    draw_status_offset_y = slider_int:new(0, 600, 0, get_hash(plugin_label .. "draw_status_offset_y")),
    draw_stash = create_checkbox(false, 'draw_stash'),
    draw_sell = create_checkbox(false, 'draw_sell'),
    draw_salvage = create_checkbox(false, 'draw_salvage'),
    draw_box_space = slider_float:new(0, 1.0, 1.0, get_hash(plugin_label .. "draw_box_space")),
    draw_inventory_origin_x = slider_int:new(0, 4000, 1270, get_hash(plugin_label .. "draw_inventory_origin_x")),
    draw_inventory_origin_y = slider_int:new(0, 2500, 720,  get_hash(plugin_label .. "draw_inventory_origin_y")),
    draw_offset_x = slider_int:new(0, 150, 54, get_hash(plugin_label .. "draw_offset_x")),
    draw_offset_y = slider_int:new(0, 150, 75, get_hash(plugin_label .. "draw_offset_y")),
    draw_box_height = slider_int:new(0, 100, 79, get_hash(plugin_label .. "draw_box_height")),
    draw_box_width = slider_int:new(0, 100, 52, get_hash(plugin_label .. "draw_box_width")),

    seperator = combo_box:new(0, get_hash(plugin_label .. '_seperator')),

    talisman_seal_tree  = tree_node:new(1),
    talisman_charm_tree = tree_node:new(1),

    talisman_seal_action              = combo_box:new(1, get_hash(plugin_label .. '_talisman_seal_action')),
    talisman_seal_affix_filter_toggle = create_checkbox(false, 'talisman_seal_affix_filter'),
    talisman_seal_affix_count_slider  = slider_int:new(1, 4, 1, get_hash(plugin_label .. '_talisman_seal_affix_count')),
    talisman_charm_action              = combo_box:new(1, get_hash(plugin_label .. '_talisman_charm_action')),
    talisman_charm_affix_filter_toggle = create_checkbox(false, 'talisman_charm_affix_filter'),
    talisman_charm_affix_count_slider  = slider_int:new(1, 4, 1, get_hash(plugin_label .. '_talisman_charm_affix_count')),
    talisman_charm_unique_filter_toggle = create_checkbox(false, 'talisman_charm_unique_filter'),
    talisman_charm_set_filter_toggle    = create_checkbox(false, 'talisman_charm_set_filter'),
    talisman_seal_mythic_filter_toggle  = create_checkbox(false, 'talisman_seal_mythic_filter'),
    talisman_tab_x             = slider_int:new(0, 3840, 1466, get_hash(plugin_label .. '_talisman_tab_x')),
    talisman_tab_y             = slider_int:new(0, 2160, 650,  get_hash(plugin_label .. '_talisman_tab_y')),
}

for _,affix_type in pairs(affix_types) do
    local name = affix_type.name .. '_affix'
    add_tree(name)
    add_checkbox(name, affix_type.data, false)
    add_search(name)
end
add_tree('aspect')
add_checkbox('aspect', item_aspects, false)
add_search('aspect')
add_tree('unique')
add_checkbox('unique', unique_items, false)
add_search('unique')
add_tree('mythic')
add_checkbox('mythic', mythic_items, true)
add_tree('charm_unique')
add_checkbox('charm_unique', unique_charm_items, false)
add_search('charm_unique')
add_tree('charm_set')
add_checkbox('charm_set', set_charm_items, false)
add_search('charm_set')
add_tree('seal_mythic')
add_checkbox('seal_mythic', mythic_seal_items, false)
function gui.render()
    if not gui.elements.main_tree:push('[O] SteroidButlerV2 v' .. gui.plugin_version) then return end
    gui.elements.main_toggle:render('Enable', 'Enable alfred')
    if not gui.elements.main_toggle:get() then gui.elements.main_tree:pop(); return end
    if gui.elements.general_tree:push('General settings') then
        gui.elements.town_choice:render('Home town', gui.town_options, 'Which town Alfred runs his errands in')
        gui.elements.use_keybind:render('Use keybind', 'Keybind to quick toggle the bot')
        if gui.elements.use_keybind:get() then
            gui.elements.keybind_toggle:render('Toggle Keybind', 'Toggle the bot for quick enable')
            gui.elements.export_keybind_toggle:render('Toggle Export Keybind', 'Toggle to export inventory data before sell/salvage/stash')
            gui.elements.dump_keybind:render('Dump tracker info', 'Dump all tracker info to log')
            gui.elements.manual_keybind:render('Manual trigger', 'Make alfred run tasks now')
        end
        gui.elements.explorer_path_angle_slider:render("Explorer Path angle", "adjust the angle for path filtering (0 - 360 degrees)")
        render_menu_header('IMPORTANT TO SET MAX INVENTORY ITEM TO 25 OR LOWER IF YOU ARE RUNNING BOSSER AND NOT PICKING EVERYTHING UP. SETTING HIGHER THAN 25 MIGHT CAUSE A MYTHIC TO BE LOST')
        gui.elements.max_inventory:render("Max inventory items", "No. of items in inventory to trigger alfred tasks")
        gui.elements.max_stash_items:render("Max stash items", "Alfred halts when stash reaches this count (6 tabs = 300)")
        gui.elements.failed_action:render('Failed action', gui.failed_options, 'Select what to do when alfred is in complete failure')
        if gui.elements.failed_action:get() == utils.failed_action_enum['LOG'] then
            render_menu_header('Log action will leave your character standing there and you might get disconnected for inactivity, but logs should still be copyable')
        else
            render_menu_header('Forced retry action will keep looping tasks, this will cause your character to move away and back and not trigger inactivity timer. if problem persist, it will stuck in a loop')
        end
        gui.elements.skip_cache:render('Skip stashing cache', 'Keep caches in inventory (mainly for season 8)')
        if gui.elements.skip_cache:get() then
            render_menu_header('If you choose to skip stashing cache and your inventory is full of caches, alfred will just stand there')
        end
        gui.elements.skip_favorite:render('Skip favorited items', 'When enabled, favorited (locked) items are ignored by all Alfred operations — not sold, salvaged, or stashed')
        gui.elements.general_tree:pop()
    end
    if gui.elements.loot_filter_tree:push('[In-game Loot Filter]') then
        gui.elements.loot_filter_toggle:render('Enable (Universal)', 'Use in-game loot filter as the sole rule for ALL item decisions — bypasses all Alfred rules.')
        if gui.elements.loot_filter_toggle:get() then
            render_menu_header('Universal mode: all stash/salvage decisions driven by is_filtered_by_loot_filter(). Filtered out = salvage, not filtered = keep/stash. All Alfred rules bypassed.')
        end
        gui.elements.loot_filter_equipment:render('Enable (Equipment Only)', 'Use in-game loot filter for armor/weapons/jewelry. Ignored if Universal is on.')
        gui.elements.loot_filter_seal:render('Enable (Seals Only)', 'Use in-game loot filter for seals. Ignored if Universal is on.')
        gui.elements.loot_filter_charm:render('Enable (Charms Only)', 'Use in-game loot filter for charms. Ignored if Universal is on.')
        if (gui.elements.loot_filter_equipment:get() or gui.elements.loot_filter_seal:get() or gui.elements.loot_filter_charm:get()) and not gui.elements.loot_filter_toggle:get() then
            render_menu_header('Selective mode: loot filter applies to checked categories. Everything else uses Alfred\'s normal rules.')
        end
        gui.elements.loot_filter_tree:pop()
    end
    if gui.elements.drawing_tree:push('Display settings') then
        gui.elements.draw_status:render('Draw status', 'Draw status info on screen')
        gui.elements.draw_stash:render('Draw Keep items', 'Draw blue box around items that alfred will keep/stash')
        if gui.elements.draw_stash:get() then
            render_menu_header('Items to keep/stash are drawn with blue box')
        end
        gui.elements.draw_salvage:render('Draw Salvage items', 'Draw orange box around items that alfred will salvage')
        if gui.elements.draw_salvage:get() then
            render_menu_header('Items to salvage are drawn with orange box')
        end
        gui.elements.draw_sell:render('Draw Sell items', 'Draw pink box around items that alfred will sell')
        if gui.elements.draw_sell:get() then
            render_menu_header('Items to sell are drawn with pink box')
        end
        gui.elements.draw_status_offset_x:render("Status Offset X", "Adjust status message offset X")
        gui.elements.draw_status_offset_y:render("Status Offset Y", "Adjust status message offset Y")
        gui.elements.draw_box_space:render("Box Spacing", "", 1)
        gui.elements.draw_inventory_origin_x:render("Inventory Origin X", "X pixel of the top-left inventory slot — open inventory and align until box overlaps slot 0,0")
        gui.elements.draw_inventory_origin_y:render("Inventory Origin Y", "Y pixel of the top-left inventory slot")
        gui.elements.draw_offset_x:render("Slot Width", "Pixel distance between inventory columns")
        gui.elements.draw_offset_y:render("Slot Height", "Pixel distance between inventory rows")
        gui.elements.draw_box_height:render("Box Height", "Height of the colored item box")
        gui.elements.draw_box_width:render("Box Width", "Width of the colored item box")
        gui.elements.drawing_tree:pop()
    end
    if gui.elements.item_tree:push('Non-Ancestral') then
        render_menu_header('Select the default action for the following item types for non-ancestral items')
        gui.elements.item_unique:render('unique items', gui.item_options, 'Select what to do with non-ancestral unique items')
        gui.elements.item_legendary_or_lower:render('non-unique items', gui.item_options, 'Select what to do with non-ancestral non-unique legendary items')
        gui.elements.item_junk:render('junk items', gui.item_options, 'Select what to do with junk items')
        gui.elements.item_tree:pop()
    end
    if gui.elements.ancestral_item_tree:push('Ancestral') then
        render_menu_header('Select the default action for the following item types for ancestral items')
        gui.elements.ancestral_item_mythic:render('mythic items', gui.item_options, 'Select what to do with mythic items')
        gui.elements.ancestral_item_unique:render('unique items', gui.item_options, 'Select what to do with unique items')
        gui.elements.ancestral_item_legendary:render('non-unique/non-mythic items', gui.item_options, 'Default action for rare/magic/legendary items with no GA override')
        gui.elements.ancestral_item_junk:render('junk items', gui.item_options, 'Select what to do with junk items')
        render_menu_header('Select the number of greater affixes on items you want to keep (override the default actions above to keep)')
        gui.elements.ancestral_mythic_ga_count_slider:render('Mythic Greater Affix', 'Minimum greater affix to keep for mythic')
        gui.elements.ancestral_unique_ga_count_slider:render('Unique Greater Affix', 'Minimum greater affix to keep for unique')
        gui.elements.ancestral_ga_count_slider:render('Non-Unique/Non-Mythic Min GA to Keep', 'Items with this many or more GAs are kept regardless of default action. 0 = disabled.')
        gui.elements.ancestral_filter_toggle:render('Use affix filter', 'Sub-filter within GA gate: also require matching affixes to keep')
        if gui.elements.ancestral_filter_toggle:get() then
            render_menu_header('Item keeps only if GA gate passes AND it has >= N of your checked affixes')
            gui.elements.ancestral_affix_count_slider:render('Min matching affixes', 'How many checked affixes must be present')
            for _, affix_type in pairs(affix_types) do
                if not affix_type.name:match('talisman') then
                    local name = affix_type.name .. '_affix'
                    if gui.elements[name .. '_tree']:push(affix_type.name) then
                        gui.elements[name .. '_search']:render('Search', 'Filter by name', false, '', '')
                        render_checkbox(name, affix_type.data, false)
                        gui.elements[name .. '_tree']:pop()
                    end
                end
            end
        end
        gui.elements.ancestral_unique_filter_toggle:render('Use unique/mythic filter', 'When enabled, only checked uniques/mythics will be kept — all others follow the default action above')
        if gui.elements.ancestral_unique_filter_toggle:get() then
            render_menu_header('Check the uniques/mythics you want to keep. Unchecked items follow the default action above.')
            if gui.elements['unique_tree']:push('Unique items') then
                gui.elements['unique_search']:render('Search', 'Find unique items', false, '', '')
                render_checkbox('unique', unique_items, true)
                gui.elements['unique_tree']:pop()
            end
            if gui.elements['mythic_tree']:push('Mythic items') then
                for _,item in pairs(mythic_items) do
                    local checkbox_name = 'mythic_' .. tostring(item.sno_id)
                    gui.elements[checkbox_name]:render(item.name, item.description)
                end
                gui.elements['mythic_tree']:pop()
            end
        end
        gui.elements.ancestral_item_tree:pop()
    end
    if gui.elements.socketable_tree:push('Socketables') then
        gui.elements.stash_socketables:render('Stash socketables', gui.stash_extra_options, 'Select when to stash socketables')
        if gui.elements.stash_socketables:get() == utils.stash_extra_enum['NEVER'] then
            render_menu_header('Never stash socketables')
        elseif gui.elements.stash_socketables:get() == utils.stash_extra_enum['FULL'] then
            render_menu_header('Stash all socketables when alfred is stashing equipment if socketables inventory is full')
        elseif gui.elements.stash_socketables:get() == utils.stash_extra_enum['ALWAYS'] then
            render_menu_header('Stash all socketables when alfred is stashing')
        end
        gui.elements.socketable_tree:pop()
    end
    if gui.elements.socketable_tree:push('Consumables') then
        gui.elements.stash_consumables:render('Stash consumables', gui.stash_extra_options, 'Select when to stash consumables')
        if gui.elements.stash_consumables:get() == utils.stash_extra_enum['NEVER'] then
            render_menu_header('Never stash consumables')
        elseif gui.elements.stash_consumables:get() == utils.stash_extra_enum['FULL'] then
            render_menu_header('Stash extra boss materials when alfred is stashing equipment if consumables inventory is full')
        elseif gui.elements.stash_consumables:get() == utils.stash_extra_enum['ALWAYS'] then
            render_menu_header('Stash extra boss materials when alfred is stashing')
        end
        gui.elements.socketable_tree:pop()
    end
    if gui.elements.key_tree:push('Dungeon Keys') then
        gui.elements.stash_keys:render('Stash dungeon keys', gui.stash_extra_options, 'Select when to stash dungeon keys')
        gui.elements.stash_sigils:render('Stash Favourited sigils', 'stash favourited sigils')
        gui.elements.salvage_sigils:render('Salvage Non-Favourited sigils', 'salvage non-favourited sigils')
        if gui.elements.stash_keys:get() == utils.stash_extra_enum['NEVER'] then
            render_menu_header('Never stash dungeon keys')
        elseif gui.elements.stash_keys:get() == utils.stash_extra_enum['FULL'] then
            render_menu_header('Stash extra compasses and tributes when alfred is stashing equipment if dungeon keys inventory is full')
        elseif gui.elements.stash_keys:get() == utils.stash_extra_enum['ALWAYS'] then
            render_menu_header('Stash extra compasses and tributes when alfred is stashing')
        end
        gui.elements.key_tree:pop()
    end
    if gui.elements.talisman_seal_tree:push('Talisman (Seal)') then
        gui.elements.talisman_seal_action:render('Seal default action', {'Keep', 'Salvage', 'Sell'}, 'What to do with seals by default')
        gui.elements.talisman_seal_affix_filter_toggle:render('Use affix filter', 'Keep seals that have >= N of your checked affixes')
        if gui.elements.talisman_seal_affix_filter_toggle:get() then
            gui.elements.talisman_seal_affix_count_slider:render('Min matching affixes', 'How many checked seal affixes must match to keep')
            local name = 'talisman_seal_affix'
            if gui.elements[name .. '_tree']:push('Seal Affixes') then
                gui.elements[name .. '_search']:render('Search', 'Filter by name', false, '', '')
                render_checkbox(name, (function()
                    for _, at in pairs(affix_types) do
                        if at.name == 'talisman_seal' then return at.data end
                    end
                    return {}
                end)(), false)
                gui.elements[name .. '_tree']:pop()
            end
        end
        gui.elements.talisman_seal_mythic_filter_toggle:render('Use mythic seal filter', 'When enabled, only checked mythic seals are kept — unchecked ones follow the seal action above')
        if gui.elements.talisman_seal_mythic_filter_toggle:get() then
            if gui.elements['seal_mythic_tree']:push('Mythic Seals') then
                for _, item in pairs(mythic_seal_items) do
                    local cb = 'seal_mythic_' .. tostring(item.sno_id)
                    gui.elements[cb]:render(item.name, item.description or '')
                end
                gui.elements['seal_mythic_tree']:pop()
            end
        end
        gui.elements.talisman_seal_tree:pop()
    end
    if gui.elements.talisman_charm_tree:push('Talisman (Charm)') then
        gui.elements.talisman_charm_action:render('Charm default action', {'Keep', 'Salvage', 'Sell'}, 'What to do with charms by default')
        gui.elements.talisman_charm_affix_filter_toggle:render('Use affix filter', 'Keep charms that have >= N of your checked affixes')
        if gui.elements.talisman_charm_affix_filter_toggle:get() then
            gui.elements.talisman_charm_affix_count_slider:render('Min matching affixes', 'How many checked charm affixes must match to keep')
            local name = 'talisman_charm_affix'
            if gui.elements[name .. '_tree']:push('Charm Affixes') then
                gui.elements[name .. '_search']:render('Search', 'Filter by name', false, '', '')
                render_checkbox(name, (function()
                    for _, at in pairs(affix_types) do
                        if at.name == 'talisman_charm' then return at.data end
                    end
                    return {}
                end)(), false)
                gui.elements[name .. '_tree']:pop()
            end
        end
        gui.elements.talisman_charm_unique_filter_toggle:render('Use unique charm filter', 'When enabled, only checked unique charms are kept — unchecked ones follow the charm action above')
        if gui.elements.talisman_charm_unique_filter_toggle:get() then
            if gui.elements['charm_unique_tree']:push('Unique Charms') then
                gui.elements['charm_unique_search']:render('Search', 'Filter by name or class', false, '', '')
                render_checkbox('charm_unique', unique_charm_items, false)
                gui.elements['charm_unique_tree']:pop()
            end
        end
        gui.elements.talisman_charm_set_filter_toggle:render('Use set charm filter', 'When enabled, only checked set charms are kept AND must pass affix filter — unchecked set charms follow charm action above')
        if gui.elements.talisman_charm_set_filter_toggle:get() then
            if gui.elements['charm_set_tree']:push('Set Charms') then
                gui.elements['charm_set_search']:render('Search', 'Filter by name or set', false, '', '')
                render_checkbox('charm_set', set_charm_items, false)
                gui.elements['charm_set_tree']:pop()
            end
        end
        gui.elements.talisman_charm_tree:pop()
    end
    -- Gambling UI hidden pending API update
    -- if gui.elements.gamble_tree:push('Gambling settings') then
    --     gui.elements.gamble_toggle:render('Enable gambling', 'enable gambling')
    --     if gui.elements.gamble_toggle:get() then
    --         render_menu_header('remember to disable gambling in piteer so that it doesnt clash')
    --     end
    --     gui.elements.gamble_threshold:render('Obols threshold', 'amount of obols before starting gambling')
    --     gui.elements.gamble_language:render('Language', gui.gamble_language, "Select your client language")
    --     if gui.gamble_language[gui.elements.gamble_language:get()+1] == 'English' then
    --         local class = utils.get_character_class()
    --         gui.elements.gamble_category[class]:render("Gamble Category", gui.gamble_categories[class], "Select the item category to gamble")
    --     elseif gui.gamble_language[gui.elements.gamble_language:get()+1] == 'Chinese' then
    --         local class = utils.get_character_class()
    --         gui.elements.gamble_category[class]:render("Gamble Category", gui.gamble_categories_chinese[class], "Select the item category to gamble")
    --     else
    --         render_menu_header('type in the gamble category including any spaces in between')
    --         gui.elements.gamble_non_english:render('Gamble category', 'type in the gamble category including any spaces in between', false, '', '')
    --     end
    --     gui.elements.gamble_tree:pop()
    -- end

    -- if gui.elements.gamble_tree:push('Gamble') then
    --     gui.elements.gamble_toggle:render('Gambling', 'Enable gambling items')
    --     gui.elements.gamble_tree:pop()
    -- end
    gui.elements.main_tree:pop()
end

return gui
