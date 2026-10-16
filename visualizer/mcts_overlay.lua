local json = require("json")
local icons = require("icons_manager")
local class_view = require("class_view")
local ui = require("ui")

local mcts_overlay = {}

local currentSearchData = nil
local isVisible = true
local isTuningOpen = false

function mcts_overlay.loadSearchData(path)
    currentSearchData = nil
    if not path then return end

    -- Path may be match.lua, we need match.lua.search.json
    local searchPath = path
    if not searchPath:match("%.search%.json$") then
        searchPath = path .. ".search.json"
    end

    local f = io.open(searchPath, "r")
    if not f then
        f = io.open("../" .. searchPath, "r")
    end

    if not f then
        return
    end

    local content = f:read("*a")
    f:close()

    if not content or #content == 0 then return end
    local ok, data = pcall(json.decode, content)
    if ok and data and data.decisions then
        currentSearchData = data
    end
end

function mcts_overlay.toggle()
    isVisible = not isVisible
end

function mcts_overlay.setVisible(v)
    isVisible = v
end

function mcts_overlay.isVisible()
    return isVisible and (currentSearchData ~= nil)
end

function mcts_overlay.hasData()
    return currentSearchData ~= nil
end

-- Find decision record closest to or at combat time t (in seconds)
local function getDecisionAtTime(t)
    if not currentSearchData or not currentSearchData.decisions then return nil end
    local decs = currentSearchData.decisions
    if #decs == 0 then return nil end

    local targetTick = math.floor(t * 100 + 0.5)

    -- Binary search or linear search for latest decision <= targetTick
    local low = 1
    local high = #decs
    local best = decs[1]

    while low <= high do
        local mid = math.floor((low + high) / 2)
        local d = decs[mid]
        if d.tick <= targetTick then
            best = d
            low = mid + 1
        else
            high = mid - 1
        end
    end

    return best
end

