local prefab = import("goluwa/entities/prefab.lua")
local Entity = import("goluwa/entities/entity.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local vehicles = {}
local DARK = {Color = Color(0.06, 0.06, 0.07, 1), Roughness = 0.6, Metallic = 0}
local METAL = {Color = Color(0.55, 0.56, 0.58, 1), Roughness = 0.35, Metallic = 1}
local TIRE = {Color = Color(0.03, 0.03, 0.03, 1), Roughness = 0.9, Metallic = 0}
local RIM = {Color = Color(0.75, 0.75, 0.78, 1), Roughness = 0.3, Metallic = 1}
local SEAT = {Color = Color(0.25, 0.12, 0.08, 1), Roughness = 0.8, Metallic = 0}
local GLASS = {Color = Color(0.2, 0.25, 0.3, 1), Roughness = 0.05, Metallic = 0}
local LIGHT = {Color = Color(1, 0.95, 0.8, 1), Roughness = 0.2, Metallic = 0}

local function box(size, position, rotation)
	return {Size = size, Position = position, Rotation = rotation}
end

local function part(name, model, options, position, rotation, material, parent)
	return {
		Name = name,
		Model = model,
		Options = options,
		Position = position,
		Rotation = rotation,
		Material = material,
		Parent = parent,
	}
end

local function node(name, position, rotation, parent)
	return {Name = name, Position = position, Rotation = rotation, Parent = parent}
end

local function pitch(angle)
	return Quat():Identity():RotatePitch(angle)
end

local function yaw(angle)
	return Quat():Identity():RotateYaw(angle)
end

vehicles.Definitions = {
	car = {
		DisplayName = "Car",
		Type = "car",
		Mass = 1200,
		SpawnHeight = 0.7,
		SpawnYaw = math.pi / 2,
		SpawnForward = 1,
		BuoyancyDensity = 1500,
		Color = Color(0.75, 0.1, 0.08, 1),
		Colliders = {
			box(Vec3(1.7, 0.25, 4.2), Vec3(0, -0.1, 0)),
			box(Vec3(1.7, 0.45, 1.3), Vec3(0, 0.12, -1.45)),
			box(Vec3(1.7, 0.4, 0.9), Vec3(0, 0.1, 1.65)),
			box(Vec3(0.12, 0.4, 2.0), Vec3(-0.85, 0.2, 0.2)),
			box(Vec3(0.12, 0.4, 2.0), Vec3(0.85, 0.2, 0.2)),
		},
		Suspension = {Stiffness = 38000, Damping = 3200, Travel = 0.22},
		Wheels = {
			{
				Position = Vec3(-0.8, -0.27, -1.35),
				Radius = 0.36,
				Width = 0.26,
				Mass = 20,
				Steer = true,
				Brake = 1600,
			},
			{
				Position = Vec3(0.8, -0.27, -1.35),
				Radius = 0.36,
				Width = 0.26,
				Mass = 20,
				Steer = true,
				Brake = 1600,
			},
			{
				Position = Vec3(-0.8, -0.27, 1.35),
				Radius = 0.36,
				Width = 0.3,
				Mass = 20,
				Drive = true,
				Brake = 1000,
				Handbrake = 4000,
			},
			{
				Position = Vec3(0.8, -0.27, 1.35),
				Radius = 0.36,
				Width = 0.3,
				Mass = 20,
				Drive = true,
				Brake = 1000,
				Handbrake = 4000,
			},
		},
		WheelFriction = 1.1,
		Engine = {Torque = 1300, Speed = 45, ReverseSpeed = 10, Braking = 120},
		Steering = {Angle = 0.6, Rate = 2.5, Ratio = 4, Node = "steering"},
		Drag = 0.45,
		Seat = {
			Pose = "drive",
			Position = Vec3(-0.4, 0.2, 0.52),
			EyeHeight = 0.68,
			ExitPosition = Vec3(-1.6, -0.55, 0.4),
			CameraDistance = 6,
			CameraHeight = 1.1,
			FootLeft = "pedal_l",
			FootRight = "pedal_r",
		},
		Parts = {
			part("floor", "box", {size = Vec3(1.7, 0.25, 4.2)}, Vec3(0, -0.1, 0), nil, "paint"),
			part("hood", "box", {size = Vec3(1.7, 0.45, 1.3)}, Vec3(0, 0.12, -1.45), nil, "paint"),
			part("deck", "box", {size = Vec3(1.7, 0.4, 0.9)}, Vec3(0, 0.1, 1.65), nil, "paint"),
			part(
				"side_l",
				"box",
				{size = Vec3(0.12, 0.4, 2.0)},
				Vec3(-0.85, 0.2, 0.2),
				nil,
				"paint"
			),
			part(
				"side_r",
				"box",
				{size = Vec3(0.12, 0.4, 2.0)},
				Vec3(0.85, 0.2, 0.2),
				nil,
				"paint"
			),
			part(
				"bumper_f",
				"box",
				{size = Vec3(1.8, 0.15, 0.12)},
				Vec3(0, -0.05, -2.15),
				nil,
				METAL
			),
			part(
				"bumper_r",
				"box",
				{size = Vec3(1.8, 0.15, 0.12)},
				Vec3(0, -0.05, 2.15),
				nil,
				METAL
			),
			part(
				"lamp_l",
				"box",
				{size = Vec3(0.3, 0.12, 0.04)},
				Vec3(-0.6, 0.22, -2.11),
				nil,
				LIGHT
			),
			part(
				"lamp_r",
				"box",
				{size = Vec3(0.3, 0.12, 0.04)},
				Vec3(0.6, 0.22, -2.11),
				nil,
				LIGHT
			),
			part(
				"windshield",
				"box",
				{size = Vec3(1.6, 0.42, 0.04)},
				Vec3(0, 0.52, -0.72),
				pitch(0.45),
				GLASS
			),
			part("seat_l", "box", {size = Vec3(0.5, 0.1, 0.45)}, Vec3(-0.4, 0.08, 0.45), nil, SEAT),
			part(
				"back_l",
				"box",
				{size = Vec3(0.5, 0.6, 0.1)},
				Vec3(-0.4, 0.4, 0.74),
				pitch(-0.2),
				SEAT
			),
			part("seat_r", "box", {size = Vec3(0.5, 0.1, 0.45)}, Vec3(0.4, 0.08, 0.45), nil, SEAT),
			part(
				"back_r",
				"box",
				{size = Vec3(0.5, 0.6, 0.1)},
				Vec3(0.4, 0.4, 0.74),
				pitch(-0.2),
				SEAT
			),
			part(
				"column",
				"box",
				{size = Vec3(0.05, 0.05, 0.5)},
				Vec3(-0.4, 0.42, -0.3),
				pitch(0.45),
				DARK
			),
			node("steering", Vec3(-0.4, 0.55, -0.08), pitch(1.1)),
			part("spoke", "box", {size = Vec3(0.36, 0.035, 0.04)}, Vec3(), nil, METAL, "steering"),
			node("grip_l", Vec3(-0.18, 0, 0), pitch(-1.1), "steering"),
			node("grip_r", Vec3(0.18, 0, 0), pitch(-1.1), "steering"),
			node("pedal_l", Vec3(-0.52, 0.06, -0.32)),
			node("pedal_r", Vec3(-0.28, 0.06, -0.32)),
		},
	},
	motorbike = {
		DisplayName = "Motorbike",
		Type = "bike",
		Mass = 220,
		SpawnHeight = 0.62,
		SpawnYaw = math.pi / 2,
		SpawnForward = 0.5,
		BuoyancyDensity = 1500,
		Color = Color(0.1, 0.25, 0.75, 1),
		Colliders = {
			box(Vec3(0.3, 0.4, 1.0), Vec3(0, -0.05, 0)),
			box(Vec3(0.3, 0.18, 0.95), Vec3(0, 0.23, 0.12)),
		},
		Suspension = {Stiffness = 22000, Damping = 1600, Travel = 0.15},
		Wheels = {
			{
				Position = Vec3(0, -0.29, -0.72),
				Radius = 0.31,
				Width = 0.12,
				Mass = 12,
				Steer = true,
				Brake = 600,
			},
			{
				Position = Vec3(0, -0.29, 0.72),
				Radius = 0.31,
				Width = 0.15,
				Mass = 14,
				Drive = true,
				Brake = 350,
			},
		},
		WheelFriction = 1.2,
		Engine = {Torque = 420, Speed = 42, ReverseSpeed = 3, Braking = 40},
		Steering = {Angle = 0.5, Rate = 3, Ratio = 1, Node = "steering"},
		Balance = {MaxTorque = 2500, Hertz = 2.5, DampingRatio = 0.9, MaxLean = 0.8},
		Drag = 0.25,
		Seat = {
			Pose = "ride",
			Position = Vec3(0, 0.4, 0.22),
			EyeHeight = 0.66,
			ExitPosition = Vec3(-1.0, -0.55, 0.2),
			CameraDistance = 4.5,
			CameraHeight = 1.0,
			FootLeft = "peg_l",
			FootRight = "peg_r",
		},
		Parts = {
			part("frame", "box", {size = Vec3(0.22, 0.38, 0.95)}, Vec3(0, -0.05, 0), nil, DARK),
			part("engine", "box", {size = Vec3(0.34, 0.3, 0.4)}, Vec3(0, -0.12, -0.05), nil, METAL),
			part(
				"tank",
				"box",
				{size = Vec3(0.32, 0.22, 0.45)},
				Vec3(0, 0.27, -0.18),
				nil,
				"paint"
			),
			part("seat", "box", {size = Vec3(0.28, 0.08, 0.5)}, Vec3(0, 0.3, 0.3), nil, SEAT),
			part(
				"tail",
				"box",
				{size = Vec3(0.24, 0.12, 0.35)},
				Vec3(0, 0.3, 0.68),
				pitch(0.2),
				"paint"
			),
			part("swingarm", "box", {size = Vec3(0.2, 0.06, 0.7)}, Vec3(0, -0.22, 0.4), nil, METAL),
			node("steering", Vec3(0, 0.45, -0.72)),
			part(
				"fork_l",
				"box",
				{size = Vec3(0.04, 0.72, 0.04)},
				Vec3(-0.08, -0.38, 0),
				nil,
				METAL,
				"steering"
			),
			part(
				"fork_r",
				"box",
				{size = Vec3(0.04, 0.72, 0.04)},
				Vec3(0.08, -0.38, 0),
				nil,
				METAL,
				"steering"
			),
			part(
				"headlight",
				"cylinder",
				{radius = 0.09, height = 0.06},
				Vec3(0, -0.02, -0.06),
				pitch(math.pi / 2),
				LIGHT,
				"steering"
			),
			part(
				"bar",
				"box",
				{size = Vec3(0.66, 0.035, 0.035)},
				Vec3(0, 0.22, 0.38),
				nil,
				DARK,
				"steering"
			),
			part(
				"riser",
				"box",
				{size = Vec3(0.04, 0.04, 0.44)},
				Vec3(0, 0.11, 0.19),
				pitch(-0.52),
				DARK,
				"steering"
			),
			node("grip_l", Vec3(-0.3, 0.22, 0.38), nil, "steering"),
			node("grip_r", Vec3(0.3, 0.22, 0.38), nil, "steering"),
			node("peg_l", Vec3(-0.2, -0.08, 0.02)),
			node("peg_r", Vec3(0.2, -0.08, 0.02)),
		},
	},
	boat = {
		DisplayName = "Boat",
		Type = "boat",
		Mass = 1000,
		SpawnHeight = 0.4,
		SpawnYaw = math.pi / 2,
		SpawnForward = 1.2,
		FluidDrag = Vec3(4, 3, 0.05),
		Color = Color(0.92, 0.92, 0.88, 1),
		Colliders = {
			box(Vec3(1.9, 0.35, 3.6), Vec3(0, -0.05, 0.4)),
			box(Vec3(1.34, 0.35, 1.34), Vec3(0, -0.05, -1.4), yaw(math.pi / 4)),
			box(Vec3(0.1, 0.35, 3.6), Vec3(-0.9, 0.3, 0.4)),
			box(Vec3(0.1, 0.35, 3.6), Vec3(0.9, 0.3, 0.4)),
		},
		Thrust = {
			Force = 7500,
			Speed = 22,
			Position = Vec3(0, -0.5, 2.3),
			Angle = 0.4,
			Rate = 2,
			Node = "outboard",
		},
		Steering = {Ratio = 3, Node = "steering"},
		Propeller = {Node = "propeller", Speed = 60},
		Seat = {
			Pose = "drive",
			Position = Vec3(0, 0.25, 0.95),
			EyeHeight = 0.68,
			ExitPosition = Vec3(-1.6, 0.2, 0.4),
			CameraDistance = 7,
			CameraHeight = 1.4,
		},
		Parts = {
			part("hull", "box", {size = Vec3(1.9, 0.35, 3.6)}, Vec3(0, -0.05, 0.4), nil, "paint"),
			part(
				"bow",
				"box",
				{size = Vec3(1.34, 0.35, 1.34)},
				Vec3(0, -0.05, -1.4),
				yaw(math.pi / 4),
				"paint"
			),
			part(
				"side_l",
				"box",
				{size = Vec3(0.1, 0.35, 3.6)},
				Vec3(-0.9, 0.3, 0.4),
				nil,
				"paint"
			),
			part("side_r", "box", {size = Vec3(0.1, 0.35, 3.6)}, Vec3(0.9, 0.3, 0.4), nil, "paint"),
			part("deck", "box", {size = Vec3(1.7, 0.02, 3.4)}, Vec3(0, 0.13, 0.5), nil, SEAT),
			part("bench", "box", {size = Vec3(0.8, 0.12, 0.45)}, Vec3(0, 0.19, 1.0), nil, SEAT),
			part("console", "box", {size = Vec3(0.6, 0.55, 0.35)}, Vec3(0, 0.4, 0.25), nil, DARK),
			part(
				"screen",
				"box",
				{size = Vec3(0.6, 0.3, 0.03)},
				Vec3(0, 0.82, 0.12),
				pitch(0.3),
				GLASS
			),
			node("steering", Vec3(0, 0.62, 0.48), pitch(1.0)),
			part("spoke", "box", {size = Vec3(0.32, 0.035, 0.04)}, Vec3(), nil, METAL, "steering"),
			node("grip_l", Vec3(-0.16, 0, 0), pitch(-1.0), "steering"),
			node("grip_r", Vec3(0.16, 0, 0), pitch(-1.0), "steering"),
			node("outboard", Vec3(0, 0.15, 2.25)),
			part(
				"motor",
				"box",
				{size = Vec3(0.3, 0.42, 0.38)},
				Vec3(0, 0.12, 0.05),
				nil,
				DARK,
				"outboard"
			),
			part(
				"shaft",
				"box",
				{size = Vec3(0.08, 0.7, 0.1)},
				Vec3(0, -0.4, 0.05),
				nil,
				DARK,
				"outboard"
			),
			node("propeller", Vec3(0, -0.65, 0.12), nil, "outboard"),
			part("blade_a", "box", {size = Vec3(0.3, 0.06, 0.02)}, Vec3(), nil, METAL, "propeller"),
			part("blade_b", "box", {size = Vec3(0.06, 0.3, 0.02)}, Vec3(), nil, METAL, "propeller"),
		},
	},
	plane = {
		DisplayName = "Plane",
		Type = "plane",
		Mass = 550,
		SpawnHeight = 1.45,
		SpawnYaw = 0,
		SpawnForward = 4.5,
		BuoyancyDensity = 900,
		Color = Color(0.95, 0.8, 0.15, 1),
		Colliders = {
			box(Vec3(1.0, 0.6, 6.4), Vec3(0, -0.25, 0.55)),
			box(Vec3(1.0, 0.5, 1.2), Vec3(0, 0.3, -2.05)),
			box(Vec3(0.8, 0.4, 3.4), Vec3(0, 0.25, 2.05)),
			box(Vec3(10, 0.14, 1.5), Vec3(0, 0.95, -0.1)),
			box(Vec3(3.2, 0.08, 0.9), Vec3(0, 0.15, 3.35)),
			box(Vec3(0.08, 1.1, 0.9), Vec3(0, 0.75, 3.35)),
		},
		Suspension = {Stiffness = 35000, Damping = 2400, Travel = 0.2},
		Wheels = {
			{
				Position = Vec3(0, -1.0, -2.2),
				Radius = 0.25,
				Width = 0.12,
				Mass = 8,
				Steer = true,
				Stiffness = 14000,
				Damping = 1200,
			},
			{
				Position = Vec3(-1.0, -1.0, 0.15),
				Radius = 0.28,
				Width = 0.14,
				Mass = 10,
				Brake = 700,
			},
			{
				Position = Vec3(1.0, -1.0, 0.15),
				Radius = 0.28,
				Width = 0.14,
				Mass = 10,
				Brake = 700,
			},
		},
		WheelFriction = 0.9,
		Steering = {Angle = 0.5, Rate = 3},
		Thrust = {Force = 3800, Speed = 75, Position = Vec3(0, 0.05, -2.75), Rate = 0.6},
		Propeller = {Node = "propeller", Speed = 140},
		Drag = 0.35,
		Surfaces = {
			{
				Position = Vec3(-2.5, 0.95, -0.1),
				Normal = Vec3(0, 1, 0),
				Area = 7.5,
				Incidence = 0.06,
				Slope = 4.8,
				Aileron = 1,
			},
			{
				Position = Vec3(2.5, 0.95, -0.1),
				Normal = Vec3(0, 1, 0),
				Area = 7.5,
				Incidence = 0.06,
				Slope = 4.8,
				Aileron = -1,
			},
			{
				Position = Vec3(0, 0.15, 3.35),
				Normal = Vec3(0, 1, 0),
				Area = 2.9,
				Incidence = -0.02,
				Slope = 4.0,
				Elevator = 1,
			},
			{
				Position = Vec3(0, 0.75, 3.35),
				Normal = Vec3(1, 0, 0),
				Area = 1.0,
				Incidence = 0,
				Slope = 2.4,
				Rudder = 1,
			},
		},
		Controls = {Aileron = 0.12, Elevator = 0.3, Rudder = 0.25, RudderMix = 0.3},
		Seat = {
			Pose = "pilot",
			Position = Vec3(0, -0.1, -0.55),
			EyeHeight = 0.68,
			ExitPosition = Vec3(-1.4, -1.33, -0.4),
			CameraDistance = 11,
			CameraHeight = 1.5,
		},
		Parts = {
			part("belly", "box", {size = Vec3(1.0, 0.6, 6.4)}, Vec3(0, -0.25, 0.55), nil, "paint"),
			part("cowling", "box", {size = Vec3(1.0, 0.5, 1.2)}, Vec3(0, 0.3, -2.05), nil, "paint"),
			part("spine", "box", {size = Vec3(0.8, 0.4, 3.4)}, Vec3(0, 0.25, 2.05), nil, "paint"),
			part("wing", "box", {size = Vec3(10, 0.14, 1.5)}, Vec3(0, 0.95, -0.1), nil, "paint"),
			part(
				"strut_l",
				"box",
				{size = Vec3(0.05, 0.9, 0.05)},
				Vec3(-0.45, 0.45, -0.5),
				nil,
				METAL
			),
			part(
				"strut_r",
				"box",
				{size = Vec3(0.05, 0.9, 0.05)},
				Vec3(0.45, 0.45, -0.5),
				nil,
				METAL
			),
			part(
				"strut_bl",
				"box",
				{size = Vec3(0.05, 0.9, 0.05)},
				Vec3(-0.45, 0.45, 0.3),
				nil,
				METAL
			),
			part(
				"strut_br",
				"box",
				{size = Vec3(0.05, 0.9, 0.05)},
				Vec3(0.45, 0.45, 0.3),
				nil,
				METAL
			),
			part(
				"stabilizer",
				"box",
				{size = Vec3(3.2, 0.08, 0.7)},
				Vec3(0, 0.15, 3.25),
				nil,
				"paint"
			),
			part("fin", "box", {size = Vec3(0.08, 1.1, 0.7)}, Vec3(0, 0.75, 3.25), nil, "paint"),
			node("elevator", Vec3(0, 0.15, 3.6)),
			part(
				"elevator_surface",
				"box",
				{size = Vec3(3.2, 0.06, 0.3)},
				Vec3(0, 0, 0.15),
				nil,
				"paint",
				"elevator"
			),
			node("rudder", Vec3(0, 0.75, 3.6)),
			part(
				"rudder_surface",
				"box",
				{size = Vec3(0.06, 1.1, 0.3)},
				Vec3(0, 0, 0.15),
				nil,
				"paint",
				"rudder"
			),
			node("aileron_l", Vec3(-3.3, 0.95, 0.65)),
			part(
				"aileron_l_surface",
				"box",
				{size = Vec3(3.0, 0.1, 0.3)},
				Vec3(0, 0, 0.1),
				nil,
				DARK,
				"aileron_l"
			),
			node("aileron_r", Vec3(3.3, 0.95, 0.65)),
			part(
				"aileron_r_surface",
				"box",
				{size = Vec3(3.0, 0.1, 0.3)},
				Vec3(0, 0, 0.1),
				nil,
				DARK,
				"aileron_r"
			),
			part(
				"windshield",
				"box",
				{size = Vec3(0.9, 0.35, 0.04)},
				Vec3(0, 0.2, -1.35),
				pitch(0.6),
				GLASS
			),
			part("seat", "box", {size = Vec3(0.5, 0.08, 0.5)}, Vec3(0, -0.2, -0.5), nil, SEAT),
			part(
				"seat_back",
				"box",
				{size = Vec3(0.5, 0.6, 0.08)},
				Vec3(0, 0.1, -0.22),
				pitch(-0.2),
				SEAT
			),
			part(
				"gear_l",
				"box",
				{size = Vec3(0.9, 0.05, 0.08)},
				Vec3(-0.6, -0.75, 0.15),
				Quat():Identity():RotateRoll(-0.45),
				METAL
			),
			part(
				"gear_r",
				"box",
				{size = Vec3(0.9, 0.05, 0.08)},
				Vec3(0.6, -0.75, 0.15),
				Quat():Identity():RotateRoll(0.45),
				METAL
			),
			part("gear_n", "box", {size = Vec3(0.05, 0.6, 0.05)}, Vec3(0, -0.7, -2.2), nil, METAL),
			node("propeller", Vec3(0, 0.05, -2.7)),
			part(
				"spinner",
				"cone",
				{radius = 0.15, height = 0.25},
				Vec3(0, 0, -0.1),
				pitch(-math.pi / 2),
				METAL,
				"propeller"
			),
			part("blade_a", "box", {size = Vec3(1.8, 0.14, 0.03)}, Vec3(), nil, DARK, "propeller"),
			node("yoke", Vec3(0, 0.22, -1.0), pitch(1.2)),
			part("yoke_bar", "box", {size = Vec3(0.32, 0.03, 0.03)}, Vec3(), nil, DARK, "yoke"),
			part(
				"yoke_column",
				"box",
				{size = Vec3(0.03, 0.03, 0.3)},
				Vec3(0, -0.15, 0),
				pitch(-1.2),
				DARK,
				"yoke"
			),
			node("grip_l", Vec3(-0.15, 0, 0), pitch(-1.2), "yoke"),
			node("grip_r", Vec3(0.15, 0, 0), pitch(-1.2), "yoke"),
		},
	},
}
local RING_SEGMENTS = 12

local function add_ring(parts, name, radius, parent)
	local length = 2.2 * radius * math.sin(math.pi / RING_SEGMENTS)

	for i = 1, RING_SEGMENTS do
		local angle = i * math.pi * 2 / RING_SEGMENTS
		parts[#parts + 1] = part(
			name .. i,
			"box",
			{size = Vec3(length, 0.03, 0.03)},
			Vec3(math.cos(angle) * radius, 0, math.sin(angle) * radius),
			yaw(-(angle + math.pi / 2)),
			DARK,
			parent
		)
	end
end

add_ring(vehicles.Definitions.car.Parts, "rim", 0.19, "steering")
add_ring(vehicles.Definitions.boat.Parts, "rim", 0.17, "steering")
vehicles.Names = {"car", "motorbike", "boat", "plane"}

function vehicles.GetPrefabName(name)
	return "vehicle_" .. name
end

local function get_model(item)
	if item.Model == "box" then return "models/box.lua" end

	if item.Model == "cylinder" then return "models/cylinder.lua" end

	if item.Model == "cone" then return "models/cone.lua" end

	return "models/sphere.lua"
end

local function build_prefab(name, def)
	local seat = def.Seat
	local paint_targets = {}
	local entities = {
		{
			guid = "root",
			components = {
				usable = {Prompt = "drive"},
				seat = {
					Pose = seat.Pose,
					Position = seat.Position,
					EyeHeight = seat.EyeHeight,
					ExitPosition = seat.ExitPosition,
					CameraDistance = seat.CameraDistance,
					CameraHeight = seat.CameraHeight,
					HandLeft = "grip_l",
					HandRight = "grip_r",
					FootLeft = seat.FootLeft or "",
					FootRight = seat.FootRight or "",
				},
				vehicle = {Kind = name},
			},
		},
	}

	for _, item in ipairs(def.Parts) do
		local components = {
			transform = {
				Position = item.Position:Copy(),
				Rotation = item.Rotation and item.Rotation:Copy(),
			},
		}

		if item.Model then
			local material = item.Material

			if material == "paint" then
				material = {Color = def.Color, Roughness = 0.35, Metallic = 0}
				paint_targets[#paint_targets + 1] = {
					Node = item.Name,
					Component = "model",
					Property = "MaterialConfig",
					Key = "Color",
				}
			end

			components.model = {
				ModelPath = get_model(item),
				ModelOptions = item.Options,
				MaterialConfig = material,
			}
		end

		entities[#entities + 1] = {
			guid = item.Name,
			parent = item.Parent or "root",
			properties = {Name = item.Name},
			components = components,
		}
	end

	for i, wheel in ipairs(def.Wheels or {}) do
		local wheel_name = "wheel" .. i
		entities[#entities + 1] = {
			guid = wheel_name,
			parent = "root",
			properties = {Name = wheel_name},
			components = {transform = {Position = wheel.Position:Copy()}},
		}
		entities[#entities + 1] = {
			guid = wheel_name .. "_tire",
			parent = wheel_name,
			properties = {Name = wheel_name .. "_tire"},
			components = {
				transform = {Rotation = Quat():Identity():RotateRoll(math.pi / 2)},
				model = {
					ModelPath = "models/cylinder.lua",
					ModelOptions = {radius = wheel.Radius, height = wheel.Width},
					MaterialConfig = TIRE,
				},
			},
		}
		entities[#entities + 1] = {
			guid = wheel_name .. "_hub",
			parent = wheel_name,
			properties = {Name = wheel_name .. "_hub"},
			components = {
				transform = {},
				model = {
					ModelPath = "models/box.lua",
					ModelOptions = {size = Vec3(wheel.Width + 0.02, wheel.Radius * 1.2, wheel.Radius * 0.25)},
					MaterialConfig = RIM,
				},
			},
		}
	end

	prefab.Register(
			vehicles.GetPrefabName(name),
			{
				inputs = {{Name = "Color", Type = "color", Default = def.Color, Targets = paint_targets}},
				entities = entities,
			}
		).builtin = true
end

for _, name in ipairs(vehicles.Names) do
	build_prefab(name, vehicles.Definitions[name])
end

-- yaw is the direction the spawner looks along, the vehicle is placed beyond the point it looks at
function vehicles.Spawn(name, position, yaw)
	local def = vehicles.Definitions[name]
	local forward = Vec3(-math.sin(yaw), 0, -math.cos(yaw)) * def.SpawnForward
	return Entity.New{
		Name = def.DisplayName,
		Transient = false,
		transform = {
			Position = position + forward + Vec3(0, def.SpawnHeight, 0),
			Rotation = QuatFromAxis(yaw + def.SpawnYaw, Vec3(0, 1, 0)),
		},
		prefab = {Path = vehicles.GetPrefabName(name)},
		network = SERVER and {} or nil,
	}
end

return vehicles
