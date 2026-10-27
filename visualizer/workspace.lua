local races=require('races')
local warrior=require('warrior')
local ui = require('ui')
local editor = require('spec_editor')
local talents = require('talents_data')
local generator = require('match_generator')
local neuroGraph = require('neuro_graph')
local camera = require('arena_camera')
local icons = require('icons_manager')
local actions = require('action_catalog')
local backgrounds = require('talent_backgrounds')
local json = require('json')
local browser = require('match_browser')
local matrix = require('matrix_view')
local gear = require('gear')
local demonPassives = require('demon_passives')
local mctsOverlay = require('mcts_overlay')
local workspace = {}
local function maximumHealth(spec)
    local stats=spec.combat_stats
    local t=spec.trees and spec.trees.Demonology or {}
    local rank=spec.class=='warlock' and (t['105907'] or t[105907] or 0) or 0
    return stats.max_health+(stats.stamina or 0)*0.03*rank*10
end
local settingsScroll, settingsMax, settingsFocus = 0, 0, nil
local settingsOpen = {settings=false,mcts=false,league=false,batch=false,replays=false,matrix=false}
function workspace.toggleSettingsSection(name)
    settingsOpen[name]=not settingsOpen[name]
    settingsFocus=settingsOpen[name] and name or nil
end
local drafts, selected, saved, buttons = {}, 1, nil, {}
local scrolls, maxScrolls, message = {0,0}, {0,0}, ''
local expanded, tooltip, tokenFrame = {false,false}, nil, nil
local tokenDrawPositions
local schoolOpen = {{},{}}
local sectionsOpen = {{},{}}
local input, dragging, arena = nil, nil, nil
local detailBounds, frameBounds = {}, {}
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
    local ok,err
    if input.key:sub(1,8)=='warrior.' then ok,err=editor.setWarriorStat(input.key:sub(9),tonumber(input.text))
    else ok,err=editor.setCombatStat(input.key,tonumber(input.text)) end
    if ok then
        playback=false; input=nil; message=''
        generator.invalidateChampions()
    else
        message=err
    end
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
local function button(x,y,w,label,action,active,disabled,glow)
    local mx,my=ui.contentPoint(love.mouse.getPosition())
    local hovered=mx>=x and mx<=x+w and my>=y and my<=y+26
    if glow then
        local g=love.graphics
        local now=love.timer and love.timer.getTime and love.timer.getTime() or os.clock()
        local pulse=0.5+0.5*math.sin(now*5)
        local glowAlpha=0.25+0.35*pulse
        g.setColor(0.35,0.77,0.98,glowAlpha)
        g.setLineWidth(2)
        g.rectangle('line',x-2,y-2,w+4,26+4,6)
        g.setLineWidth(1)
    end
    ui.button(x,y,w,26,label,hovered and not disabled,active,disabled)
    if not disabled then
        buttons[#buttons+1] = {x=x,y=y,w=w,h=26,action=action}
    end
end
local function switch(i)
    if not commitInput() then return end
    capture(); selected = i; editor.loadSpec(drafts[i])
    return true
end
local function focus(i)
    if selected==i then return commitInput() end
    return switch(i)
end
local function editUnit(i,action)
    return function(...)
        if not focus(i) then return end
        workspace.editPositions()
        action(...)
        capture()
        generator.invalidateChampions()
    end
end
local function saveUnit(i)
    if not focus(i) then return end
    capture()
    local name=(drafts[i].name or 'custom'):lower():gsub('[^%w_-]','_')
    local ok,err=talents.saveSpec(drafts[i],name,'specs')
    message=ok and 'Spec saved.' or tostring(err)
    if ok then saved=talents.loadSavedSpecs('specs') end
end
function workspace.select(i)
    if i~=1 and i~=2 then return false end
    init()
    if selected~=i and not switch(i) then return false end
    expanded[i]=true
    return true
end
function workspace.getSelected() return expanded[selected] and selected or nil end
function workspace.setTokenFrame(frame,drawPositions)
    tokenFrame,tokenDrawPositions=frame,drawPositions
end
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
    local left,right,gap = 0, math.min(260,w*0.24), 12
    local ax,aw = 12,w-right-gap*3
    workspace.left = left
    for _,p in ipairs({{ax,aw},{w-right-12,right}}) do
        ui.drawCard(p[1],12,p[2],h-24,false,false)
    end
    local rx = w-right
    local function drawUnitDetails(i,ox,panelY,left)
        local scroll=scrolls[i]
        local bottom=h-24
        if playback and replayAvailable then
            local inset=i==1 and 200 or 120
            if i==2 then
                local monitor=mctsOverlay.layout(replayViewport.virtualW,replayViewport.virtualH)
                if monitor then inset=replayViewport.virtualH-monitor.y end
            end
            bottom=replayViewport.y+replayViewport.h-inset*replayViewport.scale-12
        end
        local bounds={x=ox+12,y=panelY-8,w=left,h=math.max(0,bottom-panelY+8)}
        detailBounds[i]=bounds
        ui.drawCard(bounds.x,bounds.y,bounds.w,bounds.h,false,true)
        local spec=drafts[i]
        local function edit(action) return editUnit(i,action) end
        local top,bottom=panelY,math.max(panelY,bounds.y+bounds.h-8)
        bounds.scrollTop=top
        if i==workspace.getSelected() then workspace.scrollTop=top end
        ui.scissor(ox+20,top,left-12,math.max(0,bottom-top))
        local y=top-scroll
        local data=talents.load(spec.class)
        local sectionStates=sectionsOpen[i]
        for _,section in ipairs({'Talents','Gear','Pets','Abilities'}) do
            local open=sectionStates[section] or false
            if y>=top and y+34<=bottom then
                ui.drawCard(ox+24,y,left-24,34,false,open,5)
                ui.chevron(ox+38,y+17,open)
                g.setColor(ui.colors.text); ui.setFont('bold')
                g.print(section,ox+54,y+8); ui.resetFont()
                buttons[#buttons+1]={x=ox+24,y=y,w=left-24,h=34,action=function(b)
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
                        section=='Gear' and 'Vanilla level 60 · Pre-raid gear' or 'Click a value to edit',ox+24,y)
                end
                ui.resetFont()
                if section~='Gear' then y=y+26 end
                if section=='Talents' then
                    if spec.class=='warrior' then
                        if y>=top and y+42<=bottom then g.setColor(ui.colors.textMuted);g.printf('Partial kit: auto attacks, Heroic Strike, Hamstring, stances. Hover talents for support.',ox+24,y,left-24) end
                        y=y+46
                    end
                    local cell=(left-24)/4
                    local size=math.min(44,cell-10)
                    local states=schoolOpen[i]
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
                            backgrounds.draw(treeName,ox+24,y,left-24,headerHeight+bodyHeight)
                        end
                        if y>=top and y+headerHeight<=bottom then
                            local mx,my=ui.contentPoint(love.mouse.getPosition())
                            local hover=mx>=ox+24 and mx<=ox+left and my>=y and my<=y+headerHeight
                            g.setColor(0.025,0.035,0.06,hover and 0.65 or 0.82)
                            g.rectangle('fill',ox+24,y,left-24,headerHeight,5)
                            g.setColor(open and ui.colors.cardBorderActive or ui.colors.cardBorder)
                            g.rectangle('line',ox+24,y,left-24,headerHeight,5)
                            g.setColor(ui.colors.text); ui.setFont('bold')
                            ui.chevron(ox+38,y+14,open)
                            g.setColor(ui.colors.text)
                            g.print(treeName,ox+54,y+6)
                            ui.setFont('small'); g.setColor(ui.colors.textMuted)
                            g.print(talents.getTreePoints(data,spec.trees,treeName)..' talent points',ox+54,y+27)
                            ui.resetFont()
                            buttons[#buttons+1]={x=ox+24,y=y,w=left-24,h=headerHeight,action=function()
                                classStates[treeName]=not open
                            end}
                        end
                        y=y+headerHeight
                        if open then
                            for _,t in ipairs(treeTalents) do
                                local rank=talents.getRank(spec.trees[treeName],t.id)
                                local tx,ty=ox+24+t.col*cell+(cell-size)/2,y+8+t.row*(size+16)
                                if ty>=top and ty+size<=bottom then
                                    local allowed,err=talents.canInvest(data,spec.trees,treeName,t)
                                    local detail=t.descriptions and (t.descriptions[tostring(math.min(t.max_ranks,rank+1))] or '') or ''
                                    tile(tx,ty,size,t.icon,t.name,rank..'/'..t.max_ranks,rank>0 or allowed,
                                        t.name..'  '..rank..'/'..t.max_ranks..'\n'..detail..(spec.class=='warrior' and ('\n'..warrior.supportText(t)) or '')..(not allowed and rank<t.max_ranks and ('\n'..tostring(err)) or ''),edit(function(b)
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
                elseif section=='Gear' and spec.class=='warrior' then
                    ui.setFont('small')
                    if y>=top and y+36<=bottom then
                        g.setColor(ui.colors.textMuted);g.printf('Item starters and explicit stat overrides',ox+24,y,left-24)
                    end
                    y=y+38
                    local half=(left-30)/2
                    for row,pair in ipairs({{{'Two-hand set','two_hand'},{'Dual-wield set','dual_wield'}},{{'Shield set','shield'},{'Clear items',false}}}) do
                        if y>=top and y+26<=bottom then
                            for column,choice in ipairs(pair) do
                                button(ox+24+(column-1)*(half+6),y,half,choice[1],edit(function()
                                    if choice[2] then
                                        local ok,err=editor.equipWarriorStarter(choice[2]);message=ok and '' or err
                                    else editor.clearGear() end
                                end))
                            end
                        end
                        y=y+32
                    end
                    for _,slot in ipairs(gear.slots) do
                        local fieldX,fieldWidth=ox+24+(left-24)*0.38,(left-24)*0.62
                        if y>=top and y+26<=bottom then
                            g.setColor(ui.colors.textMuted);g.print(slot[2],ox+24,y+5)
                            local id=spec.gear and spec.gear[slot[1]] or 0
                            local action=ui.dropdown('gear_'..i..'_'..slot[1],fieldX,y,fieldWidth,26,id,gear.choices(slot[1],'warrior'),edit(function(value)
                                local ok,err=editor.setGear(slot[1],value);message=ok and '' or err
                            end),function(value) local item=gear.item(value);return item and item.name or 'Empty' end,nil,{menuWidth=left-24})
                            buttons[#buttons+1]={x=fieldX,y=y,w=fieldWidth,h=26,action=function(b) if b==1 then action() end end}
                            local mx,my=ui.contentPoint(love.mouse.getPosition())
                            if mx>=fieldX and mx<=ox+left and my>=y and my<=y+26 and not ui.dropdownOpen() then tooltip={text=gear.detail(id),x=mx,y=my} end
                        end
                        y=y+29
                    end
                    local fields={{'max_health','Health',1,100000},{'armor_damage_reduction','Armor reduction',0,1},{'melee_avoidance_chance','Legacy avoidance',0,1},{'melee_dodge_chance','Dodge chance',0,1},{'melee_parry_chance','Parry chance',0,1},{'melee_block_chance','Block chance',0,1},{'melee_block_value','Block value',0,0,10000}}
                    for _,field in ipairs(warrior.fields) do
                        if not field[1]:match('^off_hand%.') or spec.warrior.off_hand then
                            fields[#fields+1]={'warrior.'..field[1],field[2],field[3],field[4]}
                        end
                    end
                    for _,field in ipairs(fields) do
                        local key,label=field[1],field[2]
                        local value=key:sub(1,8)=='warrior.' and warrior.value(spec.warrior,key:sub(9)) or spec.combat_stats[key]
                        if key=='warrior.main_hand.two_handed' then value=spec.warrior.main_hand.two_handed end
                        if key=='warrior.off_hand' then value=spec.warrior.off_hand~=nil end
                        if key=='warrior.damage_taken_rage' then value=spec.warrior.damage_taken_rage end
                        local fx,fw=ox+24+(left-24)*0.58,(left-24)*0.42
                        if y>=top and y+26<=bottom then
                            g.setColor(ui.colors.textMuted);g.print(label,ox+24,y+5)
                            if type(field[3])=='table' then
                                local action=ui.dropdown('warrior_'..i..key,fx,y,fw,26,value,field[3],edit(function(nextValue)
                                    local ok,err=editor.setWarriorStat(key:sub(9),nextValue);message=ok and '' or err
                                end),function(v)
                                    if key=='warrior.main_hand.two_handed' then return v and 'Two hand' or 'One hand' end
                                    if key=='warrior.off_hand' then return v and 'Weapon' or 'Empty' end
                                    if key=='warrior.shield' then return v and 'Equipped' or 'None' end
                                    if key=='warrior.damage_taken_rage' then return v and 'Enabled' or 'Disabled' end
                                    return v:sub(1,1):upper()..v:sub(2)
                                end)
                                buttons[#buttons+1]={x=fx,y=y,w=fw,h=26,action=function(b) if b==1 and commitInput() then action() end end}
                            else
                                ui.drawCard(fx,y,fw,26,false,input and input.key==key,3)
                                g.setColor(ui.colors.text);g.print(input and input.key==key and (input.text..'|') or tostring(value),fx+5,y+5)
                                buttons[#buttons+1]={x=fx,y=y,w=fw,h=26,action=edit(function()
                                    if commitInput() then input={key=key,text=tostring(value),replace=true} end
                                end)}
                            end
                        end
                        y=y+30
                    end
                    if y>=top and y+26<=bottom then button(ox+24,y,left-24,'Save spec',function() saveUnit(i) end) end
                    y=y+32;ui.resetFont()
                elseif section=='Gear' then
                    local half=(left-30)/2
                    if y>=top and y+26<=bottom then
                        button(ox+24,y,half,'Pre-BiS',edit(function() editor.equipPrebis() end))
                        button(ox+30+half,y,half,'Clear',edit(function() editor.clearGear() end))
                    end
                    y=y+32
                    if y>=top and y+26<=bottom then
                        button(ox+24,y,left-24,'Save spec',function() saveUnit(i) end)
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
                    if spec.stat_profile then table.insert(summary,1,"Reference stats (provisional)") end
                    if passive.mastery then summary[#summary+1]=passive.mastery end
                    for _,line in ipairs(summary) do
                        if y>=top and y+16<=bottom then ui.setFont('small');g.setColor(ui.colors.textMuted);g.print(line,ox+24,y);ui.resetFont() end
                        y=y+18
                    end
                    y=y+4
                    local labels={shoulder='Shoulder',main_hand='Weapon',off_hand='Off hand'}
                    local rowHeight,labelWidth=24,64
                    local fieldX,fieldWidth=ox+24+labelWidth,left-24-labelWidth
                    for _,slot in ipairs(gear.slots) do
                        if y>=top and y+rowHeight<=bottom then
                            ui.setFont('small');g.setColor(ui.colors.textMuted)
                            g.print(labels[slot[1]] or slot[2],ox+24,y+5);ui.resetFont()
                            local id=spec.gear and spec.gear[slot[1]] or 0
                            local action=ui.dropdown('gear_'..i..'_'..slot[1],fieldX,y,fieldWidth,rowHeight,id,
                                gear.choices(slot[1],spec.class),edit(function(value)
                                    local ok,err=editor.setGear(slot[1],value)
                                    message=ok and '' or err
                                end),function(value) local item=gear.item(value);return item and item.name or 'Empty' end,
                                nil,{menuWidth=left-24})
                            buttons[#buttons+1]={x=fieldX,y=y,w=fieldWidth,h=rowHeight,action=function(b) if b==1 then action() end end}
                            local mx,my=ui.contentPoint(love.mouse.getPosition())
                            if mx>=fieldX and mx<=ox+left and my>=y and my<=y+rowHeight and not ui.dropdownOpen() then tooltip={text=gear.detail(id),x=mx,y=my} end
                        end
                        y=y+rowHeight+3
                    end
                elseif section=='Pets' then
                    if spec.class=='warlock' then
                        for _,sacrifice in ipairs({false,true}) do
                            for _,kind in ipairs({'none','imp','voidwalker','succubus','felhunter'}) do
                                if y>=top and y+26<=bottom then
                                    button(ox+24,y,left-24,(sacrifice and 'Sacrifice: ' or 'Pet: ')..kind,
                                        edit(function() editor.setPet(kind,sacrifice) end),
                                        (sacrifice and spec.sacrifice_pet or spec.pet)==kind)
                                end
                                y=y+30
                            end
                            y=y+12
                        end
                    else
                        if y>=top and y+20<=bottom then
                            g.setColor(ui.colors.textMuted); g.print('This class has no pet.',ox+24,y)
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
                        local tx,ty=ox+24+((idx-1)%columns)*cell,y+math.floor((idx-1)/columns)*(size+16)
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
        local maxScroll=math.max(0,y+scroll-bottom)
        scroll=math.min(scroll,maxScroll)
        scrolls[i],maxScrolls[i]=scroll,maxScroll
        if maxScroll>0 then
            local track=bottom-top
            local thumb=math.max(24,track*track/(track+maxScroll))
            g.setColor(ui.colors.cardBorder); g.rectangle('fill',ox+left+4,top,3,track)
            g.setColor(ui.colors.primary); g.rectangle('fill',ox+left+4,top+(track-thumb)*scroll/maxScroll,3,thumb)
        end
        g.setScissor()
    end
    local cfg=generator.getConfig()
    local settingsTop = 272
    local settingsBottom = h-24
    workspace.settingsX=rx
    workspace.settingsTop=settingsTop

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

    -- Main Action Buttons above the collapsable Settings section
    local hasModels = generator.hasChampionModels and generator.hasChampionModels()
    local shouldEvolve = not hasModels and not generator.isActive()
    local halfW = (right - 24 - 6) / 2
    local topY = 24

    button(rx, topY, right-24, generator.isActive() and 'Running...' or 'Evolve/Train', function()
        local launch=prepareLaunchConfig()
        if not launch then return end
        local ok,err=generator.startLeaguePlay(launch)
        if not ok then for _,tmp in ipairs(launch.temporary_specs) do os.remove(tmp) end end
        message=ok and '' or tostring(err)
    end, true, false, shouldEvolve)

    local function launchWith(extra,start)
        local launch=prepareLaunchConfig(extra)
        if not launch then return end
        local ok,err=start(launch)
        if not ok then for _,tmp in ipairs(launch.temporary_specs) do os.remove(tmp) end end
        message=ok and '' or tostring(err)
    end

    local nt=generator.getNeuroTelemetry and generator.getNeuroTelemetry() or nil
    local polA = (nt and nt.policy_a) or "matches/neuro_champion_a.nepl"
    local polB = (nt and nt.policy_b) or "matches/neuro_champion_b.nepl"

    button(rx, topY + 34, halfW, 'Quick Fight', function()
        if not hasModels then return end
        launchWith({policy_a=polA, policy_b=polB, seed=math.random(1,2^31-1),
            output='matches/neuro_champ_vs_champ.lua'}, generator.startFight)
    end, false, not hasModels)

    button(rx + halfW + 6, topY + 34, halfW, 'Polished fight', function()
        if not hasModels then return end
        launchWith({rollout_policy_a=polA, rollout_policy_b=polB, seed=math.random(1,2^31-1),
            output='matches/neuro_champ_vs_champ.lua'}, generator.startFight)
    end, false, not hasModels)

    local bulkCount = cfg.bulk_fights or 1000
    button(rx, topY + 68, right-24, string.format('Simulate batch (%d)', bulkCount), function()
        if not hasModels then return end
        launchWith(nil, generator.startBulkEval)
    end, false, not hasModels)

    -- Evolution Win Rate Graph (A on positive Y, B on negative Y, X for generation)
    local gx = rx
    local gy = topY + 98
    local gw = right - 24
    local gh = 112
    ui.drawCard(gx, gy, gw, gh, false, false, 4)

    local midY = gy + (26 + gh - 14) / 2
    -- Baseline (50% / 0 net advantage)
    g.setColor(0.18, 0.24, 0.35, 0.7)
    g.setLineWidth(1)
    g.line(gx + 20, midY, gx + gw - 6, midY)

    -- Y-axis Labels
    ui.setFont('small')
    g.setColor(ui.colors.primary)
    g.print('A', gx + 6, gy + 4)
    g.setColor(ui.colors.accentGold)
    g.print('B', gx + 6, gy + gh - 16)
    ui.resetFont()

    local graphMX,graphMY=love.mouse.getPosition()
    if graphMX>=gx and graphMX<=gx+gw and graphMY>=gy and graphMY<=gy+gh then
        tooltip={text="Both lines show Fighter A's score (wins + half of draws).\nSolid blue / Train: current candidate against archived opponents; the evolving side alternates.\nDashed gold / Pair: current champions against each other in 112 fights, using the batch evaluation settings.\nThe final Pair point uses the saved champions. These percentages can differ and need not rise together.",x=graphMX,y=graphMY}
    end
    local hist = nt and nt.history
    if hist and #hist > 0 then
        local maxGen = 1
        for _, pt in ipairs(hist) do
            if (pt.gen or 0) > maxGen then maxGen = pt.gen end
        end
        local plotX = gx + 22
        local plotW = gw - 30
        local plotH = gh - 40

        local points = {}
        local pairPoints = {}
        for idx, pt in ipairs(hist) do
            local xPct = (maxGen > 0) and ((pt.gen or idx) / maxGen) or ((idx - 1) / (#hist - 1))
            if #hist == 1 then xPct = 0.5 end
            local px = plotX + xPct * plotW
            -- Keep the plot below the legend so 100% scores remain visible.
            local py = midY - ((pt.win_rate_a or 0.5) - 0.5) * 2 * (plotH / 2)
            if pt.win_rate_a ~= nil then
                points[#points + 1] = px
                points[#points + 1] = py
            end
            if pt.pair_win_rate_a then
                local pairY = midY - (pt.pair_win_rate_a - 0.5) * plotH
                pairPoints[#pairPoints + 1] = px
                pairPoints[#pairPoints + 1] = pairY
            end
        end

        neuroGraph.draw(g,points,pairPoints,ui.colors.accentGold)

        if #points >= 2 then
            g.setColor(0.35, 0.77, 0.98, 0.9)
            -- Training candidate rate label
            local lastWR = (nt.win_rate_a or 0.5) * 100
            for i=#hist,1,-1 do
                if hist[i].win_rate_a ~= nil then lastWR=hist[i].win_rate_a*100;break end
            end
            ui.setFont('small')
            g.setColor(0.35, 0.77, 0.98, 1.0)
            g.print(string.format('Train A %.0f%%', lastWR), gx + 22, gy + 3)
            ui.resetFont()
        end

        if #pairPoints >= 2 then
            g.setColor(ui.colors.accentGold)
            ui.setFont('small')
            g.setColor(ui.colors.accentGold)
            g.print(string.format('Pair A %.0f%%', (hist[#hist].pair_win_rate_a or 0.5) * 100), gx + 120, gy + 3)
            ui.resetFont()
        end
    else
        ui.setFont('small')
        g.setColor(0.30, 0.38, 0.48, 0.8)
        local waitingText = generator.isActive() and 'Gathering generations...' or 'No generation history'
        g.printf(waitingText, gx + 22, midY - 6, gw - 28, 'center')
        ui.resetFont()
    end

    -- Neuroevolution Progress Bar & Status (between graph and settings)
    local progY = gy + gh + 8
    local progW = right - 24
    local progH = 6
    local prog = (generator.getProgress and generator.getProgress()) or 0
    if not generator.isActive() and nt and nt.converged then prog = 1.0 end

    -- Background Track
    g.setColor(0.06, 0.09, 0.14, 0.95)
    g.rectangle('fill', rx, progY, progW, progH, 3)

    -- Filled Bar
    if prog > 0 then
        g.setColor(ui.colors.primary[1], ui.colors.primary[2], ui.colors.primary[3], 0.9)
        g.rectangle('fill', rx, progY, math.max(4, progW * math.min(1.0, prog)), progH, 3)
    end

    -- Progress Label / Subtext
    ui.setFont('small')
    if generator.isActive() then
        local sideText = nt and nt.side and (' (' .. nt.side .. ')') or ''
        local epText = string.format('Evolving%s · Ep %d/%d', sideText, nt and nt.epoch or 0, nt and nt.max_epochs or cfg.epochs or 10)
        g.setColor(0.35, 0.77, 0.98, 0.9)
        g.print(epText, rx, progY + progH + 4)
        if nt and nt.fights_sec and nt.fights_sec > 0 then
            g.setColor(ui.colors.textMuted)
            g.printf(string.format('%.0fk/s', nt.fights_sec / 1000), rx, progY + progH + 4, progW, 'right')
        end
    elseif nt and nt.converged then
        g.setColor(0.30, 0.85, 0.50, 0.9)
        g.print(string.format('Archive score stable (%d epochs)', nt.epoch or 0), rx, progY + progH + 4)
    elseif nt and nt.epoch and nt.epoch > 0 then
        g.setColor(ui.colors.textMuted)
        g.print(string.format('Completed (%d epochs)', nt.epoch or 0), rx, progY + progH + 4)
    else
        g.setColor(0.30, 0.38, 0.48, 0.7)
        g.print('Ready to evolve', rx, progY + progH + 4)
    end
    ui.resetFont()

    ui.scissor(rx-2, settingsTop, right-18, settingsBottom - settingsTop)
    local sy=settingsTop + 8 - settingsScroll
    local function settingButton(y,label,action,active)
        if y>=settingsTop and y+26<=settingsBottom then button(rx,y,right-24,label,action,active) end
    end
    local function settingText(y,text)
        ui.setFont('small');g.setColor(ui.colors.textMuted)
        local _,lines=g.getFont():getWrap(text,right-24)
        local height=#lines*g.getFont():getHeight()+8
        if y+height>settingsTop and y<settingsBottom then g.printf(text,rx,y,right-24) end
        ui.resetFont()
        return y+height
    end
    local function dropdown(label,key,values,fmt)
        if sy>=settingsTop and sy+18<=settingsBottom then
            g.setColor(ui.colors.textMuted); g.print(label,rx,sy)
        end
        sy=sy+22
        if sy>=settingsTop and sy+26<=settingsBottom then
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
    local focusScroll
    local function sectionHeader(name,label,isSub)
        if settingsFocus==name then focusScroll=sy+settingsScroll-settingsTop end
        local open = settingsOpen[name]
        local inset = isSub and 10 or 0
        local cardX = rx + inset
        local cardW = right - 24 - inset
        local cardH = isSub and 28 or 32
        if sy>=settingsTop and sy+cardH<=settingsBottom then
            local mx,my=ui.contentPoint(love.mouse.getPosition())
            local hover=mx>=cardX and mx<=cardX+cardW and my>=sy and my<=sy+cardH
            ui.drawCard(cardX, sy, cardW, cardH, hover, open, 5)
            ui.chevron(cardX + 12, sy + cardH/2, open)
            g.setColor(open and ui.colors.text or (hover and ui.colors.text or ui.colors.textMuted))
            if isSub then
                ui.setFont('normal')
                g.print(label, cardX + 26, sy + 5)
            else
                ui.setFont('bold')
                g.print(label, cardX + 26, sy + 6)
            end
            ui.resetFont()
            buttons[#buttons+1] = {x=cardX, y=sy, w=cardW, h=cardH, label=label, action=function(b)
                if b==1 and commitInput() then
                    settingsOpen[name] = not open
                    ui.closeDropdown()
                end
            end}
        end
        sy=sy+cardH+6
        return settingsOpen[name]
    end

    if sectionHeader('settings','Settings') then
        if sectionHeader('mcts','MCTS Settings',true) then
            dropdown('Fight time limit','fight_seconds',{15,30,60,90,120,180,300,600},function(value)
                if value<60 then return value..' sec' end
                local seconds=value%60
                return math.floor(value/60)..' min'..(seconds>0 and (' '..seconds..' sec') or '')
            end)
            dropdown('Rollouts / decision','rollouts',{1024,4096,16384,65536})
            dropdown('Worker threads','workers',{1,2,4,8,16,32})
            dropdown('Algorithm','algorithm',{'puct','uct','exp3'})
            dropdown('Leaf scorer','evaluator',{'heuristic','rollout'})
            dropdown('Starting distance (m)','distance',{10,20,25,35})
            settingButton(sy,'Reset positions',function() resetPositions(25); cfg.distance=25; workspace.editPositions() end)
            sy=sy+40
        end

        if sectionHeader('league','Neuroevolution Settings',true) then
            dropdown('Fights / epoch','fights_per_epoch',{10000,50000,100000,250000},function(v)
                return string.format('%dk',math.floor(v/1000))
            end)
            dropdown('Max epochs','epochs',{4,6,10,20})
            dropdown('Population size','population_size',{32,64,128})
            dropdown('Early stop threshold','convergence_threshold',{0,0.01,0.02,0.05},function(v)
                return v==0 and 'Off' or string.format('%.0f%%',v*100)
            end)
            if nt and (generator.isActive() or (nt.epoch and nt.epoch>0)) then
                local prog=generator.getProgress and generator.getProgress() or 0
                if sy>=settingsTop and sy+10<=settingsBottom then
                    g.setColor(0.08,0.12,0.18,0.95)
                    g.rectangle('fill',rx,sy,right-24,8,3)
                    g.setColor(ui.colors.primary)
                    g.rectangle('fill',rx,sy,(right-24)*math.max(0,math.min(1,prog)),8,3)
                end
                sy=sy+14
                local convText=nt.converged and 'Archive score stable' or (generator.isActive() and ('Evolving '..tostring(nt.side)) or 'Completed')
                local resultLabel=generator.isActive() and 'Latest A estimate' or 'Final A vs B'
                local info=string.format('%s · Ep %d/%d (%d gens)\n%s: %.1f%% · %.0fk fights/s',
                    convText,nt.epoch or 0,nt.max_epochs or cfg.epochs,nt.gens or 0,
                    resultLabel,(nt.win_rate_a or 0.5)*100,(nt.fights_sec or 0)/1000)
                if nt.archive_score_a and nt.archive_score_b then
                    info=info..string.format('\nArchive scores A/B: %.2f / %.2f',nt.archive_score_a,nt.archive_score_b)
                end
                sy=settingText(sy,info)
            end
            if nt and nt.policy_a and nt.policy_b then
                sy=settingText(sy,'League-selected models:\n'..nt.policy_a..'\n'..nt.policy_b)
            end
        end

        if sectionHeader('batch','Batch Simulation Settings',true) then
            dropdown('Bulk fights','bulk_fights',{100,1000,10000,100000})
            dropdown('Start lag jitter (s)','jitter_start_lag',{0,0.25,0.5,1.0},function(v)
                return v==0 and 'Off' or string.format('0 – %.2f s',v)
            end)
            dropdown('Position jitter (yd)','jitter_pos',{0,1,2.5,5},function(v)
                return v==0 and 'Off' or string.format('± %.1f yd',v)
            end)
            local be=generator.getBulkEval and generator.getBulkEval() or nil
            if be then
                local nameA=(drafts[1] and drafts[1].name) or 'A'
                local nameB=(drafts[2] and drafts[2].name) or 'B'
                sy=settingText(sy,string.format(
                    'Bulk result · %d fights in %.2fs\n'..
                    'A (%s) wins: %d (%.1f%% ± %.1f%%)\n'..
                    'B (%s) wins: %d (%.1f%%)\n'..
                    'Draws: %d · Timeouts: %d\n'..
                    'Fight length: avg %.1fs · median %.1fs · %.1f–%.1fs\n'..
                    'A wins: avg %.1fs, %.0f%% HP left\n'..
                    'B wins: avg %.1fs, %.0f%% HP left',
                    be.fights or 0,be.seconds or 0,
                    nameA,be.wins_a or 0,(be.win_rate_a or 0)*100,(be.ci95 or 0)*100,
                    nameB,be.wins_b or 0,(1-(be.win_rate_a or 0))*100,
                    be.draws or 0,be.timeouts or 0,
                    be.avg_fight_s or 0,be.median_fight_s or 0,be.min_fight_s or 0,be.max_fight_s or 0,
                    be.avg_fight_s_a_wins or 0,(be.avg_hp_left_a_wins or 0)*100,
                    be.avg_fight_s_b_wins or 0,(be.avg_hp_left_b_wins or 0)*100))
            end
        end

        local function openReplay(path)
            if not commitInput() then return end
            if loadReplay then loadReplay(path); workspace.showReplay() end
        end
        if sectionHeader('replays','Fight replays [F2]',true) then
            sy=browser.drawPanel(sy,settingButton,settingText,openReplay)
        end
        if sectionHeader('matrix','Matrix [F4]',true) then
            sy=matrix.drawPanel(sy,settingButton,settingText,openReplay)
        end
    end

    settingsMax=math.max(0,sy+settingsScroll-settingsBottom)
    settingsScroll=math.min(focusScroll or settingsScroll,settingsMax)
    settingsFocus=nil
    g.setScissor()
    if settingsMax>0 then
        local track=settingsBottom-settingsTop
        local thumb=math.max(24,track*track/(track+settingsMax))
        g.setColor(ui.colors.cardBorder);g.rectangle('fill',w-22,settingsTop,3,track)
        g.setColor(ui.colors.primary);g.rectangle('fill',w-22,settingsTop+(track-thumb)*settingsScroll/settingsMax,3,thumb)
    end
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
    detailBounds={}
    workspace.details=detailBounds
    frameBounds={}
    workspace.frameBounds=frameBounds
    local scale=replayViewport.scale
    for i=1,2 do
        local fx=replayViewport.x+(i==1 and 16 or replayViewport.virtualW-336)*scale
        local fy=replayViewport.y+12*scale
        local fw,fh=320*scale,194*scale
        frameBounds[i]={x=fx,y=fy,w=fw,h=fh}
        local spec=drafts[i]
        local function anchor(id,x,y,width,height,value,choices,onSelect,format,label,options)
            local action=ui.dropdown(id,fx+x*scale,fy+y*scale,width*scale,height*scale,
                value,choices,onSelect,format,label,options)
            buttons[#buttons+1]={x=fx+x*scale,y=fy+y*scale,w=width*scale,h=height*scale,
                action=function(b) if b==1 and commitInput() then action() end end}
        end
        anchor('class_'..i,4,3,62,62,spec.class,{'warlock','frost_mage','priest','warrior'},function(class)
            if class==drafts[i].class then return end
            editUnit(i,function() editor.setClass(class);scrolls[i]=0 end)()
        end,function(class) return class=='frost_mage' and 'Mage' or (class=='priest' and 'Priest' or (class=='warrior' and 'Warrior' or 'Warlock')) end,
            nil,{portrait=true,menuWidth=180})
        local preset
        for _,candidate in ipairs(saved) do
            if candidate.name==spec.name and candidate.class==spec.class then preset=candidate;break end
        end
        anchor('preset_'..i,72,4,240,20,preset,saved,editUnit(i,function(value)
            editor.loadSpec(value);scrolls[i]=0
        end),function(value) return value.name or value.filename or 'Unnamed spec' end,
            (i==1 and 'A · ' or 'B · ')..(spec.name or 'Custom spec'),{menuWidth=320})
        anchor('class_text_'..i,72,27,118,22,spec.class,{'warlock','frost_mage','priest','warrior'},function(class)
            if class~=drafts[i].class then
                editUnit(i,function() editor.setClass(class);scrolls[i]=0 end)()
            end
        end,function(class) return class=='frost_mage' and 'Mage' or (class=='priest' and 'Priest' or (class=='warrior' and 'Warrior' or 'Warlock')) end,
            nil,{menuWidth=180})
        local race=races.normalize(spec.race,spec.class)
        anchor('race_'..i,194,27,118,22,race,races.choices(spec.class),function(value)
            if value~=race then editUnit(i,function() editor.setRace(value) end)() end
        end,function(value) return races.labels[value] end,nil,{menuWidth=180})
        local cx,cy=fx+fw/2,fy+fh+10
        local mx,my=ui.contentPoint(love.mouse.getPosition())
        local hovered=mx>=fx and mx<=fx+fw and my>=fy+fh and my<=fy+fh+20
        local now=love.timer and love.timer.getTime and love.timer.getTime() or os.clock()
        local alpha=hovered and 1 or 0.62+0.18*math.sin(now*math.pi*2/2.8)
        local direction=expanded[i] and -1 or 1
        local gold=ui.colors.accentGold
        g.push('all')
        g.setColor(gold[1],gold[2],gold[3],alpha)
        g.setLineWidth(1.5)
        for _,offset in ipairs({-3,3}) do
            local y=cy+offset
            g.line(cx-6,y-2*direction,cx,y+2*direction,cx+6,y-2*direction)
        end
        g.pop()
        if expanded[i] then drawUnitDetails(i,fx-12,fy+fh+22,fw) end
    end
    workspace.detailBounds=detailBounds[selected]
    if workspace.detailBounds then workspace.scrollTop=workspace.detailBounds.scrollTop end
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
    for _,v in ipairs(buttons) do
        if x>=v.x and x<=v.x+v.w and y>=v.y and y<=v.y+v.h then v.action(b);return true end
    end
    for i,bounds in ipairs(frameBounds) do
        if x>=bounds.x and x<=bounds.x+bounds.w and y>=bounds.y and y<=bounds.y+bounds.h+20 then
            if b==1 and focus(i) then expanded[i]=not expanded[i];ui.closeDropdown() end
            return true
        end
    end
    for _,bounds in pairs(detailBounds) do
        if x>=bounds.x and x<=bounds.x+bounds.w and y>=bounds.y and y<=bounds.y+bounds.h then return true end
    end
    local view=replayViewport
    if b==1 and view and tokenFrame then
        local scale=camera.worldScale
        local ax,ay,bx,by
        if tokenDrawPositions then
            ax,ay,bx,by=tokenDrawPositions[1],tokenDrawPositions[2],tokenDrawPositions[3],tokenDrawPositions[4]
        else
            ax,ay,bx,by=camera.tokenPositions(tokenFrame[3]*scale,(tokenFrame[49] or 0)*scale,
                tokenFrame[4]*scale,(tokenFrame[50] or 0)*scale)
        end
        for i=2,1,-1 do
            local vx,vy=ui.viewportPoint(view,x,y)
            local px,py=camera.worldPoint(view,(i==1 and ax or bx)/scale,(i==1 and ay or by)/scale)
            if x>=view.x and x<=view.x+view.w and y>=view.y and y<=view.y+view.h
                and vy>154 and vy<view.virtualH-(arena and 60 or 120) and (vx-px)^2+(vy-py)^2<=(32*camera.zoom)^2 then
                if not focus(i) then return true end
                if arena then
                    local wx,wy=camera.screenPoint(view,vx,vy)
                    dragging={i=i,dx=wx-positions[i].x,dy=wy-positions[i].y,startX=x,startY=y,active=false}
                end
                return true
            end
        end
    end
    return false
end
function workspace.wheelmoved(y)
    local mx,my=ui.contentPoint(love.mouse.getPosition())
    if mx>=(workspace.settingsX or math.huge) and my>=(workspace.settingsTop or 272) and my<ui.height()-24 then
        ui.closeDropdown()
        settingsScroll=math.max(0,math.min(settingsMax,settingsScroll-y*40))
        return true
    end
    for i,bounds in pairs(detailBounds) do
        if mx>=bounds.x and mx<=bounds.x+bounds.w and my>=bounds.y and my<=bounds.y+bounds.h then
            ui.closeDropdown()
            scrolls[i]=math.max(0,math.min(maxScrolls[i],scrolls[i]-y*40))
            return true
        end
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
    if not allowOutside then
        for _,bounds in pairs(detailBounds) do
            if x>=bounds.x and x<=bounds.x+bounds.w and y>=bounds.y and y<=bounds.y+bounds.h then return nil end
        end
    end
    if not allowOutside and (x<view.x or x>view.x+view.w or y<view.y or y>view.y+view.h) then return nil end
    local px,py=ui.viewportPoint(view,x,y)
    return px,py,view
end
-- A render-only snapshot; editing never mutates the loaded replay.
function workspace.preview()
    init(); capture()
    local frame,meta={}, {total_time=0,victor=-1}
    for i=1,136 do frame[i]=0 end
    frame[2]=distance()
    local kinds={imp=1,succubus=2,felhunter=3,voidwalker=4}
    local hp={500,700,900,1200}
    local cfg=generator.getConfig()
    for i,side in ipairs({'a','b'}) do
        local spec=drafts[i]
        meta['max_health_'..side]=maximumHealth(spec)
        meta['pvp_trinket_'..side]=gear.pvpItem(spec.gear) or 0
        meta.item_cooldown_column=163
        local t = spec.trees and spec.trees.Demonology or {}
        local felVitality = spec.class=='warlock' and (t['105903'] or t[105903] or 0) or 0
        local maxMana = races.maxMana(spec.race,spec.combat_stats.max_mana)*(1+0.05*felVitality)
        meta['max_mana_'..side]=maxMana
        if spec.class=='warrior' then
            meta['max_rage_'..side]=warrior.maxRage(spec)
            frame[124+i]=math.min(spec.warrior.starting_rage,warrior.maxRage(spec))
            frame[126+i]=warrior.stances[spec.warrior.starting_stance]
            maxMana=0;meta['max_mana_'..side]=1
        end
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
