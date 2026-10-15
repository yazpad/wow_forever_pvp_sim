local json = require("json")
local ui = require("ui")
local class_view = require("class_view")
local view = {}
local data, match, searchPath, searchBytes
local selected, side, scroll, resultScroll = 1, 0, 0, 0
local reports, thread, channel, job = {}, nil, nil, nil
local generation = 0
local status = "Select a decision to inspect its alternatives."
local samples, budgetMultiplier = 8, 2
local lastProgressPoll = 0
local hits = {}

local function readJson(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a"); f:close()
    local ok, value = pcall(json.decode, content)
    return ok and value or nil, content
end
local function quote(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
local function key() return tostring(selected) .. ":" .. tostring(side) end
local function name(action, who)
    local movement = action.movement == -1 and "advance" or action.movement == 1 and "kite" or "stand"
    return class_view.name(match and match.meta, who or side, action.ability) .. " / " .. movement
end
function view.load(path, replay)
    if job then
        local f = io.open(job.stop, "w"); if f then f:close() end
    end
    generation = generation + 1
    data, match, reports = nil, replay, {}
    selected, side, scroll, resultScroll = 1, 0, 0, 0
    searchPath = path:gsub("%.lua%.json$", ".lua") .. ".search.json"
    data, searchBytes = readJson(searchPath)
    status = data and (data.simulator_fingerprint and "Same simulator and MCTS as fight generation. Select a move to run deeper analysis." or "Legacy fight: source identity unavailable. New recordings verify matching mechanics.") or "This replay has no saved search decisions. Generate a new MCTS fight to analyze it."
end
local function choose(index)
    if not data then return end
    selected = math.max(1, math.min(#data.decisions, index))
    resultScroll = 0
end
function view.update()
    if not thread then return end
    local err = thread:getError()
    local msg = channel:pop()
    if not err and not msg then
        if job and not job.cancelled and job.generation == generation and love.timer.getTime() - lastProgressPoll > 0.5 then
            lastProgressPoll = love.timer.getTime()
            local progress = readJson(job.output .. ".progress.json")
            if progress then
                status = string.format("MCTS: move %d/%d, seed %d/%d | %d rollouts/decision, %d workers | %d searches completed",
                    progress.completed_candidates + 1, progress.total_candidates, progress.completed_samples + 1, progress.samples,
                    progress.rollouts_per_decision, progress.workers, progress.search_decisions)
            end
        end
        return
    end
    if job and job.generation == generation then
        if err or not msg.ok then
            local reason = tostring(err or msg.error)
            if reason:find("SimulatorSourceMismatch", 1, true) then
                status = "Simulator source changed since this fight. Generate a new fight to verify matching mechanics."
            else status = "Analysis stopped: " .. (reason:match("[^\r\n]+") or "Unknown error") end
        else
            local report = readJson(job.output)
            if report and report.tick == job.tick and report.side == job.side then
                reports[job.key] = report
                status = report.engine_verified and "Complete. Source verified; both players used production MCTS throughout each continuation." or "Complete with production MCTS. Legacy recording: original simulator source cannot be verified."
            else status = "Analysis returned an invalid report." end
        end
    end
    thread, channel, job = nil, nil, nil
end
function view.run()
    if job or not data or not data.decisions[selected] then return end
    local decision = data.decisions[selected]
    -- A single-choice side is often waiting for its next decision boundary.
    if decision.choices[side + 1].len <= 1 then
        status = "This player had no decision here. Select another row or player."
        return
    end
    local binary = "zig-out/bin/fight_analysis"
    local f = io.open(binary, "rb")
    if not f then binary = "../" .. binary; f = io.open(binary, "rb") end
    if not f then status = "Build the analysis engine with zig build -Doptimize=ReleaseSafe."; return end
    f:close()
    if not love.filesystem.createDirectory("fight_analysis") then status = "Unable to create the analysis results directory."; return end
    local prefix = love.filesystem.getSaveDirectory() .. "/fight_analysis/run-" .. tostring(os.time()) .. "-" .. tostring(math.floor(love.timer.getTime() * 1000))
    job = { generation = generation, path = searchPath, input = prefix .. ".search.json", key = key(), tick = decision.tick, side = side, output = prefix .. ".json", stop = prefix .. ".stop" }
    local input = io.open(job.input, "w")
    if not input then job = nil; status = "Unable to save the analysis input."; return end
    input:write(searchBytes); input:close()
    local command = table.concat({ quote(binary), "--input", quote(job.input), "--output", quote(job.output),
        "--decision", tostring(selected - 1), "--side", tostring(side), "--samples", tostring(samples), "--budget-multiplier", tostring(budgetMultiplier), "--workers", "2", "--seed", "947", "--stop-file", quote(job.stop) }, " ")
    channel = love.thread.newChannel()
    thread = love.thread.newThread([[
        local command, logPath, channel = ...
        local ok = os.execute(command .. " > " .. "'" .. logPath:gsub("'", "'\\''") .. "'" .. " 2>&1")
        local f = io.open(logPath, "r")
        local log = f and f:read("*a") or "Unable to read analysis log."
        if f then f:close() end
        channel:push({ok = ok == true or ok == 0, error = log})
    ]])
    thread:start(command, prefix .. ".log", channel)
    status = string.format("Starting MCTS analysis: decision %d, player %s, %d seeds per move, %dx original rollout budget...", selected, side == 0 and "A" or "B", samples, budgetMultiplier)
end
local function button(id, label, x, y, w)
    local mx, my = ui.contentPoint(love.mouse.getPosition())
    ui.drawCard(x, y, w, 30, false, (id == "a" and side == 0) or (id == "b" and side == 1))
    ui.tab(x, y, w, 30, label, id == "run" and not job, mx >= x and mx <= x+w and my >= y and my <= y+30)
    hits[#hits+1] = {id=id,x=x,y=y,w=w,h=30}
end
local function text(value, x, y, color, font)
    ui.setFont(font or "normal")
    love.graphics.setColor(unpack(color or ui.colors.text))
    love.graphics.print(value, x, y)
end
function view.draw()
    local g, w, h = love.graphics, ui.width(), ui.height()
    hits = {}
    text("Fight analysis", 22, 16, nil, "header")
    text("Every alternative uses the production combat simulator, with MCTS choosing subsequent moves for both players.", 22, 45, ui.colors.textMuted)
    if not data or not data.decisions or #data.decisions == 0 then
        text(status, 22, 90, ui.colors.textMuted)
        return
    end
    button("a", "Player A", 22, 76, 100)
    button("b", "Player B", 128, 76, 100)
    button("run", job and "Running..." or "Evaluate move", 240, 76, 150)
    button("samples", tostring(samples) .. " seeds", 400, 76, 100)
    button("budget", tostring(budgetMultiplier) .. "x search", 510, 76, 100)
    button("seek", "View in arena", 620, 76, 140)
    if job then button("cancel", "Cancel", 770, 76, 90) end
    text("Selected: " .. (side == 0 and (match.meta.name_a or "A") or (match.meta.name_b or "B")), 22, 116, ui.colors.accentGold)
    ui.setFont("small"); g.setColor(unpack(ui.colors.textMuted)); g.printf(status, 22, 140, w-44)
    local top, left = 180, math.min(360, w * 0.32)
    local visible = math.max(1, math.floor((h - top - 30) / 36))
    scroll = math.max(0, math.min(scroll, math.max(0, #data.decisions-visible)))
    ui.drawCard(16, top-6, left, h-top-10, false, false)
    for row=1,visible do
        local index = row + scroll
        local decision = data.decisions[index]
        if not decision then break end
        local y = top + (row-1)*36
        local chosen = decision.actions[side+1]
        ui.tab(22,y,left-12,32,string.format("%5.2fs  %s",decision.tick/100,name(chosen)),selected==index,false)
        hits[#hits+1] = {id="decision",index=index,x=22,y=y,w=left-12,h=32}
    end
    local d, x = data.decisions[selected], left+36
    local report = reports[key()]
    text(string.format("Decision %d of %d  |  %.2fs", selected,#data.decisions,d.tick/100), x, top, nil,"title")
    text("Played: " .. name(d.actions[side+1]),x,top+28,ui.colors.accentGold)
    local rows = {}
    if report then
        text(string.format("At decision: A %.0f HP / B %.0f HP",report.hp[1],report.hp[2]),x,top+52,ui.colors.textMuted)
        local played
        for _,r in ipairs(report.results) do if r.chosen then played=r; break end end
        if played then text(string.format("Played: %d wins, %d losses, %d draws, %d unfinished", played.wins, played.losses, played.draws, played.unresolved),x,top+76,ui.colors.accentGold,"small") end
        text(string.format("%d seeds/move | %d rollouts/decision | %d workers", report.samples, report.continuation_search.rollouts, report.continuation_search.workers),x,top+100,nil,"semibold")
        text("W / L / draw / unfinished. Delta vs played; +/- is ~2 standard errors.",x,top+123,ui.colors.textMuted,"small")
        for _,r in ipairs(report.results) do rows[#rows+1]=r end
        table.sort(rows,function(a,b) if a.score==b.score then return a.mean_hp_margin>b.mean_hp_margin end return a.score>b.score end)
    else
        text("Original search allocation (not win probability)",x,top+70,nil,"semibold")
        text("Evaluate all legal moves with deeper MCTS through the fight's time limit.",x,top+96,ui.colors.textMuted,"small")
        local choices = d.choices[side+1]
        for i=1,choices.len do
            rows[#rows+1]={action=choices.items[i],allocation=(d.strategies[side+1][i] or 0),chosen=choices.items[i].ability==d.actions[side+1].ability and choices.items[i].movement==d.actions[side+1].movement}
        end
        table.sort(rows,function(a,b)return a.allocation>b.allocation end)
    end
    local rowY=top+154
    local count=math.max(1,math.floor((h-rowY-56)/42))
    resultScroll=math.max(0,math.min(resultScroll,math.max(0,#rows-count)))
    for i=1,count do
        local r=rows[i+resultScroll]
        if not r then break end
        local y=rowY+(i-1)*42
        g.setColor(0.10,0.14,0.21,0.9);g.rectangle("fill",x,y,w-x-22,38,4)
        text((r.chosen and "* " or "  ")..name(r.action),x+8,y+3,r.chosen and ui.colors.accentGold or ui.colors.text,"small")
        if report then
            text(string.format("%d / %d / %d / %d    HP margin %+.0f    delta %+.1f +/- %.1f pp",r.wins,r.losses,r.draws,r.unresolved,r.mean_hp_margin,r.delta_vs_chosen*100,r.paired_standard_error*200),x+8,y+20,ui.colors.textMuted,"small")
        else
            text(string.format("%.1f%% of original search allocation",r.allocation*100),x+8,y+20,ui.colors.textMuted,"small")
        end
    end
    text("* Played move. Scroll either pane. Left/right: decision. A/B: player. Enter: evaluate.",x,h-30,ui.colors.textDim,"small")
    ui.resetFont()
end
function view.mousepressed(x,y,button)
    if button~=1 then return end
    for _,hit in ipairs(hits) do
        if x>=hit.x and x<=hit.x+hit.w and y>=hit.y and y<=hit.y+hit.h then
            if hit.id=="decision" then choose(hit.index)
            elseif hit.id=="a" then side=0;resultScroll=0
            elseif hit.id=="b" then side=1;resultScroll=0
            elseif hit.id=="run" then view.run()
            elseif hit.id=="samples" then samples=samples==8 and 16 or samples==16 and 32 or 8
            elseif hit.id=="budget" then budgetMultiplier=budgetMultiplier==2 and 4 or budgetMultiplier==4 and 8 or 2
            elseif hit.id=="seek" then return data.decisions[selected].tick/100
            elseif hit.id=="cancel" and job then job.cancelled=true; local f=io.open(job.stop,"w");if f then f:close() end;status="Stopping analysis..." end
            return
        end
    end
end
function view.keypressed(key)
    if key=="left" then choose(selected-1)
    elseif key=="right" then choose(selected+1)
    elseif key=="a" then side=0;resultScroll=0
    elseif key=="b" then side=1;resultScroll=0
    elseif key=="return" then view.run() end
    if selected<=scroll then scroll=selected-1 end
    local visible=math.max(1,math.floor((ui.height()-210)/36))
    if selected>scroll+visible then scroll=selected-visible end
end
function view.wheelmoved(y)
    local x=ui.contentPoint(love.mouse.getPosition())
    if x<math.min(360,ui.width()*0.32)+28 then scroll=scroll-y*3 else resultScroll=resultScroll-y*3 end
end
return view
