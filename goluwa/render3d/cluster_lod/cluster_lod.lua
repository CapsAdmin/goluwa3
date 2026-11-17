local ffi = require("ffi")
local pvars = import("goluwa/cli/pvars.lua")
local system = import("goluwa/system.lua")
local thread_pool = import("goluwa/thread_pool.lua")
local vertex_layout = import("goluwa/render3d/vertex_layout.lua")
local index_pool = import("goluwa/render3d/index_pool.lua")
local store = import("goluwa/render3d/scene/store.lua")
local format = import("goluwa/render3d/cluster_lod/format.lua")
local IndexBuffer = import("goluwa/render/index_buffer.lua")
local commands = import("goluwa/cli/commands.lua")
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
local rt_pixel_error = pvars.Setup2{
	key = "r_cluster_lod_rt_error",
	default = 2,
	help = "the screen space error in pixels the ray traced copies of a cluster model may have, the ray traced scene switches to a coarser cut of the hierarchy at the distance where its error projects to this many pixels (at 1080p and 60 degrees), higher traces coarser models sooner",
	callback = function()
		for _, listener in ipairs(cluster_lod.rt_listeners or {}) do
			listener()
		end
	end,
}
local debug_mode = pvars.Setup2{
	key = "r_cluster_lod_debug",
	default = 0,
	integer = true,
	help = "1 tints the models drawn through the cluster path green and the ones still waiting for their hierarchy yellow",
	callback = function()
		for _, listener in ipairs(cluster_lod.debug_listeners or {}) do
			listener()
		end
	end,
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
cluster_lod.rt_listeners = {}
cluster_lod.debug_listeners = {}
local MAX_CUTS = 3
local BEND_BOUNDS = 0.3
local CUT_REDUCTION = 2
local MIN_CUT_TRIANGLES = 128
local REFERENCE_PIXELS_PER_RADIAN = 1080 / (2 * math.tan(math.rad(60) / 2))
cluster_lod.REFERENCE_PIXELS_PER_RADIAN = REFERENCE_PIXELS_PER_RADIAN

function cluster_lod.OnReady(listener)
	cluster_lod.listeners[#cluster_lod.listeners + 1] = listener
end

function cluster_lod.OnDebugChanged(listener)
	cluster_lod.debug_listeners[#cluster_lod.debug_listeners + 1] = listener
end

function cluster_lod.GetDebugMode()
	return debug_mode:Get()
end

function cluster_lod.OnRTErrorChanged(listener)
	cluster_lod.rt_listeners[#cluster_lod.rt_listeners + 1] = listener
end

function cluster_lod.IsMaterialEligible(material)
	return not (material:IsTransparent() or material:MarchesRelief() or material.Decal)
end

function cluster_lod.GetRTPixelError()
	return rt_pixel_error:Get()
end

function cluster_lod.GetCutDistance(cut, world_scale)
	return cut.error * world_scale * REFERENCE_PIXELS_PER_RADIAN / rt_pixel_error:Get()
end

function cluster_lod.DescribePolygon(polygon3d)
	local state = states[polygon3d]

	if state and state.ready then return "clustered" end

	if state and state.failed then return "its hierarchy build failed" end

	if state then return "waiting for its hierarchy to be built" end

	local packed = polygon3d.packed

	if polygon3d.Dynamic then return "dynamic mesh" end

	if not packed then
		return "no packed vertex data (only Source 2, .mesh and cgf models keep it)"
	end

	if packed.index_count < min_triangles:Get() * 3 then
		return string.format(
			"%d triangles, under r_cluster_lod_min_triangles %d",
			packed.index_count / 3,
			min_triangles:Get()
		)
	end

	local index_size = ffi.sizeof(packed.indices) / packed.index_count

	if index_size ~= 2 and index_size ~= 4 then return "unsupported index type" end

	return "eligible, no row has asked for it yet"
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

function cluster_lod.BuildCuts(records, indices, count)
	local events = {}
	local leaf_triangles = 0

	for i = 0, count - 1 do
		local r = records[i]
		local triangles = r.index_count / 3

		if r.error == 0 then leaf_triangles = leaf_triangles + triangles end

		events[#events + 1] = {r.error, triangles}

		if r.parent_error < format.NO_PARENT_ERROR then
			events[#events + 1] = {r.parent_error, -triangles}
		end
	end

	table.sort(events, function(a, b)
		return a[1] < b[1]
	end)

	local cuts = {}
	local target = leaf_triangles / CUT_REDUCTION
	local running = 0
	local i = 1

	while i <= #events and #cuts < MAX_CUTS do
		local error = events[i][1]

		while i <= #events and events[i][1] == error do
			running = running + events[i][2]
			i = i + 1
		end

		if error > 0 and running <= target and running >= MIN_CUT_TRIANGLES then
			local data = ffi.new("uint32_t[?]", running * 3)
			local at = 0

			for c = 0, count - 1 do
				local r = records[c]

				if r.error <= error and error < r.parent_error then
					ffi.copy(data + at, indices + r.first_index, r.index_count * 4)
					at = at + r.index_count
				end
			end

			cuts[#cuts + 1] = {
				error = error,
				triangles = running,
				index_buffer = IndexBuffer.FromPointer(data, running * 3, "uint32_t", "cluster_cut"),
			}
			target = running / CUT_REDUCTION
		end
	end

	return cuts
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
		index_count,
		3
	)
	local rows = cluster_lod.GetTable()
	local base = rows:AllocRange(count)
	local destination = rows:Get() + base
	ffi.copy(destination, records, count * format.RECORD_SIZE)

	for i = 0, count - 1 do
		destination[i].first_index = destination[i].first_index + first_index
	end

	local bend_height = polygon3d:GetBendHeight()

	if bend_height > 0 then
		for i = 0, count - 1 do
			destination[i].bounds[3] = destination[i].bounds[3] + bend_height * BEND_BOUNDS
		end
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
	state.cuts = cluster_lod.BuildCuts(
		records,
		ffi.cast("const uint32_t *", blob.ptr + count * format.RECORD_SIZE),
		count
	)

	for _, listener in ipairs(cluster_lod.listeners) do
		listener(
			polygon3d,
			state,
			records,
			ffi.cast("const uint32_t *", blob.ptr + count * format.RECORD_SIZE),
			first_index
		)
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
	local stats = {
		ready = 0,
		pending = 0,
		failed = 0,
		ineligible = 0,
		clusters = 0,
		seconds = 0,
		with_cuts = 0,
		cuts = 0,
		cut_rows = 0,
	}

	for _, state in pairs(states) do
		if not state then
			stats.ineligible = stats.ineligible + 1
		elseif state.ready then
			stats.ready = stats.ready + 1
			stats.clusters = stats.clusters + state.count
			stats.seconds = stats.seconds + state.seconds

			if state.cuts[1] then stats.with_cuts = stats.with_cuts + 1 end

			for _, cut in ipairs(state.cuts) do
				stats.cuts = stats.cuts + 1

				if cut.row then stats.cut_rows = stats.cut_rows + 1 end
			end
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

commands.Add("cluster_lod_why=string|nil", function(filter)
	local report = import("goluwa/render3d/scene/draw.lua").GetClusterReport()

	if filter == "" then filter = nil end

	if filter then filter = filter:lower() end

	local lines = {}

	for _, entry in ipairs(report) do
		if not filter or entry.name:lower():find(filter, 1, true) then
			lines[#lines + 1] = entry
		end
	end

	table.sort(lines, function(a, b)
		return a.triangles * a.rows > b.triangles * b.rows
	end)

	if filter then
		for i = 1, math.min(#lines, 100) do
			local entry = lines[i]
			logf(
				"[cluster_lod_why] %s: %d triangles, %d rows: %s\n",
				entry.name,
				entry.triangles,
				entry.rows,
				entry.reason
			)
		end

		logf("[cluster_lod_why] %d meshes match %q\n", #lines, filter)
		return
	end

	local summary, order = {}, {}

	for _, entry in ipairs(lines) do
		local total = summary[entry.reason]

		if not total then
			total = {meshes = 0, rows = 0, triangles = 0}
			summary[entry.reason] = total
			order[#order + 1] = entry.reason
		end

		total.meshes = total.meshes + 1
		total.rows = total.rows + entry.rows
		total.triangles = total.triangles + entry.triangles * entry.rows
	end

	table.sort(order, function(a, b)
		return summary[a].triangles > summary[b].triangles
	end)

	for _, reason in ipairs(order) do
		local total = summary[reason]
		logf(
			"[cluster_lod_why] %7d triangles in %5d meshes, %5d rows: %s\n",
			total.triangles,
			total.meshes,
			total.rows,
			reason
		)
	end

	local shown = 0

	for _, entry in ipairs(lines) do
		if entry.reason ~= "clustered" and shown < 20 then
			shown = shown + 1
			logf(
				"[cluster_lod_why] %s: %d triangles, %d rows: %s\n",
				entry.name,
				entry.triangles,
				entry.rows,
				entry.reason
			)
		end
	end
end)

return cluster_lod
