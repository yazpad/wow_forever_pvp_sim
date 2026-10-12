local ui = require("ui")
-- PVP_SIM: SPEC & META HEALTH DASHBOARD (Love2D Native Module)
local meta_health = {}
local icons = require("icons_manager")

local HEALTH_DATA = nil
local currentStatusPath = "spec_status.lua"
local selectedSpecIdx = 1
local selectedPairIdx = 1
local activeSubView = "specs" -- "specs" or "pairs"
local buttons = {}
local activeController = nil
local notice = ""
local savedClasses, scanElapsed = {}, 2
function meta_health.update(dt, controller)
    activeController = controller or activeController
    scanElapsed = scanElapsed + dt
    if scanElapsed >= 2 and activeController and activeController.getSavedClassRuns then
        savedClasses = activeController.getSavedClassRuns()
        scanElapsed = 0
    end
end
local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

-- Canonical spec talent descriptions & combat modifiers reference table
local SPEC_INFO = {
    affliction_warlock = {
        title = "Affliction Warlock",
        class = "warlock",
        talents = "30/0/21",
        tree1 = { name = "Affliction", pts = 30 },
        tree2 = { name = "Demonology", pts = 0 },
        tree3 = { name = "Destruction", pts = 21 },
        highlights = "+25% DoT Dmg, +20% Siphon Heal, Shadow Burn/Ruin",
        role = "Rot & Attrition",
    },
    soul_link_warlock = {
        title = "Soul Link Warlock",
        class = "warlock",
        talents = "20/31/0",
        tree1 = { name = "Affliction", pts = 20 },
        tree2 = { name = "Demonology", pts = 31 },
        tree3 = { name = "Destruction", pts = 0 },
        highlights = "-20% Dmg Taken (Soul Link), High Stamina / Pet Shield",
        role = "Drain-Tank / Anti-Burst",
    },
    destro_warlock = {
        title = "Destruction Warlock",
        class = "warlock",
        talents = "0/17/34",
        tree1 = { name = "Affliction", pts = 0 },
        tree2 = { name = "Demonology", pts = 17 },
        tree3 = { name = "Destruction", pts = 34 },
        highlights = "+30% Direct Spell Dmg, -15% Cast Time, Conflag Burst",
        role = "Direct Burst Artillery",
    },
    deep_frost_mage = {
        title = "Deep Frost Mage",
        class = "frost_mage",
        talents = "17/0/34",
        tree1 = { name = "Arcane", pts = 17 },
        tree2 = { name = "Fire", pts = 0 },
        tree3 = { name = "Frost", pts = 34 },
        highlights = "+30% Barrier Absorb, +15% Chilled Dmg, -10% Dmg Taken, PoM",
        role = "Shatter Burst & Root Control",
    },
    elemental_mage = {
        title = "Elemental Mage",
        class = "frost_mage",
        talents = "0/28/23",
        tree1 = { name = "Arcane", pts = 0 },
        tree2 = { name = "Fire", pts = 28 },
        tree3 = { name = "Frost", pts = 23 },
        highlights = "+25% Direct Dmg, Ignite / Pyroblast, Frost Nova Shatters",
        role = "Hybrid Burst Finisher",
    },
}

function meta_health.loadStatusFile(path)
    currentStatusPath = path or "spec_status.lua"
    local file = io.open(currentStatusPath, "r")
    if not file then
        currentStatusPath = "../" .. currentStatusPath
        file = io.open(currentStatusPath, "r")
    end
    if not file then return false end
    file:close()

    local fn, err = loadfile(currentStatusPath)
    if fn then
        HEALTH_DATA = fn()
        selectedSpecIdx = 1
        selectedPairIdx = 1
        return true
    else
        print("Error parsing spec health status: " .. tostring(err))
    end
    return false
end

function meta_health.hasData()
    return HEALTH_DATA ~= nil and HEALTH_DATA.specs ~= nil and #HEALTH_DATA.specs > 0
