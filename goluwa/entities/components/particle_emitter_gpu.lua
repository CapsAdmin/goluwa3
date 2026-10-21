local objects = import("goluwa/objects/objects.lua")
local ParticleEmitter = import("goluwa/entities/components/particle_emitter.lua")
local particle_emitter = import("goluwa/render3d/particle_emitter.lua")
import("goluwa/render3d/particle_emitter_gpu.lua")
local GPUEmitter = objects.CreateTemplate("particle_emitter_gpu")
GPUEmitter.Base = ParticleEmitter
GPUEmitter.ParticleBackend = "gpu"
GPUEmitter:StartStorable()

for _, property in ipairs(particle_emitter.gpu) do
	GPUEmitter:GetSet(property[1], property[2], property[3])
end

GPUEmitter:EndStorable()
return GPUEmitter:Register()
