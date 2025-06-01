-- utils.lua - Utility Functions
local utils = {}

-- Table utility functions
function utils.table_copy(original)
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

-- Add table.count globally if not present
if not table.count then
    function table.count(t)
        local count = 0
        for _ in pairs(t) do
            count = count + 1
        end
        return count
    end
end

function utils.table_find(t, value)
    for i, v in ipairs(t) do
        if v == value then return i end
    end
    return nil
end

-- String utility functions
function utils.string_trim(str)
    return str:match("^%s*(.-)%s*$")
end

-- Add trim method to strings globally for compatibility
if not string.trim then
    function string.trim(str)
        return str:match("^%s*(.-)%s*$")
    end
end

function utils.string_split(str, delimiter)
    local result = {}
    local pattern = string.format("([^%s]+)", delimiter)
    for match in str:gmatch(pattern) do
        table.insert(result, match)
    end
    return result
end

-- Note utility functions
function utils.note_value_to_string(note_value)
    if note_value == 120 then return "OFF"
    elseif note_value == 121 then return "---"
    else
        local octave = math.floor(note_value / 12) - 2
        local note_names = {"C-", "C#", "D-", "D#", "E-", "F-", "F#", "G-", "G#", "A-", "A#", "B-"}
        local note_index = (note_value % 12) + 1
        return string.format("%s%d", note_names[note_index], octave)
    end
end

-- Instrument utility functions
function utils.get_current_instrument()
    local song = renoise.song()
    return song.selected_instrument
end

function utils.get_current_instrument_index()
    local song = renoise.song()
    return song.selected_instrument_index
end

-- Sample utility functions
function utils.has_sliced_samples(instrument)
    return instrument and #instrument.samples > 1
end

function utils.get_slice_count(instrument)
    if not instrument then return 0 end
    return math.max(0, #instrument.samples - 1)
end

-- Phrase utility functions
function utils.has_phrases(instrument)
    return instrument and #instrument.phrases > 0
end

function utils.get_phrase_count(instrument)
    if not instrument then return 0 end
    return #instrument.phrases
end

function utils.clear_phrase(phrase)
    for i = 1, phrase.number_of_lines do
        local line = phrase:line(i)
        for j = 1, 12 do
            line:note_column(j):clear()
        end
        for j = 1, 8 do
            line:effect_column(j):clear()
        end
    end
end

-- Dialog utility functions
function utils.calculate_ui_scale(item_count, base_count)
    base_count = base_count or 16
    return math.max(0.5, math.min(1, base_count / item_count))
end

-- File utility functions
function utils.get_safe_filename(name)
    if not name or name == "" then
        return "untitled"
    end
    -- Replace problematic characters with underscores
    return name:gsub("[%c%p%s]", "_"):gsub("_+", "_"):gsub("^_+", ""):gsub("_+$", "")
end

function utils.ensure_csv_extension(filepath)
    if not filepath:lower():match("%.csv$") then
        return filepath .. ".csv"
    end
    return filepath
end

-- Validation utility functions
function utils.validate_hex_key(key)
    return key and key:match("^%x%x$")
end

function utils.validate_break_string(str)
    if not str or str == "" then
        return false, "Break string cannot be empty"
    end
    
    -- Clean the string
    local cleaned = str:upper():gsub("%s+", "")
    
    -- Check for valid characters (A-E for now, could extend for composite)
    if not cleaned:match("^[A-E]+$") then
        return false, "Break string can only contain letters A through E"
    end
    
    return true, cleaned
end

-- Debug utility functions
function utils.debug_print_table(t, name, indent)
    name = name or "table"
    indent = indent or ""
    
    print(indent .. name .. ":")
    for k, v in pairs(t) do
        if type(v) == "table" then
            utils.debug_print_table(v, tostring(k), indent .. "  ")
        else
            print(indent .. "  " .. tostring(k) .. ": " .. tostring(v))
        end
    end
end

function utils.debug_print_phrase_info(phrase, name)
    name = name or "phrase"
    print("\n=== " .. name .. " Info ===")
    print("Name: " .. phrase.name)
    print("Lines: " .. phrase.number_of_lines)
    print("LPB: " .. phrase.lpb)
    
    local note_count = 0
    for i = 1, phrase.number_of_lines do
        local line = phrase:line(i)
        local note_column = line:note_column(1)
        if note_column.note_value ~= renoise.PatternLine.EMPTY_NOTE then
            note_count = note_count + 1
            print(string.format("Line %02d: %s Inst %02d Delay %03d", 
                i-1, 
                utils.note_value_to_string(note_column.note_value),
                note_column.instrument_value,
                note_column.delay_value))
        end
    end
    print("Total notes: " .. note_count)
    print("========================\n")
end

-- Math utility functions
function utils.clamp(value, min_val, max_val)
    return math.max(min_val, math.min(max_val, value))
end

function utils.round(value)
    return math.floor(value + 0.5)
end

-- Error handling utilities
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

function utils.safe_file_operation(filepath, mode, operation, error_context)
    local file, err = io.open(filepath, mode)
    if not file then
        local context = error_context or "file operation"
        renoise.app():show_error(string.format("Unable to open file for %s: %s", context, tostring(err)))
        return nil
    end
    
    local success, result = pcall(operation, file)
    file:close()
    
    if not success then
        local context = error_context or "file operation"
        renoise.app():show_error(string.format("Error during %s: %s", context, tostring(result)))
        return nil
    end
    
    return result
end

-- Keybinding utility functions
function utils.get_available_keys()
    local keys = {}
    -- A-T (20 keys)
    for i = string.byte('A'), string.byte('T') do
        table.insert(keys, string.char(i))
    end
    -- 0-9 (10 keys)  
    for i = string.byte('0'), string.byte('9') do
        table.insert(keys, string.char(i))
    end
    return keys
end

function utils.get_key_display_items()
    local items = {"None"}
    local available_keys = utils.get_available_keys()
    for _, key in ipairs(available_keys) do
        table.insert(items, key)
    end
    return items
end

-- Add trim method to strings globally for compatibility
if not string.trim then
    function string.trim(str)
        return str:match("^%s*(.-)%s*$")
    end
end

-- Add table.count globally if not present
if not table.count then
    function table.count(t)
        local count = 0
        for _ in pairs(t) do
            count = count + 1
        end
        return count
    end
end

return utils