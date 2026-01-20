local gui = require("gui.gui")
local Vec2 = require("structs.vec2")
local Rect = require("structs.rect")
local META = ...
META.layout_count = 0
META:GetSet("LayoutSize", nil)
META:GetSet("IgnoreLayout", false)
META:GetSet("LayoutUs", false)
META:GetSet("Flex", false)
META:GetSet("Stack", false)
META:GetSet("StackSizeToChildren", false)
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
			hit_pos.x = hit_pos.x + child:GetWidth() + self.Margin:GetRight() + child.Margin:GetLeft()
		elseif dir.x > 0 then
			hit_pos.y = self:GetY()
			hit_pos.x = hit_pos.x - self:GetWidth() - self.Margin:GetLeft() - child.Margin:GetRight()
		elseif dir.y < 0 then
			hit_pos.x = self:GetX()
			hit_pos.y = hit_pos.y + child:GetHeight() + self.Margin:GetTop() + child.Margin:GetBottom()
		elseif dir.y > 0 then
			hit_pos.x = self:GetX()
			hit_pos.y = hit_pos.y - self:GetHeight() - self.Margin:GetBottom() - child.Margin:GetTop()
		end
	else
		if dir.x < 0 then
			hit_pos.x = hit_pos.x + self.Margin:GetRight()
			hit_pos.x = hit_pos.x + self:GetParentPadding():GetLeft()
		elseif dir.x > 0 then
			hit_pos.x = hit_pos.x - self.Margin:GetLeft()
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
				if typex(cmd) == "panel" then
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
		self.layout_me = true

		if gui.debug then self.layout_me_tr = debug.traceback() end
	end
end

function META:CalcLayout()
	if self.layout_me or gui.layout_stress then self:CalcLayoutInternal(true) end
end

function META:SetLayout(commands)
	if self:HasParent() then self:GetParent():CalcLayoutInternal() end

	self:CalcLayoutInternal(true)

	if commands then
		self.Layout = commands
		self.LayoutSize = self:GetSize():Copy()

		if self:HasParent() then self:GetParent():SetLayoutUs(true) end
	else
		self.Layout = nil
		self.LayoutSize = nil

		if self:HasParent() then self:GetParent():SetLayoutUs(false) end
	end
--timer.Delay(0, function() self:CalcLayoutInternal() end, nil, self) -- FIX ME
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
		self:SetWidth(1)
		local left = self:RayCast(self:GetPosition(), Vec2(0, self.Position.y))
		local right = self:RayCast(self:GetPosition(), Vec2(parent_width, self.Position.y))

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
		self:SetHeight(1)
		local top = self:RayCast(self:GetPosition(), Vec2(self.Position.x, 0))
		local bottom = self:RayCast(self:GetPosition(), Vec2(self.Position.x, parent_height))

		if top.x > bottom.x then top, bottom = bottom, top end

		bottom.x = math.clamp(bottom.x, 0, parent_height)
		top.x = math.clamp(top.x, 0, parent_height)
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
		self:SetHeight(math.max(h + 1, min_height))
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
		local left = self:RayCast(self:GetPosition(), Vec2(0, self.Position.y))
		local right = self:RayCast(self:GetPosition(), Vec2(width, left.y))
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
		local top = self:RayCast(self:GetPosition(), Vec2(self.Position.x, 0))
		local bottom = self:RayCast(self:GetPosition(), Vec2(top.x, height))
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
		self:SetY(panel:GetY())
		self:SetX(panel:GetX() + panel:GetWidth())
		self.laid_out_x = true
		self.laid_out_y = true
	end

	function META:MoveDownOf(panel)
		self:SetX(panel:GetX())
		self:SetY(panel:GetY() + panel:GetHeight())
		self.laid_out_x = true
		self.laid_out_y = true
	end

	function META:MoveLeftOf(panel)
		self:SetY(panel:GetY())
		self:SetX(panel:GetX() - self:GetWidth())
		self.laid_out_x = true
		self.laid_out_y = true
	end

	function META:MoveUpOf(panel)
		self:SetX(panel:GetX())
		self:SetY(panel:GetY() - self:GetHeight())
		self.laid_out_x = true
		self.laid_out_y = true
	end
end
