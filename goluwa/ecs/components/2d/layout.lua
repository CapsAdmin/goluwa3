local prototype = require("prototype")
local Vec2 = require("structs.vec2")
local Rect = require("structs.rect")
local event = require("event")
local render2d = require("render2d.render2d")
local gui_element = require("ecs.components.2d.gui_element")
local layout_lib = library()
local META = prototype.CreateTemplate("layout")
META.layout_count = 0
META:StartStorable()
META:GetSet("Layout", nil, {callback = "InvalidateLayout"})
META:GetSet("MinimumSize", Vec2(0, 0), {callback = "InvalidateLayout"})
META:GetSet("Margin", Rect(0, 0, 0, 0), {callback = "InvalidateLayout"})
META:GetSet("Padding", Rect(0, 0, 0, 0), {callback = "InvalidateLayout"})
META:GetSet("LayoutSize", nil)
META:GetSet("IgnoreLayout", false, {callback = "InvalidateLayout"})
META:GetSet("LayoutUs", false, {callback = "InvalidateLayout"})
META:GetSet("CollisionGroup", "none")
META:GetSet("OthersAlwaysCollide", false)
META:GetSet("ThreeDee", false, {callback = "InvalidateLayout"})
META:GetSet("LayoutWhenInvisible", false, {callback = "InvalidateLayout"})
-- Flex properties
META:GetSet("Flex", false, {callback = "InvalidateLayout"})
META:GetSet("FlexDirection", "row", {callback = "InvalidateLayout"})
META:GetSet("FlexGap", 0, {callback = "InvalidateLayout"})
META:GetSet("FlexJustifyContent", "start", {callback = "InvalidateLayout"})
META:GetSet("FlexAlignItems", "start", {callback = "InvalidateLayout"})
META:GetSet("FlexAlignSelf", "start", {callback = "InvalidateLayout"})
-- Stacking
META:GetSet("Stack", false, {callback = "InvalidateLayout"})
META:GetSet("ForcedStackSize", Vec2(0, 0), {callback = "InvalidateLayout"})
META:GetSet("StackRight", true, {callback = "InvalidateLayout"})
META:GetSet("StackDown", true, {callback = "InvalidateLayout"})
META:GetSet("SizeStackToWidth", false, {callback = "InvalidateLayout"})
META:GetSet("SizeStackToHeight", false, {callback = "InvalidateLayout"})
META:GetSet("Stackable", true, {callback = "InvalidateLayout"})
META:GetSet("StackSizeToChildren", false, {callback = "InvalidateLayout"})
META:EndStorable()

function layout_lib.IsRunning()
	return (layout_lib.depth or 0) > 0
end

function META:IsBusy()
	return (self.recursion_depth or 0) > 0
end

function META:EnterLayout()
	self.recursion_depth = (self.recursion_depth or 0) + 1
	layout_lib.depth = (layout_lib.depth or 0) + 1
end

function META:ExitLayout()
	self.recursion_depth = self.recursion_depth - 1
	layout_lib.depth = layout_lib.depth - 1
end

function META:Initialize()
	self.Owner:AddLocalListener("OnParent", function()
		self:InvalidateLayout()
	end)

	self.Owner:AddLocalListener("OnTransformChanged", function()
		self:InvalidateLayout()

		if
			not layout_lib.IsRunning() and
			not self:IsBusy()
			and
			self.Owner and
			self.Owner.transform
		then
			self:SetLayoutSize(self.Owner.transform:GetSize():Copy())
		end
	end)

	self:InvalidateLayout()
end

function META:GetParentPadding()
	local parent = self.Owner:GetParent()

	if parent and parent:IsValid() then
		local layout = parent.layout

		if layout then return layout:GetPadding() end
	end

	return Rect(0, 0, 0, 0)
end

function META:InvalidateLayout()
	if self.LayoutInvalidated then return end

	self.LayoutInvalidated = true
	local tr_trace

	if layout_lib.debug then
		tr_trace = debug.traceback()
		self.LayoutInvalidated_tr = tr_trace
	end

	for _, parent in ipairs(self.Owner:GetParentList()) do
		local layout = parent.layout

		if layout then
			if layout:IsBusy() then break end

			if not layout.LayoutInvalidated then
				layout.LayoutInvalidated = true
				layout.LayoutInvalidated_tr = tr_trace
			end
		end
	end
end

function META:SetNocollide(b)
	if type(b) == "table" then
		for _, dir in ipairs(b) do
			self:NoCollide(dir)
		end
	elseif type(b) == "string" then
		self:NoCollide(b)
	else
		self.nocollide = b
	end
end

local origin

local function sort(a, b)
	return math.abs(a.point - origin) < math.abs(b.point - origin)
end

