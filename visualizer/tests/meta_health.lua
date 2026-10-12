-- Run from the repository root: luajit visualizer/tests/meta_health.lua
package.path = 'visualizer/?.lua;' .. package.path
local labels = {}
local noop = function() end
love = {
    graphics = setmetatable({
        getWidth = function() return 1280 end,
        getHeight = function() return 720 end,
        printf = function(text, x, y) labels[#labels + 1] = {text=text, x=x, y=y} end,
    }, {__index=function() return noop end}),
}
package.loaded.icons_manager = {drawClassIcon=noop}
local health = require('meta_health')
local path = os.tmpname()
local f = assert(io.open(path, 'w'))
f:write([[return {
 summary={total_specs=1,trained_bases=0,base_pct=0,total_pairs=1,trained_pairs=0,pair_pct=0},
 specs={{id='deep_frost_mage',name='Deep Frost Mage',class='frost_mage',has_base=false}},
 pairs={{spec_a='deep_frost_mage',spec_b='affliction_warlock',has_model=false}}
}]])
f:close()
assert(health.loadStatusFile(path))
os.remove(path)
local called, busy = 0, false
local controller = {showClassTraining=function(class)
    assert(class == 'frost_mage')
    called = called + 1
    return not busy, 'A run is active.'
end}
controller.getSavedClassRuns = function()
    return {frost_mage={elo=32795.1,generation=300,champion='/tmp/training_runs/frost/champion.bin'}}
end
health.update(2, controller)
health.draw(controller)
local action
for _, label in ipairs(labels) do
    assert(label.text ~= 'Train Matchup', 'Unsupported talent training must not be offered')
    if label.text == 'Train class' then action = label end
end
assert(action)
local ratingVisible = false
for _, label in ipairs(labels) do
    if label.text:find('Class Elo 32795.1', 1, true) then ratingVisible = true end
end
assert(ratingVisible, 'A saved class checkpoint must display its champion Elo')
assert(health.mousepressed(action.x+5, action.y+5, 2) == nil)
assert(called == 0, 'Right-click must not launch training setup')
assert(health.mousepressed(action.x+5, action.y+5, 1) == 'training')
assert(called == 1, 'Containing row must not intercept the action')
busy = true
assert(health.mousepressed(action.x+5, action.y+5, 1) == nil)
labels = {}
health.draw(controller)
local feedback = false
for _, label in ipairs(labels) do if label.text == 'A run is active.' then feedback = true end end
assert(feedback, 'A rejected action must explain why')
print('Spec Meta action routing, unsupported matchup, and busy feedback checks passed')
package.loaded.pipeline = {
    refresh=noop,
    getStages=function() return {{id='base_frost_mage',name='Frost Mage Base',class='frost_mage',
        saved={dir='/tmp/existing-frost-checkpoint'}}} end,
}
local evaluating = false
package.loaded.evaluation = {isActive=function() return evaluating end}
local training = require('training')
local config
local configure = training.configureStage
training.configureStage = function(value) config=value; configure(value) end
assert(training.showClassTraining('frost_mage'))
assert(training.getView() == 'settings')
assert(config.class == 'frost_mage' and config.stage == 'base_frost_mage')
assert(config.resume == '/tmp/existing-frost-checkpoint/population.pop')
assert(config.seed == '' and config.sparring == '' and config.opponent == '')
evaluating = true
local ok, reason = training.showClassTraining('frost_mage')
assert(not ok and reason:find('active'))
print('Class setup preserves the supported checkpoint and blocks during evaluation')
