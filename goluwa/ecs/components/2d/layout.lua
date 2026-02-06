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
META:GetSet("AlignmentX", "start", {callback = "InvalidateLayout"})
META:GetSet("AlignmentY", "start", {callback = "InvalidateLayout"})
META:GetSet("Floating", false, {callback = "InvalidateLayout"})
META:GetSet("Dirty", false)
META:GetSet("LastSize", Vec2(0, 0))
META:EndStorable()

function META:InvalidateLayout()
	if self:GetDirty() then return end

	self:SetDirty(true)
	local parent = self.Owner:GetParent()

	if parent and parent:IsValid() and parent.layout then
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

function META:Measure()
	local dir = self:GetDirection()
	local axis = axis_map[dir]
	local padding = self:GetPadding()
	local child_gap = self:GetChildGap()
	local main_total = 0
	local cross_max = 0
	local children = self.Owner:GetChildren()
	local count = 0

	for _, child in ipairs(children) do
		local gui = child.gui_element

		if
			child:IsValid() and
			(
				not gui or
				gui:GetVisible()
			)
			and
			not (
				child.layout and
				child.layout:GetFloating()
			)
		then
			local child_size
			local child_margin

			if child.layout then
				child_size = child.layout:Measure()
				child_margin = child.layout:GetMargin()
			else
				child_size = child.transform:GetSize()
				child_margin = Rect(0, 0, 0, 0)
			end

			local child_main = child_size[axis.main] + child_margin[axis.main_margin_start] + child_margin[axis.main_margin_end]
			local child_cross = child_size[axis.cross] + child_margin[axis.cross_margin_start] + child_margin[axis.cross_margin_end]

			if count > 0 then main_total = main_total + child_gap end

			main_total = main_total + child_main
			cross_max = math.max(cross_max, child_cross)
			count = count + 1
		end
	end

	local intrinsic = Vec2(0, 0)
	local tr_size = self.Owner.transform:GetSize()

	if dir == "x" then
		intrinsic.x = self:GetFitWidth() and (main_total + padding.x + padding.w) or tr_size.x
		intrinsic.y = self:GetFitHeight() and (cross_max + padding.y + padding.h) or tr_size.y
	else
		intrinsic.x = self:GetFitWidth() and (cross_max + padding.x + padding.w) or tr_size.x
		intrinsic.y = self:GetFitHeight() and (main_total + padding.y + padding.h) or tr_size.y
	end

	-- If we have no children but have a text component, use its size
	if count == 0 and self.Owner.text then
		local font = self.Owner.text:GetFont()
		local text = self.Owner.text.wrapped_text or self.Owner.text:GetText()

		if font and text then
			local w, h = font:GetTextSize(text)

			if self:GetFitWidth() then intrinsic.x = w + padding.x + padding.w end

			if self:GetFitHeight() then intrinsic.y = h + padding.y + padding.h end
		end
	end

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
	self:SetDirty(false)
	local tr = self.Owner.transform
	local actual_size = tr:GetSize()
	local dir = self:GetDirection()
	local axis = axis_map[dir]
	local padding = self:GetPadding()
	local child_gap = self:GetChildGap()
	local children = self.Owner:GetChildren()
	local layout_children = {}
	local total_grow = 0
	local fixed_main_size = 0

	for _, child in ipairs(children) do
		local gui = child.gui_element

		if
			child:IsValid() and
			(
				not gui or
				gui:GetVisible()
			)
			and
			not (
				child.layout and
				child.layout:GetFloating()
			)
		then
			local l = child.layout
			local margin = l and l:GetMargin() or Rect(0, 0, 0, 0)
			local grow = 0
			local base_size = 0

			if l then
				grow = (dir == "x") and l:GetGrowWidth() or l:GetGrowHeight()
				local sz = l.intrinsic_size or l:Measure()
				base_size = sz[axis.main]
			else
				base_size = child.transform:GetSize()[axis.main]
			end

			table.insert(
				layout_children,
				{
					entity = child,
					grow = grow,
					margin = margin,
					base_size = base_size,
					cross_size = (l and l.intrinsic_size or child.transform:GetSize())[axis.cross],
				}
			)
			total_grow = total_grow + grow
			fixed_main_size = fixed_main_size + base_size + margin[axis.main_margin_start] + margin[axis.main_margin_end]
		end
	end

	if #layout_children > 1 then
		fixed_main_size = fixed_main_size + (#layout_children - 1) * child_gap
	end

	local available_main = actual_size[axis.main] - padding[axis.main_margin_start] - padding[axis.main_margin_end]
	local extra_space = math.max(0, available_main - fixed_main_size)
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

		if total_grow > 0 and c.grow > 0 then
			grow_size = extra_space * (c.grow / total_grow)
		end

		local final_main = c.base_size + grow_size
		local child_tr = c.entity.transform
		-- Position on main axis
		current_main = current_main + c.margin[axis.main_margin_start]
		child_tr["Set" .. axis.main_size](child_tr, final_main)
		child_tr:SetAxisPosition(axis.main, current_main)
		-- Position on cross axis
		local cross_alignment = (dir == "x") and self:GetAlignmentY() or self:GetAlignmentX()
		local available_cross = actual_size[axis.cross] - padding[axis.cross_margin_start] - padding[axis.cross_margin_end]
		local child_total_cross = c.cross_size + c.margin[axis.cross_margin_start] + c.margin[axis.cross_margin_end]
		local cross_pos = padding[axis.cross_margin_start] + c.margin[axis.cross_margin_start]

		if cross_alignment == "center" then
			cross_pos = cross_pos + (available_cross - child_total_cross) / 2
		elseif cross_alignment == "end" then
			cross_pos = cross_pos + (available_cross - child_total_cross)
		elseif cross_alignment == "stretch" then
			child_tr["Set" .. axis.cross_size](
				child_tr,
				available_cross - c.margin[axis.cross_margin_start] - c.margin[axis.cross_margin_end]
			)
		end

		child_tr:SetAxisPosition(axis.cross, cross_pos)
		current_main = current_main + final_main + c.margin[axis.main_margin_end] + child_gap

		-- Recursive arrange if child has layout
		if c.entity.layout then c.entity.layout:Arrange() end
	end

	self.busy = false
end

function META:UpdateLayout()
	if not self:GetDirty() then return end

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
	self:SetDirty(false)
end

function META:Initialize()
	self.Owner:AddLocalListener("OnParent", function()
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
		{priority = 101}
	)
end

function META:OnLastRemoved()
	event.RemoveListener("Update", signature)
end

return META:Register()
