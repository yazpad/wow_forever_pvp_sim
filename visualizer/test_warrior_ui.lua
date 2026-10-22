-- From repository root: lua visualizer/test_warrior_ui.lua
package.path='visualizer/?.lua;'..package.path
package.loaded.icons_manager={}
local json=require('json')
local editor=require('spec_editor')
local warrior=require('warrior')
local talents=require('talents_data')
local frames=require('unit_frames')
local vitals=require('vitals')
local function read(path) local f=assert(io.open(path));local d=json.decode(f:read('*a'));f:close();return d end
local function has(values,name) for _,value in ipairs(values) do if value==name then return true end end;return false end
for _,file in ipairs({'warrior_two_hand','warrior_dual_wield'}) do
    local original=read('specs/'..file..'.json')
    editor.loadSpec(original)
    local config=editor.getCurrentSpecConfig()
    assert(config.class=='warrior' and config.pet=='none' and not config.gear)
    assert(config.talents_summary=='3/0/0')
    assert(warrior.validate(config.warrior))
    assert(config.warrior.main_hand.two_handed==original.warrior.main_hand.two_handed)
    assert((config.warrior.off_hand~=nil)==(original.warrior.off_hand~=nil))
    assert(has(config.action_loadout,'Heroic Strike') and has(config.action_loadout,'Hamstring'))
    assert(not has(config.action_loadout,'Auto Attack') and not has(config.action_loadout,'Blood Fury'))
    editor.equipPrebis();assert(not editor.getCurrentSpecConfig().gear,'Must not equip caster gear on Warrior')
    assert(editor.setWarriorStat('attack_power',812))
    assert(editor.setWarriorStat('starting_stance','berserker'))
    assert(editor.setWarriorStat('starting_rage',50))
    local exported=editor.getCurrentSpecConfig()
    editor.setClass('priest');editor.loadSpec(json.decode(json.encode(exported)))
    local restored=editor.getCurrentSpecConfig()
    assert(restored.warrior.attack_power==812 and restored.warrior.starting_stance=='berserker' and restored.warrior.starting_rage==50)
    assert(restored.combat_stats.max_health==original.combat_stats.max_health)
    assert(not editor.setWarriorStat('main_hand.speed',0))
    if restored.warrior.off_hand then assert(not editor.setWarriorStat('main_hand.two_handed',true)) end
end
editor.setClass('warrior')
assert(editor.getCurrentSpecConfig().warrior and not editor.getCurrentSpecConfig().gear)
assert(not editor.setWarriorStat('off_hand',true),'Two-hand plus off-hand must be rejected')
assert(editor.setWarriorStat('main_hand.two_handed',false))
assert(editor.setWarriorStat('off_hand',true))
assert(warrior.value(editor.getCurrentSpecConfig().warrior,'main_hand.two_handed')==false)
assert(warrior.supportText(assert(talents.findTalent(talents.load('warrior'),12282)))=='Active in fights')
assert(warrior.supportText(assert(talents.findTalent(talents.load('warrior'),12294))):find('Planned'))
local f={};for i=1,136 do f[i]=0 end
f[5],f[6],f[125],f[126],f[127],f[128],f[129],f[130],f[131],f[134]=3500,3000,55,22,4,2,1.2,0.7,1,9
local meta={spec_a='warrior',spec_b='warrior',max_health_a=4000,max_health_b=4000,max_rage_a=130,max_rage_b=100}
local a,b=frames.describe(meta,f,0),frames.describe(meta,f,1)
assert(a.class=='warrior' and a.power==55 and a.resource=='rage' and a.stance=='Berserker' and a.swing==1.2 and not a.pet)
assert(b.power==22 and b.stance=='Defensive' and b.swing==0.7)
assert(#a.buffs==2 and #b.buffs==1 and #a.debuffs==1 and #b.debuffs==0,'Queue/stance/slow badges must be side-specific')
assert(math.abs(vitals.fraction(meta,0,'rage',55)-55/130)<1e-8)
assert(frames.describe({spec_a='priest'},f,0).resource=='mana')
assert(frames.describe({spec_a='warlock'},f,0).resource=='mana')
print('Warrior presets, weapon edits, class changes, capabilities, rage/stance/slow replay telemetry passed')
