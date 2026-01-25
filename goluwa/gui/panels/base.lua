local event = require("event")
local window = require("window")
local render2d = require("render2d.render2d")
local prototype = require("prototype")
local Matrix44 = require("structs.matrix44")
local Vec2 = require("structs.vec2")
local Vec3 = require("structs.vec3")
local Color = require("structs.color")
local window = require("window")
local render = require("render.render")
local gfx = require("render2d.gfx")
local Rect = require("structs.rect")
local gui = require("gui.gui")
local META = prototype.CreateTemplate("panel_base")
META.IsPanel = true
prototype.ParentingTemplate(META)
assert(loadfile("goluwa/gui/panels/base/layout.lua"))(META)
assert(loadfile("goluwa/gui/panels/base/animations.lua"))(META)
META:StartStorable()
META:GetSet("Position", Vec2(0, 0), {callback = "InvalidateMatrices"})
META:GetSet("Size", Vec2(100, 100), {callback = "OnSizeChanged"})
META:GetSet("Rotation", 0, {callback = "InvalidateMatrices"})
META:GetSet("Scale", Vec2(1, 1), {callback = "InvalidateMatrices"})
META:GetSet("Pivot", Vec2(0.5, 0.5), {callback = "InvalidateMatrices"})
META:GetSet("Visible", true)
META:GetSet("Color", Color(1, 1, 1, 1))
META:GetSet("Clipping", false)
META:GetSet("Shadows", false)
META:GetSet("ShadowSize", 16)
META:GetSet("BorderRadius", 0)
META:GetSet("ShadowColor", Color(0, 0, 0, 0.5))
META:GetSet("ShadowOffset", Vec2(0, 0))
META:GetSet("Scroll", Vec2(0, 0), {callback = "InvalidateMatrices"})
META:GetSet("ScrollEnabled", false)
META:GetSet("DragEnabled", false)
META:GetSet("Margin", Rect(0, 0, 0, 0))
META:GetSet("Padding", Rect(0, 0, 0, 0))
META:GetSet("MinimumSize", Vec2(0, 0))
META:GetSet("IgnoreMouseInput", false)
META:GetSet("FocusOnClick", false)
META:GetSet("BringToFrontOnClick", false)
META:GetSet("Perspective", 0, {callback = "InvalidateMatrices"})
META:GetSet("Texture", nil)
META:GetSet("RedirectFocus", NULL)
META:GetSet("Cursor", "arrow")
META:EndStorable()

function META:CreatePanel(name)
	return gui.Create(name, self)
end

function META:OnReload()
	self:InvalidateMatrices()
	self:InvalidateLayout()
end

function META:OnRemove()
	self:UnParent()
end

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
end

function META:InvalidateMatrices()
	self.LocalMatrixDirty = true
	self:InvalidateWorldMatrices()
end

function META:InvalidateWorldMatrices()
	if self.WorldMatrixDirty then return end

	self.WorldMatrixDirty = true
	self.WorldMatrixInverseDirty = true

	for _, child in ipairs(self:GetChildrenList()) do
		child:InvalidateWorldMatrices()
	end
end

function META:OnSizeChanged()
	self:InvalidateLayout()
	self:InvalidateMatrices()
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
		mouse_pos = mouse_pos or window.GetMousePosition()
		return gui.GetHoveredObject(mouse_pos) == self
	end
end

function META:GetLocalMatrix()
	if self.LocalMatrixDirty or not self.LocalMatrix then
		self.LocalMatrix = self.LocalMatrix or Matrix44()
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
	mouse_pos = mouse_pos or window.GetMousePosition()
	local local_pos = self:GlobalToLocal(mouse_pos)

	if self.Resizable then
		local offset = self.ResizeBorder
		return local_pos.x >= -offset.x and
			local_pos.y >= -offset.y and
			local_pos.x <= self.Size.x + offset.w and
			local_pos.y <= self.Size.y + offset.h
	end

	return local_pos.x >= 0 and
		local_pos.y >= 0 and
		local_pos.x <= self.Size.x and
		local_pos.y <= self.Size.y
end

function META:DrawShadow()
	if not self.Shadows then return end

	render2d.PushMatrix()
	render2d.SetWorldMatrix(self:GetWorldMatrix())
	local s = self.Size + self.DrawSizeOffset
	render2d.SetBlendMode("alpha")
	render2d.SetColor(self.ShadowColor:Unpack())
	gfx.DrawShadow(self.ShadowOffset.x, self.ShadowOffset.y, s.x, s.y, self.ShadowSize, self.BorderRadius)
	render2d.PopMatrix()
end

