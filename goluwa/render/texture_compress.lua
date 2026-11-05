local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local dds = import("goluwa/codecs/dds.lua")
local codec = import("goluwa/codec.lua")
local Texture = import("goluwa/render/texture.lua")
local texture_compress = {}
local float_array = ffi.typeof("float[?]")
local KINDS = {linear = 0, srgb = 1, normal = 2}
local GROUP_SIZE = 64
local declarations = [[
	layout(set = 0, binding = 0, std430) buffer Source { vec4 source[]; };
	layout(set = 0, binding = 1, std430) buffer Dest { uint dest[]; };
	layout(set = 0, binding = 2, std430) buffer Params { uint params[]; };
]]
local float_declarations = [[
	layout(set = 0, binding = 0, std430) buffer Source { vec4 source[]; };
	layout(set = 0, binding = 1, std430) buffer Dest { vec4 dest[]; };
	layout(set = 0, binding = 2, std430) buffer Params { uint params[]; };
]]
local block_common = [[
	vec4 load_texel(uint bx, uint by, uint i) {
		uint width = params[0];
		uint height = params[1];
		uint x = min(bx * 4u + (i & 3u), width - 1u);
		uint y = min(by * 4u + (i >> 2u), height - 1u);
		return source[y * width + x];
	}

	void put_bits(inout uvec4 block, uint position, uint value, uint count) {
		uint word = position >> 5u;
		uint shift = position & 31u;
		block[word] |= value << shift;

		if (shift + count > 32u) block[word + 1u] |= value >> (32u - shift);
	}
]]
local single_channel_code = [[
	// encodes one channel of the block as bc4, returns the 8 bytes as two uints
	uvec2 encode_channel(float values[16]) {
		float low = 1.0;
		float high = 0.0;

		for (int i = 0; i < 16; i++) {
			low = min(low, values[i]);
			high = max(high, values[i]);
		}

		float a0 = high;
		float a1 = low;
		int indices[16];
		int a0_byte = 0;
		int a1_byte = 0;

		for (int iteration = 0; iteration < 4; iteration++) {
			a0_byte = int(clamp(a0, 0.0, 1.0) * 255.0 + 0.5);
			a1_byte = int(clamp(a1, 0.0, 1.0) * 255.0 + 0.5);

			if (a0_byte < a1_byte) {
				int swap = a0_byte;
				a0_byte = a1_byte;
				a1_byte = swap;
			}

			float palette[8];
			palette[0] = float(a0_byte);
			palette[1] = float(a1_byte);

			if (a0_byte > a1_byte) {
				for (int i = 1; i <= 6; i++) palette[i + 1] = floor(float((7 - i) * a0_byte + i * a1_byte) / 7.0);
			} else {
				for (int i = 1; i <= 4; i++) palette[i + 1] = floor(float((5 - i) * a0_byte + i * a1_byte) / 5.0);
				palette[6] = 0.0;
				palette[7] = 255.0;
			}

			float a00 = 0.0;
			float a01 = 0.0;
			float a11 = 0.0;
			float b0 = 0.0;
			float b1 = 0.0;

			for (int i = 0; i < 16; i++) {
				float target = values[i] * 255.0;
				int best = 0;
				float best_error = 1e9;

				for (int k = 0; k < 8; k++) {
					float e = abs(palette[k] - target);

					if (e < best_error) {
						best_error = e;
						best = k;
					}
				}

				indices[i] = best;
				float t = best == 0 ? 0.0 : (best == 1 ? 1.0 : (a0_byte > a1_byte ? float(best - 1) / 7.0 : float(best - 1) / 5.0));
				a00 += (1.0 - t) * (1.0 - t);
				a01 += t * (1.0 - t);
				a11 += t * t;
				b0 += (1.0 - t) * values[i];
				b1 += t * values[i];
			}

			float det = a00 * a11 - a01 * a01;

			if (abs(det) < 1e-6) break;

			a0 = (a11 * b0 - a01 * b1) / det;
			a1 = (a00 * b1 - a01 * b0) / det;
		}

		a0_byte = int(clamp(a0, 0.0, 1.0) * 255.0 + 0.5);
		a1_byte = int(clamp(a1, 0.0, 1.0) * 255.0 + 0.5);

		if (a0_byte < a1_byte) {
			int swap = a0_byte;
			a0_byte = a1_byte;
			a1_byte = swap;
		}

		float palette[8];
		palette[0] = float(a0_byte);
		palette[1] = float(a1_byte);

		if (a0_byte > a1_byte) {
			for (int i = 1; i <= 6; i++) palette[i + 1] = floor(float((7 - i) * a0_byte + i * a1_byte) / 7.0);
		} else {
			for (int i = 1; i <= 4; i++) palette[i + 1] = floor(float((5 - i) * a0_byte + i * a1_byte) / 5.0);
			palette[6] = 0.0;
			palette[7] = 255.0;
		}

		uint low_bits = 0u;
		uint high_bits = 0u;

		for (int i = 0; i < 16; i++) {
			float target = values[i] * 255.0;
			int best = 0;
			float best_error = 1e9;

			for (int k = 0; k < 8; k++) {
				float e = abs(palette[k] - target);

				if (e < best_error) {
					best_error = e;
					best = k;
				}
			}

			if (i < 10) {
				low_bits |= uint(best) << uint(i * 3);
			} else {
				high_bits |= uint(best) << uint((i - 10) * 3);
			}
		}

		uint first = uint(a0_byte) | (uint(a1_byte) << 8u) | ((low_bits & 0xFFFFu) << 16u);
		uint second = (low_bits >> 16u) | (high_bits << 14u);
		return uvec2(first, second);
	}
]]
local bc7_code = [[
	const uint weights[16] = uint[16](0u, 4u, 9u, 13u, 17u, 21u, 26u, 30u, 34u, 38u, 43u, 47u, 51u, 55u, 60u, 64u);

	vec4 interpolate(vec4 e0, vec4 e1, uint weight) {
		return floor((float(64u - weight) * e0 + float(weight) * e1 + 32.0) / 64.0);
	}

	// 7 bit endpoint with a shared p bit: returns the 8 bit reconstruction, the p bit in .w of pbit
	vec4 quantize_endpoint(vec4 target, out uvec4 q, out uint pbit) {
		float best_error = 1e9;
		vec4 best = vec4(0.0);
		pbit = 0u;
		q = uvec4(0u);

		for (uint p = 0u; p < 2u; p++) {
			vec4 scaled = target * 255.0;
			vec4 q7 = clamp(floor((scaled - float(p)) / 2.0 + 0.5), 0.0, 127.0);
			vec4 recon = q7 * 2.0 + float(p);
			vec4 diff = (recon - scaled) * vec4(1.0, 1.0, 1.0, 4.0);
			float error = dot(diff, diff);

			if (error < best_error) {
				best_error = error;
				best = recon;
				q = uvec4(q7);
				pbit = p;
			}
		}

		return best;
	}

	void main() {
		uint id = gl_GlobalInvocationID.x;
		uint blocks_x = params[2];
		uint blocks_y = params[3];

		if (id >= blocks_x * blocks_y) return;

		uint bx = id % blocks_x;
		uint by = id / blocks_x;
		vec4 px[16];
		vec4 mean = vec4(0.0);
		vec4 low = vec4(1.0);
		vec4 high = vec4(0.0);

		for (uint i = 0u; i < 16u; i++) {
			px[i] = load_texel(bx, by, i);
			mean += px[i];
			low = min(low, px[i]);
			high = max(high, px[i]);
		}

		mean /= 16.0;
		mat4 covariance = mat4(0.0);

		for (int i = 0; i < 16; i++) {
			vec4 d = px[i] - mean;
			covariance += mat4(d * d.x, d * d.y, d * d.z, d * d.w);
		}

		vec4 axis = high - low;
		axis = dot(axis, axis) > 1e-12 ? normalize(axis) : vec4(1.0, 0.0, 0.0, 0.0);

		for (int i = 0; i < 4; i++) {
			vec4 next = covariance * axis;
			axis = dot(next, next) > 1e-12 ? normalize(next) : axis;
		}

		float t_low = 1e9;
		float t_high = -1e9;

		for (int i = 0; i < 16; i++) {
			float t = dot(px[i] - mean, axis);
			t_low = min(t_low, t);
			t_high = max(t_high, t);
		}

		vec4 e0 = clamp(mean + axis * t_low, 0.0, 1.0);
		vec4 e1 = clamp(mean + axis * t_high, 0.0, 1.0);
		uint indices[16];

		for (int iteration = 0; iteration < 4; iteration++) {
			vec4 p0 = e0 * 255.0;
			vec4 p1 = e1 * 255.0;
			float a00 = 0.0;
			float a01 = 0.0;
			float a11 = 0.0;
			vec4 b0 = vec4(0.0);
			vec4 b1 = vec4(0.0);

			for (int i = 0; i < 16; i++) {
				vec4 target = px[i] * 255.0;
				uint best = 0u;
				float best_error = 1e9;

				for (uint k = 0u; k < 16u; k++) {
					vec4 diff = interpolate(p0, p1, weights[k]) - target;
					float error = dot(diff, diff);

					if (error < best_error) {
						best_error = error;
						best = k;
					}
				}

				indices[i] = best;
				float t = float(weights[best]) / 64.0;
				a00 += (1.0 - t) * (1.0 - t);
				a01 += t * (1.0 - t);
				a11 += t * t;
				b0 += (1.0 - t) * px[i];
				b1 += t * px[i];
			}

			float det = a00 * a11 - a01 * a01;

			if (abs(det) < 1e-6) break;

			e0 = clamp((a11 * b0 - a01 * b1) / det, 0.0, 1.0);
			e1 = clamp((a00 * b1 - a01 * b0) / det, 0.0, 1.0);
		}

		uvec4 q0;
		uvec4 q1;
		uint pbit0;
		uint pbit1;
		vec4 r0 = quantize_endpoint(e0, q0, pbit0);
		vec4 r1 = quantize_endpoint(e1, q1, pbit1);

		for (int i = 0; i < 16; i++) {
			vec4 target = px[i] * 255.0;
			uint best = 0u;
			float best_error = 1e9;

			for (uint k = 0u; k < 16u; k++) {
				vec4 diff = interpolate(r0, r1, weights[k]) - target;
				float error = dot(diff, diff);

				if (error < best_error) {
					best_error = error;
					best = k;
				}
			}

			indices[i] = best;
		}

		if (indices[0] >= 8u) {
			uvec4 swap_q = q0;
			q0 = q1;
			q1 = swap_q;
			uint swap_p = pbit0;
			pbit0 = pbit1;
			pbit1 = swap_p;

			for (int i = 0; i < 16; i++) indices[i] = 15u - indices[i];
		}

		uvec4 block = uvec4(0u);
		put_bits(block, 0u, 0x40u, 7u);
		uint position = 7u;

		for (int channel = 0; channel < 4; channel++) {
			put_bits(block, position, q0[channel], 7u);
			put_bits(block, position + 7u, q1[channel], 7u);
			position += 14u;
		}

		put_bits(block, position, pbit0, 1u);
		put_bits(block, position + 1u, pbit1, 1u);
		position += 2u;

		for (int i = 0; i < 16; i++) {
			uint count = i == 0 ? 3u : 4u;
			put_bits(block, position, indices[i], count);
			position += count;
		}

		dest[id * 4u] = block.x;
		dest[id * 4u + 1u] = block.y;
		dest[id * 4u + 2u] = block.z;
		dest[id * 4u + 3u] = block.w;
	}
]]
local downsample_code = [[
	float to_linear(float c) {
		return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4);
	}

	float from_linear(float c) {
		return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1.0 / 2.4) - 0.055;
	}

	void main() {
		uint src_width = params[0];
		uint src_height = params[1];
		uint dst_width = params[2];
		uint dst_height = params[3];
		uint kind = params[4];
		uint wrap = params[5];
		uint id = gl_GlobalInvocationID.x;

		if (id >= dst_width * dst_height) return;

		uint x = id % dst_width;
		uint y = id / dst_width;
		vec4 sum = vec4(0.0);

		for (uint i = 0u; i < 4u; i++) {
			uint sx = x * 2u + (i & 1u);
			uint sy = y * 2u + (i >> 1u);
			sx = wrap == 1u ? sx % src_width : min(sx, src_width - 1u);
			sy = wrap == 1u ? sy % src_height : min(sy, src_height - 1u);
			vec4 texel = source[sy * src_width + sx];

			if (kind == 1u) {
				texel.rgb = vec3(to_linear(texel.r), to_linear(texel.g), to_linear(texel.b));
			} else if (kind == 2u) {
				vec2 xy = texel.xy * 2.0 - 1.0;
				texel.xyz = vec3(xy, sqrt(max(1.0 - dot(xy, xy), 0.0)));
			}

			sum += texel;
		}

		vec4 average = sum / 4.0;

		if (kind == 1u) {
			average.rgb = vec3(from_linear(average.r), from_linear(average.g), from_linear(average.b));
		} else if (kind == 2u) {
			vec3 n = normalize(average.xyz);
			average.xyz = vec3(n.xy * 0.5 + 0.5, n.z * 0.5 + 0.5);
		}

		dest[id] = average;
	}
]]
local pipelines = {}

