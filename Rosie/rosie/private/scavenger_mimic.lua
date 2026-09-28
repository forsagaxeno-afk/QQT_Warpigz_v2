-- QQT_Warpigz_v3 1.0.23: Rosie acts as Scavenger (Navigator's own looter,
-- closed .pak) when no Scavenger addon is installed. Worldstone polls
-- Scavenger.is_busy() and pauses Navigator ("Worldstone Looting"); without a
-- Scavenger nothing held Navigator while Rosie walked to a drop, the two
-- movers took turns on the path and Rosie yielded the drop
-- (docs/THIRD_PARTY_APIS.md). Rules:
--  * QQT_Warpigz_v3 1.0.23 (owner): on only while Worldstone runs. In effect
--    (in_effect) = the table is published, the pickup option is on, this
--    Rosie is alive, _G.Worldstone is a table and no real Scavenger owns the
--    global, read on every call. Out of effect everything below is inert (no
--    table, condition false, no busy episode, cap log or walk hold): without
--    Worldstone Rosie behaves exactly like 1.0.21. Only the global is read: a
--    Worldstone switched off in its own menu may keep it (unconfirmed live;
--    tools/ApiProbe logs Worldstone.get_status() for a running flag).
--  * _G.Scavenger (marked _rosie=true) is published GRACE s after Rosie first
--    saw Worldstone (or Navigator, whichever is later: a real Scavenger loads
--    with Navigator). A real Scavenger is never overwritten. Out of effect
--    (option off, Worldstone gone, a real Scavenger, a conflict, retire) only
--    Rosie's own table is removed and every pause taken through it released.
--    A reloaded Rosie replaces its own table at once (retire hands off).
--  * Navigator is also held through Rosie's own pause condition CONDITION
--    (distinct from the trip condition "Rosie"), registered once per Navigator
--    table while published. There is no known unregister: it answers is_busy,
--    so it is false out of effect.
--  * is_busy: pickup worked a wanted drop (Pickup.step true) within DEBOUNCE s.
--    Never for the fight hold's busy-without-moving (the transitional
--    Pickup.fight_wait_busy of pickup/main.lua included; a drop at the feet is
--    worked in a fight: busy for that moment), a paused, disabled or retired
--    Rosie, the option off, a dead player, a loading screen or a town trip
--    (the trip holds Navigator itself). C6: one busy episode ends after CAP s
--    without a drop taken or leaving the ground (Pickup.progress_at) or
--    CEILING s in all (the debounce counts inside both), then false for COOL
--    s, logged once per episode, so Navigator/Worldstone never freeze on
--    Rosie's account. In the cool-down pickup walks to no drop
--    (Pickup.walk_hold, like the fight hold): Navigator gets the path back.
--  * pause/resume(caller): the Looter acquire/release_pause under the caller's
--    name. QQT_Warpigz_v3 1.0.23 (review): bounded. A repeated pause never
--    refreshes the Looter's 60 s TTL; once that pause ends (TTL, PAUSE_MAX s,
--    a pickup enable) the caller's further pauses are ignored (logged once)
--    until it calls resume.
--  * Every entry point is pcall-guarded, never raises and never requires.
local Settings=require('rosie.private.pickup.src.settings')
local ItemManager=require('rosie.private.pickup.src.item_manager')
local Pickup=require('rosie.private.pickup.src.pickup')
local Utils=require('rosie.private.pickup.utils.utils')
local M={NAME='Scavenger',PEER='Worldstone',CONDITION='Rosie Looting',DEBOUNCE=1,CAP=20,CEILING=60,COOL=5,GRACE=3,
    WANTED_TTL=0.25,PAUSE_MAX=60}
local cfg={} -- alive, enabled, town_busy, option, owned, version: functions; acquire/release: the Looter pause
local B={start=nil,since=nil,last=nil,cool_until=nil} -- since: the episode start or its last pickup
local S={ws_seen=nil,nav_seen=nil,cond_nav=nil,published=false,wanted_at=nil,wanted={}}
local P={} -- pauses taken through the table: key -> {at=, spent=}
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
-- A Scavenger addon (anything but a Rosie table) owns the global.
local function real_present()
    local cur=rawget(_G,M.NAME)
    return cur~=nil and not (type(cur)=='table' and rawget(cur,'_rosie')==true)
