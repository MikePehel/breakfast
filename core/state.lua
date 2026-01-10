-- core/state.lua - Preferences and UI State Management for BreakFast
local state = {}

-- ============================================================================
-- Preferences Document
-- ============================================================================
-- Create preferences document for persistent storage across sessions

local preferences = renoise.Document.create("BreakFastPreferences") {
    -- Global symbol registry (serialized Lua table as string)
    global_symbol_registry_data = "",
    -- User-defined custom labels (JSON array)
    custom_labels_data = "",
    -- Toggle state for Label 2 column visibility
    show_label2 = false,
    -- Toggle state for Advanced Data columns visibility
    show_advanced_data = false,
    -- Symbol dictionaries (serialized Lua table as string)
    symbol_dictionaries_data = ""
}

-- Register preferences with the tool
renoise.tool().preferences = preferences

-- ============================================================================
-- Preferences Accessors
-- ============================================================================

-- Custom labels data
function state.get_custom_labels_data()
    if preferences.custom_labels_data and preferences.custom_labels_data.value ~= "" then
        return preferences.custom_labels_data.value
    end
    return ""
end

function state.save_custom_labels_data(data)
    preferences.custom_labels_data.value = data
end

-- Show Label 2 column
function state.get_show_label2()
    if preferences.show_label2 then
        return preferences.show_label2.value
    end
    return false
end

function state.save_show_label2(value)
    if preferences.show_label2 then
        preferences.show_label2.value = value
    end
end

-- Show Advanced Data columns
function state.get_show_advanced_data()
    if preferences.show_advanced_data then
        return preferences.show_advanced_data.value
    end
    return false
end

function state.save_show_advanced_data(value)
    if preferences.show_advanced_data then
        preferences.show_advanced_data.value = value
    end
end

-- Global symbol registry data (raw string)
function state.get_global_symbol_registry_data()
    if preferences.global_symbol_registry_data and preferences.global_symbol_registry_data.value ~= "" then
        return preferences.global_symbol_registry_data.value
    end
    return ""
end

function state.save_global_symbol_registry_data(data)
    preferences.global_symbol_registry_data.value = data
end

-- Symbol dictionaries data (raw string)
function state.get_symbol_dictionaries_data()
    if preferences.symbol_dictionaries_data and preferences.symbol_dictionaries_data.value ~= "" then
        return preferences.symbol_dictionaries_data.value
    end
    return ""
end

function state.save_symbol_dictionaries_data(data)
    preferences.symbol_dictionaries_data.value = data
end

-- ============================================================================
-- UI State
-- ============================================================================
-- These are runtime states that don't persist across sessions

local ui_state = {
    -- Main dialog reference
    dialog = nil,
    -- Current ViewBuilder reference
    dialog_vb = nil,
    
    -- Collapse states
    ui_collapsed = false,
    right_column_collapsed = false,
    
    -- View toggle states
    category_view_enabled = false,  -- Tag view (kept name for compatibility)
    organize_view_enabled = false,
    detailed_view_enabled = false,
    dictionary_view_enabled = false,
    label_view_enabled = false,
    
    -- Detailed view tracking
    expanded_symbol = nil,
    
    -- Tool initialization flag
    tool_initialized = false,
    
    -- Input lock state
    input_lock_active = false,
    
    -- Symbol button references for highlighting
    symbol_button_refs = {},
    
    -- Current formatted labels for pagination
    current_formatted_labels = {}
}

-- Pagination state
local pagination_state = {
    current_page = 1,
    symbols_per_page = 12, -- 3x4 grid
    total_pages = 1
}

-- Audio preview state
local preview_state = {
    active = false,
    instrument_index = nil,
    track_index = nil,
    notes = {},  -- List of {note_value, instrument_index}
    symbol = nil
}

-- ============================================================================
-- UI State Accessors
-- ============================================================================

function state.get_dialog()
    return ui_state.dialog
end

function state.set_dialog(dialog)
    ui_state.dialog = dialog
end

function state.get_dialog_vb()
    return ui_state.dialog_vb
end

function state.set_dialog_vb(vb)
    ui_state.dialog_vb = vb
end

function state.is_ui_collapsed()
    return ui_state.ui_collapsed
end

function state.set_ui_collapsed(collapsed)
    ui_state.ui_collapsed = collapsed
end

function state.is_right_column_collapsed()
    return ui_state.right_column_collapsed
end

function state.set_right_column_collapsed(collapsed)
    ui_state.right_column_collapsed = collapsed
