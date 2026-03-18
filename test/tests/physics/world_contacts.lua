local T = import("test/environment.lua")
local physics = import("goluwa/physics.lua")
local world_contacts = import("goluwa/physics/world_contacts.lua")
local test_helpers = import("test/tests/physics/test_helpers.lua")
local Vec3 = import("goluwa/structs/vec3.lua")

local function count_pairs(tbl)
	local count = 0

	for _ in pairs(tbl or {}) do
		count = count + 1
	end

	return count
end

local function create_box_brush_model(mins, maxs)
	local primitive = {
		brush_planes = {
			{normal = Vec3(1, 0, 0), dist = maxs.x},
			{normal = Vec3(-1, 0, 0), dist = -mins.x},
			{normal = Vec3(0, 1, 0), dist = maxs.y},
			{normal = Vec3(0, -1, 0), dist = -mins.y},
			{normal = Vec3(0, 0, 1), dist = maxs.z},
			{normal = Vec3(0, 0, -1), dist = -mins.z},
		},
		aabb = {
			min_x = mins.x,
			min_y = mins.y,
			min_z = mins.z,
			max_x = maxs.x,
			max_y = maxs.y,
			max_z = maxs.z,
		},
	}
	local owner = {
		IsValid = function()
			return true
		end,
	}
	local model = {
		Owner = owner,
		Primitives = {primitive},
		AABB = primitive.aabb,
	}

	function model:GetWorldAABB()
		return self.AABB
	end

	return model, primitive
end

local function create_mock_body(data)
	return test_helpers.CreateTestRigidBody(data)
end

T.Test("World contacts use manifold-only world collision state", function()
	local old_trace = physics.Trace
	local old_source = physics.GetWorldTraceSource
	local old_record = physics.RecordWorldCollision
	local model = create_box_brush_model(Vec3(-1, -1, -1), Vec3(1, 0, 1))
	local body = create_mock_body{
		Position = Vec3(0, 0.05, 0),
		PreviousPosition = Vec3(0, 0.05, 0),
	}
	physics.Trace = function()
		error("legacy trace path should not run")
	end
	physics.GetWorldTraceSource = function()
		return {models = {model}}
	end
	physics.RecordWorldCollision = function() end
	world_contacts.SolveBodyContacts(body, 1 / 60)
	T(body.CorrectionCount)[">"](0)
	T(body.WorldContactManifold ~= nil)["=="](true)
	T(body.WorldContactManifold.manifold ~= nil)["=="](true)
	T(body.WorldContactManifold.support == nil)["=="](true)
	T(body.WorldContactManifold.motion == nil)["=="](true)
	T(body.WorldContactManifold.state.manifold.policy.kind)["=="]("manifold")
	T(next(body.WorldContactManifold.manifold) ~= nil)["=="](true)
	local _, entry = next(body.WorldContactManifold.manifold)
	T(entry.primitive_index)["=="](1)
	T(entry.feature_key ~= nil)["=="](true)
	physics.Trace = old_trace
	physics.GetWorldTraceSource = old_source
	physics.RecordWorldCollision = old_record
end)

T.Test("World contacts retain manifold feature entries briefly across flicker", function()
	local old_source = physics.GetWorldTraceSource
	local old_record = physics.RecordWorldCollision
	local model = create_box_brush_model(Vec3(-1, -1, -1), Vec3(1, 0, 1))
	local body = create_mock_body{
		Position = Vec3(0, 0.05, 0),
		PreviousPosition = Vec3(0, 0.05, 0),
	}
	physics.GetWorldTraceSource = function()
		return {models = {model}}
	end
	physics.RecordWorldCollision = function() end
	world_contacts.SolveBodyContacts(body, 1 / 60)
	local state = body.WorldContactManifold.state.manifold
	T(count_pairs(state.entries))["=="](1)
	physics.GetWorldTraceSource = function()
		return {models = {}}
	end
	world_contacts.SolveBodyContacts(body, 1 / 60)
	T(count_pairs(state.entries))["=="](1)
	world_contacts.SolveBodyContacts(body, 1 / 60)
	T(count_pairs(state.entries))["=="](1)
	world_contacts.SolveBodyContacts(body, 1 / 60)
	T(count_pairs(state.entries))["=="](0)
	physics.GetWorldTraceSource = old_source
	physics.RecordWorldCollision = old_record
end)

T.Test("World contacts expose manifold cache aliases without legacy per-kind caches", function()
	local old_source = physics.GetWorldTraceSource
	local old_record = physics.RecordWorldCollision
	local model = create_box_brush_model(Vec3(-1, -1, -1), Vec3(1, 0, 1))
	local body = create_mock_body{
		Position = Vec3(0, 0.05, 0),
		PreviousPosition = Vec3(0, 0.05, 0),
	}
	physics.GetWorldTraceSource = function()
		return {models = {model}}
	end
	physics.RecordWorldCollision = function() end
	world_contacts.SolveBodyContacts(body, 1 / 60)
	local cache = body.WorldContactManifold.manifold
	local state = body.WorldContactManifold.state.manifold
	local entry = nil

	for _, value in pairs(state.entries) do
		entry = value

		break
	end

	T(entry ~= nil)["=="](true)
	T(entry.local_point_key ~= nil)["=="](true)
	T(entry.feature_key ~= nil)["=="](true)
	T(cache[entry.local_point_key])["=="](entry)
	T(cache[entry.feature_key])["=="](entry)
	T(body.WorldManifoldContactCache == nil)["=="](true)
	T(body.WorldSupportContactCache == nil)["=="](true)
	T(body.WorldMotionContactCache == nil)["=="](true)
	physics.GetWorldTraceSource = old_source
	physics.RecordWorldCollision = old_record
end)
