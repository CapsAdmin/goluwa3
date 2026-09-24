local objects = import("goluwa/objects/objects.lua")
local View = import("goluwa/render3d/view.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local physics = import("goluwa/physics.lua")
local META = objects.CreateTemplate("camera")
META:GetSet("Active", false)
META:GetSet("Priority", 0)
META:GetSet("ViewOffset", Vec3(0, 0, 0))

-- properties are applied before Initialize creates the view
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

-- whether this camera is the one being rendered, as opposed to active but
-- overridden by a view with a higher priority
function META:IsRendered()
	return self.view:IsRendered()
end

function META:GetViewPosition()
	local transform = self.Owner and self.Owner.transform
	local body = self.Owner and self.Owner.rigid_body
	local offset = self:GetViewOffset() or Vec3()

	if not transform then return offset:Copy() end

	if body and body.ShouldInterpolateTransform and body:ShouldInterpolateTransform() then
		local alpha = physics.GetInterpolationAlpha()
		return body:GetInterpolatedPosition(alpha) + offset
	end

	return transform:GetPosition():Copy() + offset
end

function META:Initialize()
	self.Owner:EnsureComponent("transform")
	self:SetViewOffset(self.ViewOffset)
	self.view = View.New{Priority = self.Priority}
	self:AddGlobalEvent("Update", {priority = -100})
	self:SetActive(self.Active)
end

function META:OnUpdate()
	local transform = self.Owner.transform
	local view = self.view
	view:SetPosition(self:GetViewPosition())
	local look = self.Owner.player_input

	if look then
		view:SetRotation(look:GetRotation():Copy())
		view:SetFOV(look:GetFOV())
	else
		view:SetRotation(transform:GetRotation():Copy())
	end
end

function META:OnRemove()
	self.view:Remove()
end

return META:Register()
