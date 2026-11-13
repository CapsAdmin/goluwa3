local T = import("test/environment.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local weather = import("goluwa/render3d/weather.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")
local fog_volumes = import("goluwa/render3d/fog_volumes.lua")
local FRAMES = 4

local function frames(draw)
	for _ = 1, FRAMES do
		draw()
	end
end

local function use_passes()
	render3d.Initialize{
		passes = {
			import("goluwa/render3d/passes/gbuffer.lua"),
			import("goluwa/render3d/passes/ddgi.lua"),
			import("goluwa/render3d/passes/lighting.lua"),
			import("goluwa/render3d/passes/water.lua"),
			import("goluwa/render3d/passes/volumetric_fog.lua"),
			import("goluwa/render3d/passes/blit.lua"),
		},
	}
end

local function restore_passes()
	render3d.Initialize{
		passes = {
			import("goluwa/render3d/passes/gbuffer.lua"),
			import("goluwa/render3d/passes/blit.lua"),
		},
	}
end

local function setup_camera()
	local cam = render3d.GetCamera()
	cam:SetPosition(Vec3(0, 2, 10))
	cam:SetRotation(Quat():Identity())
	cam:SetFOV(math.rad(70))
	cam:SetNearZ(0.1)
	cam:SetFarZ(1000)
end

T.Test3DRayTracing("Graphics render3d fog volumes render and register by visibility", function(draw)
	local sun = Entity.New{
		transform = {Rotation = Quat():SetAngles(Deg3(35, 180, 0))},
		light_sun = {Color = Color(1, 1, 1), Intensity = 1},
	}
	local volume
	use_passes()
	local ok, err = pcall(function()
		weather.SetTimeScale(0)
		setup_camera()
		frames(draw)
		volume = Entity.New{
			Name = "media_volumes_smoke",
			transform = {Position = Vec3(0, 3, 0)},
			fog_volume = {Size = Vec3(40, 12, 8), Medium = "smoke", Density = 0.4, EdgeSoftness = 0.5},
		}
		T(#fog_volumes.GetVolumes())["=="](1)
		frames(draw)
		local r, g, b, a = T.GetScreenPixel(256, 256)

		for _, v in ipairs{r, g, b, a} do
			T(v == v and v < math.huge)["=="](true)
		end

		volume.fog_volume:SetVisible(false)
		T(#fog_volumes.GetVolumes())["=="](0)
	end)

	if volume then volume:Remove() end

	sun:Remove()
	restore_passes()

	if not ok then error(err, 0) end
end)

T.Test3DRayTracing("Graphics render3d renders the ocean and a water volume under a fog volume", function(draw)
	local previous_ocean_enabled = render3d.IsOceanEnabled()
	local sun = Entity.New{
		transform = {Rotation = Quat():SetAngles(Deg3(35, 180, 0))},
		light_sun = {Color = Color(1, 1, 1), Intensity = 1},
	}
	local entities = {}
	use_passes()
	local ok, err = pcall(function()
		weather.SetTimeScale(0)
		render3d.SetOceanEnabled(true)
		render3d.SetOceanLevel(0)
		setup_camera()
		entities[#entities + 1] = Entity.New{
			Name = "media_volumes_tank",
			transform = {Position = Vec3(0, 3, 0)},
			water_volume = {Size = Vec3(6, 3, 6), Medium = "pool", WaveHeight = 0.1},
		}
		entities[#entities + 1] = Entity.New{
			Name = "media_volumes_steam",
			transform = {Position = Vec3(0, 2, -2)},
			fog_volume = {Size = Vec3(10, 4, 4), Medium = "steam", Density = 0.2, HeightFalloff = 2},
		}
		local lamp = Entity.New{Name = "media_volumes_lamp"}
		lamp:AddComponent("transform"):SetPosition(Vec3(0, 1, 2))
		lamp:AddComponent("light_point"):SetLumen(8000)
		entities[#entities + 1] = lamp
		frames(draw)
		local r, g, b, a = T.GetScreenPixel(256, 256)

		for _, v in ipairs{r, g, b, a} do
			T(v == v and v < math.huge)["=="](true)
		end
	end)

	for _, entity in ipairs(entities) do
		entity:Remove()
	end

	sun:Remove()
	render3d.SetOceanEnabled(previous_ocean_enabled)
	restore_passes()

	if not ok then error(err, 0) end
end)
