local codec = require("codec")
local ffi = require("ffi")

local function inspect(path)
	local ok, img = pcall(codec.DecodeFile, path)

	if not ok or not img then
		print(path .. ": Failed to load: " .. tostring(img))
		return
	end

	local w, h = img.width, img.height
	print(string.format("%s: %dx%d", path, w, h))
	local buffer = img.buffer:GetBuffer()
	local counts = {}
	local samples = {}

	for i = 0, math.min(100, w * h - 1) do
		local idx = i * 4
		local r, g, b, a = buffer[idx], buffer[idx + 1], buffer[idx + 2], buffer[idx + 3]
		local key = string.format("%d,%d,%d,%d", r, g, b, a)
		counts[key] = (counts[key] or 0) + 1

		if #samples < 5 then table.insert(samples, key) end
	end

	print("  Samples: " .. table.concat(samples, " | "))
	-- Check center pixel
	local cx, cy = math.floor(w / 2), math.floor(h / 2)
	local cidx = (cy * w + cx) * 4
	print(
		string.format(
			"  Center (%d,%d): %d,%d,%d,%d",
			cx,
			cy,
			buffer[cidx],
			buffer[cidx + 1],
			buffer[cidx + 2],
			buffer[cidx + 3]
		)
	)
end

inspect("glyph_sdf_72.png")
inspect("atlas_final.png")
