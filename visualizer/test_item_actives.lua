package.path='visualizer/?.lua;'..package.path
local json=require('json');local gear=require('gear');local editor=require('spec_editor');local frames=require('unit_frames');local log=require('combat_log')
editor.setClass('warlock')
local function has(values,name) for _,value in ipairs(values) do if value==name then return true end end end
local function read(path) local f=assert(io.open(path));local value=json.decode(f:read('*a'));f:close();return value end
for _,class in ipairs({'warlock','frost_mage','priest','warrior'}) do
    editor.loadSpec(read('specs/'..class..'_pvp_trinket.json'))
    local spec=editor.getCurrentSpecConfig()
    assert(has(spec.action_loadout,'PvP Trinket'))
    assert(gear.pvpItem(spec.gear)==274445)
    assert(not editor.setGear('trinket1',274444),'Variants share a unique effect')
    assert(editor.setGear('trinket2',0))
    assert(not has(editor.getCurrentSpecConfig().action_loadout,'PvP Trinket'))
    assert(editor.setGear('trinket1',274444))
    local saved=json.decode(json.encode(editor.getCurrentSpecConfig()));editor.loadSpec(saved)
    assert(has(editor.getCurrentSpecConfig().action_loadout,'PvP Trinket'))
    local meta={spec_a=class,pvp_trinket_a=274444,item_cooldown_column=class=='warrior' and 163 or 125,action_loadout_a={'PvP Trinket'}}
    local frame={};frame[meta.item_cooldown_column]=120
    local description=frames.describe(meta,frame,0)
    assert(#description.cooldowns==1 and description.cooldowns[1].remaining==120 and description.cooldowns[1].total==300)
    meta.pvp_trinket_a=0
    assert(#frames.describe(meta,frame,0).cooldowns==0)
    meta.pvp_trinket_a=274444;meta.action_loadout_a={}
    assert(#frames.describe(meta,frame,0).cooldowns==0,'Cooldown follows capabilities recorded at Fight start')
end
assert(log.format({spec_a='warlock',name_a='A'},{s=0,k=19,sp=26,t=1}):find('activated PvP Trinket'))
assert(gear.activeOnly({trinket1=274445}))
assert(editor.loadSpec({class='warrior',gear={trinket1=274445},warrior={main_hand={min=1,max=2,speed=2,two_handed=false}},trees={Arms={},Fury={},Protection={}}})~=false)
assert(editor.getCurrentSpecConfig().warrior.main_hand.min==1)
print('Four-class item capabilities, uniqueness, save/load, equipment changes and replay cooldowns passed.')
