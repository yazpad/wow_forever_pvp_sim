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
ui.button=function(x,y,w,h,label,...) controls[label]={x=x,y=y,w=w,h=h};return button(x,y,w,h,label,...) end
local dropdown=ui.dropdown
ui.dropdown=function(id,x,y,w,h,value,choices,onSelect,...)
    dropdowns[id]={x=x,y=y,w=w,h=h,value=value,choices=choices,onSelect=onSelect}
    return dropdown(id,x,y,w,h,value,choices,onSelect,...)
end
love.graphics.print=function(label,x,y) labels[label]={x=x,y=y} end
local function draw() controls={};dropdowns={};labels={};love.draw() end
local function click(c) assert(c);workspace.mousepressed(c.x+c.w/2,c.y+c.h/2,1) end
workspace.select(1);draw()
for i=1,2 do
    local initial=workspace.preview().specs[i]
    assert(initial.gear and initial.gear.chest==(initial.class=='warlock' and 14153 or 14152),
        'Both starting fighters should have Pre-BiS gear')
end
editor.setClass('warlock');draw()
local label=assert(labels.Gear);workspace.mousepressed(70,label.y+5,1);draw()
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
label=assert(labels.Gear);workspace.mousepressed(70,label.y+5,1);draw()
click(controls['Pre-BiS']);draw()
assert(workspace.preview().specs[2].gear.chest==14152)
assert(workspace.preview().specs[1].gear.head==a.gear.head)
-- Race changes through the real header menu preserve the other player's draft.
local raceA=assert(dropdowns.race_1)
assert(raceA.x==dropdowns.class_1.x+dropdowns.class_1.w+4)
click(raceA)
local raceBounds=assert(ui.dropdownBounds())
ui.dropdownMousepressed(raceBounds.x+20,raceBounds.y+4+2.5*raceBounds.row,1)
draw()
assert(workspace.preview().specs[1].race=='orc')
assert(workspace.preview().specs[2].race=='human')
editor.setRace('troll');draw()
assert(workspace.preview().specs[2].race=='troll')
local saved=editor.getCurrentSpecConfig()
editor.setRace('human');editor.loadSpec(saved)
assert(editor.getCurrentSpecConfig().race=='troll')
editor.setClass('warlock')
assert(editor.getCurrentSpecConfig().race=='troll')
editor.loadSpec(saved);draw()
local launched
local old=generator.startFight
generator.startFight=function(cfg) launched=cfg;return true end
click(controls.Fight)
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
click(controls.Fight)
assert(launched.hp_a==2670 and launched.spec_a_obj.combat_stats.shadow_power==354)
assert(launched.spec_a_obj.gear==nil)
for _,path in ipairs(launched.temporary_specs) do os.remove(path) end
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
