local M = { developer_id = "tristram_loop_v1", FALLBACK_ANIMATION_TIME = 0.2 }
local data = require("tristram.data")
-- Load-time requires only: other addons may call status()/options() through the
-- public API, and a lazy require there would resolve against their folder.
local party = require("tristram.party")
local explorer = require("tristram.pony_explorer")
local function id(s) return get_hash(M.developer_id .. "_" .. s) end
local previous = rawget(_G, "TristramLoopPlugin")
local cached = type(previous) == "table" and rawget(previous, "_settings")
-- F5 can retain host widgets. Reuse the prior set rather than register duplicate IDs.
local e = type(cached) == "table" and cached.developer_id == M.developer_id and cached.elements or {
    root = tree_node:new(0), setup = tree_node:new(1), advanced = tree_node:new(1),
    enabled = checkbox:new(false, id("enabled")), mode = combo_box:new(0, id("mode")),
    custom_friend = input_text:new(id("custom_friend")),
    automatic = checkbox:new(true, id("automatic")),
    auto_transition = checkbox:new(true, id("auto_transition")),
    auto_finish = checkbox:new(true, id("auto_finish")),
    step_delay = slider_float:new(0.5, 5.0, 1.5, id("step_delay")),
    timeout = slider_int:new(20, 120, 60, id("timeout")),
    clear_timeout = slider_int:new(60, 900, 300, id("clear_timeout")),
    range = slider_int:new(10, 80, 60, id("range")),
    fight_range = slider_int:new(3, 25, 12, id("fight_range")),
    loot = checkbox:new(true, id("loot")),
    social_key = keybind:new(0x4F, false, id("social_key")),
    continue_key = keybind:new(0, false, id("continue_key")),
    stop_key = keybind:new(0, false, id("stop_key")),
    confirm = button:new(id("confirm")),
    finish = button:new(id("finish")), diagnose = button:new(id("diagnose")),
}
-- Add this widget to cached pre-0.1.4 settings without recreating their host IDs.
-- Loot wait uses a new widget id so an old saved 15-30 minute value cannot
-- survive the switch to the one-hour default.
if not e.loot_wait then e.loot_wait = slider_int:new(data.LOOT_WAIT_MIN, data.LOOT_WAIT_MAX, data.LOOT_WAIT_DEFAULT, id("loot_wait_minutes")) end
if not e.settle_delay then e.settle_delay = slider_float:new(1, 15, 5, id("settle_delay")) end
if not e.prompt_delay then e.prompt_delay = slider_float:new(2, 15, 5, id("prompt_delay")) end
if not e.use_butler then e.use_butler = checkbox:new(false, id("use_butler")) end
if not e.auto_revive then e.auto_revive = checkbox:new(true, id("auto_revive")) end
if not e.town_timeout then e.town_timeout = slider_int:new(60, 900, 300, id("town_timeout")) end
if not e.farm_map then e.farm_map = combo_box:new(0, id("farm_map")) end
if not e.pony_reset_wait then e.pony_reset_wait = slider_int:new(5, 180, 5, id("pony_reset_wait")) end
if not e.pony_timeout then e.pony_timeout = slider_int:new(5, 90, 20, id("pony_timeout")) end
if not e.pony_native_town then e.pony_native_town = checkbox:new(true, id("pony_native_town")) end
if not e.pony_stall_seconds then e.pony_stall_seconds = slider_int:new(5, 60, 12, id("pony_stall_seconds")) end
if not e.pony_retry_limit then e.pony_retry_limit = slider_int:new(1, 10, 3, id("pony_retry_limit")) end
if not e.pony_death_limit then e.pony_death_limit = slider_int:new(1, 10, 3, id("pony_death_limit")) end
if not e.pony_attack_slot then e.pony_attack_slot = combo_box:new(0, id("pony_attack_slot")) end
if not e.pony_priority then e.pony_priority = combo_box:new(0, id("pony_priority")) end
if not e.pony_potion then e.pony_potion = checkbox:new(true, id("pony_potion")) end
if not e.ui_scale then e.ui_scale = slider_int:new(50, 200, 100, id("ui_scale")) end
if not e.preview_points then e.preview_points = checkbox:new(false, id("preview_points")) end
-- Native trees belong to this render generation; saved setting widgets retain IDs.
e.root, e.setup, e.advanced = tree_node:new(0), tree_node:new(1), tree_node:new(1)
M.elements = e
-- A reload must never send party clicks using an old persisted master switch.
e.enabled:set(false)
local function combo(element, n)
    local v = element:get()
    if type(v) ~= "number" or v < 0 or v >= n or v ~= math.floor(v) then element:set(0); return 0 end
    return v
