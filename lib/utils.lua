-- lib/utils.lua - Shared utility functions for BreakFast
local utils = {}

-- ============================================================================
-- Global Polyfills
-- ============================================================================
-- These extend Lua's built-in tables/strings for compatibility
-- They are applied globally when this module is first required

-- Add table.count if not present (counts all keys in a table, not just array)
if not table.count then
    function table.count(t)
        local count = 0
        for _ in pairs(t) do
            count = count + 1
        end
        return count
    end
end

-- Add table.find if not present (finds value in array, returns index)
if not table.find then
    function table.find(t, value)
        for i, v in ipairs(t) do
            if v == value then
                return i
            end
        end
        return nil
    end
end

-- Add string.trim if not present
if not string.trim then
    function string.trim(str)
        return str:match("^%s*(.-)%s*$")
    end
end

-- ============================================================================
-- Table Utilities
-- ============================================================================

-- Deep copy a table (recursive)
function utils.table_copy(original)
    if type(original) ~= "table" then
        return original
    end
    local copy = {}
    for key, value in pairs(original) do
        if type(value) == "table" then
            copy[key] = utils.table_copy(value)
        else
            copy[key] = value
        end
    end
    return copy
end

-- Serialize a table to a Lua-parseable string
-- Used for saving tables to preferences
function utils.serialize_table(t, indent)
    indent = indent or 0
    local spacing = string.rep("  ", indent)
    local result = "{\n"
    
    for k, v in pairs(t) do
        local key_str = type(k) == "string" and string.format("[%q]", k) or "[" .. tostring(k) .. "]"
        result = result .. spacing .. "  " .. key_str .. " = "
        
        if type(v) == "table" then
            result = result .. utils.serialize_table(v, indent + 1)
        elseif type(v) == "string" then
            result = result .. string.format("%q", v)
        else
            result = result .. tostring(v)
        end
        result = result .. ",\n"
    end
    
    result = result .. spacing .. "}"
    return result
end

-- Merge two tables (shallow merge, second table wins on conflicts)
function utils.table_merge(base, overlay)
    local result = utils.table_copy(base)
    for k, v in pairs(overlay) do
        result[k] = v
    end
    return result
end

-- Check if a table is empty
function utils.table_is_empty(t)
    return next(t) == nil
end

-- Get sorted keys from a table
function utils.table_keys_sorted(t)
    local keys = {}
    for k in pairs(t) do
        table.insert(keys, k)
    end
    table.sort(keys)
    return keys
end

-- ============================================================================
-- String Utilities
-- ============================================================================

-- Split a string by delimiter
function utils.string_split(str, delimiter)
    local result = {}
    local pattern = string.format("([^%s]+)", delimiter)
    for match in str:gmatch(pattern) do
        table.insert(result, match)
    end
    return result
end

-- Pad string with character to reach target length
function utils.string_pad(str, length, char, right)
    char = char or " "
    str = tostring(str)
    local padding = string.rep(char, math.max(0, length - #str))
    if right then
        return str .. padding
    else
        return padding .. str
    end
end

-- Pad with underscores (commonly used in BreakFast for label formatting)
function utils.pad_with_underscores(str, length)
    str = str or ""
    if #str >= length then
        return str:sub(1, length)
    end
    return str .. string.rep("_", length - #str)
end

-- ============================================================================
-- Note Utilities
-- ============================================================================

-- Convert a numeric note value to string representation (e.g., 48 -> "C-4")
function utils.note_value_to_string(note_value)
    if note_value == 120 then
        return "OFF"
    elseif note_value == 121 then
        return "---"
    elseif note_value == renoise.PatternLine.EMPTY_NOTE then
        return "---"
    else
        local octave = math.floor(note_value / 12) - 2
        local note_names = {"C-", "C#", "D-", "D#", "E-", "F-", "F#", "G-", "G#", "A-", "A#", "B-"}
        local note_index = (note_value % 12) + 1
        return string.format("%s%d", note_names[note_index], octave)
    end
end

-- ============================================================================
-- Math Utilities
-- ============================================================================

-- Clamp a value between min and max
function utils.clamp(value, min_val, max_val)
    return math.max(min_val, math.min(max_val, value))
end

-- Round a number to nearest integer
function utils.round(value)
    return math.floor(value + 0.5)
end

-- ============================================================================
-- Validation Utilities
-- ============================================================================

-- Validate a hex key string (e.g., "00", "1F")
function utils.validate_hex_key(key)
    return key and key:match("^%x%x$") ~= nil
end

-- ============================================================================
-- File Utilities
-- ============================================================================

-- Create a safe filename from a string (replace problematic characters)
function utils.get_safe_filename(name)
    if not name or name == "" then
        return "untitled"
    end
    return name:gsub("[%c%p%s]", "_"):gsub("_+", "_"):gsub("^_+", ""):gsub("_+$", "")
end

-- Ensure a filepath has .csv extension
function utils.ensure_csv_extension(filepath)
    if not filepath:lower():match("%.csv$") then
        return filepath .. ".csv"
    end
    return filepath
end

-- Ensure a filepath has .json extension
function utils.ensure_json_extension(filepath)
    if not filepath:lower():match("%.json$") then
        return filepath .. ".json"
    end
    return filepath
end

-- ============================================================================
-- Error Handling Utilities
-- ============================================================================

-- Safely execute a function with error handling
function utils.safe_call(func, error_message)
    local success, result = pcall(func)
    if not success then
        if error_message then
            renoise.app():show_error(error_message .. "\n\nError: " .. tostring(result))
        else
            renoise.app():show_error("An error occurred: " .. tostring(result))
        end
        return nil
    end
    return result
end

-- Safely access song (returns nil if no song loaded)
function utils.safe_song_access(callback)
    local song = renoise.song()
    if not song then
        renoise.app():show_warning("No song is currently loaded.")
        return nil
    end
    if callback then
        return callback(song)
    end
    return song
end

return utils
