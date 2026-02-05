-- features/export.lua - Export/Import Functionality for BreakFast
local export = {}

-- Dependencies
local registry = require("core/registry")
local dictionaries = require("data/dictionaries")
local json = require("json")

-- ============================================================================
-- CSV Header Definition
-- ============================================================================

local CSV_HEADER = "Symbol,Dictionary,DictionaryKey,Key,SymbolType,Tags,Color,InstrumentIndex,SliceIndex,SliceLabel,IsBreakpoint,TimingLine,TimingDelay,OriginalLine,OriginalDelay,OriginalDistance,TimingBreakpoint,NoteValue,VolumeValue,PanningValue,EffectNumber,EffectAmount,HasNote,ContentType,EffectColumn1Number,EffectColumn1Amount,EffectColumn2Number,EffectColumn2Amount,EffectColumn3Number,EffectColumn3Amount,EffectColumn4Number,EffectColumn4Amount,EffectColumn5Number,EffectColumn5Amount,EffectColumn6Number,EffectColumn6Amount,EffectColumn7Number,EffectColumn7Amount,EffectColumn8Number,EffectColumn8Amount,NoteColumn1Note,NoteColumn1Instrument,NoteColumn1Volume,NoteColumn1Panning,NoteColumn1Delay,NoteColumn1EffectNumber,NoteColumn1EffectAmount,NoteColumn2Note,NoteColumn2Instrument,NoteColumn2Volume,NoteColumn2Panning,NoteColumn2Delay,NoteColumn2EffectNumber,NoteColumn2EffectAmount,NoteColumn3Note,NoteColumn3Instrument,NoteColumn3Volume,NoteColumn3Panning,NoteColumn3Delay,NoteColumn3EffectNumber,NoteColumn3EffectAmount,NoteColumn4Note,NoteColumn4Instrument,NoteColumn4Volume,NoteColumn4Panning,NoteColumn4Delay,NoteColumn4EffectNumber,NoteColumn4EffectAmount,NoteColumn5Note,NoteColumn5Instrument,NoteColumn5Volume,NoteColumn5Panning,NoteColumn5Delay,NoteColumn5EffectNumber,NoteColumn5EffectAmount,NoteColumn6Note,NoteColumn6Instrument,NoteColumn6Volume,NoteColumn6Panning,NoteColumn6Delay,NoteColumn6EffectNumber,NoteColumn6EffectAmount,NoteColumn7Note,NoteColumn7Instrument,NoteColumn7Volume,NoteColumn7Panning,NoteColumn7Delay,NoteColumn7EffectNumber,NoteColumn7EffectAmount,NoteColumn8Note,NoteColumn8Instrument,NoteColumn8Volume,NoteColumn8Panning,NoteColumn8Delay,NoteColumn8EffectNumber,NoteColumn8EffectAmount,NoteColumn9Note,NoteColumn9Instrument,NoteColumn9Volume,NoteColumn9Panning,NoteColumn9Delay,NoteColumn9EffectNumber,NoteColumn9EffectAmount,NoteColumn10Note,NoteColumn10Instrument,NoteColumn10Volume,NoteColumn10Panning,NoteColumn10Delay,NoteColumn10EffectNumber,NoteColumn10EffectAmount,NoteColumn11Note,NoteColumn11Instrument,NoteColumn11Volume,NoteColumn11Panning,NoteColumn11Delay,NoteColumn11EffectNumber,NoteColumn11EffectAmount,NoteColumn12Note,NoteColumn12Instrument,NoteColumn12Volume,NoteColumn12Panning,NoteColumn12Delay,NoteColumn12EffectNumber,NoteColumn12EffectAmount,SourcePattern,SourceTrack,CaptureStartLine,CaptureEndLine"

-- ============================================================================
-- Helper Functions
-- ============================================================================

-- Escape a CSV field (handle commas and quotes)
local function escape_csv_field(field)
    local str_field = tostring(field or "")
    if str_field:find(',') or str_field:find('"') then
        return '"' .. str_field:gsub('"', '""') .. '"'
    end
    return str_field
