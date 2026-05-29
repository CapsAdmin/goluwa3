local ffi = require("ffi")
local prototype = import("goluwa/prototype.lua")
local ShaderModule = import("goluwa/render/vulkan/internal/shader_module.lua")
local DescriptorSetLayout = import("goluwa/render/vulkan/internal/descriptor_set_layout.lua")
local PipelineLayout = import("goluwa/render/vulkan/internal/pipeline_layout.lua")
local ComputePipelineInternal = import("goluwa/render/vulkan/internal/compute_pipeline.lua")
local DescriptorPool = import("goluwa/render/vulkan/internal/descriptor_pool.lua")
local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
local render = import("goluwa/render/render.lua")
local ComputePipeline = prototype.CreateTemplate("render_compute_pipeline")
local sampler_config_keys = {
	"min_filter",
	"mag_filter",
	"mipmap_mode",
	"wrap_s",
	"wrap_t",
	"wrap_r",
	"max_lod",
	"min_lod",
	"mip_lod_bias",
	"anisotropy",
	"border_color",
	"unnormalized_coordinates",
	"compare_enable",
	"compare_op",
	"flags",
}
local sampler_config_key_cache = setmetatable({}, {__mode = "k"})
local NIL_SAMPLER_CONFIG_CACHE_KEY = {}
local FALSE_SAMPLER_CONFIG_CACHE_KEY = {}
local NIL_SAMPLER_CONFIG_VALUE = {}
local sampler_config_key_ids = {next_id = 1}
local nil_sampler_hash_key = {}
local get_bindless_texture_set_index
local get_descriptor_binding_count
local get_bindless_binding_capacity

local function copy_sampler_config(config)
	if config == false then return false end

	if type(config) ~= "table" then return nil end

	local out = {}

	for _, key in ipairs(sampler_config_keys) do
		local value = config[key]

		if value ~= nil then out[key] = value end
	end

	return out
end

local function intern_sampler_config_key(config)
	local node = sampler_config_key_ids

	for _, key in ipairs(sampler_config_keys) do
		local value = config[key]

		if value == nil then value = NIL_SAMPLER_CONFIG_VALUE end

		local next_node = node[value]

		if not next_node then
			next_node = {}
			node[value] = next_node
		end

		node = next_node
	end

	local id = node.id

	if not id then
		id = sampler_config_key_ids.next_id
		sampler_config_key_ids.next_id = id + 1
		node.id = id
	end

	return id
end

local function get_sampler_config_key(config)
	if config == false then return false end

	if type(config) ~= "table" then return nil end

	local cached = sampler_config_key_cache[config]

	if cached ~= nil then return cached end

	cached = intern_sampler_config_key(config)
	sampler_config_key_cache[config] = cached
	return cached
end

local function get_sampler_config_hash(config)
	return get_sampler_config_key(config)
end

local function merge_sampler_configs(...)
	local merged = nil

	for i = 1, select("#", ...) do
		local config = select(i, ...)

		if config == false then return false end

		if type(config) == "table" then
			merged = merged or {}

			for _, key in ipairs(sampler_config_keys) do
				local value = config[key]

				if value ~= nil then merged[key] = value end
			end
		end
	end

	return merged
end

local function get_sampler_binding_cache_key(config)
	if config == nil then return NIL_SAMPLER_CONFIG_CACHE_KEY end

	if config == false then return FALSE_SAMPLER_CONFIG_CACHE_KEY end

	return config
end

local function get_sampler_binding_cache_level(parent, key)
	local node = parent[key]

	if node then return node end

	node = setmetatable({}, {__mode = "k"})
	parent[key] = node
	return node
end

local function resolve_sampler_config(config)
	if config == false or config == nil then return nil end

	return render.CreateSampler(config)
end

local function get_texture_sampler_config(texture)
	if not texture then return nil end

	if texture.GetSamplerConfig then return texture:GetSamplerConfig() end

	return nil
end

local function get_cached_sampler_binding(self, texture_sampler_config, sampler_config_override)
	local cache = self.resolved_sampler_bindings

	if not cache then
		cache = setmetatable({}, {__mode = "k"})
		self.resolved_sampler_bindings = cache
	end

	local by_texture = get_sampler_binding_cache_level(cache, get_sampler_binding_cache_key(texture_sampler_config))
	local by_pipeline = get_sampler_binding_cache_level(by_texture, get_sampler_binding_cache_key(self.sampler_config))
	local override_key = get_sampler_binding_cache_key(sampler_config_override)
	return by_pipeline[override_key], by_pipeline, override_key