function META:RayCast(start_pos, stop_pos)
	local entity = self.Owner
	local parent = entity:GetParent()

	if not parent or not parent:IsValid() then return stop_pos end

	local dir = stop_pos - start_pos
	local found = {}
	local i = 1
	local a_lft, a_top, a_rgt, a_btm = start_pos.x, start_pos.y, start_pos.x + self:GetWidth(), start_pos.y + self:GetHeight()

	for _, b in ipairs(parent:GetChildren()) do
		local b_layout = b.layout
		local b_tr = b.transform
		local b_gui = b.gui_element

		if
			b ~= entity and
			b_tr and
			(
				not b_layout or
				not b_layout.nocollide
			)
			and
			(
				not b_gui or
				b_gui:GetVisible()
			)
			and
			(
				(
					b.laid_out_x == nil or
					b.laid_out_x == true
				)
				or
				(
					b.laid_out_y == nil or
					b.laid_out_y == true
				)
			)
			and
			(
				not b_layout or
				not b_layout:GetThreeDee()
			)
			and
			(
				not b_layout or
				not b_layout:GetIgnoreLayout()
			)
			and
			(
				not b_layout or
				self:GetCollisionGroup() == b_layout:GetCollisionGroup()
				or
				b_layout:GetOthersAlwaysCollide()
			)
		then
			local b_lft, b_top, b_rgt, b_btm = b_tr:GetWorldRectFast()

			if
				(
					b_lft <= a_lft and
					b_rgt >= a_rgt
				)
				or
				(
					b_lft >= a_lft and
					b_rgt <= a_rgt
				)
				or
				(
					b_rgt > a_rgt and
					b_lft < a_rgt
				)
				or
				(
					b_rgt > a_lft and
					b_lft < a_lft
				)
			then
				if dir.y > 0 and b_top > a_top and (not b_layout or not b_layout.nocollide_up) then
					found[i] = {child = b, point = b_top}
					i = i + 1
				elseif dir.y < 0 and b_btm < a_btm and (not b_layout or not b_layout.nocollide_down) then
					found[i] = {child = b, point = b_btm}
					i = i + 1
				end
			end

			if
				(
					b_top <= a_top and
					b_btm >= a_btm
				)
				or
				(
					b_top >= a_top and
					b_btm <= a_btm
				)
				or
				(
					b_btm > a_btm and
					b_top < a_btm
				)
				or
				(
					b_btm > a_top and
					b_top < a_top
				)
			then
				if dir.x > 0 and b_rgt > a_rgt and (not b_layout or not b_layout.nocollide_left) then
					found[i] = {child = b, point = b_lft}
					i = i + 1
				elseif dir.x < 0 and b_lft < a_lft and (not b_layout or not b_layout.nocollide_right) then
					found[i] = {child = b, point = b_rgt}
					i = i + 1
				end
			end
		end
	end

	if dir.y > 0 then
		origin = a_btm
	elseif dir.y < 0 then
		origin = a_top
	elseif dir.x > 0 then
		origin = a_rgt
	elseif dir.x < 0 then
		origin = a_lft
	end

	table.sort(found, sort)
	local hit_pos = stop_pos:Copy()

	if found and found[1] then
		local child = found[1].child
		local child_tr = child.transform
		local child_layout = child.layout
		hit_pos = child_tr:GetPosition():Copy()

		if dir.x < 0 then
			hit_pos.y = entity.transform:GetY()
			hit_pos.x = hit_pos.x + (
					child_layout and
					child_layout:GetWidth() or
					child_tr:GetWidth()
				) + self:GetMargin():GetLeft() + (
					child_layout and
					child_layout:GetMargin():GetRight() or
					0
				)
		elseif dir.x > 0 then
			hit_pos.y = entity.transform:GetY()
			hit_pos.x = hit_pos.x - self:GetWidth() - self:GetMargin():GetRight() - (
					child_layout and
					child_layout:GetMargin():GetLeft() or
					0
				)
		elseif dir.y < 0 then
			hit_pos.x = entity.transform:GetX()
			hit_pos.y = hit_pos.y + (
					child_layout and
					child_layout:GetHeight() or
					child_tr:GetHeight()
				) + self:GetMargin():GetTop() + (
					child_layout and
					child_layout:GetMargin():GetBottom() or
					0
				)
		elseif dir.y > 0 then
			hit_pos.x = entity.transform:GetX()
			hit_pos.y = hit_pos.y - self:GetHeight() - self:GetMargin():GetBottom() - (
					child_layout and
					child_layout:GetMargin():GetTop() or
					0
				)
		end
	else
		if dir.x < 0 then
			hit_pos.x = hit_pos.x + self:GetMargin():GetLeft()
			hit_pos.x = hit_pos.x + self:GetParentPadding():GetLeft()
		elseif dir.x > 0 then
			hit_pos.x = hit_pos.x - self:GetMargin():GetRight()
			hit_pos.x = hit_pos.x - self:GetParentPadding():GetRight()
		elseif dir.y < 0 then
			hit_pos.y = hit_pos.y + self:GetMargin():GetTop()
			hit_pos.y = hit_pos.y + self:GetParentPadding():GetTop()
		elseif dir.y > 0 then
			hit_pos.y = hit_pos.y - self:GetMargin():GetBottom()
			hit_pos.y = hit_pos.y - self:GetParentPadding():GetBottom()
		end

		hit_pos.x = math.max(hit_pos.x, 0)
		hit_pos.y = math.max(hit_pos.y, 0)
	end

	return hit_pos, found and found[1] and found[1].child
end

