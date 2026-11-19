local ffi = require("ffi")
local gltf = import("goluwa/codecs/gltf.lua")
local fs = import("goluwa/filesystem/fs.lua")
local threads = import("goluwa/bindings/threads.lua")
local bake_scene = {}
local WORKER = [[
	local work = ...
	local ffi = require("ffi")
	local gltf = import("goluwa/codecs/gltf.lua")
	local bake = import("goluwa/render3d/cluster_stream/bake.lua")
	local buffers = {}

	for index, path in pairs(work.buffer_paths) do
		local file = assert(io.open(path, "rb"))
		local content = file:read("*a")
		file:close()
		local c = ffi.new("uint8_t[?]", #content)
		ffi.copy(c, content, #content)
		buffers[index] = c
	end

	local function read(index)
		if not index then return nil end

		return gltf.ReadAccessor(work.gltf, index, buffers)
	end

	local position = read(work.attributes.POSITION)
	local normal = read(work.attributes.NORMAL)
	local uv = read(work.attributes.TEXCOORD_0)
	local tangent = read(work.attributes.TANGENT)
	local indices = read(work.indices)
	buffers = nil
	local started = os.clock()
	local blob, stats = bake.Bake{
		position = position.data,
		normal = normal and normal.data,
		uv = uv and uv.data,
		tangent = tangent and tangent.data,
		vertex_count = position.count,
		indices = indices.data,
		index_count = indices.count,
		flip_v = work.flip_v,
		flip_winding = true,
		min_level = work.min_level,
	}
	local temporary = work.out_path .. ".partial"
	local file = assert(io.open(temporary, "wb"))
	file:write(blob)
	file:close()
	assert(os.rename(temporary, work.out_path))
	stats.seconds = os.clock() - started
	stats.levels = nil
	collectgarbage()
	return stats
]]

-- the file a primitive's clusters are cached in, named after its source buffer so a changed source gets a new file
function bake_scene.GetCachePath(cache_dir, gltf_data, mesh_index, primitive_index)
	local raw = gltf_data.raw
	local primitive = raw.meshes[mesh_index].primitives[primitive_index]
	local accessor = raw.accessors[primitive.indices + 1]
	local view = raw.bufferViews[accessor.bufferView + 1]
	local compression = view.extensions and view.extensions.EXT_meshopt_compression
	local buffer = raw.buffers[(compression and compression.buffer or view.buffer) + 1]
	local name = (
		buffer.uri or
		gltf_data.path
	):match("([^/]+)$"):gsub("%.[^.]*$", ""):gsub("[^%w_%-]", "_")
	return string.format("%s%s_m%d_p%d.vgc", cache_dir, name, mesh_index - 1, primitive_index - 1)
end

local function collect_accessor(raw, subset, index, buffer_paths, base_dir)
	if not index then return end

	local accessor = raw.accessors[index + 1]
	subset.accessors[index + 1] = accessor
	local view = raw.bufferViews[accessor.bufferView + 1]
	subset.bufferViews[accessor.bufferView + 1] = view
	local compression = view.extensions and view.extensions.EXT_meshopt_compression
	local buffer_index = compression and compression.buffer or view.buffer
	local buffer = raw.buffers[buffer_index + 1]
	buffer_paths[buffer_index + 1] = base_dir .. assert(buffer.uri, "embedded buffers are not supported")
end

-- bakes every primitive of a gltf that has no cache file yet, blocking until done. options: cache_dir, min_level,
-- threads, filter(mesh_index, primitive_index, triangles) to bake a subset, log(line)
function bake_scene.Bake(path, options)
	options = options or {}
	local cache_dir = options.cache_dir
	assert(fs.create_directory_recursive(cache_dir))
	local gltf_data = assert(gltf.Load(path, {lazy_meshes = true}))
	local raw = gltf_data.raw
	local base_dir = path:match("^(.*/)") or ""
	local queue = {}
	local total_triangles = 0

	for mesh_index, mesh in ipairs(raw.meshes) do
		for primitive_index, primitive in ipairs(mesh.primitives) do
			local triangles = raw.accessors[primitive.indices + 1].count / 3
			local out_path = bake_scene.GetCachePath(cache_dir, gltf_data, mesh_index, primitive_index)

			if
				(
					primitive.mode or
					4
				) == 4 and
				not fs.exists(out_path)
				and
				(
					not options.filter or
					options.filter(mesh_index, primitive_index, triangles)
				)
			then
				local subset = {accessors = {}, bufferViews = {}}
				local buffer_paths = {}

				for _, accessor_index in pairs(primitive.attributes) do
					collect_accessor(raw, subset, accessor_index, buffer_paths, base_dir)
				end

				collect_accessor(raw, subset, primitive.indices, buffer_paths, base_dir)
				queue[#queue + 1] = {
					triangles = triangles,
					work = {
						gltf = subset,
						buffer_paths = buffer_paths,
						attributes = primitive.attributes,
						indices = primitive.indices,
						out_path = out_path,
						min_level = options.min_level or 0,
						flip_v = primitive.material ~= nil and
							gltf.MaterialNeedsVFlip(gltf_data, primitive.material),
					},
				}
				total_triangles = total_triangles + triangles
			end
		end
	end

	table.sort(queue, function(a, b)
		return a.triangles > b.triangles
	end)

	local log = options.log or print
	log(
		string.format(
			"cluster bake: %d primitives, %.1fM triangles to bake into %s",
			#queue,
			total_triangles / 1e6,
			cache_dir
		)
	)

	if #queue == 0 then return end

	local pool = threads.new_pool(
		[[
		local work = ...
		return assert(load(work.source, "=cluster_bake"))(work.input)
	]],
		math.min(options.threads or 16, #queue)
	)
	local inflight = {}
	local next_item = 1
	local done_triangles, done_count, bytes = 0, 0, 0
	local started = os.clock()
	local wall_started = os.time()
	local last_report = 0

	while next_item <= #queue or next(inflight) do
		for thread_id = 1, pool.num_threads do
			if inflight[thread_id] and pool:is_done(thread_id) then
				local item = inflight[thread_id]
				inflight[thread_id] = nil
				local stats, err = pool:wait(thread_id)

				if stats then
					done_triangles = done_triangles + item.triangles
					done_count = done_count + 1
					bytes = bytes + stats.bytes
				else
					log("cluster bake failed for " .. item.work.out_path .. ": " .. tostring(err))
				end
			end

			if not inflight[thread_id] and next_item <= #queue then
				local item = queue[next_item]
				next_item = next_item + 1
				inflight[thread_id] = item
				pool:submit(thread_id, {source = WORKER, input = item.work})
			end
		end

		local elapsed = os.time() - wall_started

		if elapsed - last_report >= 10 then
			last_report = elapsed
			local rate = done_triangles / math.max(elapsed, 1)
			log(
				string.format(
					"cluster bake: %d/%d primitives, %.1f/%.1fM triangles, %.1f MB written, %.0fk tris/s, eta %.0f min",
					done_count,
					#queue,
					done_triangles / 1e6,
					total_triangles / 1e6,
					bytes / 1e6,
					rate / 1e3,
					rate > 0 and (total_triangles - done_triangles) / rate / 60 or 0
				)
			)
		end

		threads.sleep(5)
	end

	pool:shutdown()
	log(
		string.format(
			"cluster bake done: %d primitives, %.1fM triangles, %.1f MB in %d s",
			done_count,
			done_triangles / 1e6,
			bytes / 1e6,
			os.time() - wall_started
		)
	)
end

return bake_scene
