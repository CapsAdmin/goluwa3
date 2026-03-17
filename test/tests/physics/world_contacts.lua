local T = import("test/environment.lua")
local physics = import("goluwa/physics.lua")
local world_contacts = import("goluwa/physics/world_contacts.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")

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
	data = data or {}
	local radius = data.Radius or 0.1
	local margin = data.Margin or 0.01
	local body = {
		CollisionEnabled = true,
		Position = data.Position or Vec3(),
		PreviousPosition = data.PreviousPosition or data.Position or Vec3(),
		Rotation = data.Rotation or Quat():Identity(),
		PreviousRotation = data.PreviousRotation or data.Rotation or Quat():Identity(),
		Velocity = data.Velocity or Vec3(),
		AngularVelocity = data.AngularVelocity or Vec3(),
		CorrectionCount = 0,
		Grounded = false,
		GroundNormal = physics.Up,
		Owner = {
			IsValid = function()
				return true
			end,
		},
	}
	local shape = {
		GetRadius = function()
			return radius
		end,
	}

	function body:GetPosition()
		return self.Position
	end

	function body:GetPreviousPosition()
		return self.PreviousPosition
	end

	function body:GetRotation()
		return self.Rotation
	end

	function body:GetPreviousRotation()
		return self.PreviousRotation
	end

	function body:GetVelocity()
		return self.Velocity
	end

	function body:GetAngularVelocity()
		return self.AngularVelocity
	end

	function body:GetCollisionMargin()
		return margin
	end

	function body:GetCollisionProbeDistance()
		return 0
	end

	function body:GetCollisionLocalPoints()
		return {Vec3(0, -radius, 0)}
	end

	function body:GetSupportLocalPoints()
		return {Vec3(0, -radius, 0)}
	end

	function body:GetOwner()
		return self.Owner
	end

	function body:GetFilterFunction()
		return nil
	end

	function body:GetMinGroundNormalY()
		return 0.7
	end

	function body:GetGrounded()
		return self.Grounded
	end

	function body:SetGrounded(grounded)
		self.Grounded = grounded
	end

	function body:SetGroundNormal(normal)
		self.GroundNormal = normal
	end

	function body:GetPhysicsShape()
		return shape
	end

	function body:GetShapeType()
		return "sphere"
	end

	function body:GetColliders()
		return {self}
	end

	function body:LocalToWorld(local_point, position)
		return (position or self.Position) + local_point
	end

	function body:GeometryLocalToWorld(local_point, position)
		return self:LocalToWorld(local_point, position)
	end

	function body:WorldToLocal(world_point, position)
		return world_point - (position or self.Position)
	end

	function body:GetBroadphaseAABB()
		local inflate = radius + margin
		return {
			min_x = self.Position.x - inflate,
			min_y = self.Position.y - inflate,
			min_z = self.Position.z - inflate,
			max_x = self.Position.x + inflate,
			max_y = self.Position.y + inflate,
			max_z = self.Position.z + inflate,
		}
	end

	function body:ApplyCorrection(_, _, point)
		self.CorrectionCount = self.CorrectionCount + 1
		self.LastCorrectionPoint = point and point:Copy() or nil
	end

	function body:HasSolverMass()
		return false
	end

	function body:ApplyImpulse() end

	function body:GetInverseMassAlong()
		return 0
	end

	function body:GetFriction()
		return 0
	end

	return body
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