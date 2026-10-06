-- One revival owner across farming/search task changes.
local tracker = require "core.tracker" -- QQT_Warpigz_v3
local M = {}
local next_revive_time = -math.huge
local dead_seen = false -- QQT_Warpigz_v3: alive -> dead edge for the stats

function M.revive_if_dead(player)
    if not player then return true end
    if not player:is_dead() then
        next_revive_time = -math.huge
        dead_seen = false
        return false
    end
    if not dead_seen then
        dead_seen = true
        local stats = tracker.hr_stats
        if stats and stats.on_death then pcall(stats.on_death) end
    end
    local now = get_time_since_inject()
    if now >= next_revive_time then
        next_revive_time = now + 1
        revive_at_checkpoint()
    end
    return true
end

return M
