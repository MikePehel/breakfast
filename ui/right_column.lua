-- ui/right_column.lua - Right Column View Management for BreakFast
local right_column = {}

-- Dependencies
local state = require("core/state")
local symbol_grid = require("ui/symbol_grid")

-- ============================================================================
-- View Mode State
-- ============================================================================
-- These control which optional UI elements are shown in the symbol grid

local view_modes = {
    category = false,    -- Tag editing view
    organize = false,    -- Organize view (move, delete, dictionary assign)
    detailed = false,    -- Detailed info view
    dictionary = false,  -- Dictionary grouping view
    label = false        -- Label editing view
}

-- Collapse state
local collapsed = false

-- Expanded symbol for detailed view
local expanded_symbol = nil

-- ============================================================================
-- View Mode Accessors
-- ============================================================================

function right_column.is_category_view_enabled()
    return view_modes.category
end

function right_column.set_category_view_enabled(enabled)
    view_modes.category = enabled
end

function right_column.is_organize_view_enabled()
    return view_modes.organize
end

function right_column.set_organize_view_enabled(enabled)
    view_modes.organize = enabled
end

function right_column.is_detailed_view_enabled()
    return view_modes.detailed
end

function right_column.set_detailed_view_enabled(enabled)
    view_modes.detailed = enabled
end

function right_column.is_dictionary_view_enabled()
    return view_modes.dictionary
end

function right_column.set_dictionary_view_enabled(enabled)
    view_modes.dictionary = enabled
end

function right_column.is_label_view_enabled()
    return view_modes.label
end

function right_column.set_label_view_enabled(enabled)
    view_modes.label = enabled
end

-- Get all view modes as a table
function right_column.get_view_modes()
    return {
        category = view_modes.category,
        organize = view_modes.organize,
        detailed = view_modes.detailed,
        dictionary = view_modes.dictionary,
        label = view_modes.label
    }
end

-- ============================================================================
-- Collapse State
-- ============================================================================

function right_column.is_collapsed()
    return collapsed
end

function right_column.set_collapsed(value)
    collapsed = value
end

function right_column.toggle_collapsed()
    collapsed = not collapsed
    return collapsed
end

-- ============================================================================
-- Expanded Symbol (for detailed view)
-- ============================================================================

function right_column.get_expanded_symbol()
    return expanded_symbol
end

function right_column.set_expanded_symbol(symbol)
    expanded_symbol = symbol
end

function right_column.clear_expanded_symbol()
    expanded_symbol = nil
end

function right_column.toggle_expanded_symbol(symbol)
    if expanded_symbol == symbol then
        expanded_symbol = nil
    else
        expanded_symbol = symbol
    end
    return expanded_symbol
end

-- ============================================================================
-- Width Calculations
-- ============================================================================

function right_column.calculate_width()
    if collapsed then
        return symbol_grid.calculate_compact_width()
    else
        return symbol_grid.calculate_grid_width(view_modes, expanded_symbol)
    end
end

-- ============================================================================
-- View Toggle Button Creation
-- ============================================================================

-- Create the view mode toggle buttons row
-- Parameters:
--   vb: ViewBuilder instance
--   callbacks: table with toggle callbacks for each view mode
function right_column.create_view_toggles(vb, callbacks)
    callbacks = callbacks or {}
    
    return vb:row {
        id = "view_toggles_row",
        visible = not collapsed,
        spacing = 2,
        
        vb:text {
            text = "View:",
            style = "disabled",
            width = 32
        },
        
        vb:button {
            id = "category_toggle",
            text = view_modes.category and "Tag*" or "Tag",
            width = 35,
            height = 22,
            tooltip = "Toggle tag editing view - add/edit tags for symbols",
            notifier = function()
                if callbacks.on_tag_toggle then
                    callbacks.on_tag_toggle()
                end
            end
        },
        
        vb:button {
            id = "organize_toggle",
            text = view_modes.organize and "Org*" or "Org",
            width = 35,
            height = 22,
            tooltip = "Toggle organize view - move, delete, assign dictionaries",
            notifier = function()
                if callbacks.on_organize_toggle then
                    callbacks.on_organize_toggle()
                end
            end
        },
        
        vb:button {
            id = "detailed_toggle",
            text = view_modes.detailed and "Info*" or "Info",
            width = 35,
            height = 22,
            tooltip = "Toggle detailed view - click symbols to expand details",
            notifier = function()
                if callbacks.on_detailed_toggle then
                    callbacks.on_detailed_toggle()
                end
            end
        },
        
        vb:button {
            id = "dictionary_toggle",
            text = view_modes.dictionary and "Dict*" or "Dict",
            width = 35,
            height = 22,
            tooltip = "Toggle dictionary view - group symbols by dictionary",
            notifier = function()
                if callbacks.on_dictionary_toggle then
                    callbacks.on_dictionary_toggle()
                end
            end
        },
        
        vb:button {
            id = "label_toggle",
            text = view_modes.label and "Label*" or "Label",
            width = 40,
            height = 22,
            tooltip = "Toggle label view - edit labels and breakpoints per symbol",
            notifier = function()
                if callbacks.on_label_toggle then
                    callbacks.on_label_toggle()
                end
            end
        }
    }
