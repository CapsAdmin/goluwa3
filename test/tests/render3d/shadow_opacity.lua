local T = import("test/environment.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Material = import("goluwa/render3d/material.lua")
local Visual = import("goluwa/entities/components/visual.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Entity = import("goluwa/entities/entity.lua")
local TRANSLUCENT_FLAG = 2

T.Test("Graphics render3d translucent materials stop the share of light their alpha covers", function()
	local material = Material.New{Translucent = true, ColorMultiplier = Color(1, 1, 1, 0.75)}
	T(material:GetShadowOpacity())["~"](0.75)
	T(material:GetSoupShadowOpacity())["~"](0.75)
	T(bit.band(material:GetShadowFlags(), TRANSLUCENT_FLAG))["=="](TRANSLUCENT_FLAG)
end)

T.Test("Graphics render3d additive materials stop no light", function()
	local material = Material.New{Additive = true, Translucent = true}
	T(material:GetShadowOpacity())["=="](0)
	T(material:GetSoupShadowOpacity())["=="](0)
	T(bit.band(material:GetShadowFlags(), TRANSLUCENT_FLAG))["=="](TRANSLUCENT_FLAG)
end)

T.Test("Graphics render3d refracting materials stop what their faces reflect and their tint absorbs", function()
	local clear = Material.New{Refraction = 1}
	T(clear:GetShadowOpacity())["~"](0.1)
	T(bit.band(clear:GetShadowFlags(), TRANSLUCENT_FLAG))["=="](TRANSLUCENT_FLAG)
	local tinted = Material.New{Refraction = 1, ColorMultiplier = Color(0.4, 0.7, 1, 1)}
	T(tinted:GetShadowOpacity() > clear:GetShadowOpacity())["=="](true)
	T(tinted:GetShadowOpacity() < 1)["=="](true)
	local half = Material.New{Refraction = 0.5}
	T(half:GetShadowOpacity())["~"](0.55)
end)

T.Test("Graphics render3d the triangle soup alpha tests a material without a texture by its color", function()
	local cut = Material.New{AlphaTest = true, ColorMultiplier = Color(1, 1, 1, 0.3)}
	T(cut:GetSoupShadowOpacity())["=="](0)
	local solid = Material.New{AlphaTest = true, ColorMultiplier = Color(1, 1, 1, 0.8)}
	T(solid:GetSoupShadowOpacity())["=="](1)
	T(Material.New():GetSoupShadowOpacity())["=="](1)
end)

T.Test3D("Graphics render3d only see through materials with an albedo texture have a shadow texture", function()
	local Texture = import("goluwa/render/texture.lua")
	local texture = Texture.New{width = 1, height = 1, format = "r8g8b8a8_unorm"}
	T(Material.New{AlphaTest = true}:HasShadowTexture())["=="](false)
	T(Material.New{AlphaTest = true, AlbedoTexture = texture}:HasShadowTexture())["=="](true)
	T(Material.New{Translucent = true, AlbedoTexture = texture}:HasShadowTexture())["=="](true)
	T(Material.New{AlbedoTexture = texture}:HasShadowTexture())["=="](false)
	T(Material.New{Translucent = true, Additive = true, AlbedoTexture = texture}:HasShadowTexture())["=="](false)
	T(Material.New{AlphaTest = true, AlbedoTexture = texture, AlbedoAlphaIsEmissive = true}:HasShadowTexture())["=="](false)
end)

T.Test("Graphics render3d the soup shadow generation follows what a material's opacity changes to", function()
	local material = Material.New{ColorMultiplier = Color(1, 1, 1, 0.5)}
	local generation = Material.shadow_generation
	material:SetTranslucent(true)
	T(Material.shadow_generation)["=="](generation + 1)
	material:SetColorMultiplier(Color(1, 1, 1, 0.5))
	T(Material.shadow_generation)["=="](generation + 1)
	material:SetColorMultiplier(Color(1, 1, 1, 0.25))
	T(Material.shadow_generation)["=="](generation + 2)
end)

T.Test3D("Graphics render3d a visual moves to the translucent pass when its material turns translucent", function()
	local polygon3d = Polygon3D.New()
	polygon3d:CreateCube(1)
	polygon3d:BuildBoundingBox()
	polygon3d:Upload()
	local material = Material.New()
	local entity = Entity.New{Name = "turns_translucent"}
	entity:AddComponent("transform")
	entity:AddComponent("visual")
	local primitive = Entity.New{Name = "turns_translucent_primitive", Parent = entity}
	primitive:AddComponent("transform")
	local visual_primitive = primitive:AddComponent("visual_primitive")
	visual_primitive:SetPolygon3D(polygon3d)
	visual_primitive:SetMaterial(material)
	entity.visual:BuildAABB()
	Visual.Library.InvalidateSceneAcceleration()
	Visual.Library.GetVisibleVisuals()
	T(entity.visual.HasTranslucentRenderEntries)["=="](false)
	T(entity.visual.HasOpaqueRenderEntries)["=="](true)
	material:SetTranslucent(true)
	Visual.Library.GetVisibleVisuals()
	T(entity.visual.HasTranslucentRenderEntries)["=="](true)
	T(entity.visual.HasOpaqueRenderEntries)["=="](false)
	T(entity.visual.translucent_registry_index ~= nil)["=="](true)
	material:SetTranslucent(false)
	Visual.Library.GetVisibleVisuals()
	T(entity.visual.HasTranslucentRenderEntries)["=="](false)
	T(entity.visual.translucent_registry_index == nil)["=="](true)
	entity:Remove()
end)