end

function meta_health.refresh(projectRoot)
    scanElapsed = 2
    meta_health.update(0, activeController)
    local root = projectRoot
    if not root and activeController and activeController.getProjectRoot then
        root = activeController.getProjectRoot()
    end
    root = root or "."
    local binPath = root .. "/zig-out/bin/pvp_sim"
    local outPath = root .. "/spec_status.lua"
    local cmd = "cd " .. quote(root) .. " && " .. quote(binPath)
        .. " --spec-status " .. quote(root .. "/models") .. " --spec-status-out " .. quote(outPath)
        .. " >/dev/null 2>&1"
    local ok = os.execute(cmd)
    if ok ~= true and ok ~= 0 then
        notice = "Refresh failed. Build the trainer, then retry."
        return false
    end
    local loaded = meta_health.loadStatusFile(outPath)
    notice = loaded and "Model file scan refreshed. Filenames do not verify trained talents." or "Could not load the refreshed status file."
    return loaded
end

function meta_health.keypressed(key)
    if not meta_health.hasData() then return end
    if key == "tab" then
        activeSubView = (activeSubView == "specs") and "pairs" or "specs"
    elseif key == "up" or key == "w" then
        if activeSubView == "specs" then
            selectedSpecIdx = math.max(1, selectedSpecIdx - 1)
        else
            selectedPairIdx = math.max(1, selectedPairIdx - 1)
        end
    elseif key == "down" or key == "s" then
        if activeSubView == "specs" then
            selectedSpecIdx = math.min(#HEALTH_DATA.specs, selectedSpecIdx + 1)
        else
            selectedPairIdx = math.min(#HEALTH_DATA.pairs, selectedPairIdx + 1)
        end
    elseif key == "r" then
        meta_health.refresh()
    end
end

function meta_health.mousepressed(x, y, button)
    if button ~= 1 then return end
    -- Actions are inserted before the containing row, so test them first.
    for _, b in ipairs(buttons) do
        if x >= b.x and x <= b.x + b.w and y >= b.y and y <= b.y + b.h and b.enabled then
            return b.action()
        end
    end
    return nil
end

local function drawProgressBar(x, y, w, h, pct, colFill, colBg)
    love.graphics.setColor(colBg[1], colBg[2], colBg[3], colBg[4] or 0.8)
    love.graphics.rectangle("fill", x, y, w, h, 3)
    love.graphics.setColor(colFill[1], colFill[2], colFill[3], colFill[4] or 1.0)
    love.graphics.rectangle("fill", x, y, w * math.max(0, math.min(1.0, pct)), h, 3)
    love.graphics.setColor(0.3, 0.4, 0.5, 0.6)
    love.graphics.rectangle("line", x, y, w, h, 3)
end

function meta_health.draw(trainingController)
    activeController = trainingController or activeController
    local screenW = ui.width()
    local screenH = ui.height()
    buttons = {}

    -- 1. Dark Backdrop
    love.graphics.setColor(0.02, 0.04, 0.08, 0.98)
    love.graphics.rectangle("fill", 0, 0, screenW, screenH)

    -- 2. Header
    love.graphics.setColor(0.20, 0.70, 0.95, 1.0)
    love.graphics.rectangle("fill", 24, 18, 5, 34)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.print("Talent preset model inventory", 38, 18)
    love.graphics.setColor(0.55, 0.65, 0.8, 1.0)
    love.graphics.print("Talent-spec training is not implemented. Train class opens class-kit training; presets below are reference only.", 38, 38)

    if not meta_health.hasData() then
        love.graphics.setColor(0.8, 0.8, 0.9)
        love.graphics.printf("No Spec Health status loaded.\nPress [Refresh] to scan models and audit canonical specs.", 0, screenH / 2 - 20, screenW, "center")
        local bW, bH = 160, 32
        local bx = screenW * 0.5 - bW * 0.5
        local by = screenH * 0.5 + 24
        love.graphics.setColor(0.12, 0.22, 0.35, 1.0)
        love.graphics.rectangle("fill", bx, by, bW, bH, 4)
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.printf("Refresh Status", bx, by + 8, bW, "center")
        table.insert(buttons, { x = bx, y = by, w = bW, h = bH, enabled = true, action = function() meta_health.refresh() end })
        return
    end

    local summary = HEALTH_DATA.summary or { total_specs = 5, trained_bases = 0, base_pct = 0, total_pairs = 20, trained_pairs = 0, pair_pct = 0 }

    -- 3. Top Meta Health Gauges
    local gaugeY = 70
    local gaugeW = (screenW - 48 - 20) / 2
    local gaugeH = 54

    -- Base Coverage Gauge
    love.graphics.setColor(0.08, 0.11, 0.18, 0.95)
    love.graphics.rectangle("fill", 24, gaugeY, gaugeW, gaugeH, 6)
    love.graphics.setColor(0.20, 0.30, 0.45, 0.8)
    love.graphics.rectangle("line", 24, gaugeY, gaugeW, gaugeH, 6)

    love.graphics.setColor(0.85, 0.92, 1.0, 1.0)
    love.graphics.print(string.format("Named base files: %d / %d Specs (%.1f%%)", summary.trained_bases, summary.total_specs, summary.base_pct), 38, gaugeY + 8)
    local baseCol = summary.base_pct >= 80 and {0.2, 0.85, 0.4} or (summary.base_pct >= 40 and {0.95, 0.75, 0.2} or {0.9, 0.3, 0.3})
    drawProgressBar(38, gaugeY + 30, gaugeW - 28, 12, summary.base_pct / 100, baseCol, {0.12, 0.16, 0.24, 0.9})

    -- Pairwise Coverage Gauge
    local gauge2X = 24 + gaugeW + 20
    love.graphics.setColor(0.08, 0.11, 0.18, 0.95)
    love.graphics.rectangle("fill", gauge2X, gaugeY, gaugeW, gaugeH, 6)
    love.graphics.setColor(0.20, 0.30, 0.45, 0.8)
    love.graphics.rectangle("line", gauge2X, gaugeY, gaugeW, gaugeH, 6)

    love.graphics.setColor(0.85, 0.92, 1.0, 1.0)
    love.graphics.print(string.format("Named matchup files: %d / %d Models (%.1f%%)", summary.trained_pairs, summary.total_pairs, summary.pair_pct), gauge2X + 14, gaugeY + 8)
    local pairCol = summary.pair_pct >= 80 and {0.2, 0.85, 0.4} or (summary.pair_pct >= 40 and {0.95, 0.75, 0.2} or {0.9, 0.3, 0.3})
    drawProgressBar(gauge2X + 14, gaugeY + 30, gaugeW - 28, 12, summary.pair_pct / 100, pairCol, {0.12, 0.16, 0.24, 0.9})

    -- 4. Left Column: Canonical Specs List
    local col1X = 24
    local col1Y = gaugeY + gaugeH + 14
    local col1W = math.floor(screenW * 0.48)
    local col1H = screenH - col1Y - 100

    love.graphics.setColor(0.06, 0.08, 0.14, 0.95)
    love.graphics.rectangle("fill", col1X, col1Y, col1W, col1H, 6)
    love.graphics.setColor(0.18, 0.24, 0.36, 0.8)
    love.graphics.rectangle("line", col1X, col1Y, col1W, col1H, 6)

    love.graphics.setColor(0.3, 0.75, 1.0, 1.0)
    love.graphics.print("TALENT PRESETS / NAMED MODEL FILES", col1X + 14, col1Y + 12)

    local specItemH = 58
    local specsList = HEALTH_DATA.specs or {}
    for i, s in ipairs(specsList) do
        local iy = col1Y + 38 + (i - 1) * (specItemH + 8)
        local isSel = (i == selectedSpecIdx and activeSubView == "specs")
        local bgCol = isSel and {0.16, 0.24, 0.36, 0.95} or {0.09, 0.12, 0.18, 0.9}
        love.graphics.setColor(bgCol[1], bgCol[2], bgCol[3], bgCol[4])
        love.graphics.rectangle("fill", col1X + 10, iy, col1W - 20, specItemH, 4)
        if isSel then
            love.graphics.setColor(0.4, 0.8, 1.0, 0.9)
            love.graphics.rectangle("line", col1X + 10, iy, col1W - 20, specItemH, 4)
        end

        local classIcon = (s.class == "frost_mage") and "mage" or "warlock"
        icons.drawClassIcon(classIcon, col1X + 26, iy + specItemH * 0.5, 26)

        love.graphics.setColor(0.95, 0.95, 1.0, 1.0)
        love.graphics.print(s.name, col1X + 46, iy + 6)

        local info = SPEC_INFO[s.id]
        local talentStr = s.talents or (info and info.talents or "0/0/0")
        love.graphics.setColor(0.55, 0.70, 0.90, 1.0)
        love.graphics.print(string.format("Build: %s  |  %s", talentStr, info and info.role or ""), col1X + 46, iy + 22)

        local savedClass = savedClasses[s.class]
        -- Do not present a class checkpoint as evidence of a trained talent build.
        local bx = col1X + col1W - 130
        love.graphics.setColor(savedClass and 0.15 or 0.20, savedClass and 0.50 or 0.25, 0.35, 0.9)
        love.graphics.rectangle("fill", bx, iy + 8, 100, 20, 3)
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.printf(savedClass and "CLASS SAVED" or (s.has_base and "PRESET FILE" or "NO CHECKPOINT"), bx, iy + 11, 100, "center")

        local btnW, btnH, by = 100, 18, iy + 32
        love.graphics.setColor(0.18, 0.32, 0.50, 0.95)
        love.graphics.rectangle("fill", bx, by, btnW, btnH, 3)
        love.graphics.setColor(0.85, 0.95, 1.0, 1.0)
        love.graphics.printf("Train class", bx, by + 2, btnW, "center")
        table.insert(buttons, {
            x = bx, y = by, w = btnW, h = btnH, enabled = true,
            action = function()
                if trainingController then
                    local ok, reason = trainingController.showClassTraining(s.class)
                    if ok then return "training" end
                    notice = reason
                end
            end
        })

        love.graphics.setColor(0.5, 0.75, 0.65)
        local ratingText = "Class Elo unavailable"
        if savedClass then
            ratingText = (savedClass.elo and string.format("Class Elo %.1f", savedClass.elo) or "Class Elo not recorded")
                .. string.format("  |  Gen %d  |  Talent preset untrained", savedClass.generation)
        elseif s.has_base then
            ratingText = string.format("Named file Elo %.1f  |  Talent training unverified", s.elo or 0)
        end
        love.graphics.printf(ratingText, col1X + 46, iy + 40, col1W - 186)

        table.insert(buttons, {
            x = col1X + 10, y = iy, w = col1W - 20, h = specItemH, enabled = true,
            action = function() selectedSpecIdx = i; activeSubView = "specs" end
        })
    end

    -- 5. Right Column: Pairwise Matchups List & Missing Model Training
    local col2X = col1X + col1W + 16
    local col2Y = col1Y
    local col2W = screenW - col2X - 24
    local col2H = col1H

    love.graphics.setColor(0.06, 0.08, 0.14, 0.95)
    love.graphics.rectangle("fill", col2X, col2Y, col2W, col2H, 6)
    love.graphics.setColor(0.18, 0.24, 0.36, 0.8)
    love.graphics.rectangle("line", col2X, col2Y, col2W, col2H, 6)

    love.graphics.setColor(0.95, 0.65, 0.25, 1.0)
    love.graphics.print("TALENT MATCHUPS / TRAINING NOT SUPPORTED", col2X + 14, col2Y + 12)

    local pairItemH = 34
    local pairsList = HEALTH_DATA.pairs or {}
    local maxVisiblePairs = math.floor((col2H - 50) / (pairItemH + 6))
    local startPairIdx = math.max(1, math.min(#pairsList - maxVisiblePairs + 1, selectedPairIdx - math.floor(maxVisiblePairs / 2)))

    for idx = startPairIdx, math.min(#pairsList, startPairIdx + maxVisiblePairs - 1) do
        local p = pairsList[idx]
        local rowIdx = idx - startPairIdx + 1
        local iy = col2Y + 38 + (rowIdx - 1) * (pairItemH + 6)
        local isSel = (idx == selectedPairIdx and activeSubView == "pairs")
        local bgCol = isSel and {0.16, 0.24, 0.36, 0.95} or {0.09, 0.12, 0.18, 0.9}

        love.graphics.setColor(bgCol[1], bgCol[2], bgCol[3], bgCol[4])
        love.graphics.rectangle("fill", col2X + 10, iy, col2W - 20, pairItemH, 4)
        if isSel then
            love.graphics.setColor(0.4, 0.8, 1.0, 0.9)
            love.graphics.rectangle("line", col2X + 10, iy, col2W - 20, pairItemH, 4)
        end

        local nameA = p.spec_a:gsub("_", " ")
        local nameB = p.spec_b:gsub("_", " ")

        love.graphics.setColor(0.9, 0.95, 1.0, 1.0)
        love.graphics.print(string.format("%s  vs  %s", nameA, nameB), col2X + 18, iy + 9)

        if p.has_model then
            love.graphics.setColor(0.2, 0.8, 0.35, 1.0)
            love.graphics.printf("[FILE FOUND]", col2X + col2W - 170, iy + 9, 150, "right")
        else
            love.graphics.setColor(0.7, 0.3, 0.3, 0.9)
            love.graphics.printf("No file", col2X + col2W - 230, iy + 9, 100, "right")

            love.graphics.setColor(0.55, 0.62, 0.72, 1)
            love.graphics.printf("Not supported", col2X + col2W - 125, iy + 9, 110, "center")
        end

        table.insert(buttons, {
            x = col2X + 10, y = iy, w = col2W - 20, h = pairItemH, enabled = true,
            action = function() selectedPairIdx = idx; activeSubView = "pairs" end
        })
    end

    -- 6. Bottom Controls Bar
    local bY = screenH - 80
    local refreshBtn = { x = 24, y = bY, w = 150, h = 34, label = "Refresh Status", action = function() meta_health.refresh() end }
    love.graphics.setColor(0.12, 0.22, 0.35, 1.0)
    love.graphics.rectangle("fill", refreshBtn.x, refreshBtn.y, refreshBtn.w, refreshBtn.h, 4)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.printf(refreshBtn.label, refreshBtn.x, refreshBtn.y + 8, refreshBtn.w, "center")
    table.insert(buttons, { x = refreshBtn.x, y = refreshBtn.y, w = refreshBtn.w, h = refreshBtn.h, enabled = true, action = refreshBtn.action })

    love.graphics.setColor(0.6, 0.72, 0.86, 1.0)
    love.graphics.printf(notice ~= "" and notice or "Train class > Start / Resume trains the class kit. Talent specs and talent matchups are not implemented.", 190, bY + 4, screenW - 214)
    local selected = specsList[selectedSpecIdx]
    local saved = selected and savedClasses[selected.class]
    love.graphics.setColor(0.65, 0.8, 0.72)
    local location = saved and saved.champion:match("(training_runs/.*)") or (saved and saved.champion)
    love.graphics.printf(saved and ("Saved class model: " .. location .. "  |  Resume checkpoint: population.pop")
        or "No saved class checkpoint found for the selected preset's class.", 24, bY + 42, screenW - 48)

end

return meta_health
