local T = import("test/environment.lua")
local physics = import("goluwa/physics.lua")
local world_contacts = import("goluwa/physics/world_contacts.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")

local function create_mock_body(data)
	data = data or {}
	local body = {
		CollisionEnabled = true,
		Position = data.Position or Vec3(),
		PreviousPosition = data.PreviousPosition or Vec3(),
		Rotation = data.Rotation or Quat():Identity(),
		PreviousRotation = data.PreviousRotation or Quat():Identity(),
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
		return 0.01
	end

	function body:GetCollisionProbeDistance()
		return 0
	end

	function body:GetCollisionLocalPoints()
		return {Vec3()}
	end

	function body:GetSupportLocalPoints()
		return {}
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
		return nil
	end

	function body:GeometryLocalToWorld(local_point, position)
		return (position or self.Position) + local_point
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

T.Test("World contacts keep cached motion contacts in a unified manifold structure", function()
	local old_trace = physics.Trace
	local old_surface_contact = physics.GetHitSurfaceContact
	local old_record_world_collision = physics.RecordWorldCollision
	local old_world_trace_source = physics.GetWorldTraceSource
	local body = create_mock_body{
		PreviousPosition = Vec3(0, 0, 0),
		Position = Vec3(0.05, 0, 0),
		Velocity = Vec3(0.03, 0, 0),
	}
	local hit = {
		entity = {
			IsValid = function()
				return true
			end,
		},
		primitive = {},
		primitive_index = 1,
		distance = 0.02,
		position = Vec3(0, 0, 0),
	}
	local trace_calls = 0
	physics.RecordWorldCollision = function() end
	physics.GetHitSurfaceContact = function()
		return {
			normal = Vec3(-1, 0, 0),
			position = Vec3(0, 0, 0),
		}
	end
	physics.Trace = function()
		trace_calls = trace_calls + 1

		if trace_calls == 1 then return hit end

		return nil
	end
	world_contacts.SolveBodyContacts(body, 1 / 60)
	T(body.CorrectionCount)[">"](0)
	T(body.WorldContactManifold ~= nil)["=="](true)
	T(body.WorldContactManifold.motion ~= nil)["=="](true)
	T(body.WorldMotionContactCache == body.WorldContactManifold.motion)["=="](true)
	T(next(body.WorldContactManifold.motion) ~= nil)["=="](true)
	body.PreviousPosition = body.Position:Copy()
	body.Position = Vec3(0.08, 0, 0)
	body.CorrectionCount = 0
	world_contacts.SolveBodyContacts(body, 1 / 60)
	T(body.CorrectionCount)[">"](0)
	T(next(body.WorldContactManifold.motion) ~= nil)["=="](true)
	physics.Trace = old_trace
	physics.GetHitSurfaceContact = old_surface_contact
	physics.RecordWorldCollision = old_record_world_collision
	physics.GetWorldTraceSource = old_world_trace_source
end)

T.Test("World contacts keep cached support contacts in a unified manifold structure", function()
	local old_trace = physics.Trace
	local old_surface_contact = physics.GetHitSurfaceContact
	local old_record_world_collision = physics.RecordWorldCollision
	local old_world_trace_source = physics.GetWorldTraceSource
	local body = create_mock_body{
		PreviousPosition = Vec3(0, 0.005, 0),
		Position = Vec3(0, 0.005, 0),
		Grounded = true,
	}
	local hit = {
		entity = {
			IsValid = function()
				return true
			end,
		},
		primitive = {},
		primitive_index = 2,
		distance = 0.01,
		position = Vec3(0, 0, 0),
	}
	local trace_calls = 0

	function body:GetCollisionLocalPoints()
		return {}
	end

	function body:GetSupportLocalPoints()
		return {Vec3()}
	end

	physics.RecordWorldCollision = function() end
	physics.GetHitSurfaceContact = function()
		return {
			normal = Vec3(0, 1, 0),
			position = Vec3(0, 0, 0),
		}
	end
	physics.GetWorldTraceSource = function()
		return {}
	end
	physics.Trace = function()
		trace_calls = trace_calls + 1

		if trace_calls == 1 then return hit end

		return nil
	end
	world_contacts.SolveBodyContacts(body, 1 / 60)
	T(body.CorrectionCount)[">"](0)
	T(body.WorldContactManifold ~= nil)["=="](true)
	T(body.WorldContactManifold.support ~= nil)["=="](true)
	T(body.WorldSupportContactCache == body.WorldContactManifold.support)["=="](true)
	T(next(body.WorldContactManifold.support) ~= nil)["=="](true)
	body.CorrectionCount = 0
	world_contacts.SolveBodyContacts(body, 1 / 60)
	T(body.CorrectionCount)[">"](0)
	T(next(body.WorldContactManifold.support) ~= nil)["=="](true)
	physics.Trace = old_trace
	physics.GetHitSurfaceContact = old_surface_contact
	physics.RecordWorldCollision = old_record_world_collision
	physics.GetWorldTraceSource = old_world_trace_source
end)

T.Test("World contacts keep support and motion manifolds separate within the unified cache", function()
	local old_trace = physics.Trace
	local old_surface_contact = physics.GetHitSurfaceContact
	local old_record_world_collision = physics.RecordWorldCollision
	local old_world_trace_source = physics.GetWorldTraceSource
	local body = create_mock_body{
		PreviousPosition = Vec3(0, 0.005, 0),
		Position = Vec3(0.05, 0.005, 0),
		Velocity = Vec3(0.03, 0, 0),
	}
	local motion_hit = {
		entity = {
			IsValid = function()
				return true
			end,
		},
		primitive = {kind = "motion"},
		primitive_index = 3,
		distance = 0.02,
		position = Vec3(0, 0.005, 0),
	}
	local support_hit = {
		entity = {
			IsValid = function()
				return true
			end,
		},
		primitive = {kind = "support"},
		primitive_index = 4,
		distance = 0.01,
		position = Vec3(0.05, 0, 0),
	}

	function body:GetCollisionLocalPoints()
		return {Vec3()}
	end

	function body:GetSupportLocalPoints()
		return {Vec3()}
	end

	physics.RecordWorldCollision = function() end
	physics.GetWorldTraceSource = function()
		return {}
	end
	physics.GetHitSurfaceContact = function(hit)
		if hit == motion_hit then
			return {
				normal = Vec3(-1, 0, 0),
				position = Vec3(0, 0.005, 0),
			}
		end

		return {
			normal = Vec3(0, 1, 0),
			position = Vec3(0.05, 0, 0),
		}
	end
	physics.Trace = function(_, direction)
		if math.abs(direction.x) > 0.0001 then return motion_hit end

		if direction.y < -0.5 then return support_hit end

		return nil
	end
	world_contacts.SolveBodyContacts(body, 1 / 60)
	T(body.WorldContactManifold ~= nil)["=="](true)
	T(body.WorldContactManifold.motion ~= nil)["=="](true)
	T(body.WorldContactManifold.support ~= nil)["=="](true)
	T(body.WorldContactManifold.motion == body.WorldContactManifold.support)["=="](false)
	T(next(body.WorldContactManifold.motion) ~= nil)["=="](true)
	T(next(body.WorldContactManifold.support) ~= nil)["=="](true)
	T(body.WorldContactManifold.motion["0.00000|0.00000|0.00000"].primitive_index)["=="](3)
	T(body.WorldContactManifold.support["0.00000|0.00000|0.00000"].primitive_index)["=="](4)
	physics.Trace = old_trace
	physics.GetHitSurfaceContact = old_surface_contact
	physics.RecordWorldCollision = old_record_world_collision
	physics.GetWorldTraceSource = old_world_trace_source
end)

T.Test("World contacts adopt legacy support and motion caches into the unified manifold", function()
	local old_trace = physics.Trace
	local old_surface_contact = physics.GetHitSurfaceContact
	local old_record_world_collision = physics.RecordWorldCollision
	local old_world_trace_source = physics.GetWorldTraceSource
	local body = create_mock_body{
		PreviousPosition = Vec3(0, 0.005, 0),
		Position = Vec3(0.05, 0.005, 0),
		Velocity = Vec3(0.03, 0, 0),
	}
	local legacy_support = {
		["0.00000|0.00000|0.00000"] = {primitive_index = 10},
	}
	local legacy_motion = {
		["1.00000|0.00000|0.00000"] = {primitive_index = 11},
	}
	local motion_hit = {
		entity = {
			IsValid = function()
				return true
			end,
		},
		primitive = {kind = "motion"},
		primitive_index = 12,
		distance = 0.02,
		position = Vec3(0, 0.005, 0),
	}
	local support_hit = {
		entity = {
			IsValid = function()
				return true
			end,
		},
		primitive = {kind = "support"},
		primitive_index = 13,
		distance = 0.01,
		position = Vec3(0.05, 0, 0),
	}

	function body:GetCollisionLocalPoints()
		return {Vec3()}
	end

	function body:GetSupportLocalPoints()
		return {Vec3()}
	end

	body.WorldSupportContactCache = legacy_support
	body.WorldMotionContactCache = legacy_motion
	physics.RecordWorldCollision = function() end
	physics.GetWorldTraceSource = function()
		return {}
	end
	physics.GetHitSurfaceContact = function(hit)
		if hit == motion_hit then
			return {
				normal = Vec3(-1, 0, 0),
				position = Vec3(0, 0.005, 0),
			}
		end

		return {
			normal = Vec3(0, 1, 0),
			position = Vec3(0.05, 0, 0),
		}
	end
	physics.Trace = function(_, direction)
		if math.abs(direction.x) > 0.0001 then return motion_hit end

		if direction.y < -0.5 then return support_hit end

		return nil
	end
	world_contacts.SolveBodyContacts(body, 1 / 60)
	T(body.WorldContactManifold ~= nil)["=="](true)
	T(body.WorldContactManifold.support)["=="](legacy_support)
	T(body.WorldContactManifold.motion)["=="](legacy_motion)
	T(body.WorldSupportContactCache)["=="](legacy_support)
	T(body.WorldMotionContactCache)["=="](legacy_motion)
	T(body.WorldContactManifold.motion["0.00000|0.00000|0.00000"].primitive_index)["=="](12)
	T(body.WorldContactManifold.support["0.00000|0.00000|0.00000"].primitive_index)["=="](13)
	physics.Trace = old_trace
	physics.GetHitSurfaceContact = old_surface_contact
	physics.RecordWorldCollision = old_record_world_collision
	physics.GetWorldTraceSource = old_world_trace_source
end)

T.Test("World contacts expose per-kind manifold state without replacing cache tables", function()
	local body = create_mock_body{}
	local support_cache = {support = true}
	local motion_cache = {motion = true}
	body.WorldSupportContactCache = support_cache
	body.WorldMotionContactCache = motion_cache
	world_contacts.SolveBodyContacts(body, 1 / 60)
	T(body.WorldContactManifold ~= nil)["=="](true)
	T(body.WorldContactManifold.state ~= nil)["=="](true)
	T(body.WorldContactManifold.state.support ~= nil)["=="](true)
	T(body.WorldContactManifold.state.motion ~= nil)["=="](true)
	T(body.WorldContactManifold.state.support.cache)["=="](support_cache)
	T(body.WorldContactManifold.state.motion.cache)["=="](motion_cache)
	T(body.WorldContactManifold.state.support.policy.kind)["=="]("support")
	T(body.WorldContactManifold.state.motion.policy.kind)["=="]("motion")
	T(body.WorldContactManifold.support)["=="](support_cache)
	T(body.WorldContactManifold.motion)["=="](motion_cache)
end)

T.Test("World contacts populate per-kind descriptor state fields", function()
	local old_trace = physics.Trace
	local old_surface_contact = physics.GetHitSurfaceContact
	local old_record_world_collision = physics.RecordWorldCollision
	local old_world_trace_source = physics.GetWorldTraceSource
	local body = create_mock_body{
		PreviousPosition = Vec3(0, 0.005, 0),
		Position = Vec3(0.05, 0.005, 0),
		Velocity = Vec3(0.03, 0, 0),
		Grounded = true,
	}

	function body:GetCollisionLocalPoints()
		return {Vec3(), Vec3(1, 0, 0)}
	end

	function body:GetSupportLocalPoints()
		return {Vec3(), Vec3(0, -1, 0)}
	end

	physics.RecordWorldCollision = function() end
	physics.GetWorldTraceSource = function()
		return {}
	end
	physics.GetHitSurfaceContact = function(hit)
		return {
			normal = hit.kind == "motion" and Vec3(-1, 0, 0) or Vec3(0, 1, 0),
			position = hit.position,
		}
	end
	physics.Trace = function(_, direction)
		if math.abs(direction.x) > 0.0001 then
			return {
				kind = "motion",
				primitive = {},
				primitive_index = 20,
				position = Vec3(0, 0.005, 0),
				distance = 0.02,
			}
		end

		if direction.y < -0.5 then
			return {
				kind = "support",
				primitive = {},
				primitive_index = 21,
				position = Vec3(0.05, 0, 0),
				distance = 0.01,
			}
		end

		return nil
	end
	body:SetGrounded(true)
	world_contacts.SolveBodyContacts(body, 1 / 60)
	T(body.WorldContactManifold.state.support.cast_up)["=="](0.01)
	T(body.WorldContactManifold.state.support.allow_cached)["=="](true)
	T(#body.WorldContactManifold.state.support.support_points)["=="](2)
	T(body.WorldContactManifold.state.support.trace_mode)["=="]("support")
	T(body.WorldContactManifold.state.support.point_source)["=="]("support_points")
	T(body.WorldContactManifold.state.support.query_builder)["=="]("support_probe")
	T(body.WorldContactManifold.state.support.cached_surface_mode)["=="]("support_position")
	T(#body.WorldContactManifold.state.support.point_items)["=="](2)
	T(body.WorldContactManifold.state.support.kind)["=="]("support")
	T(body.WorldContactManifold.state.support.dt)["=="](1 / 60)
	T(body.WorldContactManifold.state.support.patch_velocity_y_limit)["=="](0.75)
	T(body.WorldContactManifold.state.support.patch_angular_speed_limit)["=="](1.5)
	T(body.WorldContactManifold.state.support.patch_up_y_limit)["=="](0.9)
	T(body.WorldContactManifold.state.motion.sweep_margin)["=="](0.01)
	T(body.WorldContactManifold.state.motion.allow_cached)["=="](false)
	T(#body.WorldContactManifold.state.motion.collision_points)["=="](2)
	T(body.WorldContactManifold.state.motion.trace_mode)["=="]("sweep")
	T(body.WorldContactManifold.state.motion.point_source)["=="]("collision_points")
	T(body.WorldContactManifold.state.motion.query_builder)["=="]("motion_sweep")
	T(body.WorldContactManifold.state.motion.cached_surface_mode)["=="]("motion_projection")
	T(#body.WorldContactManifold.state.motion.point_items)["=="](2)
	T(body.WorldContactManifold.state.motion.kind)["=="]("motion")
	T(body.WorldContactManifold.state.motion.dt)["=="](1 / 60)
	T(body.WorldContactManifold.state.motion.patch_requires_coherent_contacts)["=="](true)
	physics.Trace = old_trace
	physics.GetHitSurfaceContact = old_surface_contact
	physics.RecordWorldCollision = old_record_world_collision
	physics.GetWorldTraceSource = old_world_trace_source
end)