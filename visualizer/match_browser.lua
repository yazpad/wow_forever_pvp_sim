local ui = require("ui")
-- PVP_SIM: MATCH REPLAY BROWSER (Love2D Native Module)
local match_browser = {}
local icons = require("icons_manager")

local allMatchesList = {}
local selectedIdx = 1
local buttons = {}
local currentDirectory = "matches"

local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function pageSize()
    return math.max(1, math.min(12, math.floor((ui.height() - 110) / 52)))
end
local function firstVisible() return math.floor((selectedIdx - 1) / pageSize()) * pageSize() + 1 end

function match_browser.getMatches() return allMatchesList end

function match_browser.scanMatchesDir(dirPath)
    allMatchesList = {}
    currentDirectory = dirPath or "matches"
    local candidates = {currentDirectory}
    if currentDirectory:sub(1, 1) ~= "/" then candidates[#candidates+1] = "../" .. currentDirectory end
    for _, checkPath in ipairs(candidates) do
        local handle = io.popen("find " .. quote(checkPath) .. " -maxdepth 1 -type f -name '*.lua' -printf '%p\t%T@\n' 2>/dev/null")
        if handle then
            for line in handle:lines() do
                local file, mtimeStr = line:match("([^\t]+)\t([^\t]+)")
                if not file then file = line end
                local cleanName = file:match("([^/]+)%.lua$") or file
                local f = io.open(file, "r")
                if f then
                    local content = f:read(4096) or ""; f:close()
                    local mtime = tonumber(mtimeStr) or 0
                    local timeFormatted = mtime > 0 and os.date("%Y-%m-%d %H:%M:%S", math.floor(mtime)) or "Unknown"
                    local dmgA = tonumber(content:match('dmg_a%s*=%s*([%d%.]+)')) or 0
                    local dmgB = tonumber(content:match('dmg_b%s*=%s*([%d%.]+)')) or 0
                    table.insert(allMatchesList, {
                        path = file, name = cleanName,
                        name_a = content:match('name_a%s*=%s*"([^"]+)"') or cleanName,
                        name_b = content:match('name_b%s*=%s*"([^"]+)"') or "",
                        spec_a = content:match('spec_a%s*=%s*"([^"]+)"') or "warlock",
                        spec_b = content:match('spec_b%s*=%s*"([^"]+)"') or "warlock",
                        elo_a = tonumber(content:match('elo_a%s*=%s*([%d%.]+)')) or 0,
                        elo_b = tonumber(content:match('elo_b%s*=%s*([%d%.]+)')) or 0,
                        victor = tonumber(content:match('victor%s*=%s*(%d+)')) or 0,
                        total_time = tonumber(content:match('total_time%s*=%s*([%d%.]+)')) or 0,
                        dmg_a = dmgA,
                        dmg_b = dmgB,
                        mtime = mtime,
                        timestamp = timeFormatted,
                    })
                end
            end
            handle:close()
        end
        if #allMatchesList > 0 then break end
    end
    -- Sort by most recent first (descending by timestamp)
    table.sort(allMatchesList, function(a, b)
        if (a.mtime or 0) ~= (b.mtime or 0) then
            return (a.mtime or 0) > (b.mtime or 0)
        end
        return a.name < b.name
    end)
    selectedIdx = math.max(1, math.min(selectedIdx, #allMatchesList))
end

function match_browser.clearAllMatches()
    local candidates = {currentDirectory}
    if currentDirectory:sub(1, 1) ~= "/" then candidates[#candidates+1] = "../" .. currentDirectory end
    for _, checkPath in ipairs(candidates) do
        os.execute("rm -f " .. quote(checkPath) .. "/*.lua " .. quote(checkPath) .. "/*.json 2>/dev/null")
    end
    match_browser.scanMatchesDir(currentDirectory)
end

function match_browser.getSelectedMatch()
    if #allMatchesList == 0 then return nil end
    return allMatchesList[selectedIdx]
end

function match_browser.prev()
    if #allMatchesList == 0 then return end
    selectedIdx = selectedIdx - 1
    if selectedIdx < 1 then selectedIdx = #allMatchesList end
end

function match_browser.next()
    if #allMatchesList == 0 then return end
    selectedIdx = selectedIdx + 1
    if selectedIdx > #allMatchesList then selectedIdx = 1 end
end

local match_generator = require("match_generator")
local showGeneratorModal = false

function match_browser.toggleGenerator()
    showGeneratorModal = not showGeneratorModal
end

function match_browser.isGeneratorOpen()
    return showGeneratorModal
end

function match_browser.update(dt)
    match_generator.update(dt)
    local completedPath = match_generator.pollCompleted()
    if completedPath then
        match_browser.scanMatchesDir(currentDirectory)
        for idx, m in ipairs(allMatchesList) do
            if m.path == completedPath or m.name == completedPath:match("([^/]+)%.lua$") then
                selectedIdx = idx
                break
            end
        end
        showGeneratorModal = false
    end
end

function match_browser.keypressed(key)
    if showGeneratorModal then
        if key == "escape" then
            showGeneratorModal = false
            return true
        end
        return false
    end

    if key == "up" then
        match_browser.prev()
        return true
    elseif key == "down" then
        match_browser.next()
        return true
    elseif key == "n" then
        match_browser.toggleGenerator()
        return true
    end
    return false
end

function match_browser.mousepressed(x, y, button)
    for _, btn in ipairs(buttons) do
        if x >= btn.x and x <= btn.x + btn.w and y >= btn.y and y <= btn.y + btn.h then
            btn.action()
            return nil
        end
    end

    if showGeneratorModal then
        match_generator.mousepressed(x, y, button)
        return nil
    end

    if #allMatchesList == 0 then return nil end
    local listX = 36
    local listY = 88
    local itemH = 44
    local itemW = ui.width() - 72

    local first = firstVisible()
    for i = first, math.min(#allMatchesList, first + pageSize() - 1) do
        local cy = listY + (i - first) * (itemH + 8)
        if x >= listX and x <= listX + itemW and y >= cy and y <= cy + itemH then
            selectedIdx = i
            if button == 1 then
                return allMatchesList[selectedIdx].path
            end
        end
    end
    return nil
end

function match_browser.draw()
    local screenW = ui.width()
    local screenH = ui.height()
    buttons = {}

    love.graphics.setColor(0.02, 0.04, 0.08, 0.98)
    love.graphics.rectangle("fill", 0, 0, screenW, screenH)

    -- Header
    love.graphics.setColor(0.2, 0.75, 1.0, 1.0)
    love.graphics.rectangle("fill", 24, 18, 4, 34, 2)
    ui.setFont("header")
    love.graphics.setColor(0.96, 0.98, 1.0, 1.0)
    love.graphics.print("RECORDED MCTS FIGHT REPLAYS", 38, 14)
    ui.setFont("small")
    love.graphics.setColor(0.55, 0.65, 0.8, 1.0)
    love.graphics.print(string.format("Showing %d High-Fidelity 100Hz Fight Trajectories in 'matches/' | [UP/DOWN] Select | [ENTER] Replay", #allMatchesList), 38, 38)
    ui.resetFont()

    -- Header Buttons in Top Right: "+ New Fight" and "Clear All Fights"
    local btnW, btnH = 140, 30
    local btnY = 20
    local bNewX = screenW - btnW - 36
    local bClearX = bNewX - btnW - 12
    local mx, my = love.mouse.getPosition()

    -- Clear All Fights Button
    local clearHover = (mx >= bClearX and mx <= bClearX + btnW and my >= btnY and my <= btnY + btnH)
    love.graphics.setColor(0.55, 0.15, 0.18, 0.85)
    love.graphics.rectangle("fill", bClearX, btnY, btnW, btnH, 5)
    love.graphics.setColor(0.95, 0.35, 0.40, clearHover and 1.0 or 0.75)
    love.graphics.rectangle("line", bClearX, btnY, btnW, btnH, 5)
    ui.setFont("normal")
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.printf("Clear All Fights", bClearX, btnY + 6, btnW, "center")
    ui.resetFont()
    table.insert(buttons, {
        x = bClearX, y = btnY, w = btnW, h = btnH,
        action = function()
            match_browser.clearAllMatches()
        end
    })

    -- "+ New Fight" Launcher Button
    local newHover = (mx >= bNewX and mx <= bNewX + btnW and my >= btnY and my <= btnY + btnH)
    ui.button(bNewX, btnY, btnW, btnH, "+ New Fight [N]", newHover, true)
    table.insert(buttons, { x = bNewX, y = btnY, w = btnW, h = btnH, action = function() match_browser.toggleGenerator() end })

    if #allMatchesList == 0 then
        love.graphics.setColor(0.8, 0.8, 0.9)
        love.graphics.printf("No recorded replays found in matches/.\nClick '+ New Fight' to run a simultaneous MCTS duel or 'Matrix' to run spec combinations.", 36, 120, screenW - 72, "center")
        if showGeneratorModal then
            local pW, pH = 720, 550
            local pX = math.floor((screenW - pW) * 0.5)
            local pY = math.floor((screenH - pH) * 0.5)
            match_generator.drawModal(pX, pY, pW, pH)
        end
        return
    end

    local listX = 36
    local listY = 88
    local itemH = 44
    local itemW = screenW - 72

    local first = firstVisible()
    for i = first, math.min(#allMatchesList, first + pageSize() - 1) do
        local m = allMatchesList[i]
        local isSel = (i == selectedIdx)
        local cy = listY + (i - first) * (itemH + 8)

        local mx, my = love.mouse.getPosition()
        local isHover = (mx >= listX and mx <= listX + itemW and my >= cy and my <= cy + itemH)

        ui.drawCard(listX, cy, itemW, itemH, isHover, isSel, 6)

        -- Winner badge styling
        local victorColor = { 0.5, 0.5, 0.5 }
        local victorName = "DRAW"
        if m.victor == 0 then
            victorColor = { 0.25, 0.85, 0.45 }
            victorName = "A WINS"
        elseif m.victor == 1 then
            victorColor = { 0.95, 0.35, 0.35 }
            victorName = "B WINS"
        end

        local classA = (m.spec_a == "frost_mage" or m.spec_a == "mage") and "mage" or "warlock"
        local classB = (m.spec_b == "frost_mage" or m.spec_b == "mage") and "mage" or "warlock"
        icons.drawClassIcon(classA, listX + 22, cy + 22, 28)
        ui.setFont("tiny")
        love.graphics.setColor(0.45, 0.55, 0.68, 0.9)
        love.graphics.printf("vs", listX + 36, cy + 16, 26, "center")
        ui.resetFont()
        icons.drawClassIcon(classB, listX + 70, cy + 22, 28)

        -- Title & Fighter Names
        ui.setFont("semibold")
        love.graphics.setColor(1, 1, 1, isSel and 1.0 or 0.9)
        local matchTitle = m.name
        if #matchTitle > 38 then matchTitle = matchTitle:sub(1, 36) .. ".." end
        love.graphics.print(matchTitle, listX + 96, cy + 6)

        -- Combatants label
        ui.setFont("small")
        love.graphics.setColor(0.55, 0.68, 0.82, 0.85)
        local vsLabel = string.format("%s vs %s", m.name_a or "A", m.name_b or "B")
        if #vsLabel > 44 then vsLabel = vsLabel:sub(1, 42) .. ".." end
        love.graphics.print(vsLabel, listX + 96, cy + 24)

        -- Timestamp column (Creation Date & Time)
        ui.setFont("small")
        love.graphics.setColor(0.60, 0.70, 0.80, 0.85)
        love.graphics.printf(m.timestamp or "", listX + itemW - 470, cy + 14, 150, "left")

        -- Damage dealt (Dmg A / Dmg B)
        love.graphics.setColor(0.85, 0.65, 0.40, 0.9)
        local dmgText = string.format("Dmg: %.0f vs %.0f", m.dmg_a or 0, m.dmg_b or 0)
        love.graphics.printf(dmgText, listX + itemW - 315, cy + 14, 120, "left")

        -- Outcome Badge
        love.graphics.setColor(victorColor[1], victorColor[2], victorColor[3], 0.2)
        love.graphics.rectangle("fill", listX + itemW - 195, cy + 10, 75, 24, 4)
        love.graphics.setColor(victorColor[1], victorColor[2], victorColor[3], 0.8)
        love.graphics.rectangle("line", listX + itemW - 195, cy + 10, 75, 24, 4)
        ui.setFont("small")
        love.graphics.setColor(victorColor[1], victorColor[2], victorColor[3], 1.0)
        love.graphics.printf(victorName, listX + itemW - 195, cy + 14, 75, "center")

        -- Duration with Clock
        icons.draw("clock", listX + itemW - 105, cy + 22, 14)
        love.graphics.setColor(0.70, 0.80, 0.95, 0.95)
        love.graphics.printf(string.format("%.1fs", m.total_time), listX + itemW - 95, cy + 14, 45, "left")

        -- PLAY Action button
        local playHover = (mx >= listX + itemW - 55 and mx <= listX + itemW and my >= cy + 8 and my <= cy + 36)
        ui.button(listX + itemW - 48, cy + 9, 44, 26, "PLAY", playHover, isSel)
        ui.resetFont()
    end

    if #allMatchesList > pageSize() then
        ui.setFont("small")
        love.graphics.setColor(0.6, 0.7, 0.85, 0.9)
        love.graphics.printf(string.format("Page %d / %d  ([UP/DOWN] Scroll)", math.floor((selectedIdx - 1) / pageSize()) + 1, math.ceil(#allMatchesList / pageSize())), listX, screenH - 32, itemW, "center")
        ui.resetFont()
    end

    if showGeneratorModal then
        local pW, pH = 720, 550
        local pX = math.floor((screenW - pW) * 0.5)
        local pY = math.floor((screenH - pH) * 0.5)
        match_generator.drawModal(pX, pY, pW, pH)
    end
end

-- Compact presentation; workspace owns scrolling and clips interactive rows.
function match_browser.drawPanel(y,button,text,loadReplay)
    button(y,'Refresh replays',function() match_browser.scanMatchesDir(currentDirectory) end)
    y=text(y+34,string.format('%d recorded fights · newest first',#allMatchesList))
    for _,m in ipairs(allMatchesList) do
        local replay=m
        local title=replay.name
        if #title>26 then title=title:sub(1,23)..'...' end
        button(y,title,function() loadReplay(replay.path) end)
        y=text(y+30,string.format('%s vs %s\n%s · %.2fs\nDamage: %.0f / %.0f · %s',
            replay.name_a,replay.name_b,replay.timestamp,replay.total_time,replay.dmg_a,replay.dmg_b,
            replay.victor==0 and 'A wins' or replay.victor==1 and 'B wins' or 'Draw'))
        y=y+8
    end
    if #allMatchesList==0 then y=text(y,'No replays yet. Use Fight below to generate one.') end
    return y+8
end

return match_browser
