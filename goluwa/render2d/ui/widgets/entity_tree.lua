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
				value.IsValid and
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

	-- Entity children
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

	-- Check for unexpanded children
	if not expanded then
		for _, child in ipairs(entity:GetChildren()) do
			if filter_callback and filter_callback(child) then goto continue end

			has_children = true

			break

			::continue::
		end
	end

	-- Virtual children (shared object references)
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

-- ---------------------------------------------------------------------------
-- Panel definition
-- ---------------------------------------------------------------------------
META:GetSet("RootEntities", nil)
META:GetSet("RootLabels", nil)
META:GetSet("FilterCallback", nil)
META:GetSet("ShowVirtualChildren", false)
META:GetSet("ExpandRootsOnInit", true)
META:GetSet("OnExpanded", nil)
META:EndStorable()

function META:OnCreate(props)
	self._expanded_keys = props.ExpandedKeys or props._expanded_keys or {}
	self._selected_entity_guid = nil
	self._root_entities = props.RootEntities or {}
	self._root_labels = props.RootLabels or {}
	self._filter_callback = props.FilterCallback
	self._show_virtual = props.ShowVirtualChildren == true
	self._on_expanded = props.OnExpanded
	self._refresh_guard = false
	self._pending_refresh = false
	self._refresh_deadline = 0
	self._refresh_debounce = props.RefreshDebounce or 0.05
	self._hierarchy_dirty = false
	self._mutation_blocked = 0
	self._editor_window = nil

	-- Default roots if none provided
	if #self._root_entities == 0 then
		self._root_entities = {Panel.World}
		-- Add 3D world if available
		local entity_world = import("goluwa/entities/entity.lua").World
		table.insert(self._root_entities, entity_world)
	end

	-- Default labels
	if not self._root_labels[Panel.World] then
		self._root_labels[Panel.World] = "2D World"
	end

	for _, entity in ipairs(self._root_entities) do
		if not self._root_labels[entity] then
			self._root_labels[entity] = get_entity_label(entity)
		end
	end

	-- Expand roots on init
	if self.ExpandRootsOnInit then
		for _, entity in ipairs(self._root_entities) do
			self._expanded_keys[entity:GetGUID()] = true
		end
	end

	-- Build initial items
	local items = build_tree_items(
		self._root_entities,
		self._root_labels,
		self._expanded_keys,
		self._filter_callback,
		self._show_virtual
	)
	props.Items = items
	META.BaseClass.OnCreate(self, props)
	-- Listen for hierarchy changes on each root entity's world
	self._hierarchy_listeners = {}
	self._hierarchy_queue = {}

	local function add_hierarchy_listener(world)
		local tree = self
		local remove = world:AddLocalListener("OnEntityHierarchyChanged", function(_, entity, action, parent)
			if tree._refreshing then return end

			if tree._mutation_blocked > 0 then return end

			table.insert(tree._hierarchy_queue, {entity = entity, action = action, parent = parent})
		end)

		if remove then table.insert(self._hierarchy_listeners, remove) end
	end

	for _, entity in ipairs(self._root_entities) do
		add_hierarchy_listener(entity:GetRoot())
	end

	-- Process queued hierarchy changes at frame end
	local function process_hierarchy_queue()
		local tree = self
		local queue = tree._hierarchy_queue

		if #queue == 0 then return end

		tree._hierarchy_queue = {}

		for _, entry in ipairs(queue) do
			local entity = entry.entity

			if not entity:IsValid() then goto continue end

			local parent = entity:GetParent()

			if self._filter_callback and self._filter_callback(entity) then
				goto continue
			end

			log_hierarchy(entry.action, entity:GetName())

			if entry.action == "parented" then
				local ok, reason = tree:try_incremental_insert(entity, parent)
			--if not ok then tree:FullRefresh(reason) end
			elseif entry.action == "unparented" then
				local ok, reason = tree:try_incremental_remove(entity)
			--if not ok then tree:FullRefresh(reason) end
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

	-- Clean up listeners on removal
	self:CallOnRemove(
		function()
			for _, remove in ipairs(self._hierarchy_listeners) do
				if type(remove) == "function" then remove() end
			end
		end,
		"entity_tree_cleanup"
	)

	-- Add OnUpdate for deferred refresh
	local tree = self
	local system = import("goluwa/system.lua")

	function self:OnUpdate()
		if tree._hierarchy_dirty then
			tree._hierarchy_dirty = false
			log_refresh("hierarchy_dirty")
			tree._pending_refresh = true
			tree._refresh_deadline = system.GetElapsedTime() + tree._refresh_debounce
		end

		if not tree._pending_refresh then return end

		if system.GetElapsedTime() < tree._refresh_deadline then return end

		tree._pending_refresh = false
		log_refresh("deferred_flush")
		tree:Refresh(true)
	end

	self:AddGlobalEvent("Update")
end

