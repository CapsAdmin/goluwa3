local threads = require("threads")
local terminal = require("terminal")

local function braille(...)
    local dots = {...}
    local offset = 0
    
    -- Map dot numbers to bit positions
    -- Dot 1 = bit 0, Dot 2 = bit 1, Dot 3 = bit 2, etc.
    for _, dot in ipairs(dots) do
        if dot >= 1 and dot <= 8 then
            offset = bit.bor(offset, bit.lshift(1, dot - 1))
        end
    end
    
    -- Braille Unicode block starts at U+2800
    local codepoint = 0x2800 + offset
    
    -- Manually encode UTF-8 (3 bytes for U+2800-U+28FF range)
    -- Format: 1110xxxx 10xxxxxx 10xxxxxx
    local byte1 = bit.bor(0xE0, bit.rshift(codepoint, 12))
    local byte2 = bit.bor(0x80, bit.band(bit.rshift(codepoint, 6), 0x3F))
    local byte3 = bit.bor(0x80, bit.band(codepoint, 0x3F))
    
    return string.char(byte1, byte2, byte3)
end

-- Initialize terminal
local term = terminal.WrapFile(io.stdin, io.stdout)

-- Use alternate screen buffer (no scrollback, cleaner)
term:UseAlternateScreen(true)

-- Enable mouse support
term:EnableMouse(true)

-- Thread worker function - computes Game of Life for assigned rows
local function worker(input)
    local start_row = input.start_row
    local end_row = input.end_row
    local width = input.width
    local height = input.height
    local grid = input.grid

    -- Helper to count neighbors with wrapping
    local function count_neighbors(x, y)
        local count = 0
        for dy = -1, 1 do
            for dx = -1, 1 do
                if not (dx == 0 and dy == 0) then
                    -- Wrap around edges
                    local nx = ((x - 1 + dx) % width) + 1
                    local ny = ((y - 1 + dy) % height) + 1
                    if grid[ny][nx] == 1 then
                        count = count + 1
                    end
                end
            end
        end
        return count
    end

    -- Compute next state for assigned rows
    local result = {}
    for y = start_row, end_row do
        result[y] = {}
        for x = 1, width do
            local neighbors = count_neighbors(x, y)
            local cell = grid[y][x]

            -- Conway's rules
            if cell == 1 then
                result[y][x] = (neighbors == 2 or neighbors == 3) and 1 or 0
            else
                result[y][x] = (neighbors == 3) and 1 or 0
            end
        end
    end

    return result
end

-- Initialize random seed
math.randomseed(os.time())

-- Get initial terminal size
local term_width, term_height = term:GetSize()
-- Each braille char represents 2x4 cells
local width = (term_width - 1) * 2  -- 2 cells per braille char width
local height = (term_height - 4) * 4  -- 4 cells per braille char height

-- Create grid with random initial state
local function create_grid(w, h)
    local grid = {}
    for y = 1, h do
        grid[y] = {}
        for x = 1, w do
            grid[y][x] = math.random() > 0.7 and 1 or 0  -- 30% alive
        end
    end
    return grid
end

local grid = create_grid(width, height)

-- Create thread pool (8 threads) - these threads will stay alive for the entire session
local num_threads = threads.get_thread_count()
local thread_pool = threads.new_pool(worker, num_threads)

-- Display function using braille characters
local function display_grid(g, generation, w, h, tw, th)
    term:BeginFrame()  -- Start buffering

    term:SetCaretPosition(1, 1)
    -- Header
    term:PushForegroundColor(0.5, 0.8, 1.0)
    term:Write(string.format("Gen: %-8d | Cells: %dx%d\n", generation, w, h))
    term:PopAttribute()
    term:PushForegroundColor(0.8, 0.8, 0.8)
    term:Write("Click=toggle | Space=pause | R=random | C=clear | Ctrl+C=exit\n")
    term:PopAttribute()

    local braille_width = math.ceil(w / 2)
   -- term:Write(string.rep("─", braille_width) .. "\n")

    -- Grid using braille characters
    -- Each braille char represents a 2x4 grid:
    -- 1 4    (column 1, column 2)
    -- 2 5
    -- 3 6
    -- 7 8
    local braille_height = math.ceil(h / 4)

    for by = 0, braille_height - 1 do
        for bx = 0, braille_width - 1 do
            -- Collect the 8 cells for this braille character
            local dots = {}
            local any_alive = false

            -- Map grid cells to braille dots
            local base_y = by * 4 + 1
            local base_x = bx * 2 + 1

            -- Left column (dots 1,2,3,7)
            local dot_map = {
                {base_y, base_x, 1},      -- dot 1
                {base_y + 1, base_x, 2},  -- dot 2
                {base_y + 2, base_x, 3},  -- dot 3
                {base_y + 3, base_x, 7},  -- dot 7
                -- Right column (dots 4,5,6,8)
                {base_y, base_x + 1, 4},      -- dot 4
                {base_y + 1, base_x + 1, 5},  -- dot 5
                {base_y + 2, base_x + 1, 6},  -- dot 6
                {base_y + 3, base_x + 1, 8},  -- dot 8
            }

            for _, mapping in ipairs(dot_map) do
                local y, x, dot_num = mapping[1], mapping[2], mapping[3]
                if y <= h and x <= w and g[y] and g[y][x] == 1 then
                    table.insert(dots, dot_num)
                    any_alive = true
                end
            end

            -- Set color based on whether any cells are alive
            if any_alive then
                term:ForegroundColor(50, 255, 76)  -- Green for alive cells
            else
                term:ForegroundColor(25, 25, 25)  -- Dark for dead cells
            end

            -- Draw braille character
            if #dots > 0 then
                term:Write(braille(unpack(dots)))
            else
                term:Write(braille())  -- Empty braille character
            end
        end
        term:Write("\n")
    end

    -- Footer
    term:Write(string.rep("─", braille_width))
    term:Write("\n")

    term:EndFrame()  -- Flush all at once
