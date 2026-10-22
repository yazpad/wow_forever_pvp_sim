package.path='visualizer/?.lua;'..package.path
local noop=function() end
local font={getHeight=function() return 12 end,getWrap=function(_,text,width)
    local lines={}
    local count=math.max(1,math.floor(width/7))
    for i=1,#text,count do lines[#lines+1]=text:sub(i,i+count-1) end
    return width,lines
end}
love={graphics=setmetatable({getFont=function() return font end,getWidth=function() return 1280 end,
    getHeight=function() return 900 end},{__index=function() return noop end})}
local log=require('combat_log')
local data={meta={name_a='Alice',name_b='Bob',spec_a='warlock',spec_b='frost_mage'},events={
    {t=0,s=0,k=1,sp=1,a=0},{t=1,s=1,k=0,sp=1,a=0},
    {t=1,s=0,k=4,sp=1,a=125},{t=2,s=0,k=6,sp=5,a=50},
}}
log.sync(data,0)
assert(#log.entries==1 and log.entries[1]:find('Alice began casting'))
log.sync(data,1)
assert(#log.entries==3 and log.entries[2]:find('Bob used'))
assert(log.entries[3]:find('125 HP',1,true))
log.sync(data,1);assert(#log.entries==3,'Paused frames must not duplicate events')
log.sync(data,2);assert(#log.entries==4 and log.entries[4]:find('50 HP',1,true))
log.sync(data,0.5);assert(#log.entries==1,'Seeking backward must remove future events')
log.sync(data,2);assert(#log.entries==4,'Seeking forward must rebuild all elapsed events')
local nextFight={meta={name_a='New fighter'},events={{t=1,s=0,k=0,sp=1,a=0}}}
log.sync(nextFight,0)
assert(#log.entries==0 and log.offset==0,'Loading another replay clears the history')
log.sync(nextFight,1)
assert(#log.entries==1 and log.entries[1]:find('New fighter') and not log.entries[1]:find('Alice'))
log.reset();log.sync(nextFight,0)
assert(#log.entries==0,'Reloading the same fight clears the history')
local many={meta=data.meta,events={}}
for i=1,60 do many.events[i]={t=i,s=i%2,k=4,sp=1,a=i} end
log.draw(many,40,16,400,320,186)
assert(#log.entries==40 and log.maxOffset>0 and log.offset==0)
assert(not log.wheel(800,500,1) and log.offset==0)
assert(log.wheel(30,440,2) and log.offset==6)
log.draw(many,41,16,400,320,186)
assert(log.offset>6,'Reading older events must preserve the scrolled position as new events arrive')
log.wheel(30,440,-1000);assert(log.offset==0)
log.draw(many,42,16,400,320,186);assert(log.offset==0,'The latest view follows new events')
log.wheel(30,440,0.25);log.draw(many,42,16,400,320,186)
log.draw(many,0,16,400,320,186)
assert(#log.entries==0 and log.offset==0,'Restarting the fight clears history and scrolling')
for kind=0,18 do assert(type(log.format(data.meta,{t=0,s=0,k=kind,sp=1,a=1}))=='string') end
print('Combat log: all event kinds, chronological history, seeks, replay resets, scrolling and follow behavior passed.')
