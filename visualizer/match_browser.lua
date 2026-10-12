local ui = require("ui")
-- PVP_SIM: MATCH REPLAY BROWSER (Love2D Native Module)
local match_browser = {}
local icons = require("icons_manager")

local allMatchesList = {}
local filteredMatchesList = {}
local selectedIdx = 1

-- Filter mode: "all" | "base" (Class Base vs Base) | "spec" (Spec vs Spec Target Pairs)
local currentFilterMode = "base"
local buttons = {}

local currentDirectory = "matches"
local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function pageSize()
    return math.max(1, math.min(12, math.floor((ui.height() - 110) / 52)))
end
local function firstVisible() return math.floor((selectedIdx - 1) / pageSize()) * pageSize() + 1 end

local function isBotOrLegacy(m)
    local n = (m.name or ""):lower()
    local na = (m.name_a or ""):lower()
    local nb = (m.name_b or ""):lower()
    return n:find("aggrorusher") or n:find("fearkiter") or n:find("turretcaster") or n:find("draintank")
        or na:find("aggrorusher") or na:find("fearkiter") or na:find("turretcaster") or na:find("draintank")
        or nb:find("aggrorusher") or nb:find("fearkiter") or nb:find("turretcaster") or nb:find("draintank")
        or n:find("legacy") or na:find("legacy") or nb:find("legacy")
end

local function isBaseMatch(m)
    local n = (m.name or ""):lower()
    if isBotOrLegacy(m) then return false end
    -- Base matches involve base models
    if n:find("base") then
        -- If it's a match between two base models, e.g. pipeline_base_warlock_vs_pipeline_base_frost_mage
        if not n:find("_vs_.*_vs_") then
            return true
        end
    end
    return false
end

local function isSpecMatch(m)
    local n = (m.name or ""):lower()
    if isBotOrLegacy(m) then return false end
    -- Target spec pairs, e.g. pipeline_warlock_vs_frost_mage vs pipeline_frost_mage_vs_warlock
    if n:find("_vs_.*_vs_") or (n:find("_vs_") and not n:find("base")) then
        return true
    end
    return false
end

