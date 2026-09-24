-- Actual standalone modules, QQT-shaped host mocks. No game execution.
local root = SUITE_ROOT .. '/SilentRaven-0.1.3/'
local checks = 0
local function eq(a,b,message)
    assert(a==b,(message or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b))
    checks=checks+1
end
local function harness()
    local e=setmetatable({}, {__index=_G}); e._G=e
    local c={time=100,zone='Skov_Temis',enabled=true,quest=true,text='Return to the Tree of Whispers',
        panel=false,items={},accepts=0,selects=0,interacts=0,clears=0,moves=0,teleports=0,escapes=0,
        entries={[1]={sno=1087411,valid=true,internal_name='BountyMeta_Cache_Helms'}},selected=0}
    local V={};V.__index=V
    function V:x() return self[1] end;function V:y() return self[2] end;function V:z() return self[3] end
    e.vec3={new=function(_,x,y,z) return setmetatable({x,y,z},V) end}
    c.pos=e.vec3:new(2596,-495,30)
    c.npc={get_skin_name=function() return 'temis_bounty_meta_raven_npc' end,
        is_interactable=function() return true end,get_position=function() return c.npc_pos or c.pos end}
    e.get_time_since_inject=function() return c.time end
    e.get_current_world=function() if c.zone==nil then return nil end return {get_current_zone_name=function() return c.zone end} end
    local player={is_dead=function() return c.dead == true end,get_position=function() return c.pos end,get_inventory_items=function()
        if c.inventory_error then error('stale inventory') end return c.items end,get_consumable_items=function() return {} end}
    e.get_local_player=function() return player end
    e.actors_manager={get_ally_actors=function() return c.hide_npc and {} or {c.npc} end}
    e.get_quests=function()
        if c.quest_error then error('loading') end
        if not c.quest then return {} end
        return {{get_name=function() return 'Bounty_Meta_Quest' end,get_objectives=function() return {{text=c.text}} end}}
    end
    e.console={print=function() end}
    e.pathfinder={request_move=function() c.moves=c.moves+1 end,clear_stored_path=function() c.clears=c.clears+1 end}
    e.utility={send_key_press=function() c.escapes=c.escapes+1;c.panel=false end}
    e.interact_object=function() c.interacts=c.interacts+1;if not c.no_panel then c.panel=true end end
    e.teleport_to_waypoint=function() c.teleports=c.teleports+1 end
    e.quest_reward={is_open=function() return c.panel end,enumerate=function() return c.entries end,
        select=function(index) c.selects=c.selects+1;c.selected=c.wrong_select and 99 or index;return true end,
        selected_index=function() return c.selected end,accept=function()
            c.accepts=c.accepts+1
            if c.accept_throws then error('ambiguous send') end
            if c.deliver then
                c.items={{get_sno_id=function() return 1087411 end,get_acd=function() return 1234 end,get_stack_count=function() return 1 end}}
                c.panel=false;c.quest=false
            end
            return true
        end}
    local function widget(value) return {get=function() return value end,set=function(_,v) value=v end,get_state=function() return value and 1 or 0 end} end
    local gui={elements={main_toggle={get=function() return c.enabled end},debug_toggle=widget(false),auto_fire_toggle=widget(false),
        prefer_legendary_toggle=widget(true),legendary_bonus_slider=widget(50),manual_fire_keybind=widget(false),reload_catalog_toggle=widget(false)},render=function() end}
    -- Intentionally poison the shared short module keys.
    local modules={gui={poison=true},['core.tracker']={poison=true},['core.settings']={poison=true},['silent_raven.gui']=gui}
    e.package={loaded=modules}
    e.require=function(name)
        if modules[name]~=nil then return modules[name] end
        local value=assert(loadfile(root..name:gsub('%.','/')..'.lua','t',e))()
        modules[name]=value;return value
    end
    e.on_update=function(fn)c.update=fn end;e.on_render_menu=function()end
    assert(loadfile(root..'main.lua','t',e))();c.update()
    c.api=e.SilentRavenPlugin;c.tracker=e.require('silent_raven.tracker');c.settings=e.require('silent_raven.settings')
    c.fsm=e.require('silent_raven.fsm');c.whispers=e.require('silent_raven.whispers');c.rewards=e.require('silent_raven.rewards')
    function c.tick(delta) c.time=c.time+(delta or 0.1);c.update() end
    function c.start(guard) c.api.set_managed('WarPigs',true);return c.api.trigger_tasks('WarPigs',function(result)c.callbacks=(c.callbacks or 0)+1;c.result=result end,guard) end
    return c,e