end

-- Ensure file has correct extension
local function ensure_extension(filepath, ext)
    if not filepath:lower():match("%." .. ext .. "$") then
        return filepath .. "." .. ext
    end
    return filepath
end

-- Extract effect columns data from timing
local function extract_effect_columns(timing)
    local data = {}
    if timing.effect_columns then
        for fx_col = 1, 8 do
            if timing.effect_columns[fx_col] then
                table.insert(data, timing.effect_columns[fx_col].number_value or "")
                table.insert(data, timing.effect_columns[fx_col].amount_value or "")
            else
                table.insert(data, "")
                table.insert(data, "")
            end
        end
    else
        for _ = 1, 16 do
            table.insert(data, "")
        end
    end
    return data
end

-- Extract note columns data from timing
local function extract_note_columns(timing)
    local data = {}
    if timing.note_columns then
        for note_col = 1, 12 do
            if timing.note_columns[note_col] then
                local col = timing.note_columns[note_col]
                table.insert(data, col.note_value or "")
                table.insert(data, col.instrument_value or "")
                table.insert(data, col.volume_value or "")
                table.insert(data, col.panning_value or "")
                table.insert(data, col.delay_value or "")
                table.insert(data, col.effect_number_value or "")
                table.insert(data, col.effect_amount_value or "")
            else
                for _ = 1, 7 do
                    table.insert(data, "")
                end
            end
        end
    else
        for _ = 1, 84 do
            table.insert(data, "")
        end
    end
    return data
end

-- ============================================================================
-- CSV Export
-- ============================================================================

