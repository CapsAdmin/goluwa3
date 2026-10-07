local objects = import("goluwa/objects/objects.lua")
local event = import("goluwa/event.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local AABB = import("goluwa/structs/aabb.lua")
local system = import("goluwa/system.lua")
local physics
local META = objects.CreateTemplate("transform_3d")
META.Is3D = true
META.Network = {
	Position = {"vec3", 1 / 20, "sequenced", true},
	Rotation = {"quat", 1 / 20, "sequenced", true},
	Scale = {"vec3", 1, "reliable"},
}

local function find_ancestor_visual(entity)
	local current = entity

	while current and current.IsValid and current:IsValid() do
		if current.visual then return current.visual end

		current = current:GetParent()
	end

	return nil
end

local function update_temp_scale(self)
	local scale = self.Scale or Vec3(1, 1, 1)
	local size = self.Size or 1
	local previous = self.temp_scale
	self.temp_scale = scale * size

	if previous and previous ~= self.temp_scale then
		local body = self.Owner and self.Owner.rigid_body

		if body then body:OnGeometryChanged() end
	end

	return self.temp_scale
end

META:StartStorable()
META:GetSet("Matrix", nil, {type = "table"})
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
	update_temp_scale(self)
end

local MATRIX_FIELDS = {}

for row = 0, 3 do
	for column = 0, 3 do
		MATRIX_FIELDS[#MATRIX_FIELDS + 1] = "m" .. row .. column
	end
end

function META:GetMatrix()
	local matrix = self.FromMatrix

	if not matrix then return nil end

	local values = {}

	for i, field in ipairs(MATRIX_FIELDS) do
		values[i] = matrix[field]
	end

	return values
end

function META:SetMatrix(values)
	if values == nil then
		self.FromMatrix = nil
	else
		local matrix = Matrix44()

		for i, field in ipairs(MATRIX_FIELDS) do
			matrix[field] = values[i]
		end

		self.FromMatrix = matrix
	end

	self:InvalidateMatrices()
end

function META:SetFromMatrix(matrix)
	self.FromMatrix = matrix:Copy()
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
	objects.CommitProperty(self, "Scale", vec3)
	update_temp_scale(self)
end

function META:SetSize(num)
	objects.CommitProperty(self, "Size", num)
	update_temp_scale(self)
end

function META:InvalidateMatrices()
	local body = self.Owner and self.Owner.rigid_body

	if body then body:MarkTransformDirty() end

	self.LocalMatrix = nil
	self.WorldMatrix = nil
	self.WorldMatrixInverse = nil
	self.LocalMatrixFrame = nil
	self.WorldMatrixFrame = nil
	self.WorldMatrixInverseFrame = nil
	self.ShouldUseInterpolatedPhysicsTransformFrame = nil
	self.ShouldUseInterpolatedPhysicsTransformCached = nil
	self.IsFrameDynamicFrame = nil
	self.IsFrameDynamicCached = nil
	event.Call("OnTransformChanged", self)

	if self.Owner and self.Owner.visual then
		self.Owner.visual.WorldAABBCache = nil
		self.Owner.visual.WorldAABBCacheMatrix = nil
		self.Owner.visual.WorldAABBCacheSource = nil
		local visual_library = self.Owner.visual.Library

		if visual_library and visual_library.InvalidateSceneAcceleration then
			visual_library.InvalidateSceneAcceleration(self.Owner.visual)
		end

		if visual_library and visual_library.TouchShadowChange then
			visual_library.TouchShadowChange(self.Owner.visual)
		end
	end

	if self.Owner and self.Owner.visual_primitive then
		local visual = find_ancestor_visual(self.Owner)

		if visual then
			visual:InvalidateHierarchyState()
			local visual_library = visual.Library

			if visual_library and visual_library.InvalidateSceneAcceleration then
				visual_library.InvalidateSceneAcceleration(visual)
			end

			if visual_library and visual_library.TouchShadowChange then
				visual_library.TouchShadowChange(visual)
			end
		end
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
			child.transform:InvalidateChildWorldMatrices()
		end
	end
end

function META:ShouldUseInterpolatedPhysicsTransform()
	local frame = system.GetFrameNumber()

	if self.ShouldUseInterpolatedPhysicsTransformFrame == frame then
		return self.ShouldUseInterpolatedPhysicsTransformCached
	end

	local owner = self.Owner
	local body = owner and owner.rigid_body
	local should_interpolate = body and
		body.ShouldInterpolateTransform and
		body:ShouldInterpolateTransform() or
		false
	self.ShouldUseInterpolatedPhysicsTransformFrame = frame
	self.ShouldUseInterpolatedPhysicsTransformCached = should_interpolate
	return should_interpolate
end

function META:IsFrameDynamic()
	local frame = system.GetFrameNumber()

	if self.IsFrameDynamicFrame == frame then return self.IsFrameDynamicCached end

	local dynamic = self:ShouldUseInterpolatedPhysicsTransform()

	if not dynamic then
		local parent = self.Owner and self.Owner:GetParent()
		dynamic = parent and parent.transform and parent.transform:IsFrameDynamic() or false
	end

	self.IsFrameDynamicFrame = frame
	self.IsFrameDynamicCached = dynamic
	return dynamic
end

function META:GetRenderPositionRotation()
	if not self:ShouldUseInterpolatedPhysicsTransform() then return nil end

	local frame = system.GetFrameNumber()

	if self.InterpolatedFrame ~= frame then
		local body = self.Owner.rigid_body
		physics = physics or import("goluwa/physics.lua")
		local alpha = physics.GetInterpolationAlpha()
		self.InterpolatedPosition = body:GetInterpolatedPosition(alpha)
		self.InterpolatedRotation = body:GetInterpolatedRotation(alpha)
		self.InterpolatedFrame = frame
	end

	return self.InterpolatedPosition, self.InterpolatedRotation
end

function META:GetLocalMatrix()
	local frame = system.GetFrameNumber()
	local dynamic = self:IsFrameDynamic()

	if dynamic and self.LocalMatrixFrame == frame and self.LocalMatrix then
		return self.LocalMatrix
	end

	if not self.LocalMatrix or dynamic then
		self.LocalMatrix = self.FromMatrix and self.FromMatrix:Copy() or Matrix44()
		self.LocalMatrixFrame = dynamic and frame or nil

		if not self.FromMatrix and not self.SkipRebuild then
			local interpolated_pos, interpolated_rot = self:GetRenderPositionRotation()
			local pos = self.OverridePosition or interpolated_pos or self.Position
			local rot = self.OverrideRotation or interpolated_rot or self.Rotation
			local temp_scale = update_temp_scale(self)
			self.LocalMatrix:Identity()
			self.LocalMatrix:SetRotation(rot)

			if temp_scale.x ~= 1 or temp_scale.y ~= 1 or temp_scale.z ~= 1 then
				self.LocalMatrix:Scale(temp_scale.x, temp_scale.y, temp_scale.z)
			end

			self.LocalMatrix:SetTranslation(pos.x, pos.y, pos.z)
		end
	end

	return self.LocalMatrix
end

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

function META:GetPreviousWorldMatrix()
	local world = self:GetWorldMatrix()
	local frame = system.GetFrameNumber()

	if self.RenderWorldMatrixFrame ~= frame then
		if self.RenderWorldMatrixFrame == frame - 1 then
			self.PreviousRenderWorldMatrix = self.RenderWorldMatrix
		else
			self.PreviousRenderWorldMatrix = nil
		end

		self.RenderWorldMatrix = world:Copy()
		self.RenderWorldMatrixFrame = frame
	end

	return self.PreviousRenderWorldMatrix or world
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

function META:GetWorldPosition()
	return Vec3(self:GetWorldMatrix():GetTranslation())
end

return META:Register()
