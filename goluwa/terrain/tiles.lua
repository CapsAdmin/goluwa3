local ffi = require("ffi")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Texture = import("goluwa/render/texture.lua")
local Material = import("goluwa/render3d/material.lua")
local Color = import("goluwa/structs/color.lua")
local assets = import("goluwa/assets.lua")
local tiles = {}
local VertexType = Polygon3D.VertexType
local Index16Array = ffi.typeof("uint16_t[?]")
local Index32Array = ffi.typeof("uint32_t[?]")
local NormalBakeConstants = ffi.typeof([[
	struct {
		int height_texture;
		float step;
	}
]])
local NORMAL_BAKE_DECLARATIONS = [[
layout(push_constant, scalar) uniform TerrainNormalBakeConstants {
	int height_texture;
	float step;
} normal_bake;
]]
local NORMAL_BAKE_GLSL = [[
	vec2 texel = 1.0 / vec2(textureSize(TEXTURE(normal_bake.height_texture), 0));
	float h_left = texture(TEXTURE(normal_bake.height_texture), uv - vec2(texel.x, 0.0)).r;
	float h_right = texture(TEXTURE(normal_bake.height_texture), uv + vec2(texel.x, 0.0)).r;
	float h_down = texture(TEXTURE(normal_bake.height_texture), uv - vec2(0.0, texel.y)).r;
	float h_up = texture(TEXTURE(normal_bake.height_texture), uv + vec2(0.0, texel.y)).r;
	vec3 n = normalize(vec3(h_left - h_right, 2.0 * normal_bake.step, h_down - h_up));
	return vec4(n.x * 0.5 + 0.5, n.z * 0.5 + 0.5, n.y * 0.5 + 0.5, 1.0);
]]

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
		for x = 0, cells do
			local vertex = vertices[z * samples + x]
			vertex.position[0] = x * step
			vertex.position[1] = heights[z * samples + x]
			vertex.position[2] = z * step
			vertex.normal[0] = 0
			vertex.normal[1] = 1
			vertex.normal[2] = 0
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

function tiles.BakeNormalTexture(chunk)
	local request = chunk.request
	local size = request.detail_size
	local texture = Texture.New{
		width = size,
		height = size,
		format = "r8g8b8a8_unorm",
		mip_map_levels = 1,
		image = {
			usage = {"sampled", "transfer_dst", "transfer_src", "color_attachment"},
		},
		sampler = {
			min_filter = "linear",
			mag_filter = "linear",
			wrap_s = "clamp_to_edge",
			wrap_t = "clamp_to_edge",
		},
	}
	local height_texture = chunk.height_texture
	local step = request.size / size
	texture:Shade(
		NORMAL_BAKE_GLSL,
		{
			custom_declarations = NORMAL_BAKE_DECLARATIONS,
			textures = {height_texture},
			fragment_push_constants = {
				size = ffi.sizeof(NormalBakeConstants),
				get_data = function(_, _, pipeline)
					return NormalBakeConstants(pipeline:GetTextureIndex(height_texture), step)
				end,
			},
		}
	)
	return texture
end

local function resolve_layer_texture(value)
	if type(value) == "string" then
		local texture = assets.GetTexture(value, {config = {srgb = false}})

		if not texture then error("failed to load terrain layer texture " .. value) end

		return texture
	end

	return value
end

--[[
	layers = {
		{albedo = texture or asset path, normal = texture or asset path, scale = meters per tile, roughness = 1, ao = 1},
		... up to 4
	}
]]
function tiles.CreateMaterial(chunk, normal_texture, layers)
	local material = Material.New()
	material:SetNormalTexture(normal_texture)
	material:SetTerrainMaterialTexture(chunk.splat_texture)
	material:SetAlbedoTexture(chunk.color_texture)
	material:SetRoughnessMultiplier(1)
	material:SetMetallicMultiplier(0)
	local scales = {}
	local roughness = {}
	local ao = {}

	for i = 1, 4 do
		local layer = layers[i] or {}
		material["SetTerrainLayer" .. i .. "Texture"](material, resolve_layer_texture(layer.albedo))
		material["SetTerrainLayer" .. i .. "NormalTexture"](material, resolve_layer_texture(layer.normal))
		scales[i] = layer.scale or 1
		roughness[i] = layer.roughness or 1
		ao[i] = layer.ao or 1
	end

	material:SetTerrainLayerScales(Color(scales[1], scales[2], scales[3], scales[4]))
	material:SetTerrainLayerRoughness(Color(roughness[1], roughness[2], roughness[3], roughness[4]))
	material:SetTerrainLayerAmbientOcclusion(Color(ao[1], ao[2], ao[3], ao[4]))
	return material
end

return tiles