function META:ExecuteLayoutCommands()
	for _, child in ipairs(self.Owner:GetChildren()) do
		local child_layout = child.layout

		if child_layout and child_layout:GetLayout() then
			if not child_layout:GetLayoutSize() then
				child_layout:SetLayoutSize(child.transform:GetSize():Copy())
			end

			child.transform:SetSize(child_layout:GetLayoutSize():Copy())
			child.laid_out_x = false
			child.laid_out_y = false
			child_layout:Confine()
		end
	end

	for _, child in ipairs(self.Owner:GetChildren()) do
		local child_layout = child.layout

		if child_layout and child_layout:GetLayout() then
			for _, cmd in ipairs(child_layout:GetLayout()) do
				if type(cmd) == "table" and cmd.IsValid then
					child.last_layout_panel = cmd
				else
					if type(cmd) == "string" then
						if cmd == "LayoutChildren" then
							self:LayoutChildren()
						elseif child_layout[cmd] then
							child_layout[cmd](child_layout)
						elseif self[cmd] then
							self[cmd](self)
						end
					elseif type(cmd) == "function" then
						cmd(child, self.Owner)
					elseif typex(cmd) == "vec2" then
						child.transform:SetSize(cmd:Copy())
					end

					child.last_layout_panel = nil
				end
			end

			child.laid_out_x = true
			child.laid_out_y = true
		end
	end

	for _, child in ipairs(self.Owner:GetChildren()) do
		local child_layout = child.layout

		if child_layout and child_layout:GetLayout() then
			for _, cmd in ipairs(child_layout:GetLayout()) do
				if cmd == "gmod_fill" then
					child_layout:SetLayoutSize(Vec2(1, 1))
					child_layout:CenterSimple()
					child_layout:FillX()
					child_layout:FillY()
					child_layout:NoCollide()
				end
			end
		end
	end
end

function META:OnLayout() end

function META:DoLayout()
	self:EnterLayout()
	self:OnLayout()

	if self:GetFlex() then self:FlexLayout() end

	self:ExecuteLayoutCommands()

	if self:GetStack() then
		local size = self:StackChildren()

		if self:GetStackSizeToChildren() then self.Owner.transform:SetSize(size) end
	end

	self:ExitLayout()
end

function META:CalcLayoutInternal()
	if self:IsBusy() then return end

	local gui = self.Owner.gui_element
	local visible = not gui or gui:GetVisible()

	if not (self:GetLayoutWhenInvisible() or visible) then return end

	local tr_comp = self.Owner.transform
	local old_size = tr_comp and tr_comp.Size:Copy()
	local old_pos = tr_comp and tr_comp.Position:Copy()
	self:EnterLayout()

	if layout_lib.debug then
		local tr = self.LayoutInvalidated_tr or "unknown"
		layout_lib.layout_traces[tr] = (layout_lib.layout_traces[tr] or 0) + 1
		self.LayoutInvalidated_tr = nil
	end

	self:DoLayout()
	self.updated_layout = (self.updated_layout or 0) + 1
	self.layout_count = (self.layout_count or 0) + 1
	self.last_children_size = nil
	self.LayoutInvalidated = false
	self:ExitLayout()

	if tr_comp and (not (tr_comp.Size == old_size) or not (tr_comp.Position == old_pos)) then
		self:InvalidateLayout()
	end
end

function META:CalcLayout()
	if self.LayoutInvalidated or layout_lib.layout_stress then
		self:CalcLayoutInternal()
	end
end

local function compare_layouts(tbl1, tbl2)
	if tbl1 == tbl2 then return true end

	if not tbl1 or not tbl2 then return false end

	if #tbl1 ~= #tbl2 then return false end

	for i = 1, #tbl1 do
		if tbl1[i] ~= tbl2[i] then return false end
	end

	return true
end

function META:SetLayout(...)
	local commands = ...

	if select("#", ...) > 1 then
		commands = {...}
	elseif commands ~= nil and type(commands) ~= "table" then
		commands = {commands}
	end

	if compare_layouts(self:GetLayout(), commands) then return end

	if commands then
		self.Layout = commands
		local parent = self.Owner:GetParent()

		if parent and parent:IsValid() then
			local p_layout = parent.layout

			if p_layout then p_layout:SetLayoutUs(true) end
		end
	else
		self.Layout = nil
		self:SetLayoutSize(nil)
		local parent = self.Owner:GetParent()

		if parent and parent:IsValid() then
			local p_layout = parent.layout

			if p_layout then p_layout:SetLayoutUs(false) end
		end
	end

	local parent = self.Owner:GetParent()

	if parent and parent:IsValid() then
		local p_layout = parent.layout

		if p_layout then p_layout:CalcLayoutInternal() end
	end

	self:CalcLayoutInternal()
end

-- Layout Helpers
function META:ResetLayout()
	self.Owner.laid_out_x = false
	self.Owner.laid_out_y = false

	for _, child in ipairs(self.Owner:GetChildren()) do
		local child_layout = child.layout

		if child_layout then
			if child_layout:GetLayoutSize() then
				child.transform:SetSize(child_layout:GetLayoutSize():Copy())
			end

			child.laid_out_x = false
			child.laid_out_y = false
		end
	end
end

function META:ResetLayoutSize()
	self:SetLayoutSize(self.Owner.transform:GetSize():Copy())
end

function META:Collide()
	self.nocollide = false
	self.nocollide_up = false
	self.nocollide_down = false
	self.nocollide_left = false
	self.nocollide_right = false
end

function META:NoCollide(dir)
	if dir then self["nocollide_" .. dir] = true else self.nocollide = true end
end

function META:LayoutChildren()
	for _, child in ipairs(self.Owner:GetChildren()) do
		local child_layout = child.layout

		if child_layout then child_layout:CalcLayoutInternal() end
	end
end

function META:Confine()
	local parent = self.Owner:GetParent()

	if not parent or not parent:IsValid() then return end

	local p_layout = parent.layout
	local parent_padding = p_layout and p_layout:GetPadding() or Rect(0, 0, 0, 0)
	local margin = self:GetMargin()
	local tr = self.Owner.transform
	local p_tr = parent.transform

	if not p_tr then return end

	local pw = p_layout and p_layout:GetWidth() or p_tr:GetWidth()
	local ph = p_layout and p_layout:GetHeight() or p_tr:GetHeight()
	tr:SetPosition(
		Vec2(
			math.clamp(
				tr.Position.x,
				parent_padding:GetLeft() + margin:GetLeft(),
				pw - self:GetWidth() - parent_padding:GetRight() - margin:GetRight()
			),
			math.clamp(
				tr.Position.y,
				parent_padding:GetTop() + margin:GetTop(),
				ph - self:GetHeight() - parent_padding:GetBottom() - margin:GetBottom()
			)
		)
	)
