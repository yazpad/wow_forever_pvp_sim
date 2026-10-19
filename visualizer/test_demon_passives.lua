-- Run from repository root: lua visualizer/test_demon_passives.lua
package.path='visualizer/?.lua;'..package.path
local passives=require('demon_passives')
local frames=require('unit_frames')
local labels={imp='Fire damage +10%',succubus='Shadow damage +10%',felhunter='Magic damage taken -10%',voidwalker='Physical damage taken -10%'}
for pet,label in pairs(labels) do
    for rank=0,3 do
        local spec={class='warlock',pet=pet,combat_stats={level=60},trees={Demonology={['105893']=rank,['105891']=5}}}
        local result=passives.describe(spec)
        assert(math.abs(result.power-({[0]=0,19.8,40.2,60})[rank])<0.001)
        assert(result.mastery==label)
        spec.pet='none';assert(passives.describe(spec).power==0 and not passives.describe(spec).mastery)
    end
end
for side=0,1 do
    local meta={spec_a='warlock',spec_b='warlock'}
    meta[side==0 and 'warlock_talents_a' or 'warlock_talents_b']={demonic_knowledge=3,master_demonologist=5}
    local f={}
    f[5+side]=2000;f[83+side*5]=1;f[84+side*5]=500
    assert(#frames.describe(meta,f,side).buffs==2)
    assert(#frames.describe(meta,f,1-side).buffs==0)
    f[84+side*5]=0;assert(#frames.describe(meta,f,side).buffs==0)
end
print('Demonic Knowledge/Master Demonologist preview values, pet gating and replay badges passed.')
