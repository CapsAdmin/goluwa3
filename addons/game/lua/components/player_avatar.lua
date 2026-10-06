local objects = import("goluwa/objects/objects.lua")
local system = import("goluwa/system.lua")
local steam = import("goluwa/steam/steam.lua")
local event = import("goluwa/event.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local META = objects.CreateTemplate("player_avatar")
META.Network = {
	Crouching = {"boolean", 0.1, "reliable"},
	Holding = {"boolean", 0.1, "reliable"},
	HoldPoint = {"vec3", 1 / 20, "sequenced", true},
	ViewRotation = {"quat", 1 / 20, "sequenced", true},
}
META:IsSet("Crouching", false)
META:IsSet("Holding", false)
META:GetSet("HoldPoint", Vec3(0, 0, 0))
META:GetSet("ViewRotation", Quat(0, 0, 0, 1))
local UNIT = steam.source2meters
local RADIUS = 16 * UNIT
local HEIGHT = 72 * UNIT
local CROUCH_HEIGHT = 36 * UNIT
local EYE_ABOVE_CENTER = 28 * UNIT
local CROUCH_EYE_ABOVE_CENTER = 10 * UNIT
local MARKER_HEIGHT = 0.55
local down = QuatFromAxis(math.pi, Vec3(0, 0, 1))
local FORWARD = import("goluwa/render3d/orientation.lua").FORWARD_VECTOR
local BEAM_THICKNESS = 0.03

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
	if CLIENT and RENDER_3D then self:Build(self.Owner.network:GetNetworkOwner()) end
end

function META:Build(owner_id)
	local shapes = import("goluwa/render3d/shapes.lua")
	local color = hash_color(owner_id)
	local body_material = shapes.Material{
		Color = color,
		Roughness = 0.45,
		Metallic = 0,
	}
	local glow_material = shapes.Material{
		Color = color,
		Roughness = 0.8,
		Metallic = 0,
		AlbedoAlphaIsEmissive = true,
		EmissiveMultiplier = Color(1, 1, 1, 6),
	}
	local visor_material = shapes.Material{
		Color = Color(0.05, 0.05, 0.06, 1),
		Roughness = 0.1,
		Metallic = 0.6,
	}
	self.body = shapes.Capsule{
		Name = "player_body",
		Radius = RADIUS,
		Height = HEIGHT,
		Material = body_material,
		Collision = false,
		RigidBody = false,
	}
	self.visor = shapes.Box{
		Name = "player_visor",
		Size = Vec3(0.34, 0.1, 0.12),
		Material = visor_material,
		Collision = false,
		RigidBody = false,
	}
	self.marker = shapes.Cone{
		Name = "player_marker",
		Radius = 0.14,
		Height = 0.3,
		Material = glow_material,
	}
	self.marker.transform:SetRotation(down)
	self.beam = shapes.Box{
		Name = "player_beam",
		Size = Vec3(BEAM_THICKNESS, BEAM_THICKNESS, 1),
		Material = glow_material,
		Collision = false,
		RigidBody = false,
	}
	self.beam.visual:SetVisible(false)
	local light = self.marker:AddComponent("light_point")
	light:SetColor(color)
	light:SetLumen(150)
	light:SetRange(6)
	light:SetOcclusionMap(false)

	self.Owner:CallOnRemove(function()
		self.body:Remove()
		self.visor:Remove()
		self.marker:Remove()
		self.beam:Remove()
	end)
end

function META:OnUpdate(dt)
	local controller = self.Owner.player_controller

	if controller then
		self:SetViewRotation(controller.cmd.view:Copy())
		self:SetCrouching(self.Owner.player_movement:IsCrouching())
		local physgun = self.Owner.player_physgun
		local holding = physgun ~= nil and
			physgun.held_body ~= nil and
			physgun:CanHoldBody(physgun.held_body)
		self:SetHolding(holding)

		if holding then self:SetHoldPoint(physgun:GetHoldPoint()) end

		return
	end

	if not self.body then return end

	local transform = self.Owner.transform
	local position = transform:GetPosition()
	local rotation = self:GetViewRotation()
	local relay = self.relay_cmd

	if relay and system.GetTime() - self.relay_time < RELAY_FRESH then
		rotation = relay.view
		self:SetCrouching(usercmd.HasButton(relay, usercmd.BUTTON.CROUCH))
	end

	self.crouch_alpha = self.crouch_alpha + (
			(
				self:IsCrouching() and
				1 or
				0
			) - self.crouch_alpha
		) * math.min(dt * 12, 1)
	local height = math.lerp(self.crouch_alpha, HEIGHT, CROUCH_HEIGHT)
	local eye = position + Vec3(0, math.lerp(self.crouch_alpha, EYE_ABOVE_CENTER, CROUCH_EYE_ABOVE_CENTER), 0)
	local squash = height / HEIGHT
	self.body.transform:SetPosition(position)
	self.body.transform:SetScale(Vec3(1, squash, 1))
	self.visor.transform:SetPosition(eye + rotation:GetForward() * RADIUS * 0.9)
	self.visor.transform:SetRotation(rotation)
	local bob = math.sin(system.GetElapsedTime() * 2.5) * 0.06
	self.marker.transform:SetPosition(eye + Vec3(0, MARKER_HEIGHT + bob, 0))
	local holding = self:IsHolding()

	if holding ~= self.beam_visible then
		self.beam_visible = holding
		self.beam.visual:SetVisible(holding)
	end

	if holding then
		local origin = eye + rotation:GetForward() * 0.3 + rotation:GetRight() * 0.15 - rotation:GetUp() * 0.12
		local offset = self:GetHoldPoint() - origin
		local length = offset:GetLength()

		if length > 0.01 then
			self.beam.transform:SetPosition(origin + offset * 0.5)
			self.beam.transform:SetRotation(rotation_between(FORWARD, offset / length))
			self.beam.transform:SetScale(Vec3(1, 1, length))
		end
	end
end

return META:Register()
