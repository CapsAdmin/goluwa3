local ffi = require("ffi")
local blob = {}
local meta = {}
meta.__index = meta

function blob.New()
	return setmetatable({parts = {}, size = 0}, meta)
end

function meta:Add(data, size)
	size = size or (type(data) == "string" and #data or ffi.sizeof(data))
	local offset = self.size
	self.parts[#self.parts + 1] = {data, size, offset}
	self.size = offset + math.ceil(size / 16) * 16
	return offset
end

function meta:Finish()
	if self.size == 0 then return nil end

	local out = ffi.new("uint8_t[?]", self.size)

	for _, part in ipairs(self.parts) do
		ffi.copy(out + part[3], part[1], part[2])
	end

	return out
end

function blob.View(blob_table, ctype, offset)
	return ffi.cast(ctype, blob_table.ptr + offset)
end

return blob