local function get_pipeline(name, declaration_code, shader)
	if not pipelines[name] then
		pipelines[name] = EasyPipeline.Compute{
			name = "texture_compress_" .. name,
			DescriptorSetCount = 1,
			LocalSize = {x = GROUP_SIZE, y = 1, z = 1},
			storage_buffers = {{binding_index = 0}, {binding_index = 1}, {binding_index = 2}},
			custom_declarations = declaration_code,
			shader = shader,
		}
	end

	return pipelines[name]
end

local function create_buffer(size, readback)
	return render.CreateBuffer{
		byte_size = size,
		buffer_usage = {"storage_buffer"},
		memory_property = readback and
			{"host_visible", "host_coherent", "host_cached"} or
			{"host_visible", "host_coherent"},
		label = "texture_compress",
	}
end

local function run(pipeline, source, dest, params, thread_count)
	local param_buffer = create_buffer(#params * 4)
	local mapped = ffi.cast("uint32_t*", param_buffer:Map())

	for i, value in ipairs(params) do
		mapped[i - 1] = value
	end

	pipeline:UpdateDescriptorSet("storage_buffer", 1, 0, 0, source, source:GetSize())
	pipeline:UpdateDescriptorSet("storage_buffer", 1, 1, 0, dest, dest:GetSize())
	pipeline:UpdateDescriptorSet("storage_buffer", 1, 2, 0, param_buffer, param_buffer:GetSize())
	local cmd = render.GetCommandPool():AllocateCommandBuffer()
	cmd:Begin()
	pipeline.pipeline:Dispatch(cmd, math.ceil(thread_count / GROUP_SIZE), 1, 1, 1)
	cmd:PipelineBarrier{srcStage = "compute", dstStage = "host", memoryBarrier = true}
	cmd:End()
	render.SubmitAndWait(cmd)
	param_buffer:Remove()
end

local function get_encoder(format)
	if format == "bc7" then
		return get_pipeline("bc7", declarations, block_common .. bc7_code), 16
	elseif format == "bc5" then
		return get_pipeline(
			"bc5",
			declarations,
			block_common .. single_channel_code .. [[
				void main() {
					uint id = gl_GlobalInvocationID.x;
					uint blocks_x = params[2];

					if (id >= blocks_x * params[3]) return;

					uint bx = id % blocks_x;
					uint by = id / blocks_x;
					float red[16];
					float green[16];

					for (uint i = 0u; i < 16u; i++) {
						vec4 texel = load_texel(bx, by, i);
						red[i] = texel.r;
						green[i] = texel.g;
					}

					uvec2 r = encode_channel(red);
					uvec2 g = encode_channel(green);
					dest[id * 4u] = r.x;
					dest[id * 4u + 1u] = r.y;
					dest[id * 4u + 2u] = g.x;
					dest[id * 4u + 3u] = g.y;
				}
			]]
		),
		16
	end

	return get_pipeline(
		"bc4",
		declarations,
		block_common .. single_channel_code .. [[
			void main() {
				uint id = gl_GlobalInvocationID.x;
				uint blocks_x = params[2];

				if (id >= blocks_x * params[3]) return;

				uint bx = id % blocks_x;
				uint by = id / blocks_x;
				uint channel = params[4];
				float values[16];

				for (uint i = 0u; i < 16u; i++) {
					values[i] = load_texel(bx, by, i)[channel];
				}

				uvec2 packed_block = encode_channel(values);
				dest[id * 2u] = packed_block.x;
				dest[id * 2u + 1u] = packed_block.y;
			}
		]]
	),
	8
end

-- takes over `current`, a level 0 buffer of width * height rgba floats, builds the mips and encodes
-- every level, returns the dds
local function encode_chain(current, width, height, config)
	local format = config.format
	local kind = config.kind or "linear"
	local pipeline, block_bytes = get_encoder(format)
	local down_pipeline = get_pipeline("downsample", float_declarations, downsample_code)
	local level_count = config.mips == false and
		1 or
		math.floor(math.log(math.max(width, height)) / math.log(2)) + 1
	local levels = {}
	local level_width, level_height = width, height

	for level = 1, level_count do
		local blocks_x, blocks_y = math.ceil(level_width / 4), math.ceil(level_height / 4)
		local blocks = create_buffer(blocks_x * blocks_y * block_bytes, true)
		run(
			pipeline,
			current,
			blocks,
			{level_width, level_height, blocks_x, blocks_y, config.channel or 0},
			blocks_x * blocks_y
		)
		levels[level] = ffi.string(blocks:Map(), blocks_x * blocks_y * block_bytes)
		blocks:Remove()

		if level < level_count then
			local next_width, next_height = math.max(level_width / 2, 1), math.max(level_height / 2, 1)
			next_width, next_height = math.floor(next_width), math.floor(next_height)
			local next_buffer = create_buffer(next_width * next_height * 16)
			run(
				down_pipeline,
				current,
				next_buffer,
				{
					level_width,
					level_height,
					next_width,
					next_height,
					KINDS[kind],
					config.wrap and
					1 or
					0,
				},
				next_width * next_height
			)
			current:Remove()
			current = next_buffer
			level_width, level_height = next_width, next_height
		end
	end

	current:Remove()
	local name = format == "bc7" and
		(
			kind == "srgb" and
			"BC7_UNORM_SRGB" or
			"BC7_UNORM"
		)
		or
		(
			format == "bc5" and
			"BC5_UNORM" or
			"BC4_UNORM"
		)
	return dds.Encode(name, width, height, levels)
end

-- Encodes an image into block compressed mips on the gpu and returns a ready dds file as a string.
-- config: pixels (r8g8b8a8, width * height * 4 bytes), width, height, format ("bc7", "bc5" or "bc4"),
-- kind ("srgb", "linear" or "normal": how mips are filtered, srgb also marks the format),
-- mips (default true), wrap (mips wrap around, for tiling textures), channel (bc4: 0 to 3)
function texture_compress.Compress(config)
	local width, height = config.width, config.height
	local current = create_buffer(width * height * 16)
	local floats = ffi.cast("float*", current:Map())

	for i = 0, width * height * 4 - 1 do
		floats[i] = config.pixels[i] / 255
	end

	return encode_chain(current, width, height, config)
end

local MAX_SOURCES = 4
local EDIT_PARAM_COUNT = 16
local edit_header = [[
	layout(set = 0, binding = 0, std430) buffer Dest { vec4 dest[]; };
	layout(set = 0, binding = 1, std430) buffer EditParams { float edit_params[]; };
	layout(set = 0, binding = 2) uniform sampler2D source_0;
	layout(set = 0, binding = 3) uniform sampler2D source_1;
	layout(set = 0, binding = 4) uniform sampler2D source_2;
	layout(set = 0, binding = 5) uniform sampler2D source_3;
]]
local edit_helpers = [[
	vec4 fetch(int index, ivec2 position) {
		ivec2 size = textureSize(source_0, 0);

		if (index == 1) size = textureSize(source_1, 0);
		else if (index == 2) size = textureSize(source_2, 0);
		else if (index == 3) size = textureSize(source_3, 0);

		position = clamp(position, ivec2(0), size - 1);

		if (index == 1) return texelFetch(source_1, position, 0);
		if (index == 2) return texelFetch(source_2, position, 0);
		if (index == 3) return texelFetch(source_3, position, 0);

		return texelFetch(source_0, position, 0);
	}

	ivec2 source_size(int index) {
		if (index == 1) return textureSize(source_1, 0);
		if (index == 2) return textureSize(source_2, 0);
		if (index == 3) return textureSize(source_3, 0);

		return textureSize(source_0, 0);
	}

	float to_linear(float c) {
		return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4);
	}

	float from_linear(float c) {
		return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1.0 / 2.4) - 0.055;
	}

	vec3 to_linear(vec3 c) {
		return vec3(to_linear(c.r), to_linear(c.g), to_linear(c.b));
	}

	vec3 from_linear(vec3 c) {
		return vec3(from_linear(c.r), from_linear(c.g), from_linear(c.b));
	}
]]
local edit_main = [[
	void main() {
		ivec2 size = source_size(0);
		uint id = gl_GlobalInvocationID.x;

		if (id >= uint(size.x * size.y)) return;

		ivec2 position = ivec2(int(id % uint(size.x)), int(id / uint(size.x)));
		dest[id] = edit(position, size, fetch(0, position));
	}
]]
local default_edit = "vec4 edit(ivec2 position, ivec2 size, vec4 texel) { return texel; }"
local edit_pipelines = {}
local edit_pipeline_count = 0