end

function META:NoCollide(dir)
	if dir then self["nocollide_" .. dir] = true else self.nocollide = true end
end

function META:Fill()
	self:CenterSimple()
	self:FillX()
	self:FillY()
end

function META:FillX(percent)
	local parent = self.Owner:GetParent()

	if not parent or not parent:IsValid() then return end

	local p_tr = parent.transform
	local p_layout = parent.layout
	local parent_width = p_layout and p_layout:GetWidth() or p_tr:GetWidth()
	local tr = self.Owner.transform
	tr:SetWidth(1)
	local left, left_child = self:RayCast(tr:GetPosition(), Vec2(0, tr.Position.y))
	local right, right_child = self:RayCast(tr:GetPosition(), Vec2(parent_width, tr.Position.y))

	if right_child then right.x = right.x + 1 end

	if left.x > right.x then left, right = right, left end

	right.x = math.clamp(right.x, 0, parent_width)
	left.x = math.clamp(left.x, 0, parent_width)
	right.x = right.x - left.x
	local x = left.x
	local w = right.x
	local min_width = self:GetMinimumSize().x

	if percent then
		x = math.max(math.lerp(percent * 0.5, left.x, right.x + tr:GetWidth()), min_width) - min_width + left.x
		w = w - x * 2 + left.x * 2

		if w < min_width then
			x = -left.x
			w = right.x
		end
	end

	tr:SetX(math.max(x, left.x))
	tr:SetWidth(math.max(w, min_width))
	self.Owner.laid_out_x = true
end

function META:FillY(percent)
	local parent = self.Owner:GetParent()

	if not parent or not parent:IsValid() then return end

	local p_tr = parent.transform
	local p_layout = parent.layout
	local parent_height = p_layout and p_layout:GetHeight() or p_tr:GetHeight()
	local tr = self.Owner.transform
	tr:SetHeight(1)
	local top, top_child = self:RayCast(tr:GetPosition(), Vec2(tr.Position.x, 0))
	local bottom, bottom_child = self:RayCast(tr:GetPosition(), Vec2(tr.Position.x, parent_height))

	if bottom_child then bottom.y = bottom.y + 1 end

	if top.y > bottom.y then top, bottom = bottom, top end

	bottom.y = math.clamp(bottom.y, 0, parent_height)
	top.y = math.clamp(top.y, 0, parent_height)
	bottom.y = bottom.y - top.y
	local y = top.y
	local h = bottom.y
	local min_height = self:GetMinimumSize().y

	if percent then
		y = math.max(math.lerp(percent, top.y, bottom.y + tr:GetHeight()), min_height / 2) - min_height / 2 + top.y
		h = h - y * 2 + top.y * 2

		if h < min_height then
			y = -top.y
			h = bottom.y
		end
	end

	tr:SetY(math.max(y, top.y))
	tr:SetHeight(math.max(h, min_height))
	self.Owner.laid_out_y = true
end

function META:CenterX()
	self:CenterXSimple()
	local parent = self.Owner:GetParent()

	if not parent or not parent:IsValid() then return end

	local p_tr = parent.transform
	local p_layout = parent.layout
	local width = p_layout and p_layout:GetWidth() or p_tr:GetWidth()
	local tr = self.Owner.transform
	local left, left_child = self:RayCast(tr:GetPosition(), Vec2(0, tr.Position.y))
	local right, right_child = self:RayCast(tr:GetPosition(), Vec2(width, left.y))

	if right_child then
		local rc_tr = right_child.transform
		local rc_layout = right_child.layout
		right.x = right.x + self:GetWidth() + self:GetMargin():GetRight() + (
				rc_layout and
				rc_layout:GetMargin():GetLeft() or
				0
			)
	end

	tr:SetX(
		(
				left.x + right.x
			) / 2 - self:GetWidth() / 2 - self:GetMargin():GetLeft() + self:GetMargin():GetRight()
	)
	self.Owner.laid_out_x = true
end

function META:CenterY()
	local parent = self.Owner:GetParent()

	if not parent or not parent:IsValid() then return end

	local p_tr = parent.transform
	local p_layout = parent.layout
	local height = p_layout and p_layout:GetHeight() or p_tr:GetHeight()
	local tr = self.Owner.transform
	local top, top_child = self:RayCast(tr:GetPosition(), Vec2(tr.Position.x, 0))
	local bottom, bottom_child = self:RayCast(tr:GetPosition(), Vec2(top.x, height))

	if bottom_child then
		local bc_tr = bottom_child.transform
		local bc_layout = bottom_child.layout
		bottom.y = bottom.y + self:GetHeight() + self:GetMargin():GetBottom() + (
				bc_layout and
				bc_layout:GetMargin():GetTop() or
				0
			)
	end

	tr:SetY(
		(
				top.y + bottom.y
			) / 2 - self:GetHeight() / 2 - self:GetMargin():GetTop() + self:GetMargin():GetBottom()
	)
	self.Owner.laid_out_y = true
end

