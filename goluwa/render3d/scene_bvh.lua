
local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local commands = import("goluwa/cli/commands.lua")
local system = import("goluwa/system.lua")
local Visual = import("goluwa/entities/components/visual.lua")
local scene_bvh = library()
local NodeArray = ffi.typeof([[
	struct {
		float bounds_min[3];
		uint32_t left_first;
		float bounds_max[3];
		uint32_t count;
	}[?]
]])
local TriangleArray = ffi.typeof([[
	struct {
		float v0[3];
		float e1[3];
		float e2[3];
		float normal[3];
		float emissive[3];
		float padding;
	}[?]
]])
local FloatArray = ffi.typeof("float[?]")
local UInt32Array = ffi.typeof("uint32_t[?]")
local NODE_BYTE_SIZE = 32
local TRIANGLE_BYTE_SIZE = 64
local BIN_COUNT = 12
local MAX_LEAF_TRIANGLES = 4
local MAX_DEPTH = 30
scene_bvh.STACK_SIZE = 32
scene_bvh.SETTLE_TIME = 0.5
scene_bvh.node_count = 0
scene_bvh.triangle_count = 0
scene_bvh.build_time = 0

function scene_bvh.IsReady()
	return scene_bvh.triangle_count > 0
end

do
	local function surface_area(min_x, min_y, min_z, max_x, max_y, max_z)
		local dx = max_x - min_x

		if dx < 0 then return 0 end

		local dy = max_y - min_y
		local dz = max_z - min_z
		return 2 * (dx * dy + dy * dz + dz * dx)
	end

	local nodes
	local order
	local bounds
	local centroids
	local node_count = 0
	local bin_counts = UInt32Array(BIN_COUNT)
	local bin_bounds = FloatArray(BIN_COUNT * 6)
	local right_area = FloatArray(BIN_COUNT)
	local right_count = UInt32Array(BIN_COUNT)

	local function subdivide(node_index, first, count, depth)
		local node = nodes[node_index]
		local min_x, min_y, min_z = math.huge, math.huge, math.huge
		local max_x, max_y, max_z = -math.huge, -math.huge, -math.huge

		for i = first, first + count - 1 do
			local t = order[i] * 6

			if bounds[t + 0] < min_x then min_x = bounds[t + 0] end

			if bounds[t + 1] < min_y then min_y = bounds[t + 1] end

			if bounds[t + 2] < min_z then min_z = bounds[t + 2] end

			if bounds[t + 3] > max_x then max_x = bounds[t + 3] end

			if bounds[t + 4] > max_y then max_y = bounds[t + 4] end

			if bounds[t + 5] > max_z then max_z = bounds[t + 5] end
		end

		node.bounds_min[0] = min_x
		node.bounds_min[1] = min_y
		node.bounds_min[2] = min_z
		node.bounds_max[0] = max_x
		node.bounds_max[1] = max_y
		node.bounds_max[2] = max_z

		if count <= MAX_LEAF_TRIANGLES or depth >= MAX_DEPTH then
			node.left_first = first
			node.count = count
			return
		end

		local c_min_x, c_min_y, c_min_z = math.huge, math.huge, math.huge
		local c_max_x, c_max_y, c_max_z = -math.huge, -math.huge, -math.huge

		for i = first, first + count - 1 do
			local t = order[i] * 3

			if centroids[t + 0] < c_min_x then c_min_x = centroids[t + 0] end

			if centroids[t + 1] < c_min_y then c_min_y = centroids[t + 1] end

			if centroids[t + 2] < c_min_z then c_min_z = centroids[t + 2] end

			if centroids[t + 0] > c_max_x then c_max_x = centroids[t + 0] end

			if centroids[t + 1] > c_max_y then c_max_y = centroids[t + 1] end

			if centroids[t + 2] > c_max_z then c_max_z = centroids[t + 2] end
		end

		local axis = 0
		local origin = c_min_x
		local extent = c_max_x - c_min_x

		if c_max_y - c_min_y > extent then
			axis = 1
			origin = c_min_y
			extent = c_max_y - c_min_y
		end

		if c_max_z - c_min_z > extent then
			axis = 2
			origin = c_min_z
			extent = c_max_z - c_min_z
		end

		if extent <= 1e-9 then
			node.left_first = first
			node.count = count
			return
		end

		local scale = BIN_COUNT / extent

		for b = 0, BIN_COUNT - 1 do
			bin_counts[b] = 0
			bin_bounds[b * 6 + 0] = math.huge
			bin_bounds[b * 6 + 1] = math.huge
			bin_bounds[b * 6 + 2] = math.huge
			bin_bounds[b * 6 + 3] = -math.huge
			bin_bounds[b * 6 + 4] = -math.huge
			bin_bounds[b * 6 + 5] = -math.huge
		end

		for i = first, first + count - 1 do
			local t = order[i]
			local b = math.floor((centroids[t * 3 + axis] - origin) * scale)

			if b < 0 then b = 0 end

			if b > BIN_COUNT - 1 then b = BIN_COUNT - 1 end

			bin_counts[b] = bin_counts[b] + 1
			t = t * 6

			if bounds[t + 0] < bin_bounds[b * 6 + 0] then
				bin_bounds[b * 6 + 0] = bounds[t + 0]
			end

			if bounds[t + 1] < bin_bounds[b * 6 + 1] then
				bin_bounds[b * 6 + 1] = bounds[t + 1]
			end

			if bounds[t + 2] < bin_bounds[b * 6 + 2] then
				bin_bounds[b * 6 + 2] = bounds[t + 2]
			end

			if bounds[t + 3] > bin_bounds[b * 6 + 3] then
				bin_bounds[b * 6 + 3] = bounds[t + 3]
			end

			if bounds[t + 4] > bin_bounds[b * 6 + 4] then
				bin_bounds[b * 6 + 4] = bounds[t + 4]
			end

			if bounds[t + 5] > bin_bounds[b * 6 + 5] then
				bin_bounds[b * 6 + 5] = bounds[t + 5]
			end
		end

		local r_min_x, r_min_y, r_min_z = math.huge, math.huge, math.huge
		local r_max_x, r_max_y, r_max_z = -math.huge, -math.huge, -math.huge
		local r_count = 0

		for b = BIN_COUNT - 1, 1, -1 do
			if bin_counts[b] > 0 then
				if bin_bounds[b * 6 + 0] < r_min_x then r_min_x = bin_bounds[b * 6 + 0] end

				if bin_bounds[b * 6 + 1] < r_min_y then r_min_y = bin_bounds[b * 6 + 1] end

				if bin_bounds[b * 6 + 2] < r_min_z then r_min_z = bin_bounds[b * 6 + 2] end

				if bin_bounds[b * 6 + 3] > r_max_x then r_max_x = bin_bounds[b * 6 + 3] end

				if bin_bounds[b * 6 + 4] > r_max_y then r_max_y = bin_bounds[b * 6 + 4] end

				if bin_bounds[b * 6 + 5] > r_max_z then r_max_z = bin_bounds[b * 6 + 5] end

				r_count = r_count + bin_counts[b]
			end

			right_area[b] = surface_area(r_min_x, r_min_y, r_min_z, r_max_x, r_max_y, r_max_z)
			right_count[b] = r_count
		end

		local l_min_x, l_min_y, l_min_z = math.huge, math.huge, math.huge
		local l_max_x, l_max_y, l_max_z = -math.huge, -math.huge, -math.huge
		local l_count = 0
		local best_cost = math.huge
		local split_bin = -1

		for b = 0, BIN_COUNT - 2 do
			if bin_counts[b] > 0 then
				if bin_bounds[b * 6 + 0] < l_min_x then l_min_x = bin_bounds[b * 6 + 0] end

				if bin_bounds[b * 6 + 1] < l_min_y then l_min_y = bin_bounds[b * 6 + 1] end

				if bin_bounds[b * 6 + 2] < l_min_z then l_min_z = bin_bounds[b * 6 + 2] end

				if bin_bounds[b * 6 + 3] > l_max_x then l_max_x = bin_bounds[b * 6 + 3] end

				if bin_bounds[b * 6 + 4] > l_max_y then l_max_y = bin_bounds[b * 6 + 4] end

				if bin_bounds[b * 6 + 5] > l_max_z then l_max_z = bin_bounds[b * 6 + 5] end

				l_count = l_count + bin_counts[b]
			end

			if l_count > 0 and right_count[b + 1] > 0 then
				local cost = l_count * surface_area(l_min_x, l_min_y, l_min_z, l_max_x, l_max_y, l_max_z) +
					right_count[b + 1] * right_area[b + 1]

				if cost < best_cost then
					best_cost = cost
					split_bin = b + 1
				end
			end
		end

		if
			split_bin < 0 or
			best_cost >= count * surface_area(min_x, min_y, min_z, max_x, max_y, max_z)
		then
			node.left_first = first
			node.count = count
			return
		end

		local i = first
		local j = first + count - 1

		while i <= j do
			local t = order[i]
			local b = math.floor((centroids[t * 3 + axis] - origin) * scale)

			if b < 0 then b = 0 end

			if b > BIN_COUNT - 1 then b = BIN_COUNT - 1 end

			if b < split_bin then
				i = i + 1
			else
				order[i] = order[j]
				order[j] = t
				j = j - 1
			end
		end

		local left_count = i - first

		if left_count == 0 or left_count == count then
			left_count = math.floor(count / 2)
		end

		local left_index = node_count
		node_count = node_count + 2
		node.left_first = left_index
		node.count = 0
		subdivide(left_index, first, left_count, depth + 1)
		subdivide(left_index + 1, first + left_count, count - left_count, depth + 1)
	end

	function scene_bvh.Build()
		local start_time = os.clock()
		local sources = {}
		local triangle_total = 0

		for _, visual in ipairs(Visual.Instances) do
			for _, entry in ipairs(visual:GetRenderEntries()) do
				local mesh = entry.polygon3d.mesh

				if mesh then
					local index_buffer = mesh.index_buffer
					local count = index_buffer and
						math.floor(index_buffer:GetIndexCount() / 3) or
						math.floor(mesh.vertex_buffer:GetVertexCount() / 3)

					if count > 0 then
						local material = visual:GetResolvedMaterial(entry)
						local emissive_r, emissive_g, emissive_b = 0, 0, 0

						if
							material:GetAlbedoAlphaIsEmissive() or
							material:GetEmissiveTexture() ~= nil
						then
							local multiplier = material:GetEmissiveMultiplier()
							emissive_r = multiplier.r * multiplier.a
							emissive_g = multiplier.g * multiplier.a
							emissive_b = multiplier.b * multiplier.a
						end

						sources[#sources + 1] = {
							vertex_buffer = mesh.vertex_buffer,
							index_buffer = index_buffer,
							matrix = entry.transform:GetWorldMatrix(),
							triangle_count = count,
							emissive_r = emissive_r,
							emissive_g = emissive_g,
							emissive_b = emissive_b,
						}
						triangle_total = triangle_total + count
					end
				end
			end
		end

		local capacity = math.max(triangle_total, 1)
		local scratch = scene_bvh.scratch

		if not scratch or scratch.capacity < capacity then
			scratch = {
				capacity = capacity,
				triangles = TriangleArray(capacity),
				ordered = TriangleArray(capacity),
				centroids = FloatArray(capacity * 3),
				bounds = FloatArray(capacity * 6),
				order = UInt32Array(capacity),
				nodes = NodeArray(capacity * 2),
				indices = UInt32Array(capacity * 3),
			}
			scene_bvh.scratch = scratch
		end

		local triangles = scratch.triangles
		centroids = scratch.centroids
		bounds = scratch.bounds
		order = scratch.order
		local written = 0

		for _, source in ipairs(sources) do
			local index_count = source.triangle_count * 3
			local indices = scratch.indices
			local index_buffer = source.index_buffer

			if index_buffer then
				local data = index_buffer:GetData()

				if type(data) == "cdata" then
					local typed = ffi.cast(index_buffer:GetIndexTypeFFI() .. "*", data)

					for i = 0, index_count - 1 do
						indices[i] = typed[i]
					end
				else
					for i = 0, index_count - 1 do
						indices[i] = data[i + 1]
					end
				end
			else
				for i = 0, index_count - 1 do
					indices[i] = i
				end
			end

			local m = source.matrix
			local m00, m01, m02 = m.m00, m.m01, m.m02
			local m10, m11, m12 = m.m10, m.m11, m.m12
			local m20, m21, m22 = m.m20, m.m21, m.m22
			local m30, m31, m32 = m.m30, m.m31, m.m32
			local vertices = ffi.cast("float*", source.vertex_buffer.data)
			local stride = source.vertex_buffer.stride / 4
			local emissive_r = source.emissive_r
			local emissive_g = source.emissive_g
			local emissive_b = source.emissive_b

			for triangle = 0, source.triangle_count - 1 do
				local a = indices[triangle * 3 + 0] * stride
				local b = indices[triangle * 3 + 1] * stride
				local c = indices[triangle * 3 + 2] * stride
				local ax, ay, az = vertices[a], vertices[a + 1], vertices[a + 2]
				local bx, by, bz = vertices[b], vertices[b + 1], vertices[b + 2]
				local cx, cy, cz = vertices[c], vertices[c + 1], vertices[c + 2]
				local x0 = ax * m00 + ay * m10 + az * m20 + m30
				local y0 = ax * m01 + ay * m11 + az * m21 + m31
				local z0 = ax * m02 + ay * m12 + az * m22 + m32
				local x1 = bx * m00 + by * m10 + bz * m20 + m30
				local y1 = bx * m01 + by * m11 + bz * m21 + m31
				local z1 = bx * m02 + by * m12 + bz * m22 + m32
				local x2 = cx * m00 + cy * m10 + cz * m20 + m30
				local y2 = cx * m01 + cy * m11 + cz * m21 + m31
				local z2 = cx * m02 + cy * m12 + cz * m22 + m32
				local e1x, e1y, e1z = x1 - x0, y1 - y0, z1 - z0
				local e2x, e2y, e2z = x2 - x0, y2 - y0, z2 - z0
				local nx = e1y * e2z - e1z * e2y
				local ny = e1z * e2x - e1x * e2z
				local nz = e1x * e2y - e1y * e2x
				local length = math.sqrt(nx * nx + ny * ny + nz * nz)

				if length > 1e-12 then
					local record = triangles[written]
					record.v0[0] = x0
					record.v0[1] = y0
					record.v0[2] = z0
					record.e1[0] = e1x
					record.e1[1] = e1y
					record.e1[2] = e1z
					record.e2[0] = e2x
					record.e2[1] = e2y
					record.e2[2] = e2z
					record.normal[0] = nx / length
					record.normal[1] = ny / length
					record.normal[2] = nz / length
					record.emissive[0] = emissive_r
					record.emissive[1] = emissive_g
					record.emissive[2] = emissive_b
					centroids[written * 3 + 0] = (x0 + x1 + x2) / 3
					centroids[written * 3 + 1] = (y0 + y1 + y2) / 3
					centroids[written * 3 + 2] = (z0 + z1 + z2) / 3
					bounds[written * 6 + 0] = math.min(x0, x1, x2)
					bounds[written * 6 + 1] = math.min(y0, y1, y2)
					bounds[written * 6 + 2] = math.min(z0, z1, z2)
					bounds[written * 6 + 3] = math.max(x0, x1, x2)
					bounds[written * 6 + 4] = math.max(y0, y1, y2)
					bounds[written * 6 + 5] = math.max(z0, z1, z2)
					order[written] = written
					written = written + 1
				end
			end
		end

		nodes = scratch.nodes
		node_count = 1

		if written > 0 then
			subdivide(0, 0, written, 0)
		else
			nodes[0].bounds_min[0] = 1
			nodes[0].bounds_min[1] = 1
			nodes[0].bounds_min[2] = 1
			nodes[0].bounds_max[0] = -1
			nodes[0].bounds_max[1] = -1
			nodes[0].bounds_max[2] = -1
			nodes[0].left_first = 0
			nodes[0].count = 0
		end

		local ordered = scratch.ordered

		for i = 0, written - 1 do
			ordered[i] = triangles[order[i]]
		end

		if scene_bvh.node_buffer then scene_bvh.node_buffer:Remove() end

		if scene_bvh.triangle_buffer then scene_bvh.triangle_buffer:Remove() end


		scene_bvh.node_buffer = render.CreateBuffer{
			byte_size = node_count * NODE_BYTE_SIZE,
			buffer_usage = {"storage_buffer"},
			memory_property = {"host_visible", "host_coherent"},
			label = "scene_bvh_nodes",
			data = nodes,
		}
		scene_bvh.triangle_buffer = render.CreateBuffer{
			byte_size = math.max(written, 1) * TRIANGLE_BYTE_SIZE,
			buffer_usage = {"storage_buffer"},
			memory_property = {"host_visible", "host_coherent"},
			label = "scene_bvh_triangles",
			data = ordered,
		}
		scene_bvh.node_count = node_count
		scene_bvh.triangle_count = written
		scene_bvh.build_time = os.clock() - start_time
		scene_bvh.source_count = #sources
		scene_bvh.built_visual_count = #Visual.Instances
		scene_bvh.bounds = {
			nodes[0].bounds_min[0],
			nodes[0].bounds_min[1],
			nodes[0].bounds_min[2],
			nodes[0].bounds_max[0],
			nodes[0].bounds_max[1],
			nodes[0].bounds_max[2],
		}
		logf(
			"[scene_bvh] %d triangles from %d meshes into %d nodes in %.2fs, bounds (%.1f %.1f %.1f) to (%.1f %.1f %.1f)\n",
			written,
			#sources,
			node_count,
			scene_bvh.build_time,
			scene_bvh.bounds[1],
			scene_bvh.bounds[2],
			scene_bvh.bounds[3],
			scene_bvh.bounds[4],
			scene_bvh.bounds[5],
			scene_bvh.bounds[6]
		)
	end
