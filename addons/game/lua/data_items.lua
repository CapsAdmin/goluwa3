local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local data_files = import("goluwa/data_files.lua")
local data_schema = import("lua/data_schema.lua")
local data_items = {}

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

local function is_list_of_tables(value)
	if #value == 0 or next(value, #value) ~= nil then return false end

	for i = 1, #value do
		if type(value[i]) ~= "table" then return false end
	end

	return true
end

local function action(key, text, on_action)
	return {Key = key, Text = "", Type = "action", ButtonText = text, OnAction = on_action}
end

local function copy_template(template, sibling)
	if type(template) == "function" then return template(sibling) end

	return table.copy(template)
end

local build

local function add_structure_actions(children, parent, key, value, path, field, options)
	local restructured = options.Restructured

	if is_list_of_tables(value) then
		local groups = {}

		for _, child in ipairs(children) do
			if child.Children and child.DataIndex then groups[child.DataIndex] = child end
		end

		for i = 1, #value do
			local group = groups[i]

			if not group then goto next_element end

			local actions = group.Children
			actions[#actions + 1] = action(group.Key .. "/duplicate", "duplicate", function()
				table.insert(value, i + 1, table.copy(value[i]))
				restructured()
			end)

			if i > 1 then
				actions[#actions + 1] = action(group.Key .. "/up", "move up", function()
					value[i], value[i - 1] = value[i - 1], value[i]
					restructured()
				end)
			end

			if i < #value then
				actions[#actions + 1] = action(group.Key .. "/down", "move down", function()
					value[i], value[i + 1] = value[i + 1], value[i]
					restructured()
				end)
			end

			actions[#actions + 1] = action(group.Key .. "/remove", "remove", function()
				table.remove(value, i)
				restructured()
			end)

			::next_element::
		end
	end

	if field and field.Template then
		children[#children + 1] = action(path .. "/add", "add item", function()
			value[#value + 1] = copy_template(field.Template, value[#value])
			restructured()
		end)
	elseif #value > 0 and type(value[1]) ~= "table" and next(value, #value) == nil then
		children[#children + 1] = action(path .. "/add", "add item", function()
			value[#value + 1] = value[#value]
			restructured()
		end)
		children[#children + 1] = action(path .. "/remove_last", "remove last", function()
			value[#value] = nil
			restructured()
		end)
	end

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
		local item_path = path .. "/" .. tostring(key)
		local item = {Key = item_path, Text = field and field.Text or tostring(key)}
		local kind = type(value)
		local child_key = type(key) == "number" and list_key or key

		if field and field.Description then item.Description = field.Description end

		if field and field.Hidden then goto continue end

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
		elseif data_files.IsColorKey(key) and is_numbers(value, 3, 4) then
			item.Type = "color"
			item.Value = Color(value[1], value[2], value[3], value[4] or 1)
		elseif is_numbers(value, 2, 3) then
			item.Type = #value == 2 and "vec2" or "vec3"
			item.Precision = 3
			item.Value = (#value == 2 and Vec2 or Vec3)(unpack(value))
		else
			item.Children = build(value, options, item_path, child_key)
			item.DataIndex = type(key) == "number" and key or nil

			if type(key) == "number" then
				field = nil
				local label = options.Schema and options.Schema.Labels and options.Schema.Labels[list_key]

				if label then item.Text = key .. "  " .. label(value) end
			end

			add_structure_actions(item.Children, data, key, value, item_path, field, options)
		end

		if item.Type then
			if item.Value == nil then item.Value = value end

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
		end

		items[#items + 1] = item

		if
			item.Type and
			field and
			field.Ref and
			options.Open and
			options.CanOpen(field.Ref) and
			kind == "string"
		then
			items[#items + 1] = action(item_path .. "/open", "open " .. value, function()
				options.Open(field.Ref, value)
			end)
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
		table.insert(item.Children and top or general.Children, item)
	end

	local structure = {Key = "/structure", Text = "add / remove keys", Expanded = false, Children = {}}
	add_structure_actions(structure.Children, nil, nil, data, "", options.Schema and options.Schema.Root, options)

	if #general.Children > 0 then table.insert(top, 1, general) end

	if #structure.Children > 0 then table.insert(top, structure) end

	return top
end

return data_items
