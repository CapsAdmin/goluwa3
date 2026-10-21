local objects = import("goluwa/objects/objects.lua")
local particle_emitter = import("goluwa/render3d/particle_emitter.lua")
local ParticleEmitter = objects.CreateTemplate("particle_emitter")
ParticleEmitter:StartStorable()

for _, property in ipairs(particle_emitter.common) do
	ParticleEmitter:GetSet(property[1], property[2], property[3])
end

ParticleEmitter:EndStorable()

function ParticleEmitter:OnCreate()
	particle_emitter.Add(self, self.ParticleBackend)
end

function ParticleEmitter:OnRemove()
	particle_emitter.Remove(self)
end

function ParticleEmitter:Burst(count)
	particle_emitter.Burst(self, count)
end

function ParticleEmitter:Restart()
	particle_emitter.Restart(self)
end

return ParticleEmitter:Register()
