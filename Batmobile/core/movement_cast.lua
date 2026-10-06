-- Enigma is a bound input action, not a native spell ID. Keep the sentinel
-- inside Batmobile; never pass it to can_cast_spell or cast_spell.position.
local M = { ENIGMA = -1, enigma_interval = 0.25 }
local last_click

local function finite(n)
    return type(n)=='number' and n==n and n~=math.huge and n~=-math.huge
end

function M.enigma_ready()
    if not utility or type(utility.send_mouse_middle_click)~='function'
        or not graphics or type(graphics.w2s)~='function' then return false end
    local ok,ready=pcall(function()
        local player=get_local_player()
        if not player or player:is_dead() then return false end
        if is_chat_open() or is_inventory_open() then return false end
        if loot_manager and type(loot_manager.is_in_vendor_screen)=='function'
            and loot_manager.is_in_vendor_screen() then return false end
        local now=get_time_since_inject()
        return finite(now) and (not last_click or now<last_click
            or now-last_click>=M.enigma_interval)
    end)
    return ok and ready==true
end

function M.position(skill_id, destination, delay)
    if skill_id~=M.ENIGMA then return cast_spell.position(skill_id,destination,delay) end
    if not destination or not M.enigma_ready() then return false end
    -- QQT_Warpigz_v3 2.2.7: every attempt that reaches the projection arms
    -- the throttle. A refused click (node off-screen, w2s nil/NaN) left it
    -- unarmed, so enigma_ready() stayed true and the legacy selector picked
    -- Enigma on every tick: class movement spells never fired.
    last_click=get_time_since_inject()
    local ok,x,y=pcall(function()
        local screen=graphics.w2s(destination)
        if not screen then return end
        return screen.x,screen.y
    end)
    if not ok or not finite(x) or not finite(y) then return false end
    local dimensions,w,h=pcall(function() return get_screen_width(),get_screen_height() end)
    if not dimensions or not finite(w) or not finite(h)
        or x<=0 or y<=0 or x>=w or y>=h then return false end
    -- API returns nil on dispatch. A click is not proof of a teleport;
    -- navigator keeps its route until the player's position actually changes.
    local sent,result=pcall(utility.send_mouse_middle_click,math.floor(x),math.floor(y))
    return sent and result~=false
end

return M
