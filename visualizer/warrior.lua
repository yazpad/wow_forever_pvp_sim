-- Explicit Warrior weapon/resource configuration shared by presets and setup.
local M = {}
local function clone(value)
    if type(value)~='table' then return value end
    local result={};for k,v in pairs(value) do result[k]=clone(v) end;return result
end
M.stances={battle=1,defensive=2,berserker=4}
M.stanceNames={[1]='Battle',[2]='Defensive',[4]='Berserker'}
M.stanceIcons={[1]='ability_warrior_offensivestance',[2]='ability_warrior_defensivestance',[4]='ability_racial_avatar'}
M.support={improvedHeroicStrike='Active in fights',improvedTacticalMastery='Active in fights',boundlessRage='Active in fights',dualWieldSpecialization='Partial: off-hand rage only'}
M.fields={
    {'main_hand.min','Main-hand minimum',0,10000}, {'main_hand.max','Main-hand maximum',0,10000},
    {'main_hand.speed','Main-hand speed',0.1,10}, {'main_hand.two_handed','Weapon type',{true,false}},
    {'off_hand','Off hand',{false,true}}, {'off_hand.min','Off-hand minimum',0,10000},
    {'off_hand.max','Off-hand maximum',0,10000}, {'off_hand.speed','Off-hand speed',0.1,10},
    {'attack_power','Attack power',0,10000}, {'white_hit','Auto attack hit before talents',0,1},
    {'special_hit','Special hit before talents',0,1}, {'crit','Melee crit before talents',0,1},
    {'damage_taken_rage','Incoming rage (provisional)',{true,false}},
    {'starting_rage','Starting rage',0,130}, {'starting_stance','Starting stance',{'battle','defensive','berserker'}},
}
function M.copy(value)
    local defaults={main_hand={min=180,max=270,speed=3.6,two_handed=true},attack_power=700,white_hit=0.95,special_hit=0.95,crit=0.05,starting_rage=0,starting_stance='battle',damage_taken_rage=true,shield=false}
    for k,v in pairs(value or {}) do if k~='build' then defaults[k]=clone(v) end end
    if defaults.off_hand==false then defaults.off_hand=nil end
    return defaults
end
function M.maxRage(spec)
    local tree=spec and spec.trees and spec.trees.Fury or {}
    return 100+10*(tree['1310236'] or tree[1310236] or 0)
end
function M.value(config,key)
    if key=='off_hand' then return type(config.off_hand)=='table' end
    local parent,field=key:match('^([%w_]+)%.([%w_]+)$')
    if parent then return config[parent] and config[parent][field] end
    return config[key]
end
function M.validate(c)
    if c.damage_taken_rage~=nil and type(c.damage_taken_rage)~='boolean' then return false,'Incoming hit rage must be enabled or disabled.' end
    if type(c.shield)~='boolean' then return false,'Shield must be enabled or disabled.' end
    if type(c.main_hand)~='table' then return false,'Main-hand weapon is required.' end
    local function finite(n) return type(n)=='number' and n==n and n~=math.huge and n~=-math.huge end
    for _,weapon in ipairs({c.main_hand,c.off_hand}) do
        if type(weapon)~='table' or not finite(weapon.min) or not finite(weapon.max) or not finite(weapon.speed) or
            weapon.min<0 or weapon.max<weapon.min or weapon.max>10000 or weapon.speed<0.1 or weapon.speed>10 or type(weapon.two_handed)~='boolean' then
            return false,'Weapon needs valid minimum, maximum and speed.'
        end
    end
    if c.shield and (c.main_hand.two_handed or c.off_hand) then return false,'A shield requires a one-handed main hand and no off-hand weapon.' end
    if c.off_hand and (c.main_hand.two_handed or c.off_hand.two_handed) then return false,'Dual wield requires two one-handed weapons.' end
    for _,key in ipairs({'white_hit','special_hit','crit'}) do if not finite(c[key]) or c[key]<0 or c[key]>1 then return false,'Hit and crit must be between 0 and 1.' end end
    if not finite(c.attack_power) or c.attack_power<0 or c.attack_power>10000 or not finite(c.starting_rage) or c.starting_rage<0 or c.starting_rage>130 or not M.stances[c.starting_stance] then return false,'Invalid Warrior stats or starting stance.' end
    return true
end
function M.set(config,key,value)
    local nextConfig=M.copy(config)
    if key=='off_hand' then nextConfig.off_hand=value and {min=55,max=85,speed=1.8,two_handed=false} or nil
    else
        local parent,field=key:match('^([%w_]+)%.([%w_]+)$')
        if parent then
            if not nextConfig[parent] then return nil,'Equip an off-hand weapon first.' end
            nextConfig[parent][field]=value
        else nextConfig[key]=value end
    end
    local ok,err=M.validate(nextConfig);if not ok then return nil,err end
    return nextConfig
end
function M.supportText(talent)
    if talent.runtime_support=='full' then return 'Active in fights' end
    if talent.runtime_support=='partial' then
        if talent.key=='ragingBlows' then return 'Partial: Whirlwind off-hand strike; Cleave pending' end
        return 'Partial: off-hand rage only'
    end
    return M.support[talent.key] or 'Planned: no fight effect yet'
end
return M
