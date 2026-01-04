-- labeler.lua - Simplified Slice Labeling System
local labeler = {}
local vb = renoise.ViewBuilder()

-- Helper function for table operations
function table.find(t, value)
    for i, v in ipairs(t) do
        if v == value then return i end
    end
    return nil
end

-- State management
labeler.saved_labels = {}
labeler.saved_labels_by_instrument = {}
labeler.refresh_callback = nil
local dialog = nil
labeler.dialog = nil  -- Expose dialog state for external checking

-- Phase 6: Slice preview state management
local slice_preview_state = {
    is_playing = false,
    current_note = nil,
    current_instrument = nil,
    current_button_id = nil,
    dialog_vb = nil,
    auto_stop_time = nil  -- For auto-stop after duration
}

-- Phase 6: Preview timer state
local preview_timer_active = false
local PREVIEW_DURATION_MS = 2000  -- Auto-stop after 2 seconds

-- Global symbol registry access (will be set by main.lua)
local get_global_symbol_registry = nil
local assign_symbols_to_instrument = nil
local save_global_symbol_registry = nil
local get_custom_labels_data = nil
local save_custom_labels_data = nil
local get_show_label2 = nil
local save_show_label2 = nil
local get_show_advanced_data = nil
local save_show_advanced_data = nil

-- Location options for Advanced Data
labeler.location_options = {"Off-Center", "Center", "Edge", "Rim", "Alt"}

-- Custom label management
labeler.custom_labels = {
    builtin = {"---------", "Kick", "Snare", "Hi Hat Closed", "Hi Hat Open", 
               "Crash", "Tom", "Ride", "Shaker", "Tambourine", "Cowbell"},
    user = {}
}

-- Set global symbol registry functions (extended with preference accessors)
function labeler.set_global_symbol_functions(get_registry_func, assign_symbols_func, save_registry_func,
                                              get_custom_labels_func, save_custom_labels_func,
                                              get_show_label2_func, save_show_label2_func,
                                              get_show_advanced_data_func, save_show_advanced_data_func)
    get_global_symbol_registry = get_registry_func
    assign_symbols_to_instrument = assign_symbols_func
    save_global_symbol_registry = save_registry_func
    get_custom_labels_data = get_custom_labels_func
    save_custom_labels_data = save_custom_labels_func
    get_show_label2 = get_show_label2_func
    save_show_label2 = save_show_label2_func
    get_show_advanced_data = get_show_advanced_data_func
    save_show_advanced_data = save_show_advanced_data_func
    
    -- Load custom labels from preferences on initialization
    labeler.load_custom_labels()
end

-- Preview symbol callback (set by main.lua)
local preview_symbol_callback = nil

-- Set preview symbol callback function
function labeler.set_preview_symbol_callback(callback)
    preview_symbol_callback = callback
end

