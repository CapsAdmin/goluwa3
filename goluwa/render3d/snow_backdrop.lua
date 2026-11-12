local event = import("goluwa/event.lua")
local Material = import("goluwa/render3d/material.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local gbuffer_instancing = import("goluwa/render3d/gbuffer_instancing.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local surface_weather = import("goluwa/render3d/surface_weather.lua")
local snow_backdrop = {}
snow_backdrop.RADIUS = 90
local polygon
local material
local matrix = Matrix44()

event.AddListener("Draw3DGeometry", "snow_backdrop", function()
	if not surface_weather.snow_map or surface_weather.snow_depth <= 0 then
		return
	end

	if not polygon then
		polygon = Polygon3D.New()
		shapes.BuildSphere(polygon, 1, 24, 12)
		polygon:BuildBoundingBox()
		polygon:Upload()
		material = Material.New{SnowBackdrop = true, DoubleSided = true, Roughness = 0.75, Metallic = 0}
	end

	local position = render3d.GetCamera():GetPosition()
	local radius = snow_backdrop.RADIUS * render3d.GetSnappedViewScale()
	matrix.m00 = radius
	matrix.m11 = radius
	matrix.m22 = radius
	matrix:SetTranslation(position.x, position.y, position.z)
	gbuffer_instancing.Queue(polygon, material, matrix, matrix)
end)

return snow_backdrop
