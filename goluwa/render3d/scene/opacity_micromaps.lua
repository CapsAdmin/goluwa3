local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local system = import("goluwa/system.lua")
local event = import("goluwa/event.lua")
local pvars = import("goluwa/cli/pvars.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local Micromap = import("goluwa/render/vulkan/internal/micromap.lua")
local meshes = import("goluwa/render3d/scene/meshes.lua")
local opacity_micromaps = {}
pvars.StartGroup("Rendering", "Ray tracing", {store = false})
local enabled = pvars.Setup2{
	key = "r_rt_opacity_micromaps",
	default = true,
	help = "alpha tested meshes get an opacity micromap in their bottom level structure, so rays skip transparent parts and accept opaque parts without running the alpha test; can be switched at runtime",
	callback = function()
		opacity_micromaps.version = opacity_micromaps.version + 1
	end,
}
local max_level = pvars.Setup2{
	key = "r_rt_opacity_micromap_level",
	default = 6,
	help = "subdivision level of an opacity micromap triangle (4^level micro triangles, 2 bits each); lowered for meshes with many triangles to stay within r_rt_opacity_micromap_megabytes",
}
local budget_megabytes = pvars.Setup2{
	key = "r_rt_opacity_micromap_megabytes",
	default = 8,
	help = "opacity micromap data size one mesh may use",
}
pvars.EndGroup()
local MIN_LEVEL = 2
local MAX_LEVEL = 7
local BATCH_JOBS = 32
local BATCH_TRIANGLES = 1024 * 1024
local MAX_TEXEL_SPAN = 32
local SCRATCH_ALIGN = 256
local WORKGROUP = 64
local JobEntry = ffi.typeof([[struct {
	uint32_t mesh_row;
	int32_t texture;
	float alpha;
	float cutoff;
	uint32_t level;
	uint32_t triangle_count;
	uint32_t cell_base;
	uint32_t pad;
	uint64_t data_address;
	uint64_t triangle_address;
}]])
local JobArray = ffi.typeof("$*", JobEntry)
opacity_micromaps.built = 0
opacity_micromaps.version = 0
local waiting = {}
local all_variants = setmetatable({}, {__mode = "k"})
local retiring = {}
local hit
local pipeline
local cell_buffer
local cell_bases = {}
local job_buffers = {}
local scratch
local scratch_address

function opacity_micromaps.IsSupported()
	return render.GetDevice().opacity_micromap_supported
end

do
	local band, bor, bxor, bnot, lshift, rshift = bit.band, bit.bor, bit.bxor, bit.bnot, bit.lshift, bit.rshift

	local function interleave(x)
		x = band(bor(x, lshift(x, 8)), 0x00ff00ff)
		x = band(bor(x, lshift(x, 4)), 0x0f0f0f0f)
		x = band(bor(x, lshift(x, 2)), 0x33333333)
		x = band(bor(x, lshift(x, 1)), 0x55555555)
		return x
	end

	-- the vulkan specification's barycentrics to micromap index reference code, evaluated at micro triangle centroids to invert it
	local function get_index(u, v, level)
		local n = lshift(1, level)
		local fu = u * n
		local fv = v * n
		local iu = math.floor(fu)
		local iv = math.floor(fv)
		local uf = fu - iu
		local vf = fv - iv

		if iu >= n then iu = n - 1 end

		if iv >= n then iv = n - 1 end

		local iuv = iu + iv

		if iuv >= n then iu = iu - (iuv - n + 1) end

		local iw = bnot(iu + iv)

		if uf + vf >= 1 and iuv < n - 1 then iw = iw - 1 end

		local b0 = band(bnot(bxor(iu, iw)), n - 1)
		local t = band(bxor(iu, iv), b0)
		local f = t
		f = bxor(f, rshift(f, 1))
		f = bxor(f, rshift(f, 2))
		f = bxor(f, rshift(f, 4))
		f = bxor(f, rshift(f, 8))
		local b1 = bor(band(bxor(f, iu), bnot(b0)), t)
		return bor(interleave(b0), lshift(interleave(b1), 1))
	end

	function opacity_micromaps.GetCellTable()
		local total = 0

		for level = MIN_LEVEL, MAX_LEVEL do
			cell_bases[level] = total
			total = total + 4 ^ level
		end

		local cells = ffi.new("uint32_t[?]", total)

		for level = MIN_LEVEL, MAX_LEVEL do
			local n = 2 ^ level
			local base = cell_bases[level]
			local seen = {}

			for iv = 0, n - 1 do
				for iu = 0, n - 1 - iv do
					for down = 0, (iu + iv < n - 1) and 1 or 0 do
						local offset = down == 1 and 2 / 3 or 1 / 3
						local index = get_index((iu + offset) / n, (iv + offset) / n, level)
						assert(not seen[index] and index < n * n, "micromap index mapping is not a bijection")
						seen[index] = true
						cells[base + index] = iu + iv * 256 + down * 65536
					end
				end
			end
		end

		return cells, total
	end
end

local function get_pipeline()
	if pipeline then return pipeline end

	hit = import("goluwa/render3d/scene/hit.lua")
	local cells, total = opacity_micromaps.GetCellTable()
	cell_buffer = render.CreateBuffer{
		byte_size = total * 4,
		buffer_usage = {"storage_buffer"},
		memory_property = {"host_visible", "host_coherent"},
		label = "opacity_micromap_cells",
	}
	ffi.copy(cell_buffer:Map(), cells, total * 4)
	pipeline = EasyPipeline.Compute{
		name = "opacity_micromap_generate",
		DescriptorSetCount = math.max(render.GetSwapchainImageCount() or 1, 1),
		LocalSize = {x = WORKGROUP, y = 1, z = 1},
		storage_buffers = {
			{binding_index = 0},
			{binding_index = 1},
			{binding_index = 2},
			{binding_index = 3},
			{binding_index = 4},
		},
		custom_declarations = hit.GetGLSL(0) .. [[
			struct omm_job {
				uint mesh_row;
				int texture;
				float alpha;
				float cutoff;
				uint level;
				uint triangle_count;
				uint cell_base;
				uint pad;
				uint64_t data_address;
				uint64_t triangle_address;
			};

			layout(scalar, set = 0, binding = 3) readonly buffer OmmJobs { omm_job omm_jobs[]; };
			layout(scalar, set = 0, binding = 4) readonly buffer OmmCells { uint omm_cells[]; };
			layout(buffer_reference, scalar, buffer_reference_align = 4) writeonly buffer OmmWords { uint w[]; };
			layout(buffer_reference, scalar, buffer_reference_align = 4) writeonly buffer OmmTriangles { uvec2 t[]; };

			#define MAX_TEXEL_SPAN ]] .. MAX_TEXEL_SPAN .. [[

		]],
		shader = [[
			vec2 omm_uv(vec2 uv0, vec2 uv1, vec2 uv2, vec2 corner, float n) {
				return uv0 + (uv1 - uv0) * (corner.x / n) + (uv2 - uv0) * (corner.y / n);
			}

			void main() {
				omm_job job = omm_jobs[gl_WorkGroupID.y];
				uint words_per_triangle = 1u << (2u * job.level - 4u);
				uint flat_index = gl_GlobalInvocationID.x;

				if (flat_index >= job.triangle_count * words_per_triangle) return;

				uint triangle = flat_index / words_per_triangle;
				uint word = flat_index % words_per_triangle;

				if (word == 0u) {
					OmmTriangles(job.triangle_address).t[triangle] = uvec2(triangle * words_per_triangle * 4u, job.level | (2u << 16u));
				}

				scene_mesh mesh = scene_meshes[job.mesh_row];
				SceneVertexData vertices = SceneVertexData(mesh.vertex_address);
				uint a = scene_mesh_index(mesh, triangle * 3u);
				uint b = scene_mesh_index(mesh, triangle * 3u + 1u);
				uint c = scene_mesh_index(mesh, triangle * 3u + 2u);
				vec2 uv0 = scene_vertex_uv(vertices, a);
				vec2 uv1 = scene_vertex_uv(vertices, b);
				vec2 uv2 = scene_vertex_uv(vertices, c);
				vec2 size = vec2(textureSize(TEXTURE(job.texture), 0));
				float n = float(1u << job.level);
				uint bits = 0u;

				for (uint k = 0u; k < 16u; k++) {
					uint cell = omm_cells[job.cell_base + word * 16u + k];
					float iu = float(cell & 0xFFu);
					float iv = float((cell >> 8u) & 0xFFu);
					bool down = (cell >> 16u) != 0u;
					vec2 p0 = omm_uv(uv0, uv1, uv2, down ? vec2(iu + 1.0, iv) : vec2(iu, iv), n);
					vec2 p1 = omm_uv(uv0, uv1, uv2, down ? vec2(iu, iv + 1.0) : vec2(iu + 1.0, iv), n);
					vec2 p2 = omm_uv(uv0, uv1, uv2, down ? vec2(iu + 1.0, iv + 1.0) : vec2(iu, iv + 1.0), n);
					vec2 low = min(min(p0, p1), p2) * size;
					vec2 high = max(max(p0, p1), p2) * size;
					uint state = 2u;

					if (all(lessThan(abs(low), vec2(1e6))) && all(lessThan(abs(high), vec2(1e6)))) {
						ivec2 first = ivec2(floor(low)) - 1;
						ivec2 last = ivec2(floor(high)) + 1;
						ivec2 span = last - first + 1;

						if (span.x <= MAX_TEXEL_SPAN && span.y <= MAX_TEXEL_SPAN) {
							bool any_pass = false;
							bool any_fail = false;

							for (int y = first.y; y <= last.y; y++) {
								for (int x = first.x; x <= last.x; x++) {
									float alpha = job.alpha * textureLod(TEXTURE(job.texture), (vec2(x, y) + 0.5) / size, 0.0).a;

									if (alpha >= job.cutoff) any_pass = true; else any_fail = true;
								}
							}

							state = any_pass ? (any_fail ? 2u : 1u) : 0u;

							// mixed micro triangles stay unknown (any hit runs the alpha test) but lean opaque or transparent by the share of the triangle that passes the same test, which rays with the 2 state flag take as is
							if (state == 2u) {
								int passes = 0;

								for (int j = 0; j < 4; j++) {
									for (int i = 0; i < 4 - j; i++) {
										vec2 up = (vec2(i, j) + 1.0 / 3.0) / 4.0;
										vec2 down = (vec2(i, j) + 2.0 / 3.0) / 4.0;

										if (job.alpha * textureLod(TEXTURE(job.texture), p0 + (p1 - p0) * up.x + (p2 - p0) * up.y, 0.0).a >= job.cutoff) passes++;

										if (i + j < 3 && job.alpha * textureLod(TEXTURE(job.texture), p0 + (p1 - p0) * down.x + (p2 - p0) * down.y, 0.0).a >= job.cutoff) passes++;
									}
								}

								if (passes >= 8) state = 3u;
							}
						}
					}

					bits |= state << (2u * k);
				}

				OmmWords(job.data_address).w[flat_index] = bits;
			}
		]],
	}
	return pipeline
end

-- a streamed texture may never reach its full size, and the alpha test reads whatever level is resident, so the micromap is built from that level and rebuilt when a finer one arrives
local function is_texture_settled(texture)
	if not (texture:IsValid() and texture:IsReady()) then return false end

	local stream = texture.stream
	return not stream or not (stream.uploading or stream.loading)
end

local function get_drop(texture)
	return texture.stream and texture.stream.drop or 0
end

event.AddListener("TextureViewChanged", "opacity_micromaps", function(texture)
	for record in pairs(all_variants) do
		local state = record.omm

		if
			state.texture == texture and
			state.micromap and
			not state.stale and
			get_drop(texture) < state.drop
		then
			state.stale = true
			waiting[#waiting + 1] = record
		end
	end
end)

function opacity_micromaps.GetStats()
	local list = {}

	for record in pairs(all_variants) do
		local state = record.omm
		list[#list + 1] = {
			row = record.row,
			triangles = record.triangle_count,
			level = state.level,
			texture = state.texture.config and state.texture.config.path,
			built = state.micromap ~= nil,
			attached = state.attached == true,
		}
	end

	table.sort(list, function(a, b)
		return a.row < b.row
	end)

	return list
end

function opacity_micromaps.GetLevel(triangle_count)
	local bytes = budget_megabytes:Get() * 1024 * 1024
	local level = math.min(max_level:Get(), MAX_LEVEL)

	while level >= MIN_LEVEL and triangle_count * 4 ^ level / 4 > bytes do
		level = level - 1
	end

	return level >= MIN_LEVEL and level or nil
end

local function get_alpha(material)
	return material:GetColorMultiplier().a
end

local function matches(state, material)
	return material:GetAlbedoTexture() == state.texture and
		material:GetAlphaCutoff() == state.cutoff and
		get_alpha(material) == state.alpha
end

-- the mesh row an instance of this mesh with this material traces: alpha tested materials with a texture get a row of their own (same geometry) whose bottom level structure carries the micromap of their alpha test
function opacity_micromaps.GetRow(record, material)
	if
		not material:GetAlphaTest() or
		not material:HasShadowTexture()
		or
		record.allow_update or
		not enabled:Get()
		or
		not opacity_micromaps.IsSupported()
	then
		return record.row
	end

	local variants = record.variants

	if variants then
		for i = 1, #variants do
			if matches(variants[i].omm, material) then return variants[i].row end
		end
	else
		variants = {}
		record.variants = variants
	end

	local level = opacity_micromaps.GetLevel(record.triangle_count)

	if not level then return record.row end

	local variant = meshes.GetVariant(record.row)
	variant.omm = {
		texture = material:GetAlbedoTexture(),
		cutoff = material:GetAlphaCutoff(),
		alpha = get_alpha(material),
		level = level,
	}
	variants[#variants + 1] = variant
	all_variants[variant] = true
	waiting[#waiting + 1] = variant
	return variant.row
end

local function ensure_scratch(size)
	if scratch and scratch:GetSize() >= size then return end

	if scratch then scratch:Remove() end

	scratch = render.CreateBuffer{
		byte_size = size,
		buffer_usage = {"storage_buffer", "shader_device_address"},
		memory_property = {"device_local"},
		label = "opacity_micromap_scratch",
	}
	scratch_address = tonumber(scratch:GetDeviceAddress())
end

local function retire_buffers(job, micromap)
	retiring[#retiring + 1] = {
		frame = system.GetFrameNumber(),
		data = job.data,
		triangles = job.triangles,
		micromap = micromap,
	}
end

local function release_retired()
	local frame = system.GetFrameNumber()
	local delay = render.GetSwapchainImageCount() + 1

	for i = #retiring, 1, -1 do
		local item = retiring[i]

		if item.frame <= frame - delay then
			item.data:Remove()
			item.triangles:Remove()

			if item.micromap then item.micromap:Remove() end

			table.remove(retiring, i)
		end
	end
end

local function get_jobs_buffer(slot)
	local entry = job_buffers[slot]

	if not entry then
		local buffer = render.CreateBuffer{
			byte_size = BATCH_JOBS * ffi.sizeof(JobEntry),
			buffer_usage = {"storage_buffer"},
			memory_property = {"host_visible", "host_coherent"},
			label = "opacity_micromap_jobs",
		}
		entry = {buffer = buffer, ptr = ffi.cast(JobArray, buffer:Map())}
		job_buffers[slot] = entry
	end

	return entry
end

function opacity_micromaps.Build(cmd)
	release_retired()

	if not waiting[1] then return end

	local device = render.GetDevice()
	local jobs = {}
	local triangles = 0
	local keep = {}

	for i = 1, #waiting do
		local record = waiting[i]
		local state = record.omm

		if state and (not state.micromap or state.stale) then
			if
				is_texture_settled(state.texture) and
				#jobs < BATCH_JOBS and
				(
					jobs[1] == nil or
					triangles + record.triangle_count <= BATCH_TRIANGLES
				)
			then
				jobs[#jobs + 1] = record
				triangles = triangles + record.triangle_count
			else
				keep[#keep + 1] = record
			end
		end
	end

	waiting = keep

	if not jobs[1] then return end

	local generate = get_pipeline()
	local slot = (
			(
				render.GetCurrentFrame() or
				1
			) - 1
		) % math.max(render.GetSwapchainImageCount() or 1, 1) + 1
	local entry = get_jobs_buffer(slot)
	local scratch_total = 0
	local scratch_offsets = {}
	local max_words = 0

	for i, record in ipairs(jobs) do
		local state = record.omm
		local level = state.level
		local words = record.triangle_count * 4 ^ level / 16
		local usage = Micromap.GetUsage(record.triangle_count, level, Micromap.FORMAT_4_STATE)
		local size, build_scratch = Micromap.QueryBuildSize(device, usage)
		state.previous = state.micromap
		state.stale = nil
		state.drop = get_drop(state.texture)
		state.usage = usage
		state.data = render.CreateBuffer{
			byte_size = words * 4,
			buffer_usage = {"storage_buffer", "shader_device_address", "micromap_build_input_read_only_ext"},
			memory_property = {"device_local"},
			label = "opacity_micromap_data",
		}
		state.triangles = render.CreateBuffer{
			byte_size = record.triangle_count * 8,
			buffer_usage = {"storage_buffer", "shader_device_address", "micromap_build_input_read_only_ext"},
			memory_property = {"device_local"},
			label = "opacity_micromap_triangles",
		}
		state.micromap = Micromap.New(
			device,
			render.CreateBuffer{
				byte_size = size,
				buffer_usage = {"micromap_storage_ext", "shader_device_address"},
				memory_property = {"device_local"},
				label = "opacity_micromap",
			},
			size
		)
		scratch_offsets[i] = scratch_total
		scratch_total = scratch_total + math.ceil(math.max(build_scratch, 1) / SCRATCH_ALIGN) * SCRATCH_ALIGN
		max_words = math.max(max_words, words)
		local job = entry.ptr[i - 1]
		job.mesh_row = record.row
		job.texture = generate:GetTextureIndex(state.texture)
		job.alpha = state.alpha
		job.cutoff = state.cutoff
		job.level = level
		job.triangle_count = record.triangle_count
		job.cell_base = cell_bases[level]
		job.pad = 0
		job.data_address = state.data:GetDeviceAddress()
		job.triangle_address = state.triangles:GetDeviceAddress()
	end

	ensure_scratch(scratch_total)
	hit.Bind(generate, slot, 0)
	generate:UpdateDescriptorSet("storage_buffer", slot, 3, 0, entry.buffer, entry.buffer:GetSize())
	generate:UpdateDescriptorSet("storage_buffer", slot, 4, 0, cell_buffer, cell_buffer:GetSize())
	generate:UploadConstants()
	cmd:PipelineBarrier{
		srcStage = {"host", "compute", "acceleration_structure_build_khr", "transfer"},
		dstStage = "compute",
		memoryBarrier = true,
	}
	generate.pipeline:Dispatch(cmd, math.ceil(max_words / WORKGROUP), #jobs, 1, slot, generate.dynamic_offsets)
	cmd:PipelineBarrier{srcStage = "compute", dstStage = "all_commands", memoryBarrier = true}

	for i, record in ipairs(jobs) do
		local state = record.omm
		state.micromap:Build(
			cmd,
			state.usage,
			scratch_address + scratch_offsets[i],
			tonumber(state.data:GetDeviceAddress()),
			tonumber(state.triangles:GetDeviceAddress())
		)
		retire_buffers(state, state.previous)
		state.previous = nil
		state.data = nil
		state.triangles = nil
		meshes.RebuildBLAS(record)
	end

	cmd:PipelineBarrier{srcStage = "all_commands", dstStage = "all_commands", memoryBarrier = true}
	opacity_micromaps.built = opacity_micromaps.built + #jobs
end

return opacity_micromaps
