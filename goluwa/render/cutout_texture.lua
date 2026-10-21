local ffi = require("ffi")
local Texture = import("goluwa/render/texture.lua")
local cutout_texture = {}
cutout_texture.DILATE_PASSES = 8

function cutout_texture.Dilate(pixels, width, height, tile_width, passes)
	local count = width * height
	local filled = ffi.new("uint8_t[?]", count)
	local queue = ffi.new("uint32_t[?]", count)
	local depths = ffi.new("uint8_t[?]", count)
	local tail = 0
	local sum_r, sum_g, sum_b = 0, 0, 0

	for i = 0, count - 1 do
		if pixels[i * 4 + 3] > 0 then
			filled[i] = 1
			queue[tail] = i
			tail = tail + 1
			sum_r, sum_g, sum_b = sum_r + pixels[i * 4], sum_g + pixels[i * 4 + 1], sum_b + pixels[i * 4 + 2]
		end
	end

	if tail == 0 then return end

	local opaque = tail
	local head = 0

	while head < tail do
		local i = queue[head]
		head = head + 1
		local depth = depths[i]

		if depth < passes then
			local x, y = i % width, math.floor(i / width)
			local tile_start = x - x % tile_width

			for dy = -1, 1 do
				local ny = y + dy

				if ny >= 0 and ny < height then
					for dx = -1, 1 do
						local nx = x + dx

						if nx >= tile_start and nx < tile_start + tile_width then
							local j = ny * width + nx

							if filled[j] == 0 then
								filled[j] = 1
								depths[j] = depth + 1
								pixels[j * 4], pixels[j * 4 + 1], pixels[j * 4 + 2] = pixels[i * 4], pixels[i * 4 + 1], pixels[i * 4 + 2]
								queue[tail] = j
								tail = tail + 1
							end
						end
					end
				end
			end
		end
	end

	local r, g, b = sum_r / opaque, sum_g / opaque, sum_b / opaque

	for i = 0, count - 1 do
		if filled[i] == 0 then
			pixels[i * 4], pixels[i * 4 + 1], pixels[i * 4 + 2] = r, g, b
		end
	end
end

function cutout_texture.BuildMipChain(pixels, width, height, cutoff)
	local levels = {{width = width, height = height, offset = 0, size = width * height * 4}}
	local total = width * height * 4
	local w, h = width, height

	while w > 1 or h > 1 do
		w, h = math.max(math.floor(w / 2), 1), math.max(math.floor(h / 2), 1)
		levels[#levels + 1] = {width = w, height = h, offset = total, size = w * h * 4}
		total = total + w * h * 4
	end

	local data = ffi.new("uint8_t[?]", total)
	ffi.copy(data, pixels, width * height * 4)
	local threshold = cutoff * 255
	local passing = 0

	for i = 0, width * height - 1 do
		if pixels[i * 4 + 3] >= threshold then passing = passing + 1 end
	end

	local coverage = passing / (width * height)

	for level = 2, #levels do
		local source, destination = levels[level - 1], levels[level]
		local source_pixels, destination_pixels = data + source.offset, data + destination.offset
		local alpha = ffi.new("float[?]", destination.width * destination.height)

		for y = 0, destination.height - 1 do
			local y0 = math.min(y * 2, source.height - 1)
			local y1 = math.min(y * 2 + 1, source.height - 1)

			for x = 0, destination.width - 1 do
				local x0 = math.min(x * 2, source.width - 1)
				local x1 = math.min(x * 2 + 1, source.width - 1)
				local i = y * destination.width + x
				local a, b, c, d = (y0 * source.width + x0) * 4,
				(y0 * source.width + x1) * 4,
				(y1 * source.width + x0) * 4,
				(y1 * source.width + x1) * 4

				for k = 0, 2 do
					destination_pixels[i * 4 + k] = (
							source_pixels[a + k] + source_pixels[b + k] + source_pixels[c + k] + source_pixels[d + k] + 2
						) / 4
				end

				alpha[i] = (source_pixels[a + 3] + source_pixels[b + 3] + source_pixels[c + 3] + source_pixels[d + 3]) / 4
			end
		end

		local count = destination.width * destination.height
		local histogram = ffi.new("uint32_t[256]")

		for i = 0, count - 1 do
			histogram[math.min(math.floor(alpha[i] + 0.5), 255)] = histogram[math.min(math.floor(alpha[i] + 0.5), 255)] + 1
		end

		local wanted, seen, quantile = coverage * count, 0, 0

		for bin = 255, 1, -1 do
			seen = seen + histogram[bin]
			quantile = bin

			if seen >= wanted then break end
		end

		local high = math.min(math.max(threshold / math.max(quantile, 1), 1), 32)

		for i = 0, count - 1 do
			destination_pixels[i * 4 + 3] = math.min(alpha[i] * high + 0.5, 255)
		end

		if destination.width == 1 and destination.height == 1 then
			destination_pixels[3] = alpha[0] > 0 and 255 or 0
		end
	end

	return data, levels, total
end

function cutout_texture.New(pixels, width, height, config)
	config = config or {}
	cutout_texture.Dilate(
		pixels,
		width,
		height,
		config.tile_width or width,
		config.dilate_passes or cutout_texture.DILATE_PASSES
	)
	local data, levels, size = cutout_texture.BuildMipChain(pixels, width, height, config.cutoff or 0.5)

	for _, level in ipairs(levels) do
		level.depth = 1
	end

	return Texture.New{
		decoded = {
			width = width,
			height = height,
			vulkan_format = config.srgb == false and "r8g8b8a8_unorm" or "r8g8b8a8_srgb",
			is_compressed = true,
			mip_count = #levels,
			mip_info = levels,
			data_size = size,
			data = data,
		},
		image = {usage = {"sampled", "transfer_dst", "transfer_src"}},
		sampler = config.sampler or
			{
				min_filter = "linear",
				mag_filter = "linear",
				mipmap_mode = "linear",
				wrap_s = "clamp_to_edge",
				wrap_t = "clamp_to_edge",
			},
	}
end

return cutout_texture
