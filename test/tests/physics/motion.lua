local T = import("test/environment.lua")
local motion = import("goluwa/physics/motion.lua")
local test_helpers = import("test/tests/physics/test_helpers.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")

local function create_mock_body(data)
	return test_helpers.CreateStubBody(data)
end

T.Test("Motion setters keep solver velocities authoritative without rewriting previous pose", function()
	local body = create_mock_body{
		Position = Vec3(4, 5, 6),
		PreviousPosition = Vec3(1, 2, 3),
		Rotation = Quat(0, 0, 0, 1),
		PreviousRotation = Quat(0.1, 0, 0, 0.995):GetNormalized(),
	}
	local previous_position = body.PreviousPosition:Copy()
	local previous_rotation = body.PreviousRotation:Copy()
	motion.SetBodyMotionFromCurrentState(body, Vec3(7, 8, 9), Vec3(1, 2, 3), 1 / 60)
	T(body.Velocity.x)["=="](7)
	T(body.Velocity.y)["=="](8)
	T(body.Velocity.z)["=="](9)
	T(body.AngularVelocity.x)["=="](1)
	T(body.AngularVelocity.y)["=="](2)
	T(body.AngularVelocity.z)["=="](3)
	T((body.PreviousPosition - previous_position):GetLength())["<"](0.000001)
	T(math.abs(body.PreviousRotation:Dot(previous_rotation) - 1))["<"](0.000001)
end)

T.Test("Motion setters ignore immovable bodies", function()
	local body = create_mock_body{
		Immovable = true,
		Velocity = Vec3(1, 0, 0),
		AngularVelocity = Vec3(0, 1, 0),
	}
	motion.SetBodyMotionFromCurrentState(body, Vec3(7, 8, 9), Vec3(1, 2, 3), 1 / 60)
	T(body.Velocity.x)["=="](1)
	T(body.AngularVelocity.y)["=="](1)
end)