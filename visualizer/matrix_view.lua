-- ⚔️ PVP_SIM: SPEC VS SPEC MATCHUP MATRIX DASHBOARD (Love2D Native Module)
local ui = require("ui")
local icons = require("icons_manager")
local talents_data = require("talents_data")
local match_runner = require("match_runner")

local matrix_view = {}

local savedSpecs = {}
local selectedSpecs = {} -- set of filenames/ids that are checked
local matrixData = nil -- computed NxN matrix from matches directory
local selectedRow = 1
local selectedCol = 1

local buttons = {}
local noticeText = nil
local noticeTimer = 0.0

-- Configurable presets for batch combinations
local PRESETS = {
    { id = "fast", label = "Fast (1k)", rollouts = 1024, workers = 4, eval = "heuristic" },
    { id = "standard", label = "Standard (4k)", rollouts = 4096, workers = 8, eval = "heuristic" },
    { id = "deep", label = "Deep (16k)", rollouts = 16384, workers = 16, eval = "rollout" },
}
local selectedPresetIdx = 1

local function sanitizeId(str)
    return (str or "spec"):lower():gsub("%s+", "_"):gsub("[^%w_%-]", "")
end

function matrix_view.init()
    matrix_view.refreshSpecs()
    matrix_view.scanMatrix()
end

function matrix_view.refreshSpecs()
    savedSpecs = talents_data.loadSavedSpecs("specs")
    if #savedSpecs == 0 then
        savedSpecs = talents_data.loadSavedSpecs("../specs")
    end
    -- Default: check all saved specs
    selectedSpecs = {}
    for _, s in ipairs(savedSpecs) do
        local id = sanitizeId(s.filename or s.name)
        selectedSpecs[id] = true
    end
end

-- Scans the matches/ directory to compute the latest win probabilities
function matrix_view.scanMatrix()
    local checkedList = {}
    for _, s in ipairs(savedSpecs) do
        local id = sanitizeId(s.filename or s.name)
        if selectedSpecs[id] then
            table.insert(checkedList, s)
        end
    end

    local N = #checkedList
    local grid = {}
    for r = 1, N do
        grid[r] = {}
        for c = 1, N do
            grid[r][c] = {
                duels = 0,
                wins_a = 0,
                wins_b = 0,
                draws = 0,
                win_rate = 0.0,
                total_time = 0.0,
                match_file = nil,
            }
        end
    end

    for r = 1, N do
        local a = checkedList[r]
        local idA = sanitizeId(a.filename or a.name)
        for c = 1, N do
            local b = checkedList[c]
            local idB = sanitizeId(b.filename or b.name)
            local matchFile = string.format("matches/match_%s_vs_%s.lua", idA, idB)
            local file = io.open(matchFile, "r")
            if not file then
                matchFile = "../" .. matchFile
                file = io.open(matchFile, "r")
            end

            if file then
                local content = file:read(4096) or ""
                file:close()
                local victor = tonumber(content:match('victor%s*=%s*(%d+)'))
                local total_time = tonumber(content:match('total_time%s*=%s*([%d%.]+)')) or 0
                if victor ~= nil then
                    grid[r][c].duels = 1
                    grid[r][c].total_time = total_time
                    grid[r][c].match_file = matchFile:gsub("^%.%./", "")
                    if victor == 0 then
                        grid[r][c].wins_a = 1
                        grid[r][c].win_rate = 1.0
                    elseif victor == 1 then
                        grid[r][c].wins_b = 1
                        grid[r][c].win_rate = 0.0
                    else
                        grid[r][c].draws = 1
                        grid[r][c].win_rate = 0.5
                    end
                end
            end
        end
    end

    matrixData = {
        specs = checkedList,
        grid = grid,
    }

    if selectedRow > N then selectedRow = math.max(1, N) end
    if selectedCol > N then selectedCol = math.max(1, N) end
end

local function getWinRateColor(wr)
    if wr >= 0.75 then
        return { 0.15, 0.85, 0.35 } -- Strong win (bright green)
    elseif wr >= 0.55 then
        return { 0.30, 0.75, 0.55 } -- Favorable win
    elseif wr >= 0.45 then
        return { 0.85, 0.75, 0.20 } -- Even (yellowish)
    elseif wr >= 0.25 then
        return { 0.90, 0.50, 0.25 } -- Unfavorable (orange)
    else
        return { 0.95, 0.25, 0.25 } -- Losing (red)
    end
