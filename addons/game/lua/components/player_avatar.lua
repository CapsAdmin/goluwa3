local objects = import("goluwa/objects/objects.lua")
local system = import("goluwa/system.lua")
local steam = import("goluwa/steam/steam.lua")
local event = import("goluwa/event.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Entity = import("goluwa/entities/entity.lua")
local prefab = import("goluwa/entities/prefab.lua")
local outfit = import("lua/outfit.lua")
local clients = import("goluwa/network/clients.lua")
local META = objects.CreateTemplate("player_avatar")
META.Network = {
	Crouching = {"boolean", 0.1, "reliable"},
	Holding = {"boolean", 0.1, "reliable"},
	Firing = {"boolean", 0.1, "reliable"},
	BeamPoint = {"vec3", 1 / 20, "sequenced", true},
	ViewRotation = {"quat", 1 / 20, "sequenced", true},
}
META:IsSet("Crouching", false)
META:IsSet("Holding", false)
META:IsSet("Firing", false)
META:GetSet("BeamPoint", Vec3(0, 0, 0))
META:GetSet("ViewRotation", Quat(0, 0, 0, 1))
local UNIT = import("goluwa/source_engine/units.lua").meters
local RADIUS = 16 * UNIT
local HEIGHT = 72 * UNIT
local CROUCH_HEIGHT = 36 * UNIT
local EYE_ABOVE_CENTER = 28 * UNIT
local CROUCH_EYE_ABOVE_CENTER = 10 * UNIT
local FORWARD = import("goluwa/render3d/orientation.lua").FORWARD_VECTOR
local BEAM_THICKNESS = 0.03
local BEAM_ALPHA = 0.4
local WEAPON_RAISE = 0.12
local WEAPON_FORWARD = 0.12

local function rotation_between(from, to)
	local axis = from:GetCross(to)
	local w = 1 + from:GetDot(to)

	if w < 0.0001 then return QuatFromAxis(math.pi, Vec3(0, 1, 0)) end

	return Quat(axis.x, axis.y, axis.z, w):Normalize()
end

local function hash_color(str)
	local hash = 5381

	for i = 1, #str do
		hash = (hash * 33 + str:byte(i)) % 16777216
	end

	return Color.FromHSV((hash % 360) / 360, 0.75, 1)
end

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

	if client:IsValid() then
		self.client = client
		self.Owner:SetOwnedBy(client)
	end

	if CLIENT and RENDER_3D then
		self:Build(network and network:GetNetworkOwner() or "local")
	end
end

function META:Build(owner_id)
	local shapes = import("goluwa/render3d/shapes.lua")
	local color = hash_color(owner_id)
	local body_material = shapes.Material{
		Color = color,
		Roughness = 0.45,
		Metallic = 0,
	}
	local beam_material = shapes.Material{
		Color = Color(color.r, color.g, color.b, BEAM_ALPHA),
		Roughness = 0.4,
		Metallic = 0,
		Translucent = true,
	}
	self.first_person = false
	self.body = shapes.Capsule{
		Name = "player_body",
		Radius = RADIUS,
		Height = HEIGHT,
		Material = body_material,
		Collision = false,
		RigidBody = false,
		PhysicsNoCollision = true,
	}
	self.head = Entity.New{Name = "player_head", Transient = true, transform = {}}
	self.beam = shapes.Box{
		Name = "player_beam",
		Size = Vec3(BEAM_THICKNESS, BEAM_THICKNESS, 1),
		Material = beam_material,
		Collision = false,
		RigidBody = false,
		PhysicsNoCollision = true,
	}
	self.beam.visual:SetVisible(false)

	if self.client then
		self.body:SetOwnedBy(self.client)
		self.beam:SetOwnedBy(self.client)
		self.head:SetOwnedBy(self.client)
	end

	self.Owner:CallOnRemove(function()
		self.body:Remove()
		self.head:Remove()
		self.beam:Remove()
	end)
end

function META:SetFirstPerson(first_person)
	if self.first_person == first_person then return end

	self.first_person = first_person
	self.body.visual:SetVisible(not first_person)

	if self.outfit then outfit.SetVisible(self.outfit, not first_person) end
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
			Name = "player_outfit",
			Transient = true,
			Parent = self.head,
			prefab = {Path = self.outfit_name},
		}
	elseif self.outfit_revision == definition.revision then
		return
	end

	self.outfit_revision = definition.revision
	outfit.SetVisible(self.outfit, not self.first_person)
end

function META:OnUpdate(dt)
	local owner = self.Owner
	local controller = owner.player_controller

	if controller then
		self:SetViewRotation(controller.cmd.view:Copy())
		self:SetCrouching(self.Owner.player_movement:IsCrouching())
		local beam_point = owner.weapon_holder:GetBeamPoint()
		self:SetHolding(controller:IsHolding())
		self:SetFiring(beam_point ~= nil)

		if beam_point then self:SetBeamPoint(beam_point) end
	end

	if not self.body then return end

	local camera = owner.camera
	local rotation
	local eye

	if camera then
		rotation = owner.player_input:GetRotation()
		eye = camera:GetViewPosition()
		self:SetFirstPerson(not camera:IsThirdPerson())
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
	local eye_above = Vec3(0, math.lerp(self.crouch_alpha, EYE_ABOVE_CENTER, CROUCH_EYE_ABOVE_CENTER), 0)

	if not camera then eye = owner.transform:GetPosition() + eye_above end

	local position = eye - eye_above
	local squash = height / HEIGHT
	self.body.transform:SetPosition(position)
	self.body.transform:SetScale(Vec3(1, squash, 1))
	self.head.transform:SetPosition(eye)
	self.head.transform:SetRotation(rotation)
	self:UpdateOutfit()
	local muzzle
	local weapon_position = position + Vec3(0, WEAPON_RAISE, 0) + rotation:GetForward() * WEAPON_FORWARD

	for _, child in ipairs(owner:GetChildren()) do
		local weapon = child.weapon

		if weapon then
			local active = weapon:IsActive()
			weapon:UpdateModel(
				active and not (self.first_person and weapon:IsHiddenInFirstPerson()),
				weapon_position,
				rotation
			)

			if active then
				muzzle = weapon_position + rotation:GetForward() * weapon:GetMuzzleDistance()
			end
		end
	end

	local firing = self:IsFiring()

	if firing ~= self.beam_visible then
		self.beam_visible = firing
		self.beam.visual:SetVisible(firing)
	end

	if firing and muzzle then
		local offset = self:GetBeamPoint() - muzzle
		local length = offset:GetLength()

		if length > 0.01 then
			self.beam.transform:SetPosition(muzzle + offset * 0.5)
			self.beam.transform:SetRotation(rotation_between(FORWARD, offset / length))
			self.beam.transform:SetScale(Vec3(1, 1, length))
		end
	end
end

return META:Register()
