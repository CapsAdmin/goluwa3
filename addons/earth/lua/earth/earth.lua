local Terrain = import("goluwa/terrain/terrain.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local fonts = import("goluwa/render2d/fonts.lua")
local TileSet = import("lua/earth/tile_set.lua")
local EarthSource = import("lua/earth/source.lua")
local mapterhorn = import("lua/earth/mapterhorn.lua")
local imagery_sources = import("lua/earth/imagery_sources.lua")
local cloud_cover = import("lua/earth/cloud_cover.lua")
local buildings = import("lua/earth/buildings.lua")
local water_bodies = import("lua/earth/water_bodies.lua")
local tile_grids = import("lua/earth/tile_grids.lua")
local land_grid = import("lua/earth/land_grid.lua")
local road_grid = import("lua/earth/road_grid.lua")
local geo = import("lua/earth/geo.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local View = import("goluwa/render3d/view.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local weather = import("goluwa/render3d/weather.lua")
local earth = {}
earth.ATTRIBUTION = {
	"Elevation: Mapterhorn (https://mapterhorn.com/attribution); sea floor: Terrain Tiles on AWS (Mapzen; ETOPO1, GEBCO, and others)",
	"Imagery: Sentinel-2 cloudless - https://s2maps.eu by EOX IT Services GmbH (Contains modified Copernicus Sentinel data 2016)",
}
-- regional photos are used from these zooms on (a WMS renders every tile it is asked for, so not for the far rings)
local REGIONAL_TILE_MIN_ZOOM = 10
local REGIONAL_EXPORT_MIN_ZOOM = 14
local REGIONAL_MAX_ZOOM = 18
local MERCATOR_EXTENT = 20037508.342789244

local function regional_url(source, z, x, y)
	local n = 2 ^ z
	local url = source.url:gsub("{z}", z):gsub("{x}", x):gsub("{y}", y):gsub("{ty}", n - 1 - y):gsub("{size}", 256)

	if source.kind == "wms" then
		local size = 2 * MERCATOR_EXTENT / n
		local west, north = -MERCATOR_EXTENT + x * size, MERCATOR_EXTENT - y * size
		url = url:gsub(
			"{bbox}",
			string.format("%.3f,%.3f,%.3f,%.3f", west, north - size, west + size, north)
		)
	elseif source.kind == "wms4326" then
		local north, west = geo.FromMercator(x, y, z, 1)
		local south, east = geo.FromMercator(x + 1, y + 1, z, 1)
		url = url:gsub("{bbox4326}", string.format("%.8f,%.8f,%.8f,%.8f", south, west, north, east))
	end

	return url
end

function earth.GetTileSets()
	if not earth.Heights then
		earth.Heights = TileSet.New{
			name = "mapterhorn",
			fetch = mapterhorn.Fetch,
			extension = "webp",
			tile_size = 512,
			max_zoom = 16,
			kind = "terrarium",
			missing_is_sea = true,
			native_zoom = mapterhorn.GetNativeZoom,
			max_resident = 160,
		}
		earth.Bathymetry = TileSet.New{
			name = "aws_terrarium",
			url = function(z, x, y)
				return string.format("https://s3.amazonaws.com/elevation-tiles-prod/terrarium/%d/%d/%d.png", z, x, y)
			end,
			extension = "png",
			tile_size = 256,
			max_zoom = 15,
			kind = "terrarium",
			host_limit = 8,
			max_resident = 256,
		}
		earth.Imagery = TileSet.New{
			name = "eox_s2cloudless_2016",
			url = function(z, x, y)
				return string.format(
					"https://tiles.maps.eox.at/wmts/1.0.0/s2cloudless_3857/default/g/%d/%d/%d.jpg",
					z,
					y,
					x
				)
			end,
			extension = "jpg",
			tile_size = 256,
			max_zoom = 14,
			kind = "image",
			host_limit = 6,
		}
		earth.ImageryChain = {}

		for _, source in ipairs(imagery_sources) do
			earth.ImageryChain[#earth.ImageryChain + 1] = TileSet.New{
				name = "photo_" .. source.name,
				url = function(z, x, y)
					return regional_url(source, z, x, y)
				end,
				extension = "img",
				tile_size = 256,
				min_zoom = source.kind == "xyz" and REGIONAL_TILE_MIN_ZOOM or REGIONAL_EXPORT_MIN_ZOOM,
				max_zoom = REGIONAL_MAX_ZOOM,
				kind = "photo",
				host_limit = 4,
				bounds = source.bounds,
				attribution = source.attribution,
			}
		end

		earth.ImageryChain[#earth.ImageryChain + 1] = earth.Imagery
	end

	return earth.Heights, earth.ImageryChain, earth.Bathymetry
end

earth.LandCover = tile_grids.New{
	Name = "land",
	Theme = "base",
	Zoom = 13,
	Size = land_grid.SIZE,
	Bytes = 1,
	Job = land_grid.JOB,
	Radius = 6000,
	KeepRadius = 9000,
	MaxMosaicStep = 16,
}
earth.Roads = tile_grids.New{
	Name = "roads",
	Theme = "transportation",
	Zoom = 14,
	Size = road_grid.SIZE,
	Bytes = 2,
	Job = road_grid.JOB,
	Radius = 3000,
	KeepRadius = 4500,
	MaxMosaicStep = 4,
}

local function start_terrain(lat, lon)
	weather.SetLocation(lat, lon)
	local heights, imagery, bathymetry = earth.GetTileSets()
	local config = earth.config
	earth.source = EarthSource.New{
		Anchor = {lat, lon},
		Heights = heights,
		Imagery = imagery,
		Bathymetry = bathymetry,
		Layers = config.Layers,
	}
	earth.terrain = Terrain.New(
		table.merge_many(
			{
				Name = "earth_terrain",
				Levels = 15,
				BaseChunkSize = 64,
				Samples = 65,
				DetailSize = 256,
				SplatSize = 128,
				ColorSize = 128,
				ShadowLevels = 4,
				BuildsPerFrame = 4,
			},
			config.Terrain or {},
			{Source = earth.source}
		)
	):Start()
	return earth.terrain
end

local function finish_recenter()
	local previous = earth.previous_terrain

	if not previous then return end

	earth.previous_terrain = nil
	earth.terrain.Root.visibility:SetVisible(true)
	previous:Stop()
end

local function update()
	local terrain = earth.terrain

	if
		earth.previous_terrain and
		not terrain.holding_scene_load and
		earth.source:GetWaitingCount() == 0
	then
		finish_recenter()
	end

	local distance = earth.config.RecenterDistance

	if not distance or earth.previous_terrain then return end

	local position = render3d.GetCamera():GetPosition()

	if position.x * position.x + position.z * position.z > distance * distance then
		earth.Recenter(earth.WorldToLatLon(position.x, position.z))
	end
end

-- config: lat, lon (the world origin, the weather's location when not given; the weather's location follows the origin),
-- Layers, Terrain (any Terrain config), Clouds (cloud layers whose cover comes from a weather model, see cloud_cover.lua),
-- Buildings (blocks extruded from Overture's footprints around the camera, see buildings.lua),
-- Water (Overture's lakes, ponds and rivers carved into the terrain and filled with water volumes, see water_bodies.lua),
-- Land (what the ground is from Overture's land cover, land use and land, picking the layers and the fine relief, see
-- land_grid.lua), Roads (Overture's roads, paths and railways flattened into and painted on the terrain, see road_grid.lua),
-- RecenterDistance (meters from the origin the camera may go before the origin moves under it, nil never moves it)
function earth.Start(config)
	earth.Stop()
	earth.config = config
	local lat, lon = weather.GetLocation()
	start_terrain(config.lat or lat, config.lon or lon)
	event.AddListener("Update", "earth", update)
	local attribution = table.copy(earth.ATTRIBUTION)

	if config.Clouds then
		cloud_cover.Start(earth.source)
		attribution[#attribution + 1] = cloud_cover.ATTRIBUTION
	end

	if config.Buildings then
		buildings.Start(earth.source)
		attribution[#attribution + 1] = buildings.ATTRIBUTION
	end

	if config.Water then
		water_bodies.Start(earth.source, earth.terrain)
		attribution[#attribution + 1] = water_bodies.ATTRIBUTION
	end

	if config.Land then
		earth.LandCover:Start(earth.source, earth.terrain, "Land")
		attribution[#attribution + 1] = land_grid.ATTRIBUTION
	end

	if config.Roads then
		earth.Roads:Start(earth.source, earth.terrain, "Roads")
		attribution[#attribution + 1] = road_grid.ATTRIBUTION
	end

	local lines = attribution
	local next_refresh = 0

	event.AddListener("DrawHUD", "earth_attribution", function()
		local now = system.GetElapsedTime()

		-- the regional photo services credited are those the terrain was baked from lately
		if now >= next_refresh then
			next_refresh = now + 2
			lines = table.copy(attribution)

			for _, set in ipairs(earth.source:GetImageryInUse(60)) do
				if set.Attribution then lines[#lines + 1] = "Imagery: " .. set.Attribution end
			end
		end

		local font = fonts.GetFont()
		local _, h = render2d.GetSize()
		render2d.SetTexture(nil)
		render2d.SetColor(1, 1, 1, 0.6)

		for i, line in ipairs(lines) do
			local _, text_h = font:GetTextSize(line)
			font:DrawText(line, 8, h - (#lines - i + 1) * (text_h + 2) - 6, 0)
		end
	end)

	return earth.terrain
end

-- moves the world origin to a latitude and longitude: the terrain streams again around it while the old one is drawn
-- moved into the new frame, the active view moves with it, and "EarthRecenter" (relation, geo.TransformPoint) lets
-- whatever else holds world positions follow
function earth.Recenter(lat, lon)
	finish_recenter()
	local old_terrain = earth.terrain
	local relation = geo.Relate(earth.source.Anchor, geo.NewAnchor(lat, lon))
	local rotation = Quat(relation.quat[1], relation.quat[2], relation.quat[3], relation.quat[4])
	old_terrain:Freeze()
	old_terrain.Root.transform:SetPosition(Vec3(relation.tx, relation.ty, relation.tz))
	old_terrain.Root.transform:SetRotation(rotation)
	earth.previous_terrain = old_terrain
	start_terrain(lat, lon).Root:AddComponent("visibility"):SetVisible(false)

	if earth.config.Clouds then cloud_cover.SetSource(earth.source) end

	if earth.config.Buildings then buildings.SetSource(earth.source) end

	if earth.config.Water then
		water_bodies.SetSource(earth.source, earth.terrain)
	end

	if earth.config.Land then earth.LandCover:SetSource(earth.source, earth.terrain) end

	if earth.config.Roads then earth.Roads:SetSource(earth.source, earth.terrain) end

	local view = View.GetActive()

	if view then
		local p = view:GetPosition()
		view:SetPosition(Vec3(geo.TransformPoint(relation, p.x, p.y, p.z)))
		view:SetRotation(rotation * view:GetRotation())
	end

	render3d.CutCamera()
	event.Call("EarthRecenter", relation, rotation)
end

function earth.Stop()
	finish_recenter()
	cloud_cover.Stop()
	buildings.Stop()
	water_bodies.Stop()
	earth.LandCover:Stop()
	earth.Roads:Stop()

	if earth.terrain then
		earth.terrain:Stop()
		earth.terrain = nil
		earth.source = nil
	end

	event.RemoveListener("Update", "earth")
	event.RemoveListener("DrawHUD", "earth_attribution")
end

function earth.WorldToLatLon(x, z)
	return earth.source:WorldToLatLon(x, z)
end

function earth.LatLonToWorld(lat, lon)
	return earth.source:LatLonToWorld(lat, lon)
end

return earth
