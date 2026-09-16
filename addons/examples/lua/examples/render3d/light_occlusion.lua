local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Material = import("goluwa/render3d/material.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local scene_bvh = import("goluwa/render3d/scene_bvh.lua")
local light_occlusion = import("goluwa/render3d/light_occlusion.lua")
local ffi = require("ffi")
local mode = os.getenv("LIGHT_OCCLUSION_MODE") or "on"

local function add_face(poly, a, b, c, d)
	poly:AddVertex({pos = a})
	poly:AddVertex({pos = b})
	poly:AddVertex({pos = c})
	poly:AddVertex({pos = a})
	poly:AddVertex({pos = c})
	poly:AddVertex({pos = d})
end

local function make_box(x0, y0, z0, x1, y1, z1)
	local v = Vec3
	local poly = Polygon3D.New()
	add_face(poly, v(x0, y0, z1), v(x1, y0, z1), v(x1, y1, z1), v(x0, y1, z1))
	add_face(poly, v(x0, y0, z0), v(x0, y1, z0), v(x1, y1, z0), v(x1, y0, z0))
	add_face(poly, v(x0, y0, z0), v(x0, y0, z1), v(x0, y1, z1), v(x0, y1, z0))
	add_face(poly, v(x1, y0, z1), v(x1, y0, z0), v(x1, y1, z0), v(x1, y1, z1))
	add_face(poly, v(x0, y1, z1), v(x1, y1, z1), v(x1, y1, z0), v(x0, y1, z0))
	add_face(poly, v(x0, y0, z0), v(x1, y0, z0), v(x1, y0, z1), v(x0, y0, z1))
	poly:BuildUVsPlanar()
	poly:BuildNormals()
	poly:BuildTangents()
	poly:Upload()
	return poly
end

local function spawn_box(name, min, max)
	local ent = Entity.New({Name = name})
	ent:AddComponent("transform")
	ent:AddComponent("visual")
	local p = Entity.New{Name = name .. "_primitive", Parent = ent}
	p:AddComponent("transform")
	p:AddComponent("visual_primitive"):SetPolygon3D(make_box(min.x, min.y, min.z, max.x, max.y, max.z))
	p.visual_primitive:SetMaterial(Material.New{DoubleSided = true})
	ent.visual:BuildAABB()
	return ent
end

local function spawn_point_light(name, position, color, intensity, range)
	local ent = Entity.New({Name = name})
	ent:AddComponent("transform")
	ent.transform:SetPosition(position)
	local c = ent:AddComponent("light_point")
	c:SetColor(color)
	c:SetIntensity(intensity)
	c:SetRange(range)
	return c
end

spawn_box("room", Vec3(-20, -10, -20), Vec3(20, 10, 20))
spawn_point_light("center", Vec3(0, 0, 0), Color(1, 1, 1, 1), 8000, 10000)
scene_bvh.LightOcclusion = (mode ~= "off")
scene_bvh.Build()
local camera = render3d.GetCamera()
camera:SetPosition(Vec3(0, 1, 12))
camera:SetRotation(Quat())
camera:SetFOV(math.rad(60))
