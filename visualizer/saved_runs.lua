-- Discover completed desktop checkpoints, including older runs without stage tags.
local saved_runs = {}
local json = require('json')
local function read(path)
    local f = io.open(path, 'rb'); if not f then return end
    local data = f:read('*a'); f:close(); return data
end
local function exists(path)
    local f = io.open(path, 'rb'); if not f then return false end
    local size = f:seek('end'); f:close(); return size and size > 0
end
local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
function saved_runs.scan(root)
    local result = {}
    local p = io.popen('find ' .. quote(root .. '/training_runs') .. ' -mindepth 1 -maxdepth 1 -type d 2>/dev/null')
    if not p then return result end
    local dirs = {}; for dir in p:lines() do dirs[#dirs+1] = dir end; p:close()
    table.sort(dirs)
    for _, dir in ipairs(dirs) do
        local state = read(dir .. '/pipeline-state.txt')
        local log = read(dir .. '/trainer.log') or ''
        local saved = state == 'completed' or state == 'stopped'
            or (not state and log:find("Saved full population checkpoint to 'population.pop'", 1, true))
        if saved and exists(dir .. '/champion.bin') and exists(dir .. '/population.pop') then
            local ok, metrics = pcall(json.decode, read(dir .. '/metrics.json') or '')
            local action = ok and metrics and metrics.action_names and metrics.action_names[2]
            local class = action == 'Ice Lance' and 'frost_mage' or (action == 'Agony' and 'warlock')
            if class then
                local last = metrics.generations and metrics.generations[#metrics.generations]
                -- The champion is selected by fitness, so population elo_max is
                -- not necessarily its rating. The trainer logs getBest().elo.
                local championElo
                for generation, rating in log:gmatch("Gen%s+(%d+)%s+|[^\n]-Best Elo:%s*([%+%-%.%deE]+)") do
                    if last and tonumber(generation) == last.generation then
                        local value = tonumber(rating)
                        if value and value == value and math.abs(value) < math.huge then championElo = value end
                    end
                end
                result[class] = {dir=dir, stage=read(dir .. '/pipeline-stage.txt'), champion=dir .. '/champion.bin', population=dir .. '/population.pop',
                    generation=last and last.generation or 0, elo=championElo}
            end
        end
    end
    return result
end
return saved_runs
