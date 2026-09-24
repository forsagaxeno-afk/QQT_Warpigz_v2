local root = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local function check(name, fn)
    fn()
    print('PASS common Batmobile: ' .. name)
end

check('Batmobile processes a traversal buff despite a temporarily empty actor scan', function()
    local Vec = {}; Vec.__index = Vec
    function Vec:new(x, y, z) return setmetatable({_x=x, _y=y, _z=z or 0}, self) end
    function Vec:x() return self._x end
    function Vec:y() return self._y end
    function Vec:z() return self._z end
    local now, movement_requests = 10, 0
    local player = {get_position = function() return Vec:new(10, 0) end,
        get_buffs = function() return {{name = function() return 'Player_Traversal_Climb' end}} end,
        get_attribute = function() return 0 end, get_character_class_id = function() return 0 end,
        is_dead = function() return false end}
    local crossed = {get_position = function() return Vec:new(0, 0) end,
        get_skin_name = function() return 'Traversal_Gizmo_Up' end}
    local actors = {}
    local settings = {step=0.5, normalizer=2, path_smooth_step=0, log_level=0,
        plugin_label='test', use_movement=false, spell_interval=0.15, min_spell_dist=3,
        explore_path_budget_ms=80}
    local modules = {
        ['core.settings'] = settings,
        ['core.tracker'] = {bench_enabled=false, bench_start=function() end,
            bench_stop=function() end, bench_count=function() end},
        ['core.explorer'] = {backtracking=false, frontier_count=0, backtrack={}, visited={},
            update=function() end, select_node=function() end, reset=function() end,
            clear_frontiers_in_box=function() return 0 end},
        ['core.movement_engine'] = {pick=function() end},
        ['core.pathfinder'] = {find_path=function(a,b) return {a,b},false end,
            clear_wall_penalty_cache=function() end},
    }
    local env = setmetatable({vec3=Vec, get_time_since_inject=function() return now end,
        get_local_player=function() return player end,
        get_current_world=function() return {get_current_zone_name=function() return 'TEST' end} end,
        attributes={PLAYER_IN_TOWN_LEVEL_AREA=1}, console={print=function() end},
        actors_manager={get_all_actors=function() return actors end},
        utility={set_height_of_valid_position=function(p) return p end,
            is_point_walkeable=function() return true end, can_cast_spell=function() return true end,
            is_ray_cast_walkeable=function() return true end},
        cast_spell={position=function() return true end},
        pathfinder={request_move=function() movement_requests=movement_requests+1 end},
        interact_object=function() end}, {__index=_G})
    env._G = env
    env.require = function(name)
        if modules[name] ~= nil then return modules[name] end
        modules[name] = assert(loadfile(root .. '/Batmobile-1.0.12/' .. name:gsub('%.','/') .. '.lua', 't', env))()
        return modules[name]
    end
    local nav = env.require('core.navigator')
    nav.last_trav = crossed
    nav.target = Vec:new(50,0)
    nav.update_trap_state = function() end
    nav.move() -- buff starts while enumeration is empty
    assert(#nav.trav_history == 1, 'saved traversal was ignored when the first buff tick had no actors')
    actors = {crossed}
    now = 10.6 -- pass the actor cache interval; continuous buff still active
    nav.move()
    assert(#nav.trav_history == 1, 'the continuous buff edge was consumed without processing its crossing')
    assert(movement_requests == 0, 'a continuous traversal animation must block movement')
end)
