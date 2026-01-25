local vk = require("bindings.vk")

if not pcall(vk.find_library) then
	print("Vulkan library not available, skipping camera tests.")
	return
end

local T = require("test.environment")
local ffi = require("ffi")
local event = require("event")
local render = require("render.render")
local render3d = require("render3d.render3d")
local Polygon3D = require("render3d.polygon_3d")
local Material = require("render3d.material")
local Texture = require("render.texture")
local Vec3 = require("structs.vec3")
local Rect = require("structs.rect")
local Quat = require("structs.quat")
local Color = require("structs.color")
local Vec2 = require("structs.vec2")
local Matrix44 = require("structs.matrix44")
local orientation = require("render3d.orientation")
local transform = require("components.transform").Component
local model = require("components.model").Component
local light = require("components.light").Component
local ecs = require("ecs")
local width = 512
local height = 512
local colors = {
	white = Color(1, 1, 1),
	black = Color(0, 0, 0),
	red = Color(1, 0, 0),
	green = Color(0, 1, 0),
	blue = Color(0, 0, 1),
	yellow = Color(1, 1, 0),
	magenta = Color(1, 0.1, 1),
	cyan = Color(0, 1, 1),
}
local positions = {
	center = Vec2(width / 2, height / 2),
	top_center = Vec2(width / 2, 10),
	left_center = Vec2(10, height / 2),
	right_center = Vec2(width - 10, height / 2),
	bottom_center = Vec2(width / 2, height - 10),
	top_left = Vec2(10, 10),
	top_right = Vec2(width - 10, 10),
	bottom_left = Vec2(10, height - 10),
	bottom_right = Vec2(width - 10, height - 10),
}

local function test_color(pos_name, color_name, tolerance)
	local pos = positions[pos_name]
	local color = colors[color_name]
	assert(pos, "invalid position: " .. tostring(pos_name))
	assert(color, "invalid color: " .. tostring(color_name))
	T.ScreenAlbedoPixel(pos.x, pos.y, color.r, color.g, color.b, 1, tolerance or 0.48)
end

local function test_color_all(color)
	test_color("center", color)
	test_color("left_center", color)
	test_color("top_right", color)
	test_color("right_center", color)
	test_color("bottom_right", color)
end

local white_tex

