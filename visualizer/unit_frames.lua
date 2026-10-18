local ui = require('ui')
local classes = require('class_view')
local icons = require('icons_manager')
local frames = {}
local pets = {'Imp','Succubus','Felhunter','Voidwalker'}
local petIcons = {'pet_imp','pet_succubus','pet_felhunter','pet_voidwalker'}
local petHp = {500,700,900,1200}
local function clamp(v) return math.max(0,math.min(1,v)) end

-- Keep telemetry decoding shared by both classes, setup, and recorded playback.
function frames.describe(meta,f,side,extra)
    extra=extra or {}
    local function value(index) return f[index+side] or 0 end
    local spec=classes.spec(meta,side)
    local mage=spec=='frost_mage'
    local priest=spec=='priest'
    local kind=value(83+side*4)
    local hp=value(84+side*4)
    local cast=value(11)
    local isChannel=(not mage and cast==5) or (priest and cast==15)
    local result={name=meta[side==0 and 'name_a' or 'name_b'] or (mage and 'Mage' or (priest and 'Priest' or 'Warlock')),
        class=classes.classIcon(meta,side),hp=value(5),mana=value(7),shield=(mage or priest) and value(45) or 0,
        cast=cast,castName=classes.name(meta,side,cast),castIcon=classes.icon(meta,side,cast>0 and cast or value(39)),
        castProgress=clamp(isChannel and value(13)/math.max(0.001,value(15))
            or 1-value(13)/math.max(0.001,value(15))),
        castRemaining=math.max(0,value(13)),cooldowns={},buffs={},debuffs={},
        pet=(not mage and not priest) and pets[kind] and {name=pets[kind],icon=petIcons[kind],hp=hp,maxHp=petHp[kind]} or nil}
    local function cd(icon,index,total)
        result.cooldowns[#result.cooldowns+1]={icon=icon,remaining=value(index),total=total}
    end
    if mage then
        cd('blink',41,15);cd('frostnova',43,25);cd('counterspell',29,24);cd('icebarrier',27,25)
        if value(25)>0 or result.shield>0 then
            result.buffs[1]={icon='icebarrier',remaining=value(25)>0 and value(25) or 20,total=20}
        end
    elseif priest then
        if value(115)>0 then result.buffs[#result.buffs+1]={icon='spell_holy_renew',remaining=value(115),total=15} end
        if value(117)>0 then result.buffs[#result.buffs+1]={icon='spell_frost_windwalkon',remaining=0,total=0} end
        if value(119)>0 then result.buffs[#result.buffs+1]={icon='spell_shadow_shadowform',remaining=0,total=0} end
        if value(121)>0 and value(123)>0 then
            result.buffs[#result.buffs+1]={icon='spell_shadow_blackplague',remaining=value(121),total=15,count=value(123)}
        end
        cd('spell_holy_powerinfusion',113,180)
        if value(111)>0 then result.buffs[#result.buffs+1]={icon='spell_holy_powerinfusion',remaining=value(111),total=15} end
        cd('spell_shadow_unholyfrenzy',29,8);cd('spell_shadow_psychicscream',43,30);cd('spell_shadow_impphaseshift',99,45);cd('spell_holy_powerwordshield',27,15)
        if value(25)>0 or result.shield>0 then
            result.buffs[#result.buffs+1]={icon='spell_holy_powerwordshield',remaining=value(25)>0 and value(25) or 20,total=20}
        end
    else
        cd('deathcoil',29,45);cd('healthstone',27,120)
        if hp>0 and (kind==2 or kind==3) then cd(kind==2 and 'seduction' or 'spell_lock',99,kind==2 and 15 or 24) end
        local wTalents = meta and meta[side==0 and 'warlock_talents_a' or 'warlock_talents_b']
        local slRank = wTalents and wTalents.soul_link or 0
        local dsRank = wTalents and wTalents.demonic_sacrifice or 0
        local dsPet = wTalents and wTalents.demonic_sacrifice_pet or 0
        if not wTalents and meta and meta.specs and meta.specs[side+1] then
            local sp = meta.specs[side+1]
            if sp.class == 'warlock' then
                local dt = sp.trees and sp.trees.Demonology or {}
                slRank = dt['105892'] or dt[105892] or 0
                dsRank = dt['105900'] or dt[105900] or 0
                local kindsMap = { imp=1, succubus=2, felhunter=3, voidwalker=4 }
                dsPet = kindsMap[sp.sacrifice_pet] or 0
            end
        end
        if slRank > 0 and hp > 0 and kind > 0 then
            result.buffs[#result.buffs+1] = { icon = 'soul_link', remaining = 0, total = 0 }
        end
        if dsRank > 0 and dsPet > 0 and petIcons[dsPet] then
            result.buffs[#result.buffs+1] = { icon = petIcons[dsPet], remaining = 0, total = 0 }
        end
    end
    local function aura(icon,remaining,total,count)
        if remaining>0 then result.debuffs[#result.debuffs+1]={icon=icon,remaining=remaining,total=total,count=count} end
    end
    aura('spell_shadow_gathershadows',value(109),3) -- Blackout stun
    aura('horror',value(23),3)
    aura('seduction',value(101),15)
    if extra.lockSchool then
        result.debuffs[#result.debuffs+1]={school=extra.lockSchool,remaining=extra.lockRemaining}
    else aura('counterspell',value(47),4) end
    for _,info in ipairs({{'fear',21},{'agony',17},{'corruption',19}}) do
        local kindName,index=info[1],info[2]
        aura(classes.aura(meta,side,kindName),value(index),classes.auraDuration(meta,side,kindName))
    end
    aura('siphonlife',extra.siphon or value(93),30)
    aura('immolate',extra.immolate or value(95),15)
    local isbTime = extra.isb_timer or value(105)
    local isbCharges = extra.isb_charges or value(107)
    aura('shadowbolt',isbTime,12,isbCharges)
    return result
end

local function text(label,x,y,w,align,alpha)
    local g=love.graphics
    g.push('all');ui.scissor(x,y,w,20)
    g.setColor(0.01,0.015,0.02,alpha or 1);g.printf(label,x+1,y+1,w,align or 'center')
    g.setColor(ui.colors.text[1],ui.colors.text[2],ui.colors.text[3],alpha or 1);g.printf(label,x,y,w,align or 'center');g.pop()
end
local function bar(x,y,w,h,pct,color,label,alpha)
    alpha=alpha or 1
    local g=love.graphics
    g.setColor(0.015,0.025,0.03,1);g.rectangle('fill',x,y,w,h,2)
    g.setColor(color[1],color[2],color[3],alpha);g.rectangle('fill',x+1,y+1,(w-2)*clamp(pct),h-2,1)
    g.setColor(1,1,1,0.09*alpha);g.rectangle('fill',x+1,y+1,(w-2)*clamp(pct),math.max(1,(h-2)/3),1)
    g.setColor(0.42,0.39,0.30,alpha);g.rectangle('line',x,y,w,h,2)
    if label then text(label,x,y+(h-love.graphics.getFont():getHeight())/2,w,nil,alpha) end
end

function frames.draw(meta,f,side,x,y,selected,extra)
    local d=frames.describe(meta,f,side,extra)
    local g=love.graphics
    local w=320
    local edge=selected and ui.colors.accentGold or {0.42,0.39,0.30,1}
    g.push('all');ui.setFont('normal')
    -- Brass rim, inset nameplate and portrait make a single classic silhouette.
    g.setColor(0.025,0.03,0.035,0.97);g.rectangle('fill',x,y,w,#d.buffs>0 and 168 or 142,8)
    g.setLineWidth(selected and 2 or 1);g.setColor(edge);g.rectangle('line',x,y,w,#d.buffs>0 and 168 or 142,8);g.setLineWidth(1)
    local bx,bw=x+72,w-80
    g.setColor(0.12,0.13,0.12,1);g.rectangle('fill',bx,y+4,bw,20,2)
    g.setColor(edge);g.rectangle('line',bx,y+4,bw,20,2)
    text((side==0 and 'A · ' or 'B · ')..d.name,bx+6,y+7,bw-12,'left')
    local hpLabel=string.format('%d HP',math.floor(d.hp))
    if d.shield>0 then hpLabel=hpLabel..string.format(' (+%d)',math.floor(d.shield)) end
    bar(bx,y+27,bw,18,d.hp/(meta[side==0 and 'max_health_a' or 'max_health_b'] or 2000),{0.16,0.60,0.23,1},hpLabel)
    bar(bx,y+48,bw,14,d.mana/(meta[side==0 and 'max_mana_a' or 'max_mana_b'] or 1000),{0.12,0.35,0.73,1},string.format('%d MP',math.floor(d.mana)))
    local cx,cy=x+35,y+34
    g.setColor(0.01,0.015,0.02,1);g.circle('fill',cx,cy,31)
    g.stencil(function() g.circle('fill',cx,cy,28) end,'replace',1)
    g.setStencilTest('greater',0);icons.drawClassIcon(d.class,cx,cy,56);g.setStencilTest()
    g.setColor(edge);g.setLineWidth(selected and 3 or 2);g.circle('line',cx,cy,30);g.setLineWidth(1)
    if selected then
        g.setColor(ui.colors.accentGold);g.polygon('fill',cx-4,y+68,cx+4,y+68,cx,y+73)
    end
    ui.setFont('small')
    local flash=d.cast==0 and extra and extra.instant
    local castIcon=flash and classes.icon(meta,side,flash.id) or d.castIcon
    local alpha=flash and flash.alpha or 1
    icons.drawRect(castIcon,bx,y+65,16,16,1,1,1,alpha)
    ui.setFont('normal')
    bar(bx+19,y+65,bw-19,16,flash and 1 or (d.cast>0 and d.castProgress or 0),{0.72,0.51,0.16,1},
        flash and classes.name(meta,side,flash.id) or
        (d.cast>0 and string.format('%s · %.1fs',d.castName,d.castRemaining) or 'Ready'),alpha)
    if d.pet then
        ui.setFont('small')
        text(d.pet.name,x+6,y+76,60)
        icons.drawRect(d.pet.icon,x+6,y+94,16,16)
        bar(x+26,y+95,40,9,d.pet.hp/d.pet.maxHp,{0.25,0.58,0.30,1})
        text(tostring(math.floor(d.pet.hp))..' HP',x+6,y+112,60)
        ui.setFont('normal')
    end
    ui.setFont('small')
    local cdX=bx
    for _,cd in ipairs(d.cooldowns) do
        icons.drawRect(cd.icon,cdX,y+87,22,22)
        if cd.remaining>0 then icons.drawRadialCooldownMask(cdX,y+87,22,22,clamp(cd.remaining/cd.total),0.7) end
        g.setColor(cd.remaining>0 and ui.colors.accentRed or ui.colors.accentGreen)
        g.rectangle('line',cdX,y+87,22,22,2);cdX=cdX+26
    end
    for i,aura in ipairs(d.buffs) do
        icons.drawAuraBadge(aura.icon,bx+(i-1)*24,y+141,20,aura.remaining,aura.total,{0.2,0.85,1,1},aura.count)
    end
    -- All eight simultaneous effects fit under the vitals, clear of the pet.
    for i,aura in ipairs(d.debuffs) do
        local dx=bx+(i-1)*24
        if aura.school and extra and extra.drawLock then extra.drawLock(dx,y+115,aura.school,aura.remaining)
        else icons.drawAuraBadge(aura.icon,dx,y+115,20,aura.remaining,aura.total,{0.95,0.45,0.35,1},aura.count) end
    end
    g.pop()
    return d
end
return frames
