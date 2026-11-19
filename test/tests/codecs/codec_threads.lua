local T = import("test/environment.lua")
local ffi = require("ffi")
local buffer = require("string.buffer")
local dds = import("goluwa/codecs/dds.lua")
local Buffer = import("goluwa/structs/buffer.lua")
local codec = import("goluwa/codec.lua")
local thread_pool = import("goluwa/thread_pool.lua")

local function build_dds_with_attached()
	local header = ffi.new("uint32_t[32]")
	header[0] = 0x20534444
	header[1] = 124
	header[3] = 4
	header[4] = 4
	header[7] = 1
	header[19] = 32
	header[20] = 0x4
	header[21] = 0x32495441
	local attached = ffi.new("uint8_t[?]", 128 + 16)
	local attached_header = ffi.new("uint32_t[32]")
	attached_header[0] = 0x20534444
	attached_header[1] = 124
	attached_header[3] = 4
	attached_header[4] = 4
	attached_header[7] = 1
	attached_header[19] = 32
	attached_header[20] = 0x4
	attached_header[21] = 28
	ffi.copy(attached, attached_header, 128)

	for i = 0, 15 do
		attached[128 + i] = i * 16
	end

	local size = 128 + 16 + 4 + 8 + (128 + 16) + 4
	local data = ffi.new("uint8_t[?]", size)
	ffi.copy(data, header, 128)
	ffi.copy(data + 128, "\1\1\1\1\1\1\1\1\2\2\2\2\2\2\2\2", 16)
	ffi.cast("uint32_t *", data)[31] = 0x43525946
	local chunks = data + 128 + 16
	ffi.copy(chunks, "CExtAttC", 8)
	ffi.cast("uint32_t *", chunks + 8)[0] = 128 + 16
	ffi.copy(chunks + 12, attached, 128 + 16)
	ffi.copy(chunks + 12 + 128 + 16, "CEnd", 4)
	return ffi.string(data, size)
end

T.Test("dds worker result equals the inline result and is serializable", function()
	local file = build_dds_with_attached()
	local meta, data = dds.DecodeBuffer(Buffer.New(file, #file))
	local encoded = buffer.encode(meta)
	T(table.equal(buffer.decode(encoded), meta))["=="](true)
	local job = thread_pool.Run(dds.thread_job, file, 1e9)
	local worker_meta, blob = job:Await()
	T(table.equal(worker_meta, meta))["=="](true)
	T(blob.len)["=="](ffi.sizeof(data))
	T(ffi.string(blob.ptr, blob.len) == ffi.string(data, ffi.sizeof(data)))["=="](true)
	local img = codec.AttachBlob(worker_meta, blob)
	T(img.data[0])["=="](2)
	T(img.attached_image.data[1])["=="](16)
	T(img.attached_image.data[15])["=="](240)
end)

T.Test("worker errors from malformed dds data are reported", function()
	local job = thread_pool.Run(dds.thread_job, string.rep("x", 200), 1e9)
	T(pcall(job.Await, job))["=="](false)
end)

T.Test("ogg worker result equals the inline result", function()
	local ogg = import("goluwa/codecs/ogg.lua")
	local fs = import("goluwa/filesystem/fs.lua")
	local resource = import("goluwa/resource.lua")
	local data = fs.read_file(
		resource.Download(
			"https://github.com/CapsAdmin/goluwa-assets/raw/refs/heads/master/test/ogg/test_sweep.ogg"
		):Get()
	)
	local meta, pcm = ogg.Decode(data)
	local worker_meta, blob = thread_pool.Run(ogg.thread_job, data, 1e9):Await()
	T(table.equal(worker_meta, meta))["=="](true)
	T(blob.len)["=="](ffi.sizeof(pcm))
	T(ffi.string(blob.ptr, blob.len) == ffi.string(pcm, ffi.sizeof(pcm)))["=="](true)
end)
