-- Class-scoped replay effects: action IDs are shared across different kits.
local M = {}
local holy = {1.0, 0.80, 0.30}
local shadow = {0.70, 0.32, 1.0}
M.priestToken = {0.96, 0.90, 0.72}
M.warriorToken = {0.78, 0.54, 0.32}

function M.color(spec, spell)
    if spec == 'warrior' then return {1.0,0.72,0.38} end
    if spec == 'priest' then
        if spell == 13 or spell == 14 or spell == 15 then return holy end
        return shadow
    end
    if spec == 'frost_mage' then return {0.3, 0.8, 1.0} end
    if spell == 7 then return {0.15, 0.95, 0.35} end
    return {0.85, 0.4, 1.0}
end

function M.channel(spec, spell)
    if spec == 'warlock' and spell == 5 then return 'drain' end
    if spec == 'priest' and spell == 5 then return 'shadow' end
    if spec == 'priest' and spell == 15 then return 'holy' end
end

function M.drawChannel(g, sx, sy, tx, ty, time, color)
    local dx, dy = tx - sx, ty - sy
    local length = math.sqrt(dx * dx + dy * dy)
    if length < 1 then return end
    local nx, ny = -dy / length, dx / length
    local width = g.getLineWidth()
    for strand = 1, 3 do
        local points = {}
        for step = 0, 24 do
            local t = step / 24
            local wave = math.sin(t * 22 - time * 12 + strand * 2) * 5 * math.sin(t * math.pi)
            points[#points + 1] = sx + dx * t + nx * wave
            points[#points + 1] = sy + dy * t + ny * wave
        end
        g.setColor(color[1], color[2], color[3], strand == 1 and 0.65 or 0.25)
        g.setLineWidth(strand == 1 and 2 or 5)
        g.line(points)
    end
    g.setLineWidth(width)
end

return M
