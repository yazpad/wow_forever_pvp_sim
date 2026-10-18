local classes = require('class_view')
local feedback = {}

-- Derive from replay time so pausing and seeking preserve the same feedback.
function feedback.instant(events, time, side, meta)
    for i = #(events or {}), 1, -1 do
        local ev = events[i]
        if ev.t <= time then
            if time - ev.t >= 1 then return nil end
            if ev.s == side then
                -- A later cast must also suppress earlier instant feedback once it ends.
                if ev.k == 1 or ev.k == 2 or ev.k == 3 then return nil end
                if ev.k == 0 and ev.sp > 0 then
                    local name = classes.name(meta, side, ev.sp)
                    if name == 'Cancel Cast' or name == 'None' then return nil end
                    return {id=ev.sp, alpha=1-(time-ev.t)}
                end
            end
        end
    end
end

return feedback
