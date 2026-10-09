local Panel = import("goluwa/render2d/ui/panel.lua")
local objects = import("goluwa/objects/objects.lua")
local META = Panel:CreateTemplate("entity_tree")
local Entity = import("goluwa/entities/entity.lua")
META.Base = import("goluwa/render2d/ui/widgets/tree.lua")
META.debug = false

local function get_entity_label(entity)
	local name = entity:GetName()
	local key = entity:GetKey()
	local base = name ~= "" and name or (key ~= "" and key or entity.Type or "entity")

	if name ~= "" and key ~= "" and key ~= name then
		base = name .. " [" .. key .. "]"
	end

	return base
end

local function is_world_root(entity)
	return entity == Panel.World or entity == (entity._world and entity._world == entity)
end

local function log_refresh(reason)
	if not META.debug then return end

	print("[entity_tree] Request refresh: " .. reason)
	print(debug.traceback())
end

local function log_hierarchy(action, entity_name)
	if not META.debug then return end

	print("[entity_tree] Hierarchy event: " .. action .. " " .. entity_name)
end

local function build_virtual_children(entity, guid)
	local children = {}

	for _, component in ipairs(entity:GetComponents()) do
		for _, info in ipairs(objects.GetStorableVariables(component)) do
			local value = objects.GetProperty(component, info.var_name)

			if
				type(value) == "table" and
				type(value.IsValid) == "function" and
				value:IsValid() and
				value.GetGUID
			then
				children[#children + 1] = {
					Object = value,
					Key = guid .. "/virtual/" .. component.Type .. "/" .. info.var_name,
					Text = info.var_name,
					HasChildren = false,
					Children = {},
					SharedInstance = true,
				}
			end
		end
	end

	return children
end

