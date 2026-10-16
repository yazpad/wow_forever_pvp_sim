local ui = require("ui")
local icons = require("icons_manager")
local talents_data = require("talents_data")

local match_generator = {}

local active = false
local channel = nil
local thread = nil
local status = "Idle"
local progress = 0.0
local errorMsg = nil
local completedMatchPath = nil

-- Config options
local savedSpecs = {}
local function refreshSavedSpecs()
    savedSpecs = talents_data.loadSavedSpecs("specs")
    if #savedSpecs == 0 then
        savedSpecs = talents_data.loadSavedSpecs("../specs")
    end
    if #savedSpecs == 0 then
        savedSpecs = {
            { name = "Destruction Warlock", filename = "destro_warlock", class = "warlock" },
            { name = "Deep Frost Mage", filename = "frost_mage", class = "frost_mage" },
        }
    end
end
refreshSavedSpecs()

local rolloutsOptions = { 1024, 4096, 16384, 65536 }
local workersOptions = { 1, 2, 4, 8, 16, 32 }
local algorithms = { "puct", "uct", "exp3" }
local evaluators = { "heuristic", "rollout" }
local distances = { 10, 20, 25, 35 }
local petOptions = { "none", "imp", "succubus", "felhunter", "voidwalker" }

local config = {
    spec_a_obj = savedSpecs[1] or { name = "Warlock", class = "warlock", filename = "warlock" },
    spec_b_obj = savedSpecs[#savedSpecs] or { name = "Frost Mage", class = "frost_mage", filename = "frost_mage" },
    spec_a = (savedSpecs[1] and savedSpecs[1].class) or "warlock",
    spec_b = (savedSpecs[#savedSpecs] and savedSpecs[#savedSpecs].class) or "frost_mage",
    rollouts = 4096,
    workers = 8,
    algorithm = "puct",
    c_puct = 1.414,
    evaluator = "rollout",
    distance = 25,
    hp_a = 2000,
    hp_b = 2000,
    pet_a = nil,
    pet_b = nil,
    output = "matches/mcts_custom.lua",
}

local buttons = {}

function match_generator.getConfig()
    return config
end

function match_generator.isActive()
    return active
end

function match_generator.getStatus()
    return status, errorMsg
end

function match_generator.update(dt)
    if active and channel then
        local msg = channel:pop()
        if msg then
            active = false
            channel = nil
            thread = nil
            if msg.success then
                status = "Complete"
                completedMatchPath = msg.output_path
            else
                status = "Failed"
                errorMsg = msg.error or "Simulation process error"
            end
        end
    end
end

function match_generator.pollCompleted()
    if completedMatchPath then
        local p = completedMatchPath
        completedMatchPath = nil
        return p
    end
    return nil
end

function match_generator.startFight(overrideConfig)
    if active then return false, "Fight generation already running" end
    local cfg = overrideConfig or config

    local root = love.filesystem.getWorkingDirectory()
    local binPath = root .. "/zig-out/bin/mcts_fight"
    local f = io.open(binPath, "rb")
    if not f then
        f = io.open("../zig-out/bin/mcts_fight", "rb")
        if f then binPath = "../zig-out/bin/mcts_fight" end
    end
    if f then f:close() else
        return false, "mcts_fight binary not found. Build with zig build -Doptimize=ReleaseFast"
    end

    local outPath = cfg.output or "matches/mcts_custom.lua"

    local nameA = (cfg.spec_a_obj and cfg.spec_a_obj.name) or cfg.name_a or (cfg.spec_a == "warlock" and "Warlock" or "Frost Mage")
    local nameB = (cfg.spec_b_obj and cfg.spec_b_obj.name) or cfg.name_b or (cfg.spec_b == "warlock" and "Warlock" or "Frost Mage")
    local specA = (cfg.spec_a_obj and cfg.spec_a_obj.class) or cfg.spec_a or "warlock"
    local specB = (cfg.spec_b_obj and cfg.spec_b_obj.class) or cfg.spec_b or "frost_mage"

    local specIdA = (cfg.spec_a_obj and (cfg.spec_a_obj.filename or cfg.spec_a_obj.filepath)) or cfg.spec_id_a
    local specIdB = (cfg.spec_b_obj and (cfg.spec_b_obj.filename or cfg.spec_b_obj.filepath)) or cfg.spec_id_b

    local args = {
        binPath,
        "--spec-a", specA,
        "--spec-b", specB,
        "--name-a", '"' .. nameA .. '"',
        "--name-b", '"' .. nameB .. '"',
        "--rollouts", tostring(cfg.rollouts),
        "--workers", tostring(cfg.workers),
        "--algorithm", cfg.algorithm,
        "--evaluator", cfg.evaluator,
        "--c-puct", string.format("%.3f", cfg.c_puct or 1.414),
        "--distance", tostring(cfg.distance),
        "--hp-a", tostring(cfg.hp_a),
        "--hp-b", tostring(cfg.hp_b),
        "--boundary", "event",
        "--output", outPath,
    }

    if cfg.pet_a then
        table.insert(args, "--pet-a")
        table.insert(args, specA == "warlock" and cfg.pet_a or "none")
    end
    if cfg.pet_b then
        table.insert(args, "--pet-b")
        table.insert(args, specB == "warlock" and cfg.pet_b or "none")
    end

    if specIdA and #specIdA > 0 then
        table.insert(args, "--spec-id-a")
        table.insert(args, '"' .. specIdA .. '"')
    end
    if specIdB and #specIdB > 0 then
        table.insert(args, "--spec-id-b")
        table.insert(args, '"' .. specIdB .. '"')
    end

    local cmd = table.concat(args, " ")
    channel = love.thread.newChannel()
    thread = love.thread.newThread([[
        local command, outPath, chan = ...
        local ok, reason, code = os.execute(command .. " > /dev/null 2>&1")
        local success = (ok == true or ok == 0)
        chan:push({ success = success, output_path = outPath, code = code, error = reason })
    ]])

    thread:start(cmd, outPath, channel)
    active = true
    status = "Searching..."
    errorMsg = nil
    completedMatchPath = nil
    return true
end

function match_generator.drawModal(panelX, panelY, panelW, panelH)
    buttons = {}
    local g = love.graphics
    g.setColor(0.03, 0.05, 0.09, 0.96)
    g.rectangle("fill", panelX, panelY, panelW, panelH, 8)
    g.setColor(0.2, 0.7, 1.0, 0.8)
    g.setLineWidth(1)
    g.rectangle("line", panelX, panelY, panelW, panelH, 8)

    -- Header
    g.setColor(0.2, 0.8, 1.0, 1.0)
    g.rectangle("fill", panelX + 16, panelY + 14, 5, 20)
    g.setColor(1, 1, 1, 1)
    g.print("SPEC VS SPEC MATCH GENERATOR (MCTS PUCT ADVERSARIAL)", panelX + 28, panelY + 16)

    local curY = panelY + 50

    -- Helper to draw option buttons
    local function drawOptionSelector(label, options, selectedVal, rowY, onSelect, fmt)
        g.setColor(0.65, 0.75, 0.85, 1.0)
        g.print(label, panelX + 20, rowY + 3)
        local startX = panelX + 170
        local btnH = 24
        local gap = 8
        local btnW = math.min(90, (panelW - 190 - math.max(0, #options - 1) * gap) / math.max(1, #options))
        for i, opt in ipairs(options) do
            local bx = startX + (i - 1) * (btnW + gap)
            local isSel = (opt == selectedVal)
            g.setColor(isSel and 0.20 or 0.07, isSel and 0.50 or 0.12, isSel and 0.80 or 0.20, 0.95)
            g.rectangle("fill", bx, rowY, btnW, btnH, 4)
            g.setColor(isSel and 0.40 or 0.18, isSel and 0.85 or 0.26, isSel and 1.0 or 0.36, 0.8)
            g.rectangle("line", bx, rowY, btnW, btnH, 4)
            g.setColor(1, 1, 1, isSel and 1.0 or 0.6)
            local text = fmt and fmt(opt) or tostring(opt)
            g.printf(text, bx, rowY + 5, btnW, "center")

            table.insert(buttons, {
                x = bx, y = rowY, w = btnW, h = btnH,
                action = function() onSelect(opt) end
            })
        end
    end

    refreshSavedSpecs()
    -- Side A Spec
    drawOptionSelector("Fighter A Spec:", savedSpecs, config.spec_a_obj, curY, function(v)
        config.spec_a_obj = v
        config.spec_a = v.class or "warlock"
    end, function(v)
        local n = v.name or v.filename or "Spec"
        return #n > 12 and (n:sub(1, 10) .. "..") or n
    end)
    curY = curY + 32

    -- Side B Spec
    drawOptionSelector("Fighter B Spec:", savedSpecs, config.spec_b_obj, curY, function(v)
        config.spec_b_obj = v
        config.spec_b = v.class or "frost_mage"
    end, function(v)
        local n = v.name or v.filename or "Spec"
        return #n > 12 and (n:sub(1, 10) .. "..") or n
    end)
    curY = curY + 38

    drawOptionSelector("A Pet (Warlock):", petOptions, config.spec_a == "warlock" and (config.pet_a or (config.spec_a_obj and config.spec_a_obj.pet) or "imp") or "none", curY,
        function(v) if config.spec_a == "warlock" then config.pet_a = v end end)
    curY = curY + 30
    drawOptionSelector("B Pet (Warlock):", petOptions, config.spec_b == "warlock" and (config.pet_b or (config.spec_b_obj and config.spec_b_obj.pet) or "imp") or "none", curY,
        function(v) if config.spec_b == "warlock" then config.pet_b = v end end)
    curY = curY + 32

    -- Separator
    g.setColor(0.15, 0.22, 0.35, 0.7)
    g.line(panelX + 16, curY, panelX + panelW - 16, curY)
    curY = curY + 12

    -- Rollout budget
    drawOptionSelector("Rollouts / Decision:", rolloutsOptions, config.rollouts, curY, function(v) config.rollouts = v end, function(v)
        if v >= 1024 then return string.format("%dk", math.floor(v / 1024)) else return tostring(v) end
    end)
    curY = curY + 30

    -- Workers
    drawOptionSelector("Worker Threads:", workersOptions, config.workers, curY, function(v) config.workers = v end)
    curY = curY + 30

    -- Algorithm
    drawOptionSelector("Search Algorithm:", algorithms, config.algorithm, curY, function(v) config.algorithm = v end, function(v) return v:upper() end)
    curY = curY + 30

    -- Evaluator
    drawOptionSelector("Leaf Scorer:", evaluators, config.evaluator, curY, function(v) config.evaluator = v end, function(v)
        return v == "heuristic" and "Heuristic Leaf" or "Pure Rollout"
    end)
    curY = curY + 30

    -- Starting Distance
    drawOptionSelector("Starting Range:", distances, config.distance, curY, function(v) config.distance = v end, function(v) return v .. "m" end)
    curY = curY + 40

    -- Presets
    local presetW = 95
    local pY = curY
    local presets = {
        { name = "Fast (1k)", rollouts = 1024, workers = 4, eval = "rollout" },
        { name = "Standard (4k)", rollouts = 4096, workers = 8, eval = "rollout" },
        { name = "Deep (16k)", rollouts = 16384, workers = 16, eval = "rollout" },
    }
    g.setColor(0.65, 0.75, 0.85, 1.0)
    g.print("Presets:", panelX + 20, pY + 4)
    for i, p in ipairs(presets) do
        local px = panelX + 170 + (i - 1) * (presetW + 8)
        g.setColor(0.12, 0.18, 0.28, 0.9)
        g.rectangle("fill", px, pY, presetW, 24, 4)
        g.setColor(0.25, 0.40, 0.60, 0.8)
        g.rectangle("line", px, pY, presetW, 24, 4)
        g.setColor(0.85, 0.90, 1.0, 0.9)
        g.printf(p.name, px, pY + 5, presetW, "center")
        table.insert(buttons, {
            x = px, y = pY, w = presetW, h = 24,
            action = function()
                config.rollouts = p.rollouts
                config.workers = p.workers
                config.evaluator = p.eval
            end
        })
    end

    -- Start Button
    local startBtnW = 160
    local startBtnH = 36
    local startBtnX = panelX + panelW - startBtnW - 20
    local startBtnY = panelY + panelH - startBtnH - 16

    if active then
        g.setColor(0.3, 0.4, 0.15, 0.9)
        g.rectangle("fill", startBtnX, startBtnY, startBtnW, startBtnH, 6)
        g.setColor(0.5, 0.7, 0.3, 1.0)
        g.rectangle("line", startBtnX, startBtnY, startBtnW, startBtnH, 6)
        g.setColor(1, 1, 1, 1)
        g.printf("SEARCHING...", startBtnX, startBtnY + 10, startBtnW, "center")
    else
        g.setColor(0.12, 0.55, 0.35, 0.95)
        g.rectangle("fill", startBtnX, startBtnY, startBtnW, startBtnH, 6)
        g.setColor(0.25, 0.90, 0.55, 1.0)
        g.rectangle("line", startBtnX, startBtnY, startBtnW, startBtnH, 6)
        g.setColor(1, 1, 1, 1)
        g.printf("START MCTS FIGHT", startBtnX, startBtnY + 10, startBtnW, "center")

        table.insert(buttons, {
            x = startBtnX, y = startBtnY, w = startBtnW, h = startBtnH,
            action = function() match_generator.startFight() end
        })
    end

    -- Status Line
    g.setColor(0.6, 0.7, 0.85, 1.0)
    local statusText = "Status: " .. status
    if errorMsg then statusText = statusText .. " (" .. errorMsg .. ")" end
    g.print(statusText, panelX + 20, startBtnY + 10)
end

function match_generator.mousepressed(x, y, button)
    for _, btn in ipairs(buttons) do
        if x >= btn.x and x <= btn.x + btn.w and y >= btn.y and y <= btn.y + btn.h then
            btn.action()
            return true
        end
    end
    return false
end

return match_generator
