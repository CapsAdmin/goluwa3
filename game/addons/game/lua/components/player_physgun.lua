local prototype = import("goluwa/prototype.lua")
local input = import("goluwa/input.lua")
local physics = import("goluwa/physics.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local META = prototype.CreateTemplate("player_physgun")
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

local function get_look_rotation_delta(state)
	local mouse_delta = (state.look_delta + state.look_nudge * state.ArrowLookSpeed) * state.MouseSensitivity
	return mouse_delta * (state.FOV / 175)
end

local function get_camera_origin(owner)
	local camera = owner and owner.camera

	if camera and camera.GetViewPosition then return camera:GetViewPosition() end

	local transform = owner and owner.transform
	return transform and transform:GetPosition():Copy() or Vec3()
end

local function sync_body_rotation_to_transform(body)
	local owner = body and body.Owner
	local transform = owner and owner.transform

	if not transform then return end

	transform:SetRotation(body:GetRotation():Copy())
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
end

function META:Release()
	if self:CanHoldBody(self.held_body) then
		sync_body_rotation_to_transform(self.held_body)
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

function META:TryAcquireBody(look)
	local origin = get_camera_origin(self.Owner)
	local movement = look:GetRotation():GetForward() * self.MaxGrabDistance
	local hit = physics.Sweep(
		origin,
		movement,
		0,
		self.Owner,
		function(entity)
			local body = entity and entity.rigid_body
			return body and body.IsDynamic and body:IsDynamic()
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

	if not self:CanHoldBody(body) or not (hit and hit.position) then return false end

	self.held_body = body
	self.held_local_point = body:WorldToLocal(hit.position)
	self.held_distance = math.clamp(hit.distance or self.MinHoldDistance, self.MinHoldDistance, self.MaxGrabDistance)
	self.held_rotation_offset = (look:GetRotation():GetConjugated() * body:GetRotation()):GetNormalized()

	if body.SetGrounded then body:SetGrounded(false) end

	if body.Wake then body:Wake() end

	return true
end

function META:UpdateHeldBody(dt, look)
	local body = self.held_body

	if not self:CanHoldBody(body) then
		self:Release()
		return
	end

	local origin = get_camera_origin(self.Owner)
	local target_position = origin + look:GetRotation():GetForward() * self.held_distance
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
	local target_rotation = (look:GetRotation() * self.held_rotation_offset):GetNormalized()
	body:SetRotation(target_rotation)
	body.PreviousRotation = target_rotation:Copy()
	sync_body_rotation_to_transform(body)
	body:SetAngularVelocity(Vec3())

	if body.SetGrounded then body:SetGrounded(false) end

	if body.Wake then body:Wake() end
end

function META:OnBeforeCameraInputUpdate(dt, state)
	if
		not state or
		not state.mouse_trapped or
		not input.IsMouseDown("button_1")
		or
		not input.IsKeyDown("e")
	then
		return
	end

	local body = self.held_body

	if not self:CanHoldBody(body) then return end

	local mouse_delta = get_look_rotation_delta(state) * self.RotateSensitivity

	if mouse_delta.x ~= 0 then
		self.held_rotation_offset:RotateYaw(mouse_delta.x)
	end

	if mouse_delta.y ~= 0 then
		self.held_rotation_offset:RotatePitch(mouse_delta.y)
	end

	self.held_rotation_offset = self.held_rotation_offset:GetNormalized()
	state.look_delta = Vec2()
	state.look_nudge = Vec2()
end

function META:OnCameraInputUpdate(dt, state)
	if not state or not state.mouse_trapped or not input.IsMouseDown("button_1") then
		self:Release()
		return
	end

	if not self.held_body and not self:TryAcquireBody(state) then return end

	if input.WasMousePressed and input.WasMousePressed("mwheel_down") then
		self:AdjustHoldDistance(self.ScrollStep)
	elseif input.WasMousePressed and input.WasMousePressed("mwheel_up") then
		self:AdjustHoldDistance(-self.ScrollStep)
	end

	self:UpdateHeldBody(dt, state)
end

function META:OnCameraModeChanged()
	self:Release()
end

function META:OnRemove()
	self:Release()
end

return META:Register()
