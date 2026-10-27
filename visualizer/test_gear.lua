-- Run from repository root: lua visualizer/test_gear.lua
package.path='visualizer/?.lua;'..package.path
local gear=require('gear')
local json=require('json')
local function near(a,b) assert(math.abs(a-b)<1e-6,tostring(a)..' != '..tostring(b)) end
local function clone(x) return json.decode(json.encode(x)) end
local function same(a,b)
    if type(a)~=type(b) then return false end
    if type(a)=='number' then return math.abs(a-b)<1e-6 end
    if type(a)~='table' then return a==b end
    for k,v in pairs(a) do if not same(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
local base={spell_hit_chance=1,spell_crit_chance=0,max_health=2000,max_mana=1000}
for _,class in ipairs({'warlock','frost_mage','priest'}) do
    local loadout=gear.prebis(class)
    assert(gear.validate(loadout,class))
    for _,slot in ipairs(gear.slots) do assert(gear.item(loadout[slot[1]])) end
    local stats,t=gear.resolve(loadout,class,base)
    near(stats.max_health,2000+t.stamina*10)
    near(stats.max_mana,1000+t.intellect*15)
    assert(stats.spell_hit_chance<=0.99 and stats.spell_crit_chance>0)
    local again=gear.resolve(clone(loadout),class,base)
    assert(same(stats,again))
end
assert(gear.item(16683).stats.spell_power==nil,'Inactive set bonus counted')
local loadout=gear.copy()
assert(not gear.equip(loadout,'head',14152,'warlock'))
assert(not gear.equip(loadout,'chest',14152,'warlock'))
assert(gear.equip(loadout,'off_hand',11904,'frost_mage'))
assert(gear.equip(loadout,'main_hand',944,'frost_mage'));assert(loadout.off_hand==0)
assert(gear.equip(loadout,'off_hand',11904,'frost_mage'));assert(loadout.main_hand==0)
assert(gear.equip(loadout,'trinket1',12930,'warlock'))
assert(not gear.equip(loadout,'trinket2',12930,'warlock'))
assert(gear.equip(loadout,'ring1',942,'frost_mage'))
assert(gear.equip(loadout,'ring2',942,'frost_mage'))
local stats=gear.resolve(loadout,'frost_mage',base);near(stats.frost_power,91) -- 42 frost + 29 reed + 20 offhand

local noop=function() end
love={graphics=setmetatable({}, {__index=function() return noop end}),filesystem={getInfo=noop}}
local editor=require('spec_editor')
editor.setClass('warlock')
local initial=editor.getCurrentSpecConfig()
assert(initial.gear.chest==14153,'New Warlocks should start in Pre-BiS')
assert(initial.combat_stats.max_health>2000)
local legacy=clone(initial)
legacy.gear=nil;legacy.gear_base_stats=nil;legacy.combat_stats=clone(base)
editor.equipPrebis()
local a=clone(editor.getCurrentSpecConfig())
editor.loadSpec(a)
assert(same(editor.getCurrentSpecConfig(),a),'Reload compounded gear bonuses')
editor.equipPrebis();assert(same(editor.getCurrentSpecConfig(),a))
assert(editor.setGear('head',0));local less=editor.getCurrentSpecConfig()
near(less.combat_stats.max_health,a.combat_stats.max_health-80)
near(less.combat_stats.shadow_power,a.combat_stats.shadow_power-30)
editor.setClass('frost_mage');assert(editor.getCurrentSpecConfig().gear.chest==14152,'New Mages should start in Pre-BiS');editor.equipPrebis();local b=clone(editor.getCurrentSpecConfig())
editor.loadSpec(a);assert(editor.getCurrentSpecConfig().class=='warlock')
editor.loadSpec(b);assert(editor.getCurrentSpecConfig().gear.chest==14152)
editor.clearGear();assert(editor.getCurrentSpecConfig().gear==nil)
editor.loadSpec(legacy);assert(editor.getCurrentSpecConfig().gear==nil);near(editor.getCurrentSpecConfig().combat_stats.max_health,2000)
editor.setClass('priest')
local priest=editor.getCurrentSpecConfig()
assert(priest.gear.chest==14136 and gear.validate(priest.gear,'priest'))
assert(priest.combat_stats.shadow_power>300 and priest.combat_stats.max_health>2500)
local f=assert(io.open('specs/shadow_priest.json'));local preset=json.decode(f:read('*a'));f:close()
editor.loadSpec(preset)
assert(editor.getCurrentSpecConfig().combat_stats.shadow_power==preset.combat_stats.shadow_power)
assert(editor.getCurrentSpecConfig().gear.chest==14136)
print('Gear catalog, stat totals, slot/class restrictions, unique items, two-hand rules, persistence, class changes and legacy specs passed.')

-- Frozen cross-language totals: changing formulas requires reviewing this fixture.
local parityFile=assert(io.open('src/testdata/equipment_parity.json'))
local fixtures=json.decode(parityFile:read('*a'));parityFile:close()
for _,fixture in ipairs(fixtures) do
    local input=fixture.input
    local actual=gear.resolve(input.gear,input.class,input.gear_base_stats or {})
    assert(same(actual,fixture.expected),'Editor/native equipment parity fixture changed')
end
assert(not gear.validate({main_hand=944,off_hand=11904},'warlock'))
assert(not gear.validate({unknown=0},'warlock'))
assert(not gear.validate({head=-1},'warlock'))

editor.loadSpec(a)
assert(editor.setCombatStat('max_health',4444))
local overridden=clone(editor.getCurrentSpecConfig())
editor.loadSpec(overridden)
near(editor.getCurrentSpecConfig().combat_stats.max_health,4444)

local referenceFile=assert(io.open('src/testdata/reference_stats.json'))
local referenceCases=json.decode(referenceFile:read('*a'));referenceFile:close()
for _,case in ipairs(referenceCases) do
    editor.loadSpec(case.input)
    local spec=clone(editor.getCurrentSpecConfig())
    assert(spec.stat_profile=='level60_reference_v1' and spec.gear_base_stats==nil)
    for key,value in pairs(case.expected) do near(spec.combat_stats[key],value) end
    editor.loadSpec(spec)
    for key,value in pairs(case.expected) do near(editor.getCurrentSpecConfig().combat_stats[key],value) end
end
-- A reference race change derives the new baseline; changing class leaves it.
editor.loadSpec(referenceCases[2].input) -- Human Warlock, geared.
editor.setRace('gnome')
local gnome=editor.getCurrentSpecConfig()
for key,value in pairs(referenceCases[4].expected) do near(gnome.combat_stats[key],value) end
editor.clearGear()
near(editor.getCurrentSpecConfig().combat_stats.max_health,1874)
editor.equipPrebis()
near(editor.getCurrentSpecConfig().combat_stats.max_health,2544)
local before=clone(editor.getCurrentSpecConfig())
assert(editor.loadSpec({class='priest',stat_profile='unknown',trees={}})==false)
assert(same(before,editor.getCurrentSpecConfig()))
editor.setClass('warlock')
assert(editor.getCurrentSpecConfig().stat_profile==nil)
near(editor.getCurrentSpecConfig().combat_stats.max_health,2670)
print('32 reference profile cases, race rebasing, round trips and legacy class defaults passed.')

local stable=clone(editor.getCurrentSpecConfig())
assert(editor.loadSpec({class='priest',stat_profile=false,trees={}})==false)
assert(same(stable,editor.getCurrentSpecConfig()))

editor.loadSpec(referenceCases[2].input)
assert(not editor.setCombatStat('level',59))
assert(editor.getCurrentSpecConfig().combat_stats.level==60)
