local event = import("goluwa/event.lua")
local list = import("goluwa/list.lua")
local system = import("goluwa/system.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local particle_emitter = {}
particle_emitter.GPU_MAX_PARTICLES = 16384
particle_emitter.CPU_MAX_PARTICLES = 4096
particle_emitter.instances = {}
particle_emitter.SHAPES = {"point", "sphere", "cone", "box", "disc"}
particle_emitter.GPU_COLLISIONS = {"none", "shelter_map", "scene_depth", "rays"}
particle_emitter.CPU_COLLISIONS = {"none", "rays"}
particle_emitter.ON_HIT = {"bounce", "stick", "kill"}
particle_emitter.MESHES = {"quad", "sphere", "cube", "shard", "feather"}
local number = {validate = "number"}
local integer = {validate = "integer"}
local boolean = {validate = "boolean"}

local function ranged(min, max)
	return {validate = "number", min = min, max = max}
end

local function validate_range(value, info)
	if type(value) == "number" then return end

	if
		type(value) == "table" and
		type(value[1]) == "number" and
		type(value[2]) == "number"
	then
		return
	end

	error(string.format("property %q: expected a number or {min, max}", info.var_name), 3)
end

local function range_value(min, max)
	return {validate = validate_range, min = min, max = max, type = "nil"}
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
	{"SizeStart", 0.05, range_value(0.001, 10), "Look", "range"},
	{"SizeEnd", 0.05, range_value(0, 10), "Look", "range"},
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
	{"ColorStart", Color(1, 1, 1, 1), nil, "Look"},
	{"ColorEnd", Color(1, 1, 1, 0), nil, "Look"},
	{"Lit", true, boolean, "Look"},
	{"Emissive", 0, ranged(0, 1e7), "Look"},
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
			elseif type(check) == "table" and entry[5] == "range" then
				if
					type(value) ~= "number" and
					not (
						type(value) == "table" and
						type(value[1]) == "number" and
						type(value[2]) == "number"
					)
				then
					error(("%s: expected a number or {min, max}, got %s"):format(name, tostring(value)), 0)
				end
			end
		end
	end
end

function particle_emitter.GetRange(value)
	if type(value) == "number" then return value, value end

	return math.min(value[1], value[2]), math.max(value[1], value[2])
end

function particle_emitter.ScaleRange(value, factor)
	if type(value) == "number" then return value * factor end

	return {value[1] * factor, value[2] * factor}
end

function particle_emitter.AddRange(value, amount)
	if type(value) == "number" then return value + amount end

	return {value[1] + amount, value[2] + amount}
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
		state.time = state.time + dt

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
