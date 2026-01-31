local T = require("test.environment")
local ffi = require("ffi")
local Polygon3D = require("render3d.polygon_3d")
local Material = require("render3d.material")
local render3d = require("render3d.render3d")
local Vec3 = require("structs.vec3")
local Rect = require("structs.rect")
local Quat = require("structs.quat")
local Color = require("structs.color")
local Vec2 = require("structs.vec2")
local Matrix44 = require("structs.matrix44")
local AABB = require("structs.aabb")
local ecs = require("ecs.ecs")
local transform = require("ecs.components.3d.transform")
local model = require("ecs.components.3d.model")
local light = require("ecs.components.3d.light")
local width = 512
local height = 512

local function spawn_test_object(pos, size, color)
	local poly = Polygon3D.New()
	poly:CreateCube(size or 1)
	poly:BuildBoundingBox()
	poly:Upload()
	local material = Material.New(
		{
			ColorMultiplier = Color(color.r, color.g, color.b, 1),
			EmissiveMultiplier = Color(1, 1, 1, 1), -- Make it bright so we can see it easily
		}
	)
	local ent = ecs.CreateEntity()
	ent:AddComponent(transform)
	ent:SetPosition(pos)
	local mdl = ent:AddComponent(model)
	mdl:AddPrimitive(poly, material)
	return ent, mdl
end

local function TestCullingBehavior(name, cb)
	T.Test3D(name, function(draw)
		local sun = ecs.CreateFromTable(
			{
				[transform] = {},
				[light] = {
					LightType = "sun",
					Color = Color(1, 1, 1),
					Intensity = 1,
				},
			}
		)
		local cam = render3d.GetCamera()
		cam:SetFOV(math.rad(90))
		cam:SetNearZ(0.1)
		cam:SetFarZ(100)
		cam:SetPosition(Vec3(0, 0, 0))
		cam:SetRotation(Quat():Identity()) -- Looking at -Z (default)
		cb(draw)
		sun:Remove()
	end)
end

local function orient_camera(ang, pos)
	local cam = render3d.GetCamera()
	cam:SetPosition(pos or Vec3(0, 0, 0))
	local q = Quat()
	q:SetAngles(ang)
	cam:SetRotation(q)
end

TestCullingBehavior("Object directly in front should not be culled", function(draw)
	local ent, mdl = spawn_test_object(Vec3(0, 0, -5), 1, Color(1, 0, 0))
	draw()
	T(mdl.frustum_culled)["=="](false)
	T.ScreenAlbedoPixel(width / 2, height / 2, 1, 0, 0, 1, 0.1)
	ent:Remove()
end)

TestCullingBehavior("Object behind should be culled", function(draw)
	local ent, mdl = spawn_test_object(Vec3(0, 0, 5), 1, Color(0, 1, 0))
	draw()
	T(mdl.frustum_culled)["=="](true)
	-- Center should be black (background)
	T.ScreenAlbedoPixel(width / 2, height / 2, 0, 0, 0, 1, 0.1)
	ent:Remove()
end)

TestCullingBehavior("Object far left outside frustum should be culled", function(draw)
	-- At dist 5, with 90 deg FOV, anything with X < -5 or X > 5 is outside
	local ent, mdl = spawn_test_object(Vec3(-10, 0, -5), 1, Color(0, 0, 1))
	draw()
	T(mdl.frustum_culled)["=="](true)
	T.ScreenAlbedoPixel(width / 2, height / 2, 0, 0, 0, 1, 0.1)
	ent:Remove()
end)

TestCullingBehavior("Object partially inside from the left should not be culled", function(draw)
	-- Positioned so it crosses the left frustum plane
	local ent, mdl = spawn_test_object(Vec3(-5, 0, -5), 2, Color(1, 1, 0))
	draw()
	T(mdl.frustum_culled)["=="](false)
	-- It should be visible on the left side of the screen
	T.ScreenAlbedoPixel(10, height / 2, 1, 1, 0, 1, 0.1)
	ent:Remove()
end)

TestCullingBehavior("Object beyond FarZ should be culled", function(draw)
	local ent, mdl = spawn_test_object(Vec3(0, 0, -110), 1, Color(1, 0, 1))
	draw()
	T(mdl.frustum_culled)["=="](true)
	T.ScreenAlbedoPixel(width / 2, height / 2, 0, 0, 0, 1, 0.1)
	ent:Remove()
end)

TestCullingBehavior("Object closer than NearZ should be culled", function(draw)
	local ent, mdl = spawn_test_object(Vec3(0, 0, -0.05), 0.01, Color(0, 1, 1))
	draw()
	-- Since it is entirely closer than NearZ (0.1), it should be culled
	T(mdl.frustum_culled)["=="](true)
	-- And it shouldn't be rendered
	T.ScreenAlbedoPixel(width / 2, height / 2, 0, 0, 0, 1, 0.1)
	ent:Remove()
end)

TestCullingBehavior("Culling with rotated camera", function(draw)
	local ent, mdl = spawn_test_object(Vec3(10, 0, 0), 1, Color(1, 1, 1))
	-- Look straight ahead (-Z), object is 90 deg to the right
	local cam = render3d.GetCamera()
	cam:SetRotation(Quat():Identity())
	draw()
	T(mdl.frustum_culled)["=="](true)
	-- Look right (+X)
	cam:SetRotation(Quat():SetAngles(Deg3(0, -90, 0)))
	draw()
	T(mdl.frustum_culled)["=="](false)
	T.ScreenAlbedoPixel(width / 2, height / 2, 1, 1, 1, 1, 0.1)
	ent:Remove()
end)

