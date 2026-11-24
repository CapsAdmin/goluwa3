local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local pvars = import("goluwa/cli/pvars.lua")
local system = import("goluwa/system.lua")
local instances = import("goluwa/render3d/scene/instances.lua")
local draw = import("goluwa/render3d/scene/draw.lua")
local visibility = import("goluwa/render3d/visibility.lua")
local software_raster = import("goluwa/render3d/scene/software_raster.lua")
local model_pipeline = import("goluwa/render3d/model_pipeline.lua")
local vertex_layout = import("goluwa/render3d/vertex_layout.lua")
local gbuffer_instancing = import("goluwa/render3d/gbuffer_instancing.lua")
local orientation = import("goluwa/render3d/orientation.lua")
local shader_features = import("goluwa/render3d/shader_features.lua")
local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
local meshes = import("goluwa/render3d/scene/meshes.lua")
local tessellation = {}
tessellation.name = "gbuffer_tessellated"
tessellation.visibility_kind = visibility.KIND_TESSELLATION
tessellation.MAX_LOG = 6
local BUCKETS = tessellation.MAX_LOG + 1
local GROUPS = 2
local TERRAIN_GROUP = 1
local TOPOLOGY_WORDS = 9
local PID_WORDS = 6
local JOB_BYTES = 80
local STATE_COMMANDS_BYTES = GROUPS * BUCKETS * 16
local STATE_ARGS_OFFSET = 256
local STATE_BYTES = STATE_ARGS_OFFSET + 8 * 8
local UPDATE_BUFFER_LIMIT = 65536

local function invalidate_scene()
	import("goluwa/entities/components/visual.lua").Library.InvalidateSceneAcceleration()
end

pvars.StartGroup("Rendering", "Tessellation", {store = false})
local enabled = pvars.Setup2{
	key = "r_tessellation",
	default = true,
	callback = invalidate_scene,
	help = "draw height mapped materials marked HeightTessellate as displaced geometry instead of marching parallax",
}
local tessellate_all = pvars.Setup2{
	key = "r_tessellation_all",
	default = true,
	callback = invalidate_scene,
	help = "tessellate every height mapped material, not only the ones marked HeightTessellate",
}
local seam_band = pvars.Setup2{
	key = "r_tessellation_seam_band",
	default = 0.35,
	help = "how far into a triangle (as a fraction of it) heights are blended toward the average of the two sides of a uv seam",
}
pvars.EndGroup()

do
	local available

	function tessellation.IsAvailable()
		if available == nil then
			local features = render.GetPhysicalDevice():GetFeatures()
			available = features.multiDrawIndirect == 1 and features.drawIndirectFirstInstance == 1
		end

		return available
	end
end

function tessellation.IsEligible(material, entry)
	if not enabled:Get() or not tessellation.IsAvailable() then return false end

	local polygon3d = entry.polygon3d

	if material.terrain_tile then
		return material.TerrainShell > 0 and polygon3d.TopologySource ~= nil
	end

	if not material:HasHeightMap() then return false end

	if not (material.HeightTessellate or tessellate_all:Get()) then return false end

	if
		material.HeightShell > 0 or
		material.TerrainShell > 0 or
		material:GetRasterBothFaces() or
		material:HasVertexAnimation() or
		material:IsTransparent()
	then
		return false
	end

	if polygon3d.shell_grid or polygon3d.Skin then return false end

	if (entry.lod_last or 0) > 0 then return false end

	return polygon3d.packed ~= nil or polygon3d.Vertices[1] ~= nil
end

local rows = {}
local row_serial = 0

function tessellation.SetRow(id, mesh, material, polygon3d)
	local row = rows[id]

	if
		row and
		row.mesh == mesh and
		row.material == material and
		row.polygon3d == polygon3d
	then
		return
	end

	rows[id] = {mesh = mesh, material = material, polygon3d = polygon3d}
	row_serial = row_serial + 1
end

function tessellation.ClearRow(id)
	if rows[id] then
		rows[id] = nil
		row_serial = row_serial + 1
	end
end

