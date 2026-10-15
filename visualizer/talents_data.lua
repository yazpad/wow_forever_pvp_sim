local json = require("json")

local talents = {}
talents.loaded = {}

local CLASS_TREES = {
    warlock = { "Affliction", "Demonology", "Destruction" },
    frost_mage = { "Arcane", "Fire", "Frost" },
    mage = { "Arcane", "Fire", "Frost" },
}

function talents.getClassTrees(className)
    local cls = className and (className:lower()) or "warlock"
    return CLASS_TREES[cls] or CLASS_TREES.warlock
end

function talents.load(className)
    local cls = (className and className:lower()) or "warlock"
    if cls == "mage" then cls = "frost_mage" end

    if talents.loaded[cls] then return talents.loaded[cls] end
    
    local filename = cls == "frost_mage" and "talents_frost_mage.json" or "talents_warlock.json"
    local contents = nil
    if type(love) == "table" and love.filesystem then
        local path = "data/" .. filename
        local info = love.filesystem.getInfo and love.filesystem.getInfo(path)
        if info or (love.filesystem.exists and love.filesystem.exists(path)) then
            contents = love.filesystem.read(path)
        end
    end

    if not contents then
        local f = io.open("visualizer/data/" .. filename, "r") or
                  io.open("data/" .. filename, "r") or
                  io.open("../data/" .. filename, "r") or
                  io.open("data/talents_warlock_forever.json", "r")
        if f then
            contents = f:read("*a")
            f:close()
        end
    end

    if contents then
        local ok, data = pcall(json.decode, contents)
        if ok and data then
            talents.loaded[cls] = data
            return talents.loaded[cls]
        end
    end
    return nil
end

function talents.getRank(invested, talentId)
    if not invested then return 0 end
    return invested[talentId] or invested[tostring(talentId)] or invested[tonumber(talentId)] or 0
end

function talents.findTalent(treeData, talentId)
    for treeName, tree in pairs(treeData) do
        for _, t in ipairs(tree.talents) do
            if t.id == talentId or tostring(t.id) == tostring(talentId) then
                return t, treeName
            end
        end
    end
    return nil, nil
end

function talents.getTreePoints(treeData, build, treeName)
    local count = 0
    local invested = build[treeName] or {}
    local tree = treeData[treeName]
    if not tree then return 0 end
    for _, t in ipairs(tree.talents) do
        count = count + talents.getRank(invested, t.id)
    end
    return count
end

function talents.getTotalPoints(treeData, build, className)
    local total = 0
    local treeCounts = {}
    local treeOrder = talents.getClassTrees(className)
    for _, treeName in ipairs(treeOrder) do
        local pts = talents.getTreePoints(treeData, build, treeName)
        treeCounts[treeName] = pts
        total = total + pts
    end
    return total, treeCounts
end

function talents.getSummaryString(treeData, build, className)
    local _, counts = talents.getTotalPoints(treeData, build, className)
    local treeOrder = talents.getClassTrees(className)
    local c1 = counts[treeOrder[1]] or 0
    local c2 = counts[treeOrder[2]] or 0
    local c3 = counts[treeOrder[3]] or 0
    return string.format("%d/%d/%d", c1, c2, c3)
end

function talents.newEmptyBuild(className)
    local treeOrder = talents.getClassTrees(className)
    local build = {}
    for _, name in ipairs(treeOrder) do
        build[name] = {}
    end
    return build
end

function talents.cloneBuild(build)
    local copy = {}
    for treeName, treeMap in pairs(build) do
        copy[treeName] = {}
        for k, v in pairs(treeMap) do
            copy[treeName][tostring(k)] = v
        end
    end
    return copy
end

function talents.canInvest(treeData, build, treeName, talent)
    local total = talents.getTotalPoints(treeData, build)
    if total >= 51 then
        return false, "Maximum 51 talent points reached"
    end

    local currentRank = talents.getRank(build[treeName], talent.id)
    if currentRank >= talent.max_ranks then
        return false, "Talent already at maximum rank"
    end

    local treePoints = talents.getTreePoints(treeData, build, treeName)
    local requiredPoints = talent.row * 5
    if treePoints < requiredPoints then
        return false, string.format("Requires %d points in %s (currently %d)", requiredPoints, treeName, treePoints)
    end

    if talent.requires and #talent.requires > 0 then
        for _, req in ipairs(talent.requires) do
            local parentRank = talents.getRank(build[treeName], req.id)
            if parentRank < req.qty then
                local parentTalent = talents.findTalent(treeData, req.id)
                local parentName = parentTalent and parentTalent.name or ("Talent #" .. req.id)
                return false, string.format("Requires %d ranks in %s", req.qty, parentName)
            end
        end
    end

    return true, nil
end

function talents.canUninvest(treeData, build, treeName, talent)
    local currentRank = talents.getRank(build[treeName], talent.id)
    if currentRank <= 0 then
        return false, "No points invested in this talent"
    end

    -- Speculatively remove 1 point and check if the resulting tree remains valid
    local testBuild = talents.cloneBuild(build)
    local key = tostring(talent.id)
    testBuild[treeName][key] = currentRank - 1
    if testBuild[treeName][key] <= 0 then
        testBuild[treeName][key] = nil
    end

    local ok, err = talents.validateBuild(treeData, testBuild)
    if not ok then
        return false, err or "Cannot remove point: higher tier or dependent talents require it"
    end

    return true, nil
end