function META:CenterXSimple()
	local parent = self.Owner:GetParent()

	if not parent or not parent:IsValid() then return end

	local p_tr = parent.transform
	local p_layout = parent.layout
	local tr = self.Owner.transform
	tr:SetX((p_layout and p_layout:GetWidth() or p_tr:GetWidth()) / 2 - self:GetWidth() / 2)
	self.Owner.laid_out_x = true
end

function META:CenterYSimple()
	local parent = self.Owner:GetParent()

	if not parent or not parent:IsValid() then return end

	local p_tr = parent.transform
	local p_layout = parent.layout
	local tr = self.Owner.transform
	tr:SetY((p_layout and p_layout:GetHeight() or p_tr:GetHeight()) / 2 - self:GetHeight() / 2)
	self.Owner.laid_out_y = true
end

function META:CenterSimple()
	self:CenterXSimple()
	self:CenterYSimple()
end

function META:Center()
	self:CenterX()
	self:CenterY()
end

function META:CenterXFrame()
	local parent = self.Owner:GetParent()

	if not parent or not parent:IsValid() then return end

	local tr = self.Owner.transform
	local p_tr = parent.transform
	local p_layout = parent.layout
	local left = self:RayCast(tr:GetPosition(), Vec2(0, tr.Position.y))
	local right = self:RayCast(
		tr:GetPosition(),
		Vec2(p_layout and p_layout:GetWidth() or p_tr:GetWidth(), left.y)
	)

	if
		tr:GetX() + self:GetWidth() + self:GetMargin():GetRight() < right.x + self:GetWidth() - self:GetMargin():GetRight()
		and
		tr:GetX() - self:GetMargin().x > left.x
	then
		tr:SetX((p_layout and p_layout:GetWidth() or p_tr:GetWidth()) / 2 - self:GetWidth() / 2)
	end

	self.Owner.laid_out_x = true
end

function META:CenterFillX()
	self:CenterXSimple()
	self:FillX()
end

function META:CenterFillY()
	self:CenterYSimple()
	self:FillY()
end

function META:CenterLeft()
	self:MoveLeft()
	self:CenterYSimple()
end

function META:CenterRight()
	self:MoveRight()
	self:CenterYSimple()
end

function META:GmodLeft()
	self:SetCollisionGroup("gmod")
	self:CenterYSimple()
	self:MoveLeft()
	self:FillY()
	self:NoCollide("left")
end

function META:GmodRight()
	self:SetCollisionGroup("gmod")
	self:CenterYSimple()
	self:MoveRight()
	self:FillY()
	self:NoCollide("right")
end

function META:GmodTop()
	self:SetCollisionGroup("gmod")
	self:CenterXSimple()
	self:MoveUp()
	self:FillX()
	self:NoCollide("up")
end

function META:GmodBottom()
	self:SetCollisionGroup("gmod")
	self:CenterXSimple()
	self:MoveDown()
	self:FillX()
	self:NoCollide("down")
end

function META:MoveUp()
	if self.Owner.last_layout_panel then
		self:MoveUpOf(self.Owner.last_layout_panel)
		return
	end

	local tr = self.Owner.transform
	tr:SetY(999999)
	tr:SetY(self:RayCast(tr:GetPosition(), Vec2(tr:GetX(), 0)).y)
	self.Owner.laid_out_y = true
end

function META:MoveDown()
	if self.Owner.last_layout_panel then
		self:MoveDownOf(self.Owner.last_layout_panel)
		return
	end

	local parent = self.Owner:GetParent()

	if not parent or not parent:IsValid() then return end

	local p_tr = parent.transform
	local p_layout = parent.layout
	local tr = self.Owner.transform
	tr:SetY(-999999)
	tr:SetY(self:RayCast(
			tr:GetPosition(),
			Vec2(
				tr:GetX(),
				(p_layout and p_layout:GetHeight() or p_tr:GetHeight()) - self:GetHeight()
			)
		).y)
	self.Owner.laid_out_y = true
end

function META:MoveLeft()
	if self.Owner.last_layout_panel then
		self:MoveLeftOf(self.Owner.last_layout_panel)
		return
	end

	local tr = self.Owner.transform
	tr:SetX(999999)
	tr:SetX(self:RayCast(tr:GetPosition(), Vec2(0, tr.Position.y)).x)
	self.Owner.laid_out_x = true
end

function META:MoveRight()
	if self.Owner.last_layout_panel then
		self:MoveRightOf(self.Owner.last_layout_panel)
		return
	end

	local parent = self.Owner:GetParent()

	if not parent or not parent:IsValid() then return end

	local p_tr = parent.transform
	local p_layout = parent.layout
	local tr = self.Owner.transform
	tr:SetX(-999999)
	tr:SetX(self:RayCast(
			tr:GetPosition(),
			Vec2(
				(p_layout and p_layout:GetWidth() or p_tr:GetWidth()) - self:GetWidth(),
				tr.Position.y
			)
		).x)
	self.Owner.laid_out_x = true
end

function META:MoveRightOf(panel)
	panel = panel or self.Owner.last_layout_panel

	if not panel then return end

	local tr = self.Owner.transform
	local p_tr = panel.transform
	local p_layout = panel.layout
	local p_margin = p_layout and p_layout:GetMargin() or Rect(0, 0, 0, 0)
	tr:SetY(p_tr:GetY())
	tr:SetX(
		p_tr:GetX() + (
				p_layout and
				p_layout:GetWidth() or
				p_tr:GetWidth()
			) + p_margin:GetRight() + self:GetMargin():GetLeft()
	)
	self.Owner.laid_out_x = true
	self.Owner.laid_out_y = true
end