end

local function resolve_sampler_binding(self, tex, sampler_config_override)
	local texture_sampler_config = tex and get_texture_sampler_config(tex) or nil
	local cached_entry, cache_bucket, cache_key = get_cached_sampler_binding(self, texture_sampler_config, sampler_config_override)

	if cached_entry then
		return cached_entry.config, cached_entry.hash, cached_entry.sampler
	end

	local effective_config = merge_sampler_configs(texture_sampler_config, self.sampler_config, sampler_config_override)

	if effective_config == false or effective_config == nil then
		effective_config = self:GetFallbackSamplerConfig()
		return effective_config,
		get_sampler_config_hash(effective_config),
		resolve_sampler_config(effective_config)
	end

	local hash = get_sampler_config_hash(effective_config)
	local sampler = resolve_sampler_config(effective_config)
	cache_bucket[cache_key] = {
		config = effective_config,
		hash = hash,
		sampler = sampler,
	}
	return effective_config, hash, sampler
end

local function build_texture_descriptor_entry(self, tex, sampler_config_override)
	local view = tex and tex:GetView() or self:GetFallbackView()
	local sampler_config, sampler_hash, sampler = resolve_sampler_binding(self, tex, sampler_config_override)
	return {
		texture = tex,
		view = view,
		sampler = sampler,
		sampler_config = sampler_config,
		sampler_config_override = copy_sampler_config(sampler_config_override),
		sampler_hash = sampler_hash,
	}
end

local function get_texture_variant_key(sampler_hash)
	if sampler_hash == nil then return nil_sampler_hash_key end

	return sampler_hash
end

local function get_texture_descriptor_write_count(array)
	local count = #array

	while count > 0 do
		local entry = array[count]

		if entry and entry.texture ~= nil then break end

		count = count - 1
	end

	return count
end

local function update_texture_descriptor_set_frame(self, frame_index, binding_index, set_index, array, override_count)
	self:UpdateDescriptorSetArray(frame_index, binding_index, set_index, array, override_count)
end

local function mark_texture_descriptor_frames_dirty(self, except_frame)
	local dirty = self.bindless_descriptor_sets_dirty

	for frame_i = 1, #self.descriptor_sets do
		if frame_i ~= except_frame then dirty[frame_i] = true end
	end
end

local function sync_texture_descriptor_sets_for_frame(self, frame_index)
	local dirty = self.bindless_descriptor_sets_dirty

	if not (dirty and dirty[frame_index]) then return end

	local set_index = get_bindless_texture_set_index(self)
	update_texture_descriptor_set_frame(self, frame_index, 0, set_index, self.texture_array)
	update_texture_descriptor_set_frame(self, frame_index, 1, set_index, self.cubemap_array)
	dirty[frame_index] = nil
end

local function update_texture_descriptor_sets(self, binding_index, set_index, array, override_count)
	local count = override_count or get_texture_descriptor_write_count(array)

	if count <= 0 then return end

	mark_texture_descriptor_frames_dirty(self)
end

local function refresh_texture_descriptor_array(self, array, binding_index, set_index)
	local changed = false

	for i = 1, #array do
		local entry = array[i]
		local next_entry = build_texture_descriptor_entry(
			self,
			entry and entry.texture or nil,
			entry and entry.sampler_config_override or nil
		)

		if
			entry == nil or
			entry.view ~= next_entry.view or
			entry.sampler_hash ~= next_entry.sampler_hash
		then
			array[i] = next_entry
			changed = true
		end
	end

	if not changed then return end

	update_texture_descriptor_sets(self, binding_index, set_index, array)
end

local function refresh_texture_descriptor_arrays(self)
	local set_index = get_bindless_texture_set_index(self)
	refresh_texture_descriptor_array(self, self.texture_array, 0, set_index)
	refresh_texture_descriptor_array(self, self.cubemap_array, 1, set_index)
end

local function normalize_pipeline_sampler_config(config)
	if config == nil or config == false then return nil end

	return copy_sampler_config(config)
end

local function get_shader_stage_bits_u32(stage)
	if type(stage) == "string" then
		return tonumber(ffi.cast("uint32_t", vulkan.vk.e.VkShaderStageFlagBits(stage)))
	end

	return tonumber(ffi.cast("uint32_t", stage))
end

