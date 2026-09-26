-- Native checkpoint revival: paced, bounded, and never called while alive/loading.
local data = require("tristram.data")
local M = {}
function M.same(a, b)
    return a ~= nil and b ~= nil and a.id == b.id and a.name == b.name and a.zone == b.zone
end
function M.settled(state, sample, time, delay)
    if not sample or sample.dead then state.stable, state.stable_at = nil, nil; return false end
    if not M.same(state.stable, sample) then state.stable, state.stable_at = sample, time end
    return time - state.stable_at >= delay
end
function M.new(time)
    local r = { started = time, attempts = 0, next_try = time, provider = "native",
        wait_state = {}, wait_seconds = 0, response_elapsed = 0, last_tick = time, observed_alive = false }
    function r.tick(sample, current, settle_delay, allow_vendor)
        -- A response deadline applies only while life/world data is unavailable.
        -- Confirmed life keeps the full countdown and menu wait out of that budget.
        r.response_elapsed = r.response_elapsed + math.max(0, current - r.last_tick)
        r.last_tick, r.wait_seconds = current, 0
        if sample and not sample.dead then
            r.response_elapsed = 0
            r.observed_alive = true
        elseif sample and sample.dead and r.observed_alive then
            -- A second death is a new bounded request, even if the previous death
            -- exhausted its native calls before a manual revival was observed.
            r.response_elapsed, r.attempts, r.next_try = 0, 0, current
            r.observed_alive, r.last_result = false, nil
        end
        if r.response_elapsed >= 90 then
            return "failed", "Revive timed out waiting for a living, loaded character. Last call: " .. (r.last_result or "none")
        end
        if not sample then M.settled(r, nil, current, settle_delay)
            M.settled(r.wait_state, nil, current, data.REVIVE_WAIT_SECONDS)
            return "waiting", "Revive: waiting for the world to load."
        end
        if sample.dead then
            M.settled(r, nil, current, settle_delay)
            M.settled(r.wait_state, nil, current, data.REVIVE_WAIT_SECONDS)
            if current < r.next_try then return "waiting", "Waiting for the revive response." end
            if r.attempts >= 8 then
                return "waiting", "Revive calls exhausted (8/8); waiting for a living character. Manual revival can still resume the loop."
            end
            local native = rawget(_G, "revive_at_checkpoint")
            if type(native) ~= "function" then return "failed", "This host does not expose revive_at_checkpoint." end
            r.attempts, r.next_try = r.attempts + 1, current + 1.5
            local ok, result = pcall(native)
            local detail = tostring(result):gsub("[%c]", " "):sub(1, 240)
            r.last_result = (ok and "returned " or "raised ") .. detail
            console.print(string.format("[TristramLoop] Checkpoint revive attempt %d/8 %s; waiting for an alive observation.", r.attempts, r.last_result))
            -- The native may change life state before returning false or raising.
            -- Keep observing; neither its return nor its error proves the outcome.
            if not ok or result == false then
                return "waiting", "Checkpoint revive " .. r.last_result .. "; recovery remains active."
            end
            return "waiting", "Checkpoint revive requested; waiting for the character."
        end
        if not M.same(r.wait_state.stable, sample) then
            console.print(string.format("[TristramLoop] Revived in a loaded world; waiting %ds before returning to the arena.", data.REVIVE_WAIT_SECONDS))
        end
        local post_ready = M.settled(r.wait_state, sample, current, data.REVIVE_WAIT_SECONDS)
        r.wait_seconds = math.max(0, data.REVIVE_WAIT_SECONDS - (current - r.wait_state.stable_at))
        -- An interrupted town service owns its vendor screen and must be allowed
        -- to resume/close it. Farming still waits for closed inventory and chat.
        if is_chat_open() or is_inventory_open() and not allow_vendor then
            M.settled(r, nil, current, settle_delay)
            return "waiting", "Revived; waiting for the inventory/chat menu to close."
        end
        local settled = M.settled(r, sample, current, settle_delay)
        if post_ready and settled then return "done" end
        if r.wait_seconds > 0 then
            return "waiting", string.format("Revived; waiting %.0fs before walking back to the arena.", math.ceil(r.wait_seconds))
        end
        return "waiting", "Revived; waiting for the world to settle before resuming."
    end
    return r
end
return M
