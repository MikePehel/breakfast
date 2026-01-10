-- ui/behavior_panels.lua - Behavior Control Panels for BreakFast
local behavior_panels = {}

-- Dependencies
local behaviors = require("core/behaviors")
local constants = require("core/constants")

-- ============================================================================
-- Compact Overflow Section
-- ============================================================================

function behavior_panels.create_compact_overflow(vb)
    local overflow = constants.overflow_behavior
    
    return vb:column {
        style = "group",
        margin = 5,
        width = 60,
        vb:text {
            text = "OF",
            font = "bold",
            style = "strong"
        },
        vb:space { height = 3 },
        vb:row {
            spacing = 5,
            vb:checkbox {
                id = "compact_overflow_extend",
                value = behaviors.is_overflow_extend(),
                notifier = function(value)
                    if value then
                        behaviors.set_overflow(overflow.EXTEND)
                        vb.views.compact_overflow_next_pattern.value = false
                        vb.views.compact_overflow_truncate.value = false
                        vb.views.compact_overflow_loop.value = false
                        vb.views.compact_overflow_insert.value = false
                    end
                end
            },
            vb:text { text = "E", width = 15 }
        },
        vb:row {
            spacing = 5,
            vb:checkbox {
                id = "compact_overflow_next_pattern",
                value = behaviors.is_overflow_next_pattern(),
                notifier = function(value)
                    if value then
                        behaviors.set_overflow(overflow.NEXT_PATTERN)
                        vb.views.compact_overflow_extend.value = false
                        vb.views.compact_overflow_truncate.value = false
                        vb.views.compact_overflow_loop.value = false
                        vb.views.compact_overflow_insert.value = false
                    end
                end
            },
            vb:text { text = "N", width = 15 }
        },
        vb:row {
            spacing = 5,
            vb:checkbox {
                id = "compact_overflow_truncate",
                value = behaviors.is_overflow_truncate(),
                notifier = function(value)
                    if value then
                        behaviors.set_overflow(overflow.TRUNCATE)
                        vb.views.compact_overflow_extend.value = false
                        vb.views.compact_overflow_next_pattern.value = false
                        vb.views.compact_overflow_loop.value = false
                        vb.views.compact_overflow_insert.value = false
                    end
                end
            },
            vb:text { text = "T", width = 15 }
        },
        vb:row {
            spacing = 5,
            vb:checkbox {
                id = "compact_overflow_loop",
                value = behaviors.is_overflow_loop(),
                notifier = function(value)
                    if value then
                        behaviors.set_overflow(overflow.LOOP)
                        vb.views.compact_overflow_extend.value = false
                        vb.views.compact_overflow_next_pattern.value = false
                        vb.views.compact_overflow_truncate.value = false
                        vb.views.compact_overflow_insert.value = false
                    end
                end
            },
            vb:text { text = "L", width = 15 }
        },
        vb:row {
            spacing = 5,
            vb:checkbox {
                id = "compact_overflow_insert",
                value = behaviors.is_overflow_insert(),
                notifier = function(value)
                    if value then
                        behaviors.set_overflow(overflow.INSERT)
                        vb.views.compact_overflow_extend.value = false
                        vb.views.compact_overflow_next_pattern.value = false
                        vb.views.compact_overflow_truncate.value = false
                        vb.views.compact_overflow_loop.value = false
                    end
                end
            },
            vb:text { text = "I", width = 15 }
        }
    }
end

-- ============================================================================
-- Compact Overwrite Section
-- ============================================================================

