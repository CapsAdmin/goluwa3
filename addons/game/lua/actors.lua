local Vec3 = import("goluwa/structs/vec3.lua")
local Health = import("lua/components/health.lua")
local actors = {}

function actors.IsAlive(entity)
	return entity:IsValid() and entity.health ~= nil and not entity.health:IsDead()
end

function actors.GetCenter(entity)
	local body = entity.rigid_body

	if body then return body:GetPosition() end

	return entity.transform:GetPosition()
end

function actors.GetForward(entity)
	local forward = entity.transform:GetRotation():GetForward()
	return Vec3(forward.x, 0, forward.z):GetNormalized()
end

function actors.GetRight(entity)
	local right = entity.transform:GetRotation():GetRight()
	return Vec3(right.x, 0, right.z):GetNormalized()
end

function actors.Find(position, radius, ignore)
	local found = {}

	for _, health in ipairs(Health.Instances) do
		local entity = health.Owner

		if
			entity ~= ignore and
			not health:IsDead()
			and
			entity.transform and
			(
				actors.GetCenter(entity) - position
			):GetLength() < radius
		then
			found[#found + 1] = entity
		end
	end

	return found
end

return actors