function META:Draw()
	self:CalcAnimations()
	self:CalcResizing()

	if self.CalcLayout then self:CalcLayout() end

	if not self.Visible then return end

	self:DrawShadow()
	local clipping = self:GetClipping()

	if clipping then
		render2d.PushStencilMask()
		render2d.PushMatrix()
		render2d.SetWorldMatrix(self:GetWorldMatrix())
		render2d.DrawRect(0, 0, self.Size.x, self.Size.y)
		render2d.PopMatrix()
		render2d.BeginStencilTest()
	end

	render2d.PushMatrix()
	render2d.SetWorldMatrix(self:GetWorldMatrix())
	self:OnDraw()

	for _, child in ipairs(self:GetChildren()) do
		child:Draw()
	end

	if clipping then render2d.PopStencilMask() end

	self:OnPostDraw()
	render2d.PopMatrix()
end

function META:GetVisibleChildren()
	local tbl = {}

	for _, v in ipairs(self:GetChildren()) do
		if v.Visible then list.insert(tbl, v) end
	end

	return tbl
end

function META:MouseInput(button, press, pos)
	if self.IgnoreMouseInput then return end

	if press then
		if self.FocusOnClick then self:RequestFocus() end

		if self.BringToFrontOnClick then self:BringToFront() end

		if button == "button_1" then
			if not self.Resizable or not self:StartResizing(nil, button) then
				if self.Draggable then self:StartDragging(button) end
			end
		end
	end

	-- todo, trigger button release events outside of the panel
	self.button_states = self.button_states or {}
	self.button_states[button] = {press = press, pos = pos}
	self:OnMouseInput(button, press, pos)
	self:CallLocalListeners("MouseInput", button, press, pos)
end

function META:IsMouseButtonDown(button)
	self.button_states = self.button_states or {}
	local state = self.button_states[button]
	return state and state.press
end

do -- example events
	function META:OnPostDraw() end

	function META:OnDraw()
		local s = self.Size + self.DrawSizeOffset
		render2d.SetTexture(self.Texture)
		local c = self.Color + self.DrawColor
		render2d.SetColor(c.r, c.g, c.b, c.a * self.DrawAlpha)
		--render2d.DrawRect(0, 0, s.x, s.y)
		gfx.DrawRoundedRect(0, 0, s.x, s.y, self.BorderRadius)
		render2d.SetColor(0, 0, 0, 1)
	end

	function META:OnMouseInput(button, press, pos)
		if self.ScrollEnabled then
			if button == "mwheel_up" then
				local s = self:GetScroll() + Vec2(0, -20)
				self:SetScroll(s)
				return true
			elseif button == "mwheel_down" then
				local s = self:GetScroll() + Vec2(0, 20)
				s.y = math.min(s.y, 0)
				self:SetScroll(s)
				return true
			end
		end
	end
end

