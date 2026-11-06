local ffi = require("ffi")
local bit = require("bit")
local render = import("goluwa/render/render.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local Texture = import("goluwa/render/texture.lua")
local height_from_normals = {}
local GROUP_SIZE = 64
local TWO_PI = 2 * math.pi
local pipelines = {}
local complex_buffers = [[
	layout(set = 0, binding = 0, std430) buffer Source { vec2 source[]; };
	layout(set = 0, binding = 1, std430) buffer Dest { vec2 dest[]; };
	layout(set = 0, binding = 2, std430) buffer Params { float params[]; };
]]
local shaders = {}
shaders.gradient = {
	storage_buffers = {{binding_index = 0}, {binding_index = 1}},
	sampled_images = {{binding_index = 2}},
	declarations = [[
		layout(set = 0, binding = 0, std430) buffer Dest { vec2 dest[]; };
		layout(set = 0, binding = 1, std430) buffer Params { float params[]; };
		layout(set = 0, binding = 2) uniform sampler2D normals;
	]],
	shader = [[
		void main() {
			uint id = gl_GlobalInvocationID.x;
			int n = int(params[0]);

			if (id >= uint(n * n)) return;

			vec2 xy = texelFetch(normals, ivec2(int(id) % n, int(id) / n), 0).xy * 2.0 - 1.0;
			float nz = sqrt(max(1.0 - dot(xy, xy), 0.0025));
			dest[id] = vec2(-xy.x / nz, -xy.y / nz * params[1]);
		}
	]],
}
shaders.fft = {
	storage_buffers = {{binding_index = 0}, {binding_index = 1}, {binding_index = 2}},
	declarations = complex_buffers,
	shader = [[
		void main() {
			uint id = gl_GlobalInvocationID.x;
			uint n = uint(params[0]);
			uint ns = uint(params[1]);
			uint stride = uint(params[2]);
			uint line_stride = uint(params[3]);
			float direction = params[4];
			uint half_n = n / 2u;

			if (id >= half_n * n) return;

			uint base = (id / half_n) * line_stride;
			uint j = id % half_n;
			vec2 in0 = source[base + j * stride];
			vec2 in1 = source[base + (j + half_n) * stride];
			uint k = j % ns;
			float angle = direction * 6.28318530718 * float(k) / float(2u * ns);
			vec2 twiddle = vec2(cos(angle), sin(angle));
			vec2 t = vec2(in1.x * twiddle.x - in1.y * twiddle.y, in1.x * twiddle.y + in1.y * twiddle.x);
			uint out0 = (j / ns) * 2u * ns + k;
			dest[base + out0 * stride] = in0 + t;
			dest[base + (out0 + ns) * stride] = in0 - t;
		}
	]],
}
shaders.solve = {
	storage_buffers = {{binding_index = 0}, {binding_index = 1}, {binding_index = 2}},
	declarations = complex_buffers,
	shader = [[
		void main() {
			uint id = gl_GlobalInvocationID.x;
			uint n = uint(params[0]);
			float cutoff = params[1];
			float height_cut = params[2];

			if (id >= n * n) return;

			uint u = id % n;
			uint v = id / n;

			if (u == 0u && v == 0u) {
				dest[id] = vec2(0.0);
				return;
			}

			vec2 f_k = source[id];
			vec2 f_mirror = source[((n - v) % n) * n + (n - u) % n];
			f_mirror.y = -f_mirror.y;
			vec2 p_k = 0.5 * (f_k + f_mirror);
			vec2 difference = 0.5 * (f_k - f_mirror);
			vec2 q_k = vec2(difference.y, -difference.x);
			float fu = (u <= n / 2u ? float(u) : float(u) - float(n)) * 6.28318530718 / float(n);
			float fv = (v <= n / 2u ? float(v) : float(v) - float(n)) * 6.28318530718 / float(n);
			vec2 s = fu * p_k + fv * q_k;
			float cycles = length(vec2(fu, fv)) * float(n) / 6.28318530718;
			float weight = cutoff > 0.0 ? smoothstep(cutoff * 0.5, cutoff, cycles) : 1.0;

			if (height_cut > 0.0) weight *= 1.0 - smoothstep(height_cut, height_cut * 2.0, cycles);
			dest[id] = vec2(s.y, -s.x) / (fu * fu + fv * fv) * weight;
		}
	]],
}
shaders.finalize = {
	storage_buffers = {{binding_index = 0}, {binding_index = 1}, {binding_index = 2}},
	declarations = [[
		layout(set = 0, binding = 0, std430) buffer Source { vec2 source[]; };
		layout(set = 0, binding = 1, std430) buffer Dest { float dest[]; };
		layout(set = 0, binding = 2, std430) buffer Params { float params[]; };
	]],
	shader = [[
		void main() {
			uint id = gl_GlobalInvocationID.x;
			uint n = uint(params[0]);

			if (id >= n * n) return;

			dest[id] = source[id].x / float(n * n);
		}
	]],
}

local function get_pipeline(name)
	if not pipelines[name] then
		local info = shaders[name]
		pipelines[name] = EasyPipeline.Compute{
			name = "height_from_normals_" .. name,
			DescriptorSetCount = 1,
			LocalSize = {x = GROUP_SIZE, y = 1, z = 1},
			storage_buffers = info.storage_buffers,
			sampled_images = info.sampled_images,
			custom_declarations = info.declarations,
			shader = info.shader,
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
		label = "height_from_normals",
	}
end

do
	local param_buffer

	local function run(name, buffers, params, thread_count, texture)
		param_buffer = param_buffer or create_buffer(16 * 4)
		local mapped = ffi.cast("float*", param_buffer:Map())

		for i, value in ipairs(params) do
			mapped[i - 1] = value
		end

		local pipeline = get_pipeline(name)
		local cmd = render.GetCommandPool():AllocateCommandBuffer()
		cmd:Begin()

		for binding, buffer in ipairs(buffers) do
			pipeline:UpdateDescriptorSet("storage_buffer", 1, binding - 1, 0, buffer, buffer:GetSize())
		end

		pipeline:UpdateDescriptorSet("storage_buffer", 1, #buffers, 0, param_buffer, param_buffer:GetSize())

		if texture then pipeline:BindSampledImage(cmd, 1, 2, texture) end

		pipeline.pipeline:Dispatch(cmd, math.ceil(thread_count / GROUP_SIZE), 1, 1, 1)
		cmd:PipelineBarrier{srcStage = "compute", dstStage = "host", memoryBarrier = true}
		cmd:End()
		render.SubmitAndWait(cmd)
	end

	local function transform_2d(a, b, n, inverse)
		local direction = inverse and 1 or -1
		local stages = math.log(n) / math.log(2)

		for _, pass in ipairs{{1, n}, {n, 1}} do
			for stage = 0, stages - 1 do
				run("fft", {a, b}, {n, 2 ^ stage, pass[1], pass[2], direction}, n * n / 2)
				a, b = b, a
			end
		end

		return a, b
	end

	-- Solves for the height whose slopes are the ones the normals describe (a Poisson problem, the
	-- Frankot Chellappa method) on the gpu: both slope fields go through one complex fft as p + iq, the
	-- solve in frequency space splits them again from the symmetry of a real signal. `normals` is a
	-- square power of two Texture with the normal's xy in rg (0 to 1 encoded); the surface is assumed
	-- to tile. `cutoff` (cycles over the texture, default 2) removes the slowest frequencies, the
	-- drift a tiling solve cannot know. `height_cut` fades out everything finer than that many
	-- cycles (a parallax method smears steep narrow grooves). Returns a buffer of n * n floats, in
	-- texels of height for a slope measured in texels (`ffi.cast("float*", buffer:Map())`). `flip_green`
	-- is for normal maps whose green points down (DirectX).
	function height_from_normals.Solve(normals, cutoff, height_cut, flip_green)
		local n = normals:GetWidth()
		assert(
			n == normals:GetHeight() and bit.band(n, n - 1) == 0,
			"normals must be a square power of two texture"
		)
		local a, b = create_buffer(n * n * 8), create_buffer(n * n * 8)
		run("gradient", {a}, {n, flip_green and -1 or 1}, n * n, normals)
		a, b = transform_2d(a, b, n, false)
		run("solve", {a, b}, {n, cutoff or 2, height_cut or 0}, n * n)
		a, b = transform_2d(b, a, n, true)
		local height = create_buffer(n * n * 4, true)
		run("finalize", {a, height}, {n}, n * n)
		a:Remove()
		b:Remove()
		return height
	end
end

-- Solves the height of a square power of two normal texture and normalises it to 8 bits (1% to 99% of the
-- solved range). Returns the r8 texture and the solved relief as a fraction of the texture size, the depth
-- the normals describe. `height_cut` is a fraction of the size, see Solve.
function height_from_normals.CreateHeightTexture(normals, height_cut, cache_key, flip_green)
	local size = normals:GetWidth()
	local buffer = height_from_normals.Solve(normals, 2, size * height_cut, flip_green)
	local heights = ffi.cast("float*", buffer:Map())
	local count = size * size
	local lo, hi = math.huge, -math.huge

	for i = 0, count - 1 do
		lo, hi = math.min(lo, heights[i]), math.max(hi, heights[i])
	end

	local bins = {}

	for i = 1, 256 do
		bins[i] = 0
	end

	for i = 0, count - 1 do
		local bin = math.min(256, math.floor((heights[i] - lo) / (hi - lo) * 255) + 1)
		bins[bin] = bins[bin] + 1
	end

	local sum, low_bin, high_bin = 0, 1, 256

	for i = 1, 256 do
		sum = sum + bins[i]

		if sum < count * 0.01 then low_bin = i end

		if sum <= count * 0.99 then high_bin = i end
	end

	local p_lo = lo + (hi - lo) * low_bin / 256
	local p_hi = lo + (hi - lo) * (high_bin + 1) / 256
	local relief = ffi.new("uint8_t[?]", count)

	for i = 0, count - 1 do
		relief[i] = math.floor(math.min(math.max((heights[i] - p_lo) / (p_hi - p_lo), 0), 1) * 255 + 0.5)
	end

	buffer:Remove()
	return Texture.New{
		buffer = relief,
		width = size,
		height = size,
		format = "r8_unorm",
		mip_map_levels = "auto",
		cache_key = cache_key,
	},
	(p_hi - p_lo) / size
end

return height_from_normals
