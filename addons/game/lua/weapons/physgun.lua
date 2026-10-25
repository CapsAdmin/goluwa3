local nodes = import("lua/weapon_nodes.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local BODY = {Color = Color(0.3, 0.32, 0.36, 1), Roughness = 0.35, Metallic = 0.8}
local HANDLE = {Color = Color(1, 0.45, 0.05, 1), Roughness = 0.6, Metallic = 0.1}
local MUZZLE = {Color = Color(0.1, 0.35, 1, 1), Roughness = 0.3, Metallic = 0.3}
return {
	Values = {
		WorldSize = Vec3(0.07, 0.19, 0.62),
		WorldCenter = Vec3(0, 0.035, -0.26),
		Slot = 1,
		DisplayName = "Physgun",
		TwoHanded = true,
		SupportGrip = Vec3(0, 0, -0.3),
		HoldOffset = Vec3(0.09, -0.21, 0.25),
	},
	Nodes = {
		nodes.Handle("handle", 0.022, 0.12, Vec3(0, 0, 0), HANDLE),
		nodes.Handle("support_handle", 0.022, 0.12, Vec3(0, 0, -0.3), HANDLE),
		nodes.Box("body", Vec3(0.07, 0.07, 0.5), Vec3(0, 0.095, -0.2), BODY),
		nodes.Muzzle(0.035, 0.12, Vec3(0, 0.095, -0.57), MUZZLE),
	},
	Source = [=====[local objects = import("goluwa/objects/objects.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local physics = import("goluwa/physics.lua")
local Color = import("goluwa/structs/color.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local event = import("goluwa/event.lua")
local Beam = RENDER_3D and import("goluwa/render3d/beam.lua")
local META = objects.CreateTemplate("weapon_physgun")
META:GetSet("MinHoldDistance", 1)
META:GetSet("MaxGrabDistance", 12)
META:GetSet("ScrollStep", 0.75)
META:GetSet("PositionStrength", 22)
META:GetSet("VelocityResponse", 18)
META:GetSet("MaxHoldLinearSpeed", 45)
META:GetSet("RotationStrength", 24)
META:GetSet("AngularResponse", 32)
META:GetSet("RotateSensitivity", 1)
META:GetSet("SnapAngle", math.rad(45))

local function clamp01(x)
	return math.min(math.max(x or 0, 0), 1)
end

local BUTTON = usercmd.BUTTON
local BEAM_POINTS = 24
local BEAM_COLOR = Color(0.25, 0.55, 1, 1)
local beam_owners = table.weak("k")
local AIM_OPTIONS = {IgnoreRigidBodies = false, IgnoreKinematicBodies = false}

local function get_origin(owner)
	return owner.transform:GetPosition() + owner.character_movement:GetViewOffset()
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
	self.held_body = nil
	self.held_local_point = Vec3()
	self.held_distance = self.MinHoldDistance
	self.held_rotation_offset = Quat():Identity()
	self.block_grab_until_primary_release = false
	self.frozen_bodies = table.weak("k")
	self.beam_on = false
	self.beam_aim = Vec3()
	self.beam_forward = Vec3()

	if RENDER_3D then
		self.beam_points = Beam.NewPoints(BEAM_POINTS)
		self.beam_control = Vec3()
		self.beam_start = Vec3()
		self.beam_end = Vec3()
		beam_owners[self] = true
	end
end

function META:UpdateBeamAim(origin, forward)
	local hit = physics.Sweep(origin, forward * self.MaxGrabDistance, 0, self.Owner:GetParent(), nil, AIM_OPTIONS)
	local point = hit and hit.point or origin + forward * self.MaxGrabDistance
	self.beam_aim:Set(point.x, point.y, point.z)
	self.beam_forward:Set(forward.x, forward.y, forward.z)
end

function META:UpdateBeam()
	local beam = self.beam
	local body = self.held_body

	if not (self.beam_on and self.Owner.weapon:IsActive()) then
		if beam then beam:SetVisible(false) end

		return
	end

	local character = self.Owner:GetParent()
	local forward = character.character_pose.aim_rotation:GetForward()

	if body then
		self.beam_forward:Set(forward:Unpack())
	else
		local camera = character.camera
		self:UpdateBeamAim(camera and camera:GetViewPosition() or get_origin(character), forward)
	end

	local muzzle = self.Owner.weapon:GetMuzzle().transform:GetWorldPosition()
	local start = self.beam_start
	start:Set(muzzle.x, muzzle.y, muzzle.z)
	local finish = self.beam_end

	if body and body:IsValid() then
		local alpha = physics.GetInterpolationAlpha()
		local grab = body:LocalToWorld(
			self.held_local_point,
			body:GetInterpolatedPosition(alpha),
			body:GetInterpolatedRotation(alpha)
		)
		finish:Set(grab.x, grab.y, grab.z)
		local forward = self.beam_forward
		local reach = start:Distance(finish) * 0.5
		local control = self.beam_control
		control:Set(start.x + forward.x * reach, start.y + forward.y * reach, start.z + forward.z * reach)
		Beam.Quadratic(start, control, finish, self.beam_points)
	else
		finish:Set(self.beam_aim.x, self.beam_aim.y, self.beam_aim.z)
		Beam.Line(start, finish, self.beam_points)
	end

	local muzzle_transform = self.Owner.weapon:GetMuzzle().transform

	if not beam then
		beam = Beam.New{
			Parent = muzzle_transform.Owner,
			Points = BEAM_POINTS,
			Radius = 0.02,
			Material = Beam.CreateMaterial(BEAM_COLOR, 40),
		}
		self.beam = beam
	end

	local inverse = muzzle_transform:GetWorldMatrixInverse()

	for _, point in ipairs(self.beam_points) do
		point:Set(inverse:TransformVectorUnpacked(point.x, point.y, point.z))
	end

	beam:SetPoints(self.beam_points)
	beam:SetVisible(true)
end

function META:Release()
	if self.held_body then
		if self.held_body:IsValid() then
			self.held_body:SetCollisionGroup(self.held_original_group)
		end

		local character = self.held_character

		if character and character:IsValid() then character.ragdoll:Ungrab(self.held_body) end

		self.held_character = nil

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
		(
			not body:IsStatic() or
			body.Owner.ragdoll_part or
			not body.Owner:GetTransient()
		)
end

function META:FreezeHeldBody()
	local body = self.held_body

	if not (body and body.IsValid and body:IsValid()) then
		self:Release()
		return
	end

	if body.Owner.ragdoll_part then
		local ragdoll = self.held_character.ragdoll
		self.block_grab_until_primary_release = true
		self:Release()
		ragdoll:Freeze(body)
		self.frozen_bodies[body] = true
		return
	end

	if body.SetVelocity then body:SetVelocity(Vec3()) end

	if body.SetAngularVelocity then body:SetAngularVelocity(Vec3()) end

	if body.SetMotionType then body:SetMotionType("static") end

	if body.Sleep then body:Sleep() end

	sync_body_rotation_to_transform(body)
	self.frozen_bodies[body] = true
	self.block_grab_until_primary_release = true
	self:Release()
end

function META:UnfreezeAll()
	for body in pairs(self.frozen_bodies) do
		if body:IsValid() then
			local part = body.Owner.ragdoll_part

			if part then
				part.Character.ragdoll:Unfreeze(body)
			else
				body:SetMotionType("dynamic")
				body:Wake()
			end
		end
	end

	self.frozen_bodies = table.weak("k")
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

			if not self:CanGrabBody(body) then return false end

			if entity.ragdoll_part then return true end

			return not entity.ragdoll and not body:IsKinematic()
		end,
		AIM_OPTIONS
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
	local grab_point = hit and hit.point or nil

	if not self:CanGrabBody(body) or not grab_point then return false end

	local part = body.Owner.ragdoll_part

	if part then
		self.held_character = part.Character
		part.Character.ragdoll:Unfreeze(body)
		part.Character.ragdoll:Grab(body)
	elseif body:IsStatic() then
		body:SetMotionType("dynamic")
	end

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

	if not self.held_character then
		local target_rotation = (cmd.view * self.held_rotation_offset):GetNormalized()

		if usercmd.HasButton(cmd, BUTTON.SPRINT) then
			local angles = target_rotation:GetAngles()
			local step = self.SnapAngle
			angles.x = math.round(angles.x / step) * step
			angles.y = math.round(angles.y / step) * step
			angles.z = math.round(angles.z / step) * step
			target_rotation = Quat():SetAngles(angles)
		end

		local target_angular = get_angular_target(body:GetRotation(), target_rotation, self.RotationStrength)
		local current_angular = body:GetAngularVelocity():Copy()
		body:SetAngularVelocity(current_angular + (target_angular - current_angular) * clamp01(dt * self.AngularResponse))
	end

	if body.SetGrounded then body:SetGrounded(false) end

	if body.Wake then body:Wake() end
end

local rotate_delta = {x = 0, y = 0}

function META:OnWeaponThink(dt, cmd)
	local pose = self.Owner:GetParent().character_pose

	if usercmd.HasButton(cmd, BUTTON.ACTIVE) and usercmd.WasPressed(cmd, BUTTON.RELOAD) then
		self:UnfreezeAll()
	end

	if
		not (
			usercmd.HasButton(cmd, BUTTON.ACTIVE) and
			usercmd.HasButton(cmd, BUTTON.ATTACK1)
		)
	then
		if not usercmd.HasButton(cmd, BUTTON.ATTACK1) then
			self.block_grab_until_primary_release = false
		end

		self.beam_on = false
		self:Release()
		pose:SetHolding(false)
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
		self.beam_on = false
		self:FreezeHeldBody()
		pose:SetHolding(false)
		return
	end

	if self.block_grab_until_primary_release then
		self.beam_on = false
		return
	end

	self.beam_on = true
	self.beam_forward:Set(cmd.view:GetForward():Unpack())

	if not self.held_body and not self:TryAcquireBody(cmd) then
		self:UpdateBeamAim(get_origin(self.Owner:GetParent()), cmd.view:GetForward())
		return
	end

	if cmd.scroll ~= 0 then self:AdjustHoldDistance(cmd.scroll * self.ScrollStep) end

	self:UpdateHeldBody(dt, cmd)
	pose:SetHolding(self.held_body ~= nil)
end

function META:OnWeaponHolster()
	self.beam_on = false
	self:Release()
	self.Owner:GetParent().character_pose:SetHolding(false)
end

function META:OnWeaponCharacterModeChanged()
	self:Release()
end

function META:OnRemove()
	beam_owners[self] = nil

	if self.beam then self.beam:Remove() end

	self:Release()
end

if RENDER_3D then
	event.AddListener(
		"PreFrame",
		"weapon_physgun_beam",
		function()
			for physgun in pairs(beam_owners) do
				physgun:UpdateBeam()
			end
		end,
		{priority = 200}
	)
end

return META:Register()
]=====],
}
