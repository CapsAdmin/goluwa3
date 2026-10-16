local objects = import("goluwa/objects/objects.lua")
local particle_emitter = import("goluwa/render3d/particle_emitter.lua")
-- what the two particle emitters have in common (they extend it, like the lights extend light): the emission, the shape,
-- the motion and the collision response, and Burst and Restart. Particles are thrown along the entity's up, from its
-- position, in world space. Use particle_emitter_gpu or particle_emitter_cpu, see docs/particles.md
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

-- spawns count particles now, on top of the rate
function ParticleEmitter:Burst(count)
	particle_emitter.Burst(self, count)
end

-- starts the duration over
function ParticleEmitter:Restart()
	particle_emitter.Restart(self)
end

return ParticleEmitter:Register()
