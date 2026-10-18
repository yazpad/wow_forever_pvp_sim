-- PVP_SIM: ICONS & TEXTURE MANAGER
local icons = {}

local loadedImages = {}
local classQuads = {}
local classSheet = nil

-- Class grid mapping in UI-CLASSES-CIRCLES.PNG (256x256, 4x4 grid of 64x64 icons)
-- Standard WoW Class Circle layout:
-- Row 0: Warrior, Mage, Rogue, Druid
-- Row 1: Hunter, Shaman, Priest, Warlock
-- Row 2: Paladin, DeathKnight, Monk, DemonHunter
local CLASS_COORDS = {
    warrior = { 0, 0 },
    mage    = { 1, 0 },
    rogue   = { 2, 0 },
    druid   = { 3, 0 },
    hunter  = { 0, 1 },
    shaman  = { 1, 1 },
    priest  = { 2, 1 },
    warlock = { 3, 1 },
    paladin = { 0, 2 },
}

local ICON_FILES = {
    -- Race portraits (Wowhead/ZAM achievement_character_<race>_male icons).
    race_human = "icons/race_human.jpg",
    race_gnome = "icons/race_gnome.jpg",
    race_orc = "icons/race_orc.jpg",
    race_undead = "icons/race_undead.jpg",
    race_troll = "icons/race_troll.jpg",
    -- Classes
    warlock = "icons/class_warlock.png",
    warrior = "icons/class_warrior.png",
    mage    = "icons/class_mage.png",
    priest  = "icons/class_priest.png",
    rogue   = "icons/class_rogue.png",
    druid   = "icons/class_druid.png",
    hunter  = "icons/class_hunter.png",
    paladin = "icons/class_paladin.png",
    shaman  = "icons/class_shaman.png",

    -- Spells / Buffs / Debuffs
    agony           = "icons/spell_shadow_curseofsargeras.png",
    corruption      = "icons/spell_corruption.png",
    fear            = "icons/spell_shadow_possession.png",
    possession      = "icons/spell_shadow_possession.png",
    shadowbolt      = "icons/spell_shadowbolt.png",
    drainlife       = "icons/spell_drainlife.png",
    healthstone      = "icons/inv_stone_04.png",
    deathcoil       = "icons/spell_deathcoil.png",
    siphonlife      = "icons/spell_shadow_requiem.png",
    immolate        = "icons/spell_fire_immolation.png",
    horror          = "icons/spell_horror.png",
    seduction       = "icons/spell_shadow_mindsteal.png",
    spell_lock      = "icons/spell_shadow_mindrot.png",

    -- UI / Indicators
    coin        = "icons/ui_coin.png",
    sword       = "icons/ui_sword.png",
    shield      = "icons/ui_shield.png",
    clock       = "icons/ui_clock.png",
    crown       = "icons/ui_crown.png",
    bone        = "icons/ui_bone.png",
    pvp_banner  = "icons/ui_pvp_banner.png",
    border      = "icons/ui_border.png",
    silver_border = "icons/ui_silver_border.png",

    -- Pets
    pet_imp         = "icons/spell_shadow_summonimp.png",
    pet_succubus    = "icons/ability_warlock_randomizesuccubusincubus.png",
    pet_felhunter   = "icons/spell_shadow_summonfelhunter.png",
    pet_voidwalker  = "icons/spell_shadow_summonvoidwalker.png",
    firebolt        = "icons/spell_fire_fireball02.png",

    -- Warlock Buffs
    soul_link       = "icons/spell_shadow_gathershadows.png",
    spell_shadow_gathershadows = "icons/spell_shadow_gathershadows.png",
    demonic_sacrifice = "icons/spell_shadow_psychicscream.png",
    spell_shadow_psychicscream = "icons/spell_shadow_psychicscream.png",
}

