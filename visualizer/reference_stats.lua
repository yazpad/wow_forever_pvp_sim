-- Provisional, opt-in baseline using the pinned local reference snapshot.
local json=require('json')
local reference={name='level60_reference_v1'}
local file=io.open('data/stat_sources/forever_level60.json') or io.open('../data/stat_sources/forever_level60.json')
assert(file,'Missing reference stat data')
reference.data=json.decode(file:read('*a'));file:close()
function reference.baseline(class,race)
    local c=assert(reference.data.classes[class],'Unsupported reference stat class')
    local r=assert(reference.data.race_offsets[race],'Unsupported reference stat race')
    local stamina=c.stamina+r.stamina
    local intellect=c.intellect+r.intellect
    local armor=2*(c.agility+r.agility)
    local coefficient=c.spell_crit_percent_per_intellect/100
    return {level=60,stamina=stamina,
        max_health=c.health+stamina*10+reference.data.resource_offsets.health,
        max_mana=c.mana+intellect*15+reference.data.resource_offsets.mana,
        spell_hit_chance=0.96,
        spell_crit_chance=c.base_spell_crit_percent/100+intellect*coefficient,
        armor_damage_reduction=armor/(armor+5500)},
        {armor=armor,crit_per_intellect=coefficient}
end
return reference
