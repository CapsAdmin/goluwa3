local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local physics = import("goluwa/physics.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local biped = import("lua/biped.lua")
local eye_pose = import("lua/eye_pose.lua")
local damage = import("lua/damage.lua")
Entity.RegisterComponent("character_movement", import("lua/components/character_movement.lua"))
Entity.RegisterComponent("ai_controller", import("lua/components/ai_controller.lua"))
Entity.RegisterComponent("player_avatar", import("lua/components/player_avatar.lua"))
Entity.RegisterComponent("weapon_holder", import("lua/components/weapon_holder.lua"))
Entity.RegisterComponent("weapon", import("lua/components/weapon.lua"))
import("addons/game/lua/autorun/characters.lua")
import("lua/weapons.lua")
local npcs = import("lua/npcs.lua")

local function create_ground(height)
	return Entity.New{
		transform = {Position = Vec3(0, (height or 0) - 0.5, 0), Scale = Vec3(100, 1, 100)},
		rigid_body = {MotionType = "static", Shape = BoxShape.New(Vec3(1, 1, 1))},
	}
end

local function run(npc, seconds)
	for _ = 1, seconds * 60 do
		physics.UpdateFixed(1 / 60)
		npc.character_pose:OnUpdate(1 / 60)
		npc.procedural_pose:OnUpdate(1 / 60)
	end
end

T.TestPhysics("the eye pose puts the eye at the pupil point and plants the feet on the ground", function()
	create_ground()
	local npc = npcs.Spawn("eye", Vec3(0, 0.05, 0), 0)
	npc.ai_controller:SetWander(false)
	run(npc, 1)
	local bones = npc.procedural_pose:GetBones()
	T(bones.head.m31)["~"](eye_pose.EyeHeight, 1e-3)
	T(bones.foot_l.m31)["~"](eye_pose.FootHeight - eye_pose.FootSink, 0.02)
	T(bones.foot_r.m31)["~"](eye_pose.FootHeight - eye_pose.FootSink, 0.02)
	npc:Remove()
end)

T.TestPhysics("the physics rig of an eye npc follows the eye pose and falls apart on death", function()
	create_ground()
	local npc = npcs.Spawn("eye", Vec3(0, 0.05, 0), 0)
	npc.ai_controller:SetWander(false)
	run(npc, 1)
	local ragdoll = npc.ragdoll
	local profile = biped.Profiles.eye
	T(#ragdoll.parts)["=="](#profile.Parts)
	local bones = npc.procedural_pose:GetBones()
	local head = ragdoll.part_by_name.head.body.Position
	T(head.y)["~"](bones.neck.m31, 0.02)
	local foot = ragdoll.part_by_name.calf_l.body.Position
	T(foot.y < 0.5)["=="](true)
	local hit = damage.Sweep(Vec3(5, head.y, head.z), Vec3(-5, 0, 0), nil)
	T(hit.entity.ragdoll_part.Group)["=="]("head")
	npc.health:TakeDamage(damage.Info{Damage = 1000})
	T(ragdoll.released)["=="](true)
	T(#ragdoll.joints)["=="](#profile.Joints)
	run(npc, 3)

	for _, joint in ipairs(profile.Joints) do
		local parent, child = ragdoll.part_by_name[joint.Parent].body, ragdoll.part_by_name[joint.Child].body
		T(parent.Position:Distance(child.Position) < 1.6)["=="](true)
	end

	npc:Remove()
end)
