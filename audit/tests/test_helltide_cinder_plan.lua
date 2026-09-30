-- QQT_Warpigz_v3: Farm-mode cinder plan (core/hr_cinder_plan.lua), table
-- driven, plus the reachability rule as the chest order applies it.
-- Runs under Lua 5.4 and LuaJIT.
local H = dofile(assert(SUITE_ROOT, 'SUITE_ROOT is required') .. '/audit/tests/hr_smart_harness.lua')
local R = H.runner('Helltide cinder plan')
local ok, eq = R.ok, R.eq

local function ctx(t)
    local c = {cinders = 0, rate_min = 0, minutes_left = 20, mystery_known = 0, farm_mode = true, plan_on = true,
        max_carry = 150, dump_min = 5}
    for k, v in pairs(t or {}) do c[k] = v end
    return c
end

-- {case, cost, is_mystery, ctx fields, allowed, reason fragment}
local ROWS = {
    {'Warplan: affordable is enough', 75, false, {cinders = 260, mystery_known = 1, farm_mode = false}, true, 'affordable'},
    {'plan off: affordable is enough', 75, false, {cinders = 260, mystery_known = 1, plan_on = false}, true, 'affordable'},
    {'not affordable', 150, false, {cinders = 149}, false, 'not affordable'},
    {'no Mystery known: no reserve', 75, false, {cinders = 80}, true, 'affordable'},
    {'reserve with a Mystery known, no income', 75, false, {cinders = 240, mystery_known = 1}, false, 'saving 250'},
    {'reserve kept', 75, false, {cinders = 325, mystery_known = 1}, true, 'reserve kept'},
    {'expected income refills the reserve', 75, false, {cinders = 240, mystery_known = 1, rate_min = 10}, true, 'income'},
    {'income too small', 75, false, {cinders = 240, mystery_known = 1, rate_min = 1}, false, 'saving 250'},
    {'income only until the wave ends', 75, false, {cinders = 240, mystery_known = 1, rate_min = 10, minutes_left = 1.5, dump_min = 0},
        false, 'saving 250'},
    -- QQT_Warpigz_v3 (night review): income only until the dump window opens.
    {'income only until the dump window', 75, false, {cinders = 240, mystery_known = 1, rate_min = 10, minutes_left = 9},
        false, 'saving 250'},
    -- QQT_Warpigz_v3 (night review): 250 in hand + a reachable Mystery: Mystery first.
    {'250 in hand: no regular chest below the reserve (income)', 75, false,
        {cinders = 300, mystery_known = 1, rate_min = 30}, false, 'Mystery chest first'},
    {'250 in hand: no regular chest below the reserve (dump window)', 75, false,
        {cinders = 260, mystery_known = 1, minutes_left = 4}, false, 'Mystery chest first'},
    {'carrying 600 past a regular chest: allowed', 150, false, {cinders = 600, mystery_known = 1}, true, 'reserve kept'},
    {'carry cap above the reserve (max carry 0)', 75, false, {cinders = 260, mystery_known = 1, max_carry = 0}, true, 'carrying'},
    {'dump window: spend everything', 75, false, {cinders = 240, mystery_known = 1, minutes_left = 4}, true, 'last minutes'},
    {'dump window off (0 min) keeps saving', 75, false, {cinders = 240, mystery_known = 1, minutes_left = 4, dump_min = 0},
        false, 'saving 250'},
    {'Mystery with 250', 250, true, {cinders = 250, mystery_known = 1}, true, 'Mystery'},
    {'Mystery with 249', 250, true, {cinders = 249, mystery_known = 1}, false, 'not affordable'},
}

R.case('allow() table', function()
    local s = H.new()
    local plan = s.require('core.hr_cinder_plan')
    for _, row in ipairs(ROWS) do
        local allowed, why = plan.allow(row[2], ctx(row[4]), row[3])
        eq(allowed, row[5], row[1] .. ' (' .. tostring(why) .. ')')
        ok(tostring(why):find(row[6], 1, true) ~= nil, row[1] .. ': reason ' .. tostring(why))
    end
end)

