local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local gpu_timing = import("goluwa/render/gpu_timing.lua")
local pvars = import("goluwa/cli/pvars.lua")
local index_pool = import("goluwa/render3d/index_pool.lua")
local meshes = import("goluwa/render3d/scene/meshes.lua")
local orientation = import("goluwa/render3d/orientation.lua")
local visibility = import("goluwa/render3d/visibility.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local software_raster = {}
software_raster.CAPACITY = 32768
software_raster.MAX_PIXELS = 4096
pvars.StartGroup("Rendering", "Visibility buffer", {store = false})
local enabled = pvars.Setup2{
	key = "r_visibility_raster",
	default = true,
	help = "rasterize small dense clusters of cluster lod meshes in compute (64 bit depth and id atomics) instead of the hardware rasterizer, they then shade through the visibility buffer",
}
local density = pvars.Setup2{
	key = "r_visibility_raster_density",
	default = 0.5,
	help = "triangles per pixel of a cluster's bounding sphere above which it is rasterized in compute",
}
local radius = pvars.Setup2{
	key = "r_visibility_raster_radius",
	default = 24,
	help = "pixels, clusters whose bounding sphere projects larger stay on the hardware rasterizer",
}
local patch_pixels = pvars.Setup2{
	key = "r_visibility_raster_patch_pixels",
	default = 3,
	help = "pixels, tessellated patches whose small triangles span at most this many are rasterized in compute",
}
pvars.EndGroup()
software_raster.RECORD_GLSL = [[
	struct software_record {
		uvec4 a;
		uvec4 b;
	};
	layout(buffer_reference, scalar) buffer SoftwareRecords { software_record r[]; };
	layout(buffer_reference, scalar) buffer SoftwareHeader { uint count; uint y; uint z; uint pad; };
	layout(buffer_reference, scalar) buffer SoftwareDepth { uint64_t v[]; };
	layout(buffer_reference, scalar) buffer SoftwarePatches { uint count; uint y; uint z; uint pad; uvec2 r[]; };
]]
local buffers
local depth_buffer
local depth_pixels = 0
local frame_worlds = 0
local frame_width = 0
local cluster_serial = -1
local rasterizers = {}
local camera_block
local header_data = ffi.new("uint32_t[4]", 0, 1, 1, 0)
local stats_copy = ffi.typeof("$[1]", import("goluwa/render/vulkan/internal/vulkan.lua").vk.VkBufferCopy)()
local STATS_RING = 4
local stats_buffer
local stats_words
local stats_serial = -1

function software_raster.IsEnabled()
	return visibility.enabled and enabled:Get()
end

local function get_buffers()
	if buffers then return buffers end

	buffers = {
		records = render.CreateBuffer{
			byte_size = software_raster.CAPACITY * 32,
			buffer_usage = {"storage_buffer", "shader_device_address"},
			memory_property = {"device_local"},
			label = "software raster records",
		},
		header = render.CreateBuffer{
			byte_size = 16,
			buffer_usage = {
				"storage_buffer",
				"shader_device_address",
				"indirect_buffer",
				"transfer_dst",
				"transfer_src",
			},
			memory_property = {"device_local"},
			label = "software raster header",
		},
		patches = render.CreateBuffer{
			byte_size = 16 + software_raster.CAPACITY * 8,
			buffer_usage = {
				"storage_buffer",
				"shader_device_address",
				"indirect_buffer",
				"transfer_dst",
				"transfer_src",
			},
			memory_property = {"device_local"},
			label = "software raster patches",
		},
	}
	buffers.records_address = buffers.records:GetDeviceAddress()
	buffers.header_address = buffers.header:GetDeviceAddress()
	buffers.patches_address = buffers.patches:GetDeviceAddress()
	return buffers
end

function software_raster.GetCullArgs()
	if not software_raster.IsEnabled() then return 0, 0, 0, 0 end

	local b = get_buffers()
	return b.records_address, b.header_address, density:Get(), radius:Get()
end

function software_raster.Reset(cmd, worlds_address)
	if not software_raster.IsEnabled() then return end

	frame_worlds = worlds_address
	cluster_serial = render.frame_serial
	cmd:UpdateBuffer(get_buffers().header, 0, 16, header_data)
end

function software_raster.ResetPatches(cmd)
	if not software_raster.IsEnabled() then return 0, 0 end

	cmd:UpdateBuffer(get_buffers().patches, 0, 16, header_data)
	return get_buffers().patches_address, patch_pixels:Get()
end

function software_raster.GetPatches()
	return get_buffers().patches
end

function software_raster.AddRasterizer(rasterize)
	table.insert(rasterizers, rasterize)
end

function software_raster.GetDepthAddress()
	return depth_buffer:GetDeviceAddress()
end

function software_raster.GetCameraBlock()
	return camera_block
end

function software_raster.SetCameraBlock(block)
	camera_block = block
end

software_raster.RASTER_GLSL = [[
			int64_t software_edge(ivec2 a, ivec2 b, ivec2 p) {
				return int64_t(b.x - a.x) * int64_t(p.y - a.y) - int64_t(b.y - a.y) * int64_t(p.x - a.x);
			}

			bool software_owner(ivec2 a, ivec2 b) {
				return b.y < a.y || (b.y == a.y && b.x > a.x);
			}

			void software_raster_triangle(ivec2 q[3], float z[3], bool cull, uint64_t payload, SoftwareDepth depth, ivec2 size) {
				int64_t area = software_edge(q[0], q[1], q[2]);

				if (area == 0l) return;

				bool front = ]] .. (
		orientation.FRONT_FACE == "counter_clockwise" and
		"area < 0l" or
		"area > 0l"
	) .. [[;

				if (cull && front == ]] .. (
		orientation.CULL_MODE == "front" and
		"true" or
		"false"
	) .. [[) return;

				if (area < 0l) {
					ivec2 swap_q = q[1];
					q[1] = q[2];
					q[2] = swap_q;
					float swap_z = z[1];
					z[1] = z[2];
					z[2] = swap_z;
					area = -area;
				}

				ivec2 lo = min(q[0], min(q[1], q[2]));
				ivec2 hi = max(q[0], max(q[1], q[2]));
				ivec2 first = max((lo - 128 + 255) >> 8, ivec2(0));
				ivec2 last = min((hi - 128) >> 8, size - 1);

				if (any(lessThan(last, first))) return;

				if ((last.x - first.x + 1) * (last.y - first.y + 1) > ]] .. software_raster.MAX_PIXELS .. [[) return;

				int64_t bias0 = software_owner(q[1], q[2]) ? 0l : 1l;
				int64_t bias1 = software_owner(q[2], q[0]) ? 0l : 1l;
				int64_t bias2 = software_owner(q[0], q[1]) ? 0l : 1l;
				float inverse_area = 1.0 / float(area);

				for (int y = first.y; y <= last.y; y++) {
					for (int x = first.x; x <= last.x; x++) {
						ivec2 p = ivec2(x * 256 + 128, y * 256 + 128);
						int64_t w0 = software_edge(q[1], q[2], p);
						int64_t w1 = software_edge(q[2], q[0], p);
						int64_t w2 = software_edge(q[0], q[1], p);

						if (w0 < bias0 || w1 < bias1 || w2 < bias2) continue;

						float d = (float(w0) * z[0] + float(w1) * z[1] + float(w2) * z[2]) * inverse_area;
						atomicMax(depth.v[y * size.x + x], (uint64_t(floatBitsToUint(d)) << 32) | payload);
					}
				}
			}

		]]
local raster_pipeline

local function get_raster_pipeline()
	if raster_pipeline then return raster_pipeline end

	raster_pipeline = EasyPipeline.Compute{
		name = "software_raster",
		LocalSize = {x = 128, y = 1, z = 1},
		uniform_buffers = {camera_block},
		block = {
			{"records", "uint64_t"},
			{"depth", "uint64_t"},
			{"meshes", "uint64_t"},
			{"worlds", "uint64_t"},
			{"indices", "uint64_t"},
			{"capacity", "int"},
		},
		write = function(self, block)
			local b = get_buffers()
			block.records = b.records_address
			block.depth = depth_buffer:GetDeviceAddress()
			block.meshes = meshes.GetTable():GetAddress()
			block.worlds = frame_worlds
			block.indices = index_pool.GetBuffer():GetDeviceAddress()
			block.capacity = software_raster.CAPACITY
		end,
		shader = software_raster.RECORD_GLSL .. software_raster.RASTER_GLSL .. [[
			struct mesh_row {
				uint64_t vertex_address;
				uint64_t index_address;
				uint64_t blas;
				uint64_t extras_address;
				uint triangle_count;
				uint vertex_stride;
				uint flags;
				uint pool_first_index;
			};
			layout(buffer_reference, scalar) readonly buffer SoftwareMeshes { mesh_row m[]; };
			layout(buffer_reference, scalar) readonly buffer SoftwareWorlds { mat4 w[]; };
			layout(buffer_reference, scalar) readonly buffer SoftwareWords { uint v[]; };
			layout(buffer_reference, scalar) readonly buffer SoftwarePositions { float v[]; };

			void main() {
				uint record_index = gl_WorkGroupID.x;
				uint t = gl_LocalInvocationID.x;

				if (record_index >= uint(compute.capacity)) return;

				software_record record = SoftwareRecords(compute.records).r[record_index];

				if (t >= (record.a.y & 0xFFu)) return;

				uint set = record.a.y >> 8u;
				mesh_row mesh = SoftwareMeshes(compute.meshes).m[record.b.x];
				mat4 world = SoftwareWorlds(compute.worlds).w[record.a.z];
				SoftwarePositions positions = SoftwarePositions(mesh.vertex_address);
				uint stride = mesh.vertex_stride / 4u;
				vec2 size = gbuffer_data.render_size.xy;
				ivec2 q[3];
				float z[3];

				for (uint k = 0u; k < 3u; k++) {
					uint vi = SoftwareWords(compute.indices).v[record.a.x + t * 3u + k];
					vec3 p = vec3(positions.v[vi * stride], positions.v[vi * stride + 1u], positions.v[vi * stride + 2u]);
					vec4 clip = gbuffer_data.projection * gbuffer_data.view * vec4((world * vec4(p, 1.0)).xyz, 1.0);
					vec2 s = (clip.xy / clip.w * 0.5 + 0.5) * size;
					q[k] = ivec2(round(s * 256.0));
					z[k] = clip.z / clip.w;
				}

				software_raster_triangle(q, z, (set & 1u) == 0u, uint64_t((record_index << 7u) | t), SoftwareDepth(compute.depth), ivec2(size));
			}
		]],
	}
	return raster_pipeline
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

function software_raster.Rasterize(cmd, width, height)
	if not software_raster.IsEnabled() then return end

	if not depth_buffer or depth_pixels < width * height then
		if depth_buffer then depth_buffer:Remove() end

		depth_pixels = width * height
		depth_buffer = render.CreateBuffer{
			byte_size = depth_pixels * 8,
			buffer_usage = {"storage_buffer", "shader_device_address", "transfer_dst"},
			memory_property = {"device_local"},
			label = "software raster depth",
		}
	end

	frame_width = width
	local b = get_buffers()
	gpu_timing.BeginScope(cmd, "software_raster")
	barrier(cmd, depth_buffer, "fragment", "transfer", "shader_read", "transfer_write")
	cmd:FillBuffer(depth_buffer, 0, width * height * 8, 0)
	barrier(
		cmd,
		depth_buffer,
		"transfer",
		"compute",
		"transfer_write",
		{"shader_read", "shader_write"}
	)
	cmd:PipelineBarrier{
		srcStage = "compute",
		dstStage = {"compute", "draw_indirect"},
		memoryBarrier = true,
	}

	if cluster_serial == render.frame_serial then
		get_raster_pipeline():DispatchIndirect(cmd, b.header, 0)
	end

	for _, rasterize in ipairs(rasterizers) do
		rasterize(cmd, width)
	end

	barrier(cmd, depth_buffer, "compute", "fragment", "shader_write", "shader_read")

	if not stats_buffer then
		stats_buffer = render.CreateBuffer{
			byte_size = STATS_RING * 8,
			buffer_usage = {"transfer_dst"},
			memory_property = {"host_visible", "host_coherent", "host_cached"},
			label = "software raster stats",
		}
		stats_words = ffi.cast("uint32_t *", stats_buffer:Map())
	end

	cmd:PipelineBarrier{srcStage = "compute", dstStage = "transfer", memoryBarrier = true}
	stats_serial = render.frame_serial
	stats_copy[0].size = 4
	stats_copy[0].srcOffset = 0
	stats_copy[0].dstOffset = (stats_serial % STATS_RING) * 8
	cmd:CopyBuffer(b.header, stats_buffer, stats_copy, 1)
	stats_copy[0].dstOffset = (stats_serial % STATS_RING) * 8 + 4
	cmd:CopyBuffer(b.patches, stats_buffer, stats_copy, 1)
	gpu_timing.EndScope(cmd, "software_raster")
end

function software_raster.GetStats()
	if not stats_words then return 0, 0 end

	local slot = ((stats_serial - STATS_RING + 1) % STATS_RING) * 2
	return stats_words[slot], stats_words[slot + 1]
end

function software_raster.BuildEmitPass(base)
	local pass = table.copy(base)
	pass.name = "software_raster_emit"
	pass.draw_in_prerender = false
	pass.dont_create_framebuffers = true
	pass.on_draw = nil
	pass.on_pre_draw = nil
	pass.vertex = nil
	pass.CullMode = "none"
	pass.DepthTest = true
	pass.DepthWrite = true
	pass.DepthCompareOp = "greater"
	pass.ColorWriteMask = ""
	pass.color_blend = {attachments = {}}

	for i = 1, #gbuffer_layout.color_format do
		pass.color_blend.attachments[i] = {
			color_write_mask = i == gbuffer_layout.attachment_index.visibility and "rgba" or "",
		}
	end

	pass.fragment = {
		uniform_buffers = {
			{
				name = "software_emit",
				binding_index = 4,
				block = {
					{"records", "uint64_t"},
					{"depth", "uint64_t"},
					{"contexts", "uint64_t"},
					{"patches", "uint64_t"},
					{"width", "int"},
				},
				write = function(self, block)
					block.records = get_buffers().records_address
					block.depth = depth_buffer:GetDeviceAddress()
					block.contexts = visibility.GetSetContextsAddress()
					block.patches = get_buffers().patches_address
					block.width = frame_width
					return block
				end,
			},
		},
		shader = software_raster.RECORD_GLSL .. [[
			layout(buffer_reference, scalar) readonly buffer SoftwareContexts { uint c[]; };

			void main() {
				ivec2 pixel = ivec2(gl_FragCoord.xy);
				uint64_t value = SoftwareDepth(software_emit.depth).v[pixel.y * software_emit.width + pixel.x];

				if (value == 0ul) discard;

				uint payload = uint(value & 0xFFFFFFFFul);

				if ((payload & 0x80000000u) != 0u) {
					uvec2 software_patch = SoftwarePatches(software_emit.patches).r[(payload >> 12u) & 0x7FFFFu];
					uint context = SoftwareContexts(software_emit.contexts).c[software_patch.y];

					if (context == 0u) discard;

					set_visibility(uvec4(context, 0u, software_patch.x, payload & 4095u));
				} else {
					software_record record = SoftwareRecords(software_emit.records).r[payload >> 7u];
					uint context = SoftwareContexts(software_emit.contexts).c[record.a.y >> 8u];

					if (context == 0u) discard;

					set_visibility(uvec4(context, record.a.w, record.a.z, payload & 127u));
				}
				gl_FragDepth = uintBitsToFloat(uint(value >> 32ul));
			}
		]],
	}
	return pass
end

function software_raster.Emit(cmd, pipeline)
	if not software_raster.IsEnabled() or not depth_buffer then return end

	pipeline:UploadConstants()
	cmd:Draw(3, 1, 0, 0)
end

return software_raster
