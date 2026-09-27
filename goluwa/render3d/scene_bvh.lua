local ffi = require("ffi")
local band = require("bit").band
local render = import("goluwa/render/render.lua")
local commands = import("goluwa/cli/commands.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local scene_bvh = library()
-- Pre-register to break import cycle: visual -> render3d -> scene_bvh -> visual
import.loaded["goluwa/render3d/scene_bvh.lua"] = scene_bvh
local Visual = import("goluwa/entities/components/visual.lua")
local Material = import("goluwa/render3d/material.lua")
local Node = ffi.typeof([[
	struct {
		uint32_t left_first;
		uint32_t count;
		float bounds_min[3];
		float bounds_max[3];
	}
]])
local Triangle = ffi.typeof([[
	struct {
		float v0[3];
		float e1[3];
		float e2[3];
		float normal[3];
		float emissive[3];
		uint32_t material;
	}
]])
local NodeArray = ffi.typeof("$[?]", Node)
local NodePtr = ffi.typeof("$*", Node)
local TriangleArray = ffi.typeof("$[?]", Triangle)
-- an emissive triangle of a block: its index in the block (high bit set when
-- double sided) and its power, area x emission luminance
local Emitter = ffi.typeof([[struct {
	uint32_t triangle;
	float power;
}]])
local EmitterArray = ffi.typeof("$[?]", Emitter)
scene_bvh.EmitterArray = EmitterArray
local TrianglePtr = ffi.typeof("$*", Triangle)
local FloatArray = ffi.typeof("float[?]")
local UInt32Array = ffi.typeof("uint32_t[?]")
local Int32Array = ffi.typeof("int32_t[?]")
local UInt8Array = ffi.typeof("uint8_t[?]")
local NODE_BYTE_SIZE = 32
local TRIANGLE_BYTE_SIZE = 64
-- the soup is bound as an array of SOUP_CHUNKS descriptors over one buffer,
-- each covering 2 GiB of it, so a soup larger than maxStorageBufferRange (and
-- than what 32 bit byte offsets can address) stays reachable. triangle i lives
-- in chunk i / SOUP_CHUNK_TRIS at i % SOUP_CHUNK_TRIS
local SOUP_CHUNK_BYTES = 2147483648
local SOUP_CHUNKS = 8
local SOUP_CHUNK_TRIS = SOUP_CHUNK_BYTES / TRIANGLE_BYTE_SIZE
scene_bvh.SOUP_CHUNKS = SOUP_CHUNKS
scene_bvh.SOUP_CHUNK_TRIS = SOUP_CHUNK_TRIS
local BIN_COUNT = 12
local MAX_LEAF_TRIANGLES = 8
local MAX_DEPTH = 30
-- every visual's soup range starts at a multiple of this, so the ray tracing
-- instance of a visual can store its range start in the 24 bit custom index
local SOUP_ALIGN = 4
scene_bvh.SOUP_ALIGN = SOUP_ALIGN
scene_bvh.STACK_SIZE = 32
scene_bvh.LightOcclusion = scene_bvh.LightOcclusion ~= false
scene_bvh.node_count = 0
scene_bvh.triangle_count = 0
scene_bvh.build_time = 0
scene_bvh.version = 0
-- bumped only when a build writes new triangles. version also bumps on every
-- invalidation, so whatever is derived from the triangles themselves (the ray
-- tracing BLAS, the expanded shadow soup, the emitter list) follows this one
scene_bvh.soup_version = 0
-- world aabbs that changed while the tree was dirty. recorded by the shared
-- aabb scan in visual.lua, consumed by light occlusion when the version
-- bumps, so it does not have to rescan every visual's aabb on its own
scene_bvh.dirty_boxes = {}
-- blocks holding emissive triangles (see the end of a build)
scene_bvh.emissive_blocks = {}
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
-- top node index -> the block root it copies (see the top leaf writer)
scene_bvh.top_leaf_roots = {}
-- top node index -> the block of a top leaf, and the same as block index + 1
-- in top_leaf_block (0 for internal nodes) for walks that avoid the tables
scene_bvh.top_leaf = {}
-- every material that has been part of a build, indexed by the per-triangle
-- material id + 1. ids are never reused so a cached block keeps pointing at
-- the right material across builds
scene_bvh.materials = {}
scene_bvh.material_ids = {}

-- ranges (of the soup, the node buffer, blas storage) are rounded up to size
-- classes at most 1/8 larger than needed, so freed ranges can be reused by
-- ranges of a similar size
local function range_class(n, align)
	if n <= 16 then return math.ceil(n / align) * align end

	local step = 1

	while step * 16 <= n do
		step = step * 2
	end

	step = math.max(step, align)
	return math.ceil(n / step) * step
end

function scene_bvh.GetMaterialID(material)
	local id = scene_bvh.material_ids[material]

	if not id then
		id = #scene_bvh.materials
		scene_bvh.materials[id + 1] = material
		scene_bvh.material_ids[material] = id
	end

	return id
end

-- world bounds of everything in the tree (the root node's box) as two float
-- arrays, nil while nothing with triangles has been built
function scene_bvh.GetBounds()
	if scene_bvh.triangle_count == 0 then return nil end

	local root = scene_bvh.debug_nodes[0]
	return root.bounds_min, root.bounds_max
end

function scene_bvh.IsReady()
	return scene_bvh.triangle_count > 0
end

-- sets raster_visible[block index] for every block whose bounds touch the
-- frustum (planes as a float[24], a b c d per plane) by walking the top tree.
-- a node inside a plane drops it from the planes its subtree still tests, so
-- a subtree inside all of them is marked without further tests. the caller
-- clears the marks it reads
do
	local node_stack = {}
	local mask_stack = {}

	function scene_bvh.MarkVisibleBlocks(planes)
		local nodes = scene_bvh.nodes
		local top_leaf_block = scene_bvh.top_leaf_block
		local visible = scene_bvh.raster_visible

		if not (nodes and visible) then return end

		node_stack[1] = 0
		mask_stack[1] = 63
		local top = 1

		while top > 0 do
			local index = node_stack[top]
			local mask = mask_stack[top]
			top = top - 1

			if mask ~= 0 then
				local node = nodes[index]
				local min, max = node.bounds_min, node.bounds_max
				local plane_bit = 1

				for p = 0, 20, 4 do
					if band(mask, plane_bit) ~= 0 then
						local a, b, c, d = planes[p], planes[p + 1], planes[p + 2], planes[p + 3]

						if
							a * (
								a > 0 and
								max[0] or
								min[0]
							) + b * (
								b > 0 and
								max[1] or
								min[1]
							) + c * (
								c > 0 and
								max[2] or
								min[2]
							) + d < 0
						then
							goto continue
						end

						if
							a * (
								a > 0 and
								min[0] or
								max[0]
							) + b * (
								b > 0 and
								min[1] or
								max[1]
							) + c * (
								c > 0 and
								min[2] or
								max[2]
							) + d >= 0
						then
							mask = mask - plane_bit
						end
					end

					plane_bit = plane_bit * 2
				end
			end

			do
				local block_index = top_leaf_block[index]

				if block_index ~= 0 then
					visible[block_index - 1] = 1
				else
					local left = nodes[index].left_first
					node_stack[top + 1] = left
					mask_stack[top + 1] = mask
					node_stack[top + 2] = left + 1
					mask_stack[top + 2] = mask
					top = top + 2
				end
			end

			::continue::
		end
	end
end

do
	local Matrix44 = import("goluwa/structs/matrix44.lua")
	local scratch = {}

	local function get_scratch(tri_capacity, top_capacity)
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

	-- every visual owns a fixed range of triangles and a fixed range of nodes,
	-- so a change to one visual rewrites only its own ranges. freed ranges
	-- are reused by the next range of the same size class
	local function create_allocator(first, align, grow)
		return {
			top = first,
			first = first,
			align = align,
			free = {},
			used = 0,
			capacity = 0,
			grow = grow,
		}
	end

	local function range_alloc(allocator, n)
		local cap = range_class(n, allocator.align)
		local list = allocator.free[cap]
		local base

		if list and list[1] then
			base = list[#list]
			list[#list] = nil
		else
			base = allocator.top
			allocator.top = base + cap

			if allocator.top > allocator.capacity then
				allocator.grow(allocator.top, allocator)
			end
		end

		allocator.used = allocator.used + cap
		return base, cap
	end

	local function range_free(allocator, base, cap)
		local list = allocator.free[cap]

		if not list then
			list = {}
			allocator.free[cap] = list
		end

		list[#list + 1] = base
		allocator.used = allocator.used - cap
	end

	-- the node mirror is the cpu copy of the node buffer. triangles have no
	-- mirror: they are baked straight into the mapped buffer
	local function write_node(index)
		ffi.copy(scene_bvh.node_ptr + index, scene_bvh.nodes + index, NODE_BYTE_SIZE)
	end

	local function create_mapped_buffer(label, byte_size)
		local buffer = render.CreateBuffer{
			byte_size = byte_size,
			buffer_usage = {"storage_buffer"},
			memory_property = {"host_visible", "host_coherent"},
			label = label,
		}
		return buffer, buffer:Map()
	end

	local function grow_nodes(needed)
		local capacity = math.max(needed, math.ceil(scene_bvh.node_capacity * 1.5), 1024)
		local nodes = NodeArray(capacity)

		if scene_bvh.nodes then
			ffi.copy(nodes, scene_bvh.nodes, scene_bvh.node_capacity * NODE_BYTE_SIZE)
		end

		if scene_bvh.node_buffer then scene_bvh.node_buffer:Remove() end

		local buffer, ptr = create_mapped_buffer("scene_bvh_nodes", capacity * NODE_BYTE_SIZE)
		scene_bvh.node_buffer = buffer
		scene_bvh.node_ptr = ffi.cast(NodePtr, ptr)
		ffi.copy(scene_bvh.node_ptr, nodes, capacity * NODE_BYTE_SIZE)
		local top_leaf_block = Int32Array(capacity)

		if scene_bvh.top_leaf_block then
			ffi.copy(top_leaf_block, scene_bvh.top_leaf_block, scene_bvh.node_capacity * 4)
		end

		scene_bvh.nodes = nodes
		scene_bvh.debug_nodes = nodes
		scene_bvh.top_leaf_block = top_leaf_block
		scene_bvh.node_capacity = capacity
		scene_bvh.node_allocator.capacity = capacity
	end

	local bake_triangles

	-- the soup lives only in the mapped buffer, so a grown buffer is baked
	-- again from every block's shape. consumers that expand it see the new
	-- generation and redo everything
	local function grow_triangles(needed)
		local capacity = math.max(needed, math.ceil(scene_bvh.triangle_capacity * 1.5), 1024)

		if scene_bvh.triangle_buffer then scene_bvh.triangle_buffer:Remove() end

		local buffer, ptr = create_mapped_buffer("scene_bvh_triangles", capacity * TRIANGLE_BYTE_SIZE)
		scene_bvh.triangle_buffer = buffer
		scene_bvh.triangles = ffi.cast(TrianglePtr, ptr)

		-- a block that is not baked yet (being laid out or moved to a bigger
		-- range) is written once it has its range
		for _, vc in ipairs(scene_bvh.blocks) do
			if vc.baked_matrix then bake_triangles(vc) end
		end

		for cap, list in pairs(scene_bvh.triangle_allocator.free) do
			for _, base in ipairs(list) do
				ffi.fill(scene_bvh.triangles + base, cap * TRIANGLE_BYTE_SIZE)
			end
		end

		scene_bvh.triangle_capacity = capacity
		scene_bvh.triangle_allocator.capacity = capacity
		scene_bvh.soup_generation = scene_bvh.soup_generation + 1
	end

	-- ranges of the soup rewritten since the consumers last looked (see
	-- ExpandPositions), as flat triangle index / count pairs
	local SOUP_LOG_LIMIT = 8192

	local function log_soup_range(first, count)
		local log = scene_bvh.soup_log
		local n = #log

		-- entries of earlier builds may already have been consumed, so only
		-- this build's entries are extended
		if n > scene_bvh.soup_log_sealed and log[n - 1] + log[n] == first then
			log[n] = log[n] + count
			return
		end

		if n >= SOUP_LOG_LIMIT * 2 then
			scene_bvh.soup_log_base = scene_bvh.soup_log_base + n
			log = {}
			scene_bvh.soup_log = log
			scene_bvh.soup_log_sealed = 0
			n = 0
		end

		log[n + 1] = first
		log[n + 2] = count
	end

	-- zeroed triangles expand to degenerate ones, so the padding of a range
	-- and a freed range draw nothing. that lets the shadow soup draw runs of
	-- neighbouring blocks as one range across their padding
	local function free_soup_range(base, cap)
		range_free(scene_bvh.triangle_allocator, base, cap)
		ffi.fill(scene_bvh.triangles + base, cap * TRIANGLE_BYTE_SIZE)
		log_soup_range(base, cap)
	end

	-- the raster block of every entry in blocks, by block index: world bounds
	-- and the padded soup vertex range, for frustum culling the soup without
	-- touching the block tables
	local function write_raster_block(vc)
		local i = vc.block_index - 1

		if i >= scene_bvh.raster_capacity then
			local capacity = math.max(math.ceil((i + 1) * 1.5), 1024)
			local bounds = FloatArray(capacity * 6)
			local ranges = Int32Array(capacity * 2)

			if scene_bvh.raster_bounds then
				ffi.copy(bounds, scene_bvh.raster_bounds, scene_bvh.raster_capacity * 6 * 4)
				ffi.copy(ranges, scene_bvh.raster_ranges, scene_bvh.raster_capacity * 2 * 4)
			end

			scene_bvh.raster_bounds = bounds
			scene_bvh.raster_ranges = ranges
			scene_bvh.raster_visible = UInt8Array(capacity)
			scene_bvh.raster_capacity = capacity
		end

		ffi.copy(scene_bvh.raster_bounds + i * 6, vc.world_aabb, 6 * 4)
		scene_bvh.raster_ranges[i * 2] = vc.tri_base * 3
		scene_bvh.raster_ranges[i * 2 + 1] = (vc.tri_base + vc.tri_cap) * 3
	end

	local function reset_layout()
		scene_bvh.node_allocator = create_allocator(1, 1, grow_nodes)
		scene_bvh.node_allocator.capacity = scene_bvh.node_capacity
		scene_bvh.triangle_allocator = create_allocator(0, SOUP_ALIGN, grow_triangles)
		scene_bvh.triangle_allocator.capacity = scene_bvh.triangle_capacity
		scene_bvh.blocks = {}
		scene_bvh.top_parent = {}

		for index in pairs(scene_bvh.top_leaf) do
			scene_bvh.top_leaf_block[index] = 0
		end

		scene_bvh.top_leaf = {}
		scene_bvh.top_count = 0
		scene_bvh.top_changes = 0
		scene_bvh.triangle_count = 0
		scene_bvh.soup_generation = scene_bvh.soup_generation + 1

		for _, vc in pairs(scene_bvh.visual_cache) do
			if scene_bvh.changed_blocks then scene_bvh.changed_blocks[vc] = true end

			vc.tri_base = nil
			vc.block_base = nil
			vc.top_slot = nil
			vc.block_index = nil
			vc.baked_matrix = nil
		end

		if scene_bvh.node_capacity == 0 then grow_nodes(1) end

		if scene_bvh.triangle_capacity == 0 then grow_triangles(1) end
	end

	scene_bvh.node_capacity = 0
	scene_bvh.triangle_capacity = 0
	scene_bvh.soup_generation = 0
	scene_bvh.soup_log = {}
	scene_bvh.soup_log_base = 0
	scene_bvh.soup_log_sealed = 0
	scene_bvh.blocks = {}
	scene_bvh.raster_capacity = 0

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
	local right_bounds = FloatArray(BIN_COUNT * 6)
	local min = math.min
	local max = math.max

	-- SAH over the items in the order[] range [first, first+count). Item i
	-- holds its centroid at centroids[i*3] and its aabb at bounds[i*6]. Child
	-- pairs come from cfg.allocator when given, otherwise from cfg.cursor,
	-- which tracks the next free slot. Leaves are finalized by
	-- cfg.leaf_writer(node, first, count, node_index). force_split turns
	-- failed splits into mid splits instead of leaves, for trees whose leaves
	-- must hold exactly one item. has_bounds says the node's bounds were
	-- already written by the parent's split
	local function build_sah(cfg, node_index, first, count, depth, has_bounds)
		local order = cfg.order
		local centroids = cfg.centroids
		local bounds = cfg.bounds
		local nodes = cfg.nodes
		local node = nodes[node_index]

		if not has_bounds then
			local min_x, min_y, min_z = math.huge, math.huge, math.huge
			local max_x, max_y, max_z = -math.huge, -math.huge, -math.huge

			for i = first, first + count - 1 do
				local t = order[i] * 6
				min_x = min(min_x, bounds[t + 0])
				min_y = min(min_y, bounds[t + 1])
				min_z = min(min_z, bounds[t + 2])
				max_x = max(max_x, bounds[t + 3])
				max_y = max(max_y, bounds[t + 4])
				max_z = max(max_z, bounds[t + 5])
			end

			node.bounds_min[0] = min_x
			node.bounds_min[1] = min_y
			node.bounds_min[2] = min_z
			node.bounds_max[0] = max_x
			node.bounds_max[1] = max_y
			node.bounds_max[2] = max_z
		end

		if count <= cfg.leaf_size or (depth >= MAX_DEPTH and not cfg.force_split) then
			cfg.leaf_writer(node, first, count, node_index)
			return
		end

		local c_min_x, c_min_y, c_min_z = math.huge, math.huge, math.huge
		local c_max_x, c_max_y, c_max_z = -math.huge, -math.huge, -math.huge

		for i = first, first + count - 1 do
			local t = order[i] * 3
			local x, y, z = centroids[t + 0], centroids[t + 1], centroids[t + 2]
			c_min_x = min(c_min_x, x)
			c_min_y = min(c_min_y, y)
			c_min_z = min(c_min_z, z)
			c_max_x = max(c_max_x, x)
			c_max_y = max(c_max_y, y)
			c_max_z = max(c_max_z, z)
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
		local lb_min_x, lb_min_y, lb_min_z, lb_max_x, lb_max_y, lb_max_z = 0, 0, 0, 0, 0, 0

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
				local b = min(max(math.floor((centroids[t * 3 + axis] - origin) * scale), 0), BIN_COUNT - 1)
				bin_counts[b] = bin_counts[b] + 1
				t = t * 6
				local o = b * 6
				bin_bounds[o + 0] = min(bin_bounds[o + 0], bounds[t + 0])
				bin_bounds[o + 1] = min(bin_bounds[o + 1], bounds[t + 1])
				bin_bounds[o + 2] = min(bin_bounds[o + 2], bounds[t + 2])
				bin_bounds[o + 3] = max(bin_bounds[o + 3], bounds[t + 3])
				bin_bounds[o + 4] = max(bin_bounds[o + 4], bounds[t + 4])
				bin_bounds[o + 5] = max(bin_bounds[o + 5], bounds[t + 5])
			end

			local r_min_x, r_min_y, r_min_z = math.huge, math.huge, math.huge
			local r_max_x, r_max_y, r_max_z = -math.huge, -math.huge, -math.huge
			local r_count = 0

			for b = BIN_COUNT - 1, 1, -1 do
				local o = b * 6
				r_min_x = min(r_min_x, bin_bounds[o + 0])
				r_min_y = min(r_min_y, bin_bounds[o + 1])
				r_min_z = min(r_min_z, bin_bounds[o + 2])
				r_max_x = max(r_max_x, bin_bounds[o + 3])
				r_max_y = max(r_max_y, bin_bounds[o + 4])
				r_max_z = max(r_max_z, bin_bounds[o + 5])
				r_count = r_count + bin_counts[b]
				right_area[b] = surface_area(r_min_x, r_min_y, r_min_z, r_max_x, r_max_y, r_max_z)
				right_count[b] = r_count
				right_bounds[o + 0] = r_min_x
				right_bounds[o + 1] = r_min_y
				right_bounds[o + 2] = r_min_z
				right_bounds[o + 3] = r_max_x
				right_bounds[o + 4] = r_max_y
				right_bounds[o + 5] = r_max_z
			end

			local l_min_x, l_min_y, l_min_z = math.huge, math.huge, math.huge
			local l_max_x, l_max_y, l_max_z = -math.huge, -math.huge, -math.huge
			local l_count = 0

			for b = 0, BIN_COUNT - 2 do
				local o = b * 6
				l_min_x = min(l_min_x, bin_bounds[o + 0])
				l_min_y = min(l_min_y, bin_bounds[o + 1])
				l_min_z = min(l_min_z, bin_bounds[o + 2])
				l_max_x = max(l_max_x, bin_bounds[o + 3])
				l_max_y = max(l_max_y, bin_bounds[o + 4])
				l_max_z = max(l_max_z, bin_bounds[o + 5])
				l_count = l_count + bin_counts[b]

				if l_count > 0 and right_count[b + 1] > 0 then
					local cost = l_count * surface_area(l_min_x, l_min_y, l_min_z, l_max_x, l_max_y, l_max_z) + right_count[b + 1] * right_area[b + 1]

					if cost < best_cost then
						best_cost = cost
						split_bin = b + 1
						lb_min_x, lb_min_y, lb_min_z = l_min_x, l_min_y, l_min_z
						lb_max_x, lb_max_y, lb_max_z = l_max_x, l_max_y, l_max_z
					end
				end
			end
		end

		if
			(
				split_bin < 0 or
				best_cost >= count * surface_area(
					node.bounds_min[0],
					node.bounds_min[1],
					node.bounds_min[2],
					node.bounds_max[0],
					node.bounds_max[1],
					node.bounds_max[2]
				)
			)
			and
			not cfg.force_split
		then
			cfg.leaf_writer(node, first, count, node_index)
			return
		end

		local i = first
		local j = first + count - 1

		while i <= j do
			local t = order[i]
			local b = min(max(math.floor((centroids[t * 3 + axis] - origin) * scale), 0), BIN_COUNT - 1)

			if b < split_bin then
				i = i + 1
			else
				order[i] = order[j]
				order[j] = t
				j = j - 1
			end
		end

		local left_count = i - first
		-- a failed split falls back to a mid split, whose child bounds are
		-- not known from the bins
		local split_bounds = left_count > 0 and left_count < count

		if not split_bounds then left_count = math.floor(count / 2) end

		local left_index

		if cfg.allocator then
			left_index = range_alloc(cfg.allocator, 2)
			nodes = cfg.nodes
		else
			left_index = cfg.cursor[1]
			cfg.cursor[1] = left_index + 2
		end

		node = nodes[node_index]
		node.left_first = left_index
		node.count = 0

		if split_bounds then
			local left = nodes[left_index]
			left.bounds_min[0] = lb_min_x
			left.bounds_min[1] = lb_min_y
			left.bounds_min[2] = lb_min_z
			left.bounds_max[0] = lb_max_x
			left.bounds_max[1] = lb_max_y
			left.bounds_max[2] = lb_max_z
			local right = nodes[left_index + 1]
			local o = split_bin * 6
			right.bounds_min[0] = right_bounds[o + 0]
			right.bounds_min[1] = right_bounds[o + 1]
			right.bounds_min[2] = right_bounds[o + 2]
			right.bounds_max[0] = right_bounds[o + 3]
			right.bounds_max[1] = right_bounds[o + 4]
			right.bounds_max[2] = right_bounds[o + 5]
		end

		build_sah(cfg, left_index, first, left_count, depth + 1, split_bounds)
		build_sah(
			cfg,
			left_index + 1,
			first + left_count,
			count - left_count,
			depth + 1,
			split_bounds
		)
	end

	-- the top tree sits above the per-visual trees: its leaves are copies of
	-- visual root nodes, so traversal continues straight into that visual's
	-- tree (or its triangles, for a one leaf tree). node 0 is its root and
	-- every internal node's children are a pair from the node allocator.
	-- visuals are inserted and removed one at a time (the dynamic aabb tree
	-- scheme), with a fresh sah over all visuals when many change at once or
	-- enough changes have piled up to degrade it
	local function node_union_area(a, b)
		return surface_area(
			a.bounds_min[0] < b.bounds_min[0] and a.bounds_min[0] or b.bounds_min[0],
			a.bounds_min[1] < b.bounds_min[1] and a.bounds_min[1] or b.bounds_min[1],
			a.bounds_min[2] < b.bounds_min[2] and a.bounds_min[2] or b.bounds_min[2],
			a.bounds_max[0] > b.bounds_max[0] and a.bounds_max[0] or b.bounds_max[0],
			a.bounds_max[1] > b.bounds_max[1] and a.bounds_max[1] or b.bounds_max[1],
			a.bounds_max[2] > b.bounds_max[2] and a.bounds_max[2] or b.bounds_max[2]
		)
	end

	local function node_area(a)
		return surface_area(
			a.bounds_min[0],
			a.bounds_min[1],
			a.bounds_min[2],
			a.bounds_max[0],
			a.bounds_max[1],
			a.bounds_max[2]
		)
	end

	-- recomputes the bounds of index and every ancestor from their children
	local function refit_top(index)
		local nodes = scene_bvh.nodes
		local top_parent = scene_bvh.top_parent
		local top_leaf = scene_bvh.top_leaf

		while index do
			if not top_leaf[index] then
				local node = nodes[index]
				local a = nodes[node.left_first]
				local b = nodes[node.left_first + 1]
				node.bounds_min[0] = a.bounds_min[0] < b.bounds_min[0] and a.bounds_min[0] or b.bounds_min[0]
				node.bounds_min[1] = a.bounds_min[1] < b.bounds_min[1] and a.bounds_min[1] or b.bounds_min[1]
				node.bounds_min[2] = a.bounds_min[2] < b.bounds_min[2] and a.bounds_min[2] or b.bounds_min[2]
				node.bounds_max[0] = a.bounds_max[0] > b.bounds_max[0] and a.bounds_max[0] or b.bounds_max[0]
				node.bounds_max[1] = a.bounds_max[1] > b.bounds_max[1] and a.bounds_max[1] or b.bounds_max[1]
				node.bounds_max[2] = a.bounds_max[2] > b.bounds_max[2] and a.bounds_max[2] or b.bounds_max[2]
				write_node(index)
			end

			index = top_parent[index]
		end
	end

	local function set_top_empty()
		local root = scene_bvh.nodes[0]
		-- a count 0 node is an inner node, so the empty root must never be
		-- entered: a point further away than any ray reaches
		root.bounds_min[0] = -1e30
		root.bounds_min[1] = -1e30
		root.bounds_min[2] = -1e30
		root.bounds_max[0] = -1e30
		root.bounds_max[1] = -1e30
		root.bounds_max[2] = -1e30
		root.left_first = 0
		root.count = 0
		write_node(0)
	end

	-- moves the node at from (a top leaf or top internal node) into slot to
	local function move_top_node(from, to)
		local nodes = scene_bvh.nodes
		local top_leaf = scene_bvh.top_leaf
		ffi.copy(nodes + to, nodes + from, NODE_BYTE_SIZE)
		local vc = top_leaf[from]

		if vc then
			top_leaf[from] = nil
			top_leaf[to] = vc
			scene_bvh.top_leaf_block[from] = 0
			scene_bvh.top_leaf_block[to] = vc.block_index
			vc.top_slot = to
		else
			local left = nodes[to].left_first
			scene_bvh.top_parent[left] = to
			scene_bvh.top_parent[left + 1] = to
		end
	end

	local function insert_top_leaf(vc)
		local top_leaf = scene_bvh.top_leaf
		local top_parent = scene_bvh.top_parent
		scene_bvh.top_count = scene_bvh.top_count + 1

		if scene_bvh.top_count == 1 then
			ffi.copy(scene_bvh.nodes, scene_bvh.nodes + vc.block_base, NODE_BYTE_SIZE)
			top_leaf[0] = vc
			scene_bvh.top_leaf_block[0] = vc.block_index
			vc.top_slot = 0
			write_node(0)
			return
		end

		local pair = range_alloc(scene_bvh.node_allocator, 2)
		local nodes = scene_bvh.nodes
		local leaf = nodes[vc.block_base]
		local index = 0

		-- descend toward the sibling that grows the tree's surface area least
		while not top_leaf[index] do
			local node = nodes[index]
			local area = node_area(node)
			local combined = node_union_area(node, leaf)
			local cost = 2 * combined
			local inherit = 2 * (combined - area)
			local left = nodes[node.left_first]
			local right = nodes[node.left_first + 1]
			local cost_left = node_union_area(left, leaf) + inherit
			local cost_right = node_union_area(right, leaf) + inherit

			if not top_leaf[node.left_first] then cost_left = cost_left - node_area(left) end

			if not top_leaf[node.left_first + 1] then
				cost_right = cost_right - node_area(right)
			end

			if cost < cost_left and cost < cost_right then break end

			index = cost_left <= cost_right and node.left_first or node.left_first + 1
		end

		-- the sibling moves down into the new pair and its slot becomes the
		-- parent of both, so nothing above it has to be repointed
		move_top_node(index, pair)
		ffi.copy(nodes + pair + 1, leaf, NODE_BYTE_SIZE)
		top_leaf[pair + 1] = vc
		scene_bvh.top_leaf_block[pair + 1] = vc.block_index
		vc.top_slot = pair + 1
		top_parent[pair] = index
		top_parent[pair + 1] = index
		nodes[index].left_first = pair
		nodes[index].count = 0
		write_node(pair)
		write_node(pair + 1)
		refit_top(index)
	end

	local function remove_top_leaf(vc)
		local slot = vc.top_slot
		local top_parent = scene_bvh.top_parent
		scene_bvh.top_leaf[slot] = nil
		scene_bvh.top_leaf_block[slot] = 0
		vc.top_slot = nil
		scene_bvh.top_count = scene_bvh.top_count - 1

		if slot == 0 then
			set_top_empty()
			return
		end

		-- the sibling takes over the parent's slot and the pair is freed
		local parent = top_parent[slot]
		local pair = scene_bvh.nodes[parent].left_first
		move_top_node(slot == pair and pair + 1 or pair, parent)
		top_parent[pair] = nil
		top_parent[pair + 1] = nil
		range_free(scene_bvh.node_allocator, pair, 2)
		write_node(parent)
		refit_top(top_parent[parent])
	end

	local top_build = {}

	local function top_leaf_writer(node, first, count, node_index)
		-- first is a sah position; the item at that position is
		-- top_order[first] (sah reordered it in place), which is the
		-- block's 0-based index
		local vc = scene_bvh.blocks[top_build.order[first] + 1]
		ffi.copy(scene_bvh.nodes + node_index, scene_bvh.nodes + vc.block_base, NODE_BYTE_SIZE)
		scene_bvh.top_leaf[node_index] = vc
		scene_bvh.top_leaf_block[node_index] = vc.block_index
		vc.top_slot = node_index
	end

	local function rebuild_top()
		local allocator = scene_bvh.node_allocator
		local nodes = scene_bvh.nodes
		local top_leaf = scene_bvh.top_leaf
		local blocks = scene_bvh.blocks
		local n = #blocks

		-- free the old internal pairs
		if scene_bvh.top_count >= 2 then
			local stack = {0}

			while stack[1] do
				local index = stack[#stack]
				stack[#stack] = nil

				if not top_leaf[index] then
					local left = nodes[index].left_first
					range_free(allocator, left, 2)
					stack[#stack + 1] = left
					stack[#stack + 1] = left + 1
				end
			end
		end

		scene_bvh.top_parent = {}

		for index in pairs(scene_bvh.top_leaf) do
			scene_bvh.top_leaf_block[index] = 0
		end

		scene_bvh.top_leaf = {}
		scene_bvh.top_count = n
		scene_bvh.top_changes = 0
		scene_bvh.top_incremental_count = 0

		if n == 0 then
			set_top_empty()
			return
		end

		-- the sah allocates up to n - 1 pairs, and must not see the node
		-- mirror move under it
		if allocator.top + n * 2 > allocator.capacity then
			grow_nodes(allocator.top + n * 2)
		end

		get_scratch(1, n)
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

		top_build.order = top_order
		top_build.centroids = top_centroids
		top_build.bounds = top_bounds
		top_build.nodes = scene_bvh.nodes
		top_build.allocator = allocator
		top_build.leaf_size = 1
		top_build.force_split = true
		top_build.leaf_writer = top_leaf_writer
		build_sah(top_build, 0, 0, n, 0)
		-- parents, and the new top nodes to the gpu
		nodes = scene_bvh.nodes
		top_leaf = scene_bvh.top_leaf
		local top_parent = scene_bvh.top_parent
		local stack = {0}

		while stack[1] do
			local index = stack[#stack]
			stack[#stack] = nil
			write_node(index)

			if not top_leaf[index] then
				local left = nodes[index].left_first
				top_parent[left] = index
				top_parent[left + 1] = index
				stack[#stack + 1] = left
				stack[#stack + 1] = left + 1
			end
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

	-- transforms a slot's mesh vertices by the piece's local matrix into
	-- piece.local_tris. degenerate triangles are dropped, so the returned
	-- count can be smaller than slot.count
	local function build_slot_local(slot, piece)
		local count = slot.count
		local tris = piece.local_tris
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

		local m = piece.matrix
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

	-- a mesh's triangles under one entry-local matrix. every visual drawing
	-- that mesh the same way (instances of a model) shares it. keyed by the
	-- vertex data and the index buffer, then matched by matrix. held by the
	-- slots and shapes using it, so an unused piece is collected
	local pieces = setmetatable({}, {__mode = "k"})
	local piece_id = 0

	local function get_piece(slot, l)
		local by_index = pieces[slot.vertex_buffer.data]

		if not by_index then
			by_index = setmetatable({}, {__mode = "k"})
			pieces[slot.vertex_buffer.data] = by_index
		end

		local index_key = slot.index_buffer or false
		local list = by_index[index_key]

		if not list then
			list = setmetatable({}, {__mode = "v"})
			by_index[index_key] = list
		end

		for _, piece in pairs(list) do
			if piece.raw_count == slot.count and matrix_equal(piece.matrix, l) then
				return piece
			end
		end

		if not scratch.indices_capacity or scratch.indices_capacity < slot.count * 3 then
			scratch.indices_capacity = math.max(slot.count * 3, 1)
			scratch.indices = UInt32Array(scratch.indices_capacity)
		end

		piece_id = piece_id + 1
		local piece = {
			id = piece_id,
			raw_count = slot.count,
			local_tris = TriangleArray(slot.count),
			matrix = {
				m00 = l.m00,
				m01 = l.m01,
				m02 = l.m02,
				m03 = l.m03,
				m10 = l.m10,
				m11 = l.m11,
				m12 = l.m12,
				m13 = l.m13,
				m20 = l.m20,
				m21 = l.m21,
				m22 = l.m22,
				m23 = l.m23,
				m30 = l.m30,
				m31 = l.m31,
				m32 = l.m32,
				m33 = l.m33,
			},
		}
		piece.count = build_slot_local(slot, piece)
		list[piece_id] = piece
		return piece
	end

	-- per-tri aabbs and centroids of a shape's local soup, for the child SAH
	local function prepare_child_sah(shape)
		local pieces = shape.pieces
		local starts = shape.starts
		local slot_of = shape.slot_of
		local tri_bounds = scratch.tri_bounds
		local tri_centroids = scratch.tri_centroids

		for i = 0, shape.total - 1 do
			local s = slot_of[i] + 1
			local tri = pieces[s].local_tris[i - starts[s]]
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

	local function child_leaf_writer(node, first, count)
		node.left_first = first
		node.count = count
	end

	local child_build = {
		cursor = {1},
		leaf_size = MAX_LEAF_TRIANGLES,
		leaf_writer = child_leaf_writer,
	}
	-- a visual's local soup (its pieces in slot order) with the local child
	-- tree over it, shared by every visual made of the same pieces. held by
	-- the visuals using it
	local shapes = setmetatable({}, {__mode = "v"})
	local shape_key = {}

	local function get_shape(slots, slot_count)
		for i = 1, slot_count do
			shape_key[i] = slots[i].piece.id
		end

		local key = table.concat(shape_key, ",", 1, slot_count)
		local shape = shapes[key]

		if shape then return shape end

		local total = 0

		for i = 1, slot_count do
			total = total + slots[i].piece.count
		end

		if total == 0 then return nil end

		shape = {
			total = total,
			pieces = {},
			starts = {},
			order = UInt32Array(total),
			slot_of = UInt32Array(total),
		}
		local span = 0

		for i = 1, slot_count do
			local piece = slots[i].piece
			shape.pieces[i] = piece
			shape.starts[i] = span

			for t = span, span + piece.count - 1 do
				shape.slot_of[t] = i - 1
			end

			span = span + piece.count
		end

		for i = 0, total - 1 do
			shape.order[i] = i
		end

		get_scratch(total, 1)

		if not scratch.child_nodes_capacity or scratch.child_nodes_capacity < total * 2 then
			scratch.child_nodes_capacity = total * 2
			scratch.child_nodes = NodeArray(total * 2)
		end

		prepare_child_sah(shape)
		child_build.order = shape.order
		child_build.centroids = scratch.tri_centroids
		child_build.bounds = scratch.tri_bounds
		child_build.nodes = scratch.child_nodes
		child_build.cursor[1] = 1
		build_sah(child_build, 0, 0, total, 0)
		shape.node_count = child_build.cursor[1]
		shape.nodes = NodeArray(shape.node_count)
		ffi.copy(shape.nodes, scratch.child_nodes, shape.node_count * NODE_BYTE_SIZE)
		shapes[key] = shape
		return shape
	end

	-- writes a block's shape into its soup range in SAH order, transformed by
	-- its world matrix and with its slots' materials
	function bake_triangles(vc)
		local shape = vc.shape
		local total = shape.total
		local order = shape.order
		local slot_of = shape.slot_of
		local pieces = shape.pieces
		local starts = shape.starts
		local slots = vc.slots
		local world = scene_bvh.triangles + vc.tri_base
		local v = vc.baked_matrix
		local m00, m01, m02 = v.m00, v.m01, v.m02
		local m10, m11, m12 = v.m10, v.m11, v.m12
		local m20, m21, m22 = v.m20, v.m21, v.m22
		local m30, m31, m32 = v.m30, v.m31, v.m32

		for i = 0, total - 1 do
			local l = order[i]
			local s = slot_of[l] + 1
			local slot = slots[s]
			local src = pieces[s].local_tris[l - starts[s]]
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
			local nx = e1y * e2z - e1z * e2y
			local ny = e1z * e2x - e1x * e2z
			local nz = e1x * e2y - e1y * e2x
			local length = math.sqrt(nx * nx + ny * ny + nz * nz)
			dst.normal[0] = nx / length
			dst.normal[1] = ny / length
			dst.normal[2] = nz / length
			dst.emissive[0] = slot.emissive_r
			dst.emissive[1] = slot.emissive_g
			dst.emissive[2] = slot.emissive_b
			dst.material = slot.material_id
		end

		ffi.fill(world + total, (vc.tri_cap - total) * TRIANGLE_BYTE_SIZE)

		if not vc.emissive then
			vc.emitter_count = 0
			return
		end

		-- the soup is write combined memory, so the emitters are gathered here
		-- rather than read back from it
		local count = 0

		if not vc.emitters or vc.emitter_capacity < total then
			vc.emitters = EmitterArray(total)
			vc.emitter_capacity = total
		end

		local emitters = vc.emitters

		for i = 0, total - 1 do
			local l = order[i]
			local s = slot_of[l] + 1
			local slot = slots[s]
			local luminance = 0.2126 * slot.emissive_r + 0.7152 * slot.emissive_g + 0.0722 * slot.emissive_b

			if luminance > 0 then
				local src = pieces[s].local_tris[l - starts[s]]
				local e1x = src.e1[0] * m00 + src.e1[1] * m10 + src.e1[2] * m20
				local e1y = src.e1[0] * m01 + src.e1[1] * m11 + src.e1[2] * m21
				local e1z = src.e1[0] * m02 + src.e1[1] * m12 + src.e1[2] * m22
				local e2x = src.e2[0] * m00 + src.e2[1] * m10 + src.e2[2] * m20
				local e2y = src.e2[0] * m01 + src.e2[1] * m11 + src.e2[2] * m21
				local e2z = src.e2[0] * m02 + src.e2[1] * m12 + src.e2[2] * m22
				local nx = e1y * e2z - e1z * e2y
				local ny = e1z * e2x - e1x * e2z
				local nz = e1x * e2y - e1y * e2x
				emitters[count].triangle = scene_bvh.materials[slot.material_id + 1]:GetDoubleSided() and
					i + 0x80000000 or
					i
				emitters[count].power = 0.5 * math.sqrt(nx * nx + ny * ny + nz * nz) * luminance
				count = count + 1
			end
		end

		vc.emitter_count = count
	end

	-- bakes a block into its ranges: the triangles, plus the child node bounds
	-- in world space with internal children remapped to the block's global
	-- base
	local function write_block(vc)
		local v = vc.matrix
		local shape = vc.shape
		local block_base = vc.block_base
		local tri_base = vc.tri_base
		vc.baked_matrix = v
		bake_triangles(vc)
		local local_nodes = shape.nodes
		local world_nodes = scene_bvh.nodes + block_base

		for j = 0, shape.node_count - 1 do
			local ln = local_nodes[j]
			local wn = world_nodes[j]
			wn.count = ln.count

			if wn.count == 0 then
				wn.left_first = block_base + ln.left_first
			else
				wn.left_first = tri_base + ln.left_first
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

		ffi.copy(scene_bvh.node_ptr + block_base, world_nodes, shape.node_count * NODE_BYTE_SIZE)
		transform_box(v, ffi.cast("float*", local_nodes[0].bounds_min), vc.world_aabb)
		-- tri_base/total are soup triangle indices, x3 for the
		-- one-position-per-vertex layout of the expanded soup
		vc.first_vertex = tri_base * 3
		vc.vertex_count = shape.total * 3
		write_raster_block(vc)
	end

	-- frees a visual's ranges and takes it out of the tree
	local function release_block(visual, vc, rebuilding_top)
		scene_bvh.visual_cache[visual] = nil

		if not vc.block_index then return end

		free_soup_range(vc.tri_base, vc.tri_cap)
		range_free(scene_bvh.node_allocator, vc.block_base, vc.node_cap)
		vc.tri_base = nil
		vc.block_base = nil
		scene_bvh.triangle_count = scene_bvh.triangle_count - vc.drawn_total
		scene_bvh.soup_dirty = true
		local blocks = scene_bvh.blocks
		local last = blocks[#blocks]
		blocks[vc.block_index] = last
		last.block_index = vc.block_index

		if last.top_slot then
			scene_bvh.top_leaf_block[last.top_slot] = last.block_index
		end

		blocks[#blocks] = nil
		vc.block_index = nil

		if last ~= vc then write_raster_block(last) end

		if scene_bvh.changed_blocks then
			scene_bvh.changed_blocks[vc] = true
			scene_bvh.changed_blocks[last] = true
		end

		if scene_bvh.emissive_set[vc] then
			scene_bvh.emissive_set[vc] = nil
			scene_bvh.emissive_changed = true
		end

		if vc.top_slot and not rebuilding_top then
			remove_top_leaf(vc)
			scene_bvh.top_changes = scene_bvh.top_changes + 1
		end
	end

	-- brings one visual's block up to date. the local soup and child tree are
	-- only rederived when its entries changed, the world bake only when it
	-- moved, and the ranges are kept whenever the block still fits
	local function update_visual(visual, stamp, inserts)
		local cache = scene_bvh.visual_cache
		local vc = cache[visual]

		if not visual:IsValid() or visual.scene_removed then
			if vc then release_block(visual, vc, inserts.rebuild) end

			return
		end

		local v = visual.Owner.transform:GetWorldMatrix()
		local slot_count = 0
		local slots = {}
		local fast = vc ~= nil and vc.matrix == v

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

					if material:GetAlbedoAlphaIsEmissive() or material:GetEmissiveTexture() ~= nil then
						local multiplier = material:GetEmissiveMultiplier()
						emissive_r = multiplier.r * multiplier.a
						emissive_g = multiplier.g * multiplier.a
						emissive_b = multiplier.b * multiplier.a
					end

					local material_id = scene_bvh.GetMaterialID(material)
					local e = entry.transform:GetWorldMatrix()
					local prev = vc and vc.slots[slot_count + 1]
					local slot = prev and
						prev.entry == entry and
						prev.count == count and
						prev.matrix == e and
						prev.material_id == material_id and
						prev.emissive_r == emissive_r and
						prev.emissive_g == emissive_g and
						prev.emissive_b == emissive_b and
						prev

					if not slot then
						fast = false
						slot = prev and
							prev.entry == entry and
							prev.count == count and
							prev or
							{
								entry = entry,
								index_buffer = index_buffer,
								vertex_buffer = mesh.vertex_buffer,
								count = count,
							}
						slot.matrix = e
					end

					slot.emissive_r = emissive_r
					slot.emissive_g = emissive_g
					slot.emissive_b = emissive_b
					slot.material_id = material_id
					slot_count = slot_count + 1
					slots[slot_count] = slot
				end
			end
		end

		if vc and slot_count ~= vc.slot_count then fast = false end

		if slot_count == 0 then
			if vc then release_block(visual, vc, inserts.rebuild) end

			return
		end

		vc = vc or {}
		cache[visual] = vc
		vc.stamp = stamp

		if fast and vc.block_index and vc.baked_matrix == v then return end

		local shape = vc.shape

		if not fast then
			local v_inv = v:GetInverse(tmp_v_inv)

			for i = 1, slot_count do
				local slot = slots[i]
				local l = slot.matrix:GetMultiplied(v_inv, tmp_l)

				if not (slot.piece and matrix_equal(slot.piece.matrix, l)) then
					slot.piece = get_piece(slot, l)
				end
			end

			shape = get_shape(slots, slot_count)

			if not shape then
				release_block(visual, vc, inserts.rebuild)
				return
			end
		end

		vc.matrix = v
		vc.slots = slots
		vc.slot_count = slot_count
		vc.shape = shape
		vc.total = shape.total
		vc.node_count = shape.node_count
		vc.alpha_tested = false

		for i = 1, slot_count do
			if scene_bvh.materials[slots[i].material_id + 1]:GetAlphaTest() then
				vc.alpha_tested = true

				break
			end
		end

		local emissive = false

		for i = 1, slot_count do
			local slot = slots[i]

			if slot.piece.count > 0 and slot.emissive_r + slot.emissive_g + slot.emissive_b > 0 then
				emissive = true
			end
		end

		if not vc.world_aabb then vc.world_aabb = FloatArray(6) end

		-- not baked until it is written below, so a soup grown while its
		-- ranges move leaves it out
		vc.baked_matrix = nil

		-- ranges: keep them while the block fits and is not much smaller
		if vc.block_index then
			scene_bvh.triangle_count = scene_bvh.triangle_count - vc.drawn_total

			if vc.tri_cap < vc.total or range_class(vc.total, SOUP_ALIGN) * 2 <= vc.tri_cap then
				free_soup_range(vc.tri_base, vc.tri_cap)
				vc.tri_base, vc.tri_cap = range_alloc(scene_bvh.triangle_allocator, vc.total)
			end

			if vc.node_cap < vc.node_count or range_class(vc.node_count, 1) * 2 <= vc.node_cap then
				range_free(scene_bvh.node_allocator, vc.block_base, vc.node_cap)
				vc.block_base, vc.node_cap = range_alloc(scene_bvh.node_allocator, vc.node_count)
			end
		else
			vc.tri_base, vc.tri_cap = range_alloc(scene_bvh.triangle_allocator, vc.total)
			vc.block_base, vc.node_cap = range_alloc(scene_bvh.node_allocator, vc.node_count)
			local blocks = scene_bvh.blocks
			blocks[#blocks + 1] = vc
			vc.block_index = #blocks
		end

		vc.drawn_total = vc.total
		scene_bvh.triangle_count = scene_bvh.triangle_count + vc.total
		log_soup_range(vc.tri_base, vc.tri_cap)
		-- the ray tracing blas of this block follows this
		vc.soup_serial = (vc.soup_serial or 0) + 1
		scene_bvh.soup_dirty = true

		if scene_bvh.changed_blocks then scene_bvh.changed_blocks[vc] = true end

		if (scene_bvh.emissive_set[vc] or false) ~= emissive then
			scene_bvh.emissive_set[vc] = emissive or nil
			scene_bvh.emissive_changed = true
		end

		vc.emissive = emissive

		if emissive then scene_bvh.emissive_changed = true end

		if inserts.rebuild then return end

		write_block(vc)

		if vc.top_slot then
			ffi.copy(scene_bvh.nodes + vc.top_slot, scene_bvh.nodes + vc.block_base, NODE_BYTE_SIZE)
			write_node(vc.top_slot)
			refit_top(scene_bvh.top_parent[vc.top_slot])
		else
			inserts[#inserts + 1] = vc
		end
	end

	scene_bvh.emissive_set = {}
	-- blocks that were written, moved in the block list or released since the
	-- ray tracing backend last looked. nil until it first does
	scene_bvh.changed_blocks = nil
	scene_bvh.top_incremental_count = 0
	-- seconds an incremental build may spend per frame
	scene_bvh.BUILD_BUDGET = 0.004
	scene_bvh.build_backlog = false
	local build_stamp = 0

	-- the allocators' grow while a reset lays blocks out: only the capacity
	-- moves, the buffers are grown once the layout is done
	local function defer_grow(needed, allocator)
		allocator.capacity = needed
	end

	-- mode "incremental" looks only at scene_bvh.dirty_components, "scan" at
	-- every visual (anything whose matrix or entries changed is rebuilt) and
	-- "reset" throws the layout away and lays every visual out again
	local function build(mode)
		local start_time = os.clock()
		build_stamp = build_stamp + 1
		local inserts = {}

		if mode == "reset" or not scene_bvh.node_allocator then
			mode = "reset"
			reset_layout()
		end

		inserts.rebuild = mode == "reset"
		scene_bvh.soup_dirty = mode == "reset"

		-- a reset lays every block out before writing any of them, so the
		-- buffers grow once to their final size instead of being refilled
		-- over and over while the soup grows
		if inserts.rebuild then
			scene_bvh.triangle_allocator.grow = defer_grow
			scene_bvh.node_allocator.grow = defer_grow
		end

		if mode == "incremental" then
			-- what does not fit in the budget waits for the next frame
			local dirty = scene_bvh.dirty_components
			local deadline = start_time + scene_bvh.BUILD_BUDGET

			for visual in pairs(dirty) do
				update_visual(visual, build_stamp, inserts)
				dirty[visual] = nil

				if os.clock() > deadline then break end
			end

			scene_bvh.build_backlog = next(dirty) ~= nil
		else
			scene_bvh.dirty_components = {}
			scene_bvh.build_backlog = false

			for _, visual in ipairs(Visual.Instances) do
				update_visual(visual, build_stamp, inserts)
			end

			for visual, vc in pairs(scene_bvh.visual_cache) do
				if vc.stamp ~= build_stamp then release_block(visual, vc, inserts.rebuild) end
			end
		end

		if inserts.rebuild then
			scene_bvh.triangle_allocator.grow = grow_triangles
			scene_bvh.node_allocator.grow = grow_nodes

			if scene_bvh.triangle_allocator.top > scene_bvh.triangle_capacity then
				grow_triangles(scene_bvh.triangle_allocator.top)
			end

			if scene_bvh.node_allocator.top > scene_bvh.node_capacity then
				grow_nodes(scene_bvh.node_allocator.top)
			end

			for _, vc in ipairs(scene_bvh.blocks) do
				write_block(vc)
			end
		end

		-- many new visuals at once get a fresh sah, which is both better and
		-- cheaper than inserting them one by one, and so does a tree that has
		-- seen as many changes as it has leaves
		scene_bvh.top_changes = scene_bvh.top_changes + #inserts

		if
			inserts.rebuild or
			#inserts > math.max(64, scene_bvh.top_count / 4)
			or
			scene_bvh.top_changes > math.max(1024, scene_bvh.top_count)
		then
			rebuild_top()
		else
			for i = 1, #inserts do
				insert_top_leaf(inserts[i])
			end

			scene_bvh.top_incremental_count = scene_bvh.top_incremental_count + 1
		end

		if scene_bvh.emissive_changed then
			local emissive_blocks = {}

			for vc in pairs(scene_bvh.emissive_set) do
				emissive_blocks[#emissive_blocks + 1] = vc
			end

			scene_bvh.emissive_blocks = emissive_blocks
			scene_bvh.emissive_changed = false
		end

		scene_bvh.debug_node_count = scene_bvh.node_allocator.top
		scene_bvh.node_count = scene_bvh.node_allocator.top
		scene_bvh.soup_triangle_count = scene_bvh.triangle_allocator.top
		scene_bvh.build_time = os.clock() - start_time
		scene_bvh.has_built = true
		scene_bvh.version = scene_bvh.version + 1
		scene_bvh.soup_log_sealed = #scene_bvh.soup_log

		if scene_bvh.soup_dirty then
			scene_bvh.soup_version = scene_bvh.soup_version + 1
		end

		if scene_bvh.triangle_count > 0 and not scene_bvh.readied then
			event.Call("BVHSceneReady")
			scene_bvh.readied = true
		end
	end

	scene_bvh.BuildIncremental = build

	-- brings the tree up to date with every visual. force_full also lays the
	-- soup out from scratch and rebuilds the top tree with a fresh sah
	function scene_bvh.Build(force_full)
		build(force_full and "reset" or "scan")
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

	-- a new emission or material on a material only rewrites the world bake
	-- of the visuals using it
	if next(Material.emission_dirty_materials) then
		local users = library.GetSceneMaterialUsers()

		for material in pairs(Material.emission_dirty_materials) do
			for component in pairs(users[material] or {}) do
				scene_bvh.Invalidate(component)
			end
		end

		table.clear(Material.emission_dirty_materials)
	end

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

	local settled = (scene_bvh.last_change_frame or 0) < frame - 1 or scene_bvh.build_backlog
	local max_wait = math.max(0.02, scene_bvh.build_time * 20)

	if not scene_bvh.has_built then
		local quiet_since = scene_bvh.last_change_time or scene_bvh.dirty_since

		if
			(
				not quiet_since or
				now - quiet_since < 5.0
			)
			and
			now - scene_bvh.dirty_since < 10.0
		then
			return
		end
	elseif not settled and (now - scene_bvh.dirty_since) < max_wait then
		return
	end

	scene_bvh.dirty_since = nil
	scene_bvh.BuildIncremental(scene_bvh.dirty_components and "incremental" or "scan")

	if scene_bvh.build_backlog then scene_bvh.dirty_since = now end
end

function scene_bvh.Invalidate(component)
	Visual.Library.ForgetWorldAABB(component)

	if scene_bvh.dirty_components then
		scene_bvh.dirty_components[component] = true
	end

	-- keep the first change time so the wait window is not slid by every
	-- subsequent transform change
	if not scene_bvh.dirty_since then
		scene_bvh.dirty_since = system.GetElapsedTime()
	end

	scene_bvh.last_change_frame = -1
	scene_bvh.version = scene_bvh.version + 1
end

-- binds a buffer as the SOUP_CHUNKS descriptors of the soup binding, each
-- covering its 2 GiB of the buffer. a chunk past the end of the buffer points
-- at its start (it is never indexed), which also lets a stand-in buffer fill
-- the binding before there is a soup
do
	local chunk_infos = setmetatable({}, {__mode = "k"})

	function scene_bvh.BindTriangleBuffer(pipeline, descriptor_index, binding, buffer)
		local infos = chunk_infos[buffer]

		if not infos then
			local size = buffer:GetSize()
			infos = {}

			for i = 0, SOUP_CHUNKS - 1 do
				local offset = i * SOUP_CHUNK_BYTES

				if offset >= size then offset = 0 end

				infos[i + 1] = {
					buffer = buffer,
					offset = offset,
					range = math.min(SOUP_CHUNK_BYTES, size - offset),
				}
			end

			chunk_infos[buffer] = infos
		end

		pipeline:UpdateStorageBufferArray(descriptor_index, binding, 0, infos, SOUP_CHUNKS)
	end
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
	scene_bvh.BindTriangleBuffer(pipeline, descriptor_index, triangle_binding, scene_bvh.triangle_buffer)
end

-- the triangle soup alone, for shaders that only look up hits (by the ray
-- query's primitive index, which is the soup index)
function scene_bvh.GetTriangleDeclarationGLSL(triangle_binding)
	return (
		[[
		struct scene_bvh_triangle {
			vec3 v0;
			vec3 e1;
			vec3 e2;
			vec3 normal;
			vec3 emissive;
			uint material;
		};

		layout(scalar, set = 0, binding = %d) readonly buffer SceneBVHTriangleBuffer {
			scene_bvh_triangle triangles[];
		} scene_bvh_soup[%d];

		#define SCENE_BVH_SOUP_CHUNK %du
		scene_bvh_triangle bvh_tri(uint index) {
			uint chunk = index / SCENE_BVH_SOUP_CHUNK;
			return scene_bvh_soup[nonuniformEXT(chunk)].triangles[index - chunk * SCENE_BVH_SOUP_CHUNK];
		}
	]]
	):format(triangle_binding, SOUP_CHUNKS, SOUP_CHUNK_TRIS)
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

		layout(scalar, set = 0, binding = %d) readonly buffer SceneBVHNodeBuffer {
			scene_bvh_node scene_bvh_nodes[];
		};
	]]
		):format(node_binding) .. scene_bvh.GetTriangleDeclarationGLSL(triangle_binding)
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
			// index into scene_bvh_triangles
			uint triangle;
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

		// the closest triangle hit between t_min and t_max and its distance, or
		// -1. any_hit returns the first hit found instead, for shadow rays
		int scene_bvh_intersect(vec3 origin, vec3 dir, float t_min, float t_max, bool any_hit, out float closest) {
			vec3 inv_dir = 1.0 / mix(dir, vec3(1e-20), lessThan(abs(dir), vec3(1e-20)));
			closest = t_max;

			if (scene_bvh_slab(0u, origin, inv_dir, t_min, t_max) >= SCENE_BVH_MISS) {
				return -1;
			}

			uint stack[SCENE_BVH_STACK_SIZE];
			int stack_size = 0;
			uint node_index = 0u;
			int closest_triangle = -1;

			while (true) {
				scene_bvh_node node = scene_bvh_nodes[node_index];
				uint count = node.count;

				if (count > 0u) {
					uint first = node.left_first;

					for (uint i = 0u; i < count; i++) {
						scene_bvh_triangle tri = bvh_tri(first + i);
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

							if (any_hit) return closest_triangle;
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

			return closest_triangle;
		}

		bool scene_bvh_trace(vec3 origin, vec3 dir, float t_min, float t_max, out scene_bvh_hit hit) {
			float closest;
			int triangle = scene_bvh_intersect(origin, dir, t_min, t_max, false, closest);

			if (triangle < 0) return false;

			scene_bvh_triangle final_triangle = bvh_tri(triangle);
			hit.position = origin + dir * closest;
			hit.distance = closest;
			hit.emissive = final_triangle.emissive;
			hit.normal = dot(final_triangle.normal, dir) > 0.0 ? -final_triangle.normal : final_triangle.normal;
			hit.triangle = uint(triangle);
			return true;
		}

		bool scene_bvh_occluded(vec3 origin, vec3 dir, float t_min, float t_max) {
			float closest;
			return scene_bvh_intersect(origin, dir, t_min, t_max, true, closest) >= 0;
		}
	]]
end

commands.Add("scene_bvh_rebuild", function()
	scene_bvh.Build()
end)

commands.Add("scene_bvh_info", function()
	logf(
		"[scene_bvh] %d triangles, %d nodes, built in %.2fs, top incremental %d, version %d, dirty %s, light_version %d\n",
		scene_bvh.triangle_count,
		scene_bvh.node_count,
		scene_bvh.build_time,
		scene_bvh.top_incremental_count,
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
	local expand_first = 0
	local expand_count = 0

	local function ensure_expand_pipeline(state)
		if state.expand_pipeline then return state.expand_pipeline end

		state.expand_pipeline = EasyPipeline.Compute{
			name = "scene_bvh_expand_positions",
			dont_create_framebuffers = true,
			-- one per frame in flight: a rebuild on the next frame mustn't
			-- rewrite the set a pending command buffer still uses
			DescriptorSetCount = render.GetSwapchainImageCount(),
			LocalSize = {EXPAND_LOCAL_SIZE, 1, 1},
			storage_buffers = {{binding_index = 0}, {binding_index = 1, count = SOUP_CHUNKS}},
			block = {
				{"first_vertex", "int"},
				{"vertex_count", "int"},
				write = function(self, block)
					block.first_vertex = expand_first
					block.vertex_count = expand_count
					return block
				end,
			},
			custom_declarations = ([=[
					struct scene_bvh_triangle {
						vec3 v0;
						vec3 e1;
						vec3 e2;
						vec3 normal;
						vec3 emissive;
						uint material;
					};
					layout(scalar, set = 0, binding = 1) readonly buffer SceneBvhTri {
						scene_bvh_triangle tris[];
					} soup[%d];
					layout(scalar, set = 0, binding = 0) buffer SceneBvhPos {
						vec3 positions[];
					};
					]=]):format(SOUP_CHUNKS),
			shader = [[
				#define SOUP_CHUNK ]] .. SOUP_CHUNK_TRIS .. [[u
				void main() {
					uint index = gl_GlobalInvocationID.x;
					if (index >= uint(compute.vertex_count)) return;
					uint vid = uint(compute.first_vertex) + index;
					uint tri = vid / 3u;
					uint chunk = tri / SOUP_CHUNK;
					scene_bvh_triangle t = soup[nonuniformEXT(chunk)].tris[tri - chunk * SOUP_CHUNK];
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

	local function expand_range(cmd, pipeline, slot, first_vertex, vertex_count)
		expand_first = first_vertex
		expand_count = vertex_count
		pipeline:Dispatch(cmd, math.ceil(vertex_count / EXPAND_LOCAL_SIZE), 1, 1, slot)
	end

	-- expands the soup into one position per vertex in state.position_buffer,
	-- for rasterizing it or building acceleration structures from it. only the
	-- ranges written since the state's last call are expanded, unless its
	-- buffer is new or the soup was laid out again. returns the vertex count
	-- the buffer covers and the buffer
	function scene_bvh.ExpandPositions(cmd, state)
		if not scene_bvh.IsReady() then return 0, nil end

		local vertex_count = scene_bvh.soup_triangle_count * 3
		local log = scene_bvh.soup_log
		local log_base = scene_bvh.soup_log_base
		local full = state.generation ~= scene_bvh.soup_generation or
			(
				state.log_position or
				-1
			) < log_base

		if not state.position_buffer or state.position_buffer:GetSize() < vertex_count * 12 then
			if state.position_buffer then state.position_buffer:Remove() end

			state.position_buffer = render.CreateBuffer{
				byte_size = math.ceil(vertex_count * 1.25) * 12,
				buffer_usage = state.buffer_usage or {"vertex_buffer", "storage_buffer"},
				memory_property = {"device_local"},
				label = "scene_bvh_raster_positions",
			}
			full = true
		end

		local position_buffer = state.position_buffer
		local pipeline = ensure_expand_pipeline(state)
		local slot = math.max(render.GetCurrentFrame(), 1)
		scene_bvh.BindTriangleBuffer(pipeline, slot, 1, scene_bvh.triangle_buffer)
		pipeline:UpdateDescriptorSet("storage_buffer", slot, 0, 0, position_buffer, position_buffer:GetSize())

		if full then
			expand_range(cmd, pipeline, slot, 0, vertex_count)
		else
			for i = state.log_position - log_base + 1, #log, 2 do
				expand_range(cmd, pipeline, slot, log[i] * 3, log[i + 1] * 3)
			end
		end

		state.generation = scene_bvh.soup_generation
		state.log_position = log_base + #log
		return vertex_count, position_buffer
	end

	-- Hardware ray tracing backend over the same soup: one BLAS per visual,
	-- built from its range of the expanded positions (non-indexed, in world
	-- space), and a TLAS with an identity instance per visual whose custom
	-- index is the visual's soup range start / SOUP_ALIGN, so a hit's soup
	-- triangle index is custom index * SOUP_ALIGN + primitive index. A changed
	-- visual only rebuilds its own BLAS and the TLAS.
	local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
	local AccelerationStructure = import("goluwa/render/vulkan/internal/acceleration_structure.lua")
	local VkRangeInfoArray = ffi.typeof("$[?]", vulkan.vk.VkAccelerationStructureBuildRangeInfoKHR)
	local VkRangePointerArray = ffi.typeof("const $*[?]", vulkan.vk.VkAccelerationStructureBuildRangeInfoKHR)
	local VkGeometryArray = ffi.typeof("$[?]", vulkan.vk.VkAccelerationStructureGeometryKHR)
	local VkBuildInfoArray = ffi.typeof("$[?]", vulkan.vk.VkAccelerationStructureBuildGeometryInfoKHR)
	local VkInstanceArray = ffi.typeof("$[?]", vulkan.vk.VkAccelerationStructureInstanceKHR)
	local VkInstancePtr = ffi.typeof("$*", vulkan.vk.VkAccelerationStructureInstanceKHR)
	local INSTANCE_BYTE_SIZE = ffi.sizeof(vulkan.vk.VkAccelerationStructureInstanceKHR)
	local VK_GEOMETRY_TYPE_TRIANGLES = 0
	local VK_GEOMETRY_TYPE_INSTANCES = 2
	local VK_INDEX_TYPE_NONE = 1000165000
	local BUILD_PREFER_FAST_TRACE = 4
	local INSTANCE_FACING_CULL_DISABLE = 0x01000000
	-- the soup has no uvs to alpha test a hit with, so alpha tested visuals are
	-- non-opaque and rays that can do without them cull them
	local INSTANCE_FORCE_OPAQUE = 0x04000000
	local INSTANCE_FORCE_NO_OPAQUE = 0x08000000
	local BLAS_ALIGN = 256
	local BLAS_POOL_BYTES = 64 * 1024 * 1024
	local SCRATCH_BUDGET = 128 * 1024 * 1024
	local TLAS_SLOT_COUNT = 4
	local rt_state = {
		buffer_usage = {
			"vertex_buffer",
			"storage_buffer",
			"shader_device_address",
			"acceleration_structure_build_input_read_only_khr",
		},
		built_version = -1,
		-- blas storage comes from big shared buffers, split into ranges of
		-- BLAS_ALIGN units
		pools = {},
		-- cpu copy of the tlas instances, copied into the tlas slot on a
		-- rebuild
		instances = nil,
		instance_capacity = 0,
		-- blas storage waits a few frames before reuse, since frames in
		-- flight may still trace the old one
		pending_free = {},
		tlas_slots = {},
	}

	local function pool_alloc(size)
		local units = range_class(math.ceil(size / BLAS_ALIGN), 1)

		for _, pool in ipairs(rt_state.pools) do
			local list = pool.free[units]

			if list and list[1] then
				local offset = list[#list]
				list[#list] = nil
				return pool, offset, units
			end

			if pool.top + units <= pool.capacity then
				local offset = pool.top
				pool.top = pool.top + units
				return pool, offset, units
			end
		end

		local capacity = math.max(math.ceil(BLAS_POOL_BYTES / BLAS_ALIGN), units)
		local pool = {
			buffer = render.CreateBuffer{
				byte_size = capacity * BLAS_ALIGN,
				buffer_usage = {"acceleration_structure_storage_khr", "shader_device_address"},
				memory_property = {"device_local"},
				label = "scene_bvh_blas_pool",
			},
			capacity = capacity,
			top = units,
			free = {},
		}
		rt_state.pools[#rt_state.pools + 1] = pool
		return pool, 0, units
	end

	local function release_blas(vc, frame)
		local list = rt_state.pending_free
		list[#list + 1] = {
			frame = frame,
			pool = vc.rt_pool,
			offset = vc.rt_offset,
			units = vc.rt_units,
			blas = vc.rt_blas,
		}
		vc.rt_blas = nil
		vc.rt_pool = nil
		vc.rt_serial = nil
	end

	local function process_pending_free(frame)
		local list = rt_state.pending_free
		local keep = {}
		local delay = render.GetSwapchainImageCount() + 1

		for _, item in ipairs(list) do
			if item.frame <= frame - delay then
				local free = item.pool.free
				free[item.units] = free[item.units] or {}
				local units_list = free[item.units]
				units_list[#units_list + 1] = item.offset
				item.blas:Remove()
			else
				keep[#keep + 1] = item
			end
		end

		rt_state.pending_free = keep
	end

	local function ensure_scratch(size)
		if rt_state.scratch and rt_state.scratch:GetSize() >= size then return end

		if rt_state.scratch then rt_state.scratch:Remove() end

		rt_state.scratch = render.CreateBuffer{
			byte_size = math.max(size, 1024 * 1024),
			buffer_usage = {"shader_device_address", "storage_buffer"},
			memory_property = {"device_local"},
			label = "scene_bvh_blas_scratch",
		}
		rt_state.scratch_address = rt_state.scratch:GetDeviceAddress()
	end

	local function blas_barrier(cmd, dst_stage)
		local barriers = {}

		for i, pool in ipairs(rt_state.pools) do
			barriers[i] = {
				buffer = pool.buffer,
				srcAccessMask = "acceleration_structure_write_khr",
				dstAccessMask = "acceleration_structure_read_khr",
			}
		end

		cmd:PipelineBarrier{
			srcStage = "acceleration_structure_build_khr",
			dstStage = dst_stage,
			bufferBarriers = barriers,
		}
	end

	local function scratch_barrier(cmd)
		cmd:PipelineBarrier{
			srcStage = "acceleration_structure_build_khr",
			dstStage = "acceleration_structure_build_khr",
			bufferBarriers = {
				{
					buffer = rt_state.scratch,
					srcAccessMask = "acceleration_structure_write_khr",
					dstAccessMask = "acceleration_structure_write_khr",
				},
			},
		}
	end

	local function fill_triangle_geometry(geometry, vertex_address, vertex_count)
		geometry.sType = vulkan.vk.VkStructureType.VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_KHR
		geometry.geometryType = VK_GEOMETRY_TYPE_TRIANGLES
		local triangles = geometry.geometry.triangles
		triangles.sType = vulkan.vk.VkStructureType.VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_TRIANGLES_DATA_KHR
		triangles.vertexFormat = vulkan.vk.e.VkFormat("r32g32b32_sfloat")
		triangles.vertexData = vertex_address
		triangles.vertexStride = 12
		triangles.maxVertex = vertex_count - 1
		triangles.indexType = VK_INDEX_TYPE_NONE
	end

	local function write_instance(vc)
		local index = vc.block_index - 1

		if index >= rt_state.instance_capacity then
			local capacity = math.max(math.ceil(rt_state.instance_capacity * 1.5), index + 1, 1024)
			local instances = VkInstanceArray(capacity)
			ffi.copy(instances, rt_state.instances, rt_state.instance_capacity * INSTANCE_BYTE_SIZE)
			rt_state.instances = instances
			rt_state.instance_capacity = capacity
		end

		local instance = rt_state.instances[index]
		instance.transform.matrix[0][0] = 1
		instance.transform.matrix[1][1] = 1
		instance.transform.matrix[2][2] = 1
		instance.sbrtAndFlags = INSTANCE_FACING_CULL_DISABLE + (
				vc.alpha_tested and
				INSTANCE_FORCE_NO_OPAQUE or
				INSTANCE_FORCE_OPAQUE
			)
		instance.customAndMask = 0xFF000000 + vc.tri_base / SOUP_ALIGN
		instance.accelerationStructureReference = vc.rt_address
	end

	-- builds the blas of every visual whose soup range was rewritten since its
	-- blas was built, in batches that fit the scratch budget, and keeps the
	-- instance list (one per block, in block order) in step
	local function build_blases(cmd, position_buffer, frame)
		local device = render.GetDevice()
		local changed = scene_bvh.changed_blocks
		scene_bvh.changed_blocks = {}

		-- the first look covers every block
		if not changed then
			changed = {}

			for _, vc in ipairs(scene_bvh.blocks) do
				changed[vc] = true
			end
		end

		local dirty = {}

		for vc in pairs(changed) do
			if not vc.block_index then
				if vc.rt_blas then release_blas(vc, frame) end
			elseif vc.rt_serial ~= vc.soup_serial then
				dirty[#dirty + 1] = vc
			else
				write_instance(vc)
			end
		end

		if not dirty[1] then return false end

		local n = #dirty
		local geometries = VkGeometryArray(n)
		local infos = VkBuildInfoArray(n)
		local ranges = VkRangeInfoArray(n)
		local range_pointers = VkRangePointerArray(n)
		local scratch_offsets = {}
		local position_address = position_buffer:GetDeviceAddress()
		rt_state.scratch_alignment = rt_state.scratch_alignment or
			math.max(
				tonumber(device.physical_device:GetAccelerationStructureProperties().minAccelerationStructureScratchOffsetAlignment),
				1
			)
		local scratch_alignment = rt_state.scratch_alignment
		local scratch_total = 0
		local largest = 0

		for i = 1, n do
			local vc = dirty[i]
			local geometry = geometries[i - 1]
			fill_triangle_geometry(geometry, position_address + vc.first_vertex * 12, vc.vertex_count)
			local storage_size, scratch_size = AccelerationStructure.QueryBuildSize(
				device,
				{
					type = "bottom_level_khr",
					flags = BUILD_PREFER_FAST_TRACE,
					geometryCount = 1,
					pGeometries = geometry,
					maxPrimitiveCount = vc.total,
				}
			)

			if vc.rt_blas then release_blas(vc, frame) end

			local pool, offset, units = pool_alloc(storage_size)
			vc.rt_pool = pool
			vc.rt_offset = offset
			vc.rt_units = units
			vc.rt_blas = AccelerationStructure.New(
				device,
				"bottom_level_khr",
				pool.buffer,
				offset * BLAS_ALIGN,
				storage_size
			)
			vc.rt_address = vc.rt_blas:Data()
			vc.rt_serial = vc.soup_serial
			write_instance(vc)
			scratch_size = math.ceil(scratch_size / scratch_alignment) * scratch_alignment
			scratch_offsets[i] = scratch_size
			scratch_total = scratch_total + scratch_size
			largest = math.max(largest, scratch_size)
			local info = infos[i - 1]
			info.sType = 1000150000
			info.type = 1
			info.flags = BUILD_PREFER_FAST_TRACE
			info.mode = 0
			info.dstAccelerationStructure = vc.rt_blas.ptr[0]
			info.geometryCount = 1
			info.pGeometries = geometry
			ranges[i - 1].primitiveCount = vc.total
			range_pointers[i - 1] = ranges + (i - 1)
		end

		ensure_scratch(math.max(math.min(SCRATCH_BUDGET, scratch_total), largest))
		local scratch_size = rt_state.scratch:GetSize()
		local cmd_build = device:GetExtension("vkCmdBuildAccelerationStructuresKHR")
		-- scratch may still be in use by builds of an earlier frame
		scratch_barrier(cmd)
		local first = 0

		while first < n do
			local count = 0
			local used = 0

			while first + count < n and used + scratch_offsets[first + count + 1] <= scratch_size do
				infos[first + count].scratchData.deviceAddress = rt_state.scratch_address + used
				used = used + scratch_offsets[first + count + 1]
				count = count + 1
			end

			cmd_build(cmd.ptr[0], count, infos + first, range_pointers + first)
			first = first + count

			if first < n then scratch_barrier(cmd) end
		end

		return true
	end

	local function create_tlas_slot(capacity)
		local slot = {capacity = capacity}
		slot.instance_buffer = render.CreateBuffer{
			byte_size = capacity * INSTANCE_BYTE_SIZE,
			buffer_usage = {"shader_device_address", "acceleration_structure_build_input_read_only_khr"},
			memory_property = {"host_visible", "host_coherent"},
			label = "scene_bvh_tlas_instances",
		}
		slot.instances = ffi.cast(VkInstancePtr, slot.instance_buffer:Map())
		slot.geometry = ffi.new(vulkan.vk.VkAccelerationStructureGeometryKHR)
		slot.geometry.sType = vulkan.vk.VkStructureType.VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_KHR
		slot.geometry.geometryType = VK_GEOMETRY_TYPE_INSTANCES
		local instances = slot.geometry.geometry.instances
		instances.sType = vulkan.vk.VkStructureType.VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_INSTANCES_DATA_KHR
		instances.data = slot.instance_buffer:GetDeviceAddress()
		local storage_size, scratch_size = AccelerationStructure.QueryBuildSize(
			render.GetDevice(),
			{
				type = "top_level_khr",
				flags = BUILD_PREFER_FAST_TRACE,
				geometryCount = 1,
				pGeometries = slot.geometry,
				maxPrimitiveCount = capacity,
			}
		)
		slot.buffer = render.CreateBuffer{
			byte_size = storage_size,
			buffer_usage = {"acceleration_structure_storage_khr", "shader_device_address"},
			memory_property = {"device_local"},
			label = "scene_bvh_tlas",
		}
		slot.tlas = AccelerationStructure.New(render.GetDevice(), "top_level_khr", slot.buffer)
		slot.tlas:EnsureScratch(scratch_size)
		slot.last_used = -math.huge
		return slot
	end

	local function remove_tlas_slot(slot)
		slot.tlas:Remove()
		slot.buffer:Remove()
		slot.instance_buffer:Remove()
	end

	-- a tlas that no frame in flight can still be tracing
	local function get_free_tlas_slot(frame, capacity)
		local delay = render.GetSwapchainImageCount() + 1

		for i = 1, TLAS_SLOT_COUNT do
			local slot = rt_state.tlas_slots[i]

			if not slot or (slot ~= rt_state.current_slot and slot.last_used <= frame - delay) then
				if slot and slot.capacity < capacity then
					remove_tlas_slot(slot)
					slot = nil
				end

				if not slot then
					slot = create_tlas_slot(math.max(capacity, 1024))
					rt_state.tlas_slots[i] = slot
				end

				return slot
			end
		end
	end

	local function build_tlas(cmd, slot, count)
		ffi.copy(slot.instances, rt_state.instances, count * INSTANCE_BYTE_SIZE)
		local ranges = VkRangeInfoArray(1)
		ranges[0].primitiveCount = count
		slot.tlas:Build(cmd, 1, slot.geometry, ranges, BUILD_PREFER_FAST_TRACE)
	end

	-- Returns the TLAS for the current soup, rebuilding what changed into cmd.
	-- Must be recorded outside of a render pass.
	function scene_bvh.EnsureRTBuilt(cmd)
		if not render.GetDevice().ray_tracing_supported or not scene_bvh.IsReady() then
			return nil
		end

		local frame = system.GetFrameNumber()

		if rt_state.built_version == scene_bvh.soup_version and rt_state.current_slot then
			rt_state.current_slot.last_used = frame
			return rt_state.current_slot.tlas
		end

		process_pending_free(frame)
		local vertex_count, position_buffer = scene_bvh.ExpandPositions(cmd, rt_state)
		cmd:PipelineBarrier{
			srcStage = "compute",
			dstStage = "acceleration_structure_build_khr",
			bufferBarriers = {
				{
					buffer = position_buffer,
					srcAccessMask = "shader_write",
					dstAccessMask = "acceleration_structure_read_khr",
				},
			},
		}

		if build_blases(cmd, position_buffer, frame) then
			blas_barrier(cmd, "acceleration_structure_build_khr")
		end

		local count = #scene_bvh.blocks
		local slot = get_free_tlas_slot(frame, count)
		build_tlas(cmd, slot, count)
		-- compute shaders trace it with ray queries (ddgi)
		cmd:PipelineBarrier{
			srcStage = "acceleration_structure_build_khr",
			dstStage = {"ray_tracing_shader_khr", "compute"},
			bufferBarriers = {
				{
					buffer = slot.buffer,
					srcAccessMask = "acceleration_structure_write_khr",
					dstAccessMask = "acceleration_structure_read_khr",
				},
			},
		}
		slot.last_used = frame
		rt_state.current_slot = slot
		rt_state.built_version = scene_bvh.soup_version
		return slot.tlas
	end

	-- An empty TLAS, for descriptors that must hold a valid one before the
	-- scene's first build (null descriptors need a feature many devices lack).
	function scene_bvh.GetPlaceholderTLAS(cmd)
		if rt_state.placeholder then return rt_state.placeholder.tlas end

		local slot = create_tlas_slot(1)
		local ranges = VkRangeInfoArray(1)
		ranges[0].primitiveCount = 0
		slot.tlas:Build(cmd, 1, slot.geometry, ranges, BUILD_PREFER_FAST_TRACE)
		cmd:PipelineBarrier{
			srcStage = "acceleration_structure_build_khr",
			dstStage = {"ray_tracing_shader_khr", "compute"},
			bufferBarriers = {
				{
					buffer = slot.buffer,
					srcAccessMask = "acceleration_structure_write_khr",
					dstAccessMask = "acceleration_structure_read_khr",
				},
			},
		}
		rt_state.placeholder = slot
		return slot.tlas
	end
end

return scene_bvh