function META:MoveDownOf(panel)
	panel = panel or self.Owner.last_layout_panel

	if not panel then return end

	local tr = self.Owner.transform
	local p_tr = panel.transform
	local p_layout = panel.layout
	local p_margin = p_layout and p_layout:GetMargin() or Rect(0, 0, 0, 0)
	tr:SetX(p_tr:GetX())
	tr:SetY(
		p_tr:GetY() + (
				p_layout and
				p_layout:GetHeight() or
				p_tr:GetHeight()
			) + p_margin:GetBottom() + self:GetMargin():GetTop()
	)
	self.Owner.laid_out_x = true
	self.Owner.laid_out_y = true
end

function META:MoveLeftOf(panel)
	panel = panel or self.Owner.last_layout_panel

	if not panel then return end

	local tr = self.Owner.transform
	local p_tr = panel.transform
	local p_layout = panel.layout
	local p_margin = p_layout and p_layout:GetMargin() or Rect(0, 0, 0, 0)
	tr:SetY(p_tr:GetY())
	tr:SetX(p_tr:GetX() - self:GetWidth() - p_margin:GetLeft() - self:GetMargin():GetRight())
	self.Owner.laid_out_x = true
	self.Owner.laid_out_y = true
end

function META:MoveUpOf(panel)
	panel = panel or self.Owner.last_layout_panel

	if not panel then return end

	local tr = self.Owner.transform
	local p_tr = panel.transform
	local p_layout = panel.layout
	local p_margin = p_layout and p_layout:GetMargin() or Rect(0, 0, 0, 0)
	tr:SetX(p_tr:GetX())
	tr:SetY(p_tr:GetY() - self:GetHeight() - p_margin:GetTop() - self:GetMargin():GetBottom())
	self.Owner.laid_out_x = true
	self.Owner.laid_out_y = true
end

function META:SetAxisPosition(axis, pos)
	self.Owner.transform:SetAxisPosition(axis, pos)
end

function META:GetAxisPosition(axis)
	return self.Owner.transform:GetAxisPosition(axis)
end

function META:SetAxisLength(axis, len)
	self.Owner.transform:SetAxisLength(axis, len)
end

function META:GetAxisLength(axis)
	if self.real_size then return self.real_size[axis] end

	return self.Owner.transform:GetAxisLength(axis)
end

function META:GetWidth()
	return self:GetAxisLength("x")
end

function META:GetHeight()
	return self:GetAxisLength("y")
end

function META:GetVisibleChildren()
	local tbl = {}

	for _, child in ipairs(self.Owner:GetChildren()) do
		local gui = child.gui_element

		if not gui or gui:GetVisible() then table.insert(tbl, child) end
	end

	return tbl
end

