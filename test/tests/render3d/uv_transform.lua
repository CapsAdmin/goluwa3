local T = import("test/environment.lua")
local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Material = import("goluwa/render3d/material.lua")
local vmt_material = import("goluwa/source_engine/vmt_material.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")

local function create_back_facing_quad()
	local cube = Polygon3D.New()
	shapes.BuildCube(cube, 0.5, 1.0)
	local poly = Polygon3D.New()

	for i = 1, #cube.Vertices, 3 do
		local a, b, c = cube.Vertices[i], cube.Vertices[i + 1], cube.Vertices[i + 2]

		if a.pos.z < 0 and b.pos.z < 0 and c.pos.z < 0 then
			poly:AddVertex(a)
			poly:AddVertex(b)
			poly:AddVertex(c)
		end
	end

	T(#poly.Vertices)["=="](6)
	poly:BuildBoundingBox()
	poly:Upload()
	return poly
end

local function spawn(polygon3d, material)
	local entity = Entity.New{Name = "double_sided_quad"}
	entity:AddComponent("transform")
	entity.transform:SetPosition(Vec3(0, 0, -4))
	entity:AddComponent("visual")
	local primitive = Entity.New{Name = "double_sided_quad_primitive", Parent = entity}
	primitive:AddComponent("transform")
	local visual_primitive = primitive:AddComponent("visual_primitive")
	visual_primitive:SetPolygon3D(polygon3d)
	visual_primitive:SetMaterial(material)
	entity.visual:BuildAABB()
	entity.visual:SetUseOcclusionCulling(false)
	return entity
end

local function center_albedo(draw, translate)
	local camera = render3d.GetCamera()
	camera:SetFOV(math.rad(90))
	camera:SetNearZ(0.1)
	camera:SetFarZ(100)
	camera:SetPosition(Vec3(0, 0, 0))
	camera:SetRotation(Quat():Identity())
	local material = Material.New{
		Albedo = "return vec4(uv.x < 0.5 ? 1.0 : 0.0, uv.x < 0.5 ? 0.0 : 1.0, 0.0, 1.0);",
		DoubleSided = true,
	}
	vmt_material.SetTextureTransform(
		material,
		"BaseTexture",
		"center 0 0 scale 1 1 rotate 0 translate " .. translate .. " 0"
	)
	local entity = spawn(create_back_facing_quad(), material)
	local ok, err = pcall(draw)
	entity:Remove()

	if not ok then error(err, 0) end

	local size = render.GetRenderImageSize()
	return gbuffer_layout.GetTexture("albedo"):GetPixel(math.floor(size.x / 2), math.floor(size.y / 2))
end

T.Test3D("Graphics render3d base texture transform shifts the albedo lookup", function(draw)
	local r1, g1 = center_albedo(draw, 0.25)
	local r2, g2 = center_albedo(draw, -0.25)
	T(g1)[">"](r1 + 100)
	T(r2)[">"](g2 + 100)
end)
