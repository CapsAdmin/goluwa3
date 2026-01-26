local event = require("event")
local window = require("window")
local render2d = require("render2d.render2d")
local prototype = require("prototype")
local Matrix44 = require("structs.matrix44")
local Vec2 = require("structs.vec2")
local Vec3 = require("structs.vec3")
local Ang3 = require("structs.ang3")
local Color = require("structs.color")
local window = require("window")
local render = require("render.render")
local gfx = require("render2d.gfx")
local Rect = require("structs.rect")
local META = prototype.CreateTemplate("transform_2d")
META.ComponentName = META.Type
-- No requirements - transform is a base component
META.Require = {}
META.Events = {}
META:StartStorable()
META:GetSet("Position", Vec2(0, 0), {callback = "OnPositionChanged"})
META:GetSet("Size", Vec2(100, 100), {callback = "OnSizeChanged"})
META:GetSet("Rotation", 0, {callback = "InvalidateMatrices"})
META:GetSet("Scale", Vec2(1, 1), {callback = "InvalidateMatrices"})
META:GetSet("Pivot", Vec2(0.5, 0.5), {callback = "InvalidateMatrices"})
META:GetSet("Perspective", 0, {callback = "InvalidateMatrices"})
META:GetSet("Scroll", Vec2(0, 0), {callback = "InvalidateMatrices"})
META:GetSet("ScrollEnabled", false)
META:GetSet("DrawSizeOffset", Vec2(0, 0), {callback = "InvalidateMatrices"})
META:GetSet("DrawScaleOffset", Vec2(1, 1), {callback = "InvalidateMatrices"})
META:GetSet("DrawPositionOffset", Vec2(0, 0), {callback = "InvalidateMatrices"})
META:GetSet("DrawAngleOffset", Ang3(0, 0, 0), {callback = "InvalidateMatrices"})
META:EndStorable()
META:GetSet("LocalMatrix", Matrix44():Identity())

function META:OnPositionChanged()
	self:InvalidateLayout()
	self:InvalidateMatrices()
end

function META:InvalidateMatrices()
	self.LocalMatrixDirty = true
	self:InvalidateWorldMatrices()
end

function META:Initialize() end

function META:InvalidateWorldMatrices()
	if self.WorldMatrixDirty then return end

	self.WorldMatrixDirty = true
	self.WorldMatrixInverseDirty = true

	if self.Entity then
		for _, child in ipairs(self.Entity:GetChildren()) do
			local tr = child:GetComponent("transform_2d")

			if tr then tr:InvalidateWorldMatrices() end
		end
	end
end

function META:InvalidateLayout()
	if not self.Entity or self.in_layout_invalidation then return end

	self.in_layout_invalidation = true
	local layout = self.Entity:GetComponent("layout_2d")

	if layout then
		layout:InvalidateLayout()
	else
		local parent = self.Entity:GetParent()

		if parent and parent:IsValid() then
			local p_layout = parent:GetComponent("layout_2d")

			if p_layout then p_layout:InvalidateLayout() end
		end
	end

	for _, child in ipairs(self.Entity:GetChildren()) do
		local c_tr = child:GetComponent("transform_2d")

		if c_tr then c_tr:InvalidateLayout() end
	end

	self.in_layout_invalidation = nil
end

function META:OnSizeChanged()
	self:InvalidateLayout()
	self:InvalidateMatrices()
end

function META:GetWidth()
	return self.Size.x
end

function META:GetHeight()
	return self.Size.y
end

function META:SetWidth(w)
	self:SetSize(Vec2(w, self.Size.y))
end

function META:SetHeight(h)
	self:SetSize(Vec2(self.Size.x, h))
end

function META:GetX()
	return self.Position.x
end

function META:GetY()
	return self.Position.y
end

function META:SetX(x)
	self:SetPosition(Vec2(x, self.Position.y))
end

function META:SetY(y)
	self:SetPosition(Vec2(self.Position.x, y))