function behavior_panels.create_compact_overwrite(vb)
    local overwrite = constants.overwrite_behavior
    
    return vb:column {
        style = "group",
        margin = 5,
        width = 60,
        vb:text {
            text = "OB",
            font = "bold",
            style = "strong"
        },
        vb:space { height = 3 },
        vb:row {
            spacing = 5,
            vb:checkbox {
                id = "compact_overwrite_sum",
                value = behaviors.is_overwrite_sum(),
                notifier = function(value)
                    if value then
                        behaviors.set_overwrite(overwrite.SUM)
                        vb.views.compact_overwrite_replace.value = false
                        vb.views.compact_overwrite_substitute.value = false
                        vb.views.compact_overwrite_retain.value = false
                        vb.views.compact_overwrite_exclude.value = false
                        vb.views.compact_overwrite_intersect.value = false
                    elseif behaviors.is_overwrite_sum() then
                        vb.views.compact_overwrite_sum.value = true
                    end
                end
            },
            vb:text { text = "+", width = 15 }
        },
        vb:row {
            spacing = 5,
            vb:checkbox {
                id = "compact_overwrite_replace",
                value = behaviors.is_overwrite_replace(),
                notifier = function(value)
                    if value then
                        behaviors.set_overwrite(overwrite.REPLACE)
                        vb.views.compact_overwrite_sum.value = false
                        vb.views.compact_overwrite_substitute.value = false
                        vb.views.compact_overwrite_retain.value = false
                        vb.views.compact_overwrite_exclude.value = false
                        vb.views.compact_overwrite_intersect.value = false
                    elseif behaviors.is_overwrite_replace() then
                        vb.views.compact_overwrite_replace.value = true
                    end
                end
            },
            vb:text { text = "R", width = 15 }
        },
        vb:row {
            spacing = 5,
            vb:checkbox {
                id = "compact_overwrite_substitute",
                value = behaviors.is_overwrite_substitute(),
                notifier = function(value)
                    if value then
                        behaviors.set_overwrite(overwrite.SUBSTITUTE)
                        vb.views.compact_overwrite_sum.value = false
                        vb.views.compact_overwrite_replace.value = false
                        vb.views.compact_overwrite_retain.value = false
                        vb.views.compact_overwrite_exclude.value = false
                        vb.views.compact_overwrite_intersect.value = false
                    elseif behaviors.is_overwrite_substitute() then
                        vb.views.compact_overwrite_substitute.value = true
                    end
                end
            },
            vb:text { text = "S", width = 15 }
        },
        vb:row {
            spacing = 5,
            vb:checkbox {
                id = "compact_overwrite_retain",
                value = behaviors.is_overwrite_retain(),
                notifier = function(value)
                    if value then
                        behaviors.set_overwrite(overwrite.RETAIN)
                        vb.views.compact_overwrite_sum.value = false
                        vb.views.compact_overwrite_replace.value = false
                        vb.views.compact_overwrite_substitute.value = false
                        vb.views.compact_overwrite_exclude.value = false
                        vb.views.compact_overwrite_intersect.value = false
                    elseif behaviors.is_overwrite_retain() then
                        vb.views.compact_overwrite_retain.value = true
                    end
                end
            },
            vb:text { text = "P", width = 15 }
        },
        vb:row {
            spacing = 5,
            vb:checkbox {
                id = "compact_overwrite_exclude",
                value = behaviors.is_overwrite_exclude(),
                notifier = function(value)
                    if value then
                        behaviors.set_overwrite(overwrite.EXCLUDE)
                        vb.views.compact_overwrite_sum.value = false
                        vb.views.compact_overwrite_replace.value = false
                        vb.views.compact_overwrite_substitute.value = false
                        vb.views.compact_overwrite_retain.value = false
                        vb.views.compact_overwrite_intersect.value = false
                    elseif behaviors.is_overwrite_exclude() then
                        vb.views.compact_overwrite_exclude.value = true
                    end
                end
            },
            vb:text { text = "E", width = 15 }
        },
        vb:row {
            spacing = 5,
            vb:checkbox {
                id = "compact_overwrite_intersect",
                value = behaviors.is_overwrite_intersect(),
                notifier = function(value)
                    if value then
                        behaviors.set_overwrite(overwrite.INTERSECT)
                        vb.views.compact_overwrite_sum.value = false
                        vb.views.compact_overwrite_replace.value = false
                        vb.views.compact_overwrite_substitute.value = false
                        vb.views.compact_overwrite_retain.value = false
                        vb.views.compact_overwrite_exclude.value = false
                    elseif behaviors.is_overwrite_intersect() then
                        vb.views.compact_overwrite_intersect.value = true
                    end
                end
            },
            vb:text { text = "I", width = 15 }
        }
    }
