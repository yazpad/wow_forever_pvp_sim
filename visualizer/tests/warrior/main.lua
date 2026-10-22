-- Real GUI + worker test: SDL_VIDEODRIVER=offscreen love visualizer --test-warrior
io.stdout:setvbuf('no')
local source=love.filesystem.getSource()
local root=assert(source:match('^(.*)/visualizer$') or source:match('^(.*)/visualizer/tests/warrior$'))
package.path=root..'/visualizer/?.lua;'..package.path
if not source:match('/visualizer$') then dofile(root..'/visualizer/main.lua') end
local appLoad,appDraw,appUpdate=love.load,love.draw,love.update
local ui,workspace,editor,generator,camera,json=require('ui'),require('workspace'),require('spec_editor'),require('match_generator'),require('arena_camera'),require('json')
local controls,dropdowns,drawnIcons={},{},{}
local iconManager=require('icons_manager')
local originalDrawIcon=iconManager.drawRect
iconManager.drawRect=function(name,...) drawnIcons[name]=true;return originalDrawIcon(name,...) end
local originalButton,originalDropdown=ui.button,ui.dropdown
ui.button=function(x,y,w,h,label,...)
    if not ui.viewport then controls[label]={x=x,y=y,w=w,h=h} end
    return originalButton(x,y,w,h,label,...)
end
ui.dropdown=function(id,x,y,w,h,value,choices,...)
    dropdowns[id]={x=x,y=y,w=w,h=h,choices=choices}
    return originalDropdown(id,x,y,w,h,value,choices,...)
end
local function render() controls={};dropdowns={};drawnIcons={};appDraw() end
local function click(x,y)
    x,y=x*ui.scale(),y*ui.scale()+ui.headerHeight
    love.mousepressed(x,y,1);love.mousereleased(x,y,1)
end
local function choose(id,predicate)
    render();local c=assert(dropdowns[id],id)
    click(c.x+10,c.y+10);render()
    local bounds=assert(ui.dropdownBounds())
    for i,v in ipairs(c.choices) do
        if predicate(v) then click(bounds.x+20,bounds.y+4+(i-0.5)*bounds.row);return end
    end
    error('Missing option for '..id)
end
local function press(label)
    render();local c=assert(controls[label],'Missing '..label);click(c.x+c.w/2,c.y+c.h/2)
end
local function drag(side,dx)
    render();local f=workspace.preview().frame
    local _,_,view=workspace.arenaPoint(workspace.left+30,100)
    local x,y=camera.worldPoint(view,f[side+2],f[side+48])
    local sx,sy=(view.x+x*view.scale)*ui.scale(),(view.y+y*view.scale)*ui.scale()+ui.headerHeight
    love.mousepressed(sx,sy,1)
    local tx=sx+dx*25*camera.zoom*view.scale*ui.scale()
    love.mousemoved(tx,sy,tx-sx,0);love.mousereleased(tx,sy,1)
end
local output=root..'/matches/warrior_ui_test.lua'
local phase,age,replayAge=0,0,0
local function screenshot(name)
    love.graphics.captureScreenshot(function(image)
        local file=assert(io.open(root..'/benchmarks/warrior/'..name..'.png','wb'))
        file:write(image:encode('png'):getString());file:close()
    end)
end
function love.load()
    love.window.setMode(1280,720,{fullscreen=false,vsync=0})
    appLoad({})
    workspace.editPositions();workspace.select(1)
end
function love.update(dt)
    appUpdate(dt);age=age+dt
    if phase==3 then replayAge=replayAge+dt end
    assert(age<90,'Warrior GUI test timeout')
    local status,err=generator.getStatus();assert(status~='Failed',err)
