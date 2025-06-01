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
    
    -- Extract all notes within the selection range
    for line_idx = selection_data.start_line, selection_data.end_line do
        local line = track:line(line_idx)
        local note_column = line:note_column(1) -- Focus on first note column for now
        
        if note_column.note_value ~= renoise.PatternLine.EMPTY_NOTE then
            has_notes = true
            
            -- Calculate relative line position (1-based from selection start)
            local relative_line = line_idx - selection_start_line + 1
            
            -- Validate note values before storing
            local note_value = note_column.note_value
            local instrument_value = note_column.instrument_value
            
            -- Log the raw values for debugging
            print("DEBUG: Raw note values - note:" .. note_value .. ", inst:" .. instrument_value)
            
            -- Ensure note value is in valid range (0-121)
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
                    effect_number = note_column.effect_number_value,
                    effect_amount = note_column.effect_amount_value,
                    distance_to_next = 0 -- Will be calculated in next step
                }
                
                table.insert(notes, note_data)
                print("DEBUG: Extracted note at line " .. line_idx .. " (relative " .. relative_line .. "): " .. 
                      "note=" .. note_data.note_value .. ", inst=" .. note_data.instrument_value .. ", delay=" .. note_data.delay_value)
            else
                print("WARNING: Invalid note value " .. note_value .. " at line " .. line_idx .. ", skipping")
            end
        end
    end
    
    if not has_notes then
        return nil, "No valid notes found in selection. Please select a range that contains valid notes."
    end
    
    -- Calculate distances between notes and trailing space
    selection.calculate_note_distances(notes, selection_data, pattern)
    
    return notes, selection_data
end

-- Calculate timing distances between notes (similar to breakpoints logic)
function selection.calculate_note_distances(notes, selection_data, pattern)
    print("DEBUG: Calculating note distances for " .. #notes .. " notes")
    
    local song = renoise.song()
    local track = pattern:track(selection_data.start_track)
    
    for i = 1, #notes do
        local current_note = notes[i]
        local current_delay = current_note.delay_value
        local found_next = false
        
        -- Look for next note within our extracted notes
        for j = i + 1, #notes do
            local next_note = notes[j]
            local lines_to_next = next_note.line - current_note.line
            local next_delay = next_note.delay_value
            current_note.distance_to_next = (lines_to_next * 256) - current_delay + next_delay
            found_next = true
            print("DEBUG: Note " .. i .. " distance to next: " .. current_note.distance_to_next)
            break
        end
        
        -- If no next note found within selection, look for the next note in the entire pattern
        if not found_next then
            local current_absolute_line = current_note.absolute_line
            print("DEBUG: Looking for next note after absolute line " .. current_absolute_line .. " in full pattern")
            
            -- Search for the next note beyond the selection in the entire pattern
            for line_idx = selection_data.end_line + 1, pattern.number_of_lines do
                local line = track:line(line_idx)
                local note_column = line:note_column(1)
                
                if note_column.note_value ~= renoise.PatternLine.EMPTY_NOTE then
                    -- Found the next note beyond the selection
                    local lines_to_next = line_idx - current_absolute_line
                    local next_delay = note_column.delay_value
                    current_note.distance_to_next = (lines_to_next * 256) - current_delay + next_delay
                    found_next = true
                    print("DEBUG: Last note " .. i .. " distance to next note at line " .. line_idx .. ": " .. current_note.distance_to_next)
                    break
                end
            end
            
            -- If still no next note found, calculate distance to end of pattern
            if not found_next then
                local lines_to_end = (pattern.number_of_lines + 1) - current_absolute_line
                current_note.distance_to_next = (lines_to_end * 256) - current_delay
                print("DEBUG: Last note " .. i .. " distance to end of pattern: " .. current_note.distance_to_next)
            end
        end
    end
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
    
    -- Convert notes to timing format (similar to breakpoints)
    for i, note in ipairs(symbol_data.notes) do
        -- Validate and clamp note value to valid Renoise range (0-121)
        local valid_note_value = note.note_value
        if valid_note_value < 0 or valid_note_value > 121 then
            print("WARNING: Invalid note value " .. valid_note_value .. " clamped to valid range")
            valid_note_value = math.max(0, math.min(121, valid_note_value))
        end
        
        -- Validate instrument value (0-254, 255 is empty)
        local valid_instrument_value = note.instrument_value
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
            relative_line = note.line,
            new_delay = note.delay_value,
            original_distance = note.distance_to_next,
            source_instrument_index = source_instrument_index,
            note_value = valid_note_value,
            volume_value = note.volume_value,
            panning_value = note.panning_value,
            effect_number = note.effect_number,
            effect_amount = note.effect_amount
        }
        table.insert(break_set.timing, timing_entry)
        
        -- Create note entry for compatibility
        local note_entry = {
            line = note.line,
            note_value = valid_note_value,
            instrument_value = valid_instrument_value,
            delay_value = note.delay_value,
            distance = note.distance_to_next,
            is_last = (i == #symbol_data.notes)
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
    
    -- Store in global registry
    local global_registry = get_global_symbol_registry()
    global_registry[new_symbol] = {
        symbol_type = "range_captured", -- NEW: Distinguish from breakpoint symbols
        break_set = break_set,
        saved_labels = {}, -- Empty for range-captured symbols
        source_metadata = { -- NEW: Additional metadata for range symbols
            pattern_index = symbol_data.pattern_index,
            track_index = symbol_data.track_index,
            capture_info = symbol_data.capture_metadata
        }
    }
    
    -- Save to preferences
    save_global_symbol_registry()
    
    local message = string.format("Captured selection as symbol %s (%d notes from pattern %d, track %d)", 
        new_symbol, #notes, symbol_data.pattern_index, symbol_data.track_index)
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
            
            -- Add source info for range symbols
            local source_pattern = symbol_data.source_metadata and symbol_data.source_metadata.pattern_index or "??"
            local source_track = symbol_data.source_metadata and symbol_data.source_metadata.track_index or "??"
            local source_str = string.format("P%02X:T%02X", source_pattern - 1, source_track - 1)
            
            local formatted_label = string.format("%s-%s-%s-%s-%s", line_str, note_str, delay_str, inst_str, source_str)
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