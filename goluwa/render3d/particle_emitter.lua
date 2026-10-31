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
	{"LifetimeMin", 1, ranged(0.01, 60), "Motion"},
	{"LifetimeMax", 2, ranged(0.01, 60), "Motion"},
	{"SpeedMin", 1, ranged(0, 100), "Motion"},
	{"SpeedMax", 3, ranged(0, 100), "Motion"},
	{"InheritVelocity", 0, ranged(0, 1), "Motion"},
	{"GravityScale", 1, ranged(-5, 5), "Motion"},
	{"Drag", 0.1, ranged(0, 20), "Motion"},
	{"SizeStart", 0.05, ranged(0.001, 10), "Look"},
	{"SizeEnd", 0.05, ranged(0, 10), "Look"},
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
	{"Spin", 0, ranged(-720, 720), "Motion"},
	{"FreezeAfter", 0, ranged(0, 60), "Motion"},
	{"SwayAmount", 0, ranged(0, 10), "Motion"},
	{"SwayRate", 1, ranged(0, 20), "Motion"},
	{"RockAngle", 0, ranged(0, 180), "Motion"},
	{"Collision", "none", particle_emitter.CPU_COLLISIONS, "Collision"},
}

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

	state.sampled = true
	position.x, position.y, position.z = x, y, z
	local length = math.sqrt(matrix.m10 ^ 2 + matrix.m11 ^ 2 + matrix.m12 ^ 2)
	state.axis.x, state.axis.y, state.axis.z = matrix.m10 / length, matrix.m11 / length, matrix.m12 / length
	return state
end

return particle_emitter
