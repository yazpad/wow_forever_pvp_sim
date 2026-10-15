local ui = require("ui")
local icons = require("icons_manager")
local talents_data = require("talents_data")
local action_catalog = require("action_catalog")

local spec_editor = {}

local TREE_ORDER_MAP = {
    warlock = { "Affliction", "Demonology", "Destruction" },
    frost_mage = { "Arcane", "Fire", "Frost" },
    mage = { "Arcane", "Fire", "Frost" },
}

local TREE_COLORS_MAP = {
    -- Warlock trees
    Affliction = { border = { 0.60, 0.30, 0.85, 0.85 }, title = { 0.78, 0.45, 1.0, 1.0 }, bg = { 0.08, 0.05, 0.12, 0.95 } },
    Demonology = { border = { 0.45, 0.25, 0.75, 0.85 }, title = { 0.65, 0.40, 0.95, 1.0 }, bg = { 0.07, 0.05, 0.11, 0.95 } },
    Destruction = { border = { 0.85, 0.40, 0.15, 0.85 }, title = { 1.0, 0.55, 0.25, 1.0 }, bg = { 0.12, 0.06, 0.04, 0.95 } },
    -- Mage trees
    Arcane = { border = { 0.70, 0.35, 0.90, 0.85 }, title = { 0.85, 0.50, 1.0, 1.0 }, bg = { 0.08, 0.06, 0.14, 0.95 } },
    Fire = { border = { 0.90, 0.35, 0.15, 0.85 }, title = { 1.0, 0.50, 0.20, 1.0 }, bg = { 0.12, 0.05, 0.04, 0.95 } },
    Frost = { border = { 0.25, 0.65, 0.95, 0.85 }, title = { 0.45, 0.85, 1.0, 1.0 }, bg = { 0.04, 0.08, 0.15, 0.95 } },
}

-- Current state
local currentClass = "warlock" -- "warlock" | "frost_mage"
local treeData = nil
local currentBuild = nil
local specName = "Custom Build"
local specDesc = "Custom 51-point level 60 talent build."
local savedSpecs = {}
local selectedSavedIdx = 1
local actionLoadout = nil
local actionSlots = nil

-- UI Interactive Elements & Hover Tooltip
local buttons = {}
local talentNodes = {}
local actionButtons = {}
local hoveredActionSlot = nil
local actionPickerSlot = nil
local hoveredTalent = nil
local noticeText = ""
local noticeTimer = 0.0

-- Modals
local modalMode = nil -- nil | "save" | "import" | "export"
local modalInputText = ""

local ACTION_CATALOG = action_catalog.specs
local ACTION_ICONS = action_catalog.icons
local function isTalentLocked(name, build)
    local gate = action_catalog.talent_gates[name]
    return gate ~= nil and talents_data.getRank(build and build[gate.tree], gate.id) == 0
end

local ACTION_LABELS = { Agony = "Bane of Agony" }

local function defaultActionSlots(className, build)
    local catalog = ACTION_CATALOG[className] or {}
    local slots = {}
    for i = 1, 10 do slots[i] = "" end
    slots[1], slots[10] = "Idle/Maneuver", "Cancel Cast"
    local slot = 2
    for i = 2, #catalog - 1 do
        if slot > 9 then break end
        local name = catalog[i]
        local locked = className == "warlock" and isTalentLocked(name, build)
        if i < 10 then slots[slot] = locked and "" or name; slot = slot + 1 end
    end
    if className == "warlock" and slots[9] == "" and talents_data.getRank(build and build.Destruction, 105884) > 0 then
        slots[9] = "Shadowburn"
    end
    return slots
end

local function cloneActionSlots(slots, className, build, legacy)
    if type(slots) ~= "table" then
        if type(legacy) == "table" then
            local allowed, result = {}, {}
            for _, name in ipairs(legacy) do allowed[name] = true end
            local catalog = ACTION_CATALOG[className] or {}
            for i = 1, 10 do result[i] = "" end
            result[1], result[10] = "Idle/Maneuver", "Cancel Cast"
            local slot = 2
            for i = 2, #catalog - 1 do
                local name = catalog[i]
                if slot <= 9 and allowed[name] then result[slot] = name; slot = slot + 1 end
            end
            return result
        end
        return defaultActionSlots(className, build)
    end
    local result, valid = {}, {}
    for i, name in ipairs(ACTION_CATALOG[className] or {}) do if i > 1 and i < #ACTION_CATALOG[className] then valid[name] = true end end
    local catalog = ACTION_CATALOG[className] or {}
    for i = 1, 10 do
        local name = slots[i]
        local locked = className == "warlock" and isTalentLocked(name, build)
        if i == 1 or i == 10 then
            result[i] = i == 1 and "Idle/Maneuver" or "Cancel Cast"
        else
            result[i] = type(name) == "string" and (name == "" or (valid[name] and not locked and name)) or ""
        end
        if type(result[i]) ~= "string" then result[i] = "" end
    end
    return result
end

