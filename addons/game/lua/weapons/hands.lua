local nodes = import("lua/weapon_nodes.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local SKIN = {Color = Color(0.85, 0.6, 0.45, 1), Roughness = 0.7, Metallic = 0}
return {
	Values = {
		WorldSize = Vec3(0.12, 0.05, 0.12),
		WorldCenter = Vec3(),
		Slot = 4,
		Category = "items",
		DisplayName = "Hands",
		TwoHanded = true,
		HoldFromHead = true,
		AlwaysPose = true,
		PoseArms = false,
		HoldOffset = Vec3(0.18, -0.3, -0.4),
		SupportGrip = Vec3(-0.36, 0, 0),
	},
	Nodes = {
		nodes.Box("palm", Vec3(0.02, 0.02, 0.02), Vec3(), SKIN),
	},
	Source = [=====[
local objects = import("goluwa/objects/objects.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local physics = import("goluwa/physics.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local META = objects.CreateTemplate("weapon_hands")
META:GetSet("Range", 3)
META:GetSet("MaxHalfWidth", 0.4)
META:GetSet("MaxHalfDepth", 0.6)
META:GetSet("MaxHalfHeight", 0.6)
META:GetSet("NearGap", 0.02)
META:GetSet("HandDepth", 0.06)
META:GetSet("CarryHeight", -0.3)
META:GetSet("PositionStrength", 30)
META:GetSet("VelocityResponse", 24)
META:GetSet("MaxHoldLinearSpeed", 30)
META:GetSet("RotationStrength", 24)
META:GetSet("AngularResponse", 32)
META:GetSet("ThrowSpeed", 6)
META:GetSet("ThrowTime", 0.12)
META:GetSet("ThrowReach", 0.45)
local BUTTON = usercmd.BUTTON
local AIM_OPTIONS = {IgnoreRigidBodies = false, IgnoreKinematicBodies = false}
local SNAP = math.pi / 2

local function get_angular_target(current, target, strength)
	local delta = (target * current:GetConjugated()):GetNormalized()

	if delta.w < 0 then delta = delta * -1 end

	local w = math.clamp(delta.w, -1, 1)
	local angle = 2 * math.acos(w)
	local axis_scale = math.sqrt(math.max(0, 1 - w * w))

	if angle <= 0.0001 or axis_scale <= 0.0001 then return Vec3() end

	return Vec3(delta.x / axis_scale, delta.y / axis_scale, delta.z / axis_scale) * angle * strength
end

function META:Initialize()
	self.held_body = nil
	self.throw_left = 0
end

function META:Release(velocity)
	self:DropBody(velocity)
	self.Owner.weapon:SetPoseArms(false)
end

function META:DropBody(velocity)
	local body = self.held_body
	self.held_body = nil
	self.held_entity = nil
	self.throw_left = 0

	if body and body:IsValid() then
		body:SetCollisionGroup(self.held_original_group)
		body:SetGravityScale(1)
		body:SetVelocity(velocity or Vec3())
		body:SetAngularVelocity(Vec3())
		body:Wake()
	end
end

function META:CanHoldBody(body)
	return body and body.IsValid and body:IsValid() and body.IsDynamic and body:IsDynamic()
end

function META:TryAcquireBody(cmd)
	local player = self.Owner:GetParent()
	local origin = player.transform:GetPosition() + player.character_movement:GetViewOffset()
	local hit = physics.Sweep(
		origin,
		cmd.aim:GetForward() * self.Range,
		0,
		player,
		function(entity)
			local body = entity and entity.rigid_body

			return body and
				body.WorldGeometry ~= true and
				body:IsDynamic() and
				not entity.ragdoll and
				not entity.ragdoll_part
		end,
		AIM_OPTIONS
	)
	local entity = hit and hit.entity
	local body = entity and entity.rigid_body

	if not self:CanHoldBody(body) then return false end

	local relative = (cmd.aim:GetConjugated() * body:GetRotation()):GetNormalized()
	local angles = relative:GetAngles()
	angles.x = math.round(angles.x / SNAP) * SNAP
	angles.y = math.round(angles.y / SNAP) * SNAP
	angles.z = math.round(angles.z / SNAP) * SNAP
	relative = Quat():SetAngles(angles)
	local half = body:GetHalfExtents()
	local x_axis, y_axis, z_axis = relative:GetRight(), relative:GetUp(), relative:GetForward()
	local half_width = half.x * math.abs(x_axis.x) + half.y * math.abs(y_axis.x) + half.z * math.abs(z_axis.x)
	local half_height = half.x * math.abs(x_axis.y) + half.y * math.abs(y_axis.y) + half.z * math.abs(z_axis.y)
	local half_depth = half.x * math.abs(x_axis.z) + half.y * math.abs(y_axis.z) + half.z * math.abs(z_axis.z)

	if
		half_width > self.MaxHalfWidth or
		half_depth > self.MaxHalfDepth or
		half_height > self.MaxHalfHeight
	then
		return false
	end

	self.held_body = body
	self.held_entity = entity
	self.held_filter = function(candidate)
		return candidate == entity
	end
	self.held_original_group = body:GetCollisionGroup()
	body:SetCollisionGroup(usercmd.HELD_COLLISION_GROUP)
	body:SetGravityScale(0)
	self.held_rotation_offset = relative
	self.held_half_width = half_width
	self.held_half_depth = half_depth
	self.throw_left = 0
	self.Owner.weapon:SetPoseArms(true)

	if body.SetGrounded then body:SetGrounded(false) end

	body:Wake()
	return true
end

function META:PlaceHands(player, view, eye)
	local body = self.held_body
	local half_width = self.held_half_width
	local hand_back = self.held_half_depth - math.min(self.held_half_depth, self.HandDepth)
	local level = body:GetPosition() - view:GetForward() * hand_back
	local right = view:GetRight()
	local reach = half_width + 0.3
	local to_local = view:GetConjugated()
	local right_hit = physics.Sweep(level + right * reach, right * (-2 * reach), 0, player, self.held_filter, AIM_OPTIONS)
	local left_hit = physics.Sweep(level - right * reach, right * (2 * reach), 0, player, self.held_filter, AIM_OPTIONS)
	local center = to_local:VecMul(level - eye)
	local right_x = right_hit and to_local:VecMul(right_hit.point - eye).x or center.x + half_width
	local left_x = left_hit and to_local:VecMul(left_hit.point - eye).x or center.x - half_width
	local weapon = self.Owner.weapon
	weapon:SetHoldOffset(Vec3(right_x, center.y, center.z))
	weapon:SetSupportGrip(Vec3(left_x - right_x, 0, 0))
end

function META:UpdateHeldBody(dt, cmd)
	local body = self.held_body

	if not self:CanHoldBody(body) then
		self:Release()
		return
	end

	local player = self.Owner:GetParent()
	local view = cmd.aim
	local eye = player.transform:GetPosition() + player.character_movement:GetViewOffset()
	local extra = 0

	if self.throw_left > 0 then
		self.throw_left = self.throw_left - dt
		extra = self.ThrowReach * (1 - math.max(self.throw_left, 0) / self.ThrowTime)

		if self.throw_left <= 0 then
			local velocity = cmd.aim:GetForward() * self.ThrowSpeed

			if player.rigid_body then velocity = velocity + player.rigid_body:GetVelocity() end

			self:Release(velocity)
			return
		end
	end

	local target = eye + view:VecMul(Vec3(0, self.CarryHeight, -(player.character_movement:GetRadius() + self.NearGap + self.held_half_depth + extra)))
	local offset = target - body:GetPosition()
	local length = offset:GetLength()
	local target_velocity = Vec3()

	if length > 0.0001 then
		target_velocity = offset / length * math.min(self.MaxHoldLinearSpeed, length * self.PositionStrength)
	end

	local velocity = body:GetVelocity():Copy()
	body:SetVelocity(velocity + (target_velocity - velocity) * math.min(dt * self.VelocityResponse, 1))
	local target_angular = get_angular_target(
		body:GetRotation(),
		(view * self.held_rotation_offset):GetNormalized(),
		self.RotationStrength
	)
	local angular = body:GetAngularVelocity():Copy()
	body:SetAngularVelocity(angular + (target_angular - angular) * math.min(dt * self.AngularResponse, 1))

	if body.SetGrounded then body:SetGrounded(false) end

	body:Wake()
	self:PlaceHands(player, view, eye)
end

function META:OnWeaponThink(dt, cmd)
	if not usercmd.HasButton(cmd, BUTTON.ACTIVE) then return end

	local weapon = self.Owner.weapon

	if self.held_body then
		if weapon:WasSecondaryPressed(cmd) then
			self:Release()
			return
		end

		if weapon:WasPrimaryPressed(cmd) and self.throw_left <= 0 then
			self.throw_left = self.ThrowTime
		end

		self:UpdateHeldBody(dt, cmd)
	elseif weapon:WasPrimaryPressed(cmd) then
		self:TryAcquireBody(cmd)
	end
end

function META:OnWeaponHolster()
	self:Release()
end

function META:OnWeaponCharacterModeChanged()
	self:Release()
end

function META:OnRemove()
	self:DropBody()
end

return META:Register()
]=====],
}
