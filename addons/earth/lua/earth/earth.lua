local Terrain = import("goluwa/terrain/terrain.lua")
local event = import("goluwa/event.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local fonts = import("goluwa/render2d/fonts.lua")
local TileSet = import("lua/earth/tile_set.lua")
local EarthSource = import("lua/earth/source.lua")
local mapterhorn = import("lua/earth/mapterhorn.lua")
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
	end

	return earth.Heights, earth.Imagery, earth.Bathymetry
end

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
-- Layers, Terrain (any Terrain config),
-- RecenterDistance (meters from the origin the camera may go before the origin moves under it, nil never moves it)
function earth.Start(config)
	earth.Stop()
	earth.config = config
	local lat, lon = weather.GetLocation()
	start_terrain(config.lat or lat, config.lon or lon)
	event.AddListener("Update", "earth", update)

	event.AddListener("DrawHUD", "earth_attribution", function()
		local font = fonts.GetFont()
		local _, h = render2d.GetSize()
		render2d.SetTexture(nil)
		render2d.SetColor(1, 1, 1, 0.6)

		for i, line in ipairs(earth.ATTRIBUTION) do
			local _, text_h = font:GetTextSize(line)
			font:DrawText(line, 8, h - (#earth.ATTRIBUTION - i + 1) * (text_h + 2) - 6, 0)
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