end
function M.options()
    local raw = e.custom_friend:get()
    local custom = type(raw) == "string" and raw:match("^%s*(.-)%s*$") or ""
    return { enabled = e.enabled:get(), loot_mode = combo(e.mode, 2) == 0,
        farm_map = combo(e.farm_map, 2) == 1 and "pony" or "tristram",
        pony_reset_wait = e.pony_reset_wait:get(), pony_timeout = math.min(e.pony_timeout:get() * 60, explorer.MAX_ACTIVE_SECONDS),
        pony_native_town = e.pony_native_town:get(), pony_stall_seconds = e.pony_stall_seconds:get(),
        pony_retry_limit = e.pony_retry_limit:get(), pony_death_limit = e.pony_death_limit:get(),
        pony_attack_slot = combo(e.pony_attack_slot, 7), pony_priority = combo(e.pony_priority, 2), pony_potion = e.pony_potion:get(),
        friend = custom, -- empty until the player types a friend; start holds with a reason
        automatic = e.automatic:get(), auto_transition = e.auto_transition:get(), ui_scale = e.ui_scale:get() / 100,
        auto_finish = e.auto_finish:get(), cooldown = M.loot_wait_minutes() * 60,
        step_delay = e.step_delay:get(), settle_delay = e.settle_delay:get(), prompt_delay = e.prompt_delay:get(),
        timeout = e.timeout:get(), clear_timeout = e.clear_timeout:get(),
        use_butler = e.use_butler:get(), auto_revive = e.auto_revive:get(), town_timeout = e.town_timeout:get(),
        range = e.range:get(), fight_range = e.fight_range:get(), loot = e.loot:get(), social_key = e.social_key:get_key(),
        stop_key = e.stop_key:get_key(), continue_key = e.continue_key:get_key() }
end
function M.loot_wait_minutes()
    local v = e.loot_wait:get()
    if type(v) ~= "number" or v ~= v then return data.LOOT_WAIT_DEFAULT end
    return math.max(data.LOOT_WAIT_MIN, math.min(data.LOOT_WAIT_MAX, v))
end
M.FRIEND_MISSING = "Friend is not set. Type your friend's account or character name in Setup > Friend, then switch Run off and on."
function M.use_movement() return true end
function M.use_rotation() return true end
function M.manage_orbwalker() return true end
local function section(node, label, fn)
    if not node:push(label) then return end
    local ok, err = pcall(fn)
    node:pop()
    if not ok then render_menu_header("Menu error: " .. tostring(err)) end
