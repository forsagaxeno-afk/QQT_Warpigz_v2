-- QQT_Warpigz_v3 1.0.31 (owner: Worldstone v0.1.9 shows "Required plugins:
-- Butler"): Rosie stands in for Butler (a closed .pak, Navigator-aware town
-- service) the way scavenger_mimic.lua stands in for Scavenger.
-- Worldstone polls Butler.is_busy() about every 5 s and stands still while it
-- is true, and in town asks Butler.needs_visit() (docs/THIRD_PARTY_APIS.md).
-- Rules:
--  * _G.Butler (marked _rosie=true) is published only while _G.Worldstone is a
--    table, the option "Stand in for Butler while Worldstone runs" is on, this
--    Rosie is alive and no real Butler owns the global; checked every pulse
--    (the load order is not fixed; a real Butler loads about 2 s after the
--    others). A real Butler is never overwritten: when one appears, Rosie's
--    own table is withdrawn. Out of effect only Rosie's own table is removed.
--  * is_busy: a Rosie town trip runs (the lifecycle, from the request through
--    the return), the span Worldstone must stand still for. QQT_Warpigz_v3
--    1.0.33 (Auditor): bounded like the Navigator hold (lifecycle
--    trip_active: a trip tick within NAV_PULSE s, at most NAV_HOLD_MAX s).
--  * needs_visit: true only while Rosie's automatic service will run the trip
--    (a need, the service on and not latched); never a need Rosie will not
--    serve, or Worldstone would wait for good.
--  * get_status: the observed Butler fields, filled from Rosie's status.
--  * Any other name Worldstone reads returns a no-op function (nil result)
--    and is logged once, so the owner's next log names it.
--  * Rosie's own town code never yields to this table (foreign.lua
--    real_butler() skips _rosie tables; 1.0.32).
--  * Every entry point is pcall-guarded and never raises.
local M={NAME='Butler',PEER='Worldstone'}
local cfg={} -- alive, option, busy, will_run, status, in_town, step: functions
local S={published=false}
local logged={}
local function log_once(key,text)
    if logged[key] then return end
    logged[key]=true
    console.print('[Rosie] '..text)
end
local function on(name)
    local f=cfg[name]
    if type(f)~='function' then return false end
    local ok,v=pcall(f)
    return ok and v==true
end
local function get(name)
    local f=cfg[name]
    if type(f)~='function' then return nil end
    local ok,v=pcall(f)
    if ok then return v end
    return nil
end
function M.configure(o) for k,v in pairs(o) do cfg[k]=v end end
local function real_present()
    local cur=rawget(_G,M.NAME)
    return cur~=nil and not (type(cur)=='table' and rawget(cur,'_rosie')==true)
end
local function worldstone() return type(rawget(_G,M.PEER))=='table' end
local function in_effect()
    return S.published and on('option') and on('alive') and worldstone() and not real_present()
end
function M.in_effect()
    local ok,v=pcall(in_effect)
    return ok and v==true
end
function M.is_busy()
    return M.in_effect() and on('busy')
