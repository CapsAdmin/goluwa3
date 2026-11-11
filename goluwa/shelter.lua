local physics = import("goluwa/physics.lua")
local system = import("goluwa/system.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local shelter = {}
shelter.CELL = 1
shelter.LIFETIME = 0.5
shelter.MAX_ENTRIES = 4096
shelter.DIRECTION_STEP = math.rad(10)
local PATTERN = {
	{0, 0, 0.3},
	{0.2, 0, 0.12},
	{-0.2, 0, 0.12},
	{0, 0.25, 0.12},
	{0, -0.12, 0.1},
	{0.4, 0.12, 0.08},
	{-0.4, 0.12, 0.08},
	{0.4, -0.05, 0.04},
	{-0.4, -0.05, 0.04},
}
local WEIGHT_SUM = 0

for _, ray in ipairs(PATTERN) do
	WEIGHT_SUM = WEIGHT_SUM + ray[3]
end

local OPTIONS = {IncludeRigidBodies = true}
local cache = {}
local count = 0
local UP = Vec3(0, 1, 0)

function shelter.Clear()
	cache = {}
	count = 0
end

local function direction_key(direction)
	local step = shelter.DIRECTION_STEP
	local azimuth = math.floor(math.atan2(direction.z, direction.x) / step + 0.5)
	local elevation = math.floor(math.asin(math.clamp(direction.y, -1, 1)) / step + 0.5)
	return azimuth * 64 + elevation
end

function shelter.Get(position, direction, range, ignore_entity)
	local cell = shelter.CELL
	local key = string.format(
		"%d,%d,%d,%d,%d",
		math.floor(position.x / cell),
		math.floor(position.y / cell),
		math.floor(position.z / cell),
		direction_key(direction),
		range
	)
	local now = system.GetElapsedTime()
	local entry = cache[key]

	if entry and now - entry.time < shelter.LIFETIME then return entry.value end

	local side = direction:GetCross(UP)

	if side:GetLengthSquared() < 0.0001 then
		side = Vec3(1, 0, 0)
	else
		side = side:GetNormalized()
	end

	local lift = side:GetCross(direction)
	local blocked = 0

	for i = 1, #PATTERN do
		local ray = PATTERN[i]
		local aimed = (direction + side * ray[1] + lift * ray[2]):GetNormalized()
		local hit = physics.RayCast(position, aimed, range, ignore_entity, nil, OPTIONS)

		if hit then
			blocked = blocked + ray[3] * (1 - math.min(hit.distance / range, 1))
		end
	end

	local value = blocked / WEIGHT_SUM

	if not entry then
		count = count + 1

		if count > shelter.MAX_ENTRIES then
			cache = {}
			count = 1
		end
	end

	cache[key] = {value = value, time = now}
	return value
end

function shelter.GetAgainst(position, air_velocity, range, ignore_entity)
	local speed = air_velocity:GetLength()

	if speed < 0.01 then return 0 end

	return shelter.Get(position, air_velocity * (-1 / speed), range, ignore_entity)
end

return shelter
