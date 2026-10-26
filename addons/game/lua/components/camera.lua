local objects = import("goluwa/objects/objects.lua")
local View = import("goluwa/render3d/view.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local third_person = import("lua/third_person.lua")
local camera_modes = import("lua/camera_modes.lua")
local outfit = import("lua/outfit.lua")
local screen_shake = import("lua/screen_shake.lua")
local META = objects.CreateTemplate("camera")
META:GetSet("Active", false)
META:GetSet("Priority", 0)
META:GetSet("ViewOffset", Vec3(0, 0, 0))

function META:SetActive(active)
	self.Active = not not active

	if not self.view then return end

	if self.Active then self.view:Activate() else self.view:Deactivate() end
end

function META:SetPriority(priority)
	self.Priority = priority

	if self.view then self.view:SetPriority(priority) end
end

function META:SetViewOffset(offset)
	self.ViewOffset = offset and offset:Copy() or Vec3()
end

function META:GetView()
	return self.view
end

function META:IsRendered()
	return self.view:IsRendered()
end

function META:GetViewPosition()
	local transform = self.Owner and self.Owner.transform
	local offset = self:GetViewOffset() or Vec3()
	local controller = self.Owner and self.Owner.player_controller

	if controller then offset = offset + controller:GetCorrectionOffset() end

	if not transform then return offset:Copy() end

	local render_position = transform:GetRenderPositionRotation()

	if render_position then return render_position + offset end

	return transform:GetPosition():Copy() + offset
end

function META:Initialize()
	self.Owner:EnsureComponent("transform")
	self:SetViewOffset(self.ViewOffset)
	self.view = View.New{Priority = self.Priority, Ignore = self.Owner}
	self.default_near_z = self.view:GetNearZ()
	self:AddGlobalEvent("LateUpdate")
	self:SetActive(self.Active)
end

function META:OnLateUpdate(dt)
	local transform = self.Owner.transform
	local view = self.view
	local movement = self.Owner.character_movement

	if movement then self:SetViewOffset(movement:GetViewOffset()) end

	local position = self:GetViewPosition()
	local look = self.Owner.player_input

	if look then
		local rotation = look:GetRotation()
		local mode = camera_modes.GetActive()

		if mode then
			local velocity = self.Owner.rigid_body:GetVelocity()
			local fov, near_z
			position, rotation, fov, near_z = mode.Update(
				self.Owner,
				position,
				self.ViewOffset,
				rotation,
				look:GetFOV(),
				velocity,
				dt
			)
			view:SetFOV(fov)
			view:SetNearZ(near_z)
			view:SetRotation(rotation:Copy())
		elseif third_person.IsEnabled() then
			local velocity = self.Owner.rigid_body:GetVelocity()
			local fov, near_z
			position, rotation, fov, near_z = third_person.Update(
				self.Owner,
				position,
				self.ViewOffset,
				rotation,
				look:GetFOV(),
				velocity,
				dt
			)
			view:SetFOV(fov)
			view:SetNearZ(near_z)
			view:SetRotation(rotation:Copy())
		else
			camera_modes.Disable()
			third_person.Disable()
			local avatar = self.Owner.player_avatar
			local near = self.default_near_z

			if avatar and avatar:IsHeadCameraActive() then
				near = select(2, outfit.GetHeadEye())
			end

			view:SetNearZ(near)
			view:SetRotation(rotation:Copy())
			view:SetFOV(look:GetFOV())
		end
	else
		view:SetRotation(transform:GetRotation():Copy())
	end

	if
		movement and
		movement.dead and
		look and
		not third_person.IsEnabled()
		and
		not camera_modes.GetActive()
	then
		local body_position, body_rotation = transform:GetRenderPositionRotation()

		if not body_position then
			body_position, body_rotation = transform:GetPosition(), transform:GetRotation()
		end

		self.death_view = self.death_view or body_rotation:GetConjugated() * look:GetRotation()
		position = body_position + body_rotation:VecMul(self.ViewOffset)
		view:SetRotation(body_rotation * self.death_view)
	else
		self.death_view = nil
	end

	local pose = self.Owner.character_pose

	if pose and pose.viewing and not third_person.IsEnabled() and not camera_modes.GetActive() then
		local rotation = view:GetRotation():Copy()
		pose:ApplyView(rotation)
		view:SetRotation(rotation)
	end

	local shake, roll = screen_shake.Get()

	if shake then
		local rotation = view:GetRotation()
		position = position + rotation:VecMul(shake)
		view:SetRotation(rotation:Copy():RotateRoll(roll))
	end

	view:SetPosition(position:Copy())
end

function META:OnRemove()
	self.view:Remove()
end

return META:Register()
