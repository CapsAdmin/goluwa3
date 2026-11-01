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
		return npc.ragdoll.global_active
	end, 10)
end

local function available()
	steam.MountSourceGame("gmod")
	return vfs.IsFile("models/zombie/classic.mdl")
end

local function wait_for_parts(npc)
	T.WaitUntil(function()
		return npc.ragdoll.parts[1] ~= nil
	end, 10)

	npc.ragdoll:SetBoxRagdoll(false)
end

T.TestPhysics("a creature npc has hitboxes that point back at it while alive", function()
	if not available() then return T.Unavailable("gmod content not mounted") end

	local ground = create_ground()

	for _, name in ipairs(CREATURES) do
		local npc = npcs.Spawn(name, Vec3(0, 0.05, 0), 0)
		wait_for_parts(npc)
		run(0.2)
		T(#npc.ragdoll.parts)[">"](0)

		for _, part in ipairs(npc.ragdoll.parts) do
			T(part.entity.ragdoll_part.Character == npc)["=="](true)
			T(part.dynamic)["=="](false)
		end

		npc:Remove()
	end

	ground:Remove()
end)

T.TestPhysics("a killed creature npc stays the same entity, goes limp and follows its corpse", function()
	if not available() then return T.Unavailable("gmod content not mounted") end

	local ground = create_ground()

	for _, name in ipairs(CREATURES) do
		local npc = npcs.Spawn(name, Vec3(0, 0.05, 0), 0)
		wait_for_parts(npc)
		run(0.2)
		kill(npc)
		npc.ragdoll:Knockdown(Vec3(4, 1, 0))
		run(2)
		T(npc:IsValid())["=="](true)
		T(npc.ai_controller ~= nil)["=="](true)
		T(npc.ragdoll.global_active)["=="](true)
		local root = npc.ragdoll.parts[1].body.Position
		T(npc.transform:GetPosition().x)[">"](0.2)
		T((npc.transform:GetPosition() - root):GetLength())["<"](2)

		for _, part in ipairs(npc.ragdoll.parts) do
			T(part.body.Position.y)[">"](-0.1)
		end

		npc:Remove()
	end

	ground:Remove()
end)

T.TestPhysics("a dead creature npc removes itself after its corpse time", function()
	if not available() then return T.Unavailable("gmod content not mounted") end

	local ground = create_ground()
	local npc = npcs.Spawn("zombie", Vec3(0, 0.05, 0), 0)
	wait_for_parts(npc)
	npc.ragdoll:SetCorpseTime(1)
	kill(npc)
	local limb = npc.ragdoll.parts[2].entity
	run(0.5)
	T(npc:IsValid())["=="](true)
	run(1)
	T(npc:IsValid())["=="](false)
	T(limb:IsValid())["=="](false)
	ground:Remove()
end)

T.TestPhysics("reviving a dead creature npc stands it back up", function()
	if not available() then return T.Unavailable("gmod content not mounted") end

	local ground = create_ground()
	local npc = npcs.Spawn("zombie", Vec3(0, 0.05, 0), 0)
	wait_for_parts(npc)
	kill(npc)
	run(1)
	npc.health:Revive()
	run(1.5)
	T(npc.ragdoll.global_active)["=="](false)
	T(npc.character_movement.dead)["=="](false)
	T(npc.ragdoll.parts[2].dynamic)["=="](false)
	kill(npc)
	T(npc.ragdoll.global_active)["=="](true)
	npc:Remove()
	ground:Remove()
end)

T.TestPhysics("a creature with a weapon gets sockets on top of its body", function()
	local Entity = import("goluwa/entities/entity.lua")
	local entity = Entity.New{
		ComponentSet = {"transform", "character_movement", "attachment_points"},
		attachment_points = {Profile = "creature"},
	}
	entity:EnsureComponent("armature", {Skeleton = "biped"})
	local names = entity.armature:GetSocketNames()
	T(#names)[">"](0)
	local height = entity.character_movement:GetHeight()
	T(entity.armature:GetBoneMatrix("grip_r").m31)[">"](height * 0.9)
	entity:Remove()
end)

T.TestPhysics("a ragdoll finds its parts by role as well as by name", function()
	if not available() then return T.Unavailable("gmod content not mounted") end

	local ground = create_ground()

	for _, name in ipairs(CREATURES) do
		local npc = npcs.Spawn(name, Vec3(0, 0.05, 0), 0)
		wait_for_parts(npc)
		T(npc.ragdoll:FindPart("torso") ~= nil)["=="](true)
		T(npc.ragdoll:FindPart(npc.ragdoll.parts[2].definition.Name))["=="](npc.ragdoll.parts[2])
		npc:Remove()
	end

	ground:Remove()
end)

T.TestPhysics("a biped npc keeps the humanoid ragdoll profile and a creature gets the model one", function()
	if not available() then return T.Unavailable("gmod content not mounted") end

	for name, profile in pairs{citizen = "humanoid", barney = "humanoid", eye = "eye", zombie = "model"} do
		local npc = npcs.Spawn(name, Vec3(0, 0.05, 0), 0)
		T(npc.ragdoll.Profile)["=="](profile)
		npc:Remove()
	end
end)

T.TestPhysics("a dead creature npc settles instead of flailing on", function()
	if not available() then return T.Unavailable("gmod content not mounted") end

	local ground = create_ground()

	for _, name in ipairs(CREATURES) do
		local npc = npcs.Spawn(name, Vec3(0, 0.05, 0), 0)
		wait_for_parts(npc)
		run(0.5)
		kill(npc)
		run(2.5)
		local worst = 0

		for _, part in ipairs(npc.ragdoll.parts) do
			worst = math.max(worst, part.body.AngularVelocity:GetLength())
		end

		print("SETTLE", name, worst)
		T(worst)["<"](15)
		npc:Remove()
	end

	ground:Remove()
end)
