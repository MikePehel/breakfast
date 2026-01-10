-- ui/symbol_grid.lua - Symbol Grid and Pagination for BreakFast
local symbol_grid = {}

-- Dependencies
local constants = require("core/constants")
local state = require("core/state")
local registry = require("core/registry")
local colors = require("data/colors")
local dictionaries = require("data/dictionaries")
local tags_module = require("data/tags")

-- ============================================================================
-- Pagination State
-- ============================================================================

local pagination = {
    current_page = 1,
    symbols_per_page = 12,  -- 3x4 grid
    columns = 4,
    rows = 3
}

-- ============================================================================
-- Pagination Accessors
-- ============================================================================

function symbol_grid.get_current_page()
    return pagination.current_page
end

function symbol_grid.set_current_page(page)
    pagination.current_page = page
end

function symbol_grid.get_symbols_per_page()
    return pagination.symbols_per_page
end

function symbol_grid.get_total_pages()
    return math.ceil(#constants.available_symbols / pagination.symbols_per_page)
end

function symbol_grid.get_grid_dimensions()
    return pagination.columns, pagination.rows
end

-- ============================================================================
-- Pagination Navigation
-- ============================================================================

function symbol_grid.can_go_prev()
    return pagination.current_page > 1
end

function symbol_grid.can_go_next()
    return pagination.current_page < symbol_grid.get_total_pages()
end

function symbol_grid.go_prev()
    if symbol_grid.can_go_prev() then
        pagination.current_page = pagination.current_page - 1
        print("DEBUG: Going to page " .. pagination.current_page .. " of " .. symbol_grid.get_total_pages())
        return true
    end
    return false
end

function symbol_grid.go_next()
    if symbol_grid.can_go_next() then
        pagination.current_page = pagination.current_page + 1
        print("DEBUG: Going to page " .. pagination.current_page .. " of " .. symbol_grid.get_total_pages())
        return true
    end
    return false
end

function symbol_grid.reset_pagination()
    pagination.current_page = 1
end

-- ============================================================================
-- Symbol Retrieval
-- ============================================================================

-- Get only symbols that have data in the registry
function symbol_grid.get_mapped_symbols()
    local mapped = {}
    for _, symbol in ipairs(constants.available_symbols) do
        if registry.has_symbol(symbol) then
            table.insert(mapped, symbol)
        end
    end
    return mapped
end

-- Get symbols for the current page
-- Returns array of {symbol = string, dictionary = string or nil}
function symbol_grid.get_page_symbols(use_dictionary_order)
    local symbols_to_display
    
    if use_dictionary_order then
        symbols_to_display = dictionaries.get_symbols_ordered()
    else
        -- Standard alphabet order
        symbols_to_display = {}
        for _, s in ipairs(constants.available_symbols) do
            table.insert(symbols_to_display, {
                symbol = s,
                dictionary = dictionaries.get_for_symbol(s)
            })
        end
    end
    
    local start_index = (pagination.current_page - 1) * pagination.symbols_per_page + 1
    local end_index = math.min(start_index + pagination.symbols_per_page - 1, #symbols_to_display)
    
    local page_symbols = {}
    for i = start_index, end_index do
        table.insert(page_symbols, symbols_to_display[i])
    end
    
    return page_symbols
end

-- Get page info text (e.g., "Page 1 of 3")
function symbol_grid.get_page_info_text()
    return string.format("Page %d of %d", pagination.current_page, symbol_grid.get_total_pages())
end

-- ============================================================================
-- Width Calculations
-- ============================================================================

-- Calculate grid width based on active view modes
function symbol_grid.calculate_grid_width(view_modes, expanded_symbol)
    local base_grid_width = 500
    local width_padding = 0
    
    if view_modes.category then width_padding = width_padding + 15 end
    if view_modes.organize then width_padding = width_padding + 15 end
    if view_modes.detailed then width_padding = width_padding + 10 end
    if view_modes.label then width_padding = width_padding + 10 end
    
    local final_width = base_grid_width + (width_padding * pagination.columns)
    
    -- Extra container space for dictionary view
    if view_modes.dictionary then
        final_width = final_width + 40
    end
    
    -- Extra width for expanded symbol detail
    if view_modes.detailed and expanded_symbol then
        final_width = final_width + 80
    end
    
    return final_width
end

-- Calculate individual symbol column width
function symbol_grid.calculate_symbol_column_width(view_modes, is_expanded)
    local base_width = 120
    local width_padding = 0
    
    if view_modes.category then width_padding = width_padding + 15 end
    if view_modes.organize then width_padding = width_padding + 15 end
    if view_modes.detailed then width_padding = width_padding + 10 end
    if view_modes.label then width_padding = width_padding + 10 end
    
    local width = base_width + width_padding
    
    if is_expanded then
        width = width + 80
    end
    
    return width
end

-- Calculate compact grid width for collapsed view
function symbol_grid.calculate_compact_width()
    local mapped_symbols = symbol_grid.get_mapped_symbols()
    local button_width = 30
    local button_spacing = 3
    local buttons_per_row = math.min(4, #mapped_symbols > 0 and #mapped_symbols or 1)
    local calculated_width = (button_width * buttons_per_row) + (button_spacing * (buttons_per_row - 1)) + 40
    return math.max(calculated_width, 140)
end

-- ============================================================================
-- Compact Grid Creation
-- ============================================================================

-- Create compact symbol grid (for collapsed right column)
-- Parameters:
--   vb: ViewBuilder instance
--   callbacks: table with {on_symbol_click, on_preview_click}
--   symbol_button_refs: table to store button references
function symbol_grid.create_compact_grid(vb, callbacks, symbol_button_refs)
    local mapped_symbols = symbol_grid.get_mapped_symbols()
    
    local compact_content = vb:column {
        spacing = 5,
        
        vb:column {
            spacing = 3,
            vb:text {
                text = "Symbols (" .. #mapped_symbols .. ")",
                font = "bold",
                style = "strong",
                align = "center"
            },
            vb:space { height = 5 }
        }
    }
    
    if #mapped_symbols > 0 then
        local buttons_per_row = 4
        local current_row = nil
        local button_width = 30
        local button_spacing = 3
        
        for i, symbol in ipairs(mapped_symbols) do
            -- Start new row every 4 buttons
            if (i - 1) % buttons_per_row == 0 then
                current_row = vb:row {
                    spacing = button_spacing
                }
                compact_content:add_child(current_row)
            end
            
            -- Create column for color bar + button
            local symbol_col = vb:column {
                spacing = 0
            }
            
            -- Add dictionary color bar
            local symbol_dictionary = dictionaries.get_for_symbol(symbol)
            if symbol_dictionary then
                local dict_data = dictionaries.get(symbol_dictionary)
                local dict_color = dict_data and dict_data.color or ""
                
                if dict_color and dict_color ~= "" then
                    local bar_color = colors.get_original(dict_color)
                    if bar_color then
                        symbol_col:add_child(vb:canvas {
                            width = button_width,
                            height = 3,
                            mode = "plain",
                            render = function(ctx)
                                ctx.fill_color = bar_color
                                ctx:fill_rect(0, 0, ctx.size.width, ctx.size.height)
                            end
                        })
                    else
                        symbol_col:add_child(vb:space { height = 3 })
                    end
                else
                    symbol_col:add_child(vb:space { height = 3 })
                end
            else
                symbol_col:add_child(vb:space { height = 3 })
            end
            
            -- Create button
            local symbol_button = vb:button {
                text = symbol,
                width = button_width,
                height = 25,
                notifier = function()
                    if callbacks and callbacks.on_symbol_click then
                        callbacks.on_symbol_click(symbol)
                    end
                end
            }
            
            -- Store reference
            if symbol_button_refs then
                symbol_button_refs[symbol] = symbol_button
            end
            
            -- Apply color
            local symbol_color = registry.get_color(symbol)
            if symbol_color and symbol_color ~= "" then
                local darker = colors.get_darker(symbol_color)
                if darker then
                    symbol_button.color = darker
                end
            end
            
            symbol_col:add_child(symbol_button)
            current_row:add_child(symbol_col)
        end
    else
        compact_content:add_child(
            vb:text {
                text = "No symbols",
                style = "disabled",
                align = "center"
            }
        )
    end
    
    return compact_content
end

-- ============================================================================
-- Pagination Controls Creation
-- ============================================================================

-- Create pagination control row
-- Parameters:
--   vb: ViewBuilder instance
--   on_page_change: callback function called when page changes
function symbol_grid.create_pagination_controls(vb, on_page_change)
    return vb:row {
        spacing = 10,
        vb:button {
            id = "prev_page_btn",
            text = "<< Prev",
            width = 80,
            active = symbol_grid.can_go_prev(),
            notifier = function()
                if symbol_grid.go_prev() and on_page_change then
                    on_page_change()
                end
            end
        },
        vb:text {
            id = "page_info",
            text = symbol_grid.get_page_info_text(),
            width = 100,
            align = "center",
            font = "bold"
        },
        vb:button {
            id = "next_page_btn",
            text = "Next >>",
            width = 80,
            active = symbol_grid.can_go_next(),
            notifier = function()
                if symbol_grid.go_next() and on_page_change then
                    on_page_change()
                end
            end
        }
    }
end

-- ============================================================================
-- Symbol Button Creation Helpers
-- ============================================================================

-- Create a symbol button with preview
-- Parameters:
--   vb: ViewBuilder instance
--   symbol: symbol string
--   callbacks: {on_click, on_preview}
--   options: {show_preview, show_expand, show_label, is_expanded}
function symbol_grid.create_symbol_button_row(vb, symbol, callbacks, options)
    options = options or {}
    
    local elements = {}
    
    -- Main symbol button
    local symbol_button = vb:button {
        text = symbol,
        width = 35,
        height = 25,
        notifier = function()
            if callbacks and callbacks.on_click then
                callbacks.on_click(symbol)
            end
        end
    }
    table.insert(elements, symbol_button)
    
    -- Preview button
    if options.show_preview ~= false then
        table.insert(elements, vb:button {
            text = ">",
            width = 20,
            height = 25,
            tooltip = "Preview symbol " .. symbol,
            notifier = function()
                if callbacks and callbacks.on_preview then
                    callbacks.on_preview(symbol)
                end
            end
        })
    end
    
    -- Expand button (for detailed view)
    if options.show_expand then
        table.insert(elements, vb:button {
            text = options.is_expanded and "-" or "+",
            width = 20,
            height = 25,
            tooltip = "Expand/collapse details for " .. symbol,
            notifier = function()
                if callbacks and callbacks.on_expand then
                    callbacks.on_expand(symbol)
                end
            end
        })
    end
    
    -- Label button (for label view)
    if options.show_label then
        table.insert(elements, vb:button {
            text = "L",
            width = 20,
            height = 25,
            tooltip = "Edit labels and breakpoints for symbol " .. symbol,
            notifier = function()
                if callbacks and callbacks.on_label then
                    callbacks.on_label(symbol)
                end
            end
        })
    end
    
    return vb:row {
        spacing = 2,
        unpack(elements)
    }, symbol_button
end

-- ============================================================================
-- Dictionary Indicator Creation
-- ============================================================================

-- Create dictionary indicator for a symbol
function symbol_grid.create_dictionary_indicator(vb, symbol, width)
    local symbol_dictionary = dictionaries.get_for_symbol(symbol)
    local elements = vb:column { spacing = 0 }
    
    if symbol_dictionary then
        local dict_data = dictionaries.get(symbol_dictionary)
        local dict_color = dict_data and dict_data.color or ""
        
        -- Color bar
        if dict_color and dict_color ~= "" then
            local bar_color = colors.get_original(dict_color)
            if bar_color then
                elements:add_child(vb:canvas {
                    width = width - 6,
                    height = 4,
                    mode = "plain",
                    render = function(ctx)
                        ctx.fill_color = bar_color
                        ctx:fill_rect(0, 0, ctx.size.width, ctx.size.height)
                    end
                })
            else
                elements:add_child(vb:space { height = 4 })
            end
        else
            elements:add_child(vb:space { height = 4 })
        end
        
        -- Dictionary name
        local abbrev = symbol_dictionary:sub(1, 14)
        if #symbol_dictionary > 14 then abbrev = abbrev .. ".." end
        
        elements:add_child(vb:text {
            text = abbrev,
            style = "disabled",
            width = width - 6,
            align = "center"
        })
    else
        elements:add_child(vb:space { height = 4 })
        elements:add_child(vb:text {
            text = "(ungrouped)",
            style = "disabled",
            width = width - 6,
            align = "center"
        })
    end
    
    elements:add_child(vb:space { height = 2 })
    
    return elements
end

return symbol_grid
