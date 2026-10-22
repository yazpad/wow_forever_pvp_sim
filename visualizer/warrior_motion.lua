-- Presentation-only Charge/Intercept travel, reconstructed from replay time.
local classes = require('class_view')
local motion = {}
local cachedMatch, charges
local duration = 0.16

local function frameIndex(frames, time)
    local low,high,result=1,#frames,0
    while low<=high do
        local mid=math.floor((low+high)/2)
        if frames[mid][1]<=time then result=mid;low=mid+1 else high=mid-1 end
    end
    return result
end

local function prepare(match)
    cachedMatch,charges=match,{}
    local frames=match.frames or {}
    for _,event in ipairs(match.events or {}) do
        local side=event.s or event.src or event.source
        local spell=event.sp or event.spell or event.spell_id
        local kind=event.k or event.kind
        local time=event.t or event.time_s
        if kind==0 and (side==0 or side==1) and (spell==3 or spell==4)
            and time and classes.spec(match.meta,side)=='warrior' then
            -- Action events describe the state after that physics tick.
            local after=frameIndex(frames,time+0.0001)
            local before=frameIndex(frames,time-0.0001)
            local start=frames[before]
            local finish=frames[after]
            local sx,sy
            if start then sx,sy=start[3+side],start[49+side] or 0
            elseif match.meta.initial_positions then
                sx=match.meta.initial_positions[1+side*2]
                sy=match.meta.initial_positions[2+side*2]
            end
            if sx and finish then
                table.insert(charges,{time=time,side=side,
                    dx=sx-finish[3+side],dy=sy-(finish[49+side] or 0)})
            end
        end
    end
end

function motion.position(match,time,side,x,y)
    if match~=cachedMatch then prepare(match) end
    for i=#charges,1,-1 do
        local charge=charges[i]
        if charge.time<=time then
            local elapsed=time-charge.time
            if elapsed>=duration then break end
            if charge.side==side then
                -- Ease out quickly, following subsequent real movement at the endpoint.
                local remaining=(1-elapsed/duration)^2
                return x+charge.dx*remaining,y+charge.dy*remaining,true
            end
        end
    end
    return x,y
end
return motion
