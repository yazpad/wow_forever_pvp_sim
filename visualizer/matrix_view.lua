-- ⚔️ PVP_SIM: SPEC VS SPEC MATCHUP MATRIX DASHBOARD (Love2D Native Module)
local matrix_view = {}
local icons = require("icons_manager")

local MATRIX_DATA = nil
local currentMatrixPath = "spec_matrix.lua"
local selectedRow = 1
local selectedCol = 1

function matrix_view.loadMatrixFile(path)
    currentMatrixPath = path
    local file, err = io.open(path, "r")
    if not file then
        path = "../" .. path
        file = io.open(path, "r")
    end

    if not file then
        return false
    end
    file:close()

    local fn, loadErr = loadfile(path)
    if fn then
        MATRIX_DATA = fn()
        selectedRow = 1
        selectedCol = 1
        return true
    else
        print("Error parsing spec matrix: " .. tostring(loadErr))
    end
    return false
end

function matrix_view.hasData()
    return MATRIX_DATA ~= nil and MATRIX_DATA.models ~= nil and #MATRIX_DATA.models > 0
end

function matrix_view.update(dt)
end

function matrix_view.keypressed(key)
    if not matrix_view.hasData() then return end
    local numModels = #MATRIX_DATA.models
    local numBots = (MATRIX_DATA.bots and #MATRIX_DATA.bots) or 0
    local totalCols = numModels + numBots

    if key == "up" or key == "w" then
        selectedRow = math.max(1, selectedRow - 1)
    elseif key == "down" or key == "s" then
        selectedRow = math.min(numModels, selectedRow + 1)
    elseif key == "left" or key == "a" then
        selectedCol = math.max(1, selectedCol - 1)
    elseif key == "right" or key == "d" then
        selectedCol = math.min(totalCols, selectedCol + 1)
    elseif key == "return" or key == "space" then
        -- Play the representative match if available
        local rowMod = MATRIX_DATA.models[selectedRow]
        local cleanA = rowMod.file:gsub("%.bin$", "")
        local matchPath = nil

        if selectedCol <= numModels then
            local colMod = MATRIX_DATA.models[selectedCol]
            local cleanB = colMod.file:gsub("%.bin$", "")
            matchPath = string.format("matches/match_%s_vs_%s.lua", cleanA, cleanB)
        else
            local bIdx = selectedCol - numModels
            local bot = MATRIX_DATA.bots[bIdx]
            local botTag = (bIdx == 1 and "AggroRusher" or (bIdx == 2 and "FearKiter" or (bIdx == 3 and "TurretCaster" or "DrainTank")))
            matchPath = string.format("matches/match_%s_vs_%s.lua", cleanA, botTag)
        end

        return matchPath
    elseif key == "r" then
        matrix_view.loadMatrixFile(currentMatrixPath)
    end
    return nil
end

function matrix_view.mousepressed(x, y, button)
    if not matrix_view.hasData() then return nil end
    local screenW = love.graphics.getWidth()
    local screenH = love.graphics.getHeight()
    local models = MATRIX_DATA.models
    local bots = MATRIX_DATA.bots or {}
    local numModels = #models
    local numBots = #bots
    local totalCols = numModels + numBots

    local startX = 220
    local startY = 130
    local cellW = math.min(84, math.max(50, (screenW - startX - 40) / totalCols))
    local cellH = 38

    for r = 1, numModels do
        for c = 1, totalCols do
            local cx = startX + (c - 1) * cellW
            local cy = startY + (r - 1) * cellH
            if x >= cx and x <= cx + cellW and y >= cy and y <= cy + cellH then
                selectedRow = r
                selectedCol = c

                if button == 1 and love.keyboard.isDown("lctrl", "rctrl") then
                    return matrix_view.keypressed("return")
                end
                return nil
            end
        end
    end
    return nil
end

local function getWinRateColor(wr)
    if wr >= 0.75 then
        return { 0.15, 0.85, 0.40 } -- Strong green
    elseif wr >= 0.50 then
        return { 0.25, 0.70, 0.85 } -- Blue-cyan
    elseif wr >= 0.25 then
        return { 0.95, 0.75, 0.20 } -- Amber
    else
        return { 0.90, 0.25, 0.25 } -- Crimson loss
    end
end

function matrix_view.draw()
    local screenW = love.graphics.getWidth()
    local screenH = love.graphics.getHeight()

    -- 1. Dark Backdrop
    love.graphics.setColor(0.02, 0.04, 0.08, 0.98)
    love.graphics.rectangle("fill", 0, 0, screenW, screenH)

    if not matrix_view.hasData() then
        love.graphics.setColor(0.8, 0.8, 0.9)
        love.graphics.printf("No Spec Matrix data loaded.\nRun './zig-out/bin/pvp_sim --eval-matrix models/ --record-all-matches matches/' to generate it.", 0, screenH / 2 - 20, screenW, "center")
        return
    end

    local models = MATRIX_DATA.models
    local bots = MATRIX_DATA.bots or {}
    local numModels = #models
    local numBots = #bots
    local totalCols = numModels + numBots

    -- 2. Header
    love.graphics.setColor(0.95, 0.40, 0.15, 1.0)
    love.graphics.rectangle("fill", 24, 18, 5, 34)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.print("⚔️ SPEC VS SPEC ASYMMETRIC WIN PERCENTAGE MATRIX", 38, 18)
    love.graphics.setColor(0.55, 0.65, 0.8, 1.0)
    love.graphics.print(string.format("Trained Neural Specs: %d  |  Baseline Bots: %d  |  Press [SPACE/ENTER] to load & replay matchup fight in Arena", numModels, numBots), 38, 38)

    -- 3. Matrix Table Dimensions
    local startX = 220
    local startY = 120
    local cellW = math.min(84, math.max(50, (screenW - startX - 40) / totalCols))
    local cellH = 38

    -- Column Headers (Opponents)
    for c = 1, numModels do
        local cx = startX + (c - 1) * cellW
        love.graphics.setColor(0.12, 0.16, 0.24, 0.9)
        love.graphics.rectangle("fill", cx + 1, startY - 32, cellW - 2, 28, 4)
        icons.drawClassIcon("warlock", cx + 10, startY - 18, 16)
        love.graphics.setColor(0.8, 0.9, 1.0, 1.0)
        local shortName = models[c].name:sub(1, 6)
        love.graphics.printf(shortName, cx + 18, startY - 26, cellW - 18, "center")
    end

    for b = 1, numBots do
        local c = numModels + b
        local cx = startX + (c - 1) * cellW
        love.graphics.setColor(0.20, 0.15, 0.28, 0.9)
        love.graphics.rectangle("fill", cx + 1, startY - 32, cellW - 2, 28, 4)
        icons.draw("ui_sword", cx + 10, startY - 18, 14)
        love.graphics.setColor(1.0, 0.85, 0.35, 1.0)
        local botLabel = bots[b].name:sub(1, 6)
        love.graphics.printf(botLabel, cx + 18, startY - 26, cellW - 18, "center")
    end

    -- Rows (Candidate Specs)
    for r = 1, numModels do
        local ry = startY + (r - 1) * cellH

        -- Row Header (Model Name & Elo)
        love.graphics.setColor((r == selectedRow) and 0.16 or 0.08, (r == selectedRow) and 0.22 or 0.11, (r == selectedRow) and 0.32 or 0.17, 0.9)
        love.graphics.rectangle("fill", 24, ry + 1, startX - 32, cellH - 2, 4)
        
        icons.drawClassIcon("warlock", 40, ry + cellH * 0.5, 24)

        love.graphics.setColor(0.95, 0.95, 1.0, 1.0)
        local mName = models[r].name
        if #mName > 18 then mName = mName:sub(1, 16) .. ".." end
        love.graphics.print(mName, 58, ry + 4)
        love.graphics.setColor(0.45, 0.70, 0.95, 0.9)
        love.graphics.print(string.format("Elo: %.0f", models[r].elo), 58, ry + 20)

        -- Model vs Model Cells
        for c = 1, numModels do
            local cx = startX + (c - 1) * cellW
            local isSel = (r == selectedRow and c == selectedCol)

            if r == c then
                -- Diagonal mirror
                love.graphics.setColor(0.06, 0.08, 0.12, 0.9)
                love.graphics.rectangle("fill", cx + 1, ry + 1, cellW - 2, cellH - 2, 4)
                love.graphics.setColor(0.3, 0.35, 0.45, 0.6)
                love.graphics.printf("---", cx, ry + 10, cellW, "center")
            else
                local res = MATRIX_DATA.matrix[r] and MATRIX_DATA.matrix[r][c]
                local wr = res and res.win_rate or 0.0
                local col = getWinRateColor(wr)

                love.graphics.setColor(col[1] * 0.22, col[2] * 0.22, col[3] * 0.22, 0.92)
                love.graphics.rectangle("fill", cx + 1, ry + 1, cellW - 2, cellH - 2, 4)

                if isSel then
                    love.graphics.setColor(1, 1, 1, 0.9)
                    love.graphics.rectangle("line", cx, ry, cellW, cellH, 4)
                end

                love.graphics.setColor(col[1], col[2], col[3], 1.0)
                love.graphics.printf(string.format("%.0f%%", wr * 100), cx, ry + 10, cellW, "center")
            end
        end

        -- Model vs Bot Cells
        for b = 1, numBots do
            local c = numModels + b
            local cx = startX + (c - 1) * cellW
            local isSel = (r == selectedRow and c == selectedCol)

            local res = MATRIX_DATA.bot_matrix[r] and MATRIX_DATA.bot_matrix[r][b]
            local wr = res and res.win_rate or 0.0
            local col = getWinRateColor(wr)

            love.graphics.setColor(col[1] * 0.20, col[2] * 0.20, col[3] * 0.20, 0.92)
            love.graphics.rectangle("fill", cx + 1, ry + 1, cellW - 2, cellH - 2, 4)

            if isSel then
                love.graphics.setColor(1, 1, 1, 0.9)
                love.graphics.rectangle("line", cx, ry, cellW, cellH, 4)
            end

            love.graphics.setColor(col[1], col[2], col[3], 1.0)
            love.graphics.printf(string.format("%.0f%%", wr * 100), cx, ry + 10, cellW, "center")
        end
    end

    -- 4. Matchup Detail Card (Bottom Panel)
    local cardY = startY + numModels * cellH + 24
    local cardH = screenH - cardY - 24
    love.graphics.setColor(0.08, 0.10, 0.16, 0.95)
    love.graphics.rectangle("fill", 24, cardY, screenW - 48, cardH, 8)
    love.graphics.setColor(0.2, 0.25, 0.35, 0.8)
    love.graphics.rectangle("line", 24, cardY, screenW - 48, cardH, 8)

    local rowMod = models[selectedRow]
    local targetName, targetElo, res, matchFile = "", "", nil, ""

    if selectedCol <= numModels then
        local colMod = models[selectedCol]
        targetName = colMod.name
        targetElo = string.format("%.0f Elo", colMod.elo)
        res = (selectedRow ~= selectedCol) and (MATRIX_DATA.matrix[selectedRow] and MATRIX_DATA.matrix[selectedRow][selectedCol]) or nil
        matchFile = string.format("matches/match_%s_vs_%s.lua", rowMod.file:gsub("%.bin$", ""), colMod.file:gsub("%.bin$", ""))
    else
        local bIdx = selectedCol - numModels
        local bot = bots[bIdx]
        targetName = bot.icon .. " " .. bot.name
        targetElo = string.format("Baseline %.0f Elo", bot.baseline_elo)
        res = MATRIX_DATA.bot_matrix[selectedRow] and MATRIX_DATA.bot_matrix[selectedRow][bIdx]
        local botTag = (bIdx == 1 and "AggroRusher" or (bIdx == 2 and "FearKiter" or (bIdx == 3 and "TurretCaster" or "DrainTank")))
        matchFile = string.format("matches/match_%s_vs_%s.lua", rowMod.file:gsub("%.bin$", ""), botTag)
    end

    love.graphics.setColor(0.2, 0.7, 1.0, 1.0)
    love.graphics.print("🔍 SELECTED MATCHUP DEEP-DIVE", 42, cardY + 14)
    love.graphics.setColor(0.95, 0.95, 1.0, 1.0)
    love.graphics.print(string.format("%s (%.0f Elo)   VS   %s (%s)", rowMod.name, rowMod.elo, targetName, targetElo), 42, cardY + 36)

    if res and res.duels > 0 then
        local wrCol = getWinRateColor(res.win_rate)
        love.graphics.setColor(wrCol[1], wrCol[2], wrCol[3], 1.0)
        love.graphics.print(string.format("Win Rate: %.1f%% (%dW / %dL / %dD out of %d duels)", res.win_rate * 100, res.wins_a, res.wins_b, res.draws, res.duels), 42, cardY + 58)
        love.graphics.setColor(0.7, 0.8, 0.9, 1.0)
        love.graphics.print(string.format("Average Match Duration: %.2fs  |  Avg HP Remainder: [A] %.0f/2000  vs  [B] %.0f/2000", res.avg_time, res.hp_a, res.hp_b), 42, cardY + 78)

        love.graphics.setColor(0.4, 0.9, 0.5, 1.0)
        love.graphics.print(string.format("▶ Press [SPACE] or [ENTER] to Load Match Fight Replay: '%s'", matchFile), 42, cardY + 104)
    else
        love.graphics.setColor(0.6, 0.7, 0.8, 1.0)
        love.graphics.print("(Identical spec mirror match)", 42, cardY + 58)
    end
end

return matrix_view
