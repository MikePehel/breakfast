-- selection.lua - Range Selection Capture Module for BreakFast
local selection = {}

-- Global symbol registry access (will be set by main.lua)
local get_global_symbol_registry = nil
local find_next_available_symbols = nil
local save_global_symbol_registry = nil

-- Set global symbol registry functions
function selection.set_global_symbol_functions(get_registry_func, find_symbols_func, save_registry_func)
    get_global_symbol_registry = get_registry_func
    find_next_available_symbols = find_symbols_func
    save_global_symbol_registry = save_registry_func
end

-- Validate that a selection exists and contains notes
function selection.validate_selection()
    if not renoise.song() then
        return false, "Song not available"
    end
    
    local song = renoise.song()
    local selection = song.selection_in_pattern
    
    if not selection then
        return false, "No selection found. Please select a range in the pattern editor first."
    end
    
    -- Ensure we have valid selection bounds
    if not selection.start_line or not selection.end_line or 
       not selection.start_track or not selection.end_track then
        return false, "Invalid selection. Please ensure you have selected a complete range."
    end
    
    -- Ensure selection is within a single track for now
    if selection.start_track ~= selection.end_track then
        return false, "Multi-track selections are not currently supported. Please select within a single track."
    end
    
    return true, selection
end

-- Extract note data from the current selection
function selection.extract_notes_from_selection()
    local success, selection_data = selection.validate_selection()
    if not success then
        return nil, selection_data -- selection_data contains error message
    end
    
    local song = renoise.song()
    local pattern = song.selected_pattern
    local track = pattern:track(selection_data.start_track)
    
    local notes = {}
    local selection_start_line = selection_data.start_line
    local has_notes = false
    
    print("DEBUG: Extracting notes from selection - lines " .. selection_data.start_line .. " to " .. selection_data.end_line)
    
    -- Extract all content within the selection range (notes, effects, volume, pan, delay)
    for line_idx = selection_data.start_line, selection_data.end_line do
        local line = track:line(line_idx)
        local note_column = line:note_column(1) -- Focus on first note column for primary data
        
        -- Check if line has any meaningful content
        local line_has_content = false
        local content_type = "empty"
        
        -- Check for note content
        if note_column.note_value ~= renoise.PatternLine.EMPTY_NOTE then
            line_has_content = true
            content_type = "note"
        end
        
        -- Check for volume/pan/delay content in note columns
        if not line_has_content then
            for col = 1, 12 do
                local nc = line:note_column(col)
                if nc.volume_value ~= renoise.PatternLine.EMPTY_VOLUME or
                   nc.panning_value ~= renoise.PatternLine.EMPTY_PANNING or
                   nc.delay_value ~= renoise.PatternLine.EMPTY_DELAY or
                   nc.effect_number_value ~= renoise.PatternLine.EMPTY_EFFECT_NUMBER then
                    line_has_content = true
                    if nc.volume_value ~= renoise.PatternLine.EMPTY_VOLUME then
                        content_type = "volume"
                    elseif nc.panning_value ~= renoise.PatternLine.EMPTY_PANNING then
                        content_type = "panning"
                    elseif nc.delay_value ~= renoise.PatternLine.EMPTY_DELAY then
                        content_type = "delay"
                    else
                        content_type = "note_effect"
                    end
                    break
                end
            end
        end
        
        -- Check for effect column content
        if not line_has_content then
            for col = 1, 8 do
                local ec = line:effect_column(col)
                if ec.number_value ~= renoise.PatternLine.EMPTY_EFFECT_NUMBER then
                    line_has_content = true
                    content_type = "effect"
                    break
                end
            end
        end
        
        if line_has_content then
            has_notes = true
            
            -- Calculate relative line position (1-based from selection start)
            local relative_line = line_idx - selection_start_line + 1
            
            -- Validate note values before storing (if note is present)
            local note_value = note_column.note_value
            local instrument_value = note_column.instrument_value
            
            -- Log the raw values for debugging
            print("DEBUG: Raw content - line:" .. line_idx .. ", type:" .. content_type .. ", note:" .. note_value .. ", inst:" .. instrument_value)
            
            -- Ensure note value is in valid range (0-121) or empty (121)
            if note_value >= 0 and note_value <= 121 then
                -- Ensure instrument value is in valid range (0-254, 255 is empty)
                if instrument_value > 254 then
                    print("WARNING: Invalid instrument value " .. instrument_value .. " at line " .. line_idx .. ", clamping to 254")
                    instrument_value = 254
                end
                
                local note_data = {
                    line = relative_line,
                    absolute_line = line_idx,
                    note_value = note_value,
                    instrument_value = instrument_value,
                    volume_value = note_column.volume_value,
                    panning_value = note_column.panning_value,
                    delay_value = note_column.delay_value,
                    effect_number_value = note_column.effect_number_value,
                    effect_amount_value = note_column.effect_amount_value,
                    distance_to_next = 0, -- Will be calculated in next step
                    -- NEW: Enhanced content information
                    has_note = (note_value ~= renoise.PatternLine.EMPTY_NOTE),
                    content_type = content_type
                }
                
                -- Capture all 12 note columns for this line
                note_data.note_columns = {}
                for note_col = 1, 12 do
                    local note_column_data = line:note_column(note_col)
                    if note_column_data then
                        -- Always capture note column data, even if empty (for complete data preservation)
                        note_data.note_columns[note_col] = {
                            note_value = note_column_data.note_value,
                            instrument_value = note_column_data.instrument_value,
                            volume_value = note_column_data.volume_value,
                            panning_value = note_column_data.panning_value,
                            delay_value = note_column_data.delay_value,
                            effect_number_value = note_column_data.effect_number_value,
                            effect_amount_value = note_column_data.effect_amount_value
                        }
                    end
                end
                
                -- Capture all 8 effect columns for this line
                note_data.effect_columns = {}
                for fx_col = 1, 8 do
                    local effect_column = line:effect_column(fx_col)
                    if effect_column then
                        -- Always capture effect column data, even if empty (for complete data preservation)
                        note_data.effect_columns[fx_col] = {
                            number_value = effect_column.number_value,
                            amount_value = effect_column.amount_value
                        }
                    end
                end
                
                table.insert(notes, note_data)
                print("DEBUG: Extracted note at line " .. line_idx .. " (relative " .. relative_line .. "): " .. 
                      "note=" .. note_data.note_value .. ", inst=" .. note_data.instrument_value .. ", delay=" .. note_data.delay_value)
            else
                print("WARNING: Invalid note value " .. note_value .. " at line " .. line_idx .. ", skipping")
            end
        end
    end
    
    if not has_notes then
        return nil, "No valid content found in selection. Please select a range that contains notes, effects, volume, panning, or delay data."
    end
    
    -- Calculate distances between notes and trailing space
    selection.calculate_note_distances(notes, selection_data, pattern)
    
    return notes, selection_data
