local ffi = require("ffi")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Material = import("goluwa/render3d/material.lua")
local Color = import("goluwa/structs/color.lua")
local media = import("goluwa/render3d/media.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local AABB = import("goluwa/structs/aabb.lua")
local assets = import("goluwa/assets.lua")
local Texture = RENDER_2D and import("goluwa/render/texture.lua")
local VertexBuffer = RENDER_2D and import("goluwa/render/vertex_buffer.lua")
local EasyPipeline = RENDER_2D and import("goluwa/render/easy_pipeline.lua")
local vertex_layout = import("goluwa/render3d/vertex_layout.lua")
local projected_decals = import("goluwa/render3d/projected_decals.lua")
local tiles = {}
local VertexType = Polygon3D.VertexType
local Index16Array = ffi.typeof("uint16_t[?]")
local Index32Array = ffi.typeof("uint32_t[?]")
local IndexBuffer = RENDER_2D and import("goluwa/render/index_buffer.lua")
local VertexSize = ffi.sizeof(VertexType(1))
local templates = {[false] = {}, [true] = {}}

local function get_template(cells, step, host, shell)
	local by_step = templates[host][cells]

	if not by_step then
		by_step = {}
		templates[host][cells] = by_step
	end

	local key = shell and -step or step
	local template = by_step[key]

	if template then return template end

	local samples = cells + 1
	local grid_count = samples * samples
	local base_start = grid_count + samples * 4
	local vertex_count = base_start + (shell and grid_count or 0)
	local index_count = cells * cells * 6 * (shell and 2 or 1) + cells * 4 * 6
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

	if shell then
		for i = grid_count, vertex_count - 1 do
			if i >= base_start then
				ffi.copy(vertices[i], vertices[i - base_start], VertexSize)
			end

			vertices[i].tangent[3] = -2
		end
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

	if shell then
		for i = 0, cells * cells * 6 - 1 do
			indices[index + i] = indices[i] + base_start
		end

		index = index + cells * cells * 6
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

	-- the tessellation topology welds corners by position: on a tile only the skirts' heights differ from the grid
	-- edge they hang from, so lowering them here welds the template like every tile of it
	local topology_vertices

	if shell then
		topology_vertices = VertexType(vertex_count)
		ffi.copy(topology_vertices, vertices, VertexSize * vertex_count)

		for i = grid_count, base_start - 1 do
			topology_vertices[i].position[1] = -1
		end
	end

	template = {
		vertices = vertices,
		vertex_count = vertex_count,
		index_count = index_count,
		uniform_extras = vertex_layout.GetUniformExtras(vertices, vertex_count),
		topology = shell and
			{
				vertices = topology_vertices,
				vertex_count = vertex_count,
				indices = indices,
				index_count = index_count,
			} or
			nil,
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
	by_step[key] = template
	return template
end

function tiles.GetShell(layers)
	local shell = 0

	for _, layer in pairs(layers) do
		local relief = (
				layer.height and
				layer.height_scale or
				0
			) * (
				layer.scale or
				1
			) + (
				layer.cover_depth or
				0
			)

		if relief > 0 then shell = math.max(shell, relief) end
	end

	return shell
end

-- the vertices are only read while the polygon uploads (it keeps its own gpu layout copy), so one array is reused
local scratch_vertices, scratch_count = nil, 0

function tiles.BuildPolygon(chunk, skirt_depth, stride, mode, shell)
	local request = chunk.request
	local full_samples = request.samples
	local heights = chunk.heights
	local step = request.size / (full_samples - 1) * stride
	local cells = (full_samples - 1) / stride
	local samples = cells + 1
	local grid_count = samples * samples
	local template = get_template(cells, step, mode == "host", shell and shell > 0)
	local vertex_count = template.vertex_count

	if vertex_count > scratch_count then
		scratch_vertices, scratch_count = VertexType(vertex_count), vertex_count
	end

	local vertices = scratch_vertices
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

	if shell and shell > 0 then
		local base_start = grid_count + samples * 4

		for i = 0, grid_count - 1 do
			ffi.copy(vertices[base_start + i].position, vertices[i].position, 12)
			ffi.copy(vertices[base_start + i].normal, vertices[i].normal, 12)
		end
	end

	local polygon = Polygon3D.New()
	polygon:SetGridCells(cells)
	polygon.TopologySource = template.topology
	polygon:UploadVertexArray(
		vertices,
		vertex_count,
		template.indices,
		template.index_count,
		false,
		mode or "owned",
		AABB(
			-(shell or 0) * 1.1,
			chunk.min_height - skirt_depth,
			-(shell or 0) * 1.1,
			request.size + (shell or 0) * 1.1,
			chunk.max_height + (shell or 0) * 1.1,
			request.size + (shell or 0) * 1.1
		)
	)
	return polygon
end

do
	local pipeline
	local job = {}

	local function get_pipeline()
		if pipeline then return pipeline end

		pipeline = EasyPipeline.Compute{
			name = "terrain_tile_vertices",
			LocalSize = {x = 64, y = 1, z = 1},
			block = {
				{"heights", "uint64_t"},
				{"vertices", "uint64_t"},
				{"samples", "int"},
				{"step", "float"},
				{"skirt_depth", "float"},
				{"shell", "int"},
			},
			write = function(self, block)
				block.heights = job.heights
				block.vertices = job.vertices
				block.samples = job.samples
				block.step = job.step
				block.skirt_depth = job.skirt_depth
				block.shell = job.shell
				return block
			end,
			shader = [[
				layout(buffer_reference, scalar) readonly buffer TileHeights { float h[]; };
				layout(buffer_reference, scalar) buffer TileVertices { float v[]; };
				]] .. vertex_layout.BuildGlslAccessors("tile_vertices", "TileVertices", true) .. [[

				// the heights have a border of one sample around the tile's samples
				float tile_height(TileHeights heights, int x, int z) {
					return heights.h[(z + 1) * (compute.samples + 2) + x + 1];
				}

				void main() {
					int samples = compute.samples;
					int cells = samples - 1;
					int grid_count = samples * samples;
					int skirt_end = grid_count + samples * 4;
					int count = skirt_end + (compute.shell != 0 ? grid_count : 0);
					int i = int(gl_GlobalInvocationID.x);

					if (i >= count) return;

					int x;
					int z;
					float drop = 0.0;
					float side = -1.0;

					if (i < grid_count) {
						x = i % samples;
						z = i / samples;
					} else if (i < skirt_end) {
						int edge = (i - grid_count) / samples;
						int k = (i - grid_count) % samples;
						x = edge < 2 ? k : (edge == 2 ? 0 : cells);
						z = edge == 0 ? 0 : (edge == 1 ? cells : k);
						drop = compute.skirt_depth;

						if (compute.shell != 0) side = -2.0;
					} else {
						x = (i - skirt_end) % samples;
						z = (i - skirt_end) / samples;
						side = -2.0;
					}

					TileHeights heights = TileHeights(compute.heights);
					float step = compute.step;
					int x0 = max(x - 1, 0);
					int x1 = min(x + 1, cells);
					int z0 = max(z - 1, 0);
					int z1 = min(z + 1, cells);
					float nx = (tile_height(heights, x0, z) - tile_height(heights, x1, z)) / (float(x1 - x0) * step);
					float nz = (tile_height(heights, x, z0) - tile_height(heights, x, z1)) / (float(z1 - z0) * step);
					TileVertices vertices = TileVertices(compute.vertices);
					uint vertex = uint(i);
					tile_vertices_set_position(vertices, vertex, vec3(float(x) * step, tile_height(heights, x, z) - drop, float(z) * step));
					tile_vertices_set_normal(vertices, vertex, normalize(vec3(nx, 1.0, nz)));
					tile_vertices_set_uv(vertices, vertex, vec2(float(x), float(z)) / float(cells));
					tile_vertices_set_tangent(vertices, vertex, vec4(1.0, 0.0, 0.0, side));
				}
			]],
		}
		return pipeline
	end

	local function get_vertex_count(samples, shell)
		return samples * samples * (shell and 2 or 1) + samples * 4
	end

	-- a tile's vertex buffer that only the gpu fills (RecordGpuMesh); its chunk keeps it
	function tiles.NewGpuVertexBuffer(samples, shell)
		return VertexBuffer.New(
			get_vertex_count(samples, shell),
			vertex_layout.GetAttributes(0, "core"),
			"terrain tile vertices",
			"device"
		)
	end

	-- records writing a tile's vertices (the layout of BuildPolygon at stride 1) from its baked heights, (samples + 2)^2
	-- floats with a border of one sample, at heights_address; the caller orders it after the heights and before use
	function tiles.RecordGpuMesh(cmd, heights_address, vertex_buffer, samples, step, skirt_depth, shell)
		job.heights = heights_address
		job.vertices = vertex_buffer.buffer:GetDeviceAddress()
		job.samples = samples
		job.step = step
		job.skirt_depth = skirt_depth
		job.shell = shell and 1 or 0
		get_pipeline():Dispatch(cmd, math.ceil(get_vertex_count(samples, shell) / 64), 1, 1)
	end
end

-- the polygon of a chunk whose vertices the bake wrote on the gpu (chunk.vertex_buffer)
function tiles.BuildGpuPolygon(chunk, skirt_depth, shell)
	local request = chunk.request
	local cells = request.samples - 1
	local template = get_template(cells, request.size / cells, false, shell > 0)
	local polygon = Polygon3D.New()
	polygon:SetGridCells(cells)
	polygon.TopologySource = template.topology
	polygon:UseVertexBuffer(
		chunk.vertex_buffer,
		template.indices,
		AABB(
			-shell * 1.1,
			chunk.min_height - skirt_depth,
			-shell * 1.1,
			request.size + shell * 1.1,
			chunk.max_height + shell * 1.1,
			request.size + shell * 1.1
		),
		template.uniform_extras
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
	{"ScalesSideX", "scale_side_x", 1, "scale"},
	{"ScalesSideZ", "scale_side_z", 1, "scale"},
	{"Roughness", "roughness", 1},
	{"DetailStrength", "detail", 0},
	{"DetailStrengthSideX", "detail_side_x", 0, "detail"},
	{"DetailStrengthSideZ", "detail_side_z", 0, "detail"},
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
	{"FadeDistanceXY", "fade_distance_xy", 0},
	{"AntiTiling", "anti_tiling", 0},
	{"CoverSlope", "cover_slope", 0},
	{"CoverStart", "cover_start", 0},
	{"CoverRange", "cover_range", 1000},
	{"CoverPower", "cover_power", 1},
	{"CoverBlend", "cover_blend", 0.05},
	{"CoverDepth", "cover_depth", 0},
	{"Medium", "medium", 0},
	{"DetailBumpTiling", "detail_bump_tiling", 0},
	{"DetailBumpScale", "detail_bump_scale", 0},
}
local TERRAIN_WIND_EMISSION = Vec3(0.15, 0.3, 0.4)

function tiles.CreateMaterial(chunk, layers, scatter_set, source, shell)
	local material = Material.New()
	material.terrain_tile = true
	material:SetNormalTexture(chunk.normal_texture)
	material:SetTerrainMaterialTexture(chunk.splat_texture)
	material:SetTerrainMaterial2Texture(chunk.splat2_texture)
	material:SetTerrainBounds(Vec3(chunk.request.min_x, chunk.request.min_z, chunk.request.size))
	material:SetAlbedoTexture(chunk.color_texture)
	material:SetTerrainTriplanarSharpness(source.TriplanarSharpness)
	material:SetDecalReceiver(projected_decals.RECEIVE_TERRAIN)
	material:SetRoughnessMultiplier(1)
	material:SetMetallicMultiplier(0)
	material:SetAcousticWindEmission(TERRAIN_WIND_EMISSION)

	if shell and shell > 0 then
		chunk.height_texture = chunk.height_texture or
			Texture.New{
				buffer = chunk.border_heights,
				width = chunk.request.samples + 2,
				height = chunk.request.samples + 2,
				format = "r32_sfloat",
			}
		material:SetTerrainHeightTexture(chunk.height_texture)
		material:SetTerrainShell(shell)
	end

	local layer_count = chunk.splat2_texture and 8 or 4

	for i = 1, layer_count do
		local layer = layers[i] or {}
		material["SetTerrainLayer" .. i .. "Texture"](material, resolve_layer_texture(layer.albedo))
		material["SetTerrainLayer" .. i .. "NormalTexture"](material, resolve_layer_texture(layer.normal))
		material["SetTerrainLayer" .. i .. "HeightTexture"](material, resolve_layer_texture(layer.height))
		material["SetTerrainLayer" .. i .. "DetailTexture"](material, resolve_layer_texture(layer.detail_bump))
		material["SetTerrainLayer" .. i .. "SideXTexture"](material, resolve_layer_texture(layer.albedo_side_x or layer.albedo))
		material["SetTerrainLayer" .. i .. "SideXNormalTexture"](material, resolve_layer_texture(layer.normal_side_x or layer.normal))
		material["SetTerrainLayer" .. i .. "SideZTexture"](material, resolve_layer_texture(layer.albedo_side_z or layer.albedo))
		material["SetTerrainLayer" .. i .. "SideZNormalTexture"](material, resolve_layer_texture(layer.normal_side_z or layer.normal))
	end

	local any_scatter = false
	local medium_density = 0

	for _, def in ipairs(LAYER_VALUES) do
		local name, key, default, fallback = def[1], def[2], def[3], def[4]
		local v = {}

		for i = 1, layer_count do
			local layer = layers[i] or {}
			v[i] = layer[key] or fallback and layer[fallback] or default

			if key == "height_scale" then v[i] = layer.height and layer.height_scale or 0 end

			if key == "medium" then
				medium_density = math.max(medium_density, v[i])
				v[i] = v[i] > 0 and 1 or 0
			end
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

	if medium_density > 0 then
		material:SetMedium(media.TERRAIN_MEDIUM)
		material:SetMediumDensity(medium_density)
	end

	return material
end

return tiles