end

-- API queue ownership, strict cancellation and paused ownership.
do
    local c=harness();eq(c.api.get_status().api_version,2,'versioned contract')
    eq(c.start(),true,'queue accepted');eq(c.api.get_status().pending,true,'pending exposed');eq(c.api.get_status().owner,'WarPigs')
    eq(c.api.trigger_tasks('Other',function()error('stolen')end),false,'managed requests rejected')
    eq(c.api.trigger_tasks('WarPigs'),false,'same owner cannot overwrite callback')
    eq(c.api.cancel('Other'),false,'foreign cancel rejected');eq(c.api.get_status().pending,true)
    eq(c.api.cancel('WarPigs'),true);eq(c.callbacks,1);eq(c.result,'cancelled')
    eq(c.clears,0,'pending queue never owns path');eq(c.escapes,0)
    eq(c.api.cancel('WarPigs'),false);eq(c.callbacks,1,'completion exactly once')
    eq(c.api.pause('WarPigs'),true);eq(c.api.resume('Other'),false);eq(c.api.resume('WarPigs'),true)
end
-- Temis only, disabled pending delivery, managing doesn't enable the user toggle.
do
    local c=harness();c.zone='Hawe_TreeOfWhispers';eq(c.start(),false,'Hawezar rejected');eq(c.teleports,0)
    c.zone='Skov_Temis';eq(c.start(),true);c.enabled=false;c.tick();eq(c.result,'disabled');eq(c.callbacks,1)
    eq(c.api.get_status().enabled,false);eq(c.api.trigger_tasks('WarPigs'),false)
    eq(c.api.trigger_tasks_with_teleport('WarPigs'),false,'managed teleport rejected')
end
-- Real cache receipt, no double accept, same visit latch, new visit rearmed while idle.
do
    local c=harness();c.deliver=true;eq(c.start(),true);c.tick();c.tick();eq(c.accepts,1)
    c.tick();eq(c.callbacks,nil,'confirmation needs elapsed second sample');c.tick(0.6)
    eq(c.result,'success');eq(c.callbacks,1);eq(c.accepts,1)
    eq(c.start(),true);c.tick();eq(c.result,'skipped_latched');eq(c.accepts,1)
    c.zone=nil;c.tick();eq(c.tracker.last_zone_handled,'Skov_Temis','loading does not unlatch')
    c.zone='Dungeon';c.tick();eq(c.tracker.last_zone_handled,nil)
    c.zone='Skov_Temis';c.quest=true;c.tick();eq(c.start(),true);c.tick();c.tick();eq(c.accepts,2,'return visit is eligible')
end
-- Lost quest data or empty quest list without receipt never prove success/retry.
for _, failure in ipairs({'quest_error','quest_empty','accept_throws'}) do
    local c=harness();eq(c.start(),true);c.tick()
    if failure=='accept_throws' then c.accept_throws=true end
    c.tick();eq(c.accepts,1)
    if failure=='quest_error' then c.quest_error=true else c.quest=false end
    c.panel=false;c.tick();c.tick(8)
    eq(c.result,'unconfirmed',failure);eq(c.accepts,1,'ambiguous claim is never retried');eq(c.callbacks,1)
end
-- Wrong selected index and all-invalid entries cannot accept.
do
    local c=harness();c.wrong_select=true;c.start();c.tick();c.tick();eq(c.accepts,0,'selection mismatch stops claim')
    local best=c.rewards.pick_best_index({[1]={valid=false,sno=1087411}},c.settings);eq(best,nil,'invalid fallback removed')
    best=c.rewards.pick_best_index({metadata={valid=true,sno=1087411}},c.settings);eq(best,nil,'metadata is not a reward index')
end
-- Unknown inventory blocks destructive acceptance; English collecting skips walk.
do
    local c=harness();c.inventory_error=true;c.start();c.tick();c.tick();eq(c.accepts,0)
    c=harness();c.text='Collect Grim Favor (3/10)';c.start();c.tick();eq(c.result,'skipped_not_ready');eq(c.interacts,0)
end
-- Untranslated bounty still probes the verified NPC and honors reward priorities.
do
    local c=harness();c.text='Вернитесь к Древу Шёпота';c.deliver=true;c.start();c.tick();c.tick();eq(c.accepts,1)
    c=harness();c.text='Наберите 3/10';c.no_panel=true;c.start();c.tick();c.tick(10.1)
    eq(c.result,'skipped_not_ready');eq(c.accepts,0)
