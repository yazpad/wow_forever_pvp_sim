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
    fight_seconds = 60,
    hp_a = 2000,
    hp_b = 2000,
    pet_a = nil,
    pet_b = nil,
    output = "matches/mcts_custom.lua",
    -- Neuroevolution League Play settings
    mode = "MCTS Search",
    fights_per_epoch = 50000,
    epochs = 10,
    population_size = 64,
    convergence_threshold = 0,
    -- Bulk champion-vs-champion evaluation
    bulk_fights = 1000,
    jitter_start_lag = 0,
    jitter_pos = 0,
}

local neuroTelemetry = {
    epoch = 0,
    max_epochs = 10,
    gens = 0,
    side = "A",
    win_rate_a = 0.5,
    fitness = 0.0,
    fights_sec = 0,
    ticks_sec = 0,
    converged = false,
    seconds = 0,
    archive_score_a = nil,
    archive_score_b = nil,
    pair_win_rate_a = nil,
    policy_a = nil,
    policy_b = nil,
    history = {}, -- list of {gen = N, win_rate_a = WR, epoch = E, side = S}
}

-- Default on-disk location of league champions (neuro_arena overwrites these every run).
local CHAMPION_PREFIX = "matches/neuro_champion"
local bulkEval = nil -- last NEURO_EVAL summary table

local function fileExists(path)
    if not path then return false end
    local f = io.open(path, "rb") or io.open("../" .. path, "rb")
    if f then f:close(); return true end
    return false
end

-- Do not pre-load champions at startup so the user starts fresh.

