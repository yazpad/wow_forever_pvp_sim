-- Headless integration: real workspace controls, dropdowns and Fight snapshots.
package.path='visualizer/?.lua;'..package.path
local width,height=1280,900
local noop=function() end
local font={getWrap=function(_,s) return 100,{s} end,getWidth=function(_,s) return #s*7 end,getHeight=function() return 14 end}
love={graphics=setmetatable({getWidth=function() return width end,getHeight=function() return height end,getFont=function() return font end},{__index=function() return noop end}),mouse={getPosition=function() return 0,0 end},filesystem={getInfo=noop}}
package.loaded.icons_manager=setmetatable({}, {__index=function() return noop end})
dofile('visualizer/main.lua')
local ui=require('ui')
local workspace=require('workspace')
local generator=require('match_generator')
local editor=require('spec_editor')
local json=require('json')
local controls,dropdowns,labels={},{},{}
local button=ui.button
ui.button=function(x,y,w,h,label,...)
    local frame=workspace.frameBounds and workspace.frameBounds[workspace.getSelected()]
    if not frame or x>=workspace.settingsX or (x>=frame.x and x<frame.x+frame.w) then controls[label]={x=x,y=y,w=w,h=h} end
    return button(x,y,w,h,label,...)
end
local dropdown=ui.dropdown
ui.dropdown=function(id,x,y,w,h,value,choices,onSelect,...)
    dropdowns[id]={x=x,y=y,w=w,h=h,value=value,choices=choices,onSelect=onSelect}
    return dropdown(id,x,y,w,h,value,choices,onSelect,...)
end
love.graphics.print=function(label,x,y)
    local frame=workspace.frameBounds and workspace.frameBounds[workspace.getSelected()]
    if frame and x>=frame.x and x<frame.x+frame.w then labels[label]={x=x,y=y} end
end
local function draw() controls={};dropdowns={};labels={};love.draw() end
local function click(c) assert(c);workspace.mousepressed(c.x+c.w/2,c.y+c.h/2,1) end
workspace.select(1);draw()
for i=1,2 do
    local initial=workspace.preview().specs[i]
    assert(initial.gear and initial.gear.chest==(initial.class=='warlock' and 14153 or 14152),
        'Both starting fighters should have Pre-BiS gear')
end
editor.setClass('warlock');draw()
local label=assert(labels.Gear);workspace.mousepressed(label.x+5,label.y+5,1);draw()
click(controls['Pre-BiS']);draw()
assert(workspace.preview().specs[1].gear.chest==14153)
assert(workspace.preview().frame[5]>2000)
local head=assert(dropdowns.gear_1_head)
click(head);assert(ui.dropdownOpen())
local bounds=ui.dropdownBounds()
ui.dropdownMousepressed(bounds.x+20,bounds.y+10,1);draw()
assert(workspace.preview().specs[1].gear.head==0)
assert(not ui.dropdownOpen())
local a=workspace.preview().specs[1]
workspace.select(2);editor.setClass('frost_mage');draw()
label=assert(labels.Gear);workspace.mousepressed(label.x+5,label.y+5,1);draw()
click(controls['Pre-BiS']);draw()
assert(workspace.preview().specs[2].gear.chest==14152)
assert(workspace.preview().specs[1].gear.head==a.gear.head)
-- Race changes through the real header menu preserve the other player's draft.
workspace.select(1);draw()
local raceA=assert(dropdowns.race_1)
assert(raceA.y>dropdowns.preset_1.y+dropdowns.preset_1.h)
assert(raceA.x>dropdowns.class_text_1.x+dropdowns.class_text_1.w)
click(raceA)
local raceBounds=assert(ui.dropdownBounds())
ui.dropdownMousepressed(raceBounds.x+20,raceBounds.y+4+2.5*raceBounds.row,1)
draw()
assert(workspace.preview().specs[1].race=='orc')
assert(workspace.preview().specs[2].race=='human')
workspace.select(2);editor.setRace('troll');draw()
assert(workspace.preview().specs[2].race=='troll')
local saved=editor.getCurrentSpecConfig()
editor.setRace('human');editor.loadSpec(saved)
assert(editor.getCurrentSpecConfig().race=='troll')
editor.setClass('warlock')
assert(editor.getCurrentSpecConfig().race=='troll')
editor.loadSpec(saved);draw()
local nt=generator.getNeuroTelemetry()
nt.policy_a,nt.policy_b='matches/neuro_champion_a.nepl','matches/neuro_champion_b.nepl'
draw()
local launched
local old=generator.startFight
generator.startFight=function(cfg) launched=cfg;return true end
click(controls['Quick Fight'])
assert(launched and #launched.temporary_specs==2)
for i,side in ipairs({'a','b'}) do
    local file=assert(io.open(launched.temporary_specs[i]));local spec=json.decode(file:read('*a'));file:close()
    assert(spec.race==(i==1 and 'orc' or 'troll'))
    assert(spec.gear and spec.combat_stats.max_health==launched['hp_'..side])
    assert(spec.combat_stats.max_mana>1000)
    os.remove(launched.temporary_specs[i])
end
-- Explicit equal-stat profiles must use their maximum health without gear.
workspace.select(1)
local profileFile=assert(io.open('specs/shadow_priest_equal_stats.json'))
local profile=json.decode(profileFile:read('*a'));profileFile:close()
editor.loadSpec(profile);draw()
assert(workspace.preview().frame[5]==2670)
click(controls['Quick Fight'])
assert(launched.hp_a==2670 and launched.spec_a_obj.combat_stats.shadow_power==354)
assert(launched.spec_a_obj.gear==nil)
for _,path in ipairs(launched.temporary_specs) do os.remove(path) end
-- Talent HP is derived once, leaving saved base health and stamina unchanged.
editor.loadSpec({class='warlock',race='human',name='Embrace test',
    combat_stats={max_health=3000,stamina=200,max_mana=2000},
    trees={Affliction={},Demonology={['105907']=5,['105903']=3},Destruction={}}})
draw()
local preview=workspace.preview()
assert(math.abs(preview.meta.max_health_a-3300)<0.001)
assert(math.abs(preview.frame[5]-3300)<0.001)
assert(math.abs(preview.meta.max_mana_a-2300)<0.001)
click(controls['Quick Fight'])
assert(math.abs(launched.hp_a-3300)<0.001)
assert(launched.spec_a_obj.combat_stats.max_health==3000)
assert(launched.spec_a_obj.combat_stats.stamina==200)
for _,path in ipairs(launched.temporary_specs) do os.remove(path) end
local gearModule=require('gear')
local resolved,totals=gearModule.resolve(gearModule.prebis('warlock'),'warlock',{max_health=2000,stamina=50})
assert(resolved.stamina==50+totals.stamina)
local legacy={class='warlock',gear=gearModule.prebis('warlock'),combat_stats={max_health=4000},trees={}}
editor.loadSpec(legacy)
assert(editor.getCurrentSpecConfig().combat_stats.stamina==totals.stamina)
assert(editor.getCurrentSpecConfig().combat_stats.max_health==4000)
generator.startFight=old
print('Gear dropdown input, per-player loadouts, preview resources and serialized Fight snapshots passed.')
editor.setClass('warlock');draw()
local mouseX,mouseY=0,0
love.mouse.getPosition=function() return mouseX,mouseY end
local gear=require('gear')
for _,size in ipairs({{960,540},{1280,720},{2560,1080}}) do
    width,height=size[1],size[2]
    workspace.select(1);draw()
    mouseX=50*ui.scale();mouseY=(workspace.scrollTop+20)*ui.scale()+ui.headerHeight
    workspace.wheelmoved(1000);draw();draw()
    local seen={}
    for step=1,80 do
        for id,control in pairs(dropdowns) do
            if id:match('^gear_1_') then
                seen[id]=true
                click(control)
                local bounds=assert(ui.dropdownBounds())
                assert(bounds.x>=0 and bounds.y>=0 and bounds.x+bounds.w<=ui.width() and bounds.y+bounds.h<=ui.height())
                ui.closeDropdown()
            end
        end
        workspace.wheelmoved(-1);draw()
    end
    for _,slot in ipairs(gear.slots) do assert(seen['gear_1_'..slot[1]],'Unreachable slot '..slot[1]) end
end
print('All 17 slots are reachable and dropdown menus remain in bounds at three window sizes.')

-- Independently audited full sets and swaps must reach setup and Fight specs.
workspace.select(1)
local auditFile=assert(io.open('src/testdata/equipment_parity.json'))
local auditCases=json.decode(auditFile:read('*a'));auditFile:close()
local function near(actual,expected) assert(math.abs(actual-expected)<1e-6,tostring(actual)..' != '..tostring(expected)) end
generator.startFight=function(cfg) launched=cfg;return true end
for _,case in ipairs(auditCases) do
    local input=json.decode(json.encode(case.input));input.trees={}
    editor.loadSpec(input);draw()
    local preview=workspace.preview()
    near(preview.meta.max_health_a,case.expected.max_health)
    near(preview.meta.max_mana_a,case.expected.max_mana)
    click(controls['Quick Fight'])
    local file=assert(io.open(launched.temporary_specs[1]));local exported=json.decode(file:read('*a'));file:close()
    for key,value in pairs(case.expected) do near(exported.combat_stats[key],value) end
    for _,path in ipairs(launched.temporary_specs) do os.remove(path) end
end
-- Gear, Gnome mana, Demonic Embrace and Fel Vitality each contribute once.
local buffed=json.decode(json.encode(auditCases[1].input))
buffed.gear_base_stats=nil;buffed.race='gnome'
buffed.trees={Affliction={},Demonology={['105907']=5,['105903']=3},Destruction={}}
editor.loadSpec(buffed);draw()
local preview=workspace.preview()
near(preview.meta.max_health_a,2770.5)
near(preview.meta.max_mana_a,3036.8625)
click(controls['Quick Fight'])
near(launched.hp_a,2770.5)
near(launched.spec_a_obj.combat_stats.max_health,2670)
near(launched.spec_a_obj.combat_stats.max_mana,2515)
for _,path in ipairs(launched.temporary_specs) do os.remove(path) end
generator.startFight=old
print('Independent gear audit cases and racial/talent totals match setup and serialized Fight inputs.')

local referenceFile=assert(io.open('src/testdata/reference_stats.json'))
local referenceCases=json.decode(referenceFile:read('*a'));referenceFile:close()
generator.startFight=function(cfg) launched=cfg;return true end
for _,case in ipairs(referenceCases) do
    editor.loadSpec(case.input);draw()
    local preview=workspace.preview()
    near(preview.meta.max_health_a,case.runtime_expected.max_health)
    near(preview.meta.max_mana_a,case.runtime_expected.max_mana)
    click(controls['Quick Fight'])
    local file=assert(io.open(launched.temporary_specs[1]));local exported=json.decode(file:read('*a'));file:close()
    assert(exported.stat_profile=='level60_reference_v1' and not exported.gear_base_stats)
    for key,value in pairs(case.expected) do near(exported.combat_stats[key],value) end
    near(launched.hp_a,case.runtime_expected.max_health)
    for _,path in ipairs(launched.temporary_specs) do os.remove(path) end
end
generator.startFight=old
print('32 reference profile setup and Fight-export cases passed.')

local warriorFile=assert(io.open('src/testdata/warrior_equipment.json'))
local warriorCases=json.decode(warriorFile:read('*a'));warriorFile:close()
generator.startFight=function(cfg) launched=cfg;return true end
for _,case in ipairs(warriorCases) do
    editor.loadSpec(case.input);draw()
    near(workspace.preview().meta.max_health_a,case.expected_stats.max_health)
    click(controls['Quick Fight'])
    local file=assert(io.open(launched.temporary_specs[1]));local exported=json.decode(file:read('*a'));file:close()
    assert(exported.gear and exported.gear_base_warrior)
    for key,value in pairs(case.expected_stats) do near(exported.combat_stats[key],value) end
    near(exported.warrior.attack_power,case.expected_warrior.attack_power)
    assert(exported.warrior.shield==case.expected_warrior.shield)
    for _,path in ipairs(launched.temporary_specs) do os.remove(path) end
end
editor.loadSpec(warriorCases[1].input);draw()
mouseX=50*ui.scale();mouseY=(workspace.scrollTop+20)*ui.scale()+ui.headerHeight
workspace.wheelmoved(1000);draw();draw()
click(controls['Shield set']);draw()
assert(workspace.preview().specs[1].warrior.shield)
near(workspace.preview().specs[1].combat_stats.melee_block_value,44.5)
assert(dropdowns.gear_1_main_hand)
dropdowns.gear_1_main_hand.onSelect(12784);draw()
assert(not workspace.preview().specs[1].warrior.shield)
assert(workspace.preview().specs[1].combat_stats.melee_block_chance==0)
assert(workspace.preview().specs[1].gear.off_hand==0)
click(controls['Clear items']);draw()
assert(not workspace.preview().specs[1].gear)
near(workspace.preview().specs[1].warrior.attack_power,700)
generator.startFight=old
print('Warrior starter controls, weapon/shield swaps and seven setup/Fight-export cases passed.')

for _,size in ipairs({{960,540},{1280,720},{2560,1080}}) do
    width,height=size[1],size[2]
    mouseX=50*ui.scale();mouseY=(workspace.scrollTop+20)*ui.scale()+ui.headerHeight
    workspace.wheelmoved(1000);draw();draw()
    local seen={}
    for step=1,100 do
        for id,control in pairs(dropdowns) do
            if id:match('^gear_1_') then
                seen[id]=true
                click(control)
                local bounds=assert(ui.dropdownBounds())
                assert(bounds.x>=0 and bounds.y>=0 and bounds.x+bounds.w<=ui.width() and bounds.y+bounds.h<=ui.height())
                ui.closeDropdown()
            end
        end
        workspace.wheelmoved(-1);draw()
    end
    for _,slot in ipairs(gear.slots) do assert(seen['gear_1_'..slot[1]],'Unreachable Warrior slot '..slot[1]) end
end
print('All Warrior item slots are reachable with in-bounds dropdowns at three window sizes.')
