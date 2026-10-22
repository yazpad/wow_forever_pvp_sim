local vitals = require('vitals')
local ui = require("ui")
local class_view = require("class_view")
local spell_visuals = require("spell_visuals")
local unit_frames = require("unit_frames")
local cast_feedback = require("cast_feedback")
local warrior_motion = require("warrior_motion")
local combat_log = require("combat_log")
-- PVP_SIM: 2D COMBAT ARENA & MCTS VISUALIZER (Love2D Native Visualizer)
local json = require("json")
local match_browser = require("match_browser")
local icons = require("icons_manager")
local mcts_overlay = require("mcts_overlay")
local matrix_view = require("matrix_view")
local fight_analysis = require("fight_analysis")
local workspace = require("workspace")
local petNames = { "Imp", "Succubus", "Felhunter", "Voidwalker" }
local petMaxHp = { 500, 700, 900, 1200 }
local petIcons = { "pet_imp", "pet_succubus", "pet_felhunter", "pet_voidwalker" }

local MATCH_DATA = nil
local currentTime = 0.0
local isPlaying = true
local playbackSpeed = 1.0
local speeds = { 0.25, 0.5, 1.0, 2.0, 4.0 }
local speedIdx = 3

-- The arena workspace owns spec setup and replay playback.
local currentTab = "setup"
-- Camera state for smooth zoom and pan
local camera = require("arena_camera")

local fctList = {}
local projectiles = {}
local particles = {}
local drainLifeShader = nil
local drainLifeMesh = nil
local tokenFrameShader = nil
local tokenFrameMesh = nil

local currentMatchPath = "last_match.lua"
local resetEventsToTime

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
            combat_log.reset()
            currentTime = 0
            isPlaying = true
            if resetEventsToTime then resetEventsToTime(0) end
            workspace.showReplay()
            print("Loaded match from Lua: " .. path)
            mcts_overlay.loadSearchData(path)
            fight_analysis.load(path, MATCH_DATA)
            return true
        else
            print("Error parsing Lua match: " .. tostring(loadErr))
        end
    else
        local f = io.open(path, "r")
        local content = f:read("*a")
        f:close()
        MATCH_DATA = json.decode(content)
        combat_log.reset()
        currentTime = 0
        isPlaying = true
        if resetEventsToTime then resetEventsToTime(0) end
        workspace.showReplay()
        print("Loaded match from JSON: " .. path)
        mcts_overlay.loadSearchData(path)
        fight_analysis.load(path, MATCH_DATA)
        return true
    end
    return false
end

function love.load(arg)
    love.graphics.setBackgroundColor(0.04, 0.06, 0.10)
    local tokenFrameSource = [[
        extern vec3 u_tint;
        vec4 effect(vec4 color, Image tex, vec2 uv, vec2 screen_coords) {
            vec2 p = (uv - vec2(0.5)) * 2.0;
            float d = length(p);
            float aa = max(fwidth(d), 0.001);
            float distanceToRing = abs(d - 0.8);
            float ring = 1.0 - smoothstep(0.025 - aa, 0.025 + aa, distanceToRing);
            float halo = exp(-pow(distanceToRing / 0.085, 2.0));
            float alpha = max(ring, halo * 0.48);
            return vec4(u_tint, alpha) * color;
        }
    ]]
    local frameOk, frameShader = pcall(love.graphics.newShader, tokenFrameSource)
    if frameOk then
        tokenFrameShader = frameShader
        -- Shapes have no useful UVs; give the halo a full 0..1 UV quad.
        tokenFrameMesh = love.graphics.newMesh({
            { -40, -40, 0, 0 },
            {  40, -40, 1, 0 },
            { -40,  40, 0, 1 },
            {  40,  40, 1, 1 },
        }, "strip", "static")
    else
        print("Token frame shader unavailable; using circle outline: " .. tostring(frameShader))
    end
    local shaderSource = [[
        extern number u_time;
        vec4 effect(vec4 color, Image tex, vec2 uv, vec2 screen_coords) {
            float x = uv.x;
            float across = abs(uv.y - 0.5) * 2.0;
            float edge = 1.0 - smoothstep(0.0, 1.0, across);
            float envelope = smoothstep(0.0, 0.08, x) * (1.0 - smoothstep(0.88, 1.0, x));
            float drift = sin(x * 28.0 - u_time * 5.0 + sin(x * 11.0 + u_time) * 1.2);
            float vein = 0.72 + 0.28 * sin(x * 54.0 - u_time * 8.0 + across * 10.0);
            float core = exp(-across * across * 18.0);
            float glow = exp(-across * across * 4.5);
            float body = edge * (0.27 * glow + 0.73 * core) * (0.84 + 0.16 * drift) * vein * envelope;
            vec3 green = mix(vec3(0.10, 0.88, 0.25), vec3(0.58, 1.0, 0.68), core);
            return vec4(green * color.rgb, body * color.a);
        }
    ]]
    local shaderOk, shader = pcall(love.graphics.newShader, shaderSource)
    if shaderOk then
        drainLifeShader = shader
        drainLifeMesh = love.graphics.newMesh({
            { "VertexPosition", "float", 2 },
            { "VertexTexCoord", "float", 2 },
            { "VertexColor", "byte", 4 },
        }, {
            { 0, -0.5, 0, 0, 255, 255, 255, 255 },
            { 1, -0.5, 1, 0, 255, 255, 255, 255 },
            { 0,  0.5, 0, 1, 255, 255, 255, 255 },
            { 1,  0.5, 1, 1, 255, 255, 255, 255 },
        }, "strip", "static")
    else
        print("Drain Life shader unavailable; using fallback beam: " .. tostring(shader))
    end
    ui.initFonts()
    ui.resetFont()
    icons.load()

    local path = "last_match.lua"
    local explicitReplay = false

    if arg then
        for i = 1, #arg do
            if arg[i] == "--fights" then
                workspace.toggleSettingsSection("replays")
            elseif arg[i] == "--specs" then
                currentTab = "setup"
            elseif arg[i] == "--matrix" then
                workspace.toggleSettingsSection("matrix")
            elseif not arg[i]:match("^%-%-") then
                path = arg[i]
                explicitReplay = true
            end
        end
    end

    -- Load sub-modules
    match_browser.scanMatchesDir("matches")
    matrix_view.init()

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

    if not explicitReplay then workspace.editPositions() end
    currentTime = 0.0
    isPlaying = true
    fctList = {}
    projectiles = {}
    particles = {}
    combat_log.reset()

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

local function siphonRemaining(targetSide, t, frameTimer)
    if frameTimer and frameTimer > 0 then return frameTimer end
    if not MATCH_DATA or not MATCH_DATA.events then return 0 end
    -- Older replays lack the appended frame columns. Reconstruct the aura
    -- from the latest Siphon Life action aimed at this target.
    for i = #MATCH_DATA.events, 1, -1 do
        local ev = MATCH_DATA.events[i]
        local kind = ev.k or ev.kind
        local spell = ev.sp or ev.spell_id
        local target = ev.tg or ev.target
        local eventTime = ev.t or ev.time_s
        if kind == 0 and spell == 8 and target == targetSide then
            local remaining = 30.0 - (t - eventTime)
            return math.max(0, remaining)
        end
    end
    return 0
end

