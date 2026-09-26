-- Screenshot-based inputs are commands, never proof of party membership.
local data = require("tristram.data")
local M = {}
function M.close_vendor()
    if loot_manager.is_in_vendor_screen() == true or is_inventory_open() then
        local ok = pcall(utility.send_key_press, 0x1B)
        return ok
    end
    return true
end
local function dimensions()
    local ok_w, w = pcall(get_screen_width)
    local ok_h, h = pcall(get_screen_height)
    if not ok_w or not ok_h then return nil, "Waiting for readable game viewport dimensions." end
    if type(w) ~= "number" or type(h) ~= "number" or w ~= w or h ~= h
        or w <= 0 or h <= 0 or w > 32768 or h > 32768 then
        return nil, "Waiting for valid game-window dimensions (" .. tostring(w) .. "x" .. tostring(h) .. ")."
    end
    return w, h
end
M.dimensions = dimensions
function M.position(name, w, h, ui_scale)
    local p = data.PARTY_POINTS[name]
    if not p then return nil end
    local scale = math.min(w / data.PARTY_WIDTH, h / data.PARTY_HEIGHT)
    ui_scale = ui_scale or 1
    if type(ui_scale) ~= "number" or ui_scale ~= ui_scale or ui_scale < 0.5 or ui_scale > 2 then return nil end
    scale = scale * ui_scale
    local x, y = p.x * scale, p.y * scale
    local anchor = data.PARTY_ANCHORS[name]
    if anchor == "right" then x = w - (data.PARTY_WIDTH - p.x) * scale
    elseif anchor == "center" then
        x = w / 2 + (p.x - data.PARTY_WIDTH / 2) * scale
        y = h / 2 + (p.y - data.PARTY_HEIGHT / 2) * scale
    end
    return { x = math.floor(x + 0.5), y = math.floor(y + 0.5) }
end
function M.validate_keys(options)
    local stop, confirm = options.stop_key or 0, options.continue_key or 0
    if stop > 0 and stop == confirm then return false, "Stop and Confirm must use different keys." end
    if not options.automatic then return true end
    if type(options.friend) ~= "string" or #options.friend < 1 or #options.friend > 100
        or options.friend:find("[%c]") then return false, "Friend is not set or invalid. Type your friend's name in Setup > Friend." end
    if not options.social_key or options.social_key <= 0 then return false, "Assign the game's Social key." end
    local generated = { [options.social_key] = true, [0x1B] = true, [0x11] = true, [0x41] = true }
    local search = options.friend:upper()
    for index = 1, #search do
        local key = search:byte(index)
        if key >= 0x20 and key <= 0x7E then generated[key] = true end
    end
    if stop > 0 and generated[stop] or confirm > 0 and generated[confirm] then
        return false, "Stop/Confirm keys conflict with generated Social, Escape, Ctrl+A or friend-search input. Assign spare keys."
    end
    return true
end
function M.validate(options)
    local valid, why = M.validate_keys(options)
    if not valid then return false, why end
    if not options.automatic then return true end
    local w, h = dimensions()
    if not w then return false, h end
    for index, name in ipairs(data.POINTS) do
        local p = M.position(name, w, h, options.ui_scale)
        if not p then return false, "Missing automatic control: " .. data.POINT_LABELS[index] end
        if p.x < 0 or p.y < 0 or p.x >= w or p.y >= h then return false, "Invalid automatic control: " .. name end
    end
    return true, nil, w, h
