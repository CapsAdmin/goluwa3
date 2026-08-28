local ffi = require("ffi")
local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
local render = import("goluwa/render/render.lua")
local render_stats = import("goluwa/render/stats.lua")
local Hash = import("goluwa/hash.lua")
local pipeline_common = {}
-- ============================================================
-- SECTION 1: Sampler Config Utilities
-- ============================================================
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

-- ============================================================
-- SECTION 2: Sampler Binding Cache
-- ============================================================
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

function pipeline_common.get_cached_sampler_binding(self, texture_sampler_config, sampler_config_override)
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

function pipeline_common.resolve_sampler_binding(self, tex, sampler_config_override)
	local texture_sampler_config = nil

	if tex then
		texture_sampler_config = tex.GetSamplerConfig and tex:GetSamplerConfig() or nil
	end

	local cached_entry, cache_bucket, cache_key = pipeline_common.get_cached_sampler_binding(self, texture_sampler_config, sampler_config_override)

	if cached_entry then
		return cached_entry.config, cached_entry.hash, cached_entry.sampler
	end

	local effective_config = pipeline_common.merge_sampler_configs(texture_sampler_config, self.sampler_config, sampler_config_override)

	if effective_config == false or effective_config == nil then
		effective_config = self:GetFallbackSamplerConfig()
		return effective_config,
		pipeline_common.get_sampler_config_hash(effective_config),
		resolve_sampler_config(effective_config)
	end

	local hash = pipeline_common.get_sampler_config_hash(effective_config)
	local sampler = resolve_sampler_config(effective_config)
	cache_bucket[cache_key] = {config = effective_config, hash = hash, sampler = sampler}
	return effective_config, hash, sampler
end

-- ============================================================
-- SECTION 3: Fallback Helpers
-- ============================================================
function pipeline_common.get_fallback_view(self)
	local Texture = import("goluwa/render/texture.lua")
	local fallback = Texture.GetFallback()

	if fallback and fallback.GetView then return fallback:GetView() end

	return fallback and fallback.view
end

function pipeline_common.get_fallback_sampler_config(self)
	local Texture = import("goluwa/render/texture.lua")
	local fallback = Texture.GetFallback()

	if fallback and fallback.GetSamplerConfig then
		return fallback:GetSamplerConfig()
	end

	return fallback and
		pipeline_common.copy_sampler_config(fallback.config and fallback.config.sampler) or
		nil
end

function pipeline_common.get_fallback_sampler(self)
	return resolve_sampler_config(self:GetFallbackSamplerConfig())
end

-- ============================================================
-- SECTION 4: Bindless Binding Capacity
-- ============================================================
function pipeline_common.get_bindless_texture_set_index(self)
	return #self.descriptor_set_layouts > 1 and 1 or 0
end

function pipeline_common.get_descriptor_binding_count(self, set_index, binding_index)
	local set_counts = self.descriptor_binding_counts and self.descriptor_binding_counts[set_index]
	return set_counts and set_counts[binding_index] or nil
end

function pipeline_common.get_bindless_binding_capacity(self, binding_index)
	return pipeline_common.get_descriptor_binding_count(self, pipeline_common.get_bindless_texture_set_index(self), binding_index)
end

-- ============================================================
-- SECTION 5: Texture Registry (Factory)
-- ============================================================
local function build_texture_descriptor_entry(self, tex, sampler_config_override)
	local view

	if tex then view = tex.GetView and tex:GetView() or tex.view end

	if not view then view = self:GetFallbackView() end

	local sampler_config, sampler_hash, sampler = pipeline_common.resolve_sampler_binding(self, tex, sampler_config_override)
	return {
		texture = tex,
		view = view,
		sampler = sampler,
		sampler_config = sampler_config,
		sampler_config_override = pipeline_common.copy_sampler_config(sampler_config_override),
		sampler_hash = sampler_hash,
	}
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

local function mark_all_descriptor_frames_dirty(self)
	local dirty = self.bindless_descriptor_sets_dirty

	for frame_i = 1, #self.descriptor_sets do
		dirty[frame_i] = true
	end
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

	mark_all_descriptor_frames_dirty(self)
end

-- Groups the state of one bindless texture binding (2d or cubemap) so the
-- shared index logic can serve both without branching. Built once per
-- pipeline; the counter and capacity are read from self by key because they
-- are assigned after the registry is initialized.
local function make_texture_slot(
	registry,
	array,
	free_list,
	next_index_key,
	limit_key,
	binding_index,
	full_message
)
	return {
		registry = registry,
		array = array,
		free_list = free_list,
		next_index_key = next_index_key,
		limit_key = limit_key,
		binding_index = binding_index,
		full_message = full_message,
	}
end

local function release_texture_index(self, tex, set_index)
	set_index = set_index or 0

	if not tex or type(tex) ~= "table" then return end

	local slot = tex.IsCubemap and tex:IsCubemap() and self.cubemap_slot or self.texture_slot
	local by_tex = slot.registry[tex]

	if by_tex then
		slot.registry[tex] = nil

		for _, per_override in pairs(by_tex) do
			for _, index in pairs(per_override) do
				table.insert(slot.free_list, index)
				slot.array[index + 1] = build_texture_descriptor_entry(self)
			end
		end

		refresh_texture_descriptor_array(self, slot.array, slot.binding_index, set_index)
	end
end

