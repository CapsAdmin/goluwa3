local prototype = import("goluwa/prototype.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local event = import("goluwa/event.lua")
local UIDebug = import("goluwa/ecs/components/2d/ui_debug.lua")
local layout_lib = library()
local META = prototype.CreateTemplate("layout")
META.layout_count = 0
META:StartStorable()
META:GetSet("MinSize", Vec2(0, 0), {callback = "InvalidateLayout"})
META:GetSet("MaxSize", Vec2(0, 0), {callback = "InvalidateLayout"})
META:GetSet("Margin", Rect(0, 0, 0, 0), {callback = "InvalidateLayout"})
META:GetSet("Padding", Rect(0, 0, 0, 0), {callback = "InvalidateLayout"})
META:GetSet("ChildGap", 0, {callback = "InvalidateLayout"})
META:GetSet("Direction", "x", {callback = "InvalidateLayout"})
META:GetSet("GrowWidth", 0, {callback = "InvalidateLayout"})
META:GetSet("GrowHeight", 0, {callback = "InvalidateLayout"})
META:GetSet("ShrinkWidth", 0, {callback = "InvalidateLayout"})
META:GetSet("ShrinkHeight", 0, {callback = "InvalidateLayout"})
META:GetSet("FitWidth", false, {callback = "InvalidateLayout"})
META:GetSet("FitHeight", false, {callback = "InvalidateLayout"})
META:GetSet("AlignmentX", "stretch", {callback = "InvalidateLayout"})
META:GetSet("AlignmentY", "stretch", {callback = "InvalidateLayout"})
META:GetSet("SelfAlignmentX", "auto", {callback = "InvalidateLayout"})
META:GetSet("SelfAlignmentY", "auto", {callback = "InvalidateLayout"})
META:GetSet("Floating", false, {callback = "InvalidateLayout"})
META:GetSet("Dock", "none", {callback = "InvalidateLayout"})
META:GetSet("Dirty", false)
META:GetSet("LastSize", Vec2(0, 0))
META:EndStorable()

function META:Initialize()
	self.Owner:EnsureComponent("transform")

	self.Owner:AddLocalListener("OnParent", function()
		self:InvalidateLayout()
	end)

	self.Owner:AddLocalListener("OnChildAdd", function()
		self:InvalidateLayout()
	end)

	self.Owner:AddLocalListener("OnChildRemove", function()
		self:InvalidateLayout()
	end)

	self.Owner:AddLocalListener("OnTransformChanged", function()
		if self.busy then return end

		local tr = self.Owner.transform
		local new_size = tr:GetSize()
		local old_size = self:GetLastSize()

		if old_size.x ~= new_size.x or old_size.y ~= new_size.y then
			self:SetLastSize(new_size:Copy())
			self:InvalidateLayout()
		end
	end)

	self:SetLastSize(self.Owner.transform:GetSize():Copy())
	self:InvalidateLayout()
end

function META:InvalidateLayout()
	local parent = self.Owner:GetParent()

	if self:GetDirty() then
		if parent and parent:IsValid() and parent.layout and parent.layout.busy then
			parent.layout.pending_child_reflow = true
		end

		return
	end

	self:SetDirty(true)

	if parent and parent:IsValid() and parent.layout then
		if parent.layout.busy then
			parent.layout.pending_child_reflow = true
			return
		end

		parent.layout:InvalidateLayout()
	end
end

local axis_map = {
	x = {
		main = "x",
		cross = "y",
		main_size = "Width",
		cross_size = "Height",
		main_margin_start = "x",
		main_margin_end = "w",
		cross_margin_start = "y",
		cross_margin_end = "h",
	},
	y = {
		main = "y",
		cross = "x",
		main_size = "Height",
		cross_size = "Width",
		main_margin_start = "y",
		main_margin_end = "h",
		cross_margin_start = "x",
		cross_margin_end = "w",
	},
}
local dock_values = {
	none = true,
	top = true,
	bottom = true,
	left = true,
	right = true,
	fill = true,
}

local function should_layout_child(child)
	local gui = child.gui_element
	return child:IsValid() and
		(
			not gui or
			gui:GetVisible()
		)
		and
		not (
			child.layout and
			child.layout:GetFloating()
		)
end

local function get_child_dock(child_layout)
	if not child_layout then return "none" end

	local dock = child_layout:GetDock()

	if dock_values[dock] then return dock end

	return "none"
end

local function layout_uses_dock(children)
	for _, child in ipairs(children) do
		if
			should_layout_child(child) and
			child.layout and
			get_child_dock(child.layout) ~= "none"
		then
			return true
		end
	end

	return false
end

local function measure_child_layout(child)
	if child.layout then
		local child_layout = child.layout
		local child_size = child_layout.intrinsic_size

		if child_layout:GetDirty() or not child_size then
			child_size = child_layout:Measure()
		end

		return child_size, child_layout:GetMargin(), child_layout
	end

	return child.transform:GetSize(), Rect(0, 0, 0, 0), nil
end

local function get_effective_dock(child_layout)
	local dock = get_child_dock(child_layout)

	if dock == "none" then return "fill" end

	return dock
end

local function measure_docked_children(children, padding)
	local consumed_left = 0
	local consumed_right = 0
	local consumed_top = 0
	local consumed_bottom = 0
	local required_width = 0
	local required_height = 0
	local count = 0
	local fill_children = {}

	for _, child in ipairs(children) do
		if should_layout_child(child) then
			local child_size, child_margin, child_layout = measure_child_layout(child)
			local dock = get_effective_dock(child_layout)
			local total_width = child_size.x + child_margin.x + child_margin.w
			local total_height = child_size.y + child_margin.y + child_margin.h

			if dock == "top" or dock == "bottom" then
				required_width = math.max(required_width, consumed_left + consumed_right + total_width)

				if dock == "top" then
					consumed_top = consumed_top + total_height
				else
					consumed_bottom = consumed_bottom + total_height
				end
			elseif dock == "left" or dock == "right" then
				required_height = math.max(required_height, consumed_top + consumed_bottom + total_height)

				if dock == "left" then
					consumed_left = consumed_left + total_width
				else
					consumed_right = consumed_right + total_width
				end
			else
				fill_children[#fill_children + 1] = {
					total_width = total_width,
					total_height = total_height,
				}
			end

			count = count + 1
		end
	end

	for _, child in ipairs(fill_children) do
		required_width = math.max(required_width, consumed_left + consumed_right + child.total_width)
		required_height = math.max(required_height, consumed_top + consumed_bottom + child.total_height)
	end

	required_width = math.max(required_width, consumed_left + consumed_right)
	required_height = math.max(required_height, consumed_top + consumed_bottom)
	return Vec2(required_width + padding.x + padding.w, required_height + padding.y + padding.h),
	count
end

local function get_child_cross_alignment(parent_layout, child_layout)
	local parent_dir = parent_layout:GetDirection()
	local self_alignment

	if parent_dir == "x" then
		self_alignment = child_layout:GetSelfAlignmentY()
	else
		self_alignment = child_layout:GetSelfAlignmentX()
	end

	if self_alignment ~= "auto" then return self_alignment end

	if parent_dir == "x" then return parent_layout:GetAlignmentY() end

	return parent_layout:GetAlignmentX()
end

function META:Measure()
	local dir = self:GetDirection()
	local axis = axis_map[dir]
	local padding = self:GetPadding()
	local child_gap = self:GetChildGap()
	local main_total = 0
	local cross_max = 0
	local children = self.Owner:GetChildren()
	local uses_dock_layout = layout_uses_dock(children)
	local count = 0
	self.uses_dock_layout = uses_dock_layout
	local intrinsic = Vec2(0, 0)
	local tr_size = self.Owner.transform:GetSize()

	if uses_dock_layout then
		intrinsic, count = measure_docked_children(children, padding)
	else
		for _, child in ipairs(children) do
			if should_layout_child(child) then
				local child_size, child_margin = measure_child_layout(child)
				local child_main = child_size[axis.main] + child_margin[axis.main_margin_start] + child_margin[axis.main_margin_end]
				local child_cross = child_size[axis.cross] + child_margin[axis.cross_margin_start] + child_margin[axis.cross_margin_end]

				if count > 0 then main_total = main_total + child_gap end

				main_total = main_total + child_main
				cross_max = math.max(cross_max, child_cross)
				count = count + 1
			end
		end

		if dir == "x" then
			intrinsic.x = main_total + padding.x + padding.w
			intrinsic.y = cross_max + padding.y + padding.h
		else
			intrinsic.x = cross_max + padding.x + padding.w
			intrinsic.y = main_total + padding.y + padding.h
		end
	end

	-- If we have no children but have a text component, use its size as the intrinsic size
	if count == 0 and self.Owner.text then
		local text_component = self.Owner.text
		local font = text_component:GetFont()
		local text = text_component.wrapped_text or text_component:GetText()

		if font and text then
			local w, h

			if text_component:GetWrap() then
				-- Wrapped text should measure against the current inner width constraint,
				-- not the widest stale wrapped line, otherwise parent layouts can get stuck
				-- widening to an old unwrapped width and never shrink again.
				local current_inner_width = math.max(0, tr_size.x - padding.x - padding.w)

				if text_component:GetWrapToParent() then
					local parent = self.Owner:GetParent()

					if parent and parent:IsValid() and parent.transform then
						current_inner_width = parent.transform:GetSize().x

						if parent.layout then
							local parent_padding = parent.layout:GetPadding()
							current_inner_width = current_inner_width - parent_padding.x - parent_padding.w
						end

						current_inner_width = math.max(0, current_inner_width)
					end
				end

				local wrapped = text_component:GetWrappedSize(current_inner_width)
				w = current_inner_width
				h = wrapped.y
			else
				w, h = font:GetTextSize(text)
			end

			intrinsic.x = w + padding.x + padding.w
			intrinsic.y = h + padding.y + padding.h
		end
	end

	self.content_size = intrinsic:Copy()
	-- Heuristic to prevent feedback loops:
	-- If we are being stretched or grown by a parent layout, we shouldn't use our current size
	-- as our intrinsic "basis", otherwise we can never shrink.
	local parent = self.Owner:GetParent()
	local is_being_managed_x = self:GetFitWidth() or self:GetGrowWidth() > 0
	local is_being_managed_y = self:GetFitHeight() or self:GetGrowHeight() > 0

	if
		self.Owner.text and
		self.Owner.text:GetWrap() and
		self.Owner.text:GetWrapToParent()
	then
		is_being_managed_x = true
	end

	if parent and parent:IsValid() and parent.layout then
		local pl = parent.layout

		if pl.uses_dock_layout then
			local dock = get_effective_dock(self)

			if dock == "top" or dock == "bottom" then
				is_being_managed_x = true
			elseif dock == "left" or dock == "right" then
				is_being_managed_y = true
			elseif dock == "fill" then
				is_being_managed_x = true
				is_being_managed_y = true
			end
		else
			local pdir = pl:GetDirection()
			local self_alignment_x = self:GetSelfAlignmentX()
			local self_alignment_y = self:GetSelfAlignmentY()
			local effective_alignment_x = self_alignment_x ~= "auto" and self_alignment_x or pl:GetAlignmentX()
			local effective_alignment_y = self_alignment_y ~= "auto" and self_alignment_y or pl:GetAlignmentY()

			if pdir == "x" then
				if effective_alignment_y == "stretch" then is_being_managed_y = true end
			else
				if effective_alignment_x == "stretch" then is_being_managed_x = true end
			end
		end
	end

	if not is_being_managed_x then intrinsic.x = tr_size.x end

	if not is_being_managed_y then intrinsic.y = tr_size.y end

	-- Min/Max constraints
	local min = self:GetMinSize()
	local max = self:GetMaxSize()

	if min.x > 0 then intrinsic.x = math.max(intrinsic.x, min.x) end

	if min.y > 0 then intrinsic.y = math.max(intrinsic.y, min.y) end

	if max.x > 0 then intrinsic.x = math.min(intrinsic.x, max.x) end

	if max.y > 0 then intrinsic.y = math.min(intrinsic.y, max.y) end

	self.intrinsic_size = intrinsic:Copy()
	return intrinsic
end

function META:Arrange()
	if self.busy then return end

	self.busy = true
	local tr = self.Owner.transform
	local actual_size = tr:GetSize()
	local dir = self:GetDirection()
	local axis = axis_map[dir]
	local padding = self:GetPadding()
	local child_gap = self:GetChildGap()
	local children = self.Owner:GetChildren()
	local uses_dock_layout = layout_uses_dock(children)
	local layout_children = {}
	local total_grow = 0
	local total_shrink = 0
	local fixed_main_size = 0
	self.uses_dock_layout = uses_dock_layout

	if uses_dock_layout then
		local remaining_x = padding.x
		local remaining_y = padding.y
		local remaining_w = math.max(0, actual_size.x - padding.x - padding.w)
		local remaining_h = math.max(0, actual_size.y - padding.y - padding.h)
		local fill_children = {}

		for _, child in ipairs(children) do
			if should_layout_child(child) then
				local child_size, margin, child_layout = measure_child_layout(child)
				local dock = get_effective_dock(child_layout)
				local child_tr = child.transform
				local base_w = child_size.x
				local base_h = child_size.y
				local total_w = base_w + margin.x + margin.w
				local total_h = base_h + margin.y + margin.h

				if dock == "top" then
					child_tr:SetWidth(math.max(0, remaining_w - margin.x - margin.w))
					child_tr:SetHeight(base_h)
					child_tr:SetX(remaining_x + margin.x)
					child_tr:SetY(remaining_y + margin.y)
					remaining_y = remaining_y + total_h
					remaining_h = math.max(0, remaining_h - total_h)
				elseif dock == "bottom" then
					child_tr:SetWidth(math.max(0, remaining_w - margin.x - margin.w))
					child_tr:SetHeight(base_h)
					child_tr:SetX(remaining_x + margin.x)
					child_tr:SetY(remaining_y + remaining_h - total_h + margin.y)
					remaining_h = math.max(0, remaining_h - total_h)
				elseif dock == "left" then
					child_tr:SetWidth(base_w)
					child_tr:SetHeight(math.max(0, remaining_h - margin.y - margin.h))
					child_tr:SetX(remaining_x + margin.x)
					child_tr:SetY(remaining_y + margin.y)
					remaining_x = remaining_x + total_w
					remaining_w = math.max(0, remaining_w - total_w)
				elseif dock == "right" then
					child_tr:SetWidth(base_w)
					child_tr:SetHeight(math.max(0, remaining_h - margin.y - margin.h))
					child_tr:SetX(remaining_x + remaining_w - total_w + margin.x)
					child_tr:SetY(remaining_y + margin.y)
					remaining_w = math.max(0, remaining_w - total_w)
				else
					fill_children[#fill_children + 1] = {
						layout = child_layout,
						margin = margin,
						transform = child_tr,
					}
				end

				if dock ~= "fill" and child_layout then child_layout:UpdateLayout() end
			end
		end

		for _, child in ipairs(fill_children) do
			child.transform:SetWidth(math.max(0, remaining_w - child.margin.x - child.margin.w))
			child.transform:SetHeight(math.max(0, remaining_h - child.margin.y - child.margin.h))
			child.transform:SetX(remaining_x + child.margin.x)
			child.transform:SetY(remaining_y + child.margin.y)

			if child.layout then child.layout:UpdateLayout() end
		end

		self.busy = false

		if self.pending_child_reflow then
			self.pending_child_reflow = false
			self:SetDirty(true)
		end

		return
	end

	for _, child in ipairs(children) do
		if should_layout_child(child) then
			local l = child.layout
			local margin = l and l:GetMargin() or Rect(0, 0, 0, 0)
			local grow = 0
			local shrink = 0
			local base_size = 0
			local min_main = 0

			if l then
				grow = (dir == "x") and l:GetGrowWidth() or l:GetGrowHeight()
				shrink = (dir == "x") and l:GetShrinkWidth() or l:GetShrinkHeight()
				local sz = l.intrinsic_size or l:Measure()
				base_size = sz[axis.main]
				min_main = l:GetMinSize()[axis.main] or 0
			else
				base_size = child.transform:GetSize()[axis.main]
			end

			if shrink <= 0 and grow > 0 then shrink = grow end

			table.insert(
				layout_children,
				{
					entity = child,
					grow = grow,
					shrink = shrink,
					margin = margin,
					base_size = base_size,
					min_main = min_main,
					cross_size = (l and l.intrinsic_size or child.transform:GetSize())[axis.cross],
				}
			)
			total_grow = total_grow + grow
			total_shrink = total_shrink + shrink
			fixed_main_size = fixed_main_size + base_size + margin[axis.main_margin_start] + margin[axis.main_margin_end]
		end
	end

	if #layout_children > 1 then
		fixed_main_size = fixed_main_size + (#layout_children - 1) * child_gap
	end

	local available_main = actual_size[axis.main] - padding[axis.main_margin_start] - padding[axis.main_margin_end]
	local main_space_delta = available_main - fixed_main_size
	local extra_space = math.max(0, main_space_delta)
	local shrink_space = math.max(0, -main_space_delta)
	-- Position children
	local current_main = padding[axis.main_margin_start]

	-- Handle Alignment (JustifyContent)
	if total_grow == 0 then
		local alignment = (dir == "x") and self:GetAlignmentX() or self:GetAlignmentY()

		if alignment == "center" then
			current_main = current_main + extra_space / 2
		elseif alignment == "end" then
			current_main = current_main + extra_space
		end
	end

	for i, c in ipairs(layout_children) do
		local grow_size = 0
		local shrink_size = 0

		if extra_space > 0 and total_grow > 0 and c.grow > 0 then
			grow_size = extra_space * (c.grow / total_grow)
		end

		if shrink_space > 0 and total_shrink > 0 and c.shrink > 0 then
			local requested = shrink_space * (c.shrink / total_shrink)
			local max_shrink = math.max(0, c.base_size - c.min_main)
			shrink_size = math.min(requested, max_shrink)
		end

		local final_main = c.base_size + grow_size - shrink_size
		local child_tr = c.entity.transform
		-- Position on main axis
		current_main = current_main + c.margin[axis.main_margin_start]
		child_tr["Set" .. axis.main_size](child_tr, final_main)
		child_tr:SetAxisPosition(axis.main, current_main)
		-- Position on cross axis
		local cross_alignment = c.entity.layout and
			get_child_cross_alignment(self, c.entity.layout) or
			(
				(
					dir == "x"
				)
				and
				self:GetAlignmentY() or
				self:GetAlignmentX()
			)
		local available_cross = actual_size[axis.cross] - padding[axis.cross_margin_start] - padding[axis.cross_margin_end]
		local child_total_cross = c.cross_size + c.margin[axis.cross_margin_start] + c.margin[axis.cross_margin_end]
		local cross_pos = padding[axis.cross_margin_start] + c.margin[axis.cross_margin_start]
		local final_cross = c.cross_size

		if cross_alignment == "center" then
			cross_pos = cross_pos + (available_cross - child_total_cross) / 2
		elseif cross_alignment == "end" then
			cross_pos = cross_pos + (available_cross - child_total_cross)
		elseif cross_alignment == "stretch" then
			final_cross = available_cross - c.margin[axis.cross_margin_start] - c.margin[axis.cross_margin_end]
		end

		child_tr["Set" .. axis.cross_size](child_tr, final_cross)
		child_tr:SetAxisPosition(axis.cross, cross_pos)
		current_main = current_main + final_main + c.margin[axis.main_margin_end] + child_gap

		-- Recursive align/arrange if child has layout
		if c.entity.layout then c.entity.layout:UpdateLayout() end
	end

	self.busy = false

	if self.pending_child_reflow then
		self.pending_child_reflow = false
		self:SetDirty(true)
	end
end

function META:UpdateLayout()
	if not self:GetDirty() then return end

	self:SetDirty(false)
	-- Measure Pass
	local intrinsic_size = self:Measure()
	-- If we are FitWidth/Height, we update our own transform size
	self.busy = true
	local tr = self.Owner.transform

	if self:GetFitWidth() then tr:SetWidth(intrinsic_size.x) end

	if self:GetFitHeight() then tr:SetHeight(intrinsic_size.y) end

	self:SetLastSize(tr:GetSize():Copy())
	self.busy = false
	-- Arrange Pass
	self:Arrange()
	self.Owner:CallLocalEvent("OnLayoutUpdated")
	UIDebug.OnDebugLayout(self)
end

-- not sure if this is needed
local signature = {}

function META:OnFirstCreated()
	event.AddListener(
		"Update",
		signature,
		function()
			for _, layout in ipairs(META.Instances) do
				if layout:GetDirty() then
					-- Find the root-most dirty layout
					local root = layout
					local parent = layout.Owner:GetParent()

					while parent and parent:IsValid() and parent.layout and parent.layout:GetDirty() do
						root = parent.layout
						parent = parent:GetParent()
					end

					root:UpdateLayout()
				end
			end
		end,
		{priority = -100}
	)
end

function META:OnLastRemoved()
	event.RemoveListener("Update", signature)
end

return META:Register()
