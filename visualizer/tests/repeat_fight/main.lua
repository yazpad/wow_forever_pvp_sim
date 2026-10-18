io.stdout:setvbuf('no')
-- From repository root: SDL_VIDEODRIVER=offscreen love visualizer/tests/repeat_fight
-- Runs the actual GUI event handlers, Love worker thread and ReleaseFast simulator.
local source=love.filesystem.getSource()
local root=assert(source:match('^(.*)/visualizer/tests/repeat_fight$'),'Run from repository root')
package.path=root..'/visualizer/?.lua;'..package.path
dofile(root..'/visualizer/main.lua')
local appLoad,appDraw,appUpdate=love.load,love.draw,love.update
local ui,workspace,editor,generator,camera,json,actions=require('ui'),require('workspace'),require('spec_editor'),
    require('match_generator'),require('arena_camera'),require('json'),require('action_catalog')
local output=os.tmpname()
os.remove(output)
output=output..'-workspace'
local controls,dropdowns={},{}
local header=ui.playerHeader
ui.playerHeader=function(x,y,w,h,label,...)
    controls[label]={x=x+60,y=y,w=w-60,h=h}
    return header(x,y,w,h,label,...)
end
local button,dropdown=ui.button,ui.dropdown
ui.button=function(x,y,w,h,label,...)
    if not ui.viewport then controls[label]=controls[label] or {x=x,y=y,w=w,h=h} end
    return button(x,y,w,h,label,...)
end
ui.dropdown=function(id,x,y,w,h,value,choices,...)
    dropdowns[id]={x=x,y=y,w=w,h=h,choices=choices}
    return dropdown(id,x,y,w,h,value,choices,...)
end
local function near(a,b) assert(math.abs(a-b)<0.001,tostring(a)..' ~= '..tostring(b)) end
local function copy(v) return json.decode(json.encode(v)) end
local function equal(a,b)
    if type(a)~=type(b) then return false end
    if type(a)=='number' then return math.abs(a-b)<1e-9 end
    if type(a)~='table' then return a==b end
    for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
local function render()
    controls={};dropdowns={}
    love.graphics.clear(love.graphics.getBackgroundColor())
    appDraw()
end
local function click(x,y,b)
    x,y=x*ui.scale(),y*ui.scale()+ui.headerHeight
    love.mousepressed(x,y,b or 1);love.mousereleased(x,y,b or 1)
end
local function press(label)
    render();local c=assert(controls[label],'Missing control: '..label)
    click(c.x+c.w/2,c.y+c.h/2)
end
local function choose(id,value)
    render();local c=assert(dropdowns[id],id)
    click(c.x+10,c.y+10);render()
    local bounds=assert(ui.dropdownBounds())
    for i,v in ipairs(c.choices) do
        if v==value then click(bounds.x+20,bounds.y+4+(i-0.5)*bounds.row);return end
    end
    error('Missing dropdown option')
end
local function drag(side,dx,dy)
    render()
    local frame=workspace.preview().frame
    local _,_,view=workspace.arenaPoint(workspace.left+30,100)
    local x,y=camera.worldPoint(view,frame[side+2],frame[side+48])
    local sx,sy=(view.x+x*view.scale)*ui.scale(),(view.y+y*view.scale)*ui.scale()+ui.headerHeight
    love.mousepressed(sx,sy,1)
    local tx,ty=sx+dx*25*camera.zoom*view.scale*ui.scale(),sy+dy*25*camera.zoom*view.scale*ui.scale()
    love.mousemoved(tx,ty,tx-sx,ty-sy);love.mousereleased(tx,ty,1)
    local after=workspace.preview().frame
    near(after[side+2],frame[side+2]+dx);near(after[side+48],frame[side+48]+dy)
