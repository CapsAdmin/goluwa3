local objects = import("goluwa/objects/objects.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local CLEARANCE = 0.02
local SpawnPoint = objects.CreateTemplate("spawn_point")
SpawnPoint.instances = {}
SpawnPoint:StartStorable()
SpawnPoint:GetSet("Group", "")
SpawnPoint:GetSet("Enabled", true)
SpawnPoint:EndStorable()

function SpawnPoint:OnCreate()
	list.insert(SpawnPoint.instances, self)
end

function SpawnPoint:OnRemove()
	for i, other in ipairs(SpawnPoint.instances) do
		if other == self then
			list.remove(SpawnPoint.instances, i)

			break
		end
	end
end

-- a spawn point sits on the ground, this is the position a given height above it, and the way the spawn point faces
function SpawnPoint:GetPlacement(height)
	local transform = self.Owner.transform
	return transform:GetPosition() + Vec3(0, height + CLEARANCE, 0),
	transform:GetRotation():Copy()
end

function SpawnPoint.GetInstances()
	return SpawnPoint.instances
end

-- spawn points of the first group that has any enabled one, or every enabled one when no group is given
function SpawnPoint.Find(...)
	local found = {}
	local group_count = select("#", ...)

	for i = 1, math.max(group_count, 1) do
		local group = select(i, ...)

		for _, spawn in ipairs(SpawnPoint.instances) do
			if spawn.Enabled and (group == nil or spawn.Group == group) then
				found[#found + 1] = spawn
			end
		end

		if found[1] then break end
	end

	return found
end

function SpawnPoint.Pick(...)
	local found = SpawnPoint.Find(...)

	if found[1] then return found[math.random(#found)] end
end

return SpawnPoint:Register()
