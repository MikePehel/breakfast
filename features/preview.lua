-- features/preview.lua - Audio Preview System for BreakFast
local preview = {}

-- Dependencies
local registry = require("core/registry")

-- ============================================================================
-- Preview State
-- ============================================================================

local preview_state = {
    active = false,
    instrument_index = nil,
    track_index = nil,
    notes = {},              -- Active notes for cleanup
    scheduled_notes = nil,   -- Notes waiting to be triggered
    symbol = nil,
    start_time = nil,
    finishing = false,
    finish_time = nil,
    current_note_index = nil
}

-- Timer state
local timer_active = false

-- Forward declaration for timer callback
local timer_callback

-- ============================================================================
-- State Accessors
-- ============================================================================

function preview.is_active()
    return preview_state.active
end

function preview.get_current_symbol()
    return preview_state.symbol
end

function preview.get_state()
    return preview_state
end

-- ============================================================================
-- Preview Control
-- ============================================================================

-- Stop any currently playing preview
function preview.stop()
    -- Remove timer if active
    if timer_active then
        if renoise.tool():has_timer(timer_callback) then
            renoise.tool():remove_timer(timer_callback)
        end
        timer_active = false
    end
    
    if not preview_state.active then
        return
    end
    
    local song = renoise.song()
    if not song then
        preview_state.active = false
        preview_state.notes = {}
        preview_state.symbol = nil
        return
    end
    
    -- Stop all notes that were triggered
    for _, note_info in ipairs(preview_state.notes) do
        local inst_idx = note_info.instrument_index
        local track_idx = preview_state.track_index or song.selected_track_index
        local note_val = note_info.note_value
        
        -- Use API 6.2 trigger_instrument_note_off
        pcall(function()
            song:trigger_instrument_note_off(inst_idx, track_idx, note_val)
        end)
    end
    
    print("DEBUG: Stopped preview for symbol:", preview_state.symbol or "unknown")
    
    -- Reset preview state
    preview_state.active = false
    preview_state.instrument_index = nil
    preview_state.track_index = nil
    preview_state.notes = {}
    preview_state.symbol = nil
    preview_state.scheduled_notes = nil
    preview_state.current_note_index = nil
    preview_state.start_time = nil
    preview_state.finishing = false
    preview_state.finish_time = nil
end

-- Timer callback for sequential note playback
timer_callback = function()
    if not preview_state.active or not preview_state.scheduled_notes then
        preview.stop()
        return
    end
    
    local song = renoise.song()
    if not song then
        preview.stop()
        return
    end
    
    local current_time = os.clock()
    local elapsed = current_time - preview_state.start_time
    local elapsed_ms = elapsed * 1000
    
    -- Check for notes that should be triggered
    local notes_remaining = false
    for i, note_info in ipairs(preview_state.scheduled_notes) do
        if not note_info.triggered then
            notes_remaining = true
            if elapsed_ms >= note_info.trigger_time_ms then
                -- Trigger this note
                local inst_idx = note_info.instrument_index
                local track_idx = preview_state.track_index
                local note_val = note_info.note_value
                local vol_normalized = note_info.volume_normalized
                
                pcall(function()
                    song:trigger_instrument_note_on(inst_idx, track_idx, note_val, vol_normalized)
                end)
                
                -- Add to active notes for cleanup
                table.insert(preview_state.notes, {
                    note_value = note_val,
                    instrument_index = inst_idx
                })
                
                note_info.triggered = true
                print("DEBUG: Triggered note", note_val, "inst", inst_idx, "at", elapsed_ms, "ms")
            end
        end
    end
    
    -- Check if all notes have been triggered
    if not notes_remaining then
        -- Keep timer running briefly to let last notes play, then stop
        if not preview_state.finishing then
            preview_state.finishing = true
            preview_state.finish_time = current_time
        elseif current_time - preview_state.finish_time > 0.5 then
            -- 500ms after last note, stop preview
            preview.stop()
        end
    end
end

