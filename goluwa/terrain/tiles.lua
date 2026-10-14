local ffi = require("ffi")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Material = import("goluwa/render3d/material.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local assets = import("goluwa/assets.lua")
local tiles = {}
local VertexType = Polygon3D.VertexType
local Index16Array = ffi.typeof("uint16_t[?]")
local Index32Array = ffi.typeof("uint32_t[?]")

function tiles.BuildPolygon(chunk, skirt_depth)
	local request = chunk.request
	local samples = request.samples
	local size = request.size
	local heights = chunk.heights
	local step = size / (samples - 1)
	local cells = samples - 1
	local grid_count = samples * samples
	local vertex_count = grid_count + samples * 4
	local index_count = cells * cells * 6 + cells * 4 * 6
	local vertices = VertexType(vertex_count)
	local indices = vertex_count > 65535 and Index32Array(index_count) or Index16Array(index_count)
	local uv_scale = 1 / cells

	for z = 0, cells do
		local z0 = math.max(z - 1, 0)
		local z1 = math.min(z + 1, cells)

		for x = 0, cells do
			local vertex = vertices[z * samples + x]
			local x0 = math.max(x - 1, 0)
			local x1 = math.min(x + 1, cells)
			local nx = (heights[z * samples + x0] - heights[z * samples + x1]) / ((x1 - x0) * step)
			local nz = (heights[z0 * samples + x] - heights[z1 * samples + x]) / ((z1 - z0) * step)
			local inv_length = 1 / math.sqrt(nx * nx + 1 + nz * nz)
			vertex.position[0] = x * step
			vertex.position[1] = heights[z * samples + x]
			vertex.position[2] = z * step
			vertex.normal[0] = nx * inv_length
			vertex.normal[1] = inv_length
			vertex.normal[2] = nz * inv_length
			vertex.uv[0] = x * uv_scale
			vertex.uv[1] = z * uv_scale
			vertex.tangent[0] = 1
			vertex.tangent[1] = 0
			vertex.tangent[2] = 0
			vertex.tangent[3] = -1
		end
	end

	local south = grid_count
	local north = grid_count + samples
	local west = grid_count + samples * 2
	local east = grid_count + samples * 3

	for i = 0, cells do
		ffi.copy(vertices[south + i], vertices[i], ffi.sizeof(vertices[0]))
		ffi.copy(vertices[north + i], vertices[cells * samples + i], ffi.sizeof(vertices[0]))
		ffi.copy(vertices[west + i], vertices[i * samples], ffi.sizeof(vertices[0]))
		ffi.copy(vertices[east + i], vertices[i * samples + cells], ffi.sizeof(vertices[0]))
		vertices[south + i].position[1] = vertices[south + i].position[1] - skirt_depth
		vertices[north + i].position[1] = vertices[north + i].position[1] - skirt_depth
		vertices[west + i].position[1] = vertices[west + i].position[1] - skirt_depth
		vertices[east + i].position[1] = vertices[east + i].position[1] - skirt_depth
	end

	local index = 0

	for z = 0, cells - 1 do
		for x = 0, cells - 1 do
			local p00 = z * samples + x
			local p10 = p00 + 1
			local p01 = p00 + samples
			local p11 = p01 + 1
			indices[index] = p00
			indices[index + 1] = p11
			indices[index + 2] = p01
			indices[index + 3] = p00
			indices[index + 4] = p10
			indices[index + 5] = p11
			index = index + 6
		end
	end

	for i = 0, cells - 1 do
		local e0 = i
		local e1 = i + 1
		indices[index] = e0
		indices[index + 1] = south + e0
		indices[index + 2] = e1
		indices[index + 3] = e1
		indices[index + 4] = south + e0
		indices[index + 5] = south + e1
		index = index + 6
		e0 = cells * samples + i
		e1 = e0 + 1
		indices[index] = e0
		indices[index + 1] = e1
		indices[index + 2] = north + i
		indices[index + 3] = e1
		indices[index + 4] = north + i + 1
		indices[index + 5] = north + i
		index = index + 6
		e0 = i * samples
		e1 = e0 + samples
		indices[index] = e0
		indices[index + 1] = e1
		indices[index + 2] = west + i
		indices[index + 3] = e1
		indices[index + 4] = west + i + 1
		indices[index + 5] = west + i
		index = index + 6
		e0 = i * samples + cells
		e1 = e0 + samples
		indices[index] = e0
		indices[index + 1] = east + i
		indices[index + 2] = e1
		indices[index + 3] = e1
		indices[index + 4] = east + i
		indices[index + 5] = east + i + 1
		index = index + 6
	end

	local polygon = Polygon3D.New()
	polygon:UploadVertexArray(vertices, vertex_count, indices, index_count)
	return polygon
end

local function resolve_layer_texture(value)
	if type(value) == "string" then
		local texture = assets.GetTexture(value, {config = {srgb = false}})

		if not texture then error("failed to load terrain layer texture " .. value) end

		return texture
	end

	return value
end

-- the per layer values, vec4 colors named TerrainLayer<Name> for layers 1 to 4 and TerrainLayer<Name>2 for 5 to 8. Scatter
-- only has the first set, the scatter pass does not know about the other layers
local LAYER_VALUES = {
	{"Scales", "scale", 1},
	{"Roughness", "roughness", 1},
	{"AmbientOcclusion", "ao", 1},
	{"DetailStrength", "detail", 0},
	{"AdditiveDetail", "additive_detail", 0},
	{"Specular", "specular", 1},
	{"Scatter", "scatter", 0},
	{"HeightScales", "height_scale", 0},
}

function tiles.CreateMaterial(chunk, layers, scatter_set)
	local material = Material.New()
	material:SetNormalTexture(chunk.normal_texture)
	material:SetTerrainMaterialTexture(chunk.splat_texture)
	material:SetTerrainMaterial2Texture(chunk.splat2_texture)
	material:SetTerrainBounds(Vec3(chunk.request.min_x, chunk.request.min_z, chunk.request.size))
	material:SetAlbedoTexture(chunk.color_texture)
	material:SetRoughnessMultiplier(1)
	material:SetMetallicMultiplier(0)
	local layer_count = chunk.splat2_texture and 8 or 4

	for i = 1, layer_count do
		local layer = layers[i] or {}
		material["SetTerrainLayer" .. i .. "Texture"](material, resolve_layer_texture(layer.albedo))
		material["SetTerrainLayer" .. i .. "NormalTexture"](material, resolve_layer_texture(layer.normal))
		material["SetTerrainLayer" .. i .. "HeightTexture"](material, resolve_layer_texture(layer.height))
	end

	local any_scatter = false

	for _, def in ipairs(LAYER_VALUES) do
		local name, key, default = def[1], def[2], def[3]
		local v = {}

		for i = 1, layer_count do
			local layer = layers[i] or {}
			v[i] = layer[key] or default

			if key == "height_scale" then v[i] = layer.height and layer.height_scale or 0 end
		end

		material["SetTerrainLayer" .. name](material, Color(v[1], v[2], v[3], v[4]))

		if layer_count == 8 and name ~= "Scatter" then
			material["SetTerrainLayer" .. name .. "2"](material, Color(v[5], v[6], v[7], v[8]))
		end

		if name == "Scatter" then any_scatter = v[1] > 0 or v[2] > 0 or v[3] > 0 or v[4] > 0 end
	end

	material:SetScatterSet(any_scatter and scatter_set or nil)
	return material
end

return tiles
