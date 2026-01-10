-- main.lua - BreakFast Main Entry Point (Phase 5: Multi-Track Support)
-- ============================================================================
-- Module Requires
-- ============================================================================

-- Existing modules
local vb = renoise.ViewBuilder()
local labeler = require("labeler")
local breakpoints = require("breakpoints")
local syntax = require("syntax")
local editor = require("editor")
local selection = require("selection")
local input_lock = require("input_lock")
local json = require("json")

-- New modular architecture (Phase 1-4)
local constants = require("core/constants")
local state = require("core/state")
local registry = require("core/registry")
local behaviors = require("core/behaviors")
local colors = require("data/colors")
local dictionaries = require("data/dictionaries")
local tags = require("data/tags")
local utils = require("lib/utils")
local behavior_panels = require("ui/behavior_panels")
local symbol_grid = require("ui/symbol_grid")
local right_column = require("ui/right_column")
local preview = require("features/preview")
local export_module = require("features/export")

-- ============================================================================
-- Local State Variables
-- ============================================================================

local dialog = nil
local current_dialog_vb = nil
local current_symbol_index = 0
local ui_collapsed = false
local right_column_collapsed = false
local current_formatted_labels = {}
local input_lock_active = false
local symbol_button_refs = {}
local tool_initialized = false

-- View toggles (UI state - these control dialog appearance)
local category_view_enabled = false
local organize_view_enabled = false
local detailed_view_enabled = false
local expanded_symbol = nil
local dictionary_view_enabled = false
local label_view_enabled = false

-- Tag/color editing states (track unsaved UI inputs)
local tag_editing_states = {}
local color_editing_states = {}

-- Forward declarations
local commit_to_phrase
local add_composite_symbol

-- ============================================================================
-- Module Aliases (for convenience)
-- ============================================================================

local composite_symbols = constants.composite_symbols
local available_symbols = constants.available_symbols
local overflow_behavior = constants.overflow_behavior
local overwrite_behavior = constants.overwrite_behavior
local instrument_source_behavior = constants.instrument_source_behavior
local multi_track_distance_mode = constants.multi_track_distance_mode
local color_definitions = colors.definitions
local color_dropdown_items = colors.dropdown_items

-- Registry reference (kept in sync with registry module)
-- Note: Direct mutations to this table require calling registry.save() afterward
local global_symbol_registry = registry.get()

-- ============================================================================
-- Preferences (handled by core/state.lua module)
-- ============================================================================
-- Note: Preferences are now managed by the state module.
-- The following functions delegate to the state module for backward compatibility.

-- Preference accessor functions for labeler module (delegating to state)
function get_custom_labels_data()
    return state.get_custom_labels_data()
end

function save_custom_labels_data(data)
    state.save_custom_labels_data(data)
end

function get_show_label2()
    return state.get_show_label2()
end

function save_show_label2(value)
    state.save_show_label2(value)
end

function get_show_advanced_data()
    return state.get_show_advanced_data()
end

function save_show_advanced_data(value)
    state.save_show_advanced_data(value)
end

-- Pagination state (delegating to symbol_grid module)
local symbol_pagination = {
    current_page = 1,
    symbols_per_page = 12,
    total_pages = 1
}

-- Audio preview state (delegating to preview module)
local preview_state = preview.get_state()

