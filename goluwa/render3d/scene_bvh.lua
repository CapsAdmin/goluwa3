local ffi = require("ffi")
local band = require("bit").band
local render = import("goluwa/render/render.lua")
local commands = import("goluwa/cli/commands.lua")
local event = import("goluwa/event.lua")
local scene_loading = import("goluwa/render3d/scene_loading.lua")
local system = import("goluwa/system.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local gpu_timing = import("goluwa/render/gpu_timing.lua")
local Fence = import("goluwa/render/vulkan/internal/fence.lua")
local scene_bvh = library()
-- Pre-register to break import cycle: visual -> render3d -> scene_bvh -> visual
import.loaded["goluwa/render3d/scene_bvh.lua"] = scene_bvh
local Visual
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
-- double sided), its power (area x emission luminance), its centroid, and
-- whether it is only emissive because its material is additive (a light shaft,
-- water foam, a sparkle: an effect, not a light)
local Emitter = ffi.typeof([[struct {
	uint32_t triangle;
	float power;
	float x, y, z;
	uint32_t additive;
}]])
local EmitterArray = ffi.typeof("$[?]", Emitter)
scene_bvh.EmitterArray = EmitterArray
local TrianglePtr = ffi.typeof("$*", Triangle)
local FloatArray = ffi.typeof("float[?]")
local DoubleArray = ffi.typeof("double[?]")
local UInt32Array = ffi.typeof("uint32_t[?]")
local Int32Array = ffi.typeof("int32_t[?]")
local UInt8Array = ffi.typeof("uint8_t[?]")
local NODE_BYTE_SIZE = 32
local TRIANGLE_BYTE_SIZE = 64
-- static: keeps a uv per triangle vertex beside the soup, so the shadow soup
-- can alpha test and blend with a material's albedo texture. set
-- GOLUWA_SOUP_UVS=1 to measure what it costs
scene_bvh.SOUP_UVS = true
local SOUP_UVS = scene_bvh.SOUP_UVS
scene_bvh.RAY_MASK_SOLID = 0x01
-- three uvs and three texture blend weights of a triangle, indexed like the
-- triangle buffer
local UV_FLOATS = 9
local UV_BYTE_SIZE = UV_FLOATS * 4
-- position, normal, uv, tangent come first in a mesh vertex
local UV_FLOAT_OFFSET = 6
local BLEND_FLOAT_OFFSET = 12
-- the soup is bound as an array of SOUP_CHUNKS descriptors over one buffer,
-- each covering 2 GiB of it, so a soup larger than maxStorageBufferRange (and
-- than what 32 bit byte offsets can address) stays reachable. triangle i lives
-- in chunk i / SOUP_CHUNK_TRIS at i % SOUP_CHUNK_TRIS
local SOUP_CHUNK_BYTES = 2147483648
local SOUP_CHUNKS = 8
local SOUP_CHUNK_TRIS = SOUP_CHUNK_BYTES / TRIANGLE_BYTE_SIZE
scene_bvh.SOUP_CHUNKS = SOUP_CHUNKS
scene_bvh.UV_CHUNK_BYTES = SOUP_CHUNK_TRIS * UV_BYTE_SIZE
scene_bvh.SOUP_CHUNK_TRIS = SOUP_CHUNK_TRIS
local BIN_COUNT = 12
local MAX_LEAF_TRIANGLES = 8
local MAX_DEPTH = 30
-- every visual's soup range starts at a multiple of this, so the ray tracing
-- instance of a visual can store its range start in the 24 bit custom index
local SOUP_ALIGN = 4
scene_bvh.SOUP_ALIGN = SOUP_ALIGN
scene_bvh.STACK_SIZE = 32
scene_bvh.node_count = 0
scene_bvh.triangle_count = 0
scene_bvh.build_time = 0
scene_bvh.version = 0
-- bumped only when a build writes new triangles. version also bumps on every
-- invalidation, so whatever is derived from the triangles themselves (the ray
-- tracing BLAS, the expanded shadow soup, the emitter list) follows this one
scene_bvh.soup_version = 0
-- bumped when a block of a hidden visual leaves the top tree or comes back.
-- its triangles, nodes and blas stay where they are, so the soup is the same
-- and only what is built over the blocks (the top tree, the tlas, the emitter
-- list) changes
scene_bvh.top_version = 0
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
-- blocks of visuals with a skeleton, rewritten by the gpu every frame
scene_bvh.animated_blocks = {}
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
	-- the leaves of every top node's subtree are a run of leaf_blocks, in tree
	-- order, so a subtree inside the frustum is marked with one loop instead
	-- of a walk over its nodes. rebuilt when a build changed the tree
	local leaf_first = Int32Array(1)
	local leaf_count = Int32Array(1)
	local leaf_blocks = Int32Array(1)
	local node_capacity = 1
	local leaf_capacity = 1
	local ranges_version = -1
	local walk_stack = {}

	local function grow_leaf_ranges(node_needed, leaf_needed)
		if node_needed > node_capacity then
			local capacity = math.max(node_needed, node_capacity * 2)
			local first, count = Int32Array(capacity), Int32Array(capacity)
			ffi.copy(first, leaf_first, node_capacity * 4)
			ffi.copy(count, leaf_count, node_capacity * 4)
			leaf_first, leaf_count, node_capacity = first, count, capacity
		end

		if leaf_needed > leaf_capacity then
			local capacity = math.max(leaf_needed, leaf_capacity * 2)
			local blocks = Int32Array(capacity)
			ffi.copy(blocks, leaf_blocks, leaf_capacity * 4)
			leaf_blocks, leaf_capacity = blocks, capacity
		end
	end

	local function build_leaf_ranges()
		local nodes = scene_bvh.nodes
		local top_leaf_block = scene_bvh.top_leaf_block
		grow_leaf_ranges(scene_bvh.top_count * 2 + 16, scene_bvh.top_count + 8)
		local written = 0
		local top = 1
		walk_stack[1] = 0

		while top > 0 do
			local entry = walk_stack[top]
			top = top - 1

			if entry >= 0 then
				leaf_first[entry] = written
				local block_index = top_leaf_block[entry]

				if block_index ~= 0 then
					grow_leaf_ranges(0, written + 1)
					leaf_blocks[written] = block_index - 1
					written = written + 1
					leaf_count[entry] = 1
				else
					local left = nodes[entry].left_first
					grow_leaf_ranges(left + 2, 0)
					walk_stack[top + 1] = -entry - 1
					walk_stack[top + 2] = left + 1
					walk_stack[top + 3] = left
					top = top + 3
				end
			else
				local index = -entry - 1
				leaf_count[index] = written - leaf_first[index]
			end
		end
	end

	function scene_bvh.MarkVisibleBlocks(planes)
		local nodes = scene_bvh.nodes
		local top_leaf_block = scene_bvh.top_leaf_block
		local visible = scene_bvh.raster_visible

		if not (nodes and visible) or scene_bvh.top_count == 0 then return end

		if ranges_version ~= scene_bvh.version then
			build_leaf_ranges()
			ranges_version = scene_bvh.version
		end

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
				if mask == 0 then
					local first = leaf_first[index]

					for i = first, first + leaf_count[index] - 1 do
						visible[leaf_blocks[i]] = 1
					end
				else
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

	local function create_mapped_buffer(label, byte_size, usage, properties)
		local buffer = render.CreateBuffer{
			byte_size = byte_size,
			buffer_usage = usage,
			memory_property = properties,
			label = label,
		}
		return buffer, buffer:Map()
	end

	-- the soup and its uvs are written by the cpu into staging buffers in
	-- cached system memory, and the ranges rewritten since the last upload
	-- are copied into device local buffers, which is where shaders read them
	-- from (system memory is read over pcie)
	local STAGING_PROPERTIES = {"host_visible", "host_coherent", "host_cached"}
	local soup_dirty = {}
	local soup_upload_all = false

	local function mark_soup_dirty(first, count)
		if count == 0 then return end

		local n = #soup_dirty

		if n > 0 and soup_dirty[n - 1] + soup_dirty[n] == first then
			soup_dirty[n] = soup_dirty[n] + count
			return
		end

		soup_dirty[n + 1] = first
		soup_dirty[n + 2] = count
	end

	local function grow_nodes(needed)
		local capacity = math.max(needed, math.ceil(scene_bvh.node_capacity * 1.5), 1024)
		local nodes = NodeArray(capacity)

		if scene_bvh.nodes then
			ffi.copy(nodes, scene_bvh.nodes, scene_bvh.node_capacity * NODE_BYTE_SIZE)
		end

		if scene_bvh.node_buffer then
			scene_bvh.node_buffer:Remove()
			render.GetDevice():WaitIdle()
		end

		local buffer, ptr = create_mapped_buffer(
			"scene_bvh_nodes",
			capacity * NODE_BYTE_SIZE,
			{"storage_buffer"},
			{"host_visible", "host_coherent"}
		)
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
	-- again from every block's shape
	local function grow_triangles(needed)
		local capacity = math.max(needed, math.ceil(scene_bvh.triangle_capacity * 1.25), 1024)

		if scene_bvh.triangle_buffer then scene_bvh.triangle_buffer:Remove() end

		if scene_bvh.triangle_staging then scene_bvh.triangle_staging:Remove() end

		if SOUP_UVS then
			if scene_bvh.uv_buffer then scene_bvh.uv_buffer:Remove() end

			if scene_bvh.uv_staging then scene_bvh.uv_staging:Remove() end
		end

		-- a build can grow the soup many times before a frame completes, and
		-- the replaced buffers would all wait for it. the soup is baked again
		-- and uploaded in full anyway, so nothing of the old one is needed
		render.GetDevice():WaitIdle()
		local staging, ptr = create_mapped_buffer(
			"scene_bvh_triangles_staging",
			capacity * TRIANGLE_BYTE_SIZE,
			{"transfer_src"},
			STAGING_PROPERTIES
		)
		scene_bvh.triangle_staging = staging
		scene_bvh.triangles = ffi.cast(TrianglePtr, ptr)
		scene_bvh.triangle_buffer = render.CreateBuffer{
			byte_size = capacity * TRIANGLE_BYTE_SIZE,
			buffer_usage = {"storage_buffer", "transfer_dst"},
			memory_property = {"device_local"},
			label = "scene_bvh_triangles",
		}

		if SOUP_UVS then
			local uv_staging, uv_ptr = create_mapped_buffer(
				"scene_bvh_uvs_staging",
				capacity * UV_BYTE_SIZE,
				{"transfer_src"},
				STAGING_PROPERTIES
			)
			scene_bvh.uv_staging = uv_staging
			scene_bvh.uvs = ffi.cast("float*", uv_ptr)
			scene_bvh.uv_buffer = render.CreateBuffer{
				byte_size = capacity * UV_BYTE_SIZE,
				buffer_usage = {"storage_buffer", "transfer_dst"},
				memory_property = {"device_local"},
				label = "scene_bvh_uvs",
			}
		end

		soup_upload_all = true

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
	end

	-- zeroed triangles expand to degenerate ones, so the padding of a range
	-- and a freed range draw nothing. that lets the shadow soup draw runs of
	-- neighbouring blocks as one range across their padding
	local function free_soup_range(base, cap)
		range_free(scene_bvh.triangle_allocator, base, cap)
		ffi.fill(scene_bvh.triangles + base, cap * TRIANGLE_BYTE_SIZE)
		mark_soup_dirty(base, cap)
	end

	do
		local BufferCopyArray = ffi.typeof("$[?]", import("goluwa/render/vulkan/internal/vulkan.lua").vk.VkBufferCopy)
		local SOUP_MERGE_GAP = 256
		local order = {}
		local ranges = {}
		local triangle_copies, uv_copies
		local copy_capacity = 0
		-- uploads in flight at once. a slot's fence is waited on before reuse
		local UPLOAD_SLOTS = 4
		local slots = {}
		local next_slot = 0

		local function by_first(a, b)
			return soup_dirty[a * 2 - 1] < soup_dirty[b * 2 - 1]
		end

		-- the dirty ranges as merged first / count pairs, sorted
		local function collect_ranges()
			local n = #soup_dirty / 2
			table.clear(ranges)

			if soup_upload_all then
				if scene_bvh.triangle_allocator.top > 0 then
					ranges[1] = 0
					ranges[2] = scene_bvh.triangle_allocator.top
				end

				return
			end

			for i = 1, n do
				order[i] = i
			end

			for i = n + 1, #order do
				order[i] = nil
			end

			table.sort(order, by_first)
			local first = soup_dirty[order[1] * 2 - 1]
			local stop = first + soup_dirty[order[1] * 2]

			for i = 2, n do
				local f = soup_dirty[order[i] * 2 - 1]
				local c = soup_dirty[order[i] * 2]

				if f <= stop + SOUP_MERGE_GAP then
					stop = math.max(stop, f + c)
				else
					ranges[#ranges + 1] = first
					ranges[#ranges + 1] = stop - first
					first = f
					stop = f + c
				end
			end

			ranges[#ranges + 1] = first
			ranges[#ranges + 1] = stop - first
		end

		-- copies what the cpu wrote into the soup staging buffers since the
		-- last call into the device local soup, in a command buffer of its
		-- own that is submitted before anything of the frame reads the soup.
		-- its barrier covers the commands submitted after it
		function scene_bvh.UploadSoup()
			if not soup_upload_all and not soup_dirty[1] then return end

			if not scene_bvh.triangle_staging then return end

			collect_ranges()
			local region_count = #ranges / 2

			if region_count == 0 then
				soup_upload_all = false
				return
			end

			-- the copy brings the cpu bake of a range, which an animated block has to be rewritten over
			for vc in pairs(scene_bvh.animated_blocks) do
				for i = 1, #ranges, 2 do
					if vc.tri_base < ranges[i] + ranges[i + 1] and ranges[i] < vc.tri_base + vc.tri_cap then
						vc.animate_dirty = true

						break
					end
				end
			end

			if copy_capacity < region_count then
				copy_capacity = math.max(region_count, copy_capacity * 2, 64)
				triangle_copies = BufferCopyArray(copy_capacity)
				uv_copies = BufferCopyArray(copy_capacity)
			end

			next_slot = next_slot % UPLOAD_SLOTS + 1
			local slot = slots[next_slot]
			local queue = render.GetQueue()

			if not slot then
				slot = {
					cmd = render.GetCommandPool():AllocateCommandBuffer(),
					fence = Fence.New(render.GetDevice()),
				}
				slots[next_slot] = slot
			end

			if queue:HasPendingSubmission(slot.fence) then
				slot.fence:Wait()
				queue:RetireFence(slot.fence)
			end

			for i = 0, region_count - 1 do
				local first = ranges[i * 2 + 1]
				local count = ranges[i * 2 + 2]
				triangle_copies[i].srcOffset = first * TRIANGLE_BYTE_SIZE
				triangle_copies[i].dstOffset = first * TRIANGLE_BYTE_SIZE
				triangle_copies[i].size = count * TRIANGLE_BYTE_SIZE

				if SOUP_UVS then
					uv_copies[i].srcOffset = first * UV_BYTE_SIZE
					uv_copies[i].dstOffset = first * UV_BYTE_SIZE
					uv_copies[i].size = count * UV_BYTE_SIZE
				end
			end

			local cmd = slot.cmd
			cmd:Reset()
			cmd:Begin()
			cmd:CopyBuffer(scene_bvh.triangle_staging, scene_bvh.triangle_buffer, triangle_copies, region_count)
			local barriers = {
				{
					buffer = scene_bvh.triangle_buffer,
					srcAccessMask = "transfer_write",
					dstAccessMask = "shader_read",
				},
			}

			if SOUP_UVS then
				cmd:CopyBuffer(scene_bvh.uv_staging, scene_bvh.uv_buffer, uv_copies, region_count)
				barriers[2] = {
					buffer = scene_bvh.uv_buffer,
					srcAccessMask = "transfer_write",
					dstAccessMask = "shader_read",
				}
			end

			cmd:PipelineBarrier{
				srcStage = "transfer",
				dstStage = {"vertex", "fragment", "compute", "ray_tracing_shader_khr"},
				bufferBarriers = barriers,
			}
			cmd:End()
			render.Submit(cmd, slot.fence)
			table.clear(soup_dirty)
			soup_upload_all = false
		end
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
			local dithered = UInt8Array(capacity)

			if scene_bvh.raster_dithered then
				ffi.copy(dithered, scene_bvh.raster_dithered, scene_bvh.raster_capacity)
			end

			scene_bvh.raster_ranges = ranges
			scene_bvh.raster_visible = UInt8Array(capacity)
			scene_bvh.raster_dithered = dithered
			scene_bvh.raster_capacity = capacity
		end

		scene_bvh.raster_dithered[i] = vc.shadow_dithered and 1 or 0
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
		scene_bvh.top_changes = 0
		scene_bvh.top_incremental_count = 0
		get_scratch(1, math.max(n, 1))
		local top_bounds = scratch.top_bounds
		local top_centroids = scratch.top_centroids
		local top_order = scratch.top_order
		local count = 0

		for i = 1, n do
			local vc = blocks[i]
			vc.top_slot = nil

			-- the sah reads bounds and centroids by block index, only the
			-- order it partitions leaves hidden blocks out
			if not vc.hidden then
				local aabb = vc.world_aabb
				local t = i - 1
				top_order[count] = t
				top_bounds[t * 6 + 0] = aabb[0]
				top_bounds[t * 6 + 1] = aabb[1]
				top_bounds[t * 6 + 2] = aabb[2]
				top_bounds[t * 6 + 3] = aabb[3]
				top_bounds[t * 6 + 4] = aabb[4]
				top_bounds[t * 6 + 5] = aabb[5]
				top_centroids[t * 3 + 0] = (aabb[0] + aabb[3]) / 2
				top_centroids[t * 3 + 1] = (aabb[1] + aabb[4]) / 2
				top_centroids[t * 3 + 2] = (aabb[2] + aabb[5]) / 2
				count = count + 1
			end
		end

		n = count
		scene_bvh.top_count = n

		if n == 0 then
			set_top_empty()
			return
		end

		-- the sah allocates up to n - 1 pairs, and must not see the node
		-- mirror move under it
		if allocator.top + n * 2 > allocator.capacity then
			grow_nodes(allocator.top + n * 2)
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
		local local_uvs = piece.local_uvs
		local local_source = piece.local_source

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

				if local_source then
					local source = written * 3
					local_source[source] = indices[triangle * 3]
					local_source[source + 1] = indices[triangle * 3 + 1]
					local_source[source + 2] = indices[triangle * 3 + 2]
				end

				if local_uvs then
					local uv = written * UV_FLOATS
					local_uvs[uv] = vertices[a + UV_FLOAT_OFFSET]
					local_uvs[uv + 1] = vertices[a + UV_FLOAT_OFFSET + 1]
					local_uvs[uv + 2] = vertices[b + UV_FLOAT_OFFSET]
					local_uvs[uv + 3] = vertices[b + UV_FLOAT_OFFSET + 1]
					local_uvs[uv + 4] = vertices[c + UV_FLOAT_OFFSET]
					local_uvs[uv + 5] = vertices[c + UV_FLOAT_OFFSET + 1]
					local_uvs[uv + 6] = vertices[a + BLEND_FLOAT_OFFSET]
					local_uvs[uv + 7] = vertices[b + BLEND_FLOAT_OFFSET]
					local_uvs[uv + 8] = vertices[c + BLEND_FLOAT_OFFSET]
				end

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
			local_uvs = SOUP_UVS and FloatArray(slot.count * UV_FLOATS) or nil,
			-- the three vertex indices of each kept triangle, for blocks the gpu rewrites every frame
			local_source = slot.animated and UInt32Array(slot.count * 3) or nil,
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

		if shape.pieces[1].local_source then
			-- per soup triangle, in soup order: the three vertex indices and the slot they index into
			local source = UInt32Array(total * 4)

			for i = 0, total - 1 do
				local l = shape.order[i]
				local s = shape.slot_of[l]
				local from = (l - shape.starts[s + 1]) * 3
				local local_source = shape.pieces[s + 1].local_source
				source[i * 4] = local_source[from]
				source[i * 4 + 1] = local_source[from + 1]
				source[i * 4 + 2] = local_source[from + 2]
				source[i * 4 + 3] = s
			end

			shape.animated_source = render.CreateBuffer{
				byte_size = total * 16,
				buffer_usage = {"storage_buffer", "shader_device_address"},
				memory_property = {"host_visible", "host_coherent"},
				data = source,
				label = "scene_bvh_animated_source",
			}
		end

		shapes[key] = shape
		return shape
	end

	-- writes a block's shape into its soup range in SAH order, transformed by
	-- its world matrix and with its slots' materials
	function bake_triangles(vc)
		vc.animate_dirty = true
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

			if SOUP_UVS then
				ffi.copy(
					scene_bvh.uvs + (vc.tri_base + i) * UV_FLOATS,
					pieces[s].local_uvs + (l - starts[s]) * UV_FLOATS,
					UV_BYTE_SIZE
				)
			end
		end

		ffi.fill(world + total, (vc.tri_cap - total) * TRIANGLE_BYTE_SIZE)
		mark_soup_dirty(vc.tri_base, vc.tri_cap)

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
				local x0 = src.v0[0] * m00 + src.v0[1] * m10 + src.v0[2] * m20 + m30
				local y0 = src.v0[0] * m01 + src.v0[1] * m11 + src.v0[2] * m21 + m31
				local z0 = src.v0[0] * m02 + src.v0[1] * m12 + src.v0[2] * m22 + m32
				local e1x = src.e1[0] * m00 + src.e1[1] * m10 + src.e1[2] * m20
				local e1y = src.e1[0] * m01 + src.e1[1] * m11 + src.e1[2] * m21
				local e1z = src.e1[0] * m02 + src.e1[1] * m12 + src.e1[2] * m22
				local e2x = src.e2[0] * m00 + src.e2[1] * m10 + src.e2[2] * m20
				local e2y = src.e2[0] * m01 + src.e2[1] * m11 + src.e2[2] * m21
				local e2z = src.e2[0] * m02 + src.e2[1] * m12 + src.e2[2] * m22
				local nx = e1y * e2z - e1z * e2y
				local ny = e1z * e2x - e1x * e2z
				local nz = e1x * e2y - e1y * e2x
				local material = scene_bvh.materials[slot.material_id + 1]
				emitters[count].triangle = material:GetDoubleSided() and i + 0x80000000 or i
				emitters[count].additive = material:GetAdditive() and
					not material:GetAlbedoAlphaIsEmissive()
					and
					material:GetEmissiveTexture() == nil and
					1 or
					0
				emitters[count].power = 0.5 * math.sqrt(nx * nx + ny * ny + nz * nz) * luminance
				emitters[count].x = x0 + (e1x + e2x) / 3
				emitters[count].y = y0 + (e1y + e2y) / 3
				emitters[count].z = z0 + (e1z + e2z) / 3
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

		-- the gpu rewrites the triangle positions of an animated block every
		-- frame, so a move only needs the bake that gave its range the
		-- materials, uvs and emissive values
		local signature = shape.total

		for i = 1, vc.slot_count do
			local slot = vc.slots[i]
			signature = signature * 131 + slot.material_id + slot.emissive_r * 7 + slot.emissive_g * 11 + slot.emissive_b * 13
		end

		if
			not vc.animated or
			vc.baked_shape ~= shape or
			vc.baked_signature ~= signature or
			vc.baked_base ~= tri_base
		then
			bake_triangles(vc)
			vc.baked_shape = shape
			vc.baked_signature = signature
			vc.baked_base = tri_base
		end

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
		scene_bvh.animated_blocks[vc] = nil

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
		local animated = false
		local fast = vc ~= nil and vc.matrix == v

		for _, entry in ipairs(visual:GetRenderEntries()) do
			local mesh = entry.polygon3d.mesh

			-- skinned meshes change every frame, the soup would keep their bind pose
			if mesh and mesh.Type ~= "null" then
				-- only with a vertex array of its own: skinned meshes that are not bound to an animator are
				-- shared between all instances of the model, and so are their shape and blas
				animated = animated or entry.polygon3d.Dynamic == true
				local index_buffer = mesh.index_buffer
				local count = index_buffer and
					math.floor(index_buffer:GetIndexCount() / 3) or
					math.floor(mesh.vertex_buffer:GetVertexCount() / 3)

				if count > 0 then
					local material = visual:GetResolvedMaterial(entry)
					local emissive_r, emissive_g, emissive_b = 0, 0, 0

					if
						material:GetAlbedoAlphaIsEmissive() or
						material:GetAdditive() or
						material:GetEmissiveTexture() ~= nil
					then
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

		for i = 1, slot_count do
			slots[i].animated = animated
		end

		if slot_count == 0 then
			if vc then release_block(visual, vc, inserts.rebuild) end

			return
		end

		vc = vc or {}
		cache[visual] = vc
		vc.stamp = stamp
		-- only where ray tracing is, which is what the gpu rewrite and the blas update serve
		vc.animated = animated and render.GetDevice().ray_tracing_supported
		scene_bvh.animated_blocks[vc] = vc.animated or nil
		local hidden = not visual.Visible

		-- a hidden visual keeps its ranges and blas, it only leaves the top
		-- tree, so showing it again is cheap
		if (vc.hidden or false) ~= hidden then
			vc.hidden = hidden
			scene_bvh.top_version = scene_bvh.top_version + 1

			if vc.block_index then
				if scene_bvh.changed_blocks then scene_bvh.changed_blocks[vc] = true end

				if vc.emissive then scene_bvh.emissive_changed = true end

				if scene_bvh.dirty_boxes then
					local box = vc.world_aabb
					list.insert(scene_bvh.dirty_boxes, {box[0], box[1], box[2], box[3], box[4], box[5]})
				end

				if hidden and vc.top_slot and not inserts.rebuild then
					remove_top_leaf(vc)
					scene_bvh.top_changes = scene_bvh.top_changes + 1
				end
			end
		end

		-- whether a block's materials let light through follows the materials,
		-- which change without the block being baked again
		local non_opaque, dithered = false, false
		local alpha_tested, total = 0, 0

		for i = 1, slot_count do
			local material = scene_bvh.materials[slots[i].material_id + 1]
			local opacity = material:GetSoupShadowOpacity()

			if material:GetAlphaTest() or opacity < 1 then non_opaque = true end

			total = total + slots[i].count

			if material:GetAlphaTest() then alpha_tested = alpha_tested + slots[i].count end

			if opacity > 0 and (opacity < 1 or (SOUP_UVS and material:HasShadowTexture())) then
				dithered = true
			end
		end

		local foliage = alpha_tested * 2 > total

		if
			vc.block_index and
			(
				vc.non_opaque ~= non_opaque or
				vc.foliage ~= foliage or
				vc.shadow_dithered ~= dithered
			)
		then
			-- the ray tracing instance carries the flag
			scene_bvh.top_version = scene_bvh.top_version + 1

			if scene_bvh.changed_blocks then scene_bvh.changed_blocks[vc] = true end

			scene_bvh.raster_dithered[vc.block_index - 1] = dithered and 1 or 0
		end

		vc.non_opaque = non_opaque
		vc.foliage = foliage
		vc.shadow_dithered = dithered

		if fast and vc.block_index and vc.baked_matrix == v then
			if not hidden and not vc.top_slot and not inserts.rebuild then
				inserts[#inserts + 1] = vc
			end

			return
		end

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
		elseif not hidden then
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
		local start_time = system.GetElapsedTime()
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

				if system.GetElapsedTime() > deadline then break end
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
				if not vc.hidden then emissive_blocks[#emissive_blocks + 1] = vc end
			end

			scene_bvh.emissive_blocks = emissive_blocks
			scene_bvh.emissive_changed = false
		end

		scene_bvh.debug_node_count = scene_bvh.node_allocator.top
		scene_bvh.node_count = scene_bvh.node_allocator.top
		scene_bvh.soup_triangle_count = scene_bvh.triangle_allocator.top
		scene_bvh.build_time = system.GetElapsedTime() - start_time
		scene_bvh.has_built = true
		scene_bvh.version = scene_bvh.version + 1

		if scene_bvh.soup_dirty then
			scene_bvh.soup_version = scene_bvh.soup_version + 1
		end

		scene_bvh.UploadSoup()

		if scene_bvh.triangle_count > 0 and not scene_bvh.readied then
			scene_bvh.readied = true
			event.Call("BVHSceneReady")
		end
	end

	scene_bvh.BuildIncremental = build

	-- brings the tree up to date with every visual. force_full also lays the
	-- soup out from scratch and rebuilds the top tree with a fresh sah
	function scene_bvh.Build(force_full)
		build(force_full and "reset" or "scan")
	end
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

-- the first build waits for everything loading (see scene_loading) and then
-- for this long without changes, so spawns that arrive together share one build
scene_bvh.FIRST_BUILD_QUIET_TIME = 0.25
-- unless the scene keeps changing after loading ended
scene_bvh.FIRST_BUILD_MAX_WAIT = 2

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

	local settled = (scene_bvh.last_change_frame or 0) < frame - 1 or scene_bvh.build_backlog
	local max_wait = math.max(0.02, scene_bvh.build_time * 20)

	if not scene_bvh.has_built then
		if scene_loading.IsLoading() then
			scene_bvh.loaded_since = nil
			return
		end

		scene_bvh.loaded_since = scene_bvh.loaded_since or now
		local quiet_since = scene_bvh.last_change_time or scene_bvh.dirty_since

		if
			now - quiet_since < scene_bvh.FIRST_BUILD_QUIET_TIME and
			now - scene_bvh.loaded_since < scene_bvh.FIRST_BUILD_MAX_WAIT
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

	function scene_bvh.BindTriangleBuffer(pipeline, descriptor_index, binding, buffer, chunk_bytes)
		chunk_bytes = chunk_bytes or SOUP_CHUNK_BYTES
		local infos = chunk_infos[buffer]

		if not infos then
			local size = buffer:GetSize()
			infos = {}

			for i = 0, SOUP_CHUNKS - 1 do
				local offset = i * chunk_bytes

				if offset >= size then offset = 0 end

				infos[i + 1] = {
					buffer = buffer,
					offset = offset,
					range = math.min(chunk_bytes, size - offset),
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

-- the three uvs of a soup triangle, bound with BindTriangleBuffer and
-- UV_CHUNK_BYTES. only exists with SOUP_UVS
function scene_bvh.GetUvDeclarationGLSL(uv_binding)
	return (
		[[
		struct scene_bvh_uv {
			vec2 uv0;
			vec2 uv1;
			vec2 uv2;
			vec3 blend;
		};

		layout(scalar, set = 0, binding = %d) readonly buffer SceneBVHUvBuffer {
			scene_bvh_uv uvs[];
		} scene_bvh_uv_soup[%d];

		scene_bvh_uv bvh_uv(uint index) {
			uint chunk = index / SCENE_BVH_SOUP_CHUNK;
			return scene_bvh_uv_soup[nonuniformEXT(chunk)].uvs[index - chunk * SCENE_BVH_SOUP_CHUNK];
		}
	]]
	):format(uv_binding, SOUP_CHUNKS)
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
	local expand_base = 0

	-- expands ranges of the soup into one world space position per vertex,
	-- which is what a blas is built from
	function scene_bvh.CreateExpander(state)
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
				{"base_vertex", "int"},
				write = function(self, block)
					block.first_vertex = expand_first
					block.vertex_count = expand_count
					block.base_vertex = expand_base
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
					positions[vid - uint(compute.base_vertex)] = p;
				}
			]],
		}
		return state
	end

	local function expand_range(cmd, pipeline, slot, first_vertex, vertex_count, base_vertex)
		expand_first = first_vertex
		expand_count = vertex_count
		expand_base = base_vertex
		pipeline:Dispatch(cmd, math.ceil(vertex_count / EXPAND_LOCAL_SIZE), 1, 1, slot)
	end

	-- the share of light each material stops, by material id, for the
	-- shadow soup to read. written again in full when a material's opacity
	-- changed and appended to otherwise. returns the buffer, which is
	-- replaced when it grows
	local shadow_materials = {capacity = 0, filled = 0, generation = -1}

	function scene_bvh.UpdateShadowMaterials()
		local materials = scene_bvh.materials
		local count = #materials

		if count > shadow_materials.capacity then
			local capacity = math.max(count, math.ceil(shadow_materials.capacity * 1.5), 256)
			local buffer = render.CreateBuffer{
				byte_size = capacity * 4,
				buffer_usage = {"storage_buffer"},
				memory_property = {"host_visible", "host_coherent"},
				label = "scene_bvh_shadow_materials",
			}
			local ptr = ffi.cast("float*", buffer:Map())

			if shadow_materials.buffer then
				ffi.copy(ptr, shadow_materials.ptr, shadow_materials.filled * 4)
				shadow_materials.buffer:Remove()
			end

			shadow_materials.buffer = buffer
			shadow_materials.ptr = ptr
			shadow_materials.capacity = capacity
		end

		local first = shadow_materials.generation == Material.shadow_generation and
			shadow_materials.filled or
			0

		for i = first, count - 1 do
			shadow_materials.ptr[i] = materials[i + 1]:GetSoupShadowOpacity()
		end

		shadow_materials.filled = count
		shadow_materials.generation = Material.shadow_generation
		return shadow_materials.buffer
	end

	-- blocks whose materials let some of the light through draw dithered in
	-- the shadow soup. a build works out the class of the blocks it writes, so
	-- this is for when a material's class changed. it looks at the materials
	-- stamped since it last ran, and only goes over the blocks when the class
	-- of one that was classified before is different now
	local classified_stamp = 0
	local classified_full_generation = -1

	function scene_bvh.RefreshShadowClasses()
		local materials = scene_bvh.materials
		local full = classified_full_generation ~= Material.shadow_full_generation
		local changed = full

		for i = 1, #materials do
			local material = materials[i]
			local class = material.soup_dither_class

			if full or class == nil or (material.shadow_stamp or 0) > classified_stamp then
				local opacity = material:GetSoupShadowOpacity()
				local new_class = (
						opacity > 0 and
						(
							opacity < 1 or
							(
								SOUP_UVS and
								material:HasShadowTexture()
							)
						)
					)
					and
					1 or
					0

				if class ~= nil and class ~= new_class then changed = true end

				material.soup_dither_class = new_class
			end
		end

		classified_stamp = Material.shadow_stamp
		classified_full_generation = Material.shadow_full_generation

		if not changed then return end

		local blocks = scene_bvh.blocks

		for index = 1, #blocks do
			local vc = blocks[index]
			local dithered = false

			for i = 1, vc.slot_count do
				if materials[vc.slots[i].material_id + 1].soup_dither_class == 1 then
					dithered = true

					break
				end
			end

			vc.shadow_dithered = dithered
			scene_bvh.raster_dithered[index - 1] = dithered and 1 or 0
		end
	end

	-- Hardware ray tracing backend over the same soup: one BLAS per shape,
	-- built from the soup range of the first visual of it that needs one
	-- (non-indexed, in that visual's world space), and a TLAS with an instance
	-- per visual. The instance's transform takes the BLAS to the visual's own
	-- world space, and its custom index is the visual's soup range start /
	-- SOUP_ALIGN, so a hit's soup triangle index is custom index *
	-- SOUP_ALIGN + primitive index (every visual of a shape bakes its
	-- triangles in the same order). A moved visual only rewrites its instance;
	-- a changed shape builds a new BLAS.
	local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
	local AccelerationStructure = import("goluwa/render/vulkan/internal/acceleration_structure.lua")
	local Matrix44 = import("goluwa/structs/matrix44.lua")
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
	-- the blas of an animated visual is updated in place every frame
	local BUILD_ALLOW_UPDATE = 1
	local BUILD_MODE_UPDATE = 1
	local INSTANCE_FACING_CULL_DISABLE = 0x01000000
	-- the soup has no uvs to alpha test a hit with, and no way to blend, so
	-- alpha tested and see through visuals are non-opaque and rays that can do
	-- without them cull them
	local INSTANCE_FORCE_OPAQUE = 0x04000000
	local INSTANCE_FORCE_NO_OPAQUE = 0x08000000
	-- the top byte of customAndMask is the ray mask. a visual that is mostly
	-- alpha tested is foliage, which a ray skips with a cull mask of RAY_MASK_SOLID
	local INSTANCE_MASK_SOLID = scene_bvh.RAY_MASK_SOLID * 0x1000000
	local INSTANCE_MASK_FOLIAGE = 0x02 * 0x1000000
	local BLAS_ALIGN = 256
	local BLAS_POOL_BYTES = 64 * 1024 * 1024
	local SCRATCH_BUDGET = 128 * 1024 * 1024
	local TLAS_SLOT_COUNT = 4
	-- blas builds read their positions from a staging buffer that is filled
	-- with the world space triangles of the blocks being built, a batch at a
	-- time, so no copy of the whole soup is kept around. blocks that are less
	-- than RUN_GAP vertices apart in the soup are expanded as one run
	local STAGING_VERTICES = 12 * 1024 * 1024
	local RUN_GAP = 16384
	local rt_state = {
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

	local function ensure_staging(vertex_count)
		if rt_state.staging and rt_state.staging_capacity >= vertex_count then return end

		if rt_state.staging then rt_state.staging:Remove() end

		rt_state.staging_capacity = math.max(STAGING_VERTICES, vertex_count)
		rt_state.staging = render.CreateBuffer{
			byte_size = rt_state.staging_capacity * 12,
			buffer_usage = {
				"storage_buffer",
				"shader_device_address",
				"acceleration_structure_build_input_read_only_khr",
			},
			memory_property = {"device_local"},
			label = "scene_bvh_blas_staging",
		}
		rt_state.staging_address = rt_state.staging:GetDeviceAddress()
	end

	local function by_first_vertex(a, b)
		return a.first_vertex < b.first_vertex
	end

	local expand_runs = {}

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

	local instance_matrix = Matrix44()
	local identity_matrix = Matrix44()

	local function get_instance(vc)
		local index = vc.block_index - 1

		if index >= rt_state.instance_capacity then
			local capacity = math.max(math.ceil(rt_state.instance_capacity * 1.5), index + 1, 1024)
			local instances = VkInstanceArray(capacity)
			ffi.copy(instances, rt_state.instances, rt_state.instance_capacity * INSTANCE_BYTE_SIZE)
			rt_state.instances = instances
			rt_state.instance_capacity = capacity
		end

		return rt_state.instances[index]
	end

	local function write_instance(vc)
		local instance = get_instance(vc)
		local group = vc.rt_group
		-- the blas of an animated visual is rewritten in world space every frame
		local m = vc.animated and identity_matrix or group.inverse:GetMultiplied(vc.baked_matrix, instance_matrix)
		local t = instance.transform.matrix
		t[0][0], t[0][1], t[0][2], t[0][3] = m.m00, m.m10, m.m20, m.m30
		t[1][0], t[1][1], t[1][2], t[1][3] = m.m01, m.m11, m.m21, m.m31
		t[2][0], t[2][1], t[2][2], t[2][3] = m.m02, m.m12, m.m22, m.m32
		instance.sbrtAndFlags = INSTANCE_FACING_CULL_DISABLE + (
				vc.non_opaque and
				INSTANCE_FORCE_NO_OPAQUE or
				INSTANCE_FORCE_OPAQUE
			)
		-- a hidden block keeps its instance, so instances stay in block order,
		-- but with a mask no ray matches
		instance.customAndMask = (
				vc.hidden and
				0 or
				(
					vc.foliage and
					INSTANCE_MASK_FOLIAGE or
					INSTANCE_MASK_SOLID
				)
			) + vc.tri_base / SOUP_ALIGN
		instance.accelerationStructureReference = group.rt_address
	end

	local function leave_group(vc, frame)
		local group = vc.rt_group
		vc.rt_group = nil
		group.count = group.count - 1

		if group.count == 0 then
			if group.rt_blas then release_blas(group, frame) end

			group.shape.rt_group = nil
		end
	end

	-- Animated blocks: the soup range of a visual with a skeleton is rewritten
	-- by the gpu every frame, from the skinned vertex arrays, in world space.
	-- the range keeps the materials, uvs and emissive values of its cpu bake.
	-- a job is a block: its range, the per soup triangle source table (three
	-- vertex indices and a slot) and its slots (the vertex array and the world
	-- matrix of each entry)
	local ANIMATE_LOCAL_SIZE = 64
	local ANIMATE_ROW = 65535
	local ANIMATE_MAX_JOBS = 2048
	local ANIMATE_MAX_SLOTS = 32768
	local ANIMATE_RING = 4
	local AnimateJob = ffi.typeof([[struct {
		uint32_t source[2];
		uint32_t slots[2];
		uint32_t first;
		uint32_t count;
		uint32_t group_start;
		uint32_t padding;
	}]])
	local AnimateSlot = ffi.typeof([[struct {
		uint32_t vertices[2];
		uint32_t padding[2];
		float matrix[12];
	}]])
	local AnimateJobPtr = ffi.typeof("$ *", AnimateJob)
	local AnimateSlotPtr = ffi.typeof("$ *", AnimateSlot)
	local animate_uint64_ptr = ffi.typeof("uint64_t *")
	local animate = {job_base = 0, job_count = 0, group_count = 0}
	-- animated blocks farther than this from the camera keep the pose they had, in meters
	scene_bvh.ANIMATION_DISTANCE = 150
	-- the first blas builds of animated visuals allowed per frame, in triangles. every animated visual has a blas of
	-- its own, so a crowd appearing at once is hundreds of builds, which the gpu can't be pre-empted in for long enough
	-- to lose the device. the rest wait for the frames after
	scene_bvh.ANIMATED_BLAS_BUILD_TRIANGLES = 500000

	local function get_animate_pipeline()
		if animate.pipeline then return animate.pipeline end

		animate.jobs = render.CreateBuffer{
			byte_size = ffi.sizeof(AnimateJob) * ANIMATE_MAX_JOBS * ANIMATE_RING,
			buffer_usage = {"storage_buffer"},
			memory_property = {"host_visible", "host_coherent"},
			label = "scene_bvh_animate_jobs",
		}
		animate.job_data = ffi.cast(AnimateJobPtr, animate.jobs:Map())
		animate.slots = render.CreateBuffer{
			byte_size = ffi.sizeof(AnimateSlot) * ANIMATE_MAX_SLOTS * ANIMATE_RING,
			buffer_usage = {"storage_buffer", "shader_device_address"},
			memory_property = {"host_visible", "host_coherent"},
			label = "scene_bvh_animate_slots",
		}
		animate.slot_data = ffi.cast(AnimateSlotPtr, animate.slots:Map())
		animate.slot_address = animate.slots:GetDeviceAddress()
		animate.pipeline = EasyPipeline.Compute{
			name = "scene_bvh_animate",
			dont_create_framebuffers = true,
			DescriptorSetCount = render.GetSwapchainImageCount(),
			LocalSize = {ANIMATE_LOCAL_SIZE, 1, 1},
			storage_buffers = {{binding_index = 0}, {binding_index = 1, count = SOUP_CHUNKS}},
			block = {
				{"job_base", "int"},
				{"job_count", "int"},
				{"group_count", "int"},
				write = function(self, block)
					block.job_base = animate.job_base
					block.job_count = animate.job_count
					block.group_count = animate.group_count
					return block
				end,
			},
			custom_declarations = ([=[
					layout(scalar, set = 0, binding = 1) buffer SceneBvhAnimateSoup {
						float f[];
					} soup[%d];
					struct AnimateJob {
						uvec2 source;
						uvec2 slots;
						uint first;
						uint count;
						uint group_start;
						uint padding;
					};
					layout(scalar, set = 0, binding = 0) readonly buffer SceneBvhAnimateJobs {
						AnimateJob jobs[];
					};
					struct AnimateSlot {
						uvec2 vertices;
						uvec2 padding;
						float m[12];
					};
					layout(buffer_reference, scalar) readonly buffer AnimateSource { uvec4 s[]; };
					layout(buffer_reference, scalar) readonly buffer AnimateSlots { AnimateSlot s[]; };
					layout(buffer_reference, scalar) readonly buffer AnimateVertices { float v[]; };
					]=]):format(SOUP_CHUNKS),
			shader = [[
				#define SOUP_CHUNK ]] .. SOUP_CHUNK_TRIS .. [[u
				// polygon_3d's vertex has 17 floats, the position first
				vec3 animate_position(AnimateVertices vertices, AnimateSlot slot, uint index) {
					uint o = index * 17u;
					vec3 p = vec3(vertices.v[o], vertices.v[o + 1u], vertices.v[o + 2u]);
					return p.x * vec3(slot.m[0], slot.m[1], slot.m[2]) +
						p.y * vec3(slot.m[3], slot.m[4], slot.m[5]) +
						p.z * vec3(slot.m[6], slot.m[7], slot.m[8]) +
						vec3(slot.m[9], slot.m[10], slot.m[11]);
				}

				void main() {
					uint flat_group = gl_WorkGroupID.y * ]] .. ANIMATE_ROW .. [[u + gl_WorkGroupID.x;

					if (flat_group >= uint(compute.group_count)) return;

					// the last job that starts at or before this workgroup
					uint low = 0u;
					uint high = uint(compute.job_count);

					while (high - low > 1u) {
						uint middle = (low + high) / 2u;

						if (jobs[uint(compute.job_base) + middle].group_start <= flat_group) low = middle; else high = middle;
					}

					AnimateJob job = jobs[uint(compute.job_base) + low];
					uint i = (flat_group - job.group_start) * ]] .. ANIMATE_LOCAL_SIZE .. [[u + gl_LocalInvocationID.x;

					if (i >= job.count) return;

					uvec4 source = AnimateSource(packUint2x32(job.source)).s[i];
					AnimateSlot slot = AnimateSlots(packUint2x32(job.slots)).s[source.w];
					AnimateVertices vertices = AnimateVertices(packUint2x32(slot.vertices));
					vec3 p0 = animate_position(vertices, slot, source.x);
					vec3 p1 = animate_position(vertices, slot, source.y);
					vec3 p2 = animate_position(vertices, slot, source.z);
					vec3 e1 = p1 - p0;
					vec3 e2 = p2 - p0;
					vec3 n = cross(e1, e2);
					float length_n = length(n);
					n = length_n > 1e-12 ? n / length_n : vec3(0.0, 1.0, 0.0);
					uint tri = job.first + i;
					uint chunk = tri / SOUP_CHUNK;
					uint o = (tri - chunk * SOUP_CHUNK) * 16u;
					soup[nonuniformEXT(chunk)].f[o] = p0.x;
					soup[nonuniformEXT(chunk)].f[o + 1u] = p0.y;
					soup[nonuniformEXT(chunk)].f[o + 2u] = p0.z;
					soup[nonuniformEXT(chunk)].f[o + 3u] = e1.x;
					soup[nonuniformEXT(chunk)].f[o + 4u] = e1.y;
					soup[nonuniformEXT(chunk)].f[o + 5u] = e1.z;
					soup[nonuniformEXT(chunk)].f[o + 6u] = e2.x;
					soup[nonuniformEXT(chunk)].f[o + 7u] = e2.y;
					soup[nonuniformEXT(chunk)].f[o + 8u] = e2.z;
					soup[nonuniformEXT(chunk)].f[o + 9u] = n.x;
					soup[nonuniformEXT(chunk)].f[o + 10u] = n.y;
					soup[nonuniformEXT(chunk)].f[o + 11u] = n.z;
				}
			]],
		}
		return animate.pipeline
	end

	-- rewrites the soup ranges of the animated blocks that are shown. returns
	-- whether any were, in which case their blas needs to follow
	function scene_bvh.RewriteAnimatedBlocks(cmd)
		if not next(scene_bvh.animated_blocks) then return false end

		local pipeline = get_animate_pipeline()
		local ring = system.GetFrameNumber() % ANIMATE_RING
		animate.job_base = ring * ANIMATE_MAX_JOBS
		local slot_base = ring * ANIMATE_MAX_SLOTS
		local camera = import("goluwa/render3d/render3d.lua").GetCamera():GetPosition()
		local reach = scene_bvh.ANIMATION_DISTANCE
		local jobs = 0
		local slots_used = 0
		local groups = 0

		for vc in pairs(scene_bvh.animated_blocks) do
			local shape = vc.shape

			if
				vc.block_index and
				vc.baked_matrix and
				not vc.hidden and
				shape.animated_source and
				jobs < ANIMATE_MAX_JOBS and
				slots_used + vc.slot_count <= ANIMATE_MAX_SLOTS and
				math.abs((vc.world_aabb[0] + vc.world_aabb[3]) / 2 - camera.x) < reach and
				math.abs((vc.world_aabb[1] + vc.world_aabb[4]) / 2 - camera.y) < reach and
				math.abs((vc.world_aabb[2] + vc.world_aabb[5]) / 2 - camera.z) < reach
			then
				-- a block is rewritten when its skinned vertices or an entry's world matrix changed, or its
				-- range was written by the cpu since
				local animator = vc.slots[1].entry.entity.VisualOwner.Owner.animator
				local version = animator and animator.skin_version or 0
				local needs = vc.animate_dirty ~= false or vc.animate_version ~= version
				local cached = vc.animate_matrices

				if not cached or vc.animate_matrix_slots ~= vc.slot_count then
					cached = DoubleArray(vc.slot_count * 12)
					vc.animate_matrices = cached
					vc.animate_matrix_slots = vc.slot_count
					needs = true
				end

				for i = 1, vc.slot_count do
					local m = vc.slots[i].entry.transform:GetWorldMatrix()
					local o = (i - 1) * 12
					local x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11 = m.m00, m.m01, m.m02, m.m10, m.m11, m.m12, m.m20, m.m21, m.m22, m.m30, m.m31, m.m32

					if
						cached[o] ~= x0 or
						cached[o + 1] ~= x1 or
						cached[o + 2] ~= x2 or
						cached[o + 3] ~= x3 or
						cached[o + 4] ~= x4 or
						cached[o + 5] ~= x5 or
						cached[o + 6] ~= x6 or
						cached[o + 7] ~= x7 or
						cached[o + 8] ~= x8 or
						cached[o + 9] ~= x9 or
						cached[o + 10] ~= x10 or
						cached[o + 11] ~= x11
					then
						needs = true
						cached[o], cached[o + 1], cached[o + 2], cached[o + 3] = x0, x1, x2, x3
						cached[o + 4], cached[o + 5], cached[o + 6], cached[o + 7] = x4, x5, x6, x7
						cached[o + 8], cached[o + 9], cached[o + 10], cached[o + 11] = x8, x9, x10, x11
					end
				end

				if needs then
					for i = 1, vc.slot_count do
						local entry_slot = animate.slot_data[slot_base + slots_used + i - 1]
						ffi.cast(animate_uint64_ptr, entry_slot.vertices)[0] = vc.slots[i].vertex_buffer:GetBuffer():GetDeviceAddress()

						for k = 0, 11 do
							entry_slot.matrix[k] = cached[(i - 1) * 12 + k]
						end
					end

					local job = animate.job_data[animate.job_base + jobs]
					ffi.cast(animate_uint64_ptr, job.source)[0] = shape.animated_source:GetDeviceAddress()
					ffi.cast(animate_uint64_ptr, job.slots)[0] = animate.slot_address + (slot_base + slots_used) * ffi.sizeof(AnimateSlot)
					job.first = vc.tri_base
					job.count = shape.total
					job.group_start = groups
					groups = groups + math.ceil(shape.total / ANIMATE_LOCAL_SIZE)
					slots_used = slots_used + vc.slot_count
					jobs = jobs + 1
					vc.animate_frame = system.GetFrameNumber()
					vc.animate_dirty = false
					vc.animate_version = version
				end
			end
		end

		scene_bvh.animated_job_count = jobs

		if jobs == 0 then return false end

		local slot = math.max(render.GetCurrentFrame(), 1)
		scene_bvh.BindTriangleBuffer(pipeline, slot, 1, scene_bvh.triangle_buffer)
		pipeline:UpdateDescriptorSet("storage_buffer", slot, 0, 0, animate.jobs, animate.jobs:GetSize())
		-- the skinned vertex arrays were written earlier in this command buffer, and earlier frames may still read the soup
		cmd:PipelineBarrier{srcStage = "all_commands", dstStage = "compute", memoryBarrier = true}
		animate.job_count = jobs
		animate.group_count = groups
		gpu_timing.BeginScope(cmd, "animate_soup")
		pipeline:Dispatch(cmd, math.min(groups, ANIMATE_ROW), math.ceil(groups / ANIMATE_ROW), 1, slot)
		gpu_timing.EndScope(cmd, "animate_soup")
		cmd:PipelineBarrier{srcStage = "compute", dstStage = "all_commands", memoryBarrier = true}
		return true
	end

	-- builds the blas of every visual whose soup range was rewritten since its
	-- blas was built, in batches that fit the scratch budget, and keeps the
	-- instance list (one per block, in block order) in step
	local function build_blases(cmd, frame)
		local device = render.GetDevice()
		local changed = scene_bvh.changed_blocks
		scene_bvh.changed_blocks = {}
		rt_state.blas_backlog = false

		-- the first look covers every block
		if not changed then
			changed = {}

			for _, vc in ipairs(scene_bvh.blocks) do
				changed[vc] = true
			end
		end

		-- the groups that need a blas built, and the visuals whose instance
		-- waits for it
		local dirty = {}
		local waiting = {}

		for vc in pairs(changed) do
			local group = vc.rt_group

			if not vc.block_index then
				if group then leave_group(vc, frame) end
			elseif vc.baked_matrix then
				local shape = vc.shape

				if group and group.shape ~= shape then
					leave_group(vc, frame)
					group = nil
				end

				if not group then
					group = shape.rt_group

					if not group then
						group = {shape = shape, count = 0, allow_update = vc.animated}
						shape.rt_group = group
					end

					group.count = group.count + 1
					vc.rt_group = group
				end

				if group.rt_blas then
					write_instance(vc)
				else
					waiting[#waiting + 1] = vc

					if not group.builder then
						group.builder = vc
						group.inverse = vc.baked_matrix:GetInverse(Matrix44())
						group.first_vertex = vc.first_vertex
						group.vertex_count = vc.vertex_count
						group.total = vc.total
						dirty[#dirty + 1] = group
					end
				end
			end
		end

		-- the blas of an animated visual is updated in place from its rewritten soup range
		local has_update = false

		if scene_bvh.animated_frame == frame then
			for vc in pairs(scene_bvh.animated_blocks) do
				local group = vc.rt_group

				if group and group.rt_blas and group.allow_update and vc.animate_frame == frame and not group.update then
					group.update = true
					group.first_vertex = vc.first_vertex
					group.vertex_count = vc.vertex_count
					group.total = vc.total
					dirty[#dirty + 1] = group
					has_update = true
				end
			end
		end

		local built_triangles = 0
		local postponed

		for i = 1, #dirty do
			local group = dirty[i]

			if group.rt_blas or not group.allow_update then goto keep end

			if built_triangles > 0 and built_triangles + group.total > scene_bvh.ANIMATED_BLAS_BUILD_TRIANGLES then
				group.builder = nil
				postponed = postponed or {}
				postponed[group] = true
				dirty[i] = false

				goto next_group
			end

			built_triangles = built_triangles + group.total

			::keep::

			::next_group::
		end

		if postponed then
			local kept = {}

			for i = 1, #dirty do
				if dirty[i] then kept[#kept + 1] = dirty[i] end
			end

			dirty = kept
			local still_waiting = {}

			for _, vc in ipairs(waiting) do
				if postponed[vc.rt_group] then
					scene_bvh.changed_blocks[vc] = true
					-- the slot may still hold a released block's blas, which nothing may trace until its own is built
					local instance = get_instance(vc)
					instance.accelerationStructureReference = 0
					instance.customAndMask = 0
				else
					still_waiting[#still_waiting + 1] = vc
				end
			end

			waiting = still_waiting
			rt_state.blas_backlog = true
		end

		if not dirty[1] then return false end

		local n = #dirty
		local geometries = VkGeometryArray(n)
		local infos = VkBuildInfoArray(n)
		local ranges = VkRangeInfoArray(n)
		local range_pointers = VkRangePointerArray(n)
		local scratch_offsets = {}
		table.sort(dirty, by_first_vertex)
		rt_state.scratch_alignment = rt_state.scratch_alignment or
			math.max(
				tonumber(device.physical_device:GetAccelerationStructureProperties().minAccelerationStructureScratchOffsetAlignment),
				1
			)
		local scratch_alignment = rt_state.scratch_alignment
		local scratch_total = 0
		local largest = 0
		local largest_vertices = 0

		for i = 1, n do
			local vc = dirty[i]
			local update = vc.update
			vc.update = nil
			local flags = vc.allow_update and
				BUILD_PREFER_FAST_TRACE + BUILD_ALLOW_UPDATE or
				BUILD_PREFER_FAST_TRACE
			local geometry = geometries[i - 1]
			fill_triangle_geometry(geometry, 0, vc.vertex_count)
			local scratch_size

			if update then
				scratch_size = vc.rt_scratch_size
			else
				local storage_size, update_scratch_size
				storage_size, scratch_size, update_scratch_size = AccelerationStructure.QueryBuildSize(
					device,
					{
						type = "bottom_level_khr",
						flags = flags,
						geometryCount = 1,
						pGeometries = geometry,
						maxPrimitiveCount = vc.total,
					}
				)
				-- an update needs its own scratch size, which is not the build's
				vc.rt_scratch_size = vc.allow_update and math.max(scratch_size, update_scratch_size) or scratch_size
				scratch_size = vc.rt_scratch_size
				local pool, offset, units = pool_alloc(storage_size)
				vc.rt_pool = pool
				vc.rt_offset = offset
				vc.rt_units = units
				vc.rt_blas = AccelerationStructure.New(
					device,
					"bottom_level_khr",
					pool.buffer,
					offset * BLAS_ALIGN,
					units * BLAS_ALIGN
				)
				vc.rt_address = vc.rt_blas:Data()
				vc.builder = nil
			end

			scratch_size = math.ceil(scratch_size / scratch_alignment) * scratch_alignment
			scratch_offsets[i] = scratch_size
			scratch_total = scratch_total + scratch_size
			largest = math.max(largest, scratch_size)
			largest_vertices = math.max(largest_vertices, vc.vertex_count)
			local info = infos[i - 1]
			info.sType = 1000150000
			info.type = 1
			info.flags = flags
			info.mode = update and BUILD_MODE_UPDATE or 0

			if update then info.srcAccelerationStructure = vc.rt_blas.ptr[0] end

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

		-- and so may the blas that is about to be updated by rays of an earlier frame
		if has_update then
			cmd:PipelineBarrier{
				srcStage = "all_commands",
				dstStage = "acceleration_structure_build_khr",
				memoryBarrier = true,
			}
		end

		for i = 1, #waiting do
			write_instance(waiting[i])
		end

		ensure_staging(largest_vertices)
		local staging = rt_state.staging
		local capacity = rt_state.staging_capacity
		local pipeline = rt_state.expand_pipeline
		local slot = math.max(render.GetCurrentFrame(), 1)
		scene_bvh.BindTriangleBuffer(pipeline, slot, 1, scene_bvh.triangle_buffer)
		pipeline:UpdateDescriptorSet("storage_buffer", slot, 0, 0, staging, staging:GetSize())
		local first = 0

		while first < n do
			local count = 0
			local used = 0
			local run_count = 0
			local run_first, run_end, run_base = 0, 0, 0

			while first + count < n do
				local j = first + count + 1
				local vc = dirty[j]
				local v_first = vc.first_vertex
				local v_end = v_first + vc.vertex_count
				local extend = count > 0 and v_first - run_end <= RUN_GAP
				local stage_end

				if extend then
					stage_end = run_base + v_end - run_first
				elseif count > 0 then
					stage_end = run_base + run_end - run_first + vc.vertex_count
				else
					stage_end = vc.vertex_count
				end

				if used + scratch_offsets[j] > scratch_size or stage_end > capacity then
					break
				end

				if not extend then
					if count > 0 then
						expand_runs[run_count + 1] = run_first
						expand_runs[run_count + 2] = run_end
						expand_runs[run_count + 3] = run_base
						run_count = run_count + 3
						run_base = run_base + run_end - run_first
					end

					run_first = v_first
				end

				run_end = v_end
				geometries[j - 1].geometry.triangles.vertexData = rt_state.staging_address + (run_base + v_first - run_first) * 12
				infos[j - 1].scratchData.deviceAddress = rt_state.scratch_address + used
				used = used + scratch_offsets[j]
				count = count + 1
			end

			expand_runs[run_count + 1] = run_first
			expand_runs[run_count + 2] = run_end
			expand_runs[run_count + 3] = run_base
			run_count = run_count + 3
			-- the previous batch may still be reading the staging buffer
			cmd:PipelineBarrier{
				srcStage = "acceleration_structure_build_khr",
				dstStage = "compute",
				bufferBarriers = {
					{
						buffer = staging,
						srcAccessMask = "acceleration_structure_read_khr",
						dstAccessMask = "shader_write",
					},
				},
			}

			for i = 1, run_count, 3 do
				expand_range(
					cmd,
					pipeline,
					slot,
					expand_runs[i],
					expand_runs[i + 1] - expand_runs[i],
					expand_runs[i] - expand_runs[i + 2]
				)
			end

			cmd:PipelineBarrier{
				srcStage = "compute",
				dstStage = "acceleration_structure_build_khr",
				bufferBarriers = {
					{
						buffer = staging,
						srcAccessMask = "shader_write",
						dstAccessMask = "acceleration_structure_read_khr",
					},
				},
			}
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
		local animated = false

		-- once per frame: the soup ranges of animated blocks are rewritten and their blas updated, which the tlas has to follow
		if scene_bvh.animated_frame ~= frame then
			animated = scene_bvh.RewriteAnimatedBlocks(cmd)
			scene_bvh.animated_frame = frame
		end

		-- a backlog of blas builds is another reason to build, but not twice in a frame: the tlas slots are
		-- handed out by frame
		if rt_state.blas_backlog and rt_state.built_frame ~= frame then animated = true end

		if
			not animated and
			rt_state.built_version == scene_bvh.soup_version and
			rt_state.built_top_version == scene_bvh.top_version and
			rt_state.current_slot
		then
			rt_state.current_slot.last_used = frame
			return rt_state.current_slot.tlas
		end

		rt_state.built_frame = frame
		process_pending_free(frame)
		gpu_timing.BeginScope(cmd, "rt_build")

		if build_blases(cmd, frame) then
			blas_barrier(cmd, "acceleration_structure_build_khr")
		end

		local count = #scene_bvh.blocks
		local slot = get_free_tlas_slot(frame, count)
		build_tlas(cmd, slot, count)
		-- compute and fragment shaders trace it with ray queries (ddgi, ssr, water)
		cmd:PipelineBarrier{
			srcStage = "acceleration_structure_build_khr",
			dstStage = {"ray_tracing_shader_khr", "compute", "fragment"},
			bufferBarriers = {
				{
					buffer = slot.buffer,
					srcAccessMask = "acceleration_structure_write_khr",
					dstAccessMask = "acceleration_structure_read_khr",
				},
			},
		}
		gpu_timing.EndScope(cmd, "rt_build")
		slot.last_used = frame
		rt_state.current_slot = slot
		rt_state.built_version = scene_bvh.soup_version
		rt_state.built_top_version = scene_bvh.top_version
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
			dstStage = {"ray_tracing_shader_khr", "compute", "fragment"},
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

	function scene_bvh.Initialize()
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
		scene_bvh.CreateExpander(rt_state)
	end
end

Visual = import("goluwa/entities/components/visual.lua")
return scene_bvh
