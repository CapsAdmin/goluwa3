local objects = import("goluwa/objects/objects.lua")
local ParticleEmitter = import("goluwa/entities/components/particle_emitter.lua")
local particle_emitter = import("goluwa/render3d/particle_emitter.lua")
-- the simulation and the queue run from events
import("goluwa/render3d/particle_emitter_cpu.lua")
-- a particle emitter simulated in lua: hundreds of particles, every one an instance of a mesh with a material in the
-- gbuffer, lit by the scene like a model, with fog, AO and TAA. Its Material is what it looks like (a quad that faces the
-- camera, a sphere or a cube), they spin, and collide with rays. They do
-- not cast shadows and are not in the bvh or DDGI
local CPUEmitter = objects.CreateTemplate("particle_emitter_cpu")
CPUEmitter.Base = ParticleEmitter
CPUEmitter.ParticleBackend = "cpu"
CPUEmitter:StartStorable()

for _, property in ipairs(particle_emitter.cpu) do
	CPUEmitter:GetSet(property[1], property[2], property[3])
end

CPUEmitter:EndStorable()
return CPUEmitter:Register()
