local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local physics = import("goluwa/physics.lua")
local steam = import("goluwa/steam/steam.lua")
local vfs = import("goluwa/vfs.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
Entity.RegisterComponent("character_movement", import("lua/components/character_movement.lua"))
Entity.RegisterComponent("ai_controller", import("lua/components/ai_controller.lua"))
Entity.RegisterComponent("usable", import("lua/components/usable.lua"))
Entity.RegisterComponent("weapon_holder", import("lua/components/weapon_holder.lua"))
Entity.RegisterComponent("weapon", import("lua/components/weapon.lua"))
import("lua/weapons.lua")
import("addons/game/lua/autorun/characters.lua")
local npcs = import("lua/npcs.lua")

local function step(npc, seconds)
	for _ = 1, seconds * 60 do
		physics.UpdateFixed(1 / 60)
		npc.source_pose:OnUpdate(1 / 60)
	end
end

local function get_relative(rig, bone, parent)
	return rig:GetBone(bone):GetMultiplied(rig:GetBone(parent):GetInverse())
end

for name, bone in pairs{
	zombie = {"ValveBiped.Bip01_R_Finger1", "ValveBiped.Bip01_R_Hand"},
	barney = {"ValveBiped.Bip01_R_Finger1", "ValveBiped.Bip01_R_Hand"},
} do
	T.Test3D("a limp " .. name .. " keeps the bones that map onto no part rigid to their parent", function()
		steam.MountSourceGame("gmod")

		if not physics.instance then physics.Initialize() end

		physics.instance.SlowStepTime = math.huge

		if not vfs.IsFile("models/zombie/classic.mdl") then
			return T.Unavailable("gmod content not mounted")
		end

		local ground = Entity.New{
			transform = {Position = Vec3(0, -0.5, 0), Scale = Vec3(300, 1, 300)},
			rigid_body = {
				MotionType = "static",
				WorldGeometry = true,
				Shape = BoxShape.New(Vec3(1, 1, 1)),
			},
		}
		local npc = npcs.Spawn(name, Vec3(0, 0.05, 0), 0)
		local rig

		T.WaitUntil(
			function()
				rig = npc.animator and npc.animator:GetRig()
				return rig and npc.ragdoll.parts[1]
			end,
			30
		)

		step(npc, 0.5)
		npc.health:TakeDamage({Damage = 1e6})
		step(npc, 0.4)
		local version = npc.animator.skin_version
		step(npc, 1 / 60)
		T(npc.animator.skin_version)[">"](version)
		local first = get_relative(rig, bone[1], bone[2])
		local before = npc.ragdoll.parts[1].body.Position:Copy()
		local animated = Matrix44():Identity()
		animated:SetRotation(Quat():Identity():RotateYaw(0.8))
		rig:SetBone(bone[1], animated, "local")
		step(npc, 0.6)
		T(npc.ragdoll.parts[1].body.Position:Distance(before))[">"](0.01)
		local second = get_relative(rig, bone[1], bone[2])

		for _, key in ipairs{
			"m00",
			"m01",
			"m02",
			"m10",
			"m11",
			"m12",
			"m20",
			"m21",
			"m22",
			"m30",
			"m31",
			"m32",
		} do
			T(first[key])["~"](second[key], 0.02)
		end

		npc:Remove()
		ground:Remove()
		physics.ResetState()
	end)
end

for _, name in ipairs{"zombie", "barney"} do
	T.Test3D("a revived " .. name .. " blends from the corpse towards the standing pose", function()
		steam.MountSourceGame("gmod")

		if not vfs.IsFile("models/zombie/classic.mdl") then
			return T.Unavailable("gmod content not mounted")
		end

		if not physics.instance then physics.Initialize() end

		physics.instance.SlowStepTime = math.huge
		local ground = Entity.New{
			transform = {Position = Vec3(0, -0.5, 0), Scale = Vec3(300, 1, 300)},
			rigid_body = {
				MotionType = "static",
				WorldGeometry = true,
				Shape = BoxShape.New(Vec3(1, 1, 1)),
			},
		}
		local npc = npcs.Spawn(name, Vec3(0, 0.05, 0), 0)

		T.WaitUntil(
			function()
				return npc.animator and npc.animator:GetRig() and npc.ragdoll.parts[1]
			end,
			30
		)

		step(npc, 0.5)
		npc.health:TakeDamage({Damage = 1e6})
		step(npc, 2)
		local root = npc.ragdoll.parts[1]
		T(root.body.Position.y)["<"](0.5)
		npc.health:Revive()

		T.WaitUntil(function()
			step(npc, 1 / 60)
			return npc.ragdoll.blend ~= nil
		end, 5)

		T(root.body.Position.y)["<"](0.5)
		step(npc, 3 / 60)
		T(root.body.Position.y)["<"](0.5)
		T(root.target_position.y)[">"](0.5)
		npc:Remove()
		ground:Remove()
		physics.ResetState()
	end)
end
