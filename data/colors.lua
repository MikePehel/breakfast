-- data/colors.lua - Color definitions and utilities for BreakFast
local colors = {}

-- ============================================================================
-- Color Definitions
-- ============================================================================
-- RGB color values for symbol color coding
-- Using Matched Saturation Hex and 35% Darker OKHSL variants

colors.definitions = {
    [""] = {original = nil, darker = nil}, -- No color
    ["Green"] = {original = {0x9d, 0xeb, 0x6d}, darker = {0x40, 0x89, 0x00}},
    ["Pink"] = {original = {0xf5, 0x72, 0xb2}, darker = {0x9d, 0x1d, 0x66}},
    ["Purple"] = {original = {0xb5, 0x72, 0xf5}, darker = {0x6d, 0x24, 0xa5}},
    ["Blue"] = {original = {0x71, 0xb2, 0xf2}, darker = {0x1f, 0x62, 0x9c}},
    ["Yellow"] = {original = {0xdd, 0xdd, 0x67}, darker = {0x7e, 0x7c, 0x00}},
    ["Orange"] = {original = {0xef, 0xb0, 0x6f}, darker = {0x93, 0x5a, 0x10}},
    ["Red"] = {original = {0xf5, 0x72, 0x72}, darker = {0x9f, 0x20, 0x2b}}
}

-- Ordered list for dropdown/popup menus
colors.dropdown_items = {"", "Green", "Pink", "Purple", "Blue", "Yellow", "Orange", "Red"}

-- ============================================================================
-- Helper Functions
-- ============================================================================

-- Get the original (lighter) color RGB values for a color name
-- Returns nil if color name is empty or not found
function colors.get_original(color_name)
    local def = colors.definitions[color_name]
    if def then
        return def.original
    end
    return nil
end

-- Get the darker color RGB values for a color name
-- Returns nil if color name is empty or not found
function colors.get_darker(color_name)
    local def = colors.definitions[color_name]
    if def then
        return def.darker
    end
    return nil
end

-- Check if a color name is valid
function colors.is_valid(color_name)
    return colors.definitions[color_name] ~= nil
end

-- Get the index of a color in the dropdown list (1-based)
-- Returns 1 (empty/no color) if not found
function colors.get_dropdown_index(color_name)
    for i, name in ipairs(colors.dropdown_items) do
        if name == color_name then
            return i
        end
    end
    return 1 -- Default to first item (no color)
end

-- Get color name from dropdown index (1-based)
-- Returns empty string if index is out of range
function colors.get_name_from_index(index)
    return colors.dropdown_items[index] or ""
end

-- Get the number of available colors (including "no color")
function colors.count()
    return #colors.dropdown_items
end

return colors