-- Serialize table function (now in utils module)
local function serialize_table(t, indent)
    return utils.serialize_table(t, indent)
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
        local dict_names = dictionaries.get_all_names()
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
                local dict_data = dictionaries.get(dict_name)
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
                            dictionaries.set_color(dict_name, color_dropdown_items[new_index])
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
                                local success, err = dictionaries.rename(dict_name, new_name)
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
                                dictionaries.delete(dict_name)
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
                        local success, err = dictionaries.create(name, color, "")
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
    local BOX_TL = string.char(0xE2, 0x95, 0x94)  -- ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â‚¬Å¾Ã‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€šÃ‚Â ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¾Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Â¦Ãƒâ€šÃ‚Â¡ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â‚¬Å¾Ã‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â¦ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¡ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Â¦Ãƒâ€šÃ‚Â¡ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â‚¬Å¾Ã‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â¦ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¡ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Â¦Ãƒâ€šÃ‚Â¡ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â
    local BOX_TR = string.char(0xE2, 0x95, 0x97)  -- ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â‚¬Å¾Ã‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€šÃ‚Â ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¾Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Â¦Ãƒâ€šÃ‚Â¡ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â‚¬Å¾Ã‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â¦ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¡ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Â¦Ãƒâ€šÃ‚Â¡ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â‚¬Å¾Ã‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â¦ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¡ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Â¦Ãƒâ€šÃ‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â
    local BOX_H = string.char(0xE2, 0x95, 0x90)   -- ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â‚¬Å¾Ã‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€šÃ‚Â ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¾Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Â¦Ãƒâ€šÃ‚Â¡ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â‚¬Å¾Ã‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â¦ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¡ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Â¦Ãƒâ€šÃ‚Â¡ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â‚¬Å¾Ã‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â¦ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¡ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Â¦Ãƒâ€šÃ‚Â¡ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â
    local BOX_V = string.char(0xE2, 0x94, 0x82)   -- ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â‚¬Å¾Ã‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€šÃ‚Â ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¾Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Â¦Ãƒâ€šÃ‚Â¡ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â‚¬Å¾Ã‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â¦ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¡ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Â¦Ãƒâ€šÃ‚Â¡ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚ÂÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â‚¬Å¾Ã‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â¦ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¡ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¦ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¡
    local BOX_LT = string.char(0xE2, 0x94, 0x9C)  -- ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â‚¬Å¾Ã‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€šÃ‚Â ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¾Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Â¦Ãƒâ€šÃ‚Â¡ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â‚¬Å¾Ã‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â¦ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¡ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Â¦Ãƒâ€šÃ‚Â¡ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚ÂÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â‚¬Å¾Ã‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¦ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Â¦Ãƒâ€šÃ‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€šÃ‚Â¦ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Â¦ÃƒÂ¢Ã¢â€šÂ¬Ã…â€œ
    local BOX_RT = string.char(0xE2, 0x94, 0xA4)  -- ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â‚¬Å¾Ã‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€šÃ‚Â ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¾Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Â¦Ãƒâ€šÃ‚Â¡ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â‚¬Å¾Ã‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â¦ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¡ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Â¦Ãƒâ€šÃ‚Â¡ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚ÂÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â‚¬Å¾Ã‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â¦ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¡ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Â¦Ãƒâ€šÃ‚Â¡ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¤
    local BOX_HL = string.char(0xE2, 0x94, 0x80)  -- ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â‚¬Å¾Ã‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€šÃ‚Â ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¾Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Â¦Ãƒâ€šÃ‚Â¡ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â‚¬Å¾Ã‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â¦ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¡ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Â¦Ãƒâ€šÃ‚Â¡ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚ÂÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â‚¬Å¾Ã‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Â¦Ãƒâ€šÃ‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€šÃ‚Â¦ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¡ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Â¦Ãƒâ€šÃ‚Â¡ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬
    
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

