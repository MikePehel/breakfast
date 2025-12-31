-- main.lua - BreakFast Main Entry Point (Phase 5: Multi-Track Support)
local vb = renoise.ViewBuilder()
local labeler = require("labeler")
local breakpoints = require("breakpoints")
local syntax = require("syntax")
local utils = require("utils")
local editor = require("editor")
local selection = require("selection")
local input_lock = require("input_lock")
local json = require("json")


local dialog = nil

-- Forward declarations
local commit_to_phrase
local add_composite_symbol
local current_symbol_index = 0

-- Available composite symbols
local composite_symbols = {"U", "V", "W", "X", "Y", "Z"}

-- Current dialog ViewBuilder reference for composite keybindings
local current_dialog_vb = nil

-- UI collapse state
local ui_collapsed = false

-- Right column collapse state
local right_column_collapsed = false

-- Store formatted labels at module level for pagination access
local current_formatted_labels = {}

-- Overflow behavior constants and state
local overflow_behavior = {
    EXTEND = 1,
    NEXT_PATTERN = 2,
    TRUNCATE = 3,
    LOOP = 4,
    INSERT = 5  -- Always inserts a new pattern after current, moves overflow there
}

local current_overflow_behavior = overflow_behavior.EXTEND

-- UPDATED: Overwrite behavior constants and state (added SUBSTITUTE, RETAIN, EXCLUDE, and INTERSECT)
local overwrite_behavior = {
    SUM = 1,
    REPLACE = 2,
    SUBSTITUTE = 3,
    RETAIN = 4,
    EXCLUDE = 5,
    INTERSECT = 6  -- NEW: Added intersect behavior
}

local current_overwrite_behavior = overwrite_behavior.SUM

-- Instrument source behavior constants and state
local instrument_source_behavior = {
    EMBEDDED = 1,        -- Use embedded instrument values (current behavior)
    CURRENT_SELECTED = 2 -- Use currently selected instrument
}

local current_instrument_source_behavior = instrument_source_behavior.EMBEDDED

-- Phase 5: Multi-track distance mode constants and state
local multi_track_distance_mode = {
    SYNC_FIRST = 1,    -- Sync all tracks to first track's cutoff distance (shortest)
    INDEPENDENT = 2,   -- Each track calculates its own distance independently
    SYNC_LAST = 3      -- Sync all tracks to last track's cutoff distance (longest, no extra notes captured)
}

local current_multi_track_distance_mode = multi_track_distance_mode.SYNC_FIRST

-- Input lock state and callback
local input_lock_active = false
local current_dialog_vb = nil

-- Symbol button feedback tracking
local symbol_button_refs = {} -- Store references to symbol buttons for highlighting

-- Tag system state
local category_view_enabled = false  -- Toggle state for category view button (keep same name for UI compatibility)
local tag_editing_states = {}       -- Track which symbols have saved tags: symbol -> {tag_index -> boolean}
local color_editing_states = {}     -- Track which symbols have saved colors: symbol -> boolean

-- Organize system state
local organize_view_enabled = false  -- Toggle state for organize view button (default off)

-- Detailed view state
local detailed_view_enabled = false  -- Toggle state for detailed view button (default off)
local expanded_symbol = nil          -- Track which symbol is currently expanded

-- Phase 4: Dictionary view state
local dictionary_view_enabled = false  -- Toggle state for dictionary view button (default off)

-- Phase 4: Symbol Dictionaries data structure
-- symbol_dictionaries[dict_name] = {
--     name = string,
--     color = string (from color_definitions),
--     symbols = array (ordered),
--     created_at = timestamp,
--     description = string
-- }
local symbol_dictionaries = {}
local symbol_to_dictionary_cache = {}  -- Reverse lookup cache: symbol -> dict_name

-- Global symbol registry for cross-instrument symbol management
local global_symbol_registry = {}
local available_symbols = {"A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9"}

-- Color definitions for symbol color coding (Using Matched Saturation Hex and 35% Darker OKHSL)
local color_definitions = {
  [""] = {original = nil, darker = nil}, -- No color
  ["Green"] = {original = {0x9d, 0xeb, 0x6d}, darker = {0x40, 0x89, 0x00}},
  ["Pink"] = {original = {0xf5, 0x72, 0xb2}, darker = {0x9d, 0x1d, 0x66}},
  ["Purple"] = {original = {0xb5, 0x72, 0xf5}, darker = {0x6d, 0x24, 0xa5}},
  ["Blue"] = {original = {0x71, 0xb2, 0xf2}, darker = {0x1f, 0x62, 0x9c}},
  ["Yellow"] = {original = {0xdd, 0xdd, 0x67}, darker = {0x7e, 0x7c, 0x00}},
  ["Orange"] = {original = {0xef, 0xb0, 0x6f}, darker = {0x93, 0x5a, 0x10}},
  ["Red"] = {original = {0xf5, 0x72, 0x72}, darker = {0x9f, 0x20, 0x2b}}
}

-- Color dropdown items (ordered list for popup)
local color_dropdown_items = {"", "Green", "Pink", "Purple", "Blue", "Yellow", "Orange", "Red"}

-- Color editing states (similar to category system)
local color_editing_states = {}

-- Set up tool preferences for global symbol registry persistence (declare early)
local preferences = renoise.Document.create("BreakFastPreferences") {
    -- Use a simple string-based storage approach to avoid nested table issues
    global_symbol_registry_data = "",
    custom_labels_data = "",      -- User-defined custom labels (JSON array)
    show_label2 = false,          -- Toggle state for Label 2 column visibility
    symbol_dictionaries_data = "" -- Phase 4: Dictionary persistence
}

renoise.tool().preferences = preferences

-- Preference accessor functions for labeler module
function get_custom_labels_data()
    if preferences.custom_labels_data and preferences.custom_labels_data.value ~= "" then
        return preferences.custom_labels_data.value
    end
    return ""
end

function save_custom_labels_data(data)
    preferences.custom_labels_data.value = data
end

function get_show_label2()
    if preferences.show_label2 then
        return preferences.show_label2.value
    end
    return false
end

function save_show_label2(value)
    if preferences.show_label2 then
        preferences.show_label2.value = value
    end
end

-- Initialization flag
local tool_initialized = false

-- Pagination state for symbol grid
local symbol_pagination = {
    current_page = 1,
    symbols_per_page = 12, -- 3x4 grid (3 rows, 4 columns)
    total_pages = 1
}

-- Phase 2: Audio preview state management
local preview_state = {
    active = false,
    instrument_index = nil,
    track_index = nil,
    notes = {},  -- List of {note_value, instrument_index} for active preview
    symbol = nil
}

-- Serialize a table to a string (simple implementation)
local function serialize_table(t, indent)
    indent = indent or 0
    local spacing = string.rep("  ", indent)
    local result = "{\n"
    
    for k, v in pairs(t) do
        local key_str = type(k) == "string" and string.format("[%q]", k) or "[" .. tostring(k) .. "]"
        result = result .. spacing .. "  " .. key_str .. " = "
        
        if type(v) == "table" then
            result = result .. serialize_table(v, indent + 1)
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

-- ============================================================================
-- Phase 4: Dictionary CRUD Functions
-- ============================================================================

-- Rebuild the symbol_to_dictionary_cache from dictionaries
local function rebuild_dictionary_cache()
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

-- Load dictionaries from preferences
local function load_dictionaries()
    if preferences.symbol_dictionaries_data and preferences.symbol_dictionaries_data.value ~= "" then
        local success, loaded_dictionaries = pcall(loadstring("return " .. preferences.symbol_dictionaries_data.value))
        if success and loaded_dictionaries then
            symbol_dictionaries = loaded_dictionaries
            rebuild_dictionary_cache()
            print("DEBUG: Loaded " .. table.count(symbol_dictionaries) .. " dictionaries")
        else
            print("DEBUG: Failed to load dictionaries, starting with empty")
            symbol_dictionaries = {}
        end
    else
        print("DEBUG: No saved dictionaries found")
        symbol_dictionaries = {}
    end
end

-- Save dictionaries to preferences
local function save_dictionaries()
    local serialized = serialize_table(symbol_dictionaries)
    preferences.symbol_dictionaries_data.value = serialized
    rebuild_dictionary_cache()
    print("DEBUG: Saved " .. table.count(symbol_dictionaries) .. " dictionaries")
end

-- Create a new dictionary
local function create_dictionary(name, color, description)
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
    
    save_dictionaries()
    print("DEBUG: Created dictionary '" .. name .. "'")
    return true
end

-- Rename a dictionary
local function rename_dictionary(old_name, new_name)
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
    
    save_dictionaries()
    print("DEBUG: Renamed dictionary '" .. old_name .. "' to '" .. new_name .. "'")
    return true
end

-- Set dictionary color
local function set_dictionary_color(dict_name, color)
    if not symbol_dictionaries[dict_name] then
        return false, "Dictionary '" .. dict_name .. "' not found"
    end
    
    symbol_dictionaries[dict_name].color = color or ""
    save_dictionaries()
    print("DEBUG: Set color '" .. (color or "") .. "' for dictionary '" .. dict_name .. "'")
    return true
end

-- Set dictionary description
local function set_dictionary_description(dict_name, description)
    if not symbol_dictionaries[dict_name] then
        return false, "Dictionary '" .. dict_name .. "' not found"
    end
    
    symbol_dictionaries[dict_name].description = description or ""
    save_dictionaries()
    return true
end

-- Delete a dictionary (symbols become ungrouped)
local function delete_dictionary(dict_name)
    if not symbol_dictionaries[dict_name] then
        return false, "Dictionary '" .. dict_name .. "' not found"
    end
    
    symbol_dictionaries[dict_name] = nil
    save_dictionaries()
    print("DEBUG: Deleted dictionary '" .. dict_name .. "'")
    return true
end

-- Add a symbol to a dictionary (removes from any existing dictionary first)
local function add_symbol_to_dictionary(symbol, dict_name)
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
    
    save_dictionaries()
    print("DEBUG: Added symbol '" .. symbol .. "' to dictionary '" .. dict_name .. "'")
    return true
end

-- Remove a symbol from its current dictionary
local function remove_symbol_from_current_dictionary(symbol)
    local current_dict = symbol_to_dictionary_cache[symbol]
    if not current_dict then
        return true -- Already not in any dictionary
    end
    
    local dict_data = symbol_dictionaries[current_dict]
    if dict_data and dict_data.symbols then
        for i, s in ipairs(dict_data.symbols) do
            if s == symbol then
                table.remove(dict_data.symbols, i)
                save_dictionaries()
                print("DEBUG: Removed symbol '" .. symbol .. "' from dictionary '" .. current_dict .. "'")
                return true
            end
        end
    end
    
    return true
end

-- Get the dictionary name for a symbol (nil if ungrouped)
local function get_dictionary_for_symbol(symbol)
    return symbol_to_dictionary_cache[symbol]
end

-- Get dictionary data by name
local function get_dictionary_data(dict_name)
    return symbol_dictionaries[dict_name]
end

-- Get all dictionary names (sorted alphabetically)
local function get_all_dictionaries()
    local names = {}
    for name, _ in pairs(symbol_dictionaries) do
        table.insert(names, name)
    end
    table.sort(names)
    return names
end

-- Get symbols ordered by dictionary (for dictionary view)
-- Returns: array of {symbol = string, dictionary = string or nil}
local function get_symbols_ordered_by_dictionary()
    local result = {}
    local used_symbols = {}
    
    -- First, add symbols from each dictionary in order
    local dict_names = get_all_dictionaries()
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
    local all_symbols = {"A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9"}
    for _, symbol in ipairs(all_symbols) do
        if not used_symbols[symbol] then
            table.insert(result, {symbol = symbol, dictionary = nil})
        end
    end
    
    return result
end

-- Toggle dictionary view mode
local function toggle_dictionary_view()
    dictionary_view_enabled = not dictionary_view_enabled
    print("DEBUG: Dictionary view " .. (dictionary_view_enabled and "enabled" or "disabled"))
    return dictionary_view_enabled
end

-- Get dictionary view state
local function is_dictionary_view_enabled()
    return dictionary_view_enabled
end

-- ============================================================================
-- Phase 4: Dictionary Management Dialog
-- ============================================================================

local dictionary_dialog = nil  -- Reference to dictionary management dialog

local function show_dictionary_management_dialog()
    local vb = renoise.ViewBuilder()
    
    -- Close existing dialog if open
    if dictionary_dialog and dictionary_dialog.visible then
        dictionary_dialog:close()
    end
    
    -- Build the dictionary list dynamically
    local function build_dictionary_list()
        local dict_names = get_all_dictionaries()
        local list_column = vb:column {
            id = "dictionary_list_container",
            spacing = 5,
            width = 400
        }
        
        if #dict_names == 0 then
            list_column:add_child(vb:text {
                text = "No dictionaries created yet.",
                style = "disabled"
            })
        else
            for _, dict_name in ipairs(dict_names) do
                local dict_data = get_dictionary_data(dict_name)
                local symbol_count = dict_data.symbols and #dict_data.symbols or 0
                local color_name = dict_data.color or ""
                
                -- Create row for this dictionary
                local dict_row = vb:row {
                    spacing = 5,
                    
                    -- Color indicator (using text with color name)
                    vb:text {
                        text = color_name ~= "" and "[" .. color_name:sub(1,1) .. "]" or "[ ]",
                        width = 30,
                        style = color_name ~= "" and "strong" or "disabled"
                    },
                    
                    -- Dictionary name
                    vb:text {
                        text = dict_name,
                        width = 120,
                        style = "strong"
                    },
                    
                    -- Symbol count
                    vb:text {
                        text = "(" .. symbol_count .. " symbols)",
                        width = 80,
                        style = "disabled"
                    },
                    
                    -- Color dropdown
                    vb:popup {
                        width = 70,
                        items = color_dropdown_items,
                        value = (function()
                            for i, c in ipairs(color_dropdown_items) do
                                if c == color_name then return i end
                            end
                            return 1
                        end)(),
                        notifier = function(new_index)
                            set_dictionary_color(dict_name, color_dropdown_items[new_index])
                            renoise.app():show_status("Color updated for '" .. dict_name .. "'")
                        end
                    },
                    
                    -- Rename button
                    vb:button {
                        text = "Rename",
                        width = 55,
                        notifier = function()
                            local new_name = renoise.app():prompt_for_string("Rename Dictionary", dict_name, "Enter new name:")
                            if new_name and new_name ~= "" and new_name ~= dict_name then
                                local success, err = rename_dictionary(dict_name, new_name)
                                if success then
                                    renoise.app():show_status("Renamed to '" .. new_name .. "'")
                                    -- Refresh dialog
                                    if dictionary_dialog then dictionary_dialog:close() end
                                    show_dictionary_management_dialog()
                                else
                                    renoise.app():show_error(err or "Failed to rename dictionary")
                                end
                            end
                        end
                    },
                    
                    -- Delete button
                    vb:button {
                        text = "X",
                        width = 25,
                        notifier = function()
                            local confirm = renoise.app():show_prompt(
                                "Delete Dictionary",
                                "Delete '" .. dict_name .. "'? Symbols will become ungrouped.",
                                {"Delete", "Cancel"}
                            )
                            if confirm == "Delete" then
                                delete_dictionary(dict_name)
                                renoise.app():show_status("Deleted '" .. dict_name .. "'")
                                -- Refresh dialog
                                if dictionary_dialog then dictionary_dialog:close() end
                                show_dictionary_management_dialog()
                            end
                        end
                    }
                }
                
                list_column:add_child(dict_row)
            end
        end
        
        return list_column
    end
    
    -- Main dialog content
    local dialog_content = vb:column {
        margin = 10,
        spacing = 10,
        
        -- Header
        vb:text {
            text = "Dictionary Management",
            font = "big",
            style = "strong"
        },
        
        vb:text {
            text = "Organize symbols into named groups with optional colors.",
            style = "disabled"
        },
        
        -- Separator
        vb:space { height = 5 },
        
        -- Create new dictionary section
        vb:row {
            spacing = 5,
            
            vb:text {
                text = "New:",
                width = 35
            },
            
            vb:textfield {
                id = "new_dict_name",
                width = 150,
                text = ""
            },
            
            vb:popup {
                id = "new_dict_color",
                width = 70,
                items = color_dropdown_items,
                value = 1
            },
            
            vb:button {
                text = "Create",
                width = 60,
                notifier = function()
                    local name = vb.views.new_dict_name.text
                    local color_index = vb.views.new_dict_color.value
                    local color = color_dropdown_items[color_index]
                    
                    if name and name ~= "" then
                        local success, err = create_dictionary(name, color, "")
                        if success then
                            renoise.app():show_status("Created dictionary '" .. name .. "'")
                            -- Refresh dialog
                            if dictionary_dialog then dictionary_dialog:close() end
                            show_dictionary_management_dialog()
                        else
                            renoise.app():show_error(err or "Failed to create dictionary")
                        end
                    else
                        renoise.app():show_error("Please enter a dictionary name")
                    end
                end
            }
        },
        
        -- Separator
        vb:space { height = 5 },
        vb:text {
            text = "Existing Dictionaries:",
            style = "strong"
        },
        
        -- Dictionary list
        build_dictionary_list(),
        
        -- Separator
        vb:space { height = 10 },
        
        -- Close button
        vb:row {
            vb:button {
                text = "Close",
                width = 80,
                notifier = function()
                    if dictionary_dialog then
                        dictionary_dialog:close()
                    end
                end
            }
        }
    }
    
    dictionary_dialog = renoise.app():show_custom_dialog("Dictionaries", dialog_content)
end

-- Input lock visual update callback
local function update_input_lock_visual(is_active)
    input_lock_active = is_active
    
    -- Update dialog if it exists and has the input lock indicator
    if current_dialog_vb and current_dialog_vb.views.input_lock_status then
        if is_active then
            current_dialog_vb.views.input_lock_status.text = "INPUT LOCK ACTIVE"
            current_dialog_vb.views.input_lock_status.style = "strong"
        else
            current_dialog_vb.views.input_lock_status.text = "Input Lock"
            current_dialog_vb.views.input_lock_status.style = "normal"
        end
    end
    
    if current_dialog_vb and current_dialog_vb.views.input_lock_description then
        if is_active then
            current_dialog_vb.views.input_lock_description.text = "Type symbol keys (A-T, 0-9) or ESC to exit"
            current_dialog_vb.views.input_lock_description.style = "italic"
        else
            current_dialog_vb.views.input_lock_description.text = "Double-press Ctrl to activate"
            current_dialog_vb.views.input_lock_description.style = "italic"
        end
    end
    
    -- Update compact input lock indicator if it exists
    if current_dialog_vb and current_dialog_vb.views.compact_input_lock_indicator then
        if is_active then
            current_dialog_vb.views.compact_input_lock_indicator.text = "[-]"
            current_dialog_vb.views.compact_input_lock_indicator.style = "strong"
        else
            current_dialog_vb.views.compact_input_lock_indicator.text = "[O]"
            current_dialog_vb.views.compact_input_lock_indicator.style = "normal"
        end
    end
end

-- Input lock visual update callback
local function update_input_lock_visual(is_active)
    input_lock_active = is_active
    
    -- Update dialog if it exists and has the input lock indicator
    if current_dialog_vb and current_dialog_vb.views.input_lock_status then
        if is_active then
            current_dialog_vb.views.input_lock_status.text = "INPUT LOCK ACTIVE"
            current_dialog_vb.views.input_lock_status.style = "strong"
        else
            current_dialog_vb.views.input_lock_status.text = "Input Lock"
            current_dialog_vb.views.input_lock_status.style = "normal"
        end
    end
    
    if current_dialog_vb and current_dialog_vb.views.input_lock_description then
        if is_active then
            current_dialog_vb.views.input_lock_description.text = "Type symbol keys (A-T, 0-9) or ESC to exit"
            current_dialog_vb.views.input_lock_description.style = "disabled"
        else
            current_dialog_vb.views.input_lock_description.text = "Double-press Ctrl to activate"
            current_dialog_vb.views.input_lock_description.style = "disabled"
        end
    end
    
    -- Update compact input lock indicator if it exists
    if current_dialog_vb and current_dialog_vb.views.compact_input_lock_indicator then
        if is_active then
            current_dialog_vb.views.compact_input_lock_indicator.text = "[-]"
            current_dialog_vb.views.compact_input_lock_indicator.style = "strong"
        else
            current_dialog_vb.views.compact_input_lock_indicator.text = "[O]"
            current_dialog_vb.views.compact_input_lock_indicator.style = "normal"
        end
    end
end

-- Symbol button feedback callback
local function update_symbol_feedback(symbol, is_highlighted)
    if not current_dialog_vb or not symbol_button_refs[symbol] then
        return
    end
    
    local button = symbol_button_refs[symbol]
    if is_highlighted then
        -- Highlight the button (make it appear pressed/active)
        local symbol_color = get_symbol_color(symbol)
        if symbol_color and symbol_color ~= "" and color_definitions[symbol_color] then
            -- Use original (brighter) color when pressed
            button.color = color_definitions[symbol_color].original
        else
            -- Yellow highlight for symbols without custom colors
            button.color = {0xFF, 0xFF, 0x00}
        end
    else
        -- Return to normal appearance
        local symbol_color = get_symbol_color(symbol)
        if symbol_color and symbol_color ~= "" and color_definitions[symbol_color] then
            -- Use darker color for normal state
            button.color = color_definitions[symbol_color].darker
        else
            -- Default theme color for symbols without custom colors
            button.color = {0x00, 0x00, 0x00}
        end
    end
    
    print("DEBUG: Symbol button " .. symbol .. " feedback: " .. (is_highlighted and "highlighted" or "normal"))
end


-- Global symbol registry management functions
function get_global_symbol_registry()
    return global_symbol_registry
end

function set_global_symbol_registry(registry)
    global_symbol_registry = registry or {}
end

function find_next_available_symbols(num_symbols_needed)
    local used_symbols = {}
    for symbol, data in pairs(global_symbol_registry) do
        used_symbols[symbol] = true
    end
    
    local available = {}
    for _, symbol in ipairs(available_symbols) do
        if not used_symbols[symbol] and #available < num_symbols_needed then
            table.insert(available, symbol)
        end
    end
    
    return available
end

