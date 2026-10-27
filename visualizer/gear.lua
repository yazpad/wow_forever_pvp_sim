-- Offline Vanilla item catalog. Regenerate with scripts/import_vanilla_gear.py.
local json=require('json')
local gear={slots={
    {'head','Head'},{'neck','Neck'},{'shoulder','Shoulders'},{'back','Back'},
    {'chest','Chest'},{'wrist','Wrists'},{'hands','Hands'},{'waist','Waist'},
    {'legs','Legs'},{'feet','Feet'},{'ring1','Ring 1'},{'ring2','Ring 2'},
    {'trinket1','Trinket 1'},{'trinket2','Trinket 2'},
    {'main_hand','Main hand / two-hand'},{'off_hand','Off hand'},{'wand','Wand'},
}}
local file=io.open('data/vanilla_gear.json','r') or io.open('../data/vanilla_gear.json','r')
assert(file,'Missing Vanilla gear catalog')
gear.catalog=json.decode(file:read('*a'));file:close()
local warriorFile=io.open('data/warrior_gear.json') or io.open('../data/warrior_gear.json')
assert(warriorFile,'Missing Warrior gear catalog')
gear.warriorCatalog=json.decode(warriorFile:read('*a'));warriorFile:close()
for _,item in ipairs(gear.warriorCatalog.items) do gear.catalog.items[#gear.catalog.items+1]=item end
local activesFile=io.open('data/item_actives.json') or io.open('../data/item_actives.json')
assert(activesFile,'Missing item effect catalog')
gear.activesCatalog=json.decode(activesFile:read('*a'));activesFile:close()
for _,item in ipairs(gear.activesCatalog.items) do gear.catalog.items[#gear.catalog.items+1]=item end
local items={}
for _,item in ipairs(gear.catalog.items) do items[item.id]=item end
function gear.item(id) return items[id] end
function gear.copy(source)
    local result={}
    for _,slot in ipairs(gear.slots) do result[slot[1]]=source and source[slot[1]] or 0 end
    return result
end
local function kind(slot) return slot:gsub('[12]$','') end
function gear.choices(slot,class)
    local result={0}
    for _,item in ipairs(gear.catalog.items) do
        local matches=item.slot==kind(slot) or (slot=='off_hand' and item.off_hand_eligible)
        if matches and (class~='warrior' or item.class=='warrior' or item.all_classes) and (not item.class or item.class==class) then result[#result+1]=item.id end
    end
    return result
end
function gear.equip(loadout,slot,id,class)
    local valid=false
    for _,candidate in ipairs(gear.choices(slot,class)) do if id==candidate then valid=true end end
    if not valid then return false,'Item cannot be equipped in this slot.' end
    local item=items[id]
    if item and (item.unique or item.unique_group) then
        for other,value in pairs(loadout) do
            if other~=slot and (value==id or (item.unique_group and items[value] and items[value].unique_group==item.unique_group)) then return false,'This item effect is unique.' end
        end
    end
    loadout[slot]=id
    if item and slot=='main_hand' and item.two_hand then loadout.off_hand=0 end
    if id~=0 and slot=='off_hand' and items[loadout.main_hand] and items[loadout.main_hand].two_hand then loadout.main_hand=0 end
    return true
end
function gear.validate(loadout,class)
    if type(loadout)~='table' then return nil,'Invalid equipment.' end
    local known={};for _,slot in ipairs(gear.slots) do known[slot[1]]=true end
    for slot,id in pairs(loadout) do
        if not known[slot] then return nil,'Unknown equipment slot.' end
        if type(id)~='number' or id<0 or id%1~=0 then return nil,'Invalid item ID.' end
    end
    local main=items[loadout.main_hand]
    if main and main.two_hand and (loadout.off_hand or 0)~=0 then
        return nil,'Two-hand weapon conflicts with off hand.'
    end
    local result=gear.copy()
    for _,slot in ipairs(gear.slots) do
        local ok,err=gear.equip(result,slot[1],loadout[slot[1]] or 0,class)
        if not ok then return nil,err end
    end
    if class=='warrior' and not (items[result.main_hand] and items[result.main_hand].weapon) and not gear.activeOnly(result) then return nil,'Equip a main-hand weapon first.' end
    return result
end
function gear.prebis(class)
    -- Fixed-stat alternatives to the guides' random "of Wrath" pieces.
    local result={head=18727,neck=12103,shoulder=18681,back=11623,
        chest=14153,wrist=18497,hands=13253,waist=11662,legs=13170,feet=18735,
        ring1=13001,ring2=12543,trinket1=12930,trinket2=13968,
        main_hand=13964,off_hand=11904,wand=13396}
    if class=='frost_mage' then
        result.shoulder=11782;result.chest=14152;result.feet=11822
        result.ring1=942;result.ring2=942;result.wand=13938
    elseif class=='priest' then
        result.neck=18691;result.chest=14136 -- unrestricted Robe of Winter Night
    else result.neck=18691 end
    return result
end
function gear.totals(loadout)
    local totals={stamina=0,intellect=0,spirit=0,armor=0,spell_power=0,
        shadow_power=0,fire_power=0,frost_power=0,spell_hit=0,spell_crit=0}
    for _,slot in ipairs(gear.slots) do
        local item=items[loadout[slot[1]]]
        if item then for key,value in pairs(item.stats) do totals[key]=(totals[key] or 0)+value end end
    end
    return totals
end
function gear.resolve(loadout,class,base,reference)
    local t=gear.totals(loadout)
    local stats={};for key,value in pairs(base) do stats[key]=value end
    -- Gear adds to the simulator's compact unbuffed baseline. Level-60 PvP
    -- has 96% base spell hit and a 99% cap. Talent bonuses resolve in Zig.
    stats.spell_hit_chance=math.min(0.99,0.96+t.spell_hit/100)
    local intellectCrit=reference and t.intellect*reference.crit_per_intellect or t.intellect/(class=='warlock' and 60.6 or 59.5)/100
    stats.spell_crit_chance=math.min(1,(base.spell_crit_chance or 0)+t.spell_crit/100+intellectCrit)
    stats.armor_damage_reduction=1-(1-(base.armor_damage_reduction or 0))*(1-t.armor/(t.armor+400+85*60))
    if reference then stats.armor_damage_reduction=(reference.armor+t.armor)/(reference.armor+t.armor+5500) end
    for _,school in ipairs({'shadow','fire','frost','arcane'}) do
        local key=school..'_resistance'
        stats[key]=(base[key] or 0)+(t[key] or 0)
    end
    stats.stamina=(base.stamina or 0)+t.stamina
    stats.max_health=(base.max_health or 2000)+t.stamina*10
    stats.max_mana=(base.max_mana or 1000)+t.intellect*15
    stats.shadow_power=(base.shadow_power or 0)+t.spell_power+t.shadow_power
    stats.fire_power=(base.fire_power or 0)+t.spell_power+t.fire_power
    stats.frost_power=(base.frost_power or 0)+t.spell_power+t.frost_power
    return stats,t
end

function gear.pvpItem(loadout)
    for _,slot in ipairs({'trinket1','trinket2'}) do
        local item=items[loadout and loadout[slot]]
        if item and item.effect_id=='forever_greater_insignia_v1' then return item.id end
    end
end
function gear.activeOnly(loadout)
    if not gear.pvpItem(loadout) then return false end
    for slot,id in pairs(loadout) do if id~=0 and slot~='trinket1' and slot~='trinket2' then return false end end
    return true
end
function gear.warriorStarter(kind)
    return gear.copy(assert(gear.warriorCatalog.starters[kind or 'two_hand'],'Unknown Warrior starter'))
end
function gear.resolveWarrior(loadout,base,baseConfig)
    local valid,err=gear.validate(loadout,'warrior')
    if not valid then return nil,err end
    local warrior=require('warrior')
    local config=warrior.copy(baseConfig)
    local main=items[loadout.main_hand]
    if not main and gear.activeOnly(loadout) then
        local stats={};for key,value in pairs(base) do stats[key]=value end;stats.max_mana=1
        return stats,config,gear.totals(loadout)
    end
    config.main_hand=warrior.copy({main_hand=main.weapon}).main_hand
    config.off_hand=nil;config.shield=false
    local block=0
    local off=items[loadout.off_hand]
    if off then
        if off.weapon then config.off_hand=warrior.copy({main_hand=off.weapon}).main_hand
        elseif off.shield_block then config.shield=true;block=off.shield_block
        else return nil,'Invalid Warrior off hand.' end
    end
    local t=gear.totals(loadout)
    local strength,agility=t.strength or 0,t.agility or 0
    config.attack_power=config.attack_power+2*strength+(t.attack_power or 0)
    config.crit=math.min(1,config.crit+agility*0.0005+(t.melee_crit or 0)/100)
    config.white_hit=math.min(1,math.max(0,config.white_hit-(config.off_hand and 0.19 or 0)+(t.melee_hit or 0)/100))
    config.special_hit=math.min(1,config.special_hit+(t.melee_hit or 0)/100)
    local stats={};for key,value in pairs(base) do stats[key]=value end
    stats.stamina=(base.stamina or 0)+t.stamina
    stats.max_health=(base.max_health or 4000)+t.stamina*10
    stats.max_mana=1
    local reduction=base.armor_damage_reduction or 0
    if reduction<1 then
        local armor=5500*reduction/(1-reduction)+t.armor+2*agility
        stats.armor_damage_reduction=armor/(armor+5500)
    end
    stats.melee_dodge_chance=(base.melee_dodge_chance or 0)+(base.melee_avoidance_chance or 0)+agility*0.0005
    stats.melee_avoidance_chance=0
    stats.melee_block_chance=config.shield and math.max(0.05,base.melee_block_chance or 0) or 0
    stats.melee_block_value=config.shield and ((base.melee_block_value or 0)+block+math.max(0,strength*0.05-1)) or 0
    for _,school in ipairs({'shadow','fire','frost','arcane'}) do
        local key=school..'_resistance';stats[key]=(base[key] or 0)+(t[key] or 0)
    end
    local ok,why=warrior.validate(config);if not ok then return nil,why end
    return stats,config,t
end

function gear.detail(id)
    local item=items[id]
    if not item then return 'Empty slot' end
    local lines={item.name}
    local keys={};for key in pairs(item.stats) do keys[#keys+1]=key end;table.sort(keys)
    for _,key in ipairs(keys) do lines[#lines+1]='+'..item.stats[key]..' '..key:gsub('_',' ') end
    if item.weapon then lines[#lines+1]=string.format('%g-%g damage / %.2f sec',item.weapon.min,item.weapon.max,item.weapon.speed) end
    if item.shield_block then lines[#lines+1]=item.shield_block..' shield block value' end
    if item.effect_note then lines[#lines+1]=item.effect_note end
    lines[#lines+1]='Wowhead Classic item '..item.id
    return table.concat(lines,'\n')
end
return gear
