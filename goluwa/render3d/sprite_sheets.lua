local ffi = require("ffi")
local vfs = import("goluwa/vfs.lua")
local assets = import("goluwa/assets.lua")
local Texture = import("goluwa/render/texture.lua")
local vtf = import("goluwa/codecs/vtf.lua")
local sprite_sheets = {}
local cache = {}

function sprite_sheets.Define(name, texture, sequences, image_space)
	local per = 1

	for _, sequence in ipairs(sequences) do
		per = math.max(per, #sequence.frames)
	end

	local count = #sequences * per
	local rects = ffi.new("float[?]", count * 4)
	local times = {}

	for s, sequence in ipairs(sequences) do
		times[s] = sequence.time

		for f = 1, per do
			local frame = sequence.frames[math.min(f, #sequence.frames)]
			local offset = ((s - 1) * per + f - 1) * 4
			local rect = frame.rect

			if image_space then rect = {rect[1], rect[4], rect[3], rect[2]} end

			for i = 1, 4 do
				rects[offset + i - 1] = rect[i]
			end
		end
	end

	local sheet = {
		Texture = texture,
		Rects = Texture.New{
			width = count,
			height = 1,
			format = "r32g32b32a32_sfloat",
			buffer = rects,
			sampler = {
				min_filter = "nearest",
				mag_filter = "nearest",
				wrap_s = "clamp_to_edge",
				wrap_t = "clamp_to_edge",
			},
		},
		Frames = count,
		SequenceFrames = per,
		Sequences = #sequences,
		Times = times,
	}
	cache[name] = sheet
	return sheet
end

function sprite_sheets.Load(path)
	if cache[path] then return cache[path] end

	local texture = assets.GetTexture(path)
	local data = path:lower():find("%.vtf$") and vfs.Read(path)
	local parsed = data and vtf.ParseSheet(data)

	if parsed and #parsed.sequences > 0 then
		table.sort(parsed.sequences, function(a, b)
			return a.id < b.id
		end)

		return sprite_sheets.Define(path, texture, parsed.sequences, true)
	end

	if data then
		return sprite_sheets.Define(path, texture, {{time = 1, frames = {{rect = {0, 0, 1, 1}}}}}, true)
	end

	cache[path] = {Texture = texture, Frames = 1, SequenceFrames = 1, Sequences = 1, Times = {1}}
	return cache[path]
end

return sprite_sheets
