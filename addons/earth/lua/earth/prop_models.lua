local ffi = require("ffi")
local assets = import("goluwa/assets.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Material = import("goluwa/render3d/material.lua")
local tint_mesh = import("lua/earth/tint_mesh.lua")
local prop_models = {}
local VertexType = Polygon3D.VertexType
local Index32Array = ffi.typeof("uint32_t[?]")
local material
-- name: {r, g, b (linear), {cx, cz, y0, y1, bottom half x, z, top half x, z}, ...}
prop_models.MODELS = {
	power_tower = {
		0.16,
		0.17,
		0.18,
		{0, 0, 0, 30, 3, 3, 0.7, 0.7},
		{0, 0, 22, 23, 6, 0.35, 6, 0.35},
		{0, 0, 26.5, 27.5, 4.5, 0.35, 4.5, 0.35},
	},
	power_pole = {
		0.5,
		0.49,
		0.47,
		{0, 0, 0, 9, 0.15, 0.15, 0.1, 0.1},
		{0, 0, 8.2, 8.35, 0.8, 0.06, 0.8, 0.06},
	},
	street_lamp = {
		0.2,
		0.2,
		0.21,
		{0, 0, 0, 8, 0.09, 0.09, 0.06, 0.06},
		{0.75, 0, 7.8, 7.9, 0.75, 0.04, 0.75, 0.04},
		{1.4, 0, 7.6, 7.8, 0.3, 0.14, 0.3, 0.14},
	},
	traffic_signals = {
		0.05,
		0.05,
		0.05,
		{0, 0, 0, 3.5, 0.07, 0.07, 0.07, 0.07},
		{0, 0, 3.5, 4.5, 0.17, 0.14, 0.17, 0.14},
	},
	bus_stop = {
		0.35,
		0.38,
		0.4,
		{0, -0.7, 0, 2.4, 1.5, 0.04, 1.5, 0.04},
		{0, 0, 2.4, 2.5, 1.6, 0.8, 1.6, 0.8},
		{-1.5, 0.6, 0, 2.4, 0.04, 0.04, 0.04, 0.04},
		{1.5, 0.6, 0, 2.4, 0.04, 0.04, 0.04, 0.04},
	},
	mast = {0.3, 0.29, 0.28, {0, 0, 0, 45, 2, 2, 0.3, 0.3}},
}

function prop_models.GetPath(name)
	return "models/earth/" .. name .. ".lua"
end

local function build(definition)
	local mesh = tint_mesh.New()
	tint_mesh.SetColor(mesh, definition[1], definition[2], definition[3])

	for i = 4, #definition do
		local b = definition[i]
		tint_mesh.AddTaperedBox(mesh, b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8])
	end

	local vertices = VertexType(mesh.count)
	ffi.copy(vertices, mesh.vertices, mesh.count * tint_mesh.VERTEX_SIZE)
	local indices = Index32Array(mesh.index_count)
	ffi.copy(indices, mesh.indices, mesh.index_count * 4)
	local polygon = Polygon3D.New()
	polygon:UploadVertexArray(vertices, mesh.count, indices, mesh.index_count, false, "owned", nil, "uint32_t")

	if not material then
		material = Material.New()
		material:SetVertexTint(true)
		material:SetRoughnessMultiplier(0.7)
		material:SetMetallicMultiplier(0)
	end

	return {{mesh = polygon, material = material}}
end

for name, definition in pairs(prop_models.MODELS) do
	local path = prop_models.GetPath(name)
	assets.RegisterVirtualAsset(
		path,
		{
			category = "models",
			kind = "lua",
			load = function()
				return {
					name = name,
					kind = "procedural_model",
					create_primitives = function()
						return build(definition)
					end,
				}
			end,
		}
	)
end

return prop_models
