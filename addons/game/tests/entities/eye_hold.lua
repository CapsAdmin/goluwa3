local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local biped = import("lua/biped.lua")
local eye_pose = import("lua/eye_pose.lua")
Entity.RegisterComponent("weapon", import("lua/components/weapon.lua"))
Entity.RegisterComponent("weapon_holder", import("lua/components/weapon_holder.lua"))
import("lua/weapons.lua")
import("addons/game/lua/autorun/characters.lua")

local function create()
	local owner = Entity.New{transform = {Position = Vec3(0, 0, 0)}, character_pose = {}, weapon_holder = {}}
	local bones = {}

	for _, entry in ipairs(biped.Bones) do
		bones[entry[1]] = Matrix44():Identity()
	end

	local state = eye_pose.New()

	local function tick(frames)
		for _ = 1, frames do
			owner.character_pose:OnUpdate(1 / 60)
			eye_pose.Compute(state, bones, owner, 1 / 60)
		end
	end

	local function hand()
		return Vec3(bones.hand_r.m30, bones.hand_r.m31, bones.hand_r.m32)
	end

	return owner, state, tick, hand
end

T.Test("the eye body raises its weapon hand with the hold weight and lowers it again", function()
	local owner, _, tick, hand = create()
	tick(30)
	local idle = hand()
	local weapon = owner.weapon_holder:Give("weapon_pistol")
	tick(6)
	local rising = hand()
	T(rising:Distance(idle) > 0.02)["=="](true)
	tick(60)
	local held = hand()
	T(rising:Distance(held) > 0.05)["=="](true)
	T(idle:Distance(held) > 0.3)["=="](true)
	owner.weapon_holder:Unequip(weapon)
	tick(6)
	local falling = hand()
	T(falling:Distance(held) > 0.05)["=="](true)
	T(falling:Distance(idle) > 0.05)["=="](true)
	tick(60)
	T(hand():Distance(idle) < 0.1)["=="](true)
	owner:Remove()
end)

T.Test("the eye body blends its weapon hand between two weapons", function()
	local owner, state, tick, hand = create()
	owner.weapon_holder:Give("weapon_pistol")
	tick(60)
	local first = hand()
	owner.weapon_holder:Equip(owner.weapon_holder:Give("weapon_physgun"), "right")
	tick(3)
	local middle = hand()
	T(state.sides[2].prev ~= nil)["=="](true)
	tick(60)
	local second = hand()
	T(state.sides[2].prev)["=="](nil)
	T(first:Distance(second) > 0.1)["=="](true)
	T(middle:Distance(first) > 0.005 and middle:Distance(second) > 0.05)["=="](true)
	owner:Remove()
end)

T.Test("a holster weapon is lowered until it is fired and then goes back down after two to three seconds", function()
	local owner, _, tick, hand = create()
	owner.weapon_holder:Give("weapon_pistol")
	tick(60)
	local lowered = hand()
	owner.character_pose:RegisterShot()
	tick(30)
	local raised = hand()
	T(raised.y - lowered.y > 0.1)["=="](true)
	T(owner.character_pose.ready_time > 1.4 and owner.character_pose.ready_time <= 2.5)["=="](true)
	tick(210)
	T(hand():Distance(lowered))["<"](0.02)
	owner.character_pose:RegisterShot()
	tick(1)
	local first = owner.character_pose.ready_time
	T(first >= 2 - 1 / 60 and first <= 3)["=="](true)
	owner.character_pose:RegisterShot()
	tick(1)
	T(owner.character_pose.ready_time ~= first)["=="](true)
	owner:Remove()
end)

T.Test("a weapon without the holster flag is never lowered", function()
	local owner, _, tick, hand = create()
	owner.weapon_holder:Give("weapon_physgun")
	tick(60)
	local first = hand()
	tick(300)
	T(hand():Distance(first))["<"](0.01)
	T(owner.character_pose:GetWeight("ready"))["=="](1)
	owner:Remove()
end)