end

local function ensure_placeholder_buffers()
	if scene_bvh.node_buffer then return end

	local nodes = NodeArray(1)
	nodes[0].bounds_min[0] = 1
	nodes[0].bounds_min[1] = 1
	nodes[0].bounds_min[2] = 1
	nodes[0].bounds_max[0] = -1
	nodes[0].bounds_max[1] = -1
	nodes[0].bounds_max[2] = -1
	nodes[0].left_first = 0
	nodes[0].count = 0
	scene_bvh.node_buffer = render.CreateBuffer{
		byte_size = NODE_BYTE_SIZE,
		buffer_usage = {"storage_buffer"},
		memory_property = {"host_visible", "host_coherent"},
		label = "scene_bvh_nodes_empty",
		data = nodes,
	}
	scene_bvh.triangle_buffer = render.CreateBuffer{
		byte_size = TRIANGLE_BYTE_SIZE,
		buffer_usage = {"storage_buffer"},
		memory_property = {"host_visible", "host_coherent"},
		label = "scene_bvh_triangles_empty",
		data = TriangleArray(1),
	}
end

function scene_bvh.EnsureBuilt()
	local count = #Visual.Instances

	if scene_bvh.built_visual_count == count then return end

	if scene_bvh.pending_visual_count ~= count then
		scene_bvh.pending_visual_count = count
		scene_bvh.pending_since = system.GetElapsedTime()
		ensure_placeholder_buffers()
		return
	end

	if system.GetElapsedTime() - scene_bvh.pending_since < scene_bvh.SETTLE_TIME then
		ensure_placeholder_buffers()
		return
	end

	scene_bvh.Build()
