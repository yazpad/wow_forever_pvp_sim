local races=require('races')
local ui = require('ui')
local editor = require('spec_editor')
local talents = require('talents_data')
local generator = require('match_generator')
local camera = require('arena_camera')
local icons = require('icons_manager')
local actions = require('action_catalog')
local backgrounds = require('talent_backgrounds')
local json = require('json')
local browser = require('match_browser')
local matrix = require('matrix_view')
local gear = require('gear')
local demonPassives = require('demon_passives')
local workspace = {}
local function maximumHealth(spec)
    local stats=spec.combat_stats
    local t=spec.trees and spec.trees.Demonology or {}
    local rank=spec.class=='warlock' and (t['105907'] or t[105907] or 0) or 0
    return stats.max_health+(stats.stamina or 0)*0.03*rank*10
end
local settingsScroll, settingsMax, settingsFocus = 0, 0, nil
local settingsOpen = {league=true,replays=false,matrix=false}
function workspace.toggleSettingsSection(name)
    settingsOpen[name]=not settingsOpen[name]
    settingsFocus=settingsOpen[name] and name or nil
end
local drafts, selected, saved, buttons = {}, 1, nil, {}
local scroll, maxScroll, message = 0, 0, ''
local expanded, tooltip, tokenFrame = true, nil, nil
local schoolOpen = {{},{}}
local sectionsOpen = {{},{}}
local input, dragging, arena = nil, nil, nil
local playback, replayAvailable, replayViewport = false, false, nil
local positions = {{x=-12.5,y=0},{x=12.5,y=0}}
local function distance()
    local dx,dy=positions[2].x-positions[1].x,positions[2].y-positions[1].y
    return math.sqrt(dx*dx+dy*dy)
end
local function resetPositions(d)
    positions={{x=-d/2,y=0},{x=d/2,y=0}}
end
local function commitInput()
    if not input then return true end
    local ok,err=editor.setCombatStat(input.key,tonumber(input.text))
    if ok then playback=false; input=nil; message='' else message=err end
    return ok
end
local function clone(v) return json.decode(json.encode(v)) end
local function capture() drafts[selected] = editor.getCurrentSpecConfig() end
local function init()
    if saved then return end
    saved = talents.loadSavedSpecs('specs')
    editor.init()
    drafts[1] = clone(generator.getConfig().spec_a_obj)
    drafts[2] = clone(generator.getConfig().spec_b_obj)
    for i = 1, 2 do
        if not drafts[i].trees then
            editor.setClass(drafts[i].class or 'warlock')
            drafts[i] = editor.getCurrentSpecConfig()
        end
        editor.loadSpec(drafts[i])
        if not drafts[i].gear then editor.equipPrebis() end
        drafts[i] = editor.getCurrentSpecConfig()
    end
    editor.loadSpec(drafts[selected])
