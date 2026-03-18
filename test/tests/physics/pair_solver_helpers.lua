local T = import("test/environment.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local pair_solver_helpers = import("goluwa/physics/pair_solver_helpers.lua")
local identity_rotation = Quat(0, 0, 0, 1)

local function create_mock_box_body(extents)
	extents = extents or Vec3(2, 1, 3)
	local shape = BoxShape.New(extents * 2)
	return {
		GetPhysicsShape = function()
			return shape
		end,
		WorldToLocal = function(_, point)
			return point
		end,
		LocalToWorld = function(_, point)
			return point
		end,
		GetRotation = function()
			return identity_rotation
		end,
	}
end

T.Test("Box contact helper returns a face point for interior sphere centers", function()
	local body = create_mock_box_body(Vec3(2, 1, 3))
	local contact = pair_solver_helpers.GetBoxContactForPoint(body, Vec3(0, 0.2, 0.1), 0.5)
	T(type(contact))["=="]("table")
	T(contact.normal.x)["=="](0)
	T(contact.normal.y)["=="](1)
	T(contact.normal.z)["=="](0)
	T(contact.point_a.x)["=="](0)
	T(contact.point_a.y)["=="](1)
	T(contact.point_a.z)["=="](0.1)
	T(contact.point_b.x)["=="](0)
	T(contact.point_b.y)["=="](-0.3)
	T(contact.point_b.z)["=="](0.1)
	T(contact.overlap)["=="](1.3)
end)

T.Test("Box contact helper chooses a stable exit axis for centered interior points", function()
	local body = create_mock_box_body(Vec3(2, 1, 3))
	local contact = pair_solver_helpers.GetBoxContactForPoint(body, Vec3(0, 0, 0), 0.25, Vec3(0, -1, 0))
	T(type(contact))["=="]("table")
	T(contact.normal.x)["=="](0)
	T(contact.normal.y)["=="](1)
	T(contact.normal.z)["=="](0)
	T(contact.point_a.y)["=="](1)
	T(contact.point_b.y)["=="](-0.25)
	T(contact.overlap)["=="](1.25)
end)
