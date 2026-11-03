local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
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

local function action(key, text, on_action)
	return {Key = key, Text = "", Type = "action", ButtonText = text, OnAction = on_action}
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
		item.Type = "number"
		item.Precision = field and field.Precision or 3
		item.ShowStepper = true

		if field and field.Min then
			item.Min, item.Max = field.Min, field.Max
			item.ShowSlider = field.Max ~= nil
		end
	elseif kind == "string" then
		item.Type = "string"
	elseif kind == "boolean" then
		item.Type = "boolean"
	elseif data_files.IsColorKey(key) and kind == "table" and is_numbers(value, 3, 4) then
		item.Type = "color"
		item.Value = Color(value[1], value[2], value[3], value[4] or 1)
	elseif kind == "table" and is_numbers(value, 2, 3) then
		item.Type = #value == 2 and "vec2" or "vec3"
		item.Precision = 3
		item.Value = (#value == 2 and Vec2 or Vec3)(unpack(value))
	else
		return nil
	end

	if item.Value == nil then item.Value = value end

	if field and field.Sound and options.PlaySound then
		item.PlayAction = function()
			options.PlaySound(data[key])
		end
	end

	item.OnChange = function(_, new)
		if item.Type == "color" then
			data[key] = {new.r, new.g, new.b, new.a}
		elseif item.Type == "vec2" then
			data[key] = {new.x, new.y}
		elseif item.Type == "vec3" then
			data[key] = {new.x, new.y, new.z}
		else
			data[key] = new
		end

		options.Changed()
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

local function add_structure_actions(children, value, path, field, options)
	local restructured = options.Restructured

	if field and field.Keys then
		for _, name in ipairs(sorted_keys(field.Keys)) do
			if value[name] == nil then
				children[#children + 1] = action(path .. "/add_" .. name, "add " .. name, function()
					value[name] = copy_template(field.Keys[name])
					restructured()
				end)
			elseif type(value[name]) ~= "table" or not is_numbers(value[name], 3, 4) then
				children[#children + 1] = action(path .. "/remove_" .. name, "remove " .. name, function()
					value[name] = nil
					restructured()
				end)
			end
		end
	end

	if field and field.NewKey then
		children[#children + 1] = action(path .. "/new", "add " .. field.NewKey.Name, function()
			local n = 1

			while value[field.NewKey.Name .. "_" .. n] ~= nil do
				n = n + 1
			end

			value[field.NewKey.Name .. "_" .. n] = copy_template(field.NewKey.Template)
			restructured()
		end)
	end
end

function build(data, options, path, list_key)
	local items = {}
	local schema = options.Schema

	for _, key in ipairs(sorted_keys(data)) do
		local value = data[key]

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
					Children = build(value, options, item_path, type(key) == "number" and list_key or key),
				}
				add_structure_actions(item.Children, value, item_path, field, options)
			end
		end

		items[#items + 1] = item

		if
			item.Type and
			field and
			field.Ref and
			options.Open and
			options.CanOpen(field.Ref) and
			type(value) == "string"
		then
			item.RowButtons = {
				{
					Icon = "arrow_right",
					Tooltip = "Open " .. value,
					OnClick = function()
						options.Open(field.Ref, value)
					end,
				},
			}
		end

		::continue::
	end

	return items
end

function data_items.BuildTable(data, options, path, list_key)
	return build(data, options, path, list_key)
end

function data_items.Build(data, options)
	local items = build(data, options, "", "")
	local top = {}
	local general = {Key = "/general", Text = "general", Expanded = true, Children = {}}

	for _, item in ipairs(items) do
		if item.IsGroup then
			item.IsGroup = nil
			top[#top + 1] = item
		else
			general.Children[#general.Children + 1] = item
		end
	end

	local structure = {Key = "/structure", Text = "add / remove keys", Expanded = false, Children = {}}
	add_structure_actions(structure.Children, data, "", options.Schema and options.Schema.Root, options)

	if #general.Children > 0 then table.insert(top, 1, general) end

	if #structure.Children > 0 then top[#top + 1] = structure end

	return top
end

return data_items
