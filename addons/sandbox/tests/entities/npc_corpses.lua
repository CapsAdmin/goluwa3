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
local SourceRagdoll = import("lua/components/source_ragdoll.lua")
import("addons/sandbox/lua/autorun/npc_corpses.lua")
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

T.TestPhysics("a killed creature npc is replaced by a ragdoll corpse of its model", function()
	steam.MountSourceGame("gmod")

	if not vfs.IsFile("models/zombie/classic.mdl") then
		return T.Unavailable("gmod content not mounted")
	end

	local ground = create_ground()

	for _, name in ipairs(CREATURES) do
		local npc = npcs.Spawn(name, Vec3(0, 0.05, 0), 0)
		local model_path = npc.model.ModelPath
		npc.health:TakeDamage({Damage = 1e6})
		T(npc:IsValid())["=="](false)
		local corpse

		T.WaitUntil(
			function()
				for _, ragdoll in ipairs(SourceRagdoll.Instances or {}) do
					if ragdoll.ModelPath == model_path then
						corpse = ragdoll.Owner
						return #ragdoll.bodies > 1
					end
				end
			end,
			10
		)

		for _ = 1, 120 do
			physics.UpdateFixed(1 / 60)
		end

		for _, body in ipairs(corpse.source_ragdoll.bodies) do
			T(body.Position.y)[">"](-0.1)
		end

		corpse:Remove()
	end

	ground:Remove()
end)
