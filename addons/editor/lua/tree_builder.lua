local Panel = import("goluwa/render2d/ui/panel.lua")
local Entity = import("goluwa/entities/entity.lua")
local Material = import("goluwa/render3d/material.lua")
local objects = import("goluwa/objects/objects.lua")
local MATERIAL_ROOT_KEY = "__editor_3d_materials__"
local SHARED_INSTANCE_COLOR = import("goluwa/structs/color.lua")(0.35, 0.62, 1.0, 1.0)

local function is_valid_object(obj)
	local obj_type = type(obj)

	if obj_type ~= "table" and obj_type ~= "userdata" and obj_type ~= "cdata" then
		return false
	end

	return obj and obj.IsValid and obj:IsValid() or false
end

local function is_guid_object(obj)
	return is_valid_object(obj) and
		obj.GetGUID ~= nil and
		obj.GetGUID ~= false and
		type(obj.GetGUID) == "function"
end

local function get_entity_label(entity)
	local name = entity.GetName and entity:GetName() or ""
	local key = entity.GetKey and entity:GetKey() or ""
	local base = name ~= "" and name or key ~= "" and key or (entity.Type or "entity")

	if name ~= "" and key ~= "" and key ~= name then
		base = name .. " [" .. key .. "]"
	end

	return base
end

local function get_object_label(obj)
	if not is_valid_object(obj) then return "object" end

	local name = obj.GetName and obj:GetName() or ""
	local key = obj.GetKey and obj:GetKey() or ""
	local base = name ~= "" and name or key ~= "" and key or (obj.Type or "object")

	if name ~= "" and key ~= "" and key ~= name then
		base = name .. " [" .. key .. "]"
	end

	return base
end

local function is_world_root(entity)
	return entity == Entity.World or entity == Panel.World
end

local function get_entity_world_root(entity)
	local current = entity

	while current and current.IsValid and current:IsValid() do
		if is_world_root(current) then return current end

		current = current:GetParent()
	end

	return nil
end

local transient_ui_keys = {
	ActiveContextMenu = true,
	ActiveMenuBarContextMenu = true,
	EditorMenuBarContextMenu = true,
	EditorTreeContextMenu = true,
	UITooltipOverlay = true,
}

local function is_transient_ui_entity(entity)
	local current = entity

	while current and current.IsValid and current:IsValid() do
		if current.IsContextMenuContainer then return true end

		local key = current.GetKey and current:GetKey() or ""

		if transient_ui_keys[key] then return true end

		current = current:GetParent()
	end

	return false
end

local function has_parent(panel, parent)
	local current = panel

	while current and current.IsValid and current:IsValid() do
		if current == parent then return true end

		current = current:GetParent()
	end

	return false
end

local function is_hidden_editor_entity(entity, editor_window)
	if not (entity and entity.IsValid and entity:IsValid()) then return false end

	if editor_window and has_parent(entity, editor_window) then return true end

	return is_transient_ui_entity(entity)
end

