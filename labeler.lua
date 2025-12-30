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

-- Global symbol registry access (will be set by main.lua)
local get_global_symbol_registry = nil
local assign_symbols_to_instrument = nil
local save_global_symbol_registry = nil
local get_custom_labels_data = nil
local save_custom_labels_data = nil
local get_show_label2 = nil
local save_show_label2 = nil

-- Custom label management
labeler.custom_labels = {
    builtin = {"---------", "Kick", "Snare", "Hi Hat Closed", "Hi Hat Open", 
               "Crash", "Tom", "Ride", "Shaker", "Tambourine", "Cowbell"},
    user = {}
}

-- Set global symbol registry functions (extended with preference accessors)
function labeler.set_global_symbol_functions(get_registry_func, assign_symbols_func, save_registry_func,
                                              get_custom_labels_func, save_custom_labels_func,
                                              get_show_label2_func, save_show_label2_func)
    get_global_symbol_registry = get_registry_func
    assign_symbols_to_instrument = assign_symbols_func
    save_global_symbol_registry = save_registry_func
    get_custom_labels_data = get_custom_labels_func
    save_custom_labels_data = save_custom_labels_func
    get_show_label2 = get_show_label2_func
    save_show_label2 = save_show_label2_func
    
    -- Load custom labels from preferences on initialization
    labeler.load_custom_labels()
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
    
    -- Full header for BreakPal/HotSwap compatibility
    file:write("Index,Label,Label 2,Breakpoint,Cycle,Roll,Ghost,Shuffle,[Ref]Instrument,[Ref]SliceNote\n")

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
            "false",  -- Cycle (not used by BreakFast)
            "false",  -- Roll (not used by BreakFast)
            "false",  -- Ghost (not used by BreakFast)
            "false",  -- Shuffle (not used by BreakFast)
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
        -- We read but ignore these columns from BreakPal/HotSwap
        elseif lower_field == "cycle" then
            column_positions.cycle = i
        elseif lower_field == "roll" then
            column_positions.roll = i
        elseif lower_field == "ghost" then
            column_positions.ghost = i
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

    -- Note: Label 2 and Instrument columns are optional for backward compatibility

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

        new_labels[index] = {
            label = unescape_csv_field(fields[column_positions.label]),
            label2 = label2,
            breakpoint = str_to_bool(fields[column_positions.breakpoint]),
            instrument_index = instrument_index
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
        
        saved_label = saved_label or { label = "---------", label2 = "---------", breakpoint = false }
        
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
            breakpoint = saved_label.breakpoint or false
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
        if dialog and dialog.visible then
            dialog:close()
            dialog = nil
        end
        labeler.show_dialog()
    end
    
    -- Build header row based on show_label2 state
    local header_row
    if show_label2 then
        header_row = dialog_vb:row {
            spacing = spacing,
            dialog_vb:text { text = "Note", width = narrow_column, align = "center", font = "bold" },
            dialog_vb:text { text = "Sample", width = column_width, align = "center", font = "bold" },
            dialog_vb:text { text = "Label", width = column_width, align = "center", font = "bold" },
            dialog_vb:button { 
                text = "[-]", 
                width = 25,
                tooltip = "Hide Label 2 column",
                notifier = function()
                    if save_show_label2 then save_show_label2(false) end
                    rebuild_dialog()
                end
            },
            dialog_vb:text { text = "Label 2", width = column_width, align = "center", font = "bold" },
            dialog_vb:text { text = "Breakpoint", width = 70, align = "center", font = "bold" }
        }
    else
        header_row = dialog_vb:row {
            spacing = spacing,
            dialog_vb:text { text = "Note", width = narrow_column, align = "center", font = "bold" },
            dialog_vb:text { text = "Sample", width = column_width, align = "center", font = "bold" },
            dialog_vb:text { text = "Label", width = column_width, align = "center", font = "bold" },
            dialog_vb:button { 
                text = "[+]", 
                width = 25,
                tooltip = "Show Label 2 column",
                notifier = function()
                    if save_show_label2 then save_show_label2(true) end
                    rebuild_dialog()
                end
            },
            dialog_vb:text { text = "Breakpoint", width = 70, align = "center", font = "bold" }
        }
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
        local row_elements = {
            -- Note
            dialog_vb:text { 
                text = mapping.display_note, 
                width = narrow_column, 
                align = "center" 
            },
            
            -- Sample name (truncated)
            dialog_vb:text { 
                text = mapping.sample_name:sub(1, 15), 
                width = column_width, 
                align = "left",
                tooltip = mapping.sample_name
            },
            
            -- Label dropdown
            dialog_vb:popup {
                id = "label_" .. i,
                items = label_options,
                width = column_width,
                value = table.find(label_options, mapping.label) or 1
            }
        }
        
        if show_label2 then
            -- Spacer for toggle button alignment
            table.insert(row_elements, dialog_vb:space { width = 25 })
            
            -- Label 2 dropdown
            table.insert(row_elements, dialog_vb:popup {
                id = "label2_" .. i,
                items = label_options,
                width = column_width,
                value = table.find(label_options, mapping.label2) or 1
            })
        else
            -- Spacer for toggle button alignment
            table.insert(row_elements, dialog_vb:space { width = 25 })
        end
        
        -- Breakpoint checkbox
        table.insert(row_elements, dialog_vb:horizontal_aligner {
            mode = "center",
            width = 70,
            dialog_vb:checkbox {
                id = "breakpoint_" .. i,
                value = mapping.breakpoint,
                notifier = function(value)
                    -- Count current breakpoints
                    local current_count = 0
                    for j = 1, #mapping_data do
                        local other_checkbox = dialog_vb.views["breakpoint_" .. j]
                        if other_checkbox and other_checkbox.value then
                            current_count = current_count + 1
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
                    
                    -- Collect labels
                    local new_labels = {}
                    local current_show_label2 = get_show_label2 and get_show_label2() or false

                    for i, mapping in ipairs(mapping_data) do
                        local label_popup = dialog_vb.views["label_" .. i]
                        local label2_popup = dialog_vb.views["label2_" .. i]
                        local breakpoint_field = dialog_vb.views["breakpoint_" .. i]
                        
                        local label2_value = "---------"
                        if current_show_label2 and label2_popup then
                            label2_value = label_popup.items[label2_popup.value]
                        end
                        
                        new_labels[mapping.hex_key] = {
                            label = label_popup.items[label_popup.value],
                            label2 = label2_value,
                            breakpoint = breakpoint_field.value,
                            instrument_index = current_instrument_index,
                            note_value = mapping.note_value,
                            is_slice = mapping.is_slice
                        }
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

-- Cleanup function
function labeler.cleanup()
    if dialog and dialog.visible then
        dialog:close()
        dialog = nil
        labeler.dialog = nil  -- Clear external reference
    end
end

return labeler