local ui=require('ui')
local class_view=require('class_view')
local log={entries={},offset=0}
local match,nextIndex,lastTime,dirty=nil,1,0,true
local lines,wrappedWidth,wrappedFont={},nil,nil
local schools={[1]='Shadow',[2]='Fire',[3]='Frost',[4]='Arcane',[5]='Holy'}
local petNames={'Imp','Succubus','Felhunter','Voidwalker'}
function log.format(meta,ev)
    local spName = class_view.name(meta, ev.s, ev.sp)
    local srcName = ev.s == 0 and (meta.name_a or "Unit A") or (meta.name_b or "Unit B")
    local desc = ""
    if ev.k == 0 then
        desc = string.format("used %s", spName)
    elseif ev.k == 1 then
        desc = string.format("began casting %s", spName)
    elseif ev.k == 2 then
        desc = string.format("completed %s", spName)
    elseif ev.k == 3 then
        desc = string.format("%s was interrupted!", spName)
    elseif ev.k == 4 then
        desc = string.format("%s hit for -%.0f HP", spName, (ev.a or 0))
    elseif ev.k == 5 then
        desc = string.format("%s tick (-%.0f HP)", ev.sp == 5 and "Siphon" or "DoT", (ev.a or 0))
    elseif ev.k == 6 then
        local healName = ({[5]="Drain Life", [6]="Healthstone", [7]="Death Coil", [8]="Siphon Life"})[ev.sp] or "Heal"
        desc = string.format("%s heal (+%.0f HP)", healName, (ev.a or 0))
    elseif ev.k == 7 then
        desc = class_view.spec(meta, ev.s) == "frost_mage" and "applied Polymorph" or "applied Fear"
    elseif ev.k == 8 then
        desc = "Fear broke"
    elseif ev.k == 9 then
        desc = class_view.spec(meta, ev.s) == "frost_mage" and "activated Ice Barrier" or "used Healthstone"
    elseif ev.k == 10 then
        desc = string.format("Death Coil hit (-%.0f HP)", (ev.a or 0))
    elseif ev.k == 11 then
        desc = "applied Death Coil Horror"
    elseif ev.k == 12 then
        desc = "applied Frost Nova Root"
    elseif ev.k == 13 then
        desc = "cast Blink"
    elseif ev.k == 14 then
        desc = "cast Counterspell"
    elseif ev.k == 19 then
        desc = "activated PvP Trinket"
    elseif ev.k == 18 then
        desc = string.format("Blackout stunned for %.2fs", (ev.a or 0))
    elseif ev.k == 17 then
        desc = string.format("locked out %s magic", schools[ev.sp] or "unknown")
    elseif ev.k == 16 then
        desc = string.format("%s hit for -%.0f HP", petNames[ev.sp] or "Pet", (ev.a or 0))
    else
        desc = string.format("%s (%.0f)", spName, (ev.a or 0))
    end
    return string.format('[%.2fs] %s %s',ev.t or 0,srcName,desc)
end
function log.reset()
    match=nil;nextIndex=1;lastTime=0
    log.entries={};log.offset=0;log.maxOffset=0;log.bounds=nil
    lines={};dirty=true
end
function log.sync(data,time)
    if data~=match or time<lastTime then log.reset();match=data end
    lastTime=time
    local events=data and data.events or {}
    while nextIndex<=#events and (events[nextIndex].t or 0)<=time do
        log.entries[#log.entries+1]=log.format(data.meta or {},events[nextIndex])
        nextIndex=nextIndex+1;dirty=true
    end
end
function log.contains(x,y)
    local b=log.bounds
    return b and x>=b.x and x<=b.x+b.w and y>=b.y and y<=b.y+b.h
end
function log.wheel(x,y,delta)
    if not log.contains(x,y) then return false end
    log.offset=math.max(0,math.min(log.maxOffset or 0,log.offset+math.floor(delta*3)))
    return true
end
function log.draw(data,time,x,y,w,h)
    log.sync(data,time)
    log.bounds={x=x,y=y,w=w,h=h}
    local g=love.graphics
    g.push('all')
    ui.drawCard(x,y,w,h,false,false,6)
    ui.setFont('bold');g.setColor(ui.colors.text);g.print('Combat log',x+10,y+8)
    ui.setFont('small')
    local font=g.getFont()
    if dirty or wrappedWidth~=w or wrappedFont~=font then
        local previous=#lines
        lines={}
        for _,entry in ipairs(log.entries) do
            local _,wrapped=font:getWrap(entry,w-30)
            for _,line in ipairs(wrapped) do lines[#lines+1]=line end
        end
        if log.offset>0 then log.offset=log.offset+math.max(0,#lines-previous) end
        dirty=false;wrappedWidth=w;wrappedFont=font
    end
    local row=font:getHeight()+3
    local capacity=math.max(1,math.floor((h-42)/row))
    log.maxOffset=math.max(0,#lines-capacity)
    log.offset=math.min(log.offset,log.maxOffset)
    ui.scissor(x+8,y+32,w-16,h-40)
    g.setColor(ui.colors.textMuted)
    if #lines==0 then g.print('No events yet',x+10,y+32) end
    local last=#lines-log.offset
    local first=math.max(1,last-capacity+1)
    for i=first,last do g.print(lines[i],x+10,y+32+(i-first)*row) end
    g.setScissor()
    if log.maxOffset>0 then
        local track=h-40
        local thumb=math.max(16,track*capacity/#lines)
        g.setColor(ui.colors.primary)
        g.rectangle('fill',x+w-7,y+32+(track-thumb)*(1-log.offset/log.maxOffset),3,thumb)
    end
    g.pop()
end
return log
