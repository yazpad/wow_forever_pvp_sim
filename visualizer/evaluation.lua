-- Evaluate a snapshot of saved champions without moving or replacing source models.
local evaluation = {}
local worker, channel, active, status, root, engineRoot, runDir
local revision = 0
local function read(path)
    local f=io.open(path,'rb'); if not f then return end
    local s=f:read('*a'); f:close(); return s
end
local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function files(path, pattern)
    local p=io.popen('find '..quote(path)..' -maxdepth 1 -type f -name '..quote(pattern)..' 2>/dev/null')
    local result={}; if p then for file in p:lines() do result[#result+1]=file end; p:close() end
    table.sort(result); return result
end
local function championClass(path)
    local data=read(path)
    if not data then return end
    if data:sub(1,4)=='PSIM' then
        if data:byte(5)==1 and data:byte(6)==1 then return 'frost_mage' end
    elseif #data>8 then return 'warlock' end
end
function evaluation.load(projectRoot, executableRoot)
    root,engineRoot=projectRoot,executableRoot
    active=false
    status=read(root..'/evaluation-status.txt') or 'Not evaluated yet'
end
function evaluation.isActive() return active end
function evaluation.getStatus() return status end
function evaluation.getRevision() return revision end
function evaluation.getRunDirectory() return runDir end
function evaluation.start(stages)
    if active then return false end
    if love.system.getOS()=='Windows' then status='Evaluation requires Linux/macOS.'; return false end
    if not read(engineRoot..'/zig-out/bin/pvp_sim') then status='Build the trainer first: zig build -Doptimize=ReleaseFast'; return false end
    local sources, represented={},{}
    for _,s in ipairs(stages) do
        if s.saved then
            sources['pipeline_'..s.id..'.bin']=s.saved.dir..'/champion.bin'
            if not s.opponent then represented[s.class]=true end
        end
    end
    local names={}; for name in pairs(sources) do names[#names+1]=name end; table.sort(names)
    if #names==0 then status='No saved champions to evaluate. Train a kit first.'; return false end
    runDir=root..'/evaluation_runs/'..os.date('%Y%m%d-%H%M%S')..'-'..tostring(love.timer.getTime()):gsub('%.','-')
    local commands={'mkdir -p '..quote(runDir..'/models')..' '..quote(root..'/matches')}
    local manifest={}
    for _,name in ipairs(names) do
        commands[#commands+1]='cp '..quote(sources[name])..' '..quote(runDir..'/models/'..name)
        manifest[#manifest+1]=name..' <- '..sources[name]
    end
    commands[#commands+1]='printf %s '..quote(table.concat(manifest,'\n')..'\n')..' > '..quote(runDir..'/sources.txt')
    commands[#commands+1]='cd '..quote(root)
    commands[#commands+1]=quote(engineRoot..'/zig-out/bin/pvp_sim')..' --eval-matrix '..quote(runDir..'/models')
        ..' --matrix-duels 32 --matrix-out '..quote(root..'/spec_matrix.lua')
        ..' --record-all-matches '..quote(root..'/matches')
    channel=love.thread.newChannel()
    worker=love.thread.newThread([[
        local command,channel=...
        local ok,reason,code=os.execute(command)
        channel:push({success=ok==true or ok==0, code=code or tostring(ok)})
    ]])
    local setup=table.remove(commands,1)
    local command=setup..' && ( '..table.concat(commands,' && ')..' ) > '..quote(runDir..'/evaluation.log')..' 2>&1'
    local ok,err=pcall(function() worker:start(command,channel) end)
    if not ok then status='Evaluation worker failed: '..tostring(err); return false end
    active=true; status='Evaluating '..#names..' champions and recording fights...'
    return true
end
function evaluation.update()
    if not active then return end
    local result=channel:pop(); local err=worker:getError()
    if not result and not err then return end
    active=false
    if err or not result.success then
        status='Evaluation failed. See '..runDir..'/evaluation.log'
    else
        revision=revision+1
        status='Matrix + replays updated '..os.date('%Y-%m-%d %H:%M:%S')
    end
    local f=io.open(root..'/evaluation-status.txt','w'); if f then f:write(status); f:close() end
end
return evaluation
