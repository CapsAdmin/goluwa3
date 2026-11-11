local ffi = require("ffi")
local kv3 = import("goluwa/source_engine/source2/kv3.lua")
local resource = {}
local u32_t = ffi.typeof("const uint32_t *")
local u8_t = ffi.typeof("const uint8_t *")

function resource.Parse(str)
	local src = ffi.cast(u8_t, str)
	local header = ffi.cast(u32_t, src)
	local block_offset, block_count = header[2], header[3]
	local blocks, list = {}, {}

	for i = 0, block_count - 1 do
		local p = 8 + block_offset + i * 12
		local block = {
			type = ffi.string(src + p, 4),
			offset = p + 4 + ffi.cast(u32_t, src + p + 4)[0],
			size = ffi.cast(u32_t, src + p + 8)[0],
		}
		blocks[block.type] = blocks[block.type] or block
		list[i] = block
	end

	return {data = str, blocks = blocks, list = list}
end

function resource.ReadKV3(res, block_name)
	local block = type(block_name) == "number" and
		res.list[block_name] or
		res.blocks[block_name or
		"DATA"]
	local str = res.data:sub(block.offset + 1, block.offset + block.size)
	return kv3.Decode(str, 0)
end

function resource.IsKV3(res, block_name)
	local block = res.blocks[block_name or "DATA"]
	return kv3.Is(res.data, block.offset)
end

function resource.Load(vfs, path)
	local str = assert(vfs.Read(path))
	return resource.Parse(str)
end

return resource
