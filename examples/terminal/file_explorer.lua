local terminal = require("terminal")
local fs = require("filesystem")

-- Initialize terminal
local term = terminal.WrapFile(io.stdin, io.stdout)
term:UseAlternateScreen(true)
term:EnableCaret(false)
term:Clear()

-- Enable mouse tracking
term:EnableMouse(true)
term:Write("\27[?1002h")
term:Flush()

-- State
local current_dir = fs.get_current_directory()
local files = {}
local selected_index = 1
local scroll_offset = 0
local running = true

-- Helper to format file size
local function format_size(size)
	if size < 1024 then
		return string.format("%d B", size)
	elseif size < 1024 * 1024 then
		return string.format("%.1f KB", size / 1024)
	elseif size < 1024 * 1024 * 1024 then
		return string.format("%.1f MB", size / (1024 * 1024))
	else
		return string.format("%.1f GB", size / (1024 * 1024 * 1024))
	end
end

-- Helper to format date
local function format_date(timestamp)
	return os.date("%Y-%m-%d %H:%M:%S", timestamp)
end

-- Helper to get file permissions string (Unix-style)
local function format_mode(mode)
	if not mode then return "----------" end

	local result = ""
	local perms = {"r", "w", "x"}

	-- Owner, group, others
	for shift = 6, 0, -3 do
		local bits = bit.band(bit.rshift(mode, shift), 7)
		for i = 1, 3 do
			local bit_val = bit.band(bits, bit.lshift(1, 3 - i))
			result = result .. (bit_val ~= 0 and perms[i] or "-")
		end
	end

	return result
end

-- Helper to check if file is an image
local function is_image_file(filename)
	if not filename then return false end
	local ext = filename:match("%.([^%.]+)$")
	if not ext then return false end
	ext = ext:lower()
	return ext == "png" or ext == "jpg" or ext == "jpeg" or ext == "gif" or 
	       ext == "bmp" or ext == "webp" or ext == "tiff" or ext == "tif"
end

-- Load files in current directory
local function load_files()
	files = {}
	local file_list, err = fs.get_files(current_dir)

	if not file_list then
		files = {{name = "[Error: " .. tostring(err) .. "]", type = "error"}}
		return
	end

	-- Add parent directory entry
	if current_dir ~= "/" then
		table.insert(files, {name = "..", type = "directory"})
	end

	-- Add all files with their attributes
	for _, name in ipairs(file_list) do
		local path = current_dir
		if path:sub(-1) ~= "/" then
			path = path .. "/"
		end
		path = path .. name

		local attr = fs.get_attributes(path)
		if attr then
			table.insert(files, {
				name = name,
				type = attr.type,
				size = attr.size,
				modified = attr.last_modified,
				mode = attr.mode
			})
		else
			table.insert(files, {name = name, type = "unknown"})
		end
	end

	-- Sort: directories first, then files, alphabetically
	table.sort(files, function(a, b)
		if a.name == ".." then return true end
		if b.name == ".." then return false end
		if a.type == b.type then
			return a.name:lower() < b.name:lower()
		end
		return a.type == "directory" and b.type ~= "directory"
	end)

	selected_index = 1
	scroll_offset = 0
end

