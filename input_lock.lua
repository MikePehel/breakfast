-- input_lock.lua - Input Lock System for BreakFast Symbol Placement
local input_lock = {}

-- Input lock state
local lock_state = {
    is_active = false,
    last_ctrl_press_time = 0,
    last_ctrl_release_time = 0,
    ctrl_is_pressed = false,
    auto_timeout_time = 0
}

-- Configuration
local config = {
    double_press_window = 0.3,  -- 300ms window for double press
    auto_timeout_duration = 10.0, -- 10 seconds of inactivity timeout
    enable_auto_timeout = true
}

-- Reference to editor module (will be set by main.lua)
local editor_module = nil

-- Reference to visual update callbacks (will be set by main.lua)
local visual_update_callback = nil
local symbol_feedback_callback = nil

-- Available symbol keys for input lock
local symbol_keys = {
    -- Primary symbols A-T
    "a", "b", "c", "d", "e", "f", "g", "h", "i", "j",
    "k", "l", "m", "n", "o", "p", "q", "r", "s", "t",
    -- Numeric symbols 0-9
    "0", "1", "2", "3", "4", "5", "6", "7", "8", "9"
}

-- Initialize the input lock system
function input_lock.initialize(editor_ref, visual_callback, symbol_feedback_cb)
    editor_module = editor_ref
    visual_update_callback = visual_callback
    symbol_feedback_callback = symbol_feedback_cb
    input_lock.reset_state()
    print("DEBUG: Input lock system initialized")
end

-- Reset all input lock state
function input_lock.reset_state()
    lock_state.is_active = false
    lock_state.last_ctrl_press_time = 0
    lock_state.last_ctrl_release_time = 0
    lock_state.ctrl_is_pressed = false
    lock_state.auto_timeout_time = 0
    
    if visual_update_callback then
        visual_update_callback(false)
    end
    
    print("DEBUG: Input lock state reset")
end

-- Check if a key is a valid symbol key
local function is_symbol_key(key_name)
    for _, symbol_key in ipairs(symbol_keys) do
        if key_name:lower() == symbol_key then
            return true
        end
    end
    return false
end

-- Handle double Ctrl press detection
local function handle_ctrl_key(key_name, is_pressed)
    local current_time = os.clock()
    
    -- Check if this is a Ctrl key
    local is_ctrl_key = (key_name == "lcontrol" or key_name == "rcontrol" or 
                        key_name == "lctrl" or key_name == "rctrl" or 
                        key_name == "left_ctrl" or key_name == "right_ctrl" or
                        key_name == "control")
    
    if not is_ctrl_key then
        return false
    end
    
    print("DEBUG: Ctrl key event - " .. key_name .. " (" .. (is_pressed and "pressed" or "released") .. ")")
    
    if is_pressed then
        lock_state.ctrl_is_pressed = true
        
        -- Check for double press: time since last press (not release)
        local time_since_last_press = current_time - lock_state.last_ctrl_press_time
        
        print("DEBUG: Time since last press: " .. string.format("%.3f", time_since_last_press) .. "s (window: " .. config.double_press_window .. "s)")
        
        if time_since_last_press <= config.double_press_window and 
           lock_state.last_ctrl_press_time > 0 then
            -- Double press detected!
            print("DEBUG: Double Ctrl press detected, activating input lock")
            input_lock.activate_lock()
            return true
        end
        
        lock_state.last_ctrl_press_time = current_time
        print("DEBUG: Updated last_ctrl_press_time to " .. string.format("%.3f", current_time))
    else
        -- Ctrl released
        lock_state.ctrl_is_pressed = false
        lock_state.last_ctrl_release_time = current_time
        print("DEBUG: Updated last_ctrl_release_time to " .. string.format("%.3f", current_time))
    end
    
    return false
end

-- Activate input lock mode
function input_lock.activate_lock()
    lock_state.is_active = true
    
    if config.enable_auto_timeout then
        lock_state.auto_timeout_time = os.clock() + config.auto_timeout_duration
    end
    
    if visual_update_callback then
        visual_update_callback(true)
    end
    
    renoise.app():show_status("BreakFast INPUT LOCK ACTIVE! Type symbol keys (A-T, 0-9) or press ESC to exit")
    print("DEBUG: Input lock activated")
