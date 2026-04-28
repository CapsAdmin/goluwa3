local event = import("goluwa/event.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local prototype = import("goluwa/prototype.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local Color = import("goluwa/structs/color.lua")
local render = import("goluwa/render/render.lua")
local gfx = import("goluwa/render2d/gfx.lua")
local Rect = import("goluwa/structs/rect.lua")
local META = prototype.CreateTemplate("transform_2d")
META:StartStorable()
META:GetSet("Position", Vec2(0, 0), {callback = "InvalidateMatrices"})
META:GetSet("Z", 0, {callback = "InvalidateMatrices"})
META:GetSet("Size", Vec2(1, 1), {callback = "InvalidateMatrices"})
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

function META:InvalidateMatrices()
	self.LocalMatrix = nil
	self:InvalidateWorldMatrices()
end

function META:Initialize() end

function META:OnParent()
	self:InvalidateWorldMatrices()
end

function META:OnUnParent()
	self:InvalidateWorldMatrices()
end

function META:InvalidateWorldMatrices()
	self.WorldMatrix = nil
	self.WorldMatrixInverse = nil

	for _, child in ipairs(self.Owner:GetChildrenList()) do
		local tr = child.transform

		if tr then
			tr.WorldMatrix = nil
			tr.WorldMatrixInverse = nil
		end
	end

	self.Owner:CallLocalEvent("OnTransformChanged")
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

function META:GetWorldBounds(x, y, w, h)
	x = x or 0
	y = y or 0
	w = w or self.Size.x
	h = h or self.Size.y
	local mat = self:GetWorldMatrix()
	local x1, y1 = mat:TransformVectorUnpacked(x, y, 0)
	local x2, y2 = mat:TransformVectorUnpacked(x + w, y, 0)
	local x3, y3 = mat:TransformVectorUnpacked(x, y + h, 0)
	local x4, y4 = mat:TransformVectorUnpacked(x + w, y + h, 0)
	return math.min(x1, x2, x3, x4),
	math.min(y1, y2, y3, y4),
	math.max(x1, x2, x3, x4),
	math.max(y1, y2, y3, y4)
end

function META:GetScrollViewportWorldBounds()
	local viewport_x1, viewport_y1, viewport_x2, viewport_y2
	local found = false
	local parent = self.Owner and self.Owner:GetParent()

	while parent and parent:IsValid() do
		local transform = parent.transform

		if transform and transform:GetScrollEnabled() then
			local x1, y1, x2, y2 = transform:GetWorldBounds(0, 0, transform.Size.x, transform.Size.y)

			if found then
				viewport_x1 = math.max(viewport_x1, x1)
				viewport_y1 = math.max(viewport_y1, y1)
				viewport_x2 = math.min(viewport_x2, x2)
				viewport_y2 = math.min(viewport_y2, y2)
			else
				viewport_x1 = x1
				viewport_y1 = y1
				viewport_x2 = x2
				viewport_y2 = y2
				found = true
			end
		end

		parent = parent:GetParent()
	end

	if not found then return end

	return viewport_x1, viewport_y1, viewport_x2, viewport_y2
end

function META:GetVisibleLocalRect(x, y, w, h)
	x = x or 0
	y = y or 0
	w = w or self.Size.x
	h = h or self.Size.y
	local viewport_x1, viewport_y1, viewport_x2, viewport_y2 = self:GetScrollViewportWorldBounds()

	if not viewport_x1 then return x, y, x + w, y + h, false end

	local inv = self:GetWorldMatrixInverse()
	local lx1, ly1 = inv:TransformVectorUnpacked(viewport_x1, viewport_y1, 0)
	local lx2, ly2 = inv:TransformVectorUnpacked(viewport_x2, viewport_y1, 0)
	local lx3, ly3 = inv:TransformVectorUnpacked(viewport_x1, viewport_y2, 0)
	local lx4, ly4 = inv:TransformVectorUnpacked(viewport_x2, viewport_y2, 0)
	local local_x1 = math.min(lx1, lx2, lx3, lx4)
	local local_y1 = math.min(ly1, ly2, ly3, ly4)
	local local_x2 = math.max(lx1, lx2, lx3, lx4)
	local local_y2 = math.max(ly1, ly2, ly3, ly4)
	local clip_x1 = math.max(x, local_x1)
	local clip_y1 = math.max(y, local_y1)
	local clip_x2 = math.min(x + w, local_x2)
	local clip_y2 = math.min(y + h, local_y2)

	if clip_x2 <= clip_x1 or clip_y2 <= clip_y1 then return nil end

	return clip_x1, clip_y1, clip_x2, clip_y2, true
end

function META:BeginScrollViewportMask(x, y, w, h)
	local clip_x1, clip_y1, clip_x2, clip_y2, masked = self:GetVisibleLocalRect(x, y, w, h)

	if not clip_x1 then return nil end

	if not masked then return false, clip_x1, clip_y1, clip_x2, clip_y2 end

	render2d.PushMatrix()
	render2d.SetWorldMatrix(self:GetWorldMatrix())
	render2d.PushClipRect(clip_x1, clip_y1, clip_x2 - clip_x1, clip_y2 - clip_y1)
	render2d.PopMatrix()
	return true, clip_x1, clip_y1, clip_x2, clip_y2
end

function META:EndScrollViewportMask(masked, clip_x1, clip_y1, clip_x2, clip_y2)
	if not masked then return end

	render2d.PopClip()
end

function META:GetLocalMatrix()
	if not self.LocalMatrix then
		self.LocalMatrix = Matrix44():Identity()
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
			-- In TransformVectorUnpacked: w = z * m23 + m33, then x/w, y/w
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
	end

	return self.LocalMatrix
end

function META:GetWorldMatrix()
	if not self.WorldMatrix then
		local local_mat = self:GetLocalMatrix()
		local parent = self.Owner and self.Owner:GetParent()
		local parent_tr = parent and parent:IsValid() and parent.transform

		if parent_tr then
			local parent_world = parent_tr:GetWorldMatrix()
			self.WorldMatrix = Matrix44()
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
	end

	return self.WorldMatrix
end

function META:GetWorldMatrixInverse()
	if not self.WorldMatrixInverse then
		self.WorldMatrixInverse = self:GetWorldMatrix():GetInverse()
	end

	return self.WorldMatrixInverse
end

function META:GlobalToLocal(vec, out)
	local mat = self:GetWorldMatrixInverse()
	local x, y, z = mat:TransformVectorUnpacked(vec.x, vec.y, vec.z or 0)

	if out then
		out.x = x
		out.y = y
		return out
	end

	return Vec2(x, y)
end

function META:LocalToGlobal(vec, out)
	local mat = self:GetWorldMatrix()
	local x, y, z = mat:TransformVectorUnpacked(vec.x, vec.y, vec.z or 0)

	if out then
		out.x = x
		out.y = y
		return out
	end

	return Vec2(x, y)
end

return META:Register()
