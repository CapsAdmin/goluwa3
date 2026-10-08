local T = import("test/environment.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Material = import("goluwa/render3d/material.lua")
local Entity = import("goluwa/entities/entity.lua")
local billboard = import("goluwa/render3d/billboard.lua")
local lod = import("goluwa/render3d/lod.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")

local function create_red_box(half_extents)
	local poly = Polygon3D.New()
	shapes.BuildCube(poly, 1, 1.0)

	for _, vertex in ipairs(poly.Vertices) do
		vertex.pos = Vec3(
			vertex.pos.x * half_extents.x,
			vertex.pos.y * half_extents.y + half_extents.y,
			vertex.pos.z * half_extents.z
		)
	end

	poly:BuildBoundingBox()
	poly:Upload()
	local entity = Entity.New{Name = "billboard_test_box"}
	entity:AddComponent("transform")
	entity:AddComponent("visual")
	local primitive_entity = Entity.New{Name = "billboard_test_box_primitive", Parent = entity}
	primitive_entity:AddComponent("transform")
	local primitive = primitive_entity:AddComponent("visual_primitive")
	primitive:SetPolygon3D(poly)
	primitive:SetMaterial(Material.New{ColorMultiplier = Color(1, 0, 0, 1), DoubleSided = true})
	entity.visual:BuildAABB()
	return entity
end

T.Test3D("Billboard bake makes crossed quads and a flat one textured with the model from the sides and above", function()
	local entity = create_red_box(Vec3(1, 2, 0.5))
	local polygon, material = billboard.Bake(entity.visual)
	T(#polygon.Vertices)["=="](12)
	local forwards = {Vec3(0, 0, -1), Vec3(-1, 0, 0), Vec3(0, -1, 0)}

	for i, vertex in ipairs(polygon.Vertices) do
		T(vertex.normal:GetDot(forwards[math.ceil(i / 4)]))[">"](0.9)
	end

	T(polygon.LODBillboard)["=="](true)
	T(polygon.LODLevel)["=="](1)
	T(polygon.LODDistance)["=="](lod.BILLBOARD_MIN_RADII)
	local texture = material:GetAlbedoTexture()
	T(texture:GetHeight())["=="](billboard.HEIGHT)
	T(texture.mip_map_levels)[">"](1)
	local downloaded = texture:Download()
	local width = downloaded:GetWidth() / billboard.TILE_COUNT
	local height = downloaded:GetHeight()
	local _, _, _, corner_alpha = downloaded:GetPixel(0, 0)
	T(corner_alpha)["=="](0)
	local r, g, b, a = downloaded:GetPixel(math.floor(width / 2), math.floor(height / 2))
	T(a)["=="](255)
	T(r)[">"](200)
	T(g)["<"](40)
	T(b)["<"](40)
	r, g, b, a = downloaded:GetPixel(math.floor(width * 1.5), math.floor(height / 2))
	T(a)["=="](255)
	T(r)[">"](200)
	r, g, b, a = downloaded:GetPixel(math.floor(width * 2.5), math.floor(height / 2))
	T(a)["=="](255)
	T(r)[">"](200)
	entity:Remove()
end)

T.Test3D("Billboard bake keeps the aspect of the model and the quads cover its bounds", function()
	local entity = create_red_box(Vec3(2, 1, 1))
	local polygon, material = billboard.Bake(entity.visual)
	local min_x, max_x, min_y, max_y = math.huge, -math.huge, math.huge, -math.huge

	for _, vertex in ipairs(polygon.Vertices) do
		min_x, max_x = math.min(min_x, vertex.pos.x), math.max(max_x, vertex.pos.x)
		min_y, max_y = math.min(min_y, vertex.pos.y), math.max(max_y, vertex.pos.y)
	end

	T(max_y - min_y)["~"](2 * billboard.PADDING)
	T(max_x - min_x)[">="](4)
	T(material:GetAlbedoTexture():GetWidth())["=="](math.min(billboard.MAX_WIDTH, billboard.HEIGHT * 2) * billboard.TILE_COUNT)
	entity:Remove()
end)

T.Test3D("Billboard keeps its own material when the visual overrides materials", function()
	local entity = create_red_box(Vec3(1, 1, 1))
	local polygon, material = billboard.Bake(entity.visual)
	local other = Material.New{ColorMultiplier = Color(0, 1, 0, 1)}
	entity.visual:SetMaterialSlotOverrides({[0] = other})
	entity.visual:SetMaterialOverride(other)
	polygon:SetMaterialSlot(0)
	entity.visual:CreatePrimitiveEntity(polygon, material, "billboard_test_quads")
	local entries = entity.visual:GetLODRenderEntries()
	T(#entries)["=="](2)
	T(entries[1].lod_before_billboard)["=="](true)
	T(entries[2].lod_billboard)["=="](true)
	T(entries[2].polygon3d.LODBillboard)["=="](true)
	T(entity.visual:GetResolvedMaterial(entries[2]))["=="](material)
	T(entity.visual:GetResolvedMaterial(entries[1]))["=="](other)
	entity:Remove()
end)
