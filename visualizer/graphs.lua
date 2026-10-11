-- 📈 PVP_SIM: TRAINING GRAPHS & PROGRESS DASHBOARD (Love2D Native Module)
local graphs = {}
local json = require("json")

local METRICS_DATA = nil
local currentMetricsPath = "training_metrics.lua"
local selectedGenIdx = 1

local ACTION_COLORS = {
    [0] = { 0.40, 0.45, 0.50 }, -- Idle
    [1] = { 0.65, 0.20, 0.85 }, -- Agony (Purple)
    [2] = { 0.20, 0.75, 0.45 }, -- Corruption (Green)
    [3] = { 0.95, 0.80, 0.10 }, -- Fear (Gold)
    [4] = { 0.30, 0.55, 0.95 }, -- Shadow Bolt (Blue)
    [5] = { 0.90, 0.25, 0.25 }, -- Drain Life (Crimson)
    [6] = { 0.15, 0.85, 0.90 }, -- Unending Resolve (Cyan)
    [7] = { 0.45, 0.90, 0.30 }, -- Death Coil (Lime)
    [8] = { 0.85, 0.40, 0.20 }, -- Cancel Cast (Orange)
}

function graphs.loadMetricsFile(path)
    currentMetricsPath = path
    local file, err = io.open(path, "r")
    if not file then
        path = "../" .. path
        file = io.open(path, "r")
    end

    if not file then
        return false
    end
    if path:match("%.json$") then
        local content = file:read("*a")
        file:close()
        local ok, data = pcall(json.decode, content)
        if not ok then
            print("Error parsing metrics: " .. tostring(data))
            return false
        end
        -- The renderer indexes names by zero-based action ID.
        local names = {}
        for i, name in ipairs(data.action_names) do names[i - 1] = name end
        data.action_names = names
        METRICS_DATA = data
        selectedGenIdx = (data.generations and #data.generations) or 1
        return true
    end
    file:close()

    local fn, loadErr = loadfile(path)
    if fn then
        METRICS_DATA = fn()
        selectedGenIdx = (METRICS_DATA.generations and #METRICS_DATA.generations) or 1
        return true
    else
        print("Error parsing metrics: " .. tostring(loadErr))
    end
    return false
end

function graphs.hasData()
    return METRICS_DATA ~= nil and METRICS_DATA.generations ~= nil and #METRICS_DATA.generations > 0
end

function graphs.update(dt)
    -- Reserved for any animated transitions or smooth scrubbing
end

function graphs.keypressed(key)
    if not graphs.hasData() then return end
    local gens = METRICS_DATA.generations
    if key == "left" or key == "a" then
        selectedGenIdx = math.max(1, selectedGenIdx - 1)
    elseif key == "right" or key == "d" then
        selectedGenIdx = math.min(#gens, selectedGenIdx + 1)
    elseif key == "r" then
        graphs.loadMetricsFile(currentMetricsPath)
    end
end

function graphs.mousepressed(x, y, button)
    if not graphs.hasData() then return end
    local screenW = love.graphics.getWidth()
    local screenH = love.graphics.getHeight()
    local gens = METRICS_DATA.generations
    local numGens = #gens

    -- Check timeline scrubber click at the top
    local scrubX = 40
    local scrubY = 80
    local scrubW = screenW - 80
    local scrubH = 24

    if y >= scrubY - 6 and y <= scrubY + scrubH + 6 and x >= scrubX and x <= scrubX + scrubW then
        local pct = math.max(0, math.min(1.0, (x - scrubX) / scrubW))
        selectedGenIdx = math.max(1, math.min(numGens, math.floor(pct * (numGens - 1) + 0.5) + 1))
    end
end

local function drawCard(x, y, w, h, title, subtitle)
    love.graphics.setColor(0.07, 0.09, 0.15, 0.94)
    love.graphics.rectangle("fill", x, y, w, h, 8)
    love.graphics.setColor(0.18, 0.24, 0.36, 0.8)
    love.graphics.rectangle("line", x, y, w, h, 8)

    if title then
        love.graphics.setColor(0.95, 0.95, 1.0, 1.0)
        love.graphics.print(title, x + 16, y + 14)
    end
    if subtitle then
        love.graphics.setColor(0.5, 0.65, 0.8, 1.0)
        love.graphics.print(subtitle, x + 16, y + 32)
    end
end

function graphs.draw()
    local screenW = love.graphics.getWidth()
    local screenH = love.graphics.getHeight()

    -- 1. Dark Backdrop
    love.graphics.setColor(0.02, 0.04, 0.08, 0.98)
    love.graphics.rectangle("fill", 0, 0, screenW, screenH)

    if not graphs.hasData() then
        love.graphics.setColor(0.8, 0.8, 0.9)
        love.graphics.printf("No training metrics loaded.\nRun './zig-out/bin/pvp_sim --metrics training_metrics.lua' first.", 0, screenH / 2 - 20, screenW, "center")
        return
    end

    local gens = METRICS_DATA.generations
    local numGens = #gens

    -- 2. Header
    love.graphics.setColor(0.12, 0.65, 1.0, 1.0)
    love.graphics.rectangle("fill", 24, 18, 5, 34)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.print("⚔️ PVP_SIM: NEURAL TRAINING TELEMETRY & PROGRESS DASHBOARD", 38, 18)
    love.graphics.setColor(0.55, 0.65, 0.8, 1.0)
    local totalDuels = 0
    for _, generation in ipairs(gens) do totalDuels = totalDuels + (generation.total_duels or 0) end
    love.graphics.print(string.format("Trained: %d Generations  |  Total Duels: %d  |  Press [G] or [ESC] to return to Arena Match Replay", numGens, totalDuels), 38, 38)

    -- 3. Generation Scrubber Bar
    local scrubX = 40
    local scrubY = 70
    local scrubW = screenW - 80
    love.graphics.setColor(0.15, 0.18, 0.26, 1.0)
    love.graphics.rectangle("fill", scrubX, scrubY + 6, scrubW, 8, 4)

    local selPct = (numGens <= 1) and 0 or ((selectedGenIdx - 1) / (numGens - 1))
    love.graphics.setColor(0.2, 0.7, 1.0, 1.0)
    love.graphics.rectangle("fill", scrubX, scrubY + 6, scrubW * selPct, 8, 4)
    love.graphics.circle("fill", scrubX + scrubW * selPct, scrubY + 10, 8)

    love.graphics.setColor(0.8, 0.9, 1.0, 1.0)
    love.graphics.print(string.format("Inspect Gen: %d / %d (Use [←/→] or Click Bar)", selectedGenIdx, numGens), scrubX, scrubY + 22)

    -- 4. Multi-Panel Layout
    local contentY = 110
    local contentH = screenH - contentY - 24
    local colW = (screenW - 56) / 2
    local panelH = (contentH - 16) / 2

    -- -------------------------------------------------------------
    -- Panel 1: Rating Convergence Curves (Min / Mean / Max / Gauntlet Elo)
    -- -------------------------------------------------------------
    local p1X, p1Y = 20, contentY
    drawCard(p1X, p1Y, colW, panelH, "📈 ELO RATING & CONVERGENCE DYNAMICS", "Min / Mean / Max Population Elo & Objective Benchmark")

    local chartX = p1X + 48
    local chartY = p1Y + 60
    local chartW = colW - 68
    local chartH = panelH - 84

    -- Grid lines
    love.graphics.setColor(0.14, 0.18, 0.26, 0.7)
    for g = 0, 4 do
        local gy = chartY + (chartH * g / 4)
        love.graphics.line(chartX, gy, chartX + chartW, gy)
    end

    -- Find Min/Max Elo across entire history for normalization
    local minElo, maxElo = 99999, -99999
    for _, m in ipairs(gens) do
        if m.elo_min < minElo then minElo = m.elo_min end
        if m.elo_max > maxElo then maxElo = m.elo_max end
        if m.has_gauntlet and m.gauntlet_objective_elo > maxElo then maxElo = m.gauntlet_objective_elo end
        if m.has_gauntlet and m.gauntlet_objective_elo < minElo then minElo = m.gauntlet_objective_elo end
    end
    minElo = math.max(0, math.floor(minElo / 100) * 100 - 50)
    maxElo = math.ceil(maxElo / 100) * 100 + 50
    local eloRange = math.max(100, maxElo - minElo)

    -- Axis labels
    love.graphics.setColor(0.45, 0.55, 0.7, 0.9)
    love.graphics.print(tostring(math.floor(maxElo)), chartX - 38, chartY - 6)
    love.graphics.print(tostring(math.floor(minElo)), chartX - 38, chartY + chartH - 10)

    -- Plot Max Elo line (Green)
    love.graphics.setColor(0.2, 0.85, 0.45, 0.9)
    for i = 1, numGens - 1 do
        local x1 = chartX + ((i - 1) / math.max(1, numGens - 1)) * chartW
        local y1 = chartY + chartH - ((gens[i].elo_max - minElo) / eloRange) * chartH
        local x2 = chartX + (i / math.max(1, numGens - 1)) * chartW
        local y2 = chartY + chartH - ((gens[i + 1].elo_max - minElo) / eloRange) * chartH
        love.graphics.line(x1, y1, x2, y2)
    end

    -- Plot Mean Elo line (Blue)
    love.graphics.setColor(0.2, 0.65, 1.0, 0.9)
    for i = 1, numGens - 1 do
        local x1 = chartX + ((i - 1) / math.max(1, numGens - 1)) * chartW
        local y1 = chartY + chartH - ((gens[i].elo_mean - minElo) / eloRange) * chartH
        local x2 = chartX + (i / math.max(1, numGens - 1)) * chartW
        local y2 = chartY + chartH - ((gens[i + 1].elo_mean - minElo) / eloRange) * chartH
        love.graphics.line(x1, y1, x2, y2)
    end

    -- Plot Gauntlet Benchmark Points (Gold Diamonds)
    for i, m in ipairs(gens) do
        if m.has_gauntlet and m.gauntlet_objective_elo > 0 then
            local gx = chartX + ((i - 1) / math.max(1, numGens - 1)) * chartW
            local gy = chartY + chartH - ((m.gauntlet_objective_elo - minElo) / eloRange) * chartH
            love.graphics.setColor(1.0, 0.85, 0.2, 1.0)
            love.graphics.circle("fill", gx, gy, 5)
        end
    end

    -- Vertical indicator for selected generation
    local selChartX = chartX + ((selectedGenIdx - 1) / math.max(1, numGens - 1)) * chartW
    love.graphics.setColor(1, 1, 1, 0.5)
    love.graphics.line(selChartX, chartY, selChartX, chartY + chartH)

    -- Legend
    love.graphics.setColor(0.2, 0.85, 0.45, 1)
    love.graphics.print("■ Max Elo", chartX, p1Y + 32)
    love.graphics.setColor(0.2, 0.65, 1.0, 1)
    love.graphics.print("■ Mean Elo", chartX + 90, p1Y + 32)
    love.graphics.setColor(1.0, 0.85, 0.2, 1)
    love.graphics.print("◆ Gauntlet Elo", chartX + 180, p1Y + 32)

    -- -------------------------------------------------------------
    -- Panel 2: Strategy Shift & Action Breakdown (Stacked Bar / Area)
    -- -------------------------------------------------------------
    local p2X, p2Y = p1X + colW + 16, contentY
    drawCard(p2X, p2Y, colW, panelH, "🎯 EMERGENT STRATEGY & ACTION DISTRIBUTION", "Action Selection Frequency Shift Across Generations")

    local actChartX = p2X + 48
    local actChartY = p2Y + 60
    local actChartW = colW - 68
    local actChartH = panelH - 84

    local barW = math.max(2, (actChartW / numGens) - 2)
    for i, m in ipairs(gens) do
        local bx = actChartX + ((i - 1) / numGens) * actChartW
        local totalActs = 0
        for actId = 0, 8 do
            totalActs = totalActs + (m.action_counts[actId + 1] or 0)
        end
        if totalActs == 0 then totalActs = 1 end

        local curY = actChartY + actChartH
        for actId = 0, 8 do
            local cnt = m.action_counts[actId + 1] or 0
            local segH = (cnt / totalActs) * actChartH
            local col = ACTION_COLORS[actId] or { 0.5, 0.5, 0.5 }
            love.graphics.setColor(col[1], col[2], col[3], (i == selectedGenIdx) and 1.0 or 0.75)
            love.graphics.rectangle("fill", bx, curY - segH, barW, segH)
            curY = curY - segH
        end
    end

    -- Selected Gen Action Legend & Percentages
    local selM = gens[selectedGenIdx]
    local selTotal = 0
    for actId = 0, 8 do selTotal = selTotal + (selM.action_counts[actId + 1] or 0) end
    if selTotal == 0 then selTotal = 1 end

    local legX = p2X + 16
    local legY = p2Y + 34
    for actId = 1, 4 do
        local col = ACTION_COLORS[actId]
        local cnt = selM.action_counts[actId + 1] or 0
        local pct = (cnt / selTotal) * 100
        local name = METRICS_DATA.action_names[actId] or ("Act" .. actId)
        love.graphics.setColor(col[1], col[2], col[3], 1)
        love.graphics.print(string.format("■ %s: %.0f%%", name, pct), legX + (actId - 1) * 100, legY)
    end

    -- -------------------------------------------------------------
    -- Panel 3: Fitness & Duration Distribution
    -- -------------------------------------------------------------
    local p3X, p3Y = 20, contentY + panelH + 16
    drawCard(p3X, p3Y, colW, panelH, "⚡ FITNESS CONVERGENCE & COMPUTE EFFICIENCY", "Generational Best/Mean Fitness and Iteration Compute Time")

    local fChartX = p3X + 48
    local fChartY = p3Y + 60
    local fChartW = colW - 68
    local fChartH = panelH - 84

    -- Min/Max Fitness
    local maxFit = 100.0
    for _, m in ipairs(gens) do
        if m.fitness_best > maxFit then maxFit = m.fitness_best end
    end
    maxFit = math.ceil(maxFit / 500) * 500 + 100

    -- Plot Best Fitness Curve
    love.graphics.setColor(1.0, 0.45, 0.2, 0.9)
    for i = 1, numGens - 1 do
        local x1 = fChartX + ((i - 1) / math.max(1, numGens - 1)) * fChartW
        local y1 = fChartY + fChartH - (gens[i].fitness_best / maxFit) * fChartH
        local x2 = fChartX + (i / math.max(1, numGens - 1)) * fChartW
        local y2 = fChartY + fChartH - (gens[i + 1].fitness_best / maxFit) * fChartH
        love.graphics.line(x1, y1, x2, y2)
    end

    love.graphics.setColor(1.0, 0.45, 0.2, 1)
    love.graphics.print("■ Best Fitness", fChartX, p3Y + 32)
    love.graphics.setColor(0.6, 0.7, 0.8, 1)
    love.graphics.print(string.format("Gen %d Step Duration: %.1f ms", selectedGenIdx, selM.duration_ms or 0), fChartX + 130, p3Y + 32)

    -- -------------------------------------------------------------
    -- Panel 4: Selected Generation Deep-Dive Card
    -- -------------------------------------------------------------
    local p4X, p4Y = p1X + colW + 16, contentY + panelH + 16
    drawCard(p4X, p4Y, colW, panelH, string.format("🔍 GENERATION %d TELEMETRY SUMMARY", selectedGenIdx), "Tournament Statistics & Champion Tactical Biases")

    local textY = p4Y + 60
    love.graphics.setColor(0.9, 0.95, 1.0, 1.0)
    love.graphics.print(string.format("• Maximum Elo:      %.1f (Mean: %.1f, Min: %.1f, Median: %.1f)", selM.elo_max, selM.elo_mean, selM.elo_min, selM.elo_median), p4X + 24, textY)
    textY = textY + 20
    love.graphics.print(string.format("• Best Fitness Score:  %.1f (Mean Fitness: %.1f)", selM.fitness_best, selM.fitness_mean), p4X + 24, textY)
    textY = textY + 20
    local recordLabel = METRICS_DATA.outcome_scope == "initiating_agent" and "Initiating Agents" or "Champion (legacy)"
    love.graphics.print(string.format("• %s: %dW / %dL / %dD (%d duels)", recordLabel, selM.wins, selM.losses, selM.draws, selM.total_duels), p4X + 24, textY)
    textY = textY + 20

    if selM.elo_stddev ~= nil then
        love.graphics.print(string.format("• Elo Standard Deviation: %.1f | Mean Fight: %.2fs", selM.elo_stddev, selM.match_duration_mean_seconds or 0), p4X + 24, textY)
        textY = textY + 20
    end
    if selM.match_duration_bins then
        local bins = selM.match_duration_bins
        love.graphics.print(string.format("• Duration bins (<5/10/20/30/30+s): %d / %d / %d / %d / %d", bins[1], bins[2], bins[3], bins[4], bins[5]), p4X + 24, textY)
        textY = textY + 20
    end

    -- Movement bias
    local totalMoves = (selM.movement.advance or 0) + (selM.movement.stand or 0) + (selM.movement.kite or 0)
    if totalMoves == 0 then totalMoves = 1 end
    local advPct = ((selM.movement.advance or 0) / totalMoves) * 100
    local stndPct = ((selM.movement.stand or 0) / totalMoves) * 100
    local kitePct = ((selM.movement.kite or 0) / totalMoves) * 100

    love.graphics.print(string.format("• Movement Bias:       Advance: %.1f%%  |  Stationary: %.1f%%  |  Kite: %.1f%%", advPct, stndPct, kitePct), p4X + 24, textY)
    textY = textY + 20

    -- Gauntlet objective
    if selM.has_gauntlet then
        love.graphics.setColor(0.2, 0.9, 0.4, 1.0)
        love.graphics.print(string.format("• 🎯 Gauntlet Check:   Win Rate: %.1f%%  |  Objective Elo: %.0f", selM.gauntlet_win_rate * 100, selM.gauntlet_objective_elo), p4X + 24, textY)
    else
        love.graphics.setColor(0.6, 0.7, 0.8, 1.0)
        love.graphics.print("• 🎯 Gauntlet Check:   (Not evaluated in this generation snapshot)", p4X + 24, textY)
    end
end

return graphs