-- Draw the UI
local function draw_ui()
	local width, height = term:GetSize()
	local split_pos = math.floor(width * 0.4)
	local list_height = height - 3

	term:BeginFrame()
	term:Clear()
	term:SetCaretPosition(1, 1)

	-- Header
	term:PushBold()
	term:PushForegroundColor(100, 200, 255)
	term:Write("File Explorer")
	term:PopAttribute()
	term:PopAttribute()

	-- Current directory
	term:SetCaretPosition(1, 2)
	term:PushForegroundColor(150, 150, 150)
	local display_dir = current_dir
	if #display_dir > split_pos - 2 then
		display_dir = "..." .. display_dir:sub(-(split_pos - 5))
	end
	term:Write(display_dir)
	term:PopAttribute()

	-- Draw divider line
	term:SetCaretPosition(1, 3)
	for i = 1, width do
		term:Write("-")
	end

	-- Draw file list (left side)
	for i = 1, list_height do
		local file_idx = scroll_offset + i
		if file_idx <= #files then
			local file = files[file_idx]
			local is_selected = file_idx == selected_index

			term:SetCaretPosition(1, 3 + i)

			-- Selection highlight
			if is_selected then
				term:PushBackgroundColor(50, 50, 100)
			end

			-- File icon and name
			local icon = " "
			if file.type == "directory" then
				icon = "/"
				term:PushForegroundColor(100, 200, 255)
			elseif file.type == "error" then
				term:PushForegroundColor(255, 100, 100)
			else
				term:PushForegroundColor(200, 200, 200)
			end

			local display_name = file.name
			local max_name_len = split_pos - 4
			if #display_name > max_name_len then
				display_name = display_name:sub(1, max_name_len - 3) .. "..."
			end

			term:Write(" " .. icon .. " " .. display_name)

			-- Pad to split position
			local current_pos = 3 + #display_name + 1
			for j = current_pos, split_pos do
				term:Write(" ")
			end

			if is_selected then
				term:PopAttribute()
			end
			term:PopAttribute()
		end
	end

	-- Draw vertical divider
	for i = 3, height do
		term:SetCaretPosition(split_pos, i)
		term:PushForegroundColor(100, 100, 100)
		term:Write("|")
		term:PopAttribute()
	end

	-- Draw file details (right side)
	if selected_index > 0 and selected_index <= #files then
		local file = files[selected_index]
		local detail_x = split_pos + 2
		local detail_y = 4

		term:SetCaretPosition(detail_x, detail_y)
		term:PushBold()
		term:Write("File Details")
		term:PopAttribute()

		detail_y = detail_y + 2
		term:SetCaretPosition(detail_x, detail_y)
		term:PushForegroundColor(150, 150, 150)
		term:Write("Name:")
		term:PopAttribute()
		term:SetCaretPosition(detail_x + 12, detail_y)
		local max_detail_len = width - detail_x - 12
		local display_name = file.name
		if #display_name > max_detail_len then
			display_name = display_name:sub(1, max_detail_len - 3) .. "..."
		end
		term:Write(display_name)

		detail_y = detail_y + 1
		term:SetCaretPosition(detail_x, detail_y)
		term:PushForegroundColor(150, 150, 150)
		term:Write("Type:")
		term:PopAttribute()
		term:SetCaretPosition(detail_x + 12, detail_y)
		term:Write(file.type or "unknown")

		if file.size then
			detail_y = detail_y + 1
			term:SetCaretPosition(detail_x, detail_y)
			term:PushForegroundColor(150, 150, 150)
			term:Write("Size:")
			term:PopAttribute()
			term:SetCaretPosition(detail_x + 12, detail_y)
			term:Write(format_size(file.size))
		end

		if file.modified then
			detail_y = detail_y + 1
			term:SetCaretPosition(detail_x, detail_y)
			term:PushForegroundColor(150, 150, 150)
			term:Write("Modified:")
			term:PopAttribute()
			term:SetCaretPosition(detail_x + 12, detail_y)
			term:Write(format_date(file.modified))
		end

		if file.mode then
			detail_y = detail_y + 1
			term:SetCaretPosition(detail_x, detail_y)
			term:PushForegroundColor(150, 150, 150)
			term:Write("Permissions:")
			term:PopAttribute()
			term:SetCaretPosition(detail_x + 12, detail_y)
			term:Write(format_mode(file.mode))
		end

		-- Image preview
		if file.type == "file" and is_image_file(file.name) then
			detail_y = detail_y + 2
			term:SetCaretPosition(detail_x, detail_y)
			term:PushBold()
			term:Write("Preview:")
			term:PopAttribute()

			detail_y = detail_y + 1
			term:SetCaretPosition(detail_x, detail_y)

			-- Try to load and display the image
			local image_path = current_dir
			if image_path:sub(-1) ~= "/" then
				image_path = image_path .. "/"
			end
			image_path = image_path .. file.name

			local success, err = pcall(function()
				local file_handle = io.open(image_path, "rb")
				if file_handle then
					local image_data = file_handle:read("*all")
					file_handle:close()

					-- Calculate available space for image
					local available_width = width - detail_x - 2
					local available_height = height - detail_y - 2

					-- Try to display the image with reasonable size
					local image_width = math.min(40, available_width)
					local image_height = math.min(20, available_height)

					term:WriteImage(image_data, {
						width = image_width,
						height = image_height,
						preserveAspectRatio = true
					})
				end
			end)

			if not success then
				term:PushForegroundColor(255, 100, 100)
				term:Write("Error: " .. tostring(err))
				term:PopAttribute()
			end
		end
	end

	-- Footer
	term:SetCaretPosition(1, height)
	term:PushForegroundColor(100, 100, 100)
	term:Write("↑↓: Navigate | Enter: Open | q: Quit | Mouse: Click to select")
	term:PopAttribute()

	term:EndFrame()