function mcts_overlay.draw(currentTime, meta)
    if not isVisible or not currentSearchData then return end

    local dec = getDecisionAtTime(currentTime)
    if not dec then return end

    local screenW = ui.width()
    local screenH = ui.height()

    -- Bottom-left or bottom HUD placement just above scrubber controls
    -- Controls are at screenH - 120, height 106.
    -- We place the MCTS panel in the upper/mid area or docked on the right side.
    -- Docked panel on the top-right / right side below top bar:
    local panelW = 340
    local panelH = 220
    local panelX = screenW - panelW - 16
    local panelY = 74

    local g = love.graphics
    g.setColor(0.04, 0.06, 0.10, 0.94)
    g.rectangle("fill", panelX, panelY, panelW, panelH, 6)
    g.setColor(0.2, 0.7, 1.0, 0.8)
    g.setLineWidth(1)
    g.rectangle("line", panelX, panelY, panelW, panelH, 6)

    -- Header
    g.setColor(0.2, 0.75, 1.0, 1.0)
    g.rectangle("fill", panelX + 8, panelY + 8, 4, 16)
    g.setColor(1, 1, 1, 1)
    g.print("MCTS / PUCT SEARCH MONITOR", panelX + 18, panelY + 8)

    -- Toggle hint
    g.setColor(0.5, 0.65, 0.8, 1.0)
    g.printf("[O] Overlay", panelX + panelW - 90, panelY + 8, 80, "right")

    -- Telemetry stats line
    local stats = dec.stats or {}
    local rollouts = stats.rollouts or 0
    local depth = stats.depth or 0
    local nodes = stats.nodes or 0
    local decSecs = dec.seconds or 0
    local decTimeMs = decSecs * 1000.0
    local rps = decSecs > 0.0001 and (rollouts / decSecs) or 0
    local rpsStr = rps >= 1000 and string.format("%.1fk/s", rps / 1000.0) or string.format("%d/s", math.floor(rps))

    g.setColor(0.65, 0.75, 0.85, 1.0)
    g.print(string.format("Tick: %d (%.2fs) | Depth: %d | %.1fms", dec.tick or 0, (dec.tick or 0)*0.01, depth, decTimeMs), panelX + 12, panelY + 28)
    g.print(string.format("Rollouts: %d (%s) | Nodes: %d", rollouts, rpsStr, nodes), panelX + 12, panelY + 44)

    -- Separator
    g.setColor(0.15, 0.22, 0.32, 0.8)
    g.line(panelX + 8, panelY + 62, panelX + panelW - 8, panelY + 62)

    -- Two columns: Left for Player A (Warlock), Right for Player B (Frost Mage)
    local colW = (panelW - 24) / 2
    local colAX = panelX + 10
    local colBX = panelX + 14 + colW

    local function drawPlayerColumn(side, colX, title, colHeader)
        g.setColor(colHeader[1], colHeader[2], colHeader[3], 1.0)
        g.print(title, colX, panelY + 68)

        local choices = dec.choices and dec.choices[side]
        local strats = dec.strategies and dec.strategies[side]
        if not choices or not choices.items or not strats then
            g.setColor(0.5, 0.5, 0.6, 1.0)
            g.print("Forced / GCD", colX, panelY + 86)
            return
        end

        local items = choices.items
        local numItems = choices.len or #items

        -- Collect candidate actions with non-zero probability
        local candidates = {}
        for i = 1, numItems do
            local p = strats[i] or 0
            if p > 0.005 then
                table.insert(candidates, {
                    action = items[i],
                    prob = p,
                })
            end
        end

        -- Sort by probability descending
        table.sort(candidates, function(a, b) return a.prob > b.prob end)

        local rowY = panelY + 86
        local maxRows = 5
        local committed = dec.actions and dec.actions[side]
        for idx = 1, math.min(#candidates, maxRows) do
            local cand = candidates[idx]
            local act = cand.action
            local prob = cand.prob
            local isChosen = committed and committed.ability == act.ability and math.abs((committed.movement or 0) - (act.movement or 0)) < 0.1

            local spellName = class_view.name(meta, side - 1, act.ability)
            local moveStr = " ·"
            if act.movement and act.movement < -0.5 then
                moveStr = " ▲"
            elseif act.movement and act.movement > 0.5 then
                moveStr = " ▼"
            end

            -- Probability bar
            local barW = colW - 38
            local barH = 16
            g.setColor(0.10, 0.14, 0.22, 0.92)
            g.rectangle("fill", colX, rowY, barW, barH, 2)

            g.setColor(colHeader[1] * (isChosen and 0.85 or 0.62), colHeader[2] * (isChosen and 0.85 or 0.62), colHeader[3] * (isChosen and 0.85 or 0.62), 0.90)
            g.rectangle("fill", colX, rowY, barW * math.min(1.0, prob), barH, 2)
            if isChosen then
                g.setColor(0.98, 0.82, 0.30, 0.90)
                g.rectangle("line", colX, rowY, barW, barH, 2)
            end

            g.setColor(1, 1, 1, 1)
            local label = string.format("%s%s", spellName:sub(1, 9), moveStr)
            g.print(label, colX + 3, rowY + 1)

            -- Percentage
            g.setColor(isChosen and 1.0 or 0.88, isChosen and 0.88 or 0.94, isChosen and 0.38 or 1.0, 1.0)
            g.printf(string.format("%d%%", math.floor(prob * 100 + 0.5)), colX + barW + 2, rowY + 1, 36, "left")

            rowY = rowY + 20
        end

        if #candidates == 0 then
            g.setColor(0.5, 0.5, 0.6, 1.0)
            g.print("No distribution", colX, panelY + 86)
        end
    end

    drawPlayerColumn(1, colAX, "Unit A Strategy", { 0.7, 0.45, 1.0 })
    drawPlayerColumn(2, colBX, "Unit B Strategy", { 0.2, 0.85, 0.55 })

    -- Win expectation / committed action footer
    local committedA = dec.actions and dec.actions[1]
    local committedB = dec.actions and dec.actions[2]
    if committedA or committedB then
        local footY = panelY + panelH - 26
        g.setColor(0.15, 0.22, 0.32, 0.8)
        g.line(panelX + 8, footY - 4, panelX + panelW - 8, footY - 4)

        g.setColor(0.85, 0.90, 0.98, 1.0)
        local actAName = committedA and class_view.name(meta, 0, committedA.ability) or "None"
        local actBName = committedB and class_view.name(meta, 1, committedB.ability) or "None"
        g.print(string.format("Committed: A [%s] | B [%s]", actAName, actBName), panelX + 12, footY)
    end

    -- Draw Tuning Panel Drawer if opened
    if isTuningOpen then
        mcts_overlay.drawTuningDrawer(screenW, screenH)
    else
        -- Draw small hint button to open tuning
        local tuneBtnW, tuneBtnH = 96, 20
        local tuneBtnX = panelX
        local tuneBtnY = panelY + panelH + 6
        g.setColor(0.10, 0.16, 0.26, 0.92)
        g.rectangle("fill", tuneBtnX, tuneBtnY, tuneBtnW, tuneBtnH, 4)
        g.setColor(0.25, 0.50, 0.75, 0.8)
        g.rectangle("line", tuneBtnX, tuneBtnY, tuneBtnW, tuneBtnH, 4)
        g.setColor(0.85, 0.95, 1.0, 0.9)
        g.printf("[T] Tuning Panel", tuneBtnX, tuneBtnY + 3, tuneBtnW, "center")
    end
end

local match_generator = require("match_generator")
local tuningButtons = {}

function mcts_overlay.toggleTuning()
    isTuningOpen = not isTuningOpen
end

function mcts_overlay.isTuningOpen()
    return isTuningOpen
end

function mcts_overlay.drawTuningDrawer(screenW, screenH)
    tuningButtons = {}
    local g = love.graphics
    local cfg = match_generator.getConfig()

    local drawerW = 340
    local drawerH = 260
    local drawerX = screenW - drawerW - 16
    local drawerY = 74 + 220 + 8

    g.setColor(0.04, 0.06, 0.10, 0.96)
    g.rectangle("fill", drawerX, drawerY, drawerW, drawerH, 6)
    g.setColor(0.3, 0.8, 0.6, 0.85)
    g.setLineWidth(1)
    g.rectangle("line", drawerX, drawerY, drawerW, drawerH, 6)

    -- Header
    g.setColor(0.3, 0.9, 0.6, 1.0)
    g.rectangle("fill", drawerX + 8, drawerY + 8, 4, 16)
    g.setColor(1, 1, 1, 1)
    g.print("INTERACTIVE SEARCH TUNING", drawerX + 18, drawerY + 8)
    g.setColor(0.6, 0.7, 0.8, 1.0)
    g.printf("[T] Close", drawerX + drawerW - 75, drawerY + 8, 65, "right")

    local curY = drawerY + 32

    local function drawDrawerSelector(label, options, selectedVal, rowY, onSelect, fmt)
        g.setColor(0.65, 0.75, 0.85, 1.0)
        g.print(label, drawerX + 12, rowY + 2)
        local startX = drawerX + 120
        local btnH = 20
        local gap = 4
        local btnW = math.min(48, (drawerW - 132 - math.max(0, #options - 1) * gap) / math.max(1, #options))
        for i, opt in ipairs(options) do
            local bx = startX + (i - 1) * (btnW + gap)
            local isSel = (opt == selectedVal)
            g.setColor(isSel and 0.18 or 0.08, isSel and 0.45 or 0.12, isSel and 0.70 or 0.20, 0.95)
            g.rectangle("fill", bx, rowY, btnW, btnH, 3)
            g.setColor(isSel and 0.40 or 0.18, isSel and 0.85 or 0.28, isSel and 1.0 or 0.38, 0.8)
            g.rectangle("line", bx, rowY, btnW, btnH, 3)
            g.setColor(1, 1, 1, isSel and 1.0 or 0.6)
            local text = fmt and fmt(opt) or tostring(opt)
            g.printf(text, bx, rowY + 3, btnW, "center")

            table.insert(tuningButtons, {
                x = bx, y = rowY, w = btnW, h = btnH,
                action = function() onSelect(opt) end
            })
        end
    end

    -- 1. Rollouts
    drawDrawerSelector("Rollouts:", { 1024, 4096, 16384, 65536 }, cfg.rollouts, curY, function(v) cfg.rollouts = v end, function(v) return (v >= 1024) and (math.floor(v/1024) .. "k") or tostring(v) end)
    curY = curY + 26

    -- 2. Workers
    drawDrawerSelector("Workers:", { 1, 2, 4, 8, 16, 32 }, cfg.workers, curY, function(v) cfg.workers = v end)
    curY = curY + 26

    -- 3. Algorithm
    drawDrawerSelector("Algorithm:", { "puct", "uct", "exp3" }, cfg.algorithm, curY, function(v) cfg.algorithm = v end, function(v) return v:upper() end)
    curY = curY + 26

    -- 4. c_puct
    drawDrawerSelector("c_puct:", { 0.707, 1.414, 2.0, 2.828 }, cfg.c_puct, curY, function(v) cfg.c_puct = v end, function(v) return string.format("%.2f", v) end)
    curY = curY + 26

    -- 5. Evaluator
    drawDrawerSelector("Evaluator:", { "rollout", "heuristic" }, cfg.evaluator, curY, function(v) cfg.evaluator = v end, function(v) return v == "heuristic" and "Heur" or "Rollout" end)
    curY = curY + 30

    -- Re-Simulate Button
    local reSimW = drawerW - 24
    local reSimH = 28
    local reSimX = drawerX + 12
    local reSimY = curY

    if match_generator.isActive() then
        g.setColor(0.35, 0.45, 0.2, 0.95)
        g.rectangle("fill", reSimX, reSimY, reSimW, reSimH, 4)
        g.setColor(0.5, 0.8, 0.3, 1.0)
        g.rectangle("line", reSimX, reSimY, reSimW, reSimH, 4)
        g.setColor(1, 1, 1, 1)
        g.printf("RE-SIMULATING MATCH...", reSimX, reSimY + 6, reSimW, "center")
    else
        g.setColor(0.15, 0.55, 0.40, 0.95)
        g.rectangle("fill", reSimX, reSimY, reSimW, reSimH, 4)
        g.setColor(0.3, 0.9, 0.6, 1.0)
        g.rectangle("line", reSimX, reSimY, reSimW, reSimH, 4)
        g.setColor(1, 1, 1, 1)
        g.printf("RE-RUN MATCH WITH NEW PARAMS", reSimX, reSimY + 6, reSimW, "center")

        table.insert(tuningButtons, {
            x = reSimX, y = reSimY, w = reSimW, h = reSimH,
            action = function() match_generator.startFight() end
        })
    end

    local statusText, err = match_generator.getStatus()
    g.setColor(0.65, 0.75, 0.85, 1.0)
    g.printf("Status: " .. statusText .. (err and (" (" .. err .. ")") or ""), drawerX + 12, reSimY + 34, drawerW - 24, "center")
end

function mcts_overlay.mousepressed(x, y, button)
    if not isVisible then return false end
    if isTuningOpen then
        for _, btn in ipairs(tuningButtons) do
            if x >= btn.x and x <= btn.x + btn.w and y >= btn.y and y <= btn.y + btn.h then
                btn.action()
                return true
            end
        end
    end
    return false
end

return mcts_overlay
