local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local commands = import("goluwa/cli/commands.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local scene_bvh = library()
-- Pre-register to break import cycle: visual -> render3d -> scene_bvh -> visual
import.loaded["goluwa/render3d/scene_bvh.lua"] = scene_bvh
local Visual = import("goluwa/entities/components/visual.lua")
local NodeArray = ffi.typeof([[
	struct {
		uint32_t left_first;
		uint32_t count;
		float bounds_min[3];
		float bounds_max[3];
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
local MAX_LEAF_TRIANGLES = 8
local MAX_DEPTH = 30
scene_bvh.STACK_SIZE = 32
scene_bvh.LightOcclusion = scene_bvh.LightOcclusion ~= false
scene_bvh.node_count = 0
scene_bvh.triangle_count = 0
scene_bvh.build_time = 0
scene_bvh.version = 0
-- world aabbs that changed while the tree was dirty. recorded by the shared
-- aabb scan in visual.lua, consumed by light occlusion when the version
-- bumps, so it does not have to rescan every visual's aabb on its own
scene_bvh.dirty_boxes = {}
-- visuals that changed while the tree was dirty. nil means a resnapshot
-- happened (everything is dirty); an empty set means no tracked change yet
scene_bvh.dirty_components = {}
-- per-visual local soup (mesh x entry-local matrix) and local child tree,
-- cached across builds so a moved visual only re-transforms its own block
scene_bvh.visual_cache = {}
-- top tree layout from the last full sah (block_base per visual in block
-- order). while the layout is unchanged and few aabbs moved, a build can
-- keep the split structure and only re-derive node bounds bottom-up, which
-- is much cheaper than re-running sah over every visual
scene_bvh.top_layout = {}
scene_bvh.top_node_count = 0
scene_bvh.top_lazy_count = 0

function scene_bvh.IsReady()
	return scene_bvh.triangle_count > 0
end

do
	local Matrix44 = import("goluwa/structs/matrix44.lua")
	local scratch = {}
	local empty_triangles = TriangleArray(1)

	local function get_scratch(node_capacity, tri_capacity, top_capacity)
		if not scratch.node_capacity or scratch.node_capacity < node_capacity then
			scratch.node_capacity = node_capacity
			scratch.nodes = NodeArray(node_capacity)
		end

		if not scratch.tri_out_capacity or scratch.tri_out_capacity < tri_capacity then
			scratch.tri_out_capacity = math.max(tri_capacity, 1)
			scratch.tri_out = TriangleArray(scratch.tri_out_capacity)
		end

		if not scratch.top_capacity or scratch.top_capacity < top_capacity then
			scratch.top_capacity = math.max(top_capacity, 1)
			scratch.top_bounds = FloatArray(scratch.top_capacity * 6)
			scratch.top_centroids = FloatArray(scratch.top_capacity * 3)
			scratch.top_order = UInt32Array(scratch.top_capacity)
		end

		if not scratch.tri_bounds_capacity or scratch.tri_bounds_capacity < tri_capacity then
			scratch.tri_bounds_capacity = math.max(tri_capacity, 1)
			scratch.tri_bounds = FloatArray(scratch.tri_bounds_capacity * 6)
			scratch.tri_centroids = FloatArray(scratch.tri_bounds_capacity * 3)
		end

		return scratch
	end

	local function surface_area(min_x, min_y, min_z, max_x, max_y, max_z)
		local dx = max_x - min_x

		if dx < 0 then return 0 end

		local dy = max_y - min_y
		local dz = max_z - min_z
		return 2 * (dx * dy + dy * dz + dz * dx)
	end

	local bin_counts = UInt32Array(BIN_COUNT)
	local bin_bounds = FloatArray(BIN_COUNT * 6)
	local right_area = FloatArray(BIN_COUNT)
	local right_count = UInt32Array(BIN_COUNT)

	-- SAH over the items in the order[] range [first, first+count). Item i
	-- holds its centroid at centroids[i*3] and its aabb at bounds[i*6]. Nodes
	-- are written postorder into cfg.nodes; cfg.cursor tracks the next free
	-- slot. Leaves are finalized by cfg.leaf_writer(node, first, count).
	-- force_split turns failed splits into mid splits instead of leaves, for
	-- trees whose leaves must hold exactly one item
	local function build_sah(cfg, node_index, first, count, depth)
		local order = cfg.order
		local centroids = cfg.centroids
		local bounds = cfg.bounds
		local nodes = cfg.nodes
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

		if count <= cfg.leaf_size or (depth >= MAX_DEPTH and not cfg.force_split) then
			cfg.leaf_writer(node, first, count)
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

		local scale = 1
		local best_cost = math.huge
		local split_bin = -1

		if extent > 1e-9 then
			scale = BIN_COUNT / extent

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
					local cost = l_count * surface_area(l_min_x, l_min_y, l_min_z, l_max_x, l_max_y, l_max_z) + right_count[b + 1] * right_area[b + 1]

					if cost < best_cost then
						best_cost = cost
						split_bin = b + 1
					end
				end
			end
		end

		if
			(
				split_bin < 0 or
				best_cost >= count * surface_area(min_x, min_y, min_z, max_x, max_y, max_z)
			)
			and
			not cfg.force_split
		then
			cfg.leaf_writer(node, first, count)
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

		local left_index = cfg.cursor[1]
		cfg.cursor[1] = left_index + 2
		node.left_first = left_index
		node.count = 0
		build_sah(cfg, left_index, first, left_count, depth + 1)
		build_sah(cfg, left_index + 1, first + left_count, count - left_count, depth + 1)
	end

	-- recompute top tree node bounds bottom-up without re-splitting. a top
	-- internal node points into the top region and is the union of both
	-- children; a top leaf points at a child root in the block region, whose
	-- bounds already track the visual's current world aabb
	local function rederive_top_node(index)
		local nodes = scratch.nodes
		local node = nodes[index]
		local left = node.left_first

		if left >= scene_bvh.top_node_count then
			local c = nodes[left]
			node.bounds_min[0] = c.bounds_min[0]
			node.bounds_min[1] = c.bounds_min[1]
			node.bounds_min[2] = c.bounds_min[2]
			node.bounds_max[0] = c.bounds_max[0]
			node.bounds_max[1] = c.bounds_max[1]
			node.bounds_max[2] = c.bounds_max[2]
		else
			rederive_top_node(left)
			rederive_top_node(left + 1)
			local a = nodes[left]
			local b = nodes[left + 1]
			node.bounds_min[0] = a.bounds_min[0] < b.bounds_min[0] and a.bounds_min[0] or b.bounds_min[0]
			node.bounds_min[1] = a.bounds_min[1] < b.bounds_min[1] and a.bounds_min[1] or b.bounds_min[1]
			node.bounds_min[2] = a.bounds_min[2] < b.bounds_min[2] and a.bounds_min[2] or b.bounds_min[2]
			node.bounds_max[0] = a.bounds_max[0] > b.bounds_max[0] and a.bounds_max[0] or b.bounds_max[0]
			node.bounds_max[1] = a.bounds_max[1] > b.bounds_max[1] and a.bounds_max[1] or b.bounds_max[1]
			node.bounds_max[2] = a.bounds_max[2] > b.bounds_max[2] and a.bounds_max[2] or b.bounds_max[2]
		end
	end

	local tmp_v_inv = Matrix44()
	local tmp_l = Matrix44()
	local tmp_box = FloatArray(6)

	local function matrix_equal(a, b)
		local eps = 1e-4
		return math.abs(a.m00 - b.m00) <= eps and
			math.abs(a.m01 - b.m01) <= eps and
			math.abs(a.m02 - b.m02) <= eps and
			math.abs(a.m03 - b.m03) <= eps and
			math.abs(a.m10 - b.m10) <= eps and
			math.abs(a.m11 - b.m11) <= eps and
			math.abs(a.m12 - b.m12) <= eps and
			math.abs(a.m13 - b.m13) <= eps and
			math.abs(a.m20 - b.m20) <= eps and
			math.abs(a.m21 - b.m21) <= eps and
			math.abs(a.m22 - b.m22) <= eps and
			math.abs(a.m23 - b.m23) <= eps and
			math.abs(a.m30 - b.m30) <= eps and
			math.abs(a.m31 - b.m31) <= eps and
			math.abs(a.m32 - b.m32) <= eps and
			math.abs(a.m33 - b.m33) <= eps
	end

	-- exact aabb of an oriented box (src = 6 floats) transformed by a matrix
	local function transform_box(m, src, dst)
		local cx = (src[0] + src[3]) / 2
		local cy = (src[1] + src[4]) / 2
		local cz = (src[2] + src[5]) / 2
		local hx = math.abs((src[3] - src[0]) / 2)
		local hy = math.abs((src[4] - src[1]) / 2)
		local hz = math.abs((src[5] - src[2]) / 2)
		local m00, m01, m02 = m.m00, m.m01, m.m02
		local m10, m11, m12 = m.m10, m.m11, m.m12
		local m20, m21, m22 = m.m20, m.m21, m.m22
		local m30, m31, m32 = m.m30, m.m31, m.m32
		local cx0 = cx * m00 + cy * m10 + cz * m20 + m30
		local cx1 = cx * m01 + cy * m11 + cz * m21 + m31
		local cx2 = cx * m02 + cy * m12 + cz * m22 + m32
		local rx = math.abs(m00) * hx + math.abs(m10) * hy + math.abs(m20) * hz
		local ry = math.abs(m01) * hx + math.abs(m11) * hy + math.abs(m21) * hz
		local rz = math.abs(m02) * hx + math.abs(m12) * hy + math.abs(m22) * hz
		dst[0] = cx0 - rx
		dst[1] = cx1 - ry
		dst[2] = cx2 - rz
		dst[3] = cx0 + rx
		dst[4] = cx1 + ry
		dst[5] = cx2 + rz
	end

	-- transforms a slot's mesh vertices by its local matrix into
	-- slot.local_tris. degenerate triangles are dropped, so the returned
	-- count can be smaller than slot.count
	local function build_slot_local(slot)
		local count = slot.count
		local tris = slot.local_tris
		local indices = scratch.indices
		local index_buffer = slot.index_buffer
		local index_count = count * 3

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

		local m = slot.local_matrix
		local m00, m01, m02 = m.m00, m.m01, m.m02
		local m10, m11, m12 = m.m10, m.m11, m.m12
		local m20, m21, m22 = m.m20, m.m21, m.m22
		local m30, m31, m32 = m.m30, m.m31, m.m32
		local vertices = ffi.cast("float*", slot.vertex_buffer.data)
		local stride = slot.vertex_buffer.stride / 4
		local written = 0

		for triangle = 0, count - 1 do
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
				local record = tris[written]
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
				record.emissive[0] = 0
				record.emissive[1] = 0
				record.emissive[2] = 0
				written = written + 1
			end
		end

		return written
	end

	-- per-tri aabbs and centroids of a visual's local soup, for the child SAH
	local function prepare_child_sah(vc)
		local slots = vc.slots
		local slot_of = vc.slot_of
		local tri_bounds = scratch.tri_bounds
		local tri_centroids = scratch.tri_centroids

		for i = 0, vc.total - 1 do
			local slot = slots[slot_of[i] + 1]
			local tri = slot.local_tris[i - slot.start]
			local x0, y0, z0 = tri.v0[0], tri.v0[1], tri.v0[2]
			local x1, y1, z1 = x0 + tri.e1[0], y0 + tri.e1[1], z0 + tri.e1[2]
			local x2, y2, z2 = x0 + tri.e2[0], y0 + tri.e2[1], z0 + tri.e2[2]
			local t = i * 6

			if x1 < x0 then x1, x0 = x0, x1 end

			if x2 < x0 then x2, x0 = x0, x2 end

			if x1 > x2 then x1, x2 = x2, x1 end

			if y1 < y0 then y1, y0 = y0, y1 end

			if y2 < y0 then y2, y0 = y0, y2 end

			if y1 > y2 then y1, y2 = y2, y1 end

			if z1 < z0 then z1, z0 = z0, z1 end

			if z2 < z0 then z2, z0 = z0, z2 end

			if z1 > z2 then z1, z2 = z2, z1 end

			tri_bounds[t + 0] = x0
			tri_bounds[t + 1] = y0
			tri_bounds[t + 2] = z0
			tri_bounds[t + 3] = x2
			tri_bounds[t + 4] = y2
			tri_bounds[t + 5] = z2
			tri_centroids[i * 3 + 0] = (x0 + x2) / 2
			tri_centroids[i * 3 + 1] = (y0 + y2) / 2
			tri_centroids[i * 3 + 2] = (z0 + z2) / 2
		end
	end

	-- world soup for a visual: local soup x the visual world matrix, in child
	-- SAH order, plus the child node bounds in world space with internal
	-- children remapped to the block's global base
	local function bake_visual_world(vc, v, block_base)
		local total = vc.total
		local order = vc.order
		local slot_of = vc.slot_of
		local slots = vc.slots
		local world = vc.world_block
		local m00, m01, m02 = v.m00, v.m01, v.m02
		local m10, m11, m12 = v.m10, v.m11, v.m12
		local m20, m21, m22 = v.m20, v.m21, v.m22
		local m30, m31, m32 = v.m30, v.m31, v.m32

		for i = 0, total - 1 do
			local l = order[i]
			local slot = slots[slot_of[l] + 1]
			local src = slot.local_tris[l - slot.start]
			local dst = world[i]
			local x0 = src.v0[0] * m00 + src.v0[1] * m10 + src.v0[2] * m20 + m30
			local y0 = src.v0[0] * m01 + src.v0[1] * m11 + src.v0[2] * m21 + m31
			local z0 = src.v0[0] * m02 + src.v0[1] * m12 + src.v0[2] * m22 + m32
			local e1x = src.e1[0] * m00 + src.e1[1] * m10 + src.e1[2] * m20
			local e1y = src.e1[0] * m01 + src.e1[1] * m11 + src.e1[2] * m21
			local e1z = src.e1[0] * m02 + src.e1[1] * m12 + src.e1[2] * m22
			local e2x = src.e2[0] * m00 + src.e2[1] * m10 + src.e2[2] * m20
			local e2y = src.e2[0] * m01 + src.e2[1] * m11 + src.e2[2] * m21
			local e2z = src.e2[0] * m02 + src.e2[1] * m12 + src.e2[2] * m22
			dst.v0[0] = x0
			dst.v0[1] = y0
			dst.v0[2] = z0
			dst.e1[0] = e1x
			dst.e1[1] = e1y
			dst.e1[2] = e1z
			dst.e2[0] = e2x
			dst.e2[1] = e2y
			dst.e2[2] = e2z
			dst.normal[0] = src.normal[0]
			dst.normal[1] = src.normal[1]
			dst.normal[2] = src.normal[2]
			dst.emissive[0] = slot.emissive_r
			dst.emissive[1] = slot.emissive_g
			dst.emissive[2] = slot.emissive_b
		end

		local local_nodes = vc.child_nodes
		local world_nodes = vc.child_world_nodes

		for j = 0, vc.node_count - 1 do
			local ln = local_nodes[j]
			local wn = world_nodes[j]
			wn.count = ln.count

			if wn.count == 0 then
				wn.left_first = block_base + ln.left_first
			else
				wn.left_first = vc.tri_base + ln.left_first
			end

			tmp_box[0] = ln.bounds_min[0]
			tmp_box[1] = ln.bounds_min[1]
			tmp_box[2] = ln.bounds_min[2]
			tmp_box[3] = ln.bounds_max[0]
			tmp_box[4] = ln.bounds_max[1]
			tmp_box[5] = ln.bounds_max[2]
			transform_box(v, tmp_box, tmp_box)
			wn.bounds_min[0] = tmp_box[0]
			wn.bounds_min[1] = tmp_box[1]
			wn.bounds_min[2] = tmp_box[2]
			wn.bounds_max[0] = tmp_box[3]
			wn.bounds_max[1] = tmp_box[4]
			wn.bounds_max[2] = tmp_box[5]
		end

		local root = local_nodes[0]
		tmp_box[0] = root.bounds_min[0]
		tmp_box[1] = root.bounds_min[1]
		tmp_box[2] = root.bounds_min[2]
		tmp_box[3] = root.bounds_max[0]
		tmp_box[4] = root.bounds_max[1]
		tmp_box[5] = root.bounds_max[2]
		transform_box(v, tmp_box, vc.world_aabb)
	end

	-- persistent grow-only host-mapped buffer: the VkBuffer is created (or
	-- grown) only when the current capacity is not enough, so the buffer
	-- object and any descriptors pointing at it survive across builds. the
	-- data itself is copied by the caller, possibly in partial ranges. the
	-- second return value says whether the buffer is fresh (needs a full fill)
	local function ensure_persistent_buffer(field, label, byte_size)
		local buffer = scene_bvh[field]

		if not buffer or buffer:GetSize() < byte_size then
			if buffer then buffer:Remove() end

			buffer = render.CreateBuffer{
				byte_size = byte_size,
				buffer_usage = {"storage_buffer"},
				memory_property = {"host_visible", "host_coherent"},
				label = label,
			}
			scene_bvh[field] = buffer
			return buffer, true
		end

		return buffer, false
	end

	function scene_bvh.Build(force_full)
		local start_time = os.clock()
		local cache = scene_bvh.visual_cache
		local blocks = {}
		local triangle_total = 0
		local present = {}
		local slow_count = 0

		for _, visual in ipairs(Visual.Instances) do
			local v = visual.Owner.transform:GetWorldMatrix()
			local vc = cache[visual]
			local slot_count = 0
			local slots = {}
			local fast = vc ~= nil and vc.matrix == v and vc.baked_matrix == v

			for _, entry in ipairs(visual:GetRenderEntries()) do
				local mesh = entry.polygon3d.mesh

				if mesh and mesh.Type ~= "null" then
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

						local e = entry.transform:GetWorldMatrix()
						local prev = fast and vc.slots[slot_count + 1] or false
						local slot = prev and
							prev.entry == entry and
							prev.count == count and
							prev.matrix == e and
							prev.emissive_r == emissive_r and
							prev.emissive_g == emissive_g and
							prev.emissive_b == emissive_b and
							prev

						if not slot then
							fast = false
							slot = {
								entry = entry,
								index_buffer = index_buffer,
								vertex_buffer = mesh.vertex_buffer,
								count = count,
								matrix = e,
							}
						end

						slot.emissive_r = emissive_r
						slot.emissive_g = emissive_g
						slot.emissive_b = emissive_b
						slot_count = slot_count + 1
						slots[slot_count] = slot
					end
				end
			end

			if slot_count == 0 then
				cache[visual] = nil
			else
				present[visual] = true
				local raw_total = 0

				for i = 1, slot_count do
					raw_total = raw_total + slots[i].count
				end

				if not fast then
					if not scratch.indices_capacity or scratch.indices_capacity < raw_total * 3 then
						scratch.indices_capacity = math.max(raw_total * 3, 1)
						scratch.indices = UInt32Array(scratch.indices_capacity)
					end

					local t0 = os.clock()
					local v_inv = v:GetInverse(tmp_v_inv)

					for i = 1, slot_count do
						local slot = slots[i]
						local l = slot.matrix:GetMultiplied(v_inv, tmp_l)

						if not (slot.local_tris and matrix_equal(slot.local_matrix, l)) then
							slot.local_matrix = {
								m00 = tmp_l.m00,
								m01 = tmp_l.m01,
								m02 = tmp_l.m02,
								m03 = tmp_l.m03,
								m10 = tmp_l.m10,
								m11 = tmp_l.m11,
								m12 = tmp_l.m12,
								m13 = tmp_l.m13,
								m20 = tmp_l.m20,
								m21 = tmp_l.m21,
								m22 = tmp_l.m22,
								m23 = tmp_l.m23,
								m30 = tmp_l.m30,
								m31 = tmp_l.m31,
								m32 = tmp_l.m32,
								m33 = tmp_l.m33,
							}

							if not slot.local_tris or slot.local_tris_capacity < slot.count then
								slot.local_tris = TriangleArray(slot.count)
								slot.local_tris_capacity = slot.count
							end

							slot.count = build_slot_local(slot)
						end
					end
				end

				vc = vc or {}
				vc.slow = not fast
				vc.matrix = v
				vc.slots = slots
				vc.slot_count = slot_count
				cache[visual] = vc
				local total = 0

				for i = 1, slot_count do
					total = total + slots[i].count
				end

				if total == 0 then
					cache[visual] = nil
				else
					if not fast then
						vc.total = total

						if not vc.world_aabb then vc.world_aabb = FloatArray(6) end

						if not vc.order_cap or vc.order_cap < total then
							vc.order_cap = total
							vc.order = UInt32Array(total)
							vc.slot_of_cap = total
							vc.slot_of = UInt32Array(total)
							vc.world_block_cap = total
							vc.world_block = TriangleArray(total)
						end

						if not vc.child_cap or vc.child_cap < total * 2 then
							vc.child_cap = total * 2
							vc.child_nodes = NodeArray(total * 2)
							vc.child_world_nodes = NodeArray(total * 2)
						end

						local span = 0

						for i = 1, slot_count do
							local slot = slots[i]
							slot.start = span

							for t = span, span + slot.count - 1 do
								vc.slot_of[t] = i - 1
							end

							span = span + slot.count
						end

						get_scratch(1, total, 1)

						for i = 0, total - 1 do
							vc.order[i] = i
						end

						prepare_child_sah(vc)
						local cursor = {1}
						build_sah(
							{
								order = vc.order,
								centroids = scratch.tri_centroids,
								bounds = scratch.tri_bounds,
								nodes = vc.child_nodes,
								cursor = cursor,
								leaf_size = MAX_LEAF_TRIANGLES,
								leaf_writer = function(node, first, count)
									node.left_first = first
									node.count = count
								end,
							},
							0,
							0,
							total,
							0
						)
						vc.node_count = cursor[1]
					end

					blocks[#blocks + 1] = vc
					triangle_total = triangle_total + vc.total

					if not fast then slow_count = slow_count + 1 end
				end
			end
		end

		for visual in pairs(cache) do
			if not present[visual] then cache[visual] = nil end
		end

		local node_count = 0
		local n = #blocks
		local layout_same = false

		if n == 0 then
			get_scratch(1, 1, 1)
			local nodes = scratch.nodes
			nodes[0].bounds_min[0] = 1
			nodes[0].bounds_min[1] = 1
			nodes[0].bounds_min[2] = 1
			nodes[0].bounds_max[0] = -1
			nodes[0].bounds_max[1] = -1
			nodes[0].bounds_max[2] = -1
			nodes[0].left_first = 0
			nodes[0].count = 0
			node_count = 1
		else
			local top_reserve = n * 2 - 1
			get_scratch(top_reserve + triangle_total * 2 + n, math.max(triangle_total, 1), n)
			local nodes = scratch.nodes
			local tri_out = scratch.tri_out
			-- layout: [top reserve][visual 0 child nodes][sentinel]...
			local tri_base = 0
			local node_base = top_reserve
			local block_roots = {}

			for i = 1, n do
				local vc = blocks[i]
				vc.tri_base = tri_base
				vc.block_base = node_base
				block_roots[i] = node_base
				tri_base = tri_base + vc.total
				node_base = node_base + vc.node_count + 1
			end

			node_count = node_base

			-- world bake for anything that moved (or baked with a different
			-- layout) since the last bake
			for i = 1, n do
				local vc = blocks[i]

				if vc.baked_matrix ~= vc.matrix or vc.baked_base ~= vc.block_base then
					bake_visual_world(vc, vc.matrix, vc.block_base)
					vc.baked_matrix = vc.matrix
					vc.baked_base = vc.block_base
				end
			end

			-- assemble blocks: world soup and child nodes memcpy, then the
			-- sentinel that closes each block. this runs before the top step
			-- because the lazy re-derivation reads the child roots from the
			-- assembled node buffer. blocks that are fast and were already
			-- assembled at this layout keep their scratch bytes
			for i = 1, n do
				local vc = blocks[i]

				if vc.slow or vc.assembled_base ~= vc.block_base then
					ffi.copy(tri_out + vc.tri_base, vc.world_block, vc.total * TRIANGLE_BYTE_SIZE)
					ffi.copy(nodes + vc.block_base, vc.child_world_nodes, vc.node_count * NODE_BYTE_SIZE)
					local sentinel = nodes[vc.block_base + vc.node_count]
					sentinel.left_first = 0
					sentinel.count = 0
					sentinel.bounds_min[0] = 1
					sentinel.bounds_min[1] = 1
					sentinel.bounds_min[2] = 1
					sentinel.bounds_max[0] = -1
					sentinel.bounds_max[1] = -1
					sentinel.bounds_max[2] = -1
					vc.assembled_base = vc.block_base
				end
			end

			layout_same = #scene_bvh.top_layout == n

			if layout_same then
				for i = 1, n do
					if scene_bvh.top_layout[i] ~= blocks[i].block_base then
						layout_same = false

						break
					end
				end
			end

			-- rebuilding the top tree runs sah over every visual aabb, the
			-- dominant build cost. while the layout is unchanged and only a few
			-- aabbs moved, keep the split structure from the last full build and
			-- only re-derive the bounds; the structure re-optimizes itself
			-- periodically (lazy cap) and on any layout change
			local lazy_top = layout_same and
				not force_full and
				slow_count <= math.max(8, math.floor(n / 8))
				and
				scene_bvh.top_lazy_count < 120

			if lazy_top then
				rederive_top_node(0)
				scene_bvh.top_lazy_count = scene_bvh.top_lazy_count + 1
			else
				-- top level: SAH over the per-visual world aabbs. a leaf holds
				-- one visual and points at (its child root, a dead sentinel
				-- node), so the flat traversal descends into the child tree
				local top_bounds = scratch.top_bounds
				local top_centroids = scratch.top_centroids
				local top_order = scratch.top_order

				for i = 1, n do
					local aabb = blocks[i].world_aabb
					top_order[i - 1] = i - 1
					top_bounds[(i - 1) * 6 + 0] = aabb[0]
					top_bounds[(i - 1) * 6 + 1] = aabb[1]
					top_bounds[(i - 1) * 6 + 2] = aabb[2]
					top_bounds[(i - 1) * 6 + 3] = aabb[3]
					top_bounds[(i - 1) * 6 + 4] = aabb[4]
					top_bounds[(i - 1) * 6 + 5] = aabb[5]
					top_centroids[(i - 1) * 3 + 0] = (aabb[0] + aabb[3]) / 2
					top_centroids[(i - 1) * 3 + 1] = (aabb[1] + aabb[4]) / 2
					top_centroids[(i - 1) * 3 + 2] = (aabb[2] + aabb[5]) / 2
				end

				local cursor = {1}
				build_sah(
					{
						order = top_order,
						centroids = top_centroids,
						bounds = top_bounds,
						nodes = nodes,
						cursor = cursor,
						leaf_size = 1,
						force_split = true,
						leaf_writer = function(node, first, count)
							node.count = 0
							-- first is a sah position; the item at that position is
							-- top_order[first] (sah reordered it in place), which is
							-- the visual's 0-based index into the blocks
							node.left_first = block_roots[top_order[first] + 1]
						end,
					},
					0,
					0,
					n,
					0
				)
				local layout = {}

				for i = 1, n do
					layout[i] = blocks[i].block_base
				end

				scene_bvh.top_layout = layout
				scene_bvh.top_node_count = cursor[1]
				scene_bvh.top_lazy_count = 0
			end
		end

		local tri_bytes = math.max(triangle_total, 1) * TRIANGLE_BYTE_SIZE
		local node_buffer, nodes_fresh = ensure_persistent_buffer("node_buffer", "scene_bvh_nodes", node_count * NODE_BYTE_SIZE)
		local tri_buffer, tris_fresh = ensure_persistent_buffer("triangle_buffer", "scene_bvh_triangles", tri_bytes)

		if nodes_fresh or tris_fresh or not layout_same then
			node_buffer:CopyData(scratch.nodes, node_count * NODE_BYTE_SIZE)
			tri_buffer:CopyData(triangle_total > 0 and scratch.tri_out or empty_triangles, tri_bytes)
		else
			-- block ranges are stable, so only the top region and the
			-- re-derived blocks changed; copy just those ranges
			node_buffer:CopyData(scratch.nodes, scene_bvh.top_node_count * NODE_BYTE_SIZE)

			for i = 1, n do
				local vc = blocks[i]

				if vc.slow then
					node_buffer:CopyData(
						scratch.nodes + vc.block_base,
						(vc.node_count + 1) * NODE_BYTE_SIZE,
						vc.block_base * NODE_BYTE_SIZE
					)
					tri_buffer:CopyData(vc.world_block, vc.total * TRIANGLE_BYTE_SIZE, vc.tri_base * TRIANGLE_BYTE_SIZE)
				end
			end
		end

		scene_bvh.debug_nodes = scratch.nodes
		scene_bvh.debug_node_count = node_count
		scene_bvh.debug_triangles = triangle_total > 0 and scratch.tri_out or nil
		scene_bvh.debug_triangle_count = triangle_total
		scene_bvh.node_count = node_count
		scene_bvh.triangle_count = triangle_total
		scene_bvh.BuildRasterBlocks(blocks)
		scene_bvh.build_time = os.clock() - start_time
		scene_bvh.has_built = true
		scene_bvh.dirty_components = {}
		scene_bvh.version = scene_bvh.version + 1
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

-- lights are not part of the bvh geometry, but their transforms invalidate
-- the light space data (occlusion maps, shadows). tracked so consumers and the
-- debug overlay can see when the light set moved
local function diff_lights()
	local light = import.loaded["goluwa/entities/components/light.lua"]

	if not light then return false end

	local lights = light.GetInstances()
	local signatures = scene_bvh.light_signatures or {}
	local changed = false
	local count = 0
	local tolerance = Visual.Library.AABB_TOLERANCE

	for _, light in ipairs(lights) do
		count = count + 1

		if light.Owner then
			local pos = light.Owner.transform:GetPosition()
			local sig = signatures[light]

			if
				not sig or
				math.abs(pos.x - sig[1]) > tolerance or
				math.abs(pos.y - sig[2]) > tolerance or
				math.abs(pos.z - sig[3]) > tolerance
			then
				signatures[light] = {pos.x, pos.y, pos.z}
				changed = true
			end
		else
			signatures[light] = nil
		end
	end

	if changed then
		scene_bvh.light_version = (scene_bvh.light_version or 0) + 1
	end

	scene_bvh.light_signatures = signatures
	scene_bvh.light_count = count
	return changed
end

function scene_bvh.EnsureBuilt()
	local frame = system.GetFrameNumber()
	local now = system.GetElapsedTime()

	if scene_bvh.ensure_frame == frame then return end

	scene_bvh.ensure_frame = frame
	local library = Visual.Library
	local changed = library.ScanWorldAABBs()
	diff_lights()

	if changed then
		scene_bvh.last_change_frame = frame
		scene_bvh.last_change_time = now

		if not scene_bvh.dirty_since then
			scene_bvh.dirty_since = system.GetElapsedTime()
		end

		if library.AABB_CHANGED_ALL then
			scene_bvh.dirty_all = true
			scene_bvh.dirty_components = nil
		else
			if scene_bvh.dirty_components then
				local comps = library.AABB_CHANGED_COMPONENTS or {}
				local set = scene_bvh.dirty_components

				for i = 1, #comps do
					set[comps[i]] = true
				end
			end

			if scene_bvh.dirty_boxes then
				local boxes = library.AABB_CHANGED_BOXES or {}
				local dirty = scene_bvh.dirty_boxes

				for i = 1, #boxes do
					dirty[#dirty + 1] = boxes[i]
				end

				if #dirty >= library.DIRTY_BOX_CAP then
					-- a long dirty window with lots of moving geometry: stop
					-- tracking per box and invalidate everything at once
					scene_bvh.dirty_boxes = nil
					scene_bvh.dirty_all = true
				end
			end
		end
	end

	if not scene_bvh.dirty_since then return end

	if not scene_bvh.node_buffer then
		ensure_placeholder_buffers()
		return
	end

	local settled = (scene_bvh.last_change_frame or 0) < frame - 1
	local max_wait = math.max(0.02, scene_bvh.build_time * 20)

	if not scene_bvh.has_built then
		local quiet_since = scene_bvh.last_change_time or scene_bvh.dirty_since

		if not quiet_since or now - quiet_since < 5.0 then return end
	elseif not settled and (now - scene_bvh.dirty_since) < max_wait then
		return
	end

	scene_bvh.dirty_since = nil
	scene_bvh.Build()
end

function scene_bvh.Invalidate()
	Visual.Library.ResetWorldAABBSignatures()

	-- keep the first change time so the wait window is not slid by every
	-- subsequent transform change
	if not scene_bvh.dirty_since then
		scene_bvh.dirty_since = system.GetElapsedTime()
	end

	scene_bvh.last_change_frame = -1
	scene_bvh.version = scene_bvh.version + 1
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
			uint left_first;
			uint count;
			vec3 bounds_min;
			vec3 bounds_max;
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

			scene_bvh_triangle final_triangle = scene_bvh_triangles[closest_triangle];
			hit.position = origin + dir * closest;
			hit.distance = closest;
			hit.emissive = final_triangle.emissive;
			hit.normal = dot(final_triangle.normal, dir) > 0.0 ? -final_triangle.normal : final_triangle.normal;
			return true;
		}
	]]
end

commands.Add("scene_bvh_rebuild", function()
	scene_bvh.Build()
end)

commands.Add("scene_bvh_info", function()
	logf(
		"[scene_bvh] %d triangles, %d nodes, built in %.2fs, top_lazy %d, version %d, dirty %s, light_version %d\n",
		scene_bvh.triangle_count,
		scene_bvh.node_count,
		scene_bvh.build_time,
		scene_bvh.top_lazy_count or 0,
		scene_bvh.version,
		scene_bvh.dirty_since and
			(
				"yes (%.2fs)"
			):format(system.GetElapsedTime() - scene_bvh.dirty_since) or
			"no",
		scene_bvh.light_version or 0
	)
end)

do
	local EXPAND_LOCAL_SIZE = 256
	scene_bvh.raster_blocks = {}

	local function ensure_position_buffer(state, vertex_count)
		local byte_size = vertex_count * 12

		if state.position_buffer and state.position_buffer:GetSize() >= byte_size then
			return state.position_buffer
		end

		if state.position_buffer then state.position_buffer:Remove() end

		state.position_buffer = render.CreateBuffer{
			byte_size = math.max(byte_size, 12),
			buffer_usage = {"vertex_buffer", "storage_buffer"},
			memory_property = {"device_local"},
			label = "scene_bvh_raster_positions",
		}
		return state.position_buffer
	end

	local function ensure_expand_pipeline(state)
		if state.expand_pipeline then return state.expand_pipeline end

		state.expand_pipeline = EasyPipeline.Compute{
			name = "scene_bvh_expand_positions",
			dont_create_framebuffers = true,
			DescriptorSetCount = 1,
			LocalSize = {EXPAND_LOCAL_SIZE, 1, 1},
			storage_buffers = {{binding_index = 0}, {binding_index = 1}},
			block = {
				{"vertex_count", "int"},
				write = function(self, block)
					block.vertex_count = scene_bvh.triangle_count * 3
					return block
				end,
			},
			custom_declarations = [[
				struct scene_bvh_triangle {
					vec3 v0;
					vec3 e1;
					vec3 e2;
					vec3 normal;
					vec3 emissive;
					float padding;
				};
				layout(scalar, set = 0, binding = 1) readonly buffer SceneBvhTri {
					scene_bvh_triangle tris[];
				};
				layout(scalar, set = 0, binding = 0) buffer SceneBvhPos {
					vec3 positions[];
				};
			]],
			shader = [[
				void main() {
					uint vid = gl_GlobalInvocationID.x;
					if (vid >= uint(compute.vertex_count)) return;
					uint tri = vid / 3u;
					scene_bvh_triangle t = tris[tri];
					uint which = vid - tri * 3u;
					vec3 p = t.v0;
					if (which == 1u) p += t.e1;
					else if (which == 2u) p += t.e2;
					positions[vid] = p;
				}
			]],
		}
		return state.expand_pipeline
	end

	-- per-visual draw ranges into the expanded position buffer, for cascade
	-- frustum culling. tri_base/total are soup triangle indices, x3 for the
	-- one-position-per-vertex layout
	function scene_bvh.BuildRasterBlocks(blocks)
		local out = {}

		for i = 1, #blocks do
			local vc = blocks[i]
			out[#out + 1] = {
				first_vertex = vc.tri_base * 3,
				vertex_count = vc.total * 3,
				min_x = vc.world_aabb[0],
				min_y = vc.world_aabb[1],
				min_z = vc.world_aabb[2],
				max_x = vc.world_aabb[3],
				max_y = vc.world_aabb[4],
				max_z = vc.world_aabb[5],
			}
		end

		scene_bvh.raster_blocks = out
	end

	function scene_bvh.ExpandPositions(cmd, state)
		if not scene_bvh.IsReady() then return 0, nil end

		local vertex_count = scene_bvh.triangle_count * 3

		if vertex_count <= 0 then return 0, nil end

		local position_buffer = ensure_position_buffer(state, vertex_count)
		local pipeline = ensure_expand_pipeline(state)
		local slot = 1
		pipeline:UpdateDescriptorSet(
			"storage_buffer",
			slot,
			1,
			0,
			scene_bvh.triangle_buffer,
			scene_bvh.triangle_buffer:GetSize()
		)
		pipeline:UpdateDescriptorSet("storage_buffer", slot, 0, 0, position_buffer, vertex_count * 12)
		pipeline:Dispatch(cmd, math.ceil(vertex_count / EXPAND_LOCAL_SIZE), 1, 1, slot)
		return vertex_count, position_buffer
	end
end

return scene_bvh