local function applyFilter()
    filteredMatchesList = {}
    for _, m in ipairs(allMatchesList) do
        if not isBotOrLegacy(m) then
            if currentFilterMode == "base" and isBaseMatch(m) then
                table.insert(filteredMatchesList, m)
            elseif currentFilterMode == "spec" and isSpecMatch(m) then
                table.insert(filteredMatchesList, m)
            elseif currentFilterMode == "all" then
                table.insert(filteredMatchesList, m)
            end
        end
    end
    selectedIdx = math.max(1, math.min(selectedIdx, #filteredMatchesList))
end

function match_browser.getMatches() return filteredMatchesList end

function match_browser.setFilter(mode)
    if mode == "base" or mode == "spec" or mode == "all" then
        currentFilterMode = mode
        applyFilter()
    end
end

function match_browser.getFilter() return currentFilterMode end

function match_browser.scanMatchesDir(dirPath)
    allMatchesList = {}
    currentDirectory = dirPath or "matches"
    local candidates = {currentDirectory}
    if currentDirectory:sub(1, 1) ~= "/" then candidates[#candidates+1] = "../" .. currentDirectory end
    for _, checkPath in ipairs(candidates) do
        local handle = io.popen("find " .. quote(checkPath) .. " -maxdepth 1 -type f -name '*.lua' 2>/dev/null")
        if handle then
            for file in handle:lines() do
                local cleanName = file:match("([^/]+)%.lua$") or file
                local f = io.open(file, "r")
                if f then
                    local content = f:read(4096) or ""; f:close()
                    table.insert(allMatchesList, {
                        path = file, name = cleanName,
                        name_a = content:match('name_a%s*=%s*"([^"]+)"') or cleanName,
                        name_b = content:match('name_b%s*=%s*"([^"]+)"') or "",
                        spec_a = content:match('spec_a%s*=%s*"([^"]+)"') or "warlock",
                        spec_b = content:match('spec_b%s*=%s*"([^"]+)"') or "warlock",
                        elo_a = tonumber(content:match('elo_a%s*=%s*([%d%.]+)')) or 0,
                        elo_b = tonumber(content:match('elo_b%s*=%s*([%d%.]+)')) or 0,
                        victor = tonumber(content:match('victor%s*=%s*(%d+)')) or 0,
                    })
                end
            end
            handle:close()
        end
        if #allMatchesList > 0 then break end
    end
    table.sort(allMatchesList, function(a,b) return a.name < b.name end)
    applyFilter()
end

function match_browser.hasData()
    return #filteredMatchesList > 0
end

function match_browser.update(dt)
end

function match_browser.keypressed(key)
    if key == "tab" then
        if currentFilterMode == "base" then
            match_browser.setFilter("spec")
        elseif currentFilterMode == "spec" then
            match_browser.setFilter("all")
        else
            match_browser.setFilter("base")
        end
        return nil
    elseif key == "r" then
        match_browser.scanMatchesDir(currentDirectory)
        return nil
    end

    if #filteredMatchesList == 0 then return nil end
    if key == "up" or key == "w" then
        selectedIdx = math.max(1, selectedIdx - 1)
    elseif key == "down" or key == "s" then
        selectedIdx = math.min(#filteredMatchesList, selectedIdx + 1)
    elseif key == "return" or key == "space" then
        return filteredMatchesList[selectedIdx].path
    elseif key == "pagedown" then
        selectedIdx = math.min(#filteredMatchesList, selectedIdx + pageSize())
    elseif key == "pageup" then
        selectedIdx = math.max(1, selectedIdx - pageSize())
    end
    return nil
end

function match_browser.mousepressed(x, y, button)
    for _, btn in ipairs(buttons) do
        if x >= btn.x and x <= btn.x + btn.w and y >= btn.y and y <= btn.y + btn.h then
            return btn.action()
        end
    end

    if #filteredMatchesList == 0 then return nil end
    local listX = 36
    local listY = 88
    local itemH = 44
    local itemW = ui.width() - 72

    local first = firstVisible()
    for i = first, math.min(#filteredMatchesList, first + pageSize() - 1) do
        local cy = listY + (i - first) * (itemH + 8)
        if x >= listX and x <= listX + itemW and y >= cy and y <= cy + itemH then
            selectedIdx = i
            if button == 1 then
                return filteredMatchesList[selectedIdx].path
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
    love.graphics.rectangle("fill", 24, 18, 5, 34)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.print(currentFilterMode == "base" and "RECORDED FIGHT REPLAYS: SET 1 (CLASS BASES)" or (currentFilterMode == "spec" and "RECORDED FIGHT REPLAYS: SET 2 (SPEC VS SPEC)" or "RECORDED FIGHT REPLAYS: ALL TRAINED MATCHES"), 38, 18)
    love.graphics.setColor(0.55, 0.65, 0.8, 1.0)
    love.graphics.print(string.format("Showing %d High-Fidelity 100Hz Fight Trajectories in 'matches/' | [TAB] Switch Replay Set | [ENTER] Replay", #filteredMatchesList), 38, 38)

    -- Filter Buttons in Top Right
    local btnW, btnH = 130, 28
    local btnY = 20
    local b1X = screenW - (btnW * 3 + 44)
    local b2X = screenW - (btnW * 2 + 32)
    local b3X = screenW - (btnW + 20)

    local function drawFilterBtn(bx, label, mode)
        local isActive = (currentFilterMode == mode)
        love.graphics.setColor(isActive and 0.20 or 0.08, isActive and 0.45 or 0.14, isActive and 0.70 or 0.22, 0.95)
        love.graphics.rectangle("fill", bx, btnY, btnW, btnH, 4)
        love.graphics.setColor(isActive and 0.40 or 0.20, isActive and 0.80 or 0.30, isActive and 1.0 or 0.40, 0.9)
        love.graphics.rectangle("line", bx, btnY, btnW, btnH, 4)
        love.graphics.setColor(1, 1, 1, isActive and 1.0 or 0.6)
        love.graphics.printf(label, bx, btnY + 6, btnW, "center")
        table.insert(buttons, { x = bx, y = btnY, w = btnW, h = btnH, action = function() match_browser.setFilter(mode) end })
    end

    drawFilterBtn(b1X, "1. Base Matches", "base")
    drawFilterBtn(b2X, "2. Spec Pairs", "spec")
    drawFilterBtn(b3X, "All Matches", "all")

    if #filteredMatchesList == 0 then
        love.graphics.setColor(0.8, 0.8, 0.9)
        love.graphics.printf(string.format("No recorded replays for %s.\nRun 'Evaluate' in Training [F6] to generate trained fight recordings.", currentFilterMode == "base" and "Base Set" or "Spec vs Spec Set"), 36, 120, screenW - 72, "center")
        return
    end

    local listX = 36
    local listY = 88
    local itemH = 44
    local itemW = screenW - 72

    local first = firstVisible()
    for i = first, math.min(#filteredMatchesList, first + pageSize() - 1) do
        local m = filteredMatchesList[i]
        local cy = listY + (i - first) * (itemH + 8)
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
        icons.drawClassIcon(m.spec_a == "frost_mage" and "mage" or "warlock", listX + 18, cy + 22, 28)

        -- Clean up names
        local cleanA = m.name_a:gsub("^pipeline ", "")
        local cleanB = m.name_b:gsub("^pipeline ", "")

        love.graphics.setColor(0.95, 0.95, 1.0, 1.0)
        love.graphics.print(string.format("%d. %s", i, cleanA), listX + 40, cy + 8)

        local nameAW = love.graphics.getFont():getWidth(string.format("%d. %s", i, cleanA))
        local vsX = listX + 40 + nameAW + 8
        icons.draw("sword", vsX + 8, cy + 14, 14)

        icons.drawClassIcon(m.spec_b == "frost_mage" and "mage" or "warlock", vsX + 26, cy + 14, 14)
        love.graphics.setColor(0.95, 0.95, 1.0, 1.0)
        love.graphics.print(cleanB, vsX + 38, cy + 8)

        love.graphics.setColor(0.5, 0.65, 0.8, 1.0)
        local fileLabel = m.path:match("([^/]+)$") or m.path
        love.graphics.print(string.format("File: %s", fileLabel), listX + 40, cy + 24)

        -- Victor tag with crown icon
        local vCol = (m.victor == 0) and { 0.7, 0.4, 1.0 } or { 0.2, 0.85, 0.5 }
        icons.draw("crown", listX + itemW - 130, cy + 22, 16)
        love.graphics.setColor(vCol[1], vCol[2], vCol[3], 1.0)
        local vName = (m.victor == 0) and cleanA:sub(1, 12) or cleanB:sub(1, 12)
        love.graphics.printf(vName, listX + itemW - 110, cy + 14, 95, "left")
    end
end

return match_browser
