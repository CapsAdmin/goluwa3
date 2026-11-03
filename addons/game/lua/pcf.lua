local ffi = require("ffi")
local vfs = import("goluwa/vfs.lua")
local vtf = import("goluwa/codecs/vtf.lua")
local pcf = {}
pcf.Directory = "particles/"
pcf.UNIT = 0.0254
pcf.GRAVITY = 9.81
pcf.MAX_PARTICLES = 16384
pcf.FRAME_RATE = 30
local ATTRIBUTE_ELEMENT, ATTRIBUTE_INT, ATTRIBUTE_FLOAT, ATTRIBUTE_BOOL, ATTRIBUTE_STRING, ATTRIBUTE_BINARY, ATTRIBUTE_TIME, ATTRIBUTE_COLOR, ATTRIBUTE_VEC2, ATTRIBUTE_VEC3, ATTRIBUTE_VEC4, ATTRIBUTE_ANGLE, ATTRIBUTE_QUAT, ATTRIBUTE_MATRIX = 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14
local i32_pointer = ffi.typeof("const int32_t *")
local f32_pointer = ffi.typeof("const float *")
local u16_pointer = ffi.typeof("const uint16_t *")
local byte_pointer = ffi.typeof("const uint8_t *")

function pcf.Parse(data)
	local header_end = data:find("\n", 1, true)
	local version = tonumber(data:sub(1, header_end):match("binary (%d+)"))
	assert(
		version and version >= 2 and version <= 5,
		"unsupported pcf encoding " .. data:sub(1, header_end)
	)
	local bytes = ffi.cast(byte_pointer, data)
	local offset = header_end

	if bytes[offset] == 0 then offset = offset + 1 end

	local function read_u16()
		local value = ffi.cast(u16_pointer, bytes + offset)[0]
		offset = offset + 2
		return value
	end

	local function read_i32()
		local value = ffi.cast(i32_pointer, bytes + offset)[0]
		offset = offset + 4
		return value
	end

	local function read_floats(count)
		local pointer = ffi.cast(f32_pointer, bytes + offset)
		local values = {}

		for i = 1, count do
			values[i] = pointer[i - 1]
		end

		offset = offset + count * 4
		return count == 1 and values[1] or values
	end

	local function read_string()
		local finish = data:find("\0", offset + 1, true)
		local value = data:sub(offset + 1, finish - 1)
		offset = finish
		return value
	end

	local read_index = version < 4 and read_u16 or read_i32
	local strings = {}

	for i = 1, read_index() do
		strings[i - 1] = read_string()
	end

	local elements = {}

	for i = 1, read_i32() do
		local element_type = strings[read_index()]
		local name = version < 4 and read_string() or strings[read_index()]
		offset = offset + 16
		elements[i - 1] = {type = element_type, name = name, attributes = {}}
	end

	local function read_value(kind)
		if kind == ATTRIBUTE_ELEMENT then return {element = read_i32()} end

		if kind == ATTRIBUTE_INT then return read_i32() end

		if kind == ATTRIBUTE_FLOAT then return read_floats(1) end

		if kind == ATTRIBUTE_BOOL then
			offset = offset + 1
			return bytes[offset - 1] ~= 0
		end

		if kind == ATTRIBUTE_STRING then
			return version < 5 and read_string() or strings[read_index()]
		end

		if kind == ATTRIBUTE_BINARY then
			offset = offset + 4 + read_i32()
			return false
		end

		if kind == ATTRIBUTE_TIME then return read_i32() / 10000 end

		if kind == ATTRIBUTE_COLOR then
			offset = offset + 4
			return {bytes[offset - 4], bytes[offset - 3], bytes[offset - 2], bytes[offset - 1]}
		end

		if kind == ATTRIBUTE_VEC2 then return read_floats(2) end

		if kind == ATTRIBUTE_VEC3 or kind == ATTRIBUTE_ANGLE then
			return read_floats(3)
		end

		if kind == ATTRIBUTE_VEC4 or kind == ATTRIBUTE_QUAT then
			return read_floats(4)
		end

		if kind == ATTRIBUTE_MATRIX then return read_floats(16) end

		error("unknown pcf attribute type " .. kind)
	end

	for index = 0, #elements do
		local attributes = elements[index].attributes

		for _ = 1, read_i32() do
			local name = strings[read_index()]
			local kind = bytes[offset]
			offset = offset + 1

			if kind > ATTRIBUTE_MATRIX then
				local list = {}

				for i = 1, read_i32() do
					list[i] = read_value(kind - ATTRIBUTE_MATRIX)
				end

				attributes[name] = list
			else
				attributes[name] = read_value(kind)
			end
		end
	end

	local systems = {}

	for _, reference in ipairs(elements[0].attributes.particleSystemDefinitions or {}) do
		local definition = elements[reference.element]
		local system = {name = definition.name, properties = {}, operators = {}, children = {}}

		for key, value in pairs(definition.attributes) do
			if key == "children" then
				for _, child_reference in ipairs(value) do
					local child = elements[child_reference.element]
					local target = child.attributes.child
					system.children[#system.children + 1] = {
						name = target and elements[target.element].name or child.name,
						delay = child.attributes.delay or 0,
					}
				end
			elseif
				type(value) == "table" and
				value[1] and
				type(value[1]) == "table" and
				value[1].element
			then
				local list = {}

				for i, operator_reference in ipairs(value) do
					local operator = elements[operator_reference.element]
					local entry = {name = operator.attributes.functionName or operator.name}

					for operator_key, operator_value in pairs(operator.attributes) do
						entry[operator_key] = operator_value
					end

					list[i] = entry
				end

				system.operators[key] = list
			else
				system.properties[key] = value
			end
		end

		systems[#systems + 1] = system
	end

	return systems
end

function pcf.GetFiles()
	local names = {}

	for _, file in ipairs(vfs.Find(pcf.Directory .. "%.pcf$")) do
		names[#names + 1] = file:gsub("%.pcf$", "")
	end

	table.sort(names)
	return names
end

do
	local cache = {}

	function pcf.GetSystems(file)
		if not cache[file] then
			local data = assert(vfs.Read(pcf.Directory .. file .. ".pcf"))
			local ok, systems = pcall(pcf.Parse, data)
			cache[file] = ok and systems or {}
		end

		return cache[file]
	end

	function pcf.Clear()
		cache = {}
		pcf.names_cache = nil
		pcf.lookup = nil
	end
end

function pcf.GetNames()
	if not pcf.names_cache then
		local names = {}
		pcf.lookup = {}
		pcf.by_name = {}

		for _, file in ipairs(pcf.GetFiles()) do
			for _, system in ipairs(pcf.GetSystems(file)) do
				local name = file .. "/" .. system.name
				system.file = file
				names[#names + 1] = name
				pcf.lookup[name] = system
				pcf.by_name[system.name] = pcf.by_name[system.name] or name
			end
		end

		table.sort(names)

		if #names == 0 then return names end

		pcf.names_cache = names
	end

	return pcf.names_cache
end

function pcf.GetChildren(name)
	local system = pcf.GetSystem(name)
	local children = {}

	for _, child in ipairs(system.children) do
		local key = system.file .. "/" .. child.name

		if not pcf.lookup[key] then key = pcf.by_name[child.name] end

		if key then children[#children + 1] = {name = key, delay = child.delay} end
	end

	return children
end

function pcf.GetSystem(name)
	pcf.GetNames()
	return pcf.lookup[name]
end

function pcf.Find(text)
	local names = pcf.GetNames()

	if pcf.lookup[text] then return text end

	for _, name in ipairs(names) do
		if name:lower():find(text:lower(), 1, true) then return name end
	end
end

do
	local cache = {}

	function pcf.GetMaterial(name)
		if cache[name] ~= nil then return cache[name] or nil end

		cache[name] = false
		local path = "materials/" .. name:lower():gsub("\\", "/")
		local text = vfs.Read(path)

		if not text then return end

		text = text:lower():gsub("//[^\n]*", "")

		local function value(key)
			return text:match("\"?%$" .. key .. "\"?%s+\"?([^\"%s]+)\"?")
		end

		local texture = value("basetexture")

		if not texture then return end

		texture = "materials/" .. texture:gsub("\\", "/") .. ".vtf"

		if not vfs.IsFile(texture) then return end

		local data = vfs.Read(texture)
		cache[name] = {
			texture = texture,
			sheet = data and vtf.ParseSheet(data),
			additive = (tonumber(value("additive")) or 0) > 0 or (tonumber(value("addself")) or 0) > 0,
			overbright = tonumber(value("overbrightfactor")) or 1,
		}
		return cache[name]
	end

	function pcf.SetMaterial(name, look)
		cache[name] = look
	end

	function pcf.ClearMaterials()
		cache = {}
	end
end

local function get(operator, key, default)
	local value = operator[key]

	if value == nil then return default end

	return value
end

local function color_of(rgba)
	return {rgba[1] / 255, rgba[2] / 255, rgba[3] / 255, (rgba[4] or 255) / 255}
end

local function bias(t, amount)
	if amount == 0.5 or t <= 0 or t >= 1 then return t end

	return t ^ (math.log(amount) / math.log(0.5))
end

local function ease(t)
	return t * t * (3 - 2 * t)
end

local function sample_times(start_time, end_time)
	local times = {0}

	for i = 0, 8 do
		local t = start_time + (end_time - start_time) * i / 8

		if t > times[#times] + 1e-6 and t < 1 then times[#times + 1] = t end
	end

	if times[#times] < 1 then times[#times + 1] = 1 end

	return times
end

local function lerp_color(a, b, f)
	return {
		a[1] + (
			b[1] - a[1]
		) * f,
		a[2] + (
			b[2] - a[2]
		) * f,
		a[3] + (
			b[3] - a[3]
		) * f,
		a[4] + (
			b[4] - a[4]
		) * f,
	}
end

local function sample_keys(keys, t)
	local last = keys[#keys]

	if t <= keys[1][1] then return keys[1][2] end

	for i = 2, #keys do
		if t <= keys[i][1] then
			local from, to = keys[i - 1], keys[i]
			local f = (t - from[1]) / math.max(to[1] - from[1], 1e-9)
			local a, b = from[2], to[2]

			if type(a) == "number" then return a + (b - a) * f end

			return lerp_color(a, b, f)
		end
	end

	return last[2]
end

local function merge_times(...)
	local seen, times = {}, {}

	for _, keys in ipairs{...} do
		for _, key in ipairs(keys) do
			local t = math.floor(key[1] * 1e5 + 0.5) / 1e5

			if not seen[t] then
				seen[t] = true
				times[#times + 1] = t
			end
		end
	end

	table.sort(times)
	return times
end

local OPERATORS_HANDLED = {
	["Lifetime Random"] = true,
	["Radius Random"] = true,
	["Color Random"] = true,
	["Alpha Random"] = true,
	["Position Within Sphere Random"] = true,
	["Position Within Box Random"] = true,
	["Velocity Random"] = true,
	["Velocity Noise"] = true,
	["Rotation Random"] = true,
	["Rotation Speed Random"] = true,
	["Rotation Yaw Flip Random"] = true,
	["Sequence Random"] = true,
	["Lifetime From Sequence"] = true,
	["lifetime from sequence"] = true,
	["Trail Length Random"] = true,
	["Movement Basic"] = true,
	["Lifespan Decay"] = true,
	["Radius Scale"] = true,
	["Alpha Fade In Random"] = true,
	["Alpha Fade Out Random"] = true,
	["Alpha Fade In Simple"] = true,
	["Alpha Fade Out Simple"] = true,
	["Alpha Fade and Decay"] = true,
	["Color Fade"] = true,
	["Rotation Spin Roll"] = true,
	["Rotation Basic"] = true,
	["random force"] = true,
	["twist around axis"] = true,
	["Collision via traces"] = true,
	["Prevent passing through static part of world"] = true,
	["Lifespan Minimum Velocity Decay"] = true,
	["emit_continuously"] = true,
	["emit_instantaneously"] = true,
	["render_animated_sprites"] = true,
	["render_sprite_trail"] = true,
	["Cull relative to Ray Trace Environment"] = true,
}

function pcf.Convert(system)
	local data = {}
	local notes = {}
	local by_name = {}
	local unit = pcf.UNIT

	for _, category in ipairs{"emitters", "initializers", "operators", "forces", "constraints", "renderers"} do
		for _, operator in ipairs(system.operators[category] or {}) do
			by_name[operator.name] = by_name[operator.name] or {}
			table.insert(by_name[operator.name], operator)

			if not OPERATORS_HANDLED[operator.name] then
				notes[operator.name] = (notes[operator.name] or 0) + 1
			end
		end
	end

	local function first(name)
		return by_name[name] and by_name[name][1]
	end

	local properties = system.properties
	local look = pcf.GetMaterial(tostring(properties.material or ""))
	data.MaxParticles = math.clamp(math.floor(get(properties, "max_particles", 1000)), 1, pcf.MAX_PARTICLES)
	data.Lit = false
	data.Spread = 0
	data.GravityScale = 0
	data.Drag = 0
	data.Shape = "point"
	data.Rate = 0
	local radius_min = get(properties, "radius", 5)
	local radius_max = radius_min
	local radius = first("Radius Random")

	if radius then
		radius_min = get(radius, "radius_min", 1)
		radius_max = get(radius, "radius_max", 1)
	end

	local lifetime = first("Lifetime Random")
	data.Lifetime = lifetime and
		{get(lifetime, "lifetime_min", 0), get(lifetime, "lifetime_max", 0)} or
		{1, 1}
	data.Lifetime[1] = math.max(data.Lifetime[1], 0.01)
	data.Lifetime[2] = math.max(data.Lifetime[2], 0.01)
	local sequence_lifetime = first("lifetime from sequence") or first("Lifetime From Sequence")

	if sequence_lifetime then
		local random_sequence = first("Sequence Random")
		local sequence = look and
			look.sheet and
			look.sheet.sequences[(
				random_sequence and
				get(random_sequence, "sequence_min", 0) or
				0
			) + 1]
		local time = sequence and sequence.time or 1
		data.Lifetime = {time, time}
	end

	local emit = first("emit_continuously")
	local burst = first("emit_instantaneously")

	if emit then
		data.Rate = get(emit, "emission_rate", 100)
		local duration = get(emit, "emission_duration", 0)

		if duration > 0 then
			data.Loop = false
			data.Duration = duration
		end
	elseif burst then
		data.Rate = get(burst, "num_to_emit", 1) * pcf.FRAME_RATE
		data.Loop = false
		data.Duration = 1 / pcf.FRAME_RATE + 0.001
	end

	local sphere = first("Position Within Sphere Random")
	local box = first("Position Within Box Random")
	local local_min, local_max = {0, 0, 0}, {0, 0, 0}

	local function add_local(low, high)
		for i = 1, 3 do
			local_min[i] = local_min[i] + low[i]
			local_max[i] = local_max[i] + high[i]
		end
	end

	local radial_min, radial_max = 0, 0

	if sphere then
		add_local(
			get(sphere, "speed_in_local_coordinate_system_min", {0, 0, 0}),
			get(sphere, "speed_in_local_coordinate_system_max", {0, 0, 0})
		)
		radial_min = get(sphere, "speed_min", 0)
		radial_max = get(sphere, "speed_max", 0)
		local distance_max = get(sphere, "distance_max", 0)

		if distance_max > 0 then
			local bias_z = get(sphere, "distance_bias", {1, 1, 1})[3]
			data.Shape = bias_z == 0 and "disc" or "sphere"
			data.ShapeSize = {distance_max * 2 * unit, distance_max * 2 * unit, distance_max * 2 * unit}
		end
	elseif box then
		local box_min, box_max = get(box, "min", {0, 0, 0}), get(box, "max", {0, 0, 0})
		data.Shape = "box"
		data.ShapeSize = {
			math.abs(box_max[1] - box_min[1]) * unit,
			math.abs(box_max[3] - box_min[3]) * unit,
			math.abs(box_max[2] - box_min[2]) * unit,
		}
	end

	for _, velocity in ipairs(by_name["Velocity Random"] or {}) do
		add_local(
			get(velocity, "speed_in_local_coordinate_system_min", {0, 0, 0}),
			get(velocity, "speed_in_local_coordinate_system_max", {0, 0, 0})
		)
	end

	for _, noise in ipairs(by_name["Velocity Noise"] or {}) do
		add_local(get(noise, "output minimum", {0, 0, 0}), get(noise, "output maximum", {0, 0, 0}))
	end

	local along_min = math.min(local_min[3], local_max[3])
	local along_max = math.max(local_min[3], local_max[3])
	local sideways = math.max(
		math.abs(local_min[1]),
		math.abs(local_max[1]),
		math.abs(local_min[2]),
		math.abs(local_max[2])
	)

	if radial_max > 0 and along_max <= 0 then
		data.Speed = {radial_min * unit, radial_max * unit}

		if data.Shape == "point" then data.Spread = 180 end
	elseif along_max > 0 or sideways > 0 then
		data.Speed = {math.max(along_min, 0) * unit, math.max(along_max, sideways) * unit}

		if sideways > 0 then
			data.Spread = math.min(math.deg(math.atan2(sideways, math.max(math.abs(along_max), 1e-3))), 180)
		end
	else
		data.Speed = 0
	end

	local movement = first("Movement Basic")

	if movement then
		local gravity = get(movement, "gravity", {0, 0, 0})
		data.GravityScale = -gravity[3] * unit / pcf.GRAVITY
		data.Drag = get(movement, "drag", 0)
	end

	local spin_speed = first("Rotation Speed Random")

	if spin_speed then
		data.Spin = {
			get(spin_speed, "rotation_speed_random_min", 0),
			get(spin_speed, "rotation_speed_random_max", 0),
		}
	end

	local spin_roll = first("Rotation Spin Roll")

	if spin_roll then
		local rate = get(spin_roll, "spin_rate_degrees", 0)
		data.Spin = data.Spin and {data.Spin[1] + rate, data.Spin[2] + rate} or {rate, rate}
	end

	local flip = first("Rotation Yaw Flip Random")

	if flip then data.FlipRandom = get(flip, "Flip Percentage", 0.5) end

	local random_force = first("random force")

	if random_force then
		local max_force = get(random_force, "max force", {0, 0, 0})
		data.Fizzle = math.max(math.abs(max_force[1]), math.abs(max_force[2]), math.abs(max_force[3])) * unit * 0.5
		data.FizzleStart = 0
	end

	local twist = first("twist around axis")

	if twist then
		local axis = get(twist, "twist axis", {0, 0, 1})
		data.Swirl = get(twist, "amount of force", 0) * unit * (axis[3] < 0 and -1 or 1)
	end

	local minimum_velocity = first("Lifespan Minimum Velocity Decay")

	if minimum_velocity then
		data.MinSpeed = math.max(get(minimum_velocity, "minimum velocity", 0.1) * unit, 0.05)
	end

	if first("Collision via traces") then
		data.Collision = "rays"
		local collision = first("Collision via traces")
		data.Restitution = math.clamp(get(collision, "amount of bounce", 1), 0, 1)
		data.Friction = math.clamp(1 - get(collision, "amount of slide", 1), 0, 1)
	end

	local renderer = first("render_animated_sprites")
	local trail = first("render_sprite_trail")

	if trail then
		data.Stretch = math.clamp(get(trail, "max length", 0.1) / 20, 0.02, 2)
		data.Shader = "glow"
	elseif renderer then
		if
			get(renderer, "orientation_type", 0) == 2 or
			get(renderer, "orientation_type", 0) == 1
		then
			data.Orientation = "ground"
		end

		if get(renderer, "use animation rate as FPS", false) then
			data.FlipbookFps = get(renderer, "animation rate", 0)
		end
	end

	local sequences = first("Sequence Random")

	if sequences then
		local low, high = get(sequences, "sequence_min", 0), get(sequences, "sequence_max", 0)
		data.Sequence = {math.min(low, high), math.max(low, high)}
	end

	if first("Sequence Two Random") then data.FlipbookRandomStart = true end

	local base = color_of(get(properties, "color", {255, 255, 255, 255}))
	local color_low, color_high = {base[1], base[2], base[3]}, {base[1], base[2], base[3]}
	local color_random = first("Color Random")

	if color_random then
		local one, two = color_of(get(color_random, "color1", {255, 255, 255, 255})),
		color_of(get(color_random, "color2", {255, 255, 255, 255}))
		color_low, color_high = {one[1], one[2], one[3]}, {two[1], two[2], two[3]}
	end

	local alpha_low, alpha_high = base[4], base[4]
	local alpha_random = first("Alpha Random")

	if alpha_random then
		alpha_low = get(alpha_random, "alpha_min", 255) / 255
		alpha_high = get(alpha_random, "alpha_max", 255) / 255
	end

	local fade_in_start, fade_in_end = 0, 0
	local fade_out_start, fade_out_end = 1, 1
	local fade_in_random = first("Alpha Fade In Random")
	local fade_out_random = first("Alpha Fade Out Random")
	local fade_in_simple = first("Alpha Fade In Simple")
	local fade_out_simple = first("Alpha Fade Out Simple")
	local fade_decay = first("Alpha Fade and Decay")

	if fade_in_random then
		fade_in_end = (
				get(fade_in_random, "fade in time min", 0) + get(fade_in_random, "fade in time max", 0)
			) / 2
	elseif fade_in_simple then
		fade_in_end = get(fade_in_simple, "proportional fade in time", 0.5)
	end

	if fade_out_random then
		fade_out_start = 1 - (
				get(fade_out_random, "fade out time min", 0) + get(fade_out_random, "fade out time max", 0)
			) / 2
	elseif fade_out_simple then
		fade_out_start = 1 - get(fade_out_simple, "proportional fade out time", 0.5)
	end

	if fade_decay then
		fade_in_start = get(fade_decay, "start_fade_in_time", 0)
		fade_in_end = get(fade_decay, "end_fade_in_time", 0)
		fade_out_start = get(fade_decay, "start_fade_out_time", 1)
		fade_out_end = get(fade_decay, "end_fade_out_time", 1)
		alpha_low = alpha_low * get(fade_decay, "start_alpha", 1)
		alpha_high = alpha_high * get(fade_decay, "start_alpha", 1)
	end

	local function alpha_keys(amount)
		local keys = {}

		if fade_in_end > fade_in_start then
			if fade_in_start > 0 then keys[#keys + 1] = {0, 0} end

			keys[#keys + 1] = {fade_in_start, 0}
			keys[#keys + 1] = {fade_in_end, amount}
		else
			keys[#keys + 1] = {0, amount}
		end

		if fade_out_start < 1 then
			keys[#keys + 1] = {math.max(fade_out_start, keys[#keys][1]), amount}
			keys[#keys + 1] = {math.min(math.max(fade_out_end, fade_out_start + 0.001), 1), 0}
		end

		return keys
	end

	local low_alpha, high_alpha = alpha_keys(alpha_low), alpha_keys(alpha_high)
	local times = merge_times(low_alpha, high_alpha)
	local color_fade = first("Color Fade")
	local fade_color

	if color_fade then
		local target = color_of(get(color_fade, "color_fade", {255, 255, 255, 255}))
		fade_color = {
			target = target,
			start = get(color_fade, "fade_start_time", 0),
			finish = get(color_fade, "fade_end_time", 1),
			ease = get(color_fade, "ease_in_and_out", false),
		}
		local fade_keys = {}

		for i, t in ipairs(sample_times(fade_color.start, fade_color.finish)) do
			fade_keys[i] = {t}
		end

		times = merge_times(low_alpha, high_alpha, fade_keys)
	end

	local function color_curve(rgb, alphas)
		local keys = {}

		for i, t in ipairs(times) do
			local color = {rgb[1], rgb[2], rgb[3], sample_keys(alphas, t)}

			if fade_color then
				local f = math.clamp(
					(t - fade_color.start) / math.max(fade_color.finish - fade_color.start, 1e-6),
					0,
					1
				)

				if fade_color.ease then f = ease(f) end

				color = {
					color[1] + (
						fade_color.target[1] - color[1]
					) * f,
					color[2] + (
						fade_color.target[2] - color[2]
					) * f,
					color[3] + (
						fade_color.target[3] - color[3]
					) * f,
					color[4],
				}
			end

			keys[i] = {t, color}
		end

		return keys
	end

	if
		color_random or
		alpha_random or
		fade_color or
		fade_in_random or
		fade_in_simple or
		fade_out_random or
		fade_out_simple or
		fade_decay
	then
		data.Color = {Keys = color_curve(color_low, low_alpha)}

		if color_random or alpha_random then
			data.Color.MaxKeys = color_curve(color_high, high_alpha)
		end
	else
		data.Color = {
			Keys = {
				{0, {base[1], base[2], base[3], base[4]}},
				{1, {base[1], base[2], base[3], base[4]}},
			},
		}
	end

	local scale = first("Radius Scale")
	local scale_start, scale_end, scale_from, scale_to, scale_bias, scale_ease = 1, 1, 0, 1, 0.5, false

	if scale then
		scale_start = get(scale, "radius_start_scale", 1)
		scale_end = get(scale, "radius_end_scale", 1)
		scale_from = get(scale, "start_time", 0)
		scale_to = get(scale, "end_time", 1)
		scale_bias = get(scale, "scale_bias", 0.5)
		scale_ease = get(scale, "ease_in_and_out", false)
	end

	local function size_curve(base_radius)
		local keys = {}

		for i, t in ipairs(sample_times(scale_from, scale_to)) do
			local f = math.clamp((t - scale_from) / math.max(scale_to - scale_from, 1e-6), 0, 1)
			f = scale_ease and ease(f) or bias(f, scale_bias)
			keys[i] = {t, base_radius * 2 * unit * (scale_start + (scale_end - scale_start) * f)}
		end

		return keys
	end

	if scale then
		data.Size = {Keys = size_curve(radius_min)}

		if radius_max ~= radius_min then data.Size.MaxKeys = size_curve(radius_max) end
	elseif radius_min ~= radius_max then
		data.Size = {
			math.min(radius_min, radius_max) * 2 * unit,
			math.max(radius_min, radius_max) * 2 * unit,
		}
	else
		data.Size = radius_min * 2 * unit
	end

	if type(data.Size) == "table" and data.Size.Keys and data.Size.MaxKeys then
		local low, high = data.Size.Keys, data.Size.MaxKeys

		for i, key in ipairs(low) do
			if key[2] > high[i][2] then low[i][2], high[i][2] = high[i][2], key[2] end
		end
	end

	local material = tostring(properties.material or ""):lower()
	data.Emissive = 60000

	if look then
		if not trail then
			data.Shader = "sprite"
			data.ShaderParams = {Sprite = look.texture}
		end

		data.Lit = not look.additive
		data.AlphaFromColor = look.additive and not trail or nil
		data.Emissive = look.additive and 60000 * math.min(look.overbright, 2) or 0
	elseif not trail then
		if
			material:find("smoke") or
			material:find("dust") or
			material:find("steam") or
			material:find("cloud") or
			material:find("mist")
		then
			data.Shader = "sprite"
			data.ShaderParams = {Sprite = "smoke"}
			data.Lit = true
			data.Emissive = 0
		elseif
			material:find("fire") or
			material:find("flame") or
			material:find("explo") or
			material:find("burn")
		then
			data.Shader = "sprite"
			data.ShaderParams = {Sprite = "fire"}
			data.Emissive = 10000

			if not color_random and base[1] + base[2] + base[3] > 2.9 then
				for _, key in ipairs(data.Color.Keys) do
					key[2][2], key[2][3] = key[2][2] * 0.6, key[2][3] * 0.25
				end
			end
		elseif material:find("ring") or material:find("shock") then
			data.Shader = "sprite"
			data.ShaderParams = {Sprite = "ring"}
		end
	end

	for _, value in ipairs{data.Color, data.Size} do
		if type(value) == "table" then
			for _, name in ipairs{"Keys", "MaxKeys"} do
				local keys = value[name]

				if keys then
					for _, key in ipairs(keys) do
						key[1] = math.clamp(key[1], 0, 1)
					end

					table.sort(keys, function(a, b)
						return a[1] < b[1]
					end)
				end
			end
		end
	end

	return data, notes
end

function pcf.DescribeNotes(system, notes)
	local lines = {}
	local names = {}

	for name, count in pairs(notes) do
		names[#names + 1] = name .. (count > 1 and (" x" .. count) or "")
	end

	table.sort(names)

	if #names > 0 then
		lines[#lines + 1] = "not converted: " .. table.concat(names, ", ")
	end

	if #system.children > 0 then
		local children = {}

		for i, child in ipairs(system.children) do
			children[i] = child.name
		end

		lines[#lines + 1] = "children: " .. table.concat(children, ", ")
	end

	return table.concat(lines, " | ")
end

return pcf
