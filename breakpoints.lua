-- breakpoints.lua - Break Pattern Analysis and Generation
local breakpoints = {}

-- Calculate timing distances between notes in a set
local function calculate_set_distances(set, analysis, source_instrument_index)
    local set_timing = {}
    
    if #set.notes > 0 then
        local first_note = set.notes[1]
        local delay_adjustment = first_note.delay_value
        local base_line = first_note.line
        
        -- Set up first note
        set_timing[1] = {
            original_line = first_note.line,
            relative_line = 1,
            original_delay = first_note.delay_value,
            new_delay = 0,
            original_distance = first_note.distance,
            new_distance = first_note.distance + delay_adjustment,
            note_value = first_note.note_value,
            instrument_value = first_note.instrument_value,
            source_instrument_index = source_instrument_index or renoise.song().selected_instrument_index
        }
        
        -- Process subsequent notes
        for i = 2, #set.notes do
            local current_note = set.notes[i]
            local new_line = current_note.line
            local new_delay = current_note.delay_value - delay_adjustment
            
            -- Handle negative delay by moving to previous line
            if new_delay < 0 then
                new_line = new_line - 1
                new_delay = 256 + new_delay
            end
            
            set_timing[i] = {
                original_line = current_note.line,
                relative_line = new_line + 1 - base_line,
                original_delay = current_note.delay_value,
                new_delay = new_delay,
                original_distance = current_note.distance,
                new_distance = current_note.distance + delay_adjustment,
                note_value = current_note.note_value,
                instrument_value = current_note.instrument_value,
                source_instrument_index = source_instrument_index or renoise.song().selected_instrument_index
            }
        end
    end
    
    return set_timing
end

local function get_breakpoint_indices(saved_labels)
    local breakpoint_indices = {}
    
    print("DEBUG: get_breakpoint_indices processing saved_labels:")
    for hex_key, label_data in pairs(saved_labels) do
        print("DEBUG: hex_key:", hex_key, "label:", label_data.label, "breakpoint:", label_data.breakpoint)
        if label_data.breakpoint then
            local index = tonumber(hex_key, 16) - 1
            breakpoint_indices[index] = true
            print("DEBUG: Added breakpoint at index:", index, "from hex_key:", hex_key)
        end
    end
    
    print("DEBUG: Final breakpoint_indices:", (function()
        local str = ""
        for k,v in pairs(breakpoint_indices) do
            str = str .. k .. "=" .. tostring(v) .. " "
        end
        return str
    end)())
    
    return breakpoint_indices
end

local function get_breakpoint_lines(analysis, breakpoint_indices)
    local breakpoint_lines = {}
    print("DEBUG: get_breakpoint_lines checking analysis data")
    
    for i = 1, #analysis do
        if analysis[i].note_value ~= renoise.PatternLine.EMPTY_NOTE then
            local instrument_val = analysis[i].instrument_value
            print("DEBUG: Line", i, "instrument_value:", instrument_val, "has_breakpoint:", breakpoint_indices[instrument_val] or false)
            if breakpoint_indices[instrument_val] then
                table.insert(breakpoint_lines, i)
                print("DEBUG: Added breakpoint line:", i)
            end
        end
    end
    
    table.sort(breakpoint_lines)
    print("DEBUG: Final breakpoint_lines:", table.concat(breakpoint_lines, ","))
    return breakpoint_lines
end

