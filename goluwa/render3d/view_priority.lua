-- what to build or bake first for a camera: the nearer of where it is and where it will be a moment from now, to the
-- nearest point of a box, counted as farther the further the box is out of view. a tile under the camera that was behind
-- it a moment ago has a distance of 0 and stays first, what is behind it a long way off is last. the terrain's tiles
-- and scatter's units both use it, so that they agree on what matters
local system = import("goluwa/system.lua")
local ViewPriority = {}
ViewPriority.__index = ViewPriority

function ViewPriority.New(config)
	local self = setmetatable({}, ViewPriority)
	config = config or {}
	-- seconds to look ahead along the camera's velocity
	self.PredictSeconds = config.PredictSeconds or 0.5
	-- a box behind the camera counts as 1 + this times as far, the ones to the sides in between
	self.OutsidePenalty = config.OutsidePenalty or 100
	-- seconds that the velocity takes to follow what the camera does
	self.VelocitySeconds = config.VelocitySeconds or 0.07
	self.velocity_x, self.velocity_y, self.velocity_z = 0, 0, 0
	self.position_x, self.position_y, self.position_z = 0, 0, 0
	self.time = nil
	return self
end

-- the horizontal half of what the camera sees, with a margin for turning
function ViewPriority.GetHalfAngle(camera)
	local viewport = camera.Viewport
	return math.atan(math.tan(camera:GetFOV() / 2) * viewport.w / viewport.h) + 0.35
end

-- forward is the camera's forward vector and half_angle comes from GetHalfAngle, call it once for each update
function ViewPriority:Update(position, forward, half_angle)
	local now = system.GetElapsedTime()

	if self.time then
		local dt = math.max(now - self.time, 1e-3)
		local dx, dy, dz = position.x - self.position_x, position.y - self.position_y, position.z - self.position_z

		-- a jump is not a speed
		if dx * dx + dy * dy + dz * dz > 1e6 then
			self.velocity_x, self.velocity_y, self.velocity_z = 0, 0, 0
		else
			local alpha = 1 - math.exp(-dt / self.VelocitySeconds)
			self.velocity_x = self.velocity_x + (dx / dt - self.velocity_x) * alpha
			self.velocity_y = self.velocity_y + (dy / dt - self.velocity_y) * alpha
			self.velocity_z = self.velocity_z + (dz / dt - self.velocity_z) * alpha
		end
	end

	self.time = now
	self.position_x, self.position_y, self.position_z = position.x, position.y, position.z
	self.predicted_x = position.x + self.velocity_x * self.PredictSeconds
	self.predicted_y = position.y + self.velocity_y * self.PredictSeconds
	self.predicted_z = position.z + self.velocity_z * self.PredictSeconds
	local forward_length = math.sqrt(forward.x * forward.x + forward.z * forward.z)
	self.look_x, self.look_z = forward.x / forward_length, forward.z / forward_length
	-- looking mostly down sees everything around
	self.looking_down = forward_length < 0.35
	self.half_angle = half_angle
end

-- a lower number is first. the box is the one of a tile or a unit, y is the range of heights that are in it
function ViewPriority:Rank(min_x, min_y, min_z, max_x, max_y, max_z)
	local q_x, q_y, q_z = self.predicted_x, self.predicted_y, self.predicted_z
	local nearest_x = math.min(math.max(q_x, min_x), max_x)
	local nearest_y = math.min(math.max(q_y, min_y), max_y)
	local nearest_z = math.min(math.max(q_z, min_z), max_z)
	local dx, dy, dz = nearest_x - q_x, nearest_y - q_y, nearest_z - q_z
	local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
	-- what is under the camera now is not less needed than what will be
	local x, y, z = self.position_x, self.position_y, self.position_z
	dx = math.min(math.max(x, min_x), max_x) - x
	dy = math.min(math.max(y, min_y), max_y) - y
	dz = math.min(math.max(z, min_z), max_z) - z
	distance = math.min(distance, math.sqrt(dx * dx + dy * dy + dz * dz))

	if self.looking_down then return distance end

	-- the bearing to the center against the view, a box is as wide as the radius of its footprint
	local center_x = (min_x + max_x) / 2 - q_x
	local center_z = (min_z + max_z) / 2 - q_z
	local center_length = math.sqrt(center_x * center_x + center_z * center_z)
	local radius = math.sqrt((max_x - min_x) ^ 2 + (max_z - min_z) ^ 2) / 2

	if center_length <= radius then return distance end

	local cos = (center_x * self.look_x + center_z * self.look_z) / center_length
	local angle = math.acos(math.min(math.max(cos, -1), 1))
	local outside = math.max(angle - self.half_angle - math.asin(radius / center_length), 0)

	return distance * (1 + outside / math.pi * self.OutsidePenalty)
end

return ViewPriority
