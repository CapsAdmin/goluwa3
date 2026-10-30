local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local physics = import("goluwa/physics.lua")
local steam = import("goluwa/steam/steam.lua")
local vfs = import("goluwa/vfs.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
Entity.RegisterComponent("character_movement", import("lua/components/character_movement.lua"))
Entity.RegisterComponent("ai_controller", import("lua/components/ai_controller.lua"))
Entity.RegisterComponent("player_controller", import("lua/components/player_controller.lua"))
Entity.RegisterComponent("usable", import("lua/components/usable.lua"))
Entity.RegisterComponent("weapon_holder", import("lua/components/weapon_holder.lua"))
Entity.RegisterComponent("weapon", import("lua/components/weapon.lua"))
import("lua/weapons.lua")
import("addons/game/lua/autorun/characters.lua")
local npcs = import("lua/npcs.lua")
local voices = import("lua/npc_voices.lua")

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

local function create_target(position)
	local player = Entity.New{
		ComponentSet = {
			"transform",
			"player_controller",
			"character_movement",
			"character_pose",
			"health",
		},
		transform = {Position = position:Copy()},
		player_controller = {Source = "queue"},
		health = {Health = 1000, MaxHealth = 1000},
	}
	player.player_controller.cmd.mode = "walk"
	player.character_movement:TeleportTo(position)
	return player
end

T.TestPhysics("an npc speaks when it sees a target, attacks, hits, is hurt and dies", function()
	steam.MountSourceGame("gmod")

	if not vfs.IsFile("models/zombie/classic.mdl") then
		return T.Unavailable("gmod content not mounted")
	end

	local ground = create_ground()
	local npc = npcs.Spawn("zombie", Vec3(0, 0.05, 0), 0)
	npc.ai_controller:SetWander(false)
	local said = {}

	function npc.npc_sounds:Say(role)
		said[#said + 1] = role
	end

	local player = create_target(Vec3(5, 0.05, 0))

	for _ = 1, 6 * 60 do
		physics.UpdateFixed(1 / 60)
	end

	T(said[1])["=="]("Alert")
	T(table.has_value(said, "Attack") ~= nil)["=="](true)
	T(table.has_value(said, "Hit") ~= nil)["=="](true)
	player.health:SetHealth(0)
	said = {}
	npc.health:TakeDamage({Damage = 1})
	npc.health:TakeDamage({Damage = 1})
	T(#said)["=="](1)
	T(said[1])["=="]("Pain")
	npc.health:TakeDamage({Damage = 1000})
	T(said[2])["=="]("Death")
	npc:Remove()
	player:Remove()
	ground:Remove()
end)

T.Test("every npc sound file exists", function()
	steam.MountSourceGame("gmod")

	if not vfs.IsFile("models/zombie/classic.mdl") then
		return T.Unavailable("gmod content not mounted")
	end

	for name, roles in pairs(voices) do
		for role, set in pairs(roles) do
			T(#set.Paths > 0)["=="](true)

			for _, path in ipairs(set.Paths) do
				if not vfs.IsFile("sound/" .. path) then error(name .. " " .. role .. " " .. path .. " is missing") end
			end
		end
	end
end)