local function get_edit_pipeline(edit)
	local pipeline = edit_pipelines[edit]

	if not pipeline then
		edit_pipeline_count = edit_pipeline_count + 1
		local sampled = {}

		for i = 1, MAX_SOURCES do
			sampled[i] = {binding_index = i + 1}
		end

		pipeline = EasyPipeline.Compute{
			name = "texture_compress_edit_" .. edit_pipeline_count,
			DescriptorSetCount = 1,
			LocalSize = {x = GROUP_SIZE, y = 1, z = 1},
			storage_buffers = {{binding_index = 0}, {binding_index = 1}},
			sampled_images = sampled,
			custom_declarations = edit_header,
			shader = edit_helpers .. edit .. "\n" .. edit_main,
		}
		edit_pipelines[edit] = pipeline
	end

	return pipeline
end

-- the gpu's own block decoder reads a source as a texture. Raw values are wanted, not the
-- srgb decoded ones, so an srgb format is read as its unorm twin
local function create_source_texture(source)
	if source.texture then
		return source.texture, source.texture:GetWidth(), source.texture:GetHeight()
	end

	if source.pixels then
		return Texture.New{
			buffer = source.pixels,
			width = source.width,
			height = source.height,
			format = "r8g8b8a8_unorm",
		},
		source.width,
		source.height
	end

	local info = assert(codec.DecodeData("source.dds", source.dds or source))
	info.vulkan_format = info.vulkan_format:gsub("_srgb", "_unorm")
	return Texture.New{decoded = info}, info.width, info.height
