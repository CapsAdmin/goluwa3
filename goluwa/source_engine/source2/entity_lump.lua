local ffi = require("ffi")
local bit = require("bit")
local resource = import("goluwa/source_engine/source2/resource.lua")
local entity_lump = {}
local u32_t = ffi.typeof("uint32_t")
local u8_t = ffi.typeof("const uint8_t *")
local i32_t = ffi.typeof("const int32_t *")
local u32_ptr_t = ffi.typeof("const uint32_t *")
local f32_t = ffi.typeof("const float *")
local f64_t = ffi.typeof("const double *")
local i64_t = ffi.typeof("const int64_t *")
local SEED = 0x31415926
local M = 0x5bd1e995
local u64_t = ffi.typeof("uint64_t")

local function mul(a, b)
	return tonumber(u32_t(u64_t(a % 4294967296) * u64_t(b % 4294967296)))
end

local function xor(a, b)
	return bit.bxor(a, b) % 4294967296
end

function entity_lump.Hash(key)
	key = key:lower()
	local len = #key
	local h = xor(SEED, len)
	local i = 1

	while len - i + 1 >= 4 do
		local k = key:byte(i) + key:byte(i + 1) * 256 + key:byte(i + 2) * 65536 + key:byte(i + 3) * 16777216
		k = mul(k, M)
		k = xor(k, bit.rshift(k, 24))
		k = mul(k, M)
		h = mul(h, M)
		h = xor(h, k)
		i = i + 4
	end

	local rest = len - i + 1

	if rest >= 3 then h = xor(h, key:byte(i + 2) * 65536) end

	if rest >= 2 then h = xor(h, key:byte(i + 1) * 256) end

	if rest >= 1 then
		h = xor(h, key:byte(i))
		h = mul(h, M)
	end

	h = xor(h, bit.rshift(h, 13))
	h = mul(h, M)
	h = xor(h, bit.rshift(h, 15))
	return h
end

local KEYS = {
	"classname",
	"targetname",
	"origin",
	"angles",
	"scales",
	"model",
	"skin",
	"parentname",
	"spawnflags",
	"color",
	"lightcolor",
	"brightness",
	"range",
	"innerconeangle",
	"outerconeangle",
	"pitch",
	"skyname",
	"light_enabled",
	"enabled",
	"colortemperature",
	"brightnessscale",
	"castshadows",
	"directlight",
	"fademindist",
	"fademaxdist",
	"renderamt",
	"rendercolor",
	"rendermode",
	"solid",
	"collisiongroup",
	"physicsmode",
	"fogenable",
	"fogstart",
	"fogend",
	"fogcolor",
	"fogmaxdensity",
	"fogdirection",
	"fogfalloffexponent",
	"fogstrength",
	"fogcolor",
	"nearz",
	"farz",
	"sunlightcolor",
	"sunlightdirection",
	"width",
	"height",
	"material",
	"mapname",
	"visible",
	"disableshadows",
	"lightgroup",
	"bakeduncompressed",
	"style",
	"fallof",
	"falloff",
	"attenuation0",
	"attenuation1",
	"attenuation2",
	"lightsize",
	"ambient",
	"bounceintensity",
	"colorscale",
	"brightness_lightmaps",
	"angles_lightmaps",
	"sundirection",
	"scale",
	"fogcolor",
	"targetmapname",
}
local hash_to_name = {}

for _, key in ipairs(KEYS) do
	hash_to_name[entity_lump.Hash(key)] = key
end

local TYPE_FLOAT, TYPE_INTEGER, TYPE_BOOLEAN, TYPE_COLOR32, TYPE_VECTOR, TYPE_INTEGER64, TYPE_CSTRING, TYPE_UINT, TYPE_UINT64, TYPE_FLOAT64, TYPE_QANGLE = 0x1, 0x5, 0x6, 0x9, 0x3, 0x1a, 0x1e, 0x25, 0x21, 0x22, 0x27

function entity_lump.ParseKeyValues(blob)
	local src = ffi.cast(u8_t, blob)
	local pos = 0
	local entity = {}

	local function u32()
		local v = ffi.cast(u32_ptr_t, src + pos)[0]
		pos = pos + 4
		return v
	end

	local function read_value()
		local t = u32()

		if t == TYPE_FLOAT then
			local v = ffi.cast(f32_t, src + pos)[0]
			pos = pos + 4
			return v
		elseif t == TYPE_INTEGER then
			local v = ffi.cast(i32_t, src + pos)[0]
			pos = pos + 4
			return v
		elseif t == TYPE_UINT then
			local v = ffi.cast(u32_ptr_t, src + pos)[0]
			pos = pos + 4
			return v
		elseif t == TYPE_BOOLEAN then
			local v = src[pos] ~= 0
			pos = pos + 1
			return v
		elseif t == TYPE_COLOR32 then
			local v = {src[pos], src[pos + 1], src[pos + 2], src[pos + 3]}
			pos = pos + 4
			return v
		elseif t == TYPE_VECTOR or t == TYPE_QANGLE then
			local v = ffi.cast(f32_t, src + pos)
			local out = {v[0], v[1], v[2]}
			pos = pos + 12
			return out
		elseif t == TYPE_INTEGER64 or t == TYPE_UINT64 then
			local v = tonumber(ffi.cast(i64_t, src + pos)[0])
			pos = pos + 8
			return v
		elseif t == TYPE_FLOAT64 then
			local v = ffi.cast(f64_t, src + pos)[0]
			pos = pos + 8
			return v
		elseif t == TYPE_CSTRING then
			local e = pos

			while src[e] ~= 0 do
				e = e + 1
			end

			local v = ffi.string(src + pos, e - pos)
			pos = e + 1
			return v
		end

		error("unknown entity field type " .. t)
	end

	assert(u32() == 1)
	local count = u32()
	local attribute_count = u32()

	for _ = 1, count do
		local hash = u32()
		local value = read_value()
		entity[hash_to_name[hash] or hash] = value
	end

	for _ = 1, attribute_count do
		u32()
		local e = pos

		while src[e] ~= 0 do
			e = e + 1
		end

		local name = ffi.string(src + pos, e - pos)
		pos = e + 1
		entity[name] = read_value()
	end

	for _, key in ipairs{"origin", "angles", "scales"} do
		local value = entity[key]

		if type(value) == "string" then
			local x, y, z = value:match("(%S+)%s+(%S+)%s+(%S+)")
			entity[key] = {tonumber(x), tonumber(y), tonumber(z)}
		end
	end

	return entity
end

function entity_lump.Load(vfs, path)
	local data = resource.ReadKV3(resource.Load(vfs, path))
	local out = {}

	for _, kv in ipairs(data.m_entityKeyValues or {}) do
		local entity = entity_lump.ParseKeyValues(kv.m_keyValuesData)
		entity.connections = kv.m_connections
		out[#out + 1] = entity
	end

	return out, data.m_childLumps
end

return entity_lump
