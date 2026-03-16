local prototype = import("goluwa/prototype.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local physics = import("goluwa/physics.lua")
local camera_system = library()
local META = prototype.CreateTemplate("camera")
META:GetSet("Active", false)
META:GetSet("ViewOffset", Vec3(0, 0, 0))
camera_system.active_camera = camera_system.active_camera or nil

function META:SetActive(active)
	active = not not active

	if self.Active == active then return end

	self.Active = active

	if active then
		local current = camera_system.active_camera

		if current and current ~= self and current:IsValid() then
			current.Active = false
		end

		camera_system.active_camera = self
	elseif camera_system.active_camera == self then
		camera_system.active_camera = nil
	end
end

function META:SetViewOffset(offset)
	self.ViewOffset = offset and offset:Copy() or Vec3()
end

function META:GetViewPosition()
	local transform = self.Owner and self.Owner.transform
	local body = self.Owner and self.Owner.rigid_body
	local offset = self:GetViewOffset() or Vec3()

	if not transform then return offset:Copy() end

	if body and body.ShouldInterpolateTransform and body:ShouldInterpolateTransform() then
		local alpha = physics.GetInterpolationAlpha and physics.GetInterpolationAlpha() or 0
		return body:GetInterpolatedPosition(alpha) + offset
	end

	return transform:GetPosition():Copy() + offset
end

function META:Initialize()
	self.Owner:EnsureComponent("transform")
	self:SetViewOffset(self.ViewOffset)
	self:AddGlobalEvent("Update", {priority = -100})

	if self.Active then self:SetActive(true) end
end

function META:OnUpdate()
	if not self.Active then return end

	local transform = self.Owner and self.Owner.transform

	if not transform then return end

	local look = self.Owner.player_input
	local cam = render3d.GetCamera()
	cam:SetPosition(self:GetViewPosition())

	if look and look.GetRotation then
		cam:SetRotation(look:GetRotation():Copy())
		cam:SetFOV(look:GetFOV())

		if look.GetOrthoMode then cam:SetOrthoMode(look:GetOrthoMode()) end
	else
		cam:SetRotation(transform:GetRotation():Copy())
	end
end

function META:OnRemove()
	if camera_system.active_camera == self then camera_system.active_camera = nil end
end

return META:Register()