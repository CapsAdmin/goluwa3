local Vec3 = import("goluwa/structs/vec3.lua")
local AABB = import("goluwa/structs/aabb.lua")
local render = import("goluwa/render/render.lua")
local Texture = import("goluwa/render/texture.lua")

local voxel_grid = {}
voxel_grid.AXES = {"x", "y", "z"}

local function copy_vec3(vec)
	return Vec3(vec.x, vec.y, vec.z)
end

local function build_world_aabb(clipmap, origin_override)
	local half_span = clipmap.world_span * 0.5
	local origin = origin_override or clipmap.origin
	return AABB(
		origin.x - half_span,
		origin.y - half_span,
		origin.z - half_span,
		origin.x + half_span,
		origin.y + half_span,
		origin.z + half_span
	)
end

local function destroy_layer_views(layer_views)
	if not layer_views then return end

	for _, view in pairs(layer_views) do
		if view and view.Remove then view:Remove() end
	end
end

local function destroy_volume_target(target)
	if not target then return end

	if target.sample_view and target.sample_view.Remove then
		target.sample_view:Remove()
	end

	destroy_layer_views(target.layer_views)

	if target.texture and target.texture.Remove then target.texture:Remove() end
end

local function destroy_clipmap_resources(clipmap)
	if not clipmap or not clipmap.resources then return end

	for _, target_group in pairs(clipmap.resources) do
		if type(target_group) == "table" and target_group.x then
			for _, target in pairs(target_group) do
				destroy_volume_target(target)
			end
		end
	end

	clipmap.resources = nil
end

local function create_volume_target(grid, clipmap, axis_name, group_config)
	local resolution = clipmap.resolution
	local texture = Texture.New{
		width = resolution,
		height = resolution,
		format = "r16g16b16a16_sfloat",
		mip_map_levels = 1,
		image = {
			array_layers = resolution,
			usage = {"color_attachment", "sampled", "storage", "transfer_src", "transfer_dst"},
		},
		view = {
			view_type = "2d_array",
			layer_count = resolution,
		},
		sampler = {
			min_filter = "nearest",
			mag_filter = "nearest",
			wrap_s = "clamp_to_edge",
			wrap_t = "clamp_to_edge",
			wrap_r = "clamp_to_edge",
		},
	}
	local target_name = table.concat({
		"render3d",
		grid.name or "voxel grid",
		tostring(clipmap.index),
		"axis",
		axis_name,
	}, " ")

	if group_config and group_config.label_suffix then
		target_name = target_name .. " " .. tostring(group_config.label_suffix)
	end

	texture:SetDebugName(target_name)
	local target = {
		axis = axis_name,
		texture = texture,
		sample_view = texture:GetImage():CreateView{
			view_type = "2d_array",
			base_array_layer = 0,
			layer_count = resolution,
			base_mip_level = 0,
			level_count = 1,
		},
		layer_views = {},
		sampler = render.CreateSampler(texture:GetSamplerConfig()),
	}

	for slice = 0, resolution - 1 do
		target.layer_views[slice] = texture:GetImage():CreateView{
			view_type = "2d",
			base_array_layer = slice,
			layer_count = 1,
			base_mip_level = 0,
			level_count = 1,
		}

		if target.layer_views[slice].SetDebugName then
			target.layer_views[slice]:SetDebugName(target_name .. " slice " .. tostring(slice))
		end
	end

	return target
end

function voxel_grid.New(config)
	local self = {
		name = config.name or "voxel grid",
		clipmap_count = assert(config.clipmap_count),
		get_resolution = assert(config.get_resolution),
		get_voxel_size = assert(config.get_voxel_size),
		target_groups = config.target_groups or {
			active = {},
		},
		clipmaps = {},
	}

	return setmetatable(self, {__index = voxel_grid})
end

function voxel_grid:EnsureClipmap(index)
	local clipmap = self.clipmaps[index]

	if clipmap then return clipmap end

	local resolution = self.get_resolution(index)
	local voxel_size = self.get_voxel_size(index)
	local world_span = resolution * voxel_size
	clipmap = {
		index = index,
		resolution = resolution,
		voxel_size = voxel_size,
		world_span = world_span,
		origin = Vec3(0, 0, 0),
		build_origin = Vec3(0, 0, 0),
		world_aabb = AABB(
			-world_span * 0.5,
			-world_span * 0.5,
			-world_span * 0.5,
			world_span * 0.5,
			world_span * 0.5,
			world_span * 0.5
		),
		build_world_aabb = AABB(
			-world_span * 0.5,
			-world_span * 0.5,
			-world_span * 0.5,
			world_span * 0.5,
			world_span * 0.5,
			world_span * 0.5
		),
		resources = nil,
	}
	self.clipmaps[index] = clipmap
	return clipmap
