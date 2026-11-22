local ffi = require("ffi")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local thread_pool = import("goluwa/thread_pool.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Material = import("goluwa/render3d/material.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local geo = import("lua/earth/geo.lua")
local overture_tiles = import("lua/earth/overture_tiles.lua")
local building_mesh = import("lua/earth/building_mesh.lua")
local layer_texture = import("goluwa/terrain/layer_texture.lua")
-- Overture's buildings (OpenStreetMap, Microsoft's and Google's machine learned footprints, Esri) as blocks: the
-- footprints of the zoom 14 tiles around the camera extruded to their height, or their floors, or a guess by class
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
local VertexType = Polygon3D.VertexType
local VERTEX_SIZE = ffi.sizeof(VertexType(1))
local Index32Array = ffi.typeof("uint32_t[?]")
local FloatArray = ffi.typeof("float[?]")
local tiles_source = overture_tiles.Get("buildings", ZOOM)
local wall_material
local roof_material

local function get_path(tile)
	return tiles_source:GetPath(tile.x, tile.y)
end

local function create_primitive(
	parent,
	name,
	material,
	blob,
	vertex_offset,
	vertex_count,
	index_offset,
	index_count
)
	if index_count == 0 then return end

	local vertices = VertexType(vertex_count)
	ffi.copy(vertices, blob + vertex_offset, vertex_count * VERTEX_SIZE)
	local indices = Index32Array(index_count)
	ffi.copy(indices, blob + index_offset, index_count * 4)
	local entity = Entity.New{Name = parent:GetName() .. "_" .. name, Parent = parent}
	entity:AddComponent("transform")
	local polygon = Polygon3D.New()
	polygon:UploadVertexArray(vertices, vertex_count, indices, index_count, false, "owned", nil, "uint32_t")
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
	local vertex_bytes = (meta.wall_vertices + meta.roof_vertices) * VERTEX_SIZE
	create_primitive(
		tile.entity,
		"walls",
		wall_material,
		data,
		0,
		meta.wall_vertices,
		vertex_bytes,
		meta.wall_indices
	)
	create_primitive(
		tile.entity,
		"roofs",
		roof_material,
		data,
		meta.wall_vertices * VERTEX_SIZE,
		meta.roof_vertices,
		vertex_bytes + meta.wall_indices * 4,
		meta.roof_indices
	)
	visual:BuildAABB()
end

-- the job's input, nil while the ground under the tile or the photo over it is not loaded
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

		create_tile_entity(tile, job.meta, job.blob)
		tile.state = "built"
	end)
end

local function remove_tile(tile)
	if tile.entity then tile.entity:Remove() end

	tile.entity = nil
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

-- the tiles are built again around the new origin
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

-- built, pending (on its way: fetching, waiting for the ground, building) and failed tiles
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