end

-- ============================================================================
-- Compact Instrument Source Section
-- ============================================================================

function behavior_panels.create_compact_instrument_source(vb)
    local inst_source = constants.instrument_source_behavior
    
    return vb:column {
        style = "group",
        margin = 5,
        width = 60,
        vb:text {
            text = "IS",
            font = "bold",
            style = "strong"
        },
        vb:space { height = 3 },
        vb:row {
            spacing = 5,
            vb:checkbox {
                id = "compact_instrument_source_embedded",
                value = behaviors.is_instrument_source_embedded(),
                notifier = function(value)
                    if value then
                        behaviors.set_instrument_source(inst_source.EMBEDDED)
                        vb.views.compact_instrument_source_current.value = false
                    elseif behaviors.is_instrument_source_embedded() then
                        vb.views.compact_instrument_source_embedded.value = true
                    end
                end
            },
            vb:text { text = "E", width = 15 }
        },
        vb:row {
            spacing = 5,
            vb:checkbox {
                id = "compact_instrument_source_current",
                value = behaviors.is_instrument_source_current(),
                notifier = function(value)
                    if value then
                        behaviors.set_instrument_source(inst_source.CURRENT_SELECTED)
                        vb.views.compact_instrument_source_embedded.value = false
                    elseif behaviors.is_instrument_source_current() then
                        vb.views.compact_instrument_source_current.value = true
                    end
                end
            },
            vb:text { text = "C", width = 15 }
        }
    }
end

-- ============================================================================
-- Compact Multi-Track Distance Section
-- ============================================================================

function behavior_panels.create_compact_multi_track_distance(vb)
    local mt_mode = constants.multi_track_distance_mode
    
    return vb:column {
        style = "group",
        margin = 5,
        width = 60,
        vb:text {
            text = "MT",
            font = "bold",
            style = "strong",
            tooltip = "Multi-Track Distance Mode"
        },
        vb:space { height = 3 },
        vb:row {
            spacing = 5,
            vb:checkbox {
                id = "compact_mt_sync_first",
                value = behaviors.is_multi_track_sync_first(),
                notifier = function(value)
                    if value then
                        behaviors.set_multi_track_distance_mode(mt_mode.SYNC_FIRST)
                        vb.views.compact_mt_independent.value = false
                        vb.views.compact_mt_sync_last.value = false
                    elseif behaviors.is_multi_track_sync_first() then
                        vb.views.compact_mt_sync_first.value = true
                    end
                end
            },
            vb:text { text = "1", width = 10, tooltip = "Sync to First" }
        },
        vb:row {
            spacing = 5,
            vb:checkbox {
                id = "compact_mt_independent",
                value = behaviors.is_multi_track_independent(),
                notifier = function(value)
                    if value then
                        behaviors.set_multi_track_distance_mode(mt_mode.INDEPENDENT)
                        vb.views.compact_mt_sync_first.value = false
                        vb.views.compact_mt_sync_last.value = false
                    elseif behaviors.is_multi_track_independent() then
                        vb.views.compact_mt_independent.value = true
                    end
                end
            },
            vb:text { text = "I", width = 10, tooltip = "Independent" }
        },
        vb:row {
            spacing = 5,
            vb:checkbox {
                id = "compact_mt_sync_last",
                value = behaviors.is_multi_track_sync_last(),
                notifier = function(value)
                    if value then
                        behaviors.set_multi_track_distance_mode(mt_mode.SYNC_LAST)
                        vb.views.compact_mt_sync_first.value = false
                        vb.views.compact_mt_independent.value = false
                    elseif behaviors.is_multi_track_sync_last() then
                        vb.views.compact_mt_sync_last.value = true
                    end
                end
            },
            vb:text { text = "L", width = 10, tooltip = "Sync to Last" }
        },
        vb:row {
            spacing = 5,
            vb:checkbox {
                id = "compact_mt_skip_blank",
                value = behaviors.get_ignore_blank_tracks(),
                notifier = function(value)
                    behaviors.set_ignore_blank_tracks(value)
                end
            },
            vb:text { text = "S", width = 10, tooltip = "Skip Blank Tracks at Capture" }
        }
    }
