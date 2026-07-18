local objects = import("goluwa/objects/objects.lua")

local function is_valid_object(obj)
	local obj_type = type(obj)

	if obj_type ~= "table" and obj_type ~= "userdata" and obj_type ~= "cdata" then
		return false
	end

	return obj and obj.IsValid and obj:IsValid() or false
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

local function get_component_name(entity, component)
	for name, value in pairs(entity.component_map or {}) do
		if value == component then return name end
	end

	return component.Type or "component"
end

local function get_material_display_text(material)
	if not material then return "None" end

	if material.vmt_path and material.vmt_path ~= "" then
		return material.vmt_path
	end

	return get_object_label(material)
end

local function get_material_preview_texture(material)
	if not material then return nil end

	local texture = material.GetAlbedoTexture and material:GetAlbedoTexture() or nil

	if texture and texture.IsReady and not texture:IsReady() then return nil end

	return texture
end

local function get_texture_display_text(texture)
	if not texture then return "None" end

	local path = texture.config and texture.config.path or nil

	if path and path ~= "" then return path end

	return get_object_label(texture)
end

local function get_texture_preview_texture(texture)
	if not texture then return nil end

	if texture.IsReady and not texture:IsReady() then return nil end

	return texture
end

local function build_property_node(target, category_key, category_name, info, hooks)
	local value = objects.GetProperty(target, info.var_name)
	local node = {
		Key = category_key .. "/" .. info.var_name,
		Text = info.var_name,
		Value = value,
		Default = info.copy and info.copy() or info.default,
		GetValue = function()
			return objects.GetProperty(target, info.var_name)
		end,
	}
	local property_type = info.enums and "enum" or info.type

	if property_type == "material" or property_type == "render3d_material" then
		node.Type = "material"
		node.GetDisplayText = get_material_display_text
		node.GetPreviewTexture = get_material_preview_texture
		node.OnBrowse = function(_, key, path, panel, commit_value)
			if open_material_picker then
				open_material_picker(node, target, info, key, path, panel, commit_value)
			end
		end
	elseif property_type == "texture" or property_type == "render_texture" then
		node.Type = "texture"
		node.GetDisplayText = get_texture_display_text
		node.GetPreviewTexture = get_texture_preview_texture
		node.OnBrowse = function(_, key, path, panel, commit_value)
			if open_texture_picker then
				open_texture_picker(node, target, info, key, path, panel, commit_value)
			end
		end
	elseif property_type == "boolean" then
		node.Type = "boolean"
	elseif property_type == "number" or property_type == "integer" then
		node.Type = "number"
		node.Precision = property_type == "integer" and 0 or 3
	elseif property_type == "string" then
		node.Type = "string"
	elseif property_type == "vec2" or property_type == "Vec2" then
		node.Type = "vec2"
	elseif property_type == "vec3" or property_type == "Vec3" then
		node.Type = "vec3"
	elseif property_type == "rect" or property_type == "Rect" then
		node.Type = "rect"
	elseif property_type == "quat" or property_type == "Quat" then
		node.Type = "quat"
	elseif property_type == "color" or property_type == "Color" then
		node.Type = "color"
	elseif property_type == "ang3" or property_type == "Ang3" then
		node.Type = "ang3"
	elseif property_type == "enum" then
		node.Type = "enum"
		node.Options = {}

		for _, option in ipairs(info.enums or {}) do
			node.Options[#node.Options + 1] = {
				Text = tostring(option),
				Value = option,
			}
		end
	else
		node.Type = "string"
		node.Value = tostring(value)
		node.Description = "String preview for unsupported value type " .. tostring(info.type)
		node.OnChange = function()
			return
		end
		return node
	end

	node.OnChange = function(_, next_value)
		if property_type == "integer" then
			next_value = math.floor((tonumber(next_value) or 0) + 0.5)
		end

		if hooks and hooks.OnPropertyChangeStart then
			hooks.OnPropertyChangeStart(target, info, next_value)
		end

		local ok, err = pcall(function()
			objects.SetProperty(target, info.var_name, next_value)
		end)

		if hooks and hooks.OnPropertyChangeEnd then
			hooks.OnPropertyChangeEnd(target, info, next_value, ok, err)
		end

		if not ok then
			print(
				"editor failed to set property",
				target,
				category_name,
				info.var_name,
				err
			)
		end

		return ok
	end
	return node
end

local function build_storable_property_group(target, group_key, group_text, hooks)
	local children = {}

	for _, info in ipairs(objects.GetStorableVariables(target)) do
		children[#children + 1] = build_property_node(target, group_key, group_text, info, hooks)
	end

	return {
		Key = group_key,
		Text = group_text,
		Expanded = true,
		Children = children,
	}
end

local function build_property_items(target, hooks)
	if not is_valid_object(target) then return {} end

	local items = {}

	if target.component_list then
		for _, component in ipairs(target.component_list or {}) do
			local component_name = get_component_name(target, component)
			items[#items + 1] = build_storable_property_group(
				component,
				target:GetGUID() .. "/" .. component_name,
				component_name,
				hooks
			)
		end

		return items
	end

	items[#items + 1] = build_storable_property_group(target, target:GetGUID() .. "/properties", get_object_label(target), hooks)
	return items
end

return {
	build_property_node = build_property_node,
	build_storable_property_group = build_storable_property_group,
	build_property_items = build_property_items,
	get_component_name = get_component_name,
	get_object_label = get_object_label,
	get_material_display_text = get_material_display_text,
	get_material_preview_texture = get_material_preview_texture,
	get_texture_display_text = get_texture_display_text,
	get_texture_preview_texture = get_texture_preview_texture,
	is_valid_object = is_valid_object,
}
