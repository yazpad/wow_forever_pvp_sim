local ui = require("ui")
local class_view = require("class_view")
-- PVP_SIM: 2D NEURAL COMBAT ARENA (Love2D Native Visualizer)
local json = require("json")
local graphs = require("graphs")
local training = require("training")
local evaluation = require("evaluation")
local evaluationRevision = 0
local quitAfterTraining = false
local matrix_view = require("matrix_view")
local match_browser = require("match_browser")
local icons = require("icons_manager")
local meta_health = require("meta_health")

local MATCH_DATA = nil
local currentTime = 0.0
local isPlaying = true
local playbackSpeed = 1.0
local speeds = { 0.25, 0.5, 1.0, 2.0, 4.0 }
local speedIdx = 3

-- View Tab: "arena" | "graphs" | "fights" | "matrix" | "health" | "training"
local currentTab = "arena"
local TABS = {
    { id = "arena", label = "Arena [F1]" },
    { id = "graphs", label = "Graphs [F2]" },
    { id = "fights", label = "Fights [F3]" },
    { id = "matrix", label = "Matrix [F4]" },
    { id = "health", label = "Spec Meta [F5]" },
    { id = "training", label = "Training [F6]" },
}

-- Camera state for smooth zoom and pan
local camera = {
    x = 0.0,
    y = 0.0,
    zoom = 1.0,
    minZoom = 0.45,
    maxZoom = 3.0,
    isDragging = false,
    dragButton = 2,
    dragStartX = 0,
    dragStartY = 0,
    origPanX = 0,
    origPanY = 0,
}

local fctList = {}
local projectiles = {}
local particles = {}
local activeCombatLog = {}

local SPELL_NAMES = {
    [0] = "Idle",
    [1] = "Agony",
    [2] = "Corruption",
    [3] = "Fear",
    [4] = "Shadow Bolt",
    [5] = "Drain Life",
    [6] = "Unending Resolve",
    [7] = "Death Coil",
    [8] = "Cancel Cast",
}

local currentMatchPath = "last_match.lua"

local function loadMatchFile(path)
    currentMatchPath = path
    local file, err = io.open(path, "r")
    if not file then
        path = "../" .. path
        file = io.open(path, "r")
    end

    if not file then
        print("Warning: Could not open match file '" .. path .. "': " .. tostring(err))
        return false
    end
    file:close()

    if path:match("%.lua$") then
        local fn, loadErr = loadfile(path)
        if fn then
            MATCH_DATA = fn()
            print("Loaded match from Lua: " .. path)
            return true
        else
            print("Error parsing Lua match: " .. tostring(loadErr))
        end
    else
        local f = io.open(path, "r")
        local content = f:read("*a")
        f:close()
        MATCH_DATA = json.decode(content)
        print("Loaded match from JSON: " .. path)
        return true
    end
    return false
end

