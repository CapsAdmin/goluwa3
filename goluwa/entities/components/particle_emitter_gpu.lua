local objects = import("goluwa/objects/objects.lua")
local ParticleEmitter = import("goluwa/entities/components/particle_emitter.lua")
local particle_emitter = import("goluwa/render3d/particle_emitter.lua")
import("goluwa/render3d/particle_emitter_gpu.lua")
-- a particle emitter simulated on the gpu: thousands of particles, drawn blended in the translucent passes and lit by the
-- scene (the sun with its shadows, local lights, DDGI or the sky) or glowing (Lit off, Emissive). Colors fade over the
-- life, and they collide with the shelter map (the depth of the world from above), the scene depth (what the view sees)
-- or rays through the scene
local GPUEmitter = objects.CreateTemplate("particle_emitter_gpu")
GPUEmitter.Base = ParticleEmitter
GPUEmitter.ParticleBackend = "gpu"
GPUEmitter:StartStorable()

for _, property in ipairs(particle_emitter.gpu) do
	GPUEmitter:GetSet(property[1], property[2], property[3])
end

GPUEmitter:EndStorable()
return GPUEmitter:Register()
