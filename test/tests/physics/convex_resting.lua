local T = import("test/environment.lua")
local physics = import("goluwa/physics.lua")
local Entity = import("goluwa/entities/entity.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local MeshShape = import("goluwa/physics/shapes/mesh.lua")
local ConvexShape = import("goluwa/physics/shapes/convex.lua")
local test_helpers = import("test/tests/physics/test_helpers.lua")

local function create_brush_floor(name)
	local ent = Entity.New({Name = name})
	ent:AddComponent("transform")
	local mins, maxs = Vec3(-20, -1, -20), Vec3(20, 0, 20)
	ent:AddComponent(
		"rigid_body",
		{
			Shape = MeshShape.New{
				Model = {
					Owner = ent,
					Visible = true,
					WorldSpaceVertices = true,
					AABB = AABB(mins.x, mins.y, mins.z, maxs.x, maxs.y, maxs.z),
					Primitives = {
						{
							brush_planes = {
								{normal = Vec3(1, 0, 0), dist = maxs.x},
								{normal = Vec3(-1, 0, 0), dist = -mins.x},
								{normal = Vec3(0, 1, 0), dist = maxs.y},
								{normal = Vec3(0, -1, 0), dist = -mins.y},
								{normal = Vec3(0, 0, 1), dist = maxs.z},
								{normal = Vec3(0, 0, -1), dist = -mins.z},
							},
							aabb = AABB(mins.x, mins.y, mins.z, maxs.x, maxs.y, maxs.z),
						},
					},
				},
			},
			MotionType = "static",
			GravityScale = 0,
			WorldGeometry = true,
			Friction = 0.8,
		}
	)
	return ent
end

local function create_barrel_hull()
	local vertices = {}

	for i = 0, 7 do
		local angle = i / 8 * math.pi * 2
		local x, z = math.cos(angle) * 0.269, math.sin(angle) * 0.269
		vertices[#vertices + 1] = Vec3(x, -0.489, z)
		vertices[#vertices + 1] = Vec3(x, 0.489, z)
	end

	return {vertices = vertices}
end

local function create_barrel(position, angles, spin)
	local hull = create_barrel_hull()
	local ent = Entity.New({Name = "convex_resting_barrel"})
	ent:AddComponent("transform")
	ent.transform:SetPosition(position)
	ent.transform:SetRotation(Quat():SetAngles(angles) * Quat():SetAngles(Deg3(0, spin, 0)))
	local body = ent:AddComponent(
		"rigid_body",
		{
			Shape = ConvexShape.New(hull),
			ConvexHull = hull,
			Mass = 60,
			AutomaticMass = false,
			Friction = 0.8,
		}
	)
	return ent, body
end

local function lowest_point(body)
	local lowest = math.huge

	for _, point in ipairs(body:GetCollisionLocalPoints()) do
		lowest = math.min(lowest, body:GeometryLocalToWorld(point).y)
	end

	return lowest
end

T.TestPhysics("Octagonal barrel sleeps just above its collision margin on a brush floor in any orientation", function()
	local floor = create_brush_floor("convex_resting_floor")
	local cases = {
		Deg3(0, 0, 0),
		Deg3(0, 0, 90),
		Deg3(0, 0, 80),
		Deg3(0, 0, 60),
		Deg3(0, 30, 90),
		Deg3(45, 0, 90),
		Deg3(0, 0, 180),
		Deg3(0, 0, 100),
		Deg3(20, 0, 85),
		Deg3(0, 0, 45),
	}
	local barrels = {}
	local bodies = {}

	for i, angles in ipairs(cases) do
		local ent, body = create_barrel(Vec3((i - 5) * 2, 1, 0), angles, i * 7)
		barrels[i] = {ent = ent, body = body, angles = angles}
		bodies[i] = body
	end

	test_helpers.SimulateSettled(bodies, 120 * 8)
	local failures = {}

	for i, barrel in ipairs(barrels) do
		local body = barrel.body
		local gap = lowest_point(body)

		if body:GetAwake() or math.abs(gap - body:GetCollisionMargin() - body:GetPhysics().solver.PENETRATION_SLOP) > 0.004 then
			failures[#failures + 1] = string.format(
				"#%d %s gap=%.4f awake=%s v=%.3f w=%.3f",
				i,
				tostring(barrel.angles),
				gap,
				tostring(body:GetAwake()),
				body:GetVelocity():GetLength(),
				body:GetAngularVelocity():GetLength()
			)
		end
	end

	for _, barrel in ipairs(barrels) do
		barrel.ent:Remove()
	end

	floor:Remove()
	T(table.concat(failures, "\n"))["=="]("")
end)