end

function scene_bvh.Invalidate()
	scene_bvh.built_visual_count = nil
	scene_bvh.pending_visual_count = nil
end

function scene_bvh.BindBuffers(pipeline, descriptor_index, node_binding, triangle_binding)
	pipeline:UpdateDescriptorSet(
		"storage_buffer",
		descriptor_index,
		node_binding,
		0,
		scene_bvh.node_buffer,
		scene_bvh.node_buffer:GetSize()
	)
	pipeline:UpdateDescriptorSet(
		"storage_buffer",
		descriptor_index,
		triangle_binding,
		0,
		scene_bvh.triangle_buffer,
		scene_bvh.triangle_buffer:GetSize()
	)
end

function scene_bvh.GetDeclarationsGLSL(node_binding, triangle_binding)
	return (
		[[
		struct scene_bvh_node {
			vec3 bounds_min;
			uint left_first;
			vec3 bounds_max;
			uint count;
		};

		struct scene_bvh_triangle {
			vec3 v0;
			vec3 e1;
			vec3 e2;
			vec3 normal;
			vec3 emissive;
			float padding;
		};

		layout(scalar, set = 0, binding = %d) readonly buffer SceneBVHNodeBuffer {
			scene_bvh_node scene_bvh_nodes[];
		};

		layout(scalar, set = 0, binding = %d) readonly buffer SceneBVHTriangleBuffer {
			scene_bvh_triangle scene_bvh_triangles[];
		};
	]]
	):format(node_binding, triangle_binding)
