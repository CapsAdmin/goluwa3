local vk = require("bindings.vk")

if not pcall(vk.find_library) then
	print("Vulkan library not available, skipping camera tests.")
	return
end

local T = require("test.environment")
local ffi = require("ffi")
local render = require("graphics.render")
local render3d = require("graphics.render3d")
local Polygon3D = require("graphics.polygon_3d")
local Material = require("graphics.material")
local Texture = require("graphics.texture")
local Vec3 = require("structs.vec3")
local Vec2 = require("structs.vec2")
local Rect = require("structs.rect")
local Quat = require("structs.quat")
local Ang3 = require("structs.ang3")
local Matrix44 = require("structs.matrix").Matrix44
local orientation = require("orientation")
local png_encode = require("file_formats.png.encode")
local fs = require("fs")
local width = 512
local height = 512
local initialized = false

local function save_screenshot(name)
	local image_data = render.CopyImageToCPU(render.target.image, width, height, "r8g8b8a8_unorm")
	local png = png_encode(width, height, "rgba")
	local pixel_table = {}

	for i = 0, image_data.size - 1 do
		pixel_table[i + 1] = image_data.pixels[i]
	end

	png:write(pixel_table)
	local png_data = png:getData()
	local screenshot_dir = "./logs/screenshots"
	fs.create_directory_recursive(screenshot_dir)
	local screenshot_path = screenshot_dir .. "/" .. name .. ".png"
	local file = assert(io.open(screenshot_path, "wb"))
	file:write(png_data)
	file:close()
	logn("Screenshot saved to: " .. screenshot_path)
end

local function init_render3d()
	if not initialized then
		render.Initialize({headless = true, width = width, height = height})
		initialized = true
	else
		render.GetDevice():WaitIdle()
	end

	render3d.Initialize()
end

local function draw3d(cb)
	init_render3d()
	local cam = render3d.GetCamera()
	cam:SetViewport(Rect(0, 0, width, height))
	cam:SetFOV(math.rad(90))
	render.BeginFrame()
	local cmd = render.GetCommandBuffer()
	cmd:SetViewport(0, 0, width, height)
	cmd:SetScissor(0, 0, width, height)
	local frame_index = render.GetCurrentFrame()
	render3d.pipeline:Bind(cmd, frame_index)
	cb(cmd)
	render.EndFrame()
	render.GetDevice():WaitIdle()
end

local function get_pixel_color(x, y)
	local image_data = render.CopyImageToCPU(render.target.image, width, height, "r8g8b8a8_unorm")
	local bytes_per_pixel = image_data.bytes_per_pixel
	local offset = (y * width + x) * bytes_per_pixel
	return image_data.pixels[offset + 0] / 255,
	image_data.pixels[offset + 1] / 255,
	image_data.pixels[offset + 2] / 255
end

local i = 0

local function test_pixel(x, y, r, g, b, tolerance)
	tolerance = tolerance or 0.1
	local r_, g_, b_ = get_pixel_color(x, y)

	if
		math.abs(r_ - r) > tolerance or
		math.abs(g_ - g) > tolerance or
		math.abs(b_ - b) > tolerance
	then
		logn(
			string.format(
				"Pixel at %d, %d: expected (%.2f, %.2f, %.2f), got (%.2f, %.2f, %.2f)",
				x,
				y,
				r,
				g,
				b,
				r_,
				g_,
				b_
			)
		)
	end

	T(math.abs(r_ - r))["<="](tolerance)
	T(math.abs(g_ - g))["<="](tolerance)
	T(math.abs(b_ - b))["<="](tolerance)
	i = i + 1
end

local white_tex

