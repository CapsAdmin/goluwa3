local gui = require("gui.gui")
local Vec2 = require("structs.vec2")
local Rect = require("structs.rect")
local META = ...
META.layout_count = 0
META:GetSet("LayoutSize", nil)
META:GetSet("IgnoreLayout", false)
META:GetSet("LayoutUs", false)
META:GetSet("CollisionGroup", "none")
META:GetSet("OthersAlwaysCollide", false)
META:GetSet("ThreeDee", false)
META:GetSet("LayoutWhenInvisible", false)
META:GetSet("Layout", nil)

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
	local parent = self:GetParent()
	local dir = stop_pos - start_pos
	local found = {}
	local i = 1
	local a_lft, a_top, a_rgt, a_btm = self:GetWorldRectFast()

	for _, b in ipairs(parent:GetChildren()) do
		if
			b ~= self and
			not b.nocollide and
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
			b.Visible and
			not b.ThreeDee and
			not b.IgnoreLayout and
			(
				self.CollisionGroup == b.CollisionGroup or
				b.OthersAlwaysCollide
			)
		then
			local b_lft, b_top, b_rgt, b_btm = b:GetWorldRectFast()

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
				if dir.y > 0 and b_top > a_top and not b.nocollide_up then
					found[i] = {child = b, point = b_top}
					i = i + 1
				elseif dir.y < 0 and b_btm < a_btm and not b.nocollide_down then
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
				if dir.x > 0 and b_rgt > a_rgt and not b.nocollide_left then
					found[i] = {child = b, point = b_lft}
					i = i + 1
				elseif dir.x < 0 and b_lft < a_lft and not b.nocollide_right then
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

	list.sort(found, sort)
	local hit_pos = stop_pos

	if found and found[1] then
		local child = found[1].child
		hit_pos = child:GetPosition():Copy()

		if dir.x < 0 then
			hit_pos.y = self:GetY()
			hit_pos.x = hit_pos.x + child:GetWidth() + self.Margin:GetLeft() + child.Margin:GetRight()
		elseif dir.x > 0 then
			hit_pos.y = self:GetY()
			hit_pos.x = hit_pos.x - self:GetWidth() - self.Margin:GetRight() - child.Margin:GetLeft()
		elseif dir.y < 0 then
			hit_pos.x = self:GetX()
			hit_pos.y = hit_pos.y + child:GetHeight() + self.Margin:GetTop() + child.Margin:GetBottom()
		elseif dir.y > 0 then
			hit_pos.x = self:GetX()
			hit_pos.y = hit_pos.y - self:GetHeight() - self.Margin:GetBottom() - child.Margin:GetTop()
		end
	else
		if dir.x < 0 then
			hit_pos.x = hit_pos.x + self.Margin:GetLeft()
			hit_pos.x = hit_pos.x + self:GetParentPadding():GetLeft()
		elseif dir.x > 0 then
			hit_pos.x = hit_pos.x - self.Margin:GetRight()
			hit_pos.x = hit_pos.x - self:GetParentPadding():GetRight()
		elseif dir.y < 0 then
			hit_pos.y = hit_pos.y + self.Margin:GetTop()
			hit_pos.y = hit_pos.y + self:GetParentPadding():GetBottom()
		elseif dir.y > 0 then
			hit_pos.y = hit_pos.y - self.Margin:GetBottom()
			hit_pos.y = hit_pos.y - self:GetParentPadding():GetTop()
		end

		hit_pos.x = math.max(hit_pos.x, 0)
		hit_pos.y = math.max(hit_pos.y, 0)
	end

	return hit_pos, found and found[1] and found[1].child
end

