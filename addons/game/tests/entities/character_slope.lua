local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local physics = import("goluwa/physics.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
import("addons/game/lua/autorun/characters.lua")
Entity.RegisterComponent("player_controller", import("lua/components/player_controller.lua"))
Entity.RegisterComponent("character_movement", import("lua/components/character_movement.lua"))

local function create_box(position, size, rotation)
	return Entity.New{
		transform = {Position = position, Scale = size, Rotation = rotation},
		rigid_body = {MotionType = "static", Shape = BoxShape.New(Vec3(1, 1, 1))},
	}
end

local function create_character(position)
	local character = Entity.New{
		ComponentSet = {
			"transform",
			"player_controller",
			"character_movement",
			"character_pose",
			"health",
		},
		transform = {Position = position},
		player_controller = {Source = "queue"},
	}
	character.player_controller.cmd.mode = "walk"
	character.player_controller.cmd.buttons = usercmd.BUTTON.ACTIVE
	return character
end

local function walk(character, seconds)
	local last = character.transform:GetPosition().y
	local largest = 0
	local highest = last

	for _ = 1, seconds * 60 do
		character.player_controller.starved = 0
		character.player_controller.cmd.forward = 1
		physics.UpdateFixed(1 / 60)
		local y = character.transform:GetPosition().y
		largest = math.max(largest, math.abs(y - last))
		highest = math.max(highest, y)
		last = y
	end

	return largest, highest
end

T.TestPhysics("a character slides up a gentle slope instead of stepping up it", function()
	create_box(Vec3(0, -0.5, 0), Vec3(60, 1, 60))
	create_box(Vec3(0, -0.5, -10), Vec3(6, 1, 20), Quat():SetAngles(Vec3(math.rad(15), 0, 0)))
	local character = create_character(Vec3(0, 0.1, -3))
	walk(character, 1)
	local start = character.transform:GetPosition()
	local largest = walk(character, 3)
	local finish = character.transform:GetPosition()
	T(finish.y - start.y)[">"](0.5)
	T(finish.z)["<"](start.z - 3)
	T(largest)["<"](0.06)
end)

T.TestPhysics("a character still steps up onto a ledge", function()
	create_box(Vec3(0, -0.5, 0), Vec3(60, 1, 60))
	create_box(Vec3(0, 0.1, -3), Vec3(4, 0.2, 2))
	local character = create_character(Vec3(0, 0.1, 0))
	local _, highest = walk(character, 1.5)
	T(highest)[">"](0.15)
end)
