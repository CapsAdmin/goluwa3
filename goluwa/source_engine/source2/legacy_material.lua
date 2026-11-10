local ffi = require("ffi")
local legacy_material = {}
local u8_t = ffi.typeof("const uint8_t *")
local u32_t = ffi.typeof("const uint32_t *")
local i32_t = ffi.typeof("const int32_t *")
local f32_t = ffi.typeof("const float *")
local u64_t = ffi.typeof("const uint64_t *")
local i64_t = ffi.typeof("const int64_t *")

-- Older compiled materials keep DATA as a binary struct (MaterialResourceData_t, described by the NTRO block) instead of
-- KV3. Fields are offsets relative to themselves, arrays are an offset and a count. Textures are resource ids that the
-- RERL block maps to paths. The result has the shape of the KV3 data.
function legacy_material.Read(res)
	local src = ffi.cast(u8_t, res.data)
	local base = res.blocks.DATA.offset

	local function string_at(position)
		local start = position + ffi.cast(u32_t, src + position)[0]
		local finish = start

		while src[finish] ~= 0 do
			finish = finish + 1
		end

		return ffi.string(src + start, finish - start)
	end

	local function array_at(position)
		return position + ffi.cast(u32_t, src + position)[0],
		ffi.cast(u32_t, src + position + 4)[0]
	end

	local paths = {}
	local rerl = res.blocks.RERL

	if rerl then
		local start, count = array_at(rerl.offset)

		for i = 0, count - 1 do
			local entry = start + i * 16
			local id = ffi.cast(u64_t, src + entry)[0]
			local name_at = entry + 8
			local name_start = name_at + tonumber(ffi.cast(i64_t, src + name_at)[0])
			local name_end = name_start

			while src[name_end] ~= 0 do
				name_end = name_end + 1
			end

			paths[tostring(id)] = ffi.string(src + name_start, name_end - name_start)
		end
	end

	local data = {
		m_materialName = string_at(base),
		m_shaderName = string_at(base + 4),
		m_intParams = {},
		m_floatParams = {},
		m_vectorParams = {},
		m_textureParams = {},
		m_stringAttributes = {},
	}
	local start, count = array_at(base + 8)

	for i = 0, count - 1 do
		local entry = start + i * 8
		data.m_intParams[i + 1] = {m_name = string_at(entry), m_nValue = ffi.cast(i32_t, src + entry + 4)[0]}
	end

	start, count = array_at(base + 16)

	for i = 0, count - 1 do
		local entry = start + i * 8
		data.m_floatParams[i + 1] = {m_name = string_at(entry), m_flValue = ffi.cast(f32_t, src + entry + 4)[0]}
	end

	start, count = array_at(base + 24)

	for i = 0, count - 1 do
		local entry = start + i * 20
		local v = ffi.cast(f32_t, src + entry + 4)
		data.m_vectorParams[i + 1] = {m_name = string_at(entry), m_value = {v[0], v[1], v[2], v[3]}}
	end

	start, count = array_at(base + 32)

	for i = 0, count - 1 do
		local entry = start + i * 16
		local id = tostring(ffi.cast(u64_t, src + entry + 8)[0])
		data.m_textureParams[i + 1] = {m_name = string_at(entry), m_pValue = paths[id] or ""}
	end

	return data
end

return legacy_material