end
-- The bag needs (Butler's needs list shape is not known: names only).
local function needs_list(st)
    local out={}
    if type(st)~='table' then return out end
    if st.inventory_full then out[#out+1]='inventory' end
    if st.talisman_inventory_full then out[#out+1]='talismans' end
    if st.need_repair then out[#out+1]='repair' end
    if #out==0 then out[#out+1]='inventory' end
    return out
end
local function needs_visit()
    if not in_effect() or on('busy') or not on('will_run') then return false,{} end
    return true,needs_list(get('status'))
end
function M.needs_visit()
    local ok,need,list=pcall(needs_visit)
    if ok and need==true then return true,type(list)=='table' and list or {} end
    return false,{}
end
local STEP={teleport='travel',repair='blacksmith',salvage='blacksmith',sell='blacksmith',
    salvage_talisman='occultist',stash='stash',stash_pull='stash'}
local function status()
    local st=get('status')
    if type(st)~='table' then st={} end
    local busy=M.is_busy()
    local need,needs=M.needs_visit()
    local step=get('step')
    local paused=st.paused==true
    return {needs_visit=need,is_in_town=on('in_town'),needs=needs,owner='Butler',name='Rosie',mimic=true,
        is_paused=paused,is_busy=busy,is_enabled=st.enabled==true,
        message=type(st.state_text)=='string' and st.state_text or nil,
        state=not (st.enabled==true) and 'disabled' or paused and 'paused' or 'running',
        step=busy and STEP[tostring(step)] or nil,town='Temis',
        counts={stash=(tonumber(st.stash_count) or 0)+(tonumber(st.stash_talisman_count) or 0),
            salvage=(tonumber(st.salvage_count) or 0)+(tonumber(st.salvage_talisman_count) or 0),
            inventory=tonumber(st.inventory_count) or 0,talismans=tonumber(st.talisman_inventory_count) or 0,
            keep=(tonumber(st.stash_count) or 0)+(tonumber(st.stash_talisman_count) or 0),
            sell=tonumber(st.sell_count) or 0},
        obols=nil}
end
function M.get_status()
    local ok,s=pcall(status)
    if ok and type(s)=='table' then return s end
    return {needs_visit=false,is_in_town=false,needs={},owner='Butler',name='Rosie',mimic=true,is_paused=false,
        is_busy=false,is_enabled=false,message='Rosie status unavailable.',state='disabled',town='Temis',
        counts={stash=0,salvage=0,inventory=0,talismans=0,keep=0,sell=0}}
end
local function noop() return nil end
-- QQT_Warpigz_v3 1.0.32 (Coordinator review): any addon may read a missing
-- name, not only Worldstone; the line names the reading source when the host
-- has debug.getinfo (level 2: the code that indexed the table).
local function reader()
    local dbg=rawget(_G,'debug')
    if type(dbg)~='table' or type(dbg.getinfo)~='function' then return '' end
    local ok,info=pcall(dbg.getinfo,3,'Sl')
    if not ok or type(info)~='table' or type(info.short_src)~='string' then return '' end
    return string.format(' by %s:%s',info.short_src,tostring(info.currentline or '?'))
end
M.shim=setmetatable({_rosie=true,mimic=true,name='Rosie',
    is_busy=M.is_busy,needs_visit=M.needs_visit,get_status=M.get_status},
    {__index=function(_,key)
        if type(key)=='string' and key:sub(1,2)~='__' and not logged['missing|'..key] then
            log_once('missing|'..key,'Butler.'..key..' called (not mimicked yet)'..reader())
        end
        return noop
    end})
local function unpublish(own)
    if own then _G[M.NAME]=nil end
    S.published=false
end
local function tick()
    local cur=rawget(_G,M.NAME)
    local own=cur==M.shim or (type(cur)=='table' and rawget(cur,'_rosie')==true)
    if cur~=nil and not own then -- a real Butler: never overwritten
        if S.published then log_once('real','A Butler addon is loaded: Rosie stops standing in for Butler and yields to it') end
        logged.pub=nil -- QQT_Warpigz_v3 1.0.33: each transition logs again
        unpublish(false)
        return
    end
    if worldstone() and on('option') and on('alive') then
        if cur~=M.shim then
            _G[M.NAME]=M.shim
            log_once('pub','Standing in for Butler for Worldstone (no Butler installed)')
            logged.gone,logged.real=nil,nil -- QQT_Warpigz_v3 1.0.33: each transition logs again
        end
        S.published=true
    else
        if S.published and not worldstone() then log_once('gone','Worldstone is not running: Rosie stops standing in for Butler');logged.pub=nil end
        unpublish(own)
    end
end
-- Publishes / removes the table (every update).
function M.tick()
    local ok,why=pcall(tick)
    if not ok then log_once('tick_err','Butler stand-in error: '..tostring(why)) end
    return ok
end
-- A conflict or a retired instance removes its own table.
function M.retire()
    local ok,own=pcall(function()
        local own=rawget(_G,M.NAME)==M.shim
        unpublish(own)
        return own
    end)
    return ok and own==true
end
return M
