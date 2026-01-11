-- core/registry.lua - Global Symbol Registry Management for BreakFast
local registry = {}

-- Dependencies
local state = require("core/state")
local constants = require("core/constants")
local utils = require("lib/utils")

-- ============================================================================
-- Registry Data
-- ============================================================================
-- The global symbol registry stores all captured symbols and their data
-- Structure: registry[symbol] = {
--     instrument_index = number,
--     break_set = table,
--     saved_labels = table,
--     tags = array of strings,
--     color = string (color name),
--     symbol_type = string (optional: "range_captured"),
--     source_metadata = table (optional),
--     key = number (0-119, MIDI note value for symbol's root note, optional)
-- }

local global_symbol_registry = {}

-- ============================================================================
-- Basic Accessors
-- ============================================================================

function registry.get()
    return global_symbol_registry
end

function registry.set(new_registry)
    global_symbol_registry = new_registry or {}
end

function registry.get_symbol(symbol)
    return global_symbol_registry[symbol]
end

function registry.set_symbol(symbol, data)
    global_symbol_registry[symbol] = data
end

function registry.remove_symbol(symbol)
    global_symbol_registry[symbol] = nil
end

function registry.has_symbol(symbol)
    return global_symbol_registry[symbol] ~= nil
end

function registry.clear()
    global_symbol_registry = {}
end

function registry.count()
    return table.count(global_symbol_registry)
end

-- ============================================================================
-- Symbol Discovery
-- ============================================================================

-- Get list of all symbols currently in use
function registry.get_used_symbols()
    local used = {}
    for symbol, _ in pairs(global_symbol_registry) do
        table.insert(used, symbol)
    end
    table.sort(used)
    return used
end

-- Find next available symbols (not in use)
function registry.find_next_available(num_needed)
    local used_symbols = {}
    for symbol, _ in pairs(global_symbol_registry) do
        used_symbols[symbol] = true
    end
    
    local available = {}
    for _, symbol in ipairs(constants.available_symbols) do
        if not used_symbols[symbol] and #available < num_needed then
            table.insert(available, symbol)
        end
    end
    
    return available
end

-- Get available symbols for moving (excluding current symbol)
function registry.get_available_for_moving(current_symbol)
    local available = {"Select target..."}  -- Default option
    
    for _, symbol in ipairs(constants.available_symbols) do
        if symbol ~= current_symbol and not global_symbol_registry[symbol] then
            table.insert(available, symbol)
        end
    end
    
    return available
end

-- ============================================================================
-- Symbol Assignment
-- ============================================================================

-- Assign symbols to an instrument's break sets
function registry.assign_to_instrument(instrument_index, break_sets, saved_labels)
    local num_needed = #break_sets
    local available = registry.find_next_available(num_needed)
    
    if #available < num_needed then
        return nil, string.format(
            "Not enough available symbols. Need %d, only %d available.",
            num_needed, #available
        )
    end
    
    -- Assign symbols
    for i = 1, num_needed do
        local symbol = available[i]
        global_symbol_registry[symbol] = {
            instrument_index = instrument_index,
            break_set = break_sets[i],
            saved_labels = saved_labels,
            tags = {},
            color = ""
        }
    end
    
    return available
end

-- ============================================================================
-- Symbol Movement
-- ============================================================================

-- Move a symbol to a new position
-- Returns: success (boolean), error_message (string or nil)
function registry.move_symbol(from_symbol, to_symbol, tag_states, color_states)
    if not global_symbol_registry[from_symbol] then
        return false, "Source symbol " .. from_symbol .. " not found in registry"
    end
    
    if global_symbol_registry[to_symbol] then
        return false, "Target symbol " .. to_symbol .. " is already in use"
    end
    
    if from_symbol == to_symbol then
        return false, "Cannot move symbol to itself"
    end
    
    print("DEBUG: Moving symbol from " .. from_symbol .. " to " .. to_symbol)
    
    -- Deep copy symbol data to new position
    global_symbol_registry[to_symbol] = utils.table_copy(global_symbol_registry[from_symbol])
    
    -- Copy editing states if provided
    if tag_states and tag_states[from_symbol] then
        tag_states[to_symbol] = utils.table_copy(tag_states[from_symbol])
        tag_states[from_symbol] = nil
    end
    
    if color_states and color_states[from_symbol] then
        color_states[to_symbol] = color_states[from_symbol]
        color_states[from_symbol] = nil
    end
    
    -- Remove from old position
    global_symbol_registry[from_symbol] = nil
    
    -- Save changes
    registry.save()
    
    print("DEBUG: Symbol move completed successfully")
    return true
end

-- ============================================================================
-- Symbol-Instrument Mapping
-- ============================================================================

-- Get the instrument index for a symbol
function registry.get_instrument_index(symbol)
    local entry = global_symbol_registry[symbol]
    return entry and entry.instrument_index or nil
end

-- Get break set for a symbol
function registry.get_break_set(symbol)
    local entry = global_symbol_registry[symbol]
    return entry and entry.break_set or nil
end

-- Get saved labels for a symbol
function registry.get_saved_labels(symbol)
    local entry = global_symbol_registry[symbol]
    return entry and entry.saved_labels or {}
end

-- ============================================================================
-- Persistence
-- ============================================================================

-- Load registry from preferences
function registry.load()
    local data = state.get_global_symbol_registry_data()
    
    if data and data ~= "" then
        local success, loaded = pcall(loadstring("return " .. data))
        if success and loaded then
            global_symbol_registry = loaded
            
            -- Ensure backward compatibility: all symbols have tags and color
            for symbol, symbol_data in pairs(global_symbol_registry) do
                -- Convert old category field to tags array
                if symbol_data.category ~= nil and symbol_data.tags == nil then
                    symbol_data.tags = symbol_data.category ~= "" and {symbol_data.category} or {}
                    symbol_data.category = nil
                end
                if symbol_data.tags == nil then
                    symbol_data.tags = {}
                end
                if symbol_data.color == nil then
                    symbol_data.color = ""
                end
            end
            
            print("DEBUG: Loaded global symbol registry with " .. table.count(global_symbol_registry) .. " symbols")
            return true
        else
            print("DEBUG: Failed to load global symbol registry, starting with empty registry")
            global_symbol_registry = {}
            return false
        end
    else
        print("DEBUG: No saved global symbol registry found, starting with empty registry")
        global_symbol_registry = {}
        return false
    end
end

-- Save registry to preferences
function registry.save()
    local serialized = utils.serialize_table(global_symbol_registry)
    state.save_global_symbol_registry_data(serialized)
    print("DEBUG: Saved global symbol registry with " .. table.count(global_symbol_registry) .. " symbols")
end

-- ============================================================================
-- Tags and Colors (direct access for performance)
-- ============================================================================

-- Get tags for a symbol
function registry.get_tags(symbol)
    local entry = global_symbol_registry[symbol]
    if entry then
        -- Handle backward compatibility
        if entry.category and not entry.tags then
            entry.tags = entry.category ~= "" and {entry.category} or {}
            entry.category = nil
        end
        return entry.tags or {}
    end
    return {}
end

-- Set tags for a symbol
function registry.set_tags(symbol, tags)
    if global_symbol_registry[symbol] then
        global_symbol_registry[symbol].tags = tags or {}
    end
end

-- Get color for a symbol
function registry.get_color(symbol)
    local entry = global_symbol_registry[symbol]
    return entry and entry.color or ""
end

-- Set color for a symbol
function registry.set_color(symbol, color)
    if global_symbol_registry[symbol] then
        global_symbol_registry[symbol].color = color or ""
    end
end

-- ============================================================================
-- Key (MIDI root note for transpose support)
-- ============================================================================

-- Get key for a symbol (MIDI note value for symbol's root note)
-- Returns: key (number 0-119) or nil if not set
function registry.get_key(symbol)
    local entry = global_symbol_registry[symbol]
    return entry and entry.key or nil
end

-- Set key for a symbol (MIDI note value for symbol's root note)
-- Returns: success (boolean), error_message (string or nil)
function registry.set_key(symbol, key)
    if not global_symbol_registry[symbol] then
        return false, "Symbol '" .. symbol .. "' not found in registry"
    end
    
    -- Validate key (must be nil or 0-119)
    if key ~= nil then
        key = tonumber(key)
        if not key or key < 0 or key > 119 then
            return false, "Key must be a MIDI note value between 0 and 119"
        end
    end
    
    global_symbol_registry[symbol].key = key
    return true
end

-- ============================================================================
-- Symbol Type Helpers
-- ============================================================================

-- Check if a symbol is a range-captured symbol
function registry.is_range_captured(symbol)
    local entry = global_symbol_registry[symbol]
    return entry and entry.symbol_type == "range_captured"
end

-- Get symbol type
function registry.get_symbol_type(symbol)
    local entry = global_symbol_registry[symbol]
    return entry and entry.symbol_type or "phrase"
end

-- ============================================================================
-- Iteration Helpers
-- ============================================================================

-- Iterate over all symbols with a callback
-- callback(symbol, data) - return false to stop iteration
function registry.for_each(callback)
    for symbol, data in pairs(global_symbol_registry) do
        if callback(symbol, data) == false then
            break
        end
    end
end

-- Get all symbols sorted alphabetically
function registry.get_sorted_symbols()
    local symbols = {}
    for symbol, _ in pairs(global_symbol_registry) do
        table.insert(symbols, symbol)
    end
    table.sort(symbols)
    return symbols
end

return registry