local function normalize_compat_config(config)
	if config.shader_stages then return config end

	local descriptor_sets = {}

	if config.descriptor_layout then
		for _, ds in ipairs(config.descriptor_layout) do
			descriptor_sets[#descriptor_sets + 1] = {
				type = ds.type,
				binding_index = ds.binding_index,
				count = ds.count,
				set_index = ds.set_index or 0,
			}
		end
	end

	local max_push_size = 0

	for _, range in ipairs(config.push_constant_ranges or {}) do
		max_push_size = math.max(max_push_size, (range.offset or 0) + (range.size or 0))
	end

	return {
		DescriptorSetCount = config.DescriptorSetCount or config.descriptor_set_count,
		LocalSize = config.LocalSize or config.local_size or config.workgroup_size,
		pool_sizes = config.pool_sizes,
		descriptor_pool = config.descriptor_pool,
		shader_stages = {
			{
				type = "compute",
				code = assert(config.shader, "ComputePipeline.New: shader is required"),
				descriptor_sets = descriptor_sets,
				push_constants = max_push_size > 0 and {
					offset = 0,
					size = max_push_size,
				} or nil,
			},
		},
	}
end

local function build_descriptor_layouts(config)
	local layout_maps = {}
	local pool_size_map = {}
	local descriptor_binding_counts = {}
	local uniform_buffers = {}
	local all_stage_bits = 0
	local max_push_end = 0
	local has_push_constants = false

	for _, stage in ipairs(config.shader_stages) do
		if stage.type ~= "compute" then
			error("ComputePipeline.New: only compute shader stages are supported", 3)
		end

		local stage_bits = get_shader_stage_bits_u32(stage.type)
		all_stage_bits = bit.bor(all_stage_bits, stage_bits)

		for _, ds in ipairs(stage.descriptor_sets or {}) do
			local set_index = ds.set_index or 0
			local binding_index = assert(ds.binding_index, "ComputePipeline.New: descriptor binding_index is required")
			layout_maps[set_index] = layout_maps[set_index] or {}
			local layout_map = layout_maps[set_index]

			if layout_map[binding_index] then
				layout_map[binding_index].stageFlags = bit.bor(layout_map[binding_index].stageFlags, stage_bits)
			else
				layout_map[binding_index] = {
					binding_index = binding_index,
					type = ds.type,
					stageFlags = stage_bits,
					count = ds.count or 1,
				}
				pool_size_map[ds.type] = (pool_size_map[ds.type] or 0) + (ds.count or 1)
			end

			descriptor_binding_counts[set_index] = descriptor_binding_counts[set_index] or {}
			descriptor_binding_counts[set_index][binding_index] = layout_map[binding_index].count or 1

			if ds.type == "uniform_buffer" or ds.type == "uniform_buffer_dynamic" then
				uniform_buffers[binding_index] = ds.args and ds.args[1] or nil
			end
		end

		if stage.push_constants then
			has_push_constants = true
			local offset = stage.push_constants.offset or 0
			local size = assert(stage.push_constants.size, "ComputePipeline.New: push constants size is required")
			max_push_end = math.max(max_push_end, offset + size)
		end
	end

	local push_constant_ranges = {}

	if has_push_constants then
		push_constant_ranges[1] = {
			stage = all_stage_bits,
			offset = 0,
			size = max_push_end,
		}
	end

	local descriptor_set_layouts = {}
	local max_set_index = 0

	for set_index in pairs(layout_maps) do
		max_set_index = math.max(max_set_index, set_index)
	end

	for set_index = 0, max_set_index do
		local layout_map = layout_maps[set_index] or {}
		local layout = {}

		for _, entry in pairs(layout_map) do
			layout[#layout + 1] = entry
		end

		table.sort(layout, function(a, b)
			return a.binding_index < b.binding_index
		end)

		descriptor_set_layouts[set_index + 1] = DescriptorSetLayout.New(config.vulkan_instance.device, layout)
	end

	local pool_sizes = {}

	for descriptor_type, count in pairs(pool_size_map) do
		pool_sizes[#pool_sizes + 1] = {
			type = descriptor_type,
			count = count,
		}
	end

	return {
		descriptor_set_layouts = descriptor_set_layouts,
		pool_sizes = pool_sizes,
		descriptor_binding_counts = descriptor_binding_counts,
		uniform_buffers = uniform_buffers,
		push_constant_ranges = push_constant_ranges,
	}
end

function ComputePipeline.New(vulkan_instance, raw_config)
	local config = normalize_compat_config(raw_config)
	config.vulkan_instance = vulkan_instance
	local self = ComputePipeline:CreateObject{
		vulkan_instance = vulkan_instance,
		config = config,
	}
	local stage = assert(
		config.shader_stages and config.shader_stages[1],
		"ComputePipeline.New: shader_stages[1] is required"
	)
	local shader = ShaderModule.New(
		vulkan_instance.device,
		assert(stage.code, "ComputePipeline.New: compute shader code is required"),
		"compute"
	)
	local descriptor_info = build_descriptor_layouts(config)

	if #descriptor_info.push_constant_ranges > 0 then
		local device_properties = vulkan_instance.physical_device:GetProperties()
		local max_push_constants_size = device_properties.limits.maxPushConstantsSize
		local range = descriptor_info.push_constant_ranges[1]

		if range.size > max_push_constants_size then
			error(
				string.format(
					"ComputePipeline.New: push constants size %d exceeds device limit %d",
					range.size,
					max_push_constants_size
				),
				3
			)
		end
	end

	local pipeline_layout = PipelineLayout.New(
		vulkan_instance.device,
		descriptor_info.descriptor_set_layouts,
		descriptor_info.push_constant_ranges
	)
	local pipeline = ComputePipelineInternal.New(vulkan_instance.device, shader, pipeline_layout)
	local descriptor_set_count = config.DescriptorSetCount or 1
	local pool_sizes = config.pool_sizes or config.descriptor_pool or descriptor_info.pool_sizes
	local descriptor_pools = {}
	local descriptor_sets = {}

	if #descriptor_info.descriptor_set_layouts > 0 then
		for frame = 1, descriptor_set_count do
			descriptor_pools[frame] = DescriptorPool.New(vulkan_instance.device, pool_sizes, #descriptor_info.descriptor_set_layouts)
			local frame_sets = {}

			for i, layout in ipairs(descriptor_info.descriptor_set_layouts) do
				frame_sets[i] = descriptor_pools[frame]:AllocateDescriptorSet(layout)
			end

			descriptor_sets[frame] = frame_sets
		end
	end

	local local_size = config.LocalSize

	if type(local_size) == "number" then
		local_size = {x = local_size, y = local_size, z = 1}
	elseif type(local_size) ~= "table" then
		local_size = {x = 8, y = 8, z = 1}
	else
		local_size = {
			x = local_size.x or local_size[1] or 8,
			y = local_size.y or local_size[2] or 8,
			z = local_size.z or local_size[3] or 1,
		}
	end

	self.shader = shader
	self.pipeline = pipeline
	self.pipeline_layout = pipeline_layout
	self.descriptor_set_layouts = descriptor_info.descriptor_set_layouts
	self.descriptor_binding_counts = descriptor_info.descriptor_binding_counts
	self.descriptor_pools = descriptor_pools
	self.descriptor_sets = descriptor_sets
	self.push_constant_ranges = descriptor_info.push_constant_ranges
	self.uniform_buffers = descriptor_info.uniform_buffers
	self.local_size = local_size

	for frame_index = 1, descriptor_set_count do
		for _, shader_stage in ipairs(config.shader_stages or {}) do
			if shader_stage.descriptor_sets then
				for _, ds in ipairs(shader_stage.descriptor_sets) do
					if ds.args then
						local args = ds.args

						if type(args) == "function" then args = args() end

						if type(args) ~= "table" then args = {args} end

						self:UpdateDescriptorSet(ds.type, frame_index, ds.binding_index, ds.set_index or 0, unpack(args))
					end
				end
			end
		end
	end

	self.sampler_config = normalize_pipeline_sampler_config(config.Sampler or config.sampler)
	self.texture_registry = setmetatable({}, {__mode = "k"})
	self.texture_array = {}
	self.next_texture_index = 0
	self.texture_free_list = {}
	self.cubemap_registry = setmetatable({}, {__mode = "k"})
	self.cubemap_array = {}
	self.next_cubemap_index = 0
	self.cubemap_free_list = {}
	self.max_textures = get_bindless_binding_capacity(self, 0) or 0
	self.max_cubemaps = get_bindless_binding_capacity(self, 1) or 0
	self.bindless_descriptor_sets_dirty = {}
	local event = import("goluwa/event.lua")

	event.AddListener("TextureRemoved", self, function(removed_tex)
		if not render.GetDevice():IsValid() then return end

		if render.shutting_down then return end

		local set_index = #self.descriptor_set_layouts > 1 and 1 or 0
		self:ReleaseTextureIndex(removed_tex, set_index)
	end)

	return self
end

function ComputePipeline:GetDescriptorSetCount()
	return self.descriptor_sets and #self.descriptor_sets or 0
end

function ComputePipeline:GetUniformBuffer(binding_index)
	local ub = self.uniform_buffers[binding_index]

	if not ub then
		error("Invalid uniform buffer binding index: " .. tostring(binding_index), 2)
	end

	return ub
end

function ComputePipeline:UpdateDescriptorSet(type, index, binding_index, set_index, ...)
	if _G.type(set_index) ~= "number" then
		return self:UpdateDescriptorSet(type, index, binding_index, 0, set_index, ...)
	end

	self.vulkan_instance.device:UpdateDescriptorSet(type, self.descriptor_sets[index][set_index + 1], binding_index, ...)
end

function ComputePipeline:Bind(cmd, frame_index, dynamic_offsets)
	frame_index = frame_index or 1
	cmd:BindPipeline(self.pipeline, "compute")

	if self.descriptor_sets and #self.descriptor_sets > 0 then
		sync_texture_descriptor_sets_for_frame(self, frame_index)
		local sets = self.descriptor_sets[frame_index] or self.descriptor_sets[1]
		cmd:BindDescriptorSets("compute", self.pipeline_layout, sets, dynamic_offsets, 0)
	end
end

get_bindless_texture_set_index = function(self)
	return #self.descriptor_set_layouts > 1 and 1 or 0
end
get_descriptor_binding_count = function(self, set_index, binding_index)
	local set_counts = self.descriptor_binding_counts and self.descriptor_binding_counts[set_index]
	return set_counts and set_counts[binding_index] or nil
end
get_bindless_binding_capacity = function(self, binding_index)
	return get_descriptor_binding_count(self, get_bindless_texture_set_index(self), binding_index)
end

function ComputePipeline:GetFallbackView()
	local Texture = import("goluwa/render/texture.lua")
	local fallback = Texture.GetFallback()

	if fallback and fallback.GetView then return fallback:GetView() end

	return fallback and fallback.view
end

function ComputePipeline:GetFallbackSamplerConfig()
	local Texture = import("goluwa/render/texture.lua")
	local fallback = Texture.GetFallback()

	if fallback and fallback.GetSamplerConfig then
		return fallback:GetSamplerConfig()
	end

	return fallback and
		copy_sampler_config(fallback.config and fallback.config.sampler) or
		nil
end

function ComputePipeline:GetFallbackSampler()
	return resolve_sampler_config(self:GetFallbackSamplerConfig())
end

function ComputePipeline:SetSamplerConfig(config)
	local normalized = normalize_pipeline_sampler_config(config)

	if
		get_sampler_config_hash(self.sampler_config) == get_sampler_config_hash(normalized)
	then
		return self:GetSamplerConfig()
	end

	self.sampler_config = normalized
	refresh_texture_descriptor_arrays(self)
	return self:GetSamplerConfig()
end

function ComputePipeline:GetSamplerConfig()
	return copy_sampler_config(self.sampler_config)
end

function ComputePipeline:SetSamplerConfigValue(key, value)
	local config = self:GetSamplerConfig() or {}

	if value == nil then config[key] = nil else config[key] = value end

	if next(config) == nil then config = nil end

	return self:SetSamplerConfig(config)
end

function ComputePipeline:ReleaseTextureIndex(tex, set_index)
	set_index = set_index or 0

	if not tex or type(tex) ~= "table" then return end

	local is_cube = tex.IsCubemap and tex:IsCubemap()
	local registry = is_cube and self.cubemap_registry or self.texture_registry
	local array = is_cube and self.cubemap_array or self.texture_array
	local free_list = is_cube and self.cubemap_free_list or self.texture_free_list
	local binding_index = is_cube and 1 or 0
	local variant_indices = registry[tex]

	if variant_indices then
		registry[tex] = nil

		for _, index in pairs(variant_indices) do
			table.insert(free_list, index)
			array[index + 1] = build_texture_descriptor_entry(self)
		end

		update_texture_descriptor_sets(self, binding_index, set_index, array)
	end
end

function ComputePipeline:GetTextureIndex(tex, set_index, sampler_config_override)
	set_index = set_index or 0

	if not tex or type(tex) ~= "table" then return -1 end

	local is_cube = tex.IsCubemap and tex:IsCubemap()
	local registry = is_cube and self.cubemap_registry or self.texture_registry
	local array = is_cube and self.cubemap_array or self.texture_array
	local index_key = is_cube and "next_cubemap_index" or "next_texture_index"
	local limit_key = is_cube and "max_cubemaps" or "max_textures"
	local binding_index = is_cube and 1 or 0
	local next_entry = build_texture_descriptor_entry(self, tex, sampler_config_override)
	local variant_key = get_texture_variant_key(next_entry.sampler_hash)
	local variant_indices = registry[tex]
	local index = variant_indices and variant_indices[variant_key]

	if index then
		local entry = array[index + 1]

		if
			next_entry.view and
			next_entry.sampler and
			(
				entry == nil or
				entry.view ~= next_entry.view or
				entry.sampler_hash ~= next_entry.sampler_hash
			)
		then
			array[index + 1] = next_entry
			update_texture_descriptor_sets(self, binding_index, set_index, array, index + 1)
		end

		return index
	end

	local free_list = is_cube and self.cubemap_free_list or self.texture_free_list

	if #free_list > 0 then
		index = table.remove(free_list)
	else
		if self[index_key] >= self[limit_key] then
			error(
				(
						(
							is_cube and
							"Cubemap" or
							"Texture"
						) .. " registry full for binding " .. binding_index .. "! Max descriptors: " .. self[limit_key]
					),
				2
			)
		end

		index = self[index_key]
		self[index_key] = index + 1
	end

	variant_indices = variant_indices or {}
	variant_indices[variant_key] = index
	registry[tex] = variant_indices
	array[index + 1] = next_entry
	update_texture_descriptor_sets(self, binding_index, set_index, array, index + 1)
	return index
end

function ComputePipeline:UpdateDescriptorSetArray(frame_index, binding_index, set_index, texture_array, override_count)
	if _G.type(set_index) ~= "number" then
		return self:UpdateDescriptorSetArray(frame_index, binding_index, 0, set_index)
	end

	local binding_count = get_descriptor_binding_count(self, set_index, binding_index)
	local count = override_count or #texture_array

	if binding_count and count > binding_count then
		error(
			string.format(
				"ComputePipeline: descriptor array update exceeds binding capacity for set %d binding %d: %d > %d",
				set_index,
				binding_index,
				count,
				binding_count
			),
			2
		)
	end

	self.vulkan_instance.device:UpdateDescriptorSetArray(
		self.descriptor_sets[frame_index][set_index + 1],
		binding_index,
		texture_array,
		self:GetFallbackView(),
		self:GetFallbackSampler(),
		override_count
	)
end

function ComputePipeline:PushConstants(cmd, stage, offset, data, data_size)
	local stage_bits

	if type(stage) == "table" then
		stage_bits = 0

		for _, stage_name in ipairs(stage) do
			stage_bits = bit.bor(stage_bits, get_shader_stage_bits_u32(stage_name))
		end
	else
		stage_bits = get_shader_stage_bits_u32(stage)
	end

	for _, range in ipairs(self.push_constant_ranges or {}) do
		if offset >= range.offset and offset < (range.offset + range.size) then
			stage_bits = bit.bor(stage_bits, range.stage)
		end
	end

	cmd:PushConstants(self.pipeline_layout, stage_bits, offset, data_size or ffi.sizeof(data), data)
end

function ComputePipeline:Dispatch(cmd, group_count_x, group_count_y, group_count_z, frame_index, dynamic_offsets)
	self:Bind(cmd, frame_index, dynamic_offsets)
	cmd:Dispatch(group_count_x or 1, group_count_y or 1, group_count_z or 1)
end

function ComputePipeline:DispatchForSize(cmd, width, height, depth, frame_index, dynamic_offsets)
	local ls = self.local_size
	local gx = math.ceil((width or 1) / math.max(ls.x, 1))
	local gy = math.ceil((height or 1) / math.max(ls.y, 1))
	local gz = math.ceil((depth or 1) / math.max(ls.z, 1))
	self:Dispatch(cmd, gx, gy, gz, frame_index, dynamic_offsets)
end

function ComputePipeline:OnRemove()
	if self.pipeline then self.pipeline:Remove() end

	if self.shader then self.shader:Remove() end

	if self.descriptor_pools then
		for _, pool in ipairs(self.descriptor_pools) do
			if pool then pool:Remove() end
		end
	end

	if self.descriptor_set_layouts then
		for _, layout in ipairs(self.descriptor_set_layouts) do
			if layout then layout:Remove() end
		end
	end

	if self.pipeline_layout then self.pipeline_layout:Remove() end
end

return ComputePipeline:Register()
