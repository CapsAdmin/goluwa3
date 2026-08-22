local T = import("test/environment.lua")
local test_helpers = import("test/tests/physics/test_helpers.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")
local CompoundShape = import("goluwa/physics/shapes/compound.lua")
local box_shape = BoxShape.New
local sphere_shape = SphereShape.New
local compound_shape = CompoundShape.New

local function spawn_void_ramp(name, position, roll_degrees, beam_length)
	beam_length = beam_length or 6
	local ent = Entity.New({Name = name})
	ent:AddComponent("transform")
	ent.transform:SetPosition(position)
	local uphill_sign = roll_degrees >= 0 and 1 or -1
	local children = {
		{
			Shape = box_shape(Vec3(beam_length, 0.55, 2.5)),
			Position = Vec3(0, 0, 0),
			Rotation = Quat():SetAngles(Deg3(0, 0, roll_degrees)),
		},
		{
			Shape = box_shape(Vec3(0.7, 2.6, 2.3)),
			Position = Vec3(uphill_sign * (beam_length * 0.33), -1.35, 0),
			Rotation = Quat(0, 0, 0, 1),
		},
	}
	ent:AddComponent(
		"rigid_body",
		{
			Shape = compound_shape(children),
			MotionType = "static",
			Friction = 0.1,
			Restitution = 0,
		}
	)
	return ent
end

local function spawn_sphere(name, position, radius)
	radius = radius or 0.48
	local ent = Entity.New({Name = name})
	ent:AddComponent("transform")
	ent.transform:SetPosition(position)
	local body = ent:AddComponent(
		"rigid_body",
		{
			Shape = sphere_shape(radius),
			Radius = radius,
			LinearDamping = 0,
			AngularDamping = 0,
			AirLinearDamping = 0,
			AirAngularDamping = 0,
			Friction = 0.08,
			Restitution = 0,
			CanSleep = false,
		}
	)
	return ent, body
end