-- Create 6 quads for the inverted cube
local function create_face(pos, normal, up, color)
	if not white_tex then
		white_tex = Texture.New(
			{
				width = 1,
				height = 1,
				format = "r8g8b8a8_unorm",
				buffer = ffi.new("uint8_t[4]", {255, 255, 255, 255}),
			}
		)
	end

	local poly = Polygon3D.New()
	local right = normal:GetCross(up)
	local size = 10 -- Large enough to cover the view
	-- Vertices for a quad
	local v1 = pos - right * size + up * size
	local v2 = pos + right * size + up * size
	local v3 = pos + right * size - up * size
	local v4 = pos - right * size - up * size
	-- CCW winding for looking from origin (inside)
	-- Triangle 1: v1, v4, v3
	poly:AddVertex({pos = v1, normal = -normal})
	poly:AddVertex({pos = v4, normal = -normal})
	poly:AddVertex({pos = v3, normal = -normal})
	-- Triangle 2: v1, v3, v2
	poly:AddVertex({pos = v1, normal = -normal})
	poly:AddVertex({pos = v3, normal = -normal})
	poly:AddVertex({pos = v2, normal = -normal})
	poly:Upload()
	return {
		poly = poly,
		material = Material.New(
			{
				base_color_factor = {color.x, color.y, color.z, 1},
				emissive_texture = white_tex,
				emissive_factor = {color.x * 100, color.y * 100, color.z * 100},
			}
		),
	}
end

local faces
local center_cube

