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
	local pairs = broadphase.New{physics = mock_physics}:BuildCandidatePairs({body_a, body_b})
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
	local pairs = broadphase.New{physics = mock_physics}:BuildCandidatePairs({giant, nearby, far})
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
	local pairs = broadphase.New{physics = mock_physics, cell_size = 1, max_cells_per_entry = 8}:BuildCandidatePairs({giant, nearby})
	T(#pairs)["=="](1)
	T(pairs[1].entry_a.body == giant or pairs[1].entry_b.body == giant)["=="](true)
	T(pairs[1].entry_a.body == nearby or pairs[1].entry_b.body == nearby)["=="](true)
end)

T.Test("Persistent broadphase removes stale pairs when bodies disappear", function()
	local phase = broadphase.New{physics = mock_physics, cell_size = 1}
	local body_a = create_mock_body(
		"remove_a",
		{min_x = -0.5, min_y = -0.5, min_z = -0.5, max_x = 0.5, max_y = 0.5, max_z = 0.5},
		{min_x = -0.5, min_y = -0.5, min_z = -0.5, max_x = 0.5, max_y = 0.5, max_z = 0.5}
	)
	local body_b = create_mock_body(
		"remove_b",
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
	local pairs = phase:BuildCandidatePairs({body_a, body_b})
	T(#pairs)["=="](1)
	pairs = phase:BuildCandidatePairs({body_a})
	T(#pairs)["=="](0)
end)

T.Test("Persistent broadphase overflow entries do not hang and still collide", function()
	local phase = broadphase.New{physics = mock_physics, cell_size = 1, max_cells_per_entry = 8}
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

T.Test("Broadphase refreshes bounds when a body is mutated in place", function()
	local body = create_mock_body("in_place_body", AABB(0, 0, 0, 1, 1, 1), AABB(0, 0, 0, 1, 1, 1))
	local bp = broadphase.New({physics = mock_physics})
	bp:TrackBodies({body}, mock_physics)
	local entry = bp.BodyEntries[body]
	local pad = entry.bounds.max_x - 1
	T(pad)[">="](0)
	body:GetPosition().x = 5
	body:SetBroadphaseBounds(AABB(5, 0, 0, 6, 1, 1), AABB(0, 0, 0, 1, 1, 1))
	bp:TrackBodies({body}, mock_physics)
	T(entry.bounds.max_x)["~"](6 + pad, 0.000001)
end)

T.Test("Broadphase queries over huge boxes scan the entries instead of every cell", function()
	local phase = broadphase.New{physics = mock_physics, cell_size = 1}
	local unit = {min_x = 0, min_y = 0, min_z = 0, max_x = 1, max_y = 1, max_z = 1}
	local near = create_mock_body("huge_query_near", unit, unit)
	local far = create_mock_body(
		"huge_query_far",
		{min_x = 100, min_y = 0, min_z = 0, max_x = 101, max_y = 1, max_z = 1},
		{min_x = 100, min_y = 0, min_z = 0, max_x = 101, max_y = 1, max_z = 1}
	)
	local giant = create_mock_body(
		"huge_query_giant",
		{min_x = -10, min_y = -10, min_z = -10, max_x = 10, max_y = 10, max_z = 10},
		{min_x = -10, min_y = -10, min_z = -10, max_x = 10, max_y = 10, max_z = 10}
	)
	phase:TrackBodies({near, far, giant}, mock_physics)

	local function bodies_in(aabb)
		local found = {}

		for _, entry in ipairs(phase:QueryAABB(aabb)) do
			found[entry.body] = true
		end

		return found
	end

	local wide = bodies_in(AABB(-50, -5, -5, 50, 5, 5))
	T(wide[near])["=="](true)
	T(wide[far])["=="](nil)
	T(wide[giant])["=="](nil)
	local everything = bodies_in(AABB(-1e7, -1e7, -1e7, 1e7, 1e7, 1e7))
	T(everything[near])["=="](true)
	T(everything[far])["=="](true)
	T(everything[giant])["=="](nil)
	T(bodies_in(AABB(1e5, 1e5, 1e5, 1e7, 1e7, 1e7))[near])["=="](nil)
end)

T.Test("Persistent broadphase pairs bodies with a collision mask only while the mask is not zero", function()
	local phase = broadphase.New{physics = mock_physics, cell_size = 1}
	local box = AABB(-0.5, -0.5, -0.5, 0.5, 0.5, 0.5)
	local body_a = create_mock_body("mask_a", box, box)
	local body_b = create_mock_body("mask_b", box, box)
	body_b.CollisionMask = 0
	T(#phase:BuildCandidatePairs({body_a, body_b}))["=="](0)
	body_b.CollisionMask = -1
	T(#phase:BuildCandidatePairs({body_a, body_b}))["=="](1)
	body_b.CollisionMask = 0
	T(#phase:BuildCandidatePairs({body_a, body_b}))["=="](0)
end)
