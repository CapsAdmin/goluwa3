local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local Texture = import("goluwa/render/texture.lua")
local render = import("goluwa/render/render.lua")
local optical_flow = {}
optical_flow.LEVELS = 7
optical_flow.BLOCK_SIZE = 8
local SLOTS_PER_FRAME = 48
local MAX_FRAMES = 9
local HISTOGRAM_BINS = 256
local HISTOGRAMS = 9
local state = {frame_index = 0, frame_parity = 0}
local resources = {}
local pipelines = {}
local PUSH_BLOCK = {
	{"display_width", "int"},
	{"display_height", "int"},
	{"level", "int"},
	{"level_count", "int"},
	{"frame_index", "int"},
	{"parity", "int"},
	{"scene_tex", "int"},
}

local function write_push(self, block)
	block.display_width = resources.width
	block.display_height = resources.height
	block.level = state.level
	block.level_count = optical_flow.LEVELS
	block.frame_index = state.frame_index
	block.parity = state.frame_parity
	block.scene_tex = state.scene and self:GetTextureIndex(state.scene) or -1
	return block
end

local COMMON_GLSL = [[
	ivec2 display_size() {
		return ivec2(compute.display_width, compute.display_height);
	}

	ivec2 luma_size() {
		return max(display_size() >> compute.level, ivec2(1));
	}

	uint sad(uint a, uint b) {
		return uint(abs(int(a & 0xffu) - int(b & 0xffu)) + abs(int((a >> 8) & 0xffu) - int((b >> 8) & 0xffu)) + abs(int((a >> 16) & 0xffu) - int((b >> 16) & 0xffu)) + abs(int(a >> 24) - int(b >> 24)));
	}

	uvec4 qsad(uint a0, uint a1, uint b) {
		uvec4 result;
		result.x = sad(a0, b);
		a0 = (a0 >> 8) | ((a1 & 0xffu) << 24);
		a1 >>= 8;
		result.y = sad(a0, b);
		a0 = (a0 >> 8) | ((a1 & 0xffu) << 24);
		a1 >>= 8;
		result.z = sad(a0, b);
		a0 = (a0 >> 8) | ((a1 & 0xffu) << 24);
		result.w = sad(a0, b);
		return result;
	}

	uint packed_luma(int width, int x, uint l0, uint l1, uint l2, uint l3) {
		uint packed = l0 | (l1 << 8) | (l2 << 16) | (l3 << 24);

		if (x < 0) {
			uint filler = packed & 0xffu;

			if (x <= -1) packed = (packed << 8) | filler;

			if (x <= -2) packed = (packed << 8) | filler;

			if (x <= -3) packed = (packed << 8) | filler;
		} else if (x > width - 4) {
			uint filler = packed & 0xff000000u;

			if (x >= width - 3) packed = (packed >> 8) | filler;

			if (x >= width - 2) packed = (packed >> 8) | filler;

			if (x >= width - 1) packed = (packed >> 8) | filler;
		}

		return packed;
	}

	uint load_packed(bool second, ivec2 p) {
		ivec2 size = luma_size();
		ivec2 q = ivec2(clamp(p.x, 0, size.x - 4), clamp(p.y, 0, size.y - 1));
		uint l0 = second ? imageLoad(previous_luma, q).r : imageLoad(current_luma, q).r;
		uint l1 = second ? imageLoad(previous_luma, q + ivec2(1, 0)).r : imageLoad(current_luma, q + ivec2(1, 0)).r;
		uint l2 = second ? imageLoad(previous_luma, q + ivec2(2, 0)).r : imageLoad(current_luma, q + ivec2(2, 0)).r;
		uint l3 = second ? imageLoad(previous_luma, q + ivec2(3, 0)).r : imageLoad(current_luma, q + ivec2(3, 0)).r;
		return packed_luma(size.x, p.x, max(l0, 1u), max(l1, 1u), max(l2, 1u), max(l3, 1u));
	}

	bool is_scene_changed() {
		return compute.frame_index <= 5 || (imageLoad(scd_output, ivec2(1, 0)).r & 0xfu) != 0u;
	}
]]

