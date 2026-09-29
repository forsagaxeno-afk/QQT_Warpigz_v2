local plugin_label = 'wonder_city' -- change to your plugin name

local utils = require "core.utils"
local settings = require 'core.settings'
local tracker = require 'core.tracker'
local reward_phase = require 'core.reward_phase'

local status_enum = {
    IDLE = 'idle',
    EXIT = 'exiting undercity',
    WAITING = 'waiting'
}
local task = {
    name = 'exit_undercity', -- change to your choice of task name
    status = status_enum['IDLE'],
    debounce_time = nil
}
-- QQT_Warpigz_v3 WonderCity 2.2.6: Kurast<->Temis ping-pong. Rosie serves
-- Temis only, so a need left over from the run (need_repair, a full talisman
-- bag, stash extras) used to cost 3 casts: exit to Kurast, Rosie's hop to
-- Temis, teleport_kurast back. With such a need pending at run end the exit
-- goes straight to Temis: Rosie serves there without a cast and
-- teleport_kurast brings the player back (2 casts). Rosie only (RosiePlugin
-- + AlfredTheButlerPlugin, enabled, not paused); the same rule as
-- tasks/alfred.lua wants_trigger: need_trigger, and advisory-only needs
-- (no inventory_full/need_repair) are left to WarPigs when it is enabled.
local TEMIS_WAYPOINT = 0x1CE51E
local exit_plan = {trigger = nil, waypoint = nil}
local function rosie_need_pending()
    local a = AlfredTheButlerPlugin
    if type(RosiePlugin) ~= 'table' or type(a) ~= 'table' or type(a.get_status) ~= 'function' then return false end
    local ok, st = pcall(a.get_status)
    if not ok or type(st) ~= 'table' or st.enabled ~= true or st.paused == true then return false end
    if st.need_trigger ~= true then return false end
    if st.inventory_full == true or st.need_repair == true then return true end
    -- QQT_Warpigz_v3 WonderCity 2.2.6 (review): the alfred task's 30 s
    -- post-cycle grace skips an advisory-only need; so does the exit.
    local ok_a, alfred_task = pcall(require, 'tasks.alfred')
    if ok_a and type(alfred_task) == 'table' and type(alfred_task.advisory_grace_active) == 'function'
        and alfred_task.advisory_grace_active()
    then
        return false
    end
    local wp = WarPigsPlugin
    if type(wp) == 'table' and type(wp.status) == 'function' then
        local ok_wp, ws = pcall(wp.status)
        if ok_wp and type(ws) == 'table' and ws.enabled == true then return false end
    end
    return true
end
-- Decided once per exit (keyed on tracker.exit_trigger_time), so the
-- debounced re-cast targets the same waypoint.
local function exit_waypoint()
    if exit_plan.trigger ~= nil and exit_plan.trigger == tracker.exit_trigger_time then
        return exit_plan.waypoint
    end
    local waypoint = settings.town_waypoint
    if waypoint ~= TEMIS_WAYPOINT and rosie_need_pending() then
        waypoint = TEMIS_WAYPOINT
        console.print('[WonderCity] Rosie need pending at run end: teleporting out to Temis (Rosie serves there, then back to town)')
    end
    exit_plan.trigger, exit_plan.waypoint = tracker.exit_trigger_time, waypoint
    return waypoint
end

-- QQT_Warpigz_v3 WonderCity 2.2.7 (W3, sweep S3 F9): the exit cast had no
-- enemy check and no cap: with a pack next to the player the rotation's
-- evade broke the channel and the exit re-cast every 5 s into the fight.
--  * a non-forced exit holds while a live enemy is within ENEMY_RANGE m, at
--    most ENEMY_HOLD s from exit_trigger_time (then it casts anyway);
--  * after MAX_CASTS casts without a world change it backs off BACKOFF s
--    (one log line per back-off), then starts counting again.
-- Every cast counts (a pickup break too), and a back-off never parks the
-- exit for good.
local EXIT = {ENEMY_RANGE = 8, ENEMY_HOLD = 20, MAX_CASTS = 4, BACKOFF = 30}
local casts = {n = 0, backoff_until = nil}
local function enemy_near()
    local player = get_local_player()
    if not player then return false end
    local ok, near = pcall(function()
        local pp = player:get_position()
        for _, enemy in pairs(target_selector.get_near_target_list(pp, EXIT.ENEMY_RANGE) or {}) do
            local hp = enemy:get_current_health()
            if type(hp) == 'number' and hp > 0 and not (enemy.is_dead and enemy:is_dead())
                and utils.distance(pp, enemy) <= EXIT.ENEMY_RANGE then
                return true
            end
        end
        return false
    end)
    return ok and near == true