function META:set_expanded(node, path, key, expanded)
	self._expanded_keys[key] = expanded

	if expanded and node and node.Entity and node.Entity:IsValid() then
		local entity = node.Entity
		local visited = {}
		local children = {}

		for _, child in ipairs(entity:GetChildren()) do
			if self._filter_callback and self._filter_callback(child) then
				goto continue
			end

			local child_node = build_entity_node(child, self._expanded_keys, self._filter_callback, self._show_virtual, visited)

			if child_node then children[#children + 1] = child_node end

			::continue::
		end

		if self._show_virtual then
			for _, vc in ipairs(build_virtual_children(entity, key)) do
				children[#children + 1] = vc
			end
		end

		-- Update the items tree
		local tree_items = self:GetItems()
		local parent_item = find_item_in_tree(tree_items, key)

		if parent_item then parent_item.Children = children end

		-- Refresh children rows without touching the parent row
		self._pending_expand_animation_key = key
		self:refresh_children(key)

		if self._on_expanded then self._on_expanded(key, expanded) end

		return
	end

	META.BaseClass.set_expanded(self, node, path, key, expanded)

	if self._on_expanded then self._on_expanded(key, expanded) end
end

function META:refresh_children(parent_key)
	-- Find the parent row position
	local parent_index
	for i, row_key in ipairs(self._row_order) do
		if row_key == parent_key then
			parent_index = i
			break
		end
	end

	if not parent_index then return end

	-- Find the end of the branch
	local end_index
	for i = parent_index + 1, #self._row_order do
		local info = self._row_infos[self._row_order[i]]
		if not (info and self:is_key_in_branch(parent_key, info.key)) then
			break
		end
		end_index = i
	end

	-- Remove descendant rows backwards to avoid index shifting
	if end_index then
		for i = end_index, parent_index + 1, -1 do
		local row_key = self._row_order[i]
		local info = self._row_infos[row_key]

		if info and info.clip and info.clip:IsValid() then
			info.clip:Remove()
		end
		self._row_infos[row_key] = nil
		table.remove(self._row_order, i)
		end
	end

	-- Re-add children via the recursive add_node
	local parent_info = self._row_infos[parent_key]
	if not parent_info then return end

	local children = self:get_children(parent_info.node, parent_info.path)
	local level = 0
	for _ in parent_info.path:gmatch("/") do
		level = level + 1
	end

	local insert_index = parent_index + 1
	for child_index, child in ipairs(children) do
		local meta = {
			level = level + 1,
			index = child_index,
			is_last = child_index == #children,
			parent_key = parent_key,
			continuations = {},
		}
		insert_index = self:add_node(child, meta, parent_info.path, insert_index) or insert_index
	end

	self:refresh_visibility()
end

-- Tree callbacks
function META.OnGetText(node, path)
	return node.Text or "item"
end

function META:is_expanded(node, path, key, has_children)
	if not has_children then return false end

	return self._expanded_keys[key] == true
end

function META:set_selected(node, path, key)
	if node and node.Entity and node.Entity:IsValid() then
		self._selected_entity_guid = node.Entity:GetGUID()
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

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------
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

function META:BlockMutations()
	self._mutation_blocked = self._mutation_blocked + 1
	return self
end

function META:UnblockMutations()
	self._mutation_blocked = math.max(0, self._mutation_blocked - 1)
	return self
end

function META:ExpandToEntity(entity)
	if not entity or not entity:IsValid() then return self end

	local guid = entity:GetGUID()

	-- Check if already visible
	if self._row_infos[guid] then
		self:SetSelectedKey(guid)
		return self
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
	if self._refreshing then return self end

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
		self._filter_callback,
		self._show_virtual
	)
	self:SetItems(items)
	self._refreshing = false
	return self
end

function META:RefreshBranch(entity)
	return self:RefreshBranchForKey(entity:GetGUID())
end

function META:refresh_visibility()
	self._mutation_blocked = self._mutation_blocked + 1
	local result = META.BaseClass.refresh_visibility(self)
	self._mutation_blocked = math.max(0, self._mutation_blocked - 1)
	return result
end

function META:GetExpandedKeys()
	return self._expanded_keys
end

function META:FullRefresh(reason)
	if META.debug and reason then print("[entity_tree] FullRefresh: ", reason) end

	self._hierarchy_dirty = true
end

function META:try_incremental_insert(entity, parent)
	-- Skip filtered entities
	if self._filter_callback and self._filter_callback(entity) then
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
		-- Entity reparented to world root - find the matching root
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

	local new_item = build_entity_node(entity, self._expanded_keys, self._filter_callback, self._show_virtual, {})

	if not new_item then return false, "build_entity_node_failed" end

	parent_item.Children[#parent_item.Children + 1] = new_item
	self:AddNode(new_item, parent_key)
	return true
end

function META:try_incremental_remove(entity)
	local guid = entity:GetGUID()
	local item = find_item_in_tree(self:GetItems(), guid)

	if not item then return false, "item_not_found_in_tree" end

	-- Remove from items tree
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
	-- Remove row from UI
	local row_key = self._row_infos[guid] and guid or nil

	if row_key then
		local info = self._row_infos[row_key]

		if info and info.clip and info.clip:IsValid() then info.clip:Remove() end

		self._row_infos[row_key] = nil

		for i, k in ipairs(self._row_order) do
			if k == row_key then
				table.remove(self._row_order, i)

				break
			end
		end
	end

	-- Also remove children rows
	local function collect_keys(nodes, keys)
		for _, n in ipairs(nodes or {}) do
			keys[n.Key] = true
			collect_keys(n.Children, keys)
		end
	end

	local child_keys = {}
	collect_keys(item.Children, child_keys)

	for i = #self._row_order, 1, -1 do
		local k = self._row_order[i]

		if child_keys[k] then
			local info = self._row_infos[k]

			if info and info.clip and info.clip:IsValid() then info.clip:Remove() end

			self._row_infos[k] = nil
			table.remove(self._row_order, i)
		end
	end

	self:refresh_visibility()
	return true
end

META:Register()
return META
