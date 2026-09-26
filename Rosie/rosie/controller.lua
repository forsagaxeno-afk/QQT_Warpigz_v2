local Runtime=require('rosie.runtime')
local Movement=require('rosie.movement')
local M={}
-- QQT_Warpigz_v2 local patch (M4): another mover is driving the player right
-- now (a Batmobile route or claimed goal that is not paused). Pickup then
-- yields its claim without clearing the native path that mover just set.
local function peer_drives_movement()
    local bat=rawget(_G,'BatmobilePlugin')
    if type(bat)~='table' or type(bat.is_paused)~='function' or type(bat.get_owner)~='function' then return false end
    local ok,paused=pcall(bat.is_paused)
    if not ok or paused~=false then return false end
    local ok2,owner=pcall(bat.get_owner)
    return ok2 and owner~=nil
end
local function peer_owns_loot()
    local peer=rawget(_G,'TRISTRAM_LOOP_STATE')
    if type(peer)~='table' or type(peer.status)~='function' then return false end
    local ok,s=pcall(peer.status)
    return ok and type(s)=='table' and s.running==true and s.owns_activity==true and s.controls_loot==true
end
function M.new(cached,conflict)
    local app={active=true,conflict=conflict,next_update=0,error=nil}
    app.elements=cached or {
        enabled=checkbox:new(false,get_hash('Rosie_enabled')),
        pace=combo_box:new(0,get_hash('Rosie_movement_pace')),
        overlay=checkbox:new(true,get_hash('Rosie_overlay')),
        service=button:new(get_hash('Rosie_service')),
        stop=button:new(get_hash('Rosie_stop')),
        diagnose=button:new(get_hash('Rosie_diagnose')),
        queue_id=input_text:new(get_hash('Rosie_queue_id')),
        queue_action=combo_box:new(0,get_hash('Rosie_queue_action')),
        queue_add=button:new(get_hash('Rosie_queue_add')),
        queue_clear=button:new(get_hash('Rosie_queue_clear')),
    }
    app.elements.root=tree_node:new(0)
    app.elements.storage=tree_node:new(1)
    app.elements.movement=tree_node:new(1)
    app.elements.display=tree_node:new(1)
    local town,loot,life,tracker,town_gui,loot_gui,settings,pickup
    local installation_valid
    local function enabled() return app.active and not conflict and app.elements.enabled:get()==true end
    if not conflict then
        require('rosie.private.pickup.main')
        require('rosie.private.town.main')
        town,loot=AlfredTheButlerPlugin,LooteerPlugin
        life=require('rosie.private.town.core.lifecycle')
        tracker=require('rosie.private.town.core.tracker')
        town_gui=require('rosie.private.town.gui')
        loot_gui=require('rosie.private.pickup.gui')
        settings=require('rosie.private.town.core.settings')
        pickup=require('rosie.private.pickup.src.pickup')
        -- QQT resolves require() in the calling plugin's folder: modules used by
        -- functions other addons can reach (status, disable, stop) are bound
        -- here, at load, instead of being required lazily.
        app.pickup_settings=require('rosie.private.pickup.src.settings')
        app.task_manager=require('rosie.private.town.core.task_manager')
        -- The private pickup worker also tracks successful native requests. A
        -- refused first request can still leave the shared route owner claimed.
        local release_pickup=pickup.release_movement
        pickup.release_movement=function(clear)
            if clear~=false and Movement.status().owner=='pickup' and peer_drives_movement() then clear=false end
            local result=release_pickup(clear)
            if clear==false then Movement.yield('pickup')
            elseif not Movement.status().cleanup_pending then Movement.release('pickup') end
            return result
        end
        town._rosie=true;loot._rosie=true
        app.town,app.loot,app.life,app.tracker=town,loot,life,tracker
        app.town_gui,app.loot_gui=town_gui,loot_gui
        local request=life.request
        life.request=function(...)
            if not app.active then return false,'This Rosie instance has reloaded.' end
            if installation_valid and not installation_valid() then return false,app.conflict end
            if not enabled() then return false,'Rosie is off.' end
            if Movement.status().cleanup_pending or not Movement.release('pickup') then
                return false,'Waiting for pickup movement to release.'
            end
            return request(...)
        end
        -- Compatibility consumers see the master gate, including immediate requests.
        local town_status=town.get_status
        town.get_status=function()
            local s=town_status();s.name='Rosie';s.version='1.0.3';s.enabled=s.enabled and enabled()
            s.allow_external=s.allow_external and enabled();return s
        end
        for _,key in ipairs({'trigger_tasks','trigger_tasks_with_teleport'}) do
            local original=town[key]
            town[key]=function(...)
                if not app.active then return false,'This Rosie instance has reloaded.' end
                if installation_valid and not installation_valid() then return false,app.conflict end
                if not enabled() then return false,'Rosie is off.' end
                if Movement.status().cleanup_pending or not Movement.release('pickup') then return false,'Waiting for pickup movement to release.' end
                return original(...)
            end
        end
        local loot_status,get_setting=loot.status,loot.getSettings
        loot.status=function()
            local s=loot_status()
            if not enabled() then s.enabled=false;s.ready=false;s.running=false;s.reason='disabled';s.detail='Rosie is off.' end
            return s
        end
        loot.getSettings=function(key)
            if not enabled() and (key=='enabled' or key=='looting') then return nil end
            return get_setting(key)
        end
        local loot_enabled=loot.get_enabled
        loot.get_enabled=function() return enabled() and loot_enabled() end
    end
    Movement.configure(function(owner)
        if not enabled() or not life or life.cleanup_pending()>0 then return false end
        if owner=='town' then return life.busy() and not tracker.external_pause end
        return owner=='pickup' and not life.busy() and not peer_owns_loot()
    end,function() return app.elements.pace:get()==1 and 0.12 or 0.20 end)
    -- A user stop / disable is a cancel (never latches the stuck state); a
    -- host error is a failure.
    local function cancel(reason,failure)
        if life and life.busy() then
            if failure then life.finish(false,reason) else life.cancel(reason or 'Stopped by user') end
        end
        if pickup then pickup.reset(not peer_owns_loot()) end
        if loot then app.pickup_settings.get().looting=false end
        if peer_owns_loot() then Movement.yield('pickup') else Movement.release('pickup') end
        Movement.release('town')
    end
    installation_valid=function()
        if conflict then return false end
        if rawget(_G,'LooteerPlugin')~=loot or rawget(_G,'AlfredTheButlerPlugin')~=town or rawget(_G,'PLUGIN_alfred_the_butler')~=town then
            conflict='Another pickup or town addon loaded. Unload it, then reload Rosie.'
            app.conflict=conflict;app.elements.enabled:set(false)
            Movement.yield('pickup');Movement.yield('town')
            town.shutdown();loot.shutdown()
            return false
        end
        return true
    end
    app.last_enabled=enabled()
    function app.refresh_preview()
        -- Configuration must be inspectable before either worker is enabled.
        -- This only reads widgets/items and updates the census; it never admits
        -- a request or dispatches a worker callback.
        local ok,why=pcall(function()
            settings:update_settings()
            local player,world=get_local_player(),get_current_world()
            if not player or player:is_dead()~=false then error('waiting for a living player') end
            local zone=world and world:get_current_zone_name()
            if not zone or zone=='[sno none]' then error('waiting for the world to load') end
            require('rosie.private.town.core.utils').update_tracker_count(player,true)
        end)
        -- QQT_Warpigz_v2: a one-frame failure (the host briefly reporting no
        -- living player or zone) used to swap the two count lines for one
        -- error line and back, so the whole menu jumped up and down. The
        -- error line now appears only after PREVIEW_GRACE s of continuous
        -- failure; until then the last counts stay on screen.
        local now=get_time_since_inject()
        if ok then
            app.preview_error=nil;app.preview_failure=nil;app.preview_fail_since=nil
        else
            local detail=tostring(why)
            app.preview_fail_since=app.preview_fail_since or now
            if now-app.preview_fail_since>=2 then
                if app.preview_failure~=detail then console.print('[Rosie] Item preview failed: '..detail) end
                app.preview_failure=detail
                app.preview_error='Item preview unavailable: wait for a living character and loaded bags, then reopen this menu.'
            end
        end
        return ok
    end
    function app.status()
        if conflict then return {enabled=false,phase='setup',detail=conflict} end
        local ts,ls=town.get_status(),loot.status()
        local phase,detail='ready','Ready. Watching drops, bags and repairs.'
        if Movement.status().cleanup_pending then phase,detail='cleanup','Waiting for owned movement to release.'
        elseif life.cleanup_pending()>0 then phase,detail='cleanup',ts.state_text
        elseif not enabled() then phase,detail='off','Off. Configure pickup and town service below.'
        elseif ts.running then phase,detail='service',ts.state_text..' | '..tostring(app.task_manager.get_current_task().status)
        elseif ts.failure_reason then phase,detail='stopped',ts.state_text
        elseif ls.running then phase,detail='pickup',ls.detail
        elseif ls.reason~='ready' then phase,detail=ls.reason,ls.detail end
        if enabled() and not ts.running and not ts.failure_reason and not Movement.status().cleanup_pending and life.cleanup_pending()==0 then
            if not ts.enabled then detail=ls.detail..' Town service is off.'
            elseif not settings.get_keybind_state() then detail=ls.detail..' Automatic town service is paused by its keybind; Run town service still works.' end
        end
        return {enabled=enabled(),phase=phase,detail=app.error or detail,
            town=ts,pickup=ls,movement=Movement.status()}
    end
    function app.service()
        if not app.active then return false,'This Rosie instance has reloaded.' end
        if not installation_valid() then return false,app.conflict end
        if not enabled() then app.notice='Enable Rosie before starting service.';return false end
        if Movement.status().cleanup_pending or not Movement.release('pickup') then app.notice='Waiting for pickup movement to release.';return false end
        settings:update_settings()
        local ok,why=life.request('Rosie',nil,true,true)
        app.notice=not ok and 'Cannot start: '..tostring(why) or nil
        return ok,why
    end
    function app.add_pull()
        if not town or life.busy() then return false end
        local text=app.elements.queue_id:get()
        local id=type(text)=='string' and text:match('^%s*(%d+)%s*$') and tonumber(text) or nil
        local item=id and require('rosie.data.items').by_id[id]
        if not item or not item.name or not ({equipment=true,charm=true,seal=true})[item.kind] then
            app.notice='Enter a named equipment, charm or seal Item ID from the local catalog.';return false
        end
        local choice=app.elements.queue_action:get()
        if choice~=0 and choice~=1 then app.notice='Choose Salvage or Sell before adding to the queue.';return false end
        local action=choice==1 and 'sell' or 'salvage'
        local ok=town.queue_stash_pull(id,action)
        app.notice=ok and 'Queued '..item.name..' for '..action..'. Run town service when ready.' or 'That item is already queued or service is busy.'
        return ok
    end
    function app.update()
        if not app.active then
            if app.cleanup_transferred then return end
            if not installation_valid() then Movement.yield('pickup');Movement.yield('town') end
            if peer_owns_loot() then Movement.yield('pickup') end
            Movement.retry_cleanup()
            if life then life.retry_cleanup() end
            return
        end
        if not installation_valid() then return end
        if peer_owns_loot() then Movement.yield('pickup') end
        if not Movement.status().cleanup_pending then Movement.suspend_if_unavailable() end
        if not Movement.retry_cleanup() or not life.retry_cleanup() then
            life.suspend()
            require('rosie.private.town.core.task_manager').suspend()
            return
        end
        if not enabled() then cancel('Rosie disabled during service');return end
        local now=get_time_since_inject()
        if now<app.next_update then return end
        app.next_update=now+0.05
        local ok,why=pcall(Runtime.run,'town','update')
        if not ok then
            local message='Host error: '..tostring(why)
            if app.error~=message then console.print('[Rosie] '..message) end
            app.error=message;app.elements.enabled:set(false);app.last_enabled=false;cancel(message,true)
            return
        end
        -- QQT_Warpigz_v2 (M2): a pickup error releases pickup for this frame
        -- only; it never switches Rosie (and the town adapter) off.
        local pok,pwhy=pcall(Runtime.run,'pickup','update')
        if not pok then
            local message='Pickup error: '..tostring(pwhy)
            if app.pickup_error~=message then console.print('[Rosie] '..message) end
            app.pickup_error=message
            pcall(pickup.reset,not peer_owns_loot())
            app.pickup_settings.get().looting=false
            if peer_owns_loot() then Movement.yield('pickup') else Movement.release('pickup') end
        else
            app.pickup_error=nil
        end
    end
    -- QQT_Warpigz_v2 (M3): the overlay redraws every render frame; its status
    -- is recomputed at most every 0.25 s.
    local overlay_cache,overlay_at=nil,-math.huge
    function app.overlay_status()
        local now=get_time_since_inject()
        if not overlay_cache or now-overlay_at>=0.25 or now<overlay_at then overlay_cache=app.status();overlay_at=now end
        return overlay_cache
    end
    local gui=require('rosie.gui')
    function app.menu()
        if not app.active then return end
        installation_valid()
        local displayed=gui.render(app)
        if conflict then return end
        -- A successfully rendered cancellation remains valid if a later child
        -- fails to display. All other actions require the complete menu.
        if app.actions.stop and app.elements.stop:get() then app.elements.enabled:set(false);app.last_enabled=false;cancel('Cancelled by user');app.notice=nil;return end
        if not displayed then return end
        local current_enabled=enabled()
        if current_enabled and not app.last_enabled then app.error=nil;app.notice=nil;life.clear_cancel() end
        app.last_enabled=current_enabled
        settings:update_settings();require('rosie.private.pickup.src.settings').update()
        if not settings.enabled and life.busy() then life.cancel('Town service disabled') end
        if not loot_gui.elements.main_toggle:get() then pickup.reset(not peer_owns_loot()) end
        if not enabled() then cancel('Rosie disabled during service') end
        if app.actions.service and app.elements.service:get() then app.service() end
        if app.actions.diagnose and app.elements.diagnose:get() then
            require('rosie.private.pickup.src.item_manager').diagnose()
            require('rosie.private.town.core.utils').dump_tracker_info(tracker)
        end
        if app.actions.queue_add and app.elements.queue_add:get() then app.add_pull() end
        if app.actions.queue_clear and app.elements.queue_clear:get() then
            if not life.busy() then town.clear_pending_pulls();app.notice='Pending stash pulls cleared.' end
        end
    end
    function app.render()
        if not app.active or conflict or not enabled() then return end
        if app.elements.overlay:get() then gui.overlay(app) end
        -- The single Rosie overlay owns status; retain opt-in bag/item highlights.
        local draw=require('rosie.private.town.core.drawing')
        if town_gui.elements.draw_stash:get() or town_gui.elements.draw_sell:get() or town_gui.elements.draw_salvage:get() then draw.draw_inventory_boxes() end
        require('rosie.private.pickup.src.renderer').draw_stuff()
    end
    app.api={_elements=app.elements,_rosie=true,status=app.status,
        _take_movement_cleanup=function() app.cleanup_transferred=true;return Movement.take_cleanup() end,
        _yield_movement=function() Movement.yield('pickup');Movement.yield('town') end,
        _owns_installation=function()
            return not conflict and rawget(_G,'LooteerPlugin')==loot and rawget(_G,'AlfredTheButlerPlugin')==town
                and rawget(_G,'PLUGIN_alfred_the_butler')==town
        end,
        _pending_pulls=function() return town and town.get_pending_pulls() or {} end,
        enable=function() if not app.active or conflict then return false end;if not installation_valid() then return false end;app.error=nil;app.notice=nil;app.elements.enabled:set(true);if life then life.clear_cancel() end;return true end,
        disable=function() if not app.active then return false end;installation_valid();app.elements.enabled:set(false);app.last_enabled=false;cancel('Rosie disabled during service');return true end,
        service=app.service,
        stop=function() if not app.active then return false end;installation_valid();app.elements.enabled:set(false);app.last_enabled=false;cancel('Cancelled by user');return true end,
        shutdown=function()
            if not app.active then return true end
            installation_valid()
            app.active=false
            if town then town.shutdown() end
            if loot then loot.shutdown() end
            Movement.release('pickup');Movement.release('town')
            return true
        end,
    }
    return app
end
return M