end
local function button(x,y,w,label,action,active)
    ui.button(x,y,w,26,label,false,active)
    buttons[#buttons+1] = {x=x,y=y,w=w,h=26,action=action}
end
local function switch(i)
    if not commitInput() then return end
    capture(); selected = i; editor.loadSpec(drafts[i]); scroll = 0; expanded=true
    return true
end
function workspace.select(i)
    if i~=1 and i~=2 then return false end
    init()
    if selected==i then expanded=true; return true end
    return switch(i)
end
function workspace.getSelected() return expanded and selected or nil end
function workspace.setTokenFrame(frame) tokenFrame=frame end
local function tile(x,y,size,icon,name,rank,active,detail,action)
    local g=love.graphics
    ui.drawCard(x,y,size,size,false,active,4)
    local drawn=icon and icons.drawRect(icon,x+3,y+3,size-6,size-6)
    if not drawn then
        g.setColor(ui.colors.textMuted)
        g.printf(name:sub(1,2),x+3,y+size/2-8,size-6,'center')
    end
    if rank~='' then
        g.setColor(0.03,0.05,0.08,0.95); g.rectangle('fill',x,y+size-14,size,14)
        ui.setFont('small'); g.setColor(ui.colors.text); g.printf(rank,x,y+size-14,size,'center'); ui.resetFont()
    end
    buttons[#buttons+1]={x=x,y=y,w=size,h=size,action=action}
    local mx,my=ui.contentPoint(love.mouse.getPosition())
    if mx>=x and mx<=x+size and my>=y and my<=y+size then tooltip={text=detail,x=mx,y=my} end
end
function workspace.draw(drawReplay, hasReplay, loadReplay)
    init(); capture(); buttons = {}; tooltip=nil
    replayAvailable = hasReplay or false
    replayViewport = nil
    local g = love.graphics
    local w,h = ui.dimensions()
    local left,right,gap = math.min(340,w*0.30), math.min(260,w*0.24), 12
    local ax,aw = left+gap*2,w-left-right-gap*4
    workspace.left = left
    for _,p in ipairs({{12,left},{ax,aw},{w-right-12,right}}) do
        ui.drawCard(p[1],12,p[2],h-24,false,false)
    end
    ui.setFont('title'); g.setColor(ui.colors.text)
    g.print('Specs',24,24); g.print('Arena',ax+12,24)
    local rx = w-right
    g.print('Settings',rx,24); ui.resetFont()
    local headerB=expanded and selected==1 and h-82 or 126
    local function playerHeader(i,y)
        local s=drafts[i]
        local className=s.class=='frost_mage' and 'Mage' or (s.class=='priest' and 'Priest' or 'Warlock')
        local accent=s.class=='frost_mage' and {0.35,0.75,1,1} or (s.class=='priest' and {0.95,0.92,0.72,1} or {0.68,0.45,0.94,1})
        ui.playerHeader(24,y,left-24,58,'Player '..(i==1 and 'A' or 'B'),
            className..' · '..(s.name or 'Custom spec'),expanded and selected==i,accent,102)
        local classAction=ui.dropdown('class_'..i,32,y+8,42,42,s.class,{'warlock','frost_mage','priest'},function(class)
            if class==drafts[i].class or not commitInput() then return end
            capture()
            if i~=selected then editor.loadSpec(drafts[i]) end
            editor.setClass(class)
            drafts[i]=editor.getCurrentSpecConfig()
            if i~=selected then editor.loadSpec(drafts[selected]) else scroll=0 end
            workspace.editPositions();message=''
        end,function(class) return class=='frost_mage' and 'Mage' or 'Warlock' end,nil,
            {icon=s.class=='frost_mage' and 'mage' or (s.class=='priest' and 'priest' or 'warlock'),menuWidth=180})
        buttons[#buttons+1]={x=32,y=y+8,w=42,h=42,action=function(b)
            if b==1 and commitInput() then classAction() end
        end}
        local race=races.normalize(s.race,s.class)
        local raceAction=ui.dropdown('race_'..i,78,y+8,42,42,race,races.choices(s.class),function(value)
            if value==race or not commitInput() then return end
            capture()
            if i~=selected then editor.loadSpec(drafts[i]) end
            editor.setRace(value)
            drafts[i]=editor.getCurrentSpecConfig()
            if i~=selected then editor.loadSpec(drafts[selected]) end
            workspace.editPositions();message=''
        end,function(value) return races.labels[value] end,nil,{race=race,menuWidth=180})
        buttons[#buttons+1]={x=78,y=y+8,w=42,h=42,action=function(b)
            if b==1 and commitInput() then raceAction() end
        end}
        buttons[#buttons+1]={x=24,y=y,w=left-24,h=58,action=function(b)
            if b~=1 then return end
            if selected==i and expanded then
                if commitInput() then capture(); expanded=false end
            else workspace.select(i) end
        end}
        local mx,my=ui.contentPoint(love.mouse.getPosition())
        if mx>=32 and mx<=74 and my>=y+8 and my<=y+50 then
            tooltip={text='Change class: '..className..'\nChoose Warlock or Mage (Frost).',x=mx,y=my}
        elseif mx>=78 and mx<=120 and my>=y+8 and my<=y+50 then
            tooltip={text='Change race: '..races.labels[race]..'\nForever: Human +2% crit; Orc +1% crit. Gnome +5% mana. Blood Fury, Berserking and Escape Artist available in Abilities.',x=mx,y=my}
        end
    end
    playerHeader(1,56); playerHeader(2,headerB)
    if expanded then
    local spec=drafts[selected]
    local base=selected==1 and 126 or 196
    local footer=selected==1 and h-94 or h-24
    local function edit(action)
        return function(b)
            if not commitInput() then return end
            workspace.editPositions(); action(b); capture()
        end
    end
    local currentPreset
    for _,preset in ipairs(saved) do
        if preset.name==spec.name and preset.class==spec.class then currentPreset=preset; break end
    end
    local presetAction=ui.dropdown('preset_'..selected,24,base,left-24,26,currentPreset,saved,
        edit(function(preset) editor.loadSpec(preset); scroll=0 end),
        function(preset) return preset.name or preset.filename or 'Unnamed spec' end,
        'Preset: '..(spec.name or 'Custom spec'))
    buttons[#buttons+1]={x=24,y=base,w=left-24,h=26,action=function(b)
        if b==1 and commitInput() then presetAction() end
    end}
    local top,bottom=base+38,footer-78
    workspace.scrollTop=top
    ui.scissor(20,top,left-12,math.max(0,bottom-top))
    local y=top-scroll
    local data=talents.load(spec.class)
    local sectionStates=sectionsOpen[selected]
    for _,section in ipairs({'Talents','Gear','Pets','Abilities'}) do
        local open=sectionStates[section] or false
        if y>=top and y+34<=bottom then
            ui.drawCard(24,y,left-24,34,false,open,5)
            ui.chevron(38,y+17,open)
            g.setColor(ui.colors.text); ui.setFont('bold')
            g.print(section,54,y+8); ui.resetFont()
            buttons[#buttons+1]={x=24,y=y,w=left-24,h=34,action=function(b)
                if b==1 and commitInput() then
                    sectionStates[section]=not open
                    ui.closeDropdown()
                end
            end}
        end
        y=y+42
        if open then
            ui.setFont('small'); g.setColor(ui.colors.textMuted)
            if section~='Gear' and y>=top and y+16<=bottom then
                g.print(section=='Talents' and 'Left + / right - · Hover for details' or
                    section=='Abilities' and 'Available automatically from your build' or
                    section=='Gear' and 'Vanilla level 60 · Pre-raid gear' or 'Click a value to edit',24,y)
            end
            ui.resetFont()
            if section~='Gear' then y=y+26 end
            if section=='Talents' then
                local cell=(left-24)/4
                local size=math.min(44,cell-10)
                local states=schoolOpen[selected]
                states[spec.class]=states[spec.class] or {}
                local classStates=states[spec.class]
                for _,treeName in ipairs(talents.getClassTrees(spec.class)) do
                    local open=classStates[treeName] or false
                    local treeTalents=(data and data[treeName] and data[treeName].talents) or {}
                    local rows=0
                    for _,t in ipairs(treeTalents) do rows=math.max(rows,t.row+1) end
                    local bodyHeight=open and rows*(size+16)+12 or 0
                    local headerHeight=48
                    if y+headerHeight+bodyHeight>top and y<bottom then
                        backgrounds.draw(treeName,24,y,left-24,headerHeight+bodyHeight)
                    end
                    if y>=top and y+headerHeight<=bottom then
                        local mx,my=ui.contentPoint(love.mouse.getPosition())
                        local hover=mx>=24 and mx<=left and my>=y and my<=y+headerHeight
                        g.setColor(0.025,0.035,0.06,hover and 0.65 or 0.82)
                        g.rectangle('fill',24,y,left-24,headerHeight,5)
                        g.setColor(open and ui.colors.cardBorderActive or ui.colors.cardBorder)
                        g.rectangle('line',24,y,left-24,headerHeight,5)
                        g.setColor(ui.colors.text); ui.setFont('bold')
                        ui.chevron(38,y+14,open)
                        g.setColor(ui.colors.text)
                        g.print(treeName,54,y+6)
                        ui.setFont('small'); g.setColor(ui.colors.textMuted)
                        g.print(talents.getTreePoints(data,spec.trees,treeName)..' talent points',54,y+27)
                        ui.resetFont()
                        buttons[#buttons+1]={x=24,y=y,w=left-24,h=headerHeight,action=function()
                            classStates[treeName]=not open
                        end}
                    end
                    y=y+headerHeight
                    if open then
                        for _,t in ipairs(treeTalents) do
                            local rank=talents.getRank(spec.trees[treeName],t.id)
                            local tx,ty=24+t.col*cell+(cell-size)/2,y+8+t.row*(size+16)
                            if ty>=top and ty+size<=bottom then
                                local allowed,err=talents.canInvest(data,editor.getCurrentBuild(),treeName,t)
                                local detail=t.descriptions and (t.descriptions[tostring(math.min(t.max_ranks,rank+1))] or '') or ''
                                tile(tx,ty,size,t.icon,t.name,rank..'/'..t.max_ranks,rank>0 or allowed,
                                    t.name..'  '..rank..'/'..t.max_ranks..'\n'..detail..(not allowed and rank<t.max_ranks and ('\n'..tostring(err)) or ''),edit(function(b)
                                        local build=editor.getCurrentBuild()
                                        local ok,why
                                        if b==2 then ok,why=talents.canUninvest(data,build,treeName,t)
                                        else ok,why=talents.canInvest(data,build,treeName,t) end
                                        if ok then build[treeName][tostring(t.id)]=rank+(b==2 and -1 or 1); message=''
                                        else message=why or 'Cannot change talent' end
                                    end))
                            end
                        end
                    end
                    y=y+bodyHeight+12
                end
            elseif section=='Gear' then
                local half=(left-30)/2
                if y>=top and y+26<=bottom then
                    button(24,y,half,'Pre-BiS',edit(function() editor.equipPrebis() end))
                    button(30+half,y,half,'Clear',edit(function() editor.clearGear() end))
                end
                y=y+32
                local stats=spec.combat_stats
                local passive=demonPassives.describe(spec)
                local power=(spec.class=='frost_mage' and stats.frost_power or stats.shadow_power)+passive.power
                local demonology=spec.trees and spec.trees.Demonology or {}
                local felVitality=demonology['105903'] or demonology[105903] or 0
                local maxMana=races.maxMana(spec.race,stats.max_mana)*(spec.class=='warlock' and (1+0.05*felVitality) or 1)
                local summary={
                    string.format('HP %.0f   MP %.0f   SP %.0f',maximumHealth(spec),maxMana,power),
                    string.format('Hit %.1f%%   Crit %.2f%%',stats.spell_hit_chance*100,math.min(1,stats.spell_crit_chance+races.critBonus(spec.race or 'human'))*100),
                }
                if passive.mastery then summary[#summary+1]=passive.mastery end
                for _,line in ipairs(summary) do
                    if y>=top and y+16<=bottom then ui.setFont('small');g.setColor(ui.colors.textMuted);g.print(line,24,y);ui.resetFont() end
                    y=y+18
                end
                y=y+4
                local labels={shoulder='Shoulder',main_hand='Weapon',off_hand='Off hand'}
                local rowHeight,labelWidth=24,64
                local fieldX,fieldWidth=24+labelWidth,left-24-labelWidth
                for _,slot in ipairs(gear.slots) do
                    if y>=top and y+rowHeight<=bottom then
                        ui.setFont('small');g.setColor(ui.colors.textMuted)
                        g.print(labels[slot[1]] or slot[2],24,y+5);ui.resetFont()
                        local id=spec.gear and spec.gear[slot[1]] or 0
                        local action=ui.dropdown('gear_'..selected..'_'..slot[1],fieldX,y,fieldWidth,rowHeight,id,
                            gear.choices(slot[1],spec.class),edit(function(value)
                                local ok,err=editor.setGear(slot[1],value)
                                message=ok and '' or err
                            end),function(value) local item=gear.item(value);return item and item.name or 'Empty' end,
                            nil,{menuWidth=left-24})
                        buttons[#buttons+1]={x=fieldX,y=y,w=fieldWidth,h=rowHeight,action=function(b) if b==1 then action() end end}
                        local mx,my=ui.contentPoint(love.mouse.getPosition())
                        if mx>=fieldX and mx<=left and my>=y and my<=y+rowHeight and not ui.dropdownOpen() then tooltip={text=gear.detail(id),x=mx,y=my} end
                    end
                    y=y+rowHeight+3
                end
            elseif section=='Pets' then
                if spec.class=='warlock' then
                    for _,sacrifice in ipairs({false,true}) do
                        for _,kind in ipairs({'none','imp','voidwalker','succubus','felhunter'}) do
                            if y>=top and y+26<=bottom then
                                button(24,y,left-24,(sacrifice and 'Sacrifice: ' or 'Pet: ')..kind,
                                    edit(function() editor.setPet(kind,sacrifice) end),
                                    (sacrifice and spec.sacrifice_pet or spec.pet)==kind)
                            end
                            y=y+30
                        end
                        y=y+12
                    end
                else
                    if y>=top and y+20<=bottom then
                        g.setColor(ui.colors.textMuted); g.print('Mages have no pet.',24,y)
                    end
                    y=y+28
                end
            elseif section=='Abilities' then
                local function abilityDetail(name)
                    local detail=name
                    local pet=actions.pet_gates[name]
                    if pet then detail=detail..'\nRequires '..pet end
                    local gate=actions.talent_gates[name]
                    if gate then
                        local talent=talents.findTalent(data,gate.id)
                        detail=detail..'\nRequires '..(talent and talent.name or gate.tree..' talent')
                    end
                    return detail
                end
                local columns=5
                local cell=(left-24)/columns
                local size=math.min(44,cell-6)
                local available=spec.action_loadout
                for idx,name in ipairs(available) do
                    local tx,ty=24+((idx-1)%columns)*cell,y+math.floor((idx-1)/columns)*(size+16)
                    if ty>=top and ty+size<=bottom then
                        tile(tx,ty,size,actions.icons[name],name,'',true,
                            abilityDetail(name)..'\nAutomatically available from this build',function() end)
                    end
                end
                y=y+math.ceil(#available/columns)*(size+16)

            end
            y=y+12
        end
    end
    maxScroll=math.max(0,y+scroll-bottom)
    scroll=math.min(scroll,maxScroll)
    if maxScroll>0 then
        local track=bottom-top
        local thumb=math.max(24,track*track/(track+maxScroll))
        g.setColor(ui.colors.cardBorder); g.rectangle('fill',left+4,top,3,track)
        g.setColor(ui.colors.primary); g.rectangle('fill',left+4,top+(track-thumb)*scroll/maxScroll,3,thumb)
    end
    g.setScissor()
    ui.setFont('small'); g.setColor(ui.colors.textMuted)
    g.printf(message,24,footer-38,left-24); ui.resetFont()
    button(24,footer-70,left-24,'Save spec',function()
        if not commitInput() then return end
        capture()
        local name=(drafts[selected].name or 'custom'):lower():gsub('[^%w_-]','_')
        local ok,err=talents.saveSpec(drafts[selected],name,'specs')
        message=ok and 'Spec saved.' or tostring(err)
        if ok then saved=talents.loadSavedSpecs('specs') end
    end)
    end
    local cfg=generator.getConfig()
    local settingsBottom=h-124
    workspace.settingsX=rx
    ui.scissor(rx-2,56,right-18,settingsBottom-56)
    local sy=66-settingsScroll
    local function settingButton(y,label,action,active)
        if y>=56 and y+26<=settingsBottom then button(rx,y,right-24,label,action,active) end
    end
    local function settingText(y,text)
        ui.setFont('small');g.setColor(ui.colors.textMuted)
        local _,lines=g.getFont():getWrap(text,right-24)
        local height=#lines*g.getFont():getHeight()+8
        if y+height>56 and y<settingsBottom then g.printf(text,rx,y,right-24) end
        ui.resetFont()
        return y+height
    end
    local function dropdown(label,key,values,fmt)
        if sy>=56 and sy+18<=settingsBottom then
            g.setColor(ui.colors.textMuted); g.print(label,rx,sy)
        end
        sy=sy+22
        if sy>=56 and sy+26<=settingsBottom then
        local action=ui.dropdown(key,rx,sy,right-24,26,cfg[key],values,function(value)
            cfg[key]=value
            if key=='distance' then resetPositions(value); workspace.editPositions() end
        end,fmt or function(value)
            return key=='distance' and string.format('%.1f m',value) or tostring(value)
        end)
        buttons[#buttons+1]={x=rx,y=sy,w=right-24,h=26,action=function(b)
            if b==1 and commitInput() then action() end
        end}
        end
        sy=sy+42
    end
    local function prepareLaunchConfig(extra)
        if generator.isActive() then return nil end
        if not commitInput() then return nil end
        capture()
        local launch=clone(cfg)
        if extra then for k,v in pairs(extra) do launch[k]=v end end
        launch.temporary_specs={}
        launch.positions=clone(positions)
        launch.distance=distance()
        for i,side in ipairs({'a','b'}) do
            local path=os.tmpname()
            local f,err=io.open(path,'w')
            if not f then
                for _,tmp in ipairs(launch.temporary_specs) do os.remove(tmp) end
                message=tostring(err); return nil
            end
            f:write(json.encode(drafts[i])); f:close()
            launch.temporary_specs[#launch.temporary_specs+1]=path
            launch['hp_'..side]=maximumHealth(drafts[i])
            launch['spec_'..side..'_obj']=clone(drafts[i])
            launch['spec_'..side..'_obj'].filename=path
            launch['spec_'..side]=drafts[i].class
            launch['pet_'..side]=drafts[i].pet
        end
        return launch
    end
    dropdown('Rollouts / decision','rollouts',{1024,4096,16384,65536})
    dropdown('Worker threads','workers',{1,2,4,8,16,32})
    dropdown('Algorithm','algorithm',{'puct','uct','exp3'})
    dropdown('Leaf scorer','evaluator',{'heuristic','rollout'})
    dropdown('Starting distance (m)','distance',{10,20,25,35})
    settingButton(sy,'Reset positions',function() resetPositions(25); cfg.distance=25; workspace.editPositions() end)
    sy=sy+40
    local focusScroll
    local function sectionHeader(name,label)
        if settingsFocus==name then focusScroll=sy+settingsScroll-66 end
        settingButton(sy,(settingsOpen[name] and '− ' or '+ ')..label,function()
            settingsOpen[name]=not settingsOpen[name]
        end,settingsOpen[name])
        sy=sy+34
        return settingsOpen[name]
    end
    if sectionHeader('league','League Play (Neuroevolution)') then
        dropdown('Fights / epoch','fights_per_epoch',{10000,50000,100000,250000},function(v)
            return string.format('%dk',math.floor(v/1000))
        end)
        dropdown('Max epochs','epochs',{4,6,10,20})
        dropdown('Population size','population_size',{32,64,128})
        dropdown('Early stop threshold','convergence_threshold',{0,0.01,0.02,0.05},function(v)
            return v==0 and 'Off' or string.format('%.0f%%',v*100)
        end)
        settingButton(sy,generator.isActive() and 'Evolving...' or 'Evolve & Fight',function()
            local launch=prepareLaunchConfig()
            if not launch then return end
            local ok,err=generator.startLeaguePlay(launch)
            if not ok then for _,tmp in ipairs(launch.temporary_specs) do os.remove(tmp) end end
            message=ok and '' or tostring(err)
        end,true)
        sy=sy+34
        local nt=generator.getNeuroTelemetry and generator.getNeuroTelemetry() or nil
        if nt and (generator.isActive() or (nt.epoch and nt.epoch>0)) then
            local prog=generator.getProgress and generator.getProgress() or 0
            if sy>=56 and sy+10<=settingsBottom then
                g.setColor(0.08,0.12,0.18,0.95)
                g.rectangle('fill',rx,sy,right-24,8,3)
                g.setColor(ui.colors.primary)
                g.rectangle('fill',rx,sy,(right-24)*math.max(0,math.min(1,prog)),8,3)
            end
            sy=sy+14
            local convText=nt.converged and 'Converged' or (generator.isActive() and ('Evolving '..tostring(nt.side)) or 'Completed')
            local info=string.format('%s · Ep %d/%d (%d gens)\nWin A: %.1f%% · %.0fk fights/s',
                convText,nt.epoch or 0,nt.max_epochs or cfg.epochs,nt.gens or 0,
                (nt.win_rate_a or 0.5)*100,(nt.fights_sec or 0)/1000)
            sy=settingText(sy,info)
            if nt.policy_a and nt.policy_b and not generator.isActive() then
                settingButton(sy,'Champ A vs MCTS B',function()
                    local launch=prepareLaunchConfig({policy_a=nt.policy_a,output='matches/neuro_vs_mcts.lua'})
                    if not launch then return end
                    local ok,err=generator.startFight(launch)
                    if not ok then for _,tmp in ipairs(launch.temporary_specs) do os.remove(tmp) end end
                    message=ok and '' or tostring(err)
                end)
                sy=sy+32
                settingButton(sy,'MCTS A vs Champ B',function()
                    local launch=prepareLaunchConfig({policy_b=nt.policy_b,output='matches/mcts_vs_neuro.lua'})
                    if not launch then return end
                    local ok,err=generator.startFight(launch)
                    if not ok then for _,tmp in ipairs(launch.temporary_specs) do os.remove(tmp) end end
                    message=ok and '' or tostring(err)
                end)
                sy=sy+34
            end
        end
    end
    local function openReplay(path)
        if not commitInput() then return end
        if loadReplay then loadReplay(path); workspace.showReplay() end
    end
    if sectionHeader('replays','Fight replays [F2]') then
        sy=browser.drawPanel(sy,settingButton,settingText,openReplay)
    end
    if sectionHeader('matrix','Matrix [F4]') then
        sy=matrix.drawPanel(sy,settingButton,settingText,openReplay)
    end
    settingsMax=math.max(0,sy+settingsScroll-settingsBottom)
    settingsScroll=math.min(focusScroll or settingsScroll,settingsMax)
    settingsFocus=nil
    g.setScissor()
    if settingsMax>0 then
        local track=settingsBottom-56
        local thumb=math.max(24,track*track/(track+settingsMax))
        g.setColor(ui.colors.cardBorder);g.rectangle('fill',w-22,56,3,track)
        g.setColor(ui.colors.primary);g.rectangle('fill',w-22,56+(track-thumb)*settingsScroll/settingsMax,3,thumb)
    end
    button(rx,h-110,right-24,generator.isActive() and 'Searching...' or 'Fight',function()
        local launch=prepareLaunchConfig()
        if not launch then return end
        local ok,err=generator.startFight(launch)
        if not ok then for _,tmp in ipairs(launch.temporary_specs) do os.remove(tmp) end end
        message=ok and '' or tostring(err)
    end,true)
    local status,err=generator.getStatus()
    g.setColor(ui.colors.textMuted); g.printf(err or status,rx,h-72,right-24)
    button(ax+12,52,(aw-30)/2,'Edit positions',function()
        workspace.editPositions()
    end,not playback)
    button(ax+18+(aw-30)/2,52,(aw-30)/2,'Playback',function()
        if replayAvailable then playback=true; dragging=nil
        else message='Run a fight or load a replay first.' end
    end,playback)
    arena=nil
    replayViewport=ui.makeViewport(ax+1,88,aw-2,h-102)
    if playback and replayAvailable then
        ui.withViewport(replayViewport,drawReplay)
    else
        arena=replayViewport
        ui.withViewport(arena,function() drawReplay(workspace.preview()) end)
    end
    if tooltip then
        local tw=math.min(320,w-32)
        ui.setFont('small')
        local _,lines=g.getFont():getWrap(tooltip.text,tw-24)
        local th=#lines*g.getFont():getHeight()+24
        local tx,ty=math.min(tooltip.x+16,w-tw-12),math.max(12,math.min(tooltip.y+16,h-th-12))
        ui.drawCard(tx,ty,tw,th,false,true)
        g.setColor(ui.colors.text); g.printf(tooltip.text,tx+12,ty+12,tw-24)
        ui.resetFont()
    end
end
function workspace.mousepressed(x,y,b)
    if b~=1 and b~=2 and b~=3 then return false end
    local view=replayViewport
    if b==1 and view and tokenFrame then
        for i=2,1,-1 do
            local vx,vy=ui.viewportPoint(view,x,y)
            local px,py=camera.worldPoint(view,tokenFrame[2+i],tokenFrame[48+i] or 0)
            if x>=view.x and x<=view.x+view.w and y>=view.y and y<=view.y+view.h
                and vy>154 and vy<view.virtualH-(arena and 60 or 120) and (vx-px)^2+(vy-py)^2<=(32*camera.zoom)^2 then
                if not workspace.select(i) then return true end
                if arena then
                    local wx,wy=camera.screenPoint(view,vx,vy)
                    dragging={i=i,dx=wx-positions[i].x,dy=wy-positions[i].y,startX=x,startY=y,active=false}
                end
                return true
            end
        end
    end
    for _,v in ipairs(buttons) do
        if x>=v.x and x<=v.x+v.w and y>=v.y and y<=v.y+v.h then
            v.action(b); return true
        end
    end
    return false
end
function workspace.wheelmoved(y)
    local mx,my=ui.contentPoint(love.mouse.getPosition())
    if mx>=(workspace.settingsX or math.huge) and my>=56 and my<ui.height()-124 then
        ui.closeDropdown()
        settingsScroll=math.max(0,math.min(settingsMax,settingsScroll-y*40))
        return
    end
    if mx<=((workspace.left or 340)+12) and expanded and my>=(workspace.scrollTop or 256) then
        ui.closeDropdown()
        scroll=math.max(0,math.min(maxScroll,scroll-y*40))
    end
end
function workspace.mousemoved(x,y)
    if not dragging or not arena then return end
    if not dragging.active then
        local dx,dy=(x-dragging.startX)*ui.scale(),(y-dragging.startY)*ui.scale()
        if dx*dx+dy*dy<25 then return end
        dragging.active=true
    end
    local i=dragging.i
    local other=positions[3-i]
    local vx,vy=ui.viewportPoint(arena,x,y)
    local wx,wy=camera.screenPoint(arena,vx,vy)
    local px=math.max(-17.5,math.min(17.5,wx-dragging.dx))
    local py=math.max(-17.5,math.min(17.5,wy-dragging.dy))
    local dx,dy=px-other.x,py-other.y
    local len=math.sqrt(dx*dx+dy*dy)
    if len>35 then px=other.x+dx*35/len; py=other.y+dy*35/len end
    positions[i]={x=px,y=py}
    generator.getConfig().distance=distance()
end
function workspace.mousereleased(b) if b==1 then dragging=nil end end
function workspace.keypressed(key)
    if not input then return false end
    if key=='return' or key=='kpenter' then commitInput()
    elseif key=='escape' then input=nil
    elseif key=='backspace' then input.text=input.replace and '' or input.text:sub(1,-2); input.replace=false end
    return true
end
function workspace.textinput(text)
    if input and text:match('^[%d.eE+%-]+$') then
        input.text=(input.replace and '' or input.text)..text; input.replace=false
    end
end
function workspace.editPositions() playback=false; dragging=nil end
function workspace.showReplay()
    playback=true; dragging=nil
end
function workspace.isPlayback() return playback and replayAvailable end
function workspace.replayPoint(x,y,allowOutside)
    if not workspace.isPlayback() then return nil end
    return workspace.arenaPoint(x,y,allowOutside)
end
function workspace.arenaPoint(x,y,allowOutside)
    local view=replayViewport
    if not view then return nil end
    if not allowOutside and (x<view.x or x>view.x+view.w or y<view.y or y>view.y+view.h) then return nil end
    local px,py=ui.viewportPoint(view,x,y)
    return px,py,view
end
-- A render-only snapshot; editing never mutates the loaded replay.
function workspace.preview()
    init(); capture()
    local frame,meta={}, {total_time=0,victor=-1}
    for i=1,104 do frame[i]=0 end
    frame[2]=distance()
    local kinds={imp=1,succubus=2,felhunter=3,voidwalker=4}
    local hp={500,700,900,1200}
    local cfg=generator.getConfig()
    for i,side in ipairs({'a','b'}) do
        local spec=drafts[i]
        meta['max_health_'..side]=maximumHealth(spec)
        local t = spec.trees and spec.trees.Demonology or {}
        local felVitality = spec.class=='warlock' and (t['105903'] or t[105903] or 0) or 0
        local maxMana = races.maxMana(spec.race,spec.combat_stats.max_mana)*(1+0.05*felVitality)
        meta['max_mana_'..side]=maxMana
        meta['action_loadout_'..side]=spec.action_loadout
        meta['race_'..side]=spec.race or 'human'
        meta['spec_'..side]=spec.class
        meta['name_'..side]=spec.name or spec.class
        frame[2+i]=positions[i].x; frame[48+i]=positions[i].y
        frame[4+i]=maximumHealth(spec); frame[6+i]=maxMana
        if spec.class=='warlock' then
            local t = spec.trees and spec.trees.Demonology or {}
            local sl = t['105892'] or t[105892] or 0
            local ds = t['105900'] or t[105900] or 0
            local sacPetKind = kinds[spec.sacrifice_pet] or 0
            meta['warlock_talents_'..side] = {
                soul_link = sl,
                fel_vitality = felVitality,
                demonic_knowledge = t['105893'] or t[105893] or 0,
                master_demonologist = t['105891'] or t[105891] or 0,
                demonic_sacrifice = ds,
                demonic_sacrifice_pet = sacPetKind,
            }
        end
        local kind=spec.class=='warlock' and kinds[spec.pet] or nil
        if kind then
            local idx=83+(i-1)*5
            frame[idx]=kind; frame[idx+1]=hp[kind]*(1+0.05*felVitality)
            frame[idx+2]=positions[i].x; frame[idx+3]=positions[i].y+1.5
        end
    end
    return {meta=meta,frame=frame,specs=drafts}
end
return workspace