end
function M.render(status, store, command)
    section(e.root, "Tristram / Pony Loop", function()
        combo(e.farm_map, 2)
        e.farm_map:render("Farm map", { "Tristram bosses", "Pony / Whimsyshire" }, "Choose while stopped. Start inside the selected map, or join your friend's party portal. A change takes effect on the next Start.")
        local pony_mode = (status.running and status.farm_map or M.options().farm_map) == "pony"
        e.enabled:render("Run farming loop", "Clear or explore the selected map, collect drops, join, accept transfer, leave, accept leaving, and repeat.")
        render_menu_header(status.detail)
        if not status.running then
            if e.automatic:get() then
                render_menu_header("Party controls adapt to your game window. No cursor captures needed.")
                render_menu_header(pony_mode and "Close Social, choose your friend, then switch Run off and on."
                    or "Close Social, choose XP or Loot, then switch Run off and on.")
            else render_menu_header("Manual party steps: clear first, then join/accept transfer and leave/accept when prompted.") end
        end
        local wait = status.phase == "revive" and status.revive_wait_seconds or status.wait_seconds
        if pony_mode then
            render_menu_header(string.format("Completed sweeps: %d | Incomplete: %d | Objects settled: %d/%d | Wait: %.0fs",
                status.cycles, status.skipped_attempts or 0, status.pony_opened or 0, status.pony_objects or 0, wait or 0))
            render_menu_header(string.format("Deferred enemies: %d | Unresolved: %d | No progress: %.0fs | Retries left: %d",
                status.pony_deferred_enemies or 0, status.pony_unresolved_enemies or 0, status.pony_progress_age or 0, status.pony_retries_remaining or 0))
            render_menu_header(string.format("Storage: %s | Sweep cap: %.0f min | Unclassified interactables: %d",
                status.pony_service or "not configured", (status.pony_effective_limit or M.options().pony_timeout) / 60, status.pony_unknown_objects or 0))
        else
            render_menu_header(string.format("Cleared runs: %d | Skipped attempts: %d | Boss deaths: %d/3 | Wait: %.0fs",
                status.cycles, status.skipped_attempts or 0, status.bosses, wait))
        end
        combo(e.mode, 2)
        if not pony_mode then e.mode:render("Purpose", { "Loot / gear", "XP (no loot wait)" }, "Loot waits before the next join and reset. XP may not drop loot.") end
        local friend = M.options().friend
        render_menu_header(friend == "" and "Friend: not set (open Setup > Friend). The loop will not start without it."
            or "Friend: " .. friend)
        e.use_butler:render("Use optional Alfred town service", "Off by default. If enabled, configure Alfred and allow external calls in its own menu.")
        e.auto_revive:render("Automatically revive", "Waits 45 seconds after observed revival, then resumes the recorded Tristram route or reconnects to pony exploration. A different instance invalidates old progress.")
        e.confirm:render("Confirm current party step", "After transfer finishes, or after Leave Party and its Accept confirmation finish in the game.", 0)
        if e.confirm:get() then command("confirm") end
        if status.phase == "clear" and not pony_mode then
            e.finish:render("I have cleared all three bosses", "Use only after checking the full encounter. Refused while living enemies are nearby.", 0)
            if e.finish:get() then command("finish") end
        end
        section(e.setup, "Setup", function()
            e.automatic:render("Automatic party inputs", "Uses game client coordinates in windowed, borderless or fullscreen mode. Resizing pauses inputs until dimensions settle; sent steps are never replayed.")
            e.ui_scale:render("Party UI size (%)", "100 follows automatic viewport scaling. Adjust while stopped if the game's UI size differs, using the target preview. Out-of-bounds controls are refused.")
            e.preview_points:render("Preview party click targets", "While stopped, labels show the predicted control centers without sending input. Turn this off after checking your Social/menu layout.")
            local w, h = party.dimensions()
            render_menu_header(w and string.format("Game viewport: %dx%d | client coordinates | window mode automatic", w, h)
                or "Waiting for readable game viewport dimensions.")
            e.custom_friend:render("Friend", "Required. Your friend's account or character name, typed into the Social search. It must match exactly one friend, and their party must be joinable.", false, "", "")
            local arena = store.arena or data.ARENA
            render_menu_header(pony_mode and "Whimsyshire: live exploration, clouds, chests and breakable containers."
                or "Arena: " .. arena.name .. ". Uses the recorded corridor automatically.")
            render_menu_header(store.message)
            e.social_key:render("Game Social key", "This key is sent to open Social; it does not start or stop the addon.")
            e.continue_key:render("Confirm party step key", "Use a spare key distinct from Stop, Social, Escape, Ctrl+A and characters in the friend search.")
            e.stop_key:render("Stop key", "Stops immediately, including while loading. Use a spare key distinct from Confirm and generated party/search inputs.")
            e.diagnose:render("Log world, bosses and portals", "Print a bounded diagnostic to the host console for improving detection.", 0)
            if e.diagnose:get() then command("diagnose") end
        end)
        section(e.advanced, "Timing and combat", function()
            if pony_mode then
                e.pony_reset_wait:render("Pony reset wait (seconds)", "Wait after collecting drops before joining for the next instance. Separate from Tristram's boss loot cooldown.")
                e.pony_timeout:render("Pony sweep limit (minutes)", "Effective limit is capped at 30 minutes by the explorer. Unfinished sweeps preserve pending pickup and do not count as completed.")
                e.pony_native_town:render("Automatic safe storage without Alfred", "When Alfred service is off, Pony stores unlocked carried gear in Temis and repairs damaged equipment. Nothing is sold or salvaged. Full stash or unconfirmed return stops with a reason.")
                e.pony_stall_seconds:render("Combat progress timeout (seconds)", "Reposition/reselect when neither damage nor approach progress is observed. Deferred enemies remain unfinished work.")
                e.pony_retry_limit:render("Consecutive incomplete run limit", "Back off between incomplete instances; stop at this limit. Only an observed complete sweep resets the failure streak.")
                e.pony_death_limit:render("Deaths per session limit", "Stop repeated death loops. Restarting the farming loop begins a new session.")
                e.pony_attack_slot:render("Fallback attack", { "Rotate equipped skills", "Equipped slot 1", "Equipped slot 2", "Equipped slot 3", "Equipped slot 4", "Equipped slot 5", "Equipped slot 6" }, "Choose a damage skill for reliable standalone combat. An enabled rotation keeps ownership.")
                e.pony_priority:render("Enemy priority", { "Nearest reachable", "Elites first" }, "Unreachable targets are temporarily deferred, never counted dead.")
                e.pony_potion:render("Use potion below 35% health", "Paced native potion use while farming without an enabled rotation; does not replace defensive skill configuration.")
            else e.loot_wait:render("Loot wait (minutes)", "Wait after a kill before the next join/reset. The game locks council loot for about one hour, so 60 is the default (15-120). Reloads begin conservatively.") end
            e.auto_transition:render("Advance party steps on a world transition", "Experimental: a loading/world change does not prove membership or Torment. Off requires your confirmation.")
            if not pony_mode then e.auto_finish:render("Finish after three observed boss deaths", "Only confirmed council deaths count. At the arena, 30 readable empty seconds can retry an incomplete attempt without counting a clear when you have not died or all three councils were observed.") end
            e.step_delay:render("Seconds between party inputs", "Increase for slow UI responses. Transfer Now is sent at most once.", 1)
            e.prompt_delay:render("Wait after Join Party (seconds)", "Allow the transfer prompt to appear before Transfer Now. On first entry, wait before Escape and the party portal.", 1)
            e.settle_delay:render("Wait after loading (seconds)", "Wait for the party menu to disappear before reopening Social or following the path. Applies after joining, entering the portal and leaving.", 1)
            e.timeout:render("Party / teleport timeout (seconds)", "Stops with a reason. Never retries Join or Leave blindly.")
            if not pony_mode then e.clear_timeout:render("Fight timeout (seconds)", "Discards an incomplete attempt and starts a fresh instance without counting a clear. Requires a readable same-instance observation; party clicks are never replayed blindly.") end
            e.town_timeout:render("Alfred town / return timeout (seconds)", "Waits for service completion and the return to the same farming instance. No repeated town requests.")
            e.range:render("Encounter scan range", "Tristram scans around its arena. Pony scans around your current location while exploring.")
            e.fight_range:render("Approach distance", "Move within this distance before combat. Set this for your equipped attack; the generic fallback cannot infer spell range or distinguish attack and support skills.")
            e.loot:render("Pick up host-approved loot", "Uses the host pickup API. If bags fill without town service, clear space manually to resume.")
        end)
    end)
end
function M.render_preview(running)
    if running or not e.preview_points:get() then return end
    local w, h = party.dimensions()
    if not w then return end
    for _, name in ipairs(data.POINTS) do
        local point = party.position(name, w, h, e.ui_scale:get() / 100)
        if point and point.x >= 0 and point.y >= 0 and point.x < w and point.y < h then
            graphics.text_2d("+ " .. name, vec2:new(point.x, point.y), 14, color_white(255))
        end
    end
end
return M
