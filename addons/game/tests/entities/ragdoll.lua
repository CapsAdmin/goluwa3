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
Entity.RegisterComponent("weapon", import("lua/components/weapon.lua"))
Entity.RegisterComponent("weapon_holder", import("lua/components/weapon_holder.lua"))
import("lua/weapons.lua")

local function create_ground()
	return Entity.New{
		transform = {Position = Vec3(0, -0.5, 0), Scale = Vec3(100, 1, 100)},
		rigid_body = {MotionType = "static", Shape = BoxShape.New(Vec3(1, 1, 1)), Friction = 0.85},
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

local function run(character, seconds, forward)
	for _ = 1, seconds * 60 do
		character.player_controller.starved = 0
		character.player_controller.cmd.forward = forward or 0
		physics.UpdateFixed(1 / 60)
		character.character_pose:OnUpdate(1 / 60)
	end
end

local function sweep_at(origin_x, y)
	return damage.Sweep(Vec3(origin_x, y, 0), Vec3(-origin_x, 0, 0), nil)
end

T.TestPhysics("the body parts of a character add up to the weight of the standing character", function()
	create_ground()
	local character = create_character()
	run(character, 0.2)
	local sum = 0

	for _, part in ipairs(character.ragdoll.parts) do
		sum = sum + part.body.Mass
	end

	T(math.abs(sum - import("lua/components/character_movement.lua").BodyMass))["<"](0.001)
	T(math.abs(character.ragdoll.total_mass - sum))["<"](0.001)
	character:Remove()
end)

T.TestPhysics("a character has kinematic body parts that follow its pose and are what weapons hit", function()
	create_ground()
	local character = create_character()
	run(character, 1)
	local ragdoll = character.ragdoll
	T(#ragdoll.parts)["=="](#biped.Profiles.humanoid.Parts)

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
	T(
		damage.Sweep(Vec3(5, head.y, 0), Vec3(-5, 0, 0), character) == nil or
			damage.Sweep(Vec3(5, head.y, 0), Vec3(-5, 0, 0), character).entity.ragdoll_part == nil
	)["=="](true)
	local own = physics.Sweep(
		Vec3(0, head.y, 0),
		Vec3(5, 0, 0),
		0,
		character,
		nil,
		{IgnoreRigidBodies = false, IgnoreKinematicBodies = false}
	)
	T(own == nil or own.entity.ragdoll_part == nil)["=="](true)
	local ray = physics.RayCast(
		Vec3(0, head.y, 0),
		Vec3(1, 0, 0),
		5,
		character,
		nil,
		{IgnoreRigidBodies = false, IgnoreKinematicBodies = false}
	)
	T(ray == nil or ray.entity == nil or ray.entity.ragdoll_part == nil)["=="](true)
	character:Remove()
	T(#physics.GetConstraints())["=="](0)
end)

T.TestPhysics("a cheap corpse has no muscle springs or forced ccd and only touches static bodies", function()
	create_ground()
	local character = create_character()
	character.ragdoll:SetCheapCorpse(true)
	run(character, 1)
	character.health:TakeDamage(damage.Info{Damage = 1000})
	run(character, 3)

	for _, part in ipairs(character.ragdoll.parts) do
		T(part.body:IsDynamic())["=="](true)
		T(part.body:GetCCD())["=="](false)
		T(part.body.SleepLinearThreshold)["=="](character.ragdoll.CheapSleepThreshold)
		T(part.body:GetCollideWorldOnly())["=="](true)
		T(
			part.joint == nil or
				part.joint.NeutralAngle == nil and
				part.joint.NeutralAngles == nil
		)["=="](true)
	end

	T(character.ragdoll.parts[1].body.Position.y < 0.5)["=="](true)
	character:Remove()
end)

T.TestPhysics("a cheap corpse turns static once it sleeps and is dynamic again when revived", function()
	create_ground()
	local character = create_character()
	character.ragdoll:SetCheapCorpse(true)
	run(character, 1)
	character.health:TakeDamage(damage.Info{Damage = 1000})
	run(character, 10)
	T(character.ragdoll.corpse_static)["=="](true)

	for _, part in ipairs(character.ragdoll.parts) do
		T(part.body:IsStatic())["=="](true)
	end

	character.health:Revive()
	character.character_movement:Reset("walk")
	character.character_movement:TeleportTo(Vec3(2, 0.05, 0))
	run(character, 1)
	T(character.ragdoll.corpse_static)["=="](false)

	for _, part in ipairs(character.ragdoll.parts) do
		T(part.body:IsStatic())["=="](false)
	end

	character:Remove()
end)

T.TestPhysics("dying lets the body parts go as a ragdoll and reviving takes them back", function()
	create_ground()
	local character = create_character()
	run(character, 1)
	local ragdoll = character.ragdoll
	character.health:TakeDamage(damage.Info{Damage = 1000})
	T(ragdoll.global_active)["=="](true)
	T(#ragdoll:GetJoints())["=="](#biped.Profiles.humanoid.Joints)

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
	T(ragdoll.global_active)["=="](false)
	T(#ragdoll:GetJoints())["=="](0)
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

	for _, joint in ipairs(biped.Profiles.humanoid.Joints) do
		local parent, child = ragdoll.part_by_name[joint.Parent].body, ragdoll.part_by_name[joint.Child].body
		T(parent.Position:Distance(child.Position) < 0.6)["=="](true)
	end

	character:Remove()
end)

T.TestPhysics("a held limb puts the character in a limp ragdoll that stands back up when let go", function()
	create_ground()
	local character = create_character()
	run(character, 1)
	local ragdoll = character.ragdoll
	local hand = ragdoll.part_by_name.forearm_r.body
	ragdoll:Grab(hand)
	T(ragdoll.Limp)["=="](true)
	T(#ragdoll:GetJoints())["=="](#biped.Profiles.humanoid.Joints)
	T(character.health:IsDead())["=="](false)

	for _, part in ipairs(ragdoll.parts) do
		T(part.body:IsDynamic())["=="](true)
	end

	local pelvis = ragdoll.part_by_name.pelvis.body

	for _ = 1, 60 do
		hand:SetVelocity(Vec3(0, 1.5, 0))
		run(character, 1 / 60, 1)
	end

	T(pelvis.Position.y > 1)["=="](true)
	T(math.abs(pelvis.Position.z) < 0.3)["=="](true)
	T(ragdoll.part_by_name.head.body.Position:Distance(pelvis.Position) < 0.9)["=="](true)
	ragdoll:Ungrab(hand)
	T(ragdoll.Limp)["=="](true)
	run(character, 0.9)
	T(ragdoll.global_active)["=="](true)
	T(character.rigid_body:IsDynamic())["=="](false)
	run(character, 5)
	T(ragdoll.global_active)["=="](false)
	T(ragdoll.Limp)["=="](false)
	run(character, 1)
	T(ragdoll:HasLimp())["=="](false)

	for _, part in ipairs(ragdoll.parts) do
		T(part.body:IsKinematic())["=="](true)
	end

	T(#ragdoll:GetJoints())["=="](0)
	T(ragdoll.part_by_name.head.body.Position.y > 1.1)["=="](true)
	T(character.rigid_body:IsDynamic())["=="](true)
	local before = character.transform:GetPosition():Copy()
	run(character, 1, 1)
	T(character.transform:GetPosition():Distance(before) > 0.5)["=="](true)
	character:Remove()
end)

T.TestPhysics("a knockdown throws a living character as a ragdoll that stands back up and knocks down whoever it hits", function()
	create_ground()
	local character = create_character()
	local bystander = create_character(Vec3(0, 0.05, -1.2))
	run(character, 1)
	run(bystander, 0.1)
	local ragdoll = character.ragdoll
	ragdoll:Knockdown(Vec3(0, 3, -7))
	run(character, 0.1)
	T(ragdoll.Limp)["=="](true)
	T(character.health:IsDead())["=="](false)
	run(character, 0.5)
	T(bystander.ragdoll.Limp)["=="](true)
	T(character.transform:GetPosition().z < -0.3)["=="](true)
	run(character, 8)
	T(ragdoll.Limp)["=="](false)
	T(bystander.ragdoll.Limp)["=="](false)
	character:Remove()
	bystander:Remove()
end)

T.TestPhysics("a thrown body trails its arms and legs straight out behind its travel and stops once it has stood up", function()
	create_ground()
	local character = create_character()
	run(character, 1)
	local ragdoll = character.ragdoll
	ragdoll:Knockdown(Vec3(0, 3, -7))
	run(character, 0.3)
	local back = ragdoll.parts[1].body.Velocity:GetNormalized() * -1

	for _, name in ipairs{"upperarm_r", "forearm_l", "thigh_r", "calf_l"} do
		local axis = ragdoll.part_by_name[name].body.Rotation:VecMul(Vec3(0, 1, 0))
		T(axis:Dot(back) > 0.65)["=="](true)
	end

	T(ragdoll.fling > 0.9)["=="](true)
	run(character, 8)
	T(ragdoll.Limp)["=="](false)
	T(ragdoll.fling)["=="](0)
	character:Remove()
end)

T.TestPhysics("a killed body flings its arms and legs away from the blow for two seconds and then lets them hang", function()
	create_ground()
	local character = create_character()
	run(character, 1)
	local ragdoll = character.ragdoll
	character.health:TakeDamage(
		damage.Info{
			Damage = 5000,
			Part = "torso",
			Force = Vec3(0, 0, -6),
			Position = ragdoll.part_by_name.torso.body.Position:Copy(),
		}
	)
	run(character, 0.4)
	T(character.health:IsDead())["=="](true)
	T(ragdoll.fling > 0.9)["=="](true)
	local back = ragdoll.fling_direction

	for _, name in ipairs{"forearm_r", "calf_l"} do
		local axis = ragdoll.part_by_name[name].body.Rotation:VecMul(Vec3(0, 1, 0))
		T(axis:Dot(back) > 0.3)["=="](true)
	end

	run(character, 2.5)
	T(ragdoll.fling)["=="](0)
	character:Remove()
end)

T.TestPhysics("a killed body comes to rest instead of spinning on", function()
	create_ground()
	local character = create_character()
	run(character, 1)
	local ragdoll = character.ragdoll
	character.health:TakeDamage(
		damage.Info{
			Damage = 5000,
			Part = "torso",
			Force = Vec3(0, 2, -9),
			Position = ragdoll.part_by_name.torso.body.Position:Copy(),
		}
	)
	run(character, 7)
	local speed, spin = 0, 0

	for _, part in ipairs(ragdoll.parts) do
		speed = math.max(speed, part.body.Velocity:GetLength())
		spin = math.max(spin, part.body.AngularVelocity:GetLength())
	end

	T(speed < 0.1)["=="](true)
	T(spin < 0.2)["=="](true)
	character:Remove()
end)

T.TestPhysics("a physgun grabs the limb it points at and a dead body stays a ragdoll when let go", function()
	create_ground()
	local target = create_character(Vec3(0, 0.05, -3))
	run(target, 1)
	local holder = Entity.New{
		ComponentSet = {
			"transform",
			"player_controller",
			"character_movement",
			"character_pose",
			"weapon_holder",
			"health",
		},
		transform = {Position = Vec3(0, 0.05, 0)},
		player_controller = {Source = "queue"},
	}
	holder.player_controller.cmd.mode = "walk"
	local physgun = holder.weapon_holder:Give("weapon_physgun")
	holder.weapon_holder:Equip(physgun, "right")
	physgun.weapon.Think = function() end
	local cmd = usercmd.New()
	cmd.buttons = usercmd.BUTTON.ACTIVE + usercmd.BUTTON.ATTACK1

	for _ = 1, 20 do
		physics.UpdateFixed(1 / 60)
		target.character_pose:OnUpdate(1 / 60)
		physgun.weapon_physgun:OnWeaponThink(1 / 60, cmd)
	end

	local held = physgun.weapon_physgun.held_body
	T(held ~= nil and held.Owner.ragdoll_part ~= nil)["=="](true)
	T(target.ragdoll.Limp)["=="](true)
	target.health:TakeDamage(damage.Info{Damage = 1000})
	cmd.buttons = usercmd.BUTTON.ACTIVE
	physgun.weapon_physgun:OnWeaponThink(1 / 60, cmd)
	run(target, 1)
	T(target.ragdoll.global_active)["=="](true)
	T(target.ragdoll.blend == nil)["=="](true)
	target:Remove()
	holder:Remove()
end)

T.TestPhysics("a physgun freezes only the held limb, grabbing or reload thaws it", function()
	create_ground()
	local target = create_character(Vec3(0, 0.05, -3))
	run(target, 1)
	local holder = Entity.New{
		ComponentSet = {
			"transform",
			"player_controller",
			"character_movement",
			"character_pose",
			"weapon_holder",
			"health",
		},
		transform = {Position = Vec3(0, 0.05, 0)},
		player_controller = {Source = "queue"},
	}
	holder.player_controller.cmd.mode = "walk"
	local physgun = holder.weapon_holder:Give("weapon_physgun")
	holder.weapon_holder:Equip(physgun, "right")
	physgun.weapon.Think = function() end
	local cmd = usercmd.New()
	cmd.buttons = usercmd.BUTTON.ACTIVE + usercmd.BUTTON.ATTACK1

	for _ = 1, 20 do
		physics.UpdateFixed(1 / 60)
		target.character_pose:OnUpdate(1 / 60)
		physgun.weapon_physgun:OnWeaponThink(1 / 60, cmd)
	end

	local ragdoll = target.ragdoll
	local held = physgun.weapon_physgun.held_body
	T(held ~= nil)["=="](true)
	cmd.buttons = usercmd.BUTTON.ACTIVE + usercmd.BUTTON.ATTACK1 + usercmd.BUTTON.ATTACK2
	cmd.pressed = usercmd.BUTTON.ATTACK2
	physgun.weapon_physgun:OnWeaponThink(1 / 60, cmd)
	cmd.buttons = usercmd.BUTTON.ACTIVE
	cmd.pressed = 0
	physgun.weapon_physgun:OnWeaponThink(1 / 60, cmd)
	T(held:IsStatic())["=="](true)
	local other

	for _, part in ipairs(ragdoll.parts) do
		if part.body ~= held and part.dynamic then other = part.body end
	end

	T(other:IsDynamic())["=="](true)
	local position = held.Position:Copy()
	run(target, 3)
	T(held:IsStatic())["=="](true)
	T(held.Position:Distance(position) < 0.001)["=="](true)
	T(ragdoll.global_active)["=="](true)
	cmd.buttons = usercmd.BUTTON.ACTIVE + usercmd.BUTTON.ATTACK1

	for _ = 1, 3 do
		physics.UpdateFixed(1 / 60)
		physgun.weapon_physgun:OnWeaponThink(1 / 60, cmd)
	end

	T(physgun.weapon_physgun.held_body ~= nil)["=="](true)
	T(held:IsStatic())["=="](false)
	T(ragdoll.frozen_count)["=="](0)
	cmd.buttons = usercmd.BUTTON.ACTIVE + usercmd.BUTTON.ATTACK1 + usercmd.BUTTON.ATTACK2
	cmd.pressed = usercmd.BUTTON.ATTACK2
	physgun.weapon_physgun:OnWeaponThink(1 / 60, cmd)
	cmd.buttons = usercmd.BUTTON.ACTIVE + usercmd.BUTTON.RELOAD
	cmd.pressed = usercmd.BUTTON.RELOAD
	physgun.weapon_physgun:OnWeaponThink(1 / 60, cmd)
	T(ragdoll.frozen_count)["=="](0)
	T(held:IsDynamic())["=="](true)
	target:Remove()
	holder:Remove()
end)

T.TestPhysics("a limp character still takes fall damage", function()
	create_ground()
	local character = create_character(Vec3(0, 8, 0))
	run(character, 0.1)
	local ragdoll = character.ragdoll
	local hand = ragdoll.part_by_name.forearm_r.body
	ragdoll:Grab(hand)
	ragdoll:Ungrab(hand)
	local health = character.health.Health
	run(character, 2)
	T(character.health.Health < health)["=="](true)
	character:Remove()
end)

T.TestPhysics("elbows bend forward and knees backward in a ragdoll", function()
	local character = create_character(Vec3(0, 50, 0))
	run(character, 0.1)
	local ragdoll = character.ragdoll
	character.health:TakeDamage(damage.Info{Damage = 1000})

	for _, part in ipairs(ragdoll.parts) do
		part.body:SetGravityScale(0)
		part.body:SetVelocity(Vec3())
		part.body:SetAngularVelocity(Vec3())
	end

	local forearm, calf = ragdoll.part_by_name.forearm_l.body, ragdoll.part_by_name.calf_l.body

	for _ = 1, 20 do
		forearm:SetAngularVelocity(Vec3(3, 0, 0))
		calf:SetAngularVelocity(Vec3(3, 0, 0))
		physics.UpdateFixed(1 / 60)
	end

	for _, joint in ipairs(ragdoll:GetJoints()) do
		if joint.Body1 == forearm then T(joint.Angle > 0.2)["=="](true) end

		if joint.Body1 == calf then T(joint.Angle < 0.1)["=="](true) end
	end

	character:Remove()
end)

T.TestPhysics("a shot arm goes limp for a while with its child parts while the rest of the body carries on", function()
	create_ground()
	local character = create_character()
	run(character, 1)
	local ragdoll = character.ragdoll
	ragdoll:SetHitLimp(true)
	local arm = ragdoll.part_by_name.upperarm_r
	character.health:TakeDamage(
		damage.Info{
			Damage = 5,
			Part = "upperarm_r",
			Force = Vec3(0, 0, -6),
			Position = arm.body.Position:Copy(),
		}
	)
	run(character, 0.2, 1)
	T(arm.dynamic)["=="](true)
	T(ragdoll.part_by_name.forearm_r.dynamic)["=="](true)
	T(ragdoll.part_by_name.torso.dynamic)["=="](false)
	T(ragdoll.part_by_name.forearm_l.dynamic)["=="](false)
	T(ragdoll.Limp)["=="](false)
	T(ragdoll:GetPartLimp("forearm_r") > 0.5)["=="](true)
	T(#ragdoll:GetJoints())["=="](2)
	local before = character.transform:GetPosition():Copy()
	run(character, 0.5, 1)
	T(character.transform:GetPosition():Distance(before) > 0.3)["=="](true)
	local torso = ragdoll.part_by_name.torso.body.Position
	T(arm.body.Position:Distance(torso) < 0.6)["=="](true)
	run(character, 2.5, 1)
	T(arm.dynamic)["=="](false)
	T(ragdoll.part_by_name.forearm_r.dynamic)["=="](false)
	T(ragdoll:HasLimp())["=="](false)
	T(#ragdoll:GetJoints())["=="](0)
	T(ragdoll:GetPartLimp("forearm_r"))["=="](0)
	character:Remove()
end)

T.TestPhysics("a hit on the torso only flinches the upper body for a moment", function()
	create_ground()
	local character = create_character()
	run(character, 1)
	local ragdoll = character.ragdoll
	ragdoll:SetHitLimp(true)
	character.health:TakeDamage(
		damage.Info{
			Damage = 5,
			Part = "torso",
			Force = Vec3(0, 0, -6),
			Position = ragdoll.part_by_name.torso.body.Position:Copy(),
		}
	)
	run(character, 0.1, 1)
	T(ragdoll.part_by_name.torso.dynamic)["=="](true)
	T(ragdoll.part_by_name.head.dynamic)["=="](true)
	T(ragdoll.part_by_name.pelvis.dynamic)["=="](false)
	T(ragdoll.part_by_name.thigh_l.dynamic)["=="](false)
	run(character, 1.5, 1)
	T(ragdoll:HasLimp())["=="](false)
	character:Remove()
end)

T.TestPhysics("a hit does not make a part limp unless HitLimp is on", function()
	create_ground()
	local character = create_character()
	run(character, 1)
	local ragdoll = character.ragdoll
	character.health:TakeDamage(
		damage.Info{
			Damage = 1,
			Part = "upperarm_r",
			Force = Vec3(0, 0, -5),
			Position = ragdoll.part_by_name.upperarm_r.body:GetPosition():Copy(),
		}
	)
	run(character, 0.1)
	T(ragdoll:GetPartLimp("upperarm_r"))["=="](0)
	character:Remove()
end)

T.TestPhysics("walking into a corpse shoves it aside without knocking the walker down", function()
	create_ground()
	local corpse = create_character(Vec3(0, 0.05, -2))
	run(corpse, 0.5)
	corpse.health:TakeDamage(damage.Info{Damage = 5000})
	run(corpse, 3)
	local position = corpse.ragdoll.parts[1].body.Position
	local player = create_character(Vec3(position.x, 0.05, position.z + 2.5))
	run(player, 0.5)

	for _ = 1, 120 do
		run(player, 1 / 60, 1)
		T(player.ragdoll.Limp)["=="](false)
	end

	T(player.transform:GetPosition().z < position.z)["=="](true)
	player:Remove()
	corpse:Remove()
end)

local function freeze_gravity(ragdoll)
	for _, part in ipairs(ragdoll.parts) do
		part.body:SetGravityScale(0)
		part.body:SetVelocity(Vec3())
		part.body:SetAngularVelocity(Vec3())
	end
end

local function get_deviation(ragdoll)
	local worst = 0

	for _, part in ipairs(ragdoll.parts) do
		if part.parent then
			local relative = part.parent.body.Rotation:GetConjugated() * part.body.Rotation
			local dot = math.abs(relative:Dot(part.neutral))
			worst = math.max(worst, 2 * math.acos(math.min(dot, 1)))
		end
	end

	return worst
end

T.TestPhysics("without gravity a limp ragdoll drifts back to its neutral pose", function()
	local character = create_character(Vec3(0, 50, 0))
	run(character, 0.1)
	local ragdoll = character.ragdoll
	local hand = ragdoll.part_by_name.forearm_r.body
	ragdoll:Grab(hand)
	freeze_gravity(ragdoll)

	for tick = 1, 30 do
		for index, part in ipairs(ragdoll.parts) do
			part.body:SetAngularVelocity(Vec3(math.sin(index + tick), math.cos(index * 2 + tick), math.sin(index * 3)) * 4)
		end

		run(character, 1 / 60)
	end

	ragdoll:Ungrab(hand)

	for _, part in ipairs(ragdoll.parts) do
		part.body:SetVelocity(Vec3())
	end

	local shaken = get_deviation(ragdoll)
	run(character, 5)
	T(shaken > 0.5)["=="](true)
	T(get_deviation(ragdoll) < 0.25)["=="](true)
	character:Remove()
end)

T.TestPhysics("a joint with its neutral on a limit rests inside the soft zone and resists more the closer it is pushed to that limit", function()
	local character = create_character(Vec3(0, 50, 0))
	run(character, 0.1)
	local ragdoll = character.ragdoll
	ragdoll:Grab(ragdoll.part_by_name.torso.body)
	freeze_gravity(ragdoll)
	local calf = ragdoll.part_by_name.calf_l
	local joint = calf.joint
	run(character, 3)
	local rest = joint:GetAngle()
	local reach = {}

	for _, push in ipairs{0.1, 0.2, 0.4, 0.8} do
		for _ = 1, 60 do
			calf.body:SetAngularVelocity(calf.body.AngularVelocity + joint.Body0.Rotation:VecMul(Vec3(-push, 0, 0)))
			run(character, 1 / 60)
		end

		reach[#reach + 1] = joint:GetAngle() - rest
		run(character, 2)
	end

	T(rest < joint.UpperAngle - 0.2)["=="](true)
	T(rest > joint.LowerAngle)["=="](true)
	T(reach[1] > 0.01)["=="](true)
	T(reach[4] < joint.UpperAngle - rest + 0.05)["=="](true)
	T(reach[2] / reach[1] > reach[4] / reach[3])["=="](true)
	character:Remove()
end)

T.TestPhysics("moving a held body around in the air does not hurt it", function()
	create_ground()
	local character = create_character(Vec3(0, 0.05, 0))
	run(character, 1)
	local ragdoll = character.ragdoll
	local hand = ragdoll.part_by_name.forearm_r.body
	ragdoll:Grab(hand)

	for _ = 1, 120 do
		hand:SetVelocity(Vec3(0, 1.5, 0))
		run(character, 1 / 60, 1)
	end

	T(ragdoll.part_by_name.pelvis.body.Position.y > 1.5)["=="](true)

	for tick = 1, 240 do
		hand:SetVelocity(Vec3(math.sin(tick / 20) * 3, 0, 0))
		run(character, 1 / 60, 1)
	end

	T(character.health.Health)["=="](character.health.MaxHealth)
	character:Remove()
end)

local function slide_distance(ground_friction)
	Entity.New{
		transform = {Position = Vec3(0, -0.5, 0), Scale = Vec3(100, 1, 100)},
		rigid_body = {
			MotionType = "static",
			Shape = BoxShape.New(Vec3(1, 1, 1)),
			Friction = ground_friction,
		},
	}
	local character = create_character(Vec3(0, 0.3, 0))
	run(character, 0.3)
	local ragdoll = character.ragdoll
	character.health:TakeDamage(damage.Info{Damage = 5000})
	run(character, 1.5)
	local start = ragdoll.parts[1].body.Position:Copy()

	for _, part in ipairs(ragdoll.parts) do
		part.body:Wake()
		part.body:SetVelocity(Vec3(5, 0, 0))
	end

	run(character, 6)
	local distance = ragdoll.parts[1].body.Position.x - start.x
	character:Remove()
	return distance
end

T.TestPhysics("a ragdoll slides far on slippery ground because its friction multiplies the ground friction", function()
	local slippery = slide_distance(0.1)
	T(slippery)[">"](6)
end)

T.TestPhysics("a ragdoll thrown along ordinary ground stops within a few meters", function()
	local ordinary = slide_distance(0.85)
	T(ordinary)[">"](1.5)
	T(ordinary)["<"](4)
end)

T.TestPhysics("a character killed while flying fast falls as one connected ragdoll", function()
	Entity.New{
		transform = {Position = Vec3(0, -0.5, 0), Scale = Vec3(1000, 1, 1000)},
		rigid_body = {MotionType = "static", Shape = BoxShape.New(Vec3(1, 1, 1)), Friction = 0.85},
	}
	local character = create_character(Vec3(0, 1, 0))

	for _ = 1, 84 do
		local cmd = character.player_controller.cmd
		cmd.mode = "fly"
		cmd.buttons = bit.bor(usercmd.BUTTON.ACTIVE, usercmd.BUTTON.SPRINT)
		cmd.forward = 1
		character.player_controller.starved = 0
		physics.UpdateFixed(1 / 60)
		character.character_pose:OnUpdate(1 / 60)
	end

	T(character.rigid_body:GetVelocity():GetLength())[">"](150)
	character.health:TakeDamage(damage.Info{Damage = 1000})
	local worst = 0

	for _ = 1, 120 do
		run(character, 1 / 60)

		for _, joint in ipairs(character.ragdoll:GetJoints()) do
			worst = math.max(worst, joint:GetAnchorError())
		end
	end

	character:Remove()
	T(worst)["<"](0.1)
end)

T.TestPhysics("a thrown victim chain knocks down bystanders but never the one who knocked it down", function()
	create_ground()
	local attacker = create_character(Vec3(0, 0.05, 0))
	local victim = create_character(Vec3(0, 0.05, -1.5))
	local bystander = create_character(Vec3(2, 0.05, 0))
	run(attacker, 0.5)
	run(bystander, 0.1)
	victim.ragdoll:Knockdown(Vec3(0, 0, 8), attacker)
	local part = victim.ragdoll.parts[1].body.Owner.ragdoll_part
	local info = {self_body = {Velocity = Vec3(0, 0, 6)}}
	part:OnCollisionEnter(attacker, info)
	T(attacker.ragdoll.thrown)["=="](nil)
	part:OnCollisionEnter(bystander, info)
	T(bystander.ragdoll.thrown)["=="](true)
	T(bystander.ragdoll.knocked_by)["=="](attacker)
end)
