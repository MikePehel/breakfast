-- json.lua - Lightweight JSON library for Lua 5.1
-- Based on rxi/json.lua, compatible with Lua 5.1
local json = {}

-- Internal functions
local function kind_of(obj)
    if type(obj) ~= 'table' then return type(obj) end
    local i = 1
    for _ in pairs(obj) do
        if obj[i] ~= nil then i = i + 1 else return 'table' end
    end
    if i == 1 then return 'table' else return 'array' end
end

local function escape_str(s)
    local in_char = {'\\', '"', '/', '\b', '\f', '\n', '\r', '\t'}
    local out_char = {'\\', '"', '/', 'b', 'f', 'n', 'r', 't'}
    for i, c in ipairs(in_char) do
        s = s:gsub(c, '\\' .. out_char[i])
    end
    return s
end

-- Returns pos, did_find
local function skip_delim(str, pos, delim, err_if_missing)
    pos = pos + #str:match('^%s*', pos)
    if str:sub(pos, pos) ~= delim then
        if err_if_missing then
            error("Expected '" .. delim .. "' near position " .. pos)
        end
        return pos, false
    end
    return pos + 1, true
end

-- Returns obj, pos
local function parse_str_val(str, pos, val)
    val = val or ''
    local early_end_error = 'End of input found while parsing string.'
    if pos > #str then error(early_end_error) end
    local c = str:sub(pos, pos)
    if c == '"' then return val, pos + 1 end
    if c ~= '\\' then return parse_str_val(str, pos + 1, val .. c) end
    -- We must have a \ character.
    local esc_map = {b = '\b', f = '\f', n = '\n', r = '\r', t = '\t'}
    local nextc = str:sub(pos + 1, pos + 1)
    if not nextc then error(early_end_error) end
    return parse_str_val(str, pos + 2, val .. (esc_map[nextc] or nextc))
end

-- Returns obj, pos
local function parse_num_val(str, pos)
    local num_str = str:match('^-?%d+%.?%d*[eE]?[+-]?%d*', pos)
    local val = tonumber(num_str)
    if not val then error('Error parsing number at position ' .. pos .. '.') end
    return val, pos + #num_str
end

-- Forward declaration
local parse

-- Returns obj, pos
local function parse_array_val(str, pos)
    local obj, key = {}, 1
    local found
    pos, found = skip_delim(str, pos, ']', false)
    if found then return obj, pos end
    local val
    repeat
        val, pos = parse(str, pos)
        obj[key] = val
        key = key + 1
        pos, found = skip_delim(str, pos, ',', false)
    until not found
    pos, found = skip_delim(str, pos, ']', true)
    return obj, pos
end

-- Returns obj, pos
local function parse_obj_val(str, pos)
    local obj = {}
    local found
    pos, found = skip_delim(str, pos, '}', false)
    if found then return obj, pos end
    local key
    repeat
        key, pos = parse(str, pos)
        if type(key) ~= 'string' then
            error('Expecting string key near position ' .. pos)
        end
        pos, found = skip_delim(str, pos, ':', true)
        obj[key], pos = parse(str, pos)
        pos, found = skip_delim(str, pos, ',', false)
    until not found
    pos, found = skip_delim(str, pos, '}', true)
    return obj, pos
end

-- Returns obj, pos
parse = function(str, pos, end_delim)
    pos = pos or 1
    if pos > #str then error('Reached unexpected end of input.') end
    local pos = pos + #str:match('^%s*', pos)  -- Skip whitespace.
    local first = str:sub(pos, pos)
    if first == '{' then  -- Parse object.
        return parse_obj_val(str, pos + 1)
    elseif first == '[' then  -- Parse array.
        return parse_array_val(str, pos + 1)
    elseif first == '"' then  -- Parse string.
        return parse_str_val(str, pos + 1)
    elseif first == '-' or first:match('%d') then  -- Parse number.
        return parse_num_val(str, pos)
    elseif first == end_delim then  -- End of an object or the array.
        return nil, pos + 1
    else  -- Parse true, false, or null.
        local literals = {['true'] = true, ['false'] = false, ['null'] = nil}
        for lit_str, lit_val in pairs(literals) do
            local lit_end = pos + #lit_str - 1
            if str:sub(pos, lit_end) == lit_str then
                return lit_val, lit_end + 1
            end
        end
        local pos_info_str = 'position ' .. pos .. ': ' .. str:sub(pos, pos + 10)
        error('Invalid json syntax starting at ' .. pos_info_str)
    end
end

-- Public interface
function json.encode(obj, as_key)
    local type = type(obj)
    if type == 'string' then
        return '"' .. escape_str(obj) .. '"'
    elseif type == 'number' then
        return tostring(obj)
    elseif type == 'table' then
        local result_str = {}
        local obj_type = kind_of(obj)
        if obj_type == 'array' then
            for i, val in ipairs(obj) do
                table.insert(result_str, json.encode(val))
            end
            return '[' .. table.concat(result_str, ',') .. ']'
        else  -- obj_type is 'table'.
            for key, val in pairs(obj) do
                table.insert(result_str, json.encode(key, true) .. ':' .. json.encode(val))
            end
            return '{' .. table.concat(result_str, ',') .. '}'
        end
    elseif type == 'boolean' then
        return obj and 'true' or 'false'
    elseif type == 'nil' then
        return 'null'
    else
        error('Encoding a ' .. type .. ' is not supported')
    end
end

function json.decode(s)
    if type(s) ~= 'string' then
        error('Expected string, got ' .. type(s))
    end
    local obj, pos = parse(s, 1)
    local pos = pos + #s:match('^%s*', pos)  -- Skip trailing whitespace.
    if pos <= #s then
        error('Trailing garbage after JSON at position ' .. pos)
    end
    return obj
end

return json