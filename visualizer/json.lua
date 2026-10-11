-- Ultra-lightweight JSON parser in pure Lua
local json = {}

local function kind_of(obj)
    if type(obj) ~= 'table' then return type(obj) end
    local i = 1
    for _ in pairs(obj) do
        if obj[i] ~= nil then i = i + 1 else return 'table' end
    end
    if i == 1 then return 'table' else return 'array' end
end

local function parse(str, idx)
    idx = idx or 1
    local len = #str

    local function skip_whitespace()
        while idx <= len do
            local b = str:byte(idx)
            if b == 32 or b == 9 or b == 10 or b == 13 then
                idx = idx + 1
            else
                break
            end
        end
    end

    skip_whitespace()
    if idx > len then return nil, idx end

    local c = str:sub(idx, idx)

    if c == '{' then
        local obj = {}
        idx = idx + 1
        skip_whitespace()
        if str:sub(idx, idx) == '}' then
            idx = idx + 1
            return obj, idx
        end
        while idx <= len do
            skip_whitespace()
            local key
            key, idx = parse(str, idx)
            skip_whitespace()
            if str:sub(idx, idx) == ':' then
                idx = idx + 1
            end
            local val
            val, idx = parse(str, idx)
            obj[key] = val
            skip_whitespace()
            local next_c = str:sub(idx, idx)
            if next_c == ',' then
                idx = idx + 1
            elseif next_c == '}' then
                idx = idx + 1
                break
            end
        end
        return obj, idx
    elseif c == '[' then
        local arr = {}
        idx = idx + 1
        skip_whitespace()
        if str:sub(idx, idx) == ']' then
            idx = idx + 1
            return arr, idx
        end
        while idx <= len do
            local val
            val, idx = parse(str, idx)
            table.insert(arr, val)
            skip_whitespace()
            local next_c = str:sub(idx, idx)
            if next_c == ',' then
                idx = idx + 1
            elseif next_c == ']' then
                idx = idx + 1
                break
            end
        end
        return arr, idx
    elseif c == '"' then
        idx = idx + 1
        local start = idx
        while idx <= len do
            local ch = str:sub(idx, idx)
            if ch == '\\' then
                idx = idx + 2
            elseif ch == '"' then
                local res = str:sub(start, idx - 1)
                idx = idx + 1
                return res, idx
            else
                idx = idx + 1
            end
        end
        return str:sub(start, len), idx
    elseif c == 't' and str:sub(idx, idx + 3) == 'true' then
        idx = idx + 4
        return true, idx
    elseif c == 'f' and str:sub(idx, idx + 4) == 'false' then
        idx = idx + 5
        return false, idx
    elseif c == 'n' and str:sub(idx, idx + 3) == 'null' then
        idx = idx + 4
        return nil, idx
    else
        -- Number
        local start = idx
        while idx <= len do
            local ch = str:sub(idx, idx)
            if ch:match('[%d%.%-%+eE]') then
                idx = idx + 1
            else
                break
            end
        end
        local num_str = str:sub(start, idx - 1)
        return tonumber(num_str), idx
    end
end

function json.decode(str)
    local res, _ = parse(str, 1)
    return res
end

return json
