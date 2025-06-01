-- editor.lua - Direct Pattern Editor Placement (Phase 2: Added Substitute Overwrite Behavior)
local editor = {}
local labeler = require("labeler")
local breakpoints = require("breakpoints")

-- Import main module functions (will be set by main.lua)
local get_overflow_behavior = nil
local get_overflow_behavior_constants = nil
-- Import overwrite behavior functions
local get_overwrite_behavior = nil
local get_overwrite_behavior_constants = nil
-- Import global symbol registry functions
local get_global_symbol_registry = nil
local get_symbol_instrument_mapping = nil

-- State management for chaining symbols (unchanged)
local placement_state = {
    current_track = nil,
    current_line = nil,
    next_placement_line = nil,
    break_sets = nil,
    last_cursor_position = {track = nil, line = nil},
    is_chaining = false,
    -- New timing state for proper stitching
    last_symbol_timing = nil,  -- Store timing info from last placed symbol
    cumulative_timing = {}     -- Track cumulative timing for stitching
}

-- Observable notifiers and idle tracking (unchanged)
local cursor_notifiers = {}
local idle_notifier = nil

-- Initialization state (unchanged)
local is_initialized = false

-- Initialize the editor module - now safe for startup (unchanged)
function editor.initialize()
    -- Don't initialize if already done
    if is_initialized then
        return
    end
    
    -- Check if song is available before proceeding
    if not renoise.song() then
        -- Song not available yet - register for when it becomes available
        renoise.app().app_new_document_observable:add_notifier(function()
            editor.initialize()
        end)
        return
    end
    
    -- Song is available, proceed with initialization
    -- Set up cursor change detection using app_idle_observable
    -- since selected_line_index is not observable
    idle_notifier = function()
        editor.check_cursor_change()
    end
    
    -- Track changes to detect manual cursor movement
    cursor_notifiers.track = function()
        editor.check_cursor_change()
    end
    
    local song = renoise.song()
    song.selected_track_index_observable:add_notifier(cursor_notifiers.track)
    renoise.tool().app_idle_observable:add_notifier(idle_notifier)
    
    is_initialized = true
end

-- Clean up notifiers when tool unloads (unchanged)
function editor.cleanup()
    if not is_initialized then
        return
    end
    
    local song = renoise.song()
    
    if cursor_notifiers.track then
        song.selected_track_index_observable:remove_notifier(cursor_notifiers.track)
    end
    
    if idle_notifier then
        renoise.tool().app_idle_observable:remove_notifier(idle_notifier)
    end
    
    cursor_notifiers = {}
    idle_notifier = nil
    is_initialized = false
end

-- Check if cursor position changed manually (unchanged)
function editor.check_cursor_change()
    if not renoise.song() then
        return
    end
    
    local song = renoise.song()
    local current_track = song.selected_track_index
    local current_line = song.selected_line_index
    
    -- If this is a manual cursor change (not from our placement), reset state
    if placement_state.is_chaining and 
       (current_track ~= placement_state.current_track or 
        current_line ~= placement_state.current_line) and
       (current_track ~= placement_state.last_cursor_position.track or
        current_line ~= placement_state.last_cursor_position.line) then
        
        editor.reset_placement_state()
    end
    
    placement_state.last_cursor_position.track = current_track
    placement_state.last_cursor_position.line = current_line
end

-- Reset placement state (unchanged)
function editor.reset_placement_state()
    placement_state.current_track = nil
    placement_state.current_line = nil
    placement_state.next_placement_line = nil
    placement_state.break_sets = nil
    placement_state.is_chaining = false
    placement_state.last_symbol_timing = nil
    placement_state.cumulative_timing = {}
end

-- Set reference to main module functions
function editor.set_main_module_functions(overflow_behavior_getter, overflow_constants_getter, overwrite_behavior_getter, overwrite_constants_getter, instrument_source_behavior_getter, instrument_source_constants_getter, symbol_registry_getter, symbol_instrument_mapper)
    get_overflow_behavior = overflow_behavior_getter
    get_overflow_behavior_constants = overflow_constants_getter
    -- Store overwrite behavior functions
    get_overwrite_behavior = overwrite_behavior_getter
    get_overwrite_behavior_constants = overwrite_constants_getter
    -- Store instrument source behavior functions
    get_instrument_source_behavior = instrument_source_behavior_getter
    get_instrument_source_behavior_constants = instrument_source_constants_getter
    -- Store global symbol registry functions
    get_global_symbol_registry = symbol_registry_getter
    get_symbol_instrument_mapping = symbol_instrument_mapper
end

-- Get break sets - now primarily for legacy compatibility and caching
function editor.get_break_sets()
    if not renoise.song() then
        return nil, "Song not available"
    end
    
    if placement_state.break_sets then
        return placement_state.break_sets
    end
    
    local song = renoise.song()
    local instrument = song.selected_instrument
    local current_instrument_index = song.selected_instrument_index
    local saved_labels = labeler.get_labels_for_instrument(current_instrument_index)
    
    -- Check if we have any breakpoints defined
    local has_breakpoints = false
    for _, label_data in pairs(saved_labels) do
        if label_data.breakpoint then
            has_breakpoints = true
            break
        end
    end
    
    if not has_breakpoints then
        return nil, "No breakpoints defined. Please set breakpoints in the labeler first"
    end
    
    if #instrument.phrases == 0 then
        return nil, "No phrases available in selected instrument"
    end
    
    local original_phrase = instrument.phrases[1]
    local break_sets = breakpoints.create_break_patterns(instrument, original_phrase, saved_labels, current_instrument_index)
    
    if not break_sets or #break_sets == 0 then
        return nil, "No valid break sets created"
    end
    
    -- Cache the break sets
    placement_state.break_sets = break_sets
    return break_sets
end

