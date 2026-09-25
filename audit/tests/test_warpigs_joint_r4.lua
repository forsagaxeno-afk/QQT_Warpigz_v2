-- Round-4 WarPigs regressions in the joint host (audit/tests/joint_host.lua:
-- all nine real plugins, one shared _G, per-plugin require caches).
--   F-W2 (round-3 critic regression 2, probe_turnin_alfred2.lua): Horde ->
--        turn-in -> Pit in one Temis visit with 'Use teleport' on runs exactly
--        one WarPigs Alfred cycle (WPT-3 per visit, not the 20 s window).
--   F-W3 (round-3 audit, probe_postaccept_alfred.lua): Alfred live work that
--        starts after accept (the claimed cache filled the bag) no longer
--        cancels the managed Whisper request: the visit ends 'success' with
--        exactly one request.
-- Both fail on d275b9d. Runs under Lua 5.4 and LuaJIT.
local ROOT = assert(SUITE_ROOT, 'SUITE_ROOT is required')
local J = dofile(ROOT .. '/audit/tests/joint_host.lua')
local checks, failures = 0, {}
local function ok(value, message)
    if not value then error(message or 'expected a true value', 2) end
    checks = checks + 1
end
local function eq(actual, expected, message)
    if actual ~= expected then
        error((message or 'mismatch') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual), 2)
    end
    checks = checks + 1
end
local function case(name, fn)
    local passed, err = xpcall(fn, debug.traceback)
    if not passed then failures[#failures + 1] = name .. ': ' .. tostring(err) end
end

local WP, PUG, SR = 'WarPigs-1.0.0', 'WarPug-1.0.0', 'SilentRaven-0.1.3'
local function el(h, dir) return assert(h.mod(dir, dir == SR and 'silent_raven.gui' or 'gui'), dir).elements end
local function setup(opts)
    local h = J.new(opts)
    h.assert_clean('load')
    h.instrument_exports()
    el(h, WP).main_toggle:set(true); el(h, PUG).main_toggle:set(true); el(h, SR).main_toggle:set(true)
    if opts.teleport then el(h, WP).use_teleport_transition:set(true) end
    if opts.quests then h.set_quests(opts.quests) end
    return h
end
local function enabled(h, export)
    local api = h.G[export]
    local fn = api.status or api.get_status
    return h.as(WP, function() return fn() end).enabled == true
end

case('F-W2 Horde -> turn-in -> Pit in one Temis visit (Use teleport on): one WarPigs Alfred cycle', function()
    for _, sticky in ipairs({false, true}) do
        local label = sticky and 'sticky restock flag' or 'no Alfred need'
        local h = setup({place = 'bsk', quests = {'WarPlans_QST_InfernalHordes_BSK'}, teleport = true})
        if sticky then h.alfred.need_trigger, h.alfred.sticky_need, h.alfred.restock_count = true, true, 2 end
        h.bounty_ready = true
        h.run(15)
        h.set_quests({'WarPlans_QST_TurnIn_Rewards'})
        h.run(5)
        h.travel_to('caldeum', 0.5, 'leave')   -- HordeDev's exit lands at the gate
        h.pos = nil
        ok(h.run_until(function() return not enabled(h, 'InfernalHordesPlugin') end, 10), label .. ': HordeDev released')
        local t0 = h.now
        h.on_confirm = function() h.at(1.0, function() h.set_quests({'WarPlans_QST_ThePit'}) end) end
        ok(h.run_until(function() return enabled(h, 'ArkhamAsylumPlugin') end, 180), label .. ': Arkham enabled\n' .. h.tail())
        local elapsed = h.now - t0
        eq(h.board.confirmed, 1, label .. ': one plan')
        eq(h.logged('teleport queued — turn-in finished'), 1, label .. ': R6 re-armed the transition')
        eq(h.count(h.alfred.triggers, function(t) return t.t >= t0 and t.context == WP end), 1,
            label .. ': one WarPigs Alfred cycle in the Temis visit (d275b9d: 2)')
        eq(h.count(h.alfred.triggers, function(t) return t.t >= t0 end), 1, label .. ': one Alfred cycle in total')
        ok(h.logged('Alfred already serviced this visit') == 1, label .. ': the R6 preamble joins the visit\'s cycle')
        -- d275b9d: +50.1 s; 86340d4 (no R6 re-arm): +36.9 s. The remaining
        -- ~3 s over 86340d4 is R6's incoming settle before the Pit check.
        ok(elapsed <= 42, string.format('%s: Arkham enabled %.1fs after the Horde release', label, elapsed))
        eq(h.place, h.P.temis, label .. ': Pit tower in Temis, no warplan teleport needed')
        h.assert_clean(label)
    end
end)

case('F-W3 Alfred live work after accept: the claimed Whisper is verified, not cancelled or re-requested', function()
    local h = setup({})
    h.bounty_ready = true
    local accept_at
    ok(h.run_until(function()
        local st = h.G.SilentRavenPlugin.get_status()
        if st.state == 'API_CLAIMING' and not accept_at then
            accept_at = h.now
            -- The claimed cache fills the bag: Alfred starts on its own.
            h.alfred.trigger_tasks, h.alfred.running, h.alfred.inventory_full = true, true, true
            h.at(4.0, function() h.alfred.trigger_tasks, h.alfred.running, h.alfred.inventory_full = false, false, false end)
        end
        return h.logged('[WarPug] state IDLE -> APPROACH_TABLE') > 0
    end, 120), 'WarPug started planning\n' .. h.tail())
    h.assert_clean('post-accept alfred')
    ok(accept_at ~= nil, 'the claim reached accept')
    eq(h.reward_accepts, 1, 'one reward accepted')
    eq(h.logged('checking completed Whispers in Temis'), 1, 'one managed request in the visit (d275b9d: 2)')
    eq(h.logged('retrying when companions are clear'), 0, 'no re-request of a claimed reward')
    eq(h.logged('run finished: success'), 1, 'SilentRaven verified the claim')
    eq(h.logged('visit 1: success'), 1, 'WarPigs reports the claim')
    eq(h.logged('run finished: cancelled'), 0, 'never cancelled')
end)

if #failures > 0 then error(#failures .. ' WarPigs round-4 joint regressions failed:\n' .. table.concat(failures, '\n\n')) end
print('PASS WarPigs round-4 joint regressions: ' .. checks .. ' checks')
