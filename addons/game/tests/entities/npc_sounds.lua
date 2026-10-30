local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local physics = import("goluwa/physics.lua")
local steam = import("goluwa/steam/steam.lua")
local vfs = import("goluwa/vfs.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
Entity.RegisterComponent("character_movement", import("lua/components/character_movement.lua"))
Entity.RegisterComponent("ai_controller", import("lua/components/ai_controller.lua"))
Entity.RegisterComponent("usable", import("lua/components/usable.lua"))
Entity.RegisterComponent("weapon_holder", import("lua/components/weapon_holder.lua"))
Entity.RegisterComponent("weapon", import("lua/components/weapon.lua"))
import("lua/weapons.lua")
import("addons/game/lua/autorun/characters.lua")
local npcs = import("lua/npcs.lua")

local function create_ground()
	return Entity.New{
		transform = {Position = Vec3(0, -0.5, 0), Scale = Vec3(300, 1, 300)},
		rigid_body = {
			MotionType = "static",
			WorldGeometry = true,
			Shape = BoxShape.New(Vec3(1, 1, 1)),
			Friction = 0.85,
		},
	}
end

T.TestPhysics("a creature npc plays one footstep per step length it walks", function()
	steam.MountSourceGame("gmod")

	if not vfs.IsFile("models/zombie/classic.mdl") then
		return T.Unavailable("gmod content not mounted")
	end

	local ground = create_ground()
	local npc = npcs.Spawn("zombie", Vec3(0, 0.05, 0), 0)
	npc.ai_controller:SetWander(false)
	local sounds = npc.npc_sounds
	local played = {}

	function sounds:Play(role)
		played[#played + 1] = role
	end

	local function run(seconds)
		for _ = 1, seconds * 60 do
			physics.UpdateFixed(1 / 60)
			npc.character_pose:OnUpdate(1 / 60)
			sounds:OnUpdate()
		end
	end

	run(1)
	T(#played)["=="](0)
	npc.ai_controller:MoveTo(Vec3(8, 0.05, 0), false)
	local start = npc.transform:GetPosition():Copy()
	run(6)
	local walked = npc.transform:GetPosition():Distance(start)
	local expected = walked / npc.npc_sounds.Sounds.Foot.Length
	T(walked > 2)["=="](true)
	T(math.abs(#played - expected) <= 1.5)["=="](true)
	T(played[1])["=="]("Foot")
	npc:Remove()
	ground:Remove()
end)
