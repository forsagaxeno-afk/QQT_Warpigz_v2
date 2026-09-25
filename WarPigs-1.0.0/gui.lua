local plugin_label   = 'war_pigs'
local plugin_version = '1.0.10'
console.print('Lua Plugin - WarPigs - v' .. plugin_version)

local gui = {}
local bound_orchestrator
gui.bind_orchestrator = function(value) bound_orchestrator = value end

local create_checkbox = function(value, key)
    return checkbox:new(value, get_hash(plugin_label .. '_' .. key))
end

gui.plugin_label   = plugin_label
gui.plugin_version = plugin_version

gui.elements = {
    main_tree     = tree_node:new(0),
    main_toggle   = create_checkbox(false, 'main_toggle'),
    use_keybind   = create_checkbox(false, 'use_keybind'),
    -- 0x0A is the harness convention for "no key bound yet" — same default as HordeDev.
    keybind_toggle= keybind:new(0x0A, true, get_hash(plugin_label .. '_keybind_toggle')),
    -- Teleport-transition: when ON, after the previous quest's plugin is
    -- disabled and BEFORE the next plugin is enabled, call
    -- warplan.teleport_to_activity() and wait for the channel to settle.
    use_teleport_transition = create_checkbox(false, 'use_teleport_transition'),
    run_pit_after_turnin    = create_checkbox(false, 'run_pit_after_turnin'),
    manage_orbwalker        = create_checkbox(false, 'manage_orbwalker'),
    manage_whispers        = create_checkbox(true, 'manage_whispers'),
    -- Infernal Hordes War Plans: enter through the War Plan teleport and run
    -- HordeDev in War Plan entry mode (no compass, no Library walk).
    horde_warplan_entry    = create_checkbox(true, 'horde_warplan_entry'),
    horde_compass_fallback = create_checkbox(false, 'horde_compass_fallback'),
    verbose_logs  = create_checkbox(false, 'verbose_logs'),
    log_all_quests= create_checkbox(false, 'log_all_quests'),
}

gui.render = function()
    if not gui.elements.main_tree:push('Z | War Pigs | Orchestrator | v' .. gui.plugin_version) then return end
    for quest_name, raw_entry in pairs(bound_orchestrator and bound_orchestrator.quest_plugin_map or {}) do
        local plugin_name
        if type(raw_entry) == 'string' then
            plugin_name = raw_entry
        elseif type(raw_entry) == 'table' then
            plugin_name = raw_entry.plugin  -- nil for task-only entries
        end
        if plugin_name and _G[plugin_name] == nil then
            render_menu_header(plugin_name .. ' not loaded — ' .. quest_name .. ' will not be managed')
        end
    end
    gui.elements.main_toggle:render('Enable', 'Watch active quests and toggle managed plugins')
    gui.elements.use_keybind:render('Use keybind', 'Quick on/off toggle via a hotkey')
    if gui.elements.use_keybind:get() then
        gui.elements.keybind_toggle:render('Toggle Keybind', 'Press to toggle WarPigs on/off')
    end

    gui.elements.use_teleport_transition:render('Use teleport',
        'After each activity ends, call warplan.teleport_to_activity() before\n' ..
        'starting the next plugin. The orchestrator waits for the channel to\n' ..
        'settle before letting the next activity begin.')

    gui.elements.run_pit_after_turnin:render('Run pit after turn-in',
        'Once at least one WarPlans turn-in has completed, fill any gap with no\n' ..
        'active WarPlans quest by enabling ArkhamAsylumPlugin (pit). The pit\n' ..
        'keeps running until a new WarPlans quest matches, at which point the\n' ..
        'normal preemption / disable_when handoff takes over.')

    gui.elements.horde_warplan_entry:render('Hordes: enter via War Plan teleport (no compass)',
        'For an Infernal Hordes War Plan, WarPigs calls warplan.teleport_to_activity()\n' ..
        'itself (also with Use teleport off) and starts HordeDev only inside the Horde,\n' ..
        'in War Plan entry mode: no Infernal Compass, no Library walk, one run, then\n' ..
        'the exit. Off: HordeDev farms with compasses as before.')
    if gui.elements.horde_warplan_entry:get() then
        gui.elements.horde_compass_fallback:render('Allow compass entry if the War Plan teleport fails',
            'Only after 3 War Plan teleports did not reach the Horde: start HordeDev in\n' ..
            'its normal compass mode (spends an Infernal Compass). Off (default): never\n' ..
            'spend a compass; retry the War Plan teleport after a 60 s pause.')
    end

    gui.elements.manage_whispers:render('Whispers in Temis (SilentRaven)',
        'Check for Whisper rewards on each Temis visit after activity cleanup.\n' ..
        'Enable the bundled SilentRaven. Waits for Alfred and Looter; never teleports for Whispers.')

    gui.elements.manage_orbwalker:render('Manage orbwalker',
        'At every handoff (after the outgoing plugin stops, and before and after\n' ..
        'enabling the next one) force orbwalker.set_clear_toggle(true) so the next\n' ..
        'plugin starts with orbwalker clear ON, regardless of what the previous plugin\n' ..
        'or a plugin\'s start-up reset left it at. Off by default — leaves orbwalker\n' ..
        'fully under individual plugins / your rotation\'s control.')

    gui.elements.verbose_logs:render('Verbose logs', 'Print WarPlans quest diffs to console')
    gui.elements.log_all_quests:render('Log ALL quests', 'Print every newly-seen quest name + id to console (use to capture quest names for new activities)')
    gui.elements.main_tree:pop()
end

return gui