end

-- ============================================================================
-- Full Overflow Section
-- ============================================================================

function behavior_panels.create_full_overflow(vb)
    local overflow = constants.overflow_behavior
    
    return vb:column {
        style = "group",
        margin = 10,
        width = 210,
        vb:text {
            text = "Overflow Behavior",
            font = "big",
            style = "strong"
        },
        vb:space { height = 5 },
        vb:column {
            spacing = 3,
            vb:row {
                spacing = 10,
                vb:checkbox {
                    id = "overflow_extend",
                    value = behaviors.is_overflow_extend(),
                    notifier = function(value)
                        if value then
                            behaviors.set_overflow(overflow.EXTEND)
                            vb.views.overflow_next_pattern.value = false
                            vb.views.overflow_truncate.value = false
                            vb.views.overflow_loop.value = false
                            vb.views.overflow_insert.value = false
                        end
                    end
                },
                vb:text { text = "Extend Pattern", width = 120 }
            },
            vb:row {
                spacing = 10,
                vb:checkbox {
                    id = "overflow_next_pattern",
                    value = behaviors.is_overflow_next_pattern(),
                    notifier = function(value)
                        if value then
                            behaviors.set_overflow(overflow.NEXT_PATTERN)
                            vb.views.overflow_extend.value = false
                            vb.views.overflow_truncate.value = false
                            vb.views.overflow_loop.value = false
                            vb.views.overflow_insert.value = false
                        end
                    end
                },
                vb:text { text = "Next Pattern", width = 120 }
            },
            vb:row {
                spacing = 10,
                vb:checkbox {
                    id = "overflow_truncate",
                    value = behaviors.is_overflow_truncate(),
                    notifier = function(value)
                        if value then
                            behaviors.set_overflow(overflow.TRUNCATE)
                            vb.views.overflow_extend.value = false
                            vb.views.overflow_next_pattern.value = false
                            vb.views.overflow_loop.value = false
                            vb.views.overflow_insert.value = false
                        end
                    end
                },
                vb:text { text = "Truncate", width = 120 }
            },
            vb:row {
                spacing = 10,
                vb:checkbox {
                    id = "overflow_loop",
                    value = behaviors.is_overflow_loop(),
                    notifier = function(value)
                        if value then
                            behaviors.set_overflow(overflow.LOOP)
                            vb.views.overflow_extend.value = false
                            vb.views.overflow_next_pattern.value = false
                            vb.views.overflow_truncate.value = false
                            vb.views.overflow_insert.value = false
                        end
                    end
                },
                vb:text { text = "Loop", width = 120 }
            },
            vb:row {
                spacing = 10,
                vb:checkbox {
                    id = "overflow_insert",
                    value = behaviors.is_overflow_insert(),
                    notifier = function(value)
                        if value then
                            behaviors.set_overflow(overflow.INSERT)
                            vb.views.overflow_extend.value = false
                            vb.views.overflow_next_pattern.value = false
                            vb.views.overflow_truncate.value = false
                            vb.views.overflow_loop.value = false
                        end
                    end
                },
                vb:text { text = "Insert Pattern", width = 120 }
            }
        }
    }
end

-- ============================================================================
-- Full Overwrite Section
-- ============================================================================

