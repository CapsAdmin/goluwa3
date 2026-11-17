local ffi = require("ffi")
local pvars = import("goluwa/cli/pvars.lua")
local system = import("goluwa/system.lua")
local thread_pool = import("goluwa/thread_pool.lua")
local vertex_layout = import("goluwa/render3d/vertex_layout.lua")
local index_pool = import("goluwa/render3d/index_pool.lua")
local store = import("goluwa/render3d/scene/store.lua")
local format = import("goluwa/render3d/cluster_lod/format.lua")
local cluster_lod = {}
local RecordPointer = ffi.typeof("$ *", format.ClusterRecord)
local JOB = [=[
	local input = ...
	return import("goluwa/render3d/cluster_lod/build.lua").Build(input)
]=]
pvars.StartGroup("Rendering", "Cluster LOD", {store = false})
local enabled = pvars.Setup2{
	key = "r_cluster_lod",
	default = true,
	help = "draw large static models as a cut through a cluster hierarchy picked per frame on the gpu, detail follows the screen space error instead of discrete levels",
}
local pixel_error = pvars.Setup2{
	key = "r_cluster_lod_error",
	default = 1,
	help = "the screen space error in pixels a cluster of a lower level may have before the finer level takes over, higher draws fewer triangles",
}
local min_triangles = pvars.Setup2{
	key = "r_cluster_lod_min_triangles",
	default = 4096,
	integer = true,
	help = "models with fewer triangles are not turned into a cluster hierarchy",
}
pvars.EndGroup()
local record_table
local states = setmetatable({}, {__mode = "k"})
cluster_lod.listeners = {}

function cluster_lod.OnReady(listener)
	cluster_lod.listeners[#cluster_lod.listeners + 1] = listener
end

function cluster_lod.IsMaterialEligible(material)
	return not (
		material:IsTransparent() or
		material:MarchesRelief() or
		material:HasVertexAnimation() or
		material:GetAlphaTest() or
		material.Decal
	)
end

function cluster_lod.GetStatus(polygon3d)
	return states[polygon3d]
end

function cluster_lod.IsEnabled()
	return enabled:Get()
end

function cluster_lod.GetPixelError()
	return pixel_error:Get()
end

function cluster_lod.GetTable()
	record_table = record_table or
		store.CreateTable{
			name = "clusters",
			ctype = format.ClusterRecord,
			capacity = 4096,
			staged = true,
		}
	return record_table
end

local function finish(polygon3d, state, job)
	if job.err then
		wlog("cluster lod: %s", tostring(job.err))
		state.failed = true
		return
	end

	local meta, blob = job.meta, job.blob

	if not meta or not polygon3d then
		state.failed = true
		return
	end

	local count, index_count = meta.cluster_count, meta.index_count
	local records = ffi.cast(RecordPointer, blob.ptr)
	local first_index = index_pool.AllocateRange(
		polygon3d,
		ffi.cast("const uint32_t *", blob.ptr + count * format.RECORD_SIZE),
		index_count
	)
	local rows = cluster_lod.GetTable()
	local base = rows:AllocRange(count)
	local destination = rows:Get() + base
	ffi.copy(destination, records, count * format.RECORD_SIZE)

	for i = 0, count - 1 do
		destination[i].first_index = destination[i].first_index + first_index
	end

	rows:TouchRange(base, count)
	state.ready = true
	state.base = base
	state.count = count
	state.leaf_count = meta.leaf_count
	state.levels = meta.levels
	state.seconds = meta.seconds
	state.guard = ffi.gc(ffi.new("char[1]"), function()
		rows:FreeRange(base, count)
	end)
	for _, listener in ipairs(cluster_lod.listeners) do
		listener(polygon3d, state)
	end
end

function cluster_lod.Request(polygon3d)
	local state = states[polygon3d]

	if state ~= nil then return state end

	if not enabled:Get() then return nil end

	local packed = polygon3d.packed

	if
		not packed or
		polygon3d.Dynamic or
		packed.index_count < min_triangles:Get() * 3 or
		packed.vertex_count == 0
	then
		states[polygon3d] = false
		return false
	end

	local index_size = ffi.sizeof(packed.indices) / packed.index_count

	if index_size ~= 2 and index_size ~= 4 then
		states[polygon3d] = false
		return false
	end

	local vertices = ffi.string(packed.vertices, packed.vertex_count * vertex_layout.Stride)
	local indices = ffi.string(packed.indices, packed.index_count * index_size)
	local state = {ready = false}
	states[polygon3d] = state
	local weak = setmetatable({polygon3d}, {__mode = "v"})
	state.job = thread_pool.Run(
		JOB,
		{
			vertices = vertices,
			vertex_count = packed.vertex_count,
			indices = indices,
			index_count = packed.index_count,
			index_size = index_size,
		},
		#vertices + #indices
	)

	state.job:OnDone(function(job)
		state.job = nil
		finish(weak[1], state, job)
	end)

	return state
end

function cluster_lod.GetStats()
	local stats = {ready = 0, pending = 0, failed = 0, ineligible = 0, clusters = 0, seconds = 0}

	for _, state in pairs(states) do
		if not state then
			stats.ineligible = stats.ineligible + 1
		elseif state.ready then
			stats.ready = stats.ready + 1
			stats.clusters = stats.clusters + state.count
			stats.seconds = stats.seconds + state.seconds
		elseif state.failed then
			stats.failed = stats.failed + 1
		else
			stats.pending = stats.pending + 1
		end
	end

	return stats
end

function cluster_lod.GetState(polygon3d)
	local state = states[polygon3d]
	return state and state.ready and state or nil
end

return cluster_lod
