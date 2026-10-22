-- Run from repository root: lua visualizer/test_warrior_talents.lua
package.path = "visualizer/?.lua;" .. package.path
local talents = require("talents_data")
local data = assert(talents.load("warrior"))
assert(table.concat(talents.getClassTrees("warrior"), "/") == "Arms/Fury/Protection")
assert(#data.Arms.talents == 17)
assert(#data.Fury.talents == 18)
assert(#data.Protection.talents == 18)
local seen = {}
for _, tree in pairs(data) do
    for _, talent in ipairs(tree.talents) do
        assert(talent.id > 0 and not seen[talent.id], "Client IDs must be unique and nonzero")
        seen[talent.id] = true
        assert(talent.name ~= "Vitality", "Older export must not add a talent absent from the pinned tree")
        assert(talent.runtime_support=="full" or talent.runtime_support=="partial" or talent.runtime_support=="none")
        for rank = 1, talent.max_ranks do
            local description = assert(talent.descriptions[tostring(rank)])
            assert(not description:find("{%d+}"), "Unresolved tooltip parameter")
        end
    end
end
local build = talents.newEmptyBuild("warrior")
local mastery = assert(talents.findTalent(data, 12295))
local anger = assert(talents.findTalent(data, 12296))
assert(not talents.canInvest(data, build, "Arms", mastery))
build.Arms["16462"] = 5 -- Deflection unlocks row one.
assert(talents.canInvest(data, build, "Arms", mastery))
build.Arms["12295"] = 4
build.Arms["12282"] = 1
assert(not talents.canInvest(data, build, "Arms", anger), "Must require max-rank parent")
build.Arms["12295"] = 5
assert(talents.canInvest(data, build, "Arms", anger))
build.Arms["12296"] = 1
assert(talents.validateBuild(data, build))
local hash = talents.exportHash(data, build, "warrior")
assert(#hash == 53)
local restored = assert(talents.importHash(data, hash, "warrior"))
assert(talents.exportHash(data, restored, "warrior") == hash)
assert(talents.getSummaryString(data, restored, "warrior") == "12/0/0")
-- All Arms talents form a legal 47-point tree; four Fury points reach the cap.
build = talents.newEmptyBuild("warrior")
for _, talent in ipairs(data.Arms.talents) do build.Arms[tostring(talent.id)] = talent.max_ranks end
build.Fury["12320"] = 4
assert(talents.validateBuild(data, build))
local cruelty = assert(talents.findTalent(data, 12320))
local can, reason = talents.canInvest(data, build, "Fury", cruelty)
assert(not can and reason:find("51"), "Cap must count Warrior trees instead of defaulting to Warlock")
build.Fury["12320"] = 5
assert(not talents.validateBuild(data, build))
local enrage = assert(talents.findTalent(data, 12317))
assert(enrage.descriptions["5"]:find("30%% chance") and enrage.descriptions["5"]:find("10%% increased"))
-- Existing kits continue loading their own data.
assert(talents.load("priest").Discipline)
assert(talents.load("warlock").Affliction)
print("Warrior talent data, prerequisites, round trip and 51-point cap passed")
