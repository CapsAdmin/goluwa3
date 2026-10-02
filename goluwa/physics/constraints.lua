local Distance = import("goluwa/physics/constraints/distance.lua")
local BallSocket = import("goluwa/physics/constraints/ball_socket.lua")
local Weld = import("goluwa/physics/constraints/weld.lua")
local Hinge = import("goluwa/physics/constraints/hinge.lua")
local Slider = import("goluwa/physics/constraints/slider.lua")
local Ragdoll = import("goluwa/physics/constraints/ragdoll.lua")
local Pulley = import("goluwa/physics/constraints/pulley.lua")
local KeepUpright = import("goluwa/physics/constraints/keep_upright.lua")
local NoCollide = import("goluwa/physics/constraints/no_collide.lua")
-- Constructors for every joint, in world space. A nil body is the world.
-- Every constructor takes an optional config table with the options of its
-- joint class, and every joint accepts CollideConnected, BreakForce and
-- BreakTorque.
local constraints = {}
-- locks the bodies together in their current pose
constraints.Weld = Weld.New
-- pins one point, free rotation
constraints.BallSocket = BallSocket.New
-- ball and socket with twist and swing limits, see ragdoll.lua
constraints.Ragdoll = Ragdoll.New
-- rotation about one axis, with optional limits, motor and friction
constraints.Hinge = Hinge.New
-- translation along one axis, with optional limits, motor and friction
constraints.Slider = Slider.New
-- keeps one local axis of the body pointing along a world axis
constraints.KeepUpright = KeepUpright.New
-- the bodies pass through each other
constraints.NoCollide = NoCollide.New
-- a rope over two fixed pulley points
constraints.Pulley = Pulley.New

-- fixed length
function constraints.Rod(body_0, body_1, anchor_0, anchor_1, config)
	return Distance.New(body_0, body_1, anchor_0, anchor_1, config)
end

-- only pulls once the length is reached
function constraints.Rope(body_0, body_1, anchor_0, anchor_1, config)
	config = config or {}
	config.Unilateral = true
	return Distance.New(body_0, body_1, anchor_0, anchor_1, config)
end

-- a spring: config needs Stiffness, and takes Damping and Length (the rest
-- length); Unilateral makes it pull only
function constraints.Spring(body_0, body_1, anchor_0, anchor_1, config)
	return Distance.New(body_0, body_1, anchor_0, anchor_1, config)
end

-- a rod whose length is driven with :SetTargetLength(length, speed)
constraints.Hydraulic = constraints.Rod
-- a rope whose length is driven with :SetTargetLength(length, speed)
constraints.Winch = constraints.Rope

-- a rod whose length follows a sine wave
function constraints.Muscle(body_0, body_1, anchor_0, anchor_1, center, amplitude, period, config)
	return Distance.New(body_0, body_1, anchor_0, anchor_1, config):SetOscillation(center, amplitude, period)
end

-- a hinge that is driven to `speed` with at most `max_torque`
function constraints.Motor(body_0, body_1, anchor, axis, speed, max_torque, config)
	config = config or {}
	config.MotorSpeed = speed
	config.MaxMotorTorque = max_torque
	return Hinge.New(body_0, body_1, anchor, axis, config)
end

return constraints