end

-- Decodes one or more sources on the gpu, runs an edit over every texel and encodes the result,
-- never leaving the gpu in between. Returns a ready dds file as a string.
-- config: sources (a list, each a dds string, {pixels, width, height} with r8g8b8a8 pixels or {texture}
-- for a Texture that is already on the gpu (an srgb texture reads as linear light); the output
-- is the size of the first), edit (glsl defining `vec4 edit(ivec2 position, ivec2 size, vec4 texel)`,
-- texel being the first source's raw value: encoded, not linear, and bc5 sources have no blue),
-- params (up to 16 floats, `edit_params[i]` in the glsl), then the same as Compress
-- Available to the glsl: fetch(index, position) and source_size(index) for the other sources,
-- to_linear/from_linear for floats and vec3.
function texture_compress.Recompress(config)
	local sources = config.sources
	assert(#sources >= 1 and #sources <= MAX_SOURCES, "one to four sources")
	local pipeline = get_edit_pipeline(config.edit or default_edit)
	local source_textures = {}
	local width, height

	for i, source in ipairs(sources) do
		local texture, source_width, source_height = create_source_texture(source)
		source_textures[i] = texture

		if i == 1 then width, height = source_width, source_height end
	end

	local dest = create_buffer(width * height * 16)
	local param_buffer = create_buffer(EDIT_PARAM_COUNT * 4)
	local mapped = ffi.cast("float*", param_buffer:Map())

	for i = 0, EDIT_PARAM_COUNT - 1 do
		mapped[i] = (config.params and config.params[i + 1]) or 0
	end

	local cmd = render.GetCommandPool():AllocateCommandBuffer()
	cmd:Begin()
	pipeline:UpdateDescriptorSet("storage_buffer", 1, 0, 0, dest, dest:GetSize())
	pipeline:UpdateDescriptorSet("storage_buffer", 1, 1, 0, param_buffer, param_buffer:GetSize())

	for i = 1, MAX_SOURCES do
		pipeline:BindSampledImage(cmd, 1, i + 1, source_textures[i] or source_textures[1])
	end

	pipeline.pipeline:Dispatch(cmd, math.ceil(width * height / GROUP_SIZE), 1, 1, 1)
	cmd:PipelineBarrier{srcStage = "compute", dstStage = "compute", memoryBarrier = true}
	cmd:End()
	render.SubmitAndWait(cmd)
	param_buffer:Remove()
	return encode_chain(dest, width, height, config)
end

return texture_compress
