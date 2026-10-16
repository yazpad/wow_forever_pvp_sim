local view = {}
local action_catalog = require("action_catalog")
function view.spec(meta, side)
    return (meta and meta[side == 0 and "spec_a" or "spec_b"]) or "warlock"
end
function view.name(meta, side, id)
    return (action_catalog.names_by_id[view.spec(meta, side)] or action_catalog.names_by_id.warlock)[id] or "Cast"
end
function view.icon(meta, side, id)
    return (action_catalog.icons_by_id[view.spec(meta, side)] or action_catalog.icons_by_id.warlock)[id] or "ui_sword"
end
function view.classIcon(meta, side)
    return view.spec(meta, side) == "frost_mage" and "mage" or "warlock"
end
function view.aura(meta, side, kind)
    local mage = view.spec(meta, kind == "icebarrier" and side or (1-side)) == "frost_mage"
    if mage then
        return ({agony="frostnova", corruption="slow", fear="polymorph"})[kind] or kind
    end
    return kind
end
function view.auraDuration(meta, side, kind)
    local icon = view.aura(meta, side, kind)
    return ({frostnova=4, slow=6, polymorph=4, icebarrier=20, agony=18, corruption=14, fear=4})[icon] or 3
end
function view.drawMagePanel(meta, f, side, x, iconsRef)
    local g, offset = love.graphics, side
    local iconsMgr = iconsRef or _G.icons or require("icons_manager")
    local borderColor = side == 0 and { 0.68, 0.35, 0.98, 0.8 } or { 0.10, 0.82, 0.55, 0.8 }
    local name = side == 0 and (meta and meta.name_a or "Mage A") or (meta and meta.name_b or "Mage B")

    -- Panel background
    g.setColor(0.08, 0.10, 0.16, 0.94)
    g.rectangle("fill", x, 74, 280, 142, 6)
    g.setColor(borderColor[1], borderColor[2], borderColor[3], borderColor[4])
    g.rectangle("line", x, 74, 280, 142, 6)

    -- Row 1: Header (Class Icon, Name & Active Cast/Action)
    iconsMgr.drawClassIcon("mage", x + 18, 92, 28)
    g.setColor(0.95, 0.95, 1.0, 1.0)
    g.print(name, x + 40, 82)

    local cast = f[11 + offset]
    local action = f[39 + offset]
    local actIcon = view.icon(meta, side, cast > 0 and cast or action)
    iconsMgr.drawRect(actIcon, x + 248, 80, 20, 20)
    if cast > 0 and f[15 + offset] > 0 then
        local castProg = math.max(0.0, math.min(1.0, f[13 + offset] / f[15 + offset]))
        iconsMgr.drawRadialCooldownMask(x + 248, 80, 20, 20, castProg, 0.65)
    end
    g.setColor(0.3, 0.4, 0.5, 0.8)
    g.rectangle("line", x + 248, 80, 20, 20, 2)

    -- Row 2: Vitals Bars (HP & MP)
    local hp = f[5 + offset]
    local hpPct = math.max(0, math.min(1.0, hp / 2000.0))
    g.setColor(0.06, 0.08, 0.12, 1.0)
    g.rectangle("fill", x + 40, 102, 228, 12, 2)
    g.setColor(0.2, 0.82, 0.3, 0.95)
    g.rectangle("fill", x + 40, 102, 228 * hpPct, 12, 2)

    -- Shield absorb overlay on HP bar if active
    local shieldAbsorb = f[45 + offset] or 0
    if shieldAbsorb > 0 then
        local shieldPct = math.min(1.0 - hpPct, shieldAbsorb / 2000.0)
        g.setColor(0.25, 0.75, 1.0, 0.85)
        g.rectangle("fill", x + 40 + (228 * hpPct), 102, 228 * shieldPct, 12, 2)
    end

    g.setColor(1, 1, 1, 0.95)
    local hpText = shieldAbsorb > 0 and string.format("%d HP (+%d)", math.floor(hp), math.floor(shieldAbsorb)) or string.format("%d HP", math.floor(hp))
    g.printf(hpText, x + 40, 102, 228, "center")

    local mana = f[7 + offset]
    local manaPct = math.max(0, math.min(1.0, mana / 1000.0))
    g.setColor(0.06, 0.08, 0.12, 1.0)
    g.rectangle("fill", x + 40, 118, 228, 8, 2)
    g.setColor(0.15, 0.65, 0.95, 0.95)
    g.rectangle("fill", x + 40, 118, 228 * manaPct, 8, 2)
    g.setColor(1, 1, 1, 0.85)
    g.printf(string.format("%d MP", math.floor(mana)), x + 40, 117, 228, "center")

    -- Row 3: Cooldowns Row (Blink, Nova, Counterspell, Barrier)
    g.setColor(0.55, 0.65, 0.8, 1.0)
    g.print("CD:", x + 10, 134)

    local cdW, cdH = 22, 22
    local cdY = 132
    local curCdX = x + 40

    local cds = {
        { icon = "blink", cd = f[41 + offset] or 0, maxCd = 15.0 },
        { icon = "frostnova", cd = f[43 + offset] or 0, maxCd = 25.0 },
        { icon = "counterspell", cd = f[29 + offset] or 0, maxCd = 24.0 },
        { icon = "icebarrier", cd = f[27 + offset] or 0, maxCd = 25.0 },
    }

    for _, cdInfo in ipairs(cds) do
        iconsMgr.drawRect(cdInfo.icon, curCdX, cdY, cdW, cdH)
        if cdInfo.cd > 0 then
            iconsMgr.drawRadialCooldownMask(curCdX, cdY, cdW, cdH, math.min(1.0, cdInfo.cd / cdInfo.maxCd), 0.7)
            g.setColor(0.95, 0.35, 0.35, 1.0)
            g.rectangle("line", curCdX, cdY, cdW, cdH, 2)
        else
            g.setColor(0.35, 0.85, 1.0, 1.0)
            g.rectangle("line", curCdX, cdY, cdW, cdH, 2)
        end
        curCdX = curCdX + 28
    end

    -- Row 4: Buffs Row
    g.setColor(0.35, 0.85, 1.0, 1.0)
    g.print("BUFF:", x + 10, 162)
    local bX = x + 48
    local row4Y = 160
    if shieldAbsorb > 0 or (f[25 + offset] and f[25 + offset] > 0) then
        local barrierDur = f[25 + offset] or 20.0
        iconsMgr.drawAuraBadge("icebarrier", bX, row4Y, 20, barrierDur, 20.0, { 0.2, 0.85, 1.0, 1 })
        bX = bX + 24
    end

    -- Row 5: Debuffs Row
    g.setColor(0.95, 0.45, 0.35, 1.0)
    g.print("DEBUFF:", x + 10, 188)
    local debX = x + 64
    local row5Y = 186
    local oppSpec = view.spec(meta, 1 - side)

    if f[23 + offset] > 0 then
        iconsMgr.drawAuraBadge("horror", debX, row5Y, 20, f[23 + offset], 3.0, { 0.3, 0.9, 0.3, 1 })
        debX = debX + 24
    end
    if f[21 + offset] > 0 or (f[101 + side] or 0) > 0 then
        local seduced = (f[101 + side] or 0) > 0
        local ccIcon = seduced and "seduction" or (oppSpec == "frost_mage" and "polymorph" or "fear")
        local ccDuration = seduced and f[101 + side] or f[21 + offset]
        local maxDur = seduced and 15.0 or (oppSpec == "frost_mage" and 4.0 or 6.0)
        iconsMgr.drawAuraBadge(ccIcon, debX, row5Y, 20, ccDuration, maxDur, { 0.85, 0.4, 1.0, 1 })
        debX = debX + 24
    end
    if oppSpec == "frost_mage" then
        if f[17 + offset] > 0 then
            iconsMgr.drawAuraBadge("frostnova", debX, row5Y, 20, f[17 + offset], 4.0, { 0.4, 0.8, 1.0, 1 })
            debX = debX + 24
        end
        if f[19 + offset] > 0 then
            iconsMgr.drawAuraBadge("slow", debX, row5Y, 20, f[19 + offset], 6.0, { 0.3, 0.7, 0.9, 1 })
            debX = debX + 24
        end
    else
        if f[17 + offset] > 0 then
            iconsMgr.drawAuraBadge("agony", debX, row5Y, 20, f[17 + offset], 18.0, { 0.7, 0.3, 0.9, 1 })
            debX = debX + 24
        end
        if f[19 + offset] > 0 then
            iconsMgr.drawAuraBadge("corruption", debX, row5Y, 20, f[19 + offset], 14.0, { 0.95, 0.5, 0.2, 1 })
            debX = debX + 24
        end
        if (f[93 + offset] or 0) > 0 then
            iconsMgr.drawAuraBadge("siphonlife", debX, row5Y, 20, f[93 + offset], 30.0, { 0.3, 0.9, 0.65, 1 })
            debX = debX + 24
        end
        if (f[95 + offset] or 0) > 0 then
            iconsMgr.drawAuraBadge("immolate", debX, row5Y, 20, f[95 + offset], 15.0, { 1.0, 0.35, 0.1, 1 })
            debX = debX + 24
        end
    end
    if (f[47 + offset] or 0) > 0 then
        iconsMgr.drawAuraBadge("counterspell", debX, row5Y, 20, f[47 + offset], 4.0, { 1.0, 0.2, 0.2, 1 })
    end
end
return view