end

function scene_bvh.GetTraversalGLSL()
	return [[
		#define SCENE_BVH_MISS 3.402823466e+38
		#define SCENE_BVH_STACK_SIZE ]] .. scene_bvh.STACK_SIZE .. [[

		struct scene_bvh_hit {
			vec3 position;
			vec3 normal;
			vec3 emissive;
			float distance;
		};

		float scene_bvh_slab(uint index, vec3 origin, vec3 inv_dir, float t_min, float t_max) {
			vec3 low = (scene_bvh_nodes[index].bounds_min - origin) * inv_dir;
			vec3 high = (scene_bvh_nodes[index].bounds_max - origin) * inv_dir;
			vec3 near_corner = min(low, high);
			vec3 far_corner = max(low, high);
			float near_t = max(max(near_corner.x, near_corner.y), max(near_corner.z, t_min));
			float far_t = min(min(far_corner.x, far_corner.y), min(far_corner.z, t_max));
			return near_t <= far_t ? near_t : SCENE_BVH_MISS;
		}

		bool scene_bvh_trace(vec3 origin, vec3 dir, float t_min, float t_max, out scene_bvh_hit hit) {
			vec3 inv_dir = 1.0 / mix(dir, vec3(1e-20), lessThan(abs(dir), vec3(1e-20)));

			if (scene_bvh_slab(0u, origin, inv_dir, t_min, t_max) >= SCENE_BVH_MISS) {
				return false;
			}

			uint stack[SCENE_BVH_STACK_SIZE];
			int stack_size = 0;
			uint node_index = 0u;
			float closest = t_max;
			int closest_triangle = -1;

			while (true) {
				scene_bvh_node node = scene_bvh_nodes[node_index];
				uint count = node.count;

				if (count > 0u) {
					uint first = node.left_first;

					for (uint i = 0u; i < count; i++) {
						scene_bvh_triangle tri = scene_bvh_triangles[first + i];
						vec3 pvec = cross(dir, tri.e2);
						float det = dot(tri.e1, pvec);

						if (abs(det) < 1e-12) continue;

						float inv_det = 1.0 / det;
						vec3 tvec = origin - tri.v0;
						float u = dot(tvec, pvec) * inv_det;

						if (u < 0.0 || u > 1.0) continue;

						vec3 qvec = cross(tvec, tri.e1);
						float v = dot(dir, qvec) * inv_det;

						if (v < 0.0 || u + v > 1.0) continue;

						float t = dot(tri.e2, qvec) * inv_det;

						if (t > t_min && t < closest) {
							closest = t;
							closest_triangle = int(first + i);
						}
					}
				} else {
					uint left = node.left_first;
					float left_t = scene_bvh_slab(left, origin, inv_dir, t_min, closest);
					float right_t = scene_bvh_slab(left + 1u, origin, inv_dir, t_min, closest);
					uint near_index = left;
					uint far_index = left + 1u;
					float near_t = left_t;
					float far_t = right_t;

					if (right_t < left_t) {
						near_index = left + 1u;
						far_index = left;
						near_t = right_t;
						far_t = left_t;
					}

					if (near_t < SCENE_BVH_MISS) {
						if (far_t < SCENE_BVH_MISS && stack_size < SCENE_BVH_STACK_SIZE) {
							stack[stack_size] = far_index;
							stack_size++;
						}

						node_index = near_index;
						continue;
					}
				}

				bool popped = false;

				while (stack_size > 0) {
					stack_size--;

					if (scene_bvh_slab(stack[stack_size], origin, inv_dir, t_min, closest) < SCENE_BVH_MISS) {
						node_index = stack[stack_size];
						popped = true;
						break;
					}
				}

				if (!popped) break;
			}

			if (closest_triangle < 0) return false;

			hit.position = origin + dir * closest;
			hit.distance = closest;
			hit.emissive = scene_bvh_triangles[closest_triangle].emissive;
			vec3 normal = scene_bvh_triangles[closest_triangle].normal;
			hit.normal = dot(normal, dir) > 0.0 ? -normal : normal;
			return true;
		}
	]]
end

commands.Add("scene_bvh_rebuild", function()
	scene_bvh.Build()
end)

commands.Add("scene_bvh_info", function()
	logf(
		"[scene_bvh] %d triangles, %d nodes, %d meshes, built in %.2fs\n",
		scene_bvh.triangle_count,
		scene_bvh.node_count,
		scene_bvh.source_count or 0,
		scene_bvh.build_time
	)
end)

return scene_bvh
