-- Run from the repository root: love visualizer/training_test
package.path = love.filesystem.getWorkingDirectory() .. "/visualizer/?.lua;" .. package.path
local training = require("training")
local graphs = require("graphs")
local json = require("json")
local pipeline = require("pipeline")
local evaluation = require("evaluation")
local stageIndex = 1
local successRevision
function love.errorhandler(message)
    print(debug.traceback(tostring(message), 2))
    return function() return 1 end
end
local phase, ticks, stoppedGeneration, started = 1, 0, nil, 0
local function read(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("*a"); f:close(); return s
end
local function edit(index, value)
    if index <= 9 then training.mousepressed(40, 115 + (index - 1) * 43, 1)
    else training.mousepressed(520, 403 + (index - 10) * 43, 1) end
    training.keypressed("a")
    training.textinput(value)
end
function love.load()
    -- The controller is exercised without an SDL window.
    love.graphics = {getWidth = function() return 1280 end, getHeight = function() return 720 end, getDimensions = function() return 1280, 720 end, isActive = function() return false end}
    for _, name in ipairs({'clear', 'setColor', 'printf', 'print', 'rectangle', 'push', 'pop', 'setScissor'}) do
        love.graphics[name] = function() end
    end
    love.graphics.getFont = function() return {getHeight = function() return 12 end} end
    love.keyboard.setTextInput = function() end
    love.keyboard.isDown = function() return true end
    local artifactRoot = "/tmp/pvp-pipeline-test-" .. os.time() .. "-" .. tostring(love.timer.getTime()):gsub("%.", "-")
    training.load({artifactRoot = artifactRoot})
    training.draw()
    training.showSettings()
    training.draw()
    edit(1, "1000"); edit(2, "16"); edit(3, "1"); edit(4, "2"); edit(9, "4")
    training.start()
    assert(training.isActive(), training.getStatus())
    started = love.timer.getTime()
end
function love.update(dt)
    ticks = ticks + 1
    assert(love.timer.getTime() - started < 30, "Training integration timed out")
    training.update(dt)
    if phase == 1 and graphs.hasData() and training.isActive() then
        training.stop(); phase = 2
    elseif phase == 2 and not training.isActive() then
        local dir = training.getRunDirectory()
        local metrics = json.decode(read(dir .. "/metrics.json"))
        stoppedGeneration = metrics.generations[#metrics.generations].generation
        assert(stoppedGeneration > 0 and stoppedGeneration < 1000)
        assert(#read(dir .. "/champion.bin") > 0)
        assert(#read(dir .. "/population.pop") > 0)
        assert(not read(dir .. "/trainer.log"):find("Benchmark 1", 1, true))
        assert(training.getStatus():find("Stopped", 1, true))
        edit(1, "2"); edit(9, "2"); training.start(); phase = 3
    elseif phase == 3 and not training.isActive() then
        local metrics = json.decode(read(training.getRunDirectory() .. "/metrics.json"))
        assert(#metrics.generations == 2)
        assert(metrics.generations[2].generation == stoppedGeneration + 2)
        assert(training.getStatus():find("Completed", 1, true))
        edit(1, "1000"); training.start(); training.stop(); phase = 4
    elseif phase == 4 and not training.isActive() then
        assert(training.getStatus():find("Stopped", 1, true), training.getStatus())
        assert(#read(training.getRunDirectory() .. "/population.pop") > 0)
        edit(8, "/tmp/pvp-nonexistent-sparring-directory")
        training.start(); phase = 5
    elseif phase == 5 and not training.isActive() then
        assert(training.getStatus():find("Training failed", 1, true), training.getStatus())
        edit(8, ""); edit(5, ""); edit(1, "2"); edit(10, "frost_mage"); edit(11, "warlock")
        training.start(); phase = 6
    elseif phase == 6 and not training.isActive() then
        assert(training.getStatus():find("Completed", 1, true), training.getStatus())
        local dir = training.getRunDirectory()
        local champion = read(dir .. "/champion.bin")
        local metrics = json.decode(read(dir .. "/metrics.json"))
        assert(champion:sub(1, 4) == "PSIM" and champion:byte(6) == 1)
        assert(metrics.action_names[2] == "Ice Lance")
        edit(1, "1"); training.start(); phase = 7
    elseif phase == 7 and not training.isActive() then
        assert(training.getStatus():find("Completed", 1, true), training.getStatus())
        local metrics = json.decode(read(training.getRunDirectory() .. "/metrics.json"))
        assert(metrics.generations[1].generation == 3)
        pipeline.startStage(stageIndex); phase = 8
        assert(training.isActive(), training.getStatus())
    elseif phase == 8 and not training.isActive() then
        assert(training.getStatus():find("Completed", 1, true), training.getStatus())
        local stages = pipeline.getStages()
        assert(stages[stageIndex].saved, "Pipeline did not persist stage artifacts")
        assert(read(training.getRunDirectory() .. "/pipeline-stage.txt") == stages[stageIndex].id)
        assert(read(training.getRunDirectory() .. "/pipeline-state.txt") == "completed")
        stageIndex = stageIndex + 1
        if stageIndex <= #stages then
            pipeline.startStage(stageIndex)
            assert(training.isActive(), training.getStatus())
        else
            pipeline.refresh()
            for _, stage in ipairs(stages) do assert(stage.saved and stage.saved.generation > 0) end
            pipeline.startAll()
            assert(evaluation.isActive(), "Completed training should launch evaluation")
            phase = 10
        end
    elseif phase == 10 and not training.isActive() then
            local stages = pipeline.getStages()
            -- Exercise the unattended queue and checkpoint resume for every stage.
            for _, stage in ipairs(stages) do stage.saved.state = "stopped" end
            pipeline.startAll(); phase = 9
            assert(training.isActive(), training.getStatus())
    elseif phase == 9 and not training.isActive() then
            for _, stage in ipairs(pipeline.getStages()) do
                assert(stage.saved and stage.saved.state == "completed")
                assert(stage.saved.generation >= 2)
            end
            assert(evaluation.getRevision() > 0, evaluation.getStatus())
            local evaluationDir = evaluation.getRunDirectory()
            local artifactRoot = evaluationDir:match("^(.*)/evaluation_runs/")
            local matrix = assert(loadfile(artifactRoot .. "/spec_matrix.lua"))()
            local mage = false
            for _, model in ipairs(matrix.models) do if model.spec == "frost_mage" then mage = true end end
            assert(mage, "Evaluation matrix is missing Mage models")
            local browser = require("match_browser")
            browser.scanMatchesDir(artifactRoot .. "/matches")
            assert(#browser.getMatches() > 12, "Expected multiple replay pages")
            local mageReplay = false
            for _, match in ipairs(browser.getMatches()) do
                if match.spec_a == "frost_mage" or match.spec_b == "frost_mage" then mageReplay = true end
            end
            assert(mageReplay, "Browser metadata is missing Mage replays")
            browser.keypressed("pagedown")
            local nextPage = math.min(12, math.floor((love.graphics.getHeight() - 100) / 52)) + 1
            assert(browser.keypressed("return") == browser.getMatches()[nextPage].path, "Replay pagination failed")
            assert(browser.mousepressed(50, 85, 1) == browser.getMatches()[nextPage].path, "Replay click position differs from draw")
            local icons = require("icons_manager")
            local mageIcons = 0
            icons.draw = function() end
            icons.drawClassIcon = function(class) if class == "mage" then mageIcons = mageIcons + 1 end end
            love.graphics.getFont = function() return {getWidth = function(_, text) return #text * 8 end} end
            local matrixView = require("matrix_view")
            assert(matrixView.loadMatrixFile(artifactRoot .. "/spec_matrix.lua"))
            matrixView.draw()
            assert(mageIcons > 0, "Matrix drew no Mage class icons")
            local before = mageIcons
            -- Find a visible page with a Mage replay and render it.
            while browser.keypressed("return") ~= browser.getMatches()[1].path do browser.keypressed("up") end
            for i, match in ipairs(browser.getMatches()) do
                if match.spec_a == "frost_mage" then
                    for _ = 2, i do browser.keypressed("down") end
                    break
                end
            end
            browser.draw()
            assert(mageIcons > before, "Browser drew no Mage class icons")
            successRevision = evaluation.getRevision()
            assert(evaluation.start({{id='missing', class='warlock', saved={dir='/tmp/pvp-missing-evaluation-champion'}}}))
            phase = 11
    elseif phase == 11 and not training.isActive() then
            assert(evaluation.getStatus():find("failed", 1, true), evaluation.getStatus())
            assert(evaluation.getRevision() == successRevision, "Failed evaluation triggered a refresh")
            print("PASS: live metrics, stop/save, resume, trainer failure, all pipeline stages, automatic evaluation, Mage matrix/replays/icons, browser pagination, evaluation failure")
            love.event.quit()
    end
end