end

-- ============================================================================
-- Collapse Button Creation
-- ============================================================================

-- Create the collapse toggle button
function right_column.create_collapse_button(vb, on_toggle)
    return vb:horizontal_aligner {
        mode = "right",
        vb:button {
            id = "right_collapse_button",
            text = collapsed and "+" or "-",
            width = 25,
            height = 22,
            tooltip = collapsed and "Expand symbol grid" or "Collapse symbol grid",
            notifier = function()
                if on_toggle then
                    on_toggle()
                end
            end
        }
    }
end

-- ============================================================================
-- Header Row Creation
-- ============================================================================

-- Create the complete header row (view toggles + collapse button)
function right_column.create_header_row(vb, callbacks)
    return vb:row {
        spacing = 3,
        right_column.create_view_toggles(vb, callbacks),
        right_column.create_collapse_button(vb, callbacks.on_collapse_toggle)
    }
end

-- ============================================================================
-- Clear All Button Creation
-- ============================================================================

-- Create the "Clear All Symbols" button
function right_column.create_clear_all_button(vb, on_clear)
    return vb:horizontal_aligner {
        mode = "right",
        vb:button {
            text = "Clear All Symbols",
            width = 120,
            notifier = function()
                local result = renoise.app():show_prompt(
                    "Clear All Symbols",
                    "This will permanently clear all symbol assignments from the global registry.\n\nAre you sure you want to continue?",
                    {"Clear All", "Cancel"}
                )
                
                if result == "Clear All" then
                    if on_clear then
                        on_clear()
                    end
                end
            end
        }
    }
end

-- ============================================================================
-- Input Lock Indicator Creation
-- ============================================================================

-- Create compact input lock indicator
function right_column.create_compact_input_lock_indicator(vb, is_active)
    return vb:horizontal_aligner {
        mode = "center",
        vb:text {
            id = "compact_input_lock_indicator",
            text = is_active and "[-]" or "[O]",
            font = "bold",
            style = is_active and "strong" or "normal"
        }
    }
end

-- ============================================================================
-- UI Update Helpers
-- ============================================================================

-- Update view toggle button text based on current state
function right_column.update_toggle_button_text(vb)
    if vb.views.category_toggle then
        vb.views.category_toggle.text = view_modes.category and "Tag*" or "Tag"
    end
    if vb.views.organize_toggle then
        vb.views.organize_toggle.text = view_modes.organize and "Org*" or "Org"
    end
    if vb.views.detailed_toggle then
        vb.views.detailed_toggle.text = view_modes.detailed and "Info*" or "Info"
    end
    if vb.views.dictionary_toggle then
        vb.views.dictionary_toggle.text = view_modes.dictionary and "Dict*" or "Dict"
    end
    if vb.views.label_toggle then
        vb.views.label_toggle.text = view_modes.label and "Label*" or "Label"
    end
end

-- Update collapse button text
function right_column.update_collapse_button_text(vb)
    if vb.views.right_collapse_button then
        vb.views.right_collapse_button.text = collapsed and "+" or "-"
        vb.views.right_collapse_button.tooltip = collapsed and "Expand symbol grid" or "Collapse symbol grid"
    end
end

-- Update visibility of view toggles row
function right_column.update_toggles_visibility(vb)
    if vb.views.view_toggles_row then
        vb.views.view_toggles_row.visible = not collapsed
    end
end

-- Update visibility of full/compact content
function right_column.update_content_visibility(vb)
    if vb.views.right_full_content then
        vb.views.right_full_content.visible = not collapsed
    end
    if vb.views.right_compact_content then
        vb.views.right_compact_content.visible = collapsed
    end
end

-- Update container width
function right_column.update_container_width(vb)
    if vb.views.right_column_container then
        vb.views.right_column_container.width = right_column.calculate_width()
    end
end

-- Perform full collapse/expand UI update
function right_column.update_collapse_ui(vb)
    right_column.update_collapse_button_text(vb)
    right_column.update_toggles_visibility(vb)
    right_column.update_content_visibility(vb)
    right_column.update_container_width(vb)
end

-- ============================================================================
-- State Reset
-- ============================================================================

function right_column.reset()
    view_modes.category = false
    view_modes.organize = false
    view_modes.detailed = false
    view_modes.dictionary = false
    view_modes.label = false
    collapsed = false
    expanded_symbol = nil
end

return right_column