-- Create 6 quads for the inverted cube
local function create_face(pos, normal, up, color)
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
	poly:AddVertex({pos = v1})
	poly:AddVertex({pos = v4})
	poly:AddVertex({pos = v3})
	poly:AddVertex({pos = v1})
	poly:AddVertex({pos = v3})
	poly:AddVertex({pos = v2})
	poly:BuildUVsPlanar()
	poly:BuildNormals()
	poly:BuildTangents()
	poly:AddSubMesh(#poly.Vertices)
	poly:Upload()
	poly.material = Material.New(
		{
			ColorMultiplier = Color(color.r, color.g, color.b, 1),
			DoubleSided = true,
		}
	)
	local ent = ecs.CreateEntity()
	ent:AddComponent(transform)
	ent:AddComponent(model)
	ent.model:AddPrimitive(poly)
end

T.Test("camera tests", function()
	do
		render.Initialize({headless = true, width = width, height = height})
		render3d.Initialize()
		ecs.CreateFromTable(
			{
				[transform] = {
					Rotation = Quat(-0.2, 0.8, 0.4, 0.4),
				},
				[light] = {
					LightType = "sun",
					Color = Color(1.0, 1, 1),
					Intensity = 1,
				},
			}
		)
		local cam = render3d.GetCamera()
		cam:SetViewport(Rect(0, 0, width, height))
		cam:SetFOV(math.rad(90))

		--
		do -- faces
			-- Forward (+Z): Blue
			create_face(Vec3(0, 0, 10), Vec3(0, 0, 1), Vec3(0, 1, 0), Color(0, 0, 1))
			-- Backward (-Z): Yellow
			create_face(Vec3(0, 0, -10), Vec3(0, 0, -1), Vec3(0, 1, 0), Color(1, 1, 0))
			-- Right (+X): Red
			create_face(Vec3(10, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0), Color(1, 0, 0))
			-- Left (-X): Cyan
			create_face(Vec3(-10, 0, 0), Vec3(-1, 0, 0), Vec3(0, 1, 0), Color(0, 1, 1))
			-- Up (+Y): Green
			create_face(Vec3(0, 10, 0), Vec3(0, 1, 0), Vec3(0, 0, -1), Color(0, 1, 0))
			-- Down (-Y): Magenta
			create_face(Vec3(0, -10, 0), Vec3(0, -1, 0), Vec3(0, 0, 1), Color(1, 0, 1))
		end

		do -- small white cube in the center
			local poly = Polygon3D.New()
			poly:CreateCube(0.5, 1.0)
			poly:AddSubMesh(#poly.Vertices)
			poly:Upload()
			poly.material = Material.New(
				{
					AlbedoTexture = white_tex,
					EmissiveMultiplier = Color(1, 1, 1, 100),
					DoubleSided = false,
				}
			)
			local ent = ecs.CreateEntity("mdl", ecs.Get3DWorld())
			ent:AddComponent(transform)
			ent:AddComponent(model)
			ent.model:AddPrimitive(poly)
		end
	end

	T.Test("Identity rotation", function()
		local cam = render3d.GetCamera()
		cam:SetPosition(Vec3(0, 0, 0))
		cam:SetRotation(Quat(0, 0, 0, 1))
		render.Draw(1)
		test_color("center", "yellow") -- Should see Yellow (-Z)
	end)

	local function setup_camera_angles(ang)
		local cam = render3d.GetCamera()
		cam:SetPosition(Vec3(0, 0, 0))
		local q = Quat()
		q:SetAngles(ang)
		cam:SetRotation(q)
	end

	T.Test("Pitch 90 degrees should look Up", function()
		setup_camera_angles(Deg3(90, 0, 0))
		render.Draw(1)
		test_color("center", "green")
	end)

	T.Test("Yaw 180 degrees should look Forward", function()
		setup_camera_angles(Deg3(0, 180, 0))
		render.Draw(1)
		test_color("center", "blue") -- Should see Blue (+Z)
	end)

	T.Test("Yaw 90 degrees should look Right", function()
		setup_camera_angles(Deg3(0, -90, 0))
		render.Draw(1)
		test_color("center", "red") -- Should see Red (+X)
	end)

	T.Test("Camera look left and up", function()
		local cam = render3d.GetCamera()
		cam:SetFOV(math.rad(120))
		cam:SetPosition(Vec3(0, 0, 0))
		local q = Quat()
		q:Identity()
		q:RotateYaw(math.rad(90)) -- Turn Left
		q:RotatePitch(math.rad(90)) -- Look Up
		cam:SetRotation(q)
		render.Draw(1)
		test_color("center", "green")
	end)

	T.Test("Camera look left and up", function()
		local cam = render3d.GetCamera()
		cam:SetFOV(math.rad(120))
		cam:SetPosition(Vec3(0, 0, 0))
		local q = Quat()
		q:Identity()
		q:RotateYaw(math.rad(180)) -- Turn Backward (to Forward)
		q:RotatePitch(math.rad(90)) -- Look Up
		cam:SetRotation(q)
		render.Draw(1)
		test_color("center", "green")
		test_color("left_center", "red")
	end)

	T.Test("Camera look up and move forward", function()
		local cam = render3d.GetCamera()
		cam:SetFOV(math.rad(120))
		cam:SetRotation(Quat():SetAngles(Deg3(90, 0, 0)))
		cam:SetPosition(cam:GetRotation():GetForward() * 5)
		render.Draw(1)
		test_color_all("green")
	end)

	T.Test("Pitch -90 degrees should look Down", function()
		local cam = render3d.GetCamera()
		cam:SetFOV(math.rad(120))
		cam:SetRotation(Quat():SetAngles(Deg3(-90, 0, 0)))
		cam:SetPosition(cam:GetRotation():GetForward() * 5)
		render.Draw(1)
		test_color_all("magenta")
	end)

	T.Test("Camera movement up", function()
		local cam = render3d.GetCamera()
		cam:SetPosition(Vec3(0, 0, 0))
		cam:SetRotation(Quat(0, 0, 0, 1))
		local up = cam:GetRotation():Up()
		T(up.x)["=="](0)
		T(up.y)["=="](1)
		T(up.z)["=="](0)
		cam:SetPosition(cam:GetPosition() + up * 5)
		T(cam:GetPosition().y)["=="](5)
		render.Draw(1)
		test_color("center", "yellow")
		test_color("top_center", "green")
	end)

	T.Test("Camera movement backward", function()
		local cam = render3d.GetCamera()
		cam:SetFOV(math.rad(120))
		cam:SetPosition(Vec3(0, 0, 10))
		render.Draw(1)
		render3d.pipelines.gbuffer:GetFramebuffer():GetAttachment(1):DumpToDisk("test")
		test_color("center", "white")
	end)

	T.Test("Camera movement left", function()
		local cam = render3d.GetCamera()
		cam:SetFOV(math.rad(120))
		cam:SetPosition(Vec3(-10, 0, 0))
		render.Draw(1)
		-- left half of the screen should be black
		-- top right should be green 
		-- right should be yellow 
		-- bottom right should be magenta
		test_color("left_center", "black")
		test_color("top_right", "green")
		test_color("right_center", "yellow")
		test_color("bottom_right", "magenta")
	end)

	T.Test("Camera roll", function()
		local cam = render3d.GetCamera()
		cam:SetFOV(math.rad(120))
		cam:SetPosition(Vec3(0, 0, 5))
		local q = Quat()
		q:SetAngles(Deg3(0, 0, -90))
		cam:SetRotation(q)
		render.Draw(1)
		test_color("left_center", "green")
	end)

	T.Pending("Camera FOV change", function()
		local pixels_90, pixels_45
		local cam = render3d.GetCamera()
		cam:SetFOV(math.rad(90))
		cam:SetPosition(Vec3(0, 0, 5))
		cam:SetRotation(Quat(0, 0, 0, 1))
		render.Draw(1)
		test_color("center", "white")
		local image_data = render.target:GetTexture():Download()
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

		local cam = render3d.GetCamera()
		cam:SetFOV(math.rad(45))
		cam:SetPosition(Vec3(0, 0, 5))
		cam:SetRotation(Quat(0, 0, 0, 1))
		render.Draw(1)
		test_color("center", "white")
		local image_data = render.target:GetTexture():Download()
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

		T(pixels_45)[">"](pixels_90 * 2)
	end)

	T.Test("Camera near plane clipping", function()
		local cam = render3d.GetCamera()
		cam:SetNearZ(2.0)
		cam:SetPosition(Vec3(0, 0, 1)) -- 1 unit away from center cube
		cam:SetRotation(Quat(0, 0, 0, 1)) -- Look at center cube
		render.Draw(1)
		test_color("center", "yellow")
	end)

	T.Test("Camera far plane clipping", function()
		local cam = render3d.GetCamera()
		cam:SetFarZ(10 - 0.1) -- Just before the Yellow face
		cam:SetFOV(math.rad(120))
		cam:SetPosition(Vec3(0, 0, 0))
		cam:SetRotation(Quat(0, 0, 0, 1)) -- Look at Yellow face (-Z)
		render.Draw(1)
		test_color("center", "black") -- center is clipped, so black
		test_color("top_center", "green") -- top is green
		test_color("bottom_center", "magenta") -- bottom is magenta
		test_color("left_center", "cyan") -- left is cyan
		test_color("right_center", "red") -- right is red
	end)

	T.Pending("Camera orbiting", function()
		for angle = 0, math.pi * 2 - 0.1, math.pi / 2 do
			local cam = render3d.GetCamera()
			local radius = 5
			local x = math.sin(angle) * radius
			local z = math.cos(angle) * radius
			cam:SetPosition(Vec3(x, 0, z))
			cam:SetAngles(Deg3(0, angle, 0))

			for i = 1, 5 do
				render.Draw(1)
			end

			test_color("center", "white") -- Should always see the white center cube
		end
	end)
end)