end

-- Check for Ctrl+C
local should_exit = false
local paused = false

-- Main loop
local generation = 0
local last_width, last_height = term_width, term_height

-- Hide cursor for cleaner display
term:EnableCaret(false)

-- Helper function to toggle a cell based on screen coordinates
local function toggle_cell_at_screen(screen_x, screen_y)
	-- Screen Y needs to account for header (2 lines) and separator (1 line)
	local grid_screen_y = screen_y - 3
	if grid_screen_y < 1 then return end

	-- Convert screen position to grid position
	-- Each braille character is 2x4 cells
	local braille_x = screen_x - 1  -- 0-based braille column
	local braille_y = grid_screen_y - 1  -- 0-based braille row

	if braille_x < 0 or braille_y < 0 then return end

	-- Convert to grid coordinates (each braille char = 2 cells wide, 4 cells tall)
	local base_grid_x = braille_x * 2 + 1
	local base_grid_y = braille_y * 4 + 1

	-- Toggle all 8 cells in this braille character
	for dy = 0, 3 do
		for dx = 0, 1 do
			local gx = base_grid_x + dx
			local gy = base_grid_y + dy
			if gx >= 1 and gx <= width and gy >= 1 and gy <= height then
				grid[gy][gx] = 1 - grid[gy][gx]
			end
		end
	end
end

while not should_exit do
    -- Check for terminal resize
    local new_width, new_height = term:GetSize()
    if new_width ~= last_width or new_height ~= last_height then
        -- Terminal resized, restart simulation
        term_width, term_height = new_width, new_height
        width = (term_width - 1) * 2  -- 2 cells per braille char width
        height = (term_height - 4) * 4  -- 4 cells per braille char height

        -- Ensure dimensions are valid
        if width < 1 then width = 1 end
        if height < 1 then height = 1 end

        grid = create_grid(width, height)
        generation = 0
        last_width, last_height = new_width, new_height

        -- Display the new grid and skip to next iteration
        -- This prevents running threads with mismatched dimensions
        display_grid(grid, generation, width, height, term_width, term_height)
        goto continue
    end

    -- Check for input events
    local event = term:ReadEvent()
    if event then
        if event.mouse then
            -- Handle mouse events
            if event.button == "left" and event.action == "pressed" then
                toggle_cell_at_screen(event.x, event.y)
            end
        else
            -- Handle keyboard events
            if event.key == "c" and event.modifiers.ctrl then
                should_exit = true
                break
            elseif event.key == " " then
                paused = not paused
            elseif event.key == "r" or event.key == "R" then
                grid = create_grid(width, height)
                generation = 0
            elseif event.key == "c" or event.key == "C" then
                -- Clear the grid
                for y = 1, height do
                    for x = 1, width do
                        grid[y][x] = 0
                    end
                end
                generation = 0
            end
        end
    end

    -- Display once per frame
    display_grid(grid, generation, width, height, term_width, term_height)

    -- Skip evolution if paused
    if paused then
        goto continue
    end

    -- Submit work to all threads - threads stay alive and process the work
    local rows_per_thread = math.floor(height / num_threads)
    local work_items = {}
    for i = 1, num_threads do
        local start_row = (i - 1) * rows_per_thread + 1
        local end_row = math.min(i * rows_per_thread, height)

        work_items[i] = {
            start_row = start_row,
            end_row = end_row,
            width = width,
            height = height,
            grid = grid
        }
    end

    -- Submit work to all threads
    thread_pool:submit_all(work_items)

    -- Wait for all threads to complete and collect results
    local results = thread_pool:wait_all()

    -- Assemble new grid from thread results
    local new_grid = {}
    -- Pre-initialize all rows
    for y = 1, height do
        new_grid[y] = {}
        for x = 1, width do
            new_grid[y][x] = 0  -- Default to dead cells
        end
    end

    -- Collect thread results
    for i = 1, num_threads do
        local result = results[i]
        if result then
            for y, row in pairs(result) do
                new_grid[y] = row
            end
        end
    end

    grid = new_grid
    generation = generation + 1

    ::continue::
end

-- Cleanup - shutdown the thread pool to join all threads
thread_pool:shutdown()

-- Cleanup terminal
term:EnableMouse(false)  -- Disable mouse tracking
term:UseAlternateScreen(false)  -- Restore main screen
term:EnableCaret(true)
term:NoAttributes()
term:Write("Game of Life ended. Goodbye!\n")
