local ui = {
    headerHeight = 64,
    inset = 0,
    fonts = {},
    colors = {
        bg = { 0.04, 0.06, 0.10, 1.0 },
        cardBg = { 0.08, 0.11, 0.18, 0.94 },
        cardHover = { 0.11, 0.16, 0.25, 0.96 },
        cardBorder = { 0.18, 0.24, 0.36, 0.75 },
        cardBorderActive = { 0.35, 0.70, 0.95, 0.90 },
        primary = { 0.20, 0.65, 0.95, 1.0 },
        primaryHover = { 0.30, 0.75, 1.0, 1.0 },
        accentGold = { 0.96, 0.76, 0.25, 1.0 },
        accentPurple = { 0.72, 0.42, 0.98, 1.0 },
        accentGreen = { 0.25, 0.85, 0.55, 1.0 },
        accentRed = { 0.95, 0.32, 0.35, 1.0 },
        text = { 0.94, 0.96, 1.0, 1.0 },
        textMuted = { 0.60, 0.68, 0.78, 1.0 },
        textDim = { 0.40, 0.48, 0.58, 1.0 },
    }
}

function ui.initFonts()
    local fontDefs = {
        tiny = { 10, "regular" },
        small = { 12, "regular" },
        normal = { 14, "regular" },
        semibold = { 14, "semibold" },
        bold = { 15, "bold" },
        title = { 18, "bold" },
        header = { 22, "bold" },
    }
    for name, def in pairs(fontDefs) do
        local sz, weight = def[1], def[2]
        local path = "visualizer/fonts/" .. weight .. ".ttf"
        if not love.filesystem.getInfo(path) then
            path = "fonts/" .. weight .. ".ttf"
        end
        if love.filesystem.getInfo(path) then
            local ok, f = pcall(love.graphics.newFont, path, sz)
            if ok and f then ui.fonts[name] = f end
        end
    end
end

function ui.setFont(name)
    if ui.fonts[name] then
        love.graphics.setFont(ui.fonts[name])
    end
end

function ui.resetFont()
    if ui.fonts.normal then
        love.graphics.setFont(ui.fonts.normal)
    end
end

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

function ui.drawCard(x, y, w, h, hovered, active, r)
    local g = love.graphics
    local radius = r or 6
    -- Background drop shadow
    g.setColor(0.01, 0.02, 0.04, 0.45)
    g.rectangle('fill', x + 2, y + 2, w, h, radius)
    -- Card background fill
    local bg = hovered and ui.colors.cardHover or ui.colors.cardBg
    g.setColor(bg[1], bg[2], bg[3], bg[4])
    g.rectangle('fill', x, y, w, h, radius)
    -- Border
    local border = active and ui.colors.cardBorderActive or (hovered and ui.colors.primary or ui.colors.cardBorder)
    g.setColor(border[1], border[2], border[3], border[4])
    g.setLineWidth(hovered and 1.5 or 1)
    g.rectangle('line', x, y, w, h, radius)
    g.setLineWidth(1)
end

function ui.tab(x, y, w, h, label, selected, hovered)
    local g = love.graphics
    -- Subtle tab background
    if selected then
        g.setColor(0.12, 0.18, 0.28, 0.95)
        g.rectangle('fill', x, y, w, h, 6)
        -- Glow underline
        g.setColor(0.35, 0.77, 0.94, 0.3)
        g.rectangle('fill', x + 8, y + h - 5, w - 16, 5, 2)
        g.setColor(0.35, 0.77, 0.94, 1.0)
        g.rectangle('fill', x + 10, y + h - 2, w - 20, 2, 1)
    elseif hovered then
        g.setColor(0.09, 0.13, 0.21, 0.85)
        g.rectangle('fill', x, y, w, h, 6)
        g.setColor(0.25, 0.35, 0.50, 0.6)
        g.rectangle('line', x, y, w, h, 6)
    end

    if selected then
        ui.setFont("semibold")
        g.setColor(0.96, 0.98, 1.0, 1.0)
    elseif hovered then
        ui.setFont("normal")
        g.setColor(0.85, 0.90, 0.98, 1.0)
    else
        ui.setFont("normal")
        g.setColor(0.55, 0.65, 0.76, 0.9)
    end
    g.printf(label, x, y + math.floor((h - g.getFont():getHeight()) / 2), w, 'center')
    ui.resetFont()
end

function ui.button(x, y, w, h, label, hovered, isPrimary)
    local g = love.graphics
    local r = 5
    if isPrimary then
        if hovered then
            g.setColor(0.24, 0.58, 0.88, 1.0)
        else
            g.setColor(0.18, 0.48, 0.76, 0.95)
        end
    else
        if hovered then
            g.setColor(0.14, 0.19, 0.29, 0.95)
        else
            g.setColor(0.09, 0.13, 0.21, 0.85)
        end
    end
    g.rectangle('fill', x, y, w, h, r)

    local border = isPrimary and (hovered and { 0.45, 0.80, 1.0, 1.0 } or { 0.30, 0.65, 0.90, 0.8 })
        or (hovered and { 0.35, 0.48, 0.68, 0.9 } or { 0.20, 0.28, 0.40, 0.7 })
    g.setColor(border[1], border[2], border[3], border[4])
    g.setLineWidth(hovered and 1.5 or 1)
    g.rectangle('line', x, y, w, h, r)
    g.setLineWidth(1)

    ui.setFont("normal")
    g.setColor(hovered and 1.0 or 0.92, hovered and 1.0 or 0.94, 1.0, 1.0)
    g.printf(label, x, y + math.floor((h - g.getFont():getHeight()) / 2), w, 'center')
    ui.resetFont()
end

return ui
