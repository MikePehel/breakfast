-- selection.lua - Range Selection Capture Module for BreakFast
-- Phase 5: Multi-Track Support
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
-- Phase 5: Now accepts multi-track selections
function selection.validate_selection()
    if not renoise.song() then
        return false, "Song not available"
    end
    
    local song = renoise.song()
    local sel = song.selection_in_pattern
    
    if not sel then
        return false, "No selection found. Please select a range in the pattern editor first."
    end
    
    -- Ensure we have valid selection bounds
    if not sel.start_line or not sel.end_line or 
       not sel.start_track or not sel.end_track then
        return false, "Invalid selection. Please ensure you have selected a complete range."
    end
    
    -- Phase 5: Multi-track selections are now supported
    -- Validate that selected tracks are sequencer tracks (not send/master)
    local sequencer_track_count = song.sequencer_track_count
    if sel.start_track > sequencer_track_count then
        return false, "Selection starts on a non-sequencer track (send/master). Please select sequencer tracks only."
    end
    
    -- Clamp end_track to sequencer tracks if it extends into send/master
    local effective_end_track = math.min(sel.end_track, sequencer_track_count)
    
    -- Create enhanced selection data with track info
    local enhanced_selection = {
        start_line = sel.start_line,
        end_line = sel.end_line,
        start_track = sel.start_track,
        end_track = effective_end_track,
        -- Phase 5: New multi-track metadata
        track_count = effective_end_track - sel.start_track + 1,
        first_track_index = sel.start_track,
        is_multi_track = (effective_end_track > sel.start_track)
    }
    
    return true, enhanced_selection
end

-- Phase 5: Get track names for the selection range
function selection.get_track_names(start_track, end_track)
    local song = renoise.song()
    local track_names = {}
    
    for track_idx = start_track, end_track do
        local track = song:track(track_idx)
        if track then
            table.insert(track_names, track.name or string.format("Track %02d", track_idx))
        end
    end
    
    return track_names
end

-- Extract note data from the current selection
-- Phase 5: Now extracts from all tracks in selection
function selection.extract_notes_from_selection()
    local success, selection_data = selection.validate_selection()
    if not success then
        return nil, selection_data -- selection_data contains error message
    end
    
    local song = renoise.song()
    local pattern = song.selected_pattern
    
    local notes = {}
    local selection_start_line = selection_data.start_line
    local has_notes = false
    local first_track = selection_data.start_track
    
    print("DEBUG: Extracting notes from selection - lines " .. selection_data.start_line .. " to " .. selection_data.end_line)
    print("DEBUG: Multi-track extraction - tracks " .. selection_data.start_track .. " to " .. selection_data.end_track .. " (" .. selection_data.track_count .. " tracks)")
    
    -- Phase 5: Iterate across all tracks in the selection
    for track_idx = selection_data.start_track, selection_data.end_track do
        local track = pattern:track(track_idx)
        local track_offset = track_idx - first_track  -- 0 for first track, 1 for second, etc.
        
        print("DEBUG: Processing track " .. track_idx .. " (offset: " .. track_offset .. ")")
        
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
                print("DEBUG: Raw content - track:" .. track_idx .. ", line:" .. line_idx .. ", type:" .. content_type .. ", note:" .. note_value .. ", inst:" .. instrument_value)
                
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
                        -- Enhanced content information
                        has_note = (note_value ~= renoise.PatternLine.EMPTY_NOTE),
                        content_type = content_type,
                        -- Phase 5: Multi-track information
                        track_index = track_idx,           -- Absolute track index
                        track_offset = track_offset        -- Offset from first track (0, 1, 2, etc.)
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
                    print("DEBUG: Extracted note at track " .. track_idx .. ", line " .. line_idx .. " (relative " .. relative_line .. "): " .. 
                          "note=" .. note_data.note_value .. ", inst=" .. note_data.instrument_value .. ", delay=" .. note_data.delay_value .. ", track_offset=" .. track_offset)
                else
                    print("WARNING: Invalid note value " .. note_value .. " at track " .. track_idx .. ", line " .. line_idx .. ", skipping")
                end
            end
        end
    end
    
    if not has_notes then
        return nil, "No valid content found in selection. Please select a range that contains notes, effects, volume, panning, or delay data."
    end
    
    -- Calculate distances between notes and trailing space
    -- Phase 5: Pass track-aware selection data
    selection.calculate_note_distances(notes, selection_data, pattern)
    
    return notes, selection_data
