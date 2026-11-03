local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Vec4 = import("goluwa/structs/vec4.lua")
local Color = import("goluwa/structs/color.lua")
local data_files = import("goluwa/data_files.lua")
local data_schema = import("lua/data_schema.lua")
local data_items = {}
local ids = setmetatable({}, {__mode = "k"})
local next_id = 0

local function get_id(value)
	local id = ids[value]

	if not id then
		next_id = next_id + 1
		id = next_id
		ids[value] = id
	end

	return id
end

local function sorted_keys(value)
	local keys = {}

	for key in pairs(value) do
		keys[#keys + 1] = key
	end

	table.sort(keys, function(a, b)
		if type(a) ~= type(b) then return type(a) == "number" end

		return a < b
	end)

	return keys
end

local function is_numbers(value, min, max)
	if #value < min or #value > max then return false end

	for i = 1, #value do
		if type(value[i]) ~= "number" then return false end
	end

	return next(value, #value) == nil
end

local function is_array(value, field)
	if next(value) == nil then return field ~= nil and field.Template ~= nil end

	return #value > 0 and next(value, #value) == nil
end

local function copy_template(template, sibling)
	if type(template) == "function" then return template(sibling) end

	return table.copy(template)
end

local function default_item(list, field, sibling)
	if field and field.Template then
		return copy_template(field.Template, sibling)
	end

	local like = sibling or list[#list]

	if type(like) == "table" then return table.copy(like) end

	if type(like) == "number" then return 0 end

	if type(like) == "boolean" then return false end

	return ""
end

local build

local function make_leaf(data, key, value, item_path, field, options)
	local item = {Key = item_path, Text = field and field.Text or tostring(key)}
	local kind = type(value)
	local schema = options.Schema

	if field and field.Description then item.Description = field.Description end

	local choices = field and (field.Options or field.Ref and schema.Refs[field.Ref])

	if choices and kind == "string" then
		local list = type(choices) == "function" and choices() or choices
		item.Type = "enum"
		item.Options = {}
		local found

		for _, name in ipairs(list) do
			item.Options[#item.Options + 1] = {Text = name, Value = name}
			found = found or name == value
		end

		if not found then
			table.insert(item.Options, 1, {Text = value .. " (missing)", Value = value})
		end
	elseif kind == "number" then
		item.Type = field and field.Integer and "integer" or "number"
		item.Precision = field and field.Integer and 0 or field and field.Precision or 3

		if field and field.Min then
			item.Min, item.Max = field.Min, field.Max
			item.ShowSlider = field.Max ~= nil
		end
	elseif kind == "string" then
		item.Type = field and field.Sound and "sound" or field and field.Code and "code" or "string"

		if item.Type == "code" then
			item.CodeLanguage = field.Code
			item.GetStatus = field.GetStatus and
				function()
					return field.GetStatus(data, options)
				end
		end
	elseif kind == "boolean" then
		item.Type = "boolean"
	elseif data_files.IsColorKey(key) and kind == "table" and is_numbers(value, 3, 4) then
		item.Type = "color"
		item.Value = Color(value[1], value[2], value[3], value[4] or 1)
	elseif kind == "table" and is_numbers(value, 2, 4) then
		item.Type = ("vec%d"):format(#value)
		item.Precision = 3
		item.Value = (#value == 2 and Vec2 or #value == 3 and Vec3 or Vec4)(unpack(value))
	else
		return nil
	end

	if item.Value == nil then item.Value = value end

	if item.Type == "sound" and options.PlaySound then
		item.PlayAction = options.PlaySound
	end

	item.OnChange = function(_, new)
		if item.Type == "color" then
			data[key] = {new.r, new.g, new.b, new.a}
		elseif item.Type == "vec2" then
			data[key] = {new.x, new.y}
		elseif item.Type == "vec3" then
			data[key] = {new.x, new.y, new.z}
		elseif item.Type == "vec4" then
			data[key] = {new.x, new.y, new.z, new.w}
		else
			data[key] = new
		end

		if field and field.OnSet then field.OnSet(data, new) end

		if field and field.Restructure then
			options.Restructured(true)
		else
			options.Changed()
		end
	end
	return item
end

local function to_lua(list)
	return (table.to_source(list):gsub("^return ", ""):gsub("%s*\n$", ""))
end

local function make_list(data, key, list, item_path, field, list_key, options)
	local restructured = options.Restructured
	local node = {
		Key = item_path,
		Text = field and field.Text or tostring(key),
		Type = "list",
		Display = field and field.Display or "rows",
		Columns = field and field.Columns,
		Description = field and field.Description,
		Items = {},
	}
	local element_field = data_schema.GetField(options.Schema, key, 1)
	local all_scalar = true

	for i = 1, #list do
		if type(list[i]) == "table" and not is_numbers(list[i], 2, 3) then
			all_scalar = false
		end
	end

	local focus = options.Focus

	if focus and focus.Path == item_path then node.FocusIndex = focus.Index end

	if node.Display == "table" then
		for i, element in ipairs(list) do
			local cells = {}

			for column_index, column in ipairs(node.Columns) do
				local cell_field = table.shallow_copy(column)
				cell_field.Text = column.Text
				cells[column_index] = make_leaf(
					element,
					column.Key,
					element[column.Key],
					item_path .. "/" .. i .. "/" .. column_index,
					cell_field,
					options
				)
			end

			node.Items[i] = {Key = item_path .. "/" .. i, Cells = cells}
		end
	elseif all_scalar then
		for i = 1, #list do
			node.Items[i] = make_leaf(list, i, list[i], item_path .. "/" .. i, element_field, options)
		end
	else
		local label = options.Schema and options.Schema.Labels and options.Schema.Labels[key]

		for i, element in ipairs(list) do
			node.Items[i] = {
				Key = item_path .. "/#" .. get_id(element),
				Text = label and label(element) or "item",
				Collapsed = true,
				Children = build(element, options, item_path .. "/#" .. get_id(element), key),
			}
		end
	end

	local function insert(index)
		table.insert(list, index, default_item(list, field, list[index] or list[#list]))
		restructured(false, {Path = item_path, Index = index})
	end

	node.Actions = {
		Add = function()
			insert(#list + 1)
		end,
		Insert = insert,
		Duplicate = function(index)
			table.insert(list, index + 1, table.copy(list[index]))
			restructured(false, {Path = item_path, Index = index + 1})
		end,
		Remove = function(index)
			table.remove(list, index)
			restructured()
		end,
		Move = function(from, to)
			table.insert(list, to, table.remove(list, from))
			restructured()
		end,
		Clear = function()
			for i = #list, 1, -1 do
				list[i] = nil
			end

			restructured()
		end,
		Copy = function()
			return to_lua(list)
		end,
	}

	if #list > 0 and type(list[1]) == "string" then
		node.Actions.Sort = function()
			table.sort(list)
			restructured()
		end
		node.Actions.Paste = function(text)
			for line in text:gmatch("[^\r\n]+") do
				list[#list + 1] = line
			end

			restructured()
		end
	end

	return node
end

local function optional_keys(field)
	if not field then return end

	return field.NewKey and true or field.Keys
end

local function make_add_node(value, path, field, options, keys)
	local items = {}

	if keys then
		for _, name in ipairs(sorted_keys(keys)) do
			if value[name] == nil then
				items[#items + 1] = {
					Text = name,
					OnClick = function()
						value[name] = copy_template(keys[name])
						options.Restructured()
					end,
				}
			end
		end
	end

	if field and field.NewKey then
		items[#items + 1] = {
			Text = "new " .. field.NewKey.Name,
			OnClick = function()
				local n = 1

				while value[field.NewKey.Name .. "_" .. n] ~= nil do
					n = n + 1
				end

				value[field.NewKey.Name .. "_" .. n] = copy_template(field.NewKey.Template)
				options.Restructured()
			end,
		}
	end

	if #items == 0 then return end

	return {Key = path .. "/add", Type = "add", Items = items}
end

function build(data, options, path, list_key, optional)
	local items = {}
	local schema = options.Schema
	local defaults = path == "" and schema and schema.Root and schema.Root.Defaults or nil
	local keys = sorted_keys(data)

	if defaults then
		for key in pairs(defaults) do
			if data[key] == nil then keys[#keys + 1] = key end
		end

		table.sort(keys)
	end

	for _, key in ipairs(keys) do
		local value = data[key]
		local default = defaults and defaults[key]
		local is_default = value == nil

		if is_default then
			value = type(default) == "table" and table.copy(default) or default
		end

		if type(value) == "function" then goto continue end

		local field = data_schema.GetField(schema, list_key, key)

		if field and field.Hidden then goto continue end

		local item_path = path .. "/" .. tostring(key)
		local item = make_leaf(data, key, value, item_path, field, options)

		if not item then
			if is_array(value, field) then
				item = make_list(data, key, value, item_path, field, list_key, options)
			else
				item = {
					Key = item_path,
					Text = field and field.Text or tostring(key),
					IsGroup = true,
					Description = field and field.Description,
					Children = build(
						value,
						options,
						item_path,
						type(key) == "number" and list_key or key,
						optional_keys(field)
					),
				}
				local add = make_add_node(value, item_path, field, options, field and field.Keys)

				if add then item.Children[#item.Children + 1] = add end
			end
		end

		items[#items + 1] = item

		if optional and not is_default and (optional == true or optional[key] ~= nil) then
			item.ContextActions = item.ContextActions or {}
			table.insert(
				item.ContextActions,
				{
					Text = "Remove",
					OnClick = function()
						data[key] = nil
						options.Restructured()
					end,
				}
			)
		end

		local buttons = {}

		if item.Type and default ~= nil then
			if is_default then
				item.Default = item.Value
			elseif field and field.Range and item.Type == "vec2" then
				item.ContextActions = {
					{
						Text = "Reset to the default",
						OnClick = function()
							data[key] = nil
							options.Restructured()
						end,
					},
				}
			else
				item.Default = make_leaf(
						{},
						key,
						type(default) == "table" and table.copy(default) or default,
						item_path,
						field,
						options
					).Value
			end
		end

		if item.Type and field and field.Range then
			if type(value) == "number" then
				buttons[#buttons + 1] = {
					Icon = "wand",
					Tooltip = "randomize between a min and a max",
					OnClick = function()
						data[key] = {value, value}
						options.Restructured()
					end,
				}
			elseif item.Type == "vec2" then
				item.Text = item.Text .. " (min, max)"
				buttons[#buttons + 1] = {
					Icon = "close",
					Tooltip = "use one value",
					OnClick = function()
						data[key] = (value[1] + value[2]) / 2
						options.Restructured()
					end,
				}
			end
		end

		if
			item.Type and
			field and
			field.Ref and
			options.Open and
			options.CanOpen(field.Ref) and
			type(value) == "string"
		then
			buttons[#buttons + 1] = {
				Icon = "arrow_right",
				Tooltip = "Open " .. value,
				OnClick = function()
					options.Open(field.Ref, value)
				end,
			}
		end

		if #buttons > 0 then item.RowButtons = buttons end

		::continue::
	end

	return items
end

function data_items.BuildTable(data, options, path, list_key)
	return build(data, options, path, list_key)
end

function data_items.StripDefaults(data, schema)
	local defaults = schema.Root and schema.Root.Defaults

	if not defaults then return end

	for key, default in pairs(defaults) do
		local value = data[key]

		if
			value ~= nil and
			(
				value == default or
				type(value) == "table" and
				type(default) == "table" and
				table.equal(value, default)
			)
		then
			data[key] = nil
		end
	end
end

function data_items.Build(data, options)
	local root = options.Schema and options.Schema.Root
	local items = build(data, options, "", "", root and root.Keys)
	local top = {}
	local general = {Key = "/general", Text = "general", Expanded = true, Children = {}}
	local groups = options.Schema and options.Schema.Root and options.Schema.Root.Groups
	local placed = {}

	if groups then
		local by_key = {}

		for _, item in ipairs(items) do
			by_key[item.Key] = item
		end

		for _, group in ipairs(groups) do
			local node = {
				Key = "/group/" .. group.Name,
				Text = group.Name,
				Expanded = true,
				Children = {},
			}

			for _, key in ipairs(group.Keys) do
				local item = by_key["/" .. key]

				if item then
					node.Children[#node.Children + 1] = item
					placed[item] = true
				end
			end

			if #node.Children > 0 then top[#top + 1] = node end
		end
	end

	for _, item in ipairs(items) do
		if placed[item] then goto continue end

		if item.IsGroup then
			item.IsGroup = nil
			top[#top + 1] = item
		else
			general.Children[#general.Children + 1] = item
		end

		::continue::
	end

	local add = make_add_node(data, "", root, options, root and root.Keys)

	if #general.Children > 0 then table.insert(top, 1, general) end

	if add then
		if groups or #general.Children == 0 then
			top[#top + 1] = {Key = "/optional", Text = "optional", Expanded = true, Children = {add}}
		else
			general.Children[#general.Children + 1] = add
		end
	end

	return top
end

return data_items
