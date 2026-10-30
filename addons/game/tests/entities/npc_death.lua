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
local CREATURES = {"zombie", "headcrab", "antlion", "hunter", "zombie_torso"}

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

local function run(seconds)
	for _ = 1, seconds * 60 do
		physics.UpdateFixed(1 / 60)
	end
end

local function kill(npc)
	npc.health:TakeDamage({Damage = 1e6})
	T.WaitUntil(function()
		return #npc.source_ragdoll.bodies > 1
	end, 10)
end

local function available()
	steam.MountSourceGame("gmod")

	return vfs.IsFile("models/zombie/classic.mdl")
end

T.TestPhysics("a killed creature npc stays the same entity and becomes a ragdoll", function()
	if not available() then return T.Unavailable("gmod content not mounted") end

	local ground = create_ground()

	for _, name in ipairs(CREATURES) do
		local npc = npcs.Spawn(name, Vec3(0, 0.05, 0), 0)
		run(0.2)
		kill(npc)
		run(2)
		T(npc:IsValid())["=="](true)
		T(npc.ai_controller ~= nil)["=="](true)
		T(npc.source_ragdoll:IsDead())["=="](true)

		for _, body in ipairs(npc.source_ragdoll.bodies) do
			T(body.Position.y)[">"](-0.1)
		end

		npc:Remove()
	end

	ground:Remove()
end)

T.TestPhysics("a dead creature npc removes itself after its corpse time", function()
	if not available() then return T.Unavailable("gmod content not mounted") end

	local ground = create_ground()
	local npc = npcs.Spawn("zombie", Vec3(0, 0.05, 0), 0)
	npc.source_ragdoll:SetCorpseTime(1)
	kill(npc)
	local limb = npc.source_ragdoll.bodies[2].Owner
	run(0.5)
	T(npc:IsValid())["=="](true)
	run(1)
	T(npc:IsValid())["=="](false)
	T(limb:IsValid())["=="](false)
	ground:Remove()
end)

T.TestPhysics("reviving a dead creature npc turns the ragdoll back into the npc", function()
	if not available() then return T.Unavailable("gmod content not mounted") end

	local ground = create_ground()
	local npc = npcs.Spawn("zombie", Vec3(0, 0.05, 0), 0)
	kill(npc)
	run(1)
	local limb = npc.source_ragdoll.bodies[2].Owner
	npc.health:Revive()
	run(0.5)
	T(npc.source_ragdoll:IsDead())["=="](false)
	T(#npc.source_ragdoll.bodies)["=="](0)
	T(limb:IsValid())["=="](false)
	T(npc.character_movement.dead)["=="](false)
	kill(npc)
	T(npc.source_ragdoll:IsDead())["=="](true)
	npc:Remove()
	ground:Remove()
end)