end
function M.new(kind, options, sample, now)
    local settle_delay = options.settle_delay or 5
    local prompt_delay = options.prompt_delay or 5
    local steps = kind == "join" and { "social", "search", "select", "text", "friend", "join", "transfer" }
        or kind == "entryjoin" and { "social", "search", "select", "text", "friend", "join" }
        or kind == "entryclose" and { "escape" }
        or kind == "arrival" and {}
        or { "social", "leave", "leaveaccept" }
    local p = { index = 1, sent = kind == "arrival", armed = kind == "arrival", gap = false, transition = false,
        baseline = sample and sample.id, ready_at = now, stable_at = nil, kind = kind,
        baseline_name = sample and sample.name, baseline_zone = sample and sample.zone,
        started_at = now, last_input_at = nil,
        viewport_paused = 0 }
    local initial_width, initial_height = dimensions()
    p.width, p.height = initial_width, initial_width and initial_height or nil
    function p.paused_seconds(time)
        return p.viewport_paused + (p.viewport_wait_at and time - p.viewport_wait_at or 0)
    end
    local function viewport(time)
        if not options.automatic then return end
        local w, h = dimensions()
        if not w or w ~= p.width or h ~= p.height then
            p.viewport_wait_at = p.viewport_wait_at or time
            p.viewport_stable_at = w and time or nil
            p.width, p.height = w, w and h or nil
        elseif p.viewport_wait_at and p.viewport_stable_at and time - p.viewport_stable_at >= 1 then
            local elapsed = time - p.viewport_wait_at
            p.viewport_paused = p.viewport_paused + elapsed
            p.ready_at = p.ready_at + elapsed -- preserve the pending prompt/input delay
            p.viewport_wait_at, p.viewport_stable_at = nil, nil
        end
        p.viewport_detail = p.viewport_wait_at and (w and "Window changed; waiting for the viewport to settle."
            or "Window minimized or viewport unavailable; party inputs paused.") or nil
    end
    function p.observe(current, time)
        viewport(time)
        if not p.armed then return end
        if not current then p.gap = true; p.stable_at = nil; return end
        if p.gap or current.id ~= p.baseline or current.name ~= p.baseline_name or current.zone ~= p.baseline_zone then
            p.transition = true
            p.sent = true -- the timed transfer may already have occurred; never click into the world
            if not p.stable_at or p.stable_world ~= current.id or p.stable_name ~= current.name or p.stable_zone ~= current.zone then
                p.stable_at = time
                p.stable_world, p.stable_name, p.stable_zone = current.id, current.name, current.zone
            end
        end
    end
    function p.tick(current, time)
        p.observe(current, time)
        if not current or current.dead or p.sent or p.viewport_wait_at or time < p.ready_at then return true end
        if not options.automatic then p.armed = true; p.sent = true; return true end
        local valid, why, w, h = M.validate(options)
        if not valid then return false, why end
        if w ~= p.width or h ~= p.height then viewport(time); return true end
        local action = steps[p.index]
        local point = M.position(action, w, h, options.ui_scale)
        local ok, err = pcall(function()
            if action == "social" then utility.send_key_press(options.social_key)
            elseif action == "escape" then utility.send_key_press(0x1B)
            elseif action == "select" then utility.send_key_combo(0x11, 0x41)
            elseif action == "text" then utility.send_string(options.friend)
            else
                if action == "friend" then utility.send_mouse_right_click(point.x, point.y)
                else utility.send_mouse_click(point.x, point.y) end
            end
        end)
        if not ok then return false, "Party input failed: " .. tostring(err) end
        -- Leaving opens a confirmation dialog. Only Accept can start the departure.
        if action == "join" or action == "leaveaccept" or action == "escape" then
            p.armed = true
            p.baseline, p.baseline_name, p.baseline_zone = current.id, current.name, current.zone
        end
        p.index = p.index + 1
        local delay = options.step_delay
        if action == "join" then delay = math.max(prompt_delay, delay)
        elseif action == "leave" then delay = math.max(2, delay) end
        p.ready_at = time + delay
        console.print(string.format("[TristramLoop] party=%s input=%s%s window=%dx%d elapsed=%.1fs since_previous=%.1fs next_wait=%.1fs",
            kind, action, point and string.format(" click=(%d,%d)", point.x, point.y) or "",
            w, h, time - p.started_at, p.last_input_at and time - p.last_input_at or 0, delay))
        p.last_input_at = time
        if p.index > #steps then p.sent = true end
        return true
    end
    function p.can_confirm(time)
        return not p.viewport_wait_at and p.sent and time >= p.ready_at and (not p.transition
            or (p.stable_at ~= nil and time - p.stable_at >= settle_delay))
    end
    function p.settle_remaining(time)
        if not p.transition or not p.stable_at then return 0 end
        return math.max(0, settle_delay - (time - p.stable_at))
    end
    function p.auto_ready(time)
        -- A loading gap back into the same Pony instance is not a new run.
        if options.farm_map == "pony" and kind == "join" and p.stable_world == p.baseline then return false end
        return not p.viewport_wait_at and options.auto_transition and p.transition and p.stable_at ~= nil and time - p.stable_at >= settle_delay
    end
    return p
end
return M
