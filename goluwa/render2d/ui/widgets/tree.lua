local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local system = import("goluwa/system.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local META = Panel:CreateTemplate("tree")
META.CMP.transform = {}
META.CMP.layout = {
	Direction = "y",
	GrowWidth = 1,
	FitHeight = true,
	AlignmentX = "stretch",
}
META.CMP.gui_element = {}
META.CMP.mouse_input = {}
META.CMP.clickable = {}
META.CMP.animation = {}
META:StartStorable()
META:GetSet("IndentSize", nil)
META:GetSet("ToggleSize", 16)
META:GetSet("GuideStep", nil)
META:GetSet("BoxSize", 10)
META:GetSet("CustomPanelPosition", "before_label")
META:GetSet("LabelGrow", nil)
META:GetSet("ToggleOnRowClick", false)
META:GetSet("DoubleClickTime", 0.3)
META:GetSet("AnimationTime", 0.18)
META:GetSet("DragThreshold", 6)
META:GetSet("SharedInstanceColor", nil)
META:GetSet("LineColor", "border")
META:GetSet("BoxFillColor", "surface")
META:GetSet("BoxOutlineColor", "border")
META:GetSet("GlyphColor", "text")
META:GetSet("SelectedColor", "primary")
META:GetSet("HoverColor", "primary")
META:GetSet("RowFont", "body")
META:GetSet("LabelPadding", "XS")
META:GetSet("RowGap", 3)
META:GetSet("DropIndicatorColor", "primary")
META:EndStorable()

local function build_path(parent_path, index)
	if parent_path then return parent_path .. "/" .. index end

	return tostring(index)
end

local function draw_shared_instance_marker(self, size, color)
	render2d.SetTexture(nil)
	render2d.SetColor(color:Unpack())
	render2d.DrawRect(2, math.floor(size.y * 0.5) - 1, math.max(1, size.x - 4), 2)
	render2d.DrawRect(math.floor(size.x * 0.5) - 1, 2, 2, math.max(1, size.y - 4))
end

function META:OnCreate(props)
	if props.layout then
		props.layout = table.merge(META.CMP.layout, props.layout)
	end

	-- State (before BaseClass.OnCreate which may fire events that call back into us)
	self._items = props.Items or {}
	self._selected_key = props.SelectedKey
	self._expanded_state = {}
	self._row_infos = {}
	self._row_order = {}
	self._drag_state = {active = false, source_key = nil, drop_info = nil}
	self._row_click_times = {}
	self._pending_expand_animation_key = nil
	self._ready = false
	self.BaseClass.OnCreate(self, props)
	self:Rebuild()
	self._pending_expand_animation_key = nil
	self._ready = true
	self._drag_enabled = true
end

function META.OnGetText() end

function META.OnGetNodePanel() end

function META.OnIncludeNode() end

function META.OnCanDragNode() end

function META.OnCanDropInside() end

function META.OnCanDrop() end

function META.OnIsExpanded() end

function META.OnGetTextColor() end

function META.OnSelect() end

function META.OnToggle() end

function META.OnDrop() end

function META.OnNodeHover() end

function META.OnNodeContextMenu() end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------
function META:SetItems(new_items)
	self._items = new_items or {}
	self:Rebuild()
	return self
end

function META:GetItems()
	return self._items
end

function META:SetSelectedKey(key)
	local previous_key = self._selected_key
	self._selected_key = key
	self:refresh_row_text(self._row_infos[previous_key])
	self:refresh_row_text(self._row_infos[key])
	return self
end

function META:GetSelectedKey()
	return self._selected_key
end

function META:ExpandAll()
	self:apply_branch_state(self._items, nil, true)
	self:refresh_visibility()
	return self
end

function META:CollapseAll()
	self:apply_branch_state(self._items, nil, false)
	self:refresh_visibility()
	return self
end

function META:ExpandToKey(key)
	self:expand_to_key(self._items, nil, key)
	self:refresh_visibility()
	return self
end

function META:EnsureVisible(key, padding)
	if key == nil then return self end

	local info = self._row_infos[key]

	if not (info and info.clip and info.clip:IsValid()) then return self end

	local parent = self:GetParent()

	while parent and parent.IsValid and parent:IsValid() do
		if parent.ScrollChildIntoView then
			parent:ScrollChildIntoView(info.clip, padding)

			break
		end

		parent = parent:GetParent()
	end

	return self
end

function META:Rebuild()
	if not self._ready then return self end

	self:clear_drag_state()
	self._row_infos = {}
	self._row_order = {}
	self:RemoveChildren()

	for index, node in ipairs(self._items) do
		self:add_node(
			node,
			{
				level = 0,
				index = index,
				is_last = index == #self._items,
				parent_key = nil,
				continuations = {},
			},
			nil
		)
	end

	self:refresh_visibility()
	return self
end

function META:RefreshBranchForKey(key)
	if key == nil then return self:Rebuild() end

	local descriptor = self:find_item_descriptor(self._items, nil, nil, 0, {}, key)

	if not descriptor then return self:Rebuild() end

	local start_index
	local end_index

	for i, row_key in ipairs(self._row_order) do
		if row_key == key then
			start_index = i
			end_index = i

			break
		end
	end

	if not start_index then return self:Rebuild() end

	for i = start_index + 1, #self._row_order do
		local info = self._row_infos[self._row_order[i]]

		if not (info and self:is_key_in_branch(key, info.key)) then break end

		end_index = i
	end

	self:clear_drag_state()

	for i = end_index, start_index, -1 do
		local row_key = self._row_order[i]
		local info = self._row_infos[row_key]

		if info and info.clip and info.clip:IsValid() then info.clip:Remove() end

		self._row_infos[row_key] = nil
		table.remove(self._row_order, i)
	end

	self:add_node(descriptor.node, descriptor.meta, descriptor.parent_path)
	self:refresh_visibility()

	if self._pending_expand_animation_key == key then
		self._pending_expand_animation_key = nil
	end

	return self
end

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------
function META:update_layout_now(entity)
	if not entity or not entity:IsValid() or not entity.layout then return end

	entity.layout:InvalidateLayout()
	local root = entity.layout
	local parent = entity:GetParent()

	while parent and parent:IsValid() and parent.layout do
		root = parent.layout
		parent = parent:GetParent()
	end

	if root.busy ~= nil then root:UpdateLayout() end
end

-- Callback accessors (callback or fallback)
function META:get_text(node, path)
	local val = self.OnGetText(node, path)

	if val ~= nil then return tostring(val) end

	return tostring(node.Text or node.Label or node.Name or node.Value or node.Id or "Item")
end

function META:get_children(node, path)
	return node.Children or {}
end

function META:has_children(node, path)
	if next(self:get_children(node, path)) then return true end

	if node.HasChildren ~= nil then return not not node.HasChildren end

	return false
end

function META:get_key(node, path)
	return tostring(node.Key or node.Id or path)
end

function META:is_selected(node, path, key)
	return self._selected_key ~= nil and self._selected_key == key
end

function META:is_expanded(node, path, key, has_children)
	if not has_children then return false end

	local val = self.OnIsExpanded(node, path, key)

	if val ~= nil then return not not val end

	local expanded = self._expanded_state[key]

	if expanded == nil then
		expanded = node.Expanded == true
		self._expanded_state[key] = expanded
	end

	return expanded
end

function META:get_text_token(node, path, key)
	if node.Disabled then return "text_disabled" end

	if self:is_selected(node, path, key) then return "text_on_accent" end

	local color = self.OnGetTextColor(node, path, key)

	if color ~= nil then return color end

	if node.TextColor ~= nil then return node.TextColor end

	return "text"
end

function META:refresh_row_text(info)
	if not info or not info.text or not info.text:IsValid() then return end

	local selected = self:is_selected(info.node, info.path, info.key)
	info.text.style:SetBackgroundColor(selected and self.SelectedColor or nil)
	info.text.text:SetColor(self:get_text_token(info.node, info.path, info.key))
end

-- Walk up parent chain to check if candidate is under source
function META:is_key_in_branch(source_key, candidate_key)
	local current_key = candidate_key

	while current_key do
		if current_key == source_key then return true end

		local current_info = self._row_infos[current_key]

		if not current_info then break end

		current_key = current_info.parent_key
	end

	return false
end

function META:should_seed_open_fraction(meta)
	return meta.parent_key and
		self._pending_expand_animation_key and
		self:is_key_in_branch(self._pending_expand_animation_key, meta.parent_key)
end

function META:clear_drag_state()
	self._drag_state.active = false
	self._drag_state.source_key = nil
	self._drag_state.drop_info = nil
end

function META:can_drag_node(node, path, key)
	local val = self.OnCanDragNode(node, path, key)

	if val ~= nil then return not not val end

	return not node.Disabled
end

function META:can_drop_inside(node, path, key, has_children)
	local val = self.OnCanDropInside(node, path, key, has_children)

	if val ~= nil then return not not val end

	return has_children
end

function META:find_drop_info(source_info, global_pos)
	if not source_info then return nil end

	for _, key in ipairs(self._row_order) do
		local target_info = self._row_infos[key]

		if
			target_info and
			target_info.clip and
			target_info.clip:IsValid() and
			target_info.clip.gui_element and
			target_info.clip.gui_element:GetVisible() and
			target_info.clip.gui_element:IsHovered(global_pos)
		then
			if target_info.key == source_info.key then return nil end

			local local_pos = target_info.clip.transform:GlobalToLocal(global_pos)
			local height = math.max(target_info.clip.transform:GetHeight(), 1)
			local position
			local allow_inside = self:can_drop_inside(target_info.node, target_info.path, target_info.key, target_info.has_children)

			if allow_inside then
				local edge_size = math.max(4, height * 0.25)

				if local_pos.y <= edge_size then
					position = "before"
				elseif local_pos.y >= height - edge_size then
					position = "after"
				else
					position = "inside"
				end
			else
				position = local_pos.y < height / 2 and "before" or "after"
			end

			local parent_info
			local parent_key

			if position == "inside" then
				parent_info = target_info
				parent_key = target_info.key
			else
				parent_key = target_info.parent_key
				parent_info = parent_key and self._row_infos[parent_key] or nil
			end

			if self:is_key_in_branch(source_info.key, parent_key) then return nil end

			local drop_info = {
				source_node = source_info.node,
				source_key = source_info.key,
				source_path = source_info.path,
				target_node = target_info.node,
				target_key = target_info.key,
				target_path = target_info.path,
				parent_node = parent_info and parent_info.node or nil,
				parent_key = parent_key,
				parent_path = parent_info and parent_info.path or nil,
				position = position,
			}
			local can_drop = self.OnCanDrop(drop_info)

			if can_drop ~= nil and not can_drop then return nil end

			return drop_info
		end
	end

	return nil
end

-- Drag lifecycle
function META:begin_drag(row_info)
	if not self._drag_enabled or not row_info then return end

	if
		row_info.toggle and
		row_info.toggle.mouse_input and
		row_info.toggle.mouse_input:GetHovered()
	then
		if
			row_info.body and
			row_info.body.draggable and
			row_info.body.draggable:IsDragging()
		then
			row_info.body.draggable:StopDragging()
		end

		return
	end

	self._drag_state.active = false
	self._drag_state.source_key = row_info.key
	self._drag_state.drop_info = nil
	self:set_selected(row_info.node, row_info.path, row_info.key)
end

function META:update_drag(row_info, delta, global_pos)
	if
		not self._drag_enabled or
		not row_info or
		self._drag_state.source_key ~= row_info.key
	then
		return true
	end

	if not self._drag_state.active then
		if delta:GetLength() < self.DragThreshold then return true end

		self._drag_state.active = true
	end

	self._drag_state.drop_info = self:find_drop_info(row_info, global_pos)
	return true
end

function META:finish_drag(row_info)
	if
		not self._drag_enabled or
		not row_info or
		self._drag_state.source_key ~= row_info.key
	then
		return
	end

	local drop_info = self._drag_state.active and self._drag_state.drop_info or nil
	self:clear_drag_state()

	if drop_info then self.OnDrop(drop_info) end
end

-- Row display (expand/collapse animation)
function META:update_row_display(info)
	if not self._ready then return end

	if
		not (
			info and
			info.clip and
			info.clip:IsValid() and
			info.body and
			info.body:IsValid()
		)
	then
		return
	end

	local clip_w = info.clip.transform:GetWidth()
	local open_fraction = info.open_fraction or 0

	if open_fraction > 0.001 then info.clip.gui_element:SetVisible(true) end

	info.body.transform:SetWidth(clip_w)
	local body_h = info.body.transform:GetHeight()

	if open_fraction > 0.001 and body_h <= 0.001 then
		self:update_layout_now(info.clip)
		body_h = info.body.transform:GetHeight()
	end

	local target_h = body_h * open_fraction
	info.clip.transform:SetHeight(target_h)
	info.clip.gui_element:SetVisible(target_h > 0.001)
	info.body.transform:SetY(-(body_h - target_h))
end

function META:is_row_visible(info)
	local parent_key = info and info.parent_key

	while parent_key do
		local parent_info = self._row_infos[parent_key]

		if not parent_info then break end

		if
			not self:is_expanded(parent_info.node, parent_info.path, parent_info.key, parent_info.has_children)
		then
			return false
		end

		parent_key = parent_info.parent_key
	end

	return true
end

function META:refresh_visibility()
	for _, key in ipairs(self._row_order) do
		local info = self._row_infos[key]

		if not (info and info.clip and info.clip:IsValid() and info.clip.gui_element) then
			goto continue
		end

		local target = self:is_row_visible(info) and 1 or 0

		if info.open_fraction == nil then
			info.open_fraction = target
			self:update_row_display(info)
		elseif info.open_fraction ~= target then
			if self.AnimationTime <= 0 then
				info.open_fraction = target
				self:update_row_display(info)
			else
				local tree = self
				local animation_time = self.AnimationTime
				tree.animation:Animate{
					id = "tree_row_open_" .. key,
					get = function()
						return info.open_fraction or 0
					end,
					set = function(v)
						info.open_fraction = v
						tree:update_row_display(info)
					end,
					to = target,
					time = animation_time,
					interpolation = target > (info.open_fraction or 0) and "outExpo" or "outCubic",
				}
			end
		end

		::continue::
	end

	self:update_layout_now(self)
end

-- Fire toggle callback + set expanded state (used by set_expanded, apply_branch_state, expand_to_key)
function META:fire_toggle(node, expanded, key, path)
	local val = self.OnIsExpanded(node, path, key)

	if val == nil then self._expanded_state[key] = expanded end

	self.OnToggle(node, expanded, key, path)
end

function META:set_expanded(node, path, key, expanded)
	if self.OnIsExpanded(node, path, key) ~= nil and expanded then
		self._pending_expand_animation_key = key
	end

	self:fire_toggle(node, expanded, key, path)
	self:refresh_visibility()
end

function META:set_selected(node, path, key)
	local previous_key = self._selected_key
	self._selected_key = key
	self.OnSelect(node, key, path)
	self:refresh_row_text(self._row_infos[previous_key])
	self:refresh_row_text(self._row_infos[key])
end

function META:apply_branch_state(nodes, parent_path, expanded)
	for index, node in ipairs(nodes) do
		local path = build_path(parent_path, index)
		local key = self:get_key(node, path)
		local children = self:get_children(node, path)

		if next(children) then
			self:fire_toggle(node, expanded, key, path)
			self:apply_branch_state(children, path, expanded)
		end
	end
end

function META:find_item_descriptor(nodes, parent_path, parent_key, level, continuations, target_key)
	for index, node in ipairs(nodes) do
		local path = build_path(parent_path, index)
		local key = self:get_key(node, path)
		local meta = {
			level = level,
			index = index,
			is_last = index == #nodes,
			parent_key = parent_key,
			continuations = continuations,
		}

		if key == target_key then
			return {node = node, path = path, key = key, meta = meta, parent_path = parent_path}
		end

		local children = self:get_children(node, path)

		if next(children) then
			local child_continuations = table.shallow_copy(continuations)
			child_continuations[level + 1] = index ~= #nodes
			local found = self:find_item_descriptor(children, path, key, level + 1, child_continuations, target_key)

			if found then return found end
		end
	end
end

function META:expand_to_key(nodes, parent_path, target_key)
	for index, node in ipairs(nodes) do
		local path = build_path(parent_path, index)
		local key = self:get_key(node, path)
		local children = self:get_children(node, path)

		if key == target_key then return true end

		if next(children) and self:expand_to_key(children, path, target_key) then
			self:fire_toggle(node, true, key, path)
			return true
		end
	end

	return false
end

-- ---------------------------------------------------------------------------
-- Row / node building
-- ---------------------------------------------------------------------------
function META:add_node(node, meta, parent_path, insert_index)
	insert_index = insert_index or 1
	local path = build_path(parent_path, meta.index)
	local key = self:get_key(node, path)
	local include = self.OnIncludeNode(node, path, key)

	if include ~= nil and not include then return insert_index end

	local children = self:get_children(node, path)
	local has_children = self:has_children(node, path)
	local expanded = self:is_expanded(node, path, key, has_children)
	local selected = self:is_selected(node, path, key)
	local custom_panel = self:get_node_panel(node, path, key, selected, has_children, expanded)
	local tree = self
	local row_info = {
		tree = tree,
		node = node,
		path = path,
		key = key,
		surface = selected and self.SelectedColor or nil,
		parent_key = meta.parent_key,
		has_children = has_children,
		open_fraction = self:should_seed_open_fraction(meta) and 0 or nil,
		toggle = nil,
	}
	self._row_infos[key] = row_info
	table.insert(self._row_order, insert_index, key)
	local label = self:make_label(node, path, key, selected, row_info)
	local row_children = {
		has_children and
		self:make_toggle(node, path, key, meta, row_info) or
		self:make_toggle_placeholder(meta),
	}

	if self.CustomPanelPosition == "before_label" then
		if custom_panel then row_children[#row_children + 1] = custom_panel end

		row_children[#row_children + 1] = label
	else
		row_children[#row_children + 1] = label

		if custom_panel then row_children[#row_children + 1] = custom_panel end
	end

	-- Shared listener setup for clip/body transform changes
	local function on_row_layout_changed()
		tree:update_row_display(row_info)
	end

	local row = Panel.New{
		IsInternal = true,
		Name = "TreeRowBody",
		transform = true,
		layout = {
			Direction = "x",
			AlignmentY = "stretch",
			FitHeight = true,
			GrowWidth = 1,
			FitWidth = false,
			ChildGap = self.RowGap,
			Floating = true,
		},
		gui_element = true,
		mouse_input = {
			Cursor = node.Disabled and "arrow" or "pointer",
			OnHover = function(self, is_hovered)
				row_info.hovered = is_hovered
				tree.OnNodeHover(node, key, path, row_info, is_hovered, self.Owner)
			end,
		},
		draggable = self._drag_enabled and self:can_drag_node(node, path, key),
		OnDragStarted = function()
			tree:begin_drag(row_info)
		end,
		OnDrag = function(self, delta, global_pos)
			return tree:update_drag(row_info, delta, global_pos)
		end,
		OnDragStopped = function()
			tree:finish_drag(row_info)
		end,
		clickable = {
			DoubleClickKey = key,
			DoubleClickTime = self.DoubleClickTime,
		},
		OnClick = function(self)
			if node.Disabled then return end

			local now = system.GetElapsedTime()
			local last_click = tree._row_click_times[key]
			local is_double_click = last_click and now - last_click <= tree.DoubleClickTime

			if is_double_click then
				tree._row_click_times[key] = nil
			else
				tree._row_click_times[key] = now
			end

			tree:set_selected(node, path, key)

			if has_children then
				if tree.ToggleOnRowClick or is_double_click then
					tree:set_expanded(node, path, key, not tree:is_expanded(node, path, key, has_children))
				end
			end

			return true
		end,
		OnDoubleClick = function() end,
		OnRightClick = function(self)
			if node.Disabled then return end

			tree:set_selected(node, path, key)
			return tree.OnNodeContextMenu(node, key, path, row_info, self.Owner)
		end,
	}(row_children)
	row_info.body = row
	row:AddLocalListener("OnTransformChanged", on_row_layout_changed)
	row:AddLocalListener("OnLayoutUpdated", on_row_layout_changed)
	local clip = Panel.New{
		IsInternal = true,
		Name = "TreeRow",
		Ref = function(self)
			row_info.clip = self
		end,
		transform = {
			Size = Vec2(0, 0),
		},
		layout = {
			GrowWidth = 1,
			FitHeight = false,
		},
		gui_element = {
			Clipping = true,
			Visible = false,
			OnPostDraw = function(self)
				local drop_info = tree._drag_state.active and tree._drag_state.drop_info or nil
				local is_source = tree._drag_state.active and tree._drag_state.source_key == key

				if not is_source and (not drop_info or drop_info.target_key ~= key) then
					return
				end

				self.Owner:SetState("theme_role", "tree_drop_indicator")
				self.Owner:SetState(
					"drop_indicator_opts",
					{
						color = tree.DropIndicatorColor,
						source = is_source,
						position = drop_info and drop_info.target_key == key and drop_info.position or nil,
						thickness = 2,
					}
				)
				theme.active:DrawPost(self.Owner)
			end,
		},
		mouse_input = true,
		animation = true,
	}(row)
	clip:AddLocalListener("OnTransformChanged", on_row_layout_changed)
	clip:AddLocalListener("OnLayoutUpdated", on_row_layout_changed)
	tree:AddChild(clip, insert_index)
	insert_index = insert_index + 1

	if has_children then
		local child_continuations = table.shallow_copy(meta.continuations)
		child_continuations[meta.level + 1] = not meta.is_last

		for child_index, child in ipairs(children) do
			insert_index = tree:add_node(
				child,
				{
					level = meta.level + 1,
					index = child_index,
					is_last = child_index == #children,
					parent_key = key,
					continuations = child_continuations,
				},
				path,
				insert_index
			)
		end
	end

	return insert_index
end

-- ---------------------------------------------------------------------------
-- Panel builders (toggle, label, placeholder)
-- ---------------------------------------------------------------------------
do
	function META:make_toggle(node, path, key, meta, row_info)
		local tree = self
		local toggle_size = self.ToggleSize
		local guide_step = self.GuideStep or
			math.max(self.IndentSize or theme.active:GetSize("M"), toggle_size)
		local box_size = self.BoxSize
		local center_x = meta.level * guide_step + math.floor(toggle_size / 2)
		local half_box = math.floor(box_size / 2)
		return Panel.New{
			IsInternal = true,
			Name = "TreeToggle",
			Ref = function(self)
				row_info.toggle = self
			end,
			transform = {
				Size = Vec2(math.max(toggle_size, meta.level * guide_step + toggle_size + 6), toggle_size),
			},
			gui_element = {
				OnDraw = function(self)
					local row_has_children = tree:has_children(node, path)
					local current_expanded = tree:is_expanded(node, path, key, row_has_children)
					self.Owner:SetState("theme_role", row_has_children and "tree_toggle" or "tree_guides")
					self.Owner:SetState("tree_meta", meta)
					self.Owner:SetState(
						"tree_opts",
						{
							line_color = tree.LineColor,
							box_fill = tree.BoxFillColor,
							box_outline = tree.BoxOutlineColor,
							glyph_color = tree.GlyphColor,
							toggle_size = toggle_size,
							guide_step = guide_step,
							box_size = box_size,
							line_start_x = row_has_children and (center_x + half_box) or center_x,
							expanded = current_expanded,
						}
					)
					theme.active:Draw(self.Owner)
				end,
			},
			mouse_input = {
				Cursor = "pointer",
			},
			OnClick = function()
				tree:set_expanded(node, path, key, not tree:is_expanded(node, path, key, true))
				return true
			end,
			clickable = true,
		}
	end

	function META:make_label(node, path, key, selected, row_info)
		local tree = self
		local label_grow = tree.LabelGrow == true or tree.CustomPanelPosition == "after_label"
		return Panel.New{
			IsInternal = true,
			Name = "TreeLabel",
			transform = true,
			layout = {
				FitWidth = not label_grow,
				FitHeight = true,
				GrowWidth = label_grow and 1 or nil,
				Padding = tree.LabelPadding,
			},
			gui_element = {
				OnDraw = function(self)
					self.Owner:SetState("theme_role", "tree_label")
					self.Owner:SetState("selected", tree:is_selected(node, path, key))
					self.Owner:SetState("selected_color", tree.SelectedColor)
					self.Owner:SetState("hovered", row_info.hovered)
					self.Owner:SetState("hover_color", theme.active:GetColor(tree.HoverColor):Copy():SetAlpha(0.08))
					theme.active:Draw(self.Owner)
				end,
			},
			mouse_input = {
				IgnoreMouseInput = true,
			},
		}{
			Text{
				Ref = function(self)
					row_info.text = self
					tree:refresh_row_text(row_info)
				end,
				Text = tree:get_text(node, path),
				Font = node.Font or (tree.RowFont),
				BackgroundColor = selected and tree.SelectedColor or nil,
				Color = node.Disabled and
					"text_disabled" or
					(
						selected and
						"text_on_accent" or
						"text"
					),
				IgnoreMouseInput = true,
				layout = {
					FitWidth = true,
					FitHeight = true,
				},
			},
		}
	end

	function META:make_toggle_placeholder(meta)
		local toggle_size = self.ToggleSize
		local guide_step = self.GuideStep or
			math.max(self.IndentSize or theme.active:GetSize("M"), toggle_size)
		return Panel.New{
			IsInternal = true,
			Name = "TreeTogglePlaceholder",
			transform = {
				Size = Vec2(math.max(toggle_size, meta.level * guide_step + toggle_size + 6), toggle_size),
			},
			gui_element = {
				OnDraw = function(self)
					self.Owner:SetState("theme_role", "tree_guides")
					self.Owner:SetState("tree_meta", meta)
					self.Owner:SetState(
						"tree_opts",
						{
							line_color = self.LineColor,
							toggle_size = toggle_size,
							guide_step = guide_step,
						}
					)
					theme.active:Draw(self.Owner)
				end,
			},
			mouse_input = {
				IgnoreMouseInput = true,
			},
		}
	end
end

-- ---------------------------------------------------------------------------
-- Shared instance marker
-- ---------------------------------------------------------------------------
function META:get_node_panel(node, path, key, selected, has_children, expanded)
	if node.SharedInstance and self.SharedInstanceColor then
		local shared_instance_color = self.SharedInstanceColor
		return Panel.New{
			IsInternal = true,
			Name = "TreeSharedInstanceMarker",
			transform = {
				Size = Vec2(12, 12),
			},
			layout = {
				SelfAlignmentY = "center",
				GrowWidth = 0,
				FitWidth = false,
			},
			mouse_input = {
				IgnoreMouseInput = true,
			},
			gui_element = {
				OnDraw = function(self)
					local size = self.Owner.transform:GetSize()
					draw_shared_instance_marker(self, size, shared_instance_color)
				end,
			},
		}
	end

	return self.OnGetNodePanel(node, path, key, selected, has_children, expanded)
end

META:Register()
return META.New
