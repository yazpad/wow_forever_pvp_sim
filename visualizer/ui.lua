-- Shared layout for the application shell and its content views.
local ui = { headerHeight = 64, inset = 0 }
function ui.scale()
    return math.min(1, (love.graphics.getHeight() - ui.headerHeight) / 640)
end
function ui.width() return love.graphics.getWidth() / ui.scale() end
function ui.height() return (love.graphics.getHeight() - ui.headerHeight) / ui.scale() - ui.inset end
function ui.dimensions() return ui.width(), ui.height() end
function ui.contentPoint(x, y)
    return x / ui.scale(), (y - ui.headerHeight) / ui.scale()
end
function ui.scissor(x, y, w, h)
    local scale = ui.scale()
    love.graphics.setScissor(x * scale, ui.headerHeight + (y + ui.inset) * scale,
        w * scale, h * scale)
end
function ui.withInset(amount, draw)
    love.graphics.push('all')
    love.graphics.translate(0, amount)
    ui.inset = ui.inset + amount
    draw()
    ui.inset = ui.inset - amount
    love.graphics.pop()
end
function ui.tab(x, y, w, h, label, selected, hovered)
    local g = love.graphics
    g.setColor(selected and 0.13 or 0.075, selected and 0.23 or 0.105, selected and 0.32 or 0.15)
    if selected or hovered then g.rectangle('fill', x, y, w, h, 6) end
    if selected then
        g.setColor(0.35, 0.77, 0.94)
        g.rectangle('fill', x + 12, y + h - 2, w - 24, 2, 1)
    end
    g.setColor(selected and 0.94 or 0.62, selected and 0.97 or 0.70, selected and 1 or 0.80)
    g.printf(label, x, y + math.floor((h - g.getFont():getHeight()) / 2), w, 'center')
end
return ui