end

function META:GetAxisLength(axis)
	if axis == "x" then return self:GetWidth() else return self:GetHeight() end
end

function META:SetAxisLength(axis, len)
	if axis == "x" then self:SetWidth(len) else self:SetHeight(len) end
end

function META:GetAxisPosition(axis)
	if axis == "x" then return self:GetX() else return self:GetY() end
end

function META:SetAxisPosition(axis, pos)
	if axis == "x" then self:SetX(pos) else self:SetY(pos) end
end

function META:GetWorldRectFast()
	local mat = self:GetWorldMatrix()
	local x, y = mat:GetTranslation()
	return x, y, x + self.Size.x, y + self.Size.y
end

function META:GetLocalMatrix()
	if self.LocalMatrixDirty then
		self.LocalMatrix:Identity()
		local pivot = self.Pivot
		local center = (self.Size + self.DrawSizeOffset) * pivot
		local angles = self.DrawAngleOffset
		local perspective = self.Perspective
		local pos = self.Position + self.DrawPositionOffset
		self.LocalMatrix:Translate(pos.x + center.x, pos.y + center.y, 0)

		if perspective ~= 0 then
			local p = Matrix44()
			p:Identity()
			-- CSS perspective projection: divides x,y by (1 - z/d)
			-- In TransformVector: w = z * m23 + m33, then x/w, y/w
			-- For w = 1 - z/d: m23 = -1/d, m33 = 1
			p.m23 = -1 / perspective
			self.LocalMatrix = p * self.LocalMatrix
		end

		if angles.p ~= 0 then self.LocalMatrix:Rotate(angles.p, 1, 0, 0) end

		if angles.y ~= 0 then self.LocalMatrix:Rotate(angles.y, 0, 1, 0) end

		local rotation = math.rad(self.Rotation) + angles.r

		if rotation ~= 0 then self.LocalMatrix:Rotate(rotation, 0, 0, 1) end

		local scale = self.Scale * self.DrawScaleOffset

		if scale.x ~= 1 or scale.y ~= 1 then
			self.LocalMatrix:Scale(scale.x, scale.y, 1)
		end

		self.LocalMatrix:Translate(-center.x, -center.y, 0)
		self.LocalMatrixDirty = false
	end

	return self.LocalMatrix
end

function META:GetWorldMatrix()
	if self.WorldMatrixDirty or not self.WorldMatrix then
		local local_mat = self:GetLocalMatrix()
		local parent = self.Entity and self.Entity:GetParent()
		local parent_tr = parent and parent:IsValid() and parent:GetComponent("transform_2d")

		if parent_tr then
			local parent_world = parent_tr:GetWorldMatrix()
			self.WorldMatrix = self.WorldMatrix or Matrix44()
			local scroll = parent_tr:GetScroll()

			if scroll.x ~= 0 or scroll.y ~= 0 then
				local temp = local_mat:Copy()
				temp:Translate(-scroll.x, -scroll.y, 0)
				temp:GetMultiplied(parent_world, self.WorldMatrix)
			else
				local_mat:GetMultiplied(parent_world, self.WorldMatrix)
			end
		else
			self.WorldMatrix = local_mat:Copy()
		end

		self.WorldMatrixDirty = false
	end

	return self.WorldMatrix
end

function META:GetWorldMatrixInverse()
	if self.WorldMatrixInverseDirty or not self.WorldMatrixInverse then
		self.WorldMatrixInverse = self:GetWorldMatrix():GetInverse()
		self.WorldMatrixInverseDirty = false
	end

	return self.WorldMatrixInverse
end

function META:GlobalToLocal(vec, out)
	local mat = self:GetWorldMatrixInverse()
	local x, y, z = mat:TransformVector(vec.x, vec.y, vec.z or 0)

	if out then
		out.x = x
		out.y = y
		return out
	end

	return Vec2(x, y)
end

local transform = {}
transform.Component = META:Register()
-- no system?
return transform