local function build_entity_node(entity, expanded_keys, filter_callback, show_virtual, visited)
	if visited[entity] then return nil end

	visited[entity] = true
	local guid = entity:GetGUID()
	local expanded = expanded_keys[guid] == true
	local children = {}
	local has_children = false

	if expanded then
		for _, child in ipairs(entity:GetChildren()) do
			if filter_callback and filter_callback(child) then goto continue end

			local child_node = build_entity_node(child, expanded_keys, filter_callback, show_virtual, visited)

			if child_node then
				children[#children + 1] = child_node
				has_children = true
			end

			::continue::
		end
	end

	if not expanded then
		for _, child in ipairs(entity:GetChildren()) do
			if filter_callback and filter_callback(child) then goto continue end

			has_children = true

			break

			::continue::
		end
	end

	if show_virtual then
		local virtual_children = build_virtual_children(entity, guid)

		for _, vc in ipairs(virtual_children) do
			children[#children + 1] = vc
			has_children = true
		end
	end

	visited[entity] = nil
	return {
		Entity = entity,
		Key = guid,
		Text = get_entity_label(entity),
		HasChildren = has_children,
		Children = children,
	}
end

local function build_tree_items(root_entities, root_labels, expanded_keys, filter_callback, show_virtual)
	local items = {}

	for i, entity in ipairs(root_entities) do
		local label = root_labels and root_labels[entity] or get_entity_label(entity)

		if filter_callback and filter_callback(entity) then
			items[#items + 1] = {
				Entity = entity,
				Key = entity:GetGUID(),
				Text = label,
				HasChildren = false,
				Children = {},
				_HiddenRoot = true,
			}
		else
			local visited = {}
			local node = build_entity_node(entity, expanded_keys, filter_callback, show_virtual, visited)

			if node then
				node.Text = label
				items[#items + 1] = node
			end
		end

		::continue::
	end

	return items
end

local function find_item_in_tree(items, key)
	for _, item in ipairs(items or {}) do
		if item.Key == key then return item end

		local found = find_item_in_tree(item.Children, key)

		if found then return found end
	end

	return nil
end

META:StartStorable()
META:GetSet("RootEntities", nil)
META:GetSet("RootLabels", nil)
META:GetSet("FilterCallback", nil)
META:GetSet("ShowVirtualChildren", false)
META:GetSet("ExpandRootsOnInit", true)
META:GetSet("OnExpanded", nil)
META:EndStorable()

function META:OnCreate()
	self._expanded_keys = self.ExpandedKeys or self._expanded_keys or {}
	self._selected_entity_guid = nil
	self._root_entities = self._root_entities or {}
	self._root_labels = self._root_labels or {}
	self._effective_filter = self._filter_callback
	self._show_virtual = self._show_virtual == true
	self._nearby = {}
	self._nearby_root = self.NearbyRoot
	self._expanded_keys.nearby = true
	self._on_expanded = self.OnExpanded
	self._hierarchy_dirty = false

	if #self._root_entities == 0 then
		self._root_entities = {Panel.World}
		local entity_world = import("goluwa/entities/entity.lua").World
		table.insert(self._root_entities, entity_world)
	end

	if not self._root_labels[Panel.World] then
		self._root_labels[Panel.World] = "2D World"
	end

	for _, entity in ipairs(self._root_entities) do
		if not self._root_labels[entity] then
			self._root_labels[entity] = get_entity_label(entity)
		end
	end

	if self.ExpandRootsOnInit then
		for _, entity in ipairs(self._root_entities) do
			self._expanded_keys[entity:GetGUID()] = true
		end
	end

	local items = build_tree_items(
		self._root_entities,
		self._root_labels,
		self._expanded_keys,
		self._effective_filter,
		self._show_virtual
	)
	self:insert_nearby(items)
	self._items = items
	META.BaseClass.OnCreate(self)
	self._hierarchy_listeners = {}
	self._hierarchy_queue = {}

	local function add_hierarchy_listener(world)
		local tree = self
		local remove = world:AddLocalListener("OnEntityHierarchyChanged", function(_, entity, action, parent)
			if tree._refreshing then return end

			if tree:AreMutationsBlocked() then return end

			table.insert(
				tree._hierarchy_queue,
				{entity = entity, guid = entity:GetGUID(), action = action, parent = parent}
			)
		end)

		if remove then table.insert(self._hierarchy_listeners, remove) end
	end

	for _, entity in ipairs(self._root_entities) do
		add_hierarchy_listener(entity:GetRoot())
	end

	local function process_hierarchy_queue()
		local tree = self
		local queue = tree._hierarchy_queue

		if #queue == 0 then return end

		tree._hierarchy_queue = {}

		for _, entry in ipairs(queue) do
			local entity = entry.entity

			if entry.action == "unparented" then
				tree:try_incremental_remove(entry.guid)
				tree:try_incremental_remove("nearby/" .. entry.guid)

				goto continue
			end

			if tree._search_visible then goto continue end

			if not entity:IsValid() then goto continue end

			local parent = entity:GetParent()

			if self._effective_filter and self._effective_filter(entity) then
				goto continue
			end

			log_hierarchy(entry.action, entity:GetName())

			if entry.action == "parented" then
				local ok, reason = tree:try_incremental_insert(entity, parent)
			else
				print("unknown action: " .. entry.action)
			end

			::continue::
		end
	end

	local event = import("goluwa/event.lua")
	table.insert(
		self._hierarchy_listeners,
		event.AddListener("FrameEnd", self, process_hierarchy_queue)
	)

	self:CallOnRemove(
		function()
			for _, remove in ipairs(self._hierarchy_listeners) do
				if type(remove) == "function" then remove() end
			end
		end,
		"entity_tree_cleanup"
	)
end

function META:set_expanded(node, path, key, expanded)
	self._expanded_keys[key] = expanded

	if expanded and node and node.Entity and node.Entity:IsValid() then
		local entity = node.Entity
		local visited = {}
		local children = {}
		local filter = self._effective_filter

		for _, child in ipairs(entity:GetChildren()) do
			if filter and filter(child) then goto continue end

			local child_node = build_entity_node(
				child,
				self._expanded_keys,
				filter,
				self._show_virtual and not self._search_visible,
				visited
			)

			if child_node then children[#children + 1] = child_node end

			::continue::
		end

		if entity == self._nearby_root and not self._search_visible then
			table.insert(children, 1, self:build_nearby_node())
		end

		if self._show_virtual and not self._search_visible then
			for _, vc in ipairs(build_virtual_children(entity, key)) do
				children[#children + 1] = vc
			end
		end

		local tree_items = self:GetItems()
		local parent_item = find_item_in_tree(tree_items, key)

		if parent_item then parent_item.Children = children end

		self._pending_expand_animation_key = key
		self:refresh_branch_children(key)

		if self._on_expanded then self._on_expanded(key, expanded) end

		return
	end

	META.BaseClass.set_expanded(self, node, path, key, expanded)

	if self._on_expanded then self._on_expanded(key, expanded) end
end

function META.OnGetText(node, path)
	return node.Text or "item"
end

function META:is_expanded(node, path, key, has_children)
	if not has_children then return false end

	return self._expanded_keys[key] == true
end

function META:set_selected(node, path, key)
	local target = node and (node.Entity or node.Object)

	if target and target:IsValid() then
		self._selected_entity_guid = target:GetGUID()
	end

	META.BaseClass.set_selected(self, node, path, key)
end

function META.OnToggle(node, expanded, key, path) end

function META.OnNodeHover(node, key, path, row_info, hovered, owner) end

function META.OnNodeContextMenu(node, key, path, row_info, owner) end

function META.OnCanDragNode(node, path, key)
	if not node or not node.Entity then return false end

	return not is_world_root(node.Entity)
end

function META.OnCanDropInside(node, path, key, has_children)
	return node and node.Entity and node.Entity:IsValid()
end

function META.OnDrop(drop_info)
	local source_entity = drop_info.source_node and drop_info.source_node.Entity
	local target_entity = drop_info.target_node and drop_info.target_node.Entity
	local parent_entity = drop_info.parent_node and drop_info.parent_node.Entity

	if not (source_entity and source_entity:IsValid()) then return false end

	local next_parent

	if drop_info.position == "inside" then
		next_parent = target_entity
	else
		next_parent = parent_entity or source_entity:GetRoot()
	end

	if not (next_parent and next_parent:IsValid()) then
		next_parent = source_entity:GetRoot()
	end

	if next_parent == source_entity then return false end

	if source_entity:GetRoot() ~= next_parent:GetRoot() then return false end

	if
		next_parent ~= source_entity:GetRoot() and
		next_parent:ContainsParent(source_entity)
	then
		return false
	end

	if source_entity:GetParent() == next_parent then return false end

	source_entity:SetParent(next_parent)
	return true
end

function META:SetRootEntities(entities)
	self._root_entities = entities or {}
	self:Refresh()
	return self
end

function META:GetRootEntities()
	return self._root_entities
end

function META:SetRootLabels(labels)
	self._root_labels = labels or {}
	self:Refresh()
	return self
end

function META:GetRootLabels()
	return self._root_labels
end

function META:SetFilterCallback(callback)
	self._filter_callback = callback
	self:update_effective_filter()
	self:Refresh()
	return self
end

function META:GetFilterCallback()
	return self._filter_callback
end

function META:SetShowVirtualChildren(show)
	self._show_virtual = show == true
	self:Refresh()
	return self
end

function META:GetShowVirtualChildren()
	return self._show_virtual
end

function META:SetOnExpanded(callback)
	self._on_expanded = callback
	return self
end

function META:GetOnExpanded()
	return self._on_expanded
end

function META:GetExpandedKeys()
	return self._expanded_keys
end

function META:GetSelectedEntity()
	if not self._selected_entity_guid then return nil end

	return objects.GetObjectByGUID(self._selected_entity_guid)
end

function META:GetSelectedEntityGUID()
	return self._selected_entity_guid
end

function META:SelectEntity(entity)
	self._selected_entity_guid = entity:GetGUID()
	self:SetSelectedKey(entity:GetGUID())
	return self
end

function META:ExpandToEntity(entity)
	if not entity or not entity:IsValid() then return self end

	local guid = entity:GetGUID()
	local info = self._row_infos[guid]

	if info then
		local fully_open = true

		while info do
			if info.open_fraction ~= 1 then
				fully_open = false

				break
			end

			info = info.parent_key and self._row_infos[info.parent_key]
		end

		if fully_open then
			self:SetSelectedKey(guid)
			self:EnsureVisible(guid)
			return self
		end
	end

	if entity.GetParent then
		local parent = entity:GetParent()

		while parent and parent:IsValid() and parent ~= Panel.World and parent ~= Entity.World do
			self._expanded_keys[parent:GetGUID()] = true
			parent = parent:GetParent()
		end
	end

	self._expanded_keys[guid] = true
	self:Refresh(true)
	self:SetSelectedKey(guid)
	self:EnsureVisible(guid)
	return self
end

function META:EnsureEntityVisible(entity, padding)
	self:EnsureVisible(entity:GetGUID(), padding)
	return self
end

function META:GetSelectedNode()
	local key = self:GetSelectedKey()

	if not key then return nil end

	local info = self._row_infos[key]
	return info and info.node or nil
end

function META:ExpandRoots()
	for _, entity in ipairs(self._root_entities) do
		self._expanded_keys[entity:GetGUID()] = true
	end

	self:Refresh()
	return self
end

function META:CollapseRoots()
	for _, entity in ipairs(self._root_entities) do
		self._expanded_keys[entity:GetGUID()] = nil
	end

	self:Refresh()
	return self
end

function META:Refresh(force)
	if self._refreshing or not self._ready then return self end

	if not force then
		log_refresh("Refresh_debounced")
		self._pending_refresh = true
		self._refresh_deadline = import("goluwa/system.lua").GetElapsedTime() + self._refresh_debounce
		return self
	end

	log_refresh("Refresh_forced")
	self._refreshing = true
	local items = build_tree_items(
		self._root_entities,
		self._root_labels,
		self._expanded_keys,
		self._effective_filter,
		self._show_virtual and not self._search_visible
	)
	self:insert_nearby(items)
	self:SetItems(items)
	self._refreshing = false
	return self
end

function META:RefreshBranch(entity)
	return self:RefreshBranchForKey(entity:GetGUID())
end

function META:refresh_visibility()
	self:BlockMutations()
	local result = META.BaseClass.refresh_visibility(self)
	self:UnblockMutations()
	return result
end

function META:FullRefresh(reason)
	if META.debug and reason then print("[entity_tree] FullRefresh: ", reason) end

	self._hierarchy_dirty = true
end

function META:try_incremental_insert(entity, parent)
	if self._effective_filter and self._effective_filter(entity) then
		return true
	end

	local parent_key = parent and parent:GetGUID() or nil
	local parent_item

	if parent_key then
		parent_item = find_item_in_tree(self:GetItems(), parent_key)

		if not parent_item then return false, "parent_item_not_found" end

		if not self._expanded_keys[parent_key] then
			return false, "parent_not_expanded"
		end
	else
		for _, root in ipairs(self._root_entities) do
			if entity:GetRoot() == root then
				parent_key = root:GetGUID()
				parent_item = find_item_in_tree(self:GetItems(), parent_key)

				break
			end
		end

		if not parent_item then return false, "root_parent_item_not_found" end

		if not self._expanded_keys[parent_key] then
			return false, "root_parent_not_expanded"
		end
	end

	local new_item = build_entity_node(
		entity,
		self._expanded_keys,
		self._effective_filter,
		self._show_virtual and not self._search_visible,
		{}
	)

	if not new_item then return false, "build_entity_node_failed" end

	parent_item.Children[#parent_item.Children + 1] = new_item
	self:AddNode(new_item, parent_key)
	return true
end

function META:try_incremental_remove(guid)
	local item = find_item_in_tree(self:GetItems(), guid)

	if not item then return false, "item_not_found_in_tree" end

	local function remove_from(items, key)
		for i, v in ipairs(items) do
			if v.Key == key then
				table.remove(items, i)
				return true
			end

			if remove_from(v.Children, key) then return true end
		end

		return false
	end

	remove_from(self:GetItems(), guid)
	self:remove_node_rows(guid)
	self:refresh_visibility()
	return true
end

function META:update_effective_filter()
	local base = self._filter_callback
	local visible = self._search_visible

	if not visible then
		self._effective_filter = base
		return
	end

	self._effective_filter = function(entity)
		return visible[entity] == nil or (base and base(entity))
	end
end

do
	local MAX_SEARCH_MATCHES = 400

	local function entity_matches(entity, text, in_name, in_model)
		if in_name and get_entity_label(entity):lower():find(text, 1, true) then
			return true
		end

		if in_model then
			local visual = entity.visual

			if visual then
				local model_path = visual:GetModelPath()

				if model_path ~= "" and model_path:lower():find(text, 1, true) then
					return true
				end
			end
		end

		return false
	end

	function META:SetSearch(text)
		text = text:lower():match("^%s*(.-)%s*$")

		if text == "" then
			if not self._search_visible then return self end

			self._search_visible = nil
			self._expanded_keys = self._saved_expanded
			self._saved_expanded = nil
			self:update_effective_filter()
			self:Refresh(true)
			local selected = self:GetSelectedEntity()

			if selected and selected:IsValid() then self:ExpandToEntity(selected) end

			return self
		end

		local in_name, in_model = true, true

		if text:starts_with("name:") then
			text, in_model = text:sub(6), false
		elseif text:starts_with("model:") then
			text, in_name = text:sub(7), false
		end

		if not self._search_visible then self._saved_expanded = self._expanded_keys end

		local visible = {}
		local expanded = {nearby = false}
		local matches = 0
		local base = self._filter_callback
		local stack = {}

		for _, root in ipairs(self._root_entities) do
			visible[root] = true
			expanded[root:GetGUID()] = true
			stack[#stack + 1] = root
		end

		while stack[1] and matches < MAX_SEARCH_MATCHES do
			local entity = table.remove(stack)

			for _, child in ipairs(entity:GetChildren()) do
				if
					child.visual_primitive == nil and
					child.VisualOwner == nil and
					not (
						base and
						base(child)
					)
				then
					stack[#stack + 1] = child

					if entity_matches(child, text, in_name, in_model) then
						matches = matches + 1
						visible[child] = true
						local ancestor = child:GetParent()

						while ancestor:IsValid() and not expanded[ancestor:GetGUID()] do
							visible[ancestor] = true
							expanded[ancestor:GetGUID()] = true
							ancestor = ancestor:GetParent()
						end
					end
				end
			end
		end

		self._search_visible = visible
		self._expanded_keys = expanded
		self:update_effective_filter()
		self:Refresh(true)
		return self
	end
end

function META:build_nearby_node()
	local children = {}

	for _, info in ipairs(self._nearby) do
		local entity = info.entity

		if entity:IsValid() then
			children[#children + 1] = {
				Entity = entity,
				Key = "nearby/" .. entity:GetGUID(),
				Text = string.format("%s  (%.1f m)", get_entity_label(entity), info.distance),
				HasChildren = false,
				Children = {},
			}
		end
	end

	return {
		Key = "nearby",
		Text = "nearby",
		HasChildren = #children > 0,
		Children = children,
	}
end

function META:insert_nearby(items)
	if self._search_visible or not self._nearby_root then return end

	for _, item in ipairs(items) do
		if item.Entity == self._nearby_root and self._expanded_keys[item.Key] then
			table.insert(item.Children, 1, self:build_nearby_node())
			item.HasChildren = true
		end
	end
end

function META:SetNearbyRoot(root)
	self._nearby_root = root
	self:Refresh(true)
	return self
end

function META:SetNearby(nearby)
	self._nearby = nearby

	if self._search_visible then return self end

	local item = find_item_in_tree(self:GetItems(), "nearby")

	if not item then return self end

	local node = self:build_nearby_node()
	item.Children = node.Children
	item.HasChildren = node.HasChildren
	self:RefreshBranchForKey("nearby")
	return self
end

return META:Register()
