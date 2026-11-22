local ffi = require("ffi")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local thread_pool = import("goluwa/thread_pool.lua")
local threads = import("goluwa/bindings/threads.lua")
local fs = import("goluwa/filesystem/fs.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Material = import("goluwa/render3d/material.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local layer_texture = import("goluwa/terrain/layer_texture.lua")
local geo = import("lua/earth/geo.lua")
local overture_tiles = import("lua/earth/overture_tiles.lua")
local road_mesh = import("lua/earth/road_mesh.lua")
local tint_mesh = import("lua/earth/tint_mesh.lua")
-- Overture's roads near the camera as ribbons over the terrain (road_mesh.lua), in cells whose heights are read back
-- from the terrain itself, so a ribbon lies on the ground the terrain draws; farther away the roads are the terrain's
-- painted ones (road_grid.lua)
local roads = {}
local ZOOM = 14
-- road tiles are decoded out to RADIUS plus a tile, cells are built within RADIUS and kept to KEEP_RADIUS
local RADIUS = 600
local KEEP_RADIUS = 800
local CELL = 128
-- the heights read around a cell, so ribbons of the lines in it that reach out of it still have ground under them
local MARGIN = 16
local UPDATE_INTERVAL = 0.25
local MAX_BUILDING = 4
local MAX_HEIGHTS = 8
local tiles_source = overture_tiles.Get("transportation", ZOOM)
local VERTEX_SIZE = tint_mesh.VERTEX_SIZE
local VertexType = Polygon3D.VertexType
local Index32Array = ffi.typeof("uint32_t[?]")
-- one texture repeat: across the road 0 to 1, along it V_PERIOD meters, the dashes 3 of every 12
local MARKINGS = [=[
float road_line(float u, float center, float width) {
	return 1.0 - smoothstep(width * 0.5 - texel, width * 0.5 + texel, abs(u - center));
}

float road_dash(float v) {
	return 1.0 - smoothstep(0.25 - texel * 2.0, 0.25, fract(v * 2.0));
}

float road_paint(vec2 uv) {
	float paint = 0.0;
#if ROAD_STYLE >= 2
	paint = max(paint, road_line(uv.x, 0.5, ROAD_STYLE == 4 ? 0.012 : 0.02) * (ROAD_STYLE == 4 ? 1.0 : road_dash(uv.y)));
#endif
#if ROAD_STYLE >= 3
	paint = max(paint, road_line(uv.x, 0.04, 0.012));
	paint = max(paint, road_line(uv.x, 0.96, 0.012));
#endif
#if ROAD_STYLE == 4
	paint = max(paint, road_line(uv.x, 0.27, 0.008) * road_dash(uv.y));
	paint = max(paint, road_line(uv.x, 0.73, 0.008) * road_dash(uv.y));
#endif
	return paint * (0.75 + 0.25 * smoothstep(-0.2, 0.3, tile_fbm(uv, vec2(12.0), 4, 0.5)));
}

float road_grain(vec2 uv) {
	return tile_fbm(uv, vec2(256.0), 3, 0.5);
}
]=]
local HEIGHT = [=[
float layer_height(vec2 uv) {
	return 0.5 + road_grain(uv) * 0.3 + road_paint(uv) * 0.15;
}
]=]
-- marked roads carry their asphalt in the texture (their vertices are white), a plain road is near white and takes
-- its class's colour from its vertices
local ALBEDO = [=[
	float grain = road_grain(uv);
#if ROAD_STYLE == 1
	return vec4(vec3(0.92 + grain * 0.12) * (0.95 + 0.1 * tile_fbm(uv, vec2(6.0), 3, 0.5)), 1.0);
#else
	vec3 asphalt = vec3(0.07, 0.07, 0.068) * (0.9 + grain * 0.25) * (0.95 + 0.1 * tile_fbm(uv, vec2(6.0), 3, 0.5));
	return vec4(mix(asphalt, vec3(0.72, 0.72, 0.68), road_paint(uv)), 1.0);
#endif
]=]
local materials

local function get_materials()
	if materials then return materials end

	materials = {}

	for style = 1, road_mesh.STYLES do
		local config = {
			Size = 1024,
			Header = "#define ROAD_STYLE " .. style .. "\n" .. MARKINGS,
			Height = HEIGHT,
			Albedo = ALBEDO,
			Depth = 0.08,
		}
		local material = Material.New()
		material:SetVertexTint(true)
		material:SetRoughnessMultiplier(0.85)
		material:SetAlbedoTexture(layer_texture.BakeAlbedo(config))
		material:SetNormalTexture(layer_texture.BakeNormal(config))
		materials[style] = material
	end

	return materials
end

local function cell_key(cx, cz)
	return (cx + 32768) * 65536 + cz + 32768
end

local function create_cell_entity(cell, meta, blob)
	local entity = Entity.New{
		Name = string.format("earth_road_mesh_%d_%d", cell.x, cell.z),
		Parent = roads.root,
	}
	entity:AddComponent("transform"):SetPosition(Vec3(cell.x * CELL, 0, cell.z * CELL))
	local visual = entity:AddComponent("visual")
	visual:SetCullDistance(KEEP_RADIUS * 2)
	visual:SetCastShadows(false)
	local data = ffi.cast("const uint8_t *", blob.ptr)
	local offset = 0

	for style, counts in ipairs(meta.styles) do
		local vertex_count, index_count = counts[1], counts[2]

		if index_count > 0 then
			local vertices = VertexType(vertex_count)
			ffi.copy(vertices, data + offset, vertex_count * VERTEX_SIZE)
			local indices = Index32Array(index_count)
			ffi.copy(indices, data + offset + vertex_count * VERTEX_SIZE, index_count * 4)
			local child = Entity.New{Name = entity:GetName() .. "_" .. style, Parent = entity}
			child:AddComponent("transform")
			local polygon = Polygon3D.New()
			polygon:UploadVertexArray(vertices, vertex_count, indices, index_count, false, "owned", nil, "uint32_t")
			local primitive = child:AddComponent("visual_primitive")
			primitive:SetPolygon3D(polygon)
			primitive:SetMaterial(get_materials()[style])
		end

		offset = offset + vertex_count * VERTEX_SIZE + index_count * 4
	end

	visual:BuildAABB()
	return entity
end

-- the lines near a cell from the decoded tiles, as Decode's floats; nil while a tile over it is not decoded
local function gather_lines(cell)
	local min_x, min_z = cell.x * CELL - MARGIN, cell.z * CELL - MARGIN
	local max_x, max_z = min_x + CELL + MARGIN * 2, min_z + CELL + MARGIN * 2
	local tiles = {}

	for _, tile in pairs(roads.tiles) do
		if
			tile.max_x >= min_x and
			tile.min_x <= max_x and
			tile.max_z >= min_z and
			tile.min_z <= max_z
		then
			if tile.state ~= "decoded" and tile.state ~= "failed" then return end

			tiles[#tiles + 1] = tile
		end
	end

	local parts = {}
	local key = cell_key(cell.x, cell.z)

	for _, tile in ipairs(tiles) do
		local bucket = tile.cells and tile.cells[key]

		if bucket then parts[#parts + 1] = table.concat(bucket) end
	end

	return table.concat(parts)
end

-- the terrain bakes the heights around a cell; the chunk may be ready at once, before AcquireChunk returns its key
local function request_heights(cell, lines)
	cell.state = "heights"
	cell.lines = lines
	roads.heights = roads.heights + 1
	local size = CELL + MARGIN * 2
	cell.chunk_key = roads.terrain:AcquireChunk(
		{
			min_x = cell.x * CELL - MARGIN,
			min_z = cell.z * CELL - MARGIN,
			size = size,
			samples = size + 1,
			generation = roads.terrain.Generation,
		},
		function(chunk)
			cell.heights = ffi.string(chunk.heights, (size + 1) * (size + 1) * 4)
		end,
		cell.distance
	)
end

local function release_heights(cell)
	if not cell.chunk_key then return end

	roads.terrain:ReleaseChunk(cell.chunk_key)
	cell.chunk_key = nil
	roads.heights = roads.heights - 1
end

local function build_cell(cell)
	release_heights(cell)
	cell.state = "building"
	roads.building = roads.building + 1
	local generation = cell.generation

	thread_pool.Run(
		road_mesh.JOB,
		{
			min_x = cell.x * CELL,
			min_z = cell.z * CELL,
			size = CELL,
			grid_x = cell.x * CELL - MARGIN,
			grid_z = cell.z * CELL - MARGIN,
			grid_samples = CELL + MARGIN * 2 + 1,
			heights = cell.heights,
			lines = cell.lines,
		},
		math.huge
	):OnDone(function(job)
		roads.building = roads.building - 1

		if cell.removed or cell.generation ~= generation then return end

		if job.err then
			llog("earth: roads %d/%d: %s", cell.x, cell.z, tostring(job.err))
			cell.state = "failed"
			return
		end

		cell.state = "ready"
		cell.job = job
		list.insert(roads.ready, cell)
	end)

	cell.heights = nil
	cell.lines = nil
end

local function decode_tile(tile)
	tile.state = "decoding"
	local source = roads.source

	thread_pool.Run(
		road_mesh.DECODE_JOB,
		{
			data = fs.read_file(tiles_source:GetPath(tile.x, tile.y)) or "",
			x = tile.x,
			y = tile.y,
			zoom = ZOOM,
			anchor_lat = source.Anchor.lat,
			anchor_lon = source.Anchor.lon,
		},
		math.huge
	):OnDone(function(job)
		if tile.removed then return end

		if job.err then
			llog("earth: road lines %d/%d: %s", tile.x, tile.y, tostring(job.err))
			tile.state = "failed"
			return
		end

		-- each line's floats, in a bucket per cell its bounds (with the margin) touch
		local cells = {}

		if job.meta.lines > 0 then
			local floats = ffi.cast("const float *", job.blob.ptr)
			local i = 0

			for _ = 1, job.meta.lines do
				local count = floats[i + 1]
				local min_x, min_z, max_x, max_z = math.huge, math.huge, -math.huge, -math.huge

				for k = 0, count - 1 do
					local x, z = floats[i + 2 + k * 2], floats[i + 3 + k * 2]
					min_x, max_x = math.min(min_x, x), math.max(max_x, x)
					min_z, max_z = math.min(min_z, z), math.max(max_z, z)
				end

				local data = ffi.string(floats + i, (2 + count * 2) * 4)

				for cz = math.floor((min_z - MARGIN) / CELL), math.floor((max_z + MARGIN) / CELL) do
					for cx = math.floor((min_x - MARGIN) / CELL), math.floor((max_x + MARGIN) / CELL) do
						local key = cell_key(cx, cz)
						cells[key] = cells[key] or {}
						list.insert(cells[key], data)
					end
				end

				i = i + 2 + count * 2
			end
		end

		if job.blob then threads.release_blob(job.blob) end

		tile.cells = cells
		tile.state = "decoded"
	end)
end

local function remove_cell(cell)
	if cell.entity then cell.entity:Remove() end

	release_heights(cell)
	cell.entity = nil
	cell.removed = true
end

local function by_distance(a, b)
	return a.distance < b.distance
end

local function update()
	local source = roads.source
	local camera = render3d.GetCamera():GetPosition()
	local lat, lon = source:WorldToLatLon(camera.x, camera.z)
	local cx, cy = geo.ToMercator(lat, lon, ZOOM, 1)
	local tile_size = geo.GetPixelSize(lat, ZOOM, 1)
	local reach = math.ceil(RADIUS / tile_size) + 1
	local tiles = roads.tiles

	for key, tile in pairs(tiles) do
		if
			math.abs(tile.x + 0.5 - cx) > reach + 1 or
			math.abs(tile.y + 0.5 - cy) > reach + 1
		then
			tile.removed = true
			tiles[key] = nil
		end
	end

	for ty = math.floor(cy) - reach, math.floor(cy) + reach do
		for tx = math.floor(cx) - reach, math.floor(cx) + reach do
			local key = ty * 2 ^ ZOOM + tx

			if not tiles[key] then
				local north, west = geo.FromMercator(tx, ty, ZOOM, 1)
				local south, east = geo.FromMercator(tx + 1, ty + 1, ZOOM, 1)
				local x0, z0 = source:LatLonToWorld(north, west)
				local x1, z1 = source:LatLonToWorld(south, east)
				local tile = {
					x = tx,
					y = ty,
					state = "loading",
					min_x = math.min(x0, x1),
					max_x = math.max(x0, x1),
					min_z = math.min(z0, z1),
					max_z = math.max(z0, z1),
				}
				tiles[key] = tile

				tiles_source:Fetch(tx, ty, function(err)
					if tile.removed then return end

					if err then
						llog("earth: road lines %d/%d failed: %s", tx, ty, err)
						tile.state = "failed"
						return
					end

					decode_tile(tile)
				end)
			end
		end
	end

	local cells = roads.cells
	local wanted = {}

	for key, cell in pairs(cells) do
		local dx = math.max(math.abs((cell.x + 0.5) * CELL - camera.x) - CELL / 2, 0)
		local dz = math.max(math.abs((cell.z + 0.5) * CELL - camera.z) - CELL / 2, 0)

		if dx * dx + dz * dz > KEEP_RADIUS * KEEP_RADIUS then
			remove_cell(cell)
			cells[key] = nil
		end
	end

	for z = math.floor((camera.z - RADIUS) / CELL), math.floor((camera.z + RADIUS) / CELL) do
		for x = math.floor((camera.x - RADIUS) / CELL), math.floor((camera.x + RADIUS) / CELL) do
			local dx = math.max(math.abs((x + 0.5) * CELL - camera.x) - CELL / 2, 0)
			local dz = math.max(math.abs((z + 0.5) * CELL - camera.z) - CELL / 2, 0)
			local distance = dx * dx + dz * dz

			if distance <= RADIUS * RADIUS then
				local key = cell_key(x, z)
				local cell = cells[key]

				if not cell then
					cell = {x = x, z = z, state = "new", generation = 0}
					cells[key] = cell
				end

				cell.distance = math.sqrt(distance)
				wanted[#wanted + 1] = cell
			end
		end
	end

	table.sort(wanted, by_distance)

	for _, cell in ipairs(wanted) do
		if cell.state == "heights" and cell.heights and roads.building < MAX_BUILDING then
			build_cell(cell)
		elseif cell.state == "new" and roads.heights < MAX_HEIGHTS then
			local lines = gather_lines(cell)

			if lines == "" then
				cell.state = "empty"
			elseif lines then
				request_heights(cell, lines)
			end
		end
	end
end

-- cells over ground the terrain bakes again are built again (once the old heights are gone); the built ribbons stay
-- until their replacements are in
local function on_invalidated(terrain, box)
	if terrain ~= roads.terrain then return end

	for _, cell in pairs(roads.cells) do
		local min_x, min_z = cell.x * CELL - MARGIN, cell.z * CELL - MARGIN

		if
			min_x < box.max_x and
			box.min_x < min_x + CELL + MARGIN * 2 and
			min_z < box.max_z and
			box.min_z < min_z + CELL + MARGIN * 2
		then
			release_heights(cell)
			cell.heights = nil
			cell.job = nil
			cell.generation = cell.generation + 1
			cell.state = "new"
		end
	end
end

function roads.Start(source, terrain)
	roads.Stop()
	roads.source = source
	roads.terrain = terrain
	roads.tiles = {}
	roads.cells = {}
	roads.ready = {}
	roads.building = 0
	roads.heights = 0
	roads.root = Entity.New{Name = "earth_road_mesh"}
	roads.root:SetTransient(true)
	roads.root:AddComponent("transform")
	local next_update = 0

	event.AddListener("Update", "earth_road_mesh", function()
		-- one built cell becomes entities a frame, so many finishing together do not stall one
		local cell = table.remove(roads.ready, 1)

		if cell and not cell.removed and cell.state == "ready" then
			local job = cell.job
			local indices = 0

			for _, counts in ipairs(job.meta.styles) do
				indices = indices + counts[2]
			end

			if cell.entity then cell.entity:Remove() end

			cell.entity = indices > 0 and create_cell_entity(cell, job.meta, job.blob) or nil

			cell.job = nil
			cell.state = "built"
		end

		local now = system.GetElapsedTime()

		if now < next_update then return end

		next_update = now + UPDATE_INTERVAL
		update()
	end)

	event.AddListener("TerrainInvalidated", "earth_road_mesh", on_invalidated)
end

-- the lines and cells are built again around the new origin
function roads.SetSource(source, terrain)
	roads.Start(source, terrain)
end

function roads.Stop()
	event.RemoveListener("Update", "earth_road_mesh")
	event.RemoveListener("TerrainInvalidated", "earth_road_mesh")

	if roads.cells then
		for _, cell in pairs(roads.cells) do
			remove_cell(cell)
		end
	end

	if roads.tiles then
		for _, tile in pairs(roads.tiles) do
			tile.removed = true
		end
	end

	if roads.root then roads.root:Remove() end

	roads.root = nil
	roads.cells = nil
	roads.tiles = nil
	roads.source = nil
	roads.terrain = nil
end

-- built, pending (waiting for lines, heights or building) and empty cells
function roads.GetStats()
	local stats = {built = 0, pending = 0, empty = 0}

	for _, cell in pairs(roads.cells or {}) do
		local key = cell.state == "built" and
			"built" or
			cell.state == "empty" and
			"empty" or
			"pending"
		stats[key] = stats[key] + 1
	end

	return stats
end

return roads
