local objects = import("goluwa/objects/objects.lua")
local Color = import("goluwa/structs/color.lua")
local FORWARD = import("goluwa/render3d/orientation.lua").FORWARD_VECTOR
local usercmd = import("goluwa/network/usercmd.lua")
local physics = import("goluwa/physics.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local physics_beam_options = {IgnoreRigidBodies = false, IgnoreKinematicBodies = false}
local META = objects.CreateTemplate("weapon_physgun")
META:GetSet("MinHoldDistance", 1)
META:GetSet("MaxGrabDistance", 12)
META:GetSet("ScrollStep", 0.75)
META:GetSet("PositionStrength", 22)
META:GetSet("VelocityResponse", 18)
META:GetSet("MaxHoldLinearSpeed", 45)
META:GetSet("RotationStrength", 16)
META:GetSet("AngularResponse", 16)
META:GetSet("RotateSensitivity", 1)

local function clamp01(x)
	return math.min(math.max(x or 0, 0), 1)
end

local BUTTON = usercmd.BUTTON

local function get_origin(owner)
	return owner.transform:GetPosition() + owner.player_movement:GetViewOffset()
end

local function sync_body_rotation_to_transform(body)
	local owner = body and body.Owner
	local transform = owner and owner.transform

	if not transform then return end

	transform:SetRotation(body:GetRotation():Copy())
end

local function rotate_offset_relative_to_camera(offset, camera_rotation, mouse_delta)
	local target_rotation = (camera_rotation * offset):GetNormalized()
	local delta_rotation = Quat():Identity()

	if mouse_delta.x ~= 0 then
		local up = camera_rotation:GetUp()
		delta_rotation:Rotate(mouse_delta.x, up.x, up.y, up.z)
	end

	if mouse_delta.y ~= 0 then
		local right = camera_rotation:GetRight()
		delta_rotation:Rotate(mouse_delta.y, right.x, right.y, right.z)
	end

	target_rotation = (delta_rotation * target_rotation):GetNormalized()
	return (camera_rotation:GetConjugated() * target_rotation):GetNormalized()
end

local function get_angular_target(current, target, strength)
	local delta = (target * current:GetConjugated()):GetNormalized()

	if delta.w < 0 then delta = delta * -1 end

	local w = math.clamp(delta.w, -1, 1)
	local angle = 2 * math.acos(w)
	local axis_scale = math.sqrt(math.max(0, 1 - w * w))

	if angle <= 0.0001 or axis_scale <= 0.0001 then return Vec3() end

	local axis = Vec3(delta.x / axis_scale, delta.y / axis_scale, delta.z / axis_scale)
	return axis * angle * strength
end

function META:Initialize()
	self.Owner.weapon:SetDisplayName("Physgun")
	self.Owner.weapon:SetMuzzleDistance(0.64)
	self.held_body = nil
	self.held_local_point = Vec3()
	self.held_distance = self.MinHoldDistance
	self.held_rotation_offset = Quat():Identity()
	self.block_grab_until_primary_release = false
end

function META:Release()
	if self.held_body then
		if self.held_body:IsValid() then
			self.held_body:SetCollisionGroup(self.held_original_group)
		end

		if self:CanHoldBody(self.held_body) then
			sync_body_rotation_to_transform(self.held_body)
		end
	end

	self.held_body = nil
	self.held_local_point = Vec3()
	self.held_distance = self.MinHoldDistance
	self.held_rotation_offset = Quat():Identity()
end

function META:AdjustHoldDistance(delta)
	self.held_distance = math.clamp(
		(self.held_distance or self.MinHoldDistance) + delta,
		self.MinHoldDistance,
		self.MaxGrabDistance
	)
end

function META:CanHoldBody(body)
	return body and
		body.IsValid and
		body:IsValid() and
		body.IsDynamic and
		body:IsDynamic()
end

function META:CanGrabBody(body)
	return body and
		body.IsValid and
		body:IsValid() and
		body.WorldGeometry ~= true and
		not body:IsStatic()
end

function META:FreezeHeldBody()
	local body = self.held_body

	if not (body and body.IsValid and body:IsValid()) then
		self:Release()
		return
	end

	if body.SetVelocity then body:SetVelocity(Vec3()) end

	if body.SetAngularVelocity then body:SetAngularVelocity(Vec3()) end

	if body.SetMotionType then body:SetMotionType("static") end

	if body.Sleep then body:Sleep() end

	sync_body_rotation_to_transform(body)
	self.block_grab_until_primary_release = true
	self:Release()
end

function META:TryAcquireBody(cmd)
	local player = self.Owner:GetParent()
	local origin = get_origin(player)
	local movement = cmd.view:GetForward() * self.MaxGrabDistance
	local hit = physics.Sweep(
		origin,
		movement,
		0,
		player,
		function(entity)
			local body = entity and entity.rigid_body
			return self:CanGrabBody(body)
		end,
		{
			IgnoreRigidBodies = false,
			IgnoreKinematicBodies = true,
		}
	)
	local body = hit and
		(
			hit.rigid_body or
			(
				hit.collider and
				hit.collider.GetBody and
				hit.collider:GetBody()
			)
			or
			(
				hit.entity and
				hit.entity.rigid_body
			)
		)
	local grab_point = hit and (hit.point or hit.position) or nil

	if not self:CanGrabBody(body) or not grab_point then return false end

	self.held_body = body
	self.held_original_group = body:GetCollisionGroup()
	body:SetCollisionGroup(usercmd.HELD_COLLISION_GROUP)
	self.held_local_point = body:WorldToLocal(grab_point)
	self.held_distance = math.clamp(hit.distance or self.MinHoldDistance, self.MinHoldDistance, self.MaxGrabDistance)
	self.held_rotation_offset = (cmd.view:GetConjugated() * body:GetRotation()):GetNormalized()

	if body.SetGrounded then body:SetGrounded(false) end

	if body.Wake then body:Wake() end

	return true
end

function META:UpdateHeldBody(dt, cmd)
	local body = self.held_body

	if not self:CanHoldBody(body) then
		self:Release()
		return
	end

	local origin = get_origin(self.Owner:GetParent())
	local target_position = origin + cmd.view:GetForward() * self.held_distance
	local grab_position = body:LocalToWorld(self.held_local_point)
	local offset = target_position - grab_position
	local offset_length = offset:GetLength()
	local target_velocity = Vec3()

	if offset_length > 0.0001 then
		target_velocity = offset / offset_length * math.min(self.MaxHoldLinearSpeed, offset_length * self.PositionStrength)
	end

	local linear_response = clamp01(dt * self.VelocityResponse)
	local current_velocity = body:GetVelocity():Copy()
	body:SetVelocity(current_velocity + (target_velocity - current_velocity) * linear_response)
	local target_rotation = (cmd.view * self.held_rotation_offset):GetNormalized()
	body:SetRotation(target_rotation)
	body.PreviousRotation = target_rotation:Copy()
	sync_body_rotation_to_transform(body)
	body:SetAngularVelocity(Vec3())

	if body.SetGrounded then body:SetGrounded(false) end

	if body.Wake then body:Wake() end
end

local rotate_delta = {x = 0, y = 0}

function META:WeaponThink(dt, cmd)
	local controller = self.Owner:GetParent().player_controller

	if
		not (
			usercmd.HasButton(cmd, BUTTON.ACTIVE) and
			usercmd.HasButton(cmd, BUTTON.ATTACK1)
		)
	then
		if not usercmd.HasButton(cmd, BUTTON.ATTACK1) then
			self.block_grab_until_primary_release = false
		end

		self:Release()
		controller:SetHolding(false)
		return
	end

	if
		self.held_body and
		(
			cmd.rotate_x ~= 0 or
			cmd.rotate_y ~= 0
		)
		and
		self:CanHoldBody(self.held_body)
	then
		rotate_delta.x = cmd.rotate_x * self.RotateSensitivity
		rotate_delta.y = cmd.rotate_y * self.RotateSensitivity
		self.held_rotation_offset = rotate_offset_relative_to_camera(self.held_rotation_offset, cmd.view, rotate_delta)
	end

	if self.held_body and usercmd.WasPressed(cmd, BUTTON.ATTACK2) then
		self:FreezeHeldBody()
		controller:SetHolding(false)
		return
	end

	if self.block_grab_until_primary_release then return end

	if not self.held_body and not self:TryAcquireBody(cmd) then return end

	if cmd.scroll ~= 0 then self:AdjustHoldDistance(cmd.scroll * self.ScrollStep) end

	self:UpdateHeldBody(dt, cmd)
	controller:SetHolding(self.held_body ~= nil)
end

function META:WeaponGetBeamPoint()
	if self:CanHoldBody(self.held_body) then
		return self.held_body:LocalToWorld(self.held_local_point)
	end

	local player = self.Owner:GetParent()
	local cmd = player.player_controller.cmd

	if
		not (
			usercmd.HasButton(cmd, BUTTON.ACTIVE) and
			usercmd.HasButton(cmd, BUTTON.ATTACK1)
		)
	then
		return
	end

	local origin = get_origin(player)
	local movement = cmd.view:GetForward() * self.MaxGrabDistance
	local hit = physics.Sweep(origin, movement, 0, player, nil, physics_beam_options)
	return hit and (hit.point or hit.position) or origin + movement
end

function META:WeaponCreateModel()
	local shapes = import("goluwa/render3d/shapes.lua")
	local weapon = self.Owner.weapon
	local metal = shapes.Material{Color = Color(0.25, 0.27, 0.3, 1), Roughness = 0.35, Metallic = 0.8}
	local glow = shapes.Material{
		Color = Color(1, 0.55, 0.15, 1),
		Roughness = 0.6,
		Metallic = 0,
		AlbedoAlphaIsEmissive = true,
		EmissiveMultiplier = Color(1, 1, 1, 4),
	}
	weapon:AddModelBox(Vec3(0.1, 0.1, 0.36), FORWARD * 0.32, metal)
	weapon:AddModelBox(Vec3(0.12, 0.05, 0.2), FORWARD * 0.28 + Vec3(0, 0.07, 0), glow)
	weapon:AddModelBox(Vec3(0.06, 0.06, 0.1), FORWARD * 0.59, glow)
	weapon:AddModelBox(Vec3(0.06, 0.13, 0.08), FORWARD * 0.16 - Vec3(0, 0.09, 0), metal)
end

function META:WeaponHolster()
	self:Release()
	self.Owner:GetParent().player_controller:SetHolding(false)
end

function META:WeaponPlayerModeChanged()
	self:Release()
end

function META:OnRemove()
	self:Release()
end

return META:Register()
