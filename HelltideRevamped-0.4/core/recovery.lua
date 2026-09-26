-- One revival owner across farming/search task changes.
local M = {}
local next_revive_time = -math.huge

function M.revive_if_dead(player)
    if not player then return true end
    if not player:is_dead() then
        next_revive_time = -math.huge
        return false
    end
    local now = get_time_since_inject()
    if now >= next_revive_time then
        next_revive_time = now + 1
        revive_at_checkpoint()
    end
    return true
end

return M
