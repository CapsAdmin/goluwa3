local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local gpu_timing = import("goluwa/render/gpu_timing.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local index_pool = import("goluwa/render3d/index_pool.lua")
local model_pipeline = import("goluwa/render3d/model_pipeline.lua")
local shader_features = import("goluwa/render3d/shader_features.lua")
local pvars = import("goluwa/cli/pvars.lua")
local visibility = {}
visibility.enabled = gbuffer_layout.visibility
pvars.StartGroup("Rendering", "Visibility buffer", {store = false})
local density = pvars.Setup2{
	key = "r_visibility_buffer_density",
	default = 0.03,
	help = "triangles per pixel above which a group of plain scene meshes is drawn through the visibility buffer (triangles of its visible instances over the pixels of their bounding spheres), below it stays classic; each cluster of a cluster lod mesh is routed the same way by its own triangles, scatter always uses it",
}
pvars.EndGroup()

function visibility.GetDensity()
	return density:Get()
end

visibility.MAX_CONTEXTS = 1024
visibility.VARIANTS = shader_features.ALL + 1
visibility.KIND_MULTI_DRAW = 0
visibility.KIND_TESSELLATION = 1
visibility.KINDS = 2
visibility.MAX_SETS = 256
visibility.TESSELLATION_SET = 128
visibility.RING = 4
visibility.CONTEXT_GLSL = [[
	struct VisibilityContext {
		uint64_t commands;
		uint64_t batches;
		uint64_t instances;
		uint64_t prev_instances;
		uint64_t batch_ids;
		uint64_t extra0;
		uint64_t extra1;
		uint64_t extra2;
		float time;
		float prev_time;
		float detail_time;
		float prev_detail_time;
		float extra_float;
		uint variant;
		uint kind;
		uint pad;
	};
]]
local Context = ffi.typeof([[struct {
	uint64_t commands;
	uint64_t batches;
	uint64_t instances;
	uint64_t prev_instances;
	uint64_t batch_ids;
	uint64_t extra0;
	uint64_t extra1;
	uint64_t extra2;
	float time;
	float prev_time;
	float detail_time;
	float prev_detail_time;
	float extra_float;
	uint32_t variant;
	uint32_t kind;
	uint32_t pad;
}]])
local ContextPtr = ffi.typeof("$ *", Context)
local CONTEXT_SIZE = ffi.sizeof(Context)
local buffer
local records
local set_contexts
local serial = -1
local count = 0
local used_variants = {}

local function get_buffer()
	if buffer then return buffer end

	buffer = render.CreateBuffer{
		byte_size = (
				CONTEXT_SIZE * visibility.MAX_CONTEXTS + visibility.MAX_SETS * 4
			) * visibility.RING,
		buffer_usage = {"storage_buffer", "shader_device_address"},
		memory_property = {"host_visible", "host_coherent"},
		label = "visibility contexts",
	}
	local mapped = buffer:Map()
	records = ffi.cast(ContextPtr, mapped)
	set_contexts = ffi.cast(
		"uint32_t *",
		ffi.cast("uint8_t *", mapped) + CONTEXT_SIZE * visibility.MAX_CONTEXTS * visibility.RING
	)
	return buffer
end

local function get_ring()
	return render.frame_serial % visibility.RING
end

function visibility.AddContext(pipeline, commands_address, set, kind, extra0, extra1, extra2, extra_float)
	get_buffer()

	if serial ~= render.frame_serial then
		serial = render.frame_serial
		count = 0
		table.clear(used_variants)
		ffi.fill(set_contexts + get_ring() * visibility.MAX_SETS, visibility.MAX_SETS * 4)
	end

	if count >= visibility.MAX_CONTEXTS then
		error(
			"more than " .. visibility.MAX_CONTEXTS .. " visibility draw contexts in one frame",
			2
		)
	end

	local record = records[get_ring() * visibility.MAX_CONTEXTS + count]
	record.commands = commands_address
	record.batches = pipeline.draw_batches_address
	record.instances = pipeline.draw_instances_address
	record.prev_instances = pipeline.draw_prev_instances_address
	record.batch_ids = pipeline.draw_batch_ids_address or 0
	record.time = atmosphere.GetWindTime()
	record.prev_time = atmosphere.GetPreviousWindTime()
	record.detail_time = atmosphere.GetWindDetailTime()
	record.prev_detail_time = atmosphere.GetPreviousWindDetailTime()
	record.variant = pipeline.config.visibility_bits
	record.kind = kind or visibility.KIND_MULTI_DRAW
	record.extra0 = extra0 or 0
	record.extra1 = extra1 or 0
	record.extra2 = extra2 or 0
	record.extra_float = extra_float or 0
	used_variants[record.kind * visibility.VARIANTS + record.variant] = true
	count = count + 1

	if set then set_contexts[get_ring() * visibility.MAX_SETS + set] = count end

	pipeline.draw_context = count
	return count
end

function visibility.GetContextsAddress()
	return get_buffer():GetDeviceAddress() + get_ring() * visibility.MAX_CONTEXTS * CONTEXT_SIZE
end

function visibility.GetSetContextsAddress()
	return get_buffer():GetDeviceAddress() + CONTEXT_SIZE * visibility.MAX_CONTEXTS * visibility.RING + get_ring() * visibility.MAX_SETS * 4
end

do
	local STORAGE_FORMATS = {
		r8g8b8a8_unorm = "rgba8",
		r16g16b16a16_unorm = "rgba16",
		r16g16_unorm = "rg16",
		b10g11r11_ufloat_pack32 = "r11f_g11f_b10f",
		r16g16b16a16_sfloat = "rgba16f",
	}
	local IDS_BINDING = 10
	local TARGET_BINDING = 11
	local QUADS_PER_GROUP = 16
	local ANIMATE_LOCAL_SIZE = 64
	local VARIANTS = visibility.VARIANTS
	local BINS = VARIANTS * 2 * visibility.KINDS
	local MATERIAL_BINS = 256
	local OFFSET_BYTES = 36
	local HEADER_WORDS = BINS * MATERIAL_BINS * 2 + BINS * 5 + 4
	local HEADER_BYTES = HEADER_WORDS * 4
	local ARGS_OFFSET = (BINS * MATERIAL_BINS * 2 + BINS * 2) * 4
	local ANIMATE_ARGS_OFFSET = ARGS_OFFSET + BINS * 12
	local JOBS_HEADER = string.format(
		[[
		layout(buffer_reference, scalar) buffer VisibilityJobs { uint counts[%d]; uint cursors[%d]; uint totals[%d]; uint bases[%d]; uint args[%d]; uint animate[4]; uvec2 jobs[]; };
	]],
		BINS * MATERIAL_BINS,
		BINS * MATERIAL_BINS,
		BINS,
		BINS,
		BINS * 3
	)
	local kinds = {}

	local function build_job_glsl(kind)
		local info = kinds[kind]
		local words = info.indexed and 5 or 4
		return string.format(
			[[
			layout(set = 0, binding = %d, rgba32ui) uniform readonly uimage2D visibility_ids;
			layout(buffer_reference, scalar) readonly buffer VisibilityContexts { VisibilityContext c[]; };
			layout(buffer_reference, scalar) readonly buffer VisibilityWords { uint v[]; };
			layout(buffer_reference, scalar) buffer VisibilityOffsets { uint v[]; };

			uvec4 visibility_job_id(uvec2 job) {
				uint first = uint(findLSB(job.y));
				return imageLoad(visibility_ids, ivec2(job.x & 0xFFFFu, job.x >> 16u) * 2 + ivec2(first & 1u, first >> 1u));
			}

			void visibility_prepare(uvec4 id, uint vertex) {
				VisibilityContext context = VisibilityContexts(compute.contexts).c[id.x - 1u];
				gbuffer_draw.batches = context.batches;
				gbuffer_draw.instances = context.instances;
				gbuffer_draw.prev_instances = context.prev_instances;
				gbuffer_draw.batch_ids = context.batch_ids;
				gbuffer_draw.time = context.time;
				gbuffer_draw.prev_time = context.prev_time;
				gbuffer_draw.detail_time = context.detail_time;
				gbuffer_draw.prev_detail_time = context.prev_detail_time;
				gbuffer_draw.context = int(id.x);
				VisibilityWords command = VisibilityWords(context.commands);
				%s
				visibility_instance_index = int(id.z);
				visibility_draw_id = int(id.y);
				%s
			}
		]],
			IDS_BINDING,
			info.indexed and
				string.format(
					"visibility_vertex_index = int(VisibilityWords(compute.indices).v[command.v[id.y * %du + 2u] + id.w * 3u + vertex]) + int(command.v[id.y * %du + 3u]);",
					words,
					words
				) or
				"visibility_vertex_index = int(id.w * 3u + vertex);",
			info.prepare or ""
		)
	end

	local camera
	local classify
	local bins
	local animate
	local resolves = {}
	local jobs
	local offsets
	local jobs_pixels = 0
	local jobs_address
	local offsets_address
	local RESOLVE_RING = 64
	local resolve_count = 0
	local classify_mode = 0
	local resolve_bin = 0

	local function strip_locations(code)
		return (
			code:gsub("layout%(location = %d+%) flat out ", ""):gsub("layout%(location = %d+%) flat in ", "")
		)
	end

	local function build_vertex_glsl(vertex, defines, kind)
		local lines = {
			defines,
			visibility.CONTEXT_GLSL,
			kinds[kind].declarations or
			"",
			[[
			struct VisibilityDraw {
				uint64_t batches;
				uint64_t instances;
				uint64_t prev_instances;
				uint64_t batch_ids;
				float time;
				float prev_time;
				float detail_time;
				float prev_detail_time;
				int context;
			};
			VisibilityDraw gbuffer_draw;
			int visibility_vertex_index;
			int visibility_instance_index;
			int visibility_draw_id;
			vec4 visibility_clip;
			vec3 visibility_offset;
			vec3 visibility_previous_offset;
			]],
		}

		for _, output in ipairs(vertex.outputs) do
			table.insert(
				lines,
				string.format("%s out_%s;\n%s in_%s;", output[2], output[1], output[2], output[1])
			)
		end

		table.insert(
			lines,
			strip_locations(vertex.custom_declarations) .. "\n" .. (
					vertex.shader:gsub("void main%(%)", "void visibility_vertex_main()"):gsub("gl_VertexIndex", "visibility_vertex_index"):gsub("gl_InstanceIndex", "visibility_instance_index"):gsub("gl_DrawID", "visibility_draw_id"):gsub("gl_Position", "visibility_clip")
				)
		)
		table.insert(lines, JOBS_HEADER .. build_job_glsl(kind))
		return table.concat(lines, "\n")
	end

	local function build_resolve_shader(bin)
		local kind = math.floor(bin / (VARIANTS * 2))
		local animated = math.floor(bin / VARIANTS) % 2 == 1
		local pass = kinds[kind].build(bin % VARIANTS)
		local vertex = pass.vertex
		local fragment = pass.fragment
		local record_glsl = model_pipeline.BuildPBRBatchRecordGlsl()
		local fragment_declarations, replaced = fragment.custom_declarations:gsub(record_glsl:gsub("%p", "%%%0"), "", 1)
		assert(
			replaced == 1,
			"the fragment declarations no longer contain the batch record glsl"
		)
		local lines = {
			"layout(derivative_group_quadsNV) in;",
			build_vertex_glsl(
				vertex,
				animated and
					"#define VERTEX_ANIMATION_OFFSET visibility_offset\n#define VERTEX_ANIMATION_PREVIOUS_OFFSET visibility_previous_offset" or
					"#define VERTEX_ANIMATION_STATIC",
				kind
			),
			"vec4 visibility_frag_coord;\nbool visibility_front_facing;",
		}
		local vertex_fields = {"vec4 clip;"}
		local store = {"\t\t\tv.clip = visibility_clip;"}
		local interpolate = {}

		for _, output in ipairs(vertex.outputs) do
			local name, type = output[1], output[2]
			table.insert(vertex_fields, string.format("%s %s;", type, name))
			table.insert(store, string.format("\t\t\tv.%s = out_%s;", name, name))
			table.insert(
				interpolate,
				string.format("\tin_%s = v0.%s * b.x + v1.%s * b.y + v2.%s * b.z;", name, name, name, name)
			)
		end

		for _, name in ipairs({"batch", "instance", "triangle"}) do
			table.insert(vertex_fields, "uint " .. name .. ";")
			table.insert(store, string.format("\t\t\tv.%s = out_%s;", name, name))
			table.insert(interpolate, string.format("\tin_%s = v0.%s;", name, name))
		end

		table.insert(
			lines,
			"struct VisibilityVertex {\n" .. table.concat(vertex_fields, "\n") .. "\n};"
		)
		local stores = {}

		for i, target in ipairs(gbuffer_layout.targets) do
			local storage_format = assert(STORAGE_FORMATS[target.format], "no storage format for gbuffer target " .. target.format)
			table.insert(
				lines,
				string.format(
					"layout(set = 0, binding = %d, %s) uniform writeonly image2D visibility_target_%d;\nvec4 out_%d = vec4(0.0);",
					TARGET_BINDING + i - 1,
					storage_format,
					i - 1,
					i - 1
				)
			)

			for _, channel in ipairs(target.channels) do
				local name, swizzle = channel[1], channel[2]
				table.insert(
					lines,
					string.format(
						"void set_%s(%s val) { out_%d.%s = val; }",
						name,
						#swizzle == 1 and "float" or "vec" .. #swizzle,
						i - 1,
						swizzle
					)
				)
			end

			table.insert(
				stores,
				string.format("\t\timageStore(visibility_target_%d, pixel, out_%d);", i - 1, i - 1)
			)
		end

		table.insert(lines, "void set_visibility(uvec4 val) {}")
		table.insert(
			lines,
			"#undef model\n#undef terrain_model\n" .. strip_locations(fragment_declarations)
		)
		table.insert(
			lines,
			(
				fragment.shader:gsub("void main%(%)", "void visibility_fragment_main()"):gsub("gl_FragCoord", "visibility_frag_coord"):gsub("gl_FrontFacing", "visibility_front_facing"):gsub("discard%s*;", "{}")
			)
		)
		table.insert(
			lines,
			string.format(
				[[
			shared VisibilityVertex visibility_vertices[%d];

			float visibility_cross(vec2 a, vec2 b) {
				return a.x * b.y - a.y * b.x;
			}

			void main() {
				uint quad = (gl_LocalInvocationID.y >> 1u) * 4u + (gl_LocalInvocationID.x >> 1u);
				uint lane = (gl_LocalInvocationID.x & 1u) | ((gl_LocalInvocationID.y & 1u) << 1u);
				uint job_index = gl_WorkGroupID.x * %du + quad;
				VisibilityJobs jobs = VisibilityJobs(compute.jobs);
				bool job_active = job_index < jobs.totals[compute.bin];
				uint job_slot = jobs.bases[compute.bin] + job_index;
				uvec2 job = job_active ? jobs.jobs[job_slot] : uvec2(0u, 1u);
				ivec2 pixel = ivec2(job.x & 0xFFFFu, job.x >> 16u) * 2 + ivec2(lane & 1u, lane >> 1u);

				if (job_active) {
					visibility_prepare(visibility_job_id(job), min(lane, 2u));

					if (lane < 3u) {
						%s
						visibility_vertex_main();
						VisibilityVertex v;
%s
						visibility_vertices[quad * 3u + lane] = v;
					}
				}

				barrier();

				if (!job_active) return;

				VisibilityVertex v0 = visibility_vertices[quad * 3u];
				VisibilityVertex v1 = visibility_vertices[quad * 3u + 1u];
				VisibilityVertex v2 = visibility_vertices[quad * 3u + 2u];
				vec2 ndc = (vec2(pixel) + 0.5) / gbuffer_data.render_size.xy * 2.0 - 1.0;
				vec2 a0 = v0.clip.xy - ndc * v0.clip.w;
				vec2 a1 = v1.clip.xy - ndc * v1.clip.w;
				vec2 a2 = v2.clip.xy - ndc * v2.clip.w;
				vec3 b = vec3(visibility_cross(a1, a2), visibility_cross(a2, a0), visibility_cross(a0, a1));
				b /= b.x + b.y + b.z;
%s
				visibility_frag_coord = vec4(vec2(pixel) + 0.5, 0.0, 1.0);
				visibility_front_facing = dot(v0.clip.xyw, cross(v1.clip.xyw, v2.clip.xyw)) %s 0.0;
				]] .. (
						kinds[kind].before_fragment or
						""
					) .. [[
				visibility_fragment_main();

				if (((job.y >> lane) & 1u) != 0u) {
%s
				}
			}
		]],
				QUADS_PER_GROUP * 3,
				QUADS_PER_GROUP,
				animated and
					string.format(
						[[
						uint offset = ((job_slot - jobs.bases[%d]) * 3u + lane) * 3u;
						VisibilityOffsets offsets = VisibilityOffsets(compute.offsets);
						vec2 a = unpackHalf2x16(offsets.v[offset]);
						vec2 b = unpackHalf2x16(offsets.v[offset + 1u]);
						vec2 c = unpackHalf2x16(offsets.v[offset + 2u]);
						visibility_offset = vec3(a, b.x);
						visibility_previous_offset = vec3(b.y, c);
						]],
						VARIANTS
					) or
					"",
				table.concat(store, "\n"),
				table.concat(interpolate, "\n"),
				camera.front_face == "counter_clockwise" and "<" or ">",
				table.concat(stores, "\n")
			)
		)
		return table.concat(lines, "\n")
	end

	visibility.BuildResolveShader = build_resolve_shader

	local function get_storage_descriptors(targets)
		local storage = {
			{
				type = "storage_image",
				binding_index = IDS_BINDING,
				stageFlags = "compute",
				set_index = 0,
			},
		}

		for i = 1, targets do
			table.insert(
				storage,
				{
					type = "storage_image",
					binding_index = TARGET_BINDING + i - 1,
					stageFlags = "compute",
					set_index = 0,
				}
			)
		end

		return storage
	end

	local function get_descriptor_count()
		return RESOLVE_RING * 3
	end

	local job_block = {
		{"jobs", "uint64_t"},
		{"contexts", "uint64_t"},
		{"indices", "uint64_t"},
		{"offsets", "uint64_t"},
		{"bin", "int"},
		{"mode", "int"},
	}

	local function write_job_block(self, block)
		block.jobs = jobs_address
		block.contexts = visibility.GetContextsAddress()
		block.indices = index_pool.GetBuffer():GetDeviceAddress()
		block.offsets = offsets_address
		block.bin = resolve_bin
		block.mode = classify_mode
	end

	local function get_job_pipelines()
		if classify then return classify, bins, animate end

		classify = EasyPipeline.Compute{
			name = "visibility_classify",
			DescriptorSetCount = get_descriptor_count(),
			LocalSize = {x = 8, y = 8, z = 1},
			descriptor_sets = get_storage_descriptors(0),
			block = job_block,
			write = write_job_block,
			shader = JOBS_HEADER .. visibility.CONTEXT_GLSL .. model_pipeline.BuildPBRBatchRecordGlsl() .. string.format(
					[[
				layout(set = 0, binding = %d, rgba32ui) uniform readonly uimage2D visibility_ids;
				layout(buffer_reference, scalar) readonly buffer VisibilityContexts { VisibilityContext c[]; };
				layout(buffer_reference, scalar) readonly buffer VisibilityBatchIds { uvec2 ids[]; };

				void main() {
					ivec2 quad = ivec2(gl_GlobalInvocationID.xy);
					ivec2 size = imageSize(visibility_ids);

					if (any(greaterThanEqual(quad * 2, size))) return;

					uvec4 ids[4];

					for (int i = 0; i < 4; i++) {
						ivec2 p = quad * 2 + ivec2(i & 1, i >> 1);
						ids[i] = all(lessThan(p, size)) ? imageLoad(visibility_ids, p) : uvec4(0u);
					}

					VisibilityJobs jobs = VisibilityJobs(compute.jobs);
					VisibilityContexts contexts = VisibilityContexts(compute.contexts);
					uint used = 0u;

					for (int i = 0; i < 4; i++) {
						if (ids[i].x == 0u || (used & (1u << i)) != 0u) continue;

						uint mask = 0u;

						for (int j = i; j < 4; j++) {
							if (all(equal(ids[j], ids[i]))) mask |= 1u << j;
						}

						used |= mask;
						VisibilityContext context = contexts.c[ids[i].x - 1u];
						uint material = ids[i].z >> 6u;
						bool animated = false;

						if (context.kind == 0u) {
							material = context.batch_ids != 0ul ? VisibilityBatchIds(context.batch_ids).ids[ids[i].z].x : ids[i].y;
							PBRBatch_vertex_animation animation = PBRBatchData(context.batches).b[material].m_vertex_animation;
							animated = animation.MainBending > 0.0 || (animation.DetailBending != 0 && animation.BendSpeed > 0.0) || animation.PushBending > 0.0;
						}

						uint bin = ((context.kind * 2u + (animated ? 1u : 0u)) * %du + context.variant) * %du + ((material * 2654435761u) ^ (ids[i].x * 40503u)) %% %du;

						if (compute.mode == 0) {
							atomicAdd(jobs.counts[bin], 1u);
						} else {
							uint index = atomicAdd(jobs.cursors[bin], 1u);
							jobs.jobs[index] = uvec2(uint(quad.x) | (uint(quad.y) << 16u), mask);
						}
					}
				}
			]],
					IDS_BINDING,
					VARIANTS,
					MATERIAL_BINS,
					MATERIAL_BINS
				),
		}
		bins = EasyPipeline.Compute{
			name = "visibility_bins",
			LocalSize = {x = BINS, y = 1, z = 1},
			block = job_block,
			write = write_job_block,
			shader = JOBS_HEADER .. string.format(
					[[
				shared uint totals[%d];

				void main() {
					VisibilityJobs jobs = VisibilityJobs(compute.jobs);
					uint bin = gl_LocalInvocationID.x;
					uint total = 0u;

					for (uint i = 0u; i < %du; i++) {
						total += jobs.counts[bin * %du + i];
					}

					totals[bin] = total;
					barrier();
					uint base = 0u;

					for (uint i = 0u; i < bin; i++) {
						base += totals[i];
					}

					jobs.totals[bin] = total;
					jobs.bases[bin] = base;
					jobs.args[bin * 3u] = (total + %du) / %du;
					jobs.args[bin * 3u + 1u] = 1u;
					jobs.args[bin * 3u + 2u] = 1u;

					for (uint i = 0u; i < %du; i++) {
						jobs.cursors[bin * %du + i] = base;
						base += jobs.counts[bin * %du + i];
					}

					if (bin == 0u) {
						uint animated = 0u;

						for (uint i = %du; i < %du; i++) {
							animated += totals[i];
						}

						jobs.animate[0] = (animated * 3u + %du) / %du;
						jobs.animate[1] = 1u;
						jobs.animate[2] = 1u;
						jobs.animate[3] = animated;
					}
				}
			]],
					BINS,
					MATERIAL_BINS,
					MATERIAL_BINS,
					QUADS_PER_GROUP - 1,
					QUADS_PER_GROUP,
					MATERIAL_BINS,
					MATERIAL_BINS,
					MATERIAL_BINS,
					VARIANTS,
					VARIANTS * 2,
					ANIMATE_LOCAL_SIZE - 1,
					ANIMATE_LOCAL_SIZE
				),
		}
		animate = EasyPipeline.Compute{
			name = "visibility_animate",
			DescriptorSetCount = get_descriptor_count(),
			LocalSize = {x = ANIMATE_LOCAL_SIZE, y = 1, z = 1},
			descriptor_sets = get_storage_descriptors(0),
			uniform_buffers = {camera.block},
			block = job_block,
			write = write_job_block,
			shader = build_vertex_glsl(
					kinds[visibility.KIND_MULTI_DRAW].build(0).vertex,
					"#define VERTEX_ANIMATION_RECORD visibility_offset\n#define VERTEX_ANIMATION_PREVIOUS_RECORD visibility_previous_offset",
					visibility.KIND_MULTI_DRAW
				) .. string.format(
					[[
				void main() {
					uint job_index = gl_GlobalInvocationID.x / 3u;
					uint vertex = gl_GlobalInvocationID.x %% 3u;
					VisibilityJobs jobs = VisibilityJobs(compute.jobs);

					if (job_index >= jobs.animate[3]) return;

					visibility_offset = vec3(0.0);
					visibility_previous_offset = vec3(0.0);
					visibility_prepare(visibility_job_id(jobs.jobs[jobs.bases[%d] + job_index]), vertex);
					visibility_vertex_main();
					uint offset = (job_index * 3u + vertex) * 3u;
					VisibilityOffsets offsets = VisibilityOffsets(compute.offsets);
					offsets.v[offset] = packHalf2x16(visibility_offset.xy);
					offsets.v[offset + 1u] = packHalf2x16(vec2(visibility_offset.z, visibility_previous_offset.x));
					offsets.v[offset + 2u] = packHalf2x16(visibility_previous_offset.yz);
				}
			]],
					VARIANTS
				),
		}
		return classify, bins, animate
	end

	local function get_resolve_pipeline(bin)
		if resolves[bin] then return resolves[bin] end

		resolves[bin] = EasyPipeline.Compute{
			name = "visibility_resolve",
			DescriptorSetCount = get_descriptor_count(),
			LocalSize = {x = 8, y = 8, z = 1},
			descriptor_sets = get_storage_descriptors(#gbuffer_layout.targets),
			uniform_buffers = {camera.block},
			block = job_block,
			write = write_job_block,
			shader = build_resolve_shader(bin),
		}
		return resolves[bin]
	end

	function visibility.SetCamera(block, front_face)
		camera = {block = block, front_face = front_face}
	end

	function visibility.SetKind(kind, info)
		kinds[kind] = info
	end

	local function barrier(cmd, buffer, src_stage, dst_stage, src_access, dst_access)
		cmd:PipelineBarrier{
			srcStage = src_stage,
			dstStage = dst_stage,
			bufferBarriers = {
				{
					buffer = buffer,
					size = buffer.size,
					srcAccessMask = src_access,
					dstAccessMask = dst_access,
				},
			},
		}
	end

	function visibility.Resolve(cmd, framebuffer)
		if serial ~= render.frame_serial or count == 0 then return end

		local classify, bins, animate = get_job_pipelines()
		local ids = framebuffer:GetAttachment(gbuffer_layout.attachment_index.visibility)
		local width, height = ids:GetWidth(), ids:GetHeight()

		if not jobs or jobs_pixels < width * height then
			if jobs then
				jobs:Remove()
				offsets:Remove()
			end

			jobs_pixels = width * height
			jobs = render.CreateBuffer{
				byte_size = HEADER_BYTES + 8 * jobs_pixels,
				buffer_usage = {"storage_buffer", "shader_device_address", "indirect_buffer", "transfer_dst"},
				memory_property = {"device_local"},
				label = "visibility jobs",
			}
			offsets = render.CreateBuffer{
				byte_size = OFFSET_BYTES * jobs_pixels,
				buffer_usage = {"storage_buffer", "shader_device_address"},
				memory_property = {"device_local"},
				label = "visibility animation offsets",
			}
			jobs_address = jobs:GetDeviceAddress()
			offsets_address = offsets:GetDeviceAddress()
		end

		local slot = (resolve_count % RESOLVE_RING) * 3 + 1
		resolve_count = resolve_count + 1
		gpu_timing.BeginScope(cmd, "visibility_classify")
		barrier(cmd, jobs, "compute", "transfer", "shader_read", "transfer_write")
		cmd:FillBuffer(jobs, 0, HEADER_BYTES, 0)
		barrier(cmd, jobs, "transfer", "compute", "transfer_write", "shader_read")
		classify:BindStorageImage(cmd, slot, IDS_BINDING, ids)
		classify_mode = 0
		classify:DispatchForSize(cmd, math.ceil(width / 2), math.ceil(height / 2), 1, slot)
		barrier(cmd, jobs, "compute", "compute", "shader_write", "shader_read")
		bins:Dispatch(cmd, 1, 1, 1)
		barrier(cmd, jobs, "compute", "compute", "shader_write", "shader_read")
		classify_mode = 1
		classify:DispatchForSize(cmd, math.ceil(width / 2), math.ceil(height / 2), 1, slot)
		barrier(
			cmd,
			jobs,
			"compute",
			{"compute", "draw_indirect"},
			"shader_write",
			{"shader_read", "indirect_command_read"}
		)
		gpu_timing.EndScope(cmd, "visibility_classify")
		gpu_timing.BeginScope(cmd, "visibility_animate")
		animate:BindStorageImage(cmd, slot + 1, IDS_BINDING, ids)
		animate:DispatchIndirect(cmd, jobs, ANIMATE_ARGS_OFFSET, slot + 1)
		barrier(cmd, offsets, "compute", "compute", "shader_write", "shader_read")
		gpu_timing.EndScope(cmd, "visibility_animate")
		gpu_timing.BeginScope(cmd, "visibility_resolve")

		for key in pairs(used_variants) do
			local kind, bits = math.floor(key / VARIANTS), key % VARIANTS

			for bin = kind * VARIANTS * 2 + bits, kind == visibility.KIND_MULTI_DRAW and
				kind * VARIANTS * 2 + VARIANTS + bits or
				kind * VARIANTS * 2 + bits, VARIANTS do
				local resolve = get_resolve_pipeline(bin)
				resolve:BindStorageImage(cmd, slot + 2, IDS_BINDING, ids)

				for i = 1, #gbuffer_layout.targets do
					resolve:BindStorageImage(cmd, slot + 2, TARGET_BINDING + i - 1, framebuffer:GetAttachment(i))
				end

				resolve_bin = bin
				resolve:DispatchIndirect(cmd, jobs, ARGS_OFFSET + bin * 12, slot + 2)
			end
		end

		for i = 1, #gbuffer_layout.targets do
			render.TransitionResourceFrom(
				framebuffer:GetAttachment(i),
				"shader_read_only_optimal",
				{
					cmd = cmd,
					srcStage = "compute",
					srcAccess = "shader_write",
					dstStage = "all_commands",
					dstAccess = "shader_read",
				}
			)
		end

		gpu_timing.EndScope(cmd, "visibility_resolve")
	end
end

return visibility