end
local launches={}
local startFight=generator.startFight
generator.startFight=function(cfg)
    launches[#launches+1]=copy(cfg)
    -- Inspect unsaved snapshots before the real worker consumes/deletes them.
    for i,path in ipairs(cfg.temporary_specs) do
        local f=assert(io.open(path));local spec=json.decode(f:read('*a'));f:close()
        assert(equal(spec,workspace.preview().specs[i]))
    end
    return startFight(cfg)
end
local function verify(index)
    local launch=assert(launches[index])
    local replay=dofile(launch.output)
    local f=assert(io.open(launch.output..'.search.json'))
    local metadata=json.decode(f:read('*a'));f:close()
    local options=metadata.options
    assert(replay.frames and #replay.frames>1 and #replay.events>0)
    for i,side in ipairs({'a','b'}) do
        local spec=launch['spec_'..side..'_obj']
        assert(options[side]==spec.class)
        near(options['combat_stats_'..side].spell_crit_chance,spec.combat_stats.spell_crit_chance)
        local mask=2^0+2^10
        for _,name in ipairs(spec.action_loadout) do
            for id,n in pairs(actions.names_by_id[spec.class]) do
                if name==n then mask=mask+2^id;break end
            end
        end
        -- Catalog loadout has unique action names; idle and cancel are always included.
        assert(options['action_mask_'..side]==mask,'Recorded ability mask differs from draft')
        near(options['x_'..side],launch.positions[i].x);near(options['y_'..side],launch.positions[i].y)
        -- The first replay row follows a physics tick, so a moving fighter may
        -- already have left its recorded launch position.
        local dx=replay.frames[1][i+2]-launch.positions[i].x
        local dy=replay.frames[1][i+48]-launch.positions[i].y
        assert(math.sqrt(dx*dx+dy*dy)<=7*replay.frames[1][1]+0.002)
        near(replay.frames[1][i+4],launch['hp_'..side])
        local petIndex=83+(i-1)*5
        if spec.class=='warlock' then
            local kinds={imp=1,succubus=2,felhunter=3,voidwalker=4}
            assert(options['pet_'..side]==spec.pet)
            assert(replay.frames[1][petIndex]==kinds[spec.pet])
            assert(replay.frames[1][petIndex+1]>0,'Selected pet has no health')
            assert(options['warlock_talents_'..side].suppression==spec.trees.Affliction['105925'])
            -- Replay rows follow physics ticks; melee pets have already begun moving.
            local px,py=replay.frames[1][petIndex+2],replay.frames[1][petIndex+3]
            local dx,dy=px-launch.positions[i].x,py-launch.positions[i].y-1.5
            assert(math.sqrt(dx*dx+dy*dy)<=7*replay.frames[1][1]+0.002)
        else assert(replay.frames[1][petIndex]==0) end
        assert(not io.open(launch.temporary_specs[i]),'Temporary spec was not cleaned up')
    end
    assert(options.config.rollouts==1024 and options.config.workers==1)
    assert(workspace.isPlayback(),'Completed fight did not enter playback')
    print('Verified real fight '..index..': unsaved stats/loadout, both coordinates, HP, pets, replay and metadata')
end
local phase,age,reviewIndex=0,0,1
local reviewSizes={{960,540},{1280,720},{2560,1080}}
local before,firstSnapshot
function love.load()
    appLoad({})
    workspace.editPositions()
    workspace.select(1);editor.setClass('warlock');editor.setPet('imp')
    editor.getCurrentBuild().Affliction['105925']=1
    for i=2,14 do editor.setActionSlot(i,'') end
    editor.setActionSlot(2,'Shadow Bolt')
    workspace.select(2);editor.setClass('frost_mage')
    for i=2,14 do editor.setActionSlot(i,'') end
    editor.setActionSlot(2,'Frostbolt');editor.setCombatStat('spell_crit_chance',0.18)
    workspace.select(1)
    local cfg=generator.getConfig();cfg.hp_a=400;cfg.hp_b=400;cfg.output=output..'-1.lua'
end
function love.update(dt)
    appUpdate(dt);age=age+dt
    assert(age<120,'Repeat-fight test timed out: '..tostring(generator.getStatus()))
    local status,err=generator.getStatus();assert(status~='Failed',err)
end
function love.draw()
    render()
    if phase==0 then
        choose('rollouts',1024);choose('workers',1);choose('evaluator','heuristic')
        press('Stats');render()
        -- Enter an unsaved stat using the real text field, then switch players twice.
        press('0');love.textinput('0.27');love.keypressed('return')
        press('Player B');press('Player A')
        near(workspace.preview().specs[1].combat_stats.spell_crit_chance,0.27)
        drag(1,1,2);drag(2,-1,-2)
        -- Resize and verify that the displayed world positions do not change.
        before=copy(workspace.preview())
        love.window.setMode(960,540);render()
        assert(equal(workspace.preview(),before))
        press('Fight');assert(generator.isActive())
        firstSnapshot=copy(workspace.preview())
        phase=1
    elseif phase==1 and not generator.isActive() then
        render();verify(1)
        assert(equal(workspace.preview(),firstSnapshot))
        press('Edit positions');assert(not workspace.isPlayback())
        assert(equal(workspace.preview(),firstSnapshot))
        -- Change pet through its visible control, preserving the other player's draft.
        press('Player A');press('Pets');press('Pet: felhunter');render()
        assert(workspace.preview().specs[1].pet=='felhunter')
        editor.setActionSlot(2,'Corruption')
        editor.getCurrentBuild().Affliction['105925']=2
        drag(1,0.5,-1)
        assert(equal(workspace.preview().specs[2],firstSnapshot.specs[2]))
        generator.getConfig().output=output..'-2.lua'
        before=copy(workspace.preview());press('Fight');assert(generator.isActive());phase=2
    elseif phase==2 and not generator.isActive() then
        render();verify(2)
        assert(equal(workspace.preview(),before))
        press('Edit positions');press('Playback');render()
        assert(workspace.isPlayback())
        -- A learned sacrifice talent with no sacrificed demon must retain pets.
        press('Edit positions')
        for i=1,2 do
            workspace.select(i);editor.setClass('warlock')
            editor.getCurrentBuild().Demonology['105900']=1
            editor.getCurrentBuild().Demonology['105890']=0
            editor.setPet('none',true);editor.setPet('voidwalker')
            editor.getCurrentBuild().Affliction['105925']=1
            for slot=2,14 do editor.setActionSlot(slot,'') end
            editor.setActionSlot(2,'Shadow Bolt')
        end
        local preview=workspace.preview()
        for i=1,2 do
            assert(preview.specs[i].sacrifice_pet=='none')
            assert(preview.frame[83+(i-1)*5]==4)
            assert(preview.frame[84+(i-1)*5]==1200)
        end
        generator.getConfig().output=output..'-3.lua'
        before=copy(preview);press('Fight');assert(generator.isActive());phase=5
    elseif phase==5 and not generator.isActive() then
        render();verify(3)
        assert(equal(workspace.preview(),before))
        print('Voidwalkers retained for both players with Sacrifice: none')
        phase=3
    elseif phase==3 then
        local size=reviewSizes[reviewIndex]
        love.window.setMode(size[1],size[2]);render()
        local c=assert(dropdowns.workers)
        local snapshot=copy(workspace.preview())
        click(c.x+10,c.y+10);render()
        local bounds=assert(ui.dropdownBounds())
        assert(bounds.x>=0 and bounds.y>=0 and bounds.x+bounds.w<=ui.width() and bounds.y+bounds.h<=ui.height())
        love.keypressed('escape');assert(not ui.dropdownOpen())
        click(c.x+10,c.y+10);render()
        -- Outside click must dismiss without switching mode or moving a fighter.
        click(workspace.left+100,250);assert(not ui.dropdownOpen())
        assert(equal(workspace.preview(),snapshot) and workspace.isPlayback())
        click(c.x+10,c.y+10);render()
        local screenshot=output..'-'..size[1]..'.png'
        local last=reviewIndex==#reviewSizes
        love.graphics.captureScreenshot(function(data)
            local f=assert(io.open(screenshot,'wb'));f:write(data:encode('png'):getString());f:close()
            print('Reviewed menu bounds/dismissal at '..size[1]..'x'..size[2]..': '..screenshot)
            if last then
                print('Repeat-fight GUI passed. Replay artifacts: '..output..'-{1,2,3}.lua')
                love.event.quit(0)
            end
        end)
        ui.closeDropdown()
        reviewIndex=reviewIndex+1
        if last then phase=4 end
    end
end
function love.errorhandler(message)
    print(debug.traceback(message,2));return function() return 1 end
end
