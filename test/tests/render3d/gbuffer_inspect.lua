local T = import("test/environment.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_inspect = import("goluwa/render3d/gbuffer_inspect.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Material = import("goluwa/render3d/material.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")

local function inspect(draw, material, view)
	local passes = {
		import("goluwa/render3d/passes/gbuffer.lua"),
		import("goluwa/render3d/passes/gbuffer_inspect.lua"),
		import("goluwa/render3d/passes/blit.lua"),
	}
	render3d.Initialize{passes = passes}
	local camera = render3d.GetCamera()
	camera:SetFOV(math.rad(90))
	camera:SetNearZ(0.1)
	camera:SetFarZ(100)
	camera:SetPosition(Vec3(0, 0, 0))
	camera:SetRotation(Quat():Identity())
	local polygon3d = Polygon3D.New()
	shapes.BuildCube(polygon3d, 1)
	polygon3d:BuildBoundingBox()
	polygon3d:Upload()
	local entity = Entity.New{Name = "gbuffer_inspect_cube"}
	entity:AddComponent("transform")
	entity.transform:SetPosition(Vec3(0, 0, -4))
	entity:AddComponent("visual")
	local primitive = Entity.New{Name = "gbuffer_inspect_cube_primitive", Parent = entity}
	primitive:AddComponent("transform")
	local visual_primitive = primitive:AddComponent("visual_primitive")
	visual_primitive:SetPolygon3D(polygon3d)
	visual_primitive:SetMaterial(material)
	entity.visual:BuildAABB()
	gbuffer_inspect.SetView(view)
	local ok, err = pcall(draw)
	local framebuffer = render3d.pipelines.gbuffer_inspect and render3d.pipelines.gbuffer_inspect:GetFramebuffer()
	local downloaded = ok and framebuffer and framebuffer:GetAttachment(1):Download()
	local size = render3d.GetRenderSize()
	local center = downloaded and {downloaded:GetPixelFloat(math.floor(size.x / 2), math.floor(size.y / 2))}
	gbuffer_inspect.SetView(nil)
	entity:Remove()
	polygon3d:Remove()
	render3d.Initialize{
		passes = {
			import("goluwa/render3d/passes/gbuffer.lua"),
			import("goluwa/render3d/passes/blit.lua"),
		},
	}

	if not ok then error(err, 0) end

	return center
end

T.Test3D("Graphics render3d gbuffer inspect shows the decoded fields", function(draw)
	local material = Material.New{
		ColorMultiplier = Color(0.5, 0.25, 0.75, 1),
		MetallicMultiplier = 0.25,
		SpecularMultiplier = 1.5,
	}
	local metallic = inspect(draw, material, {mode = "field", name = "metallic"})
	T(metallic[1])["~"](0.25, 0.01)
	-- specular is stored over 0 to 2, the view shows it relative to that
	local specular = inspect(draw, material, {mode = "field", name = "specular"})
	T(specular[1])["~"](0.75, 0.02)
	local albedo = inspect(draw, material, {mode = "field", name = "albedo"})
	T(albedo[1])["~"](0.5, 0.02)
	T(albedo[2])["~"](0.25, 0.02)
	T(albedo[3])["~"](0.75, 0.02)
end)

T.Test3D("Graphics render3d gbuffer inspect draws the entries of a sheet", function(draw)
	local material = Material.New{MetallicMultiplier = 0.25, SpecularMultiplier = 1.5}
	-- one entry is a grid of one tile, that is the whole screen
	local metallic = inspect(draw, material, {mode = "sheet", names = {"metallic"}})
	T(metallic[1])["~"](0.25, 0.01)
	local specular = inspect(draw, material, {mode = "sheet", names = {"specular"}})
	T(specular[1])["~"](0.75, 0.02)
end)

T.Test("gbuffer inspect groups the fields in sheets", function()
	local by_name = {}

	for _, sheet in ipairs(gbuffer_inspect.GetSheets()) do
		by_name[sheet.name] = sheet
	end

	T(by_name.normal.primary.name)["=="]("normal")
	T(#by_name.transmission.entries)["=="](4)
	T(by_name.clearcoat.primary.name)["=="]("clearcoat")
	T(by_name.specular.entries[2].name)["=="]("secondary_specular")
	T(by_name.depth.primary.name)["=="]("depth")
end)
