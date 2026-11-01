local Vec3 = import("goluwa/structs/vec3.lua")
local RigidBody = import("goluwa/physics/rigid_body.lua")
local orientation = import("goluwa/render3d/orientation.lua")
local raycast = RENDER_3D and import("goluwa/render3d/raycast.lua")
local U = import("goluwa/source_engine/units.lua").meters
local FORWARD = orientation.FORWARD_VECTOR
local RIGHT = orientation.RIGHT_VECTOR
local MAX_DISTANCE = 800 * U
local DEAD_HOLD = 2
local targeting = {}
local target
local dead_time = 0

local function is_not_owner(entity, owner)
	return entity ~= owner and not entity:ContainsParent(owner)
end

local function is_valid_target(body, owner)
	local entity = body.Owner
	return entity ~= owner and
		not body.TraceOwner and
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
	dead_time = 0
end

function targeting.Clear()
	target = nil
end

local function get_visible_offset(body, owner, from)
	if not is_valid_target(body, owner) then return end

	local to_body = body:GetPosition() - from
	local distance = to_body:GetLength()

	if distance >= MAX_DISTANCE or distance <= 1e-4 then return end

	local hit = raycast.CastClosestUnskinned(from, to_body / distance, distance, is_not_owner, owner)

	if not hit or hit.entity == body.Owner then return to_body end
end

function targeting.Find(owner, from, camera_rotation)
	local forward = camera_rotation:VecMul(FORWARD)
	local right = camera_rotation:VecMul(RIGHT)
	local found = {}

	for _, body in ipairs(RigidBody.Instances) do
		local to_body = get_visible_offset(body, owner, from)

		if to_body then
			found[#found + 1] = {
				body = body,
				angle = math.atan2(to_body:Dot(right), to_body:Dot(forward)),
			}
		end
	end

	table.sort(found, by_angle)
	return found
end

function targeting.HasAny(owner, from)
	for _, body in ipairs(RigidBody.Instances) do
		if get_visible_offset(body, owner, from) then return true end
	end

	return false
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

function targeting.Validate(owner, from, dt)
	if not target then return end

	if not target:IsValid() then
		target = nil
		return
	end

	local health = target.Owner.health

	if health and health:IsDead() then
		dead_time = dead_time + dt

		if dead_time > DEAD_HOLD or targeting.HasAny(owner, from) then
			target = nil
		end

		return
	end

	dead_time = 0

	if
		not is_valid_target(target, owner) or
		(
			target:GetPosition() - from
		):GetLength() > MAX_DISTANCE
	then
		target = nil
	end
end

return targeting
