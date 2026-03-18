local T = import("test/environment.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Quat = import("goluwa/structs/quat.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local broadphase = import("goluwa/physics/broadphase.lua")
local test_helpers = import("test/tests/physics/test_helpers.lua")
local identity_rotation = Quat(0, 0, 0, 1)

local function create_mock_body(name, current_bounds, previous_bounds)
	local body = test_helpers.CreateStubBody{
		Name = name,
		Owner = nil,
		IncludeDefaultOwner = false,
		Rotation = identity_rotation,
		PreviousRotation = identity_rotation,
	}

	function body:GetBroadphaseAABB(position)
		if position then
			return AABB(
				previous_bounds.min_x,
				previous_bounds.min_y,
				previous_bounds.min_z,
				previous_bounds.max_x,
				previous_bounds.max_y,
				previous_bounds.max_z
			)
		end

		return AABB(
			current_bounds.min_x,
			current_bounds.min_y,
			current_bounds.min_z,
			current_bounds.max_x,
			current_bounds.max_y,
			current_bounds.max_z
		)
	end

	return body
end

local mock_physics = {
	IsActiveRigidBody = function(body)
		return body ~= nil
	end,
}

T.Test("Broadphase pair building from entries matches direct pair building", function()
	local body_a = create_mock_body(
		"a",
		{min_x = -0.5, min_y = -0.5, min_z = -0.5, max_x = 0.5, max_y = 0.5, max_z = 0.5},
		{min_x = -0.5, min_y = -0.5, min_z = -0.5, max_x = 0.5, max_y = 0.5, max_z = 0.5}
	)
	local body_b = create_mock_body(
		"b",
		{
			min_x = 0.25,
			min_y = -0.5,
			min_z = -0.5,
			max_x = 1.25,
			max_y = 0.5,
			max_z = 0.5,
		},
		{
			min_x = 0.25,
			min_y = -0.5,
			min_z = -0.5,
			max_x = 1.25,
			max_y = 0.5,
			max_z = 0.5,
		}
	)
	local bodies = {body_a, body_b}
	local entries = broadphase.BuildEntries(mock_physics, bodies)
	local pairs_from_entries = broadphase.BuildCandidatePairsFromEntries(entries)
	local pairs_direct = broadphase.BuildCandidatePairs(mock_physics, bodies)
	T(#entries)["=="](2)
	T(#pairs_from_entries)["=="](1)
	T(#pairs_direct)["=="](1)
	T(
		pairs_from_entries[1].entry_a.body == pairs_direct[1].entry_a.body or
			pairs_from_entries[1].entry_a.body == pairs_direct[1].entry_b.body
	)["=="](true)
	T(
		pairs_from_entries[1].entry_b.body == pairs_direct[1].entry_a.body or
			pairs_from_entries[1].entry_b.body == pairs_direct[1].entry_b.body
	)["=="](true)
end)

T.Test("Broadphase keeps swept pairs when bodies overlap only through previous bounds", function()
	local body_a = create_mock_body(
		"swept_a",
		{min_x = 2.0, min_y = -0.5, min_z = -0.5, max_x = 3.0, max_y = 0.5, max_z = 0.5},
		{min_x = -0.5, min_y = -0.5, min_z = -0.5, max_x = 0.5, max_y = 0.5, max_z = 0.5}
	)
	local body_b = create_mock_body(
		"swept_b",
		{min_x = -0.4, min_y = -0.5, min_z = -0.5, max_x = 0.4, max_y = 0.5, max_z = 0.5},
		{min_x = -0.4, min_y = -0.5, min_z = -0.5, max_x = 0.4, max_y = 0.5, max_z = 0.5}
	)
	local pairs = broadphase.BuildCandidatePairs(mock_physics, {body_a, body_b})
	T(#pairs)["=="](1)
	T(pairs[1].entry_a.body == body_a or pairs[1].entry_b.body == body_a)["=="](true)
	T(pairs[1].entry_a.body == body_b or pairs[1].entry_b.body == body_b)["=="](true)
end)