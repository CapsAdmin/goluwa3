local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local event = import("goluwa/event.lua")
local physics = import("goluwa/physics.lua")
local system = import("goluwa/system.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local Vec3 = import("goluwa/structs/vec3.lua")

local function create_floor()
	return Entity.New{
		transform = {Position = Vec3(0, -0.5, 0)},
		rigid_body = {Shape = BoxShape.New(Vec3(120, 1, 120)), MotionType = "static"},
	}
end

local function create_pile(x, count, can_sleep)
	local boxes = {}

	for i = 1, count do
		boxes[i] = Entity.New{
			transform = {Position = Vec3(x + (i % 3) * 0.05, 0.5 + (i - 1), 0)},
			rigid_body = {Shape = BoxShape.New(Vec3(1, 1, 1)), CanSleep = can_sleep},
		}
	end

	return boxes
end

local function run_slow_ticks(count)
	local instance = physics.instance
	local previous = instance.SlowStepTime
	instance.SlowStepTime = 1e-9

	for _ = 1, count do
		physics.UpdateFixed(instance.FixedTimeStep)
	end

	instance.SlowStepTime = previous
	instance.TimeIslands = false
end

T.TestPhysics("slow ticks put the busiest island to sleep", function()
	create_floor()
	local pile = create_pile(0, 30, true)
	local immune = create_pile(60, 1, false)[1]
	run_slow_ticks(4)

	for _, box in ipairs(pile) do
		T(box.rigid_body:GetAwake())["=="](false)
	end

	T(immune.rigid_body:GetAwake())["=="](true)
end)

T.TestPhysics("slow ticks leave an island awake when it holds a body that cannot sleep", function()
	create_floor()
	local pile = create_pile(0, 30, true)
	pile[15].rigid_body:SetCanSleep(false)
	run_slow_ticks(4)
	local awake = 0

	for _, box in ipairs(pile) do
		if box.rigid_body:GetAwake() then awake = awake + 1 end
	end

	T(awake)[">="](29)
end)

T.TestPhysics("a frame spending too long in physics drops its backlog", function()
	local instance = physics.instance
	local previous = instance.MaxFrameStepTime
	local ticks = 0
	instance.MaxFrameStepTime = 0.05

	event.AddListener("PhysicsUpdate", "slow_step_test", function()
		ticks = ticks + 1
		local start = system.GetTime()

		while system.GetTime() - start < 0.03 do

		end
	end)

	physics.UpdateFixed(0.1)
	event.RemoveListener("PhysicsUpdate", "slow_step_test")
	instance.MaxFrameStepTime = previous
	T(ticks)["=="](2)
	T(instance.FrameAccumulator)["=="](0)
end)
