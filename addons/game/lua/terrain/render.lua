local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Texture = import("goluwa/render/texture.lua")
local Material = import("goluwa/render3d/material.lua")
local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local Color = import("goluwa/structs/color.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Entity = import("goluwa/ecs/entity.lua")
local timer = import("goluwa/timer.lua")
local ffi = require("ffi")
local ProceduralTerrainHybridRenderer = {}
ProceduralTerrainHybridRenderer.__index = ProceduralTerrainHybridRenderer
local approx_equal
local build_trim_key

local function is_valid(obj)
	return obj and obj.IsValid and obj:IsValid()
end

local function merge_shade_config(base, extra)
	if not base then return extra end

	if not extra then return base end

	local merged = {}

	for key, value in pairs(base) do
		merged[key] = value
	end

	for key, value in pairs(extra) do
		merged[key] = value
	end

	return merged
end

local function get_mesh_segments(mesh_resolution)
	if mesh_resolution == nil then return 1, 1 end

	if type(mesh_resolution) == "number" then
		local segments = math.max(math.floor(mesh_resolution), 1)
		return segments, segments
	end

	local x = mesh_resolution.x or mesh_resolution[1] or 1
	local y = mesh_resolution.y or mesh_resolution[2] or x
	return math.max(math.floor(x), 1), math.max(math.floor(y), 1)
end

local function get_mesh_resolution_key(mesh_resolution)
	local segments_x, segments_y = get_mesh_segments(mesh_resolution)
	return segments_x .. ":" .. segments_y
end

local function patch_has_tag(patch_type, tag)
	if not patch_type or patch_type == "interior" then return false end

	for token in patch_type:gmatch("[^+]+") do
		if token == tag then return true end
	end

	return false
end

local function get_patch_tags(patch_type)
	local tags = {}

	if not patch_type or patch_type == "interior" then return tags end

	for token in patch_type:gmatch("[^+]+") do
		tags[#tags + 1] = token
	end

	table.sort(tags)
	return tags
end

local function classify_patch_variant(patch_type, trim_rect)
	local tags = get_patch_tags(patch_type)
	local inner = {}
	local outer = {}

	for i = 1, #tags do
		local tag = tags[i]

		if tag:find("^inner_") then
			inner[#inner + 1] = tag
		elseif tag:find("^outer_") then
			outer[#outer + 1] = tag
		end
	end

	local variant = {
		patch_type = patch_type or "interior",
		trim_rect = trim_rect,
		tags = tags,
		inner = inner,
		outer = outer,
		kind = "interior",
		key = patch_type or "interior",
	}

	if trim_rect then
		variant.kind = "trim"
		variant.key = (patch_type or "interior") .. ":" .. build_trim_key(trim_rect)
	end

	if not trim_rect and #inner >= 2 then
		variant.kind = "inner_corner"
		variant.key = "inner_corner:" .. table.concat(inner, "+")
	elseif not trim_rect and #inner == 1 then
		variant.kind = "inner_edge"
		variant.key = "inner_edge:" .. inner[1]
	elseif not trim_rect and #outer >= 2 then
		variant.kind = "outer_corner"
		variant.key = "outer_corner:" .. table.concat(outer, "+")
	elseif not trim_rect and #outer == 1 then
		variant.kind = "outer_edge"
		variant.key = "outer_edge:" .. outer[1]
	elseif not trim_rect and #tags > 0 then
		variant.kind = "mixed"
		variant.key = "mixed:" .. table.concat(tags, "+")
	end

	variant.inject_x_split = patch_has_tag(patch_type, "inner_n") or patch_has_tag(patch_type, "inner_s")
	variant.inject_z_split = patch_has_tag(patch_type, "inner_w") or patch_has_tag(patch_type, "inner_e")
	return variant
end

local function should_flip_patch_cell(patch_variant, x0, x1, z0, z1)
	if not patch_variant then return false end

	local mid_x = (x0 + x1) * 0.5
	local mid_z = (z0 + z1) * 0.5
	local near_west = mid_x < -1 / 6
	local near_east = mid_x > 1 / 6
	local near_north = mid_z < -1 / 6
	local near_south = mid_z > 1 / 6

	if patch_variant.kind == "inner_edge" then
		if patch_has_tag(patch_variant.patch_type, "inner_n") then return near_north end

		if patch_has_tag(patch_variant.patch_type, "inner_s") then return near_south end

		if patch_has_tag(patch_variant.patch_type, "inner_w") then return near_west end

		if patch_has_tag(patch_variant.patch_type, "inner_e") then return near_east end

		return false
	end

	if patch_variant.kind ~= "inner_corner" then return false end

	if
		patch_has_tag(patch_variant.patch_type, "inner_n") and
		patch_has_tag(patch_variant.patch_type, "inner_w")
	then
		return near_west and near_north
	end

	if
		patch_has_tag(patch_variant.patch_type, "inner_n") and
		patch_has_tag(patch_variant.patch_type, "inner_e")
	then
		return near_east and near_north
	end

	if
		patch_has_tag(patch_variant.patch_type, "inner_s") and
		patch_has_tag(patch_variant.patch_type, "inner_w")
	then
		return near_west and near_south
	end

	if
		patch_has_tag(patch_variant.patch_type, "inner_s") and
		patch_has_tag(patch_variant.patch_type, "inner_e")
	then
		return near_east and near_south
	end

	return false
end

local function build_patch_axis_coords(segments, inject_thirds)
	local coords = {}

	for i = 0, segments do
		coords[#coords + 1] = -0.5 + (i / segments)
	end

	if inject_thirds then
		coords[#coords + 1] = -1 / 6
		coords[#coords + 1] = 1 / 6
	end

	table.sort(coords)
	local merged = {}

	for i = 1, #coords do
		if #merged == 0 or not approx_equal(coords[i], merged[#merged]) then
			merged[#merged + 1] = coords[i]
		end
	end

	return merged
end

local function merge_patch_axis_coords(base_coords, extra_coords)
	local coords = {}

	for i = 1, #base_coords do
		coords[#coords + 1] = base_coords[i]
	end

	for i = 1, #(extra_coords or {}) do
		coords[#coords + 1] = extra_coords[i]
	end

	table.sort(coords)
	local merged = {}

	for i = 1, #coords do
		if #merged == 0 or not approx_equal(coords[i], merged[#merged]) then
			merged[#merged + 1] = coords[i]
		end
	end

	return merged
end

local function get_bounds_overlap(bounds, other)
	if not other then return nil end

	local min_x = math.max(bounds.min_x, other.min_x)
	local max_x = math.min(bounds.max_x, other.max_x)
	local min_z = math.max(bounds.min_z, other.min_z)
	local max_z = math.min(bounds.max_z, other.max_z)

	if min_x >= max_x or min_z >= max_z then return nil end

	return {
		min_x = min_x,
		max_x = max_x,
		min_z = min_z,
		max_z = max_z,
	}
end

local function get_normalized_trim_rect(bounds, overlap)
	if not overlap then return nil end

	local span_x = bounds.max_x - bounds.min_x
	local span_z = bounds.max_z - bounds.min_z

	if span_x <= 0 or span_z <= 0 then return nil end

	local min_z = 0.5 - ((overlap.max_z - bounds.min_z) / span_z)
	local max_z = 0.5 - ((overlap.min_z - bounds.min_z) / span_z)
	return {
		min_x = ((overlap.min_x - bounds.min_x) / span_x) - 0.5,
		max_x = ((overlap.max_x - bounds.min_x) / span_x) - 0.5,
		min_z = math.min(min_z, max_z),
		max_z = math.max(min_z, max_z),
	}
end

build_trim_key = function(trim_rect)
	if not trim_rect then return "none" end

	return string.format(
		"trim:%.3f:%.3f:%.3f:%.3f",
		trim_rect.min_x,
		trim_rect.max_x,
		trim_rect.min_z,
		trim_rect.max_z
	)
end

local function get_trimmed_cell_rects(x0, x1, z0, z1, trim_rect)
	if not trim_rect then
		return {
			{min_x = x0, max_x = x1, min_z = z0, max_z = z1},
		}
	end

	local ix0 = math.max(x0, trim_rect.min_x)
	local ix1 = math.min(x1, trim_rect.max_x)
	local iz0 = math.max(z0, trim_rect.min_z)
	local iz1 = math.min(z1, trim_rect.max_z)

	if ix0 >= ix1 or iz0 >= iz1 then
		return {
			{min_x = x0, max_x = x1, min_z = z0, max_z = z1},
		}
	end

	if ix0 <= x0 and ix1 >= x1 and iz0 <= z0 and iz1 >= z1 then return {} end

	local rects = {}

	if x0 < ix0 then
		rects[#rects + 1] = {min_x = x0, max_x = ix0, min_z = z0, max_z = z1}
	end

	if ix1 < x1 then
		rects[#rects + 1] = {min_x = ix1, max_x = x1, min_z = z0, max_z = z1}
	end

	if z0 < iz0 then
		rects[#rects + 1] = {min_x = ix0, max_x = ix1, min_z = z0, max_z = iz0}
	end

	if iz1 < z1 then
		rects[#rects + 1] = {min_x = ix0, max_x = ix1, min_z = iz1, max_z = z1}
	end

	return rects
end

local function make_texture(width, height, format, sampler_config)
	sampler_config = sampler_config or {}
	return Texture.New{
		width = width,
		height = height,
		format = format,
		mip_map_levels = 1,
		image = {
			usage = {"sampled", "transfer_dst", "transfer_src"},
		},
		sampler = {
			min_filter = sampler_config.min_filter or "linear",
			mag_filter = sampler_config.mag_filter or "linear",
			wrap_s = sampler_config.wrap_s or "clamp_to_edge",
			wrap_t = sampler_config.wrap_t or "clamp_to_edge",
		},
	}
end

local function make_shaded_texture(width, height, format, sampler_config)
	sampler_config = sampler_config or {}
	return Texture.New{
		width = width,
		height = height,
		format = format,
		mip_map_levels = 1,
		image = {
			usage = {"storage", "sampled", "transfer_dst", "transfer_src", "color_attachment"},
		},
		sampler = {
			min_filter = sampler_config.min_filter or "linear",
			mag_filter = sampler_config.mag_filter or "linear",
			wrap_s = sampler_config.wrap_s or "clamp_to_edge",
			wrap_t = sampler_config.wrap_t or "clamp_to_edge",
		},
	}
end

local function build_bounds_key(bounds)
	return string.format(
		"%.3f:%.3f:%.3f:%.3f",
		bounds.min_x,
		bounds.max_x,
		bounds.min_z,
		bounds.max_z
	)
end

local function copy_bounds(bounds)
	if not bounds then return nil end

	return {
		min_x = bounds.min_x,
		max_x = bounds.max_x,
		min_z = bounds.min_z,
		max_z = bounds.max_z,
	}
end

local function get_color4_components(color)
	if color.r then return color.r, color.g, color.b, color.a or 1 end

	return color[1] or color.x or 1,
	color[2] or color.y or 1,
	color[3] or color.z or 1,
	color[4] or color.w or 1
end

local function to_color4(color)
	local r, g, b, a = get_color4_components(color)
	return Color(r, g, b, a)
end

local function get_material_layer_colors(layer)
	local color_a = layer.color_a or layer.color or {1, 1, 1}
	local color_b = layer.color_b or layer.color2 or layer.color_alt or color_a
	return to_color4(color_a), to_color4(color_b)
end

local function get_chunk_bounds(chunk_x, chunk_z, chunk_world_size)
	return {
		min_x = chunk_x * chunk_world_size,
		max_x = (chunk_x + 1) * chunk_world_size,
		min_z = chunk_z * chunk_world_size,
		max_z = (chunk_z + 1) * chunk_world_size,
	}
end

local function get_ring_coverage_bounds(center_chunk_x, center_chunk_z, chunk_world_size, radius)
	return {
		min_x = (center_chunk_x - radius) * chunk_world_size,
		max_x = (center_chunk_x + radius + 1) * chunk_world_size,
		min_z = (center_chunk_z - radius) * chunk_world_size,
		max_z = (center_chunk_z + radius + 1) * chunk_world_size,
	}
end

approx_equal = function(a, b)
	return math.abs(a - b) <= 0.0001
end

local function is_grid_aligned(value, step)
	if not step or step == 0 then return true end

	local snapped = math.floor(value / step + 0.5) * step
	return approx_equal(value, snapped)
end

local function bounds_align_to_grid(bounds, step)
	if not bounds then return false end

	return is_grid_aligned(bounds.min_x, step) and
		is_grid_aligned(bounds.max_x, step) and
		is_grid_aligned(bounds.min_z, step) and
		is_grid_aligned(bounds.max_z, step)
end

local function bounds_inside(bounds, outer_bounds)
	if not outer_bounds then return false end

	return bounds.min_x >= outer_bounds.min_x and
		bounds.max_x <= outer_bounds.max_x and
		bounds.min_z >= outer_bounds.min_z and
		bounds.max_z <= outer_bounds.max_z
end

local function get_bounds_center(bounds)
	return (bounds.min_x + bounds.max_x) * 0.5, (bounds.min_z + bounds.max_z) * 0.5
end

local function ranges_touch_or_overlap(min_a, max_a, min_b, max_b)
	return max_a > min_b or
		approx_equal(max_a, min_b) and
		(
			min_a < max_b or
			approx_equal(min_a, max_b)
		)
		or
		max_b > min_a or
		approx_equal(max_b, min_a) and
		(
			min_b < max_a or
			approx_equal(min_b, max_a)
		)
end

local function bounds_touch_or_overlap(bounds, other)
	if not other then return false end

	if get_bounds_overlap(bounds, other) then return true end

	local touch_x = (
			approx_equal(bounds.max_x, other.min_x) or
			approx_equal(bounds.min_x, other.max_x)
		) and
		ranges_touch_or_overlap(bounds.min_z, bounds.max_z, other.min_z, other.max_z)
	local touch_z = (
			approx_equal(bounds.max_z, other.min_z) or
			approx_equal(bounds.min_z, other.max_z)
		) and
		ranges_touch_or_overlap(bounds.min_x, bounds.max_x, other.min_x, other.max_x)
	return touch_x or touch_z
end

local function get_centered_bounds(position_x, position_z, half_size)
	return {
		min_x = position_x - half_size,
		max_x = position_x + half_size,
		min_z = position_z - half_size,
		max_z = position_z + half_size,
	}
end

local function snap_center_chunk_to_parent_grid(center_chunk, radius, chunk_world_size, parent_chunk_world_size)
	if not parent_chunk_world_size then return center_chunk end

	if parent_chunk_world_size % chunk_world_size ~= 0 then return center_chunk end

	local ratio = parent_chunk_world_size / chunk_world_size
	local chunk_span = radius * 2 + 1

	if chunk_span % ratio ~= 0 then return center_chunk end

	return math.floor((center_chunk - radius) / ratio + 0.5) * ratio + radius
end

local function build_patch_type(bounds, outer_bounds, inner_bounds)
	local tags = {}

	if outer_bounds then
		if approx_equal(bounds.min_x, outer_bounds.min_x) then
			tags[#tags + 1] = "outer_w"
		end

		if approx_equal(bounds.max_x, outer_bounds.max_x) then
			tags[#tags + 1] = "outer_e"
		end

		if approx_equal(bounds.min_z, outer_bounds.min_z) then
			tags[#tags + 1] = "outer_n"
		end

		if approx_equal(bounds.max_z, outer_bounds.max_z) then
			tags[#tags + 1] = "outer_s"
		end
	end

	if inner_bounds then
		if approx_equal(bounds.max_x, inner_bounds.min_x) then
			tags[#tags + 1] = "inner_e"
		end

		if approx_equal(bounds.min_x, inner_bounds.max_x) then
			tags[#tags + 1] = "inner_w"
		end

		if approx_equal(bounds.max_z, inner_bounds.min_z) then
			tags[#tags + 1] = "inner_s"
		end

		if approx_equal(bounds.min_z, inner_bounds.max_z) then
			tags[#tags + 1] = "inner_n"
		end
	end

	if #tags == 0 then return "interior" end

	table.sort(tags)
	return table.concat(tags, "+")
end

local function supports_tessellation()
	local device = render.GetDevice and render.GetDevice()

	if
		not device or
		not device.physical_device or
		not device.physical_device.GetFeatures
	then
		return false
	end

	local features = device.physical_device:GetFeatures()
	return features and features.tessellationShader == 1 or false
end

function ProceduralTerrainHybridRenderer.New(config)
	config = config or {}
	local self = setmetatable({}, ProceduralTerrainHybridRenderer)
	self.Name = config.Name or "procedural_terrain_hybrid"
	self.Source = config.Source or config.TerrainSource
	self.ChunkWorldSize = config.ChunkWorldSize or 1024
	self.ChunkRings = config.ChunkRings
	self.LODs = config.LODs or
		{
			{
				radius = 0,
				texture_size = 256,
				height_texture_size = 256,
				tessellation_factor = 16,
			},
			{
				radius = 2,
				texture_size = 128,
				height_texture_size = 128,
				tessellation_factor = 8,
			},
		}
	self.UpdateInterval = config.UpdateInterval or 0.05
	self.BuildsPerUpdate = config.BuildsPerUpdate or 1
	self.Roughness = config.Roughness or 0.92
	self.Metallic = config.Metallic or 0.02
	self.FarTerrain = config.FarTerrain
	self.CastShadows = config.CastShadows == true
	self.HeightScale = self.Source.HeightScale
	self.VerticalOffset = self.Source.VerticalOffset
	self.ActiveTiles = {}
	self.TileRenderCache = {}
	self.SharedPatchCache = {}
	self.RingResidency = {}
	self.FarState = nil
	self.TimerId = self.Name .. "_update"
	self.Root = nil
	self.SupportsTessellation = supports_tessellation()
	return self
end

function ProceduralTerrainHybridRenderer:HasFarTerrain()
	return type(self.FarTerrain) == "table"
end

function ProceduralTerrainHybridRenderer:GetChunkCoord(world_value, chunk_world_size)
	return math.floor(world_value / (chunk_world_size or self.ChunkWorldSize))
end

function ProceduralTerrainHybridRenderer:GetChunkKey(chunk_x, chunk_z, ring_index)
	if ring_index ~= nil then
		return ring_index .. ":" .. chunk_x .. ":" .. chunk_z
	end

	return chunk_x .. ":" .. chunk_z
end

function ProceduralTerrainHybridRenderer:GetRingSlotKey(chunk_x, chunk_z, ring_index, slot_span)
	local function wrap(value, span)
		return ((value % span) + span) % span
	end

	return string.format(
		"slot:%d:%d:%d",
		ring_index or 0,
		wrap(chunk_x, slot_span),
		wrap(chunk_z, slot_span)
	)
end

function ProceduralTerrainHybridRenderer:GetMaxChunkRadius()
	return self.LODs[#self.LODs].radius
end

function ProceduralTerrainHybridRenderer:GetLODIndexForDistance(distance)
	for i = 1, #self.LODs do
		if distance <= self.LODs[i].radius then return i end
	end

	return nil
end

function ProceduralTerrainHybridRenderer:GetSharedPatchPolygon(cache_key, mesh_resolution, patch_type, trim_rect)
	local cached = self.SharedPatchCache[cache_key]

	if cached then return cached end

	local polygon = Polygon3D.New()
	local segments_x, segments_y = get_mesh_segments(mesh_resolution)
	local patch_variant = classify_patch_variant(patch_type, trim_rect)
	local x_coords = build_patch_axis_coords(segments_x, patch_variant.inject_x_split)
	local z_coords = build_patch_axis_coords(segments_y, patch_variant.inject_z_split)

	if trim_rect then
		x_coords = merge_patch_axis_coords(x_coords, {trim_rect.min_x, trim_rect.max_x})
		z_coords = merge_patch_axis_coords(z_coords, {trim_rect.min_z, trim_rect.max_z})
	end

	local normal = Vec3(0, 1, 0)
	local tangent = Vec3(1, 0, 0)

	local function add_patch_rect(rect)
		local x0 = rect.min_x
		local x1 = rect.max_x
		local z0 = rect.min_z
		local z1 = rect.max_z
		local u0 = x0 + 0.5
		local u1 = x1 + 0.5
		local v0 = 0.5 - z0
		local v1 = 0.5 - z1
		local p1 = Vec3(x0, 0, -z0)
		local p2 = Vec3(x1, 0, -z0)
		local p3 = Vec3(x1, 0, -z1)
		local p4 = Vec3(x0, 0, -z1)

		if should_flip_patch_cell(patch_variant, x0, x1, z0, z1) then
			polygon:AddVertex{pos = p1, uv = Vec2(u0, v0), normal = normal, tangent = tangent}
			polygon:AddVertex{pos = p4, uv = Vec2(u0, v1), normal = normal, tangent = tangent}
			polygon:AddVertex{pos = p2, uv = Vec2(u1, v0), normal = normal, tangent = tangent}
			polygon:AddVertex{pos = p4, uv = Vec2(u0, v1), normal = normal, tangent = tangent}
			polygon:AddVertex{pos = p3, uv = Vec2(u1, v1), normal = normal, tangent = tangent}
			polygon:AddVertex{pos = p2, uv = Vec2(u1, v0), normal = normal, tangent = tangent}
		else
			polygon:AddVertex{pos = p1, uv = Vec2(u0, v0), normal = normal, tangent = tangent}
			polygon:AddVertex{pos = p3, uv = Vec2(u1, v1), normal = normal, tangent = tangent}
			polygon:AddVertex{pos = p2, uv = Vec2(u1, v0), normal = normal, tangent = tangent}
			polygon:AddVertex{pos = p1, uv = Vec2(u0, v0), normal = normal, tangent = tangent}
			polygon:AddVertex{pos = p4, uv = Vec2(u0, v1), normal = normal, tangent = tangent}
			polygon:AddVertex{pos = p3, uv = Vec2(u1, v1), normal = normal, tangent = tangent}
		end
	end

	for zi = 1, #z_coords - 1 do
		local z0 = z_coords[zi]
		local z1 = z_coords[zi + 1]

		for xi = 1, #x_coords - 1 do
			local x0 = x_coords[xi]
			local x1 = x_coords[xi + 1]
			local rects = get_trimmed_cell_rects(x0, x1, z0, z1, trim_rect)

			for i = 1, #rects do
				add_patch_rect(rects[i])
			end
		end
	end

	polygon:BuildBoundingBox()
	polygon:Upload()
	self.SharedPatchCache[cache_key] = polygon
	return polygon
end

local function build_height_texture_sampler(height_texture)
	local downloaded = height_texture:Download()
	local width = downloaded:GetWidth()
	local height = downloaded:GetHeight()
	local texel_u = 1 / math.max(width - 1, 1)
	local texel_v = 1 / math.max(height - 1, 1)

	if downloaded.format == "r32_sfloat" then
		local floats = ffi.cast("float*", downloaded.pixels)
		return function(u, v)
			local x = math.clamp(math.floor(u * (width - 1) + 0.5), 0, width - 1)
			local y = math.clamp(math.floor(v * (height - 1) + 0.5), 0, height - 1)
			return floats[y * width + x]
		end,
		texel_u,
		texel_v
	end

	return function(u, v)
		local x = math.clamp(math.floor(u * (width - 1) + 0.5), 0, width - 1)
		local y = math.clamp(math.floor(v * (height - 1) + 0.5), 0, height - 1)
		local r = downloaded:GetRawPixelColor(x, y)
		return (r or 0) / 255
	end,
	texel_u,
	texel_v
end

function ProceduralTerrainHybridRenderer:CreateTilePatchPolygon(height_texture, mesh_resolution, patch_type, trim_rect)
	local polygon = Polygon3D.New()
	local segments_x, segments_y = get_mesh_segments(mesh_resolution)
	local patch_variant = classify_patch_variant(patch_type, trim_rect)
	local x_coords = build_patch_axis_coords(segments_x, patch_variant.inject_x_split)
	local z_coords = build_patch_axis_coords(segments_y, patch_variant.inject_z_split)
	local sample_height01, texel_u, texel_v = build_height_texture_sampler(height_texture)
	local height_scale = self.HeightScale
	local has_trim_rect = trim_rect ~= nil
	local normal_scale_u = math.max(texel_u * 2, 1e-6)
	local normal_scale_v = math.max(texel_v * 2, 1e-6)
	local vertex_indices = {}
	local triangle_indices = {}

	if trim_rect then
		x_coords = merge_patch_axis_coords(x_coords, {trim_rect.min_x, trim_rect.max_x})
		z_coords = merge_patch_axis_coords(z_coords, {trim_rect.min_z, trim_rect.max_z})
	end

	local function get_surface_basis(u, v)
		local left = sample_height01(math.clamp(u - texel_u, 0, 1), v) * height_scale
		local right = sample_height01(math.clamp(u + texel_u, 0, 1), v) * height_scale
		local down = sample_height01(u, math.clamp(v - texel_v, 0, 1)) * height_scale
		local up = sample_height01(u, math.clamp(v + texel_v, 0, 1)) * height_scale
		local dx = (right - left) / normal_scale_u
		local dz = (up - down) / normal_scale_v
		local normal_inverse_length = 1 / math.sqrt(dx * dx + dz * dz + 1)
		local tangent_inverse_length = 1 / math.sqrt(dx * dx + 1)
		return Vec3(-dx * normal_inverse_length, normal_inverse_length, -dz * normal_inverse_length),
		Vec3(tangent_inverse_length, dx * tangent_inverse_length, 0)
	end

	local function get_vertex_index(x, z)
		local x_vertices = vertex_indices[x]
		local existing = x_vertices and x_vertices[z]

		if existing then return existing end

		if not x_vertices then
			x_vertices = {}
			vertex_indices[x] = x_vertices
		end

		local u = x + 0.5
		local v = 0.5 - z
		local normal, tangent = get_surface_basis(u, v)
		polygon:AddVertex{
			pos = Vec3(x, 0, -z),
			uv = Vec2(u, v),
			normal = normal,
			tangent = tangent,
		}
		local index = polygon.i - 1
		x_vertices[z] = index
		return index
	end

	local function add_triangle(a, b, c)
		triangle_indices[#triangle_indices + 1] = a
		triangle_indices[#triangle_indices + 1] = b
		triangle_indices[#triangle_indices + 1] = c
	end

	local function add_patch_rect(x0, x1, z0, z1)
		local i00 = get_vertex_index(x0, z0)
		local i10 = get_vertex_index(x1, z0)
		local i01 = get_vertex_index(x0, z1)
		local i11 = get_vertex_index(x1, z1)

		if should_flip_patch_cell(patch_variant, x0, x1, z0, z1) then
			add_triangle(i00, i01, i10)
			add_triangle(i01, i11, i10)
		else
			add_triangle(i00, i11, i10)
			add_triangle(i00, i01, i11)
		end
	end

	for zi = 1, #z_coords - 1 do
		local z0 = z_coords[zi]
		local z1 = z_coords[zi + 1]

		for xi = 1, #x_coords - 1 do
			local x0 = x_coords[xi]
			local x1 = x_coords[xi + 1]

			if not has_trim_rect then
				add_patch_rect(x0, x1, z0, z1)
			else
				local rects = get_trimmed_cell_rects(x0, x1, z0, z1, trim_rect)

				for i = 1, #rects do
					local rect = rects[i]
					add_patch_rect(rect.min_x, rect.max_x, rect.min_z, rect.max_z)
				end
			end
		end
	end

	polygon:Upload(triangle_indices)
	return polygon
end

function ProceduralTerrainHybridRenderer:CreateTileTextures(bounds, config)
	local world_size_x = bounds.max_x - bounds.min_x
	local world_size_z = bounds.max_z - bounds.min_z
	local height_size = config.height_texture_size or
		config.displacement_texture_size or
		config.texture_size or
		128
	local albedo_size = config.texture_size or 128
	local normal_size = config.normal_texture_size or albedo_size
	local material_size = config.material_texture_size or albedo_size
	local height_texture = make_shaded_texture(height_size, height_size, "r32_sfloat", config.height_sampler)
	local height_shader, height_shader_config = self.Source:BuildHeightShader(bounds.min_x, bounds.min_z, world_size_x, height_size, height_size)
	height_texture:Shade(
		height_shader,
		merge_shade_config(height_shader_config, {header = self.Source:GetShaderHeader()})
	)
	local albedo_texture = make_shaded_texture(albedo_size, albedo_size, "r8g8b8a8_unorm", config.albedo_sampler)
	local albedo_shader, albedo_shader_config = self.Source:BuildAlbedoShader(bounds.min_x, bounds.min_z, world_size_x, albedo_size, albedo_size)
	albedo_texture:Shade(
		albedo_shader,
		merge_shade_config(albedo_shader_config, {header = self.Source:GetMaterialShaderHeader()})
	)
	local normal_texture = make_shaded_texture(normal_size, normal_size, "r8g8b8a8_unorm", config.normal_sampler)
	local normal_shader, normal_shader_config = self.Source:BuildNormalShader(
		bounds.min_x,
		bounds.min_z,
		world_size_x,
		normal_size,
		normal_size,
		config.normal_strength or 1
	)
	normal_texture:Shade(
		normal_shader,
		merge_shade_config(normal_shader_config, {header = self.Source:GetShaderHeader()})
	)
	local material_texture = make_shaded_texture(material_size, material_size, "r8g8b8a8_unorm", config.material_sampler)
	local material_shader, material_shader_config = self.Source:BuildMaterialShader(bounds.min_x, bounds.min_z, world_size_x, material_size, material_size)
	material_texture:Shade(
		material_shader,
		merge_shade_config(material_shader_config, {header = self.Source:GetMaterialShaderHeader()})
	)
	return height_texture, albedo_texture, normal_texture, material_texture
end

function ProceduralTerrainHybridRenderer:GetOrCreateTileRenderData(bounds, config, ring_index, patch_type, trim_rect)
	local cache_key = build_bounds_key(bounds) .. "|" .. tostring(ring_index or 0) .. "|" .. tostring(config.texture_size or 0) .. "|" .. tostring(config.height_texture_size or config.displacement_texture_size or 0) .. "|" .. tostring(config.normal_texture_size or config.texture_size or 0) .. "|" .. tostring(config.material_texture_size or config.texture_size or 0) .. "|" .. tostring(config.normal_strength or 1) .. "|" .. tostring(patch_type or "interior") .. "|" .. build_trim_key(trim_rect)
	local cached = self.TileRenderCache[cache_key]

	if cached then return cached end

	local height_texture, albedo_texture, normal_texture, material_texture = self:CreateTileTextures(bounds, config)
	local material = Material.New()
	material:SetAlbedoTexture(albedo_texture)
	material:SetNormalTexture(normal_texture)
	material:SetTerrainMaterialTexture(material_texture)
	material:SetHeightTexture(height_texture)
	material:SetHeightScale(self.HeightScale)
	material:SetHeightCenter(0.5)
	material:SetHeightLayers(config.height_layers or 24)
	material:SetTessellationFactor(self.SupportsTessellation and (config.tessellation_factor or 8) or 1)
	material:SetRoughnessMultiplier(config.roughness or self.Roughness)
	material:SetMetallicMultiplier(config.metallic or self.Metallic)

	do
		local layers = self.Source.MaterialLayers or {}
		local layer1 = layers[1] or {}
		local layer2 = layers[2] or {}
		local layer3 = layers[3] or {}
		local layer4 = layers[4] or {}
		material:SetTerrainCheckerScales(
			Color(
				layer1.checker_scale or 1,
				layer2.checker_scale or 1,
				layer3.checker_scale or 1,
				layer4.checker_scale or 1
			)
		)
		material:SetTerrainLayer1ColorA(get_material_layer_colors(layer1))
		material:SetTerrainLayer1ColorB(select(2, get_material_layer_colors(layer1)))
		material:SetTerrainLayer2ColorA(get_material_layer_colors(layer2))
		material:SetTerrainLayer2ColorB(select(2, get_material_layer_colors(layer2)))
		material:SetTerrainLayer3ColorA(get_material_layer_colors(layer3))
		material:SetTerrainLayer3ColorB(select(2, get_material_layer_colors(layer3)))
		material:SetTerrainLayer4ColorA(get_material_layer_colors(layer4))
		material:SetTerrainLayer4ColorB(select(2, get_material_layer_colors(layer4)))
		material:SetTerrainLayerRoughness(
			Color(
				layer1.roughness or 0.9,
				layer2.roughness or 0.8,
				layer3.roughness or 0.7,
				layer4.roughness or 0.5
			)
		)
		material:SetTerrainLayerAmbientOcclusion(
			Color(
				layer1.ambient_occlusion or layer1.ao or 1,
				layer2.ambient_occlusion or layer2.ao or 1,
				layer3.ambient_occlusion or layer3.ao or 1,
				layer4.ambient_occlusion or layer4.ao or 1
			)
		)
	end

	local patch_variant = classify_patch_variant(patch_type, trim_rect)
	local render_data = {
		cache_key = cache_key,
		polygon = self:CreateTilePatchPolygon(
			height_texture,
			config.mesh_resolution,
			patch_variant.patch_type,
			trim_rect
		),
		material = material,
		height_texture = height_texture,
		albedo_texture = albedo_texture,
		normal_texture = normal_texture,
		material_texture = material_texture,
		patch_type = patch_type or "interior",
		patch_variant = patch_variant,
		trim_rect = trim_rect,
	}
	self.TileRenderCache[cache_key] = render_data
	return render_data
end

function ProceduralTerrainHybridRenderer:ApplyTileRenderState(tile, bounds, chunk_world_size, render_data)
	local config_label = tostring(tile.config_index)
	tile.transform:SetPosition(
		Vec3(
			(bounds.min_x + bounds.max_x) * 0.5,
			self.VerticalOffset,
			(bounds.min_z + bounds.max_z) * 0.5
		)
	)
	tile.entity:SetName(string.format("%s_tile_%s_cfg_%s", self.Name, tile.key, config_label))
	tile.primitive_entity:SetName(string.format("%s_tile_primitive_%s", self.Name, tile.key))
	tile.primitive:SetPolygon3D(render_data.polygon)
	tile.primitive:SetMaterial(render_data.material)
	tile.render_cache_key = render_data.cache_key
	tile.primitive:SetLocalAABB(
		AABB(
			-chunk_world_size * 0.5,
			-self.HeightScale * 0.5,
			-chunk_world_size * 0.5,
			chunk_world_size * 0.5,
			self.HeightScale * 0.5,
			chunk_world_size * 0.5
		)
	)
	tile.visual:BuildAABB()
	return tile
end

function ProceduralTerrainHybridRenderer:DestroyRenderData(render_data)
	if not render_data then return end

	if
		render_data.height_texture and
		render_data.height_texture.IsValid and
		render_data.height_texture:IsValid()
	then
		render_data.height_texture:Remove()
	end

	if
		render_data.albedo_texture and
		render_data.albedo_texture.IsValid and
		render_data.albedo_texture:IsValid()
	then
		render_data.albedo_texture:Remove()
	end

	if
		render_data.normal_texture and
		render_data.normal_texture.IsValid and
		render_data.normal_texture:IsValid()
	then
		render_data.normal_texture:Remove()
	end

	if
		render_data.material_texture and
		render_data.material_texture.IsValid and
		render_data.material_texture:IsValid()
	then
		render_data.material_texture:Remove()
	end

	if render_data.material then
		render_data.material:SetAlbedoTexture(nil)
		render_data.material:SetNormalTexture(nil)
		render_data.material:SetTerrainMaterialTexture(nil)
		render_data.material:SetHeightTexture(nil)
	end

	render_data.height_texture = nil
	render_data.albedo_texture = nil
	render_data.normal_texture = nil
	render_data.material_texture = nil
	render_data.material = nil
end

function ProceduralTerrainHybridRenderer:PruneRenderCache()
	local live = {}

	for _, tile in pairs(self.ActiveTiles) do
		if tile.render_cache_key then live[tile.render_cache_key] = true end
	end

	if self.FarState and self.FarState.render_cache_key then
		live[self.FarState.render_cache_key] = true
	end

	for cache_key, render_data in pairs(self.TileRenderCache) do
		if not live[cache_key] then
			self.TileRenderCache[cache_key] = nil
			self:DestroyRenderData(render_data)
		end
	end
end

function ProceduralTerrainHybridRenderer:RemoveRenderCache()
	for cache_key, render_data in pairs(self.TileRenderCache) do
		self.TileRenderCache[cache_key] = nil
		self:DestroyRenderData(render_data)
	end
end

function ProceduralTerrainHybridRenderer:BuildTile(
	tile_key,
	chunk_x,
	chunk_z,
	config_index,
	chunk_config,
	ring_index,
	patch_type,
	trim_rect
)
	if not is_valid(self.Root) then return nil end

	local chunk_world_size = chunk_config.chunk_world_size or self.ChunkWorldSize
	local bounds = get_chunk_bounds(chunk_x, chunk_z, chunk_world_size)
	local render_data = self:GetOrCreateTileRenderData(bounds, chunk_config, ring_index, patch_type, trim_rect)
	local entity = Entity.New{
		Name = string.format("%s_tile_%s_cfg_%d", self.Name, tile_key, config_index),
		Parent = self.Root,
	}
	local transform = entity:AddComponent("transform")
	transform:SetScale(Vec3(chunk_world_size, 1, chunk_world_size))
	local visual = entity:AddComponent("visual")
	visual:SetCastShadows(self.CastShadows or chunk_config.cast_shadows == true)
	visual:SetUseOcclusionCulling(false)
	local primitive_entity = Entity.New{
		Name = string.format("%s_tile_primitive_%s", self.Name, tile_key),
		Parent = entity,
	}
	primitive_entity:AddComponent("transform")
	local primitive = primitive_entity:AddComponent("visual_primitive")
	local tile = {
		key = tile_key,
		entity = entity,
		transform = transform,
		visual = visual,
		primitive_entity = primitive_entity,
		primitive = primitive,
		chunk_x = chunk_x,
		chunk_z = chunk_z,
		config_index = config_index,
		ring_index = ring_index,
		patch_type = patch_type or "interior",
		trim_key = build_trim_key(trim_rect),
	}
	return self:ApplyTileRenderState(tile, bounds, chunk_world_size, render_data)
end

function ProceduralTerrainHybridRenderer:UpdateTile(tile, want)
	if not tile or not is_valid(tile.entity) then return nil end

	local chunk_world_size = want.chunk_config.chunk_world_size or self.ChunkWorldSize
	local bounds = get_chunk_bounds(want.chunk_x, want.chunk_z, chunk_world_size)
	local render_data = self:GetOrCreateTileRenderData(
		bounds,
		want.chunk_config,
		want.ring_index,
		want.patch_type,
		want.trim_rect
	)
	tile.chunk_x = want.chunk_x
	tile.chunk_z = want.chunk_z
	tile.config_index = want.config_index
	tile.ring_index = want.ring_index
	tile.patch_type = want.patch_type or "interior"
	tile.trim_key = build_trim_key(want.trim_rect)
	return self:ApplyTileRenderState(tile, bounds, chunk_world_size, render_data)
end

function ProceduralTerrainHybridRenderer:GetCurrentFarHoleBounds(position)
	local far = self.FarTerrain or {}

	if type(self.ChunkRings) == "table" and self.ChunkRings[#self.ChunkRings] then
		local ring = self.ChunkRings[#self.ChunkRings]
		local chunk_world_size = ring.chunk_world_size or self.ChunkWorldSize
		local center_chunk_x = self:GetChunkCoord(position.x, chunk_world_size)
		local center_chunk_z = self:GetChunkCoord(position.z, chunk_world_size)
		local radius = ring.radius or 0
		return get_ring_coverage_bounds(center_chunk_x, center_chunk_z, chunk_world_size, radius)
	end

	local half_size = far.inner_half_size or
		(
			self.ChunkWorldSize * math.max(self:GetMaxChunkRadius(), 1)
		)
	return get_centered_bounds(position.x, position.z, half_size)
end

function ProceduralTerrainHybridRenderer:GetFarBounds(position)
	local far = self.FarTerrain or {}
	local snap_size = far.snap_size or far.outer_half_size or self.ChunkWorldSize
	local center_x = math.floor(position.x / snap_size + 0.5) * snap_size
	local center_z = math.floor(position.z / snap_size + 0.5) * snap_size
	local half_size = far.outer_half_size or (self.ChunkWorldSize * 16)
	return get_centered_bounds(center_x, center_z, half_size)
end

function ProceduralTerrainHybridRenderer:BuildFarTile(state_key, bounds, far_config, trim_rect)
	if not is_valid(self.Root) then return nil end

	local render_data = self:GetOrCreateTileRenderData(bounds, far_config, "far", "interior", trim_rect)
	local entity = Entity.New{
		Name = string.format("%s_far_terrain", self.Name),
		Parent = self.Root,
	}
	local transform = entity:AddComponent("transform")
	transform:SetScale(Vec3(bounds.max_x - bounds.min_x, 1, bounds.max_z - bounds.min_z))
	local visual = entity:AddComponent("visual")
	visual:SetCastShadows(far_config.cast_shadows == true)
	visual:SetUseOcclusionCulling(false)
	local primitive_entity = Entity.New{
		Name = string.format("%s_far_terrain_primitive", self.Name),
		Parent = entity,
	}
	primitive_entity:AddComponent("transform")
	local primitive = primitive_entity:AddComponent("visual_primitive")
	local tile = {
		key = state_key,
		entity = entity,
		transform = transform,
		visual = visual,
		primitive_entity = primitive_entity,
		primitive = primitive,
		config_index = "far",
	}
	return self:ApplyTileRenderState(tile, bounds, bounds.max_x - bounds.min_x, render_data)
end

function ProceduralTerrainHybridRenderer:UpdateFarTerrain(position)
	if not self:HasFarTerrain() or not is_valid(self.Root) then return end

	local far = self.FarTerrain
	local bounds = self:GetFarBounds(position)
	local hole_bounds = self:GetCurrentFarHoleBounds(position)
	local overlap = get_bounds_overlap(bounds, hole_bounds)
	local trim_rect = overlap and get_normalized_trim_rect(bounds, overlap) or nil
	local state_key = build_bounds_key(bounds) .. "|" .. build_trim_key(trim_rect)

	if
		self.FarState and
		self.FarState.key == state_key and
		is_valid(self.FarState.entity)
	then
		return self.FarState
	end

	if self.FarState and is_valid(self.FarState.entity) then
		self.FarState.entity:Remove()
	end

	local far_tile = self:BuildFarTile(state_key, bounds, far, trim_rect)

	if not far_tile then
		self.FarState = nil
		return nil
	end

	self.FarState = {
		key = state_key,
		entity = far_tile.entity,
		bounds = bounds,
		hole_bounds = hole_bounds,
		render_cache_key = far_tile.render_cache_key,
		trim_key = build_trim_key(trim_rect),
	}
	return self.FarState
end

function ProceduralTerrainHybridRenderer:MakeRingResidencyState(state, inner_bounds)
	return {
		center_chunk_x = state.center_chunk_x,
		center_chunk_z = state.center_chunk_z,
		chunk_world_size = state.chunk_world_size,
		radius = state.radius,
		outer_bounds = copy_bounds(state.outer_bounds),
		inner_bounds = copy_bounds(inner_bounds),
		outer_bounds_key = build_bounds_key(state.outer_bounds),
		inner_bounds_key = inner_bounds and build_bounds_key(inner_bounds) or "none",
	}
end

function ProceduralTerrainHybridRenderer:HasRingResidencyChanged(ring_index, state, inner_bounds)
	local previous = self.RingResidency[ring_index]
	local current = self:MakeRingResidencyState(state, inner_bounds)

	if not previous then return true, current end

	if previous.center_chunk_x ~= current.center_chunk_x then
		return true, current
	end

	if previous.center_chunk_z ~= current.center_chunk_z then
		return true, current
	end

	if previous.chunk_world_size ~= current.chunk_world_size then
		return true, current
	end

	if previous.radius ~= current.radius then return true, current end

	if previous.outer_bounds_key ~= current.outer_bounds_key then
		return true, current
	end

	if previous.inner_bounds_key ~= current.inner_bounds_key then
		return true, current
	end

	return false, current
end

function ProceduralTerrainHybridRenderer:GetRingMovementDelta(previous, current)
	if not previous then return nil end

	return {
		dx = current.center_chunk_x - previous.center_chunk_x,
		dz = current.center_chunk_z - previous.center_chunk_z,
	}
end

function ProceduralTerrainHybridRenderer:BuildRingStripPlan(radius, movement)
	if not movement then return nil end

	local slot_span = radius * 2 + 1
	local dx = movement.dx or 0
	local dz = movement.dz or 0

	if dx == 0 and dz == 0 then return nil end

	if math.abs(dx) >= slot_span or math.abs(dz) >= slot_span then return nil end

	local rows = {}
	local columns = {}

	if dx > 0 then
		for step = 0, dx - 1 do
			columns[#columns + 1] = radius - step
		end
	elseif dx < 0 then
		for step = 0, -dx - 1 do
			columns[#columns + 1] = -radius + step
		end
	end

	if dz > 0 then
		for step = 0, dz - 1 do
			rows[#rows + 1] = radius - step
		end
	elseif dz < 0 then
		for step = 0, -dz - 1 do
			rows[#rows + 1] = -radius + step
		end
	end

	return {
		rows = rows,
		columns = columns,
	}
end

function ProceduralTerrainHybridRenderer:IsSlotInStripPlan(dx, dz, plan)
	if not plan then return false end

	for i = 1, #plan.columns do
		if dx == plan.columns[i] then return true end
	end

	for i = 1, #plan.rows do
		if dz == plan.rows[i] then return true end
	end

	return false
end

function ProceduralTerrainHybridRenderer:IsInnerBoundsPriorityTile(bounds, previous_inner_bounds, current_inner_bounds)
	return bounds_touch_or_overlap(bounds, previous_inner_bounds) or
		bounds_touch_or_overlap(bounds, current_inner_bounds)
end

function ProceduralTerrainHybridRenderer:RemoveTile(tile)
	if tile and is_valid(tile.entity) then tile.entity:Remove() end
end

function ProceduralTerrainHybridRenderer:GatherDesiredFixedTiles(position)
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
					key = key,
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

	for key, tile in pairs(self.ActiveTiles) do
		local want = desired[key]

		if not want or want.config_index ~= tile.config_index then
			self:RemoveTile(tile)
			self.ActiveTiles[key] = nil
		end
	end

	for key, want in pairs(desired) do
		local tile = self.ActiveTiles[key]

		if not tile then
			want.action = "create"
			pending[#pending + 1] = want
		elseif
			tile.chunk_x ~= want.chunk_x or
			tile.chunk_z ~= want.chunk_z or
			tile.patch_type ~= (
				want.patch_type or
				"interior"
			)
		then
			want.action = "update"
			pending[#pending + 1] = want
		end
	end

	return pending
end

function ProceduralTerrainHybridRenderer:GatherDesiredRingTiles(position)
	local pending = {}
	local ring_states = {}

	for ring_index, ring in ipairs(self.ChunkRings) do
		local chunk_world_size = ring.chunk_world_size or self.ChunkWorldSize
		local radius = ring.radius or 0
		local prev_state = ring_states[ring_index - 1]
		local center_chunk_x
		local center_chunk_z

		if prev_state then
			local center_x, center_z = get_bounds_center(prev_state.outer_bounds)
			center_chunk_x = self:GetChunkCoord(center_x, chunk_world_size)
			center_chunk_z = self:GetChunkCoord(center_z, chunk_world_size)
		else
			center_chunk_x = self:GetChunkCoord(position.x, chunk_world_size)
			center_chunk_z = self:GetChunkCoord(position.z, chunk_world_size)
		end

		ring_states[ring_index] = {
			config = ring,
			chunk_world_size = chunk_world_size,
			center_chunk_x = center_chunk_x,
			center_chunk_z = center_chunk_z,
			radius = radius,
			outer_bounds = get_ring_coverage_bounds(center_chunk_x, center_chunk_z, chunk_world_size, radius),
		}
	end

	for ring_index, state in ipairs(ring_states) do
		local ring = state.config
		local chunk_world_size = state.chunk_world_size
		local center_chunk_x = state.center_chunk_x
		local center_chunk_z = state.center_chunk_z
		local radius = state.radius
		local slot_span = radius * 2 + 1
		local inner_state = ring_states[ring_index - 1]
		local inner_bounds = nil

		if inner_state then inner_bounds = inner_state.outer_bounds end

		local ring_changed, residency_state = self:HasRingResidencyChanged(ring_index, state, inner_bounds)
		local previous_residency = self.RingResidency[ring_index]
		local movement = self:GetRingMovementDelta(previous_residency, residency_state)
		local strip_plan = self:BuildRingStripPlan(radius, movement)
		local desired = {}

		for dz = -radius, radius do
			for dx = -radius, radius do
				local distance = math.max(math.abs(dx), math.abs(dz))

				if distance <= radius then
					local chunk_x = center_chunk_x + dx
					local chunk_z = center_chunk_z + dz
					local bounds = get_chunk_bounds(chunk_x, chunk_z, chunk_world_size)
					local overlap = get_bounds_overlap(bounds, inner_bounds)
					local trim_rect = nil

					if overlap and not bounds_inside(bounds, inner_bounds) then
						trim_rect = get_normalized_trim_rect(bounds, overlap)
					end

					if not bounds_inside(bounds, inner_bounds) then
						local physical_slot_x = ((chunk_x % slot_span) + slot_span) % slot_span
						local physical_slot_z = ((chunk_z % slot_span) + slot_span) % slot_span
						local key = self:GetRingSlotKey(chunk_x, chunk_z, ring_index, slot_span)
						desired[key] = {
							key = key,
							slot_x = physical_slot_x,
							slot_z = physical_slot_z,
							relative_x = dx,
							relative_z = dz,
							chunk_x = chunk_x,
							chunk_z = chunk_z,
							config_index = ring_index,
							ring_index = ring_index,
							chunk_config = ring,
							distance = distance,
							patch_type = build_patch_type(bounds, state.outer_bounds, inner_bounds),
							trim_rect = trim_rect,
							trim_key = build_trim_key(trim_rect),
						}
					end
				end
			end
		end

		if ring_changed then
			for key, tile in pairs(self.ActiveTiles) do
				if tile.ring_index == ring_index then
					local want = desired[key]

					if not want or want.config_index ~= tile.config_index then
						self:RemoveTile(tile)
						self.ActiveTiles[key] = nil
					end
				end
			end
		end

		for key, want in pairs(desired) do
			local tile = self.ActiveTiles[key]
			local slot_needs_update = self:IsSlotInStripPlan(want.relative_x, want.relative_z, strip_plan)
			local trim_priority = self:IsInnerBoundsPriorityTile(
				get_chunk_bounds(want.chunk_x, want.chunk_z, chunk_world_size),
				previous_residency and previous_residency.inner_bounds,
				inner_bounds
			)
			local tile_needs_update = tile and
				(
					tile.chunk_x ~= want.chunk_x or
					tile.chunk_z ~= want.chunk_z or
					tile.patch_type ~= (
						want.patch_type or
						"interior"
					)
					or
					tile.trim_key ~= want.trim_key
				)
			want.is_strip_update = slot_needs_update or trim_priority

			if not tile then
				want.action = "create"
				pending[#pending + 1] = want
			elseif tile_needs_update then
				want.action = "update"
				pending[#pending + 1] = want
			end
		end

		self.RingResidency[ring_index] = residency_state
	end

	return pending
end

function ProceduralTerrainHybridRenderer:UpdateTileSet()
	local camera = render3d.GetCamera()

	if not camera then return end

	local position = camera:GetPosition()
	local pending = self.ChunkRings and
		self:GatherDesiredRingTiles(position) or
		self:GatherDesiredFixedTiles(position)

	table.sort(pending, function(a, b)
		if (a.is_strip_update == true) ~= (b.is_strip_update == true) then
			return a.is_strip_update == true
		end

		if a.config_index ~= b.config_index then
			return a.config_index < b.config_index
		end

		if a.distance == b.distance then return (a.key or "") < (b.key or "") end

		return a.distance < b.distance
	end)

	local build_limit = math.min(self.BuildsPerUpdate, #pending)

	if #pending > 0 and pending[1].is_strip_update then
		local strip_count = 0

		for i = 1, #pending do
			local want = pending[i]

			if want.is_strip_update then
				strip_count = strip_count + 1
			else
				break
			end
		end

		build_limit = math.max(build_limit, strip_count)
	end

	for i = 1, math.min(build_limit, #pending) do
		local want = pending[i]
		local tile = want.action == "update" and
			self:UpdateTile(self.ActiveTiles[want.key], want) or
			self:BuildTile(
				want.key,
				want.chunk_x,
				want.chunk_z,
				want.config_index,
				want.chunk_config,
				want.ring_index,
				want.patch_type,
				want.trim_rect
			)

		if tile then self.ActiveTiles[tile.key] = tile end
	end

	self:UpdateFarTerrain(position)
	self:PruneRenderCache()
	return pending
end

function ProceduralTerrainHybridRenderer:Start()
	self:Stop()
	self.Root = Entity.New{Name = self.Name}
	self.Root:AddComponent("transform")

	timer.Repeat(
		self.TimerId,
		self.UpdateInterval,
		0,
		function()
			if not is_valid(self.Root) then return true end

			self:UpdateTileSet()
		end
	)

	self:UpdateTileSet()
	return self
end

function ProceduralTerrainHybridRenderer:Stop()
	timer.RemoveTimer(self.TimerId)

	for key, tile in pairs(self.ActiveTiles) do
		self:RemoveTile(tile)
		self.ActiveTiles[key] = nil
	end

	if self.FarState and is_valid(self.FarState.entity) then
		self.FarState.entity:Remove()
	end

	self.RingResidency = {}
	self.FarState = nil
	self:RemoveRenderCache()

	if is_valid(self.Root) then self.Root:Remove() end

	self.Root = nil
	return self
end

return ProceduralTerrainHybridRenderer
