local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local steam = import("goluwa/steam/steam.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local u = steam.source2meters
local rig = _G.PLAYER_RIG
local look, movement, body = rig.player_input, rig.player_movement, rig.rigid_body
look:SetMode("walk")
local floor = Entity.New({Name = "jump_floor"})
floor:AddComponent("transform")
floor.transform:SetPosition(Vec3(0, -0.5, 0))
floor:AddComponent(
	"rigid_body",
	{
		Shape = BoxShape.New(Vec3(400, 1, 400)),
		Size = Vec3(400, 1, 400),
		MotionType = "static",
		Friction = 0.5,
		WorldGeometry = true,
	}
)
rig.transform:SetPosition(Vec3(0, movement.Height * 0.5 + 0.02, 0))
body:SynchronizeFromTransform()
body.PreviousPosition = body.Position:Copy()

event.AddListener(
	"PhysicsUpdate",
	"jump_test_input",
	function()
		look.move_local = Vec3()
		look.mouse_trapped = true
		look.speed_multiplier = 1
		look.crouching = _G.CROUCH_TEST or false
		movement.input_frame = system.GetFrameNumber()
	end,
	{priority = 100}
)

local steps, rest_y, apex, phase = 0, nil, -math.huge, "settle"
local crouch_reported = false

event.AddListener("PhysicsUpdate", "jump_test_driver", function()
	steps = steps + 1
	local feet = rig.transform:GetPosition().y - movement.Height * 0.5

	if phase == "settle" and steps == 90 then
		rest_y = feet
		movement.jump_requested = true
		phase = "air"
	elseif phase == "air" then
		apex = math.max(apex, feet)

		if steps > 90 + 120 then
			print(
				string.format(
					"JUMP rest feet=%.3f apex rise=%.3f m = %.1f units (Source jump power 200 = 33.3 units)",
					rest_y,
					apex - rest_y,
					(apex - rest_y) / u
				)
			)
			system.ShutDown(0)
		end
	end
end)
