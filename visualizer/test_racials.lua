-- Run from repository root: lua visualizer/test_racials.lua
package.path='visualizer/?.lua;'..package.path
love={filesystem={getInfo=function() end}}
local races=require('races')
local editor=require('spec_editor')
local function contains(xs,item)
    for _,value in ipairs(xs) do if value==item then return true end end
    return false
end
for _,class in ipairs({'warlock','frost_mage','priest'}) do
    editor.setClass(class)
    for _,race in ipairs({'human','gnome','orc','undead','troll'}) do
        assert(races.normalize(race,class)==race)
        editor.setRace(race)
        local actions=editor.getAvailableActions()
        assert(contains(actions,'Blood Fury')==(race=='orc'))
        assert(contains(actions,'Berserking')==(race=='troll'))
        assert(contains(actions,'Escape Artist')==(race=='gnome'))
        assert(contains(actions,'Will of the Forsaken')==(race=='undead'))
        if race=='gnome' then
            local spec=editor.getCurrentSpecConfig()
            assert(races.maxMana(race,spec.combat_stats.max_mana)==spec.combat_stats.max_mana*1.05)
            editor.setActionSlot(2,'Escape Artist')
            assert(contains(editor.getCurrentSpecConfig().action_loadout,'Escape Artist'))
            editor.setRace('human')
            assert(not contains(editor.getCurrentSpecConfig().action_loadout,'Escape Artist'))
        end
    end
end
print('Forever race combinations, racial action gates, loadout cleanup and unbuffed mana export passed.')