local function get_valid_children(entity, editor_window)
	local out = {}

	for _, child in ipairs(entity:GetChildren()) do
		if
			child and
			child:IsValid() and
			child ~= entity and
			child:GetParent() == entity and
			not is_hidden_editor_entity(child, editor_window)
		then
			out[#out + 1] = child
		end
	end

	return out
end

local function can_preserve_hidden_selection(selected_target, editor_window)
	if not is_valid_object(selected_target) then return false end

	if selected_target.component_list then
		return not is_hidden_editor_entity(selected_target, editor_window)
	end

	return true
end

local function should_ignore_editor_tree_change(entity, related_entity, editor_window)
	return is_hidden_editor_entity(entity, editor_window) or
		is_hidden_editor_entity(related_entity, editor_window)
end

local function get_component_name(entity, component)
	for name, value in pairs(entity.component_map or {}) do
		if value == component then return name end
	end

	return component.Type or "component"
end

local function build_shared_object_node(object, key, text)
	return {
		Object = object,
		Key = key,
		Text = text or get_object_label(object),
		HasChildren = false,
		Children = {},
		SharedInstance = true,
		TextColor = SHARED_INSTANCE_COLOR,
	}
end

local function build_virtual_property_children(entity)
	local children = {}

	for _, component in ipairs(entity.component_list or {}) do
		if component and component.IsValid and component:IsValid() then
			local component_name = get_component_name(entity, component)

			for _, info in ipairs(objects.GetStorableVariables(component)) do
				local value = objects.GetProperty(component, info.var_name)

				if is_guid_object(value) and not value.component_list then
					children[#children + 1] = build_shared_object_node(
						value,
						entity:GetGUID() .. "/" .. component_name .. "/" .. info.var_name .. "/" .. value:GetGUID(),
						info.var_name
					)
				end
			end
		end
	end

	return children
end

local function count_material_objects()
	local count = 0

	for _, material in ipairs(Material.Instances or {}) do
		if is_valid_object(material) then count = count + 1 end
	end

	return count
end

local function build_material_root_key(material)
	return MATERIAL_ROOT_KEY .. "/" .. material:GetGUID()
end

local function build_material_tree_item(expanded_entities)
	local children = {}
	local expanded = expanded_entities[MATERIAL_ROOT_KEY] == true

	if expanded then
		for _, material in ipairs(Material.Instances or {}) do
			if is_valid_object(material) then
				children[#children + 1] = build_shared_object_node(material, build_material_root_key(material))
			end
		end
	end

	return {
		Key = MATERIAL_ROOT_KEY,
		Text = "3D Materials",
		HasChildren = count_material_objects() > 0,
		Expanded = expanded,
		Children = children,
	}
end

local function build_tree_snapshot(entity, expanded_entities, visited, editor_window)
	if not entity or not entity:IsValid() then return nil end

	local guid = entity:GetGUID()

	if visited[entity] then return nil end

	visited[entity] = true
	local expanded = expanded_entities[guid] == true
	local children = {}
	local valid_children = get_valid_children(entity, editor_window)
	local has_children = valid_children[1] ~= nil

	if expanded then
		for _, child in ipairs(valid_children) do
			local child_node = build_tree_snapshot(child, expanded_entities, visited, editor_window)

			if child_node then children[#children + 1] = child_node end
		end
	end

	local virtual_children = build_virtual_property_children(entity)
	has_children = has_children or virtual_children[1] ~= nil

	if expanded then
		for _, child_node in ipairs(virtual_children) do
			children[#children + 1] = child_node
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

local function build_world_tree_item(world_entity, label, expanded_entities, visited, editor_window)
	if not (world_entity and world_entity.IsValid and world_entity:IsValid()) then
		return nil
	end

	local children = {}
	local expanded = expanded_entities[world_entity:GetGUID()] == true
	local valid_children = get_valid_children(world_entity, editor_window)

	if expanded then
		for _, child in ipairs(valid_children) do
			local child_node = build_tree_snapshot(child, expanded_entities, visited, editor_window)

			if child_node then children[#children + 1] = child_node end
		end
	end

	return {
		Entity = world_entity,
		Key = world_entity:GetGUID(),
		Text = label,
		HasChildren = valid_children[1] ~= nil,
		Children = children,
	}
end

local function build_tree_items(expanded_entities, editor_window, world_info_list)
	local items = {}
	local visited = {}
	world_info_list = world_info_list or
		{
			{entity = Entity.World, label = "3D World"},
			{virtual = true},
			{entity = Panel.World, label = "2D World"},
		}

	for _, world_info in ipairs(world_info_list) do
		local node = world_info.virtual and
			build_material_tree_item(expanded_entities) or
			build_world_tree_item(world_info.entity, world_info.label, expanded_entities, visited, editor_window)

		if node then items[#items + 1] = node end
	end

	return items
end

local function find_tree_item(items, key)
	for _, item in ipairs(items or {}) do
		if item.Key == key then return item end

		local found = find_tree_item(item.Children, key)

		if found then return found end
	end

	return nil
end

local function replace_tree_item(items, key, replacement)
	for index, item in ipairs(items or {}) do
		if item.Key == key then
			items[index] = replacement
			return true
		end

		if replace_tree_item(item.Children, key, replacement) then return true end
	end

	return false
end

local function insert_tree_item(items, parent_key, new_item)
	if parent_key == nil then
		table.insert(items, new_item)
		return true
	end

	for _, item in ipairs(items or {}) do
		if item.Key == parent_key then
			table.insert(item.Children, new_item)
			return true
		end

		if insert_tree_item(item.Children, parent_key, new_item) then return true end
	end

	return false
end

local function remove_tree_item(items, key)
	for index, item in ipairs(items or {}) do
		if item.Key == key then
			table.remove(items, index)
			return true
		end

		if remove_tree_item(item.Children, key) then return true end
	end

	return false
end

return {
	build_tree_items = build_tree_items,
	build_tree_snapshot = build_tree_snapshot,
	build_world_tree_item = build_world_tree_item,
	build_material_tree_item = build_material_tree_item,
	find_tree_item = find_tree_item,
	replace_tree_item = replace_tree_item,
	insert_tree_item = insert_tree_item,
	remove_tree_item = remove_tree_item,
	build_shared_object_node = build_shared_object_node,
	build_virtual_property_children = build_virtual_property_children,
	build_material_root_key = build_material_root_key,
	count_material_objects = count_material_objects,
	get_component_name = get_component_name,
	get_entity_label = get_entity_label,
	get_object_label = get_object_label,
	is_valid_object = is_valid_object,
	is_world_root = is_world_root,
	is_hidden_editor_entity = is_hidden_editor_entity,
	get_valid_children = get_valid_children,
	can_preserve_hidden_selection = can_preserve_hidden_selection,
	should_ignore_editor_tree_change = should_ignore_editor_tree_change,
	get_entity_world_root = get_entity_world_root,
	MATERIAL_ROOT_KEY = MATERIAL_ROOT_KEY,
	SHARED_INSTANCE_COLOR = SHARED_INSTANCE_COLOR,
}
