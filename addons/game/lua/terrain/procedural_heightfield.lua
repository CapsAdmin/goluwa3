local ffi = require("ffi")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Texture = import("goluwa/render/texture.lua")
local Material = import("goluwa/render3d/material.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local ProceduralTerrainSource = import("addons/game/lua/terrain/procedural_terrain_source.lua")
local ProceduralTerrainTileCache = import("addons/game/lua/terrain/procedural_terrain_tile_cache.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Entity = import("goluwa/ecs/entity.lua")
local timer = import("goluwa/timer.lua")
local ProceduralHeightfield = {}
ProceduralHeightfield.__index = ProceduralHeightfield

local function is_valid(obj)
	return obj and obj.IsValid and obj:IsValid()
end

local function as_vec2(value, fallback)
	if value == nil then return fallback end

	if type(value) == "table" and value.x then return value end

	return Vec2() + value
end

local function get_color_components(color)
	if color.r then return color.r, color.g, color.b end

	return color[1] or color.x or 1,
	color[2] or color.y or 1,
	color[3] or color.z or 1
end

local function to_color4(color, alpha)
	local r, g, b = get_color_components(color)
	return Color(r, g, b, alpha or 1)
end

local function make_bake_texture(size, height, format)
	height = height or size
	return Texture.New{
		width = size,
		height = height,
		format = format or "r8g8b8a8_unorm",
		mip_map_levels = "auto",
		image = {
			usage = {"storage", "sampled", "transfer_dst", "transfer_src", "color_attachment"},
		},
		sampler = {
			min_filter = "linear",
			mag_filter = "linear",
			wrap_s = "clamp_to_edge",
			wrap_t = "clamp_to_edge",
		},
	}
end

local function make_height_bake_texture(size, height)
	return make_bake_texture(size, height, "r32_sfloat")
end

local function make_displacement_bake_texture(size, height)
	return make_bake_texture(size, height, "r16g16b16a16_sfloat")
end

local function get_height01(tex, x, y)
	local width = tex.width
	x = math.clamp(math.floor(x), 0, width - 1)
	y = math.clamp(math.floor(y), 0, tex.height - 1)

	if tex.format == "r32_sfloat" then
		local fpixels = ffi.cast("float*", tex.pixels)
		return fpixels[y * width + x]
	end

	local r, g, b, a = tex:GetRawPixelColor(x, y)
	return (((r + g + b + a) / 4) / 255)
end

local function clone_vertex(pos, uv, normal)
	return {
		pos = Vec3(pos.x, pos.y, pos.z),
		uv = Vec2(uv.x, uv.y),
		normal = Vec3(normal.x, normal.y, normal.z),
	}
end

local function get_seed_offsets(seed)
	seed = tonumber(seed) or 1337
	return Vec2(math.sin(seed * 12.9898) * 16384.0, math.cos(seed * 78.2330) * 16384.0)
end

local function intersect_bounds(a, b)
	if not a or not b then return nil end

	local min_x = math.max(a.min_x, b.min_x)
	local max_x = math.min(a.max_x, b.max_x)
	local min_z = math.max(a.min_z, b.min_z)
	local max_z = math.min(a.max_z, b.max_z)

	if min_x >= max_x or min_z >= max_z then return nil end

	return {
		min_x = min_x,
		max_x = max_x,
		min_z = min_z,
		max_z = max_z,
	}
end

local function build_bounds_key(bounds)
	if not bounds then return "full" end

	return string.format(
		"%.3f:%.3f:%.3f:%.3f",
		bounds.min_x,
		bounds.max_x,
		bounds.min_z,
		bounds.max_z
	)
end

local function get_visible_patch_rects(chunk_bounds, clip_bounds)
	local overlap = intersect_bounds(chunk_bounds, clip_bounds)

	if not overlap then return {chunk_bounds} end

	local rects = {}

	local function add_rect(min_x, max_x, min_z, max_z)
		if min_x >= max_x or min_z >= max_z then return end

		rects[#rects + 1] = {
			min_x = min_x,
			max_x = max_x,
			min_z = min_z,
			max_z = max_z,
		}
	end

	add_rect(chunk_bounds.min_x, chunk_bounds.max_x, chunk_bounds.min_z, overlap.min_z)
	add_rect(chunk_bounds.min_x, chunk_bounds.max_x, overlap.max_z, chunk_bounds.max_z)
	add_rect(chunk_bounds.min_x, overlap.min_x, overlap.min_z, overlap.max_z)
	add_rect(overlap.max_x, chunk_bounds.max_x, overlap.min_z, overlap.max_z)
	return rects
end

function ProceduralHeightfield.New(config)
	config = config or {}
	local self = setmetatable({}, ProceduralHeightfield)
	self.Name = config.Name or "procedural_heightfield"
	self.Seed = config.Seed or 1337
	self.Source = config.Source or
		config.TerrainSource or
		ProceduralTerrainSource.New{
			Seed = self.Seed,
			TerrainProfile = config.TerrainProfile or config.TerrainStyle,
			HeightScale = config.HeightScale or 512,
			VerticalOffset = config.VerticalOffset or 0,
			MaterialBands = config.MaterialBands,
		}
	self.SeedOffset = self.Source.SeedOffset or get_seed_offsets(self.Seed)
	self.TerrainProfile = self.Source.TerrainProfile
	self.ShaderHeader = self.Source:GetShaderHeader()
	self.ChunkRings = config.ChunkRings
	self.FarTerrain = config.FarTerrain
	self.DebugView = config.DebugView or "off"
	self.DebugRingColors = config.DebugRingColors or
		{
			{0.98, 0.28, 0.22},
			{0.16, 0.72, 0.98},
			{0.24, 0.84, 0.32},
			{0.96, 0.80, 0.22},
			{0.82, 0.34, 0.94},
		}
	self.ChunkWorldSize = config.ChunkWorldSize or 1024
	self.HeightScale = self.Source.HeightScale
	self.VerticalOffset = self.Source.VerticalOffset
	self.UVScale = config.UVScale or (Vec2() + 1)
	self.UpdateInterval = config.UpdateInterval or 0.05
	self.BuildsPerUpdate = config.BuildsPerUpdate or 1
	self.Roughness = config.Roughness or 0.92
	self.Metallic = config.Metallic or 0.02
	self.SkirtDepth = config.SkirtDepth or math.max(32, self.HeightScale * 0.12)
	self.MaterialBands = self.Source.MaterialBands
	self.TileCache = config.TileCache or ProceduralTerrainTileCache.New{Source = self.Source}
	self.LODs = config.LODs or
		{
			{radius = 0, mesh_resolution = Vec2() + 96, texture_size = 512},
			{radius = 1, mesh_resolution = Vec2() + 64, texture_size = 256},
			{radius = 3, mesh_resolution = Vec2() + 32, texture_size = 128},
			{radius = 5, mesh_resolution = Vec2() + 16, texture_size = 64},
		}
	self.ActiveChunks = {}
	self.DebugMaterialCache = {}
	self.ChunkRenderCache = {}
	self.FarRenderCache = {}
	self.TimerId = self.Name .. "_update"
	self.Root = nil
	self.FarState = nil
	return self
end

function ProceduralHeightfield:GetHeightSampleTile(min_x, min_z, step_x, step_z, sample_width, sample_height)
	return self.TileCache:GetHeightTile{
		min_x = min_x,
		min_z = min_z,
		span_x = step_x * math.max(0, sample_width - 1),
		span_z = step_z * math.max(0, sample_height - 1),
		width = sample_width,
		height = sample_height,
	}
end

function ProceduralHeightfield:IsDebugRingViewEnabled()
	return self.DebugView == "rings"
end

function ProceduralHeightfield:GetDebugRingColor(ring_index, config_index)
	local palette = self.DebugRingColors
	local index = (ring_index or config_index or 1) - 1
	return palette[(index % #palette) + 1]
end

function ProceduralHeightfield:GetOrCreateDebugMaterial(config, ring_index, config_index)
	local cache_key = tostring(ring_index or config_index or 1)
	local material = self.DebugMaterialCache[cache_key]

	if material then return material end

	local debug_color = to_color4(self:GetDebugRingColor(ring_index, config_index), 1)
	material = Material.New()
	material:SetColorMultiplier(debug_color)
	material:SetEmissiveMultiplier(to_color4(self:GetDebugRingColor(ring_index, config_index), 0.18))
	material:SetRoughnessMultiplier(config.roughness or self.Roughness)
	material:SetMetallicMultiplier(config.metallic or self.Metallic)
	self.DebugMaterialCache[cache_key] = material
	return material
end

function ProceduralHeightfield:HasChunkRings()
	return type(self.ChunkRings) == "table" and self.ChunkRings[1] ~= nil
end

function ProceduralHeightfield:HasFarTerrain()
	return type(self.FarTerrain) == "table"
end

function ProceduralHeightfield:GetMaxChunkRadius()
	return self.LODs[#self.LODs].radius
end

function ProceduralHeightfield:GetLODIndexForDistance(distance)
	for i = 1, #self.LODs do
		if distance <= self.LODs[i].radius then return i end
	end

	return nil
end

function ProceduralHeightfield:GetChunkCoord(world_value, chunk_world_size)
	return math.floor(world_value / (chunk_world_size or self.ChunkWorldSize))
end

function ProceduralHeightfield:GetChunkKey(chunk_x, chunk_z, ring_index)
	if ring_index ~= nil then
		return ring_index .. ":" .. chunk_x .. ":" .. chunk_z
	end

	return chunk_x .. ":" .. chunk_z
end

function ProceduralHeightfield:GetChunkRenderCacheKey(chunk_x, chunk_z, config_index, ring_index, clip_bounds)
	return self:GetChunkKey(chunk_x, chunk_z, ring_index) .. "|" .. tostring(config_index or 0) .. "|" .. build_bounds_key(clip_bounds)
end

function ProceduralHeightfield:GetChunkCenter(chunk_x, chunk_z, chunk_world_size)
	chunk_world_size = chunk_world_size or self.ChunkWorldSize
	return Vec3(
		(chunk_x + 0.5) * chunk_world_size,
		self.VerticalOffset,
		(chunk_z + 0.5) * chunk_world_size
	)
end

function ProceduralHeightfield:BuildHeightShader(chunk_min_x, chunk_min_z, chunk_world_size)
	chunk_world_size = chunk_world_size or self.ChunkWorldSize
	return string.format(
		[[
		vec2 world_pos = vec2(%.6f, %.6f) + uv * %.6f + vec2(%.6f, %.6f);
		float h = sampleTerrainHeight01(world_pos);
		return vec4(h, h, h, 1.0);
	]],
		chunk_min_x,
		chunk_min_z,
		chunk_world_size,
		self.SeedOffset.x,
		self.SeedOffset.y
	)
end

function ProceduralHeightfield:BuildHeightSampleShader(chunk_min_x, chunk_min_z, sample_width, sample_height, step_x, step_z)
	return string.format(
		[[
		vec2 pixel = vec2(uv.x * %.6f - 0.5, uv.y * %.6f - 0.5);
		vec2 world_pos = vec2(%.6f, %.6f) + (pixel - vec2(1.0, 1.0)) * vec2(%.6f, %.6f) + vec2(%.6f, %.6f);
		float h = sampleTerrainHeight01(world_pos);
		return vec4(h, h, h, 1.0);
	]],
		sample_width,
		sample_height,
		chunk_min_x,
		chunk_min_z,
		step_x,
		step_z,
		self.SeedOffset.x,
		self.SeedOffset.y
	)
end

function ProceduralHeightfield:BuildAlbedoShader(chunk_min_x, chunk_min_z, chunk_world_size)
	chunk_world_size = chunk_world_size or self.ChunkWorldSize
	return self.Source:BuildAlbedoShader(chunk_min_x, chunk_min_z, chunk_world_size)
end

function ProceduralHeightfield:BuildBoundsAlbedoShader(bounds)
	return self:BuildAlbedoShader(bounds.min_x, bounds.min_z, bounds.max_x - bounds.min_x)
end

function ProceduralHeightfield:BuildBoundsHeightShader(bounds)
	return self:BuildHeightShader(bounds.min_x, bounds.min_z, bounds.max_x - bounds.min_x)
end

function ProceduralHeightfield:BuildDisplacementShader(chunk_min_x, chunk_min_z, chunk_world_size)
	chunk_world_size = chunk_world_size or self.ChunkWorldSize
	return self.Source:BuildDisplacementShader(chunk_min_x, chunk_min_z, chunk_world_size)
end

function ProceduralHeightfield:BuildBoundsDisplacementShader(bounds)
	return self:BuildDisplacementShader(bounds.min_x, bounds.min_z, bounds.max_x - bounds.min_x)
end

function ProceduralHeightfield:BuildNormalShader(chunk_min_x, chunk_min_z, chunk_world_size, texture_size, normal_strength)
	chunk_world_size = chunk_world_size or self.ChunkWorldSize
	texture_size = math.max(1, texture_size or 128)
	normal_strength = normal_strength or 1
	return string.format(
		[[
		vec2 world_pos = vec2(%.6f, %.6f) + uv * %.6f + vec2(%.6f, %.6f);
		float sample_step = %.6f;
		float h_left = sampleTerrainHeight01(world_pos - vec2(sample_step, 0.0)) * %.6f;
		float h_right = sampleTerrainHeight01(world_pos + vec2(sample_step, 0.0)) * %.6f;
		float h_down = sampleTerrainHeight01(world_pos - vec2(0.0, sample_step)) * %.6f;
		float h_up = sampleTerrainHeight01(world_pos + vec2(0.0, sample_step)) * %.6f;
		vec3 tangent_normal = normalize(vec3((h_left - h_right) * %.6f, (h_down - h_up) * %.6f, 2.0 * sample_step));
		return vec4(tangent_normal * 0.5 + 0.5, 1.0);
	]],
		chunk_min_x,
		chunk_min_z,
		chunk_world_size,
		self.SeedOffset.x,
		self.SeedOffset.y,
		chunk_world_size / texture_size,
		self.HeightScale,
		self.HeightScale,
		self.HeightScale,
		self.HeightScale,
		normal_strength,
		normal_strength
	)
end

function ProceduralHeightfield:BuildBoundsNormalShader(bounds, texture_size, normal_strength)
	return self:BuildNormalShader(
		bounds.min_x,
		bounds.min_z,
		bounds.max_x - bounds.min_x,
		texture_size,
		normal_strength
	)
end

function ProceduralHeightfield:ApplyMaterialDisplacement(material, config, height_shader)
	local displacement_scale = tonumber(config.displacement_scale) or 0

	if displacement_scale <= 0 then return false end

	local texture_size = config.displacement_texture_size or config.texture_size or 128
	local height_tex = make_displacement_bake_texture(texture_size)
	height_tex:Shade(height_shader, {header = self.ShaderHeader})
	material:SetHeightTexture(height_tex)
	material:SetHeightScale(displacement_scale)
	material:SetHeightCenter(config.height_center or 0.5)
	material:SetHeightLayers(config.height_layers or 24)
	material:SetTessellationFactor(config.tessellation_factor or 1)
	return true
end

function ProceduralHeightfield:CreateChunkMaterial(config, chunk_min_x, chunk_min_z, chunk_world_size, ring_index, config_index)
	if self:IsDebugRingViewEnabled() then
		return self:GetOrCreateDebugMaterial(config, ring_index, config_index)
	end

	local texture_size = config.texture_size or 128
	local normal_tex_size = config.normal_texture_size or texture_size
	local normal_strength = config.normal_strength or 1
	local albedo_tex = make_bake_texture(texture_size)
	albedo_tex:Shade(
		self:BuildAlbedoShader(chunk_min_x, chunk_min_z, chunk_world_size),
		{header = self.Source:GetMaterialShaderHeader()}
	)
	local normal_tex = make_bake_texture(normal_tex_size)
	normal_tex:Shade(
		self:BuildNormalShader(chunk_min_x, chunk_min_z, chunk_world_size, normal_tex_size, normal_strength),
		{header = self.ShaderHeader}
	)
	local material = Material.New()
	material:SetAlbedoTexture(albedo_tex)
	local uses_displacement = self:ApplyMaterialDisplacement(
		material,
		config,
		self:BuildDisplacementShader(chunk_min_x, chunk_min_z, chunk_world_size)
	)

	if not uses_displacement then material:SetNormalTexture(normal_tex) end

	material:SetRoughnessMultiplier(config.roughness or self.Roughness)
	material:SetMetallicMultiplier(config.metallic or self.Metallic)
	return material
end

function ProceduralHeightfield:CreateBoundsMaterial(config, bounds, ring_index, config_index)
	if self:IsDebugRingViewEnabled() then
		return self:GetOrCreateDebugMaterial(config, ring_index, config_index)
	end

	local texture_size = config.texture_size or 128
	local normal_tex_size = config.normal_texture_size or texture_size
	local normal_strength = config.normal_strength or 1
	local albedo_tex = make_bake_texture(texture_size)
	albedo_tex:Shade(
		self:BuildBoundsAlbedoShader(bounds),
		{header = self.Source:GetMaterialShaderHeader()}
	)
	local normal_tex = make_bake_texture(normal_tex_size)
	normal_tex:Shade(
		self:BuildBoundsNormalShader(bounds, normal_tex_size, normal_strength),
		{header = self.ShaderHeader}
	)
	local material = Material.New()
	material:SetAlbedoTexture(albedo_tex)
	local uses_displacement = self:ApplyMaterialDisplacement(material, config, self:BuildBoundsDisplacementShader(bounds))

	if not uses_displacement then material:SetNormalTexture(normal_tex) end

	material:SetRoughnessMultiplier(config.roughness or self.Roughness)
	material:SetMetallicMultiplier(config.metallic or self.Metallic)
	return material
end

function ProceduralHeightfield:AddSkirtQuad(polygon, top0, top1, outward_axis)
	local drop = Vec3(0, -self.SkirtDepth, 0)
	local bottom0 = clone_vertex(top0.pos + drop, top0.uv, top0.normal)
	local bottom1 = clone_vertex(top1.pos + drop, top1.uv, top1.normal)

	if outward_axis == "west" or outward_axis == "south" then
		polygon:AddVertex(clone_vertex(top0.pos, top0.uv, top0.normal))
		polygon:AddVertex(clone_vertex(top1.pos, top1.uv, top1.normal))
		polygon:AddVertex(bottom0)
		polygon:AddVertex(clone_vertex(top1.pos, top1.uv, top1.normal))
		polygon:AddVertex(bottom1)
		polygon:AddVertex(bottom0)
	else
		polygon:AddVertex(clone_vertex(top0.pos, top0.uv, top0.normal))
		polygon:AddVertex(bottom0)
		polygon:AddVertex(clone_vertex(top1.pos, top1.uv, top1.normal))
		polygon:AddVertex(clone_vertex(top1.pos, top1.uv, top1.normal))
		polygon:AddVertex(bottom0)
		polygon:AddVertex(bottom1)
	end
end

function ProceduralHeightfield:CreateChunkPolygon(config, chunk_min_x, chunk_min_z, chunk_world_size, clip_bounds)
	chunk_world_size = chunk_world_size or self.ChunkWorldSize
	local chunk_bounds = {
		min_x = chunk_min_x,
		max_x = chunk_min_x + chunk_world_size,
		min_z = chunk_min_z,
		max_z = chunk_min_z + chunk_world_size,
	}
	return self:CreateBoundsPolygon(config, chunk_bounds, clip_bounds)
end

function ProceduralHeightfield:CreateBoundsPolygon(config, bounds, clip_bounds)
	local polygon = Polygon3D.New()
	local resolution = as_vec2(config.mesh_resolution, Vec2() + 32)
	local base_resolution_x = math.max(1, math.floor((resolution.x or 0) + 0.5))
	local base_resolution_z = math.max(1, math.floor((resolution.y or 0) + 0.5))
	local smoothing = math.clamp(tonumber(config.height_smoothing) or 0, 0, 1)
	local base_width = bounds.max_x - bounds.min_x
	local base_depth = bounds.max_z - bounds.min_z
	local center_x = (bounds.min_x + bounds.max_x) * 0.5
	local center_z = (bounds.min_z + bounds.max_z) * 0.5
	local patch_rects = get_visible_patch_rects(bounds, clip_bounds)

	local function approx_equal(a, b)
		return math.abs(a - b) <= 0.0001
	end

	for _, rect in ipairs(patch_rects) do
		local patch_width = rect.max_x - rect.min_x
		local patch_depth = rect.max_z - rect.min_z
		local resolution_x = math.max(1, math.floor(base_resolution_x * (patch_width / base_width) + 0.5))
		local resolution_z = math.max(1, math.floor(base_resolution_z * (patch_depth / base_depth) + 0.5))
		local step_x = patch_width / resolution_x
		local step_z = patch_depth / resolution_z
		local sample_width = resolution_x + 3
		local sample_height = resolution_z + 3
		local height_tile = self:GetHeightSampleTile(
			rect.min_x - step_x,
			rect.min_z - step_z,
			step_x,
			step_z,
			sample_width,
			sample_height
		)
		local height_samples = height_tile.samples
		local stride = resolution_x + 1
		local vertex_rows = {}

		local function sample_height_value(x, y)
			x = math.clamp(x, 0, sample_width - 1)
			y = math.clamp(y, 0, sample_height - 1)
			local index = y * sample_width + x + 1

			if smoothing <= 0 then return height_samples[index] end

			local center = height_samples[index]
			local sum = 0
			local count = 0

			for oy = -1, 1 do
				for ox = -1, 1 do
					local sample_index = math.clamp(y + oy, 0, sample_height - 1) * sample_width + math.clamp(x + ox, 0, sample_width - 1) + 1
					sum = sum + height_samples[sample_index]
					count = count + 1
				end
			end

			return center + ((sum / count) - center) * smoothing
		end

		for z = 0, resolution_z do
			for x = 0, resolution_x do
				local h_left = sample_height_value(x + 0, z + 1)
				local h_right = sample_height_value(x + 2, z + 1)
				local h_down = sample_height_value(x + 1, z + 0)
				local h_up = sample_height_value(x + 1, z + 2)
				local h_center = sample_height_value(x + 1, z + 1)
				local world_x = rect.min_x + x * step_x
				local world_z = rect.min_z + z * step_z
				local pos = Vec3(
					world_x - center_x,
					h_center * self.HeightScale - self.HeightScale * 0.5,
					world_z - center_z
				)
				local uv = Vec2((world_x - bounds.min_x) / base_width, (world_z - bounds.min_z) / base_depth) * self.UVScale
				local dz = Vec3(0, (h_up - h_down) * self.HeightScale, step_z * 2)
				local dx = Vec3(step_x * 2, (h_right - h_left) * self.HeightScale, 0)
				local normal = dz:Cross(dx):GetNormalized()
				local index = z * stride + x + 1
				vertex_rows[index] = {pos = pos, uv = uv, normal = normal}
			end
		end

		local function get_vertex(x, z)
			return vertex_rows[z * stride + x + 1]
		end

		for z = 0, resolution_z - 1 do
			for x = 0, resolution_x - 1 do
				local p00 = get_vertex(x, z)
				local p10 = get_vertex(x + 1, z)
				local p01 = get_vertex(x, z + 1)
				local p11 = get_vertex(x + 1, z + 1)
				polygon:AddVertex(clone_vertex(p00.pos, p00.uv, p00.normal))
				polygon:AddVertex(clone_vertex(p10.pos, p10.uv, p10.normal))
				polygon:AddVertex(clone_vertex(p01.pos, p01.uv, p01.normal))
				polygon:AddVertex(clone_vertex(p10.pos, p10.uv, p10.normal))
				polygon:AddVertex(clone_vertex(p11.pos, p11.uv, p11.normal))
				polygon:AddVertex(clone_vertex(p01.pos, p01.uv, p01.normal))
			end
		end

		if approx_equal(rect.min_x, bounds.min_x) then
			for z = 0, resolution_z - 1 do
				self:AddSkirtQuad(polygon, get_vertex(0, z), get_vertex(0, z + 1), "west")
			end
		end

		if approx_equal(rect.max_x, bounds.max_x) then
			for z = 0, resolution_z - 1 do
				self:AddSkirtQuad(polygon, get_vertex(resolution_x, z), get_vertex(resolution_x, z + 1), "east")
			end
		end

		if approx_equal(rect.min_z, bounds.min_z) then
			for x = 0, resolution_x - 1 do
				self:AddSkirtQuad(polygon, get_vertex(x, 0), get_vertex(x + 1, 0), "north")
			end
		end

		if approx_equal(rect.max_z, bounds.max_z) then
			for x = 0, resolution_x - 1 do
				self:AddSkirtQuad(polygon, get_vertex(x, resolution_z), get_vertex(x + 1, resolution_z), "south")
			end
		end
	end

	polygon:BuildBoundingBox()
	polygon:Upload()
	return polygon
end

function ProceduralHeightfield:GetCurrentFarHoleBounds(position)
	local far = self.FarTerrain or {}

	if self:HasChunkRings() then
		local ring = self.ChunkRings[#self.ChunkRings]
		local chunk_world_size = ring.chunk_world_size or self.ChunkWorldSize
		local center_chunk_x = self:GetChunkCoord(position.x, chunk_world_size)
		local center_chunk_z = self:GetChunkCoord(position.z, chunk_world_size)
		local radius = ring.radius or 0
		return {
			min_x = (center_chunk_x - radius) * chunk_world_size,
			max_x = (center_chunk_x + radius + 1) * chunk_world_size,
			min_z = (center_chunk_z - radius) * chunk_world_size,
			max_z = (center_chunk_z + radius + 1) * chunk_world_size,
		}
	end

	local half_size = far.inner_half_size or (self.ChunkWorldSize * 2)
	return {
		min_x = position.x - half_size,
		max_x = position.x + half_size,
		min_z = position.z - half_size,
		max_z = position.z + half_size,
	}
end

function ProceduralHeightfield:GetFarBounds(position)
	local far = self.FarTerrain
	local snap_size = far.snap_size or far.outer_half_size or self.ChunkWorldSize
	local center_x = math.floor(position.x / snap_size + 0.5) * snap_size
	local center_z = math.floor(position.z / snap_size + 0.5) * snap_size
	local half_size = far.outer_half_size or (self.ChunkWorldSize * 16)
	return {
		min_x = center_x - half_size,
		max_x = center_x + half_size,
		min_z = center_z - half_size,
		max_z = center_z + half_size,
	}
end

function ProceduralHeightfield:GetFarRenderData(position)
	local far = self.FarTerrain
	local bounds = self:GetFarBounds(position)
	local hole_bounds = self:GetCurrentFarHoleBounds(position)
	local cache_key = build_bounds_key(bounds) .. "|" .. build_bounds_key(hole_bounds)
	local cached = self.FarRenderCache[cache_key]

	if cached then return cached, bounds, hole_bounds, cache_key end

	local debug_index = self:HasChunkRings() and (#self.ChunkRings + 1) or 1
	local render_data = {
		polygon = self:CreateBoundsPolygon(far, bounds, hole_bounds),
		material = self:CreateBoundsMaterial(far, bounds, debug_index, debug_index),
	}
	self.FarRenderCache[cache_key] = render_data
	return render_data, bounds, hole_bounds, cache_key
end

function ProceduralHeightfield:UpdateFarTerrain(position)
	if not self:HasFarTerrain() or not is_valid(self.Root) then return end

	local far = self.FarTerrain
	local render_data, bounds, hole_bounds, state_key = self:GetFarRenderData(position)

	if
		self.FarState and
		self.FarState.key == state_key and
		is_valid(self.FarState.entity)
	then
		return
	end

	if self.FarState and is_valid(self.FarState.entity) then
		self.FarState.entity:Remove()
	end

	local entity = Entity.New{
		Name = string.format("%s_far_terrain", self.Name),
		Parent = self.Root,
	}
	local transform = entity:AddComponent("transform")
	transform:SetPosition(
		Vec3(
			(bounds.min_x + bounds.max_x) * 0.5,
			self.VerticalOffset,
			(bounds.min_z + bounds.max_z) * 0.5
		)
	)
	local visual = entity:AddComponent("visual")
	visual:SetCastShadows(far.cast_shadows == true)
	visual:SetUseOcclusionCulling(false)
	local primitive_entity = Entity.New{
		Name = string.format("%s_far_terrain_primitive", self.Name),
		Parent = entity,
	}
	primitive_entity:AddComponent("transform")
	local primitive = primitive_entity:AddComponent("visual_primitive")
	primitive:SetPolygon3D(render_data.polygon)
	primitive:SetMaterial(render_data.material)
	visual:BuildAABB()
	self.FarState = {
		key = state_key,
		bounds = bounds,
		hole_bounds = hole_bounds,
		entity = entity,
	}
end

function ProceduralHeightfield:RemoveChunk(chunk)
	if not chunk then return end

	if is_valid(chunk.entity) then chunk.entity:Remove() end
end

function ProceduralHeightfield:GetOrCreateChunkRenderData(chunk_x, chunk_z, config_index, chunk_config, ring_index, clip_bounds)
	local cache_key = self:GetChunkRenderCacheKey(chunk_x, chunk_z, config_index, ring_index, clip_bounds)
	local cached = self.ChunkRenderCache[cache_key]

	if cached then return cached end

	local chunk_world_size = chunk_config.chunk_world_size or self.ChunkWorldSize
	local chunk_min_x = chunk_x * chunk_world_size
	local chunk_min_z = chunk_z * chunk_world_size
	local render_data = {
		polygon = self:CreateChunkPolygon(chunk_config, chunk_min_x, chunk_min_z, chunk_world_size, clip_bounds),
		material = self:CreateChunkMaterial(
			chunk_config,
			chunk_min_x,
			chunk_min_z,
			chunk_world_size,
			ring_index,
			config_index
		),
	}
	self.ChunkRenderCache[cache_key] = render_data
	return render_data
end

function ProceduralHeightfield:BuildChunk(chunk_x, chunk_z, config_index, chunk_config, ring_index, clip_bounds)
	if not is_valid(self.Root) then return nil end

	local chunk_world_size = chunk_config.chunk_world_size or self.ChunkWorldSize
	local chunk_key = self:GetChunkKey(chunk_x, chunk_z, ring_index)
	local render_data = self:GetOrCreateChunkRenderData(chunk_x, chunk_z, config_index, chunk_config, ring_index, clip_bounds)
	local entity = Entity.New{
		Name = string.format("%s_chunk_%s_cfg_%d", self.Name, chunk_key, config_index),
		Parent = self.Root,
	}
	local transform = entity:AddComponent("transform")
	transform:SetPosition(self:GetChunkCenter(chunk_x, chunk_z, chunk_world_size))
	local visual = entity:AddComponent("visual")
	visual:SetCastShadows(chunk_config.cast_shadows == true)
	visual:SetUseOcclusionCulling(false)
	local primitive_entity = Entity.New{
		Name = string.format("%s_chunk_primitive_%s", self.Name, chunk_key),
		Parent = entity,
	}
	primitive_entity:AddComponent("transform")
	local primitive = primitive_entity:AddComponent("visual_primitive")
	primitive:SetPolygon3D(render_data.polygon)
	primitive:SetMaterial(render_data.material)
	visual:BuildAABB()
	return {
		key = chunk_key,
		chunk_x = chunk_x,
		chunk_z = chunk_z,
		config_index = config_index,
		ring_index = ring_index,
		clip_key = build_bounds_key(clip_bounds),
		entity = entity,
	}
end

function ProceduralHeightfield:GatherDesiredFixedChunks(position)
	local center_chunk_x = self:GetChunkCoord(position.x)
	local center_chunk_z = self:GetChunkCoord(position.z)
	local desired = {}
	local pending = {}
	local max_radius = self:GetMaxChunkRadius()

	for dz = -max_radius, max_radius do
		for dx = -max_radius, max_radius do
			local distance = math.max(math.abs(dx), math.abs(dz))
			local lod_index = self:GetLODIndexForDistance(distance)

			if lod_index then
				local chunk_x = center_chunk_x + dx
				local chunk_z = center_chunk_z + dz
				local key = self:GetChunkKey(chunk_x, chunk_z)
				desired[key] = {
					chunk_x = chunk_x,
					chunk_z = chunk_z,
					config_index = lod_index,
					ring_index = nil,
					chunk_config = self.LODs[lod_index],
					distance = distance,
				}
			end
		end
	end

	for key, chunk in pairs(self.ActiveChunks) do
		local want = desired[key]

		if not want or want.config_index ~= chunk.config_index then
			self:RemoveChunk(chunk)
			self.ActiveChunks[key] = nil
		end
	end

	for key, want in pairs(desired) do
		if not self.ActiveChunks[key] then pending[#pending + 1] = want end
	end

	return pending
end

function ProceduralHeightfield:GatherDesiredRingChunks(position)
	local desired = {}
	local pending = {}
	local covered_bounds = nil

	local function get_ring_bounds(center_chunk_x, center_chunk_z, radius, chunk_world_size)
		return {
			min_x = (center_chunk_x - radius) * chunk_world_size,
			max_x = (center_chunk_x + radius + 1) * chunk_world_size,
			min_z = (center_chunk_z - radius) * chunk_world_size,
			max_z = (center_chunk_z + radius + 1) * chunk_world_size,
		}
	end

	local function get_chunk_bounds(chunk_x, chunk_z, chunk_world_size)
		return {
			min_x = chunk_x * chunk_world_size,
			max_x = (chunk_x + 1) * chunk_world_size,
			min_z = chunk_z * chunk_world_size,
			max_z = (chunk_z + 1) * chunk_world_size,
		}
	end

	local function is_fully_covered(bounds, coverage)
		if not coverage then return false end

		return bounds.min_x >= coverage.min_x and
			bounds.max_x <= coverage.max_x and
			bounds.min_z >= coverage.min_z and
			bounds.max_z <= coverage.max_z
	end

	for ring_index, ring in ipairs(self.ChunkRings) do
		local chunk_world_size = ring.chunk_world_size or self.ChunkWorldSize
		local center_chunk_x = self:GetChunkCoord(position.x, chunk_world_size)
		local center_chunk_z = self:GetChunkCoord(position.z, chunk_world_size)
		local radius = ring.radius or 0

		for dz = -radius, radius do
			for dx = -radius, radius do
				local distance = math.max(math.abs(dx), math.abs(dz))

				if distance <= radius then
					local chunk_x = center_chunk_x + dx
					local chunk_z = center_chunk_z + dz
					local chunk_bounds = get_chunk_bounds(chunk_x, chunk_z, chunk_world_size)
					local clip_bounds = intersect_bounds(chunk_bounds, covered_bounds)

					if not is_fully_covered(chunk_bounds, covered_bounds) then
						local key = self:GetChunkKey(chunk_x, chunk_z, ring_index)
						desired[key] = {
							chunk_x = chunk_x,
							chunk_z = chunk_z,
							config_index = ring_index,
							ring_index = ring_index,
							chunk_config = ring,
							clip_bounds = clip_bounds,
							clip_key = build_bounds_key(clip_bounds),
							distance = distance,
						}
					end
				end
			end
		end

		covered_bounds = get_ring_bounds(center_chunk_x, center_chunk_z, radius, chunk_world_size)
	end

	for key, chunk in pairs(self.ActiveChunks) do
		local want = desired[key]

		if
			not want or
			want.config_index ~= chunk.config_index or
			want.clip_key ~= chunk.clip_key
		then
			self:RemoveChunk(chunk)
			self.ActiveChunks[key] = nil
		end
	end

	for key, want in pairs(desired) do
		if not self.ActiveChunks[key] then pending[#pending + 1] = want end
	end

	return pending
end

function ProceduralHeightfield:UpdateChunkSet()
	local camera = render3d.GetCamera()

	if not camera then return end

	local position = camera:GetPosition()
	local pending = self:HasChunkRings() and
		self:GatherDesiredRingChunks(position) or
		self:GatherDesiredFixedChunks(position)

	table.sort(pending, function(a, b)
		if a.distance == b.distance then return a.config_index < b.config_index end

		return a.distance < b.distance
	end)

	for i = 1, math.min(self.BuildsPerUpdate, #pending) do
		local want = pending[i]
		local chunk = self:BuildChunk(
			want.chunk_x,
			want.chunk_z,
			want.config_index,
			want.chunk_config,
			want.ring_index,
			want.clip_bounds
		)

		if chunk then self.ActiveChunks[chunk.key] = chunk end
	end

	self:UpdateFarTerrain(position)
end

function ProceduralHeightfield:Start()
	self:Stop()
	self.Root = Entity.New{Name = self.Name}
	self.Root:AddComponent("transform")

	timer.Repeat(
		self.TimerId,
		self.UpdateInterval,
		0,
		function()
			if not is_valid(self.Root) then return true end

			self:UpdateChunkSet()
		end
	)

	self:UpdateChunkSet()
	return self
end

function ProceduralHeightfield:Stop()
	timer.RemoveTimer(self.TimerId)

	for key, chunk in pairs(self.ActiveChunks) do
		self:RemoveChunk(chunk)
		self.ActiveChunks[key] = nil
	end

	if self.FarState and is_valid(self.FarState.entity) then
		self.FarState.entity:Remove()
	end

	self.FarState = nil

	if is_valid(self.Root) then self.Root:Remove() end

	self.Root = nil
	return self
end

return ProceduralHeightfield
