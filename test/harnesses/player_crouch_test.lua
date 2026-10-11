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

local steps = 0

event.AddListener("PhysicsUpdate", "crouch_test_driver", function()
	steps = steps + 1

	if steps == 90 then
		local shape = body:GetPhysicsShape()
		local feet = rig.transform:GetPosition().y - shape:GetHeight() * 0.5
		print(
			string.format(
				"STAND radius=%.4f (%.1f u) height=%.4f (%.1f u) eye_offset=%.4f feet=%.3f",
				shape:GetRadius(),
				shape:GetRadius() / u,
				shape:GetHeight(),
				shape:GetHeight() / u,
				movement:GetEyeOffset().y,
				feet
			)
		)
		movement:SetCrouch(true)
		print(
			"AFTER SetCrouch",
			tostring(movement:IsCrouching()),
			tostring(movement.CrouchTransition),
			tostring(movement.crouch_alpha)
		)
		movement:UpdateCrouchTransition(1)
		print(
			"AFTER Update",
			tostring(movement.crouch_alpha),
			body:GetPhysicsShape():GetHeight(),
			tostring(body:GetPhysicsShape():GetTypeName())
		)
	elseif steps == 150 then
		local shape = body:GetPhysicsShape()
		local feet = rig.transform:GetPosition().y - shape:GetHeight() * 0.5
		local _, _, eye = movement:GetDimensions(1)
		print(
			string.format(
				"CROUCH radius=%.4f (%.1f u) height=%.4f (%.1f u) eye=%.4f (%.1f u) feet=%.3f grounded=%s",
				shape:GetRadius(),
				shape:GetRadius() / u,
				shape:GetHeight(),
				shape:GetHeight() / u,
				eye,
				eye / u,
				feet,
				tostring(body:GetGrounded())
			)
		)
		system.ShutDown(0)
	end
end)