end

function voxel_grid:EnsureResources(index)
	local clipmap = self:EnsureClipmap(index)
	local resources = clipmap.resources

	if resources and resources.resolution == clipmap.resolution then
		return resources
	end

	destroy_clipmap_resources(clipmap)
	resources = {
		resolution = clipmap.resolution,
	}

	for group_name, group_config in pairs(self.target_groups) do
		resources[group_name] = {}

		for _, axis_name in ipairs(voxel_grid.AXES) do
			resources[group_name][axis_name] = create_volume_target(self, clipmap, axis_name, group_config)
		end
	end

	clipmap.resources = resources
	return resources
end

function voxel_grid:GetClipmaps()
	return self.clipmaps or {}
end

function voxel_grid:GetClipmap(index)
	return self.clipmaps and self.clipmaps[index] or nil
end

function voxel_grid:GetTargetGroup(index, group_name)
	local resources = self:EnsureResources(index)
	return resources and resources[group_name] or nil
end

function voxel_grid:GetAxisTarget(index, group_name, axis_name)
	local targets = self:GetTargetGroup(index, group_name)
	return targets and targets[axis_name] or nil
end

function voxel_grid:SwapAxisTargets(index, group_a, group_b, axis_name)
	local resources = self:EnsureResources(index)

	if not resources or not resources[group_a] or not resources[group_b] then return end

	resources[group_a][axis_name], resources[group_b][axis_name] = resources[group_b][axis_name], resources[group_a][axis_name]
	return resources[group_a][axis_name], resources[group_b][axis_name]
end

function voxel_grid:SetOrigin(index, origin)
	local clipmap = self:EnsureClipmap(index)
	clipmap.origin = copy_vec3(origin)
	clipmap.world_aabb = build_world_aabb(clipmap, clipmap.origin)
	return clipmap.origin
end

function voxel_grid:SetBuildOrigin(index, origin)
	local clipmap = self:EnsureClipmap(index)
	clipmap.build_origin = copy_vec3(origin)
	clipmap.build_world_aabb = build_world_aabb(clipmap, clipmap.build_origin)
	return clipmap.build_origin
end

function voxel_grid:Reset()
	if self.clipmaps then
		for _, clipmap in ipairs(self.clipmaps) do
			destroy_clipmap_resources(clipmap)
		end
	end

	self.clipmaps = {}

	for index = 1, self.clipmap_count do
		self:EnsureClipmap(index)
	end

	return self
end

function voxel_grid:WorldToVoxel(index, world_position)
	local clipmap = self:GetClipmap(index)

	if not clipmap then return nil end

	local inv_voxel_size = 1 / clipmap.voxel_size
	local half_resolution = clipmap.resolution * 0.5
	local voxel_xf = (world_position.x - clipmap.origin.x) * inv_voxel_size + half_resolution
	local voxel_yf = (world_position.y - clipmap.origin.y) * inv_voxel_size + half_resolution
	local voxel_zf = (world_position.z - clipmap.origin.z) * inv_voxel_size + half_resolution
	local voxel_x = math.floor(voxel_xf)
	local voxel_y = math.floor(voxel_yf)
	local voxel_z = math.floor(voxel_zf)
	local inside = voxel_x >= 0 and
		voxel_x < clipmap.resolution and
		voxel_y >= 0 and
		voxel_y < clipmap.resolution and
		voxel_z >= 0 and
		voxel_z < clipmap.resolution

	return {
		clipmap_index = index,
		inside = inside,
		voxel = Vec3(voxel_x, voxel_y, voxel_z),
		fractional = Vec3(voxel_xf, voxel_yf, voxel_zf),
		normalized = Vec3(
			voxel_xf / clipmap.resolution,
			voxel_yf / clipmap.resolution,
			voxel_zf / clipmap.resolution
		),
		voxel_size = clipmap.voxel_size,
		resolution = clipmap.resolution,
	}
end

function voxel_grid:VoxelToWorld(index, voxel_position)
	local clipmap = self:GetClipmap(index)

	if not clipmap then return nil end

	local half_resolution = clipmap.resolution * 0.5
	local voxel_size = clipmap.voxel_size
	return Vec3(
		clipmap.origin.x + ((voxel_position.x + 0.5) - half_resolution) * voxel_size,
		clipmap.origin.y + ((voxel_position.y + 0.5) - half_resolution) * voxel_size,
		clipmap.origin.z + ((voxel_position.z + 0.5) - half_resolution) * voxel_size
	)
end

function voxel_grid:Shutdown()
	for _, clipmap in ipairs(self.clipmaps or {}) do
		destroy_clipmap_resources(clipmap)
	end
end

return voxel_grid