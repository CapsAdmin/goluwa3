local T = import("test/environment.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local weather = import("goluwa/render3d/weather.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")

local function use_passes()
	render3d.Initialize{
		passes = {
			import("goluwa/render3d/passes/gbuffer.lua"),
			import("goluwa/render3d/passes/ddgi.lua"),
			import("goluwa/render3d/passes/fluid_volumes.lua"),
			import("goluwa/render3d/passes/lighting.lua"),
			import("goluwa/render3d/passes/volumetric_fog.lua"),
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

local function run(draw, frames)
	local system = import("goluwa/system.lua")

	for _ = 1, frames do
		system.SetElapsedTime(system.GetElapsedTime() + 1 / 60)
		draw()
	end
end

local function check_screen()
	local r, g, b, a = T.GetScreenPixel(256, 256)

	for _, v in ipairs{r, g, b, a} do
		T(v == v and v < math.huge)["=="](true)
	end
end

local function with_scene(draw, build)
	local sun = Entity.New{
		transform = {Rotation = Quat():SetAngles(Deg3(35, 180, 0))},
		light_sun = {Color = Color(1, 1, 1), Intensity = 1},
	}
	local root = Entity.New{Name = "fluid_volumes_test"}
	use_passes()
	local ok, err = pcall(function()
		weather.SetTimeScale(0)
		setup_camera()
		build(root, import("goluwa/render3d/fluid_volumes.lua"))
	end)
	root:Remove()
	sun:Remove()

	if not ok then error(err, 0) end
end

T.Test3DRayTracing("Graphics render3d fluid fire burns its fuel and the smoke rises", function(draw)
	with_scene(draw, function(root, fluid_volumes)
		local volume = Entity.New{
			Parent = root,
			transform = {Position = Vec3(0, 2, 0)},
			fluid_volume = {Size = Vec3(2, 4, 2), Resolution = 32, Medium = "smoke"},
		}
		Entity.New{
			Parent = root,
			transform = {Position = Vec3(0, 0.4, 0)},
			fluid_emitter = {Radius = 0.4, Fuel = 8, Temperature = 1200},
		}
		run(draw, 90)
		local stats = fluid_volumes.GetStats(volume.fluid_volume)
		T(stats ~= nil)["=="](true)
		T(stats.max_flame)[">"](0.05)
		T(stats.max_temperature)[">"](volume.fluid_volume:GetIgnitionTemperature())
		T(stats.max_temperature)["<="](volume.fluid_volume:GetFlameTemperature() + 1)
		T(stats.smoke_total)[">"](0)
		T(stats.smoke_height)[">"](-1.6)
		T(stats.emitted_intensity)[">"](0)
		T(stats.emission_temperature)[">"](volume.fluid_volume:GetIgnitionTemperature())
		check_screen()
	end)
end)

T.Test3DRayTracing("Graphics render3d heavy fluid gas sinks and pools on the floor", function(draw)
	with_scene(draw, function(root, fluid_volumes)
		local volume = Entity.New{
			Parent = root,
			transform = {Position = Vec3(0, 1.5, 0)},
			fluid_volume = {
				Size = Vec3(3, 3, 3),
				Resolution = 32,
				Medium = "poison",
				Weight = 1,
				Buoyancy = 0,
			},
		}
		Entity.New{
			Parent = root,
			transform = {Position = Vec3(0, 2.2, 0)},
			fluid_emitter = {Radius = 0.3, Smoke = 4},
		}
		run(draw, 90)
		local stats = fluid_volumes.GetStats(volume.fluid_volume)
		T(stats.solid_cells)[">"](0)
		T(stats.smoke_total)[">"](0)
		T(stats.smoke_height)["<"](0.4)
		T(stats.max_temperature)["<"](fluid_volumes.AMBIENT_TEMPERATURE + 1)
		check_screen()
	end)
end)

T.Test3DRayTracing("Graphics render3d procedural fluid fog fills the froxels", function(draw)
	with_scene(draw, function(root, fluid_volumes)
		local volume = Entity.New{
			Parent = root,
			transform = {Position = Vec3(0, 2, -10)},
			fluid_volume = {
				Size = Vec3(40, 4, 10),
				Resolution = 32,
				Medium = "fog",
				Simulation = "procedural",
				Raymarch = false,
				Fill = 0.2,
				Floor = false,
				Obstacles = false,
			},
		}
		run(draw, 8)
		local stats = fluid_volumes.GetStats(volume.fluid_volume)
		local nx, ny, nz, cell = fluid_volumes.GetGridSize(volume.fluid_volume)
		T(
			math.abs(stats.smoke_total - 0.2 * nx * ny * nz * cell ^ 3) / (
					0.2 * nx * ny * nz * cell ^ 3
				)
		)["<"](0.02)
		T(fluid_volumes.HasRaymarched())["=="](false)
		check_screen()
		volume.fluid_volume:SetVisible(false)
		T(#fluid_volumes.GetVolumes())["=="](0)
	end)
end)

T.Test3DRayTracing("Graphics render3d a rising body drags smoke up in its wake", function(draw)
	with_scene(draw, function(root, fluid_volumes)
		local BoxShape = import("goluwa/physics/shapes/box.lua")
		local config = {
			Size = Vec3(3, 4, 3),
			Resolution = 32,
			Medium = "smoke",
			Buoyancy = 0,
			Turbulence = 0,
			Vorticity = 0,
			Dissipation = 0,
			Floor = false,
			Obstacles = false,
		}
		local pushed = Entity.New{Parent = root, transform = {Position = Vec3(0, 2, 0)}, fluid_volume = config}
		local still = Entity.New{Parent = root, transform = {Position = Vec3(10, 2, 0)}, fluid_volume = config}
		local mover = Entity.New{Parent = root, transform = {Position = Vec3(0, 0.6, 0)}}
		local body = mover:AddComponent(
			"rigid_body",
			{Shape = BoxShape.New(Vec3(0.6, 0.6, 0.6)), MotionType = "kinematic"}
		)
		run(draw, 2)
		fluid_volumes.Splat(Vec3(0, 0.6, 0), 1, {smoke = 1})
		fluid_volumes.Splat(Vec3(10, 0.6, 0), 1, {smoke = 1})
		run(draw, 4)
		local solid_seen = 0

		for i = 1, 50 do
			body:SetPosition(Vec3(0, 0.6 + i * 0.05, 0))
			run(draw, 1)
			solid_seen = math.max(solid_seen, fluid_volumes.GetStats(pushed.fluid_volume).solid_cells)
		end

		run(draw, 4)
		local pushed_stats = fluid_volumes.GetStats(pushed.fluid_volume)
		local still_stats = fluid_volumes.GetStats(still.fluid_volume)
		T(solid_seen)[">"](0)
		T(still_stats.smoke_total)[">"](0)
		T(pushed_stats.smoke_height - still_stats.smoke_height)[">"](0.1)
	end)
end)
