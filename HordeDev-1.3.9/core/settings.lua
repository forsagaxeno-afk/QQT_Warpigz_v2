local gui = require "gui"
local settings = {
    enabled = false,
    use_keybind = false,
    elites_only = false,
    run_pit = false,
    party_mode = false,
    do_bartuc = false,
    pit_level = 1,
    salvage = true,
    aggresive_movement = true, 
    path_angle = 10,
    reset_time = 1,
    selected_chest_type = 0,
    always_open_ga_chest = true,
    always_open_talisman_chest = false,
    merry_go_round = true,
    movement_spell_to_objective = true,
    use_evade_as_movement_spell = true,
    use_teleport = true,
    use_teleport_enchanted = true,
    use_dash = true,
    use_shadow_step = true,
    use_the_hunter = true,
    use_rushing_claw = true,
    use_soar = true,
    use_leap = true,
    use_nether_step = true,
    use_rampage = true,
    pick_pylon_delay = 1.5,
    open_chest_delay = 1.5,
    open_ga_chest_delay = 3,
    wait_loot_delay = 10,
    boss_kill_delay = 6,
    chest_move_attempts = 40,
    use_salvage_filter_toggle = false,
    affix_salvage_count = 0,
    greater_affix_count = 0,
    use_alfred = true,
    use_6_wave = true,
    use_8_wave = true,
    use_10_wave = true,
    use_bloodied = false,
    exit_mode = 0,
    manage_orbwalker = false,
    -- R8: runtime only (no GUI control, never persisted). True between an
    -- external enable() (WarPigs) and disable() or the user switching the
    -- main toggle off; lets 'Use keybind' with no key bound (0x0A) run.
    external_control = false,
}

local controls = {
    enabled = "main_toggle",
    use_keybind = "use_keybind",
    salvage = "salvage_toggle",
    run_pit = "run_pit_toggle",
    party_mode = "party_mode_toggle",
    do_bartuc = "do_bartuc_toggle",
    aggresive_movement = "aggresive_movement_toggle",
    path_angle = "path_angle_slider",
    selected_chest_type = "chest_type_selector",
    always_open_ga_chest = "always_open_ga_chest",
    always_open_talisman_chest = "always_open_talisman_chest",
    merry_go_round = "merry_go_round",
    movement_spell_to_objective = "movement_spell_to_objective",
    use_evade_as_movement_spell = "use_evade_as_movement_spell",
    use_teleport = "use_teleport",
    use_teleport_enchanted = "use_teleport_enchanted",
    use_dash = "use_dash",
    use_shadow_step = "use_shadow_step",
    use_the_hunter = "use_the_hunter",
    use_soar = "use_soar",
    use_rushing_claw = "use_rushing_claw",
    use_leap = "use_leap",
    use_nether_step = "use_nether_step",
    use_rampage = "use_rampage",
    pick_pylon_delay = "pick_pylon_delay",
    open_chest_delay = "open_chest_delay",
    open_ga_chest_delay = "open_ga_chest_delay",
    wait_loot_delay = "wait_loot_delay",
    boss_kill_delay = "boss_kill_delay",
    chest_move_attempts = "chest_move_attempts",
    use_salvage_filter_toggle = "use_salvage_filter_toggle",
    affix_salvage_count = "affix_salvage_count",
    greater_affix_count = "greater_affix_count",
    use_alfred = "use_alfred",
    use_6_wave = "use_6_wave",
    use_8_wave = "use_8_wave",
    use_10_wave = "use_10_wave",
    use_bloodied = "use_bloodied",
    exit_mode = "exit_mode",
    manage_orbwalker = "manage_orbwalker",
}

function settings.set_setting(name, value)
    if settings[name] == nil or type(settings[name]) == "function"
        or type(settings[name]) ~= type(value) then return false end
    if controls[name] then gui.elements[controls[name]]:set(value) end
    settings[name] = value
    return true
end

function settings:update_settings()
    settings.enabled = gui.elements.main_toggle:get()
    if not settings.enabled then settings.external_control = false end
    settings.use_keybind = gui.elements.use_keybind:get()
    settings.salvage = gui.elements.salvage_toggle:get()
    settings.run_pit = gui.elements.run_pit_toggle:get()
    settings.party_mode = gui.elements.party_mode_toggle:get()
    settings.do_bartuc = gui.elements.do_bartuc_toggle:get()
    settings.aggresive_movement = gui.elements.aggresive_movement_toggle:get() -- Finn's movement logic
    settings.path_angle = gui.elements.path_angle_slider:get()
    settings.selected_chest_type = gui.elements.chest_type_selector:get()
    settings.always_open_ga_chest = gui.elements.always_open_ga_chest:get()
    settings.always_open_talisman_chest = gui.elements.always_open_talisman_chest:get()
    settings.merry_go_round = gui.elements.merry_go_round:get()
    settings.movement_spell_to_objective = gui.elements.movement_spell_to_objective:get()
    settings.use_evade_as_movement_spell = gui.elements.use_evade_as_movement_spell:get()
    settings.use_teleport = gui.elements.use_teleport:get()
    settings.use_teleport_enchanted = gui.elements.use_teleport_enchanted:get()
    settings.use_dash = gui.elements.use_dash:get()
    settings.use_shadow_step = gui.elements.use_shadow_step:get()
    settings.use_the_hunter = gui.elements.use_the_hunter:get()
    settings.use_soar = gui.elements.use_soar:get()
    settings.use_rushing_claw = gui.elements.use_rushing_claw:get()
    settings.use_leap = gui.elements.use_leap:get()
    settings.use_nether_step = gui.elements.use_nether_step:get()
    settings.use_rampage = gui.elements.use_rampage:get()
    settings.pick_pylon_delay = gui.elements.pick_pylon_delay:get()
    settings.open_chest_delay = gui.elements.open_chest_delay:get()
    settings.open_ga_chest_delay = gui.elements.open_ga_chest_delay:get()
    settings.wait_loot_delay = gui.elements.wait_loot_delay:get()
    settings.boss_kill_delay = gui.elements.boss_kill_delay:get()
    settings.chest_move_attempts = gui.elements.chest_move_attempts:get()
    settings.use_salvage_filter_toggle = gui.elements.use_salvage_filter_toggle:get()
    settings.affix_salvage_count = gui.elements.affix_salvage_count:get()
    settings.greater_affix_count = gui.elements.greater_affix_count:get()
    settings.use_alfred = gui.elements.use_alfred:get()
    settings.use_6_wave = gui.elements.use_6_wave:get()
    settings.use_8_wave = gui.elements.use_8_wave:get()
    settings.use_10_wave = gui.elements.use_10_wave:get()
    settings.use_bloodied = gui.elements.use_bloodied:get()
    settings.exit_mode = gui.elements.exit_mode:get()
    settings.manage_orbwalker = gui.elements.manage_orbwalker:get()
end

return settings