-- data/dictionaries.lua - Symbol Dictionary Management for BreakFast
local dictionaries = {}

-- Dependencies
local state = require("core/state")
local constants = require("core/constants")
local utils = require("lib/utils")

-- ============================================================================
-- Dictionary Data
-- ============================================================================
-- Dictionaries allow grouping symbols for organization
-- Structure: symbol_dictionaries[dict_name] = {
--     name = string,
--     color = string (from color_definitions),
--     symbols = array (ordered),
--     created_at = timestamp,
--     description = string
-- }

local symbol_dictionaries = {}

-- Reverse lookup cache: symbol -> dict_name
local symbol_to_dictionary_cache = {}

-- ============================================================================
-- Cache Management
-- ============================================================================

-- Rebuild the cache from dictionaries
local function rebuild_cache()
    symbol_to_dictionary_cache = {}
    for dict_name, dict_data in pairs(symbol_dictionaries) do
        if dict_data.symbols then
            for _, symbol in ipairs(dict_data.symbols) do
                symbol_to_dictionary_cache[symbol] = dict_name
            end
        end
    end
    print("DEBUG: Rebuilt dictionary cache with " .. table.count(symbol_to_dictionary_cache) .. " symbol mappings")
end

-- ============================================================================
-- Persistence
-- ============================================================================

-- Load dictionaries from preferences
function dictionaries.load()
    local data = state.get_symbol_dictionaries_data()
    
    if data and data ~= "" then
        local success, loaded = pcall(loadstring("return " .. data))
        if success and loaded then
            symbol_dictionaries = loaded
            rebuild_cache()
            print("DEBUG: Loaded " .. table.count(symbol_dictionaries) .. " dictionaries")
            return true
        else
            print("DEBUG: Failed to load dictionaries, starting with empty")
            symbol_dictionaries = {}
            return false
        end
    else
        print("DEBUG: No saved dictionaries found")
        symbol_dictionaries = {}
        return false
    end
end

-- Save dictionaries to preferences
function dictionaries.save()
    local serialized = utils.serialize_table(symbol_dictionaries)
    state.save_symbol_dictionaries_data(serialized)
    rebuild_cache()
    print("DEBUG: Saved " .. table.count(symbol_dictionaries) .. " dictionaries")
end

-- ============================================================================
-- Dictionary CRUD
-- ============================================================================

-- Create a new dictionary
-- Returns: success (boolean), error_message (string or nil)
function dictionaries.create(name, color, description)
    if not name or name == "" then
        return false, "Dictionary name cannot be empty"
    end
    if symbol_dictionaries[name] then
        return false, "Dictionary '" .. name .. "' already exists"
    end
    
    symbol_dictionaries[name] = {
        name = name,
        color = color or "",
        symbols = {},
        created_at = os.time(),
        description = description or ""
    }
    
    dictionaries.save()
    print("DEBUG: Created dictionary '" .. name .. "'")
    return true
end

-- Rename a dictionary
-- Returns: success (boolean), error_message (string or nil)
function dictionaries.rename(old_name, new_name)
    if not symbol_dictionaries[old_name] then
        return false, "Dictionary '" .. old_name .. "' not found"
    end
    if old_name == new_name then
        return true -- No change needed
    end
    if symbol_dictionaries[new_name] then
        return false, "Dictionary '" .. new_name .. "' already exists"
    end
    
    -- Copy data to new name
    symbol_dictionaries[new_name] = symbol_dictionaries[old_name]
    symbol_dictionaries[new_name].name = new_name
    
    -- Remove old entry
    symbol_dictionaries[old_name] = nil
    
    dictionaries.save()
    print("DEBUG: Renamed dictionary '" .. old_name .. "' to '" .. new_name .. "'")
    return true
end

-- Delete a dictionary (symbols become ungrouped)
-- Returns: success (boolean), error_message (string or nil)
function dictionaries.delete(dict_name)
    if not symbol_dictionaries[dict_name] then
        return false, "Dictionary '" .. dict_name .. "' not found"
    end
    
    symbol_dictionaries[dict_name] = nil
    dictionaries.save()
    print("DEBUG: Deleted dictionary '" .. dict_name .. "'")
    return true
end

-- Set dictionary color
-- Returns: success (boolean), error_message (string or nil)
function dictionaries.set_color(dict_name, color)
    if not symbol_dictionaries[dict_name] then
        return false, "Dictionary '" .. dict_name .. "' not found"
    end
    
    symbol_dictionaries[dict_name].color = color or ""
    dictionaries.save()
    print("DEBUG: Set color '" .. (color or "") .. "' for dictionary '" .. dict_name .. "'")
    return true
end

-- Set dictionary description
-- Returns: success (boolean), error_message (string or nil)
function dictionaries.set_description(dict_name, description)
    if not symbol_dictionaries[dict_name] then
        return false, "Dictionary '" .. dict_name .. "' not found"
    end
    
    symbol_dictionaries[dict_name].description = description or ""
    dictionaries.save()
    return true
end

-- ============================================================================
-- Dictionary Accessors
-- ============================================================================

-- Get dictionary data by name
function dictionaries.get(dict_name)
    return symbol_dictionaries[dict_name]
end

-- Check if a dictionary exists
function dictionaries.exists(dict_name)
    return symbol_dictionaries[dict_name] ~= nil