end

local liveScanTimer = 0.0

function matrix_view.update(dt)
    match_runner.update(dt)
    if match_runner.isActive() then
        liveScanTimer = liveScanTimer + dt
        if liveScanTimer >= 0.5 then
            liveScanTimer = 0.0
            matrix_view.scanMatrix()
        end
    end

    if match_runner.pollCompleted() then
        matrix_view.scanMatrix()
        noticeText = "All spec combinations finished! Matrix updated."
        noticeTimer = 4.0
    end
    if noticeTimer > 0 then
        noticeTimer = noticeTimer - dt
        if noticeTimer <= 0 then noticeText = nil end
    end
end

function matrix_view.keypressed(key)
    if not matrixData or #matrixData.specs == 0 then return end
    local N = #matrixData.specs
    if key == "up" or key == "w" then
        selectedRow = math.max(1, selectedRow - 1)
    elseif key == "down" or key == "s" then
        selectedRow = math.min(N, selectedRow + 1)
    elseif key == "left" or key == "a" then
        selectedCol = math.max(1, selectedCol - 1)
    elseif key == "right" or key == "d" then
        selectedCol = math.min(N, selectedCol + 1)
    elseif key == "return" or key == "space" then
        local cell = matrixData.grid[selectedRow] and matrixData.grid[selectedRow][selectedCol]
        if cell and cell.match_file then
            return cell.match_file
        end
    end
    return nil
end