function META:ExecuteLayoutCommands()
	--	if self:HasParent() then self = self.Parent end
	--if not self.layout_us then return end
	for _, child in ipairs(self:GetChildren()) do
		if child.Layout then
			if child.LayoutSize then child:SetSize(child.LayoutSize:Copy()) end

			child.laid_out_x = false
			child.laid_out_y = false
			child:Confine()
		end
	end

	for _, child in ipairs(self:GetChildren()) do
		if child.Layout then
			for _, cmd in ipairs(child.Layout) do
				if type(cmd) == "table" and cmd.IsSurface then
					child.last_layout_panel = cmd
				else
					if cmd == "LayoutChildren" then
						self[tr_self[cmd]](self)
					elseif child[cmd] then
						child[cmd](child)
					elseif self[cmd] then
						self[cmd](self)
					elseif type(cmd) == "function" then
						cmd(child, self)
					elseif typex(cmd) == "vec2" then
						child:SetSize(cmd:Copy())
					end

					child.last_layout_panel = nil
				end
			end
		end
	end

	for _, child in ipairs(self:GetChildren()) do
		if child.Layout then
			for _, cmd in ipairs(child.Layout) do
				if cmd == "gmod_fill" then
					child.LayoutSize = Vec2(1, 1)
					child:CenterSimple()
					child:FillX()
					child:FillY()
					child:NoCollide()
				end
			end
		end
	end
end

function META:DoLayout()
	self.in_layout = self.in_layout + 1
	gui.in_layout = gui.in_layout + 1

	--	self:OnLayout() --self:GetLayoutScale(), self:GetSkin())
	if self.Flex then self:FlexLayout() end

	self:ExecuteLayoutCommands()

	if self.Stack then
		local size = self:StackChildren()

		if self.StackSizeToChildren then self:SetSize(size) end
	end

	--	self:OnPostLayout()
	--self:MarkCacheDirty()
	self.in_layout = self.in_layout - 1
	gui.in_layout = gui.in_layout - 1
end

gui.layout_traces = {}

