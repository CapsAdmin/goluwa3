require("test.environment")
local Matrix44 = require("structs.matrix").Matrix44
local Vec3 = require("structs.vec3")
local Ang3 = require("structs.ang3")

-- Helper to build view matrix from camera position and angles
local function build_view_matrix(cam_pos, cam_ang)
	-- View matrix = Z-flip * inverse rotation * translation(-position)
	-- Pitch is NOT negated - Z-flip handles the direction
	local flip = Matrix44()
	flip:Scale(1, 1, -1) -- Flip Z axis
	local rotation = Matrix44()
	rotation:RotateRoll(-cam_ang.z)
	rotation:RotatePitch(cam_ang.x) -- NOT negated - Z-flip handles it
	rotation:RotateYaw(-cam_ang.y)
	local translation = Matrix44()
	translation:SetTranslation(-cam_pos.x, -cam_pos.y, -cam_pos.z)
	return flip:GetMultiplied(rotation:GetMultiplied(translation))
end

-- Test: Mouse up/down should rotate pitch (look up/down)
test("Mouse up rotates view up (pitch)", function()
	local cam_pos = Vec3(0, 0, 0)
	local cam_ang = Ang3(0, 0, 0) -- Looking forward along +Z
	-- Mouse moved up increases pitch (look up toward +Y)
	local pitch_up = Ang3(math.rad(45), 0, 0)
	local view_matrix = build_view_matrix(cam_pos, pitch_up)
	-- A point above should now be in front (negative view Z)
	local point_above = Vec3(0, 1, 0)
	local vx, vy, vz = view_matrix:TransformVector(point_above.x, point_above.y, point_above.z)
	ok(vz < 0, "Point above should be in front when pitched up: got vz=" .. vz)
end)

test("Mouse down rotates view down (pitch)", function()
	local cam_pos = Vec3(0, 0, 0)
	-- Mouse moved down decreases pitch (look down toward -Y)
	local pitch_down = Ang3(math.rad(-45), 0, 0)
	local view_matrix = build_view_matrix(cam_pos, pitch_down)
	-- A point below should now be in front (negative view Z)
	local point_below = Vec3(0, -1, 0)
	local vx, vy, vz = view_matrix:TransformVector(point_below.x, point_below.y, point_below.z)
	ok(vz < 0, "Point below should be in front when pitched down: got vz=" .. vz)
end)

-- Test: Mouse left/right should rotate yaw (look left/right)
test("Mouse left rotates view left (yaw)", function()
	local cam_pos = Vec3(0, 0, 0)
	-- Mouse moved left increases yaw (look toward -X)
	local yaw_left = Ang3(0, math.rad(90), 0)
	local view_matrix = build_view_matrix(cam_pos, yaw_left)
	-- A point to the left (+X in world) should now be in front
	local point_left = Vec3(1, 0, 0)
	local vx, vy, vz = view_matrix:TransformVector(point_left.x, point_left.y, point_left.z)
	ok(vz < 0, "Point to left should be in front when yawed left: got vz=" .. vz)
end)

test("Mouse right rotates view right (yaw)", function()
	local cam_pos = Vec3(0, 0, 0)
	-- Mouse moved right decreases yaw (look toward +X)
	local yaw_right = Ang3(0, math.rad(-90), 0)
	local view_matrix = build_view_matrix(cam_pos, yaw_right)
	-- A point to the right (-X in world) should now be in front
	local point_right = Vec3(-1, 0, 0)
	local vx, vy, vz = view_matrix:TransformVector(point_right.x, point_right.y, point_right.z)
	ok(vz < 0, "Point to right should be in front when yawed right: got vz=" .. vz)
end)

-- Test: Right mouse button + mouse movement should rotate roll
test("Right mouse left rotates roll clockwise", function()
	local cam_pos = Vec3(0, 0, 0)
	-- Roll right (clockwise from camera POV)
	local roll_cw = Ang3(0, 0, math.rad(45))
	local view_matrix = build_view_matrix(cam_pos, roll_cw)
	-- Point at world +Y (up) should appear tilted to the right in view space
	local world_up = Vec3(0, 1, 0)
	local vx, vy, vz = view_matrix:TransformVector(world_up.x, world_up.y, world_up.z)
	ok(
		vx > 0,
		"World up should tilt right (positive vx) with clockwise roll: got vx=" .. vx
	)
end)

test("Right mouse right rotates roll counter-clockwise", function()
	local cam_pos = Vec3(0, 0, 0)
	-- Roll left (counter-clockwise from camera POV)
	local roll_ccw = Ang3(0, 0, math.rad(-45))
	local view_matrix = build_view_matrix(cam_pos, roll_ccw)
	-- Point at world +Y (up) should appear tilted to the left in view space
	local world_up = Vec3(0, 1, 0)
	local vx, vy, vz = view_matrix:TransformVector(world_up.x, world_up.y, world_up.z)
	ok(
		vx < 0,
		"World up should tilt left (negative vx) with counter-clockwise roll: got vx=" .. vx
	)
end)

