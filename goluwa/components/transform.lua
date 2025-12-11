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

function META:Initialize(config)
	config = config or {}
	self.temp_scale = Vec3(1, 1, 1)
	self.LocalMatrix = nil
	self.WorldMatrix = nil
	self.WorldMatrixInverse = nil

	if config.position then self:SetPosition(config.position) end

	if config.rotation then self:SetRotation(config.rotation) end

	if config.scale then self:SetScale(config.scale) end

	if config.size then self:SetSize(config.size) end

	if config.matrix then self:SetFromMatrix(config.matrix) end
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
	self.Scale = vec3
	self.temp_scale = vec3 * self.Size
	self:InvalidateMatrices()
end

function META:SetSize(num)
	self.Size = num
	self.temp_scale = num * self.Scale
	self:InvalidateMatrices()
end

function META:InvalidateMatrices()
	self.LocalMatrix = nil
	self.WorldMatrix = nil
	self.WorldMatrixInverse = nil
	self:InvalidateChildWorldMatrices()
end

function META:InvalidateChildWorldMatrices()
	if not self.Entity then return end

	for _, child in ipairs(self.Entity:GetChildrenList()) do
		if child:HasComponent("transform") then
			child.transform.WorldMatrix = nil
			child.transform.WorldMatrixInverse = nil
			child.transform:InvalidateChildWorldMatrices()
		end
	end
end

-- Get local matrix (without parent transforms)
function META:GetLocalMatrix()
	if not self.LocalMatrix then
		self.LocalMatrix = Matrix44()

		if not self.SkipRebuild then
			local pos = self.OverridePosition or self.Position
			local rot = self.OverrideRotation or self.Rotation
			self.LocalMatrix:Identity()
			self.LocalMatrix:SetTranslation(pos.x, pos.y, pos.z)
			self.LocalMatrix:SetRotation(rot)

			-- Apply scale if needed
			if self.temp_scale.x ~= 1 or self.temp_scale.y ~= 1 or self.temp_scale.z ~= 1 then
				local scale_matrix = Matrix44()
				scale_matrix:Identity()
				scale_matrix:Scale(self.temp_scale.x, self.temp_scale.y, self.temp_scale.z)
				local temp = Matrix44()
				self.LocalMatrix:GetMultiplied(scale_matrix, temp)
				self.LocalMatrix = temp
			end
		end
	end

	return self.LocalMatrix
end

-- Get world matrix (with parent transforms applied)
function META:GetWorldMatrix()
	if not self.WorldMatrix then
		local local_matrix = self:GetLocalMatrix()

		if self.Entity and self.Entity:HasParent() then
			local parent = self.Entity:GetParent()

			if parent:HasComponent("transform") then
				local parent_world = parent.transform:GetWorldMatrix()
				self.WorldMatrix = Matrix44()
				parent_world:GetMultiplied(local_matrix, self.WorldMatrix)
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
	if not self.WorldMatrixInverse then
		self.WorldMatrixInverse = self:GetWorldMatrix():GetInverse()
	end

	return self.WorldMatrixInverse
end

META:Register()
ecs.RegisterComponent(META)
return META