-- Analyze phrase to get note timing information
local function get_line_analysis(phrase)
    local analysis = {}
    local lines = phrase.number_of_lines
    
    -- Capture current instrument index for proper embedding
    local song = renoise.song()
    local current_instrument_index = song.selected_instrument_index
    
    -- First pass: collect all note data
    print("DEBUG: Analyzing phrase with", lines, "lines")
    for i = 1, lines do
        local line = phrase:line(i)
        local note_column = line:note_column(1)
        
        analysis[i] = {
            note_value = note_column.note_value,
            instrument_value = note_column.instrument_value,
            delay_value = note_column.delay_value,
            distance = 0,
            is_last = false
        }
        
        -- DEBUG: Show every line with data
        if note_column.note_value ~= renoise.PatternLine.EMPTY_NOTE then
            print("DEBUG: Line", i, "raw note_value:", note_column.note_value, "instrument_value:", note_column.instrument_value, "delay:", note_column.delay_value)
        end
    end

    -- Detect and handle phrases with disabled sample columns  
    -- If all instrument values are 255 (empty) or 0, interpolate slice values from note values
    local all_instruments_empty = true
    local note_count = 0
    print("DEBUG: Checking", lines, "lines for note data...")

    for i = 1, lines do
        if analysis[i].note_value ~= renoise.PatternLine.EMPTY_NOTE then
            note_count = note_count + 1
            print("DEBUG: Found note at line", i, "note_value:", analysis[i].note_value, "instrument_value:", analysis[i].instrument_value)
            -- Check if instrument value is valid (not 0 and not 255/empty)
            if analysis[i].instrument_value ~= 0 and analysis[i].instrument_value ~= 255 then
                all_instruments_empty = false
                print("DEBUG: Valid instrument found, not interpolating")
                break
            end
        end
    end

    print("DEBUG: Total notes found:", note_count, "all_instruments_empty:", all_instruments_empty)

    -- Interpolate slice values if needed
    -- Interpolate slice values if needed
    if all_instruments_empty and note_count > 0 then
        print("DEBUG: Detected phrase with disabled/empty sample column, interpolating slice values from notes")
        for i = 1, lines do
            if analysis[i].note_value ~= renoise.PatternLine.EMPTY_NOTE then
                -- Convert note value to slice index: C#2 (37) = slice 1, D-2 (38) = slice 2, etc.
                local slice_index = analysis[i].note_value - 37  -- C#2 is note 37, maps to slice 0
                if slice_index >= 0 and slice_index <= 127 then  -- Valid slice range
                    analysis[i].instrument_value = slice_index
                    print("DEBUG: Line", i, "note", analysis[i].note_value, "-> slice", slice_index)
                else
                    print("DEBUG: Line", i, "note", analysis[i].note_value, "outside valid slice range (36-163), got", slice_index)
                    -- Set to slice 0 for safety
                    analysis[i].instrument_value = 0
                end
            end
        end
    else
        print("DEBUG: Not interpolating - all_instruments_empty:", all_instruments_empty, "note_count:", note_count)
    end
    
    -- Second pass: calculate distances and identify last note
    local last_note_index = nil
    
    -- Find the last actual note
    for i = lines, 1, -1 do
        if analysis[i].note_value ~= renoise.PatternLine.EMPTY_NOTE then
            last_note_index = i
            analysis[i].is_last = true
            break
        end
    end
    
    -- Calculate distances
    for i = 1, lines do
        if analysis[i].note_value ~= renoise.PatternLine.EMPTY_NOTE then
            local current_delay = analysis[i].delay_value
            local found_next = false
            
            -- Look for next note
            for j = i + 1, lines do
                if analysis[j].note_value ~= renoise.PatternLine.EMPTY_NOTE then
                    local lines_to_next = j - i
                    local next_delay = analysis[j].delay_value
                    analysis[i].distance = (lines_to_next * 256) - current_delay + next_delay
                    found_next = true
                    break
                end
            end
            
            -- If no next note found, calculate distance to end
            if not found_next then
                local lines_to_end = (lines + 1) - i
                analysis[i].distance = (lines_to_end * 256) - current_delay
            end
        end
    end
    
    -- DEBUG: Show final analysis results
    print("DEBUG: Final analysis - found", note_count, "notes")
    if note_count > 0 then
        local sample_summary = {}
        for i = 1, lines do
            if analysis[i].note_value ~= renoise.PatternLine.EMPTY_NOTE then
                local slice = analysis[i].instrument_value
                sample_summary[slice] = (sample_summary[slice] or 0) + 1
            end
        end
        print("DEBUG: Slice usage:", (function()
            local str = ""
            for slice, count in pairs(sample_summary) do
                str = str .. "slice" .. slice .. "=" .. count .. " "
            end
            return str
        end)())
    end

    return analysis

end

-- Create break patterns from phrase and breakpoint labels
function breakpoints.create_break_patterns(instrument, original_phrase, saved_labels, source_instrument_index)
    local sets = {}
    -- Ensure we have a valid source instrument index
    local actual_source_instrument_index = source_instrument_index or renoise.song().selected_instrument_index
    local analysis = get_line_analysis(original_phrase)
    local breakpoint_indices = get_breakpoint_indices(saved_labels)
    local breakpoint_lines = get_breakpoint_lines(analysis, breakpoint_indices)
    
    -- Find start and end points for each set
    local set_boundaries = {}
    table.insert(set_boundaries, 1)
    for _, line in ipairs(breakpoint_lines) do
        table.insert(set_boundaries, line)
    end
    table.insert(set_boundaries, original_phrase.number_of_lines + 1)
    
    -- Create sets from boundaries
    for i = 1, #set_boundaries - 1 do
        local set = {
            start_line = set_boundaries[i],
            end_line = set_boundaries[i + 1] - 1,
            notes = {}
        }
        
        -- Collect notes within this set's boundaries
        for line = set.start_line, set.end_line do
            if analysis[line] and analysis[line].note_value ~= renoise.PatternLine.EMPTY_NOTE then
                table.insert(set.notes, {
                    line = line,
                    note_value = analysis[line].note_value,
                    instrument_value = analysis[line].instrument_value,
                    delay_value = analysis[line].delay_value,
                    distance = analysis[line].distance,
                    is_last = analysis[line].is_last
                })
            end
        end
        
        -- Calculate new timing for the set
        set.timing = calculate_set_distances(set, analysis, actual_source_instrument_index)
        
        table.insert(sets, set)
    end
    
    return sets