-- Test: Translation based on view rotation
test("W moves camera forward along view direction", function()
	local cam_pos = Vec3(0, 0, 0)
	local cam_ang = Ang3(0, 0, 0)
	-- Get forward direction and move camera
	local forward = cam_ang:GetForward()
	local new_pos = cam_pos + forward
	-- Build view matrix at new position
	local view_matrix = build_view_matrix(new_pos, cam_ang)
	-- Original camera position (0,0,0) should now be behind camera (positive view Z)
	local vx, vy, vz = view_matrix:TransformVector(0, 0, 0)
	ok(vz > 0, "Origin should be behind camera after moving forward: got vz=" .. vz)
end)

test("S moves camera backward along view direction", function()
	local cam_pos = Vec3(0, 0, 0)
	local cam_ang = Ang3(0, 0, 0)
	-- Get forward direction and move camera backward
	local forward = cam_ang:GetForward()
	local new_pos = cam_pos - forward
	-- Build view matrix at new position
	local view_matrix = build_view_matrix(new_pos, cam_ang)
	-- Original camera position should now be in front (negative view Z)
	local vx, vy, vz = view_matrix:TransformVector(0, 0, 0)
	ok(vz < 0, "Origin should be in front after moving backward: got vz=" .. vz)
end)

test("A moves camera left (perpendicular to view)", function()
	local cam_pos = Vec3(0, 0, 0)
	local cam_ang = Ang3(0, 0, 0)
	-- Get right direction and move camera left (negative right)
	local right = cam_ang:GetRight()
	local new_pos = cam_pos - right
	-- Build view matrix at new position
	local view_matrix = build_view_matrix(new_pos, cam_ang)
	-- Origin should be to the right in view space (positive view X)
	local vx, vy, vz = view_matrix:TransformVector(0, 0, 0)
	ok(vx > 0, "Origin should be to right after moving left: got vx=" .. vx)
end)

test("D moves camera right (perpendicular to view)", function()
	local cam_pos = Vec3(0, 0, 0)
	local cam_ang = Ang3(0, 0, 0)
	-- Get right direction and move camera right
	local right = cam_ang:GetRight()
	local new_pos = cam_pos + right
	-- Build view matrix at new position
	local view_matrix = build_view_matrix(new_pos, cam_ang)
	-- Origin should be to the left in view space (negative view X)
	local vx, vy, vz = view_matrix:TransformVector(0, 0, 0)
	ok(vx < 0, "Origin should be to left after moving right: got vx=" .. vx)
end)

test("Z moves camera up along view's up direction", function()
	local cam_pos = Vec3(0, 0, 0)
	local cam_ang = Ang3(0, 0, 0)
	-- Get up direction and move camera up
	local up = cam_ang:GetUp()
	local new_pos = cam_pos + up
	-- Build view matrix at new position
	local view_matrix = build_view_matrix(new_pos, cam_ang)
	-- Origin should be below in view space (negative view Y)
	local vx, vy, vz = view_matrix:TransformVector(0, 0, 0)
	ok(vy < 0, "Origin should be below after moving up: got vy=" .. vy)
end)

test("X moves camera down along view's up direction", function()
	local cam_pos = Vec3(0, 0, 0)
	local cam_ang = Ang3(0, 0, 0)
	-- Get up direction and move camera down (negative up)
	local up = cam_ang:GetUp()
	local new_pos = cam_pos - up
	-- Build view matrix at new position
	local view_matrix = build_view_matrix(new_pos, cam_ang)
	-- Origin should be above in view space (positive view Y)
	local vx, vy, vz = view_matrix:TransformVector(0, 0, 0)
	ok(vy > 0, "Origin should be above after moving down: got vy=" .. vy)
end)

-- Test: Z movement when looking down (pitch -90°)
test("Z moves along floor when looking straight down", function()
	local cam_pos = Vec3(0, 5, 0) -- 5 units above floor
	local cam_ang = Ang3(math.rad(-90), 0, 0) -- Looking straight down
	-- Get "up" direction from camera's perspective (which points along floor when looking down)
	local cam_up = cam_ang:GetUp()
	-- Move "up" from camera perspective
	local new_pos = cam_pos + cam_up
	-- The Y component should stay the same (moving along floor, not toward/away from it)
	-- The Z component should change (moving horizontally)
	ok(
		math.abs(new_pos.y - cam_pos.y) < 0.1,
		"Moving 'up' when looking down should move along floor (Y unchanged): got y=" .. new_pos.y
	)
	ok(
		math.abs(new_pos.z - cam_pos.z) > 0.9,
		"Moving 'up' when looking down should move horizontally: got z=" .. new_pos.z
	)
end)

-- Test: Movement when upside down (roll 180°)
test("Forward movement works when camera is upside down", function()
	local cam_pos = Vec3(0, 0, 0)
	local cam_ang = Ang3(0, 0, math.rad(180)) -- Rolled upside down
	-- Get forward direction (should still point in forward direction)
	local forward = cam_ang:GetForward()
	local new_pos = cam_pos + forward
	-- Should still move along Z axis
	ok(
		new_pos.z > cam_pos.z,
		"Should move forward along Z even when upside down: got z=" .. new_pos.z
	)
end)
