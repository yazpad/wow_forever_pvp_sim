local ui = require("ui")
-- Supported simulator kits and directed training stages. Artifacts stay in training_runs.
local pipeline = {}
local json = require('json')
local evaluation = require('evaluation')

-- Two organized sets of stages:
-- Set 1: Base Sets (General class kits trained via self-play)
-- Set 2: Target Spec Pairs (Specialized matchup training seeded from base)
local stages = {
    {id='base_warlock', name='Warlock Base', class='warlock', set='base'},
    {id='base_frost_mage', name='Frost Mage Base', class='frost_mage', set='base'},
    {id='warlock_vs_frost_mage', name='Warlock (Target vs Frost Mage)', class='warlock', opponent='frost_mage', set='spec'},
    {id='frost_mage_vs_warlock', name='Frost Mage (Target vs Warlock)', class='frost_mage', opponent='warlock', set='spec'},
}

local activeTab = 'base' -- 'base' or 'spec'
local root, controller, queue, current, message, buttons, legacy = nil, nil, nil, nil, '', {}, {}

local function read(path)
    local f=io.open(path,'rb'); if not f then return end
    local s=f:read('*a'); f:close(); return s
end

local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

local function base(class)
    for _, s in ipairs(stages) do if s.class==class and not s.opponent then return s end end
end

