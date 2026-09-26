-- Activity lifecycle for the in-arena party reset loop.
local settings = require("tristram.settings")
local data = require("tristram.data")
local host = require("tristram.host")
local party = require("tristram.party")
local encounter = require("tristram.encounter")
local navigation = require("tristram.navigation")
local alfred = require("tristram.bridge_alfred")
local recovery = require("tristram.recovery")
local movement = require("tristram.bridge_movement")
local rotation = require("tristram.bridge_rotation")
local lease = require("tristram.activity_lease")
local pony = require("tristram.pony")
local pony_data = require("tristram.pony_data")
local combat_policy = require("tristram.combat_policy")
local native_town = require("tristram.native_town")
local M = {}

function M.new(store)
    local c = { phase = "idle", detail = "Stopped. Party clicks are automatic; type your friend in Setup > Friend and start.",
        cycles = 0, skipped = 0, running = false, held = false, active = true, previous_enabled = false,
        entered = 0, wait_seconds = 0, fight = encounter.new(), cleanup_pending = false,
        last_tick = -1, cold_until = get_time_since_inject() + settings.options().cooldown }
    local saved_orb = nil
    local cleanup_movement_done, cleanup_rotation_done = false, false
    local sequence = nil
    local options = nil
    local arena = nil
    local run_world = nil
    local last_action = -math.huge
    local awaiting_item = nil
    local loot_empty_since = nil
    local initial = true
    local navigator = nil
    local entry = nil
    local town, revival, last_loaded = nil, nil, nil
    local menu_hold = nil
    local town_grace = 0
    local retry_reason, retry_until, retry_sample = nil, nil, nil
    local retry_pickup_elapsed = nil -- interrupted pickup budget, independent of clear classification
    local attempt_died, incomplete_empty_at = false, nil
    local next_progress_log = 0
    local pony_run, pony_return = nil, nil
    local pony_loot_origin = nil
    local pony_return_at = nil
    local pony_loot_return, pony_clear_elapsed, pony_pickup_elapsed = false, 0, nil
    local targets, attacking = nil, nil
    local failure_streak, session_deaths, last_potion = 0, 0, -math.huge
    local function is_pony() return options ~= nil and options.farm_map == "pony" end
    local function map_label() return is_pony() and "Whimsyshire" or "Tristram" end
    local function scan_area(sample)
        if not is_pony() then return arena end
        return { x = sample.position:x(), y = sample.position:y(), z = sample.position:z() }
    end
    local function copy_position(position) return vec3:new(position:x(), position:y(), position:z()) end
    local function now() return get_time_since_inject() end
    local function wall_time()
        local system = rawget(_G, "os")
        local value = type(system) == "table" and host.try(system.time)
        return type(value) == "number" and value or nil
    end
    local function go(phase, detail)
        if phase == "loot" then loot_empty_since = nil end
        c.phase, c.detail, c.entered = phase, detail, now()
        host.try(console.print, "[TristramLoop] " .. detail)
    end
    local function stop_movement()
        return movement.release()
    end
    local function release_step(fn)
        local ok, result = pcall(fn)
        return ok and result ~= false
    end
    local function clean()
        -- Mark pending before effects; independent stages still release if one
        -- throws, and the lease survives until every stage finishes.
        c.cleanup_pending = true
        local released = true
        local _, service_status = alfred.find()
        local foreign_combat = rotation.has_foreign_target()
        local servicing = town ~= nil or alfred.busy(service_status) or foreign_combat
        if town then
            if release_step(town.ticket.cancel) then town = nil else released = false end
        end
        if lease.owns() then
            -- Alfred owns movement during service, including an adopted foreign job.
            if not cleanup_movement_done then
                cleanup_movement_done = servicing or release_step(stop_movement)
                if not cleanup_movement_done then released = false end
            end
            if not cleanup_rotation_done then
                cleanup_rotation_done = release_step(rotation.release)
                if not cleanup_rotation_done then released = false end
            end
            if saved_orb ~= nil then
                local current_orb = host.try(orbwalker.get_orb_mode)
                if foreign_combat or current_orb ~= nil and current_orb ~= orb_mode.clear then
                    saved_orb = nil -- a later player/provider choice supersedes our saved mode
                elseif current_orb == nil then
                    released = false
                elseif release_step(function() return orbwalker.set_orbwalker_mode(saved_orb) end) then
                    saved_orb = nil
                else released = false end
            end
            if not released then return false end
            if not release_step(lease.release) then return false end
        elseif not released then return false end
        town, revival, saved_orb = nil, nil, nil
        menu_hold = nil
        retry_reason, retry_until, retry_sample = nil, nil, nil
        retry_pickup_elapsed = nil
        loot_empty_since = nil
        pony_run, pony_return, pony_pickup_elapsed = nil, nil, nil
        sequence = nil
        navigator = nil
        entry = nil
        c.cleanup_pending = false
        c.fallback_state, c.fallback_spell_id, c.fallback_distance, c.fallback_reason = "idle", nil, nil, nil
        return true
    end
    function c.stop(reason)
        c.running, c.held = false, true
        c.stop_reason = reason or "Stopped."
        local ok = clean()
        go(ok and "hold" or "cleanup", ok and c.stop_reason or "Waiting for movement, recovery and combat controls to release.")
        return ok
    end
    function c.disable(source)
        if not c.active then return false end
        host.try(function() settings.elements.enabled:set(false) end)
        c.previous_enabled = false
        return c.stop(source or "Stopped by external control.")
    end
    function c.shutdown()
        if not c.active then return true end
        local ok = c.disable("Stopped for Lua reload/shutdown.")
        if ok then c.active = false end
        return ok
    end
    local function admitted()
        if host.try(auto_play.is_active) == true then
            return false, "Stop host Auto-play before running the Tristram loop."
        end
        -- Gameplay choices stay frozen; callbacks read these two widgets live.
        options.stop_key = settings.elements.stop_key:get_key()
        options.continue_key = settings.elements.continue_key:get_key()
        return party.validate_keys(options)
    end
    local function stamp()
        if is_pony() then c.pony_until = now() + options.pony_reset_wait; return end
        -- Save at fight start and after observed deaths: reload cannot erase a recent kill.
        store.last_clear = wall_time() or store.last_clear
        store.save()
        c.cold_until = now() + options.cooldown
    end
    local function remaining()
        if is_pony() then return math.max(0, (c.pony_until or 0) - now()) end
        if not options.loot_mode then return 0 end
        local wall = wall_time()
        if store.last_clear and wall then
            local elapsed = math.max(0, wall - store.last_clear)
            return math.max(0, options.cooldown - elapsed)
        end
        return math.max(0, c.cold_until - now())
    end
    local function pause_combat()
        rotation.refresh()
        if rotation.clear_external_target() == false then return false end
        return rotation.set_travel_mode(true) ~= false
    end
    local function quiet()
        if stop_movement() == false then return false end
        return pause_combat()
    end
    local function begin_clear(sample)
        if not host.in_arena(sample, arena) then c.stop("Outside the selected " .. map_label() .. " map; return there before clearing."); return end
        sequence = nil
        entry = nil
        c.fight = encounter.new()
        retry_reason, retry_until, retry_sample = nil, nil, nil
        retry_pickup_elapsed = nil
        attempt_died, incomplete_empty_at = false, nil
        c.clear_wait_seconds, next_progress_log = options.clear_timeout, now()
        run_world = sample.id
        if is_pony() then
            targets = combat_policy.new(options)
            navigator, pony_return, pony_pickup_elapsed = nil, nil, nil
            pony_loot_return, pony_clear_elapsed = false, 0
            pony_run = pony.new(sample, now(), options)
            last_action = -math.huge
            go("clear", "Exploring Whimsyshire; fighting enemies and opening clouds and chests.")
            return
        end
        local route, why = navigation.new(sample.position, vec3:new(arena.x, arena.y, arena.z), now(), options.range)
        if not route then c.stop(why); return end
        navigator = route
        last_action = -math.huge
        stamp()
        go("clear", "Clearing Tristram. Waiting for three observed boss deaths.")
    end
    local function begin_join(sample, from_outside)
        if not quiet() then c.stop("Rotation refused the party-step pause."); return end
        local kind = from_outside and "entryjoin" or "join"
        sequence = party.new(kind, options, sample, now())
        go(kind, "Join " .. (options.friend ~= "" and options.friend or "your friend") .. (from_outside and " to enter " .. map_label() .. "." or ", accept transfer, then confirm if no transition is observed."))
    end
    local function begin_leave(sample)
        -- User's live observation: Transfer Now closes Social. Reopen it to leave.
        sequence = party.new("leave", options, sample, now())
        go("leave", "Leave Party, then Accept. Waiting for a transition or your confirmation.")
    end
    local function begin_portal(sample)
        entry = { sent = false, progress_at = now(), loading = false }
        sequence = party.new("arrival", options, sample, now())
        go("portal", "First entry: finding the party member's portal; waiting for verified " .. map_label() .. " arrival.")
    end
    local function after_join(sample)
        if is_pony() and not initial and sample.id == run_world then
            c.stop("Repeat transfer did not produce a new Pony instance; party membership remains unconfirmed."); return
        end
        sequence = nil
        if host.in_arena(sample, arena) then begin_leave(sample)
        elseif not initial then c.stop("Repeat transfer left " .. map_label() .. "; restart for a new first entry.")
        else
            sequence = party.new("entryclose", options, sample, now())
            go("entryclose", "First entry: close Social with Escape, then use the party member's portal.")
        end
    end
    local function resume_retry_pickup()
        if not quiet() then c.stop("Rotation refused to resume pending retry pickup."); return false end
        navigator, awaiting_item, last_action = nil, nil, -math.huge
        go("loot", "Returning enemies cleared; resuming the same pending pickup.")
        c.entered = now() - (retry_pickup_elapsed or 0)
        retry_pickup_elapsed = nil
        return true
    end
    local function finish_clear()
        if retry_pickup_elapsed ~= nil then return resume_retry_pickup() end
        if not quiet() then c.stop("Rotation refused to finish the fight."); return false end
        stamp()
        navigator = nil
        awaiting_item = nil
        retry_reason, retry_until, retry_sample = nil, nil, nil
        if is_pony() then
            pony_loot_return = false
            pony_loot_origin = copy_position(last_loaded.position)
            pony_run.pause(now())
        end
        go("loot", "Encounter cleared; collecting host-approved drops.")
        return true
    end
    local function finish_pickup()
        if not quiet() then c.stop("Rotation refused the end-of-pickup pause."); return end
        if is_pony() and pony_loot_return then
            pony_run.looted(now(), pony_loot_origin)
            go("clear", "Nearby pony drops collected; continuing exploration.")
            c.entered = now() - pony_clear_elapsed
            pony_loot_return, pony_pickup_elapsed = false, nil
            return
        end
        if is_pony() then stamp() end
        retry_pickup_elapsed = nil
        initial = false
        if retry_reason then
            c.skipped = c.skipped + 1
            if is_pony() then
                failure_streak = failure_streak + 1
                if failure_streak >= options.pony_retry_limit then
                    c.stop("Pony consecutive incomplete-run limit reached: " .. retry_reason); return
                end
            end
            retry_until = now() + data.RETRY_WAIT_SECONDS
            if is_pony() then retry_until = now() + math.min(120, data.RETRY_WAIT_SECONDS * 2 ^ (failure_streak - 1)) end
            go("cooldown", "Incomplete attempt not counted; retrying a fresh instance after the wait. " .. retry_reason)
        else
            if is_pony() then failure_streak = 0 end
            c.cycles = c.cycles + 1
            go("cooldown", "Clear finished. Waiting before joining and creating the next instance.")
        end
    end
    local function retry_attempt(sample, reason)
        if not host.in_arena(sample, arena) or sample.id ~= run_world or not c.fight.known then return end
        if not quiet() then c.stop("Rotation refused the incomplete-attempt pause."); return end
        retry_reason, retry_sample = reason, sample
        if is_pony() then pony_loot_return = false; pony_loot_origin = copy_position(sample.position); pony_run.pause(now()) end
        retry_pickup_elapsed = nil
        navigator, awaiting_item = nil, nil
        last_action = -math.huge
        if c.fight.alive == 0 then
            -- An unobserved last death may still have dropped loot. Preserve the
            -- ordinary policy/service path before discarding the incomplete run.
            go("loot", (is_pony() and "Pony sweep incomplete" or "Boss evidence incomplete") .. "; collecting eligible drops before retrying. " .. reason)
        else finish_pickup() end
    end
    local function suspended(sample)
        if menu_hold then return menu_hold.saved end
        local origin = last_loaded or sample
        if is_pony() and origin then
            origin = { id = origin.id, name = origin.name, zone = origin.zone, position = copy_position(origin.position) }
        end
        return { phase = c.phase, elapsed = now() - c.entered, sample = origin,
            in_arena = host.in_arena(origin, arena) }
    end
    local function resume_phase(saved, sample, label, revived, from_town)
        incomplete_empty_at = nil
        loot_empty_since = nil
        last_loaded = sample
        movement.refresh()
        rotation.refresh()
        if not quiet() then c.stop("Rotation refused the recovery pause."); return end
        if saved.phase ~= "clear" and saved.phase ~= "loot" and saved.phase ~= "cooldown" then
            c.stop(label .. ": a party input step was interrupted. Close Social, then restart; no old clicks were replayed.")
            return
        end
        if saved.in_arena and not recovery.same(saved.sample, sample) then
            if not revived then c.stop("Alfred returned to a different instance; previous clear not counted."); return end
            -- A checkpoint in another world cannot inherit this instance's deaths.
            c.fight, run_world, initial = encounter.new(), nil, true
            retry_reason, retry_until, retry_sample = nil, nil, nil
            retry_pickup_elapsed = nil
            sequence, entry, navigator = nil, nil, nil
            pony_run, pony_return, pony_pickup_elapsed = nil, nil, nil
            go("cooldown", "Revived outside the original instance; re-entering after any remaining loot wait.")
            return
        end
        c.fight.target, c.fight.empty_at = nil, nil
        last_action, awaiting_item = -math.huge, nil
        if is_pony() and pony_run then
            pony_run.resume(now())
            if pony_return then pony_return_at = now() end
            if (revived or from_town) and saved.in_arena then
                local position = saved.sample.position
                pony_return = vec3:new(position:x(), position:y(), position:z())
                pony_return_at = now()
            end
            go(saved.phase, label .. "; resuming pony " .. saved.phase .. ".")
            c.entered = now() - saved.elapsed
            return
        end
        local return_to_arena = revived and saved.phase == "cooldown" and host.in_arena(sample, arena)
        if saved.phase == "clear" or saved.phase == "loot" or return_to_arena then
            if not host.in_arena(sample, arena) then c.stop("Recovery did not return to Tristram."); return end
            local route, why = navigation.new(sample.position, vec3:new(arena.x, arena.y, arena.z), now(), options.range)
            if not route then c.stop(why); return end
            navigator = route
        end
        go(saved.phase, label .. "; resuming " .. saved.phase .. " with " .. c.fight.bosses .. "/3 observed boss deaths.")
        c.entered = now() - saved.elapsed -- servicing/revival does not consume fight or pickup time
    end
    local function begin_town(sample, peer, status, adopt)
        if targets then targets.pause() end
        local saved = suspended(sample)
        if pony_run then pony_run.pause(now()) end
        menu_hold = nil
        local paused
        if adopt then paused = pause_combat() else paused = quiet() end
        if not paused then c.stop("Rotation refused the town-service pause."); return end
        navigator = nil
        local native = is_pony() and not adopt and not options.use_butler and options.pony_native_town
        status = status or {}
        local count = sample and host.method(sample.player, "get_item_count")
        local ticket, why
        if native then ticket, why = native_town.begin(sample, type(count) == "number" and count >= data.INVENTORY_CAPACITY, native_town.needs_repair(sample.player) == true)
        else ticket, why = alfred.begin(peer, status, adopt) end
        if not ticket then c.stop(why); return end
        town = { ticket = ticket, saved = saved, started = now(), count = count,
            need_room = status.inventory_full == true or type(count) == "number" and count >= data.INVENTORY_CAPACITY,
            need_repair = status.need_repair == true, need_talisman = status.talisman_inventory_full == true }
        go("town", native and "Native town service: store carried gear safely, then return to this instance."
            or adopt and "Alfred is already working; yielding until service and return finish."
            or "Calling Alfred once for town service and return. Its item rules control salvage and storage.")
    end
    local function town_tick(sample)
        if now() - town.started >= options.town_timeout then
            c.stop((town.ticket.native and "Native" or "Alfred") .. " town/return timed out: " .. c.detail); return
        end
        local done, why, status = town.ticket.poll()
        if why then c.stop(why); return end
        if not done then
            recovery.settled(town, nil, now(), options.settle_delay)
            c.detail = town.ticket.detail or "Waiting for Alfred to finish servicing and return."
            return
        end
        if not sample or sample.dead or town.saved.in_arena and not host.in_arena(sample, arena) then
            recovery.settled(town, nil, now(), options.settle_delay)
            c.detail = "Alfred signalled completion; waiting for the return to " .. map_label() .. "."
            return
        end
        if is_inventory_open() or is_chat_open() then
            recovery.settled(town, nil, now(), options.settle_delay)
            c.detail = "Alfred finished; waiting for the inventory/vendor menu to close."
            return
        end
        if not recovery.settled(town, sample, now(), options.settle_delay) then
            c.detail = "Alfred returned; waiting for the world to settle."
            return
        end
        local count = host.method(sample.player, "get_item_count")
        if town.need_room and (type(count) ~= "number" or count >= data.INVENTORY_CAPACITY
            or type(town.count) == "number" and count >= town.count or status.inventory_full == true)
            or town.need_repair and status.need_repair == true
            or town.need_talisman and status.talisman_inventory_full == true then
            c.stop("Alfred finished but the requested inventory/repair need remains. Check its item rules and stash space.")
            return
        end
        local saved = town.saved
        town.ticket.cancel()
        town, town_grace = nil, now() + 30
        resume_phase(saved, sample, "Town service and same-instance return completed", false, true)
    end
    local function begin_revival(sample)
        if targets then targets.pause() end
        attempt_died, incomplete_empty_at = true, nil
        if is_pony() then
            session_deaths = session_deaths + 1
            if session_deaths >= options.pony_death_limit then c.stop("Pony session death limit reached; check equipment and combat."); return end
        end
        if not options.auto_revive then c.stop("Character died. Automatic revival is disabled."); return end
        local saved = suspended(sample)
        if pony_run then pony_run.pause(now()) end
        menu_hold = nil
        if not quiet() then c.stop("Rotation refused the revive pause."); return end
        if town and town.ticket.set_recovering(true) == false then c.stop("Alfred refused to pause for revival."); return end
        navigator = nil
        revival = { saved = saved, state = recovery.new(now()) }
        go("revive", "Character died; pausing the loop for checkpoint revival.")
    end
    local function revive_tick(sample)
        local state, why = revival.state.tick(sample, now(), options.settle_delay,
            town ~= nil and revival.saved.phase == "town")
        if state == "failed" then c.stop(why); return end
        if state ~= "done" then c.detail = why; return end
        local saved, duration = revival.saved, now() - revival.state.started
        revival = nil
        if saved.phase == "town" and town then
            if town.ticket.set_recovering(false) == false then c.stop("Alfred refused to resume after revival."); return end
            town.started = town.started + duration
            recovery.settled(town, nil, now(), options.settle_delay)
            go("town", "Revived; waiting for the existing Alfred request and return.")
        else resume_phase(saved, sample, "Revived", true) end
    end
    local function service_if_needed(sample, peer, status)
        -- Do not break a fight or an in-progress party reset for our own request.
        if c.phase ~= "loot" and c.phase ~= "cooldown" then return false end
        local count = host.method(sample.player, "get_item_count")
        local native_repair = is_pony() and options.pony_native_town and native_town.needs_repair(sample.player) == true
        local needed = alfred.needed(status, count) or native_repair
        if is_pony() and options.pony_native_town and not options.use_butler then
            needed = native_repair or type(count) == "number" and count >= data.INVENTORY_CAPACITY
        end
        if not needed then return false end
        if now() < town_grace and (type(count) ~= "number" or count < data.INVENTORY_CAPACITY)
            and not (status and status.need_repair == true) and not native_repair then return false end
        if not options.use_butler then
            if is_pony() and options.pony_native_town then begin_town(sample, peer, status, false); return true end
            if options.loot and type(count) == "number" and count >= data.INVENTORY_CAPACITY then
                if not quiet() then c.stop("Combat could not pause for full inventory."); return true end
                c.entered = now() -- manual inventory clearing does not consume the pickup budget
                loot_empty_since = nil -- a bag/menu pause cannot count as an empty ground scan
                c.detail = "Inventory full. Clear space manually to resume pickup."
                return true
            end
            return false
        end
        begin_town(sample, peer, status, false)
        return true
    end
    function c.start()
        if not c.active then return false, "This addon instance was unloaded." end
        if c.running then return true end
        if c.cleanup_pending and not clean() then return false, c.detail end
        local sample = host.sample()
        if not sample then return false, "Waiting for a loaded character." end
        options = settings.options()
        if options.automatic and options.friend == "" then return false, settings.FRIEND_MISSING end
        if options.farm_map == "pony" and not sample.dead and not combat_policy.ready(options) then
            return false, "Pony combat needs an equipped attack in the selected slot or an enabled rotation."
        end
        if options.farm_map == "pony" and options.pony_native_town and not options.use_butler and not native_town.available() then
            return false, "Automatic Pony storage needs native town APIs or configured Alfred."
        end
        if options.farm_map == "pony" and options.use_butler then
            local peer, state = alfred.find()
            if not peer or not state or state.enabled ~= true or state.allow_external == false then
                return false, "Pony town service needs enabled Alfred with external calls allowed, or native safe storage."
            end
        end
        local allowed, admission_reason = admitted()
        if not allowed then return false, admission_reason end
        if sample.dead and not options.auto_revive then return false, "Revive before starting, or enable automatic revival." end
        arena = is_pony() and { name = pony_data.WORLD, zone = pony_data.ZONE } or store.arena or data.ARENA
        pony_run, pony_return, pony_pickup_elapsed = nil, nil, nil
        pony_loot_return, c.pony_until = false, 0
        local valid, reason = party.validate(options)
        if not valid then return false, reason end
        if not rotation.available() then return false, "Another script owns the combat handoff. Stop it before starting this loop." end
        local acquired, owner = lease.acquire()
        if not acquired then return false, "Another activity owns control: " .. tostring(owner) end
        cleanup_movement_done, cleanup_rotation_done = false, false
        movement.refresh()
        rotation.refresh()
        if not rotation.orb_mode_owned_elsewhere() then
            saved_orb = orbwalker.get_orb_mode()
            orbwalker.set_orbwalker_mode(orb_mode.clear)
        end
        local _, service_status = alfred.find()
        local paused
        if alfred.busy(service_status) then paused = pause_combat() else paused = quiet() end
        if not paused then c.stop("Rotation refused the initial pause."); return false, c.detail end
        c.running, c.held, initial = true, false, true
        c.stop_reason = nil
        failure_streak, session_deaths, targets, attacking = 0, 0, nil, nil
        last_loaded = sample
        settings.elements.enabled:set(true)
        c.previous_enabled = true
        go("cooldown", is_pony() and "Preparing a pony sweep; choose a friend with a joinable Whimsyshire instance."
            or "Preparing the first clear; loot mode respects the last kill or reload wait.")
        return true
    end
    function c.enable()
        if not c.active then return false, "This addon instance was unloaded." end
        settings.elements.enabled:set(true)
        c.held = false
        local ok, why = c.start()
        if not ok then c.detail = why; c.stop_reason = why end
        return ok, why
    end
    function c.confirm()
        if c.running then
            local allowed, why = admitted()
            if not allowed then c.stop(why); return false, why end
        end
        local sample = host.sample()
        -- Keys/menu callbacks can precede on_update after a loading gap.
        if sequence then sequence.observe(sample, now()) end
        if not c.running or not lease.owns() or not sample or sample.dead or not sequence or not sequence.can_confirm(now()) then
            return false, "There is no completed party input step to confirm."
        end
        if c.phase == "join" or c.phase == "entryjoin" then after_join(sample); return c.running end
        if c.phase == "entryclose" then
            if host.in_arena(sample, arena) then begin_leave(sample) else begin_portal(sample) end
            return c.running
        end
        if c.phase == "portal" then
            if not host.in_arena(sample, arena) then return false, "Waiting to arrive in " .. map_label() .. "." end
            begin_leave(sample); return c.running
        end
        if c.phase == "leave" then begin_clear(sample); return c.running end
        return false
    end
    function c.finish()
        if c.running then
            local allowed, why = admitted()
            if not allowed then c.stop(why); return false, why end
        end
        if is_pony() then return false, "Pony mode finishes after exploration and observed pickup." end
        local sample = host.sample()
        if c.phase ~= "clear" or not c.running or not lease.owns() or not host.in_arena(sample, arena)
            or sample.dead or sample.id ~= run_world then return false end
        c.fight.scan(sample, arena, options.range, now())
        if not c.fight.known or c.fight.alive > 0 then
            c.detail = "Completion refused: living enemies or unreadable actor list."
            return false
        end
        return finish_clear()
    end
    local function route_tick(sample)
        if not navigator then return false end
        local state, target = navigator.tick(sample.position, now())
        if state == "done" then navigator = nil; stop_movement(); return false end
        if state == "blocked" then c.stop(target); return true end
        if rotation.clear_external_target() == false or rotation.set_travel_mode(true) == false then
            c.stop("Rotation refused the recorded-path pause."); return true
        end
        c.detail = string.format("Recorded path: waypoint %d/%d.", navigator.index, #navigator.points)
        if movement.go_to(target, { regime = "corridor", arrive_dist = 0.8, disable_spell = true }) == false then
            c.stop("Movement refused: " .. tostring(movement.last_error()))
        end
        return true
    end
    local function move_to(position, sample, reach)
        if is_pony() then
            if not pause_combat() then c.stop("Rotation refused pony movement."); return end
            local state, target = pony_run.approach(sample.position, position, now(), reach or 2)
            if state == "blocked" then
                if attacking and targets then
                    targets.defer("Pony approach failed: " .. tostring(target))
                    pony_run.pause(now()); pony_run.resume(now())
                    if not quiet() then c.stop("Failed to release a deferred target.") end
                    c.detail = "Deferring unreachable enemy; seeking other reachable work."
                else c.stop("Pony approach failed: " .. tostring(target)) end
                return
            end
            if state == "move" then
                if movement.go_to(target, { regime = "combat", arrive_dist = 0.8, disable_spell = true }) == false then
                    if attacking and targets then
                        targets.defer("Pony movement refused: " .. tostring(movement.last_error()))
                        pony_run.pause(now()); pony_run.resume(now())
                        if not quiet() then c.stop("Failed to release refused target movement.") end
                    else c.stop("Pony movement refused: " .. tostring(movement.last_error())) end
                end
            else stop_movement(); c.detail = tostring(target or "Waiting for a pony approach path.") end
            return
        end
        -- Entry owns the recorded corridor. Once it is complete, ordinary arena
        -- combat/loot movement must not try to reconstruct that entrance route.
        if route_tick(sample) then return end
        if host.distance(vec3:new(arena.x, arena.y, arena.z), position) > options.range then
            c.stop("Movement target is outside the Tristram encounter range."); return
        end
        if rotation.clear_external_target() == false or rotation.set_travel_mode(true) == false then
            c.stop("Rotation refused arena movement."); return
        end
        if movement.go_to(position, { regime = "combat", arrive_dist = 2, disable_spell = true }) == false then
            c.stop("Arena movement refused: " .. tostring(movement.last_error()))
        end
    end
    local function portal_tick(sample)
        if now() - c.entered > options.timeout then
            host.diagnose()
            c.stop("First-entry portal timed out: " .. c.detail)
            return
        end
        if entry.loading then
            entry.loading, entry.actor_id, entry.best = false, nil, nil
            entry.progress_at = now()
        end
        local settling = sequence.settle_remaining(now())
        if settling > 0 then
            stop_movement()
            c.detail = string.format("Portal/world loaded; waiting %.1fs for the menu to close.", settling)
            return
        end
        if host.in_arena(sample, arena) then
            stop_movement()
            c.detail = "Arrived in " .. map_label() .. ". Confirm the current party step if automatic transitions are off."
            if sequence.auto_ready(now()) then begin_leave(sample) end
            return
        end
        if entry.sent then
            c.detail = "Portal interaction sent; waiting to arrive in " .. map_label() .. " (current world: " .. sample.name .. ")."
            return
        end
        local portal, why = host.entry_portal(sample.position)
        if not portal then
            stop_movement()
            entry.best = nil
            c.detail = why
            if entry.note ~= why then console.print("[TristramLoop] " .. why); entry.note = why end
            return
        end
        local position = host.method(portal, "get_position")
        local distance = host.distance(sample.position, position)
        local id = host.method(portal, "get_id")
        if entry.actor_id ~= id or not entry.best then
            entry.actor_id, entry.best, entry.progress_at = id, distance, now()
            console.print(string.format("[TristramLoop] First-entry %s actor_id=%s distance=%.1f.", data.ENTRY_PORTAL_SKIN, tostring(id), distance))
        elseif distance < entry.best - 0.15 then entry.best, entry.progress_at = distance, now() end
        if distance > 2 then
            if now() - entry.progress_at >= 12 then c.stop("Party portal approach blocked for 12 seconds."); return end
            c.detail = string.format("First entry: approaching the party portal (%.1f away).", distance)
            if movement.go_to(position, { regime = "corridor", arrive_dist = 1.5, disable_spell = true }) == false then
                c.stop("Portal movement refused: " .. tostring(movement.last_error()))
            end
            return
        end
        stop_movement()
        entry.sent = true
        sequence = party.new("arrival", options, sample, now())
        local accepted = host.try(interact_object, portal)
        console.print("[TristramLoop] Party portal interaction sent; result=" .. tostring(accepted) .. "; arrival still unconfirmed.")
        if accepted == false then c.stop("Party portal interaction refused. Check the portal, then restart.") end
    end
    local function attack_target(sample, target)
        local position = host.method(target, "get_position")
        local distance = host.distance(sample.position, position)
        c.fallback_distance = distance
        if distance > options.fight_range then
            c.fallback_spell_id, c.fallback_reason = nil, nil
            c.fallback_state = "approaching"
            if rotation.clear_external_target() == false then c.stop("Rotation refused target cleanup."); return end
            move_to(position, sample, options.fight_range)
            return
        end
        stop_movement()
        if rotation.set_external_target(target) == false then c.stop("Rotation refused the combat target."); return end
        local external_rotation, rotation_reason = host.standalone_rotation()
        if external_rotation then
            c.fallback_spell_id, c.fallback_reason = nil, nil
            c.fallback_state = rotation_reason and "rotation_unavailable" or "external_rotation"
            c.fallback_reason = rotation_reason
            c.detail = rotation_reason or "Fighting through your enabled rotation."; return
        end
        if now() - last_action < 0.3 then return end
        last_action = now()
        local ids = host.try(get_equipped_spell_ids)
        if is_pony() and targets then ids = targets.spells(ids) end
        c.fallback_spell_id, c.fallback_reason = nil, nil
        local attempted = false
        if type(ids) == "table" then
            for _, id in ipairs(ids) do
                if type(id) == "number" and id > 0 and host.try(utility.can_cast_spell, id) == true then
                    attempted = true
                    c.fallback_spell_id = id
                    local cast = rotation.fallback_attack(target, id, 0.2)
                    c.fallback_state = cast and "cast_accepted" or "cast_refused"
                    c.fallback_reason = rotation.last_error()
                    if cast then c.detail = "Fighting with an equipped spell (basic fallback)."; return end
                end
            end
        end
        if not attempted then c.fallback_state = "no_castable_spell" end
        c.detail = attempted and "Equipped spells refused this target; waiting."
            or "No castable equipped spell. Equip a usable skill or fight manually."
    end
    local function pony_return_tick(sample)
        if not pony_return then return false end
        -- Recovery travel has its own validated-leg bounds, not the interrupted pickup clock.
        c.entered = c.entered + math.max(0, now() - (pony_return_at or now()))
        pony_return_at = now()
        local height, saved_height = host.method(sample.position, "z"), host.method(pony_return, "z")
        if host.distance(sample.position, pony_return) <= 2 and type(height) == "number"
            and type(saved_height) == "number" and math.abs(height - saved_height) <= 1 then
            pony_return = nil; stop_movement(); return false
        end
        if not pause_combat() then c.stop("Rotation refused the pony recovery return."); return true end
        local action, value = pony_run.return_step(sample.position, pony_return, now())
        if action == "blocked" then c.stop("Pony recovery return blocked: " .. tostring(value)); return true end
        if action == "move" then
            if movement.go_to(value, { regime = "combat", arrive_dist = 0.8, disable_spell = true }) == false then
                c.stop("Pony recovery movement refused: " .. tostring(movement.last_error())); return true
            end
        else stop_movement() end
        c.detail = "Returning along explored pony terrain after recovery. " .. (type(value) == "string" and value or "")
        return true
    end
    local function pony_clear_tick(sample)
        c.fight.scan(sample, scan_area(sample), options.range, now())
        c.clear_wait_seconds = math.max(0, options.pony_timeout - (now() - c.entered))
        if not c.fight.known then
            targets.pause()
            if c.clear_wait_seconds <= 0 then
                c.stop("Pony enemy scan unreadable at sweep limit; run not counted. " .. c.fight.progress)
                return
            end
            pony_run.pause(now())
            if not quiet() then c.stop("Rotation refused the unreadable pony scan pause.") end
            c.detail = "Waiting for readable pony enemy data; this is not an empty map."
            return
        end
        if pony_return_tick(sample) then return end
        local selected = targets.select(sample, options.range, now())
        if c.clear_wait_seconds <= 0 then
            if pony_pickup_elapsed ~= nil then c.stop("Pony combat timed out while pickup was pending; drops were not discarded."); return end
            retry_attempt(sample, "Pony exploration time limit reached; sweep not counted.")
            return
        end
        if selected then
            pony_run.combat(now())
            attacking = selected
            attack_target(sample, selected)
            attacking = nil
            return
        end
        if c.fight.alive > 0 and pony_pickup_elapsed ~= nil then
            if not quiet() then c.stop("Rotation refused pending-pickup combat wait.") end
            c.detail = "Pickup retained; waiting to retry deferred enemies."
            return
        end
        pony_run.defer_loot = c.fight.alive > 0
        if not pause_combat() then c.stop("Rotation refused pony exploration."); return end
        if pony_pickup_elapsed ~= nil then
            if not c.fight.empty_at or now() - c.fight.empty_at < 5 then stop_movement(); return end
            go("loot", "Pony enemies cleared; resuming the pending pickup.")
            c.entered = now() - pony_pickup_elapsed
            pony_pickup_elapsed = nil
            return
        end
        local action, value = pony_run.tick(sample, now())
        if action == "move" then
            c.detail = "Exploring Whimsyshire and approaching nearby clouds/chests."
            if movement.go_to(value, { regime = "combat", arrive_dist = 0.8, disable_spell = true }) == false then
                c.stop("Pony exploration movement refused: " .. tostring(movement.last_error()))
            end
        elseif action == "interact" or action == "attack" then
            stop_movement()
            if action == "interact" then
                local result = host.try(interact_object, value)
                c.detail = "Pony interaction sent; waiting for an observed object state change."
                console.print("[TristramLoop] Pony interact " .. tostring(host.method(value, "get_skin_name")) .. " result=" .. tostring(result))
            else
                -- Exact metadata-confirmed breakable container, with combat suppressed.
                -- Equipped-bar fallback avoids inventing a class spell or asking an enemy-only rotation to target a prop.
                local ids = host.try(get_equipped_spell_ids)
                local cast = false
                if type(ids) == "table" then
                    for _, id in ipairs(ids) do
                        if type(id) == "number" and id > 0 and host.try(utility.can_cast_spell, id) == true then
                            cast = rotation.fallback_attack(value, id, 0.2)
                            if cast then break end
                        end
                    end
                end
                c.detail = cast and "Attacking a pony breakable container; waiting for observed destruction."
                    or "No equipped spell accepted the container; attempts remain bounded."
            end
        elseif action == "loot" then
            if not quiet() then c.stop("Rotation refused pony pickup."); return end
            pony_loot_return, pony_clear_elapsed = true, now() - c.entered
            pony_loot_origin = copy_position(sample.position)
            awaiting_item, last_action = nil, -math.huge
            go("loot", value)
        elseif action == "done" then
            if targets.unresolved > 0 then
                retry_attempt(sample, "Exploration exhausted with " .. targets.unresolved .. " unresolved enemies; sweep not counted.")
                return
            end
            pony_clear_elapsed = now() - c.entered
            finish_clear()
            if c.running then c.detail = "Reachable pony exploration finished; collecting remaining nearby drops." end
        elseif action == "incomplete" or action == "blocked" then
            pony_clear_elapsed = now() - c.entered
            retry_attempt(sample, tostring(value))
        else stop_movement(); c.detail = tostring(value or "Waiting for pony exploration.") end
        if c.running and pony_run and now() >= next_progress_log then
            local status = pony_run.status()
            console.print(string.format("[TristramLoop] Pony progress: nodes=%d edge_arrivals=%d pending_edges=%d objects=%d settled=%d unresolved=%d position=(%.1f,%.1f,%.1f) | %s | %s",
                status.nodes or 0, status.reveal_arrivals or 0, status.pending_frontiers or 0,
                status.objects, status.opened, status.unresolved,
                sample.position:x(), sample.position:y(), sample.position:z(), c.detail, status.reason or ""))
            next_progress_log = now() + 10
        end
    end
    local function clear_tick(sample)
        if not host.in_arena(sample, arena) or sample.id ~= run_world then c.stop("World changed during the clear; run not counted."); return end
        if is_pony() then pony_clear_tick(sample); return end
        local previous = c.fight.bosses
        c.fight.scan(sample, arena, options.range, now())
        if not c.fight.known and now() - c.entered >= options.clear_timeout then
            c.stop("Boss scan unreadable at clear limit; run not counted. " .. c.fight.progress)
            return
        end
        if c.fight.bosses > previous then stamp() end
        if retry_pickup_elapsed ~= nil and c.fight.known and c.fight.alive == 0 and navigator == nil
            and c.fight.empty_at and now() - c.fight.empty_at >= 5 then
            resume_retry_pickup()
            return
        end
        if retry_pickup_elapsed == nil and options.auto_finish and c.fight.complete(now()) then finish_clear(); return end
        local retry_wait = options.clear_timeout - (now() - c.entered)
        local incomplete = c.fight.bosses < 3 and not attempt_died
            or c.fight.seen_count >= 3 and c.fight.unresolved > 0
        if c.fight.known and c.fight.alive == 0 and navigator == nil and incomplete then
            if not incomplete_empty_at then incomplete_empty_at = now() end
            retry_wait = math.min(retry_wait, data.INCOMPLETE_EMPTY_SECONDS - (now() - incomplete_empty_at))
        else incomplete_empty_at = nil end
        c.clear_wait_seconds = math.max(0, retry_wait)
        if now() >= next_progress_log then
            local next_step = c.fight.known and string.format("Attempt retry in %.0fs.", math.ceil(c.clear_wait_seconds))
                or "Retry requires a readable encounter scan."
            if retry_pickup_elapsed ~= nil then next_step = "Pending pickup; fight limit " .. math.ceil(c.clear_wait_seconds) .. "s." end
            console.print("[TristramLoop] Clear progress: " .. c.fight.progress .. " " .. next_step)
            next_progress_log = now() + 5
        end
        if retry_wait <= 0 and c.fight.known then
            if retry_pickup_elapsed ~= nil then
                c.stop("Returning enemies prevented pending retry pickup; fight timed out without abandoning drops.")
                return
            end
            local reason = c.fight.progress
            if incomplete_empty_at and now() - incomplete_empty_at >= data.INCOMPLETE_EMPTY_SECONDS then
                reason = "Arena stayed empty for " .. data.INCOMPLETE_EMPTY_SECONDS .. " seconds; "
                    .. (attempt_died and "death evidence remains incomplete. " or "no death observed in this attempt. ") .. reason
            end
            retry_attempt(sample, reason)
            return
        end
        if route_tick(sample) then return end
        local target = c.fight.target
        if target then
            attack_target(sample, target)
            return
        end
        if rotation.clear_external_target() == false then c.stop("Rotation refused target cleanup."); return end
        local center = vec3:new(arena.x, arena.y, arena.z)
        if host.distance(sample.position, center) > 3 then move_to(center, sample)
        else stop_movement(); c.detail = "At the arena center; waiting for all three boss deaths. Empty space is not completion." end
    end
    local function loot_tick(sample)
        if not host.in_arena(sample, arena) or sample.id ~= run_world then c.stop("World changed before loot finished; repeat stopped."); return end
        if is_pony() and pony_return_tick(sample) then loot_empty_since = nil; return end
        if now() - c.entered > 60 then c.stop("Pickup timed out: " .. c.detail); return end
        c.fight.scan(sample, scan_area(sample), options.range, now())
        if not c.fight.known then
            loot_empty_since = nil
            c.detail = "Waiting for a readable encounter before finishing pickup."
            return
        end
        if c.fight.alive > 0 then
            loot_empty_since = nil
            awaiting_item = nil
            if not quiet() then c.stop("Rotation refused to resume the fight."); return end
            if is_pony() then
                pony_pickup_elapsed = now() - c.entered
                pony_run.combat(now())
                go("clear", "Pony enemies returned during pickup; clearing before resuming the same pickup.")
                c.entered = now() - pony_clear_elapsed
                return
            end
            retry_pickup_elapsed = now() - c.entered
            incomplete_empty_at = nil
            go("clear", "Enemies returned during pickup; clearing before collecting the pending drops.")
            return
        end
        if route_tick(sample) then loot_empty_since = nil; return end
        local items = host.try(actors_manager.get_all_items)
        if type(items) ~= "table" then loot_empty_since = nil; c.detail = "Waiting for a readable loot list."; return end
        local looter = rawget(_G, "LooteerPlugin")
        local policy = nil
        if options.loot and type(looter) == "table" and type(rawget(looter, "evaluate_item")) == "function" then
            local status = host.try(rawget(looter, "status"))
            if type(status) ~= "table" then c.stop("Looteer status is unreadable; pickup stopped."); return end
            if status.enabled == true then
                -- Current Looteer yields standalone pickup to this activity but
                -- keeps its filter available. Preserve its separate Behavior rule.
                local policy_ready = status.ready == true
                if status.activity_owned == true and status.reason == "activity_owned" then
                    local behavior = host.try(rawget(looter, "getSettings"), "behavior")
                    policy_ready = behavior == 0 or behavior == 1 and host.try(orbwalker.get_orb_mode) == orb_mode.clear
                end
                if status.paused == true or not policy_ready then
                    loot_empty_since = nil
                    c.detail = "Waiting for Looteer: externally paused or its Behavior setting is inactive."
                    return
                end
                policy = rawget(looter, "evaluate_item")
                host.try(rawget(looter, "observe_items"), items)
            end
        end
        local item, item_position, deferred, pending_deferred = nil, nil, nil, nil
        if options.loot then
            local area = scan_area(sample)
            local center = is_pony() and pony_loot_origin or vec3:new(area.x, area.y, area.z)
            for _, candidate in pairs(items) do
                local same = awaiting_item ~= nil and host.method(candidate, "get_id") == awaiting_item
                local position = host.method(candidate, "get_position")
                local distance = host.distance(center, position)
                local position_known = distance < math.huge
                if not position_known or distance <= options.range then
                    local lootable = host.try(loot_manager.is_lootable_item, candidate, false, false)
                    local wanted = lootable == true
                    local reason = type(lootable) ~= "boolean" and "host lootability is unreadable" or nil
                    if policy then
                        local ok, accepted, why, decision = pcall(policy, candidate, true)
                        if not ok or type(accepted) ~= "boolean" then c.stop("Looteer item filter failed; pickup stopped."); return end
                        wanted = accepted and lootable == true
                        if decision == "deferred" then
                            wanted = false
                            reason = tostring(why or "Looteer item data is unreadable")
                        elseif not accepted then
                            reason = nil -- a final policy rejection needs no other pickup data
                        end
                    end
                    if wanted and not position_known then
                        wanted, reason = false, "item position is unreadable"
                    end
                    if reason then
                        deferred = reason:gsub("[%c]", " "):sub(1, 160)
                        if same then pending_deferred = deferred end
                    end
                    -- Host enumeration order may change each frame. Continue
                    -- the same observed pickup using fresh policy and position.
                    if wanted and (not item or same) then item, item_position = candidate, position end
                end
            end
        end
        if pending_deferred then awaiting_item = nil; deferred = pending_deferred end
        if item then
            loot_empty_since = nil
            local id = host.method(item, "get_id")
            if awaiting_item ~= id then awaiting_item = id; last_action = -math.huge end
            if now() - last_action < 1 then return end
            last_action = now()
            local position = item_position -- use this frame's validated observation
            local info = host.method(item, "get_item_info")
            local label = tostring(host.method(info, "get_display_name") or host.method(item, "get_skin_name") or id):gsub("[\r\n]", " "):sub(1,100)
            c.detail = "Picking up " .. label .. " (actor " .. tostring(id) .. ")."
            if host.distance(sample.position, position) > 3 then move_to(position, sample)
            else
                stop_movement()
                local result = host.try(loot_manager.loot_item, item, false, false)
                c.detail = c.detail .. " Host result=" .. tostring(result) .. "; waiting for disappearance."
            end
            return -- a returned true never counts as observed pickup
        end
        if deferred then
            loot_empty_since = nil
            stop_movement()
            c.detail = "Waiting for readable loot policy: " .. deferred .. "."
            return -- unknown policy is not a rejection or observed pickup
        end
        loot_empty_since = loot_empty_since or now()
        if now() - c.entered < 5 then return end -- allow delayed drops to become visible
        if now() - loot_empty_since < 2 then
            c.detail = "Confirming the pickup area is clear before the next instance."
            return
        end
        finish_pickup()
    end
    -- Loot wait / retry wait before the next join (split out of c.tick to keep
    -- its LuaJIT upvalue count below the bundle's margin).
    local function cooldown_tick(sample)
        if is_pony() and pony_return_tick(sample) then return end
        if route_tick(sample) then return end -- checkpoint return also applies during the loot wait
        c.wait_seconds = remaining()
        if retry_reason then
            if not recovery.same(retry_sample, sample) then c.stop("Instance changed before the incomplete-attempt retry; old reset cancelled."); return end
            c.wait_seconds = math.max(c.wait_seconds, math.max(0, (retry_until or now()) - now()))
            c.detail = string.format("Incomplete attempt not counted. Next instance in %.0fs. %s", math.ceil(c.wait_seconds), retry_reason)
        elseif c.wait_seconds > 0 then
            c.detail = string.format("Clear finished. Next instance in %.0fs.", math.ceil(c.wait_seconds))
        end
        if c.wait_seconds > 0 then return end
        retry_reason, retry_until, retry_sample = nil, nil, nil
        if initial then
            if host.in_arena(sample, arena) then begin_clear(sample)
            else begin_join(sample, true) end
        elseif host.in_arena(sample, arena) then begin_join(sample)
        else c.stop("Left " .. map_label() .. " during the wait. Return before starting another run.") end
    end
    function c.tick()
        if not c.active then return end
        if c.cleanup_pending then
            if clean() then go("hold", c.stop_reason or "Stopped.") end
            return
        end
        local enabled = settings.elements.enabled:get()
        if not enabled then
            if c.running or c.previous_enabled then c.disable("Stopped: Run farming loop was switched off.") end
            if c.cleanup_pending then clean() end
            return
        end
        if not c.previous_enabled then
            c.previous_enabled = true
            local ok, why = c.start()
            if not ok then c.stop(why) end
            return
        end
        if not c.running or now() - c.last_tick < 0.1 then return end
        c.last_tick = now()
        if not lease.owns() then c.stop("Activity ownership lost."); return end
        if rotation.has_foreign_target() then c.stop("Another script replaced the combat target; control released."); return end
        local allowed, admission_reason = admitted()
        if not allowed then c.stop(admission_reason); return end
        local sample = host.sample()
        -- Recovery owns these frames, including loading and vendor screens. The
        -- party observer must never mistake a revive/town load for a party ACK.
        -- Reassert combat suppression, but leave Alfred's own movement untouched.
        if (town or revival) and not pause_combat() then c.stop("Rotation refused the recovery pause."); return end
        if revival then revive_tick(sample); return end
        local butler, butler_status = alfred.find()
        if not town and alfred.busy(butler_status) then
            begin_town(sample, butler, butler_status, true)
            if c.running and sample and sample.dead then begin_revival(sample) end
            return
        end
        if sample and sample.dead then begin_revival(sample); return end
        if town then town_tick(sample); return end
        if sequence then sequence.observe(sample, now()) end
        if not sample then
            if entry and not entry.loading then stop_movement(); entry.loading = true end
            if c.phase == "clear" or c.phase == "loot" then c.stop("Loading interrupted the encounter; run not counted.")
            elseif now() - c.entered - (sequence and sequence.paused_seconds(now()) or 0) > options.timeout then c.stop("Loading/transfer timed out.") end
            return
        end
        last_loaded = sample
        if is_chat_open() or is_inventory_open() then
            if targets then targets.pause() end
            if c.phase ~= "clear" and c.phase ~= "loot" and c.phase ~= "cooldown" then
                c.stop("Chat or inventory interrupted a party step. Close it, then restart."); return
            end
            if not menu_hold then
                menu_hold = { saved = suspended(sample) }
                if pony_run then pony_run.pause(now()) end
                navigator = nil
                console.print("[TristramLoop] Waiting for chat/inventory to close; the run will resume automatically.")
            end
            if not quiet() then c.stop("Rotation refused the menu pause."); return end
            c.detail = "Paused while chat/inventory is open. Close it to resume automatically."
            return
        end
        if menu_hold then
            local saved = menu_hold.saved
            menu_hold = nil
            if not recovery.same(saved.sample, sample) then c.stop("World changed while the menu was open; run not counted."); return end
            resume_phase(saved, sample, "Menus closed", false)
            return
        end
        movement.refresh()
        rotation.refresh()
        if is_pony() and options.pony_potion and not host.standalone_rotation()
            and (c.phase == "clear" or c.phase == "loot") and now() - last_potion >= 3 then
            local hp, maximum = host.method(sample.player, "get_current_health"), host.method(sample.player, "get_max_health")
            if type(hp) == "number" and type(maximum) == "number" and maximum > 0 and hp / maximum < 0.35
                and (host.method(sample.player, "get_health_potion_count") or 0) > 0 then
                last_potion = now(); host.try(use_health_potion)
            end
        end
        if service_if_needed(sample, butler, butler_status) then return end
        if c.phase == "cooldown" then cooldown_tick(sample)
        elseif c.phase == "join" or c.phase == "entryjoin" or c.phase == "entryclose" or c.phase == "leave" then
            if now() - c.entered - sequence.paused_seconds(now()) > options.timeout then c.stop("Party step timed out. Verify it manually; no repeat clicks were sent."); return end
            local ok, why = sequence.tick(sample, now())
            if not ok then c.stop(why); return end
            if sequence.viewport_detail then c.detail = sequence.viewport_detail; return end
            local settling = sequence.settle_remaining(now())
            if settling > 0 then
                c.detail = string.format("Transfer loaded; waiting %.1fs for the menu to close.", settling)
            elseif sequence.transition and not options.auto_transition then
                c.detail = "Transfer settled. Confirm the current party step when ready."
            end
            -- Joining can complete without a loading gap. Pacing the first-entry
            -- commands permits Escape and portal discovery, not a claim of arrival.
            local entry_inputs_done = (c.phase == "entryjoin" or c.phase == "entryclose") and options.automatic
                and sequence.can_confirm(now()) and (not sequence.transition and not sequence.gap or sequence.auto_ready(now()))
            if sequence.auto_ready(now()) or entry_inputs_done then
                if c.phase == "join" or c.phase == "entryjoin" then after_join(sample)
                elseif c.phase == "entryclose" then
                    if host.in_arena(sample, arena) then begin_leave(sample) else begin_portal(sample) end
                else begin_clear(sample) end
            end
        elseif c.phase == "portal" then portal_tick(sample)
        elseif c.phase == "clear" then clear_tick(sample)
        elseif c.phase == "loot" then loot_tick(sample) end
    end
    function c.status()
        local detail = c.detail
        if c.phase == "clear" and not is_pony() then
            local next_step = c.fight.known and string.format(" Retry in %.0fs.", math.ceil(c.clear_wait_seconds or 0))
                or " Retry requires a readable encounter scan."
            if retry_pickup_elapsed ~= nil then next_step = " Pending pickup; fight limit " .. math.ceil(c.clear_wait_seconds or 0) .. "s." end
            detail = detail .. " | " .. c.fight.progress .. next_step
        end
        local pony_status = pony_run and pony_run.status() or {}
        return { name = data.name, version = data.version, enabled = settings.elements.enabled:get(),
            farm_map = options and options.farm_map or settings.options().farm_map,
            pony_opened = pony_status.opened or 0, pony_objects = pony_status.objects or 0,
            pony_unresolved = pony_status.unresolved or 0,
            pony_nodes = pony_status.nodes or 0,
            pony_unknown_objects = pony_status.unknown_objects or 0,
            pony_coverage = "reachable sampled terrain; unknown objects are diagnostics",
            pony_effective_limit = options and options.pony_timeout or nil,
            pony_deferred_enemies = targets and targets.deferred or 0,
            pony_unresolved_enemies = targets and targets.unresolved or 0,
            pony_progress_age = targets and targets.progress_age or 0,
            pony_target_reason = targets and targets.reason or "",
            pony_failure_streak = failure_streak, pony_session_deaths = session_deaths,
            pony_retries_remaining = options and math.max(0, options.pony_retry_limit - failure_streak) or 0,
            pony_service = options and (options.use_butler and "configured Alfred" or options.pony_native_town and "native safe storage" or "manual") or "not configured",
            state = c.phase, phase = c.phase, detail = detail, running = c.running, held = c.held,
            -- Why the loop last stopped or refused to start; nil while running.
            stop_reason = not c.running and c.stop_reason or nil,
            friend_set = ((c.running and options or settings.options()).friend or "") ~= "",
            loot_wait_minutes = settings.loot_wait_minutes(),
            cycles = c.cycles, skipped_attempts = c.skipped, bosses = c.fight.bosses, attempt_had_death = attempt_died,
            wait_seconds = c.phase == "clear" and c.clear_wait_seconds or c.wait_seconds,
            owns_activity = lease.owns(), activity_owner = lease.owner_name() or "none",
            controls_loot = c.running and lease.owns(), menu_paused = menu_hold ~= nil,
            party_state = "not exposed by host", cleanup_pending = c.cleanup_pending,
            town_pending = town ~= nil, revive_attempts = revival and revival.state.attempts or 0,
            revive_wait_seconds = revival and revival.state.wait_seconds or 0,
            recovery_phase = revival and revival.saved.phase or town and town.saved.phase or "none",
            fallback_state = c.fallback_state or "idle", fallback_spell_id = c.fallback_spell_id,
            fallback_distance = c.fallback_distance, fallback_reason = c.fallback_reason,
            fallback_approach_distance = options and options.fight_range or nil,
            waypoint = navigator and navigator.index or 0, waypoints = navigator and #navigator.points or 0 }
    end
    lease.bind_release(function() return c.shutdown() end)
    return c
end
return M