-- Preview a symbol (plays notes in sequence with original timing)
function preview.play_symbol(symbol_name)
    -- Stop any existing preview first
    preview.stop()
    
    local song = renoise.song()
    if not song then
        renoise.app():show_warning("No song loaded")
        return false
    end
    
    -- Check if symbol exists in registry
    local symbol_data = registry.get_symbol(symbol_name)
    if not symbol_data then
        print("DEBUG: Symbol not found in registry:", symbol_name)
        return false
    end
    
    -- Get current BPM and LPB for timing calculations
    local bpm = song.transport.bpm
    local lpb = song.transport.lpb
    
    -- Calculate milliseconds per line
    local ms_per_line = 60000 / (bpm * lpb)
    local ms_per_delay_unit = ms_per_line / 256
    
    print("DEBUG: BPM=" .. bpm .. " LPB=" .. lpb .. " ms_per_line=" .. ms_per_line)
    
    -- Collect notes with their timing information
    local scheduled_notes = {}
    
    if symbol_data.break_set and symbol_data.break_set.timing then
        for _, timing in ipairs(symbol_data.break_set.timing) do
            local relative_line = timing.relative_line or 1
            local delay = timing.new_delay or 0
            local trigger_time_ms = ((relative_line - 1) * ms_per_line) + (delay * ms_per_delay_unit)
            local source_inst_idx = timing.source_instrument_index or symbol_data.instrument_index or 1
            
            -- Check for multi-column data
            if timing.note_columns then
                for col_idx, col_data in pairs(timing.note_columns) do
                    if col_data.note_value and 
                       col_data.note_value ~= renoise.PatternLine.EMPTY_NOTE and
                       col_data.note_value < 120 and
                       col_data.instrument_value and
                       col_data.instrument_value ~= 255 then
                        local slice_note = 36 + col_data.instrument_value
                        local volume = col_data.volume_value or 0x80
                        local vol_normalized = (volume == 255 or volume == renoise.PatternLine.EMPTY_VOLUME) 
                            and 0.5 or (volume / 127)
                        
                        table.insert(scheduled_notes, {
                            note_value = slice_note,
                            instrument_index = source_inst_idx,
                            volume_normalized = vol_normalized,
                            trigger_time_ms = trigger_time_ms,
                            triggered = false
                        })
                    end
                end
            -- Fallback to single note_value
            elseif timing.note_value and 
                   timing.note_value ~= renoise.PatternLine.EMPTY_NOTE and
                   timing.note_value < 120 and
                   timing.instrument_value and
                   timing.instrument_value ~= 255 then
                local slice_note = 36 + timing.instrument_value
                local volume = timing.volume_value or 0x80
                local vol_normalized = (volume == 255 or volume == renoise.PatternLine.EMPTY_VOLUME) 
                    and 0.5 or (volume / 127)
                
                table.insert(scheduled_notes, {
                    note_value = slice_note,
                    instrument_index = source_inst_idx,
                    volume_normalized = vol_normalized,
                    trigger_time_ms = trigger_time_ms,
                    triggered = false
                })
            end
        end
    end
    
    if #scheduled_notes == 0 then
        print("DEBUG: No valid notes to preview for symbol:", symbol_name)
        return false
    end
    
    -- Sort by trigger time
    table.sort(scheduled_notes, function(a, b)
        return a.trigger_time_ms < b.trigger_time_ms
    end)
    
    -- Add initial delay (150ms) to allow UI to settle
    local initial_delay_ms = 150
    for _, note in ipairs(scheduled_notes) do
        note.trigger_time_ms = note.trigger_time_ms + initial_delay_ms
    end
    
    -- Set up preview state
    preview_state.active = true
    preview_state.track_index = song.selected_track_index
    preview_state.symbol = symbol_name
    preview_state.notes = {}
    preview_state.scheduled_notes = scheduled_notes
    preview_state.start_time = os.clock()
    preview_state.finishing = false
    
    -- Start timer (10ms interval for responsive timing)
    if not renoise.tool():has_timer(timer_callback) then
        renoise.tool():add_timer(timer_callback, 10)
        timer_active = true
    end
    
    print("DEBUG: Started sequential preview for symbol:", symbol_name, "with", #scheduled_notes, "notes")
    return true
end

-- Preview a specific sample directly
function preview.play_sample(instrument_index, sample_index, note_value, volume)
    local song = renoise.song()
    if not song then return false end
    
    -- Stop any existing preview
    preview.stop()
    
    local track_idx = song.selected_track_index
    local vol_normalized = volume and (volume / 127) or 0.5
    
    -- Set up preview state for single note
    preview_state.active = true
    preview_state.track_index = track_idx
    preview_state.symbol = nil
    preview_state.notes = {{
        note_value = note_value,
        instrument_index = instrument_index,
        sample_index = sample_index
    }}
    
    -- Use trigger_sample_note_on for direct sample playback
    local success = pcall(function()
        song:trigger_sample_note_on(instrument_index, sample_index, track_idx, note_value, vol_normalized, false)
    end)
    
    return success
end

-- ============================================================================
-- Timing Utilities
-- ============================================================================

-- Calculate milliseconds per line based on current song tempo
function preview.get_ms_per_line()
    local song = renoise.song()
    if not song then return 125 end -- Default fallback
    
    local bpm = song.transport.bpm
    local lpb = song.transport.lpb
    return 60000 / (bpm * lpb)
end

-- Calculate trigger time from line and delay
function preview.calculate_trigger_time(relative_line, delay)
    local ms_per_line = preview.get_ms_per_line()
    local ms_per_delay_unit = ms_per_line / 256
    return ((relative_line - 1) * ms_per_line) + (delay * ms_per_delay_unit)
end

return preview
