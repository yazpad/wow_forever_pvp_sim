-- Race choices; implemented combat racials are tracked in VISUALIZER_TODO.md.
local races = {}
races.labels = {human='Human',gnome='Gnome',orc='Orc',undead='Undead',troll='Troll'}
function races.choices(class)
    return {'human','gnome','orc','undead','troll'}
end
function races.normalize(race,class)
    for _,value in ipairs(races.choices(class)) do if value==race then return value end end
    return 'human'
end
function races.draw(race,x,y,size)
    local icons=require("icons_manager")
    local key="race_"..(races.labels[race] and race or "human")
    if icons.get(key) then
        icons.draw(key,x,y,size)
        return
    end
    local g=love.graphics
    local horde=race=='orc' or race=='undead' or race=='troll'
    g.setColor(horde and 0.65 or 0.22,0.32,horde and 0.24 or 0.65,1)
    g.circle('fill',x,y,size/2)
    g.setColor(0.9,0.77,0.46,1);g.circle('line',x,y,size/2)
    local label=(races.labels[race] or 'Human'):sub(1,1)
    local font=g.getFont()
    g.setColor(1,1,1,1);g.print(label,x-font:getWidth(label)/2,y-font:getHeight()/2)
end
-- Keep exported stats free of racials; match the simulator's pinned Forever build.
function races.critBonus(race)
    return race=='human' and 0.02 or race=='orc' and 0.01 or 0
end
function races.maxMana(race,base)
    return base*(race=='gnome' and 1.05 or 1)
end
return races