end

-- Get all dictionary names (sorted alphabetically)
function dictionaries.get_all_names()
    local names = {}
    for name, _ in pairs(symbol_dictionaries) do
        table.insert(names, name)
    end
    table.sort(names)
    return names
end

-- Get dictionary count
function dictionaries.count()
    return table.count(symbol_dictionaries)
end

-- Get all dictionaries (raw table)
function dictionaries.get_all()
    return symbol_dictionaries
end

-- ============================================================================
-- Symbol-Dictionary Operations
-- ============================================================================

-- Get the dictionary name for a symbol (nil if ungrouped)
function dictionaries.get_for_symbol(symbol)
    return symbol_to_dictionary_cache[symbol]
end

-- Add a symbol to a dictionary (removes from any existing dictionary first)
-- Returns: success (boolean), error_message (string or nil)
function dictionaries.add_symbol(symbol, dict_name)
    if not symbol_dictionaries[dict_name] then
        return false, "Dictionary '" .. dict_name .. "' not found"
    end
    
    -- Remove from any existing dictionary first
    for name, dict_data in pairs(symbol_dictionaries) do
        if dict_data.symbols then
            for i, s in ipairs(dict_data.symbols) do
                if s == symbol then
                    table.remove(dict_data.symbols, i)
                    break
                end
            end
        end
    end
    
    -- Add to new dictionary
    table.insert(symbol_dictionaries[dict_name].symbols, symbol)
    
    dictionaries.save()
    print("DEBUG: Added symbol '" .. symbol .. "' to dictionary '" .. dict_name .. "'")
    return true
end

-- Remove a symbol from its current dictionary
-- Returns: success (boolean)
function dictionaries.remove_symbol(symbol)
    local current_dict = symbol_to_dictionary_cache[symbol]
    if not current_dict then
        return true -- Already not in any dictionary
    end
    
    local dict_data = symbol_dictionaries[current_dict]
    if dict_data and dict_data.symbols then
        for i, s in ipairs(dict_data.symbols) do
            if s == symbol then
                table.remove(dict_data.symbols, i)
                dictionaries.save()
                print("DEBUG: Removed symbol '" .. symbol .. "' from dictionary '" .. current_dict .. "'")
                return true
            end
        end
    end
    
    return true
end

-- Get symbols in a specific dictionary
function dictionaries.get_symbols(dict_name)
    local dict_data = symbol_dictionaries[dict_name]
    if dict_data and dict_data.symbols then
        return dict_data.symbols
    end
    return {}
end

-- Get symbol count in a dictionary
function dictionaries.get_symbol_count(dict_name)
    local dict_data = symbol_dictionaries[dict_name]
    if dict_data and dict_data.symbols then
        return #dict_data.symbols
    end
    return 0
end

-- ============================================================================
-- Dictionary View Helpers
-- ============================================================================

-- Get symbols ordered by dictionary (for dictionary view)
-- Returns: array of {symbol = string, dictionary = string or nil}
function dictionaries.get_symbols_ordered()
    local result = {}
    local used_symbols = {}
    
    -- First, add symbols from each dictionary in order
    local dict_names = dictionaries.get_all_names()
    for _, dict_name in ipairs(dict_names) do
        local dict_data = symbol_dictionaries[dict_name]
        if dict_data and dict_data.symbols then
            for _, symbol in ipairs(dict_data.symbols) do
                table.insert(result, {symbol = symbol, dictionary = dict_name})
                used_symbols[symbol] = true
            end
        end
    end
    
    -- Then add ungrouped symbols
    for _, symbol in ipairs(constants.available_symbols) do
        if not used_symbols[symbol] then
            table.insert(result, {symbol = symbol, dictionary = nil})
        end
    end
    
    return result
end

-- Get dropdown items for dictionary selection (with "None" option)
function dictionaries.get_dropdown_items(include_none)
    local items = {}
    
    if include_none then
        table.insert(items, "None")
    end
    
    local names = dictionaries.get_all_names()
    for _, name in ipairs(names) do
        table.insert(items, name)
    end
    
    return items
end

-- Get dropdown index for a symbol's current dictionary
function dictionaries.get_dropdown_index_for_symbol(symbol, include_none)
    local current_dict = symbol_to_dictionary_cache[symbol]
    
    if include_none then
        if not current_dict then
            return 1 -- "None"
        end
        -- Find index in sorted list + 1 for "None"
        local names = dictionaries.get_all_names()
        for i, name in ipairs(names) do
            if name == current_dict then
                return i + 1
            end
        end
        return 1
    else
        if not current_dict then
            return nil
        end
        local names = dictionaries.get_all_names()
        for i, name in ipairs(names) do
            if name == current_dict then
                return i
            end
        end
        return nil
    end
end

-- ============================================================================
-- Utility Functions
-- ============================================================================

-- Clear all dictionaries
function dictionaries.clear_all()
    symbol_dictionaries = {}
    symbol_to_dictionary_cache = {}
    dictionaries.save()
    print("DEBUG: Cleared all dictionaries")
end

-- Check if symbol is in any dictionary
function dictionaries.is_symbol_grouped(symbol)
    return symbol_to_dictionary_cache[symbol] ~= nil
end

return dictionaries
