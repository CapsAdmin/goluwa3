local objects = import("goluwa/objects/objects.lua")
local system = import("goluwa/system.lua")
local event = import("goluwa/event.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Entity = import("goluwa/entities/entity.lua")
local prefab = import("goluwa/entities/prefab.lua")
local outfit = import("lua/outfit.lua")
local visibility = import("lua/visibility.lua")
local clients = import("goluwa/network/clients.lua")
local META = objects.CreateTemplate("player_avatar")
META.Network = {
	Crouching = {"boolean", 0.1, "reliable"},
	Holding = {"boolean", 0.1, "reliable"},
	ViewRotation = {"quat", 1 / 20, "sequenced", true},
}
META:IsSet("Crouching", false)
META:IsSet("Holding", false)
META:GetSet("ViewRotation", Quat(0, 0, 0, 1))
local UNIT = import("goluwa/source_engine/units.lua").meters
local HEIGHT = 72 * UNIT
local CROUCH_HEIGHT = 36 * UNIT
local EYE_HEIGHT = 64 * UNIT
local CROUCH_EYE_HEIGHT = 28 * UNIT
local WEAPON_RAISE = 0.12
local WEAPON_FORWARD = 0.12
local HAND_SPACING = 0.22
local bone_matrix = Matrix44()

function META:Initialize()
	self.Owner:EnsureComponent("transform")
	self.crouch_alpha = 0
	self:AddGlobalEvent("Update")
end

local RELAY_FRESH = 0.3

function META:ApplyRelayedCommands(commands)
	for _, cmd in ipairs(commands) do
		if cmd.number > (self.relay_number or 0) then
			self.relay_number = cmd.number
			self.relay_cmd = cmd
			self.relay_time = system.GetTime()
		end
	end
end

event.AddListener("RemotePlayerCommands", "player_avatar", function(owner, commands)
	for _, avatar in ipairs(META.Instances or {}) do
		if avatar.Owner.network and avatar.Owner.network:GetNetworkOwner() == owner then
			avatar:ApplyRelayedCommands(commands)
		end
	end
end)

function META:OnAdd()
	local network = self.Owner.network
	local client = network and clients.GetByUniqueID(network:GetNetworkOwner()) or clients.GetLocalClient()

	if client:IsValid() then self.Owner:SetOwnedBy(client) end
end

-- the player entity stands on its origin and has an armature with the points things attach to, the look is the outfit
function META:Build()
	self.first_person = false
	self.armature = self.Owner:AddComponent("armature")
	self.armature:SetSkeleton("player")
end

function META:SetFirstPerson(first_person)
	if self.first_person == first_person then return end

	self.first_person = first_person

	if self.outfit then visibility.SetTreeVisible(self.outfit, not first_person) end
end

function META:UpdateOutfit()
	local network = self.Owner.network

	if not self.outfit_name then
		self.outfit_name = network and outfit.GetName(network:GetNetworkOwner()) or outfit.LoadLocal()
	end

	local definition = prefab.definitions[self.outfit_name]

	if not definition then return end

	if not self.outfit then
		self.outfit = Entity.New{
			Name = "outfit",
			Parent = self.Owner,
			prefab = {Path = self.outfit_name},
		}
	elseif self.outfit_revision == definition.revision then
		return
	end

	self.outfit_revision = definition.revision
	visibility.SetTreeVisible(self.outfit, not self.first_person)
end

function META:OnUpdate(dt)
	local owner = self.Owner
	local controller = owner.player_controller

	if controller then
		self:SetViewRotation(controller.cmd.view:Copy())
		self:SetCrouching(owner.player_movement:IsCrouching())
		self:SetHolding(controller:IsHolding())
	end

	if not self.armature then
		if not (CLIENT and RENDER_3D) then return end

		self:Build()
	end

	local camera = owner.camera
	local rotation

	if camera then
		rotation = owner.player_input:GetRotation()
		self:SetFirstPerson(not camera:IsThirdPerson() and camera:IsRendered())
	else
		rotation = self:GetViewRotation()
		local relay = self.relay_cmd

		if relay and system.GetTime() - self.relay_time < RELAY_FRESH then
			rotation = relay.view
			self:SetCrouching(usercmd.HasButton(relay, usercmd.BUTTON.CROUCH))
		end
	end

	self.crouch_alpha = self.crouch_alpha + (
			(
				self:IsCrouching() and
				1 or
				0
			) - self.crouch_alpha
		) * math.min(dt * 12, 1)
	local height = math.lerp(self.crouch_alpha, HEIGHT, CROUCH_HEIGHT)
	local armature = self.armature
	-- the player entity turns with the view in yaw, so the head and hands are the view relative to it, which is the pitch
	local transform = owner.transform
	local _, entity_rotation = transform:GetRenderPositionRotation()
	local pitch = (entity_rotation or transform:GetRotation()):GetConjugated() * rotation
	bone_matrix:Identity()
	bone_matrix:Scale(1, height / HEIGHT, 1)
	bone_matrix:SetTranslation(0, height * 0.5, 0)
	armature:SetBone("body", bone_matrix, "local")
	bone_matrix:Identity()
	bone_matrix:SetRotation(pitch)
	bone_matrix:SetTranslation(0, math.lerp(self.crouch_alpha, EYE_HEIGHT, CROUCH_EYE_HEIGHT), 0)
	armature:SetBone("head", bone_matrix, "local")
	local hand = Vec3(0, height * 0.5 + WEAPON_RAISE, 0) + pitch:GetForward() * WEAPON_FORWARD
	bone_matrix:SetTranslation(hand.x, hand.y, hand.z)
	armature:SetBone("hand_r", bone_matrix, "local")
	hand = hand - pitch:GetRight() * HAND_SPACING
	bone_matrix:SetTranslation(hand.x, hand.y, hand.z)
	armature:SetBone("hand_l", bone_matrix, "local")
	self:UpdateOutfit()

	for _, child in ipairs(owner:GetChildren()) do
		local weapon = child.weapon

		if weapon then
			weapon:UpdateModel(weapon:IsActive() and not (self.first_person and weapon:IsHiddenInFirstPerson()))
		end
	end
end

return META:Register()