end
function love.draw()
    render()
    if phase==0 then
        choose('class_1',function(v) return v=='warrior' end)
        choose('preset_1',function(v) return v.filename=='warrior_dual_wield' end)
        assert(workspace.preview().specs[1].warrior.off_hand)
        choose('preset_1',function(v) return v.filename=='warrior_two_hand' end)
        assert(not workspace.preview().specs[1].warrior.off_hand)
        workspace.select(2);editor.loadSpec(assert((function()
            local file=assert(io.open(root..'/specs/disc_priest.json'));local data=json.decode(file:read('*a'));file:close();return data
        end)()))
        workspace.select(1);assert(editor.setWarriorStat('starting_rage',60))
        assert(editor.setWarriorStat('attack_power',812))
        -- Close detail cards before dragging tokens underneath their overlays.
        for i=1,2 do
            workspace.select(i);render();local b=workspace.frameBounds[i]
            click(b.x+b.w/2,b.y+b.h+10)
        end
        drag(1,11);drag(2,-11)
        assert(math.abs(workspace.preview().frame[2]-3)<0.02,'Token drag did not reach melee range: '..workspace.preview().frame[2])
        workspace.select(1);render()
        local b=workspace.details[1];click(b.x+50,b.scrollTop+15);render()
        click(b.x+50,b.scrollTop+42+26+46+15);render()
        assert(drawnIcons.ability_rogue_ambush,'Arms talent nodes not rendered')
        screenshot('warrior_talents');phase=6
    elseif phase==6 then
        local b=workspace.details[1];click(b.x+50,b.scrollTop+15);render()
        click(b.x+50,b.scrollTop+42+15);render()
        assert(dropdowns['warrior_1warrior.main_hand.two_handed'],'Warrior weapon controls not rendered')
        screenshot('warrior_setup')
        local cfg=generator.getConfig();cfg.rollouts=32;cfg.workers=2;cfg.evaluator='heuristic';cfg.fight_seconds=8;cfg.output=output
        phase=1
    elseif phase==1 then
        render();assert(not controls.Fight,'Standalone Fight button must not change the evolution workflow')
        assert(controls['Evolve/Train'] and controls['Evolve/Train'].w>200)
        -- Generate a replay fixture through the worker API, outside the product workflow.
        local cfg={};for k,v in pairs(generator.getConfig()) do cfg[k]=v end
        cfg.temporary_specs={};cfg.distance=workspace.preview().frame[2]
        for i,side in ipairs({'a','b'}) do
            workspace.select(i);local spec=editor.getCurrentSpecConfig()
            local path=os.tmpname();local file=assert(io.open(path,'w'));file:write(json.encode(spec));file:close()
            spec.filename=path;cfg['spec_'..side..'_obj']=spec;cfg['spec_'..side]=spec.class
            cfg.temporary_specs[#cfg.temporary_specs+1]=path
        end
        workspace.select(1)
        assert(generator.startFight(cfg));assert(generator.isActive());phase=2
    elseif phase==2 and not generator.isActive() then
        local replay=dofile(output)
        assert(replay.meta.spec_a=='warrior' and replay.meta.max_rage_a==100)
        assert(#replay.frames[1]==136 and replay.frames[1][125]>0)
        local file=assert(io.open(output..'.search.json'));local saved=json.decode(file:read('*a'));file:close()
        assert(saved.options.warrior_a.attack_power==812 and saved.options.warrior_a.starting_rage==60)
        assert(#saved.initial_state.warrior==11)
        local damage=false
        for _,event in ipairs(replay.events) do
            if event.s==0 and event.k==4 then assert(event.sp==1 or event.sp==2 or event.sp==21);damage=true end
            assert(not(event.s==0 and event.k==5),'Melee mislabeled as a DoT')
        end
        assert(damage,'No melee damage in fixture')
        assert(workspace.isPlayback())
        phase=3
    elseif phase==3 and replayAge>0.7 then
        screenshot('warrior_replay');phase=4
    elseif phase==4 then
        love.window.setMode(960,540);render()
        love.window.setMode(1280,720);render()
        print('PASS: real Warrior class/presets, weapon controls, worker replay fixture, rage/stance replay, frozen config, resizing and screenshots')
        love.event.quit(0);phase=5
    end
end
function love.errorhandler(message)
    print(debug.traceback(tostring(message),2))
    return function() return 1 end
end
