local styles = {}
styles.PARAM_FLOATS = 16
styles.version = 0
local definitions = {}
local order = {}
local SIZES = {float = 1, int = 1, bool = 1, vec3 = 3, color = 4, texture = 0}
local HOOKS = {
	{
		key = "Spawn",
		name = "spawn",
		signature = "uint index, uint generation, inout Particle p",
		return_type = "void",
	},
	{
		key = "Update",
		name = "update",
		signature = "uint index, float dt, float t, inout Particle p",
		return_type = "void",
	},
	{
		key = "Visibility",
		name = "visibility",
		signature = "float t, Particle p",
		return_type = "float",
	},
	{
		key = "Shade",
		name = "shade",
		signature = "float t, inout Particle p",
		return_type = "void",
	},
}
local RESERVED = {
	e = true,
	p = true,
	t = true,
	dt = true,
	index = true,
	generation = true,
	style = true,
}
styles.Hooks = HOOKS

function styles.Register(name, definition)
	assert(
		type(name) == "string" and name:find("^[%w_]+$"),
		"style names are letters, digits and underscores"
	)
	local layout = {}
	local offset = 0
	local seen = {}

	for _, param in ipairs(definition.Params or {}) do
		local size = assert(SIZES[param.Type], "unknown style param type " .. tostring(param.Type))
		assert(
			param.Name:find("^[A-Za-z][%w_]*$") and
				not RESERVED[param.Name] and
				not seen[param.Name],
			"bad style param name " .. param.Name
		)
		seen[param.Name] = true

		if size > 0 then
			layout[#layout + 1] = {param = param, offset = offset, size = size}
			offset = offset + size
		end
	end

	assert(
		offset <= styles.PARAM_FLOATS,
		("style %s uses %d of %d param floats"):format(name, offset, styles.PARAM_FLOATS)
	)

	if definition.Sprite then
		assert(seen[definition.Sprite], "the sprite param does not exist: " .. definition.Sprite)
	end

	local entry = {name = name, definition = definition, layout = layout}

	if definitions[name] then
		for index, other in ipairs(order) do
			if other == name then order[index] = name end
		end
	else
		order[#order + 1] = name
	end

	definitions[name] = entry
	styles.version = styles.version + 1
	return entry
end

function styles.Remove(name)
	if not definitions[name] then return end

	definitions[name] = nil

	for index, other in ipairs(order) do
		if other == name then
			table.remove(order, index)

			break
		end
	end

	styles.version = styles.version + 1
end

function styles.Get(name)
	return definitions[name]
end

function styles.GetNames()
	return {table.unpack(order)}
end

function styles.GetId(name)
	for index, other in ipairs(order) do
		if other == name then return index end
	end

	return 0
end

function styles.GetDefaults(name)
	local defaults = {}
	local entry = definitions[name]

	if not entry then return defaults end

	for _, param in ipairs(entry.definition.Params or {}) do
		defaults[param.Name] = type(param.Default) == "table" and table.copy(param.Default) or param.Default
	end

	return defaults
end

function styles.GetSpriteParam(name)
	local entry = definitions[name]
	return entry and entry.definition.Sprite
end

do
	local FIELDS = {color = {"r", "g", "b", "a"}, vec3 = {"x", "y", "z"}}

	function styles.WriteParams(name, values, target)
		local entry = definitions[name]

		if not entry then return end

		for _, item in ipairs(entry.layout) do
			local param = item.param
			local value = values and values[param.Name]

			if value == nil then value = param.Default end

			local type_name = param.Type

			if type_name == "bool" then
				value = value and 1 or 0
				type_name = "float"
			end

			if type(value) == "number" then
				target[math.floor(item.offset / 4)][item.offset % 4] = value
			else
				local names = FIELDS[type_name]
				local is_array = type(value) == "table" and value[1] ~= nil

				for component = 0, item.size - 1 do
					local slot = item.offset + component
					target[math.floor(slot / 4)][slot % 4] = (
							is_array and
							value[component + 1] or
							not is_array and
							value[names[component + 1]]
						)
						or
						0
				end
			end
		end
	end
end

local function get_locals(entry)
	local out = {}

	for _, item in ipairs(entry.layout) do
		local param = item.param
		local parts = {}

		for component = 0, item.size - 1 do
			local slot = item.offset + component
			parts[#parts + 1] = (
				"e.params[%d].%s"
			):format(math.floor(slot / 4), ("xyzw"):sub(slot % 4 + 1, slot % 4 + 1))
		end

		if param.Type == "float" then
			out[#out + 1] = ("float %s = %s;"):format(param.Name, parts[1])
		elseif param.Type == "int" then
			out[#out + 1] = ("int %s = int(%s);"):format(param.Name, parts[1])
		elseif param.Type == "bool" then
			out[#out + 1] = ("bool %s = %s > 0.5;"):format(param.Name, parts[1])
		elseif param.Type == "vec3" then
			out[#out + 1] = ("vec3 %s = vec3(%s);"):format(param.Name, table.concat(parts, ", "))
		else
			out[#out + 1] = ("vec4 %s = vec4(%s);"):format(param.Name, table.concat(parts, ", "))
		end
	end

	return table.concat(out, " ")
end

function styles.GetSourceId(style_id, hook_index)
	return style_id * 10 + hook_index
end

function styles.ParseError(message)
	local source, line, text = message:match("(%d+):(%d+): error: ([^\n]*)")

	if not source then return message end

	source = tonumber(source)
	local style = order[math.floor(source / 10)]
	local hook = HOOKS[source % 10]

	if not style or not hook then return message end

	return ("%s %s line %s: %s"):format(style, hook.name, line, text)
end

function styles.GetGLSL()
	local out = {}

	for hook_index, hook in ipairs(HOOKS) do
		local cases = {}
		local call = hook.key == "Spawn" and
			"e, index, generation, p" or
			hook.key == "Update" and
			"e, index, dt, t, p" or
			"e, t, p"

		for style_id, name in ipairs(order) do
			local entry = definitions[name]
			local body = entry.definition[hook.key]

			if body and body:find("%S") then
				local function_name = ("style_%d_%s"):format(style_id, hook.name)
				out[#out + 1] = (
					"%s %s(emitters_t e, %s) { %s\n#line 1 %d\n%s\n}\n"
				):format(
					hook.return_type,
					function_name,
					hook.signature,
					get_locals(entry),
					styles.GetSourceId(style_id, hook_index),
					body
				)
				cases[#cases + 1] = hook.return_type == "float" and
					(
						"case %d: return %s(%s);"
					):format(style_id, function_name, call) or
					(
						"case %d: %s(%s); break;"
					):format(style_id, function_name, call)
			end
		end

		local dispatch = hook.return_type == "float" and
			"switch (e.style) { %s default: break; } return 1.0;" or
			"switch (e.style) { %s default: break; }"
		out[#out + 1] = (
			"%s emitter_style_%s(emitters_t e, %s) { %s }\n"
		):format(
			hook.return_type,
			hook.name,
			hook.signature,
			dispatch:format(table.concat(cases, " "))
		)
	end

	return table.concat(out, "\n")
end

return styles
