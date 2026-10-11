-- 📂 PVP_SIM: MATCH REPLAY BROWSER (Love2D Native Module)
local match_browser = {}
local icons = require("icons_manager")

local matchesList = {}
local selectedIdx = 1

function match_browser.scanMatchesDir(dirPath)
    matchesList = {}
    dirPath = dirPath or "matches"

    -- Check local or parent relative path
    local checkPath = dirPath
    local handle = io.popen("ls -1 " .. checkPath .. "/*.lua 2>/dev/null")
    if not handle then
        checkPath = "../" .. dirPath
        handle = io.popen("ls -1 " .. checkPath .. "/*.lua 2>/dev/null")
    end

    if handle then
        for file in handle:lines() do
            local cleanName = file:match("([^/]+)%.lua$") or file
            local f = io.open(file, "r")
            local metaA, metaB, eloA, eloB, victor = "?", "?", 0, 0, 0
            if f then
                local content = f:read(1024) or ""
                f:close()
                metaA = content:match('name_a%s*=%s*"([^"]+)"') or cleanName
                metaB = content:match('name_b%s*=%s*"([^"]+)"') or ""
                eloA = tonumber(content:match('elo_a%s*=%s*([%d%.]+)')) or 0
                eloB = tonumber(content:match('elo_b%s*=%s*([%d%.]+)')) or 0
                victor = tonumber(content:match('victor%s*=%s*(%d+)')) or 0
            end

            table.insert(matchesList, {
                path = file,
                name = cleanName,
                name_a = metaA,
                name_b = metaB,
                elo_a = eloA,
                elo_b = eloB,
                victor = victor,
            })
        end
        handle:close()
    end

    if #matchesList == 0 then
        -- Fallback default matches
        table.insert(matchesList, {
            path = "last_match.lua",
            name = "last_match",
            name_a = "Unit A",
            name_b = "Unit B",
            elo_a = 1500,
            elo_b = 1500,
            victor = 0,
        })
    end
end

function match_browser.hasData()
    return #matchesList > 0
end

function match_browser.update(dt)
end

function match_browser.keypressed(key)
    if #matchesList == 0 then return nil end
    if key == "up" or key == "w" then
        selectedIdx = math.max(1, selectedIdx - 1)
    elseif key == "down" or key == "s" then
        selectedIdx = math.min(#matchesList, selectedIdx + 1)
    elseif key == "return" or key == "space" then
        return matchesList[selectedIdx].path
    elseif key == "r" then
        match_browser.scanMatchesDir("matches")
    end
    return nil
end

function match_browser.mousepressed(x, y, button)
    if #matchesList == 0 then return nil end
    local listX = 36
    local listY = 90
    local itemH = 44
    local itemW = love.graphics.getWidth() - 72

    for i = 1, math.min(#matchesList, 12) do
        local cy = listY + (i - 1) * (itemH + 8)
        if x >= listX and x <= listX + itemW and y >= cy and y <= cy + itemH then
            selectedIdx = i
            if button == 1 then
                return matchesList[selectedIdx].path
            end
        end
    end
    return nil
end

function match_browser.draw()
    local screenW = love.graphics.getWidth()
    local screenH = love.graphics.getHeight()

    love.graphics.setColor(0.02, 0.04, 0.08, 0.98)
    love.graphics.rectangle("fill", 0, 0, screenW, screenH)

    -- Header
    love.graphics.setColor(0.2, 0.75, 1.0, 1.0)
    love.graphics.rectangle("fill", 24, 18, 5, 34)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.print("📂 RECORDED FIGHT REPLAY BROWSER", 38, 18)
    love.graphics.setColor(0.55, 0.65, 0.8, 1.0)
    love.graphics.print(string.format("Found %d Stored High-Fidelity 100Hz Fight Trajectories in 'matches/'  |  Click or [ENTER] to Load Replay", #matchesList), 38, 38)

    local listX = 36
    local listY = 80
    local itemH = 44
    local itemW = screenW - 72

    for i = 1, math.min(#matchesList, 12) do
        local m = matchesList[i]
        local cy = listY + (i - 1) * (itemH + 8)
        local isSel = (i == selectedIdx)

        love.graphics.setColor(isSel and 0.14 or 0.07, isSel and 0.20 or 0.10, isSel and 0.30 or 0.16, 0.95)
        love.graphics.rectangle("fill", listX, cy, itemW, itemH, 6)

        if isSel then
            love.graphics.setColor(0.25, 0.75, 1.0, 0.9)
            love.graphics.rectangle("line", listX, cy, itemW, itemH, 6)
        else
            love.graphics.setColor(0.15, 0.20, 0.30, 0.6)
            love.graphics.rectangle("line", listX, cy, itemW, itemH, 6)
        end

        -- Match item icon: Class icon of Unit A
        icons.drawClassIcon("warlock", listX + 18, cy + 22, 28)

        -- Title & Versus
        love.graphics.setColor(0.95, 0.95, 1.0, 1.0)
        love.graphics.print(string.format("%d. %s", i, m.name_a), listX + 40, cy + 8)

        -- Crossed Swords icon for VS
        local nameAW = love.graphics.getFont():getWidth(string.format("%d. %s", i, m.name_a))
        local vsX = listX + 40 + nameAW + 8
        icons.draw("sword", vsX + 8, cy + 14, 14)

        icons.drawClassIcon("warlock", vsX + 26, cy + 14, 14)
        love.graphics.setColor(0.95, 0.95, 1.0, 1.0)
        love.graphics.print(m.name_b, vsX + 38, cy + 8)

        love.graphics.setColor(0.5, 0.65, 0.8, 1.0)
        local fileLabel = m.path:match("([^/]+)$") or m.path
        love.graphics.print(string.format("File: %s", fileLabel), listX + 40, cy + 24)

        -- Victor tag with crown icon
        local vCol = (m.victor == 0) and { 0.7, 0.4, 1.0 } or { 0.2, 0.85, 0.5 }
        icons.draw("crown", listX + itemW - 130, cy + 22, 16)
        love.graphics.setColor(vCol[1], vCol[2], vCol[3], 1.0)
        local vName = (m.victor == 0) and (m.name_a:sub(1, 10)) or (m.name_b:sub(1, 10))
        love.graphics.printf(vName, listX + itemW - 110, cy + 14, 95, "left")
    end
end

return match_browser