end
local function worldstone() return type(rawget(_G,M.PEER))=='table' end
-- QQT_Warpigz_v3 1.0.23 (owner): the one gate of everything the mimic adds (see the header).
local function in_effect()
    return S.published and on('option') and on('alive') and worldstone() and not real_present()
end
-- Why is_busy is false whatever pickup did (nil: nothing blocks it).
local function blocked()
    if not on('alive') then return 'retired' end
    if not on('option') then return 'off' end
    if not S.published then return 'unpublished' end
    if not worldstone() then return 'no Worldstone' end -- QQT_Warpigz_v3 1.0.23 (owner)
    if real_present() then return 'Scavenger addon' end -- QQT_Warpigz_v3 1.0.23 (review)
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
    local p=Pickup.progress_at -- a drop taken restarts the CAP clock
    if type(p)=='number' and p>B.since and p<=now then B.since=p end
    local stalled=now-B.since>=M.CAP
    if not stalled and now-B.start<M.CEILING then return true end
    B.cool_until,B.start,B.since=now+M.COOL,nil,nil
    console.print(string.format('[Rosie] Busy as Scavenger for %ds %s; Navigator/Worldstone get the path back for %ds',
        stalled and M.CAP or M.CEILING,stalled and 'without a pickup' or 'in one go',M.COOL))
    return false
end
-- Pickup worked a wanted drop this pulse (Pickup.step returned true).
function M.note_work(now)
    if not in_effect() then return end
    if B.last and (now<B.last or now-B.last>M.DEBOUNCE) then B.start,B.since=nil,nil end
    B.last=now
    refresh(now)
end
-- The cool-down after a cap; pickup walks to no drop meanwhile (pickup.lua
-- fight_deferred), drops in reach are still taken.
local function cooling(now)
    local c=B.cool_until
    return c~=nil and now<c and now>=c-M.COOL and in_effect()
end
Pickup.walk_hold=function(now)
    local ok,hold=pcall(cooling,now)
    return ok and hold==true
end
local function busy_now()
    if blocked()~=nil then return false end
    return refresh(now_s())
end
function M.is_busy()
    local ok,busy=pcall(busy_now)
    return ok and busy==true
end
local function condition() return M.is_busy() end
-- Pause keyed by the caller (see the header). 'Rosie' is Rosie's own
-- town-trip pause and keeps that name to itself.
local function caller_of(caller)
    if type(caller)~='string' or caller=='' then return 'Scavenger-caller' end
    return caller=='Rosie' and 'Scavenger-caller:Rosie' or caller
end
local function holds(key)
    Settings.is_paused() -- the Looter's TTL expiry runs here
    return Settings.pause_state().owners[key]==true
end
-- QQT_Warpigz_v3 1.0.23 (review): the caller's pause episode ends (bounded).
local function spend(key,p,now)
    if holds(key) then Settings.release_pause(key) end
    p.spent=true
    console.print(string.format('[Rosie] Pickup pause by %s (through Scavenger) ended after %ds; its further Scavenger.pause calls are ignored until it calls resume',
        key,math.floor(math.max(0,now-p.at)+0.5)))
end
local function over(key,p,now) return not p.spent and (now<p.at or now-p.at>=M.PAUSE_MAX or not holds(key)) end
local function bound_pauses(now)
    for key,p in pairs(P) do if over(key,p,now) then spend(key,p,now) end end
