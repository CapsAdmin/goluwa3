local m3 = import("test/harnesses/m3/harness.lua")
local ffi = require("ffi")
local BatchTable = import("goluwa/render3d/batch_table.lua")
local objects = import("goluwa/objects/objects.lua")
local model_pipeline = import("goluwa/render3d/model_pipeline.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local surface_features = import("goluwa/render3d/surface_features.lua")
local visual = import("goluwa/entities/components/visual.lua")
local Material = import("goluwa/render3d/material.lua")
local system = import("goluwa/system.lua")
local stats = {checked = 0, mismatched = 0, frames = 0, tables = {}}
local orig = BatchTable.Update
local tmp_cache = {}
BatchTable.Update = function(self, pipeline, batches, batch_serial, submission, context)
	local address = orig(self, pipeline, batches, batch_serial, submission, context)
	local count = #batches
	local scratch = tmp_cache[self]
	if not scratch or scratch.count < count then
		scratch = {count = count + 16, records = ffi.typeof("$[?]", self.record_type)(count + 16)}
		tmp_cache[self] = scratch
	end
	local UInt64Ptr = ffi.typeof("uint64_t *")
	local bad = 0
	for i = 1, count do
		local batch = batches[i]
		local record = scratch.records[i - 1]
		ffi.copy(record, ffi.cast("uint8_t *", self.records) + (i - 1) * self.record_size, self.record_size)
		local addresses = ffi.cast(UInt64Ptr, record.addresses)
		local mesh = batch.mesh
		if mesh:IsValid() then
			addresses[0] = mesh:GetVertexBufferAddress()
			addresses[1] = mesh:GetIndexBufferAddress()
			record.index_is_32 = mesh.index_buffer and mesh.index_buffer:GetIndexType() == "uint32" and 1 or 0
			self.write_record(context, pipeline, record, batch)
		else
			addresses[0] = 0
			addresses[1] = 0
		end
		-- compare ignoring never written bytes: the live record is only fully defined where the writer writes, so
		-- compare against a live record that was filled the same way
		local live = ffi.cast("uint8_t *", self.records) + (i - 1) * self.record_size
		local fresh = ffi.cast("uint8_t *", record)
		local anim_name = ffi.offsetof(self.record_type, "m_vertex_animation") and "m_vertex_animation" or "anim"
		local anim_offset = ffi.offsetof(self.record_type, anim_name)
		local anim_size = ffi.sizeof(record[anim_name])
		local material = batch.material
		local differs
		if material and not material:HasVertexAnimation() and mesh:IsValid() then
			-- the time of a batch that does not animate is stale on purpose
			differs = ffi.C.memcmp(live, fresh, anim_offset) ~= 0 or ffi.C.memcmp(live + anim_offset + anim_size, fresh + anim_offset + anim_size, self.record_size - anim_offset - anim_size) ~= 0
		else
			differs = ffi.C.memcmp(live, fresh, self.record_size) ~= 0
		end
		if differs then bad = bad + 1 end
	end
	stats.checked = stats.checked + count
	stats.mismatched = stats.mismatched + bad
	stats.tables[self.label] = (stats.tables[self.label] or 0) + 1
	return address
end
ffi.cdef("int memcmp(const void *a, const void *b, size_t n);")

-- upload keys: compare with the uncached original logic
local function old_factor_default(material)
	local d = material:GetMetallicMultiplier() == 1.0 and material:GetRoughnessMultiplier() == 1.0 and material:GetRoughnessMin() == 0.0 and material:GetRoughnessMax() == 1.0 and material:GetMetallicMaskMin() == 0.0 and material:GetMetallicMaskMax() == 1.0 and material:GetSpecularMultiplier() == 1.0 and material:GetAlphaCutoff() == 0.5
	for _, feature in ipairs(surface_features.list) do
		if feature.block == nil then
			for _, param in ipairs(feature.params or {}) do
				if material["Get" .. param.name](material) ~= param.default then d = false end
			end
		end
	end
	return d
end
local function old_aux_default(material)
	local a = material:GetMetallicRoughnessTexture() ~= nil or material:GetMetallicTexture() ~= nil or material:GetRoughnessTexture() ~= nil
	local b = material:GetAmbientOcclusionTexture() ~= nil or material:GetAmbientOcclusionMultiplier() ~= 1.0
	local c = material:GetEmissiveTexture() ~= nil or material:GetAlbedoAlphaIsEmissive() or material:GetAdditive() or material:GetMetallicTextureAlphaIsEmissive()
	return not (a or b or c)
end
local key_stats = {materials = 0, factor_bad = 0, aux_bad = 0, active_bad = 0}
local frames = 0
m3.Run(function(view, now)
	frames = frames + 1
	if frames == 200 then
		local seen = {}
		local mats = {}
		for material in pairs(visual.Library.material_users) do mats[material] = true end
		for material in pairs(mats) do
			local users = true
			if not seen[material] then
				seen[material] = true
				key_stats.materials = key_stats.materials + 1
				render3d.SetMaterial(material)
				local k = model_pipeline.GetPBRFactorUploadKey()
				local is_def = k ~= render3d.GetMaterialUploadKey()
				-- cached answer must equal the original: default <=> sentinel key
				local cached_default = material.factor_key_is_default
				if cached_default ~= old_factor_default(material) then key_stats.factor_bad = key_stats.factor_bad + 1 end
				model_pipeline.GetPBRAuxUploadKey()
				if material.aux_key_is_default ~= old_aux_default(material) then key_stats.aux_bad = key_stats.aux_bad + 1 end
				for _, ubo in ipairs(model_pipeline.GetPBRUniformBuffers()) do
					if ubo.name:find("_model$") and ubo.name ~= "color_model" and ubo.name ~= "factor_model" and ubo.name ~= "aux_model" and ubo.name ~= "model" then
						ubo.upload_key()
					end
				end
				for _, feature in ipairs(surface_features.list) do
					if feature.block == "own" and material[feature.name .. "_active"] ~= nil then
						if (not not material[feature.name .. "_active"]) ~= (not not feature.active(material)) then key_stats.active_bad = key_stats.active_bad + 1 end
					end
				end
			end
		end
		render3d.SetMaterial(nil)
		print(string.format("KEYS materials=%d factor_bad=%d aux_bad=%d active_bad=%d", key_stats.materials, key_stats.factor_bad, key_stats.aux_bad, key_stats.active_bad))
	end
	if frames == 400 then
		local parts = {}
		for k, v in pairs(stats.tables) do parts[#parts + 1] = k .. "=" .. v end
		print(string.format("BATCH checked=%d mismatched=%d updates: %s", stats.checked, stats.mismatched, table.concat(parts, " ")))
		return false
	end
end)
