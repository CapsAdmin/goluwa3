local T = import("test/environment.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local surface_effects = import("goluwa/render3d/surface_effects.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local TICK = surface_effects.TICK

local function slab(position, size, flammability)
	return shapes.Box{
		Position = position,
		Size = size,
		Material = shapes.Material{
			Color = Color(0.6, 0.5, 0.4, 1),
			Roughness = 0.8,
			Metallic = 0,
			Flammability = flammability,
		},
		Collision = false,
		RigidBody = false,
	}
end

local function with_field(cb)
	local ray_time = surface_effects.RAY_TIME
	local temperature = atmosphere.GetTemperature()
	surface_effects.RAY_TIME = 1
	surface_effects.Clear()
	math.randomseed(1)
	local ok, err = pcall(cb)
	surface_effects.Clear()
	surface_effects.RAY_TIME = ray_time
	atmosphere.SetTemperature(temperature)

	if not ok then error(err, 0) end
end

local function run(seconds)
	for _ = 1, math.ceil(seconds / TICK) do
		surface_effects.Step(TICK)
	end
end

T.Test3D("surface effects find surfaces and burn flammable ones", function()
	local ground = slab(Vec3(0, -0.5, 0), Vec3(8, 1, 8), 1)

	with_field(function()
		surface_effects.Apply("fire", Vec3(0, 0, 0), 1, 1)
		T(surface_effects.GetCellCount())[">"](4)
		run(5)
		T(surface_effects.Query(Vec3(0, 0, 0), 0.5, "heat"))[">"](0.3)
		T(surface_effects.Query(Vec3(0, 0, 0), 0.5, "burnt"))[">"](0.1)
		local cell = surface_effects.GetCellAt(0.1, -0.01, 0.1) or
			surface_effects.GetCellAt(0.1, 0.01, 0.1)
		T(cell ~= nil)["=="](true)
		T(cell.ny)[">"](0.99)
	end)

	ground:Remove()
end)

T.Test3D("surface effects fire spreads over wood and stops at stone", function()
	local wood = slab(Vec3(-4, -0.5, 0), Vec3(8, 1, 6), 1)
	local stone = slab(Vec3(4, -0.5, 0), Vec3(8, 1, 6), 0.02)

	with_field(function()
		surface_effects.Apply("fire", Vec3(-6, 0, 0), 0.8, 1)
		run(40)
		T(surface_effects.Query(Vec3(-2, 0, 0), 0.5, "burnt"))[">"](0.2)
		T(surface_effects.Query(Vec3(2.5, 0, 0), 1, "burnt"))["<"](0.05)
		T(surface_effects.Query(Vec3(2.5, 0, 0), 1, "heat"))["<"](0.1)
	end)

	wood:Remove()
	stone:Remove()
end)

T.Test3D("surface effects frost melts into water and water quenches fire", function()
	local ground = slab(Vec3(0, -0.5, 0), Vec3(8, 1, 8), 1)

	with_field(function()
		atmosphere.SetTemperature(-5)
		surface_effects.Apply("frost", Vec3(-2, 0, 0), 1, 1)
		run(3)
		local frozen = surface_effects.Query(Vec3(-2, 0, 0), 0.5, "frost")
		T(frozen)[">"](0.5)
		T(surface_effects.Query(Vec3(-2, 0, 0), 0.5, "wet"))["=="](0)
		atmosphere.SetTemperature(30)
		run(10)
		T(surface_effects.Query(Vec3(-2, 0, 0), 0.5, "frost"))["<"](frozen)
		T(surface_effects.Query(Vec3(-2, 0, 0), 0.5, "wet"))[">"](0)
		surface_effects.Apply("fire", Vec3(2, 0, 0), 0.8, 1)
		run(3)
		local burning = surface_effects.Query(Vec3(2, 0, 0), 0.5, "heat")
		T(burning)[">"](0.2)
		surface_effects.Apply("water", Vec3(2, 0, 0), 1.5, 1)
		T(surface_effects.Query(Vec3(2, 0, 0), 0.5, "heat"))["<"](burning * 0.5)
	end)

	ground:Remove()
end)

T.Test3D("surface effects shade the gbuffer through the gpu field", function(draw)
	local ground = slab(Vec3(0, -0.5, 0), Vec3(20, 1, 20), 1)
	local cam = render3d.GetCamera()
	cam:SetPosition(Vec3(0, 6, 0))
	cam:SetRotation(Quat():SetAngles(Deg3(-90, 0, 0)))
	cam:SetFOV(math.rad(60))
	cam:SetNearZ(0.1)
	cam:SetFarZ(100)

	with_field(function()
		local function albedo(x, y)
			draw()
			draw()
			local r, g, b = gbuffer_layout.GetTexture("albedo"):GetPixel(x, y)
			return r + g + b
		end

		local size = render3d.GetRenderSize()
		local cx, cy = math.floor(size.x / 2), math.floor(size.y / 2)
		local before = albedo(cx, cy)
		local edge_before = albedo(math.floor(size.x * 0.02), cy)

		for cell in pairs(surface_effects.FindSurfaces(Vec3(0, 0, 0), 2, Vec3(0, 1, 0))) do
			cell.burnt = 1
			surface_effects.Touch(cell)
		end

		T(albedo(cx, cy))["<"](before * 0.5)
		T(albedo(math.floor(size.x * 0.02), cy))["~"](edge_before, 3)
	end)

	ground:Remove()
end)

T.Test3D("surface effects burn a whole dynamic object", function(draw)
	local physics = import("goluwa/physics.lua")

	if not physics.instance then physics.Initialize() end

	local crate = shapes.Box{
		Position = Vec3(0, 0.5, 0),
		Size = Vec3(1, 1, 1),
		Material = shapes.Material{
			Color = Color(0.6, 0.5, 0.4, 1),
			Roughness = 0.8,
			Metallic = 0,
			Flammability = 1,
		},
		RigidBody = {Mass = 10, GravityScale = 0},
	}
	local cam = render3d.GetCamera()
	cam:SetPosition(Vec3(0, 4, 0))
	cam:SetRotation(Quat():SetAngles(Deg3(-90, 0, 0)))
	cam:SetFOV(math.rad(40))
	cam:SetNearZ(0.1)
	cam:SetFarZ(100)

	with_field(function()
		local size = render3d.GetRenderSize()

		local function albedo()
			for _ = 1, 4 do
				draw()
			end

			local r, g, b = gbuffer_layout.GetTexture("albedo"):GetPixel(math.floor(size.x / 2), math.floor(size.y / 2))
			return r + g + b
		end

		local before = albedo()
		surface_effects.Apply("fire", Vec3(0, 1.3, 0), 0.8, 1)
		local cell = surface_effects.GetObject(crate.visual)
		T(cell ~= nil)["=="](true)
		run(12)
		T(cell.heat)[">"](0.3)
		T(cell.burnt)[">"](0.5)
		T(surface_effects.GetCellCount())["=="](0)
		cell.heat = 0
		cell.burnt = 1
		T(albedo())["<"](before * 0.5)
	end)

	crate:Remove()
end)

T.Test3D("surface effects rain damps fires that are open to the sky", function()
	local weather = import("goluwa/render3d/weather.lua")
	local ground = slab(Vec3(0, -0.5, 0), Vec3(16, 1, 8), 1)
	local roof = slab(Vec3(5, 2.5, 0), Vec3(4, 0.2, 4), 0)
	local enabled = atmosphere.IsEnabled()

	with_field(function()
		atmosphere.SetEnabled(true)
		weather.SetWetness(1)
		surface_effects.Apply("fire", Vec3(-5, 0, 0), 0.8, 1)
		surface_effects.Apply("fire", Vec3(5, 0, 0), 0.8, 1)
		run(6)
		local open = surface_effects.Query(Vec3(-5, 0, 0), 0.5, "heat")
		local covered = surface_effects.Query(Vec3(5, 0, 0), 0.5, "heat")
		T(covered)[">"](0.8)
		T(open)["<"](covered * 0.6)
	end)

	weather.SetWetness(0)
	atmosphere.SetEnabled(enabled)
	ground:Remove()
	roof:Remove()
end)