function export.to_csv(filepath)
    if not filepath then
        filepath = renoise.app():prompt_for_filename_to_write("csv", "Export Global Alphabet (CSV)")
        if not filepath or filepath == "" then return false end
    end
    
    filepath = ensure_extension(filepath, "csv")
    
    local file, err = io.open(filepath, "w")
    if not file then
        renoise.app():show_error("Unable to open file for writing: " .. tostring(err))
        return false
    end
    
    -- Write header
    file:write(CSV_HEADER .. "\n")
    
    -- Get all symbols from registry
    local global_registry = registry.get()
    
    -- Write data for each symbol
    for symbol, symbol_data in pairs(global_registry) do
        local instrument_index = symbol_data.instrument_index or 1
        local break_set = symbol_data.break_set
        local saved_labels = symbol_data.saved_labels or {}
        local symbol_type = symbol_data.symbol_type or "breakpoint_created"
        local symbol_color = symbol_data.color or ""
        local symbol_tags = symbol_data.tags or {}
        local symbol_dictionary = dictionaries.get_for_symbol(symbol) or ""
        local raw_symbol_key = symbol_data.key -- Symbol's root note (MIDI 0-119 or nil)
        
        -- Get dictionary key if symbol belongs to a dictionary
        -- Default to C-4 (MIDI 48) if dictionary exists but has no key set
        local dictionary_key = nil
        local dictionary_key_export = ""
        if symbol_dictionary ~= "" then
            dictionary_key = dictionaries.get_key(symbol_dictionary)
            -- If dictionary has a key, use it; otherwise default to C-4 (48)
            dictionary_key_export = dictionary_key or 48
        end
        
        -- Determine symbol key export value:
        -- - If symbol has its own key: export that key
        -- - If symbol belongs to dictionary but has no key: export "inherited"
        -- - If symbol has no dictionary and no key: export "nil"
        local symbol_key_export
        if raw_symbol_key ~= nil then
            symbol_key_export = raw_symbol_key
        elseif symbol_dictionary ~= "" then
            symbol_key_export = "inherited"
        else
            symbol_key_export = "nil"
        end
        
        -- Convert tags to string
        local tags_string = #symbol_tags > 0 and table.concat(symbol_tags, ", ") or ""
        
        -- Extract source metadata
        local source_pattern = ""
        local source_track = ""
        local capture_start_line = ""
        local capture_end_line = ""
        
        if symbol_type == "range_captured" and symbol_data.source_metadata then
            source_pattern = tostring(symbol_data.source_metadata.pattern_index or "")
            source_track = tostring(symbol_data.source_metadata.track_index or "")
            if symbol_data.source_metadata.capture_info then
                capture_start_line = tostring(symbol_data.source_metadata.capture_info.start_line or "")
                capture_end_line = tostring(symbol_data.source_metadata.capture_info.end_line or "")
            end
        end
        
        if break_set and break_set.timing then
            for _, timing in ipairs(break_set.timing) do
                local slice_index = timing.instrument_value or 0
                local note_value = timing.note_value or ""
                
                -- Calculate hex_key for label lookup
                local hex_key
                if symbol_type == "range_captured" then
                    local calculated_slice = note_value >= 37 and (note_value - 36) or 0
                    hex_key = string.format("%02X", calculated_slice + 1)
                else
                    hex_key = string.format("%02X", slice_index + 1)
                end
                
                local label_data = saved_labels[hex_key] or {}
                local slice_label = label_data.label or ""
                local is_breakpoint = label_data.breakpoint or false
                
                -- For range-captured symbols, use actual instrument value
                local actual_instrument_value = slice_index
                if symbol_type == "range_captured" and timing.source_instrument_index then
                    actual_instrument_value = timing.source_instrument_index - 1
                end
                
                -- Extract column data
                local effect_columns_data = extract_effect_columns(timing)
                local note_columns_data = extract_note_columns(timing)
                
                -- Build values array (order matches CSV_HEADER)
                local values = {
                    symbol or "",
                    symbol_dictionary or "",
                    dictionary_key_export or "",  -- DictionaryKey (defaults to 48/C-4 if dict exists but no key)
                    symbol_key_export or "",      -- Key (symbol's root note, "inherited", or "nil")
                    symbol_type or "",
                    tags_string or "",
                    symbol_color or "",
                    instrument_index or "",
                    actual_instrument_value or "",
                    slice_label or "",
                    tostring(is_breakpoint),
                    timing.relative_line or "",
                    timing.new_delay or "",
                    timing.original_line or "",
                    timing.original_delay or "",
                    timing.original_distance or "",
                    tostring(timing.breakpoint or false),
                    note_value or "",
                    timing.volume_value or "",
                    timing.panning_value or "",
                    timing.effect_number_value or "",
                    timing.effect_amount_value or "",
                    tostring(timing.has_note or false),
                    timing.content_type or ""
                }
                
                -- Add effect columns
                for _, fx_data in ipairs(effect_columns_data) do
                    table.insert(values, fx_data)
                end
                
                -- Add note columns
                for _, note_data in ipairs(note_columns_data) do
                    table.insert(values, note_data)
                end
                
                -- Add source metadata
                table.insert(values, source_pattern)
                table.insert(values, source_track)
                table.insert(values, capture_start_line)
                table.insert(values, capture_end_line)
                
                -- Escape all values
                for i, value in ipairs(values) do
                    values[i] = escape_csv_field(value)
                end
                
                file:write(table.concat(values, ",") .. "\n")
            end
        end
    end
    
    file:close()
    renoise.app():show_status("Global alphabet exported to " .. filepath)
    return true
end

-- ============================================================================
-- JSON Export
-- ============================================================================

function export.to_json(filepath)
    if not filepath then
        filepath = renoise.app():prompt_for_filename_to_write("json", "Export Global Alphabet (JSON)")
        if not filepath or filepath == "" then return false end
    end
    
    filepath = ensure_extension(filepath, "json")
    
    local file, err = io.open(filepath, "w")
    if not file then
        renoise.app():show_error("Unable to open file for writing: " .. tostring(err))
        return false
    end
    
    -- Build export structure
    local export_data = {
        version = "2.1",  -- Bumped version for key support
        dictionaries = {},
        symbols = {}
    }
    
    -- Export dictionaries with their keys
    -- Default to C-4 (MIDI 48) if dictionary has no key set
    local all_dictionaries = dictionaries.get_all()
    for dict_name, dict_data in pairs(all_dictionaries) do
        export_data.dictionaries[dict_name] = {
            name = dict_data.name,
            color = dict_data.color or "",
            symbols = dict_data.symbols or {},
            created_at = dict_data.created_at,
            description = dict_data.description or "",
            key = dict_data.key or 48  -- Dictionary key center (defaults to C-4/48 if not set)
        }
    end
    
    local global_registry = registry.get()
    
    for symbol, symbol_data in pairs(global_registry) do
        local instrument_index = symbol_data.instrument_index or 1
        local break_set = symbol_data.break_set
        local saved_labels = symbol_data.saved_labels or {}
        local symbol_type = symbol_data.symbol_type or "breakpoint_created"
        local symbol_dictionary = dictionaries.get_for_symbol(symbol) or ""
        local raw_symbol_key = symbol_data.key
        
        -- Determine symbol key export value:
        -- - If symbol has its own key: export that key (number)
        -- - If symbol belongs to dictionary but has no key: export "inherited" (string)
        -- - If symbol has no dictionary and no key: export json.null (nil)
        local symbol_key_export
        if raw_symbol_key ~= nil then
            symbol_key_export = raw_symbol_key
        elseif symbol_dictionary ~= "" then
            symbol_key_export = "inherited"
        else
            symbol_key_export = nil  -- Will be encoded as null in JSON
        end
        
        local symbol_entry = {
            symbol_type = symbol_type,
            instrument_index = instrument_index,
            tags = symbol_data.tags or {},
            color = symbol_data.color or "",
            dictionary = symbol_dictionary,
            key = symbol_key_export,  -- Symbol root note (number), "inherited" (string), or null
            timing_data = {},  -- Original field name for WaveBreak compatibility
            source_metadata = symbol_data.source_metadata
        }
        
        if break_set and break_set.timing then
            for _, timing in ipairs(break_set.timing) do
                local slice_index = timing.instrument_value or 0
                local note_value = timing.note_value or ""
                
                local hex_key
                if symbol_type == "range_captured" then
                    local calculated_slice = note_value >= 37 and (note_value - 36) or 0
                    hex_key = string.format("%02X", calculated_slice + 1)
                else
                    hex_key = string.format("%02X", slice_index + 1)
                end
                
                local label_data = saved_labels[hex_key] or {}
                
                local timing_entry = {
                    slice_index = slice_index,
                    slice_label = label_data.label or "",
                    is_breakpoint = label_data.breakpoint or false,
                    relative_line = timing.relative_line,  -- Original field name
                    new_delay = timing.new_delay,          -- Original field name
                    original_line = timing.original_line,
                    original_delay = timing.original_delay,
                    original_distance = timing.original_distance,
                    timing_breakpoint = timing.breakpoint or false,
                    note_value = note_value,
                    volume_value = timing.volume_value,
                    panning_value = timing.panning_value,
                    effect_number = timing.effect_number_value,
                    effect_amount = timing.effect_amount_value,
                    has_note = timing.has_note or false,
                    content_type = timing.content_type or ""
                }
                
                -- Include source_instrument_index for range-captured
                if timing.source_instrument_index then
                    timing_entry.source_instrument_index = timing.source_instrument_index
                end
                
                -- Include effect columns
                if timing.effect_columns then
                    timing_entry.effect_columns = timing.effect_columns
                end
                
                -- Include note columns
                if timing.note_columns then
                    timing_entry.note_columns = timing.note_columns
                end
                
                table.insert(symbol_entry.timing_data, timing_entry)
            end
        end
        
        export_data.symbols[symbol] = symbol_entry
    end
    
    -- Write JSON
    local json_string = json.encode(export_data)
    file:write(json_string)
    file:close()
    
    renoise.app():show_status("Global alphabet exported to " .. filepath)
    return true
end

-- ============================================================================
-- Prompt-Based Export (for menu items)
-- ============================================================================

function export.prompt_csv()
    export.to_csv(nil)
end

function export.prompt_json()
    export.to_json(nil)
end

-- ============================================================================
-- Import Placeholder
-- ============================================================================
-- Note: Full import functionality would require parsing and reconstructing
-- symbol data, which is complex. This provides a foundation.

function export.from_json(filepath)
    if not filepath then
        filepath = renoise.app():prompt_for_filename_to_read({"*.json"}, "Import Global Alphabet (JSON)")
        if not filepath or filepath == "" then return false end
    end
    
    local file, err = io.open(filepath, "r")
    if not file then
        renoise.app():show_error("Unable to open file for reading: " .. tostring(err))
        return false
    end
    
    local content = file:read("*all")
    file:close()
    
    local success, import_data = pcall(json.decode, content)
    if not success or not import_data then
        renoise.app():show_error("Failed to parse JSON file")
        return false
    end
    
    -- Version check (2.0 and 2.1 are compatible, 2.1 adds key support)
    if import_data.version ~= "2.0" and import_data.version ~= "2.1" then
        renoise.app():show_warning("Warning: JSON version mismatch. Import may not be complete.")
    end
    
    -- Import dictionaries first (if present in 2.1+ format)
    if import_data.dictionaries then
        for dict_name, dict_data in pairs(import_data.dictionaries) do
            if not dictionaries.exists(dict_name) then
                -- Create dictionary with key if provided
                dictionaries.create(
                    dict_name,
                    dict_data.color or "",
                    dict_data.description or "",
                    dict_data.key  -- May be nil
                )
            else
                -- Update existing dictionary's key if provided
                if dict_data.key then
                    dictionaries.set_key(dict_name, dict_data.key)
                end
            end
        end
    end
    
    -- Import symbols
    if import_data.symbols then
        local imported_count = 0
        for symbol, symbol_entry in pairs(import_data.symbols) do
            -- Handle symbol key:
            -- - Number (0-119): explicit key
            -- - "inherited": symbol inherits from dictionary (store as nil internally)
            -- - nil/null: no key
            local symbol_key = symbol_entry.key
            if symbol_key == "inherited" then
                symbol_key = nil  -- "inherited" means no explicit key, will inherit from dictionary
            elseif type(symbol_key) == "number" then
                if symbol_key < 0 or symbol_key > 119 then
                    symbol_key = nil
                end
            else
                symbol_key = nil
            end
            
            -- Reconstruct symbol data
            local symbol_data = {
                instrument_index = symbol_entry.instrument_index,
                symbol_type = symbol_entry.symbol_type,
                tags = symbol_entry.tags or {},
                color = symbol_entry.color or "",
                key = symbol_key,  -- Symbol root note (nil if inherited or not set)
                saved_labels = {},
                source_metadata = symbol_entry.source_metadata
            }
            
            -- Reconstruct break_set from timing_data (original) or notes (v2.1 legacy)
            local timing_source = symbol_entry.timing_data or symbol_entry.notes
            if timing_source and #timing_source > 0 then
                local timing = {}
                for _, entry in ipairs(timing_source) do
                    local timing_entry = {
                        instrument_value = entry.slice_index,
                        -- Support both original and v2.1 field names
                        relative_line = entry.relative_line or entry.timing_line,
                        new_delay = entry.new_delay or entry.timing_delay,
                        original_line = entry.original_line,
                        original_delay = entry.original_delay,
                        original_distance = entry.original_distance,
                        breakpoint = entry.timing_breakpoint,
                        note_value = entry.note_value,
                        volume_value = entry.volume_value,
                        panning_value = entry.panning_value,
                        effect_number_value = entry.effect_number,
                        effect_amount_value = entry.effect_amount,
                        has_note = entry.has_note,
                        content_type = entry.content_type,
                        source_instrument_index = entry.source_instrument_index,
                        effect_columns = entry.effect_columns,
                        note_columns = entry.note_columns
                    }
                    table.insert(timing, timing_entry)
                    
                    -- Rebuild saved_labels
                    if entry.slice_label and entry.slice_label ~= "" then
                        local hex_key = string.format("%02X", entry.slice_index + 1)
                        symbol_data.saved_labels[hex_key] = {
                            label = entry.slice_label,
                            breakpoint = entry.is_breakpoint
                        }
                    end
                end
                symbol_data.break_set = { timing = timing }
            end
            
            -- Add to registry
            registry.set_symbol(symbol, symbol_data)
            
            -- Handle dictionary assignment
            if symbol_entry.dictionary and symbol_entry.dictionary ~= "" then
                if not dictionaries.exists(symbol_entry.dictionary) then
                    dictionaries.create(symbol_entry.dictionary, "", "")
                end
                dictionaries.add_symbol(symbol, symbol_entry.dictionary)
            end
            
            imported_count = imported_count + 1
        end
        
        -- Save registry
        registry.save()
        
        renoise.app():show_status("Imported " .. imported_count .. " symbols from " .. filepath)
        return true, imported_count
    end
    
    return false
end

function export.prompt_import_json()
    return export.from_json(nil)
end

-- ============================================================================
-- CSV Import
-- ============================================================================

-- Parse a CSV line handling quoted fields
local function parse_csv_line(line)
    local fields = {}
    local field = ""
    local in_quotes = false
    
    local i = 1
    while i <= #line do
        local char = line:sub(i, i)
        
        if char == '"' then
            if in_quotes and line:sub(i + 1, i + 1) == '"' then
                field = field .. '"'
                i = i + 1
            else
                in_quotes = not in_quotes
            end
        elseif char == ',' and not in_quotes then
            table.insert(fields, field)
            field = ""
        else
            field = field .. char
        end
        i = i + 1
    end
    table.insert(fields, field)
    
    return fields
end

function export.from_csv(filepath)
    if not filepath then
        filepath = renoise.app():prompt_for_filename_to_read({"*.csv"}, "Import Global Alphabet (CSV)")
        if not filepath or filepath == "" then return false end
    end
    
    local file, err = io.open(filepath, "r")
    if not file then
        renoise.app():show_error("Unable to open file for reading: " .. tostring(err))
        return false
    end
    
    -- Read and skip header
    local header = file:read()
    if not header then
        renoise.app():show_error("Invalid CSV format: No header found")
        file:close()
        return false
    end
    
    -- Parse header to get column indices
    local header_fields = parse_csv_line(header)
    local col_index = {}
    for i, name in ipairs(header_fields) do
        col_index[name] = i
    end
    
    -- Verify required columns exist
    if not col_index["Symbol"] then
        renoise.app():show_error("Invalid CSV format: Missing Symbol column")
        file:close()
        return false
    end
    
    -- Collect data grouped by symbol
    local symbol_data = {}
    local dictionary_keys = {}  -- Track dictionary keys from CSV
    local line_num = 1
    
    for line in file:lines() do
        line_num = line_num + 1
        local fields = parse_csv_line(line)
        
        local symbol = fields[col_index["Symbol"]]
        if symbol and symbol ~= "" then
            if not symbol_data[symbol] then
                -- Parse symbol key:
                -- - Number (0-119): explicit key
                -- - "inherited": symbol inherits from dictionary (store as nil)
                -- - "nil" or empty: no key (store as nil)
                local symbol_key = nil
                if col_index["Key"] then
                    local key_str = fields[col_index["Key"]] or ""
                    if key_str ~= "" and key_str ~= "inherited" and key_str ~= "nil" then
                        symbol_key = tonumber(key_str)
                        if symbol_key and (symbol_key < 0 or symbol_key > 119) then
                            symbol_key = nil
                        end
                    end
                    -- "inherited" and "nil" both result in symbol_key = nil
                    -- The distinction is handled at export time based on dictionary membership
                end
                
                local dict_name = fields[col_index["Dictionary"]] or ""
                
                -- Track dictionary key if present
                -- Note: On import, we accept whatever key value is in the CSV
                -- (including the default 48 that was exported)
                if dict_name ~= "" and col_index["DictionaryKey"] then
                    local dict_key_str = fields[col_index["DictionaryKey"]] or ""
                    if dict_key_str ~= "" then
                        local dict_key = tonumber(dict_key_str)
                        if dict_key and dict_key >= 0 and dict_key <= 119 then
                            dictionary_keys[dict_name] = dict_key
                        end
                    end
                end
                
                symbol_data[symbol] = {
                    symbol_type = fields[col_index["SymbolType"]] or "breakpoint_created",
                    instrument_index = tonumber(fields[col_index["InstrumentIndex"]]) or 1,
                    tags = {},
                    color = fields[col_index["Color"]] or "",
                    dictionary = dict_name,
                    key = symbol_key,
                    saved_labels = {},
                    timing = {}
                }
                
                -- Parse tags (comma-separated)
                local tags_str = fields[col_index["Tags"]] or ""
                if tags_str ~= "" then
                    for tag in tags_str:gmatch("[^,]+") do
                        table.insert(symbol_data[symbol].tags, tag:match("^%s*(.-)%s*$"))
                    end
                end
            end
            
            -- Add timing entry
            local timing_entry = {
                instrument_value = tonumber(fields[col_index["SliceIndex"]]) or 0,
                relative_line = tonumber(fields[col_index["TimingLine"]]) or 1,
                new_delay = tonumber(fields[col_index["TimingDelay"]]) or 0,
                original_line = tonumber(fields[col_index["OriginalLine"]]),
                original_delay = tonumber(fields[col_index["OriginalDelay"]]),
                original_distance = tonumber(fields[col_index["OriginalDistance"]]),
                breakpoint = fields[col_index["TimingBreakpoint"]] == "true",
                note_value = tonumber(fields[col_index["NoteValue"]]) or 0,
                volume_value = tonumber(fields[col_index["VolumeValue"]]),
                panning_value = tonumber(fields[col_index["PanningValue"]]),
                effect_number_value = tonumber(fields[col_index["EffectNumber"]]),
                effect_amount_value = tonumber(fields[col_index["EffectAmount"]]),
                has_note = fields[col_index["HasNote"]] == "true",
                content_type = fields[col_index["ContentType"]] or ""
            }
            table.insert(symbol_data[symbol].timing, timing_entry)
            
            -- Add label if present
            local slice_label = fields[col_index["SliceLabel"]] or ""
            local is_breakpoint = fields[col_index["IsBreakpoint"]] == "true"
            if slice_label ~= "" or is_breakpoint then
                local hex_key = string.format("%02X", (timing_entry.instrument_value or 0) + 1)
                symbol_data[symbol].saved_labels[hex_key] = {
                    label = slice_label,
                    breakpoint = is_breakpoint
                }
            end
        end
    end
    
    file:close()
    
    -- Import collected symbols
    local imported_count = 0
    for symbol, data in pairs(symbol_data) do
        local symbol_entry = {
            instrument_index = data.instrument_index,
            symbol_type = data.symbol_type,
            tags = data.tags,
            color = data.color,
            key = data.key,
            saved_labels = data.saved_labels,
            break_set = { timing = data.timing }
        }
        
        registry.set_symbol(symbol, symbol_entry)
        
        -- Handle dictionary
        if data.dictionary and data.dictionary ~= "" then
            if not dictionaries.exists(data.dictionary) then
                -- Create dictionary with key if we captured one
                local dict_key = dictionary_keys[data.dictionary]
                dictionaries.create(data.dictionary, "", "", dict_key)
            else
                -- Update existing dictionary's key if we have one and it doesn't have one
                local dict_key = dictionary_keys[data.dictionary]
                if dict_key and not dictionaries.get_key(data.dictionary) then
                    dictionaries.set_key(data.dictionary, dict_key)
                end
            end
            dictionaries.add_symbol(symbol, data.dictionary)
        end
        
        imported_count = imported_count + 1
    end
    
    registry.save()
    
    renoise.app():show_status("Imported " .. imported_count .. " symbols from " .. filepath)
    return true, imported_count
end

function export.prompt_import_csv()
    return export.from_csv(nil)
end

return export