R.case('reserve, expected income, reachability and want_mystery', function()
    local s = H.new()
    local plan = s.require('core.hr_cinder_plan')
    eq(plan.reserve(ctx({mystery_known = 2})), 250)
    eq(plan.reserve(ctx({mystery_known = 0})), 0)
    eq(plan.expected(ctx({rate_min = 10, minutes_left = 20})), 10 * 14 * 0.8, 'until the dump window (5 min) less 1')
    eq(plan.expected(ctx({rate_min = 10, minutes_left = 20, dump_min = 0})), 10 * 19 * 0.8)
    eq(plan.expected(ctx({rate_min = 10, minutes_left = 5})), 0)
    eq(plan.expected(ctx({rate_min = -5, minutes_left = 20})), 0, 'no negative income')
    eq(plan.reachable(2000, 20), true, '2 km in 20 min')
    eq(plan.reachable(2000, 5), false, '2 km in 5 min at 6 m/s (80 %)')
    eq(plan.want_mystery(ctx({cinders = 250, mystery_known = 1})), true)
    eq(plan.want_mystery(ctx({cinders = 250, mystery_known = 0})), false)
    eq(plan.want_mystery(ctx({cinders = 200, mystery_known = 1})), false)
end)

-- The chest order counts a Mystery for the reserve only when it can still be
-- reached before the Helltide ends.
local function order_session()
    local s = H.new({cinders = 300})
    s.set('mode', 1)
    s.set('farm_goal', false) -- QQT_Warpigz_v3: goal off (the pre-goal smart order + cinder plan path)
    local order = s.require('core.hr_chest_order')
    s.require('core.hr_fence'); s.require('core.hr_roads')
    local targets = s.require('core.chest_targets')
    return s, order, targets
end

R.case('a Mystery that cannot be reached in the time left gives no reserve', function()
    local s, order, targets = order_session()
    local mystery = H.actor('usz_rewardGizmo_Uber', 140, 0, {interactable = true})
    local regular = H.actor('usz_rewardGizmo_Gloves', 30, 0)
    local remembered = {}
    local function pick()
        return order.pick({actors = {mystery, regular}, remembered = remembered, key_of = targets.key,
            player = s.pos, cinders = s.cinders, now = s.now})
    end
    s.set('dump_min', 0) -- no "spend everything" window: only the reserve decides
    s.cinders = 200 -- the Mystery is not affordable yet
    s.at_minute(10)
    local chosen = pick()
    eq(chosen, nil, 'saving: 200 - 75 < 250 and no income yet')
    eq(order.last_plan.reserve, 250, 'reserve for the reachable Mystery')
    s.at_minute(54, 45)         -- 15 s left: 140 m at 6 m/s does not fit
    chosen = pick()
    ok(chosen ~= nil and chosen.name == 'usz_rewardGizmo_Gloves', 'regular chest allowed without a reachable Mystery')
    eq(order.last_plan.reserve, 0)
end)

-- QQT_Warpigz_v3 (night review): played through a whole Helltide, the income
-- rule kept the balance just under 250 until the dump window spent it on
-- regular chests: no Mystery all hour at 12-30 cinders/min.
R.case('a whole Helltide with a Mystery known all hour opens at least one Mystery', function()
    local s = H.new()
    local plan = s.require('core.hr_cinder_plan')
    for _, rate in ipairs({8, 12, 20, 25, 30}) do
        for _, every in ipairs({0.25, 1, 3}) do
            local c, t, myst, reg, next_reg = 0, 0, 0, 0, 0
            while t < 55 - 1e-9 do
                t = t + 0.25
                c = c + rate * 0.25
                local cx = {cinders = c, rate_min = rate, minutes_left = 55 - t, mystery_known = 1,
                    farm_mode = true, plan_on = true, max_carry = 150, dump_min = 5}
                if c >= 250 then
                    c = c - 250; myst = myst + 1
                elseif c >= 75 and t >= next_reg and plan.allow(75, cx, false) then
                    c = c - 75; reg = reg + 1; next_reg = t + every
                end
            end
            ok(myst >= 1, string.format('rate %d/min, a chest every %.2f min: Mystery %d, regular %d', rate, every, myst, reg))
        end
    end
end)

R.finish()