function META:FlexLayout()
	if self.flex_size_to_children then return end

	local pad = self:GetPadding()
	local pos = Vec2(pad:GetLeft(), pad:GetTop())
	local axis = "x"
	local axis2 = "y"

	if self:GetFlexDirection() == "row" then
		axis = "x"
		axis2 = "y"
	elseif self:GetFlexDirection() == "column" then
		axis = "y"
		axis2 = "x"
	end

	local children = self:GetVisibleChildren()

	if #children == 0 then return end

	local parent_length = self:GetAxisLength(axis) / #children

	for i, child in ipairs(children) do
		local c_tr = child.transform
		local c_layout = child.layout
		c_tr:SetPosition(pos:Copy())
		local child_length = c_layout and c_layout:GetAxisLength(axis) or c_tr:GetAxisLength(axis)

		if parent_length > child_length then
			c_tr:SetAxisLength(axis, math.min(parent_length, child_length))
		end

		pos[axis] = pos[axis] + (
				c_layout and
				c_layout:GetAxisLength(axis) or
				c_tr:GetAxisLength(axis)
			)

		if i ~= #children then pos[axis] = pos[axis] + self:GetFlexGap() end
	end

	local end_pad = axis == "x" and pad:GetRight() or pad:GetBottom()
	self:SetAxisLength(axis, math.max(pos[axis] + end_pad, self:GetAxisLength(axis)))
	local diff = self:GetAxisLength(axis) - (pos[axis] + end_pad)

	if self:GetFlexJustifyContent() == "center" then
		for _, child in ipairs(children) do
			local c_tr = child.transform
			c_tr:SetAxisPosition(axis, c_tr:GetAxisPosition(axis) + diff / 2)
		end
	elseif self:GetFlexJustifyContent() == "end" then
		for _, child in ipairs(children) do
			local c_tr = child.transform
			c_tr:SetAxisPosition(axis, c_tr:GetAxisPosition(axis) + diff)
		end
	elseif self:GetFlexJustifyContent() == "space-between" then
		for i, child in ipairs(children) do
			local c_tr = child.transform
			c_tr:SetAxisPosition(axis, c_tr:GetAxisPosition(axis) + diff / (#children - 1) * (i - 1))
		end
	elseif self:GetFlexJustifyContent() == "space-around" then
		for i, child in ipairs(children) do
			local c_tr = child.transform
			c_tr:SetAxisPosition(axis, c_tr:GetAxisPosition(axis) + diff / (#children) * (i - 0.5))
		end
	end

	self.flex_size_to_children = true
	local h = self:GetAxisLength(axis2)

	if self:GetFlexDirection() == "row" then
		self:SizeToChildrenHeight()
	else
		self:SizeToChildrenWidth()
	end

	local h2 = self:GetAxisLength(axis2)
	self:SetAxisLength(axis2, math.max(h, h2))
	self.flex_size_to_children = nil

	if self:GetFlexAlignItems() == "end" then
		for _, child in ipairs(children) do
			local c_tr = child.transform
			local c_layout = child.layout
			local c_len = c_layout and c_layout:GetAxisLength(axis2) or c_tr:GetAxisLength(axis2)
			c_tr:SetAxisPosition(axis2, self:GetAxisLength(axis2) - c_len)
		end
	elseif self:GetFlexAlignItems() == "center" then
		for _, child in ipairs(children) do
			local c_tr = child.transform
			local c_layout = child.layout
			local c_len = c_layout and c_layout:GetAxisLength(axis2) or c_tr:GetAxisLength(axis2)
			c_tr:SetAxisPosition(axis2, (self:GetAxisLength(axis2) - c_len) / 2)
		end
	elseif self:GetFlexAlignItems() == "stretch" then
		for _, child in ipairs(children) do
			local c_tr = child.transform
			local offset = axis2 == "y" and pad:GetTop() or pad:GetLeft()
			local total_pad = axis2 == "y" and pad:GetSize().y or pad:GetSize().x
			c_tr:SetAxisPosition(axis2, offset)
			c_tr:SetAxisLength(axis2, self:GetAxisLength(axis2) - total_pad)
		end
	end

	for i, child in ipairs(children) do
		local c_layout = child.layout

		if c_layout then
			local c_tr = child.transform
			local c_len = c_layout:GetAxisLength(axis2)

			if c_layout:GetFlexAlignSelf() == "end" then
				c_tr:SetAxisPosition(axis2, self:GetAxisLength(axis2) - c_len)
			elseif c_layout:GetFlexAlignSelf() == "center" then
				c_tr:SetAxisPosition(axis2, (self:GetAxisLength(axis2) - c_len) / 2)
			elseif c_layout:GetFlexAlignSelf() == "stretch" then
				local offset = axis2 == "y" and pad:GetTop() or pad:GetLeft()
				local total_pad = axis2 == "y" and pad:GetSize().y or pad:GetSize().x
				c_tr:SetAxisPosition(axis2, offset)
				c_tr:SetAxisLength(axis2, self:GetAxisLength(axis2) - total_pad)
			end
		end
	end
end

function META:GetSizeOfChildren()
	local children = self:GetVisibleChildren()

	if #children == 0 then return self.Owner.transform:GetSize() end

	if self.last_children_size then return self.last_children_size:Copy() end

	if not self:IsBusy() then self:DoLayout() end

	local total_size = Vec2()

	for _, v in ipairs(children) do
		local v_tr = v.transform
		local v_layout = v.layout
		local margin = v_layout and v_layout:GetMargin() or Rect(0, 0, 0, 0)
		local v_sz = Vec2(
			v_layout and v_layout:GetWidth() or v_tr:GetWidth(),
			v_layout and v_layout:GetHeight() or v_tr:GetHeight()
		)
		local pos = v_tr:GetPosition() + v_sz + Vec2(margin:GetRight(), margin:GetBottom())

		if pos.x > total_size.x then total_size.x = pos.x end

		if pos.y > total_size.y then total_size.y = pos.y end
	end

	self.last_children_size = total_size
	return total_size
end

function META:SizeToChildrenHeight()
	local children = self:GetVisibleChildren()

	if #children == 0 then return end

	local tr = self.Owner.transform
	local old_last_size = self.last_children_size
	self.last_children_size = nil
	local old_real_size = self.real_size
	self.real_size = self.real_size or tr.Size:Copy()
	tr:SetHeight(1000000)
	tr:SetHeight(self:GetSizeOfChildren().y)
	local min_pos = math.huge
	local max_pos = -math.huge

	for _, v in ipairs(children) do
		local v_layout = v.layout
		local margin = v_layout and v_layout:GetMargin() or Rect(0, 0, 0, 0)
		local v_h = v_layout and v_layout:GetHeight() or v.transform:GetHeight()
		min_pos = math.min(min_pos, v.transform.Position.y - margin:GetTop())
		max_pos = math.max(max_pos, v.transform.Position.y + v_h + margin:GetBottom())
	end

	local padding = self:GetPadding()
	tr:SetHeight((max_pos - min_pos) + padding:GetYH())
	local offset_y = padding:GetTop() - min_pos

	if offset_y ~= 0 then
		for _, v in ipairs(children) do
			v.transform:SetY(v.transform.Position.y + offset_y)
		end
	end

	self:SetLayoutSize(tr.Size:Copy())
	self.real_size = old_real_size
	self.last_children_size = old_last_size
end

function META:SizeToChildrenWidth()
	local children = self:GetVisibleChildren()

	if #children == 0 then return end

	local tr = self.Owner.transform
	local old_last_size = self.last_children_size
	self.last_children_size = nil
	local old_real_size = self.real_size
	self.real_size = self.real_size or tr.Size:Copy()
	tr:SetWidth(1000000)
	tr:SetWidth(self:GetSizeOfChildren().x)
	local min_pos = math.huge
	local max_pos = -math.huge

	for _, v in ipairs(children) do
		local v_layout = v.layout
		local margin = v_layout and v_layout:GetMargin() or Rect(0, 0, 0, 0)
		local v_w = v_layout and v_layout:GetWidth() or v.transform:GetWidth()
		min_pos = math.min(min_pos, v.transform.Position.x - margin:GetLeft())
		max_pos = math.max(max_pos, v.transform.Position.x + v_w + margin:GetRight())
	end

	local padding = self:GetPadding()
	tr:SetWidth((max_pos - min_pos) + padding:GetXW())
	local offset_x = padding:GetLeft() - min_pos

	if offset_x ~= 0 then
		for _, v in ipairs(children) do
			v.transform:SetX(v.transform.Position.x + offset_x)
		end
	end

	self:SetLayoutSize(tr.Size:Copy())
	self.real_size = old_real_size
	self.last_children_size = old_last_size
end

function META:SizeToChildren()
	local children = self:GetVisibleChildren()

	if #children == 0 then return end

	local tr = self.Owner.transform
	local old_last_size = self.last_children_size
	self.last_children_size = nil
	local old_real_size = self.real_size
	self.real_size = self.real_size or tr.Size:Copy()
	tr:SetSize(Vec2(1000000, 1000000))
	local min_pos = Vec2(math.huge, math.huge)
	local max_pos = Vec2(-math.huge, -math.huge)

	for _, v in ipairs(children) do
		local v_tr = v.transform
		local v_layout = v.layout
		local margin = v_layout and v_layout:GetMargin() or Rect(0, 0, 0, 0)
		local v_w = v_layout and v_layout:GetWidth() or v_tr:GetWidth()
		local v_h = v_layout and v_layout:GetHeight() or v_tr:GetHeight()
		min_pos.x = math.min(min_pos.x, v_tr.Position.x - margin:GetLeft())
		min_pos.y = math.min(min_pos.y, v_tr.Position.y - margin:GetTop())
		max_pos.x = math.max(max_pos.x, v_tr.Position.x + v_w + margin:GetRight())
		max_pos.y = math.max(max_pos.y, v_tr.Position.y + v_h + margin:GetBottom())
	end

	local padding = self:GetPadding()
	tr:SetSize((max_pos - min_pos) + padding:GetPosSize())
	local offset = Vec2(padding:GetLeft(), padding:GetTop()) - min_pos

	if offset.x ~= 0 or offset.y ~= 0 then
		for _, v in ipairs(children) do
			v.transform:SetPosition(v.transform.Position + offset)
		end
	end

	self:SetLayoutSize(tr.Size:Copy())
	self.real_size = old_real_size
	self.last_children_size = old_last_size
end

function META:StackChildren()
	local w = 0
	local h = 0
	local pad = self:GetPadding()
	local p_tr = self.Owner.transform

	for _, child in ipairs(self.Owner:GetChildren()) do
		local c_layout = child.layout
		local c_tr = child.transform

		if not c_layout or c_layout:GetStackable() then
			local siz = Vec2(
				c_layout and c_layout:GetWidth() or c_tr:GetWidth(),
				c_layout and c_layout:GetHeight() or c_tr:GetHeight()
			)
			local margin = c_layout and c_layout:GetMargin() or Rect(0, 0, 0, 0)

			if self:GetForcedStackSize().x ~= 0 then siz.x = self:GetForcedStackSize().x end

			if self:GetForcedStackSize().y ~= 0 then siz.y = self:GetForcedStackSize().y end

			siz.x = siz.x + margin:GetLeft() + margin:GetRight()
			siz.y = siz.y + margin:GetTop() + margin:GetBottom()

			if self:GetStackRight() then
				h = h == 0 and siz.y or h
				w = w + siz.x

				if self:GetStackDown() and w > self:GetWidth() then
					h = h + siz.y
					w = siz.x
				end

				c_tr:SetPosition(
					Vec2(
						w + pad:GetLeft() - siz.x + margin:GetLeft(),
						h + pad:GetTop() - siz.y + margin:GetTop()
					)
				)
			else
				h = h + siz.y
				w = siz.x > w and siz.x or w
				c_tr:SetPosition(
					Vec2(pad:GetLeft() + margin:GetLeft(), h + pad:GetTop() - siz.y + margin:GetTop())
				)
			end

			if not self:GetForcedStackSize():IsZero() then
				local fsiz = self:GetForcedStackSize()

				if self:GetSizeStackToWidth() then fsiz.x = self:GetWidth() end

				if self:GetSizeStackToHeight() then fsiz.y = self:GetHeight() end

				c_tr:SetSize(Vec2(fsiz.x - pad:GetSize().x, fsiz.y))
			else
				if self:GetSizeStackToWidth() then
					c_tr:SetWidth(self:GetWidth() - pad:GetSize().x)
				end

				if self:GetSizeStackToHeight() then
					c_tr:SetHeight(self:GetHeight() - pad:GetSize().y)
				end
			end
		end
	end

	if self:GetSizeStackToWidth() then w = self:GetWidth() - pad:GetSize().x end

	return Vec2(w, h) + pad:GetSize()
end

layout_lib.layout_traces = {}

function layout_lib.DumpLayouts()
	local tbl = {}

	for trace, count in pairs(layout_lib.layout_traces) do
		table.insert(tbl, {count = count, trace = trace})
	end

	table.sort(tbl, function(a, b)
		return a.count > b.count
	end)

	for i = 1, 20 do
		if not tbl[i] then break end

		logn("===============")
		logn(tbl[i].count)
		logn(tbl[i].trace)
		logn("===============")
	end
end

layout_lib.depth = 0
layout_lib.layout_stress = false
META.recursion_depth = 0
layout_lib.debug = false
META.Library = layout_lib

function META:OnFirstCreated()
	local Panel = require("ecs.panel")

	event.AddListener(
		"Update",
		"layout_2d_system",
		function()
			for _, layout in ipairs(META.Instances) do
				layout:CalcLayout()
			end
		end,
		{priority = 101}
	)
end

function META:OnLastRemoved()
	event.RemoveListener("Update", "layout_2d_system")
end

return META:Register()
