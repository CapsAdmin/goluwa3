local T = import("test/environment.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local View = import("goluwa/render3d/view.lua")
local Shot = import("goluwa/render3d/shot.lua")
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

local function draw_until(draw, done)
	for _ = 1, 100 do
		if done() then return end

		draw()
	end

	error("gave up after 100 frames")
end

T.Test3D("Shot view overrides a per-frame view controller", function(draw)
	-- red face visible from the origin looking -Z
	local red_face = create_face(Vec3(0, 0, -10), Vec3(0, 0, 1), Vec3(0, 1, 0), Color(1, 0, 0))
	-- blue face visible from (50, 0, 0) looking -X
	local blue_face = create_face(Vec3(40, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0), Color(0, 0, 1))
	-- fake player controller, re-asserting its view every frame
	local controller_pos = Vec3(50, 0, 0)
	local controller_rot = Quat():SetAngles(Deg3(0, 90, 0))
	local controller_view = View.New{Position = controller_pos, Rotation = controller_rot}:Activate()
	local results = {}
	Shot.Capture(
		{Position = Vec3(0, 0, 0), Rotation = Quat(0, 0, 0, 1)},
		function(texture, info)
			results.info = info
			-- the gbuffer holds the last frame, rendered from the shot's view
			-- (the test pipeline has no lighting pass, so the screen target
			-- itself is not a useful assertion)
			results.r, results.g, results.b = T.GetAlbedoPixel(256, 256)
			results.restored = render3d.GetCamera():GetPosition() == controller_pos
		end,
		{settle = 0, settle_frames = 3}
	)
	draw_until(
		function()
			controller_view:SetPosition(controller_pos:Copy())
			controller_view:SetRotation(controller_rot:Copy())
			draw()
		end,
		function()
			return results.info ~= nil
		end
	)
	assert(
		results.r > 0.6 and results.g < 0.4 and results.b < 0.4,
		string.format(
			"albedo center should be red (shot view beat the controller), got %.2f,%.2f,%.2f",
			results.r,
			results.g,
			results.b
		)
	)
	assert(results.info.frames >= 3, "shot should be held for settle_frames, got " .. results.info.frames)
	assert(results.restored, "the controller's view should be rendered again after the shot")
	controller_view:Remove()
	red_face:Remove()
	blue_face:Remove()
end)

T.Test3D("Shot converge compares captures of a static scene", function(draw)
	local face = create_face(Vec3(0, 0, -10), Vec3(0, 0, 1), Vec3(0, 1, 0), Color(1, 0, 0))
	local result
	Shot.Capture(
		{Position = Vec3(0, 0, 0), Rotation = Quat(0, 0, 0, 1)},
		function(texture, info)
			result = info
		end,
		{settle = 0, settle_frames = 2, converge = 1, converge_frames = 2}
	)
	draw_until(draw, function()
		return result ~= nil
	end)
	assert(result.converged, "a static scene should converge, difference " .. tostring(result.difference))
	assert(result.difference <= 1)
	face:Remove()
end)

T.Test3D("Shot.Sequence captures each view in turn", function(draw)
	local indices = {}
	local done = false
	Shot.Sequence(
		{
			{Position = Vec3(1, 0, 0)},
			{Position = Vec3(2, 0, 0)},
		},
		function(texture, info, i)
			indices[#indices + 1] = i
			assert(render3d.GetCamera():GetPosition() == Vec3(i, 0, 0), "shot " .. i .. " rendered from the wrong position")
		end,
		{settle = 0, settle_frames = 2},
		function()
			done = true
		end
	)
	draw_until(draw, function()
		return done
	end)
	assert(indices[1] == 1 and indices[2] == 2 and not indices[3])
	assert(View.GetActive() == nil, "the sequence's view should be removed")
end)
