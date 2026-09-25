-- ============================================================
--  Reaper  v1.10.0
--  by Magoogle
--
--  Flow per run:
--    1. Teleport directly to boss dungeon
--    2. Navigate to altar and interact to summon the boss
--    3. Kill the boss (your combat script handles casting)
--    4. Open the boss chest
--    5. Decrement key/husk pool by 1 run
--    6. Cycle to the next selected boss
--    7. When no selected boss has resources, disable
-- ============================================================

local gui          = require "gui"
local task_manager = require "core.task_manager"
local settings     = require "core.settings"
local rotation     = require "core.boss_rotation"
local tracker      = require "core.tracker"
local enums        = require "data.enums"
local materials    = require "core.materials"
local utils        = require "core.utils"
local belial_chest = require "tasks.belial_chest"
local revive       = require "tasks.revive"
local alfred_task  = require "tasks.alfred"
local dungeon_reset = require "tasks.dungeon_reset"

-- Home town now resolved per pulse from settings.town_zone / settings.town_waypoint
-- (driven by the gui.town combo_box). Defaults to Temis to match Arkham/Alfred.

-- -------------------------------------------------------
-- Enable guard — only fires once per toggle-on
-- -------------------------------------------------------
local enabled_last_frame = false
local enable_time        = 0   -- time when toggle was first turned on
local startup_done       = false
local finishing          = false
local finish_tp_time     = 0

-- Callback registered by ReaperPlugin.run_once(). C2: called exactly once
-- per run with 'success' (after Reaper returns to town and disables),
-- 'failed' or 'cancelled' (stopped before the run finished).
local run_once_callback = nil

-- C2: the current run and the terminal result of the last one. `kind` is
-- 'run_once', 'run_boss' or 'manual'. The result survives stop() so a
-- poller that only sees enabled=false still learns how the run ended.
local run = { active = false, kind = nil, last_result = nil, last_error = nil }

local function begin_run(kind)
    run.active, run.kind = true, kind
    run.last_result, run.last_error = nil, nil
end

-- Ends the current run once; returns its run_once callback (if any).
local function end_run(result, reason)
    if not run.active then return nil end
    run.active = false
    run.last_result, run.last_error = result, reason
    local cb = run_once_callback
    run_once_callback = nil
    if result ~= "success" then
        console.print(string.format("[Reaper] Run %s: %s", result, tostring(reason)))
    end
    return cb
end

local function report(cb, result)
    if not cb then return end
    local ok, err = pcall(cb, result)
    if not ok then console.print("[Reaper] run_once callback error: " .. tostring(err)) end
end

-- RPR-8: nothing confirms Belial's Ritual of Lies reward dialog while the
-- Belial Chest sequence is off, so an unattended one-shot could only fail
-- after the fight. Refuse it up front instead.
local function refuse_external(boss_id)
    if boss_id == "belial" and not settings.belial_chest_enabled then return "belial_chest_disabled" end
    return nil
end

