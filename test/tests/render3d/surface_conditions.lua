local T = import("test/environment.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local surface_conditions = import("goluwa/render3d/surface_conditions.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local TICK = surface_conditions.TICK

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
	local ray_time = surface_conditions.RAY_TIME
	local temperature = atmosphere.GetTemperature()
	surface_conditions.RAY_TIME = 1
	surface_conditions.Clear()
	math.randomseed(1)
	local ok, err = pcall(cb)
	surface_conditions.Clear()
	surface_conditions.RAY_TIME = ray_time
	atmosphere.SetTemperature(temperature)

	if not ok then error(err, 0) end
end

local function run(seconds)
	for _ = 1, math.ceil(seconds / TICK) do
		surface_conditions.Step(TICK)
	end
end

T.Test3D("surface conditions find surfaces and burn flammable ones", function()
	local ground = slab(Vec3(0, -0.5, 0), Vec3(8, 1, 8), 1)

	with_field(function()
		surface_conditions.Apply("fire", Vec3(0, 0, 0), 1, 1)
		T(surface_conditions.GetCellCount())[">"](4)
		run(5)
		T(surface_conditions.Query(Vec3(0, 0, 0), 0.5, "heat"))[">"](0.3)
		T(surface_conditions.Query(Vec3(0, 0, 0), 0.5, "burnt"))[">"](0.1)
		local cell = surface_conditions.GetCellAt(0.1, -0.01, 0.1) or
			surface_conditions.GetCellAt(0.1, 0.01, 0.1)
		T(cell ~= nil)["=="](true)
		T(cell.ny)[">"](0.99)
	end)

	ground:Remove()
end)

T.Test3D("surface conditions fire spreads over wood and stops at stone", function()
	local wood = slab(Vec3(-4, -0.5, 0), Vec3(8, 1, 6), 1)
	local stone = slab(Vec3(4, -0.5, 0), Vec3(8, 1, 6), 0.02)

	with_field(function()
		surface_conditions.Apply("fire", Vec3(-6, 0, 0), 0.8, 1)
		run(40)
		T(surface_conditions.Query(Vec3(-2, 0, 0), 0.5, "burnt"))[">"](0.2)
		T(surface_conditions.Query(Vec3(2.5, 0, 0), 1, "burnt"))["<"](0.05)
		T(surface_conditions.Query(Vec3(2.5, 0, 0), 1, "heat"))["<"](0.1)
	end)

	wood:Remove()
	stone:Remove()
end)

T.Test3D("surface conditions frost melts into water and water quenches fire", function()
	local ground = slab(Vec3(0, -0.5, 0), Vec3(8, 1, 8), 1)

	with_field(function()
		atmosphere.SetTemperature(-5)
		surface_conditions.Apply("frost", Vec3(-2, 0, 0), 1, 1)
		run(3)
		local frozen = surface_conditions.Query(Vec3(-2, 0, 0), 0.5, "frost")
		T(frozen)[">"](0.5)
		T(surface_conditions.Query(Vec3(-2, 0, 0), 0.5, "wet"))["=="](0)
		atmosphere.SetTemperature(30)
		run(10)
		T(surface_conditions.Query(Vec3(-2, 0, 0), 0.5, "frost"))["<"](frozen)
		T(surface_conditions.Query(Vec3(-2, 0, 0), 0.5, "wet"))[">"](0)
		surface_conditions.Apply("fire", Vec3(2, 0, 0), 0.8, 1)
		run(3)
		local burning = surface_conditions.Query(Vec3(2, 0, 0), 0.5, "heat")
		T(burning)[">"](0.2)
		surface_conditions.Apply("water", Vec3(2, 0, 0), 1.5, 1)
		T(surface_conditions.Query(Vec3(2, 0, 0), 0.5, "heat"))["<"](burning * 0.5)
	end)

	ground:Remove()
end)

T.Test3D("surface conditions shade the gbuffer through the gpu field", function(draw)
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

		for cell in pairs(surface_conditions.FindSurfaces(Vec3(0, 0, 0), 2, Vec3(0, 1, 0))) do
			cell.burnt = 1
			surface_conditions.Touch(cell)
		end

		T(albedo(cx, cy))["<"](before * 0.5)
		T(albedo(math.floor(size.x * 0.02), cy))["~"](edge_before, 3)
	end)

	ground:Remove()
end)

T.Test3D("surface conditions leave dynamic objects alone", function(draw)
	local physics = import("goluwa/physics.lua")

	if not physics.instance then physics.Initialize() end

	local ground = slab(Vec3(0, -0.5, 0), Vec3(20, 1, 20), 1)
	local plate = shapes.Box{
		Position = Vec3(0, 0.03, 0),
		Size = Vec3(4, 0.05, 4),
		Material = shapes.Material{
			Color = Color(0.6, 0.5, 0.4, 1),
			Roughness = 0.8,
			Metallic = 0,
			Flammability = 1,
		},
		RigidBody = {Mass = 10, GravityScale = 0},
	}
	local cam = render3d.GetCamera()
	cam:SetPosition(Vec3(0, 6, 0))
	cam:SetRotation(Quat():SetAngles(Deg3(-90, 0, 0)))
	cam:SetFOV(math.rad(60))
	cam:SetNearZ(0.1)
	cam:SetFarZ(100)

	with_field(function()
		local size = render3d.GetRenderSize()
		local cx, cy = math.floor(size.x / 2), math.floor(size.y / 2)

		local function albedo(x, y)
			for _ = 1, 3 do
				draw()
			end

			local r, g, b = gbuffer_layout.GetTexture("albedo"):GetPixel(x, y)
			return r + g + b
		end

		local before = albedo(cx, cy)
		surface_conditions.MarkDynamicVisuals()

		for cell in pairs(surface_conditions.FindSurfaces(Vec3(0, 0, 0), 2, Vec3(0, 1, 0))) do
			cell.burnt = 1
			surface_conditions.Touch(cell)
		end

		T(surface_conditions.GetCellCount())[">"](4)
		T(albedo(cx, cy))["~"](before, 0.05)
	end)

	plate:Remove()
	ground:Remove()
end)

T.Test3D("surface conditions rain damps fires that are open to the sky", function()
	local weather = import("goluwa/render3d/weather.lua")
	local ground = slab(Vec3(0, -0.5, 0), Vec3(16, 1, 8), 1)
	local roof = slab(Vec3(5, 2.5, 0), Vec3(4, 0.2, 4), 0)
	local enabled = atmosphere.IsEnabled()

	with_field(function()
		atmosphere.SetEnabled(true)
		weather.SetWetness(1)
		surface_conditions.Apply("fire", Vec3(-5, 0, 0), 0.8, 1)
		surface_conditions.Apply("fire", Vec3(5, 0, 0), 0.8, 1)
		run(6)
		local open = surface_conditions.Query(Vec3(-5, 0, 0), 0.5, "heat")
		local covered = surface_conditions.Query(Vec3(5, 0, 0), 0.5, "heat")
		T(covered)[">"](0.8)
		T(open)["<"](covered * 0.6)
	end)

	weather.SetWetness(0)
	atmosphere.SetEnabled(enabled)
	ground:Remove()
	roof:Remove()
end)
