-- Shared normalization for overhead vitals and unit frames, including old replays.
local vitals = {}
function vitals.fraction(meta, side, resource, current)
    meta=meta or {}
    local fallback = resource == 'health' and 2000 or (resource=='rage' and 100 or 1000)
    local maximum = meta['max_'..resource..(side == 0 and '_a' or '_b')] or fallback
    return math.max(0, math.min(1, current / math.max(1, maximum)))
end
return vitals
