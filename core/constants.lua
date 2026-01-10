-- core/constants.lua - Centralized constants for BreakFast
local constants = {}

-- ============================================================================
-- Overflow Behavior
-- ============================================================================
-- Controls what happens when placed notes exceed the current pattern length

constants.overflow_behavior = {
    EXTEND = 1,       -- Extend pattern length to fit all notes
    NEXT_PATTERN = 2, -- Continue overflow notes in the next pattern
    TRUNCATE = 3,     -- Cut off notes that don't fit
    LOOP = 4,         -- Wrap overflow notes back to pattern start
    INSERT = 5        -- Insert a new pattern after current, move overflow there
}

constants.overflow_behavior_names = {
    [1] = "Extend",
    [2] = "Next Pattern",
    [3] = "Truncate",
    [4] = "Loop",
    [5] = "Insert"
}

-- ============================================================================
-- Overwrite Behavior
-- ============================================================================
-- Controls how new notes interact with existing pattern content

constants.overwrite_behavior = {
    SUM = 1,        -- Add new notes alongside existing (find empty columns)
    REPLACE = 2,    -- Clear all content in placement range first
    SUBSTITUTE = 3, -- Only place where content already exists
    RETAIN = 4,     -- Skip lines that have existing content
    EXCLUDE = 5,    -- Only place where NO content exists
    INTERSECT = 6   -- Place only on lines that have content, skip empty lines
}

constants.overwrite_behavior_names = {
    [1] = "Sum",
    [2] = "Replace",
    [3] = "Substitute",
    [4] = "Retain",
    [5] = "Exclude",
    [6] = "Intersect"
}

-- ============================================================================
-- Instrument Source Behavior
-- ============================================================================
-- Controls which instrument index is used when placing notes

constants.instrument_source_behavior = {
    EMBEDDED = 1,        -- Use instrument values stored in the symbol data
    CURRENT_SELECTED = 2 -- Use the currently selected instrument in Renoise
}

constants.instrument_source_behavior_names = {
    [1] = "Embedded",
    [2] = "Current Selected"
}

-- ============================================================================
-- Multi-Track Distance Mode
-- ============================================================================
-- Controls how note distances are calculated across multiple tracks

constants.multi_track_distance_mode = {
    SYNC_FIRST = 1,  -- Sync all tracks to first track's cutoff distance (shortest)
    INDEPENDENT = 2, -- Each track calculates its own distance independently
    SYNC_LAST = 3    -- Sync all tracks to last track's cutoff distance (longest)
}

constants.multi_track_distance_mode_names = {
    [1] = "Sync First",
    [2] = "Independent",
    [3] = "Sync Last"
}

-- ============================================================================
-- Symbol Definitions
-- ============================================================================
-- Available symbols for break pattern assignment

-- Primary symbols (A-T) plus numeric symbols (0-9)
constants.available_symbols = {
    "A", "B", "C", "D", "E", "F", "G", "H", "I", "J",
    "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T",
    "0", "1", "2", "3", "4", "5", "6", "7", "8", "9"
}

-- Composite symbols for combining multiple breaks
constants.composite_symbols = {"U", "V", "W", "X", "Y", "Z"}

-- ============================================================================
-- Pagination Defaults
-- ============================================================================

constants.pagination = {
    symbols_per_page = 12, -- 3x4 grid (3 rows, 4 columns)
    grid_columns = 4,
    grid_rows = 3
}

return constants
