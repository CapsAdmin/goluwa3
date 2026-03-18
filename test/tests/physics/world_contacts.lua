local T = import("test/environment.lua")
local physics = import("goluwa/physics.lua")
local world_contacts = import("goluwa/physics/world_contacts.lua")
local world_contact_state = import("goluwa/physics/world_contact/state.lua")
local contact_resolution = import("goluwa/physics/contact_resolution.lua")
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

local function create_event_owner(name, sink)
	return {
		Name = name,
		transform = {
			position = Vec3(),
			rotation = nil,
		},
		IsValid = function()
			return true
		end,
		CallLocalEvent = function(self, what, other, data)
			sink.events[#sink.events + 1] = {
				owner = self.Name,
				what = what,
				other = other,
				data = data,
			}
		end,
	}
end

T.Test("World contacts use manifold-only world collision state", function()
	local old_trace = physics.Trace
	local old_source = physics.GetWorldTraceSource
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
	world_contacts.SolveBodyContacts(body, 1 / 60)
	T(body.CorrectionCount)[">"](0)
	T(body.WorldContactManifold ~= nil)["=="](true)
	T(body.WorldContactManifold.manifold ~= nil)["=="](true)
	T(body.WorldContactManifold.support == nil)["=="](true)
	T(body.WorldContactManifold.motion == nil)["=="](true)
	T(body.WorldContactManifold.state.manifold.policy.kind)["=="]("manifold")
	local entry = body.WorldContactManifold.state.manifold.entries[1]
	T(entry ~= nil)["=="](true)
	T(entry.primitive_index)["=="](1)
	T(entry.feature_key ~= nil)["=="](true)
	T(body.WorldContactManifold.manifold.local_points ~= nil)["=="](true)
	T(body.WorldContactManifold.manifold.feature_entities ~= nil)["=="](true)
	physics.Trace = old_trace
	physics.GetWorldTraceSource = old_source
end)

T.Test("World contacts retain manifold feature entries briefly across flicker", function()
	local old_source = physics.GetWorldTraceSource
	local model = create_box_brush_model(Vec3(-1, -1, -1), Vec3(1, 0, 1))
	local body = create_mock_body{
		Position = Vec3(0, 0.05, 0),
		PreviousPosition = Vec3(0, 0.05, 0),
	}
	physics.GetWorldTraceSource = function()
		return {models = {model}}
	end
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
end)

T.Test("World contacts keep structured manifold caches without legacy per-kind caches", function()
	local old_source = physics.GetWorldTraceSource
	local model = create_box_brush_model(Vec3(-1, -1, -1), Vec3(1, 0, 1))
	local body = create_mock_body{
		Position = Vec3(0, 0.05, 0),
		PreviousPosition = Vec3(0, 0.05, 0),
	}
	physics.GetWorldTraceSource = function()
		return {models = {model}}
	end
	world_contacts.SolveBodyContacts(body, 1 / 60)
	local cache = body.WorldContactManifold.manifold
	local state = body.WorldContactManifold.state.manifold
	local entry = state.entries[1]
	T(entry ~= nil)["=="](true)
	T(entry.local_point_key ~= nil)["=="](true)
	T(entry.feature_key ~= nil)["=="](true)
	T(cache.local_points[entry.local_point_key])["=="](entry)
	T(cache.feature_entities[entry.feature_key.entity][entry.feature_key.token])["=="](entry)
	T(body.WorldManifoldContactCache == nil)["=="](true)
	T(body.WorldSupportContactCache == nil)["=="](true)
	T(body.WorldMotionContactCache == nil)["=="](true)
	physics.GetWorldTraceSource = old_source
end)

T.Test("Persistent manifolds stay symmetric when accessed in either body order", function()
	physics.ResetState()
	local solver = physics.solver
	local body_a = create_mock_body{Position = Vec3(0, 0, 0), PreviousPosition = Vec3(0, 0, 0)}
	local body_b = create_mock_body{Position = Vec3(0, 0.1, 0), PreviousPosition = Vec3(0, 0.1, 0)}
	local normal = Vec3(0, 1, 0)
	local contacts_ab = {
		{
			point_a = Vec3(0, 0, 0),
			point_b = Vec3(0, 0.1, 0),
		},
	}
	local contacts_ba = {
		{
			point_a = Vec3(0, 0.1, 0),
			point_b = Vec3(0, 0, 0),
		},
	}
	solver.StepStamp = 1
	contact_resolution.ResolvePairPenetration(
		body_a,
		body_b,
		normal,
		0.1,
		1 / 60,
		nil,
		nil,
		contacts_ab,
		{
			skip_grounding = true,
		}
	)
	local manifold_ab = solver.PersistentManifolds[body_a][body_b]
	local manifold_ba = solver.PersistentManifolds[body_b][body_a]
	T(manifold_ab ~= nil)["=="](true)
	T(manifold_ab)["=="](manifold_ba)
	solver.StepStamp = 2
	contact_resolution.ResolvePairPenetration(
		body_b,
		body_a,
		-normal,
		0.1,
		1 / 60,
		nil,
		nil,
		contacts_ba,
		{
			skip_grounding = true,
		}
	)
	T(solver.PersistentManifolds[body_a][body_b])["=="](manifold_ab)
	T(solver.PersistentManifolds[body_b][body_a])["=="](manifold_ab)
end)