local function acquire_texture_index(self, slot, tex, sampler_config_override)
	local cfg_key = get_sampler_binding_cache_key(tex:GetSamplerConfig())
	local override_key = get_sampler_binding_cache_key(sampler_config_override)
	local by_tex = slot.registry[tex]
	local per_override = by_tex and by_tex[cfg_key]
	local index = per_override and per_override[override_key]
	local view = tex:GetView()

	if index and view then
		local entry = slot.array[index + 1]

		if entry and entry.view == view then return index end
	end

	local next_entry = build_texture_descriptor_entry(self, tex, sampler_config_override)

	if index then
		local entry = slot.array[index + 1]

		if
			next_entry.view and
			next_entry.sampler and
			(
				entry == nil or
				entry.view ~= next_entry.view
			)
		then
			slot.array[index + 1] = next_entry
			mark_all_descriptor_frames_dirty(self)
		end

		return index
	end

	local free_list = slot.free_list

	if #free_list > 0 then
		index = table.remove(free_list)
	else
		local next_index = self[slot.next_index_key]
		local limit = self[slot.limit_key]

		if next_index >= limit then error(slot.full_message .. limit) end

		index = next_index
		self[slot.next_index_key] = next_index + 1
	end

	if not per_override then
		per_override = {}
		by_tex = by_tex or {}
		by_tex[cfg_key] = per_override
		slot.registry[tex] = by_tex
	end

	per_override[override_key] = index
	slot.array[index + 1] = next_entry
	mark_all_descriptor_frames_dirty(self)
	return index
end

local function get_texture_index(self, tex, set_index, sampler_config_override)
	if not tex then return -1 end

	set_index = set_index or 0
	return acquire_texture_index(self, self.texture_slot, tex, sampler_config_override)
end

local function get_cubemap_texture_index(self, tex, set_index, sampler_config_override)
	if not tex then return -1 end

	set_index = set_index or 0
	return acquire_texture_index(self, self.cubemap_slot, tex, sampler_config_override)
end

function pipeline_common.bind_texture_registry(META)
	function META:InitializeTextureRegistry()
		self.texture_registry = setmetatable({}, {__mode = "k"})
		self.texture_array = {}
		self.next_texture_index = 0
		self.texture_free_list = {}
		self.cubemap_registry = setmetatable({}, {__mode = "k"})
		self.cubemap_array = {}
		self.next_cubemap_index = 0
		self.cubemap_free_list = {}
		self.bindless_descriptor_sets_dirty = {}
		self.texture_slot = make_texture_slot(
			self.texture_registry,
			self.texture_array,
			self.texture_free_list,
			"next_texture_index",
			"max_textures",
			0,
			"Texture registry full for binding 0! Max descriptors: "
		)
		self.cubemap_slot = make_texture_slot(
			self.cubemap_registry,
			self.cubemap_array,
			self.cubemap_free_list,
			"next_cubemap_index",
			"max_cubemaps",
			1,
			"Cubemap registry full for binding 1! Max descriptors: "
		)
	end

	META.BuildTextureDescriptorEntry = build_texture_descriptor_entry
	META.GetTextureIndex = get_texture_index
	META.GetCubeMapTextureIndex = get_cubemap_texture_index
	META.ReleaseTextureIndex = release_texture_index
	META.RefreshTextureDescriptorArray = refresh_texture_descriptor_array
end

-- ============================================================
-- SECTION 6: Sampler Config Management (Methods)
-- ============================================================
function pipeline_common.bind_sampler_config_methods(META)
	function META:GetSamplerConfig()
		return pipeline_common.copy_sampler_config(self.sampler_config)
	end

	function META:SetSamplerConfig(config)
		local normalized = pipeline_common.normalize_pipeline_sampler_config(config)

		if
			pipeline_common.get_sampler_config_hash(self.sampler_config) == pipeline_common.get_sampler_config_hash(normalized)
		then
			return self:GetSamplerConfig()
		end

		self.sampler_config = normalized
		local set_index = pipeline_common.get_bindless_texture_set_index(self)
		self:RefreshTextureDescriptorArray(self.texture_array, 0, set_index)
		self:RefreshTextureDescriptorArray(self.cubemap_array, 1, set_index)
		return self:GetSamplerConfig()
	end

	function META:SetSamplerConfigValue(key, value)
		local config = self:GetSamplerConfig() or {}

		if value == nil then config[key] = nil else config[key] = value end

		if next(config) == nil then config = nil end

		return self:SetSamplerConfig(config)
	end

	function META:GetFallbackSamplerConfig()
		return pipeline_common.get_fallback_sampler_config()
	end
end

-- ============================================================
-- SECTION 7: Descriptor Set Methods
-- ============================================================
function pipeline_common.update_descriptor_set(self, descriptor_type, index, binding_index, set_index, ...)
	if _G.type(set_index) ~= "number" then
		return self:update_descriptor_set(descriptor_type, index, binding_index, 0, set_index, ...)
	end

	local count = select("#", ...)
	local args = {...}

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
				self:GetFallbackSampler()
			)
			return
		end
	end

	table.insert(args, self:GetFallbackView())
	table.insert(args, self:GetFallbackSampler())

	if render.stats then render_stats.AddDescriptorWrites(1) end

	self.vulkan_instance.device:UpdateDescriptorSet(
		descriptor_type,
		self.descriptor_sets[index][set_index + 1],
		binding_index,
		unpack(args)
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

function pipeline_common.bind_descriptor_set_methods(META)
	function META:UpdateDescriptorSet(...)
		return pipeline_common.update_descriptor_set(self, ...)
	end

	function META:UpdateDescriptorSetArray(...)
		return pipeline_common.update_descriptor_set_array(self, ...)
	end

	function META:GetFallbackView()
		local Texture = import("goluwa/render/texture.lua")
		local fallback = Texture.GetFallback()

		if fallback and fallback.GetView then return fallback:GetView() end

		return fallback and fallback.view
	end

	function META:GetFallbackSampler()
		local Texture = import("goluwa/render/texture.lua")
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

-- ============================================================
-- SECTION 8: Push Constants
-- ============================================================
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