end

-- Navigate into a directory
local function enter_directory()
	if selected_index < 1 or selected_index > #files then return end

	local file = files[selected_index]
	if file.type ~= "directory" then return end

	if file.name == ".." then
		-- Go up one directory
		local parent = current_dir:match("(.+)/[^/]+/?$")
		if parent and parent ~= "" then
			current_dir = parent
		else
			current_dir = "/"
		end
	else
		-- Go into directory
		local new_dir = current_dir
		if new_dir:sub(-1) ~= "/" then
			new_dir = new_dir .. "/"
		end
		new_dir = new_dir .. file.name
		current_dir = new_dir
	end

	load_files()
end

-- Initialize
load_files()
draw_ui()

-- Main loop
while running do
	local event = term:ReadEvent()

	if event then
		local redraw = false

		if event.key and not event.mouse then
			-- Keyboard navigation
			if event.key == "up" then
				if selected_index > 1 then
					selected_index = selected_index - 1
					local _, height = term:GetSize()
					local list_height = height - 3
					if selected_index < scroll_offset + 1 then
						scroll_offset = math.max(0, selected_index - 1)
					end
					redraw = true
				end
			elseif event.key == "down" then
				if selected_index < #files then
					selected_index = selected_index + 1
					local _, height = term:GetSize()
					local list_height = height - 3
					if selected_index > scroll_offset + list_height then
						scroll_offset = selected_index - list_height
					end
					redraw = true
				end
			elseif event.key == "enter" then
				enter_directory()
				redraw = true
			elseif event.key == "q" then
				running = false
			elseif event.key == "c" and event.modifiers.ctrl then
				running = false
			end
		elseif event.mouse then
			-- Mouse click to select
			if event.action == "pressed" and event.button == "left" then
				local width, height = term:GetSize()
				local split_pos = math.floor(width * 0.4)

				-- Check if click is in file list area
				if event.x < split_pos and event.y > 3 and event.y <= height - 1 then
					local clicked_idx = scroll_offset + (event.y - 3)
					if clicked_idx >= 1 and clicked_idx <= #files then
						if clicked_idx == selected_index then
							-- Double-click behavior: enter directory
							enter_directory()
						else
							selected_index = clicked_idx
						end
						redraw = true
					end
				end
			elseif event.button == "wheel_up" then
				if scroll_offset > 0 then
					scroll_offset = scroll_offset - 1
					if selected_index > scroll_offset + 1 then
						selected_index = math.max(1, selected_index - 1)
					end
					redraw = true
				end
			elseif event.button == "wheel_down" then
				local _, height = term:GetSize()
				local list_height = height - 3
				if scroll_offset + list_height < #files then
					scroll_offset = scroll_offset + 1
					if selected_index < scroll_offset + 1 then
						selected_index = math.min(#files, selected_index + 1)
					end
					redraw = true
				end
			end
		end

		if redraw then
			draw_ui()
		end
	end
end

-- Cleanup
term:Write("\27[?1002l")
term:EnableMouse(false)
term:EnableCaret(true)
term:UseAlternateScreen(false)
term:Clear()
term:Write("File explorer closed.\n")