function pipeline.refresh()
    for _, s in ipairs(stages) do s.saved=nil; s.latest=nil end
    legacy={warlock=0, frost_mage=0}
    if love.system.getOS()=='Windows' then return end
    local p=io.popen('find '..quote(root..'/training_runs')..' -mindepth 1 -maxdepth 1 -type d 2>/dev/null')
    if not p then return end
    local dirs={}; for dir in p:lines() do dirs[#dirs+1]=dir end; p:close(); table.sort(dirs)
    for _, dir in ipairs(dirs) do
        local id=read(dir..'/pipeline-stage.txt')
        local state=read(dir..'/pipeline-state.txt') or 'interrupted'
        local found=false
        for _, s in ipairs(stages) do
            if id==s.id then
                found=true
                s.latest={dir=dir, state=state}
                if (state=='completed' or state=='stopped') and read(dir..'/champion.bin') and read(dir..'/population.pop') then
                    local ok,m=pcall(json.decode,read(dir..'/metrics.json') or '')
                    local last=ok and m and m.generations and m.generations[#m.generations]
                    s.saved={dir=dir, generation=last and last.generation or 0, state=state}
                end
            end
        end
        if not found then
            local data=read(dir..'/metrics.json')
            if data then
                local class=data:find('Ice Lance',1,true) and 'frost_mage' or 'warlock'
                legacy[class]=legacy[class]+1
            end
        end
    end
end

function pipeline.load(projectRoot, training)
    root,controller=projectRoot,training; pipeline.refresh()
end

local function ready(s)
    if not s.opponent then return true end
    return base(s.class).saved and base(s.opponent).saved
end

local function launch(s)
    if not ready(s) then message='Train both base kits before starting this matchup.'; return false end
    local own=s.saved or (s.opponent and base(s.class).saved)
    local config={class=s.class, opponent=s.opponent or '', stage=s.id,
        resume=s.saved and s.saved.dir..'/population.pop' or '',
        seed=not s.saved and own and own.dir..'/champion.bin' or '',
        sparring=s.opponent and base(s.opponent).saved.dir..'/champion.bin' or ''}
    controller.configureStage(config)
    controller.start()
    if controller.isActive() then current=s; message=''; return true end
    message=controller.getStatus(); return false
end

function pipeline.startStage(index)
    if controller.isActive() then return end
    queue=nil; launch(stages[index])
end

function pipeline.startAll()
    if controller.isActive() then return end
    queue={}
    for _,s in ipairs(stages) do
        if not s.saved or s.saved.state~='completed' then queue[#queue+1]=s end
    end
    if #queue==0 then queue=nil; pipeline.evaluate(); return end
    local s=table.remove(queue,1); if not launch(s) then queue=nil end
end

function pipeline.startBases()
    if controller.isActive() then return end
    queue = {}
    for _, s in ipairs(stages) do
        if not s.opponent and (not s.saved or s.saved.state ~= 'completed') then
            queue[#queue + 1] = s
        end
    end
    if #queue == 0 then queue = nil; pipeline.evaluate(); return end
    local s = table.remove(queue, 1); if not launch(s) then queue = nil end
end

function pipeline.startMissingPairs()
    if controller.isActive() then return end
    queue = {}
    for _, s in ipairs(stages) do
        if s.opponent and (not s.saved or s.saved.state ~= 'completed') then
            queue[#queue + 1] = s
        end
    end
    if #queue == 0 then queue = nil; pipeline.evaluate(); return end
    local s = table.remove(queue, 1); if not launch(s) then queue = nil end
end

function pipeline.stop()
    queue=nil; controller.stop()
end

function pipeline.evaluate()
    if controller.isActive() then return end
    message=''; controller.evaluate()
end

function pipeline.manualCompleted()
    if not current then pipeline.refresh(); pipeline.evaluate() end
end

function pipeline.update()
    if current and not controller.isActive() then
        local success=controller.getStatus():find('Completed',1,true)
        current=nil; pipeline.refresh()
        if success and queue and #queue>0 then
            local s=table.remove(queue,1); if not launch(s) then queue=nil end
        else
            queue=nil
            if success then pipeline.evaluate() end
        end
    end
end

function pipeline.getStages() return stages end

function pipeline.draw()
    local g=love.graphics; local w,h=ui.dimensions(); buttons={}
    g.clear(0.03,0.05,0.09)
    local function text(s,x,y,width,color)
        g.setColor(unpack(color or {0.9,0.94,1})); g.printf(s,x,y,width)
    end
    local function button(label,x,y,width,action,enabled)
        g.setColor(enabled and 0.12 or 0.07,0.18,0.28); g.rectangle('fill',x,y,width,28,4)
        text(label,x+6,y+7,width-12,enabled and {0.85,0.94,1} or {0.4,0.48,0.58})
        buttons[#buttons+1]={x=x,y=y,w=width,h=28,action=action,enabled=enabled}
    end

    -- Header
    text('Training pipeline',28,62,w-56)
    text('Set 1: Train Class in General (Self-Play)  |  Set 2: Spec vs Spec Matchup (Seeded from Base vs Sparring Opponent)',28,84,w-56,{0.6,0.75,0.88})

    -- Two Clear Navigation Tabs
    local tabW, tabH = 260, 32
    local t1X, t2X = 28, 28 + tabW + 14
    local tabY = 114

    local function drawNavTab(x, label, mode, count)
        local isSel = (activeTab == mode)
        g.setColor(isSel and 0.18 or 0.08, isSel and 0.38 or 0.14, isSel and 0.60 or 0.22, 0.95)
        g.rectangle('fill', x, tabY, tabW, tabH, 5)
        g.setColor(isSel and 0.35 or 0.15, isSel and 0.70 or 0.25, isSel and 0.95 or 0.35, 0.9)
        g.rectangle('line', x, tabY, tabW, tabH, 5)
        g.setColor(1, 1, 1, isSel and 1.0 or 0.65)
        g.printf(label, x, tabY + 8, tabW, 'center')
        buttons[#buttons+1] = { x = x, y = tabY, w = tabW, h = tabH, action = function() activeTab = mode end, enabled = true }
    end

    drawNavTab(t1X, "1. Base Training (Class in General)", "base", 2)
    drawNavTab(t2X, "2. Spec vs Spec Specialization", "spec", 2)

    -- Filter stages for active tab
    local currentStages = {}
    for idx, s in ipairs(stages) do
        if s.set == activeTab then
            currentStages[#currentStages+1] = { stage = s, globalIdx = idx }
        end
    end

    local cardW = (w - 68) / 2
    for pos, item in ipairs(currentStages) do
        local s = item.stage
        local globalIdx = item.globalIdx
        local x = 28 + ((pos - 1) % 2) * (cardW + 12)
        local y = 164 + math.floor((pos - 1) / 2) * 130
        g.setColor(0.07,0.12,0.19); g.rectangle('fill',x,y,cardW,118,5)
        text(s.name,x+14,y+12,cardW-28)

        local state = current==s and controller.isActive() and 'Status: Currently Training...' or
            (s.saved and (s.saved.state=='stopped' and 'Status: Checkpoint Paused' or 'Status: Model Ready')..' | Gen '..s.saved.generation) or
            (ready(s) and 'Status: Ready to Train' or 'Status: Locked (Needs both Base Champions)')
        if s.latest and s.latest.state=='failed' then state=state..' | Failed' end
        text(state,x+14,y+36,cardW-28,{0.4,0.8,1})

        local subtitle = s.set == 'base' and 'Self-play baseline training from scratch' or
            string.format('Seeded from %s base champion, sparring vs %s', s.class, s.opponent or '')
        text(subtitle, x+14, y+58, cardW-28, {0.6, 0.7, 0.8})

        button(s.saved and 'Continue Training' or 'Train Model', x+14, y+80, 160, function() pipeline.startStage(globalIdx) end, not controller.isActive() and not not ready(s))
        if s.saved then text('Champion .bin saved', x+185, y+87, cardW-195, {0.6,0.85,0.6}) end
    end

    -- Bottom Controls
    local ctrlY = 405
    if activeTab == 'base' then
        button('Train All Bases', 28, ctrlY, 150, pipeline.startBases, not controller.isActive())
    else
        button('Train Missing Pairs', 28, ctrlY, 170, pipeline.startMissingPairs, not controller.isActive())
    end
    button('Train All Stages', 208, ctrlY, 140, pipeline.startAll, not controller.isActive())
    button('Stop & Save', 358, ctrlY, 115, pipeline.stop, controller.isActive() and not evaluation.isActive())
    button('Live Graphs', 483, ctrlY, 115, function() controller.setView('graphs') end, true)
    button('Settings', 608, ctrlY, 85, function() return 'settings' end, true)
    button('Evaluate Matrix', 703, ctrlY, 135, pipeline.evaluate, not controller.isActive())
    button('Refresh', 848, ctrlY, 80, pipeline.refresh, not controller.isActive())

    text(message~='' and message or controller.getStatus(), 28, 448, w-56)
    text('Evaluation updates both "Base Set Matrix" and "Spec vs Spec Matrix" automatically without mixing bots or legacy models.', 28, 480, w-56, {0.6,0.75,0.88})
    if current and h>575 then
        text('Active: '..current.name..' | '..controller.getSummary()..'\n'..(controller.getRunDirectory() or ''), 28, 540, w-56)
    end
end

function pipeline.mousepressed(x,y)
    for _,b in ipairs(buttons) do
        if x>=b.x and x<=b.x+b.w and y>=b.y and y<=b.y+b.h and b.enabled then return b.action() end
    end
end

return pipeline
