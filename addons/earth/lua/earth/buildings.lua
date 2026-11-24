local ffi = require("ffi")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local thread_pool = import("goluwa/thread_pool.lua")
local threads = import("goluwa/bindings/threads.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Material = import("goluwa/render3d/material.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local geo = import("lua/earth/geo.lua")
local overture_tiles = import("lua/earth/overture_tiles.lua")
local building_mesh = import("lua/earth/building_mesh.lua")
local layer_texture = import("goluwa/terrain/layer_texture.lua")
local MeshShape = import("goluwa/physics/shapes/mesh.lua")
local RigidBody = import("goluwa/physics/rigid_body.lua")
local vertex_layout = import("goluwa/render3d/vertex_layout.lua")
local AABB = import("goluwa/structs/aabb.lua")
local buildings = {}
buildings.ATTRIBUTION = "Buildings: Overture Maps Foundation (OpenStreetMap contributors ODbL, Microsoft, Google, Esri)"
local ZOOM = 14
local RADIUS = 3000
local KEEP_RADIUS = 4500
local UPDATE_INTERVAL = 0.25
local GRID_SIZE = 33
local GRID_MARGIN = 0.1
local MAX_BUILDING = 2
-- the pixel size of the photo the roofs take their colour from; where no imagery source is about this sharp the roofs
-- keep a colour picked from a palette
local PHOTO_METERS = 1.7
-- one bay of a facade over a wall's uv (building_mesh: a bay across, a floor up): plaster, a window with a frame and
-- a sill, a band at the floor; white, so the wall's vertex colour is the plaster's, the glass dark in any colour
local FACADE = {
	Size = 256,
	Header = [=[
float facade_window(vec2 uv) {
	vec2 d = abs(uv - vec2(0.5, 0.55)) - vec2(0.24, 0.24);
	return max(d.x, d.y);
}
]=],
	Height = [=[
float layer_height(vec2 uv) {
	uv = fract(uv);
	float window = facade_window(uv);
	float frame = smoothstep(0.0, 0.004, -window) * (1.0 - smoothstep(-0.03, -0.026, window));
	float glass = smoothstep(0.03, 0.026, -window);
	float band = 1.0 - smoothstep(0.02, 0.03, uv.y);
	return 0.8 - glass * 0.6 - frame * 0.2 + band * 0.1 + tile_fbm(uv, 8.0, 3, 0.5) * 0.04;
}
]=],
	Albedo = [=[
	vec2 f = fract(uv);
	float window = facade_window(f);
	float glass = smoothstep(0.0, -0.004, window + 0.03);
	float frame = smoothstep(0.0, -0.004, window) * (1.0 - glass);
	float band = 1.0 - smoothstep(0.02, 0.03, f.y);
	float dirt = tile_fbm(uv, 6.0, 4, 0.5) * 0.12 + smoothstep(0.3, 0.0, f.y) * 0.06;
	vec3 plaster = vec3(1.0 - dirt - band * 0.15);
	vec3 col = mix(plaster, vec3(0.75), frame);
	col = mix(col, vec3(0.06, 0.07, 0.08) + 0.05 * f.y, glass);
	return vec4(col, 1.0);
]=],
	Depth = 0.6,
}
local Index32Array = ffi.typeof("uint32_t[?]")
local FloatArray = ffi.typeof("float[?]")
-- buildings get colliders within COLLIDER_RADIUS of the camera or a dynamic body (asleep too, or it wakes when the
-- collider under it goes), kept to COLLIDER_KEEP_RADIUS, found through a grid of COLLIDER_CELL cells over each tile
local COLLIDER_RADIUS = 100
local COLLIDER_KEEP_RADIUS = 150
local COLLIDER_CELL = 32
-- the most colliders made in one update, the rest come in the next ones
local COLLIDER_BUDGET = 8

local function cell_key(cx, cz)
	return (cx + 32768) * 65536 + cz + 32768
end

local tiles_source = overture_tiles.Get("buildings", ZOOM)
local wall_material
local roof_material

local function get_path(tile)
	return tiles_source:GetPath(tile.x, tile.y)
end

local function create_primitive(parent, name, material, data, sections, prefix, vertex_count, index_count, aabb)
	if index_count == 0 then return end

	local core = ffi.new("uint8_t[?]", vertex_count * vertex_layout.CoreStride)
	ffi.copy(core, data + sections[prefix .. "_core"], vertex_count * vertex_layout.CoreStride)
	local extras = ffi.new("uint8_t[?]", vertex_count * vertex_layout.ExtrasStride)
	ffi.copy(
		extras,
		data + sections[prefix .. "_extras"],
		vertex_count * vertex_layout.ExtrasStride
	)
	local indices = Index32Array(index_count)
	ffi.copy(indices, data + sections[prefix .. "_indices"], index_count * 4)
	local entity = Entity.New{Name = parent:GetName() .. "_" .. name, Parent = parent}
	entity:AddComponent("transform")
	local polygon = Polygon3D.New()
	polygon:UploadVertexArray(
		nil,
		vertex_count,
		indices,
		index_count,
		false,
		"owned",
		AABB(aabb[1], aabb[2], aabb[3], aabb[4], aabb[5], aabb[6]),
		"uint32_t",
		{core = core, extras = extras}
	)
	local primitive = entity:AddComponent("visual_primitive")
	primitive:SetPolygon3D(polygon)
	primitive:SetMaterial(material)
end

local function create_tile_entity(tile, meta, blob)
	tile.entity = Entity.New{
		Name = string.format("earth_buildings_%d_%d", tile.x, tile.y),
		Parent = buildings.root,
	}
	tile.entity:AddComponent("transform"):SetPosition(Vec3(tile.origin_x, 0, tile.origin_z))
	local visual = tile.entity:AddComponent("visual")
	visual:SetCullDistance(KEEP_RADIUS * 2)
	local data = ffi.cast("const uint8_t *", blob.ptr)
	local sections = meta.sections
	create_primitive(
		tile.entity,
		"walls",
		wall_material,
		data,
		sections,
		"wall",
		meta.wall_vertices,
		meta.wall_indices,
		meta.wall_aabb
	)
	create_primitive(
		tile.entity,
		"roofs",
		roof_material,
		data,
		sections,
		"roof",
		meta.roof_vertices,
		meta.roof_indices,
		meta.roof_aabb
	)
	visual:BuildAABB()
	-- the collision data stays in the job's result, which the collector does not count, until the tile goes
	tile.blob = blob
	local positions = ffi.cast("const float *", data + sections.positions)
	local indices = ffi.cast("const uint32_t *", data + sections.indices)
	local ranges = ffi.cast("const uint32_t *", data + sections.ranges)
	local bounds = ffi.cast("const float *", data + sections.bounds)
	local cells = {}
	local min_x, min_z, max_x, max_z = math.huge, math.huge, -math.huge, -math.huge

	for part = 0, meta.buildings - 1 do
		min_x, min_z = math.min(min_x, bounds[part * 4]), math.min(min_z, bounds[part * 4 + 1])
		max_x, max_z = math.max(max_x, bounds[part * 4 + 2]), math.max(max_z, bounds[part * 4 + 3])

		for cz = math.floor(bounds[part * 4 + 1] / COLLIDER_CELL), math.floor(bounds[part * 4 + 3] / COLLIDER_CELL) do
			for cx = math.floor(bounds[part * 4] / COLLIDER_CELL), math.floor(bounds[part * 4 + 2] / COLLIDER_CELL) do
				local key = cell_key(cx, cz)
				cells[key] = cells[key] or {}
				list.insert(cells[key], part)
			end
		end
	end

	tile.collision = {
		buildings = meta.buildings,
		positions = positions,
		indices = indices,
		ranges = ranges,
		bounds = bounds,
		cells = cells,
		colliders = {},
		min_x = min_x - COLLIDER_KEEP_RADIUS,
		min_z = min_z - COLLIDER_KEEP_RADIUS,
		max_x = max_x + COLLIDER_KEEP_RADIUS,
		max_z = max_z + COLLIDER_KEEP_RADIUS,
	}
end

local function create_collider(tile, part)
	local collision = tile.collision
	local positions, indices, ranges = collision.positions, collision.indices, collision.ranges
	local vertices = {}
	local triangles = {}

	for range = 0, 1 do
		local o = part * 8 + range * 4
		local vertex_first, vertex_count = ranges[o], ranges[o + 1]
		local offset = #vertices - vertex_first

		for i = vertex_first, vertex_first + vertex_count - 1 do
			vertices[#vertices + 1] = Vec3(positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2])
		end

		for i = ranges[o + 2], ranges[o + 2] + ranges[o + 3] - 1 do
			triangles[#triangles + 1] = indices[i] + offset
		end
	end

	local entity = Entity.New{Name = tile.entity:GetName() .. "_collider_" .. part, Parent = tile.entity}
	entity:AddComponent("transform")
	entity:AddComponent(
		"rigid_body",
		{
			Shape = MeshShape.New{Vertices = vertices, indices = triangles},
			MotionType = "static",
			WorldGeometry = true,
			Friction = 0.8,
		}
	)
	return entity
end

local function build_input(tile)
	local source = buildings.source
	local north, west = geo.FromMercator(tile.x - GRID_MARGIN, tile.y - GRID_MARGIN, ZOOM, 1)
	local south, east = geo.FromMercator(tile.x + 1 + GRID_MARGIN, tile.y + 1 + GRID_MARGIN, ZOOM, 1)
	tile.photo_state = tile.photo_state or
		{south = south, west = west, north = north, east = east, meters = PHOTO_METERS}
	local photo = source:RequestPhoto(tile.photo_state)

	if photo == nil then return end

	local dlat, dlon = (north - south) / (GRID_SIZE - 1), (east - west) / (GRID_SIZE - 1)
	local grid = FloatArray(GRID_SIZE * GRID_SIZE)

	for j = 0, GRID_SIZE - 1 do
		for i = 0, GRID_SIZE - 1 do
			local h = source:SampleLatLonHeight(south + j * dlat, west + i * dlon)

			if not h then return end

			grid[j * GRID_SIZE + i] = h
		end
	end

	return {
		path = get_path(tile),
		x = tile.x,
		y = tile.y,
		zoom = ZOOM,
		anchor_lat = source.Anchor.lat,
		anchor_lon = source.Anchor.lon,
		origin_x = tile.origin_x,
		origin_z = tile.origin_z,
		grid_size = GRID_SIZE,
		grid_lat0 = south,
		grid_lon0 = west,
		grid_dlat = dlat,
		grid_dlon = dlon,
		grid = ffi.string(grid, GRID_SIZE * GRID_SIZE * 4),
		photo = photo or nil,
	}
end

local function build_tile(tile)
	local input = build_input(tile)

	if not input then return end

	tile.state = "building"
	buildings.building = buildings.building + 1

	thread_pool.Run(building_mesh.JOB, input, math.huge):OnDone(function(job)
		buildings.building = buildings.building - 1

		if tile.removed then return end

		if job.err then
			llog("earth: buildings %d/%d: %s", tile.x, tile.y, tostring(job.err))
			tile.state = "failed"
			return
		end

		if job.meta.buildings > 0 then
			create_tile_entity(tile, job.meta, job.blob)
		elseif job.blob then
			threads.release_blob(job.blob)
		end

		tile.state = "built"
	end)
end

local function remove_tile(tile)
	if tile.entity then tile.entity:Remove() end

	if tile.blob then threads.release_blob(tile.blob) end

	tile.entity = nil
	tile.collision = nil
	tile.blob = nil
	tile.removed = true
end

local function load_tile(tile)
	tile.state = "loading"

	tiles_source:Fetch(tile.x, tile.y, function(err)
		if tile.removed then return end

		if err then
			llog("earth: buildings %d/%d failed: %s", tile.x, tile.y, err)
			tile.state = "failed"
			return
		end

		tile.state = "fetched"
	end)
end

local anchors = {}
local keep = {}
local missing = {}

local function by_distance(a, b)
	return a.distance < b.distance
end

local function update_colliders(camera)
	list.clear(anchors)
	list.clear(missing)
	anchors[1] = camera

	for _, body in ipairs(RigidBody.Instances) do
		if body:IsDynamic() then anchors[#anchors + 1] = body:GetPosition() end
	end

	for _, tile in pairs(buildings.tiles) do
		local collision = tile.collision

		if collision then
			local bounds, colliders = collision.bounds, collision.colliders
			table.clear(keep)

			for _, anchor in ipairs(anchors) do
				local x, z = anchor.x - tile.origin_x, anchor.z - tile.origin_z

				if
					x > collision.min_x and
					x < collision.max_x and
					z > collision.min_z and
					z < collision.max_z
				then
					for cz = math.floor((z - COLLIDER_KEEP_RADIUS) / COLLIDER_CELL), math.floor((z + COLLIDER_KEEP_RADIUS) / COLLIDER_CELL) do
						for cx = math.floor((x - COLLIDER_KEEP_RADIUS) / COLLIDER_CELL), math.floor((x + COLLIDER_KEEP_RADIUS) / COLLIDER_CELL) do
							local cell = collision.cells[cell_key(cx, cz)]

							if cell then
								for _, part in ipairs(cell) do
									local o = part * 4
									local dx = math.max(bounds[o] - x, x - bounds[o + 2], 0)
									local dz = math.max(bounds[o + 1] - z, z - bounds[o + 3], 0)
									local distance = dx * dx + dz * dz

									if distance < COLLIDER_KEEP_RADIUS * COLLIDER_KEEP_RADIUS then
										keep[part] = true

										if not colliders[part] and distance < COLLIDER_RADIUS * COLLIDER_RADIUS then
											missing[#missing + 1] = {tile = tile, part = part, distance = distance}
										end
									end
								end
							end
						end
					end
				end
			end

			for part, entity in pairs(colliders) do
				if not keep[part] then
					entity:Remove()
					colliders[part] = nil
				end
			end
		end
	end

	table.sort(missing, by_distance)

	for i = 1, math.min(#missing, COLLIDER_BUDGET) do
		local entry = missing[i]
		local colliders = entry.tile.collision.colliders

		if not colliders[entry.part] then
			colliders[entry.part] = create_collider(entry.tile, entry.part)
		end
	end
end

local function nearest_first(a, b)
	return a.distance < b.distance
end

local function update()
	local source = buildings.source
	local camera = render3d.GetCamera():GetPosition()
	local lat, lon = source:WorldToLatLon(camera.x, camera.z)
	local cx, cy = geo.ToMercator(lat, lon, ZOOM, 1)
	local tile_size = geo.GetPixelSize(lat, ZOOM, 1)
	local reach = math.ceil(RADIUS / tile_size) + 1
	local tiles = buildings.tiles

	for key, tile in pairs(tiles) do
		local dx = math.max(math.abs(tile.x + 0.5 - cx) - 0.5, 0) * tile_size
		local dy = math.max(math.abs(tile.y + 0.5 - cy) - 0.5, 0) * tile_size

		if dx * dx + dy * dy > KEEP_RADIUS * KEEP_RADIUS then
			remove_tile(tile)
			tiles[key] = nil
		end
	end

	local wanted = {}

	for ty = math.floor(cy) - reach, math.floor(cy) + reach do
		for tx = math.floor(cx) - reach, math.floor(cx) + reach do
			local dx = math.max(math.abs(tx + 0.5 - cx) - 0.5, 0) * tile_size
			local dy = math.max(math.abs(ty + 0.5 - cy) - 0.5, 0) * tile_size
			local distance = dx * dx + dy * dy

			if distance <= RADIUS * RADIUS then
				local key = ty * 2 ^ ZOOM + tx

				if not tiles[key] then
					local origin_x, origin_z = source:LatLonToWorld(geo.FromMercator(tx + 0.5, ty + 0.5, ZOOM, 1))
					tiles[key] = {x = tx, y = ty, origin_x = origin_x, origin_z = origin_z, state = "new"}
				end

				wanted[#wanted + 1] = {tile = tiles[key], distance = distance}
			end
		end
	end

	table.sort(wanted, nearest_first)
	update_colliders(camera)

	for _, entry in ipairs(wanted) do
		local tile = entry.tile

		if tile.state == "new" then
			load_tile(tile)
		elseif tile.state == "fetched" and buildings.building < MAX_BUILDING then
			build_tile(tile)
		end
	end
end

function buildings.Start(source)
	buildings.Stop()
	buildings.source = source
	buildings.tiles = {}
	buildings.building = 0
	buildings.root = Entity.New{Name = "earth_buildings"}
	buildings.root:SetTransient(true)
	buildings.root:AddComponent("transform")

	if not wall_material then
		wall_material = Material.New()
		wall_material:SetVertexTint(true)
		wall_material:SetRoughnessMultiplier(0.9)
		wall_material:SetAlbedoTexture(layer_texture.BakeAlbedo(FACADE))
		wall_material:SetNormalTexture(layer_texture.BakeNormal(FACADE))
		roof_material = Material.New()
		roof_material:SetVertexTint(true)
		roof_material:SetRoughnessMultiplier(0.8)
	end

	local next_update = 0

	event.AddListener("Update", "earth_buildings", function()
		local now = system.GetElapsedTime()

		if now < next_update then return end

		next_update = now + UPDATE_INTERVAL
		update()
	end)
end

function buildings.SetSource(source)
	buildings.Start(source)
end

function buildings.Stop()
	event.RemoveListener("Update", "earth_buildings")

	if buildings.tiles then
		for _, tile in pairs(buildings.tiles) do
			remove_tile(tile)
		end
	end

	if buildings.root then buildings.root:Remove() end

	buildings.root = nil
	buildings.tiles = nil
	buildings.source = nil
end

function buildings.GetStats()
	local stats = {built = 0, pending = 0, failed = 0}

	for _, tile in pairs(buildings.tiles or {}) do
		local key = tile.state == "built" and
			"built" or
			tile.state == "failed" and
			"failed" or
			"pending"
		stats[key] = stats[key] + 1
	end

	return stats
end

return buildings
