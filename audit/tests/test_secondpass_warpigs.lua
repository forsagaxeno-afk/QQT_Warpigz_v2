-- Independent adversarial review of the actual dispatcher and creator modules.
local count, failures = 0, {}
local function eq(a,b,message)
    assert(a==b,(message or 'mismatch') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a))
    count=count+1
end
local function case(name, run)
    local ok,err=pcall(run)
    if not ok then failures[#failures+1]=name .. ': ' .. tostring(err) end
end
local function fixture()
    local f={now=100,world='Sanctuary',zone='Skov_Temis',town=true,dead=false,quests={},
        waypoints=0,teleports=0,interactions=0,task_active=false}
    local e=setmetatable({}, {__index=_G}); e._G=e
    e.console={print=function() end}
    e.attributes={PLAYER_IN_TOWN_LEVEL_AREA='town'}
    e.get_time_since_inject=function() return f.now end
    e.get_local_player=function() return {is_dead=function() return f.dead end,
        get_attribute=function() return f.town and 1 or 0 end,get_buffs=function() return {} end} end
    e.get_current_world=function()
        if f.world==nil then return nil end
        return {get_name=function() return f.world end,get_current_zone_name=function() return f.zone end,
            get_world_id=function() return 8 end}
    end
    e.get_quests=function() return f.quests end
    e.actors_manager={get_all_actors=function() return {} end}
    e.get_player_position=function() return {dist_to=function() return 0 end} end
    e.teleport_to_waypoint=function() f.waypoints=f.waypoints+1 end
    e.warplan={teleport_to_activity=function() f.teleports=f.teleports+1 end}
    e.get_aether_count=function() return 0 end
    e.revive_at_checkpoint=function() f.revives=(f.revives or 0)+1 end
    e.loot_manager={interact_with_object=function() f.interactions=f.interactions+1 end}
    e.pathfinder={request_move=function() f.moves=(f.moves or 0)+1 end}
    f.settings={enabled=true,manage_whispers=false,use_teleport_transition=false}
    local modules={['core.settings']=f.settings,['core.tasks.turn_in_rewards']={tick=function(active) f.task_active=active end}}
    local root=SUITE_ROOT .. '/WarPigs-1.0.0/'
    e.require=function(name)
        if modules[name] then return modules[name] end
        local value=assert(loadfile(root .. name:gsub('%.','/') .. '.lua','t',e))()
        modules[name]=value; return value
    end
    f.o=e.require('core.orchestrator'); f.e=e
    function f.quest(name) return {get_name=function() return name end} end
    function f.set_quest(name) f.quests=name and {f.quest(name)} or {} end
    function f.plugin(name)
        local p={enabled=false,enables=0,disables=0}
        p.enable=function() p.enabled=true; p.enables=p.enables+1 end
        p.disable=function() p.enabled=false; p.disables=p.disables+1 end
        p.status=function() return {enabled=p.enabled} end
        e[name]=p; return p
    end
    function f.tick(dt) f.now=f.now+(dt or 0.5); f.o.tick() end
    function f.turnin() return assert(loadfile(root .. 'core/tasks/turn_in_rewards.lua','t',e))() end
    return f
end

case('stale quest name is unknown, not completion',function()
    local f=fixture(); local p=f.plugin('HelltideRevampedPlugin')
    f.set_quest('WarPlans_QST_Helltide_TorturedGifts'); f.tick(); eq(p.enables,1)
    f.quests={{get_name=function() error('stale handle') end}}
    f.tick(); eq(p.disables,0,'unreadable active quest must preserve current owner')
    f.quests={f.quest('')}; f.tick(); eq(p.disables,0,'empty name is not an empty log')
end)

case('sparse valid quest snapshots still dispatch',function()
    local f=fixture(); local p=f.plugin('HelltideRevampedPlugin')
    f.quests={[9]=f.quest('WarPlans_QST_Helltide_TorturedGifts')}
    f.tick(); eq(p.enables,1,'sparse quest key must not disappear under ipairs')
end)

case('loading preserves current activity and does not navigate',function()
    for _,location in ipairs({{world='Limbo',zone='[sno none]'},{world='',zone=''},{zone=''}}) do
        local f=fixture(); local p=f.plugin('HelltideRevampedPlugin')
        f.set_quest('WarPlans_QST_Helltide_TorturedGifts'); f.tick()
        f.world,f.zone=location.world,location.zone; f.quests={}
        f.tick(30); eq(p.disables,0,'empty loading snapshot cannot complete Helltide')
        eq(f.waypoints,0); eq(f.teleports,0)
    end
end)

case('missing town attribute cannot release a dungeon owner',function()
    local f=fixture(); local p=f.plugin('ArkhamAsylumPlugin')
    f.world,f.zone,f.town='PitDungeon','PitDungeon',false
    f.set_quest('WarPlans_QST_ThePit'); f.tick()
    f.e.attributes={}; f.set_quest('WarPlans_QST_TurnIn_Rewards')
    f.tick(30); eq(p.disables,0,'unknown town flag is not town arrival')
    eq(f.task_active,false)
end)

case('unreadable Alfred status holds direct turn-in',function()
    local f=fixture(); local task=f.turnin()
    f.e.AlfredTheButlerPlugin={get_status=function() error('transient status unavailable') end}
    f.e.actors_manager.get_all_actors=function()
        return {{get_skin_name=function() return 'NPC_QST_X2_Tyrael_NonCombat' end,get_position=function() return {} end}}
    end
    task.tick(true); task.tick(true)
    eq(f.interactions,0,'unreadable Alfred ownership must prevent NPC interaction')
    f.zone='OtherTown'; task.tick(true)
    eq(f.waypoints,0,'unreadable Alfred ownership must prevent teleport')
end)

case('queued Alfred holds direct turn-in before its running flag appears',function()
    local f=fixture(); local task=f.turnin()
    f.e.AlfredTheButlerPlugin={get_status=function() return {enabled=true,pending=true} end}
    f.e.actors_manager.get_all_actors=function()
        return {{get_skin_name=function() return 'NPC_QST_X2_Tyrael_NonCombat' end,get_position=function() return {} end}}
    end
    task.tick(true); task.tick(true)
    eq(f.interactions,0,'queued service must retain the NPC interaction lane')
    f.zone='OtherTown'; task.tick(true)
    eq(f.waypoints,0,'queued service must retain the teleport lane')
end)

case('stale Alfred callback cannot grant grace after dispatcher release',function()
    local f=fixture(); f.settings.use_teleport_transition=true
    local callback
    f.e.AlfredTheButlerPlugin={get_status=function() return {enabled=true,need_trigger=true} end,
        trigger_tasks=function(_,cb) callback=cb end}
    f.set_quest('WarPlans_QST_ThePit'); f.tick()
    assert(callback,'expected an owned maintenance request')
    f.o.release_all(); callback()
    eq(f.o.alfred_idle(),false,'released request must not authorize new advisory work')
end)

local function add_creator(f)
    local e=f.e
    f.psettings={enabled=true,table_actor_name='Warplans_Vendor'}
    f.selected={}; f.confirms=0
    e.get_screen_width=function() return 1920 end
    e.get_screen_height=function() return 1080 end
    e.warplan.is_ready=function() return true end
    e.warplan.selected_count=function() return #f.selected end
    e.warplan.selected_path=function() return {(table.unpack or unpack)(f.selected)} end
    e.warplan.required_picks=function() return 1 end
    e.warplan.get_selectable_now=function() return #f.selected==0 and {7} or {} end
    e.warplan.node_name=function() return 'Warplans_Helltide' end
    e.warplan.select_node=function(id) f.selected[#f.selected+1]=id; return true end
    e.warplan.deselect_last=function() return table.remove(f.selected)~=nil end
    e.warplan.is_complete=function() return #f.selected==1 end
    e.warplan.confirm=function() f.confirms=f.confirms+1 end
    local creator_environment=setmetatable({require=function(name)
        assert(name=='core.settings'); return f.psettings
    end},{__index=e})
    f.planner=assert(loadfile(SUITE_ROOT .. '/WarPug-1.0.0/core/planner.lua','t',creator_environment))()
    e.WarPigsPlugin={status=function() return {enabled=true,busy=f.o.is_busy()} end}
    e.WarPugPlugin={status=function() return {enabled=true,state=f.planner.get_current_state()} end}
end

case('real dispatcher and creator serialize a managed Whisper visit',function()
    local f=fixture(); f.settings.manage_whispers=true; add_creator(f)
    local s={enabled=true,api_version=2,running=false,pending=false}; local triggers,callback=0
    f.e.SilentRavenPlugin={get_status=function() return s end,
        set_managed=function(owner,enabled) s.managed_by=enabled and owner or nil; return true end,
        trigger_tasks=function(owner,cb,guard)
            eq(guard(),true,'companions are clear when Whisper request is submitted')
            triggers=triggers+1; callback=cb; s.owner=owner; s.running=true; return true
        end,
        cancel=function() s.running=false; return true end}
    f.tick(); f.planner.tick(); eq(f.planner.get_current_state(),'IDLE','creator waits for visit stabilization')
    f.tick(1.1); f.planner.tick(); eq(triggers,1); eq(f.confirms,0,'creator waits for Whisper completion')
    s.running=false; s.last_result='no_reward'; callback('no_reward')
    f.tick(); f.planner.tick(); eq(f.planner.get_current_state(),'FIND_PATH')
    f.tick(); f.planner.tick(); eq(f.planner.get_current_state(),'CONFIRMING')
    f.tick(); f.planner.tick(); eq(f.confirms,1)
    local activity=f.plugin('HelltideRevampedPlugin')
    f.set_quest('WarPlans_QST_Helltide_TorturedGifts'); f.tick(); f.planner.tick()
    eq(activity.enables,1,'dispatcher starts accepted plan activity once')
    eq(f.planner.get_current_state(),'IDLE','creator observes accepted plan')
    eq(triggers,1,'same Temis visit cannot resubmit Whispers')
end)

case('creator accepts confirmed dispatcher grace only for sticky pending work',function()
    local f=fixture(); add_creator(f)
    f.e.WarPigsPlugin.status=function() return {enabled=true,busy=false,alfred_idle=true} end
    f.e.AlfredTheButlerPlugin={get_status=function() return {enabled=true,need_trigger=true} end}
    f.planner.tick(); eq(f.planner.get_current_state(),'FIND_PATH','confirmed completion grace permits new plan')
    for _,flag in ipairs({'trigger_tasks','external_trigger','running','teleport','inventory_full','need_repair'}) do
        f=fixture(); add_creator(f)
        f.e.WarPigsPlugin.status=function() return {enabled=true,busy=false,alfred_idle=true} end
        f.e.AlfredTheButlerPlugin={get_status=function() return {enabled=true,need_trigger=true,[flag]=true} end}
        f.planner.tick(); eq(f.planner.get_current_state(),'IDLE','grace must not mask ' .. flag)
    end
    for _,status in ipairs({{enabled=false,busy=false,alfred_idle=true},{enabled=true,busy=false}}) do
        f=fixture(); add_creator(f)
        f.e.WarPigsPlugin.status=function() return status end
        f.e.AlfredTheButlerPlugin={get_status=function() return {enabled=true,need_trigger=true} end}
        f.planner.tick(); eq(f.planner.get_current_state(),'IDLE','disabled/old dispatcher cannot grant grace')
    end
end)

case('stale Temis zone cannot conceal an invalid planner world',function()
    for _,value in ipairs({{name='Limbo',id=8},{name='',id=8},{name='Sanctuary'}}) do
        local f=fixture(); add_creator(f)
        f.e.get_current_world=function() return {get_current_zone_name=function() return 'Skov_Temis' end,
            get_world_id=function() return value.id end,get_name=function() return value.name end} end
        f.planner.tick(); eq(f.planner.get_current_state(),'IDLE','unknown/loading world must not begin planning')
        eq(f.confirms,0)
    end
end)

case('standalone creator yields to active or queued SilentRaven',function()
    for _,state in ipairs({{enabled=true,running=true},{enabled=true,pending=true},{enabled=false,running=true}}) do
        local f=fixture(); add_creator(f); f.e.WarPigsPlugin=false
        f.e.SilentRavenPlugin={get_status=function() return state end}
        f.planner.tick(); eq(f.planner.get_current_state(),'IDLE')
        state.running,state.pending=false,false
        f.planner.tick(); eq(f.planner.get_current_state(),'FIND_PATH','creator resumes after Whisper release')
    end
    local f=fixture(); add_creator(f); f.e.WarPigsPlugin=false
    f.e.SilentRavenPlugin={get_status=function() error('unavailable') end}
    f.planner.tick(); eq(f.planner.get_current_state(),'IDLE','unreadable Whisper owner')
end)

case('creator prioritizes actual collection over sticky legacy Looter flags',function()
    local function state_with(looter)
        local f=fixture(); add_creator(f); f.e.WarPigsPlugin=false
        f.e.LooteerPlugin=looter; f.planner.tick(); return f.planner.get_current_state()
    end
    eq(state_with({get_enabled=function() return true end,is_actively_looting=function() return true end}),'IDLE')
    eq(state_with({get_enabled=function() return true end,is_actively_looting=function() return false end,
        getSettings=function() return true end}),'FIND_PATH','modern idle overrides sticky legacy flag')
    eq(state_with({get_enabled=function() return false end,is_actively_looting=function() return true end}),'FIND_PATH','disabled collector')
    eq(state_with({getSettings=function(key) return key=='enabled' and true or nil end}),'FIND_PATH','legacy nil is stored false')
    eq(state_with({getSettings=function() return true end}),'IDLE','legacy active collector')
    eq(state_with({get_enabled=function() return true end,getSettings=function() error('stale') end}),'IDLE','unknown collector status')
    eq(state_with({get_enabled=function() error('stale') end,getSettings=function() return nil end}),'IDLE','modern enable error cannot become legacy disabled')
    eq(state_with({is_actively_looting=function() error('stale') end,getSettings=function() return nil end}),'IDLE','modern activity error cannot become legacy disabled')
    eq(state_with({get_enabled=function() return true end,is_actively_looting=function() error('stale') end,
        getSettings=function() return nil end}),'IDLE','modern activity error cannot become legacy idle')
    eq(state_with({is_actively_looting=function() error('stale') end,is_idle=function() return true end,
        getSettings=function() return nil end}),'FIND_PATH','explicit secondary modern idle can resolve unknown activity')
end)

if #failures>0 then error(table.concat(failures,'\n')) end
print('Second-pass WarPigs/WarPug assertions: ' .. count)
