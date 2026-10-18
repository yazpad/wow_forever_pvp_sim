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
        if item.slot==kind(slot) and (not item.class or item.class==class) then result[#result+1]=item.id end
    end
    return result
end
function gear.equip(loadout,slot,id,class)
    local valid=false
    for _,candidate in ipairs(gear.choices(slot,class)) do if id==candidate then valid=true end end
    if not valid then return false,'Item cannot be equipped in this slot.' end
    local item=items[id]
    if item and item.unique then
        for other,value in pairs(loadout) do
            if other~=slot and value==id then return false,'This item is unique.' end
        end
    end
    loadout[slot]=id
    if item and slot=='main_hand' and item.two_hand then loadout.off_hand=0 end
    if id~=0 and slot=='off_hand' and items[loadout.main_hand] and items[loadout.main_hand].two_hand then loadout.main_hand=0 end
    return true
end
function gear.validate(loadout,class)
    local result=gear.copy()
    for _,slot in ipairs(gear.slots) do
        local ok,err=gear.equip(result,slot[1],loadout[slot[1]] or 0,class)
        if not ok then return nil,err end
    end
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
function gear.resolve(loadout,class,base)
    local t=gear.totals(loadout)
    local stats={};for key,value in pairs(base) do stats[key]=value end
    -- Gear adds to the simulator's compact unbuffed baseline. Level-60 PvP
    -- has 96% base spell hit and a 99% cap. Talent bonuses resolve in Zig.
    stats.spell_hit_chance=math.min(0.99,0.96+t.spell_hit/100)
    stats.spell_crit_chance=math.min(1,(base.spell_crit_chance or 0)+t.spell_crit/100+t.intellect/(class=='warlock' and 60.6 or 59.5)/100)
    stats.armor_damage_reduction=1-(1-(base.armor_damage_reduction or 0))*(1-t.armor/(t.armor+400+85*60))
    for _,school in ipairs({'shadow','fire','frost','arcane'}) do
        local key=school..'_resistance'
        stats[key]=(base[key] or 0)+(t[key] or 0)
    end
    stats.max_health=(base.max_health or 2000)+t.stamina*10
    stats.max_mana=(base.max_mana or 1000)+t.intellect*15
    stats.shadow_power=(base.shadow_power or 0)+t.spell_power+t.shadow_power
    stats.fire_power=(base.fire_power or 0)+t.spell_power+t.fire_power
    stats.frost_power=(base.frost_power or 0)+t.spell_power+t.frost_power
    return stats,t
end
function gear.detail(id)
    local item=items[id]
    if not item then return 'Empty slot' end
    local lines={item.name}
    local keys={};for key in pairs(item.stats) do keys[#keys+1]=key end;table.sort(keys)
    for _,key in ipairs(keys) do lines[#lines+1]='+'..item.stats[key]..' '..key:gsub('_',' ') end
    if item.effect_note then lines[#lines+1]=item.effect_note end
    lines[#lines+1]='Wowhead Classic item '..item.id
    return table.concat(lines,'\n')
end
return gear