local function actionsFromSlots(slots)
    local result, seen = {}, {}
    for _, name in ipairs(slots or {}) do
        if name ~= "" and name ~= "Idle/Maneuver" and name ~= "Cancel Cast" and not seen[name] then
            result[#result + 1] = name
            seen[name] = true
        end
    end
    return result
end

local function defaultActionLoadout(className, build)
    local result = {}
    for _, name in ipairs(ACTION_CATALOG[className] or {}) do
        if name ~= "Idle/Maneuver" and name ~= "Cancel Cast" and
            not (className == "warlock" and isTalentLocked(name, build)) then
            table.insert(result, name)
        end
    end
    return result
end

local function cloneActionLoadout(actions, className, build)
    local catalog = ACTION_CATALOG[className] or {}
    if type(actions) ~= "table" then return defaultActionLoadout(className, build) end
    local result, seen = {}, {}
    for _, name in ipairs(actions) do
        if type(name) == "string" and not seen[name] then
            for _, supported in ipairs(catalog) do
                local talent_locked = className == "warlock" and isTalentLocked(name, build)
                if name == supported and not talent_locked then
                    table.insert(result, name)
                    seen[name] = true
                    break
                end
            end
        end
    end
    return result
end

function spec_editor.init()
    spec_editor.setClass(currentClass or "warlock")
    spec_editor.refreshSavedSpecs()
    -- Default to first saved spec for current class if available
    local found = false
    for _, s in ipairs(savedSpecs) do
        local sc = (s.class or "warlock"):lower()
        if sc == "mage" then sc = "frost_mage" end
        if sc == currentClass then
            spec_editor.loadSpec(s)
            found = true
            break
        end
    end
    if not found and #savedSpecs > 0 then
        spec_editor.loadSpec(savedSpecs[1])
    end
end

function spec_editor.setClass(newClass)
    local cls = (newClass or "warlock"):lower()
    if cls == "mage" then cls = "frost_mage" end
    currentClass = cls
    treeData = talents_data.load(cls)
    currentBuild = talents_data.newEmptyBuild(cls)
    actionLoadout = defaultActionLoadout(cls, currentBuild)
    actionSlots = defaultActionSlots(cls, currentBuild)
    specName = cls == "frost_mage" and "New Frost Mage Build" or "New Warlock Build"
    specDesc = "Custom 51-point level 60 talent build."
end

function spec_editor.refreshSavedSpecs()
    savedSpecs = talents_data.loadSavedSpecs("specs")
end

function spec_editor.loadSpec(specObj)
    if not specObj or not specObj.trees then return end
    local sc = (specObj.class or "warlock"):lower()
    if sc == "mage" then sc = "frost_mage" end
    if sc ~= currentClass then
        currentClass = sc
        treeData = talents_data.load(sc)
    end
    currentBuild = talents_data.cloneBuild(specObj.trees)
    actionLoadout = cloneActionLoadout(specObj.action_loadout, currentClass, currentBuild)
    actionSlots = cloneActionSlots(specObj.action_slots, currentClass, currentBuild, specObj.action_loadout)
    specName = specObj.name or "Custom Build"
    specDesc = specObj.description or ""
    noticeText = "Loaded spec: " .. specName
    noticeTimer = 2.5
end

function spec_editor.getCurrentBuild()
    return currentBuild
end

function spec_editor.getCurrentClass()
    return currentClass
end

function spec_editor.getCurrentSpecConfig()
    if not treeData or not currentBuild then return nil end
    local summary = talents_data.getSummaryString(treeData, currentBuild, currentClass)
    local hash = talents_data.exportHash(treeData, currentBuild, currentClass)
    return {
        name = specName,
        class = currentClass,
        level = 60,
        description = specDesc,
        talents_summary = summary,
        hash = hash,
        trees = talents_data.cloneBuild(currentBuild),
        action_loadout = actionsFromSlots(cloneActionSlots(actionSlots, currentClass, currentBuild)),
        action_slots = cloneActionSlots(actionSlots, currentClass, currentBuild),
    }
end

function spec_editor.update(dt)
    if noticeTimer > 0 then
        noticeTimer = noticeTimer - dt
        if noticeTimer <= 0 then
            noticeText = ""
        end
    end
end

function spec_editor.keypressed(key)
    if modalMode then
        if key == "escape" then
            modalMode = nil
            modalInputText = ""
            return true
        elseif key == "backspace" then
            modalInputText = modalInputText:sub(1, -2)
            return true
        elseif key == "return" or key == "kpenter" then
            if modalMode == "save" then
                if #modalInputText > 0 then
                    specName = modalInputText
                    local specConfig = spec_editor.getCurrentSpecConfig()
                    local fname = modalInputText:lower():gsub("%s+", "_"):gsub("[^%w_%-]", "")
                    local ok, pathOrErr = talents_data.saveSpec(specConfig, fname, "specs")
                    if ok then
                        noticeText = "Spec saved successfully: " .. fname .. ".json"
                        spec_editor.refreshSavedSpecs()
                    else
                        noticeText = "Save error: " .. tostring(pathOrErr)
                    end
                end
                modalMode = nil
            elseif modalMode == "import" then
                if #modalInputText > 0 then
                    local imported, err = talents_data.importHash(treeData, modalInputText, currentClass)
                    if imported then
                        currentBuild = imported
                        specName = "Imported Build"
                        noticeText = "Build imported successfully (" .. talents_data.getSummaryString(treeData, currentBuild, currentClass) .. ")"
                    else
                        noticeText = "Import error: " .. tostring(err)
                    end
                end
                modalMode = nil
            elseif modalMode == "export" then
                modalMode = nil
            end
            return true
        end
        return true
    end

    if key == "c" and love.keyboard.isDown("lctrl", "rctrl") then
        local hash = talents_data.exportHash(treeData, currentBuild, currentClass)
        if love.system and love.system.setClipboardText then
            love.system.setClipboardText(hash)
            noticeText = "Export hash copied to clipboard!"
            noticeTimer = 2.5
        end
        return true
    end

    return false
end

function spec_editor.textinput(text)
    if modalMode then
        modalInputText = modalInputText .. text
    end
end

function spec_editor.mousepressed(x, y, button)
    if not treeData then return false end

    -- Modal clicks take precedence
    if modalMode then
        -- Cancel or Close click outside
        return true
    end

    -- Check action buttons
    for _, btn in ipairs(actionButtons) do
        if x >= btn.x and x <= btn.x + btn.w and y >= btn.y and y <= btn.y + btn.h then
            if button == 1 then
                if btn.kind == "option" then
                    actionSlots[btn.slot] = btn.name == "(Empty)" and "" or btn.name
                    actionPickerSlot = nil
                elseif btn.kind == "slot" then
                    if btn.slot > 1 and btn.slot < 10 then
                        actionPickerSlot = actionPickerSlot == btn.slot and nil or btn.slot
                    end
                end
            end
            return true
        end
    end

    for _, btn in ipairs(buttons) do
        if x >= btn.x and x <= btn.x + btn.w and y >= btn.y and y <= btn.y + btn.h then
            if btn.action then btn.action(button) end
            return true
        end
    end

    -- Check talent node clicks
    for _, node in ipairs(talentNodes) do
        if x >= node.x and x <= node.x + node.w and y >= node.y and y <= node.y + node.h then
            local talent = node.talent
            local treeName = node.treeName
            if button == 1 then
                -- Invest 1 point
                local can, reason = talents_data.canInvest(treeData, currentBuild, treeName, talent)
                if can then
                    local cur = talents_data.getRank(currentBuild[treeName], talent.id)
                    currentBuild[treeName][tostring(talent.id)] = cur + 1
                    noticeText = ""
                else
                    noticeText = reason or "Cannot invest point"
                    noticeTimer = 2.0
                end
            elseif button == 2 then
                -- Uninvest 1 point
                local can, reason = talents_data.canUninvest(treeData, currentBuild, treeName, talent)
                if can then
                    local cur = talents_data.getRank(currentBuild[treeName], talent.id)
                    if cur - 1 <= 0 then
                        currentBuild[treeName][tostring(talent.id)] = nil
                    else
                        currentBuild[treeName][tostring(talent.id)] = cur - 1
                    end
                    noticeText = ""
                else
                    noticeText = reason or "Cannot remove point"
                    noticeTimer = 2.0
                end
            end
            return true
        end
    end

    return false
end

-- Helper to draw an arrow or connecting line between parent and child talent
local function drawPrereqArrow(pNode, cNode)
    local g = love.graphics
    local px = pNode.x + pNode.w * 0.5
    local py = pNode.y + pNode.h
    local cx = cNode.x + cNode.w * 0.5
    local cy = cNode.y

    g.setColor(0.85, 0.70, 0.20, 0.65)
    g.setLineWidth(2)
    g.line(px, py, cx, cy)

    -- Arrowhead at child node
    local ahSize = 5
    g.polygon("fill", cx, cy, cx - ahSize, cy - ahSize, cx + ahSize, cy - ahSize)
end

function spec_editor.draw(trainingController)
    if not treeData then
        spec_editor.init()
    end
    if not treeData then
        love.graphics.setColor(1, 0.4, 0.4, 1)
        love.graphics.printf("Failed to load talents metadata.", 0, ui.height() * 0.5, ui.width(), "center")
        return
    end

    local g = love.graphics
    local screenW = ui.width()
    local screenH = ui.height()
    buttons = {}
    actionButtons = {}
    talentNodes = {}
    hoveredTalent = nil

    local mx, my = love.mouse.getPosition()
    mx, my = ui.contentPoint(mx, my)

    -- 1. Dark Backdrop
    g.setColor(0.04, 0.06, 0.10, 1.0)
    g.rectangle("fill", 0, 0, screenW, screenH)

    -- 2. Header
    local isMage = (currentClass == "frost_mage")
    local classIconName = isMage and "mage" or "warlock"
    local classDisplayName = isMage and "Frost Mage" or "Warlock"
    local classSubtitle = isMage and "Mage 51-Point Talent Tree Calculator" or "Warlock 51-Point Talent Tree Calculator"
    local classAccent = isMage and { 0.35, 0.75, 1.0, 0.9 } or { 0.65, 0.50, 0.90, 0.9 }

    icons.drawClassIcon(classIconName, 38, 33, 30)
    ui.setFont("header")
    g.setColor(0.96, 0.98, 1.0, 1.0)
    g.print("SPEC & TALENT BUILDER", 60, 12)
    ui.setFont("small")
    g.setColor(classAccent[1], classAccent[2], classAccent[3], classAccent[4])
    g.print(classSubtitle, 60, 36)
    ui.resetFont()

    local totalPts, treePts = talents_data.getTotalPoints(treeData, currentBuild, currentClass)
    local ptsRemaining = 51 - totalPts

    -- Header summary & point counters
    local treeOrder = TREE_ORDER_MAP[currentClass] or TREE_ORDER_MAP.warlock
    local c1 = treePts[treeOrder[1]] or 0
    local c2 = treePts[treeOrder[2]] or 0
    local c3 = treePts[treeOrder[3]] or 0
    local summaryStr = string.format("%d / %d / %d", c1, c2, c3)

    ui.setFont("small")
    g.setColor(0.55, 0.65, 0.8, 1.0)
    local summaryLabel = string.format("Build: %s  |  Talents: %s  |  Points: ", specName, summaryStr)
    g.print(summaryLabel, 360, 36)

    local remX = 360 + g.getFont():getWidth(summaryLabel)
    if ptsRemaining == 0 then
        g.setColor(0.2, 0.9, 0.4, 1.0)
    elseif ptsRemaining < 10 then
        g.setColor(0.95, 0.75, 0.2, 1.0)
    else
        g.setColor(0.3, 0.8, 1.0, 1.0)
    end
    g.print(string.format("%d / 51 Remaining", ptsRemaining), remX, 36)
    ui.resetFont()

    -- Top Toolbar Buttons (Reset All, Save, Export, Import, Fight Spec)
    local tbX = screenW - 560
    local tbY = 18
    local btnW = 86
    local btnH = 26
    local gap = 6

    local function drawToolBtn(label, bx, action, col)
        col = col or { 0.12, 0.20, 0.32, 0.95 }
        local isHov = (mx >= bx and mx <= bx + btnW and my >= tbY and my <= tbY + btnH)
        g.setColor(isHov and col[1] * 1.4 or col[1], isHov and col[2] * 1.4 or col[2], isHov and col[3] * 1.4 or col[3], col[4])
        g.rectangle("fill", bx, tbY, btnW, btnH, 4)
        g.setColor(0.35, 0.60, 0.85, 0.8)
        g.rectangle("line", bx, tbY, btnW, btnH, 4)
        g.setColor(1, 1, 1, isHov and 1.0 or 0.85)
        g.printf(label, bx, tbY + 5, btnW, "center")
        table.insert(buttons, { x = bx, y = tbY, w = btnW, h = btnH, action = action })
    end

    drawToolBtn("Reset All", tbX, function()
        currentBuild = talents_data.newEmptyBuild(currentClass)
        actionLoadout = defaultActionLoadout(currentClass, currentBuild)
        noticeText = "Reset all talents to 0."
        noticeTimer = 2.0
    end, { 0.35, 0.12, 0.12, 0.95 })

    drawToolBtn("Save Spec", tbX + (btnW + gap) * 1, function()
        modalMode = "save"
        modalInputText = specName
    end, { 0.12, 0.38, 0.22, 0.95 })

    drawToolBtn("Export Hash", tbX + (btnW + gap) * 2, function()
        modalMode = "export"
        modalInputText = talents_data.exportHash(treeData, currentBuild, currentClass)
        if love.system and love.system.setClipboardText then
            love.system.setClipboardText(modalInputText)
        end
    end)

    drawToolBtn("Import", tbX + (btnW + gap) * 3, function()
        modalMode = "import"
        modalInputText = ""
    end)

    drawToolBtn("Fight Spec", tbX + (btnW + gap) * 4, function()
        local match_generator = require("match_generator")
        local cfg = match_generator.getConfig()
        local specConfig = spec_editor.getCurrentSpecConfig()
        local fname = specName:lower():gsub("%s+", "_"):gsub("[^%w_%-]", "")
        if #fname == 0 then fname = "custom_spec" end
        -- Ensure spec JSON exists on disk so mcts_fight can read talents_summary
        talents_data.saveSpec(specConfig, fname, "specs")
        specConfig.filename = fname
        specConfig.filepath = "specs/" .. fname .. ".json"

        cfg.spec_a = currentClass
        cfg.spec_a_obj = specConfig
        cfg.ctrl_a = "search"
        cfg.output = "matches/fight_" .. fname .. ".lua"
        local ok, err = match_generator.startFight(cfg)
        if ok then
            noticeText = "Fight simulation started with " .. specName .. "!"
            noticeTimer = 3.0
        else
            noticeText = "Fight error: " .. tostring(err)
            noticeTimer = 3.0
        end
    end, { 0.20, 0.50, 0.30, 0.95 })

    -- 3. Main Layout: Left Sidebar (Saved Specs Browser) + Right (3 Talent Trees)
    local sidebarW = 270
    local sidebarX = 24
    local mainY = 66
    local mainH = screenH - mainY - 30
    local actionPanelH = 132

    -- Left Sidebar Container
    g.setColor(0.06, 0.08, 0.14, 0.95)
    g.rectangle("fill", sidebarX, mainY, sidebarW, mainH, 6)
    g.setColor(0.18, 0.25, 0.38, 0.8)
    g.rectangle("line", sidebarX, mainY, sidebarW, mainH, 6)

    -- Class Selector Tabs at Top of Sidebar
    local tabW = math.floor((sidebarW - 20) / 2)
    local tabH = 26
    local tabY = mainY + 10

    -- Warlock Tab
    local isWarlockTab = (currentClass == "warlock")
    local wHov = (mx >= sidebarX + 10 and mx <= sidebarX + 10 + tabW and my >= tabY and my <= tabY + tabH)
    if isWarlockTab then
        g.setColor(0.20, 0.14, 0.32, 0.95)
    elseif wHov then
        g.setColor(0.14, 0.10, 0.22, 0.85)
    else
        g.setColor(0.08, 0.07, 0.12, 0.70)
    end
    g.rectangle("fill", sidebarX + 10, tabY, tabW, tabH, 4)
    g.setColor(isWarlockTab and 0.75 or 0.35, isWarlockTab and 0.45 or 0.25, isWarlockTab and 1.0 or 0.5, isWarlockTab and 0.95 or 0.6)
    g.rectangle("line", sidebarX + 10, tabY, tabW, tabH, 4)
    icons.drawClassIcon("warlock", sidebarX + 22, tabY + tabH * 0.5, 16)
    ui.setFont("small")
    g.setColor(isWarlockTab and 1.0 or 0.75, isWarlockTab and 1.0 or 0.75, 1.0, 1.0)
    g.printf("Warlock", sidebarX + 32, tabY + 6, tabW - 32, "center")
    ui.resetFont()

    table.insert(buttons, {
        x = sidebarX + 10, y = tabY, w = tabW, h = tabH,
        action = function()
            if currentClass ~= "warlock" then
                spec_editor.setClass("warlock")
                -- Pick first warlock spec
                for _, s in ipairs(savedSpecs) do
                    local sc = (s.class or "warlock"):lower()
                    if sc == "warlock" then
                        spec_editor.loadSpec(s)
                        break
                    end
                end
            end
        end
    })

    -- Frost Mage Tab
    local isMageTab = (currentClass == "frost_mage")
    local mX = sidebarX + 10 + tabW + 2
    local mHov = (mx >= mX and mx <= mX + tabW and my >= tabY and my <= tabY + tabH)
    if isMageTab then
        g.setColor(0.12, 0.24, 0.38, 0.95)
    elseif mHov then
        g.setColor(0.09, 0.16, 0.26, 0.85)
    else
        g.setColor(0.06, 0.09, 0.14, 0.70)
    end
    g.rectangle("fill", mX, tabY, tabW, tabH, 4)
    g.setColor(isMageTab and 0.35 or 0.20, isMageTab and 0.80 or 0.45, isMageTab and 1.0 or 0.65, isMageTab and 0.95 or 0.6)
    g.rectangle("line", mX, tabY, tabW, tabH, 4)
    icons.drawClassIcon("mage", mX + 12, tabY + tabH * 0.5, 16)
    ui.setFont("small")
    g.setColor(isMageTab and 1.0 or 0.75, isMageTab and 1.0 or 0.75, 1.0, 1.0)
    g.printf("Mage", mX + 22, tabY + 6, tabW - 22, "center")
    ui.resetFont()

    table.insert(buttons, {
        x = mX, y = tabY, w = tabW, h = tabH,
        action = function()
            if currentClass ~= "frost_mage" then
                spec_editor.setClass("frost_mage")
                -- Pick first mage spec
                for _, s in ipairs(savedSpecs) do
                    local sc = (s.class or "warlock"):lower()
                    if sc == "frost_mage" or sc == "mage" then
                        spec_editor.loadSpec(s)
                        break
                    end
                end
            end
        end
    })

    -- Filter saved specs for active class
    local classSavedSpecs = {}
    for _, s in ipairs(savedSpecs) do
        local sc = (s.class or "warlock"):lower()
        if sc == "mage" then sc = "frost_mage" end
        if sc == currentClass then
            table.insert(classSavedSpecs, s)
        end
    end

    local specListY = mainY + 44
    local specItemH = 50
    for idx, s in ipairs(classSavedSpecs) do
        local iy = specListY + (idx - 1) * (specItemH + 8)
        if iy + specItemH <= mainY + mainH - 50 then
            local isSel = (s.name == specName)
            local isHov = (mx >= sidebarX + 10 and mx <= sidebarX + sidebarW - 10 and my >= iy and my <= iy + specItemH)

            g.setColor(isSel and 0.16 or (isHov and 0.12 or 0.08), isSel and 0.26 or (isHov and 0.18 or 0.12), isSel and 0.40 or (isHov and 0.28 or 0.18), 0.95)
            g.rectangle("fill", sidebarX + 10, iy, sidebarW - 20, specItemH, 4)

            g.setColor(isSel and 0.4 or 0.2, isSel and 0.8 or 0.4, isSel and 1.0 or 0.6, 0.8)
            g.rectangle("line", sidebarX + 10, iy, sidebarW - 20, specItemH, 4)

            -- Spec Name
            g.setColor(1, 1, 1, 1)
            g.print(s.name, sidebarX + 18, iy + 8)

            -- Badge: e.g. 17/0/34
            g.setColor(0.85, 0.75, 0.35, 1.0)
            local badge = s.talents_summary or "0/0/0"
            g.print(badge, sidebarX + 18, iy + 26)

            -- Delete button (little [x])
            local delW, delH = 20, 20
            local delX = sidebarX + sidebarW - 38
            local delY = iy + 14
            local delHov = (mx >= delX and mx <= delX + delW and my >= delY and my <= delY + delH)
            g.setColor(delHov and 0.7 or 0.35, delHov and 0.2 or 0.15, delHov and 0.2 or 0.15, 0.9)
            g.rectangle("fill", delX, delY, delW, delH, 3)
            g.setColor(1, 1, 1, delHov and 1 or 0.6)
            g.printf("x", delX, delY + 2, delW, "center")

            -- Click on item loads spec
            table.insert(buttons, {
                x = sidebarX + 10, y = iy, w = sidebarW - 20 - 28, h = specItemH,
                action = function() spec_editor.loadSpec(s) end
            })

            -- Click on delete removes it
            table.insert(buttons, {
                x = delX, y = delY, w = delW, h = delH,
                action = function()
                    if s.filepath then
                        talents_data.deleteSpec(s.filepath)
                        noticeText = "Deleted spec: " .. s.name
                        noticeTimer = 2.0
                        spec_editor.refreshSavedSpecs()
                    end
                end
            })
        end
    end

    -- "+ New Spec" at bottom of sidebar
    local newSpecY = mainY + mainH - 42
    local newBtnW = sidebarW - 20
    local newBtnH = 30
    local newHov = (mx >= sidebarX + 10 and mx <= sidebarX + 10 + newBtnW and my >= newSpecY and my <= newSpecY + newBtnH)
    g.setColor(newHov and 0.18 or 0.10, newHov and 0.40 or 0.25, newHov and 0.25 or 0.15, 0.95)
    g.rectangle("fill", sidebarX + 10, newSpecY, newBtnW, newBtnH, 4)
    g.setColor(0.3, 0.8, 0.5, 0.8)
    g.rectangle("line", sidebarX + 10, newSpecY, newBtnW, newBtnH, 4)
    g.setColor(1, 1, 1, 1)
    g.printf(string.format("+ New %s Spec", classDisplayName), sidebarX + 10, newSpecY + 7, newBtnW, "center")
    table.insert(buttons, {
        x = sidebarX + 10, y = newSpecY, w = newBtnW, h = newBtnH,
        action = function()
            currentBuild = talents_data.newEmptyBuild(currentClass)
            actionLoadout = defaultActionLoadout(currentClass, currentBuild)
            specName = "New " .. classDisplayName .. " Spec"
            specDesc = "Custom talent distribution."
            noticeText = "Started new blank spec."
            noticeTimer = 2.0
        end
    })

    -- 4. Multi-Tree Grid Layout (3 Trees Side-by-Side)
    local treesAreaX = sidebarX + sidebarW + 18
    local treesAreaW = screenW - treesAreaX - 24
    local treeColW = math.floor((treesAreaW - 24) / 3)

    local nodeSize = 42
    local nodeGapX = 14
    local nodeGapY = 16
    local gridPadX = math.floor((treeColW - (4 * nodeSize + 3 * nodeGapX)) / 2)
    local gridPadY = 56

    -- Lookup table for drawing arrows between prerequisite and child talents
    local renderedNodesById = {}

    for tIdx, treeName in ipairs(treeOrder) do
        local tree = treeData[treeName]
        if tree then
            local tColX = treesAreaX + (tIdx - 1) * (treeColW + 12)
            local theme = TREE_COLORS_MAP[treeName] or { border = { 0.4, 0.4, 0.6, 0.8 }, title = { 0.8, 0.8, 1.0, 1.0 }, bg = { 0.08, 0.09, 0.14, 0.95 } }

            -- Tree Background & Border
            g.setColor(theme.bg[1], theme.bg[2], theme.bg[3], theme.bg[4])
            g.rectangle("fill", tColX, mainY, treeColW, mainH - actionPanelH - 10, 6)
            g.setColor(theme.border[1], theme.border[2], theme.border[3], theme.border[4])
            g.rectangle("line", tColX, mainY, treeColW, mainH - actionPanelH - 10, 6)

            -- Tree Header
            local treeInvested = treePts[treeName] or 0
            g.setColor(theme.title[1], theme.title[2], theme.title[3], 1.0)
            g.print(string.format("%s (%d)", treeName:upper(), treeInvested), tColX + 16, mainY + 12)

            -- Reset this single tree button
            local rstW, rstH = 46, 20
            local rstX = tColX + treeColW - rstW - 14
            local rstY = mainY + 10
            local rstHov = (mx >= rstX and mx <= rstX + rstW and my >= rstY and my <= rstY + rstH)
            g.setColor(rstHov and 0.4 or 0.2, 0.1, 0.1, 0.85)
            g.rectangle("fill", rstX, rstY, rstW, rstH, 3)
            g.setColor(0.6, 0.3, 0.3, 0.7)
            g.rectangle("line", rstX, rstY, rstW, rstH, 3)
            g.setColor(1, 1, 1, rstHov and 1 or 0.7)
            g.printf("Reset", rstX, rstY + 3, rstW, "center")
            table.insert(buttons, {
                x = rstX, y = rstY, w = rstW, h = rstH,
                action = function()
                    currentBuild[treeName] = {}
                    noticeText = "Reset " .. treeName .. " tree."
                    noticeTimer = 2.0
                end
            })

            -- Grid Rows & Talents
            for _, tal in ipairs(tree.talents) do
                local nx = tColX + gridPadX + tal.col * (nodeSize + nodeGapX)
                local ny = mainY + gridPadY + tal.row * (nodeSize + nodeGapY)
                local rank = talents_data.getRank(currentBuild[treeName], tal.id)

                local nodeInfo = {
                    x = nx, y = ny, w = nodeSize, h = nodeSize,
                    talent = tal, treeName = treeName, rank = rank,
                }
                table.insert(talentNodes, nodeInfo)
                renderedNodesById[tal.id] = nodeInfo

                local isHov = (mx >= nx and mx <= nx + nodeSize and my >= ny and my <= ny + nodeSize)
                if isHov then
                    hoveredTalent = nodeInfo
                end

                -- Determine node state (active / maxed / locked / available)
                local isMaxed = (rank >= tal.max_ranks)
                local hasPoints = (rank > 0)
                local canInvest, _ = talents_data.canInvest(treeData, currentBuild, treeName, tal)
                local isLocked = (not canInvest and not hasPoints)

                -- Node Background
                if isMaxed then
                    g.setColor(0.25, 0.20, 0.05, 0.95)
                elseif hasPoints then
                    g.setColor(0.12, 0.22, 0.12, 0.95)
                elseif canInvest then
                    g.setColor(0.10, 0.14, 0.22, 0.95)
                else
                    g.setColor(0.05, 0.06, 0.08, 0.95)
                end
                g.rectangle("fill", nx, ny, nodeSize, nodeSize, 4)

                -- Node Border
                if isMaxed then
                    g.setColor(0.95, 0.85, 0.25, 1.0)
                elseif hasPoints then
                    g.setColor(0.3, 0.9, 0.4, 0.95)
                elseif canInvest then
                    g.setColor(0.35, 0.65, 0.95, 0.8)
                else
                    g.setColor(0.20, 0.22, 0.26, 0.6)
                end
                g.setLineWidth(isHov and 2 or 1)
                g.rectangle("line", nx, ny, nodeSize, nodeSize, 4)

                -- Node Icon / Graphic
                -- If an icon file is registered with icons_manager, draw it; otherwise draw stylized initials
                local iconDrawn = false
                if tal.icon and icons.get(tal.icon) then
                    local a = isLocked and 0.35 or 1.0
                    iconDrawn = icons.drawRect(tal.icon, nx + 2, ny + 2, nodeSize - 4, nodeSize - 4, 1, 1, 1, a)
                end
                if not iconDrawn then
                    -- Extract initials (e.g. "Shadow Bolt" -> "SB")
                    local initials = ""
                    for word in tal.name:gmatch("%S+") do
                        initials = initials .. word:sub(1, 1)
                        if #initials >= 2 then break end
                    end
                    g.setColor(1, 1, 1, isLocked and 0.30 or (hasPoints and 1.0 or 0.75))
                    g.printf(initials, nx, ny + 8, nodeSize, "center")
                end

                -- Rank Badge in bottom-right corner of node
                local badgeW = 20
                local badgeH = 14
                local bx = nx + nodeSize - badgeW + 3
                local by = ny + nodeSize - badgeH + 3
                g.setColor(0.02, 0.04, 0.06, 0.9)
                g.rectangle("fill", bx, by, badgeW, badgeH, 2)
                if isMaxed then
                    g.setColor(0.95, 0.85, 0.25, 1.0)
                elseif hasPoints then
                    g.setColor(0.3, 0.9, 0.4, 1.0)
                else
                    g.setColor(0.5, 0.55, 0.65, 0.8)
                end
                g.printf(string.format("%d/%d", rank, tal.max_ranks), bx, by + 1, badgeW, "center")
            end
        end
    end

    -- Ten ordered action slots are saved with the spec.
    local panelY = mainY + mainH - actionPanelH
    g.setColor(0.06, 0.08, 0.14, 0.98)
    g.rectangle("fill", treesAreaX, panelY, treesAreaW, actionPanelH, 6)
    g.setColor(0.22, 0.32, 0.48, 0.85)
    g.rectangle("line", treesAreaX, panelY, treesAreaW, actionPanelH, 6)
    ui.setFont("small")
    g.setColor(0.75, 0.84, 1.0, 1.0)
    g.print("TRACKED ACTION SLOTS (hover to inspect, click to change)", treesAreaX + 14, panelY + 8)
    local slotSize, gap, cols = 36, 9, 10
    local totalW = cols * slotSize + (cols - 1) * gap
    local startX = treesAreaX + math.max(14, (treesAreaW - totalW) * 0.5)
    local slotY = panelY + 34
    for i = 1, 10 do
        local sx = startX + (i - 1) * (slotSize + gap)
        local name = actionSlots and actionSlots[i] or ""
        local isHover = mx >= sx and mx <= sx + slotSize and my >= slotY and my <= slotY + slotSize
        if isHover then hoveredActionSlot = i end
        local reserved = i == 1 or i == 10
        g.setColor(reserved and 0.10 or (isHover and 0.24 or 0.10), reserved and 0.11 or (isHover and 0.35 or 0.14), reserved and 0.13 or (isHover and 0.50 or 0.22), 1)
        g.rectangle("fill", sx, slotY, slotSize, slotSize, 4)
        g.setColor(reserved and 0.24 or (isHover and 0.45 or 0.27), reserved and 0.26 or (isHover and 0.72 or 0.38), reserved and 0.30 or (isHover and 1 or 0.58), 1)
        g.rectangle("line", sx, slotY, slotSize, slotSize, 4)
        if name ~= "" then
            local icon = ACTION_ICONS[name]
            local tint = reserved and 0.38 or 1
            local drawn = icon and icons.get(icon) and icons.drawRect(icon, sx + 3, slotY + 3, slotSize - 6, slotSize - 6, tint, tint, tint, 1)
            if not drawn then
                local initials = name:gsub("[^%w]", ""):sub(1, 2):upper()
                g.setColor(reserved and 0.4 or 1, reserved and 0.4 or 1, reserved and 0.4 or 1, 0.95)
                g.printf(initials, sx, slotY + 11, slotSize, "center")
            end
        else
            g.setColor(0.52, 0.58, 0.68, 1)
            g.printf("+", sx, slotY + 8, slotSize, "center")
        end
        g.setColor(0.76, 0.82, 0.92, 0.9)
        g.printf(tostring(i), sx, slotY + slotSize + 2, slotSize, "center")
        table.insert(actionButtons, { x = sx, y = slotY, w = slotSize, h = slotSize, kind = "slot", slot = i })
        if isHover then
            local displayName = ACTION_LABELS[name] or name
            local label = reserved and (displayName .. " (reserved)") or (name ~= "" and displayName or "Empty slot")
            local tipW = math.max(110, #label * 7 + 18)
            local tipX = math.min(screenW - tipW - 8, math.max(8, sx + slotSize * 0.5 - tipW * 0.5))
            local tipY = slotY - 25
            g.setColor(0.035, 0.05, 0.085, 0.97)
            g.rectangle("fill", tipX, tipY, tipW, 21, 3)
            g.setColor(0.4, 0.55, 0.75, 1)
            g.rectangle("line", tipX, tipY, tipW, 21, 3)
            g.setColor(reserved and 0.62 or 0.94, reserved and 0.65 or 0.96, reserved and 0.72 or 1, 1)
            g.printf(label, tipX + 4, tipY + 3, tipW - 8, "center")
        end
    end
    hoveredActionSlot = hoveredActionSlot or actionPickerSlot
    if actionPickerSlot then
        local menuW, rowH = 154, 19
        local menuH = (#ACTION_CATALOG[currentClass] + 1) * rowH
        local anchorX = startX + (actionPickerSlot - 1) * (slotSize + gap)
        local menuX = math.min(screenW - menuW - 8, anchorX)
        local menuY = math.min(screenH - menuH - 8, slotY + slotSize + 7)
        g.setColor(0.035, 0.05, 0.085, 0.98)
        g.rectangle("fill", menuX, menuY, menuW, menuH, 4)
        g.setColor(0.34, 0.48, 0.68, 1)
        g.rectangle("line", menuX, menuY, menuW, menuH, 4)
        local options = { "(Empty)" }
        for i, name in ipairs(ACTION_CATALOG[currentClass]) do if i > 1 and i < #ACTION_CATALOG[currentClass] then options[#options + 1] = name end end
        for i, name in ipairs(options) do
            local oy = menuY + (i - 1) * rowH
            local locked = currentClass == "warlock" and isTalentLocked(name, currentBuild)
            if locked then g.setColor(0.18, 0.19, 0.22, 0.95)
            elseif (name == "(Empty)" and actionSlots[actionPickerSlot] == "") or name == actionSlots[actionPickerSlot] then g.setColor(0.28, 0.55, 0.82, 0.95)
            else g.setColor(0.12, 0.16, 0.23, 0.95) end
            g.rectangle("fill", menuX + 1, oy + 1, menuW - 2, rowH - 1)
            g.setColor(locked and 0.48 or 0.9, locked and 0.5 or 0.93, locked and 0.56 or 1, 1)
            g.print(locked and ((ACTION_LABELS[name] or name) .. " (locked)") or (ACTION_LABELS[name] or name), menuX + 8, oy + 2)
            if not locked then table.insert(actionButtons, { x = menuX, y = oy, w = menuW, h = rowH, kind = "option", slot = actionPickerSlot, name = name }) end
        end
    end
    g.setColor(0.85, 0.68, 0.42, 1.0)
    g.print("Movement is controlled separately.", treesAreaX + 14, panelY + actionPanelH - 19)
    ui.resetFont()

    -- Draw Prerequisite Arrows connecting talents
    for _, node in ipairs(talentNodes) do
        local tal = node.talent
        if tal.requires and #tal.requires > 0 then
            for _, req in ipairs(tal.requires) do
                local parentNode = renderedNodesById[req.id]
                if parentNode then
                    drawPrereqArrow(parentNode, node)
                end
            end
        end
    end

    -- 5. Notice / Alert Message Overlay at bottom
    if #noticeText > 0 then
        local notW = 480
        local notH = 26
        local notX = math.floor((screenW - notW) * 0.5)
        local notY = screenH - 46
        g.setColor(0.05, 0.12, 0.20, 0.95)
        g.rectangle("fill", notX, notY, notW, notH, 4)
        g.setColor(0.3, 0.8, 1.0, 0.9)
        g.rectangle("line", notX, notY, notW, notH, 4)
        g.setColor(1, 1, 1, 1)
        g.printf(noticeText, notX, notY + 5, notW, "center")
    end

    -- 6. Hover Tooltip
    if hoveredTalent then
        local tal = hoveredTalent.talent
        local treeName = hoveredTalent.treeName
        local rank = hoveredTalent.rank
        local canInvest, lockReason = talents_data.canInvest(treeData, currentBuild, treeName, tal)

        local ttW = 280
        local ttH = 150
        local ttX = math.min(screenW - ttW - 16, mx + 16)
        local ttY = math.min(screenH - ttH - 16, my + 16)

        g.setColor(0.05, 0.07, 0.11, 0.96)
        g.rectangle("fill", ttX, ttY, ttW, ttH, 6)
        g.setColor(0.3, 0.5, 0.8, 0.85)
        g.rectangle("line", ttX, ttY, ttW, ttH, 6)

        -- Title & Tree Name
        g.setColor(1, 1, 1, 1)
        g.print(tal.name, ttX + 12, ttY + 10)
        g.setColor(0.85, 0.75, 0.35, 1.0)
        g.printf(string.format("Rank %d / %d", rank, tal.max_ranks), ttX + 12, ttY + 10, ttW - 24, "right")

        g.setColor(0.65, 0.45, 0.95, 1.0)
        g.print(treeName, ttX + 12, ttY + 28)

        local curDescY = ttY + 48

        -- Current rank description if rank > 0
        if rank > 0 and tal.descriptions and tal.descriptions[tostring(rank)] then
            g.setColor(0.9, 0.9, 0.9, 1.0)
            g.printf(tal.descriptions[tostring(rank)], ttX + 12, curDescY, ttW - 24, "left")
            curDescY = curDescY + 38
        end

        -- Next rank description if rank < max
        if rank < tal.max_ranks and tal.descriptions and tal.descriptions[tostring(rank + 1)] then
            g.setColor(0.5, 0.8, 1.0, 1.0)
            g.print("Next rank:", ttX + 12, curDescY)
            curDescY = curDescY + 16
            g.setColor(0.8, 0.8, 0.85, 0.9)
            g.printf(tal.descriptions[tostring(rank + 1)], ttX + 12, curDescY, ttW - 24, "left")
            curDescY = curDescY + 34
        end

        -- Requirements warning if locked
        if not canInvest and rank < tal.max_ranks and lockReason then
            g.setColor(0.95, 0.35, 0.35, 1.0)
            g.printf("Locked: " .. lockReason, ttX + 12, ttH + ttY - 22, ttW - 24, "left")
        end
    end

    -- 7. Modals (Save, Import, Export)
    if modalMode then
        local mw = 440
        local mh = 160
        local mx0 = math.floor((screenW - mw) * 0.5)
        local my0 = math.floor((screenH - mh) * 0.5)

        -- Darken backdrop
        g.setColor(0, 0, 0, 0.75)
        g.rectangle("fill", 0, 0, screenW, screenH)

        -- Modal Box
        g.setColor(0.08, 0.11, 0.18, 0.98)
        g.rectangle("fill", mx0, my0, mw, mh, 8)
        g.setColor(0.3, 0.7, 1.0, 0.9)
        g.rectangle("line", mx0, my0, mw, mh, 8)

        local title = "MODAL"
        if modalMode == "save" then title = "SAVE CUSTOM SPEC"
        elseif modalMode == "import" then title = "IMPORT TALENT HASH STRING"
        elseif modalMode == "export" then title = "EXPORT TALENT HASH (COPIED TO CLIPBOARD)"
        end

        g.setColor(1, 1, 1, 1)
        g.print(title, mx0 + 16, my0 + 14)

        -- Input Box
        local ibX = mx0 + 16
        local ibY = my0 + 48
        local ibW = mw - 32
        local ibH = 34
        g.setColor(0.04, 0.05, 0.09, 1.0)
        g.rectangle("fill", ibX, ibY, ibW, ibH, 4)
        g.setColor(0.4, 0.5, 0.7, 0.8)
        g.rectangle("line", ibX, ibY, ibW, ibH, 4)

        g.setColor(1, 1, 1, 1)
        local displayText = modalInputText
        if #displayText > 44 then displayText = "..." .. displayText:sub(#displayText - 40) end
        g.print(displayText, ibX + 8, ibY + 9)

        -- Modal Controls
        g.setColor(0.55, 0.65, 0.8, 1.0)
        local hint = "Press [ENTER] to confirm  |  [ESC] to cancel"
        if modalMode == "export" then hint = "Press [ESC] or [ENTER] to close" end
        g.printf(hint, mx0, my0 + mh - 32, mw, "center")
    end
end

return spec_editor
