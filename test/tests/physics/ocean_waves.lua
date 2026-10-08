local T = import("test/environment.lua")
local water = import("goluwa/render3d/water.lua")
local fluid = import("goluwa/physics/fluid.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local test_helpers = import("test/tests/physics/test_helpers.lua")
local sample = {}

T.Test("Ocean waves are a pure function of position and game time", function()
	water.SetOcean{WindSpeed = 8, SwellHeight = 0.6, Seed = 3}
	water.SampleOcean(12.5, -7.25, 123.4, 0, sample)
	local height, velocity_y = sample.height, sample.velocity_y
	water.SampleOcean(12.5, -7.25, 123.4, 0, sample)
	T(sample.height)["=="](height)
	T(sample.velocity_y)["=="](velocity_y)
end)

T.Test("Ocean waves repeat after the wave period", function()
	water.SetOcean{WindSpeed = 8, SwellHeight = 0.6, Seed = 3}
	water.SampleOcean(40, 15, 17.3, 0, sample)
	local height, slope_x = sample.height, sample.slope_x
	water.SampleOcean(40, 15, 17.3 + water.WAVE_PERIOD * 3, 0, sample)
	T(math.abs(sample.height - height))["<"](1e-6)
	T(math.abs(sample.slope_x - slope_x))["<"](1e-6)
end)

T.Test("Ocean wave velocity is the derivative of its height", function()
	water.SetOcean{WindSpeed = 8, SwellHeight = 0.6, Seed = 3, Choppiness = 0}
	local h = 1e-4
	water.SampleOcean(5, 9, 50, 0, sample)
	local velocity_y = sample.velocity_y
	water.SampleOcean(5, 9, 50 + h, 0, sample)
	local after = sample.height
	water.SampleOcean(5, 9, 50 - h, 0, sample)
	T(math.abs((after - sample.height) / (2 * h) - velocity_y))["<"](1e-3)
end)

T.Test("Ocean sampling ignores waves shorter than the body", function()
	water.SetOcean{WindSpeed = 8, SwellHeight = 0.6, Seed = 3}
	water.SampleOcean(0, 0, 10, 0, sample)
	local all = sample.height
	water.SampleOcean(0, 0, 10, 1e9, sample)
	T(sample.height)["=="](0)
	T(all)["~="](0)
end)

T.TestPhysics("Floating bodies ride the ocean waves", function()
	water.SetOcean{WindSpeed = 8, SwellHeight = 1.2, SwellWavelength = 40, Seed = 5}
	fluid.SetOceanLevel(0)
	local ent = Entity.New({Name = "wave_floater"})
	ent:AddComponent("transform")
	ent.transform:SetPosition(Vec3(0, 1, 0))
	local body = ent:AddComponent(
		"rigid_body",
		{Shape = BoxShape.New(Vec3(2, 1, 2)), Density = 400, CanSleep = true}
	)
	local low, high = math.huge, -math.huge

	for _ = 1, 40 do
		test_helpers.Simulate(60)
		local y = ent.transform:GetPosition().y
		low, high = math.min(low, y), math.max(high, y)
	end

	T(high - low)[">"](0.1)
	T(body:GetAwake())["=="](true)
	T(body.SubmergedFraction)[">"](0.2)
	fluid.SetOceanLevel(nil)
	ent:Remove()
end)

T.Test("Game time follows the server clock with the lowest latency sample", function()
	local system = import("goluwa/system.lua")
	system.ResetGameTime()
	local elapsed = system.GetElapsedTime()
	system.SetServerTime(elapsed + 100 - 0.08)
	system.SetServerTime(elapsed + 100 - 0.02)
	system.SetServerTime(elapsed + 100 - 0.2)
	T(math.abs(system.GetGameTime() - (elapsed + 100 - 0.02 - 0.18 * 0.02)))["<"](1e-9)
	system.ResetGameTime()
	T(system.GetGameTime())["=="](elapsed)
end)
