local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local event = import("goluwa/event.lua")
local input = import("goluwa/input.lua")
local physics = import("goluwa/physics.lua")
local debug_draw = import("goluwa/debug_draw.lua")
local constraints = import("goluwa/physics/constraints.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local ORIGIN = Vec3(34, -1.5, -8)
local SPACING = 14
local SCENE = {breakables = {}}
local spawned = {}
local timers = {}
local scene_time = 0
local labels = {}
local live_joints = {}

local function at(x, y, z)
	return ORIGIN + Vec3(x, y, z)
end

local function rotation(pitch, yaw, roll)
	return Quat():SetAngles(Deg3(pitch or 0, yaw or 0, roll or 0))
end

local function mat(r, g, b, roughness, metallic)
	return shapes.Material{
		Color = Color(r, g, b, 1),
		Roughness = roughness or 0.6,
		Metallic = metallic or 0,
	}
end

local floor_material = mat(0.17, 0.16, 0.15, 0.95)
local pad_material = mat(0.10, 0.11, 0.13, 0.9)
local steel_material = mat(0.72, 0.77, 0.84, 0.25, 1)
local wood_material = mat(0.49, 0.31, 0.16, 0.85)
local orange_material = mat(0.94, 0.44, 0.20, 0.4)
local blue_material = mat(0.20, 0.55, 1.00, 0.3)
local green_material = mat(0.30, 0.80, 0.40, 0.4)
local red_material = mat(0.90, 0.22, 0.20, 0.4)
local skin_material = mat(0.85, 0.65, 0.52, 0.7)
local cloth_material = mat(0.25, 0.30, 0.55, 0.8)

local function track(ent, body)
	spawned[#spawned + 1] = ent
	return ent, body
end

local function dynamic(mass, options)
	local config = {
		Mass = mass,
		AutomaticMass = false,
		LinearDamping = 0.02,
		AngularDamping = 0.05,
		AirLinearDamping = 0.005,
		AirAngularDamping = 0.02,
		Friction = 0.7,
		Restitution = 0,
		MaxLinearSpeed = 1000,
		MaxAngularSpeed = 1000,
	}

	for key, value in pairs(options or {}) do
		config[key] = value
	end

	return config
end

local function static_body(friction)
	return {MotionType = "static", Friction = friction or 0.8, Restitution = 0}
end

local function box(position, size, material, body, rot)
	return track(
		shapes.Box{
			Name = "joint_box",
			Position = position,
			Size = size,
			Material = material,
			Rotation = rot,
			RigidBody = body,
		}
	)
end

local function sphere(position, radius, material, body)
	return track(
		shapes.Sphere{
			Name = "joint_sphere",
			Position = position,
			Radius = radius,
			Material = material,
			RigidBody = body,
		}
	)
end

local function visual_sphere(position, radius, material)
	return track(
		shapes.Sphere{
			Name = "joint_marker",
			PhysicsNoCollision = true,
			Collision = false,
			Position = position,
			Radius = radius,
			Material = material,
		}
	)
end

local function visual_box(position, size, material)
	return track(
		shapes.Box{
			Name = "joint_visual",
			PhysicsNoCollision = true,
			Collision = false,
			Position = position,
			Size = size,
			Material = material,
		}
	)
end

local function joint(constraint)
	live_joints[#live_joints + 1] = constraint
	return constraint
end

local function every(period, callback, first)
	timers[#timers + 1] = {period = period, callback = callback, next = first or period}
end

local function station(name, column, row)
	local center = at(column * SPACING, 0, row * SPACING)
	visual_box(center, Vec3(11, 0.04, 11), pad_material)
	labels[#labels + 1] = {text = name, position = center + Vec3(0, 9.6, 0)}
	return center
end

local function ground()
	box(at(0, -0.75, 0), Vec3(500, 1.5, 500), floor_material, static_body(0.9))
end

local function build_weld()
	local c = station("WELD", -2, 0)
	local _, post = box(c + Vec3(-2, 2.5, 0), Vec3(0.6, 5, 0.6), steel_material, static_body())
	local _, beam = box(c + Vec3(0.3, 3.5, 0), Vec3(4, 0.35, 0.5), wood_material, dynamic(4))
	joint(constraints.Weld(post, beam, c + Vec3(-1.7, 3.5, 0)))
	local _, bar = box(c + Vec3(1.5, 5, 2.5), Vec3(1.6, 0.4, 0.4), orange_material, dynamic(2))
	local _, leg = box(c + Vec3(0.7, 5.6, 2.5), Vec3(0.4, 1.6, 0.4), orange_material, dynamic(2))
	joint(constraints.Weld(bar, leg, c + Vec3(0.7, 5, 2.5)))
	local previous
	local base_y = 0.4

	for i = 1, 4 do
		local _, block = box(
			c + Vec3(2.5, base_y + (i - 1) * 0.8, -2.5),
			Vec3(0.8, 0.8, 0.8),
			blue_material,
			dynamic(2, {CanSleep = true})
		)

		if previous then
			joint(constraints.Weld(previous, block, c + Vec3(2.5, (i - 1) * 0.8, -2.5)))
		end

		previous = block
	end
end

local function build_ball_socket()
	local c = station("BALL SOCKET", -1, 0)
	local _, left = box(c + Vec3(-4, 1.5, 0), Vec3(0.6, 3, 0.6), steel_material, static_body())
	local _, right = box(c + Vec3(4, 1.5, 0), Vec3(0.6, 3, 0.6), steel_material, static_body())
	local count = 15
	local links = {}

	for i = 1, count do
		local t = (i - 1) / (count - 1) * 2 - 1
		local position = c + Vec3(t * 3.7, 3.2 - 1.2 * (1 - t * t), 0)
		local _, link = sphere(position, 0.18, steel_material, dynamic(0.8))
		links[i] = link
	end

	joint(constraints.BallSocket(left, links[1], c + Vec3(-3.7, 3.2, 0)))

	for i = 2, count do
		joint(
			constraints.BallSocket(links[i - 1], links[i], (links[i - 1].Position + links[i].Position) * 0.5)
		)
	end

	joint(constraints.BallSocket(links[count], right, c + Vec3(3.7, 3.2, 0)))
	local dropped

	every(
		10,
		function()
			if dropped and dropped:IsValid() then dropped:Remove() end

			dropped = sphere(c + Vec3(0, 6.5, 0), 0.5, orange_material, dynamic(10))
		end,
		2
	)
end

local function build_hinge()
	local c = station("HINGE", 0, 0)
	local _, left_post = box(c + Vec3(-1.25, 1.5, 2.5), Vec3(0.3, 3, 0.4), steel_material, static_body())
	box(c + Vec3(1.25, 1.5, 2.5), Vec3(0.3, 3, 0.4), steel_material, static_body())
	box(c + Vec3(0, 3.15, 2.5), Vec3(2.8, 0.3, 0.4), steel_material, static_body())
	local _, door = box(c + Vec3(-0.15, 1.4, 2.5), Vec3(1.9, 2.8, 0.12), wood_material, dynamic(8))
	SCENE.door = door
	joint(
		constraints.Hinge(
			left_post,
			door,
			c + Vec3(-1.1, 1.4, 2.5),
			Vec3(0, 1, 0),
			{LowerAngle = -1.9, UpperAngle = 1.9, Friction = 2}
		)
	)
	local _, pivot = box(c + Vec3(0, 0.65, -2.5), Vec3(0.4, 1.3, 0.4), steel_material, static_body())
	local _, plank = box(c + Vec3(0, 1.45, -2.5), Vec3(5, 0.2, 1.2), wood_material, dynamic(6))
	local seesaw_joint = joint(
		constraints.Hinge(
			pivot,
			plank,
			c + Vec3(0, 1.45, -2.5),
			Vec3(0, 0, 1),
			{LowerAngle = -0.3, UpperAngle = 0.3}
		)
	)
	local _, weight = box(c + Vec3(-2.0, 1.85, -2.5), Vec3(0.6, 0.6, 0.6), orange_material, dynamic(3))
	SCENE.seesaw = {plank = plank, weight = weight, joint = seesaw_joint}
end

local function build_motor()
	local c = station("MOTOR", 1, 0)
	local _, post = box(c + Vec3(0, 0.25, 0), Vec3(0.5, 0.5, 0.5), steel_material, static_body())
	local _, platform = box(
		c + Vec3(0, 0.65, 0),
		Vec3(5, 0.25, 5),
		wood_material,
		dynamic(40, {Friction = 1.2})
	)
	SCENE.motor = joint(constraints.Motor(post, platform, c + Vec3(0, 0.65, 0), Vec3(0, 1, 0), 0.5, 3000))

	for i = 1, 3 do
		local angle = i * math.pi * 2 / 3
		box(
			c + Vec3(math.cos(angle) * 1.6, 1.3, math.sin(angle) * 1.6),
			Vec3(0.7, 0.7, 0.7),
			i == 1 and orange_material or i == 2 and blue_material or green_material,
			dynamic(1.5, {Friction = 1.2})
		)
	end
end

local function build_slider()
	local c = station("SLIDER", 2, 0)
	visual_box(c + Vec3(0, 0.02, 0), Vec3(10, 0.04, 0.5), steel_material)
	local _, block = box(c + Vec3(-3, 0.6, 0), Vec3(1.6, 1, 1.4), orange_material, dynamic(10))
	SCENE.slider = joint(
		constraints.Slider(
			nil,
			block,
			c + Vec3(-3, 0.6, 0),
			Vec3(1, 0, 0),
			{
				LowerTranslation = 0,
				UpperTranslation = 6,
				MotorSpeed = 3,
				MaxMotorForce = 4000,
			}
		)
	)
	SCENE.slider_direction = 1

	for i = 1, 3 do
		box(
			c + Vec3(3.6, 0.4 + (i - 1) * 0.8, 0),
			Vec3(0.8, 0.8, 0.8),
			wood_material,
			dynamic(1, {CanSleep = true})
		)
	end

	box(
		c + Vec3(4.8, 0.4, 0),
		Vec3(0.8, 0.8, 0.8),
		blue_material,
		dynamic(1, {CanSleep = true})
	)
end

local function build_ragdoll()
	local c = station("RAGDOLL", -2, -1)
	local origin = c + Vec3(0, 5, 0)

	local function limb(offset, size, mass, material)
		return select(2, box(origin + offset, size, material, dynamic(mass, {Friction = 0.8})))
	end

	local pelvis = limb(Vec3(0, 0, 0), Vec3(0.4, 0.25, 0.25), 6, cloth_material)
	local torso = limb(Vec3(0, 0.4, 0), Vec3(0.45, 0.55, 0.26), 10, cloth_material)
	local _, head = sphere(origin + Vec3(0, 0.9, 0), 0.17, skin_material, dynamic(3, {Friction = 0.8}))
	local down = Vec3(0, -1, 0)
	local up = Vec3(0, 1, 0)
	local side = Vec3(1, 0, 0)
	local friction = {TwistFriction = 0.6, SwingFriction = 0.6}

	local function ragdoll_joint(parent, child, anchor, axis, twist, swing)
		local config = {
			TwistMin = -twist,
			TwistMax = twist,
			SwingYMin = -swing,
			SwingYMax = swing,
			SwingZMin = -swing,
			SwingZMax = swing,
			TwistFriction = friction.TwistFriction,
			SwingFriction = friction.SwingFriction,
		}
		return joint(constraints.Ragdoll(parent, child, origin + anchor, axis, config))
	end

	ragdoll_joint(pelvis, torso, Vec3(0, 0.125, 0), up, 0.4, 0.35)
	ragdoll_joint(torso, head, Vec3(0, 0.675, 0), up, 0.8, 0.5)

	for _, sign in ipairs({-1, 1}) do
		local arm = limb(Vec3(sign * 0.3, 0.42, 0), Vec3(0.14, 0.4, 0.14), 2, skin_material)
		local forearm = limb(Vec3(sign * 0.3, 0.02, 0), Vec3(0.12, 0.4, 0.12), 1.5, skin_material)
		ragdoll_joint(torso, arm, Vec3(sign * 0.3, 0.62, 0), down, 1.0, 1.5)
		joint(
			constraints.Hinge(
				arm,
				forearm,
				origin + Vec3(sign * 0.3, 0.22, 0),
				side,
				{LowerAngle = -2.4, UpperAngle = 0, Friction = 0.3}
			)
		)
		local thigh = limb(Vec3(sign * 0.12, -0.35, 0), Vec3(0.18, 0.45, 0.18), 5, cloth_material)
		local shin = limb(Vec3(sign * 0.12, -0.8, 0), Vec3(0.15, 0.45, 0.15), 3, cloth_material)
		ragdoll_joint(pelvis, thigh, Vec3(sign * 0.12, -0.125, 0), down, 0.4, 1.0)
		joint(
			constraints.Hinge(
				thigh,
				shin,
				origin + Vec3(sign * 0.12, -0.575, 0),
				side,
				{LowerAngle = 0, UpperAngle = 2.4, Friction = 0.3}
			)
		)
	end
end

local function build_pendulums()
	local c = station("ROD AND ROPE", -1, -1)
	local height = 7
	box(c + Vec3(0, height, 0), Vec3(8, 0.3, 0.3), steel_material, static_body())
	box(
		c + Vec3(-4.2, height / 2, 0),
		Vec3(0.4, height, 0.4),
		steel_material,
		static_body()
	)
	box(
		c + Vec3(4.2, height / 2, 0),
		Vec3(0.4, height, 0.4),
		steel_material,
		static_body()
	)
	local anchor = c + Vec3(-2.5, height - 0.15, 0)
	local length = 4
	local angle = math.rad(40)
	local _, bob = sphere(
		anchor + Vec3(math.sin(angle) * length, -math.cos(angle) * length, 0),
		0.4,
		orange_material,
		dynamic(5)
	)
	joint(constraints.Rod(nil, bob, anchor, bob.Position, {Length = length}))
	anchor = c + Vec3(0, height - 0.15, 0)
	local _, thrown = sphere(anchor + Vec3(0, -3.5, 0), 0.4, blue_material, dynamic(4))
	joint(constraints.Rope(nil, thrown, anchor, thrown.Position, {Length = 3.5}))
	thrown:SetVelocity(Vec3(4, 7, 0))
	anchor = c + Vec3(2.5, height - 0.15, 0)
	local _, first = sphere(anchor + Vec3(1.6, 0, 0), 0.3, green_material, dynamic(3))
	local _, second = sphere(anchor + Vec3(3.2, 0, 0), 0.3, red_material, dynamic(3))
	joint(constraints.Rod(nil, first, anchor, first.Position, {Length = 1.6}))
	joint(constraints.Rod(first, second, first.Position, second.Position, {Length = 1.6}))
end

local function build_springs()
	local c = station("SPRINGS", 0, -1)
	local height = 6.5
	box(c + Vec3(0, height, 0), Vec3(8, 0.3, 0.3), steel_material, static_body())
	box(
		c + Vec3(-4.2, height / 2, 0),
		Vec3(0.4, height, 0.4),
		steel_material,
		static_body()
	)
	box(
		c + Vec3(4.2, height / 2, 0),
		Vec3(0.4, height, 0.4),
		steel_material,
		static_body()
	)
	local settings = {
		{x = -2.5, stiffness = 80, damping = 2, material = green_material},
		{x = -0.5, stiffness = 300, damping = 8, material = blue_material},
		{x = 1.5, stiffness = 1500, damping = 25, material = orange_material},
	}

	for _, setting in ipairs(settings) do
		local anchor = c + Vec3(setting.x, height - 0.15, 0)
		local _, crate = box(anchor + Vec3(0, -1.9, 0), Vec3(0.8, 0.8, 0.8), setting.material, dynamic(3))
		joint(
			constraints.Spring(
				nil,
				crate,
				anchor,
				crate.Position + Vec3(0, 0.4, 0),
				{Length = 1.5, Stiffness = setting.stiffness, Damping = setting.damping}
			)
		)
	end

	box(c + Vec3(3.2, 3, 3.5), Vec3(1.5, 6, 1.5), steel_material, static_body())
	local top = c + Vec3(3.2, 6, 3.5)
	local _, jumper = box(top + Vec3(0.7, 0.45, 0), Vec3(0.5, 0.9, 0.5), red_material, dynamic(3))
	joint(
		constraints.Spring(
			nil,
			jumper,
			top,
			jumper.Position,
			{Length = 3, Stiffness = 200, Damping = 4, Unilateral = true}
		)
	)
	jumper:SetVelocity(Vec3(2, 0, 0))
end

local function build_hydraulics()
	local c = station("HYDRAULIC AND MUSCLE", 1, -1)
	box(c + Vec3(-2.5, 0.15, 0), Vec3(3, 0.3, 3), steel_material, static_body())
	local _, platform = box(
		c + Vec3(-2.5, 0.8, 0),
		Vec3(3, 0.3, 3),
		wood_material,
		dynamic(15, {Friction = 1})
	)
	joint(
		constraints.Slider(
			nil,
			platform,
			platform.Position,
			Vec3(0, 1, 0),
			{LowerTranslation = -0.3, UpperTranslation = 3.5}
		)
	)
	SCENE.lift = joint(
		constraints.Hydraulic(
			nil,
			platform,
			c + Vec3(-2.5, 0.3, 0),
			c + Vec3(-2.5, 0.65, 0),
			{Length = 0.35, MaxForce = 6000}
		)
	)
	box(
		c + Vec3(-2.5, 1.35, 0),
		Vec3(0.8, 0.8, 0.8),
		orange_material,
		dynamic(4, {Friction = 1})
	)

	every(4, function()
		SCENE.lift_up = not SCENE.lift_up
		SCENE.lift:SetTargetLength(SCENE.lift_up and 3.3 or 0.35, 1.2)
	end)

	local _, post = box(c + Vec3(1, 1, 2.5), Vec3(0.4, 2, 0.4), steel_material, static_body())
	local _, arm = box(c + Vec3(2.8, 2, 2.5), Vec3(3.6, 0.25, 0.4), wood_material, dynamic(5))
	joint(
		constraints.Hinge(post, arm, c + Vec3(1, 2, 2.5), Vec3(0, 0, 1), {LowerAngle = -1, UpperAngle = 1})
	)
	joint(
		constraints.Muscle(
			nil,
			arm,
			c + Vec3(3.8, 0.2, 2.5),
			c + Vec3(3.8, 2, 2.5),
			1.8,
			0.7,
			3,
			{MaxForce = 3000}
		)
	)
	visual_sphere(c + Vec3(3.8, 0.2, 2.5), 0.12, steel_material)
end

local function build_pulleys()
	local c = station("PULLEY", 2, -1)
	local top = 8
	box(c + Vec3(0, top + 0.5, 0), Vec3(5, 0.3, 0.6), steel_material, static_body())
	visual_sphere(c + Vec3(-1.2, top, 0), 0.35, steel_material)
	visual_sphere(c + Vec3(1.2, top, 0), 0.35, steel_material)
	local _, heavy = box(c + Vec3(-1.2, 3, 0), Vec3(1, 1, 1), orange_material, dynamic(6))
	local _, light = box(c + Vec3(1.2, 3, 0), Vec3(0.8, 0.8, 0.8), blue_material, dynamic(3))
	joint(
		constraints.Pulley(
			heavy,
			light,
			c + Vec3(-1.2, top, 0),
			c + Vec3(1.2, top, 0),
			c + Vec3(-1.2, 3.5, 0),
			c + Vec3(1.2, 3.4, 0)
		)
	)
	box(c + Vec3(0, top + 0.5, -4), Vec3(5, 0.3, 0.6), steel_material, static_body())
	visual_sphere(c + Vec3(-1.2, top, -4), 0.35, steel_material)
	visual_sphere(c + Vec3(1.2, top, -4), 0.35, steel_material)
	local _, big = box(c + Vec3(-1.2, 3, -4), Vec3(1, 1, 1), green_material, dynamic(8))
	local _, small = box(c + Vec3(1.2, 3, -4), Vec3(0.7, 0.7, 0.7), red_material, dynamic(2))
	joint(
		constraints.Pulley(
			big,
			small,
			c + Vec3(-1.2, top, -4),
			c + Vec3(1.2, top, -4),
			c + Vec3(-1.2, 3.5, -4),
			c + Vec3(1.2, 3.35, -4),
			{Ratio = 2}
		)
	)
end

local function build_keep_upright()
	local c = station("KEEP UPRIGHT", -2, 1)
	local _, plain = box(
		c + Vec3(-1.8, 0.9, 0),
		Vec3(0.8, 1.8, 0.8),
		blue_material,
		dynamic(6, {CanSleep = true})
	)
	local _, upright = box(c + Vec3(1.8, 0.9, 0), Vec3(0.8, 1.8, 0.8), green_material, dynamic(6))
	joint(constraints.KeepUpright(upright, {MaxTorque = 700}))
	local homes = {[plain] = plain.Position:Copy(), [upright] = upright.Position:Copy()}
	local balls = {}

	every(
		9,
		function()
			for _, ball in ipairs(balls) do
				ball:Remove()
			end

			balls = {}

			for body, home in pairs(homes) do
				body:SetPosition(home)
				body:SetRotation(Quat():Identity())
				body:SetVelocity(Vec3(0, 0, 0))
				body:SetAngularVelocity(Vec3(0, 0, 0))
			end

			for _, side in ipairs({-1, 1}) do
				local ball_entity, ball = sphere(c + Vec3(side * -4.5, 1.2, 0), 0.5, orange_material, dynamic(15))
				ball:SetVelocity(Vec3(side * 9, 3, 0))
				balls[#balls + 1] = ball_entity
			end
		end,
		2
	)
end

local function build_no_collide()
	local c = station("NO COLLIDE", -1, 1)
	local _, wall = box(c + Vec3(0, 1.5, 0), Vec3(0.4, 3, 5), steel_material, static_body())
	local balls = {}
	local pass

	every(
		7,
		function()
			if pass then pass:Remove() end

			pass = nil

			for _, ball in ipairs(balls) do
				ball:Remove()
			end

			balls = {}

			for _, side in ipairs({-1, 1}) do
				local entity, ball = sphere(
					c + Vec3(-4.5, 0.4, side * 1.4),
					0.4,
					side < 0 and green_material or red_material,
					dynamic(2)
				)

				if side < 0 then pass = constraints.NoCollide(wall, ball) end

				ball:SetVelocity(Vec3(7, 0, 0))
				balls[#balls + 1] = entity
			end
		end,
		1
	)

	local _, a = box(
		c + Vec3(1.5, 2, -3),
		Vec3(0.9, 0.9, 0.9),
		green_material,
		dynamic(1, {CanSleep = true})
	)
	local _, b = box(
		c + Vec3(1.9, 2.4, -3),
		Vec3(0.9, 0.9, 0.9),
		green_material,
		dynamic(1, {CanSleep = true})
	)
	joint(constraints.NoCollide(a, b))
	box(
		c + Vec3(1.5, 2, 3),
		Vec3(0.9, 0.9, 0.9),
		red_material,
		dynamic(1, {CanSleep = true})
	)
	box(
		c + Vec3(1.9, 2.4, 3),
		Vec3(0.9, 0.9, 0.9),
		red_material,
		dynamic(1, {CanSleep = true})
	)
end

local function build_breakable()
	local c = station("BREAKABLE RODS", 0, 1)
	local height = 6
	box(c + Vec3(0, height, 0), Vec3(8, 0.3, 0.3), steel_material, static_body())
	box(
		c + Vec3(-4.2, height / 2, 0),
		Vec3(0.4, height, 0.4),
		steel_material,
		static_body()
	)
	box(
		c + Vec3(4.2, height / 2, 0),
		Vec3(0.4, height, 0.4),
		steel_material,
		static_body()
	)
	local limit = 150
	SCENE.breakables = {}

	for i, mass in ipairs{1, 3, 6, 12} do
		local anchor = c + Vec3(-3 + (i - 1) * 2, height - 0.15, 0)
		local _, crate = box(
			anchor + Vec3(0, -1.9, 0),
			Vec3(0.7, 0.7, 0.7),
			mass > 5 and red_material or green_material,
			dynamic(mass)
		)
		local rod = joint(
			constraints.Rod(
				nil,
				crate,
				anchor,
				crate.Position + Vec3(0, 0.35, 0),
				{Length = 1.5, BreakForce = limit}
			)
		)
		SCENE.breakables[#SCENE.breakables + 1] = {rod = rod, crate = crate, mass = mass, limit = limit}
	end
end

local function build_winch()
	local c = station("WINCH", 1, 1)
	local angle = math.rad(25)
	local direction = Vec3(math.cos(angle), math.sin(angle), 0)
	local normal = Vec3(-math.sin(angle), math.cos(angle), 0)
	local ramp_center = c + Vec3(0, 1.1, 0)
	box(
		ramp_center,
		Vec3(7, 0.3, 3.5),
		wood_material,
		static_body(0.8),
		rotation(0, 0, 25)
	)
	local crate_position = ramp_center + direction * -2 + normal * 0.6
	local _, crate = box(
		crate_position,
		Vec3(1, 0.9, 0.9),
		orange_material,
		dynamic(8, {Friction = 0.3}),
		rotation(0, 0, 25)
	)
	local post_top = ramp_center + direction * 3 + normal * 1.2
	box(
		post_top + Vec3(0, -(post_top.y - ORIGIN.y) / 2, 0),
		Vec3(0.4, post_top.y - ORIGIN.y, 0.4),
		steel_material,
		static_body()
	)
	local anchor = crate_position + direction * 0.5 + normal * 0.2
	local length = (post_top - anchor):GetLength()
	SCENE.winch = joint(constraints.Winch(nil, crate, post_top, anchor, {Length = length, MaxForce = 1500}))
	SCENE.winch_length = length

	every(
		6,
		function()
			SCENE.winch_in = not SCENE.winch_in
			SCENE.winch:SetTargetLength(SCENE.winch_in and 1.4 or SCENE.winch_length, 0.9)
		end,
		1
	)
end

local function build_heavy_chain()
	local c = station("HEAVY CHAIN", 2, 1)
	local top = 8.85
	box(c + Vec3(0, 9, 0), Vec3(3, 0.3, 0.6), steel_material, static_body())
	box(c + Vec3(-1.6, 4.5, 0), Vec3(0.4, 9, 0.4), steel_material, static_body())
	local count = 14
	local previous
	SCENE.chain = {}

	for i = 1, count do
		local _, link = sphere(c + Vec3(0, top - 0.25 - (i - 1) * 0.5, 0), 0.15, steel_material, dynamic(1))
		SCENE.chain[#SCENE.chain + 1] = joint(constraints.BallSocket(previous, link, c + Vec3(0, top - (i - 1) * 0.5, 0)))
		previous = link
	end

	local _, weight = sphere(c + Vec3(0, top - count * 0.5 - 0.55, 0), 0.55, orange_material, dynamic(30))
	SCENE.chain[#SCENE.chain + 1] = joint(constraints.BallSocket(previous, weight, c + Vec3(0, top - count * 0.5, 0)))
	weight:SetVelocity(Vec3(5, 0, 0))
end

function SCENE.Build()
	scene_time = 0
	SCENE.lift_up = false
	SCENE.winch_in = false
	ground()
	build_weld()
	build_ball_socket()
	build_hinge()
	build_motor()
	build_slider()
	build_ragdoll()
	build_pendulums()
	build_springs()
	build_hydraulics()
	build_pulleys()
	build_keep_upright()
	build_no_collide()
	build_breakable()
	build_winch()
	build_heavy_chain()
end

function SCENE.Clear()
	physics.RemoveAllConstraints()

	for _, ent in ipairs(spawned) do
		if ent:IsValid() then ent:Remove() end
	end

	spawned = {}
	timers = {}
	labels = {}
	live_joints = {}
end

function SCENE.Rebuild()
	SCENE.Clear()
	SCENE.Build()
end

function SCENE.DropHeavyBalls()
	for _, position in ipairs{at(-2 * SPACING + 1.8, 9, 0), at(2, 9, -2.5)} do
		sphere(position, 0.6, red_material, dynamic(40))
	end
end

function SCENE.Step(dt)
	scene_time = scene_time + dt
	local slider = SCENE.slider

	if slider and slider:IsValid() then
		local translation = slider:GetTranslation()

		if translation > 5.9 and SCENE.slider_direction > 0 then
			SCENE.slider_direction = -1
			slider:SetMotor(-3, 4000)
		elseif translation < 0.1 and SCENE.slider_direction < 0 then
			SCENE.slider_direction = 1
			slider:SetMotor(3, 4000)
		end
	end

	for _, timer in ipairs(timers) do
		if scene_time >= timer.next then
			timer.next = scene_time + timer.period
			timer.callback()
		end
	end
end

local function draw_line(constraint, from, to, color, width)
	debug_draw.DrawLine{
		id = tostring(constraint),
		from = from,
		to = to,
		color = color,
		width = width,
		time = 1,
	}
end

local function draw_dot(constraint, position, color, radius)
	debug_draw.DrawSphere{
		id = tostring(constraint),
		position = position,
		radius = radius or 0.07,
		color = color,
		time = 1,
	}
end

local function lerp_color(t)
	t = math.clamp(t, 0, 1)
	return Color(0.2 + 0.8 * t, 0.9 - 0.7 * t, 0.3 - 0.1 * t, 1)
end

function SCENE.Draw()
	for i = #live_joints, 1, -1 do
		local constraint = live_joints[i]

		if not constraint:IsValid() then
			table.remove(live_joints, i)
		else
			local s0, s1 = constraint:LoadStates()
			local p0 = Vec3(s0.px, s0.py, s0.pz)
			local p1 = Vec3(s1.px, s1.py, s1.pz)
			local kind = constraint.Type

			if kind == "physics_distance_constraint" then
				local length = (p1 - p0):GetLength()

				if constraint.Stiffness > 0 then
					draw_line(
						constraint,
						p0,
						p1,
						lerp_color(math.abs(length - constraint.Length) / constraint.Length),
						3
					)
				elseif constraint.TargetLength or constraint.OscillationPeriod then
					draw_line(constraint, p0, p1, Color(0.2, 0.9, 1, 1), 6)
				elseif constraint.Unilateral then
					draw_line(constraint, p0, p1, Color(0.8, 0.65, 0.35, 1), 2)
				else
					draw_line(constraint, p0, p1, Color(0.7, 0.72, 0.75, 1), 3)
				end
			elseif kind == "physics_pulley_constraint" then
				draw_line(constraint, constraint.Ground0, p0, Color(0.8, 0.65, 0.35, 1), 2)
				draw_line(constraint, constraint.Ground1, p1, Color(0.8, 0.65, 0.35, 1), 2)
			elseif kind == "physics_hinge_constraint" then
				local axis = Vec3(s0.xx, s0.xy, s0.xz) * 0.35
				draw_line(constraint, p0 - axis, p0 + axis, Color(1, 0.9, 0.2, 1), 4)
			elseif kind == "physics_slider_constraint" then
				local axis = Vec3(s0.xx, s0.xy, s0.xz) * 0.6
				draw_line(constraint, p0 - axis, p0 + axis, Color(1, 0.9, 0.2, 1), 4)
			elseif kind == "physics_weld_constraint" then
				draw_dot(constraint, p0, Color(1, 0.3, 0.3, 1), 0.08)
			elseif kind == "physics_ball_socket_constraint" or kind == "physics_ragdoll_constraint" then
				draw_dot(constraint, p0, Color(0.3, 0.9, 1, 1), 0.06)
			end
		end
	end

	for index, label in ipairs(labels) do
		debug_draw.DrawText{
			id = "constraints_label_" .. index,
			position = label.position,
			lines = {label.text},
			time = 1,
			padding = 7,
			background_alpha = 0.66,
			title_color = Color(1, 1, 1, 1),
		}
	end

	for index, entry in ipairs(SCENE.breakables) do
		local force = entry.rod:IsValid() and entry.rod:GetReactionForce() or 0
		debug_draw.DrawText{
			id = "constraints_breakable_" .. index,
			position = entry.crate.Position + Vec3(0, 1.2, 0),
			lines = {
				string.format("%g kg", entry.mass),
				entry.rod:IsValid() and string.format("%d / %d N", force, entry.limit) or "BROKEN",
			},
			time = 1,
			padding = 4,
			background_alpha = 0.55,
			title_color = entry.rod:IsValid() and Color(1, 1, 1, 1) or Color(1, 0.3, 0.3, 1),
		}
	end
end

SCENE.Build()
local previous_keys = {}

local function pressed(key)
	local down = input.IsKeyDown(key)
	local was = previous_keys[key]
	previous_keys[key] = down
	return down and not was
end

event.AddListener("PhysicsUpdate", "constraints_playground_step", function(dt)
	SCENE.Step(dt)
end)

event.AddListener("Update", "constraints_playground_update", function()
	if pressed("r") then SCENE.Rebuild() end

	if pressed("g") then SCENE.DropHeavyBalls() end

	if RENDER_3D then SCENE.Draw() end
end)

return SCENE
