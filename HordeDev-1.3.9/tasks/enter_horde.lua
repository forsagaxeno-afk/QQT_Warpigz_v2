local utils = require "core.utils"
local tracker = require "core.tracker"
local start_task = require "tasks.start_dungeon"
local task = {name="Enter Horde"}
local ENTRY_TIMEOUT, INTERACT_GAP, MAX_INTERACTIONS = 45, 5, 5

function task:reset()
    self.entry_phase,self.entry_error=nil,nil
    self.started,self.quiet_until,self.next_interact=nil,nil,nil
    self.inside_since,self.inside_world=nil,nil
    self.interactions,self.move_issued=0,false
    tracker.horde_entry_pending=false
end

function task:fail(message)
    self.entry_phase,self.entry_error="FAULT",message
    tracker.horde_entry_pending=true
    console.print("[enter_horde] "..message)
end

task.shouldExecute = function()
    if tracker.horde_entry_pending then return true end
    if tracker.sigil_activation_pending or tracker.has_entered then return false end
    local s=start_task.read_world()
    return s~=nil and s.outside and tracker.horde_opened==true
end

function task:Execute()
    local now=get_time_since_inject()
    if self.token~=start_task.entry_started or not self.started then
        self:reset()
        self.token=start_task.entry_started
        self.started=start_task.entry_started or now
        self.quiet_until,self.next_interact=now,now
        tracker.horde_entry_pending=true
        self.entry_phase="FIND_PORTAL"
    end
    if self.entry_error then return end
    if now-self.started>=ENTRY_TIMEOUT then self:fail("Entry timed out. Horde arrival was not confirmed.");return end
    if now<self.quiet_until then return end
    local s=start_task.read_world()
    if not s then self.inside_since,self.inside_world=nil,nil;return end
    if s.inside then
        if self.inside_world~=s.id then self.inside_since,self.inside_world=now,s.id end
        self.entry_phase="WAIT_HORDE_STABLE"
        if now-self.inside_since<1 then return end
        tracker.has_entered,tracker.horde_opened=true,true
        tracker.horde_entry_pending=false
        self.entry_phase="IN_HORDE"
        start_task:release_movement()
        console.print("[enter_horde] Horde arrival confirmed; entry finished.")
        return
    end
    self.inside_since,self.inside_world=nil,nil
    if not s.outside then return end
    local found,portal=pcall(utils.get_horde_portal)
    if not found then self:fail("Portal observation failed: "..tostring(portal));return end
    if not portal then
        if self.entry_phase~="WAIT_PORTAL" then console.print("[enter_horde] Waiting for the confirmed portal to become visible.") end
        self.entry_phase="WAIT_PORTAL"
        return
    end
    if utils.distance_to(portal)>=2 then
        self.entry_phase="APPROACH_PORTAL"
        pathfinder.request_move(portal:get_position())
        self.move_issued=true
        return
    end
    if self.move_issued then
        local stopped,why=pcall(start_task.stop_movement,s.player)
        if not stopped then self:fail("Cannot stop at the portal: "..tostring(why));return end
        self.move_issued=false
        self.next_interact=now+0.5
        return
    end
    if now<self.next_interact then return end
    if self.interactions>=MAX_INTERACTIONS then self:fail("Portal entry failed after five interactions.");return end
    self.interactions=self.interactions+1
    self.next_interact,self.quiet_until=now+INTERACT_GAP,now+INTERACT_GAP
    self.entry_phase="WAIT_ENTRY"
    local called,result=pcall(interact_object,portal)
    console.print(string.format("[enter_horde] Portal interaction %d/%d; result=%s",self.interactions,MAX_INTERACTIONS,tostring(result)))
    if not called then self:fail("Portal interaction failed: "..tostring(result)) end
    -- Do not inspect actors or reset chest flags after this native call.
end

return task