do -- focus
	do -- child order
		META:GetSet("ChildOrder", 0)

		function META:BringToFront()
			if self.RedirectFocus:IsValid() then
				return self.RedirectFocus:BringToFront()
			end

			local parent = self:GetParent()

			if parent:IsValid() then
				self:UnParent()
				parent:AddChild(self)
			end
		end

		function META:SendToBack()
			local parent = self:GetParent()

			if parent:IsValid() then
				self:UnParent()
				parent:AddChild(self, 1)
			end
		end

		function META:SetChildOrder(pos)
			self.ChildOrder = pos

			if self:HasParent() then
				list.sort(self.Parent.Children, function(a, b)
					return a.ChildOrder > b.ChildOrder
				end)
			end
		end
	end

	do -- focus
		function META:OnFocus() end

		function META:OnUnfocus() end

		function META:RequestFocus()
			if self.RedirectFocus:IsValid() then self = self.RedirectFocus end

			if gui.focus_panel:IsValid() and gui.focus_panel ~= self then
				gui.focus_panel:OnUnfocus()
			end

			self:OnFocus()
			gui.focus_panel = self
		end

		function META:Unfocus()
			if self.RedirectFocus:IsValid() then self = self.RedirectFocus end

			if gui.focus_panel:IsValid() and gui.focus_panel == self then
				self:OnUnfocus()
				gui.focus_panel = NULL
			end

			self.popup = nil

			if gui.popup_panel == self then gui.popup_panel = NULL end
		end

		function META:IsFocused()
			return gui.focus_panel == self
		end

		function META:MakePopup()
			self.popup = true
			gui.popup_panel = self
		end
	end

	function META:GetMousePosition()
		local mouse_pos = window.GetMousePosition()
		return self:GlobalToLocal(mouse_pos)
	end

	do -- resizing
		META:GetSet("ResizeBorder", Rect(8, 8, 8, 8))
		META:GetSet("Resizable", false)

		function META:GetMouseLocation(pos) -- rename this function
			pos = pos or self:GetMousePosition()
			local offset = self.ResizeBorder
			local siz = self:GetSize()
			local is_top = pos.y > -offset.y and pos.y < offset.y
			local is_bottom = pos.y > siz.y - offset.h and pos.y < siz.y + offset.h
			local is_left = pos.x > -offset.x and pos.x < offset.x
			local is_right = pos.x > siz.x - offset.w and pos.x < siz.x + offset.w

			if is_top and is_left then return "top_left" end

			if is_top and is_right then return "top_right" end

			if is_bottom and is_left then return "bottom_left" end

			if is_bottom and is_right then return "bottom_right" end

			if is_left then return "left" end

			if is_right then return "right" end

			if is_bottom then return "bottom" end

			if is_top then return "top" end

			return "center"
		end

		function META:GetResizeLocation(pos)
			pos = pos or self:GetMousePosition()
			local loc = self:GetMouseLocation(pos)

			if loc ~= "center" then return loc end
		end

		function META:StartResizing(pos, button)
			local loc = self:GetResizeLocation(pos)

			if loc then
				self.resize_start_pos = self:GetMousePosition():Copy()
				self.resize_location = loc
				self.resize_prev_mouse_pos = gui.mouse_pos:Copy()
				self.resize_prev_pos = self:GetPosition():Copy()
				self.resize_prev_size = self:GetSize():Copy()
				self.resize_button = button
				return true
			end
		end

		function META:StopResizing()
			self.resize_start_pos = nil
		end

		function META:IsResizing()
			return self.resize_start_pos ~= nil
		end

		local location2cursor = {
			right = "horizontal_resize",
			left = "horizontal_resize",
			top = "vertical_resize",
			bottom = "vertical_resize",
			top_right = "top_right_resize",
			bottom_left = "bottom_left_resize",
			top_left = "top_left_resize",
			bottom_right = "bottom_right_resize",
		}
		local input = require("input")

		function META:CalcResizing()
			if self.Resizable then
				local loc = self:GetResizeLocation(self:GetMousePosition())

				if location2cursor[loc] then
					self:SetCursor(location2cursor[loc])
				else
					self:SetCursor()
				end
			end

			if self.resize_start_pos then
				if self.resize_button ~= nil and not input.IsMouseDown(self.resize_button) then
					self:StopResizing()
					return
				end

				local diff_world = gui.mouse_pos - self.resize_prev_mouse_pos
				local loc = self.resize_location
				local prev_size = self.resize_prev_size:Copy()
				local prev_pos = self.resize_prev_pos:Copy()

				if loc == "right" or loc == "top_right" or loc == "bottom_right" then
					prev_size.x = math.max(self.MinimumSize.x, prev_size.x + diff_world.x)
				elseif loc == "left" or loc == "top_left" or loc == "bottom_left" then
					local d_x = math.min(diff_world.x, prev_size.x - self.MinimumSize.x)
					prev_pos.x = prev_pos.x + d_x
					prev_size.x = prev_size.x - d_x
				end

				if loc == "bottom" or loc == "bottom_right" or loc == "bottom_left" then
					prev_size.y = math.max(self.MinimumSize.y, prev_size.y + diff_world.y)
				elseif loc == "top" or loc == "top_left" or loc == "top_right" then
					local d_y = math.min(diff_world.y, prev_size.y - self.MinimumSize.y)
					prev_pos.y = prev_pos.y + d_y
					prev_size.y = prev_size.y - d_y
				end

				if self:HasParent() and not self.ThreeDee then
					prev_pos.x = math.max(prev_pos.x, 0)
					prev_pos.y = math.max(prev_pos.y, 0)
					prev_size.x = math.min(prev_size.x, self.Parent.Size.x - prev_pos.x)
					prev_size.y = math.min(prev_size.y, self.Parent.Size.y - prev_pos.y)
				end

				self:SetPosition(prev_pos)
				self:SetSize(prev_size)

				if self.LayoutSize then self:SetLayoutSize(prev_size:Copy()) end
			end
		end
	end

	do -- key input
		function META:OnPreKeyInput(key, press) end

		function META:OnKeyInput(key, press) end

		function META:OnPostKeyInput(key, press) end

		function META:OnCharInput(key, press) end

		function META:KeyInput(button, press)
			local b

			if self:OnPreKeyInput(button, press) ~= false then
				b = self:OnKeyInput(button, press)
				self:OnPostKeyInput(button, press)
			end

			return b
		end

		function META:CharInput(char)
			return self:OnCharInput(char)
		end
	end
end

return META:Register()