local function get_pipeline(name, local_size, declarations, shader)
	if pipelines[name] then return pipelines[name] end

	local storage_images = {}

	for binding in declarations:gmatch("binding = (%d+)") do
		storage_images[#storage_images + 1] = {binding_index = tonumber(binding)}
	end

	pipelines[name] = EasyPipeline.Compute{
		name = "optical_flow_" .. name,
		DescriptorSetCount = MAX_FRAMES * SLOTS_PER_FRAME,
		LocalSize = local_size,
		storage_images = storage_images,
		block = PUSH_BLOCK,
		write = write_push,
		custom_declarations = declarations,
		shader = shader,
	}
	return pipelines[name]
end

local CLEAR_DECLARATIONS = [[
	layout(set = 0, binding = 0, r32ui) uniform writeonly uimage2D histogram;
]]
local CLEAR_SHADER = [[
	void main() {
		imageStore(histogram, ivec2(gl_GlobalInvocationID.x, 0), uvec4(0u));
	}
]]
local LUMA_DECLARATIONS = [[
	layout(set = 0, binding = 0, r32ui) uniform writeonly uimage2D luma;
]]
local LUMA_SHADER = [[
	void main() {
		ivec2 p = ivec2(gl_GlobalInvocationID.xy);

		if (any(greaterThanEqual(p, ivec2(compute.display_width, compute.display_height)))) return;

		vec3 c = texelFetch(TEXTURE(compute.scene_tex), p, 0).rgb;
		imageStore(luma, p, uvec4(uint(clamp(dot(c, vec3(0.2126, 0.7152, 0.0722)), 0.0, 1.0) * 255.0)));
	}
]]
local PYRAMID_DECLARATIONS = [[
	layout(set = 0, binding = 0, r32ui) uniform readonly uimage2D source;
	layout(set = 0, binding = 1, r32ui) uniform writeonly uimage2D target;
]]
local PYRAMID_SHADER = [[
	void main() {
		ivec2 p = ivec2(gl_GlobalInvocationID.xy);

		if (any(greaterThanEqual(p, imageSize(target)))) return;

		ivec2 size = imageSize(source) - 1;
		uint sum = imageLoad(source, min(p * 2, size)).r + imageLoad(source, min(p * 2 + ivec2(1, 0), size)).r + imageLoad(source, min(p * 2 + ivec2(0, 1), size)).r + imageLoad(source, min(p * 2 + ivec2(1, 1), size)).r;
		imageStore(target, p, uvec4(sum / 4u));
	}
]]
local HISTOGRAM_DECLARATIONS = [[
	layout(set = 0, binding = 0, r32ui) uniform readonly uimage2D current_luma;
	layout(set = 0, binding = 1, r32ui) uniform uimage2D histogram;
]]
local HISTOGRAM_SHADER = [[
	const uint LBASE = 10u;
	shared uint scd_buffer[256 * 10];

	void main() {
		uint local_index = gl_LocalInvocationIndex;
		uint div_x = uint(compute.display_width) / 3u;
		uint div_y = uint(compute.display_height) / 3u;
		uint nx = gl_GlobalInvocationID.z % 3u;
		uint ny = gl_GlobalInvocationID.z / 3u;
		uint start_x = div_x * nx;
		uint start_y = div_y * ny;
		uint stop_x = start_x + div_x;
		uint stop_y = start_y + div_y;
		uint offset = local_index * LBASE;

		for (uint i = 0u; i < LBASE; i++) {
			scd_buffer[offset + i] = 0u;
		}

		barrier();
		ivec2 coord = ivec2(start_x + 4u * gl_GlobalInvocationID.x, start_y + gl_GlobalInvocationID.y);

		if (uint(coord.x) < stop_x) {
			for (; uint(coord.y) < stop_y; coord.y += 128) {
				uvec4 color = uvec4(imageLoad(current_luma, coord).r, imageLoad(current_luma, coord + ivec2(1, 0)).r, imageLoad(current_luma, coord + ivec2(2, 0)).r, imageLoad(current_luma, coord + ivec2(3, 0)).r) * LBASE;
				uint scramble = local_index % LBASE;
				atomicAdd(scd_buffer[color.x + scramble], 1u);
				atomicAdd(scd_buffer[color.y + scramble], 1u);
				atomicAdd(scd_buffer[color.z + scramble], 1u);
				atomicAdd(scd_buffer[color.w + scramble], 1u);
			}
		}

		barrier();
		uint value = 0u;

		for (uint i = 0u; i < LBASE; i++) {
			value += scd_buffer[offset + i];
		}

		imageAtomicAdd(histogram, ivec2(256u * gl_GlobalInvocationID.z + local_index, 0), value);
	}
]]
local DIVERGENCE_DECLARATIONS = [[
	layout(set = 0, binding = 0, r32ui) uniform coherent uimage2D histogram;
	layout(set = 0, binding = 1, r32f) uniform readonly image2D previous_histogram;
	layout(set = 0, binding = 2, r32f) uniform writeonly image2D next_histogram;
	layout(set = 0, binding = 3, r32ui) uniform coherent uimage2D scd_temp;
	layout(set = 0, binding = 4, r32ui) uniform coherent uimage2D scd_output;
]]
local DIVERGENCE_SHADER = [[
	const float FACTOR = 1000000.0;
	const uint WHERE_TO_STOP = 3u * 9u - 1u;
	const float KERNEL[6] = float[6](0.0088122291, 0.027143577, 0.065114059, 0.12164907, 0.17699835, 0.20056541);
	shared float source_histogram[256];
	shared float filtered_histogram[256];
	shared float temp_buffer[256];
	shared vec2 temp_buffer2[256];

	void main() {
		int local_index = int(gl_LocalInvocationIndex);
		int global_x = int(gl_GlobalInvocationID.x);
		int shift = int(gl_GlobalInvocationID.y);
		source_histogram[local_index] = float(imageLoad(histogram, ivec2(global_x, 0)).r);
		barrier();
		int index = local_index - 5;
		float value = 1.0;

		for (int k = 0; k < 11; k++) {
			value += KERNEL[k < 6 ? k : 10 - k] * source_histogram[clamp(index + k, 0, 255)];
		}

		if (shift == 0) {
			if (local_index == 0) {
				filtered_histogram[255] = 1.0;
			} else {
				filtered_histogram[local_index - 1] = value;
			}
		} else if (shift == 1) {
			filtered_histogram[local_index] = value;
		} else {
			if (local_index == 255) {
				filtered_histogram[0] = 1.0;
			} else {
				filtered_histogram[local_index + 1] = value;
			}
		}

		barrier();
		temp_buffer[local_index] = filtered_histogram[local_index];
		barrier();

		for (int stride = 128; stride > 0; stride >>= 1) {
			if (local_index < stride) temp_buffer[local_index] += temp_buffer[local_index + stride];

			barrier();
		}

		filtered_histogram[local_index] /= temp_buffer[0];
		float current = filtered_histogram[local_index];
		float previous = imageLoad(previous_histogram, ivec2(global_x, 0)).r;
		temp_buffer2[local_index] = vec2(current * log(current / previous), previous * log(previous / current));
		barrier();

		for (int stride = 128; stride > 0; stride >>= 1) {
			if (local_index < stride) temp_buffer2[local_index] += temp_buffer2[local_index + stride];

			barrier();
		}

		if (local_index == 0) {
			vec2 sum = temp_buffer2[0];
			float result = 1.0 - exp(-(abs(sum.x) + abs(sum.y)));
			imageAtomicAdd(scd_temp, ivec2(shift, 0), uint(result / 9.0 * FACTOR));
			memoryBarrierImage();
			uint finished = imageAtomicAdd(scd_output, ivec2(2, 0), 1u);

			if (finished == WHERE_TO_STOP) {
				uint r0 = imageAtomicAdd(scd_temp, ivec2(0, 0), 0u);
				uint r1 = imageAtomicAdd(scd_temp, ivec2(1, 0), 0u);
				uint r2 = imageAtomicAdd(scd_temp, ivec2(2, 0), 0u);
				float scene_change = float(min(r0, min(r1, r2))) / FACTOR;
				uint history = imageAtomicAdd(scd_output, ivec2(1, 0), 0u) << 1;

				if (scene_change > 0.45) history |= 1u;

				imageStore(scd_output, ivec2(0, 0), uvec4(floatBitsToUint(scene_change)));
				imageStore(scd_output, ivec2(1, 0), uvec4(history));
				imageStore(scd_output, ivec2(2, 0), uvec4(0u));
				imageStore(scd_temp, ivec2(0, 0), uvec4(0u));
				imageStore(scd_temp, ivec2(1, 0), uvec4(0u));
				imageStore(scd_temp, ivec2(2, 0), uvec4(0u));
			}
		}

		if (shift == 1) imageStore(next_histogram, ivec2(global_x, 0), vec4(current));
	}
]]
local SEARCH_DECLARATIONS = [[
	layout(set = 0, binding = 0, r32ui) uniform readonly uimage2D current_luma;
	layout(set = 0, binding = 1, r32ui) uniform readonly uimage2D previous_luma;
	layout(set = 0, binding = 2, rg32i) uniform iimage2D flow;
	layout(set = 0, binding = 3, r32ui) uniform readonly uimage2D scd_output;
]]
local SEARCH_SHADER = COMMON_GLSL .. [[
	const int COMPARE_SIZE = 8;
	const int SEARCH_RADIUS = 8;
	const int SEARCH_BUFFER_WIDTH = (COMPARE_SIZE + SEARCH_RADIUS * 2) / 4;
	const int SEARCH_BUFFER_HEIGHT = COMPARE_SIZE + SEARCH_RADIUS * 2;
	shared uint pixels[COMPARE_SIZE][COMPARE_SIZE / 4];
	shared uint search_buffer[SEARCH_BUFFER_HEIGHT * SEARCH_BUFFER_WIDTH];
	shared uint reduction[64];

	uint encode_search_coord(ivec2 coord) {
		uvec2 a = uvec2(abs(coord - 8));
		return (a.y << 12) | (a.x << 8) | uint(coord.y << 4) | uint(coord.x);
	}

	ivec2 decode_search_coord(uint bits) {
		return ivec2(int(bits & 0xfu) - SEARCH_RADIUS, int((bits >> 4) & 0xfu) - SEARCH_RADIUS);
	}

	void main() {
		int local_index = int(gl_LocalInvocationIndex);
		ivec2 group = ivec2(gl_WorkGroupID.xy);
		ivec2 search_id = ivec2(local_index & 3, (local_index >> 2) & 15);
		int lane_block = ((local_index >> 1) & 1) | (((local_index >> 5) & 1) << 1);
		ivec2 pixel = (group << 4) + search_id * ivec2(4, 1);
		ivec2 group_flow = group << 1;
		ivec2 flow_size = imageSize(flow);

		if (is_scene_changed()) {
			if ((search_id.y & 7) == 0 && (search_id.x & 1) == 0) {
				ivec2 q = pixel >> 3;

				if (all(lessThan(q, flow_size))) imageStore(flow, q, ivec4(0));
			}

			return;
		}

		bool use_prediction = compute.level != compute.level_count - 1;
		uint luma4 = load_packed(false, pixel);
		uint sad4 = sad(luma4, load_packed(true, pixel));

		for (int by = 0; by < 2; by++) {
			for (int bx = 0; bx < 2; bx++) {
				ivec2 block = ivec2(bx, by);
				ivec2 flow_pos = group_flow + block;
				bool flow_inside = all(lessThan(flow_pos, flow_size));
				ivec2 current_vector = use_prediction && flow_inside ? imageLoad(flow, flow_pos).xy : ivec2(0);
				barrier();

				if (lane_block == by * 2 + bx) pixels[search_id.y & 7][search_id.x & 1] = luma4;

				ivec2 base = (group << 4) + block * 8 + current_vector - ivec2(SEARCH_RADIUS);

				for (int id = local_index; id < SEARCH_BUFFER_WIDTH * SEARCH_BUFFER_HEIGHT; id += 64) {
					search_buffer[id] = load_packed(true, base + ivec2((id % SEARCH_BUFFER_WIDTH) * 4, id / SEARCH_BUFFER_WIDTH));
				}

				barrier();
				uvec4 sads = uvec4(0u);

				for (int dy = 0; dy < COMPARE_SIZE; dy++) {
					int row = (search_id.y + dy) * SEARCH_BUFFER_WIDTH;
					uint a0 = search_buffer[row + search_id.x];
					uint a1 = search_buffer[row + search_id.x + 1];
					uint a2 = search_buffer[row + search_id.x + 2];
					sads += qsad(a0, a1, pixels[dy][0]) + qsad(a1, a2, pixels[dy][1]);
				}

				uint best = min(
					min((sads.x << 16) | encode_search_coord(ivec2(search_id.x * 4 + 0, search_id.y)), (sads.y << 16) | encode_search_coord(ivec2(search_id.x * 4 + 1, search_id.y))),
					min((sads.z << 16) | encode_search_coord(ivec2(search_id.x * 4 + 2, search_id.y)), (sads.w << 16) | encode_search_coord(ivec2(search_id.x * 4 + 3, search_id.y)))
				);
				reduction[local_index] = best;
				barrier();

				for (int stride = 32; stride > 0; stride >>= 1) {
					if (local_index < stride) reduction[local_index] = min(reduction[local_index], reduction[local_index + stride]);

					barrier();
				}

				uint min_sad = reduction[0];
				barrier();
				reduction[local_index] = lane_block == by * 2 + bx ? sad4 : 0u;
				barrier();

				for (int stride = 32; stride > 0; stride >>= 1) {
					if (local_index < stride) reduction[local_index] += reduction[local_index + stride];

					barrier();
				}

				uint block_sad = reduction[0];
				ivec2 new_vector = current_vector + decode_search_coord(min_sad);

				if (compute.level == 0 && block_sad <= (min_sad >> 16)) new_vector = ivec2(0);

				barrier();

				if (local_index == 0 && flow_inside) imageStore(flow, flow_pos, ivec4(new_vector, 0, 0));
			}
		}
	}
]]
local FILTER_DECLARATIONS = [[
	layout(set = 0, binding = 0, rg32i) uniform readonly iimage2D source_flow;
	layout(set = 0, binding = 1, rg32i) uniform writeonly iimage2D target_flow;
]]
local FILTER_SHADER = [[
	void main() {
		ivec2 p = ivec2(gl_GlobalInvocationID.xy);
		ivec2 size = imageSize(source_flow);

		if (any(greaterThanEqual(p, size))) return;

		ivec2 vectors[9];
		int idx = 0;

		for (int x = -1; x < 2; x++) {
			for (int y = -1; y < 2; y++) {
				ivec2 q = p + ivec2(x, y);
				vectors[idx] = all(lessThan(uvec2(q), uvec2(size))) ? imageLoad(source_flow, q).xy : ivec2(0);
				idx++;
			}
		}

		uint best = 0xFFFFFFFFu;

		for (int i = 0; i < 9; i++) {
			uint total = 0u;

			for (int j = 0; j < 9; j++) {
				ivec2 delta = vectors[i] - vectors[j];
				total = uint(delta.x * delta.x) + uint(delta.y * delta.y) + total;
			}

			best = min((total << 4) | uint(i), best);
		}

		imageStore(target_flow, p, ivec4(vectors[best & 0xFu], 0, 0));
	}
]]
local SCALE_DECLARATIONS = [[
	layout(set = 0, binding = 0, r32ui) uniform readonly uimage2D current_luma;
	layout(set = 0, binding = 1, r32ui) uniform readonly uimage2D previous_luma;
	layout(set = 0, binding = 2, rg32i) uniform readonly iimage2D source_flow;
	layout(set = 0, binding = 3, rg32i) uniform writeonly iimage2D next_flow;
	layout(set = 0, binding = 4, r32ui) uniform readonly uimage2D scd_output;
]]
local SCALE_SHADER = COMMON_GLSL .. [[
	shared ivec2 nearest_vectors[4][4][4];
	shared uint local_region[4][4][4];
	shared uint sads[4][4][4];

	void main() {
		ivec3 gid = ivec3(gl_GlobalInvocationID);
		ivec3 lid = ivec3(gl_LocalInvocationID);
		bool inside = all(lessThan(gid.xy, imageSize(next_flow)));
		bool scene_changed = is_scene_changed();
		int x_offset = (lid.z % 2) - 1 + gid.x % 2;
		int y_offset = (lid.z / 2) - 1 + gid.y % 2;
		ivec2 source_pos = clamp(ivec2(gid.x / 2 + x_offset, gid.y / 2 + y_offset), ivec2(0), imageSize(source_flow) - 1);
		ivec2 nearest = imageLoad(source_flow, source_pos).xy;
		nearest_vectors[lid.z][lid.y][lid.x] = nearest * 2;
		local_region[lid.z][lid.y][lid.x] = load_packed(false, ivec2(gid.x * 4, gid.y * 4 + lid.z));
		barrier();
		uint total = 0u;

		for (int n = 0; n < 4; n++) {
			total += sad(local_region[n][lid.y][lid.x], load_packed(true, ivec2(gid.x * 4, gid.y * 4 + n) + nearest));
		}

		sads[lid.z][lid.y][lid.x] = total;
		barrier();

		if (lid.z == 0 && inside) {
			if (scene_changed) {
				imageStore(next_flow, gid.xy, ivec4(0));
				return;
			}

			uint best_sad = 0xffffffffu;
			int best_id = 0;

			for (int n = 0; n < 4; n++) {
				if (sads[n][lid.y][lid.x] < best_sad) {
					best_sad = sads[n][lid.y][lid.x];
					best_id = n;
				}
			}

			imageStore(next_flow, gid.xy, ivec4(nearest_vectors[best_id][lid.y][lid.x], 0, 0));
		}
	}
]]

local function texture(name, width, height, format)
	local t = Texture.New{
		width = width,
		height = height,
		format = format,
		image = {
			usage = {"storage", "sampled", "transfer_dst"},
			properties = "device_local",
		},
		sampler = false,
	}
	t:SetDebugName("optical flow " .. name)
	return t
end

local function ensure_resources(width, height)
	if resources.width == width and resources.height == height then return false end

	render.GetDevice():WaitIdle()

	for _, value in pairs(resources) do
		if type(value) == "table" then
			for _, t in pairs(value) do
				if type(t) == "table" and t.Remove then t:Remove() end
			end

			if value.Remove then value:Remove() end
		end
	end

	table.clear(resources)
	resources.width, resources.height = width, height
	resources.luma = {{}, {}}

	for input = 1, 2 do
		for level = 0, optical_flow.LEVELS - 1 do
			resources.luma[input][level] = texture(
				"luma " .. input .. " level " .. level,
				math.max(1, math.floor(width / 2 ^ level)),
				math.max(1, math.floor(height / 2 ^ level)),
				"r32_uint"
			)
		end
	end

	resources.search = {}
	resources.filtered = {}
	local flow_width = math.ceil(width / optical_flow.BLOCK_SIZE)
	local flow_height = math.ceil(height / optical_flow.BLOCK_SIZE)
	resources.flow_sizes = {}

	for level = 0, optical_flow.LEVELS - 1 do
		resources.flow_sizes[level] = {flow_width, flow_height}
		resources.search[level] = texture("search level " .. level, flow_width, flow_height, "r32g32_sint")
		resources.filtered[level] = texture("filtered level " .. level, flow_width, flow_height, "r32g32_sint")
		flow_width, flow_height = math.ceil(flow_width / 2), math.ceil(flow_height / 2)
	end

	resources.histogram = texture("histogram", HISTOGRAM_BINS * HISTOGRAMS, 1, "r32_uint")
	resources.previous_histograms = {
		texture("previous histogram 1", HISTOGRAM_BINS * HISTOGRAMS, 1, "r32_sfloat"),
		texture("previous histogram 2", HISTOGRAM_BINS * HISTOGRAMS, 1, "r32_sfloat"),
	}
	resources.scd_temp = texture("scd temp", 3, 1, "r32_uint")
	resources.scd_output = texture("scd output", 3, 1, "r32_uint")
	return true
end

local function barrier(cmd)
	cmd:PipelineBarrier{srcStage = "compute", dstStage = "compute", memoryBarrier = true}
end

local function bind(cmd, pipeline, slot, images)
	for binding, image in ipairs(images) do
		pipeline:UpdateDescriptorSet("storage_image", slot, binding - 1, 0, image:GetView())
	end

	pipeline:UploadConstants()
end

local function clear_images(cmd, images)
	for _, image in ipairs(images) do
		cmd:ClearColorImage{image = image:GetImage(), color = {0, 0, 0, 0}, layout = "general"}
	end
end

function optical_flow.EnsureResources(scene)
	local size = scene:GetSize()
	ensure_resources(size.x, size.y)
end

function optical_flow.GetFlow()
	return resources.filtered[0]
end

function optical_flow.GetSceneChangeOutput()
	return resources.scd_output
end

function optical_flow.GetFlowSize()
	return resources.flow_sizes[0][1], resources.flow_sizes[0][2]
end

function optical_flow.Dispatch(cmd, scene, reset)
	local size = scene:GetSize()
	local recreated = ensure_resources(size.x, size.y)
	local r = resources

	for _, list in ipairs{r.luma[1], r.luma[2], r.search, r.filtered} do
		for _, t in pairs(list) do
			render.TransitionResourceToComputeStorage(t, {cmd = cmd, srcStage = "all_commands", srcAccess = "memory_read"})
		end
	end

	for _, t in ipairs{
		r.histogram,
		r.previous_histograms[1],
		r.previous_histograms[2],
		r.scd_temp,
		r.scd_output,
	} do
		render.TransitionResourceToComputeStorage(t, {cmd = cmd, srcStage = "all_commands", srcAccess = "memory_read"})
	end

	if reset or recreated then
		state.frame_index = 0
		clear_images(
			cmd,
			{r.scd_temp, r.scd_output, r.previous_histograms[1], r.previous_histograms[2]}
		)

		for input = 1, 2 do
			clear_images(cmd, r.luma[input])
		end

		cmd:PipelineBarrier{srcStage = "transfer", dstStage = "compute", memoryBarrier = true}
	else
		state.frame_index = state.frame_index + 1
	end

	state.frame_parity = (state.frame_parity + 1) % 2
	local current = r.luma[state.frame_parity + 1]
	local previous = r.luma[2 - state.frame_parity]
	state.scene = scene
	state.level = 0
	local base = ((render.GetCurrentFrame() or 1) - 1) % MAX_FRAMES * SLOTS_PER_FRAME + 1
	local slot = base

	local function next_slot()
		slot = slot + 1
		return slot - 1
	end

	local p = get_pipeline("clear", {x = 64, y = 1, z = 1}, CLEAR_DECLARATIONS, CLEAR_SHADER)
	local s = next_slot()
	bind(cmd, p, s, {r.histogram})
	p.pipeline:Dispatch(cmd, HISTOGRAM_BINS * HISTOGRAMS / 64, 1, 1, s, p.dynamic_offsets)
	p = get_pipeline("luma", {x = 8, y = 8, z = 1}, LUMA_DECLARATIONS, LUMA_SHADER)
	s = next_slot()
	bind(cmd, p, s, {current[0]})
	p.pipeline:DispatchForSize(cmd, size.x, size.y, 1, s, p.dynamic_offsets)
	barrier(cmd)
	p = get_pipeline("pyramid", {x = 8, y = 8, z = 1}, PYRAMID_DECLARATIONS, PYRAMID_SHADER)

	for level = 1, optical_flow.LEVELS - 1 do
		s = next_slot()
		bind(cmd, p, s, {current[level - 1], current[level]})
		p.pipeline:DispatchForSize(
			cmd,
			math.max(1, math.floor(size.x / 2 ^ level)),
			math.max(1, math.floor(size.y / 2 ^ level)),
			1,
			s,
			p.dynamic_offsets
		)
		barrier(cmd)
	end

	p = get_pipeline("histogram", {x = 32, y = 8, z = 1}, HISTOGRAM_DECLARATIONS, HISTOGRAM_SHADER)
	s = next_slot()
	bind(cmd, p, s, {current[0], r.histogram})
	p.pipeline:Dispatch(
		cmd,
		math.max(1, math.ceil(math.floor(math.floor(size.x / 4) / 3) / 32)),
		16,
		HISTOGRAMS,
		s,
		p.dynamic_offsets
	)
	barrier(cmd)
	p = get_pipeline("divergence", {x = 256, y = 1, z = 1}, DIVERGENCE_DECLARATIONS, DIVERGENCE_SHADER)
	s = next_slot()
	bind(
		cmd,
		p,
		s,
		{
			r.histogram,
			r.previous_histograms[2 - state.frame_parity],
			r.previous_histograms[state.frame_parity + 1],
			r.scd_temp,
			r.scd_output,
		}
	)
	p.pipeline:Dispatch(cmd, HISTOGRAMS, 3, 1, s, p.dynamic_offsets)
	barrier(cmd)
	local search = get_pipeline("search", {x = 64, y = 1, z = 1}, SEARCH_DECLARATIONS, SEARCH_SHADER)
	local filter = get_pipeline("filter", {x = 16, y = 4, z = 1}, FILTER_DECLARATIONS, FILTER_SHADER)
	local scale = get_pipeline("scale", {x = 4, y = 4, z = 4}, SCALE_DECLARATIONS, SCALE_SHADER)

	for level = optical_flow.LEVELS - 1, 0, -1 do
		state.level = level
		local luma_width, luma_height = math.max(1, math.floor(size.x / 2 ^ level)),
		math.max(1, math.floor(size.y / 2 ^ level))
		s = next_slot()
		bind(cmd, search, s, {current[level], previous[level], r.search[level], r.scd_output})
		search.pipeline:Dispatch(
			cmd,
			math.ceil(luma_width / 16),
			math.ceil(luma_height / 16),
			1,
			s,
			search.dynamic_offsets
		)
		barrier(cmd)
		local flow_width, flow_height = r.flow_sizes[level][1], r.flow_sizes[level][2]
		s = next_slot()
		bind(cmd, filter, s, {r.search[level], r.filtered[level]})
		filter.pipeline:Dispatch(
			cmd,
			math.ceil(flow_width / 16),
			math.ceil(flow_height / 4),
			1,
			s,
			filter.dynamic_offsets
		)
		barrier(cmd)

		if level > 0 then
			local next_width, next_height = r.flow_sizes[level - 1][1], r.flow_sizes[level - 1][2]
			s = next_slot()
			bind(
				cmd,
				scale,
				s,
				{
					current[level],
					previous[level],
					r.filtered[level],
					r.search[level - 1],
					r.scd_output,
				}
			)
			scale.pipeline:Dispatch(
				cmd,
				math.ceil(next_width / 4),
				math.ceil(next_height / 4),
				1,
				s,
				scale.dynamic_offsets
			)
			barrier(cmd)
		end
	end

	state.level = 0
	state.scene = nil
end

return optical_flow
