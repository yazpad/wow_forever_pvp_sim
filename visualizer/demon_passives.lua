local passives={}
function passives.describe(spec)
    local t=spec.trees and spec.trees.Demonology or {}
    local function rank(id) return t[tostring(id)] or t[id] or 0 end
    local pet=spec.class=='warlock' and spec.pet or 'none'
    if not pet or pet=='none' then return {power=0} end
    local fractions={0.33,0.67,1}
    local power=(fractions[rank(105893)] or 0)*(spec.combat_stats.level or 60)
    local bonus=rank(105891)*2
    local labels={imp='Fire damage',succubus='Shadow damage',voidwalker='Physical damage taken',felhunter='Magic damage taken'}
    return {power=power,mastery=bonus>0 and labels[pet] and string.format('%s %s%d%%',labels[pet],(pet=='voidwalker' or pet=='felhunter') and '-' or '+',bonus) or nil}
end
return passives
