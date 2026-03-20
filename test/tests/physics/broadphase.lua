local T = import("test/environment.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Quat = import("goluwa/structs/quat.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local broadphase = import("goluwa/physics/broadphase.lua")
local test_helpers = import("test/tests/physics/test_helpers.lua")
local identity_rotation = Quat(0, 0, 0, 1)

local function set_mock_bounds(body, current_bounds, previous_bounds)
	function body:GetBroadphaseAABB(position)
		local bounds = position and previous_bounds or current_bounds
		return AABB(
			bounds.min_x,
			bounds.min_y,
			bounds.min_z,
			bounds.max_x,
			bounds.max_y,
			bounds.max_z
		)
	end
end

local function create_mock_body(name, current_bounds, previous_bounds)
	local body = test_helpers.CreateStubBody{
		Name = name,
		Owner = nil,
		IncludeDefaultOwner = false,
		Rotation = identity_rotation,
		PreviousRotation = identity_rotation,
	}

	set_mock_bounds(body, current_bounds, previous_bounds)

	function body:SetBroadphaseBounds(new_current_bounds, new_previous_bounds)
		current_bounds = new_current_bounds
		previous_bounds = new_previous_bounds or new_current_bounds
		set_mock_bounds(self, current_bounds, previous_bounds)
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

T.Test("Broadphase handles very large entries without dropping nearby pairs", function()
	local giant = create_mock_body(
		"giant",
		{min_x = -10, min_y = -10, min_z = -10, max_x = 10, max_y = 10, max_z = 10},
		{min_x = -10, min_y = -10, min_z = -10, max_x = 10, max_y = 10, max_z = 10}
	)
	local nearby = create_mock_body(
		"nearby",
		{min_x = 9.5, min_y = -0.5, min_z = -0.5, max_x = 10.5, max_y = 0.5, max_z = 0.5},
		{min_x = 9.5, min_y = -0.5, min_z = -0.5, max_x = 10.5, max_y = 0.5, max_z = 0.5}
	)
	local far = create_mock_body(
		"far",
		{min_x = 30, min_y = 30, min_z = 30, max_x = 31, max_y = 31, max_z = 31},
		{min_x = 30, min_y = 30, min_z = 30, max_x = 31, max_y = 31, max_z = 31}
	)
	local pairs = broadphase.BuildCandidatePairs(mock_physics, {giant, nearby, far})
	T(#pairs)["=="](1)
	T(pairs[1].entry_a.body == giant or pairs[1].entry_b.body == giant)["=="](true)
	T(pairs[1].entry_a.body == nearby or pairs[1].entry_b.body == nearby)["=="](true)
end)

T.Test("Broadphase overflow entries still report nearby overlaps", function()
	local giant = create_mock_body(
		"overflow_giant",
		{min_x = -10, min_y = -10, min_z = -10, max_x = 10, max_y = 10, max_z = 10},
		{min_x = -10, min_y = -10, min_z = -10, max_x = 10, max_y = 10, max_z = 10}
	)
	local nearby = create_mock_body(
		"overflow_nearby",
		{min_x = 9.5, min_y = -0.5, min_z = -0.5, max_x = 10.5, max_y = 0.5, max_z = 0.5},
		{min_x = 9.5, min_y = -0.5, min_z = -0.5, max_x = 10.5, max_y = 0.5, max_z = 0.5}
	)
	local pairs = broadphase.BuildCandidatePairs(mock_physics, {giant, nearby}, {cell_size = 1, max_cells_per_entry = 8})
	T(#pairs)["=="](1)
	T(pairs[1].entry_a.body == giant or pairs[1].entry_b.body == giant)["=="](true)
	T(pairs[1].entry_a.body == nearby or pairs[1].entry_b.body == nearby)["=="](true)
end)

T.Test("Persistent broadphase updates pairs when bodies move apart", function()
	local phase = broadphase.New({physics = mock_physics, cell_size = 1})
	local body_a = create_mock_body(
		"dynamic_a",
		{min_x = -0.5, min_y = -0.5, min_z = -0.5, max_x = 0.5, max_y = 0.5, max_z = 0.5},
		{min_x = -0.5, min_y = -0.5, min_z = -0.5, max_x = 0.5, max_y = 0.5, max_z = 0.5}
	)
	local body_b = create_mock_body(
		"dynamic_b",
		{min_x = 0.25, min_y = -0.5, min_z = -0.5, max_x = 1.25, max_y = 0.5, max_z = 0.5},
		{min_x = 0.25, min_y = -0.5, min_z = -0.5, max_x = 1.25, max_y = 0.5, max_z = 0.5}
	)
	local pairs = phase:BuildCandidatePairs({body_a, body_b})
	T(#pairs)["=="](1)
	body_b:SetBroadphaseBounds(
		{min_x = 4, min_y = -0.5, min_z = -0.5, max_x = 5, max_y = 0.5, max_z = 0.5},
		{min_x = 4, min_y = -0.5, min_z = -0.5, max_x = 5, max_y = 0.5, max_z = 0.5}
	)
	pairs = phase:BuildCandidatePairs({body_a, body_b})
	T(#pairs)["=="](0)
end)

T.Test("Persistent broadphase removes stale pairs when bodies disappear", function()
	local phase = broadphase.New({physics = mock_physics, cell_size = 1})
	local body_a = create_mock_body(
		"remove_a",
		{min_x = -0.5, min_y = -0.5, min_z = -0.5, max_x = 0.5, max_y = 0.5, max_z = 0.5},
		{min_x = -0.5, min_y = -0.5, min_z = -0.5, max_x = 0.5, max_y = 0.5, max_z = 0.5}
	)
	local body_b = create_mock_body(
		"remove_b",
		{min_x = 0.25, min_y = -0.5, min_z = -0.5, max_x = 1.25, max_y = 0.5, max_z = 0.5},
		{min_x = 0.25, min_y = -0.5, min_z = -0.5, max_x = 1.25, max_y = 0.5, max_z = 0.5}
	)
	local pairs = phase:BuildCandidatePairs({body_a, body_b})
	T(#pairs)["=="](1)
	pairs = phase:BuildCandidatePairs({body_a})
	T(#pairs)["=="](0)
end)

T.Test("Persistent broadphase overflow entries do not hang and still collide", function()
	local phase = broadphase.New({physics = mock_physics, cell_size = 1, max_cells_per_entry = 8})
	local giant = create_mock_body(
		"persistent_overflow_giant",
		{min_x = -10, min_y = -10, min_z = -10, max_x = 10, max_y = 10, max_z = 10},
		{min_x = -10, min_y = -10, min_z = -10, max_x = 10, max_y = 10, max_z = 10}
	)
	local nearby = create_mock_body(
		"persistent_overflow_nearby",
		{min_x = 9.5, min_y = -0.5, min_z = -0.5, max_x = 10.5, max_y = 0.5, max_z = 0.5},
		{min_x = 9.5, min_y = -0.5, min_z = -0.5, max_x = 10.5, max_y = 0.5, max_z = 0.5}
	)
	local pairs = phase:BuildCandidatePairs({giant, nearby})
	T(#pairs)["=="](1)
	T(pairs[1].entry_a.body == giant or pairs[1].entry_b.body == giant)["=="](true)
	T(pairs[1].entry_a.body == nearby or pairs[1].entry_b.body == nearby)["=="](true)
end)