function assign_symbols_to_instrument(instrument_index, break_sets, saved_labels)
    local num_symbols_needed = #break_sets
    local available = find_next_available_symbols(num_symbols_needed)
    
    if #available < num_symbols_needed then
        return nil, string.format("Not enough available symbols. Need %d, only %d available.", 
            num_symbols_needed, #available)
    end
    
    -- Assign symbols to this instrument
    for i = 1, num_symbols_needed do
        local symbol = available[i]
        global_symbol_registry[symbol] = {
            instrument_index = instrument_index,
            break_set = break_sets[i],
            saved_labels = saved_labels,
            tags = {},      -- Initialize empty tags array
            color = ""      -- Initialize empty color
        }
    end
    
    return available
end

function assign_symbols_to_instrument(instrument_index, break_sets, saved_labels)
    local num_symbols_needed = #break_sets
    local available = find_next_available_symbols(num_symbols_needed)
    
    if #available < num_symbols_needed then
        return nil, string.format("Not enough available symbols. Need %d, only %d available.", 
            num_symbols_needed, #available)
    end
    
    -- Assign symbols to this instrument
    for i = 1, num_symbols_needed do
        local symbol = available[i]
        global_symbol_registry[symbol] = {
            instrument_index = instrument_index,
            break_set = break_sets[i],
            saved_labels = saved_labels,
            tags = {},      -- Initialize empty tags array
            color = ""      -- Initialize empty color
        }
    end
    
    return available
end

-- Get available symbols for moving (excluding the current symbol)
function get_available_symbols_for_moving(current_symbol)
    local available = {"Select target..."}  -- Default option
    local all_symbols = {"A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9"}
    
    for _, symbol in ipairs(all_symbols) do
        -- Only include symbols that are not currently in use and not the current symbol
        if symbol ~= current_symbol and not global_symbol_registry[symbol] then
            table.insert(available, symbol)
        end
    end
    
    return available
end

-- Move symbol to a new position
function move_symbol_to_position(from_symbol, to_symbol, vb)
    if not global_symbol_registry[from_symbol] then
        renoise.app():show_warning("Source symbol " .. from_symbol .. " not found in registry")
        return false
    end
    
    if global_symbol_registry[to_symbol] then
        renoise.app():show_warning("Target symbol " .. to_symbol .. " is already in use")
        return false
    end
    
    if from_symbol == to_symbol then
        renoise.app():show_warning("Cannot move symbol to itself")
        return false
    end
    
    print("DEBUG: Moving symbol from " .. from_symbol .. " to " .. to_symbol)
    
    -- Deep copy symbol data to new position
    global_symbol_registry[to_symbol] = {}
    for key, value in pairs(global_symbol_registry[from_symbol]) do
        if type(value) == "table" then
            global_symbol_registry[to_symbol][key] = {}
            for k, v in pairs(value) do
                if type(v) == "table" then
                    global_symbol_registry[to_symbol][key][k] = {}
                    for k2, v2 in pairs(v) do
                        global_symbol_registry[to_symbol][key][k][k2] = v2
                    end
                else
                    global_symbol_registry[to_symbol][key][k] = v
                end
            end
        else
            global_symbol_registry[to_symbol][key] = value
        end
    end
    
    -- Copy editing states to new position
    if tag_editing_states[from_symbol] then
        tag_editing_states[to_symbol] = {}
        for k, v in pairs(tag_editing_states[from_symbol]) do
            tag_editing_states[to_symbol][k] = v
        end
    end
    if color_editing_states[from_symbol] then
        color_editing_states[to_symbol] = color_editing_states[from_symbol]
    end
    
    -- Remove from old position
    global_symbol_registry[from_symbol] = nil
    
    -- Clear symbol button reference for old position
    if symbol_button_refs[from_symbol] then
        symbol_button_refs[from_symbol] = nil
    end
    
    -- Clear editing states for old position
    if tag_editing_states[from_symbol] then
        tag_editing_states[from_symbol] = nil
    end
    if color_editing_states[from_symbol] then
        color_editing_states[from_symbol] = nil
    end
    
    -- Save to preferences
    save_global_symbol_registry()
    
    renoise.app():show_status("Symbol " .. from_symbol .. " moved to " .. to_symbol)
    print("DEBUG: Symbol move completed successfully")
    
    return true
end

function get_symbol_instrument_mapping(symbol)
    local registry_entry = global_symbol_registry[symbol]
    return registry_entry and registry_entry.instrument_index or nil
end

-- Tag system functions
function toggle_tag_view(vb)
    -- Preserve any unsaved tag inputs before toggling
    if current_dialog_vb then
        preserve_unsaved_tag_inputs(nil, current_dialog_vb)
    end
    
    category_view_enabled = not category_view_enabled  -- Keep same variable name for UI compatibility
    
    -- Update toggle button text
    if vb.views.category_toggle then
        vb.views.category_toggle.text = category_view_enabled and "Tag*" or "Tag"
    end
    
    -- Always refresh dialog to rebuild with new width
    if dialog and dialog.visible then
        dialog:close()
        show_main_dialog()
    end
    
    print("DEBUG: Tag view toggled to " .. (category_view_enabled and "enabled" or "disabled"))
end

function toggle_organize_view(vb)
    organize_view_enabled = not organize_view_enabled
    
    -- Update toggle button text
    if vb.views.organize_toggle then
        vb.views.organize_toggle.text = organize_view_enabled and "Org*" or "Org"
    end
    
    -- Always refresh dialog to rebuild with new width
    if dialog and dialog.visible then
        dialog:close()
        show_main_dialog()
    end
    
    print("DEBUG: Organize view toggled to " .. (organize_view_enabled and "enabled" or "disabled"))
end

-- Format detailed information about a symbol for display
function format_detailed_symbol_info(symbol)
    local info_lines = {}
    
    -- Box drawing characters (using string.char for proper UTF-8)
    local BOX_TL = string.char(0xE2, 0x95, 0x94)  -- ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â
    local BOX_TR = string.char(0xE2, 0x95, 0x97)  -- ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Â
    local BOX_H = string.char(0xE2, 0x95, 0x90)   -- ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â¢Ãƒâ€šÃ‚Â
    local BOX_V = string.char(0xE2, 0x94, 0x82)   -- ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡
    local BOX_LT = string.char(0xE2, 0x94, 0x9C)  -- ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒâ€¦Ã¢â‚¬Å“
    local BOX_RT = string.char(0xE2, 0x94, 0xA4)  -- ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒâ€šÃ‚Â¤
    local BOX_HL = string.char(0xE2, 0x94, 0x80)  -- ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬
    
    -- Check if symbol exists in global registry
    local symbol_data = global_symbol_registry[symbol]
    if not symbol_data then
        table.insert(info_lines, "Symbol not assigned")
        return info_lines
    end
    
    -- Get break set data
    local break_set = symbol_data.break_set
    if not break_set or not break_set.timing then
        table.insert(info_lines, "No timing data")
        return info_lines
    end
    
    local note_count = #break_set.timing
    
    -- === HEADER ===
    local header = BOX_TL .. BOX_H .. BOX_H .. " Symbol " .. symbol .. " " .. string.rep(BOX_H, 27) .. BOX_TR
    table.insert(info_lines, header)
    
    -- === TYPE & SOURCE ===
    local symbol_type = symbol_data.symbol_type or "breakpoint"
    table.insert(info_lines, BOX_V .. " Type: " .. symbol_type)
    
    -- Source info (for range_captured symbols)
    if symbol_data.source_metadata then
        local src = symbol_data.source_metadata
        local pattern_idx = src.pattern_index or "??"
        local track_idx = src.track_index or "??"
        if type(pattern_idx) == "number" then
            pattern_idx = string.format("%02d", pattern_idx)
        end
        if type(track_idx) == "number" then
            track_idx = string.format("%02d", track_idx)
        end
        table.insert(info_lines, BOX_V .. " Source: Pattern " .. pattern_idx .. ", Track " .. track_idx)
        
        -- Phase 5: Show multi-track info if this is a multi-track symbol
        local is_multi_track = src.is_multi_track or (break_set and break_set.is_multi_track)
        local track_count = src.track_count or (break_set and break_set.track_count) or 1
        
        if is_multi_track and track_count > 1 then
            local track_names = src.track_names or break_set.track_names or {}
            local track_info = string.format(" Tracks: %d", track_count)
            if #track_names > 0 then
                -- Show first few track names
                local names_preview = {}
                for i = 1, math.min(3, #track_names) do
                    table.insert(names_preview, track_names[i]:sub(1, 8))
                end
                if #track_names > 3 then
                    table.insert(names_preview, "...")
                end
                track_info = track_info .. " (" .. table.concat(names_preview, ", ") .. ")"
            end
            table.insert(info_lines, BOX_V .. track_info)
        end
        
        -- Capture timestamp
        if src.capture_info and src.capture_info.capture_timestamp then
            table.insert(info_lines, BOX_V .. " Captured: " .. src.capture_info.capture_timestamp)
        end
    end
    
    -- Instrument info
    local instrument_index = symbol_data.instrument_index
    if instrument_index then
        local song = renoise.song()
        if song and song.instruments[instrument_index] then
            local inst_name = song.instruments[instrument_index].name
            if inst_name and inst_name ~= "" then
                table.insert(info_lines, BOX_V .. string.format(" Inst: %02X %s", instrument_index - 1, inst_name:sub(1, 14)))
            else
                table.insert(info_lines, BOX_V .. string.format(" Inst: %02X", instrument_index - 1))
            end
        end
    end
    
    -- === STATISTICS ===
    -- Calculate timing span and stats
    local min_line, max_line = 1, 1
    local total_delay = 0
    local total_distance = 0
    local unique_instruments = {}
    local unique_notes = {}
    local unique_tracks = {}  -- Phase 5: Track unique tracks
    
    if note_count > 0 then
        min_line = break_set.timing[1].relative_line or 1
        max_line = min_line
        
        for _, timing in ipairs(break_set.timing) do
            local line = timing.relative_line or 1
            if line < min_line then min_line = line end
            if line > max_line then max_line = line end
            total_delay = total_delay + (timing.new_delay or 0)
            total_distance = total_distance + (timing.original_distance or 0)
            
            -- Track unique instruments
            local inst_val = timing.source_instrument_index or timing.instrument_value
            if inst_val then
                unique_instruments[inst_val] = true
            end
            
            -- Track unique notes
            local note_val = timing.note_value or (36 + (timing.instrument_value or 0))
            if note_val then
                unique_notes[note_val] = true
            end
            
            -- Phase 5: Track unique track offsets
            local track_offset = timing.track_offset or 0
            unique_tracks[track_offset] = true
        end
    end
    
    local span = max_line - min_line + 1
    table.insert(info_lines, BOX_V .. string.format(" Total Lines: %d | Notes: %d", span, note_count))
    
    -- === NOTES SECTION ===
    local separator = BOX_LT .. string.rep(BOX_HL, 39) .. BOX_RT
    table.insert(info_lines, separator)
    table.insert(info_lines, BOX_V .. " NOTES:")
    
    -- Get labels for this instrument
    local saved_labels = symbol_data.saved_labels or {}
    if instrument_index then
        local inst_labels = labeler.get_labels_for_instrument(instrument_index)
        if inst_labels then
            for k, v in pairs(inst_labels) do
                saved_labels[k] = v
            end
        end
    end
    
    -- Note name lookup
    local note_names = {"C-", "C#", "D-", "D#", "E-", "F-", "F#", "G-", "G#", "A-", "A#", "B-"}
    
    -- List individual notes (limit to first 6 for space)
    local max_notes_to_show = 6
    -- Phase 5: Check if this is a multi-track symbol for display purposes
    local is_multi_track_symbol = break_set.is_multi_track or 
                                   (symbol_data.source_metadata and symbol_data.source_metadata.is_multi_track) or
                                   (break_set.track_count and break_set.track_count > 1)
    
    for i, timing in ipairs(break_set.timing) do
        if i > max_notes_to_show then
            table.insert(info_lines, BOX_V .. string.format("   ... +%d more", note_count - max_notes_to_show))
            break
        end
        
        local line = timing.relative_line or 1
        local delay = timing.new_delay or 0
        local note_val = timing.note_value or (36 + (timing.instrument_value or 0))
        local inst_val = timing.source_instrument_index or timing.instrument_value or 0
        local vol = timing.volume_value
        local pan = timing.panning_value
        local dist = timing.original_distance or 0
        local track_offset = timing.track_offset or 0  -- Phase 5
        
        -- Convert note value to note name
        local octave = math.floor(note_val / 12)
        local note_index = (note_val % 12) + 1
        local note_name = note_names[note_index] .. octave
        
        -- Format: L01 C-4 I11 V-- P-- d00 Dist:2048 [+T0]
        local vol_str = (vol and vol ~= 255 and vol ~= 0xFF) and string.format("%02X", vol) or "--"
        local pan_str = (pan and pan ~= 255 and pan ~= 0xFF) and string.format("%02X", pan) or "--"
        local inst_str = string.format("%02X", inst_val)
        
        -- Phase 5: Include track offset for multi-track symbols
        if is_multi_track_symbol then
            table.insert(info_lines, BOX_V .. string.format(" L%02d %s I%s V%s d%02X +T%d", 
                line, note_name, inst_str, vol_str, delay, track_offset))
        else
            table.insert(info_lines, BOX_V .. string.format(" L%02d %s I%s V%s P%s d%02X Dist:%d", 
                line, note_name, inst_str, vol_str, pan_str, delay, dist))
        end
    end
    
    -- === STATISTICS SECTION ===
    table.insert(info_lines, separator)
    table.insert(info_lines, BOX_V .. " STATISTICS:")
    
    -- Count unique instruments
    local inst_count = 0
    local inst_list = {}
    for inst_val, _ in pairs(unique_instruments) do
        inst_count = inst_count + 1
        table.insert(inst_list, string.format("I%02X", inst_val))
    end
    if inst_count > 0 then
        local inst_str = table.concat(inst_list, ","):sub(1, 12)
        table.insert(info_lines, BOX_V .. string.format(" Instruments: %d (%s)", inst_count, inst_str))
    end
    
    -- Count unique notes
    local note_type_count = 0
    local note_list = {}
    for note_val, _ in pairs(unique_notes) do
        note_type_count = note_type_count + 1
        local octave = math.floor(note_val / 12)
        local note_index = (note_val % 12) + 1
        table.insert(note_list, note_names[note_index] .. octave)
    end
    if note_type_count > 0 then
        local note_str = table.concat(note_list, ","):sub(1, 10)
        table.insert(info_lines, BOX_V .. string.format(" Unique Notes: %d (%s)", note_type_count, note_str))
    end
    
    -- Average distance
    if note_count > 0 then
        local avg_distance = math.floor(total_distance / note_count)
        table.insert(info_lines, BOX_V .. string.format(" Avg Note Distance: %d ticks", avg_distance))
        
        -- Approximate duration in lines
        local duration_lines = math.floor(total_distance / 256)
        table.insert(info_lines, BOX_V .. string.format(" Duration: ~%d lines", duration_lines))
    end
    
    -- === LABELS SECTION ===
    local has_labels = false
    for _, _ in pairs(saved_labels) do
        has_labels = true
        break
    end
    
    if has_labels then
        table.insert(info_lines, separator)
        table.insert(info_lines, BOX_V .. " LABELS:")
        
        local label_count = 0
        for slice_key, label_data in pairs(saved_labels) do
            if label_count >= 4 then
                table.insert(info_lines, BOX_V .. "   ... more")
                break
            end
            
            local label_str = label_data.label or ""
            local label2_str = label_data.label2 or ""
            local bp_str = label_data.breakpoint and " (breakpoint)" or ""
            
            if label_str ~= "" and label_str ~= "---------" then
                local display = slice_key .. ": " .. label_str:sub(1, 12)
                if label2_str ~= "" and label2_str ~= "---------" then
                    display = display .. "/" .. label2_str:sub(1, 6)
                end
                display = display .. bp_str
                table.insert(info_lines, BOX_V .. " " .. display)
                label_count = label_count + 1
            end
        end
    end
    
    -- === TAGS & COLOR ===
    local current_tags = symbol_data.tags or {}
    local current_color = symbol_data.color or ""
    
    if #current_tags > 0 or current_color ~= "" then
        table.insert(info_lines, separator)
        
        if #current_tags > 0 then
            local non_empty_tags = {}
            for _, tag in ipairs(current_tags) do
                if tag and tag ~= "" then
                    table.insert(non_empty_tags, tag)
                end
            end
            if #non_empty_tags > 0 then
                table.insert(info_lines, BOX_V .. " TAGS: " .. table.concat(non_empty_tags, ", "):sub(1, 20))
            end
        end
        
        if current_color ~= "" then
            table.insert(info_lines, BOX_V .. " COLOR: " .. current_color)
        end
    end
    
    return info_lines
end

-- Toggle detailed view and handle symbol expansion
function toggle_detailed_view(vb)
    detailed_view_enabled = not detailed_view_enabled
    expanded_symbol = nil  -- Reset expanded symbol when toggling
    
    -- Update toggle button text
    if vb.views.detailed_toggle then
        vb.views.detailed_toggle.text = detailed_view_enabled and "Info*" or "Info"
    end
    
    -- Refresh dialog to rebuild with new view state
    if dialog and dialog.visible then
        dialog:close()
        show_main_dialog()
    end
    
    print("DEBUG: Detailed view toggled to " .. (detailed_view_enabled and "enabled" or "disabled"))
end

-- Phase 4: Toggle dictionary view and refresh dialog
function toggle_dictionary_view_ui(vb)
    dictionary_view_enabled = not dictionary_view_enabled
    
    -- Update toggle button text
    if vb.views.dictionary_toggle then
        vb.views.dictionary_toggle.text = dictionary_view_enabled and "Dict*" or "Dict"
    end
    
    -- Refresh dialog to rebuild with new view state (reorders symbols)
    if dialog and dialog.visible then
        dialog:close()
        show_main_dialog()
    end
    
    print("DEBUG: Dictionary view toggled to " .. (dictionary_view_enabled and "enabled" or "disabled"))
end

-- Expand a symbol to show detailed info (collapse others)
function expand_symbol_detail(symbol, vb)
    local was_expanded = (expanded_symbol == symbol)
    
    if was_expanded then
        -- Clicking same symbol collapses it
        expanded_symbol = nil
    else
        -- Expand this symbol, collapse others
        expanded_symbol = symbol
    end
    
    print("DEBUG: Expanded symbol: " .. (expanded_symbol or "none"))
    
    -- Preserve any unsaved tag inputs before refresh
    if current_dialog_vb then
        preserve_unsaved_tag_inputs(nil, current_dialog_vb)
    end
    
    -- Refresh dialog to properly resize - visibility changes don't reclaim space
    if dialog and dialog.visible then
        dialog:close()
        show_main_dialog()
    end
end

function delete_symbol(symbol, vb)
    -- Check if symbol exists in global registry
    if not global_symbol_registry[symbol] then
        renoise.app():show_warning("Symbol " .. symbol .. " not found in registry")
        return false
    end
    
    -- Show confirmation dialog
    local result = renoise.app():show_prompt("Delete Symbol", 
        "This will permanently delete symbol '" .. symbol .. "' and all its data.\n\nAre you sure you want to continue?", 
        {"Delete", "Cancel"})
    
    if result == "Delete" then
        -- Remove symbol from global registry
        global_symbol_registry[symbol] = nil
        
        -- Clear symbol button reference
        if symbol_button_refs[symbol] then
            symbol_button_refs[symbol] = nil
        end
        
        -- Clear tag editing state
        if tag_editing_states[symbol] then
            tag_editing_states[symbol] = nil
        end
        
        -- Clear color editing state
        if color_editing_states[symbol] then
            color_editing_states[symbol] = nil
        end
        
        -- Save to preferences
        save_global_symbol_registry()
        
        renoise.app():show_status("Symbol " .. symbol .. " deleted successfully")
        
        -- Refresh the dialog to update the UI
        if dialog and dialog.visible then
            -- Preserve all unsaved tag inputs before refresh
            if current_dialog_vb then
                preserve_unsaved_tag_inputs(nil, current_dialog_vb)
            end
            dialog:close()
            show_main_dialog()
        end
        
        return true
    end
    
    return false
end

function get_symbol_tags(symbol)
    local registry_entry = global_symbol_registry[symbol]
    if registry_entry then
        -- Handle backward compatibility: convert old category to tags array
        if registry_entry.category and not registry_entry.tags then
            registry_entry.tags = registry_entry.category ~= "" and {registry_entry.category} or {}
            registry_entry.category = nil  -- Remove old category field
        end
        return registry_entry.tags or {}
    end
    return {}
end

function get_tag_count(symbol)
    local tags = get_symbol_tags(symbol)
    return math.max(1, #tags)  -- Minimum of 1 tag input
end

function save_symbol_tag(symbol, tag_index, tag_text, vb)
    if not global_symbol_registry[symbol] then
        print("DEBUG: Cannot save tag for symbol " .. symbol .. " - symbol not in registry")
        return false
    end
    
    -- Initialize tags array if it doesn't exist
    if not global_symbol_registry[symbol].tags then
        global_symbol_registry[symbol].tags = {}
    end
    
    -- Save tag to registry
    if tag_text and tag_text ~= "" then
        global_symbol_registry[symbol].tags[tag_index] = tag_text
    else
        -- Remove empty tag
        table.remove(global_symbol_registry[symbol].tags, tag_index)
    end
    
    -- Update editing state - true means saved/locked, false means editing
    local has_tag = tag_text and tag_text ~= ""
    if not tag_editing_states[symbol] then
        tag_editing_states[symbol] = {}
    end
    tag_editing_states[symbol][tag_index] = has_tag
    
    -- Update UI to show saved state (locked)
    if vb then
        update_tag_ui_state(symbol, tag_index, has_tag, tag_text, vb)
    end
    
    -- Persist to preferences immediately
    save_global_symbol_registry()
    
    print("DEBUG: Saved tag " .. tag_index .. " '" .. (tag_text or "") .. "' for symbol " .. symbol)
    
    local status_msg = has_tag and 
        ("Tag saved for symbol " .. symbol .. ": " .. tag_text) or
        ("Tag cleared for symbol " .. symbol)
    renoise.app():show_status(status_msg)
    
    -- If category view is enabled, also update the display outside editing mode
    -- This ensures consistency between editing and display states
    print("DEBUG: Tag saved successfully for symbol " .. symbol .. ", registry updated")
    
    return true
end

function unlock_symbol_tag(symbol, tag_index, vb)
    -- Set editing state to false (unlocked for editing)
    if not tag_editing_states[symbol] then
        tag_editing_states[symbol] = {}
    end
    tag_editing_states[symbol][tag_index] = false
    
    -- Get current tag text
    local current_tags = get_symbol_tags(symbol)
    local current_tag = current_tags[tag_index] or ""
    
    -- Update UI to show editing state (unlocked)
    update_tag_ui_state(symbol, tag_index, false, current_tag, vb)
    
    print("DEBUG: Unlocked tag " .. tag_index .. " editing for symbol " .. symbol)
    renoise.app():show_status("Tag editing unlocked for symbol " .. symbol)
end

function add_tag_input(symbol, vb)
    local current_count = get_tag_count(symbol)
    if current_count >= 5 then
        renoise.app():show_warning("Maximum 5 tags allowed per symbol")
        return false
    end
    
    -- Preserve any unsaved tag inputs before refresh
    preserve_unsaved_tag_inputs(symbol, vb)
    
    local new_tag_index = current_count + 1
    
    -- Initialize tag editing state
    if not tag_editing_states[symbol] then
        tag_editing_states[symbol] = {}
    end
    tag_editing_states[symbol][new_tag_index] = false  -- Start in editing mode
    
    -- Add empty tag to registry
    if not global_symbol_registry[symbol].tags then
        global_symbol_registry[symbol].tags = {}
    end
    table.insert(global_symbol_registry[symbol].tags, "")
    
    -- Persist changes and refresh dialog
    save_global_symbol_registry()
    
    if dialog and dialog.visible then
        dialog:close()
        show_main_dialog()
    end
    
    return true
end

function remove_tag_input(symbol, tag_index, vb)
    local current_count = get_tag_count(symbol)
    if current_count <= 1 then
        renoise.app():show_warning("Minimum 1 tag input required")
        return false
    end
    
    -- Remove from registry
    if global_symbol_registry[symbol] and global_symbol_registry[symbol].tags then
        table.remove(global_symbol_registry[symbol].tags, tag_index)
    end
    
    -- Remove from editing states
    if tag_editing_states[symbol] and tag_editing_states[symbol][tag_index] then
        table.remove(tag_editing_states[symbol], tag_index)
    end
    
    -- Persist changes and refresh dialog
    save_global_symbol_registry()
    
    if dialog and dialog.visible then
        dialog:close()
        show_main_dialog()
    end
    
    return true
end

function update_tag_ui_state(symbol, tag_index, is_saved, tag_text, vb)
    local tag_field = vb.views["tag_field_" .. symbol .. "_" .. tag_index]
    local tag_text_display = vb.views["tag_text_" .. symbol .. "_" .. tag_index]
    local tag_save_button = vb.views["tag_save_" .. symbol .. "_" .. tag_index]
    
    if not tag_save_button then
        print("DEBUG: Could not find tag UI elements for symbol " .. symbol .. " tag " .. tag_index)
        return
    end
    
    if is_saved and tag_text and tag_text ~= "" then
        -- Saved state: hide textfield, show text display, update button
        if tag_field then
            tag_field.visible = false
        end
        if tag_text_display then
            tag_text_display.visible = true
            tag_text_display.text = tag_text
        end
        tag_save_button.text = "[*]"
        tag_save_button.tooltip = "Click to edit tag"
    else
        -- Editing state: show textfield, hide text display, update button
        if tag_field then
            tag_field.visible = true
            tag_field.text = tag_text or ""
        end
        if tag_text_display then
            tag_text_display.visible = false
        end
        tag_save_button.text = "[ ]"
        tag_save_button.tooltip = "Click to save tag"
    end
end

function update_tag_button_states(symbol, vb)
    local current_count = get_tag_count(symbol)
    
    local add_button = vb.views["tag_add_" .. symbol]
    local remove_button = vb.views["tag_remove_" .. symbol]
    
    if add_button then
        add_button.active = (current_count < 5)
    end
    
    if remove_button then
        remove_button.active = (current_count > 1)
    end
end

function preserve_unsaved_tag_inputs(symbol, vb)
    print("DEBUG: preserve_unsaved_tag_inputs called for " .. (symbol or "ALL symbols"))
    if symbol then
        -- Preserve specific symbol
        preserve_single_symbol_tag_inputs(symbol, vb)
    else
        -- Preserve all symbols
        for sym, _ in pairs(global_symbol_registry) do
            preserve_single_symbol_tag_inputs(sym, vb)
        end
    end
    -- Ensure changes are persisted immediately
    save_global_symbol_registry()
    print("DEBUG: preserve_unsaved_tag_inputs completed, registry saved")
end

function preserve_single_symbol_tag_inputs(symbol, vb)
    local current_tags = get_symbol_tags(symbol)
    local tag_count = get_tag_count(symbol)
    
    if not global_symbol_registry[symbol].tags then
        global_symbol_registry[symbol].tags = {}
    end
    
    local preserved_count = 0
    for i = 1, tag_count do
        local tag_field = vb.views["tag_field_" .. symbol .. "_" .. i]
        if tag_field and tag_field.visible then
            local current_text = tag_field.text or ""
            if current_text ~= "" then
                while #global_symbol_registry[symbol].tags < i do
                    table.insert(global_symbol_registry[symbol].tags, "")
                end
                global_symbol_registry[symbol].tags[i] = current_text
                if not tag_editing_states[symbol] then
                    tag_editing_states[symbol] = {}
                end
                tag_editing_states[symbol][i] = true  -- Mark as saved, not editing
                preserved_count = preserved_count + 1
                print("DEBUG: Preserved tag " .. i .. " for symbol " .. symbol .. ": '" .. current_text .. "'")
            end
        end
    end
    
    if preserved_count > 0 then
        print("DEBUG: Preserved " .. preserved_count .. " unsaved tag inputs for symbol " .. symbol)
    end
end

function clear_all_symbols()
    global_symbol_registry = {}
    tag_editing_states = {}
    color_editing_states = {}
    
    save_global_symbol_registry()
    
    if dialog and dialog.visible then
        dialog:close()
        show_main_dialog()
    end
    
    renoise.app():show_status("All symbols cleared")
end

function create_tag_input_row(symbol, tag_index, tag_text, is_saved, vb)
    return vb:row {
        id = "tag_row_" .. symbol .. "_" .. tag_index,
        spacing = 2,
        width = 122,  -- Fixed width to match symbol column
        
        -- Container for the input/display area to maintain consistent width
        vb:column {
            width = 98,
            height = 20,
            
            -- Textfield (for editing)
            vb:textfield {
                id = "tag_field_" .. symbol .. "_" .. tag_index,
                width = 98,
                height = 20,
                text = tag_text or "",
                visible = not (is_saved and tag_text and tag_text ~= "")
            },
            
            -- Text display (for saved state) - wrapped in aligner for consistent positioning
            vb:horizontal_aligner {
                mode = "left",
                width = 98,
                height = 20,
                vb:text {
                    id = "tag_text_" .. symbol .. "_" .. tag_index,
                    text = tag_text or "",
                    style = "strong",
                    tooltip = "Tag: " .. (tag_text or ""),
                    visible = (is_saved and tag_text and tag_text ~= "")
                }
            }
        },
        
        -- Save/Edit button
        vb:button {
            id = "tag_save_" .. symbol .. "_" .. tag_index,
            text = (is_saved and tag_text and tag_text ~= "") and "[*]" or "[ ]",
            width = 22,
            height = 20,
            tooltip = (is_saved and tag_text and tag_text ~= "") and "Click to edit tag" or "Click to save tag",
            notifier = function()
                local current_is_saved = tag_editing_states[symbol] and tag_editing_states[symbol][tag_index] or false
                local current_tag = ""
                
                if global_symbol_registry[symbol] and global_symbol_registry[symbol].tags then
                    current_tag = global_symbol_registry[symbol].tags[tag_index] or ""
                end
                
                if current_is_saved and current_tag and current_tag ~= "" then
                    -- Currently saved, so unlock for editing
                    unlock_symbol_tag(symbol, tag_index, vb)
                else
                    -- Currently editing, so save
                    local tag_field = vb.views["tag_field_" .. symbol .. "_" .. tag_index]
                    if tag_field then
                        save_symbol_tag(symbol, tag_index, tag_field.text, vb)
                    end
                end
            end
        }
    }
end

function create_tag_buttons_row(symbol, vb)
    return vb:row {
        id = "tag_buttons_row_" .. symbol,
        spacing = 5,
        vb:button {
            id = "tag_add_" .. symbol,
            text = "+",
            width = 20,
            height = 20,
            tooltip = "Add tag",
            notifier = function()
                add_tag_input(symbol, vb)
            end
        },
        vb:button {
            id = "tag_remove_" .. symbol,
            text = "-",
            width = 20,
            height = 20,
            tooltip = "Remove last tag",
            notifier = function()
                local current_count = get_tag_count(symbol)
                if current_count > 1 then
                    remove_tag_input(symbol, current_count, vb)
                end
            end
        }
    }
end

function rebuild_tag_container(symbol, vb)
    -- Instead of complex rebuilding, just refresh the entire dialog
    save_global_symbol_registry()
    
    if dialog and dialog.visible then
        dialog:close()
        show_main_dialog()
    end
    
    -- Get current tags
    local tags = get_symbol_tags(symbol)
    local tag_count = math.max(1, #tags)
    
    -- Rebuild tag input rows
    for i = 1, tag_count do
        local tag_text = tags[i] or ""
        local is_saved = tag_editing_states[symbol] and tag_editing_states[symbol][i] or false
        
        local tag_row = create_tag_input_row(symbol, i, tag_text, is_saved, vb)
        tag_container:add_child(tag_row)
    end
    
    -- Add +/- buttons row
    local buttons_row = create_tag_buttons_row(symbol, vb)
    tag_container:add_child(buttons_row)
    
    -- Update button states
    update_tag_button_states(symbol, vb)
end

-- Color system functions (mirror category system)
function get_symbol_color(symbol)
    local registry_entry = global_symbol_registry[symbol]
    return registry_entry and registry_entry.color or ""
end

function save_symbol_color(symbol, color_name, vb)
    if not global_symbol_registry[symbol] then
        print("DEBUG: Cannot save color for symbol " .. symbol .. " - symbol not in registry")
        return false
    end
    
    -- Save color to registry
    global_symbol_registry[symbol].color = color_name or ""
    
    -- Update editing state - true means saved/locked, false means editing
    local has_color = color_name and color_name ~= ""
    color_editing_states[symbol] = has_color
    
    -- Update UI to show saved state (locked)
    if vb then
        update_color_ui_state(symbol, has_color, color_name, vb)
    end
    
    -- Apply color to symbol button
    if vb then
        apply_symbol_button_color(symbol, color_name, vb)
    end
    
    -- Persist to preferences
    save_global_symbol_registry()
    
    print("DEBUG: Saved color '" .. (color_name or "") .. "' for symbol " .. symbol)
    
    local status_msg = has_color and 
        ("Color saved for symbol " .. symbol .. ": " .. color_name) or
        ("Color cleared for symbol " .. symbol)
    renoise.app():show_status(status_msg)
    
    -- Preserve unsaved tag inputs before refresh
    preserve_unsaved_tag_inputs(symbol, vb)
    
    -- Refresh the dialog to show color changes
    if dialog and dialog.visible then
        dialog:close()
        show_main_dialog()
    end
    
    return true
end

function unlock_symbol_color(symbol, vb)
    -- Set editing state to false (unlocked for editing)
    color_editing_states[symbol] = false
    
    -- Get current color
    local current_color = get_symbol_color(symbol)
    
    -- Update UI to show editing state (unlocked)
    update_color_ui_state(symbol, false, current_color, vb)
    
    print("DEBUG: Unlocked color editing for symbol " .. symbol)
    renoise.app():show_status("Color editing unlocked for symbol " .. symbol)
end

function update_color_ui_state(symbol, is_saved, color_name, vb)
    local color_popup = vb.views["color_popup_" .. symbol]
    local color_text_display = vb.views["color_text_" .. symbol]
    local color_save_button = vb.views["color_save_" .. symbol]
    
    if not color_save_button then
        print("DEBUG: Could not find color UI elements for symbol " .. symbol)
        return
    end
    
    if is_saved and color_name and color_name ~= "" then
        -- Saved state: hide popup, show text display, update button
        if color_popup then
            color_popup.visible = false
        end
        if color_text_display then
            color_text_display.visible = true
            color_text_display.text = color_name
            -- Note: Text views don't support color property in Renoise
            -- Color indication is handled by the symbol buttons themselves
        end
        color_save_button.text = "[*]"
        color_save_button.tooltip = "Click to edit color"
    else
        -- Editing state: show popup, hide text display, update button
        if color_popup then
            color_popup.visible = true
            -- Set popup value to current color
            local color_index = table.find(color_dropdown_items, color_name or "")
            if color_index then
                color_popup.value = color_index
            else
                color_popup.value = 1 -- Default to no color
            end
        end
        if color_text_display then
            color_text_display.visible = false
        end
        color_save_button.text = "[ ]"
        color_save_button.tooltip = "Click to save color"
    end
end

function apply_symbol_button_color(symbol, color_name, vb)
    local symbol_button = symbol_button_refs[symbol]
    if not symbol_button then
        print("DEBUG: No button reference found for symbol " .. symbol)
        print("DEBUG: Available button refs:", table.concat((function()
            local keys = {}
            for k, _ in pairs(symbol_button_refs) do
                table.insert(keys, k)
            end
            return keys
        end)(), ", "))
        return
    end
    
    print("DEBUG: Found button reference for symbol " .. symbol)
    
    if color_name and color_name ~= "" and color_definitions[color_name] then
        local color_def = color_definitions[color_name]
        if color_def.darker then
            -- Apply darker color as background
            symbol_button.color = color_def.darker
            print("DEBUG: Applied color " .. color_name .. " RGB(" .. color_def.darker[1] .. "," .. color_def.darker[2] .. "," .. color_def.darker[3] .. ") to symbol " .. symbol)
        end
    else
        -- Remove color (return to default theme colors)
        symbol_button.color = {0, 0, 0}
        print("DEBUG: Removed color from symbol " .. symbol)
    end
end

function initialize_color_editing_states()
    -- Initialize editing states based on existing colors
    -- true = saved/locked, false = editing/unlocked
    color_editing_states = {}
    for symbol, symbol_data in pairs(global_symbol_registry) do
        local has_color = symbol_data.color and symbol_data.color ~= ""
        color_editing_states[symbol] = has_color  -- saved colors start in locked state
    end
    print("DEBUG: Initialized color editing states for " .. table.count(color_editing_states) .. " symbols")
end

function update_category_ui_state(symbol, is_saved, category_text, vb)
    -- Instead of trying to modify existing views, we'll update the visibility and content
    -- of existing views that we know exist
    
    local category_field = vb.views["category_field_" .. symbol]
    local category_text_display = vb.views["category_text_" .. symbol]
    local category_save_button = vb.views["category_save_" .. symbol]
    
    if not category_save_button then
        print("DEBUG: Could not find category UI elements for symbol " .. symbol)
        return
    end
    
    if is_saved and category_text and category_text ~= "" then
        -- Saved state: hide textfield, show text display, update button
        if category_field then
            category_field.visible = false
        end
        if category_text_display then
            category_text_display.visible = true
            category_text_display.text = category_text
        end
        category_save_button.text = "[*]"
        category_save_button.tooltip = "Click to edit category"
    else
        -- Editing state: show textfield, hide text display, update button
        if category_field then
            category_field.visible = true
            category_field.text = category_text or ""
        end
        if category_text_display then
            category_text_display.visible = false
        end
        category_save_button.text = "[ ]"
        category_save_button.tooltip = "Click to save category"
    end
end

function initialize_tag_editing_states()
    -- Initialize editing states based on existing tags
    -- true = saved/locked, false = editing/unlocked
    tag_editing_states = {}
    for symbol, symbol_data in pairs(global_symbol_registry) do
        -- Handle backward compatibility: convert old category to tags
        if symbol_data.category and not symbol_data.tags then
            symbol_data.tags = symbol_data.category ~= "" and {symbol_data.category} or {}
            symbol_data.category = nil  -- Remove old category field
        end
        
        local tags = symbol_data.tags or {}
        tag_editing_states[symbol] = {}
        
        -- Initialize editing state for each tag
        for i, tag in ipairs(tags) do
            local has_tag = tag and tag ~= ""
            tag_editing_states[symbol][i] = has_tag  -- saved tags start in locked state
        end
        
        -- Ensure at least one tag input state exists
        if #tags == 0 then
            tag_editing_states[symbol][1] = false  -- empty tag in editing state
        end
    end
    print("DEBUG: Initialized tag editing states for " .. table.count(tag_editing_states) .. " symbols")
    
    -- Also initialize color editing states
    initialize_color_editing_states()
end

-- Capture current selection as symbol
function capture_selection_as_symbol()
    print("DEBUG: Capturing selection as symbol")
    
    -- Preserve all unsaved tag inputs before refresh
    if dialog and dialog.visible and current_dialog_vb then
        preserve_unsaved_tag_inputs(nil, current_dialog_vb)
    end
    
    local success, new_symbol = selection.capture_selection_as_symbol()
    if success then
        -- Update current formatted labels to reflect the new symbol
        current_formatted_labels = syntax.prepare_global_symbol_labels(global_symbol_registry)
        
        -- Refresh the main dialog if it's open to show the new symbol
        if dialog and dialog.visible then
            dialog:close()
            show_main_dialog()
        end
        
        return true, new_symbol
    end
    
    return false
end

-- Capture selection with labels - allows user to label notes before capturing
function capture_selection_with_labels()
    print("DEBUG: Capturing selection with labels")
    
    -- Validate selection first
    local success, selection_data = selection.validate_selection()
    if not success then
        renoise.app():show_warning(selection_data)
        return false
    end
    
    -- Extract notes from selection
    local notes, sel_data = selection.extract_notes_from_selection()
    if not notes then
        renoise.app():show_warning(sel_data or "Failed to extract notes from selection")
        return false
    end
    
    -- Collect unique (instrument_index, note_value) pairs
    local unique_notes = {}
    local unique_notes_list = {}
    
    for _, note in ipairs(notes) do
        if note.has_note and note.note_value ~= renoise.PatternLine.EMPTY_NOTE then
            local key = string.format("%03d_%03d", note.instrument_value, note.note_value)
            if not unique_notes[key] then
                unique_notes[key] = true
                table.insert(unique_notes_list, {
                    instrument_index = note.instrument_value + 1,  -- Convert to 1-based
                    note_value = note.note_value,
                    display_instrument = string.format("%02X", note.instrument_value),
                    display_note = selection.note_value_to_string(note.note_value)
                })
            end
        end
    end
    
    if #unique_notes_list == 0 then
        renoise.app():show_warning("No notes found in selection")
        return false
    end
    
    -- Sort by instrument, then note value
    table.sort(unique_notes_list, function(a, b)
        if a.instrument_index ~= b.instrument_index then
            return a.instrument_index < b.instrument_index
        end
        return a.note_value < b.note_value
    end)
    
    -- Look up existing labels for each note
    for _, note_info in ipairs(unique_notes_list) do
        local saved_labels = labeler.get_labels_for_instrument(note_info.instrument_index)
        
        -- Calculate the slice-based key (what labeler uses for sliced samples)
        -- Slice 1 = note 37, key "01"; Slice 2 = note 38, key "02"
        local slice_key = nil
        if note_info.note_value >= 37 then
            slice_key = string.format("%02X", note_info.note_value - 36)
        end
        
        -- Also try note-based key (for keyzone mappings)
        local note_key = string.format("%02X", note_info.note_value)
        
        -- Try slice key first (most common), then note key
        local label_data = (slice_key and saved_labels[slice_key]) or saved_labels[note_key] or nil
        
        note_info.label = (label_data and label_data.label) or "---------"
        note_info.label2 = (label_data and label_data.label2) or "---------"
        note_info.has_existing_label = (label_data ~= nil)
        
        -- Store the key format that was found (for saving back)
        note_info.storage_key = (slice_key and saved_labels[slice_key]) and slice_key or note_key
    end
    
    -- Show dialog for labeling
    show_capture_with_labels_dialog(unique_notes_list, notes, sel_data)
end

-- Dialog for capturing selection with labels
function show_capture_with_labels_dialog(unique_notes_list, notes, sel_data)
    local capture_vb = renoise.ViewBuilder()
    local capture_dialog = nil
    
    -- Get label options from labeler
    local label_options = labeler.get_all_labels()
    local show_label2 = get_show_label2()
    
    local column_width = 100
    local narrow_column = 50
    local spacing = 5
    local preview_column_width = 22  -- Phase 6: Preview column
    
    -- Build the dialog content
    local dialog_content = capture_vb:column {
        margin = 10,
        spacing = spacing,
        
        capture_vb:text {
            text = "Capture Selection with Labels",
            font = "bold",
            style = "strong"
        },
        
        capture_vb:text {
            text = string.format("Found %d unique notes across selection", #unique_notes_list),
            style = "disabled"
        },
        
        capture_vb:space { height = 5 },
        
        -- Header row (Phase 6: Added preview column)
        capture_vb:row {
            spacing = spacing,
            capture_vb:text { text = "", width = preview_column_width, align = "center" },  -- Preview column header
            capture_vb:text { text = "Inst", width = narrow_column, font = "bold", align = "center" },
            capture_vb:text { text = "Note", width = narrow_column, font = "bold", align = "center" },
            capture_vb:text { text = "Label", width = column_width, font = "bold", align = "center" },
            show_label2 and capture_vb:text { text = "Label 2", width = column_width, font = "bold", align = "center" } or capture_vb:space { width = 1 },
            capture_vb:text { text = "Status", width = 80, font = "bold", align = "center" }
        }
    }
    
    -- Add rows for each unique note
    for i, note_info in ipairs(unique_notes_list) do
        local status_text = note_info.has_existing_label and "(auto-filled)" or "(no label)"
        local status_style = note_info.has_existing_label and "normal" or "disabled"
        
        -- Phase 6: Create preview button ID
        local preview_button_id = "capture_preview_" .. i
        
        local row = capture_vb:row {
            spacing = spacing,
            
            -- Phase 6: Preview button
            capture_vb:button {
                id = preview_button_id,
                text = "â–¸",
                width = preview_column_width,
                tooltip = "Preview this note",
                notifier = function()
                    labeler.toggle_slice_preview(
                        note_info.instrument_index,
                        note_info.note_value,
                        preview_button_id,
                        capture_vb
                    )
                end
            },
            
            -- Instrument
            capture_vb:text {
                text = note_info.display_instrument,
                width = narrow_column,
                align = "center"
            },
            
            -- Note
            capture_vb:text {
                text = note_info.display_note,
                width = narrow_column,
                align = "center"
            },
            
            -- Label dropdown
            capture_vb:popup {
                id = "label_" .. i,
                items = label_options,
                width = column_width,
                value = table.find(label_options, note_info.label) or 1
            },
            
            -- Label 2 dropdown (if enabled)
            show_label2 and capture_vb:popup {
                id = "label2_" .. i,
                items = label_options,
                width = column_width,
                value = table.find(label_options, note_info.label2) or 1
            } or capture_vb:space { width = 1 },
            
            -- Status
            capture_vb:text {
                text = status_text,
                width = 80,
                style = status_style
            }
        }
        
        dialog_content:add_child(row)
    end
    
    -- Add buttons
    dialog_content:add_child(capture_vb:space { height = 10 })
    dialog_content:add_child(
        capture_vb:row {
            spacing = 10,
            
            capture_vb:button {
                text = "Capture & Save Labels",
                width = 140,
                notifier = function()
                    -- Phase 6: Stop any active preview
                    labeler.stop_slice_preview()
                    
                    -- Collect labels from dialog
                    local labels_to_save = {}
                    for i, note_info in ipairs(unique_notes_list) do
                        local label_popup = capture_vb.views["label_" .. i]
                        local label2_popup = capture_vb.views["label2_" .. i]
                        
                        note_info.label = label_popup.items[label_popup.value]
                        note_info.label2 = show_label2 and label2_popup and label2_popup.items[label2_popup.value] or "---------"
                        
                        -- Group by instrument for saving
                        if not labels_to_save[note_info.instrument_index] then
                            labels_to_save[note_info.instrument_index] = {}
                        end
                        
                        -- Use slice-based key for sliced samples (note 37+ = slice keys)
                        -- This matches what the labeler uses
                        local save_key
                        if note_info.note_value >= 37 then
                            save_key = string.format("%02X", note_info.note_value - 36)  -- Slice key
                        else
                            save_key = string.format("%02X", note_info.note_value)  -- Note key
                        end
                        
                        labels_to_save[note_info.instrument_index][save_key] = {
                            label = note_info.label,
                            label2 = note_info.label2,
                            breakpoint = false,
                            instrument_index = note_info.instrument_index,
                            note_value = note_info.note_value
                        }
                    end
                    
                    -- Save labels to each instrument
                    for inst_idx, inst_labels in pairs(labels_to_save) do
                        -- Merge with existing labels
                        local existing = labeler.get_labels_for_instrument(inst_idx)
                        for key, label_data in pairs(inst_labels) do
                            existing[key] = label_data
                        end
                        labeler.store_labels_for_instrument(inst_idx, existing)
                    end
                    
                    -- Close dialog
                    if capture_dialog and capture_dialog.visible then
                        capture_dialog:close()
                    end
                    
                    -- Now capture the symbol
                    capture_selection_as_symbol()
                end
            },
            
            capture_vb:button {
                text = "Capture Only",
                width = 100,
                notifier = function()
                    -- Phase 6: Stop any active preview
                    labeler.stop_slice_preview()
                    
                    -- Close dialog and capture without saving labels
                    if capture_dialog and capture_dialog.visible then
                        capture_dialog:close()
                    end
                    capture_selection_as_symbol()
                end
            },
            
            capture_vb:button {
                text = "Cancel",
                width = 80,
                notifier = function()
                    -- Phase 6: Stop any active preview
                    labeler.stop_slice_preview()
                    
                    if capture_dialog and capture_dialog.visible then
                        capture_dialog:close()
                    end
                end
            }
        }
    )
    
    capture_dialog = renoise.app():show_custom_dialog("Capture with Labels", dialog_content)
end

-- ============================================================================
-- Phase 2: Audio Preview Functions (API 6.2)
-- ============================================================================

-- Timer handle for sequential preview
local preview_timer_active = false

-- Stop any currently playing symbol preview
function stop_symbol_preview()
    -- Remove timer if active
    if preview_timer_active then
        if renoise.tool():has_timer(preview_timer_callback) then
            renoise.tool():remove_timer(preview_timer_callback)
        end
        preview_timer_active = false
    end
    
    if not preview_state.active then
        return
    end
    
    local song = renoise.song()
    if not song then
        preview_state.active = false
        preview_state.notes = {}
        preview_state.symbol = nil
        return
    end
    
    -- Stop all notes that were triggered
    for _, note_info in ipairs(preview_state.notes) do
        local inst_idx = note_info.instrument_index
        local track_idx = preview_state.track_index or song.selected_track_index
        local note_val = note_info.note_value
        
        -- Use API 6.2 trigger_instrument_note_off
        pcall(function()
            song:trigger_instrument_note_off(inst_idx, track_idx, note_val)
        end)
    end
    
    print("DEBUG: Stopped preview for symbol:", preview_state.symbol or "unknown")
    
    -- Reset preview state
    preview_state.active = false
    preview_state.instrument_index = nil
    preview_state.track_index = nil
    preview_state.notes = {}
    preview_state.symbol = nil
    preview_state.scheduled_notes = nil
    preview_state.current_note_index = nil
    preview_state.start_time = nil
end

-- Timer callback for sequential note playback
function preview_timer_callback()
    if not preview_state.active or not preview_state.scheduled_notes then
        stop_symbol_preview()
        return
    end
    
    local song = renoise.song()
    if not song then
        stop_symbol_preview()
        return
    end
    
    local current_time = os.clock()
    local elapsed = current_time - preview_state.start_time
    local elapsed_ms = elapsed * 1000
    
    -- Check for notes that should be triggered
    local notes_remaining = false
    for i, note_info in ipairs(preview_state.scheduled_notes) do
        if not note_info.triggered then
            notes_remaining = true
            if elapsed_ms >= note_info.trigger_time_ms then
                -- Trigger this note
                local inst_idx = note_info.instrument_index
                local track_idx = preview_state.track_index
                local note_val = note_info.note_value
                local vol_normalized = note_info.volume_normalized
                
                pcall(function()
                    song:trigger_instrument_note_on(inst_idx, track_idx, note_val, vol_normalized)
                end)
                
                -- Add to active notes for cleanup
                table.insert(preview_state.notes, {
                    note_value = note_val,
                    instrument_index = inst_idx
                })
                
                note_info.triggered = true
                print("DEBUG: Triggered note", note_val, "inst", inst_idx, "at", elapsed_ms, "ms")
            end
        end
    end
    
    -- Check if all notes have been triggered
    if not notes_remaining then
        -- Keep timer running briefly to let last notes play, then stop
        if not preview_state.finishing then
            preview_state.finishing = true
            preview_state.finish_time = current_time
        elseif current_time - preview_state.finish_time > 0.5 then
            -- 500ms after last note, stop preview
            stop_symbol_preview()
        end
    end
end

-- Preview a symbol (plays notes in sequence with original timing)
function preview_symbol(symbol_name)
    -- Stop any existing preview first
    stop_symbol_preview()
    
    local song = renoise.song()
    if not song then
        renoise.app():show_warning("No song loaded")
        return false
    end
    
    -- Check if symbol exists in registry
    local symbol_data = global_symbol_registry[symbol_name]
    if not symbol_data then
        print("DEBUG: Symbol not found in registry:", symbol_name)
        return false
    end
    
    -- Get current BPM and LPB for timing calculations
    local bpm = song.transport.bpm
    local lpb = song.transport.lpb
    
    -- Calculate milliseconds per line
    -- BPM = beats per minute, LPB = lines per beat
    -- Lines per minute = BPM * LPB
    -- Seconds per line = 60 / (BPM * LPB)
    -- Milliseconds per line = 60000 / (BPM * LPB)
    local ms_per_line = 60000 / (bpm * lpb)
    
    -- Delay value 256 = one full line, so ms_per_delay_unit = ms_per_line / 256
    local ms_per_delay_unit = ms_per_line / 256
    
    print("DEBUG: BPM=" .. bpm .. " LPB=" .. lpb .. " ms_per_line=" .. ms_per_line)
    
    -- Collect notes with their timing information
    local scheduled_notes = {}
    
    if symbol_data.break_set and symbol_data.break_set.timing then
        for _, timing in ipairs(symbol_data.break_set.timing) do
            -- Calculate trigger time for this timing entry
            local relative_line = timing.relative_line or 1
            local delay = timing.new_delay or 0
            
            -- Time in ms from start: (line - 1) * ms_per_line + delay * ms_per_delay_unit
            local trigger_time_ms = ((relative_line - 1) * ms_per_line) + (delay * ms_per_delay_unit)
            
            -- Get the source instrument index (this is the actual instrument to trigger)
            -- source_instrument_index is 1-based (Renoise convention)
            local source_inst_idx = timing.source_instrument_index or symbol_data.instrument_index or 1
            
            -- Check if this timing entry has note_columns (multi-column data)
            if timing.note_columns then
                for col_idx, col_data in pairs(timing.note_columns) do
                    if col_data.note_value and 
                       col_data.note_value ~= renoise.PatternLine.EMPTY_NOTE and
                       col_data.note_value < 120 and
                       col_data.instrument_value and
                       col_data.instrument_value ~= 255 then
                        -- Calculate the slice trigger note from the instrument_value (slice number)
                        -- Slice 1 = C#1 (note 37), Slice 2 = D-1 (note 38), etc.
                        -- Formula: slice_note = 36 + slice_number
                        local slice_note = 36 + col_data.instrument_value
                        local volume = col_data.volume_value or 0x80
                        local vol_normalized = (volume == 255 or volume == renoise.PatternLine.EMPTY_VOLUME) 
                            and 0.5 or (volume / 127)
                        
                        table.insert(scheduled_notes, {
                            note_value = slice_note,
                            instrument_index = source_inst_idx,
                            volume_normalized = vol_normalized,
                            trigger_time_ms = trigger_time_ms,
                            triggered = false
                        })
                        print("DEBUG: Scheduled note (multi-col) slice", col_data.instrument_value, "-> note", slice_note, "inst", source_inst_idx, "at", trigger_time_ms, "ms")
                    end
                end
            -- Fallback to single note_value if no note_columns
            elseif timing.note_value and 
                   timing.note_value ~= renoise.PatternLine.EMPTY_NOTE and
                   timing.note_value < 120 and
                   timing.instrument_value and
                   timing.instrument_value ~= 255 then
                -- Calculate the slice trigger note from the instrument_value (slice number)
                -- Slice 1 = C#1 (note 37), Slice 2 = D-1 (note 38), etc.
                -- Formula: slice_note = 36 + slice_number
                local slice_note = 36 + timing.instrument_value
                local volume = timing.volume_value or 0x80
                local vol_normalized = (volume == 255 or volume == renoise.PatternLine.EMPTY_VOLUME) 
                    and 0.5 or (volume / 127)
                
                table.insert(scheduled_notes, {
                    note_value = slice_note,
                    instrument_index = source_inst_idx,
                    volume_normalized = vol_normalized,
                    trigger_time_ms = trigger_time_ms,
                    triggered = false
                })
                print("DEBUG: Scheduled note (fallback) slice", timing.instrument_value, "-> note", slice_note, "inst", source_inst_idx, "at", trigger_time_ms, "ms")
            end
        end
    end
    
    if #scheduled_notes == 0 then
        print("DEBUG: No valid notes to preview for symbol:", symbol_name)
        return false
    end
    
    -- Sort by trigger time
    table.sort(scheduled_notes, function(a, b)
        return a.trigger_time_ms < b.trigger_time_ms
    end)
    
    -- Add a short delay before the first note (150ms) to allow UI to settle
    local initial_delay_ms = 150
    for _, note in ipairs(scheduled_notes) do
        note.trigger_time_ms = note.trigger_time_ms + initial_delay_ms
    end
    
    -- Set up preview state
    preview_state.active = true
    preview_state.track_index = song.selected_track_index
    preview_state.symbol = symbol_name
    preview_state.notes = {}  -- Will be filled as notes are triggered
    preview_state.scheduled_notes = scheduled_notes
    preview_state.start_time = os.clock()
    preview_state.finishing = false
    
    -- Start timer (10ms interval for responsive timing)
    if not renoise.tool():has_timer(preview_timer_callback) then
        renoise.tool():add_timer(preview_timer_callback, 10)
        preview_timer_active = true
    end
    
    print("DEBUG: Started sequential preview for symbol:", symbol_name, "with", #scheduled_notes, "notes")
    return true
end

-- Preview a specific sample directly (helper function)
function preview_sample_direct(instrument_index, sample_index, note_value, volume)
    local song = renoise.song()
    if not song then return false end
    
    -- Stop any existing preview
    stop_symbol_preview()
    
    local track_idx = song.selected_track_index
    local vol_normalized = volume and (volume / 127) or 0.5
    
    -- Set up preview state for single note
    preview_state.active = true
    preview_state.track_index = track_idx
    preview_state.symbol = nil
    preview_state.notes = {{
        note_value = note_value,
        instrument_index = instrument_index,
        sample_index = sample_index
    }}
    
    -- Use trigger_sample_note_on for direct sample playback
    local success = pcall(function()
        song:trigger_sample_note_on(instrument_index, sample_index, track_idx, note_value, vol_normalized, false)
    end)
    
    return success
end

-- ============================================================================
-- Phase 2: Selection-Based Breakpoint Creation
-- ============================================================================

-- Add breakpoints from current pattern selection
function add_breakpoints_from_selection()
    print("DEBUG: Adding breakpoints from selection")
    
    local song = renoise.song()
    if not song then
        renoise.app():show_warning("No song loaded")
        return false
    end
    
    -- Check for valid selection
    local sel = song.selection_in_pattern
    if not sel then
        renoise.app():show_warning("No selection in pattern. Please select some notes first.")
        return false
    end
    
    local pattern_index = song.selected_pattern_index
    local pattern = song.patterns[pattern_index]
    if not pattern then
        renoise.app():show_warning("Could not access current pattern")
        return false
    end
    
    -- Collect unique (instrument_index, note_value) pairs from selection
    local unique_notes = {}
    local notes_found = 0
    
    for track_idx = sel.start_track, sel.end_track do
        local track = pattern:track(track_idx)
        if track then
            for line_idx = sel.start_line, sel.end_line do
                local line = track:line(line_idx)
                if line then
                    -- Determine column range for this track
                    local start_col = (track_idx == sel.start_track) and sel.start_column or 1
                    local end_col = (track_idx == sel.end_track) and sel.end_column or #line.note_columns
                    
                    -- Clamp to valid note column range
                    end_col = math.min(end_col, #line.note_columns)
                    
                    for col_idx = start_col, end_col do
                        local note_col = line:note_column(col_idx)
                        if note_col and note_col.note_value ~= renoise.PatternLine.EMPTY_NOTE then
                            local inst_idx = note_col.instrument_value
                            local note_val = note_col.note_value
                            
                            -- Skip OFF notes (120) and invalid instruments
                            if note_val < 120 and inst_idx ~= 255 then
                                local key = string.format("%03d_%03d", inst_idx, note_val)
                                if not unique_notes[key] then
                                    unique_notes[key] = {
                                        instrument_index = inst_idx + 1,  -- Convert to 1-based
                                        note_value = note_val
                                    }
                                    notes_found = notes_found + 1
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    
    if notes_found == 0 then
        renoise.app():show_warning("No valid notes found in selection")
        return false
    end
    
    -- Mark each unique note as a breakpoint in labeler data
    local breakpoints_added = 0
    
    for _, note_info in pairs(unique_notes) do
        local inst_idx = note_info.instrument_index
        local note_val = note_info.note_value
        
        -- Calculate the hex key (same format as labeler uses)
        -- For sliced instruments: slice 1 = note 37 (C#1), key "01"
        -- For non-sliced: use note value directly
        local hex_key
        if note_val >= 37 then
            -- Slice-based key (note 37 = slice 1 = "01")
            hex_key = string.format("%02X", note_val - 36)
        else
            -- Root sample or non-sliced
            hex_key = string.format("%02X", note_val)
        end
        
        -- Get or create label data for this instrument/note
        local saved_labels = labeler.get_labels_for_instrument(inst_idx)
        
        if not saved_labels[hex_key] then
            -- Create new label entry
            saved_labels[hex_key] = {
                label = "---------",
                label2 = "---------",
                breakpoint = true,
                instrument_index = inst_idx,
                note_value = note_val
            }
        else
            -- Update existing entry to mark as breakpoint
            saved_labels[hex_key].breakpoint = true
        end
        
        -- Save back to labeler
        labeler.set_labels_for_instrument(inst_idx, saved_labels)
        breakpoints_added = breakpoints_added + 1
        
        print("DEBUG: Added breakpoint for instrument", inst_idx, "note", note_val, "key", hex_key)
    end
    
    -- Trigger refresh to regenerate symbols
    if dialog and dialog.visible then
        -- Preserve tag inputs before refresh
        if current_dialog_vb then
            preserve_unsaved_tag_inputs(nil, current_dialog_vb)
        end
        dialog:close()
        show_main_dialog()
    end
    
    renoise.app():show_status(string.format("Added %d breakpoint(s) from selection", breakpoints_added))
    return true, breakpoints_added
end
function load_global_symbol_registry()
    if preferences.global_symbol_registry_data and preferences.global_symbol_registry_data.value ~= "" then
        -- Deserialize the registry from string format
        local success, loaded_registry = pcall(loadstring("return " .. preferences.global_symbol_registry_data.value))
        if success and loaded_registry then
            global_symbol_registry = loaded_registry
            
            -- Ensure all symbols have tags and color fields (backward compatibility)
            for symbol, symbol_data in pairs(global_symbol_registry) do
                -- Convert old category field to tags array
                if symbol_data.category ~= nil and symbol_data.tags == nil then
                    symbol_data.tags = symbol_data.category ~= "" and {symbol_data.category} or {}
                    symbol_data.category = nil  -- Remove old category field
                end
                if symbol_data.tags == nil then
                    symbol_data.tags = {}
                end
                if symbol_data.color == nil then
                    symbol_data.color = ""
                end
            end
            
            print("DEBUG: Loaded global symbol registry with", table.count(global_symbol_registry), "symbols")
        else
            print("DEBUG: Failed to load global symbol registry, starting with empty registry")
            global_symbol_registry = {}
        end
    else
        print("DEBUG: No saved global symbol registry found, starting with empty registry")
        global_symbol_registry = {}
    end
    
    -- Initialize tag editing states
    initialize_tag_editing_states()
end

-- Save global symbol registry to preferences
function save_global_symbol_registry()
    -- Serialize the registry to a string
    local serialized = serialize_table(global_symbol_registry)
    preferences.global_symbol_registry_data.value = serialized
    print("DEBUG: Saved global symbol registry with", table.count(global_symbol_registry), "symbols")
end

-- Export global symbol registry to CSV format
function export_global_alphabet_csv()
    local filepath = renoise.app():prompt_for_filename_to_write("csv", "Export Global Alphabet (CSV)")
    if not filepath or filepath == "" then return end
    
    if not filepath:lower():match("%.csv$") then
        filepath = filepath .. ".csv"
    end
    
    local file, err = io.open(filepath, "w")
    if not file then
        renoise.app():show_error("Unable to open file for writing: " .. tostring(err))
        return
    end
    
    -- Write CSV header - expanded to include content type and enhanced content detection
    -- Phase 4: Added Dictionary column
    file:write("Symbol,Dictionary,SymbolType,Tags,Color,InstrumentIndex,SliceIndex,SliceLabel,IsBreakpoint,TimingLine,TimingDelay,OriginalDistance,NoteValue,VolumeValue,PanningValue,EffectNumber,EffectAmount,HasNote,ContentType,EffectColumn1Number,EffectColumn1Amount,EffectColumn2Number,EffectColumn2Amount,EffectColumn3Number,EffectColumn3Amount,EffectColumn4Number,EffectColumn4Amount,EffectColumn5Number,EffectColumn5Amount,EffectColumn6Number,EffectColumn6Amount,EffectColumn7Number,EffectColumn7Amount,EffectColumn8Number,EffectColumn8Amount,NoteColumn1Note,NoteColumn1Instrument,NoteColumn1Volume,NoteColumn1Panning,NoteColumn1Delay,NoteColumn1EffectNumber,NoteColumn1EffectAmount,NoteColumn2Note,NoteColumn2Instrument,NoteColumn2Volume,NoteColumn2Panning,NoteColumn2Delay,NoteColumn2EffectNumber,NoteColumn2EffectAmount,NoteColumn3Note,NoteColumn3Instrument,NoteColumn3Volume,NoteColumn3Panning,NoteColumn3Delay,NoteColumn3EffectNumber,NoteColumn3EffectAmount,NoteColumn4Note,NoteColumn4Instrument,NoteColumn4Volume,NoteColumn4Panning,NoteColumn4Delay,NoteColumn4EffectNumber,NoteColumn4EffectAmount,NoteColumn5Note,NoteColumn5Instrument,NoteColumn5Volume,NoteColumn5Panning,NoteColumn5Delay,NoteColumn5EffectNumber,NoteColumn5EffectAmount,NoteColumn6Note,NoteColumn6Instrument,NoteColumn6Volume,NoteColumn6Panning,NoteColumn6Delay,NoteColumn6EffectNumber,NoteColumn6EffectAmount,NoteColumn7Note,NoteColumn7Instrument,NoteColumn7Volume,NoteColumn7Panning,NoteColumn7Delay,NoteColumn7EffectNumber,NoteColumn7EffectAmount,NoteColumn8Note,NoteColumn8Instrument,NoteColumn8Volume,NoteColumn8Panning,NoteColumn8Delay,NoteColumn8EffectNumber,NoteColumn8EffectAmount,NoteColumn9Note,NoteColumn9Instrument,NoteColumn9Volume,NoteColumn9Panning,NoteColumn9Delay,NoteColumn9EffectNumber,NoteColumn9EffectAmount,NoteColumn10Note,NoteColumn10Instrument,NoteColumn10Volume,NoteColumn10Panning,NoteColumn10Delay,NoteColumn10EffectNumber,NoteColumn10EffectAmount,NoteColumn11Note,NoteColumn11Instrument,NoteColumn11Volume,NoteColumn11Panning,NoteColumn11Delay,NoteColumn11EffectNumber,NoteColumn11EffectAmount,NoteColumn12Note,NoteColumn12Instrument,NoteColumn12Volume,NoteColumn12Panning,NoteColumn12Delay,NoteColumn12EffectNumber,NoteColumn12EffectAmount,SourcePattern,SourceTrack,CaptureStartLine,CaptureEndLine\n")

    -- Write data for each symbol
    for symbol, symbol_data in pairs(global_symbol_registry) do
        local instrument_index = symbol_data.instrument_index or 1
        local break_set = symbol_data.break_set
        local saved_labels = symbol_data.saved_labels or {}
        local symbol_type = symbol_data.symbol_type or "breakpoint_created"
        local symbol_color = symbol_data.color or ""
        local symbol_tags = symbol_data.tags or {}
        
        -- Phase 4: Get dictionary for this symbol
        local symbol_dictionary = get_dictionary_for_symbol(symbol) or ""
        
        -- Convert tags array to comma-separated string
        local tags_string = ""
        if #symbol_tags > 0 then
            tags_string = table.concat(symbol_tags, ", ")
        end
        
        print("DEBUG: Exporting symbol " .. symbol .. " (type: " .. symbol_type .. ") with " .. (function()
            local count = 0
            for _ in pairs(saved_labels) do count = count + 1 end
            return count
        end)() .. " labels, tags: " .. tags_string .. ", color: " .. symbol_color .. ", dictionary: " .. symbol_dictionary)
        
        -- Debug: Show available labels for this symbol
        for hex_key, label_data in pairs(saved_labels) do
            print("DEBUG:   " .. symbol .. " has label " .. hex_key .. " -> " .. (label_data.label or ""))
        end
        
        -- Extract source metadata for range-captured symbols
        local source_pattern = ""
        local source_track = ""
        local capture_start_line = ""
        local capture_end_line = ""
        
        if symbol_type == "range_captured" and symbol_data.source_metadata then
            source_pattern = tostring(symbol_data.source_metadata.pattern_index or "")
            source_track = tostring(symbol_data.source_metadata.track_index or "")
            if symbol_data.source_metadata.capture_info then
                capture_start_line = tostring(symbol_data.source_metadata.capture_info.start_line or "")
                capture_end_line = tostring(symbol_data.source_metadata.capture_info.end_line or "")
            end
        end
        
        if break_set and break_set.timing then
            for _, timing in ipairs(break_set.timing) do
                local slice_index = timing.instrument_value or 0
                local slice_label = ""
                local is_breakpoint = false
                local note_value = timing.note_value or ""
                
                -- For range symbols, calculate the hex_key using the same logic as label mapping
                local hex_key
                if symbol_type == "range_captured" then
                    -- Use the same note-to-slice mapping as in selection.lua
                    local calculated_slice_index = 0
                    if note_value >= 37 then
                        calculated_slice_index = note_value - 36
                    end
                    hex_key = string.format("%02X", calculated_slice_index + 1)
                    print("DEBUG: Range symbol " .. symbol .. " note " .. note_value .. " -> slice " .. calculated_slice_index .. " -> hex_key " .. hex_key)
                else
                    -- Breakpoint symbols use the instrument_value
                    hex_key = string.format("%02X", slice_index + 1)
                end
                
                local label_data = saved_labels[hex_key] or {}
                slice_label = label_data.label or ""
                is_breakpoint = label_data.breakpoint or false
                
                print("DEBUG: Symbol " .. symbol .. " using hex_key " .. hex_key .. " -> label '" .. slice_label .. "'")
                
                -- Escape CSV fields - ensure all values are strings and handle nil
                local function escape_csv_field(field)
                    -- Convert to string and handle nil values
                    local str_field = tostring(field or "")
                    if str_field:find(',') or str_field:find('"') then
                        return '"' .. str_field:gsub('"', '""') .. '"'
                    end
                    return str_field
                end
                
                -- For range-captured symbols, use the actual instrument value from the timing data
                -- For breakpoint symbols, use the slice_index as before
                local actual_instrument_value = slice_index
                if symbol_type == "range_captured" and timing.source_instrument_index then
                    -- For range symbols, the instrument value should be the 0-based instrument from the pattern
                    actual_instrument_value = (timing.source_instrument_index - 1)
                end
                
                -- Extract all 8 effect columns data
                local effect_columns_data = {}
                if timing.effect_columns then
                    for fx_col = 1, 8 do
                        if timing.effect_columns[fx_col] then
                            table.insert(effect_columns_data, timing.effect_columns[fx_col].number_value or "")
                            table.insert(effect_columns_data, timing.effect_columns[fx_col].amount_value or "")
                        else
                            table.insert(effect_columns_data, "")  -- Empty number value
                            table.insert(effect_columns_data, "")  -- Empty amount value
                        end
                    end
                else
                    -- No effect columns data, add 16 empty fields (8 columns x 2 values each)
                    for fx_col = 1, 16 do
                        table.insert(effect_columns_data, "")
                    end
                end

                -- Extract all 12 note columns data
                local note_columns_data = {}
                if timing.note_columns then
                    for note_col = 1, 12 do
                        if timing.note_columns[note_col] then
                            table.insert(note_columns_data, timing.note_columns[note_col].note_value or "")
                            table.insert(note_columns_data, timing.note_columns[note_col].instrument_value or "")
                            table.insert(note_columns_data, timing.note_columns[note_col].volume_value or "")
                            table.insert(note_columns_data, timing.note_columns[note_col].panning_value or "")
                            table.insert(note_columns_data, timing.note_columns[note_col].delay_value or "")
                            table.insert(note_columns_data, timing.note_columns[note_col].effect_number_value or "")
                            table.insert(note_columns_data, timing.note_columns[note_col].effect_amount_value or "")
                        else
                            -- Add 7 empty fields for this note column (note, instrument, volume, panning, delay, effect_number, effect_amount)
                            for field = 1, 7 do
                                table.insert(note_columns_data, "")
                            end
                        end
                    end
                else
                    -- No note columns data, add 84 empty fields (12 columns x 7 values each)
                    for note_col = 1, 84 do
                        table.insert(note_columns_data, "")
                    end
                end

                local values = {
                    symbol or "",
                    symbol_dictionary or "",  -- Phase 4: Dictionary column
                    symbol_type or "",
                    tags_string or "",  -- Use comma-separated tags string
                    symbol_color or "",
                    instrument_index or "",
                    actual_instrument_value or "",
                    slice_label or "",
                    tostring(is_breakpoint),
                    timing.relative_line or "",
                    timing.new_delay or "",
                    timing.original_distance or "",
                    note_value or "",
                    timing.volume_value or "",
                    timing.panning_value or "",
                    timing.effect_number_value or "",
                    timing.effect_amount_value or "",
                    -- NEW: Enhanced content information
                    tostring(timing.has_note or false),
                    timing.content_type or ""
                }
                
                -- Add all effect columns data
                for _, fx_data in ipairs(effect_columns_data) do
                    table.insert(values, fx_data)
                end
                
                -- Add all note columns data
                for _, note_data in ipairs(note_columns_data) do
                    table.insert(values, note_data)
                end
                
                -- Add remaining fields
                table.insert(values, source_pattern)
                table.insert(values, source_track)
                table.insert(values, capture_start_line)
                table.insert(values, capture_end_line)       
                
                -- Ensure all values are properly escaped
                for i, value in ipairs(values) do
                    values[i] = escape_csv_field(value)
                end
                
                file:write(table.concat(values, ",") .. "\n")
            end
        end
    end
    
    file:close()
    renoise.app():show_status("Global alphabet exported to " .. filepath)
end

-- Export global symbol registry to JSON format
function export_global_alphabet_json()
    local filepath = renoise.app():prompt_for_filename_to_write("json", "Export Global Alphabet (JSON)")
    if not filepath or filepath == "" then return end
    
    if not filepath:lower():match("%.json$") then
        filepath = filepath .. ".json"
    end
    
    local file, err = io.open(filepath, "w")
    if not file then
        renoise.app():show_error("Unable to open file for writing: " .. tostring(err))
        return
    end
    
    -- Build export structure with expanded schema
    local export_data = {
        version = "2.0",
        symbols = {}
    }
    
    for symbol, symbol_data in pairs(global_symbol_registry) do
        local instrument_index = symbol_data.instrument_index or 1
        local break_set = symbol_data.break_set
        local saved_labels = symbol_data.saved_labels or {}
        local symbol_type = symbol_data.symbol_type or "breakpoint_created"
        
        -- Phase 4: Get dictionary for this symbol
        local symbol_dictionary = get_dictionary_for_symbol(symbol) or ""
        
        -- Build symbol entry with all metadata
        local symbol_entry = {
            symbol_type = symbol_type,
            instrument_index = instrument_index,
            tags = symbol_data.tags or {},  -- Store as array
            color = symbol_data.color or "",
            dictionary = symbol_dictionary,  -- Phase 4: Add dictionary
            notes = {},
            timing_data = {}
        }
        
        -- Add source metadata for range-captured symbols
        if symbol_type == "range_captured" and symbol_data.source_metadata then
            symbol_entry.source_metadata = {
                pattern_index = symbol_data.source_metadata.pattern_index,
                track_index = symbol_data.source_metadata.track_index,
                capture_info = symbol_data.source_metadata.capture_info,
                -- Phase 5: Multi-track metadata
                track_count = symbol_data.source_metadata.track_count,
                first_track_index = symbol_data.source_metadata.first_track_index,
                track_names = symbol_data.source_metadata.track_names,
                is_multi_track = symbol_data.source_metadata.is_multi_track
            }
        end
        
        -- Phase 5: Add break_set level multi-track metadata
        if break_set then
            symbol_entry.track_count = break_set.track_count
            symbol_entry.first_track_index = break_set.first_track_index
            symbol_entry.track_names = break_set.track_names
            symbol_entry.is_multi_track = break_set.is_multi_track
        end
        
        -- Add saved labels for both breakpoint and range symbols (range symbols can now have labels too)
        if saved_labels and next(saved_labels) ~= nil then
            symbol_entry.saved_labels = saved_labels
        end
        
        if break_set and break_set.timing then
            for _, timing in ipairs(break_set.timing) do
                local slice_index = timing.instrument_value or 0
                local hex_key = string.format("%02X", slice_index + 1)
                local label_data = saved_labels[hex_key] or {}
                
                -- For range-captured symbols, use the actual instrument value from timing data
                -- For breakpoint symbols, use the slice_index as before
                local actual_slice_index = slice_index
                local actual_instrument_value = timing.source_instrument_index or instrument_index
                
                if symbol_type == "range_captured" then
                    -- For range symbols, slice_index should represent the actual instrument value from the pattern
                    actual_slice_index = (timing.source_instrument_index and (timing.source_instrument_index - 1)) or slice_index
                end
                
                -- Build note entry with comprehensive data
                local note_entry = {
                    slice_index = actual_slice_index,
                    label = label_data.label or "",
                    breakpoint = label_data.breakpoint or false,
                    timing_line = timing.relative_line or 1,
                    timing_delay = timing.new_delay or 0,
                    original_distance = timing.original_distance or 256,
                    source_instrument_index = actual_instrument_value,
                    -- NEW: Enhanced content information
                    has_note = timing.has_note or false,
                    content_type = timing.content_type or "note"
                }
                
                -- Add note_value for range-captured symbols
                if timing.note_value then
                    note_entry.note_value = timing.note_value
                end
                
                -- Add additional timing properties if they exist
                if timing.volume_value then
                    note_entry.volume_value = timing.volume_value
                end
                if timing.panning_value then
                    note_entry.panning_value = timing.panning_value
                end
                if timing.effect_number_value then
                    note_entry.effect_number_value = timing.effect_number_value
                end
                if timing.effect_amount_value then
                    note_entry.effect_amount_value = timing.effect_amount_value
                end
                
                -- Add note columns data if available
                if timing.note_columns then
                    note_entry.note_columns = timing.note_columns
                end
                
                table.insert(symbol_entry.notes, note_entry)
                
                -- Also store raw timing data for exact reconstruction
                table.insert(symbol_entry.timing_data, {
                    instrument_value = timing.instrument_value or 0,
                    relative_line = timing.relative_line or 1,
                    new_delay = timing.new_delay or 0,
                    original_distance = timing.original_distance or 256,
                    source_instrument_index = timing.source_instrument_index or instrument_index,
                    note_value = timing.note_value,
                    volume_value = timing.volume_value,
                    panning_value = timing.panning_value,
                    effect_number_value = timing.effect_number_value,
                    effect_amount_value = timing.effect_amount_value,
                    effect_columns = timing.effect_columns or {},
                    note_columns = timing.note_columns or {},
                    -- NEW: Enhanced content information
                    has_note = timing.has_note or false,
                    content_type = timing.content_type or "note",
                    -- Phase 5: Multi-track information
                    track_index = timing.track_index,
                    track_offset = timing.track_offset or 0
                })
            end
        end
        
        export_data.symbols[symbol] = symbol_entry
    end
    
    -- Phase 4: Export dictionaries
    export_data.dictionaries = {}
    for dict_name, dict_data in pairs(symbol_dictionaries) do
        export_data.dictionaries[dict_name] = {
            name = dict_data.name,
            color = dict_data.color or "",
            symbols = dict_data.symbols or {},
            description = dict_data.description or "",
            created_at = dict_data.created_at
        }
    end
    
    -- Write JSON
    local json_str = json.encode(export_data)
    file:write(json_str)
    file:close()
    
    renoise.app():show_status("Global alphabet exported to " .. filepath)
end

-- Show format selection dialog for export
function export_global_alphabet()
    local vb = renoise.ViewBuilder()
    local format_dialog = nil  -- Declare upfront
    
    local dialog_content = vb:column {
        margin = 10,
        spacing = 10,
        
        vb:text {
            text = "Export Global Alphabet",
            font = "big",
            style = "strong"
        },
        
        vb:text {
            text = "Choose export format:",
            style = "strong"
        },
        
        vb:row {
            spacing = 10,
            
            vb:button {
                text = "CSV",
                width = 80,
                notifier = function()
                    if format_dialog then format_dialog:close() end
                    export_global_alphabet_csv()
                end
            },
            
            vb:button {
                text = "JSON",
                width = 80,
                notifier = function()
                    if format_dialog then format_dialog:close() end
                    export_global_alphabet_json()
                end
            },
            
            vb:button {
                text = "Cancel",
                width = 80,
                notifier = function()
                    if format_dialog then format_dialog:close() end
                end
            }
        }
    }
    
    format_dialog = renoise.app():show_custom_dialog("Export Format", dialog_content)
end

-- Import global symbol registry from CSV format
function import_global_alphabet_csv()
    local filepath = renoise.app():prompt_for_filename_to_read({"*.csv"}, "Import Global Alphabet (CSV)")
    if not filepath or filepath == "" then return end
    
    local file, err = io.open(filepath, "r")
    if not file then
        renoise.app():show_error("Unable to open file: " .. tostring(err))
        return
    end
    
    -- Read and validate header
    local header = file:read()
    if not header then
        renoise.app():show_error("Invalid CSV format: No header found")
        file:close()
        return
    end
    
    -- Parse header to find column positions
    local function parse_csv_line(line)
        local fields = {}
        local field = ""
        local in_quotes = false
        
        local i = 1
        while i <= #line do
            local char = line:sub(i,i)
            
            if char == '"' then
                if in_quotes and line:sub(i+1,i+1) == '"' then
                    field = field .. '"'
                    i = i + 2
                else
                    in_quotes = not in_quotes
                    i = i + 1
                end
            elseif char == ',' and not in_quotes then
                table.insert(fields, field)
                field = ""
                i = i + 1
            else
                field = field .. char
                i = i + 1
            end
        end
        
        table.insert(fields, field)
        return fields
    end
    
    local function unescape_csv_field(field)
        if field:sub(1,1) == '"' and field:sub(-1) == '"' then
            return field:sub(2, -2):gsub('""', '"')
        end
        return field
    end
    
    local header_fields = parse_csv_line(header)
    local column_positions = {}
    
    -- Updated expected columns to include content type fields, all 8 effect columns, and all 12 note columns
    -- Phase 4: Added dictionary column
    local expected_columns = {
        "symbol", "dictionary", "symboltype", "tags", "color", "instrumentindex", "sliceindex", "slicelabel", 
        "timingline", "timingdelay", "originaldistance", "notevalue", "volumevalue", "panningvalue", 
        "effectnumber", "effectamount", "hasnote", "contenttype",
        "effectcolumn1number", "effectcolumn1amount", "effectcolumn2number", "effectcolumn2amount",
        "effectcolumn3number", "effectcolumn3amount", "effectcolumn4number", "effectcolumn4amount",
        "effectcolumn5number", "effectcolumn5amount", "effectcolumn6number", "effectcolumn6amount",
        "effectcolumn7number", "effectcolumn7amount", "effectcolumn8number", "effectcolumn8amount",
        "notecolumn1note", "notecolumn1instrument", "notecolumn1volume", "notecolumn1panning", "notecolumn1delay", "notecolumn1effectnumber", "notecolumn1effectamount",
        "notecolumn2note", "notecolumn2instrument", "notecolumn2volume", "notecolumn2panning", "notecolumn2delay", "notecolumn2effectnumber", "notecolumn2effectamount",
        "notecolumn3note", "notecolumn3instrument", "notecolumn3volume", "notecolumn3panning", "notecolumn3delay", "notecolumn3effectnumber", "notecolumn3effectamount",
        "notecolumn4note", "notecolumn4instrument", "notecolumn4volume", "notecolumn4panning", "notecolumn4delay", "notecolumn4effectnumber", "notecolumn4effectamount",
        "notecolumn5note", "notecolumn5instrument", "notecolumn5volume", "notecolumn5panning", "notecolumn5delay", "notecolumn5effectnumber", "notecolumn5effectamount",
        "notecolumn6note", "notecolumn6instrument", "notecolumn6volume", "notecolumn6panning", "notecolumn6delay", "notecolumn6effectnumber", "notecolumn6effectamount",
        "notecolumn7note", "notecolumn7instrument", "notecolumn7volume", "notecolumn7panning", "notecolumn7delay", "notecolumn7effectnumber", "notecolumn7effectamount",
        "notecolumn8note", "notecolumn8instrument", "notecolumn8volume", "notecolumn8panning", "notecolumn8delay", "notecolumn8effectnumber", "notecolumn8effectamount",
        "notecolumn9note", "notecolumn9instrument", "notecolumn9volume", "notecolumn9panning", "notecolumn9delay", "notecolumn9effectnumber", "notecolumn9effectamount",
        "notecolumn10note", "notecolumn10instrument", "notecolumn10volume", "notecolumn10panning", "notecolumn10delay", "notecolumn10effectnumber", "notecolumn10effectamount",
        "notecolumn11note", "notecolumn11instrument", "notecolumn11volume", "notecolumn11panning", "notecolumn11delay", "notecolumn11effectnumber", "notecolumn11effectamount",
        "notecolumn12note", "notecolumn12instrument", "notecolumn12volume", "notecolumn12panning", "notecolumn12delay", "notecolumn12effectnumber", "notecolumn12effectamount",
        "sourcepattern", "sourcetrack", "capturestartline", "captureendline"
    }
    
    -- Map header fields to column positions (case insensitive)
    for i, field in ipairs(header_fields) do
        local lower_field = field:lower():gsub("%s+", "")
        for _, expected in ipairs(expected_columns) do
            if lower_field == expected then
                column_positions[expected] = i
                break
            end
        end
    end
    
    -- Validate required core columns exist (backwards compatibility check)
    local required_columns = {"symbol", "instrumentindex", "sliceindex", "timingline", "timingdelay", "originaldistance"}
    for _, required in ipairs(required_columns) do
        if not column_positions[required] then
            renoise.app():show_error("Invalid CSV format: Missing required '" .. required .. "' column")
            file:close()
            return
        end
    end
    
    -- Parse data lines
    local imported_symbols = {}
    local line_number = 1
    
    for line in file:lines() do
        line_number = line_number + 1
        local line_trimmed = line:gsub("^%s*(.-)%s*$", "%1")
        
        if line_trimmed ~= "" then  -- Only process non-empty lines
            local fields = parse_csv_line(line)
            
            if #fields >= #required_columns then  -- Only process lines with sufficient core fields
                -- Extract core fields
                local symbol = unescape_csv_field(fields[column_positions.symbol] or ""):upper()
                local symbol_type = unescape_csv_field(fields[column_positions.symboltype] or "breakpoint_created")
                local tags_string = unescape_csv_field(fields[column_positions.tags] or "")
                local color = unescape_csv_field(fields[column_positions.color] or "")
                local instrument_index = tonumber(unescape_csv_field(fields[column_positions.instrumentindex] or "1"))
                
                -- Phase 4: Extract dictionary
                local dictionary = ""
                if column_positions.dictionary and fields[column_positions.dictionary] then
                    dictionary = unescape_csv_field(fields[column_positions.dictionary])
                end
                
                -- Parse tags string into array
                local tags = {}
                if tags_string and tags_string ~= "" then
                    -- Split by comma and trim whitespace
                    for tag in tags_string:gmatch("([^,]+)") do
                        local trimmed_tag = tag:match("^%s*(.-)%s*$")  -- Trim whitespace
                        if trimmed_tag and trimmed_tag ~= "" then
                            table.insert(tags, trimmed_tag)
                        end
                    end
                end
                local slice_index = tonumber(unescape_csv_field(fields[column_positions.sliceindex] or "0"))
                local slice_label = unescape_csv_field(fields[column_positions.slicelabel] or "")
                local is_breakpoint_str = unescape_csv_field(fields[column_positions.isbreakpoint] or "false"):lower()
                local timing_line = tonumber(unescape_csv_field(fields[column_positions.timingline] or "1"))
                local timing_delay = tonumber(unescape_csv_field(fields[column_positions.timingdelay] or "0"))
                local original_distance = tonumber(unescape_csv_field(fields[column_positions.originaldistance] or "256"))
                
                -- Extract new fields with fallbacks
                local note_value = nil
                if column_positions.notevalue and fields[column_positions.notevalue] and fields[column_positions.notevalue] ~= "" then
                    note_value = tonumber(unescape_csv_field(fields[column_positions.notevalue]))
                end
                
                local volume_value = nil
                if column_positions.volumevalue and fields[column_positions.volumevalue] and fields[column_positions.volumevalue] ~= "" then
                    volume_value = tonumber(unescape_csv_field(fields[column_positions.volumevalue]))
                end
                
                local panning_value = nil
                if column_positions.panningvalue and fields[column_positions.panningvalue] and fields[column_positions.panningvalue] ~= "" then
                    panning_value = tonumber(unescape_csv_field(fields[column_positions.panningvalue]))
                end
                
                local effect_number_value = nil
                if column_positions.effectnumber and fields[column_positions.effectnumber] and fields[column_positions.effectnumber] ~= "" then
                    effect_number_value = tonumber(unescape_csv_field(fields[column_positions.effectnumber]))
                end
                
                local effect_amount_value = nil
                if column_positions.effectamount and fields[column_positions.effectamount] and fields[column_positions.effectamount] ~= "" then
                    effect_amount_value = tonumber(unescape_csv_field(fields[column_positions.effectamount]))
                end
                
                -- Extract enhanced content information
                local has_note = true  -- Default to true for backward compatibility
                if column_positions.hasnote and fields[column_positions.hasnote] and fields[column_positions.hasnote] ~= "" then
                    has_note = (unescape_csv_field(fields[column_positions.hasnote]):lower() == "true")
                end
                
                local content_type = "note"  -- Default for backward compatibility
                if column_positions.contenttype and fields[column_positions.contenttype] and fields[column_positions.contenttype] ~= "" then
                    content_type = unescape_csv_field(fields[column_positions.contenttype])
                end
                
                -- Extract all 8 effect columns data
                local effect_columns_data = {}
                for fx_col = 1, 8 do
                    local number_key = "effectcolumn" .. fx_col .. "number"
                    local amount_key = "effectcolumn" .. fx_col .. "amount"
                    
                    local fx_number = nil
                    local fx_amount = nil
                    
                    if column_positions[number_key] and fields[column_positions[number_key]] and fields[column_positions[number_key]] ~= "" then
                        fx_number = tonumber(unescape_csv_field(fields[column_positions[number_key]]))
                    end
                    
                    if column_positions[amount_key] and fields[column_positions[amount_key]] and fields[column_positions[amount_key]] ~= "" then
                        fx_amount = tonumber(unescape_csv_field(fields[column_positions[amount_key]]))
                    end
                    
                    -- Only store effect column data if we have valid values
                    if fx_number or fx_amount then
                        effect_columns_data[fx_col] = {
                            number_value = fx_number,
                            amount_value = fx_amount
                        }
                    end
                end
                
                -- Extract range capture metadata
                local source_pattern = nil
                local source_track = nil
                local capture_start_line = nil
                local capture_end_line = nil
                
                if symbol_type == "range_captured" then
                    if column_positions.sourcepattern and fields[column_positions.sourcepattern] and fields[column_positions.sourcepattern] ~= "" then
                        source_pattern = tonumber(unescape_csv_field(fields[column_positions.sourcepattern]))
                    end
                    if column_positions.sourcetrack and fields[column_positions.sourcetrack] and fields[column_positions.sourcetrack] ~= "" then
                        source_track = tonumber(unescape_csv_field(fields[column_positions.sourcetrack]))
                    end
                    if column_positions.capturestartline and fields[column_positions.capturestartline] and fields[column_positions.capturestartline] ~= "" then
                        capture_start_line = tonumber(unescape_csv_field(fields[column_positions.capturestartline]))
                    end
                    if column_positions.captureendline and fields[column_positions.captureendline] and fields[column_positions.captureendline] ~= "" then
                        capture_end_line = tonumber(unescape_csv_field(fields[column_positions.captureendline]))
                    end
                end
                
                local is_breakpoint = (is_breakpoint_str == "true")
                
                print("DEBUG: Importing " .. symbol_type .. " symbol " .. symbol .. " with slice_label '" .. slice_label .. "'")
                
                -- Validate essential data
                if symbol and symbol ~= "" and instrument_index and slice_index and timing_line and timing_delay and original_distance then
                    -- Initialize symbol data if not exists
                    if not imported_symbols[symbol] then
                        imported_symbols[symbol] = {
                            symbol_type = symbol_type,
                            instrument_index = instrument_index,
                            tags = tags,  -- Store tags array
                            color = color,
                            dictionary = dictionary,  -- Phase 4: Store dictionary
                            timing_data = {},
                            saved_labels = {},
                            source_metadata = nil
                        }
                        
                        -- Add source metadata for range-captured symbols
                        if symbol_type == "range_captured" and (source_pattern or source_track or capture_start_line or capture_end_line) then
                            imported_symbols[symbol].source_metadata = {
                                pattern_index = source_pattern,
                                track_index = source_track,
                                capture_info = {}
                            }
                            
                            if capture_start_line or capture_end_line then
                                imported_symbols[symbol].source_metadata.capture_info = {
                                    start_line = capture_start_line,
                                    end_line = capture_end_line
                                }
                            end
                        end
                    end
                    
                    -- Create timing entry with all available data
                    -- For range-captured symbols, slice_index contains the actual instrument value (0-based)
                    -- For breakpoint symbols, slice_index is the slice index
                    local timing_entry = {
                        instrument_value = slice_index,
                        relative_line = timing_line,
                        new_delay = timing_delay,
                        original_distance = original_distance,
                        source_instrument_index = instrument_index
                    }
                    
                    -- For range-captured symbols, ensure source_instrument_index reflects the actual instrument
                    if symbol_type == "range_captured" then
                        -- slice_index contains the 0-based instrument value from the pattern
                        -- Convert to 1-based for source_instrument_index
                        timing_entry.source_instrument_index = slice_index + 1
                    end
                    
                    -- Add note_value for range-captured symbols
                    if note_value then
                        timing_entry.note_value = note_value
                    end
                    
                    -- Add Vol/Pan/FX values if present
                    if volume_value then
                        timing_entry.volume_value = volume_value
                    end
                    if panning_value then
                        timing_entry.panning_value = panning_value
                    end
                    if effect_number_value then
                        timing_entry.effect_number_value = effect_number_value
                    end
                    if effect_amount_value then
                        timing_entry.effect_amount_value = effect_amount_value
                    end
                    
                    -- Add enhanced content information
                    timing_entry.has_note = has_note
                    timing_entry.content_type = content_type
                    
                    -- Add effect columns data if present
                    if next(effect_columns_data) ~= nil then
                        timing_entry.effect_columns = effect_columns_data
                    end
                    
                    -- Extract all 12 note columns data
                    local note_columns_data = {}
                    for note_col = 1, 12 do
                        local note_key = "notecolumn" .. note_col .. "note"
                        local instrument_key = "notecolumn" .. note_col .. "instrument"
                        local volume_key = "notecolumn" .. note_col .. "volume"
                        local panning_key = "notecolumn" .. note_col .. "panning"
                        local delay_key = "notecolumn" .. note_col .. "delay"
                        local effect_number_key = "notecolumn" .. note_col .. "effectnumber"
                        local effect_amount_key = "notecolumn" .. note_col .. "effectamount"
                        
                        local note_val = nil
                        local instrument_val = nil
                        local volume_val = nil
                        local panning_val = nil
                        local delay_val = nil
                        local effect_number_val = nil
                        local effect_amount_val = nil
                        
                        if column_positions[note_key] and fields[column_positions[note_key]] and fields[column_positions[note_key]] ~= "" then
                            note_val = tonumber(unescape_csv_field(fields[column_positions[note_key]]))
                        end
                        if column_positions[instrument_key] and fields[column_positions[instrument_key]] and fields[column_positions[instrument_key]] ~= "" then
                            instrument_val = tonumber(unescape_csv_field(fields[column_positions[instrument_key]]))
                        end
                        if column_positions[volume_key] and fields[column_positions[volume_key]] and fields[column_positions[volume_key]] ~= "" then
                            volume_val = tonumber(unescape_csv_field(fields[column_positions[volume_key]]))
                        end
                        if column_positions[panning_key] and fields[column_positions[panning_key]] and fields[column_positions[panning_key]] ~= "" then
                            panning_val = tonumber(unescape_csv_field(fields[column_positions[panning_key]]))
                        end
                        if column_positions[delay_key] and fields[column_positions[delay_key]] and fields[column_positions[delay_key]] ~= "" then
                            delay_val = tonumber(unescape_csv_field(fields[column_positions[delay_key]]))
                        end
                        if column_positions[effect_number_key] and fields[column_positions[effect_number_key]] and fields[column_positions[effect_number_key]] ~= "" then
                            effect_number_val = tonumber(unescape_csv_field(fields[column_positions[effect_number_key]]))
                        end
                        if column_positions[effect_amount_key] and fields[column_positions[effect_amount_key]] and fields[column_positions[effect_amount_key]] ~= "" then
                            effect_amount_val = tonumber(unescape_csv_field(fields[column_positions[effect_amount_key]]))
                        end
                        
                        -- Only store note column data if we have valid values
                        if note_val or instrument_val or volume_val or panning_val or delay_val or effect_number_val or effect_amount_val then
                            note_columns_data[note_col] = {
                                note_value = note_val,
                                instrument_value = instrument_val,
                                volume_value = volume_val,
                                panning_value = panning_val,
                                delay_value = delay_val,
                                effect_number_value = effect_number_val,
                                effect_amount_value = effect_amount_val
                            }
                        end
                    end
                    
                    -- Add note columns data if present
                    if next(note_columns_data) ~= nil then
                        timing_entry.note_columns = note_columns_data
                    end
                    
                    table.insert(imported_symbols[symbol].timing_data, timing_entry)
                    
                    -- Add label data - FIXED: Use correct hex_key calculation for range symbols
                    if slice_label ~= "" or is_breakpoint then
                        local hex_key
                        
                        if symbol_type == "range_captured" and note_value then
                            -- For range symbols, calculate hex_key using the same note-to-slice mapping
                            local calculated_slice_index = 0
                            if note_value >= 37 then
                                calculated_slice_index = note_value - 36
                            end
                            hex_key = string.format("%02X", calculated_slice_index + 1)
                            print("DEBUG: Range symbol " .. symbol .. " note " .. note_value .. " -> slice " .. calculated_slice_index .. " -> hex_key " .. hex_key)
                        else
                            -- For breakpoint symbols, use slice_index directly
                            hex_key = string.format("%02X", slice_index + 1)
                        end
                        
                        imported_symbols[symbol].saved_labels[hex_key] = {
                            label = slice_label,
                            breakpoint = is_breakpoint,
                            instrument_index = instrument_index
                        }
                        
                        print("DEBUG: Added label '" .. slice_label .. "' to symbol " .. symbol .. " hex_key " .. hex_key)
                    end
                else
                    print("WARNING: Line " .. line_number .. " has invalid core data, skipping")
                end
            else
                print("WARNING: Line " .. line_number .. " has insufficient fields, skipping")
            end
        end
    end
    
    file:close()
    
    if next(imported_symbols) == nil then
        renoise.app():show_warning("No valid symbol data found in file")
        return
    end
    
    -- Convert imported data to proper break_set format and update global registry
    for symbol, symbol_data in pairs(imported_symbols) do
        -- Create break_set structure
        local break_set = {
            timing = symbol_data.timing_data,
            notes = {},
            start_line = 1,
            end_line = 64  -- Default values
        }
        
        -- Create notes from timing data
        for _, timing in ipairs(symbol_data.timing_data) do
            local note_entry = {
                line = timing.relative_line,
                instrument_value = timing.instrument_value,
                delay_value = timing.new_delay,
                distance = timing.original_distance,
                is_last = false
            }
            
            -- Set note_value based on symbol type
            if symbol_data.symbol_type == "range_captured" and timing.note_value then
                note_entry.note_value = timing.note_value
            else
                note_entry.note_value = 48  -- C-4 default for breakpoint symbols
            end
            
            table.insert(break_set.notes, note_entry)
        end
        
        -- Adjust end_line based on actual content
        if #break_set.notes > 0 then
            local last_note = break_set.notes[#break_set.notes]
            local distance_in_lines = math.floor(last_note.distance / 256)
            break_set.end_line = last_note.line + distance_in_lines + 4 -- Add buffer
        end
        
        -- Create registry entry with proper structure
        local registry_entry = {
            instrument_index = symbol_data.instrument_index,
            break_set = break_set,
            saved_labels = symbol_data.saved_labels,
            tags = symbol_data.tags or (symbol_data.category and {symbol_data.category} or {}), -- Convert category to tags array
            color = symbol_data.color or ""
        }
        
        -- Add symbol type and source metadata for range-captured symbols
        if symbol_data.symbol_type == "range_captured" then
            registry_entry.symbol_type = "range_captured"
            if symbol_data.source_metadata then
                registry_entry.source_metadata = symbol_data.source_metadata
            end
        end
        
        -- Update global registry
        global_symbol_registry[symbol] = registry_entry
        
        -- Phase 4: Assign to dictionary if specified
        if symbol_data.dictionary and symbol_data.dictionary ~= "" then
            -- Create dictionary if it doesn't exist
            if not symbol_dictionaries[symbol_data.dictionary] then
                create_dictionary(symbol_data.dictionary, "", "")
            end
            add_symbol_to_dictionary(symbol, symbol_data.dictionary)
        end
        
        local label_count = 0
        for _ in pairs(symbol_data.saved_labels) do label_count = label_count + 1 end
        print("DEBUG: Imported symbol " .. symbol .. " with " .. label_count .. " labels")
    end
    
    -- Save to preferences
    save_global_symbol_registry()
    
    local symbol_count = 0
    for _ in pairs(imported_symbols) do symbol_count = symbol_count + 1 end
    
    renoise.app():show_status(string.format("Imported %d symbols from CSV", symbol_count))
    
    -- Refresh main dialog if open
    if dialog and dialog.visible then
        -- Preserve all unsaved tag inputs before refresh
        if current_dialog_vb then
            preserve_unsaved_tag_inputs(nil, current_dialog_vb)
        end
        dialog:close()
        show_main_dialog()
    end
end

-- Import global symbol registry from JSON format
function import_global_alphabet_json()
    local filepath = renoise.app():prompt_for_filename_to_read({"*.json"}, "Import Global Alphabet (JSON)")
    if not filepath or filepath == "" then return end
    
    local file, err = io.open(filepath, "r")
    if not file then
        renoise.app():show_error("Unable to open file: " .. tostring(err))
        return
    end
    
    local content = file:read("*all")
    file:close()
    
    -- Parse JSON
    local success, import_data = pcall(json.decode, content)
    if not success then
        renoise.app():show_error("Invalid JSON format: " .. tostring(import_data))
        return
    end
    
    -- Validate structure
    if not import_data.symbols or type(import_data.symbols) ~= "table" then
        renoise.app():show_error("Invalid JSON structure: Missing 'symbols' table")
        return
    end
    
    -- Check version for compatibility
    local format_version = import_data.version or "1.0"
    local is_legacy_format = (format_version == "1.0")
    
    local imported_count = 0
    
    -- Process each symbol
    for symbol, symbol_data in pairs(import_data.symbols) do
        if type(symbol_data) == "table" and 
           symbol_data.instrument_index and 
           ((symbol_data.notes and type(symbol_data.notes) == "table") or 
            (symbol_data.timing_data and type(symbol_data.timing_data) == "table")) then
            
            local instrument_index = symbol_data.instrument_index
            local symbol_type = symbol_data.symbol_type or "breakpoint_created"
            local tags = symbol_data.tags or {}
            -- Handle backward compatibility: convert old category to tags
            if symbol_data.category and #tags == 0 then
                tags = symbol_data.category ~= "" and {symbol_data.category} or {}
            end
            local color = symbol_data.color or ""
            local dictionary = symbol_data.dictionary or ""  -- Phase 4: Extract dictionary
            local timing_data = {}
            local saved_labels = {}
            local notes = {}
            local source_metadata = nil
            
            -- Handle different data sources based on format version
            local data_source = nil
            if not is_legacy_format and symbol_data.timing_data then
                -- New format: use timing_data for reconstruction
                data_source = symbol_data.timing_data
            elseif symbol_data.notes then
                -- Legacy format or fallback: use notes array
                data_source = symbol_data.notes
            end
            
            if data_source then
                -- Process timing/note data
                for _, entry in ipairs(data_source) do
                    if type(entry) == "table" then
                        local slice_index, timing_line, timing_delay, original_distance, note_value
                        local source_instrument_index = instrument_index
                        
                        -- Extract fields based on data source type
                        if not is_legacy_format and entry.instrument_value then
                            -- New timing_data format
                            slice_index = entry.instrument_value
                            timing_line = entry.relative_line
                            timing_delay = entry.new_delay
                            original_distance = entry.original_distance
                            note_value = entry.note_value
                            source_instrument_index = entry.source_instrument_index or instrument_index
                        else
                            -- Legacy notes format
                            slice_index = entry.slice_index
                            timing_line = entry.timing_line
                            timing_delay = entry.timing_delay
                            original_distance = entry.original_distance
                            note_value = entry.note_value
                            source_instrument_index = entry.source_instrument_index or instrument_index
                        end
                        
                        -- Validate essential fields
                        if slice_index and timing_line and timing_delay and original_distance then
                            -- Create comprehensive timing entry
                            local timing_entry = {
                                instrument_value = slice_index,
                                relative_line = timing_line,
                                new_delay = timing_delay,
                                original_distance = original_distance,
                                source_instrument_index = source_instrument_index
                            }
                            
                            -- For range-captured symbols, ensure proper instrument value handling
                            if symbol_type == "range_captured" then
                                -- slice_index should contain the 0-based instrument value for range symbols
                                -- Ensure source_instrument_index is correctly set (1-based)
                                if not is_legacy_format and entry.instrument_value and entry.source_instrument_index then
                                    -- New format: instrument_value is the 0-based instrument, source_instrument_index is 1-based
                                    timing_entry.instrument_value = entry.instrument_value
                                    timing_entry.source_instrument_index = entry.source_instrument_index
                                else
                                    -- Legacy or converted: slice_index contains 0-based instrument value
                                    timing_entry.source_instrument_index = slice_index + 1
                                end
                            end
                            
                            -- Add note_value if present
                            if note_value then
                                timing_entry.note_value = note_value
                            end
                            
                            -- Add additional properties if they exist
                            if entry.volume_value then
                                timing_entry.volume_value = entry.volume_value
                            end
                            if entry.panning_value then
                                timing_entry.panning_value = entry.panning_value
                            end
                            if entry.effect_number_value then
                                timing_entry.effect_number_value = entry.effect_number_value
                            end
                            if entry.effect_amount_value then
                                timing_entry.effect_amount_value = entry.effect_amount_value
                            end
                            if entry.effect_columns then
                                timing_entry.effect_columns = entry.effect_columns
                            end
                            if entry.note_columns then
                                timing_entry.note_columns = entry.note_columns
                            end
                            
                            -- Add enhanced content information
                            timing_entry.has_note = entry.has_note or false
                            timing_entry.content_type = entry.content_type or "note"
                            
                            -- Phase 5: Add multi-track information
                            if entry.track_index then
                                timing_entry.track_index = entry.track_index
                            end
                            timing_entry.track_offset = entry.track_offset or 0
                            
                            table.insert(timing_data, timing_entry)
                            
                            -- Create note entry
                            local note_entry = {
                                line = timing_line,
                                instrument_value = slice_index,
                                delay_value = timing_delay,
                                distance = original_distance,
                                is_last = false
                            }
                            
                            -- Set note_value based on symbol type and available data
                            if symbol_type == "range_captured" and note_value then
                                note_entry.note_value = note_value
                            else
                                note_entry.note_value = 48  -- C-4 default for breakpoint symbols
                            end
                            
                            -- Add note columns data if available
                            if entry.note_columns then
                                note_entry.note_columns = entry.note_columns
                            end
                            
                            table.insert(notes, note_entry)
                            
                            -- Add label data for breakpoint symbols
                            if symbol_type == "breakpoint_created" then
                                local hex_key = string.format("%02X", slice_index + 1)
                                saved_labels[hex_key] = {
                                    label = entry.label or "",
                                    breakpoint = entry.breakpoint or false,
                                    instrument_index = instrument_index
                                }
                            end
                        end
                    end
                end
            end
            
            -- Extract saved_labels if provided (for new format)
            if not is_legacy_format and symbol_data.saved_labels and type(symbol_data.saved_labels) == "table" then
                saved_labels = symbol_data.saved_labels
            end
            
            -- Extract source_metadata for range-captured symbols
            -- Phase 5: Include multi-track metadata
            if symbol_type == "range_captured" and symbol_data.source_metadata and type(symbol_data.source_metadata) == "table" then
                source_metadata = {
                    pattern_index = symbol_data.source_metadata.pattern_index,
                    track_index = symbol_data.source_metadata.track_index,
                    capture_info = symbol_data.source_metadata.capture_info,
                    -- Phase 5: Multi-track metadata
                    track_count = symbol_data.source_metadata.track_count,
                    first_track_index = symbol_data.source_metadata.first_track_index,
                    track_names = symbol_data.source_metadata.track_names,
                    is_multi_track = symbol_data.source_metadata.is_multi_track
                }
            end
            
            if #timing_data > 0 then
                -- Create break_set structure
                local break_set = {
                    timing = timing_data,
                    notes = notes,
                    start_line = 1,
                    end_line = 64  -- Default values
                }
                
                -- Adjust end_line based on actual content
                if #notes > 0 then
                    local last_note = notes[#notes]
                    local distance_in_lines = math.floor(last_note.distance / 256)
                    break_set.end_line = last_note.line + distance_in_lines + 4 -- Add buffer
                end
                
                -- Phase 5: Add multi-track metadata to break_set
                if symbol_data.track_count then
                    break_set.track_count = symbol_data.track_count
                end
                if symbol_data.first_track_index then
                    break_set.first_track_index = symbol_data.first_track_index
                end
                if symbol_data.track_names then
                    break_set.track_names = symbol_data.track_names
                end
                if symbol_data.is_multi_track then
                    break_set.is_multi_track = symbol_data.is_multi_track
                end
                
                -- Create registry entry with proper structure
                local registry_entry = {
                    instrument_index = instrument_index,
                    break_set = break_set,
                    saved_labels = saved_labels,
                    tags = tags,  -- Store tags array
                    color = color
                }
                
                -- Add symbol type and source metadata for range-captured symbols
                if symbol_type == "range_captured" then
                    registry_entry.symbol_type = "range_captured"
                    if source_metadata then
                        registry_entry.source_metadata = source_metadata
                    end
                end
                
                -- Update global registry
                global_symbol_registry[symbol:upper()] = registry_entry
                
                -- Phase 4: Assign to dictionary if specified
                if dictionary and dictionary ~= "" then
                    -- Create dictionary if it doesn't exist
                    if not symbol_dictionaries[dictionary] then
                        create_dictionary(dictionary, "", "")
                    end
                    add_symbol_to_dictionary(symbol:upper(), dictionary)
                end
                
                imported_count = imported_count + 1
            end
        end
    end
    
    if imported_count == 0 then
        renoise.app():show_warning("No valid symbol data found in JSON file")
        return
    end
    
    -- Phase 4: Import dictionaries if present
    local dict_count = 0
    if import_data.dictionaries and type(import_data.dictionaries) == "table" then
        for dict_name, dict_data in pairs(import_data.dictionaries) do
            if type(dict_data) == "table" then
                -- Create or update dictionary
                if not symbol_dictionaries[dict_name] then
                    symbol_dictionaries[dict_name] = {
                        name = dict_name,
                        color = dict_data.color or "",
                        symbols = {},  -- Symbols are assigned via symbol import
                        created_at = dict_data.created_at or os.time(),
                        description = dict_data.description or ""
                    }
                else
                    -- Update existing dictionary properties
                    symbol_dictionaries[dict_name].color = dict_data.color or symbol_dictionaries[dict_name].color
                    symbol_dictionaries[dict_name].description = dict_data.description or symbol_dictionaries[dict_name].description
                end
                dict_count = dict_count + 1
            end
        end
        if dict_count > 0 then
            save_dictionaries()
            print("DEBUG: Imported " .. dict_count .. " dictionaries from JSON")
        end
    end
    
    -- Save to preferences
    save_global_symbol_registry()
    
    local status_msg = string.format("Imported %d symbols", imported_count)
    if dict_count > 0 then
        status_msg = status_msg .. string.format(" and %d dictionaries", dict_count)
    end
    status_msg = status_msg .. " from JSON"
    renoise.app():show_status(status_msg)
    
    -- Refresh main dialog if open
    if dialog and dialog.visible then
        -- Preserve all unsaved tag inputs before refresh
        if current_dialog_vb then
            preserve_unsaved_tag_inputs(nil, current_dialog_vb)
        end
        dialog:close()
        show_main_dialog()
    end
end

-- Show format selection dialog for import
function import_global_alphabet()
    local vb = renoise.ViewBuilder()
    local format_dialog = nil  -- Declare upfront
    
    local dialog_content = vb:column {
        margin = 10,
        spacing = 10,
        
        vb:text {
            text = "Import Global Alphabet",
            font = "big",
            style = "strong"
        },
        
        vb:text {
            text = "Choose import format:",
            style = "strong"
        },
        
        vb:row {
            spacing = 10,
            
            vb:button {
                text = "CSV",
                width = 80,
                notifier = function()
                    if format_dialog then format_dialog:close() end
                    import_global_alphabet_csv()
                end
            },
            
            vb:button {
                text = "JSON",
                width = 80,
                notifier = function()
                    if format_dialog then format_dialog:close() end
                    import_global_alphabet_json()
                end
            },
            
            vb:button {
                text = "Cancel",
                width = 80,
                notifier = function()
                    if format_dialog then format_dialog:close() end
                end
            }
        }
    }
    
    format_dialog = renoise.app():show_custom_dialog("Import Format", dialog_content)
end

-- Safe song access function
local function safe_song_access(callback)
    if renoise.song() then
        return callback()
    else
        renoise.app():show_warning("Song not available")
        return nil
    end
end

-- Create compact overflow behavior section
local function create_compact_overflow_section(vb)
    return vb:column {
        style = "group",
        margin = 5,
        width = 60,
        vb:text {
            text = "OF",
            font = "bold",
            style = "strong"
        },
        vb:space { height = 3 },
        vb:row {
            spacing = 5,
            vb:checkbox {
                id = "compact_overflow_extend",
                value = (current_overflow_behavior == overflow_behavior.EXTEND),
                notifier = function(value)
                    if value then
                        current_overflow_behavior = overflow_behavior.EXTEND
                        -- Uncheck other options
                        vb.views.compact_overflow_next_pattern.value = false
                        vb.views.compact_overflow_truncate.value = false
                        vb.views.compact_overflow_loop.value = false
                        vb.views.compact_overflow_insert.value = false
                    end
                end
            },
            vb:text { text = "E", width = 15 }
        },
        vb:row {
            spacing = 5,
            vb:checkbox {
                id = "compact_overflow_next_pattern",
                value = (current_overflow_behavior == overflow_behavior.NEXT_PATTERN),
                notifier = function(value)
                    if value then
                        current_overflow_behavior = overflow_behavior.NEXT_PATTERN
                        -- Uncheck other options
                        vb.views.compact_overflow_extend.value = false
                        vb.views.compact_overflow_truncate.value = false
                        vb.views.compact_overflow_loop.value = false
                        vb.views.compact_overflow_insert.value = false
                    end
                end
            },
            vb:text { text = "N", width = 15 }
        },
        vb:row {
            spacing = 5,
            vb:checkbox {
                id = "compact_overflow_truncate",
                value = (current_overflow_behavior == overflow_behavior.TRUNCATE),
                notifier = function(value)
                    if value then
                        current_overflow_behavior = overflow_behavior.TRUNCATE
                        -- Uncheck other options
                        vb.views.compact_overflow_extend.value = false
                        vb.views.compact_overflow_next_pattern.value = false
                        vb.views.compact_overflow_loop.value = false
                        vb.views.compact_overflow_insert.value = false
                    end
                end
            },
            vb:text { text = "T", width = 15 }
        },
        vb:row {
            spacing = 5,
            vb:checkbox {
                id = "compact_overflow_loop",
                value = (current_overflow_behavior == overflow_behavior.LOOP),
                notifier = function(value)
                    if value then
                        current_overflow_behavior = overflow_behavior.LOOP
                        -- Uncheck other options
                        vb.views.compact_overflow_extend.value = false
                        vb.views.compact_overflow_next_pattern.value = false
                        vb.views.compact_overflow_truncate.value = false
                        vb.views.compact_overflow_insert.value = false
                    end
                end
            },
            vb:text { text = "L", width = 15 }
        },
        vb:row {
            spacing = 5,
            vb:checkbox {
                id = "compact_overflow_insert",
                value = (current_overflow_behavior == overflow_behavior.INSERT),
                notifier = function(value)
                    if value then
                        current_overflow_behavior = overflow_behavior.INSERT
                        -- Uncheck other options
                        vb.views.compact_overflow_extend.value = false
                        vb.views.compact_overflow_next_pattern.value = false
                        vb.views.compact_overflow_truncate.value = false
                        vb.views.compact_overflow_loop.value = false
                    end
                end
            },
            vb:text { text = "I", width = 15 }
        }
    }
end

-- Create compact overwrite behavior section
local function create_compact_overwrite_section(vb)
    return vb:column {
        style = "group",
        margin = 5,
        width = 60,
        vb:text {
            text = "OB",
            font = "bold",
            style = "strong"
        },
        vb:space { height = 3 },
        vb:row {
            spacing = 5,
            vb:checkbox {
                id = "compact_overwrite_sum",
                value = (current_overwrite_behavior == overwrite_behavior.SUM),
                notifier = function(value)
                    if value then
                        current_overwrite_behavior = overwrite_behavior.SUM
                        -- Uncheck other options
                        vb.views.compact_overwrite_replace.value = false
                        vb.views.compact_overwrite_substitute.value = false
                        vb.views.compact_overwrite_retain.value = false
                        vb.views.compact_overwrite_exclude.value = false
                        vb.views.compact_overwrite_intersect.value = false
                    elseif current_overwrite_behavior == overwrite_behavior.SUM then
                        vb.views.compact_overwrite_sum.value = true
                    end
                end
            },
            vb:text { text = "+", width = 15 }
        },
        vb:row {
            spacing = 5,
            vb:checkbox {
                id = "compact_overwrite_replace",
                value = (current_overwrite_behavior == overwrite_behavior.REPLACE),
                notifier = function(value)
                    if value then
                        current_overwrite_behavior = overwrite_behavior.REPLACE
                        -- Uncheck other options
                        vb.views.compact_overwrite_sum.value = false
                        vb.views.compact_overwrite_substitute.value = false
                        vb.views.compact_overwrite_retain.value = false
                        vb.views.compact_overwrite_exclude.value = false
                        vb.views.compact_overwrite_intersect.value = false
                    elseif current_overwrite_behavior == overwrite_behavior.REPLACE then
                        vb.views.compact_overwrite_replace.value = true
                    end
                end
            },
            vb:text { text = "R", width = 15 }
        },
        vb:row {
            spacing = 5,
            vb:checkbox {
                id = "compact_overwrite_substitute",
                value = (current_overwrite_behavior == overwrite_behavior.SUBSTITUTE),
                notifier = function(value)
                    if value then
                        current_overwrite_behavior = overwrite_behavior.SUBSTITUTE
                        -- Uncheck other options
                        vb.views.compact_overwrite_sum.value = false
                        vb.views.compact_overwrite_replace.value = false
                        vb.views.compact_overwrite_retain.value = false
                        vb.views.compact_overwrite_exclude.value = false
                        vb.views.compact_overwrite_intersect.value = false
                    elseif current_overwrite_behavior == overwrite_behavior.SUBSTITUTE then
                        vb.views.compact_overwrite_substitute.value = true
                    end
                end
            },
            vb:text { text = "S", width = 15 }
        },
        vb:row {
            spacing = 5,
            vb:checkbox {
                id = "compact_overwrite_retain",
                value = (current_overwrite_behavior == overwrite_behavior.RETAIN),
                notifier = function(value)
                    if value then
                        current_overwrite_behavior = overwrite_behavior.RETAIN
                        -- Uncheck other options
                        vb.views.compact_overwrite_sum.value = false
                        vb.views.compact_overwrite_replace.value = false
                        vb.views.compact_overwrite_substitute.value = false
                        vb.views.compact_overwrite_exclude.value = false
                        vb.views.compact_overwrite_intersect.value = false
                    elseif current_overwrite_behavior == overwrite_behavior.RETAIN then
                        vb.views.compact_overwrite_retain.value = true
                    end
                end
            },
            vb:text { text = "T", width = 15 }
        },
        vb:row {
            spacing = 5,
            vb:checkbox {
                id = "compact_overwrite_exclude",
                value = (current_overwrite_behavior == overwrite_behavior.EXCLUDE),
                notifier = function(value)
                    if value then
                        current_overwrite_behavior = overwrite_behavior.EXCLUDE
                        -- Uncheck other options
                        vb.views.compact_overwrite_sum.value = false
                        vb.views.compact_overwrite_replace.value = false
                        vb.views.compact_overwrite_substitute.value = false
                        vb.views.compact_overwrite_retain.value = false
                        vb.views.compact_overwrite_intersect.value = false
                    elseif current_overwrite_behavior == overwrite_behavior.EXCLUDE then
                        vb.views.compact_overwrite_exclude.value = true
                    end
                end
            },
            vb:text { text = "E", width = 15 }
        },
        vb:row {
            spacing = 5,
            vb:checkbox {
                id = "compact_overwrite_intersect",
                value = (current_overwrite_behavior == overwrite_behavior.INTERSECT),
                notifier = function(value)
                    if value then
                        current_overwrite_behavior = overwrite_behavior.INTERSECT
                        -- Uncheck other options
                        vb.views.compact_overwrite_sum.value = false
                        vb.views.compact_overwrite_replace.value = false
                        vb.views.compact_overwrite_substitute.value = false
                        vb.views.compact_overwrite_retain.value = false
                        vb.views.compact_overwrite_exclude.value = false
                    elseif current_overwrite_behavior == overwrite_behavior.INTERSECT then
                        vb.views.compact_overwrite_intersect.value = true
                    end
                end
            },
            vb:text { text = "I", width = 15 }
        }
    }
end

-- Create compact instrument source behavior section
local function create_compact_instrument_source_section(vb)
    return vb:column {
        style = "group",
        margin = 5,
        width = 60,
        vb:text {
            text = "IS",
            font = "bold",
            style = "strong"
        },
        vb:space { height = 3 },
        vb:row {
            spacing = 5,
            vb:checkbox {
                id = "compact_instrument_source_embedded",
                value = (current_instrument_source_behavior == instrument_source_behavior.EMBEDDED),
                notifier = function(value)
                    if value then
                        current_instrument_source_behavior = instrument_source_behavior.EMBEDDED
                        -- Uncheck other option
                        vb.views.compact_instrument_source_current.value = false
                    elseif current_instrument_source_behavior == instrument_source_behavior.EMBEDDED then
                        vb.views.compact_instrument_source_embedded.value = true
                    end
                end
            },
            vb:text { text = "E", width = 15 }
        },
        vb:row {
            spacing = 5,
            vb:checkbox {
                id = "compact_instrument_source_current",
                value = (current_instrument_source_behavior == instrument_source_behavior.CURRENT_SELECTED),
                notifier = function(value)
                    if value then
                        current_instrument_source_behavior = instrument_source_behavior.CURRENT_SELECTED
                        -- Uncheck other option
                        vb.views.compact_instrument_source_embedded.value = false
                    elseif current_instrument_source_behavior == instrument_source_behavior.CURRENT_SELECTED then
                        vb.views.compact_instrument_source_current.value = true
                    end
                end
            },
            vb:text { text = "C", width = 15 }
        }
    }
end

-- Phase 5: Create compact multi-track distance section for collapsed view
local function create_compact_multi_track_distance_section(vb)
    return vb:column {
        style = "group",
        margin = 5,
        width = 60,
        vb:text {
            text = "MT",
            font = "bold",
            style = "strong",
            tooltip = "Multi-Track Distance Mode"
        },
        vb:space { height = 3 },
        vb:row {
            spacing = 5,
            vb:checkbox {
                id = "compact_mt_sync_first",
                value = (current_multi_track_distance_mode == multi_track_distance_mode.SYNC_FIRST),
                notifier = function(value)
                    if value then
                        current_multi_track_distance_mode = multi_track_distance_mode.SYNC_FIRST
                        vb.views.compact_mt_independent.value = false
                        vb.views.compact_mt_sync_last.value = false
                    elseif current_multi_track_distance_mode == multi_track_distance_mode.SYNC_FIRST then
                        vb.views.compact_mt_sync_first.value = true
                    end
                end
            },
            vb:text { text = "1", width = 10, tooltip = "Sync to First" }
        },
        vb:row {
            spacing = 5,
            vb:checkbox {
                id = "compact_mt_independent",
                value = (current_multi_track_distance_mode == multi_track_distance_mode.INDEPENDENT),
                notifier = function(value)
                    if value then
                        current_multi_track_distance_mode = multi_track_distance_mode.INDEPENDENT
                        vb.views.compact_mt_sync_first.value = false
                        vb.views.compact_mt_sync_last.value = false
                    elseif current_multi_track_distance_mode == multi_track_distance_mode.INDEPENDENT then
                        vb.views.compact_mt_independent.value = true
                    end
                end
            },
            vb:text { text = "I", width = 10, tooltip = "Independent" }
        },
        vb:row {
            spacing = 5,
            vb:checkbox {
                id = "compact_mt_sync_last",
                value = (current_multi_track_distance_mode == multi_track_distance_mode.SYNC_LAST),
                notifier = function(value)
                    if value then
                        current_multi_track_distance_mode = multi_track_distance_mode.SYNC_LAST
                        vb.views.compact_mt_sync_first.value = false
                        vb.views.compact_mt_independent.value = false
                    elseif current_multi_track_distance_mode == multi_track_distance_mode.SYNC_LAST then
                        vb.views.compact_mt_sync_last.value = true
                    end
                end
            },
            vb:text { text = "L", width = 10, tooltip = "Sync to Last" }
        }
    }
end

-- Toggle UI collapse state
local function toggle_ui_collapse(vb)
    ui_collapsed = not ui_collapsed
    
    -- Update collapse button text to use +/- like the right column
    if vb.views.collapse_button then
        vb.views.collapse_button.text = ui_collapsed and "+" or "-"
    end
    
    -- Toggle visibility of collapsible elements
    if vb.views.header_controls then
        vb.views.header_controls.visible = not ui_collapsed
    end
    if vb.views.full_behaviors_section then
        vb.views.full_behaviors_section.visible = not ui_collapsed
    end
    if vb.views.instrument_source_section then
        vb.views.instrument_source_section.visible = not ui_collapsed
    end
    if vb.views.multi_track_distance_section then
        vb.views.multi_track_distance_section.visible = not ui_collapsed
    end
    if vb.views.break_composite_row then
        vb.views.break_composite_row.visible = not ui_collapsed
    end
    if vb.views.compact_behaviors_section then
        vb.views.compact_behaviors_section.visible = ui_collapsed
    end
    if vb.views.action_buttons then
        vb.views.action_buttons.visible = not ui_collapsed
    end
end

-- Navigate to previous page
local function prev_symbol_page(dialog_vb)
    local all_symbols = {"A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9"}
    local total_pages = math.ceil(#all_symbols / symbol_pagination.symbols_per_page)
    
    if symbol_pagination.current_page > 1 then
        symbol_pagination.current_page = symbol_pagination.current_page - 1
        print("DEBUG: Going to page " .. symbol_pagination.current_page .. " of " .. total_pages)
        -- Recreate dialog to show new page
        if dialog and dialog.visible then
            dialog:close()
            show_main_dialog()
        end
    end
end

-- Navigate to next page
local function next_symbol_page(dialog_vb)
    local all_symbols = {"A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9"}
    local total_pages = math.ceil(#all_symbols / symbol_pagination.symbols_per_page)
    
    if symbol_pagination.current_page < total_pages then
        symbol_pagination.current_page = symbol_pagination.current_page + 1
        print("DEBUG: Going to page " .. symbol_pagination.current_page .. " of " .. total_pages)
        -- Recreate dialog to show new page
        if dialog and dialog.visible then
            dialog:close()
            show_main_dialog()
        end
    end
end

-- Get only symbols that are mapped in the global registry
local function get_mapped_symbols()
    local mapped = {}
    local all_symbols = {"A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9"}
    
    for _, symbol in ipairs(all_symbols) do
        if global_symbol_registry[symbol] then
            table.insert(mapped, symbol)
        end
    end
    
    return mapped
end

-- Calculate the full right column width based on active view modes
local function calculate_right_column_width()
    local base_grid_width = 500
    local width_padding = 0
    if category_view_enabled then width_padding = width_padding + 15 end
    if organize_view_enabled then width_padding = width_padding + 15 end
    if detailed_view_enabled then width_padding = width_padding + 10 end
    -- Note: dictionary_view does NOT add to per-symbol padding
    local final_width = base_grid_width + (width_padding * 4)
    -- Add extra container space for dictionary view (not per-symbol)
    if dictionary_view_enabled then
        final_width = final_width + 40  -- Extra container padding for dictionary elements
    end
    -- Add extra width for the single expanded symbol's detail box
    if detailed_view_enabled and expanded_symbol then
        final_width = final_width + 80  -- Extra width for one expanded detail box
    end
    print("DEBUG: calculate_right_column_width() -> " .. final_width .. " (padding=" .. width_padding .. ", tag=" .. tostring(category_view_enabled) .. ", org=" .. tostring(organize_view_enabled) .. ", info=" .. tostring(detailed_view_enabled) .. ", expanded=" .. tostring(expanded_symbol) .. ", dict=" .. tostring(dictionary_view_enabled) .. ")")
    return final_width
end

-- Toggle right column collapse state
local function toggle_right_column_collapse(vb)
    right_column_collapsed = not right_column_collapsed
    
    -- Update collapse button text
    if vb.views.right_collapse_button then
        vb.views.right_collapse_button.text = right_column_collapsed and "+" or "-"
    end
    
    -- Toggle visibility of view mode toggles (hidden when collapsed)
    if vb.views.view_toggles_row then
        vb.views.view_toggles_row.visible = not right_column_collapsed
    end
    
    -- Toggle visibility of collapsible elements
    if vb.views.right_full_content then
        vb.views.right_full_content.visible = not right_column_collapsed
    end
    if vb.views.right_compact_content then
        vb.views.right_compact_content.visible = right_column_collapsed
    end
    
    -- Update the width of the right column container
    if vb.views.right_column_container then
        if right_column_collapsed then
            -- Calculate compact width
            local mapped_symbols = get_mapped_symbols()
            local button_width = 30
            local button_spacing = 3
            local buttons_per_row = math.min(4, #mapped_symbols > 0 and #mapped_symbols or 1)
            local calculated_width = (button_width * buttons_per_row) + (button_spacing * (buttons_per_row - 1)) + 40 -- +40 for margin/padding
            local compact_width = math.max(calculated_width, 140) -- Minimum width for collapse button and text
            vb.views.right_column_container.width = compact_width
        else
            -- Restore full width based on active view modes
            vb.views.right_column_container.width = calculate_right_column_width()
        end
    end
end

-- Create compact right column content (only mapped symbols)
local function create_compact_right_column(vb)
    local mapped_symbols = get_mapped_symbols()
    
    local compact_content = vb:column {
        spacing = 5,
        
        -- Compact symbol buttons (only mapped ones)
        vb:column {
            spacing = 3,
            vb:text {
                text = "Symbols (" .. #mapped_symbols .. ")",
                font = "bold",
                style = "strong",
                align = "center"
            },
            vb:space { height = 5 }
        }
    }
    
    -- Add symbol buttons in compact rows (4 per row max)
    if #mapped_symbols > 0 then
        local buttons_per_row = 4
        local current_row = nil
        local button_width = 30
        local button_spacing = 3
        
        for i, symbol in ipairs(mapped_symbols) do
            -- Start new row every 4 buttons
            if (i - 1) % buttons_per_row == 0 then
                current_row = vb:row {
                    spacing = button_spacing
                }
                compact_content:add_child(current_row)
            end
            
            -- Create a column for each symbol to hold color bar + button
            local symbol_col = vb:column {
                spacing = 0
            }
            
            -- Add dictionary color bar if symbol has a dictionary
            local symbol_dictionary = get_dictionary_for_symbol(symbol)
            if symbol_dictionary then
                local dict_data = get_dictionary_data(symbol_dictionary)
                local dict_color = dict_data and dict_data.color or ""
                
                if dict_color and dict_color ~= "" and color_definitions[dict_color] then
                    local bar_color = color_definitions[dict_color].original
                    symbol_col:add_child(vb:canvas {
                        width = button_width,
                        height = 3,
                        mode = "plain",
                        render = function(ctx)
                            ctx.fill_color = bar_color
                            ctx:fill_rect(0, 0, ctx.size.width, ctx.size.height)
                        end
                    })
                else
                    -- Dictionary exists but no color - add subtle indicator
                    symbol_col:add_child(vb:space { height = 3 })
                end
            else
                -- No dictionary - add space for alignment
                symbol_col:add_child(vb:space { height = 3 })
            end
            
            local symbol_button = vb:button {
                text = symbol,
                width = button_width,
                height = 25,
                notifier = function()
                    editor.place_symbol(symbol)
                end
            }
            
            -- Store reference for visual feedback
            symbol_button_refs[symbol] = symbol_button
            
            -- Apply color if symbol has one
            local symbol_color = get_symbol_color(symbol)
            if symbol_color and symbol_color ~= "" and color_definitions[symbol_color] then
                symbol_button.color = color_definitions[symbol_color].darker
            end
            
            symbol_col:add_child(symbol_button)
            current_row:add_child(symbol_col)
        end
    else
        compact_content:add_child(
            vb:text {
                text = "No symbols",
                style = "disabled",
                align = "center"
            }
        )
    end
    
    -- Add compact input lock indicator
    compact_content:add_child(vb:space { height = 10 })
    compact_content:add_child(
        vb:horizontal_aligner {
            mode = "center",
            vb:text {
                id = "compact_input_lock_indicator",
                text = input_lock_active and "[-]" or "[O]",
                font = "bold",
                style = input_lock_active and "strong" or "normal"
            }
        }
    )
    
    return compact_content
end

-- Helper function for table operations
function table.find(t, value)
    for i, v in ipairs(t) do
        if v == value then return i end
    end
    return nil
end

-- Register keybinding entries for user assignment (unchanged)
local function register_keybinding_entries()
    -- Direct symbol placement A-T
    renoise.tool():add_keybinding {
        name = "Global:Tools:Insert Symbol A",
        invoke = function() editor.place_symbol("A") end
    }
    renoise.tool():add_keybinding {
        name = "Global:Tools:Insert Symbol B", 
        invoke = function() editor.place_symbol("B") end
    }
    renoise.tool():add_keybinding {
        name = "Global:Tools:Insert Symbol C",
        invoke = function() editor.place_symbol("C") end
    }
    renoise.tool():add_keybinding {
        name = "Global:Tools:Insert Symbol D",
        invoke = function() editor.place_symbol("D") end
    }
    renoise.tool():add_keybinding {
        name = "Global:Tools:Insert Symbol E",
        invoke = function() editor.place_symbol("E") end
    }
    renoise.tool():add_keybinding {
        name = "Global:Tools:Insert Symbol F",
        invoke = function() editor.place_symbol("F") end
    }
    renoise.tool():add_keybinding {
        name = "Global:Tools:Insert Symbol G",
        invoke = function() editor.place_symbol("G") end
    }
    renoise.tool():add_keybinding {
        name = "Global:Tools:Insert Symbol H",
        invoke = function() editor.place_symbol("H") end
    }
    renoise.tool():add_keybinding {
        name = "Global:Tools:Insert Symbol I",
        invoke = function() editor.place_symbol("I") end
    }
    renoise.tool():add_keybinding {
        name = "Global:Tools:Insert Symbol J",
        invoke = function() editor.place_symbol("J") end
    }
    renoise.tool():add_keybinding {
        name = "Global:Tools:Insert Symbol K",
        invoke = function() editor.place_symbol("K") end
    }
    renoise.tool():add_keybinding {
        name = "Global:Tools:Insert Symbol L",
        invoke = function() editor.place_symbol("L") end
    }
    renoise.tool():add_keybinding {
        name = "Global:Tools:Insert Symbol M",
        invoke = function() editor.place_symbol("M") end
    }
    renoise.tool():add_keybinding {
        name = "Global:Tools:Insert Symbol N",
        invoke = function() editor.place_symbol("N") end
    }
    renoise.tool():add_keybinding {
        name = "Global:Tools:Insert Symbol O",
        invoke = function() editor.place_symbol("O") end
    }
    renoise.tool():add_keybinding {
        name = "Global:Tools:Insert Symbol P",
        invoke = function() editor.place_symbol("P") end
    }
    renoise.tool():add_keybinding {
        name = "Global:Tools:Insert Symbol Q",
        invoke = function() editor.place_symbol("Q") end
    }
    renoise.tool():add_keybinding {
        name = "Global:Tools:Insert Symbol R",
        invoke = function() editor.place_symbol("R") end
    }
    renoise.tool():add_keybinding {
        name = "Global:Tools:Insert Symbol S",
        invoke = function() editor.place_symbol("S") end
    }
    renoise.tool():add_keybinding {
        name = "Global:Tools:Insert Symbol T",
        invoke = function() editor.place_symbol("T") end
    }
    
    -- Direct symbol placement 0-9
    renoise.tool():add_keybinding {
        name = "Global:Tools:Insert Symbol 0",
        invoke = function() editor.place_symbol("0") end
    }
    renoise.tool():add_keybinding {
        name = "Global:Tools:Insert Symbol 1",
        invoke = function() editor.place_symbol("1") end
    }
    renoise.tool():add_keybinding {
        name = "Global:Tools:Insert Symbol 2",
        invoke = function() editor.place_symbol("2") end
    }
    renoise.tool():add_keybinding {
        name = "Global:Tools:Insert Symbol 3",
        invoke = function() editor.place_symbol("3") end
    }
    renoise.tool():add_keybinding {
        name = "Global:Tools:Insert Symbol 4",
        invoke = function() editor.place_symbol("4") end
    }
    renoise.tool():add_keybinding {
        name = "Global:Tools:Insert Symbol 5",
        invoke = function() editor.place_symbol("5") end
    }
    renoise.tool():add_keybinding {
        name = "Global:Tools:Insert Symbol 6",
        invoke = function() editor.place_symbol("6") end
    }
    renoise.tool():add_keybinding {
        name = "Global:Tools:Insert Symbol 7",
        invoke = function() editor.place_symbol("7") end
    }
    renoise.tool():add_keybinding {
        name = "Global:Tools:Insert Symbol 8",
        invoke = function() editor.place_symbol("8") end
    }
    renoise.tool():add_keybinding {
        name = "Global:Tools:Insert Symbol 9",
        invoke = function() editor.place_symbol("9") end
    }
    
    -- Composite symbols U-Z (for break string building)
    renoise.tool():add_keybinding {
        name = "Global:Tools:Insert Composite U",
        invoke = function()
            if dialog and dialog.visible and current_dialog_vb then
                local break_string_view = current_dialog_vb.views.break_string
                if break_string_view then
                    break_string_view.text = break_string_view.text .. "U"
                end
            end
        end
    }
    renoise.tool():add_keybinding {
        name = "Global:Tools:Insert Composite V",
        invoke = function()
            if dialog and dialog.visible and current_dialog_vb then
                local break_string_view = current_dialog_vb.views.break_string
                if break_string_view then
                    break_string_view.text = break_string_view.text .. "V"
                end
            end
        end
    }
    renoise.tool():add_keybinding {
        name = "Global:Tools:Insert Composite W",
        invoke = function()
            if dialog and dialog.visible and current_dialog_vb then
                local break_string_view = current_dialog_vb.views.break_string
                if break_string_view then
                    break_string_view.text = break_string_view.text .. "W"
                end
            end
        end
    }
    renoise.tool():add_keybinding {
        name = "Global:Tools:Insert Composite X",
        invoke = function()
            if dialog and dialog.visible and current_dialog_vb then
                local break_string_view = current_dialog_vb.views.break_string
                if break_string_view then
                    break_string_view.text = break_string_view.text .. "X"
                end
            end
        end
    }
    renoise.tool():add_keybinding {
        name = "Global:Tools:Insert Composite Y",
        invoke = function()
            if dialog and dialog.visible and current_dialog_vb then
                local break_string_view = current_dialog_vb.views.break_string
                if break_string_view then
                    break_string_view.text = break_string_view.text .. "Y"
                end
            end
        end
    }
    renoise.tool():add_keybinding {
        name = "Global:Tools:Insert Composite Z",
        invoke = function()
            if dialog and dialog.visible and current_dialog_vb then
                local break_string_view = current_dialog_vb.views.break_string
                if break_string_view then
                    break_string_view.text = break_string_view.text .. "Z"
                end
            end
        end
    }
    
    -- Capture selection as symbol
    renoise.tool():add_keybinding {
        name = "Pattern Editor:Selection:Capture Selection as BreakFast Symbol",
        invoke = function()
            capture_selection_as_symbol()
        end
    }
    
    -- Phase 2: Stop preview keybinding
    renoise.tool():add_keybinding {
        name = "Global:Tools:BreakFast Stop Preview",
        invoke = function()
            stop_symbol_preview()
        end
    }
    
    -- Phase 2: Add breakpoints from selection keybinding
    renoise.tool():add_keybinding {
        name = "Pattern Editor:Selection:BreakFast Add Breakpoints from Selection",
        invoke = function()
            add_breakpoints_from_selection()
        end
    }
end



-- Main symbol editor dialog creation
local function create_symbol_editor_dialog()
    -- Check if song is available first
    local vb = renoise.ViewBuilder()
    current_dialog_vb = vb  -- Store reference for keybinding access and input lock updates
    
    local song = renoise.song()
    local instrument = song.selected_instrument
    local saved_labels = labeler.get_saved_labels()
        
    -- Get break sets and format labels from global registry
    local break_sets = {}
    local formatted_labels = {}

    -- Prepare formatted labels from global symbol registry
    formatted_labels = syntax.prepare_global_symbol_labels(global_symbol_registry)
    current_formatted_labels = formatted_labels  -- Store at module level for pagination

    -- Check if current instrument has breakpoints defined for legacy compatibility
    local has_breakpoints = false
    for _, label_data in pairs(saved_labels) do
        if label_data.breakpoint then
            has_breakpoints = true
            break
        end
    end

    if has_breakpoints and #instrument.phrases > 0 then
        local original_phrase = instrument.phrases[1]
        break_sets = breakpoints.create_break_patterns(instrument, original_phrase, saved_labels)
    end

    -- Main dialog content
    local dialog_content = vb:column {
        margin = 10,
        spacing = 10,
        
        -- Main content row: Left side (Collapsible) and Right side (Symbol Grid)
        vb:row {
            spacing = 15,
            
            -- Left side: Collapsible sections
            vb:column {
                spacing = 10,
                width = ui_collapsed and 60 or 450,  -- Dynamic width based on collapse state
                
                -- Collapse toggle button
                vb:button {
                    id = "collapse_button",
                    text = ui_collapsed and "+" or "-",  -- Changed from "Expand"/"Collapse"
                    width = 25,  -- Changed from 60 to match right column button size
                    height = 25,
                    notifier = function()
                        toggle_ui_collapse(vb)
                    end
                },
                
                vb:space { height = 5 },
                
                -- Header controls (collapsible)
                vb:row {
                    id = "header_controls",
                    visible = not ui_collapsed,
                    spacing = 10,
                    vb:button {
                        text = "Label Slices",
                        width = 100,
                        notifier = function()
                            labeler.show_dialog()
                        end
                    },
                    vb:button {
                        text = "Import Labels",
                        width = 100,
                        notifier = function()
                            labeler.import_labels()
                            -- Refresh the dialog after import
                            if dialog and dialog.visible then
                                dialog:close()
                                show_main_dialog()
                            end
                        end
                    },
                    vb:button {
                        text = "Export Labels",
                        width = 100,
                        notifier = function()
                            labeler.export_labels()
                        end
                    }
                },

                -- Combined behaviors section (collapsible)
                vb:row {
                    id = "full_behaviors_section",
                    visible = not ui_collapsed,
                    spacing = 15,
                    
                    -- Overflow behavior section
                    vb:column {
                        style = "group",
                        margin = 10,
                        width = 210,
                        vb:text {
                            text = "Overflow Behavior",
                            font = "big",
                            style = "strong"
                        },
                        vb:space { height = 5 },
                        vb:column {
                            spacing = 3,
                            vb:row {
                                spacing = 10,
                                vb:checkbox {
                                    id = "overflow_extend",
                                    value = (current_overflow_behavior == overflow_behavior.EXTEND),
                                    notifier = function(value)
                                        if value then
                                            current_overflow_behavior = overflow_behavior.EXTEND
                                            vb.views.overflow_next_pattern.value = false
                                            vb.views.overflow_truncate.value = false
                                            vb.views.overflow_loop.value = false
                                            vb.views.overflow_insert.value = false
                                        end
                                    end
                                },
                                vb:text {
                                    text = "Extend Pattern",
                                    width = 120
                                }
                            },
                            vb:row {
                                spacing = 10,
                                vb:checkbox {
                                    id = "overflow_next_pattern",
                                    value = (current_overflow_behavior == overflow_behavior.NEXT_PATTERN),
                                    notifier = function(value)
                                        if value then
                                            current_overflow_behavior = overflow_behavior.NEXT_PATTERN
                                            vb.views.overflow_extend.value = false
                                            vb.views.overflow_truncate.value = false
                                            vb.views.overflow_loop.value = false
                                            vb.views.overflow_insert.value = false
                                        end
                                    end
                                },
                                vb:text {
                                    text = "Next Pattern",
                                    width = 120
                                }
                            },
                            vb:row {
                                spacing = 10,
                                vb:checkbox {
                                    id = "overflow_truncate",
                                    value = (current_overflow_behavior == overflow_behavior.TRUNCATE),
                                    notifier = function(value)
                                        if value then
                                            current_overflow_behavior = overflow_behavior.TRUNCATE
                                            vb.views.overflow_extend.value = false
                                            vb.views.overflow_next_pattern.value = false
                                            vb.views.overflow_loop.value = false
                                            vb.views.overflow_insert.value = false
                                        end
                                    end
                                },
                                vb:text {
                                    text = "Truncate",
                                    width = 120
                                }
                            },
                            vb:row {
                                spacing = 10,
                                vb:checkbox {
                                    id = "overflow_loop",
                                    value = (current_overflow_behavior == overflow_behavior.LOOP),
                                    notifier = function(value)
                                        if value then
                                            current_overflow_behavior = overflow_behavior.LOOP
                                            vb.views.overflow_extend.value = false
                                            vb.views.overflow_next_pattern.value = false
                                            vb.views.overflow_truncate.value = false
                                            vb.views.overflow_insert.value = false
                                        end
                                    end
                                },
                                vb:text {
                                    text = "Loop",
                                    width = 120
                                }
                            },
                            vb:row {
                                spacing = 10,
                                vb:checkbox {
                                    id = "overflow_insert",
                                    value = (current_overflow_behavior == overflow_behavior.INSERT),
                                    notifier = function(value)
                                        if value then
                                            current_overflow_behavior = overflow_behavior.INSERT
                                            vb.views.overflow_extend.value = false
                                            vb.views.overflow_next_pattern.value = false
                                            vb.views.overflow_truncate.value = false
                                            vb.views.overflow_loop.value = false
                                        end
                                    end
                                },
                                vb:text {
                                    text = "Insert Pattern",
                                    width = 120
                                }
                            }
                        }
                    },
                    
                    -- Overwrite behavior section
                    vb:column {
                        style = "group",
                        margin = 10,
                        width = 210,
                        vb:text {
                            text = "Overwrite Behavior",
                            font = "big",
                            style = "strong"
                        },
                        vb:space { height = 5 },
                        vb:row {
                            spacing = 10,
                            -- First column
                            vb:column {
                                spacing = 3,
                                vb:row {
                                    spacing = 10,
                                    vb:checkbox {
                                        id = "overwrite_sum",
                                        value = (current_overwrite_behavior == overwrite_behavior.SUM),
                                        notifier = function(value)
                                            if value then
                                                current_overwrite_behavior = overwrite_behavior.SUM
                                                vb.views.overwrite_replace.value = false
                                                vb.views.overwrite_substitute.value = false
                                                vb.views.overwrite_retain.value = false
                                                vb.views.overwrite_exclude.value = false
                                                vb.views.overwrite_intersect.value = false
                                            elseif current_overwrite_behavior == overwrite_behavior.SUM then
                                                vb.views.overwrite_sum.value = true
                                            end
                                        end
                                    },
                                    vb:text {
                                        text = "Sum",
                                        width = 70
                                    }
                                },
                                vb:row {
                                    spacing = 10,
                                    vb:checkbox {
                                        id = "overwrite_replace",
                                        value = (current_overwrite_behavior == overwrite_behavior.REPLACE),
                                        notifier = function(value)
                                            if value then
                                                current_overwrite_behavior = overwrite_behavior.REPLACE
                                                vb.views.overwrite_sum.value = false
                                                vb.views.overwrite_substitute.value = false
                                                vb.views.overwrite_retain.value = false
                                                vb.views.overwrite_exclude.value = false
                                                vb.views.overwrite_intersect.value = false
                                            elseif current_overwrite_behavior == overwrite_behavior.REPLACE then
                                                vb.views.overwrite_replace.value = true
                                            end
                                        end
                                    },
                                    vb:text {
                                        text = "Replace",
                                        width = 70
                                    }
                                },
                                vb:row {
                                    spacing = 10,
                                    vb:checkbox {
                                        id = "overwrite_substitute",
                                        value = (current_overwrite_behavior == overwrite_behavior.SUBSTITUTE),
                                        notifier = function(value)
                                            if value then
                                                current_overwrite_behavior = overwrite_behavior.SUBSTITUTE
                                                vb.views.overwrite_sum.value = false
                                                vb.views.overwrite_replace.value = false
                                                vb.views.overwrite_retain.value = false
                                                vb.views.overwrite_exclude.value = false
                                                vb.views.overwrite_intersect.value = false
                                            elseif current_overwrite_behavior == overwrite_behavior.SUBSTITUTE then
                                                vb.views.overwrite_substitute.value = true
                                            end
                                        end
                                    },
                                    vb:text {
                                        text = "Substitute",
                                        width = 70
                                    }
                                },
                                vb:row {
                                    spacing = 10,
                                    vb:checkbox {
                                        id = "overwrite_retain",
                                        value = (current_overwrite_behavior == overwrite_behavior.RETAIN),
                                        notifier = function(value)
                                            if value then
                                                current_overwrite_behavior = overwrite_behavior.RETAIN
                                                vb.views.overwrite_sum.value = false
                                                vb.views.overwrite_replace.value = false
                                                vb.views.overwrite_substitute.value = false
                                                vb.views.overwrite_exclude.value = false
                                                vb.views.overwrite_intersect.value = false
                                            elseif current_overwrite_behavior == overwrite_behavior.RETAIN then
                                                vb.views.overwrite_retain.value = true
                                            end
                                        end
                                    },
                                    vb:text {
                                        text = "Retain",
                                        width = 70
                                    }
                                }
                            },
                            -- Second column
                            vb:column {
                                spacing = 3,
                                vb:row {
                                    spacing = 10,
                                    vb:checkbox {
                                        id = "overwrite_exclude",
                                        value = (current_overwrite_behavior == overwrite_behavior.EXCLUDE),
                                        notifier = function(value)
                                            if value then
                                                current_overwrite_behavior = overwrite_behavior.EXCLUDE
                                                vb.views.overwrite_sum.value = false
                                                vb.views.overwrite_replace.value = false
                                                vb.views.overwrite_substitute.value = false
                                                vb.views.overwrite_retain.value = false
                                                vb.views.overwrite_intersect.value = false
                                            elseif current_overwrite_behavior == overwrite_behavior.EXCLUDE then
                                                vb.views.overwrite_exclude.value = true
                                            end
                                        end
                                    },
                                    vb:text {
                                        text = "Exclude",
                                        width = 70
                                    }
                                },
                                vb:row {
                                    spacing = 10,
                                    vb:checkbox {
                                        id = "overwrite_intersect",
                                        value = (current_overwrite_behavior == overwrite_behavior.INTERSECT),
                                        notifier = function(value)
                                            if value then
                                                current_overwrite_behavior = overwrite_behavior.INTERSECT
                                                vb.views.overwrite_sum.value = false
                                                vb.views.overwrite_replace.value = false
                                                vb.views.overwrite_substitute.value = false
                                                vb.views.overwrite_retain.value = false
                                                vb.views.overwrite_exclude.value = false
                                            elseif current_overwrite_behavior == overwrite_behavior.INTERSECT then
                                                vb.views.overwrite_intersect.value = true
                                            end
                                        end
                                    },
                                    vb:text {
                                        text = "Intersect",
                                        width = 70
                                    }
                                }
                            }
                        }
                    }
                },

                -- Instrument source behavior section (collapsible)
                vb:column {
                    id = "instrument_source_section",
                    visible = not ui_collapsed,
                    style = "group",
                    margin = 10,
                    width = 430,
                    vb:text {
                        text = "Instrument Source",
                        font = "big",
                        style = "strong"
                    },
                    vb:space { height = 5 },
                    vb:column {
                        spacing = 3,
                        vb:row {
                            spacing = 10,
                            vb:checkbox {
                                id = "instrument_source_embedded",
                                value = (current_instrument_source_behavior == instrument_source_behavior.EMBEDDED),
                                notifier = function(value)
                                    if value then
                                        current_instrument_source_behavior = instrument_source_behavior.EMBEDDED
                                        vb.views.instrument_source_current.value = false
                                    elseif current_instrument_source_behavior == instrument_source_behavior.EMBEDDED then
                                        vb.views.instrument_source_embedded.value = true
                                    end
                                end
                            },
                            vb:text {
                                text = "Use Embedded Instrument (from symbol definition)",
                                width = 350
                            }
                        },
                        vb:row {
                            spacing = 10,
                            vb:checkbox {
                                id = "instrument_source_current",
                                value = (current_instrument_source_behavior == instrument_source_behavior.CURRENT_SELECTED),
                                notifier = function(value)
                                    if value then
                                        current_instrument_source_behavior = instrument_source_behavior.CURRENT_SELECTED
                                        vb.views.instrument_source_embedded.value = false
                                    elseif current_instrument_source_behavior == instrument_source_behavior.CURRENT_SELECTED then
                                        vb.views.instrument_source_current.value = true
                                    end
                                end
                            },
                            vb:text {
                                text = "Use Currently Selected Instrument",
                                width = 350
                            }
                        }
                    }
                },

                -- Phase 5: Multi-track distance mode section (collapsible)
                vb:column {
                    id = "multi_track_distance_section",
                    visible = not ui_collapsed,
                    style = "group",
                    margin = 10,
                    width = 430,
                    vb:text {
                        text = "Multi-Track Capture",
                        font = "big",
                        style = "strong"
                    },
                    vb:space { height = 5 },
                    vb:column {
                        spacing = 3,
                        vb:row {
                            spacing = 10,
                            vb:checkbox {
                                id = "mt_sync_first",
                                value = (current_multi_track_distance_mode == multi_track_distance_mode.SYNC_FIRST),
                                notifier = function(value)
                                    if value then
                                        current_multi_track_distance_mode = multi_track_distance_mode.SYNC_FIRST
                                        vb.views.mt_independent.value = false
                                        vb.views.mt_sync_last.value = false
                                    elseif current_multi_track_distance_mode == multi_track_distance_mode.SYNC_FIRST then
                                        vb.views.mt_sync_first.value = true
                                    end
                                end
                            },
                            vb:text {
                                text = "Sync to First (shortest cutoff distance)",
                                width = 350
                            }
                        },
                        vb:row {
                            spacing = 10,
                            vb:checkbox {
                                id = "mt_independent",
                                value = (current_multi_track_distance_mode == multi_track_distance_mode.INDEPENDENT),
                                notifier = function(value)
                                    if value then
                                        current_multi_track_distance_mode = multi_track_distance_mode.INDEPENDENT
                                        vb.views.mt_sync_first.value = false
                                        vb.views.mt_sync_last.value = false
                                    elseif current_multi_track_distance_mode == multi_track_distance_mode.INDEPENDENT then
                                        vb.views.mt_independent.value = true
                                    end
                                end
                            },
                            vb:text {
                                text = "Independent (each track uses own distance)",
                                width = 350
                            }
                        },
                        vb:row {
                            spacing = 10,
                            vb:checkbox {
                                id = "mt_sync_last",
                                value = (current_multi_track_distance_mode == multi_track_distance_mode.SYNC_LAST),
                                notifier = function(value)
                                    if value then
                                        current_multi_track_distance_mode = multi_track_distance_mode.SYNC_LAST
                                        vb.views.mt_sync_first.value = false
                                        vb.views.mt_independent.value = false
                                    elseif current_multi_track_distance_mode == multi_track_distance_mode.SYNC_LAST then
                                        vb.views.mt_sync_last.value = true
                                    end
                                end
                            },
                            vb:text {
                                text = "Sync to Last (longest cutoff, no extra notes)",
                                width = 350
                            }
                        }
                    }
                },

                -- Break String and Composite Symbols in a row (collapsible)
                vb:row {
                    id = "break_composite_row",
                    visible = not ui_collapsed,
                    spacing = 10,
                    
                    -- Break string input with quick insert buttons
                    vb:column {
                        id = "break_string_section",
                        style = "group",
                        margin = 10,
                        width = 210,
                        vb:text {
                            text = "Break String",
                            font = "big",
                            style = "strong"
                        },
                        vb:space { height = 5 },
                        vb:textfield {
                            id = "break_string",
                            width = 190,
                            height = 25,
                            text = ""
                        },
                        vb:space { height = 5 },
                        vb:row {
                            spacing = 3,
                            vb:text {
                                text = "Insert:",
                                style = "strong"
                            },
                            (function()
                                -- Create quick insert buttons from global registry
                                local available_symbols = {}
                                for symbol, _ in pairs(current_formatted_labels) do
                                    table.insert(available_symbols, symbol)
                                end
                                table.sort(available_symbols)
                                
                                if #available_symbols > 0 then
                                    return vb:row {
                                        spacing = 2,
                                        unpack((function()
                                            local buttons = {}
                                            for i = 1, math.min(#available_symbols, 6) do
                                                local symbol_letter = available_symbols[i]
                                                table.insert(buttons, vb:button {
                                                    text = symbol_letter,
                                                    width = 22,
                                                    height = 20,
                                                    notifier = function()
                                                        local break_string_view = vb.views.break_string
                                                        if break_string_view then
                                                            break_string_view.text = break_string_view.text .. symbol_letter
                                                        end
                                                    end
                                                })
                                            end
                                            return buttons
                                        end)())
                                    }
                                else
                                    return vb:text {
                                        text = "None",
                                        style = "disabled"
                                    }
                                end
                            end)()
                        }
                    },

                    -- Composite symbols section
                    vb:column {
                        id = "composite_symbols_section",
                        style = "group",
                        margin = 10,
                        width = 210,
                        vb:text {
                            text = "Composite Symbols",
                            font = "big",
                            style = "strong"
                        },
                        vb:space { height = 5 },
                        vb:column {
                            id = "composite_symbols",
                            spacing = 3
                        },
                        vb:button {
                            id = "add_symbol_button",
                            text = "+",
                            width = 25,
                            height = 25,
                            notifier = function()
                                add_composite_symbol(vb)
                            end
                        }
                    }
                },

                -- Compact behaviors section (only visible when collapsed)
                vb:column {
                    id = "compact_behaviors_section",
                    visible = ui_collapsed,
                    spacing = 10,
                    create_compact_overflow_section(vb),
                    create_compact_overwrite_section(vb),
                    create_compact_instrument_source_section(vb),
                    create_compact_multi_track_distance_section(vb)
                }
            },
            
            -- Right side: Symbol Grid
            vb:column {
                id = "right_column_container",
                style = "group",
                margin = 10,
                width = calculate_right_column_width(),

                
                -- Right column header with view toggles and collapse button
                vb:row {
                    spacing = 3,
                    
                    -- View mode toggles group (hidden when collapsed - modes require full view to work)
                    vb:row {
                        id = "view_toggles_row",
                        visible = not right_column_collapsed,
                        spacing = 2,
                        vb:text {
                            text = "View:",
                            style = "disabled",
                            width = 32
                        },
                        vb:button {
                            id = "category_toggle",
                            text = category_view_enabled and "Tag*" or "Tag",
                            width = 35,
                            height = 22,
                            tooltip = "Toggle tag editing view - add/edit tags for symbols",
                            notifier = function()
                                toggle_tag_view(vb)
                            end
                        },
                        vb:button {
                            id = "organize_toggle",
                            text = organize_view_enabled and "Org*" or "Org",
                            width = 35,
                            height = 22,
                            tooltip = "Toggle organize view - move, delete, assign dictionaries",
                            notifier = function()
                                toggle_organize_view(vb)
                            end
                        },
                        vb:button {
                            id = "detailed_toggle",
                            text = detailed_view_enabled and "Info*" or "Info",
                            width = 35,
                            height = 22,
                            tooltip = "Toggle detailed view - click symbols to expand details",
                            notifier = function()
                                toggle_detailed_view(vb)
                            end
                        },
                        vb:button {
                            id = "dictionary_toggle",
                            text = dictionary_view_enabled and "Dict*" or "Dict",
                            width = 35,
                            height = 22,
                            tooltip = "Toggle dictionary view - group symbols by dictionary",
                            notifier = function()
                                toggle_dictionary_view_ui(vb)
                            end
                        }
                    },
                    
                    -- Collapse button aligned right
                    vb:horizontal_aligner {
                        mode = "right",
                        vb:button {
                            id = "right_collapse_button",
                            text = right_column_collapsed and "+" or "-",
                            width = 25,
                            height = 22,
                            tooltip = right_column_collapsed and "Expand symbol grid" or "Collapse symbol grid",
                            notifier = function()
                                toggle_right_column_collapse(vb)
                            end
                        }
                    }
                },
                
                vb:space { height = 5 },
                
                -- Full right column content (visible when not collapsed)
                vb:column {
                    id = "right_full_content",
                    visible = not right_column_collapsed,
                    spacing = 10,
                    
                    -- Clear All Symbols button
                    vb:horizontal_aligner {
                        mode = "right",
                        vb:button {
                            text = "Clear All Symbols",
                            width = 120,
                            notifier = function()
                                local result = renoise.app():show_prompt("Clear All Symbols", 
                                    "This will permanently clear all symbol assignments from the global registry.\n\nAre you sure you want to continue?", 
                                    {"Clear All", "Cancel"})
                                
                                if result == "Clear All" then
                                    -- Preserve unsaved tag inputs before clearing
                                    if current_dialog_vb then
                                        preserve_unsaved_tag_inputs(nil, current_dialog_vb)
                                    end
                                    clear_all_symbols()
                                end
                            end
                        }
                    },
                    
                    vb:text {
                        text = "Symbols",
                        font = "big",
                        style = "strong"
                    },
                    
                    -- Pagination controls
                    vb:row {
                        spacing = 10,
                        vb:button {
                            id = "prev_page_btn",
                            text = "<< Prev",
                            width = 80,
                            active = (function()
                                local all_symbols = {"A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9"}
                                local total_pages = math.ceil(#all_symbols / symbol_pagination.symbols_per_page)
                                return symbol_pagination.current_page > 1
                            end)(),
                            notifier = function()
                                prev_symbol_page(vb)
                            end
                        },
                        vb:text {
                            id = "page_info",
                            text = (function()
                                local all_symbols = {"A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9"}
                                local total_pages = math.ceil(#all_symbols / symbol_pagination.symbols_per_page)
                                return string.format("Page %d of %d", symbol_pagination.current_page, total_pages)
                            end)(),
                            width = 100,
                            align = "center",
                            font = "bold"
                        },
                        vb:button {
                            id = "next_page_btn",
                            text = "Next >>",
                            width = 80,
                            active = (function()
                                local all_symbols = {"A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9"}
                                local total_pages = math.ceil(#all_symbols / symbol_pagination.symbols_per_page)
                                return symbol_pagination.current_page < total_pages
                            end)(),
                            notifier = function()
                                next_symbol_page(vb)
                            end
                        }
                    },
                    
-- Symbol grid for current page (3x4 = 12 symbols per page)
                    (function()
                        -- Phase 4: Use dictionary-ordered symbols when dictionary view is enabled
                        local symbols_to_display
                        if dictionary_view_enabled then
                            symbols_to_display = get_symbols_ordered_by_dictionary()
                        else
                            -- Standard alphabet order
                            local all_symbols = {"A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9"}
                            symbols_to_display = {}
                            for _, s in ipairs(all_symbols) do
                                table.insert(symbols_to_display, {symbol = s, dictionary = get_dictionary_for_symbol(s)})
                            end
                        end
                        
                        local start_index = (symbol_pagination.current_page - 1) * symbol_pagination.symbols_per_page + 1
                        local end_index = math.min(start_index + symbol_pagination.symbols_per_page - 1, #symbols_to_display)
                        
                        -- Dynamic width calculation based on active view modes
                        local base_symbol_width = 120
                        local base_grid_width = 500
                        local width_padding = 0
                        
                        if category_view_enabled then
                            width_padding = width_padding + 15  -- Extra for tag inputs
                        end
                        if organize_view_enabled then
                            width_padding = width_padding + 15  -- Extra for organize controls
                        end
                        if detailed_view_enabled then
                            width_padding = width_padding + 10  -- Extra for detail button
                        end
                        -- Note: dictionary_view does NOT add to symbol width - only to container
                        
                        local symbol_col_width = base_symbol_width + width_padding
                        local grid_width = base_grid_width + (width_padding * 4)  -- 4 columns
                        -- Add extra container space for dictionary view (not per-symbol)
                        if dictionary_view_enabled then
                            grid_width = grid_width + 40  -- Extra container padding for dictionary elements
                        end
                        -- Add extra width for the single expanded symbol's detail box
                        if detailed_view_enabled and expanded_symbol then
                            grid_width = grid_width + 80  -- Extra width for one expanded detail box
                        end
                        
                        -- Debug: Check global symbol registry state
                        print("DEBUG: Global symbol registry has " .. table.count(global_symbol_registry) .. " symbols")
                        for symbol, symbol_data in pairs(global_symbol_registry) do
                            local tags = symbol_data.tags or {}
                            print("DEBUG: Symbol " .. symbol .. " has " .. #tags .. " tags: " .. table.concat(tags, ", "))
                        end
                        
                        local grid_column = vb:column {
                            spacing = 5,
                            width = grid_width,
                            height = 260
                        }
                        
                        -- Create 3x4 grid for current page
                        for row = 1, 3 do
                            local row_columns = {}
                            for col = 1, 4 do
                                local symbol_index = start_index + (row - 1) * 4 + (col - 1)
                                
                                if symbol_index <= end_index then
                                    -- Phase 4: Get symbol info from display structure
                                    local symbol_info = symbols_to_display[symbol_index]
                                    local symbol = symbol_info.symbol
                                    local symbol_dictionary = symbol_info.dictionary
                                    
                                    -- Calculate this symbol's column width (wider if expanded)
                                    local this_symbol_col_width = symbol_col_width
                                    if detailed_view_enabled and expanded_symbol == symbol then
                                        this_symbol_col_width = symbol_col_width + 80  -- Extra width for expanded detail box
                                    end
                                    
                                    local symbol_col = vb:column {
                                        width = this_symbol_col_width,
                                        margin = 3,
                                        style = "panel"
                                    }

                                    print("DEBUG: Creating symbol column for " .. symbol .. ", width=" .. this_symbol_col_width)
                                    
                                    -- Phase 4: Add dictionary indicator at TOP when dictionary view is enabled
                                    if dictionary_view_enabled then
                                        if symbol_dictionary then
                                            local dict_data = get_dictionary_data(symbol_dictionary)
                                            local dict_color = dict_data and dict_data.color or ""
                                            
                                            -- Add colored bar using canvas if dictionary has a color
                                            if dict_color and dict_color ~= "" and color_definitions[dict_color] then
                                                local bar_color = color_definitions[dict_color].original
                                                
                                                symbol_col:add_child(vb:canvas {
                                                    width = this_symbol_col_width - 6,
                                                    height = 4,
                                                    mode = "plain",
                                                    render = function(ctx)
                                                        ctx.fill_color = bar_color
                                                        ctx:fill_rect(0, 0, ctx.size.width, ctx.size.height)
                                                    end
                                                })
                                            else
                                                -- No color - add empty spacer for alignment
                                                symbol_col:add_child(vb:space { height = 4 })
                                            end
                                            
                                            -- Show dictionary name abbreviation
                                            local abbrev = symbol_dictionary:sub(1, 14)
                                            if #symbol_dictionary > 14 then abbrev = abbrev .. ".." end
                                            
                                            symbol_col:add_child(vb:text {
                                                text = abbrev,
                                                style = "disabled",
                                                width = this_symbol_col_width - 6,
                                                align = "center"
                                            })
                                        else
                                            -- Ungrouped indicator - no colored bar
                                            symbol_col:add_child(vb:space { height = 4 })
                                            symbol_col:add_child(vb:text {
                                                text = "(ungrouped)",
                                                style = "disabled",
                                                width = this_symbol_col_width - 6,
                                                align = "center"
                                            })
                                        end
                                        symbol_col:add_child(vb:space { height = 2 })
                                    end
                                    
                                    -- Add placement button if symbol exists, otherwise show disabled text
                                    if current_formatted_labels[symbol] and #current_formatted_labels[symbol] > 0 then
                                        local grid_symbol_button = vb:button {
                                            text = symbol,
                                            width = 35,
                                            height = 25,
                                            notifier = function()
                                                if detailed_view_enabled then
                                                    -- In detailed mode, clicking expands/collapses detail
                                                    expand_symbol_detail(symbol, vb)
                                                else
                                                    -- Normal mode, place symbol
                                                    editor.place_symbol(symbol)
                                                end
                                            end
                                        }
                                        
                                        -- Phase 2: Preview button
                                        local preview_button = vb:button {
                                            text = ">",
                                            width = 20,
                                            height = 25,
                                            tooltip = "Preview symbol " .. symbol,
                                            notifier = function()
                                                preview_symbol(symbol)
                                            end
                                        }
                                        
                                        -- Detailed view: Expand button (only in detailed mode)
                                        local expand_button = vb:button {
                                            text = (expanded_symbol == symbol) and "-" or "+",
                                            width = 20,
                                            height = 25,
                                            tooltip = "Expand/collapse details for " .. symbol,
                                            visible = detailed_view_enabled,
                                            notifier = function()
                                                expand_symbol_detail(symbol, vb)
                                            end
                                        }
                                        
                                        -- Store reference for visual feedback
                                        symbol_button_refs[symbol] = grid_symbol_button
                                        
                                        -- Apply saved color immediately if it exists
                                        local symbol_color = get_symbol_color(symbol)
                                        if symbol_color and symbol_color ~= "" and color_definitions[symbol_color] then
                                            grid_symbol_button.color = color_definitions[symbol_color].darker
                                        end
                                        
                                        symbol_col:add_child(
                                            vb:horizontal_aligner {
                                                mode = "center",
                                                vb:row {
                                                    spacing = 2,
                                                    grid_symbol_button,
                                                    preview_button,
                                                    expand_button
                                                }
                                            }
                                        )
                                    else
                                        -- Show disabled text for symbols that don't exist
                                        -- Note: Dictionary indicator is already added at top of symbol_col
                                        symbol_col:add_child(
                                            vb:horizontal_aligner {
                                                mode = "center",
                                                vb:text {
                                                    text = symbol,
                                                    font = "big",
                                                    style = "disabled"
                                                }
                                            }
                                        )
                                    end
                                    
                                    symbol_col:add_child(vb:space { height = 5 })
                                    
                                    -- Add formatted labels if they exist, otherwise show placeholder
                                    if current_formatted_labels[symbol] and #current_formatted_labels[symbol] > 0 then
                                        for _, label_text in ipairs(current_formatted_labels[symbol]) do
                                            symbol_col:add_child(
                                                vb:text {
                                                    text = label_text,
                                                    font = "mono",
                                                    align = "left"
                                                }
                                            )
                                            symbol_col:add_child(vb:space { height = 1 })
                                        end
                                    else
                                        symbol_col:add_child(
                                            vb:text {
                                                text = "---",
                                                style = "disabled",
                                                align = "center"
                                            }
                                        )
                                    end
                                    
                                    -- Detailed view: Expandable detail container
                                    if detailed_view_enabled then
                                        local is_expanded = (expanded_symbol == symbol)
                                        local detail_info = format_detailed_symbol_info(symbol)
                                        
                                        local detail_container = vb:column {
                                            id = "detail_container_" .. symbol,
                                            visible = is_expanded,
                                            style = "border",
                                            margin = 2,
                                            width = this_symbol_col_width - 8  -- Use dynamic width minus margin
                                        }
                                        
                                        -- Add separator
                                        detail_container:add_child(vb:space { height = 3 })
                                        
                                        -- Add each line of detail info
                                        for _, info_line in ipairs(detail_info) do
                                            detail_container:add_child(
                                                vb:text {
                                                    text = info_line,
                                                    font = "mono",
                                                    align = "left"
                                                }
                                            )
                                        end
                                        
                                        detail_container:add_child(vb:space { height = 3 })
                                        
                                        symbol_col:add_child(detail_container)
                                    end
                                    
-- Add tag display below note info (when not in tag editing mode)
                                    if not category_view_enabled then
                                        -- Check if symbol exists in global registry first
                                        if global_symbol_registry[symbol] then
                                            local current_tags = get_symbol_tags(symbol)
                                            print("DEBUG: Symbol " .. symbol .. " tags check - found " .. (#current_tags or 0) .. " tags")
                                            if current_tags and #current_tags > 0 then
                                                -- Filter out empty tags and format
                                                local non_empty_tags = {}
                                                for _, tag in ipairs(current_tags) do
                                                    if tag and tag ~= "" then
                                                        table.insert(non_empty_tags, tag)
                                                    end
                                                end
                                                
                                                if #non_empty_tags > 0 then
                                                    local tags_text = table.concat(non_empty_tags, ", ")
                                                    print("DEBUG: Adding tags display for " .. symbol .. ": " .. tags_text)
                                                    symbol_col:add_child(vb:space { height = 2 })
                                                    
                                                    -- Split long text into multiple lines manually
                                                    local max_chars_per_line = 16  -- Approximate characters that fit in symbol column
                                                    if #tags_text <= max_chars_per_line then
                                                        -- Short text - single line
                                                        symbol_col:add_child(
                                                            vb:text {
                                                                text = tags_text,
                                                                font = "mono",
                                                                style = "disabled",
                                                                align = "left"
                                                            }
                                                        )
                                                    else
                                                        -- Long text - split into multiple lines
                                                        local words = {}
                                                        for word in tags_text:gmatch("[^, ]+") do
                                                            table.insert(words, word)
                                                        end
                                                        
                                                        local current_line = ""
                                                        for i, word in ipairs(words) do
                                                            local test_line = current_line == "" and word or (current_line .. ", " .. word)
                                                            if #test_line <= max_chars_per_line then
                                                                current_line = test_line
                                                            else
                                                                -- Add current line and start new one
                                                                if current_line ~= "" then
                                                                    symbol_col:add_child(
                                                                        vb:text {
                                                                            text = current_line,
                                                                            font = "mono",
                                                                            style = "disabled",
                                                                            align = "left"
                                                                        }
                                                                    )
                                                                end
                                                                current_line = word
                                                            end
                                                        end
                                                        
                                                        -- Add final line if any
                                                        if current_line ~= "" then
                                                            symbol_col:add_child(
                                                                vb:text {
                                                                    text = current_line,
                                                                    font = "mono",
                                                                    style = "disabled",
                                                                    align = "left"
                                                                }
                                                            )
                                                        end
                                                    end
                                                end
                                            else
                                                print("DEBUG: Symbol " .. symbol .. " has no non-empty tags to display")
                                            end
                                        else
                                            print("DEBUG: Symbol " .. symbol .. " not found in global registry")
                                        end
                                    end
                                    
                                    -- NEW: Add color UI row (before tags)
                                    local current_color = get_symbol_color(symbol)
                                    local color_is_saved = color_editing_states[symbol] or false
                                    
                                    symbol_col:add_child(
                                        vb:row {
                                            id = "color_row_" .. symbol,
                                            visible = category_view_enabled,  -- Same visibility as tags
                                            spacing = 2,
                                            width = 122,  -- Fixed width to match symbol column
                                            
                                            -- Container for the popup/display area to maintain consistent width
                                            vb:column {
                                                width = 98,
                                                height = 20,
                                                
                                                -- Popup (for editing)
                                                vb:popup {
                                                    id = "color_popup_" .. symbol,
                                                    width = 98,
                                                    height = 20,
                                                    items = color_dropdown_items,
                                                    value = (function()
                                                        local color_index = table.find(color_dropdown_items, current_color)
                                                        return color_index or 1
                                                    end)(),
                                                    visible = not (color_is_saved and current_color and current_color ~= "")
                                                },
                                                
                                                -- Text display (for saved state) - wrapped in aligner for consistent positioning
                                                vb:horizontal_aligner {
                                                    mode = "left",
                                                    width = 98,
                                                    height = 20,
                                                    vb:text {
                                                        id = "color_text_" .. symbol,
                                                        text = current_color or "",
                                                        style = "strong",
                                                        tooltip = "Color: " .. (current_color or ""),
                                                        visible = (color_is_saved and current_color and current_color ~= "")
                                                    }
                                                }
                                            },
                                            
                                            -- Save/Edit button
                                            vb:button {
                                                id = "color_save_" .. symbol,
                                                text = (color_is_saved and current_color and current_color ~= "") and "[*]" or "[ ]",
                                                width = 22,
                                                height = 20,
                                                tooltip = (color_is_saved and current_color and current_color ~= "") and "Click to edit color" or "Click to save color",
                                                notifier = function()
                                                    local current_color_is_saved = color_editing_states[symbol] or false
                                                    local current_col = get_symbol_color(symbol)
                                                    
                                                    if current_color_is_saved and current_col and current_col ~= "" then
                                                        -- Currently saved, so unlock for editing
                                                        unlock_symbol_color(symbol, vb)
                                                    else
                                                        -- Currently editing, so save
                                                        local color_popup = vb.views["color_popup_" .. symbol]
                                                        if color_popup then
                                                            local selected_color = color_dropdown_items[color_popup.value]
                                                            save_symbol_color(symbol, selected_color, vb)
                                                        end
                                                    end
                                                end
                                            }
                                        }
                                    )
                                    
                                    -- NEW: Add tag UI container (after color row)
                                    local current_tags = get_symbol_tags(symbol)
                                    local tag_count = math.max(1, #current_tags)
                                    
                                    -- Create tag container
                                    local tag_container = vb:column {
                                        id = "tag_container_" .. symbol,
                                        visible = category_view_enabled,
                                        spacing = 1
                                    }
                                    
                                    -- Add tag input rows
                                    for i = 1, tag_count do
                                        local tag_text = current_tags[i] or ""
                                        local is_saved = tag_editing_states[symbol] and tag_editing_states[symbol][i] or false
                                        
                                        local tag_row = create_tag_input_row(symbol, i, tag_text, is_saved, vb)
                                        tag_container:add_child(tag_row)
                                    end
                                    
                                    -- Add +/- buttons row
                                    local buttons_row = create_tag_buttons_row(symbol, vb)
                                    tag_container:add_child(buttons_row)
                                    
                                    symbol_col:add_child(tag_container)
                                    
                                    -- Update button states after container is created
                                    update_tag_button_states(symbol, vb)
                                    
                                    -- Calculate organize row width based on symbol column width
                                    local organize_row_width = this_symbol_col_width - 8
                                    
                                    -- NEW: Add organize UI rows (move controls and delete button)
                                    if global_symbol_registry[symbol] then
                                        -- Move controls row (dropdown + lock button)
                                        local move_row = vb:row {
                                            id = "move_row_" .. symbol,
                                            visible = organize_view_enabled,
                                            spacing = 2,
                                            width = organize_row_width,
                                            
                                            -- Move to dropdown
                                            vb:popup {
                                                id = "move_dropdown_" .. symbol,
                                                width = organize_row_width - 30,
                                                height = 20,
                                                items = get_available_symbols_for_moving(symbol),
                                                value = 1  -- Default to "Select target..."
                                            },
                                            
                                            -- Lock/execute move button
                                            vb:button {
                                                id = "move_lock_" .. symbol,
                                                text = "->",
                                                width = 28,
                                                height = 20,
                                                tooltip = "Move symbol " .. symbol .. " to selected position",
                                                notifier = function()
                                                    local dropdown = vb.views["move_dropdown_" .. symbol]
                                                    if dropdown and dropdown.value > 1 then
                                                        local target_symbol = dropdown.items[dropdown.value]
                                                        local success = move_symbol_to_position(symbol, target_symbol, vb)
                                                        if success then
                                                            -- Preserve unsaved tag inputs before refresh
                                                            if current_dialog_vb then
                                                                preserve_unsaved_tag_inputs(nil, current_dialog_vb)
                                                            end
                                                            -- Refresh dialog to show new positions
                                                            if dialog and dialog.visible then
                                                                dialog:close()
                                                                show_main_dialog()
                                                            end
                                                        end
                                                    else
                                                        renoise.app():show_warning("Please select a target symbol first")
                                                    end
                                                end
                                            }
                                        }
                                        
                                        symbol_col:add_child(move_row)
                                        
                                        -- Delete button row
                                        local delete_row = vb:row {
                                            id = "delete_row_" .. symbol,
                                            visible = organize_view_enabled,
                                            spacing = 2,
                                            width = organize_row_width,
                                            
                                            vb:button {
                                                text = "Delete",
                                                width = organize_row_width,
                                                height = 20,
                                                color = {0x80, 0x00, 0x00}, -- Dark red color to indicate destructive action
                                                tooltip = "Delete symbol " .. symbol .. " permanently",
                                                notifier = function()
                                                    delete_symbol(symbol, vb)
                                                end
                                            }
                                        }
                                        
                                        symbol_col:add_child(delete_row)
                                        
                                        -- Phase 4: Dictionary assignment row
                                        local dict_row = vb:row {
                                            id = "dict_row_" .. symbol,
                                            visible = organize_view_enabled,
                                            spacing = 2,
                                            width = organize_row_width,
                                            
                                            vb:text {
                                                text = "Dict:",
                                                width = 30,
                                                style = "disabled"
                                            },
                                            
                                            vb:popup {
                                                id = "dict_dropdown_" .. symbol,
                                                width = organize_row_width - 32,
                                                height = 20,
                                                items = (function()
                                                    local items = {"-- None --"}
                                                    local dict_names = get_all_dictionaries()
                                                    for _, name in ipairs(dict_names) do
                                                        table.insert(items, name)
                                                    end
                                                    return items
                                                end)(),
                                                value = (function()
                                                    local current_dict = get_dictionary_for_symbol(symbol)
                                                    if current_dict then
                                                        local dict_names = get_all_dictionaries()
                                                        for i, name in ipairs(dict_names) do
                                                            if name == current_dict then
                                                                return i + 1  -- +1 for "-- None --"
                                                            end
                                                        end
                                                    end
                                                    return 1
                                                end)(),
                                                notifier = function(new_value)
                                                    if new_value == 1 then
                                                        -- Remove from dictionary
                                                        remove_symbol_from_current_dictionary(symbol)
                                                    else
                                                        local dict_names = get_all_dictionaries()
                                                        local selected_dict = dict_names[new_value - 1]
                                                        if selected_dict then
                                                            add_symbol_to_dictionary(symbol, selected_dict)
                                                        end
                                                    end
                                                    renoise.app():show_status("Dictionary updated for " .. symbol)
                                                end
                                            }
                                        }
                                        
                                        symbol_col:add_child(dict_row)
                                    else
                                        -- Empty placeholder for symbols that don't exist
                                        local empty_organize_row = vb:column {
                                            id = "organize_row_" .. symbol,
                                            visible = organize_view_enabled,
                                            width = organize_row_width,
                                            height = 62,  -- Height for move, delete, and dict rows
                                            vb:text {
                                                text = "",
                                                width = organize_row_width,
                                                height = 62
                                            }
                                        }
                                        
                                        symbol_col:add_child(empty_organize_row)
                                    end
                                    
                                    table.insert(row_columns, symbol_col)
                                else
                                    -- Empty placeholder
                                    table.insert(row_columns, vb:column {
                                        width = symbol_col_width,
                                        height = 60,
                                        margin = 3
                                    })
                                end
                            end
                            
                            -- Add row to grid
                            grid_column:add_child(vb:row {
                                spacing = 5,
                                unpack(row_columns)
                            })
                        end
                        
                        return grid_column
                    end)(),
                    
                    vb:space { height = 15 },
                    
                    -- Combined row: Input lock indicator (left) and Export/Import buttons (right)
                    vb:row {
                        spacing = 10,
                        
                        -- Input lock status indicator (left side)
                        vb:column {
                            spacing = 3,
                            vb:text {
                                id = "input_lock_status",
                                text = "Input Lock",
                                font = "big",
                                style = "normal",
                                align = "left"
                            },
                            vb:text {
                                id = "input_lock_description",
                                text = "Double-press Ctrl to activate",
                                style = "disabled",
                                align = "left"
                            }
                        },
                        
                        -- Spacer to push buttons to the right
                        vb:space { width = 5 },
                        
                        -- Export/Import Alphabet buttons (right side)
                        vb:horizontal_aligner {
                            mode = "right",
                            vb:row {
                                spacing = 5,
                                vb:button {
                                    text = "Dictionaries",
                                    width = 85,
                                    height = 22,
                                    tooltip = "Manage symbol dictionaries",
                                    notifier = function()
                                        show_dictionary_management_dialog()
                                    end
                                },
                                vb:button {
                                    text = "Export",
                                    width = 55,
                                    height = 22,
                                    tooltip = "Export alphabet to CSV or JSON",
                                    notifier = function()
                                        export_global_alphabet()
                                    end
                                },
                                vb:button {
                                    text = "Import",
                                    width = 55,
                                    height = 22,
                                    tooltip = "Import alphabet from CSV or JSON",
                                    notifier = function()
                                        import_global_alphabet()
                                    end
                                }
                            }
                        }
                    }
                },
                
                -- Compact right column content (visible when collapsed)
                vb:column {
                    id = "right_compact_content",
                    visible = right_column_collapsed,
                    create_compact_right_column(vb)
                }
            }
        },
        
        -- Action buttons (collapsible)
        vb:row {
            id = "action_buttons",
            visible = not ui_collapsed,
            spacing = 10,
            vb:button {
                text = "Commit to Phrase",
                width = 150,
                height = 30,
                notifier = function()
                    commit_to_phrase(vb, break_sets)
                end
            },
            vb:button {
                text = "Import Syntax",
                width = 100,
                notifier = function()
                    syntax.import_syntax(vb)
                end
            },
            vb:button {
                text = "Export Syntax",
                width = 100,
                notifier = function()
                    syntax.export_syntax(vb)
                end
            }
        }
    }
    
    return dialog_content
end

-- Main dialog key handler for input lock
local function main_dialog_key_handler(dialog, key)
    -- Let input lock system handle the key event
    return input_lock.handle_key_event(key)
end

-- Add composite symbol row
add_composite_symbol = function(dialog_vb)
    if current_symbol_index >= #composite_symbols then
        renoise.app():show_status("Maximum number of composite symbols reached!")
        return
    end
    
    current_symbol_index = current_symbol_index + 1
    local symbol = composite_symbols[current_symbol_index]
    
    local composite_container = dialog_vb.views.composite_symbols
    local new_row = dialog_vb:row {
        margin = 3,
        dialog_vb:text {
            text = symbol .. " =",
            width = 25
        },
        dialog_vb:textfield {
            id = "symbol_" .. string.lower(symbol),
            width = 365,
            height = 25
        }
    }
    
    composite_container:add_child(new_row)
    
    -- Hide add button if we've reached the maximum
    if current_symbol_index >= #composite_symbols then
        dialog_vb.views.add_symbol_button.visible = false
    end
end

-- Commit break string to phrase
commit_to_phrase = function(dialog_vb, break_sets)
    return safe_song_access(function()
        local break_string = dialog_vb.views.break_string.text
        
        if not break_sets or #break_sets == 0 then
            renoise.app():show_warning("No break sets available. Please ensure you have breakpoints defined and at least one phrase.")
            return
        end
        
        if not break_string or break_string == "" then
            renoise.app():show_warning("Please enter a break string.")
            return
        end
        
        -- Parse break string with composite symbols
        local composite_symbol_values = {}
        for _, symbol in ipairs(composite_symbols) do
            local symbol_view = dialog_vb.views["symbol_" .. string.lower(symbol)]
            if symbol_view and symbol_view.text ~= "" then
                composite_symbol_values[symbol] = symbol_view.text:upper()
            end
        end
        
        local permutation, error = syntax.parse_break_string(break_string, #break_sets, composite_symbol_values)
        if not permutation then
            renoise.app():show_warning("Invalid break string: " .. error)
            return
        end
        
        -- Get current instrument and phrase
        local song = renoise.song()
        local instrument = song.selected_instrument
        if #instrument.phrases == 0 then
            renoise.app():show_warning("No phrases available in current instrument.")
            return
        end
        
        local original_phrase = instrument.phrases[1]
        
        -- Create the break pattern
        breakpoints.create_break_phrase(break_sets, original_phrase, permutation, break_string)
        
        -- Show status with resolved string if composites were used
        local resolved = syntax.resolve_break_string(break_string, composite_symbol_values)
        if resolved ~= break_string then
            renoise.app():show_status(string.format("Break pattern created. Original: %s, Resolved: %s", 
                break_string, resolved))
        else
            renoise.app():show_status("Break pattern created from string: " .. break_string)
        end
    end)
end

-- Show main dialog
function show_main_dialog()
    if not renoise.song() then
        renoise.app():show_warning("Song not available. Please create or load a song first.")
        return
    end
    
    -- Load global symbol registry on first dialog show
    if not tool_initialized then
        load_global_symbol_registry()
        load_dictionaries()  -- Phase 4: Load dictionaries after registry
        tool_initialized = true
    else
        -- Ensure tag editing states are up to date
        initialize_tag_editing_states()
    end
    
    -- Debug: Check registry state right before dialog creation
    print("DEBUG: show_main_dialog - global_symbol_registry has " .. table.count(global_symbol_registry) .. " symbols")
    for symbol, symbol_data in pairs(global_symbol_registry) do
        if symbol_data.tags and #symbol_data.tags > 0 then
            print("DEBUG: Symbol " .. symbol .. " has tags: " .. table.concat(symbol_data.tags, ", "))
        end
    end
    
    -- Initialize editor when dialog is shown (safe because song exists)
    editor.initialize()
    
    -- Set up editor module references to main module functions (including global symbol registry)
    -- Phase 5: Added multi-track distance mode getters
    editor.set_main_module_functions(get_overflow_behavior, get_overflow_behavior_constants, get_overwrite_behavior, get_overwrite_behavior_constants, get_instrument_source_behavior, get_instrument_source_behavior_constants, get_global_symbol_registry, get_symbol_instrument_mapping, get_multi_track_distance_mode, get_multi_track_distance_mode_constants)

    if dialog and dialog.visible then
        dialog:close()
        dialog = nil
    end
    
    local dialog_content = create_symbol_editor_dialog()
    if dialog_content then
        -- Set up key handler options for input lock
        local key_handler_options = {
            send_key_repeat = false,
            send_key_release = true
        }
        
        dialog = renoise.app():show_custom_dialog("BreakFast", dialog_content, main_dialog_key_handler, key_handler_options)
        
        -- Initialize input lock system (editor module is already required at top of file)
         if editor then
            input_lock.initialize(editor, update_input_lock_visual, update_symbol_feedback)
        else
            print("ERROR: Editor module not available for input lock initialization")
        end

        -- Apply saved colors to symbol buttons after dialog creation
        if current_dialog_vb then
            for symbol, symbol_data in pairs(global_symbol_registry) do
                if symbol_data.color and symbol_data.color ~= "" then
                    apply_symbol_button_color(symbol, symbol_data.color, current_dialog_vb)
                end
            end
        end

        -- Store formatted_labels reference and initialize pagination
        if current_dialog_vb then
            -- Get the formatted_labels from the dialog creation context
            local song = renoise.song()
            local instrument = song.selected_instrument
            local saved_labels = labeler.get_saved_labels()
            local break_sets = {}
            local formatted_labels = {}
            
            -- Check if we have any breakpoints defined
            local has_breakpoints = false
            for _, label_data in pairs(saved_labels) do
                if label_data.breakpoint then
                    has_breakpoints = true
                    break
                end
            end
            
            if has_breakpoints and #instrument.phrases > 0 then
                local original_phrase = instrument.phrases[1]
                break_sets = breakpoints.create_break_patterns(instrument, original_phrase, saved_labels)
                
                -- Only create formatted labels if we actually have break sets with content
                if break_sets and #break_sets > 0 then
                    formatted_labels = syntax.prepare_symbol_labels(break_sets, saved_labels)
                end
            end
            
            -- Store at module level instead of assigning to ViewBuilder
            current_formatted_labels = formatted_labels
            -- No need to call update function since dialog is created fresh each time
        end
    end
end

-- Safe callback wrapper for labeler refresh
local function safe_labeler_refresh()
    print("DEBUG: safe_labeler_refresh called")
    if dialog and dialog.visible then
        print("DEBUG: Main dialog is visible, preserving tag inputs and reopening")
        -- Preserve all unsaved tag inputs before refresh
        if current_dialog_vb then
            preserve_unsaved_tag_inputs(nil, current_dialog_vb)
        end
        dialog:close()
        show_main_dialog()
    else
        print("DEBUG: Main dialog is not visible, not refreshing")
    end
end

-- Get current overflow behavior setting
function get_overflow_behavior()
    return current_overflow_behavior
end

-- Get overflow behavior constants for external access
function get_overflow_behavior_constants()
    return overflow_behavior
end

-- Get current overwrite behavior setting
function get_overwrite_behavior()
    return current_overwrite_behavior
end

-- Get overwrite behavior constants for external access
function get_overwrite_behavior_constants()
    return overwrite_behavior
end

-- Get current instrument source behavior setting
function get_instrument_source_behavior()
    return current_instrument_source_behavior
end

-- Get instrument source behavior constants for external access
function get_instrument_source_behavior_constants()
    return instrument_source_behavior
end

-- Phase 5: Get multi-track distance mode for external access
function get_multi_track_distance_mode()
    return current_multi_track_distance_mode
end

-- Phase 5: Get multi-track distance mode constants for external access
function get_multi_track_distance_mode_constants()
    return multi_track_distance_mode
end

-- Set up labeler callback to refresh main dialog and provide global symbol functions
labeler.set_refresh_callback(safe_labeler_refresh)
labeler.set_global_symbol_functions(
    get_global_symbol_registry, 
    assign_symbols_to_instrument, 
    save_global_symbol_registry,
    get_custom_labels_data,
    save_custom_labels_data,
    get_show_label2,
    save_show_label2
)

-- Set up selection module functions
selection.set_global_symbol_functions(get_global_symbol_registry, find_next_available_symbols, save_global_symbol_registry)

-- Add periodic check for when labeler closes to trigger additional refresh
local labeler_was_open = false
local labeler_check_notifier = function()
    -- Check if labeler was open but now isn't (i.e., it was closed)
    local labeler_is_open = labeler.dialog and labeler.dialog.visible
    
    if labeler_was_open and not labeler_is_open then
        -- Labeler was just closed, trigger refresh like import does
        print("DEBUG: Labeler dialog closed, triggering manual refresh")
        if dialog and dialog.visible then
            -- Preserve all unsaved tag inputs before refresh
            if current_dialog_vb then
                preserve_unsaved_tag_inputs(nil, current_dialog_vb)
            end
            dialog:close()
            show_main_dialog()
        end
    end
    
    labeler_was_open = labeler_is_open
end

-- Add the check to idle observable
renoise.tool().app_idle_observable:add_notifier(labeler_check_notifier)

-- Load registry will be handled when show_main_dialog() is called
-- This ensures a song is available before trying to load preferences

-- Tool menu entry - safe wrapper
renoise.tool():add_menu_entry {
    name = "Main Menu:Tools:BreakFast...",
    invoke = function()
        show_main_dialog()
    end
}

-- Pattern Editor context menu entry for capturing selection
renoise.tool():add_menu_entry {
    name = "Pattern Editor:Capture Selection as BreakFast Symbol",
    invoke = function()
        capture_selection_as_symbol()
    end
}

-- Pattern Editor context menu entry for capturing selection with labels
renoise.tool():add_menu_entry {
    name = "Pattern Editor:Capture Selection with Labels",
    invoke = function()
        capture_selection_with_labels()
    end
}

-- Phase 2: Pattern Editor context menu entry for adding breakpoints from selection
renoise.tool():add_menu_entry {
    name = "Pattern Editor:BreakFast:Add Breakpoints from Selection",
    invoke = function()
        add_breakpoints_from_selection()
    end
}

-- Initialize keybinding system (safe at startup)
register_keybinding_entries()

-- Cleanup on tool unload
function cleanup()
    -- Stop any active preview (both symbol and slice)
    stop_symbol_preview()
    labeler.stop_slice_preview()  -- Phase 6: Stop slice preview
    
    -- Save global symbol registry before cleanup
    save_global_symbol_registry()
    
    -- Cleanup input lock system
    input_lock.cleanup()
    
    if dialog and dialog.visible then
        dialog:close()
        dialog = nil
    end

    -- Clear symbol button references
    symbol_button_refs = {}    
    labeler.cleanup()
    editor.cleanup()
    tool_initialized = false
end