-- Load custom labels from preferences
function labeler.load_custom_labels()
    if get_custom_labels_data then
        local data = get_custom_labels_data()
        if data and data ~= "" then
            -- Parse JSON-like array format: ["label1","label2",...]
            labeler.custom_labels.user = {}
            for label in data:gmatch('"([^"]+)"') do
                table.insert(labeler.custom_labels.user, label)
            end
            print("DEBUG: Loaded " .. #labeler.custom_labels.user .. " custom labels")
        end
    end
end

-- Save custom labels to preferences
function labeler.save_custom_labels()
    if save_custom_labels_data then
        -- Serialize as JSON-like array
        local parts = {}
        for _, label in ipairs(labeler.custom_labels.user) do
            table.insert(parts, '"' .. label .. '"')
        end
        local data = "[" .. table.concat(parts, ",") .. "]"
        save_custom_labels_data(data)
        print("DEBUG: Saved " .. #labeler.custom_labels.user .. " custom labels")
    end
end

-- Get all available labels (builtin + user)
function labeler.get_all_labels()
    local all = {}
    for _, label in ipairs(labeler.custom_labels.builtin) do
        table.insert(all, label)
    end
    for _, label in ipairs(labeler.custom_labels.user) do
        table.insert(all, label)
    end
    return all
end

-- Add a custom user label
function labeler.add_custom_label(label_name)
    if not label_name or label_name == "" then
        return false, "Label name cannot be empty"
    end
    
    -- Trim whitespace
    label_name = label_name:match("^%s*(.-)%s*$")
    
    if label_name == "" then
        return false, "Label name cannot be empty"
    end
    
    -- Check for duplicates in builtin
    for _, existing in ipairs(labeler.custom_labels.builtin) do
        if existing:lower() == label_name:lower() then
            return false, "Label already exists as built-in"
        end
    end
    
    -- Check for duplicates in user
    for _, existing in ipairs(labeler.custom_labels.user) do
        if existing:lower() == label_name:lower() then
            return false, "Label already exists"
        end
    end
    
    table.insert(labeler.custom_labels.user, label_name)
    labeler.save_custom_labels()
    return true
end

-- Remove a custom user label
function labeler.remove_custom_label(label_name)
    for i, label in ipairs(labeler.custom_labels.user) do
        if label == label_name then
            table.remove(labeler.custom_labels.user, i)
            labeler.save_custom_labels()
            return true
        end
    end
    return false
end

-- ============================================================================
-- Phase 6: Slice Preview Functions
-- ============================================================================

-- Timer callback for auto-stop preview
local function slice_preview_timer_callback()
    if not slice_preview_state.is_playing then
        -- Stop timer if preview is not active
        if preview_timer_active and renoise.tool():has_timer(slice_preview_timer_callback) then
            renoise.tool():remove_timer(slice_preview_timer_callback)
            preview_timer_active = false
        end
        return
    end
    
    -- Check if we should auto-stop
    if slice_preview_state.auto_stop_time then
        local current_time = os.clock() * 1000  -- Convert to ms
        if current_time >= slice_preview_state.auto_stop_time then
            labeler.stop_slice_preview()
        end
    end
end

-- Update preview button visual (> when stopped, [] when playing)
local function update_preview_button(button_id, dialog_vb, is_playing)
    if not dialog_vb then return end
    
    local button = dialog_vb.views[button_id]
    if button then
        button.text = is_playing and "[]" or ">"
    end
end

-- Stop any currently playing slice preview
function labeler.stop_slice_preview()
    -- Remove timer if active
    if preview_timer_active then
        if renoise.tool():has_timer(slice_preview_timer_callback) then
            renoise.tool():remove_timer(slice_preview_timer_callback)
        end
        preview_timer_active = false
    end
    
    if not slice_preview_state.is_playing then
        return
    end
    
    local song = renoise.song()
    if song and slice_preview_state.current_note and slice_preview_state.current_instrument then
        -- Send note-off
        local track_idx = song.selected_track_index
        pcall(function()
            song:trigger_instrument_note_off(
                slice_preview_state.current_instrument,
                track_idx,
                slice_preview_state.current_note
            )
        end)
    end
    
    -- Update button visual back to play symbol
    if slice_preview_state.dialog_vb and slice_preview_state.current_button_id then
        update_preview_button(slice_preview_state.current_button_id, slice_preview_state.dialog_vb, false)
    end
    
    -- Reset state
    slice_preview_state.is_playing = false
    slice_preview_state.current_note = nil
    slice_preview_state.current_instrument = nil
    slice_preview_state.current_button_id = nil
    slice_preview_state.dialog_vb = nil
    slice_preview_state.auto_stop_time = nil
    
    print("DEBUG: Stopped slice preview")
end

-- Start preview for a specific slice/note
function labeler.start_slice_preview(instrument_index, note_value, button_id, dialog_vb)
    -- Stop any existing preview first
    labeler.stop_slice_preview()
    
    local song = renoise.song()
    if not song then
        print("DEBUG: No song loaded for slice preview")
        return false
    end
    
    -- Validate instrument
    if not instrument_index or instrument_index < 1 or instrument_index > #song.instruments then
        print("DEBUG: Invalid instrument index for slice preview:", instrument_index)
        return false
    end
    
    local instrument = song.instruments[instrument_index]
    if not instrument or #instrument.samples == 0 then
        print("DEBUG: Instrument has no samples for preview")
        return false
    end
    
    local track_idx = song.selected_track_index
    
    -- Trigger note on
    local success = pcall(function()
        song:trigger_instrument_note_on(instrument_index, track_idx, note_value, 0.5)
    end)
    
    if not success then
        print("DEBUG: Failed to trigger note for slice preview")
        return false
    end
    
    -- Update state
    slice_preview_state.is_playing = true
    slice_preview_state.current_note = note_value
    slice_preview_state.current_instrument = instrument_index
    slice_preview_state.current_button_id = button_id
    slice_preview_state.dialog_vb = dialog_vb
    slice_preview_state.auto_stop_time = (os.clock() * 1000) + PREVIEW_DURATION_MS
    
    -- Update button visual to stop symbol
    update_preview_button(button_id, dialog_vb, true)
    
    -- Start auto-stop timer (check every 100ms)
    if not preview_timer_active then
        renoise.tool():add_timer(slice_preview_timer_callback, 100)
        preview_timer_active = true
    end
    
    print("DEBUG: Started slice preview - inst:", instrument_index, "note:", note_value)
    return true
end

-- Toggle preview for a slice (play if stopped, stop if playing same slice)
function labeler.toggle_slice_preview(instrument_index, note_value, button_id, dialog_vb)
    -- If same slice is playing, stop it
    if slice_preview_state.is_playing and
       slice_preview_state.current_instrument == instrument_index and
       slice_preview_state.current_note == note_value then
        labeler.stop_slice_preview()
        return false
    end
    
    -- Start preview (this will stop any different slice that's playing)
    return labeler.start_slice_preview(instrument_index, note_value, button_id, dialog_vb)
end

-- Check if slice preview is currently active
function labeler.is_slice_previewing()
    return slice_preview_state.is_playing
end

-- Check if a specific slice is being previewed
function labeler.is_previewing_slice(instrument_index, note_value)
    return slice_preview_state.is_playing and
           slice_preview_state.current_instrument == instrument_index and
           slice_preview_state.current_note == note_value
end


-- Set callback for when labels are updated
function labeler.set_refresh_callback(callback)
    labeler.refresh_callback = callback
end

-- Get current saved labels
function labeler.get_saved_labels()
    local song = renoise.song()
    local current_index = labeler.locked_instrument_index or song.selected_instrument_index
    return labeler.saved_labels_by_instrument[current_index] or {}
end

-- Store labels for specific instrument
function labeler.store_labels_for_instrument(instrument_index, labels)
    labeler.saved_labels_by_instrument[instrument_index] = {}
    for k, v in pairs(labels) do
        labeler.saved_labels_by_instrument[instrument_index][k] = v
    end
    labeler.saved_labels = labels
end

-- Get labels for specific instrument
function labeler.get_labels_for_instrument(instrument_index)
    return labeler.saved_labels_by_instrument[instrument_index] or {}
end

-- Set labels for specific instrument (Phase 2: needed for add_breakpoints_from_selection)
function labeler.set_labels_for_instrument(instrument_index, labels)
    if not instrument_index or instrument_index < 1 then
        print("DEBUG: Invalid instrument index for set_labels_for_instrument")
        return false
    end
    labeler.saved_labels_by_instrument[instrument_index] = labels or {}
    return true
end

-- Helper functions for CSV export/import
local function escape_csv_field(field)
    if type(field) == "string" and (field:find(',') or field:find('"')) then
        return '"' .. field:gsub('"', '""') .. '"'
    end
    return tostring(field)
end

local function unescape_csv_field(field)
    if field:sub(1,1) == '"' and field:sub(-1) == '"' then
        return field:sub(2, -2):gsub('""', '"')
    end
    return field
end

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

-- Get sample name for file naming
local function get_current_sample_name()
    local song = renoise.song()
    local instrument = song.selected_instrument
    if instrument and #instrument.samples > 0 then
        local name = instrument.samples[1].name:gsub("[%c%p%s]", "_")
        return name
    end
    return "default"
end

-- Calculate UI scale factor based on number of slices
local function calculate_scale_factor(num_slices)
    local base_slices = 16
    return math.max(0.5, math.min(1, base_slices / num_slices))
end

-- Export labels to CSV (compatible with BreakPal/HotSwap format)
function labeler.export_labels()
    local filename = get_current_sample_name() .. "_breakfast_labels.csv"
    local filepath = renoise.app():prompt_for_filename_to_write("csv", "Export BreakFast Labels")
    
    if not filepath or filepath == "" then return end
    
    if not filepath:lower():match("%.csv$") then
        filepath = filepath .. ".csv"
    end
    
    local file, err = io.open(filepath, "w")
    if not file then
        renoise.app():show_error("Unable to open file for writing: " .. tostring(err))
        return
    end
    
    -- Full header for BreakPal/HotSwap compatibility (added Location, Counterstroke)
    file:write("Index,Label,Label 2,Breakpoint,Location,Cycle,Ghost,Counterstroke,[Ref]Instrument,[Ref]SliceNote\n")

    -- Sort keys for consistent output
    local sorted_keys = {}
    for hex_key, _ in pairs(labeler.saved_labels) do
        table.insert(sorted_keys, hex_key)
    end
    table.sort(sorted_keys)

    for _, hex_key in ipairs(sorted_keys) do
        local data = labeler.saved_labels[hex_key]
        -- Calculate slice note from hex key (slice 01 = note 37, etc.)
        local slice_index = tonumber(hex_key, 16) or 1
        local slice_note = 36 + slice_index  -- Note 37 = slice 1
        
        local values = {
            hex_key,
            data.label or "---------",
            data.label2 or "---------",
            tostring(data.breakpoint or false),
            data.location or "Off-Center",
            tostring(data.cycle or false),
            tostring(data.ghost or false),
            tostring(data.counterstroke or false),
            tostring((data.instrument_index or 1) - 1),  -- 0-based for display
            tostring(slice_note)
        }
        
        -- Escape each field
        for i, value in ipairs(values) do
            values[i] = escape_csv_field(value)
        end
        
        file:write(table.concat(values, ",") .. "\n")
    end
    
    file:close()
    renoise.app():show_status("BreakFast labels exported to " .. filepath)
end

-- Import labels from CSV
function labeler.import_labels()
    local filepath = renoise.app():prompt_for_filename_to_read({"*.csv"}, "Import BreakFast Labels")
    
    if not filepath or filepath == "" then return end
    
    local file, err = io.open(filepath, "r")
    if not file then
        renoise.app():show_error("Unable to open file: " .. tostring(err))
        return
    end
    
    local header = file:read()
    if not header then
        renoise.app():show_error("Invalid CSV format: No header found")
        file:close()
        return
    end
    
    -- Parse header to find column positions
    local header_fields = parse_csv_line(header)
    local column_positions = {}
    
    -- Look for columns (case insensitive, handle both old and new formats)
    for i, field in ipairs(header_fields) do
        local lower_field = field:lower():gsub("%s+", " ")  -- Normalize whitespace
        if lower_field == "index" then
            column_positions.index = i
        elseif lower_field == "label" then
            column_positions.label = i
        elseif lower_field == "label 2" then
            column_positions.label2 = i
        elseif lower_field == "breakpoint" then
            column_positions.breakpoint = i
        elseif lower_field == "instrument" or lower_field == "[ref]instrument" then
            column_positions.instrument = i
        -- Advanced data fields
        elseif lower_field == "location" then
            column_positions.location = i
        elseif lower_field == "cycle" then
            column_positions.cycle = i
        elseif lower_field == "ghost" then
            column_positions.ghost = i
        elseif lower_field == "counterstroke" then
            column_positions.counterstroke = i
        -- Legacy columns (read but converted/ignored)
        elseif lower_field == "roll" then
            column_positions.roll = i
        elseif lower_field == "shuffle" then
            column_positions.shuffle = i
        elseif lower_field == "[ref]slicenote" then
            column_positions.slicenote = i
        end
    end
    
    -- Validate required columns exist
    if not column_positions.index then
        renoise.app():show_error("Invalid CSV format: Missing 'Index' column")
        file:close()
        return
    end
    
    if not column_positions.label then
        renoise.app():show_error("Invalid CSV format: Missing 'Label' column")
        file:close()
        return
    end
    
    if not column_positions.breakpoint then
        renoise.app():show_error("Invalid CSV format: Missing 'Breakpoint' column")
        file:close()
        return
    end

    -- Note: Label 2, Instrument, and Advanced Data columns are optional for backward compatibility

    local new_labels = {}
    local line_number = 1
    
    for line in file:lines() do
        line_number = line_number + 1
        local fields = parse_csv_line(line)
        
        -- Validate we have enough fields for the required columns
        local required_columns = {column_positions.index, column_positions.label, column_positions.breakpoint}
        local max_column = math.max(unpack(required_columns))
        if #fields < max_column then
            renoise.app():show_error(string.format(
                "Invalid CSV format at line %d: Not enough fields (need at least %d, got %d)", 
                line_number, max_column, #fields))
            file:close()
            return
        end
        
        local index = fields[column_positions.index]
        if not index:match("^%x%x$") then
            renoise.app():show_error(string.format(
                "Invalid index format at line %d: %s", 
                line_number, index))
            file:close()
            return
        end
        
        local function str_to_bool(str)
            return str:lower() == "true"
        end
        
        -- Get current instrument index for fallback
        local song = renoise.song()
        local current_instrument_index = song.selected_instrument_index
        local instrument_index = current_instrument_index  -- Default to current selection

        if column_positions.instrument and #fields >= column_positions.instrument then
            -- Use imported instrument value if available (handle both 0-based and 1-based)
            local imported_instrument = tonumber(unescape_csv_field(fields[column_positions.instrument]))
            if imported_instrument then
                -- Convert 0-based to 1-based if needed
                instrument_index = imported_instrument < 1 and imported_instrument + 1 or imported_instrument
            end
        end

        -- Get Label 2 if present
        local label2 = "---------"
        if column_positions.label2 and #fields >= column_positions.label2 then
            label2 = unescape_csv_field(fields[column_positions.label2])
            if label2 == "" then label2 = "---------" end
        end

        -- Get Location if present (default: Off-Center)
        local location = "Off-Center"
        if column_positions.location and #fields >= column_positions.location then
            local loc_value = unescape_csv_field(fields[column_positions.location])
            -- Validate location is in valid options
            for _, valid_loc in ipairs(labeler.location_options) do
                if loc_value == valid_loc then
                    location = loc_value
                    break
                end
            end
        end

        -- Get Cycle if present (default: false)
        local cycle = false
        if column_positions.cycle and #fields >= column_positions.cycle then
            cycle = str_to_bool(fields[column_positions.cycle])
        end

        -- Get Ghost if present (default: false)
        local ghost = false
        if column_positions.ghost and #fields >= column_positions.ghost then
            ghost = str_to_bool(fields[column_positions.ghost])
        end

        -- Get Counterstroke if present (default: false)
        local counterstroke = false
        if column_positions.counterstroke and #fields >= column_positions.counterstroke then
            counterstroke = str_to_bool(fields[column_positions.counterstroke])
        end

        new_labels[index] = {
            label = unescape_csv_field(fields[column_positions.label]),
            label2 = label2,
            breakpoint = str_to_bool(fields[column_positions.breakpoint]),
            instrument_index = instrument_index,
            location = location,
            cycle = cycle,
            ghost = ghost,
            counterstroke = counterstroke
        }
    end
    
    file:close()
    
    -- Get current instrument index
    local song = renoise.song()
    local current_instrument_index = labeler.locked_instrument_index or song.selected_instrument_index

    -- Store labels for current instrument and update global reference
    labeler.store_labels_for_instrument(current_instrument_index, new_labels)

    -- Check if we have breakpoints and assign global symbols
    local has_breakpoints = false
    for _, label_data in pairs(new_labels) do
        if label_data.breakpoint then
            has_breakpoints = true
            break
        end
    end

    if has_breakpoints and assign_symbols_to_instrument then
        local instrument = song.selected_instrument
        if #instrument.phrases > 0 then
            local original_phrase = instrument.phrases[1]
            local breakpoints_module = require("breakpoints")
            local break_sets = breakpoints_module.create_break_patterns(instrument, original_phrase, new_labels, current_instrument_index)
            
            if break_sets and #break_sets > 0 then
                local assigned_symbols, error_msg = assign_symbols_to_instrument(current_instrument_index, break_sets, new_labels)
                if assigned_symbols then
                    print("DEBUG: Import assigned symbols", table.concat(assigned_symbols, ", "), "to instrument", current_instrument_index)
                    if save_global_symbol_registry then
                        save_global_symbol_registry()
                    end
                    renoise.app():show_status(string.format("BreakFast labels imported. Assigned symbols: %s", table.concat(assigned_symbols, ", ")))
                else
                    renoise.app():show_warning("Labels imported, but could not assign symbols: " .. (error_msg or "Unknown error"))
                end
            else
                renoise.app():show_warning("Labels imported, but no valid break sets were created.")
            end
        else
            renoise.app():show_warning("Labels imported, but no phrases available for break pattern creation.")
        end
    else
        renoise.app():show_status("BreakFast labels imported from " .. filepath)
    end

    -- Trigger refresh callback
    if labeler.refresh_callback then
        labeler.refresh_callback()
    end
end

-- Helper: Convert note value to display string (e.g., "C-4")
local function note_value_to_string(note_value)
    if note_value == 120 then return "OFF"
    elseif note_value == 121 or note_value == 255 then return "---"
    else
        local octave = math.floor(note_value / 12) - 2
        local note_names = {"C-", "C#", "D-", "D#", "E-", "F-", "F#", "G-", "G#", "A-", "A#", "B-"}
        local note_index = (note_value % 12) + 1
        return string.format("%s%d", note_names[note_index], octave)
    end
end

-- Scan instrument for note mappings (slices or keyzones)
function labeler.scan_instrument_note_mappings(instrument)
    local mappings = {}
    local samples = instrument.samples
    
    -- Check if instrument has slices (samples > 1 means sliced)
    if #samples > 1 then
        -- First, add the root/unsliced sample at C-1 (note 36)
        local root_sample = samples[1]
        table.insert(mappings, {
            note_value = 36,  -- C-1 triggers the full unsliced sample
            sample_index = 1,
            slice_index = 0,  -- 0 = root sample
            sample_name = "SRC: " .. (root_sample.name or "Root Sample"),
            display_note = note_value_to_string(36),
            is_slice = false,
            hex_key = "00"  -- Key "00" for root sample
        })
        
        -- Then add each slice starting at C#1 (note 37)
        for slice_idx = 2, #samples do
            local sample = samples[slice_idx]
            local trigger_note = 36 + (slice_idx - 1)  -- Slice 1 = note 37 (C#1)
            
            table.insert(mappings, {
                note_value = trigger_note,
                sample_index = slice_idx,
                slice_index = slice_idx - 1,
                sample_name = string.format("S#%02X: %s", slice_idx - 1, sample.name or ("Slice " .. (slice_idx - 1))),
                display_note = note_value_to_string(trigger_note),
                is_slice = true,
                hex_key = string.format("%02X", slice_idx - 1)  -- Slice 1 = "01", Slice 2 = "02", etc.
            })
        end
    elseif #samples == 1 then
        -- Single sample instrument: show the sample with its base note
        local sample = samples[1]
        local base_note = 48  -- Default to C-4 if no mapping info
        
        -- Try to get the actual base note from sample mappings
        -- sample_mappings structure: [LAYER][mapping_index]
        -- LAYER_NOTE_ON = 1
        if instrument.sample_mappings and instrument.sample_mappings[1] then
            local layer_mappings = instrument.sample_mappings[1]
            if #layer_mappings > 0 then
                -- Use the first mapping's base_note
                local first_mapping = layer_mappings[1]
                if first_mapping and first_mapping.base_note then
                    base_note = first_mapping.base_note
                end
            end
        end
        
        table.insert(mappings, {
            note_value = base_note,
            sample_index = 1,
            slice_index = nil,
            sample_name = sample.name or "Sample 1",
            display_note = note_value_to_string(base_note),
            is_slice = false,
            hex_key = string.format("%02X", base_note)  -- Note-based key
        })
    end
    -- If no samples, mappings remains empty
    
    -- Sort by note value
    table.sort(mappings, function(a, b) return a.note_value < b.note_value end)
    
    return mappings
end

-- Show Manage Labels dialog
function labeler.show_manage_labels_dialog(parent_dialog_vb, on_close_callback)
    local manage_vb = renoise.ViewBuilder()
    local manage_dialog = nil
    
    local function refresh_label_list()
        local list_container = manage_vb.views.label_list_container
        if not list_container then return end
        
        -- Clear existing
        while #list_container.views > 0 do
            list_container:remove_child(list_container.views[1])
        end
        
        -- Add built-in labels (disabled)
        list_container:add_child(manage_vb:text {
            text = "Built-in Labels:",
            font = "bold"
        })
        
        for _, label in ipairs(labeler.custom_labels.builtin) do
            if label ~= "---------" then
                list_container:add_child(manage_vb:row {
                    manage_vb:text { text = "  " .. label, width = 150 },
                    manage_vb:text { text = "(built-in)", style = "disabled" }
                })
            end
        end
        
        -- Add user labels (with delete button)
        if #labeler.custom_labels.user > 0 then
            list_container:add_child(manage_vb:space { height = 10 })
            list_container:add_child(manage_vb:text {
                text = "Custom Labels:",
                font = "bold"
            })
            
            for _, label in ipairs(labeler.custom_labels.user) do
                list_container:add_child(manage_vb:row {
                    manage_vb:text { text = "  " .. label, width = 150 },
                    manage_vb:button {
                        text = "X",
                        width = 20,
                        notifier = function()
                            labeler.remove_custom_label(label)
                            refresh_label_list()
                        end
                    }
                })
            end
        end
    end
    
    local dialog_content = manage_vb:column {
        margin = 10,
        spacing = 5,
        
        manage_vb:text {
            text = "Manage Custom Labels",
            font = "bold",
            style = "strong"
        },
        
        manage_vb:space { height = 5 },
        
        -- Scrollable list container
        manage_vb:column {
            id = "label_list_container",
            style = "group",
            margin = 5,
            width = 220
        },
        
        manage_vb:space { height = 10 },
        
        -- Add new label row
        manage_vb:row {
            spacing = 5,
            manage_vb:textfield {
                id = "new_label_input",
                width = 150,
                text = ""
            },
            manage_vb:button {
                text = "Add",
                width = 50,
                notifier = function()
                    local input = manage_vb.views.new_label_input
                    local label_name = input.text
                    local success, err = labeler.add_custom_label(label_name)
                    if success then
                        input.text = ""
                        refresh_label_list()
                    else
                        renoise.app():show_warning(err or "Failed to add label")
                    end
                end
            }
        },
        
        manage_vb:space { height = 10 },
        
        manage_vb:button {
            text = "Close",
            width = 100,
            notifier = function()
                if manage_dialog and manage_dialog.visible then
                    manage_dialog:close()
                end
                if on_close_callback then
                    on_close_callback()
                end
            end
        }
    }
    
    -- Initial population
    refresh_label_list()
    
    manage_dialog = renoise.app():show_custom_dialog("Manage Labels", dialog_content)
end

-- Show labeling dialog
function labeler.show_dialog()
    if dialog and dialog.visible then
        dialog:close()
        dialog = nil
    end
    
    -- Create a fresh ViewBuilder instance to avoid ID conflicts
    local dialog_vb = renoise.ViewBuilder()
    
    local song = renoise.song()
    local instrument_count = #song.instruments
    
    if instrument_count < 1 then
        renoise.app():show_warning("No instruments found in the song.")
        return
    end
    
    -- Get current instrument
    local current_instrument_index = song.selected_instrument_index
    local instrument = song:instrument(current_instrument_index)
    local samples = instrument.samples
    
    -- Scan for note mappings
    local note_mappings = labeler.scan_instrument_note_mappings(instrument)
    
    if #note_mappings == 0 then
        renoise.app():show_warning("No samples or slices found in this instrument.")
        return
    end
    
    -- Get saved labels for current instrument
    local current_labels = labeler.get_labels_for_instrument(current_instrument_index)
    
    -- Get show_label2 state from preferences
    local show_label2 = get_show_label2 and get_show_label2() or false
    
    -- Get show_advanced_data state from preferences
    local show_advanced_data = get_show_advanced_data and get_show_advanced_data() or false
    
    -- Prepare mapping data with existing labels
    local mapping_data = {}
    for _, mapping in ipairs(note_mappings) do
        -- Try to find existing label using both hex_key formats
        local saved_label = current_labels[mapping.hex_key]
        
        -- Also try legacy slice-based key if this is a slice
        if not saved_label and mapping.is_slice then
            local legacy_key = string.format("%02X", mapping.slice_index + 1)
            saved_label = current_labels[legacy_key]
        end
        
        saved_label = saved_label or { 
            label = "---------", 
            label2 = "---------", 
            breakpoint = false,
            location = "Off-Center",
            ghost = false,
            counterstroke = false,
            cycle = false
        }
        
        table.insert(mapping_data, {
            note_value = mapping.note_value,
            sample_index = mapping.sample_index,
            slice_index = mapping.slice_index,
            sample_name = mapping.sample_name,
            display_note = mapping.display_note,
            is_slice = mapping.is_slice,
            hex_key = mapping.hex_key,
            label = saved_label.label or "---------",
            label2 = saved_label.label2 or "---------",
            breakpoint = saved_label.breakpoint or false,
            location = saved_label.location or "Off-Center",
            ghost = saved_label.ghost or false,
            counterstroke = saved_label.counterstroke or false,
            cycle = saved_label.cycle or false
        })
    end
    
    local scale_factor = calculate_scale_factor(#mapping_data)
    local column_width = 100
    local narrow_column = 60
    local spacing = 5
    local row_height = math.max(20, math.min(30, 30 * scale_factor))
    
    -- Get all available labels
    local label_options = labeler.get_all_labels()
    
    -- Function to rebuild the dialog (called when Label 2 toggle changes)
    local function rebuild_dialog()
        -- Stop any active preview before rebuilding
        labeler.stop_slice_preview()
        if dialog and dialog.visible then
            dialog:close()
            dialog = nil
        end
        labeler.show_dialog()
    end
    
    -- Preview column width
    local preview_column_width = 22
    
    -- Column widths for advanced data
    local location_column_width = 80
    local checkbox_column_width = 50
    
    -- Build header row based on show_label2 and show_advanced_data states
    local header_elements = {
        dialog_vb:text { text = "", width = preview_column_width, align = "center" },  -- Preview column header
        dialog_vb:text { text = "Note", width = narrow_column, align = "center", font = "bold" },
        dialog_vb:text { text = "Sample", width = column_width, align = "center", font = "bold" },
        dialog_vb:text { text = "Label", width = column_width, align = "center", font = "bold" },
        dialog_vb:button { 
            text = show_label2 and "[-]" or "[+]", 
            width = 25,
            tooltip = show_label2 and "Hide Label 2 column" or "Show Label 2 column",
            notifier = function()
                if save_show_label2 then save_show_label2(not show_label2) end
                rebuild_dialog()
            end
        }
    }
    
    -- Add Label 2 column if enabled
    if show_label2 then
        table.insert(header_elements, dialog_vb:text { text = "Label 2", width = column_width, align = "center", font = "bold" })
    end
    
    -- Add Breakpoint column
    table.insert(header_elements, dialog_vb:text { text = "Breakpoint", width = 70, align = "center", font = "bold" })
    
    -- Add Advanced Data toggle button
    table.insert(header_elements, dialog_vb:button { 
        text = show_advanced_data and "Adv [-]" or "Adv [+]", 
        width = 50,
        tooltip = show_advanced_data and "Hide Advanced Data columns" or "Show Advanced Data columns",
        notifier = function()
            if save_show_advanced_data then save_show_advanced_data(not show_advanced_data) end
            rebuild_dialog()
        end
    })
    
    -- Add Advanced Data columns if enabled
    if show_advanced_data then
        table.insert(header_elements, dialog_vb:text { text = "Location", width = location_column_width, align = "center", font = "bold" })
        table.insert(header_elements, dialog_vb:text { text = "Ghost", width = checkbox_column_width, align = "center", font = "bold" })
        table.insert(header_elements, dialog_vb:text { text = "CStroke", width = checkbox_column_width, align = "center", font = "bold" })
        table.insert(header_elements, dialog_vb:text { text = "Cycle", width = checkbox_column_width, align = "center", font = "bold" })
    end
    
    -- Build header row from elements
    local header_row = dialog_vb:row { spacing = spacing }
    for _, element in ipairs(header_elements) do
        header_row:add_child(element)
    end
    
    -- Create dialog content
    local dialog_content = dialog_vb:column {
        spacing = spacing,
        margin = 10,
        
        dialog_vb:text {
            text = "BreakFast Labeler",
            font = "big",
            style = "strong"
        },
        
        dialog_vb:space { height = 5 },
        
        -- Instrument selection row
        dialog_vb:row {
            spacing = 10,
            dialog_vb:text {
                text = "Instrument:",
                font = "bold"
            },
            dialog_vb:valuebox {
                id = "instrument_index",
                min = 0,
                max = instrument_count - 1,
                value = current_instrument_index - 1,
                tostring = function(value) 
                    return string.format("%02X", value)
                end,
                tonumber = function(str)
                    return tonumber(str, 16)
                end,
                notifier = function(value)
                    -- Stop any active preview before changing instrument
                    labeler.stop_slice_preview()
                    -- Close dialog and reopen with new instrument
                    dialog:close()
                    song.selected_instrument_index = value + 1
                    labeler.show_dialog()
                end
            },
            dialog_vb:text {
                text = instrument.name or "(unnamed)",
                style = "disabled"
            }
        },
        
        dialog_vb:space { height = 5 },
        
        -- Header row
        header_row
    }
    
    -- Add mapping rows
    for i, mapping in ipairs(mapping_data) do
        -- Create preview button ID
        local preview_button_id = "preview_" .. i
        
        -- Check if this is the SRC (root) sample - labels are disabled for SRC
        local is_src_sample = (mapping.hex_key == "00")
        
        local row_elements = {
            -- Preview button (Phase 6) - always enabled, even for SRC
            dialog_vb:button {
                id = preview_button_id,
                text = ">",
                width = preview_column_width,
                tooltip = is_src_sample and "Preview full sample" or "Preview this slice",
                notifier = function()
                    labeler.toggle_slice_preview(
                        current_instrument_index,
                        mapping.note_value,
                        preview_button_id,
                        dialog_vb
                    )
                end
            },
            
            -- Note
            dialog_vb:text { 
                text = mapping.display_note, 
                width = narrow_column, 
                align = "center",
                style = is_src_sample and "disabled" or "normal"
            },
            
            -- Sample name (truncated)
            dialog_vb:text { 
                text = mapping.sample_name:sub(1, 15), 
                width = column_width, 
                align = "left",
                tooltip = mapping.sample_name,
                style = is_src_sample and "disabled" or "normal"
            }
        }
        
        -- Label dropdown or disabled text for SRC
        if is_src_sample then
            -- SRC sample: show disabled text instead of dropdown
            table.insert(row_elements, dialog_vb:text {
                text = "(no labels)",
                width = column_width,
                align = "center",
                style = "disabled"
            })
        else
            -- Regular slice: show label dropdown
            table.insert(row_elements, dialog_vb:popup {
                id = "label_" .. i,
                items = label_options,
                width = column_width,
                value = table.find(label_options, mapping.label) or 1
            })
        end
        
        -- Spacer for Label 2 toggle button alignment
        table.insert(row_elements, dialog_vb:space { width = 25 })
        
        if show_label2 then
            if is_src_sample then
                -- SRC sample: show disabled text instead of dropdown
                table.insert(row_elements, dialog_vb:text {
                    text = "---",
                    width = column_width,
                    align = "center",
                    style = "disabled"
                })
            else
                -- Regular slice: show Label 2 dropdown
                table.insert(row_elements, dialog_vb:popup {
                    id = "label2_" .. i,
                    items = label_options,
                    width = column_width,
                    value = table.find(label_options, mapping.label2) or 1
                })
            end
        end
        
        -- Breakpoint checkbox or disabled placeholder for SRC
        if is_src_sample then
            -- SRC sample: show disabled placeholder
            table.insert(row_elements, dialog_vb:horizontal_aligner {
                mode = "center",
                width = 70,
                dialog_vb:text {
                    text = "---",
                    style = "disabled"
                }
            })
        else
            -- Regular slice: show breakpoint checkbox
            table.insert(row_elements, dialog_vb:horizontal_aligner {
                mode = "center",
                width = 70,
                dialog_vb:checkbox {
                    id = "breakpoint_" .. i,
                    value = mapping.breakpoint,
                    notifier = function(value)
                        -- Count current breakpoints (exclude SRC samples)
                        local current_count = 0
                        for j = 1, #mapping_data do
                            if mapping_data[j].hex_key ~= "00" then
                                local other_checkbox = dialog_vb.views["breakpoint_" .. j]
                                if other_checkbox and other_checkbox.value then
                                    current_count = current_count + 1
                                end
                            end
                        end
                        
                        -- Limit to 5 breakpoints (6 sections maximum)
                        if value and current_count > 5 then
                            dialog_vb.views["breakpoint_" .. i].value = false
                            renoise.app():show_warning(
                                "Maximum 5 breakpoints allowed (creates 6 sections)."
                            )
                        end
                    end
                }
            })
        end
        
        -- Spacer for Advanced Data toggle button alignment
        table.insert(row_elements, dialog_vb:space { width = 50 })
        
        -- Advanced Data fields (when enabled)
        if show_advanced_data then
            if is_src_sample then
                -- SRC sample: show disabled placeholders for all advanced data fields
                -- Location placeholder
                table.insert(row_elements, dialog_vb:text {
                    text = "---",
                    width = location_column_width,
                    align = "center",
                    style = "disabled"
                })
                
                -- Ghost placeholder
                table.insert(row_elements, dialog_vb:horizontal_aligner {
                    mode = "center",
                    width = checkbox_column_width,
                    dialog_vb:text {
                        text = "---",
                        style = "disabled"
                    }
                })
                
                -- Counterstroke placeholder
                table.insert(row_elements, dialog_vb:horizontal_aligner {
                    mode = "center",
                    width = checkbox_column_width,
                    dialog_vb:text {
                        text = "---",
                        style = "disabled"
                    }
                })
                
                -- Cycle placeholder
                table.insert(row_elements, dialog_vb:horizontal_aligner {
                    mode = "center",
                    width = checkbox_column_width,
                    dialog_vb:text {
                        text = "---",
                        style = "disabled"
                    }
                })
            else
                -- Regular slice: show all advanced data controls
                -- Location dropdown
                table.insert(row_elements, dialog_vb:popup {
                    id = "location_" .. i,
                    items = labeler.location_options,
                    width = location_column_width,
                    value = table.find(labeler.location_options, mapping.location) or 1
                })
                
                -- Ghost checkbox
                table.insert(row_elements, dialog_vb:horizontal_aligner {
                    mode = "center",
                    width = checkbox_column_width,
                    dialog_vb:checkbox {
                        id = "ghost_" .. i,
                        value = mapping.ghost
                    }
                })
                
                -- Counterstroke checkbox
                table.insert(row_elements, dialog_vb:horizontal_aligner {
                    mode = "center",
                    width = checkbox_column_width,
                    dialog_vb:checkbox {
                        id = "counterstroke_" .. i,
                        value = mapping.counterstroke
                    }
                })
                
                -- Cycle checkbox
                table.insert(row_elements, dialog_vb:horizontal_aligner {
                    mode = "center",
                    width = checkbox_column_width,
                    dialog_vb:checkbox {
                        id = "cycle_" .. i,
                        value = mapping.cycle
                    }
                })
            end
        end
        
        local row = dialog_vb:row {
            spacing = spacing,
            height = row_height
        }
        
        for _, element in ipairs(row_elements) do
            row:add_child(element)
        end
        
        dialog_content:add_child(row)
    end
    
    -- Add action buttons
    dialog_content:add_child(dialog_vb:space { height = 15 })
    dialog_content:add_child(
        dialog_vb:row {
            spacing = 10,
            dialog_vb:button {
                text = "Save Labels",
                width = 100,
                notifier = function()
                    print("DEBUG: Save Labels button clicked")
                    
                    -- Stop any active preview
                    labeler.stop_slice_preview()
                    
                    -- Collect labels
                    local new_labels = {}
                    local current_show_label2 = get_show_label2 and get_show_label2() or false
                    local current_show_advanced_data = get_show_advanced_data and get_show_advanced_data() or false

                    for i, mapping in ipairs(mapping_data) do
                        -- Skip SRC (root) sample - it cannot have labels assigned
                        if mapping.hex_key == "00" then
                            goto continue_save_loop
                        end
                        
                        local label_popup = dialog_vb.views["label_" .. i]
                        local label2_popup = dialog_vb.views["label2_" .. i]
                        local breakpoint_field = dialog_vb.views["breakpoint_" .. i]
                        
                        -- Skip if controls don't exist (safety check)
                        if not label_popup or not breakpoint_field then
                            goto continue_save_loop
                        end
                        
                        local label2_value = "---------"
                        if current_show_label2 and label2_popup then
                            label2_value = label_popup.items[label2_popup.value]
                        end
                        
                        -- Collect advanced data values
                        local location_value = "Off-Center"
                        local ghost_value = false
                        local counterstroke_value = false
                        local cycle_value = false
                        
                        if current_show_advanced_data then
                            local location_popup = dialog_vb.views["location_" .. i]
                            local ghost_field = dialog_vb.views["ghost_" .. i]
                            local counterstroke_field = dialog_vb.views["counterstroke_" .. i]
                            local cycle_field = dialog_vb.views["cycle_" .. i]
                            
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
                        else
                            -- Preserve existing values when advanced data is hidden
                            location_value = mapping.location or "Off-Center"
                            ghost_value = mapping.ghost or false
                            counterstroke_value = mapping.counterstroke or false
                            cycle_value = mapping.cycle or false
                        end
                        
                        new_labels[mapping.hex_key] = {
                            label = label_popup.items[label_popup.value],
                            label2 = label2_value,
                            breakpoint = breakpoint_field.value,
                            instrument_index = current_instrument_index,
                            note_value = mapping.note_value,
                            is_slice = mapping.is_slice,
                            location = location_value,
                            ghost = ghost_value,
                            counterstroke = counterstroke_value,
                            cycle = cycle_value
                        }
                        
                        ::continue_save_loop::
                    end
                    
                    -- Store labels for current instrument
                    print("DEBUG: Storing labels for instrument", current_instrument_index)
                    labeler.store_labels_for_instrument(current_instrument_index, new_labels)

                    -- Check if we have breakpoints and assign global symbols
                    local has_breakpoints = false
                    for _, label_data in pairs(new_labels) do
                        if label_data.breakpoint then
                            has_breakpoints = true
                            break
                        end
                    end
                    
                    if has_breakpoints and assign_symbols_to_instrument then
                        local song = renoise.song()
                        local instrument = song.selected_instrument
                        if #instrument.phrases > 0 then
                            local original_phrase = instrument.phrases[1]
                            local breakpoints_module = require("breakpoints")
                            local break_sets = breakpoints_module.create_break_patterns(instrument, original_phrase, new_labels, current_instrument_index)
                            
                            if break_sets and #break_sets > 0 then
                                local assigned_symbols, error_msg = assign_symbols_to_instrument(current_instrument_index, break_sets, new_labels)
                                if assigned_symbols then
                                    print("DEBUG: Assigned symbols", table.concat(assigned_symbols, ", "), "to instrument", current_instrument_index)
                                    if save_global_symbol_registry then
                                        save_global_symbol_registry()
                                    end
                                    renoise.app():show_status(string.format("BreakFast labels saved. Assigned symbols: %s", table.concat(assigned_symbols, ", ")))
                                else
                                    renoise.app():show_warning("Labels saved, but could not assign symbols: " .. (error_msg or "Unknown error"))
                                end
                            else
                                renoise.app():show_warning("Labels saved, but no valid break sets were created.")
                            end
                        else
                            renoise.app():show_warning("Labels saved, but no phrases available for break pattern creation.")
                        end
                    end

                    -- Close dialog
                    print("DEBUG: Closing labeler dialog")
                    if dialog and dialog.visible then
                        dialog:close()
                        dialog = nil
                    end

                    -- Trigger refresh callback
                    print("DEBUG: Triggering refresh callback")
                    if labeler.refresh_callback then
                        labeler.refresh_callback()
                    end

                    if not has_breakpoints then
                        renoise.app():show_status("BreakFast labels saved")
                    end
                    print("DEBUG: Save Labels process completed")
                end
            },
            dialog_vb:button {
                text = "Manage Labels",
                width = 100,
                notifier = function()
                    labeler.show_manage_labels_dialog(dialog_vb, rebuild_dialog)
                end
            },
            dialog_vb:button {
                text = "Cancel",
                width = 80,
                notifier = function()
                    -- Stop any active preview
                    labeler.stop_slice_preview()
                    if dialog and dialog.visible then
                        dialog:close()
                        dialog = nil
                    end
                end
            }
        }
    )
    
    dialog = renoise.app():show_custom_dialog("BreakFast Labeler", dialog_content)
    labeler.dialog = dialog  -- Keep reference for external checking
end

-- ============================================================================
-- Symbol Labeler: Per-symbol labeling and breakpoint management
-- ============================================================================

-- Symbol labeler dialog reference
local symbol_labeler_dialog = nil

-- Show the symbol labeler dialog for a specific symbol
-- This allows users to relabel notes/slices within a symbol and add breakpoints
function labeler.show_symbol_labeler(symbol_name, on_save_callback)
    -- Get the global symbol registry
    if not get_global_symbol_registry then
        renoise.app():show_warning("Symbol registry not available")
        return
    end
    
    local registry = get_global_symbol_registry()
    if not registry then
        renoise.app():show_warning("Could not access symbol registry")
        return
    end
    
    local symbol_data = registry[symbol_name]
    if not symbol_data then
        renoise.app():show_warning("Symbol '" .. symbol_name .. "' not found in registry")
        return
    end
    
    local break_set = symbol_data.break_set
    if not break_set or not break_set.timing or #break_set.timing == 0 then
        renoise.app():show_warning("Symbol '" .. symbol_name .. "' has no timing data")
        return
    end
    
    -- Close any existing symbol labeler dialog
    if symbol_labeler_dialog and symbol_labeler_dialog.visible then
        symbol_labeler_dialog:close()
        symbol_labeler_dialog = nil
    end
    
    -- Stop any active preview
    labeler.stop_slice_preview()
    
    local dialog_vb = renoise.ViewBuilder()
    local instrument_index = symbol_data.instrument_index or 1
    
    -- Get saved labels for this instrument
    local saved_labels = symbol_data.saved_labels or {}
    local inst_labels = labeler.get_labels_for_instrument(instrument_index)
    if inst_labels then
        for k, v in pairs(inst_labels) do
            if not saved_labels[k] then
                saved_labels[k] = v
            end
        end
    end
    
    -- Get all available labels for dropdowns
    local all_labels = labeler.get_all_labels()
    
    -- Note name lookup
    local note_names = {"C-", "C#", "D-", "D#", "E-", "F-", "F#", "G-", "G#", "A-", "A#", "B-"}
    
    local function note_to_string(note_val)
        if note_val == 120 then return "OFF"
        elseif note_val == 121 or note_val == 255 then return "---"
        else
            local octave = math.floor(note_val / 12) - 2
            local note_index = (note_val % 12) + 1
            return string.format("%s%d", note_names[note_index], octave)
        end
    end
    
    -- Build dialog content
    local dialog_content = dialog_vb:column {
        margin = 10,
        spacing = 5,
        
        -- Header row with Play All button
        dialog_vb:row {
            spacing = 10,
            dialog_vb:text {
                text = "Symbol Labeler: " .. symbol_name,
                font = "bold",
                style = "strong"
            },
            dialog_vb:button {
                text = "Play All",
                width = 60,
                tooltip = "Preview entire symbol " .. symbol_name,
                notifier = function()
                    -- Stop any slice preview first
                    labeler.stop_slice_preview()
                    -- Call the main preview_symbol function
                    if preview_symbol_callback then
                        preview_symbol_callback(symbol_name)
                    else
                        print("DEBUG: preview_symbol_callback not set")
                    end
                end
            }
        },
        
        -- Instrument info
        dialog_vb:row {
            dialog_vb:text {
                text = string.format("Instrument: %02X | Notes: %d", instrument_index - 1, #break_set.timing),
                style = "disabled"
            }
        },
        
        dialog_vb:space { height = 5 },
        
        -- Column headers
        dialog_vb:row {
            spacing = 5,
            dialog_vb:text { text = "#", width = 25, font = "bold" },
            dialog_vb:text { text = "Note", width = 45, font = "bold" },
            dialog_vb:text { text = "Slice", width = 40, font = "bold" },
            dialog_vb:text { text = "Label", width = 100, font = "bold" },
            dialog_vb:text { text = "BP", width = 25, font = "bold" },
            dialog_vb:text { text = "", width = 25 }  -- Preview column
        },
        
        dialog_vb:space { height = 2 }
    }
    
    -- Create rows for each timing entry
    local timing_entries = break_set.timing
    local max_visible_rows = 16  -- Limit visible rows for usability
    local show_scroll_hint = #timing_entries > max_visible_rows
    
    -- Container for timing rows (scrollable if needed)
    local rows_container = dialog_vb:column {
        id = "timing_rows_container",
        spacing = 2
    }
    
    for i, timing in ipairs(timing_entries) do
        local note_val = timing.note_value or 0
        local instrument_val = timing.instrument_value or 0
        local hex_key = string.format("%02X", instrument_val)
        
        -- Get current label for this slice/note
        local current_label = "---------"
        local current_breakpoint = timing.breakpoint or false
        
        if saved_labels[hex_key] then
            current_label = saved_labels[hex_key].label or "---------"
        end
        
        -- Find label index in dropdown
        local label_index = 1
        for li, label in ipairs(all_labels) do
            if label == current_label then
                label_index = li
                break
            end
        end
        
        local row = dialog_vb:row {
            spacing = 5,
            
            -- Index
            dialog_vb:text {
                text = string.format("%02d", i),
                width = 25,
                style = "disabled"
            },
            
            -- Note value
            dialog_vb:text {
                text = note_to_string(note_val),
                width = 45
            },
            
            -- Slice/instrument value
            dialog_vb:text {
                text = hex_key,
                width = 40
            },
            
            -- Label dropdown
            dialog_vb:popup {
                id = "sym_label_" .. i,
                items = all_labels,
                value = label_index,
                width = 100
            },
            
            -- Breakpoint checkbox
            dialog_vb:checkbox {
                id = "sym_bp_" .. i,
                value = current_breakpoint,
                width = 25
            },
            
            -- Preview button
            dialog_vb:button {
                id = "sym_preview_" .. i,
                text = ">",
                width = 25,
                notifier = function()
                    local button_id = "sym_preview_" .. i
                    -- Calculate correct slice trigger note: slice N triggers at note 36 + N
                    local slice_trigger_note = 36 + instrument_val
                    labeler.toggle_slice_preview(instrument_index, slice_trigger_note, button_id, dialog_vb)
                end
            }
        }
        
        rows_container:add_child(row)
    end
    
    dialog_content:add_child(rows_container)
    
    if show_scroll_hint then
        dialog_content:add_child(dialog_vb:text {
            text = string.format("Showing all %d entries", #timing_entries),
            style = "disabled"
        })
    end
    
    -- Helper function to collect updated data from dialog
    local function collect_updated_data()
        local updated_labels = {}
        local breakpoint_indices = {}  -- Track which timing indices have breakpoints
        
        for i, timing in ipairs(timing_entries) do
            local label_popup = dialog_vb.views["sym_label_" .. i]
            local bp_checkbox = dialog_vb.views["sym_bp_" .. i]
            
            if label_popup and bp_checkbox then
                local selected_label = all_labels[label_popup.value]
                local is_breakpoint = bp_checkbox.value
                
                -- Store breakpoint state in timing entry
                timing.breakpoint = is_breakpoint
                
                -- Track breakpoint indices (skip first entry - can't break before first note)
                if is_breakpoint and i > 1 then
                    table.insert(breakpoint_indices, i)
                end
                
                -- Update saved_labels for this slice
                local hex_key = string.format("%02X", timing.instrument_value or 0)
                if not updated_labels[hex_key] then
                    updated_labels[hex_key] = saved_labels[hex_key] or {}
                end
                updated_labels[hex_key].label = selected_label
                updated_labels[hex_key].breakpoint = is_breakpoint
            end
        end
        
        return updated_labels, breakpoint_indices
    end
    
    -- Helper function to save labels to symbol data
    local function save_labels_to_symbol(updated_labels)
        for hex_key, label_data in pairs(updated_labels) do
            if not symbol_data.saved_labels then
                symbol_data.saved_labels = {}
            end
            if not symbol_data.saved_labels[hex_key] then
                symbol_data.saved_labels[hex_key] = {}
            end
            symbol_data.saved_labels[hex_key].label = label_data.label
            symbol_data.saved_labels[hex_key].breakpoint = label_data.breakpoint
        end
        
        -- Save the global registry
        if save_global_symbol_registry then
            save_global_symbol_registry()
        end
    end
    
    -- Helper function to create new symbols from breakpoints
    local function create_symbols_from_breakpoints(breakpoint_indices)
        if #breakpoint_indices == 0 then
            return nil, "No breakpoints marked (excluding first note)"
        end
        
        -- Sort breakpoint indices
        table.sort(breakpoint_indices)
        
        -- Create break sets by splitting timing at breakpoints
        local new_break_sets = {}
        local boundaries = {1}  -- Start with first note
        for _, bp_idx in ipairs(breakpoint_indices) do
            table.insert(boundaries, bp_idx)
        end
        table.insert(boundaries, #timing_entries + 1)  -- End boundary
        
        print("DEBUG: Creating symbols from breakpoint boundaries:", table.concat(boundaries, ", "))
        print("DEBUG: Total timing entries:", #timing_entries)
        
        for i = 1, #boundaries - 1 do
            local start_idx = boundaries[i]
            local end_idx = boundaries[i + 1] - 1
            
            if end_idx >= start_idx then
                local new_timing = {}
                local first_entry = timing_entries[start_idx]
                local first_line = first_entry.relative_line or 1
                local first_delay = first_entry.new_delay or 0
                
                print("DEBUG: Break set", i, "from index", start_idx, "to", end_idx)
                print("DEBUG: First entry - line:", first_line, "delay:", first_delay)
                
                for j = start_idx, end_idx do
                    local orig_timing = timing_entries[j]
                    -- Deep copy timing entry
                    local new_entry = {}
                    for k, v in pairs(orig_timing) do
                        if type(v) == "table" then
                            new_entry[k] = {}
                            for kk, vv in pairs(v) do
                                new_entry[k][kk] = vv
                            end
                        else
                            new_entry[k] = v
                        end
                    end
                    
                    -- Adjust relative_line to start from 1
                    local orig_line = orig_timing.relative_line or 1
                    local orig_delay = orig_timing.new_delay or 0
                    
                    -- Calculate new delay relative to first note of this segment
                    local adjusted_delay = orig_delay - first_delay
                    local adjusted_line = orig_line - first_line + 1
                    
                    -- Handle negative delay by moving to previous line
                    if adjusted_delay < 0 then
                        adjusted_line = adjusted_line - 1
                        adjusted_delay = 256 + adjusted_delay
                    end
                    
                    -- For the first note, delay should always be 0
                    if j == start_idx then
                        new_entry.relative_line = 1
                        new_entry.new_delay = 0
                    else
                        new_entry.relative_line = adjusted_line
                        new_entry.new_delay = adjusted_delay
                    end
                    
                    print("DEBUG: Entry", j - start_idx + 1, "- orig line:", orig_line, "orig delay:", orig_delay, 
                          "-> new line:", new_entry.relative_line, "new delay:", new_entry.new_delay)
                    
                    table.insert(new_timing, new_entry)
                end
                
                local new_break_set = {
                    timing = new_timing,
                    start_line = 1,
                    end_line = new_timing[#new_timing].relative_line or 1
                }
                
                table.insert(new_break_sets, new_break_set)
                print("DEBUG: Created break set", i, "with", #new_timing, "notes")
            end
        end
        
        return new_break_sets
    end
    
    -- Action buttons
    dialog_content:add_child(dialog_vb:space { height = 10 })
    dialog_content:add_child(
        dialog_vb:row {
            spacing = 5,
            
            -- Save & Create Symbols button
            dialog_vb:button {
                text = "Save & Create",
                width = 90,
                tooltip = "Save labels and create new symbols from marked breakpoints",
                notifier = function()
                    -- Stop any active preview
                    labeler.stop_slice_preview()
                    
                    -- Collect updated data
                    local updated_labels, breakpoint_indices = collect_updated_data()
                    
                    print("DEBUG: Save & Create - breakpoint_indices count:", #breakpoint_indices)
                    for idx, bp in ipairs(breakpoint_indices) do
                        print("DEBUG: Breakpoint", idx, "at timing index", bp)
                    end
                    
                    -- Check if there are breakpoints to create symbols from
                    if #breakpoint_indices == 0 then
                        renoise.app():show_warning("No breakpoints marked. Mark at least one note (not the first) as a breakpoint to split the symbol.")
                        return
                    end
                    
                    -- Create new break sets from breakpoints
                    local new_break_sets, error_msg = create_symbols_from_breakpoints(breakpoint_indices)
                    
                    print("DEBUG: Created", new_break_sets and #new_break_sets or 0, "break sets")
                    
                    if not new_break_sets or #new_break_sets == 0 then
                        renoise.app():show_warning("Could not create symbols: " .. (error_msg or "No break sets created"))
                        return
                    end
                    
                    -- Assign new symbols to the break sets
                    if assign_symbols_to_instrument then
                        print("DEBUG: Calling assign_symbols_to_instrument with", #new_break_sets, "break sets")
                        
                        local assigned_symbols, assign_error = assign_symbols_to_instrument(
                            instrument_index, 
                            new_break_sets, 
                            symbol_data.saved_labels or {}
                        )
                        
                        print("DEBUG: assign_symbols_to_instrument returned:", assigned_symbols and table.concat(assigned_symbols, ", ") or "nil", "error:", assign_error or "none")
                        
                        if assigned_symbols and #assigned_symbols > 0 then
                            -- Save labels to symbol data
                            save_labels_to_symbol(updated_labels)
                            
                            -- IMPORTANT: Save the global registry to persist the new symbols
                            if save_global_symbol_registry then
                                save_global_symbol_registry()
                                print("DEBUG: Saved global symbol registry")
                            end
                            
                            print("DEBUG: Created new symbols:", table.concat(assigned_symbols, ", "))
                            renoise.app():show_status(string.format(
                                "Created %d new symbols: %s", 
                                #assigned_symbols, 
                                table.concat(assigned_symbols, ", ")
                            ))
                            
                            -- Close dialog
                            if symbol_labeler_dialog and symbol_labeler_dialog.visible then
                                symbol_labeler_dialog:close()
                                symbol_labeler_dialog = nil
                            end
                            
                            -- Trigger callback if provided (this should refresh the main dialog)
                            if on_save_callback then
                                on_save_callback()
                            end
                        else
                            renoise.app():show_warning("Could not assign symbols: " .. (assign_error or "Unknown error"))
                        end
                    else
                        renoise.app():show_warning("Symbol assignment function not available")
                        print("DEBUG: assign_symbols_to_instrument is nil!")
                    end
                end
            },
            
            -- Save Only button
            dialog_vb:button {
                text = "Save Only",
                width = 70,
                tooltip = "Save labels without creating new symbols",
                notifier = function()
                    -- Stop any active preview
                    labeler.stop_slice_preview()
                    
                    -- Collect updated data
                    local updated_labels, _ = collect_updated_data()
                    
                    -- Save labels to symbol data
                    save_labels_to_symbol(updated_labels)
                    
                    print("DEBUG: Symbol labeler saved for symbol " .. symbol_name)
                    renoise.app():show_status("Symbol " .. symbol_name .. " labels saved")
                    
                    -- Close dialog
                    if symbol_labeler_dialog and symbol_labeler_dialog.visible then
                        symbol_labeler_dialog:close()
                        symbol_labeler_dialog = nil
                    end
                    
                    -- Trigger callback if provided
                    if on_save_callback then
                        on_save_callback()
                    end
                end
            },
            
            -- Cancel button
            dialog_vb:button {
                text = "Cancel",
                width = 60,
                notifier = function()
                    -- Stop any active preview
                    labeler.stop_slice_preview()
                    
                    if symbol_labeler_dialog and symbol_labeler_dialog.visible then
                        symbol_labeler_dialog:close()
                        symbol_labeler_dialog = nil
                    end
                end
            }
        }
    )
    
    -- Show dialog
    symbol_labeler_dialog = renoise.app():show_custom_dialog(
        "Symbol Labeler: " .. symbol_name,
        dialog_content
    )
end

-- Check if symbol labeler dialog is open
function labeler.is_symbol_labeler_open()
    return symbol_labeler_dialog and symbol_labeler_dialog.visible
end

-- Close symbol labeler dialog
function labeler.close_symbol_labeler()
    labeler.stop_slice_preview()
    if symbol_labeler_dialog and symbol_labeler_dialog.visible then
        symbol_labeler_dialog:close()
        symbol_labeler_dialog = nil
    end
end

-- Cleanup function
function labeler.cleanup()
    -- Stop any active preview
    labeler.stop_slice_preview()
    -- Close symbol labeler if open
    labeler.close_symbol_labeler()
    if dialog and dialog.visible then
        dialog:close()
        dialog = nil
        labeler.dialog = nil  -- Clear external reference
    end
end

return labeler