end

-- Adjust timing for set transitions
local function adjust_timing(set, adjusted_delay, next_start_line)
    local adjusted_set = {}
    for k, v in pairs(set) do
        adjusted_set[k] = v
    end
    
    adjusted_set.timing = {}
    for _, timing in ipairs(set.timing) do
        local new_timing = {}
        for k, v in pairs(timing) do
            new_timing[k] = v
        end
        
        new_timing.new_delay = timing.new_delay + adjusted_delay
        if new_timing.new_delay > 255 then
            new_timing.new_delay = new_timing.new_delay % 256
            new_timing.relative_line = timing.relative_line + 1
        end
        new_timing.relative_line = new_timing.relative_line + next_start_line - 1
        
        table.insert(adjusted_set.timing, new_timing)
    end
    
    return adjusted_set
end

-- Stitch break sets together according to permutation
local function stitch_breaks(permutation, sets)
    local new_set = {timing = {}}
    
    for i, set_index in ipairs(permutation) do
        local current_set = sets[set_index]
        
        if i == 1 then
            -- First set - use as-is
            for _, timing in ipairs(current_set.timing) do
                local new_timing = {}
                for k, v in pairs(timing) do
                    new_timing[k] = v
                end
                table.insert(new_set.timing, new_timing)
            end
        else
            -- Subsequent sets - adjust timing based on previous set
            local prev_timing = new_set.timing[#new_set.timing]
            local prev_delay = prev_timing.new_delay
            local prev_line = prev_timing.relative_line
            local delay_diff = 256 - prev_delay
            local prev_distance = prev_timing.original_distance
            
            local line_gap = math.floor((prev_distance - delay_diff) / 256)
            local adjusted_delay = prev_distance - delay_diff - (line_gap * 256)
            local next_start_line = prev_line + line_gap + 1
            
            local adjusted_set = adjust_timing(current_set, adjusted_delay, next_start_line)
            
            for _, timing in ipairs(adjusted_set.timing) do
                table.insert(new_set.timing, timing)
            end
        end
    end
    
    return new_set
end

-- Create a phrase from a break permutation
function breakpoints.create_break_phrase(sets, original_phrase, permutation, phrase_name)
    local song = renoise.song()
    local current_instrument = song.selected_instrument
    
    -- Create new phrase
    local new_phrase = current_instrument:insert_phrase_at(#current_instrument.phrases + 1)
    new_phrase:copy_from(original_phrase)
    new_phrase.name = string.format("Break %s", phrase_name)
    
    -- Stitch breaks according to permutation
    local stitched_set = stitch_breaks(permutation, sets)
    
    -- Calculate required phrase length
    local required_length = 16 -- minimum
    if stitched_set.timing and #stitched_set.timing > 0 then
        local last_timing = stitched_set.timing[#stitched_set.timing]
        local lines_to_add = math.floor(last_timing.original_distance / 256)
        required_length = last_timing.relative_line + lines_to_add
    end
    
    new_phrase.number_of_lines = required_length
    
    -- Clear the phrase
    for i = 1, new_phrase.number_of_lines do
        local line = new_phrase:line(i)
        for j = 1, 12 do
            line:note_column(j):clear()
        end
        for j = 1, 8 do
            line:effect_column(j):clear()
        end
    end
    
    -- Apply the stitched timing
    for _, timing in ipairs(stitched_set.timing) do
        if timing.relative_line <= new_phrase.number_of_lines then
            local line = new_phrase:line(timing.relative_line)
            local note_column = line:note_column(1)
            
            note_column.note_value = 48  -- C-4
            note_column.instrument_value = timing.instrument_value
            note_column.delay_value = timing.new_delay
        end
    end
    
    return new_phrase
end

return breakpoints