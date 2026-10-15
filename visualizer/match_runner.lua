local json = require("json")
local talents_data = require("talents_data")

local match_runner = {}

local active = false
local thread = nil
local channel = nil

local queue = {}
local totalQueue = 0
local currentIndex = 0
local currentMatchName = ""
local statusText = "Idle"
local lastError = nil

-- Configuration options for matrix / sequential runs
local runnerConfig = {
    rollouts = 1024,
    workers = 4,
    algorithm = "puct",
    evaluator = "heuristic",
    c_puct = 1.414,
    distance = 25,
    hp_a = 2000,
    hp_b = 2000,
}

local function sanitizeId(str)
    return (str or "spec"):lower():gsub("%s+", "_"):gsub("[^%w_%-]", "")
end

function match_runner.getConfig()
    return runnerConfig
end

function match_runner.isActive()
    return active
end

function match_runner.getStatus()
    return statusText, currentIndex, totalQueue, currentMatchName, lastError
end

function match_runner.update(dt)
    if not active then return end

    if thread then
        local threadErr = thread:getError()
        if threadErr then
            active = false
            channel = nil
            thread = nil
            statusText = "Thread Error"
            lastError = threadErr
            return
        end
    end

    if channel then
        local msg = channel:pop()
        if msg then
            if msg.type == "item_done" then
                currentIndex = msg.index
                currentMatchName = msg.name or ""
                statusText = string.format("Running [%d/%d]: %s", currentIndex, totalQueue, currentMatchName)
            elseif msg.type == "queue_complete" then
                active = false
                channel = nil
                thread = nil
                statusText = "Batch Simulation Complete"
                currentMatchName = ""
                match_runner.justCompleted = true
            elseif msg.type == "error" then
                active = false
                channel = nil
                thread = nil
                statusText = "Failed"
                lastError = msg.error
            end
        end
    end
end

function match_runner.pollCompleted()
    if match_runner.justCompleted then
        match_runner.justCompleted = false
        return true
    end
    return false
end

-- Kicks off simulations sequentially for a list of (spec_a, spec_b) pairs
function match_runner.startBatch(pairList, overrideConfig)
    if active then return false, "Batch simulation already running" end
    if not pairList or #pairList == 0 then return false, "No spec pairs provided" end

    local cfg = overrideConfig or runnerConfig
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

    queue = {}
    for idx, pair in ipairs(pairList) do
        local a = pair.a
        local b = pair.b
        local idA = sanitizeId(a.filename or a.name or a.id)
        local idB = sanitizeId(b.filename or b.name or b.id)
        local outPath = string.format("matches/match_%s_vs_%s.lua", idA, idB)

        local function shQuote(val)
            return string.format("'%s'", tostring(val):gsub("'", "'\\''"))
        end

        local function normalizeSpec(cls)
            if not cls then return "warlock" end
            local s = tostring(cls):lower()
            if s == "frost_mage" or s == "mage" then return "frost_mage" end
            return "warlock"
        end

        local args = {
            shQuote(binPath),
            "--spec-a", normalizeSpec(a.class),
            "--spec-b", normalizeSpec(b.class),
            "--name-a", shQuote(a.name or idA),
            "--name-b", shQuote(b.name or idB),
            "--spec-id-a", shQuote(idA),
            "--spec-id-b", shQuote(idB),
            "--rollouts", tostring(cfg.rollouts or 1024),
            "--workers", tostring(cfg.workers or 4),
            "--algorithm", cfg.algorithm or "puct",
            "--evaluator", cfg.evaluator or "heuristic",
            "--c-puct", string.format("%.3f", cfg.c_puct or 1.414),
            "--distance", tostring(cfg.distance or 25),
            "--hp-a", tostring(cfg.hp_a or 2000),
            "--hp-b", tostring(cfg.hp_b or 2000),
            "--boundary", "event",
            "--output", shQuote(outPath),
        }
        table.insert(queue, {
            index = idx,
            cmd = table.concat(args, " "),
            outPath = outPath,
            name = string.format("%s vs %s", a.name or idA, b.name or idB),
        })
    end

    totalQueue = #queue
    currentIndex = 0
    currentMatchName = queue[1].name
    statusText = string.format("Starting [%d matches]...", totalQueue)
    lastError = nil

    channel = love.thread.newChannel()
    thread = love.thread.newThread([[
        local queueJson, chan = ...
        package.path = "visualizer/?.lua;?.lua;" .. package.path
        local ok_j, json = pcall(require, "json")
        if not ok_j then
            chan:push({ type = "error", error = "Failed to load json in thread: " .. tostring(json) })
            return
        end

        local ok_d, q = pcall(json.decode, queueJson)
        if not ok_d or not q then
            chan:push({ type = "error", error = "Failed to decode queue in thread" })
            return
        end

        for i, item in ipairs(q) do
            chan:push({ type = "item_done", index = i, name = item.name, outPath = item.outPath })
            local fcmd = io.open("/tmp/match_runner_cmd.log", "w")
            if fcmd then fcmd:write(item.cmd .. "\n"); fcmd:close() end
            local ok, reason, code = os.execute(item.cmd .. " > /tmp/match_runner_last.log 2>&1")
            local success = (ok == true or ok == 0)
            if not success then
                local logContent = ""
                local f = io.open("/tmp/match_runner_last.log", "r")
                if f then logContent = f:read(1024) or ""; f:close() end
                chan:push({ type = "error", error = "Match failed (" .. item.name .. "): " .. logContent .. " [CMD: " .. item.cmd .. "]" })
                return
            end
        end
        chan:push({ type = "queue_complete" })
    ]])

    local serialized = json.encode(queue)
    thread:start(serialized, channel)
    active = true
    return true
end

return match_runner
