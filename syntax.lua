-- syntax.lua - Break String Parsing and Symbol Formatting
local syntax = {}

-- Helper function to pad strings with underscores
local function pad_with_underscores(str, length)
    if #str >= length then
        return str:sub(1, length)
    end
    return str .. string.rep("_", length - #str)
end

-- CSV helper functions
local function escape_csv_field(field)
    if type(field) == "string" and (field:find(',') or field:find('"')) then
        return '"' .. field:gsub('"', '""') .. '"'
    end
    return tostring(field)
end

local function unescape_csv_field(field)
    if field:sub(1,1) == '"' and field:sub(-1) == '"' then
        return field:sub(2, -2):gsub('""', '"')
    end
    return field
end

local function parse_csv_line(line)
    local fields = {}
    local field = ""
    local in_quotes = false
    
    local i = 1
    while i <= #line do
        local char = line:sub(i,i)
        
        if char == '"' then
            if in_quotes and line:sub(i+1,i+1) == '"' then
                field = field .. '"'
                i = i + 2
            else
                in_quotes = not in_quotes
                i = i + 1
            end
        elseif char == ',' and not in_quotes then
            table.insert(fields, field)
            field = ""
            i = i + 1
        else
            field = field .. char
            i = i + 1
        end
    end
    
    table.insert(fields, field)
    return fields
end

-- Format a single break label with instrument information
function syntax.format_break_label(note, label, source_instrument_index)
    -- Ensure we have a valid instrument index (fallback to 1 if not provided)
    local actual_instrument_index = source_instrument_index or 1
    local instrument_index = actual_instrument_index - 1  -- Convert to 0-based for display
    
    local line_str = string.format("%02d", note.line)
    local padded_label = pad_with_underscores(label or "", 5)
    local delay_str = string.format("d%02X", note.delay_value or 0)
    local instrument_str = string.format("I%02X", instrument_index)
    
    return string.format("%s-%s-%s-%s", line_str, padded_label, delay_str, instrument_str)
end

-- Parse break string into permutation array
function syntax.parse_break_string(break_string, num_sets, composite_symbols)
    if not break_string or break_string == "" then
        return nil, "Break string cannot be empty"
    end

    local permutation = {}
    local valid_symbols = {}
    local symbol_list = {"A", "B", "C", "D", "E"}
    
    -- Build valid symbols map
    for i = 1, num_sets do
        valid_symbols[symbol_list[i]] = i
    end
    
    -- Clean input string
    break_string = break_string:upper():gsub("%s+", "")
    
    -- First validate composite symbols if present
    if composite_symbols then
        for symbol, value in pairs(composite_symbols) do
            if value and value ~= "" and not syntax.validate_composite_symbol(value, valid_symbols) then
                return nil, string.format("Invalid composite symbol '%s': value '%s' contains invalid base symbols", 
                    symbol, value)
            end
        end
    end
    
    -- Resolve composite symbols if present
    local resolved_string = syntax.resolve_break_string(break_string, composite_symbols)
    if not resolved_string then
        return nil, "Failed to resolve break string"
    end
    
    -- Process resolved string
    for i = 1, #resolved_string do
        local symbol = resolved_string:sub(i, i)
        local set_index = valid_symbols[symbol]
        
        if not set_index then
            local valid_chars = table.concat(symbol_list, ", ", 1, num_sets)
            return nil, string.format("Invalid symbol '%s'. Valid symbols are: %s", 
                symbol, valid_chars)
        end
        
        table.insert(permutation, set_index)
    end
    
    return permutation
end

-- Resolve composite symbols in break string
function syntax.resolve_break_string(break_string, composite_symbols)
    if not break_string or break_string == "" then
        return break_string, "Break string cannot be empty"
    end

    local result = ""
    for char in break_string:gmatch(".") do
        if composite_symbols and composite_symbols[char] and composite_symbols[char] ~= "" then
            result = result .. composite_symbols[char]
        else
            result = result .. char
        end
    end
    
    return result
end

-- Validate composite symbol contains only valid base symbols
function syntax.validate_composite_symbol(symbol_str, valid_symbols)
    if not symbol_str or symbol_str == "" then
        return true
    end
    
    for char in symbol_str:gmatch(".") do
        if not valid_symbols[char] then
            return false
        end
    end
    
    return true
end

-- Prepare formatted labels for symbol editor
function syntax.prepare_symbol_labels(sets, saved_labels)
    local symbol_labels = {}
    local symbols = {"A", "B", "C", "D", "E"}
    
    for i = 1, math.min(#sets, #symbols) do
        local set = sets[i]
        if set and #set.notes > 0 then
            symbol_labels[symbols[i]] = {}
            
            for _, note in ipairs(set.notes) do
                local hex_key = string.format("%02X", note.instrument_value + 1)
                local label = saved_labels[hex_key] and saved_labels[hex_key].label or ""
                -- Get source instrument index from the first timing entry of this set
                local source_instrument_index = set.timing and set.timing[1] and set.timing[1].source_instrument_index or 1
                table.insert(symbol_labels[symbols[i]], syntax.format_break_label(note, label, source_instrument_index))
            end
        end
    end
    
    return symbol_labels
end

-- Prepare formatted labels from global symbol registry
function syntax.prepare_global_symbol_labels(global_registry)
    local symbol_labels = {}
    
    for symbol, symbol_data in pairs(global_registry) do
        if symbol_data.break_set and symbol_data.break_set.notes and #symbol_data.break_set.notes > 0 then
            symbol_labels[symbol] = {}
            
            -- Check if this is a range-captured symbol (different formatting logic)
            if symbol_data.symbol_type == "range_captured" then
                -- For range symbols, use timing data to get the correct instrument values
                for i, note in ipairs(symbol_data.break_set.notes) do
                    local timing = symbol_data.break_set.timing[i]
                    if timing then
                        local hex_key = string.format("%02X", note.instrument_value + 1)
                        local label = "" -- Range symbols don't have slice labels
                        
                        -- Use the source_instrument_index from timing data for accurate display
                        local source_instrument_index = timing.source_instrument_index
                        table.insert(symbol_labels[symbol], syntax.format_break_label(note, label, source_instrument_index))
                    end
                end
            else
                -- Original logic for breakpoint symbols
                for _, note in ipairs(symbol_data.break_set.notes) do
                    local hex_key = string.format("%02X", note.instrument_value + 1)
                    local label = ""
                    
                    -- Get label from saved_labels in the symbol data
                    if symbol_data.saved_labels and symbol_data.saved_labels[hex_key] then
                        label = symbol_data.saved_labels[hex_key].label or ""
                    end
                    
                    -- Use the instrument index from the symbol data
                    local source_instrument_index = symbol_data.instrument_index
                    table.insert(symbol_labels[symbol], syntax.format_break_label(note, label, source_instrument_index))
                end
            end
        end
    end
    
    return symbol_labels
end

-- Export break syntax to CSV
function syntax.export_syntax(dialog_vb)
    local break_string = dialog_vb.views.break_string.text or ""
    
    -- Collect composite symbols from dialog
    local composite_symbols = {}
    local symbols = {"U", "V", "W", "X", "Y", "Z"}
    
    for _, symbol in ipairs(symbols) do
        local symbol_view = dialog_vb.views["symbol_" .. string.lower(symbol)]
        if symbol_view then
            composite_symbols[symbol] = symbol_view.text or ""
        else
            composite_symbols[symbol] = ""
        end
    end
    
    local filepath = renoise.app():prompt_for_filename_to_write("csv", "Export Break Syntax")
    if not filepath or filepath == "" then return end
    
    if not filepath:lower():match("%.csv$") then
        filepath = filepath .. ".csv"
    end
    
    local file, err = io.open(filepath, "w")
    if not file then
        renoise.app():show_error("Unable to open file for writing: " .. tostring(err))
        return
    end
    
    -- Write header
    file:write("Break String,U,V,W,X,Y,Z\n")
    
    -- Write data row
    local values = {
        break_string,
        composite_symbols["U"],
        composite_symbols["V"], 
        composite_symbols["W"],
        composite_symbols["X"],
        composite_symbols["Y"],
        composite_symbols["Z"]
    }
    
    -- Escape each field
    for i, value in ipairs(values) do
        values[i] = escape_csv_field(value)
    end
    
    file:write(table.concat(values, ",") .. "\n")
    file:close()
    
    renoise.app():show_status("Break syntax exported to " .. filepath)
end

-- Import break syntax from CSV
function syntax.import_syntax(dialog_vb)
    local filepath = renoise.app():prompt_for_filename_to_read({"*.csv"}, "Import Break Syntax")
    
    if not filepath or filepath == "" then return end
    
    local file, err = io.open(filepath, "r")
    if not file then
        renoise.app():show_error("Unable to open file: " .. tostring(err))
        return
    end
    
    -- Read and verify header
    local header = file:read()
    if not header or not header:lower():match("break string,u,v,w,x,y,z") then
        renoise.app():show_error("Invalid CSV format: Missing or incorrect header")
        file:close()
        return
    end

    -- Read the data line
    local data_line = file:read()
    if not data_line then
        renoise.app():show_error("No data found in file")
        file:close()
        return
    end

    -- Parse the CSV line
    local fields = parse_csv_line(data_line)
    if #fields ~= 7 then
        renoise.app():show_error(string.format(
            "Invalid CSV format: Expected 7 fields, got %d", #fields))
        file:close()
        return
    end

    -- Update dialog with imported data
    local break_string_view = dialog_vb.views.break_string
    if break_string_view then
        break_string_view.text = unescape_csv_field(fields[1])
    end

    -- Update composite symbol fields and create them if they don't exist
    local symbols = {"U", "V", "W", "X", "Y", "Z"}
    for i, symbol in ipairs(symbols) do
        local view_id = "symbol_" .. string.lower(symbol)
        local symbol_view = dialog_vb.views[view_id]
        
        -- If the view doesn't exist, we need to create it by calling add_composite_symbol
        if not symbol_view and fields[i + 1] and fields[i + 1] ~= "" then
            -- Call the main dialog's add function (we need to pass this somehow)
            -- For now, we'll just show a message that the user needs to add symbols manually
            if i == 1 then -- Only show once
                renoise.app():show_message("Some composite symbols were found in the import file. Please add composite symbols manually and re-import.")
            end
        elseif symbol_view then
            symbol_view.text = unescape_csv_field(fields[i + 1])
        end
    end
    
    file:close()
    renoise.app():show_status("Break syntax imported from " .. filepath)
end

return syntax