local event = import("goluwa/event.lua")
local physics = import("goluwa/physics.lua")
local impacts = {}

function impacts.Fire(entity, part, kind, hit, speed)
	local material = physics.GetHitMaterial(hit)
	event.Call(
		"Impact",
		{
			Entity = entity,
			Part = part,
			Kind = kind,
			Surface = material and material:GetSurfaceType() or "default",
			Material = material,
			Other = hit.entity,
			Position = hit.position,
			Normal = hit.normal,
			Speed = speed,
		}
	)
end

function impacts.FireFootstep(character, part, hit, speed)
	local ragdoll = character.ragdoll

	if ragdoll and ragdoll:HasLimp() then return end

	impacts.Fire(character, part, "footstep", hit, speed)
end

return impacts
