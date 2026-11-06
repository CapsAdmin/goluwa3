local ffi = require("ffi")
local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
local render = import("goluwa/render/render.lua")
local render_stats = import("goluwa/render/stats.lua")
local bindless = import("goluwa/render/vulkan/bindless.lua")
local Hash = import("goluwa/hash.lua")
local Texture
local pipeline_common = {}
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

function pipeline_common.copy_sampler_config(config)
	if config == false then return false end

	if type(config) ~= "table" then return nil end

	local out = {}

	for _, key in ipairs(sampler_config_keys) do
		local value = config[key]

		if value ~= nil then out[key] = value end
	end

	return out
end

local sampler_config_key_cache = setmetatable({}, {__mode = "k"})
local sampler_config_interner = Hash.New()
local NIL_SAMPLER_CONFIG_CACHE_KEY = {}
local FALSE_SAMPLER_CONFIG_CACHE_KEY = {}
local SAMPLER_CONFIG_KEYS = {
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

local function intern_sampler_config_key(config)
	if type(config) ~= "table" then return sampler_config_interner:intern() end

	return sampler_config_interner:intern_with_keys(config, SAMPLER_CONFIG_KEYS)
end

function pipeline_common.get_sampler_config_hash(config)
	if config == false then return false end

	if type(config) ~= "table" then return nil end

	local cached = sampler_config_key_cache[config]

	if cached ~= nil then return cached end

	cached = intern_sampler_config_key(config)
	sampler_config_key_cache[config] = cached
	return cached
end

function pipeline_common.merge_sampler_configs(...)
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

function pipeline_common.normalize_pipeline_sampler_config(config)
	if config == nil or config == false then return nil end

	return pipeline_common.copy_sampler_config(config)
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

function pipeline_common.get_cached_sampler_binding(self, texture_sampler_config)
	local cache = self.resolved_sampler_bindings

	if not cache then
		cache = setmetatable({}, {__mode = "k"})
		self.resolved_sampler_bindings = cache
	end

	local by_texture = get_sampler_binding_cache_level(cache, get_sampler_binding_cache_key(texture_sampler_config))
	local pipeline_key = get_sampler_binding_cache_key(self.sampler_config)
	return by_texture[pipeline_key], by_texture, pipeline_key
end

function pipeline_common.resolve_sampler_binding(self, tex)
	local texture_sampler_config = nil

	if tex then
		texture_sampler_config = tex.GetSamplerConfig and tex:GetSamplerConfig() or nil
	end

	local cached_entry, cache_bucket, cache_key = pipeline_common.get_cached_sampler_binding(self, texture_sampler_config)

	if cached_entry then
		return cached_entry.config, cached_entry.hash, cached_entry.sampler
	end

	local effective_config = pipeline_common.merge_sampler_configs(texture_sampler_config, self.sampler_config)

	if effective_config == false or effective_config == nil then
		effective_config = pipeline_common.get_fallback_sampler_config(self)
		return effective_config,
		pipeline_common.get_sampler_config_hash(effective_config),
		resolve_sampler_config(effective_config)
	end

	local hash = pipeline_common.get_sampler_config_hash(effective_config)
	local sampler = resolve_sampler_config(effective_config)
	cache_bucket[cache_key] = {config = effective_config, hash = hash, sampler = sampler}
	return effective_config, hash, sampler
end

function pipeline_common.get_fallback_view(self)
	Texture = Texture or import("goluwa/render/texture.lua")
	local fallback = Texture.GetFallback()

	if fallback and fallback.GetView then return fallback:GetView() end

	return fallback and fallback.view
end

function pipeline_common.get_fallback_sampler_config(self)
	Texture = Texture or import("goluwa/render/texture.lua")
	local fallback = Texture.GetFallback()

	if fallback and fallback.GetSamplerConfig then
		return fallback:GetSamplerConfig()
	end

	return fallback and
		pipeline_common.copy_sampler_config(fallback.config and fallback.config.sampler) or
		nil
end

function pipeline_common.get_fallback_sampler(self)
	return resolve_sampler_config(pipeline_common.get_fallback_sampler_config(self))
end

function pipeline_common.get_descriptor_binding_count(self, set_index, binding_index)
	local set_counts = self.descriptor_binding_counts and self.descriptor_binding_counts[set_index]
	return set_counts and set_counts[binding_index] or nil
end

local function build_texture_descriptor_entry(self, tex)
	local view

	if tex then view = tex.GetView and tex:GetView() or tex.view end

	if not view then view = self:GetFallbackView() end

	local sampler_config, sampler_hash, sampler = pipeline_common.resolve_sampler_binding(self, tex)
	return {
		texture = tex,
		view = view,
		sampler = sampler,
		sampler_config = sampler_config,
		sampler_hash = sampler_hash,
		layout = tex and tex.sampled_layout or "shader_read_only_optimal",
	}
end

local function get_sampler_slot_cache_key(config)
	local hash = pipeline_common.get_sampler_config_hash(config)

	if hash == nil then return NIL_SAMPLER_CONFIG_CACHE_KEY end

	if hash == false then return FALSE_SAMPLER_CONFIG_CACHE_KEY end

	return hash
end

local function acquire_sampled_texture_index(self, slot, tex)
	local _, hash = pipeline_common.resolve_sampler_binding(self, tex)
	local sub_key = hash == nil and
		NIL_SAMPLER_CONFIG_CACHE_KEY or
		hash == false and
		FALSE_SAMPLER_CONFIG_CACHE_KEY or
		hash
	local by_key = slot.registry[tex]
	local index = by_key and by_key[sub_key]

	if index then
		local entry = slot.entries[index + 1]

		if
			entry.view == tex:GetView() and
			entry.layout == (
				tex.sampled_layout or
				"shader_read_only_optimal"
			)
		then
			return index
		end
	end

	return bindless.Acquire(self.bindless, slot, tex, sub_key, build_texture_descriptor_entry(self, tex))
end

local function get_texture_index(self, tex)
	if not tex then return -1 end

	return acquire_sampled_texture_index(self, self.bindless.textures, tex)
end

local function get_cubemap_texture_index(self, tex)
	if not tex then return -1 end

	return acquire_sampled_texture_index(self, self.bindless.cubemaps, tex)
end

local function get_view_index(self, tex)
	if not tex then return -1 end

	local view = tex.GetView and tex:GetView() or tex.view or self:GetFallbackView()
	local slot = self.bindless.views
	local by_key = slot.registry[tex]
	local index = by_key and by_key[true]

	if index and slot.entries[index + 1].view == view then return index end

	return bindless.Acquire(self.bindless, slot, tex, true, {texture = tex, view = view})
end

local function get_sampler_index(self, config)
	local key = get_sampler_slot_cache_key(config)
	local slot = self.bindless.samplers
	local by_key = slot.registry[key]

	if by_key then return by_key[true] end

	return bindless.Acquire(self.bindless, slot, key, true, {sampler = resolve_sampler_config(config)})
end

local function release_texture_index(self, tex)
	if type(tex) ~= "table" then return end

	bindless.Release(self.bindless, tex)
end

local function get_texture_index_releases(self)
	return self.bindless.releases
end

function pipeline_common.bind_texture_registry(META)
	function META:InitializeTextureRegistry(device)
		local state = bindless.Get(device)

		if not state.fallback_view then
			state.fallback_view = pipeline_common.get_fallback_view(self)
			state.fallback_sampler = pipeline_common.get_fallback_sampler(self)
		end

		self.bindless = state
	end

	META.BuildTextureDescriptorEntry = build_texture_descriptor_entry
	META.GetTextureIndex = get_texture_index
	META.GetCubeMapTextureIndex = get_cubemap_texture_index
	META.ReleaseTextureIndex = release_texture_index
	META.ReleaseViewIndex = release_texture_index
	META.GetViewIndex = get_view_index
	META.GetTextureIndexReleases = get_texture_index_releases
	META.GetSamplerIndex = get_sampler_index
end

function pipeline_common.update_descriptor_set(self, descriptor_type, index, binding_index, set_index, ...)
	if _G.type(set_index) ~= "number" then
		return self:update_descriptor_set(descriptor_type, index, binding_index, 0, set_index, ...)
	end

	local count = select("#", ...)
	local args = {...}

	if descriptor_type == "uniform_buffer_dynamic" then
		local buffer = args[1]
		buffer.descriptor_users = buffer.descriptor_users or setmetatable({}, {__mode = "k"})
		buffer.descriptor_users[self] = buffer.descriptor_users[self] or {}
		buffer.descriptor_users[self][index .. " " .. binding_index .. " " .. set_index] = {index = index, binding_index = binding_index, set_index = set_index}
	end

	if descriptor_type == "combined_image_sampler" then
		local tex_count = 0

		for _, arg in ipairs(args) do
			if type(arg) == "table" and arg.GetView then tex_count = tex_count + 1 end
		end

		if tex_count > 1 then
			local array = {}

			for i, tex in ipairs(args) do
				if type(tex) == "table" and tex.GetView then
					array[i] = self:BuildTextureDescriptorEntry(tex)
				end
			end

			self:UpdateDescriptorSetArray(index, binding_index, set_index, array)
			return
		elseif count == 1 then
			local tex = args[1]
			local entry = self:BuildTextureDescriptorEntry(tex)

			if render.stats then render_stats.AddDescriptorWrites(1) end

			self.vulkan_instance.device:UpdateDescriptorSet(
				descriptor_type,
				self.descriptor_sets[index][set_index + 1],
				binding_index,
				entry.view,
				entry.sampler,
				self:GetFallbackView(),
				self:GetFallbackSampler(),
				entry.layout
			)
			return
		end
	end

	args[count + 1] = self:GetFallbackView()
	args[count + 2] = self:GetFallbackSampler()

	if render.stats then render_stats.AddDescriptorWrites(1) end

	self.vulkan_instance.device:UpdateDescriptorSet(
		descriptor_type,
		self.descriptor_sets[index][set_index + 1],
		binding_index,
		unpack(args, 1, count + 2)
	)
end

function pipeline_common.update_descriptor_set_array(self, frame_index, binding_index, set_index, texture_array, override_count)
	if _G.type(set_index) ~= "number" then
		return self:update_descriptor_set_array(frame_index, binding_index, 0, set_index)
	end

	local binding_count = pipeline_common.get_descriptor_binding_count(self, set_index, binding_index)
	local count = override_count or #texture_array

	if binding_count and count > binding_count then
		error(
			string.format(
				"Pipeline: descriptor array update exceeds binding capacity for set %d binding %d: %d > %d",
				set_index,
				binding_index,
				count,
				binding_count
			),
			2
		)
	end

	if render.stats then render_stats.AddDescriptorWrites(count) end

	self.vulkan_instance.device:UpdateDescriptorSetArray(
		self.descriptor_sets[frame_index][set_index + 1],
		binding_index,
		texture_array,
		self:GetFallbackView(),
		self:GetFallbackSampler(),
		override_count
	)
end

local function get_descriptor_array_binding_count(self, set_index, binding_index, count)
	local binding_count = pipeline_common.get_descriptor_binding_count(self, set_index, binding_index)

	if binding_count and count > binding_count then
		error(
			string.format(
				"Pipeline: descriptor array update exceeds binding capacity for set %d binding %d: %d > %d",
				set_index,
				binding_index,
				count,
				binding_count
			),
			3
		)
	end
end

function pipeline_common.update_storage_buffer_array(self, frame_index, binding_index, set_index, buffer_infos, count)
	get_descriptor_array_binding_count(self, set_index, binding_index, count)

	if render.stats then render_stats.AddDescriptorWrites(count) end

	self.vulkan_instance.device:UpdateDescriptorSetBufferArray(self.descriptor_sets[frame_index][set_index + 1], binding_index, buffer_infos, count)
end

function pipeline_common.update_sampled_image_descriptor_set_array(self, frame_index, binding_index, set_index, view_array, override_count)
	if _G.type(set_index) ~= "number" then
		return pipeline_common.update_sampled_image_descriptor_set_array(self, frame_index, binding_index, 0, set_index)
	end

	local count = override_count or #view_array
	get_descriptor_array_binding_count(self, set_index, binding_index, count)

	if render.stats then render_stats.AddDescriptorWrites(count) end

	self.vulkan_instance.device:UpdateSampledImageDescriptorSetArray(
		self.descriptor_sets[frame_index][set_index + 1],
		binding_index,
		view_array,
		self:GetFallbackView(),
		override_count
	)
end

function pipeline_common.update_sampler_descriptor_set_array(self, frame_index, binding_index, set_index, sampler_array, override_count)
	if _G.type(set_index) ~= "number" then
		return pipeline_common.update_sampler_descriptor_set_array(self, frame_index, binding_index, 0, set_index)
	end

	local count = override_count or #sampler_array
	get_descriptor_array_binding_count(self, set_index, binding_index, count)

	if render.stats then render_stats.AddDescriptorWrites(count) end

	self.vulkan_instance.device:UpdateSamplerDescriptorSetArray(
		self.descriptor_sets[frame_index][set_index + 1],
		binding_index,
		sampler_array,
		self:GetFallbackSampler(),
		override_count
	)
end

function pipeline_common.bind_descriptor_set_methods(META)
	function META:UpdateDescriptorSet(...)
		return pipeline_common.update_descriptor_set(self, ...)
	end

	function META:UpdateDescriptorSetArray(...)
		return pipeline_common.update_descriptor_set_array(self, ...)
	end

	function META:UpdateStorageBufferArray(...)
		return pipeline_common.update_storage_buffer_array(self, ...)
	end

	function META:UpdateSampledImageDescriptorSetArray(...)
		return pipeline_common.update_sampled_image_descriptor_set_array(self, ...)
	end

	function META:UpdateSamplerDescriptorSetArray(...)
		return pipeline_common.update_sampler_descriptor_set_array(self, ...)
	end

	function META:GetFallbackView()
		Texture = Texture or import("goluwa/render/texture.lua")
		local fallback = Texture.GetFallback()

		if fallback and fallback.GetView then return fallback:GetView() end

		return fallback and fallback.view
	end

	function META:GetFallbackSampler()
		Texture = Texture or import("goluwa/render/texture.lua")
		local fallback = Texture.GetFallback()

		if not fallback then return nil end

		local config = nil

		if fallback.GetSamplerConfig then
			config = fallback:GetSamplerConfig()
		elseif fallback.config and fallback.config.sampler then
			config = fallback.config.sampler
		end

		if config == nil or config == false then return nil end

		return render.CreateSampler(config)
	end
end

local shader_stage_bits_u32_cache = {}

local function get_shader_stage_bits_u32(stage)
	if type(stage) == "number" then return stage end

	if type(stage) == "string" then
		local cached = shader_stage_bits_u32_cache[stage]

		if cached then return cached end

		cached = tonumber(ffi.cast("uint32_t", vulkan.vk.e.VkShaderStageFlagBits(stage)))
		shader_stage_bits_u32_cache[stage] = cached
		return cached
	end

	return tonumber(ffi.cast("uint32_t", stage))
end

function pipeline_common.get_shader_stage_bits_u32(stage)
	if type(stage) == "number" then return stage end

	if type(stage) == "string" then
		local cached = shader_stage_bits_u32_cache[stage]

		if cached then return cached end

		cached = tonumber(ffi.cast("uint32_t", vulkan.vk.e.VkShaderStageFlagBits(stage)))
		shader_stage_bits_u32_cache[stage] = cached
		return cached
	end

	return tonumber(ffi.cast("uint32_t", stage))
end

function pipeline_common.push_constants(self, cmd, stage, offset, data, data_size)
	local stage_bits

	if type(stage) == "table" then
		stage_bits = 0

		for _, s in ipairs(stage) do
			stage_bits = bit.bor(stage_bits, get_shader_stage_bits_u32(s))
		end
	else
		stage_bits = get_shader_stage_bits_u32(stage)
	end

	for _, range in ipairs(self.push_constant_ranges) do
		if offset >= range.offset and offset < (range.offset + range.size) then
			stage_bits = bit.bor(stage_bits, range.stage)
		end
	end

	cmd:PushConstants(self.pipeline_layout, stage_bits, offset, data_size or ffi.sizeof(data), data)
end

return pipeline_common
