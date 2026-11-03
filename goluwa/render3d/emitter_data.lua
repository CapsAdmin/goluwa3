local data_files = import("goluwa/data_files.lua")
local Color = import("goluwa/structs/color.lua")
local particle_emitter = import("goluwa/render3d/particle_emitter.lua")
local emitter_data = {}
emitter_data.MAX_VARIANTS = 16
local registry = {}
local vfx

local function build(data, inputs)
	local properties = data_files.Realize(table.copy(data))
	local declared = properties.Inputs
	properties.Inputs = nil
	properties.Preview = nil

	if inputs then
		for input_name in pairs(inputs) do
			assert(declared and declared[input_name], "unknown emitter input " .. input_name)
		end
	end

	if not declared then
		particle_emitter.CheckProperties(properties)
		return properties
	end

	for input_name, spec in pairs(declared) do
		local value = inputs and inputs[input_name]

		if value == nil then value = spec.Default or spec.DefaultColor end

		if value ~= nil then
			for _, target in ipairs(spec.Targets) do
				local property, mode = target[1], target[2]
				local current = properties[property]

				if current == nil then current = particle_emitter.GetDefault(property) end

				if type(value) == "number" then
					if mode == "set" then
						properties[property] = value
					elseif mode == "set_min" then
						properties[property] = {value, select(2, particle_emitter.GetRange(current))}
					elseif mode == "set_max" then
						properties[property] = {(particle_emitter.GetRange(current)), value}
					elseif mode == "scale" then
						properties[property] = particle_emitter.ScaleRange(current, value)
					elseif mode == "add" then
						properties[property] = particle_emitter.AddRange(current, value)
					else
						error("unknown input mode " .. tostring(mode) .. " on " .. input_name)
					end
				else
					assert(mode == "set", "color inputs only set, " .. input_name)
					properties[property] = Color(value.r, value.g, value.b, current.a)
				end
			end
		end
	end

	particle_emitter.CheckProperties(properties)
	return properties
end

function emitter_data.Set(name, data)
	build(data)
	local entry = registry[name]

	if not entry then
		entry = {variants = {}, count = 0}
		registry[name] = entry
	end

	entry.data = data

	if vfx then
		for key, inputs in pairs(entry.variants) do
			vfx.DefineBurst(key, build(data, inputs or nil))
		end
	end
end

function emitter_data.Has(name)
	return registry[name] ~= nil
end

function emitter_data.Get(name, inputs)
	return build(registry[name].data, inputs)
end

function emitter_data.GetBurstKey(name, inputs)
	if not inputs or not next(inputs) then return name end

	local names = {}

	for input_name in pairs(inputs) do
		names[#names + 1] = input_name
	end

	table.sort(names)
	local parts = {name}

	for _, input_name in ipairs(names) do
		local value = inputs[input_name]
		parts[#parts + 1] = input_name .. "=" .. (
				type(value) == "number" and
				(
					"%.4g"
				):format(value) or
				(
					"%.3g,%.3g,%.3g"
				):format(value.r, value.g, value.b)
			)
	end

	return table.concat(parts, ":")
end

function emitter_data.DefineBurst(name, inputs)
	vfx = vfx or import("goluwa/render3d/vfx.lua")
	local key = emitter_data.GetBurstKey(name, inputs)

	if vfx.HasBurst(key) then return key end

	local entry = registry[name]

	if entry.count == emitter_data.MAX_VARIANTS then
		logn(
			"emitter ",
			name,
			" has ",
			emitter_data.MAX_VARIANTS,
			" input variants, each one is a gpu emitter: round the input values"
		)
	end

	entry.count = entry.count + 1
	entry.variants[key] = inputs or false
	vfx.DefineBurst(key, emitter_data.Get(name, inputs))
	return key
end

function emitter_data.Burst(name, position, direction, count, inputs)
	local key = emitter_data.DefineBurst(name, inputs)
	vfx.Burst(key, position, direction, count)
end

return emitter_data
