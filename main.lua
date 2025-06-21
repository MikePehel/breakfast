-- main.lua - BreakFast Main Entry Point (Phase 2: Added Substitute Overwrite Behavior)
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
    LOOP = 4
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

-- Input lock state and callback
local input_lock_active = false
local current_dialog_vb = nil

-- Symbol button feedback tracking
local symbol_button_refs = {} -- Store references to symbol buttons for highlighting

-- Tag system state
local category_view_enabled = false  -- Toggle state for ≡/… button (keep same name for UI compatibility)
local tag_editing_states = {}       -- Track which symbols have saved tags: symbol -> {tag_index -> boolean}
local color_editing_states = {}     -- Track which symbols have saved colors: symbol -> boolean

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
    global_symbol_registry_data = ""
}

renoise.tool().preferences = preferences

-- Initialization flag
local tool_initialized = false

-- Pagination state for symbol grid
local symbol_pagination = {
    current_page = 1,
    symbols_per_page = 12, -- 3x4 grid (3 rows, 4 columns)
    total_pages = 1
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

function get_symbol_instrument_mapping(symbol)
    local registry_entry = global_symbol_registry[symbol]
    return registry_entry and registry_entry.instrument_index or nil
end

-- Tag system functions
function toggle_tag_view(vb)
    category_view_enabled = not category_view_enabled  -- Keep same variable name for UI compatibility
    
    -- Update toggle button text
    if vb.views.category_toggle then
        vb.views.category_toggle.text = category_view_enabled and "…" or "≡"
    end
    
    -- Update visibility of all tag rows and color rows
    for _, symbol in ipairs(available_symbols) do
        -- Update visibility of tag container
        local tag_container = vb.views["tag_container_" .. symbol]
        if tag_container then
            tag_container.visible = category_view_enabled
        end
        
        -- Update visibility of color rows
        local color_row = vb.views["color_row_" .. symbol]
        if color_row then
            color_row.visible = category_view_enabled
        end
    end
    
    print("DEBUG: Tag view toggled to " .. (category_view_enabled and "enabled" or "disabled"))
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
    
    -- Persist to preferences
    save_global_symbol_registry()
    
    print("DEBUG: Saved tag " .. tag_index .. " '" .. (tag_text or "") .. "' for symbol " .. symbol)
    
    local status_msg = has_tag and 
        ("Tag saved for symbol " .. symbol .. ": " .. tag_text) or
        ("Tag cleared for symbol " .. symbol)
    renoise.app():show_status(status_msg)
    
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
        tag_save_button.text = "[■]"
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
        tag_save_button.text = "[□]"
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
    if symbol then
        -- Preserve specific symbol
        preserve_single_symbol_tag_inputs(symbol, vb)
    else
        -- Preserve all symbols
        for sym, _ in pairs(global_symbol_registry) do
            preserve_single_symbol_tag_inputs(sym, vb)
        end
    end
end

function preserve_single_symbol_tag_inputs(symbol, vb)
    local current_tags = get_symbol_tags(symbol)
    local tag_count = get_tag_count(symbol)
    
    if not global_symbol_registry[symbol].tags then
        global_symbol_registry[symbol].tags = {}
    end
    
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
                tag_editing_states[symbol][i] = false
            end
        end
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
        width = 102,  -- Fixed width to prevent expansion (80 + 20 + 2 spacing)
        
        -- Container for the input/display area to maintain consistent width
        vb:column {
            width = 80,
            height = 20,
            
            -- Textfield (for editing)
            vb:textfield {
                id = "tag_field_" .. symbol .. "_" .. tag_index,
                width = 80,
                height = 20,
                text = tag_text or "",
                visible = not (is_saved and tag_text and tag_text ~= "")
            },
            
            -- Text display (for saved state) - wrapped in aligner for consistent positioning
            vb:horizontal_aligner {
                mode = "left",
                width = 80,
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
            text = (is_saved and tag_text and tag_text ~= "") and "[■]" or "[□]",
            width = 20,
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
        color_save_button.text = "[■]"
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
        color_save_button.text = "[□]"
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
        category_save_button.text = "[■]"
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
        category_save_button.text = "[□]"
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

-- Load global symbol registry from preferences on startup
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
    
    -- Write CSV header - expanded to include symbol type, range capture metadata, tags, and color
    file:write("Symbol,SymbolType,Tags,Color,InstrumentIndex,SliceIndex,SliceLabel,IsBreakpoint,TimingLine,TimingDelay,OriginalDistance,NoteValue,SourcePattern,SourceTrack,CaptureStartLine,CaptureEndLine\n")
    
    -- Write data for each symbol
    for symbol, symbol_data in pairs(global_symbol_registry) do
        local instrument_index = symbol_data.instrument_index or 1
        local break_set = symbol_data.break_set
        local saved_labels = symbol_data.saved_labels or {}
        local symbol_type = symbol_data.symbol_type or "breakpoint_created"
        local symbol_color = symbol_data.color or ""
        local symbol_tags = symbol_data.tags or {}
        
        -- Convert tags array to comma-separated string
        local tags_string = ""
        if #symbol_tags > 0 then
            tags_string = table.concat(symbol_tags, ", ")
        end
        
        print("DEBUG: Exporting symbol " .. symbol .. " (type: " .. symbol_type .. ") with " .. (function()
            local count = 0
            for _ in pairs(saved_labels) do count = count + 1 end
            return count
        end)() .. " labels, tags: " .. tags_string .. ", and color: " .. symbol_color)
        
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
                
                local values = {
                    symbol or "",
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
                    source_pattern,
                    source_track,
                    capture_start_line,
                    capture_end_line
                }
                
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
        
        -- Build symbol entry with all metadata
        local symbol_entry = {
            symbol_type = symbol_type,
            instrument_index = instrument_index,
            tags = symbol_data.tags or {},  -- Store as array
            color = symbol_data.color or "",
            notes = {},
            timing_data = {}
        }
        
        -- Add source metadata for range-captured symbols
        if symbol_type == "range_captured" and symbol_data.source_metadata then
            symbol_entry.source_metadata = {
                pattern_index = symbol_data.source_metadata.pattern_index,
                track_index = symbol_data.source_metadata.track_index,
                capture_info = symbol_data.source_metadata.capture_info
            }
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
                    source_instrument_index = actual_instrument_value
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
                if timing.effect_number then
                    note_entry.effect_number = timing.effect_number
                end
                if timing.effect_amount then
                    note_entry.effect_amount = timing.effect_amount
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
                    effect_number = timing.effect_number,
                    effect_amount = timing.effect_amount
                })
            end
        end
        
        export_data.symbols[symbol] = symbol_entry
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
    
    -- Updated expected columns to include new fields
    local expected_columns = {
        "symbol", "symboltype", "tags", "color", "instrumentindex", "sliceindex", "slicelabel", 
        "timingline", "timingdelay", "originaldistance", "notevalue",
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
                            if entry.effect_number then
                                timing_entry.effect_number = entry.effect_number
                            end
                            if entry.effect_amount then
                                timing_entry.effect_amount = entry.effect_amount
                            end
                            
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
            if symbol_type == "range_captured" and symbol_data.source_metadata and type(symbol_data.source_metadata) == "table" then
                source_metadata = symbol_data.source_metadata
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
                
                imported_count = imported_count + 1
            end
        end
    end
    
    if imported_count == 0 then
        renoise.app():show_warning("No valid symbol data found in JSON file")
        return
    end
    
    -- Save to preferences
    save_global_symbol_registry()
    
    renoise.app():show_status(string.format("Imported %d symbols from JSON", imported_count))
    
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
                    end
                end
            },
            vb:text { text = "L", width = 15 }
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
    if vb.views.break_string_section then
        vb.views.break_string_section.visible = not ui_collapsed
    end
    if vb.views.composite_symbols_section then
        vb.views.composite_symbols_section.visible = not ui_collapsed
    end
    if vb.views.instrument_source_section then
        vb.views.instrument_source_section.visible = not ui_collapsed
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

-- Toggle right column collapse state
local function toggle_right_column_collapse(vb)
    right_column_collapsed = not right_column_collapsed
    
    -- Update collapse button text
    if vb.views.right_collapse_button then
        vb.views.right_collapse_button.text = right_column_collapsed and "+" or "-"
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
            -- Restore full width
            vb.views.right_column_container.width = 500
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
            
            current_row:add_child(symbol_button)
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
                                        end
                                    end
                                },
                                vb:text {
                                    text = "Loop",
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

                -- Break string input with quick insert buttons (collapsible)
                vb:column {
                    id = "break_string_section",
                    visible = not ui_collapsed,
                    style = "group",
                    margin = 10,
                    vb:text {
                        text = "Break String",
                        font = "big",
                        style = "strong"
                    },
                    vb:space { height = 5 },
                    vb:textfield {
                        id = "break_string",
                        width = 400,
                        height = 25,
                        text = ""
                    },
                    vb:space { height = 5 },
                    vb:row {
                        spacing = 5,
                        vb:text {
                            text = "Quick Insert:",
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
                                    spacing = 3,
                                    unpack((function()
                                        local buttons = {}
                                        for i = 1, math.min(#available_symbols, 10) do
                                            local symbol_letter = available_symbols[i]
                                            table.insert(buttons, vb:button {
                                                text = symbol_letter,
                                                width = 30,
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
                                    text = "No symbols available",
                                    style = "disabled"
                                }
                            end
                        end)()
                    },
                    vb:space { height = 3 },
                    vb:text {
                        text = "Tip: Assign keyboard shortcuts in Preferences > Keys > Global > Tools",
                        style = "disabled"
                    }
                },

                -- Composite symbols section (collapsible)
                vb:column {
                    id = "composite_symbols_section",
                    visible = not ui_collapsed,
                    style = "group",
                    margin = 10,
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
                },

                -- Compact behaviors section (only visible when collapsed)
                vb:column {
                    id = "compact_behaviors_section",
                    visible = ui_collapsed,
                    spacing = 10,
                    create_compact_overflow_section(vb),
                    create_compact_overwrite_section(vb),
                    create_compact_instrument_source_section(vb)
                }
            },
            
            -- Right side: Symbol Grid
            vb:column {
                id = "right_column_container",
                style = "group",
                margin = 10,
                width = 500,

                
                -- Right column header with collapse and category toggle buttons
                vb:row {
                    spacing = 5,
                    vb:button {
                        id = "category_toggle",
                        text = category_view_enabled and "…" or "≡",
                        width = 25,
                        height = 25,
                        tooltip = "Toggle tag view",
                        notifier = function()
                            toggle_tag_view(vb)
                        end
                    },
                    vb:horizontal_aligner {
                        mode = "right",
                        vb:button {
                            id = "right_collapse_button",
                            text = right_column_collapsed and "+" or "-",
                            width = 25,
                            height = 25,
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
                            text = "◄ Previous",
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
                            text = "Next ►",
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
                        local all_symbols = {"A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9"}
                        local start_index = (symbol_pagination.current_page - 1) * symbol_pagination.symbols_per_page + 1
                        local end_index = math.min(start_index + symbol_pagination.symbols_per_page - 1, #all_symbols)
                        
                        local grid_column = vb:column {
                            spacing = 5,
                            width = 500,
                            height = 240
                        }
                        
                        -- Create 3x4 grid for current page
                        for row = 1, 3 do
                            local row_columns = {}
                            for col = 1, 4 do
                                local symbol_index = start_index + (row - 1) * 4 + (col - 1)
                                
                                if symbol_index <= end_index then
                                    local symbol = all_symbols[symbol_index]
                                    local symbol_col = vb:column {
                                        width = 120,
                                        margin = 3,
                                        style = "panel"
                                    }
                                    
                                    -- Add placement button if symbol exists, otherwise show disabled text
                                    if current_formatted_labels[symbol] and #current_formatted_labels[symbol] > 0 then
                                        local grid_symbol_button = vb:button {
                                            text = symbol,
                                            width = 35,
                                            height = 25,
                                            notifier = function()
                                                editor.place_symbol(symbol)
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
                                                grid_symbol_button
                                            }
                                        )
                                    else
                                        -- Show disabled text for symbols that don't exist
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
                                    
                                    -- NEW: Add color UI row (before tags)
                                    local current_color = get_symbol_color(symbol)
                                    local color_is_saved = color_editing_states[symbol] or false
                                    
                                    symbol_col:add_child(
                                        vb:row {
                                            id = "color_row_" .. symbol,
                                            visible = category_view_enabled,  -- Same visibility as tags
                                            spacing = 2,
                                            width = 102,  -- Fixed width to prevent expansion (80 + 20 + 2 spacing)
                                            
                                            -- Container for the popup/display area to maintain consistent width
                                            vb:column {
                                                width = 80,
                                                height = 20,
                                                
                                                -- Popup (for editing)
                                                vb:popup {
                                                    id = "color_popup_" .. symbol,
                                                    width = 80,
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
                                                    width = 80,
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
                                                text = (color_is_saved and current_color and current_color ~= "") and "[■]" or "[□]",
                                                width = 20,
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
                                    
                                    table.insert(row_columns, symbol_col)
                                else
                                    -- Empty placeholder
                                    table.insert(row_columns, vb:column {
                                        width = 120,
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
                        vb:space { width = 1 },
                        
                        -- Export/Import Alphabet buttons (right side)
                        vb:horizontal_aligner {
                            mode = "right",
                            vb:row {
                                spacing = 10,
                                vb:button {
                                    text = "Export Alphabet",
                                    width = 120,
                                    notifier = function()
                                        export_global_alphabet()
                                    end
                                },
                                vb:button {
                                    text = "Import Alphabet",
                                    width = 120,
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
        tool_initialized = true
    else
        -- Ensure tag editing states are up to date
        initialize_tag_editing_states()
    end
    
    -- Initialize editor when dialog is shown (safe because song exists)
    editor.initialize()
    
    -- Set up editor module references to main module functions (including global symbol registry)
    editor.set_main_module_functions(get_overflow_behavior, get_overflow_behavior_constants, get_overwrite_behavior, get_overwrite_behavior_constants, get_instrument_source_behavior, get_instrument_source_behavior_constants, get_global_symbol_registry, get_symbol_instrument_mapping)

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

-- Set up labeler callback to refresh main dialog and provide global symbol functions
labeler.set_refresh_callback(safe_labeler_refresh)
labeler.set_global_symbol_functions(get_global_symbol_registry, assign_symbols_to_instrument, save_global_symbol_registry)

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

-- Initialize keybinding system (safe at startup)
register_keybinding_entries()

-- Cleanup on tool unload
function cleanup()
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