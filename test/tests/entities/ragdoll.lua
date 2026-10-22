local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local physics = import("goluwa/physics.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local biped = import("lua/biped.lua")
local damage = import("lua/damage.lua")
import("addons/game/lua/autorun/characters.lua")
Entity.RegisterComponent("player_controller", import("lua/components/player_controller.lua"))
Entity.RegisterComponent("character_movement", import("lua/components/character_movement.lua"))

local function create_ground()
	return Entity.New{
		transform = {Position = Vec3(0, -0.5, 0), Scale = Vec3(100, 1, 100)},
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
			"ragdoll",
			"health",
		},
		transform = {Position = position or Vec3(0, 0.05, 0)},
		player_controller = {Source = "queue"},
	}
	character.player_controller.cmd.mode = "walk"
	character.player_controller.cmd.buttons = usercmd.BUTTON.ACTIVE
	return character
end

local function run(character, seconds)
	for _ = 1, seconds * 60 do
		physics.UpdateFixed(1 / 60)
		character.character_pose:OnUpdate(1 / 60)
	end
end

local function sweep_at(origin_x, y)
	return damage.Sweep(Vec3(origin_x, y, 0), Vec3(-origin_x, 0, 0), nil)
end

T.TestPhysics("a character has kinematic body parts that follow its pose and are what weapons hit", function()
	create_ground()
	local character = create_character()
	run(character, 1)
	local ragdoll = character.ragdoll
	T(#ragdoll.parts)["=="](#biped.Parts)

	for _, part in ipairs(ragdoll.parts) do
		T(part.body:IsKinematic())["=="](true)
		T(part.body:GetCollisionMask())["=="](0)
	end

	local head = ragdoll.part_by_name.head.body.Position
	T(head.y > 1.1)["=="](true)
	T(head.y < 1.5)["=="](true)
	local hit = sweep_at(5, head.y)
	T(hit ~= nil)["=="](true)
	T(hit.entity.ragdoll_part.Group)["=="]("head")
	local victim, multiplier = damage.GetVictim(hit.entity)
	T(victim == character)["=="](true)
	T(multiplier)[">"](1)
	local leg = sweep_at(5, 0.2)
	T(leg.entity.ragdoll_part.Group:find("calf", 1, true) ~= nil)["=="](true)
	T(damage.Sweep(Vec3(5, head.y, 0), Vec3(-5, 0, 0), character) == nil or damage.Sweep(Vec3(5, head.y, 0), Vec3(-5, 0, 0), character).entity.ragdoll_part == nil)["=="](true)
	local own = physics.Sweep(Vec3(0, head.y, 0), Vec3(5, 0, 0), 0, character, nil, {IgnoreRigidBodies = false, IgnoreKinematicBodies = false})
	T(own == nil or own.entity.ragdoll_part == nil)["=="](true)
	local ray = physics.RayCast(Vec3(0, head.y, 0), Vec3(1, 0, 0), 5, character, nil, {IgnoreRigidBodies = false, IgnoreKinematicBodies = false})
	T(ray == nil or ray.entity == nil or ray.entity.ragdoll_part == nil)["=="](true)
	character:Remove()
	T(#physics.GetConstraints())["=="](0)
end)

T.TestPhysics("dying lets the body parts go as a ragdoll and reviving takes them back", function()
	create_ground()
	local character = create_character()
	run(character, 1)
	local ragdoll = character.ragdoll
	character.health:TakeDamage(damage.Info{Damage = 1000})
	T(ragdoll.released)["=="](true)
	T(#ragdoll.joints)["=="](#biped.Joints)

	for _, part in ipairs(ragdoll.parts) do
		T(part.body:IsDynamic())["=="](true)
		T(part.body:GetCollisionMask())["=="](-1)
	end

	run(character, 3)
	local pelvis = ragdoll.part_by_name.pelvis.body.Position
	local head = ragdoll.part_by_name.head.body.Position
	T(head:Distance(pelvis) < 1.2)["=="](true)
	T(pelvis.y < 0.5)["=="](true)
	T(math.abs(pelvis.x) < 3 and math.abs(pelvis.z) < 3)["=="](true)
	character.health:Revive()
	character.character_movement:Reset("walk")
	character.character_movement:TeleportTo(Vec3(2, 0.05, 0))
	T(ragdoll.released)["=="](false)
	T(#ragdoll.joints)["=="](0)
	run(character, 1)

	for _, part in ipairs(ragdoll.parts) do
		T(part.body:IsKinematic())["=="](true)
	end

	T(ragdoll.part_by_name.head.body.Position.y > 1.1)["=="](true)
	T(math.abs(ragdoll.part_by_name.head.body.Position.x - 2) < 0.2)["=="](true)
	character:Remove()
end)

T.TestPhysics("a ragdoll thrown at a wall comes to rest on a floor without friction instead of sliding off", function()
	create_ground()
	Entity.New{
		transform = {Position = Vec3(6, 2, 0), Scale = Vec3(1, 4, 20)},
		rigid_body = {MotionType = "static", Shape = BoxShape.New(Vec3(1, 1, 1))},
	}
	local character = create_character(Vec3(0, 1.5, 0))
	run(character, 0.5)
	character.rigid_body:SetVelocity(Vec3(10, 2, 0))

	for i = 1, 31 do
		local rotation = Quat(0, 0, 0, 1):Rotate(i * 0.07, 1, 0.5, 0.3)
		character.rigid_body:SetRotation(rotation)
		character.rigid_body.PreviousRotation = rotation:Copy()
		character.transform:SetRotation(rotation:Copy())
		character.rigid_body:SetVelocity(Vec3(10, character.rigid_body:GetVelocity().y, 0))
		run(character, 1 / 60)
	end

	character.health:TakeDamage(damage.Info{Damage = 1000})
	run(character, 3)
	local ragdoll = character.ragdoll
	local rest = ragdoll.part_by_name.pelvis.body.Position:Copy()
	run(character, 1)
	T(ragdoll.part_by_name.pelvis.body.Position:Distance(rest) < 0.05)["=="](true)

	for _, joint in ipairs(biped.Joints) do
		local parent, child = ragdoll.part_by_name[joint.Parent].body, ragdoll.part_by_name[joint.Child].body
		T(parent.Position:Distance(child.Position) < 0.6)["=="](true)
	end

	character:Remove()
end)