function love.load(arg)
    love.graphics.setBackgroundColor(0.03, 0.05, 0.09)
    icons.load()
    training.load()

    local path = "last_match.lua"
    local metricsPath = "training_metrics.lua"
    local matrixPath = "spec_matrix.lua"

    if arg then
        for i = 1, #arg do
            if arg[i] == "--training" then
                currentTab = "training"
            elseif arg[i] == "--graphs" then
                currentTab = "graphs"
                if arg[i + 1] and not arg[i + 1]:match("^%-%-") then
                    metricsPath = arg[i + 1]
                end
            elseif arg[i] == "--matrix" then
                currentTab = "matrix"
                if arg[i + 1] and not arg[i + 1]:match("^%-%-") then
                    matrixPath = arg[i + 1]
                end
            elseif arg[i] == "--fights" then
                currentTab = "fights"
            elseif arg[i]:match("metrics") then
                metricsPath = arg[i]
            elseif arg[i]:match("matrix") then
                matrixPath = arg[i]
            elseif not arg[i]:match("^%-%-") then
                path = arg[i]
            end
        end
    end

    -- Load sub-modules
    graphs.loadMetricsFile(metricsPath)
    matrix_view.loadMatrixFile(matrixPath)
    match_browser.scanMatchesDir("matches")
    meta_health.loadStatusFile("spec_status.lua")

    if not loadMatchFile(path) then
        if not loadMatchFile("last_match.json") then
            -- Fallback demo data
            MATCH_DATA = {
                meta = {
                    name_a = "Shadowcaller A",
                    name_b = "Felbinder B",
                    elo_a = 2840.5,
                    elo_b = 2620.2,
                    victor = 0,
                    total_time = 15.0,
                    dmg_a = 2000.0,
                    dmg_b = 1200.0,
                    heal_a = 480.0,
                    heal_b = 180.0,
                },
                events = {},
                frames = {},
            }
            for i = 0, 1500 do
                local t = i * 0.01
                local dist = math.max(6.0, 25.0 - t * 1.2)
                local hp_a = math.max(0.0, 2000.0 - t * 60.0)
                local hp_b = math.max(0.0, 2000.0 - t * 133.3)
                table.insert(MATCH_DATA.frames, {
                    t, dist, -dist*0.5, dist*0.5,
                    hp_a, hp_b, 1000.0, 1000.0,
                    0, 0,
                    (t > 3 and t < 5) and 4 or 0, (t > 6 and t < 9) and 5 or 0,
                    1.8, 3.0, 1.8, 3.0,
                    (t > 1) and 12.0 or 0, 0, (t > 2) and 10.0 or 0, 0,
                    0, 0, 0, 0,
                    (t > 8 and t < 14) and 6.0 or 0, 0, 0, 0,
                    0, 0,
                    0, 0, 0, 0,
                    0, 0, 0, 0,
                    1, 1
                })
            end
        end
    end

    currentTime = 0.0
    isPlaying = true
    fctList = {}
    projectiles = {}
    particles = {}
    activeCombatLog = {}

    if MATCH_DATA and MATCH_DATA.events then
        for i = 1, math.min(#MATCH_DATA.events, 40) do
            local ev = MATCH_DATA.events[i]
            local spName = class_view.name(MATCH_DATA.meta, ev.s, ev.sp)
            local text = string.format("[%.2fs] %s used %s", ev.t, ev.s == 0 and "A" or "B", spName)
            table.insert(activeCombatLog, text)
        end
    end
end

local function getFrameAtTime(t)
    if not MATCH_DATA or not MATCH_DATA.frames or #MATCH_DATA.frames == 0 then return nil end
    local totalTime = MATCH_DATA.meta.total_time
    local num = #MATCH_DATA.frames
    local dt = num > 1 and (totalTime / (num - 1)) or 0.01
    local idx = math.floor(t / dt) + 1
    if idx < 1 then idx = 1 end
    if idx > num then idx = num end
    return MATCH_DATA.frames[idx]
end

local nextEventIdx = 1

local function resetEventsToTime(t)
    fctList = {}
    projectiles = {}
    particles = {}
    nextEventIdx = 1
    if MATCH_DATA and MATCH_DATA.events then
        while nextEventIdx <= #MATCH_DATA.events and MATCH_DATA.events[nextEventIdx].t < t do
            nextEventIdx = nextEventIdx + 1
        end
    end
end

local function addFCT(x, y, text, color, scale)
    if #fctList >= 14 then
        table.remove(fctList, 1)
    end
    table.insert(fctList, {
        x = x + (math.random() - 0.5) * 28,
        y = y - 32,
        vy = -45 - math.random() * 20,
        text = text,
        color = color or { 1, 1, 1 },
        scale = scale or 1.0,
        alpha = 1.0,
        life = 0.95,
    })
end

-- Convert simulation world position (-20m to +20m) to arena coordinate space
local function worldToArenaX(wX)
    local arenaSpan = 1000.0
    local norm = (wX + 20.0) / 40.0
    return (norm - 0.5) * arenaSpan
end

local function checkEvents(currT, frame)
    if not MATCH_DATA or not MATCH_DATA.events then return end
    local events = MATCH_DATA.events

    if nextEventIdx > 1 and nextEventIdx <= #events and events[nextEventIdx].t > currT + 0.1 then
        resetEventsToTime(currT)
    end

    while nextEventIdx <= #events and events[nextEventIdx].t <= currT do
        local ev = events[nextEventIdx]
        nextEventIdx = nextEventIdx + 1

        local targetX = ev.tg == 0 and worldToArenaX(frame[3]) or worldToArenaX(frame[4])
        local srcX = ev.s == 0 and worldToArenaX(frame[3]) or worldToArenaX(frame[4])

        if ev.k == 4 then -- Direct Hit (Shadow Bolt or Death Coil)
            local isDc = (ev.sp == 7 and class_view.spec(MATCH_DATA.meta, ev.s) == "warlock")
            local col = isDc and { 0.2, 0.95, 0.4 } or { 0.95, 0.45, 1.0 }
            local label = isDc and string.format("DEATH COIL -%d", math.floor(ev.a + 0.5)) or string.format("-%d", math.floor(ev.a + 0.5))
            addFCT(targetX, -60, label, col, isDc and 1.6 or 1.4)

            if not isDc then
                table.insert(projectiles, {
                    kind = "shadowbolt",
                    sx = srcX, sy = -20,
                    tx = targetX, ty = -20,
                    progress = 0.0,
                    duration = 0.22,
                    color = class_view.spec(MATCH_DATA.meta, ev.s) == "frost_mage" and {0.3, 0.8, 1} or { 0.85, 0.45, 1.0 },
                })
            end
        elseif ev.k == 10 then -- Death Coil Launched
            table.insert(projectiles, {
                kind = "deathcoil",
                sx = srcX, sy = -20,
                tx = targetX, ty = -20,
                progress = 0.0,
                duration = 0.28,
                color = { 0.1, 0.95, 0.35 },
            })
        elseif ev.k == 5 then -- Periodic DOT or Siphon Pulse
            local isDrain = (ev.sp == 5)
            local col = isDrain and { 0.25, 0.9, 0.55 } or { 0.85, 0.45, 0.95 }
            local label = isDrain and string.format("Siphon -%d", math.floor(ev.a + 0.5)) or string.format("-%d", math.floor(ev.a + 0.5))
            addFCT(targetX, -45, label, col, 1.0)
        elseif ev.k == 6 then -- Siphon / Death Coil Heal
            local isDc = (ev.sp == 7 and class_view.spec(MATCH_DATA.meta, ev.s) == "warlock")
            local label = isDc and string.format("+%d Siphon Heal", math.floor(ev.a + 0.5)) or string.format("+%d", math.floor(ev.a + 0.5))
            addFCT(srcX, -70, label, { 0.2, 0.98, 0.4 }, isDc and 1.4 or 1.1)
        elseif ev.k == 3 then -- Interrupt
            addFCT(srcX, -85, "INTERRUPTED!", { 0.98, 0.2, 0.2 }, 1.5)
        elseif ev.k == 7 then -- Feared
            addFCT(targetX, -85, class_view.spec(MATCH_DATA.meta, ev.s) == "frost_mage" and "POLYMORPH!" or "FEARED!", { 0.85, 0.55, 1.0 }, 1.4)
        elseif ev.k == 11 then -- Horror Applied
            addFCT(targetX, -85, "HORRIFIED!", { 0.2, 0.95, 0.5 }, 1.5)
        elseif ev.k == 12 then
            addFCT(targetX, -85, "ROOTED!", {0.3, 0.8, 1}, 1.4)
        elseif ev.k == 13 then
            addFCT(srcX, -85, "BLINK", {0.3, 0.8, 1}, 1.4)
        elseif ev.k == 14 then
            addFCT(targetX, -85, "COUNTERSPELL", {0.3, 0.8, 1}, 1.4)
        elseif ev.k == 9 then -- Defensive
            addFCT(srcX, -80, class_view.spec(MATCH_DATA.meta, ev.s) == "frost_mage" and "ICE BARRIER" or "UNENDING RESOLVE (-40%)", { 0.2, 0.85, 1.0 }, 1.3)
        end
    end
end

function love.update(dt)
    training.update(dt)
    meta_health.update(dt, training)
    if evaluation.getRevision() ~= evaluationRevision then
        evaluationRevision = evaluation.getRevision()
        matrix_view.loadMatrixFile("spec_matrix.lua")
        match_browser.scanMatchesDir("matches")
    end
    if quitAfterTraining and not training.isActive() then love.event.quit(); return end
    if currentTab == "training" then return end
    if currentTab == "graphs" then
        graphs.update(dt)
        return
    elseif currentTab == "matrix" then
        matrix_view.update(dt)
        return
    elseif currentTab == "fights" then
        match_browser.update(dt)
        return
    end

    if not MATCH_DATA then return end
    local maxTime = MATCH_DATA.meta.total_time

    if isPlaying then
        currentTime = currentTime + dt * playbackSpeed
        if currentTime >= maxTime then
            currentTime = maxTime
            isPlaying = false
        end
    end

    local frame = getFrameAtTime(currentTime)
    if frame and isPlaying then
        checkEvents(currentTime, frame)
    end

    -- Update FCT
    for i = #fctList, 1, -1 do
        local item = fctList[i]
        item.y = item.y + item.vy * dt
        item.alpha = item.alpha - dt / item.life
        if item.alpha <= 0 then
            table.remove(fctList, i)
        end
    end

    -- Update Projectiles
    for i = #projectiles, 1, -1 do
        local p = projectiles[i]
        p.progress = p.progress + dt / p.duration

        -- Emit trailing particles
        if math.random() < 0.6 then
            local curX = p.sx + (p.tx - p.sx) * p.progress
            local curY = p.sy + (p.ty - p.sy) * p.progress
            table.insert(particles, {
                x = curX, y = curY + (math.random() - 0.5) * 8,
                vx = (math.random() - 0.5) * 20,
                vy = (math.random() - 0.5) * 20,
                alpha = 0.8,
                color = p.color,
                size = 3.0,
            })
        end

        if p.progress >= 1.0 then
            -- Impact burst
            local sparkCount = p.kind == "deathcoil" and 24 or 14
            for s = 1, sparkCount do
                local ang = math.random() * math.pi * 2
                local spd = 60 + math.random() * 90
                table.insert(particles, {
                    x = p.tx, y = p.ty,
                    vx = math.cos(ang) * spd,
                    vy = math.sin(ang) * spd,
                    alpha = 1.0,
                    color = p.color,
                    size = p.kind == "deathcoil" and 4.0 or 2.5,
                })
            end
            table.remove(projectiles, i)
        end
    end

    -- Update Particles
    for i = #particles, 1, -1 do
        local pt = particles[i]
        pt.x = pt.x + pt.vx * dt
        pt.y = pt.y + pt.vy * dt
        pt.alpha = pt.alpha - dt * 2.2
        if pt.alpha <= 0 then
            table.remove(particles, i)
        end
    end
end

local function drawDrainLifeBeam(sx, sy, tx, ty, c1, c2)
    love.graphics.setLineWidth(4)
    local steps = 18
    local prevX, prevY = sx, sy

    for s = 1, steps do
        local ratio = s / steps
        local px = sx + (tx - sx) * ratio
        local wave = math.sin((ratio * 16.0) - (currentTime * 20.0)) * 14.0
        local py = sy + (ty - sy) * ratio + wave

        love.graphics.setColor(c1[1] * (1 - ratio) + c2[1] * ratio, c1[2] * (1 - ratio) + c2[2] * ratio, c1[3] * (1 - ratio) + c2[3] * ratio, 0.88)
        love.graphics.line(prevX, prevY, px, py)
        prevX, prevY = px, py
    end
end

local function getDrBadge(tier, timer)
    if tier <= 0.0 and timer <= 0.0 then
        return nil
    elseif tier <= 1.0 then
        return { label = string.format("DR 50%% (%.1fs)", timer), color = { 0.95, 0.80, 0.20 } }
    elseif tier <= 2.0 then
        return { label = string.format("DR 25%% (%.1fs)", timer), color = { 0.98, 0.50, 0.15 } }
    else
        return { label = string.format("IMMUNE (%.1fs)", timer), color = { 0.95, 0.25, 0.25 } }
    end
end

local function drawPill(x, y, w, h, text, bgCol, textCol)
    love.graphics.setColor(bgCol[1], bgCol[2], bgCol[3], bgCol[4] or 0.92)
    love.graphics.rectangle("fill", x, y, w, h, 4)
    love.graphics.setColor(textCol[1], textCol[2], textCol[3], textCol[4] or 1.0)
    love.graphics.printf(text, x, y + 2, w, "center")
end

local function drawCombatant(x, y, hp, mana, cid, ctmr, ctot, agony, corrup, fear, horror, unDur, color, isLeft)
    local side = isLeft and 0 or 1
    local meta = MATCH_DATA and MATCH_DATA.meta
    -- 1. Unending Resolve Shield Dome (single clean subtle protective glow, no spinning arcs)
    if unDur > 0.0 then
        love.graphics.setColor(0.2, 0.75, 1.0, 0.20)
        love.graphics.circle("fill", x, y, 42)
        love.graphics.setColor(0.3, 0.85, 1.0, 0.85)
        love.graphics.setLineWidth(2)
        love.graphics.circle("line", x, y, 42)
    end

    -- 2. Token Core with Class Icon (clean token, single border)
    love.graphics.setColor(0.10, 0.13, 0.20, 1.0)
    love.graphics.circle("fill", x, y, 32)

    -- Draw Class Icon inside circular token
    local drawnClass = icons.drawClassIcon(class_view.classIcon(meta, side), x, y, 56)
    if not drawnClass then
        love.graphics.setColor(color[1], color[2], color[3], 1.0)
        local emblem = class_view.spec(meta, side) == "frost_mage" and "M" or "W"
        if horror > 0.0 then emblem = "H"
        elseif fear > 0.0 then emblem = "!"
        elseif unDur > 0.0 then emblem = "S" end
        love.graphics.printf(emblem, x - 15, y - 8, 30, "center")
    end

    -- Status overlay icon centered over character token if active CC/defensive
    if horror > 0.0 then
        icons.draw("horror", x, y, 34, 1, 0.3, 0.3, 0.95)
    elseif fear > 0.0 then
        icons.draw(class_view.aura(meta, side, "fear"), x, y, 34, 0.9, 0.5, 1, 0.95)
    elseif unDur > 0.0 then
        icons.draw(class_view.aura(meta, side, "unendingresolve"), x, y, 34, 0.4, 0.9, 1, 0.95)
    end

    -- Token Team Border
    love.graphics.setColor(color[1], color[2], color[3], 1.0)
    love.graphics.setLineWidth(3)
    love.graphics.circle("line", x, y, 32)

    -- Directional Eye Marker
    local isCC = (fear > 0.0 or horror > 0.0)
    local dir = isCC and (isLeft and -1 or 1) or (isLeft and 1 or -1)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.circle("fill", x + dir * 24, y, 4)

    -- 3. Overhead Health Bar & Buffs (Clean, no mana bar in world space)
    local barW = 110
    local halfW = barW * 0.5
    local hpY = y - 56

    -- Health Bar (HP only above character)
    local hpPct = math.max(0, math.min(1.0, hp / 2000.0))
    love.graphics.setColor(0.08, 0.10, 0.15, 0.9)
    love.graphics.rectangle("fill", x - halfW, hpY, barW, 13, 3)

    love.graphics.setColor(0.15 * (1 - hpPct) + 0.2 * hpPct, 0.85 * hpPct, 0.25 * (1 - hpPct), 1.0)
    love.graphics.rectangle("fill", x - halfW, hpY, barW * hpPct, 13, 3)

    love.graphics.setColor(0.2, 0.3, 0.4, 0.8)
    love.graphics.setLineWidth(1)
    love.graphics.rectangle("line", x - halfW, hpY, barW, 13, 3)

    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.printf(string.format("%d", math.floor(hp)), x - halfW, hpY, barW, "center")

    -- Buffs & Debuffs with Rotating Masks (Above health bar - clean, no numbers)
    local dbY = hpY - 26
    local dbSize = 22
    local dbSpacing = 25
    local auras = {}
    if horror > 0.0 then table.insert(auras, { icon = "horror", dur = horror, maxDur = 3.0, border = { 0.3, 0.9, 0.3, 1 } }) end
    if fear > 0.0 then table.insert(auras, { icon = class_view.aura(meta, side, "fear"), dur = fear, maxDur = class_view.auraDuration(meta, side, "fear"), border = { 0.85, 0.4, 1.0, 1 } }) end
    if agony > 0.0 then table.insert(auras, { icon = class_view.aura(meta, side, "agony"), dur = agony, maxDur = class_view.auraDuration(meta, side, "agony"), border = { 0.7, 0.3, 0.9, 1 } }) end
    if corrup > 0.0 then table.insert(auras, { icon = class_view.aura(meta, side, "corruption"), dur = corrup, maxDur = class_view.auraDuration(meta, side, "corruption"), border = { 0.95, 0.5, 0.2, 1 } }) end
    if unDur > 0.0 then table.insert(auras, { icon = class_view.aura(meta, side, "unendingresolve"), dur = unDur, maxDur = class_view.auraDuration(meta, side, "unendingresolve"), border = { 0.2, 0.85, 1.0, 1 } }) end

    if #auras > 0 then
        local totalAuraW = #auras * dbSpacing - 3
        local curAuraX = x - totalAuraW * 0.5
        for _, aura in ipairs(auras) do
            icons.drawAuraBadge(aura.icon, curAuraX, dbY, dbSize, aura.dur, aura.maxDur, aura.border)
            curAuraX = curAuraX + dbSpacing
        end
    end

    -- 4. Cast Bar UNDER Characters in 2D space
    if cid > 0 and ctot > 0 then
        local castY = y + 42
        local cProg = math.max(0, math.min(1.0, (ctot - ctmr) / ctot))
        local isChannel = (cid == 5)
        local castIconMap = {
            [1] = "agony",
            [2] = "corruption",
            [3] = "fear",
            [4] = "shadowbolt",
            [5] = "drainlife",
            [6] = "unendingresolve",
            [7] = "deathcoil",
        }
        local cIcon = class_view.icon(meta, side, cid)

        local iconSize = 16
        local castBarX = x - halfW + iconSize + 3
        local castBarW = barW - iconSize - 3

        -- Draw Spell Icon with rotating radial mask for remaining cast time
        if cIcon then
            icons.drawRect(cIcon, x - halfW, castY, iconSize, iconSize)
            local remainRatio = math.max(0.0, math.min(1.0, ctmr / ctot))
            icons.drawRadialCooldownMask(x - halfW, castY, iconSize, iconSize, remainRatio, 0.65)
            love.graphics.setColor(0.4, 0.4, 0.5, 0.9)
            love.graphics.setLineWidth(1)
            love.graphics.rectangle("line", x - halfW, castY, iconSize, iconSize, 2)
        else
            castBarX = x - halfW
            castBarW = barW
        end

        love.graphics.setColor(0.08, 0.10, 0.15, 0.9)
        love.graphics.rectangle("fill", castBarX, castY, castBarW, iconSize, 3)

        if isChannel then
            love.graphics.setColor(0.1, 0.8, 0.85, 1.0)
            love.graphics.rectangle("fill", castBarX, castY, castBarW * (1.0 - cProg), iconSize, 3)
        else
            love.graphics.setColor(0.95, 0.65, 0.1, 1.0)
            love.graphics.rectangle("fill", castBarX, castY, castBarW * cProg, iconSize, 3)
        end

        love.graphics.setColor(0.25, 0.35, 0.45, 0.8)
        love.graphics.setLineWidth(1)
        love.graphics.rectangle("line", castBarX, castY, castBarW, iconSize, 3)

        love.graphics.setColor(1, 1, 1, 1)
        local castLabel = class_view.name(meta, side, cid)
        love.graphics.printf(castLabel, castBarX, castY + 1, castBarW, "center")
    end
end

local function tabBounds(screenW, index)
    local startX, gap = 156, 4
    local width = (screenW - startX - 20 - gap * (#TABS - 1)) / #TABS
    return startX + (index - 1) * (width + gap), 14, width, 36
end

local function drawTabBar(screenW)
    local g = love.graphics
    g.setColor(0.055, 0.075, 0.11)
    g.rectangle("fill", 0, 0, screenW, ui.headerHeight)
    g.setColor(0.15, 0.20, 0.27)
    g.line(0, ui.headerHeight - 1, screenW, ui.headerHeight - 1)
    g.setColor(0.9, 0.95, 1)
    g.print("PVP / SIM", 24, 17)
    g.setColor(0.49, 0.60, 0.71)
    g.print("Combat lab", 24, 35)
    local mx, my = love.mouse.getPosition()
    for idx, tab in ipairs(TABS) do
        local x, y, w, h = tabBounds(screenW, idx)
        ui.tab(x, y, w, h, tab.label, currentTab == tab.id,
            mx >= x and mx <= x + w and my >= y and my <= y + h)
    end
end

local function drawContent()
    local screenW = ui.width()
    local screenH = ui.height()

    if currentTab == "training" then
        training.draw()
        return
    elseif currentTab == "health" then
        meta_health.draw(training)
        return
    elseif currentTab == "graphs" then
        graphs.draw()
        return
    elseif currentTab == "matrix" then
        matrix_view.draw()
        return
    elseif currentTab == "fights" then
        match_browser.draw()
        return
    end

    local arenaCenterY = screenH * 0.48

    -- ==========================================
    -- 1. SCENE RENDERING (WITH ZOOM & PAN)
    -- ==========================================
    love.graphics.push()
    love.graphics.translate(screenW * 0.5 + camera.x, arenaCenterY + camera.y)
    love.graphics.scale(camera.zoom, camera.zoom)

    -- Arena Oval Floor
    love.graphics.setColor(0.08, 0.11, 0.18, 1.0)
    love.graphics.ellipse("fill", 0, 0, 520, 190)

    love.graphics.setColor(0.18, 0.22, 0.32, 0.8)
    love.graphics.setLineWidth(3)
    love.graphics.ellipse("line", 0, 0, 520, 190)

    -- Yard markings & Ranges
    love.graphics.setColor(0.3, 0.38, 0.5, 0.3)
    love.graphics.setLineWidth(1)
    love.graphics.ellipse("line", 0, 0, 300, 110) -- Fear Range (20m)
    love.graphics.line(0, -180, 0, 180)

    love.graphics.setColor(0.5, 0.6, 0.7, 0.5)
    love.graphics.printf("-15m", worldToArenaX(-15) - 30, 155, 60, "center")
    love.graphics.printf("0m", worldToArenaX(0) - 30, 155, 60, "center")
    love.graphics.printf("+15m", worldToArenaX(15) - 30, 155, 60, "center")

    local frame = getFrameAtTime(currentTime)
    if frame then
        local ax = worldToArenaX(frame[3])
        local bx = worldToArenaX(frame[4])

        -- Distance connector line
        love.graphics.setColor(0.2, 0.6, 0.9, 0.25)
        love.graphics.setLineWidth(2)
        love.graphics.line(ax, 0, bx, 0)

        -- Distance indicator badge
        local midX = (ax + bx) * 0.5
        love.graphics.setColor(0.1, 0.14, 0.22, 0.9)
        love.graphics.rectangle("fill", midX - 35, 14, 70, 22, 5)
        love.graphics.setColor(0.3, 0.7, 1.0, 1.0)
        love.graphics.printf(string.format("%.1fm", frame[2]), midX - 35, 18, 70, "center")

        -- Drain Life beam if active
        if frame[11] == 5 then -- Unit A casting Drain Life
            drawDrainLifeBeam(ax, 0, bx, 0, { 0.7, 0.35, 1.0 }, { 0.2, 0.9, 0.5 })
        end
        if frame[12] == 5 then -- Unit B casting Drain Life
            drawDrainLifeBeam(bx, 0, ax, 0, { 0.2, 0.9, 0.5 }, { 0.7, 0.35, 1.0 })
        end

        -- Projectiles in-flight
        for _, p in ipairs(projectiles) do
            local curX = p.sx + (p.tx - p.sx) * p.progress
            local curY = p.sy + (p.ty - p.sy) * p.progress
            love.graphics.setColor(p.color[1], p.color[2], p.color[3], 1.0)
            if p.kind == "deathcoil" then
                love.graphics.circle("fill", curX, curY, 11)
                love.graphics.setColor(0.9, 1.0, 0.9, 0.8)
                love.graphics.circle("fill", curX, curY, 6)
            else
                love.graphics.circle("fill", curX, curY, 8)
            end
        end

        -- Particles
        for _, pt in ipairs(particles) do
            love.graphics.setColor(pt.color[1], pt.color[2], pt.color[3], pt.alpha)
            love.graphics.circle("fill", pt.x, pt.y, pt.size or 3)
        end

        -- Draw combatants with full 40-column telemetry
        local meta = MATCH_DATA.meta
        drawCombatant(
            ax, 0,
            frame[5], frame[7],                                    -- hp_a, mana_a
            frame[11], frame[13], frame[15],                       -- cast_id_a, cast_timer_a, cast_total_a
            frame[17], frame[19], frame[21], frame[23],            -- agony_a, corruption_a, fear_a, horror_a
            frame[25],                                             -- unending_dur_a
            { 0.68, 0.35, 0.98 }, true
        )

        drawCombatant(
            bx, 0,
            frame[6], frame[8],                                    -- hp_b, mana_b
            frame[12], frame[14], frame[16],                       -- cast_id_b, cast_timer_b, cast_total_b
            frame[18], frame[20], frame[22], frame[24],            -- agony_b, corruption_b, fear_b, horror_b
            frame[26],                                             -- unending_dur_b
            { 0.10, 0.82, 0.55 }, false
        )

        -- Floating Combat Text
        for _, item in ipairs(fctList) do
            love.graphics.setColor(item.color[1], item.color[2], item.color[3], item.alpha)
            love.graphics.printf(item.text, item.x - 100, item.y, 200, "center")
        end
    end

    love.graphics.pop()

    -- ==========================================
    -- 2. FIXED HUD & UI (NOT ZOOMED)
    -- ==========================================

    -- 2.1 Top Header Bar
    love.graphics.setColor(0.08, 0.10, 0.16, 0.95)
    love.graphics.rectangle("fill", 16, 12, screenW - 32, 54, 8)
    love.graphics.setColor(0.2, 0.25, 0.35, 0.8)
    love.graphics.rectangle("line", 16, 12, screenW - 32, 54, 8)


    -- Top left PVP icon and title
    icons.draw("pvp_banner", 32, 28, 24)
    love.graphics.setColor(0.95, 0.95, 1.0, 1.0)
    love.graphics.print("PVP_SIM", 48, 20)
    love.graphics.setColor(0.4, 0.7, 1.0, 1.0)
    love.graphics.print(string.format("Zoom: %d%%", math.floor(camera.zoom * 100 + 0.5)), 48, 38)

    if MATCH_DATA then
        local meta = MATCH_DATA.meta
        local victorStr = "DRAW"
        local vColor = { 0.6, 0.7, 0.8 }
        local showCrown = false
        if meta.victor == 0 then
            victorStr = string.format("%s VICTORIOUS", meta.name_a)
            vColor = { 0.7, 0.4, 1.0 }
            showCrown = true
        elseif meta.victor == 1 then
            victorStr = string.format("%s VICTORIOUS", meta.name_b)
            vColor = { 0.2, 0.85, 0.5 }
            showCrown = true
        end

        local centerBoxX = screenW * 0.35
        local centerBoxW = screenW * 0.3
        if showCrown then
            icons.draw("crown", centerBoxX + centerBoxW * 0.5 - 90, 36, 20)
        end
        love.graphics.setColor(vColor[1], vColor[2], vColor[3], 1.0)
        love.graphics.printf(victorStr, centerBoxX, 28, centerBoxW, "center")

        -- Time clock with clock icon
        icons.draw("clock", screenW - 250, 38, 18)
        love.graphics.setColor(0.7, 0.8, 0.9, 1.0)
        love.graphics.printf(string.format("%.2fs / %.2fs", currentTime, meta.total_time), screenW - 235, 30, 195, "right")
    end

    -- Helper spell icon lookup
    local spellIconMap = {
        [0] = "ui_sword",
        [1] = "agony",
        [2] = "corruption",
        [3] = "fear",
        [4] = "shadowbolt",
        [5] = "drainlife",
        [6] = "unendingresolve",
        [7] = "deathcoil",
    }

    -- 2.2 Telemetry Unit Frames (Top-left & Top-right)
    if frame and MATCH_DATA then
        local meta = MATCH_DATA.meta
        local cdW = 22
        local cdH = 22

        local cdY, row4Y, row5Y = 132, 160, 186
        if class_view.spec(meta, 0) == "warlock" then
        -- Unit Frame A
        love.graphics.setColor(0.08, 0.10, 0.16, 0.94)
        love.graphics.rectangle("fill", 16, 74, 280, 142, 6)
        love.graphics.setColor(0.68, 0.35, 0.98, 0.8)
        love.graphics.rectangle("line", 16, 74, 280, 142, 6)

        -- Row 1: Header (Class Icon, Name & Active Cast/Action)
        icons.drawClassIcon("warlock", 34, 92, 28)
        love.graphics.setColor(0.95, 0.95, 1.0, 1.0)
        love.graphics.print(meta.name_a, 56, 82)

        local actA = frame[39]
        local castA = frame[11]
        local actIconA = (castA > 0 and spellIconMap[castA]) or spellIconMap[actA] or "ui_sword"
        icons.drawRect(actIconA, 264, 80, 20, 20)
        if castA > 0 and frame[15] > 0 then
            local castProg = math.max(0.0, math.min(1.0, frame[13] / frame[15]))
            icons.drawRadialCooldownMask(264, 80, 20, 20, castProg, 0.65)
        end
        love.graphics.setColor(0.3, 0.4, 0.5, 0.8)
        love.graphics.rectangle("line", 264, 80, 20, 20, 2)

        -- Row 2: Vitals Bars (HP & MP)
        local hpPctA = math.max(0, math.min(1.0, frame[5] / 2000.0))
        love.graphics.setColor(0.06, 0.08, 0.12, 1.0)
        love.graphics.rectangle("fill", 56, 102, 228, 12, 2)
        love.graphics.setColor(0.2, 0.82, 0.3, 0.95)
        love.graphics.rectangle("fill", 56, 102, 228 * hpPctA, 12, 2)
        love.graphics.setColor(1, 1, 1, 0.95)
        love.graphics.printf(string.format("%d HP", math.floor(frame[5])), 56, 102, 228, "center")

        local manaPctA = math.max(0, math.min(1.0, frame[7] / 1000.0))
        love.graphics.setColor(0.06, 0.08, 0.12, 1.0)
        love.graphics.rectangle("fill", 56, 118, 228, 8, 2)
        love.graphics.setColor(0.15, 0.65, 0.95, 0.95)
        love.graphics.rectangle("fill", 56, 118, 228 * manaPctA, 8, 2)
        love.graphics.setColor(1, 1, 1, 0.85)
        love.graphics.printf(string.format("%d MP", math.floor(frame[7])), 56, 117, 228, "center")

        -- Row 3: Cooldowns Row
        love.graphics.setColor(0.55, 0.65, 0.8, 1.0)
        love.graphics.print("CD:", 26, 134)

        -- Death Coil CD
        local dcX = 56
        cdY = 132
        icons.drawRect("deathcoil", dcX, cdY, cdW, cdH)
        if frame[29] > 0 then
            icons.drawRadialCooldownMask(dcX, cdY, cdW, cdH, math.min(1.0, frame[29] / 45.0), 0.7)
            love.graphics.setColor(0.95, 0.35, 0.35, 1.0)
            love.graphics.rectangle("line", dcX, cdY, cdW, cdH, 2)
        else
            love.graphics.setColor(0.3, 0.9, 0.45, 1.0)
            love.graphics.rectangle("line", dcX, cdY, cdW, cdH, 2)
        end

        -- Unending Resolve CD
        local urX = 84
        icons.drawRect("unendingresolve", urX, cdY, cdW, cdH)
        if frame[27] > 0 then
            icons.drawRadialCooldownMask(urX, cdY, cdW, cdH, math.min(1.0, frame[27] / 45.0), 0.7)
            love.graphics.setColor(0.95, 0.35, 0.35, 1.0)
            love.graphics.rectangle("line", urX, cdY, cdW, cdH, 2)
        else
            love.graphics.setColor(0.35, 0.85, 1.0, 1.0)
            love.graphics.rectangle("line", urX, cdY, cdW, cdH, 2)
        end

        -- Row 4: Buffs Row
        love.graphics.setColor(0.35, 0.85, 1.0, 1.0)
        love.graphics.print("BUFF:", 26, 162)
        local bX = 64
        row4Y = 160
        if frame[25] > 0 then -- Unending Resolve buff
            icons.drawAuraBadge("unendingresolve", bX, row4Y, 20, frame[25], 6.0, { 0.2, 0.85, 1.0, 1 })
            bX = bX + 24
        end

        -- Row 5: Debuffs Row
        love.graphics.setColor(0.95, 0.45, 0.35, 1.0)
        love.graphics.print("DEBUFF:", 26, 188)
        local debX = 80
        row5Y = 186
        if frame[23] > 0 then
            icons.drawAuraBadge("horror", debX, row5Y, 20, frame[23], 3.0, { 0.3, 0.9, 0.3, 1 })
            debX = debX + 24
        end
        if frame[21] > 0 then
            icons.drawAuraBadge(class_view.aura(meta, 0, "fear"), debX, row5Y, 20, frame[21], 6.0, { 0.85, 0.4, 1.0, 1 })
            debX = debX + 24
        end
        if frame[17] > 0 then
            icons.drawAuraBadge(class_view.aura(meta, 0, "agony"), debX, row5Y, 20, frame[17], 18.0, { 0.7, 0.3, 0.9, 1 })
            debX = debX + 24
        end
        if frame[19] > 0 then
            icons.drawAuraBadge(class_view.aura(meta, 0, "corruption"), debX, row5Y, 20, frame[19], 14.0, { 0.95, 0.5, 0.2, 1 })
            debX = debX + 24
        end

        else
            class_view.drawMagePanel(meta, frame, 0, 16, icons)
        end
        -- Unit Frame B
        local cardBx = screenW - 296
        if class_view.spec(meta, 1) == "warlock" then
        love.graphics.setColor(0.08, 0.10, 0.16, 0.94)
        love.graphics.rectangle("fill", cardBx, 74, 280, 142, 6)
        love.graphics.setColor(0.10, 0.82, 0.55, 0.8)
        love.graphics.rectangle("line", cardBx, 74, 280, 142, 6)

        -- Row 1: Header (Class Icon, Name & Active Cast/Action)
        icons.drawClassIcon("warlock", cardBx + 18, 92, 28)
        love.graphics.setColor(0.95, 0.95, 1.0, 1.0)
        love.graphics.print(meta.name_b, cardBx + 40, 82)

        local actB = frame[40]
        local castB = frame[12]
        local actIconB = (castB > 0 and spellIconMap[castB]) or spellIconMap[actB] or "ui_sword"
        icons.drawRect(actIconB, cardBx + 248, 80, 20, 20)
        if castB > 0 and frame[16] > 0 then
            local castProgB = math.max(0.0, math.min(1.0, frame[14] / frame[16]))
            icons.drawRadialCooldownMask(cardBx + 248, 80, 20, 20, castProgB, 0.65)
        end
        love.graphics.setColor(0.3, 0.4, 0.5, 0.8)
        love.graphics.rectangle("line", cardBx + 248, 80, 20, 20, 2)

        -- Row 2: Vitals Bars (HP & MP)
        local hpPctB = math.max(0, math.min(1.0, frame[6] / 2000.0))
        love.graphics.setColor(0.06, 0.08, 0.12, 1.0)
        love.graphics.rectangle("fill", cardBx + 40, 102, 228, 12, 2)
        love.graphics.setColor(0.2, 0.82, 0.3, 0.95)
        love.graphics.rectangle("fill", cardBx + 40, 102, 228 * hpPctB, 12, 2)
        love.graphics.setColor(1, 1, 1, 0.95)
        love.graphics.printf(string.format("%d HP", math.floor(frame[6])), cardBx + 40, 102, 228, "center")

        local manaPctB = math.max(0, math.min(1.0, frame[8] / 1000.0))
        love.graphics.setColor(0.06, 0.08, 0.12, 1.0)
        love.graphics.rectangle("fill", cardBx + 40, 118, 228, 8, 2)
        love.graphics.setColor(0.15, 0.65, 0.95, 0.95)
        love.graphics.rectangle("fill", cardBx + 40, 118, 228 * manaPctB, 8, 2)
        love.graphics.setColor(1, 1, 1, 0.85)
        love.graphics.printf(string.format("%d MP", math.floor(frame[8])), cardBx + 40, 117, 228, "center")

        -- Row 3: Cooldowns Row
        love.graphics.setColor(0.55, 0.65, 0.8, 1.0)
        love.graphics.print("CD:", cardBx + 10, 134)

        local dcXB = cardBx + 40
        icons.drawRect("deathcoil", dcXB, cdY, cdW, cdH)
        if frame[30] > 0 then
            icons.drawRadialCooldownMask(dcXB, cdY, cdW, cdH, math.min(1.0, frame[30] / 45.0), 0.7)
            love.graphics.setColor(0.95, 0.35, 0.35, 1.0)
            love.graphics.rectangle("line", dcXB, cdY, cdW, cdH, 2)
        else
            love.graphics.setColor(0.3, 0.9, 0.45, 1.0)
            love.graphics.rectangle("line", dcXB, cdY, cdW, cdH, 2)
        end

        local urXB = cardBx + 68
        icons.drawRect("unendingresolve", urXB, cdY, cdW, cdH)
        if frame[28] > 0 then
            icons.drawRadialCooldownMask(urXB, cdY, cdW, cdH, math.min(1.0, frame[28] / 45.0), 0.7)
            love.graphics.setColor(0.95, 0.35, 0.35, 1.0)
            love.graphics.rectangle("line", urXB, cdY, cdW, cdH, 2)
        else
            love.graphics.setColor(0.35, 0.85, 1.0, 1.0)
            love.graphics.rectangle("line", urXB, cdY, cdW, cdH, 2)
        end

        -- Row 4: Buffs Row
        love.graphics.setColor(0.35, 0.85, 1.0, 1.0)
        love.graphics.print("BUFF:", cardBx + 10, 162)
        local bXB = cardBx + 48
        if frame[26] > 0 then -- Unending Resolve buff
            icons.drawAuraBadge("unendingresolve", bXB, row4Y, 20, frame[26], 6.0, { 0.2, 0.85, 1.0, 1 })
            bXB = bXB + 24
        end

        -- Row 5: Debuffs Row
        love.graphics.setColor(0.95, 0.45, 0.35, 1.0)
        love.graphics.print("DEBUFF:", cardBx + 10, 188)
        local debXB = cardBx + 64
        if frame[24] > 0 then
            icons.drawAuraBadge("horror", debXB, row5Y, 20, frame[24], 3.0, { 0.3, 0.9, 0.3, 1 })
            debXB = debXB + 24
        end
        if frame[22] > 0 then
            icons.drawAuraBadge(class_view.aura(meta, 1, "fear"), debXB, row5Y, 20, frame[22], 6.0, { 0.85, 0.4, 1.0, 1 })
            debXB = debXB + 24
        end
        if frame[18] > 0 then
            icons.drawAuraBadge(class_view.aura(meta, 1, "agony"), debXB, row5Y, 20, frame[18], 18.0, { 0.7, 0.3, 0.9, 1 })
            debXB = debXB + 24
        end
        if frame[20] > 0 then
            icons.drawAuraBadge(class_view.aura(meta, 1, "corruption"), debXB, row5Y, 20, frame[20], 14.0, { 0.95, 0.5, 0.2, 1 })
            debXB = debXB + 24
        end
        else
            class_view.drawMagePanel(meta, frame, 1, cardBx, icons)
        end
    end

    -- 2.3 Bottom Controls & Scrubber Panel
    local ctrlY = screenH - 120
    love.graphics.setColor(0.08, 0.10, 0.16, 0.95)
    love.graphics.rectangle("fill", 16, ctrlY, screenW - 32, 106, 8)
    love.graphics.setColor(0.2, 0.25, 0.35, 0.8)
    love.graphics.rectangle("line", 16, ctrlY, screenW - 32, 106, 8)

    -- Scrubber Track
    local scrubX = 36
    local scrubW = screenW - 72
    local totalT = (MATCH_DATA and MATCH_DATA.meta.total_time) or 1.0
    local scrubPct = math.max(0, math.min(1.0, currentTime / totalT))

    love.graphics.setColor(0.18, 0.22, 0.32, 1.0)
    love.graphics.rectangle("fill", scrubX, ctrlY + 18, scrubW, 8, 4)
    love.graphics.setColor(0.2, 0.7, 1.0, 1.0)
    love.graphics.rectangle("fill", scrubX, ctrlY + 18, scrubW * scrubPct, 8, 4)
    love.graphics.circle("fill", scrubX + scrubW * scrubPct, ctrlY + 22, 9)

    -- Instructions & Shortcuts
    love.graphics.setColor(0.85, 0.9, 0.98, 1.0)
    ui.tab(36, ctrlY + 36, 132, 28, isPlaying and "Pause  [Space]" or "Play  [Space]", true, false)
    love.graphics.setColor(0.6, 0.7, 0.8, 1.0)
    love.graphics.print("Arrows  Step    +/-  Zoom    0  Reset    R  Reload    1–5  Speed: " .. tostring(playbackSpeed) .. "x", 180, ctrlY + 42)

    -- Combat Summary / Live Log
    if MATCH_DATA and MATCH_DATA.events then
        love.graphics.setColor(0.5, 0.65, 0.8, 1.0)
        local latestEvText = "No events yet"
        for i = #MATCH_DATA.events, 1, -1 do
            local ev = MATCH_DATA.events[i]
            if ev.t <= currentTime then
                local spName = class_view.name(MATCH_DATA.meta, ev.s, ev.sp)
                latestEvText = string.format("Latest Event: [%.2fs] Unit %s -> %s (Amount: %.0f)", ev.t, ev.s == 0 and "A" or "B", spName, ev.a)
                break
            end
        end
        love.graphics.print(latestEvText, 36, ctrlY + 70)
    end
end

function love.draw()
    love.graphics.push("all")
    love.graphics.translate(0, ui.headerHeight)
    love.graphics.scale(ui.scale())
    drawContent()
    love.graphics.pop()
    drawTabBar(love.graphics.getWidth())
end

function love.wheelmoved(x, y)
    if currentTab ~= "arena" then return end
    local oldZoom = camera.zoom
    if y > 0 then
        camera.zoom = math.min(camera.maxZoom, camera.zoom * 1.15)
    elseif y < 0 then
        camera.zoom = math.max(camera.minZoom, camera.zoom / 1.15)
    end
end

function love.keypressed(key)
    -- Tab switching shortcuts
    if key == "f1" or key == "1" and love.keyboard.isDown("lctrl", "rctrl") then
        currentTab = "arena"
        return
    elseif key == "f2" or key == "g" and currentTab ~= "training" and currentTab ~= "health" or key == "2" and love.keyboard.isDown("lctrl", "rctrl") then
        currentTab = (currentTab == "graphs") and "arena" or "graphs"
        return
    elseif key == "f3" or key == "3" and love.keyboard.isDown("lctrl", "rctrl") then
        currentTab = (currentTab == "fights") and "arena" or "fights"
        return
    elseif key == "f4" or key == "m" and currentTab ~= "training" and currentTab ~= "health" or key == "4" and love.keyboard.isDown("lctrl", "rctrl") then
        currentTab = (currentTab == "matrix") and "arena" or "matrix"
        return
    elseif key == "f5" then
        currentTab = (currentTab == "health") and "arena" or "health"
        return
    elseif key == "f6" then
        currentTab = "training"
        return
    elseif key == "tab" and not (currentTab == "training" and training.hasFocus()) and currentTab ~= "health" then
        local nextTab = { arena = "graphs", graphs = "fights", fights = "matrix", matrix = "health", health = "training", training = "arena" }
        currentTab = nextTab[currentTab] or "arena"
        return
    end

    if currentTab == "training" then
        training.keypressed(key)
        return
    elseif currentTab == "health" then
        if key == "escape" then
            currentTab = "arena"
            return
        end
        meta_health.keypressed(key)
        return
    elseif currentTab == "graphs" then
        if key == "escape" then
            currentTab = "arena"
            return
        end
        graphs.keypressed(key)
        return
    elseif currentTab == "matrix" then
        if key == "escape" then
            currentTab = "arena"
            return
        end
        local matchToLoad = matrix_view.keypressed(key)
        if matchToLoad then
            loadMatchFile(matchToLoad)
            currentTime = 0.0
            isPlaying = true
            currentTab = "arena"
        end
        return
    elseif currentTab == "fights" then
        if key == "escape" then
            currentTab = "arena"
            return
        end
        local matchToLoad = match_browser.keypressed(key)
        if matchToLoad then
            loadMatchFile(matchToLoad)
            currentTime = 0.0
            isPlaying = true
            currentTab = "arena"
        end
        return
    end

    if key == "space" then
        isPlaying = not isPlaying
    elseif key == "left" then
        isPlaying = false
        currentTime = math.max(0, currentTime - 0.01)
        resetEventsToTime(currentTime)
    elseif key == "right" then
        isPlaying = false
        if MATCH_DATA then
            currentTime = math.min(MATCH_DATA.meta.total_time, currentTime + 0.01)
            resetEventsToTime(currentTime)
        end
    elseif key == "r" then
        loadMatchFile(currentMatchPath)
        currentTime = 0.0
        isPlaying = true
        resetEventsToTime(0.0)
    elseif key == "=" or key == "+" or key == "kp+" then
        camera.zoom = math.min(camera.maxZoom, camera.zoom * 1.2)
    elseif key == "-" or key == "_" or key == "kp-" then
        camera.zoom = math.max(camera.minZoom, camera.zoom / 1.2)
    elseif key == "0" or key == "kp0" then
        camera.zoom = 1.0
        camera.x = 0.0
        camera.y = 0.0
    elseif key == "1" then playbackSpeed = 0.25
    elseif key == "2" then playbackSpeed = 0.5
    elseif key == "3" then playbackSpeed = 1.0
    elseif key == "4" then playbackSpeed = 2.0
    elseif key == "5" then playbackSpeed = 4.0
    elseif key == "escape" then
        love.event.quit()
    end
end

function love.mousepressed(x, y, button)
    local screenW = ui.width()

    if button == 1 then
        for idx, tab in ipairs(TABS) do
            local tx, ty, tw, th = tabBounds(love.graphics.getWidth(), idx)
            if x >= tx and x <= tx + tw and y >= ty and y <= ty + th then
                currentTab = tab.id
                return
            end
        end
    end
    if y < ui.headerHeight then return end
    x, y = ui.contentPoint(x, y)

    if currentTab == "training" then
        local tab = training.mousepressed(x, y, button)
        if tab then currentTab = tab end
        return
    elseif currentTab == "health" then
        local tab = meta_health.mousepressed(x, y, button)
        if tab then currentTab = tab end
        return
    elseif currentTab == "graphs" then
        graphs.mousepressed(x, y, button)
        return
    elseif currentTab == "matrix" then
        local matchToLoad = matrix_view.mousepressed(x, y, button)
        if matchToLoad then
            loadMatchFile(matchToLoad)
            currentTime = 0.0
            isPlaying = true
            currentTab = "arena"
        end
        return
    elseif currentTab == "fights" then
        local matchToLoad = match_browser.mousepressed(x, y, button)
        if matchToLoad then
            loadMatchFile(matchToLoad)
            currentTime = 0.0
            isPlaying = true
            currentTab = "arena"
        end
        return
    end

    local screenH = ui.height()
    local ctrlY = screenH - 120
    local scrubX = 36
    local scrubW = screenW - 72

    if button == 1 then
        if x >= 36 and x <= 168 and y >= ctrlY + 36 and y <= ctrlY + 64 then
            isPlaying = not isPlaying
            return
        end
        if y >= ctrlY + 10 and y <= ctrlY + 34 and x >= scrubX and x <= scrubX + scrubW then
            if MATCH_DATA then
                local pct = (x - scrubX) / scrubW
                currentTime = pct * MATCH_DATA.meta.total_time
                resetEventsToTime(currentTime)
            end
        end
    elseif button == 2 or button == 3 then
        camera.isDragging = true
        camera.dragButton = button
        camera.dragStartX = x
        camera.dragStartY = y
        camera.origPanX = camera.x
        camera.origPanY = camera.y
    end
end

function love.mousereleased(x, y, button)
    if camera.isDragging and button == camera.dragButton then
        camera.isDragging = false
    end
end

function love.mousemoved(x, y, dx, dy)
    x, y = ui.contentPoint(x, y)
    if camera.isDragging then
        camera.x = camera.origPanX + (x - camera.dragStartX)
        camera.y = camera.origPanY + (y - camera.dragStartY)
    end
end

function love.textinput(text)
    if currentTab == "training" then training.textinput(text) end
end

function love.quit()
    if training.isActive() then
        training.stop()
        quitAfterTraining = true
        currentTab = "training"
        return true
    end
end