local function apply_timing_adjustment(set, adjusted_delay, next_start_line)
    print("DEBUG: apply_timing_adjustment called with adjusted_delay=" .. adjusted_delay .. ", next_start_line=" .. next_start_line)
    print("DEBUG: Original set has " .. #set.timing .. " timing entries")
    
    local adjusted_set = {}
    for k, v in pairs(set) do
        adjusted_set[k] = v
    end
    
    adjusted_set.timing = {}
    for i, timing in ipairs(set.timing) do
        local new_timing = {}
        for k, v in pairs(timing) do
            new_timing[k] = v
        end
        
        print("DEBUG: Original timing[" .. i .. "] relative_line=" .. timing.relative_line .. ", new_delay=" .. timing.new_delay)
        
        new_timing.new_delay = timing.new_delay + adjusted_delay
        if new_timing.new_delay > 255 then
            new_timing.new_delay = new_timing.new_delay % 256
            new_timing.relative_line = timing.relative_line + 1
        end
        new_timing.relative_line = new_timing.relative_line + next_start_line - 1
        
        print("DEBUG: Adjusted timing[" .. i .. "] relative_line=" .. new_timing.relative_line .. ", new_delay=" .. new_timing.new_delay)
        
        table.insert(adjusted_set.timing, new_timing)
    end
    
    return adjusted_set
end

-- Calculate stitched placement positions using breakpoints logic (CORRECTED: Simple cursor position fix)
local function calculate_stitched_placement_positions(break_set, start_line, last_symbol_timing, symbol_type)
    local placement_info = {
        notes = {},
        next_line = start_line,
        last_note_distance = nil  -- Track the last note's distance for pattern extension
    }
    
    local current_set = break_set
    
    -- If we have timing from a previous symbol, apply stitching logic
    if last_symbol_timing then
        local prev_timing = last_symbol_timing
        local prev_delay = prev_timing.new_delay
        local prev_line = prev_timing.relative_line
        local delay_diff = 256 - prev_delay
        local prev_distance = prev_timing.original_distance
        
        local line_gap = math.floor((prev_distance - delay_diff) / 256)
        local adjusted_delay = prev_distance - delay_diff - (line_gap * 256)
        local next_start_line = prev_line + line_gap + 1
        
        print("DEBUG: Timing calculation - prev_line=" .. prev_line .. ", line_gap=" .. line_gap .. ", calculated next_start_line=" .. next_start_line .. ", but placement start_line=" .. start_line)
        
        -- FIXED: Use the actual placement start_line, not the calculated next_start_line
        -- Apply timing adjustment using the same logic as breakpoints
        current_set = apply_timing_adjustment(break_set, adjusted_delay, start_line)
        
        -- DON'T update start_line - keep the placement position
        print("DEBUG: Using placement start_line=" .. start_line .. " instead of calculated=" .. next_start_line)
    end
    
    local base_line = start_line
    local last_note_timing = nil
    
    for _, timing in ipairs(current_set.timing) do
        -- SIMPLE FIX: For first symbol, use cursor position; for chained symbols, use calculated position
        local target_line
        if last_symbol_timing then
            -- Chained symbol - use the calculated relative position
            target_line = timing.relative_line
        else
            -- First symbol - place relative to cursor position
            target_line = base_line + timing.relative_line - 1
        end
        
        -- Calculate note value based on symbol type
        local note_value
        if symbol_type == "range_captured" then
            -- Range-captured symbol: use raw note value from timing data
            note_value = timing.note_value or 48  -- Fallback to C-4 if missing
        else
            -- Breakpoint symbol: calculate from slice index (original behavior)
            note_value = 36 + timing.instrument_value
        end
        
        table.insert(placement_info.notes, {
            line = target_line,
            delay = timing.new_delay,
            instrument_value = timing.instrument_value,
            note_value = note_value,
            source_instrument_index = timing.source_instrument_index,
            original_distance = timing.original_distance  -- Include distance for pattern extension
        })
        
        -- Keep track of the last note timing for calculating next symbol position
        last_note_timing = timing
    end
    
    -- Calculate next placement line based on the last note's distance
    if last_note_timing then
        -- Use the original distance from the breakpoints analysis
        local distance_in_lines = math.floor(last_note_timing.original_distance / 256)
        local distance_delay = last_note_timing.original_distance % 256
        
        -- Calculate the effective end position
        local last_note_line
        if last_symbol_timing then
            -- Chained symbol
            last_note_line = last_note_timing.relative_line
        else
            -- First symbol
            last_note_line = base_line + last_note_timing.relative_line - 1
        end
        
        placement_info.next_line = last_note_line + distance_in_lines
        
        -- If there's remaining delay, we might need to advance one more line
        if last_note_timing.new_delay + distance_delay >= 256 then
            placement_info.next_line = placement_info.next_line + 1
        end
        
        -- Store the last timing for next symbol
        placement_info.last_timing = last_note_timing
        
        -- Store the last note's distance information for pattern extension
        placement_info.last_note_distance = {
            line = last_note_line,
            delay = last_note_timing.new_delay,
            original_distance = last_note_timing.original_distance
        }
    end
    
    return placement_info
end

-- Place a symbol at the current cursor position using global symbol registry
function editor.place_symbol(symbol_name)
    print("DEBUG: editor.place_symbol() called with symbol: " .. tostring(symbol_name))
    
    if not renoise.song() then
        renoise.app():show_warning("Song not available")
        return false
    end
    
    local song = renoise.song()
    
    -- Check if symbol exists in global registry
    if not get_global_symbol_registry then
        renoise.app():show_warning("Global symbol registry not available")
        return false
    end
    
    local global_registry = get_global_symbol_registry()
    local symbol_data = global_registry[symbol_name]
    
    if not symbol_data then
        print("DEBUG: Symbol not found in global registry: " .. tostring(symbol_name))
        renoise.app():show_warning("Symbol " .. symbol_name .. " not available. Please assign breakpoints to an instrument first.")
        return false
    end
    
    print("DEBUG: Found symbol", symbol_name, "for instrument", symbol_data.instrument_index, "type:", symbol_data.symbol_type or "breakpoint_created")
    
    -- Use the break set from the global registry
    local selected_set = symbol_data.break_set
    local symbol_type = symbol_data.symbol_type or "breakpoint_created"
    if not selected_set or not selected_set.timing or #selected_set.timing == 0 then
        renoise.app():show_warning(string.format("Symbol %s has no notes to place", symbol_name))
        return false
    end
    
    -- Get current cursor position
    local current_track = song.selected_track_index
    local current_line = song.selected_line_index
    
    -- Initialize placement state if this is the first symbol or cursor moved
    if not placement_state.is_chaining or 
       placement_state.current_track ~= current_track or
       placement_state.current_line ~= current_line then
        
        placement_state.current_track = current_track
        placement_state.current_line = current_line
        placement_state.next_placement_line = current_line
        placement_state.is_chaining = true
        placement_state.last_symbol_timing = nil
        placement_state.cumulative_timing = {}
    end
    
    
    -- Use the break set from global registry (already validated above)
    -- selected_set is already set from symbol_data.break_set
    
    -- Calculate placement positions using stitching logic
    local placement_info = calculate_stitched_placement_positions(
        selected_set, 
        placement_state.next_placement_line, 
        placement_state.last_symbol_timing,
        symbol_type  -- Pass symbol type to calculation function
    )

-- ALWAYS use the placement position as the start line - this follows the chain correctly
    placement_info.original_start_line = placement_state.next_placement_line
    print("DEBUG: Stored start line: " .. placement_info.original_start_line .. " (cursor at " .. current_line .. ")")

    -- Check for next pattern overflow behavior before placing
    if get_overflow_behavior and get_overflow_behavior_constants then
        local current_behavior = get_overflow_behavior()
        local behavior_constants = get_overflow_behavior_constants()
        
        if current_behavior == behavior_constants.NEXT_PATTERN then
            -- Check if ANY note in this symbol would exceed current pattern length
            local max_note_line = 0
            for _, note in ipairs(placement_info.notes) do
                max_note_line = math.max(max_note_line, note.line)
            end
            
            if max_note_line > song.selected_pattern.number_of_lines then
                local current_sequence_pos = song.selected_sequence_index
                local next_sequence_pos = current_sequence_pos + 1
                
                -- Check if next pattern exists, create if needed
                if next_sequence_pos > #song.sequencer.pattern_sequence then
                    local new_pattern_index = song.sequencer:insert_new_pattern_at(next_sequence_pos)
                    print("DEBUG: Created new pattern " .. new_pattern_index .. " at sequence position " .. next_sequence_pos)
                end
                
                -- FIXED: Calculate offset based on current pattern length and cursor position
                local current_pattern_length = song.selected_pattern.number_of_lines
                local cursor_offset = placement_state.next_placement_line - 1  -- Convert to 0-based
                
                -- NEW: Store original positions before pattern transition for Intersect behavior
                placement_info.original_next_line_before_transition = placement_info.next_line
                placement_info.original_start_line_before_transition = placement_info.original_start_line
                
                -- Move to next pattern
                song.selected_sequence_index = next_sequence_pos
                
                -- FIXED: Adjust all note positions to wrap to new pattern accounting for cursor position
                for _, note in ipairs(placement_info.notes) do
                    -- Calculate how far this note extends beyond the current pattern
                    local overhang = note.line - current_pattern_length
                    -- Place it at the beginning of next pattern plus the overhang
                    note.line = overhang
                end
                
                -- FIXED: Adjust next_line calculation for proper chaining
                local next_line_overhang = placement_info.next_line - current_pattern_length
                placement_info.next_line = next_line_overhang
                
                -- NEW: Adjust original_start_line for new pattern context
                if placement_info.original_start_line then
                    local start_line_overhang = placement_info.original_start_line - current_pattern_length
                    placement_info.original_start_line = start_line_overhang
                    print("DEBUG: Adjusted original_start_line from " .. placement_info.original_start_line_before_transition .. " to " .. placement_info.original_start_line .. " for new pattern")
                end
                
                -- FIXED: Adjust last_timing to maintain stitching chain with cursor offset
                if placement_info.last_timing then
                    local timing_overhang = placement_info.last_timing.relative_line - current_pattern_length
                    placement_info.last_timing.relative_line = timing_overhang
                end
                
                -- FIXED: Adjust last_note_distance for pattern extension calculations
                if placement_info.last_note_distance then
                    local distance_overhang = placement_info.last_note_distance.line - current_pattern_length
                    placement_info.last_note_distance.line = distance_overhang
                end
                
                -- NEW: Mark that pattern transition occurred for Intersect behavior
                placement_info.pattern_transition_occurred = true
                
                -- Update placement state to reflect new pattern position
                placement_state.next_placement_line = placement_info.next_line
                
                print("DEBUG: Moved to next pattern, adjusted notes with cursor offset consideration")
            end
        end
    end
    
    -- Place the notes
    local success = editor.place_notes_in_pattern(placement_info, current_track)
    
    if success then
        -- Update next placement line and timing state for chaining
        placement_state.next_placement_line = placement_info.next_line
        placement_state.last_symbol_timing = placement_info.last_timing
        
        renoise.app():show_status(string.format("Placed symbol %s (%d notes)", 
            symbol_name, #placement_info.notes))
        return true
    end
    
    return false
end

-- Calculate where to place notes based on timing data (LEGACY - kept for backward compatibility) (unchanged)
function editor.calculate_placement_positions(break_set, start_line)
    local placement_info = {
        notes = {},
        next_line = start_line
    }
    
    local base_line = start_line
    local last_note_timing = nil
    
    for _, timing in ipairs(break_set.timing) do
        local target_line = base_line + timing.relative_line - 1
        
        -- Calculate note value based on symbol type
        local note_value
        if timing.note_value then
            -- Range-captured symbol: use raw note value
            note_value = timing.note_value
        else
            -- Breakpoint symbol: calculate from slice index
            note_value = 36 + timing.instrument_value
        end
        
        table.insert(placement_info.notes, {
            line = target_line,
            delay = timing.new_delay,
            instrument_value = timing.instrument_value,
            note_value = note_value,
            source_instrument_index = timing.source_instrument_index
        })
        
        -- Keep track of the last note timing for calculating next symbol position
        last_note_timing = timing
    end
    
    -- Calculate next placement line based on the last note's distance
    if last_note_timing then
        -- Use the original distance from the breakpoints analysis
        local distance_in_lines = math.floor(last_note_timing.original_distance / 256)
        local distance_delay = last_note_timing.original_distance % 256
        
        -- Calculate the effective end position
        local last_note_line = base_line + last_note_timing.relative_line - 1
        placement_info.next_line = last_note_line + distance_in_lines
        
        -- If there's remaining delay, we might need to advance one more line
        if last_note_timing.new_delay + distance_delay >= 256 then
            placement_info.next_line = placement_info.next_line + 1
        end
    end
    
    return placement_info
end

-- Handle extend overflow behavior (unchanged)
local function handle_extend_overflow(placement_info, pattern)
    -- Calculate required pattern length considering note durations
    local required_length = pattern.number_of_lines
    
    -- Find the maximum line where notes are placed
    local max_note_line = 0
    for _, note in ipairs(placement_info.notes) do
        max_note_line = math.max(max_note_line, note.line)
    end
    
    -- Calculate total required length including the last note's duration
    if placement_info.last_note_distance then
        local last_note_info = placement_info.last_note_distance
        local distance_in_lines = math.floor(last_note_info.original_distance / 256)
        local distance_delay = last_note_info.original_distance % 256
        
        -- Calculate the end position where the last note's duration completes
        local duration_end_line = last_note_info.line + distance_in_lines - 1
        
        -- If the combined delay (note delay + distance delay) exceeds 256, we need an extra line
        if last_note_info.delay + distance_delay >= 256 then
            duration_end_line = duration_end_line + 1
        end
        
        -- The pattern needs to be at least as long as this duration end
        required_length = math.max(required_length, duration_end_line)
        
        print("DEBUG: Pattern extension - Last note at line " .. last_note_info.line .. 
              ", distance: " .. last_note_info.original_distance .. 
              ", calculated end: " .. duration_end_line)
    else
        -- Fallback to old behavior if distance info is not available
        required_length = math.max(required_length, max_note_line)
    end
    
    -- Extend pattern if necessary
    if required_length > pattern.number_of_lines then
        print("DEBUG: Extending pattern from " .. pattern.number_of_lines .. " to " .. required_length .. " lines")
        pattern.number_of_lines = required_length
    end
end

-- Handle next pattern overflow behavior (unchanged)
local function handle_next_pattern_overflow(placement_info, pattern)
    -- For next pattern behavior, we don't modify anything here
    -- The overflow logic is handled in place_symbol() before placement
    -- This function is just a placeholder for consistency
    return
end

-- Handle truncate overflow behavior (unchanged)
local function handle_truncate_overflow(placement_info, pattern)
    local pattern_length = pattern.number_of_lines
    local original_note_count = #placement_info.notes
    local truncated_notes = {}
    local truncated_count = 0
    
    -- Filter out notes that would exceed pattern boundary
    for _, note in ipairs(placement_info.notes) do
        if note.line <= pattern_length then
            table.insert(truncated_notes, note)
        else
            truncated_count = truncated_count + 1
        end
    end
    
    -- Update placement_info with truncated notes
    placement_info.notes = truncated_notes
    
    -- Show truncation message if notes were removed
    if truncated_count > 0 then
        local message = string.format("Truncated: %d/%d notes placed (%d notes exceeded pattern boundary)", 
            #truncated_notes, original_note_count, truncated_count)
        renoise.app():show_warning(message)
        print("DEBUG: " .. message)
    end
    
    return true, truncated_count > 0 and truncated_count or nil
end

-- Handle loop overflow behavior (FIXED: Now handles cursor positioning correctly)
local function handle_loop_overflow(placement_info, pattern)
    local pattern_length = pattern.number_of_lines
    local wrapped_notes = 0
    
    -- IMPORTANT: Calculate the CORRECT original range for Replace/Intersect behavior
    if placement_info.next_line and placement_info.next_line > pattern_length then
        -- Calculate the actual symbol range length
        local start_line = placement_info.original_start_line or 1
        local symbol_range_length = placement_info.next_line - start_line
        
        -- The original_next_line should represent where the symbol would end if there was no wrapping
        -- This is: start_line + symbol_range_length
        placement_info.original_next_line = start_line + symbol_range_length
        
        print("DEBUG: Loop overflow - symbol starts at " .. start_line .. 
              ", range length " .. symbol_range_length .. 
              ", setting original_next_line to " .. placement_info.original_next_line .. 
              " (unwrapped next: " .. placement_info.next_line .. ")")
    end
    
    -- Wrap notes that exceed pattern boundary back to beginning
    for _, note in ipairs(placement_info.notes) do
        if note.line > pattern_length then
            -- FIXED: Calculate how many full pattern cycles we've exceeded
            local excess_lines = note.line - pattern_length
            -- Wrap back to beginning: line 65 becomes line 1, line 66 becomes line 2, etc.
            note.line = ((excess_lines - 1) % pattern_length) + 1
            wrapped_notes = wrapped_notes + 1
        end
    end
    
    -- FIXED: Also wrap the next_line for continued stitching
    if placement_info.next_line > pattern_length then
        local excess_lines = placement_info.next_line - pattern_length
        placement_info.next_line = ((excess_lines - 1) % pattern_length) + 1
        print("DEBUG: Loop overflow - wrapped next_line from " .. placement_info.original_next_line .. " to " .. placement_info.next_line)
    end
    
    -- FIXED: Update last_note_distance if it exists
    if placement_info.last_note_distance and placement_info.last_note_distance.line > pattern_length then
        local excess_lines = placement_info.last_note_distance.line - pattern_length
        placement_info.last_note_distance.line = ((excess_lines - 1) % pattern_length) + 1
    end
    
    -- FIXED: Update last_timing for proper chaining
    if placement_info.last_timing and placement_info.last_timing.relative_line > pattern_length then
        local excess_lines = placement_info.last_timing.relative_line - pattern_length
        placement_info.last_timing.relative_line = ((excess_lines - 1) % pattern_length) + 1
    end
    
    -- Show loop message if notes were wrapped
    if wrapped_notes > 0 then
        local message = string.format("Loop: %d notes wrapped to beginning of pattern", wrapped_notes)
        renoise.app():show_status(message)
        print("DEBUG: " .. message)
    end
    
    return true, wrapped_notes > 0 and wrapped_notes or nil
end

-- Handle sum overwrite behavior (existing)
local function handle_sum_overwrite(placement_info, track, pattern)
    -- This is the current default behavior - try first column, then additional columns
    -- No special handling needed here since this is implemented in the note placement loop
    -- This function exists for consistency and future expansion
    return true
end

-- Handle replace overwrite behavior (existing)
local function handle_replace_overwrite(placement_info, track, pattern)
    -- Calculate the range that needs to be cleared for Replace behavior
    -- This includes all lines from the first note to the next symbol position (including trailing space)
    
    if not placement_info.notes or #placement_info.notes == 0 then
        return true -- Nothing to replace
    end
    
    -- Check if we're using Truncate overflow behavior
    local is_truncate_mode = false
    if get_overflow_behavior and get_overflow_behavior_constants then
        local current_overflow_behavior = get_overflow_behavior()
        local overflow_constants = get_overflow_behavior_constants()
        is_truncate_mode = (current_overflow_behavior == overflow_constants.TRUNCATE)
    end
    
    -- Find the start line - always use the original cursor position, not wrapped note positions
    local start_line = placement_info.original_start_line
    if not start_line then
        -- Fallback: find earliest note position (but this shouldn't happen)
        for _, note in ipairs(placement_info.notes) do
            if not start_line or note.line < start_line then
                start_line = note.line
            end
        end
        print("DEBUG: WARNING - using fallback start_line calculation: " .. (start_line or "none"))
    else
        print("DEBUG: Replace using preserved original start_line: " .. start_line)
    end
    
    -- Calculate end line based on the next symbol placement position
    local end_line = nil
    local original_end_line = nil
    
    if placement_info.original_next_line then
        -- Use the preserved original_next_line, but limit it to reasonable bounds
        original_end_line = placement_info.original_next_line - 1
        
        -- Sanity check: if the range seems too large, use a more conservative calculation
        local range_length = original_end_line - start_line + 1
        if range_length > 64 then  -- If range is larger than a full pattern, use conservative estimate
            -- Find the actual latest note position (accounting for wrapped notes)
            local latest_note_line = start_line
            for _, note in ipairs(placement_info.notes) do
                local note_line = note.line
                -- If note wrapped around, calculate its original position
                if note_line < start_line then
                    note_line = note_line + pattern.number_of_lines
                end
                latest_note_line = math.max(latest_note_line, note_line)
            end
            
            -- Add reasonable trailing space
            original_end_line = latest_note_line + 4
            print("DEBUG: Replace behavior - limited large range, using calculated end: " .. original_end_line .. 
                  " (original was " .. (placement_info.original_next_line - 1) .. ")")
        end
        
        end_line = original_end_line
        
        print("DEBUG: Replace behavior - using range " .. start_line .. " to " .. original_end_line .. 
              " (original next_line was " .. placement_info.original_next_line .. ")")
    elseif placement_info.next_line then
        -- Use next_line - 1 because next_line is where the NEXT symbol would start
        original_end_line = placement_info.next_line - 1
        end_line = original_end_line
        
        print("DEBUG: Replace behavior - using current next_line, range would end at line " .. original_end_line .. 
              " (next symbol at " .. placement_info.next_line .. ", pattern length " .. pattern.number_of_lines .. ")")
    elseif placement_info.last_note_distance then
        -- Fallback: use last note distance calculation
        local last_note_info = placement_info.last_note_distance
        local distance_in_lines = math.floor(last_note_info.original_distance / 256)
        local distance_delay = last_note_info.original_distance % 256
        
        -- Calculate the end position where the symbol's duration completes
        original_end_line = last_note_info.line + distance_in_lines
        
        -- If the combined delay exceeds 256, we need an extra line
        if last_note_info.delay + distance_delay >= 256 then
            original_end_line = original_end_line + 1
        end
        
        end_line = original_end_line
        
        print("DEBUG: Replace behavior (fallback) - range would end at line " .. original_end_line .. 
              " (last note at " .. last_note_info.line .. ", distance: " .. last_note_info.original_distance .. ")")
    else
        -- Last resort: find the latest line where we're placing notes and add buffer
        for _, note in ipairs(placement_info.notes) do
            if not end_line or note.line > end_line then
                end_line = note.line
            end
        end
        
        -- Add buffer for safety when we don't have distance info
        end_line = end_line + 4
        original_end_line = end_line
        
        print("DEBUG: Replace behavior (last resort) - range ends at line " .. end_line)
    end
    
    -- Handle different clearing scenarios based on overflow behavior and range
    if is_truncate_mode then
        -- Truncate mode: Simply limit to pattern boundaries, no wraparound
        start_line = math.max(1, start_line)
        end_line = math.min(pattern.number_of_lines, end_line)
        
        print("DEBUG: Replace behavior (truncate mode) - clearing from line " .. start_line .. " to " .. end_line)
        
        -- Clear the range within pattern boundaries
        local cleared_notes = 0
        for line_num = start_line, end_line do
            local line = track:line(line_num)
            
            for col = 1, #line.note_columns do
                local note_column = line:note_column(col)
                if note_column.note_value ~= renoise.PatternLine.EMPTY_NOTE then
                    note_column:clear()
                    cleared_notes = cleared_notes + 1
                end
            end
        end
        
        if cleared_notes > 0 then
            print("DEBUG: Replace behavior cleared " .. cleared_notes .. " notes from lines " .. start_line .. "-" .. end_line)
        end
        
    elseif original_end_line and original_end_line > pattern.number_of_lines then
        -- Wraparound scenario: Handle both original part and wrapped part
        local wrapped_end_line = original_end_line - pattern.number_of_lines
        
        print("DEBUG: Replace behavior (wraparound) - clearing original range " .. start_line .. " to " .. pattern.number_of_lines .. 
              " and wrapped range 1 to " .. wrapped_end_line .. 
              " (total symbol range: " .. original_end_line .. " lines)")
        
        -- Clear original part (from start_line to end of pattern)
        local cleared_notes = 0
        local cleared_original = 0
        local cleared_wrapped = 0
        
        start_line = math.max(1, start_line)
        
        -- Clear ALL notes in the original range (start_line to end of pattern)
        for line_num = start_line, pattern.number_of_lines do
            local line = track:line(line_num)
            
            -- Clear ALL note columns on this line (not just non-empty ones)
            for col = 1, #line.note_columns do
                local note_column = line:note_column(col)
                if note_column.note_value ~= renoise.PatternLine.EMPTY_NOTE then
                    note_column:clear()
                    cleared_notes = cleared_notes + 1
                    cleared_original = cleared_original + 1
                end
            end
        end
        
        -- Clear wrapped part (from beginning to wrapped_end_line, but exclude the symbol's starting position)
        if wrapped_end_line >= 1 then
            wrapped_end_line = math.min(pattern.number_of_lines, wrapped_end_line)
            
            -- Only clear wrapped range if it doesn't conflict with symbol starting position
            if wrapped_end_line < start_line then
                -- Safe to clear the wrapped range since it doesn't overlap with symbol start
                for line_num = 1, wrapped_end_line do
                    local line = track:line(line_num)
                    
                    -- Clear ALL note columns on this line
                    for col = 1, #line.note_columns do
                        local note_column = line:note_column(col)
                        if note_column.note_value ~= renoise.PatternLine.EMPTY_NOTE then
                            note_column:clear()
                            cleared_notes = cleared_notes + 1
                            cleared_wrapped = cleared_wrapped + 1
                        end
                    end
                end
                print("DEBUG: Wrapped clearing from line 1 to " .. wrapped_end_line)
            else
                print("DEBUG: Skipping wrapped clearing to avoid clearing symbol starting position " .. start_line)
            end
        end
        
        if cleared_notes > 0 then
            print("DEBUG: Replace behavior cleared " .. cleared_notes .. " total notes: " .. 
                  cleared_original .. " from original range (lines " .. start_line .. "-" .. pattern.number_of_lines .. "), " ..
                  cleared_wrapped .. " from wrapped range (lines 1-" .. wrapped_end_line .. ")")
        else
            print("DEBUG: Replace behavior - no existing notes found to clear in wraparound ranges")
        end
        
    else
        -- Normal scenario: Clear within pattern boundaries
        start_line = math.max(1, start_line)
        end_line = math.min(pattern.number_of_lines, end_line)
        
        print("DEBUG: Replace behavior (normal) - clearing from line " .. start_line .. " to " .. end_line)
        
        local cleared_notes = 0
        for line_num = start_line, end_line do
            local line = track:line(line_num)
            
            for col = 1, #line.note_columns do
                local note_column = line:note_column(col)
                if note_column.note_value ~= renoise.PatternLine.EMPTY_NOTE then
                    note_column:clear()
                    cleared_notes = cleared_notes + 1
                end
            end
        end
        
        if cleared_notes > 0 then
            print("DEBUG: Replace behavior cleared " .. cleared_notes .. " notes from lines " .. start_line .. "-" .. end_line)
        end
    end
    
    return true
end

-- NEW: Handle substitute overwrite behavior
local function handle_substitute_overwrite(placement_info, track, pattern)
    -- Substitute behavior: Only replace notes on lines where the new symbol has notes
    -- Leave all other existing notes untouched
    
    if not placement_info.notes or #placement_info.notes == 0 then
        return true -- Nothing to substitute
    end
    
    -- Use original cursor position as reference
    local start_line = placement_info.original_start_line
    print("DEBUG: Substitute using original cursor position: " .. (start_line or "unknown"))
    
    -- Create a set of lines where new notes will be placed
    local new_note_lines = {}
    for _, note in ipairs(placement_info.notes) do
        new_note_lines[note.line] = true
    end
    
    -- Clear notes only on lines where new notes will be placed
    local cleared_notes = 0
    for line_num, _ in pairs(new_note_lines) do
        if line_num >= 1 and line_num <= pattern.number_of_lines then
            local line = track:line(line_num)
            
            -- Clear all note columns on this specific line only
            for col = 1, #line.note_columns do
                local note_column = line:note_column(col)
                if note_column.note_value ~= renoise.PatternLine.EMPTY_NOTE then
                    note_column:clear()
                    cleared_notes = cleared_notes + 1
                end
            end
        end
    end
    
    if cleared_notes > 0 then
        local line_count = 0
        for _ in pairs(new_note_lines) do
            line_count = line_count + 1
        end
        print("DEBUG: Substitute behavior cleared " .. cleared_notes .. " notes from " .. line_count .. " conflicting lines")
    end
    
    return true
end

-- NEW: Handle retain overwrite behavior
local function handle_retain_overwrite(placement_info, track, pattern)
    -- Retain behavior: Only place notes where the first note column is empty
    -- Skip placement for any line where the first column already contains note data
    -- This preserves existing notes by not overwriting them
    
    if not placement_info.notes or #placement_info.notes == 0 then
        return true -- Nothing to retain
    end
    
    -- Use original cursor position as reference
    local start_line = placement_info.original_start_line
    print("DEBUG: Retain using original cursor position: " .. (start_line or "unknown"))
    
    local retained_notes = {}
    local skipped_notes = 0
    
    -- Filter notes to only include those that can be placed without overwriting first column
    for _, note in ipairs(placement_info.notes) do
        if note.line >= 1 and note.line <= pattern.number_of_lines then
            local line = track:line(note.line)
            local first_column = line:note_column(1)
            
            -- Only place note if the first column is empty
            if first_column.note_value == renoise.PatternLine.EMPTY_NOTE then
                table.insert(retained_notes, note)
            else
                skipped_notes = skipped_notes + 1
            end
        else
            -- Skip notes outside pattern boundaries
            skipped_notes = skipped_notes + 1
        end
    end
    
    -- Update placement_info with only the retained notes
    placement_info.notes = retained_notes
    
    -- Show retain message if notes were skipped
    if skipped_notes > 0 then
        local message = string.format("Retain: %d/%d notes placed (%d notes skipped due to conflicts)", 
            #retained_notes, #retained_notes + skipped_notes, skipped_notes)
        renoise.app():show_status(message)
        print("DEBUG: " .. message)
    end
    
    return true
end

-- NEW: Handle exclude overwrite behavior
local function handle_exclude_overwrite(placement_info, track, pattern)
    -- Exclude behavior: Only keep notes that don't conflict between new and existing
    -- Remove existing notes that conflict with new notes
    -- Skip placement of new notes that conflict with existing notes
    -- Result: only non-conflicting notes from both sources remain
    -- NOTE: This runs AFTER overflow handling, so note positions are final
    
    if not placement_info.notes or #placement_info.notes == 0 then
        return true -- Nothing to exclude
    end
    
    -- Use original cursor position as reference
    local start_line = placement_info.original_start_line
    print("DEBUG: Exclude using original cursor position: " .. (start_line or "unknown"))
    
    -- First pass: identify conflicts and track what to clear/skip
    -- Use the actual final line positions (post-overflow)
    local conflicts = {} -- lines where both new and existing notes exist
    local cleared_notes = 0
    local skipped_notes = 0
    
    for _, note in ipairs(placement_info.notes) do
        -- Ensure line is within pattern bounds (should be after overflow handling)
        if note.line >= 1 and note.line <= pattern.number_of_lines then
            local line = track:line(note.line)
            local first_column = line:note_column(1)
            
            -- Check if there's an existing note that would conflict
            if first_column.note_value ~= renoise.PatternLine.EMPTY_NOTE then
                conflicts[note.line] = true
                print("DEBUG: Exclude found conflict at line " .. note.line)
            end
        else
            print("DEBUG: Exclude - note at line " .. note.line .. " is outside pattern bounds (1-" .. pattern.number_of_lines .. ")")
        end
    end
    
    -- Second pass: clear existing notes on conflicting lines
    for line_num, _ in pairs(conflicts) do
        local line = track:line(line_num)
        local first_column = line:note_column(1)
        print("DEBUG: Exclude clearing existing note at line " .. line_num)
        first_column:clear()
        cleared_notes = cleared_notes + 1
    end
    
    -- Third pass: filter out new notes that would conflict
    local excluded_notes = {}
    
    for _, note in ipairs(placement_info.notes) do
        if note.line >= 1 and note.line <= pattern.number_of_lines then
            -- Skip new notes on conflicting lines
            if conflicts[note.line] then
                print("DEBUG: Exclude skipping new note at line " .. note.line .. " due to conflict")
                skipped_notes = skipped_notes + 1
            else
                -- Keep non-conflicting new notes
                print("DEBUG: Exclude keeping new note at line " .. note.line .. " (no conflict)")
                table.insert(excluded_notes, note)
            end
        else
            -- Skip notes outside pattern boundaries
            skipped_notes = skipped_notes + 1
        end
    end
    
    -- Update placement_info with only the non-conflicting notes
    placement_info.notes = excluded_notes
    
    -- Show exclude message
    if cleared_notes > 0 or skipped_notes > 0 then
        local message = string.format("Exclude: %d existing notes cleared, %d new notes skipped, %d notes placed", 
            cleared_notes, skipped_notes, #excluded_notes)
        renoise.app():show_status(message)
        print("DEBUG: " .. message)
    end
    
    return true
end

-- NEW: Handle intersect overwrite behavior
local function handle_intersect_overwrite(placement_info, track, pattern)
    -- Intersect behavior: Like Replace but only keep conflicting notes within the symbol range
    -- - Calculate the symbol range (from first note to next symbol position including trailing space)
    -- - Within that range: keep only conflicting notes, remove non-conflicting notes
    -- - Outside that range: leave existing notes untouched
    -- This behaves like Replace behavior but filters conflicts vs non-conflicts
    -- NOTE: This runs AFTER overflow handling, so note positions are final
    
    if not placement_info.notes or #placement_info.notes == 0 then
        return true -- Nothing to intersect
    end
    
    -- Check if we're using Truncate overflow behavior
    local is_truncate_mode = false
    if get_overflow_behavior and get_overflow_behavior_constants then
        local current_overflow_behavior = get_overflow_behavior()
        local overflow_constants = get_overflow_behavior_constants()
        is_truncate_mode = (current_overflow_behavior == overflow_constants.TRUNCATE)
    end
    
    -- Use the original cursor position as start line for Intersect behavior
    local start_line = placement_info.original_start_line
    if not start_line then
        -- Fallback: find earliest note position (but this shouldn't happen)
        for _, note in ipairs(placement_info.notes) do
            if not start_line or note.line < start_line then
                start_line = note.line
            end
        end
        print("DEBUG: WARNING - Intersect using fallback start_line calculation: " .. (start_line or "none"))
    else
        print("DEBUG: Intersect using original cursor position: " .. start_line)
    end
    
    -- Calculate end line based on the next symbol placement position
    local end_line = nil
    local original_end_line = nil
    
    -- NEW: Handle pattern transition case specifically for Next Pattern overflow
    if placement_info.pattern_transition_occurred then
        -- For pattern transitions, use adjusted positions in the new pattern
        if placement_info.next_line then
            original_end_line = placement_info.next_line - 1
            end_line = original_end_line
            print("DEBUG: Intersect behavior (pattern transition) - range ends at line " .. original_end_line .. 
                  " (next symbol at " .. placement_info.next_line .. " in new pattern)")
        elseif placement_info.last_note_distance then
            -- Fallback for pattern transition: use last note distance calculation
            local last_note_info = placement_info.last_note_distance
            local distance_in_lines = math.floor(last_note_info.original_distance / 256)
            local distance_delay = last_note_info.original_distance % 256
            
            original_end_line = last_note_info.line + distance_in_lines
            if last_note_info.delay + distance_delay >= 256 then
                original_end_line = original_end_line + 1
            end
            end_line = original_end_line
            
            print("DEBUG: Intersect behavior (pattern transition fallback) - range ends at line " .. original_end_line .. 
                  " (last note at " .. last_note_info.line .. ", distance: " .. last_note_info.original_distance .. ")")
        else
            -- Last resort for pattern transition
            for _, note in ipairs(placement_info.notes) do
                if not end_line or note.line > end_line then
                    end_line = note.line
                end
            end
            end_line = end_line + 4
            original_end_line = end_line
            print("DEBUG: Intersect behavior (pattern transition last resort) - range ends at line " .. end_line)
        end
    elseif placement_info.original_next_line then
        -- Use preserved original next_line for accurate range calculation
        original_end_line = placement_info.original_next_line - 1
        end_line = original_end_line
        
        print("DEBUG: Intersect behavior - original range would end at line " .. original_end_line .. 
              " (next symbol at " .. placement_info.original_next_line .. ", pattern length " .. pattern.number_of_lines .. ")")
    elseif placement_info.next_line then
        -- Use next_line - 1 because next_line is where the NEXT symbol would start
        original_end_line = placement_info.next_line - 1
        end_line = original_end_line
        
        print("DEBUG: Intersect behavior - range would end at line " .. original_end_line .. 
              " (next symbol at " .. placement_info.next_line .. ", pattern length " .. pattern.number_of_lines .. ")")
    elseif placement_info.last_note_distance then
        -- Fallback: use last note distance calculation
        local last_note_info = placement_info.last_note_distance
        local distance_in_lines = math.floor(last_note_info.original_distance / 256)
        local distance_delay = last_note_info.original_distance % 256
        
        -- Calculate the end position where the symbol's duration completes
        original_end_line = last_note_info.line + distance_in_lines
        
        -- If the combined delay exceeds 256, we need an extra line
        if last_note_info.delay + distance_delay >= 256 then
            original_end_line = original_end_line + 1
        end
        
        end_line = original_end_line
        
        print("DEBUG: Intersect behavior (fallback) - range would end at line " .. original_end_line .. 
              " (last note at " .. last_note_info.line .. ", distance: " .. last_note_info.original_distance .. ")")
    else
        -- Last resort: find the latest line where we're placing notes and add buffer
        for _, note in ipairs(placement_info.notes) do
            if not end_line or note.line > end_line then
                end_line = note.line
            end
        end
        
        -- Add buffer for safety when we don't have distance info
        end_line = end_line + 4
        original_end_line = end_line
        
        print("DEBUG: Intersect behavior (last resort) - range ends at line " .. end_line)
    end
    
    -- Handle different scenarios based on overflow behavior and range
    if is_truncate_mode then
        -- Truncate mode: Process only within pattern boundaries, no wraparound
        start_line = math.max(1, start_line)
        end_line = math.min(pattern.number_of_lines, end_line)
        
        print("DEBUG: Intersect behavior (truncate mode) - processing range " .. start_line .. " to " .. end_line)
        
        -- Find conflicts within the truncated range
        local conflicts = {}
        for _, note in ipairs(placement_info.notes) do
            if note.line >= start_line and note.line <= end_line then
                local line = track:line(note.line)
                local first_column = line:note_column(1)
                
                if first_column.note_value ~= renoise.PatternLine.EMPTY_NOTE then
                    conflicts[note.line] = true
                    print("DEBUG: Intersect found conflict at line " .. note.line)
                end
            end
        end
        
        -- Clear non-conflicting existing notes within the range
        local cleared_notes = 0
        for line_num = start_line, end_line do
            local line = track:line(line_num)
            local first_column = line:note_column(1)
            
            if first_column.note_value ~= renoise.PatternLine.EMPTY_NOTE and not conflicts[line_num] then
                first_column:clear()
                cleared_notes = cleared_notes + 1
            end
        end
        
        -- Filter new notes: place all if no conflicts, otherwise only conflicting ones
        local has_any_conflicts = next(conflicts) ~= nil
        local intersected_notes = {}
        local skipped_notes = 0
        
        for _, note in ipairs(placement_info.notes) do
            if note.line >= start_line and note.line <= end_line then
                if not has_any_conflicts or conflicts[note.line] then
                    table.insert(intersected_notes, note)
                else
                    skipped_notes = skipped_notes + 1
                end
            else
                skipped_notes = skipped_notes + 1
            end
        end
        
        placement_info.notes = intersected_notes
        
        if cleared_notes > 0 or skipped_notes > 0 then
            print("DEBUG: Intersect (truncate) cleared " .. cleared_notes .. " notes, skipped " .. skipped_notes .. " new notes")
        end
        
    elseif original_end_line and original_end_line > pattern.number_of_lines then
        -- Wraparound scenario: Handle both original part and wrapped part
        local wrapped_end_line = original_end_line - pattern.number_of_lines
        
        print("DEBUG: Intersect behavior (wraparound) - processing original range " .. start_line .. " to " .. pattern.number_of_lines .. 
              " and wrapped range 1 to " .. wrapped_end_line)
        
        -- Find conflicts in both ranges
        local conflicts = {}
        local wrapped_conflicts = {}
        
        -- Check original range for conflicts
        for _, note in ipairs(placement_info.notes) do
            if note.line >= start_line and note.line <= pattern.number_of_lines then
                local line = track:line(note.line)
                local first_column = line:note_column(1)
                
                if first_column.note_value ~= renoise.PatternLine.EMPTY_NOTE then
                    conflicts[note.line] = true
                    print("DEBUG: Intersect found conflict at line " .. note.line .. " (original range)")
                end
            end
        end
        
        -- Check wrapped range for conflicts
        wrapped_end_line = math.min(pattern.number_of_lines, wrapped_end_line)
        for _, note in ipairs(placement_info.notes) do
            if note.line >= 1 and note.line <= wrapped_end_line then
                local line = track:line(note.line)
                local first_column = line:note_column(1)
                
                if first_column.note_value ~= renoise.PatternLine.EMPTY_NOTE then
                    wrapped_conflicts[note.line] = true
                    print("DEBUG: Intersect found conflict at line " .. note.line .. " (wrapped range)")
                end
            end
        end
        
        -- Clear non-conflicting notes in original range
        local cleared_notes = 0
        local cleared_original = 0
        local cleared_wrapped = 0
        
        start_line = math.max(1, start_line)
        
        for line_num = start_line, pattern.number_of_lines do
            local line = track:line(line_num)
            
            -- Clear ALL note columns for non-conflicting lines
            for col = 1, #line.note_columns do
                local note_column = line:note_column(col)
                if note_column.note_value ~= renoise.PatternLine.EMPTY_NOTE and not conflicts[line_num] then
                    note_column:clear()
                    cleared_notes = cleared_notes + 1
                    cleared_original = cleared_original + 1
                end
            end
        end
        
        -- Clear non-conflicting notes in wrapped range
        for line_num = 1, wrapped_end_line do
            local line = track:line(line_num)
            
            -- Clear ALL note columns for non-conflicting lines
            for col = 1, #line.note_columns do
                local note_column = line:note_column(col)
                if note_column.note_value ~= renoise.PatternLine.EMPTY_NOTE and not wrapped_conflicts[line_num] then
                    note_column:clear()
                    cleared_notes = cleared_notes + 1
                    cleared_wrapped = cleared_wrapped + 1
                end
            end
        end
        
        if cleared_notes > 0 then
            print("DEBUG: Intersect (wraparound) cleared " .. cleared_notes .. " non-conflicting notes: " .. 
                  cleared_original .. " from original range (lines " .. start_line .. "-" .. pattern.number_of_lines .. "), " ..
                  cleared_wrapped .. " from wrapped range (lines 1-" .. wrapped_end_line .. ")")
        else
            print("DEBUG: Intersect (wraparound) - no non-conflicting notes found to clear")
        end
        
        -- Filter new notes based on conflicts in both ranges
        local has_conflicts = next(conflicts) ~= nil or next(wrapped_conflicts) ~= nil
        local intersected_notes = {}
        local skipped_notes = 0
        
        for _, note in ipairs(placement_info.notes) do
            local in_original_range = (note.line >= start_line and note.line <= pattern.number_of_lines)
            local in_wrapped_range = (note.line >= 1 and note.line <= wrapped_end_line)
            
            if in_original_range or in_wrapped_range then
                if not has_conflicts or conflicts[note.line] or wrapped_conflicts[note.line] then
                    table.insert(intersected_notes, note)
                else
                    skipped_notes = skipped_notes + 1
                end
            else
                skipped_notes = skipped_notes + 1
            end
        end
        
        placement_info.notes = intersected_notes
        
        if cleared_notes > 0 or skipped_notes > 0 then
            print("DEBUG: Intersect (wraparound) cleared " .. cleared_notes .. " notes, skipped " .. skipped_notes .. " new notes")
        end
        
    else
        -- Normal scenario: Process within pattern boundaries
        start_line = math.max(1, start_line)
        end_line = math.min(pattern.number_of_lines, end_line)
        
        print("DEBUG: Intersect behavior (normal) - processing range " .. start_line .. " to " .. end_line)
        
        -- Find conflicts within the range
        local conflicts = {}
        for _, note in ipairs(placement_info.notes) do
            if note.line >= start_line and note.line <= end_line then
                local line = track:line(note.line)
                local first_column = line:note_column(1)
                
                if first_column.note_value ~= renoise.PatternLine.EMPTY_NOTE then
                    conflicts[note.line] = true
                    print("DEBUG: Intersect found conflict at line " .. note.line)
                end
            end
        end
        
        -- Clear non-conflicting existing notes within the range
        local cleared_notes = 0
        for line_num = start_line, end_line do
            local line = track:line(line_num)
            local first_column = line:note_column(1)
            
            if first_column.note_value ~= renoise.PatternLine.EMPTY_NOTE and not conflicts[line_num] then
                first_column:clear()
                cleared_notes = cleared_notes + 1
            end
        end
        
        -- Filter new notes: place all if no conflicts, otherwise only conflicting ones
        local has_any_conflicts = next(conflicts) ~= nil
        local intersected_notes = {}
        local skipped_notes = 0
        
        for _, note in ipairs(placement_info.notes) do
            if note.line >= start_line and note.line <= end_line then
                if not has_any_conflicts or conflicts[note.line] then
                    table.insert(intersected_notes, note)
                else
                    skipped_notes = skipped_notes + 1
                end
            else
                skipped_notes = skipped_notes + 1
            end
        end
        
        placement_info.notes = intersected_notes
        
        if cleared_notes > 0 or skipped_notes > 0 then
            print("DEBUG: Intersect (normal) cleared " .. cleared_notes .. " notes, skipped " .. skipped_notes .. " new notes")
        end
    end
    
    return true
end

-- UPDATED: Place notes in the pattern (now includes substitute overwrite behavior handling)
function editor.place_notes_in_pattern(placement_info, track_index)
    if not renoise.song() then
        renoise.app():show_warning("Song not available")
        return false
    end
    
    local song = renoise.song()
    local pattern = song.selected_pattern
    
    -- Validate track
    if track_index < 1 or track_index > #song.tracks then
        renoise.app():show_warning("Invalid track selected")
        return false
    end
    
    if song.tracks[track_index].type ~= renoise.Track.TRACK_TYPE_SEQUENCER then
        renoise.app():show_warning("Selected track is not a sequencer track")
        return false
    end
    
    local track = pattern:track(track_index)
    
    -- Handle overflow behavior FIRST (so overwrite behaviors work on final positions)
    if get_overflow_behavior and get_overflow_behavior_constants then
        local current_behavior = get_overflow_behavior()
        local behavior_constants = get_overflow_behavior_constants()
        
        if current_behavior == behavior_constants.EXTEND then
            handle_extend_overflow(placement_info, pattern)
        elseif current_behavior == behavior_constants.NEXT_PATTERN then
            handle_next_pattern_overflow(placement_info, pattern)
        elseif current_behavior == behavior_constants.TRUNCATE then
            handle_truncate_overflow(placement_info, pattern)
        elseif current_behavior == behavior_constants.LOOP then
            handle_loop_overflow(placement_info, pattern)
        else
            -- Fall back to extend for unimplemented options
            handle_extend_overflow(placement_info, pattern)
        end
    else
        -- Fallback if main module functions not available
        handle_extend_overflow(placement_info, pattern)
    end
    
    -- UPDATED: Handle overwrite behavior AFTER overflow (so it works on final positions)
    if get_overwrite_behavior and get_overwrite_behavior_constants then
        local current_overwrite_behavior = get_overwrite_behavior()
        local overwrite_constants = get_overwrite_behavior_constants()
        
        if current_overwrite_behavior == overwrite_constants.SUM then
            handle_sum_overwrite(placement_info, track, pattern)
        elseif current_overwrite_behavior == overwrite_constants.REPLACE then
            handle_replace_overwrite(placement_info, track, pattern)
        elseif current_overwrite_behavior == overwrite_constants.SUBSTITUTE then
            handle_substitute_overwrite(placement_info, track, pattern)
        elseif current_overwrite_behavior == overwrite_constants.RETAIN then
            handle_retain_overwrite(placement_info, track, pattern)
        elseif current_overwrite_behavior == overwrite_constants.EXCLUDE then
            handle_exclude_overwrite(placement_info, track, pattern)
        elseif current_overwrite_behavior == overwrite_constants.INTERSECT then
            handle_intersect_overwrite(placement_info, track, pattern)
        else
            -- Fall back to sum behavior for unknown options
            handle_sum_overwrite(placement_info, track, pattern)
        end
    else
        -- Fallback if overwrite behavior functions not available (maintain backward compatibility)
        handle_sum_overwrite(placement_info, track, pattern)
    end
    
    -- UPDATED: Place each note (updated logic to handle different overwrite behaviors including substitute, retain, exclude, and intersect)
    for _, note in ipairs(placement_info.notes) do
        if note.line >= 1 and note.line <= pattern.number_of_lines then
            local line = track:line(note.line)
            local note_column = line:note_column(1)
            
            -- Get current overwrite behavior to determine placement strategy
            local use_replace_behavior = false
            local use_substitute_behavior = false
            local use_retain_behavior = false
            local use_exclude_behavior = false
            local use_intersect_behavior = false
            if get_overwrite_behavior and get_overwrite_behavior_constants then
                local current_overwrite_behavior = get_overwrite_behavior()
                local overwrite_constants = get_overwrite_behavior_constants()
                use_replace_behavior = (current_overwrite_behavior == overwrite_constants.REPLACE)
                use_substitute_behavior = (current_overwrite_behavior == overwrite_constants.SUBSTITUTE)
                use_retain_behavior = (current_overwrite_behavior == overwrite_constants.RETAIN)
                use_exclude_behavior = (current_overwrite_behavior == overwrite_constants.EXCLUDE)
                use_intersect_behavior = (current_overwrite_behavior == overwrite_constants.INTERSECT)  -- NEW
            end
            
            if use_replace_behavior or use_substitute_behavior or use_exclude_behavior then
                -- Replace/Substitute/Exclude behavior: Always place in first column (we've already processed conflicts)
                note_column.note_value = note.note_value
                -- Determine instrument value based on instrument source behavior
                local instrument_value
                if get_instrument_source_behavior and get_instrument_source_behavior_constants then
                    local current_behavior = get_instrument_source_behavior()
                    local behavior_constants = get_instrument_source_behavior_constants()
                    if current_behavior == behavior_constants.CURRENT_SELECTED then
                        -- Use currently selected instrument (0-based for API)
                        instrument_value = renoise.song().selected_instrument_index - 1
                    else
                        -- Use embedded instrument value (default/fallback behavior)
                        instrument_value = (note.source_instrument_index or 1) - 1
                    end
                else
                    -- Fallback if instrument source behavior functions not available
                    instrument_value = (note.source_instrument_index or 1) - 1
                end
                note_column.instrument_value = instrument_value
                note_column.delay_value = note.delay
elseif use_intersect_behavior then
                -- Intersect behavior: Always place new notes, use sum logic for conflicts (opposite of exclude)
                -- This is identical to sum behavior - place in first column if empty, otherwise try additional columns
                if note_column.note_value == renoise.PatternLine.EMPTY_NOTE then
                    note_column.note_value = note.note_value
                    -- Determine instrument value based on instrument source behavior
                    local instrument_value
                    if get_instrument_source_behavior and get_instrument_source_behavior_constants then
                        local current_behavior = get_instrument_source_behavior()
                        local behavior_constants = get_instrument_source_behavior_constants()
                        if current_behavior == behavior_constants.CURRENT_SELECTED then
                            instrument_value = renoise.song().selected_instrument_index - 1
                        else
                            instrument_value = (note.source_instrument_index or 1) - 1
                        end
                    else
                        instrument_value = (note.source_instrument_index or 1) - 1
                    end
                    note_column.instrument_value = instrument_value
                    note_column.delay_value = note.delay
                else
                    -- Try additional columns if first is occupied (Sum behavior for intersect conflicts)
                    local placed = false
                    for col = 2, #line.note_columns do
                        local alt_column = line:note_column(col)
                        if alt_column.note_value == renoise.PatternLine.EMPTY_NOTE then
                            alt_column.note_value = note.note_value
                            -- Determine instrument value based on instrument source behavior
                            local instrument_value
                            if get_instrument_source_behavior and get_instrument_source_behavior_constants then
                                local current_behavior = get_instrument_source_behavior()
                                local behavior_constants = get_instrument_source_behavior_constants()
                                if current_behavior == behavior_constants.CURRENT_SELECTED then
                                    instrument_value = renoise.song().selected_instrument_index - 1
                                else
                                    instrument_value = (note.source_instrument_index or 1) - 1
                                end
                            else
                                instrument_value = (note.source_instrument_index or 1) - 1
                            end
                            alt_column.instrument_value = instrument_value
                            alt_column.delay_value = note.delay
                            placed = true
                            break
                        end
                    end
                    
                    if not placed then
                        renoise.app():show_warning(string.format(
                            "Could not place intersect note at line %d - all columns occupied", note.line))
                    end
                end
            elseif use_retain_behavior then
                -- Retain behavior: Only place if first column is empty (filtering already done in handler)
                -- Since we've already filtered in handle_retain_overwrite, we can place directly
                note_column.note_value = note.note_value
                -- Determine instrument value based on instrument source behavior
                local instrument_value
                if get_instrument_source_behavior and get_instrument_source_behavior_constants then
                    local current_behavior = get_instrument_source_behavior()
                    local behavior_constants = get_instrument_source_behavior_constants()
                    if current_behavior == behavior_constants.CURRENT_SELECTED then
                        instrument_value = renoise.song().selected_instrument_index - 1
                    else
                        instrument_value = (note.source_instrument_index or 1) - 1
                    end
                else
                    instrument_value = (note.source_instrument_index or 1) - 1
                end
                note_column.instrument_value = instrument_value
                note_column.delay_value = note.delay
            else
                -- Sum behavior: Only place if the slot is empty to avoid overwriting existing notes
                if note_column.note_value == renoise.PatternLine.EMPTY_NOTE then
                    note_column.note_value = note.note_value
                    -- Determine instrument value based on instrument source behavior
                    local instrument_value
                    if get_instrument_source_behavior and get_instrument_source_behavior_constants then
                        local current_behavior = get_instrument_source_behavior()
                        local behavior_constants = get_instrument_source_behavior_constants()
                        if current_behavior == behavior_constants.CURRENT_SELECTED then
                            instrument_value = renoise.song().selected_instrument_index - 1
                        else
                            instrument_value = (note.source_instrument_index or 1) - 1
                        end
                    else
                        instrument_value = (note.source_instrument_index or 1) - 1
                    end
                    note_column.instrument_value = instrument_value
                    note_column.delay_value = note.delay
                else
                    -- Try additional columns if first is occupied (Sum behavior)
                    local placed = false
                    for col = 2, #line.note_columns do
                        local alt_column = line:note_column(col)
                        if alt_column.note_value == renoise.PatternLine.EMPTY_NOTE then
                            alt_column.note_value = note.note_value
                            -- Determine instrument value based on instrument source behavior
                            local instrument_value
                            if get_instrument_source_behavior and get_instrument_source_behavior_constants then
                                local current_behavior = get_instrument_source_behavior()
                                local behavior_constants = get_instrument_source_behavior_constants()
                                if current_behavior == behavior_constants.CURRENT_SELECTED then
                                    instrument_value = renoise.song().selected_instrument_index - 1
                                else
                                    instrument_value = (note.source_instrument_index or 1) - 1
                                end
                            else
                                instrument_value = (note.source_instrument_index or 1) - 1
                            end
                            alt_column.instrument_value = instrument_value
                            alt_column.delay_value = note.delay
                            placed = true
                            break
                        end
                    end
                    
                    if not placed then
                        renoise.app():show_warning(string.format(
                            "Could not place note at line %d - all columns occupied", note.line))
                    end
                end
            end
        end
    end
    
    return true
end

-- Individual symbol placement functions for keybinding (unchanged)
function editor.place_symbol_a()
    print("DEBUG: editor.place_symbol_a() called - about to place symbol A")
    return editor.place_symbol("A")
end

function editor.place_symbol_b()
    print("DEBUG: editor.place_symbol_b() called - about to place symbol B")
    return editor.place_symbol("B")
end

function editor.place_symbol_c()
    print("DEBUG: editor.place_symbol_c() called - about to place symbol C")
    return editor.place_symbol("C")
end

function editor.place_symbol_d()
    print("DEBUG: editor.place_symbol_d() called - about to place symbol D")
    return editor.place_symbol("D")
end

function editor.place_symbol_e()
    print("DEBUG: editor.place_symbol_e() called - about to place symbol E")
    return editor.place_symbol("E")
end

-- Get current placement state for debugging (unchanged)
function editor.get_placement_state()
    return placement_state
end

return editor