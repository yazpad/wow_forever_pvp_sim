-- Run from repository root: lua visualizer/test_priest_utility.lua
package.path='visualizer/?.lua;'..package.path
package.loaded.icons_manager={}
local json=require('json')
local editor=require('spec_editor')
local function read(path)
    local f=assert(io.open(path)); local data=json.decode(f:read('*a')); f:close(); return data
end
local function has(actions,name)
    for _,action in ipairs(actions) do if action==name then return true end end
    return false
end
local disc=read('specs/disc_priest.json')
editor.loadSpec(disc)
local exported=editor.getCurrentSpecConfig()
assert(#exported.action_loadout>=#disc.action_loadout,'Editor dropped a configured priest ability')
for _,name in ipairs(disc.action_loadout) do assert(has(exported.action_loadout,name),name) end
assert(has(editor.getAvailableActions(),'Power Infusion'))
-- Preserve late spell slots when migrating an older 15-slot action bar.
local legacy=read('specs/disc_priest.json')
legacy.action_slots={}
for i=1,15 do legacy.action_slots[i]='' end
legacy.action_slots[1]='Idle/Maneuver'
legacy.action_slots[2]='Devouring Plague'
legacy.action_slots[12]='Penance'
legacy.action_slots[14]='Inner Focus'
legacy.action_slots[15]='Cancel Cast'
editor.loadSpec(legacy)
exported=editor.getCurrentSpecConfig()
assert(has(exported.action_loadout,'Penance'))
assert(has(exported.action_loadout,'Inner Focus'))
assert(exported.automatic_actions)
assert(exported.action_slots[#exported.action_slots]=='Cancel Cast')
for _,file in ipairs({'specs/shadow_priest.json','specs/shadow_priest_equal_stats.json'}) do
    local spec=read(file); editor.loadSpec(spec); exported=editor.getCurrentSpecConfig()
    assert(#exported.action_loadout>=#spec.action_loadout)
    assert(not has(editor.getAvailableActions(),'Power Infusion'))
    for _,name in ipairs({'Dispel Magic (Self)','Dispel Magic (Enemy)','Mana Burn'}) do
        assert(has(exported.action_loadout,name),name)
    end
end
local frames=require('unit_frames')
for side=0,1 do
    local frame={}
    frame[111+side]=12
    frame[113+side]=177
    local info=frames.describe({spec_a='priest',spec_b='priest'},frame,side)
    local found=false
    for _,buff in ipairs(info.buffs) do
        if buff.icon=='spell_holy_powerinfusion' then assert(buff.remaining==12); found=true end
    end
    assert(found,'Missing Power Infusion replay badge')
end
print('Priest utility presets, editor migration, talent gates and replay badges passed.')
editor.setClass('priest')
exported=editor.getCurrentSpecConfig()
for _,name in ipairs({'Dispel Magic (Self)','Dispel Magic (Enemy)','Mana Burn'}) do
    assert(has(exported.action_loadout,name),'New priest defaults omitted '..name)
end
assert(not has(exported.action_loadout,'Power Infusion'))

-- Optional appended columns preserve old recordings and keep A/B independent.
for side=0,1 do
    local meta={spec_a='priest',spec_b='priest'}
    assert(#frames.describe(meta,{},side).buffs==0)
    local f={}
    f[115+side]=9; f[117+side]=1; f[119+side]=1
    f[121+side]=13; f[123+side]=5
    local buffs=frames.describe(meta,f,side).buffs
    assert(#buffs==4)
    assert(buffs[1].icon=='spell_holy_renew' and buffs[1].remaining==9)
    assert(buffs[2].icon=='spell_frost_windwalkon' and buffs[2].total==0)
    assert(buffs[3].icon=='spell_shadow_shadowform' and buffs[3].total==0)
    assert(buffs[4].icon=='spell_shadow_blackplague' and buffs[4].remaining==13 and buffs[4].count==5)
    assert(#frames.describe(meta,f,1-side).buffs==0)
    f[121+side]=0
    assert(#frames.describe(meta,f,side).buffs==3,'Expired Shadow Weaving retained stale stacks')
    assert(#frames.describe({spec_a='warlock',spec_b='frost_mage'},f,side).buffs==0)
end
print('Priest aura replay compatibility and side isolation passed.')
