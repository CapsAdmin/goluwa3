local objects = import("goluwa/objects/objects.lua")
local event = import("goluwa/event.lua")
local Entity = import("goluwa/entities/entity.lua")
local prefab = import("goluwa/entities/prefab.lua")
local outfit = import("lua/outfit.lua")
local outfit_source = import("lua/outfit_source.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local biped = import("lua/biped.lua")
local clients = import("goluwa/network/clients.lua")
local View = import("goluwa/render3d/view.lua")
local third_person = import("lua/third_person.lua")
local camera_modes = import("lua/camera_modes.lua")
local META = objects.CreateTemplate("player_avatar")
local HEAD_MAX_LAG = 0.04
local HEAD_BONES = {biped.SourceBones.head, biped.SourceBones.neck, biped.SourceBones.chest}
local NO_BONES = {}
-- an empty Network table is what makes the component part of the spawn packet
META.Network = {}
META:GetSet("Outfit", nil)

function META:Initialize()
	self.Owner:EnsureComponent("transform")
	self.head_offset = Vec3()
	self.head_camera_active = false
	self.player_hidden = false
	self:AddGlobalEvent("Update")
end

event.AddListener("RemotePlayerCommands", "player_avatar", function(owner, commands)
	for _, avatar in ipairs(META.Instances or {}) do
		if avatar.Owner.network and avatar.Owner.network:GetNetworkOwner() == owner then
			avatar.Owner.character_pose:ApplyRelayedCommands(commands)
		end
	end
end)

event.AddListener("CreateMove", "player_avatar_head", function(owner, cmd)
	if owner.player_avatar then
		cmd.head:CopyFrom(owner.player_avatar:GetHeadOffset())
	end
end)

function META:OnAdd()
	if self.Outfit then return end

	local network = self.Owner.network
	local client = network and
		clients.GetByUniqueID(network:GetNetworkOwner()) or
		clients.GetLocalClient()

	if client:IsValid() then self.Owner:SetOwnedBy(client) end
end

function META:Build()
	self.first_person = false
	self.armature = self.Owner:AddComponent("armature")
	self.armature:SetSkeleton(biped.SkeletonName)
end

function META:SetFirstPerson(first_person)
	if self.first_person == first_person then return end

	self.first_person = first_person
	self.Owner.character_pose:SetFirstPerson(first_person)

	if self.outfit then self:ApplyFirstPerson() end
end

function META:ApplyFirstPerson()
	for _, child in ipairs(self.outfit:GetChildrenList()) do
		if child.animator then
			child.animator:SetViewHiddenBones(self.first_person and HEAD_BONES or NO_BONES)
		end
	end
end

function META:UpdateWeaponHidden()
	local holder = self.Owner.weapon_holder
	local weapon = holder and holder:GetWeapon("right")
	local hidden = self.first_person and weapon ~= nil and weapon.weapon:IsHidesPlayer()
	self.player_hidden = hidden

	if hidden then
		self.outfit.visibility:AddHider("weapon")
	else
		self.outfit.visibility:RemoveHider("weapon")
	end
end

function META:GetHeadOffset()
	return self.head_offset
end

function META:IsHeadCameraActive()
	return self.head_camera_active
end

function META:GetEyeRig()
	local outfit_entity = self.outfit

	if self.eye_rig_outfit ~= outfit_entity then
		self.eye_rig_outfit = outfit_entity
		self.eye_rig = nil
	end

	if not self.eye_rig and outfit_entity then
		for _, child in ipairs(outfit_entity:GetChildrenList()) do
			local rig = child.animator and child.animator:GetRig()

			if rig and rig.skeleton.Eyes and #rig.skeleton.Eyes > 0 then
				self.eye_rig = rig

				break
			end
		end
	end

	return self.eye_rig
end

function META:UpdateHeadOffset(dt)
	local owner = self.Owner
	local offset = self.head_offset
	local active, vertical, smoothing = outfit.GetHeadCamera()
	local ragdoll = owner.ragdoll
	active = active and
		not self.player_hidden and
		not (
			owner.character_movement and
			owner.character_movement.dead
		)
		and
		not (
			ragdoll and
			ragdoll.Limp
		)
	local x, y, z = 0, 0, 0
	local rig = active and
		owner.player_input and
		self.outfit_name == outfit_source.Name and
		self:GetEyeRig()
	self.head_camera_active = rig and true or false

	if rig then
		local movement = owner.character_movement
		local _, rotation = owner.transform:GetRenderPositionRotation()
		local eyes = rig.skeleton.Eyes
		local sum_x, sum_y, sum_z = 0, 0, 0

		for _, eye in ipairs(eyes) do
			local ex, ey, ez = rig:GetBonePosition(eye.name)
			sum_x, sum_y, sum_z = sum_x + ex, sum_y + ey, sum_z + ez
		end

		local world = (
				rotation or
				owner.transform:GetRotation()
			):VecMul(Vec3(sum_x / #eyes, sum_y / #eyes, sum_z / #eyes)) - movement:GetEyeOffset()
		x, y, z = world.x, vertical and world.y or 0, world.z
	end

	local alpha = smoothing > 0 and 1 - math.exp(-dt / smoothing) or 1
	local dx, dy, dz = x - offset.x, y - offset.y, z - offset.z
	local lag = math.sqrt(dx * dx + dy * dy + dz * dz) * (1 - alpha)

	if lag > HEAD_MAX_LAG then alpha = 1 - HEAD_MAX_LAG / (lag / (1 - alpha)) end

	offset:Set(offset.x + dx * alpha, offset.y + dy * alpha, offset.z + dz * alpha)
end

function META:ApplyViewHidden()
	local view = View.GetActive()
	local camera = self.Owner.camera
	local visibility = self.Owner:EnsureComponent("visibility")

	if camera and view and view:GetHidePlayer() and not camera:IsRendered() then
		visibility:AddHider("view")
	else
		visibility:RemoveHider("view")
	end
end

function META:UpdateOutfit()
	local network = self.Owner.network
	local name, inputs

	if self.Outfit then
		name = self.Outfit
	elseif network and not network.linked then
		name = outfit.GetName(network:GetNetworkOwner())
	else
		name, inputs = outfit.LoadLocal()
	end

	local model = inputs and inputs.Model

	if self.outfit and (self.outfit_name ~= name or self.outfit_model ~= model) then
		self.outfit:Remove()
		self.outfit = nil
	end

	local definition = prefab.definitions[name]

	if not definition then return end

	if not self.outfit then
		self.outfit = Entity.New{
			Name = "outfit",
			Parent = self.Owner,
			prefab = {Inputs = inputs, Path = name},
			visibility = {},
		}
		self.outfit_name = name
		self.outfit_model = model
	elseif self.outfit_revision == definition.revision then
		return
	end

	self.outfit_revision = definition.revision
	self:ApplyFirstPerson()
end

function META:OnUpdate(dt)
	if not self.armature then
		if not (CLIENT and RENDER_3D) then return end

		self:Build()
	end

	self:ApplyViewHidden()
	local camera = self.Owner.camera

	if camera then
		self:SetFirstPerson(camera_modes.IsFirstPerson(third_person.IsEnabled()) and camera:IsRendered())
	end

	self:UpdateOutfit()

	if self.outfit then self:UpdateWeaponHidden() end
end

return META:Register()
