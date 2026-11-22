local ffi = require("ffi")
local fs = import("goluwa/filesystem/fs.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local thread_pool = import("goluwa/thread_pool.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local scatter = import("goluwa/render3d/scatter.lua")
local ScatterSet = import("goluwa/render3d/scatter_set.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Material = import("goluwa/render3d/material.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local geo = import("lua/earth/geo.lua")
local overture_tiles = import("lua/earth/overture_tiles.lua")
local object_features = import("lua/earth/object_features.lua")
local bridge_features = import("lua/earth/bridge_features.lua")
local canopy_tiles = import("lua/earth/canopy_tiles.lua")
local EarthSource = import("lua/earth/source.lua")
local prop_models = import("lua/earth/prop_models.lua")
local tint_mesh = import("lua/earth/tint_mesh.lua")
-- the things around the camera that stand at a point or run along a line (object_features.lua) and the bridges of
-- the roads (bridge_features.lua): points are placed instances in the scatter, the rest a mesh per map tile
local objects = {}
objects.ATTRIBUTION = "Objects: Overture Maps Foundation (OpenStreetMap contributors ODbL)"
-- the tiles each job is run on
local SOURCES = {
	{
		tiles = overture_tiles.Get("base", 13),
		job = object_features.JOB,
		radius = 2500,
		keep_radius = 3500,
	},
	{
		tiles = overture_tiles.Get("transportation", 14),
		job = bridge_features.JOB,
		radius = 3000,
		keep_radius = 4500,
	},
}
local UPDATE_INTERVAL = 0.25
local MAX_BUILDING = 2
local HEIGHT_MAX_ZOOM = 14
-- placed prototype settings by kind of instance
objects.KINDS = {
	power_tower = {max_distance = 3000},
	power_pole = {max_distance = 600},
	street_lamp = {max_distance = 500},
	traffic_signals = {max_distance = 400},
	bus_stop = {max_distance = 400},
	mast = {max_distance = 4000},
	tree = {max_distance = 2500, billboard = {radii = 40}, scale = {0.75, 1.25}},
}
local VertexType = Polygon3D.VertexType
local Index32Array = ffi.typeof("uint32_t[?]")
local FloatArray = ffi.typeof("float[?]")
local line_material

local function create_lines(tile, meta, blob)
	if meta.indices == 0 then return end

	local data = ffi.cast("const uint8_t *", blob.ptr)
	local vertices = VertexType(meta.vertices)
	ffi.copy(vertices, data, meta.vertices * tint_mesh.VERTEX_SIZE)
	local indices = Index32Array(meta.indices)
	ffi.copy(indices, data + meta.vertices * tint_mesh.VERTEX_SIZE, meta.indices * 4)
	tile.entity = Entity.New{
		Name = string.format("earth_objects_%d_%d", tile.x, tile.y),
		Parent = objects.root,
	}
	tile.entity:AddComponent("transform"):SetPosition(Vec3(meta.origin_x, 0, meta.origin_z))
	local visual = tile.entity:AddComponent("visual")
	visual:SetCullDistance(tile.source.keep_radius * 2)
	local polygon = Polygon3D.New()
	polygon:UploadVertexArray(vertices, meta.vertices, indices, meta.indices, false, "owned", nil, "uint32_t")
	local child = Entity.New{Name = tile.entity:GetName() .. "_lines", Parent = tile.entity}
	child:AddComponent("transform")
	local primitive = child:AddComponent("visual_primitive")
	primitive:SetPolygon3D(polygon)
	primitive:SetMaterial(line_material)
	visual:BuildAABB()
end

local function hash(x, z)
	local h = math.sin(x * 37.719 + z * 11.137) * 24634.6345
	return h - math.floor(h)
end

local function place_points(tile, points)
	tile.handles = {}

	for kind, list in pairs(points) do
		local protos = objects.protos[kind]

		if protos then
			local settings = objects.KINDS[kind]
			local scale = settings.scale or {1, 1}
			local groups = {}

			for i = 1, #list, 5 do
				local index = math.floor(hash(list[i], list[i + 2]) * #protos) + 1
				groups[index] = groups[index] or {}
				local group = groups[index]
				group[#group + 1] = i
			end

			for index, group in pairs(groups) do
				local matrices = FloatArray(#group * 16)

				for n, i in ipairs(group) do
					local x, y, z, yaw, size = list[i], list[i + 1], list[i + 2], list[i + 3], list[i + 4]
					scatter.WritePlacement(
						matrices,
						(n - 1) * 16,
						x,
						y,
						z,
						size > 0 and size or math.lerp(hash(z, x), scale[1], scale[2]),
						yaw,
						0,
						1,
						0
					)
				end

				tile.handles[#tile.handles + 1] = scatter.AddPlacements(protos[index], matrices, #group)
			end
		end
	end
end

-- the job's input, nil while the ground under the tile is not loaded
local function build_input(tile)
	local source = objects.source

	if not tile.height_state then
		local zoom = tile.source.tiles.Zoom
		local north, west = geo.FromMercator(tile.x, tile.y, zoom, 1)
		local south, east = geo.FromMercator(tile.x + 1, tile.y + 1, zoom, 1)
		local heights = source.Heights
		tile.height_state = {
			south = south,
			west = west,
			north = north,
			east = east,
			zoom = math.min(
				heights.NativeZoom((north + south) / 2, (west + east) / 2),
				heights.MaxZoom,
				HEIGHT_MAX_ZOOM
			),
		}
	end

	local dem = source:RequestHeights(tile.height_state)
	local state = tile.height_state
	local lat, lon = (state.north + state.south) / 2, (state.west + state.east) / 2
	-- as in the bake: height data coarser than 4 m is a surface model, lowered under the canopy
	tile.coarse = geo.GetPixelSize(
			lat,
			math.min(source.Heights.NativeZoom(lat, lon), source.Heights.MaxZoom),
			source.Heights.TileSize
		) >= 4

	if dem == nil then return end

	if dem == false then
		tile.state = "failed"
		return
	end

	return {
		data = fs.read_file(tile.source.tiles:GetPath(tile.x, tile.y)),
		x = tile.x,
		y = tile.y,
		zoom = tile.source.tiles.Zoom,
		anchor_lat = source.Anchor.lat,
		anchor_lon = source.Anchor.lon,
		dem = dem,
		sink = tile.coarse and EarthSource.CANOPY_SINK or 0,
		tree_height = objects.config.TreeHeight,
	}
end

local function build_tile(tile)
	local input = build_input(tile)

	if not input then return end

	tile.state = "building"
	objects.building = objects.building + 1

	thread_pool.Run(tile.source.job, input, math.huge):OnDone(function(job)
		objects.building = objects.building - 1

		if tile.removed then return end

		if job.err then
			llog("earth: objects %d/%d: %s", tile.x, tile.y, tostring(job.err))
			tile.state = "failed"
			return
		end

		create_lines(tile, job.meta, job.blob)
		place_points(tile, job.meta.points)
		tile.state = "built"
	end)
end

local function load_tile(tile)
	tile.state = "loading"

	tile.source.tiles:Fetch(tile.x, tile.y, function(err)
		if tile.removed then return end

		if err then
			llog("earth: objects %d/%d failed: %s", tile.x, tile.y, err)
			tile.state = "failed"
			return
		end

		tile.state = "fetched"
	end)
end

local function remove_tile(tile)
	tile.removed = true

	for _, handle in ipairs(tile.handles or {}) do
		scatter.RemovePlacements(handle)
	end

	tile.handles = nil

	if tile.entity then tile.entity:Remove() end

	tile.entity = nil
end

local function update()
	local camera = render3d.GetCamera():GetPosition()

	for i, source in ipairs(objects.sources) do
		local tiles = objects.tiles[i]
		local wanted = source.tiles:GetTilesAround(
			objects.source,
			camera.x,
			camera.z,
			tiles,
			source.radius,
			source.keep_radius,
			remove_tile
		)

		for _, entry in ipairs(wanted) do
			local tile = entry.tile
			tile.source = source

			if tile.state == "new" then
				load_tile(tile)
			elseif tile.state == "fetched" and objects.building < MAX_BUILDING then
				build_tile(tile)
			end
		end
	end
end

-- config: Trees (model paths a mapped tree is one of, picked by its position; none places no trees), Canopy (trees at
-- the peaks of the canopy height map too, canopy_tiles.lua), TreeHeight (the tree models' height, which a canopy tree is
-- scaled to its own from)
function objects.Start(source, config)
	objects.Stop()
	objects.source = source
	objects.config = config
	objects.sources = table.shallow_copy(SOURCES)

	if config.Canopy then
		objects.sources[#objects.sources + 1] = {
			tiles = canopy_tiles.Get(),
			job = object_features.CANOPY_JOB,
			radius = 1500,
			keep_radius = 2500,
		}
	end

	objects.tiles = {}

	for i in ipairs(objects.sources) do
		objects.tiles[i] = {}
	end

	objects.building = 0
	objects.root = Entity.New{Name = "earth_objects"}
	objects.root:SetTransient(true)
	objects.root:AddComponent("transform")

	if not line_material then
		line_material = Material.New()
		line_material:SetVertexTint(true)
		line_material:SetRoughnessMultiplier(0.8)
		line_material:SetMetallicMultiplier(0)
	end

	local prototypes, kinds = {}, {}

	for kind, settings in pairs(objects.KINDS) do
		local models = kind == "tree" and (config.Trees or {}) or {prop_models.GetPath(kind)}

		for _, model in ipairs(models) do
			prototypes[#prototypes + 1] = {
				model = model,
				placed = true,
				max_distance = settings.max_distance,
				billboard = settings.billboard or false,
				shadow = true,
			}
			kinds[#prototypes] = kind
		end
	end

	objects.set = ScatterSet.New{Name = "earth_objects", Prototypes = prototypes}
	objects.set:Use()
	objects.protos = {}

	for i, proto in ipairs(objects.set.protos) do
		local kind = kinds[i]
		objects.protos[kind] = objects.protos[kind] or {}
		table.insert(objects.protos[kind], proto)
	end

	local next_update = 0

	event.AddListener("Update", "earth_objects", function()
		local now = system.GetElapsedTime()

		if now < next_update then return end

		next_update = now + UPDATE_INTERVAL
		update()
	end)
end

-- the objects are placed again around the new origin
function objects.SetSource(source)
	objects.Start(source, objects.config)
end

function objects.Stop()
	event.RemoveListener("Update", "earth_objects")

	for _, tiles in ipairs(objects.tiles or {}) do
		for _, tile in pairs(tiles) do
			remove_tile(tile)
		end
	end

	if objects.set then objects.set:Remove() end

	if objects.root then objects.root:Remove() end

	objects.tiles = nil
	objects.set = nil
	objects.protos = nil
	objects.root = nil
	objects.source = nil
end

-- built, pending (fetching, waiting for the ground, building) and failed tiles
function objects.GetStats()
	local stats = {built = 0, pending = 0, failed = 0}

	for _, tiles in ipairs(objects.tiles or {}) do
		for _, tile in pairs(tiles) do
			local key = tile.state == "built" and
				"built" or
				tile.state == "failed" and
				"failed" or
				"pending"
			stats[key] = stats[key] + 1
		end
	end

	return stats
end

return objects