end

-- Calculate timing distances between content lines (notes, effects, etc.)
-- Phase 5: Updated to handle multi-track note distances with distance mode support
function selection.calculate_note_distances(notes, selection_data, pattern)
    print("DEBUG: Calculating content distances for " .. #notes .. " content lines")
    
    local song = renoise.song()
    
    -- Phase 5: Group notes by track for proper distance calculation
    local notes_by_track = {}
    for _, note in ipairs(notes) do
        local track_idx = note.track_index or selection_data.start_track
        if not notes_by_track[track_idx] then
            notes_by_track[track_idx] = {}
        end
        table.insert(notes_by_track[track_idx], note)
    end
    
    -- Phase 5: For multi-track symbols, first find next notes on ALL tracks to determine cutoff
    local next_note_lines = {}  -- track_idx -> {line = line_number, delay = delay_value} or nil
    local last_notes_by_track = {}  -- track_idx -> last note in that track
    
    if selection_data.is_multi_track and selection_data.track_count > 1 then
        -- Find the next note AFTER selection on each track
        for track_idx = selection_data.start_track, selection_data.end_track do
            local track = pattern:track(track_idx)
            
            -- Search for next content beyond the selection
            for line_idx = selection_data.end_line + 1, pattern.number_of_lines do
                local line = track:line(line_idx)
                local line_has_content = false
                local line_delay = 0
                
                -- Check note columns for content
                for col = 1, 12 do
                    local nc = line:note_column(col)
                    if nc.note_value ~= renoise.PatternLine.EMPTY_NOTE or
                       nc.volume_value ~= renoise.PatternLine.EMPTY_VOLUME or
                       nc.panning_value ~= renoise.PatternLine.EMPTY_PANNING or
                       nc.delay_value ~= renoise.PatternLine.EMPTY_DELAY or
                       nc.effect_number_value ~= renoise.PatternLine.EMPTY_EFFECT_NUMBER then
                        line_has_content = true
                        line_delay = nc.delay_value or 0
                        break
                    end
                end
                
                -- Check effect columns if no note content found
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
                    next_note_lines[track_idx] = { line = line_idx, delay = line_delay }
                    print("DEBUG: Track " .. track_idx .. " next note found at line " .. line_idx)
                    break
                end
            end
            
            if not next_note_lines[track_idx] then
                -- No next note found, use end of pattern + 1
                next_note_lines[track_idx] = { line = pattern.number_of_lines + 1, delay = 0 }
                print("DEBUG: Track " .. track_idx .. " no next note, using pattern end + 1")
            end
        end
        
        -- Determine unified cutoff based on distance mode
        local unified_cutoff = selection.get_unified_cutoff(next_note_lines, selection_data)
        if unified_cutoff then
            print("DEBUG: Unified cutoff line: " .. unified_cutoff.line .. " (from track " .. unified_cutoff.source_track .. ")")
        end
        
        -- Store unified cutoff for use in distance calculation
        selection_data.unified_cutoff = unified_cutoff
    end
    
    -- Calculate distances within each track
    for track_idx, track_notes in pairs(notes_by_track) do
        local track = pattern:track(track_idx)
        
        for i = 1, #track_notes do
            local current_content = track_notes[i]
            local current_delay = current_content.delay_value
            local found_next = false
            
            -- Look for next content within our extracted notes for this track
            for j = i + 1, #track_notes do
                local next_content = track_notes[j]
                local lines_to_next = next_content.line - current_content.line
                local next_delay = next_content.delay_value
                current_content.distance_to_next = (lines_to_next * 256) - current_delay + next_delay
                found_next = true
                print("DEBUG: Track " .. track_idx .. " Content " .. i .. " (" .. current_content.content_type .. ") distance to next: " .. current_content.distance_to_next)
                break
            end
            
            -- If this is the last note in this track
            if not found_next then
                last_notes_by_track[track_idx] = current_content
                local current_absolute_line = current_content.absolute_line
                
                -- Phase 5: For multi-track with unified cutoff, use that
                if selection_data.unified_cutoff and selection_data.is_multi_track then
                    local cutoff = selection_data.unified_cutoff
                    local lines_to_cutoff = cutoff.line - current_absolute_line
                    current_content.distance_to_next = (lines_to_cutoff * 256) - current_delay + cutoff.delay
                    print("DEBUG: Track " .. track_idx .. " Last content using unified cutoff at line " .. cutoff.line .. ", distance: " .. current_content.distance_to_next)
                else
                    -- Single track or Independent mode: use original per-track logic
                    print("DEBUG: Track " .. track_idx .. " Looking for next content after absolute line " .. current_absolute_line .. " in full pattern")
                    
                    -- Search for the next content beyond the selection in the entire pattern
                    for line_idx = selection_data.end_line + 1, pattern.number_of_lines do
                        local line = track:line(line_idx)
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
                            local lines_to_next = line_idx - current_absolute_line
                            local next_delay = line:note_column(1).delay_value
                            current_content.distance_to_next = (lines_to_next * 256) - current_delay + next_delay
                            found_next = true
                            print("DEBUG: Track " .. track_idx .. " Last content " .. i .. " distance to next content at line " .. line_idx .. ": " .. current_content.distance_to_next)
                            break
                        end
                    end
                    
                    -- If still no next content found, calculate distance to end of pattern
                    if not found_next then
                        local lines_to_end = (pattern.number_of_lines + 1) - current_absolute_line
                        current_content.distance_to_next = (lines_to_end * 256) - current_delay
                        print("DEBUG: Track " .. track_idx .. " Last content " .. i .. " distance to end of pattern: " .. current_content.distance_to_next)
                    end
                end
            end
        end
    end
end

-- Phase 5: Determine unified cutoff point based on multi-track distance mode
function selection.get_unified_cutoff(next_note_lines, selection_data)
    -- Get the distance mode from main module
    local get_mode = _G.get_multi_track_distance_mode
    local get_constants = _G.get_multi_track_distance_mode_constants
    
    if not get_mode or not get_constants then
        print("DEBUG: Multi-track distance mode functions not available, using independent mode")
        return nil
    end
    
    local mode = get_mode()
    local constants = get_constants()
    
    if mode == constants.INDEPENDENT then
        -- Independent mode - no unified cutoff
        print("DEBUG: Multi-track distance mode: Independent - no unified cutoff")
        return nil
    end
    
    -- Find earliest and latest next notes across all tracks
    local earliest_line = nil
    local earliest_track = nil
    local earliest_delay = 0
    local latest_line = nil
    local latest_track = nil
    local latest_delay = 0
    
    for track_idx, next_info in pairs(next_note_lines) do
        local line = next_info.line
        local delay = next_info.delay or 0
        
        -- Compare using tick position (line * 256 + delay)
        local tick_pos = line * 256 + delay
        
        if not earliest_line or tick_pos < (earliest_line * 256 + earliest_delay) then
            earliest_line = line
            earliest_track = track_idx
            earliest_delay = delay
        end
        
        if not latest_line or tick_pos > (latest_line * 256 + latest_delay) then
            latest_line = line
            latest_track = track_idx
            latest_delay = delay
        end
    end
    
    if mode == constants.SYNC_FIRST then
        -- Sync to First: use earliest (shortest distance to next note)
        print("DEBUG: Multi-track distance mode: Sync to First - cutoff at line " .. earliest_line .. " (track " .. earliest_track .. ")")
        return {
            line = earliest_line,
            delay = earliest_delay,
            source_track = earliest_track
        }
    elseif mode == constants.SYNC_LAST then
        -- Sync to Last: use latest (longest distance)
        print("DEBUG: Multi-track distance mode: Sync to Last - cutoff at line " .. latest_line .. " (track " .. latest_track .. ")")
        return {
            line = latest_line,
            delay = latest_delay,
            source_track = latest_track
        }
    end
    
    return nil
end

-- Apply labels from BreakFast labeler data to a range symbol
-- Now supports multi-instrument lookups and both legacy slice-based and new note-based formats
function selection.apply_labels_to_range_symbol(symbol_data, notes)
    print("DEBUG: Applying labels to range symbol")
    
    if not renoise.song() then
        print("DEBUG: No song available for label mapping")
        return {}
    end
    
    local labeler = require("labeler")
    local applied_labels = {}
    local labels_applied_count = 0
    
    -- For each note in the captured selection, look up labels from the note's instrument
    for i, note in ipairs(notes) do
        if not note.has_note then
            goto continue
        end
        
        local note_value = note.note_value
        local instrument_index = note.instrument_value + 1  -- Convert to 1-based
        
        print("DEBUG: Checking note " .. i .. " from instrument " .. instrument_index .. " with note_value " .. note_value)
        
        -- Get saved labels for THIS note's instrument (not just the selected instrument)
        local saved_labels = labeler.get_labels_for_instrument(instrument_index)
        
        if not saved_labels or next(saved_labels) == nil then
            print("DEBUG: No saved labels for instrument " .. instrument_index)
            goto continue
        end
        
        -- Try slice-based key first (most common for sliced samples)
        -- Slice 1 = note 37, key "01"; Slice 2 = note 38, key "02"
        local slice_key = nil
        if note_value >= 37 then
            slice_key = string.format("%02X", note_value - 36)
        end
        
        -- Also try note-based key (for keyzone mappings)
        local note_key = string.format("%02X", note_value)
        
        local label_data = (slice_key and saved_labels[slice_key]) or saved_labels[note_key] or nil
        
        if label_data then
            -- Use the key that was found for storage
            local storage_key = (slice_key and saved_labels[slice_key]) and slice_key or note_key
            
            applied_labels[storage_key] = {
                label = label_data.label or "---------",
                label2 = label_data.label2 or "---------",
                breakpoint = label_data.breakpoint or false,
                instrument_index = instrument_index,
                note_value = note_value
            }
            labels_applied_count = labels_applied_count + 1
            print("DEBUG: Applied label '" .. (label_data.label or "") .. "' from instrument " .. instrument_index .. " note " .. note_value .. " (key: " .. storage_key .. ")")
        else
            print("DEBUG: No label found for note " .. note_value .. " (slice_key: " .. (slice_key or "N/A") .. ", note_key: " .. note_key .. ") in instrument " .. instrument_index)
        end
        
        ::continue::
    end
    
    print("DEBUG: Applied " .. labels_applied_count .. " labels to range symbol")
    return applied_labels
end

-- Create symbol data structure for range-captured notes
-- Phase 5: Now includes multi-track metadata
function selection.create_symbol_data(notes, selection_data)
    local song = renoise.song()
    local current_pattern_index = song.selected_pattern_index
    
    -- Calculate total duration
    local total_duration = 0
    if #notes > 0 then
        local last_note = notes[#notes]
        total_duration = (last_note.line - 1) * 256 + last_note.delay_value + last_note.distance_to_next
    end
    
    -- Phase 5: Get track names for the selection
    local track_names = selection.get_track_names(selection_data.start_track, selection_data.end_track)
    
    local symbol_data = {
        type = "range_captured",
        pattern_index = current_pattern_index,
        track_index = selection_data.start_track,  -- Keep for backward compatibility
        capture_metadata = {
            start_line = selection_data.start_line,
            end_line = selection_data.end_line,
            pattern_length = song.selected_pattern.number_of_lines,
            capture_timestamp = os.date("%Y-%m-%d %H:%M:%S")
        },
        notes = notes,
        total_duration = total_duration,
        -- Phase 5: Multi-track metadata
        track_count = selection_data.track_count,
        first_track_index = selection_data.first_track_index,
        track_names = track_names,
        is_multi_track = selection_data.is_multi_track
    }
    
    print("DEBUG: Created symbol data with " .. #notes .. " notes across " .. selection_data.track_count .. " tracks, total duration: " .. total_duration)
    if selection_data.is_multi_track then
        print("DEBUG: Multi-track symbol - tracks: " .. table.concat(track_names, ", "))
    end
    return symbol_data
end

-- Convert range symbol to break_set format for compatibility with placement system
-- Phase 5: Now includes track information in timing entries
-- FIXED: Now normalizes delays like breakpoints.lua - first note gets delay 0, others adjusted relative
function selection.convert_to_break_set(symbol_data)
    local break_set = {
        timing = {},
        notes = {},
        start_line = 1,
        end_line = 64, -- Will be adjusted based on actual content
        -- Phase 5: Multi-track metadata in break_set
        track_count = symbol_data.track_count or 1,
        first_track_index = symbol_data.first_track_index or 1,
        track_names = symbol_data.track_names or {},
        is_multi_track = symbol_data.is_multi_track or false
    }
    
    -- Get delay adjustment from first note (to normalize so first note has delay 0)
    -- This matches how breakpoints.lua handles timing normalization
    local delay_adjustment = 0
    local base_line = 1
    if #symbol_data.notes > 0 then
        delay_adjustment = symbol_data.notes[1].delay_value or 0
        base_line = symbol_data.notes[1].line or 1
    end
    
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
        
        -- Calculate normalized delay and relative line (like breakpoints.lua)
        local normalized_delay
        local relative_line = content.line
        local adjusted_distance = content.distance_to_next
        
        if i == 1 then
            -- First note: delay becomes 0, distance increases by delay_adjustment
            normalized_delay = 0
            adjusted_distance = content.distance_to_next + delay_adjustment
        else
            -- Subsequent notes: subtract delay_adjustment from delay
            normalized_delay = content.delay_value - delay_adjustment
            
            -- Handle negative delay by moving to previous line
            if normalized_delay < 0 then
                relative_line = relative_line - 1
                normalized_delay = 256 + normalized_delay
            end
        end
        
        -- Create timing entry with normalized delay
        local timing_entry = {
            instrument_value = valid_instrument_value,
            relative_line = relative_line,
            new_delay = normalized_delay,
            original_delay = content.delay_value,  -- Keep original for reference
            original_distance = adjusted_distance,
            source_instrument_index = source_instrument_index,
            note_value = valid_note_value,
            volume_value = content.volume_value,
            panning_value = content.panning_value,
            effect_number_value = content.effect_number_value,
            effect_amount_value = content.effect_amount_value,
            effect_columns = content.effect_columns or {},
            note_columns = content.note_columns or {},
            -- Enhanced content information
            has_note = content.has_note,
            content_type = content.content_type,
            -- Phase 5: Multi-track information
            track_index = content.track_index,
            track_offset = content.track_offset or 0
        }
        table.insert(break_set.timing, timing_entry)
        
        -- Create note entry for compatibility (keeps original delay_value for display purposes)
        local note_entry = {
            line = content.line,
            note_value = valid_note_value,
            instrument_value = valid_instrument_value,
            delay_value = content.delay_value,  -- Keep original for display
            volume_value = content.volume_value,
            panning_value = content.panning_value,
            effect_number_value = content.effect_number_value,
            effect_amount_value = content.effect_amount_value,
            effect_columns = content.effect_columns or {},
            note_columns = content.note_columns or {},
            distance = content.distance_to_next,
            is_last = (i == #symbol_data.notes),
            -- Enhanced content information
            has_note = content.has_note,
            content_type = content.content_type,
            -- Phase 5: Multi-track information
            track_index = content.track_index,
            track_offset = content.track_offset or 0
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
-- Phase 5: Now supports multi-track capture
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
    
    -- Apply labels from current instrument's BreakFast labeler data
    local applied_labels = selection.apply_labels_to_range_symbol(symbol_data, notes)
    
    -- Store in global registry
    local global_registry = get_global_symbol_registry()
    global_registry[new_symbol] = {
        symbol_type = "range_captured", -- Distinguish from breakpoint symbols
        break_set = break_set,
        saved_labels = applied_labels, -- Apply mapped labels instead of empty table
        source_metadata = { -- Additional metadata for range symbols
            pattern_index = symbol_data.pattern_index,
            track_index = symbol_data.track_index,  -- Keep for backward compatibility
            capture_info = symbol_data.capture_metadata,
            -- Phase 5: Multi-track metadata
            track_count = symbol_data.track_count,
            first_track_index = symbol_data.first_track_index,
            track_names = symbol_data.track_names,
            is_multi_track = symbol_data.is_multi_track
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
    
    -- Phase 5: Enhanced status message for multi-track
    local message
    if symbol_data.is_multi_track then
        message = string.format("Captured selection as symbol %s (%d content lines, %d notes from pattern %d, %d tracks [%s], %d labels applied)", 
            new_symbol, #notes, note_count, symbol_data.pattern_index, symbol_data.track_count, 
            table.concat(symbol_data.track_names, ", "), labels_count)
    else
        message = string.format("Captured selection as symbol %s (%d content lines, %d notes from pattern %d, track %d, %d labels applied)", 
            new_symbol, #notes, note_count, symbol_data.pattern_index, symbol_data.track_index, labels_count)
    end
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
-- Updated to handle label format with label2
-- Phase 5: Now includes track offset information for multi-track symbols
function selection.format_range_symbol_labels(symbol_data)
    local labels = {}
    
    if symbol_data.break_set and symbol_data.break_set.timing then
        -- Check if this is a multi-track symbol
        local is_multi_track = symbol_data.break_set.is_multi_track or 
                               (symbol_data.source_metadata and symbol_data.source_metadata.is_multi_track) or
                               (symbol_data.break_set.track_count and symbol_data.break_set.track_count > 1)
        
        for _, timing in ipairs(symbol_data.break_set.timing) do
            local line_str = string.format("%02d", timing.relative_line)
            local note_str = selection.note_value_to_string(timing.note_value)
            local delay_str = string.format("d%02X", timing.new_delay)
            -- Use source_instrument_index - 1 to show the 0-based instrument number as it appears in the pattern
            local inst_idx = timing.source_instrument_index or 1
            local inst_str = string.format("I%02X", inst_idx - 1)
            
            -- Get label from saved_labels if available, otherwise use note value
            local label_str = ""
            local label2_str = ""
            
            if symbol_data.saved_labels then
                local note_value = timing.note_value
                
                -- Try slice-based key first (most common)
                -- Slice 1 = note 37, key "01"
                local slice_key = nil
                if note_value >= 37 then
                    slice_key = string.format("%02X", note_value - 36)
                end
                
                -- Also try note-based key
                local note_key = string.format("%02X", note_value)
                
                local label_data = (slice_key and symbol_data.saved_labels[slice_key]) or symbol_data.saved_labels[note_key] or nil
                
                if label_data and label_data.label and label_data.label ~= "" and label_data.label ~= "---------" then
                    -- Pad label to consistent width for display
                    label_str = string.format("%-5s", label_data.label:sub(1, 5))
                    
                    -- Include label2 if present
                    if label_data.label2 and label_data.label2 ~= "" and label_data.label2 ~= "---------" then
                        label2_str = "/" .. label_data.label2:sub(1, 3)
                    end
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
            
            -- Phase 5: Add track offset indicator for multi-track symbols
            local track_str = ""
            if is_multi_track then
                local track_offset = timing.track_offset or 0
                track_str = string.format("+T%d", track_offset)
            end
            
            local formatted_label
            if is_multi_track then
                formatted_label = string.format("%s-%s%s-%s-%s-%s%s", line_str, label_str, label2_str, delay_str, inst_str, source_str, track_str)
            else
                formatted_label = string.format("%s-%s%s-%s-%s-%s", line_str, label_str, label2_str, delay_str, inst_str, source_str)
            end
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
    
    -- Phase 5: Check if this is a multi-track symbol
    local is_multi_track = symbol_data.break_set and symbol_data.break_set.is_multi_track
    if is_multi_track then
        local track_count = symbol_data.break_set.track_count or 1
        print("DEBUG: Multi-track symbol with " .. track_count .. " tracks")
    end
    
    -- Use the existing editor placement system but with range symbol data
    -- The break_set format ensures compatibility with existing placement logic
    -- Phase 5: editor.place_symbol will handle multi-track placement using track_offset
    return editor_module.place_symbol(symbol_name)
end

-- Phase 5: Utility function to get track count for a symbol
function selection.get_symbol_track_count(symbol_name)
    if not get_global_symbol_registry then
        return 1
    end
    
    local global_registry = get_global_symbol_registry()
    local symbol_data = global_registry[symbol_name]
    
    if not symbol_data then
        return 1
    end
    
    -- Check break_set first, then source_metadata
    if symbol_data.break_set and symbol_data.break_set.track_count then
        return symbol_data.break_set.track_count
    elseif symbol_data.source_metadata and symbol_data.source_metadata.track_count then
        return symbol_data.source_metadata.track_count
    end
    
    return 1
end

-- Phase 5: Utility function to check if symbol is multi-track
function selection.is_multi_track_symbol(symbol_name)
    return selection.get_symbol_track_count(symbol_name) > 1
end

return selection