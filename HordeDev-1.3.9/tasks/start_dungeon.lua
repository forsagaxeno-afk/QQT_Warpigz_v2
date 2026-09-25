local utils = require "core.utils"
local settings = require "core.settings"
local tracker = require "core.tracker"
local open_chests_task = require "tasks.open_chests"
local explorer = require "core.explorer"
local task = {name="Start Dungeon"}
local DIALOG_DELAY, CONFIRM_INTERVAL, ACTOR_QUIET = 3, 5, 3
local MAX_CONFIRMS, ACTIVATION_TIMEOUT = 5, 60

-- Missing/loading snapshots cannot prove either activation or entry.
function task.read_world()
    local ok, result = pcall(function()
        local player, w = get_local_player(), get_current_world()
        if not player or player:is_dead() ~= false or not w then return nil end
        local name, zone, id = w:get_name(), w:get_current_zone_name(), w:get_world_id()
        if type(name)~="string" or name=="" or type(zone)~="string" or zone=="" or id==nil then return nil end
        local lower=name:lower()
        if lower:find("loading",1,true) or lower:find("limbo",1,true) then return nil end
        local bsk=lower:find("bsk",1,true)~=nil
        return {player=player,id=id,zone=zone,
            outside=zone=="Kehj_Caldeum" and not bsk,
            inside=zone=="S05_BSK_Prototype02" and bsk}
    end)
    return ok and result or nil
end

function task.stop_movement(player)
    if BatmobilePlugin then
        if BatmobilePlugin.is_long_path_navigating and BatmobilePlugin.is_long_path_navigating() then
            assert(BatmobilePlugin.stop_long_path("infernal_horde")~=false,"Cannot stop Batmobile long path.")
        end
        assert(BatmobilePlugin.pause("infernal_horde")~=false,"Cannot pause Batmobile.")
        assert(BatmobilePlugin.clear_target("infernal_horde")~=false,"Cannot clear Batmobile target.")
    end
    assert(pathfinder.clear_stored_path()~=false,"Cannot clear the old movement path.")
    assert(pathfinder.request_move(player:get_position())~=false,"Cannot stop movement.")
end

function task:release_movement()
    if self.explorer_before_start~=nil then explorer.is_task_running=self.explorer_before_start end
    self.explorer_before_start=nil
end

function task:reset()
    self:release_movement()
    self.activation_phase, self.activation_error = nil, nil
    self.started, self.source_world, self.next_confirm, self.quiet_until = nil, nil, nil, nil
    self.confirms, self.evidence_since, self.evidence_key = 0, nil, nil
    self.entry_started, self.use_retry_at = nil, nil
    tracker.sigil_activation_pending, tracker.horde_entry_pending = false, false
end

function task:fail(message)
    self.activation_phase, self.activation_error = "FAULT", message
    console.print("[start_dungeon] "..message)
    -- Keep ownership until explicitly restarted; do not use another compass.
end

function task:begin_activation(now, s, item)
    self:reset()
    self.started, self.source_world, self.confirms = now, s.id, 0
    self.next_confirm, self.quiet_until = now+DIALOG_DELAY, now+DIALOG_DELAY
    self.activation_phase = "WAIT_SIGIL_DIALOG"
    tracker.sigil_activation_pending = true
    tracker.horde_opened, tracker.has_entered = false, false
    self.explorer_before_start=explorer.is_task_running
    explorer.is_task_running=true
    local stopped, why=pcall(self.stop_movement,s.player)
    if not stopped then self:fail("Cannot stop movement before activating: "..tostring(why));return end
    -- Set guards before the native call; use_item can open a UI/transition.
    local called, result=pcall(use_item,item)
    if not called or result==false then
        self:fail("Sigil use failed: "..tostring(result));return
    end
    tracker.sigil_used, tracker.first_run = true, true
    tracker.teleported_from_town = false
    open_chests_task:reset() -- once for the new run, never on each entry pulse
    tracker.finished_looting_start_time = nil
    console.print("[start_dungeon] Sigil requested. Waiting for the confirmation dialog.")
end

