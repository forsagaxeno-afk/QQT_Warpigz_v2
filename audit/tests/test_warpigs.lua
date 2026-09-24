local root = assert(SUITE_ROOT) .. '/WarPigs-1.0.0/'
package.path = root .. '?.lua;' .. package.path
local function equal(a, b, message)
    assert(a == b, (message or 'mismatch') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a))
end
local function fixture()
    local f = { now = 100, quests = {}, town = false, world = 'Dungeon', zone = 'Dungeon', task_ticks = {}, waypoints = 0, teleports = 0 }
    f.settings = { use_teleport_transition = false }
    package.loaded['core.settings'] = f.settings
    package.loaded['core.tasks.turn_in_rewards'] = { tick = function(active) f.task_ticks[#f.task_ticks + 1] = active end }
    console = { print = function() end }
    attributes = { PLAYER_IN_TOWN_LEVEL_AREA = 1 }
    get_time_since_inject = function() return f.now end
    get_local_player = function() return { is_dead = function() return false end, get_attribute = function() return f.town and 1 or 0 end, get_buffs = function() return {} end } end
    get_current_world = function() return { get_name = function() return f.world end, get_current_zone_name = function() return f.zone end } end
    get_quests = function()
        local out = {}
        for _, name in ipairs(f.quests) do out[#out + 1] = { get_name = function() return name end } end
        return out
    end
    actors_manager = { get_all_actors = function() return {} end }
    teleport_to_waypoint = function() f.waypoints = f.waypoints + 1 end
    warplan = { teleport_to_activity = function() f.teleports = f.teleports + 1 end }
    get_aether_count = function() return 0 end
    AlfredTheButlerPlugin, PLUGIN_alfred_the_butler, target_selector = nil, nil, nil
    ArkhamAsylumPlugin, InfernalHordesPlugin, ReaperPlugin, WonderCityPlugin, HelltideRevampedPlugin, CustomPlugin = nil, nil, nil, nil, nil, nil
    f.o = dofile(root .. 'core/orchestrator.lua')
    function f.plugin(name)
        local p = { enabled = false, enables = 0, disables = 0 }
        p.enable = function() p.enables = p.enables + 1; p.enabled = true end
        p.disable = function() p.disables = p.disables + 1; p.enabled = false end
        p.status = function() return { enabled = p.enabled } end
        _G[name] = p
        return p
    end
    function f.tick(seconds) f.now = f.now + (seconds or 0); f.o.tick() end
    function f.task_active() return f.task_ticks[#f.task_ticks] end
    return f
end

-- A turn-in task cannot bypass outgoing cleanup or the handoff cooldown,
-- even with automatic teleport disabled.
do
    local f = fixture(); local p = f.plugin('ArkhamAsylumPlugin')
    f.quests = { 'WarPlans_QST_ThePit' }; f.tick(); equal(p.enables, 1)
    f.quests = { 'WarPlans_QST_TurnIn_Rewards' }; f.tick(1); equal(f.task_active(), false)
    f.tick(400); equal(p.disables, 0, 'cleanup timeout cannot abandon loot'); equal(f.task_active(), false)
    f.town = true; f.tick(); equal(p.disables, 1); equal(f.task_active(), false)
    f.tick(5); equal(f.task_active(), true)
    f.o.release_all(); equal(f.task_active(), false, 'master stop resets internal task')
end

-- Two boss quests must serialize around the outgoing run_once callback.
do
    local f = fixture(); local p = f.plugin('ReaperPlugin'); local runs = {}
    p.run_once = function(id, _, callback) p.enabled = true; runs[#runs + 1] = { id = id, callback = callback } end
    f.quests = { 'WarPlans_QST_BossLair_Zir' }; f.tick(); equal(runs[1].id, 'zir')
    f.quests = { 'WarPlans_QST_BossLair_Andariel' }; f.tick(1); equal(#runs, 1)
    f.tick(301); equal(#runs, 1); equal(p.disables, 0)
    runs[1].callback(); f.tick(); equal(p.disables, 1); equal(#runs, 1)
    f.tick(5); equal(#runs, 2); equal(runs[2].id, 'andariel')
    runs[1].callback(); f.quests = {}; f.tick(); equal(p.disables, 1, 'stale completion cannot finish new run')
end

-- Stable overlap selection retains the active boss while its quest exists.
do
    local f = fixture(); local p = f.plugin('ReaperPlugin'); local runs = {}
    p.run_once = function(id) p.enabled = true; runs[#runs + 1] = id end
    f.quests = { 'WarPlans_QST_BossLair_Zir' }; f.tick()
    f.quests[2] = 'WarPlans_QST_BossLair_Andariel'
    for _ = 1, 5 do f.tick(1) end
    equal(#runs, 1); equal(runs[1], 'zir')
end

-- Self-disable while still matched is observed, then retried after the gap.
do
    local f = fixture(); local p = f.plugin('ArkhamAsylumPlugin')
    f.quests = { 'WarPlans_QST_ThePit' }; f.tick(); p.enabled = false
    f.tick(1); equal(p.enables, 1); f.tick(5); equal(p.enables, 2)
end

-- Status-less plugin contracts can be owned and released.
do
    local f = fixture(); local p = f.plugin('CustomPlugin'); p.status = nil
    f.o.quest_plugin_map = { WarPlans_QST_Custom = 'CustomPlugin' }
    f.quests = { 'WarPlans_QST_Custom' }; f.tick(); f.tick(1); equal(p.enables, 1)
    equal(f.o.release_all(), true); equal(p.disables, 1)
end

-- A failing disable blocks both plugin and task handoffs; master stop retries.
do
    local f = fixture(); local p = f.plugin('HelltideRevampedPlugin'); local nextp = f.plugin('ArkhamAsylumPlugin')
    f.quests = { 'WarPlans_QST_Helltide_TorturedGifts' }; f.tick()
    p.disable = function() error('temporary disable failure') end
    f.quests = { 'WarPlans_QST_ThePit' }; f.tick(1); f.tick(10); equal(nextp.enables, 0)
    equal(f.o.release_all(), false)
    p.disable = function() p.enabled = false; p.disables = p.disables + 1 end
    equal(f.o.release_all(), true); equal(p.disables, 1)
end

-- A host quest-read error does not become a false empty snapshot.
do
    local f = fixture(); local p = f.plugin('HelltideRevampedPlugin')
    f.quests = { 'WarPlans_QST_Helltide_TorturedGifts' }; f.tick()
    get_quests = function() error('loading') end; f.tick(1); equal(p.disables, 0)
end

-- Turning teleport off cancels a pending sequence and its enable gate.
do
    local f = fixture(); local p = f.plugin('ArkhamAsylumPlugin')
    f.settings.use_teleport_transition = true; f.quests = { 'WarPlans_QST_ThePit' }; f.tick(); equal(p.enables, 0)
    f.settings.use_teleport_transition = false; f.tick(1); equal(p.enables, 1); equal(f.waypoints, 0)
end

-- Cold-start tasks wait for the orchestrator's own teleport sequence.
do
    local f = fixture(); f.settings.use_teleport_transition = true
    f.quests = { 'WarPlans_QST_TurnIn_Rewards' }; f.tick(); equal(f.task_active(), false)
    f.tick(3); equal(f.task_active(), false); equal(f.waypoints, 1)
end

-- Hordes chest/RESET completion remains authoritative after the old 300s cap.
do
    local f = fixture(); local p = f.plugin('InfernalHordesPlugin'); local done = false
    p.chests_done = function() return done end
    f.world = 'S05_BSK'; f.quests = { 'WarPlans_QST_InfernalHordes_BSK' }; f.tick()
    f.quests = { 'WarPlans_QST_TurnIn_Rewards' }; f.tick(1); f.tick(400)
    equal(p.disables, 0); equal(f.task_active(), false)
    done = true; f.world = 'Town'; f.tick(); equal(p.disables, 1)
end

-- The altar watchdog cannot invent boss/chest completion.
do
    local f = fixture(); local p = f.plugin('ReaperPlugin')
    p.status = function() return { enabled = p.enabled, external = true, task = { name = 'Interact Altar' } } end
    p.run_once = function() p.enabled = true end
    f.quests = { 'WarPlans_QST_BossLair_Zir' }; f.tick(); f.tick(1); f.tick(31)
    equal(p.disables, 0); equal(p.enabled, true)
end

-- Joining Alfred's active cycle must not replace its original caller.
do
    local f = fixture(); f.settings.use_teleport_transition = true; local triggers = 0
    local s = { enabled = true, trigger_tasks = true }
    AlfredTheButlerPlugin = { get_status = function() return s end, trigger_tasks = function() triggers = triggers + 1 end }
    f.quests = { 'WarPlans_QST_ThePit' }; f.tick(); f.tick(3); equal(f.waypoints, 1)
    f.zone = 'Skov_Temis'; f.town = true; f.tick(6); equal(triggers, 0)
    f.tick(10); equal(f.teleports, 0)
end

-- A recent Alfred completion never masks a new live salvage cycle.
do
    local f = fixture(); f.settings.use_teleport_transition = true; f.zone = 'Skov_Temis'; f.town = true
    local s = { enabled = true }; local callback
    AlfredTheButlerPlugin = { get_status = function() return s end, trigger_tasks = function(_, cb) callback = cb end }
    f.quests = { 'WarPlans_QST_ThePit' }; f.tick(); f.tick(3); assert(callback)
    callback(); s.trigger_tasks = true; s.need_trigger = true
    f.tick(7); equal(f.teleports, 0)
end

-- Real turn-in state also yields to an Alfred trigger queued between ticks.
do
    local f = fixture(); f.zone = 'Skov_Temis'
    local interacted = 0; local s = { enabled = true }
    AlfredTheButlerPlugin = { get_status = function() return s end }
    actors_manager.get_all_actors = function() return { { get_skin_name = function() return 'NPC_QST_X2_Tyrael_NonCombat' end, get_position = function() return {} end } } end
    get_player_position = function() return { dist_to = function() return 0 end } end
    loot_manager = { interact_with_object = function() interacted = interacted + 1 end }
    local task = dofile(root .. 'core/tasks/turn_in_rewards.lua')
    task.tick(true); equal(task.get_state(), 'APPROACH_NPC')
    s.external_trigger = true; task.tick(true); equal(interacted, 0)
    s.external_trigger = false; task.tick(true); equal(interacted, 1)
    task.tick(false); equal(task.get_state(), 'IDLE')
end
-- Cold start adopts an active matching Horde run without resetting it.
do
    local f = fixture(); f.settings.use_teleport_transition = true
    local p = f.plugin('InfernalHordesPlugin'); p.enabled = true
    p.chests_done = function() return false end
    f.world = 'S05_BSK'; f.quests = { 'WarPlans_QST_InfernalHordes_BSK' }
    f.tick(); f.tick(10); equal(p.enables, 0); equal(f.waypoints, 0)
    f.o.release_all(); equal(p.disables, 1)
end

-- Teleport retries leave the native channel intact, and absent world data
-- cannot confirm arrival or release the incoming plugin.
do
    local f = fixture(); f.settings.use_teleport_transition = true
    f.zone = 'Skov_Temis'; f.town = true
    local p = f.plugin('ArkhamAsylumPlugin')
    f.quests = { 'WarPlans_QST_ThePit' }; f.tick(); f.tick(3); equal(f.teleports, 1)
    f.tick(3); equal(f.teleports, 1)
    get_current_world = function() return nil end
    f.tick(3); equal(p.enables, 0); equal(f.teleports, 1)
end

-- A quest destination appearing early cannot bypass the outgoing gap.
do
    local f = fixture(); local p = f.plugin('HelltideRevampedPlugin')
    f.quests = { 'WarPlans_QST_Helltide_TorturedGifts' }; f.tick()
    f.settings.use_teleport_transition = true
    f.quests = { 'WarPlans_QST_ThePit' }; f.tick(1); f.tick(3)
    equal(f.waypoints, 0); f.tick(2); equal(f.waypoints, 1)
end

print('PASS WarPigs: serialized tasks/bosses, cleanup gates, ownership, snapshot errors, teleport cancellation, Alfred callbacks, native turn-in')