end
-- Visible but unreachable NPC eventually fails and releases callback.
do
    local c=harness();c.npc_pos={x=function()return 9000 end,y=function()return 9000 end,z=function()return 30 end}
    c.start();c.tick()
    for _=1,3 do c.tick(20.1);c.tick(1.6) end
    eq(c.result,'failed');eq(c.callbacks,1);eq(c.accepts,0)
end
-- Guard revocation while moving cannot erase a competing owner's path/UI.
do
    local c=harness();local allowed=true;c.hide_npc=true;c.pos={x=function()return 0 end,y=function()return 0 end,z=function()return 0 end}
    c.start(function()return allowed,'looter_busy'end);c.tick();eq(c.moves>0,true)
    local clears,escapes=c.clears,c.escapes;allowed=false;c.tick()
    eq(c.result,'cancelled');eq(c.tracker.last_reason,'looter_busy');eq(c.clears,clears);eq(c.escapes,escapes);eq(c.callbacks,1)
    c=harness();c.start(function()error('stale guard')end);c.tick();eq(c.result,'cancelled');eq(c.interacts,0)
end
-- Existing panel cannot be consumed. Managed auto/manual cannot race queue ownership.
do
    local c,e=harness();c.panel=true;c.start();c.tick();eq(c.result,'skipped_busy');eq(c.accepts,0)
    c=harness();c.api.set_managed('WarPigs',true)
    c.tick();eq(c.api.get_status().running,false);eq(c.interacts,0)
end
-- Zero-based reward tables keep their native first index; sparse lists stop.
do
    local c=harness();c.entries={[0]={sno=1087411,valid=true,internal_name='BountyMeta_Cache_Helms'}}
    c.deliver=true;c.start();c.tick();c.tick();eq(c.selected,0);eq(c.accepts,1)
    c=harness();c.entries={[3]={sno=1087411,valid=true,internal_name='BountyMeta_Cache_Helms'}}
    c.start();c.tick();c.tick();eq(c.accepts,0,'sparse indexing unsupported')
end
-- Explicit preemption cancel preserves a successor's movement and UI too.
do
    local c=harness();c.hide_npc=true;c.pos={x=function()return 0 end,y=function()return 0 end,z=function()return 0 end}
    c.start();c.tick();local clears,escapes=c.clears,c.escapes
    eq(c.api.cancel('Other',true),false);eq(c.api.get_status().running,true)
    eq(c.api.cancel('WarPigs',true),true);eq(c.clears,clears);eq(c.escapes,escapes);eq(c.callbacks,1)
    eq(c.api.set_managed('WarPigs',false),true);eq(c.api.get_status().managed_by,nil)
end
-- A continuation guard can change during selection; accept still cannot follow.
do
    local c,e=harness();local allowed=true
    e.quest_reward.select=function(index)c.selected=index;allowed=false;return true end
    c.start(function()return allowed,'alfred_busy'end);c.tick();c.tick()
    eq(c.accepts,0);eq(c.result,'cancelled');eq(c.tracker.last_reason,'alfred_busy')
end
-- Disabling or a normal cancel after ownership changed must preserve successor path.
for _, action in ipairs({'disable', 'cancel'}) do
    local c=harness();local allowed=true;c.hide_npc=true
    c.pos={x=function()return 0 end,y=function()return 0 end,z=function()return 0 end}
    c.start(function()return allowed,'looter_busy'end);c.tick()
    local clears,escapes=c.clears,c.escapes;allowed=false
    if action=='disable' then c.enabled=false;c.tick() else c.api.cancel('WarPigs') end
    eq(c.clears,clears,action..' preserves successor path');eq(c.escapes,escapes);eq(c.callbacks,1)
end
-- An explicit owner-verified clean stop clears its native movement even when
-- that owner has already revoked its continuation token.
do
    local c=harness();local allowed=true;c.hide_npc=true
    c.pos={x=function()return 0 end,y=function()return 0 end,z=function()return 0 end}
    c.start(function()return allowed,'request_revoked'end);c.tick();allowed=false
    local clears=c.clears;eq(c.api.cancel('WarPigs',false),true)
    eq(c.clears,clears+1,'verified clean stop clears own movement');eq(c.callbacks,1)
end
print('SilentRaven focused regressions: '..checks..' checks')
