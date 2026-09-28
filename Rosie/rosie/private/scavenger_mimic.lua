-- QQT_Warpigz_v3 1.0.22: Rosie acts as Scavenger (Navigator's own looter,
-- closed .pak) when no Scavenger addon is installed. Worldstone polls
-- Scavenger.is_busy() and pauses Navigator ("Worldstone Looting"); without a
-- Scavenger nothing held Navigator while Rosie walked to a drop, the two
-- movers took turns on the path and Rosie yielded the drop
-- (docs/THIRD_PARTY_APIS.md). Rules:
--  * _G.Scavenger (marked _rosie=true) is published only while Navigator is
--    loaded (GRACE s after Rosie first saw it: Scavenger loads with it), no
--    other Scavenger is present and the pickup option is on. A real Scavenger
--    that loads later wins and is never overwritten; option off removes only
--    Rosie's own table. A reloaded Rosie replaces its own old table at once.
--  * Navigator is also held through Rosie's own pause condition CONDITION
--    (distinct from the trip condition "Rosie"), once per Navigator table.
--  * is_busy: pickup worked a wanted drop (Pickup.step true) within DEBOUNCE s.
--    Never for the fight hold's busy-without-moving, a paused, disabled or
--    retired Rosie, the option off, a dead player, a loading screen or a town
--    trip (the trip holds Navigator itself). C6: one busy episode ends after
--    CAP s without a drop taken or leaving the ground (Pickup.progress_at) or
--    CEILING s in all (the debounce counts inside both), then false for COOL
--    s, logged once per episode, so Navigator/Worldstone never freeze on
--    Rosie's account. QQT_Warpigz_v3 1.0.22 (review): progress restarts the
--    CAP clock (a big pile was cut off after CAP s), and in the cool-down
--    pickup walks to no drop (Pickup.walk_hold, like the fight hold), so
--    Navigator gets the path back without a tug of war. The episode is
--    counted only while Navigator is loaded and the option is on.
--  * Every entry point is pcall-guarded, never raises and never requires.
local Settings=require('rosie.private.pickup.src.settings')
local ItemManager=require('rosie.private.pickup.src.item_manager')
local Pickup=require('rosie.private.pickup.src.pickup')
local Utils=require('rosie.private.pickup.utils.utils')
local M={NAME='Scavenger',CONDITION='Rosie Looting',DEBOUNCE=1,CAP=20,CEILING=60,COOL=5,GRACE=3,WANTED_TTL=0.25}
local cfg={} -- alive, enabled, town_busy, option, version: functions; acquire/release: the Looter pause
local B={start=nil,since=nil,last=nil,cool_until=nil} -- since: the episode start or its last pickup
local S={nav_seen=nil,cond_nav=nil,published=false,wanted_at=nil,wanted={}}
local logged={}
local function log_once(key,text)
    if logged[key] then return end
    logged[key]=true
    console.print('[Rosie] '..text)
end
local function now_s()
    local ok,t=pcall(get_time_since_inject)
    return ok and type(t)=='number' and t or 0
end
local function on(name)
    local f=cfg[name]
    if type(f)~='function' then return false end
    local ok,v=pcall(f)
    return ok and v==true
end
function M.configure(o) for k,v in pairs(o) do cfg[k]=v end end
-- Why is_busy is false whatever pickup did (nil: nothing blocks it).
local function blocked()
    if not on('alive') then return 'retired' end
    if not on('option') then return 'off' end
    if not on('enabled') then return 'disabled' end
    if on('town_busy') then return 'town' end
    if Settings.is_paused() then return 'paused' end
    local player=Utils.host_call(rawget(_G,'get_local_player'))
    if not player or Utils.call(player,'is_dead')~=false then return 'dead' end
    local zone=Utils.call(Utils.host_call(rawget(_G,'get_current_world')),'get_current_zone_name')
    if type(zone)~='string' or zone=='[sno none]' then return 'loading' end
    return nil
end
-- The busy episode (see the header); true while it may report busy.
local function refresh(now)
    if not B.last or now<B.last or now-B.last>M.DEBOUNCE then B.start,B.since=nil,nil;return false end
    if B.cool_until then
        if now<B.cool_until and now>=B.cool_until-M.COOL then return false end
        B.cool_until,B.start=nil,nil -- cool-down over: a new episode
    end
    if not B.start or now<B.start then B.start,B.since=now,now end
    local p=Pickup.progress_at -- QQT_Warpigz_v3 1.0.22 (review): a drop taken restarts the CAP clock
    if type(p)=='number' and p>B.since and p<=now then B.since=p end
    local stalled=now-B.since>=M.CAP
    if not stalled and now-B.start<M.CEILING then return true end
    B.cool_until,B.start,B.since=now+M.COOL,nil,nil
    console.print(string.format('[Rosie] Busy as Scavenger for %ds %s; Navigator/Worldstone get the path back for %ds',
        stalled and M.CAP or M.CEILING,stalled and 'without a pickup' or 'in one go',M.COOL))
    return false
end
-- QQT_Warpigz_v3 1.0.22 (review): something reads is_busy (see the header).
local function in_effect() return on('option') and on('alive') and type(rawget(_G,'Navigator'))=='table' end
-- Pickup worked a wanted drop this pulse (Pickup.step returned true).
function M.note_work(now)
    if not in_effect() then return end
    if B.last and (now<B.last or now-B.last>M.DEBOUNCE) then B.start,B.since=nil,nil end
    B.last=now
    refresh(now)