end

-- View toggles
function state.is_category_view_enabled()
    return ui_state.category_view_enabled
end

function state.set_category_view_enabled(enabled)
    ui_state.category_view_enabled = enabled
end

function state.is_organize_view_enabled()
    return ui_state.organize_view_enabled
end

function state.set_organize_view_enabled(enabled)
    ui_state.organize_view_enabled = enabled
end

function state.is_detailed_view_enabled()
    return ui_state.detailed_view_enabled
end

function state.set_detailed_view_enabled(enabled)
    ui_state.detailed_view_enabled = enabled
end

function state.is_dictionary_view_enabled()
    return ui_state.dictionary_view_enabled
end

function state.set_dictionary_view_enabled(enabled)
    ui_state.dictionary_view_enabled = enabled
end

function state.is_label_view_enabled()
    return ui_state.label_view_enabled
end

function state.set_label_view_enabled(enabled)
    ui_state.label_view_enabled = enabled
end

-- Expanded symbol tracking
function state.get_expanded_symbol()
    return ui_state.expanded_symbol
end

function state.set_expanded_symbol(symbol)
    ui_state.expanded_symbol = symbol
end

-- Tool initialization
function state.is_tool_initialized()
    return ui_state.tool_initialized
end

function state.set_tool_initialized(initialized)
    ui_state.tool_initialized = initialized
end

-- Input lock
function state.is_input_lock_active()
    return ui_state.input_lock_active
end

function state.set_input_lock_active(active)
    ui_state.input_lock_active = active
end

-- Symbol button refs
function state.get_symbol_button_refs()
    return ui_state.symbol_button_refs
end

function state.set_symbol_button_ref(symbol, ref)
    ui_state.symbol_button_refs[symbol] = ref
end

function state.clear_symbol_button_ref(symbol)
    ui_state.symbol_button_refs[symbol] = nil
end

-- Formatted labels
function state.get_current_formatted_labels()
    return ui_state.current_formatted_labels
end

function state.set_current_formatted_labels(labels)
    ui_state.current_formatted_labels = labels
end

-- ============================================================================
-- Pagination State Accessors
-- ============================================================================

function state.get_pagination()
    return pagination_state
end

function state.get_current_page()
    return pagination_state.current_page
end

function state.set_current_page(page)
    pagination_state.current_page = page
end

function state.get_symbols_per_page()
    return pagination_state.symbols_per_page
end

function state.get_total_pages()
    return pagination_state.total_pages
end

function state.set_total_pages(pages)
    pagination_state.total_pages = pages
end

-- ============================================================================
-- Preview State Accessors
-- ============================================================================

function state.get_preview_state()
    return preview_state
end

function state.is_preview_active()
    return preview_state.active
end

function state.set_preview_active(active)
    preview_state.active = active
end

function state.get_preview_instrument_index()
    return preview_state.instrument_index
end

function state.set_preview_instrument_index(index)
    preview_state.instrument_index = index
end

function state.get_preview_track_index()
    return preview_state.track_index
end

function state.set_preview_track_index(index)
    preview_state.track_index = index
end

function state.get_preview_notes()
    return preview_state.notes
end

function state.set_preview_notes(notes)
    preview_state.notes = notes
end

function state.add_preview_note(note_info)
    table.insert(preview_state.notes, note_info)
end

function state.clear_preview_notes()
    preview_state.notes = {}
end

function state.get_preview_symbol()
    return preview_state.symbol
end

function state.set_preview_symbol(symbol)
    preview_state.symbol = symbol
end

function state.reset_preview_state()
    preview_state.active = false
    preview_state.instrument_index = nil
    preview_state.track_index = nil
    preview_state.notes = {}
    preview_state.symbol = nil
end

-- ============================================================================
-- State Reset
-- ============================================================================

function state.reset_ui_state()
    ui_state.dialog = nil
    ui_state.dialog_vb = nil
    ui_state.ui_collapsed = false
    ui_state.right_column_collapsed = false
    ui_state.category_view_enabled = false
    ui_state.organize_view_enabled = false
    ui_state.detailed_view_enabled = false
    ui_state.dictionary_view_enabled = false
    ui_state.label_view_enabled = false
    ui_state.expanded_symbol = nil
    ui_state.input_lock_active = false
    ui_state.symbol_button_refs = {}
    ui_state.current_formatted_labels = {}
end

function state.reset_pagination()
    pagination_state.current_page = 1
    pagination_state.total_pages = 1
end

return state
