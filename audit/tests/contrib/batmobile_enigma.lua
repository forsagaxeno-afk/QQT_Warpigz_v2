-- Run from Batmobile: lua tests/enigma.lua. All host input is mocked.
package.path='./?.lua;'..package.path
local checks=0
local function check(value,label)
    assert(value,label); checks=checks+1
end
local now,chat,inventory,vendor,dead,town=10,false,false,false,false,false
local position={x=function() return 0 end,y=function() return 0 end}
local player={is_dead=function() return dead end,get_position=function() return position end}
get_local_player=function() return player end
get_time_since_inject=function() return now end
is_chat_open=function() return chat end
is_inventory_open=function() return inventory end
get_screen_width=function() return 1920 end
get_screen_height=function() return 1080 end
get_equipped_spell_ids=function() return {} end
loot_manager={is_in_vendor_screen=function() return vendor end}
local screen={x=650.8,y=420.2}
local projected,clicked,native
graphics={w2s=function(dest) projected=dest;return screen end}
local function click(x,y) clicked={x,y} end -- documented nil return
utility={send_mouse_middle_click=click,can_cast_spell=function(id)
    check(id>0,'input sentinel never reaches native castability');return true
end}
cast_spell={position=function(id,dest,delay)
    check(id>0,'input sentinel never reaches native casting')
    native={id,dest,delay};return true
end}
local cast=require('core.movement_cast')
local dest={x=function() return 8 end,y=function() return 0 end}
check(cast.enigma_ready(),'input initially ready')
check(cast.position(cast.ENIGMA,dest,0),'nil-returning mouse API counts as dispatch')
check(projected==dest and clicked[1]==650 and clicked[2]==420,'click projected path node in pixels')
check(native==nil,'Enigma bypasses native casting')
check(not cast.enigma_ready(),'shared click throttle starts')
clicked=nil
check(not cast.position(cast.ENIGMA,dest,0) and not clicked,'throttle prevents repeat click')
now=10.249
check(not cast.enigma_ready(),'default throttle holds before 0.25 seconds')
now=10.25
check(cast.enigma_ready(),'default throttle expires at 0.25 seconds')
cast.enigma_interval=0.1
check(cast.position(cast.ENIGMA,dest,0),'short interval dispatch')
now=10.349
check(not cast.enigma_ready(),'0.1 second throttle holds before deadline')
now=10.351
check(cast.enigma_ready(),'0.1 second throttle permits rapid retries')
cast.enigma_interval=0.25
now=12
chat=true;check(not cast.enigma_ready(),'chat suppresses clicks');chat=false
inventory=true;check(not cast.enigma_ready(),'inventory suppresses clicks');inventory=false
vendor=true;check(not cast.enigma_ready(),'vendor suppresses clicks');vendor=false
dead=true;check(not cast.enigma_ready(),'dead player suppresses clicks');dead=false
screen={x=1920,y=100}
check(not cast.position(cast.ENIGMA,dest,0),'off-screen target rejected')
screen={x=0/0,y=100}
check(not cast.position(cast.ENIGMA,dest,0),'invalid projection rejected')
screen=nil
check(not cast.position(cast.ENIGMA,dest,0),'missing projection rejected')
screen={x=650,y=420}
utility.send_mouse_middle_click=nil
check(not cast.enigma_ready(),'unsupported host rejected')
utility.send_mouse_middle_click=function() error('input failed') end
check(not cast.position(cast.ENIGMA,dest,0),'input exception contained')
check(not cast.enigma_ready(),'failed input attempts also throttled')
now=14
utility.send_mouse_middle_click=function() return false end
check(not cast.position(cast.ENIGMA,dest,0),'explicit input failure rejected')
utility.send_mouse_middle_click=click
check(cast.position(288106,dest,0),'native spells still dispatch during input throttle')
check(native[1]==288106 and native[2]==dest and native[3]==0,'native arguments preserved')
now=16

package.loaded['core.utils']={
    log=function() end,debug_log=function() end,
    distance=function(a,b) return math.abs(a:x()-b:x()) end,
    vec_to_string=function(v) return tostring(v:x()) end,
    player_in_town=function() return town end,
    get_character_class=function() return 'sorcerer' end,
}
local rules=require('core.movement_rules')
check(rules.skill_catalog[1].id==337031,'Evade picker index preserved')
check(rules.skill_catalog[15].match=='rampage','Rampage picker index preserved')
check(rules.skill_catalog[#rules.skill_catalog].id==cast.ENIGMA,'Enigma appended to picker')
local engine=require('core.movement_engine')
local ctx={local_player=player,player_pos=position,path={dest},default_range=12,min_spell_dist=3,blacklist={}}
local rule={enabled=true,skill_id=cast.ENIGMA,conditions={},throttle_ms=0}
local id,los,range,node=engine.pick({rule},ctx)
check(id==cast.ENIGMA and los==false and range==12 and node==dest,'revamp selects Enigma without an equipped spell')
check(cast.position(id,node,0),'revamp dispatches Mouse 3')
check(engine.pick({rule},ctx)==nil,'revamp observes shared throttle')
rule.enabled=false;now=18
check(engine.pick({rule},ctx)==nil,'disabled rule does not fire');rule.enabled=true
ctx.blacklist['8']=dest
check(engine.pick({rule},ctx)==nil,'revamp respects blacklisted nodes');ctx.blacklist={}
ctx.min_spell_dist=9
check(engine.pick({rule},ctx)==nil,'revamp respects minimum distance');ctx.min_spell_dist=3

local settings={use_movement=true,use_enigma=true,spell_interval=0.15,use_teleport=true}
package.loaded['core.settings']=settings
package.loaded['core.explorer']={}
package.loaded['core.pathfinder']={}
package.loaded['core.tracker']={}
local nav=require('core.navigator')
local pick
for i=1,100 do
    local name,value=debug.getupvalue(nav.move,i)
    if not name then break end
    if name=='get_movement_spell_id' then pick=value end
end
assert(pick,'navigator selector upvalue missing')
local function select_spell()
    now=now+1;nav.spell_time=-1;return pick(player)
end
check(select_spell()==cast.ENIGMA,'legacy prioritizes enabled Enigma')
settings.use_movement=false
check(select_spell()==nil,'master movement toggle suppresses Enigma');settings.use_movement=true
nav.disable_spell=true
check(select_spell()==nil,'caller disable_spell suppresses Enigma');nav.disable_spell=false
settings.use_enigma=false
check(select_spell()==288106,'opt-out preserves class spell selection');settings.use_enigma=true
town=true
check(select_spell()~=cast.ENIGMA,'town suppresses Enigma');town=false
nav.path={dest};settings.movement_revamp=true;settings.movement_rules={rule}
check(select_spell()==cast.ENIGMA,'navigator routes revamp Enigma selection')
settings.use_movement=false
check(select_spell()==nil,'revamp also respects master toggle')
print('PASS: Enigma input, throttle, rule engine and navigator guards ('..checks..' checks)')