-- Kick off simulations for all checked combinations
function matrix_view.kickoffSimulations()
    local checkedList = {}
    for _, s in ipairs(savedSpecs) do
        local id = sanitizeId(s.filename or s.name)
        if selectedSpecs[id] then
            table.insert(checkedList, s)
        end
    end

    if #checkedList == 0 then
        noticeText = "No specs selected! Check at least 1 spec."
        noticeTimer = 3.0
        return
    end

    local pairs = {}
    for r = 1, #checkedList do
        for c = 1, #checkedList do
            table.insert(pairs, { a = checkedList[r], b = checkedList[c] })
        end
    end

    local curPreset = PRESETS[selectedPresetIdx] or PRESETS[1]
    local cfg = {
        rollouts = curPreset.rollouts,
        workers = curPreset.workers,
        evaluator = curPreset.eval,
        algorithm = "puct",
        c_puct = 1.414,
        distance = 25,
        hp_a = 2000,
        hp_b = 2000,
    }

    local ok, err = match_runner.startBatch(pairs, cfg)
    if ok then
        noticeText = string.format("Started %d matchups with %s preset (%d rollouts, %d workers)!", #pairs, curPreset.label, curPreset.rollouts, curPreset.workers)
        noticeTimer = 4.0
    else
        noticeText = "Error: " .. tostring(err)
        noticeTimer = 4.0
    end
end

function matrix_view.draw()
    buttons = {}
    local g = love.graphics
    local screenW = ui.width()
    local screenH = ui.height()

    -- 1. Top Control Bar: Spec Selector Checkboxes & Action Buttons
    local barY = 16
    local barH = 50
    ui.drawCard(24, barY, screenW - 48, barH, false, false, 6)

    icons.draw("ui_sword", 42, barY + barH * 0.5, 24)
    ui.setFont("header")
    g.setColor(0.2, 0.75, 1.0, 1.0)
    g.print("SPEC MATCHUP MATRIX", 62, barY + 11)
    ui.resetFont()

    -- Action buttons on top right
    local btnW = 150
    local btnH = 32
    local rightX = screenW - 24 - 12 - btnW

    -- Run All Matchups Button
    local isRunning = match_runner.isActive()
    if isRunning then
        g.setColor(0.3, 0.45, 0.2, 0.95)
        g.rectangle("fill", rightX, barY + 9, btnW, btnH, 4)
        g.setColor(0.5, 0.8, 0.3, 1.0)
        g.rectangle("line", rightX, barY + 9, btnW, btnH, 4)
        g.setColor(1, 1, 1, 1)
        g.printf("SIMULATING...", rightX, barY + 17, btnW, "center")
    else
        g.setColor(0.15, 0.55, 0.35, 0.95)
        g.rectangle("fill", rightX, barY + 9, btnW, btnH, 4)
        g.setColor(0.30, 0.90, 0.55, 1.0)
        g.rectangle("line", rightX, barY + 9, btnW, btnH, 4)
        g.setColor(1, 1, 1, 1)
        g.printf("RUN COMBINATIONS", rightX, barY + 17, btnW, "center")

        table.insert(buttons, {
            x = rightX, y = barY + 9, w = btnW, h = btnH,
            action = function() matrix_view.kickoffSimulations() end
        })
    end

    -- Refresh Matrix Button
    rightX = rightX - 12 - 120
    g.setColor(0.12, 0.20, 0.32, 0.9)
    g.rectangle("fill", rightX, barY + 9, 120, btnH, 4)
    g.setColor(0.25, 0.45, 0.70, 0.8)
    g.rectangle("line", rightX, barY + 9, 120, btnH, 4)
    g.setColor(0.9, 0.95, 1.0, 1.0)
    g.printf("REFRESH DATA", rightX, barY + 17, 120, "center")

    table.insert(buttons, {
        x = rightX, y = barY + 9, w = 120, h = btnH,
        action = function()
            matrix_view.refreshSpecs()
            matrix_view.scanMatrix()
            noticeText = "Matrix data refreshed from matches directory."
            noticeTimer = 2.5
        end
    })

    -- Select All / Clear Buttons
    rightX = rightX - 12 - 90
    g.setColor(0.12, 0.18, 0.28, 0.9)
    g.rectangle("fill", rightX, barY + 9, 90, btnH, 4)
    g.setColor(0.25, 0.35, 0.50, 0.8)
    g.rectangle("line", rightX, barY + 9, 90, btnH, 4)
    g.setColor(0.8, 0.85, 0.95, 1.0)
    g.printf("ALL SPECS", rightX, barY + 17, 90, "center")

    table.insert(buttons, {
        x = rightX, y = barY + 9, w = 90, h = btnH,
        action = function()
            for _, s in ipairs(savedSpecs) do
                selectedSpecs[sanitizeId(s.filename or s.name)] = true
            end
            matrix_view.scanMatrix()
        end
    })

    -- Presets buttons (Fast, Standard, Deep)
    local presetW = 96
    for i = #PRESETS, 1, -1 do
        local p = PRESETS[i]
        rightX = rightX - 8 - presetW
        local isSel = (i == selectedPresetIdx)
        g.setColor(isSel and 0.18 or 0.08, isSel and 0.45 or 0.12, isSel and 0.70 or 0.20, 0.95)
        g.rectangle("fill", rightX, barY + 9, presetW, btnH, 4)
        g.setColor(isSel and 0.35 or 0.20, isSel and 0.80 or 0.28, isSel and 1.0 or 0.38, isSel and 1.0 or 0.8)
        g.rectangle("line", rightX, barY + 9, presetW, btnH, 4)
        g.setColor(1, 1, 1, isSel and 1.0 or 0.7)
        g.printf(p.label, rightX, barY + 17, presetW, "center")

        table.insert(buttons, {
            x = rightX, y = barY + 9, w = presetW, h = btnH,
            action = function()
                selectedPresetIdx = i
                local activeP = PRESETS[selectedPresetIdx]
                noticeText = string.format("Selected %s: %d rollouts, %d workers, %s", activeP.label, activeP.rollouts, activeP.workers, activeP.eval)
                noticeTimer = 3.0
            end
        })
    end

    -- Status or Notice display
    local _, curIdx, tot, curName, lastErr = match_runner.getStatus()
    if isRunning then
        g.setColor(0.3, 0.9, 0.5, 1.0)
        local pct = tot > 0 and (curIdx / tot) or 0
        local progW = 160
        local progH = 14
        local progX = 215
        local progY = barY + 18
        g.setColor(0.1, 0.15, 0.22, 1.0)
        g.rectangle("fill", progX, progY, progW, progH, 3)
        g.setColor(0.2, 0.8, 0.45, 0.9)
        g.rectangle("fill", progX, progY, progW * pct, progH, 3)
        g.setColor(0.3, 0.9, 0.6, 1.0)
        g.rectangle("line", progX, progY, progW, progH, 3)
        g.setColor(1, 1, 1, 1)
        g.printf(string.format("%d/%d", curIdx, tot), progX, progY + 1, progW, "center")

        g.setColor(0.85, 0.92, 1.0, 1.0)
        local matchName = #curName > 20 and (curName:sub(1, 18) .. "..") or curName
        g.print("Active: " .. matchName, progX + progW + 12, barY + 16)
    elseif lastErr then
        g.setColor(1.0, 0.35, 0.35, 1.0)
        -- Clean up error text (remove extra newlines)
        local singleLineErr = lastErr:gsub("[\r\n]+", " "):gsub("%s+", " ")
        local maxChars = math.floor((screenW - 550) / 7.5)
        local errShort = #singleLineErr > maxChars and (singleLineErr:sub(1, maxChars - 3) .. "...") or singleLineErr
        ui.setFont("small")
        g.print("Error: " .. errShort, 215, barY + 16)
        ui.resetFont()

        -- Hover tooltip over error to see full log message
        local mx, my = love.mouse.getPosition()
        mx, my = ui.contentPoint(mx, my)
        if mx >= 215 and mx <= 215 + 400 and my >= barY + 10 and my <= barY + 36 then
            local ttW = math.min(screenW - 48, 640)
            local ttH = 90
            local ttX = 24
            local ttY = barY + barH + 8
            ui.drawCard(ttX, ttY, ttW, ttH, false, true, 6)
            ui.setFont("small")
            g.setColor(1.0, 0.45, 0.45, 1.0)
            g.print("Simulation Failure Details:", ttX + 12, ttY + 10)
            g.setColor(0.9, 0.9, 0.95, 0.95)
            g.printf(singleLineErr, ttX + 12, ttY + 30, ttW - 24, "left")
            ui.resetFont()
        end
    elseif noticeText then
        g.setColor(0.2, 0.8, 1.0, 1.0)
        g.print(noticeText, 215, barY + 16)
    else
        local p = PRESETS[selectedPresetIdx]
        g.setColor(0.55, 0.65, 0.75, 1.0)
        g.print(string.format("Config: %d rollouts | %d workers | %s", p.rollouts, p.workers, p.eval), 215, barY + 16)
    end

    -- 2. Left Sidebar: Spec Checkbox Selector
    local sideW = 280
    local mainY = barY + barH + 14
    local cardH = 140
    local gridH = screenH - mainY - cardH - 24
    local sideH = gridH

    g.setColor(0.06, 0.08, 0.14, 0.95)
    g.rectangle("fill", 24, mainY, sideW, sideH, 6)
    g.setColor(0.18, 0.25, 0.38, 0.8)
    g.rectangle("line", 24, mainY, sideW, sideH, 6)

    g.setColor(0.2, 0.75, 1.0, 1.0)
    g.print("INCLUDED SPECS", 36, mainY + 14)
    g.setColor(0.5, 0.6, 0.7, 1.0)
    g.print("(Toggle to filter / match)", 160, mainY + 14)

    local rowY = mainY + 42
    for idx, s in ipairs(savedSpecs) do
        local id = sanitizeId(s.filename or s.name)
        local isChecked = selectedSpecs[id] == true

        -- Checkbox square
        local boxX = 36
        local boxY = rowY + 3
        g.setColor(isChecked and 0.15 or 0.08, isChecked and 0.55 or 0.12, isChecked and 0.35 or 0.20, 0.95)
        g.rectangle("fill", boxX, boxY, 16, 16, 3)
        g.setColor(isChecked and 0.30 or 0.22, isChecked and 0.90 or 0.30, isChecked and 0.55 or 0.40, 1.0)
        g.rectangle("line", boxX, boxY, 16, 16, 3)
        if isChecked then
            g.setColor(1, 1, 1, 1)
            g.printf("X", boxX, boxY + 1, 16, "center")
        end

        -- Spec title & build
        local classColor = (s.class == "frost_mage" or s.class == "mage") and { 0.4, 0.8, 1.0 } or { 0.7, 0.45, 0.95 }
        g.setColor(classColor[1], classColor[2], classColor[3], 1.0)
        local title = s.name or id
        if #title > 22 then title = title:sub(1, 20) .. ".." end
        g.print(title, boxX + 26, rowY + 2)

        if s.talents_summary then
            g.setColor(0.5, 0.6, 0.7, 1.0)
            g.print(s.talents_summary, boxX + 26, rowY + 18)
        end

        -- Row clickable toggle
        table.insert(buttons, {
            x = 30, y = rowY, w = sideW - 12, h = 36,
            action = function()
                selectedSpecs[id] = not isChecked
                matrix_view.scanMatrix()
            end
        })

        rowY = rowY + 40
    end

    -- 3. Matrix Heatmap Grid (Right Side)
    local gridX = 24 + sideW + 16
    local gridW = screenW - gridX - 24
    g.setColor(0.06, 0.08, 0.14, 0.95)
    g.rectangle("fill", gridX, mainY, gridW, gridH, 6)
    g.setColor(0.18, 0.25, 0.38, 0.8)
    g.rectangle("line", gridX, mainY, gridW, gridH, 6)

    if not matrixData or #matrixData.specs == 0 then
        g.setColor(0.5, 0.6, 0.7, 1.0)
        g.printf("No specs selected. Check one or more specs on the left.", gridX, mainY + gridH * 0.4, gridW, "center")
    else
        local specs = matrixData.specs
        local N = #specs
        local labelMargin = 120
        local cellW = math.min(80, (gridW - labelMargin - 20) / N)
        local cellH = math.min(48, (gridH - 70) / N)
        local startX = gridX + labelMargin
        local startY = mainY + 50

        -- Top Column Headers (Fighter B)
        g.setColor(0.4, 0.65, 0.9, 1.0)
        g.print("VS FIGHTER B (OPPONENT)", startX, mainY + 12)
        for c = 1, N do
            local cx = startX + (c - 1) * cellW
            local s = specs[c]
            local cCol = (s.class == "frost_mage" or s.class == "mage") and { 0.4, 0.8, 1.0 } or { 0.7, 0.45, 0.95 }
            g.setColor(cCol[1], cCol[2], cCol[3], 0.9)
            local shortName = s.name or "Spec"
            if #shortName > 9 then shortName = shortName:sub(1, 8) .. "." end
            g.printf(shortName, cx, mainY + 30, cellW, "center")
        end

        -- Rows (Fighter A)
        for r = 1, N do
            local ry = startY + (r - 1) * cellH
            local sA = specs[r]
            local rCol = (sA.class == "frost_mage" or sA.class == "mage") and { 0.4, 0.8, 1.0 } or { 0.7, 0.45, 0.95 }
            g.setColor(rCol[1], rCol[2], rCol[3], 0.9)
            local rowTitle = sA.name or "Spec"
            if #rowTitle > 14 then rowTitle = rowTitle:sub(1, 13) .. "." end
            g.printf(rowTitle, gridX + 10, ry + cellH * 0.3, labelMargin - 15, "right")

            for c = 1, N do
                local cx = startX + (c - 1) * cellW
                local cell = matrixData.grid[r][c]
                local isSel = (r == selectedRow and c == selectedCol)

                if cell.duels > 0 then
                    local color = getWinRateColor(cell.win_rate)
                    g.setColor(color[1] * 0.25, color[2] * 0.25, color[3] * 0.25, 0.95)
                    g.rectangle("fill", cx + 2, ry + 2, cellW - 4, cellH - 4, 4)

                    if isSel then
                        g.setColor(1, 1, 1, 0.95)
                        g.setLineWidth(2)
                        g.rectangle("line", cx + 1, ry + 1, cellW - 2, cellH - 2, 4)
                        g.setLineWidth(1)
                    else
                        g.setColor(color[1] * 0.7, color[2] * 0.7, color[3] * 0.7, 0.6)
                        g.rectangle("line", cx + 2, ry + 2, cellW - 4, cellH - 4, 4)
                    end

                    g.setColor(color[1], color[2], color[3], 1.0)
                    g.printf(string.format("%.0f%%", cell.win_rate * 100), cx, ry + cellH * 0.25, cellW, "center")
                else
                    -- No match recorded
                    g.setColor(0.1, 0.12, 0.18, 0.8)
                    g.rectangle("fill", cx + 2, ry + 2, cellW - 4, cellH - 4, 4)
                    if isSel then
                        g.setColor(1, 1, 1, 0.95)
                        g.setLineWidth(2)
                        g.rectangle("line", cx + 1, ry + 1, cellW - 2, cellH - 2, 4)
                        g.setLineWidth(1)
                    else
                        g.setColor(0.18, 0.22, 0.30, 0.8)
                        g.rectangle("line", cx + 2, ry + 2, cellW - 4, cellH - 4, 4)
                    end
                    g.setColor(0.4, 0.45, 0.55, 0.8)
                    g.printf("-", cx, ry + cellH * 0.25, cellW, "center")
                end

                -- Cell click to select
                table.insert(buttons, {
                    x = cx, y = ry, w = cellW, h = cellH,
                    action = function()
                        selectedRow = r
                        selectedCol = c
                    end
                })
            end
        end
    end

    -- 4. Bottom Matchup Detail Card
    local cardY = mainY + gridH + 12
    g.setColor(0.08, 0.10, 0.16, 0.95)
    g.rectangle("fill", 24, cardY, screenW - 48, cardH, 8)
    g.setColor(0.2, 0.25, 0.35, 0.8)
    g.rectangle("line", 24, cardY, screenW - 48, cardH, 8)

    if matrixData and #matrixData.specs > 0 then
        local sA = matrixData.specs[selectedRow]
        local sB = matrixData.specs[selectedCol]
        local cell = matrixData.grid[selectedRow] and matrixData.grid[selectedRow][selectedCol]

        g.setColor(0.2, 0.75, 1.0, 1.0)
        g.print("SELECTED MATCHUP DEEP-DIVE", 42, cardY + 14)

        g.setColor(0.95, 0.95, 1.0, 1.0)
        g.print(string.format("%s (%s)   VS   %s (%s)", sA.name or "Spec A", sA.talents_summary or "", sB.name or "Spec B", sB.talents_summary or ""), 42, cardY + 36)

        if cell and cell.duels > 0 then
            local wrCol = getWinRateColor(cell.win_rate)
            g.setColor(wrCol[1], wrCol[2], wrCol[3], 1.0)
            local victorStr = cell.wins_a > 0 and (sA.name .. " Won") or (cell.wins_b > 0 and (sB.name .. " Won") or "Draw")
            g.print(string.format("Outcome: %s (Win Probability: %.0f%%)  |  Fight Duration: %.2fs", victorStr, cell.win_rate * 100, cell.total_time), 42, cardY + 62)

            g.setColor(0.35, 0.90, 0.55, 1.0)
            g.print(string.format("Replay Stored: '%s'  (Press [SPACE] or Click to Load in Arena)", cell.match_file or ""), 42, cardY + 88)

            table.insert(buttons, {
                x = 40, y = cardY + 84, w = 600, h = 26,
                action = function()
                    if cell.match_file then
                        -- Signal match load
                        matrix_view.matchToLoad = cell.match_file
                    end
                end
            })
        else
            g.setColor(0.6, 0.65, 0.75, 1.0)
            g.print("No matchup replay simulated yet for this spec pairing.", 42, cardY + 62)
            g.setColor(0.25, 0.70, 0.95, 1.0)
            g.print("Click 'RUN COMBINATIONS' above to simulate all checked pairs sequentially.", 42, cardY + 84)
        end
    end
end

function matrix_view.mousepressed(x, y, button)
    for _, btn in ipairs(buttons) do
        if x >= btn.x and x <= btn.x + btn.w and y >= btn.y and y <= btn.y + btn.h then
            btn.action()
            if matrix_view.matchToLoad then
                local m = matrix_view.matchToLoad
                matrix_view.matchToLoad = nil
                return m
            end
            return true
        end
    end
    return nil
end

return matrix_view