TestCullingBehavior("Freezing culling", function(draw)
	local ent, mdl = spawn_test_object(Vec3(0, 0, -5), 1, Color(1, 0, 0))
	local cam = render3d.GetCamera()
	-- Initial frame to capture frustum
	cam:SetPosition(Vec3(0, 0, 0))
	cam:SetRotation(Quat():Identity())
	draw()
	T(mdl.frustum_culled)["=="](false)
	model.freeze_culling = true
	-- Move camera so object would normally be culled (it will be behind)
	cam:SetPosition(Vec3(0, 0, -10))
	draw()
	-- Should still be NOT culled because frustum was frozen at original camera position
	T(mdl.frustum_culled)["=="](false)
	model.freeze_culling = false
	draw()
	-- Now it should be culled
	T(mdl.frustum_culled)["=="](true)
	ent:Remove()
end)

TestCullingBehavior("Near plane clipping reproduction (from camera.lua)", function(draw)
	-- Setup camera
	local cam = render3d.GetCamera()
	cam:SetPosition(Vec3(0, 0, 1))
	cam:SetNearZ(2.0)
	cam:SetRotation(Quat():Identity())
	-- Object at (0, 0, -10). Distance 11. Should be visible.
	local ent, mdl = spawn_test_object(Vec3(0, 0, -10), 1, Color(1, 1, 0))
	draw()
	T(mdl.frustum_culled)["=="](false)
	T.ScreenAlbedoPixel(width / 2, height / 2, 1, 1, 0, 1, 0.48)
	ent:Remove()
end)

TestCullingBehavior("Far plane clipping reproduction (from camera.lua)", function(draw)
	-- Setup camera
	local cam = render3d.GetCamera()
	cam:SetPosition(Vec3(0, 0, 0))
	cam:SetFarZ(9.9)
	cam:SetNearZ(0.1)
	cam:SetRotation(Quat():Identity())
	-- Object at (-10, 0, 0). (Cyan face in camera.lua)
	-- Distance from (0,0,0) is 10. 10 > 9.9. Should be culled.
	local ent_cyan, mdl_cyan = spawn_test_object(Vec3(-10, 0, 0), 1, Color(0, 1, 1))
	-- Object at (0, 0, -5). (Somewhere in front)
	-- Distance 5 < 9.9. Should be visible.
	local ent_front, mdl_front = spawn_test_object(Vec3(0, 0, -5), 1, Color(1, 0, 0))
	draw()
	T(mdl_cyan.frustum_culled)["=="](true)
	T(mdl_front.frustum_culled)["=="](false)
	ent_cyan:Remove()
	ent_front:Remove()
end)

TestCullingBehavior("Movement left reproduction (from camera.lua)", function(draw)
	-- Camera at (-10, 0, 0), looking at -Z
	local cam = render3d.GetCamera()
	cam:SetPosition(Vec3(-10, 0, 0))
	cam:SetRotation(Quat():Identity())
	cam:SetFOV(math.rad(120))
	cam:SetNearZ(0.1)
	cam:SetFarZ(100)
	-- Yellow face at (0, 0, -10)
	local ent, mdl = spawn_test_object(Vec3(0, 0, -10), 1, Color(1, 1, 0))
	draw()
	-- In camera space: (0, 0, -10) - (-10, 0, 0) = (10, 0, -10).
	-- With 120 FOV, aspect 1, half-angle is 60 deg.
	-- max_x = tan(60) * depth = 1.732 * 10 = 17.32.
	-- Object is at x=10, depth=10. 10 < 17.32. Should be visible.
	T(mdl.frustum_culled)["=="](false)
	ent:Remove()
end)

TestCullingBehavior("Movement backward reproduction", function(draw)
	local cam_pos = Vec3(0, 0, 10)
	local view = Matrix44()
	view:Translate(-cam_pos.x, -cam_pos.y, -cam_pos.z)
	local proj = Matrix44()
	proj:Perspective(math.rad(120), 0.1, 1000, 1)
	local VP = view:GetMultiplied(proj)
	local planes = ffi.new("float[24]")
	-- Simulating model:get_frustum_planes() logic
	local m = VP
	planes[0] = m.m03 + m.m00 -- Left
	planes[1] = m.m13 + m.m10
	planes[2] = m.m23 + m.m20
	planes[3] = m.m33 + m.m30
	planes[4] = m.m03 - m.m00 -- Right
	planes[5] = m.m13 - m.m10
	planes[6] = m.m23 - m.m20
	planes[7] = m.m33 - m.m30
	planes[8] = m.m03 + m.m01 -- Top
	planes[9] = m.m13 + m.m11
	planes[10] = m.m23 + m.m21
	planes[11] = m.m33 + m.m31
	planes[12] = m.m03 - m.m01 -- Bottom
	planes[13] = m.m13 - m.m11
	planes[14] = m.m23 - m.m21
	planes[15] = m.m33 - m.m31
	planes[16] = m.m02 -- Near
	planes[17] = m.m12
	planes[18] = m.m22
	planes[19] = m.m32
	planes[20] = m.m03 - m.m02 -- Far
	planes[21] = m.m13 - m.m12
	planes[22] = m.m23 - m.m22
	planes[23] = m.m33 - m.m32
	local is_aabb_visible_frustum = function(aabb, planes)
		for i = 0, 20, 4 do
			local a, b, c, d = planes[i], planes[i + 1], planes[i + 2], planes[i + 3]
			local px = a > 0 and aabb.max_x or aabb.min_x
			local py = b > 0 and aabb.max_y or aabb.min_y
			local pz = c > 0 and aabb.max_z or aabb.min_z

			if a * px + b * py + c * pz + d < 0 then return false end
		end

		return true
	end
	local aabb = AABB(-0.5, -0.5, -0.5, 0.5, 0.5, 0.5)
	T(is_aabb_visible_frustum(aabb, planes))["=="](true)
end)
