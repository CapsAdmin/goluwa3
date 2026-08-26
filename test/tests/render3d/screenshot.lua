local T = import("test/environment.lua")
local event = import("goluwa/event.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Material = import("goluwa/render3d/material.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")

local function create_face(pos, normal, up, color)
	local poly = Polygon3D.New()
	local right = normal:GetCross(up)
	local size = 10
	local v1 = pos - right * size + up * size
	local v2 = pos + right * size + up * size
	local v3 = pos + right * size - up * size
	local v4 = pos - right * size - up * size
	poly:AddVertex({pos = v1})
	poly:AddVertex({pos = v3})
	poly:AddVertex({pos = v4})
	poly:AddVertex({pos = v1})
	poly:AddVertex({pos = v2})
	poly:AddVertex({pos = v3})
	poly:BuildUVsPlanar()
	poly:BuildNormals()
	poly:BuildTangents()
	poly:Upload()
	local material = Material.New{
		ColorMultiplier = Color(color.r, color.g, color.b, 1),
		DoubleSided = true,
	}
	local ent = Entity.New({Name = "face"})
	ent:AddComponent("transform")
	ent:AddComponent("visual")
	local primitive_entity = Entity.New{Name = ent:GetName() .. "_primitive", Parent = ent}
	primitive_entity:AddComponent("transform")
	local visual_primitive = primitive_entity:AddComponent("visual_primitive")
	visual_primitive:SetPolygon3D(poly)
	visual_primitive:SetMaterial(material)
	ent.visual:BuildAABB()
	ent.visual:SetUseOcclusionCulling(false)
	return ent
end

T.Test3D("Screenshot camera override beats a per-frame camera controller", function()
	local cam = render3d.GetCamera()

	-- red face visible from the origin looking -Z
	local red_face = create_face(Vec3(0, 0, -10), Vec3(0, 0, 1), Vec3(0, 1, 0), Color(1, 0, 0))
	-- blue face visible from (50, 0, 0) looking -X
	local blue_face = create_face(Vec3(40, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0), Color(0, 0, 1))

	-- fake player controller: re-asserts the camera every Update at priority
	-- -100, like the camera component does (before render.Draw renders the frame)
	local controller_pos = Vec3(50, 0, 0)
	local controller_rot = Quat():SetAngles(Deg3(0, 90, 0))
	event.AddListener(
		"Update",
		"screenshot_test_controller",
		function()
			cam:SetPosition(controller_pos)
			cam:SetRotation(controller_rot)
		end,
		{priority = -100}
	)

	-- the "current" camera the controller left behind; Screenshot must restore this
	cam:SetPosition(controller_pos)
	cam:SetRotation(controller_rot)

	local results = {}
	Screenshot(
		function(tex)
			results.called = true
			local pos = cam:GetPosition()
			results.restored = pos.x == 50 and pos.y == 0 and pos.z == 0
		end,
		{
			update_events = 1,
			camera = {position = Vec3(0, 0, 0), rotation = Quat(0, 0, 0, 1)},
		}
	)

	event.Call("FrameEnd")
	event.RemoveListener("Update", "screenshot_test_controller")

	assert(results.called, "Screenshot callback was not called")
	-- the capture frame's gbuffer holds the scene as seen from the override
	-- camera (the test pipeline has no lighting pass, so the screen target
	-- itself is not a useful assertion)
	local r, g, b = T.GetAlbedoPixel(256, 256)
	assert(
		r > 0.6 and g < 0.4 and b < 0.4,
		string.format(
			"albedo center should be red (camera override beat the controller), got %.2f,%.2f,%.2f",
			r,
			g,
			b
		)
	)
	assert(results.restored, "camera should be restored after the capture")

	red_face:Remove()
	blue_face:Remove()
end)

T.Test3D("Screenshot midframe and camera cannot be combined", function()
	local ok, err = pcall(Screenshot, function() end, {midframe = true, camera = {position = Vec3(0, 0, 0)}})
	assert(not ok, "should error")
	assert(err:find("midframe"), "error should mention midframe, got: " .. tostring(err))
end)
