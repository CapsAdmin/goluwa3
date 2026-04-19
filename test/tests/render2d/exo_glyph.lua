local T = import("test/environment.lua")
local gfonts = import("goluwa/gfonts.lua")
local fs = import("goluwa/fs.lua")
local Buffer = import("goluwa/structs/buffer.lua")
local ttf = import("goluwa/codecs/ttf.lua")
local ttf_font = import("goluwa/render2d/fonts/ttf.lua")
local cached_path = nil

local function decode_font_name(path)
	local file = io.open(path, "rb")

	if not file then return end

	local content = file:read("*a")
	file:close()
	return ttf.DecodeBuffer(Buffer.New(content, #content))
end

local function get_exo_regular_path()
	if cached_path then return cached_path end

	local cache_root = "game/storage/shared/downloads/url"
	local entries = fs.get_files(cache_root) or {}

	for _, entry in ipairs(entries) do
		local path = cache_root .. "/" .. entry .. "/file.ttf"

		if fs.exists(path) then
			local ok, font_data = pcall(decode_font_name, path)

			if
				ok and
				font_data and
				font_data.family == "Exo" and
				font_data.subfamily == "Regular"
			then
				cached_path = path
				return path
			end
		end
	end

	local ok, path = pcall(function()
		return gfonts.Download{name = "Exo", weight = "Regular"}:Get()
	end)

	if ok and path then
		cached_path = path
		return path
	end
end

local function count_enclosed_regions(width, height, is_filled)
	local visited = {}
	local queue_x = {}
	local queue_y = {}

	local function key(x, y)
		return y * width + x
	end

	local function is_background(x, y)
		return not is_filled(x, y)
	end

	local function flood_fill(start_x, start_y)
		local head = 1
		local tail = 1
		local pixels = 0
		queue_x[1] = start_x
		queue_y[1] = start_y
		visited[key(start_x, start_y)] = true

		while head <= tail do
			local x = queue_x[head]
			local y = queue_y[head]
			head = head + 1
			pixels = pixels + 1

			for i = 1, 4 do
				local nx = x
				local ny = y

				if i == 1 then
					nx = x - 1
				elseif i == 2 then
					nx = x + 1
				elseif i == 3 then
					ny = y - 1
				else
					ny = y + 1
				end

				if nx >= 0 and ny >= 0 and nx < width and ny < height then
					local idx = key(nx, ny)

					if not visited[idx] and is_background(nx, ny) then
						tail = tail + 1
						queue_x[tail] = nx
						queue_y[tail] = ny
						visited[idx] = true
					end
				end
			end
		end

		return pixels
	end

	for x = 0, width - 1 do
		if is_background(x, 0) and not visited[key(x, 0)] then flood_fill(x, 0) end

		if is_background(x, height - 1) and not visited[key(x, height - 1)] then
			flood_fill(x, height - 1)
		end
	end

	for y = 0, height - 1 do
		if is_background(0, y) and not visited[key(0, y)] then flood_fill(0, y) end

		if is_background(width - 1, y) and not visited[key(width - 1, y)] then
			flood_fill(width - 1, y)
		end
	end

	local enclosed = 0
	local min_pixels = math.max(24, math.floor((width * height) * 0.002))

	for y = 1, height - 2 do
		for x = 1, width - 2 do
			local idx = key(x, y)

			if not visited[idx] and is_background(x, y) then
				if flood_fill(x, y) >= min_pixels then enclosed = enclosed + 1 end
			end
		end
	end

	return enclosed
end

T.Test("Exo lowercase g keeps both counters hollow", function()
	local path = get_exo_regular_path()
	assert(path, "Exo Regular font unavailable")
	local font = ttf_font.New(path)
	font:SetSize(96)
	local glyph = font:GetGlyph("g")
	assert(glyph and glyph.glyph_data, "expected lowercase g glyph data")
	local get_contour_points

	for i = 1, 20 do
		local name, value = debug.getupvalue(font.DrawGlyph, i)

		if not name then break end

		if name == "get_contour_points" then get_contour_points = value end
	end

	assert(get_contour_points, "expected glyph contour helper")
	local contours = {}
	local start_idx = 1

	for _, end_idx in ipairs(glyph.glyph_data.end_pts_of_contours) do
		end_idx = end_idx + 1
		local raw_points = {}

		for i = start_idx, end_idx do
			table.insert(raw_points, glyph.glyph_data.points[i])
		end

		start_idx = end_idx + 1

		if #raw_points >= 2 then
			local flattened = get_contour_points(font, glyph.glyph_data, raw_points)

			if #flattened >= 6 then
				for _, contour in ipairs(math2d.SplitSelfIntersectingContour(flattened)) do
					if #contour >= 6 then table.insert(contours, contour) end
				end
			end
		end
	end

	local min_x, min_y = math.huge, math.huge
	local max_x, max_y = -math.huge, -math.huge

	for _, contour in ipairs(contours) do
		for i = 1, #contour, 2 do
			min_x = math.min(min_x, contour[i])
			min_y = math.min(min_y, contour[i + 1])
			max_x = math.max(max_x, contour[i])
			max_y = math.max(max_y, contour[i + 1])
		end
	end

	local padding = 4
	local width = math.max(1, math.ceil(max_x - min_x + padding * 2))
	local height = math.max(1, math.ceil(max_y - min_y + padding * 2))

	local function is_filled(x, y)
		local px = min_x - padding + x + 0.5
		local py = min_y - padding + y + 0.5
		local nesting = 0

		for _, contour in ipairs(contours) do
			if math2d.IsPointInPolygon(px, py, contour) then nesting = nesting + 1 end
		end

		return nesting % 2 == 1
	end

	local enclosed = count_enclosed_regions(width, height, is_filled)
	assert(
		enclosed >= 2,
		(
			"expected Exo lowercase g to keep two enclosed counters, got %d"
		):format(enclosed)
	)
end)
