local ui = require("ui")
-- Desktop training controller. The native trainer runs outside the render thread.
local training = {}
local json = require("json")
local graphs = require("graphs")
local pipeline = require("pipeline")
local evaluation = require("evaluation")
local advanced, pendingStage, activeStage = false, nil, nil
local trainingView = "pipeline" -- "pipeline" | "graphs" | "settings"
local navButtons = {}
local fields = {
    {label = "Generations", value = "100", numeric = true, min = 1, max = 1000000},
    {label = "Population (ignored on resume)", value = "64", numeric = true, min = 2, max = 65536},
    {label = "Duel batches per agent (16 duels each)", value = "4", numeric = true, min = 1, max = 10000},
    {label = "Checkpoint every N generations", value = "10", numeric = true, min = 1, max = 1000000},
    {label = "Resume population (.pop), optional", value = "", flag = "--resume"},
    {label = "Seed champion (.bin), optional", value = "", flag = "--seed-from"},
    {label = "Sparring model (.bin), optional", value = "", flag = "--sparring-opponent"},
    {label = "Sparring models directory, optional", value = "", flag = "--sparring-pool"},
    {label = "CPU training threads", value = "1", numeric = true, min = 1, max = 256},
    {label = "Class: warlock or frost_mage", value = "warlock"},
    {label = "External opponent class (optional)", value = ""},
}
local selected, root, artifactRoot, worker, channel, runDir
local status, logTail, summary = "Ready", "", ""
local active, stopping, sparGauntlet = false, false, false
local stopWritten = false
local pollTime, lastMetrics, serial = 0, nil, 0
local buttons = {}

local function quote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end
local function read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end
local function absolute(path)
    return path:sub(1, 1) == "/" and path or root .. "/" .. path
end

function training.load(options)
    local source = love.filesystem.getSource()
    local candidates = {source:match("^(.*)/[^/]+$"), love.filesystem.getWorkingDirectory(), ".."}
    for _, candidate in ipairs(candidates) do
        if read(candidate .. "/build.zig") then root = candidate; break end
    end
    root = root or love.filesystem.getWorkingDirectory()
    if love.system.getOS() == "Windows" then
        status = "Training controls currently support Linux/macOS desktop builds."
    elseif not read(root .. "/zig-out/bin/pvp_sim") then
        status = "Build the trainer first: zig build -Doptimize=ReleaseFast"
    end
    artifactRoot = options and options.artifactRoot or root
    evaluation.load(artifactRoot, root)
    pipeline.load(artifactRoot, training)
end

function training.showSettings()
    trainingView = "settings"
    advanced = true
end
-- Canonical talent presets are not trainer inputs. Open the supported class
-- stage for review, retaining its checkpoint when one exists.
function training.showClassTraining(class)
    if active or evaluation.isActive() then
        return false, "A run is active. Open Training [F6] to monitor or stop it first."
    end
    pipeline.refresh()
    for _, stage in ipairs(pipeline.getStages()) do
        if stage.class == class and not stage.opponent then
            local checkpoint = stage.saved and stage.saved.dir
            local latest = training.getSavedClassRuns()[class]
            if latest and (not latest.stage or latest.stage == stage.id)
                and (not checkpoint or latest.dir > checkpoint) then checkpoint = latest.dir end
            training.configureStage({class = class, opponent = "", stage = stage.id,
                resume = checkpoint and checkpoint .. "/population.pop" or "",
                seed = "", sparring = ""})
            sparGauntlet = false
            status = "Class kit: " .. stage.name .. ". Talent presets are not supported."
            training.showSettings()
            return true
        end
    end
    return false, "No supported training stage for " .. tostring(class)
end

function training.setView(view)
    if view == "graphs" or view == "pipeline" or view == "settings" then
        trainingView = view
        advanced = (view == "settings")
    end
end
function training.getView()
    return trainingView
end
function training.configureStage(config)
    pendingStage = config.stage
    fields[10].value, fields[11].value = config.class, config.opponent
    fields[5].value, fields[6].value = config.resume, config.seed
    fields[7].value, fields[8].value = config.sparring, ""
end

