local event = import("goluwa/event.lua")
local pvars = import("goluwa/cli/pvars.lua")
local Physics = import("goluwa/physics/physics.lua")
local physics = {}
local tickrate = pvars.Setup2{
	key = "phys_tickrate",
	category = "Debug",
	group = "Physics",
	store = false,
	default = 60,
	min = 1,
	max = 1000,
	help = "fixed physics steps per second. the game renders at its own rate and draws bodies between steps (phys_interpolation)",
	callback = function(hz, initial)
		if not initial then physics.instance.FixedTimeStep = 1 / hz end
	end,
}

function physics.Initialize(config)
	config = config or {}
	config.FixedTimeStep = config.FixedTimeStep or 1 / tickrate:Get()
	physics.instance = Physics.New(config)

	do
		local world_step = import("goluwa/physics/world_step.lua")
		physics.instance.Step = function(dt)
			return world_step.Step(physics.instance, dt)
		end
		physics.instance.Update = function(dt)
			return world_step.Update(physics.instance, dt)
		end
		physics.instance.UpdateFixed = function(dt)
			return world_step.UpdateFixed(physics.instance, dt)
		end
		physics.instance.UpdateRigidBodies = function(dt)
			return world_step.UpdateRigidBodies(physics.instance, dt)
		end

		function physics.instance:OnUpdate(dt)
			physics.instance.UpdateFixed(dt)
		end

		event.AddListener(
			"Update",
			"physics",
			function(dt)
				physics.instance.UpdateFixed(dt)
			end,
			{priority = 50}
		)
	end
end

function physics.Step(dt)
	return physics.instance.Step(dt)
end

function physics.Update(dt)
	return physics.instance.Update(dt)
end

function physics.UpdateFixed(dt)
	return physics.instance.UpdateFixed(dt)
end

function physics.GetInterpolationAlpha()
	local instance = physics.instance
	return instance and instance.GetInterpolationAlpha() or 0
end

function physics.RayCast(...)
	return physics.instance.RayCast(...)
end

function physics.GetHitNormal(...)
	return physics.instance.GetHitNormal(...)
end

function physics.GetUp()
	return physics.instance.Up
end

function physics.GetHitMaterial(hit)
	local primitive = hit.primitive

	if primitive then
		if primitive.material then return primitive.material end

		local materials = primitive.brush_materials

		if materials then
			local planes = primitive.brush_planes
			local normal = hit.normal
			local best, best_dot = 1, -math.huge

			for i = 1, #planes do
				local dot = planes[i].normal:Dot(normal)

				if dot > best_dot then best, best_dot = i, dot end
			end

			return materials[best]
		end
	end

	local entity = hit.entity

	if not entity or entity.rigid_body and entity.rigid_body.WorldGeometry then
		return nil
	end

	if entity.model and entity.model.material then return entity.model.material end

	local visual = entity.visual

	if not visual then
		for _, child in ipairs(entity:GetChildren()) do
			if child.visual then
				visual = child.visual

				break
			end
		end
	end

	local entry = visual and visual:GetRenderEntries()[1]
	return entry and visual:GetResolvedMaterial(entry)
end

function physics.GetHitSurfaceContact(...)
	return physics.instance.GetHitSurfaceContact(...)
end

function physics.Sweep(...)
	return physics.instance.Sweep(...)
end

function physics.SweepCollider(...)
	return physics.instance.SweepCollider(...)
end

function physics.GetConstraints()
	return physics.instance.GetConstraints()
end

function physics.RemoveAllConstraints()
	return physics.instance.RemoveAllConstraints()
end

function physics.ResetState()
	return physics.instance.ResetState()
end

return physics
