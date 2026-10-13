local ffi = require("ffi")
local objects = import("goluwa/objects/objects.lua")
local event = import("goluwa/event.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local AABB = import("goluwa/structs/aabb.lua")
local system = import("goluwa/system.lua")
local physics
local MATRIX_SIZE = ffi.sizeof(Matrix44)
local attachment_matrix = Matrix44()
local rotation_matrix = Matrix44()

-- the armature of the nearest ancestor that has one, an attachment goes through containers
local function find_armature(entity)
	local parent = entity:GetParent()

	while parent:IsValid() do
		if parent.armature then return parent.armature end

		parent = parent:GetParent()
	end
end
local META = objects.CreateTemplate("transform_3d")
META.Is3D = true
META.Is2D = false
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
META:GetSet(
	"Attachment",
	"root",
	{
		callback = "InvalidateMatrices",
		get_enums = function(self)
			local armature = find_armature(self.Owner)
			local names = {"root"}

			if armature then
				for _, name in ipairs(armature:GetBoneNames()) do
					if name ~= "root" then names[#names + 1] = name end
				end
			end

			return names
		end,
	}
)
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

	local dynamic = self.Attachment ~= "root" or self:ShouldUseInterpolatedPhysicsTransform()

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
		self.InterpolatedPosition = body:GetInterpolatedOrigin(alpha)
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

-- the matrix of the bone this transform is attached to, nil for root or when no ancestor has such a bone
function META:GetAttachedBone()
	if self.Attachment == "root" then return nil end

	local armature = find_armature(self.Owner)
	return armature and armature:GetBoneMatrix(self.Attachment) or nil
end

-- the rotation of the bone this transform is attached to without its scale, nil for root
function META:GetAttachedBoneRotation()
	local bone = self:GetAttachedBone()

	if not bone then return nil end

	local m = rotation_matrix
	local l0 = math.sqrt(bone.m00 * bone.m00 + bone.m01 * bone.m01 + bone.m02 * bone.m02)
	local l1 = math.sqrt(bone.m10 * bone.m10 + bone.m11 * bone.m11 + bone.m12 * bone.m12)
	local l2 = math.sqrt(bone.m20 * bone.m20 + bone.m21 * bone.m21 + bone.m22 * bone.m22)
	m:Identity()
	m.m00, m.m01, m.m02 = bone.m00 / l0, bone.m01 / l0, bone.m02 / l0
	m.m10, m.m11, m.m12 = bone.m10 / l1, bone.m11 / l1, bone.m12 / l1
	m.m20, m.m21, m.m22 = bone.m20 / l2, bone.m21 / l2, bone.m22 / l2
	return m:GetRotation()
end

-- the matrix the local transform is relative to, the world matrix of the parent with the bone of the attachment in between
function META:GetParentWorldMatrix()
	local parent = self.Owner:GetParent()

	if not (parent:IsValid() and parent.transform) then return nil end

	local parent_world = parent.transform:GetWorldMatrix()
	local bone = self:GetAttachedBone()

	if not bone then return parent_world end

	return bone:GetMultiplied(parent_world, Matrix44())
end

-- a position in the world as a local position of this transform
function META:WorldToLocalPosition(world_position)
	local parent = self.Owner:GetParent()

	if not (parent:IsValid() and parent.transform) then return world_position:Copy() end

	if self.Attachment == "root" then
		return parent.transform:GetWorldMatrixInverse():TransformVector(world_position)
	end

	return self:GetParentWorldMatrix():GetInverse():TransformVector(world_position)
end

function META:GetWorldMatrix()
	local frame = system.GetFrameNumber()
	local dynamic = self:IsFrameDynamic()
	local bone = self:GetAttachedBone()

	if
		dynamic and
		self.WorldMatrixFrame == frame and
		self.WorldMatrix and
		self.WorldMatrixBone == bone
	then
		return self.WorldMatrix
	end

	if not self.WorldMatrix or dynamic then
		self.WorldMatrixBone = bone
		local local_matrix = self:GetLocalMatrix()
		self.WorldMatrixFrame = dynamic and frame or nil

		if self.Owner and self.Owner:HasParent() then
			local parent = self.Owner:GetParent()

			if parent.transform then
				local parent_world = parent.transform:GetWorldMatrix()
				self.WorldMatrix = Matrix44()

				if bone then
					local_matrix:GetMultiplied(bone, attachment_matrix)
					attachment_matrix:GetMultiplied(parent_world, self.WorldMatrix)
				else
					local_matrix:GetMultiplied(parent_world, self.WorldMatrix)
				end
			else
				self.WorldMatrix = local_matrix
			end
		else
			self.WorldMatrix = local_matrix
		end
	end

	return self.WorldMatrix
end

-- the world matrix of this frame is kept for the next one, in two matrices that take turns
function META:GetPreviousWorldMatrix()
	local world = self:GetWorldMatrix()
	local frame = system.GetFrameNumber()

	if self.RenderWorldMatrixFrame ~= frame then
		local current = self.RenderWorldMatrix
		local spare = self.SpareRenderWorldMatrix

		if self.RenderWorldMatrixFrame == frame - 1 then
			self.PreviousRenderWorldMatrix = current
		else
			self.PreviousRenderWorldMatrix = nil
		end

		if not spare then spare = Matrix44() end

		ffi.copy(spare, world, MATRIX_SIZE)
		self.RenderWorldMatrix = spare
		self.SpareRenderWorldMatrix = current
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

do
	local FOLLOW_RATE = 12
	local MAX_GAP = 0.25

	-- measured from the world position of the last frames, so it is the same for bodies the client simulates and for
	-- replicated ones (rigid_body does not replicate velocity), smoothed, shared by every caller of the frame
	-- and zero when nobody asked for a while. Do not modify the returned vector.
	function META:GetRenderVelocity()
		local frame = system.GetFrameNumber()
		local velocity = self.RenderVelocity

		if self.RenderVelocityFrame == frame then return velocity end

		local m = self:GetWorldMatrix()
		local now = system.GetElapsedTime()
		self.RenderVelocityFrame = frame

		if not velocity then
			velocity = Vec3(0, 0, 0)
			self.RenderVelocity = velocity
		end

		local dt = now - (self.RenderVelocityTime or -math.huge)

		if dt > MAX_GAP then
			velocity:Set(0, 0, 0)
		elseif dt > 0 then
			local follow = math.min(dt * FOLLOW_RATE, 1)
			velocity:Set(
				velocity.x + ((m.m30 - self.RenderVelocityX) / dt - velocity.x) * follow,
				velocity.y + ((m.m31 - self.RenderVelocityY) / dt - velocity.y) * follow,
				velocity.z + ((m.m32 - self.RenderVelocityZ) / dt - velocity.z) * follow
			)
		end

		self.RenderVelocityTime = now
		self.RenderVelocityX, self.RenderVelocityY, self.RenderVelocityZ = m.m30, m.m31, m.m32
		return velocity
	end
end

return META:Register()