end
local function release_all()
    local names={}
    for key,p in pairs(P) do
        if not p.spent and holds(key) then Settings.release_pause(key);names[#names+1]=key end
    end
    P={}
    if #names>0 then
        table.sort(names)
        console.print('[Rosie] Pickup pause by '..table.concat(names,', ')..' (through Scavenger) released: Rosie no longer acts as Scavenger')
    end
end
local function pause(caller)
    if not in_effect() or type(cfg.acquire)~='function' then return false end
    local key,now=caller_of(caller),now_s()
    local p=P[key]
    if p and over(key,p,now) then spend(key,p,now) end
    if p then return true end -- held: no TTL refresh; spent: ignored until resume
    local ok,result=pcall(cfg.acquire,key)
    if not (ok and result==true) then return false end
    P[key]={at=now}
    return true
end
local function resume(caller)
    if not on('alive') or type(cfg.release)~='function' then return false end
    local key=caller_of(caller)
    P[key]=nil -- a new pause episode for this caller
    local ok,result=pcall(cfg.release,key)
    return ok and result==true
end
function M.pause(caller)
    local ok,result=pcall(pause,caller)
    return ok and result==true
end
function M.resume(caller)
    local ok,result=pcall(resume,caller)
    return ok and result==true
end
-- One version source (the controller's s.version).
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
-- QQT_Warpigz_v3 1.0.23 (review): only drops Rosie would work now. None
-- while out of effect, off, paused, dead, loading, on a town trip, in the
-- cool-down, outside the orbwalker behavior or while an activity owns the
-- loot; never a drop the fight holds, nor a settled, exhausted or resting
-- one, nor a yielded one farther than reach (pickup.lua: one in reach is
-- still taken). Read at most every WANTED_TTL s; a copy for the caller.
local function wanted_now()
    local now=now_s()
    if blocked()~=nil or cooling(now) or on('owned') or Settings.should_execute()~=true then S.wanted_at=nil;return {} end
    if S.wanted_at and now>=S.wanted_at and now-S.wanted_at<M.WANTED_TTL then return S.wanted end
    local out={}
    local am=rawget(_G,'actors_manager')
    local items=type(am)=='table' and Utils.host_call(am.get_all_items)
    for _,item in pairs(type(items)=='table' and items or {}) do
        local ok,want=pcall(ItemManager.check_want_item,item,false)
        if ok and want==true and not Pickup.blocked(item) and not Pickup.fight_deferred(item,now) then out[#out+1]=item end
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
local function first_seen(at,name,now)
    if type(rawget(_G,name))~='table' then return nil end
    return (at and now>=at) and at or now
end
local function unpublish(own)
    if own then _G[M.NAME]=nil end
    if S.published then B.start,B.since,B.last,B.cool_until=nil,nil,nil,nil end
    S.published=false
    if next(P)~=nil then release_all() end
end
local function tick(handoff)
    local now=now_s()
    S.ws_seen,S.nav_seen=first_seen(S.ws_seen,M.PEER,now),first_seen(S.nav_seen,'Navigator',now)
    local cur=rawget(_G,M.NAME)
    local own=type(cur)=='table' and rawget(cur,'_rosie')==true
    if cur~=nil and not own then -- a real Scavenger: never overwritten
        if S.published then log_once('real','A Scavenger addon is loaded: Rosie stops acting as Scavenger and yields to it') end
        unpublish(false)
        return
    end
    local from=S.ws_seen and math.max(S.ws_seen,S.nav_seen or S.ws_seen)
    if from and on('option') and on('alive') and (own or handoff==true or now-from>=M.GRACE) then
        if cur~=M.shim then
            _G[M.NAME]=M.shim
            log_once('pub','Acting as Scavenger for Worldstone/Navigator (no Scavenger installed)')
        end
        S.published=true
        local nav=rawget(_G,'Navigator')
        if type(nav)=='table' then register(nav) end
        if next(P)~=nil then bound_pauses(now) end
    else
        if S.published and not from then log_once('gone','Worldstone is not running: Rosie stops acting as Scavenger') end
        unpublish(own)
    end
end
-- Publishes / removes the table and registers the condition (every update).
-- handoff: the retired instance had its table published (reload: at once).
function M.tick(handoff)
    local ok,why=pcall(tick,handoff)
    if not ok then log_once('tick_err','Scavenger mimic error: '..tostring(why)) end
    return ok
end
-- QQT_Warpigz_v3 1.0.23 (review): a conflict or a retired instance removes
-- its own table and releases its pauses. True when its table was published.
local function retire()
    local own=rawget(_G,M.NAME)==M.shim
    unpublish(own)
    return own
end
function M.retire()
    local ok,own=pcall(retire)
    return ok and own==true
end
return M
