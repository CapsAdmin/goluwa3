local ffi = require("ffi")
local buffer = require("string.buffer")
local nav = {}
nav.file_extensions = {"nav"}
nav.magic_headers = {"\xCE\xFA\xED\xFE"}
nav.MAGIC = 0xFEEDFACE
nav.VERSION = 16
nav.NORTH = 0
nav.EAST = 1
nav.SOUTH = 2
nav.WEST = 3
nav.ATTRIBUTE = {
	CROUCH = 0x1,
	JUMP = 0x2,
	PRECISE = 0x4,
	NO_JUMP = 0x8,
	STOP = 0x10,
	RUN = 0x20,
	WALK = 0x40,
	AVOID = 0x80,
	TRANSIENT = 0x100,
	DONT_HIDE = 0x200,
	STAND = 0x400,
	NO_HOSTAGES = 0x800,
	STAIRS = 0x1000,
	NO_MERGE = 0x2000,
	OBSTACLE_TOP = 0x4000,
	CLIFF = 0x8000,
}
local u8_ptr_t = ffi.typeof("const uint8_t *")
local u16_ptr_t = ffi.typeof("const uint16_t *")
local u32_ptr_t = ffi.typeof("const uint32_t *")
local f32_ptr_t = ffi.typeof("const float *")
local u8_array_t = ffi.typeof("uint8_t[?]")
local reader = {}
reader.__index = reader

function reader:Check(size)
	if self.position + size > self.length then
		error("nav data is out of range at byte " .. self.position, 3)
	end
end

function reader:U8()
	self:Check(1)
	local value = ffi.cast(u8_ptr_t, self.base + self.position)[0]
	self.position = self.position + 1
	return value
end

function reader:U16()
	self:Check(2)
	local value = ffi.cast(u16_ptr_t, self.base + self.position)[0]
	self.position = self.position + 2
	return value
end

function reader:U32()
	self:Check(4)
	local value = ffi.cast(u32_ptr_t, self.base + self.position)[0]
	self.position = self.position + 4
	return value
end

function reader:F32()
	self:Check(4)
	local value = ffi.cast(f32_ptr_t, self.base + self.position)[0]
	self.position = self.position + 4
	return value
end

function reader:Skip(size)
	self:Check(size)
	self.position = self.position + size
end

function reader:String(size)
	self:Check(size)
	local value = ffi.string(self.base + self.position, size)
	self.position = self.position + size
	return value
end

local function read_ids(r)
	local count = r:U32()
	r:Check(count * 4)
	local ids = {}

	for i = 1, count do
		ids[i] = r:U32()
	end

	return ids
end

local function read_area(r, version)
	local area = {id = r:U32()}

	if version <= 8 then
		area.flags = r:U8()
	elseif version < 13 then
		area.flags = r:U16()
	else
		area.flags = r:U32()
	end

	area.nw = {r:F32(), r:F32(), r:F32()}
	area.se = {r:F32(), r:F32(), r:F32()}
	area.ne_z = r:F32()
	area.sw_z = r:F32()
	area.connections = {}

	for direction = 0, 3 do
		area.connections[direction] = read_ids(r)
	end

	local hiding_spots = {}

	for i = 1, r:U8() do
		hiding_spots[i] = {id = r:U32(), x = r:F32(), y = r:F32(), z = r:F32(), flags = r:U8()}
	end

	area.hiding_spots = hiding_spots

	if version < 15 then r:Skip(r:U8() * 14) end

	for _ = 1, r:U32() do
		r:Skip(10)
		r:Skip(r:U8() * 5)
	end

	area.place = r:U16()
	area.ladders = {}

	for direction = 0, 1 do
		area.ladders[direction] = read_ids(r)
	end

	r:Skip(8)

	if version >= 11 then r:Skip(16) end

	if version >= 16 then
		r:Skip(r:U32() * 5)
		area.inherit_visibility_from = r:U32()
	end

	return area
end

