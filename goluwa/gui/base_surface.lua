local event = require("event")
local render2d = require("render2d.render2d")
local prototype = require("prototype")
local Matrix44 = require("structs.matrix44")
local Vec2 = require("structs.vec2")
local Vec3 = require("structs.vec3")
local Color = require("structs.color")
local window = require("window")
local Rect = require("structs.rect")
local META = prototype.CreateTemplate("surface_base")
META.IsSurface = true
prototype.ParentingTemplate(META)
assert(loadfile("goluwa/gui/base_surface_layout.lua"))(META)
assert(loadfile("goluwa/gui/base_surface_animations.lua"))(META)
META:StartStorable()
META:GetSet("Position", Vec2(0, 0), {callback = "InvalidateMatrices"})
META:GetSet("Size", Vec2(100, 100), {callback = "InvalidateLayout"})
META:GetSet("Rotation", 0, {callback = "InvalidateMatrices"})
META:GetSet("Scale", Vec2(1, 1), {callback = "InvalidateMatrices"})
META:GetSet("Visible", true)
META:GetSet("Color", Color(1, 1, 1, 1))
META:GetSet("Clipping", false)
META:GetSet("Scroll", Vec2(0, 0), {callback = "InvalidateMatrices"})
META:GetSet("ScrollEnabled", false)
META:GetSet("DragEnabled", false)
META:GetSet("Margin", Rect(0, 0, 0, 0))
META:GetSet("Padding", Rect(0, 0, 0, 0))
META:GetSet("MinimumSize", Vec2(0, 0))
META:EndStorable()

function META:SetColor(c)
	if type(c) == "string" then
		self.Color = Color.FromHex(c)
	else
		self.Color = c
	end
end

function META:IsWorld()
	return self.Name == "Root"
end

function META:Initialize()
	self.LocalMatrix = Matrix44()
	self.LocalMatrix:Identity()
	self.animations = {}
end

function META:InvalidateMatrices()
	self.LocalMatrixDirty = true
	self.WorldMatrixDirty = true
	self.WorldMatrixInverseDirty = true

	for _, child in ipairs(self:GetChildrenList()) do
		child.WorldMatrixDirty = true
		child.WorldMatrixInverseDirty = true
	end
end

function META:InvalidateLayout()
	if self.layout_me then return end

	self.layout_me = true

	if self:HasParent() then self:GetParent():InvalidateLayout() end
end

function META:GetWidth()
	return self.Size.x
end

function META:GetHeight()
	return self.Size.y
end

function META:SetWidth(w)
	self.Size.x = w
	self:InvalidateLayout()
end

function META:SetHeight(h)
	self.Size.y = h
	self:InvalidateLayout()
end

function META:GetX()
	return self.Position.x
end

function META:GetY()
	return self.Position.y
end

function META:SetX(x)
	self.Position.x = x
	self:InvalidateMatrices()
end

function META:SetY(y)
	self.Position.y = y
	self:InvalidateMatrices()
end

function META:GetWorldRectFast()
	local mat = self:GetWorldMatrix()
	local x, y = mat:GetTranslation()
	return x, y, x + self.Size.x, y + self.Size.y
end

function META:GetParentPadding()
	if self:HasParent() then return self:GetParent():GetPadding() end

	return Rect(0, 0, 0, 0)
end

do
	local gui = require("gui.gui")

	function META:IsHoveredExclusively(mouse_pos)
		return gui.GetHoveredObject(mouse_pos) == self
	end
end

function META:GetLocalMatrix()
	if self.LocalMatrixDirty or not self.LocalMatrix then
		self.LocalMatrix = self.LocalMatrix or Matrix44()
		-- Construct Local Matrix: S * R * T
		self.LocalMatrix:Identity()

		-- Apply Rotation (Z axis)
		if self.Rotation ~= 0 then
			self.LocalMatrix:Rotate(math.rad(self.Rotation), 0, 0, 1)
		end

		-- Apply Scale
		if self.Scale.x ~= 1 or self.Scale.y ~= 1 then
			self.LocalMatrix:Scale(self.Scale.x, self.Scale.y, 1)
		end

		-- Apply Translation
		self.LocalMatrix:SetTranslation(self.Position.x, self.Position.y, 0)
		self.LocalMatrixDirty = false
	end

	return self.LocalMatrix
end

function META:GetWorldMatrix()
	if self.WorldMatrixDirty or not self.WorldMatrix then
		local local_mat = self:GetLocalMatrix()

		if self:HasParent() and self:GetParent().GetWorldMatrix then
			local parent = self:GetParent()
			local parent_world = parent:GetWorldMatrix()
			self.WorldMatrix = self.WorldMatrix or Matrix44()
			local scroll = parent:GetScroll()

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

function META:IsHovered(mouse_pos)
	local local_pos = self:GlobalToLocal(mouse_pos)
	return local_pos.x >= 0 and
		local_pos.y >= 0 and
		local_pos.x <= self.Size.x and
		local_pos.y <= self.Size.y
end

function META:Draw()
	self:CalcAnimations()

	if self.CalcLayout then self:CalcLayout() end

	if not self.Visible then return end

	local clipping = self:GetClipping()

	if clipping then
		local mat = self:GetWorldMatrix()
		local x1, y1 = mat:TransformVector(0, 0, 0)
		local x2, y2 = mat:TransformVector(self.Size.x, self.Size.y, 0)
		-- Clamp negative coordinates and adjust width/height
		local clamped_x1 = math.max(0, x1)
		local clamped_y1 = math.max(0, y1)
		local width = (x2 - x1) - (clamped_x1 - x1)
		local height = (y2 - y1) - (clamped_y1 - y1)
		render2d.PushScissor(clamped_x1, clamped_y1, width, height)
	end

	render2d.PushMatrix()
	render2d.SetWorldMatrix(self:GetWorldMatrix())
	self:OnDraw()

	for _, child in ipairs(self:GetChildren()) do
		child:Draw()
	end

	render2d.PopMatrix()

	if clipping then render2d.PopScissor() end
end

function META:GetVisibleChildren()
	local tbl = {}

	for _, v in ipairs(self:GetChildren()) do
		if v.Visible then list.insert(tbl, v) end
	end

	return tbl
end

function META:MouseInput(button, press, pos)
	-- todo, trigger button release events outside of the panel
	self.button_states = self.button_states or {}
	self.button_states[button] = {press = press, pos = pos}
	self:OnMouseInput(button, press, pos)
	self:CallLocalListeners("MouseInput", button, press, pos)
end

function META:IsMouseButtonDown(button)
	self.button_states = self.button_states or {}
	local state = self.button_states[button]
	table.print(self.button_states)
	return state and state.press
end

do -- example events
	function META:OnDraw()
		render2d.SetTexture(nil)
		render2d.SetColor(self.Color:Unpack())
		render2d.DrawRect(0, 0, self.Size.x, self.Size.y)
	end

	function META:OnMouseInput(button, press, pos)
		if self.ScrollEnabled then
			if button == "mwheel_up" then
				local s = self:GetScroll()
				self:SetScroll(Vec2(s.x, s.y - 20))
				return true
			elseif button == "mwheel_down" then
				local s = self:GetScroll()
				self:SetScroll(Vec2(s.x, s.y + 20))
				return true
			end
		end
	end
end

return META:Register()
