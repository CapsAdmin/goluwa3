local T = import("test/environment.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local manifold = import("goluwa/physics/manifold.lua")
local test_helpers = import("test/tests/physics/test_helpers.lua")

local function create_mock_body(data)
	data = data or {}

	if data.Friction == nil then data.Friction = 1 end

	return test_helpers.CreateStubBody(data)
end

T.Test("Manifold rebuild preserves tangent impulse state for matched contacts", function()
	local body_a = create_mock_body()
	local body_b = create_mock_body{Position = Vec3(0, 1, 0)}
	local data = {
		contacts = {
			{
				local_point_a = Vec3(0, 0, 0),
				local_point_b = Vec3(0, -1, 0),
				normal_impulse = 2.5,
				tangent_impulse = 0.75,
				tangent = Vec3(1, 0, 0),
			},
		},
	}
	local rebuilt = manifold.RebuildContacts(
		body_a,
		body_b,
		data,
		{
			{point_a = Vec3(0.02, 0, 0), point_b = Vec3(0.02, 0, 0)},
		}
	)
	T(#rebuilt)["=="](1)
	T(rebuilt[1].normal_impulse)["=="](2.5)
	T(rebuilt[1].tangent_impulse)["=="](0.75)
	T(rebuilt[1].tangent.x)["=="](1)
	T(rebuilt[1].tangent.y)["=="](0)
	T(rebuilt[1].tangent.z)["=="](0)
end)

T.Test("Manifold warm start reapplies cached tangent impulses", function()
	local body_a = create_mock_body()
	local body_b = create_mock_body{Position = Vec3(0, 1, 0)}
	local data = {
		contacts = {
			{
				local_point_a = Vec3(),
				local_point_b = Vec3(0, -1, 0),
				normal_impulse = 0,
				tangent_impulse = 1,
				tangent = Vec3(1, 0, 0),
			},
		},
	}
	manifold.WarmStart(body_a, body_b, Vec3(0, 1, 0), data, 1 / 60)
	T(body_a:GetVelocity().x)["=="](-0.1)
	T(body_b:GetVelocity().x)["=="](0.1)
end)

T.Test("Manifold impulse solve accumulates tangent impulses across frames", function()
	local body_a = create_mock_body{Velocity = Vec3(1, 0, 0)}
	local body_b = create_mock_body{Position = Vec3(0, 1, 0)}
	local data = {
		contacts = {
			{
				local_point_a = Vec3(),
				local_point_b = Vec3(0, -1, 0),
				normal_impulse = 1,
				tangent_impulse = 0.2,
				tangent = Vec3(1, 0, 0),
			},
		},
	}
	local previous_impulse = data.contacts[1].tangent_impulse
	manifold.SolveImpulses(body_a, body_b, Vec3(0, 1, 0), data, 1 / 60)
	T(data.contacts[1].tangent ~= nil)["=="](true)
	T(math.abs(data.contacts[1].tangent_impulse))[">="](math.abs(previous_impulse))
	T(body_a:GetVelocity().x)["<"](1)
	T(math.abs(body_b:GetVelocity().x))[">"](0)
end)
