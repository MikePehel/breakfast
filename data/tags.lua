-- data/tags.lua - Tag and Color Editing State Management for BreakFast
local tags = {}

-- Dependencies
local registry = require("core/registry")
local colors = require("data/colors")

-- ============================================================================
-- Editing State Data
-- ============================================================================
-- Track which tags/colors are in "saved" (locked) vs "editing" (unlocked) state
-- This is UI state that doesn't persist - it's rebuilt from registry on load

-- Tag editing states: symbol -> {tag_index -> boolean (true=saved, false=editing)}
local tag_editing_states = {}

-- Color editing states: symbol -> boolean (true=saved, false=editing)
local color_editing_states = {}

-- ============================================================================
-- Tag Accessors (delegated to registry)
-- ============================================================================

-- Get tags for a symbol
function tags.get(symbol)
    return registry.get_tags(symbol)
end

-- Get tag count for a symbol (minimum 1 for UI)
function tags.get_count(symbol)
    local symbol_tags = registry.get_tags(symbol)
    return math.max(1, #symbol_tags)
end

-- Get a specific tag
function tags.get_tag(symbol, tag_index)
    local symbol_tags = registry.get_tags(symbol)
    return symbol_tags[tag_index] or ""
end

-- ============================================================================
-- Tag CRUD Operations
-- ============================================================================

-- Save a tag for a symbol
-- Returns: success (boolean)
function tags.save(symbol, tag_index, tag_text)
    if not registry.has_symbol(symbol) then
        print("DEBUG: Cannot save tag for symbol " .. symbol .. " - symbol not in registry")
        return false
    end
    
    -- Get current tags
    local symbol_tags = registry.get_tags(symbol)
    
    -- Ensure tags array exists and is large enough
    while #symbol_tags < tag_index do
        table.insert(symbol_tags, "")
    end
    
    -- Save or remove tag
    if tag_text and tag_text ~= "" then
        symbol_tags[tag_index] = tag_text
    else
        -- Remove empty tag
        if tag_index <= #symbol_tags then
            table.remove(symbol_tags, tag_index)
        end
    end
    
    -- Update registry
    registry.set_tags(symbol, symbol_tags)
    
    -- Update editing state
    local has_tag = tag_text and tag_text ~= ""
    if not tag_editing_states[symbol] then
        tag_editing_states[symbol] = {}
    end
    tag_editing_states[symbol][tag_index] = has_tag
    
    -- Persist
    registry.save()
    
    print("DEBUG: Saved tag " .. tag_index .. " '" .. (tag_text or "") .. "' for symbol " .. symbol)
    return true
end

-- Add a new tag input for a symbol
-- Returns: success (boolean), new_tag_index (number or nil)
function tags.add_input(symbol)
    local current_count = tags.get_count(symbol)
    if current_count >= 5 then
        return false, nil
    end
    
    local new_index = current_count + 1
    
    -- Initialize editing state for new tag
    if not tag_editing_states[symbol] then
        tag_editing_states[symbol] = {}
    end
    tag_editing_states[symbol][new_index] = false  -- Start in editing mode
    
    -- Add empty tag to registry
    local symbol_tags = registry.get_tags(symbol)
    table.insert(symbol_tags, "")
    registry.set_tags(symbol, symbol_tags)
    
    -- Persist
    registry.save()
    
    return true, new_index
end

-- Remove a tag input
-- Returns: success (boolean)
function tags.remove_input(symbol, tag_index)
    local current_count = tags.get_count(symbol)
    if current_count <= 1 then
        return false
    end
    
    -- Remove from registry
    local symbol_tags = registry.get_tags(symbol)
    if tag_index <= #symbol_tags then
        table.remove(symbol_tags, tag_index)
        registry.set_tags(symbol, symbol_tags)
    end
    
    -- Remove from editing states
    if tag_editing_states[symbol] and tag_editing_states[symbol][tag_index] then
        table.remove(tag_editing_states[symbol], tag_index)
    end
    
    -- Persist
    registry.save()
    
    return true
end

-- ============================================================================
-- Tag Editing State Management
-- ============================================================================

-- Check if a tag is in saved (locked) state
function tags.is_saved(symbol, tag_index)
    if tag_editing_states[symbol] then
        return tag_editing_states[symbol][tag_index] == true
    end
    return false
end

-- Set tag to editing (unlocked) state
function tags.unlock(symbol, tag_index)
    if not tag_editing_states[symbol] then
        tag_editing_states[symbol] = {}
    end
    tag_editing_states[symbol][tag_index] = false
    print("DEBUG: Unlocked tag " .. tag_index .. " editing for symbol " .. symbol)
end

-- Set tag to saved (locked) state
function tags.lock(symbol, tag_index)
    if not tag_editing_states[symbol] then
        tag_editing_states[symbol] = {}
    end
    tag_editing_states[symbol][tag_index] = true
end

-- Get all tag editing states for a symbol
function tags.get_editing_states(symbol)
    return tag_editing_states[symbol] or {}
end

-- Get the raw tag editing states table (for move operations)
function tags.get_all_tag_states()
    return tag_editing_states
end

-- Set tag editing states for a symbol (for move operations)
function tags.set_editing_states(symbol, states)
    tag_editing_states[symbol] = states
end

-- Clear tag editing states for a symbol
function tags.clear_editing_states(symbol)
    tag_editing_states[symbol] = nil
end

-- ============================================================================
-- Color Accessors (delegated to registry)
-- ============================================================================

-- Get color for a symbol
function tags.get_color(symbol)
    return registry.get_color(symbol)
end

-- ============================================================================
-- Color CRUD Operations
-- ============================================================================

-- Save color for a symbol
-- Returns: success (boolean)
function tags.save_color(symbol, color_name)
    if not registry.has_symbol(symbol) then
        print("DEBUG: Cannot save color for symbol " .. symbol .. " - symbol not in registry")
        return false
    end
    
    -- Save color to registry
    registry.set_color(symbol, color_name or "")
    
    -- Update editing state
    local has_color = color_name and color_name ~= ""
    color_editing_states[symbol] = has_color
    
    -- Persist
    registry.save()
    
    print("DEBUG: Saved color '" .. (color_name or "") .. "' for symbol " .. symbol)
    return true
end

-- ============================================================================
-- Color Editing State Management
-- ============================================================================

-- Check if color is in saved (locked) state
function tags.is_color_saved(symbol)
    return color_editing_states[symbol] == true
end

-- Set color to editing (unlocked) state
function tags.unlock_color(symbol)
    color_editing_states[symbol] = false
    print("DEBUG: Unlocked color editing for symbol " .. symbol)
end

-- Set color to saved (locked) state
function tags.lock_color(symbol)
    color_editing_states[symbol] = true
end

-- Get the raw color editing states table (for move operations)
function tags.get_all_color_states()
    return color_editing_states
end

-- Set color editing state for a symbol (for move operations)
function tags.set_color_state(symbol, state)
    color_editing_states[symbol] = state
end

-- Clear color editing state for a symbol
function tags.clear_color_state(symbol)
    color_editing_states[symbol] = nil
end

-- ============================================================================
-- Initialization
-- ============================================================================

-- Initialize all editing states from registry
-- Call this after loading the registry
function tags.initialize_editing_states()
    -- Initialize tag editing states
    tag_editing_states = {}
    
    registry.for_each(function(symbol, symbol_data)
        local symbol_tags = symbol_data.tags or {}
        tag_editing_states[symbol] = {}
        
        -- Initialize editing state for each tag
        for i, tag in ipairs(symbol_tags) do
            local has_tag = tag and tag ~= ""
            tag_editing_states[symbol][i] = has_tag  -- saved tags start locked
        end
        
        -- Ensure at least one tag input state exists
        if #symbol_tags == 0 then
            tag_editing_states[symbol][1] = false  -- empty tag in editing state
        end
    end)
    
    print("DEBUG: Initialized tag editing states for " .. table.count(tag_editing_states) .. " symbols")
    
    -- Initialize color editing states
    tags.initialize_color_states()
end

-- Initialize color editing states from registry
function tags.initialize_color_states()
    color_editing_states = {}
    
    registry.for_each(function(symbol, symbol_data)
        local has_color = symbol_data.color and symbol_data.color ~= ""
        color_editing_states[symbol] = has_color  -- saved colors start locked
    end)
    
    print("DEBUG: Initialized color editing states for " .. table.count(color_editing_states) .. " symbols")
end

-- ============================================================================
-- Clear All
-- ============================================================================

-- Clear all editing states (used when clearing all symbols)
function tags.clear_all_states()
    tag_editing_states = {}
    color_editing_states = {}
end

-- ============================================================================
-- UI Helper Functions
-- ============================================================================
-- Note: These functions help with UI updates but don't directly manipulate UI
-- The actual UI manipulation should be done by the calling code

-- Get the display text for a tag (for locked display)
function tags.get_display_text(symbol, tag_index)
    local symbol_tags = registry.get_tags(symbol)
    return symbol_tags[tag_index] or ""
end

-- Check if add button should be active
function tags.can_add_tag(symbol)
    return tags.get_count(symbol) < 5
end

-- Check if remove button should be active
function tags.can_remove_tag(symbol)
    return tags.get_count(symbol) > 1
end

-- Get color dropdown index for a symbol
function tags.get_color_dropdown_index(symbol)
    local color_name = registry.get_color(symbol)
    return colors.get_dropdown_index(color_name or "")
end

return tags
