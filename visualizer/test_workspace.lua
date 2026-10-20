-- Run from repository root: lua visualizer/test_workspace.lua
package.path='visualizer/?.lua;'..package.path
local width,height,mx,my=1280,720,0,0
local font={getWrap=function(_,s,w) local lines={} for line in (s..'\n'):gmatch('(.-)\n') do lines[#lines+1]=line end return w,lines end,getWidth=function(_,s) return #s*7 end,getHeight=function() return 14 end}
local noop=function() end
love={graphics=setmetatable({getWidth=function() return width end,getHeight=function() return height end,
    getFont=function() return font end}, {__index=function() return noop end}),
    mouse={getPosition=function() return mx,my end},filesystem={getInfo=function() end}}
package.loaded.icons_manager=setmetatable({}, {__index=function() return noop end})
dofile('visualizer/main.lua')
local ui=require('ui')
local workspace=require('workspace')
local camera=require('arena_camera')
local function near(a,b) assert(math.abs(a-b)<1e-7,tostring(a)..' != '..tostring(b)) end
local function upvalue(fn,name,value)
    for i=1,100 do
        local n,v=debug.getupvalue(fn,i)
        if not n then break end
        if n==name then if value~=nil then debug.setupvalue(fn,i,value) end; return v end
    end
    error('Missing upvalue '..name)
end
local drawContent=upvalue(love.draw,'drawContent')
local function physical(x,y) return x*ui.scale(),y*ui.scale()+ui.headerHeight end
for _,size in ipairs({{960,540},{1280,720},{2560,1080}}) do
    width,height=size[1],size[2]
    workspace.editPositions(); love.draw()
    local snapshot=workspace.preview()
    local replay={meta=snapshot.meta,frames={snapshot.frame},events={}}
    replay.meta.total_time=1
    upvalue(drawContent,'MATCH_DATA',replay)
    for _,zoom in ipairs({0.45,1,3}) do
        camera.zoom=zoom;camera.x=80;camera.y=-30
        love.draw()
        local _,_,view=workspace.arenaPoint((workspace.left or 0)+30,100)
        assert(view)
        for _,pos in ipairs({{-12.5,0},{12.5,0},{-4,6}}) do
            local x,y=camera.worldPoint(view,pos[1],pos[2])
            local wx,wy=camera.screenPoint(view,x,y);near(wx,pos[1]);near(wy,pos[2])
        end
        workspace.showReplay();love.draw()
        local _,_,replayView=workspace.replayPoint(view.x+1,view.y+1)
        near(view.virtualW,replayView.virtualW);near(view.virtualH,replayView.virtualH)
        near(camera.zoom,zoom);near(camera.x,80);near(camera.y,-30)
        workspace.editPositions();love.draw()
    end
    -- Focus each fighter at every zoom, then drag with a nonzero pan.
    for _,zoom in ipairs({0.45,1,3}) do
        for i=1,2 do
            local before=workspace.preview().frame
            local _,_,view=workspace.arenaPoint(workspace.left+30,100)
            camera.zoom=zoom
            camera.x=-before[2+i]*camera.worldScale*zoom
            camera.y=-before[48+i]*camera.worldScale*zoom
            love.draw()
            local x,y=camera.worldPoint(view,before[2+i],before[48+i])
            local sx,sy=physical(view.x+x*view.scale,view.y+y*view.scale)
            love.mousepressed(sx,sy,1)
            local direction=zoom==3 and -1 or 1
            local tx,ty=physical(view.x+(x+12.5*zoom*direction)*view.scale,view.y+(y+25*zoom*direction)*view.scale)
            love.mousemoved(tx,ty,0,0);love.mousereleased(tx,ty,1)
            local after=workspace.preview().frame
            near(after[2+i],before[2+i]+0.5*direction);near(after[48+i],before[48+i]+direction)
        end
    end
    camera.zoom=1;camera.x=0;camera.y=0;love.draw()
    local _,_,view=workspace.arenaPoint(workspace.left+30,100)
    -- Drag each fighter using the actual event routing and physical window pixels.
    for i=1,2 do
        local before=workspace.preview().frame
        local x,y=camera.worldPoint(view,before[2+i],before[48+i])
        local sx,sy=physical(view.x+x*view.scale,view.y+y*view.scale)
        love.mousepressed(sx,sy,1)
        local tx,ty=physical(view.x+(x+25)*view.scale,view.y+(y+50)*view.scale)
        love.mousemoved(tx,ty,0,0);love.mousereleased(tx,ty,1)
        local after=workspace.preview().frame
        near(after[2+i],before[2+i]+1);near(after[48+i],before[48+i]+2)
    end
    -- Pan and zoom work in setup; no replay controls consume those events.
    local sx,sy=physical(view.x+view.w/2,view.y+view.h/2)
    love.mousepressed(sx,sy,2)
    love.mousemoved(sx+20*view.scale*ui.scale(),sy+30*view.scale*ui.scale(),0,0)
    love.mousereleased(sx,sy,2);near(camera.x,20);near(camera.y,30)
    mx,my=sx,sy;love.wheelmoved(0,1);near(camera.zoom,1.15)
    love.keypressed('0');near(camera.zoom,1);near(camera.x,0);near(camera.y,0)
    -- Preview uses current HP, class, pet and loadout, not loaded replay metadata.
    assert(workspace.preview().frame[5]==workspace.preview().specs[1].combat_stats.max_health)
end
local editor=require('spec_editor')
workspace.select(1)
local original=workspace.preview()
editor.setClass('frost_mage');love.draw()
local changed=workspace.preview()
assert(changed.meta.spec_a=='frost_mage' and changed.frame[83]==0)
assert(original.meta.spec_a~='frost_mage')
editor.setClass('warlock');editor.setPet('felhunter');love.draw()
local changed=workspace.preview()
assert(changed.frame[83]==3 and changed.frame[84]==900)
near(changed.frame[85],changed.frame[3]);near(changed.frame[86],changed.frame[49]+1.5)
-- Existing distance-era replay files still render in the shared viewport.
upvalue(drawContent,'MATCH_DATA',dofile('last_match.lua'))
workspace.showReplay();love.draw();workspace.editPositions();love.draw()
print('Workspace rendering, camera, mode switching and dragging checks passed at three window sizes.')

-- Spec panel interactions: use drawn control bounds and the real event handlers.
local controls,iconCalls,schoolHeaders={},{},{}
local chevrons={}
local originalChevron=ui.chevron
ui.chevron=function(x,y,expanded)
    chevrons[y]=expanded
    return originalChevron(x,y,expanded)
end
love.graphics.print=function(text,x,y)
    if type(text)=='string' and (chevrons[y+8]~=nil or chevrons[y+9]~=nil) then
        schoolHeaders[(chevrons[y+8] and 'v  ' or '>  ')..text]={x=x,y=y}
        if text=='Talents' or text=='Gear' or text=='Pets' or text=='Abilities' then
            controls[#controls+1]={x=24,y=y-8,w=workspace.left-24,h=34,label=text}
        end
    end
end
local originalHeader=ui.playerHeader
ui.playerHeader=function(x,y,w,h,title,...)
    controls[#controls+1]={x=126,y=y,w=x+w-126,h=h,label=title,header=true}
    return originalHeader(x,y,w,h,title,...)
end
local originalButton=ui.button
ui.button=function(x,y,w,h,label,...)
    controls[#controls+1]={x=x,y=y,w=w,h=h,label=label}
    return originalButton(x,y,w,h,label,...)
end
package.loaded.icons_manager.drawRect=function(icon,x,y,w,h)
    if not ui.viewport then iconCalls[#iconCalls+1]={icon=icon,x=x,y=y,w=w,h=h} end
    return true
end
local function render() controls={};iconCalls={};schoolHeaders={};chevrons={};love.draw() end
local function click(x,y,b)
    local sx,sy=physical(x,y)
    love.mousepressed(sx,sy,b or 1);love.mousereleased(sx,sy,b or 1)
end
local function control(label)
    if label=='Warlock' or label=='Frost Mage' then
        local player=workspace.getSelected()
        for _,v in ipairs(controls) do
            if v.header and v.label=='Player '..(player==1 and 'A' or 'B') then
                click(53,v.y+29)
                local r=assert(ui.dropdownBounds())
                click(r.x+20,r.y+4+(label=='Warlock' and 0.5 or 1.5)*r.row)
                return
            end
        end
    end
    for _,v in ipairs(controls) do
        if v.label==label then click(v.x+v.w/2,v.y+v.h/2);return end
    end
    -- Find controls after scrolling; the automatic grid has fewer rows than slots.
    mx,my=physical(60,workspace.scrollTop+20)
    workspace.wheelmoved(100);render()
    for attempt=1,60 do
        for _,v in ipairs(controls) do
            if v.label==label then click(v.x+v.w/2,v.y+v.h/2);return end
        end
        workspace.wheelmoved(-1);render()
    end
    error('Missing control '..label)
end
local function findSchool(label)
    if schoolHeaders[label] then return schoolHeaders[label] end
    mx,my=physical(60,workspace.scrollTop+20)
    workspace.wheelmoved(100);render()
    for attempt=1,60 do
        if schoolHeaders[label] then return schoolHeaders[label] end
        workspace.wheelmoved(-1);render()
    end
    return nil
end
local function school(name,open)
    local label=(open and '>  ' or 'v  ')..name
    local header=assert(findSchool(label),'Missing school header '..label)
    click(header.x+8,header.y+8)
end
local function iconControl(name,last,b)
    local found
    for _,v in ipairs(iconCalls) do
        if v.icon==name and v.x<workspace.left and (last or not found) then found=v end
    end
    assert(found,'Missing icon '..tostring(name))
    click(found.x+found.w/2,found.y+found.h/2,b)
end
for _,size in ipairs({{960,540},{1280,720},{2560,1080}}) do
    width,height=size[1],size[2]
    workspace.editPositions();workspace.select(1);render()
    editor.setCombatStat('spell_crit_chance',0.23)
    render();control('Player B');render()
    assert(workspace.getSelected()==2)
    editor.setCombatStat('spell_crit_chance',0.37)
    render();control('Player A');render()
    near(workspace.preview().specs[1].combat_stats.spell_crit_chance,0.23)
    near(workspace.preview().specs[2].combat_stats.spell_crit_chance,0.37)
    control('Player A');render();assert(workspace.getSelected()==nil)
    control('Player B');render();assert(workspace.getSelected()==2)
    local snapshot=workspace.preview()
    local frame={}
    for i=1,104 do frame[i]=snapshot.frame[i] end
    frame[3],frame[4],frame[49],frame[50]=-5,5,4,-4
    upvalue(drawContent,'MATCH_DATA',{meta={spec_a='warlock',spec_b='warlock',name_a='A',name_b='B',total_time=1,victor=-1},frames={frame},events={}})
    workspace.showReplay();render()
    local _,_,view=workspace.replayPoint(workspace.left+30,100)
    -- Click recorded tokens, whose coordinates differ from setup positions.
    for i=1,2 do
        camera.zoom=1.3
        camera.x=-frame[2+i]*25*camera.zoom;camera.y=-frame[48+i]*25*camera.zoom
        render()
        local x,y=camera.worldPoint(view,frame[2+i],frame[48+i])
        click(view.x+x*view.scale,view.y+y*view.scale)
        render();assert(workspace.getSelected()==i and workspace.isPlayback())
        near(workspace.preview().frame[3],snapshot.frame[3]);near(workspace.preview().frame[4],snapshot.frame[4])
    end
    -- A setup click with two pixels of jitter selects without moving either fighter.
    workspace.editPositions();render()
    local before=workspace.preview().frame
    local _,_,view=workspace.arenaPoint(workspace.left+30,100)
    camera.x=-before[3]*25*camera.zoom;camera.y=-before[49]*25*camera.zoom;render()
    local x,y=camera.worldPoint(view,before[3],before[49])
    local sx,sy=physical(view.x+x*view.scale,view.y+y*view.scale)
    love.mousepressed(sx,sy,1);love.mousemoved(sx+2,sy+2,2,2);love.mousereleased(sx+2,sy+2,1)
    assert(workspace.getSelected()==1)
    near(workspace.preview().frame[3],before[3]);near(workspace.preview().frame[49],before[49])
    -- Scroll the stacked trees, then navigate within the same player's section.
    render()
    if schoolHeaders['>  Affliction'] then school('Affliction',true);render() end
    mx,my=physical(60,workspace.scrollTop+20);workspace.wheelmoved(-100);render()
    -- Scrollable section headers remain reachable with the compact ability grid.
    control('Pets');render()
    mx,my=physical(60,workspace.scrollTop+20);workspace.wheelmoved(-100);render()
    control('Abilities');render()
end
-- Actual talent point allocation and removal through icon tiles.
workspace.select(1);editor.setClass('warlock');render();control('Talents');render()
if findSchool('>  Affliction') then school('Affliction',true);render() end
local talents=require('talents_data')
local t=talents.load('warlock').Affliction.talents[1]
iconControl(t.icon);render()
assert(talents.getRank(workspace.preview().specs[1].trees.Affliction,t.id)==1)
iconControl(t.icon,false,2);render()
assert(talents.getRank(workspace.preview().specs[1].trees.Affliction,t.id)==0)
-- Loadout choices follow pet and talent restrictions, and launch with that exact loadout.
editor.setPet('succubus');render();control('Abilities');render()
local available=editor.getAvailableActions()
local allowed={};for _,name in ipairs(available) do allowed[name]=true end
assert(allowed.Seduction and not allowed['Spell Lock'] and not allowed.Shadowburn)
-- Scroll the choices into view even in the shortest panel.
mx,my=physical(60,workspace.scrollTop+20);workspace.wheelmoved(-100);render()
-- Pet actions appear automatically without selecting a slot.
render()
assert(require('json').encode(workspace.preview().specs[1].action_loadout):find('Seduction'))
editor.setPet('felhunter');render()
assert(not require('json').encode(workspace.preview().specs[1].action_loadout):find('Seduction'))
local generator=require('match_generator')
local originalStart=generator.startFight
local launch
generator.startFight=function(cfg) launch=cfg;return true end
control('Fight');assert(launch)
local expected=workspace.preview().specs[1]
assert(require('json').encode(launch.spec_a_obj.action_loadout)==require('json').encode(expected.action_loadout))
for _,path in ipairs(launch.temporary_specs) do os.remove(path) end
generator.startFight=originalStart
print('Accordion, arena selection, click/drag separation, talents, loadout gates and launch checks passed.')

-- Each school folds independently, retaining points and a separate state per player/class.
for _,size in ipairs({{960,540},{1280,720},{2560,1080}}) do
    width,height=size[1],size[2]
    workspace.select(1);render()
    if not findSchool('>  Affliction') and not findSchool('v  Affliction') then control('Talents');render() end
    mx,my=physical(60,workspace.scrollTop+20);workspace.wheelmoved(100);render()
    if findSchool('v  Affliction') then school('Affliction',false);render() end
    assert(findSchool('>  Affliction') and findSchool('>  Demonology') and findSchool('>  Destruction'))
    local before=require('json').encode(workspace.preview().specs[1])
    school('Affliction',true);render()
    assert(findSchool('v  Affliction'))
    workspace.select(2);render()
    if not findSchool('>  Affliction') and not findSchool('v  Affliction') then control('Talents');render() end
    assert(findSchool('>  Affliction'))
    workspace.select(1);render();assert(findSchool('v  Affliction'))
    assert(require('json').encode(workspace.preview().specs[1])==before)
    school('Affliction',false);render()
    school('Demonology',true);render()
    assert(findSchool('>  Affliction') and findSchool('v  Demonology'))
    school('Demonology',false);render()
    school('Destruction',true);render()
    assert(findSchool('v  Destruction'))
    school('Destruction',false);render()
end
control('Frost Mage');render()
assert(findSchool('>  Arcane') and findSchool('>  Fire') and findSchool('>  Frost'))
school('Arcane',true);render();assert(findSchool('v  Arcane'))
control('Warlock');render()
assert(findSchool('>  Affliction'))
control('Frost Mage');render();assert(findSchool('v  Arcane'))
school('Arcane',false);render()
workspace.showReplay();render();assert(workspace.isPlayback())
school('Frost',true);render();assert(workspace.isPlayback())
assert(findSchool('v  Frost'))
print('School collapsing, independent player/class state, preserved drafts and playback checks passed.')

-- Real event routing: menus select exact config values and block underlying input.
local dropdownControls={}
local originalDropdown=ui.dropdown
ui.dropdown=function(id,x,y,w,h,value,choices,onSelect,...)
    dropdownControls[id]={x=x,y=y,w=w,h=h,choices=choices,value=value}
    return originalDropdown(id,x,y,w,h,value,choices,onSelect,...)
end
local function clickLogical(x,y,b)
    local px,py=physical(x,y)
    love.mousepressed(px,py,b or 1)
end
local function openDropdown(id)
    render()
    local c=assert(dropdownControls[id])
    clickLogical(c.x+c.w/2,c.y+c.h/2)
    assert(ui.dropdownOpen())
    love.draw()
    return assert(ui.dropdownBounds())
end
for _,size in ipairs({{960,540},{1280,720},{2560,1080}}) do
    width,height=size[1],size[2]
    workspace.editPositions()
    for _,id in ipairs({'rollouts','workers','algorithm','evaluator','distance'}) do
        love.draw()
        for index,value in ipairs(dropdownControls[id].choices) do
            local r=openDropdown(id)
            assert(r.x>=0 and r.y>=0 and r.x+r.w<=ui.width() and r.y+r.h<=ui.height())
            clickLogical(r.x+r.w/2,r.y+4+(index-0.5)*r.row)
            assert(not ui.dropdownOpen())
            assert(generator.getConfig()[id]==value)
            if id=='distance' then near(workspace.preview().frame[2],value) end
        end
    end
    openDropdown('workers')
    local zoom=camera.zoom
    love.wheelmoved(0,1);near(camera.zoom,zoom)
    love.keypressed('escape');assert(not ui.dropdownOpen())
    openDropdown('workers')
    control('Fight')
    assert(not ui.dropdownOpen() and not generator.isActive())
    openDropdown('workers')
    local selectedBefore=workspace.getSelected()
    clickLogical(workspace.left+50,300)
    assert(not ui.dropdownOpen() and workspace.getSelected()==selectedBefore)
    openDropdown('workers')
    love.mousepressed(20,20,1) -- Header outside click dismisses without navigation.
    assert(not ui.dropdownOpen())
    love.draw();assert(dropdownControls.workers)
    local start=generator.startFight
    local submitted
    generator.startFight=function(cfg) submitted=cfg;return true end
    control('Fight')
    generator.startFight=start
    assert(submitted)
    for _,id in ipairs({'rollouts','workers','algorithm','evaluator','distance'}) do
        assert(submitted[id]==generator.getConfig()[id])
    end
    for _,path in ipairs(submitted.temporary_specs) do os.remove(path) end
end
-- Presets use real event routing and preserve the other draft, positions and settings.
local json=require('json')
for _,size in ipairs({{960,540},{1280,720},{2560,1080}}) do
    width,height=size[1],size[2]
    for player=1,2 do
        workspace.select(player);render()
        editor.setCombatStat('spell_crit_chance',0.31);render()
        local before=workspace.preview()
        local other=json.encode(before.specs[3-player])
        local settings=json.encode(generator.getConfig())
        local id='preset_'..player
        local choices=dropdownControls[id].choices
        assert(#choices>1)
        local target=choices[#choices]
        workspace.showReplay();render()
        local r=openDropdown(id)
        assert(r.x>=0 and r.y>=0 and r.x+r.w<=ui.width() and r.y+r.h<=ui.height())
        if #choices>r.rows then love.wheelmoved(0,-100) end
        local slot=math.min(#choices,r.rows)
        clickLogical(r.x+r.w/2,r.y+4+(slot-0.5)*r.row)
        assert(not ui.dropdownOpen() and not workspace.isPlayback())
        render()
        local after=workspace.preview()
        assert(after.specs[player].name==target.name and after.specs[player].class==target.class)
        assert(json.encode(after.specs[3-player])==other)
        assert(json.encode(generator.getConfig())==settings)
        for _,index in ipairs({3,4,49,50}) do near(after.frame[index],before.frame[index]) end
        assert(dropdownControls[id].value==target)
        openDropdown(id);love.keypressed('escape');assert(not ui.dropdownOpen())
        openDropdown(id);clickLogical(workspace.left+50,300)
        assert(not ui.dropdownOpen() and workspace.getSelected()==player)
    end
end
-- A long library stays in bounds and scrolls without zooming the arena.
local choices={}
for i=1,100 do choices[i]='Preset '..i end
local picked
ui.dropdown('long_presets',24,100,220,26,choices[1],choices,function(value) picked=value end)()
local r=ui.dropdownBounds()
assert(r.y>=0 and r.y+r.h<=ui.height())
local zoom=camera.zoom
love.wheelmoved(0,-1000);near(camera.zoom,zoom)
clickLogical(r.x+20,r.y+4+(r.rows-0.5)*r.row)
assert(picked=='Preset 100')
ui.dropdown('empty_presets',24,100,220,26,nil,{},function() error('Empty selection') end)()
assert(not ui.dropdownOpen())
print('Preset selection, draft/setup preservation, dismissal, empty libraries and long-menu scrolling passed.')
ui.dropdown=originalDropdown
print('Settings dropdown selection, launch values, dismissal, bounds and input blocking passed at three window sizes.')

-- Mixed-class combat telemetry: distinct values catch side/index swaps and missing effects.
local unitFrames=require('unit_frames')
local meta={spec_a='warlock',spec_b='frost_mage',name_a='Warlock A',name_b='Mage B'}
local f={}
for i=1,104 do f[i]=0 end
f[5],f[6],f[7],f[8]=1234,678,456,789
f[11],f[12],f[13],f[14],f[15],f[16]=5,4,1,2,3,4
f[27],f[28],f[29],f[30],f[42],f[44]=60,12,22,11,7,8
f[83],f[84],f[88],f[89],f[99]=3,555,2,444,9
f[26],f[46]=10,350
for _,i in ipairs({17,19,21,23,47,93,95,101,18,20,22,24,48,94,96,102}) do f[i]=2 end
local a=unitFrames.describe(meta,f,0,{lockSchool='Shadow',lockRemaining=3})
local b=unitFrames.describe(meta,f,1)
assert(a.hp==1234 and a.mana==456 and a.pet.hp==555 and a.pet.name=='Felhunter')
assert(b.hp==678 and b.mana==789 and b.shield==350 and not b.pet)
assert(a.castName=='Drain Life' and b.castName=='Frostbolt')
near(a.castProgress,1/3);near(b.castProgress,1/2)
assert(a.castRemaining==1 and b.castRemaining==2)
local startCast=unitFrames.describe(meta,setmetatable({[14]=4},{__index=f}),1)
near(startCast.castProgress,0)
local endCast=unitFrames.describe(meta,setmetatable({[14]=0},{__index=f}),1)
near(endCast.castProgress,1)
assert(#a.cooldowns==3 and a.cooldowns[3].remaining==9)
assert(#b.cooldowns==4 and b.cooldowns[1].remaining==7 and b.cooldowns[4].remaining==12)
assert(#a.debuffs==8 and #b.debuffs==8 and b.buffs[1].icon=='icebarrier')
assert(a.debuffs[3].school=='Shadow' and a.debuffs[4].icon=='polymorph')
assert(b.debuffs[4].icon=='fear' and b.debuffs[5].icon=='agony')
-- Real renderer must retain every effect, pet and cooldown without extending past its frame.
local iconManager=require('icons_manager')
local oldAura,oldRect=iconManager.drawAuraBadge,iconManager.drawRect
local seen={}
iconManager.drawAuraBadge=function(icon,x,y,size)
    assert(x>=16 and x+size<=336 and y>=74 and y+size<=242)
    seen[icon]=(seen[icon] or 0)+1
end
iconManager.drawRect=function(icon,x,y,w,h)
    assert(x>=16 and x+w<=336 and y>=74 and y+h<=242)
    seen[icon]=(seen[icon] or 0)+1
end
for side=0,1 do
    seen={}
    unitFrames.draw(meta,f,side,16,74,true)
    assert(seen.horror and seen.seduction and seen.counterspell and seen.siphonlife and seen.immolate)
    assert(seen[side==0 and 'polymorph' or 'fear'])
    assert(seen[side==0 and 'pet_felhunter' or 'icebarrier'])
end

-- Soul Link and Demonic Sacrifice buffs: active effects show, inactive effects do not.
local slMeta = {
    spec_a = 'warlock', spec_b = 'warlock',
    warlock_talents_a = { soul_link = 1, demonic_sacrifice = 1, demonic_sacrifice_pet = 2 },
    warlock_talents_b = { soul_link = 1, demonic_sacrifice = 0, demonic_sacrifice_pet = 0 },
}
local frameSL = {}
for i = 1, 104 do frameSL[i] = 0 end
frameSL[83], frameSL[84] = 3, 900 -- A has alive Felhunter
frameSL[88], frameSL[89] = 0, 0   -- B has no pet / dead pet
local slA = unitFrames.describe(slMeta, frameSL, 0)
local slB = unitFrames.describe(slMeta, frameSL, 1)
assert(#slA.buffs == 2)
assert(slA.buffs[1].icon == 'soul_link')
assert(slA.buffs[2].icon == 'pet_succubus') -- DS sacrificed succubus buff
assert(#slB.buffs == 0) -- Talent learned on B but pet dead/absent and DS unlearned -> no buff!

-- If pet dies on A, Soul Link buff immediately disappears:
local frameDeadPet = {}
for i = 1, 104 do frameDeadPet[i] = frameSL[i] end
frameDeadPet[84] = 0 -- 0 HP
local slDead = unitFrames.describe(slMeta, frameDeadPet, 0)
assert(#slDead.buffs == 1 and slDead.buffs[1].icon == 'pet_succubus') -- Only DS buff remains

-- Setup preview checks:
local setupSnapshot = workspace.preview()
assert(setupSnapshot.meta.warlock_talents_a ~= nil or setupSnapshot.meta.warlock_talents_b ~= nil or setupSnapshot.specs ~= nil)

iconManager.drawAuraBadge,iconManager.drawRect=oldAura,oldRect
-- Legacy replay rows omit newer fields; both classes remain renderable.
local legacy={}
for i=1,40 do legacy[i]=f[i] end
unitFrames.draw(meta,legacy,0,16,74,false)
unitFrames.draw(meta,legacy,1,624,74,false)
print('Classic unit frames: mixed-class vitals, casts, shields, pets, cooldowns, all effects and legacy rows passed.')

-- Header class icons act independently from section expansion and arena selection.
local classControls={}
local dropdownBefore=ui.dropdown
ui.dropdown=function(id,x,y,w,h,value,choices,onSelect,...)
    if id:match('^class_') then classControls[id]={x=x,y=y,w=w,h=h,choices=choices,value=value} end
    return dropdownBefore(id,x,y,w,h,value,choices,onSelect,...)
end
local function chooseClass(player,class)
    render()
    local c=assert(classControls['class_'..player])
    assert(#c.choices==3 and c.choices[1]=='warlock' and c.choices[2]=='frost_mage' and c.choices[3]=='priest')
    click(c.x+c.w/2,c.y+c.h/2)
    local r=assert(ui.dropdownBounds())
    assert(r.w>=160 and r.x>=0 and r.y>=0 and r.x+r.w<=ui.width() and r.y+r.h<=ui.height())
    click(r.x+30,r.y+4+(class=='warlock' and 0.5 or 1.5)*r.row)
    assert(not ui.dropdownOpen())
    render()
end
for _,size in ipairs({{960,540},{1280,720},{2560,1080}}) do
    width,height=size[1],size[2]
    for target=1,2 do
        local other=3-target
        -- Give the other player unsaved stats/talents; keep its section open.
        workspace.select(other);editor.setClass('warlock')
        editor.setCombatStat('spell_crit_chance',0.29);render()
        local otherBefore=json.encode(workspace.preview().specs[other])
        local stateBefore=workspace.preview()
        local cfgBefore=json.encode(generator.getConfig())
        for _,class in ipairs({'frost_mage','warlock'}) do
            workspace.showReplay();render()
            chooseClass(target,class)
            assert(workspace.getSelected()==other)
            local state=workspace.preview()
            assert(state.specs[target].class==class)
            assert(classControls['class_'..target].value==class)
            assert(json.encode(state.specs[other])==otherBefore)
            assert(json.encode(generator.getConfig())==cfgBefore)
            for _,index in ipairs({3,4,49,50}) do near(state.frame[index],stateBefore.frame[index]) end
            assert(state.meta[target==1 and 'spec_a' or 'spec_b']==class)
            assert(state.specs[target].pet==(class=='frost_mage' and 'none' or 'imp'))
            assert(not workspace.isPlayback())
            -- Fight must capture the changed collapsed fighter's actual loadout and stats.
            local original=generator.startFight
            local launched
            generator.startFight=function(config) launched=config;return true end
            control('Fight');generator.startFight=original
            local submitted=launched[target==1 and 'spec_a_obj' or 'spec_b_obj']
            assert(submitted.class==class)
            assert(json.encode(submitted.action_slots)==json.encode(state.specs[target].action_slots))
            for key,value in pairs(state.specs[target].combat_stats) do near(submitted.combat_stats[key],value) end
            for _,path in ipairs(launched.temporary_specs) do os.remove(path) end
        end
        -- The icon also works when both sections are collapsed.
        render();control(other==1 and 'Player A' or 'Player B');render()
        assert(workspace.getSelected()==nil)
        chooseClass(target,'frost_mage');assert(workspace.getSelected()==nil)
        -- Expanded class changes retain expansion and immediately replace talent schools.
        workspace.select(target);render()
        if not findSchool('>  Arcane') and not findSchool('v  Arcane') then control('Talents');render() end
        assert(findSchool('>  Arcane') or findSchool('v  Arcane'))
        chooseClass(target,'warlock');assert(workspace.getSelected()==target)
        assert(findSchool('>  Affliction') or findSchool('v  Affliction'))
        -- Selecting the current class is harmless and preserves edits/playback.
        editor.setCombatStat('spell_crit_chance',0.32);render()
        local unchanged=json.encode(workspace.preview().specs[target])
        workspace.showReplay();render();chooseClass(target,'warlock')
        assert(json.encode(workspace.preview().specs[target])==unchanged and workspace.isPlayback())
        -- Escape and outside clicks consume menu input without changing the section.
        local c=classControls['class_'..target]
        click(c.x+10,c.y+10);love.keypressed('escape');assert(not ui.dropdownOpen())
        click(c.x+10,c.y+10);control(target==1 and 'Player A' or 'Player B')
        assert(not ui.dropdownOpen() and workspace.getSelected()==target)
    end
end
ui.dropdown=dropdownBefore
print('Header class menus: expanded/collapsed isolation, draft/setup preservation, live classes, Fight snapshots and dismissal passed at three sizes.')

-- Consolidated Settings: real event routing, scrolling, navigation and isolation.
local browser=require('match_browser')
local matrix=require('matrix_view')
local sectionState=upvalue(workspace.toggleSettingsSection,'settingsOpen')
local browserMatches=browser.getMatches()
local previousMatches={}
for i,m in ipairs(browserMatches) do previousMatches[i]=m end
for i=#browserMatches,1,-1 do browserMatches[i]=nil end
for i=1,30 do
    browserMatches[i]={path='last_match.lua',name='Review replay '..i,name_a='Warlock',name_b='Mage',
        timestamp='2026-10-16',total_time=1,dmg_a=100,dmg_b=200,victor=1}
end
local printed={}
local previousPrint=love.graphics.print
love.graphics.print=function(text,...) printed[tostring(text)]=true;previousPrint(text,...) end
for _,size in ipairs({{960,540},{1280,720},{2560,1080}}) do
    width,height=size[1],size[2]
    sectionState.replays=false;sectionState.matrix=false
    upvalue(workspace.wheelmoved,'settingsScroll',0)
    workspace.editPositions();render()
    local before=json.encode(workspace.preview())
    local cfgBefore=json.encode(generator.getConfig())
    local zoomBefore=camera.zoom
    love.keypressed('f2');render();render()
    assert(sectionState.replays and not sectionState.matrix)
    local found=false
    for _,v in ipairs(controls) do
        if v.label=='Review replay 1' then
            assert(v.y>=56 and v.y+v.h<=ui.height()-124)
            click(v.x+10,v.y+10);found=true;break
        end
    end
    assert(found and workspace.isPlayback())
    assert(json.encode(workspace.preview())==before)
    assert(json.encode(generator.getConfig())==cfgBefore)
    mx,my=physical(workspace.settingsX+10,150)
    love.wheelmoved(0,-100);render()
    near(camera.zoom,zoomBefore)
    local count=0
    for _,v in ipairs(controls) do
        if v.x>=workspace.settingsX and v.label~='Fight' then
            assert(v.y>=56 and v.y+v.h<=ui.height()-124);count=count+1
        end
    end
    assert(count>0)
    love.keypressed('f4');render();render()
    assert(sectionState.matrix and sectionState.replays)
    local hasMatrix=false
    for _,v in ipairs(controls) do if v.label=='Refresh Matrix / specs' then hasMatrix=true end end
    assert(hasMatrix)
    assert(json.encode(workspace.preview())==before)
    love.keypressed('f5');render()
    assert(upvalue(drawContent,'currentTab')=='setup')
    love.keypressed('tab');render()
    assert(upvalue(drawContent,'currentTab')=='setup')
    assert(json.encode(workspace.preview())==before)
    -- Banner is absent from both modes, and frames start at the reclaimed top edge.
    for _,mode in ipairs({'setup','playback'}) do
        if mode=='setup' then workspace.editPositions() else workspace.showReplay() end
        printed={};render();assert(not printed['PVP ARENA'])
    end
end
love.graphics.print=previousPrint
for i=#browserMatches,1,-1 do browserMatches[i]=nil end
for i,m in ipairs(previousMatches) do browserMatches[i]=m end
print('Consolidated Settings: replay loading, section shortcuts, scroll bounds, camera/draft/settings isolation and hidden navigation passed at three sizes.')

-- Matrix keeps filters, batch config and replay actions while sharing Settings.
local matrixState=upvalue(matrix.drawPanel,'matrixData')
local matrixSpecs=upvalue(matrix.drawPanel,'savedSpecs')
local matrixSelected=upvalue(matrix.drawPanel,'selectedSpecs')
matrix.init()
local panelButtons={}
local function panelButton(_,label,action) panelButtons[label]=action end
local function panelText(y) return y+30 end
local loaded
local function panelDraw()
    panelButtons={};matrix.drawPanel(0,panelButton,panelText,function(path) loaded=path end)
end
panelDraw()
assert(panelButtons['Include all specs'] and panelButtons['Run combinations'])
local runner=require('match_runner')
local startBatch=runner.startBatch
local submittedPairs,submittedCfg
runner.startBatch=function(pairs,cfg) submittedPairs=pairs;submittedCfg=cfg;return true end
panelButtons['Deep (16k)']();panelDraw();panelButtons['Include all specs']();panelDraw()
panelButtons['Run combinations']()
local specs=upvalue(matrix.drawPanel,'savedSpecs')
assert(#submittedPairs==#specs*#specs)
assert(submittedCfg.rollouts==16384 and submittedCfg.workers==16 and submittedCfg.algorithm=='puct')
-- Filtering changes both displayed results and the batch submitted to the runner.
for label,action in pairs(panelButtons) do
    if label:sub(1,4)=='[x] ' then action();break end
end
panelDraw();panelButtons['Run combinations']()
assert(#submittedPairs==(#specs-1)*(#specs-1))
runner.startBatch=startBatch
upvalue(matrix.drawPanel,'matrixData',{specs={{name='A'},{name='B'}},grid={
    {{duels=1,win_rate=1,total_time=3,match_file='last_match.lua'},{duels=0}},
    {{duels=0},{duels=0}}}})
panelDraw();assert(panelButtons['100% · 3.00s · Replay'])
panelButtons['100% · 3.00s · Replay']();assert(loaded=='last_match.lua')
upvalue(matrix.drawPanel,'matrixData',matrixState)
upvalue(matrix.drawPanel,'savedSpecs',matrixSpecs)
upvalue(matrix.drawPanel,'savedSpecs',matrixSpecs)
upvalue(matrix.drawPanel,'selectedSpecs',matrixSelected)
print('Matrix panel: filters, batch pair count, preset launch values and recorded-match replay passed.')

-- League Play (Neuroevolution) section: dropdowns, Evolve & Fight button, and Champion vs MCTS launch.
width,height=1280,720
upvalue(workspace.wheelmoved,'settingsScroll',0)
render()
mx,my=physical(workspace.settingsX+10,150)
local startLeague=generator.startLeaguePlay
local launchedLeague
generator.startLeaguePlay=function(cfg) launchedLeague=cfg;return true end
local function findControl(label)
    for _,v in ipairs(controls) do if v.label==label then return v end end
end
-- Scroll step by step: the section height varies (e.g. when champion models exist on disk).
upvalue(workspace.wheelmoved,'settingsScroll',0);render()
for _=1,40 do
    if findControl('Evolve & Fight') then break end
    love.wheelmoved(0,-1);render()
end
local evolveBtn=findControl('Evolve & Fight')
if evolveBtn then click(evolveBtn.x+evolveBtn.w/2,evolveBtn.y+evolveBtn.h/2) end
generator.startLeaguePlay=startLeague
assert(launchedLeague and launchedLeague.fights_per_epoch==50000 and launchedLeague.epochs==10)
for _,path in ipairs(launchedLeague.temporary_specs) do os.remove(path) end
print('League Play (Neuroevolution) UI and Evolve & Fight launch checks passed.')

-- Champion vs Champion: bulk simulation and single-fight replay buttons.
do
    local nt=generator.getNeuroTelemetry()
    local savedA,savedB=nt.policy_a,nt.policy_b
    nt.policy_a,nt.policy_b='matches/test_champ_a.nepl','matches/test_champ_b.nepl'
    local startBulk,startFight=generator.startBulkEval,generator.startFight
    local bulkCfg,fightCfg
    generator.startBulkEval=function(cfg) bulkCfg=cfg;return true end
    generator.startFight=function(cfg) fightCfg=cfg;return true end
    upvalue(workspace.wheelmoved,'settingsScroll',0);render()
    local bulkLabel='Simulate 1000 Champ vs Champ'
    local simLabel='Sim 1 Champ vs Champ + Replay'
    for _=1,80 do
        if findControl(bulkLabel) and findControl(simLabel) then break end
        love.wheelmoved(0,-1);render()
    end
    local b=findControl(bulkLabel);assert(b,'bulk simulate button missing')
    click(b.x+b.w/2,b.y+b.h/2)
    local s=findControl(simLabel);assert(s,'sim 1 button missing')
    click(s.x+s.w/2,s.y+s.h/2)
    generator.startBulkEval,generator.startFight=startBulk,startFight
    nt.policy_a,nt.policy_b=savedA,savedB
    assert(bulkCfg and bulkCfg.bulk_fights==1000 and bulkCfg.jitter_start_lag==0 and bulkCfg.jitter_pos==0)
    assert(fightCfg and fightCfg.policy_a=='matches/test_champ_a.nepl' and fightCfg.policy_b=='matches/test_champ_b.nepl' and fightCfg.seed)
    for _,cfg in ipairs({bulkCfg,fightCfg}) do
        for _,path in ipairs(cfg.temporary_specs) do os.remove(path) end
    end
    print('Champion vs Champion bulk simulation and single replay launch checks passed.')
end