function behavior_panels.create_full_overwrite(vb)
    local overwrite = constants.overwrite_behavior
    
    return vb:column {
        style = "group",
        margin = 10,
        width = 210,
        vb:text {
            text = "Overwrite Behavior",
            font = "big",
            style = "strong"
        },
        vb:space { height = 5 },
        vb:column {
            spacing = 3,
            vb:row {
                spacing = 10,
                vb:checkbox {
                    id = "overwrite_sum",
                    value = behaviors.is_overwrite_sum(),
                    notifier = function(value)
                        if value then
                            behaviors.set_overwrite(overwrite.SUM)
                            vb.views.overwrite_replace.value = false
                            vb.views.overwrite_substitute.value = false
                            vb.views.overwrite_retain.value = false
                            vb.views.overwrite_exclude.value = false
                            vb.views.overwrite_intersect.value = false
                        end
                    end
                },
                vb:text { text = "Sum (+)", width = 120 }
            },
            vb:row {
                spacing = 10,
                vb:checkbox {
                    id = "overwrite_replace",
                    value = behaviors.is_overwrite_replace(),
                    notifier = function(value)
                        if value then
                            behaviors.set_overwrite(overwrite.REPLACE)
                            vb.views.overwrite_sum.value = false
                            vb.views.overwrite_substitute.value = false
                            vb.views.overwrite_retain.value = false
                            vb.views.overwrite_exclude.value = false
                            vb.views.overwrite_intersect.value = false
                        end
                    end
                },
                vb:text { text = "Replace", width = 120 }
            },
            vb:row {
                spacing = 10,
                vb:checkbox {
                    id = "overwrite_substitute",
                    value = behaviors.is_overwrite_substitute(),
                    notifier = function(value)
                        if value then
                            behaviors.set_overwrite(overwrite.SUBSTITUTE)
                            vb.views.overwrite_sum.value = false
                            vb.views.overwrite_replace.value = false
                            vb.views.overwrite_retain.value = false
                            vb.views.overwrite_exclude.value = false
                            vb.views.overwrite_intersect.value = false
                        end
                    end
                },
                vb:text { text = "Substitute", width = 120 }
            },
            vb:row {
                spacing = 10,
                vb:checkbox {
                    id = "overwrite_retain",
                    value = behaviors.is_overwrite_retain(),
                    notifier = function(value)
                        if value then
                            behaviors.set_overwrite(overwrite.RETAIN)
                            vb.views.overwrite_sum.value = false
                            vb.views.overwrite_replace.value = false
                            vb.views.overwrite_substitute.value = false
                            vb.views.overwrite_exclude.value = false
                            vb.views.overwrite_intersect.value = false
                        end
                    end
                },
                vb:text { text = "Retain (Preserve)", width = 120 }
            },
            vb:row {
                spacing = 10,
                vb:checkbox {
                    id = "overwrite_exclude",
                    value = behaviors.is_overwrite_exclude(),
                    notifier = function(value)
                        if value then
                            behaviors.set_overwrite(overwrite.EXCLUDE)
                            vb.views.overwrite_sum.value = false
                            vb.views.overwrite_replace.value = false
                            vb.views.overwrite_substitute.value = false
                            vb.views.overwrite_retain.value = false
                            vb.views.overwrite_intersect.value = false
                        end
                    end
                },
                vb:text { text = "Exclude", width = 120 }
            },
            vb:row {
                spacing = 10,
                vb:checkbox {
                    id = "overwrite_intersect",
                    value = behaviors.is_overwrite_intersect(),
                    notifier = function(value)
                        if value then
                            behaviors.set_overwrite(overwrite.INTERSECT)
                            vb.views.overwrite_sum.value = false
                            vb.views.overwrite_replace.value = false
                            vb.views.overwrite_substitute.value = false
                            vb.views.overwrite_retain.value = false
                            vb.views.overwrite_exclude.value = false
                        end
                    end
                },
                vb:text { text = "Intersect", width = 120 }
            }
        }
    }
end

-- ============================================================================
-- Combined Compact Behaviors Row
-- ============================================================================

function behavior_panels.create_compact_behaviors_row(vb)
    return vb:row {
        id = "compact_behaviors_section",
        spacing = 5,
        behavior_panels.create_compact_overflow(vb),
        behavior_panels.create_compact_overwrite(vb),
        behavior_panels.create_compact_instrument_source(vb),
        behavior_panels.create_compact_multi_track_distance(vb)
    }
end

-- ============================================================================
-- Combined Full Behaviors Row
-- ============================================================================

function behavior_panels.create_full_behaviors_row(vb)
    return vb:row {
        id = "full_behaviors_section",
        spacing = 15,
        behavior_panels.create_full_overflow(vb),
        behavior_panels.create_full_overwrite(vb)
    }
end

return behavior_panels
