package.path='visualizer/?.lua;'..package.path
love={filesystem={getInfo=function() end}}
local editor=require('spec_editor')
local frames=require('unit_frames')
local json=require('json')
local vitals=require('vitals')
local function has(xs,name)
    for _,v in ipairs(xs) do if v==name then return true end end
    return false
end
local function cd(info,icon)
    for _,v in ipairs(info.cooldowns) do if v.icon==icon then return v end end
end
editor.setClass('warlock')
editor.setPet('succubus')
local spec=editor.getCurrentSpecConfig()
assert(spec.automatic_actions and has(spec.action_loadout,'Fear'))
assert(has(spec.action_loadout,'Seduction') and not has(spec.action_loadout,'Spell Lock'))
editor.setPet('felhunter')
spec=editor.getCurrentSpecConfig()
assert(has(spec.action_loadout,'Spell Lock') and not has(spec.action_loadout,'Seduction'))
for _,file in ipairs({'shadow_priest','disc_priest'}) do
    local f=assert(io.open('specs/'..file..'.json')); local original=json.decode(f:read('*a'));f:close()
    original.action_slots={'Idle/Maneuver','Cancel Cast'};original.action_loadout={}
    editor.loadSpec(original)
    spec=editor.getCurrentSpecConfig()
    assert(has(spec.action_loadout,'Mana Burn'))
    local pi=file=='disc_priest'
    assert(has(spec.action_loadout,'Power Infusion')==pi)
    for side=0,1 do
        local suffix=side==0 and 'a' or 'b'
        local meta={spec_a='priest',spec_b='priest'}
        meta['action_loadout_'..suffix]=spec.action_loadout
        local f={};f[113+side]=177
        assert((cd(frames.describe(meta,f,side),'spell_holy_powerinfusion')~=nil)==pi)
        meta['action_loadout_'..suffix]=nil
        meta['action_mask_'..suffix]=pi and 2^21 or 0
        assert((cd(frames.describe(meta,f,side),'spell_holy_powerinfusion')~=nil)==pi)
    end
end
for side=0,1 do
    local suffix=side==0 and 'a' or 'b'
    local meta={};meta['max_mana_'..suffix]=7350;meta['max_health_'..suffix]=5400
    assert(vitals.fraction(meta,side,'mana',3675)==0.5)
    assert(vitals.fraction(meta,side,'health',1350)==0.25)
    assert(vitals.fraction({},side,'mana',500)==0.5)
    assert(vitals.fraction(meta,side,'mana',9000)==1)
end
print('Automatic actions, legacy migration, per-side cooldown capabilities and shared mana/HP normalization passed.')
