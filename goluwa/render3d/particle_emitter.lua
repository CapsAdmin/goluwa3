local event = import("goluwa/event.lua")
local list = import("goluwa/list.lua")
local system = import("goluwa/system.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
-- what the particle emitter components are made of: their properties, which an editor lists in groups, and what both
-- backends share, how many particles to spawn this frame and where the emitter is. The backends are two components with
-- their own properties, that follow each other where they can and deviate where they have to:
--   particle_emitter_gpu  (particle_emitter_gpu.lua) one gpu system for all of them, simulated and lit in the particles
--                         pass and drawn blended, thousands of particles
--   particle_emitter_cpu  (particle_emitter_cpu.lua) simulated in lua, every particle an instance of a mesh with a material,
--                         drawn into the gbuffer through the instancing path like any model, hundreds
-- both are extensions of the particle_emitter component (the properties of `common` and Burst/Restart). An emitter spawns
-- the number of particles Step gives it every frame, so a rate, bursts and a duration mean the same in both. The
-- emission axis is the entity's up, and it moves with the entity
local particle_emitter = {}
particle_emitter.GPU_MAX_PARTICLES = 16384
particle_emitter.CPU_MAX_PARTICLES = 4096
particle_emitter.instances = {}
particle_emitter.SHAPES = {"point", "sphere", "cone", "box", "disc"}
particle_emitter.GPU_COLLISIONS = {"none", "shelter_map", "scene_depth", "rays"}
particle_emitter.CPU_COLLISIONS = {"none", "rays"}
particle_emitter.ON_HIT = {"bounce", "stick", "kill"}
particle_emitter.MESHES = {"quad", "sphere", "cube"}
local number = {validate = "number"}
local integer = {validate = "integer"}
local boolean = {validate = "boolean"}

local function ranged(min, max)
	return {validate = "number", min = min, max = max}
end

-- {name, default, info, group}, what both kinds have
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
-- the gpu emitter: blended particles, lit by the scene or glowing, thousands. Colors fade over the life, any collision mode
particle_emitter.gpu = {
	{"MaxParticles", 1000, {validate = "integer", min = 1, max = particle_emitter.GPU_MAX_PARTICLES}, "Emission"},
	{"ColorStart", Color(1, 1, 1, 1), nil, "Look"},
	{"ColorEnd", Color(1, 1, 1, 0), nil, "Look"},
	{"Lit", true, boolean, "Look"},
	{"Emissive", 0, ranged(0, 1e7), "Look"},
	{"Collision", "none", particle_emitter.GPU_COLLISIONS, "Collision"},
}
-- the cpu emitter: solid meshes with a material in the gbuffer, hundreds. Spinning, collides with rays
particle_emitter.cpu = {
	{"MaxParticles", 100, {validate = "integer", min = 1, max = particle_emitter.CPU_MAX_PARTICLES}, "Emission"},
	{"Mesh", "quad", particle_emitter.MESHES, "Look"},
	{"Material", nil, {type = "render3d_material"}, "Look"},
	{"Spin", 0, ranged(-720, 720), "Motion"},
	{"Collision", "none", particle_emitter.CPU_COLLISIONS, "Collision"},
}

function particle_emitter.Add(emitter, backend)
	emitter.particle_backend = backend
	emitter.particle_state = {time = 0, carry = 0, burst = 0, position = Vec3(), axis = Vec3(0, 1, 0), velocity = Vec3()}
	list.insert(particle_emitter.instances, emitter)
end

function particle_emitter.Remove(emitter)
	emitter.particle_removed = true
	list.remove_value(particle_emitter.instances, emitter)
end

-- an emitter that is in the scene: Visible, and its entity not hidden (visibility component)
function particle_emitter.IsShown(emitter)
	return emitter.Visible and not emitter.Owner.visibility_hidden
end

function particle_emitter.Burst(emitter, count)
	emitter.particle_state.burst = emitter.particle_state.burst + count
end

-- start the duration over
function particle_emitter.Restart(emitter)
	local state = emitter.particle_state
	state.time = 0
	state.carry = 0
end

-- how many particles it spawns over dt seconds: its rate, while it plays and its duration has not run out (a looping
-- emitter has none), and the bursts asked for
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

-- where the emitter is, the way its particles are thrown (the entity's up) and how fast it moves
function particle_emitter.Sample(emitter, dt)
	local state = emitter.particle_state
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