function task:activation_update(now)
    if self.activation_error then return end
    if now-self.started>=ACTIVATION_TIMEOUT then
        self:fail("Activation timed out: no portal or Horde arrival was confirmed.");return
    end
    -- No actor enumeration, clicks or movement during UI/zone transition settling.
    if now<self.quiet_until then return end
    local s=self.read_world()
    if not s then self.evidence_since,self.evidence_key=nil,nil;return end
    if s.inside then
        local key="inside:"..tostring(s.id)
        if self.evidence_key~=key then self.evidence_key,self.evidence_since=key,now end
        if now-self.evidence_since<1 then return end
        tracker.sigil_activation_pending=false
        tracker.horde_opened,tracker.has_entered=true,true
        self.activation_phase="IN_HORDE"
        self:release_movement()
        console.print("[start_dungeon] Horde arrival confirmed.")
        return
    end
    if not s.outside or s.id~=self.source_world then
        self.evidence_since,self.evidence_key=nil,nil;return
    end
    -- A void/true confirmation return is not proof of an accepted dialog.
    -- Require a visible portal (or actual arrival above) before handing off.
    if self.confirms>0 then
        local found,portal=pcall(utils.get_horde_portal)
        if not found then self:fail("Portal observation failed: "..tostring(portal));return end
        if portal then
            local key="portal:"..tostring(s.id)
            if self.evidence_key~=key then self.evidence_key,self.evidence_since=key,now end
            self.activation_phase="WAIT_PORTAL_STABLE"
            if now-self.evidence_since<1 then return end
            tracker.horde_opened=true
            tracker.sigil_activation_pending=false
            tracker.horde_entry_pending=true
            self.entry_started=now
            self.activation_phase="PORTAL_CONFIRMED"
            console.print("[start_dungeon] Portal confirmed. Entering Horde.")
            return
        end
    end
    self.evidence_since,self.evidence_key=nil,nil
    if self.confirms>=MAX_CONFIRMS then
        if now>=self.next_confirm+5 then self:fail("Confirmation did not produce a portal after five attempts. Check the Consume Sigil dialog.") end
        return
    end
    if now<self.next_confirm then return end
    if not utility or type(utility.confirm_sigil_notification)~="function" then
        self:fail("QQT confirm_sigil_notification API is unavailable.");return
    end
    self.confirms=self.confirms+1
    self.next_confirm,self.quiet_until=now+CONFIRM_INTERVAL,now+ACTOR_QUIET
    self.activation_phase="WAIT_ACTIVATION"
    local called,result=pcall(utility.confirm_sigil_notification)
    console.print(string.format("[start_dungeon] Sigil confirmation attempt %d/%d; result=%s",self.confirms,MAX_CONFIRMS,tostring(result)))
    if not called then self:fail("Sigil confirmation API failed: "..tostring(result)) end
end

