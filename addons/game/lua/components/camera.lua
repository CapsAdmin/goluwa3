local objects = import("goluwa/objects/objects.lua")
local View = import("goluwa/render3d/view.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local physics = import("goluwa/physics.lua")
local pvars = import("goluwa/cli/pvars.lua")
local third_person = pvars.Setup("cl_thirdperson", false, nil, "over the shoulder camera, client side only")
local THIRD_PERSON_DISTANCE = 2.4
local THIRD_PERSON_SHOULDER = 0.55
local THIRD_PERSON_LIFT = 0.15
local THIRD_PERSON_RADIUS = 0.15
local THIRD_PERSON_MARGIN = 0.1
local TRACE_OPTIONS = {IgnoreRigidBodies = false, IgnoreKinematicBodies = true}

local function is_static_geometry(entity)
	local body = entity.rigid_body
	return body ~= nil and body:IsStatic()
end

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
	local body = self.Owner and self.Owner.rigid_body
	local offset = self:GetViewOffset() or Vec3()
	local controller = self.Owner and self.Owner.player_controller

	if controller then offset = offset + controller:GetCorrectionOffset() end

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

function META:IsThirdPerson()
	return third_person:Get()
end

function META:OnUpdate()
	local transform = self.Owner.transform
	local view = self.view
	local movement = self.Owner.player_movement

	if movement then self:SetViewOffset(movement:GetViewOffset()) end

	local position = self:GetViewPosition()
	local look = self.Owner.player_input

	if look then
		local rotation = look:GetRotation()
		view:SetRotation(rotation:Copy())
		view:SetFOV(look:GetFOV())

		if third_person:Get() then
			local offset = rotation:GetForward() * -THIRD_PERSON_DISTANCE + rotation:GetRight() * THIRD_PERSON_SHOULDER + rotation:GetUp() * THIRD_PERSON_LIFT
			local length = offset:GetLength()
			local hit = physics.Sweep(
				position,
				offset,
				THIRD_PERSON_RADIUS,
				self.Owner,
				is_static_geometry,
				TRACE_OPTIONS
			)

			if hit then
				offset = offset * (math.max(hit.distance - THIRD_PERSON_MARGIN, 0) / length)
			end

			position = position + offset
		end
	else
		view:SetRotation(transform:GetRotation():Copy())
	end

	view:SetPosition(position)
end

function META:OnRemove()
	self.view:Remove()
end

return META:Register()