function talents.validateBuild(treeData, build)
    local totalPoints = 0
    local treePoints = {}

    for treeName, tree in pairs(treeData) do
        treePoints[treeName] = 0
        local invested = build[treeName] or {}
        for _, t in ipairs(tree.talents) do
            local rank = talents.getRank(invested, t.id)
            if rank < 0 or rank > t.max_ranks then
                return false, string.format("Invalid rank %d for %s", rank, t.name)
            end
            treePoints[treeName] = treePoints[treeName] + rank
            totalPoints = totalPoints + rank
        end
    end

    if totalPoints > 51 then
        return false, string.format("Exceeds 51 points cap (has %d)", totalPoints)
    end

    -- Validate row requirements and prerequisites
    for treeName, tree in pairs(treeData) do
        local invested = build[treeName] or {}
        for _, t in ipairs(tree.talents) do
            local rank = talents.getRank(invested, t.id)
            if rank > 0 then
                -- Check points in tree before this row
                local pointsInTreeBefore = 0
                for _, other in ipairs(tree.talents) do
                    if other.row < t.row then
                        pointsInTreeBefore = pointsInTreeBefore + talents.getRank(invested, other.id)
                    end
                end
                local required = t.row * 5
                if pointsInTreeBefore < required then
                    return false, string.format("%s requires %d points in %s (only %d before row %d)", t.name, required, treeName, pointsInTreeBefore, t.row)
                end

                -- Check prerequisites
                if t.requires and #t.requires > 0 then
                    for _, req in ipairs(t.requires) do
                        local reqRank = talents.getRank(invested, req.id)
                        if reqRank < req.qty then
                            return false, string.format("%s requires prerequisite talent rank %d", t.name, req.qty)
                        end
                    end
                end
            end
        end
    end

    return true, nil, totalPoints, treePoints
end

-- Export build to digit hash string
function talents.exportHash(treeData, build, className)
    local parts = {}
    local treeOrder = talents.getClassTrees(className)
    for _, treeName in ipairs(treeOrder) do
        local tree = treeData[treeName]
        if tree then
            local invested = build[treeName] or {}
            for _, t in ipairs(tree.talents) do
                local r = talents.getRank(invested, t.id)
                table.insert(parts, tostring(r))
            end
        end
    end
    return table.concat(parts, "")
end

-- Import build from digit hash string or URL
function talents.importHash(treeData, input, className)
    if not input then return nil, "Empty input" end
    -- Strip any URL prefix if present (e.g., https://...#05502323... or ?talents=...)
    local hash = input:match("([0-9]+)$") or input:match("#([0-9]+)") or input:gsub("%s+", "")
    if not hash or #hash == 0 then
        return nil, "Invalid hash string: no digits found"
    end

    local build = talents.newEmptyBuild(className)
    local treeOrder = talents.getClassTrees(className)
    local charIdx = 1
    for _, treeName in ipairs(treeOrder) do
        local tree = treeData[treeName]
        if tree then
            for _, t in ipairs(tree.talents) do
                if charIdx <= #hash then
                    local digit = tonumber(hash:sub(charIdx, charIdx)) or 0
                    if digit > t.max_ranks then digit = t.max_ranks end
                    if digit > 0 then
                        build[treeName][tostring(t.id)] = digit
                    end
                    charIdx = charIdx + 1
                end
            end
        end
    end

    local ok, err = talents.validateBuild(treeData, build)
    if not ok then
        return nil, "Imported build validation failed: " .. tostring(err)
    end
    return build, nil
end

-- Load saved specs from directory
function talents.loadSavedSpecs(dirPath)
    local specsDir = dirPath or "specs"
    local results = {}
    local candidates = { specsDir }
    if specsDir:sub(1, 1) ~= "/" then table.insert(candidates, "../" .. specsDir) end

    for _, p in ipairs(candidates) do
        local handle = io.popen("find '" .. p .. "' -maxdepth 1 -type f -name '*.json' 2>/dev/null")
        if handle then
            for filepath in handle:lines() do
                local f = io.open(filepath, "r")
                if f then
                    local content = f:read("*a")
                    f:close()
                    local ok, specData = pcall(json.decode, content)
                    if ok and specData and specData.trees then
                        specData.filepath = filepath
                        specData.filename = filepath:match("([^/]+)%.json$") or filepath
                        table.insert(results, specData)
                    end
                end
            end
            handle:close()
            if #results > 0 then break end
        end
    end

    -- Sort specs by name
    table.sort(results, function(a, b)
        return (a.name or "") < (b.name or "")
    end)
    return results
end

-- Save a spec JSON to disk
function talents.saveSpec(specData, filename, dirPath)
    local specsDir = dirPath or "specs"
    local cleanName = filename:gsub("[^%w_%-]", "_")
    if not cleanName:match("%.json$") then cleanName = cleanName .. ".json" end
    local fullPath = specsDir .. "/" .. cleanName

    local content = json.encode(specData)
    local f = io.open(fullPath, "w")
    if not f then
        f = io.open("../" .. fullPath, "w")
    end
    if not f then
        return false, "Could not open file for writing: " .. fullPath
    end
    f:write(content)
    f:close()
    return true, fullPath
end

-- Delete a saved spec file
function talents.deleteSpec(filepath)
    if not filepath or #filepath == 0 then return false, "No filepath" end
    local ok, err = os.remove(filepath)
    if not ok and filepath:sub(1, 3) ~= "../" then
        ok, err = os.remove("../" .. filepath)
    end
    return ok, err
end

return talents