do
	local topologies = setmetatable({}, {__mode = "k"})
	local float_bits = ffi.new("union { float f[3]; uint32_t u[3]; }")

	local function read_polygon(polygon3d)
		local px, py, pz, nx, ny, nz, u, v = {}, {}, {}, {}, {}, {}, {}, {}
		local indices = {}
		local packed = polygon3d.TopologySource or polygon3d.packed
		local vertex_count

		if packed then
			vertex_count = packed.vertex_count

			for i = 0, vertex_count - 1 do
				local vertex = packed.vertices[i]
				px[i], py[i], pz[i] = vertex.position[0], vertex.position[1], vertex.position[2]
				nx[i], ny[i], nz[i] = vertex.normal[0], vertex.normal[1], vertex.normal[2]
				u[i], v[i] = vertex.uv[0], vertex.uv[1]
			end

			for i = 0, packed.index_count - 1 do
				indices[i] = packed.indices[i]
			end

			return vertex_count, px, py, pz, nx, ny, nz, u, v, indices, packed.index_count
		end

		local vertices = polygon3d.Vertices

		if not vertices[1] then
			local mesh = polygon3d.mesh
			vertex_count = mesh.vertex_buffer:GetVertexCount()
			local joined = vertex_layout.Join(mesh.vertex_buffer.data, mesh.extras.data or mesh.extras.value, vertex_count)

			for i = 0, vertex_count - 1 do
				local vertex = joined[i]
				px[i], py[i], pz[i] = vertex.position[0], vertex.position[1], vertex.position[2]
				nx[i], ny[i], nz[i] = vertex.normal[0], vertex.normal[1], vertex.normal[2]
				u[i], v[i] = vertex.uv[0], vertex.uv[1]
			end

			local index_buffer = mesh.index_buffer
			local source = index_buffer.indices
			local index_count = index_buffer:GetIndexCount()

			for i = 0, index_count - 1 do
				indices[i] = type(source) == "table" and source[i + 1] or source[i]
			end

			return vertex_count, px, py, pz, nx, ny, nz, u, v, indices, index_count
		end

		vertex_count = #vertices

		for i = 1, vertex_count do
			local vertex = vertices[i]
			px[i - 1], py[i - 1], pz[i - 1] = vertex.pos.x, vertex.pos.y, vertex.pos.z
			local normal = vertex.normal
			nx[i - 1], ny[i - 1], nz[i - 1] = normal and normal.x or 0, normal and normal.y or 0, normal and normal.z or 0
			u[i - 1], v[i - 1] = vertex.uv and vertex.uv.x or 0, vertex.uv and vertex.uv.y or 0
		end

		local source = polygon3d.indices

		if source then
			for i = 1, #source do
				indices[i - 1] = source[i] - 1
			end

			return vertex_count, px, py, pz, nx, ny, nz, u, v, indices, #source
		end

		for i = 0, vertex_count - 1 do
			indices[i] = i
		end

		return vertex_count, px, py, pz, nx, ny, nz, u, v, indices, vertex_count
	end

	local function build_topology(polygon3d)
		local vertex_count, px, py, pz, nx, ny, nz, u, v, indices, index_count = read_polygon(polygon3d)
		local triangle_count = math.floor(index_count / 3)
		local pid_of_vertex = {}
		local pid_lookup = {}
		local pid_count = 0
		local pid_vertices = {}

		for i = 0, vertex_count - 1 do
			float_bits.f[0], float_bits.f[1], float_bits.f[2] = px[i], py[i], pz[i]
			local a, b, c = float_bits.u[0], float_bits.u[1], float_bits.u[2]
			local by_a = pid_lookup[a]

			if not by_a then
				by_a = {}
				pid_lookup[a] = by_a
			end

			local by_b = by_a[b]

			if not by_b then
				by_b = {}
				by_a[b] = by_b
			end

			local pid = by_b[c]

			if not pid then
				pid = pid_count
				pid_count = pid_count + 1
				by_b[c] = pid
				pid_vertices[pid] = {}
			end

			pid_of_vertex[i] = pid
			local list = pid_vertices[pid]
			list[#list + 1] = i
		end

		local dir_x, dir_y, dir_z, scale_sum, scale_count = {}, {}, {}, {}, {}

		for pid = 0, pid_count - 1 do
			dir_x[pid], dir_y[pid], dir_z[pid], scale_sum[pid], scale_count[pid] = 0, 0, 0, 0, 0
		end

		local edges = {}

		for t = 0, triangle_count - 1 do
			local i0, i1, i2 = indices[t * 3], indices[t * 3 + 1], indices[t * 3 + 2]
			local e1x, e1y, e1z = px[i1] - px[i0], py[i1] - py[i0], pz[i1] - pz[i0]
			local e2x, e2y, e2z = px[i2] - px[i0], py[i2] - py[i0], pz[i2] - pz[i0]
			local fx, fy, fz = e1y * e2z - e1z * e2y, e1z * e2x - e1x * e2z, e1x * e2y - e1y * e2x
			local vx, vy, vz = nx[i0] + nx[i1] + nx[i2], ny[i0] + ny[i1] + ny[i2], nz[i0] + nz[i1] + nz[i2]

			if fx * vx + fy * vy + fz * vz < 0 then fx, fy, fz = -fx, -fy, -fz end

			local du1, dv1 = u[i1] - u[i0], v[i1] - v[i0]
			local du2, dv2 = u[i2] - u[i0], v[i2] - v[i0]
			local det = du1 * dv2 - du2 * dv1
			local scale

			if math.abs(det) > 1e-12 then
				local ux, uy, uz = (e1x * dv2 - e2x * dv1) / det,
				(e1y * dv2 - e2y * dv1) / det,
				(e1z * dv2 - e2z * dv1) / det
				local wx, wy, wz = (e2x * du1 - e1x * du2) / det,
				(e2y * du1 - e1y * du2) / det,
				(e2z * du1 - e1z * du2) / det
				scale = math.sqrt(math.sqrt(ux * ux + uy * uy + uz * uz) * math.sqrt(wx * wx + wy * wy + wz * wz))
			end

			for k = 0, 2 do
				local pid = pid_of_vertex[indices[t * 3 + k]]
				dir_x[pid], dir_y[pid], dir_z[pid] = dir_x[pid] + fx, dir_y[pid] + fy, dir_z[pid] + fz

				if scale then
					scale_sum[pid] = scale_sum[pid] + scale
					scale_count[pid] = scale_count[pid] + 1
				end
			end

			for e = 0, 2 do
				local a = pid_of_vertex[indices[t * 3 + (e == 2 and 1 or 0)]]
				local b = pid_of_vertex[indices[t * 3 + (e == 0 and 1 or 2)]]
				local lo, hi = math.min(a, b), math.max(a, b)
				local by_lo = edges[lo]

				if not by_lo then
					by_lo = {}
					edges[lo] = by_lo
				end

				local users = by_lo[hi]

				if not users then
					users = {}
					by_lo[hi] = users
				end

				users[#users + 1] = t
			end
		end

		local corner_total = vertex_count
		local topology_bytes = triangle_count * TOPOLOGY_WORDS * 4
		local pids_offset = math.ceil(topology_bytes / 16) * 16
		local corners_offset = pids_offset + math.ceil(pid_count * PID_WORDS * 4 / 16) * 16
		local buffer = render.CreateBuffer{
			byte_size = math.max(corners_offset + corner_total * 4, 16),
			buffer_usage = {"storage_buffer", "shader_device_address"},
			memory_property = {"host_visible", "host_coherent"},
			label = "tessellation_topology",
		}
		local mapped = ffi.cast("uint8_t *", buffer:Map())
		local topology = ffi.cast("uint32_t *", mapped)
		local pid_words = ffi.cast("uint32_t *", mapped + pids_offset)
		local pid_floats = ffi.cast("float *", mapped + pids_offset)
		local corners = ffi.cast("uint32_t *", mapped + corners_offset)

		for t = 0, triangle_count - 1 do
			local base = t * TOPOLOGY_WORDS

			for k = 0, 2 do
				topology[base + k] = pid_of_vertex[indices[t * 3 + k]]
			end

			for e = 0, 2 do
				local ia = indices[t * 3 + (e == 2 and 1 or 0)]
				local ib = indices[t * 3 + (e == 0 and 1 or 2)]
				local a, b = pid_of_vertex[ia], pid_of_vertex[ib]
				local users = edges[math.min(a, b)][math.max(a, b)]
				local twin_a, twin_b = ia, ib

				if #users == 2 then
					local other = users[1] == t and users[2] or users[1]

					for k = 0, 2 do
						local index = indices[other * 3 + k]

						if pid_of_vertex[index] == a then twin_a = index end

						if pid_of_vertex[index] == b then twin_b = index end
					end
				end

				topology[base + 3 + e * 2] = twin_a
				topology[base + 3 + e * 2 + 1] = twin_b
			end
		end

		local corner_at = 0

		for pid = 0, pid_count - 1 do
			local x, y, z = dir_x[pid], dir_y[pid], dir_z[pid]
			local length = math.sqrt(x * x + y * y + z * z)

			if length > 0 then
				x, y, z = x / length, y / length, z / length
			else
				x, y, z = 0, 1, 0
			end

			local base = pid * PID_WORDS
			pid_floats[base], pid_floats[base + 1], pid_floats[base + 2] = x, y, z
			pid_floats[base + 3] = scale_count[pid] > 0 and scale_sum[pid] / scale_count[pid] or 1
			local list = pid_vertices[pid]
			pid_words[base + 4] = corner_at
			pid_words[base + 5] = #list

			for _, index in ipairs(list) do
				corners[corner_at] = index
				corner_at = corner_at + 1
			end
		end

		local address = buffer:GetDeviceAddress()
		return {
			buffer = buffer,
			triangle_count = triangle_count,
			topology_address = address,
			pids_address = address + pids_offset,
			corners_address = address + corners_offset,
		}
	end

	function tessellation.GetTopology(polygon3d)
		local key = polygon3d.TopologySource or polygon3d.mesh
		local topology = topologies[key]

		if not topology then
			topology = build_topology(polygon3d)
			topologies[key] = topology
		end

		return topology
	end
end

local TESS_GLSL = [[
	struct TessJob {
		uint instance;
		uint batch;
		uint first_triangle;
		uint triangle_count;
		uint64_t topology;
		uint64_t pids;
		uint64_t corners;
		uint64_t vertices;
		uint64_t indices;
		uint index_is_32;
		float height_scale;
		uint flags;
		float uv_size;
		float texel;
		uint pad;
	};

	struct TessPid {
		vec3 dir;
		float scale;
		uint first;
		uint count;
	};

	layout(buffer_reference, scalar) readonly buffer TessJobData { TessJob j[]; };
	layout(buffer_reference, scalar) readonly buffer TessPidData { TessPid p[]; };
	layout(buffer_reference, scalar) buffer TessWords { uint w[]; };
	layout(buffer_reference, scalar) buffer TessWorldData { mat4 w[]; };
	layout(buffer_reference, scalar) buffer TessPatchData { uvec4 p[]; };
	layout(buffer_reference, scalar) readonly buffer TessVertexData { float v[]; };

	uint tess_index(uint64_t address, uint index_is_32, uint i) {
		TessWords indices = TessWords(address);

		if (index_is_32 != 0u) return indices.w[i];

		uint word = indices.w[i >> 1];
		return (i & 1u) == 0u ? (word & 0xFFFFu) : (word >> 16);
	}

	uint tess_edge_rate(float edge_length, float edge_pixels, float relief_pixels, float uv_size, float texel, float error, int max_log) {
		if (relief_pixels <= error || edge_length <= 0.0) return 0u;

		float ratio = error / relief_pixels;
		float spacing = max(uv_size * max(ratio * ratio, texel), error * edge_length / max(edge_pixels, 1e-6));
		return uint(clamp(int(ceil(log2(max(edge_length / spacing, 1.0)) - 1e-6)), 0, max_log));
	}
]] .. vertex_layout.BuildGlslAccessors("tess_vertex", "TessVertexData")
local state = {
	ready = false,
	job_capacity = 0,
	triangle_capacity = 0,
	jobs_cpu = nil,
	batches = {},
	batch_serial = 0,
	built_serial = -1,
	job_count = 0,
	job_rows = {},
	triangle_count = 0,
	stats = {jobs = 0, triangles = 0},
}
local compute_block = {
	{"view_projection", "mat4"},
	{"camera_position", "vec3"},
	{"error", "float"},
	{"resolution", "vec2"},
	{"focal", "float"},
	{"job_count", "int"},
	{"triangle_count", "int"},
	{"capacity", "int"},
	{"args", "uint64_t"},
	{"software_pixels", "float"},
	{"software_cache", "int"},
	{"software_cache_pixels", "float"},
}

local function write_compute_block(self, block)
	state.view_projection:CopyToFloatPointer(block.view_projection)
	local position = state.camera_position
	block.camera_position[0], block.camera_position[1], block.camera_position[2] = position.x, position.y, position.z
	block.error = pvars.Get("r_cluster_lod_error")
	block.resolution[0], block.resolution[1] = state.resolution.x, state.resolution.y
	block.focal = state.focal
	block.job_count = state.job_count
	block.triangle_count = state.triangle_count
	block.capacity = state.triangle_capacity
	block.args = state.state_address + STATE_ARGS_OFFSET
	block.software_pixels = state.software_pixels or 0
	block.software_cache = state.software_cache or 0
	block.software_cache_pixels = state.software_cache_pixels or 0
	return block
end

local COMPUTE_GLSL = [[
	#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require
	const int TESS_MAX_LOG = ]] .. tessellation.MAX_LOG .. [[;
	]] .. instances.TLAS_INSTANCE_GLSL .. instances.INSTANCE_DATA_GLSL .. instances.RASTER_DATA_GLSL .. [[
	layout(buffer_reference, scalar) readonly buffer TessArgs { uint64_t a[]; };
	layout(buffer_reference, scalar) readonly buffer TessTLAS { tlas_instance t[]; };
	layout(buffer_reference, scalar) readonly buffer TessInstanceData { instance_data d[]; };
	layout(buffer_reference, scalar) readonly buffer TessRaster { raster_data r[]; };
	]] .. TESS_GLSL .. model_pipeline.BuildPBRBatchRecordGlsl() .. draw.WORLD_FROM_GLSL .. software_raster.RECORD_GLSL
local compute_pipelines

local function get_compute_pipelines()
	if compute_pipelines then return compute_pipelines end

	compute_pipelines = {
		worlds = EasyPipeline.Compute{
			name = "tessellation_worlds",
			LocalSize = {x = 64, y = 1, z = 1},
			block = compute_block,
			write = write_compute_block,
			shader = COMPUTE_GLSL .. [=[
				void main() {
					uint job_index = gl_GlobalInvocationID.x;

					if (job_index >= uint(compute.job_count)) return;

					TessArgs args = TessArgs(compute.args);
					TessJob job = TessJobData(args.a[0]).j[job_index];
					tlas_instance t = TessTLAS(args.a[4]).t[job.instance];
					instance_data inst = TessInstanceData(args.a[5]).d[job.instance];
					raster_data raster = TessRaster(args.a[6]).r[job.instance];
					TessWorldData worlds = TessWorldData(args.a[1]);
					worlds.w[job_index * 2u] = world_from(t.m, 0.0, inst.dynamic, inst.overlay);
					worlds.w[job_index * 2u + 1u] = world_from(raster.prev, 0.0, inst.dynamic, inst.overlay);
				}
			]=],
		},
		cull = EasyPipeline.Compute{
			name = "tessellation_cull",
			LocalSize = {x = 64, y = 1, z = 1},
			block = compute_block,
			write = write_compute_block,
			shader = COMPUTE_GLSL .. [=[
				vec4 tess_clip(mat4 world, vec3 local_position) {
					return compute.view_projection * (world * vec4(local_position, 1.0));
				}

				void main() {
					uint g = gl_GlobalInvocationID.x;

					if (g >= uint(compute.triangle_count)) return;

					TessArgs args = TessArgs(compute.args);
					TessJobData jobs = TessJobData(args.a[0]);
					uint lo = 0u;
					uint hi = uint(compute.job_count) - 1u;

					while (lo < hi) {
						uint mid = (lo + hi + 1u) >> 1;

						if (jobs.j[mid].first_triangle <= g) lo = mid; else hi = mid - 1u;
					}

					TessJob job = jobs.j[lo];
					uint tri = g - job.first_triangle;

					if (tri >= job.triangle_count) return;

					if ((TessInstanceData(args.a[5]).d[job.instance].flags & 16u) != 0u) return;

					mat4 world = TessWorldData(args.a[1]).w[lo * 2u];
					float height_scale = job.height_scale;
					TessVertexData data = TessVertexData(job.vertices);
					TessWords topology = TessWords(job.topology);
					TessPidData pids = TessPidData(job.pids);
					vec3 position[3];
					vec3 dir[3];
					float scale[3];
					uint pid[3];

					bool terrain = (job.flags & 2u) != 0u;
					int off_grid = 0;

					for (uint k = 0u; k < 3u; k++) {
						uint vertex = tess_index(job.indices, job.index_is_32, tri * 3u + k);
						position[k] = tess_vertex_position(data, vertex);
						off_grid += abs(tess_vertex_tangent(data, vertex).w) > 1.5 ? 1 : 0;
						pid[k] = topology.w[tri * 9u + k];
						TessPid p = pids.p[pid[k]];
						dir[k] = terrain ? vec3(0.0, 1.0, 0.0) : p.dir;
						scale[k] = terrain ? 1.0 : p.scale;
					}

					if (off_grid == 3) return;

					int outside_x0 = 0, outside_x1 = 0, outside_y0 = 0, outside_y1 = 0, behind = 0;
					vec2 ndc_lo = vec2(1e30);
					vec2 ndc_hi = vec2(-1e30);
					float min_w = 1e30;

					for (int i = 0; i < 6; i++) {
						int k = i % 3;
						float level = i < 3 ? 0.0 : 1.0;
						vec4 c = tess_clip(world, position[k] + dir[k] * (level * height_scale * scale[k]));
						min_w = min(min_w, c.w);
						ndc_lo = min(ndc_lo, c.xy / max(c.w, 1e-6));
						ndc_hi = max(ndc_hi, c.xy / max(c.w, 1e-6));
						outside_x0 += c.x < -c.w ? 1 : 0;
						outside_x1 += c.x > c.w ? 1 : 0;
						outside_y0 += c.y < -c.w ? 1 : 0;
						outside_y1 += c.y > c.w ? 1 : 0;
						behind += c.w <= 0.0 ? 1 : 0;
					}

					if (outside_x0 == 6 || outside_x1 == 6 || outside_y0 == 6 || outside_y1 == 6 || behind == 6) return;

					uint rate[3];

					for (int e = 0; e < 3; e++) {
						int ia = e == 2 ? 1 : 0;
						int ib = e == 0 ? 1 : 2;

						if (pid[ia] > pid[ib]) {
							int swap = ia;
							ia = ib;
							ib = swap;
						}

						vec4 ca = tess_clip(world, position[ia] + dir[ia] * (0.5 * height_scale * scale[ia]));
						vec4 cb = tess_clip(world, position[ib] + dir[ib] * (0.5 * height_scale * scale[ib]));
						uint log_rate = uint(TESS_MAX_LOG);

						if (ca.w > 0.01 && cb.w > 0.01) {
							float pixels = length((ca.xy / ca.w - cb.xy / cb.w) * 0.5 * compute.resolution);
							float relief_pixels = height_scale * max(scale[ia], scale[ib]) * compute.focal / min(ca.w, cb.w);
							log_rate = tess_edge_rate(distance((world * vec4(position[ia], 1.0)).xyz, (world * vec4(position[ib], 1.0)).xyz), pixels, relief_pixels, job.uv_size * min(scale[ia], scale[ib]), job.texel, compute.error, TESS_MAX_LOG);
						}

						rate[e] = log_rate;
					}

					uint inner = max(max(rate[0], rate[1]), rate[2]);
					uint rates = rate[0] | (rate[1] << 4) | (rate[2] << 8) | (inner << 12);

					if (args.a[7] != 0ul && inner >= 2u && (job.flags & 1u) == 0u && min_w > 0.05) {
						vec2 extent = (ndc_hi - ndc_lo) * 0.5 * compute.resolution;
						float span = max(extent.x, extent.y);

						if (span <= compute.software_pixels * float(1u << inner)) {
							SoftwarePatches list = SoftwarePatches(args.a[7]);
							uint record = atomicAdd(list.count, 1u);

							if (record < min(uint(compute.capacity), ]=] .. software_raster.CAPACITY .. [=[u)) {
								uint instance = ]=] .. GROUPS * BUCKETS .. [=[u * uint(compute.capacity) + record;
								TessPatchData(args.a[3]).p[instance] = uvec4(lo, tri, rates, 0u);
								uint vertices = ((1u << inner) + 1u) * ((1u << inner) + 2u) / 2u;
								uint cache = span <= compute.software_cache_pixels * float(1u << inner) ? atomicAdd(list.cache_cursor, vertices) : 0xFFFFFFFFu;
								list.r[record] = uvec4(instance, ]=] .. visibility.TESSELLATION_SET .. [=[u + (terrain ? 1u : 0u), cache != 0xFFFFFFFFu && cache + vertices <= uint(compute.software_cache) ? cache : 0xFFFFFFFFu, 0u);
								return;
							}
						}
					}

					uint bucket = (terrain ? ]=] .. TERRAIN_GROUP * BUCKETS .. [=[u : 0u) + inner;
					uint slot = atomicAdd(TessWords(args.a[2]).w[bucket * 4u + 1u], 1u);
					TessPatchData(args.a[3]).p[bucket * uint(compute.capacity) + slot] = uvec4(lo, tri, rates, 0u);
				}
			]=],
		},
	}
	return compute_pipelines
end

local tess_block = {
	name = "tess_draw",
	block = {
		{"jobs", "uint64_t"},
		{"worlds", "uint64_t"},
		{"patches", "uint64_t"},
		{"seam_band", "float"},
	},
	write = function(self, block)
		block.jobs = state.jobs_address or 0
		block.worlds = state.worlds_address or 0
		block.patches = state.patches_address or 0
		block.seam_band = seam_band:Get()
		return block
	end,
}
tessellation.VISIBILITY_DECLARATIONS = [[
	struct VisibilityTessDraw {
		uint64_t jobs;
		uint64_t worlds;
		uint64_t patches;
		float seam_band;
	};
	VisibilityTessDraw tess_draw;
	uint64_t visibility_tess_cache;
	layout(buffer_reference, scalar) readonly buffer VisibilityTessPatches { uvec4 r[]; };
]]
tessellation.VISIBILITY_PREPARE = [[
	tess_draw.jobs = context.extra0;
	tess_draw.worlds = context.extra1;
	tess_draw.patches = context.extra2;
	tess_draw.seam_band = context.extra_float;
	visibility_tess_cache = 0ul;

	if (context.extra3 != 0ul && id.y >= context.extra_uint) {
		uint cache = VisibilityTessPatches(context.extra3 + 16ul).r[id.y - context.extra_uint].z;
		visibility_tess_cache = context.extra3 + ]] .. software_raster.PATCH_CACHE_OFFSET .. [[ul + uint64_t(cache) * ]] .. software_raster.PATCH_SAMPLE_WORDS * 4 .. [[ul;
	}
]]
tessellation.VISIBILITY_CLASSIFY_DECLARATIONS = [[
	layout(buffer_reference, scalar) readonly buffer VisibilityTessPatches { uvec4 r[]; };
]]
tessellation.VISIBILITY_CLASSIFY = [[
	if (context.extra3 != 0ul && ids[i].y >= context.extra_uint) {
		animated = VisibilityTessPatches(context.extra3 + 16ul).r[ids[i].y - context.extra_uint].z != 0xFFFFFFFFu;
	}
]]
local TESS_EVAL_GLSL = [=[
	int tess_fade_texture;

	float tess_sample(int texture_index, vec2 uv, float lod) {
		if (texture_index < 0) return 0.0;

		float height = textureLod(TEXTURE(texture_index), uv, lod).r;

		if (tess_fade_texture >= 0) height *= textureLod(TEXTURE(tess_fade_texture), uv, lod).a;

		return height;
	}

	float tess_lod(vec2 a, vec2 b, vec2 size, int rate) {
		return log2(max(length((b - a) * size) / float(rate), 1.0));
	}

	struct TessPoint {
		vec3 base;
		vec3 dir;
		float scale;
		float height;
		float spacing;
		float displace;
	};

	float tess_displace(TessVertexData data, uint vertex) {
		return abs(tess_vertex_tangent(data, vertex).w) > 1.5 ? 0.0 : 1.0;
	}

	TessPoint tess_edge(TessVertexData data, TessPidData pids, int height_texture, vec2 height_size, uint va, uint vb, uint ta, uint tb, uint pa, uint pb, int rate, float t) {
		if (pa > pb) {
			uint swap = va; va = vb; vb = swap;
			swap = ta; ta = tb; tb = swap;
			swap = pa; pa = pb; pb = swap;
			t = 1.0 - t;
		}

		TessPid da = pids.p[pa];
		TessPid db = pids.p[pb];
		vec2 ua = tess_vertex_uv(data, va);
		vec2 ub = tess_vertex_uv(data, vb);
		vec2 sa = tess_vertex_uv(data, ta);
		vec2 sb = tess_vertex_uv(data, tb);
		TessPoint point;
		vec3 xa = tess_vertex_position(data, va);
		vec3 xb = tess_vertex_position(data, vb);
		point.base = mix(xa, xb, t);
		point.spacing = length(xb - xa) / float(rate);
		point.displace = mix(tess_displace(data, va), tess_displace(data, vb), t);
		point.dir = normalize(mix(da.dir, db.dir, t));
		point.scale = mix(da.scale, db.scale, t);
		point.height = 0.5 * (
			tess_sample(height_texture, mix(ua, ub, t), tess_lod(ua, ub, height_size, rate)) +
			tess_sample(height_texture, mix(sa, sb, t), tess_lod(sa, sb, height_size, rate))
		);
		return point;
	}

	int tess_snap(int value, int n, int rate) {
		int step = n / rate;
		return (value / step) * step;
	}

	struct TessSample {
		vec3 local_position;
		vec3 world_position;
		vec3 normal;
		vec4 tangent;
		vec2 uv;
		float texture_blend;
		vec4 vertex_color;
	};

	TessSample tess_evaluate(TessJob job, uint tri, uint rates, ivec2 q, mat4 world, TessVertexData data, TessVertexData extras, int height_texture, float seam_band) {
		float height_scale = job.height_scale;
		vec2 height_size = vec2(textureSize(TEXTURE(height_texture), 0));
		TessWords topology = TessWords(job.topology);
		TessPidData pids = TessPidData(job.pids);
		uint vi[3];
		uint pid[3];
		uint twin[6];

		for (uint k = 0u; k < 3u; k++) {
			vi[k] = tess_index(job.indices, job.index_is_32, tri * 3u + k);
			pid[k] = topology.w[tri * 9u + k];
		}

		for (uint k = 0u; k < 6u; k++) {
			twin[k] = topology.w[tri * 9u + 3u + k];
		}

		int rab = 1 << int(rates & 15u);
		int rac = 1 << int((rates >> 4) & 15u);
		int rbc = 1 << int((rates >> 8) & 15u);
		int n = 1 << int((rates >> 12) & 15u);
		bool on_ab = q.y == 0;
		bool on_ac = q.y == q.x;
		bool on_bc = q.x == n;

		if (on_ab) q.x = tess_snap(q.x, n, rab);
		if (on_ac) { q.x = tess_snap(q.x, n, rac); q.y = q.x; }
		if (on_bc) q.y = tess_snap(q.y, n, rbc);

		float wa = float(n - q.x) / float(n);
		float wb = float(q.x - q.y) / float(n);
		float wc = float(q.y) / float(n);
		int corner_id = q == ivec2(0, 0) ? 0 : (q == ivec2(n, 0) ? 1 : (q == ivec2(n, n) ? 2 : -1));
		int edge_id = -1;
		float edge_t = 0.0;

		if (corner_id < 0) {
			if (q.y == 0) { edge_id = 0; edge_t = float(q.x) / float(n); }
			else if (q.y == q.x) { edge_id = 1; edge_t = float(q.x) / float(n); }
			else if (q.x == n) { edge_id = 2; edge_t = float(q.y) / float(n); }
		}

		vec2 uv = wa * tess_vertex_uv(data, vi[0]) + wb * tess_vertex_uv(data, vi[1]) + wc * tess_vertex_uv(data, vi[2]);
		vec3 normal = wa * tess_vertex_normal(data, vi[0]) + wb * tess_vertex_normal(data, vi[1]) + wc * tess_vertex_normal(data, vi[2]);
		vec4 tangent = wa * tess_vertex_tangent(data, vi[0]) + wb * tess_vertex_tangent(data, vi[1]) + wc * tess_vertex_tangent(data, vi[2]);
		float texture_blend = wa * tess_vertex_texture_blend(extras, vi[0]) + wb * tess_vertex_texture_blend(extras, vi[1]) + wc * tess_vertex_texture_blend(extras, vi[2]);
		vec4 vertex_color = wa * tess_vertex_color(extras, vi[0]) + wb * tess_vertex_color(extras, vi[1]) + wc * tess_vertex_color(extras, vi[2]);
		TessPoint point;

		if (corner_id >= 0) {
			TessPid p = pids.p[pid[corner_id]];
			point.base = tess_vertex_position(data, vi[corner_id]);
			point.spacing = 0.0;
			point.displace = tess_displace(data, vi[corner_id]);
			point.dir = p.dir;
			point.scale = p.scale;
			TessWords corners = TessWords(job.corners);
			float sum = 0.0;

			for (uint i = 0u; i < p.count; i++) {
				sum += tess_sample(height_texture, tess_vertex_uv(data, corners.w[p.first + i]), 0.0);
			}

			point.height = sum / float(max(p.count, 1u));
		} else if (edge_id >= 0) {
			int ia = edge_id == 2 ? 1 : 0;
			int ib = edge_id == 0 ? 1 : 2;
			int rate = edge_id == 0 ? rab : (edge_id == 1 ? rac : rbc);
			point = tess_edge(data, pids, height_texture, height_size, vi[ia], vi[ib], twin[edge_id * 2], twin[edge_id * 2 + 1], pid[ia], pid[ib], rate, edge_t);
		} else {
			TessPid p0 = pids.p[pid[0]];
			TessPid p1 = pids.p[pid[1]];
			TessPid p2 = pids.p[pid[2]];
			vec3 x0 = tess_vertex_position(data, vi[0]);
			vec3 x1 = tess_vertex_position(data, vi[1]);
			vec3 x2 = tess_vertex_position(data, vi[2]);
			point.base = wa * x0 + wb * x1 + wc * x2;
			point.spacing = (length(x1 - x0) + length(x2 - x0) + length(x2 - x1)) / (3.0 * float(n));
			point.displace = wa * tess_displace(data, vi[0]) + wb * tess_displace(data, vi[1]) + wc * tess_displace(data, vi[2]);
			point.dir = normalize(wa * p0.dir + wb * p1.dir + wc * p2.dir);
			point.scale = wa * p0.scale + wb * p1.scale + wc * p2.scale;
			vec2 uv0 = tess_vertex_uv(data, vi[0]);
			vec2 uv1 = tess_vertex_uv(data, vi[1]);
			vec2 uv2 = tess_vertex_uv(data, vi[2]);
			float uv_span = (length((uv1 - uv0) * height_size) + length((uv2 - uv0) * height_size) + length((uv2 - uv1) * height_size)) / 3.0;
			point.height = tess_sample(height_texture, uv, log2(max(uv_span / float(n), 1.0)));
			float best = 2.0;
			int best_edge = -1;
			float best_t = 0.0;

			if ((twin[0] != vi[0] || twin[1] != vi[1]) && wc < best) { best = wc; best_edge = 0; best_t = wb / max(wa + wb, 1e-6); }
			if ((twin[2] != vi[0] || twin[3] != vi[2]) && wb < best) { best = wb; best_edge = 1; best_t = wc / max(wa + wc, 1e-6); }
			if ((twin[4] != vi[1] || twin[5] != vi[2]) && wa < best) { best = wa; best_edge = 2; best_t = wc / max(wb + wc, 1e-6); }

			if (best_edge >= 0 && best < seam_band) {
				int ia = best_edge == 2 ? 1 : 0;
				int ib = best_edge == 0 ? 1 : 2;
				int rate = best_edge == 0 ? rab : (best_edge == 1 ? rac : rbc);
				TessPoint foot = tess_edge(data, pids, height_texture, height_size, vi[ia], vi[ib], twin[best_edge * 2], twin[best_edge * 2 + 1], pid[ia], pid[ib], rate, best_t);
				point.height = mix(point.height, foot.height, 1.0 - smoothstep(0.0, seam_band, best));
			}
		}

		// shadow maps and rays see the base mesh, so the relief rises out of it instead of sinking below it where the base would cover it
		vec3 local_position = point.base + point.dir * (point.height * height_scale * point.scale * point.displace);
		vec4 world_position = world * vec4(local_position, 1.0);

		if ((job.flags & 2u) != 0u) {
			vec2 terrain_uv = (world_position.xz - terrain_model.TerrainBounds.xy) / terrain_model.TerrainBounds.z;
			vec3 coarse = get_terrain_world_normal(clamp(terrain_uv, 0.0, 1.0));
			TerrainShellWeights weights = terrain_shell_weights(terrain_uv, coarse, world_position.y);
			float g = point.spacing / max(terrain_model.TerrainLayerScales.y, 0.0001);
			vec2 gx[3] = vec2[3](vec2(g, 0.0), vec2(g, 0.0), vec2(g, 0.0));
			vec2 gy[3] = vec2[3](vec2(0.0, g), vec2(0.0, g), vec2(0.0, g));
			vec3 offset = coarse * (terrain_shell_relief(world_position.xyz, weights, gx, gy) * point.displace);
			world_position.xyz += offset;
		}

		TessSample result;
		result.local_position = local_position;
		result.world_position = world_position.xyz;

		if ((job.flags & 2u) != 0u) result.local_position = (inverse(world) * world_position).xyz;

		result.normal = normal;
		result.tangent = tangent;
		result.uv = uv;
		result.texture_blend = texture_blend;
		result.vertex_color = vertex_color;
		return result;
	}

	layout(buffer_reference, scalar) buffer TessSampleCache { uint w[]; };

	vec2 tess_cache_oct_encode(vec3 n) {
		n /= abs(n.x) + abs(n.y) + abs(n.z);
		return n.z < 0.0 ? (1.0 - abs(n.yx)) * vec2(n.x >= 0.0 ? 1.0 : -1.0, n.y >= 0.0 ? 1.0 : -1.0) : n.xy;
	}

	vec3 tess_cache_oct_decode(vec2 p) {
		vec3 n = vec3(p, 1.0 - abs(p.x) - abs(p.y));

		if (n.z < 0.0) n.xy = (1.0 - abs(n.yx)) * vec2(n.x >= 0.0 ? 1.0 : -1.0, n.y >= 0.0 ? 1.0 : -1.0);

		return normalize(n);
	}

	void tess_cache_store(uint64_t address, TessSample s) {
		TessSampleCache c = TessSampleCache(address);
		c.w[0] = floatBitsToUint(s.local_position.x);
		c.w[1] = floatBitsToUint(s.local_position.y);
		c.w[2] = floatBitsToUint(s.local_position.z);
		c.w[3] = floatBitsToUint(s.world_position.x);
		c.w[4] = floatBitsToUint(s.world_position.y);
		c.w[5] = floatBitsToUint(s.world_position.z);
		c.w[6] = packSnorm2x16(tess_cache_oct_encode(s.normal));
		c.w[7] = packSnorm2x16(tess_cache_oct_encode(s.tangent.xyz));
		c.w[8] = floatBitsToUint(s.tangent.w);
		c.w[9] = floatBitsToUint(s.uv.x);
		c.w[10] = floatBitsToUint(s.uv.y);
		c.w[11] = floatBitsToUint(s.texture_blend);
		c.w[12] = packUnorm4x8(s.vertex_color);
	}

	TessSample tess_cache_load(uint64_t address) {
		TessSampleCache c = TessSampleCache(address);
		TessSample s;
		s.local_position = uintBitsToFloat(uvec3(c.w[0], c.w[1], c.w[2]));
		s.world_position = uintBitsToFloat(uvec3(c.w[3], c.w[4], c.w[5]));
		s.normal = tess_cache_oct_decode(unpackSnorm2x16(c.w[6]));
		s.tangent = vec4(tess_cache_oct_decode(unpackSnorm2x16(c.w[7])), uintBitsToFloat(c.w[8]));
		s.uv = uintBitsToFloat(uvec2(c.w[9], c.w[10]));
		s.texture_blend = uintBitsToFloat(c.w[11]);
		s.vertex_color = unpackUnorm4x8(c.w[12]);
		return s;
	}

]=]
local VERTEX_MAIN = [=[
	void main() {
		uvec4 patch_record = TessPatchData(tess_draw.patches).p[gl_InstanceIndex];
		TessJob job = TessJobData(tess_draw.jobs).j[patch_record.x];
		uint tri = patch_record.y;
		uint rates = patch_record.z;
		uint batch_index = job.batch;
		tess_batch = batch_index;
		out_batch = batch_index;
		out_instance = job.instance;
		out_triangle = tri;
		out_patch = uint(gl_InstanceIndex);
		out_primitive = uint(gl_VertexIndex) / 3u;
		PBRBatchData batch_data = PBRBatchData(gbuffer_draw.batches);
		TessVertexData data = TessVertexData(job.vertices);
		TessVertexData extras = TessVertexData(packUint2x32(batch_data.b[batch_index].extras_address));
		int height_texture = batch_data.b[batch_index].m_displacement_model.HeightTexture;
		tess_fade_texture = (job.flags & 1u) != 0u ? batch_data.b[batch_index].m_model.AlbedoTexture : -1;
		mat4 world = TessWorldData(tess_draw.worlds).w[patch_record.x * 2u];
		mat4 prev_world = TessWorldData(tess_draw.worlds).w[patch_record.x * 2u + 1u];
		int small = gl_VertexIndex / 3;
		int corner_index = gl_VertexIndex % 3;
		int r = int(sqrt(float(small)));

		while (r * r > small) r--;
		while ((r + 1) * (r + 1) <= small) r++;

		int c = small - r * r;
		int k = c / 2;
		ivec2 q;

		if ((c & 1) == 0) {
			q = corner_index == 0 ? ivec2(r, k) : (corner_index == 1 ? ivec2(r + 1, k) : ivec2(r + 1, k + 1));
		} else {
			q = corner_index == 0 ? ivec2(r, k) : (corner_index == 1 ? ivec2(r + 1, k + 1) : ivec2(r, k + 1));
		}

		#ifdef TESS_SAMPLE_CACHED
		TessSample sample_point = tess_cache_load(TESS_SAMPLE_CACHED + uint64_t((q.x * (q.x + 1) / 2 + q.y) * ]=] .. software_raster.PATCH_SAMPLE_WORDS * 4 .. [=[));
		#else
		TessSample sample_point = tess_evaluate(job, tri, rates, q, world, data, extras, height_texture, tess_draw.seam_band);
		#endif
		vec3 local_position = sample_point.local_position;
		vec4 world_position = vec4(sample_point.world_position, 1.0);
		vec4 prev_world_position = prev_world * vec4(local_position, 1.0);
		vec3 normal = sample_point.normal;
		vec4 tangent = sample_point.tangent;
		vec2 uv = sample_point.uv;
		float texture_blend = sample_point.texture_blend;
		vec4 vertex_color = sample_point.vertex_color;

		// decals lie on the surface they are projected on and this variant does not write fragment depth, so they are pulled toward the eye like the parallax path's decal depth bias
		if ((job.flags & 1u) != 0u) {
			vec3 to_camera = gbuffer_data.camera_position.xyz - world_position.xyz;
			float camera_distance = max(length(to_camera), 0.0001);
			vec3 bias = to_camera / camera_distance * (camera_distance * 0.002 + 0.002);
			world_position.xyz += bias;
			prev_world_position.xyz += bias;
		}
		mat3 normal_matrix = transpose(inverse(mat3(world)));
		vec3 world_normal = normalize(normal_matrix * normal);
		out_position = world_position.xyz;
		out_normal = world_normal;
		out_tangent = vec4(normalize(mat3(world) * tangent.xyz), tangent.w < 0.0 ? -1.0 : 1.0);
		out_uv = uv;
		out_texture_blend = texture_blend;
		out_vertex_color = vertex_color;
		out_prev_position = prev_world_position.xyz;
		out_lod_fade = world[0][3];
		out_instance_overlay = world[1][3];
		out_instance_dynamic = world[2][3];
		bool local_effect = world[1][3] > 0.0;
		out_effect_position = local_effect ? local_position : world_position.xyz;
		out_effect_normal = local_effect ? normalize(normal) : world_normal;
		gl_Position = gbuffer_data.projection * gbuffer_data.view * vec4(world_position.xyz, 1.0);
	}
]=]

function tessellation.CreateVertexStage(uniform_buffers, bits)
	local outputs = model_pipeline.GetVertexStageOutputs{
		normal = true,
		tangent = true,
		uv = true,
		texture_blend = true,
		vertex_color = true,
		velocity = true,
		lod_fade = true,
		instance_overlay = true,
		instance_dynamic = true,
		effect_space = true,
	}
	local batch_location = #outputs
	local buffers = table.copy(uniform_buffers)
	buffers[#buffers + 1] = tess_block
	return {
		outputs = outputs,
		batch_location = batch_location,
		uniform_buffers = buffers,
		custom_declarations = model_pipeline.BuildPBRBatchRecordGlsl() .. TESS_GLSL .. shader_features.GetDefines(bits) .. [[
uint tess_batch;
#define model (PBRBatchData(gbuffer_draw.batches).b[tess_batch].m_model)
#define terrain_model (PBRBatchData(gbuffer_draw.batches).b[tess_batch].m_terrain_model)
]] .. model_pipeline.TERRAIN_RELIEF_GLSL .. string.format(
				"layout(location = %d) flat out uint out_batch;\nlayout(location = %d) flat out uint out_instance;\nlayout(location = %d) flat out uint out_triangle;\nlayout(location = %d) flat out uint out_patch;\nlayout(location = %d) flat out uint out_primitive;\n",
				batch_location,
				batch_location + 1,
				batch_location + 2,
				batch_location + 3,
				batch_location + 4
			),
		shader = TESS_EVAL_GLSL .. VERTEX_MAIN,
	}
end

local function create_buffer(byte_size, usage, label)
	return render.CreateBuffer{
		byte_size = byte_size,
		buffer_usage = usage,
		memory_property = {"device_local"},
		label = label,
	}
end

local function ensure_capacity(job_count, triangle_count)
	if
		job_count <= state.job_capacity and
		triangle_count <= state.triangle_capacity and
		state.state_buffer
	then
		return
	end

	render.GetDevice():WaitIdle()

	for _, key in ipairs{"state_buffer", "jobs_buffer", "worlds_buffer", "patches_buffer"} do
		if state[key] then state[key]:Remove() end
	end

	state.job_capacity = math.max(64, 2 ^ math.ceil(math.log(math.max(job_count, 1)) / math.log(2)))
	state.triangle_capacity = math.max(1024, 2 ^ math.ceil(math.log(math.max(triangle_count, 1)) / math.log(2)))
	state.state_buffer = create_buffer(
		STATE_BYTES,
		{"storage_buffer", "indirect_buffer", "shader_device_address", "transfer_dst"},
		"tessellation_state"
	)
	state.jobs_buffer = create_buffer(
		state.job_capacity * JOB_BYTES,
		{"storage_buffer", "shader_device_address", "transfer_dst"},
		"tessellation_jobs"
	)
	state.worlds_buffer = create_buffer(
		state.job_capacity * 2 * 64,
		{"storage_buffer", "shader_device_address"},
		"tessellation_worlds"
	)
	state.patches_buffer = create_buffer(
		(GROUPS * BUCKETS + 1) * state.triangle_capacity * 16,
		{"storage_buffer", "shader_device_address"},
		"tessellation_patches"
	)
	state.state_address = state.state_buffer:GetDeviceAddress()
	state.jobs_address = state.jobs_buffer:GetDeviceAddress()
	state.worlds_address = state.worlds_buffer:GetDeviceAddress()
	state.patches_address = state.patches_buffer:GetDeviceAddress()
	state.jobs_cpu = ffi.new("uint8_t[?]", state.job_capacity * JOB_BYTES)
	state.state_cpu = ffi.new("uint8_t[?]", STATE_BYTES)
end

local JobType = ffi.typeof([[struct {
	uint32_t instance;
	uint32_t batch;
	uint32_t first_triangle;
	uint32_t triangle_count;
	uint64_t topology;
	uint64_t pids;
	uint64_t corners;
	uint64_t vertices;
	uint64_t indices;
	uint32_t index_is_32;
	float height_scale;
	uint32_t flags;
	float uv_size;
	float texel;
	uint32_t pad;
}]])
assert(ffi.sizeof(JobType) == JOB_BYTES)
local JobPointer = ffi.typeof("$ *", JobType)
local terrain_relief_detail

do
	local layers = {}

	for i = 1, 8 do
		local suffix = i > 4 and "2" or ""
		layers[i] = {
			texture = "TerrainLayer" .. i .. "HeightTexture",
			scales = "TerrainLayerScales" .. suffix,
			height_scales = "TerrainLayerHeightScales" .. suffix,
			component = ({"r", "g", "b", "a"})[(i - 1) % 4 + 1],
		}
	end

	function terrain_relief_detail(material)
		local best_relief, uv_size, texel = 0, 1, 1

		for _, layer in ipairs(layers) do
			local texture = material[layer.texture]

			if texture then
				local scale = material[layer.scales][layer.component]
				local relief = material[layer.height_scales][layer.component] * scale

				if relief > best_relief then
					best_relief, uv_size, texel = relief, scale, 1 / texture:GetWidth()
				end
			end
		end

		return uv_size, texel
	end
end

local function build_jobs()
	if state.built_serial ~= row_serial then
		state.built_serial = row_serial
		local job_rows = {}
		local batches = {}
		local triangles = 0

		for id, row in pairs(rows) do
			local topology = tessellation.GetTopology(row.polygon3d)

			if topology.triangle_count > 0 then
				job_rows[#job_rows + 1] = {id = id, row = row, topology = topology}
			end
		end

		table.sort(job_rows, function(a, b)
			return a.id < b.id
		end)

		for i, job in ipairs(job_rows) do
			batches[i] = {
				mesh = job.row.mesh,
				material = job.row.material,
				first_polygon3d = job.row.polygon3d,
			}
			triangles = triangles + job.topology.triangle_count
		end

		ensure_capacity(#job_rows, triangles)
		state.job_rows = job_rows
		state.batches = batches
		state.batch_serial = state.batch_serial + 1
		state.job_count = #job_rows
		state.triangle_count = triangles
		state.stats.jobs = #job_rows
		state.stats.triangles = triangles
	end

	local jobs = ffi.cast(JobPointer, state.jobs_cpu)
	local first = 0

	for i, job in ipairs(state.job_rows) do
		local out = jobs[i - 1]
		local mesh = job.row.mesh
		local material = job.row.material
		out.instance = job.id
		out.batch = i - 1
		out.first_triangle = first
		out.triangle_count = job.topology.triangle_count
		out.topology = job.topology.topology_address
		out.pids = job.topology.pids_address
		out.corners = job.topology.corners_address
		out.vertices = mesh:GetVertexBufferAddress()
		out.indices = mesh:GetIndexBufferAddress()
		out.index_is_32 = mesh.index_buffer:GetIndexType() == "uint32" and 1 or 0

		if material.terrain_tile then
			out.height_scale = material:GetTerrainShell()
			out.flags = 2
			out.uv_size, out.texel = terrain_relief_detail(material)
		else
			out.height_scale = material:GetHeightScale()
			out.flags = material.Decal and 1 or 0
			out.uv_size = 1
			out.texel = 1 / material:GetHeightTexture():GetWidth()
		end

		first = first + job.topology.triangle_count
	end
end

local function upload(cmd, buffer, source, bytes, destination)
	local data = ffi.cast("uint8_t *", source)
	destination = destination or 0

	for offset = 0, bytes - 1, UPDATE_BUFFER_LIMIT do
		cmd:UpdateBuffer(
			buffer,
			destination + offset,
			math.min(UPDATE_BUFFER_LIMIT, bytes - offset),
			data + offset
		)
	end
end

local function get_pipeline()
	if not render3d.HasPipelineVariants(tessellation.name) then return end

	if visibility.enabled then
		local bits = bit.bor(draw.GetGlobalBits(0), shader_features.PARAMS)
		local ids = render3d.GetPipelineVariant(tessellation.name, draw.GetVariant(draw.SHAPE_IDS, bits))

		if
			render3d.IsPipelineReady(ids) and
			visibility.IsResolveReady(visibility.KIND_TESSELLATION, bits)
		then
			return ids
		end
	end

	local plain = draw.GetVariant(draw.SHAPE_PLAIN, bit.bor(draw.GetGlobalBits(0), shader_features.PARAMS))
	local pipeline = render3d.GetPipelineVariant(tessellation.name, plain)

	if render3d.IsPipelineReady(pipeline) then return pipeline end

	pipeline = render3d.GetPipelineVariant(tessellation.name, draw.GetVariant(draw.SHAPE_PLAIN, shader_features.PARAMS))

	if render3d.IsPipelineReady(pipeline) then return pipeline end
end

local function get_terrain_pipeline(pipeline)
	local bits = bit.bor(draw.GetGlobalBits(0), shader_features.TERRAIN, shader_features.PARAMS)

	if pipeline.config.visibility then
		local ids = render3d.GetPipelineVariant(tessellation.name, draw.GetVariant(draw.SHAPE_IDS, bits))

		if
			render3d.IsPipelineReady(ids) and
			visibility.IsResolveReady(visibility.KIND_TESSELLATION, bits)
		then
			return ids
		end
	end

	return render3d.GetPipelineVariant(tessellation.name, draw.GetVariant(draw.SHAPE_PLAIN, bits))
end

local batch_table

local function update_batches(pipeline)
	batch_table = batch_table or gbuffer_instancing.NewBatchTable("tessellation_batches")
	state.batches_address = batch_table:Update(pipeline, state.batches, state.batch_serial, system.GetFrameNumber())
	return state.batches_address
end

function tessellation.PreDraw(cmd)
	state.ready = false

	if not enabled:Get() or next(rows) == nil then return end

	local pipeline = get_pipeline()

	if not pipeline then return end

	build_jobs()

	if state.job_count == 0 then return end

	local camera = render3d.GetCamera()
	state.view_projection = camera:BuildViewMatrix() * camera:BuildUnjitteredProjectionMatrix()
	state.camera_position = camera:GetPosition()
	state.resolution = render3d.GetRenderSize()
	state.focal = 0.5 * state.resolution.y * math.abs(camera:BuildUnjitteredProjectionMatrix().m11)
	local commands = ffi.cast("uint32_t *", state.state_cpu)

	for slot = 0, GROUPS * BUCKETS - 1 do
		local n = 2 ^ (slot % BUCKETS)
		commands[slot * 4] = n * n * 3
		commands[slot * 4 + 1] = 0
		commands[slot * 4 + 2] = 0
		commands[slot * 4 + 3] = slot * state.triangle_capacity
	end

	local args = ffi.cast("uint64_t *", state.state_cpu + STATE_ARGS_OFFSET)
	local tlas_table, data_table = instances.GetTables()
	args[0] = state.jobs_address
	args[1] = state.worlds_address
	args[2] = state.state_address
	args[3] = state.patches_address
	args[4] = tlas_table:GetAddress()
	args[5] = data_table:GetAddress()
	args[6] = instances.GetRasterTable():GetAddress()
	args[7], state.software_pixels, state.software_cache, state.software_cache_pixels = software_raster.ResetPatches(cmd)

	if
		not (
			pipeline.config.visibility and
			get_terrain_pipeline(pipeline).config.visibility
		)
	then
		args[7] = 0
	end

	state.software_patches_address = args[7]
	update_batches(pipeline)
	cmd:PipelineBarrier{
		srcStage = {"draw_indirect", "vertex_shader", "compute"},
		dstStage = "transfer",
		memoryBarrier = true,
	}
	upload(cmd, state.state_buffer, state.state_cpu, STATE_BYTES)
	upload(cmd, state.jobs_buffer, state.jobs_cpu, state.job_count * JOB_BYTES)
	cmd:PipelineBarrier{srcStage = {"host", "transfer"}, dstStage = "compute", memoryBarrier = true}
	local passes = get_compute_pipelines()
	passes.worlds:Dispatch(cmd, math.ceil(state.job_count / 64), 1, 1, 1)
	cmd:PipelineBarrier{srcStage = "compute", dstStage = "compute", memoryBarrier = true}
	passes.cull:Dispatch(cmd, math.ceil(state.triangle_count / 64), 1, 1, 1)
	cmd:PipelineBarrier{
		srcStage = "compute",
		dstStage = {"draw_indirect", "vertex_shader"},
		memoryBarrier = true,
	}
	state.ready = true
end

do
	local SOFTWARE_LOCAL_SIZE = 256
	local SOFTWARE_MAX_LOG = tessellation.MAX_LOG
	local SOFTWARE_VERTICES = (2 ^ SOFTWARE_MAX_LOG + 1) * (2 ^ SOFTWARE_MAX_LOG + 2) / 2
	local software_pipeline

	local function get_software_pipeline()
		if software_pipeline then return software_pipeline end

		software_pipeline = EasyPipeline.Compute{
			name = "software_raster_patches",
			LocalSize = {x = SOFTWARE_LOCAL_SIZE, y = 1, z = 1},
			uniform_buffers = {software_raster.GetCameraBlock()},
			block = {
				{"patches", "uint64_t"},
				{"list", "uint64_t"},
				{"jobs", "uint64_t"},
				{"worlds", "uint64_t"},
				{"batches", "uint64_t"},
				{"depth", "uint64_t"},
				{"base", "int"},
				{"limit", "int"},
				{"seam_band", "float"},
			},
			write = function(self, block)
				block.patches = state.patches_address
				block.list = software_raster.GetPatches():GetDeviceAddress()
				block.jobs = state.jobs_address
				block.worlds = state.worlds_address
				block.batches = state.batches_address
				block.depth = software_raster.GetDepthAddress()
				block.base = GROUPS * BUCKETS * state.triangle_capacity
				block.limit = math.min(state.triangle_capacity, software_raster.CAPACITY)
				block.seam_band = seam_band:Get()
			end,
			shader = model_pipeline.BuildPBRBatchRecordGlsl() .. TESS_GLSL .. shader_features.GetDefines(shader_features.ALL) .. [[
				struct SoftwareTessDraw {
					uint64_t batches;
				};
				SoftwareTessDraw gbuffer_draw;
				uint tess_batch;
				#define model (PBRBatchData(gbuffer_draw.batches).b[tess_batch].m_model)
				#define terrain_model (PBRBatchData(gbuffer_draw.batches).b[tess_batch].m_terrain_model)
			]] .. model_pipeline.TERRAIN_RELIEF_GLSL .. software_raster.RECORD_GLSL .. software_raster.RASTER_GLSL .. TESS_EVAL_GLSL .. [[
				shared ivec2 software_q[]] .. SOFTWARE_VERTICES .. [[];
				shared float software_z[]] .. SOFTWARE_VERTICES .. [[];

				int software_lattice(ivec2 q) {
					return q.x * (q.x + 1) / 2 + q.y;
				}

				void main() {
					SoftwarePatches list = SoftwarePatches(compute.list);
					uint record = gl_WorkGroupID.x;

					if (record >= min(list.count, uint(compute.limit))) return;

					uvec4 patch_record = TessPatchData(compute.patches).p[uint(compute.base) + record];
					TessJob job = TessJobData(compute.jobs).j[patch_record.x];
					uint tri = patch_record.y;
					uint rates = patch_record.z;
					uint cache = list.r[record].z;
					int n = 1 << int((rates >> 12u) & 15u);
					gbuffer_draw.batches = compute.batches;
					tess_batch = job.batch;
					tess_fade_texture = -1;
					PBRBatchData batch_data = PBRBatchData(compute.batches);
					TessVertexData data = TessVertexData(job.vertices);
					TessVertexData extras = TessVertexData(packUint2x32(batch_data.b[job.batch].extras_address));
					int height_texture = batch_data.b[job.batch].m_displacement_model.HeightTexture;
					mat4 world = TessWorldData(compute.worlds).w[patch_record.x * 2u];
					ivec2 size = ivec2(gbuffer_data.render_size.xy);
					int vertex_count = (n + 1) * (n + 2) / 2;

					for (int v = int(gl_LocalInvocationID.x); v < vertex_count; v += ]] .. SOFTWARE_LOCAL_SIZE .. [[) {
						int row = int((sqrt(8.0 * float(v) + 1.0) - 1.0) * 0.5);

						while (row * (row + 1) / 2 > v) row--;
						while ((row + 1) * (row + 2) / 2 <= v) row++;

						TessSample sample_point = tess_evaluate(job, tri, rates, ivec2(row, v - row * (row + 1) / 2), world, data, extras, height_texture, compute.seam_band);

						if (cache != 0xFFFFFFFFu) tess_cache_store(compute.list + ]] .. software_raster.PATCH_CACHE_OFFSET .. [[ul + uint64_t((cache + uint(v)) * ]] .. software_raster.PATCH_SAMPLE_WORDS * 4 .. [[u), sample_point);
						vec4 clip = gbuffer_data.projection * gbuffer_data.view * vec4(sample_point.world_position, 1.0);
						software_q[v] = ivec2(round((clip.xy / clip.w * 0.5 + 0.5) * vec2(size) * 256.0));
						software_z[v] = clip.z / clip.w;
					}

					barrier();
					SoftwareDepth depth = SoftwareDepth(compute.depth);

					for (int small = int(gl_LocalInvocationID.x); small < n * n; small += ]] .. SOFTWARE_LOCAL_SIZE .. [[) {
						int r = int(sqrt(float(small)));

						while (r * r > small) r--;
						while ((r + 1) * (r + 1) <= small) r++;

						int c = small - r * r;
						int k = c / 2;
						ivec2 a = ivec2(r, k);
						ivec2 b = (c & 1) == 0 ? ivec2(r + 1, k) : ivec2(r + 1, k + 1);
						ivec2 d = (c & 1) == 0 ? ivec2(r + 1, k + 1) : ivec2(r, k + 1);
						int ia = software_lattice(a);
						int ib = software_lattice(b);
						int id = software_lattice(d);
						ivec2 q[3] = ivec2[3](software_q[ia], software_q[ib], software_q[id]);
						float z[3] = float[3](software_z[ia], software_z[ib], software_z[id]);
						software_raster_triangle(q, z, true, uint64_t(0x80000000u | (record << 12u) | uint(small)), depth, size);
					}
				}
			]],
		}
		return software_pipeline
	end

	software_raster.AddRasterizer(function(cmd)
		if not state.ready then return end

		get_software_pipeline():DispatchIndirect(cmd, software_raster.GetPatches(), 0)
	end)
end

function tessellation.Draw(pipeline, cmd)
	if not state.ready or not render3d.IsPipelineReady(pipeline) then return end

	local batches_address = update_batches(pipeline)
	local terrain = get_terrain_pipeline(pipeline)

	for group, group_pipeline in ipairs({pipeline, terrain}) do
		if render3d.IsPipelineReady(group_pipeline) then
			group_pipeline.draw_batches_address = batches_address
			group_pipeline.draw_instances_address = 0
			group_pipeline.draw_prev_instances_address = 0
			group_pipeline.draw_groups_address = 0

			if group_pipeline.config.visibility then
				visibility.AddContext(
					group_pipeline,
					state.state_buffer:GetDeviceAddress() + (group - 1) * BUCKETS * 16,
					visibility.TESSELLATION_SET + group - 1,
					visibility.KIND_TESSELLATION,
					state.jobs_address,
					state.worlds_address,
					state.patches_address,
					seam_band:Get(),
					state.software_patches_address,
					GROUPS * BUCKETS * state.triangle_capacity
				)
			end

			group_pipeline:UploadConstants()
			cmd:SetCullMode(orientation.CULL_MODE)
			cmd:DrawIndirect(state.state_buffer, (group - 1) * BUCKETS * 16, BUCKETS, 16)
		end
	end
end

local cluster_lod_reference_pixels = string.format("%.6f", 1080 / (2 * math.tan(math.rad(60) / 2)))
local RT_MAX_LOG = 3
local RT_PATCHES = 32768
local RT_PATCH_VERTICES = (2 ^ RT_MAX_LOG + 1) * (2 ^ RT_MAX_LOG + 2) / 2
local RT_PATCH_TRIANGLES = 4 ^ RT_MAX_LOG
local RT_VERTICES = RT_PATCHES * RT_PATCH_VERTICES
local RT_TRIANGLES = RT_PATCHES * RT_PATCH_TRIANGLES
local RT_NONE = 0xFFFFFFFF
local RT_ARG_COUNT = 16
local RT_COUNTER_BYTES = 64
pvars.StartGroup("Rendering", "Tessellation", {store = false})
local rt_enabled = pvars.Setup2{
	key = "r_tessellation_rt",
	default = true,
	help = "trace tessellated surfaces near the camera through cluster acceleration structures built every frame, so shadows and reflections see the relief",
}
local rt_distance = pvars.Setup2{
	key = "r_tessellation_rt_distance",
	default = 40,
	help = "how far from the camera (in meters, from the edge of a model) tessellated models are traced with their relief, farther ones are traced as their base mesh",
}
pvars.EndGroup()
local rt = {
	built = false,
	job_capacity = 0,
	ref_capacity = 0,
	instance_capacity = 0,
	ready = false,
}
local rt_block = {
	{"camera_position", "vec3"},
	{"error", "float"},
	{"job_count", "int"},
	{"triangle_count", "int"},
	{"seam_band", "float"},
	{"pad", "int"},
	{"args", "uint64_t"},
}

local function write_rt_block(self, block)
	local position = rt.camera_position
	block.camera_position[0], block.camera_position[1], block.camera_position[2] = position.x, position.y, position.z
	block.error = pvars.Get("r_cluster_lod_rt_error")
	block.job_count = state.job_count
	block.triangle_count = state.triangle_count
	block.seam_band = seam_band:Get()
	block.args = rt.args_address
	return block
end

local RT_GLSL = [[
	#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require
	#define TERRAIN_LAYERS 1
	const int RT_MAX_LOG = ]] .. RT_MAX_LOG .. [[;
	const uint RT_PATCHES = ]] .. RT_PATCHES .. [[u;
	layout(buffer_reference, scalar) readonly buffer RTArgs { uint64_t a[]; };
	layout(buffer_reference, scalar) buffer RTInfos { uvec4 i[]; };
	layout(buffer_reference, scalar) buffer RTRefs { uint64_t a[]; };
	layout(buffer_reference, scalar) buffer RTVertexData { float v[]; };
	]] .. TESS_GLSL .. vertex_layout.BuildGlslAccessors("rt_vertex", "RTVertexData", true) .. model_pipeline.BuildPBRBatchRecordGlsl() .. [[
	uint tess_batch;
	#define model (PBRBatchData(RTArgs(compute.args).a[13]).b[tess_batch].m_model)
	#define terrain_model (PBRBatchData(RTArgs(compute.args).a[13]).b[tess_batch].m_terrain_model)
	]] .. model_pipeline.TERRAIN_RELIEF_GLSL .. TESS_EVAL_GLSL
local rt_pipelines

local function get_rt_pipelines()
	if rt_pipelines then return rt_pipelines end

	rt_pipelines = {
		select = EasyPipeline.Compute{
			name = "tessellation_rt_select",
			LocalSize = {x = 64, y = 1, z = 1},
			block = rt_block,
			write = write_rt_block,
			shader = RT_GLSL .. [=[
				void main() {
					uint g = gl_GlobalInvocationID.x;

					if (g >= uint(compute.triangle_count)) return;

					RTArgs args = RTArgs(compute.args);
					TessJobData jobs = TessJobData(args.a[0]);
					uint lo = 0u;
					uint hi = uint(compute.job_count) - 1u;

					while (lo < hi) {
						uint mid = (lo + hi + 1u) >> 1;

						if (jobs.j[mid].first_triangle <= g) lo = mid; else hi = mid - 1u;
					}

					TessJob job = jobs.j[lo];
					uint tri = g - job.first_triangle;

					if (tri >= job.triangle_count) return;

					uint rt_job = TessWords(args.a[2]).w[lo];

					if (rt_job == 0xFFFFFFFFu) return;

					mat4 world = TessWorldData(args.a[1]).w[lo * 2u];
					TessVertexData data = TessVertexData(job.vertices);
					TessWords topology = TessWords(job.topology);
					TessPidData pids = TessPidData(job.pids);
					bool terrain = (job.flags & 2u) != 0u;
					vec3 position[3];
					float scale[3];
					uint pid[3];
					int off_grid = 0;

					for (uint k = 0u; k < 3u; k++) {
						uint vertex = tess_index(job.indices, job.index_is_32, tri * 3u + k);
						position[k] = (world * vec4(tess_vertex_position(data, vertex), 1.0)).xyz;
						pid[k] = topology.w[tri * 9u + k];
						scale[k] = terrain ? 1.0 : pids.p[pid[k]].scale;
						off_grid += abs(tess_vertex_tangent(data, vertex).w) > 1.5 ? 1 : 0;
					}

					if (off_grid == 3) return;

					uint rate[3];

					for (int e = 0; e < 3; e++) {
						int ia = e == 2 ? 1 : 0;
						int ib = e == 0 ? 1 : 2;

						if (pid[ia] > pid[ib]) {
							int swap = ia;
							ia = ib;
							ib = swap;
						}

						float edge_length = distance(position[ia], position[ib]);
						float pixels = edge_length * ]=] .. cluster_lod_reference_pixels .. [=[ / max(distance(compute.camera_position, 0.5 * (position[ia] + position[ib])), 0.05);
						float relief_pixels = job.height_scale * max(scale[ia], scale[ib]) * ]=] .. cluster_lod_reference_pixels .. [=[ / max(min(distance(compute.camera_position, position[ia]), distance(compute.camera_position, position[ib])), 0.05);
						rate[e] = tess_edge_rate(edge_length, pixels, relief_pixels, job.uv_size * min(scale[ia], scale[ib]), job.texel, compute.error, RT_MAX_LOG);
					}

					uint inner = max(max(rate[0], rate[1]), rate[2]);
					uint n = 1u << inner;
					TessWords counters = TessWords(args.a[3]);
					uint patch_index = atomicAdd(counters.w[0], 1u);

					if (patch_index >= RT_PATCHES) return;

					atomicAdd(counters.w[4], 1u);
					uint vertex_base = atomicAdd(counters.w[1], (n + 1u) * (n + 2u) / 2u);
					uint triangle_base = atomicAdd(counters.w[2], n * n);
					uint slot = atomicAdd(RTInfos(args.a[6]).i[rt_job].x, 1u);
					uint rates = rate[0] | (rate[1] << 4) | (rate[2] << 8) | (inner << 12);
					TessPatchData patches = TessPatchData(args.a[4]);
					patches.p[patch_index * 2u] = uvec4(lo, tri, rates, vertex_base);
					patches.p[patch_index * 2u + 1u] = uvec4(triangle_base, rt_job, slot, n);
					TessWords cluster = TessWords(args.a[5] + uint64_t(patch_index) * 64ul);
					uint64_t index_buffer = args.a[7] + uint64_t(TessWords(args.a[7]).w[inner]);
					uint64_t vertex_buffer = args.a[8] + uint64_t(vertex_base) * ]=] .. vertex_layout.CoreStride .. [=[ul;
					cluster.w[0] = triangle_base | 0x80000000u;
					cluster.w[1] = 0u;
					cluster.w[2] = (n * n) | (((n + 1u) * (n + 2u) / 2u) << 9) | (1u << 24);
					cluster.w[3] = 0u;
					cluster.w[4] = 1u | (]=] .. vertex_layout.CoreStride .. [=[u << 16);
					cluster.w[5] = 0u;
					cluster.w[6] = uint(index_buffer & 0xFFFFFFFFul);
					cluster.w[7] = uint(index_buffer >> 32);
					cluster.w[8] = uint(vertex_buffer & 0xFFFFFFFFul);
					cluster.w[9] = uint(vertex_buffer >> 32);

					for (uint w = 10u; w < 16u; w++) cluster.w[w] = 0u;
				}
			]=],
		},
		vertices = EasyPipeline.Compute{
			name = "tessellation_rt_vertices",
			LocalSize = {x = 64, y = 1, z = 1},
			block = rt_block,
			write = write_rt_block,
			shader = RT_GLSL .. [=[
				uint rt_template_index(TessWords templates, uint offset, uint at) {
					uint byte_at = offset + at;
					return (templates.w[byte_at >> 2] >> ((byte_at & 3u) * 8u)) & 0xFFu;
				}

				void main() {
					uint patch_index = gl_WorkGroupID.x;
					RTArgs args = RTArgs(compute.args);
					TessPatchData patches = TessPatchData(args.a[4]);
					uvec4 a = patches.p[patch_index * 2u];
					uvec4 b = patches.p[patch_index * 2u + 1u];
					TessJob job = TessJobData(args.a[0]).j[a.x];
					tess_batch = job.batch;
					PBRBatchData batch_data = PBRBatchData(args.a[13]);
					TessVertexData data = TessVertexData(job.vertices);
					TessVertexData extras = TessVertexData(packUint2x32(batch_data.b[job.batch].extras_address));
					int height_texture = batch_data.b[job.batch].m_displacement_model.HeightTexture;
					tess_fade_texture = (job.flags & 1u) != 0u ? batch_data.b[job.batch].m_model.AlbedoTexture : -1;
					mat4 world = TessWorldData(args.a[1]).w[a.x * 2u];
					uint n = b.w;
					uint vertex_count = (n + 1u) * (n + 2u) / 2u;
					RTVertexData core = RTVertexData(args.a[8]);
					RTVertexData out_extras = RTVertexData(args.a[9]);

					for (uint i = gl_LocalInvocationID.x; i < vertex_count; i += 64u) {
						uint r = uint((sqrt(8.0 * float(i) + 1.0) - 1.0) * 0.5);

						while (r * (r + 1u) / 2u > i) r--;
						while ((r + 1u) * (r + 2u) / 2u <= i) r++;

						uint c = i - r * (r + 1u) / 2u;
						TessSample s = tess_evaluate(job, a.y, a.z, ivec2(r, c), world, data, extras, height_texture, compute.seam_band);
						uint v = a.w + i;
						rt_vertex_set_position(core, v, s.local_position);
						rt_vertex_set_normal(core, v, s.normal);
						rt_vertex_set_uv(core, v, s.uv);
						rt_vertex_set_tangent(core, v, s.tangent);
						rt_vertex_set_texture_blend(out_extras, v, s.texture_blend);
						rt_vertex_set_color(out_extras, v, s.vertex_color);
						rt_vertex_set_pivot(out_extras, v, vec4(0.0));
						rt_vertex_set_chain_mid(out_extras, v, vec3(0.0));
						rt_vertex_set_chain_tip(out_extras, v, vec3(0.0));
					}

					TessWords templates = TessWords(args.a[7]);
					uint offset = templates.w[uint(findLSB(n))];
					TessWords indices = TessWords(args.a[10]);

					for (uint t = gl_LocalInvocationID.x; t < n * n; t += 64u) {
						for (uint k = 0u; k < 3u; k++) {
							indices.w[(b.x + t) * 3u + k] = a.w + rt_template_index(templates, offset, t * 3u + k);
						}
					}
				}
			]=],
		},
		refs = EasyPipeline.Compute{
			name = "tessellation_rt_refs",
			LocalSize = {x = 64, y = 1, z = 1},
			block = rt_block,
			write = write_rt_block,
			shader = RT_GLSL .. [=[
				void main() {
					uint patch_index = gl_GlobalInvocationID.x;
					RTArgs args = RTArgs(compute.args);

					if (patch_index >= TessWords(args.a[3]).w[4]) return;

					uvec4 b = TessPatchData(args.a[4]).p[patch_index * 2u + 1u];
					uvec4 info = RTInfos(args.a[6]).i[b.y];
					RTRefs(packUint2x32(info.zw) + uint64_t(b.z) * 8ul).a[0] = RTRefs(args.a[11]).a[patch_index];
				}
			]=],
		},
	}
	return rt_pipelines
end

local function build_templates()
	local words = {}
	local offsets = {}
	local bytes = {}
	local header = (RT_MAX_LOG + 1) * 4

	for log = 0, RT_MAX_LOG do
		offsets[log] = header + #bytes
		local n = 2 ^ log

		for small = 0, n * n - 1 do
			local r = math.floor(math.sqrt(small))

			while r * r > small do
				r = r - 1
			end

			while (r + 1) * (r + 1) <= small do
				r = r + 1
			end

			local c = small - r * r
			local k = math.floor(c / 2)
			local corners = c % 2 == 0 and
				{{r, k}, {r + 1, k}, {r + 1, k + 1}} or
				{{r, k}, {r + 1, k + 1}, {r, k + 1}}

			for _, q in ipairs(corners) do
				bytes[#bytes + 1] = q[1] * (q[1] + 1) / 2 + q[2]
			end
		end
	end

	local total = header + #bytes
	local buffer = render.CreateBuffer{
		byte_size = math.ceil(total / 4) * 4 + 4,
		buffer_usage = {
			"storage_buffer",
			"shader_device_address",
			"acceleration_structure_build_input_read_only_khr",
		},
		memory_property = {"host_visible", "host_coherent"},
		label = "tessellation_rt_templates",
	}
	local mapped = ffi.cast("uint8_t *", buffer:Map())
	local header_words = ffi.cast("uint32_t *", mapped)

	for log = 0, RT_MAX_LOG do
		header_words[log] = offsets[log]
	end

	for i, value in ipairs(bytes) do
		mapped[header + i - 1] = value
	end

	return buffer
end

local function rt_buffer(byte_size, usage, label)
	return render.CreateBuffer{
		byte_size = math.max(byte_size, 16),
		buffer_usage = usage,
		memory_property = {"device_local"},
		label = label,
	}
end

local function rt_cluster_build(
	cmd,
	op,
	count_address,
	info_address,
	info_stride,
	info_count,
	input,
	storage,
	addresses,
	scratch
)
	local commands = rt.commands[op]

	if op == 1 then
		commands[0].input.opInput.pClustersBottomLevel = rt.inputs[op]
	else
		commands[0].input.opInput.pTriangleClusters = rt.inputs[op]
	end

	commands[0].dstImplicitData = storage:GetDeviceAddress()
	commands[0].scratchData = scratch:GetDeviceAddress()
	commands[0].dstAddressesArray.deviceAddress = addresses:GetDeviceAddress()
	commands[0].dstAddressesArray.stride = 8
	commands[0].dstAddressesArray.size = info_count * 8
	commands[0].srcInfosArray.deviceAddress = info_address
	commands[0].srcInfosArray.stride = info_stride
	commands[0].srcInfosArray.size = info_count * info_stride
	commands[0].srcInfosCount = count_address
	render.GetDevice():GetExtension("vkCmdBuildClusterAccelerationStructureIndirectNV")(cmd.ptr[0], commands)
end

local function ensure_rt_buffers()
	if rt.built then return end

	local vk = vulkan.vk

	local function sizes(op, count, fill)
		local commands = ffi.new(ffi.typeof("$[1]", vk.VkClusterAccelerationStructureCommandsInfoNV))
		commands[0].sType = vk.VkStructureType.VK_STRUCTURE_TYPE_CLUSTER_ACCELERATION_STRUCTURE_COMMANDS_INFO_NV
		local input = commands[0].input
		input.sType = vk.VkStructureType.VK_STRUCTURE_TYPE_CLUSTER_ACCELERATION_STRUCTURE_INPUT_INFO_NV
		input.maxAccelerationStructureCount = count
		input.flags = 4
		input.opType = op
		input.opMode = 0
		local op_input = fill()

		if op == 1 then
			commands[0].input.opInput.pClustersBottomLevel = op_input
		else
			commands[0].input.opInput.pTriangleClusters = op_input
		end

		local info = ffi.new(ffi.typeof("$[1]", vk.VkAccelerationStructureBuildSizesInfoKHR))
		info[0].sType = vk.VkStructureType.VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_BUILD_SIZES_INFO_KHR
		local device = render.GetDevice()
		device:GetExtension("vkGetClusterAccelerationStructureBuildSizesNV")(device.ptr[0], commands[0].input, info)
		return commands,
		op_input,
		tonumber(info[0].accelerationStructureSize),
		tonumber(info[0].buildScratchSize)
	end

	local triangle_commands, triangle_input, clas_size, clas_scratch = sizes(2, RT_PATCHES, function()
		local input = ffi.new(ffi.typeof("$[1]", vk.VkClusterAccelerationStructureTriangleClusterInputNV))
		input[0].sType = vk.VkStructureType.VK_STRUCTURE_TYPE_CLUSTER_ACCELERATION_STRUCTURE_TRIANGLE_CLUSTER_INPUT_NV
		input[0].vertexFormat = 106
		input[0].maxGeometryIndexValue = 0
		input[0].maxClusterUniqueGeometryCount = 1
		input[0].maxClusterTriangleCount = RT_PATCH_TRIANGLES
		input[0].maxClusterVertexCount = RT_PATCH_VERTICES
		input[0].maxTotalTriangleCount = RT_TRIANGLES
		input[0].maxTotalVertexCount = RT_VERTICES
		return input
	end)
	local bottom_commands, bottom_input, blas_size, blas_scratch = sizes(1, RT_PATCHES, function()
		local input = ffi.new(ffi.typeof("$[1]", vk.VkClusterAccelerationStructureClustersBottomLevelInputNV))
		input[0].sType = vk.VkStructureType.VK_STRUCTURE_TYPE_CLUSTER_ACCELERATION_STRUCTURE_CLUSTERS_BOTTOM_LEVEL_INPUT_NV
		input[0].maxTotalClusterCount = RT_PATCHES
		input[0].maxClusterCountPerAccelerationStructure = RT_PATCHES
		return input
	end)
	rt.commands = {[2] = triangle_commands, [1] = bottom_commands}
	rt.inputs = {[2] = triangle_input, [1] = bottom_input}
	local input_usage = {
		"storage_buffer",
		"shader_device_address",
		"transfer_dst",
		"acceleration_structure_build_input_read_only_khr",
	}
	rt.templates = build_templates()
	rt.args = rt_buffer(
		RT_ARG_COUNT * 8,
		{"storage_buffer", "shader_device_address", "transfer_dst"},
		"tessellation_rt_args"
	)
	rt.counters = rt_buffer(
		RT_COUNTER_BYTES,
		{
			"storage_buffer",
			"shader_device_address",
			"transfer_dst",
			"indirect_buffer",
			"acceleration_structure_build_input_read_only_khr",
		},
		"tessellation_rt_counters"
	)
	rt.patches = rt_buffer(
		RT_PATCHES * 32,
		{"storage_buffer", "shader_device_address"},
		"tessellation_rt_patches"
	)
	rt.clas_args = rt_buffer(RT_PATCHES * 64, input_usage, "tessellation_rt_clas_args")
	rt.core = rt_buffer(RT_VERTICES * vertex_layout.CoreStride, input_usage, "tessellation_rt_core")
	rt.extras = rt_buffer(
		RT_VERTICES * vertex_layout.ExtrasStride,
		{"storage_buffer", "shader_device_address"},
		"tessellation_rt_extras"
	)
	rt.indices = rt_buffer(
		RT_TRIANGLES * 12,
		{"storage_buffer", "shader_device_address"},
		"tessellation_rt_indices"
	)
	rt.clas = rt_buffer(
		clas_size,
		{"acceleration_structure_storage_khr", "shader_device_address"},
		"tessellation_rt_clas"
	)
	rt.clas_addresses = rt_buffer(RT_PATCHES * 8, input_usage, "tessellation_rt_clas_addresses")
	rt.refs = rt_buffer(RT_PATCHES * 8, input_usage, "tessellation_rt_refs")
	rt.blas = rt_buffer(
		blas_size,
		{"acceleration_structure_storage_khr", "shader_device_address"},
		"tessellation_rt_blas"
	)
	rt.scratch = rt_buffer(
		math.max(clas_scratch, blas_scratch),
		{"storage_buffer", "shader_device_address"},
		"tessellation_rt_scratch"
	)
	rt.args_address = rt.args:GetDeviceAddress()
	rt.args_cpu = ffi.new("uint64_t[?]", RT_ARG_COUNT)
	rt.dispatch_ones = ffi.new("uint32_t[2]", 1, 1)
	meshes.SetTessellationRow(
		rt.core:GetDeviceAddress(),
		rt.extras:GetDeviceAddress(),
		rt.indices:GetDeviceAddress()
	)
	rt.built = true
end

local function ensure_rt_jobs(job_count, instance_capacity)
	if job_count <= rt.job_capacity and instance_capacity <= rt.instance_capacity then
		return
	end

	render.GetDevice():WaitIdle()

	for _, key in ipairs{"slot_buffer", "infos_buffer", "blas_addresses", "job_of_buffer"} do
		if rt[key] then rt[key]:Remove() end
	end

	rt.job_capacity = math.max(64, 2 ^ math.ceil(math.log(math.max(job_count, 1)) / math.log(2)))
	rt.instance_capacity = math.max(1024, 2 ^ math.ceil(math.log(math.max(instance_capacity, 1)) / math.log(2)))
	rt.slot_buffer = rt_buffer(
		rt.job_capacity * 4,
		{"storage_buffer", "shader_device_address", "transfer_dst"},
		"tessellation_rt_slots"
	)
	rt.infos_buffer = rt_buffer(
		rt.job_capacity * 16 + 16,
		{
			"storage_buffer",
			"shader_device_address",
			"transfer_dst",
			"acceleration_structure_build_input_read_only_khr",
		},
		"tessellation_rt_infos"
	)
	rt.blas_addresses = rt_buffer(
		rt.job_capacity * 8,
		{"storage_buffer", "shader_device_address"},
		"tessellation_rt_blas_addresses"
	)
	rt.job_of_buffer = rt_buffer(
		rt.instance_capacity * 4,
		{"storage_buffer", "shader_device_address", "transfer_dst"},
		"tessellation_rt_job_of"
	)
	rt.slots_cpu = ffi.new("uint32_t[?]", rt.job_capacity)
	rt.infos_cpu = ffi.new("uint32_t[?]", rt.job_capacity * 4 + 4)
	rt.job_of_cpu = ffi.new("uint32_t[?]", rt.instance_capacity)
end

function tessellation.BuildRT(cmd)
	rt.ready = false

	if
		not rt_enabled:Get() or
		not enabled:Get()
		or
		not render.GetDevice().cluster_acceleration_structure_supported or
		next(rows) == nil
	then
		return
	end

	local pipeline = get_pipeline()

	if not pipeline then return end

	build_jobs()

	if state.job_count == 0 then return end

	-- the raster draw comes later in the frame, until then its batch table may still list the previous jobs
	update_batches(pipeline)
	local tlas_table, data_table = instances.GetTables()
	ensure_rt_buffers()
	ensure_rt_jobs(state.job_count, tlas_table.capacity)
	local camera_object = render3d.GetCamera()
	local camera = camera_object:GetPosition()
	rt.camera_position = camera
	state.view_projection = camera_object:BuildViewMatrix() * camera_object:BuildUnjitteredProjectionMatrix()
	state.camera_position = camera
	state.resolution = render3d.GetRenderSize()
	state.focal = 0.5 * state.resolution.y * math.abs(camera_object:BuildUnjitteredProjectionMatrix().m11)
	local data = data_table:Get()
	local max_distance = rt_distance:Get()
	ffi.fill(rt.job_of_cpu, rt.instance_capacity * 4, 0xFF)
	local rt_jobs, ref_base = 0, 0

	for i, job in ipairs(state.job_rows) do
		local instance = data[job.id]
		local dx, dy, dz = instance.center_x - camera.x,
		instance.center_y - camera.y,
		instance.center_z - camera.z

		if
			math.sqrt(dx * dx + dy * dy + dz * dz) - instance.radius <= max_distance and
			ref_base + job.topology.triangle_count <= RT_PATCHES
		then
			rt.slots_cpu[i - 1] = rt_jobs
			rt.infos_cpu[rt_jobs * 4] = 0
			rt.infos_cpu[rt_jobs * 4 + 1] = 8
			local address = tonumber(rt.refs:GetDeviceAddress()) + ref_base * 8
			rt.infos_cpu[rt_jobs * 4 + 2] = address % 4294967296
			rt.infos_cpu[rt_jobs * 4 + 3] = math.floor(address / 4294967296)
			rt.job_of_cpu[job.id] = rt_jobs
			rt_jobs = rt_jobs + 1
			ref_base = ref_base + job.topology.triangle_count
		else
			rt.slots_cpu[i - 1] = RT_NONE
		end
	end

	if rt_jobs == 0 then return end

	rt.infos_cpu[rt.job_capacity * 4] = rt_jobs
	local args = rt.args_cpu
	args[0] = state.jobs_address
	args[1] = state.worlds_address
	args[2] = rt.slot_buffer:GetDeviceAddress()
	args[3] = rt.counters:GetDeviceAddress()
	args[4] = rt.patches:GetDeviceAddress()
	args[5] = rt.clas_args:GetDeviceAddress()
	args[6] = rt.infos_buffer:GetDeviceAddress()
	args[7] = rt.templates:GetDeviceAddress()
	args[8] = rt.core:GetDeviceAddress()
	args[9] = rt.extras:GetDeviceAddress()
	args[10] = rt.indices:GetDeviceAddress()
	args[11] = rt.clas_addresses:GetDeviceAddress()
	args[12] = rt.refs:GetDeviceAddress()
	args[13] = state.batches_address
	local commands = ffi.cast("uint32_t *", state.state_cpu)
	local state_args = ffi.cast("uint64_t *", state.state_cpu + STATE_ARGS_OFFSET)
	state_args[0] = state.jobs_address
	state_args[1] = state.worlds_address
	state_args[4] = tlas_table:GetAddress()
	state_args[5] = data_table:GetAddress()
	state_args[6] = instances.GetRasterTable():GetAddress()
	cmd:PipelineBarrier{srcStage = "all_commands", dstStage = "transfer", memoryBarrier = true}
	upload(
		cmd,
		state.state_buffer,
		state.state_cpu + STATE_ARGS_OFFSET,
		STATE_BYTES - STATE_ARGS_OFFSET,
		STATE_ARGS_OFFSET
	)
	upload(cmd, state.jobs_buffer, state.jobs_cpu, state.job_count * JOB_BYTES)
	upload(cmd, rt.args, args, RT_ARG_COUNT * 8)
	upload(cmd, rt.slot_buffer, rt.slots_cpu, state.job_count * 4)
	upload(cmd, rt.infos_buffer, rt.infos_cpu, rt_jobs * 16)
	upload(
		cmd,
		rt.infos_buffer,
		rt.infos_cpu + rt.job_capacity * 4,
		4,
		rt.job_capacity * 16
	)
	upload(cmd, rt.job_of_buffer, rt.job_of_cpu, rt.instance_capacity * 4)
	cmd:FillBuffer(rt.counters, 0, RT_COUNTER_BYTES, 0)
	cmd:PipelineBarrier{srcStage = "transfer", dstStage = "transfer", memoryBarrier = true}
	upload(cmd, rt.counters, rt.dispatch_ones, 8, 20)
	cmd:PipelineBarrier{srcStage = "transfer", dstStage = "compute", memoryBarrier = true}
	get_compute_pipelines().worlds:Dispatch(cmd, math.ceil(state.job_count / 64), 1, 1, 1)
	cmd:PipelineBarrier{srcStage = "compute", dstStage = "compute", memoryBarrier = true}
	local passes = get_rt_pipelines()
	passes.select:Dispatch(cmd, math.ceil(state.triangle_count / 64), 1, 1, 1)
	cmd:PipelineBarrier{
		srcStage = "compute",
		dstStage = {"compute", "draw_indirect"},
		memoryBarrier = true,
	}
	passes.vertices:DispatchIndirect(cmd, rt.counters, 16)
	cmd:PipelineBarrier{
		srcStage = "compute",
		dstStage = "acceleration_structure_build_khr",
		memoryBarrier = true,
	}
	rt_cluster_build(
		cmd,
		2,
		rt.counters:GetDeviceAddress() + 16,
		rt.clas_args:GetDeviceAddress(),
		64,
		RT_PATCHES,
		nil,
		rt.clas,
		rt.clas_addresses,
		rt.scratch
	)
	cmd:PipelineBarrier{
		srcStage = "acceleration_structure_build_khr",
		dstStage = "compute",
		memoryBarrier = true,
	}
	passes.refs:Dispatch(cmd, RT_PATCHES / 64, 1, 1, 1)
	cmd:PipelineBarrier{
		srcStage = "compute",
		dstStage = "acceleration_structure_build_khr",
		memoryBarrier = true,
	}
	rt_cluster_build(
		cmd,
		1,
		rt.infos_buffer:GetDeviceAddress() + rt.job_capacity * 16,
		rt.infos_buffer:GetDeviceAddress(),
		16,
		rt.job_capacity,
		nil,
		rt.blas,
		rt.blas_addresses,
		rt.scratch
	)
	cmd:PipelineBarrier{
		srcStage = "acceleration_structure_build_khr",
		dstStage = {"compute", "acceleration_structure_build_khr"},
		memoryBarrier = true,
	}
	rt.ready = true
	state.stats.rt_jobs = rt_jobs
end

function tessellation.GetTLASOverride()
	if not rt.ready then return 0, 0, 0 end

	return rt.job_of_buffer:GetDeviceAddress(),
	rt.blas_addresses:GetDeviceAddress(),
	rt.instance_capacity
end

function tessellation.IsDrawing()
	return state.ready
end

function tessellation.GetStats()
	return state.stats
end

function tessellation.GetRowCount()
	local count = 0

	for _ in pairs(rows) do
		count = count + 1
	end

	return count
end

return tessellation
