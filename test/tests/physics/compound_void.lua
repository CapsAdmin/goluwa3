local T = import("test/environment.lua")
local physics = import("goluwa/physics.lua")
local Entity = import("goluwa/ecs/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")
local CompoundShape = import("goluwa/physics/shapes/compound.lua")
local box_shape = BoxShape.New
local sphere_shape = SphereShape.New
local compound_shape = CompoundShape.New

local function simulate_physics(steps, dt)
	dt = dt or (1 / 120)

	for _ = 1, steps do
		physics.Update(dt)
	end
end

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

T.Test3D("Compound void ramps do not trap spheres between platforms", function()
	local ramps = {
		spawn_void_ramp("compound_void_ramp_top", Vec3(0, 1.5, 0), -34, 8),
	}
	local spheres = {
		{spawn_sphere("compound_void_sphere_1", Vec3(-1.6, 6.2, 0.0), 0.5)},
		{spawn_sphere("compound_void_sphere_2", Vec3(-0.3, 7.0, 0.35), 0.5)},
		{spawn_sphere("compound_void_sphere_3", Vec3(0.9, 7.8, -0.3), 0.5)},
		{spawn_sphere("compound_void_sphere_4", Vec3(1.9, 8.6, 0.15), 0.42)},
	}
	simulate_physics(720)

	for _, pair in ipairs(spheres) do
		local ent = pair[1]
		local body = pair[2]
		local position = ent.transform:GetPosition()
		local velocity = body:GetVelocity()
		T(position.y)["<"](-20)
		T(body:GetGrounded())["=="](false)
		T(velocity.y)["<"](-5)
		T(math.abs(position.x))[">"](5.0)
	end

	for _, pair in ipairs(spheres) do
		pair[1]:Remove()
	end

	for _, ramp in ipairs(ramps) do
		ramp:Remove()
	end
end)