function match_generator.hasChampionModels()
    local polA = neuroTelemetry.policy_a
    local polB = neuroTelemetry.policy_b
    return (polA and polB and #polA > 0 and #polB > 0) and true or false
end

function match_generator.invalidateChampions()
    neuroTelemetry.policy_a = nil
    neuroTelemetry.policy_b = nil
    neuroTelemetry.pair_win_rate_a = nil
    neuroTelemetry.archive_score_a = nil
    neuroTelemetry.archive_score_b = nil
    neuroTelemetry.history = {}
    bulkEval = nil
end

function match_generator.getBulkEval()
    return bulkEval
end

local buttons = {}

function match_generator.getConfig()
    return config
end

function match_generator.getNeuroTelemetry()
    return neuroTelemetry
end

function match_generator.isActive()
    return active
end

function match_generator.getStatus()
    return status, errorMsg
end

function match_generator.getProgress()
    return progress
end

function match_generator.update(dt)
    if active and channel then
        while true do
            local msg = channel:pop()
            if not msg then break end
            if msg.kind == "progress" then
                neuroTelemetry.epoch = msg.epoch or neuroTelemetry.epoch
                neuroTelemetry.max_epochs = msg.max_epochs or neuroTelemetry.max_epochs
                neuroTelemetry.gens = msg.gens or neuroTelemetry.gens
                neuroTelemetry.side = msg.side or neuroTelemetry.side
                neuroTelemetry.win_rate_a = msg.win_rate_a or neuroTelemetry.win_rate_a
                neuroTelemetry.pair_win_rate_a = msg.pair_win_rate_a or neuroTelemetry.pair_win_rate_a
                neuroTelemetry.fitness = msg.fitness or neuroTelemetry.fitness
                neuroTelemetry.fights_sec = msg.fights_sec or neuroTelemetry.fights_sec
                neuroTelemetry.ticks_sec = msg.ticks_sec or neuroTelemetry.ticks_sec
                local h = neuroTelemetry.history or {}
                neuroTelemetry.history = h
                if #h == 0 or h[#h].gen ~= neuroTelemetry.gens or h[#h].win_rate_a ~= neuroTelemetry.win_rate_a then
                    h[#h + 1] = {
                        gen = neuroTelemetry.gens or #h,
                        epoch = neuroTelemetry.epoch or 0,
                        win_rate_a = neuroTelemetry.win_rate_a,
                        pair_win_rate_a = neuroTelemetry.pair_win_rate_a,
                        side = neuroTelemetry.side,
                    }
                end
                progress = neuroTelemetry.max_epochs > 0 and (neuroTelemetry.epoch / neuroTelemetry.max_epochs) or 0
                status = string.format("Ep %d/%d (Gen %d) · %.0f%% A · %.0fk/s",
                    neuroTelemetry.epoch, neuroTelemetry.max_epochs, neuroTelemetry.gens,
                    neuroTelemetry.win_rate_a * 100, neuroTelemetry.fights_sec / 1000)
            elseif msg.kind == "converged" then
                neuroTelemetry.epoch = msg.epochs or neuroTelemetry.epoch
                neuroTelemetry.gens = msg.gens or neuroTelemetry.gens
                neuroTelemetry.converged = msg.converged or false
                neuroTelemetry.win_rate_a = msg.win_rate_a or neuroTelemetry.win_rate_a
                neuroTelemetry.pair_win_rate_a = msg.pair_win_rate_a
                neuroTelemetry.archive_score_a = msg.archive_score_a
                neuroTelemetry.archive_score_b = msg.archive_score_b
                neuroTelemetry.seconds = msg.seconds or 0
                neuroTelemetry.policy_a = msg.policy_a
                neuroTelemetry.policy_b = msg.policy_b
                local h = neuroTelemetry.history or {}
                neuroTelemetry.history = h
                h[#h + 1] = {
                    gen = (#h > 0 and h[#h].gen) or neuroTelemetry.gens or #h,
                    epoch = neuroTelemetry.epoch or 0,
                    win_rate_a = (#h > 0 and h[#h].win_rate_a) or neuroTelemetry.win_rate_a,
                    pair_win_rate_a = neuroTelemetry.pair_win_rate_a,
                    side = 'final selected pair',
                }
                bulkEval = nil -- models changed; old bulk stats are stale
                progress = 1.0
            elseif msg.kind == "bulk_eval" then
                bulkEval = msg.summary
            else
                active = false
                channel = nil
                thread = nil
                if msg.success then
                    if msg.is_bulk then
                        status = bulkEval and string.format("Simulated %d fights (%.1f%% A)",
                            bulkEval.fights or 0, (bulkEval.win_rate_a or 0) * 100) or "Simulated"
                    elseif msg.is_neuro then
                        status = string.format("Evolved (%d ep, %.0f%% A)",
                            neuroTelemetry.epoch, (neuroTelemetry.win_rate_a or 0.5) * 100)
                    else
                        status = "Complete"
                    end
                    progress = 1.0
                    completedMatchPath = msg.output_path
                else
                    status = "Failed"
                    errorMsg = msg.error or "Simulation process error"
                end
                break
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

local function findBinary(name)
    local root = love.filesystem and love.filesystem.getWorkingDirectory and love.filesystem.getWorkingDirectory() or "."
    local candidates = {
        root .. "/zig-out/bin/" .. name,
        "../zig-out/bin/" .. name,
        "zig-out/bin/" .. name,
    }
    for _, p in ipairs(candidates) do
        local f = io.open(p, "rb")
        if f then
            f:close()
            return p
        end
    end
    return nil
end

local function appendCommonArgs(args, cfg)
    local nameA = (cfg.spec_a_obj and cfg.spec_a_obj.name) or cfg.name_a or (cfg.spec_a == "warlock" and "Warlock" or "Frost Mage")
    local nameB = (cfg.spec_b_obj and cfg.spec_b_obj.name) or cfg.name_b or (cfg.spec_b == "warlock" and "Warlock" or "Frost Mage")
    local specA = (cfg.spec_a_obj and cfg.spec_a_obj.class) or cfg.spec_a or "warlock"
    local specB = (cfg.spec_b_obj and cfg.spec_b_obj.class) or cfg.spec_b or "frost_mage"

    local specIdA = (cfg.spec_a_obj and (cfg.spec_a_obj.filename or cfg.spec_a_obj.filepath)) or cfg.spec_id_a
    local specIdB = (cfg.spec_b_obj and (cfg.spec_b_obj.filename or cfg.spec_b_obj.filepath)) or cfg.spec_id_b

    table.insert(args, "--spec-a"); table.insert(args, specA)
    table.insert(args, "--spec-b"); table.insert(args, specB)
    table.insert(args, "--name-a"); table.insert(args, nameA)
    table.insert(args, "--name-b"); table.insert(args, nameB)
    table.insert(args, "--seconds"); table.insert(args, tostring(cfg.fight_seconds or config.fight_seconds))
    table.insert(args, "--workers"); table.insert(args, tostring(cfg.workers))
    table.insert(args, "--distance"); table.insert(args, tostring(cfg.distance))
    table.insert(args, "--hp-a"); table.insert(args, tostring(cfg.hp_a))
    table.insert(args, "--hp-b"); table.insert(args, tostring(cfg.hp_b))

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
        table.insert(args, specIdA)
    end
    if specIdB and #specIdB > 0 then
        table.insert(args, "--spec-id-b")
        table.insert(args, specIdB)
    end

    if cfg.positions then
        for i, side in ipairs({ "a", "b" }) do
            for _, axis in ipairs({ "x", "y" }) do
                args[#args + 1] = "--" .. axis .. "-" .. side
                args[#args + 1] = tostring(cfg.positions[i][axis])
            end
        end
    end
end

function match_generator.startFight(overrideConfig)
    if active then return false, "Fight generation already running" end
    local cfg = overrideConfig or config

    local binPath = findBinary("mcts_fight")
    if not binPath then
        return false, "mcts_fight binary not found. Build with zig build -Doptimize=ReleaseFast"
    end

    local outPath = cfg.output or "matches/mcts_custom.lua"
    local args = { binPath }
    appendCommonArgs(args, cfg)
    table.insert(args, "--rollouts"); table.insert(args, tostring(cfg.rollouts))
    table.insert(args, "--algorithm"); table.insert(args, cfg.algorithm)
    table.insert(args, "--evaluator"); table.insert(args, cfg.evaluator)
    table.insert(args, "--c-puct"); table.insert(args, string.format("%.3f", cfg.c_puct or 1.414))
    table.insert(args, "--boundary"); table.insert(args, "event")
    table.insert(args, "--output"); table.insert(args, outPath)

    if cfg.policy_a then
        table.insert(args, "--policy-a"); table.insert(args, cfg.policy_a)
    end
    if cfg.policy_b then
        table.insert(args, "--policy-b"); table.insert(args, cfg.policy_b)
    end
    if cfg.rollout_policy_a then
        table.insert(args, "--rollout-policy-a"); table.insert(args, cfg.rollout_policy_a)
    end
    if cfg.rollout_policy_b then
        table.insert(args, "--rollout-policy-b"); table.insert(args, cfg.rollout_policy_b)
    end
    if cfg.seed then
        table.insert(args, "--seed"); table.insert(args, tostring(cfg.seed))
    end

    for i, arg in ipairs(args) do
        args[i] = "'" .. tostring(arg):gsub("'", "'\"'\"'") .. "'"
    end
    local cmd = table.concat(args, " ")
    channel = love.thread.newChannel()
    thread = love.thread.newThread([[
        local command, outPath, chan, temporarySpecs = ...
        local logPath = os.tmpname()
        local quotedLog = "'" .. logPath:gsub("'", "'\"'\"'") .. "'"
        local ok, reason, code = os.execute(command .. " > " .. quotedLog .. " 2>&1")
        local logFile = io.open(logPath, "r")
        local details = logFile and logFile:read("*a") or ""
        if logFile then logFile:close() end
        os.remove(logPath)
        for _, path in ipairs(temporarySpecs or {}) do os.remove(path) end
        local success = (ok == true or ok == 0)
        chan:push({ success = success, output_path = outPath, code = code, error = success and nil or (details ~= "" and details:sub(-2000) or tostring(reason) .. " (exit " .. tostring(code) .. ")") })
    ]])

    thread:start(cmd, outPath, channel, cfg.temporary_specs or {})
    active = true
    progress = 0.0
    status = "Searching..."
    errorMsg = nil
    completedMatchPath = nil
    return true
end

function match_generator.startLeaguePlay(overrideConfig)
    if active then return false, "Generation already running" end
    local cfg = overrideConfig or config

    local binPath = findBinary("neuro_arena")
    if not binPath then
        return false, "neuro_arena binary not found. Build with zig build -Doptimize=ReleaseFast"
    end

    local outPath = cfg.output_replay or "matches/neuro_custom.lua"
    local weightsPrefix = cfg.output_weights or "matches/neuro_champion"
    local fightsPerEpoch = cfg.fights_per_epoch or config.fights_per_epoch or 50000
    local maxEpochs = cfg.epochs or config.epochs or 10
    local popSize = cfg.population_size or config.population_size or 64
    local convThreshold = cfg.convergence_threshold
    if convThreshold == nil then convThreshold = config.convergence_threshold or 0 end

    local args = { binPath }
    appendCommonArgs(args, cfg)
    table.insert(args, "--fights-per-epoch"); table.insert(args, tostring(fightsPerEpoch))
    table.insert(args, "--epochs"); table.insert(args, tostring(maxEpochs))
    table.insert(args, "--population-size"); table.insert(args, tostring(popSize))
    table.insert(args, "--convergence-threshold"); table.insert(args, tostring(convThreshold))
    table.insert(args, "--output-replay"); table.insert(args, outPath)
    table.insert(args, "--output-weights"); table.insert(args, weightsPrefix)

    for i, arg in ipairs(args) do
        args[i] = "'" .. tostring(arg):gsub("'", "'\"'\"'") .. "'"
    end
    local cmd = table.concat(args, " ")

    neuroTelemetry.epoch = 0
    neuroTelemetry.max_epochs = maxEpochs
    neuroTelemetry.gens = 0
    neuroTelemetry.converged = false
    neuroTelemetry.pair_win_rate_a = nil
    neuroTelemetry.archive_score_a = nil
    neuroTelemetry.archive_score_b = nil
    neuroTelemetry.history = {}

    channel = love.thread.newChannel()
    thread = love.thread.newThread([[
        local command, outPath, chan, temporarySpecs = ...
        local pipe = io.popen(command .. " 2>&1", "r")
        local outputLines = {}
        if pipe then
            for line in pipe:lines() do
                outputLines[#outputLines + 1] = line
                if line:find("^NEURO_EPOCH ") then
                    local ep, maxEp = line:match("epoch=(%d+)/(%d+)")
                    local gens = line:match("gens=(%d+)")
                    local side = line:match("side=(%S+)")
                    local wrA = line:match("win_rate_a=([%d%.%-]+)")
                    local pairWrA = line:match("pair_wr_a=([%d%.%-]+)")
                    local fit = line:match("fitness=([%d%.%-]+)")
                    local fps = line:match("fights_sec=([%d%.%-]+)")
                    local tps = line:match("ticks_sec=([%d%.%-]+)")
                    chan:push({
                        kind = "progress",
                        epoch = tonumber(ep),
                        max_epochs = tonumber(maxEp),
                        gens = tonumber(gens),
                        side = side,
                        win_rate_a = tonumber(wrA),
                        pair_win_rate_a = tonumber(pairWrA),
                        fitness = tonumber(fit),
                        fights_sec = tonumber(fps),
                        ticks_sec = tonumber(tps),
                    })
                elseif line:find("^NEURO_CONVERGED ") then
                    local ep = line:match("epochs=(%d+)")
                    local gens = line:match("gens=(%d+)")
                    local conv = line:match("converged=(%S+)")
                    local wrA = line:match("win_rate_a=([%d%.%-]+)")
                    local pairWrA = line:match("pair_wr_a=([%d%.%-]+)")
                    local scoreA = line:match("archive_score_a=([%d%.%-]+)")
                    local scoreB = line:match("archive_score_b=([%d%.%-]+)")
                    local sec = line:match("seconds=([%d%.%-]+)")
                    local polA = line:match("policy_a=(%S+)")
                    local polB = line:match("policy_b=(%S+)")
                    chan:push({
                        kind = "converged",
                        epochs = tonumber(ep),
                        gens = tonumber(gens),
                        converged = (conv == "true"),
                        win_rate_a = tonumber(wrA),
                        pair_win_rate_a = tonumber(pairWrA),
                        archive_score_a = tonumber(scoreA),
                        archive_score_b = tonumber(scoreB),
                        seconds = tonumber(sec),
                        policy_a = polA,
                        policy_b = polB,
                    })
                end
            end
            local ok, reason, code = pipe:close()
            for _, path in ipairs(temporarySpecs or {}) do os.remove(path) end
            local details = table.concat(outputLines, "\n")
            local f = io.open(outPath, "r")
            local fileExists = (f ~= nil)
            if f then f:close() end
            local success = (ok == true or ok == 0) or fileExists
            chan:push({
                is_neuro = true,
                success = success,
                output_path = outPath,
                code = code,
                error = success and nil or (details ~= "" and details:sub(-2000) or tostring(reason)),
            })
        else
            for _, path in ipairs(temporarySpecs or {}) do os.remove(path) end
            chan:push({ is_neuro = true, success = false, output_path = outPath, error = "Failed to spawn neuro_arena" })
        end
    ]])

    thread:start(cmd, outPath, channel, cfg.temporary_specs or {})
    active = true
    progress = 0.0
    status = string.format("Evolving 0/%d...", maxEpochs)
    errorMsg = nil
    completedMatchPath = nil
    return true
end

function match_generator.startBulkEval(overrideConfig)
    if active then return false, "Generation already running" end
    local cfg = overrideConfig or config
    local polA = cfg.policy_a or neuroTelemetry.policy_a
    local polB = cfg.policy_b or neuroTelemetry.policy_b
    if not (fileExists(polA) and fileExists(polB)) then
        return false, "No trained champion models found. Run Evolve & Fight first."
    end

    local binPath = findBinary("neuro_arena")
    if not binPath then
        return false, "neuro_arena binary not found. Build with zig build -Doptimize=ReleaseFast"
    end

    local fights = cfg.bulk_fights or config.bulk_fights or 1000
    local args = { binPath }
    appendCommonArgs(args, cfg)
    table.insert(args, "--evaluate"); table.insert(args, tostring(fights))
    table.insert(args, "--policy-a"); table.insert(args, polA)
    table.insert(args, "--policy-b"); table.insert(args, polB)
    table.insert(args, "--seed"); table.insert(args, tostring(cfg.seed or math.random(1, 2 ^ 31 - 1)))
    table.insert(args, "--jitter-start-lag"); table.insert(args, tostring(cfg.jitter_start_lag or 0))
    table.insert(args, "--jitter-pos"); table.insert(args, tostring(cfg.jitter_pos or 0))
    table.insert(args, "--output-eval"); table.insert(args, cfg.output_eval or (CHAMPION_PREFIX .. "_eval.json"))

    for i, arg in ipairs(args) do
        args[i] = "'" .. tostring(arg):gsub("'", "'\"'\"'") .. "'"
    end
    local cmd = table.concat(args, " ")

    bulkEval = nil
    channel = love.thread.newChannel()
    thread = love.thread.newThread([[
        local command, chan, temporarySpecs = ...
        local pipe = io.popen(command .. " 2>&1", "r")
        if not pipe then
            for _, path in ipairs(temporarySpecs or {}) do os.remove(path) end
            chan:push({ is_bulk = true, success = false, error = "Failed to spawn neuro_arena" })
            return
        end
        local outputLines, gotSummary = {}, false
        for line in pipe:lines() do
            outputLines[#outputLines + 1] = line
            if line:find("^NEURO_EVAL ") then
                local summary = {}
                for k, v in line:gmatch("(%S+)=(%S+)") do
                    summary[k] = tonumber(v) or v
                end
                gotSummary = true
                chan:push({ kind = "bulk_eval", summary = summary })
            end
        end
        local ok, reason, code = pipe:close()
        for _, path in ipairs(temporarySpecs or {}) do os.remove(path) end
        local success = gotSummary and (ok == true or ok == 0)
        local details = table.concat(outputLines, "\n")
        chan:push({
            is_bulk = true,
            success = success,
            code = code,
            error = success and nil or (details ~= "" and details:sub(-2000) or tostring(reason)),
        })
    ]])

    thread:start(cmd, channel, cfg.temporary_specs or {})
    active = true
    progress = 0.0
    status = string.format("Simulating %d fights...", fights)
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