T.Test("Collision pairs emit enter stay exit transitions for body and world contacts", function()
	physics.ResetState()
	local sink = {events = {}}
	local owner_a = create_event_owner("body_a", sink)
	local owner_b = create_event_owner("body_b", sink)
	local world_entity = create_event_owner("world", sink)
	local body_a = test_helpers.CreateStubBody({Owner = owner_a})
	local body_b = test_helpers.CreateStubBody({Owner = owner_b})
	local collision_pairs = physics.collision_pairs

	local function count_event(what, owner)
		local count = 0

		for _, event in ipairs(sink.events) do
			if event.what == what and event.owner == owner then count = count + 1 end
		end

		return count
	end

	collision_pairs:BeginCollisionFrame()
	collision_pairs:RecordCollisionPair(body_a, body_b, Vec3(0, 1, 0), 0.1)
	collision_pairs:RecordWorldCollision(body_a, {entity = world_entity}, Vec3(0, 1, 0), 0.05)
	collision_pairs:DispatchCollisionEvents()
	T(count_event("OnCollisionEnter", "body_a"))["=="](2)
	T(count_event("OnCollisionEnter", "body_b"))["=="](1)
	T(count_event("OnCollisionEnter", "world"))["=="](1)
	sink.events = {}
	collision_pairs:BeginCollisionFrame()
	collision_pairs:RecordCollisionPair(body_a, body_b, Vec3(0, 1, 0), 0.1)
	collision_pairs:RecordWorldCollision(body_a, {entity = world_entity}, Vec3(0, 1, 0), 0.05)
	collision_pairs:DispatchCollisionEvents()
	T(count_event("OnCollisionStay", "body_a"))["=="](2)
	T(count_event("OnCollisionStay", "body_b"))["=="](1)
	T(count_event("OnCollisionStay", "world"))["=="](1)
	sink.events = {}
	collision_pairs:BeginCollisionFrame()
	collision_pairs:DispatchCollisionEvents()
	T(count_event("OnCollisionExit", "body_a"))["=="](2)
	T(count_event("OnCollisionExit", "body_b"))["=="](1)
	T(count_event("OnCollisionExit", "world"))["=="](1)
end)

T.Test("World contact feature caches keep identical tokens separate across entities", function()
	physics.ResetState()
	local body = test_helpers.CreateStubBody{Position = Vec3(0, 0, 0), PreviousPosition = Vec3(0, 0, 0)}
	local state = world_contact_state.GetContactState(body, "manifold")
	local local_point_a = Vec3(0, 0, 0)
	local local_point_b = Vec3(0.1, 0, 0)
	local position = Vec3(1, 2, 3)
	local normal = Vec3(0, 1, 0)
	local entity_a = {Name = "entity_a"}
	local entity_b = {Name = "entity_b"}
	world_contact_state.CacheContacts(
		body,
		"manifold",
		{
			{
				local_point = local_point_a,
				point = position,
				position = position,
				normal = normal,
				depth = 0.1,
				hit = {entity = entity_a, primitive = {}, primitive_index = 1, triangle_index = 2},
			},
			{
				local_point = local_point_b,
				point = position,
				position = position,
				normal = normal,
				depth = 0.1,
				hit = {entity = entity_b, primitive = {}, primitive_index = 1, triangle_index = 2},
			},
		}
	)
	T(#state.entries)["=="](2)
	local _, cached_a = world_contact_state.GetCachedContactEntryForContact(
		body,
		"manifold",
		local_point_a,
		{entity = entity_a, primitive = {}, primitive_index = 1, triangle_index = 2},
		position,
		normal
	)
	local _, cached_b = world_contact_state.GetCachedContactEntryForContact(
		body,
		"manifold",
		local_point_b,
		{entity = entity_b, primitive = {}, primitive_index = 1, triangle_index = 2},
		position,
		normal
	)
	T(cached_a ~= nil)["=="](true)
	T(cached_b ~= nil)["=="](true)
	T(cached_a ~= cached_b)["=="](true)
	T(cached_a.entity)["=="](entity_a)
	T(cached_b.entity)["=="](entity_b)
end)
