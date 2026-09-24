-- Adversarial Alfred callers and actual SilentRaven/WarPug bridge contracts.
local checks = 0
local function eq(actual, expected, message)
    assert(actual == expected, (message or 'mismatch') .. ': ' .. tostring(actual) .. ' ~= ' .. tostring(expected))
    checks = checks + 1
end
local folders = {'WonderCity-main', 'ArkhamAsylum-1.0.6', 'HelltideRevamped-0.4', 'HordeDev-1.3.9'}
local function caller(folder, mode)
    local c = {now=100, calls=0, pauses=0, resumes=0, teleports=0, in_town=true, floor_loot=false,
        status={enabled=true, need_trigger=true}, callbacks={}}
    local settings = {salvage=true, use_alfred=true, town_zone='Skov_Temis', town_waypoint=1, return_for_loot=true}
    local tracker = {needs_salvage=true, has_salvaged=false}
    local utils = {player_in_zone=function(z) return c.in_town and z=='Skov_Temis' end,
        player_in_undercity=function() return false end, is_in_helltide=function() return true end}
    local env=setmetatable({}, {__index=_G}); env._G=env
    env.get_time_since_inject=function() return c.now end
    env.get_player_position=function() return {} end
    env.get_current_world=function() return {get_current_zone_name=function()return c.in_town and 'Skov_Temis' or 'Dungeon' end,
        get_name=function()return c.loading and 'Limbo' or 'World' end} end
    env.loot_manager={any_item_around=function() if c.loot_error then error('stale floor') end return c.floor_loot end}
    env.teleport_to_waypoint=function() c.teleports=c.teleports+1 end
    env.BatmobilePlugin={pause=function() c.pauses=c.pauses+1 end}
    env.console={print=function() end}
    c.api={get_status=function() if c.status_error then error('temporary status failure') end return c.status end,
        resume=function() c.resumes=c.resumes+1 end}
    local function trigger(_, cb)
        c.calls=c.calls+1;c.callbacks[#c.callbacks+1]=cb
        if mode=='reject' then return false end
        if mode=='throw' then error('failed before queue') end
        if mode=='throw_after_queue' then c.status.pending=true;error('queued, then threw') end
        if mode=='sync' then c.status.need_trigger=false;cb();return nil end
        if mode=='pending' then c.status.teleport=true end
        return nil
    end
    c.api.trigger_tasks=function(...)c.method='plain';return trigger(...)end
    c.api.trigger_tasks_with_teleport=function(...)c.method='teleport';return trigger(...)end
    env.AlfredTheButlerPlugin=c.api
    local modules={['core.settings']=settings,['core.tracker']=tracker,['core.utils']=utils}
    env.require=function(name) return assert(modules[name],name) end
    c.task=assert(loadfile(SUITE_ROOT..'/'..folder..'/tasks/alfred.lua','t',env))()
    c.env,c.tracker=env,tracker
    return c
end
for _, folder in ipairs(folders) do
    for _, mode in ipairs({'reject','throw','throw_after_queue'}) do
        local c=caller(folder,mode)
        eq(c.task.shouldExecute(),true,folder..' requests maintenance')
        eq(pcall(c.task.Execute),true,'trigger exception is contained')
        eq(c.task.status,mode=='reject' and 'idle' or 'waiting for alfred to complete','throw retains uncertainty; explicit rejection retires')
        c.now=105;c.task.shouldExecute();c.task.Execute()
        eq(c.calls,mode=='reject' and 2 or 1,'uncertain request is not resubmitted at retry boundary')
        if mode=='throw_after_queue' then
            c.now=120;c.task.shouldExecute();c.task.Execute();eq(c.calls,1,'pending-only queued work is not overwritten')
            eq(c.task.status,'waiting for alfred to complete')
            c.callbacks[1]();eq(c.task.status,'idle','late callback resolves still-owned uncertainty')
        elseif mode=='throw' then
            c.now=109;c.task.shouldExecute();eq(c.task.status,'waiting for alfred to complete')
            c.now=112;c.task.shouldExecute();eq(c.task.status,'idle','throw with no queue reconciles only after stable idle')
            c.callbacks[1]();eq(c.task.status,'idle','retired callback cannot revive request')
        else
            c.callbacks[1]();eq(c.task.status,'idle','rejected callback is obsolete')
        end
    end
    do
        local c=caller(folder,'nil');c.task.Execute();eq(c.task.status,'waiting for alfred to complete','legacy nil accepted')
        c.now=109;c.task.shouldExecute();eq(c.task.status,'waiting for alfred to complete','idle requires stable second sample')
        c.now=112;c.task.shouldExecute();eq(c.task.status,'idle','missing callback retires after observed quiet')
        c.callbacks[1]();eq(c.task.status,'idle');eq(c.tracker.has_salvaged,false,'quiet retirement is not a success claim')
    end
    do
        local c=caller(folder,'nil');c.task.Execute();c.now=109;c.task.Execute();c.now=112;c.task.Execute()
        eq(c.task.status,'idle','forced cleanup bypassing predicate still retires lost callback')
    end
    do
        local c=caller(folder,'sync');c.loot_error=true;c.task.Execute()
        eq(c.task.status~='waiting for alfred to complete',true,'synchronous callback and unreadable floor cannot retain WAITING')
        eq(c.resumes,0,'task cannot resume a pause it never acquired')
    end
    for _, field in ipairs({'trigger_tasks','external_trigger','teleport','paused','pending'}) do
        local c=caller(folder,'nil');c.status[field]=true;c.status.external_caller='Other'
        c.task.shouldExecute();c.task.Execute();eq(c.calls,0,'foreign '..field..' blocks trigger')
        eq(c.pauses,0,'foreign '..field..' does not pause Batmobile');eq(c.resumes,0)
    end
    -- Each intervening unknown/busy/paused sample invalidates quiet confirmation,
    -- including the direct Execute path used by forced cleanup.
    for _, execute_only in ipairs({false,true}) do
        for _, interrupted in ipairs({'unknown','trigger_tasks','paused','pending'}) do
            local c=caller(folder,'nil');c.task.Execute()
            local poll=execute_only and c.task.Execute or c.task.shouldExecute
            c.now=108;poll();c.now=109
            if interrupted=='unknown' then c.status_error=true else c.status[interrupted]=true end
            poll()
            c.status_error=false;c.status[interrupted]=nil;c.now=120;poll()
            eq(c.task.status,'waiting for alfred to complete','interrupted interval needs new idle samples')
            c.now=122.1;poll();eq(c.task.status,'idle','fresh quiet interval permits retirement')
        end
    end
    for _, terminal in ipairs({'teleport_done','teleport_failed'}) do
        local c=caller(folder,'nil');c.task.Execute();c.status.teleport=true;c.status[terminal]=true
        c.now=109;c.task.shouldExecute();c.now=112;c.task.shouldExecute()
        eq(c.task.status,'idle','terminal teleport latch is not live movement')
    end
    do
        local c=caller(folder,'nil');c.status={}
        eq(c.task.shouldExecute(),true,'malformed status is not confirmed disabled');c.task.Execute();eq(c.calls,0)
    end
    do
        local c=caller(folder,'nil');c.status_error=true
        eq(c.task.shouldExecute(),true,'unreadable owner retains queue');eq(pcall(c.task.Execute),true)
        eq(c.calls,0);eq(c.pauses,0)
    end
    do
        local c=caller(folder,'nil');c.task.Execute()
        c.env.AlfredTheButlerPlugin={get_status=function()return {enabled=true,trigger_tasks=true}end}
        c.callbacks[1]();eq(c.tracker.has_salvaged,false,'replaced-plugin callback cannot mark maintenance complete')
        eq(c.task.status,'waiting for alfred to complete','replaced-plugin callback cannot change local wait')
    end
end

-- Arkham keeps its own bounded retry only for an accepted plain request.
do
    local c=caller('ArkhamAsylum-1.0.6','nil');c.in_town=false;c.task.Execute()
    eq(c.method,'plain');eq(c.teleports,1,'plain accepted request starts own town hop')
    c.now=101;c.task.Execute();eq(c.teleports,1,'native channel debounce')
    c.now=103;c.task.Execute();eq(c.teleports,2,'interrupted own hop can retry')
    c.now=106;c.task.Execute();eq(c.teleports,3)
    c.now=109;c.task.Execute();eq(c.teleports,3,'at most three local attempts for one request')
end
for _, mode in ipairs({'reject','throw','throw_after_queue'}) do
    local c=caller('ArkhamAsylum-1.0.6',mode);c.in_town=false;c.task.Execute();c.now=103;c.task.Execute()
    eq(c.teleports,0,'unaccepted or uncertain request cannot authorize local teleport')
end
do
    local c=caller('ArkhamAsylum-1.0.6','nil');c.in_town=false;c.floor_loot=true;c.task.Execute()
    eq(c.method,'teleport');c.now=103;c.task.Execute();eq(c.teleports,0,'Alfred round-trip never receives a local retry')
end
for _, blocker in ipairs({'unknown','pending','foreign','loading','arrived'}) do
    local c=caller('ArkhamAsylum-1.0.6','nil');c.in_town=false;c.task.Execute();c.now=103
    if blocker=='unknown' then c.status_error=true elseif blocker=='pending' then c.status.pending=true
    elseif blocker=='foreign' then c.status.external_caller='Other' elseif blocker=='loading' then c.loading=true
    else c.in_town=true end
    c.task.Execute();eq(c.teleports,1,'local retry yields on '..blocker)
end

local function bridge_session()
    local c={now=10,zone='Skov_Temis',moves=0,clears=0,looting=false}
    local e=setmetatable({}, {__index=_G});e._G=e
    e.get_time_since_inject=function()return c.now end
    e.get_local_player=function()return {is_dead=function()return false end,get_attribute=function()return 1 end}end
    e.get_current_world=function()return {get_current_zone_name=function()return c.zone end,
        get_name=function()return 'World' end,get_world_id=function()return 123 end}end
    e.get_quests=function()return {}end;e.console={print=function()end}
    e.pathfinder={request_move=function()c.moves=c.moves+1 end,clear_stored_path=function()c.clears=c.clears+1 end}
    e.actors_manager={get_all_actors=function()return {}end}
    e.LooteerPlugin={get_enabled=function()return true end,is_actively_looting=function()return c.looting end,
        setSettings=function()error('bridge must not mutate Looter')end,disable=function()error('bridge must not disable Looter')end}
    local modules={['silent_raven.settings']={enabled=true,plugin_label='SilentRaven',plugin_version='0.1.4'},
        ['silent_raven.whispers']={in_whisper_town=function()return c.zone=='Skov_Temis' end,
            send_escape=function()end,stop_movement=function()c.clears=c.clears+1 end},
        ['core.settings']={enabled=true,plugin_version='1.0.0'}}
    e.require=function(name)
        if modules[name] then return modules[name] end
        local prefix=name:match('^silent_raven%.') and 'SilentRaven-0.1.3/' or 'WarPug-1.0.0/'
        local value=assert(loadfile(SUITE_ROOT..'/'..prefix..name:gsub('%.','/')..'.lua','t',e))()
        modules[name]=value;return value
    end
    c.raven=e.require('silent_raven.external');c.tracker=e.require('silent_raven.tracker');e.SilentRavenPlugin=c.raven
    c.planner=e.require('core.planner');e.WarPugPlugin=e.require('core.external')
    c.bridge=assert(loadfile(SUITE_ROOT..'/WarPigs-1.0.0/wp_silent_raven.lua','t',e))().new()
    e.WarPigsPlugin={status=function()return {enabled=true,busy=c.bridge:is_busy() or c.bridge:blocks_plan_creator()}end}
    c.bridge:observe(10,true);c.bridge:observe(11.1,true);c.now=11.1;c.env=e
    return c
end
-- Actual Raven queue + actual WarPug planner; either callback order yields one owner.
do
    local c=bridge_session();eq(c.bridge:tick(c.now,true),true);eq(c.raven.get_status().pending,true)
    c.planner.tick();eq(c.planner.get_current_state(),'IDLE','planner waits for reserved Whisper step')
    c.tracker.finish('skipped_not_ready');c.bridge:tick(c.now+0.1,false)
    c.planner.tick();eq(c.planner.get_current_state(),'APPROACH_TABLE','planner proceeds after completion callback')
    eq(c.bridge:release(),true);eq(c.raven.get_status().managed_by,nil,'management lease released')
end
do
    local c=bridge_session();c.bridge:release();c.planner.tick();eq(c.planner.get_current_state(),'APPROACH_TABLE')
    c.bridge:observe(12,true);c.bridge:observe(13.1,true);c.now=13.1
    eq(c.bridge:blocks_plan_creator(),false,'reservation cannot invalidate active planner transaction')
    c.bridge:tick(c.now,true);eq(c.raven.get_status().pending,false,'active planner blocks new Whisper queue')
    c.planner.tick();eq(c.planner.get_current_state(),'APPROACH_TABLE','mutual guards do not halt active planner')
end
for _, competing in ipairs({false,true}) do
    local c=bridge_session();c.bridge:tick(c.now,true)
    c.tracker.external_trigger=false;c.tracker.running=true;c.tracker.movement_owned=true;c.looting=competing
    eq(c.bridge:release(),true);eq(c.clears,competing and 0 or 1,'master stop clears only uncontested Raven path')
    eq(c.raven.get_status().owner,nil);eq(c.raven.get_status().managed_by,nil)
end

-- Optional original-source contract probes. These references are deliberately not
-- substituted with the proprietary current packs. Set QQT_REFERENCE_ROOT when available.
local refs=os.getenv('QQT_REFERENCE_ROOT') or '/workspace/scratch/896e1c8c15f3/qqt_extracted/diablo_qqt/scripts'
local file=io.open(refs..'/AlfredTheButler-main/core/external.lua','r')
if file then
    file:close()
    local t={restock_items={}};local settings={enabled=true,plugin_version='1.0.0'}
    local e=setmetatable({require=function(name)
        if name=='core.tracker' then return t elseif name=='core.settings' then return settings
        else return {log=function()end}end end}, {__index=_G})
    local api=assert(loadfile(refs..'/AlfredTheButler-main/core/external.lua','t',e))()
    local cb1,cb2=function()end,function()end
    eq(api.trigger_tasks('First',cb1),nil,'legacy trigger returns nil')
    eq(t.external_trigger,true);eq(api.get_status().external_trigger,nil,'legacy queued flag is not exposed')
    api.trigger_tasks('Second',cb2);eq(t.external_trigger_callback,cb2,'legacy API does not enforce caller ownership')
    api.pause('Other');eq(api.get_status().paused,nil,'legacy pause not exposed');api.resume()
    eq(t.external_pause,false,'legacy resume is unowned')
    for _, key in ipairs({'sell_done','stash_done','restock_done','stocktake_done','salvage_done','repair_done','gamble_done'}) do t[key]=true end
    settings.allow_external=true;t.trigger_tasks=true;t.need_trigger=false
    local callback_seen=0
    api.trigger_tasks('CompletionOrder',function()
        callback_seen=callback_seen+1
        eq(t.external_trigger,false,'queue cleared before callback')
        eq(t.external_caller,nil,'caller cleared before callback')
        eq(t.trigger_tasks,false,'live work cleared before callback')
        eq(type(t.external_trigger_callback),'function','callback reference clears after invocation')
    end)
    local callbacks_utils={is_in_town=function()return true end,log=function()end,
        reset_all_task=function()t.teleport=false end}
    e.get_local_player=function()return {}end;e.get_time_since_inject=function()return 100 end
    e.require=function(name)
        if name=='core.tracker' then return t elseif name=='core.settings' then return settings else return callbacks_utils end
    end
    local status_task=assert(loadfile(refs..'/AlfredTheButler-main/tasks/status.lua','t',e))()
    status_task.Execute();eq(callback_seen,1);eq(t.external_trigger_callback,nil,'callback reference eventually released')
else print('SKIP: optional original Alfred source contract probe (QQT_REFERENCE_ROOT unavailable)') end
local looter_file=io.open(refs..'/LooteerV2-main/main.lua','r')
if looter_file then
    looter_file:close()
    local flags={enabled=true,looting=false}
    local e=setmetatable({require=function(name)
        if name=='src.settings' then return {get=function()return flags end} end
        return {}
    end,on_update=function()end,on_render_menu=function()end,on_render=function()end}, {__index=_G})
    e._G=e;assert(loadfile(refs..'/LooteerV2-main/main.lua','t',e))()
    eq(e.LooteerPlugin.getSettings('looting'),nil,'actual legacy false is nil')
    eq(e.LooteerPlugin.setSettings('enabled',false),true)
    eq(e.LooteerPlugin.setSettings('enabled',true),false,'legacy setter cannot restore a false value')
    eq(flags.enabled,false,'read-only coordination avoids unrecoverable toggle mutation')
else print('SKIP: optional original LooteerV2 source contract probe (QQT_REFERENCE_ROOT unavailable)') end
print('Second-pass town contracts: '..checks..' checks')
