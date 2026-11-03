local vfs = import("goluwa/vfs.lua")
local data_files = import("goluwa/data_files.lua")
local Color = import("goluwa/structs/color.lua")
local emitters = {}
emitters.Files = data_files.New("lua/emitters/")
emitters.Names = {}
emitters.MAX_VARIANTS = 16
local variants = {}
local vfx

function emitters.Init()
	if emitters.Initialized then return end

	emitters.Initialized = true

	for _, file in ipairs(vfs.Find("lua/emitters/%.lua$")) do
		local name = file:gsub("%.lua$", "")
		emitters.Names[#emitters.Names + 1] = name
		emitters.Files:Remember(name, emitters.Files:Read(name))
	end

	table.sort(emitters.Names)
end

local function build(data, inputs)
	local properties = data_files.Realize(table.copy(data))
	local declared = properties.Inputs
	properties.Inputs = nil

	if inputs then
		for input_name in pairs(inputs) do
			assert(declared and declared[input_name], "unknown emitter input " .. input_name)
		end
	end

	if not declared then return properties end

	for input_name, spec in pairs(declared) do
		local value = inputs and inputs[input_name]

		if value == nil then value = spec.Default or spec.DefaultColor end

		if value ~= nil then
			for _, target in ipairs(spec.Targets) do
				local property, mode = target[1], target[2]

				if type(value) == "number" then
					if mode == "set" then
						properties[property] = value
					elseif mode == "scale" then
						properties[property] = properties[property] * value
					elseif mode == "add" then
						properties[property] = properties[property] + value
					else
						error("unknown input mode " .. tostring(mode) .. " on " .. input_name)
					end
				else
					assert(mode == "set", "color inputs only set, " .. input_name)
					properties[property] = Color(value.r, value.g, value.b, properties[property].a)
				end
			end
		end
	end

	return properties
end

function emitters.Get(name, inputs)
	return build(emitters.Files.Source[name], inputs)
end

function emitters.GetBurstKey(name, inputs)
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

function emitters.DefineBurst(name, inputs)
	vfx = vfx or import("goluwa/render3d/vfx.lua")
	local key = emitters.GetBurstKey(name, inputs)

	if vfx.HasBurst(key) then return key end

	local defined = variants[name]

	if not defined then
		defined = {count = 0, inputs = {}}
		variants[name] = defined
	end

	if defined.count == emitters.MAX_VARIANTS then
		logn(
			"emitter ",
			name,
			" has ",
			emitters.MAX_VARIANTS,
			" input variants, each one is a gpu emitter: round the input values"
		)
	end

	defined.count = defined.count + 1
	defined.inputs[key] = inputs or false
	vfx.DefineBurst(key, emitters.Get(name, inputs))
	return key
end

function emitters.Burst(name, position, direction, count, inputs)
	local key = emitters.DefineBurst(name, inputs)
	vfx.Burst(key, position, direction, count)
end

function emitters.Update(name, data)
	build(data)
	emitters.Files:Remember(name, data)

	if not table.has_value(emitters.Names, name) then
		emitters.Names[#emitters.Names + 1] = name
		table.sort(emitters.Names)
	end

	local defined = variants[name]

	if defined then
		for key, inputs in pairs(defined.inputs) do
			vfx.DefineBurst(key, emitters.Get(name, inputs or nil))
		end
	end
end

function emitters.Reload(name)
	emitters.Update(name, emitters.Files:Read(name))
end

function emitters.Save(name)
	return emitters.Files:Save(name)
end

function emitters.Create(name, from)
	emitters.Update(name, table.copy(emitters.Files.Source[from]))
	return name
end

function emitters.GetNewName(base)
	local index = 2

	while table.has_value(emitters.Names, base .. "_" .. index) do
		index = index + 1
	end

	return base .. "_" .. index
end

emitters.Init()
return emitters