end

local exit_with_debounce = function (delay)
    if tracker.exit_trigger_time + settings.exit_undercity_delay >= get_time_since_inject() then
        local wait_time = tracker.exit_trigger_time + settings.exit_undercity_delay - get_time_since_inject()
        task.status = status_enum['WAITING'] ..
        ' exit delay ' .. string.format("%.2f", wait_time) .. 's'
    else
        -- Always debounce. teleport_to_waypoint and reset_all_dungeons each
        -- have a multi-second cast/channel that gets CANCELLED if the call
        -- fires again before the previous one completes. Without this guard,
        -- the action fires every 50ms — the channel never finishes, the
        -- player runs around (input returns between cancellations), and the
        -- bot looks like it's stuck in the dungeon. The original `delay`
        -- flag only enabled this check in party mode, leaving non-party
        -- users spamming the teleport. confirm_delay (default 5s) covers
        -- the channel.
        if task.debounce_time ~= nil and
            task.debounce_time + math.max(settings.confirm_delay, 5) > get_time_since_inject()
        then
            task.status = status_enum['WAITING'] .. ' for ' ..
                (settings.exit_mode == 1 and 'teleport' or 'reset') .. ' to complete'
            return
        end
        -- QQT_Warpigz_v3 WonderCity 2.2.7 (W3): cast cap + back-off.
        local now = get_time_since_inject()
        if casts.backoff_until ~= nil then
            if now < casts.backoff_until then
                task.status = string.format('%s exit re-cast back-off %.0fs', status_enum['WAITING'], casts.backoff_until - now)
                return
            end
            casts.n, casts.backoff_until = 0, nil
        end
        if casts.n >= EXIT.MAX_CASTS then
            casts.backoff_until = now + EXIT.BACKOFF
            console.print(string.format('[WonderCity] exit cast %d times without leaving the Undercity - backing off %ds',
                casts.n, EXIT.BACKOFF))
            task.status = status_enum['WAITING'] .. ' exit re-cast back-off'
            return
        end
        -- QQT_Warpigz_v3 WonderCity 2.2.7 (W3): no cast into a fight (bounded).
        if not utils.exit_forced() and now - tracker.exit_trigger_time < EXIT.ENEMY_HOLD and enemy_near() then
            task.status = status_enum['WAITING'] .. ' for nearby enemies to die'
            return
        end
        casts.n = casts.n + 1
        task.debounce_time = get_time_since_inject()
        tracker.exit_cast_time = task.debounce_time -- QQT_Warpigz_v3 WonderCity 2.2.7 (W1): the leave is final
        task.status = status_enum['EXIT']
        if settings.exit_mode == 1 then
            console.print('teleport out')
            teleport_to_waypoint(exit_waypoint()) -- QQT_Warpigz_v3 WonderCity 2.2.6: Temis when a Rosie need is pending
        else
            console.print('reset dungeon')
            reset_all_dungeons()
        end
    end
end

task.shouldExecute = function ()
    return utils.player_in_undercity() and
        (utils.exit_forced() or reward_phase.can_exit())
end

task.Execute = function ()
    local local_player = get_local_player()
    if not local_player then return end
    -- Stop any in-flight long_path navigation BEFORE pausing. Batmobile's
    -- main_pulse re-runs navigator.unpause() + update() + move() every frame
    -- while long_path.navigating is true, which overrides our pause and
    -- keeps the player walking — that movement cancels the teleport channel.
    if BatmobilePlugin.is_long_path_navigating
        and BatmobilePlugin.is_long_path_navigating()
    then
        BatmobilePlugin.stop_long_path(plugin_label)
    end
    BatmobilePlugin.clear_target(plugin_label)
    BatmobilePlugin.pause(plugin_label)
    if tracker.exit_trigger_time == nil then
        tracker.exit_trigger_time = get_time_since_inject()
    end
    if not settings.party_enabled or utils.exit_forced() then
        exit_with_debounce(false)
    elseif settings.party_mode == 0 then
        exit_with_debounce(true)
    else
        if tracker.exit_trigger_time == get_time_since_inject() and
            settings.use_magoogle_tool and settings.party_enabled and
            settings.party_mode == 1
        then
            -- contact magoogle tool accepting exit
        end
        task.status = status_enum['WAITING'] .. ' for d4 assistant'
    end
end

task.reset = function ()
    task.debounce_time = nil; exit_plan.trigger, exit_plan.waypoint = nil, nil
    casts.n, casts.backoff_until = 0, nil -- QQT_Warpigz_v3 WonderCity 2.2.7 (W3): a world change
end

return task
