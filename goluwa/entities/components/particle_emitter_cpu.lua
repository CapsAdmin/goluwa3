local objects = import("goluwa/objects/objects.lua")
local ParticleEmitter = import("goluwa/entities/components/particle_emitter.lua")
local particle_emitter = import("goluwa/render3d/particle_emitter.lua")
import("goluwa/render3d/particle_emitter_cpu.lua")
local CPUEmitter = objects.CreateTemplate("particle_emitter_cpu")
CPUEmitter.Base = ParticleEmitter
CPUEmitter.ParticleBackend = "cpu"
CPUEmitter:StartStorable()

for _, property in ipairs(particle_emitter.cpu) do
	CPUEmitter:StartCategory(property[4])
	CPUEmitter:GetSet(property[1], property[2], property[3])
end

CPUEmitter:EndCategory()
CPUEmitter:EndStorable()
return CPUEmitter:Register()
