local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local physics = import("goluwa/physics.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local pvars = import("goluwa/cli/pvars.lua")
local character_scale = import("lua/character_scale.lua")
local CharacterMovement = import("lua/components/character_movement.lua")
local engines = import("goluwa/engines.lua")
local event = import("goluwa/event.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
import("addons/game/lua/autorun/characters.lua")
Entity.RegisterComponent("player_controller", import("lua/components/player_controller.lua"))
Entity.RegisterComponent("character_movement", import("lua/components/character_movement.lua"))

local function create_character(scale)
	local character = Entity.New{
		ComponentSet = {
			"transform",
			"player_controller",
			"character_movement",
			"character_pose",
			"ragdoll",
			"health",
		},
		transform = {Position = Vec3(0, 0.1, 0)},
		player_controller = {Source = "queue"},
		character_movement = {Scale = scale},
	}
	character.player_controller.cmd.mode = "walk"
	character.player_controller.cmd.buttons = usercmd.BUTTON.ACTIVE
	return character
end

local function run_forward(character, seconds)
	for _ = 1, seconds * 60 do
		character.player_controller.starved = 0
		character.player_controller.cmd.forward = 1
		physics.UpdateFixed(1 / 60)
	end

	return -character.transform:GetPosition().z
end

T.TestPhysics("a character scale multiplies the body, the eyes and the speeds", function()
	Entity.New{
		transform = {Position = Vec3(0, -0.5, 0), Scale = Vec3(400, 1, 400)},
		rigid_body = {MotionType = "static", Shape = BoxShape.New(Vec3(1, 1, 1))},
	}
	local normal = create_character(1)
	local tall = create_character(1.5)
	local normal_movement, tall_movement = normal.character_movement, tall.character_movement
	T(tall_movement:GetHeight())["~"](normal_movement:GetHeight() * 1.5, 1e-6)
	T(tall_movement:GetEyeHeight())["~"](normal_movement:GetEyeHeight() * 1.5, 1e-6)
	T(tall_movement:GetRadius())["~"](normal_movement:GetRadius() * 1.5, 1e-6)
	T(tall_movement:GetGroundSpeed())["~"](normal_movement:GetGroundSpeed() * 1.5, 1e-6)
	T(tall_movement:GetJumpSpeed())["~"](normal_movement:GetJumpSpeed() * 1.5, 1e-6)
	T(tall_movement.BodyMass)["~"](normal_movement.BodyMass * 1.5 ^ 3, 1e-6)
	T(tall.rigid_body:GetPhysicsShape():GetHeight())["~"](tall_movement:GetHeight(), 1e-6)
	normal.transform:SetPosition(Vec3(-20, 0.1, 0))
	tall.transform:SetPosition(Vec3(20, 0.1, 0))
	local normal_distance = run_forward(normal, 2)
	local tall_distance = run_forward(tall, 2)
	T(tall_distance / normal_distance)["~"](1.5, 0.1)
end)

T.TestPhysics("changing the scale of a live character resizes its capsule", function()
	local character = create_character(1)
	local movement = character.character_movement
	local height = movement:GetHeight()
	movement:SetScale(2)
	T(movement:GetHeight())["~"](height * 2, 1e-6)
	T(character.rigid_body:GetPhysicsShape():GetHeight())["~"](height * 2, 1e-6)
	movement:SetScale(1)
	T(movement:GetHeight())["~"](height, 1e-6)
	T(character.rigid_body:GetPhysicsShape():GetHeight())["~"](height, 1e-6)
end)

T.TestPhysics("the body parts of a scaled character are scaled with it", function()
	Entity.New{
		transform = {Position = Vec3(0, -0.5, 0), Scale = Vec3(100, 1, 100)},
		rigid_body = {MotionType = "static", Shape = BoxShape.New(Vec3(1, 1, 1))},
	}
	local normal = create_character(1)
	local tall = create_character(2)
	physics.UpdateFixed(1 / 60)
	normal.character_pose:OnUpdate(1 / 60)
	tall.character_pose:OnUpdate(1 / 60)

	for i, part in ipairs(normal.ragdoll.parts) do
		local other = tall.ragdoll.parts[i]
		T(other.body:GetPhysicsShape():GetRadius())["~"](part.body:GetPhysicsShape():GetRadius() * 2, 1e-6)
		T(other.half)["~"](part.half * 2, 1e-3)
	end

	T(tall.ragdoll.total_mass / normal.ragdoll.total_mass)["~"](8, 1e-3)
end)

T.TestPhysics("a scaled character jumps as high relative to its body and stays in the air as long", function()
	local normal = create_character(1).character_movement
	local tall = create_character(2).character_movement
	T((tall.JumpSpeed ^ 2 / tall.Gravity) / (normal.JumpSpeed ^ 2 / normal.Gravity))["~"](2, 1e-6)
	T((tall.JumpSpeed / tall.Gravity) / (normal.JumpSpeed / normal.Gravity))["~"](1, 1e-6)
end)

T.TestPhysics("a ragdoll is rebuilt at the new size when the character scale changes", function()
	Entity.New{
		transform = {Position = Vec3(0, -0.5, 0), Scale = Vec3(100, 1, 100)},
		rigid_body = {MotionType = "static", Shape = BoxShape.New(Vec3(1, 1, 1))},
	}
	local reference = create_character(1)
	local character = create_character(10)
	physics.UpdateFixed(1 / 60)
	reference.character_pose:OnUpdate(1 / 60)
	character.character_pose:OnUpdate(1 / 60)
	T(character.ragdoll.parts[1].definition.Radius)["~"](reference.ragdoll.parts[1].definition.Radius * 10, 1e-6)
	T(character.rigid_body:GetHalfExtents().x)[">"](reference.rigid_body:GetHalfExtents().x * 5)
	character.character_movement:SetScale(1)
	T(character.rigid_body:GetHalfExtents().x)["~"](reference.rigid_body:GetHalfExtents().x, 1e-4)
	physics.UpdateFixed(1 / 60)
	character.character_pose:OnUpdate(1 / 60)
	T(#character.ragdoll.parts)["=="](#reference.ragdoll.parts)

	for i, part in ipairs(reference.ragdoll.parts) do
		local other = character.ragdoll.parts[i]
		T(other.definition.Radius)["~"](part.definition.Radius, 1e-6)
		T(other.half)["~"](part.half, 1e-3)
	end
end)

T.TestPhysics("the speed that hurts follows the character scale by the fall damage exponent", function()
	local function health_after(scale, speed)
		local character = create_character(scale)
		character.character_movement:Impact(speed)
		return character.health:GetHealth() / character.health:GetMaxHealth()
	end

	pvars.SetSession("sv_fall_damage_exponent", 1)
	T(health_after(1, 6))["=="](1)
	T(health_after(2, 12))["=="](1)
	T(health_after(2, 16))["<"](1)
	T(health_after(0.1, 0.9))["<"](1)
	pvars.SetSession("sv_fall_damage_exponent", 0)
	T(health_after(2, 6))["=="](1)
	T(health_after(2, 16))["<"](1)
	T(health_after(0.1, 0.9))["=="](1)
	T(health_after(0.1, 9))["<"](1)
	pvars.SetSession("sv_fall_damage_exponent", 1)
end)

T.Test("the scale of a character comes from its movement, else its npc transform, else its avatar", function()
	local function transform(scale)
		return {
			GetScale = function()
				return Vec3(scale, scale, scale)
			end,
		}
	end

	T(
		character_scale.Get{
			transform = transform(1),
			character_movement = {Scale = 4},
			player_avatar = {Scale = 2},
		}
	)["=="](4)
	T(character_scale.Get{transform = transform(3), ai_controller = {}, player_avatar = {Scale = 2}})["=="](3)
	T(character_scale.Get{transform = transform(1), player_avatar = {Scale = 2}})["=="](2)
	T(character_scale.Get{transform = transform(1)})["=="](1)
end)

T.TestPhysics("a player avatar and the movement of its character keep the same scale", function()
	Entity.RegisterComponent("player_avatar", import("lua/components/player_avatar.lua"))
	local character = create_character(2)
	character:AddComponent("player_avatar")
	T(character.player_avatar.Scale)["=="](2)
	character.character_movement:SetScale(5)
	T(character.player_avatar.Scale)["=="](5)
	character.player_avatar:SetScale(0.5)
	T(character.character_movement.Scale)["=="](0.5)
end)

T.TestPhysics("the scale a map asks for multiplies the player scale and a crysis level asks for a 1.8 m player", function()
	import("addons/game/lua/autorun/level_player_scale.lua")
	local character = create_character(1)
	local movement = character.character_movement
	local base = CharacterMovement.PlayerScale:Get()
	CharacterMovement.SetLevelScale(2)
	T(movement.Scale)["~"](base * 2, 1e-6)
	CharacterMovement.SetLevelScale(1)
	T(movement.Scale)["~"](base, 1e-6)
	local previous = engines.loaded_map
	engines.loaded_map = "cry:IA/Quarry"
	event.Call("SceneLoad", "cry:IA/Quarry")
	T(movement:GetHeight())["~"](1.8 * base, 1e-4)
	engines.loaded_map = "source:gm_construct"
	event.Call("SceneLoad", "gm_construct")
	T(movement.Scale)["~"](base, 1e-6)
	engines.loaded_map = previous
end)
