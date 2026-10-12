local ui = require("ui")
-- PVP_SIM: SPEC VS SPEC MATCHUP MATRIX DASHBOARD (Love2D Native Module)
local matrix_view = {}
local icons = require("icons_manager")

local MATRIX_DATA = nil
local currentMatrixPath = "spec_matrix.lua"
local selectedRow = 1
local selectedCol = 1

-- Set Mode: "base" (Class Base vs Class Base) or "spec" (Spec vs Spec Target Pairs)
local currentSetMode = "base"
local filteredModels = {}
local buttons = {}

local function isBaseModel(m)
    local n = (m.name or ""):lower()
    local f = (m.file or ""):lower()
    if f:find("base") or n:find("base") then return true end
    if f:find("_vs_") or n:find(" vs ") then return false end
    -- If it's named purely after the class/spec without 'vs'
    return false
end

local function isSpecialistModel(m)
    local n = (m.name or ""):lower()
    local f = (m.file or ""):lower()
    if f:find("_vs_") or n:find(" vs ") then return true end
    return false
end

local function refreshFilteredModels()
    filteredModels = {}
    if not (MATRIX_DATA and MATRIX_DATA.models) then return end

    for origIdx, m in ipairs(MATRIX_DATA.models) do
        -- Skip legacy models, bots, or non-pipeline files if any slipped through
        local n = (m.name or ""):lower()
        local f = (m.file or ""):lower()
        local isBotOrLegacy = n:find("aggro") or n:find("turret") or n:find("fear") or n:find("turtle") or f:find("legacy")

        if not isBotOrLegacy then
            if currentSetMode == "base" then
                if isBaseModel(m) or not isSpecialistModel(m) then
                    table.insert(filteredModels, { origIdx = origIdx, model = m })
                end
            else
                if isSpecialistModel(m) then
                    table.insert(filteredModels, { origIdx = origIdx, model = m })
                end
            end
        end
    end

    selectedRow = math.max(1, math.min(selectedRow, #filteredModels))
    selectedCol = math.max(1, math.min(selectedCol, #filteredModels))
end

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
        refreshFilteredModels()
        return true
    else
        print("Error parsing spec matrix: " .. tostring(loadErr))
    end
    return false
end

function matrix_view.hasData()
    return MATRIX_DATA ~= nil and MATRIX_DATA.models ~= nil and #MATRIX_DATA.models > 0
end

function matrix_view.setMode(mode)
    if mode == "base" or mode == "spec" then
        currentSetMode = mode
        refreshFilteredModels()
    end
end

function matrix_view.getMode()
    return currentSetMode
end

function matrix_view.update(dt)
end

function matrix_view.keypressed(key)
    if not matrix_view.hasData() then return end
    local numModels = #filteredModels

    if key == "tab" then
        matrix_view.setMode(currentSetMode == "base" and "spec" or "base")
        return nil
    elseif key == "up" or key == "w" then
        selectedRow = math.max(1, selectedRow - 1)
    elseif key == "down" or key == "s" then
        selectedRow = math.min(numModels, selectedRow + 1)
    elseif key == "left" or key == "a" then
        selectedCol = math.max(1, selectedCol - 1)
    elseif key == "right" or key == "d" then
        selectedCol = math.min(numModels, selectedCol + 1)
    elseif key == "return" or key == "space" then
        if numModels == 0 or selectedCol == selectedRow then return nil end
        -- Play the representative match if available
        local rowEntry = filteredModels[selectedRow]
        local colEntry = filteredModels[selectedCol]
        if not (rowEntry and colEntry) then return nil end

        local rowMod = rowEntry.model
        local colMod = colEntry.model
        local cleanA = rowMod.file:gsub("%.bin$", "")
        local cleanB = colMod.file:gsub("%.bin$", "")
        return string.format("matches/match_%s_vs_%s.lua", cleanA, cleanB)
    elseif key == "r" then
        matrix_view.loadMatrixFile(currentMatrixPath)
    end
    return nil
end

function matrix_view.mousepressed(x, y, button)
    for _, btn in ipairs(buttons) do
        if x >= btn.x and x <= btn.x + btn.w and y >= btn.y and y <= btn.y + btn.h then
            return btn.action()
        end
    end

    if not matrix_view.hasData() or #filteredModels == 0 then return nil end
    local screenW = ui.width()
    local numModels = #filteredModels

    local startX = 240
    local startY = 125
    local cellW = math.min(100, math.max(60, (screenW - startX - 40) / math.max(1, numModels)))
    local cellH = 42

    for r = 1, numModels do
        for c = 1, numModels do
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
    local screenW = ui.width()
    local screenH = ui.height()
    buttons = {}

    -- 1. Dark Backdrop
    love.graphics.setColor(0.02, 0.04, 0.08, 0.98)
    love.graphics.rectangle("fill", 0, 0, screenW, screenH)

    if not matrix_view.hasData() then
        love.graphics.setColor(0.8, 0.8, 0.9)
        love.graphics.printf("No Spec Matrix data loaded.\nOpen Training [F6] and choose 'Evaluate' to generate it from saved champions.", 0, screenH / 2 - 20, screenW, "center")
        return
    end

    local numModels = #filteredModels

    -- 2. Header
    love.graphics.setColor(0.95, 0.40, 0.15, 1.0)
    love.graphics.rectangle("fill", 24, 18, 5, 34)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.print(currentSetMode == "base" and "SET 1: CLASS BASE VS BASE MATRIX" or "SET 2: SPEC VS SPEC TARGET MATCHUP MATRIX", 38, 18)
    love.graphics.setColor(0.55, 0.65, 0.8, 1.0)
    love.graphics.print(string.format("Trained Models: %d | [TAB] Switch Matrix Set | [SPACE/ENTER] Load Match Replay", numModels), 38, 38)

    -- Set Switcher Buttons in Top-Right
    local btnW, btnH = 150, 30
    local btnY = 20
    local b1X = screenW - (btnW * 2 + 36)
    local b2X = screenW - (btnW + 24)

    -- Tab 1: Base Set
    local isBaseActive = (currentSetMode == "base")
    love.graphics.setColor(isBaseActive and 0.20 or 0.08, isBaseActive and 0.45 or 0.14, isBaseActive and 0.70 or 0.22, 0.95)
    love.graphics.rectangle("fill", b1X, btnY, btnW, btnH, 5)
    love.graphics.setColor(isBaseActive and 0.40 or 0.20, isBaseActive and 0.80 or 0.30, isBaseActive and 1.0 or 0.40, 0.9)
    love.graphics.rectangle("line", b1X, btnY, btnW, btnH, 5)
    love.graphics.setColor(1, 1, 1, isBaseActive and 1.0 or 0.6)
    love.graphics.printf("1. Base Set (Class)", b1X, btnY + 7, btnW, "center")
    table.insert(buttons, { x = b1X, y = btnY, w = btnW, h = btnH, action = function() matrix_view.setMode("base") end })

    -- Tab 2: Spec vs Spec
    local isSpecActive = (currentSetMode == "spec")
    love.graphics.setColor(isSpecActive and 0.20 or 0.08, isSpecActive and 0.45 or 0.14, isSpecActive and 0.70 or 0.22, 0.95)
    love.graphics.rectangle("fill", b2X, btnY, btnW, btnH, 5)
    love.graphics.setColor(isSpecActive and 0.40 or 0.20, isSpecActive and 0.80 or 0.30, isSpecActive and 1.0 or 0.40, 0.9)
    love.graphics.rectangle("line", b2X, btnY, btnW, btnH, 5)
    love.graphics.setColor(1, 1, 1, isSpecActive and 1.0 or 0.6)
    love.graphics.printf("2. Spec vs Spec", b2X, btnY + 7, btnW, "center")
    table.insert(buttons, { x = b2X, y = btnY, w = btnW, h = btnH, action = function() matrix_view.setMode("spec") end })

    if numModels == 0 then
        love.graphics.setColor(0.7, 0.75, 0.85, 0.9)
        love.graphics.printf(string.format("No trained models found for %s.\nTrain models in the Training tab [F6] and run 'Evaluate'.", currentSetMode == "base" and "Base Set" or "Spec vs Spec Matchup Set"), 0, screenH / 2 - 20, screenW, "center")
        return
    end

    -- 3. Matrix Table Dimensions
    local startX = 240
    local startY = 125
    local cellW = math.min(100, math.max(60, (screenW - startX - 40) / math.max(1, numModels)))
    local cellH = 42

    -- Column Headers (Opponents)
    for c = 1, numModels do
        local entry = filteredModels[c]
        local mod = entry.model
        local cx = startX + (c - 1) * cellW
        love.graphics.setColor(0.12, 0.16, 0.24, 0.9)
        love.graphics.rectangle("fill", cx + 1, startY - 36, cellW - 2, 32, 4)
        icons.drawClassIcon(mod.spec == "frost_mage" and "mage" or "warlock", cx + 10, startY - 20, 18)
        love.graphics.setColor(0.8, 0.9, 1.0, 1.0)
        local shortName = mod.name:gsub("^pipeline ", ""):gsub("^base ", ""):sub(1, 7)
        love.graphics.printf(shortName, cx + 18, startY - 28, cellW - 18, "center")
    end

    -- Rows (Candidate Models)
    for r = 1, numModels do
        local rowEntry = filteredModels[r]
        local rowMod = rowEntry.model
        local ry = startY + (r - 1) * cellH

        -- Row Header (Model Name & Elo)
        local isRowSel = (r == selectedRow)
        love.graphics.setColor(isRowSel and 0.16 or 0.08, isRowSel and 0.22 or 0.11, isRowSel and 0.32 or 0.17, 0.9)
        love.graphics.rectangle("fill", 24, ry + 1, startX - 32, cellH - 2, 4)

        icons.drawClassIcon(rowMod.spec == "frost_mage" and "mage" or "warlock", 42, ry + cellH * 0.5, 24)

        love.graphics.setColor(0.95, 0.95, 1.0, 1.0)
        local mName = rowMod.name:gsub("^pipeline ", "")
        if #mName > 20 then mName = mName:sub(1, 18) .. ".." end
        love.graphics.print(mName, 60, ry + 5)
        love.graphics.setColor(0.45, 0.70, 0.95, 0.9)
        love.graphics.print(string.format("Elo: %.0f", rowMod.elo), 60, ry + 22)

        -- Model vs Model Cells
        for c = 1, numModels do
            local colEntry = filteredModels[c]
            local cx = startX + (c - 1) * cellW
            local isSel = (r == selectedRow and c == selectedCol)

            if r == c then
                -- Diagonal mirror
                love.graphics.setColor(0.06, 0.08, 0.12, 0.9)
                love.graphics.rectangle("fill", cx + 1, ry + 1, cellW - 2, cellH - 2, 4)
                love.graphics.setColor(0.3, 0.35, 0.45, 0.6)
                love.graphics.printf("---", cx, ry + 12, cellW, "center")
            else
                local origR = rowEntry.origIdx
                local origC = colEntry.origIdx
                local res = MATRIX_DATA.matrix[origR] and MATRIX_DATA.matrix[origR][origC]
                local wr = res and res.win_rate or 0.0
                local col = getWinRateColor(wr)

                love.graphics.setColor(col[1] * 0.22, col[2] * 0.22, col[3] * 0.22, 0.92)
                love.graphics.rectangle("fill", cx + 1, ry + 1, cellW - 2, cellH - 2, 4)

                if isSel then
                    love.graphics.setColor(1, 1, 1, 0.9)
                    love.graphics.rectangle("line", cx, ry, cellW, cellH, 4)
                end

                love.graphics.setColor(col[1], col[2], col[3], 1.0)
                love.graphics.printf(string.format("%.0f%%", wr * 100), cx, ry + 12, cellW, "center")
            end
        end
    end

    -- 4. Matchup Detail Card (Bottom Panel)
    local cardY = startY + numModels * cellH + 24
    local cardH = screenH - cardY - 20
    if cardH > 80 then
        love.graphics.setColor(0.08, 0.10, 0.16, 0.95)
        love.graphics.rectangle("fill", 24, cardY, screenW - 48, cardH, 8)
        love.graphics.setColor(0.2, 0.25, 0.35, 0.8)
        love.graphics.rectangle("line", 24, cardY, screenW - 48, cardH, 8)

        local rowEntry = filteredModels[selectedRow]
        local colEntry = filteredModels[selectedCol]

        if rowEntry and colEntry then
            local rowMod = rowEntry.model
            local colMod = colEntry.model
            local targetName = colMod.name
            local targetElo = string.format("%.0f Elo", colMod.elo)
            local origR = rowEntry.origIdx
            local origC = colEntry.origIdx
            local res = (selectedRow ~= selectedCol) and (MATRIX_DATA.matrix[origR] and MATRIX_DATA.matrix[origR][origC]) or nil
            local matchFile = string.format("matches/match_%s_vs_%s.lua", rowMod.file:gsub("%.bin$", ""), colMod.file:gsub("%.bin$", ""))

            love.graphics.setColor(0.2, 0.7, 1.0, 1.0)
            love.graphics.print("MATCHUP DETAILS", 42, cardY + 12)
            love.graphics.setColor(0.95, 0.95, 1.0, 1.0)
            love.graphics.print(string.format("%s (%.0f Elo)   VS   %s (%s)", rowMod.name, rowMod.elo, targetName, targetElo), 42, cardY + 30)

            local statsY = cardY + 54

            if res and res.duels > 0 then
                local wrCol = getWinRateColor(res.win_rate)
                love.graphics.setColor(wrCol[1], wrCol[2], wrCol[3], 1.0)
                love.graphics.print(string.format("Win Rate: %.1f%% (%dW / %dL / %dD out of %d duels)", res.win_rate * 100, res.wins_a, res.wins_b, res.draws, res.duels), 42, statsY)
                love.graphics.setColor(0.7, 0.8, 0.9, 1.0)
                love.graphics.print(string.format("Average Match Duration: %.2fs  |  Avg HP: [A] %.0f/2000 vs [B] %.0f/2000", res.avg_time, res.hp_a, res.hp_b), 42, statsY + 18)

                love.graphics.setColor(0.4, 0.9, 0.5, 1.0)
                love.graphics.print(string.format("> Press [SPACE] or [ENTER] to Load Match Fight Replay: '%s'", matchFile), 42, statsY + 38)
            else
                love.graphics.setColor(0.6, 0.7, 0.8, 1.0)
                love.graphics.print("(Identical mirror matchup)", 42, statsY)
            end
        end
    end
end

return matrix_view