local LOCKOUT_SCHOOLS = { [1] = "Shadow", [2] = "Fire", [3] = "Frost", [4] = "Arcane" }
local function spellLockRemaining(targetSide, t)
    if not MATCH_DATA or not MATCH_DATA.events then return nil, 0 end
    for i = #MATCH_DATA.events, 1, -1 do
        local ev = MATCH_DATA.events[i]
        if (ev.k or ev.kind) == 17 and (ev.tg or ev.target) == targetSide then
            local eventTime = ev.t or ev.time_s
            local duration = ev.a or ev.amount or 4.0
            -- Replays are scrubbed from time zero, while the full event list is
            -- already loaded. Ignore future interrupts instead of showing their
            -- lockout badge before the interrupt happens.
            local remaining = eventTime <= t and duration - (t - eventTime) or 0
            if remaining > 0 then
                return LOCKOUT_SCHOOLS[ev.sp or ev.spell_id] or "Magic", remaining
            end
        end
    end
    return nil, 0
end

local function drawSpellLockBadge(x, y, school, remaining)
    icons.drawAuraBadge("spell_lock", x, y, 20, remaining, 4.0, { 1.0, 0.2, 0.2, 1 })
    love.graphics.setColor(0.02, 0.03, 0.05, 0.92)
    love.graphics.rectangle("fill", x - 2, y + 14, 24, 8, 2)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.push()
    love.graphics.translate(x + 10, y + 14)
    love.graphics.scale(0.52, 0.62)
    love.graphics.printf(string.upper(school), -27, 0, 54, "center")
    love.graphics.pop()
end

local nextEventIdx = 1

resetEventsToTime = function(t)
    camera.resetTokenMotion()
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

-- Both ground-plane axes use the same scale: grid cells are square meters.
local WORLD_SCALE = camera.worldScale
local function worldToArenaX(x)
    return x * WORLD_SCALE
end

local function worldToArenaY(y)
    return y * WORLD_SCALE
end

local function drawWorldGrid(screenW, screenH, centerY)
    local g = love.graphics
    local zoom = camera.zoom
    local left = (-screenW * 0.5 - camera.x) / zoom
    local right = (screenW * 0.5 - camera.x) / zoom
    local top = (-centerY - camera.y) / zoom
    local bottom = (screenH - centerY - camera.y) / zoom
    g.setColor(0.055, 0.075, 0.115, 1)
    g.rectangle("fill", left, top, right - left, bottom - top)

    -- Only draw visible lines; reduce density when zoomed out.
    local step = WORLD_SCALE * zoom >= 12 and 1 or 5
    if WORLD_SCALE * zoom * step < 12 then step = 10 end
    g.setLineWidth(1 / zoom)
    for meter = math.ceil(left / WORLD_SCALE / step) * step, math.floor(right / WORLD_SCALE), step do
        local major = meter % 5 == 0
        g.setColor(0.20, 0.29, 0.40, major and 0.65 or 0.25)
        local x = worldToArenaX(meter)
        g.line(x, top, x, bottom)
    end
    for meter = math.ceil(top / WORLD_SCALE / step) * step, math.floor(bottom / WORLD_SCALE), step do
        local major = meter % 5 == 0
        g.setColor(0.20, 0.29, 0.40, major and 0.65 or 0.25)
        local y = worldToArenaY(meter)
        g.line(left, y, right, y)
    end

    g.setColor(0.32, 0.54, 0.70, 0.75)
    g.setLineWidth(2 / zoom)
    g.line(left, 0, right, 0)
    g.line(0, top, 0, bottom)
    g.setColor(0.55, 0.67, 0.78, 0.8)
    for meter = math.ceil(left / WORLD_SCALE / 10) * 10, math.floor(right / WORLD_SCALE), 10 do
        g.print(string.format("%dm", meter), worldToArenaX(meter) + 5 / zoom, 5 / zoom)
    end
    for meter = math.ceil(top / WORLD_SCALE / 10) * 10, math.floor(bottom / WORLD_SCALE), 10 do
        if meter ~= 0 then
            g.print(string.format("%dm", meter), 5 / zoom, worldToArenaY(meter) + 5 / zoom)
        end
    end
end

local function checkEvents(currT, frame)
    if not MATCH_DATA or not MATCH_DATA.events then return end
    local events = MATCH_DATA.events
    -- Only reset events when seeking backwards in time
    if nextEventIdx > 1 and events[nextEventIdx - 1] and events[nextEventIdx - 1].t > currT then
        resetEventsToTime(currT)
    end

    while nextEventIdx <= #events and events[nextEventIdx].t <= currT do
        local ev = events[nextEventIdx]
        nextEventIdx = nextEventIdx + 1

        local targetX = ev.tg == 0 and worldToArenaX(frame[3]) or worldToArenaX(frame[4])
        local targetY = worldToArenaY(frame[ev.tg == 0 and 49 or 50] or 0)
        local srcY = worldToArenaY(frame[ev.s == 0 and 49 or 50] or 0)
        local srcX = ev.s == 0 and worldToArenaX(frame[3]) or worldToArenaX(frame[4])

        if ev.k == 4 then -- Direct Hit (Shadow Bolt, Frostbolt, Ice Lance, etc.)
            local isDc = (ev.sp == 7 and class_view.spec(MATCH_DATA.meta, ev.s) == "warlock")
            local col = spell_visuals.color(class_view.spec(MATCH_DATA.meta, ev.s), ev.sp)
            local spName = class_view.name(MATCH_DATA.meta, ev.s, ev.sp)
            local label = isDc and string.format("DEATH COIL -%d", math.floor(ev.a + 0.5)) or ((spName ~= "Idle" and (spName .. " -") or "-") .. string.format("%d", math.floor(ev.a + 0.5)))
            addFCT(targetX, targetY + -60, label, col, isDc and 1.6 or 1.4)

            if class_view.spec(MATCH_DATA.meta,ev.s)=='warrior' then
                for _=1,8 do
                    local angle=math.random()*math.pi*2
                    table.insert(particles,{x=targetX,y=targetY-20,vx=math.cos(angle)*90,vy=math.sin(angle)*90,alpha=1,color=col,size=3})
                end
            elseif not isDc and not frame[51] then
                table.insert(projectiles, {
                    kind = "shadowbolt",
                    sx = srcX, sy = srcY - 20,
                    tx = targetX, ty = targetY - 20,
                    progress = 0.0,
                    duration = 0.22,
                    color = col,
                })
            end
        elseif ev.k == 10 and not frame[51] then -- Legacy Death Coil visual
            table.insert(projectiles, {
                kind = "deathcoil",
                sx = srcX, sy = srcY - 20,
                tx = targetX, ty = targetY - 20,
                progress = 0.0,
                duration = 0.28,
                color = { 0.1, 0.95, 0.35 },
            })
        elseif ev.k == 15 then -- Simulation projectile arrival, including absorbed hits
            local color = spell_visuals.color(class_view.spec(MATCH_DATA.meta, ev.s), ev.sp)
            for _ = 1, 12 do
                local angle = math.random() * math.pi * 2
                local speed = 60 + math.random() * 90
                table.insert(particles, {
                    x = targetX, y = targetY - 20,
                    vx = math.cos(angle) * speed, vy = math.sin(angle) * speed,
                    alpha = 1, color = color, size = 3,
                })
            end
        elseif ev.k == 16 then -- Autonomous pet damage; spell ID is pet kind.
            addFCT(targetX, targetY - 72,
                string.format("%s -%d", petNames[ev.sp] or "Pet", math.floor(ev.a + 0.5)),
                { 1.0, 0.65, 0.3 }, 1.0)

            -- If pet is an Imp (kind == 1), spawn Firebolt projectile from Imp to target
            if ev.sp == 1 then
                local side = ev.s
                local petIdx = 83 + side * 5
                local petX = frame[petIdx + 2] and worldToArenaX(frame[petIdx + 2]) or srcX
                local petY = frame[petIdx + 3] and worldToArenaY(frame[petIdx + 3]) or srcY
                local dx = targetX - petX
                local dy = (targetY - 20) - petY
                local distPixels = math.sqrt(dx * dx + dy * dy)
                local distMeters = distPixels / WORLD_SCALE
                -- Distinct, clearly trackable visual travel speed (~16 m/s, duration between 0.75s and 1.8s)
                local flightDuration = math.max(0.75, math.min(1.80, distMeters / 16.0))

                table.insert(projectiles, {
                    kind = "firebolt",
                    sx = petX, sy = petY,
                    tx = targetX, ty = targetY - 20,
                    progress = 0.0,
                    duration = flightDuration,
                    color = { 1.0, 0.55, 0.15 },
                })
            else
                -- Melee hit sparks
                for _ = 1, 8 do
                    local angle = math.random() * math.pi * 2
                    local speed = 40 + math.random() * 60
                    table.insert(particles, {
                        x = targetX, y = targetY - 20,
                        vx = math.cos(angle) * speed, vy = math.sin(angle) * speed,
                        alpha = 1.0, color = { 0.9, 0.4, 0.7 }, size = 2.5,
                    })
                end
            end
        elseif ev.k == 5 then -- Periodic DOT or Siphon Pulse
            local spec = class_view.spec(MATCH_DATA.meta, ev.s)
            local isDrain = spec == "warlock" and ev.sp == 5
            local col = spec == "priest" and spell_visuals.color(spec, ev.sp)
                or (isDrain and { 0.55, 1.0, 0.62 } or { 1.0, 0.52, 0.72 })
            addFCT(targetX, targetY - 48, string.format("-%d", math.floor(ev.a + 0.5)), col, 1.0)
        elseif ev.k == 6 then -- Siphon / Death Coil Heal
            local isDc = (ev.sp == 7 and class_view.spec(MATCH_DATA.meta, ev.s) == "warlock")
            local isDrain = (ev.sp == 5)
            local isSiphonLife = (ev.sp == 8)
            local isHealthstone = (ev.sp == 6)
            local label = string.format("+%d", math.floor(ev.a + 0.5))
            local scale = (isDc or isDrain or isSiphonLife or isHealthstone) and 1.1 or 1.0
            addFCT(srcX, srcY - 52, label, { 0.45, 1.0, 0.58 }, scale)
        elseif ev.k == 3 then -- Interrupt
            addFCT(srcX, srcY + -85, "INTERRUPTED!", { 0.98, 0.2, 0.2 }, 1.5)
        elseif ev.k == 7 then -- Feared
            addFCT(targetX, targetY + -85, class_view.spec(MATCH_DATA.meta, ev.s) == "frost_mage" and "POLYMORPH!" or "FEARED!", { 0.85, 0.55, 1.0 }, 1.4)
        elseif ev.k == 11 then -- Horror Applied
            addFCT(targetX, targetY + -85, "HORRIFIED!", { 0.2, 0.95, 0.5 }, 1.5)
        elseif ev.k == 12 then
            addFCT(targetX, targetY + -85, "ROOTED!", {0.3, 0.8, 1}, 1.4)
        elseif ev.k == 13 then
            addFCT(srcX, srcY + -85, "BLINK", {0.3, 0.8, 1}, 1.4)
        elseif ev.k == 14 then
            addFCT(targetX, targetY + -85, "COUNTERSPELL", {0.3, 0.8, 1}, 1.4)
        elseif ev.k == 9 then -- Defensive
            local isMage = class_view.spec(MATCH_DATA.meta, ev.s) == "frost_mage"
            addFCT(srcX, srcY + -80, isMage and "ICE BARRIER" or "HEALTHSTONE", isMage and { 0.2, 0.85, 1.0 } or { 0.2, 0.98, 0.4 }, 1.3)
        end
    end
