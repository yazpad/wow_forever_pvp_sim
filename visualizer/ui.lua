local ui = {
    headerHeight = 0,
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
function ui.width() return ui.viewport and ui.viewport.virtualW or love.graphics.getWidth() / ui.scale() end
function ui.height() return ui.viewport and ui.viewport.virtualH or (love.graphics.getHeight() - ui.headerHeight) / ui.scale() - ui.inset end
function ui.dimensions() return ui.width(), ui.height() end
function ui.contentPoint(x, y)
    x, y = x / ui.scale(), (y - ui.headerHeight) / ui.scale()
    if ui.viewport then return ui.viewportPoint(ui.viewport, x, y) end
    return x, y
end
-- A panel supplies a logical canvas for the existing arena renderer and controls.
function ui.makeViewport(x, y, w, h)
    local virtualW = math.max(960, w)
    local scale = w / virtualW
    return { x=x, y=y, w=w, h=h, scale=scale, virtualW=virtualW, virtualH=h/scale }
end
function ui.viewportPoint(view, x, y)
    return (x-view.x)/view.scale, (y-view.y)/view.scale
end
function ui.scissor(x, y, w, h)
    local scale = ui.scale()
    local view = ui.viewport
    if view then
        x, y = view.x+x*view.scale, view.y+(y+ui.inset)*view.scale
        w, h = w*view.scale, h*view.scale
    else y = y+ui.inset end
    love.graphics.setScissor(x*scale, ui.headerHeight+y*scale, w*scale, h*scale)
end
function ui.withViewport(view, draw)
    local previous = ui.viewport
    love.graphics.push('all')
    ui.scissor(view.x, view.y, view.w, view.h)
    love.graphics.translate(view.x, view.y)
    love.graphics.scale(view.scale)
    ui.viewport = view
    draw()
    ui.viewport = previous
    love.graphics.pop()
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

function ui.button(x, y, w, h, label, hovered, isPrimary, disabled)
    local g = love.graphics
    local r = 5
    if disabled then
        g.setColor(0.06, 0.08, 0.12, 0.6)
        g.rectangle('fill', x, y, w, h, r)
        g.setColor(0.14, 0.18, 0.24, 0.5)
        g.setLineWidth(1)
        g.rectangle('line', x, y, w, h, r)
        ui.setFont("normal")
        g.setColor(0.35, 0.42, 0.50, 0.6)
        g.printf(label, x, y + math.floor((h - g.getFont():getHeight()) / 2), w, 'center')
        ui.resetFont()
        return
    end
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

function ui.chevron(x,y,expanded)
    local g=love.graphics
    g.setColor(ui.colors.textMuted); g.setLineWidth(1.5)
    if expanded then g.line(x-4,y-2,x,y+2,x+4,y-2)
    else g.line(x-2,y-4,x+2,y,x-2,y+4) end
    g.setLineWidth(1)
end

-- Header body excludes the class-icon hit area so the two actions stay distinct.
function ui.playerHeader(x,y,w,h,title,subtitle,expanded,accent,textInset)
    local inset=textInset or 56
    local g=love.graphics
    local mx,my=ui.contentPoint(love.mouse.getPosition())
    local hover=mx>=x and mx<=x+w and my>=y and my<=y+h
    g.setColor(hover and ui.colors.cardHover or ui.colors.cardBg);g.rectangle('fill',x,y,w,h,6)
    g.setColor(expanded and accent or ui.colors.cardBorder);g.rectangle('line',x,y,w,h,6)
    g.setColor(accent);g.rectangle('fill',x,y+8,3,h-16,2)
    ui.chevron(x+w-14,y+h/2,expanded)
    g.push('all');ui.scissor(x+inset,y+4,w-inset-26,h-8)
    ui.setFont('bold');g.setColor(ui.colors.text);g.print(title,x+inset,y+8)
    ui.setFont('small');g.setColor(ui.colors.textMuted);g.print(subtitle,x+inset,y+31)
    g.pop();ui.resetFont()
end

-- Dropdown anchors and input use the same logical coordinates as panel controls.
local menu
local function contains(r, x, y)
    return x >= r.x and x < r.x+r.w and y >= r.y and y < r.y+r.h
end
function ui.dropdownOpen() return menu ~= nil end
function ui.closeDropdown() menu = nil end
function ui.dropdown(id, x, y, w, h, value, choices, onSelect, format, displayValue, options)
    options=options or {}
    local anchor = {x=x,y=y,w=w,h=h,menuWidth=options.menuWidth}
    if menu and menu.id == id then menu.anchor=anchor end
    local g=love.graphics
    if options.portrait then
        local mx,my=ui.contentPoint(love.mouse.getPosition())
        g.setColor(contains(anchor,mx,my) and ui.colors.accentGold or ui.colors.textMuted)
        if contains(anchor,mx,my) then g.circle('line',x+w/2,y+h/2,math.min(w,h)/2-1) end
        g.polygon('fill',x+w-12,y+h-8,x+w-4,y+h-8,x+w-8,y+h-4)
    elseif options.icon or options.race then
        local mx,my=ui.contentPoint(love.mouse.getPosition())
        ui.drawCard(x,y,w,h,contains(anchor,mx,my),menu and menu.id==id,6)
        if options.race then require('races').draw(options.race,x+w/2,y+h/2,math.min(w,h)-6)
        else require('icons_manager').drawClassIcon(options.icon,x+w/2,y+h/2,math.min(w,h)-6) end
        g.setColor(ui.colors.accentGold)
        g.polygon('fill',x+w-10,y+h-6,x+w-4,y+h-6,x+w-7,y+h-3)
    else
        ui.button(x,y,w,h,'',false,false)
        ui.setFont('normal')
        g.setColor(ui.colors.text)
        g.push('all'); ui.scissor(x+10,y,w-38,h)
        g.print(displayValue or (format and format(value) or tostring(value)),x+10,y+math.floor((h-g.getFont():getHeight())/2))
        g.pop()
        local cx,cy=x+w-15,y+h/2
        local direction=(menu and menu.id==id) and -1 or 1
        g.setColor(ui.colors.textMuted)
        g.setLineWidth(1.5)
        g.line(cx-4,cy-2*direction,cx,cy+2*direction,cx+4,cy-2*direction)
        g.setLineWidth(1)
        ui.resetFont()
    end
    return function()
        if menu and menu.id == id then menu=nil; return end
        if #choices==0 then return end
        menu={id=id,anchor=anchor,value=value,choices=choices,onSelect=onSelect,format=format,offset=0}
    end
end
function ui.dropdownBounds()
    if not menu then return nil end
    local w,h=ui.dimensions()
    local mw=math.min(menu.anchor.menuWidth or menu.anchor.w,w-16)
    local row=26
    local rows=math.min(#menu.choices,math.max(1,math.floor((h-24)/row)))
    menu.offset=math.max(0,math.min(menu.offset,#menu.choices-rows))
    local mh=rows*row+8
    local x=math.max(8,math.min(menu.anchor.x,w-mw-8))
    local y=menu.anchor.y+menu.anchor.h+4
    if y+mh>h-8 then y=menu.anchor.y-mh-4 end
    y=math.max(8,math.min(y,h-mh-8))
    return {x=x,y=y,w=mw,h=mh,row=row,rows=rows}
end
function ui.drawDropdown()
    if not menu then return end
    local g=love.graphics
    local r=ui.dropdownBounds()
    local mx,my=ui.contentPoint(love.mouse.getPosition())
    g.push('all'); g.setScissor()
    g.setColor(0.06,0.09,0.15,1); g.rectangle('fill',r.x,r.y,r.w,r.h,5)
    g.setColor(ui.colors.cardBorderActive); g.rectangle('line',r.x,r.y,r.w,r.h,5)
    ui.setFont('normal')
    ui.scissor(r.x+3,r.y+4,r.w-6,r.h-8)
    for slot=1,r.rows do
        local value=menu.choices[menu.offset+slot]
        local y=r.y+4+(slot-1)*r.row
        local hovered=contains({x=r.x,y=y,w=r.w,h=r.row},mx,my)
        if hovered or value==menu.value then
            g.setColor(hovered and ui.colors.cardHover or ui.colors.cardBorder)
            g.rectangle('fill',r.x+3,y,r.w-6,r.row,3)
        end
        g.setColor(value==menu.value and ui.colors.accentGold or ui.colors.text)
        g.print((value==menu.value and '*  ' or '   ')..(menu.format and menu.format(value) or tostring(value)),r.x+8,y+5)
    end
    g.pop()
end
function ui.dropdownMousepressed(x,y,button)
    if not menu then return false end
    local current=menu
    local r=ui.dropdownBounds()
    menu=nil
    if button==1 and contains(r,x,y) then
        local slot=math.floor((y-r.y-4)/r.row)+1
        local i=current.offset+slot
        if slot>=1 and slot<=r.rows and current.choices[i] then current.onSelect(current.choices[i]) end
    end
    return true
end
function ui.dropdownWheelmoved(y)
    if not menu then return false end
    local r=ui.dropdownBounds()
    menu.offset=math.max(0,math.min(#menu.choices-r.rows,menu.offset-(y>0 and math.ceil(y) or math.floor(y))))
    return true
end
function ui.dropdownKeypressed(key)
    if not menu then return false end
    if key=='escape' then menu=nil end
    return true
end

return ui
