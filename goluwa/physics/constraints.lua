local Distance = import("goluwa/physics/constraints/distance.lua")
local BallSocket = import("goluwa/physics/constraints/ball_socket.lua")
local Weld = import("goluwa/physics/constraints/weld.lua")
local Hinge = import("goluwa/physics/constraints/hinge.lua")
local Slider = import("goluwa/physics/constraints/slider.lua")
local Ragdoll = import("goluwa/physics/constraints/ragdoll.lua")
local Pulley = import("goluwa/physics/constraints/pulley.lua")
local KeepUpright = import("goluwa/physics/constraints/keep_upright.lua")
local NoCollide = import("goluwa/physics/constraints/no_collide.lua")
local constraints = {}
constraints.Weld = Weld.New
constraints.BallSocket = BallSocket.New
constraints.Ragdoll = Ragdoll.New
constraints.Hinge = Hinge.New
constraints.Slider = Slider.New
constraints.KeepUpright = KeepUpright.New
constraints.NoCollide = NoCollide.New
constraints.Pulley = Pulley.New

function constraints.Rod(body_0, body_1, anchor_0, anchor_1, config)
	return Distance.New(body_0, body_1, anchor_0, anchor_1, config)
end

function constraints.Rope(body_0, body_1, anchor_0, anchor_1, config)
	config = config or {}
	config.Unilateral = true
	return Distance.New(body_0, body_1, anchor_0, anchor_1, config)
end

function constraints.Spring(body_0, body_1, anchor_0, anchor_1, config)
	return Distance.New(body_0, body_1, anchor_0, anchor_1, config)
end

constraints.Hydraulic = constraints.Rod
constraints.Winch = constraints.Rope

function constraints.Muscle(body_0, body_1, anchor_0, anchor_1, center, amplitude, period, config)
	return Distance.New(body_0, body_1, anchor_0, anchor_1, config):SetOscillation(center, amplitude, period)
end

function constraints.Motor(body_0, body_1, anchor, axis, speed, max_torque, config)
	config = config or {}
	config.MotorSpeed = speed
	config.MaxMotorTorque = max_torque
	return Hinge.New(body_0, body_1, anchor, axis, config)
end

return constraints
