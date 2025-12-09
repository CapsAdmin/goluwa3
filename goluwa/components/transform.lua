local prototype = require("prototype")
local ecs = require("ecs")
local Matrix44 = require("structs.matrix").Matrix44
local Ang3 = require("structs.ang3")
local Vec3 = require("structs.vec3")
local Quat = require("structs.quat")
local AABB = require("structs.aabb")
local META = prototype.CreateTemplate("component", "transform")
META.ComponentName = "transform"
-- No requirements - transform is a base component
META.Require = {}
META.Events = {}
META:GetSet("TRMatrix", Matrix44())
META:GetSet("ScaleMatrix", Matrix44())
META:StartStorable()
META:GetSet("Position", Vec3(0, 0, 0), {callback = "InvalidateTRMatrix"})
META:GetSet("Rotation", Quat(0, 0, 0, 1), {callback = "InvalidateTRMatrix"})
META:GetSet("Scale", Vec3(1, 1, 1), {callback = "InvalidateScaleMatrix"})
META:GetSet("Size", 1, {callback = "InvalidateScaleMatrix"})
META:GetSet("SkipRebuild", false)
META:EndStorable()
META:GetSet("OverridePosition", nil, {callback = "InvalidateTRMatrix"})
META:GetSet("OverrideRotation", nil, {callback = "InvalidateTRMatrix"})
META:GetSet("AABB", AABB(-1, -1, -1, 1, 1, 1), {callback = "InvalidateTRMatrix"})
-- Local matrix (without parent transform)
META:GetSet("LocalMatrix", nil)
-- Cached world matrix (with parent transforms applied)
META:GetSet("WorldMatrix", nil)

function META:Initialize(config)
	config = config or {}
	-- Create fresh matrices for this instance
	self.TRMatrix = Matrix44()
	self.ScaleMatrix = Matrix44()
	self.temp_scale = Vec3(1, 1, 1)
	self.rebuild_tr_matrix = true
	self.rebuild_scale_matrix = true
	self.world_matrix_dirty = true

	-- Apply config
	if config.position then self:SetPosition(config.position) end

	if config.rotation then self:SetRotation(config.rotation) end

	if config.scale then self:SetScale(config.scale) end

	if config.size then self:SetSize(config.size) end

	if config.matrix then self:SetFromMatrix(config.matrix) end
end

function META:OnAdd(entity) -- Nothing special needed
end

-- Set transform from a matrix (decompose into TRS)
function META:SetFromMatrix(matrix)
	-- For now, just store the matrix directly
	-- A proper implementation would decompose into position/rotation/scale
	self.TRMatrix = matrix:Copy()
	self.rebuild_tr_matrix = false
	self.rebuild_scale_matrix = false
	self.world_matrix_dirty = true
end

function META:GetAngles()
	return self.Rotation:GetAngles()
end

function META:SetAngles(ang)
	self.Rotation:SetAngles(ang)
	self:InvalidateTRMatrix()
end

function META:SetScale(vec3)
	self.Scale = vec3
	self.temp_scale = vec3 * self.Size
	self:InvalidateScaleMatrix()
end

function META:SetSize(num)
	self.Size = num
	self.temp_scale = num * self.Scale
	self:InvalidateScaleMatrix()
end

function META:InvalidateScaleMatrix()
	self.rebuild_scale_matrix = true
	self.rebuild_tr_matrix = true
	self.world_matrix_dirty = true
	self:InvalidateChildWorldMatrices()
end

function META:InvalidateTRMatrix()
	self.rebuild_tr_matrix = true
	self.world_matrix_dirty = true
	self:InvalidateChildWorldMatrices()
end

function META:InvalidateChildWorldMatrices()
	if not self.Entity then return end

	for _, child in ipairs(self.Entity:GetChildrenList()) do
		if child:HasComponent("transform") then
			child.transform.world_matrix_dirty = true
		end
	end
end

function META:RebuildLocalMatrix()
	if
		self.rebuild_scale_matrix and
		(
			self.temp_scale.x ~= 1 or
			self.temp_scale.y ~= 1 or
			self.temp_scale.z ~= 1
		)
	then
		self.ScaleMatrix:Identity()
		self.ScaleMatrix:Scale(self.temp_scale.y, self.temp_scale.x, self.temp_scale.z)
	end

	if self.rebuild_tr_matrix and not self.SkipRebuild then
		local pos = self.Position
		local rot = self.Rotation

		if self.OverrideRotation then rot = self.OverrideRotation end

		if self.OverridePosition then pos = self.OverridePosition end

		self.TRMatrix:Identity()
		self.TRMatrix:SetTranslation(-pos.y, -pos.x, -pos.z)
		self.TRMatrix:SetRotation(rot)
	end

	if self.rebuild_tr_matrix or self.rebuild_scale_matrix then
		if self.temp_scale.x ~= 1 or self.temp_scale.y ~= 1 or self.temp_scale.z ~= 1 then
			self.LocalMatrix = self.LocalMatrix or Matrix44()
			self.TRMatrix:GetMultiplied(self.ScaleMatrix, self.LocalMatrix)
		else
			self.LocalMatrix = self.TRMatrix
		end
	end

	self.rebuild_tr_matrix = false
	self.rebuild_scale_matrix = false
end

-- Get local matrix (without parent transforms)
function META:GetLocalMatrix()
	self:RebuildLocalMatrix()
	return self.LocalMatrix or self.TRMatrix
end

-- Get world matrix (with parent transforms applied)
function META:GetWorldMatrix()
	if not self.world_matrix_dirty and self.WorldMatrix then
		return self.WorldMatrix
	end

	local local_matrix = self:GetLocalMatrix()

	-- Check if we have a parent with a transform
	if self.Entity and self.Entity:HasParent() then
		local parent = self.Entity:GetParent()

		if parent:HasComponent("transform") then
			local parent_world = parent.transform:GetWorldMatrix()
			-- Reuse existing WorldMatrix to avoid allocation
			self.WorldMatrix = self.WorldMatrix or Matrix44()
			parent_world:GetMultiplied(local_matrix, self.WorldMatrix)
		else
			self.WorldMatrix = local_matrix
		end
	else
		self.WorldMatrix = local_matrix
	end

	self.world_matrix_dirty = false
	return self.WorldMatrix
end

-- Alias for compatibility
function META:GetMatrix()
	return self:GetWorldMatrix()
end

META:Register()
ecs.RegisterComponent(META)
return META
