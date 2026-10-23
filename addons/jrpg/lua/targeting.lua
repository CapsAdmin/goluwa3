local Vec3 = import("goluwa/structs/vec3.lua")
local RigidBody = import("goluwa/physics/rigid_body.lua")
local orientation = import("goluwa/render3d/orientation.lua")
local raycast = RENDER_3D and import("goluwa/render3d/raycast.lua")
local U = import("goluwa/source_engine/units.lua").meters
local FORWARD = orientation.FORWARD_VECTOR
local RIGHT = orientation.RIGHT_VECTOR
local MAX_DISTANCE = 800 * U
local targeting = {}
local target

local function is_not_owner(entity, owner)
	return entity ~= owner and not entity:ContainsParent(owner)
end

local function is_valid_target(body, owner)
	local entity = body.Owner

	return entity ~= owner and
		not entity.ragdoll_part and
		not body.WorldGeometry and
		not body:IsStatic()
		and
		not entity:ContainsParent(owner)
		and
		not (
			entity.health and
			entity.health:IsDead()
		)
end

local function by_angle(a, b)
	return a.angle < b.angle
end

function targeting.GetMaxDistance()
	return MAX_DISTANCE
end

function targeting.Get()
	if target and not target:IsValid() then target = nil end

	return target
end

function targeting.Set(body)
	target = body
end

function targeting.Clear()
	target = nil
end

function targeting.Find(owner, from, camera_rotation)
	local forward = camera_rotation:VecMul(FORWARD)
	local right = camera_rotation:VecMul(RIGHT)
	local found = {}

	for _, body in ipairs(RigidBody.Instances) do
		if is_valid_target(body, owner) then
			local to_body = body:GetPosition() - from
			local distance = to_body:GetLength()

			if distance < MAX_DISTANCE and distance > 1e-4 then
				local hit = raycast.CastClosest(from, to_body / distance, distance, is_not_owner, owner)

				if not hit or hit.entity == body.Owner then
					found[#found + 1] = {
						body = body,
						angle = math.atan2(to_body:Dot(right), to_body:Dot(forward)),
					}
				end
			end
		end
	end

	table.sort(found, by_angle)

	return found
end

function targeting.Scroll(owner, from, camera_rotation, delta)
	local found = targeting.Find(owner, from, camera_rotation)

	if #found == 0 then return end

	local index

	if target then
		for i, entry in ipairs(found) do
			if entry.body == target then
				index = i

				break
			end
		end
	end

	if index then
		index = (index - 1 + delta) % #found + 1
	else
		local best = math.huge

		for i, entry in ipairs(found) do
			if math.abs(entry.angle) < best then
				best = math.abs(entry.angle)
				index = i
			end
		end
	end

	target = found[index].body
end

function targeting.Toggle(owner, from, camera_rotation)
	if target then
		target = nil
	else
		targeting.Scroll(owner, from, camera_rotation, 0)
	end
end

function targeting.Validate(owner, from)
	if not target then return end

	if
		not target:IsValid() or
		not is_valid_target(target, owner) or
		(
			target:GetPosition() - from
		):GetLength() > MAX_DISTANCE
	then
		target = nil
	end
end

return targeting
