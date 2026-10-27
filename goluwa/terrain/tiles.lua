local ffi = require("ffi")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Material = import("goluwa/render3d/material.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local AABB = import("goluwa/structs/aabb.lua")
local assets = import("goluwa/assets.lua")
local tiles = {}
local VertexType = Polygon3D.VertexType
local Index16Array = ffi.typeof("uint16_t[?]")
local Index32Array = ffi.typeof("uint32_t[?]")
local IndexBuffer = RENDER_2D and import("goluwa/render/index_buffer.lua")
local VertexSize = ffi.sizeof(VertexType(1))
local templates = {[false] = {}, [true] = {}}

local function get_template(cells, step, host)
	local by_step = templates[host][cells]

	if not by_step then
		by_step = {}
		templates[host][cells] = by_step
	end

	local template = by_step[step]

	if template then return template end

	local samples = cells + 1
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
			vertex.position[2] = z * step
			vertex.normal[1] = 1
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
		ffi.copy(vertices[south + i], vertices[i], VertexSize)
		ffi.copy(vertices[north + i], vertices[cells * samples + i], VertexSize)
		ffi.copy(vertices[west + i], vertices[i * samples], VertexSize)
		ffi.copy(vertices[east + i], vertices[i * samples + cells], VertexSize)
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

	template = {
		vertices = vertices,
		vertex_count = vertex_count,
		index_count = index_count,
		indices = IndexBuffer and
			IndexBuffer.FromPointer(
				indices,
				index_count,
				vertex_count > 65535 and "uint32_t" or "uint16_t",
				"terrain tile indices",
				host
			) or
			indices,
	}
	by_step[step] = template
	return template
end

function tiles.BuildPolygon(chunk, skirt_depth, stride, mode)
	local request = chunk.request
	local full_samples = request.samples
	local heights = chunk.heights
	local step = request.size / (full_samples - 1) * stride
	local cells = (full_samples - 1) / stride
	local samples = cells + 1
	local grid_count = samples * samples
	local template = get_template(cells, step, mode == "host")
	local vertex_count = template.vertex_count
	local vertices = VertexType(vertex_count)
	ffi.copy(vertices, template.vertices, VertexSize * vertex_count)

	for z = 0, cells do
		local z0 = math.max(z - 1, 0)
		local z1 = math.min(z + 1, cells)

		for x = 0, cells do
			local vertex = vertices[z * samples + x]
			local x0 = math.max(x - 1, 0)
			local x1 = math.min(x + 1, cells)
			local nx = (
					heights[z * stride * full_samples + x0 * stride] - heights[z * stride * full_samples + x1 * stride]
				) / (
					(
						x1 - x0
					) * step
				)
			local nz = (
					heights[z0 * stride * full_samples + x * stride] - heights[z1 * stride * full_samples + x * stride]
				) / (
					(
						z1 - z0
					) * step
				)
			local inv_length = 1 / math.sqrt(nx * nx + 1 + nz * nz)
			local height = heights[z * stride * full_samples + x * stride]

			if stride > 1 then
				for sz = math.max(z * stride - stride, 0), math.min(z * stride + stride, full_samples - 1) do
					for sx = math.max(x * stride - stride, 0), math.min(x * stride + stride, full_samples - 1) do
						height = math.min(height, heights[sz * full_samples + sx])
					end
				end
			end

			vertex.position[1] = height
			vertex.normal[0] = nx * inv_length
			vertex.normal[1] = inv_length
			vertex.normal[2] = nz * inv_length
		end
	end

	for i = 0, cells do
		local south = vertices[grid_count + i]
		local north = vertices[grid_count + samples + i]
		local west = vertices[grid_count + samples * 2 + i]
		local east = vertices[grid_count + samples * 3 + i]
		local edge = vertices[i]
		south.position[1] = edge.position[1] - skirt_depth
		south.normal[0] = edge.normal[0]
		south.normal[1] = edge.normal[1]
		south.normal[2] = edge.normal[2]
		edge = vertices[cells * samples + i]
		north.position[1] = edge.position[1] - skirt_depth
		north.normal[0] = edge.normal[0]
		north.normal[1] = edge.normal[1]
		north.normal[2] = edge.normal[2]
		edge = vertices[i * samples]
		west.position[1] = edge.position[1] - skirt_depth
		west.normal[0] = edge.normal[0]
		west.normal[1] = edge.normal[1]
		west.normal[2] = edge.normal[2]
		edge = vertices[i * samples + cells]
		east.position[1] = edge.position[1] - skirt_depth
		east.normal[0] = edge.normal[0]
		east.normal[1] = edge.normal[1]
		east.normal[2] = edge.normal[2]
	end

	local polygon = Polygon3D.New()
	polygon:SetGridCells(cells)
	polygon:UploadVertexArray(
		vertices,
		vertex_count,
		template.indices,
		template.index_count,
		false,
		mode or "owned",
		AABB(
			0,
			chunk.min_height - skirt_depth,
			0,
			request.size,
			chunk.max_height,
			request.size
		)
	)
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

local LAYER_VALUES = {
	{"Scales", "scale", 1},
	{"Roughness", "roughness", 1},
	{"AmbientOcclusion", "ao", 1},
	{"DetailStrength", "detail", 0},
	{"AdditiveDetail", "additive_detail", 0},
	{"Specular", "specular", 1},
	{"Scatter", "scatter", 0},
	{"HeightScales", "height_scale", 0},
	{"SlopeMin", "slope_min", -1},
	{"SlopeMax", "slope_max", 2},
	{"SlopeBlend", "slope_blend", 0.01},
	{"HeightBlend", "height_blend", 0},
	{"FarScales", "far_scale", 0},
	{"FarDistances", "far_distance", 0},
	{"FarScaleB", "far_scale_b", 0},
	{"FarDistanceB", "far_distance_b", 0},
	{"FadeDistance", "fade_distance", 0},
	{"AntiTiling", "anti_tiling", 0},
	{"CoverSlope", "cover_slope", 0},
	{"CoverStart", "cover_start", 0},
	{"CoverRange", "cover_range", 1000},
	{"CoverPower", "cover_power", 1},
	{"CoverBlend", "cover_blend", 0.05},
}

function tiles.CreateMaterial(chunk, layers, scatter_set, source)
	local material = Material.New()
	material:SetNormalTexture(chunk.normal_texture)
	material:SetTerrainMaterialTexture(chunk.splat_texture)
	material:SetTerrainMaterial2Texture(chunk.splat2_texture)
	material:SetTerrainBounds(Vec3(chunk.request.min_x, chunk.request.min_z, chunk.request.size))
	material:SetAlbedoTexture(chunk.color_texture)
	material:SetTerrainTriplanarSharpness(source.TriplanarSharpness)
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

		if name == "Scatter" then
			any_scatter = v[1] > 0 or v[2] > 0 or v[3] > 0 or v[4] > 0
		end
	end

	material:SetScatterSet(any_scatter and scatter_set or nil)
	return material
end

return tiles