end

function love.update(dt)
    fight_analysis.update()
    if currentTab == "analysis" then return end
    matrix_view.update(dt)

    if currentTab == "fights" then
        local matchToLoad = match_browser.update(dt)
        if matchToLoad then
            loadMatchFile(matchToLoad)
            currentTime = 0.0
            isPlaying = true
            currentTab = "setup"
        end
        return
    elseif currentTab == "matrix" then
        return
    end

    local match_generator = require("match_generator")
    match_generator.update(dt)
    local reSimMatch = match_generator.pollCompleted()
    if reSimMatch then
        loadMatchFile(reSimMatch)
        currentTime = 0.0
        isPlaying = true
        currentTab = "setup"
        resetEventsToTime(0.0)
        match_browser.scanMatchesDir("matches")
        matrix_view.scanMatrix()
    end

    if currentTab == "setup" and not workspace.isPlayback() then return end
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
        p.progress = p.progress + (dt * playbackSpeed) / p.duration

        -- Emit trailing particles
        local isFire = (p.kind == "firebolt")
        local emitChance = isFire and 0.95 or 0.6
        if math.random() < emitChance then
            local curX = p.sx + (p.tx - p.sx) * p.progress
            local curY = p.sy + (p.ty - p.sy) * p.progress
            table.insert(particles, {
                x = curX + (math.random() - 0.5) * (isFire and 6 or 0),
                y = curY + (math.random() - 0.5) * (isFire and 6 or 8),
                vx = (math.random() - 0.5) * (isFire and 35 or 20),
                vy = (math.random() - 0.5) * (isFire and 35 or 20) - (isFire and 15 or 0),
                alpha = 0.9,
                color = isFire and (math.random() < 0.5 and {1.0, 0.8, 0.2} or {1.0, 0.35, 0.05}) or p.color,
                size = isFire and (math.random() * 3 + 2.5) or 3.0,
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

local function drawDrainLifeBeam(sx, sy, tx, ty)
    -- The green current flows from the victim back into the caster. Layered
    -- translucent strokes give the channel a soft glow without a texture/shader.
    local dx, dy = tx - sx, ty - sy
    local length = math.sqrt(dx * dx + dy * dy)
    if length < 1 then return end
    local nx, ny = -dy / length, dx / length
    local phase = currentTime * 7.5
    local steps = 36
    local function pointAt(ratio, strand)
        local envelope = math.sin(math.pi * ratio)
        local wave = math.sin(ratio * 18 - phase + strand * 0.75) * (1.5 + 2.5 * envelope)
        local wobble = math.sin(ratio * 7 + phase * 0.55 + strand * 0.4) * 0.8
        return sx + dx * ratio + nx * (wave + wobble), sy + dy * ratio + ny * (wave + wobble)
    end

    local oldBlend, oldAlpha = love.graphics.getBlendMode()
    love.graphics.setBlendMode("add", "alphamultiply")
    if drainLifeShader and drainLifeMesh then
        drainLifeShader:send("u_time", currentTime)
        love.graphics.setShader(drainLifeShader)
        love.graphics.setColor(1, 1, 1, 0.92)
        love.graphics.push()
        love.graphics.translate(sx, sy)
        love.graphics.rotate(math.atan2(dy, dx))
        love.graphics.scale(length, 22)
        love.graphics.draw(drainLifeMesh)
        love.graphics.pop()
        love.graphics.setShader()
    else
        -- Keep the channel visible on systems where the GPU cannot compile GLSL.
        love.graphics.setLineWidth(5)
        love.graphics.setColor(0.22, 1.0, 0.42, 0.56)
        local px, py = pointAt(0, 0)
        for s = 1, steps do
            local ratio = s / steps
            local qx, qy = pointAt(ratio, 0)
            love.graphics.line(px, py, qx, qy)
            px, py = qx, qy
        end
    end

    -- Bright motes travel from target to caster, reinforcing the drain direction.
    for i = 0, 11 do
        local ratio = (i / 12 + (currentTime * 0.72) % 1) % 1
        local x, y = pointAt(1 - ratio, 1)
        local tailX, tailY = pointAt(math.min(1, 1 - ratio + 0.025), 1)
        local pulse = 0.65 + 0.35 * math.sin(currentTime * 12 + i * 1.7)
        love.graphics.setLineWidth(1.2 + pulse)
        love.graphics.setColor(0.35, 1.0, 0.48, 0.28 * pulse)
        love.graphics.line(x, y, tailX, tailY)
        love.graphics.setColor(0.55, 1.0, 0.70, 0.72 * pulse)
        love.graphics.circle("fill", x, y, 2.2 + pulse * 1.5)
        love.graphics.setColor(0.88, 1.0, 0.9, 0.8 * pulse)
        love.graphics.circle("fill", x, y, 1.0)
    end

    -- A soft siphon bloom on the target and a smaller receiving spark on the caster.
    local pulse = 0.75 + 0.25 * math.sin(currentTime * 9)
    love.graphics.setColor(0.08, 1.0, 0.24, 0.035 * pulse)
    love.graphics.circle("fill", tx, ty, 34 + pulse * 5)
    love.graphics.setColor(0.12, 1.0, 0.32, 0.075 * pulse)
    love.graphics.circle("fill", tx, ty, 22 + pulse * 3)
    love.graphics.setColor(0.42, 1.0, 0.58, 0.16 * pulse)
    love.graphics.circle("fill", tx, ty, 11 + pulse * 2)
    love.graphics.setColor(0.55, 1.0, 0.68, 0.38 * pulse)
    love.graphics.setLineWidth(2)
    love.graphics.circle("line", tx, ty, 13 + pulse * 3)
    love.graphics.setColor(0.55, 1.0, 0.68, 0.12 * pulse)
    love.graphics.circle("fill", sx, sy, 14 + pulse * 3)
    love.graphics.setColor(0.75, 1.0, 0.82, 0.24 * pulse)
    love.graphics.circle("fill", sx, sy, 6 + pulse * 2)
    love.graphics.setBlendMode(oldBlend, oldAlpha)
    love.graphics.setColor(1, 1, 1, 1)
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

local function drawTokenFrame(x, y, radius, color, alpha)
    love.graphics.push("all")
    if tokenFrameShader then
        love.graphics.setBlendMode("add", "alphamultiply")
        tokenFrameShader:send("u_tint", color)
        love.graphics.setShader(tokenFrameShader)
        love.graphics.setColor(1, 1, 1, 0.95 * alpha)
        love.graphics.draw(tokenFrameMesh, x, y, 0, radius / 32, radius / 32)
    else
        love.graphics.setColor(color[1], color[2], color[3], alpha)
        love.graphics.setLineWidth(3 * radius / 32)
        love.graphics.circle("line", x, y, radius)
    end
    love.graphics.pop()
end

local function drawCombatant(x, y, hp, mana, cid, ctmr, ctot, agony, corrup, fear, horror, seduction, unDur, siphon, immolate, color, isLeft, meta, isbDur, isbCharges)
    local side = isLeft and 0 or 1
    if class_view.spec(meta, side) == "priest" then color = spell_visuals.priestToken end
    if class_view.spec(meta, side) == "warrior" then color = spell_visuals.warriorToken end
    -- 1. Ice Barrier Shield Dome
    if unDur > 0.0 and class_view.spec(meta, side) == "frost_mage" then
        love.graphics.setColor(0.2, 0.75, 1.0, 0.20)
        love.graphics.circle("fill", x, y, 42)
        love.graphics.setColor(0.3, 0.85, 1.0, 0.85)
        love.graphics.setLineWidth(2)
        love.graphics.circle("line", x, y, 42)
    end

    -- 2. Token Core with a centered class icon, clipped to the circular frame.
    love.graphics.setColor(0.10, 0.13, 0.20, 1.0)
    love.graphics.circle("fill", x, y, 32)

    -- Clip square class art to the token circle, keeping its full visual scale.
    love.graphics.stencil(function()
        love.graphics.circle("fill", x, y, 31.5)
    end, "replace", 1)
    love.graphics.setStencilTest("greater", 0)
    local drawnClass = icons.drawClassPortrait(class_view.classIcon(meta, side), x, y, 63)
    love.graphics.setStencilTest()
    if not drawnClass then
        love.graphics.setColor(color[1], color[2], color[3], 1.0)
        local emblem = class_view.spec(meta, side) == "frost_mage" and "M" or "W"
        if horror > 0.0 then emblem = "H"
        elseif seduction > 0.0 then emblem = "S"
        elseif fear > 0.0 then emblem = "!"
        elseif unDur > 0.0 and class_view.spec(meta, side) == "frost_mage" then emblem = "S" end
        love.graphics.printf(emblem, x - 15, y - 8, 30, "center")
    end

    -- Status overlay icon centered over character token if active CC/defensive
    if horror > 0.0 then
        icons.draw("horror", x, y, 34, 1, 0.3, 0.3, 0.95)
    elseif seduction > 0.0 then
        icons.draw("seduction", x, y, 34, 0.8, 0.45, 1, 0.95)
    elseif fear > 0.0 then
        icons.draw(class_view.aura(meta, side, "fear"), x, y, 34, 0.9, 0.5, 1, 0.95)
    elseif unDur > 0.0 and class_view.spec(meta, side) == "frost_mage" then
        icons.draw(class_view.aura(meta, side, "icebarrier"), x, y, 34, 0.4, 0.9, 1, 0.95)
    end

    -- Shader draws the crisp team outline and a soft halo in the same pass.
    drawTokenFrame(x, y, 32, color, 1)

    if workspace.getSelected()==side+1 then
        love.graphics.setColor(1,0.83,0.35,0.9)
        love.graphics.setLineWidth(2)
        love.graphics.circle('line',x,y,39)
    end

    -- Directional Eye Marker
    local isCC = (fear > 0.0 or horror > 0.0 or seduction > 0.0)
    local dir = isCC and (isLeft and -1 or 1) or (isLeft and 1 or -1)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.circle("fill", x + dir * 39, y, 4)

    -- 3. Compact overhead vitals; exact values remain in the fixed unit frames.
    local barW = 110
    local halfW = barW * 0.5
    local hpY = y - 56

    local hpPct = vitals.fraction(meta, side, "health", hp)
    local manaPct = vitals.fraction(meta, side, class_view.spec(meta,side)=="warrior" and "rage" or "mana", mana)
    love.graphics.setColor(0.04, 0.06, 0.09, 0.95)
    love.graphics.rectangle("fill", x - halfW - 1, hpY - 1, barW + 2, 13, 2)
    love.graphics.setColor(0.12, 0.18, 0.16, 1)
    love.graphics.rectangle("fill", x - halfW, hpY, barW, 6, 1)
    love.graphics.setColor(0.16, 0.60, 0.23, 1.0)
    love.graphics.rectangle("fill", x - halfW, hpY, barW * hpPct, 6, 1)
    love.graphics.setColor(0.07, 0.12, 0.23, 1)
    love.graphics.rectangle("fill", x - halfW, hpY + 8, barW, 3, 1)
    if class_view.spec(meta,side)=="warrior" then love.graphics.setColor(0.85,0.18,0.12,1) else love.graphics.setColor(0.18, 0.52, 0.95, 1) end
    love.graphics.rectangle("fill", x - halfW, hpY + 8, barW * manaPct, 3, 1)

    -- Buffs & Debuffs with Rotating Masks (Above health bar - clean, no numbers)
    local dbY = hpY - 26
    local dbSize = 22
    local dbSpacing = 25
    local auras = {}
    if horror > 0.0 then table.insert(auras, { icon = "horror", dur = horror, maxDur = 3.0, border = { 0.3, 0.9, 0.3, 1 } }) end
    if seduction > 0.0 then table.insert(auras, { icon = "seduction", dur = seduction, maxDur = 15.0, border = { 0.8, 0.4, 1.0, 1 } }) end
    if fear > 0.0 then table.insert(auras, { icon = class_view.aura(meta, side, "fear"), dur = fear, maxDur = class_view.auraDuration(meta, side, "fear"), border = { 0.85, 0.4, 1.0, 1 } }) end
    if agony > 0.0 then table.insert(auras, { icon = class_view.aura(meta, side, "agony"), dur = agony, maxDur = class_view.auraDuration(meta, side, "agony"), border = { 0.7, 0.3, 0.9, 1 } }) end
    if corrup > 0.0 then table.insert(auras, { icon = class_view.aura(meta, side, "corruption"), dur = corrup, maxDur = class_view.auraDuration(meta, side, "corruption"), border = { 0.95, 0.5, 0.2, 1 } }) end
    if siphon > 0.0 then table.insert(auras, { icon = "siphonlife", dur = siphon, maxDur = 30.0, border = { 0.3, 0.9, 0.65, 1 } }) end
    if immolate > 0.0 then table.insert(auras, { icon = "immolate", dur = immolate, maxDur = 15.0, border = { 1.0, 0.35, 0.1, 1 } }) end
    if isbDur and isbDur > 0.0 then table.insert(auras, { icon = "shadowbolt", dur = isbDur, maxDur = 12.0, border = { 0.6, 0.2, 0.9, 1 }, count = isbCharges }) end
    if unDur > 0.0 and class_view.spec(meta, side) == "frost_mage" then table.insert(auras, { icon = "icebarrier", dur = unDur, maxDur = 20.0, border = { 0.2, 0.85, 1.0, 1 } }) end

    if #auras > 0 then
        local totalAuraW = #auras * dbSpacing - 3
        local curAuraX = x - totalAuraW * 0.5
        for _, aura in ipairs(auras) do
            icons.drawAuraBadge(aura.icon, curAuraX, dbY, dbSize, aura.dur, aura.maxDur, aura.border, aura.count)
            curAuraX = curAuraX + dbSpacing
        end
    end

    -- Instant abilities share the cast bar, full immediately and fading in replay time.
    local flash = workspace.isPlayback() and cast_feedback.instant(MATCH_DATA and MATCH_DATA.events, currentTime, side, meta) or nil
    local castAlpha = 1
    if not (cid > 0 and ctot > 0) and flash then
        cid, ctmr, ctot, castAlpha = flash.id, 0, 1, flash.alpha
    end
    if cid > 0 and ctot > 0 then
        local castY = y + 42
        local cProg = math.max(0, math.min(1.0, (ctot - ctmr) / ctot))
        local spec = class_view.spec(meta, side)
        local isChannel = castAlpha == 1 and ctmr > 0 and
            ((spec == "warlock" and cid == 5) or (spec == "priest" and (cid == 5 or cid == 15)))
        local cIcon = class_view.icon(meta, side, cid)

        local iconSize = 16
        local castBarX = x - halfW + iconSize + 3
        local castBarW = barW - iconSize - 3

        -- Draw Spell Icon with rotating radial mask for remaining cast time
        if cIcon then
            icons.drawRect(cIcon, x - halfW, castY, iconSize, iconSize, 1, 1, 1, castAlpha)
            local remainRatio = math.max(0.0, math.min(1.0, ctmr / ctot))
            icons.drawRadialCooldownMask(x - halfW, castY, iconSize, iconSize, remainRatio, 0.65 * castAlpha)
            love.graphics.setColor(0.4, 0.4, 0.5, 0.9 * castAlpha)
            love.graphics.setLineWidth(1)
            love.graphics.rectangle("line", x - halfW, castY, iconSize, iconSize, 2)
        else
            castBarX = x - halfW
            castBarW = barW
        end

        love.graphics.setColor(0.08, 0.10, 0.15, 0.9 * castAlpha)
        love.graphics.rectangle("fill", castBarX, castY, castBarW, iconSize, 3)

        if isChannel then
            love.graphics.setColor(0.1, 0.8, 0.85, castAlpha)
            love.graphics.rectangle("fill", castBarX, castY, castBarW * (1.0 - cProg), iconSize, 3)
        else
            love.graphics.setColor(0.95, 0.65, 0.1, castAlpha)
            love.graphics.rectangle("fill", castBarX, castY, castBarW * cProg, iconSize, 3)
        end

        love.graphics.setColor(0.25, 0.35, 0.45, 0.8 * castAlpha)
        love.graphics.setLineWidth(1)
        love.graphics.rectangle("line", castBarX, castY, castBarW, iconSize, 3)

        love.graphics.setColor(1, 1, 1, castAlpha)
        local castLabel = class_view.name(meta, side, cid)
        love.graphics.printf(castLabel, castBarX, castY + 1, castBarW, "center")
    end
end

local function playbackControlWidth(w,h)
    local monitor=mcts_overlay.layout(w,h)
    return monitor and monitor.x-368 or w-368
end

local function drawArena(setup)
    local MATCH_DATA = setup or MATCH_DATA
    local projectiles = setup and {} or projectiles
    local particles = setup and {} or particles
    local fctList = setup and {} or fctList
    local screenW, screenH = ui.dimensions()
    local arenaCenterY = screenH * 0.48

    -- ==========================================
    -- 1. SCENE RENDERING (WITH ZOOM & PAN)
    -- ==========================================
    love.graphics.push()
    love.graphics.translate(camera.worldPoint({virtualW=screenW,virtualH=screenH},0,0))
    love.graphics.scale(camera.zoom, camera.zoom)

    drawWorldGrid(screenW, screenH, arenaCenterY)

    local frame = setup and setup.frame or getFrameAtTime(currentTime)
    workspace.setTokenFrame(frame)
    local siphonOnA = not setup and frame and siphonRemaining(0, currentTime, frame[93]) or 0
    local siphonOnB = not setup and frame and siphonRemaining(1, currentTime, frame[94]) or 0
    local immolateOnA = frame and (frame[95] or 0) or 0
    local immolateOnB = frame and (frame[96] or 0) or 0
    local seductionOnA = frame and (frame[101] or 0) or 0
    local seductionOnB = frame and (frame[102] or 0) or 0
    local isbOnA = frame and (frame[105] or 0) or 0
    local isbOnB = frame and (frame[106] or 0) or 0
    local isbChargesA = frame and (frame[107] or 0) or 0
    local isbChargesB = frame and (frame[108] or 0) or 0
    if frame then
        local ax = worldToArenaX(frame[3])
        local bx = worldToArenaX(frame[4])
        local ay = worldToArenaY(frame[49] or 0)
        local by = worldToArenaY(frame[50] or 0)

        -- Pet columns are appended after player missiles. Old replays omit them.
        for side = 0, 1 do
            local idx = 83 + side * 5
            local kind = frame[idx] or 0
            if petNames[kind] then
                local hp = frame[idx + 1] or 0
                local px = worldToArenaX(frame[idx + 2] or 0)
                local py = worldToArenaY(frame[idx + 3] or 0)
                local pTimer = frame[idx + 4] or 0
                local alive = hp > 0
                local teamColor = side == 0 and { 0.68, 0.35, 0.98 } or { 0.10, 0.82, 0.55 }
                local r, g, b = teamColor[1], teamColor[2], teamColor[3]

                -- 1. Pet Icon & Circular Badge (size 24x24)
                local iconSize = 22
                local halfIcon = iconSize * 0.5
                -- Dark background backing
                love.graphics.setColor(0.04, 0.05, 0.08, alive and 0.95 or 0.4)
                love.graphics.circle("fill", px, py, halfIcon + 3)
                -- Match the player portrait's mask and border overlap at pet scale.
                local radius = halfIcon + 2
                local portraitRadius = radius * 31.5 / 32
                love.graphics.stencil(function()
                    love.graphics.circle("fill", px, py, portraitRadius)
                end, "replace", 1)
                love.graphics.setStencilTest("greater", 0)
                local iconName = petIcons[kind]
                if iconName then
                    icons.drawPortrait(iconName, px, py, portraitRadius * 2, alive and 1.0 or 0.4)
                else
                    love.graphics.setColor(r, g, b, alive and 0.95 or 0.3)
                    love.graphics.circle("fill", px, py, 10)
                end
                love.graphics.setStencilTest()
                drawTokenFrame(px, py, radius, teamColor, alive and 1 or 0.4)

                -- 2. HP Bar
                local barW = 44
                local barH = 3
                local barX = px - barW * 0.5
                local hpY = py + halfIcon + 4
                love.graphics.setColor(0.02, 0.03, 0.04, 0.9)
                love.graphics.rectangle("fill", barX, hpY, barW, barH, 2)
                love.graphics.setColor(0.16, 0.60, 0.23, 1)
                love.graphics.rectangle("fill", barX, hpY, barW * math.max(0, math.min(1, hp / petMaxHp[kind])), barH, 2)

                -- 3. Pet Cast Bar
                local petCastTimer = side == 0 and (frame[103] or 0) or (frame[104] or 0)
                local petCastTime = kind == 1 and 2.0 or 1.5
                if alive and ((kind == 1 and pTimer > 0 and pTimer < 2.0) or (kind == 2 and petCastTimer > 0)) then
                    local castBarY = hpY + barH + 2
                    local castRemaining = kind == 1 and pTimer or petCastTimer
                    local castProg = math.max(0, math.min(1, (petCastTime - castRemaining) / petCastTime))
                    local cIconSize = 10
                    local cBarX = barX + cIconSize + 2
                    local cBarW = barW - cIconSize - 2

                    -- Mini cast icon
                    icons.draw(kind == 1 and "firebolt" or "seduction", barX + cIconSize * 0.5, castBarY + cIconSize * 0.5, cIconSize)

                    -- Cast bar track
                    love.graphics.setColor(0.08, 0.10, 0.15, 0.9)
                    love.graphics.rectangle("fill", cBarX, castBarY, cBarW, cIconSize, 2)
                    -- Cast bar fill
                    if kind == 1 then love.graphics.setColor(1.0, 0.55, 0.1, 1.0) else love.graphics.setColor(0.8, 0.4, 1.0, 1.0) end
                    love.graphics.rectangle("fill", cBarX, castBarY, cBarW * castProg, cIconSize, 2)
                    -- Border
                    love.graphics.setColor(0.3, 0.35, 0.45, 0.8)
                    love.graphics.setLineWidth(1)
                    love.graphics.rectangle("line", cBarX, castBarY, cBarW, cIconSize, 2)

                end

            end
        end

        -- Distance connector line
        love.graphics.setColor(0.2, 0.6, 0.9, 0.25)
        love.graphics.setLineWidth(2)
        love.graphics.line(ax, ay, bx, by)

        -- Distance indicator badge
        local midX = (ax + bx) * 0.5
        local midY = (ay + by) * 0.5
        love.graphics.setColor(0.1, 0.14, 0.22, 0.9)
        love.graphics.rectangle("fill", midX - 35, midY + 14, 70, 22, 5)
        love.graphics.setColor(0.3, 0.7, 1.0, 1.0)
        love.graphics.printf(string.format("%.1fm", frame[2]), midX - 35, midY + 18, 70, "center")

        for side = 0, 1 do
            local spec = class_view.spec(MATCH_DATA.meta, side)
            local channel = spell_visuals.channel(spec, frame[11 + side])
            local sx, sy = side == 0 and ax or bx, side == 0 and ay or by
            local tx, ty = side == 0 and bx or ax, side == 0 and by or ay
            if channel == "drain" then
                drawDrainLifeBeam(sx, sy, tx, ty)
            elseif channel then
                spell_visuals.drawChannel(love.graphics, sx, sy - 20, tx, ty - 20,
                    currentTime, spell_visuals.color(spec, frame[11 + side]))
            end
        end

        -- Recorded simulation missiles: four slots per side, spell/damage/x/y.
        if frame[51] then
            for side = 0, 1 do
                for slot = 0, 3 do
                    local idx = 51 + side * 16 + slot * 4
                    local spell = frame[idx]
                    if spell and spell > 0 then
                        local x = worldToArenaX(frame[idx + 2])
                        local y = worldToArenaY(frame[idx + 3]) - 20
                        local spec = class_view.spec(MATCH_DATA.meta, side)
                        local color = spell_visuals.color(spec, spell)
                        local size = spec == "warlock" and spell == 7 and 10 or (spell == 1 and 5 or 8)
                        love.graphics.setColor(color[1], color[2], color[3], 0.2)
                        love.graphics.circle("fill", x, y, size * 2)
                        love.graphics.setColor(color[1], color[2], color[3], 1)
                        love.graphics.circle("fill", x, y, size)
                        love.graphics.setColor(1, 1, 1, 0.9)
                        love.graphics.circle("fill", x, y, size * 0.4)
                    end
                end
            end
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
            elseif p.kind == "firebolt" then
                love.graphics.setColor(1.0, 0.35, 0.05, 0.4)
                love.graphics.circle("fill", curX, curY, 12)
                love.graphics.setColor(1.0, 0.65, 0.15, 1.0)
                love.graphics.circle("fill", curX, curY, 7)
                love.graphics.setColor(1.0, 0.95, 0.7, 0.9)
                love.graphics.circle("fill", curX, curY, 3.5)
            else
                love.graphics.circle("fill", curX, curY, 8)
            end
        end

        -- Particles
        for _, pt in ipairs(particles) do
            love.graphics.setColor(pt.color[1], pt.color[2], pt.color[3], pt.alpha)
            love.graphics.circle("fill", pt.x, pt.y, pt.size or 3)
        end

        -- Separate portraits only; distances, missiles and combat use real positions.
        local visualAX,visualAY,visualBX,visualBY=ax,ay,bx,by
        local chargingA,chargingB=false,false
        if not setup then
            local x,y,charging=warrior_motion.position(MATCH_DATA,currentTime,0,frame[3],frame[49] or 0)
            visualAX,visualAY=worldToArenaX(x),worldToArenaY(y)
            chargingA=charging
            x,y,charging=warrior_motion.position(MATCH_DATA,currentTime,1,frame[4],frame[50] or 0)
            visualBX,visualBY=worldToArenaX(x),worldToArenaY(y)
            chargingB=charging
        end
        local tokenAX,tokenAY,tokenBX,tokenBY=camera.tokenPositions(visualAX,visualAY,visualBX,visualBY)
        if not setup then
            local dx,dy=visualBX-visualAX,visualBY-visualAY
            tokenAX,tokenAY,tokenBX,tokenBY=camera.smoothTokenPositions(
                tokenAX,tokenAY,tokenBX,tokenBY,dx*dx+dy*dy<120*120,
                MATCH_DATA,currentTime,love.timer.getDelta(),chargingA or chargingB)
        else
            camera.resetTokenMotion()
        end
        workspace.setTokenFrame(frame,{tokenAX,tokenAY,tokenBX,tokenBY})
        local function drawPositionArrow(x,y,realX,realY,color)
            local dx,dy=realX-x,realY-y
            local length=math.sqrt(dx*dx+dy*dy)
            if length<2 then return end
            local nx,ny=dx/length,dy/length
            -- Draw above the portraits below so even small offsets remain visible.
            local startX,startY=x+nx*34,y+ny*34
            love.graphics.setColor(0.025,0.035,0.055,0.95)
            love.graphics.setLineWidth(5)
            love.graphics.line(startX,startY,realX,realY)
            love.graphics.setColor(color[1],color[2],color[3],1)
            love.graphics.setLineWidth(2)
            love.graphics.line(startX,startY,realX,realY)
            love.graphics.polygon("fill",realX,realY,
                realX-nx*8-ny*4,realY-ny*8+nx*4,
                realX-nx*8+ny*4,realY-ny*8-nx*4)
            love.graphics.circle("line",realX,realY,3)
        end

        -- Draw combatants with full telemetry at their presentation positions.
        local meta = MATCH_DATA.meta
        drawCombatant(
            tokenAX, tokenAY,
            frame[5], class_view.spec(meta,0)=="warrior" and (frame[125] or 0) or frame[7],                                    -- hp_a, mana_a
            frame[11], frame[13], frame[15],                       -- cast_id_a, cast_timer_a, cast_total_a
            frame[17], frame[19], frame[21], frame[23],            -- agony_a, corruption_a, fear_a, horror_a
            seductionOnA, frame[25],                               -- Seduction, action6_dur_a
            siphonOnA,                                               -- Siphon Life debuff on A
            immolateOnA,                                             -- Immolate debuff on A
            { 0.68, 0.35, 0.98 }, true, meta,
            isbOnA, isbChargesA
        )

        drawCombatant(
            tokenBX, tokenBY,
            frame[6], class_view.spec(meta,1)=="warrior" and (frame[126] or 0) or frame[8],                                    -- hp_b, mana_b
            frame[12], frame[14], frame[16],                       -- cast_id_b, cast_timer_b, cast_total_b
            frame[18], frame[20], frame[22], frame[24],            -- agony_b, corruption_b, fear_b, horror_b
            seductionOnB, frame[26],                               -- Seduction, action6_dur_b
            siphonOnB,                                               -- Siphon Life debuff on B
            immolateOnB,                                             -- Immolate debuff on B
            { 0.10, 0.82, 0.55 }, false, meta,
            isbOnB, isbChargesB
        )

        drawPositionArrow(tokenAX,tokenAY,ax,ay,{0.68,0.35,0.98})
        drawPositionArrow(tokenBX,tokenBY,bx,by,{0.10,0.82,0.55})
        love.graphics.setLineWidth(1)

        -- Floating Combat Text
        local previousFont = love.graphics.getFont()
        ui.setFont("bold")
        for _, item in ipairs(fctList) do
            local scale = 0.82 + (item.scale or 1.0) * 0.10
            love.graphics.push()
            love.graphics.translate(item.x, item.y)
            love.graphics.scale(scale, scale)
            -- Heavy dark outline keeps saturated spell colors legible on any arena color.
            love.graphics.setColor(0.015, 0.025, 0.035, 0.92 * item.alpha)
            for _, offset in ipairs({ { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }) do
                love.graphics.printf(item.text, -100 + offset[1], offset[2], 200, "center")
            end
            love.graphics.setColor(item.color[1], item.color[2], item.color[3], item.alpha)
            love.graphics.printf(item.text, -100, 0, 200, "center")
            love.graphics.pop()
        end
        love.graphics.setFont(previousFont)
    end

    love.graphics.pop()

    -- ==========================================
    -- 2. FIXED HUD & UI (NOT ZOOMED)
    -- ==========================================

    -- Shared classic frames use draft values in setup and recorded telemetry in playback.
    if frame and MATCH_DATA then
        for side=0,1 do
            local school,remaining
            if not setup then school,remaining=spellLockRemaining(side,currentTime) end
            unit_frames.draw(MATCH_DATA.meta,frame,side,side==0 and 16 or screenW-336,12,
                workspace.getSelected()==side+1,{
                    siphon=side==0 and siphonOnA or siphonOnB,
                    immolate=side==0 and immolateOnA or immolateOnB,
                    lockSchool=school,lockRemaining=remaining,drawLock=drawSpellLockBadge,
                    instant=not setup and cast_feedback.instant(MATCH_DATA.events,currentTime,side,MATCH_DATA.meta) or nil,
                })
        end
    end

    -- Setup guidance sits directly on the arena; playback retains its scrubber.
    if setup then
        ui.setFont('normal')
        love.graphics.setColor(ui.colors.textMuted)
        love.graphics.printf(string.format('A: (%.1f, %.1f)    B: (%.1f, %.1f)    Distance: %.1f m',
            frame[3],frame[49] or 0,frame[4],frame[50] or 0,frame[2]),24,screenH-52,screenW-48,'center')
        love.graphics.printf('Drag fighters · Wheel to zoom · Right/middle drag to pan · 0 to reset camera',
            24,screenH-30,screenW-48,'center')
        ui.resetFont()
        return
    end

    -- 2.3 Bottom Controls & Scrubber Panel
    local ctrlY = screenH - 120
    local controlW=playbackControlWidth(screenW,screenH)
    ui.drawCard(352, ctrlY, controlW, 106, false, false, 8)

    -- Scrubber Track
    local scrubX = 372
    local scrubW = playbackControlWidth(screenW,screenH)-40
    local totalT = (MATCH_DATA and MATCH_DATA.meta.total_time) or 1.0
    local scrubPct = math.max(0, math.min(1.0, currentTime / totalT))

    -- Track groove background
    love.graphics.setColor(0.12, 0.16, 0.24, 1.0)
    love.graphics.rectangle("fill", scrubX, ctrlY + 18, scrubW, 8, 4)
    -- Fill highlight with gradient look
    love.graphics.setColor(0.25, 0.70, 0.98, 1.0)
    love.graphics.rectangle("fill", scrubX, ctrlY + 18, scrubW * scrubPct, 8, 4)
    -- Glow scrubber knob
    love.graphics.setColor(0.55, 0.85, 1.0, 0.4)
    love.graphics.circle("fill", scrubX + scrubW * scrubPct, ctrlY + 22, 12)
    love.graphics.setColor(1.0, 1.0, 1.0, 1.0)
    love.graphics.circle("fill", scrubX + scrubW * scrubPct, ctrlY + 22, 7)

    -- Play/Pause Button
    local mx, my = love.mouse.getPosition()
    mx, my = ui.contentPoint(mx, my)
    local btnHover = (mx >= 372 and mx <= 372 + 140 and my >= ctrlY + 36 and my <= ctrlY + 36 + 28)
    ui.button(372, ctrlY + 36, 140, 28, isPlaying and "Pause  [Space]" or "Play  [Space]", btnHover, isPlaying)

    -- Instructions & Shortcuts
    ui.setFont("small")
    love.graphics.setColor(0.65, 0.75, 0.88, 0.9)
    if controlW>=480 then
        love.graphics.print("Arrows: Step · R: Reload · Speed: " .. tostring(playbackSpeed) .. "x", 526, ctrlY + 42)
    end
    ui.resetFont()

    ui.setFont('small')
    love.graphics.setColor(ui.colors.textMuted)
    love.graphics.printf(string.format('%.1fs / %.1fs · %gx', currentTime,
        MATCH_DATA and MATCH_DATA.meta.total_time or 0, playbackSpeed),
        372, ctrlY+88, controlW-40, 'right')
    ui.resetFont()

    if MATCH_DATA then
        local meta=MATCH_DATA.meta
        local outcome=meta.victor==0 and (meta.name_a..' victorious')
            or meta.victor==1 and (meta.name_b..' victorious') or 'In progress'
        love.graphics.setColor(ui.colors.textMuted)
        ui.setFont('small')
        love.graphics.push('all');ui.scissor(372,ctrlY+70,controlW-40,16)
        love.graphics.print(outcome,372,ctrlY+70)
        love.graphics.pop()
        ui.resetFont()
    end

    combat_log.draw(MATCH_DATA,currentTime,16,screenH-200,320,186)

    -- 2.4 Interactive MCTS / PUCT Overlay (Visit distributions & win odds)
    if MATCH_DATA and MATCH_DATA.meta then
        mcts_overlay.draw(currentTime, MATCH_DATA.meta)
    end
end

local function drawContent()
    if currentTab == "setup" then
        workspace.draw(drawArena, MATCH_DATA ~= nil, function(path)
            loadMatchFile(path); currentTime=0; isPlaying=true; resetEventsToTime(0)
        end)
    elseif currentTab == "analysis" then fight_analysis.draw()
    elseif currentTab == "fights" then match_browser.draw()
    elseif currentTab == "matrix" then matrix_view.draw()
    end
end

function love.draw()
    love.graphics.push("all")
    love.graphics.scale(ui.scale())
    drawContent()
    love.graphics.pop()
    love.graphics.push('all')
    love.graphics.scale(ui.scale())
    ui.drawDropdown()
    love.graphics.pop()
end

function love.wheelmoved(x, y)
    if ui.dropdownWheelmoved(y) then return end
    if currentTab == "analysis" then fight_analysis.wheelmoved(y); return end
    if currentTab ~= "setup" then return end
    local mx, my = ui.contentPoint(love.mouse.getPosition())
    if workspace.isPlayback() then
        local lx,ly=workspace.arenaPoint(mx,my)
        if lx and combat_log.wheel(lx,ly,y) then return end
    end
    if workspace.wheelmoved(y) then return end
    if not workspace.arenaPoint(mx, my) then return end
    if y > 0 then camera.zoom = math.min(camera.maxZoom, camera.zoom * 1.15)
    elseif y < 0 then camera.zoom = math.max(camera.minZoom, camera.zoom / 1.15) end
end

function love.keypressed(key)
    if ui.dropdownKeypressed(key) then return end
    if key == "f11" then
        love.window.setFullscreen(not love.window.getFullscreen(), "desktop")
        return
    end

    if key == "f6" or key == "f3" then currentTab = "setup"; return end

    -- Tab switching shortcuts
    if key == "f1" or key == "1" and love.keyboard.isDown("lctrl", "rctrl") then
        currentTab = "setup"
        return
    elseif key == "f2" or key == "2" and love.keyboard.isDown("lctrl", "rctrl") then
        workspace.toggleSettingsSection('replays'); return
    elseif key == "f4" or key == "4" and love.keyboard.isDown("lctrl", "rctrl") then
        workspace.toggleSettingsSection('matrix'); return
    end

    if currentTab == "analysis" then
        if key == "escape" then currentTab = "setup" else fight_analysis.keypressed(key) end
        return
    elseif currentTab == "fights" then
        if key == "escape" then
            currentTab = "setup"
            return
        end
        local matchToLoad = match_browser.keypressed(key)
        if matchToLoad then
            loadMatchFile(matchToLoad)
            currentTime = 0.0
            isPlaying = true
            currentTab = "setup"
        end
        return
    elseif currentTab == "matrix" then
        if key == "escape" then
            currentTab = "setup"
            return
        end
        local matchToLoad = matrix_view.keypressed(key)
        if matchToLoad then
            loadMatchFile(matchToLoad)
            currentTime = 0.0
            isPlaying = true
            currentTab = "setup"
        end
        return
    end

    if currentTab == "setup" then
        if workspace.keypressed(key) then return end
        if not workspace.isPlayback() and key ~= '=' and key ~= '+' and key ~= 'kp+'
            and key ~= '-' and key ~= '_' and key ~= 'kp-' and key ~= '0' and key ~= 'kp0' then return end
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
    elseif key == "o" then
        mcts_overlay.toggle()
    elseif key == "t" then
        mcts_overlay.toggleTuning()
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
        workspace.editPositions()
        camera.isDragging = false
    end
end

function love.mousepressed(x, y, button)
    local menuX,menuY=ui.contentPoint(x,y)
    if ui.dropdownMousepressed(menuX,menuY,button) then
        workspace.mousereleased(1); camera.isDragging=false; return
    end
    local screenW = ui.width()

    x, y = ui.contentPoint(x, y)

    local replayView
    if currentTab == "setup" then
        if workspace.mousepressed(x, y, button) then camera.isDragging = false; return end
        x, y, replayView = workspace.arenaPoint(x, y)
        if not x then return end
        screenW = replayView.virtualW
    end
    if workspace.isPlayback() and x and combat_log.contains(x,y) then return end
    if currentTab == "analysis" then
        local seek = fight_analysis.mousepressed(x, y, button)
        if seek then currentTime = seek; isPlaying = false; resetEventsToTime(seek); workspace.showReplay(); currentTab = "setup" end
        return
    elseif currentTab == "fights" then
        local matchToLoad = match_browser.mousepressed(x, y, button)
        if matchToLoad then
            loadMatchFile(matchToLoad)
            currentTime = 0.0
            isPlaying = true
            currentTab = "setup"
        end
        return
    elseif currentTab == "matrix" then
        local matchToLoad = matrix_view.mousepressed(x, y, button)
        if matchToLoad and type(matchToLoad) == "string" then
            loadMatchFile(matchToLoad)
            currentTime = 0.0
            isPlaying = true
            currentTab = "setup"
        end
        return
    end

    if currentTab == "setup" then
        if workspace.isPlayback() and mcts_overlay.mousepressed(x, y, button) then
            return
        end
    end

    local screenH = replayView and replayView.virtualH or ui.height()
    local ctrlY = screenH - 120
    local scrubX = 372
    local scrubW = playbackControlWidth(screenW,screenH)-40

    if button == 1 and workspace.isPlayback() then
        if x >= 372 and x <= 512 and y >= ctrlY + 36 and y <= ctrlY + 64 then
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
    workspace.mousereleased(button)
    if camera.isDragging and button == camera.dragButton then
        camera.isDragging = false
    end
end

function love.mousemoved(x, y, dx, dy)
    x, y = ui.contentPoint(x, y)
    if currentTab == "setup" then
        workspace.mousemoved(x, y)
        if camera.isDragging then
            x, y = workspace.arenaPoint(x, y, true)
            if not x then camera.isDragging = false; return end
        else return end
    end
    if camera.isDragging then
        camera.x = camera.origPanX + (x - camera.dragStartX)
        camera.y = camera.origPanY + (y - camera.dragStartY)
    end
end

function love.textinput(text)
    if currentTab == "setup" then workspace.textinput(text); return end
end

function love.quit()
    return false
end

-- Run automation inside the normal game source so real fonts/art are loaded.
for _,option in ipairs(arg or {}) do
    if option=='--test-warrior' then
        dofile(love.filesystem.getSource()..'/tests/warrior/main.lua')
        break
    end
end
