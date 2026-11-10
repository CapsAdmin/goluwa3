local T = import("test/environment.lua")
local ffi = require("ffi")
local codec = import("goluwa/codec.lua")
local bc = import("goluwa/codecs/bc.lua")
local texture_compress = import("goluwa/render/texture_compress.lua")

local function make_image(width, height)
	local pixels = ffi.new("uint8_t[?]", width * height * 4)
	local seed = 12345

	for y = 0, height - 1 do
		for x = 0, width - 1 do
			seed = (seed * 1103515245 + 12345) % 2147483648
			local noise = (seed / 2147483648 - 0.5) * 12
			local o = (y * width + x) * 4
			local edge = x > width / 2 and 1 or 0
			pixels[o] = math.min(math.max(x / width * 255 + noise, 0), 255)
			pixels[o + 1] = math.min(math.max(y / height * 255 * (1 - edge * 0.6) + noise, 0), 255)
			pixels[o + 2] = math.min(math.max(128 + 100 * math.sin(x / 7) * math.cos(y / 9) + noise, 0), 255)
			pixels[o + 3] = 255
		end
	end

	return pixels
end

local function psnr(a, b, count, channels)
	local sum = 0
	local n = 0

	for i = 0, count - 1 do
		for _, c in ipairs(channels) do
			local d = a[i * 4 + c] - b[i * 4 + c]
			sum = sum + d * d
			n = n + 1
		end
	end

	return 10 * math.log10(255 * 255 / math.max(sum / n, 1e-9))
end

local function decode_level(dds_data, format, level)
	local info = assert(codec.DecodeData("x.dds", dds_data))
	local mip = info.mip_info[level]
	return bc.Decode(format, info.data + mip.offset, mip.width, mip.height),
	info,
	mip
end

T.Test3D("texture_compress bc7 mode 6 round trips an image with mips", function()
	local width, height = 64, 64
	local pixels = make_image(width, height)
	local file = texture_compress.Compress{pixels = pixels, width = width, height = height, format = "bc7", kind = "srgb"}
	local decoded, info = decode_level(file, "bc7", 1)
	T(info.vulkan_format)["=="]("bc7_srgb_block")
	T(info.mip_count)["=="](7)
	T(info.mip_info[7].width)["=="](1)
	T(psnr(decoded, pixels, width * height, {0, 1, 2}) > 36)["=="](true)
	T(psnr(decoded, pixels, width * height, {3}) > 60)["=="](true)
end)

T.Test3D("texture_compress bc5 and bc4 round trip their channels", function()
	local width, height = 64, 64
	local pixels = make_image(width, height)
	local bc5_file = texture_compress.Compress{
		pixels = pixels,
		width = width,
		height = height,
		format = "bc5",
		kind = "normal",
		mips = false,
	}
	local decoded5, info5 = decode_level(bc5_file, "bc5", 1)
	T(info5.vulkan_format)["=="]("bc5_unorm_block")
	T(info5.mip_count)["=="](1)
	T(psnr(decoded5, pixels, width * height, {0, 1}) > 44)["=="](true)
	local bc4_file = texture_compress.Compress{
		pixels = pixels,
		width = width,
		height = height,
		format = "bc4",
		channel = 2,
		mips = false,
	}
	local decoded4, info4 = decode_level(bc4_file, "bc4", 1)
	T(info4.vulkan_format)["=="]("bc4_unorm_block")
	local errors = 0

	for i = 0, width * height - 1 do
		errors = errors + math.abs(decoded4[i * 4] - pixels[i * 4 + 2])
	end

	T(errors / (width * height) < 1.5)["=="](true)
end)

