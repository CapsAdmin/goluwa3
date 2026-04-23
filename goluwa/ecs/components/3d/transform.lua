local prototype = import("goluwa/prototype.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local AABB = import("goluwa/structs/aabb.lua")
local system = import("goluwa/system.lua")
local physics
local META = prototype.CreateTemplate("transform_3d")
META:StartStorable()
META:GetSet("Position", Vec3(0, 0, 0), {callback = "InvalidateMatrices"})
META:GetSet("Rotation", Quat(0, 0, 0, 1), {callback = "InvalidateMatrices"})
META:GetSet("Scale", Vec3(1, 1, 1), {callback = "InvalidateMatrices"})
META:GetSet("Size", 1, {callback = "InvalidateMatrices"})
META:GetSet("SkipRebuild", false)
META:EndStorable()
META:GetSet("OverridePosition", nil, {callback = "InvalidateMatrices"})
META:GetSet("OverrideRotation", nil, {callback = "InvalidateMatrices"})
META:GetSet("AABB", AABB(-1, -1, -1, 1, 1, 1), {callback = "InvalidateMatrices"})

function META:Initialize()
	self.temp_scale = Vec3(1, 1, 1)
end

function META:SetFromMatrix(matrix)
	self.LocalMatrix = matrix:Copy()
	self:InvalidateMatrices()
end

function META:GetAngles()
	return self.Rotation:GetAngles()
end

function META:SetAngles(ang)
	self.Rotation:SetAngles(ang)
	self:InvalidateMatrices()
end

function META:SetScale(vec3)
	prototype.CommitProperty(self, "Scale", vec3)
	self.temp_scale = self.Scale * self.Size
end

function META:SetSize(num)
	prototype.CommitProperty(self, "Size", num)
	self.temp_scale = self.Size * self.Scale
end

function META:InvalidateMatrices()
	self.LocalMatrix = nil
	self.WorldMatrix = nil
	self.WorldMatrixInverse = nil
	self.LocalMatrixFrame = nil
	self.WorldMatrixFrame = nil
	self.WorldMatrixInverseFrame = nil

	if self.Owner and self.Owner.model then
		self.Owner.model.WorldAABBCache = nil
		self.Owner.model.WorldAABBCacheMatrix = nil
		self.Owner.model.WorldAABBCacheSource = nil
	end

	self:InvalidateChildWorldMatrices()
end

function META:InvalidateChildWorldMatrices()
	if not self.Owner then return end

	for _, child in ipairs(self.Owner:GetChildrenList()) do
		if child.transform then
			child.transform.WorldMatrix = nil
			child.transform.WorldMatrixInverse = nil
			child.transform.WorldMatrixFrame = nil
			child.transform.WorldMatrixInverseFrame = nil

			if child.model then
				child.model.WorldAABBCache = nil
				child.model.WorldAABBCacheMatrix = nil
				child.model.WorldAABBCacheSource = nil
			end

			child.transform:InvalidateChildWorldMatrices()
		end
	end
end

function META:ShouldUseInterpolatedPhysicsTransform()
	local owner = self.Owner
	local body = owner and owner.rigid_body
	return body and
		body.ShouldInterpolateTransform and
		body:ShouldInterpolateTransform() or
		false
end

function META:IsFrameDynamic()
	if self:ShouldUseInterpolatedPhysicsTransform() then return true end

	local parent = self.Owner and self.Owner:GetParent()
	return parent and parent.transform and parent.transform:IsFrameDynamic() or false
end

function META:GetRenderPositionRotation()
	if not self:ShouldUseInterpolatedPhysicsTransform() then return nil end

	local frame = system.GetFrameNumber()

	if self.InterpolatedFrame ~= frame then
		local body = self.Owner.rigid_body
		physics = physics or import("goluwa/physics.lua")
		local alpha = physics.GetInterpolationAlpha and physics.GetInterpolationAlpha() or 0
		self.InterpolatedPosition = body:GetInterpolatedPosition(alpha)
		self.InterpolatedRotation = body:GetInterpolatedRotation(alpha)
		self.InterpolatedFrame = frame
	end

	return self.InterpolatedPosition, self.InterpolatedRotation
end

-- Get local matrix (without parent transforms)
function META:GetLocalMatrix()
	local frame = system.GetFrameNumber()
	local dynamic = self:IsFrameDynamic()

	if dynamic and self.LocalMatrixFrame == frame and self.LocalMatrix then
		return self.LocalMatrix
	end

	if not self.LocalMatrix or dynamic then
		self.LocalMatrix = Matrix44()
		self.LocalMatrixFrame = dynamic and frame or nil

		if not self.SkipRebuild then
			-- ORIENTATION / TRANSFORMATION
			local interpolated_pos, interpolated_rot = self:GetRenderPositionRotation()
			local pos = self.OverridePosition or interpolated_pos or self.Position
			local rot = self.OverrideRotation or interpolated_rot or self.Rotation
			self.LocalMatrix:Identity()
			self.LocalMatrix:SetRotation(rot)

			-- Apply scale if needed
			if self.temp_scale.x ~= 1 or self.temp_scale.y ~= 1 or self.temp_scale.z ~= 1 then
				self.LocalMatrix:Scale(self.temp_scale.x, self.temp_scale.y, self.temp_scale.z)
			end

			self.LocalMatrix:SetTranslation(pos.x, pos.y, pos.z)
		end
	end

	return self.LocalMatrix
end

-- Get world matrix (with parent transforms applied)
function META:GetWorldMatrix()
	local frame = system.GetFrameNumber()
	local dynamic = self:IsFrameDynamic()

	if dynamic and self.WorldMatrixFrame == frame and self.WorldMatrix then
		return self.WorldMatrix
	end

	if not self.WorldMatrix or dynamic then
		local local_matrix = self:GetLocalMatrix()
		self.WorldMatrixFrame = dynamic and frame or nil

		if self.Owner and self.Owner:HasParent() then
			local parent = self.Owner:GetParent()

			if parent.transform then
				local parent_world = parent.transform:GetWorldMatrix()
				self.WorldMatrix = Matrix44()
				local_matrix:GetMultiplied(parent_world, self.WorldMatrix)
			else
				self.WorldMatrix = local_matrix
			end
		else
			self.WorldMatrix = local_matrix
		end
	end

	return self.WorldMatrix
end

function META:GetWorldMatrixInverse()
	local frame = system.GetFrameNumber()
	local dynamic = self:IsFrameDynamic()

	if dynamic and self.WorldMatrixInverseFrame == frame and self.WorldMatrixInverse then
		return self.WorldMatrixInverse
	end

	if not self.WorldMatrixInverse or dynamic then
		self.WorldMatrixInverseFrame = dynamic and frame or nil
		self.WorldMatrixInverse = self:GetWorldMatrix():GetInverse()
	end

	return self.WorldMatrixInverse
end

return META:Register()
