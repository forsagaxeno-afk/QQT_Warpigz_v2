-- QQT_Warpigz_v3 Rosie 1.0.21: third-party peers that ship as closed .pak
-- files (Navigator, Scavenger, Butler). Every name below was observed with
-- tools/ApiProbe (docs/THIRD_PARTY_APIS.md); every call is guarded by a
-- type check and a pcall, and an absent peer is a no-op.
local M={}
local LABEL='Rosie'
local logged={}
local function log_once(key,text)
    if logged[key] then return end
    logged[key]=true
    console.print('[Rosie] '..text)
end
local function peer(name)
    local t=rawget(_G,name)
    return type(t)=='table' and t or nil
end
-- ok, value of t[fn](...) or false when the function is absent or raised.
local function call(t,fn,...)
    if not t or type(t[fn])~='function' then return false,'missing' end
    return pcall(t[fn],...)
end
M.call=call

-- QQT_Warpigz_v3 1.0.23: the Scavenger addon, never Rosie's own Scavenger
-- table (scavenger_mimic.lua, _rosie=true): yielding to it would be yielding
-- to itself (busy -> reset -> not busy -> oscillation).
local function real_scavenger()
    local t=peer('Scavenger')
    if t and rawget(t,'_rosie')~=true then return t end
    return nil
end
M.real_scavenger=real_scavenger
-- Navigator's looter owns the drops while it is busy (pickup yields).
function M.scavenger_busy()
    local ok,busy=call(real_scavenger(),'is_busy')
    return ok and busy==true
end
-- QQT_Warpigz_v3 1.0.32 (Coordinator review of 1.0.31): the Butler addon,
-- never Rosie's own stand-in (butler_mimic.lua, _rosie=true): during her own
-- trip get_status().foreign_busy read 'Butler' (her own trip as a third-party one).
local function real_butler()
    local t=peer('Butler')
    if t and rawget(t,'_rosie')~=true then return t end
    return nil
end
M.real_butler=real_butler
-- Butler (another town service): Rosie never starts a trip while it runs one.
function M.butler_busy()
    local ok,busy=call(real_butler(),'is_busy')
    return ok and busy==true
end
function M.navigator_status()
    local ok,st=call(peer('Navigator'),'get_status')
    return ok and type(st)=='table' and st or nil
end

-- Navigator stops for the whole trip through its pause condition
-- (set_pause_condition(name, fn), seen: Worldstone registers one). Registered
-- once per Navigator table; `active` says whether a Rosie trip is in progress.
-- Without it, pause(label)/resume(label) are the fallback (arguments not
-- captured, so only a pause Rosie observed taking effect is resumed).
local registered=nil
function M.navigator_hold(active)
    local nav=peer('Navigator')
    if not nav then return false end
    if type(nav.set_pause_condition)=='function' then
        if registered~=nav then
            local ok,why=pcall(nav.set_pause_condition,LABEL,function()
                local ok2,on=pcall(active)
                return ok2 and on==true
            end)
            if not ok then log_once('nav_cond_err','Navigator.set_pause_condition failed: '..tostring(why)); return false end
            registered=nav
            log_once('nav_cond','Navigator is held during town trips (pause condition "'..LABEL..'")')
        end
        return 'condition'
    end
    local ok_p,paused=call(nav,'is_paused')
    if ok_p and paused==true then return false end -- someone else's pause: never resumed by Rosie
    local ok=call(nav,'pause',LABEL)
    if not ok then return false end
    local ok_a,after=call(nav,'is_paused')
    log_once('nav_pause','Navigator is held during town trips (Navigator.pause)')
    return (ok_a and after==true or not ok_a) and 'pause' or false
end
function M.navigator_release(how)
    if how=='pause' then call(peer('Navigator'),'resume',LABEL) end
end

-- During the Town Portal cast: a Navigator request that still moves the
-- player (Worldstone re-issues navigate() on its own) is stopped, at most once
-- per STOP_GAP s and STOP_MAX times per trip.
M.STOP_GAP,M.STOP_MAX=1,30
local stops={trip=nil,n=0,at=-math.huge}
function M.quiet_navigator(trip)
    if stops.trip~=trip then stops.trip,stops.n,stops.at=trip,0,-math.huge end
    local st=M.navigator_status()
    if not st or st.is_busy~=true or st.is_paused==true or st.owner==LABEL then return false end
    local now=get_time_since_inject()
    if stops.n>=M.STOP_MAX or now-stops.at<M.STOP_GAP then return false end
    local ok=call(peer('Navigator'),'stop')
    if not ok then return false end
    stops.n,stops.at=stops.n+1,now
    if stops.n==1 then
        console.print('[Rosie] Navigator request of '..tostring(st.owner or '?')..' stopped for the Town Portal cast')
    end
    return true
end

function M.scavenger_hold()
    local sc=real_scavenger()
    if not sc then return 'mimic' end -- QQT_Warpigz_v3 1.0.23: Rosie's own table: nothing to pause
    local ok=call(sc,'pause',LABEL)
    if ok then log_once('scav','Scavenger is paused during town trips') end
    return ok
end
function M.scavenger_release() call(real_scavenger(),'resume',LABEL) end -- QQT_Warpigz_v3 1.0.23: never Rosie's own table

return M