-- Toggle label view and refresh dialog
function toggle_label_view(vb)
    label_view_enabled = not label_view_enabled
    
    -- Update toggle button text
    if vb.views.label_toggle then
        vb.views.label_toggle.text = label_view_enabled and "Label*" or "Label"
    end
    
    -- Refresh dialog to rebuild with new view state
    if dialog and dialog.visible then
        dialog:close()
        show_main_dialog()
    end
    
    print("DEBUG: Label view toggled to " .. (label_view_enabled and "enabled" or "disabled"))
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
        
        -- Advanced data fields
        note_info.location = (label_data and label_data.location) or "Off-Center"
        note_info.ghost = (label_data and label_data.ghost) or false
        note_info.counterstroke = (label_data and label_data.counterstroke) or false
        note_info.cycle = (label_data and label_data.cycle) or false
        
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
    local show_advanced_data = get_show_advanced_data()
    
    local column_width = 100
    local narrow_column = 50
    local spacing = 5
    local preview_column_width = 22  -- Phase 6: Preview column
    local location_column_width = 80
    local checkbox_column_width = 50
    
    -- Function to rebuild the dialog when toggles change
    local function rebuild_dialog()
        labeler.stop_slice_preview()
        if capture_dialog and capture_dialog.visible then
            capture_dialog:close()
        end
        show_capture_with_labels_dialog(unique_notes_list, notes, sel_data)
    end
    
    -- Build header elements dynamically
    local header_elements = {
        capture_vb:text { text = "", width = preview_column_width, align = "center" },  -- Preview column header
        capture_vb:text { text = "Inst", width = narrow_column, font = "bold", align = "center" },
        capture_vb:text { text = "Note", width = narrow_column, font = "bold", align = "center" },
        capture_vb:text { text = "Label", width = column_width, font = "bold", align = "center" }
    }
    
    -- Add Label 2 toggle and column
    if show_label2 then
        table.insert(header_elements, capture_vb:button {
            text = "[-]",
            width = 25,
            tooltip = "Hide Label 2 column",
            notifier = function()
                save_show_label2(false)
                rebuild_dialog()
            end
        })
        table.insert(header_elements, capture_vb:text { text = "Label 2", width = column_width, font = "bold", align = "center" })
    else
        table.insert(header_elements, capture_vb:button {
            text = "[+]",
            width = 25,
            tooltip = "Show Label 2 column",
            notifier = function()
                save_show_label2(true)
                rebuild_dialog()
            end
        })
    end
    
    -- Add Status column
    table.insert(header_elements, capture_vb:text { text = "Status", width = 80, font = "bold", align = "center" })
    
    -- Add Advanced Data toggle
    table.insert(header_elements, capture_vb:button {
        text = show_advanced_data and "Adv [-]" or "Adv [+]",
        width = 50,
        tooltip = show_advanced_data and "Hide Advanced Data columns" or "Show Advanced Data columns",
        notifier = function()
            save_show_advanced_data(not show_advanced_data)
            rebuild_dialog()
        end
    })
    
    -- Add Advanced Data columns if enabled
    if show_advanced_data then
        table.insert(header_elements, capture_vb:text { text = "Location", width = location_column_width, font = "bold", align = "center" })
        table.insert(header_elements, capture_vb:text { text = "Ghost", width = checkbox_column_width, font = "bold", align = "center" })
        table.insert(header_elements, capture_vb:text { text = "CStroke", width = checkbox_column_width, font = "bold", align = "center" })
        table.insert(header_elements, capture_vb:text { text = "Cycle", width = checkbox_column_width, font = "bold", align = "center" })
    end
    
    -- Build header row
    local header_row = capture_vb:row { spacing = spacing }
    for _, element in ipairs(header_elements) do
        header_row:add_child(element)
    end
    
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
        
        -- Header row
        header_row
    }
    
    -- Add rows for each unique note
    for i, note_info in ipairs(unique_notes_list) do
        local status_text = note_info.has_existing_label and "(auto-filled)" or "(no label)"
        local status_style = note_info.has_existing_label and "normal" or "disabled"
        
        -- Phase 6: Create preview button ID
        local preview_button_id = "capture_preview_" .. i
        
        local row_elements = {
            -- Phase 6: Preview button
            capture_vb:button {
                id = preview_button_id,
                text = "ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Å“Ãƒâ€šÃ‚Â¸",
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
            }
        }
        
        -- Spacer for Label 2 toggle button
        table.insert(row_elements, capture_vb:space { width = 25 })
        
        -- Label 2 dropdown (if enabled)
        if show_label2 then
            table.insert(row_elements, capture_vb:popup {
                id = "label2_" .. i,
                items = label_options,
                width = column_width,
                value = table.find(label_options, note_info.label2) or 1
            })
        end
        
        -- Status
        table.insert(row_elements, capture_vb:text {
            text = status_text,
            width = 80,
            style = status_style
        })
        
        -- Spacer for Advanced Data toggle button
        table.insert(row_elements, capture_vb:space { width = 50 })
        
        -- Advanced Data fields (when enabled)
        if show_advanced_data then
            -- Location dropdown
            table.insert(row_elements, capture_vb:popup {
                id = "location_" .. i,
                items = labeler.location_options,
                width = location_column_width,
                value = table.find(labeler.location_options, note_info.location) or 1
            })
            
            -- Ghost checkbox
            table.insert(row_elements, capture_vb:horizontal_aligner {
                mode = "center",
                width = checkbox_column_width,
                capture_vb:checkbox {
                    id = "ghost_" .. i,
                    value = note_info.ghost
                }
            })
            
            -- Counterstroke checkbox
            table.insert(row_elements, capture_vb:horizontal_aligner {
                mode = "center",
                width = checkbox_column_width,
                capture_vb:checkbox {
                    id = "counterstroke_" .. i,
                    value = note_info.counterstroke
                }
            })
            
            -- Cycle checkbox
            table.insert(row_elements, capture_vb:horizontal_aligner {
                mode = "center",
                width = checkbox_column_width,
                capture_vb:checkbox {
                    id = "cycle_" .. i,
                    value = note_info.cycle
                }
            })
        end
        
        -- Build row from elements
        local row = capture_vb:row { spacing = spacing }
        for _, element in ipairs(row_elements) do
            row:add_child(element)
        end
        
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
                    local current_show_advanced_data = get_show_advanced_data()
                    
                    for i, note_info in ipairs(unique_notes_list) do
                        local label_popup = capture_vb.views["label_" .. i]
                        local label2_popup = capture_vb.views["label2_" .. i]
                        
                        note_info.label = label_popup.items[label_popup.value]
                        note_info.label2 = show_label2 and label2_popup and label2_popup.items[label2_popup.value] or "---------"
                        
                        -- Collect advanced data values
                        local location_value = note_info.location or "Off-Center"
                        local ghost_value = note_info.ghost or false
                        local counterstroke_value = note_info.counterstroke or false
                        local cycle_value = note_info.cycle or false
                        
                        if current_show_advanced_data then
                            local location_popup = capture_vb.views["location_" .. i]
                            local ghost_field = capture_vb.views["ghost_" .. i]
                            local counterstroke_field = capture_vb.views["counterstroke_" .. i]
                            local cycle_field = capture_vb.views["cycle_" .. i]
                            
                            if location_popup then
                                location_value = labeler.location_options[location_popup.value]
                            end
                            if ghost_field then
                                ghost_value = ghost_field.value
                            end
                            if counterstroke_field then
                                counterstroke_value = counterstroke_field.value
                            end
                            if cycle_field then
                                cycle_value = cycle_field.value
                            end
                        end
                        
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
                            note_value = note_info.note_value,
                            location = location_value,
                            ghost = ghost_value,
                            counterstroke = counterstroke_value,
                            cycle = cycle_value
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
-- Audio Preview Functions (use preview module)
-- ============================================================================

