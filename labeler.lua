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

-- Set global symbol registry functions
function labeler.set_global_symbol_functions(get_registry_func, assign_symbols_func, save_registry_func)
    get_global_symbol_registry = get_registry_func
    assign_symbols_to_instrument = assign_symbols_func
    save_global_symbol_registry = save_registry_func
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

-- Export labels to CSV
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
    
    -- Simplified header for BreakFast
    file:write("Index,Label,Breakpoint,Instrument\n")

    for hex_key, data in pairs(labeler.saved_labels) do
        local values = {
            hex_key,
            data.label or "",
            tostring(data.breakpoint or false),
            tostring(data.instrument_index or 1)  -- Export instrument index, default to 1 if missing
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
    
    -- Look for required columns (case insensitive)
    for i, field in ipairs(header_fields) do
        local lower_field = field:lower()
        if lower_field == "index" then
            column_positions.index = i
        elseif lower_field == "label" then
            column_positions.label = i
        elseif lower_field == "breakpoint" then
            column_positions.breakpoint = i
        elseif lower_field == "instrument" then
            column_positions.instrument = i  -- Optional instrument column
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

    -- Note: Instrument column is optional for backward compatibility

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
        
        -- Create simplified label structure using only the columns we need
        -- Get current instrument index for fallback (import function context)
        local song = renoise.song()
        local current_instrument_index = song.selected_instrument_index
        local instrument_index = current_instrument_index  -- Default to current selection

        if column_positions.instrument and #fields >= column_positions.instrument then
            -- Use imported instrument value if available
            local imported_instrument = tonumber(unescape_csv_field(fields[column_positions.instrument]))
            if imported_instrument and imported_instrument > 0 then
                instrument_index = imported_instrument
            end
        end

        new_labels[index] = {
            label = unescape_csv_field(fields[column_positions.label]),
            breakpoint = str_to_bool(fields[column_positions.breakpoint]),
            instrument_index = instrument_index  -- Store the determined instrument index
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
    
    if #samples < 2 then
        renoise.app():show_warning("No sliced samples found. Please load a sliced sample first.")
        return
    end
    
    -- Get saved labels for current instrument
    local current_labels = labeler.get_labels_for_instrument(current_instrument_index)
    
    -- Prepare slice data
    local slice_data = {}
    for j = 2, #samples do
        local sample = samples[j]
        local hex_key = string.format("%02X", j)
        local saved_label = current_labels[hex_key] or {
            label = "",
            breakpoint = false
        }
        
        table.insert(slice_data, {
            index = j - 1,
            hex_index = string.format("%02X", j - 1),
            sample_name = sample.name,
            label = saved_label.label,
            breakpoint = saved_label.breakpoint
        })
    end
    
    local scale_factor = calculate_scale_factor(#slice_data)
    local column_width = 120
    local spacing = 10
    local row_height = math.max(20, math.min(30, 30 * scale_factor))
    
    -- Create dialog content
    local dialog_content = dialog_vb:column {
        spacing = spacing,
        margin = 10,
        
        dialog_vb:text {
            text = "BreakFast Slice Labeler",
            font = "big",
            style = "strong"
        },
        
        dialog_vb:space { height = 10 },
        
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
            }
        },
        
        dialog_vb:space { height = 10 },
        
        -- Header row
        dialog_vb:row {
            spacing = spacing,
            dialog_vb:text { text = "Slice", width = column_width, align = "center", font = "bold" },
            dialog_vb:text { text = "Label", width = column_width, align = "center", font = "bold" },
            dialog_vb:text { text = "Breakpoint", width = column_width, align = "center", font = "bold" }
        }
    }
    
    -- Add slice rows directly to dialog_content
    for _, slice in ipairs(slice_data) do
        local row = dialog_vb:row {
            spacing = spacing,
            height = row_height,
            
            -- Slice index
            dialog_vb:text { 
                text = "#" .. slice.hex_index, 
                width = column_width, 
                align = "center" 
            },
            
            -- Label dropdown (matching BreakPal)
            dialog_vb:popup {
                id = "label_" .. slice.index,
                items = {"---------", "Kick", "Snare", "Hi Hat Closed", "Hi Hat Open", "Crash", "Tom", "Ride", "Shaker", "Tambourine", "Cowbell"},
                width = column_width,
                value = table.find({"---------", "Kick", "Snare", "Hi Hat Closed", "Hi Hat Open", "Crash", "Tom", "Ride", "Shaker", "Tambourine", "Cowbell"}, slice.label) or 1
            },
            
            -- Breakpoint checkbox
            dialog_vb:horizontal_aligner {
                mode = "center",
                width = column_width,
                dialog_vb:checkbox {
                    id = "breakpoint_" .. slice.index,
                    value = slice.breakpoint,
                    notifier = function(value)
                        -- Count current breakpoints
                        local current_count = 0
                        for _, other_slice in ipairs(slice_data) do
                            local other_checkbox = dialog_vb.views["breakpoint_" .. other_slice.index]
                            if other_checkbox and other_checkbox.value then
                                current_count = current_count + 1
                            end
                        end
                        
                        -- Limit to 5 breakpoints (6 sections maximum)
                        if value and current_count > 5 then
                            dialog_vb.views["breakpoint_" .. slice.index].value = false
                            renoise.app():show_warning(
                                "Maximum 5 breakpoints allowed (creates 6 sections)."
                            )
                        end
                    end
                }
            }
        }
        
        dialog_content:add_child(row)
    end
    
    -- Add action buttons
    dialog_content:add_child(dialog_vb:space { height = 15 })
    dialog_content:add_child(
        dialog_vb:row {
            spacing = 10,
            dialog_vb:button {
                text = "Save Labels",
                width = 120,
                notifier = function()
                    print("DEBUG: Save Labels button clicked")
                    
                    -- Collect labels
                    local new_labels = {}

                    for _, slice in ipairs(slice_data) do
                        local hex_key = string.format("%02X", slice.index + 1)
                        local label_popup = dialog_vb.views["label_" .. slice.index]
                        local breakpoint_field = dialog_vb.views["breakpoint_" .. slice.index]
                        
                        new_labels[hex_key] = {
                            label = label_popup.items[label_popup.value],
                            breakpoint = breakpoint_field.value,
                            instrument_index = current_instrument_index  -- Store instrument index from dialog context
                        }
                    end
                    
                    -- Store labels for current instrument
                    print("DEBUG: Storing labels for instrument", current_instrument_index, "with", (function() local count = 0; for _ in pairs(new_labels) do count = count + 1 end; return count end)(), "labels")
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

                    -- Trigger refresh callback (like import does)
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