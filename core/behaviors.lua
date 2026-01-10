-- core/behaviors.lua - Behavior State Management for BreakFast
local behaviors = {}

-- Dependencies
local constants = require("core/constants")

-- ============================================================================
-- Current Behavior State
-- ============================================================================
-- These track the currently selected behavior modes

local current_overflow_behavior = constants.overflow_behavior.EXTEND
local current_overwrite_behavior = constants.overwrite_behavior.SUM
local current_instrument_source_behavior = constants.instrument_source_behavior.EMBEDDED
local current_multi_track_distance_mode = constants.multi_track_distance_mode.SYNC_FIRST
local current_ignore_blank_tracks = false

-- ============================================================================
-- Overflow Behavior
-- ============================================================================

function behaviors.get_overflow()
    return current_overflow_behavior
end

function behaviors.set_overflow(value)
    current_overflow_behavior = value
end

function behaviors.get_overflow_constants()
    return constants.overflow_behavior
end

function behaviors.is_overflow_extend()
    return current_overflow_behavior == constants.overflow_behavior.EXTEND
end

function behaviors.is_overflow_next_pattern()
    return current_overflow_behavior == constants.overflow_behavior.NEXT_PATTERN
end

function behaviors.is_overflow_truncate()
    return current_overflow_behavior == constants.overflow_behavior.TRUNCATE
end

function behaviors.is_overflow_loop()
    return current_overflow_behavior == constants.overflow_behavior.LOOP
end

function behaviors.is_overflow_insert()
    return current_overflow_behavior == constants.overflow_behavior.INSERT
end

-- ============================================================================
-- Overwrite Behavior
-- ============================================================================

function behaviors.get_overwrite()
    return current_overwrite_behavior
end

function behaviors.set_overwrite(value)
    current_overwrite_behavior = value
end

function behaviors.get_overwrite_constants()
    return constants.overwrite_behavior
end

function behaviors.is_overwrite_sum()
    return current_overwrite_behavior == constants.overwrite_behavior.SUM
end

function behaviors.is_overwrite_replace()
    return current_overwrite_behavior == constants.overwrite_behavior.REPLACE
end

function behaviors.is_overwrite_substitute()
    return current_overwrite_behavior == constants.overwrite_behavior.SUBSTITUTE
end

function behaviors.is_overwrite_retain()
    return current_overwrite_behavior == constants.overwrite_behavior.RETAIN
end

function behaviors.is_overwrite_exclude()
    return current_overwrite_behavior == constants.overwrite_behavior.EXCLUDE
end

function behaviors.is_overwrite_intersect()
    return current_overwrite_behavior == constants.overwrite_behavior.INTERSECT
end

-- ============================================================================
-- Instrument Source Behavior
-- ============================================================================

function behaviors.get_instrument_source()
    return current_instrument_source_behavior
end

function behaviors.set_instrument_source(value)
    current_instrument_source_behavior = value
end

function behaviors.get_instrument_source_constants()
    return constants.instrument_source_behavior
end

function behaviors.is_instrument_source_embedded()
    return current_instrument_source_behavior == constants.instrument_source_behavior.EMBEDDED
end

function behaviors.is_instrument_source_current()
    return current_instrument_source_behavior == constants.instrument_source_behavior.CURRENT_SELECTED
end

-- ============================================================================
-- Multi-Track Distance Mode
-- ============================================================================

function behaviors.get_multi_track_distance_mode()
    return current_multi_track_distance_mode
end

function behaviors.set_multi_track_distance_mode(value)
    current_multi_track_distance_mode = value
end

function behaviors.get_multi_track_distance_mode_constants()
    return constants.multi_track_distance_mode
end

function behaviors.is_multi_track_sync_first()
    return current_multi_track_distance_mode == constants.multi_track_distance_mode.SYNC_FIRST
end

function behaviors.is_multi_track_independent()
    return current_multi_track_distance_mode == constants.multi_track_distance_mode.INDEPENDENT
end

function behaviors.is_multi_track_sync_last()
    return current_multi_track_distance_mode == constants.multi_track_distance_mode.SYNC_LAST
end

-- ============================================================================
-- Ignore Blank Tracks
-- ============================================================================

function behaviors.get_ignore_blank_tracks()
    return current_ignore_blank_tracks
end

function behaviors.set_ignore_blank_tracks(value)
    current_ignore_blank_tracks = value
end

-- ============================================================================
-- Reset to Defaults
-- ============================================================================

function behaviors.reset_all()
    current_overflow_behavior = constants.overflow_behavior.EXTEND
    current_overwrite_behavior = constants.overwrite_behavior.SUM
    current_instrument_source_behavior = constants.instrument_source_behavior.EMBEDDED
    current_multi_track_distance_mode = constants.multi_track_distance_mode.SYNC_FIRST
    current_ignore_blank_tracks = false
end

-- ============================================================================
-- Bulk Getters (for editor module compatibility)
-- ============================================================================

-- Get all behavior states as a table (for passing to other modules)
function behaviors.get_all()
    return {
        overflow = current_overflow_behavior,
        overwrite = current_overwrite_behavior,
        instrument_source = current_instrument_source_behavior,
        multi_track_distance_mode = current_multi_track_distance_mode,
        ignore_blank_tracks = current_ignore_blank_tracks
    }
end

-- Get all constants (for UI building)
function behaviors.get_all_constants()
    return {
        overflow = constants.overflow_behavior,
        overwrite = constants.overwrite_behavior,
        instrument_source = constants.instrument_source_behavior,
        multi_track_distance_mode = constants.multi_track_distance_mode
    }
end

return behaviors