end

-- Calculate timing distances between content lines (notes, effects, etc.)
function selection.calculate_note_distances(notes, selection_data, pattern)
    print("DEBUG: Calculating content distances for " .. #notes .. " content lines")
    
    local song = renoise.song()
    local track = pattern:track(selection_data.start_track)
    
    for i = 1, #notes do
        local current_content = notes[i]
        local current_delay = current_content.delay_value
        local found_next = false
        
        -- Look for next content within our extracted notes
        for j = i + 1, #notes do
            local next_content = notes[j]
            local lines_to_next = next_content.line - current_content.line
            local next_delay = next_content.delay_value
            current_content.distance_to_next = (lines_to_next * 256) - current_delay + next_delay
            found_next = true
            print("DEBUG: Content " .. i .. " (" .. current_content.content_type .. ") distance to next: " .. current_content.distance_to_next)
            break
        end
        
        -- If no next content found within selection, look for the next content in the entire pattern
        if not found_next then
            local current_absolute_line = current_content.absolute_line
            print("DEBUG: Looking for next content after absolute line " .. current_absolute_line .. " in full pattern")
            
            -- Search for the next content beyond the selection in the entire pattern
            for line_idx = selection_data.end_line + 1, pattern.number_of_lines do
                local line = track:line(line_idx)
                
                -- Check if this line has any content
                local line_has_content = false
                
                -- Check note columns for content
                for col = 1, 12 do
                    local nc = line:note_column(col)
                    if nc.note_value ~= renoise.PatternLine.EMPTY_NOTE or
                       nc.volume_value ~= renoise.PatternLine.EMPTY_VOLUME or
                       nc.panning_value ~= renoise.PatternLine.EMPTY_PANNING or
                       nc.delay_value ~= renoise.PatternLine.EMPTY_DELAY or
                       nc.effect_number_value ~= renoise.PatternLine.EMPTY_EFFECT_NUMBER then
                        line_has_content = true
                        break
                    end
                end
                
                -- Check effect columns for content if no note content found
                if not line_has_content then
                    for col = 1, 8 do
                        local ec = line:effect_column(col)
                        if ec.number_value ~= renoise.PatternLine.EMPTY_EFFECT_NUMBER then
                            line_has_content = true
                            break
                        end
                    end
                end
                
                if line_has_content then
                    -- Found the next content beyond the selection
                    local lines_to_next = line_idx - current_absolute_line
                    local next_delay = line:note_column(1).delay_value  -- Use first note column delay as reference
                    current_content.distance_to_next = (lines_to_next * 256) - current_delay + next_delay
                    found_next = true
                    print("DEBUG: Last content " .. i .. " distance to next content at line " .. line_idx .. ": " .. current_content.distance_to_next)
                    break
                end
            end
            
            -- If still no next content found, calculate distance to end of pattern
            if not found_next then
                local lines_to_end = (pattern.number_of_lines + 1) - current_absolute_line
                current_content.distance_to_next = (lines_to_end * 256) - current_delay
                print("DEBUG: Last content " .. i .. " distance to end of pattern: " .. current_content.distance_to_next)
            end
        end
    end
end

-- Apply labels from the current instrument's BreakFast labeler data to a range symbol
function selection.apply_labels_to_range_symbol(symbol_data, notes)
    print("DEBUG: Applying labels to range symbol")
    
    if not renoise.song() then
        print("DEBUG: No song available for label mapping")
        return {}
    end
    
    local song = renoise.song()
    local current_instrument_index = song.selected_instrument_index
    
    -- Get saved labels for the currently selected instrument (same as breakpoint workflow)
    local labeler = require("labeler")
    local saved_labels = labeler.get_labels_for_instrument(current_instrument_index)
    
    print("DEBUG: Current instrument index: " .. current_instrument_index)
    print("DEBUG: Available saved_labels:")
    for hex_key, label_data in pairs(saved_labels or {}) do
        print("DEBUG:   " .. hex_key .. " -> " .. (label_data.label or ""))
    end
    
    if not saved_labels or next(saved_labels) == nil then
        print("DEBUG: No saved labels found for current instrument " .. current_instrument_index)
        return {}
    end
    
    local applied_labels = {}
    local labels_applied_count = 0
    
    -- For each note in the captured selection, map note values to slice labels
    for i, note in ipairs(notes) do
        local note_value = note.note_value
        local pattern_instrument_index = note.instrument_value + 1
        
        print("DEBUG: Checking note " .. i .. " from pattern instrument " .. pattern_instrument_index .. " with note_value " .. note_value)
        
        -- Calculate slice index from note value
        -- Based on your specification: slice 1 (hex key 01) = note value 37
        -- So: note 37 = slice 1, note 38 = slice 2, etc.
        local slice_index = 0  -- Default to main sample
        
        if note_value >= 37 then
            slice_index = note_value - 36  -- note 37 = slice 1, note 38 = slice 2, etc.
        end
        
        print("DEBUG: Note mapping - note_value " .. note_value .. " -> slice_index " .. slice_index)
        
        -- Convert to hex key format (same as labeler system)
        local hex_key = string.format("%02X", slice_index + 1)  -- +1 because labeler uses 1-based indexing
        
        print("DEBUG: Note value " .. note_value .. " maps to slice " .. slice_index .. " (hex_key: " .. hex_key .. ")")
        
        -- Check if we have a saved label for this slice in the current instrument
        if saved_labels[hex_key] then
            applied_labels[hex_key] = {
                label = saved_labels[hex_key].label or "",
                breakpoint = saved_labels[hex_key].breakpoint or false,
                instrument_index = current_instrument_index  -- Use current instrument, not pattern instrument
            }
            labels_applied_count = labels_applied_count + 1
            print("DEBUG: Applied label '" .. (saved_labels[hex_key].label or "") .. "' from current instrument " .. current_instrument_index .. " slice " .. slice_index)
        else
            print("DEBUG: No label found for slice " .. slice_index .. " (hex_key: " .. hex_key .. ") in current instrument " .. current_instrument_index)
        end
    end
    
    print("DEBUG: Applied " .. labels_applied_count .. " labels to range symbol")
    return applied_labels
end

-- Create symbol data structure for range-captured notes
function selection.create_symbol_data(notes, selection_data)
    local song = renoise.song()
    local current_pattern_index = song.selected_pattern_index
    
    -- Calculate total duration
    local total_duration = 0
    if #notes > 0 then
        local last_note = notes[#notes]
        total_duration = (last_note.line - 1) * 256 + last_note.delay_value + last_note.distance_to_next
    end
    
    local symbol_data = {
        type = "range_captured",
        pattern_index = current_pattern_index,
        track_index = selection_data.start_track,
        capture_metadata = {
            start_line = selection_data.start_line,
            end_line = selection_data.end_line,
            pattern_length = song.selected_pattern.number_of_lines,
            capture_timestamp = os.date("%Y-%m-%d %H:%M:%S")
        },
        notes = notes,
        total_duration = total_duration
    }
    
    print("DEBUG: Created symbol data with " .. #notes .. " notes, total duration: " .. total_duration)
    return symbol_data
end

-- Convert range symbol to break_set format for compatibility with placement system
function selection.convert_to_break_set(symbol_data)
    local break_set = {
        timing = {},
        notes = {},
        start_line = 1,
        end_line = 64 -- Will be adjusted based on actual content
    }
    
    -- Convert content to timing format (similar to breakpoints)
    for i, content in ipairs(symbol_data.notes) do
        -- Validate and clamp note value to valid Renoise range (0-121)
        local valid_note_value = content.note_value
        if valid_note_value < 0 or valid_note_value > 121 then
            print("WARNING: Invalid note value " .. valid_note_value .. " clamped to valid range")
            valid_note_value = math.max(0, math.min(121, valid_note_value))
        end
        
        -- Validate instrument value (0-254, 255 is empty)
        local valid_instrument_value = content.instrument_value
        if valid_instrument_value < 0 or valid_instrument_value > 254 then
            print("WARNING: Invalid instrument value " .. valid_instrument_value .. " clamped to valid range")
            valid_instrument_value = math.max(0, math.min(254, valid_instrument_value))
        end
        
        -- Calculate source_instrument_index from the actual instrument_value in the pattern
        -- Convert from 0-based instrument_value to 1-based instrument index
        local source_instrument_index = valid_instrument_value + 1
        
        -- Create timing entry
        local timing_entry = {
            instrument_value = valid_instrument_value,
            relative_line = content.line,
            new_delay = content.delay_value,
            original_distance = content.distance_to_next,
            source_instrument_index = source_instrument_index,
            note_value = valid_note_value,
            volume_value = content.volume_value,
            panning_value = content.panning_value,
            effect_number_value = content.effect_number_value,
            effect_amount_value = content.effect_amount_value,
            effect_columns = content.effect_columns or {},
            note_columns = content.note_columns or {},
            -- NEW: Enhanced content information
            has_note = content.has_note,
            content_type = content.content_type
        }
        table.insert(break_set.timing, timing_entry)
        
        -- Create note entry for compatibility
        local note_entry = {
            line = content.line,
            note_value = valid_note_value,
            instrument_value = valid_instrument_value,
            delay_value = content.delay_value,
            volume_value = content.volume_value,
            panning_value = content.panning_value,
            effect_number_value = content.effect_number_value,
            effect_amount_value = content.effect_amount_value,
            effect_columns = content.effect_columns or {},
            note_columns = content.note_columns or {},
            distance = content.distance_to_next,
            is_last = (i == #symbol_data.notes),
            -- NEW: Enhanced content information
            has_note = content.has_note,
            content_type = content.content_type
        }
        table.insert(break_set.notes, note_entry)
    end
    
    -- Adjust end_line based on actual content
    if #break_set.notes > 0 then
        local last_note = break_set.notes[#break_set.notes]
        local distance_in_lines = math.floor(last_note.distance / 256)
        break_set.end_line = last_note.line + distance_in_lines + 4 -- Add buffer
    end
    
    return break_set
end

-- Capture current selection as a new symbol
function selection.capture_selection_as_symbol()
    print("DEBUG: selection.capture_selection_as_symbol() called")
    
    -- Validate we have the required functions
    if not get_global_symbol_registry or not find_next_available_symbols or not save_global_symbol_registry then
        renoise.app():show_warning("Symbol registry functions not available. Please ensure the tool is properly initialized.")
        return false
    end
    
    -- Extract notes from selection
    local notes, selection_data = selection.extract_notes_from_selection()
    if not notes then
        renoise.app():show_warning(selection_data) -- selection_data contains error message
        return false
    end
    
    -- Create symbol data
    local symbol_data = selection.create_symbol_data(notes, selection_data)
    
    -- Find next available symbol
    local available_symbols = find_next_available_symbols(1)
    if #available_symbols == 0 then
        renoise.app():show_warning("No available symbols left. Please clear some symbols first.")
        return false
    end
    
    local new_symbol = available_symbols[1]
    
    -- Convert to break_set format for compatibility
    local break_set = selection.convert_to_break_set(symbol_data)
    
    -- NEW: Apply labels from current instrument's BreakFast labeler data
    local applied_labels = selection.apply_labels_to_range_symbol(symbol_data, notes)
    
    -- Store in global registry
    local global_registry = get_global_symbol_registry()
    global_registry[new_symbol] = {
        symbol_type = "range_captured", -- NEW: Distinguish from breakpoint symbols
        break_set = break_set,
        saved_labels = applied_labels, -- NEW: Apply mapped labels instead of empty table
        source_metadata = { -- NEW: Additional metadata for range symbols
            pattern_index = symbol_data.pattern_index,
            track_index = symbol_data.track_index,
            capture_info = symbol_data.capture_metadata
        }
    }
    
    -- Save to preferences
    save_global_symbol_registry()
    
    local labels_count = 0
    for _ in pairs(applied_labels) do
        labels_count = labels_count + 1
    end
    
    local note_count = 0
    for _, content in ipairs(notes) do
        if content.has_note then
            note_count = note_count + 1
        end
    end
    
    local message = string.format("Captured selection as symbol %s (%d content lines, %d notes from pattern %d, track %d, %d labels applied)", 
        new_symbol, #notes, note_count, symbol_data.pattern_index, symbol_data.track_index, labels_count)
    renoise.app():show_status(message)
    print("DEBUG: " .. message)
    
    return true, new_symbol
end

-- Get all range-captured symbols from registry
function selection.get_range_captured_symbols()
    if not get_global_symbol_registry then
        return {}
    end
    
    local global_registry = get_global_symbol_registry()
    local range_symbols = {}
    
    for symbol, symbol_data in pairs(global_registry) do
        if symbol_data.symbol_type == "range_captured" then
            range_symbols[symbol] = symbol_data
        end
    end
    
    return range_symbols
end

-- Clear all range-captured symbols
function selection.clear_range_captured_symbols()
    if not get_global_symbol_registry or not save_global_symbol_registry then
        return false
    end
    
    local global_registry = get_global_symbol_registry()
    local cleared_count = 0
    
    -- Remove only range-captured symbols
    for symbol, symbol_data in pairs(global_registry) do
        if symbol_data.symbol_type == "range_captured" then
            global_registry[symbol] = nil
            cleared_count = cleared_count + 1
        end
    end
    
    if cleared_count > 0 then
        save_global_symbol_registry()
        renoise.app():show_status(string.format("Cleared %d range-captured symbols", cleared_count))
    else
        renoise.app():show_status("No range-captured symbols to clear")
    end
    
    return true, cleared_count
end

-- Format range symbol for display (similar to syntax.lua formatting)
function selection.format_range_symbol_labels(symbol_data)
    local labels = {}
    
    if symbol_data.break_set and symbol_data.break_set.timing then
        for _, timing in ipairs(symbol_data.break_set.timing) do
            local line_str = string.format("%02d", timing.relative_line)
            local note_str = selection.note_value_to_string(timing.note_value)
            local delay_str = string.format("d%02X", timing.new_delay)
            -- Use source_instrument_index - 1 to show the 0-based instrument number as it appears in the pattern
            local inst_str = string.format("I%02X", (timing.source_instrument_index or 1) - 1)
            
            -- Get label from saved_labels if available, otherwise use note value
            local label_str = ""
            if symbol_data.saved_labels then
                -- For range symbols, calculate the slice index from note value (same logic as apply_labels_to_range_symbol)
                local note_value = timing.note_value
                local slice_index = 0
                if note_value >= 37 then
                    slice_index = note_value - 36
                end
                local hex_key = string.format("%02X", slice_index + 1)
                
                local label_data = symbol_data.saved_labels[hex_key]
                if label_data and label_data.label and label_data.label ~= "" then
                    -- Pad label to consistent width for display
                    label_str = string.format("%-5s", label_data.label:sub(1, 5))
                else
                    -- Use note value instead of underscores when no label exists
                    label_str = string.format("%-5s", note_str:sub(1, 5))
                end
            else
                -- Use note value when no saved_labels available
                label_str = string.format("%-5s", note_str:sub(1, 5))
            end
            
            -- Add source info for range symbols
            local source_pattern = symbol_data.source_metadata and symbol_data.source_metadata.pattern_index or "??"
            local source_track = symbol_data.source_metadata and symbol_data.source_metadata.track_index or "??"
            local source_str = string.format("P%02X:T%02X", source_pattern - 1, source_track - 1)
            
            local formatted_label = string.format("%s-%s-%s-%s-%s", line_str, label_str, delay_str, inst_str, source_str)
            table.insert(labels, formatted_label)
        end
    end
    
    return labels
end

-- Utility function to convert note value to string
function selection.note_value_to_string(note_value)
    if note_value == 120 then return "OFF"
    elseif note_value == 121 then return "---"
    else
        local octave = math.floor(note_value / 12) - 2
        local note_names = {"C-", "C#", "D-", "D#", "E-", "F-", "F#", "G-", "G#", "A-", "A#", "B-"}
        local note_index = (note_value % 12) + 1
        return string.format("%s%d", note_names[note_index], octave)
    end
end

-- Place a range-captured symbol using dedicated placement logic
function selection.place_range_symbol(symbol_name, editor_module)
    print("DEBUG: selection.place_range_symbol() called with symbol: " .. tostring(symbol_name))
    
    if not get_global_symbol_registry then
        renoise.app():show_warning("Symbol registry not available")
        return false
    end
    
    local global_registry = get_global_symbol_registry()
    local symbol_data = global_registry[symbol_name]
    
    if not symbol_data then
        renoise.app():show_warning("Symbol " .. symbol_name .. " not found")
        return false
    end
    
    if symbol_data.symbol_type ~= "range_captured" then
        -- Delegate to regular symbol placement for breakpoint symbols
        return editor_module.place_symbol(symbol_name)
    end
    
    print("DEBUG: Placing range-captured symbol", symbol_name)
    
    -- Use the existing editor placement system but with range symbol data
    -- The break_set format ensures compatibility with existing placement logic
    return editor_module.place_symbol(symbol_name)
end

return selection