-- Keep both series visible when their scores coincide.
local graph = {}

local function dashed(g, points)
    local phase = 0
    for i = 3, #points, 2 do
        local x, y = points[i-2], points[i-1]
        local dx, dy = points[i]-x, points[i+1]-y
        local length = math.sqrt(dx*dx + dy*dy)
        local offset = 0
        while offset < length do
            local step = math.min(length-offset, (phase < 6 and 6 or 11)-phase)
            if phase < 6 then
                g.line(x+dx*offset/length, y+dy*offset/length,
                    x+dx*(offset+step)/length, y+dy*(offset+step)/length)
            end
            offset = offset + step
            phase = (phase + step) % 11
        end
    end
end

function graph.draw(g, train, pair, gold)
    g.setColor(0.35, 0.77, 0.98, 1)
    g.setLineWidth(3.5)
    if #train >= 4 then g.line(train) end
    if #train >= 2 then g.circle('fill', train[#train-1], train[#train], 3.5) end

    g.setColor(gold)
    g.setLineWidth(1.5)
    dashed(g, pair)
    -- An open ring leaves the blue endpoint visible when the points coincide.
    if #pair >= 2 then g.circle('line', pair[#pair-1], pair[#pair], 5.5) end
    g.setLineWidth(1)
end

return graph