local render = import("goluwa/render/render.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local Texture = import("goluwa/render/texture.lua")

-- what the gpu's own block decoder makes of the dds, as r8g8b8a8
local function decode_on_gpu(dds_data)
	local info = assert(codec.DecodeData("x.dds", dds_data))
	local texture = Texture.New{decoded = info}
	local width, height = info.width, info.height
	local pipeline = EasyPipeline.Compute{
		name = "texture_compress_test_decode",
		DescriptorSetCount = 1,
		LocalSize = {x = 64, y = 1, z = 1},
		storage_buffers = {{binding_index = 0}},
		sampled_images = {{binding_index = 1}},
		custom_declarations = [[
			layout(set = 0, binding = 0, std430) buffer Out { uint texels[]; };
			layout(set = 0, binding = 1) uniform sampler2D test_texture;
		]],
		shader = ([[
			void main() {
				uint id = gl_GlobalInvocationID.x;

				if (id >= %du) return;

				ivec2 position = ivec2(int(id %% %du), int(id / %du));
				vec4 texel = texelFetch(test_texture, position, 0);
				uvec4 bytes = uvec4(round(texel * 255.0));
				texels[id] = bytes.r | (bytes.g << 8u) | (bytes.b << 16u) | (bytes.a << 24u);
			}
		]]):format(width * height, width, width),
	}
	local out = render.CreateBuffer{
		byte_size = width * height * 4,
		buffer_usage = {"storage_buffer"},
		memory_property = {"host_visible", "host_coherent"},
		label = "texture_compress_test_decode",
	}
	local cmd = render.GetCommandPool():AllocateCommandBuffer()
	cmd:Begin()
	pipeline:UpdateDescriptorSet("storage_buffer", 1, 0, 0, out, out:GetSize())
	pipeline:BindSampledImage(cmd, 1, 1, texture)
	pipeline.pipeline:Dispatch(cmd, math.ceil(width * height / 64), 1, 1, 1)
	cmd:PipelineBarrier{srcStage = "compute", dstStage = "host", memoryBarrier = true}
	cmd:End()
	render.SubmitAndWait(cmd)
	local copy = ffi.new("uint8_t[?]", width * height * 4)
	ffi.copy(copy, out:Map(), width * height * 4)
	out:Remove()
	return copy
end

T.Test3D("texture_compress blocks decode the same on the gpu as on the cpu", function()
	local width, height = 32, 32
	local pixels = make_image(width, height)

	for _, case in ipairs{{"bc7", {0, 1, 2, 3}}, {"bc5", {0, 1}}, {"bc4", {0}}} do
		local format = case[1]
		local file = texture_compress.Compress{
			pixels = pixels,
			width = width,
			height = height,
			format = format,
			kind = "linear",
			mips = false,
			channel = 1,
		}
		local cpu = decode_level(file, format, 1)
		local gpu = decode_on_gpu(file)
		local worst = 0

		for i = 0, width * height - 1 do
			for _, channel in ipairs(case[2]) do
				worst = math.max(worst, math.abs(cpu[i * 4 + channel] - gpu[i * 4 + channel]))
			end
		end

		T(worst <= 1)["=="](true)
	end
end)

T.Test3D("texture_compress recompress keeps a texture, edits it and blends sources on the gpu", function()
	local width, height = 64, 64
	local pixels = make_image(width, height)
	local source = texture_compress.Compress{
		pixels = pixels,
		width = width,
		height = height,
		format = "bc7",
		kind = "linear",
		mips = false,
	}
	local original = decode_level(source, "bc7", 1)
	local same = texture_compress.Recompress{sources = {source}, format = "bc7", kind = "linear", mips = false}
	local again = decode_level(same, "bc7", 1)
	T(psnr(again, original, width * height, {0, 1, 2}) > 42)["=="](true)
	local mipped = texture_compress.Recompress{sources = {source}, format = "bc7", kind = "linear"}
	local info = assert(codec.DecodeData("x.dds", mipped))
	T(info.mip_count)["=="](7)
	T(info.vulkan_format)["=="]("bc7_unorm_block")
	local halved = texture_compress.Recompress{
		sources = {source},
		format = "bc7",
		kind = "linear",
		mips = false,
		edit = "vec4 edit(ivec2 position, ivec2 size, vec4 texel) { return vec4(texel.rgb * edit_params[0], texel.a); }",
		params = {0.5},
	}
	local dimmed = decode_level(halved, "bc7", 1)
	local expected = ffi.new("uint8_t[?]", width * height * 4)

	for i = 0, width * height - 1 do
		for channel = 0, 2 do
			expected[i * 4 + channel] = original[i * 4 + channel] * 0.5
		end

		expected[i * 4 + 3] = 255
	end

	T(psnr(dimmed, expected, width * height, {0, 1, 2}) > 38)["=="](true)
	local solid = ffi.new("uint8_t[?]", width * height * 4)

	for i = 0, width * height - 1 do
		solid[i * 4], solid[i * 4 + 1], solid[i * 4 + 2], solid[i * 4 + 3] = 200, 100, 50, 255
	end

	local blended = texture_compress.Recompress{
		sources = {
			{pixels = pixels, width = width, height = height},
			{pixels = solid, width = width, height = height},
		},
		format = "bc7",
		kind = "linear",
		mips = false,
		edit = "vec4 edit(ivec2 position, ivec2 size, vec4 texel) { return mix(texel, fetch(1, position), 0.5); }",
	}
	local mixed = decode_level(blended, "bc7", 1)
	local target = ffi.new("uint8_t[?]", width * height * 4)

	for i = 0, width * height - 1 do
		for channel = 0, 2 do
			target[i * 4 + channel] = (pixels[i * 4 + channel] + solid[i * 4 + channel]) / 2
		end

		target[i * 4 + 3] = 255
	end

	T(psnr(mixed, target, width * height, {0, 1, 2}) > 36)["=="](true)
end)

T.Test3D("textures drop mips above r_max_texture_size", function()
	local fs = import("goluwa/filesystem/fs.lua")
	local pvars = import("goluwa/cli/pvars.lua")
	local Texture = import("goluwa/render/texture.lua")
	local source = texture_compress.Compress{
		pixels = make_image(64, 64),
		width = 64,
		height = 64,
		format = "bc7",
		kind = "linear",
	}
	local file = "storage/cache/test_max_texture_size.dds"
	fs.create_directory_recursive("storage/cache/")
	assert(fs.write_file(file, source))
	local widths = {}

	for _, limit in ipairs{0, 16, 1} do
		pvars.SetSession("r_max_texture_size", limit)
		Texture.ClearCache()
		local texture = Texture.New{path = file}

		T.WaitUntilReal(function()
			return texture:IsReady()
		end, 10, "the texture to load")

		widths[#widths + 1] = texture:GetImage().width .. ":" .. texture:GetMipMapLevels()
		texture:Remove()
	end

	pvars.SetSession("r_max_texture_size", 0)
	Texture.ClearCache()
	fs.remove_file(file)
	T(widths[1])["=="]("64:7")
	T(widths[2])["=="]("16:5")
	T(widths[3])["=="]("1:1")
end)

T.Test3D("streamed textures keep small mips and swap in bigger ones", function()
	local fs = import("goluwa/filesystem/fs.lua")
	local pvars = import("goluwa/cli/pvars.lua")
	local Texture = import("goluwa/render/texture.lua")
	local source = texture_compress.Compress{
		pixels = make_image(64, 64),
		width = 64,
		height = 64,
		format = "bc7",
		kind = "linear",
	}
	local file = "storage/cache/test_streamed_texture.dds"
	fs.create_directory_recursive("storage/cache/")
	assert(fs.write_file(file, source))
	pvars.SetSession("r_texture_stream_base_size", 8)
	pvars.SetSession("r_max_texture_size", 0)
	Texture.ClearCache()
	local texture = Texture.New{path = file, stream = true}

	T.WaitUntilReal(
		function()
			return texture:IsReady() and texture.stream ~= nil
		end,
		10,
		"the texture to load"
	)

	local stream = texture.stream
	T(texture:GetImage().width)["=="](8)
	T(texture:GetMipMapLevels())["=="](4)
	T(stream.drop)["=="](3)
	T(stream.bytes)["=="](stream.bytes_from[4])
	texture:RequestStreamLevel(1)

	T.WaitUntilReal(function()
		return stream.pending ~= nil
	end, 10, "the bigger mips to decode")

	texture:UploadStreamLevel(stream.pending, 1)
	stream.pending = nil
	T(texture:GetImage().width)["=="](8)

	T.WaitUntilReal(
		function()
			Texture.PollStreamUploads()
			return not stream.uploading
		end,
		10,
		"the upload to finish"
	)

	T(texture:GetImage().width)["=="](32)
	T(texture:GetMipMapLevels())["=="](6)
	T(stream.drop)["=="](1)
	T(stream.bytes)["=="](stream.bytes_from[2])
	texture:RequestStreamLevel(3)

	T.WaitUntilReal(function()
		return stream.pending ~= nil
	end, 10, "the smaller mips to decode")

	texture:UploadStreamLevel(stream.pending, 3)

	T.WaitUntilReal(
		function()
			Texture.PollStreamUploads()
			return not stream.uploading
		end,
		10,
		"the upload to finish"
	)

	T(texture:GetImage().width)["=="](8)
	texture:Remove()
	pvars.SetSession("r_texture_stream_base_size", 256)
	Texture.ClearCache()
	fs.remove_file(file)
end)