function stop_symbol_preview()
    preview.stop()
end

function preview_symbol(symbol_name)
    return preview.play_symbol(symbol_name)
end

function preview_sample_direct(instrument_index, sample_index, note_value, volume)
    return preview.play_sample(instrument_index, sample_index, note_value, volume)
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
-- ============================================================================
-- Load/Save Global Symbol Registry (delegated to registry module)
-- ============================================================================

function load_global_symbol_registry()
    registry.load()
    -- Update local reference during transition
    global_symbol_registry = registry.get()
    -- Initialize tag editing states
    tags.initialize_editing_states()
end

function save_global_symbol_registry()
    -- Update registry module from local reference during transition
    registry.set(global_symbol_registry)
    registry.save()
end

-- ============================================================================
-- Export/Import Functions (use export_module)
-- ============================================================================

function export_global_alphabet_csv()
    export_module.prompt_csv()
end

function export_global_alphabet_json()
    export_module.prompt_json()
end

function import_global_alphabet_json()
    export_module.prompt_import_json()
end

-- Show format selection dialog for export
function export_global_alphabet()
    local vb = renoise.ViewBuilder()
    local format_dialog = nil
    
    local dialog_content = vb:column {
        margin = 10,
        spacing = 10,
        
        vb:text {
            text = "Export Global Alphabet",
            font = "big",
            style = "strong"
        },
        
        vb:text {
            text = "Select export format:"
        },
        
        vb:row {
            spacing = 10,
            
            vb:button {
                text = "CSV",
                width = 80,
                notifier = function()
                    if format_dialog then format_dialog:close() end
                    export_module.prompt_csv()
                end
            },
            
            vb:button {
                text = "JSON",
                width = 80,
                notifier = function()
                    if format_dialog then format_dialog:close() end
                    export_module.prompt_json()
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

-- Show format selection dialog for import
function import_global_alphabet()
    local vb = renoise.ViewBuilder()
    local format_dialog = nil
    
    local function do_import_and_refresh(import_func)
        local success = import_func()
        if success then
            -- Update local registry reference
            global_symbol_registry = registry.get()
            -- Refresh the main dialog to show new symbols
            if dialog and dialog.visible then
                dialog:close()
                show_main_dialog()
            end
        end
    end
    
    local dialog_content = vb:column {
        margin = 10,
        spacing = 10,
        
        vb:text {
            text = "Import Global Alphabet",
            font = "big",
            style = "strong"
        },
        
        vb:text {
            text = "Select import format:"
        },
        
        vb:row {
            spacing = 10,
            
            vb:button {
                text = "CSV",
                width = 80,
                notifier = function()
                    if format_dialog then format_dialog:close() end
                    do_import_and_refresh(export_module.prompt_import_csv)
                end
            },
            
            vb:button {
                text = "JSON",
                width = 80,
                notifier = function()
                    if format_dialog then format_dialog:close() end
                    do_import_and_refresh(export_module.prompt_import_json)
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

-- Compact behavior panel functions (use behavior_panels module)
local function create_compact_overflow_section(vb)
    return behavior_panels.create_compact_overflow(vb)
end

local function create_compact_overwrite_section(vb)
    return behavior_panels.create_compact_overwrite(vb)
end

local function create_compact_instrument_source_section(vb)
    return behavior_panels.create_compact_instrument_source(vb)
end

local function create_compact_multi_track_distance_section(vb)
    return behavior_panels.create_compact_multi_track_distance(vb)
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
    
    -- Sync checkbox states between compact and expanded views
    if ui_collapsed then
        -- Switching to compact view - update compact checkboxes to match current state
        
        -- Overflow behavior
        if vb.views.compact_overflow_extend then
            vb.views.compact_overflow_extend.value = (behaviors.is_overflow_extend())
        end
        if vb.views.compact_overflow_next then
            vb.views.compact_overflow_next.value = (behaviors.is_overflow_next_pattern())
        end
        if vb.views.compact_overflow_truncate then
            vb.views.compact_overflow_truncate.value = (behaviors.is_overflow_truncate())
        end
        if vb.views.compact_overflow_loop then
            vb.views.compact_overflow_loop.value = (behaviors.is_overflow_loop())
        end
        
        -- Overwrite behavior
        if vb.views.compact_overwrite_sum then
            vb.views.compact_overwrite_sum.value = (behaviors.is_overwrite_sum())
        end
        if vb.views.compact_overwrite_replace then
            vb.views.compact_overwrite_replace.value = (behaviors.is_overwrite_replace())
        end
        if vb.views.compact_overwrite_substitute then
            vb.views.compact_overwrite_substitute.value = (behaviors.is_overwrite_substitute())
        end
        if vb.views.compact_overwrite_retain then
            vb.views.compact_overwrite_retain.value = (behaviors.is_overwrite_retain())
        end
        if vb.views.compact_overwrite_exclude then
            vb.views.compact_overwrite_exclude.value = (behaviors.is_overwrite_exclude())
        end
        if vb.views.compact_overwrite_intersect then
            vb.views.compact_overwrite_intersect.value = (behaviors.is_overwrite_intersect())
        end
        
        -- Instrument source behavior
        if vb.views.compact_instrument_source_embedded then
            vb.views.compact_instrument_source_embedded.value = (behaviors.is_instrument_source_embedded())
        end
        if vb.views.compact_instrument_source_current then
            vb.views.compact_instrument_source_current.value = (behaviors.is_instrument_source_current())
        end
        
        -- Multi-track distance mode
        if vb.views.compact_mt_sync_first then
            vb.views.compact_mt_sync_first.value = (behaviors.is_multi_track_sync_first())
        end
        if vb.views.compact_mt_independent then
            vb.views.compact_mt_independent.value = (behaviors.is_multi_track_independent())
        end
        if vb.views.compact_mt_sync_last then
            vb.views.compact_mt_sync_last.value = (behaviors.is_multi_track_sync_last())
        end
        if vb.views.compact_mt_skip_blank then
            vb.views.compact_mt_skip_blank.value = behaviors.get_ignore_blank_tracks()
        end
    else
        -- Switching to expanded view - update expanded checkboxes to match current state
        
        -- Overflow behavior
        if vb.views.overflow_extend then
            vb.views.overflow_extend.value = (behaviors.is_overflow_extend())
        end
        if vb.views.overflow_next_pattern then
            vb.views.overflow_next_pattern.value = (behaviors.is_overflow_next_pattern())
        end
        if vb.views.overflow_truncate then
            vb.views.overflow_truncate.value = (behaviors.is_overflow_truncate())
        end
        if vb.views.overflow_loop then
            vb.views.overflow_loop.value = (behaviors.is_overflow_loop())
        end
        
        -- Overwrite behavior
        if vb.views.overwrite_sum then
            vb.views.overwrite_sum.value = (behaviors.is_overwrite_sum())
        end
        if vb.views.overwrite_replace then
            vb.views.overwrite_replace.value = (behaviors.is_overwrite_replace())
        end
        if vb.views.overwrite_substitute then
            vb.views.overwrite_substitute.value = (behaviors.is_overwrite_substitute())
        end
        if vb.views.overwrite_retain then
            vb.views.overwrite_retain.value = (behaviors.is_overwrite_retain())
        end
        if vb.views.overwrite_exclude then
            vb.views.overwrite_exclude.value = (behaviors.is_overwrite_exclude())
        end
        if vb.views.overwrite_intersect then
            vb.views.overwrite_intersect.value = (behaviors.is_overwrite_intersect())
        end
        
        -- Instrument source behavior
        if vb.views.instrument_source_embedded then
            vb.views.instrument_source_embedded.value = (behaviors.is_instrument_source_embedded())
        end
        if vb.views.instrument_source_current then
            vb.views.instrument_source_current.value = (behaviors.is_instrument_source_current())
        end
        
        -- Multi-track distance mode
        if vb.views.mt_sync_first then
            vb.views.mt_sync_first.value = (behaviors.is_multi_track_sync_first())
        end
        if vb.views.mt_independent then
            vb.views.mt_independent.value = (behaviors.is_multi_track_independent())
        end
        if vb.views.mt_sync_last then
            vb.views.mt_sync_last.value = (behaviors.is_multi_track_sync_last())
        end
        if vb.views.mt_ignore_blank_tracks then
            vb.views.mt_ignore_blank_tracks.value = behaviors.get_ignore_blank_tracks()
        end
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
    if label_view_enabled then width_padding = width_padding + 10 end
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
    print("DEBUG: calculate_right_column_width() -> " .. final_width .. " (padding=" .. width_padding .. ", tag=" .. tostring(category_view_enabled) .. ", org=" .. tostring(organize_view_enabled) .. ", info=" .. tostring(detailed_view_enabled) .. ", label=" .. tostring(label_view_enabled) .. ", expanded=" .. tostring(expanded_symbol) .. ", dict=" .. tostring(dictionary_view_enabled) .. ")")
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
            local symbol_dictionary = dictionaries.get_for_symbol(symbol)
            if symbol_dictionary then
                local dict_data = dictionaries.get(symbol_dictionary)
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
                                    value = (behaviors.is_overflow_extend()),
                                    notifier = function(value)
                                        if value then
                                            behaviors.set_overflow(overflow_behavior.EXTEND)
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
                                    value = (behaviors.is_overflow_next_pattern()),
                                    notifier = function(value)
                                        if value then
                                            behaviors.set_overflow(overflow_behavior.NEXT_PATTERN)
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
                                    value = (behaviors.is_overflow_truncate()),
                                    notifier = function(value)
                                        if value then
                                            behaviors.set_overflow(overflow_behavior.TRUNCATE)
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
                                    value = (behaviors.is_overflow_loop()),
                                    notifier = function(value)
                                        if value then
                                            behaviors.set_overflow(overflow_behavior.LOOP)
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
                                    value = (behaviors.is_overflow_insert()),
                                    notifier = function(value)
                                        if value then
                                            behaviors.set_overflow(overflow_behavior.INSERT)
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
                                        value = (behaviors.is_overwrite_sum()),
                                        notifier = function(value)
                                            if value then
                                                behaviors.set_overwrite(overwrite_behavior.SUM)
                                                vb.views.overwrite_replace.value = false
                                                vb.views.overwrite_substitute.value = false
                                                vb.views.overwrite_retain.value = false
                                                vb.views.overwrite_exclude.value = false
                                                vb.views.overwrite_intersect.value = false
                                            elseif behaviors.is_overwrite_sum() then
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
                                        value = (behaviors.is_overwrite_replace()),
                                        notifier = function(value)
                                            if value then
                                                behaviors.set_overwrite(overwrite_behavior.REPLACE)
                                                vb.views.overwrite_sum.value = false
                                                vb.views.overwrite_substitute.value = false
                                                vb.views.overwrite_retain.value = false
                                                vb.views.overwrite_exclude.value = false
                                                vb.views.overwrite_intersect.value = false
                                            elseif behaviors.is_overwrite_replace() then
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
                                        value = (behaviors.is_overwrite_substitute()),
                                        notifier = function(value)
                                            if value then
                                                behaviors.set_overwrite(overwrite_behavior.SUBSTITUTE)
                                                vb.views.overwrite_sum.value = false
                                                vb.views.overwrite_replace.value = false
                                                vb.views.overwrite_retain.value = false
                                                vb.views.overwrite_exclude.value = false
                                                vb.views.overwrite_intersect.value = false
                                            elseif behaviors.is_overwrite_substitute() then
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
                                        value = (behaviors.is_overwrite_retain()),
                                        notifier = function(value)
                                            if value then
                                                behaviors.set_overwrite(overwrite_behavior.RETAIN)
                                                vb.views.overwrite_sum.value = false
                                                vb.views.overwrite_replace.value = false
                                                vb.views.overwrite_substitute.value = false
                                                vb.views.overwrite_exclude.value = false
                                                vb.views.overwrite_intersect.value = false
                                            elseif behaviors.is_overwrite_retain() then
                                                vb.views.overwrite_retain.value = true
                                            end
                                        end
                                    },
                                    vb:text {
                                        text = "Preserve",
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
                                        value = (behaviors.is_overwrite_exclude()),
                                        notifier = function(value)
                                            if value then
                                                behaviors.set_overwrite(overwrite_behavior.EXCLUDE)
                                                vb.views.overwrite_sum.value = false
                                                vb.views.overwrite_replace.value = false
                                                vb.views.overwrite_substitute.value = false
                                                vb.views.overwrite_retain.value = false
                                                vb.views.overwrite_intersect.value = false
                                            elseif behaviors.is_overwrite_exclude() then
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
                                        value = (behaviors.is_overwrite_intersect()),
                                        notifier = function(value)
                                            if value then
                                                behaviors.set_overwrite(overwrite_behavior.INTERSECT)
                                                vb.views.overwrite_sum.value = false
                                                vb.views.overwrite_replace.value = false
                                                vb.views.overwrite_substitute.value = false
                                                vb.views.overwrite_retain.value = false
                                                vb.views.overwrite_exclude.value = false
                                            elseif behaviors.is_overwrite_intersect() then
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
                                value = (behaviors.is_instrument_source_embedded()),
                                notifier = function(value)
                                    if value then
                                        behaviors.set_instrument_source(instrument_source_behavior.EMBEDDED)
                                        vb.views.instrument_source_current.value = false
                                    elseif behaviors.is_instrument_source_embedded() then
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
                                value = (behaviors.is_instrument_source_current()),
                                notifier = function(value)
                                    if value then
                                        behaviors.set_instrument_source(instrument_source_behavior.CURRENT_SELECTED)
                                        vb.views.instrument_source_embedded.value = false
                                    elseif behaviors.is_instrument_source_current() then
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

                -- Phase 5: Multi-track settings section (collapsible)
                vb:column {
                    id = "multi_track_distance_section",
                    visible = not ui_collapsed,
                    style = "group",
                    margin = 10,
                    width = 430,
                    vb:text {
                        text = "Multi-Track Settings",
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
                                value = (behaviors.is_multi_track_sync_first()),
                                notifier = function(value)
                                    if value then
                                        behaviors.set_multi_track_distance_mode(multi_track_distance_mode.SYNC_FIRST)
                                        vb.views.mt_independent.value = false
                                        vb.views.mt_sync_last.value = false
                                    elseif behaviors.is_multi_track_sync_first() then
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
                                value = (behaviors.is_multi_track_independent()),
                                notifier = function(value)
                                    if value then
                                        behaviors.set_multi_track_distance_mode(multi_track_distance_mode.INDEPENDENT)
                                        vb.views.mt_sync_first.value = false
                                        vb.views.mt_sync_last.value = false
                                    elseif behaviors.is_multi_track_independent() then
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
                                value = (behaviors.is_multi_track_sync_last()),
                                notifier = function(value)
                                    if value then
                                        behaviors.set_multi_track_distance_mode(multi_track_distance_mode.SYNC_LAST)
                                        vb.views.mt_sync_first.value = false
                                        vb.views.mt_independent.value = false
                                    elseif behaviors.is_multi_track_sync_last() then
                                        vb.views.mt_sync_last.value = true
                                    end
                                end
                            },
                            vb:text {
                                text = "Sync to Last (longest cutoff, no extra notes)",
                                width = 350
                            }
                        },
                        vb:space { height = 5 },
                        vb:row {
                            spacing = 10,
                            vb:checkbox {
                                id = "mt_ignore_blank_tracks",
                                value = behaviors.get_ignore_blank_tracks(),
                                notifier = function(value)
                                    behaviors.set_ignore_blank_tracks(value)
                                end
                            },
                            vb:text {
                                text = "Skip Blank Tracks at Capture",
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
                        },
                        vb:button {
                            id = "label_toggle",
                            text = label_view_enabled and "Label*" or "Label",
                            width = 40,
                            height = 22,
                            tooltip = "Toggle label view - edit labels and breakpoints per symbol",
                            notifier = function()
                                toggle_label_view(vb)
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
                            symbols_to_display = dictionaries.get_symbols_ordered()
                        else
                            -- Standard alphabet order
                            local all_symbols = {"A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9"}
                            symbols_to_display = {}
                            for _, s in ipairs(all_symbols) do
                                table.insert(symbols_to_display, {symbol = s, dictionary = dictionaries.get_for_symbol(s)})
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
                        if label_view_enabled then
                            width_padding = width_padding + 10  -- Extra for label button
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
                                            local dict_data = dictionaries.get(symbol_dictionary)
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
                                        
                                        -- Label view: Label button (only in label mode)
                                        local label_button = vb:button {
                                            text = "L",
                                            width = 20,
                                            height = 25,
                                            tooltip = "Edit labels and breakpoints for symbol " .. symbol,
                                            visible = label_view_enabled,
                                            notifier = function()
                                                -- Open symbol labeler dialog
                                                labeler.show_symbol_labeler(symbol, function()
                                                    -- Callback after save - refresh the dialog
                                                    if dialog and dialog.visible then
                                                        dialog:close()
                                                        show_main_dialog()
                                                    end
                                                end)
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
                                                    expand_button,
                                                    label_button
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
                                                items = registry.get_available_for_moving(symbol),
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
                                                        local success, err = registry.move_symbol(symbol, target_symbol, tag_editing_states, color_editing_states)
                                                        if success then
                                                            -- Clear local button reference
                                                            symbol_button_refs[symbol] = nil
                                                            renoise.app():show_status("Symbol " .. symbol .. " moved to " .. target_symbol)
                                                            -- Preserve unsaved tag inputs before refresh
                                                            if current_dialog_vb then
                                                                preserve_unsaved_tag_inputs(nil, current_dialog_vb)
                                                            end
                                                            -- Refresh dialog to show new positions
                                                            if dialog and dialog.visible then
                                                                dialog:close()
                                                                show_main_dialog()
                                                            end
                                                        else
                                                            renoise.app():show_warning(err or "Move failed")
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
                                                    local dict_names = dictionaries.get_all_names()
                                                    for _, name in ipairs(dict_names) do
                                                        table.insert(items, name)
                                                    end
                                                    return items
                                                end)(),
                                                value = (function()
                                                    local current_dict = dictionaries.get_for_symbol(symbol)
                                                    if current_dict then
                                                        local dict_names = dictionaries.get_all_names()
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
                                                        dictionaries.remove_symbol(symbol)
                                                    else
                                                        local dict_names = dictionaries.get_all_names()
                                                        local selected_dict = dict_names[new_value - 1]
                                                        if selected_dict then
                                                            dictionaries.add_symbol(symbol, selected_dict)
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
        dictionaries.load()  -- Phase 4: Load dictionaries after registry
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
    editor.set_main_module_functions(
        behaviors.get_overflow, 
        behaviors.get_overflow_constants, 
        behaviors.get_overwrite, 
        behaviors.get_overwrite_constants, 
        behaviors.get_instrument_source, 
        behaviors.get_instrument_source_constants, 
        registry.get, 
        registry.get_instrument_index, 
        behaviors.get_multi_track_distance_mode, 
        behaviors.get_multi_track_distance_mode_constants
    )

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

-- Set up labeler callback to refresh main dialog and provide global symbol functions
labeler.set_refresh_callback(safe_labeler_refresh)
labeler.set_global_symbol_functions(
    registry.get, 
    registry.assign_to_instrument, 
    registry.save,
    state.get_custom_labels_data,
    state.save_custom_labels_data,
    state.get_show_label2,
    state.save_show_label2,
    state.get_show_advanced_data,
    state.save_show_advanced_data
)
-- Set preview symbol callback for symbol labeler
labeler.set_preview_symbol_callback(preview.play_symbol)

-- Set up selection module functions
selection.set_global_symbol_functions(registry.get, registry.find_next_available, registry.save)
-- Phase 5: Set multi-track distance mode functions for selection module
selection.set_multi_track_mode_functions(behaviors.get_multi_track_distance_mode, behaviors.get_multi_track_distance_mode_constants)
-- Set ignore blank tracks function for selection module
selection.set_ignore_blank_tracks_function(behaviors.get_ignore_blank_tracks)

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