function icons.load()
    -- Load base known files
    for name, path in pairs(ICON_FILES) do
        local info = love.filesystem.getInfo(path) or love.filesystem.getInfo("visualizer/" .. path)
        local resolvedPath = love.filesystem.getInfo(path) and path or ("visualizer/" .. path)
        if info then
            local img = love.graphics.newImage(resolvedPath)
            if img then
                img:setFilter("linear", "linear")
                loadedImages[name] = img
            end
        end
    end

    -- Automatically discover and load all PNGs in icons/ directory
    local iconDirs = { "icons", "visualizer/icons" }
    for _, dir in ipairs(iconDirs) do
        local files = love.filesystem.getDirectoryItems(dir)
        if files and #files > 0 then
            for _, filename in ipairs(files) do
                if filename:match("%.png$") or filename:match("%.PNG$") then
                    local name = filename:gsub("%.[pP][nN][gG]$", ""):lower()
                    if not loadedImages[name] then
                        local fullPath = dir .. "/" .. filename
                        local img = love.graphics.newImage(fullPath)
                        if img then
                            img:setFilter("linear", "linear")
                            loadedImages[name] = img
                            -- Also register without prefix if it starts with spell_ or ui_
                            local cleanName = name:gsub("^spell_", ""):gsub("^ui_", "")
                            if not loadedImages[cleanName] then
                                loadedImages[cleanName] = img
                            end
                        end
                    end
                end
            end
        end
    end

    -- Setup Class Circles if sheet is present
    local sheetPath = "icons/class_circles.png"
    if not love.filesystem.getInfo(sheetPath) and love.filesystem.getInfo("visualizer/" .. sheetPath) then
        sheetPath = "visualizer/" .. sheetPath
    end

    if love.filesystem.getInfo(sheetPath) then
        classSheet = love.graphics.newImage(sheetPath)
        local sw, sh = classSheet:getDimensions()
        local iconSize = 64
        for cls, coords in pairs(CLASS_COORDS) do
            local qx = coords[1] * iconSize
            local qy = coords[2] * iconSize
            classQuads[cls] = love.graphics.newQuad(qx, qy, iconSize, iconSize, sw, sh)
        end
    end
end

function icons.get(name)
    return loadedImages[name]
end

--- Draw an icon centered at (x, y) with specified size (diameter/box)
local frostSymbols = {icelance="IL", frostnova="FN", polymorph="PM", frostbolt="FB", blink="BL", icebarrier="IB", counterspell="CS", slow="SL"}
local function drawFrostSymbol(name, x, y, w, h, alpha)
    local symbol = frostSymbols[name]
    if not symbol then return false end
    love.graphics.setColor(0.08, 0.22, 0.35, alpha or 1)
    love.graphics.rectangle("fill", x, y, w, h, 3)
    love.graphics.setColor(0.4, 0.85, 1, alpha or 1)
    love.graphics.rectangle("line", x, y, w, h, 3)
    love.graphics.printf(symbol, x, y + (h-12)*0.5, w, "center")
    return true
end

function icons.draw(name, x, y, size, r, g, b, a)
    local img = loadedImages[name]
    if not img then return drawFrostSymbol(name, x-size*0.5, y-size*0.5, size, size, a) end

    love.graphics.setColor(r or 1, g or 1, b or 1, a or 1)
    local iw, ih = img:getDimensions()
    local sx = size / iw
    local sy = size / ih
    love.graphics.draw(img, x, y, 0, sx, sy, iw * 0.5, ih * 0.5)
    return true
end

--- Draw an icon top-left aligned at (x, y) with size w, h
function icons.drawRect(name, x, y, w, h, r, g, b, a)
    local img = loadedImages[name]
    if not img then return drawFrostSymbol(name, x, y, w, h, a) end

    love.graphics.setColor(r or 1, g or 1, b or 1, a or 1)
    local iw, ih = img:getDimensions()
    local sx = w / iw
    local sy = (h or w) / ih
    love.graphics.draw(img, x, y, 0, sx, sy)
    return true
end

-- Arena portraits use square art so the caller's circular mask defines the edge.
-- Crop the baked square frame off the standalone icons before scaling.
local portraitQuads = {}
function icons.drawPortrait(className, x, y, size, alpha)
    local cls = (className or "warlock"):lower()
    local img = loadedImages[cls]
    if not img then return false end
    local iw, ih = img:getDimensions()
    local inset = math.min(iw, ih) / 16
    if not portraitQuads[cls] then
        portraitQuads[cls] = love.graphics.newQuad(inset, inset, iw - inset * 2, ih - inset * 2, iw, ih)
    end
    local w, h = iw - inset * 2, ih - inset * 2
    love.graphics.setColor(1, 1, 1, alpha or 1)
    love.graphics.draw(img, portraitQuads[cls], x, y, 0, size / w, size / h, w / 2, h / 2)
    return true
end
icons.drawClassPortrait = icons.drawPortrait