end
-- QQT_Warpigz_v3 1.0.22 (review): the cool-down after a cap; pickup walks to
-- no drop meanwhile (pickup.lua fight_deferred), drops in reach are still taken.
local function cooling(now)
    local c=B.cool_until
    return c~=nil and now<c and now>=c-M.COOL and on('option') and on('alive')
end
Pickup.walk_hold=function(now)
    local ok,hold=pcall(cooling,now)
    return ok and hold==true
end
local function busy_now()
    local busy=refresh(now_s())
    return busy and blocked()==nil
end
function M.is_busy()
    local ok,busy=pcall(busy_now)
    return ok and busy==true
end
local function condition() return M.is_busy() end
-- Pause keyed by the caller (Looter acquire_pause: 60 s TTL for foreign owners).
-- 'Rosie' is Rosie's own town-trip pause and keeps that name to itself.
local function caller_of(caller)
    if type(caller)~='string' or caller=='' then return 'Scavenger-caller' end
    return caller=='Rosie' and 'Scavenger-caller:Rosie' or caller
end
local function pause_call(key,caller)
    if not on('alive') or type(cfg[key])~='function' then return false end
    local ok,result=pcall(cfg[key],caller_of(caller))
    return ok and result==true
end
function M.pause(caller) return pause_call('acquire',caller) end
function M.resume(caller) return pause_call('release',caller) end
-- QQT_Warpigz_v3 1.0.22 (review): one version source (the controller's s.version).
local function version()
    local f=cfg.version
    if type(f)~='function' then return nil end
    local ok,v=pcall(f)
    return ok and type(v)=='string' and v or nil
end
local function status()
    local enabled=on('alive') and on('enabled')
    local paused=Settings.is_paused()==true
    local busy=M.is_busy()
    local state=not enabled and 'disabled' or paused and 'paused' or busy and 'looting' or 'idle'
    local message=({disabled='Rosie pickup is off.',paused='Rosie pickup is paused.',
        looting='Rosie is picking up a drop.',idle='Rosie is waiting for a wanted drop.'})[state]
    return {name='Rosie',owner='Rosie',version=version(),mimic=true,is_busy=busy,is_paused=paused,
        is_enabled=enabled,state=state,message=message}
end
function M.get_status()
    local ok,s=pcall(status)
    if ok and type(s)=='table' then return s end
    return {name='Rosie',owner='Rosie',version=version(),mimic=true,is_busy=false,is_paused=false,
        is_enabled=false,state='disabled',message='Rosie status unavailable.'}
end
-- Ground items Rosie wants now (in pickup distance, not settled, resting or
-- exhausted); read at most every WANTED_TTL s; a copy for the caller.
local function wanted_now()
    if not (on('alive') and on('enabled') and on('option')) then S.wanted_at=nil;return {} end
    local now=now_s()
    if S.wanted_at and now>=S.wanted_at and now-S.wanted_at<M.WANTED_TTL then return S.wanted end
    local out={}
    local am=rawget(_G,'actors_manager')
    local items=type(am)=='table' and Utils.host_call(am.get_all_items)
    for _,item in pairs(type(items)=='table' and items or {}) do
        local ok,want=pcall(ItemManager.check_want_item,item,false)
        if ok and want==true and not Pickup.blocked(item) then out[#out+1]=item end
    end
    S.wanted_at,S.wanted=now,out
    return out
end
function M.get_wanted_items()
    local ok,list=pcall(wanted_now)
    local copy={}
    if ok and type(list)=='table' then for i,item in ipairs(list) do copy[i]=item end end
    return copy
end
M.shim={_rosie=true,mimic=true,name='Rosie',
    is_busy=M.is_busy,pause=M.pause,resume=M.resume,get_status=M.get_status,get_wanted_items=M.get_wanted_items}
-- Once per Navigator table; a reloaded Rosie registers the same name again.
local function register(nav)
    if S.cond_nav==nav or type(nav.set_pause_condition)~='function' then return end
    S.cond_nav=nav
    local ok,why=pcall(nav.set_pause_condition,M.CONDITION,condition)
    if ok then log_once('cond','Navigator waits while Rosie picks up a drop (pause condition "'..M.CONDITION..'")')
    else log_once('cond_err','Navigator.set_pause_condition failed: '..tostring(why)) end
end
local function tick()
    local now=now_s()
    local nav=rawget(_G,'Navigator')
    if type(nav)~='table' then nav=nil end
    if not nav then S.nav_seen=nil elseif not S.nav_seen or now<S.nav_seen then S.nav_seen=now end
    local allowed=on('option') and on('alive')
    if allowed and nav then register(nav) end
    local cur=rawget(_G,M.NAME)
    local own=type(cur)=='table' and rawget(cur,'_rosie')==true
    if cur~=nil and not own then -- a real Scavenger: never overwritten
        if S.published then
            S.published=false
            log_once('real','A Scavenger addon is loaded: Rosie stops acting as Scavenger and yields to it')
        end
        return
    end
    if allowed and nav and (own or now-S.nav_seen>=M.GRACE) then
        if cur~=M.shim then
            _G[M.NAME]=M.shim
            log_once('pub','Acting as Scavenger for Worldstone/Navigator (no Scavenger installed)')
        end
        S.published=true
    elseif own then
        _G[M.NAME]=nil
        S.published=false
    end
end
-- Publishes / removes the table and registers the condition (every update).
function M.tick()
    local ok,why=pcall(tick)
    if not ok then log_once('tick_err','Scavenger mimic error: '..tostring(why)) end
    return ok
end
return M
