-- QQT_Warpigz_v3: Farm-mode cinder plan (pure functions, no host calls).
--
-- Keep 250 cinders for a known Mystery chest (Tortured Gift of Mysteries)
-- that can still be reached before the Helltide ends, counting what the
-- farm is expected to earn until then; never carry a big pile past chests;
-- spend everything in the last minutes.
-- QQT_Warpigz_v3 (night review): the expected income is counted only until
-- the "spend everything" window opens (the reserve is due before it), and
-- with 250 in hand and a reachable Mystery known, a regular chest that would
-- take the balance below 250 is refused (Mystery first; want_mystery).
--
-- ctx = {cinders, rate_min, minutes_left, mystery_known (reachable Mystery
--        chests), farm_mode, plan_on, max_carry, dump_min}
-- Outside Farm mode, or with the plan off, a chest is allowed as soon as it
-- is affordable (the legacy behaviour; Warplan / WarPigs always).
local M = {
    MYSTERY_COST = 250,     -- enums.chest_types.usz_rewardGizmo_Uber
    SPEED = 6,              -- m/s used for "reachable in the time left"
    REACH_SHARE = 0.8,      -- share of the time left a trip may take
    INCOME_SHARE = 0.8,     -- share of the expected income counted on
    DEFAULT_MAX_CARRY = 150,
    DEFAULT_DUMP_MIN = 5,
}

local function num(v, default)
    v = tonumber(v)
    if v == nil or v ~= v then return default end
    return v
end

function M.reserve(ctx)
    return num(ctx and ctx.mystery_known, 0) > 0 and M.MYSTERY_COST or 0
end

-- Cinders expected before the reserve is due: until the "spend everything"
-- window opens (dump_min), less one minute for the trip. Counting income up
-- to the last minute kept the balance just under 250 all hour, and the dump
-- window then spent it on regular chests (QQT_Warpigz_v3).
function M.expected(ctx)
    local rate = math.max(0, num(ctx and ctx.rate_min, 0))
    local dump = math.max(0, num(ctx and ctx.dump_min, M.DEFAULT_DUMP_MIN))
    local left = math.max(0, num(ctx and ctx.minutes_left, 0) - dump - 1)
    return rate * left * M.INCOME_SHARE
end

-- A trip of `road_m` metres fits in the time left.
function M.reachable(road_m, minutes_left)
    road_m, minutes_left = num(road_m, math.huge), num(minutes_left, 0)
    return road_m / M.SPEED <= minutes_left * 60 * M.REACH_SHARE
end

-- Go for a Mystery chest now: enough cinders and one is known and reachable.
function M.want_mystery(ctx)
    ctx = ctx or {}
    return num(ctx.cinders, 0) >= M.MYSTERY_COST and num(ctx.mystery_known, 0) > 0
end

-- allow(cost, ctx, is_mystery) -> ok, reason
function M.allow(cost, ctx, is_mystery)
    ctx = ctx or {}
    local cinders = num(ctx.cinders, 0)
    cost = num(cost, math.huge)
    if cinders < cost then return false, 'not affordable' end
    if not (ctx.farm_mode and ctx.plan_on) then return true, 'affordable' end
    if is_mystery or cost >= M.MYSTERY_COST then return true, 'Mystery' end
    local reserve = M.reserve(ctx)
    local left_after = cinders - cost
    if left_after >= reserve then return true, reserve > 0 and 'reserve kept' or 'affordable' end
    if cinders >= reserve + math.max(0, num(ctx.max_carry, M.DEFAULT_MAX_CARRY)) then
        return true, 'carrying too many'
    end
    -- QQT_Warpigz_v3: 250 in hand and a reachable Mystery known: the Mystery
    -- first (no income or dump rule may spend its cinders on the way).
    if M.want_mystery(ctx) then return false, 'Mystery chest first (250 in hand)' end
    if left_after + M.expected(ctx) >= reserve then return true, 'income refills the reserve' end
    if num(ctx.minutes_left, 0) <= math.max(0, num(ctx.dump_min, M.DEFAULT_DUMP_MIN)) then
        return true, 'last minutes: spend everything'
    end
    return false, 'saving 250 for a Mystery chest'
end

return M