function training.start()
    if active or evaluation.isActive() then return end
    if love.system.getOS() == "Windows" then
        status = "Training controls currently support Linux/macOS desktop builds."
        return
    end
    if not read(root .. "/zig-out/bin/pvp_sim") then
        status = "Build the trainer first: zig build -Doptimize=ReleaseFast"
        return
    end
    for _, field in ipairs(fields) do
        if field.numeric then
            local n = tonumber(field.value)
            if not field.value:match("^%d+$") or not n or n ~= math.floor(n) or n < field.min or n > field.max then
                status = field.label .. ": enter an integer from " .. field.min .. " to " .. field.max
                return
            end
        end
    end
    for _, i in ipairs({10, 11}) do
        local value = fields[i].value
        if value ~= "warlock" and value ~= "frost_mage" and not (i == 11 and value == "") then
            status = fields[i].label .. ": enter warlock or frost_mage"
            return
        end
    end
    if fields[5].value ~= "" and fields[6].value ~= "" then
        status = "Choose either a resume population or a seed champion."
        return
    end
    for i = 5, 7 do
        if fields[i].value ~= "" and not read(absolute(fields[i].value)) then
            status = "Cannot read " .. fields[i].value
            return
        end
    end
    serial = serial + 1
    -- Reserve a unique directory without overwriting any previous run.
    runDir = artifactRoot .. "/training_runs/" .. os.date("%Y%m%d-%H%M%S") .. "-" .. tostring(love.timer.getTime()):gsub("%.", "-") .. "-" .. serial
    local args = {quote(root .. "/zig-out/bin/pvp_sim"), "--train-only", "--live-metrics",
        "--stop-file stop.request", "--metrics metrics.json", "--save-champion champion.bin",
        "--save-population population.pop", "--generations " .. fields[1].value,
        "--pop " .. fields[2].value, "--duels " .. fields[3].value,
        "--checkpoint-interval " .. fields[4].value, "--threads " .. fields[9].value}
    args[#args+1] = "--class " .. fields[10].value
    if fields[11].value ~= "" then args[#args+1] = "--opponent-class " .. fields[11].value end
    for i = 5, 8 do
        if fields[i].value ~= "" then
            args[#args + 1] = fields[i].flag .. " " .. quote(absolute(fields[i].value))
        end
    end
    if sparGauntlet then
        args[#args + 1] = "--spar-gauntlet --gauntlet-interval " .. fields[4].value
    end
    local command = "mkdir -p " .. quote(artifactRoot .. "/training_runs") .. " && mkdir " .. quote(runDir)
        .. " && cd " .. quote(runDir)
    activeStage, pendingStage = pendingStage, nil
    if activeStage then
        command = command .. " && printf %s " .. quote(activeStage) .. " > pipeline-stage.txt"
            .. " && printf running > pipeline-state.txt"
    end
    command = command .. " && " .. table.concat(args, " ") .. " > trainer.log 2>&1"
    channel = love.thread.newChannel()
    worker = love.thread.newThread([[
        local command, result = ...
        local ok, reason, code = os.execute(command)
        -- LuaJIT returns a numeric status; Lua 5.2+ returns boolean/reason/code.
        local success = ok == true or ok == 0
        result:push({success = success, code = code or tostring(ok), reason = reason or "exit"})
    ]])
    local ok, err = pcall(function() worker:start(command, channel) end)
    if not ok then status = tostring(err); return end
    active, stopping, selected = true, false, nil
    stopWritten = false
    love.keyboard.setTextInput(false)
    status, logTail, summary = "Running", "", "Waiting for first generation..."
    pollTime, lastMetrics = 0.5, nil
    graphs.clear()
    trainingView = "graphs"
    advanced = false
end

local function writeStop()
    local f, err = io.open(runDir .. "/stop.request", "w")
    if not f then return false, err end
    f:write("stop\n"); f:close()
    return true
end

function training.stop()
    if not active or stopping then return end
    stopping = true
    stopWritten = writeStop()
    status = "Stopping after the current generation; saving champion and population..."
end

local function refresh()
    if not runDir then return end
    local data = read(runDir .. "/metrics.json")
    if data and data ~= lastMetrics then
        local ok, metrics = pcall(json.decode, data)
        if ok and metrics.generations then
            lastMetrics = data
            graphs.loadMetricsFile(runDir .. "/metrics.json", true)
            local m = metrics.generations[#metrics.generations]
            if m then
                summary = string.format("Generation %d | Best Elo %.1f | Mean fitness %.1f | %.1f ms/gen",
                    m.generation, m.elo_max, m.fitness_mean, m.duration_ms)
            end
        end
    end
    local f = io.open(runDir .. "/trainer.log", "rb")
    if f then
        local size = f:seek("end")
        f:seek("set", math.max(0, size - 8192))
        local lines = {}
        for line in f:lines() do lines[#lines + 1] = line end
        f:close()
        local tail = {}
        for i = math.max(1, #lines - 7), #lines do tail[#tail + 1] = lines[i] end
        logTail = table.concat(tail, "\n")
    end
end

function training.update(dt)
    evaluation.update()
    if not active then pipeline.update(); return end
    if stopping and not stopWritten then stopWritten = writeStop() end
    pollTime = pollTime + dt
    if pollTime >= 0.5 then pollTime = 0; refresh() end
    local result = channel:pop()
    local err = worker:getError()
    if result or err then
        active = false
        refresh()
        if err then status = "Worker failed: " .. err
        elseif not result.success then status = "Training failed (" .. tostring(result.code) .. "). See log below."
        elseif stopping then status = "Stopped; champion and population saved."
        else status = "Completed; champion and population saved." end
        if result and result.success then
            fields[5].value = runDir .. "/population.pop"
            fields[6].value = ""
        end
        if activeStage then
            local f = io.open(runDir .. "/pipeline-state.txt", "w")
            if f then
                local state = (err or not result or not result.success) and "failed" or (stopping and "stopped" or "completed")
                f:write(state)
                f:close()
            end
            pendingStage = activeStage
            activeStage = nil
        end
        if result and result.success and not stopping then pipeline.manualCompleted() end
        stopping = false
    end
    pipeline.update()
end

function training.hasFocus() return selected ~= nil end
function training.isActive() return active or evaluation.isActive() end
function training.getProjectRoot() return root end
function training.getSavedClassRuns()
    if not (artifactRoot or root) then return {} end
    return require("saved_runs").scan(artifactRoot or root)
end
function training.getRunDirectory() return runDir end
function training.getStatus() return status end
function training.getSummary() return summary end
function training.evaluate()
    if active then return false end
    return evaluation.start(pipeline.getStages())
end

local function fieldBounds(index, screenW)
    local fieldW = math.min(440, screenW * 0.46)
    if index <= 9 then return 28, 94 + (index - 1) * 43, fieldW end
    local x = fieldW + 55
    return x, 382 + (index - 10) * 43, math.min(fieldW, screenW - x - 28)
end

local function drawNavTabs(w)
    local g = love.graphics
    local tabs = {
        {id = "pipeline", label = "Pipeline"},
        {id = "graphs", label = "Live telemetry" .. (graphs.hasData() and " [Active]" or "")},
        {id = "settings", label = "Settings"},
    }
    local tabW = 210
    local totalW = #tabs * (tabW + 8) - 8
    local startX = 28
    local tabY = 16

    navButtons = {}
    for i, tab in ipairs(tabs) do
        local bx = startX + (i - 1) * (tabW + 8)
        local isAct = (trainingView == tab.id)
        ui.tab(bx, tabY, tabW, 28, tab.label, isAct, false)
        navButtons[#navButtons + 1] = {x = bx, y = tabY, w = tabW, h = 26, id = tab.id}
    end

    if active then
        local stopW = 100
        local stopX = w - stopW - 28
        g.setColor(stopping and 0.4 or 0.7, 0.15, 0.15, 0.9)
        g.rectangle("fill", stopX, tabY, stopW, 26, 4)
        g.setColor(1, 1, 1, 1)
        g.printf(stopping and "Stopping..." or "Stop & Save", stopX, tabY + 5, stopW, "center")
        navButtons[#navButtons + 1] = {x = stopX, y = tabY, w = stopW, h = 26, id = "stop_action"}
    end
end

function training.draw()
    local g = love.graphics
    local w, h = ui.dimensions()

    if trainingView == "graphs" then
        ui.withInset(48, graphs.draw)
        drawNavTabs(w)
        return
    elseif trainingView == "pipeline" then
        pipeline.draw()
        drawNavTabs(w)
        return
    end

    -- settings view
    g.clear(0.03, 0.05, 0.09)
    drawNavTabs(w)
    g.setColor(0.9, 0.94, 1)
    g.print("Training control | CPU workers with 16-wide SIMD", 28, 62)
    local fieldW = math.min(440, w * 0.46)
    for i, field in ipairs(fields) do
        local fx, y, fw = fieldBounds(i, w)
        g.setColor(0.6, 0.72, 0.86)
        g.print(field.label, fx, y)
        g.setColor(selected == i and 0.16 or 0.08, 0.14, 0.22)
        g.rectangle("fill", fx, y + 16, fw, 23, 3)
        g.setColor(active and 0.5 or 0.9, active and 0.6 or 0.94, 1)
        local text = field.value ~= "" and field.value or "(none)"
        if selected == i then text = text .. "|" end
        g.push(); ui.scissor(fx + 4, y + 16, fw - 8, 23)
        g.print(text, fx + 6, y + 20); g.setScissor(); g.pop()
    end
    local x = fieldW + 55
    g.setColor(0.9, 0.94, 1)
    g.printf(status, x, 95, w - x - 28)
    g.setColor(0.4, 0.8, 1)
    g.printf(summary, x, 155, w - x - 28)
    g.setColor(0.6, 0.72, 0.86)
    g.printf("Run folder:\n" .. (runDir or "Created automatically when training starts")
        .. "\n\nPaths are relative to the project root. Resume keeps the checkpoint population size; generations adds to the saved count.\n\nUse F2 for live graphs. You can browse other tabs while training runs.", x, 210, w - x - 28)
    buttons = {
        {x = 28, y = 490, w = fieldW, label = (sparGauntlet and "[x]" or "[ ]") .. " Spar against gauntlet bots", action = "gauntlet"},
        {x = 28, y = 526, w = 145, label = "Start / Resume", action = "start"},
        {x = 185, y = 526, w = 120, label = "Stop & Save", action = "stop"},
        {x = 317, y = 526, w = 150, label = "Live Graphs [F2]", action = "graphs"},
        {x = x, y = 526, w = 180, label = "Pipeline overview", action = "pipeline"},
    }
    for _, b in ipairs(buttons) do
        g.setColor(0.12, 0.23, 0.34); g.rectangle("fill", b.x, b.y, b.w, 28, 4)
        g.setColor(0.85, 0.94, 1); g.printf(b.label, b.x, b.y + 7, b.w, "center")
    end
    if h > 598 then
        g.setColor(0.55, 0.67, 0.8)
        g.printf(logTail, 28, 570, w - 56)
    end
end

function training.mousepressed(x, y, button)
    if button ~= 1 then return end
    for _, nb in ipairs(navButtons) do
        if x >= nb.x and x <= nb.x + nb.w and y >= nb.y and y <= nb.y + nb.h then
            if nb.id == "stop_action" then
                training.stop()
            elseif nb.id == "pipeline" then
                training.setView("pipeline")
                pipeline.refresh()
            elseif nb.id == "graphs" then
                training.setView("graphs")
            elseif nb.id == "settings" then
                training.setView("settings")
            end
            return
        end
    end

    if trainingView == "graphs" then
        graphs.mousepressed(x, y - 48, button)
        return
    end

    if trainingView == "pipeline" then
        local res = pipeline.mousepressed(x, y)
        if res == "settings" then
            training.setView("settings")
            pendingStage = nil
        end
        return
    end

    selected = nil
    for _, b in ipairs(buttons) do
        if x >= b.x and x <= b.x + b.w and y >= b.y and y <= b.y + 28 then
            if b.action == "start" then training.start()
            elseif b.action == "stop" then training.stop()
            elseif b.action == "gauntlet" and not active then sparGauntlet = not sparGauntlet
            elseif b.action == "graphs" then training.setView("graphs") end
            if b.action == "pipeline" then
                training.setView("pipeline")
                pendingStage = nil
                love.keyboard.setTextInput(false); pipeline.refresh()
            end
            return
        end
    end
    if not active then
        local fieldW = math.min(440, ui.width() * 0.46)
        for i = 1, #fields do
            local fx, labelY, fw = fieldBounds(i, ui.width())
            local fy = labelY + 16
            if x >= fx and x <= fx + fw and y >= fy and y <= fy + 23 then
                selected = i; love.keyboard.setTextInput(true); return
            end
        end
    end
    love.keyboard.setTextInput(false)
end

function training.textinput(text)
    if trainingView == "settings" and selected and not active then
        local field = fields[selected]
        if not field.numeric or text:match("^%d+$") then field.value = field.value .. text end
    end
end

function training.keypressed(key)
    if trainingView == "graphs" then
        graphs.keypressed(key)
        return
    end

    if selected and not active and trainingView == "settings" then
        local field = fields[selected]
        if key == "backspace" then
            local utf8 = require("utf8")
            local offset = utf8.offset(field.value, -1)
            if offset then field.value = field.value:sub(1, offset - 1) end
        elseif key == "v" and love.keyboard.isDown("lctrl", "rctrl", "lgui", "rgui") then
            local text = love.system.getClipboardText():gsub("[\r\n]", "")
            if not field.numeric or text:match("^%d+$") then field.value = field.value .. text end
        elseif key == "a" and love.keyboard.isDown("lctrl", "rctrl", "lgui", "rgui") then
            field.value = ""
        elseif key == "tab" then
            selected = selected % #fields + 1
        elseif key == "return" or key == "escape" then
            selected = nil; love.keyboard.setTextInput(false)
        end
    end
end
return training