function gui.DumpLayouts()
	local tbl = {}

	for trace, count in pairs(gui.layout_traces) do
		list.insert(tbl, {count = count, trace = trace})
	end

	list.sort(tbl, function(a, b)
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

gui.in_layout = 0
META.in_layout = 0
gui.debug = true

function META:CalcLayoutInternal(now)
	if self.in_layout ~= 0 then return end

	if now and (self.LayoutWhenInvisible or self.Visible) then
		self.in_layout = self.in_layout + 1
		gui.in_layout = gui.in_layout + 1

		if gui.debug then
			local tr = self.layout_me_tr or debug.traceback()
			gui.layout_traces[tr] = (gui.layout_traces[tr] or 0) + 1
			self.layout_me_tr = nil
		end

		if self.Scrollable then self:SetScrollFraction(self:GetScrollFraction()) end

		self:DoLayout()

		if now then
			self.updated_layout = (self.updated_layout or 0) + 1

			for _, v in ipairs(self:GetChildren()) do
				v:CalcLayoutInternal(true)
			end
		else
			for _, v in ipairs(self:GetChildren()) do
				v.layout_me = true
			end
		end

		self.layout_count = (self.layout_count or 0) + 1
		self.last_children_size = nil
		self.layout_me = false
		self.in_layout = self.in_layout - 1
		gui.in_layout = gui.in_layout - 1
	else --if gui.in_layout == 0 then
		if self.layout_me then return end

		self.layout_me = true

		if self:HasParent() then self:GetParent():CalcLayoutInternal() end

		if gui.debug then self.layout_me_tr = debug.traceback() end
	end
end

function META:CalcLayout()
	if self.layout_me or gui.layout_stress then self:CalcLayoutInternal(true) end
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

function META:SetLayout(commands)
	if compare_layouts(self.Layout, commands) then return end

	if commands then
		self.Layout = commands
		self.LayoutSize = self:GetSize():Copy()

		if self:HasParent() then self:GetParent():SetLayoutUs(true) end
	else
		self.Layout = nil
		self.LayoutSize = nil

		if self:HasParent() then self:GetParent():SetLayoutUs(false) end
	end

	if self:HasParent() then self:GetParent():CalcLayoutInternal() end

	self:CalcLayoutInternal()
end

function META:ResetLayoutSize()
	self.LayoutSize.x = self.Size.x
	self.LayoutSize.y = self.Size.y
end

function META:OnParent(parent)
	if parent ~= self.Parent then
		if self.Layout then self:SetupLayout(self.Layout) end
	end
end

do -- layout commands
	function META:ResetLayout()
		self.laid_out_x = false
		self.laid_out_y = false

		for _, child in ipairs(self:GetChildren()) do
			if child.LayoutSize then child:SetSize(child.LayoutSize:Copy()) end

			child.laid_out_x = false
			child.laid_out_y = false
		end
	end

	function META:Collide()
		self.nocollide = false
		self.nocollide_up = false
		self.nocollide_down = false
		self.nocollide_left = false
		self.nocollide_right = false
	end

	function META:NoCollide(dir)
		if dir then
			self["nocollide_" .. dir] = true
		else
			self.nocollide = true
		end
	end

	function META:LayoutChildren()
		for _, child in ipairs(self:GetChildren()) do
			child:CalcLayoutInternal(true)
		end
	end

	function META:Fill()
		self:CenterSimple()
		self:FillX()
		self:FillY()
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

	function META:FillX(percent)
		local parent = self:GetParent()
		local parent_width = parent.real_size and parent.real_size.x or parent:GetWidth()
		local temp_w = self:GetWidth()
		self:SetWidth(1)
		local left, left_child = self:RayCast(self:GetPosition(), Vec2(0, self.Position.y))
		local right, right_child = self:RayCast(self:GetPosition(), Vec2(parent_width, self.Position.y))

		if right_child then right.x = right.x + 1 end

		if left.x > right.x then left, right = right, left end

		right.x = math.clamp(right.x, 0, parent_width)
		left.x = math.clamp(left.x, 0, parent_width)
		right.x = right.x - left.x
		local x = left.x
		local w = right.x
		local min_width = self.MinimumSize.x

		if percent then
			x = math.max(math.lerp(percent * 0.5, left.x, right.x + self:GetWidth()), min_width) - min_width + left.x
			w = w - x * 2 + left.x * 2

			if w < min_width then
				x = -left.x
				w = right.x
			end
		end

		self:SetX(math.max(x, left.x)) -- HACK???
		self:SetWidth(math.max(w, min_width))
		self.laid_out_x = true
	end

	function META:FillY(percent)
		local parent = self:GetParent()
		local parent_height = parent.real_size and parent.real_size.y or parent:GetHeight()
		local temp_h = self:GetHeight()
		self:SetHeight(1)
		local top, top_child = self:RayCast(self:GetPosition(), Vec2(self.Position.x, 0))
		local bottom, bottom_child = self:RayCast(self:GetPosition(), Vec2(self.Position.x, parent_height))

		if bottom_child then bottom.y = bottom.y + 1 end

		if top.y > bottom.y then top, bottom = bottom, top end

		bottom.y = math.clamp(bottom.y, 0, parent_height)
		top.y = math.clamp(top.y, 0, parent_height)
		bottom.y = bottom.y - top.y
		local y = top.y
		local h = bottom.y
		local min_height = self.MinimumSize.y

		if percent then
			y = math.max(math.lerp(percent, top.y, bottom.y + self:GetHeight()), min_height / 2) - min_height / 2 + top.y
			h = h - y * 2 + top.y * 2

			if h < min_height then
				y = -top.y
				h = bottom.y
			end
		end

		self:SetY(math.max(y, top.y)) -- HACK???
		self:SetHeight(math.max(h, min_height))
		self.laid_out_y = true
	end

	function META:Center()
		self:CenterX()
		self:CenterY()
	end

	function META:CenterX()
		self:CenterXSimple()
		local parent = self:GetParent()
		local width = parent.real_size and parent.real_size.x or parent:GetWidth()
		local left, left_child = self:RayCast(self:GetPosition(), Vec2(0, self.Position.y))
		local right, right_child = self:RayCast(self:GetPosition(), Vec2(width, left.y))

		if right_child then
			right.x = right.x + self:GetWidth() + self.Margin:GetRight() + right_child.Margin:GetLeft()
		end

		self:SetX(
			(
					left.x + right.x
				) / 2 - self:GetWidth() / 2 - self.Margin:GetLeft() + self.Margin:GetRight()
		)
		self.laid_out_x = true
	end

	function META:CenterY()
		local parent = self:GetParent()
		local height = parent.real_size and parent.real_size.y or parent:GetHeight()
		local top, top_child = self:RayCast(self:GetPosition(), Vec2(self.Position.x, 0))
		local bottom, bottom_child = self:RayCast(self:GetPosition(), Vec2(top.x, height))

		if bottom_child then
			bottom.y = bottom.y + self:GetHeight() + self.Margin:GetBottom() + bottom_child.Margin:GetTop()
		end

		self:SetY(
			(
					top.y + bottom.y
				) / 2 - self:GetHeight() / 2 - self.Margin:GetTop() + self.Margin:GetBottom()
		)
		self.laid_out_y = true
	end

	function META:CenterXSimple()
		local parent = self:GetParent()
		local width = parent.real_size and parent.real_size.x or parent:GetWidth()
		self:SetX(width / 2 - self:GetWidth() / 2)
		self.laid_out_x = true
	end

	function META:CenterYSimple()
		local parent = self:GetParent()
		local height = parent.real_size and parent.real_size.y or parent:GetHeight()
		self:SetY(height / 2 - self:GetHeight() / 2)
		self.laid_out_y = true
	end

	function META:CenterSimple()
		self:CenterXSimple()
		self:CenterYSimple()
	end

	function META:CenterXFrame()
		local parent = self:GetParent()
		local left = self:RayCast(self:GetPosition(), Vec2(0, self.Position.y))
		local right = self:RayCast(self:GetPosition(), Vec2(parent:GetWidth(), left.y))

		if
			self:GetX() + self:GetWidth() + self.Margin:GetRight() < right.x + self:GetWidth() - self.Margin:GetRight()
			and
			self:GetX() - self.Margin.x > left.x
		then
			self:SetX(parent:GetWidth() / 2 - self:GetWidth() / 2)
		end

		self.laid_out_x = true
	end

	function META:MoveUp()
		local parent = self:GetParent()

		if self.last_layout_panel then self:MoveUpOf(self.last_layout_panel) end

		if not self.laid_out_y then self:SetY(999999999999) -- :(
		end

		self:SetY(math.max(self:GetY(), 1))
		self:SetY(self:RayCast(self:GetPosition(), Vec2(self:GetX(), 0)).y)
		self.laid_out_y = true
	end

	function META:MoveLeft()
		local parent = self:GetParent()

		if self.last_layout_panel then self:MoveLeftOf(self.last_layout_panel) end

		if not self.laid_out_x then self:SetX(999999999999) end

		self:SetX(math.max(self:GetX(), 1))
		self:SetX(self:RayCast(self:GetPosition(), Vec2(0, self.Position.y)).x)
		self.laid_out_x = true
	end

	function META:Confine()
		local m = self:GetParent():GetPadding()
		local p = self:GetMargin()
		self.Position.x = math.clamp(
			self.Position.x,
			m:GetLeft() + p:GetLeft(),
			self.Parent.Size.x - self.Size.x - m:GetRight() + p:GetRight()
		)
		self.Position.y = math.clamp(
			self.Position.y,
			m:GetTop() + p:GetTop(),
			self.Parent.Size.y - self.Size.y - m:GetBottom() + p:GetBottom()
		)
	end

	function META:MoveDown()
		local parent = self:GetParent()

		if self.last_layout_panel then self:MoveDownOf(self.last_layout_panel) end

		if not self.laid_out_y then self:SetY(-999999999999) end

		self:SetY(math.max(self:GetY(), 1))
		self:SetY(self:RayCast(self:GetPosition(), Vec2(self:GetX(), parent:GetHeight() - self:GetHeight())).y)
		self.laid_out_y = true
	end

	function META:MoveRight()
		local parent = self:GetParent()

		if self.last_layout_panel then self:MoveRightOf(self.last_layout_panel) end

		if not self.laid_out_x then self:SetX(-999999999999) end

		self:SetX(math.max(self:GetX(), 1))
		self:SetX(self:RayCast(self:GetPosition(), Vec2(parent:GetWidth() - self:GetWidth(), self.Position.y)).x)
		self.laid_out_x = true
	end

	function META:MoveRightOf(panel)
		panel = panel or self.last_layout_panel

		if not panel then return end

		self:SetY(panel:GetY())
		self:SetX(panel:GetX() + panel:GetWidth() + panel.Margin:GetRight() + self.Margin:GetLeft())
		self.laid_out_x = true
		self.laid_out_y = true
	end

	function META:MoveDownOf(panel)
		panel = panel or self.last_layout_panel

		if not panel then return end

		self:SetX(panel:GetX())
		self:SetY(
			panel:GetY() + panel:GetHeight() + panel.Margin:GetBottom() + self.Margin:GetTop()
		)
		self.laid_out_x = true
		self.laid_out_y = true
	end

	function META:MoveLeftOf(panel)
		panel = panel or self.last_layout_panel

		if not panel then return end

		self:SetY(panel:GetY())
		self:SetX(panel:GetX() - self:GetWidth() - panel.Margin:GetLeft() - self.Margin:GetRight())
		self.laid_out_x = true
		self.laid_out_y = true
	end

	function META:MoveUpOf(panel)
		panel = panel or self.last_layout_panel

		if not panel then return end

		self:SetX(panel:GetX())
		self:SetY(panel:GetY() - self:GetHeight() - panel.Margin:GetTop() - self.Margin:GetBottom())
		self.laid_out_x = true
		self.laid_out_y = true
	end
end

do -- flex layout
	META:GetSet("Flex", false)
	META:GetSet("FlexDirection", "row")
	META:GetSet("FlexGap", 0)
	META:GetSet("FlexJustifyContent", "start")
	META:GetSet("FlexAlignItems", "start")
	META:GetSet("FlexAlignSelf", "start")

	function META:SetAxisPosition(axis, pos)
		if axis == "x" then self:SetX(pos) else self:SetY(pos) end
	end

	function META:GetAxisPosition(axis)
		if axis == "x" then return self:GetX() else return self:GetY() end
	end

	function META:SetAxisLength(axis, len)
		if axis == "x" then self:SetWidth(len) else self:SetHeight(len) end
	end

	function META:GetAxisLength(axis)
		if axis == "x" then
			return self:GetWidth()
		else
			return self:GetHeight()
		end
	end

	function META:FlexLayout()
		if self.flex_size_to_children then return end

		local pos = Vec2(self:GetPadding().x, self:GetPadding().y)
		local axis = "x"
		local axis2 = "y"

		if self.FlexDirection == "row" then
			axis = "x"
			axis2 = "y"
		elseif self.FlexDirection == "column" then
			axis = "y"
			axis2 = "x"
		end

		local children = self:GetVisibleChildren()
		local parent_length = self:GetAxisLength(axis) / #children

		for i, child in ipairs(children) do
			child:SetPosition(pos:Copy())
			local child_length = child:GetAxisLength(axis)

			if parent_length > child_length then
				child:SetAxisLength(axis, math.min(parent_length, child:GetAxisLength(axis)))
			end

			pos[axis] = pos[axis] + child:GetAxisLength(axis)

			if i ~= #children then pos[axis] = pos[axis] + self.FlexGap end
		end

		self:SetAxisLength(axis, math.max(pos[axis], self:GetAxisLength(axis)))
		local diff = self:GetAxisLength(axis) - pos[axis]

		if self.FlexJustifyContent == "center" then
			for i, child in ipairs(children) do
				child:SetAxisPosition(axis, child:GetAxisPosition(axis) + diff / 2)
			end
		elseif self.FlexJustifyContent == "end" then
			for i, child in ipairs(children) do
				child:SetAxisPosition(axis, child:GetAxisPosition(axis) + diff)
			end
		elseif self.FlexJustifyContent == "space-between" then
			for i, child in ipairs(children) do
				child:SetAxisPosition(axis, child:GetAxisPosition(axis) + diff / (#children - 1) * (i - 1))
			end
		elseif self.FlexJustifyContent == "space-around" then
			for i, child in ipairs(children) do
				child:SetAxisPosition(axis, child:GetAxisPosition(axis) + diff / (#children) * (i - 0.5))
			end
		end

		self.flex_size_to_children = true
		local h = self:GetAxisLength(axis2)

		if self.FlexDirection == "row" then
			self:SizeToChildrenHeight()
		else
			self:SizeToChildrenWidth()
		end

		local h2 = self:GetAxisLength(axis2)
		self:SetAxisLength(axis2, math.max(h, h2))
		self.flex_size_to_children = nil
		self:SetAxisLength(
			axis,
			math.max(
				self:GetAxisLength(axis) + self:GetPadding()[self.FlexDirection == "row" and
					"h" or
					"w"],
				self:GetAxisLength(axis)
			)
		)

		if self.FlexAlignItems == "end" then
			for i, child in ipairs(children) do
				child:SetAxisPosition(axis2, self:GetAxisLength(axis2) - child:GetAxisLength(axis2))
			end
		elseif self.FlexAlignItems == "center" then
			for i, child in ipairs(children) do
				child:SetAxisPosition(axis2, (self:GetAxisLength(axis2) - child:GetAxisLength(axis2)) / 2)
			end
		elseif self.FlexAlignItems == "stretch" then
			for i, child in ipairs(children) do
				child:SetAxisPosition(axis2, self:GetPadding()[axis2])
				child:SetAxisLength(
					axis2,
					self:GetAxisLength(axis2) - self:GetPadding()[axis2] - self:GetPadding()[self.FlexDirection == "column" and
						"w" or
						"h"]
				)
			end
		end

		for i, child in ipairs(children) do
			if child.FlexAlignSelf == "end" then
				child:SetAxisPosition(axis2, self:GetAxisLength(axis2) - child:GetAxisLength(axis2))
			elseif child.FlexAlignSelf == "center" then
				child:SetAxisPosition(axis2, (self:GetAxisLength(axis2) - child:GetAxisLength(axis2)) / 2)
			elseif child.FlexAlignSelf == "stretch" then
				child:SetAxisPosition(axis2, self:GetPadding()[axis2])
				child:SetAxisLength(
					axis2,
					self:GetAxisLength(axis2) - self:GetPadding()[axis2] - self:GetPadding()[self.FlexDirection == "column" and
						"w" or
						"h"]
				)
			end
		end
	end
end

do -- stacking
	META:GetSet("ForcedStackSize", Vec2(0, 0))
	META:GetSet("StackRight", true)
	META:GetSet("StackDown", true)
	META:GetSet("SizeStackToWidth", false)
	META:GetSet("SizeStackToHeight", false)
	META:IsSet("Stackable", true)
	META:IsSet("Stack", false)
	META:IsSet("StackSizeToChildren", false)

	function META:StackChildren()
		local w = 0
		local h
		local pad = self:GetPadding()

		for _, pnl in ipairs(self:GetChildren()) do
			if pnl:IsStackable() then
				local siz = pnl:GetSize():Copy()

				if self.ForcedStackSize.x ~= 0 then siz.x = self.ForcedStackSize.x end

				if self.ForcedStackSize.y ~= 0 then siz.y = self.ForcedStackSize.y end

				siz.x = siz.x + pnl.Margin.w
				siz.y = siz.y + pnl.Margin.h

				if self.StackRight then
					h = h or siz.y
					w = w + siz.x

					if self.StackDown and w > self:GetWidth() then
						h = h + siz.y
						w = siz.x
					end

					pnl.Position.x = w + pad.x - siz.x + pnl.Margin.x
					pnl.Position.y = h + pad.y - siz.y + pnl.Margin.y
				else
					h = h or 0
					h = h + siz.y
					w = siz.x > w and siz.x or w
					pnl.Position.x = pad.x + pnl.Margin.x
					pnl.Position.y = h + pad.y - siz.y + pnl.Margin.y
				end

				if not self.ForcedStackSize:IsZero() then
					local siz = self.ForcedStackSize

					if self.SizeStackToWidth then siz.x = self:GetWidth() end

					if self.SizeStackToHeight then siz.x = self:GetHeight() end

					pnl:SetSize(Vec2(siz.x - pad.y * 2, siz.y))
				else
					if self.SizeStackToWidth then
						pnl:SetWidth(self:GetWidth() - pad.x * 2)
					end

					if self.SizeStackToHeight then
						pnl:SetHeight(self:GetHeight() - pad.y * 2)
					end
				end
			end
		end

		if self.SizeStackToWidth then w = self:GetWidth() - pad.x * 2 end

		h = h or 0
		return Vec2(w, h) + pad:GetSize()
	end
end

do
	function META:GetSizeOfChildren()
		if #self.Children == 0 then return self:GetSize() end

		if self.last_children_size then return self.last_children_size:Copy() end

		self:DoLayout()
		local total_size = Vec2()

		for _, v in ipairs(self:GetVisibleChildren()) do
			local pos = v:GetPosition() + v:GetSize() + v.Margin:GetPosition()

			if pos.x > total_size.x then total_size.x = pos.x end

			if pos.y > total_size.y then total_size.y = pos.y end
		end

		self.last_children_size = total_size
		return total_size
	end

	function META:SizeToChildrenHeight()
		if #self.Children == 0 then return end

		self.last_children_size = nil
		self.real_size = self.Size:Copy()
		self.Size.y = math.huge
		self.Size.y = self:GetSizeOfChildren().y
		local min_pos = self.Size.y
		local max_pos = 0

		for i, v in ipairs(self:GetVisibleChildren()) do
			min_pos = math.min(min_pos, v.Position.y - v.Margin.y - v:GetParentPadding().y)
		end

		for i, v in ipairs(self:GetVisibleChildren()) do
			local pos_y = v.Position.y - min_pos
			max_pos = math.max(max_pos, pos_y + v.Size.y + v.Margin.h)
		end

		self.Size.y = max_pos + self.Padding:GetSize().y
		self.LayoutSize = self.Size:Copy()
		--self:SetY(0)
		self.laid_out_y = true
		self.real_size = nil
	end

	function META:SizeToChildrenWidth()
		if #self.Children == 0 then return end

		self.last_children_size = nil
		self.real_size = self.Size:Copy()
		self.Size.x = math.huge
		self.Size.x = self:GetSizeOfChildren().x
		local min_pos = self.Size.x
		local max_pos = 0

		for i, v in ipairs(self:GetVisibleChildren()) do
			min_pos = math.min(min_pos, v.Position.x - v.Margin.x - v:GetParentPadding().x)
		end

		for i, v in ipairs(self:GetVisibleChildren()) do
			local pos_x = v.Position.x - min_pos
			max_pos = math.max(max_pos, pos_x + v.Size.x + v.Margin.w)
		end

		self.Size.x = max_pos + self.Padding:GetSize().x
		self.LayoutSize = self.Size:Copy()
		--self:SetX(0)
		self.laid_out_x = true
		self.real_size = nil
	end

	function META:SizeToChildren()
		if #self.Children == 0 then return end

		self.last_children_size = nil
		self.real_size = self.Size:Copy()
		self.Size = Vec2() + math.huge
		self.Size = self:GetSizeOfChildren()
		local min_pos = self.Size:Copy()
		local max_pos = Vec2()

		for i, v in ipairs(self:GetVisibleChildren()) do
			min_pos.x = math.min(min_pos.x, v.Position.x - v.Margin.x - self.Padding.x)
			min_pos.y = math.min(min_pos.y, v.Position.y - v.Margin.y - self.Padding.y)
		end

		for i, v in ipairs(self:GetVisibleChildren()) do
			local pos_x = v.Position.x - min_pos.x
			local pos_y = v.Position.y - min_pos.y
			max_pos.x = math.max(max_pos.x, pos_x + v.Size.x + v.Margin.w)
			max_pos.y = math.max(max_pos.y, pos_y + v.Size.y + v.Margin.h)
		end

		self.Size = max_pos + self.Padding:GetSize()
		self.LayoutSize = self.Size:Copy()
		--self:SetPosition(Vec2())
		self.laid_out_x = true
		self.laid_out_y = true
		self.real_size = nil
	end
end