--- Draw class circular icon (from circular texture or standalone icon)
function icons.drawClassIcon(className, x, y, size, r, g, b, a)
    local cls = (className or "warlock"):lower()
    -- If circular quad available, use it for perfect circular framing
    if classSheet and classQuads[cls] then
        love.graphics.setColor(r or 1, g or 1, b or 1, a or 1)
        local q = classQuads[cls]
        local s = size / 64
        love.graphics.draw(classSheet, q, x, y, 0, s, s, 32, 32)
        return true
    end

    -- Fallback to standalone class icon
    local img = loadedImages[cls] or loadedImages["warlock"]
    if img then
        love.graphics.setColor(r or 1, g or 1, b or 1, a or 1)
        local iw, ih = img:getDimensions()
        local sx = size / iw
        local sy = size / ih
        love.graphics.draw(img, x, y, 0, sx, sy, iw * 0.5, ih * 0.5)
        return true
    end
    return false
end

--- Draw a WoW-style radial cooldown sweep / rotating mask over a square/rect area
-- progress: 0.0 to 1.0
-- invert: if true (buffs/debuffs), starts fully bright/clear when fresh and sweeps dark over remaining time as it runs down
function icons.drawRadialCooldownMask(x, y, w, h, progress, alpha, invert)
    if not progress then return end
    local a = alpha or 0.65

    -- For buffs/debuffs, as time runs out (progress: 1.0 down to 0.0),
    -- elapsed portion (1 - progress) is darkened, sweeping clockwise
    local sweepRatio = invert and (1.0 - progress) or progress
    if sweepRatio <= 0.001 then return end
    if sweepRatio >= 0.999 then
        love.graphics.setColor(0.02, 0.02, 0.05, a)
        love.graphics.rectangle("fill", x, y, w, h)
        return
    end

    local cx = x + w * 0.5
    local cy = y + h * 0.5
    local radius = math.sqrt(w * w + h * h) * 0.55

    -- Stencil function creates a scissor box to constrain the fan/pie
    local function stencilFunc()
        love.graphics.rectangle("fill", x, y, w, h)
    end

    love.graphics.stencil(stencilFunc, "replace", 1)
    love.graphics.setStencilTest("greater", 0)

    -- Draw dark rotating sweep
    -- WoW classic sweep starts at 12 o'clock (-pi/2) and sweeps clockwise
    love.graphics.setColor(0.02, 0.02, 0.05, a)
    local startAngle = -math.pi * 0.5
    local sweepAngle = sweepRatio * (math.pi * 2)

    love.graphics.arc("fill", "pie", cx, cy, radius, startAngle, startAngle + sweepAngle, 40)

    -- Bright radial sweep leading edge line
    love.graphics.setColor(1.0, 1.0, 1.0, 0.75)
    love.graphics.setLineWidth(1.5)
    local curAngle = startAngle + sweepAngle
    love.graphics.line(cx, cy, cx + math.cos(curAngle) * radius, cy + math.sin(curAngle) * radius)

    love.graphics.setStencilTest()
end

--- Draw a polished aura/buff/debuff badge with WoW icon, rotating mask, and border
-- duration: current remaining duration
-- maxDuration: full duration (e.g. 18.0s for Agony, 6.0s for Shield)
function icons.drawAuraBadge(iconName, x, y, size, duration, maxDuration, borderCol, count)
    local img = loadedImages[iconName]
    if not img and not frostSymbols[iconName] then return end

    -- Background frame
    love.graphics.setColor(0.04, 0.05, 0.08, 0.95)
    love.graphics.rectangle("fill", x, y, size, size, 3)

    -- Icon inside
    love.graphics.setColor(1, 1, 1, 1)
    icons.drawRect(iconName, x + 1, y + 1, size - 2, size - 2)

    -- Rotating duration mask (invert = true for buffs/debuffs so dark sweep fills as duration elapses)
    if duration and maxDuration and maxDuration > 0 then
        local prog = math.max(0.0, math.min(1.0, duration / maxDuration))
        icons.drawRadialCooldownMask(x + 1, y + 1, size - 2, size - 2, prog, 0.65, true)
    end

    -- Border
    local bCol = borderCol or { 0.3, 0.3, 0.4, 0.8 }
    love.graphics.setColor(bCol[1], bCol[2], bCol[3], bCol[4] or 1.0)
    love.graphics.setLineWidth(1.5)
    love.graphics.rectangle("line", x, y, size, size, 3)

    -- Stack / charge count
    if count and count > 1 then
        love.graphics.push("all")
        local font = love.graphics.getFont()
        local txt = tostring(math.floor(count))
        local tw = font:getWidth(txt)
        local th = font:getHeight()
        love.graphics.setColor(0.01, 0.01, 0.02, 0.85)
        love.graphics.rectangle("fill", x + size - tw - 3, y + size - th - 1, tw + 2, th, 2)
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.print(txt, x + size - tw - 2, y + size - th - 1)
        love.graphics.pop()
    end
end

return icons
