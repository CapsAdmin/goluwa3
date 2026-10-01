-- A car with four hinged wheels rolls down a tilted ramp and crashes into a
-- stack of boxes. Key R respawns the scene.
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local event = import("goluwa/event.lua")
local input = import("goluwa/input.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local HingeConstraint = import("goluwa/physics/hinge_constraint.lua")
local shapes = import("lua/shapes.lua")
local SLOPE = math.rad(16)
local RAMP_LENGTH = 26
local WHEEL_RADIUS = 0.45
local spawned = {}
local hinges = {}

local function track(ent)
	spawned[#spawned + 1] = ent
	return ent
end

local function clear()
	for _, hinge in ipairs(hinges) do
		hinge:Remove()
	end

	hinges = {}

	for _, ent in ipairs(spawned) do
		if ent:IsValid() then ent:Remove() end
	end

	spawned = {}
end

local function spawn()
	clear()
	local ground_material = shapes.Material{Color = Color(0.55, 0.57, 0.6, 1), Roughness = 0.9}
	local ramp_material = shapes.Material{Color = Color(0.35, 0.4, 0.5, 1), Roughness = 0.8}
	local crate_material = shapes.Material{Color = Color(0.85, 0.55, 0.2, 1), Roughness = 0.7}
	local body_material = shapes.Material{Color = Color(0.8, 0.12, 0.1, 1), Roughness = 0.35, Metallic = 0.3}
	local wheel_material = shapes.Material{Color = Color(0.08, 0.08, 0.09, 1), Roughness = 0.6}
	local spoke_material = shapes.Material{Color = Color(0.9, 0.9, 0.9, 1), Roughness = 0.5}
	local rotation = Quat(0, 0, math.sin(-SLOPE / 2), math.cos(-SLOPE / 2))
	local normal = Vec3(math.sin(SLOPE), math.cos(SLOPE), 0)
	local top_center = Vec3(-RAMP_LENGTH / 2 * math.cos(SLOPE), RAMP_LENGTH / 2 * math.sin(SLOPE), 0)
	track(
		(
			shapes.Box{
				Name = "car_crash_ground",
				Position = Vec3(0, -0.5, 0),
				Size = Vec3(120, 1, 30),
				Material = ground_material,
				RigidBody = {MotionType = "static", Friction = 0.8},
			}
		)
	)
	track(
		(
			shapes.Box{
				Name = "car_crash_ramp",
				Position = top_center - normal * 0.5,
				Rotation = rotation,
				Size = Vec3(RAMP_LENGTH, 1, 8),
				Material = ramp_material,
				RigidBody = {MotionType = "static", Friction = 0.8},
			}
		)
	)

	for level = 0, 4 do
		for row = -1, 0 do
			track(
				(
					shapes.Box{
						Name = "car_crash_crate",
						Position = Vec3(9 + row * 1.05, 0.5 + level * 1.0, row * 0.0),
						Size = Vec3(1, 1, 2.2),
						Material = crate_material,
						RigidBody = {Mass = 1, AutomaticMass = false, Friction = 0.6},
					}
				)
			)
		end
	end

	local start = top_center * 1.75 + normal * 1.0
	local car_ent, car = shapes.Box{
		Name = "car_crash_body",
		Position = start,
		Rotation = rotation,
		Size = Vec3(2.6, 0.55, 1.3),
		Material = body_material,
		RigidBody = {Mass = 10, AutomaticMass = false, Friction = 0.3},
	}
	track(car_ent)
	local cabin = shapes.Box{
		Name = "car_crash_cabin",
		Position = Vec3(-0.15, 0.5, 0),
		Size = Vec3(1.3, 0.5, 1.1),
		Material = body_material,
		Collision = false,
		PhysicsNoCollision = true,
		RigidBody = false,
	}
	cabin:SetParent(car_ent)
	local axis = rotation:VecMul(Vec3(0, 0, 1))

	for _, x in ipairs({-1, 1}) do
		for _, z in ipairs({-0.95, 0.95}) do
			local world = start + rotation:VecMul(Vec3(x, -0.1, z))
			local wheel_ent, wheel = shapes.Sphere{
				Name = "car_crash_wheel",
				Position = world,
				Radius = WHEEL_RADIUS,
				Material = wheel_material,
				RigidBody = {
					Radius = WHEEL_RADIUS,
					Mass = 1,
					AutomaticMass = false,
					Friction = 0.9,
					MaxLinearSpeed = 1000,
					MaxAngularSpeed = 1000,
				},
			}
			track(wheel_ent)
			local spoke = shapes.Box{
				Name = "car_crash_spoke",
				Position = Vec3(0, 0, z > 0 and 0.4 or -0.4),
				Size = Vec3(WHEEL_RADIUS * 1.6, 0.1, 0.12),
				Material = spoke_material,
				Collision = false,
				PhysicsNoCollision = true,
				RigidBody = false,
			}
			spoke:SetParent(wheel_ent)
			hinges[#hinges + 1] = HingeConstraint.New(car, wheel, world, axis)
		end
	end
end

local function frame_camera()
	local camera = render3d.GetCamera()
	camera:SetPosition(Vec3(2, 5, 24))
	camera:SetRotation(QuatDeg3(-10, 0, 0))
end

spawn()
frame_camera()
local was_down = false

event.AddListener("Update", "physics_car_crash", function()
	local down = input.IsKeyDown("r")

	if down and not was_down then spawn() end

	was_down = down
end)
