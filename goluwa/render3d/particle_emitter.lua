local event = import("goluwa/event.lua")
local list = import("goluwa/list.lua")
local system = import("goluwa/system.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local curve = import("goluwa/math/curve.lua")
local particle_emitter = {}
particle_emitter.GPU_MAX_PARTICLES = 16384
particle_emitter.CPU_MAX_PARTICLES = 4096
particle_emitter.instances = {}
particle_emitter.SHAPES = {"point", "sphere", "cone", "box", "disc"}
particle_emitter.GPU_COLLISIONS = {"none", "shelter_map", "scene_depth", "rays"}
particle_emitter.CPU_COLLISIONS = {"none", "rays"}
particle_emitter.ON_HIT = {"bounce", "stick", "kill"}
particle_emitter.MESHES = {"quad", "sphere", "cube", "shard", "feather"}
local SAMPLES = 32
particle_emitter.CURVE_SAMPLES = SAMPLES
local number = {validate = "number"}
local integer = {validate = "integer"}
local boolean = {validate = "boolean"}

local function ranged(min, max)
	return {validate = "number", min = min, max = max}
end

local CURVE_MODES = {linear = true, smooth = true, step = true}

local function is_color(value)
	return type(value) == "cdata" or
		(
			type(value) == "table" and
			type(value[1]) == "number" and
			type(value[2]) == "number" and
			type(value[3]) == "number"
		)
end

local function keys_problem(keys, color)
	if type(keys) ~= "table" or #keys == 0 then
		return "curve keys must be a list of {time, value}"
	end

	local previous = 0

	for i, key in ipairs(keys) do
		if type(key) ~= "table" or type(key[1]) ~= "number" or key[1] < 0 or key[1] > 1 then
			return ("curve key %d: expected {time, value} with a time from 0 to 1"):format(i)
		end

		if key[1] < previous then return "curve key times must not decrease" end

		previous = key[1]

		if color and not is_color(key[2]) then
			return ("curve key %d: expected a color value"):format(i)
		elseif not color and type(key[2]) ~= "number" then
			return ("curve key %d: expected a number value"):format(i)
		end

		if key[3] ~= nil and not CURVE_MODES[key[3]] then
			return ("curve key %d: unknown interpolation %s"):format(i, tostring(key[3]))
		end
	end
end

local function range_problem(value)
	if type(value) == "number" then return end

	if
		type(value) == "table" and
		type(value[1]) == "number" and
		type(value[2]) == "number"
	then
		return
	end

	return "expected a number or {min, max}, got " .. tostring(value)
end

local function scalar_band_problem(value)
	if type(value) == "table" and value.Keys then
		return keys_problem(value.Keys, false) or
			(
				value.MaxKeys and
				keys_problem(value.MaxKeys, false)
			)
	end

	return range_problem(value)
end

local function color_band_problem(value)
	if is_color(value) then return end

	if type(value) == "table" then
		if value.Keys then
			return keys_problem(value.Keys, true) or
				(
					value.MaxKeys and
					keys_problem(value.MaxKeys, true)
				)
		end

		if is_color(value[1]) and is_color(value[2]) then return end
	end

	return "expected a color, {color, color} or a curve with Keys, got " .. tostring(value)
end

local function validator(problem_of, min, max)
	local check = {problem = problem_of, min = min, max = max, type = "nil"}

	function check.validate(value, info)
		local problem = problem_of(value)

		if problem then
			error(string.format("property %q: %s", info.var_name, problem), 3)
		end
	end

	return check
end

local function range_value(min, max)
	return validator(range_problem, min, max)
end

local function scalar_band(min, max)
	return validator(scalar_band_problem, min, max)
end

local function color_band()
	return validator(color_band_problem)
end

particle_emitter.common = {
	{"Visible", true, boolean, "Emission"},
	{"Playing", true, boolean, "Emission"},
	{"Rate", 50, ranged(0, 5000), "Emission"},
	{"Loop", true, boolean, "Emission"},
	{"Duration", 5, ranged(0, 3600), "Emission"},
	{"Seed", 1, integer, "Emission"},
	{"Shape", "point", particle_emitter.SHAPES, "Shape"},
	{"ShapeSize", Vec3(1, 1, 1), nil, "Shape"},
	{"Spread", 20, ranged(0, 180), "Shape"},
	{"Lifetime", {1, 2}, range_value(0.01, 60), "Motion", "range"},
	{"Speed", {1, 3}, range_value(0, 100), "Motion", "range"},
	{"InheritVelocity", 0, ranged(0, 1), "Motion"},
	{"GravityScale", 1, range_value(-5, 5), "Motion", "range"},
	{"Drag", 0.1, range_value(0, 20), "Motion", "range"},
	{"Size", 0.05, scalar_band(0, 10), "Look", "band"},
	{"OnHit", "bounce", particle_emitter.ON_HIT, "Collision"},
	{"Restitution", 0.5, ranged(0, 1), "Collision"},
	{"Friction", 0.2, ranged(0, 1), "Collision"},
}
particle_emitter.gpu = {
	{
		"MaxParticles",
		1000,
		{validate = "integer", min = 1, max = particle_emitter.GPU_MAX_PARTICLES},
		"Emission",
	},
	{
		"Color",
		{Keys = {{0, Color(1, 1, 1, 1)}, {1, Color(1, 1, 1, 0)}}},
		color_band(),
		"Look",
		"color_band",
	},
	{"Lit", true, boolean, "Look"},
	{"Emissive", 0, scalar_band(0, 1e7), "Look", "band"},
	{"ExposureCompensation", 0, ranged(0, 2), "Look"},
	{"Fizzle", 0, ranged(0, 50), "Motion"},
	{"FizzleStart", 0.6, ranged(0, 1), "Motion"},
	{"Flow", 0, ranged(0, 50), "Motion"},
	{"FlowScale", 0.28, ranged(0.01, 20), "Motion"},
	{"Sparkle", 0, ranged(0, 1), "Look"},
	{"SaturationJitter", 0, ranged(0, 1), "Look"},
	{"Shader", "glow", nil, "Look"},
	{"ShaderParams", nil, nil, "Look"},
	{"RatePerMeter", 0, ranged(0, 10000), "Emission"},
	{"FlipbookFps", 0, ranged(0, 120), "Look"},
	{"FlipbookRandomStart", false, boolean, "Look"},
	{"Flatten", 0, ranged(0, 1), "Shape"},
	{"Stretch", 0, ranged(0, 2), "Look"},
	{"Spin", 0, range_value(-720, 720), "Look", "range"},
	{"Collision", "none", particle_emitter.GPU_COLLISIONS, "Collision"},
}
particle_emitter.cpu = {
	{
		"MaxParticles",
		100,
		{validate = "integer", min = 1, max = particle_emitter.CPU_MAX_PARTICLES},
		"Emission",
	},
	{"Mesh", "quad", particle_emitter.MESHES, "Look"},
	{"Material", nil, {type = "render3d_material"}, "Look"},
	{"Spin", 0, range_value(-720, 720), "Motion", "range"},
	{"FreezeAfter", 0, ranged(0, 60), "Motion"},
	{"SwayAmount", 0, ranged(0, 10), "Motion"},
	{"SwayRate", 1, ranged(0, 20), "Motion"},
	{"RockAngle", 0, ranged(0, 180), "Motion"},
	{"Collision", "none", particle_emitter.CPU_COLLISIONS, "Collision"},
}

do
	local defaults

	function particle_emitter.GetDefault(name)
		if not defaults then
			defaults = {}

			for _, properties in ipairs{particle_emitter.common, particle_emitter.gpu, particle_emitter.cpu} do
				for _, entry in ipairs(properties) do
					defaults[entry[1]] = defaults[entry[1]] or entry[2]
				end
			end
		end

		return defaults[name]
	end
end

do
	local known

	function particle_emitter.CheckProperties(properties)
		if not known then
			known = {}

			for _, list in ipairs{particle_emitter.common, particle_emitter.gpu} do
				for _, entry in ipairs(list) do
					known[entry[1]] = entry
				end
			end
		end

		for name, value in pairs(properties) do
			local entry = known[name] or error("unknown gpu emitter property " .. tostring(name), 0)
			local check = entry[3]

			if type(check) == "table" and not check.validate then
				if not table.has_value(check, value) then
					error(
						(
							"%s: expected one of %s, got %s"
						):format(name, table.concat(check, ", "), tostring(value)),
						0
					)
				end
			elseif type(check) == "table" and check.validate == "integer" then
				if type(value) ~= "number" or value % 1 ~= 0 then
					error(("%s: expected an integer, got %s"):format(name, tostring(value)), 0)
				end

				if value < check.min or value > check.max then
					error(("%s: expected %d to %d, got %d"):format(name, check.min, check.max, value), 0)
				end
			elseif type(check) == "table" and check.validate == "number" then
				if type(value) ~= "number" then
					error(("%s: expected a number, got %s"):format(name, tostring(value)), 0)
				end
			elseif type(check) == "table" and check.validate == "boolean" then
				if type(value) ~= "boolean" then
					error(("%s: expected true or false, got %s"):format(name, tostring(value)), 0)
				end
			elseif type(check) == "table" and check.problem then
				local problem = check.problem(value)

				if problem then error(name .. ": " .. problem, 0) end
			end
		end
	end
end

function particle_emitter.GetRange(value)
	if type(value) == "number" then return value, value end

	return math.min(value[1], value[2]), math.max(value[1], value[2])
end

local function map_keys(keys, map)
	local mapped = {}

	for i, key in ipairs(keys) do
		mapped[i] = {key[1], map(key[2]), key[3]}
	end

	return mapped
end

local function map_curve(value, map)
	return {
		Keys = map_keys(value.Keys, map),
		MaxKeys = value.MaxKeys and map_keys(value.MaxKeys, map),
	}
end

function particle_emitter.ScaleRange(value, factor)
	if type(value) == "number" then return value * factor end

	if value.Keys then
		return map_curve(value, function(v)
			return v * factor
		end)
	end

	return {value[1] * factor, value[2] * factor}
end

function particle_emitter.AddRange(value, amount)
	if type(value) == "number" then return value + amount end

	if value.Keys then
		return map_curve(value, function(v)
			return v + amount
		end)
	end

	return {value[1] + amount, value[2] + amount}
end

local function get_channel(color, channel)
	if type(color) == "cdata" then
		if channel == 0 then return color.r end

		if channel == 1 then return color.g end

		if channel == 2 then return color.b end

		return color.a
	end

	return color[channel + 1] or (channel == 3 and 1 or 0)
end

local function fill(out, channels, value)
	for i = 0, SAMPLES - 1 do
		if channels == 1 then
			out[i] = value
		else
			for c = 0, channels - 1 do
				out[i * channels + c] = get_channel(value, c)
			end
		end
	end
end

local function bake_keys(keys, out, channels)
	for i = 0, SAMPLES - 1 do
		local from, to, fraction = curve.Segment(keys, i / (SAMPLES - 1))

		for c = 0, channels - 1 do
			local a = channels == 1 and from[2] or get_channel(from[2], c)
			local b = channels == 1 and to[2] or get_channel(to[2], c)
			out[i * channels + c] = a + (b - a) * fraction
		end
	end
end

function particle_emitter.BakeScalar(value, low, high)
	if type(value) == "number" then
		fill(low, 1, value)
		fill(high, 1, value)
	elseif value.Keys then
		bake_keys(value.Keys, low, 1)
		bake_keys(value.MaxKeys or value.Keys, high, 1)
	else
		local min, max = particle_emitter.GetRange(value)
		fill(low, 1, min)
		fill(high, 1, max)
	end
end

function particle_emitter.BakeColor(value, low, high)
	if is_color(value) then
		fill(low, 4, value)
		fill(high, 4, value)
	elseif value.Keys then
		bake_keys(value.Keys, low, 4)
		bake_keys(value.MaxKeys or value.Keys, high, 4)
	else
		fill(low, 4, value[1])
		fill(high, 4, value[2])
	end
end

function particle_emitter.SampleBaked(low, high, t, random)
	local x = math.clamp(t, 0, 1) * (SAMPLES - 1)
	local i = math.min(math.floor(x), SAMPLES - 2)
	local f = x - i
	local a = low[i] + (low[i + 1] - low[i]) * f
	return a + (high[i] + (high[i + 1] - high[i]) * f - a) * random
end

local function with_rgb(color, tint)
	return Color(tint.r, tint.g, tint.b, get_channel(color, 3))
end

local function tint_keys(keys, tint, which)
	local tinted = {}

	for i, key in ipairs(keys) do
		local hit = which == "set" or
			(
				which == "set_first" and
				i == 1
			)
			or
			(
				which == "set_last" and
				i == #keys
			)
		tinted[i] = {key[1], hit and with_rgb(key[2], tint) or key[2], key[3]}
	end

	return tinted
end

function particle_emitter.TintColor(current, tint, which)
	if is_color(current) then
		local tinted = with_rgb(current, tint)

		if which == "set" then return tinted end

		return {
			Keys = {
				{0, which == "set_first" and tinted or current},
				{1, which == "set_last" and tinted or current},
			},
		}
	end

	if current.Keys then
		return {
			Keys = tint_keys(current.Keys, tint, which),
			MaxKeys = current.MaxKeys and tint_keys(current.MaxKeys, tint, which),
		}
	end

	local first, last = current[1], current[2]

	if which ~= "set_last" then first = with_rgb(first, tint) end

	if which ~= "set_first" then last = with_rgb(last, tint) end

	return {first, last}
end

function particle_emitter.Add(emitter, backend)
	emitter.particle_backend = backend
	emitter.particle_state = {
		time = 0,
		carry = 0,
		burst = 0,
		queue = {},
		queue_head = 1,
		queue_tail = 1,
		position = Vec3(),
		previous = Vec3(),
		moved = 0,
		path_carry = 0,
		axis = Vec3(0, 1, 0),
		velocity = Vec3(),
	}
	list.insert(particle_emitter.instances, emitter)
end

function particle_emitter.Remove(emitter)
	emitter.particle_removed = true
	list.remove_value(particle_emitter.instances, emitter)
end

function particle_emitter.IsShown(emitter)
	return emitter.Visible and not emitter.Owner.visibility_hidden
end

function particle_emitter.Burst(emitter, count)
	emitter.particle_state.burst = emitter.particle_state.burst + count
end

function particle_emitter.BurstAt(emitter, count, position, direction)
	local state = emitter.particle_state
	local queue = state.queue
	local tail = state.queue_tail
	queue[tail] = count
	queue[tail + 1] = position.x
	queue[tail + 2] = position.y
	queue[tail + 3] = position.z
	queue[tail + 4] = direction.x
	queue[tail + 5] = direction.y
	queue[tail + 6] = direction.z
	state.queue_tail = tail + 7
end

function particle_emitter.Restart(emitter)
	local state = emitter.particle_state
	state.time = 0
	state.carry = 0
end

function particle_emitter.Step(emitter, dt)
	local state = emitter.particle_state
	local count = state.burst
	state.burst = 0

	if emitter.Playing then
		if emitter.Loop or state.time <= emitter.Duration then
			state.carry = state.carry + emitter.Rate * dt
			local whole = math.floor(state.carry)
			state.carry = state.carry - whole
			count = count + whole
		end
	end

	return math.min(count, emitter.MaxParticles)
end

function particle_emitter.Sample(emitter, dt)
	local state = emitter.particle_state

		state.time = state.time + dt

	if state.queue_head < state.queue_tail then
		local queue = state.queue
		local head = state.queue_head
		state.burst = state.burst + queue[head]
		state.position:Set(queue[head + 1], queue[head + 2], queue[head + 3])
		state.axis:Set(queue[head + 4], queue[head + 5], queue[head + 6])
		state.velocity:Set(0, 0, 0)
		state.moved = 0
		state.sampled = false
		head = head + 7
		state.queue_head = head

		if head == state.queue_tail then state.queue_head, state.queue_tail = 1, 1 end

		return state
	end

	local matrix = emitter.Owner.transform:GetWorldMatrix()
	local x, y, z = matrix:GetTranslation()
	local position = state.position

	if dt > 0 and state.sampled then
		state.velocity.x = (x - position.x) / dt
		state.velocity.y = (y - position.y) / dt
		state.velocity.z = (z - position.z) / dt
	end

	local previous = state.previous

	if state.sampled then
		previous.x, previous.y, previous.z = position.x, position.y, position.z
	else
		previous.x, previous.y, previous.z = x, y, z
	end

	state.moved = math.sqrt((x - previous.x) ^ 2 + (y - previous.y) ^ 2 + (z - previous.z) ^ 2)
	state.sampled = true
	position.x, position.y, position.z = x, y, z
	local length = math.sqrt(matrix.m10 ^ 2 + matrix.m11 ^ 2 + matrix.m12 ^ 2)
	state.axis.x, state.axis.y, state.axis.z = matrix.m10 / length, matrix.m11 / length, matrix.m12 / length
	return state
end

return particle_emitter
