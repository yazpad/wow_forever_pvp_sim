-- Run from the repository root: luajit visualizer/tests/saved_runs.lua
package.path = 'visualizer/?.lua;' .. package.path
local scanner = require('saved_runs')
local root = os.tmpname(); os.remove(root)
assert(os.execute('mkdir -p ' .. root .. '/training_runs') == 0)
local function run(name, state, complete, checkpoint)
    local dir = root .. '/training_runs/' .. name
    assert(os.execute('mkdir ' .. dir) == 0)
    local function write(file, text)
        local f=assert(io.open(dir .. '/' .. file,'w')); f:write(text); f:close()
    end
    if state then write('pipeline-state.txt', state) end
    write('champion.bin','model')
    if checkpoint then write('population.pop','population') end
    write('metrics.json','{"action_names":["Idle/Maneuver","Ice Lance"],"generations":[{"generation":300,"elo_max":40000}]}')
    write('trainer.log',complete and "Gen 299 | Time: 45 ms | Best Elo: 32000 | Best Fitness: 1\nGen 300 | Time: 45 ms | Best Elo: 32795.1 | Best Fitness: 2\nSaved full population checkpoint to 'population.pop'" or '')
    return dir
end
run('01','completed',true,true)
local latest=run('02',nil,true,true)
run('03','running',true,true)
run('04','failed',true,true)
run('05','completed',true,false)
local found=scanner.scan(root)
assert(found.frost_mage.dir == latest, 'Discover untagged completed runs; skip active, failed, and incomplete runs')
assert(found.frost_mage.generation == 300)
assert(found.frost_mage.elo == 32795.1, 'Use the saved champion rating, not population maximum or an earlier generation')
assert(not found.warlock)
print('Saved run discovery checks passed; fixtures: ' .. root)
