local Entity = import("goluwa/entities/entity.lua")
local npcs = import("lua/npcs.lua")
local move_stage = {}
local PLAYER_COMPONENTS = {
	"transform",
	"player_controller",
	"character_movement",
	"character_pose",
	"attachment_points",
	"procedural_pose",
	"ragdoll",
	"weapon_holder",
	"player_avatar",
	"health",
}

function move_stage.Hold(entity)
	local body = entity.rigid_body

	if body:GetCollisionEnabled() then body:SetCollisionEnabled(false) end

	if body:GetMotionType() ~= "kinematic" then body:SetMotionType("kinematic") end
end

function move_stage.Arm(entity, set_name)
	local holder = entity.weapon_holder
	local weapon = holder and holder:FindWeapon("weapon_" .. set_name)

	if not weapon then return end

	if holder:GetWeapon("right") ~= weapon then holder:Equip(weapon, "right") end

	weapon.weapon:SetDrawn(true)
end

function move_stage.SpawnNpc(name, position, rotation)
	local npc = npcs.Spawn(name, position, 0)
	npc.ai_controller.Wander = false
	npc.character_movement:TeleportTo(position)
	npc.transform:SetRotation(rotation:Copy())
	return npc
end

function move_stage.SpawnAttacker(set_name, attacker_name, position, rotation)
	local npc_name = set_name:match("^npc_(.+)$")

	if npc_name then return move_stage.SpawnNpc(npc_name, position, rotation) end

	local attacker

	if attacker_name == "player" then
		attacker = Entity.New{
			Name = "move stage attacker",
			ComponentSet = PLAYER_COMPONENTS,
			transform = {Position = position:Copy(), Rotation = rotation:Copy()},
			player_controller = {Source = "queue"},
			player_avatar = {},
		}
	else
		attacker = move_stage.SpawnNpc(attacker_name, position, rotation)
	end

	attacker.weapon_holder:Give("weapon_" .. set_name)
	move_stage.Arm(attacker, set_name)
	return attacker
end

return move_stage
