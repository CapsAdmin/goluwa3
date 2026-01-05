-- Example usage of the raycast system
local raycast = require("raycast")
local ecs = require("ecs")
local Vec3 = require("structs.vec3")

-- Example 1: Simple raycast from camera forward
local function raycast_from_camera()
	local render3d = require("render3d.render3d")
	local camera = render3d.GetCamera()
	-- Get camera position and forward direction
	local camera_pos = camera:GetPosition()
	local camera_rot = camera:GetRotation()
	local forward = camera_rot:GetForward()
	-- Cast ray 100 units forward
	local hits = raycast.Cast(camera_pos, forward, 100)

	if #hits > 0 then
		local closest = hits[1]
		logf("Hit entity: %s at distance %.2f\n", tostring(closest.entity), closest.distance)
		logf(
			"Hit position: %.2f, %.2f, %.2f\n",
			closest.position.x,
			closest.position.y,
			closest.position.z
		)
		logf(
			"Hit normal: %.2f, %.2f, %.2f\n",
			closest.normal.x,
			closest.normal.y,
			closest.normal.z
		)
	else
		logn("No hits")
	end

	return hits
end

-- Example 2: Screen space raycast (for mouse picking)
local function raycast_from_screen(screen_x, screen_y)
	local render3d = require("render3d.render3d")
	local camera = render3d.GetCamera()
	-- Convert screen coordinates to world ray
	-- (You'd need to implement UnprojectScreenPoint on camera)
	-- local origin, direction = camera:UnprojectScreenPoint(screen_x, screen_y)
	-- For now, use camera position and direction
	local origin = camera:GetPosition()
	local direction = camera:GetRotation():GetForward()
	-- Cast and return closest hit
	return raycast.CastClosest(origin, direction, 1000)
end

-- Example 3: Filtered raycast (only specific entities)
local function raycast_with_filter()
	local origin = Vec3(0, 1, 0)
	local direction = Vec3(0, -1, 0)
	-- Only test entities with specific name pattern
	local hits = raycast.Cast(
		origin,
		direction,
		100,
		function(entity)
			-- Filter: only test entities whose name contains "prop"
			return entity:GetName():find("prop") ~= nil
		end
	)
	return hits
end

-- Example 4: Line of sight check
local function has_line_of_sight(from_pos, to_pos, max_distance)
	local direction = (to_pos - from_pos):GetNormalized()
	local distance = (to_pos - from_pos):GetLength()

	if distance > max_distance then return false end

	-- Check if anything blocks the path
	return not raycast.CastAny(from_pos, direction, distance)
end

-- Example 5: Ground detection / height finding
local function find_ground_height(x, z, max_distance)
	max_distance = max_distance or 1000
	local origin = Vec3(x, max_distance, z)
	local direction = Vec3(0, -1, 0)
	local hit = raycast.CastClosest(origin, direction, max_distance * 2)

	if hit then return hit.position.y end

	return nil
end

-- Example 6: Multiple rays (cone/spread)
local function raycast_cone(origin, direction, cone_angle, num_rays, max_distance)
	local hits = {}
	local Quat = require("structs.quat")

	for i = 1, num_rays do
		-- Create rotation for this ray within the cone
		local angle = (i / num_rays) * math.pi * 2
		local offset_angle = cone_angle / 2
		-- Rotate direction by cone angle
		local rot = Quat():SetAxisAngle(Vec3(1, 0, 0), offset_angle)
		local rotated_dir = rot:RotateVector(direction)
		-- Cast ray
		local ray_hits = raycast.Cast(origin, rotated_dir, max_distance)

		for _, hit in ipairs(ray_hits) do
			table.insert(hits, hit)
		end
	end

	return hits
end

-- Example 7: Interactive object selection
local function select_object_under_cursor(mouse_x, mouse_y)
	local hit = raycast_from_screen(mouse_x, mouse_y)

	if hit then
		logf("Selected: %s\n", tostring(hit.entity))

		-- You could add an outline component or change material
		if hit.entity:HasComponent("model") then

		-- Example: Change color to indicate selection
		-- hit.entity.model:SetColor(Color(1, 1, 0, 1))
		end

		return hit.entity
	end

	return nil
end

-- Example 8: Collision detection for projectile
local function simulate_projectile(start_pos, velocity, time_step, max_time)
	local Vec3 = require("structs.vec3")
	local gravity = Vec3(0, -9.8, 0)
	local pos = start_pos
	local vel = velocity
	local time = 0

	while time < max_time do
		-- Predict next position
		local next_vel = vel + gravity * time_step
		local next_pos = pos + next_vel * time_step
		-- Cast ray from current to next position
		local direction = (next_pos - pos):GetNormalized()
		local distance = (next_pos - pos):GetLength()
		local hit = raycast.CastClosest(pos, direction, distance)

		if hit then
			logf(
				"Projectile hit %s at %.2f, %.2f, %.2f\n",
				tostring(hit.entity),
				hit.position.x,
				hit.position.y,
				hit.position.z
			)
			return hit
		end

		-- Update for next frame
		pos = next_pos
		vel = next_vel
		time = time + time_step
	end

	return nil
end

return {
	raycast_from_camera = raycast_from_camera,
	raycast_from_screen = raycast_from_screen,
	raycast_with_filter = raycast_with_filter,
	has_line_of_sight = has_line_of_sight,
	find_ground_height = find_ground_height,
	raycast_cone = raycast_cone,
	select_object_under_cursor = select_object_under_cursor,
	simulate_projectile = simulate_projectile,
}