local function draw_faces(cmd)
	if not faces then
		faces = {
			-- Forward (+Z): Blue
			create_face(Vec3(0, 0, 10), Vec3(0, 0, 1), Vec3(0, 1, 0), Vec3(0, 0, 1)),
			-- Backward (-Z): Yellow
			create_face(Vec3(0, 0, -10), Vec3(0, 0, -1), Vec3(0, 1, 0), Vec3(1, 1, 0)),
			-- Right (+X): Red
			create_face(Vec3(10, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(1, 0, 0)),
			-- Left (-X): Cyan
			create_face(Vec3(-10, 0, 0), Vec3(-1, 0, 0), Vec3(0, 1, 0), Vec3(0, 1, 1)),
			-- Up (+Y): Green
			create_face(Vec3(0, 10, 0), Vec3(0, 1, 0), Vec3(0, 0, -1), Vec3(0, 1, 0)),
			-- Down (-Y): Magenta
			create_face(Vec3(0, -10, 0), Vec3(0, -1, 0), Vec3(0, 0, 1), Vec3(1, 0, 1)),
		}
	end

	if not center_cube then
		center_cube = Polygon3D.New()
		center_cube:CreateCube(0.5, 1.0)
		center_cube:AddSubMesh(#center_cube.Vertices)
		center_cube:Upload()
	end

	for _, face in ipairs(faces) do
		render3d.SetWorldMatrix(Matrix44())
		render3d.SetMaterial(face.material)
		render3d.UploadConstants(cmd)
		face.poly:Draw(cmd)
	end

	-- Draw a small white cube at origin to help with positioning tests
	render3d.SetWorldMatrix(Matrix44())
	render3d.SetMaterial(
		Material.New(
			{
				base_color_factor = {1, 1, 1, 1},
				emissive_texture = white_tex,
				emissive_factor = {10, 10, 10},
			}
		)
	)
	render3d.UploadConstants(cmd)
	center_cube:Draw(cmd)
end

-- Test 1: Initial orientation
-- In this engine, identity rotation looks Backward (-Z)
T.Test("Camera initial orientation", function()
	draw3d(function(cmd)
		local cam = render3d.GetCamera()
		cam:SetPosition(Vec3(0, 0, 0))
		cam:SetRotation(Quat(0, 0, 0, 1))
		draw_faces(cmd)
	end)

	test_pixel(width / 2, height / 2, 1, 1, 0) -- Should see Yellow (-Z)
end)

-- Test 1.5: Look Forward (+Z)
-- Yaw 180 degrees (pi) should look Forward
T.Test("Camera look forward", function()
	draw3d(function(cmd)
		local cam = render3d.GetCamera()
		cam:SetPosition(Vec3(0, 0, 0))
		local q = Quat()
		q:SetAngles(Ang3(0, math.pi, 0))
		cam:SetRotation(q)
		draw_faces(cmd)
	end)

	test_pixel(width / 2, height / 2, 0, 0, 1) -- Should see Blue (+Z)
end)

-- Test 2: Look Right (+X)
-- Yaw -90 degrees (-pi/2) should look Right
T.Test("Camera look right", function()
	draw3d(function(cmd)
		local cam = render3d.GetCamera()
		cam:SetPosition(Vec3(0, 0, 0))
		local q = Quat()
		q:SetAngles(Ang3(0, -math.pi / 2, 0))
		cam:SetRotation(q)
		draw_faces(cmd)
	end)

	test_pixel(width / 2, height / 2, 1, 0, 0) -- Should see Red (+X)
end)

-- Test 3: Look Up (+Y)
-- Pitch -90 degrees (-pi/2) should look Up
T.Test("Camera look up", function()
	draw3d(function(cmd)
		local cam = render3d.GetCamera()
		cam:SetPosition(Vec3(0, 0, 0))
		local q = Quat()
		q:SetAngles(Ang3(-math.pi / 2, 0, 0))
		cam:SetRotation(q)
		draw_faces(cmd)
	end)

	test_pixel(width / 2, height / 2, 0, 1, 0) -- Should see Green (+Y)
end)

T.Test("Camera look left and up", function()
	draw3d(function(cmd)
		local cam = render3d.GetCamera()
		cam:SetFOV(math.rad(120))
		cam:SetPosition(Vec3(0, 0, 0))
		local q = Quat()
		q:Identity()
		q:RotateYaw(math.rad(90)) -- TODO: known bug, left is actually right here
		q:RotatePitch(math.rad(90)) -- Look Up
		cam:SetRotation(q)
		draw_faces(cmd)
	end)

	save_screenshot("camera_look_left_and_up")
	test_pixel(width / 2, height / 2, 0, 1, 0) -- Should see Green (+Y)
end)

T.Test("Camera look left and up", function()
	draw3d(function(cmd)
		local cam = render3d.GetCamera()
		cam:SetFOV(math.rad(120))
		cam:SetPosition(Vec3(0, 0, 0))
		local q = Quat()
		q:Identity()
		q:RotateYaw(math.rad(180)) -- TODO: known bug, left is actually right here
		q:RotatePitch(math.rad(90)) -- Look Up
		cam:SetRotation(q)
		draw_faces(cmd)
	end)

	save_screenshot("camera_look_left_and_up")
	test_pixel(width / 2, height / 2, 0, 1, 0) -- Should see Green (+Y)
	-- left side is red
	test_pixel(10, height / 2, 1, 0, 0)
end)

-- Test 3: Look Up (+Y)
-- Pitch -90 degrees (-pi/2) should look Up
T.Test("Camera look up and move forward", function()
	draw3d(function(cmd)
		local cam = render3d.GetCamera()
		cam:SetFOV(math.rad(120))
		cam:SetPosition(Vec3(0, 0, 0))
		local q = Quat()
		q:SetAngles(Ang3(-math.pi / 2, 0, 0))
		cam:SetPosition(cam:GetPosition() + cam:GetRotation():GetForward() * 5)
		cam:SetRotation(q)
		draw_faces(cmd)
	end)

	test_pixel(width / 2, height / 2, 0, 1, 0) -- Should see Green (+Y)
	test_pixel(10, height / 2, 0, 1, 0)
	test_pixel(width - 10, 10, 0, 1, 0)
	test_pixel(width - 10, height / 2, 0, 1, 0)
	test_pixel(width - 10, height - 10, 0, 1, 0)
end)

-- Test 3: Look Up (+Y)
-- Pitch -90 degrees (-pi/2) should look Up
T.Test("Camera look down and move forward", function()
	draw3d(function(cmd)
		local cam = render3d.GetCamera()
		cam:SetFOV(math.rad(120))
		cam:SetPosition(Vec3(0, 0, 0))
		local q = Quat()
		q:SetAngles(Ang3(math.pi / 2, 0, 0))
		cam:SetPosition(cam:GetPosition() + cam:GetRotation():GetForward() * -5) -- TODO: forward is actually backward here
		cam:SetRotation(q)
		draw_faces(cmd)
	end)

	test_pixel(width / 2, height / 2, 1, 0.1, 1) -- Should see Magenta (-Y)
	test_pixel(10, height / 2, 1, 0.1, 1)
	test_pixel(width - 10, 10, 1, 0.1, 1)
	test_pixel(width - 10, height / 2, 1, 0.1, 1)
	test_pixel(width - 10, height - 10, 1, 0.1, 1)
end)

-- Test 4: Movement Up
-- cam:SetPosition(cam:GetPosition() + cam:GetRotation():Up()*2)
T.Test("Camera movement up", function()
	draw3d(function(cmd)
		local cam = render3d.GetCamera()
		cam:SetPosition(Vec3(0, 0, 0))
		cam:SetRotation(Quat(0, 0, 0, 1)) -- Looking Backward (-Z)
		local up = cam:GetRotation():Up()
		-- TODO: known bug, up is actually down here
		T(up.x)["=="](0)
		T(up.y)["=="](1)
		T(up.z)["=="](0)
		cam:SetPosition(cam:GetPosition() + up * -5)
		T(cam:GetPosition().y)["=="](-5)
		draw_faces(cmd)
	end)

	-- If we moved UP, the Backward face (-Z) should appear shifted DOWN in the view.
	-- The center should still be Yellow (-Z)
	test_pixel(width / 2, height / 2, 1, 1, 0)
	-- The top of the screen should now show more of the Green ceiling (+Y)
	test_pixel(width / 2, 10, 0, 1, 0)
end)

T.Test("Camera movement backward", function()
	draw3d(function(cmd)
		local cam = render3d.GetCamera()
		cam:SetFOV(math.rad(120))
		cam:SetPosition(Vec3(0, 0, 0))
		cam:SetPosition(Vec3(0, 0, -5))
		draw_faces(cmd)
	end)

	-- see the white box
	test_pixel(width / 2, height / 2, 1, 1, 1)
end)

T.Test("Camera movement left", function()
	draw3d(function(cmd)
		local cam = render3d.GetCamera()
		cam:SetFOV(math.rad(120))
		cam:SetPosition(Vec3(0, 0, 0))
		-- TODO: known bug, right is actually left here
		cam:SetPosition(Vec3(10, 0, 0))
		draw_faces(cmd)
	end)

	-- left half of the screen should be black
	-- top right should be green 
	-- right should be yellow 
	-- bottom right should be magenta
	test_pixel(10, height / 2, 0, 0, 0)
	test_pixel(width - 10, 10, 0, 1, 0)
	test_pixel(width - 10, height / 2, 1, 1, 0)
	test_pixel(width - 10, height - 10, 1, 0.11, 1)
end)

-- Test 6: Camera Roll
T.Test("Camera roll", function()
	draw3d(function(cmd)
		local cam = render3d.GetCamera()
		cam:SetFOV(math.rad(120))
		cam:SetPosition(Vec3(0, 0, -5)) -- Back up a bit to see the center cube
		local q = Quat()
		-- Look at origin (Forward +Z) and roll -90 degrees
		-- Then roll -90.
		q:SetAngles(Ang3(0, 0, -math.pi / 2))
		cam:SetRotation(q)
		draw_faces(cmd)
	end)

	-- With 90 degree roll, the "Up" direction is now "Left".
	-- The Green ceiling (+Y) should now be on the LEFT side of the screen.
	test_pixel(10, height / 2, 0, 1, 0)
end)

-- Test 7: FOV Change
T.Pending("Camera FOV change", function()
	local pixels_90, pixels_45

	-- 90 degree FOV
	draw3d(function(cmd)
		local cam = render3d.GetCamera()
		cam:SetFOV(math.rad(90))
		cam:SetPosition(Vec3(0, 0, 5))
		cam:SetRotation(Quat(0, 0, 0, 1)) -- Look at center cube (at origin, identity looks -Z)
		draw_faces(cmd)
	end)

	test_pixel(width / 2, height / 2, 1, 1, 1) -- Should see white center cube
	-- Count white pixels of the center cube
	local image_data = render.CopyImageToCPU(render.target.image, width, height, "r8g8b8a8_unorm")
	pixels_90 = 0

	for i = 0, image_data.size - 1, 4 do
		if
			image_data.pixels[i] > 200 and
			image_data.pixels[i + 1] > 200 and
			image_data.pixels[i + 2] > 200
		then
			pixels_90 = pixels_90 + 1
		end
	end

	-- 45 degree FOV
	draw3d(function(cmd)
		local cam = render3d.GetCamera()
		cam:SetFOV(math.rad(45))
		cam:SetPosition(Vec3(0, 0, 5))
		cam:SetRotation(Quat(0, 0, 0, 1))
		draw_faces(cmd)
	end)

	test_pixel(width / 2, height / 2, 1, 1, 1)
	local image_data = render.CopyImageToCPU(render.target.image, width, height, "r8g8b8a8_unorm")
	pixels_45 = 0

	for i = 0, image_data.size - 1, 4 do
		if
			image_data.pixels[i] > 200 and
			image_data.pixels[i + 1] > 200 and
			image_data.pixels[i + 2] > 200
		then
			pixels_45 = pixels_45 + 1
		end
	end

	-- 45 degree FOV should have significantly more pixels for the same object (approx 4x more area)
	T(pixels_45)[">"](pixels_90 * 2)
end)

-- Test 8: Near Plane Clipping
T.Test("Camera near plane clipping", function()
	draw3d(function(cmd)
		local cam = render3d.GetCamera()
		cam:SetNearZ(2.0)
		cam:SetPosition(Vec3(0, 0, 1)) -- 1 unit away from center cube
		cam:SetRotation(Quat(0, 0, 0, 1)) -- Look at center cube
		draw_faces(cmd)
	end)

	-- Center cube is at origin, camera is at Z=1, near plane is at 2.
	-- So the cube (at distance 1) should be clipped and we should see the Yellow face (-Z) behind it.
	test_pixel(width / 2, height / 2, 1, 1, 0)
end)

-- Test 9: Far Plane Clipping
T.Test("Camera far plane clipping", function()
	draw3d(function(cmd)
		local cam = render3d.GetCamera()
		cam:SetFarZ(10 - 0.1) -- Just before the Yellow face
		cam:SetFOV(math.rad(120))
		cam:SetPosition(Vec3(0, 0, 0))
		cam:SetRotation(Quat(0, 0, 0, 1)) -- Look at Yellow face (-Z)
		draw_faces(cmd)
	end)

	-- Yellow face is at Z=-10, camera at Z=0, FarZ=5.
	-- Yellow face should be clipped (not rendered).
	test_pixel(width / 2, height / 2, 0, 0, 0) -- center is clipped, so black
	test_pixel(width / 2, 1, 0, 1, 0) -- top is green
	test_pixel(width / 2, height - 2, 1, 0, 1) -- bottom is magenta
	test_pixel(1, height / 2, 0, 1, 1) -- left is cyan
	test_pixel(width - 2, height / 2, 1, 0, 0) -- right is red
end)

-- Test 10: Orbiting
T.Pending("Camera orbiting", function()
	for angle = 0, math.pi * 2 - 0.1, math.pi / 2 do
		draw3d(function(cmd)
			local cam = render3d.GetCamera()
			local radius = 5
			local x = math.sin(angle) * radius
			local z = math.cos(angle) * radius
			cam:SetPosition(Vec3(x, 0, z))
			cam:SetAngles(Ang3(0, angle, 0))
			draw_faces(cmd)
		end)

		test_pixel(width / 2, height / 2, 1, 1, 1) -- Should always see the white center cube
	end
end)