end

-- Deactivate input lock mode
function input_lock.deactivate_lock()
    lock_state.is_active = false
    lock_state.auto_timeout_time = 0
    
    if visual_update_callback then
        visual_update_callback(false)
    end
    
    renoise.app():show_status("BreakFast Input Lock deactivated - Double-press Ctrl to reactivate")
    print("DEBUG: Input lock deactivated")
end

-- Handle symbol key press when input lock is active
local function handle_symbol_key(key_name, is_pressed)
    if not editor_module then
        print("ERROR: Editor module not available for symbol placement")
        return false
    end
    
    -- Convert key to uppercase symbol
    local symbol = key_name:upper()
    
    -- Provide visual feedback that follows key press/release
    if symbol_feedback_callback then
        symbol_feedback_callback(symbol, is_pressed)
    end
    
    -- Only place symbol on key PRESS (not release)
    if is_pressed then
        print("DEBUG: Attempting to place symbol " .. symbol .. " via input lock")
        
        -- Use existing editor placement system
        local success = editor_module.place_symbol(symbol)
        
        if success then
            renoise.app():show_status("BreakFast: Placed symbol " .. symbol .. " (Input Lock active)")
            
            -- Reset auto-timeout
            if config.enable_auto_timeout then
                lock_state.auto_timeout_time = os.clock() + config.auto_timeout_duration
            end
            
            return true
        else
            renoise.app():show_warning("Failed to place symbol " .. symbol .. " - symbol may not be available")
            return false
        end
    end
    
    return true -- Return true for key release events (no action needed)
end

-- Check for auto-timeout
local function check_auto_timeout()
    if not lock_state.is_active or not config.enable_auto_timeout then
        return
    end
    
    if lock_state.auto_timeout_time > 0 and os.clock() > lock_state.auto_timeout_time then
        print("DEBUG: Input lock auto-timeout triggered")
        input_lock.deactivate_lock()
    end
end

-- Main key event handler
function input_lock.handle_key_event(key)
    -- Always check for auto-timeout
    check_auto_timeout()
    
    local key_name = key.name
    local is_pressed = (key.state == "pressed")
    
    print("DEBUG: Input lock key event - " .. key_name .. " (" .. (is_pressed and "pressed" or "released") .. ")")
    
    -- Handle Ctrl key for double press detection (both when locked and unlocked)
    if handle_ctrl_key(key_name, is_pressed) then
        -- Double press detected and lock activated
        return key -- Consume the key event
    end
    
    -- If input lock is not active, pass through the key event
    if not lock_state.is_active then
        return key -- Let Renoise handle the key normally
    end
    
    -- Input lock is active - handle special cases
    if is_pressed then
        -- ESC key deactivates input lock
        if key_name == "esc" then
            input_lock.deactivate_lock()
            return key -- Consume the key event
        end
        
        -- Handle symbol keys - pass both key name and press state
        if is_symbol_key(key_name) then
            handle_symbol_key(key_name, true) -- true = pressed
            return key -- Consume the key event
        end
        
        -- For any other key, show helpful message
        renoise.app():show_status("BreakFast Input Lock: Use A-T, 0-9 for symbols, ESC to exit")
    else
        -- Handle symbol key releases for visual feedback
        if is_symbol_key(key_name) then
            handle_symbol_key(key_name, false) -- false = released
            return key -- Consume the key event
        end
    end
    
    -- Consume all key events when input lock is active
    return key
end

-- Get current input lock state
function input_lock.is_active()
    return lock_state.is_active
end

-- Get configuration (for external access/modification)
function input_lock.get_config()
    return config
end

-- Set configuration
function input_lock.set_config(new_config)
    for key, value in pairs(new_config) do
        if config[key] ~= nil then
            config[key] = value
        end
    end
end

-- Manual activation (for testing or alternative triggers)
function input_lock.manual_activate()
    input_lock.activate_lock()
end

-- Manual deactivation (for cleanup)
function input_lock.manual_deactivate()
    input_lock.deactivate_lock()
end

-- Cleanup function
function input_lock.cleanup()
    input_lock.reset_state()
    editor_module = nil
    visual_update_callback = nil
    symbol_feedback_callback = nil
    print("DEBUG: Input lock system cleaned up")
end

return input_lock