local function read_ladder(r)
	local ladder = {id = r:U32(), width = r:F32()}
	ladder.top = {r:F32(), r:F32(), r:F32()}
	ladder.bottom = {r:F32(), r:F32(), r:F32()}
	ladder.length = r:F32()
	ladder.direction = r:U32()
	ladder.top_forward = r:U32()
	ladder.top_left = r:U32()
	ladder.top_right = r:U32()
	ladder.top_behind = r:U32()
	ladder.bottom_area = r:U32()
	return ladder
end

function nav.Decode(str)
	local r = setmetatable({base = ffi.cast(u8_ptr_t, str), length = #str, position = 0}, reader)

	if r:U32() ~= nav.MAGIC then return nil, "not a nav file" end

	local version = r:U32()

	if version < 5 or version > nav.VERSION then
		return nil, "unsupported nav version " .. version
	end

	local out = {version = version, places = {}, areas = {}, ladders = {}}
	out.sub_version = version >= 10 and r:U32() or 0
	out.bsp_size = r:U32()
	out.analyzed = version >= 14 and r:U8() ~= 0 or false

	for i = 1, r:U16() do
		out.places[i] = r:String(r:U16()):gsub("%z$", "")
	end

	out.has_unnamed_areas = version > 11 and r:U8() ~= 0 or false
	local area_count = r:U32()
	r:Check(area_count * 4)

	for i = 1, area_count do
		out.areas[i] = read_area(r, version)
	end

	if version >= 6 then
		for i = 1, r:U32() do
			out.ladders[i] = read_ladder(r)
		end
	end

	out.trailing_bytes = r.length - r.position
	return out
end

local function write_u32(out, value)
	out:put(ffi.string(ffi.new("uint32_t[1]", value), 4))
end

local function write_u16(out, value)
	out:put(ffi.string(ffi.new("uint16_t[1]", value), 2))
end

local function write_u8(out, value)
	out:put(string.char(value))
end

local function write_f32(out, value)
	out:put(ffi.string(ffi.new("float[1]", value), 4))
end

local function write_ids(out, ids)
	write_u32(out, #ids)

	for _, id in ipairs(ids) do
		write_u32(out, id)
	end
end

function nav.Encode(data)
	local out = buffer.new()
	write_u32(out, nav.MAGIC)
	write_u32(out, nav.VERSION)
	write_u32(out, data.sub_version or 0)
	write_u32(out, data.bsp_size or 0)
	write_u8(out, data.analyzed and 1 or 0)
	write_u16(out, #data.places)

	for _, name in ipairs(data.places) do
		write_u16(out, #name + 1)
		out:put(name, "\0")
	end

	write_u8(out, data.has_unnamed_areas and 1 or 0)
	write_u32(out, #data.areas)

	for _, area in ipairs(data.areas) do
		write_u32(out, area.id)
		write_u32(out, area.flags or 0)

		for i = 1, 3 do
			write_f32(out, area.nw[i])
		end

		for i = 1, 3 do
			write_f32(out, area.se[i])
		end

		write_f32(out, area.ne_z)
		write_f32(out, area.sw_z)

		for direction = 0, 3 do
			write_ids(out, area.connections[direction] or {})
		end

		write_u8(out, 0)
		write_u32(out, 0)
		write_u16(out, area.place or 0)

		for direction = 0, 1 do
			write_ids(out, area.ladders and area.ladders[direction] or {})
		end

		out:put(ffi.string(u8_array_t(24), 24))
		write_u32(out, 0)
		write_u32(out, area.inherit_visibility_from or 0)
	end

	write_u32(out, #data.ladders)

	for _, ladder in ipairs(data.ladders) do
		write_u32(out, ladder.id)
		write_f32(out, ladder.width)

		for i = 1, 3 do
			write_f32(out, ladder.top[i])
		end

		for i = 1, 3 do
			write_f32(out, ladder.bottom[i])
		end

		write_f32(out, ladder.length)
		write_u32(out, ladder.direction)
		write_u32(out, ladder.top_forward)
		write_u32(out, ladder.top_left)
		write_u32(out, ladder.top_right)
		write_u32(out, ladder.top_behind)
		write_u32(out, ladder.bottom_area)
	end

	return out:tostring()
end

return nav