local function on_enable()
    local lp = get_local_player()
    if not lp then return false, "no local player" end

    -- Give the game's inventory API a moment to be ready
    if (get_time_since_inject() - enable_time) < 0.5 then return false, "inventory not ready" end

    console.print("=============================================")
    console.print("  REAPER STARTING")
    console.print("=============================================")

    settings:update_settings()
    task_manager.reset_all()

    -- Orchestrator-driven path (e.g. WarPigs / WarMachine via
    -- ReaperPlugin.run_boss). The external caller already populated
    -- rotation.boss_list and set rotation.external + rotation.initialized,
    -- so the per-boss GUI selection is irrelevant. We skip the
    -- ticked-boxes validation in that case — otherwise the orchestrator's
    -- request gets silently undone here when no menu boxes are ticked.
    if rotation.external then
        local cur = rotation.current()
        console.print(string.format(
            "[Reaper] External rotation: %s [%s] — skipping menu validation.",
            (cur and cur.label)    or "?",
            (cur and cur.run_type) or "?"))
        materials.print_summary()
        return rotation.initialized, "external rotation not initialized"
    end

    -- Validate boss selection based on rotation mode
    if settings.boss_rotation_mode == "manual" then
        -- Manual mode uses the boss_target dropdown, not checkboxes
        if not settings.boss_target or settings.boss_target == "" then
            console.print("[Reaper] Manual mode: no boss target set — open menu and pick a boss.")
            return false, "no boss target set"
        end
        console.print("[Reaper] Manual mode: targeting " .. settings.boss_target)
    else
        local selected = {}
        for _, bd in ipairs(enums.boss_zones) do
            if settings.boss_enabled[bd.id] then selected[#selected + 1] = bd.label end
        end
        if #selected == 0 then
            console.print("[Reaper] No bosses selected — open menu and tick the bosses you want to farm.")
            return false, "no bosses selected"
        end
        console.print("[Reaper] Selected: " .. table.concat(selected, ", "))
    end

    -- Dump inventory so the user can verify SNO IDs in core/materials.lua
    materials.print_all_keys()
    materials.print_summary()

    rotation.build(settings)

    if not rotation.initialized then
        console.print("[Reaper] No keys / husks available for the selected bosses. Stopping.")
        return false, "no keys or husks for the selected bosses"
    end

    return true
end

local function on_disable()
    task_manager.reset_all()
    -- Drop any one-shot rotation injected by an external orchestrator so the
    -- next manual enable goes back to inventory-derived farming.
    rotation.reset()
    console.print("[Reaper] Stopped.")
    console.print(string.format("[Reaper] Total runs completed this session: %d", tracker.total_kills))
end

-- -------------------------------------------------------
-- Main update
-- -------------------------------------------------------
-- `result`/`reason` are given by the finishing path and a failed startup.
-- Any other stop (disable(), toggle off) ended the run early: 'failed' when
-- the rotation had already failed, 'success' when an external kill + chest
-- completed and only the town return remained, otherwise 'cancelled'.
local function stop(result, reason)
    if result == nil then
        if rotation.failed then
            result, reason = "failed", rotation.failure_reason or "run failed"
        elseif rotation.external and rotation.external_consumed then
            result = "success"
        else
            result, reason = "cancelled", "stopped before the run finished"
        end
    end
    local cb = end_run(result, reason)
    gui.elements.main_toggle:set(false)
    settings.enabled = false
    on_disable()
    enabled_last_frame = false
    startup_done = false
    finishing = false
    -- Cleanup before invoking the callback: it may immediately queue
    -- another run, which must start with clean task/rotation state.
    report(cb, result)
end

-- C2 in_run: an orchestrator run (run_once/run_boss) is committed from
-- acceptance until it reports; a manual run only in its committed phases
-- (altar/fight/chest, Reaper's own Alfred trip, the return to town).
local function run_in_progress(enabled)
    if not run.active then return false end
    if run.kind ~= "manual" then return true end
    if not enabled then return false end
    return finishing or tracker.altar_activated == true or tracker.chest_opened_time ~= nil
        or alfred_task.status == "waiting for alfred to complete"
end

-- C6: why Reaper is holding (Alfred or Looter), for status and overlay.
local function hold_reason()
    return alfred_task.hold_reason() or utils.loot_hold_reason()
end

on_update(function()
    settings:update_settings()
    local enabled = settings.enabled

    -- Detect toggle-on edge
    if enabled and not enabled_last_frame then
        enable_time        = get_time_since_inject()
        enabled_last_frame = true
        startup_done       = false
        if not run.active then begin_run("manual") end
        return
    end

    -- Detect toggle-off edge (also a request switched off before its first
    -- frame, so its callback still reports exactly once)
    if not enabled and (enabled_last_frame or run.active) then
        stop()
        return
    end

    if not enabled then return end

    -- Startup: attempt on_enable once inventory is ready
    if not startup_done then
        local lp = get_local_player()
        if not lp or (get_time_since_inject() - enable_time) < 0.5 then return end

        startup_done = true  -- mark attempted regardless of outcome
        local ok, why = on_enable()
        if not ok then
            stop("failed", why or "startup failed")
        end
        return
    end

    -- Normal running
    local lp = get_local_player()
    if not lp then return end
    local world = get_current_world()
    if not world or world:get_current_zone_name() == "" then return end

    -- Death recovery also applies while returning to town.
    if revive.shouldExecute() then revive.Execute(); return end

    -- When rotation is done, return to home town then disable
    if rotation.is_done() or finishing then
        if not finishing then
            -- RPR-6: let the Looter collect the boss drops before the town
            -- teleport (bounded in utils.loot_ready).
            if enums.is_boss_zone(utils.get_zone()) and not utils.loot_ready() then return end
            console.print("[Reaper] Rotation finished — returning to " .. settings.town_zone .. ".")
            task_manager.reset_all()
            teleport_to_waypoint(settings.town_waypoint)
            finishing     = true
            finish_tp_time = get_time_since_inject()
            return
        end
        local world   = get_current_world()
        local zone    = world and world:get_current_zone_name() or ""
        local elapsed = get_time_since_inject() - finish_tp_time
        if zone == settings.town_zone then
            -- RPR-11: a periodic dungeon reset that came due during this run
            -- is done here in town (the finishing path preempts the task).
            if dungeon_reset.shouldExecute() then dungeon_reset.Execute(); return end
            if rotation.failed then
                stop("failed", rotation.failure_reason or "run failed")
            else
                stop("success")
            end
        elseif elapsed > 30.0 then
            console.print("[Reaper] Town teleport not confirmed — retrying.")
            teleport_to_waypoint(settings.town_waypoint)
            finish_tp_time = get_time_since_inject()
        end
        return
    end

    task_manager.execute_tasks()
end)

-- -------------------------------------------------------
-- Render
-- -------------------------------------------------------
on_render(function()
    local lp = get_local_player()
    if not lp or not settings.enabled then return end

    local current_task = task_manager.get_current_task()
    local boss         = rotation.current()
    local pool         = rotation.pool_summary()

    -- Centered task label above the character (same style as ArkhamAsylum)
    if current_task then
        local msg  = "Reaper: " .. current_task.name
        local cx   = get_screen_width() / 2 - (#msg * 5.5)
        graphics.text_2d(msg, vec2:new(cx, 80), 20, color_white(255))
    end

    local x, y = 20, 60
    graphics.text_2d("=== REAPER  v1.10.0  by Magoogle ===", vec2:new(x, y), 14, color_orange(255))
    y = y + 20

    if boss then
        graphics.text_2d(
            string.format("Farming: %s  [%s]",
                boss.label, boss.run_type),
            vec2:new(x, y), 13, color_white(255))
        y = y + 16
    end
    if current_task then
        graphics.text_2d("Task: " .. current_task.name, vec2:new(x, y), 12, color_yellow(255))
        y = y + 16
    end
    local hold = hold_reason()
    if hold then
        graphics.text_2d("Hold: " .. hold, vec2:new(x, y), 12, color_orange(255))
        y = y + 16
    end
    graphics.text_2d("Total kills: " .. tracker.total_kills, vec2:new(x, y), 12, color_green(255))
    y = y + 20

    graphics.text_2d("── Key Pools ──", vec2:new(x, y), 12, color_white(180))
    y = y + 14
    local rows = {
        { "Lair Keys        ", pool.lair        },
        { "Greater Lair Keys", pool.greater     },
        { "Belial (Husks)   ", pool.belial_runs },
    }
    for _, r in ipairs(rows) do
        local col = r[2] > 0 and color_white(220) or color_red(180)
        graphics.text_2d(string.format("%s  %d runs", r[1], r[2]),
            vec2:new(x, y), 12, col)
        y = y + 13
    end
end)

-- -------------------------------------------------------
-- Belial chest calibration overlay
-- Drawn whenever the user has the show-crosshairs toggle on, regardless
-- of whether the farmer is enabled, so they can tune positions in front
-- of the live Ritual of Lies dialog without arming the bot.
-- -------------------------------------------------------
on_render(function()
    local cfg = settings.belial_chest
    if not cfg or not cfg.show_crosshairs then return end

    local pts = belial_chest.get_ref_points and belial_chest.get_ref_points(cfg)
    if not pts then return end

    local color_for = {
        yellow = color_yellow,
        orange = color_orange,
        green  = color_green,
        white  = color_white,
        red    = color_red,
        cyan   = color_orange,  -- no native cyan; closest is orange
    }

    for _, p in ipairs(pts) do
        local sx, sy = belial_chest.resolve_ref_to_screen(p.x, p.y)
        local cf = color_for[p.color] or color_white
        graphics.text_2d("+",      vec2:new(sx - 4, sy - 9), 22, cf(255))
        graphics.text_2d(p.label, vec2:new(sx + 10, sy - 7), 12, cf(200))
    end
end)

on_render_menu(gui.render)

-- External plugin API
ReaperPlugin = {
    enable  = function() gui.elements.main_toggle:set(true)  end,
    disable = function() stop() end,

    -- Externally request a single-boss run. boss_id must match an entry in
    -- enums.boss_zones (e.g. "duriel", "andariel", "varshan"). run_type is
    -- nil / "material" / "lair_key" infer the configured tier; explicit
    -- "lair", "greater", or "husk" override it. Sigil requests are rejected. Resets
    -- prior task state and enables the plugin. Returns true on success,
    -- false plus a reason if busy, boss_id is unknown, or run_type is
    -- unsupported.
    run_boss = function(boss_id, run_type)
        if gui.elements.main_toggle:get() then return false, "busy" end
        -- A request switched off before its first frame reports first.
        report(end_run("cancelled", "replaced by a new request"), "cancelled")
        local refused = refuse_external(boss_id)
        if refused then
            console.print(string.format("[Reaper] run_boss(%s) refused: %s", tostring(boss_id), refused))
            return false, refused
        end
        local ok, why = rotation.set_external(boss_id, run_type)
        if not ok then return false, why or "rejected" end
        begin_run("run_boss")
        task_manager.reset_all()
        gui.elements.main_toggle:set(true)
        return true
    end,

    -- Single-run orchestrator override.
    -- Runs boss_id exactly once (kill + chest + return to town) then halts.
    -- on_complete(result) is called exactly once per run (C2): 'success'
    -- after Reaper reaches town and stops, 'failed' when the run failed
    -- (status().last_error says why) and 'cancelled' when it was stopped
    -- early (disable(), toggle off). Reaper is already off when it runs.
    --
    -- boss_id   : string matching enums.boss_zones id (e.g. "duriel")
    -- run_type  : "lair" | "greater" | "husk" — nil infers from enum
    -- on_complete : optional function(result)
    --
    -- Returns true, or false plus a reason: 'busy', 'unknown boss',
    -- 'unsupported run type', 'sigil runs are not supported',
    -- 'belial_chest_disabled'.
    --
    -- Example (orchestrator side):
    --   ReaperPlugin.run_once("duriel", nil, function()
    --       console.print("Reaper done — taking back control")
    --   end)
    run_once = function(boss_id, run_type, on_complete)
        if gui.elements.main_toggle:get() then return false, "busy" end
        -- A request switched off before its first frame reports first.
        report(end_run("cancelled", "replaced by a new request"), "cancelled")
        local refused = refuse_external(boss_id)
        if refused then
            console.print(string.format("[Reaper] run_once(%s) refused: %s", tostring(boss_id), refused))
            return false, refused
        end
        local ok, why = rotation.set_external(boss_id, run_type)
        if not ok then
            console.print(string.format("[Reaper] run_once(%s) refused: %s", tostring(boss_id), tostring(why)))
            return false, why or "rejected"
        end
        begin_run("run_once")
        run_once_callback = type(on_complete) == "function" and on_complete or nil
        task_manager.reset_all()
        gui.elements.main_toggle:set(true)
        console.print(string.format("[Reaper] run_once: queued %s [%s]",
            tostring(boss_id), tostring(run_type or "auto")))
        return true
    end,

    -- Drop the external rotation without disabling. Useful if an orchestrator
    -- wants to hand control back to inventory-driven farming.
    clear_external = function()
        local cb = run.kind ~= "manual" and end_run("cancelled", "external rotation cleared") or nil
        task_manager.reset_all()
        rotation.reset()
        run_once_callback = nil
        startup_done = false
        finishing = false
        enable_time = get_time_since_inject()
        if gui.elements.main_toggle:get() and not run.active then begin_run("manual") end
        report(cb, "cancelled")
    end,

    status  = function()
        local enabled = gui.elements.main_toggle:get()
        return {
            enabled    = enabled,
            busy       = enabled,
            boss       = rotation.current() and rotation.current().label or "None",
            external   = rotation.external,
            failed     = rotation.failed,
            failure_reason = rotation.failure_reason,
            total_runs = tracker.total_kills,
            task       = task_manager.get_current_task(),
            -- C2 (additive): run phase and terminal result of the last run.
            in_run       = run_in_progress(enabled),
            external_run = run.active and run.kind == "run_once",
            last_result  = run.last_result,
            last_error   = run.last_error,
            hold_reason  = hold_reason(),
        }
    end,
}

console.print("=============================================")
console.print("  Reaper  v1.10.0  by Magoogle  - Loaded")
console.print("  Enable in menu to start reaping")
console.print("=============================================")
