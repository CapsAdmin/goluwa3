local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local system = import("goluwa/system.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local bridge = import("goluwa/render3d/scene/bridge.lua")
local materials = import("goluwa/render3d/scene/materials.lua")
local meshes = import("goluwa/render3d/scene/meshes.lua")
local hit = import("goluwa/render3d/scene/hit.lua")
local store = import("goluwa/render3d/scene/store.lua")
local emitters = {}
emitters.DOUBLE_SIDED = 0x80000000
local EMITTER_WORDS = 4
local HEADER_WORDS = 2
local SCAN_SIZE = 256
emitters.EMITTER_WORDS = EMITTER_WORDS
local list = {count = 0, version = -1}
local Source = ffi.typeof([[struct {
	uint32_t first;
	uint32_t instance;
	uint32_t triangle_count;
	uint32_t flags;
	float luminance;
}]])
local SourceArray = ffi.typeof("$[?]", Source)
local sources_buffer
local words_buffer
local sums_base = 0
local built_frame = -1

function emitters.Get(include_additive)
	if list.version == bridge.emitter_version and list.additive == include_additive then
		return list
	end

	local sources = {}
	local count = 0
	local total = 0

	for visual in pairs(bridge.GetEmissiveVisuals()) do
		if visual.Visible then
			for _, item in ipairs(visual.scene_instances) do
				local material = item.material
				local r, g, b = materials.GetEmissive(material)
				local luminance = item.level == 0 and 0.2126 * r + 0.7152 * g + 0.0722 * b or 0
				local additive = material:GetAdditive() and
					not material:GetAlbedoAlphaIsEmissive()
					and
					material:GetEmissiveTexture() == nil

				if luminance > 0 and (include_additive or not additive) then
					count = count + 1
					sources[count] = {
						first = total,
						instance = item.id,
						triangle_count = meshes.GetRecord(item.mesh_row).triangle_count,
						flags = material:GetDoubleSided() and emitters.DOUBLE_SIDED or 0,
						luminance = luminance,
					}
					total = total + sources[count].triangle_count
				end
			end
		end
	end

	list.source_count = count
	list.count = total
	list.additive = include_additive
	list.version = bridge.emitter_version
	list.sources_version = (list.sources_version or 0) + 1
	list.sources = sources
	return list
end

do
	local pipelines
	local uniform = {source_count = 0, triangle_count = 0, block_count = 0, sums_base = 0}
	local bound = {}
	local uploaded_version = -1

	local function create_pipelines()
		local slots = math.max(render.GetSwapchainImageCount() or 1, 1)
		local declarations = hit.GetGLSL(0) .. [[
			struct emitter_source {
				uint first;
				uint instance;
				uint triangle_count;
				uint flags;
				float luminance;
			};

			layout(scalar, set = 0, binding = 4) readonly buffer EmitterSources { emitter_source sources[]; };
			layout(scalar, set = 0, binding = 5) buffer EmitterWords { uint words[]; };
			shared float scan_data[]] .. SCAN_SIZE .. [[];

			float block_scan(uint lid, float v) {
				scan_data[lid] = v;
				barrier();

				for (uint offset = 1u; offset < ]] .. SCAN_SIZE .. [[u; offset <<= 1u) {
					float add = lid >= offset ? scan_data[lid - offset] : 0.0;
					barrier();
					scan_data[lid] += add;
					barrier();
				}

				return scan_data[lid];
			}
		]]

		local function create(name, shader)
			return EasyPipeline.Compute{
				name = name,
				DescriptorSetCount = slots,
				LocalSize = {x = SCAN_SIZE, y = 1, z = 1},
				storage_buffers = {
					{binding_index = 0},
					{binding_index = 1},
					{binding_index = 2},
					{binding_index = 4},
					{binding_index = 5},
				},
				uniform_buffers = {
					{
						name = "emitter_data",
						binding_index = 3,
						block = {
							{"source_count", "int"},
							{"triangle_count", "int"},
							{"block_count", "int"},
							{"sums_base", "int"},
						},
						write = function(self, block)
							block.source_count = uniform.source_count
							block.triangle_count = uniform.triangle_count
							block.block_count = uniform.block_count
							block.sums_base = uniform.sums_base
							return block
						end,
					},
				},
				custom_declarations = declarations,
				shader = shader,
			}
		end

		pipelines = {
			power = create(
				"scene_emitter_power",
				[[
				void main() {
					uint t = gl_GlobalInvocationID.x;
					uint lid = gl_LocalInvocationID.x;
					float power = 0.0;

					if (t < uint(emitter_data.triangle_count)) {
						uint lo = 0u;
						uint hi = uint(emitter_data.source_count) - 1u;

						while (lo < hi) {
							uint mid = (lo + hi + 1u) >> 1u;

							if (sources[mid].first <= t) {
								lo = mid;
							} else {
								hi = mid - 1u;
							}
						}

						emitter_source source = sources[lo];
						uint primitive = t - source.first;

						if ((scene_instance_flags(source.instance) & 16u) == 0u) {
							scene_triangle tri = scene_hit_tri(source.instance, primitive);
							power = 0.5 * length(cross(tri.e1, tri.e2)) * source.luminance;

							if (!(power > 0.0)) power = 0.0;
						}

						uint at = 2u + t * 4u;
						words[at] = source.instance;
						words[at + 1u] = primitive | source.flags;
						words[at + 3u] = floatBitsToUint(power);
					}

					float sum = block_scan(lid, power);

					if (t < uint(emitter_data.triangle_count)) words[2u + t * 4u + 2u] = floatBitsToUint(sum);

					if (lid == ]] .. SCAN_SIZE - 1 .. [[u) words[emitter_data.sums_base + gl_WorkGroupID.x] = floatBitsToUint(sum);
				}
			]]
			),
			blocks = create(
				"scene_emitter_blocks",
				[[
				void main() {
					uint lid = gl_LocalInvocationID.x;
					uint count = uint(emitter_data.block_count);
					float carry = 0.0;

					for (uint base = 0u; base < count; base += ]] .. SCAN_SIZE .. [[u) {
						uint index = base + lid;
						float sum = block_scan(lid, index < count ? uintBitsToFloat(words[emitter_data.sums_base + index]) : 0.0);

						if (index < count) words[emitter_data.sums_base + index] = floatBitsToUint(carry + sum);

						float chunk = scan_data[]] .. SCAN_SIZE - 1 .. [[];
						barrier();
						carry += chunk;
					}
				}
			]]
			),
			cdf = create(
				"scene_emitter_cdf",
				[[
				void main() {
					uint t = gl_GlobalInvocationID.x;
					uint count = uint(emitter_data.triangle_count);
					float total = uintBitsToFloat(words[emitter_data.sums_base + uint(emitter_data.block_count) - 1u]);

					if (t == 0u) {
						words[0] = floatBitsToUint(total);
						words[1] = count;
					}

					if (t >= count) return;

					uint block = t / ]] .. SCAN_SIZE .. [[u;
					float offset = block > 0u ? uintBitsToFloat(words[emitter_data.sums_base + block - 1u]) : 0.0;
					uint at = 2u + t * 4u + 2u;
					float cdf = total > 0.0 ? (uintBitsToFloat(words[at]) + offset) / total : 0.0;

					if (t == count - 1u) cdf = 1.0;

					words[at] = floatBitsToUint(cdf);
				}
			]]
			),
			guide = create(
				"scene_emitter_guide",
				[[
				void main() {
					uint k = gl_GlobalInvocationID.x;
					uint count = uint(emitter_data.triangle_count);

					if (k > count) return;

					float u = float(k) / float(count);
					uint lo = 0u;
					uint hi = count - 1u;

					while (lo < hi) {
						uint mid = (lo + hi) >> 1u;

						if (uintBitsToFloat(words[2u + mid * 4u + 2u]) <= u) {
							lo = mid + 1u;
						} else {
							hi = mid;
						}
					}

					words[2u + count * 4u + k] = lo;
				}
			]]
			),
		}
	end

	local function bind(pipeline, slot, buffers)
		bound[pipeline] = bound[pipeline] or {}
		local last = bound[pipeline][slot]

		if not last then
			last = {}
			bound[pipeline][slot] = last
		end

		hit.Bind(pipeline, slot, 0)

		if last[1] ~= buffers[1] then
			pipeline:UpdateDescriptorSet("storage_buffer", slot, 4, 0, buffers[1], buffers[1]:GetSize())
			last[1] = buffers[1]
		end

		if last[2] ~= buffers[2] then
			pipeline:UpdateDescriptorSet("storage_buffer", slot, 5, 0, buffers[2], buffers[2]:GetSize())
			last[2] = buffers[2]
		end
	end

	function emitters.Build(cmd, include_additive)
		local frame = system.GetFrameNumber()
		local emitter_list = emitters.Get(include_additive)

		if built_frame == frame or emitter_list.count == 0 then
			return emitters.GetBuffer()
		end

		built_frame = frame

		if not pipelines then create_pipelines() end

		local count = emitter_list.count
		local blocks = math.ceil(count / SCAN_SIZE)
		local words = HEADER_WORDS + count * EMITTER_WORDS + count + 1
		local needed = (words + blocks) * 4

		if not words_buffer or words_buffer:GetSize() < needed then
			if words_buffer then words_buffer:Remove() end

			words_buffer = render.CreateBuffer{
				byte_size = math.ceil(needed * 1.5),
				buffer_usage = {"storage_buffer", "transfer_src"},
				memory_property = {"device_local"},
				label = "ddgi_emitters",
			}
		end

		if uploaded_version ~= emitter_list.sources_version then
			local sources = emitter_list.sources
			local data = SourceArray(math.max(emitter_list.source_count, 1))

			for i = 1, emitter_list.source_count do
				local source = sources[i]
				data[i - 1].first = source.first
				data[i - 1].instance = source.instance
				data[i - 1].triangle_count = source.triangle_count
				data[i - 1].flags = source.flags
				data[i - 1].luminance = source.luminance
			end

			if sources_buffer then sources_buffer:Remove() end

			sources_buffer = render.CreateBuffer{
				byte_size = ffi.sizeof(data),
				buffer_usage = {"storage_buffer"},
				memory_property = {"host_visible", "host_coherent"},
				label = "ddgi_emitter_sources",
				data = data,
			}
			uploaded_version = emitter_list.sources_version
		end

		sums_base = words
		uniform.source_count = emitter_list.source_count
		uniform.triangle_count = count
		uniform.block_count = blocks
		uniform.sums_base = sums_base
		local slot = (
				(
					render.GetCurrentFrame() or
					1
				) - 1
			) % math.max(render.GetSwapchainImageCount() or 1, 1) + 1
		local buffers = {sources_buffer, words_buffer}
		cmd:PipelineBarrier{
			srcStage = {
				"host",
				"transfer",
				"compute",
				"acceleration_structure_build_khr",
				"ray_tracing_shader_khr",
			},
			dstStage = "compute",
			memoryBarrier = true,
		}

		for i, name in ipairs({"power", "blocks", "cdf", "guide"}) do
			local pipeline = pipelines[name]
			bind(pipeline, slot, buffers)
			pipeline:UploadConstants()
			pipeline.pipeline:Dispatch(
				cmd,
				name == "blocks" and 1 or name == "guide" and math.ceil((count + 1) / SCAN_SIZE) or blocks,
				1,
				1,
				slot,
				pipeline.dynamic_offsets
			)

			if i < 4 then
				cmd:PipelineBarrier{srcStage = "compute", dstStage = "compute", memoryBarrier = true}
			end
		end

		cmd:PipelineBarrier{
			srcStage = "compute",
			dstStage = {"compute", "ray_tracing_shader_khr"},
			memoryBarrier = true,
		}
		return words_buffer
	end

	function emitters.GetBuffer()
		if not words_buffer then
			words_buffer = render.CreateBuffer{
				byte_size = 4096,
				buffer_usage = {"storage_buffer", "transfer_src"},
				memory_property = {"device_local"},
				label = "ddgi_emitters",
			}
		end

		return words_buffer
	end
end

function emitters.ReadBackHeader()
	local data = store.Download(words_buffer, HEADER_WORDS * 4)
	return ffi.cast("float*", data)[0], ffi.cast("uint32_t*", data)[1]
end

return emitters