local function use_dungeon_sigil(task, now, snapshot)
    if tracker.sigil_used then
        console.print("Horde already opened this session. Skipping.")
        return false
    end

    local local_player = get_local_player()
    local inventory = local_player:get_dungeon_key_items()
    
    -- List of valid sigil names
    local valid_sigils = {}

    if settings.use_6_wave then
        table.insert(valid_sigils, "S05_DungeonSigil_BSK_Wave6")
    end

    if settings.use_8_wave then
        table.insert(valid_sigils, "S05_DungeonSigil_BSK_Wave8")
    end

    if settings.use_10_wave then
        table.insert(valid_sigils, "S05_DungeonSigil_BSK_Wave10")
    end

    if settings.use_bloodied then
        table.insert(valid_sigils, "S12_DungeonSigil_BSK_SpecialButcher")
    end
    
    for _, item in pairs(inventory) do
        local item_info = utils.get_consumable_info(item)
        if item_info then
            for _, sigil_name in ipairs(valid_sigils) do
                if item_info.name == sigil_name then
                    task:begin_activation(now, snapshot, item)
                    return true
                end
            end
        end
    end

    console.print("Dungeon Sigil not found in inventory.")
    -- inventory will also report as full when need restock and 
    -- if stash have more compasses and if alfred is configured to restock
    if settings.use_alfred and AlfredTheButlerPlugin then
        -- C1: an unreadable status is bounded by utils.read_alfred_status().
        local status = utils.read_alfred_status()
        if not status then return false end
        if status.enabled and type(status.need_trigger) ~= 'boolean' then return false end
        -- add additional conditions to trigger if required
        -- C1: advisory need_trigger alone cannot re-trigger within the sticky
        -- grace after HordeDev's own completed Alfred cycle.
        -- F-H4 (as Arkham's warpigs_advisory_idle): under WarPigs, an
        -- advisory-only flag (restock, no inventory_full/need_repair) that
        -- WarPigs reports serviced (alfred_idle) starts no trip here; the
        -- via-Temis preamble covers restocking. Hard needs are unchanged.
        if utils.alfred_trip_wanted(status, tracker.alfred_completed_at) then
            if utils.alfred_hard_need(status) or not task.warpigs_advisory_idle() then
                tracker.start_dungeon_time = nil
                tracker.needs_salvage = true
                return false
            end
            if not task.advisory_skip_logged then
                task.advisory_skip_logged = true
                console.print("[start_dungeon] Advisory Alfred restock skipped:"
                    .. " WarPigs reports it serviced for this visit.")
            end
        end
    end
    
    -- Stop script and run pit
    if settings.run_pit then
        task:start_pit()
    end
    
    return false
end

-- HRD-9: no plugin exports PitPlugin; ArkhamAsylum exports ArkhamAsylumPlugin.
-- While WarPigs is on it owns activity handoffs, so HordeDev must not start
-- a Pit behind its back.
local function warpigs_on()
    local wp = WarPigsPlugin
    if type(wp) ~= 'table' or type(wp.status) ~= 'function' then return false end
    local ok, st = pcall(wp.status)
    return ok and type(st) == 'table' and st.enabled == true
end

-- F-H4: the same reading as ArkhamAsylum's warpigs_advisory_idle().
function task.warpigs_advisory_idle()
    local wp = WarPigsPlugin
    if type(wp) ~= 'table' or type(wp.status) ~= 'function' then return false end
    local ok, st = pcall(wp.status)
    return ok and type(st) == 'table' and st.enabled == true and st.alfred_idle == true
end

function task:start_pit()
    if warpigs_on() then
        if not self.pit_skip_logged then
            self.pit_skip_logged = true
            console.print("[start_dungeon] Out of compasses; 'Run pit' skipped because WarPigs manages activity handoffs.")
        end
        return false
    end
    local pit = PitPlugin or ArkhamAsylumPlugin
    if type(pit) ~= 'table' or type(pit.enable) ~= 'function' then
        console.print("Pit version does not support auto start")
        return false
    end
    console.print("[start_dungeon] Out of compasses; starting the Pit plugin.")
    InfernalHordesPlugin.disable()
    local ok, why = pcall(pit.enable)
    if not ok then console.print("[start_dungeon] Pit plugin failed to start: " .. tostring(why)) end
    return ok
end

task.shouldExecute = function()
    -- F-H1: War Plan entry never uses a compass (no use_item, no activation,
    -- no sigil confirmation).
    if tracker.entry_mode == 'warplan' then return false end
    if tracker.sigil_activation_pending then return true end
    if tracker.horde_entry_pending then return false end
    local s=task.read_world()
    return s~=nil and s.outside and not tracker.horde_opened
end

function task:Execute()
    if tracker.entry_mode == 'warplan' then return end -- F-H1 (forced paths too)
    local now=get_time_since_inject()
    if tracker.sigil_activation_pending then self:activation_update(now);return end
    local s=self.read_world()
    if not s or not s.outside then return end
    if not tracker.start_dungeon_time then
        tracker.start_dungeon_time=now
        console.print("[start_dungeon] Waiting five seconds before selecting a compass.")
    end
    if now-tracker.start_dungeon_time<5 then return end
    if self.use_retry_at and now<self.use_retry_at then return end
    if tracker.sigil_used then
        -- Never blindly reuse a compass after an interrupted/unknown activation.
        tracker.sigil_activation_pending=true
        self.started,self.quiet_until=now,now
        self:fail("Sigil state is incomplete. Restart HordeDev before activating another compass.")
        return
    end
    self.use_retry_at=now+5
    use_dungeon_sigil(self,now,s)
end

return task
