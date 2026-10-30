local objects = import("goluwa/objects/objects.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local system = import("goluwa/system.lua")
local event = import("goluwa/event.lua")
local use = import("goluwa/entities/use.lua")
local META = objects.CreateTemplate("usable")
META:StartStorable()
META:GetSet("Prompt", "use")
META:IsSet("Enabled", true)
META:EndStorable()
META.last_use = -math.huge

function META:OnUse(user, hit)
	if not self.Enabled then return end

	self.last_use = system.GetElapsedTime()
	return self.Owner:CallLocalEvent("OnUsed", user, hit) == true
end

local function find_usable(entity)
	local current = entity

	while current:IsValid() do
		local usable = current.usable

		if usable and usable.Enabled then return usable end

		current = current:GetParent()
	end
end

do
	local MIN_ALIGNMENT = 0.5
	local DISTANCE_WEIGHT = 0.25
	local FALLBACK_DISTANCE_MULT = 1.5
	local fallback_hit = {entity = NULL, point = Vec3(), distance = 0}

	event.AddListener("FindUseFallback", "usable", function(user, origin, direction, hit)
		if hit and find_usable(hit.entity) then return end

		local max_distance = use.MaxDistance * FALLBACK_DISTANCE_MULT
		local best, best_score, best_distance, best_x, best_y, best_z

		for _, usable in ipairs(META.Instances) do
			local owner = usable.Owner

			if usable.Enabled and owner ~= user and not owner:ContainsParent(user) then
				local x, y, z = owner.transform:GetWorldMatrix():GetTranslation()
				x, y, z = x - origin.x, y - origin.y, z - origin.z
				local distance = math.sqrt(x * x + y * y + z * z)

				if distance > 0 and distance <= max_distance then
					local alignment = (x * direction.x + y * direction.y + z * direction.z) / distance

					if alignment >= MIN_ALIGNMENT then
						local score = (1 - alignment) + distance / max_distance * DISTANCE_WEIGHT

						if not best_score or score < best_score then
							best, best_score, best_distance = usable, score, distance
							best_x, best_y, best_z = x, y, z
						end
					end
				end
			end
		end

		if not best then return end

		fallback_hit.entity = best.Owner
		fallback_hit.point:Set(origin.x + best_x, origin.y + best_y, origin.z + best_z)
		fallback_hit.distance = best_distance
		return fallback_hit
	end)
end

function META.Find(user)
	local movement = user.character_movement
	local hit = use.Find(
		user,
		user.transform:GetPosition() + movement:GetViewOffset(),
		movement:GetCommand().aim:GetForward()
	)

	if not hit then return end

	local usable = find_usable(hit.entity)

	if usable then return usable, hit end
end

return META:Register()
